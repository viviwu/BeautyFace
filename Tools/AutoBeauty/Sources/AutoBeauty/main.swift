import Foundation
import UniformTypeIdentifiers
import BFAlgorithms
import BFKit

struct Options {
    var input: URL
    var output: URL
    var detect: Bool
    var includeMask: Bool
    var quality: BeautyQuality
    var parameters: BeautyParameters
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
        case "--no-detect":
            detect = false
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
        parameters: parameters
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
    print("渲染：Metal 磨皮 / 美白 / 提亮")
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
