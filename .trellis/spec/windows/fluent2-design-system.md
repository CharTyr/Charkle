# Charkle Windows Fluent 2 设计与组件规范

> **适用范围**：Charkle Windows 原生客户端前端（`windows/ui/`）及配套窗口外观能力（`windows/crates/charkle-platform-win/src/windowing.rs`）。  
> **与根设计宪章的关系**：本规范承接根 [`DESIGN.md`](../../../DESIGN.md) 的品牌哲学与跨端契约，并定义 Windows 11 桌面端的原生视觉外壳、Fluent 2 Token 体系、组件原语选型与物理动效标准。凡涉及 `./windows/ui/` 的界面重构、组件新增与交互打磨，均以此文档为单一执行依据。

---

## 1. 设计总纲：同魂不同壳（Same Soul, Native Shell）

Charkle 在 macOS、Web、Windows 三端共享同一产品灵魂，但桌面外壳与控件工艺必须顺应宿主操作系统的视觉物理规则，不再在 Windows 上强行仿制 macOS 液态玻璃折射胶囊或双层顶栏。

### 1.1 跨端不可妥协的「同魂」铁律（继承 `DESIGN.md`）

1. **90–95% 中性画布，作品绝对主角**：画廊与情绪板主工作面保持高纯度中性灰（Light `#F5F5F6` / Dark `#141518`，零泛黄偏色、零紫罗兰偏色），绝不给作品底面染泛黄米色或高饱和底色；画廊素材卡片默认纯图展现，不在图下堆砌文字与标签墙。
2. **严禁紫罗兰 / 霓虹渐变**：任何界面 chrome、按钮、强调色、光晕均不得落在 `OKLCH 270°–330°`；默认强调色为工作室钴蓝（`#2A60E0` / `#5B8DEF`）。
3. **跨端功能与交互契约一致**：三/四模画廊（纵向瀑布流 / 横向等高 / 画廊胶片 / 3D 环形画廊）、确定性 `Space` Quick Look、300px 同步检查器零闪烁、自由情绪板、无损同步与外部 Agent 安全边界 100% 保持一致。
4. **按频率克制动效与 `< 1%` 空闲 CPU 红线**：`Ctrl+J` 随处跳转、方向键切图、单选切换与实时滚动保持 `0ms` 瞬时响应；空闲态禁止挂持续循环动画。
5. **平实克制文案**：用户可见界面严禁出现底层工程术语或营销腔。

### 1.2 Windows 端本土化「不同壳」边界（WinUI 3 / Fluent 2 Desktop）

1. **采用 WinUI 3 桌面端语言（而非 Web 套件风）**：以 Windows 11 原生 **Mica Alt 窗口外壳 + 圆角抬升内容画布（Layer Surface）+ 1px 立体细描边（Control Elevation Border）+ 高可读性 Acrylic 瞬态浮层** 为核心视觉层次。
2. **全面退役跨平台违和材质**：移除 WebView2 端用 SVG `feDisplacementMap` 模拟的低模糊液态玻璃折射（`liquidGlassLens.ts`）、9 层高光反光胶囊、5 层拟物键帽按钮（`.charkle-skeuo-*`）以及全局强塞的 `20px` 超级椭圆大圆角。
3. **三项已锁定架构决策**：
   - **唯一全局搜索框置于左侧 Mica 导航栏顶部**：展开态直接输入搜索（含内联语义搜图开关），折叠态收为单一搜索图标按钮；`Ctrl+J` 保留为 `0ms` 极速跳转命令面板；彻底消除「顶栏搜索框 + 画廊胶囊搜索框」重复。
   - **设置中心保留居中独立浮窗形态**：维持轻量不打断主画布心智的居中模态浮窗（最大 `880 × 660px`），但内部导航、分组卡片、展开行与全部表单控件彻底升级为 Fluent 2 体系。
   - **强调色双策略**：默认使用工作室钴蓝（`#2A60E0` / `#5B8DEF`），同时在「设置 → 通用 → 外观」提供**「跟随 Windows 系统强调色」**开关，开启后实时读取系统强调色并自动完成亮/暗色对比度校准。

---

## 2. 技术栈与核心依赖选型

保持现有 **Tauri v2 + Rust + WebView2 + React 19 + TypeScript 5.8 + Tailwind CSS v4 + Zustand 5** 架构，通过以下四层明确分工实现 Win11 原生质感：

