#!/bin/bash
# M8 效果调试固定入口：命令字符串恒定，输出 M8 开 / 关两组图 + 数值对比。
# 用法：bash scripts/render_m8.sh [输出目录]
set -o pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:-/tmp/bf-m8/ab}"
BUILD="$ROOT/build/swiftpm"

RUN=(swift run --disable-sandbox
  --package-path "$ROOT/Tools/AutoBeauty"
  --cache-path "$BUILD/cache"
  --scratch-path "$BUILD/scratch-auto"
  AutoBeauty)

# 只开脸型（形变足以暴露颈肩过渡），颜色参数全关以便逐像素比较。
FLAGS=(--no-config --quality preview
  --smooth 0 --white 0 --bright 0 --eye 0 --teeth 0 --dark-circle 0 --blemish 0
  --face-size 1 --jaw 1 --v-face 1 --chin 1)

echo "=== M8 开启 ==="
"${RUN[@]}" "${FLAGS[@]}" --dump-neck --dump-body --output "$OUT/on" 2>&1 | tail -30
ON=${PIPESTATUS[0]}

echo "=== M8 关闭（M5 基线） ==="
"${RUN[@]}" "${FLAGS[@]}" --no-body --output "$OUT/off" 2>&1 | tail -12
OFF=${PIPESTATUS[0]}

echo "=== RESULT on=$ON off=$OFF ==="
[ "$ON" -eq 0 ] && [ "$OFF" -eq 0 ]
