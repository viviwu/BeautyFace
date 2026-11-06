# BeautyFace 开发台账

本台账记录从 v1 启动（2026-10-26）起的架构决策、里程碑、计划、风险与变更。

## 0. 使用约定

- **ADR**（架构决策记录）一经接受不修改内容。若要推翻，新增一条 ADR 并把旧条目的状态改为「被 ADR-XXX 取代」。
- **里程碑**状态取值：`未开始` / `进行中` / `已完成` / `阻塞`。
- **每次完成一个里程碑**，更新状态表并在变更日志中记一行。
- **风险**发生或被消除时更新风险登记表。
- 台账只记录决定与进展，设计细节写在 README 或代码注释中。

---

## 1. 架构决策记录（ADR）

| 编号 | 标题 | 状态 | 日期 |
|---|---|---|---|
| ADR-001 | 第一版只处理静态图片 | 已接受 | 2026-10-26 |
| ADR-002 | 检测只用 Vision，不引入第三方库 | 已接受 | 2026-10-26 |
| ADR-003 | 部署目标 iOS 18，验收机型 iPhone 17 / Air | 已接受 | 2026-10-26 |
| ADR-004 | 工作与输出上限 4096 长边 | 已接受 | 2026-10-26 |
| ADR-005 | 算法层用纯 Swift，不依赖平台框架 | 已接受 | 2026-10-26 |
| ADR-006 | 形变采用 MLS，单次重采样 | 已接受 | 2026-10-26 |
| ADR-007 | 处理顺序：颜色与平滑 → 几何 → 美妆 | 已接受 | 2026-10-26 |
| ADR-008 | 美妆素材程序化生成 | 已接受 | 2026-10-26 |
| ADR-009 | 身体仅做颈肩协调，不做精细塑形 | 已接受 | 2026-10-26 |
| ADR-010 | 纹理格式 rgba16Float，在 gamma 空间处理 | 已接受 | 2026-10-26 |
| ADR-011 | 视频与实时预览延后，接口不阻碍后续加入 | 已接受 | 2026-10-26 |
| ADR-012 | 多人脸逐张独立处理 | 已接受 | 2026-10-26 |
| ADR-013 | 先以 Mac（Apple Silicon）为主开发调试，iPhone 为最终验收 | 已接受 | 2026-11-02 |
| ADR-014 | macOS（Apple Silicon / arm64）为正式支持平台 | 已接受 | 2026-11-03 |
| ADR-015 | 独立 AutoBeauty 命令行工具作为调试入口 | 已接受 | 2026-11-03 |

### ADR-001 第一版只处理静态图片
- **背景**：需求中包含实时相机与视频，但第一版的核心目标是尽快做出可用的图片美化。
- **决定**：v1 只处理静态图片。
- **后果**：不需要检测流水线、关键点平滑和异步调度；架构保留 `MTLTexture` 输入输出接口，便于后续复用。

### ADR-002 检测只用 Vision，不引入第三方库
- **背景**：商用许可未定；MediaPipe 的代码与模型许可需逐一确认；dlib 的 68 点模型训练数据限制商用。
- **决定**：人脸、人像分割、人体姿态全部使用 Vision。
- **后果**：关键点为 76 点，眼、鼻、美瞳精度有限，作为 B 级功能的已知限制。若后续引入 MediaPipe，需新增 ADR 并完成模型许可评估。

### ADR-003 部署目标 iOS 18，验收机型 iPhone 17 / Air
- **背景**：iPhone 17 系列出厂预装 iOS 26，无法运行 iOS 18；部署目标只需不高于 26。
- **决定**：部署目标 iOS 18；真机验收在 iPhone 17 与 iPhone Air 上进行，系统为 iOS 26。
- **后果**：iOS 18 的兼容性只能通过编译与模拟器验证，在验收中需注明。

### ADR-004 工作与输出上限 4096 长边
- **背景**：4800 万像素原图（约 8064×6048）在 rgba16Float 下单张纹理约 390MB，流水线中间结果叠加会超出内存安全范围。
- **决定**：解码阶段缩放到长边 ≤ 4096；输出同样为该尺寸。
- **后果**：原图会被缩小；全分辨率输出需分块处理，推迟到 v1 之后。UI 中需向用户说明输出尺寸。

### ADR-005 算法层用纯 Swift，不依赖平台框架
- **背景**：Android 版本未来需要；C++ 版本需要一个可对照的参考实现。
- **决定**：`BFAlgorithms` 只使用标准库，不 `import` 任何 Apple 框架；输入输出为基础类型。
- **后果**：算法可在 Mac 命令行测试；Swift 版本成为将来 C++ 移植的参考（oracle），需保存输入输出样本。移植成本约一到两周。

### ADR-006 形变采用 MLS，单次重采样
- **背景**：需要自然的脸型与五官形变，同时控制 GPU 重采样次数以减少模糊。
- **决定**：使用 Schaefer 等人 2006 年的 MLS 图像变形算法，在 ROI 的粗网格上求位移场，双线性插值到全分辨率；脸部与颈肩位移合并后只做一次 warp。
- **后果**：大幅度形变需要位移上限与折叠检测；TPS 作为备选，若 MLS 效果不佳再评估。

### ADR-007 处理顺序：颜色与平滑 → 几何 → 美妆
- **背景**：美妆需要与变形后的五官对齐；几何变形不应重复模糊颜色效果。
- **决定**：先做颜色与平滑，再合并位移做一次几何变换，关键点经同一 MLS 映射后再做美妆。
- **后果**：美妆依赖变形后的关键点；蒙版在几何变换前后需要分别管理。

### ADR-008 美妆素材程序化生成
- **背景**：避免美术素材的许可与制作成本；参数化便于调整风格。
- **决定**：口红、眼影、腮红、眉毛全部由颜色（Lab 或 HSL）、形状蒙版与混合模式生成；预设只保存参数。
- **后果**：写实度低于真实素材；需要投入调参时间；后续可加入自定义颜色。

### ADR-009 身体仅做颈肩协调，不做精细塑形
- **背景**：身体部分不是本版重点，只需保证脸与颈肩过渡自然。
- **决定**：脸部位移沿颈部向下衰减，到肩线为 0；位移限制在人像蒙版内；小头（B 级）以颈根为中心衰减缩放。
- **后果**：瘦腰、瘦腿等功能归入 C 级。

### ADR-010 纹理格式 rgba16Float，在 gamma 空间处理
- **背景**：8 位纹理在磨皮与形变采样时易产生色带；线性空间处理会增加复杂度并改变视觉效果。
- **决定**：内部统一使用 rgba16Float；颜色运算在 gamma 空间进行；输出保留源图的 ICC 配置。
- **后果**：若后续出现明显的混合或光照问题，需重新评估线性空间，新增 ADR 推翻本条。

### ADR-011 视频与实时预览延后
- **背景**：实时预览需要 30fps 的流水线与追踪平滑，会显著增加 v1 的复杂度。
- **决定**：v1 不做；接口只接收 `MTLTexture`，不绑定图片来源。
- **后果**：后续加入实时预览时需要新增检测流水线与关键点平滑，可能需要重新评估 ADR-004 的工作分辨率。

### ADR-012 多人脸逐张独立处理
- **背景**：多人合影时每张脸的参数需要独立。
- **决定**：每张脸独立生成蒙版与位移场，最后合并到同一帧；参数按脸分别保存。
- **后果**：多脸时计算量线性增加；需要处理脸之间的重叠区域，M5 中验证。

### ADR-013 先以 Mac（Apple Silicon）为主开发调试，iPhone 为最终验收
- **背景**：真机部署与签名流程较慢，M0–M7 的大部分工作是算法与调参，需要快速的编辑-运行循环。Mac 与 iPhone 同为 Apple Silicon，Metal、Vision、ImageIO 的 API 与行为基本一致。
- **决定**：App 工程同时包含 My Mac 与 iPhone 目标，日常开发以 My Mac 运行和调试；SDK 与 App 代码保持平台无关（不使用 UIKit / AppKit，图片用 CGImage）。每个里程碑完成前至少在真机上做一次冒烟测试；M10 的性能与内存验收只以 iPhone 17 / Air 为准。
- **后果**：
  - Mac 的 GPU 与内存与 A 系列不同，Mac 上的耗时与内存数据不能作为验收依据。
  - 不能使用 `.managed` 类型的 Metal 存储模式（iOS 不支持），纹理统一使用 `.private` 或 `.shared`。
  - Mac App 默认启用 App Sandbox；导出到相册时需按 iOS 的权限模型补充配置。
  - 部署目标保持不变（iOS 18、macOS 15）；Mac 版不改变 ADR-003 的验收机型。

### ADR-014 macOS（Apple Silicon / arm64）为正式支持平台
- **背景**：ADR-013 将 Mac 定位为开发调试环境；产品需求已明确 macOS 与 iOS 均为正式交付平台，Mac 用户需要同等完整的功能与导出能力。
- **决定**：macOS 15+（Apple Silicon / arm64）与 iOS 18+ 并列为正式支持平台；两平台共享同一套 BFKit / BFAlgorithms 与 SwiftUI App；性能验收仍以 iPhone 17 / iPhone Air 为准，Mac 端只做功能与稳定性验收。
- **后果**：
  - 不使用仅 iOS 可用的 API；不依赖 UIKit / AppKit。
  - 导出路径需同时适配两平台：iOS 走相册 / Files，macOS 走文件面板。
  - 维持 ADR-013 的「Mac 数据不作为性能验收依据」；需要时另立 Mac 性能目标。

### ADR-015 独立 AutoBeauty 命令行工具作为调试入口
- **背景**：M0–M7 的主要工作是算法与调参，通过 App + 相册选择验证需要人工点击；Debug 读取仓库素材还需关闭 App Sandbox，影响工程配置与安全边界。
- **决定**：新增独立 SwiftPM 可执行包 `Tools/AutoBeauty`，依赖 BFKit，直接读取 `SampleImages/` 并批量输出到仓库 `processed/`；BeautyFaceDemo 恢复为始终使用 PhotosPicker，Debug 沙盒保持开启。
- **后果**：
  - 核心功能验证不依赖相册与 UI，便于脚本化与前后对比。
  - `processed/` 为生成物，加入 `.gitignore`，不进入版本库。
  - AutoBeauty 与 App 共享同一处理管线，避免两套实现；M1 起以该工具作为恒等 / 处理回归入口。