| 层级 | 选型 | 职责与边界 |
| :--- | :--- | :--- |
| **原生窗口层** | `windows/crates/charkle-platform-win/src/windowing.rs` | Win11 22H2+ 原生 Mica Alt（`DWMSBT_TABBEDWINDOW`）、窗口圆角（`DWMWCP_ROUND`）、沉浸式暗色模式、`HTMAXBUTTON` Snap Layouts、系统透明/动画偏好、系统强调色（`systemAccentHex`）读取与变更事件推送 |
| **交互原语层** | `@base-ui/react`（v1.0+） + Tailwind CSS v4 | 提供无样式、完整无障碍、原生支持 React 19 的交互组件原语（Dialog、Popover、Menu/ContextMenu、Select/Combobox、Switch、Slider、Tooltip、Collapsible、Tabs），自带 `data-starting-style` / `data-ending-style` 属性与现代浮层边界防溢出定位，与 Tailwind v4 `@layer` 零冲突 |
| **高阶动效层** | `motion`（`motion/react` + `LazyMotion`） | 仅用于 CSS 难以优雅完成的物理连续动效：侧栏激活指示条滑移（`layoutId`）、Quick Look 共享元素连贯动画（FLIP）、画廊滚动吸顶标题栏插值（`useScroll`）、页面入场/下钻过渡；根部包裹 `<MotionConfig reducedMotion="user">` |
| **系统图标层** | `@fluentui/react-icons` | 替换壳层与标准控件中的 `lucide-react`，统一 Fluent 几何比例与 `Regular`（未激活线框）⇄ `Filled`（激活实心）双态切换（使用显式具名导入 + `bundleIcon` 保障 Tree-shaking）；保留 Charkle 专属品牌图标（Logo、自定义彩色文件夹、微型界面空状态） |

### 明确禁止引入的依赖与反模式

- 禁止引入绑定运行时 CSS-in-JS 引擎的整套 Web 组件库（避免与 Tailwind CSS v4 级联层冲突，且其默认视觉偏向网页办公套件而非 WinUI 3 桌面端）。
- 禁止引入缺乏 React 19 / 无障碍 / 窗口防溢出保障的个人社区 WinUI 样式包装库作为运行时依赖。
- 禁止使用 `transition: all`；禁止对参与虚拟画廊布局的容器宽度（`width`）做逐帧 CSS 过渡。

---

## 3. 窗口外壳与信息架构（Window Shell & Layout）

### 3.1 总体几何布局

告别「全宽 38px 密集顶栏压在三栏之上 + 画廊顶部漂浮 7 个胶囊」的双层割裂结构，重构为标准 Win11 **全高 Mica 导航轨 + 右侧圆角抬升工作画布** 的 L/双层框架：

```text
┌───────────────────────────┬─────────────────────────────────────────────────────────┐
│ [Mica Alt 全高导航轨 y=0] │ [右侧融合顶条 40px: 面包屑/留白 | 全局微按钮 | — □ ×]  │
│  [Logo] Charkle  [折叠][+]├──────────────────────────────────────────┬──────────────┤
│  ┌──────────────────────┐ │ ┌─ 圆角抬升主内容画布 (tl: 8px) ───────┐ │              │
│  │ 🔍 搜索素材…   [语义]│ │ │                                      │ │  右侧检查器  │
│  └──────────────────────┘ │ │  全部素材   [筛选][排序][视图][缩放]  │ │   (300px)    │
│                           │ │  ────────── (滚动后平滑吸顶 Acrylic)  │ │              │
│  ▎ [●] 全部素材     1,248 │ │                                      │ │  信息 | 相似 │
│    [ ] 收件箱          12 │ │   ┌──────┐ ┌──────┐ ┌──────┐ ┌────┐  │ │  [卡片区]    │
│    [ ] 未打标签         8 │ │   │      │ │      │ │      │ │    │  │ │              │
│    [ ] 最近浏览           │ │   │ 作品 │ │ 作品 │ │ 作品 │ │作品│  │ │              │
│    [ ] 回收站             │ │   └──────┘ └──────┘ └──────┘ └────┘  │ │              │
│  ──────────────────────── │ │   ┌──────┐ ┌──────┐ ┌──────┐ ┌────┐  │ │              │
│  情绪板           [+生成] │ │   │ 作品 │ │ 作品 │ │ 作品 │ │作品│  │ │              │
│  智能文件夹           [+] │ │                                      │ │              │
│  文件夹           [⇅] [+] │ │         [按需浮现: 多选 Acrylic 浮条] │ │              │
│  标签 42           [全部] │ └──────────────────────────────────────┘ │              │
│  ──────────────────────── │                                          │              │
│  ● Google Drive · 已同步  │                                          │              │
│  ⚙ 设置           Ctrl+, │                                          │              │
└───────────────────────────┴──────────────────────────────────────────┴──────────────┘
```

### 3.2 各分区尺寸与交互规格

