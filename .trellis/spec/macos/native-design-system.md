# Charkle macOS 原生设计与组件规范

> **适用范围**：Charkle macOS 原生客户端（`Sources/CharkleApp/` 与 `Sources/CharkleCanvas/`，目标平台 macOS 15–26/27，Swift 6.2）。  
> **与根设计宪章及多端规范的关系**：本规范承接根 [`DESIGN.md`](../../../DESIGN.md) 的品牌哲学与跨端契约，并与 Windows 端 [`fluent2-design-system.md`](../windows/fluent2-design-system.md) 形成「同魂不同壳（Same Soul, Native Shell）」对偶体系。凡涉及 macOS 端界面重构、组件抽离、SwiftPM UI 依赖引入与视觉打磨，均以此文档为单一执行依据。

---

## 1. 设计总纲：同魂不同壳（Same Soul, Native macOS Shell）

Charkle 在 macOS、Web、Windows 三端共享同一创作工具灵魂，但 macOS 端必须呈现**纯正的 macOS 原生工作室软件工艺**——依靠克制的光学层次、精确的 AppKit 控件密度、无多余嵌套框的清晰信息层级，以及 120fps 零闪烁的硬件加速交互，彻底消除「多胶囊漂浮、卡片套卡片、手搓假控件」带来的模板化堆砌感。

### 1.1 跨端不可妥协的「同魂」铁律（继承 `DESIGN.md`）

1. **90–95% 中性画布，作品绝对主角**：画廊与情绪板底面严格保持高纯度中性灰（Light `#F5F5F6` / Dark `#141518`，零泛黄偏色、零紫罗兰偏色），色彩仅来自素材本身、真实色板、自定义文件夹标记与克制使用的唯一强调色；画廊卡片默认纯图呈现，不在图下堆砌文字墙。
2. **严禁紫罗兰 / 霓虹渐变**：任何 chrome、按钮、强调色、背景光晕均不得落在 `OKLCH 270°–330°`；默认强调色为工作室钴蓝（`#2A60E0` / `#5B8DEF`）。
3. **跨端功能与交互契约一致**：四模画廊（纵向瀑布流 / 横向等高 / 画廊胶片 / 3D 环形画廊）、确定性 `Space` Quick Look、300pt 同步检查器零闪烁、自由/自动双模情绪板、无损双向同步与外部 Agent 安全边界保持 100% 一致。
4. **按频率克制动效与 `< 1%` 空闲 CPU 红线**：`⌘J` 随处跳转、方向键切图、单选切换与实时滚动保持 `0ms` 瞬时响应；静息态零持续动画或轮询，稳定空闲 CPU 严格 `< 1%`。
5. **平实克制文案**：界面标题直接命名事物，操作采用「动词 + 宾语」，严禁暴露底层工程术语或营销修饰语。

### 1.2 macOS 端纯正原生工艺与「去模板感」五大红线

1. **顶部工具栏去碎片化**：退役画廊正上方横排 7–8 个独立漂浮玻璃胶囊的碎裂布局，收敛为 **2–3 组语义清晰的液态玻璃岛**（或原生 `.toolbar` 分组），配合 macOS 26+ `.scrollEdgeEffectStyle(.soft)` 柔和边缘过渡，让顶部视野开阔、呼吸感充足。
2. **消灭「卡片套卡片」与多余描边**：`InspectorView` 与 `Settings/` 禁止出现「白底圆角卡 + 描边 + 内部再套灰底圆角框/胶囊」的多层套娃。检查器转向 `0.5pt` Retina Hairline 分区与紧密参数排版，设置页回归 macOS 原生分组表单节奏。
3. **统一按钮与控件家族，退役拟物键帽**：正式退役 `CharkleSkeuoButtonStyle` 以及 `SettingsChrome` 中各自为政的按钮样式，全端收敛为 4 个清晰语义变体（主强调 / 标准次级 / 轻幽灵 / 画布浮层玻璃）。
4. **用真 AppKit 精密控件替换粗糙手搓控件**：以 `NSSearchField` / `NSTokenField` 语义承载搜索与内联筛选 Token，以 `NSColorSampler` 系统屏幕吸管升级色彩筛选，以原生 `KeyboardShortcuts.Recorder` 替代静态快捷键文本，以原生文本排版引擎替代正则手写 Markdown 渲染。
5. **零闪烁与 120fps 硬件交互底座**：绝不允许 SwiftUI 动画逐帧驱动虚拟画廊宽度重排；侧栏与检查器开关走单次目标宽度 GPU 同步过渡、`MasonryClipView` 零重绘与 `MTKView` 原子事务提交。

