import Foundation
import UniformTypeIdentifiers
import CoreGraphics
import BFAlgorithms
import BFKit

/// 把位移场幅度渲染成灰度调试图（网格分辨率，按最大值归一）。
func warpDebugImage(_ field: DisplacementField) -> CGImage? {
    let count = field.columns * field.rows
    var magnitudes = [Float](repeating: 0, count: count)
    var maximum: Float = 0
    for index in 0..<count {
        let dx = field.offsetX[index]
        let dy = field.offsetY[index]
        let magnitude = (dx * dx + dy * dy).squareRoot()
        magnitudes[index] = magnitude
        maximum = max(maximum, magnitude)
    }
    guard maximum > 0.01 else { return nil }

    var bytes = [UInt8](repeating: 0, count: count)
    for index in 0..<count {
        bytes[index] = UInt8((magnitudes[index] / maximum * 255).rounded())
    }

    guard let context = CGContext(
        data: &bytes,
        width: field.columns,
        height: field.rows,
        bitsPerComponent: 8,
        bytesPerRow: field.columns,
        space: CGColorSpaceCreateDeviceGray(),
        bitmapInfo: CGImageAlphaInfo.none.rawValue
    ) else { return nil }
    return context.makeImage()
}

/// 边缘剖面调试用的脸部度量（BFAlgorithms 的 FaceMetrics 是 internal）。
struct FaceMetricsBridge {
    let minY: Float
    let height: Float
    let axisX: Float

    init(_ face: FaceGeometry) {
        guard let first = face.contour.first else {
            minY = 0; height = 0; axisX = 0
            return
        }
        var minY = first.y, maxY = first.y
        for p in face.contour {
            minY = min(minY, p.y)
            maxY = max(maxY, p.y)
        }
        self.minY = minY
        self.height = maxY - minY
        if let l = face.leftPupil, let r = face.rightPupil {
            axisX = (l.x + r.x) * 0.5
        } else {
            axisX = (face.contour.map(\.x).min()! + face.contour.map(\.x).max()!) * 0.5
        }
    }
}

struct Options {
    var input: URL
    var output: URL
    var detect: Bool
    var includeMask: Bool
    var quality: BeautyQuality
    var parameters: BeautyParameters
    var dumpEdge: Bool
}

func repositoryRoot() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
}

