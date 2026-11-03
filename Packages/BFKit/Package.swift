// swift-tools-version: 6.0
// BFKit：依赖 Apple 框架的 SDK 层（Core、Vision、Render、Pipeline）
import PackageDescription

let package = Package(
    name: "BFKit",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "BFKit", targets: ["BFKit"]),
    ],
    dependencies: [
        .package(path: "../BFAlgorithms"),
    ],
    targets: [
        .target(name: "BFKit",
                dependencies: [.product(name: "BFAlgorithms", package: "BFAlgorithms")],
                path: "Sources/BFKit"),
        .testTarget(name: "BFKitTests",
                    dependencies: [
                        "BFKit",
                        .product(name: "BFAlgorithms", package: "BFAlgorithms"),
                    ],
                    path: "Tests/BFKitTests"),
    ]
)
