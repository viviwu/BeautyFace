import Foundation
import BFAlgorithms

/// 各处理功能的默认值配置（JSON，默认位于 `Configs/beauty_default.json`）。
///
/// 结构镜像 `BeautyParameters`，**所有字段均可省略**：省略的字段保持
/// 进入配置前的取值，因此既支持全量配置，也支持单字段调试文件。
/// 显式命令行旗标在配置之后解析，天然覆盖配置值。
struct BeautyConfig: Codable {
    var color: ColorSection?
    var faceShape: FaceShapeSection?
    var faceFeature: FaceFeatureSection?
    var makeup: MakeupSection?

    struct ColorSection: Codable {
        var smoothing: Double?
        var whitening: Double?
        var brightening: Double?
        var eyeBrightening: Double?
        var teethWhitening: Double?
        var darkCircleRemoval: Double?
        var blemishRemoval: Double?
    }

    struct FaceShapeSection: Codable {
        var faceSize: Double?
        var jawSlim: Double?
        var faceNarrow: Double?
        var vShape: Double?
        var chin: Double?
        var forehead: Double?
        var cheekbone: Double?
    }

    struct FaceFeatureSection: Codable {
        var eyeSize: Double?
        var eyeDistance: Double?
        var browSpacing: Double?
        var browThickness: Double?
        var noseWidth: Double?
        var mouthShape: Double?
    }

    struct MakeupSection: Codable {
        var lipstick: Double?
        var blush: Double?
        var brow: Double?
        var shadow: Double?
        var lipColor: String?
        var blushColor: String?
        var browColor: String?
        var shadowColor: String?
    }

    // MARK: - 加载

    static func load(from url: URL) throws -> BeautyConfig {
        let data = try Data(contentsOf: url)
        let config = try JSONDecoder().decode(BeautyConfig.self, from: data)
        try config.validate()
        return config
    }

    /// 校验颜色字段；强度越界由 clamp 兜底，颜色拼错必须显式报错。
    func validate() throws {
        let hexes: [(String?, String)] = [
            (makeup?.lipColor, "makeup.lipColor"),
            (makeup?.blushColor, "makeup.blushColor"),
            (makeup?.browColor, "makeup.browColor"),
            (makeup?.shadowColor, "makeup.shadowColor"),
        ]
        for (value, field) in hexes {
            guard let value else { continue }
            if Self.color(fromHex: value) == nil {
                throw ConfigError.invalidHex(field: field, value: value)
            }
        }
    }

    enum ConfigError: LocalizedError {
        case invalidHex(field: String, value: String)

        var errorDescription: String? {
            switch self {
            case let .invalidHex(field, value):
                return "\(field)：\"\(value)\" 不是合法的 #RRGGBB 颜色"
            }
        }
    }

    // MARK: - 应用到参数

    func apply(to parameters: inout BeautyParameters) {
        func value(_ input: Double?) -> Float? {
            input.map { BeautyParameters.clamp(Float($0)) }
        }

        if let color {
            if let x = value(color.smoothing) { parameters.smoothing = x }
            if let x = value(color.whitening) { parameters.whitening = x }
            if let x = value(color.brightening) { parameters.brightening = x }
            if let x = value(color.eyeBrightening) { parameters.eyeBrightening = x }
            if let x = value(color.teethWhitening) { parameters.teethWhitening = x }
            if let x = value(color.darkCircleRemoval) { parameters.darkCircleRemoval = x }
            if let x = value(color.blemishRemoval) { parameters.blemishRemoval = x }
        }
        if let shape = faceShape {
            if let x = value(shape.faceSize) { parameters.faceShape.faceSize = x }
            if let x = value(shape.jawSlim) { parameters.faceShape.jawSlim = x }
            if let x = value(shape.faceNarrow) { parameters.faceShape.faceNarrow = x }
            if let x = value(shape.vShape) { parameters.faceShape.vShape = x }
            if let x = value(shape.chin) { parameters.faceShape.chin = x }
            if let x = value(shape.forehead) { parameters.faceShape.forehead = x }
            if let x = value(shape.cheekbone) { parameters.faceShape.cheekbone = x }
        }
        if let feature = faceFeature {
            if let x = value(feature.eyeSize) { parameters.faceFeature.eyeSize = x }
            if let x = value(feature.eyeDistance) { parameters.faceFeature.eyeDistance = x }
            if let x = value(feature.browSpacing) { parameters.faceFeature.browSpacing = x }
            if let x = value(feature.browThickness) { parameters.faceFeature.browThickness = x }
            if let x = value(feature.noseWidth) { parameters.faceFeature.noseWidth = x }
            if let x = value(feature.mouthShape) { parameters.faceFeature.mouthShape = x }
        }
        if let makeup {
            if let x = value(makeup.lipstick) { parameters.makeup.lipstick = x }
            if let x = value(makeup.blush) { parameters.makeup.blush = x }
            if let x = value(makeup.brow) { parameters.makeup.brow = x }
            if let x = value(makeup.shadow) { parameters.makeup.eyeshadow = x }
            if let hex = makeup.lipColor, let color = Self.color(fromHex: hex) {
                parameters.makeup.lipstickColor = color
            }
            if let hex = makeup.blushColor, let color = Self.color(fromHex: hex) {
                parameters.makeup.blushColor = color
            }
            if let hex = makeup.browColor, let color = Self.color(fromHex: hex) {
                parameters.makeup.browColor = color
            }
            if let hex = makeup.shadowColor, let color = Self.color(fromHex: hex) {
                parameters.makeup.eyeshadowColor = color
            }
        }
    }