### 1.3 三项已锁定 macOS 架构决策

1. **顶部信息架构收敛（分区标题 + 最多 3 组液态玻璃岛）**：
   - 顶层画廊视图默认顶部左侧展现清晰分区标题（如「全部素材」「收件箱」「建筑光影」）与紧凑计数，滚动后平滑融入顶条；
   - 顶部悬浮控制收敛为最多 3 组玻璃岛：**搜索与筛选岛**（内联 Token 搜索 + 筛选开关）、**视图与排序岛**（4 模切换 + 排序 + 密度缩放）、**行动与面板岛**（快速生成情绪板 + 同步状态 + 右侧检查器开关）；
   - 视觉筛选条、收件箱整理条与子文件夹导航条采用按需紧凑形态，绝不与顶部工具栏叠加出超过 2 层垂直噪音。
2. **设置浮窗与右侧检查器回归 macOS 原生精密节奏**：
   - 设置中心保留轻量居中独立浮窗形态（最大 `880 × 640pt`，不打断主画布心智），但内部统一到 macOS 原生 `.formStyle(.grouped)` 视觉节奏（统一行高、基线对齐、原生控件密度与可录制快捷键）；
   - 右侧检查器固定 `300pt`（后续支持原生分割线微调宽与双击复位），以 `0.5pt` Hairline 分区代替厚重卡片外壳，保留可拖拽排序的 `InspectorInfoSection` 与零闪烁同步缓存契约。
3. **强调色双策略（与 Windows 对偶）**：
   - 默认态（`accentSource = .studio`）：工作室钴蓝（Light `#2A60E0` / Dark `#5B8DEF`）；
   - 跟随系统态（`accentSource = .system`）：在「设置 → 通用 → 外观」提供**「跟随 macOS 系统强调色」**开关，开启后直接消费系统 `Color.accentColor` / `NSColor.controlAccentColor`，实时响应系统外观与多色强调色变更并维持按钮文字对比度 `>= 4.5:1`。

---

## 2. 技术栈与四层组件架构选型

保持 **Swift 6.2 + SwiftUI + AppKit + CoreAnimation + Metal** 原生架构（目标平台 macOS 15+，渐进增强 macOS 26/27 Liquid Glass），不引入任何 Web 风格或 iOS 风格的庞大第三方 UI 套件，通过四层明确分工实现旗舰级 macOS 质感：

| 层级 | 选型 | 职责与边界 |
| :--- | :--- | :--- |
| **原生窗口与材质层** | AppKit + macOS 26 SwiftUI（`CharkleWindowChromeBridge`、`CharkleSidebarMaterialBackground`、`GlassEffectContainer`、`NSColorSampler`、`NotchShelfController`） | 全出血透明标题栏与交通灯对齐、`NSVisualEffectView(.sidebar)` 侧栏透色、节制化 `.glassEffect` 浮层（macOS 15 回退 `.ultraThinMaterial` + `0.75pt` 顶边高光，Reduce Transparency 降级高对比实色）、系统屏幕吸管、纯黑硬件刘海融合 |
| **高帧率原生渲染层** | `CharkleCanvas`（CoreAnimation 瓦片回收池 + `MasonryClipView` + `RingGalleryMTKView` Metal + `MoodboardCanvasView`） | 10,000+ 素材 120fps 虚拟化瀑布流、单次目标宽度 GPU 同步抽屉过渡、Photos 风格精确资产锚定缩放、Metal 3D 环形画廊（静止缩放 `presentsWithTransaction` 零撕裂）、自由/自动双模情绪板 |
| **统一内部控件原语层** | `Sources/CharkleApp/DesignSystem/`（收口构建 `CharkleControls` 原语集） | 统一所有业务页面的按钮、分段器、Token 搜索栏、无套壳 Hairline 检查器分区、精密滑块、取色筛选浮层、全行折叠组（`CharkleDisclosureGroup`）、确认浮层（`CharklePopconfirm`）与交互式撤销 Toast（`CharkleToastOverlay`） |
| **精选轻量 SwiftPM 专业组件** | 仅引入补齐 macOS 原生短板的成熟小体量库（严格 Swift 6 并发兼容） | 1) **`KeyboardShortcuts`**（必选）：原生 AppKit 全局快捷键录制器 `KeyboardShortcuts.Recorder` + 冲突检测 + 本地化；<br>2) **`Textual`**（必选）：Swift 6 原生 SwiftUI 文本与 Markdown 排版引擎，用于 Quick Look 文档/README/社交帖文/笔记渲染；<br>3) **`Sparkle`**（可选，独立分发阶段接入）：macOS 标准原生应用内更新与安全差分升级；<br>4) **`LaunchAtLogin-Modern`**（可选，极轻）：封装 `SMAppService` 的开机自启原生开关 |

