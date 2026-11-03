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

/// 基于 Metal / MPS 的皮肤与局部修饰渲染器。
public final class SkinRenderer {
    private struct GPUParameters {
        var smoothing: Float
        var whitening: Float
        var brightening: Float
        var padding: Float
        var eyeBrightening: Float
        var teethWhitening: Float
        var darkCircleRemoval: Float
        var blemishRemoval: Float
    }

    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct BeautyParams {
        float smoothing;
        float whitening;
        float brightening;
        float padding;
        float eyeBrightening;
        float teethWhitening;
        float darkCircleRemoval;
        float blemishRemoval;
    };

    kernel void beautyCompose(
        texture2d<float, access::read> original [[texture(0)]],
        texture2d<float, access::read> blurred [[texture(1)]],
        texture2d<float, access::read> blemishBase [[texture(2)]],
        texture2d<float, access::sample> skinMask [[texture(3)]],
        texture2d<float, access::sample> retouchMask [[texture(4)]],
        texture2d<float, access::write> output [[texture(5)]],
        constant BeautyParams &params [[buffer(0)]],
        uint2 gid [[thread_position_in_grid]]
    ) {
        if (gid.x >= original.get_width() || gid.y >= original.get_height()) {
            return;
        }

        float4 source = original.read(gid);
        float4 soft = blurred.read(gid);
        float4 base = blemishBase.read(gid);

        float2 uv = (float2(gid) + 0.5)
            / float2(original.get_width(), original.get_height());
        constexpr sampler maskSampler(
            coord::normalized,
            filter::linear,
            address::clamp_to_edge
        );
        float skin = clamp(skinMask.sample(maskSampler, uv).r, 0.0, 1.0);
        float3 retouch = clamp(
            retouchMask.sample(maskSampler, uv).rgb,
            0.0,
            1.0
        );

        constexpr float3 lumaWeights = float3(0.299, 0.587, 0.114);
        float3 color = mix(
            source.rgb,
            soft.rgb,
            0.85 * params.smoothing * skin
        );

        float luma = dot(color, lumaWeights);
        float whiten = params.whitening * skin;
        float targetLuma = luma + (1.0 - luma) * 0.22 * whiten;
        float3 whitened = color * (targetLuma / max(luma, 1e-4));
        whitened = mix(whitened, float3(targetLuma), 0.12 * whiten);
        color = whitened;

        float bright = params.brightening * skin;
        color = color + (1.0 - color) * 0.20 * bright;

        float eyeWeight = retouch.r * params.eyeBrightening;
        if (eyeWeight > 0.0) {
            float l = dot(color, lumaWeights);
            float target = l + (1.0 - l) * 0.45 * eyeWeight;
            float3 value = color * (target / max(l, 1e-4));
            value = mix(value, float3(target), 0.18 * eyeWeight);
            color = value;
        }

        float teethWeight = retouch.g * params.teethWhitening;
        if (teethWeight > 0.0) {
            float l = dot(color, lumaWeights);
            float target = l + (1.0 - l) * 0.35 * teethWeight;
            float3 value = color * (target / max(l, 1e-4));
            value.b = value.b + (1.0 - value.b) * 0.15 * teethWeight;
            value = mix(value, float3(target), 0.08 * teethWeight);
            color = value;
        }

        float darkWeight = retouch.b * params.darkCircleRemoval;
        if (darkWeight > 0.0) {
            float l = dot(color, lumaWeights);
            float target = l + (1.0 - l) * 0.30 * darkWeight;
            float3 value = color * (target / max(l, 1e-4));
            // 眼下偏青紫，按暖色调轻微中和；强度保持克制，避免出现橙色条带。
            value.r = value.r + (1.0 - value.r) * 0.040 * darkWeight;
            value.g = value.g + (1.0 - value.g) * 0.035 * darkWeight;
            value.b = value.b + (1.0 - value.b) * 0.030 * darkWeight;
            value = mix(value, float3(target), 0.08 * darkWeight);
            color = value;
        }

        float blemishWeight = params.blemishRemoval * skin;
        if (blemishWeight > 0.0) {
            // 痘印判据：低频底色（base）与原始像素的亮度差。
            // 两者都取自原图，不受磨皮 / 美白造成的整体亮度偏移影响；
            // 修复时按比例抬升像素自身的纹理，而不是替换成模糊值。
            float baseLuma = dot(base.rgb, lumaWeights);
            float sourceLuma = dot(source.rgb, lumaWeights);
            float dip = baseLuma - sourceLuma;
            float spot = smoothstep(0.030, 0.095, dip) * blemishWeight;

            if (spot > 0.0) {
                float gain = clamp(baseLuma / max(sourceLuma, 1e-3), 1.0, 1.22);
                color = color * mix(1.0, gain, 0.90 * spot);

                // 色度向邻域收敛，去掉痘印的偏红，同时不改动亮度。
                float3 baseChroma = base.rgb - baseLuma;
                float3 sourceChroma = source.rgb - sourceLuma;
                color = color + (baseChroma - sourceChroma) * (0.45 * spot);
            }
        }

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
        retouchMask: RetouchMask? = nil,
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

        let needsSmoothing = parameters.smoothing > 0
        let needsBlemish = parameters.blemishRemoval > 0

        let blurredTexture = try makeBlurredTexture(
            source: source,
            descriptor: descriptor,
            required: needsSmoothing
        )
        let blemishBaseTexture = try makeBlurredTexture(
            source: source,
            descriptor: descriptor,
            required: needsBlemish
        )

        guard let skinTexture = makeSkinTexture(skinMask) else {
            throw SkinRenderError.textureCreation
        }
        guard let retouchTexture = makeRetouchTexture(retouchMask) else {
            throw SkinRenderError.textureCreation
        }
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            throw SkinRenderError.commandEncoderCreation
        }

