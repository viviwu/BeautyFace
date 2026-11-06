import CoreGraphics
import Foundation
import BFAlgorithms

public enum DetectionDebugRenderer {
    /// `bodyModels` 为 M8 颈肩几何（可选）。传入后在 `_debug.png` 上叠加
    /// 下巴线 / 颈根 / 肩线 / 走廊边界，便于目视核对肩线定位与衰减范围。
    /// 坐标为 y 向上像素坐标，与 `FaceGeometry` 一致；CGContext 的位图上下文
    /// 原点在左下，因此可直接使用，无需 `1 − v` 翻转。
    public static func render(
        image: CGImage,
        result: DetectionResult,
        skinMask: SkinMask? = nil,
        bodyModels: [NeckShoulderModel] = []
    ) -> CGImage? {
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

        if let skinMask,
           !skinMask.isEmpty,
           let skinImage = makeSkinMaskImage(skinMask) {
            context.interpolationQuality = .low
            context.draw(
                skinImage,
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

        if !bodyModels.isEmpty {
            drawBodyModels(bodyModels, in: context)
        }

        return context.makeImage()
    }

    /// M8 颈肩几何标注：绿=下巴 / 青=颈根 / 黄=肩线 / 白=走廊边界。
    private static func drawBodyModels(
        _ models: [NeckShoulderModel],
        in context: CGContext
    ) {
        let lineWidth: CGFloat = 2
        for model in models {
            let left = CGFloat(model.axisX - model.outerHalfWidth)
            let right = CGFloat(model.axisX + model.outerHalfWidth)

            func horizontal(_ y: Float, _ color: CGColor) {
                context.setStrokeColor(color)
                context.setLineWidth(lineWidth)
                context.move(to: CGPoint(x: left, y: CGFloat(y)))
                context.addLine(to: CGPoint(x: right, y: CGFloat(y)))
                context.strokePath()
            }

            horizontal(model.chinY, CGColor(red: 0.2, green: 1, blue: 0.3, alpha: 1))
            horizontal(model.neckRootY, CGColor(red: 0.1, green: 0.9, blue: 1, alpha: 1))
            horizontal(model.shoulderY, CGColor(red: 1, green: 0.85, blue: 0.1, alpha: 1))

            context.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.85))
            context.setLineWidth(1)
            for x in [left, right] {
                context.move(to: CGPoint(x: x, y: CGFloat(model.shoulderY)))
                context.addLine(to: CGPoint(x: x, y: CGFloat(model.neckRootY)))
                context.strokePath()
            }

            // 中轴虚线：便于看颈部质心是否落在真实脖颈上。
            context.setStrokeColor(CGColor(red: 1, green: 0.4, blue: 0.1, alpha: 0.9))
            context.setLineWidth(1)
            var y = model.shoulderY
            while y < model.neckRootY {
                context.move(to: CGPoint(x: CGFloat(model.axisX), y: CGFloat(y)))
                let end = min(y + 12, model.neckRootY)
                context.addLine(to: CGPoint(x: CGFloat(model.axisX), y: CGFloat(end)))
                context.strokePath()
                y += 24
            }
        }
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

    private static func makeSkinMaskImage(_ mask: SkinMask) -> CGImage? {
        var bytes = [UInt8](repeating: 0, count: mask.values.count * 4)
        for index in mask.values.indices {
            let value = min(max(mask.values[index], 0), 1)
            let alpha = value * 0.45
            bytes[index * 4] = UInt8(10 * alpha)
            bytes[index * 4 + 1] = UInt8(230 * alpha)
            bytes[index * 4 + 2] = UInt8(60 * alpha)
            bytes[index * 4 + 3] = UInt8(255 * alpha)
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
