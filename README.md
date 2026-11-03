# BeautyFace

面向 **macOS（Apple Silicon / arm64）与 iOS** 的人像（面部为主）照片美化 App，同时提供 Swift Package 形式的 SDK。第一版专注于**静态图片**，以头部与面部处理为主，支持多人脸。身体部分只做颈部与肩部的协调，保证脸与躯体过渡自然。

- 状态：M3 完成（皮肤蒙版、磨皮、美白/提亮、预览与全分辨率），准备进入 M4
- 最后更新：2026-11-03
- 开发台账（ADR、里程碑、计划）：见 [dev_ledger.md](dev_ledger.md)

---

## 一、目标与范围

### 1.1 第一版（v1）做什么

- 平台：macOS 15+（Apple Silicon / arm64）、iOS 18+
- 输入：静态图片（相册、拍照、文件），HEIC / JPEG / PNG
- 处理：皮肤美化、五官与脸型形变、程序化美妆、颈肩协调
- 多人脸：逐张检测，各自独立参数
- 输出：处理后的图片，长边 ≤ 4096 像素，保留 EXIF 与颜色配置
- 交付：Swift Package 形式的 SDK、SwiftUI App（macOS / iOS），以及开发调试命令行工具 AutoBeauty
- 调试：核心功能开发阶段由 AutoBeauty 直接读取 `SampleImages/` 批处理，无需相册交互与人工点击

### 1.2 第一版明确不做

- 视频处理与实时相机预览
- 精细的身体塑形（瘦身、瘦腰、瘦腿、长腿、增高等）
- 全分辨率输出（4800 万像素原图按 4096 长边处理与输出）
- 基于美术素材的美妆（美妆全部程序化生成）
- Android 版本（算法层保持可移植，Android 在后续版本）
- 商用发布（暂不考虑，但依赖选型尽量避开许可风险）

### 1.3 运行与兼容

- 部署目标：iOS 18、macOS 15（Apple Silicon / arm64）
- 支持平台：macOS（arm64）、iOS
- 验收机型：iPhone 17（A19）、iPhone Air（A19 Pro），均运行 iOS 26；真机验证推迟到核心功能基本完成后
- 系统相册（PhotosPicker）路径只在非 Debug 模式下验证
- Debug 处理结果由 AutoBeauty 写入仓库 `processed/`；Release / iOS 由用户选择保存或导出
- 所有处理在设备端完成，不联网

---

## 二、功能清单

分级含义：**A** 第一版必须完成；**B** A 完成后补充，效果可能偏粗；**C** 本版不做。

### 人脸检测

| 功能 | 级别 | 说明 |
|---|---|---|
| 人脸框与关键点 | A | Vision 检测，76 点关键点 |
| 人像蒙版 | A | 用于皮肤处理与背景保护 |
| 多人脸 | A | 逐张检测，各自独立参数 |

### 基础美颜

| 功能 | 级别 | 说明 |
|---|---|---|
| 美白 / 淡化肤色 | A | 皮肤蒙版内提亮、降低偏色与肤色不均 |
| 磨皮 | A | 皮肤蒙版内高低频混合，保留部分纹理；后续升级引导滤波 |
| 增亮 / 提亮 | A | 面部整体亮度与对比度调整，保留高光 |
| 亮眼 | A | 巩膜区域提亮，不影响虹膜 |
| 白牙 | A | 口内低饱和高亮区域校正 |
| 去黑眼圈 | A | 眼下区域提亮并校正偏色 |
| 去黑点 / 痘印 | A | 皮肤蒙版内小面积瑕疵检测与修复 |

### 美型（脸型）

| 功能 | 级别 | 说明 |
|---|---|---|
| 小脸、瘦脸、窄脸、V 脸 | A | 基于轮廓点的 MLS 形变 |
| 下巴、额头、颧骨 | A | 局部轮廓形变 |
| 小头 | B | 整头缩放，需颈部协调配合 |

### 美型（五官）

| 功能 | 级别 | 说明 |
|---|---|---|
| 大眼、眼距、眉间距、眉毛粗细 | A | 基于眼、眉点 |
| 鼻翼、嘴型 | A | 基于鼻、唇点 |
| 眼角、下眼睑 | B | 眼部轮廓点偏少，效果可能偏粗 |
| 瘦鼻、长鼻、山根 | B | 鼻部点数较少 |

### 美妆（程序化生成）

| 功能 | 级别 | 说明 |
|---|---|---|
| 口红 | A | 唇部蒙版 + 颜色混合，保留高光 |
| 腮红 | A | 颧骨处渐变椭圆蒙版 |
| 眉毛着色 | A | 沿眉点的带状渐变 |
| 眼妆 | A | 眼眶上缘的多段渐变 |
| 美瞳 | B | 基于瞳孔点与眼宽估计圆环 |

