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
    public let parameters: BeautyParameters
    public let originalSize: CGSize
    public let wasDownscaled: Bool
    public let quality: BeautyQuality

    public init(
        image: CGImage,
        metadata: ImageMetadata,
        detection: DetectionResult,
        skinMask: SkinMask,
        parameters: BeautyParameters,
        originalSize: CGSize,
        wasDownscaled: Bool,
        quality: BeautyQuality
    ) {
        self.image = image
        self.metadata = metadata
        self.detection = detection
        self.skinMask = skinMask
        self.parameters = parameters
        self.originalSize = originalSize
        self.wasDownscaled = wasDownscaled
        self.quality = quality
    }
}

/// M3 美化管线：解码 → 检测 → 皮肤蒙版 → Metal 磨皮/美白/提亮。
public final class BeautyEngine {
    public let detector: FaceDetector
    public let renderer: SkinRenderer

    public init(
        detector: FaceDetector = FaceDetector(),
        renderer: SkinRenderer? = nil
    ) throws {
        self.detector = detector
        self.renderer = try renderer ?? SkinRenderer()
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
        let rendered = try renderer.render(
            image: decoded.image,
            skinMask: skinMask,
            parameters: parameters
        )

        return BeautyResult(
            image: rendered,
            metadata: decoded.metadata,
            detection: detection,
            skinMask: skinMask,
            parameters: parameters,
            originalSize: decoded.originalSize,
            wasDownscaled: decoded.wasDownscaled,
            quality: quality
        )
    }
}
