import CoreGraphics
import Foundation
import Observation
import SwiftUI
import UniformTypeIdentifiers
import BFAlgorithms
import BFKit

/// 所有耗时的检测与渲染都在同一条串行队列上执行。类内部持有 Metal 引擎，
/// 由调用方保证单线程访问，因此标记为 @unchecked Sendable。
private final class BeautySession: @unchecked Sendable {
    private let engine: BeautyEngine
    private var analysis: BeautyAnalysis?

    init(engine: BeautyEngine) {
        self.engine = engine
    }

    struct Analysis: @unchecked Sendable {
        let original: CGImage
        let faceCount: Int
        let succeeded: Bool
    }

    struct Preview: @unchecked Sendable {
        let image: CGImage?
        let milliseconds: Double
    }

    /// 换图时调用一次：解码 → 检测 → 蒙版，之后调参复用缓存。
    func prepare(data: Data, quality: BeautyQuality) -> Analysis? {
        guard let decoded = try? ImageDecoder.decode(
            data: data,
            maxLongEdge: quality.maxLongEdge
        ) else { return nil }
        do {
            let result = try engine.analyze(decoded: decoded, quality: quality)
            analysis = result
            return Analysis(
                original: decoded.image,
                faceCount: result.detection.faces.count,
                succeeded: true
            )
        } catch {
            analysis = nil
            return Analysis(original: decoded.image, faceCount: 0, succeeded: false)
        }
    }

    /// 拖动滑杆时调用：只做颜色 / 平滑与几何，不重新检测。
    func render(_ parameters: BeautyParameters) -> Preview {
        guard let analysis else {
            return Preview(image: nil, milliseconds: 0)
        }
        let start = Date()
        let result = try? engine.render(analysis: analysis, parameters: parameters)
        return Preview(
            image: result?.image,
            milliseconds: Date().timeIntervalSince(start) * 1000
        )
    }

    /// 导出时按全分辨率重新分析一次（蒙版分辨率与像素坐标随质量变化）。
    func export(data: Data, parameters: BeautyParameters) -> Data? {
        guard let decoded = try? ImageDecoder.decode(
            data: data,
            maxLongEdge: BeautyQuality.full.maxLongEdge
        ),
        let fullAnalysis = try? engine.analyze(decoded: decoded, quality: .full),
        let result = try? engine.render(analysis: fullAnalysis, parameters: parameters)
        else { return nil }
        return try? ImageEncoder.data(
            result.image,
            metadata: result.metadata,
            type: .png
        )
    }
}

@MainActor
@Observable
final class BeautyStudioModel {
    var parameters: BeautyParameters = BeautyDefaults.parameters
    var selectedCategory: BeautyCategory = .skin
    var activePreset: BeautyPreset = .natural
    var showingOriginal = false
    /// M8 / 美妆目视：可拖拽分割线对比，左侧原图、右侧效果。
    var splitComparison = false
    var splitFraction: Double = 0.5
    var sourceName = "内置示例人像"

    private(set) var originalImage: CGImage?
    private(set) var previewImage: CGImage?
    private(set) var isAnalyzing = false
    private(set) var isRendering = false
    private(set) var isExporting = false
    private(set) var faceCount = 0
    private(set) var lastRenderMilliseconds: Double?
    private(set) var statusMessage = "正在载入示例图"
    private(set) var errorMessage: String?
    private(set) var engineUnavailable: String?
    private(set) var exportURL: URL?

    private let session: BeautySession?
    private let queue = DispatchQueue(label: "com.vivi.BeautyFace.session", qos: .userInitiated)
    private var sourceData: Data?
    private var generation = 0
    private var pendingRender: DispatchWorkItem?

    init() {
        do {
            session = BeautySession(engine: try BeautyEngine())
        } catch {
            session = nil
            engineUnavailable = "Metal 不可用：\(error.localizedDescription)。仍可查看照片，但美化功能已停用。"
        }
    }

    // MARK: - 图片来源

    func loadDefault() {
        if let data = bundledDefaultPortrait() {
            sourceName = "默认示例照片"
            load(data: data)
            return
        }
        guard let data = SamplePortrait.makeData() else {
            errorMessage = "无法生成内置示例图"
            return
        }
        sourceName = "内置示意人像"
        load(data: data)
    }

    /// 优先使用 scripts/install_default_portrait.sh 放进 bundle 的真实人像。
    /// 该资源不入库，缺失时回退到程序化示意人像，保证任何环境启动都有图。
    private func bundledDefaultPortrait() -> Data? {
        let bundle = Bundle.main
        var candidates: [URL] = []
        if let url = bundle.url(forResource: "DefaultPortrait", withExtension: "jpg") {
            candidates.append(url)
        }
        if let url = bundle.url(
            forResource: "DefaultPortrait",
            withExtension: "jpg",
            subdirectory: "Resources"
        ) {
            candidates.append(url)
        }
        if let root = bundle.resourceURL {
            candidates.append(root.appendingPathComponent("DefaultPortrait.jpg"))
            candidates.append(root.appendingPathComponent("Resources/DefaultPortrait.jpg"))
        }
        for url in candidates where FileManager.default.fileExists(atPath: url.path) {
            if let data = try? Data(contentsOf: url), !data.isEmpty {
                return data
            }
        }
        return nil
    }