每个美妆类别支持「样式 + 强度」两级控制。

### 身体（协调）

| 功能 | 级别 | 说明 |
|---|---|---|
| 颈肩过渡 | A | 脸部位移沿颈部向下衰减，到肩线为 0 |
| 瘦腰等身体塑形 | C | 本版不做 |

---

## 三、架构

```
┌──────────────────────────────────────────────┐
│ BeautyFaceDemo（SwiftUI）                       │
│ 选图 · 参数面板 · 预设 · 对比 · 导出              │
├──────────────────────────────────────────────┤
│ BFKit（依赖 Apple 框架）                         │
│ Core：解码、EXIF、纹理转换、编码                  │
│ Vision：人脸、关键点、人像蒙版、人体姿态            │
│ Render：Metal 管线与内核                         │
│ Pipeline：阶段编排、缓存、预览/导出                │
├──────────────────────────────────────────────┤
│ BFAlgorithms（纯 Swift，无平台依赖）               │
│ Geometry：MLS 求解、位移场、控制点映射              │
│ Params：参数模型、强度映射、预设                   │
│ Makeup：程序化妆面参数                            │
│ Body：颈肩衰减函数                                │
└──────────────────────────────────────────────┘
```

**依赖方向**：BeautyFaceDemo / AutoBeauty → BFKit → BFAlgorithms。`BFAlgorithms` 不能反向依赖任何上层模块，也不能 `import` Apple 框架。

### 3.1 处理流水线

```
原图解码（缩放到 4096 长边）→ rgba16Float 工作纹理
  → 检测：人脸框、76 点关键点、人像蒙版、人体姿态
  → 颜色与平滑：美白、磨皮、亮眼、白牙、去黑眼圈（不改几何）
  → 几何：合并位移场（脸部形变 + 颈肩协调） → 单次 warp
  → 变换关键点（同一 MLS 映射）
  → 美妆：使用变形后的关键点定位
  → 输出：编码保存，保留 EXIF 与颜色配置；Debug 由 AutoBeauty 写入 processed/，Release / iOS 由用户导出
```

### 3.2 对外 API（草案）

```swift
let engine = try BeautyEngine()
let analysis = try await engine.analyze(image)              // 检测与蒙版，可缓存
let preview  = try await engine.render(analysis, params: params, quality: .preview)
let final    = try await engine.render(analysis, params: params, quality: .full)
```

### 3.3 性能与交互策略

- 检测结果与蒙版按图片缓存，调节参数时不重新检测
- 拖动滑杆时使用 1024 像素的预览代理图，松手或导出时使用 4096 工作图
- 形变只重算 MLS 与位移场，属于小规模 CPU 计算

---

## 四、技术栈

| 类别 | 选型 | 许可 |
|---|---|---|
| 语言 | Swift（算法层、SDK、App），Metal Shading Language（内核） | — |
| UI | SwiftUI、PhotosUI、PhotoKit（仅添加权限） | 系统框架 |
| 图像 I/O | ImageIO、CoreGraphics | 系统框架 |
| 人脸与人体检测 | Vision | 系统框架 |
| GPU | Metal、MetalPerformanceShaders（盒式滤波） | 系统框架 |
| CPU 数学 | Accelerate | 系统框架 |
| 测试 | XCTest、os_signpost | 系统框架 |

**第三方库：无。** 第一版完全依赖 Apple 系统框架。后续若需引入（如 MediaPipe 做精细关键点），必须先在 ADR 中记录许可评估结论。

---

## 五、目录结构

```
BeautyFace/
├── README.md
├── dev_ledger.md
├── BeautyFace.xcworkspace
├── Packages/
│   ├── BFAlgorithms/          纯 Swift 算法层
│   │   ├── Sources/BFAlgorithms/
│   │   │   ├── Geometry/
│   │   │   ├── Params/
│   │   │   ├── Makeup/
│   │   │   └── Body/
│   │   └── Tests/BFAlgorithmsTests/
│   └── BFKit/                 Apple 框架依赖层
│       ├── Sources/BFKit/
│       │   ├── Core/
│       │   ├── Vision/
│       │   ├── Render/
│       │   ├── Shaders/
│       │   └── Pipeline/
│       └── Tests/BFKitTests/
├── BeautyFaceDemo/            SwiftUI App（macOS / iOS）
├── Tools/
│   └── AutoBeauty/            macOS 快速调试 CLI
├── SampleImages/              开发调试素材（由 .gitignore 排除，不入库）
└── processed/                 AutoBeauty 输出（由 .gitignore 排除，不入库）
```

