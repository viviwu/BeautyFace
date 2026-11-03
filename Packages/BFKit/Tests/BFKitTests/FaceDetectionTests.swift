import XCTest
import CoreGraphics
@testable import BFKit

final class FaceDetectionTests: XCTestCase {
    func testSampleImageContainsDetectableFaceAndMaskWhenAvailable() throws {
        let sample = try sampleImageURL(named: "musk.jpeg")
        let decoded = try ImageDecoder.decode(url: sample)
        let result = try FaceDetector().detect(image: decoded.image)

        XCTAssertGreaterThanOrEqual(result.faces.count, 1)
        let face = try XCTUnwrap(result.faces.first)
        XCTAssertNotNil(face.landmarks)
        XCTAssertGreaterThanOrEqual(face.landmarks?.allPoints.count ?? 0, 60)
        XCTAssertNotNil(result.personMask)
        XCTAssertFalse(result.personMask?.isEmpty ?? true)
    }

    func testCompositeImageDetectsTwoFacesWhenAvailable() throws {
        let sample = try sampleImageURL(named: "musk.jpeg")
        let source = try ImageDecoder.decode(url: sample).image
        let width = source.width * 2
        let height = source.height
        let colorSpace = source.colorSpace
            ?? CGColorSpace(name: CGColorSpace.sRGB)
            ?? CGColorSpaceCreateDeviceRGB()

        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                | CGBitmapInfo.byteOrder32Big.rawValue
        ))
        context.draw(
            source,
            in: CGRect(x: 0, y: 0, width: source.width, height: height)
        )
        context.draw(
            source,
            in: CGRect(x: source.width, y: 0, width: source.width, height: height)
        )
        let composite = try XCTUnwrap(context.makeImage())

        let result = try FaceDetector(includePersonMask: false).detect(image: composite)
        XCTAssertGreaterThanOrEqual(result.faces.count, 2)
    }

    func testDebugRendererKeepsImageSize() throws {
        let image = try makeImage(width: 80, height: 60)
        let landmarks = FaceLandmarks(
            allPoints: [CGPoint(x: 0.5, y: 0.5)],
            faceContour: [CGPoint(x: 0.3, y: 0.3), CGPoint(x: 0.7, y: 0.3)],
            leftEye: [],
            rightEye: [],
            leftEyebrow: [],
            rightEyebrow: [],
            nose: [],
            noseCrest: [],
            medianLine: [],
            outerLips: [],
            innerLips: [],
            leftPupil: [],
            rightPupil: []
        )
        let face = FaceObservation(
            boundingBox: CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5),
            roll: nil,
            yaw: nil,
            confidence: 1,
            landmarks: landmarks
        )
        let result = DetectionResult(
            imageSize: CGSize(width: 80, height: 60),
            faces: [face],
            personMask: SegmentationMask(
                width: 4,
                height: 4,
                pixels: [UInt8](repeating: 128, count: 16)
            )
        )

        let debug = try XCTUnwrap(
            DetectionDebugRenderer.render(image: image, result: result)
        )
        XCTAssertEqual(debug.width, 80)
        XCTAssertEqual(debug.height, 60)
    }

    func testTopLeftPixelBoundingBoxFlipsY() {
        let face = FaceObservation(
            boundingBox: CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4),
            roll: nil,
            yaw: nil,
            confidence: 1,
            landmarks: nil
        )
        let size = CGSize(width: 100, height: 200)

        let bottom = face.pixelBoundingBox(in: size)
        XCTAssertEqual(bottom.minX, 10, accuracy: 0.001)
        XCTAssertEqual(bottom.minY, 40, accuracy: 0.001)
        XCTAssertEqual(bottom.width, 30, accuracy: 0.001)
        XCTAssertEqual(bottom.height, 80, accuracy: 0.001)

        let top = face.topLeftPixelBoundingBox(in: size)
        XCTAssertEqual(top.minX, 10, accuracy: 0.001)
        XCTAssertEqual(top.minY, 80, accuracy: 0.001)
        XCTAssertEqual(top.width, 30, accuracy: 0.001)
        XCTAssertEqual(top.height, 80, accuracy: 0.001)
    }

    private func sampleImageURL(named name: String) throws -> URL {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let url = root.appendingPathComponent("SampleImages/\(name)")
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: url.path),
            "SampleImages 不可用"
        )
        return url
    }

    private func makeImage(width: Int, height: Int) throws -> CGImage {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for index in stride(from: 0, to: pixels.count, by: 4) {
            pixels[index] = 120
            pixels[index + 1] = 160
            pixels[index + 2] = 200
            pixels[index + 3] = 255
        }

        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let image = CGImage(
                width: width,
                height: height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: CGBitmapInfo(
                    rawValue: CGImageAlphaInfo.premultipliedLast.rawValue
                        | CGBitmapInfo.byteOrder32Big.rawValue
                ),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
              ) else {
            throw TestError.cannotCreateImage
        }
        return image
    }
}

private enum TestError: Error {
    case cannotCreateImage
}
