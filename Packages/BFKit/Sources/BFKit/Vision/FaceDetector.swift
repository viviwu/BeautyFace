import CoreGraphics
import CoreVideo
import Foundation
import ImageIO
import Vision

public struct DetectionResult: Sendable {
    public let imageSize: CGSize
    public let faces: [FaceObservation]
    public let personMask: SegmentationMask?

    public init(
        imageSize: CGSize,
        faces: [FaceObservation],
        personMask: SegmentationMask?
    ) {
        self.imageSize = imageSize
        self.faces = faces
        self.personMask = personMask
    }
}

public enum FaceDetectionError: Error, LocalizedError {
    case requestFailed(String)

    public var errorDescription: String? {
        switch self {
        case .requestFailed(let message):
            return "人脸检测失败：\(message)"
        }
    }
}

public struct FaceDetector {
    public var includeLandmarks: Bool
    public var includePersonMask: Bool
    public var segmentationQuality: VNGeneratePersonSegmentationRequest.QualityLevel

    public init(
        includeLandmarks: Bool = true,
        includePersonMask: Bool = true,
        segmentationQuality: VNGeneratePersonSegmentationRequest.QualityLevel = .accurate
    ) {
        self.includeLandmarks = includeLandmarks
        self.includePersonMask = includePersonMask
        self.segmentationQuality = segmentationQuality
    }

    public func detect(
        image: CGImage,
        orientation: CGImagePropertyOrientation = .up
    ) throws -> DetectionResult {
        let handler = VNImageRequestHandler(
            cgImage: image,
            orientation: orientation,
            options: [:]
        )

        let faceRequest = VNDetectFaceLandmarksRequest()
        var requests: [VNRequest] = [faceRequest]

        let maskRequest: VNGeneratePersonSegmentationRequest?
        if includePersonMask {
            let request = VNGeneratePersonSegmentationRequest()
            request.qualityLevel = segmentationQuality
            request.outputPixelFormat = kCVPixelFormatType_OneComponent8
            requests.append(request)
            maskRequest = request
        } else {
            maskRequest = nil
        }

        do {
            try handler.perform(requests)
        } catch {
            throw FaceDetectionError.requestFailed(error.localizedDescription)
        }

        let faces = (faceRequest.results ?? []).map {
            makeFace(from: $0, includeLandmarks: includeLandmarks)
        }
        let personMask = maskRequest?.results?.first.flatMap {
            makeMask(from: $0.pixelBuffer)
        }

        return DetectionResult(
            imageSize: CGSize(width: image.width, height: image.height),
            faces: faces,
            personMask: personMask
        )
    }

    private func makeFace(
        from observation: VNFaceObservation,
        includeLandmarks: Bool
    ) -> FaceObservation {
        var landmarks: FaceLandmarks?
        if includeLandmarks, let visionLandmarks = observation.landmarks {
            let box = observation.boundingBox

            func imagePoints(_ region: VNFaceLandmarkRegion2D?) -> [CGPoint] {
                guard let region else { return [] }
                return region.normalizedPoints.map { point in
                    CGPoint(
                        x: box.minX + point.x * box.width,
                        y: box.minY + point.y * box.height
                    )
                }
            }

            landmarks = FaceLandmarks(
                allPoints: imagePoints(visionLandmarks.allPoints),
                faceContour: imagePoints(visionLandmarks.faceContour),
                leftEye: imagePoints(visionLandmarks.leftEye),
                rightEye: imagePoints(visionLandmarks.rightEye),
                leftEyebrow: imagePoints(visionLandmarks.leftEyebrow),
                rightEyebrow: imagePoints(visionLandmarks.rightEyebrow),
                nose: imagePoints(visionLandmarks.nose),
                noseCrest: imagePoints(visionLandmarks.noseCrest),
                medianLine: imagePoints(visionLandmarks.medianLine),
                outerLips: imagePoints(visionLandmarks.outerLips),
                innerLips: imagePoints(visionLandmarks.innerLips),
                leftPupil: imagePoints(visionLandmarks.leftPupil),
                rightPupil: imagePoints(visionLandmarks.rightPupil)
            )
        }

        return FaceObservation(
            boundingBox: observation.boundingBox,
            roll: observation.roll.map { CGFloat($0.doubleValue) },
            yaw: observation.yaw.map { CGFloat($0.doubleValue) },
            confidence: observation.confidence,
            landmarks: landmarks
        )
    }

    private func makeMask(from pixelBuffer: CVPixelBuffer) -> SegmentationMask? {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        guard width > 0, height > 0,
              let base = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            return nil
        }

        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let format = CVPixelBufferGetPixelFormatType(pixelBuffer)

        if format == kCVPixelFormatType_OneComponent8 {
            var pixels = [UInt8](repeating: 0, count: width * height)
            pixels.withUnsafeMutableBytes { destination in
                guard let destinationBase = destination.baseAddress else { return }
                for row in 0..<height {
                    memcpy(
                        destinationBase.advanced(by: row * width),
                        base.advanced(by: row * bytesPerRow),
                        width
                    )
                }
            }
            return SegmentationMask(width: width, height: height, pixels: pixels)
        }

        if format == kCVPixelFormatType_OneComponent32Float {
            var pixels = [UInt8](repeating: 0, count: width * height)
            let floats = base.assumingMemoryBound(to: Float.self)
            let floatsPerRow = bytesPerRow / MemoryLayout<Float>.size
            for row in 0..<height {
                for column in 0..<width {
                    let value = min(max(floats[row * floatsPerRow + column], 0), 1)
                    pixels[row * width + column] = UInt8(value * 255)
                }
            }
            return SegmentationMask(width: width, height: height, pixels: pixels)
        }

        return nil
    }
}
