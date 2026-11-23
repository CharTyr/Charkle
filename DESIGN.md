# Charkle 设计系统与视觉体验规范（DESIGN.md）

> **适用范围**：Charkle 全平台统一视觉、交互与动效宪章——覆盖 **macOS 原生（SwiftUI / AppKit）**、**Web 版（React / Tailwind CSS v4）** 与 **Windows 原生（Tauri v2 / WebView2 / Win11 Mica）**。  
> **使用方式**：所有前端界面开发、重构、组件新增与体验调优均以此文档为单一设计依据；如某个页面需要偏离规范，必须先在此文档记录理由，禁止单页私自漂移。

---

## 1. 设计哲学与五条不可妥协的铁律

Charkle 是面向视觉创作者的**灵感收集库与 10 秒情绪板工作台**。界面的最高境界不是「展示自己有多炫」，而是让用户的每一张摄影作品、设计稿、配色卡与情绪板成为绝对主角。

1. **90–95% 中性画布，作品绝对主角**
   - 界面主背景与容器保持低饱和中性色（亮色暖纸灰 `#F6F6F5`，暗色深曜石 `#141517`），色彩只来源于用户的素材作品、真实色板、文件夹标记与唯一强调色。
   - **严禁紫罗兰 / 霓虹 AI 渐变**：任何界面 chrome、按钮、强调色、背景光晕均不得落在紫罗兰色相区（`OKLCH 270°–330°`）；需要高亮时使用工作室钴蓝（`#2A60E0` / `#5B8DEF`）或高对比度中性墨色。
   - **默认无图下杂乱文字**：画廊素材卡片默认纯图展现，不强行在每张图下面堆砌标题、说明或标签墙；次要信息通过悬停微控件、检查器或 Quick Look 按需呈现。
2. **一套语言贯穿三端，拒绝局部漂移**
   - 整套产品只允许一套颜色 Token、一套 4pt 空间网格、一套连续同心圆角阶梯、一套按钮家族与一套动效曲线。
   - 禁止在业务页面散落手写十六进制色值、临时像素圆角（如 `7px` / `9px`）或重复造同职责的弹窗/提示组件。
3. **克制的光学材质，绝不玻璃叠玻璃**
   - 液态玻璃（macOS Liquid Glass / Web `backdrop-filter` / Windows 11 Mica & Acrylic）**仅限悬浮在媒体与画布之上的控制层**（顶部筛选胶囊、情绪板底部工具坞、多选批处理浮条、Quick Look 控制栏、顶部收纳浮窗）。
   - 绝不在纯色背景上使用半透明毛玻璃（会发灰发脏），绝不玻璃叠玻璃，并始终提供 `Reduce Transparency` 高对比度实色降级。
4. **按频率克制用动效，以物理真实感服务理解**
   - 每个动画都必须回答「为什么动」：建立空间连续性、指示状态变化、或消除生硬跳变。
   - **高频操作零动画**：每天触发上百次的键盘动作（如 `⌘J` / `Ctrl+J` 随处跳转、列表键盘切项、实时滚动）必须瞬时响应，绝不加进出场过渡。
   - **退出用强 `ease-out`，严禁 `ease-in`**：界面元素离开时必须立刻起步且短于入场，杜绝迟滞感。
5. **平实克制的界面文案与纯净产品表达**
   - 界面标题直接命名事物，按钮用「动词 + 宾语」（如「移至回收站」「导出情绪板」而非模糊的「确定」），删除重复解释界面显而易见信息的废话。
   - 用户可见界面中严禁出现底层工程术语（如 `FTS5`、`CIELAB`、`scrypt`、`Manifest V3`、`Agent Harness`、`Shadow DOM` 等）或营销腔。

---

## 2. 色彩系统与表面层级（Light / Dark）

### 2.1 基础表面与文字 Token

所有组件必须消费语义角色 Token，禁止硬编码裸色值。

| 语义角色 | CSS Token | Swift / Native 映射 | Light Mode | Dark Mode | 职责说明 |
| :--- | :--- | :--- | :--- | :--- | :--- |
| 画廊与画布底面 | `--bg-gallery` | `CharkleTheme.galleryGround` | `#F6F6F5` | `#141517` | 主画廊、情绪板画布底色，严禁染色污染素材 |
| 浮起卡片 / 面板 | `--bg-elevated` | `CharkleTheme.surfaceElevated` | `#FFFFFF` | `#1E2025` | 弹窗、菜单、卡片、控件激活底面 |
| 弱对比底面 | `--bg-subtle` | `CharkleTheme.surfaceSubtle` | `#EDEDE9` | `#24272C` | 占位框、次要按钮、悬停底、徽章 |
| 左侧边栏底面 | `--bg-sidebar` | 系统侧栏 / Mica / `#F2F1EE` | `#F2F1EE` | `#17191D` | 导航轨底面 |
| 右侧检查器底面 | `--bg-inspector` | `CharkleTheme.inspectorBackground` | `#F1F0EC` | `#131519` | 右侧信息与候选池轨道 |
| 检查器输入区 | `--bg-inspector-field` | `CharkleTheme.inspectorFieldSurface` | `#F6F5F1` | `#16181D` | 检查器内嵌文本框与只读元信息块 |
| 细分隔线 | `--border-hairline` | `CharkleTheme.hairline` | `rgba(0,0,0,0.08)` | `rgba(255,255,255,0.09)` | 1px / 0.5pt 结构边界 |
| 强调边界 | `--border-strong` | — | `rgba(0,0,0,0.14)` | `rgba(255,255,255,0.16)` | 悬停边框、降级实色边界 |
| 主文字 | `--text-primary` | `.primary` | `#18191C` | `#F2F3F5` | 标题、正文、主数值（≥ 7:1 对比度） |
| 次文字 | `--text-secondary` | `CharkleTheme.secondaryInk` | `#5C6069` | `#A1A6B0` | 副标题、标签、次级操作（≥ 4.5:1） |
| 弱文字 | `--text-tertiary` | `.tertiary` | `#8A8F99` | `#6E737D` | 快捷键提示、时间戳、占位符 |

