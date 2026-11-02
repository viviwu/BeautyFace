import SwiftUI
import PhotosUI
import ImageIO

/// M0：选图并显示原图。同时支持 macOS（Apple Silicon）与 iOS，不依赖 UIKit / AppKit。
/// M1 起替换为 BFKit 的解码管线。
struct ContentView: View {
    @State private var selection: PhotosPickerItem?
    @State private var image: CGImage?
    @State private var errorMessage: String?

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

                PhotosPicker("选择照片", selection: $selection, matching: .images)
                    .buttonStyle(.borderedProminent)

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
}
