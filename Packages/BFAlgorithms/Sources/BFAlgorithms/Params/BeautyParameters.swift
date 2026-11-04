/// 人像美化参数。所有强度均为 0...1，超出范围会被裁剪。
public struct BeautyParameters: Equatable, Sendable {
    /// 磨皮强度。
    public var smoothing: Float
    /// 美白/淡化肤色强度。
    public var whitening: Float
    /// 增亮/提亮强度。
    public var brightening: Float
    /// 亮眼（眼白提亮）强度。
    public var eyeBrightening: Float
    /// 白牙强度。
    public var teethWhitening: Float
    /// 去黑眼圈强度。
    public var darkCircleRemoval: Float
    /// 去黑点/痘印强度。
    public var blemishRemoval: Float
    /// 脸型形变（小脸 / 瘦脸 / 窄脸 / V 脸 / 下巴 / 额头 / 颧骨）。
    public var faceShape: FaceShapeParameters

    public init(
        smoothing: Float = 0,
        whitening: Float = 0,
        brightening: Float = 0,
        eyeBrightening: Float = 0,
        teethWhitening: Float = 0,
        darkCircleRemoval: Float = 0,
        blemishRemoval: Float = 0,
        faceShape: FaceShapeParameters = FaceShapeParameters()
    ) {
        self.smoothing = Self.clamp(smoothing)
        self.whitening = Self.clamp(whitening)
        self.brightening = Self.clamp(brightening)
        self.eyeBrightening = Self.clamp(eyeBrightening)
        self.teethWhitening = Self.clamp(teethWhitening)
        self.darkCircleRemoval = Self.clamp(darkCircleRemoval)
        self.blemishRemoval = Self.clamp(blemishRemoval)
        self.faceShape = faceShape
    }

    /// 默认自然预设：轻度磨皮、美白、提亮与局部修饰。
    public static let natural = BeautyParameters(
        smoothing: 0.35,
        whitening: 0.25,
        brightening: 0.20,
        eyeBrightening: 0.20,
        teethWhitening: 0.15,
        darkCircleRemoval: 0.25,
        blemishRemoval: 0.30
    )

    public static let none = BeautyParameters()

    public var isIdentity: Bool {
        smoothing == 0
            && whitening == 0
            && brightening == 0
            && eyeBrightening == 0
            && teethWhitening == 0
            && darkCircleRemoval == 0
            && blemishRemoval == 0
            && faceShape.isIdentity
    }

    public static func clamp(_ value: Float) -> Float {
        guard value.isFinite else { return 0 }
        return min(max(value, 0), 1)
    }
}
