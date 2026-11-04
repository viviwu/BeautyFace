import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import BFAlgorithms

/// App 主界面：左侧功能菜单、中间预览、底部随菜单变化的参数面板。
/// 纯 SwiftUI + ImageIO / CGImage，不使用 UIKit / AppKit（ADR-013 / ADR-014）。
struct BeautyStudioView: View {
    @State private var model = BeautyStudioModel()
    @State private var pickerItem: PhotosPickerItem?
    @State private var showingFileImporter = false
    @State private var didLoadDefault = false
    @State private var pickerError: String?

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            HStack(spacing: 0) {
                categorySidebar
                Divider()
                previewArea
            }
            .frame(maxHeight: .infinity)
            Divider()
            parameterPanel
        }
        #if os(macOS)
        .frame(minWidth: 1040, minHeight: 780)
        #endif
        .onAppear {
            guard !didLoadDefault else { return }
            didLoadDefault = true
            model.loadDefault()
        }
        .onChange(of: pickerItem) { _, item in
            Task { await loadFromPhotos(item) }
        }
        .fileImporter(
            isPresented: $showingFileImporter,
            allowedContentTypes: [.image],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                do {
                    let data = try Data(contentsOf: url)
                    model.load(data: data, name: url.lastPathComponent)
                } catch {
                    pickerError = error.localizedDescription
                }
            case .failure(let error):
                pickerError = error.localizedDescription
            }
        }
        .alert("无法读取照片", isPresented: Binding(
            get: { pickerError != nil },
            set: { if !$0 { pickerError = nil } }
        )) {
            Button("好", role: .cancel) { pickerError = nil }
        } message: {
            Text(pickerError ?? "")
        }
    }

    // MARK: - 顶部工具栏

    private var toolbar: some View {
        HStack(spacing: 12) {
            Label("BeautyFace", systemImage: "sparkles")
                .font(.headline)
            Text("·")
                .foregroundStyle(.secondary)
            Text(model.sourceName)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer(minLength: 12)

            Menu {
                ForEach([BeautyPreset.original, .natural, .refined]) { preset in
                    Button {
                        model.apply(preset)
                    } label: {
                        VStack(alignment: .leading) {
                            Text(preset.title)
                            Text(preset.detail).font(.caption)
                        }
                    }
                }
            } label: {
                Label(model.activePreset.title, systemImage: "chevron.down")
            }
            .frame(minWidth: 96)

            Divider().frame(height: 20)

            PhotosPicker(selection: $pickerItem, matching: .images) {
                Label("选择照片", systemImage: "photo")
            }

            Button {
                showingFileImporter = true
            } label: {
                Label("打开文件", systemImage: "folder")
            }

            Button {
                model.loadDefault()
            } label: {
                Label("示例图", systemImage: "arrow.counterclockwise")
            }
            .platformHelp("恢复内置的默认示例人像")

            Divider().frame(height: 20)

            exportControl
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var exportControl: some View {
        if model.isExporting {
            ProgressView()
                .controlSize(.small)
        } else if let url = model.exportURL {
            ShareLink(item: url) {
                Label("保存 PNG", systemImage: "square.and.arrow.up")
            }
        } else {
            Button {
                model.prepareExport()
            } label: {
                Label("导出", systemImage: "square.and.arrow.up")
            }
            .disabled(model.previewImage == nil || model.engineUnavailable != nil)
            .platformHelp("按全分辨率（长边 ≤4096）重新处理并生成 PNG")
        }
    }

    // MARK: - 左侧功能菜单

    private var categorySidebar: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("功能")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)
                .padding(.bottom, 4)

            ForEach(BeautyCategory.allCases) { category in
                let selected = model.selectedCategory == category
                Button {
                    model.selectedCategory = category
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: category.symbol)
                            .font(.body)
                            .frame(width: 20)
                            .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(category.shortTitle)
                                .font(.body)
                            Text(category.summary)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(selected ? Color.accentColor.opacity(0.16) : Color.clear)
                    )
                    .overlay(alignment: .leading) {
                        if selected {
                            Capsule()
                                .fill(Color.accentColor)
                                .frame(width: 3, height: 26)
                                .padding(.leading, 2)
                        }
                    }
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 8)
            }

            Spacer()

            VStack(alignment: .leading, spacing: 6) {
                Divider()
                HStack(spacing: 6) {
                    Image(systemName: model.faceCount > 0 ? "face.smiling" : "questionmark.circle")
                        .foregroundStyle(model.faceCount > 0 ? .green : .orange)
                    Text(model.faceCount > 0 ? "检测到 \(model.faceCount) 张人脸" : "未检测到人脸")
                        .font(.caption)
                }
                Text("形变与局部修饰依赖人脸关键点，未检测到人脸时不生效。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
        }
        .frame(width: 176)
        .padding(.vertical, 10)
        .background(Color.secondary.opacity(0.06))
    }

    // MARK: - 预览区

    private var displayImage: CGImage? {
        model.showingOriginal
            ? model.originalImage
            : (model.previewImage ?? model.originalImage)
    }

    private var previewArea: some View {
        ZStack {
            Color.secondary.opacity(0.08)

            if let image = displayImage {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .scaledToFit()
                    .padding(18)
            } else if model.isAnalyzing {
                ProgressView("正在分析照片…")
            } else {
                ContentUnavailableView(
                    "尚无照片",
                    systemImage: "photo",
                    description: Text("选择一张照片，或恢复内置示例图")
                )
            }

            VStack {
                if let message = model.errorMessage {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                        Text(message).font(.caption)
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(.orange)
                    .padding(10)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(.regularMaterial)
                    )
                    .padding(12)
                }
                if let unavailable = model.engineUnavailable {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                        Text(unavailable).font(.caption)
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(.orange)
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 8).fill(.regularMaterial))
                    .padding(.horizontal, 12)
                }
                Spacer()
                HStack(spacing: 12) {
                    Text(model.statusMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer()
                    if let ms = model.lastRenderMilliseconds {
                        Text(String(format: "渲染 %.0f ms", ms))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    if model.isRendering {
                        ProgressView().controlSize(.small)
                    }
                    Toggle(isOn: $model.showingOriginal) {
                        Label("原图", systemImage: "eye")
                    }
                    .toggleStyle(.button)
                    .platformHelp("切换查看原图 / 效果")
                }
                .padding(12)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 底部参数面板

    private var parameterPanel: some View {
        let category = model.selectedCategory
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(category.title).font(.headline)
                    Text(category == .presets
                         ? "一键套用参数，或把全部滑杆恢复默认"
                         : category.summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if !category.parameters.isEmpty {
                    Button("重置本组") { model.reset(category) }
                        .buttonStyle(.borderless)
                }
                Button("恢复自然") { model.apply(.natural) }
                    .buttonStyle(.borderless)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Divider()

            Group {
                if category == .presets {
                    presetPanel
                } else {
                    ScrollView {
                        LazyVGrid(
                            columns: [
                                GridItem(.flexible(minimum: 220), spacing: 20),
                                GridItem(.flexible(minimum: 220), spacing: 20)
                            ],
                            spacing: 14
                        ) {
                            ForEach(category.parameters) { definition in
                                ParameterSlider(definition: definition, model: model)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                    }
                }
            }
            .frame(maxHeight: .infinity)
            .disabled(model.engineUnavailable != nil)
        }
        .frame(height: 236)
        .background(Color.secondary.opacity(0.06))
    }

    private var presetPanel: some View {
        HStack(spacing: 12) {
            ForEach([BeautyPreset.original, .natural, .refined]) { preset in
                Button {
                    model.apply(preset)
                } label: {
                    VStack(alignment: .leading, spacing: 8) {
                        Label(preset.title, systemImage: presetSymbol(preset))
                            .font(.headline)
                        Text(preset.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.leading)
                        Spacer(minLength: 0)
                        if model.activePreset == preset {
                            Label("当前", systemImage: "checkmark.circle.fill")
                                .font(.caption)
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(model.activePreset == preset
                                  ? Color.accentColor.opacity(0.14)
                                  : Color.secondary.opacity(0.08))
                    )
                }
                .buttonStyle(.plain)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("说明").font(.headline)
                Text("每个参数都有默认值。拖动任意滑杆会自动切换到「自定义」；导出时按全分辨率重新处理，预览始终使用 1024 代理图。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
    }

    private func presetSymbol(_ preset: BeautyPreset) -> String {
        switch preset {
        case .original: return "photo"
        case .natural: return "leaf"
        case .refined: return "sparkles"
        case .custom: return "slider.horizontal.3"
        }
    }

    // MARK: - 图片载入

    @MainActor
    private func loadFromPhotos(_ item: PhotosPickerItem?) async {
        guard let item else { return }
        do {
            guard let data = try await item.loadTransferable(type: Data.self) else {
                pickerError = "这张照片无法读取，请换一张"
                return
            }
            model.load(data: data, name: "相册照片")
        } catch {
            pickerError = error.localizedDescription
        }
    }
}

/// 悬停提示只在 macOS 提供；iOS 上退化为无操作，保持双平台编译一致。
private extension View {
    @ViewBuilder
    func platformHelp(_ text: String) -> some View {
        #if os(macOS)
        self.help(text)
        #else
        self
        #endif
    }
}

/// 单条参数滑杆：标题、当前值、默认值回退按钮、说明。
private struct ParameterSlider: View {
    let definition: ParameterDefinition
    let model: BeautyStudioModel

    private var value: Float {
        model.parameters[keyPath: definition.keyPath]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(definition.title)
                    .font(.subheadline)
                Spacer(minLength: 4)
                Text(String(format: "%.2f", value))
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                if abs(value - definition.defaultValue) > 0.001 {
                    Button {
                        model.reset(definition)
                    } label: {
                        Image(systemName: "arrow.counterclockwise.circle")
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .platformHelp("恢复默认值 \(String(format: "%.2f", definition.defaultValue))")
                }
            }
            Slider(value: model.binding(for: definition), in: 0...1)
                .controlSize(.small)
            if !definition.hint.isEmpty {
                Text(definition.hint)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }
}