### 2.2 设置与引导专属中性色板

设置浮层与首次引导采用更沉静、低干扰的暖灰分层，不与主画廊抢视觉层级：

| 角色 | CSS Token | Light Mode | Dark Mode |
| :--- | :--- | :--- | :--- |
| 左侧导轨 | `--settings-rail` | `#F0EFEA` | `#17181B` |
| 右侧内容区 | `--settings-content` | `#F6F6F4` | `#121316` |
| 分组卡片 | `--settings-card` | `#FFFFFF` | `#1B1C20` |
| 轻底填充 | `--settings-subtle` | `rgba(0,0,0,0.04)` | `rgba(255,255,255,0.05)` |
| 区块标题文字 | `--settings-label` | `rgba(0,0,0,0.48)` | `rgba(255,255,255,0.46)` |
| 行分隔线 | `--settings-divider` | `rgba(0,0,0,0.065)` | `rgba(255,255,255,0.065)` |
| 卡片描边 | `--settings-border` | `rgba(0,0,0,0.08)` | `rgba(255,255,255,0.085)` |

### 2.3 强调色、语义状态色与微弱环境呼应

| 角色 | CSS Token | Light Mode | Dark Mode | 使用约束 |
| :--- | :--- | :--- | :--- | :--- |
| 主强调色 | `--accent` / `--accent-hover` | `#2A60E0` / `#2151C7` | `#5B8DEF` / `#74A0F7` | 选中环、主操作、焦点环、激活态图标；整屏占比 < 3% |
| 柔和强调底 | `--accent-soft` / `--accent-ring` | `rgba(42,96,224,0.11)` / `0.35` | `rgba(91,141,239,0.16)` / `0.44` | 文本选中、激活胶囊底、拖拽插入提示 |
| 成功 / 就绪 | `--success` / `--settings-positive` | `#249A4B` / `#15803D` | `#34C769` / `#4ADE80` | 同步完成、连接正常、已缓存离线 |
| 警告 / 提示 | `--warning` / `--settings-warning` | `#C98212` / `#B45309` | `#F2B23E` / `#FBBF24` | 未授权、配置待完善、本地回退 |
| 危险 / 删除 | `--danger` / `--settings-destructive` | `#D93B30` / `#DC2626` | `#F2584D` / `#F87171` | 永久删除、断开授权、异常错误 |
| 环境微呼应 | `ambientTint(hex)` | 选中素材主色 `opacity: 0.06` | 选中素材主色 `opacity: 0.10` | **仅限**单图检查器顶部 200px 渐变与 Quick Look 背景，绝不污染原图 |

### 2.4 情绪板与用户标记色板

- **便签主题（5 套）**：纸白 `#FFFFFF/#1D1F23`、墨黑 `#1D1F24/#F1F2F4`、暖米 `#F7F0E4/#392F22`、鼠尾草 `#E8F0EA/#203227`、石板蓝 `#E9EEF3/#1F2B36`。
- **分组框色调（6 套）**：中性灰 `#7D838B`、砂岩 `#B5956B`、苔绿 `#6B8E76`、石青 `#627A94`、陶土 `#BA6B55`、海蓝 `#4D7E97`。
- **筛选色板（10 枚低饱和高级色）**：`#1E2024`、`#5C6B73`、`#3D5A80`、`#4E7D96`、`#6B8E76`、`#D4A373`、`#BA6B55`、`#E5B243`、`#C8B8A6`、`#F0EEE9`。

### 2.5 三端光学材质映射

