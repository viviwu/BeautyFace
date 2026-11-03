import CoreGraphics

public struct SegmentationMask: Sendable {
    public let width: Int
    public let height: Int
    /// 单通道 0...255，行优先。
    public let pixels: [UInt8]

    public init(width: Int, height: Int, pixels: [UInt8]) {
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    public var isEmpty: Bool {
        width == 0 || height == 0 || pixels.isEmpty
    }

    public func value(x: Int, y: Int) -> UInt8? {
        guard x >= 0, x < width, y >= 0, y < height else { return nil }
        return pixels[y * width + x]
    }

    public func normalizedValue(x: Int, y: Int) -> Float? {
        guard let value = value(x: x, y: y) else { return nil }
        return Float(value) / 255
    }
}