### ADR-016 BeautyEngine 拆分为 analyze / render 两步
- **背景**：M9 要接入滑杆式实时调参。原 `process(...)` 每次调用都重新跑 Vision 检测、人像蒙版、皮肤蒙版与局部修饰蒙版，拖动一次滑杆就要重复数百毫秒到数秒的分析，交互不可接受。
- **决定**：新增公开的 `BeautyAnalysis`（`DecodedImage` + `DetectionResult` + `SkinMask` + `RetouchMask` + 质量档位），提供 `analyze(decoded:quality:)` 与 `render(analysis:parameters:)`；`process(...)` 保留为两者组合的兼容入口，行为不变。换图时分析一次，调参时只渲染；导出时按 `.full` 重新分析一次（蒙版分辨率与关键点像素坐标随质量档位变化，不能复用预览档蒙版）。
- **后果**：
  - AutoBeauty 等一次性调用方无需改动；App 可以做到检测只跑一次。
  - 质量档位与分析结果必须成对使用，跨档复用蒙版会产生错位。
  - App 侧需串行化对引擎的访问，并用 generation token 丢弃过期渲染结果。

### ADR-017 App 启动自动载入默认示例照片，真实人像不入库
- **背景**：需求要求启动即有可处理的照片，用户可再用相册替换；ADR-015 中「App 始终使用 PhotosPicker」的结论与目标冲突。同时真实人像属于隐私素材，不能进入版本库。
- **决定**：`BeautyStudioView.onAppear` 自动载入 bundle 内 `Resources/DefaultPortrait.jpg`；该 JPG 由 `scripts/install_default_portrait.sh` 从 `SampleImages/IMG_0789.HEIC` 本地生成，加入 `.gitignore`。文件缺失时回退到 `SamplePortrait.swift` 程序化绘制的示意人像。相册（PhotosPicker）与「打开文件」用于替换，工具栏可一键恢复默认图。
- **后果**：
  - 取代 ADR-015 中「App 始终使用 PhotosPicker」的表述；AutoBeauty 仍作为无 UI 的批量调试入口。
  - 干净检出不会缺失资源，但示意人像没有人脸关键点，形变与局部修饰不生效；效果验证需先运行脚本生成真实照片。
  - 工程使用 Xcode 16 文件同步组，新资源无需手工登记到 pbxproj。

---

## 2. 里程碑与状态

| 编号 | 名称 | 主要内容 | 完成标准 | 估计工期 | 状态 |
|---|---|---|---|---|---|
| M0 | 骨架 | 工程、Swift Package、SwiftUI 空壳、素材目录 | 能选图并显示 | 2–3 天 | 已完成（Mac；真机待补） |
| M1 | 图像管线 | 解码、EXIF、缩放、rgba16Float、编码输出 | 恒等处理误差 ≤ 1 个灰阶 | 3–4 天 | 已完成（Mac） |
| M2 | 检测与调试视图 | Vision 脸框、76 点、人像蒙版、多脸、调试绘制 | 样图关键点正确，多脸分别输出 | 4–5 天 | 已完成（Mac） |
| M3 | 皮肤 | 皮肤蒙版、磨皮、美白/淡化肤色、增亮/提亮、预览与全分辨率 | 边缘无明显伪影，背景不变 | 1 周 | 已完成（Mac） |
| M4 | 局部修饰 | 亮眼、白牙、去黑眼圈、去黑点/痘印 | 效果可控，唇与眼白不被误伤 | 4 天 | 已完成（Mac） |
| M5 | MLS 与脸型 | MLS 求解器、位移场、单次 warp、小脸/瘦脸/窄脸/V 脸/下巴/额头/颧骨 | 大幅度形变无折叠，背景不变形 | 1.5 周 | 已完成（Mac） |
| M6 | 五官形变 | 大眼、眼距、眉间距、眉毛粗细、鼻翼、嘴型 | 五官比例自然 | 1 周 | 已完成（Mac） |
| M7 | 程序化美妆 | 口红、腮红、眉毛、眼妆，基于变形后关键点 | 随脸型变形仍对齐 | 1 周 | 已完成（Mac） |
| M8 | 颈肩协调 | 沿颈纵向衰减到肩线为 0、人像蒙版内约束（A 级）；小头联动拆出 M8.1（B 级，见 3.12） | 脸与颈过渡无明显断裂；肩线以下与人像蒙版外位移严格 0；背景 / 白 T 恤逐像素不变 | 4–5 天 | **已完成（Mac，2026-11-06）**：双素材数值验收通过、A/B 目视过渡连续；R-07 已缓解 |
| M9 | App 与 UI | 参数面板、预设、对比、导出 | 完整交互流程可用 | 1.5 周 | 界面与引擎接入已完成（arm64 交叉编译验证通过；真机与完整流程待验） |
| M10 | 验收 | 性能、真机矩阵、内存峰值、回归测试 | 通过验收清单 | 1 周 | 未开始 |

合计约 9–10 周（单人估计）。M5 为技术风险最高的里程碑，建议优先打通 MLS 原型。

### 2.1 验收清单（M10）

| 验收项 | 标准 | 工具 |
|---|---|---|
| 完整处理耗时 | iPhone 17 与 iPhone Air 各 < 1 秒（4096 长边） | os_signpost + Time Profiler |
| 预览响应 | 参数变化到画面更新 < 100 毫秒（1024 代理图） | Metal System Trace |
| 内存峰值 | 4800 万像素原图处理不闪退 | Instruments（Allocations、Memory Graph） |
| 连续稳定性 | 连续 20 张图无内存增长，耗时波动 ≤ 20% | 自动化测试 |
| 背景保护 | 蒙版外像素变化接近 0 | XCTest 快照比较 |
| 几何安全 | 位移场雅可比行列式为正 | XCTest |

---

## 3. M0 计划与验收

**目标**：工程可编译运行，能在真机上选图并显示。

**进展（2026-10-26）**：在 Linux 环境生成源码骨架（两个 Swift Package、Demo 源码、`.gitignore`、`SampleImages/` 目录、算法层平台依赖检查脚本）。Xcode 工程创建、编译、`swift test` 与真机验证需在 Mac 上完成，未验证。

**进展（2026-11-02）**：按 ADR-013 改为 Mac 优先开发。`ContentView` 改为不依赖 UIKit，使用 ImageIO 解码为 `CGImage`，可同时在 macOS 与 iOS 上编译。

**进展（2026-11-02，Mac 构建验收）**：
- 修复 SwiftPM 同名文件冲突：`Placeholder.swift` 改为带模块前缀的唯一文件名，BFAlgorithms / BFKit 均可编译。
- App Debug 改为本机签名（`CODE_SIGN_STYLE=Manual`、`CODE_SIGN_IDENTITY=-`、清空 Team），规避已吊销的 Apple Development 证书；Release 保留原 Team 配置。
- 部署目标修正为 iOS 18 / macOS 15，与 ADR-003 及两个 Package 的平台声明一致。
- `swift test`（BFAlgorithms、BFKit）通过；`xcodebuild -scheme BeautyFaceDemo -destination 'platform=macOS'` 构建通过；App 可正常启动。
- Debug 下支持直接读取 `SampleImages/`：启动自动载入示例图，「载入示例图」按钮可轮换；为允许读取仓库目录，Debug 关闭 App Sandbox（Release 保持沙盒）。PhotosPicker 在 Debug 下暂时禁用，便于自动化。
- 已通过自动化截图验证：`SampleImages/musk.jpeg` 与 `SampleImages/vivi.jpeg` 均可正常显示并可切换。
- 未覆盖项：当前环境未安装 iOS 模拟器 runtime，iPhone 设备均 Offline；PhotosPicker 系统相册路径与真机冒烟待设备可用后补做。

**进展（2026-11-03，调试工具与定位更新）**：
- 新增 `Tools/AutoBeauty`（SwiftPM 可执行包，依赖 BFKit）：批量读取 `SampleImages/`，输出到仓库 `processed/`，支持 `--input` / `--output`；M0 阶段为恒等解码 / PNG 输出。
- `ContentView` 恢复为始终使用 PhotosPicker；Debug 重新开启 App Sandbox，不再内嵌 `SampleImages` 读取逻辑。
- 平台定位更新为 macOS（arm64）+ iOS 双正式平台（ADR-014）；新增 ADR-015（AutoBeauty）。
- 功能清单补充：美白 / 淡化肤色、增亮 / 提亮、去黑点 / 痘印（A）。
- 已验证：`swift run --package-path Tools/AutoBeauty` 成功处理两张样例并写入 `processed/`。

- [x] 创建 `BeautyFace.xcworkspace`
- [x] 创建 `Packages/BFAlgorithms`，确认 `Package.swift` 不依赖 Apple 框架（已生成；`scripts/check_no_apple_imports.sh` 通过）
- [x] 创建 `Packages/BFKit`，依赖 `BFAlgorithms`（已生成）
- [x] 创建 `BeautyFaceDemo` SwiftUI App，部署目标已修正为 iOS 18
- [x] 配置 PhotosPicker 选图并显示原图（代码完成；系统相册路径待非 Debug 真机验证）
- [x] 建立 `SampleImages/` 目录（已被 `.gitignore` 排除），真机素材待拍摄放入
- [x] 修复本机构建问题：同名 `Placeholder.swift`、已吊销证书、部署目标 26.2
- [ ] 在 iPhone 17 与 iPhone Air 上运行验证（推迟到核心功能基本完成后）
- [x] 确认两个 Package 可用 `swift test` 在 Mac 上运行
- [x] 决定 `SampleImages/` 是否入库：放在项目目录内，由 `.gitignore` 排除（Q-02）

### 3.1 M1 图像管线（已完成 2026-11-03）

- **解码**：`ImageDecoder` 使用 ImageIO，支持 HEIC / JPEG / PNG；按 EXIF 方向归一；长边 > 4096 时等比缩放，不放大。
- **工作纹理**：`TextureConverter` 在 CGImage 与 `rgba16Float` Metal 纹理之间转换，保持 gamma 空间（ADR-010），纹理使用 `.shared` 存储。
- **编码**：`ImageEncoder` 保留源 EXIF / TIFF / GPS 属性与颜色空间，方向写回 1，并更新像素尺寸；支持 Data / URL 输出。
- **恒等验收**：合成测试图经「解码 → rgba16Float 纹理 → 回读 → PNG 编码 → 解码」，最大通道误差 ≤ 1 灰阶（实测 0）；覆盖缩放、方向与 EXIF 保留。
- **验证**：BFKitTests 6 项通过；`swift run --package-path Tools/AutoBeauty` 处理 `SampleImages/` 两张成功，输出到 `processed/`。

### 3.2 M2 检测与调试（已完成 2026-11-03）