### 明确禁止引入的依赖与反模式

- 禁止引入大型跨平台/兼容层全集库（体量庞大，Swift 6 严格并发与 macOS 26/27 API 演进易产生维护负担）。
- 禁止引入模仿 Web 仪表盘或 iOS 卡片堆叠风格的第三方 SwiftUI 组件库。
- 禁止在纯色实底容器（如设置表单内容区、检查器正文区）上叠加 `.glassEffect` 或 `.ultraThinMaterial`，严禁玻璃叠玻璃。
- 禁止使用裸 SwiftUI `DisclosureGroup`（macOS 上仅点击小箭头有效，必须统一用 `CharkleDisclosureGroup`）。
- 禁止使用 `modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty` 判断无修饰键快捷键（中英文切换 Caps Lock 会导致失效，必须掩码 `[.command, .option, .control, .shift]`）。

---

## 3. 窗口外壳与信息架构（Window Shell & Layout）

### 3.1 总体几何布局

保持原生全高三栏工作台骨架，彻底收紧顶部悬浮噪音与检查器嵌套层级：

```text
┌───────────────────────────┬─────────────────────────────────────────────────────────────┐
│ [NSVisualEffectView y=0]  │  全部素材 1,248     [🔍 搜索或 #标签… ⚙]  [视图|排序|缩放] [生成][●][▤] │
│  ● ● ●       [⌘J] [收起]  ├──────────────────────────────────────────────┬──────────────┤
│  [Logo] Charkle           │                                              │  信息 | 相似 │
│  ──────────────────────── │   ┌──────┐ ┌──────┐ ┌──────┐ ┌──────┐        │ ──────────── │
│  素材库                    │   │      │ │      │ │      │ │      │        │ [缩略图预览] │
│   [●] 全部素材      1,248 │   │ 作品 │ │ 作品 │ │ 作品 │ │ 作品 │        │ 标题可编辑   │
│   [ ] 收件箱           12 │   │      │ │      │ │      │ │      │        │ ──────────── │
│   [ ] 未打标签          8 │   └──────┘ └──────┘ └──────┘ └──────┘        │ 快捷操作行   │
│   [ ] 最近添加            │   ┌──────┐ ┌──────┐ ┌──────┐ ┌──────┐        │ ──────────── │
│   [ ] 废纸篓              │   │ 作品 │ │ 作品 │ │ 作品 │ │ 作品 │        │ 主色板 / 标签│
│  ──────────────────────── │   └──────┘ └──────┘ └──────┘ └──────┘        │ ──────────── │
│  情绪板           [+生成] │                                              │ 备注与 OCR   │
│  智能文件夹           [+] │          [按需浮现: 多选 Liquid Glass 浮条]   │ ──────────── │
│  文件夹           [⇅] [+] │                                              │ 相机/AI 参数 │
│  标签 42           [全部] │                                              │              │
│  ──────────────────────── │                                              │              │
│  ⚙ 设置               ⌘, │                                              │              │
└───────────────────────────┴──────────────────────────────────────────────┴──────────────┘
```

### 3.2 各分区尺寸与交互规格

1. **左侧全高原生侧栏（`SidebarView`）**
   - **宽度与固定内宽契约**：展开态固定 `232pt`，折叠图标窄轨固定 `76pt`（对称避开 macOS 交通灯）；`collapsedRailBody` 与 `expandedSidebarBody` 各自锁定 `76pt` / `232pt` 内部宽度，在统一 `CharkleMotion.drawerEase`（`0.30s`）动画槽内平滑裁切，彻底杜绝展开首帧文字挤压换行。
   - **材质**：承载于 `NSVisualEffectView(.sidebar, blendingMode: .behindWindow)`，右缘以单一 `1pt` `CharkleTheme.hairline` 分隔；Reduce Transparency 下回退为高纯度中性灰实色 `#F2F2F3` / `#16171A`。
   - **导航行**：高度 `30pt`（左右内边距 `10pt`，连续圆角 `8pt`），选中项使用柔和中性高亮底 + 共享几何指示过渡 + 实心激活态图标；文件夹计数始终展示递归子树总数（`subtreeAssetCount`），标签区保持「Top 10 常用 + 最多 5 枚最近高频 + 可搜索全部标签 Popover」。

