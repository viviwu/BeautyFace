import CoreGraphics
import Foundation
import Metal

public enum TextureConverterError: Error, LocalizedError {
    case noMetalDevice
    case cannotCreateContext
    case cannotCreateTexture
    case unsupportedPixelFormat
    case cannotCreateImage

    public var errorDescription: String? {
        switch self {
        case .noMetalDevice:
            return "当前设备没有可用的 Metal 设备"
        case .cannotCreateContext:
            return "无法创建位图上下文"
        case .cannotCreateTexture:
            return "无法创建 Metal 纹理"
        case .unsupportedPixelFormat:
            return "纹理格式不是 rgba16Float"
        case .cannotCreateImage:
            return "无法从纹理创建 CGImage"
        }
    }
}

/// CGImage 与 rgba16Float 工作纹理之间的转换（ADR-010）。
public final class TextureConverter {
    public let device: MTLDevice

    public init(device: MTLDevice? = nil) throws {
        guard let resolved = device ?? MTLCreateSystemDefaultDevice() else {
            throw TextureConverterError.noMetalDevice
        }
        self.device = resolved
    }

    public func makeTexture(from image: CGImage) throws -> MTLTexture {
        let width = image.width
        let height = image.height
        let colorSpace = Self.rgbColorSpace(for: image)

        var bytes = [UInt8](repeating: 0, count: width * height * 4)
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
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else {
            throw TextureConverterError.cannotCreateContext
        }

        let scale = Float16(1.0 / 255.0)
        var half = [Float16](repeating: 0, count: bytes.count)
        for index in 0..<bytes.count {
            half[index] = Float16(bytes[index]) * scale
        }

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead, .shaderWrite]
        descriptor.storageMode = .shared

        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw TextureConverterError.cannotCreateTexture
        }

        half.withUnsafeBytes { buffer in
            texture.replace(
                region: MTLRegionMake2D(0, 0, width, height),
                mipmapLevel: 0,
                withBytes: buffer.baseAddress!,
                bytesPerRow: width * 8
            )
        }

        return texture
    }

    public func makeCGImage(
        from texture: MTLTexture,
        colorSpace: CGColorSpace? = nil
    ) throws -> CGImage {
        guard texture.pixelFormat == .rgba16Float else {
            throw TextureConverterError.unsupportedPixelFormat
        }

        let width = texture.width
        let height = texture.height
        var half = [Float16](repeating: 0, count: width * height * 4)
        half.withUnsafeMutableBytes { buffer in
            texture.getBytes(
                buffer.baseAddress!,
                bytesPerRow: width * 8,
                from: MTLRegionMake2D(0, 0, width, height),
                mipmapLevel: 0
            )
        }

        var bytes = [UInt8](repeating: 0, count: half.count)
        for index in 0..<half.count {
            let value = (Float(half[index]) * 255.0).rounded()
            bytes[index] = UInt8(min(max(value, 0), 255))
        }

        let space = colorSpace
            ?? CGColorSpace(name: CGColorSpace.sRGB)
            ?? CGColorSpaceCreateDeviceRGB()
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else {
            throw TextureConverterError.cannotCreateImage
        }

        let bitmapInfo = CGBitmapInfo(
            rawValue: CGImageAlphaInfo.premultipliedLast.rawValue
                | CGBitmapInfo.byteOrder32Big.rawValue
        )
        guard let image = CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: space,
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ) else {
            throw TextureConverterError.cannotCreateImage
        }

        return image
    }

    private static func rgbColorSpace(for image: CGImage) -> CGColorSpace {
        if let colorSpace = image.colorSpace, colorSpace.model == .rgb {
            return colorSpace
        }
        return CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    }
}
