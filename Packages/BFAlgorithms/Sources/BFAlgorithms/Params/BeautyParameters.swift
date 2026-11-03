/// 人像美化参数。所有强度均为 0...1，超出范围会被裁剪。
public struct BeautyParameters: Equatable, Sendable {
    /// 磨皮强度。
    public var smoothing: Float
    /// 美白/淡化肤色强度。
    public var whitening: Float
    /// 增亮/提亮强度。
    public var brightening: Float

    public init(
        smoothing: Float = 0,
        whitening: Float = 0,
        brightening: Float = 0
    ) {
        self.smoothing = Self.clamp(smoothing)
        self.whitening = Self.clamp(whitening)
        self.brightening = Self.clamp(brightening)
    }

    /// 默认自然预设：轻度磨皮、美白与提亮。
    public static let natural = BeautyParameters(
        smoothing: 0.35,
        whitening: 0.25,
        brightening: 0.20
    )

    public static let none = BeautyParameters()

    public var isIdentity: Bool {
        smoothing == 0 && whitening == 0 && brightening == 0
    }

    public static func clamp(_ value: Float) -> Float {
        guard value.isFinite else { return 0 }
        return min(max(value, 0), 1)
    }
}