| 悬浮层级 | macOS (SwiftUI/AppKit) | Web (CSS) | Windows (Tauri v2) | Reduce Transparency 降级 |
| :--- | :--- | :--- | :--- | :--- |
| 浅/暗通用玻璃浮层 | macOS 26+ `.glassEffect(.regular)`；macOS 15 `.ultraThinMaterial` + 0.75pt 顶边高光描边 | `.charkle-glass`（Light `rgba(255,255,255,0.74)` / Dark `rgba(26,28,34,0.78)` + `blur(22px) saturate(180%)` + 内高光） | Win11 22H2+ Acrylic/Glass CSS；Win10 实色浮面 | `--bg-elevated` + `1px var(--border-strong)` + 柔和投影 |
| 顶部收纳暗色玻璃 / 刘海 | 刘海区严格纯黑 `#000000` 与硬件边框无缝融合；扩展态 `darkNotch` 暗玻璃 | `.charkle-glass-dark`（`rgba(11,12,15,0.88)` + `blur(24px)`） | 顶部悬浮窗纯深色高对比胶囊（`WS_EX_NOACTIVATE`） | `#0B0C0F` / `#121316` + `1px rgba(255,255,255,0.16)` |
| 窗口侧栏背景 | 原生侧栏材质 | 纯中性实色 `--bg-sidebar` | Win11 `DWMSBT_MAINWINDOW` (Mica)；Win10 `--bg-sidebar` | `--bg-sidebar` 纯实色 |
| 弹窗遮罩背板 | 柔光径向暗幕（中心 `0.075` 边缘 `0.165` Light；中心 `0.34` 边缘 `0.50` Dark），无全屏毛玻璃卡顿 | 统一对齐柔光径向暗幕（见 §8 P0-2 调优项），轻遮罩不压灰亮色画廊 | 与 Web 保持一致 | 纯半透明中性色，无 `backdrop-filter` |

---

## 3. 空间网格与连续同心圆角

### 3.1 4pt 空间网格与嵌套间距规律

- 所有内边距、外边距、间距必须落在 `4pt` 倍数上：`4, 8, 12, 16, 20, 24, 32`（极紧凑微元素仅允许 `2px` / `6px` 过渡）。
- **嵌套间距铁律**：组内元素间距 < 同级组间间距 < 容器外边距（例如行内图文 `6–8px`、卡片内行距 `12px`、设置分组间距 `20–24px`）。
- **对齐与边界**：左右边距保持视觉对称；任意弹窗与面板内层嵌套深度不超过 **2 层卡片**（杜绝盒中套盒再套盒）。

### 3.2 连续曲率与同心圆角公式

- **同心公式**：`innerRadius = max(4, outerRadius - padding)`，严禁父容器与内部子元素使用相同圆角值。
- **连续曲率**：
  - macOS：所有圆角矩形统一使用 `RoundedRectangle(cornerRadius: ..., style: .continuous)`。
  - Web / Windows：渐进启用 `@supports (corner-shape: superellipse(1.25))`，并对胶囊形（`.rounded-full` / `[data-pill="true"]`）显式保持 `corner-shape: round`。

| 场景 | 外层 Token / 值 | 内边距 Padding | 内层 Token / 值 |
| :--- | :--- | :--- | :--- |
| 悬浮工具坞 / 弹窗外壳 | `--radius-dock-outer`: `20px` | `8px` | `--radius-dock-inner`: `12px` |
| 弹出菜单 / Popover | `--radius-popover-outer`: `16px` | `6px` | `--radius-popover-inner`: `10px` |
| 设置卡片 / 分组面板 | `--radius-settings-outer`: `14px` | `6px` | `--radius-settings-inner`: `8px` |
| 素材卡片 / 情绪板节点 | `--radius-card-outer`: `12px` | `6px` | `--radius-card-inner`: `6px` |
| 小徽章 / 筛选标签 / 图标按钮 | `--radius-chip`: `8px` | — | — |
| 全胶囊（筛选条、步骤指示器） | `9999px` | `3–4px` | 内胶囊同样 `9999px` |

---

## 4. 字体层级与中英文排版开关

### 4.1 跨平台字体栈与字阶

- **macOS**：系统 `SF Pro` + `PingFang SC`；技术参数/HEX/尺寸使用 `.monospaced` + `.monospacedDigit()`。
- **Web**：`-apple-system, BlinkMacSystemFont, "SF Pro Text", "SF Pro Display", "PingFang SC", "Hiragino Sans GB", "Noto Sans SC", Inter, system-ui, sans-serif`。
- **Windows**：`"Segoe UI Variable Text", "Segoe UI", "Microsoft YaHei UI", system-ui, sans-serif`；等宽用 `"Cascadia Code", Consolas, monospace`。

| 层级 | 字号 / 字重 | 行高 | 字距 | 使用场景 |
| :--- | :--- | :--- | :--- | :--- |
| 引导主标题 | `24–27px` / `700` | `1.2` | `-0.02em` | Onboarding 欢迎与完成页 |
| 弹窗 / 页面标题 | `15–16px` / `600` | `1.35` | `-0.01em` | Modal 顶栏、设置页头、情绪板标题 |
| 正文 / 列表行 | `13px` / `500`–`400` | `1.5` | `0` | 侧边栏项、设置行标题、正文说明 |
| 辅助描述 / 元数据 | `11.5–12px` / `400`–`500` | `1.45` | `0` | 设置副标题、EXIF 键名、卡片角标 |
| 区块分组头 | `11px` / `600` | `1.3` | `0.01em` | 设置区块标签、检查器卡片头（不使用过度追踪全大写） |

### 4.2 Web / Windows 必选 CSS 排版开关

以下渐进增强规则写入全局 `tokens.css`（无需 polyfill），保证中英文混排精致无破绽：

