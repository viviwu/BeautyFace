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
///
/// 上传路径不走 CPU 逐字节换算（全分辨率 29M 次循环要 2.5s），而是先把
/// RGBA8 位图直接放进 rgba8Unorm 纹理，再用一个微型 kernel 在 GPU 上
/// 完成归一化并写出 rgba16Float，全程毫秒级。
public final class TextureConverter {
    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    kernel void u8To16F(
        texture2d<float, access::read> source [[texture(0)]],
        texture2d<float, access::write> output [[texture(1)]],
        uint2 gid [[thread_position_in_grid]]
    ) {
        if (gid.x >= output.get_width() || gid.y >= output.get_height()) {
            return;
        }
        // rgba8Unorm 读取即得 0...1 归一化值
        output.write(source.read(gid), gid);
    }

    kernel void f16ToU8(
        texture2d<float, access::read> source [[texture(0)]],
        texture2d<float, access::write> output [[texture(1)]],
        uint2 gid [[thread_position_in_grid]]
    ) {
        if (gid.x >= output.get_width() || gid.y >= output.get_height()) {
            return;
        }
        // rgba8Unorm 写入自动完成 clamp 与量化
        output.write(source.read(gid), gid);
    }
    """

    public let device: MTLDevice
    private var conversionPipeline: MTLComputePipelineState?
    private var conversionQueue: MTLCommandQueue?

    public init(device: MTLDevice? = nil) throws {
        guard let resolved = device ?? MTLCreateSystemDefaultDevice() else {
            throw TextureConverterError.noMetalDevice
        }
        self.device = resolved
    }

    /// 惰性准备 GPU 转换管线；失败时调用方回退 CPU 路径。
    private func prepareGPUConversion() -> (
        MTLComputePipelineState, MTLCommandQueue
    )? {
        if let pipeline = conversionPipeline, let queue = conversionQueue {
            return (pipeline, queue)
        }
        guard let queue = device.makeCommandQueue() else { return nil }
        do {
            let library = try device.makeLibrary(
                source: Self.shaderSource,
                options: nil
            )
            guard let function = library.makeFunction(name: "u8To16F") else {
                return nil
            }
            let pipeline = try device.makeComputePipelineState(
                function: function
            )
            conversionPipeline = pipeline
            conversionQueue = queue
            return (pipeline, queue)
        } catch {
            return nil
        }
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

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .shared

        guard let byteTexture = device.makeTexture(descriptor: descriptor) else {
            throw TextureConverterError.cannotCreateTexture
        }
        bytes.withUnsafeBytes { buffer in
            byteTexture.replace(
                region: MTLRegionMake2D(0, 0, width, height),
                mipmapLevel: 0,
                withBytes: buffer.baseAddress!,
                bytesPerRow: width * 4
            )
        }

        // GPU 上完成 8bit → 16F 归一化；不可用时回退 CPU 循环。
        if let (pipeline, queue) = prepareGPUConversion() {
            return try convertTo16F(
                byteTexture: byteTexture,
                pipeline: pipeline,
                queue: queue
            )
        }
        return try cpuConvert(byteTexture: byteTexture)
    }

    private func convertTo16F(
        byteTexture: MTLTexture,
        pipeline: MTLComputePipelineState,
        queue: MTLCommandQueue
    ) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float,
            width: byteTexture.width,
            height: byteTexture.height,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead, .shaderWrite]
        descriptor.storageMode = .shared

        guard let output = device.makeTexture(descriptor: descriptor) else {
            throw TextureConverterError.cannotCreateTexture
        }
        guard let commandBuffer = queue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw TextureConverterError.cannotCreateTexture
        }
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(byteTexture, index: 0)
        encoder.setTexture(output, index: 1)
        let threadWidth = pipeline.threadExecutionWidth
        let threadHeight = max(
            1,
            pipeline.maxTotalThreadsPerThreadgroup / threadWidth
        )
        encoder.dispatchThreads(
            MTLSize(width: byteTexture.width, height: byteTexture.height, depth: 1),
            threadsPerThreadgroup: MTLSize(
                width: threadWidth,
                height: threadHeight,
                depth: 1
            )
        )
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        if commandBuffer.error != nil {
            throw TextureConverterError.cannotCreateTexture
        }
        return output
    }

    /// 兜底 CPU 路径：环境不支持时从 8bit 纹理读回逐字节换算。
    private func cpuConvert(byteTexture: MTLTexture) throws -> MTLTexture {
        let width = byteTexture.width
        let height = byteTexture.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        bytes.withUnsafeMutableBytes { buffer in
            byteTexture.getBytes(
                buffer.baseAddress!,
                bytesPerRow: width * 4,
                from: MTLRegionMake2D(0, 0, width, height),
                mipmapLevel: 0
            )
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

        // GPU 上完成 16F → 8bit 量化，再整块读回；不可用时回退 CPU 循环。
        if let (pipeline, queue) = prepareGPUConversion() {
            let bytes = try quantizeToBytes(
                texture: texture,
                pipeline: pipeline,
                queue: queue
            )
            return try image(fromBytes: bytes, width: width, height: height, colorSpace: colorSpace)
        }

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
        return try image(fromBytes: bytes, width: width, height: height, colorSpace: colorSpace)
    }

    private func quantizeToBytes(
        texture: MTLTexture,
        pipeline: MTLComputePipelineState,
        queue: MTLCommandQueue
    ) throws -> [UInt8] {
        let width = texture.width
        let height = texture.height

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead, .shaderWrite]
        descriptor.storageMode = .shared

        guard let byteTexture = device.makeTexture(descriptor: descriptor),
              let commandBuffer = queue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw TextureConverterError.cannotCreateImage
        }
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(texture, index: 0)
        encoder.setTexture(byteTexture, index: 1)
        let threadWidth = pipeline.threadExecutionWidth
        let threadHeight = max(
            1,
            pipeline.maxTotalThreadsPerThreadgroup / threadWidth
        )
        encoder.dispatchThreads(
            MTLSize(width: width, height: height, depth: 1),
            threadsPerThreadgroup: MTLSize(
                width: threadWidth,
                height: threadHeight,
                depth: 1
            )
        )
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        if commandBuffer.error != nil {
            throw TextureConverterError.cannotCreateImage
        }

        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        bytes.withUnsafeMutableBytes { buffer in
            byteTexture.getBytes(
                buffer.baseAddress!,
                bytesPerRow: width * 4,
                from: MTLRegionMake2D(0, 0, width, height),
                mipmapLevel: 0
            )
        }
        return bytes
    }

    private func image(
        fromBytes bytes: [UInt8],
        width: Int,
        height: Int,
        colorSpace: CGColorSpace?
    ) throws -> CGImage {
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