    func load(data: Data, name: String) {
        sourceName = name
        load(data: data)
    }

    private func load(data: Data) {
        sourceData = data
        exportURL = nil
        errorMessage = nil
        previewImage = nil
        originalImage = nil
        lastRenderMilliseconds = nil
        pendingRender?.cancel()
        // 作废上一张照片尚未回传的渲染结果，避免旧画面覆盖新照片。
        generation += 1

        guard let session else {
            statusMessage = engineUnavailable ?? "美化引擎不可用"
            // 没有 Metal 时仍解码并显示原图，而不是停留在空白页。
            if let decoded = try? ImageDecoder.decode(
                data: data,
                maxLongEdge: BeautyQuality.preview.maxLongEdge
            ) {
                originalImage = decoded.image
                previewImage = decoded.image
            }
            return
        }

        isAnalyzing = true
        statusMessage = "正在分析照片…"
        queue.async { [weak self] in
            let outcome = session.prepare(data: data, quality: .preview)
            DispatchQueue.main.async {
                guard let self else { return }
                self.isAnalyzing = false
                guard let outcome else {
                    self.errorMessage = "无法解码这张图片，请换一张 HEIC / JPEG / PNG"
                    self.statusMessage = "载入失败"
                    return
                }
                self.originalImage = outcome.original
                self.previewImage = outcome.original
                self.faceCount = outcome.faceCount
                if outcome.succeeded {
                    self.statusMessage = outcome.faceCount > 0
                        ? "检测到 \(outcome.faceCount) 张人脸 · 预览长边 1024"
                        : "未检测到人脸：形变与局部修饰需要真实人像，请选择一张照片"
                } else {
                    self.errorMessage = "检测或蒙版生成失败，已显示原图"
                    self.statusMessage = "分析失败"
                }
                // 分析失败时缓存为空，再渲染只会报「渲染失败」盖掉真正原因。
                if outcome.succeeded {
                    self.renderPreview()
                }
            }
        }
    }

    // MARK: - 参数与预览

    func binding(for definition: ParameterDefinition) -> Binding<Double> {
        Binding(
            get: { Double(self.parameters[keyPath: definition.keyPath]) },
            set: { newValue in
                var updated = self.parameters
                updated[keyPath: definition.keyPath] = Float(newValue)
                self.parameters = updated
                self.activePreset = .custom
                // 参数变了，之前导出的 PNG 已过期，不能继续提供「保存」。
                self.exportURL = nil
                self.schedulePreview()
            }
        )
    }

    /// 颜色控件走与滑杆完全相同的自定义标记 + 防抖渲染路径，
    /// 不会重新跑 `analyze`。
    func setColor(_ color: MakeupColor, for definition: MakeupColorDefinition) {
        var updated = parameters
        updated[keyPath: definition.keyPath] = color
        parameters = updated
        activePreset = .custom
        exportURL = nil
        schedulePreview()
    }

    func reset(_ definition: MakeupColorDefinition) {
        setColor(definition.defaultValue, for: definition)
    }

    func apply(_ preset: BeautyPreset) {
        guard preset != .custom else { return }
        parameters = preset.parameters
        activePreset = preset
        exportURL = nil
        renderPreview()
    }

    func reset(_ category: BeautyCategory) {
        var updated = parameters
        for definition in category.parameters {
            updated[keyPath: definition.keyPath] = definition.defaultValue
        }
        for color in category.colorDefinitions {
            updated[keyPath: color.keyPath] = color.defaultValue
        }
        parameters = updated
        activePreset = .custom
        exportURL = nil
        renderPreview()
    }

    func reset(_ definition: ParameterDefinition) {
        var updated = parameters
        updated[keyPath: definition.keyPath] = definition.defaultValue
        parameters = updated
        activePreset = .custom
        exportURL = nil
        renderPreview()
    }

    private func schedulePreview() {
        pendingRender?.cancel()
        let item = DispatchWorkItem { [weak self] in
            DispatchQueue.main.async { self?.renderPreview() }
        }
        pendingRender = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: item)
    }

    private func renderPreview() {
        guard let session else {
            previewImage = originalImage
            return
        }
        generation += 1
        let token = generation
        let snapshot = parameters
        isRendering = true
        queue.async { [weak self] in
            let outcome = session.render(snapshot)
            DispatchQueue.main.async {
                guard let self, self.generation == token else { return }
                self.isRendering = false
                self.lastRenderMilliseconds = outcome.milliseconds
                if let image = outcome.image {
                    self.previewImage = image
                    self.errorMessage = nil
                } else {
                    self.errorMessage = "渲染失败，请重试或更换照片"
                }
            }
        }
    }

    // MARK: - 导出

    func prepareExport() {
        guard let session, let data = sourceData else { return }
        isExporting = true
        let snapshot = parameters
        queue.async { [weak self] in
            let png = session.export(data: data, parameters: snapshot)
            var url: URL?
            if let png {
                let target = FileManager.default.temporaryDirectory
                    .appendingPathComponent("BeautyFace-\(UUID().uuidString).png")
                try? png.write(to: target)
                url = target
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.isExporting = false
                if let url {
                    self.exportURL = url
                    self.statusMessage = "已生成全分辨率 PNG（长边 ≤4096），可保存或分享"
                } else {
                    self.errorMessage = "导出失败：无法完成全分辨率处理"
                }
            }
        }
    }
}
