import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum ImageEncodingError: Error, LocalizedError {
    case cannotCreateDestination
    case cannotFinalize

    public var errorDescription: String? {
        switch self {
        case .cannotCreateDestination:
            return "无法创建输出文件"
        case .cannotFinalize:
            return "无法写入图片数据"
        }
    }
}

public enum ImageEncoder {
    public static func encode(
        _ image: CGImage,
        metadata: ImageMetadata,
        to url: URL,
        type: UTType,
        quality: Double = 0.95
    ) throws {
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            type.identifier as CFString,
            1,
            nil
        ) else {
            throw ImageEncodingError.cannotCreateDestination
        }

        add(image, metadata: metadata, to: destination, type: type, quality: quality)

        guard CGImageDestinationFinalize(destination) else {
            throw ImageEncodingError.cannotFinalize
        }
    }

    public static func data(
        _ image: CGImage,
        metadata: ImageMetadata,
        type: UTType,
        quality: Double = 0.95
    ) throws -> Data {
        guard let output = CFDataCreateMutable(nil, 0),
              let destination = CGImageDestinationCreateWithData(
                output,
                type.identifier as CFString,
                1,
                nil
              ) else {
            throw ImageEncodingError.cannotCreateDestination
        }

        add(image, metadata: metadata, to: destination, type: type, quality: quality)

        guard CGImageDestinationFinalize(destination) else {
            throw ImageEncodingError.cannotFinalize
        }

        return output as Data
    }

    private static func add(
        _ image: CGImage,
        metadata: ImageMetadata,
        to destination: CGImageDestination,
        type: UTType,
        quality: Double
    ) {
        var properties = metadata.properties
        properties[kCGImagePropertyOrientation] = 1
        properties[kCGImagePropertyPixelWidth] = image.width
        properties[kCGImagePropertyPixelHeight] = image.height

        var exif = (properties[kCGImagePropertyExifDictionary] as? [CFString: Any]) ?? [:]
        exif[kCGImagePropertyExifPixelXDimension] = image.width
        exif[kCGImagePropertyExifPixelYDimension] = image.height
        properties[kCGImagePropertyExifDictionary] = exif

        properties[kCGImageDestinationEmbedThumbnail] = false
        properties[kCGImageDestinationOptimizeColorForSharing] = false

        if type.conforms(to: .jpeg) {
            properties[kCGImageDestinationLossyCompressionQuality] = min(max(quality, 0), 1)
        }

        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
    }
}