1. **左侧全高 Mica 导航轨（`NavigationView`）**
   - **宽度**：展开态 `248px`，折叠图标窄轨 `64px`（窗口宽度 `< 860px` 时自动建议或平滑切换至紧凑态），完全承载在系统 Mica Alt 底层上，**不使用不透明实色盖死壁纸透色**。
   - **顶部区（`40px`，含 `data-tauri-drag-region`）**：左侧为 Charkle 品牌标与字标（折叠态仅保留居中品牌标），右侧为「收起/展开侧栏（`Ctrl+\`）」与「快捷采集（`Ctrl+N`）」图标按钮。
   - **唯一全局搜索框（`AutoSuggestBox`）**：紧贴顶部区下方（左右内边距 `12px`，高 `32px`，圆角 `4px`，底部带 Win11 标志性焦点强调下划线 `2px`）：
     - 输入实时过滤当前视图（`120ms` 防抖）；右侧内嵌紧凑的「语义」微切换按钮与清空键。
     - 聚焦空输入或按 `Ctrl+J` 可直达快速跳转命令面板；按 `Ctrl+F` 直接聚焦此搜索框。
     - 侧栏折叠为 `64px` 窄轨时，搜索框收拢为居中的 `40 × 36px` 搜索图标按钮，点击自动临时展开侧栏并聚焦输入框。
   - **导航行（`NavItem`）**：高度 `34px`（左右内边距 `10px`，圆角 `4px`，行距 `2px`）；激活项使用柔和背景填充 + **左侧 `3px × 16px` 强调色圆角竖条** + `Filled` 态 Fluent 图标 + `Medium (500)` 字重。
   - **底部固定区（`border-top: 1px var(--win-stroke-divider)`）**：
     - 云同步状态行（状态点 / 进度百分比 + 传输模式名，点击弹出 Acrylic 同步详情浮层）。
     - 唯一「设置」入口行（`Ctrl+,`，点击打开 Fluent 2 居中设置浮窗）。

2. **右侧融合顶条（`40px`，`Titlebar` 瘦身重构）**
   - 仅跨越右侧内容区上方（不再横穿左侧栏），承载于 Mica Alt 底层，保留完整窗口拖拽与双击最大化能力。
   - **左侧槽**：在文件夹视图显示极简面包屑路径，在情绪板编辑视图显示返回按钮与画板标题；在顶层画廊视图保持清爽留白（作为充足窗口拖动区）。
   - **右侧工具槽（最多 4 个高价值系统微按钮 + 原生三键）**：
     - 区域截图采集（`Alt+Shift+A`）
     - 顶部悬浮窗开关（`Alt+Shift+S`）
     - 浅色 / 深色 / 跟随系统快捷切换
     - **唯一右侧检查器开关（`Ctrl+I`）**
     - 右端紧贴 `46 × 40px` × 3 个标准 Win11 窗口控制键（最小化 / 最大化含 `HTMAXBUTTON` Snap Layouts 同步 / 关闭悬停 `#C42B1C` 白字），使用精雕细线几何图标对齐 Windows 11 原生比例。

3. **圆角抬升主内容画布（Elevated Layer Surface）**
   - 紧贴融合顶条下方、导航轨右侧：设置 `border-top-left-radius: 8px`、`border-top: 1px solid var(--win-stroke-surface-card)`、`border-left: 1px solid var(--win-stroke-surface-card)`，背景采用高纯度中性灰层次面（Light `#F5F5F6` / Dark `#141518`），确保作品色彩零偏移且与左侧 Mica 形成清晰克制的前后景层次。
   - **画廊可折叠吸顶头部（Collapsible Sticky Header）**：
     - **展开态（`scrollTop === 0`）**：左侧为分区大标题（`24px / 600`，`Segoe UI Variable Display`，如「全部素材」「收件箱」「建筑光影」）+ 紧凑数量副标；右侧为整齐对齐的单行 Fluent 工具条（`32px` 统一高度）：筛选开关按钮（带激活计数徽章）、排序 `Select`、4 模视图切换分段器（纵向瀑布流 / 横向等高 / 胶片 / 3D 环形）、密度缩放滑块（含 `−`/`+` 步进按钮）、快速生成情绪板次级按钮。
     - **吸顶态（`scrollTop >= 36px`）**：大标题平滑上移并淡出，标题文字微缩移入吸顶条左侧，工具条背景平滑显现 `Acrylic` 半透明毛玻璃 + 1px 底分隔线（高度收敛为 `48px`），卡片在吸顶条后顺滑穿行。
     - **上下文副条**：筛选展开面板（视觉/色彩/评分/标签筛选）以独立 Fluent 卡片平滑向下展开；收件箱分拣条、回收站操作条与子文件夹快捷条以单行轻量 Fluent 工具条呈现，绝不再堆叠多层悬浮圆角胶囊。

4. **右侧检查器（`300px` Inspector Panel）**
   - 与主画布并排于右侧抬升区域内，通过柔和的 `1px var(--win-stroke-divider)` 与略微降阶的表面色（`--win-surface-inspector`）区分层级，顶部平齐融合顶条下方；与 Quick Look 内的检查器保持 100% 组件复用与状态同步。

### 3.3 冗余入口去重对照表

| 原重复入口 | 旧版位置（2 处冲突） | Fluent 2 新版唯一归位 |
| :--- | :--- | :--- |
| 搜索素材 / 跳转 | `Titlebar` 中央跳转框 + `TopFilterCapsule` 搜索胶囊 | **左侧 Mica 导航栏顶部唯一搜索框**（`Ctrl+F` 聚焦，`Ctrl+J` 仍独立呼出 0ms 命令面板） |
| 右侧检查器开关 | `Titlebar` 右侧按钮 + `TopFilterCapsule` 圆形玻璃按钮 | **右侧融合顶条唯一按钮**（`Ctrl+I`） |
| 打开设置中心 | `Titlebar` 齿轮按钮 + `SidebarView` 底部设置按钮 | **左侧导航栏底部唯一入口**（`Ctrl+,`） |
| 同步状态 | `Titlebar` 顶部胶囊 | **左侧导航栏底部状态行**（释放顶部空间，点开弹 Acrylic 进度卡） |
| 全局快捷键说明 | `Titlebar` 独立键盘图标 | 收拢进「设置 → 采集与快捷键」与 `Ctrl+J` 命令面板提示 |

---