func parseOptions() -> Options {
    let root = repositoryRoot()
    var input = root.appendingPathComponent("SampleImages", isDirectory: true)
    var output = root.appendingPathComponent("processed", isDirectory: true)
    var detect = true
    var includeMask = true
    var quality = BeautyQuality.full
    var parameters = BeautyParameters.natural
    var dumpEdge = false

    let arguments = Array(CommandLine.arguments.dropFirst())
    var index = 0
    while index < arguments.count {
        switch arguments[index] {
        case "--input":
            if index + 1 < arguments.count {
                input = URL(fileURLWithPath: arguments[index + 1])
                index += 1
            }
        case "--output":
            if index + 1 < arguments.count {
                output = URL(fileURLWithPath: arguments[index + 1])
                index += 1
            }
        case "--quality":
            if index + 1 < arguments.count {
                switch arguments[index + 1].lowercased() {
                case "preview":
                    quality = .preview
                case "full":
                    quality = .full
                default:
                    print("忽略无效质量：\(arguments[index + 1])（可选 preview/full）")
                }
                index += 1
            }
        case "--smooth":
            if index + 1 < arguments.count, let value = Float(arguments[index + 1]) {
                parameters.smoothing = BeautyParameters.clamp(value)
                index += 1
            }
        case "--white":
            if index + 1 < arguments.count, let value = Float(arguments[index + 1]) {
                parameters.whitening = BeautyParameters.clamp(value)
                index += 1
            }
        case "--bright":
            if index + 1 < arguments.count, let value = Float(arguments[index + 1]) {
                parameters.brightening = BeautyParameters.clamp(value)
                index += 1
            }
        case "--eye":
            if index + 1 < arguments.count, let value = Float(arguments[index + 1]) {
                parameters.eyeBrightening = BeautyParameters.clamp(value)
                index += 1
            }
        case "--teeth":
            if index + 1 < arguments.count, let value = Float(arguments[index + 1]) {
                parameters.teethWhitening = BeautyParameters.clamp(value)
                index += 1
            }
        case "--dark-circle":
            if index + 1 < arguments.count, let value = Float(arguments[index + 1]) {
                parameters.darkCircleRemoval = BeautyParameters.clamp(value)
                index += 1
            }
        case "--blemish":
            if index + 1 < arguments.count, let value = Float(arguments[index + 1]) {
                parameters.blemishRemoval = BeautyParameters.clamp(value)
                index += 1
            }
        case "--face-size":
            if index + 1 < arguments.count, let value = Float(arguments[index + 1]) {
                parameters.faceShape.faceSize = BeautyParameters.clamp(value)
                index += 1
            }
        case "--jaw":
            if index + 1 < arguments.count, let value = Float(arguments[index + 1]) {
                parameters.faceShape.jawSlim = BeautyParameters.clamp(value)
                index += 1
            }
        case "--narrow":
            if index + 1 < arguments.count, let value = Float(arguments[index + 1]) {
                parameters.faceShape.faceNarrow = BeautyParameters.clamp(value)
                index += 1
            }
        case "--v-face":
            if index + 1 < arguments.count, let value = Float(arguments[index + 1]) {
                parameters.faceShape.vShape = BeautyParameters.clamp(value)
                index += 1
            }
        case "--chin":
            if index + 1 < arguments.count, let value = Float(arguments[index + 1]) {
                parameters.faceShape.chin = BeautyParameters.clamp(value)
                index += 1
            }
        case "--forehead":
            if index + 1 < arguments.count, let value = Float(arguments[index + 1]) {
                parameters.faceShape.forehead = BeautyParameters.clamp(value)
                index += 1
            }
        case "--cheekbone":
            if index + 1 < arguments.count, let value = Float(arguments[index + 1]) {
                parameters.faceShape.cheekbone = BeautyParameters.clamp(value)
                index += 1
            }
        case "--eye-size":
            if index + 1 < arguments.count, let value = Float(arguments[index + 1]) {
                parameters.faceFeature.eyeSize = BeautyParameters.clamp(value)
                index += 1
            }
        case "--eye-dist":
            if index + 1 < arguments.count, let value = Float(arguments[index + 1]) {
                parameters.faceFeature.eyeDistance = BeautyParameters.clamp(value)
                index += 1
            }
        case "--brow-space":
            if index + 1 < arguments.count, let value = Float(arguments[index + 1]) {
                parameters.faceFeature.browSpacing = BeautyParameters.clamp(value)
                index += 1
            }
        case "--brow-thick":
            if index + 1 < arguments.count, let value = Float(arguments[index + 1]) {
                parameters.faceFeature.browThickness = BeautyParameters.clamp(value)
                index += 1
            }
        case "--nose-width":
            if index + 1 < arguments.count, let value = Float(arguments[index + 1]) {
                parameters.faceFeature.noseWidth = BeautyParameters.clamp(value)
                index += 1
            }
        case "--mouth":
            if index + 1 < arguments.count, let value = Float(arguments[index + 1]) {
                parameters.faceFeature.mouthShape = BeautyParameters.clamp(value)
                index += 1
            }
        case "--no-detect":
            detect = false
        case "--dump-edge":
            dumpEdge = true
        case "--no-mask":
            includeMask = false
        case "-h", "--help":
            print("""
            用法: AutoBeauty [选项]
              --input <目录>       输入目录，默认 SampleImages/
              --output <目录>      输出目录，默认 processed/
              --quality <preview|full>  预览（长边 1024）或全分辨率（长边 4096）
              --smooth <0...1>     磨皮强度，默认 0.35
              --white <0...1>      美白强度，默认 0.25
              --bright <0...1>     提亮强度，默认 0.20
              --eye <0...1>        亮眼强度，默认 0.20
              --teeth <0...1>      白牙强度，默认 0.15
              --dark-circle <0...1> 去黑眼圈强度，默认 0.25
              --blemish <0...1>    去黑点/痘印强度，默认 0.30
              --face-size <0...1>  小脸（整圈轮廓收缩）
              --jaw <0...1>        瘦脸（下颌收窄）
              --narrow <0...1>     窄脸（面颊收窄）
              --v-face <0...1>     V 脸（下半张脸收窄）
              --chin <0...1>       下巴（加长并收窄）
              --forehead <0...1>   额头（上段轮廓下压，额头显小）
              --cheekbone <0...1>  颧骨（收窄）
              --eye-size <0...1>   大眼（眼眶径向放大）
              --eye-dist <0...1>   眼距（变窄）
              --brow-space <0...1> 眉间距（变窄）
              --brow-thick <0...1> 眉毛粗细（纵向拉伸显浓）
              --nose-width <0...1> 鼻翼（变窄）
              --mouth <0...1>      嘴型（嘴角上扬 + 收窄）
              --no-detect          跳过检测与美化，输出恒等管线结果
              --no-mask            不使用人像分割蒙版（仅肤色）
            """)
            exit(0)
        default:
            print("忽略未知参数: \(arguments[index])")
        }
        index += 1
    }

    return Options(
        input: input,
        output: output,
        detect: detect,
        includeMask: includeMask,
        quality: quality,
        parameters: parameters,
        dumpEdge: dumpEdge
    )
}

