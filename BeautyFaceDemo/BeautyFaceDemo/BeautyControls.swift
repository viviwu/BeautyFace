import Foundation
import SwiftUI
import BFAlgorithms

/// 一条可调参数的数据描述。用 WritableKeyPath 统一表达基础参数与
/// 嵌套的脸型 / 五官参数，UI 与参数模型之间不需要逐项手写绑定。
struct ParameterDefinition: Identifiable {
    let id: String
    let title: String
    let keyPath: WritableKeyPath<BeautyParameters, Float>
    let defaultValue: Float
    let hint: String

    init(
        _ id: String,
        _ title: String,
        _ keyPath: WritableKeyPath<BeautyParameters, Float>,
        defaultValue: Float,
        hint: String = ""
    ) {
        self.id = id
        self.title = title
        self.keyPath = keyPath
        self.defaultValue = defaultValue
        self.hint = hint
    }
}

enum BeautyCategory: String, CaseIterable, Identifiable {
    case skin
    case retouch
    case faceShape
    case features
    case makeup
    case presets

    var id: String { rawValue }

    var title: String {
        switch self {
        case .skin: return "美肤"
        case .retouch: return "局部修饰"
        case .faceShape: return "脸型"
        case .features: return "五官"
        case .makeup: return "美妆"
        case .presets: return "预设"
        }
    }

    var shortTitle: String {
        switch self {
        case .skin: return "美肤"
        case .retouch: return "局部"
        case .faceShape: return "脸型"
        case .features: return "五官"
        case .makeup: return "美妆"
        case .presets: return "预设"
        }
    }

    var symbol: String {
        switch self {
        case .skin: return "sparkles"
        case .retouch: return "eye"
        case .faceShape: return "person.crop.circle"
        case .features: return "face.smiling"
        case .makeup: return "paintpalette"
        case .presets: return "slider.horizontal.3"
        }
    }

    var summary: String {
        switch self {
        case .skin: return "磨皮、美白与提亮"
        case .retouch: return "眼、齿、眼下与痘印"
        case .faceShape: return "轮廓与脸型形变"
        case .features: return "眼、眉、鼻、嘴微调"
        case .makeup: return "口红、腮红、眉毛与眼影"
        case .presets: return "一键套用与重置"
        }
    }

    /// 美妆颜色定义。`MakeupColor` 不是 Float，无法复用
    /// `ParameterDefinition` 的 KeyPath 机制，因此用独立类型承载，
    /// 避免改动既有 20 条滑杆。
    var colorDefinitions: [MakeupColorDefinition] {
        switch self {
        case .makeup:
            return [
                .init("lipColor", "口红色号",
                      \BeautyParameters.makeup.lipstickColor,
                      defaultValue: .rose,
                      swatches: [
                        .init("rose", "玫瑰", .rose),
                        .init("coral", "珊瑚", .coral),
                        .init("pink", "蜜桃粉", MakeupColor(red: 0.92, green: 0.48, blue: 0.52)),
                        .init("brick", "砖红", MakeupColor(red: 0.68, green: 0.20, blue: 0.18)),
                        .init("berry", "浆果", MakeupColor(red: 0.55, green: 0.14, blue: 0.30)),
                        .init("nude", "裸棕", MakeupColor(red: 0.72, green: 0.46, blue: 0.40))
                      ]),
                .init("blushColor", "腮红色号",
                      \BeautyParameters.makeup.blushColor,
                      defaultValue: .pinkBlush,
                      swatches: [
                        .init("pink", "粉桃", .pinkBlush),
                        .init("apricot", "杏橘", .apricotBlush),
                        .init("coral", "珊瑚", .coral),
                        .init("rose", "玫瑰", .rose),
                        .init("peach", "蜜桃", MakeupColor(red: 0.96, green: 0.70, blue: 0.58)),
                        .init("plum", "梅子", MakeupColor(red: 0.74, green: 0.36, blue: 0.46))
                      ]),
                .init("browColor", "眉色",
                      \BeautyParameters.makeup.browColor,
                      defaultValue: .darkBrown,
                      swatches: [
                        .init("dark", "深棕", .darkBrown),
                        .init("warm", "暖棕", .warmBrown),
                        .init("earth", "大地", .earthShadow),
                        .init("black", "黑", MakeupColor(red: 0.08, green: 0.07, blue: 0.07)),
                        .init("ash", "灰棕", MakeupColor(red: 0.36, green: 0.32, blue: 0.30))
                      ]),
                .init("shadowColor", "眼影色号",
                      \BeautyParameters.makeup.eyeshadowColor,
                      defaultValue: .earthShadow,
                      swatches: [
                        .init("earth", "大地", .earthShadow),
                        .init("warm", "暖棕", .warmBrown),
                        .init("rose", "玫瑰", MakeupColor(red: 0.72, green: 0.44, blue: 0.46)),
                        .init("plum", "梅子", MakeupColor(red: 0.52, green: 0.32, blue: 0.48)),
                        .init("gold", "香槟金", MakeupColor(red: 0.82, green: 0.68, blue: 0.46)),
                        .init("smoke", "烟灰", MakeupColor(red: 0.38, green: 0.36, blue: 0.40))
                      ])
            ]
        default:
            return []
        }
    }

