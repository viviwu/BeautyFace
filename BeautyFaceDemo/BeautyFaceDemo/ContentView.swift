import SwiftUI
import PhotosUI
import ImageIO

/// M0：选图并显示原图。同时支持 macOS（Apple Silicon）与 iOS，不依赖 UIKit / AppKit。
/// M1 起替换为 BFKit 的解码管线。
struct ContentView: View {
    @State private var selection: PhotosPickerItem?
    @State private var image: CGImage?
    @State private var errorMessage: String?
    #if DEBUG
    @State private var sampleIndex = 0
    #endif

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                if let image {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .scaledToFit()
                } else {
                    ContentUnavailableView(
                        "尚未选择图片",
                        systemImage: "photo",
                        description: Text("点击下方按钮从相册选择一张照片")
                    )
                }

                #if DEBUG
                Button("载入示例图") {
                    loadNextSample()
                }
                .buttonStyle(.bordered)

                Button("选择照片") {
                    // Debug 下不自动打开系统相册，改用 SampleImages 便于自动化。
                }
                .buttonStyle(.borderedProminent)
                .disabled(true)
                #else
                PhotosPicker("选择照片", selection: $selection, matching: .images)
                    .buttonStyle(.borderedProminent)
                #endif

                if let errorMessage {
                    Text(errorMessage).foregroundStyle(.red)
                }
            }
            .padding()
            .navigationTitle("BeautyFace")
        }
        .onChange(of: selection) { _, newItem in
            Task { await load(newItem) }
        }
        #if DEBUG
        .task {
            if image == nil { loadNextSample() }
        }
        #endif
    }

    private func load(_ item: PhotosPickerItem?) async {
        guard let item else { return }
        do {
            guard let data = try await item.loadTransferable(type: Data.self),
                  let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                errorMessage = "无法读取所选图片"
                return
            }
            image = cgImage
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    #if DEBUG
    /// 直接读取仓库内 `SampleImages/` 的图片，供开发调试与自动化验证使用。
    private static let sampleDirectory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("SampleImages", isDirectory: true)

    private func loadNextSample() {
        let fm = FileManager.default
        let allowedExtensions: Set<String> = ["jpeg", "jpg", "png", "heic"]
        let urls = (try? fm.contentsOfDirectory(
            at: Self.sampleDirectory,
            includingPropertiesForKeys: nil
        ))?
            .filter { allowedExtensions.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent } ?? []

        guard !urls.isEmpty else {
            errorMessage = "SampleImages 目录中没有可用图片"
            return
        }

        let url = urls[sampleIndex % urls.count]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            errorMessage = "无法读取 \(url.lastPathComponent)"
            return
        }
        image = cgImage
        errorMessage = nil
        sampleIndex += 1
    }
    #endif
}
