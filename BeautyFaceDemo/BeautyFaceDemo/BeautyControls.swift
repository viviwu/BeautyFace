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
    case presets

    var id: String { rawValue }

    var title: String {
        switch self {
        case .skin: return "美肤"
        case .retouch: return "局部修饰"
        case .faceShape: return "脸型"
        case .features: return "五官"
        case .presets: return "预设"
        }
    }

    var shortTitle: String {
        switch self {
        case .skin: return "美肤"
        case .retouch: return "局部"
        case .faceShape: return "脸型"
        case .features: return "五官"
        case .presets: return "预设"
        }
    }

    var symbol: String {
        switch self {
        case .skin: return "sparkles"
        case .retouch: return "eye"
        case .faceShape: return "person.crop.circle"
        case .features: return "face.smiling"
        case .presets: return "slider.horizontal.3"
        }
    }

    var summary: String {
        switch self {
        case .skin: return "磨皮、美白与提亮"
        case .retouch: return "眼、齿、眼下与痘印"
        case .faceShape: return "轮廓与脸型形变"
        case .features: return "眼、眉、鼻、嘴微调"
        case .presets: return "一键套用与重置"
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
        case .presets:
            return []
        }
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
        }
        return value
    }()
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
        case .original: return "关闭全部美化，查看原始照片"
        case .natural: return "轻度磨皮与肤色修饰，附带轻微脸型与五官微调"
        case .refined: return "更明显的磨皮、提亮与形变，适合查看效果差异"
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
            return value
        case .custom:
            return BeautyDefaults.parameters
        }
    }
}