1. **标题行长均衡**：`h1, h2, h3, .charkle-heading { text-wrap: balance; }`（短标题不出现最后一行孤字）。
2. **段落防孤词**：`p, .charkle-prose { text-wrap: pretty; }`（数字与单位之间不折行）。
3. **等宽数字防抖动**：所有计数徽章、尺寸（`1920 × 1080`）、EXIF 参数、同步进度、文件大小与快捷键必须启用 `font-variant-numeric: tabular-nums`（SwiftUI `.monospacedDigit()`）。
4. **按钮单行与弹性截断**：按钮固定 `white-space: nowrap`；Flex 行内可截断文本外层必须加 `min-width: 0`，文本本体配 `overflow: hidden; text-overflow: ellipsis; white-space: nowrap;`，被真实截断时提供 `title` / Tooltip 查看全文。
5. **中文混排自动留隙与行首标点挤压**（限定 `:lang(zh)`，跳过代码与输入框）：
   ```css
   :lang(zh) {
     text-autospace: normal;
     text-spacing-trim: trim-start;
   }
   code, pre, kbd, input, textarea {
     text-autospace: no-autospace;
   }
   ```
6. **尊重中文避头尾规则**：严禁使用 `line-break: anywhere` 或 `word-break: break-all` 解决长字符串溢出，统一用 `overflow-wrap: anywhere`（长 URL/Hash 可换行，普通中文保留标点避头尾）。

---

## 5. 图标体系与微型界面空状态

### 5.1 内置双色与分层 SVG 图标体系（48 枚）

- **功能图标（`duotone-<name>.svg`，16 网格，17–20px）**：
  - 源色板固定为主色 `#445C94`、辅色 `#B4BED4`，运行时按主题与状态动态重映射：
    - Light 常规：`#445C94` / `#B4BED4`；Light 激活：`#2A60E0` / `#AFC6F7`
    - Dark 常规：`#8EA8E8` / `#3D4E75`；Dark 激活：`#9BB7FF` / `#3E5998`
  - 用户自定义文件夹颜色推导：
    - Light：主色 `#RRGGBB`，辅色为与 `#FFFFFF` 50% 混合；
    - Dark：主色提亮 12%（`c * 0.88 + 255 * 0.12`），辅色为与 `#22242A` 45%/55% 混合。
  - **macOS 原生菜单防变灰**：`NSMenu` / `.contextMenu` 中的彩色文件夹图标必须预渲染为 `16×16` 且 `isTemplate = false` 的 `NSImage`。
- **英雄与品牌图标（`layered-<name>.svg`，32–96px）**：用于 Onboarding 支柱卡片、就绪印章与品牌标识；第三方真实产品标识（如 Figma、Google Drive、ChatGPT、GitHub）保留官方原色或官方单色规范，绝不手绘山寨版。

### 5.2 微型界面空状态规范（Miniature UI Vignettes）

空状态（空素材库、收件箱清零、无筛选结果、空文件夹、空情绪板）**禁止使用抽象插画、Emoji 堆砌或毫无信息量的空白页**，统一采用「产品自身界面的微型矢量缩影」：

- **构图**：`viewBox="0 0 160 120"`，圆角 `18` 的微底板叠加极细 45° 斜线底纹（Light `#FAFAFA` + 5% 线纹；Dark `#26262B` + 3.5% 线纹），居中绘制 **2–3 个真实界面对象的简笔缩影**（例如：空文件夹为带空槽位的文件夹卡；无筛选结果为搜索框 + 空卡片格；收件箱清零为已归档打勾的收件卡片）。
- **克制点缀**：画内不出现文字与人物；最多 **1 处强调色元素**（指向下一步动作如「导入」「新建情绪板」），无后续动作时全中性灰。
- **实现要求**：单文件自包含内联 SVG（无外链 `<image>`），通过 CSS 变量响应 Light / Dark 主题；如为强调元素加轻弹入场，必须受 `prefers-reduced-motion: no-preference` 门控。

---

## 6. 动效物理体系与性能红线

### 6.1 交互频率决策矩阵（决定「该不该动」）

| 使用频率 | 典型场景 | 动效策略 |
| :--- | :--- | :--- |
| **极高频（100+ 次/天）** | `⌘J` / `Ctrl+J` 随处跳转开关、方向键切图、单选选中切换、实时滚动画廊 | **零动画（0ms）**。瞬间响应是最好的高级感 |
| **高频（数十次/天）** | 按钮按压、工具栏悬停、筛选芯片切换、侧栏切页 | **极克制微反馈（120–220ms）**，仅 `transform` / `opacity` / 色彩 |
| **偶发（数次/天）** | 弹窗、设置浮层、Quick Look 展开、侧栏/检查器抽屉、Toast、拖拽排序 | **标准物理过渡（180–300ms）**，全程可打断 |
| **罕见 / 仪式感（首次/完成）** | 首次引导步骤切换、配置完成光环、收件箱清零瞬间 | **允许克制惊喜（280–680ms）**，单次触发不循环干扰 |

### 6.2 全平台统一曲线与时长 Token

所有动画必须引用命名 Token，禁止手写五花八门的相近贝塞尔值。UI 过渡常规上限 **300ms**。