## 4. Fluent 2 Desktop 视觉 Token 体系

所有 Windows 端样式收敛于 `windows/ui/src/design-system/tokens.css`，禁止业务组件硬编码十六进制色值或临时圆角。

### 4.1 表面与文字颜色 Token（Light / Dark）

直接对齐 WinUI 3 桌面资源层次，并保持 Charkle 画廊底面 100% 中性无偏色：

| 语义角色 | CSS Token | Light Mode | Dark Mode | 职责与说明 |
| :--- | :--- | :--- | :--- | :--- |
| Mica 窗口底透层 | `--win-mica-tint` | `rgba(242, 242, 243, 0.16)` | `rgba(22, 23, 26, 0.24)` | Win11 Mica Alt 开启时侧栏与顶条的轻度校准层 |
| Mica 侧栏实色降级 | `--bg-sidebar` / `--win-solid-base` | `#F2F2F3` | `#16171A` | Win10 / 关闭透明效果 / 窗口失焦时的侧栏与外壳底色 |
| 主画廊中性画布 | `--bg-gallery` | `#F5F5F6` | `#141518` | 主画廊与情绪板底色，与 `DESIGN.md` 高纯度中性灰严格一致 |
| 抬升内容面（Layer） | `--win-layer-default` | `rgba(255, 255, 255, 0.72)` | `rgba(42, 44, 50, 0.42)` | 叠加在 Mica/次底面上的卡片容器与内容区 |
| 浮起实面 / 弹窗底 | `--bg-elevated` | `#FFFFFF` | `#1C1D20` | ContentDialog、设置浮窗内容区、实色降级浮层 |
| 弱对比底面 | `--bg-subtle` | `#F4F4F5` | `#25262B` | 占位框、次要芯片、分段槽与弱对比容器 |
| 检查器次表面 | `--bg-inspector` | `#FFFFFF` | `#1C1D20` | 右侧纯白检查器轨道底面，与 `#F5F5F6` 主画廊清晰分层 |
| 检查器内嵌区块 | `--bg-inspector-field` | `#F4F4F5` | `#25262B` | 纯白检查器内嵌输入框与轻量信息槽 |
| 控件默认填充 | `--win-control-fill` | `rgba(255, 255, 255, 0.72)` | `rgba(255, 255, 255, 0.06)` | 标准按钮、输入框、Select 触发器常规态 |
| 控件悬停填充 | `--win-control-fill-hover` | `rgba(249, 249, 249, 0.54)` | `rgba(255, 255, 255, 0.09)` | 按钮/下拉框 `:hover` 态 |
| 控件按压填充 | `--win-control-fill-pressed` | `rgba(249, 249, 249, 0.32)` | `rgba(255, 255, 255, 0.04)` | 按钮 `:active` 态 |
| 控件激活输入底 | `--win-control-fill-input-active` | `#FFFFFF` | `rgba(30, 32, 38, 0.85)` | 搜索框 / 文本框 `:focus-within` 态 |
| 轻交互悬停底 | `--win-subtle-hover` | `rgba(0, 0, 0, 0.04)` | `rgba(255, 255, 255, 0.06)` | 侧栏行、幽灵图标按钮、菜单项 `:hover` |
| 轻交互按压/选中底 | `--win-subtle-active` | `rgba(0, 0, 0, 0.06)` | `rgba(255, 255, 255, 0.09)` | 侧栏激活项、开关激活按钮底 |
| 主文字 | `--text-primary` | `rgba(0, 0, 0, 0.895)` (`#1B1B1B`) | `#F5F6F8` | 标题、正文、主数值（对比度 `>= 7:1`） |
| 次文字 | `--text-secondary` | `rgba(0, 0, 0, 0.606)` (`#5E6168`) | `rgba(255, 255, 255, 0.76)` | 副标题、次级操作、EXIF 键名（`>= 4.5:1`） |
| 弱文字 / 禁用文字 | `--text-tertiary` | `rgba(0, 0, 0, 0.445)` (`#7D828C`) | `rgba(255, 255, 255, 0.48)` | 占位符、快捷键、计数角标 |

### 4.2 标志性 1px 立体细描边（Elevation & Surface Strokes）

Windows 11 控件精致感的核心来源是**顶部/底部微光差的 1px 立体细边**，而非厚重阴影：

| 描边角色 | CSS Token | Light Mode | Dark Mode |
| :--- | :--- | :--- | :--- |
| 控件基础边 | `--win-stroke-control` | `rgba(0, 0, 0, 0.06)` | `rgba(255, 255, 255, 0.07)` |
| 控件立体高光/底影边 | `--win-stroke-control-bevel` | `rgba(0, 0, 0, 0.16)`（用于底边 `border-bottom-color`） | `rgba(255, 255, 255, 0.10)`（用于顶边 `border-top-color`） |
| 卡片与画布边界 | `--win-stroke-card` | `rgba(0, 0, 0, 0.06)` | `rgba(255, 255, 255, 0.075)` |
| 浮层与弹窗亮边 | `--win-stroke-flyout` | `rgba(0, 0, 0, 0.08)` | `rgba(255, 255, 255, 0.11)` |
| 结构分隔线 | `--win-stroke-divider` | `rgba(0, 0, 0, 0.06)` | `rgba(255, 255, 255, 0.08)` |
| 强调按钮立体边 | `--win-stroke-accent-bevel` | 顶/侧 `rgba(255, 255, 255, 0.12)`，底 `rgba(0, 0, 0, 0.35)` | 顶 `rgba(255, 255, 255, 0.14)`，底 `rgba(0, 0, 0, 0.25)` |

