import Foundation
import UniformTypeIdentifiers
import BFKit

struct Options {
    var input: URL
    var output: URL
    var detect: Bool
    var includeMask: Bool
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
        case "--no-detect":
            detect = false
        case "--no-mask":
            includeMask = false
        case "-h", "--help":
            print("用法: AutoBeauty [--input <目录>] [--output <目录>] [--no-detect] [--no-mask]")
            exit(0)
        default:
            print("忽略未知参数: \(arguments[index])")
        }
        index += 1
    }
    return Options(input: input, output: output, detect: detect, includeMask: includeMask)
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
print("")

let pipeline = ImagePipeline(converter: converter)
let detector = FaceDetector(includePersonMask: options.includeMask)
if options.detect {
    print("检测：Vision 人脸 / 关键点\(options.includeMask ? " / 人像蒙版" : "")")
} else {
    print("检测：已禁用")
}
print("")

var failures: [String] = []
var successCount = 0

for url in urls {
    let start = Date()
    do {
        let processed = try pipeline.process(url: url)
        let baseName = url.deletingPathExtension().lastPathComponent
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
        for (index, face) in detection.faces.enumerated() {
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