- **人脸框与关键点**：`FaceDetector` 使用 `VNDetectFaceLandmarksRequest`，输出归一化人脸框、76 点关键点与各区域点集；多脸逐张输出。
- **人像蒙版**：`VNGeneratePersonSegmentationRequest`（accurate，OneComponent8），转换为 `SegmentationMask` 供后续皮肤处理与背景保护使用。
- **调试绘制**：`DetectionDebugRenderer` 输出人脸框、关键点连线/圆点与半透明蒙版，AutoBeauty 写入 `processed/<name>_debug.png`。
- **验证**：`SampleImages/musk.jpeg` 与 `vivi.jpeg` 各检测 1 张脸、76 点、蒙版非空；两张样例横向拼接后检测到 2 张脸；BFKitTests 10 项通过。
- **已知限制**：多脸仅用拼接图验证，尚未使用真实多人合影；后续补拍多人素材。

### 3.3 M3 皮肤（已完成 2026-11-03）

- **参数模型**：BFAlgorithms 新增 `BeautyParameters`（磨皮 / 美白 / 提亮，0...1 自动裁剪，`natural` 预设），保持纯 Swift、无平台依赖。
- **皮肤蒙版**：`SkinMask` + `SkinMaskGenerator`；长边 512（预览 256）生成，YCbCr 肤色软阈值 × Vision 人像蒙版，眼 / 唇用关键点多边形排除，再做可分离盒式羽化；背景由人像蒙版保护。
- **渲染**：`SkinRenderer` 用 `MPSImageGaussianBlur` 生成低频，Metal compute kernel 按蒙版混合磨皮，并在蒙版内做亮度提升（美白，含轻微降饱和）与提亮；参数全 0 时与输入一致。
- **管线**：`BeautyEngine` 串联解码 → 检测 → 皮肤蒙版 → 渲染；预览长边 1024 / 蒙版 256，全分辨率长边 ≤4096 / 蒙版 512，保留 EXIF 与颜色空间。
- **AutoBeauty**：默认输出 `processed/<name>.png`、`_debug.png`、`_skin.png`；支持 `--quality preview|full` 与 `--smooth` / `--white` / `--bright`。
- **验证**：BFAlgorithms 4 项、BFKitTests 22 项通过；两张样例与 2000×2000 放大样图均成功；预览 1024×1024、全分辨率 2000×2000；蒙版外像素最大差 ≤1 灰阶；强参数（1/1/1）目视无嘴部 / 眼部环状伪影，背景不变。
- **已知限制**：当前磨皮为高斯模糊 + 蒙版混合，强参数下纹理保留有限；引导滤波 / 高低频分离留待后续升级。真实多人合影素材仍缺失。

### 3.4 M4 局部修饰（已完成 2026-11-03）

- **参数模型**：`BeautyParameters` 新增 `eyeBrightening` / `teethWhitening` / `darkCircleRemoval` / `blemishRemoval`，同样 0...1 自动裁剪；`natural` 预设补上 0.20 / 0.15 / 0.25 / 0.30。
- **蒙版工具抽取**：把 M3 中私有的肤色/几何工具抽到 `Skin/` 下复用——`MaskImageRasterizer`（CGImage → 低分辨率 RGBA 字节）、`PolygonRasterizer`（归一化多边形 → 蒙版）、`MaskFilters`（可分离盒式模糊）、`MaskMath`（smoothstep / 区间带 / 亮度 / 饱和度 / 分位数）。`SkinMaskGenerator` 改为复用这些工具，行为不变。
- **局部蒙版**：`RetouchMask`（eye / teeth / darkCircle 三个 0...1 通道，与皮肤蒙版同分辨率）+ `RetouchMaskGenerator`。
  - 眼白：眼轮廓内「绝对亮度」与「相对眼内中位亮度」取较大者，并要求低饱和；虹膜因暗且带色被排除。
  - 牙齿：内唇多边形内的高亮、低饱和、无红偏像素；唇部因红偏与饱和度高被排除。
  - 眼下：由眼睛下缘外推椭圆，限制在皮肤蒙版内，按相对全脸平均亮度判暗；生成后减去眼白通道。
- **渲染**：`SkinRenderer` 的 compute kernel 扩展为一次性完成磨皮 / 美白 / 提亮 / 亮眼 / 白牙 / 去黑眼圈 / 去痘印；局部蒙版打包进一张 `rgba8Unorm` 纹理（r=眼白，g=牙齿，b=眼下）。
- **去痘印**：以原图的低频模糊（sigma 随长边缩放，上限 24）作为邻域底色，与原始像素亮度差作为瑕疵判据，按增益抬升像素自身亮度并向邻域色度收敛。参考亮度取自原图，因此美白 / 提亮不会抵消检测；纹理不被替换成模糊值。
- **管线与工具**：`BeautyEngine` 串联皮肤蒙版 → 局部蒙版 → 渲染，`BeautyResult` 增加 `retouchMask`；AutoBeauty 新增 `--eye` / `--teeth` / `--dark-circle` / `--blemish`，输出 `_retouch.png` 调试图，并打印各区域像素数与峰值。
- **验证**：BFAlgorithms 5 项、BFKitTests 33 项通过。新增测试覆盖：合成人像的眼白 / 虹膜 / 牙齿 / 唇 / 眼下几何、蒙版归一化与背景为零、痘印修复（含开启美白后仍生效）、三类局部修饰只影响对应蒙版区域、全参数拉满时蒙版外像素差 ≤ 1 灰阶。
- **调参记录**：
  - 眼白初版用绝对阈值 `smoothstep(0.25, 0.60)`，实测样图眼内最高亮度仅 0.35~0.55，蒙版几乎为空；改为绝对 + 相对双判据后，`musk` 眼白蒙版从 48 px / 峰值 0.62 提升到 54 px / 峰值 0.98。
  - 去痘印初版把「已美白后的像素」与模糊值比较，美白会抵消检测；改为双方都取自原图。
  - 去痘印的参考 sigma 初版仅 2.7（约等于瑕疵半径），粗模糊无法把瑕疵平均掉，实测提亮只有 4/255；改为约 8 个「1024 基准像素」后提升到 16/255 以上。
- **已知限制**：
  - 眼白在眯眼、闭眼、暗光、小图上基本无效果（这些素材本身眼白占比极低），属预期行为；`vivi.jpeg` 眼白蒙版为 0。
  - 76 点眼轮廓较粗（R-01），眼白边界不如精细关键点准确；浅色虹膜（蓝/灰）可能被误判为眼白，待后续用虹膜颜色区分。
  - 去痘印对鼻翼沟、眼睑褶等「小而暗」的结构也会轻微提亮，默认强度 0.30 下不明显，强度拉满时可见。
  - 尚无真实带痘印、带黑眼圈的高分辨率素材，仅用合成图与现有样图验证。

### 3.5 皮肤蒙版判据修正（2026-11-03）

- **触发**：用真实手机照片 `IMG_0789.HEIC` 跑 AutoBeauty 时发现白 T 恤被当作皮肤——衣物被提亮 +9.7 灰阶，领口缝线纹理被磨平。
- **实测数据**（同一张照片）：

  | 区域 | sat | Cb | Cr | luma |
  |---|---|---|---|---|
  | 额头 | 0.358 | 0.412 | 0.645 | 0.50 |
  | 左颊 | 0.403 | 0.393 | 0.652 | 0.56 |
  | 脖子 | 0.347 | 0.405 | 0.627 | 0.46 |
  | 白 T 恤 | 0.218 | 0.433 | 0.571 | 0.64 |
  | 灰墙 | 0.008 | 0.501 | 0.500 | 0.56 |

  衣物与肤色的 Cb/Cr 都落在传统肤色带内，饱和度 0.218 也远高于原闸门 `smoothstep(0.02, 0.08)`，因此纯绝对阈值无法区分。
- **决定**：检测到人脸时改用「人脸肤色参考 + 亮度归一化色度距离」判据；无人脸时保留原绝对阈值作为兜底。
  - 归一化：`((Cb-0.5)/luma, (Cr-0.5)/luma)`。漫反射下 RGB 同比缩放，该比值对阴影与高光不敏感。
  - 参考值：人脸框内缩 12%，排除眼（1.30）/ 唇（1.20）/ 眉（1.25）后取中位数；要求 luma > 0.12 且人像蒙版 > 0.5；采样不足 40 像素则退回绝对判据。
  - 阈值：内半径 0.05 + 0.02×tolerance，外半径 0.09 + 0.04×tolerance；再乘以 luma 下限 `smoothstep(0.06, 0.18)` 抑制死黑区域。
- **效果**（`IMG_0789.HEIC`，AutoBeauty 全参数）：

  | 区域 | 修改前 | 修改后 | 变化像素占比 |
  |---|---|---|---|
  | 白 T 恤 | +9.74 | **+0.11** | 99.9% → 1.35% |
  | 脸部 | +10.03 | +7.00 | — |
  | 脖子 | +15.09 | +8.44 | — |
  | 背景 | +0.00 | +0.00 | 0% |

  皮肤蒙版覆盖率 61.2% → 25.8%，`musk.jpeg` 44.9% → 27.2%，目视蒙版无空洞；领口缝线纹理保留。
- **验证**：新增 `testWarmWhiteClothingIsNotSkin`（合成图，取值来自该照片实测：受光肤色 / 压暗 40% 的同一肤色 / 暖白衣物），断言前两者 > 0.9、衣物 < 0.1。BFKitTests 34 项、BFAlgorithms 5 项通过。
- **失败的尝试**：曾试图对镜面高光做补偿，把归一化色度按 `(1-luma)/(1-refLuma)` 放大后再比距离。高光会让色度与亮度同时缩小，放大后参考向量本身也变大，方向相同的正常肤色同样被推离参考，鼻梁与面颊出现大片漏判（斑驳）。已回退，并在代码里写了注释禁止再加。
- **顺带修复**：`vivi.jpeg` 已从 `SampleImages/` 移除，`RetouchMaskTests` 的样例冒烟测试因此被静默跳过；改为 `musk.jpeg` + `IMG_0789.HEIC`，并放宽背景断言到 1e-6（浮点噪声）。
- **已知限制**：
  - 多张人脸肤色差异较大时共用同一参考（取全局中位数），深/浅肤色混合的合影可能偏向一方。
  - 强单色光（如蓝色 LED）下参考会跟着偏移，属于预期行为，但极端光照仍可能失效。
  - 衣物色度与肤色几乎重合时（例如偏暖的米白 + 冷调浅肤色），颜色判据本身无解，需要纹理或分割模型。
  - **高光与绒毛落在蒙版外**：鼻梁镜面反光、面部细小绒毛被白光稀释后归一化色度偏离参考，判为非皮肤。这些像素本身不被磨皮，而周围皮肤被磨平，因此在磨皮强度拉满时它们会凸显成亮丝。已确认与去痘印无关（单独关闭去痘印渲染仍然存在）。默认 `natural` 档下不可见，属可接受范围（R-15）。

### 3.6 磨皮改为亮度引导的保边滤波（2026-11-03）

