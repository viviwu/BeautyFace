// swift-tools-version: 6.0
// BFAlgorithms：纯 Swift 算法层，不 import 任何 Apple 框架（ADR-005）
import PackageDescription

let package = Package(
    name: "BFAlgorithms",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "BFAlgorithms", targets: ["BFAlgorithms"]),
    ],
    targets: [
        .target(name: "BFAlgorithms", path: "Sources/BFAlgorithms"),
        .testTarget(name: "BFAlgorithmsTests", dependencies: ["BFAlgorithms"],
                    path: "Tests/BFAlgorithmsTests"),
    ]
)
