import CoreGraphics
import Foundation
import Metal
import BFAlgorithms

/// 程序化美妆渲染器（Metal）。
///
/// 在**几何 warp 之后**执行（ADR-007）：蒙版由形变后的关键点生成，
/// 着色作用在形变后的图像上，天然与五官对齐。
///
/// 混合方式（ADR-008：颜色 + 蒙版 + 混合模式，无美术素材）：
///
/// - **口红**：亮度保持着色——`tint = 颜色 × (像素亮度 / 颜色亮度)`，
///   唇纹与明暗完整保留，只替换色相，唇部受光不丢质感；
/// - **腮红 / 眼影**：向目标色低权重混合（叠在皮肤上，保纹理）；
/// - **眉毛**：向深色混合（加深）。
public final class MakeupRenderer {
    private struct GPUParameters {
        var lipStrength: Float
        var blushStrength: Float
        var browStrength: Float
        var shadowStrength: Float
        var lipColor: SIMD4<Float>
        var blushColor: SIMD4<Float>
        var browColor: SIMD4<Float>
        var shadowColor: SIMD4<Float>
    }

    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    constant float3 kLumaWeights = float3(0.299, 0.587, 0.114);

    struct MakeupParams {
        float lipStrength;
        float blushStrength;
        float browStrength;
        float shadowStrength;
        float4 lipColor;
        float4 blushColor;
        float4 browColor;
        float4 shadowColor;
    };

    kernel void makeupCompose(
        texture2d<float, access::read> source [[texture(0)]],
        texture2d<float, access::sample> makeupMask [[texture(1)]],
        texture2d<float, access::write> output [[texture(2)]],
        constant MakeupParams &params [[buffer(0)]],
        uint2 gid [[thread_position_in_grid]]
    ) {
        if (gid.x >= source.get_width() || gid.y >= source.get_height()) {
            return;
        }

        float4 src = source.read(gid);
        float2 uv = (float2(gid) + 0.5)
            / float2(source.get_width(), source.get_height());
        constexpr sampler maskSampler(
            coord::normalized,
            filter::linear,
            address::clamp_to_edge
        );
        float4 mask = clamp(
            makeupMask.sample(maskSampler, uv),
            0.0,
            1.0
        );

        float3 color = src.rgb;
        float luma = dot(color, kLumaWeights);

        // 口红：色度替换、亮度保持（保唇纹与明暗）。
        // 直接用「目标色 chroma + 像素亮度」合成，避免高光下 tint
        // 被 clamp 到 1.0 后亮度整体下坠。
        float w = mask.r * params.lipStrength * 0.85;
        if (w > 0.0) {
            float3 chroma = params.lipColor.rgb
                - dot(params.lipColor.rgb, kLumaWeights);
            float3 tint = clamp(luma + chroma, 0.0, 1.0);
            color = mix(color, tint, w);
        }

        // 腮红 / 眼影：低权重叠色，保皮肤纹理
        float wg = mask.g * params.blushStrength * 0.35;
        if (wg > 0.0) {
            color = mix(color, params.blushColor.rgb, wg);
        }

        // 眉毛加深
        float wb = mask.b * params.browStrength * 0.60;
        if (wb > 0.0) {
            color = mix(color, params.browColor.rgb, wb);
        }

        // 眼影
        float wa = mask.a * params.shadowStrength * 0.40;
        if (wa > 0.0) {
            color = mix(color, params.shadowColor.rgb, wa);
        }

        output.write(float4(clamp(color, 0.0, 1.0), src.a), gid);
    }
    """

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let composePipeline: MTLComputePipelineState
    private let converter: TextureConverter

    public init(device: MTLDevice? = nil) throws {
        guard let resolved = device ?? MTLCreateSystemDefaultDevice() else {
            throw SkinRenderError.noMetalDevice
        }
        guard let queue = resolved.makeCommandQueue() else {
            throw SkinRenderError.commandEncoderCreation
        }
        self.device = resolved
        self.commandQueue = queue
        self.converter = try TextureConverter(device: resolved)

        let library: MTLLibrary
        do {
            library = try resolved.makeLibrary(
                source: Self.shaderSource,
                options: nil
            )
        } catch {
            throw SkinRenderError.shaderCompilation(error.localizedDescription)
        }
        guard let function = library.makeFunction(name: "makeupCompose") else {
            throw SkinRenderError.missingFunction
        }
        do {
            self.composePipeline = try resolved.makeComputePipelineState(
                function: function
            )
        } catch {
            throw SkinRenderError.pipelineCreation(error.localizedDescription)
        }
    }

    public func render(
        image: CGImage,
        mask: MakeupMask,
        parameters: MakeupParameters
    ) throws -> CGImage {
        guard !parameters.isIdentity, !mask.isEmpty else {
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
        guard let maskTexture = makeMaskTexture(mask) else {
            throw SkinRenderError.textureCreation
        }
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            throw SkinRenderError.commandEncoderCreation
        }
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw SkinRenderError.commandEncoderCreation
        }

        var gpuParameters = GPUParameters(
            lipStrength: parameters.lipstick,
            blushStrength: parameters.blush,
            browStrength: parameters.brow,
            shadowStrength: parameters.eyeshadow,
            lipColor: SIMD4<Float>(
                parameters.lipstickColor.red,
                parameters.lipstickColor.green,
                parameters.lipstickColor.blue,
                0
            ),
            blushColor: SIMD4<Float>(
                parameters.blushColor.red,
                parameters.blushColor.green,
                parameters.blushColor.blue,
                0
            ),
            browColor: SIMD4<Float>(
                parameters.browColor.red,
                parameters.browColor.green,
                parameters.browColor.blue,
                0
            ),
            shadowColor: SIMD4<Float>(
                parameters.eyeshadowColor.red,
                parameters.eyeshadowColor.green,
                parameters.eyeshadowColor.blue,
                0
            )
        )

        encoder.setComputePipelineState(composePipeline)
        encoder.setTexture(source, index: 0)
        encoder.setTexture(maskTexture, index: 1)
        encoder.setTexture(outputTexture, index: 2)
        encoder.setBytes(
            &gpuParameters,
            length: MemoryLayout<GPUParameters>.size,
            index: 0
        )
        let threadWidth = composePipeline.threadExecutionWidth
        let threadHeight = max(
            1,
            composePipeline.maxTotalThreadsPerThreadgroup / threadWidth
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

    private func makeMaskTexture(_ mask: MakeupMask) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
            width: mask.width,
            height: mask.height,
            mipmapped: false
        )
        descriptor.usage = .shaderRead
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            return nil
        }

        var bytes = [UInt8](repeating: 0, count: mask.width * mask.height * 4)
        for index in 0..<(mask.width * mask.height) {
            bytes[index * 4] = UInt8(
                (min(max(mask.lip[index], 0), 1) * 255).rounded()
            )
            bytes[index * 4 + 1] = UInt8(
                (min(max(mask.blush[index], 0), 1) * 255).rounded()
            )
            bytes[index * 4 + 2] = UInt8(
                (min(max(mask.brow[index], 0), 1) * 255).rounded()
            )
            bytes[index * 4 + 3] = UInt8(
                (min(max(mask.shadow[index], 0), 1) * 255).rounded()
            )
        }
        bytes.withUnsafeBytes { buffer in
            texture.replace(
                region: MTLRegionMake2D(0, 0, mask.width, mask.height),
                mipmapLevel: 0,
                withBytes: buffer.baseAddress!,
                bytesPerRow: mask.width * 4
            )
        }
        return texture
    }
}
