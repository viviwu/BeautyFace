#!/usr/bin/env bash
# 从 SampleImages/ 生成 App 的内置默认示例照片。
# 生成的 jpg 含真实人像，已被 .gitignore 排除，不提交到仓库。
# 未执行本脚本时，App 会自动回退到程序化绘制的示意人像。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE="${1:-$ROOT/SampleImages/IMG_0789.HEIC}"
TARGET_DIR="$ROOT/BeautyFaceDemo/BeautyFaceDemo/Resources"
TARGET="$TARGET_DIR/DefaultPortrait.jpg"

if [[ ! -f "$SOURCE" ]]; then
  echo "找不到源照片：$SOURCE" >&2
  echo "用法：$0 <人像照片路径>（默认 SampleImages/IMG_0789.HEIC）" >&2
  exit 1
fi

mkdir -p "$TARGET_DIR"
sips -s format jpeg -s formatOptions 85 -Z 1600 "$SOURCE" --out "$TARGET" >/dev/null
echo "已生成 $TARGET（长边 1600，不入库）"