2. **画廊顶部融合栏（收敛为最多 3 组液态玻璃岛）**
   - 全部悬浮控制放进单一 `CharkleGlassContainer`（macOS 26+ 原生 `GlassEffectContainer`），配合 `.charkleScrollEdgeSoft(for: .top)` 在画廊滚动时与下方图片自然柔化融合，不再形成生硬横条截断。
   - **左侧标题/上下文区**：展示当前分区标题（`15pt / Semibold`，紧凑计数使用 `.monospacedDigit()`）或在文件夹视图中显示可点击面包屑；空白区内置 `CharkleWindowDragArea` 保障充足窗口拖动与双击缩放热区。
   - **岛 1 — 统一搜索与内联筛选岛**：集成搜索输入、内联已选筛选 Token（颜色点、格式、评分、标签）、语义搜图开关与筛选 Popover 触发器；彻底免除常驻 92pt 厚的展开筛选抽屉，仅在点击筛选器时以轻量 `Popover` 呈现。
   - **岛 2 — 视图与排版岛**：4 模切换分段器（纵向瀑布流 / 横向等高 / 画廊胶片 / 3D 环形）、排序菜单与密度缩放控件（宽屏显示紧凑步进滑块，窄屏 `< 790pt` 自动折叠入视图菜单，保持零溢出）。
   - **岛 3 — 创作、同步与检查器岛**：快速生成情绪板 CTA、独立隔离的同步状态胶囊（`FloatingSyncStatusPill`，不触发主画廊重渲染）、右侧检查器显隐按钮（`⌥⌘I`）。

3. **右侧 `300pt` 精密检查器（`InspectorView`）**
   - 保持 `300pt` 宽度并在主工作区与 Quick Look 之间 1:1 同步显隐与当前 Tab（`信息` / `相似`）。
   - **去卡片套卡片重构**：废除每个信息块各自套白底圆角框 + 描边的视觉冗余，改为统一沉静底面（`CharkleTheme.inspectorBackground`）+ 顶部极淡单图环境微晕（`ambientTint` `0.06` / `0.10`）+ **`0.5pt` Hairline 水平分区**；仅可编辑文本框、缩略图预览与色板条保留柔和内嵌底面（`CharkleTheme.inspectorFieldSurface`，连续圆角 `8pt`）。
   - 保留 `InspectorInfoSection` 拖拽排序与上下微调菜单，保留 `resolvedImageMetadata(for:)` 同步缓存与 `AssetThumbnailSurface.loadedAssetID` 零闪烁契约。

4. **居中设置浮窗（`SettingsOverlayView`）**
   - 保留居中独立浮窗形态（最大 `880 × 640pt`，连续圆角 `14pt`，柔光径向暗幕背板，无全屏毛玻璃卡顿）。
   - 左侧 `208pt` 沉静导轨 + 右侧原生分组表单节奏（外置淡雅分组标题 + 单层圆角分组底，行内绝不再嵌套次级圆角卡片）；右侧所有控件统一使用 `28pt` 基准高度与基线对齐。

---

## 4. macOS 原生 Token、圆角、排版与图标体系

### 4.1 表面、描边与强调色 Token（Light / Dark）

延续 `DESIGN.md` §2 语义命名，全部收敛于 `Sources/CharkleApp/DesignSystem/CharkleTheme.swift`，业务视图禁止散写裸十六进制色值：