| 角色 | CSS / 跨端 Token | 曲线 / 弹簧参数 | 时长 | 使用场景 |
| :--- | :--- | :--- | :--- | :--- |
| 小组件入场 | `--ease-out` / `--duration-sm` | `cubic-bezier(0.23, 1, 0.32, 1)` | `180ms` | Toast、菜单、小型提示卡片 |
| 中组件入场 | `--ease-out` / `--duration-md` | `cubic-bezier(0.23, 1, 0.32, 1)` | `240ms` | 弹窗面板、确认框、检查器内容 |
| 大画幅入场 | `--ease-out` / `--duration-lg` | `cubic-bezier(0.23, 1, 0.32, 1)` | `280ms` | 设置浮层、工作区转场 |
| 强效落定 | `--ease-out-strong` / `--duration-settle` | `cubic-bezier(0.22, 1, 0.36, 1)` | `220ms` | 激活态指示器、筛选芯片、画廊胶片焦点、分步显现 |
| 退场（小/中） | `--ease-out` / `--duration-exit-sm`/`md` | `cubic-bezier(0.23, 1, 0.32, 1)` | `130ms` / `170ms` | **所有退场均用强 `ease-out`** 且短于入场，绝不用 `ease-in` |
| 同屏位移动画 | `--ease-in-out` / `--duration-move` | `cubic-bezier(0.77, 0, 0.175, 1)` | `240ms` | 分段滑块移动、同屏元素重排、导航游标 |
| 抽屉与侧栏 | `--ease-drawer` / `--duration-drawer` | `cubic-bezier(0.32, 0.72, 0, 1)` | `300ms` | 侧边栏折叠、检查器/Quick Look 抽屉、候选池滑出 |
| 微确认回弹 | `--ease-overshoot` / `--duration-overshoot` | `cubic-bezier(0.34, 1.56, 0.64, 1)` | `260ms` | **严格限 ≤ 64px 控件**（星标、复选、钉选离线），严禁用于弹窗/抽屉 |
| 悬停与按压 | `--ease-out` / `--duration-press` | `cubic-bezier(0.23, 1, 0.32, 1)` | `120ms` | `:active` 轻压 `scale(0.97)` + `opacity: 0.88`；悬停绝不触发布局变化 |
| Popover 进/出 | `--duration-popover-in`/`out` | `cubic-bezier(0.23, 1, 0.32, 1)` | `160ms` / `110ms` | 从触发边缘 `scale(0.96 -> 1.0)` + `opacity(0 -> 1)` |
| 手势与刘海弹簧 | `gestureSpring` / `notchMorphSpring` | Swift `.spring(duration: 0.36, bounce: 0.10)` / `(0.42, 0.08)` | 自然衰减 | 拖拽释放、Quick Look 卡片缩放归位、刘海形变 |
| 拖拽避让波纹 | `rippleOffset` / `rippleDelay` | 位移 `A * pow(0.7, n)`（卡 `8pt` / 行 `6pt`） | 延迟 `24ms * n` | 侧栏文件夹/情绪板拖拽调序时的邻项避让与 2px 强调插入线 |

### 6.3 物理连续性、可打断性与性能铁律

1. **绝不 `scale(0)`**：现实物体不会凭空从零点出现。缩放起始统一在 `0.92–0.97` 配合 `opacity: 0`。
2. **锚点归源（Origin-Aware）**：所有 Popover、菜单、色板选择器必须把 `transform-origin`（SwiftUI `anchor:`）精准绑定到触发边角，并在靠近视口边缘自动翻转时同步翻转锚点（居中 Modal 例外，居中展开正确）。
3. **可打断优先**：快速连续触发或可逆的 UI（Toast、切换态、抽屉、展开收起）使用 CSS Transition（配合 `@starting-style`）或弹簧物理，避免 `@keyframes` 中途重新触发时从零跳变。
4. **合成层性能红线**：
   - 仅对 `transform` 和 `opacity` 做动画；**严禁 `transition: all`**，严禁对 `width` / `height` / `margin` / `padding` / `top` / `left` 做高频动画。
   - 实时滚动中（`isLiveScrolling`）动画彻底关闭；仅在离散缩放、切换布局时用 GPU 合成过渡。
   - 过渡期 `filter: blur()` 严控在 `≤ 8px`（绝不超过 `20px`）；不在父节点高频写 CSS 变量驱动大量子节点 `transform`。
   - 桌面常驻空闲 CPU 预算 `< 1%`（禁止空闲态挂持续 `TimelineView` 或高频轮询定时器）。
5. **无障碍与触控隔离**：
   - 所有纯悬停放大/浮起效果必须包裹在 `@media (hover: hover) and (pointer: fine)` 中，避免触屏点按后卡死悬停态。
   - `prefers-reduced-motion: reduce` / `accessibilityReduceMotion`：保留状态变化与 `150ms` 轻柔淡入淡出，移除位移、缩放、弹簧回弹与光环扩散。

---

## 7. 核心组件与交互选型规范

### 7.1 按钮家族（一套规范，绝不混造）