- **触发**：M3 的高斯磨皮在强度拉满时把整张脸一起糊掉——眉毛变淡、发丝消失、五官轮廓发虚（R-11）。同时 R-15 里「高光 / 绒毛不被磨皮而周围被磨平」的对比在高斯下最刺眼，因为高斯把周围压得太平。
- **决定**：换成以原图亮度为引导图的 guided filter。窗口内拟合 `q = a·I + b`，`a = cov(I,P)/(var(I)+eps)`、`b = mean(P) - a·mean(I)`。方差 ≪ eps 的区域 `a → 0`（趋近均值，纹理被抹平），方差 ≫ eps 的区域 `a → 1`（趋近原图，边缘保留）。
- **参数**：
  - 窗口半径 `max(1, scale × (3 + 9 × smoothing))`，`scale = max(1, 长边/1024)`，换算到低分辨率再取整；
  - 正则项 `eps = 0.010 + 0.040 × smoothing`；
  - 混合权重沿用 `0.85 × smoothing × 皮肤蒙版`。
- **实现**：Fast Guided Filter。新增两个 kernel（`guidedStats` 做 4×4 方框降采样并一次算出 `(I, I², I·R, I·G)` / `(I·B, R, G, B)`；`guidedCoefficients` 求 a/b），中间用 `MPSImageBox` 做两轮方框滤波，全部在 1/4 分辨率上完成；`beautyCompose` 里双线性采样系数后回代。
  - 关键点：统计量必须同时包含 `I·P` 与 `P`，否则算不出 `cov(I,P)` 与 `mean(P)`。8 个标量正好塞进两张 `rgba16Float`，方框滤波一次搞定，不必按通道重复。
- **调参记录**：
  - 初版 eps 取 0.0035~0.008，保边过头，强度拉满时皱纹、毛孔几乎原样保留，看起来像没处理；逐档试到 **eps ≈ 0.05**（smoothing=1）才既抹平皱纹又保住眉毛与发丝。
  - eps = 0.15 时眉毛开始变淡、额头出现轻微色块，说明「半平滑点」已经越过眉毛的局部方差，因此上限定在 0.05。
- **效果**（`IMG_0789.HEIC`，2316×3088）：
  - 强度 1.0：皱纹与毛孔抹平，眉毛 / 睫毛 / 发丝 / 唇线清晰，无块状或光晕伪影；
  - `natural`（smoothing=0.35）：脸部亮度 +6.98（高斯版 +7.00，无明显漂移），背景 0.00，纯白 T 恤 0.00、变化像素 0%；
  - 耗时：同一张图 smooth=0 为 6672 ms、smooth=1 为 6652 ms，无可测差异（解码与检测占绝大部分）；同时省掉一张全分辨率高斯纹理，内存略降。
- **验证**：新增 `testSmoothingFlattensTextureButKeepsHighContrastDetail`（合成图：低幅度棋盘纹理 + 20 像素宽深色条），断言纹理幅度压到 50% 以下、深色条对比度保留 75% 以上（实测约 79%）。BFKitTests 35 项、BFAlgorithms 5 项通过。
- **已知限制**：
  - 1 像素宽的极细毛发在强度 1.0 下仍会被削弱（实测保留约 24%），成簇的眉毛 / 睫毛不受影响。
  - 该测试在旧的纯高斯实现上也能通过：旧 sigma 随图幅缩放，在 200 像素的测试图上只有 1.5，本来就没磨掉多少，因此无法用它区分两种实现；它只用于锁定「纹理要平、高对比结构要留」的行为约定。
  - 系数在 1/4 分辨率上计算，极端细密的纹理（接近 4 像素周期）会有轻微走样，实际素材中不可见。

### 3.7 M5 MLS 与脸型（已完成 2026-11-04）

- **范围**：Schaefer et al. 2006 的 MLS 刚体变形（纯 Swift，BFAlgorithms/Geometry）、7 项脸型参数（小脸/瘦脸/窄脸/V 脸/下巴/额头/颧骨）、粗网格位移场 + 雅可比折叠检查（R-02）、Metal 单次 warp 渲染器，并接入 BeautyEngine / AutoBeauty（ADR-006 / ADR-007）。
- **实现要点**：
  - `MLSSolver`：逆向映射 `f(v)`，保证 `f(p_i) = q_i` 精确成立（控制点 snap）与远场恒等（权重 `1/(d²+ε)` 衰减）。正交 Procrustes 分子与质心在同一趟循环内累加，查询一次遍历全部控制点。
  - `FaceShapeAdjuster`：76 点轮廓按纵坐标归一化 `t` 分带位移（下颌 / V 脸 / 下巴 / 额头 / 颧骨各占不同 `t` 段），单点位移上限为脸高的 10%，超出线性压缩（R-02）；沿图像边框加恒等锚点抑制远场。
  - `DisplacementField`：多张脸的控制点合入一次 MLS 求解，在长边 128 节点的粗网格上预计算位移；网格节点位移显式乘以距离衰减（到最近关键点的距离，`0.15×R` 以内不衰减、`0.45×R` 以外严格为 0，R 为该脸半径）——锚点只能压制远场，不能保证归零，衰减是「背景不变形」验收标准的关键；对场做中心差分雅可比，出现 ≤ 0 即按 0.7 整体回退强度重解（最多 12 次）。
  - `WarpRenderer`：位移场上传为 `rgba16Float` 纹理，kernel 双线性采样位移后对源图双线性重采样，整图只重采样一次；位移 ≤ 0.01px 时直接返回原图。
  - `BeautyEngine`：颜色与平滑之后、编码之前做单次 warp（ADR-007）；`BeautyResult.displacementField` 供后续美妆阶段用同一映射变换关键点。AutoBeauty 新增 7 个 `--face-*` 参数与 `_warp.png` 调试图。
- **中间踩坑**：衰减因子的属性默认值改成了 `0.15/0.45`，但 memberwise `init` 的默认值漏改（仍是 `1.0/1.6`），而 `solve` 走的是 `Config()` 初始化——生产路径一直用着旧值。表现为背景区域 40~50% 像素差异 > 2；修正后顶部墙面 2.4%（边缘过渡带）、左下 0.4%、纯白 T 恤 **0.00%**，远场严格为 0。
- **效果**（`IMG_0789.HEIC`，2316×3088）：
  - 全参数拉满（7 项）：最大位移 122.2px，最小雅可比 0.042（> 0，无折叠），强度 1.00；背景不动，衣服不动。
  - `natural` + 脸型（小脸 0.5 / 瘦脸 0.6 / V 脸 0.5）：最大位移 72.4px，最小雅可比 0.480。
  - 右侧头部邻域（y 0.55–0.65）有部分位移属设计内的混合带（发丝随脸移动，避免形变后头发与脸脱节），y 0.75 以下严格为 0。
- **性能（重要发现）**：接入后总耗时从 6.4s 涨到 12.1s，定位发现瓶颈根本不在 warp（GPU 5ms、solve 261ms），而在 `TextureConverter` 的 CPU 逐字节转换——上传路径 U8→F16 循环 2.6s、回读路径 F16→U8 循环 2.8s（2316×3088 全分辨率各 29M 次循环）。修复：位图直接放进 `rgba8Unorm` 纹理，用两个微型 kernel（`u8To16F` / `f16ToU8`）在 GPU 上完成归一化与量化，再整块搬运。修复后（Mac debug 构建）：
  - 无脸型完整管线 6393 → **1081 ms**；自然档 + 脸型 **1493 ms**；强脸型 **1460 ms**；
  - warp 自身：solve 261ms + 上传 28ms + GPU 5ms + 回读 27ms。
  - 新旧实现输出逐像素一致（max abs diff 1.9，>2 的像素 0%，纯量化舍入差）。
- **验证**：新增 `MLSSolverTests` 7 项（恒等、控制点精确、远场恒等、跟随、对称）、`FaceShapeAdjusterTests` 6 项（各参数位移方向、上限、互不干扰）、`DisplacementFieldTests` 5 项（网格恒等、雅可比为正、极端位移触发回退、多脸独立、远场 ≈ 0）、`WarpRendererTests` 3 项（恒等 ≤ 1 灰阶、形变后背景不变、零位移直接返回）。BFKitTests 38 项、BFAlgorithms 23 项通过。
- **已知限制**：
  - 位移上限 10% 脸高 + 线性压缩意味着极端参数下效果会打折，这是防折叠的设计取舍（R-02）。
  - MLS 参考混合了边界锚点，脸部整体平移类参数（如小头）尚未接入，颈肩协调（M8）需要在衰减带内嵌入人像蒙版约束。
  - 右下角头部邻域的混合带在极端参数下可感知（发丝移动），属预期；若嫌宽可调小 `falloffOuterFactor`，但要接受更硬的过渡。

---

### 3.8 M6 五官形变（已完成 2026-11-04）

- **范围**：6 项五官参数（大眼 / 眼距 / 眉间距 / 眉毛粗细 / 鼻翼 / 嘴型），复用 M5 的 MLS + 位移场 + 单次 warp 基础设施，脸型与五官合入**同一次** MLS 求解与 warp（ADR-006 / ADR-007 不变）。
- **实现要点**：
  - `FaceFeatureParameters`：6 个 0...1 参数；正方向即美化方向（眼距 / 眉间距 / 鼻翼为「变窄」，嘴型为「嘴角上扬 + 收窄」）。
  - `FaceFeatureAdjuster`：与 `FaceShapeAdjuster` 互补——只有五官点动，轮廓点归脸型。各参数的驱动方式：
    - 大眼：眼眶点绕眼睛质心**径向外移**，纵向系数 0.30 大于横向 0.18（眼裂加高比加宽更「有神」）；瞳孔近似质心，保持锚点。
    - 眼距 / 眉间距：单侧整组点做**同一水平平移**（严格保持眼形 / 眉形），相对瞳距归一（p=1 位移约 10% 瞳距）；瞳孔随眼距平移。
    - 眉毛粗细：眉形折线绕自身质心**纵向拉伸**——Vision 眉毛只有单条折线、没有厚度轮廓，靠 MLS 把眉部暗色带同步拉宽近似「变浓」，属当前数据下的近似（R-16）。
    - 鼻翼：鼻部点向鼻中轴按横向距离等比收拢（0.18 × p）。
    - 嘴型：唇部点向唇心水平收拢（0.10 × p），同时按横向距离平方加权上扬（0.22 × 唇高 × p）——嘴角抬得最多、唇中不动，形成微笑嘴型。
  - 位移上限 / 全局倍率与脸型共用 `applyDisplacementCap`（脸高的 10%，R-02）。
  - `FaceShapeAdjuster.controls` 增加 `featureControls` 注入口：传入时五官点由五官调整器负责（可带位移），为 nil 时保持原「五官零位移锚点」行为，纯脸型调用不受影响。
  - `Point2` 增加 `Hashable`（五官位移按点归集）。`DisplacementField.solve` 增加 `features:` 参数，恒等守卫改为「脸型与五官均为零才跳过」。
