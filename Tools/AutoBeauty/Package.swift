// swift-tools-version: 6.0
// AutoBeauty：macOS 快速调试工具，批量读取 SampleImages 并输出到 processed/。
import PackageDescription

let package = Package(
    name: "AutoBeauty",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "AutoBeauty", targets: ["AutoBeauty"]),
    ],
    dependencies: [
        .package(path: "../../Packages/BFKit"),
    ],
    targets: [
        .executableTarget(
            name: "AutoBeauty",
            dependencies: [.product(name: "BFKit", package: "BFKit")],
            path: "Sources/AutoBeauty"
        ),
    ]
)