- 每个视图/弹窗底部**至多一个填充主按钮**，按视觉重量分为 6 个受控变体：
  - `primary`（工作室钴蓝填充）：常规表单/弹窗主提交；
  - `skeuoPrimary` / `skeuoSecondary`（5 层顶光触感键帽，按压 `translateY(1px)` 内影切换）：保留给 Onboarding 与高仪式感主 CTA；
  - `secondary`（中性轻底 + 细描边）：次要操作；
  - `ghost`（透明底，悬停轻底）：工具栏图标与行内轻量动作；
  - `danger`（柔红底红字，悬停实红）：不可逆危险动作；
  - `glass`（液态玻璃）：仅用于悬浮在媒体/画布上的操作按钮。

### 7.2 选择控件决策矩阵

选控件看**语义和生效时机**，不凭感觉乱用：

| 场景判断 | 正确控件 | 禁止用法 |
| :--- | :--- | :--- |
| 单项开/关且**拨动立即生效**（无保存按钮） | **Switch**（`role="switch"`） | 禁止放在需要点「保存」才生效的表单里；禁止用两个单选框表示「开/关」 |
| 单项是/否且**随表单提交生效** | **Checkbox** | 禁止在自动保存的设置列表里误用 Checkbox |
| 单选，**2–5 个短标签选项**（如外观模式、画廊布局、对齐方式） | **Segmented Control**（一眼看全，一点即中） | 禁止把 2–3 个短选项藏进下拉框增加点击成本 |
| 单选，**2–5 个需附说明行的选项**（如存储模式、权限级别） | **Radio Card / Radio Group**（左对齐纵向排列） | 禁止强塞进窄右栏 |
| 单选，**6+ 项或数量会增长的列表**（如文件夹、AI 模型、排序） | **Select**（≥15 项加顶部搜索形成 Combobox）；列表内用勾选对号 | 禁止用横向按钮排到溢出；下拉单选项内禁止画圆点单选框 |
| 执行一串动词操作（导出、复制、删除） | **Dropdown Menu**（执行后按钮保持原名） | 禁止把动词菜单做成 Select 或让按钮文字变成刚执行的动作 |
| 切换不同内容面板且不设定值 | **Tabs**（带滑动激活胶囊） | 与设定值的 Segmented Control 明确区分 |

### 7.3 浮层层级决策矩阵

| 场景 | 正确浮层 | 关键行为 |
| :--- | :--- | :--- |
| 仅补充文字解释（图标说明、截断文本全文、禁用原因） | **Tooltip** | 首个悬停约 `500ms` 出现，移至相邻图标立即切换；纯文字不可交互 |
| 锚定在按钮旁的轻交互（文件夹配色、标签选择、筛选条件） | **Popover** | 从触发边缘展开（`0.96 -> 1.0`），Esc / 点外部关闭 |
| **单项可撤销操作**（软删至回收站、改文件夹、标星） | **不弹窗确认** | 立即执行 + 出 Undo Toast，零打断 |
| **单项不可逆操作**（彻底删除单张素材、删除智能文件夹） | **Popconfirm**（就地气泡确认） | 锚定在触发按钮旁，路径最短，确认按钮写明具体动作 |
| **大影响 / 批量不可逆操作**或独立短表单（清空回收站、存储迁移、批量彻底删除） | **Dialog (Modal)** | 居中柔光径向背板，说明影响对象与不可撤销性，Esc 取消 |
| 需对照主画布的长面板（素材详情、相似推荐、候选替换池） | **Drawer / 侧栏** | 沿边缘使用 `--ease-drawer` 滑出，绝不用于操作确认 |

### 7.4 级联菜单安全缓冲

- 含子菜单的文件夹移动菜单（如「移动到文件夹 > 子文件夹」）必须具备鼠标向子菜单斜向移动时的安全三角区容错与轻量延时，杜绝指针斜穿相邻行时子菜单意外关闭。

### 7.5 Toast 与通知规范

- **定位与分工**：
  - **Toast**：回应用户刚刚主动触发的操作（短、轻、不打断、自动消失），分为三类：
    1. *状态型*（图标 + 一句话，如「已复制色值 `#2A60E0`」，停留 `3–4s`）；
    2. *动作撤销型*（已立即生效 + 「撤销」按钮 + 倒计时指示，停留 `≥5s`，悬停或键盘聚焦时暂停计时）；
    3. *进度变形型*（进行中原地平滑切换为完成态与「查看」入口）。
  - **绝不滥用 Toast**：表单字段校验错误贴在字段下方；必须修复的失败（同步失败、上传中断）留在对应条目或状态位并提供「重试」；不可逆操作在执行前确认而非事后提示。

### 7.6 加载态时间阈值与反闪烁规则

| 等待时长 / 类型 | 表现策略 | 关键细节 |
| :--- | :--- | :--- |
| **`< 300ms`** | **不显示独立加载器** | 避免闪现刺眼；仅本身带动作含义的图标（刷新/同步）可自按压起完整旋转至少 1 圈停在整圈 |
| **`300ms – 3s` 未知时长单操作** | 按钮原地旋转/切微加载器 | 保持按钮宽度与文案不变，防重复提交；遵循「延迟 `300ms` 出现、出现后至少停留 `500ms`」防闪规则 |
| **已知结构的列表/画廊/检查器** | **匹配真实几何的骨架屏** | 静态框架（侧栏、筛选栏、标题）立即渲染；`300ms` 后展示与真实尺寸一致的骨架，数据到达后逐项 `200ms` 淡入无布局跳动；刷新已有数据时保留旧内容配轻刷新态，绝不清空变白 |
| **`> 3s` 可计数长任务**（批量导入/同步/导出） | 进度条 + 计数/阶段 + 可取消 | 后台可继续时不锁死页面；完成后原地转为结果提示 |
| **高成功率可逆操作**（标星/改名/移文件夹/排序） | **乐观更新** | 界面立即更新，后台静默持久化；失败则完整回滚并在条目旁给出简短原因与「重试」 |
| **AI 策展 / 视觉分析流式过程** | 分步状态打勾 + 预留高度 | 每阶段完成即时打勾；结果区域预先占位仅向下扩展，杜绝抖动 |