    var parameters: [ParameterDefinition] {
        switch self {
        case .skin:
            return [
                .init("smoothing", "磨皮", \BeautyParameters.smoothing,
                      defaultValue: 0.35, hint: "保边滤波，压平毛孔细纹"),
                .init("whitening", "美白", \BeautyParameters.whitening,
                      defaultValue: 0.25, hint: "淡化肤色不均"),
                .init("brightening", "提亮", \BeautyParameters.brightening,
                      defaultValue: 0.20, hint: "整体亮度，保留高光")
            ]
        case .retouch:
            return [
                .init("eyeBrightening", "亮眼", \BeautyParameters.eyeBrightening,
                      defaultValue: 0.20, hint: "只提亮眼白"),
                .init("teethWhitening", "白牙", \BeautyParameters.teethWhitening,
                      defaultValue: 0.15, hint: "中和牙齿偏黄"),
                .init("darkCircleRemoval", "去黑眼圈", \BeautyParameters.darkCircleRemoval,
                      defaultValue: 0.25, hint: "眼下提亮校色"),
                .init("blemishRemoval", "去痘印", \BeautyParameters.blemishRemoval,
                      defaultValue: 0.30, hint: "小面积瑕疵修复")
            ]
        case .faceShape:
            return [
                .init("faceSize", "小脸", \BeautyParameters.faceShape.faceSize,
                      defaultValue: 0.30, hint: "整圈轮廓内收"),
                .init("jawSlim", "瘦脸", \BeautyParameters.faceShape.jawSlim,
                      defaultValue: 0.25, hint: "下颌收窄"),
                .init("faceNarrow", "窄脸", \BeautyParameters.faceShape.faceNarrow,
                      defaultValue: 0.15, hint: "面颊收窄"),
                .init("vShape", "V 脸", \BeautyParameters.faceShape.vShape,
                      defaultValue: 0.20, hint: "下半张脸收窄"),
                .init("chin", "下巴", \BeautyParameters.faceShape.chin,
                      defaultValue: 0.15, hint: "加长并收窄"),
                .init("forehead", "额头", \BeautyParameters.faceShape.forehead,
                      defaultValue: 0.00, hint: "上段轮廓下压"),
                .init("cheekbone", "颧骨", \BeautyParameters.faceShape.cheekbone,
                      defaultValue: 0.10, hint: "颧骨区域收窄")
            ]
        case .features:
            return [
                .init("eyeSize", "大眼", \BeautyParameters.faceFeature.eyeSize,
                      defaultValue: 0.25, hint: "眼裂纵向放大"),
                .init("eyeDistance", "眼距", \BeautyParameters.faceFeature.eyeDistance,
                      defaultValue: 0.00, hint: "双眼向鼻梁靠拢"),
                .init("browSpacing", "眉间距", \BeautyParameters.faceFeature.browSpacing,
                      defaultValue: 0.00, hint: "双眉向眉心靠拢"),
                .init("browThickness", "眉毛浓度", \BeautyParameters.faceFeature.browThickness,
                      defaultValue: 0.15, hint: "眉带纵向拉伸"),
                .init("noseWidth", "鼻翼", \BeautyParameters.faceFeature.noseWidth,
                      defaultValue: 0.15, hint: "鼻部向中轴收拢"),
                .init("mouthShape", "微笑嘴型", \BeautyParameters.faceFeature.mouthShape,
                      defaultValue: 0.20, hint: "嘴角上扬并收窄")
            ]
        case .makeup:
            return [
                .init("lipstick", "口红", \BeautyParameters.makeup.lipstick,
                      defaultValue: 0.28, hint: "唇部着色，强度即着色权重上限"),
                .init("blush", "腮红", \BeautyParameters.makeup.blush,
                      defaultValue: 0.22, hint: "面颊晕染，边缘自动羽化"),
                .init("brow", "眉毛加深", \BeautyParameters.makeup.brow,
                      defaultValue: 0.18, hint: "沿眉形加深，不改变眉形"),
                .init("eyeshadow", "眼影", \BeautyParameters.makeup.eyeshadow,
                      defaultValue: 0.20, hint: "上眼睑晕染，避开眼球")
            ]
        case .presets:
            return []
        }
    }
}

