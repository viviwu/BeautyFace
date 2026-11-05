import CoreGraphics

/// 美妆区域蒙版（低分辨率，GPU 采样时双线性放大）。
///
/// 通道：`lip`（口红）、`blush`（腮红）、`brow`（眉毛加深）、
/// `shadow`（眼影），取值 0...1，已含羽化。
public struct MakeupMask: Sendable {
    public let width: Int
    public let height: Int
    public var lip: [Float]
    public var blush: [Float]
    public var brow: [Float]
    public var shadow: [Float]

    public init(
        width: Int,
        height: Int,
        lip: [Float],
        blush: [Float],
        brow: [Float],
        shadow: [Float]
    ) {
        self.width = width
        self.height = height
        self.lip = lip
        self.blush = blush
        self.brow = brow
        self.shadow = shadow
    }

    public static let empty = MakeupMask(
        width: 1,
        height: 1,
        lip: [0],
        blush: [0],
        brow: [0],
        shadow: [0]
    )

    public var isEmpty: Bool {
        width * height == 1 && lip[0] == 0 && blush[0] == 0
            && brow[0] == 0 && shadow[0] == 0
    }

    /// 全通道裁剪回 0...1（羽化后可能出现轻微越界）。
    mutating func clampAll() {
        for index in lip.indices {
            lip[index] = min(max(lip[index], 0), 1)
            blush[index] = min(max(blush[index], 0), 1)
            brow[index] = min(max(brow[index], 0), 1)
            shadow[index] = min(max(shadow[index], 0), 1)
        }
    }

    /// 调试图：R=口红、G=腮红、B=眉+眼影，直观检查区域与羽化。
    public func makeDebugCGImage() -> CGImage? {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for index in 0..<(width * height) {
            bytes[index * 4] = UInt8(
                (min(max(lip[index], 0), 1) * 255).rounded()
            )
            bytes[index * 4 + 1] = UInt8(
                (min(max(blush[index], 0), 1) * 255).rounded()
            )
            bytes[index * 4 + 2] = UInt8(
                (min(max(brow[index] + shadow[index], 0), 1) * 255).rounded()
            )
            bytes[index * 4 + 3] = 255
        }
        return bytes.withUnsafeBytes { buffer -> CGImage? in
            guard let context = CGContext(
                data: UnsafeMutableRawPointer(mutating: buffer.baseAddress),
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return nil }
            return context.makeImage()
        }
    }
}