标准按钮与输入框统一通过 `.win-control-elevation` 工具类施加立体描边（输入框聚焦态同步切为 `1px` 常规边 + 底部 `2px solid var(--accent)` 焦点底线）。

### 4.3 Acrylic 瞬态浮层与透明降级规则

仅限**瞬态浮层**（右键菜单、Popover、筛选展开板、吸顶工具条、多选批处理浮条、情绪板底部工具坞、Quick Look 底部 HUD）使用 Acrylic，严禁玻璃叠玻璃：

| 浮层类型 | Light Mode | Dark Mode | Backdrop Filter | 投影 |
| :--- | :--- | :--- | :--- | :--- |
| 标准 Acrylic 浮层（`.win-acrylic`） | `rgba(252, 252, 252, 0.85)` | `rgba(36, 38, 44, 0.86)` | `blur(28px) saturate(140%)` | `0 8px 24px rgba(0,0,0,0.14), 0 0 0 1px var(--win-stroke-flyout)` |
| 吸顶融合栏（`.win-acrylic-header`） | `rgba(245, 245, 246, 0.82)` | `rgba(20, 21, 24, 0.82)` | `blur(24px) saturate(135%)` | 底边 `1px solid var(--win-stroke-divider)` |
| Quick Look / 顶部收纳暗色浮层（`.win-acrylic-dark`） | `rgba(24, 25, 29, 0.88)` | `rgba(24, 25, 29, 0.88)` | `blur(28px) saturate(140%)` | `0 12px 32px rgba(0,0,0,0.44), 0 0 0 1px rgba(255,255,255,0.12)` |
| 模态居中遮罩（`Smoke`） | `rgba(0, 0, 0, 0.24)` | `rgba(0, 0, 0, 0.48)` | 无全屏模糊（纯合成层） | — |

**严格无障碍与低配降级（修复现行实现漏洞）**：
- 在 `@media (prefers-reduced-transparency: reduce)` 或 `:root[data-backdrop="solidFallback"]` 下，**必须关闭 `backdrop-filter: none`**，并将 `.win-acrylic` / `.win-acrylic-header` / `.win-acrylic-dark` 降级为 `100%` 实色表面（`--bg-elevated` / `--bg-gallery` / `#18191D`）+ 清晰 `1px` 描边，绝不强行覆盖保留透明模糊。

### 4.4 强调色与「跟随 Windows 系统强调色」契约

1. **默认态（`accentSource: 'studio'`）**：
   - Light：`--accent: #2A60E0`，`--accent-hover: #2151C7`，`--accent-pressed: #1A42A8`，`--accent-soft: rgba(42, 96, 224, 0.11)`，`--accent-text: #FFFFFF`。
   - Dark：`--accent: #5B8DEF`，`--accent-hover: #74A0F7`，`--accent-pressed: #4A7CE0`，`--accent-soft: rgba(91, 141, 239, 0.17)`，`--accent-text: #0D1117`（或高对比 `#FFFFFF` 视亮度校验结果）。
2. **跟随系统态（`accentSource: 'windows'`）**：
   - Rust 侧 `windowing.rs` 在 `WindowSurfaceState` 中扩展 `system_accent_hex: Option<String>`，读取 `HKCU\Software\Microsoft\Windows\DWM\AccentColor`（ABGR 转 `#RRGGBB`），并监听 `WM_DWMCOLORIZATIONCOLORCHANGED` 实时通知前端。
   - 前端 `theme.ts` 对系统强调色执行安全派生：
     - Light 模式下若相对亮度过高导致白字对比度 `< 4.5:1`，自动在 HSL/OKLCH 空间压暗主强调色用于文字与主按钮；
     - Dark 模式下自动提亮至清晰易读区间，并根据 WCAG 相对亮度动态计算 `--accent-text`（`#FFFFFF` 或 `#111214`）；
     - 若系统未返回有效色值（或非 Windows 环境），无缝回退到默认工作室钴蓝。

### 4.5 圆角与字阶（Fluent 2 Geometry & Typography）

- **圆角体系（4px 基准，取消全屏泛滥的 20px 超级椭圆胶囊）**：
  - `--win-radius-control`: `4px`（按钮、输入框、Select、侧栏导航行、菜单项、小标签）
  - `--win-radius-card`: `8px`（画廊素材卡片、检查器信息卡、设置分组卡、情绪板缩略卡）
  - `--win-radius-overlay`: `8px`（右键菜单壳、Popover、Dropdown、Toast、多选浮条、主画布左上角）
  - `--win-radius-dialog`: `10px`（`ContentDialog` 与居中设置浮窗外壳；内部子卡遵循同心原则 `6px`–`8px`）
  - 仅开关轨道（Switch）、激活竖条（3px pill）、状态指示点与极少数胶囊计数徽章使用 `9999px`。