- **同日修正（脸型）**：M5 的「按 t 区段钟形函数叠加」收窄模型在实拍图上出现两侧波浪与腮部外鼓（用户确认），改为**单调 C1 宽度锥形**——所有收窄参数线性合成一个总量，乘一条从太阳穴到下巴单调递增的锥形函数，逐点按自身横向距离等比压缩；宽度剖面由构造保证单调，波浪与局部外鼓在数学上不可能出现。新增宽度剖面单调性回归测试。
- **效果**（`IMG_0789.HEIC`，五官 全大眼 0.7 / 眼距 0.3 / 眉间距 0.3 / 眉粗 0.4 / 鼻翼 0.5 / 嘴型 0.5）：最大位移 39.9px，最小雅可比 0.725（无折叠），强度 1.00；数值验证脸部 52.7% 像素变化、顶部背景 **0.00%**。
- **验证**：新增 `FaceFeatureAdjusterTests` 10 项（恒等退化为锚点、大眼径向放大且纵向强于横向、眼距整眼平移不畸变且瞳孔随动、眉间距平移、眉粗纵向张开、鼻翼收拢公式、嘴型上扬公式、位移上限、仅五官参数端到端求解、全零返回 nil）。BFAlgorithms 34 项、BFKitTests 38 项通过。
- **已知限制**：眉毛粗细受限于单条眉线（R-16）；眼角开大 / 下眼睑调整为 B 级，眼部轮廓点偏少，暂不实现。
- **后续修正（同日，用户实拍反馈驱动）**：
  - 系数放大（初版系数以眼睛/唇部自身尺寸为基准，拉满也不可感知）：大眼 0.18/0.30 → 0.30/0.60，眼距/眉间距 0.20 → 0.30，眉粗 0.30 → 0.45，鼻翼 0.18 → 0.32，嘴型 0.10/0.22 → 0.08/0.30（横向收拢从 0.16 回撤到 0.08：与脸型收窄叠加导致嘴部比例失调）。
  - **轮廓波浪两次根治**：① 脸型与五官从合入同一个 MLS 场**拆为两个独立场叠加**——场 A 轮廓位移 + 五官锚定，场 B 五官位移 + 轮廓锚定，边缘 = 纯锥形剖面，与五官强度无关；② 场 B 的轮廓锚从 17 个顶点**沿弧长加密到 ~129 个**（只锚顶点时，~200px 的段间无锚区会漏出以段为波长的残余波浪）。场 A 的轮廓控制点同步 3 倍加密。
  - **验证手段**：AutoBeauty 新增 `--dump-edge` 探针——沿轮廓折线加密采样（每段 4 点，含段中点），分侧输出收窄比例剖面并统计反向点。脸侧（t 0.93→0.05）严格单调、反向点 0；下巴尖端（lateral≈0）的比例噪声不计。
  - 回归测试：五官拉满时轮廓点位移 < 2px；双场叠加雅可比 > 0；轮廓加密点数 = 3×(n−1)+1。BFAlgorithms 37 项、BFKitTests 38 项通过。
- **产品决策**：自动五官参数保持保守定位（给「80 分底子」）；**手动液化工具**（选区 / 半径 / 拖拽拉伸压缩，笔刷位移直接写入位移场，笔画可撤销）列入计划，作为自动美型的手动微调出口，安排在 M9（App 与 UI）阶段实现。

### 3.9 M7 程序化美妆（已完成 2026-11-05）

- **范围**：口红 / 腮红 / 眉毛加深 / 眼影四路程序化美妆（ADR-007 / ADR-008）：`MakeupParameters`（BFAlgorithms，强度 + 可自定义颜色）、`MakeupMaskGenerator`（BFKit，形变后关键点生成蒙版）、`MakeupRenderer`（Metal 单 pass 合成）；`FaceGeometry` 补 `innerLips`；BeautyEngine 管线变为 颜色 → warp → 美妆 → 编码；AutoBeauty 新增 `--lipstick / --blush / --brow / --shadow`。
- **实现要点**：
  - 蒙版：外唇多边形减口内（口内不上色、不参与 MLS）；腮红为眼心—唇心连线颊部椭圆软边；眉毛沿眉形折线撒圆盘补厚度；眼影为上眼睑向上偏移带。蒙版长边 512 + 盒滤波羽化。
  - 口红**色度替换、亮度保持**：唇纹与明暗完整保留；实测唇色 (95,25,29) → (134,0,16)（红分量 +39，亮度基本不变——亮度 diff 工具看不见色度变化，属正常）。
  - 初版蒙版几何 bug：非方形图像下椭圆纵坐标用错缩放比（用 `maskW/imgMax`），腮红左右不对称——改为 mask 坐标按轴独立换算。
- **效果**（`IMG_0789.HEIC`，美妆四项 0.5~0.7）：背景逐像素不变；全流程组合（自然美颜 + 脸型 + 五官 + 美妆）2223 ms（Mac debug）；美妆蒙版随形变关键点对齐（R-06 缓解）。
- **验证**：新增 `MakeupTests` 5 项（蒙版位置、口内排除、形变跟随、口红保亮度着色、背景不变）。BFKitTests 44 项、BFAlgorithms 37 项通过。
- **已知限制**：腮红 / 眼影为几何椭圆近似，未做颧骨定位优化；写实度依赖参数调优（R-08 已缓解：亮度保持 + 低权重合成，无「糊一层彩」感）。

### 3.10 AutoBeauty 参数配置文件（2026-11-05）

- **动机**：自动参数只需保证「每功能有效果」，满意程度由用户实时调值——验证改为配置文件驱动，不依赖个人审美挑参。
- **实现**：`Configs/beauty_default.json`（全功能默认值集中，颜色 `#RRGGBB`）；`BeautyConfig`（CLI 层，BFAlgorithms 保持零 Apple 依赖）：Codable 全字段可省略、hex 校验（拼错报错）、`apply(to:)`。
- **CLI 行为**：启动自动加载默认配置 → 显式旗标覆盖配置 → `--config <路径>` 换配置 → `--dump-config <路径>` 反向导出（round 2 位小数防 Float 尾数）→ `--no-config` 跳过。
- **坑**：预扫 config 旗标后 `index` 忘复位，功能旗标循环全部跳过——已修并全流程回归。
- **验证**：默认加载 / 旗标覆盖 / 导出 / 非法颜色报错 / 单字段迷你配置，全通过。JSON schema 即将来 App 端预设 / 草稿的存储格式。

### 3.11 M9 阶段性：BeautyFaceDemo 接入 BeautyEngine（2026-11-05）
- **目标**：启动即有待处理照片；左侧竖直功能栏，选中后底部出现对应滑杆（带默认值）；可换图、可导出。
- **BFKit（ADR-016）**：`BeautyEngine` 新增 `BeautyAnalysis` / `analyze(decoded:quality:)` / `render(analysis:parameters:)`；`process(...)` 退化为兼容组合入口，AutoBeauty 无需改动。
- **App 代码**（`BeautyFaceDemo/BeautyFaceDemo/`，Xcode 16 文件同步组自动纳入 Target）：
  - `BeautyControls.swift`：`ParameterDefinition` 用 `WritableKeyPath<BeautyParameters, Float>` 统一顶层参数与嵌套的脸型 / 五官参数；5 个分类共 20 条滑杆；`BeautyDefaults` 作为默认值唯一来源，避免初值 / 预设 / 重置三处漂移；4 档预设。
  - `BeautyStudioModel.swift`：`@MainActor @Observable`；单条串行队列持有 Metal 引擎；换图分析一次、调参只渲染；50 ms 防抖 + generation token 丢弃过期回传；换图 / 调参 / 换预设时使旧导出 URL 失效；导出按 `.full` 重新分析后编码 PNG；Metal 不可用时仍显示原图。
  - `BeautyStudioView.swift`：纯 SwiftUI（不引入 AppKit / UIKit）；顶部工具栏、左侧功能栏、中央预览（原图 / 效果切换、人脸数、耗时、状态 / 错误）、底部参数面板（单项与整组重置）；`PhotosPicker` + `fileImporter` 换图。
  - `SamplePortrait.swift`：无真实照片时的程序化示意人像，保证干净检出也有画面。
- **工程**：pbxproj 补齐 `XCLocalSwiftPackageReference`（`../Packages/BFAlgorithms`、`../Packages/BFKit`）、`XCSwiftPackageProductDependency` 与 Target 的 `Frameworks` 阶段；`plutil -lint` 通过，对象引用完整。
- **默认照片（ADR-017）**：`scripts/install_default_portrait.sh` 从 `SampleImages/IMG_0789.HEIC` 生成 1600 长边 JPEG 到 `Resources/DefaultPortrait.jpg`（不入库）；缺失时回退示意人像。
- **验证**：本机为 Intel `x86_64` + CommandLineTools，无法直接 `xcodebuild`（`Float16` 只在 arm64 可用、无 XCTest、无完整 Xcode）。改用 `--triple arm64-apple-macosx15.0` 交叉编译：`Packages/BFKit`（含 BFAlgorithms）`Build complete!`；把 5 个 App 源文件放进临时 SwiftPM harness，按工程的 Swift 6.2 参数（`-swift-version 5 -default-isolation MainActor` + 两个 upcoming feature）类型检查通过。**未验证**：Xcode 图形界面打开工程、真机运行、实际渲染效果与性能。
- **待办**：iPhone 真机验证（约定后置）；M9 完整交互回归（手动液化、App 端 JSON 预设持久化、PhotosPicker 非 Debug 路径）；M8.1 小头联动（Q-05）；M10 验收未开始。M8 已完成（Mac），本轮 App 侧用 SwiftPM harness 全量类型检查通过；`xcodebuild` 在本机受嵌套沙箱限制无法解析本地包，已如实记录（见 3.12 实现记录）。

### 3.12 M8 颈肩协调（详细设计，2026-11-05）

**目标与范围**：按 ADR-009「脸部位移沿颈部向下衰减，到肩线为 0；位移限制在人像蒙版内」，消除 M5 形变后脸与颈之间可能出现的硬边（R-07）。完成标准仍是「脸与颈过渡无明显断裂」。

