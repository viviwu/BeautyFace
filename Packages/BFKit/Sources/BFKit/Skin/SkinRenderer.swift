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
///
/// 磨皮采用**亮度引导的保边滤波**（guided filter，He et al.）：
/// 以原图亮度 `I` 作为引导图，对 R/G/B 三通道分别拟合局部线性模型
/// `q = a·I + b`。在平坦的皮肤区域方差远小于正则项，`a → 0`，
/// 输出趋近局部均值，纹理被抹平；在眼睛、唇线、发际线等强边缘处方差
/// 远大于正则项，`a → 1`，输出趋近原图，边缘被保留。因此不需要额外
/// 的边缘检测，也不会像高斯磨皮那样在强参数下把整张脸糊掉。
///
/// 实现采用 Fast Guided Filter：统计量与线性系数在 1/4 分辨率上计算，
/// 再按全分辨率双线性放大后回代，既省显存也省算力。
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

    /// 引导滤波参数；`downsample` 为低分辨率统计的下采样倍数。
    private struct GuidedParameters {
        var epsilon: Float
        var downsample: Float
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

    struct GuidedParams {
        float epsilon;
        float downsample;
    };

    constant float3 kLumaWeights = float3(0.299, 0.587, 0.114);

    /// 引导滤波第一步：把原图按 `downsample` 做方框降采样，
    /// 并在低分辨率上一次性算出后续需要的统计量。
    ///
    /// statsA = (I, I², I·R, I·G)
    /// statsB = (I·B, R, G, B)
    ///
    /// 这样一次方框滤波之后就能同时得到 meanI、meanI²、meanI·P 与 meanP，
    /// 无需为每个通道单独再算一次均值。
    kernel void guidedStats(
        texture2d<float, access::read> source [[texture(0)]],
        texture2d<float, access::write> statsA [[texture(1)]],
        texture2d<float, access::write> statsB [[texture(2)]],
        constant GuidedParams &params [[buffer(0)]],
        uint2 gid [[thread_position_in_grid]]
    ) {
        uint lowWidth = statsA.get_width();
        uint lowHeight = statsA.get_height();
        if (gid.x >= lowWidth || gid.y >= lowHeight) {
            return;
        }

        uint step = uint(max(params.downsample, 1.0));
        uint sourceWidth = source.get_width();
        uint sourceHeight = source.get_height();

        float3 sum = float3(0.0);
        float count = 0.0;
        for (uint dy = 0; dy < step; ++dy) {
            uint y = min(gid.y * step + dy, sourceHeight - 1);
            for (uint dx = 0; dx < step; ++dx) {
                uint x = min(gid.x * step + dx, sourceWidth - 1);
                sum += source.read(uint2(x, y)).rgb;
                count += 1.0;
            }
        }

        float3 color = sum / count;
        float guide = dot(color, kLumaWeights);
        statsA.write(float4(guide, guide * guide, guide * color.r, guide * color.g), gid);
        statsB.write(float4(guide * color.b, color.r, color.g, color.b), gid);
    }

    /// 引导滤波第二步：由模糊后的统计量求局部线性系数。
    ///
    /// a = cov(I, P) / (var(I) + eps)，b = mean(P) - a · mean(I)
    ///
    /// coeffA = (aR, aG, aB, bR)，coeffB = (bG, bB, 0, 0)
    kernel void guidedCoefficients(
        texture2d<float, access::read> meanA [[texture(0)]],
        texture2d<float, access::read> meanB [[texture(1)]],
        texture2d<float, access::write> coeffA [[texture(2)]],
        texture2d<float, access::write> coeffB [[texture(3)]],
        constant GuidedParams &params [[buffer(0)]],
        uint2 gid [[thread_position_in_grid]]
    ) {
        if (gid.x >= meanA.get_width() || gid.y >= meanA.get_height()) {
            return;
        }

        float4 first = meanA.read(gid);
        float4 second = meanB.read(gid);

        float meanGuide = first.x;
        float variance = max(first.y - meanGuide * meanGuide, 0.0);
        float inverse = 1.0 / (variance + max(params.epsilon, 1e-6));

        float3 meanColor = float3(second.y, second.z, second.w);
        float3 covariance = float3(
            first.z - meanGuide * meanColor.r,
            first.w - meanGuide * meanColor.g,
            second.x - meanGuide * meanColor.b
        );

        float3 a = covariance * inverse;
        float3 b = meanColor - a * meanGuide;

        coeffA.write(float4(a.r, a.g, a.b, b.r), gid);
        coeffB.write(float4(b.g, b.b, 0.0, 0.0), gid);
    }

    kernel void beautyCompose(
        texture2d<float, access::read> original [[texture(0)]],
        texture2d<float, access::sample> guideCoefficients [[texture(1)]],
        texture2d<float, access::sample> guideOffsets [[texture(2)]],
        texture2d<float, access::read> blemishBase [[texture(3)]],
        texture2d<float, access::sample> skinMask [[texture(4)]],
        texture2d<float, access::sample> retouchMask [[texture(5)]],
        texture2d<float, access::write> output [[texture(6)]],
        constant BeautyParams &params [[buffer(0)]],
        uint2 gid [[thread_position_in_grid]]
    ) {
        if (gid.x >= original.get_width() || gid.y >= original.get_height()) {
            return;
        }

        float4 source = original.read(gid);
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

        // 保边磨皮：q = a·I + b。系数在 1/4 分辨率上算好后双线性放大，
        // 本身已是平滑场，放大不会引入台阶。
        float3 smoothed = source.rgb;
        if (params.smoothing > 0.0) {
            float4 coefficients = guideCoefficients.sample(maskSampler, uv);
            float4 offsets = guideOffsets.sample(maskSampler, uv);
            float3 a = float3(coefficients.r, coefficients.g, coefficients.b);
            float3 b = float3(coefficients.a, offsets.r, offsets.g);
            float guide = dot(source.rgb, kLumaWeights);
            smoothed = clamp(a * guide + b, 0.0, 1.0);
        }

        float3 color = mix(
            source.rgb,
            smoothed,
            0.85 * params.smoothing * skin
        );

        float luma = dot(color, kLumaWeights);
        float whiten = params.whitening * skin;
        float targetLuma = luma + (1.0 - luma) * 0.22 * whiten;
        float3 whitened = color * (targetLuma / max(luma, 1e-4));
        whitened = mix(whitened, float3(targetLuma), 0.12 * whiten);
        color = whitened;

        float bright = params.brightening * skin;
        color = color + (1.0 - color) * 0.20 * bright;

        float eyeWeight = retouch.r * params.eyeBrightening;
        if (eyeWeight > 0.0) {
            float l = dot(color, kLumaWeights);
            float target = l + (1.0 - l) * 0.45 * eyeWeight;
            float3 value = color * (target / max(l, 1e-4));
            value = mix(value, float3(target), 0.18 * eyeWeight);
            color = value;
        }

        float teethWeight = retouch.g * params.teethWhitening;
        if (teethWeight > 0.0) {
            float l = dot(color, kLumaWeights);
            float target = l + (1.0 - l) * 0.35 * teethWeight;
            float3 value = color * (target / max(l, 1e-4));
            value.b = value.b + (1.0 - value.b) * 0.15 * teethWeight;
            value = mix(value, float3(target), 0.08 * teethWeight);
            color = value;
        }

        float darkWeight = retouch.b * params.darkCircleRemoval;
        if (darkWeight > 0.0) {
            float l = dot(color, kLumaWeights);
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
            float baseLuma = dot(base.rgb, kLumaWeights);
            float sourceLuma = dot(source.rgb, kLumaWeights);
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

    /// 低分辨率统计量的下采样倍数。系数本身是平滑场，1/4 分辨率足够，
    /// 同时把引导滤波的开销降到全分辨率的 1/16。
    private static let guidedDownsample = 4

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let composePipeline: MTLComputePipelineState
    private let statsPipeline: MTLComputePipelineState
    private let coefficientsPipeline: MTLComputePipelineState
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

        func makePipeline(_ name: String) throws -> MTLComputePipelineState {
            guard let function = library.makeFunction(name: name) else {
                throw SkinRenderError.missingFunction
            }
            do {
                return try resolved.makeComputePipelineState(function: function)
            } catch {
                throw SkinRenderError.pipelineCreation(error.localizedDescription)
            }
        }

        self.device = resolved
        self.commandQueue = queue
        self.composePipeline = try makePipeline("beautyCompose")
        self.statsPipeline = try makePipeline("guidedStats")
        self.coefficientsPipeline = try makePipeline("guidedCoefficients")
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

        guard let skinTexture = makeSkinTexture(skinMask) else {
            throw SkinRenderError.textureCreation
        }
        guard let retouchTexture = makeRetouchTexture(retouchMask) else {
            throw SkinRenderError.textureCreation
        }
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            throw SkinRenderError.commandEncoderCreation
        }

        let needsSmoothing = parameters.smoothing > 0
        let needsBlemish = parameters.blemishRemoval > 0

        // 去痘印的参考底色仍是高斯低频：这里要的是「把瑕疵平均掉」的
        // 大尺度均值，保边反而会保留瑕疵本身。
        let blemishBaseTexture = try makeBlurredTexture(
            source: source,
            descriptor: descriptor,
            required: needsBlemish
        )
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

        var coefficientTexture = source
        var offsetTexture = source
        if needsSmoothing {
            let coefficients = try encodeGuidedFilter(
                commandBuffer: commandBuffer,
                source: source,
                longEdge: max(image.width, image.height),
                smoothing: parameters.smoothing
            )
            coefficientTexture = coefficients.a
            offsetTexture = coefficients.b
        }

        guard let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw SkinRenderError.commandEncoderCreation
        }
        encoder.setComputePipelineState(composePipeline)
        encoder.setTexture(source, index: 0)
        encoder.setTexture(coefficientTexture, index: 1)
        encoder.setTexture(offsetTexture, index: 2)
        encoder.setTexture(blemishBaseTexture, index: 3)
        encoder.setTexture(skinTexture, index: 4)
        encoder.setTexture(retouchTexture, index: 5)
        encoder.setTexture(outputTexture, index: 6)

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
        dispatch(
            encoder,
            pipeline: composePipeline,
            width: image.width,
            height: image.height
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

    // MARK: - 引导滤波

    /// 在同一个 command buffer 里编码引导滤波的四个阶段，返回放大后可直接
    /// 采样的两张系数纹理：`a`（存 aR/aG/aB/bR）与 `b`（存 bG/bB）。
    private func encodeGuidedFilter(
        commandBuffer: MTLCommandBuffer,
        source: MTLTexture,
        longEdge: Int,
        smoothing: Float
    ) throws -> (a: MTLTexture, b: MTLTexture) {
        let step = Self.guidedDownsample
        let lowWidth = max(1, (source.width + step - 1) / step)
        let lowHeight = max(1, (source.height + step - 1) / step)

        func makeLowResTexture() throws -> MTLTexture {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .rgba16Float,
                width: lowWidth,
                height: lowHeight,
                mipmapped: false
            )
            descriptor.usage = [.shaderRead, .shaderWrite]
            descriptor.storageMode = .private
            guard let texture = device.makeTexture(descriptor: descriptor) else {
                throw SkinRenderError.textureCreation
            }
            return texture
        }

        let statsA = try makeLowResTexture()
        let statsB = try makeLowResTexture()
        let meanA = try makeLowResTexture()
        let meanB = try makeLowResTexture()
        let rawCoefficients = try makeLowResTexture()
        let rawOffsets = try makeLowResTexture()
        let coefficients = try makeLowResTexture()
        let offsets = try makeLowResTexture()

        var guided = GuidedParameters(
            epsilon: guidedEpsilon(smoothing: smoothing),
            downsample: Float(step)
        )
        let guidedLength = MemoryLayout<GuidedParameters>.size

        // 1) 低分辨率统计量
        guard let statsEncoder = commandBuffer.makeComputeCommandEncoder() else {
            throw SkinRenderError.commandEncoderCreation
        }
        statsEncoder.setComputePipelineState(statsPipeline)
        statsEncoder.setTexture(source, index: 0)
        statsEncoder.setTexture(statsA, index: 1)
        statsEncoder.setTexture(statsB, index: 2)
        statsEncoder.setBytes(&guided, length: guidedLength, index: 0)
        dispatch(
            statsEncoder,
            pipeline: statsPipeline,
            width: lowWidth,
            height: lowHeight
        )
        statsEncoder.endEncoding()

        // 2) 统计量方框滤波 → 均值
        let radius = guidedLowRadius(
            longEdge: longEdge,
            smoothing: smoothing,
            step: step
        )
        let box = MPSImageBox(
            device: device,
            kernelWidth: 2 * radius + 1,
            kernelHeight: 2 * radius + 1
        )
        box.edgeMode = .clamp
        box.encode(
            commandBuffer: commandBuffer,
            sourceTexture: statsA,
            destinationTexture: meanA
        )
        box.encode(
            commandBuffer: commandBuffer,
            sourceTexture: statsB,
            destinationTexture: meanB
        )

        // 3) 由统计量求局部线性系数 a / b
        guard let coefficientsEncoder = commandBuffer.makeComputeCommandEncoder() else {
            throw SkinRenderError.commandEncoderCreation
        }
        coefficientsEncoder.setComputePipelineState(coefficientsPipeline)
        coefficientsEncoder.setTexture(meanA, index: 0)
        coefficientsEncoder.setTexture(meanB, index: 1)
        coefficientsEncoder.setTexture(rawCoefficients, index: 2)
        coefficientsEncoder.setTexture(rawOffsets, index: 3)
        coefficientsEncoder.setBytes(&guided, length: guidedLength, index: 0)
        dispatch(
            coefficientsEncoder,
            pipeline: coefficientsPipeline,
            width: lowWidth,
            height: lowHeight
        )
        coefficientsEncoder.endEncoding()

        // 4) 系数再方框滤波，得到可用的平滑场
        box.encode(
            commandBuffer: commandBuffer,
            sourceTexture: rawCoefficients,
            destinationTexture: coefficients
        )
        box.encode(
            commandBuffer: commandBuffer,
            sourceTexture: rawOffsets,
            destinationTexture: offsets
        )

        return (coefficients, offsets)
    }

    /// 引导滤波的窗口半径（低分辨率像素）。与旧的磨皮 sigma 大致对应：
    /// 1 个「1024 基准像素」≈ 1 个低分辨率像素。
    private func guidedLowRadius(
        longEdge: Int,
        smoothing: Float,
        step: Int
    ) -> Int {
        let scale = max(1, Float(longEdge) / 1024)
        let fullRadius = scale * (3.0 + 9.0 * smoothing)
        return max(1, Int((fullRadius / Float(step)).rounded()))
    }

    /// 正则项 eps 控制「多强的边缘才被保留」。
    /// 局部方差远小于 eps 时 `a → 0`，输出趋近局部均值（纹理被抹平）；
    /// 远大于 eps 时 `a → 1`，输出趋近原图（边缘保留）。半平滑点落在
    /// 标准差 ≈ √eps 处：eps=0.05 对应「亮度标准差 0.22 以下都算纹理」，
    /// 足以吃掉皱纹与毛孔，而眉毛、发丝、眼白、唇线的方差高出这个量级，
    /// 仍会被完整保留。
    private func guidedEpsilon(smoothing: Float) -> Float {
        0.010 + 0.040 * smoothing
    }

    private func dispatch(
        _ encoder: MTLComputeCommandEncoder,
        pipeline: MTLComputePipelineState,
        width: Int,
        height: Int
    ) {
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

    /// 去痘印的低频参考尺度：约等于 8 个「1024 基准像素」，
    /// 需明显大于痘印本身，才能把瑕疵平均掉；同时设上限控制 MPS 卷积开销。
    private func blemishBaseSigma(for image: CGImage) -> Float {
        let longEdge = Float(max(image.width, image.height))
        let scale = max(0.4, longEdge / 1024)
        return min(max(3.0, scale * 8), 24.0)
    }
}