- **字体栈与字阶**：
  - 正文与控件：`"Segoe UI Variable Text", "Segoe UI", "Microsoft YaHei UI", system-ui, sans-serif`
  - 大标题：`"Segoe UI Variable Display", "Segoe UI Variable Text", "Segoe UI", "Microsoft YaHei UI", sans-serif`
  - 技术数值/快捷键：`"Cascadia Code", Consolas, ui-monospace, monospace` + `font-variant-numeric: tabular-nums`
  - 字阶规范：

| 角色 | 字号 / 字重 | 行高 | 场景 |
| :--- | :--- | :--- | :--- |
| Page Title（Display） | `24px` / `600` | `32px` | 画廊/情绪板首屏大标题 |
| Dialog / Settings Title | `18px` / `600` | `24px` | 设置浮窗标题、`ContentDialog` 标题 |
| Section Subtitle | `14px` / `600` | `20px` | 检查器卡片头、设置分组标题 |
| Body / Nav / Control | `13px` / `400`–`500` | `18px` | 侧栏项、按钮、设置行标题、正文 |
| Caption | `12px` / `400` | `16px` | 设置副说明、EXIF 键名、卡片角标 |
| Micro Badge | `11px` / `500` | `14px` | 侧栏分组标签、计数徽章、快捷键键帽 |

保留 `DESIGN.md` §4.2 全部中英文排版开关（`text-wrap: balance/pretty`、`:lang(zh)` `text-autospace`、`overflow-wrap: anywhere`、`tabular-nums`）。

---

## 5. 组件映射清单（现有 `design-system/` → Fluent 2 + `@base-ui/react`）

所有基础交互组件收敛在 `windows/ui/src/design-system/`，业务层禁止绕过封装直接手写裸浮层或原生 `<select>`：

| 现有文件 / 模块 | 底层原语 | Fluent 2 改造要点 |
| :--- | :--- | :--- |
| `Button.tsx` | 原生 `<button>` | 退役 `skeuoPrimary` / `skeuoSecondary` / `glass`；收敛为 5 个变体：`accent`（主强调填充 + 立体边）、`standard`（Fluent 默认控件底 + 立体细边）、`subtle`（透明底 + 轻悬停，用于工具栏）、`danger`（柔和危险态）、`acrylic`（仅用于画布/媒体上方浮动操作）；高度规范：`xs: 26px`, `sm: 32px`（标准）, `md: 36px`, `icon: 32×32px` |
| `ModalShell.tsx` | `@base-ui/react` `Dialog` | 对齐 WinUI 3 `ContentDialog` 视觉：清晰标题区 + 内容区 + 微灰底色操作底栏（`border-top` 分隔，确认主按钮放右侧）；支持 `instant`（`0ms` 供 `Ctrl+J` 使用）与 `Smoke` 遮罩；内置焦点陷阱与关闭焦点还原 |
| `Popover.tsx` & `Popconfirm` | `@base-ui/react` `Popover` | 替换手写定位与退出计时器；自动视口边界翻转、`transform-origin` 绑定触发边、`.win-acrylic` 材质、`data-starting-style` / `data-ending-style` 平滑揭示 |
| **新增** `ContextMenu.tsx` / `DropdownMenu.tsx` | `@base-ui/react` `Menu` | 统一右键菜单（素材卡、文件夹、情绪板、画布）与下拉操作菜单；`32px` 菜单行高、统一前导 Fluent 图标槽、右对齐快捷键、原生支持级联子菜单安全三角（取代 `FolderMoveMenu` 手写三角） |
| `CustomSelect.tsx` | `@base-ui/react` `Select` / `Combobox` | 对齐 WinUI 3 `ComboBox`：选中项左侧带 `3px` 强调指示条（替代圆点），`>= 15` 项自动启用内嵌搜索框；移除 `variant="glassPill"` 液态玻璃胶囊样式 |
| `SegmentedControl.tsx` | `@base-ui/react` `Tabs` / `RadioGroup` + `motion` | 保留用于 2–5 项短单选与视图模式切换；激活滑块使用 `motion` `layoutId` 平滑滑移（`180ms`），4px 外圆角配内衬滑块 |
| `Slider.tsx` | `@base-ui/react` `Slider` | 回归 WinUI 3 双层圆形滑块（外白环 + 内强调色实心圆：悬停内圆 `scale(1.18)`、拖动按压 `scale(0.86)`），移除液态玻璃拉长胶囊滑块样式；保留 `−`/`+` 精确步进与 `Ctrl+滚轮` 联动 |
| **新增** `Switch.tsx` | `@base-ui/react` `Switch` | 从 `Titlebar.tsx` / `SettingsChrome.tsx` 抽离统一组件：对齐 WinUI 3 `ToggleSwitch`（`40 × 20px`，关闭态透明底 + 1px 强描边 + 次色圆点，开启态强调色填充 + 反色圆点，按压时圆点横向微拉伸 `14px -> 17px`） |
| **新增** `Tooltip.tsx` | `@base-ui/react` `Tooltip` | 替换全局散落的原生 `title` 提示；`4px` 圆角实面/轻影卡片，首项延迟 `500ms`，同组相邻图标 `0ms` 即时切换，支持附带快捷键徽章 |
| `CharkleDisclosureGroup.tsx` | `@base-ui/react` `Collapsible` | 保持全行点击热区与键盘无障碍，补齐平滑内容高度/透明度展开过渡；同步作为 `SettingsExpander` 基础原语 |
| `ToastHost.tsx` | Zustand + `motion` `AnimatePresence` | 升级为 Win11 `InfoBar` 风格 Acrylic 轻卡片（`8px` 圆角、左侧状态图标、一句话提示、撤销按钮与倒计时进度环），悬停与聚焦自动暂停计时 |
| `CharkleIcon.tsx` | `@fluentui/react-icons` + 品牌 SVG | 壳层与通用功能图标全部接入 `@fluentui/react-icons`（`bundleIcon(Filled, Regular)` 自动按 `isActive` 切换线框/实心）；保留自定义彩色文件夹图标、Charkle Logo 与微型界面空状态 |
| `SettingsOverlay.tsx` & `SettingsChrome.tsx` | `Dialog` + `SettingsCard` / `SettingsExpander` | **保留居中独立浮窗**（最大 `880 × 660px`，`10px` 圆角），内部改造为：左侧 `212px` Fluent 分组导航轨（配 `3px` 滑动激活条）+ 右侧 `SettingsCard`（图标 + 标题/副标题 + 右侧控件）与 `SettingsExpander` 可展开卡片行，在「通用 → 外观」加入「跟随 Windows 系统强调色」开关 |
| `liquidGlassLens.ts` | **退役删除** | 移除全局 `MutationObserver`、SVG `feDisplacementMap` 滤镜与滚动亮度采样逻辑，消除无谓的渲染与内存开销 |