- **本里程碑只做 A 级**：沿颈纵向衰减 + 人像蒙版内约束。ADR-009 中「小头（B 级）以颈根为中心衰减缩放」按 B 级排期，拆为 **M8.1**（登记 Q-05），不纳入 M8；**不修改 ADR-009 的内容**（§0 约定 ADR 一经接受不修改，只做范围说明）。
- 理由：A 级只需改位移场的权重表，不动 MLS 控制点、不动渲染 pass；小头需要在 `FaceShapeAdjuster.controls` 无条件追加的整图边框锚点之外另建第三套「以颈根为中心、肩线归零」的 MLS 场，是独立的一块形变（约 2–3 天）。把两者绑在一起会让已可验证的 A 级验收与未验证的 B 级形变互相牵制，R-07 无法干净关闭，也没有余量做效果调参。
- **不做**：人体姿态检测（B 级预留）、瘦腰 / 瘦腿（C 级）、新渲染 pass / kernel / 纹理、新增用户可调参数、iPhone 真机验证（`AGENTS.md` 约定推迟到核心功能完成后）。

**效果优先原则**：分割蒙版约束是手段不是目标。下列权重公式是起点而非教条；若实测过渡不自然、颈肩出现硬边、发丝或衣领被拖动，允许调整走廊宽度、衰减曲线与 `maskGate` 阈值。数值判据全绿不等于验收通过，最终以 `SampleImages/IMG_0291.jpg`（完整肩线、灰蓝衬衫 + 白 T 恤、暖色复杂背景）与 `IMG_0789.HEIC`（M5 基线：白 T 恤 + 纯灰墙，肩被裁在画面底边，走兜底路径）的前后目视对比为准，由用户拍板。预留 2–3 轮调参；若蒙版方案整体反而更差，回退到 `bodyCoordination = false` 的 M5 基线并重新设计，失败尝试照 §3.5 惯例如实记录。

#### 现状与约束

- `DisplacementField.falloffTable` 是**各向同性径向**衰减：`smoothstep(0.45R, 0.15R, 到该脸最近关键点的距离)`，多脸取 max。它是 M5「背景严格不动」的关键（§3.7 记录过衰减因子 `init` 默认值漏改导致背景 40~50% 像素差异的踩坑）。
- **不能直接调大 `falloffOuterFactor`**：位移会向左右与上方同时扩散，踩坑复发，并打断 `DisplacementFieldTests` 的横向 / 斜向远场探针。
- 结论：颈部延伸必须是**有向的、只在下巴以下的窄走廊**，而不是把径向圈扩大。`falloffInnerFactor / falloffOuterFactor` 保持 0.15 / 0.45 不动。
- 约束：ADR-005（BFAlgorithms 零 Apple 依赖，连 Foundation 也不能 `import`）、ADR-006（脸部与颈肩位移合并后只做一次 warp）、ADR-007（颜色 → 几何 → 美妆）、ADR-012（多脸逐张独立）、ADR-016（analyze / render 拆分）。

#### 衰减权重

坐标统一为 `FaceGeometry` 的像素坐标、**y 向上**。每脸由 76 点推得 `minY`（下巴）、`height`（脸高）、`faceWidth`、`axisX`（瞳孔中轴）、`R`（`allPoints` 质心到最远点距离）；由蒙版推得 `neckRootY` / `shoulderY` / `xNeck`。

```
neckRootY  = minY − 0.08 × height
upperCut   = smoothstep(neckRootY + 0.10 × height, neckRootY, y)  // 防头顶竖直位移带
vTaper     = smoothstep(shoulderY, neckRootY, y) × upperCut        // 肩线 0 → 颈根 1
lTaper     = smoothstep(0.50 × faceWidth, 0.25 × faceWidth, |x − xNeck|)
neck_f     = vTaper × lTaper                                        // 下巴以下的窄走廊
radial_f   = 现有 falloffTable（原样保留）

radial     = max_f(radial_f)                                        // 多脸取并集
neck       = max_f(neck_f)
spatial    = max(radial, neck)                                      // 脸部内 radial ≈ 1，位移不被改动
maskGate   = m < 0.02 ? 0 : smoothstep(0.5, 0.9, m)                 // m 为人像蒙版采样值
W          = spatial × maskGate                                     // 乘积，不是 min
```

- 空间取 `max`：两区并集，脸部内保持 M5 行为，交界处 C0 连续；蒙版取乘积：`m = 0` 处严格 0，且比 `min` 少一个硬拐角。
- 边界羽化三层：`smoothstep` 本身、`maskGate` 软阈值、128 节点粗网格 + `WarpRenderer` 双线性放大（2316×3088 图上约 24px 过渡带）。网格节点上 `W = 0` 可精确断言；相邻像素仍可能有极小双线性残差，因此像素级判据沿用 M5 的「≤ 1 灰阶」。必要时在网格分辨率上对 `maskGate` 做一圈腐蚀。
- `sampleOffsets` 仅把 `falloff[index]` 换成 `W[index]`；权重表在 `solve` 里算一次，折叠回退循环不重算。**不新增 MLS 场、控制点、pass、kernel 或纹理**，符合 ADR-006 / ADR-007，无性能与显存增量；美妆仍用同一总场变换关键点。
- `Config` 新增 9 个字段（走廊内外半宽、颈根下沉、肩线兜底比例、宽度突变倍率、`upperCut`、`maskGateLow/High`、`maskEpsilon`）。**注意 `Config` 是手写显式 `init`**，属性默认值与 `init` 默认参数必须同步（§3.7 踩坑），并加一致性单测。

#### 跨层数据契约

BFKit 的 `SegmentationMask`（`import CoreGraphics`，UInt8 行优先）不能进 BFAlgorithms。新增纯 Swift 类型，零 `import`：

```swift
public struct PersonMaskGrid: Sendable {
    public let width: Int, height: Int, values: [Float]   // 0...1，行优先
    public func sample(u: Float, v: Float) -> Float       // 归一化双线性
}
public enum BodyCoordination {
    public static func weightTable(
        faces: [FaceGeometry], imageSize: (width: Int, height: Int),
        columns: Int, rows: Int, config: DisplacementField.Config,
        mask: PersonMaskGrid?
    ) -> [Float]
}
```

- `DisplacementField.solve` 末尾追加 `personMask: PersonMaskGrid? = nil`；**nil 时逐元素返回原 `falloffTable` 结果**，保证 37 + 44 项既有测试与合成图断言逐位不变，同时也是「分割失败 / `--no-mask`」的降级路径（R-04 不强行处理）。所有既有调用方都是带标签参数，末尾追加默认参数完全兼容。
- 三套分辨率（Vision 蒙版自身 W×H、皮肤蒙版 512/256、位移网格 128、图像像素 ≤4096）用**归一化 `(u, v)` 采样**对齐，不降采样到 128，避免三处取整错位。
- **v 方向需实测锁定**：`SkinMaskGenerator.samplePersonMask` 现有实现把光栅行比例 `v` 直接喂给蒙版像素（无翻转），而 `FaceGeometryConverter` 明确 Vision 关键点与 `FaceGeometry` 同为 y 向上。两套行序的关系用一个上 / 下不对称的合成蒙版单测 + `_body.png` 真实图目视复核；若相反，只在 `PersonMaskConverter` 一处 `1 − v` 修正并写测试锁死。这是本设计中最需要实测确认的细节。
- `BeautyEngine.render` 构造并传入蒙版；新增 `bodyCoordination: Bool = true` 开关（`process` / `render` 各入口带默认值向下转发），作为一键回退。

#### 肩线定位（不引入人体姿态）

主方案：从 `neckRootY` 向下逐行扫 `PersonMaskGrid`，在包含 `xNeck` 的连通段上取人像宽度 `w(y)`；颈段窄、肩线处突然展宽，取连续 ≥3 行满足 `w(y) > 1.8 × wNeckMedian` 的第一行为肩线，再用一阶差分最大处微调。`xNeck` 取蒙版颈段的水平质心（对侧身 / 偏转鲁棒），退化时回退瞳孔中轴。
兜底链：硬界 `[neckRootY − 2.2 × height, neckRootY − 0.5 × height]` → 越界或找不到突变时用固定比例 `neckRootY − 0.90 × height` → 蒙版下沿与图像 `y = 0` 保护 → 检测 / 蒙版缺失走 nil 兼容路径。`IMG_0291` 验主方案（肩线完整、宽度突变明显），`IMG_0789` 验兜底（肩被裁掉）。
升级到 `VNDetectHumanBodyPoseRequest` 的触发条件：真实合影 / 侧身素材上肩线估计反复失败、M8.1 需要可靠颈根锚、或用户要求显式肩点。ADR-002 允许使用 Vision 姿态，但 A 级不需要；README 架构图中的「人体姿态」标注为 B 级预留。

#### 管线接入

`BeautyEngine.render` 在 `DisplacementField.solve` 之前把 `analysis.detection.personMask` 转成 `PersonMaskGrid` 并传入。`WarpRenderer` 及其 Metal kernel、`FaceGeometryConverter`、`MLSSolver`、三个 Adjuster、`MakeupMaskGenerator`、App 参数模型、`Configs/beauty_default.json` 均不改动。M8 不新增用户可调参数。
AutoBeauty 新增 `--no-body`（A/B 开关）、`--dump-neck`（颈中线剖面 + 颈根 / 肩线 / 走廊半宽 + 蒙版外与肩线下最大位移，须为 0）、`--shoulder-line`（调参覆盖）、`_body.png`（权重热图）。

#### 验收判据

数值：肩线以下网格节点位移恰 0（像素 |d| < 0.5px）；人像蒙版外节点恰 0，背景与白 T 恤像素差 ≤ 1 灰阶；颈部中线位移单调衰减且相邻差分 ≤ 0.15 × max；脸部位移与 `--no-body` 基线逐像素一致；走廊两侧 `xNeck ± 2 × faceWidth` 处 `W = 0`（防径向扩圈复发）；`minimumJacobian() > 0` 且 `appliedStrength == 1`；多脸各颈段独立、脸间为 0；`--dump-edge` 反向点 0。
目视：`IMG_0291` 下巴→颈→肩过渡连续无横向硬边，肩线以下躯干 / 手臂 / 桌面不动，灰蓝衬衫与白 T 恤纹理不被拖拽；`_body.png` 权重带呈「上宽下窄、肩线处收 0」而非左右扩散；`IMG_0789` 白 T 恤领口缝线与灰墙不变。**两张都过且用户目视确认「效果好」才关闭 R-07。**
回归：BFAlgorithms 37 项、BFKit 44 项全绿，尤其 `DisplacementFieldTests` 远场≈0 / 雅可比>0 / 多脸独立、`WarpRendererTests` 背景不动、`MakeupTests` 形变对齐；`scripts/check_no_apple_imports.sh` 通过。

#### 回归与风险

最高风险是**衰减带放宽导致背景位移复发**（§3.7 原坑）。缓解：有向走廊、0.15/0.45 不动、`maskGate` 乘积硬置 0、`upperCut`、Config 一致性单测、侧向守卫测试；一键回退 `bodyCoordination = false` / `personMask = nil` 立即回到 M5 位精确行为。其余：maskGate 梯度可能触发雅可比回退（放宽阈值带）、肩线估错（硬界 + 固定比例兜底 + `--shoulder-line`）、蒙版 v 方向反了（不对称合成蒙版测试）、`IMG_0291` 背景虚化人影可能干扰检测 / 分割（先记录，干扰则记为已知限制交 M10 合影验证，不扩大 M8 范围）。

