import CoreGraphics
import Foundation

/// 皮肤蒙版，值域 0...1，行优先、原点在左上角。
public struct SkinMask: Sendable {
    public let width: Int
    public let height: Int
    public let values: [Float]

    public init(width: Int, height: Int, values: [Float]) {
        precondition(width >= 0 && height >= 0)
        precondition(values.count == width * height)
        self.width = width
        self.height = height
        self.values = values
    }

    public var isEmpty: Bool {
        width == 0 || height == 0 || values.isEmpty
    }

    public var averageValue: Float {
        guard !values.isEmpty else { return 0 }
        return values.reduce(0, +) / Float(values.count)
    }

    public func value(x: Int, y: Int) -> Float? {
        guard x >= 0, x < width, y >= 0, y < height else { return nil }
        return values[y * width + x]
    }

    /// 生成 8-bit 灰度图，便于 AutoBeauty 输出蒙版调试图。
    public func makeCGImage() -> CGImage? {
        guard width > 0, height > 0 else { return nil }

        var bytes = [UInt8](repeating: 0, count: values.count)
        for index in values.indices {
            let value = min(max(values[index], 0), 1)
            bytes[index] = UInt8((value * 255).rounded())
        }

        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else {
            return nil
        }

        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 8,
            bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }
}
