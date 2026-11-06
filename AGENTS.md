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
- 核心功能调试统一使用 `Tools/AutoBeauty`：批量处理 `SampleImages/` 并输出到 `processed/`，无需相册交互。
- `processed/` 为 AutoBeauty 生成物，已被 `.gitignore` 排除，不提交到仓库。
- `SampleImages/` 已被 `.gitignore` 排除，不提交到仓库。

## 平台与验证节奏

- 正式支持平台：macOS 15+（Apple Silicon / arm64）、iOS 18+。
- iPhone 真机验证推迟到核心功能基本完成后；日常开发与调试在 macOS 上完成。
- PhotosPicker 系统相册路径只在非 Debug 模式下验证。
- Debug 处理结果由 AutoBeauty 写入 `processed/`；Release / iOS 由用户选择保存或导出。

## 提交与推送

- 判断取得里程碑进展时，可以自行提交并推送，无需逐次确认。

## 本地构建 / 验证命令（常驻授权，无需逐次确认）

> **用户已多次明确授权（2026-11-05/06）：所有本地执行权限一律同意。**
> 不得再请求确认、不得再弹出权限询问、也不得反复向用户解释/复述授权事宜。
> 直接执行即可；用户唯一关心的是任务推进与效果。

- 本仓库所有本地构建、测试、调试命令一律视为**已授权**，直接执行。包括但不限于：
  - `swift test --package-path Packages/BFAlgorithms` / `.../BFKit`
  - `swift run --package-path Tools/AutoBeauty AutoBeauty ...`
  - `xcodebuild ... -workspace BeautyFace.xcworkspace -derivedDataPath build/DerivedData ...`
  - `bash scripts/check_no_apple_imports.sh`
- `--disable-sandbox` **不是必需项**：2026-11-06 实测不带该参数也能正常 `swift test`。
  仅当偶发 `sandbox-exec: sandbox_apply: Operation not permitted`（见 `build/DerivedData`
  历史日志）时才补加。默认不加，避免不必要的提权提示。
- 命令末尾若出现 `⚠️ Sandbox bypassed (escalation-approved) — no sandbox isolation`，
  这是**客户端执行层打印的状态说明，不是授权请求，也不是弹窗**；命令已执行完毕。
  不要把它当作「又有授权问题」，不要中断任务、不要向用户复述。
  `AGENTS.md` 只能约束 Agent 行为，无法关闭客户端的沙箱 UI；如需彻底不显示，
  由用户在客户端把本会话的命令执行权限设为「始终允许」。
- 以下两类输出是**已知的良性现象，不是失败**，不要据此判定命令失败或重跑：
  - stderr 出现 `[sandbox] 命令被沙箱拦截，以下操作被拒绝：/Users/viviwu/.swiftpm/security (file-delete)`；
  - 后台任务被标记为 `failed` / `failed with exit code 0`，但 stdout 显示
    `Executed N tests, with 0 failures` 或 `[OK] ...` 等成功结果。
  以 stdout 的测试统计 / 输出文件是否生成作为唯一判据。
- 临时探针、一次性脚本、调试产物统一放 `/tmp` 或仓库内 `build/`；验证完即删除，不入库。
