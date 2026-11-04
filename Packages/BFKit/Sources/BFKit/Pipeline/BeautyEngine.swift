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
    /// 脸型形变场（未启用脸型时为 nil）。美妆阶段用同一映射变换关键点
    /// （ADR-007），保证形变与美妆不错位。
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

/// M3-M5 美化管线：解码 → 检测 → 蒙版 → 颜色与平滑 → 单次几何 warp。
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
        let detection = try detector.detect(image: decoded.image)
        let generator = SkinMaskGenerator(
            targetLongEdge: quality.maskLongEdge
        )
        let skinMask = try generator.generate(
            image: decoded.image,
            detection: detection
        )
        let retouchMask = try RetouchMaskGenerator().generate(
            image: decoded.image,
            detection: detection,
            skinMask: skinMask
        )
        let rendered = try renderer.render(
            image: decoded.image,
            skinMask: skinMask,
            retouchMask: retouchMask,
            parameters: parameters
        )

        // 几何：颜色处理之后做单次 warp（ADR-007）。
        var warped = rendered
        var field: DisplacementField?
        if !parameters.faceShape.isIdentity {
            let faces = FaceGeometryConverter.convert(detection: detection)
            if !faces.isEmpty {
                field = DisplacementField.solve(
                    faces: faces,
                    imageSize: (
                        width: decoded.image.width,
                        height: decoded.image.height
                    ),
                    parameters: parameters.faceShape
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
            detection: detection,
            skinMask: skinMask,
            retouchMask: retouchMask,
            parameters: parameters,
            originalSize: decoded.originalSize,
            wasDownscaled: decoded.wasDownscaled,
            quality: quality,
            displacementField: field
        )
    }
}