---

## 6. Windows 11 Fluent 2 动效规范与性能红线

### 6.1 统一时序与曲线 Token（对齐 WinUI 3 标准）

| 角色 | CSS / Motion Token | 曲线 / 弹簧参数 | 时长 | 典型场景 |
| :--- | :--- | :--- | :--- | :--- |
| 极高频直达 | — | 无动画 | `0ms` | `Ctrl+J` 跳转、方向键切图、单选切换、实时滚动 |
| 微反馈 | `--win-duration-faster` / `--win-ease-out` | `cubic-bezier(0, 0, 0, 1)` | `83ms` | 按钮按压、开关圆点拉伸、图标悬停、微勾选 |
| 常规浮层与态变 | `--win-duration-fast` / `--win-ease-out` | `cubic-bezier(0, 0, 0, 1)` | `167ms` | 右键菜单、Popover、Tooltip、筛选条展开、颜色/描边过渡 |
| 结构与导航过渡 | `--win-duration-normal` / `--win-ease-out` | `cubic-bezier(0, 0, 0, 1)` | `250ms` | 切页 Entrance/Drill-in、居中弹窗入场、抽屉显隐 |
| 快速退场 | `--win-duration-exit` / `--win-ease-out` | `cubic-bezier(0, 0, 0, 1)` | `120ms`–`150ms` | 所有浮层/弹窗/Toast 离开（强减速立即起步，严禁 `ease-in`） |
| Fluent 物理弹簧 | `WIN_SPRING_SNAPPY`（`motion`） | `stiffness: 480, damping: 36, mass: 0.8` | 自然落定（~240ms） | 侧栏激活指示条滑移、分段器滑块、Quick Look 共享元素连贯动画 |

### 6.2 五大标志性动效精确契约

1. **侧栏激活指示条（`NavigationView SelectionIndicator`）**
   - 在激活导航项内渲染 `<m.span layoutId="win-sidebar-indicator" transition={WIN_SPRING_SNAPPY} />`（绝对定位在左侧 `0px`，宽 `3px`、高 `16px`、圆角 `9999px`、颜色 `var(--accent)`）。
   - 在不同导航项间切换时自动以物理弹簧平滑滑移并轻微形变，折叠与展开态共用同一 `layoutId` 无缝衔接。
2. **视图切换（`Entrance` & `Drill-in`）**
   - 在侧栏顶级分类（全部素材 / 收件箱 / 情绪板首页等）间切换：新内容区执行轻盈垂直上浮淡入（`y: 12px -> 0`，`opacity: 0 -> 1`，`200ms`，`cubic-bezier(0, 0, 0, 1)`）。
   - 进入或退回子文件夹、进入情绪板画布：执行轻微缩放下钻过渡（`scale: 0.985 -> 1`，`opacity: 0 -> 1`，`220ms`），避免生硬闪切。
3. **画廊头部滚动吸顶融合（Sticky Collapsing Header）**
   - 通过 `motion/react` 的 `useScroll({ container: scrollRef })` + `useTransform` 驱动标题区透明度/位移与顶部吸顶条 Acrylic 背景透明度（阈值区间 `scrollTop: 0px -> 48px`）。
   - 所有插值直写合成层 `transform` / `opacity`，绝不在 `onScroll` 里 `setState` 触发 React 重渲染。