    // MARK: - 颜色转换

    /// 解析 `#RRGGBB` 或 `RRGGBB`；非法返回 nil。
    static func color(fromHex hex: String) -> MakeupColor? {
        var text = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6, let raw = UInt64(text, radix: 16) else { return nil }
        return MakeupColor(
            red: Float((raw >> 16) & 0xFF) / 255,
            green: Float((raw >> 8) & 0xFF) / 255,
            blue: Float(raw & 0xFF) / 255
        )
    }

    static func hex(from color: MakeupColor) -> String {
        func byte(_ channel: Float) -> Int {
            Int((channel * 255).rounded())
        }
        return String(
            format: "#%02X%02X%02X",
            byte(color.red),
            byte(color.green),
            byte(color.blue)
        )
    }

    // MARK: - 导出

    /// 从最终参数反向生成配置（供 `--dump-config` 存档满意的一组值）。
    init(parameters: BeautyParameters) {
        func rounded(_ value: Float) -> Double {
            // Float 转double 会带尾数噪声（0.6 → 0.60000002…），
            // 导出统一保留 2 位小数，与配置文件手写精度一致
            let scaled = (Double(value) * 100).rounded()
            return scaled / 100
        }

        color = ColorSection(
            smoothing: rounded(parameters.smoothing),
            whitening: rounded(parameters.whitening),
            brightening: rounded(parameters.brightening),
            eyeBrightening: rounded(parameters.eyeBrightening),
            teethWhitening: rounded(parameters.teethWhitening),
            darkCircleRemoval: rounded(parameters.darkCircleRemoval),
            blemishRemoval: rounded(parameters.blemishRemoval)
        )
        faceShape = FaceShapeSection(
            faceSize: rounded(parameters.faceShape.faceSize),
            jawSlim: rounded(parameters.faceShape.jawSlim),
            faceNarrow: rounded(parameters.faceShape.faceNarrow),
            vShape: rounded(parameters.faceShape.vShape),
            chin: rounded(parameters.faceShape.chin),
            forehead: rounded(parameters.faceShape.forehead),
            cheekbone: rounded(parameters.faceShape.cheekbone)
        )
        faceFeature = FaceFeatureSection(
            eyeSize: rounded(parameters.faceFeature.eyeSize),
            eyeDistance: rounded(parameters.faceFeature.eyeDistance),
            browSpacing: rounded(parameters.faceFeature.browSpacing),
            browThickness: rounded(parameters.faceFeature.browThickness),
            noseWidth: rounded(parameters.faceFeature.noseWidth),
            mouthShape: rounded(parameters.faceFeature.mouthShape)
        )
        makeup = MakeupSection(
            lipstick: rounded(parameters.makeup.lipstick),
            blush: rounded(parameters.makeup.blush),
            brow: rounded(parameters.makeup.brow),
            shadow: rounded(parameters.makeup.eyeshadow),
            lipColor: Self.hex(from: parameters.makeup.lipstickColor),
            blushColor: Self.hex(from: parameters.makeup.blushColor),
            browColor: Self.hex(from: parameters.makeup.browColor),
            shadowColor: Self.hex(from: parameters.makeup.eyeshadowColor)
        )
    }

    /// 导出为格式化 JSON 文本。
    func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }
}
