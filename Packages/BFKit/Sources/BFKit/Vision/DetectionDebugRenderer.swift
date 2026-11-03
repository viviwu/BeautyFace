import CoreGraphics
import Foundation

public enum DetectionDebugRenderer {
    public static func render(image: CGImage, result: DetectionResult) -> CGImage? {
        let width = image.width
        let height = image.height
        let colorSpace = image.colorSpace
            ?? CGColorSpace(name: CGColorSpace.sRGB)
            ?? CGColorSpaceCreateDeviceRGB()

        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                | CGBitmapInfo.byteOrder32Big.rawValue
        ) else {
            return nil
        }

        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        if let mask = result.personMask,
           !mask.isEmpty,
           let maskImage = makeMaskImage(mask) {
            context.interpolationQuality = .low
            context.draw(
                maskImage,
                in: CGRect(x: 0, y: 0, width: width, height: height)
            )
            context.interpolationQuality = .none
        }

        let imageSize = CGSize(width: width, height: height)
        for (index, face) in result.faces.enumerated() {
            let color = color(for: index)
            let rect = face.pixelBoundingBox(in: imageSize)

            context.setStrokeColor(color)
            context.setLineWidth(2)
            context.stroke(rect)

            guard let landmarks = face.landmarks else { continue }
            for region in FaceLandmarkRegion.allCases {
                draw(
                    points: landmarks.points(for: region),
                    in: context,
                    imageSize: imageSize,
                    color: color,
                    closed: region.isClosed
                )
            }
        }

        return context.makeImage()
    }

    private static func draw(
        points: [CGPoint],
        in context: CGContext,
        imageSize: CGSize,
        color: CGColor,
        closed: Bool
    ) {
        guard !points.isEmpty else { return }
        let pixelPoints = points.map {
            CGPoint(x: $0.x * imageSize.width, y: $0.y * imageSize.height)
        }

        if pixelPoints.count > 1 {
            context.setStrokeColor(color)
            context.setLineWidth(1)
            context.move(to: pixelPoints[0])
            for point in pixelPoints.dropFirst() {
                context.addLine(to: point)
            }
            if closed, let first = pixelPoints.first {
                context.addLine(to: first)
            }
            context.strokePath()
        }

        context.setFillColor(color)
        let radius: CGFloat = 1.5
        for point in pixelPoints {
            context.fillEllipse(in: CGRect(
                x: point.x - radius,
                y: point.y - radius,
                width: radius * 2,
                height: radius * 2
            ))
        }
    }

    private static func makeMaskImage(_ mask: SegmentationMask) -> CGImage? {
        var bytes = [UInt8](repeating: 0, count: mask.width * mask.height * 4)
        for index in 0..<mask.pixels.count {
            let alpha = mask.pixels[index]
            let factor = Float(alpha) / 255
            bytes[index * 4] = 0
            bytes[index * 4 + 1] = UInt8(120 * factor)
            bytes[index * 4 + 2] = UInt8(255 * factor)
            bytes[index * 4 + 3] = alpha
        }

        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
            return nil
        }

        return CGImage(
            width: mask.width,
            height: mask.height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: mask.width * 4,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo(
                rawValue: CGImageAlphaInfo.premultipliedLast.rawValue
                    | CGBitmapInfo.byteOrder32Big.rawValue
            ),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }

    private static func color(for index: Int) -> CGColor {
        switch index % 6 {
        case 0:
            return CGColor(red: 1, green: 0.2, blue: 0.2, alpha: 1)
        case 1:
            return CGColor(red: 0.2, green: 0.9, blue: 0.3, alpha: 1)
        case 2:
            return CGColor(red: 0.2, green: 0.5, blue: 1, alpha: 1)
        case 3:
            return CGColor(red: 1, green: 0.85, blue: 0.1, alpha: 1)
        case 4:
            return CGColor(red: 0.85, green: 0.2, blue: 1, alpha: 1)
        default:
            return CGColor(red: 0.1, green: 0.9, blue: 0.9, alpha: 1)
        }
    }
}

private extension FaceLandmarkRegion {
    var isClosed: Bool {
        switch self {
        case .faceContour, .leftEye, .rightEye, .outerLips, .innerLips:
            return true
        default:
            return false
        }
    }
}
