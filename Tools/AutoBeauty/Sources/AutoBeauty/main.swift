import Foundation
import ImageIO
import UniformTypeIdentifiers
import BFKit

struct Options {
    var input: URL
    var output: URL
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
        case "-h", "--help":
            print("用法: AutoBeauty [--input <目录>] [--output <目录>]")
            exit(0)
        default:
            print("忽略未知参数: \(arguments[index])")
        }
        index += 1
    }
    return Options(input: input, output: output)
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
print("")

var failures: [String] = []
var successCount = 0

for url in urls {
    let start = Date()
    do {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw NSError(
                domain: "AutoBeauty",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "解码失败"]
            )
        }

        let outputURL = options.output
            .appendingPathComponent(url.deletingPathExtension().lastPathComponent)
            .appendingPathExtension("png")
        guard let destination = CGImageDestinationCreateWithURL(
            outputURL as CFURL,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            throw NSError(
                domain: "AutoBeauty",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "无法创建输出文件"]
            )
        }

        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw NSError(
                domain: "AutoBeauty",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "写入失败"]
            )
        }

        let elapsed = Date().timeIntervalSince(start) * 1000
        successCount += 1
        print(String(
            format: "[OK]   %@  %d×%d  %.1f ms -> %@",
            url.lastPathComponent,
            image.width,
            image.height,
            elapsed,
            outputURL.lastPathComponent
        ))
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
