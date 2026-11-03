import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// 源图元数据：EXIF / TIFF / GPS 等属性、方向、颜色空间与原始格式。
public struct ImageMetadata {
    public let properties: [CFString: Any]
    public let orientation: CGImagePropertyOrientation
    public let colorSpace: CGColorSpace?
    public let sourceType: UTType?

    public init(
        properties: [CFString: Any],
        orientation: CGImagePropertyOrientation,
        colorSpace: CGColorSpace?,
        sourceType: UTType?
    ) {
        self.properties = properties
        self.orientation = orientation
        self.colorSpace = colorSpace
        self.sourceType = sourceType
    }
}
