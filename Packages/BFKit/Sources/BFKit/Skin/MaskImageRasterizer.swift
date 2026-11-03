import CoreGraphics
import Foundation

enum MaskImageRasterizerError: Error, LocalizedError {
    case cannotCreateContext

    var errorDescription: String? {
        "无法创建蒙版像素上下文"
    }
}

enum MaskImageRasterizer {
    static func rgbaBytes(
        from image: CGImage,
        width: Int,
        height: Int
    ) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)
            ?? CGColorSpaceCreateDeviceRGB()

        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                    | CGBitmapInfo.byteOrder32Big.rawValue
            ) else {
                return false
            }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }

        guard drawn else {
            throw MaskImageRasterizerError.cannotCreateContext
        }
        return bytes
    }
}