/// 一个美妆色号（可点选的预设色）。
struct MakeupSwatch: Identifiable {
    let id: String
    let name: String
    let color: MakeupColor

    init(_ id: String, _ name: String, _ color: MakeupColor) {
        self.id = id
        self.name = name
        self.color = color
    }
}

/// 一条可调颜色的数据描述。独立于 `ParameterDefinition`，用
/// `WritableKeyPath<BeautyParameters, MakeupColor>` 绑定颜色本身。
struct MakeupColorDefinition: Identifiable {
    let id: String
    let title: String
    let keyPath: WritableKeyPath<BeautyParameters, MakeupColor>
    let defaultValue: MakeupColor
    let swatches: [MakeupSwatch]

    init(
        _ id: String,
        _ title: String,
        _ keyPath: WritableKeyPath<BeautyParameters, MakeupColor>,
        defaultValue: MakeupColor,
        swatches: [MakeupSwatch]
    ) {
        self.id = id
        self.title = title
        self.keyPath = keyPath
        self.defaultValue = defaultValue
        self.swatches = swatches
    }
}

/// 所有滑杆默认值的唯一来源：ViewModel 初值、「自然」预设和重置按钮都从这里取值，
/// 避免同一组数字在两处维护造成漂移。
enum BeautyDefaults {
    static let parameters: BeautyParameters = {
        var value = BeautyParameters()
        for category in BeautyCategory.allCases {
            for definition in category.parameters {
                value[keyPath: definition.keyPath] = definition.defaultValue
            }
            // 颜色与强度同属「自然」默认值，单点维护避免两套色号漂移。
            for color in category.colorDefinitions {
                value[keyPath: color.keyPath] = color.defaultValue
            }
        }
        return value
    }()
}

/// 颜色控件把 `MakeupColor`（线性 0...1）映射到 SwiftUI 的 Color 与展示用十六进制。
extension MakeupColor {
    var swiftUIColor: Color {
        Color(.sRGB,
              red: Double(red),
              green: Double(green),
              blue: Double(blue),
              opacity: 1)
    }

    var hexString: String {
        func byte(_ value: Float) -> Int {
            Int((min(max(value, 0), 1) * 255).rounded())
        }
        return String(format: "#%02X%02X%02X", byte(red), byte(green), byte(blue))
    }
}

enum BeautyPreset: String, CaseIterable, Identifiable {
    case original
    case natural
    case refined
    case custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .original: return "原图"
        case .natural: return "自然"
        case .refined: return "精致"
        case .custom: return "自定义"
        }
    }

    var detail: String {
        switch self {
        case .original: return "关闭全部美化（含美妆），查看原始照片"
        case .natural: return "轻度磨皮与肤色修饰，附轻微脸型、五官与淡妆"
        case .refined: return "更明显的磨皮、形变与略浓的彩妆，适合查看效果差异"
        case .custom: return "当前参数由手动调整而来"
        }
    }

    var parameters: BeautyParameters {
        switch self {
        case .original:
            return .none
        case .natural:
            return BeautyDefaults.parameters
        case .refined:
            var value = BeautyParameters(
                smoothing: 0.60,
                whitening: 0.45,
                brightening: 0.35,
                eyeBrightening: 0.45,
                teethWhitening: 0.35,
                darkCircleRemoval: 0.50,
                blemishRemoval: 0.50
            )
            value.faceShape = FaceShapeParameters(
                faceSize: 0.55,
                jawSlim: 0.50,
                faceNarrow: 0.35,
                vShape: 0.45,
                chin: 0.35,
                forehead: 0.10,
                cheekbone: 0.30
            )
            value.faceFeature = FaceFeatureParameters(
                eyeSize: 0.50,
                eyeDistance: 0.15,
                browSpacing: 0.10,
                browThickness: 0.30,
                noseWidth: 0.30,
                mouthShape: 0.40
            )
            value.makeup = MakeupParameters(
                lipstickColor: .coral,
                lipstick: 0.55,
                blushColor: .apricotBlush,
                blush: 0.48,
                browColor: .warmBrown,
                brow: 0.38,
                eyeshadowColor: MakeupColor(red: 0.72, green: 0.44, blue: 0.46),
                eyeshadow: 0.45
            )
            return value
        case .custom:
            return BeautyDefaults.parameters
        }
    }
}