let options = parseOptions()
let fileManager = FileManager.default
try? fileManager.createDirectory(at: options.output, withIntermediateDirectories: true)

let imageExtensions: Set<String> = ["jpeg", "jpg", "png", "heic"]
let urls = (try? fileManager.contentsOfDirectory(
    at: options.input,
    includingPropertiesForKeys: nil
))?
    .filter { imageExtensions.contains($0.pathExtension.lowercased()) }
    .sorted { $0.lastPathComponent < $1.lastPathComponent } ?? []

guard !urls.isEmpty else {
    FileHandle.standardError.write(Data("错误：\(options.input.path) 下没有可用图片\n".utf8))
    exit(1)
}

print("AutoBeauty 调试工具")
print("输入：\(options.input.path)")
print("输出：\(options.output.path)")
print("BFKit maxLongEdge：\(WorkingLimits.maxLongEdge)")

let converter: TextureConverter?
do {
    converter = try TextureConverter()
    print("工作纹理：rgba16Float（Metal）")
} catch {
    converter = nil
    print("工作纹理：不可用（\(error.localizedDescription)），使用 CPU 恒等路径")
}

let detector = FaceDetector(includePersonMask: options.includeMask)
let engine: BeautyEngine?
do {
    engine = try BeautyEngine(detector: detector)
    print("渲染：Metal 磨皮 / 美白 / 提亮 / 亮眼 / 白牙 / 去黑眼圈 / 去痘印")
} catch {
    engine = nil
    print("渲染：不可用（\(error.localizedDescription)），回退恒等管线")
}

if options.detect {
    print("检测：Vision 人脸 / 关键点\(options.includeMask ? " / 人像蒙版" : "")")
} else {
    print("检测：已禁用")
}
print("质量：\(options.quality == .preview ? "预览（长边 ≤1024）" : "全分辨率（长边 ≤4096）")")
print(String(
    format: "参数：磨皮=%.2f 美白=%.2f 提亮=%.2f",
    options.parameters.smoothing,
    options.parameters.whitening,
    options.parameters.brightening
))
print(String(
    format: "      亮眼=%.2f 白牙=%.2f 去黑眼圈=%.2f 去痘印=%.2f",
    options.parameters.eyeBrightening,
    options.parameters.teethWhitening,
    options.parameters.darkCircleRemoval,
    options.parameters.blemishRemoval
))
if !options.parameters.faceShape.isIdentity {
    let shape = options.parameters.faceShape
    print(String(
        format: "      脸型：小脸=%.2f 瘦脸=%.2f 窄脸=%.2f V脸=%.2f 下巴=%.2f 额头=%.2f 颧骨=%.2f",
        shape.faceSize,
        shape.jawSlim,
        shape.faceNarrow,
        shape.vShape,
        shape.chin,
        shape.forehead,
        shape.cheekbone
    ))
}
if !options.parameters.faceFeature.isIdentity {
    let feature = options.parameters.faceFeature
    print(String(
        format: "      五官：大眼=%.2f 眼距=%.2f 眉间距=%.2f 眉粗=%.2f 鼻翼=%.2f 嘴型=%.2f",
        feature.eyeSize,
        feature.eyeDistance,
        feature.browSpacing,
        feature.browThickness,
        feature.noseWidth,
        feature.mouthShape
    ))
}
print("")

let pipeline = ImagePipeline(converter: converter)
var failures: [String] = []
var successCount = 0