| 语义角色 | Swift Token | Light Mode | Dark Mode | 职责与约束 |
| :--- | :--- | :--- | :--- | :--- |
| 画廊与画布底面 | `CharkleTheme.galleryGround` | `#F5F5F6` | `#141518` | 主画廊与情绪板底面，100% 高纯度中性灰无泛黄偏色 |
| 浮起实面 | `CharkleTheme.surfaceElevated` | `#FFFFFF` | `#1C1D20` | 设置分组、表格页、弹窗、实色降级浮层 |
| 柔和弱底面 | `CharkleTheme.surfaceSubtle` | `#F4F4F5` | `#25262B` | 悬停底（Hover `#EAEBEC` / `#2E3036`）、分段槽、紧凑徽章 |
| 侧栏实色降级 | `CharkleSidebarMaterialBackground` | `#F2F2F3` | `#16171A` | Reduce Transparency 下左侧导航轨实色底面 |
| 检查器轨道底面 | `CharkleTheme.inspectorBackground` | `#FFFFFF` | `#1C1D20` | 纯白检查器轨道（与 `#F5F5F6` 主画廊干净对比，无多余套壳） |
| 检查器内嵌输入底 | `CharkleTheme.inspectorFieldSurface` | `#F4F4F5` | `#25262B` | 纯白检查器内嵌无描边输入框与选择槽 |
| Retina 细分隔线 | `CharkleTheme.hairline` | `black @ 6.5%` | `white @ 7.5%` | `0.5pt`（Retina 1px）分区线与面板边界 |
| 次要文字 | `CharkleTheme.secondaryInk` | `#3C3C43 @ 72%` | `white @ 64%` | 副标题、参数键名（对比度 `>= 4.5:1`） |
| 主强调色（默认工作室） | `CharkleTheme.accent(for:source:)` | `#2A60E0` | `#5B8DEF` | `accentSource == .studio` 时生效；整屏占比 `< 3%` |
| 主强调色（跟随系统） | `CharkleTheme.accent(for:source:)` | `Color.accentColor` | `Color.accentColor` | `accentSource == .system` 时实时读取 macOS 系统强调色 |

### 4.2 光学材质与无障碍降级

- **macOS 26+**：悬浮工具栏、多选批处理浮条、情绪板底部工具坞、Quick Look HUD 与浮动 Toast 使用 `GlassEffectContainer` + `.glassEffect(.regular / .clear)`；刘海扩展态使用 `.darkNotch`（`#0B0C0F @ 88%` 暗玻璃），刘海贴合区保持纯黑 `#000000`。
- **macOS 15 回退**：`.ultraThinMaterial` + `0.75pt` 顶部微高光描边 + 克制单层投影。
- **Reduce Transparency 降级**：`@Environment(\.accessibilityReduceTransparency)` 为 `true` 时，立即关闭所有玻璃与材质效果，退回高对比实色 `CharkleTheme.surfaceElevated` + `1pt` 清晰描边。

### 4.3 连续同心圆角阶梯（4pt 网格）

所有圆角矩形强制使用 `RoundedRectangle(cornerRadius: ..., style: .continuous)` 并遵循 `innerRadius = max(4, outerRadius - padding)`：

| 层级 | Token | 半径 | 典型场景 |
| :--- | :--- | :--- | :--- |
| 浮坞 / 弹窗外框 | `Radius.dockOuter` | `20pt`（内 `12pt`） | 情绪板底部工具坞、多选浮条外廓 |
| Popover / 菜单 | `Radius.popoverOuter` | `16pt`（内 `10pt`） | 筛选 Popover、取色浮层、标签搜索浮层 |
| 设置浮窗 / 分组 | `Radius.settingsOuter` | `14pt`（内 `8pt`） | 设置浮窗外框与单层设置分组 |
| 素材卡片 / 情绪板节点 | `Radius.cardOuter` | `12pt`（内徽章 `6pt`） | 瀑布流卡片、情绪板图片卡 |
| 常规控件 / 行项 / 芯片 | `Radius.chip` | `8pt` | 侧栏行、标准按钮、检查器输入框、Tag 芯片 |
| 全胶囊 | `Capsule(style: .continuous)` | 全圆弧 | 顶部液态玻璃岛、紧凑状态点徽章 |

### 4.4 字体层级（SF Pro + PingFang SC）

| 角色 | 字体规格 | 场景 |
| :--- | :--- | :--- |
| 分区主标题 | `.system(size: 16, weight: .semibold)` / 首屏大标题 `22pt / .semibold` | 画廊顶部标题、情绪板页头、设置页头 |
| 分区小标题 | `.system(size: 11.5, weight: .semibold)` | 检查器分区头、设置分组头（不使用全大写宽追踪） |
| 正文与控件 | `.system(size: 13, weight: .regular / .medium)` | 侧栏项、按钮、设置行标题、正文输入 |
| 元数据与辅助说明 | `.system(size: 11.5, weight: .regular)` | 设置副说明、EXIF 键名、时间与路径 |
| 技术数值与快捷键 | `.monospaced` + `.monospacedDigit()` | 像素尺寸、HEX 色值、计数角标、同步百分比、键帽 |

### 4.5 图标体系收敛策略（统一线宽与双态语言）

目前代码中存在手绘双色 SVG 与 SF Symbols 混用、导致同一工具栏里图标视觉重量不一的问题。改造遵循清晰的二元边界：