---

## 六、构建与运行

**环境要求**

- Xcode 26 或更新版本
- macOS 15 或更新版本，Apple Silicon 芯片（日常开发与调试在此运行）
- iPhone 17 或 iPhone Air 真机（最终验收；Mac 上的性能与内存数据不作为验收依据，见 ADR-013 / ADR-014）

**运行步骤**

1. 打开 `BeautyFace.xcworkspace`
2. 选择 `BeautyFaceDemo` Scheme，目标设备选择 My Mac 或 iOS 设备
3. Debug 配置使用本机签名（`CODE_SIGN_IDENTITY = "-"`），无需开发者证书；Release 与真机运行仍需有效的 Apple Development 证书
4. `BeautyFaceDemo` 始终使用 PhotosPicker；系统相册路径只在非 Debug 模式下验证
5. iPhone 真机验证推迟到核心功能基本完成后；首次运行需在设备上信任开发者证书

**快速调试（AutoBeauty，仅 macOS）**

核心功能开发阶段使用 `AutoBeauty` 直接读取 `SampleImages/`，无需相册交互与人工点击：

```bash
swift run --package-path Tools/AutoBeauty AutoBeauty
```

- 默认批量处理 `SampleImages/` 下的全部图片
- 结果写入仓库根目录 `processed/`（已加入 `.gitignore`）
- 支持 `--input <目录>` / `--output <目录>` 覆盖默认路径
- M1 起已接入 BFKit：解码、EXIF 方向归一、4096 长边缩放、rgba16Float 工作纹理与编码输出
- M2 起默认检测人脸与人像蒙版，并输出 `_debug.png`（人脸框、76 点关键点、半透明蒙版）
- M3 起默认输出美化结果，并输出 `_skin.png`（皮肤蒙版灰度图）
- 参数：`--quality preview|full`、`--smooth <0...1>`、`--white <0...1>`、`--bright <0...1>`
- 示例：`swift run --package-path Tools/AutoBeauty AutoBeauty --quality preview --smooth 0.5 --white 0.3 --bright 0.2`
- `--no-detect` 关闭检测与美化，`--no-mask` 跳过人像蒙版（仅肤色）；需指定可执行名

**算法层单独测试**（不需要真机）

```bash
cd Packages/BFAlgorithms
swift test
```

---

## 七、测试

- **算法层**：`swift test` 在 Mac 上运行，覆盖 MLS 求解、参数映射、预设编解码、衰减函数。
- **AutoBeauty**：批量处理 `SampleImages/`，输出到 `processed/` 做回归与前后对比。
- **恒等回归**：合成测试图经 `rgba16Float` 工作纹理往返，最大通道误差 ≤ 1 灰阶。
- **人脸检测**：样例图检测 1 张脸、拼接图检测 2 张脸；76 点关键点；人像蒙版非空。
- **皮肤处理**：肤色 + 人像蒙版生成皮肤蒙版，眼/唇多边形排除；恒等参数往返误差 ≤ 1 灰阶。
- **快照测试**：固定图片与参数，输出与参考图比较，允许少量容差。
- **背景保护**：蒙版外像素变化接近 0（实测 ≤ 1 灰阶）。
- **几何检查**：位移场雅可比行列式为正，防止折叠。
- **真机验收**：两台设备 × 三类素材（前置自拍、4800 万像素原图、多人合影）。

详细的验收标准与测量方法见 `dev_ledger.md` 的里程碑章节。

---

## 八、性能目标

| 指标 | 目标 |
|---|---|
| 4096 长边完整处理 | iPhone 17 与 iPhone Air 各 < 1 秒 |
| 预览拖动响应 | 参数变化到画面更新 < 100 毫秒 |
| 内存峰值 | 处理 4800 万像素原图不闪退，峰值在设备可承受范围内 |
| 连续 20 张图 | 无内存增长，耗时波动 ≤ 20% |

macOS（arm64）为正式支持平台；性能验收仍以 iPhone 17 / iPhone Air 为准（ADR-014）。

---

## 九、隐私

- 图片与处理结果只保存在设备本地。
- Debug 阶段由 AutoBeauty 写入仓库 `processed/`，仅用于开发调试。
- Release / iOS 导出仅由用户主动选择（相册或 Files），不读取整个相册。
- 不包含任何网络请求或数据上传。

---

## 十、文档索引

| 文档 | 内容 |
|---|---|
| [README.md](README.md) | 项目概述、范围、架构、使用说明 |
| [dev_ledger.md](dev_ledger.md) | 架构决策记录（ADR）、里程碑、当前计划、风险、变更日志 |