### 7.7 核心产品界面专属契约

1. **三模画廊（垂直瀑布流 / 横向等高 / 画廊胶片）**：
   - O(log N) 虚拟化渲染；卡片仅呈现纯画面与极克制的角标，细指针悬停时画面内部 `scale(1.02)`；视频/GIF 悬停静默预览严格只读本地缓存（`cachedOnly=1`），绝不触发云端下载。
2. **Quick Look 全媒体沉浸预览（`Space`）**：
   - 始终加载**原图全分辨率**（绝不止步于缩略图）；高纵横比长条形图（`height >= 1600 && height / width >= 2.2`）默认进入垂直全宽滚动模式，并支持一键切回适配全屏与动态高倍缩放（最高 `16×`）。
   - 富媒体查看器（GitHub README、社交帖多图视频提取、Markdown、PDF、音频波形、3D 模型）在 Quick Look 与画廊胶片中保持 100% 交互一致。
3. **右侧 Inspector（自由排序 + 零闪烁铁律）**：
   - 信息卡片支持自由拖拽排序并持久化（如将 EXIF 或 AI Prompt 拖至顶部）。
   - 切换素材必须**零闪烁**：① 元数据采用 Frame-0 同步内存缓存解析（绝不切图后异步弹入新卡片）；② 相机 EXIF 卡片严格由 `hasMeaningfulCameraExif` 门控（不给普通插画弹出泛化的 `sRGB / 8-bit`）；③ 缩略图组件绑定 `loadedAssetID == asset.id`，杜绝闪现上一张素材旧图。
4. **情绪板工作室**：Freeform 无限画布优先（兼容旧版自动排版文档无跳变冻结升级），交互态摄像头与悬停状态与工具栏彻底隔离，保证 60–120 FPS 缩放平移。
5. **9 面板模块化设置与可跳过引导**：4 分组 9 面板居中浮层，支持 Esc / 背板关闭与深链直达；首次引导每步与全程均可随时跳过。

---

## 8. 三端前端调优审计与优先级路线图

基于对当前 macOS（v1.0.1）与 Web（`./web/packages/client`）真实代码的逐项体检，整理出按**杠杆率（体验提升 ÷ 改造成本）**排序的前端调优路线图，后续按批次逐项落地，Windows 端（M2–M5）直接以调优后标准一次建齐。

### P0 — 最高杠杆（优先打磨，立竿见影消除粗糙感）

| 编号 | 端 | 锚点位置 | 当前实测问题 | 调优目标 |
| :--- | :--- | :--- | :--- | :--- |
| **P0-1** | Web | `web/packages/client/src/design-system/ToastHost.tsx` | Toast 仅直接挂载/卸载，无入场和退场动画、无悬停/聚焦暂停自动关闭、Undo 缺少倒计时视觉指示 | 升级为可打断的进入/退场过渡（`@starting-style` + `transform`/`opacity` `180ms`/`130ms` `--ease-out`），支持悬停与聚焦暂停计时、Undo 倒计时环，并统一到视觉更顺手的位置与同心圆角 |
| **P0-2** | Web | `web/packages/client/src/design-system/ModalShell.tsx` | 使用 `@keyframes` 仅做入场、无退场过渡；背板为硬黑 `bg-black/42 backdrop-blur-[3px]`，亮色模式下压暗画廊且伴随全屏模糊开销 | 改为可打断的进/退场状态过渡（`240ms` 入 / `170ms` 出），并将背板校准为与 macOS `CharkleModalBackdrop` 一致的纯 GPU 柔和径向暗幕（亮色中心 `0.075` 边缘 `0.165`，暗色 `0.34`–`0.50`） |
| **P0-3** | Web | `web/packages/client/src/design-system/tokens.css` | 实测 `text-wrap: balance/pretty`、`text-autospace`、`text-spacing-trim` 出现次数为 `0` | 在全局基础样式中补齐 §4.2 全部中英文排版开关，并确保 `<html lang="zh-CN">` 生效、代码块与输入控件显式关闭 `text-autospace` |
| **P0-4** | Web | `GalleryView.tsx`, `InboxTriageBar.tsx`, `InspectorView.tsx`, `CandidatePoolPanel.tsx` | 存在 15+ 处裸 `animate-spin` 居中旋转且无延迟阈值；短请求闪烁明显，列表首屏缺少真实结构骨架屏 | 封装通用 `useDelayedFlag(loading, 300, 500)` 反闪烁 Hook；为画廊瀑布流、收件箱清理台、检查器相似列表、候选池建立与真实卡片几何对齐的统一样式骨架屏（同步光带，Reduce Motion 降级为静默） |

