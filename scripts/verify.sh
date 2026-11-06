#!/bin/bash
# 一次性固定验证入口：命令字符串恒定，便于客户端缓存授权；
# 所有 SwiftPM 缓存/构建产物都落在仓库内 build/（已 gitignore），不写 ~ 目录。
set -o pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$ROOT/build/swiftpm"
mkdir -p "$BUILD/cache" "$BUILD/scratch-alg" "$BUILD/scratch-kit"

# SwiftPM manifest 编译在本机会偶发 `sandbox_apply: Operation not permitted`
# （见 AGENTS.md / 台账），统一禁用 SwiftPM 自身沙箱以保证可重复。
# 注意：这是 SwiftPM 的子进程沙箱，与客户端执行层的权限弹窗无关。
COMMON=(--cache-path "$BUILD/cache" --disable-sandbox)

echo "=== ADR-005 guard ==="
bash "$ROOT/scripts/check_no_apple_imports.sh" || exit 1

echo "=== BFAlgorithms ==="
swift test "${COMMON[@]}" --scratch-path "$BUILD/scratch-alg" \
  --package-path "$ROOT/Packages/BFAlgorithms" 2>&1 | tail -12
ALG=${PIPESTATUS[0]}

echo "=== BFKit ==="
swift test "${COMMON[@]}" --scratch-path "$BUILD/scratch-kit" \
  --package-path "$ROOT/Packages/BFKit" 2>&1 | tail -12
KIT=${PIPESTATUS[0]}

echo "=== AutoBeauty build ==="
swift build "${COMMON[@]}" \
  --scratch-path "$BUILD/scratch-auto" \
  --package-path "$ROOT/Tools/AutoBeauty" 2>&1 | tail -12
AUTO=${PIPESTATUS[0]}

echo "=== App sources typecheck (SwiftPM harness) ==="
# Xcode 在本机解析本地包时会触发嵌套沙箱失败，故用 SwiftPM harness
# 把 App 源码作为一个 target 编译，验证 SwiftUI / @Observable 类型正确。
mkdir -p "$BUILD/appcheck/Sources"
cp "$ROOT"/BeautyFaceDemo/BeautyFaceDemo/*.swift "$BUILD/appcheck/Sources/"
cat > "$BUILD/appcheck/Package.swift" <<'MANIFEST'
// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "AppCheck",
    platforms: [.macOS(.v15), .iOS(.v18)],
    dependencies: [
        .package(path: "../../../Packages/BFKit"),
        .package(path: "../../../Packages/BFAlgorithms"),
    ],
    targets: [
        .target(
            name: "AppCheck",
            dependencies: [
                .product(name: "BFKit", package: "BFKit"),
                .product(name: "BFAlgorithms", package: "BFAlgorithms"),
            ],
            path: "Sources"
        ),
    ]
)
MANIFEST
swift build "${COMMON[@]}" \
  --scratch-path "$BUILD/scratch-appcheck" \
  --package-path "$BUILD/appcheck" 2>&1 | tail -10
APP=${PIPESTATUS[0]}

echo "=== RESULT BFAlgorithms=$ALG BFKit=$KIT AutoBeauty=$AUTO App=$APP ==="
[ "$ALG" -eq 0 ] && [ "$KIT" -eq 0 ] && [ "$AUTO" -eq 0 ] && [ "$APP" -eq 0 ]