        if needsSmoothing {
            let sigma = blurSigma(for: image, smoothing: parameters.smoothing)
            let blur = MPSImageGaussianBlur(device: device, sigma: sigma)
            blur.edgeMode = .clamp
            blur.encode(
                commandBuffer: commandBuffer,
                sourceTexture: source,
                destinationTexture: blurredTexture
            )
        }

        if needsBlemish {
            let sigma = blemishBaseSigma(for: image)
            let blur = MPSImageGaussianBlur(device: device, sigma: sigma)
            blur.edgeMode = .clamp
            blur.encode(
                commandBuffer: commandBuffer,
                sourceTexture: source,
                destinationTexture: blemishBaseTexture
            )
        }

        guard let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw SkinRenderError.commandEncoderCreation
        }
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(source, index: 0)
        encoder.setTexture(blurredTexture, index: 1)
        encoder.setTexture(blemishBaseTexture, index: 2)
        encoder.setTexture(skinTexture, index: 3)
        encoder.setTexture(retouchTexture, index: 4)
        encoder.setTexture(outputTexture, index: 5)

        var gpuParameters = GPUParameters(
            smoothing: parameters.smoothing,
            whitening: parameters.whitening,
            brightening: parameters.brightening,
            padding: 0,
            eyeBrightening: parameters.eyeBrightening,
            teethWhitening: parameters.teethWhitening,
            darkCircleRemoval: parameters.darkCircleRemoval,
            blemishRemoval: parameters.blemishRemoval
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

    private func makeBlurredTexture(
        source: MTLTexture,
        descriptor: MTLTextureDescriptor,
        required: Bool
    ) throws -> MTLTexture {
        guard required else { return source }
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw SkinRenderError.textureCreation
        }
        return texture
    }

    private func makeSkinTexture(_ mask: SkinMask) -> MTLTexture? {
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

    private func makeRetouchTexture(_ mask: RetouchMask?) -> MTLTexture? {
        let width = mask?.isEmpty == false ? mask!.width : 1
        let height = mask?.isEmpty == false ? mask!.height : 1
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.usage = .shaderRead
        descriptor.storageMode = .shared

        guard let texture = device.makeTexture(descriptor: descriptor) else {
            return nil
        }

        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        if let mask, !mask.isEmpty {
            for index in mask.eye.indices {
                bytes[index * 4] = UInt8(
                    (min(max(mask.eye[index], 0), 1) * 255).rounded()
                )
                bytes[index * 4 + 1] = UInt8(
                    (min(max(mask.teeth[index], 0), 1) * 255).rounded()
                )
                bytes[index * 4 + 2] = UInt8(
                    (min(max(mask.darkCircle[index], 0), 1) * 255).rounded()
                )
            }
        }

        bytes.withUnsafeBytes { buffer in
            texture.replace(
                region: MTLRegionMake2D(0, 0, width, height),
                mipmapLevel: 0,
                withBytes: buffer.baseAddress!,
                bytesPerRow: width * 4
            )
        }
        return texture
    }

    private func blurSigma(for image: CGImage, smoothing: Float) -> Float {
        let longEdge = Float(max(image.width, image.height))
        let scale = max(0.5, longEdge / 1024)
        return max(0.5, scale * (0.8 + 2.2 * smoothing))
    }

    /// 去痘印的低频参考尺度：约等于 8 个「1024 基准像素」，
    /// 需明显大于痘印本身，才能把瑕疵平均掉；同时设上限控制 MPS 卷积开销。
    private func blemishBaseSigma(for image: CGImage) -> Float {
        let longEdge = Float(max(image.width, image.height))
        let scale = max(0.4, longEdge / 1024)
        return min(max(3.0, scale * 8), 24.0)
    }
}
