import CoreGraphics
import Foundation
import Metal
import MetalPerformanceShaders
import BFAlgorithms

public enum SkinRenderError: Error, LocalizedError {
    case noMetalDevice
    case shaderCompilation(String)
    case missingFunction
    case pipelineCreation(String)
    case textureCreation
    case commandEncoderCreation
    case commandFailed(String)

    public var errorDescription: String? {
        switch self {
        case .noMetalDevice:
            return "当前设备没有可用的 Metal 设备"
        case .shaderCompilation(let message):
            return "美化着色器编译失败：\(message)"
        case .missingFunction:
            return "美化着色器缺少入口函数"
        case .pipelineCreation(let message):
            return "美化管线创建失败：\(message)"
        case .textureCreation:
            return "无法创建美化纹理"
        case .commandEncoderCreation:
            return "无法创建 Metal 命令编码器"
        case .commandFailed(let message):
            return "Metal 命令执行失败：\(message)"
        }
    }
}

/// 基于 Metal / MPS 的皮肤磨皮、美白与提亮渲染器。
public final class SkinRenderer {
    private struct GPUParameters {
        var smoothing: Float
        var whitening: Float
        var brightening: Float
        var padding: Float = 0
    }

    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct BeautyParams {
        float smoothing;
        float whitening;
        float brightening;
        float padding;
    };

    kernel void beautyCompose(
        texture2d<float, access::read> original [[texture(0)]],
        texture2d<float, access::read> blurred [[texture(1)]],
        texture2d<float, access::sample> skinMask [[texture(2)]],
        texture2d<float, access::write> output [[texture(3)]],
        constant BeautyParams &params [[buffer(0)]],
        uint2 gid [[thread_position_in_grid]]
    ) {
        if (gid.x >= original.get_width() || gid.y >= original.get_height()) {
            return;
        }

        float4 source = original.read(gid);
        float4 soft = blurred.read(gid);

        float2 uv = (float2(gid) + 0.5)
            / float2(original.get_width(), original.get_height());
        constexpr sampler maskSampler(
            coord::normalized,
            filter::linear,
            address::clamp_to_edge
        );
        float mask = clamp(skinMask.sample(maskSampler, uv).r, 0.0, 1.0);

        float3 color = mix(
            source.rgb,
            soft.rgb,
            0.85 * params.smoothing * mask
        );

        float luma = dot(color, float3(0.299, 0.587, 0.114));
        float whiten = params.whitening * mask;
        float targetLuma = luma + (1.0 - luma) * 0.22 * whiten;
        float3 whitened = color * (targetLuma / max(luma, 1e-4));
        whitened = mix(whitened, float3(targetLuma), 0.12 * whiten);
        color = whitened;

        float bright = params.brightening * mask;
        color = color + (1.0 - color) * 0.20 * bright;

        output.write(float4(clamp(color, 0.0, 1.0), source.a), gid);
    }
    """

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let pipeline: MTLComputePipelineState
    private let converter: TextureConverter

    public init(device: MTLDevice? = nil) throws {
        guard let resolved = device ?? MTLCreateSystemDefaultDevice() else {
            throw SkinRenderError.noMetalDevice
        }
        guard let queue = resolved.makeCommandQueue() else {
            throw SkinRenderError.commandEncoderCreation
        }

        let library: MTLLibrary
        do {
            library = try resolved.makeLibrary(
                source: Self.shaderSource,
                options: nil
            )
        } catch {
            throw SkinRenderError.shaderCompilation(error.localizedDescription)
        }

        guard let function = library.makeFunction(name: "beautyCompose") else {
            throw SkinRenderError.missingFunction
        }

        let pipeline: MTLComputePipelineState
        do {
            pipeline = try resolved.makeComputePipelineState(function: function)
        } catch {
            throw SkinRenderError.pipelineCreation(error.localizedDescription)
        }

        self.device = resolved
        self.commandQueue = queue
        self.pipeline = pipeline
        self.converter = try TextureConverter(device: resolved)
    }

    public func render(
        image: CGImage,
        skinMask: SkinMask,
        parameters: BeautyParameters
    ) throws -> CGImage {
        guard !skinMask.isEmpty else {
            return image
        }

        let source = try converter.makeTexture(from: image)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float,
            width: image.width,
            height: image.height,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead, .shaderWrite]
        descriptor.storageMode = .shared

        guard let outputTexture = device.makeTexture(descriptor: descriptor) else {
            throw SkinRenderError.textureCreation
        }

        let blurredTexture: MTLTexture
        if parameters.smoothing > 0 {
            guard let texture = device.makeTexture(descriptor: descriptor) else {
                throw SkinRenderError.textureCreation
            }
            blurredTexture = texture
        } else {
            blurredTexture = source
        }

        guard let maskTexture = makeMaskTexture(skinMask) else {
            throw SkinRenderError.textureCreation
        }
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            throw SkinRenderError.commandEncoderCreation
        }

        if parameters.smoothing > 0 {
            let sigma = blurSigma(for: image, smoothing: parameters.smoothing)
            let blur = MPSImageGaussianBlur(device: device, sigma: sigma)
            blur.edgeMode = .clamp
            blur.encode(
                commandBuffer: commandBuffer,
                sourceTexture: source,
                destinationTexture: blurredTexture
            )
        }

        guard let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw SkinRenderError.commandEncoderCreation
        }
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(source, index: 0)
        encoder.setTexture(blurredTexture, index: 1)
        encoder.setTexture(maskTexture, index: 2)
        encoder.setTexture(outputTexture, index: 3)

        var gpuParameters = GPUParameters(
            smoothing: parameters.smoothing,
            whitening: parameters.whitening,
            brightening: parameters.brightening
        )
        encoder.setBytes(
            &gpuParameters,
            length: MemoryLayout<GPUParameters>.size,
            index: 0
        )

        let threadWidth = pipeline.threadExecutionWidth
        let threadHeight = max(
            1,
            pipeline.maxTotalThreadsPerThreadgroup / threadWidth
        )
        encoder.dispatchThreads(
            MTLSize(width: image.width, height: image.height, depth: 1),
            threadsPerThreadgroup: MTLSize(
                width: threadWidth,
                height: threadHeight,
                depth: 1
            )
        )
        encoder.endEncoding()

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        if let error = commandBuffer.error {
            throw SkinRenderError.commandFailed(error.localizedDescription)
        }

        return try converter.makeCGImage(
            from: outputTexture,
            colorSpace: image.colorSpace
        )
    }

    private func makeMaskTexture(_ mask: SkinMask) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r8Unorm,
            width: mask.width,
            height: mask.height,
            mipmapped: false
        )
        descriptor.usage = .shaderRead
        descriptor.storageMode = .shared

        guard let texture = device.makeTexture(descriptor: descriptor) else {
            return nil
        }

        var bytes = [UInt8](repeating: 0, count: mask.values.count)
        for index in mask.values.indices {
            let value = min(max(mask.values[index], 0), 1)
            bytes[index] = UInt8((value * 255).rounded())
        }

        bytes.withUnsafeBytes { buffer in
            texture.replace(
                region: MTLRegionMake2D(0, 0, mask.width, mask.height),
                mipmapLevel: 0,
                withBytes: buffer.baseAddress!,
                bytesPerRow: mask.width
            )
        }
        return texture
    }

    private func blurSigma(for image: CGImage, smoothing: Float) -> Float {
        let longEdge = Float(max(image.width, image.height))
        let scale = max(0.5, longEdge / 1024)
        return max(0.5, scale * (0.8 + 2.2 * smoothing))
    }
}