1. **标准系统交互与工具栏图标 → 统一收口至 SF Symbols（双态语言）**：
   - 工具栏按钮、设置导航项、检查器参数图标、右键菜单项、排序/缩放/关闭/展开箭头统一采用 SF Symbols（统一 `.medium` / `.semibold` 字重与 `14–16pt` 光学尺寸）；
   - 激活态自动切换 `.symbolVariant(.fill)`（与 Windows `@fluentui/react-icons` 的 `Regular ⇄ Filled` 双态完全对偶），按需辅以克制的 `.symbolEffect(.replace)`。
2. **Charkle 专属品牌与核心视觉资产 → 保留定制矢量**：
   - Charkle 品牌标（`CharkleBrandMark`）、菜单栏图标（`CharkleMenuBarIcon`）、支持自定义颜色与符号的文件夹图标（`CharkleFolderIcon` 及 `CharkleIconCache.shared.menuFolderIcon` 非模板菜单图标）、以及空状态微型界面插画（`CharkleEmptyStateVignette`）继续保留定制矢量，确保品牌辨识度。

---

## 5. 组件改造与抽离映射清单

所有通用控件收拢至 `Sources/CharkleApp/DesignSystem/`，业务大文件（`MainWindowView`、`InspectorView`、`SidebarView`、`Settings/`）不再各自重复定义按钮样式、分段器或卡片壳：

| 现有散落实现 / 模块 | 目标原语 / 依赖 | 改造要点 |
| :--- | :--- | :--- |
| `CharkleSkeuoButtonStyle` + `SettingsPrimary/Secondary/DestructiveButtonStyle` | **统一** `CharkleButtonStyle`（4 变体） | 退役拟物键帽与两套割裂按钮；收敛为 `.accent`（强调主操作）、`.standard`（原生描边次级）、`.subtle`（透明悬停工具按钮）、`.destructive`（柔和危险态）；画布上方浮层操作使用 `.charkleLiquidGlass(..., interactive: true)`；统一高度阶梯 `24 / 28 / 32pt` |
| `MainWindowView.floatingTopBar` 裸 `TextField` + `floatingVisualFilterBar` | **新增** `CharkleTokenSearchField`（AppKit `NSSearchField` / 内联 Token 桥接） | 将已选颜色、格式、评分、标签渲染为搜索岛内联可删 Token；高级筛选收进轻量 `Popover`，移除 92pt 常驻展开抽屉 |
| `MainWindowView` / `InspectorView` / `Settings` 多处手写分段切换 | **新增** `CharkleSegmentedControl`（或原生 `Picker(.segmented)`） | 统一 2–4 项单选切换，支持共享几何滑块（`CharkleMotion.moveOnScreen`）或系统原生分段控件，消灭「胶囊套胶囊」 |
| `InspectorView` 内部多处白底圆角卡片 | **新增** `CharkleInspectorSection` | 去除多余圆角卡片套壳，以 `0.5pt` Hairline 分隔 + 全行可点击折叠头 + `LabeledContent` 参数行 + `.monospacedDigit()`，完整保留拖拽排序与上下微调 |
| `MainWindowView.filterColorPresets` 固定 10 色点 | **新增** `CharkleColorFilterPopover` + `NSColorSampler` | 保留 10 枚经典低饱和快速色点，新增**屏幕吸管（`NSColorSampler`）**与连续色轮/HEX 输入，设计师可直接吸取画布或外部屏幕颜色检索相似配色素材 |
| `CaptureShortcutsSettingsPane` 静态快捷键显示 + `GlobalHotkeyManager` | 引入 **`KeyboardShortcuts`**（SwiftPM） | 替换静态键帽文本为原生 `KeyboardShortcuts.Recorder`，支持点击录制、系统快捷键冲突提醒、一键清除与本地化键名显示 |
| `QuickLookRichViewers` 手写正则 Markdown 渲染 | 引入 **`Textual`**（SwiftPM） | 全面升级 Markdown 文档、GitHub README、社交帖文正文与长备注预览：原生 SwiftUI 文本选择、代码块语法样式、表格、引用块与 Light/Dark 自适应 |
| `SettingsChrome.swift` & 9 个设置面板 | 精炼 `SettingsSection` / `SettingsRow` + 原生 `.formStyle(.grouped)` 节奏 | 消除嵌套卡片与自定义开关/下拉差异，全部采用系统原生 `Toggle(.switch)`、`Picker`、`Stepper` 与统一样式按钮，在「通用 → 外观」新增「强调色来源（工作室钴蓝 / 跟随 macOS 系统）」 |
| `CharkleDisclosureGroup` / `CharklePopconfirm` / `CharkleToastOverlay` | 保留并微调光学一致性 | 保持全行点击热区、键盘无障碍与撤销倒计时，移除冗余硬描边，统一消费 `CharkleTheme` 强调色与圆角 Token |
| `VirtualizedMasonryView` & `RingGalleryMetalView` | 已就绪零闪烁底座（持续守卫） | 保持 `MasonryClipView` 零重绘、单次目标宽度 GPU 同步抽屉过渡与 Metal `presentsWithTransaction` 原子提交 |

