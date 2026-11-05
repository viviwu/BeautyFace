/// 程序化美妆的 RGB 颜色（线性 0...1，gamma 空间）。
public struct MakeupColor: Equatable, Sendable {
    public var red: Float
    public var green: Float
    public var blue: Float

    public init(red: Float, green: Float, blue: Float) {
        self.red = min(max(red, 0), 1)
        self.green = min(max(green, 0), 1)
        self.blue = min(max(blue, 0), 1)
    }

    /// 亮度（Rec.601 加权）。
    public var luma: Float {
        0.299 * red + 0.587 * green + 0.114 * blue
    }

    // 常用预设（ADR-008：颜色参数化，不依赖美术素材）
    public static let rose = MakeupColor(red: 0.78, green: 0.22, blue: 0.28)
    public static let coral = MakeupColor(red: 0.86, green: 0.38, blue: 0.36)
    public static let pinkBlush = MakeupColor(red: 0.92, green: 0.48, blue: 0.52)
    public static let apricotBlush = MakeupColor(red: 0.94, green: 0.62, blue: 0.50)
    public static let darkBrown = MakeupColor(red: 0.16, green: 0.10, blue: 0.08)
    public static let warmBrown = MakeupColor(red: 0.48, green: 0.28, blue: 0.18)
    public static let earthShadow = MakeupColor(red: 0.55, green: 0.36, blue: 0.26)
}

/// 美妆参数。所有强度均为 0...1，超出范围会被裁剪；
/// 颜色可自定义（ADR-008），预设只保存参数。
public struct MakeupParameters: Equatable, Sendable {
    /// 口红颜色与强度。强度为「着色权重」上限。
    public var lipstickColor: MakeupColor
    public var lipstick: Float
    /// 腮红颜色与强度。
    public var blushColor: MakeupColor
    public var blush: Float
    /// 眉毛加深颜色与强度。
    public var browColor: MakeupColor
    public var brow: Float
    /// 眼影颜色与强度。
    public var eyeshadowColor: MakeupColor
    public var eyeshadow: Float

    public init(
        lipstickColor: MakeupColor = .rose,
        lipstick: Float = 0,
        blushColor: MakeupColor = .pinkBlush,
        blush: Float = 0,
        browColor: MakeupColor = .darkBrown,
        brow: Float = 0,
        eyeshadowColor: MakeupColor = .earthShadow,
        eyeshadow: Float = 0
    ) {
        self.lipstickColor = lipstickColor
        self.lipstick = BeautyParameters.clamp(lipstick)
        self.blushColor = blushColor
        self.blush = BeautyParameters.clamp(blush)
        self.browColor = browColor
        self.brow = BeautyParameters.clamp(brow)
        self.eyeshadowColor = eyeshadowColor
        self.eyeshadow = BeautyParameters.clamp(eyeshadow)
    }

    public static let none = MakeupParameters()

    public var isIdentity: Bool {
        lipstick == 0 && blush == 0 && brow == 0 && eyeshadow == 0
    }
}