#### 任务分解

0. 补本节设计与 README §3.10、修文档漂移 → 1. BFAlgorithms 三个 Body 类型 + `DisplacementField` 改造 + 单测 → 2. BFKit `PersonMaskConverter` + `BeautyEngine` + 调试绘制 + 单测 → 3. AutoBeauty 旗标与 `_body.png` → 4. 双素材效果迭代与调参（2–3 轮）→ 5. App 补齐美妆分类、颜色、预设与分割对比（用户追加）→ 6. App 构建验证 → 7. 文档收口与提交。

#### M8.1 小头联动解法备忘（本里程碑不实现）

新建**场 C**：头部 76 点绕 `neckRoot` 缩放（`output = neckRoot + s·(p − neckRoot)`，`s = 1 − 0.1 × param`），不追加整图边框锚点，改为沿肩线与颈走廊两侧撒零位移锚，使缩放在肩线自然归零；场 C 的权重不用径向 `falloff`（会连头内缩放一起砍掉），改用 `neckTaper × maskGate`。三场叠加后统一做雅可比检查与 0.7 回退，美妆关键点仍用同一总场。这正是 ADR-009「以颈根为中心衰减缩放」的落地方式，因此 `neckRoot` 在 M8 就要定义好并暴露。根因见 §3.7 已知限制：`FaceShapeAdjuster.controls` 无条件追加整图边框锚点，MLS 远场退化为全局刚体，整体缩放 / 平移类参数会被这些锚点抵抗。

#### 实现记录（2026-11-06，M8 完成）

**发现并修复一个既有垂直镜像 bug（本轮最大意外）。** 在真实半身像 `IMG_0291` 上做端到端放大差异图时，发现脸型形变落在**胸口 / 衬衫领子**而非脸上：差异质心 0.680（胸），脸实际在 0.13–0.40。根因是 `DisplacementField` 的网格 row 0 对应 y 向上 y=0（图像下沿），而 `WarpRenderer.makeDisplacementTexture` 直接把场按行原样灌进 Metal 纹理，Metal 纹理 row 0 / 归一化 v=0 却是图像上沿。源图纹理走的 `CGContext.draw` 内部自带一次翻转，位移纹理没有，两者相差一次镜像。旧单测用上下近似对称的居中合成脸，因此一直没暴露。

修复只在 `makeDisplacementTexture` 一处：上传时按行倒序、并把 `dy` 由 y 向上取反为光栅向下；**不动 kernel、不新增 pass / 纹理**。修复后差异质心 0.680 → 0.305，目视确认形变精准落在眼镜、脸颊、下颌。`WarpRendererTests` 里原本按镜像结果校准的采样窗口（raster 180–300）同步修正为 245–430，并新增 `testDisplacementFieldMapsYUpToRasterRows` 锁死方向。此修复同时保证 M8 颈部走廊不会跑到头顶上方。

**蒙版方向（§3.12 最高风险细节）已实测锁定。** `SegmentationMask` row 0 = 图像上沿、`PersonMaskGrid.sample(u:v:)` 的 v 为 y 向上并在内部换算；`PersonMaskConverter` 因此不做翻转。用真实 Vision 检测结果确认：人像上半均值 0.39、下半 0.96（符合半身像），头顶位置与 Vision bbox 吻合。BFKit 新增 `testPersonMaskGridYUpSampling` / `testPersonMaskOrientation`（上/下不对称合成蒙版）锁死方向。

**效果优先的三轮调参（含失败尝试，按 §1.1 如实记录）：**

1. 首轮 `W = spatial × maskGate` 在 `IMG_0789`（头部特写）触发两次折叠回退：强度 1.00 → 0.49，最大位移 38.8 → 19.0 px，整脸形变被砍半。
2. **失败尝试 A**：把 `maskGate` 软阈值从 (0.5, 0.9) 放宽到 (0.08, 0.85) 无效。加蒙版值分布诊断后发现 Vision 分割是**硬二值**（32.5% 为 0、66.8% 为 1，中间值仅约 1%），`smoothstep` 根本没机会生效。
3. **失败尝试 B**：对蒙版做 3×3 邻域羽化采样，把硬阶跃摊成软过渡，仍无效（强度仍 0.49）。
4. **最终改公式**：定位到真正原因是 `IMG_0789` 的脸几乎占满画面、分割蒙版在脸缘内缩，乘积式门控把**脸部原有的 radial 权重也一起砍掉**了，违反「脸部位移与 M5 基线逐像素一致」。改为 **`W = max(radial, neck × gate)`**——门控只约束新增的颈部走廊，不碰原有径向衰减。改动后强度恢复 1.00 / 位移 38.8px，且蒙版外新增权重严格 0、肩线以下位移严格 0。羽化采样保留（降低走廊边界阶跃）。数值探针同步改为检查「M8 相对 M5 的**权重增量**」而非绝对位移，否则会把 M5 本来就有的脸缘形变误判为越界。

**最终数值验收（双素材，全参数拉满）**：`IMG_0291` 走蒙版宽度突变主方案（肩线 396.2）、`IMG_0789` 走固定比例兜底（肩线 0.0），两条路径都覆盖；M8 最大新增权重 0.939 / 0.867（颈部确有形变）；蒙版外新增 0.000000；肩线以下最大位移 0.0000 px；最小雅可比 0.562 / 0.368 > 0，强度均 1.00；脸部与 M5 基线逐像素一致；肩线以下（top 60%+ / 95%+）A/B 差异为 0。目视：分割线两侧脸型一致，差异只落在下巴→颈→领口一条连续弧线，灰墙与白 T 恤绝大部分全黑、无硬边。

**调试能力**：AutoBeauty 新增 `--no-body`（M5 基线 A/B）、`--dump-neck`（33 点中线剖面 + 权重/位移探针 + 蒙版值分布）、`--shoulder-line <倍数>`（经 `Config.shoulderLineFactorOverride` 真正作用到求解器）、`--dump-body` → `_body.png` 权重热图；`_debug.png` 叠加下巴 / 颈根 / 肩线 / 走廊边界。固定脚本 `scripts/render_m8.sh` 一次产出开 / 关两组图。

**App UI 补齐（用户追加）**：`BeautyCategory` 第 6 类 `.makeup`，4 条强度滑杆 + 4 组色号（独立 `MakeupColorDefinition` 类型，不碰既有 `WritableKeyPath<…, Float>` 机制）；预设补美妆、单项 / 整组重置对颜色生效；预览区新增可拖拽分割线 before/after（保留原图 Toggle）。颜色变更走同一套 50ms 防抖 + generation token，不重跑 `analyze`。

**构建验证**：本机 Xcode 26.2 / arm64 上 `xcodebuild` 解析本地包稳定触发嵌套沙箱 `sandbox_apply: Operation not permitted`（SwiftPM manifest 层，与客户端执行权限无关），真实 App 构建未能完成，如实记录。改用 SwiftPM harness 把 App 全部 6 个源文件作为 target 全量编译通过（含 SwiftUI / `@Observable` / PhotosUI）。`scripts/verify.sh` 固定入口统一跑 ADR-005 守护 + BFAlgorithms 50 项 + BFKit 51 项 + AutoBeauty 构建 + App 源码类型检查，结果全 0。

**范围说明**：本轮按批准的「效果优先」原则调整了权重公式（§3.12 原式 `W = spatial × maskGate` → `max(radial, neck × gate)`），并额外修复了 `WarpRenderer` 的既有镜像 bug；`WarpRenderer` 的 Metal kernel、三个 Adjuster、`BeautyParameters`、`Configs/beauty_default.json` 结构均未改动。iPhone 真机、M9 完整交互回归、M8.1、M10 仍按约定后置。

---

## 4. 风险登记

| 编号 | 风险 | 可能性 | 影响 | 应对 | 状态 |
|---|---|---|---|---|---|
| R-01 | 76 点关键点在眼、鼻处偏粗 | 高 | 中 | 限制幅度；B 级再评估 | 开放 |
| R-02 | MLS 大幅度形变折叠 | 中 | 高 | 位移上限 10% 脸高 + 线性压缩；粗网格雅可比检查，折叠时按 0.7 整体回退强度重解（3.7）。实测全参数拉满最小雅可比 0.042 > 0，未触发回退 | 已缓解 |
| R-03 | 4800 万像素原图内存压力 | 中 | 高 | 4096 上限（ADR-004）；M10 测峰值 | 开放 |
| R-04 | Vision 在侧脸、遮挡下失败 | 高 | 中 | 检测失败时提示，不强行处理 | 开放 |
| R-05 | 颜色空间与 Display P3 偏色 | 中 | 中 | 统一工作色彩空间，保留 ICC | 开放 |
| R-06 | 形变与美妆错位 | 中 | 中 | 美妆蒙版用 warp 之后的形变关键点生成（ADR-007 / 3.9），实测随形变对齐 | 已缓解 |
| R-07 | 颈肩过渡显得突兀 | 中 | 低 | 沿颈纵向衰减到肩线为 0 + 人像蒙版内约束（3.12）；效果以双素材目视为准 | **已缓解（M8 完成，待用户目视最终拍板）** |
| R-08 | 程序化美妆写实度不足 | 高 | 低 | 口红色度替换保亮度（唇纹 / 明暗保留），腮红 / 眼影低权重合成（3.9）；颜色可自定义持续调优 | 已缓解 |
| R-09 | iOS 18 兼容性无真机验证 | 中 | 中 | 记录在验收中；必要时补一台 iOS 18 设备 | 开放 |
| R-10 | 免费 Apple ID 签名 7 天失效 | 高 | 低 | 必要时付费开发者账号 | 开放 |
| R-11 | 磨皮在强参数下纹理损失（已修正） | 中 | 低 | M3 的高斯模糊已在 3.6 换成亮度引导的保边滤波：强边缘保留，纹理压平 | 已修正 |
| R-12 | 76 点眼轮廓过粗导致眼白蒙版边界不准 | 高 | 低 | 用相对亮度判据降低依赖；接受为已知限制 | 开放 |
| R-13 | 去痘印误伤鼻翼沟、眼睑褶等小而暗的结构 | 中 | 低 | 增益上限 1.45、默认强度 0.30；必要时加梯度抑制 | 开放 |
| R-14 | 浅色衣物被误判为皮肤（已修正） | 高 | 中 | 改为人脸肤色参考 + 亮度归一化色度距离（3.5）；混合肤色合影仍共用单参考 | 已缓解 |
| R-15 | 高光 / 面部绒毛落在皮肤蒙版外，强磨皮下凸显为亮丝 | 中 | 低 | 保边滤波（3.6）已大幅降低对比：周围皮肤不再被压成一片平，亮丝不再跳出来；根治仍需蒙版空洞填充 + 二次膨胀 | 已缓解 |
| R-16 | Vision 眉毛只有单条折线、无厚度轮廓，「眉毛粗细」只能靠 MLS 纵向拉伸近似 | 高 | 低 | 已按纵向拉伸实现（3.8）；若效果不足，考虑用暗色区域检测估计眉带厚度再定控制点 | 开放 |