for url in urls {
    let start = Date()
    do {
        let suffix = options.quality == .preview ? "_preview" : ""
        let baseName = url.deletingPathExtension().lastPathComponent + suffix

        if options.detect, let engine {
            let result = try engine.process(
                url: url,
                parameters: options.parameters,
                quality: options.quality
            )

            let outputURL = options.output
                .appendingPathComponent(baseName)
                .appendingPathExtension("png")
            try ImageEncoder.encode(
                result.image,
                metadata: result.metadata,
                to: outputURL,
                type: .png
            )

            let elapsed = Date().timeIntervalSince(start) * 1000
            let original = "\(Int(result.originalSize.width))×\(Int(result.originalSize.height))"
            let working = "\(result.image.width)×\(result.image.height)"
            let scaleNote = result.wasDownscaled ? " [缩放]" : ""
            successCount += 1
            print(String(
                format: "[OK]   %@  %@ -> %@%@  %.1f ms -> %@",
                url.lastPathComponent,
                original,
                working,
                scaleNote,
                elapsed,
                outputURL.lastPathComponent
            ))

            let maskNote = result.detection.personMask
                .map { "\($0.width)×\($0.height)" } ?? "无"
            print("       检测：\(result.detection.faces.count) 张人脸；人像蒙版：\(maskNote)")
            for (index, face) in result.detection.faces.enumerated() {
                let box = face.boundingBox
                let points = face.landmarks?.allPoints.count ?? 0
                print(String(
                    format: "         人脸 %d：bbox=(%.3f, %.3f, %.3f, %.3f) 关键点=%d 置信度=%.2f",
                    index + 1,
                    box.minX,
                    box.minY,
                    box.width,
                    box.height,
                    points,
                    face.confidence
                ))
            }
            print(String(
                format: "       皮肤蒙版：%d×%d，覆盖率 %.1f%%",
                result.skinMask.width,
                result.skinMask.height,
                result.skinMask.averageValue * 100
            ))
            if !result.retouchMask.isEmpty {
                let total = Float(result.retouchMask.width * result.retouchMask.height)
                func describe(_ channel: [Float], _ label: String) -> String {
                    let strong = channel.filter { $0 > 0.1 }.count
                    let peak = channel.max() ?? 0
                    return String(
                        format: "%@ %d px (%.2f%%, 峰值 %.2f)",
                        label,
                        strong,
                        Float(strong) / total * 100,
                        peak
                    )
                }
                print("       局部蒙版：" + [
                    describe(result.retouchMask.eye, "眼白"),
                    describe(result.retouchMask.teeth, "牙齿"),
                    describe(result.retouchMask.darkCircle, "眼下"),
                ].joined(separator: "；"))
            }

            if let debugImage = DetectionDebugRenderer.render(
                image: result.image,
                result: result.detection,
                skinMask: result.skinMask
            ) {
                let debugURL = options.output
                    .appendingPathComponent(baseName + "_debug")
                    .appendingPathExtension("png")
                try ImageEncoder.encode(
                    debugImage,
                    metadata: result.metadata,
                    to: debugURL,
                    type: .png
                )
                print("         调试图 -> \(debugURL.lastPathComponent)")
            }

            if let skinImage = result.skinMask.makeCGImage() {
                let skinURL = options.output
                    .appendingPathComponent(baseName + "_skin")
                    .appendingPathExtension("png")
                try ImageEncoder.encode(
                    skinImage,
                    metadata: result.metadata,
                    to: skinURL,
                    type: .png
                )
                print("         蒙版图 -> \(skinURL.lastPathComponent)")
            }

            if let retouchImage = RetouchDebugRenderer.render(
                image: result.image,
                mask: result.retouchMask
            ) {
                let retouchURL = options.output
                    .appendingPathComponent(baseName + "_retouch")
                    .appendingPathExtension("png")
                try ImageEncoder.encode(
                    retouchImage,
                    metadata: result.metadata,
                    to: retouchURL,
                    type: .png
                )
                print("         局部图 -> \(retouchURL.lastPathComponent)")
            }

            if let field = result.displacementField {
                print(String(
                    format: "       形变：网格 %d×%d，最大位移 %.1f px，最小雅可比 %.3f，强度 %.2f",
                    field.columns,
                    field.rows,
                    field.maximumDisplacement(),
                    field.minimumJacobian(),
                    field.appliedStrength
                ))
                if options.dumpEdge {
                    // 边缘宽度剖面：沿轮廓采样，分左右两侧各自按高度
                    // 排列，检查「收窄比例」（位移/横向距离）是否沿
                    // 太阳穴 → 下巴单调递增。波浪 = 比例反向。
                    // 注意：轮廓点输出位置 = 原位置 − d（d 是采样偏移），
                    // 收窄量（向轴为正）= d.x × sign(lateral)。
                    let faces = FaceGeometryConverter.convert(detection: result.detection)
                    for (faceIndex, face) in faces.enumerated() {
                        let m = FaceMetricsBridge(face)
                        print("       脸 \(faceIndex + 1) 边缘剖面（t=1 太阳穴 → 0 下巴，收窄比例）：")
                        for sideSign in [Float(-1), Float(1)] {
                            var samples: [(t: Float, ratio: Float)] = []
                            // 沿轮廓折线加密采样（含段中点）——波浪恰恰
                            // 藏在顶点之间，只采顶点会漏检
                            for point in DisplacementField.densifiedContour(
                                face.contour,
                                subdivisions: 4
                            ) {
                                let lateral = point.x - m.axisX
                                // 下巴尖端 lateral≈0，比例分母趋零是数值
                                // 噪声，不参与波浪判定
                                guard lateral * sideSign > 15 else { continue }
                                let t = (point.y - m.minY) / max(m.height, 1)
                                let d = field.displacement(at: point)
                                let inward = d.x * (lateral > 0 ? 1 : -1)
                                samples.append((t, inward / abs(lateral)))
                            }
                            samples.sort { $0.t > $1.t }
                            var reversals = 0
                            for i in 1..<samples.count
                            where samples[i].ratio < samples[i - 1].ratio - 0.005 {
                                reversals += 1
                            }
                            let side = sideSign < 0 ? "左" : "右"
                            let line = samples.map {
                                String(format: "%.2f:%.3f", $0.t, $0.ratio)
                            }.joined(separator: " ")
                            print("         \(side)侧 \(line)")
                            print("         \(side)侧比例反向点（波浪）个数：\(reversals)")
                        }
                    }
                }
                if let warpImage = warpDebugImage(field) {
                    let warpURL = options.output
                        .appendingPathComponent(baseName + "_warp")
                        .appendingPathExtension("png")
                    try ImageEncoder.encode(
                        warpImage,
                        metadata: result.metadata,
                        to: warpURL,
                        type: .png
                    )
                    print("         形变图 -> \(warpURL.lastPathComponent)")
                }
            }
        } else {
            let processed = try pipeline.process(
                url: url,
                maxLongEdge: options.quality.maxLongEdge
            )
            let outputURL = options.output
                .appendingPathComponent(baseName)
                .appendingPathExtension("png")
            try ImageEncoder.encode(
                processed.image,
                metadata: processed.metadata,
                to: outputURL,
                type: .png
            )

            let elapsed = Date().timeIntervalSince(start) * 1000
            let original = "\(Int(processed.originalSize.width))×\(Int(processed.originalSize.height))"
            let working = "\(processed.image.width)×\(processed.image.height)"
            let scaleNote = processed.wasDownscaled ? " [缩放]" : ""
            successCount += 1
            print(String(
                format: "[OK]   %@  %@ -> %@%@  %.1f ms -> %@",
                url.lastPathComponent,
                original,
                working,
                scaleNote,
                elapsed,
                outputURL.lastPathComponent
            ))

            guard options.detect else { continue }

            let detection = try detector.detect(image: processed.image)
            let maskNote = detection.personMask.map { "\($0.width)×\($0.height)" } ?? "无"
            print("       检测：\(detection.faces.count) 张人脸；人像蒙版：\(maskNote)")

            if let debugImage = DetectionDebugRenderer.render(
                image: processed.image,
                result: detection
            ) {
                let debugURL = options.output
                    .appendingPathComponent(baseName + "_debug")
                    .appendingPathExtension("png")
                try ImageEncoder.encode(
                    debugImage,
                    metadata: processed.metadata,
                    to: debugURL,
                    type: .png
                )
                print("         调试图 -> \(debugURL.lastPathComponent)")
            }
        }
    } catch {
        failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
        print("[FAIL] \(url.lastPathComponent)：\(error.localizedDescription)")
    }
}

print("")
print("完成：成功 \(successCount) 张，失败 \(failures.count) 张")
if !failures.isEmpty {
    exit(1)
}