4. **Quick Look 共享元素连贯动画（Connected Animation / FLIP）**
   - 按 `Space` 或双击打开 Quick Look 时，记录源卡片当前视口矩形 `sourceRect`；舞台主图在首帧按 `sourceRect -> targetStageRect` 反向变换（纯 `transform: translate + scale`），以 `WIN_SPRING_SNAPPY` 丝滑放大展开；背景 `Smoke` 暗幕与极低饱和环境氛围微晕（基于主色 `opacity: 0.08–0.12`，仅在 Quick Look 与 3D 环形画廊启用，绝不污染原图）同步淡入。
   - 关闭 Quick Look 时，反向查询当前选中资产的卡片 DOM 矩形：若仍在画廊视口内，精准飞回原卡片位置并收拢；若不可见则原地柔和缩退（`scale: 1 -> 0.96`, `opacity: 1 -> 0`, `150ms`）。
5. **侧栏 / 检查器抽屉零卡顿显隐（消除 `width` 逐帧重排）**
   - 废除现行 `.charkle-drawer-slot` 的 `transition: width 300ms`（该写法会每帧迫使虚拟瀑布流重复计算布局导致掉帧）。
   - **开关策略**：
     - 侧栏折叠/展开与右侧检查器显隐采用**目标布局宽度一次提交 + 面板内部纯 `transform: translateX` 与 `opacity`（`200ms` `--win-ease-out`）滑入/滑出**；
     - 瀑布流布局仅在开关动作开始/结束重排一次，配合画廊内卡片纯合成层位置过渡，彻底消除缩放期间的 60Hz 布局抖动。

### 6.3 性能与无障碍硬红线

- `<MotionConfig reducedMotion="user">` 统一感知系统动画设置，同时同步 `windowing.rs` 返回的 `animationsEnabled`（`SPI_GETCLIENTAREAANIMATION`）；关闭系统动画后，移除所有位移、缩放与弹簧，仅保留 `<= 150ms` 纯透明度切换。
- 严禁在画廊实时滚动（`isLiveScrolling`）中运行非必要动画或 DOM 测量；`Motion` 的 `LazyMotion` 按需加载特征集。
- 常驻静置时零后台 `requestAnimationFrame` / 定时器轮询，空闲 CPU 预算严格 `< 1%`。

---

## 7. 分阶段实施路线与交付门禁

### 实施阶段划分

- **Phase 1 — 骨架重构、依赖接入与 Token 重建**
  1. 在 `windows/ui/package.json` 引入 `@base-ui/react`、`motion`、`@fluentui/react-icons`。
  2. 重写 `windows/ui/src/design-system/tokens.css` 为 Fluent 2 Desktop Token，退役并移除 `liquidGlassLens.ts` 及其全局调用。
  3. 重构 `App.tsx`、`Titlebar.tsx`、`SidebarView.tsx`、`TopFilterCapsule.tsx`、`GalleryView.tsx`：落地全高 Mica 导航栏、左侧顶部唯一搜索框、瘦身融合顶条、抬升圆角画布与画廊分区大标题 + 吸顶工具条，清理全部重复入口。
- **Phase 2 — 组件原语升级与 Fluent 2 动效引擎**
  1. 将 `Button`、`ModalShell`、`Popover`、`ContextMenu/DropdownMenu`、`CustomSelect`、`SegmentedControl`、`Slider`、`Switch`、`Tooltip`、`CharkleDisclosureGroup`、`ToastHost` 迁移至 `@base-ui/react` + Fluent 2 样式与 `@fluentui/react-icons`（Regular/Filled 双态）。
  2. 接入 `motion/react`（`LazyMotion` + `MotionConfig`）：落地侧栏激活指示条滑移、切页 Entrance/Drill-in、画廊滚动吸顶融合、Quick Look 共享元素连贯动画、以及零逐帧重排的抽屉开关。
- **Phase 3 — 设置浮窗重塑、系统强调色与全量验收**
  1. 扩展 `windowing.rs` 读取 `systemAccentHex` 并监听 `WM_DWMCOLORIZATIONCOLORCHANGED`，接入前端强调色派生与设置页开关。
  2. 重塑 `SettingsOverlay.tsx` 与 `SettingsChrome.tsx`（居中 Fluent 2 浮窗 + `SettingsCard` / `SettingsExpander`），微调情绪板首页与检查器细节。
  3. 更新并补齐 Vitest 组件/回归测试，过完构建与实机目视门禁。

### 必过交付门禁（每阶段合并前）

1. **静态与测试门禁**：
   - `windows/` 下 `cargo fmt --all -- --check`、`cargo clippy --workspace --all-targets -- -D warnings`、`cargo test --workspace` 全绿。
   - `windows/ui/` 下 `npm run typecheck`、`npm test`、`npm run build` 全绿。
2. **双主题与系统开关实测**：Light / Dark、开启/关闭 Windows「透明效果」、开启/关闭 Windows「动画效果」、默认工作室钴蓝 / 跟随 Windows 系统强调色 8 种组合均清晰无破绽。
3. **窗口交互实测**：Win11 原生 Mica Alt 透色与失焦回退正常；最大化/还原及 `HTMAXBUTTON` Snap Layouts 悬停弹窗正常；窄窗（`800px`）到超宽屏（`2560px`）无溢出、无双滚动条、无文字截断错位。
4. **性能与规范纯净度**：无 `transition: all`、无 `ease-in` 退场、无紫罗兰色值、无逐帧 `width` 布局动画、`Ctrl+J` 0ms 瞬开、空闲 CPU `< 1%`、仓库无任何外部参考产品/作者名或本机绝对路径残留。
