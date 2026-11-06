import CoreGraphics
import Foundation
import Metal
import BFAlgorithms

public enum WarpRenderError: Error, LocalizedError {
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
            return "形变着色器编译失败：\(message)"
        case .missingFunction:
            return "形变着色器缺少入口函数"
        case .pipelineCreation(let message):
            return "形变管线创建失败：\(message)"
        case .textureCreation:
            return "无法创建形变纹理"
        case .commandEncoderCreation:
            return "无法创建形变命令编码器"
        case .commandFailed(let message):
            return "形变命令执行失败：\(message)"
        }
    }
}

/// 几何形变渲染器：按位移场对图像做**单次**重采样（ADR-006）。
///
/// 位移场在 CPU 上以粗网格求出（`DisplacementField`），以 `rgba16Float`
/// 纹理上传；kernel 对每个输出像素双线性采样位移，加到像素坐标上得到
/// 源图位置，再双线性采样源图。整张图只重采样一次，不叠加模糊。
public final class WarpRenderer {
    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    kernel void warpResample(
        texture2d<float, access::sample> source [[texture(0)]],
        texture2d<float, access::sample> displacement [[texture(1)]],
        texture2d<float, access::write> output [[texture(2)]],
        uint2 gid [[thread_position_in_grid]]
    ) {
        if (gid.x >= output.get_width() || gid.y >= output.get_height()) {
            return;
        }

        float2 size = float2(output.get_width(), output.get_height());
        constexpr sampler sampler2d(
            coord::normalized,
            filter::linear,
            address::clamp_to_edge
        );

        float2 uv = (float2(gid) + 0.5) / size;
        // 位移场在粗网格上求解、此处双线性放大，本身就是平滑场
        float2 offset = displacement.sample(sampler2d, uv).xy;
        // 源位置 = 输出像素 + 位移；位移以像素为单位
        float2 sourceUV = (float2(gid) + 0.5 + offset) / size;
        float4 color = source.sample(sampler2d, sourceUV);

        output.write(color, gid);
    }
    """

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let pipeline: MTLComputePipelineState
    private let converter: TextureConverter

    public init(device: MTLDevice? = nil) throws {
        guard let resolved = device ?? MTLCreateSystemDefaultDevice() else {
            throw WarpRenderError.noMetalDevice
        }
        guard let queue = resolved.makeCommandQueue() else {
            throw WarpRenderError.commandEncoderCreation
        }

        let library: MTLLibrary
        do {
            library = try resolved.makeLibrary(
                source: Self.shaderSource,
                options: nil
            )
        } catch {
            throw WarpRenderError.shaderCompilation(error.localizedDescription)
        }

        guard let function = library.makeFunction(name: "warpResample") else {
            throw WarpRenderError.missingFunction
        }
        let pipeline: MTLComputePipelineState
        do {
            pipeline = try resolved.makeComputePipelineState(function: function)
        } catch {
            throw WarpRenderError.pipelineCreation(error.localizedDescription)
        }

        self.device = resolved
        self.commandQueue = queue
        self.pipeline = pipeline
        self.converter = try TextureConverter(device: resolved)
    }

    /// 按位移场重采样。位移场为空 / 全零时返回原图。
    public func render(
        image: CGImage,
        field: DisplacementField
    ) throws -> CGImage {
        guard field.maximumDisplacement() > 0.01 else {
            return image
        }

        let source = try converter.makeTexture(from: image)

        let outputDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float,
            width: image.width,
            height: image.height,
            mipmapped: false
        )
        outputDescriptor.usage = [.shaderRead, .shaderWrite]
        outputDescriptor.storageMode = .shared
        guard let output = device.makeTexture(descriptor: outputDescriptor) else {
            throw WarpRenderError.textureCreation
        }

        guard let displacement = makeDisplacementTexture(field) else {
            throw WarpRenderError.textureCreation
        }

        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            throw WarpRenderError.commandEncoderCreation
        }
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw WarpRenderError.commandEncoderCreation
        }
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(source, index: 0)
        encoder.setTexture(displacement, index: 1)
        encoder.setTexture(output, index: 2)

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
            throw WarpRenderError.commandFailed(error.localizedDescription)
        }

        return try converter.makeCGImage(
            from: output,
            colorSpace: image.colorSpace
        )
    }

    /// 位移场上传为 rgba16Float 纹理（r = dx，g = dy）。
    private func makeDisplacementTexture(_ field: DisplacementField) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float,
            width: field.columns,
            height: field.rows,
            mipmapped: false
        )
        descriptor.usage = .shaderRead
        descriptor.storageMode = .shared

        guard let texture = device.makeTexture(descriptor: descriptor) else {
            return nil
        }

        // 坐标约定换算（M8 修复，见 dev_ledger 3.12）：
        // - `DisplacementField` 的 row 0 对应 y 向上坐标 y = 0，即**图像下沿**；
        //   它与人脸 `FaceGeometry` 同为 y 向上，算法层（含颈部走廊、蒙版门）
        //   都在这个坐标系里求解。
        // - Metal 纹理 row 0 / 归一化 v = 0 对应**图像上沿**；kernel 的 gid
        //   也是光栅行序。源图纹理虽然也走光栅序，但 `CGContext.draw` 内部
        //   已把 CGImage 的 top-down 数据翻正，位移纹理没有这一步。
        // 因此上传时必须把场按行倒序，并把 dy 由 y 向上取反为光栅向下。
        // 少了这一步，形变会垂直镜像到对称位置（真实半身像上表现为
        // 脸型形变落到胸口、M8 颈部走廊跑到头顶），而居中合成脸因为
        // 上下近似对称，旧单测未能发现。
        var halfs = [Float16](
            repeating: 0,
            count: field.columns * field.rows * 4
        )
        for row in 0..<field.rows {
            let sourceRow = field.rows - 1 - row
            for column in 0..<field.columns {
                let source = sourceRow * field.columns + column
                let base = (row * field.columns + column) * 4
                halfs[base] = Float16(field.offsetX[source])
                halfs[base + 1] = Float16(-field.offsetY[source])
            }
        }

        halfs.withUnsafeBytes { buffer in
            texture.replace(
                region: MTLRegionMake2D(0, 0, field.columns, field.rows),
                mipmapLevel: 0,
                withBytes: buffer.baseAddress!,
                bytesPerRow: field.columns * 8
            )
        }
        return texture
    }
}
