import CoreGraphics
import Foundation

public struct ProcessedImage {
    public let image: CGImage
    public let metadata: ImageMetadata
    public let originalSize: CGSize
    public let wasDownscaled: Bool
    public let usedWorkingTexture: Bool

    public init(
        image: CGImage,
        metadata: ImageMetadata,
        originalSize: CGSize,
        wasDownscaled: Bool,
        usedWorkingTexture: Bool
    ) {
        self.image = image
        self.metadata = metadata
        self.originalSize = originalSize
        self.wasDownscaled = wasDownscaled
        self.usedWorkingTexture = usedWorkingTexture
    }
}

/// M1 恒等管线：解码 → rgba16Float 工作纹理 → 回读 CGImage。
public struct ImagePipeline {
    public let converter: TextureConverter?

    public init(converter: TextureConverter? = nil) {
        self.converter = converter
    }

    public func process(
        url: URL,
        maxLongEdge: Int = WorkingLimits.maxLongEdge
    ) throws -> ProcessedImage {
        try process(ImageDecoder.decode(url: url, maxLongEdge: maxLongEdge))
    }

    public func process(
        data: Data,
        maxLongEdge: Int = WorkingLimits.maxLongEdge
    ) throws -> ProcessedImage {
        try process(ImageDecoder.decode(data: data, maxLongEdge: maxLongEdge))
    }

    public func process(_ decoded: DecodedImage) throws -> ProcessedImage {
        let image: CGImage
        let usedWorkingTexture: Bool

        if let converter {
            let texture = try converter.makeTexture(from: decoded.image)
            image = try converter.makeCGImage(
                from: texture,
                colorSpace: decoded.metadata.colorSpace
            )
            usedWorkingTexture = true
        } else {
            image = decoded.image
            usedWorkingTexture = false
        }

        return ProcessedImage(
            image: image,
            metadata: decoded.metadata,
            originalSize: decoded.originalSize,
            wasDownscaled: decoded.wasDownscaled,
            usedWorkingTexture: usedWorkingTexture
        )
    }
}
