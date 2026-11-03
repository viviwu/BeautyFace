import CoreGraphics
import Foundation

public enum RetouchDebugRenderer {
    public static func render(image: CGImage, mask: RetouchMask) -> CGImage? {
        guard !mask.isEmpty else { return nil }
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

        if let overlay = makeOverlay(mask) {
            context.interpolationQuality = .low
            context.draw(
                overlay,
                in: CGRect(x: 0, y: 0, width: width, height: height)
            )
            context.interpolationQuality = .none
        }

        return context.makeImage()
    }

    private static func makeOverlay(_ mask: RetouchMask) -> CGImage? {
        var bytes = [UInt8](repeating: 0, count: mask.width * mask.height * 4)
        for index in 0..<(mask.width * mask.height) {
            let eye = min(max(mask.eye[index], 0), 1)
            let teeth = min(max(mask.teeth[index], 0), 1)
            let dark = min(max(mask.darkCircle[index], 0), 1)

            let value = max(eye, max(teeth, dark))
            guard value > 0 else { continue }

            let color: (Float, Float, Float)
            if eye >= teeth && eye >= dark {
                color = (0.1, 0.95, 1.0)
            } else if teeth >= dark {
                color = (1.0, 0.95, 0.1)
            } else {
                color = (1.0, 0.1, 0.9)
            }

            let alpha = value * 0.5
            bytes[index * 4] = UInt8((color.0 * alpha * 255).rounded())
            bytes[index * 4 + 1] = UInt8((color.1 * alpha * 255).rounded())
            bytes[index * 4 + 2] = UInt8((color.2 * alpha * 255).rounded())
            bytes[index * 4 + 3] = UInt8((alpha * 255).rounded())
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
}
