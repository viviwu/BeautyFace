import CoreGraphics
import Foundation
import BFAlgorithms

public enum BeautyQuality: Equatable, Sendable {
    /// 交互预览：长边 1024。
    case preview
    /// 全分辨率：长边不超过 4096。
    case full

    public var maxLongEdge: Int {
        switch self {
        case .preview: return 1024
        case .full: return WorkingLimits.maxLongEdge
        }
    }

    public var maskLongEdge: Int {
        switch self {
        case .preview: return 256
        case .full: return 512
        }
    }
}

/// 与图片、质量绑定的分析结果。检测与蒙版在参数调节期间保持不变，
/// 由 App 缓存后反复送入 `render(analysis:parameters:)`（README 3.3）。
/// 质量变化时（预览 → 全分辨率）必须重新分析，因为蒙版分辨率与像素坐标不同。
public struct BeautyAnalysis {
    public let decoded: DecodedImage
    public let detection: DetectionResult
    public let skinMask: SkinMask
    public let retouchMask: RetouchMask
    public let quality: BeautyQuality

    public init(
        decoded: DecodedImage,
        detection: DetectionResult,
        skinMask: SkinMask,
        retouchMask: RetouchMask,
        quality: BeautyQuality
    ) {
        self.decoded = decoded
        self.detection = detection
        self.skinMask = skinMask
        self.retouchMask = retouchMask
        self.quality = quality
    }
}

public struct BeautyResult {
    public let image: CGImage
    public let metadata: ImageMetadata
    public let detection: DetectionResult
    public let skinMask: SkinMask
    public let retouchMask: RetouchMask
    public let parameters: BeautyParameters
    public let originalSize: CGSize
    public let wasDownscaled: Bool
    public let quality: BeautyQuality
    /// 脸型与五官形变场（未启用形变时为 nil）。美妆阶段用同一映射变换
    /// 关键点（ADR-007），保证形变与美妆不错位。
    public let displacementField: DisplacementField?

    public init(
        image: CGImage,
        metadata: ImageMetadata,
        detection: DetectionResult,
        skinMask: SkinMask,
        retouchMask: RetouchMask,
        parameters: BeautyParameters,
        originalSize: CGSize,
        wasDownscaled: Bool,
        quality: BeautyQuality,
        displacementField: DisplacementField? = nil
    ) {
        self.image = image
        self.metadata = metadata
        self.detection = detection
        self.skinMask = skinMask
        self.retouchMask = retouchMask
        self.parameters = parameters
        self.originalSize = originalSize
        self.wasDownscaled = wasDownscaled
        self.quality = quality
        self.displacementField = displacementField
    }
}

/// M3-M6 美化管线：解码 → 检测 → 蒙版 → 颜色与平滑 → 单次几何 warp。
public final class BeautyEngine {
    public let detector: FaceDetector
    public let renderer: SkinRenderer
    public let warpRenderer: WarpRenderer

    public init(
        detector: FaceDetector = FaceDetector(),
        renderer: SkinRenderer? = nil,
        warpRenderer: WarpRenderer? = nil
    ) throws {
        self.detector = detector
        self.renderer = try renderer ?? SkinRenderer()
        self.warpRenderer = try warpRenderer ?? WarpRenderer()
    }

    public func process(
        url: URL,
        parameters: BeautyParameters = .natural,
        quality: BeautyQuality = .full
    ) throws -> BeautyResult {
        let decoded = try ImageDecoder.decode(
            url: url,
            maxLongEdge: quality.maxLongEdge
        )
        return try process(
            decoded: decoded,
            parameters: parameters,
            quality: quality
        )
    }

    public func process(
        data: Data,
        parameters: BeautyParameters = .natural,
        quality: BeautyQuality = .full
    ) throws -> BeautyResult {
        let decoded = try ImageDecoder.decode(
            data: data,
            maxLongEdge: quality.maxLongEdge
        )
        return try process(
            decoded: decoded,
            parameters: parameters,
            quality: quality
        )
    }

    public func process(
        decoded: DecodedImage,
        parameters: BeautyParameters = .natural,
        quality: BeautyQuality = .full
    ) throws -> BeautyResult {
        let analysis = try analyze(decoded: decoded, quality: quality)
        return try render(analysis: analysis, parameters: parameters)
    }

    /// 一次性的检测与蒙版生成。结果可跨多次参数调节复用。
    public func analyze(
        decoded: DecodedImage,
        quality: BeautyQuality = .preview
    ) throws -> BeautyAnalysis {
        let detection = try detector.detect(image: decoded.image)
        let generator = SkinMaskGenerator(targetLongEdge: quality.maskLongEdge)
        let skinMask = try generator.generate(
            image: decoded.image,
            detection: detection
        )
        let retouchMask = try RetouchMaskGenerator().generate(
            image: decoded.image,
            detection: detection,
            skinMask: skinMask
        )
        return BeautyAnalysis(
            decoded: decoded,
            detection: detection,
            skinMask: skinMask,
            retouchMask: retouchMask,
            quality: quality
        )
    }

    /// 用缓存的分析结果渲染：跳过解码、检测与蒙版，只做颜色 / 平滑与几何。
    /// 拖滑杆时调用此方法，避免每次重新跑 Vision。
    public func render(
        analysis: BeautyAnalysis,
        parameters: BeautyParameters = .natural
    ) throws -> BeautyResult {
        let decoded = analysis.decoded
        let rendered = try renderer.render(
            image: decoded.image,
            skinMask: analysis.skinMask,
            retouchMask: analysis.retouchMask,
            parameters: parameters
        )

        // 几何：颜色处理之后做单次 warp（ADR-007）。
        var warped = rendered
        var field: DisplacementField?
        if !parameters.faceShape.isIdentity || !parameters.faceFeature.isIdentity {
            let faces = FaceGeometryConverter.convert(detection: analysis.detection)
            if !faces.isEmpty {
                field = DisplacementField.solve(
                    faces: faces,
                    imageSize: (
                        width: decoded.image.width,
                        height: decoded.image.height
                    ),
                    parameters: parameters.faceShape,
                    features: parameters.faceFeature
                )
                if let field {
                    warped = try warpRenderer.render(
                        image: rendered,
                        field: field
                    )
                }
            }
        }

        return BeautyResult(
            image: warped,
            metadata: decoded.metadata,
            detection: analysis.detection,
            skinMask: analysis.skinMask,
            retouchMask: analysis.retouchMask,
            parameters: parameters,
            originalSize: decoded.originalSize,
            wasDownscaled: decoded.wasDownscaled,
            quality: analysis.quality,
            displacementField: field
        )
    }
}