---

## 6. macOS 原生 120fps 动效与零闪烁硬契约

### 6.1 统一时序与曲线 Token（`CharkleMotion.swift`）

| 角色 | Token | 曲线 / 弹簧参数 | 时长 | 场景 |
| :--- | :--- | :--- | :--- | :--- |
| 高频直达 | — | 无动画 | `0ms` | `⌘J` 快速跳转、方向键切图、单选切换、实时滚动 |
| 微反馈 | `hoverPress` | `cubic-bezier(0.23, 1, 0.32, 1)` | `120ms` | 按压缩放（`0.97`）、图标悬停与双态切换 |
| 快速退场 | `exitSm` / `popoverExit` | `cubic-bezier(0.23, 1, 0.32, 1)` | `110ms–130ms` | 所有浮层/弹窗/Toast 离开（强减速立即起步，严禁 `ease-in`） |
| 常规入场 | `enterSm` / `popoverEnter` | `cubic-bezier(0.23, 1, 0.32, 1)` | `160ms–180ms` | Popover、菜单、Toast、轻量面板进入 |
| 状态落定 | `settleStrong` / `moveOnScreen` | `(0.22, 1, 0.36, 1)` / `(0.77, 0, 0.175, 1)` | `220ms–240ms` | 分段滑块、导航指示移动、视图模式切换 |
| 抽屉滑移 | `drawerEase` | `cubic-bezier(0.32, 0.72, 0, 1)` | `300ms` | 侧栏折叠/展开、检查器显隐、画廊单次 GPU 同步重排 |
| 物理弹簧 | `gestureSpring` / `notchMorphSpring` | `spring(0.36s, 0.10)` / `spring(0.42s, 0.08)` | 自然落定 | Quick Look 共享元素连贯展开/飞回、硬件刘海形态融合 |

### 6.2 五大核心动效与零闪烁红线

1. **侧栏与检查器抽屉零闪烁切换（已落地，持续作为硬不变量）**
   - 侧栏与检查器开关由单一 `drawerEase`（`0.30s`）驱动，`SidebarView` 固定内部宽度并在动画槽内裁切；
   - `VirtualizedMasonryView` 通过 `sideChromeWidth` 在 `t = 0` 计算精确目标宽度（`MasonryLayoutEngine.paneTransitionTargetWidth`），仅执行 **1 次**带滚动锚定的布局重排，并以同曲线 GPU `CABasicAnimation` 同步滑移卡片；跨列远距换行的卡片保持不低于 `0.35` 起始透明度柔和落位，绝不闪白。
   - `RingGalleryMTKView` 在静止缩放期间启用 `presentsWithTransaction = true` 原子提交 Metal 帧。
2. **Photos 风格精确资产锚定缩放**
   - 连续捏合或 `⌘+滚轮` 缩放期间锁定同一资产锚点（悬停卡片 > 可见选中卡片 > 视口中心），先应用锚定 `newScrollY` 再挂载瓦片，首帧 0pt 跳变，锚定卡片抬升 `zPosition` 连续滑移。
3. **Quick Look 共享元素连贯动画（Connected Animation）**
   - 按 `Space` 或双击打开 Quick Look 时，查询当前卡片在窗口坐标系下的精确屏幕矩形（`sourceRect`），从该矩形以 `gestureSpring` 平滑展开至舞台；关闭时若目标资产仍在画廊视口内，精准飞回原卡片位置收拢；同步保持 `300pt` `InspectorView` 显隐与 Tab 1:1 连续无闪烁。
4. **画廊顶部滚动柔化融合**
   - 滚动时由 AppKit `NSScrollView` 驱动轻量合成层标题缩进，搭配 macOS 26 原生 `.scrollEdgeEffectStyle(.soft)`，绝不在每帧滚动回调中触发 `MainWindowView` SwiftUI body 重建。
5. **硬件刘海零溢出形态融合**
   - 保持 `NotchShellShape` 与 `NotchShellRimPath` 共享 `animatableData`，内部内容锁定最终目标宽高的铁律，严禁在刘海展开期间发生内容重排或溢边。

