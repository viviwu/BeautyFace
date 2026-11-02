#!/usr/bin/env bash
# 检查 BFAlgorithms/Sources 是否 import 了 Apple 框架或 Foundation（ADR-005）。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/Packages/BFAlgorithms/Sources"
PATTERN='^[[:space:]]*(@testable[[:space:]]+)?import[[:space:]]+(UIKit|AppKit|Foundation|SwiftUI|Combine|Metal|MetalKit|MetalPerformanceShaders|Vision|CoreImage|CoreGraphics|CoreVideo|ImageIO|AVFoundation|Accelerate|os|simd|Darwin)\b'
if grep -rEn "$PATTERN" "$SRC"; then
    echo "错误：BFAlgorithms 中存在平台依赖的 import（违反 ADR-005）" >&2
    exit 1
fi
echo "通过：BFAlgorithms 无平台依赖 import"