### P1 — 架构一致性与三端核心体验对齐

| 编号 | 端 | 锚点位置 | 当前实测问题 | 调优目标 |
| :--- | :--- | :--- | :--- | :--- |
| **P1-1** | Web / macOS | Web 业务层（155 处硬编码 hex、166 处散落 `rounded-*`）；macOS `QuickLookRichViewers.swift:1174` | Web 部分加载器硬编码 `#5B8DEF`、大量零散圆角绕过 `--radius-*`；macOS Markdown `.important` 提示框残留 `#8B5CF6` 紫色 | 将 Web 业务层硬编码颜色与圆角逐步收敛回 `tokens.css` 语义变量（保留画布色板等用户数据色）；将 macOS `.important` 提示色替换为工作室钴蓝/深石板色，实现 100% 零紫罗兰 |
| **P1-2** | Web | `web/packages/client/src/features/moodboard/MoodboardCanvasView.tsx:1372` | 节点动画同时过渡 `transform` 与 `width`（布局属性），在大量节点重排时易触发回流掉帧 | 消除 `width` 布局属性过渡，改为纯 `transform` 合成层动画或独立尺寸提交；同步排查 Popover / 抽屉是否均使用可打断过渡 |
| **P1-3** | Web | `QuickLookOverlay.tsx`, `InspectorView.tsx`, `@charkle/shared` | Web 端 Quick Look 缩放上限固定 `5×` 且尚未对齐 macOS v1.0.1 的**长条形图原图滚动模式**、**完整 EXIF & AI Prompt 解析展示**、以及**Inspector 卡片自由拖拽排序与零闪烁缓存** | 将 macOS v1.0.1 这三项核心体验完整同步到 Web（服务端 + 客户端）与 Windows M2 规格，保证三端体验零落差 |
| **P1-4** | Web | 7 处原生 `<select>`（`TopFilterCapsule.tsx:219`, `InspectorView.tsx:402/923`, `NodeViews.tsx:832`, `QuickCaptureModal.tsx:452`, `OnboardingModal.tsx:1425`, `SettingsChrome.tsx:314`） | 部分仅 2–4 个短选项的配置仍藏在原生 `<select>` 中，跨浏览器外观割裂且多一步点击 | 按 §7.2 控件矩阵逐一审定：2–5 项短选项升级为统一样式 Segmented Control；动态增长的文件夹/模型列表升级为可搜索定制 Select/Combobox |

### P2 — 工艺细节与情绪价值点睛

| 编号 | 端 | 锚点位置 | 当前实测问题 | 调优目标 |
| :--- | :--- | :--- | :--- | :--- |
| **P2-1** | 三端 | 画廊空态、收件箱清零、无筛选结果、空文件夹、空情绪板 | 部分空态仅靠图标 + 文字支撑，视觉识别度与指引感偏弱 | 按 §5.2 统一设计 5 枚自包含「微型界面示意图」SVG（Light/Dark 自适应），让每个空态一眼看出该区域装满后的样子与下一步动作 |
| **P2-2** | 三端 | 文件夹级联移动菜单、资产软删除交互 | Web 端多级移动菜单与卡片删除退场还可更顺滑 | 为多级子菜单补齐安全三角区防误关缓冲；为画廊/情绪板单卡移除增加干脆的 `150ms` 缩放淡出 + 可撤销 Toast 闭环 |
| **P2-3** | Windows | `./windows/ui/`（M2–M5 开发期） | 即将进入实现阶段 | 启动 M2 前直接复用本 `DESIGN.md` 的 Token、CSS 排版开关、骨架屏、Toast、微型空状态 SVG 与控件矩阵，零历史技术债 |

---

## 9. 三端前端评审与交付门禁

每次对 macOS、Web 或 Windows 界面进行视觉与动效调整后，必须过完以下 6 项门禁：

1. **双主题校验**：Light（`#F6F6F5`）与 Dark（`#141517`）下对比度、描边、阴影与玻璃边缘均清晰通透，无亮色发灰、无暗色糊成一团。
2. **无障碍降级校验**：开启系统 `Reduce Motion` 后无位移/弹簧/光环残留但状态切换清晰；开启 `Reduce Transparency` 后悬浮层退回清晰高对比实色表面。
3. **Token 与色域纯净度**：零新增紫罗兰色值、零 `transition: all`、零 `ease-in` UI 退场、零 `scale(0)`、零业务层硬编码颜色/圆角漂移。
4. **高频零延迟与帧率检查**：`⌘J`/`Ctrl+J` 跳转瞬开；画廊快速滚动无掉帧；macOS 静置空闲 CPU `< 1%`；切换素材时 Inspector 零闪烁。
5. **真实运行态目视验收**：macOS 启动 `dist/Charkle.app` 实测交互；Web 在真实浏览器（桌面宽屏 + 窄窗/平板视口）校验排版折行、截断与悬停态。
6. **文案与仓库纯净度**：用户界面无工程黑话、无营销废话；全仓无外部参考项目/作者名或本机绝对路径残留。