### 6.3 无障碍与性能硬红线

- 所有 SwiftUI 动画必须经 `CharkleMotion.accessible(..., reduced: reduceMotion)` 包装；CoreAnimation 布局过渡在 `reduceMotion == true` 时降级为 `animate: false` 单次无闪烁直达。
- Reduce Transparency 下所有玻璃浮层与侧栏材质无缝降级为高对比度实色。
- 常驻静置时零后台 `TimelineView` / 高频定时器空转，实测 `dist/Charkle.app` 静息 CPU 严格 `< 1%`。

---

## 7. 分阶段实施路线与交付门禁

### 实施阶段划分

- **Phase 1 — 顶部工具栏瘦身、统一按钮原语与强调色双策略**
  1. 在 `Sources/CharkleApp/DesignSystem/` 建立统一 `CharkleButtonStyle`（4 变体）与 `CharkleSegmentedControl`，退役 `CharkleSkeuoButtonStyle` 及 `SettingsChrome` 重复按钮样式。
  2. 重构 `MainWindowView` 顶部工具栏：将 7–8 个碎片胶囊收束为「分区标题 + 最多 3 组液态玻璃岛」，并验证 `800pt` 至 `2560pt` 全宽度响应式无溢出。
  3. 在 `AppCoordinatorStore`、`CharkleTheme` 与 `GeneralSettingsPane` 落地「强调色来源（工作室钴蓝 / 跟随 macOS 系统强调色）」开关与动态对比度适配。
- **Phase 2 — 检查器与设置页去卡片化、AppKit 精密控件升级与图标收敛**
  1. 重构 `InspectorView` 为 `CharkleInspectorSection`（`0.5pt` Hairline 分区，移除多余圆角卡片套壳，完整保留拖拽排序与零闪烁缓存）。
  2. 精炼 `SettingsOverlayView` 与 `SettingsChrome`（原生 `.formStyle(.grouped)` 密度、单层分组、系统原生控件基线对齐）。
  3. 落地 `CharkleTokenSearchField`（内联筛选 Token + 轻量筛选 `Popover` 取代 92pt 常驻筛选条）与 `CharkleColorFilterPopover`（集成原生 `NSColorSampler` 屏幕吸管）。
  4. 将标准系统操作图标收口至 SF Symbols 双态（`.symbolVariant(.fill)`），仅保留品牌标、自定义彩色文件夹与空状态微型插画为定制矢量。
- **Phase 3 — 精选 SwiftPM 专业组件接入与 Quick Look 连贯动画**
  1. 在 `Package.swift` 接入 **`KeyboardShortcuts`**，改造 `CaptureShortcutsSettingsPane` 与 `GlobalHotkeyManager` 支持点击录制自定义全局快捷键与冲突检测。
  2. 在 `Package.swift` 接入 **`Textual`**，升级 `QuickLookRichViewers`（Markdown、GitHub README、社交帖文正文与长备注）为原生 SwiftUI 富文本排版。
  3. 补齐 Quick Look 源卡片屏幕矩形查询与共享元素平滑展开/飞回动画（与 Windows Connected Animation 对偶）。
  4. 按需评估并接入 `Sparkle`（应用内安全更新）与 `LaunchAtLogin-Modern`（开机自启）。

### 必过交付门禁（每阶段合并前，遵循 `charkle-macos-ship`）

1. **零告警编译与全量测试**：
   ```bash
   swift build --build-tests -Xswiftc -warnings-as-errors && swift test --skip-build
   ```
2. **仓库纯净度与隐私扫描**：Python 正则扫描所有变更文件，确认零个人绝对路径、零敏感密钥、零外部参考产品/作者残留。
3. **签名 Release 打包与 `/tmp` 严格校验**：执行 `./scripts/build-app.sh release`，对剥离 `xattr` 的 `/tmp` 副本执行 `codesign --verify --deep --strict`（覆盖 `.app` 与 `.appex`）。
4. **实机多维目视与静息资源验证**：
   - Light / Dark × 开启/关闭「降低透明度」× 开启/关闭「减弱动态效果」× 工作室钴蓝/跟随 macOS 系统强调色，全部组合无对比度缺陷与视觉破绽；
   - 反复收起/展开侧栏与检查器、Photos 风格缩放、Space Quick Look 开关零闪烁；
   - 重启 `dist/Charkle.app` 稳定后静息 CPU 严格 `< 1%`。
