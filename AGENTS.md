# 工程约定

## 文件访问范围（强制）

- 只允许读取/写入当前工作目录（本仓库）与 `/tmp` 下的文件。
- 禁止读取工作目录和 `/tmp` 之外的任何文件，包括但不限于：
  - `~/Library/...`（DerivedData、DiagnosticReports、日志等）
  - `/var/folders/...`
  - 用户主目录其他位置、其他项目目录
- 需要临时脚本、截图、构建产物时，统一放到 `/tmp` 或工作目录内的 `build/`（已被 `.gitignore` 排除）。
- 构建 Xcode 工程时使用工程内派生数据目录，例如：
  `xcodebuild ... -derivedDataPath build/DerivedData`
- 例外：App 调试运行时产生在工作目录以外的日志文件（如 `~/Library/Logs`、`~/Library/Containers/.../Logs`、DerivedData 日志）允许读取，仅用于排查问题；无关文件仍然禁止。
- 如确需访问上述范围外的其他路径，必须先向用户说明原因并获得明确许可。

## 调试素材（强制）

- 开发与调试核心功能时，优先直接读取 `SampleImages/` 目录中的照片，不依赖系统相册或 PhotosPicker。
- `SampleImages/` 中任意一张照片都可以用于测试与调试。
- 自动化验证（截图、脚本）应使用 `SampleImages/` 中的固定素材，保证可重复。
- `SampleImages/` 已被 `.gitignore` 排除，不提交到仓库。

## 提交与推送

- 判断取得里程碑进展时，可以自行提交并推送，无需逐次确认。
