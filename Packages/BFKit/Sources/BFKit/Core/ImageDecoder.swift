import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public struct DecodedImage {
    public let image: CGImage
    public let metadata: ImageMetadata
    public let originalSize: CGSize
    public let wasDownscaled: Bool

    public init(
        image: CGImage,
        metadata: ImageMetadata,
        originalSize: CGSize,
        wasDownscaled: Bool
    ) {
        self.image = image
        self.metadata = metadata
        self.originalSize = originalSize
        self.wasDownscaled = wasDownscaled
    }
}

public enum ImageDecodingError: Error, LocalizedError {
    case invalidMaxLongEdge
    case cannotOpenSource
    case cannotDecodeImage

    public var errorDescription: String? {
        switch self {
        case .invalidMaxLongEdge:
            return "maxLongEdge 必须大于 0"
        case .cannotOpenSource:
            return "无法读取图片数据"
        case .cannotDecodeImage:
            return "无法解码图片"
        }
    }
}

public enum ImageDecoder {
    public static func decode(
        url: URL,
        maxLongEdge: Int = WorkingLimits.maxLongEdge
    ) throws -> DecodedImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw ImageDecodingError.cannotOpenSource
        }
        return try decode(source: source, maxLongEdge: maxLongEdge)
    }

    public static func decode(
        data: Data,
        maxLongEdge: Int = WorkingLimits.maxLongEdge
    ) throws -> DecodedImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            throw ImageDecodingError.cannotOpenSource
        }
        return try decode(source: source, maxLongEdge: maxLongEdge)
    }

    static func decode(
        source: CGImageSource,
        maxLongEdge: Int
    ) throws -> DecodedImage {
        guard maxLongEdge > 0 else {
            throw ImageDecodingError.invalidMaxLongEdge
        }

        let properties = (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]) ?? [:]
        let orientationRaw = (properties[kCGImagePropertyOrientation] as? NSNumber)?.uint32Value ?? 1
        let orientation = CGImagePropertyOrientation(rawValue: orientationRaw) ?? .up

        let pixelWidth = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
        let pixelHeight = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
        var originalSize = CGSize(width: pixelWidth, height: pixelHeight)
        if orientation.swapsDimensions {
            originalSize = CGSize(width: originalSize.height, height: originalSize.width)
        }

        let longEdge = max(originalSize.width, originalSize.height)
        let needsDownscale = longEdge > CGFloat(maxLongEdge)

        let image: CGImage
        if !needsDownscale && orientation == .up {
            guard let fullImage = CGImageSourceCreateImageAtIndex(
                source,
                0,
                [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
            ) else {
                throw ImageDecodingError.cannotDecodeImage
            }
            image = fullImage
        } else {
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxLongEdge,
                kCGImageSourceShouldCacheImmediately: true,
            ]
            guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(
                source,
                0,
                options as CFDictionary
            ) else {
                throw ImageDecodingError.cannotDecodeImage
            }
            image = thumbnail
        }

        if originalSize == .zero {
            originalSize = CGSize(width: image.width, height: image.height)
        }

        let sourceType = CGImageSourceGetType(source).flatMap { UTType($0 as String) }
        let metadata = ImageMetadata(
            properties: properties,
            orientation: orientation,
            colorSpace: image.colorSpace,
            sourceType: sourceType
        )

        return DecodedImage(
            image: image,
            metadata: metadata,
            originalSize: originalSize,
            wasDownscaled: needsDownscale
        )
    }
}

private extension CGImagePropertyOrientation {
    var swapsDimensions: Bool {
        switch self {
        case .left, .leftMirrored, .right, .rightMirrored:
            return true
        default:
            return false
        }
    }
}