---

## 5. 待决问题

| 编号 | 问题 | 状态 |
|---|---|---|
| Q-01 | 是否需要 iOS 18 真机验证设备？ | 已决定：已有 iOS 18 设备 |
| Q-02 | SampleImages 是否入库？ | 已决定：不入库，由 .gitignore 排除 |
| Q-03 | 是否需要 Apple Developer Program 付费账号用于分发？ | 待定 |
| Q-04 | 导出时是否提供「原图尺寸」选项（需分块处理）？ | 推迟到 v1 之后 |
| Q-05 | M8.1 小头联动（B 级）何时排期？ | 已从 M8 拆出；解法见 3.12「M8.1 小头联动解法备忘」，待 M8 验收后决定 |

---

## 6. 测试设备矩阵

| 设备 | 系统 | 芯片 | 素材 | 状态 |
|---|---|---|---|---|
| macOS（Apple Silicon / arm64） | macOS 15+ | M 系列 | `SampleImages/`（musk.jpeg、IMG_0789.HEIC） | 开发调试（AutoBeauty） |
| iPhone 17 | iOS 26 | A19 | 前置自拍、后置 4800 万像素 HEIC、多人合影 | 推迟（核心功能完成后） |
| iPhone Air | iOS 26 | A19 Pro | 前置自拍、后置 4800 万像素 HEIC、多人合影 | 推迟（核心功能完成后） |
| iOS 18 设备 | iOS 18 | — | — | 待定（Q-01） |

素材拍摄要求：前置自拍覆盖正面、微侧、戴眼镜、弱光、逆光；每类至少若干张。

PhotosPicker 系统相册路径只在非 Debug 模式下验证。

---

## 7. 变更日志

| 日期 | 变更 |
|---|---|
| 2026-10-26 | 完成需求与技术规划；确认 ADR-001 至 ADR-012；创建 README 与台账；M0 准备开始 |
| 2026-10-26 | M0 进行中：生成工程骨架（BFAlgorithms、BFKit、Demo 源码、.gitignore、SampleImages 目录、平台依赖检查脚本）；Q-01、Q-02 决定 |
| 2026-11-02 | 新增 ADR-013（Mac 优先开发、iPhone 最终验收）；ContentView 去除 UIKit 依赖，改用 CGImage，支持 macOS |
| 2026-11-02 | M0 完成 Mac 构建验收：修复同名 Placeholder 文件、Debug 改本机签名、部署目标修正为 iOS 18 / macOS 15；两个 Package `swift test` 与 App `xcodebuild` 均通过 |
| 2026-11-02 | 调试流程改为直接读取 `SampleImages/`（Debug 自动载入示例图、关闭 App Sandbox），便于自动化验证；新增工程约定 `AGENTS.md` |
| 2026-11-03 | 平台定位更新为 macOS（arm64）+ iOS，新增 ADR-014；功能清单补充美白/淡化肤色、增亮/提亮、去黑点/痘印（A） |
| 2026-11-03 | 新增 ADR-015 与 `Tools/AutoBeauty` CLI（SampleImages 批处理 → processed/）；主 App 恢复始终使用 PhotosPicker，Debug 重新开启沙盒 |
| 2026-11-03 | iPhone 真机验证推迟到核心功能基本完成后；PhotosPicker 只在非 Debug 验证；`processed/` 加入 .gitignore |
| 2026-11-03 | M1 完成：ImageDecoder / ImageEncoder / rgba16Float TextureConverter / ImagePipeline；BFKitTests 6 项通过，恒等误差 ≤ 1 灰阶；AutoBeauty 接入 BFKit |
| 2026-11-03 | M2 完成：FaceDetector（脸框 / 76 点 / 人像蒙版 / 多脸）与 DetectionDebugRenderer；AutoBeauty 输出 `_debug.png`；BFKitTests 10 项通过 |
| 2026-11-03 | M3 完成：BeautyParameters、皮肤蒙版（肤色 + 人像 + 眼唇排除）、MPS + Metal 磨皮 / 美白 / 提亮、BeautyEngine 预览 / 全分辨率；AutoBeauty 参数与 `_skin.png`；BFKitTests 22 项通过 |
| 2026-11-03 | M4 完成：抽取蒙版工具（MaskImageRasterizer / PolygonRasterizer / MaskFilters / MaskMath）、RetouchMask + Generator（眼白 / 牙齿 / 眼下）、SkinRenderer 接入局部修饰与去痘印、BeautyEngine 与 AutoBeauty 接入（`_retouch.png`、四个新参数）；BFKitTests 33 项通过 |
| 2026-11-03 | 真实照片 `IMG_0789.HEIC` 验证 M4：眼白蒙版准确、背景零变化；发现白 T 恤被误判为皮肤。皮肤蒙版改为「人脸肤色参考 + 亮度归一化色度距离」（3.5），衣物亮度变化 +9.74 → +0.11；新增衣物回归测试，BFKitTests 34 项通过；记录 R-15（高光 / 绒毛在强磨皮下凸显） |
| 2026-11-03 | 磨皮从高斯模糊改为亮度引导的保边滤波（3.6）：新增 `guidedStats` / `guidedCoefficients` 两个 kernel，系数在 1/4 分辨率上用 `MPSImageBox` 求得后回代；强度拉满时皱纹抹平而眉毛、发丝、唇线保留。R-11 关闭、R-15 降级为已缓解；新增保边回归测试，BFKitTests 35 项通过 |
| 2026-11-04 | M5 完成：MLS 刚体求解器（纯 Swift）、7 项脸型参数与位移上限、粗网格位移场（距离衰减 + 雅可比折叠回退，R-02 缓解）、WarpRenderer 单次 warp，接入 BeautyEngine 与 AutoBeauty（`_warp.png`）；修复衰减因子 init 默认值漏改导致的背景位移；BFKitTests 38 项、BFAlgorithms 23 项通过 |
| 2026-11-04 | TextureConverter 上传 / 回读改为 GPU 转换（`u8To16F` / `f16ToU8` 微型 kernel + `rgba8Unorm` 整块搬运），消除两处 29M 次 CPU 逐字节循环：完整管线 6393 → 1081 ms，自然档 + 脸型 1493 ms（Mac debug 构建） |
| 2026-11-04 | 脸型收窄改为单调 C1 宽度锥形（3.8）：修复实拍图上两侧波浪与腮部外鼓（用户确认），新增宽度剖面单调性回归测试 |
| 2026-11-04 | M6 完成：6 项五官参数（大眼 / 眼距 / 眉间距 / 眉粗 / 鼻翼 / 嘴型）与 `FaceFeatureAdjuster`，脸型 + 五官合入同一次 MLS 求解与单次 warp；AutoBeauty 新增 6 个 `--eye-size` 等参数；BFAlgorithms 34 项、BFKitTests 38 项通过 |
| 2026-11-05 | M6 收尾：脸型/五官**拆为两个独立 MLS 场叠加**（场 B 轮廓沿弧长加密锚定为零），根治五官位移拽动脸缘的波浪；场 A 轮廓控制点 3 倍加密；五官系数按实拍反馈定稿；AutoBeauty 新增 `--dump-edge` 边缘剖面探针（脸侧反向点 0）；BFAlgorithms 37 项、BFKitTests 38 项通过。决策：自动参数保持保守，手动液化工具列入 M9 |
| 2026-11-05 | 新增 ADR-016 / ADR-017；M9 阶段性完成：BeautyEngine 拆分 analyze / render，BeautyFaceDemo 接入真实管线并实现工具栏、左侧功能栏、底部滑杆面板、预设 / 对比 / 导出；启动自动载入本地默认示例照片（真实人像不入库）；pbxproj 链接 BFKit / BFAlgorithms；arm64 交叉编译与 UI 类型检查通过，真机验证待补 |
| 2026-11-05 | M7 完成：口红 / 腮红 / 眉毛 / 眼影程序化美妆——形变后关键点生成四路蒙版，Metal 色度替换合成（口内排除），`FaceGeometry.innerLips`，AutoBeauty 新增 4 个美妆参数；BFKitTests 44 项、BFAlgorithms 37 项通过 |
| 2026-11-05 | AutoBeauty 参数配置文件：默认值集中 `Configs/beauty_default.json`，`--config / --no-config / --dump-config`；调整单字段重新渲染即可逐项验证效果（3.10） |
| 2026-11-05 | 补 M8 颈肩协调详细设计（3.12）与 README 3.10：按 ADR-009 切分范围（小头拆 M8.1，登记 Q-05）、有向颈部走廊 + 人像蒙版约束的衰减权重、跨层数据契约与肩线定位；确立「效果优先」原则；修正 README 头部状态行、`DisplacementField` 衰减注释与架构图人体姿态的文档漂移 |
| 2026-11-06 | **M8 完成（Mac）**：BFAlgorithms 三个 Body 类型 + `DisplacementField` 可选 `personMask`、BFKit `PersonMaskConverter` / `BeautyEngine` 四入口开关与调参透传、AutoBeauty M8 调试旗标与 `_body.png`；双素材三轮调参后公式为 `W = max(radial, neck × gate)`（含两次失败尝试记录），数值与目视验收通过，R-07 已缓解 |
| 2026-11-06 | 修复既有 `WarpRenderer` 位移场垂直镜像 bug（真实半身像上形变落到胸口）：上传时行倒序 + `dy` 取反，差异质心 0.680 → 0.305；新增方向回归测试并修正被旧镜像结果带偏的采样窗口 |
| 2026-11-06 | App UI 补齐美妆分类（4 强度 + 4 色号、预设与重置）与可拖拽分割对比；App 源码经 SwiftPM harness 全量编译通过（Xcode 本机受嵌套沙箱限制无法解析本地包，如实记录）；`scripts/verify.sh` 固定验证入口：BFAlgorithms 50 项 / BFKit 51 项 / AutoBeauty / App 类型检查全绿 |
| 2026-11-06 | 工程约定：`AGENTS.md` 增加本地构建/验证命令常驻授权与良性沙箱提示说明；新增 `scripts/render_m8.sh` 固定 A/B 渲染入口；用户偏好改为中文汇报 |
