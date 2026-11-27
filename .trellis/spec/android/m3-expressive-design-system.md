# Charkle Android Material 3 Expressive 设计与组件规范

> **适用范围**：Charkle Android 原生客户端（`android/`，覆盖手机、折叠屏与 Android 平板，Jetpack Compose + Material 3 1.5+ Expressive）。  
> **与根设计宪章的关系**：本规范承接根 [`DESIGN.md`](../../../DESIGN.md) 的品牌哲学与跨端契约，并定义 Android 端的原生视觉外壳、Material 3 Expressive Token 体系、**双区色彩策略（主画廊绝对中性 + 单图/收件箱作品主色沉浸融合）**、连接形变控件与弹簧物理动效标准。凡涉及 `./android/` 的界面开发、组件新增与体验打磨，均以此文档为单一执行依据。

---

## 1. 设计总纲：同魂不同壳（Same Soul, Native Shell）

Charkle 在 macOS（Liquid Glass）、Windows（Fluent 2）、iOS（Liquid Glass Morphing Bar）与 Android（Material 3 Expressive）四端共享同一产品灵魂，但交互与材质严格顺应 Android 16 / Material 3 Expressive 的物理和形态语言——绝不在 Android 上生硬照搬 iOS 毛玻璃折射胶囊或双层桌面顶栏。

### 1.1 跨端不可妥协的「同魂」铁律（继承 `DESIGN.md`）

1. **主画廊与情绪板画布 90–95% 中性，作品绝对主角**：主画廊与情绪板工作面始终保持低饱和中性底色（Light `#F6F6F5` / Dark `#141517`），卡片默认纯图展现，不在图下堆砌标题与标签墙。
2. **默认零紫罗兰 / 霓虹渐变**：所有默认界面 chrome、按钮、强调色、加载指示器均不得落入紫罗兰色相区（`OKLCH 270°–330°`）；默认 Brand Seed 锁定为工作室钴蓝（`#2A60E0` / `#5B8DEF`）。
3. **与 iOS v1.5.0 功能与交互 1:1 对齐**：全量覆盖纯图虚拟化瀑布流（锚定双指缩放 + 滑动多选）、4 模随手搜图与 CIELAB 主色容差筛盘、收件箱逐张归档/瀑布流双模、全屏沉浸 Quick Look + 检查器 + 相似检索、自由/自动排版情绪板工作室、Pinterest 无限空间探索、多源采集与系统分享接收、多后端无损 `/.charkle/` 同步。
4. **高频操作零卡顿，动效服务空间理解**：快速滚动瀑布流、键盘/手指连续切项禁止阻塞动画；支持系统 `Reduce Motion`（`AnimatorDurationScale == 0`）无障碍降级。
5. **平实克制文案**：按钮统一「动词 + 宾语」，用户可见界面禁止出现底层工程术语（如 `UniFFI`、`FTS5`、`CIELAB`、`HLC`、`SAF`、`PKCE` 等）。

### 1.2 Android 专属「双区色彩策略」（已锁定决策）

这是 Charkle Android 区别于常规 M3 应用的核心审美设计——把 Material 3 Expressive 的色彩表现力用在**最能放大作品情绪、又绝不破坏设计师专业判色**的位置：

| 区域 | 色彩策略 | 材质与容器 | 说明 |
| :--- | :--- | :--- | :--- |
| **Zone A — 中性工作区**<br>（主素材库瀑布流、文件夹视图、情绪板画布、Pinterest 无限空间、全局目录、设置页） | **绝对中性画布 + 工作室钴蓝强调色**<br>• `background` / `surface` 严格锁死 `#F6F6F5`（Light）与 `#141517`（Dark）<br>• Surface Container 阶梯使用纯中性暖灰/曜石灰，绝不因壁纸 Monet 染色而让画布泛粉/泛紫<br>• 「设置 → 外观」提供可选开关：**跟随系统动态取色（仅作用于控件强调色与激活胶囊，画廊底面始终保持纯中性）** | M3 Expressive 形态语言拉满：`HorizontalFloatingToolbar`、独立形变 FAB、`ButtonGroup` 连接按钮组、分段圆角设置卡片、`LoadingIndicator` 与 `WavyProgressIndicator` | 保证设计师浏览几十上百张不同色相参考图时，视觉基准绝对客观、画面通透干净 |
| **Zone B — 作品沉浸色区**<br>（单图全屏预览 Quick Look、收件箱「逐张归档」聚焦台、情绪板封面卡片底栏） | **作品主色实时驱动 Expressive `ColorScheme`**<br>• 读取素材已提取的 `dominantColors.first`（无提取值时通过量化器离线取样）作为 Seed，生成 `PaletteStyle.Expressive` / `PaletteStyle.Content` 主题色板<br>• 顶部返回钮、右上角连接按钮组、底部操作坞、氛围渐变背景、音频波浪进度条随切图以弹簧动效丝滑过渡<br>• **一键「原色校对模式」**：单图预览工具条内置护色开关，点按瞬切纯黑/纯中性无染色背景，支持在设置中设为默认 | 全出血作品舞台 + 无遮挡垂直分区（顶栏 → 纯净画面 → 胶片缩略条 → 底部 Expressive 操作坞），作品主色仅渲染氛围层与操作控件，绝不叠加滤镜污染原图本身 | 每次翻看单张灵感图或清理收件箱时，整个界面都会像为这幅作品量身定制的画册展台一样呼吸变化 |

---

## 2. 色彩系统与表面角色映射

### 2.1 Zone A：中性工作区静态 Token（`CharkleLightColorScheme` / `CharkleDarkColorScheme`）

所有 Compose 业务组件必须通过 `MaterialTheme.colorScheme` 与 `CharkleColors.current` 消费语义 Token，禁止硬编码裸 `Color(0xFF...)`。

| Material 3 Role | Light (`#F6F6F5` 体系) | Dark (`#141517` 体系) | 对应 `DESIGN.md` 语义与职责 |
| :--- | :--- | :--- | :--- |
| `background` / `surface` | `#F6F6F5` | `#141517` | 主画廊、情绪板、Pinterest 无限画布底面（绝对中性） |
| `surfaceContainerLowest` | `#FFFFFF` | `#0F1012` | 最高对比卡片底、输入框内底 |
| `surfaceContainerLow` | `#F2F1EE` | `#17191D` | 平板侧边导航轨、检查器底面、筛选面板底 |
| `surfaceContainer` | `#EDEDE9` | `#1E2025` | 浮起卡片、分段列表组、骨架占位框、次要芯片 |
| `surfaceContainerHigh` | `#E6E5E0` | `#24272C` | 底部 `HorizontalFloatingToolbar`、Popover、次级按钮悬停/按压态 |
| `surfaceContainerHighest` | `#DFDED8` | `#2C3037` | 强调胶囊、滑动轨道底槽、选中未激活芯片 |
| `primary` | `#2A60E0` | `#5B8DEF` | 工作室钴蓝主强调色（选中环、主操作、焦点指示） |
| `onPrimary` | `#FFFFFF` | `#0A1A3A` | 主按钮文字与图标 |
| `primaryContainer` | `#DDE7FF` | `#1E3566` | 激活导航胶囊、主 FAB 容器、激活连接按钮 |
| `onPrimaryContainer` | `#102B6E` | `#DCE7FF` | 激活态容器内文字与图标 |
| `secondary` | `#4E5D78` | `#9FB0CC` | 低饱和石板蓝辅助强调（绝不偏紫） |
| `secondaryContainer` | `#E4E8F0` | `#272D38` | 次级激活胶囊、筛选已选标签 |
| `onSecondaryContainer` | `#1D2638` | `#DCE3F0` | 次级激活胶囊文字 |
| `tertiary` | `#4E7D96` | `#84B6D0` | 第三强调色（海岩青，用于色板筛选/特殊徽章） |
| `onSurface` | `#18191C` | `#F2F3F5` | 主文字（对比度 ≥ 12:1） |
| `onSurfaceVariant` | `#5C6069` | `#A1A6B0` | 次文字、图标默认色、元数据键名（对比度 ≥ 4.5:1） |
| `outline` | `#8A8F99` | `#6E737D` | 弱文字、输入边框 |
| `outlineVariant` | `rgba(0,0,0,0.08)` | `rgba(255,255,255,0.09)` | `0.5dp` / `1dp` 细分隔线与卡片微描边 |
| `error` / `errorContainer` | `#D93B30` / `#FCE6E4` | `#F2584D` / `#4A1A17` | 危险操作、同步异常、删除确认 |

扩展语义色（通过 `CompositionLocalProvider(LocalCharkleExtendedColors)` 提供）：
- `positive`: Light `#249A4B` / Dark `#34C769`（已同步、离线就绪）
- `warning`: Light `#C98212` / Dark `#F2B23E`（未配置、待补齐、回退提示）
- `inkTertiary`: Light `#8A8F99` / Dark `#6E737D`（时间戳、快捷键、占位符）

### 2.2 Zone B：作品主色动态引擎（`ArtworkDynamicExpressiveTheme`）

用于 **单图沉浸预览（Quick Look）** 与 **收件箱逐张归档台**：

1. **Seed 选取优先级**：
   - 优先使用 `AssetRecord.dominantColors` 中首个有效高彩度非极暗/极白主色（避免纯黑/纯白导致退化）；
   - 若素材所有主色均极低饱和（如黑白素描、线稿），回退至 `PaletteStyle.Neutral` 优雅灰阶，绝不强行编造突兀彩色。
2. **动态方案构建**：
   - 使用 `MaterialKolor`（基于 Google `material-color-utilities` HCT 色域算法）生成 `DynamicMaterialExpressiveTheme(seedColor = seed, style = PaletteStyle.Fidelity, isDark = isDark, animate = !reduceMotion)`（采用忠实色相的 `Fidelity` 方案而非反差旋转色相的 `Expressive`，保证所有顶部返回键、连接按钮组、底部操作坞与收件箱浮栏均和谐统一在作品主色家族内）。
   - 切换相邻图片时，背景氛围色、顶部按钮组、底部操作坞颜色使用 `MotionScheme.expressive().defaultEffectsSpec()`（无回弹临界阻尼）在 `220ms` 内平滑插值，杜绝闪烁与生硬跳变。
3. **对比度与色准护栏**：
   - 所有控件严格使用生成的 `primaryContainer` / `onPrimaryContainer`、`secondaryContainer` / `onSecondaryContainer` 角色配对，自动保证 WCAG AA 以上可读性；
   - 图片本身放置于干净画布区域，顶/底控制栏采用无遮挡布局或极克制边缘渐变；点击顶栏「原色校对」图标可立即关闭作品染色，切入纯粹深黑/中性灰校色视图。

---

## 3. 空间网格、形状系统与 Expressive 形态语法

### 3.1 4dp 空间网格与边缘适配
- 全端严格执行 `4dp` 倍数网格（`4, 8, 12, 16, 20, 24, 32dp`），全屏强制 `enableEdgeToEdge()`，透明状态栏与手势导航栏，列表底部为悬浮底栏预留 `navigationBarsPadding() + 88dp` 安全呼吸区。
- 任意模态弹层与面板嵌套卡片层级 **≤ 2 层**。

### 3.2 圆角阶梯与 Expressive 形态对照

| 控件 / 容器 | 常规态形状 | 激活 / 按压态 Expressive 形变 | 说明 |
| :--- | :--- | :--- | :--- |
| 瀑布流素材卡片 | `RoundedCornerShape(12.dp)` | 多选选中内缩 `4dp` + `2.5dp` 钴蓝外环 | 保持画面利落边界，不裁剪过多边角 |
| 底部悬浮导航工具栏（`HorizontalFloatingToolbar`） | `CircleShape`（全胶囊，`64dp` 高） | 滚动自动平滑下沉离屏 | 左胶囊承载 `素材库 / 收件箱 / 情绪板` |
| 伴生主 FAB / 搜索钮 | `CircleShape`（`56dp`） | 展开菜单或切入选中态时形变为 `RoundedCornerShape(16.dp)` 方圆块 | 与左侧导航胶囊成双岛编排，对应 iOS 双胶囊 |
| 连接按钮组（`ButtonGroup`） | 外端全胶囊、内侧相邻角 `6dp`，项间 `2dp` 缝隙 | 按压时内角平滑弹性增大、点击选中项切为 `CircleShape` / 高对比 `primaryContainer` | 用于单图顶栏操作组、底部控制组、画廊筛选与视图切换 |
| 分段圆角列表卡片（设置 / 目录 / 检查器） | 首项 `top=20dp, bottom=4dp`；中间项 `4dp`；末项 `top=4dp, bottom=20dp`；单项 `20dp`；项间 `2dp` | 列表点击涟漪贴合各自圆角 | 取代传统横线分割列表，兼顾密度与高级质感 |
| 底部检查器 / 采集 / 筛选 `ModalBottomSheet` | 顶部 `RoundedCornerShape(topStart = 28.dp, topEnd = 28.dp)` | 拖拽手柄居中 `32×4dp` 胶囊 | 半高 / 全高双段吸附 |
| 进度与加载器 | `LoadingIndicator`（`MaterialShapes` 多边形有机形变）<br>`LinearWavyProgressIndicator`（波浪进度） | 同步进度、音频波形进度、长任务上传均采用波浪条 | 遵循 `< 300ms` 延迟显现防闪烁规则 |

---

## 4. 字体层级与中英文排版

- **字体族**：拉丁字母与数字优先内置 **Roboto Flex** 可变字体（支持 `wght` / `wdth` / `opsz` 表现力轴），中文回退系统无衬线黑体（`Noto Sans CJK` / 厂商系统黑体）；HEX 色值、像素尺寸、EXIF 参数与时间码使用 `JetBrains Mono` / `FontFamily.Monospace` + `fontFeatureSettings = "tnum"`（等宽数字防抖动）。
- **字阶规范**：

| 角色 | M3 Typography Slot | 字号 / 行高 / 字重 | 场景 |
| :--- | :--- | :--- | :--- |
| 展台大标题 / 大计数 | `displaySmall` | `32sp / 38sp / 700`（紧凑字距 `-0.5sp`） | 收件箱待整理大数字、情绪板列表页头、引导页主标题 |
| 页面顶栏标题 | `headlineSmall` | `22sp / 28sp / 600` | 当前目录/文件夹名、搜索结果页头 |
| 卡片 / 面板标题 | `titleMedium` | `16sp / 22sp / 600` | BottomSheet 标题、检查器信息块头、情绪板卡片标题 |
| 正文 / 列表主行 | `bodyMedium` | `14sp / 20sp / 500–400` | 设置行、文件夹树项、便签正文 |
| 元数据 / 标签 / 角标 | `labelMedium` | `12sp / 16sp / 500`（`tnum`） | 分辨率、EXIF 键名、筛选芯片、底栏标签 |
| 分组眉标 | `labelSmall` | `11sp / 15sp / 600` | 设置分段头、检查器分区标签 |

---

## 5. 动效物理体系与性能红线

统一通过 `MaterialExpressiveTheme(motionScheme = MotionScheme.expressive())` 注入官方双通道弹簧规范：

1. **Spatial Springs（空间位移 / 尺寸 / 形状形变 — 允许轻微自然回弹）**：
   - `fastSpatialSpec()`：连接按钮组圆角形变、复选框/标星确认、多选浮条弹入。
   - `defaultSpatialSpec()`：底部 Floating Toolbar 展开/收起、底部搜索栏拉伸形变、`SharedTransitionLayout` 瀑布流 ⇄ 单图全屏缩放转场。
   - `slowSpatialSpec()`：大画幅折叠屏展开切换、收件箱卡片飞出与下一张接替。
2. **Effects Springs（色彩 / 透明度 — 零回弹、临界阻尼）**：
   - `fastEffectsSpec()`：按压态透明度、单图全屏隐藏/显示控件、悬浮角标显隐。
   - `defaultEffectsSpec()`：单图预览 / 收件箱切换素材时的**作品主色 `ColorScheme` 过渡**、暗色/亮色主题切换。
3. **性能与交互红线**：
   - 瀑布流（`LazyVerticalStaggeredGrid` / 确定性虚拟化坐标容器）**实时滚动中零额外卡片动画**，保证 120Hz 满帧；
   - 双指捏合缩放瀑布流列数（手机 `1..5` 列 / 平板 `2..7` 列）必须**锚定手指下方具体卡片**并同步补偿 `scrollOffset`，绝不闪白或跳回顶部；
   - 全面支持 Android 原生 **Predictive Back**：从单图预览侧滑返回画廊时，预览图随手指实时缩放回原始瀑布流卡位。

---

## 6. 导航外壳与多形态自适应（手机 · 折叠屏 · 平板）

### 6.1 紧凑屏幕（手机竖屏，`Compact < 600dp`）
对应 iOS 端的双胶囊底栏，采用正宗 **M3 Expressive 悬浮双岛底栏**：

```text
┌────────────────────────────────────────────────┐
│  全部素材   ▾              [筛选(2)] [选择] [+] │  <- 透明大标题，滚动吸顶微缩
│                                                │
│   ┌──────────┐  ┌──────────┐  ┌──────────┐     │
│   │          │  │          │  │          │     │
│   │   作品   │  │   作品   │  │   作品   │     │  <- 纯图高密度瀑布流
│   │          │  │          │  │          │     │     （绝对中性底色 #F6F6F5 / #141517）
│   └──────────┘  │          │  └──────────┘     │
│   ┌──────────┐  └──────────┘  ┌──────────┐     │
│   │   作品   │  ┌──────────┐  │   作品   │     │
│   └──────────┘  │   作品   │  └──────────┘     │
│                                                │
│   ╭─────────────────────────╮   ╭───────╮      │
│   │ [素材库]  [收件箱]  [情绪板] │   │  🔍   │      │  <- HorizontalFloatingToolbar
│   ╰─────────────────────────╯   ╰───────╯      │     + 伴生搜索/采集形变 FAB
└────────────────────────────────────────────────┘
```

- **左侧 `HorizontalFloatingToolbar`**：`素材库` / `收件箱`（带未整理计数角标）/ `情绪板`；再次点击已激活的 `素材库` 或向上轻滑底栏，直接拉起**「目录与筛选」分段圆角抽屉**（快速范围磁贴、折叠文件夹树、智能文件夹、标签云、底栏同步状态与设置入口）。
- **右侧伴生形变 FAB**：
  - 点击 `🔍` 平滑形变为底部可单手触及的 **Expressive Search Bar**，内置 4 模切换芯片（`全部素材` / `主色调` / `当前目录` / `Pinterest 空间`）+ 同步设置快捷入口；
  - 长按 `🔍` 或点顶栏 `+` 呼出多源采集面板（相册多选 / 相机 / 文件 / 剪贴板 / 链接与社媒解析）。
- **多选态**：进入多选后，导航底栏平滑替换为 **Connected Batch Action Bar**（`移入文件夹 | 标星 | 加标签 | 分享 | 删除`），支持连续横向/斜向滑动批量框选。

### 6.2 中/宽屏（折叠屏展开态 & Android 平板，`Medium / Expanded ≥ 600dp`）
使用 `androidx.compose.material3.adaptive`（`NavigationSuiteScaffold` + `SupportingPaneScaffold`）：
- **左侧常驻导航轨 / 侧栏**（`80dp` 窄轨或 `280dp` 展开树，与 iPad `SidebarNavigationView` 1:1 对应）；
- **中间主画布**（`2..7` 列瀑布流、情绪板画布或 Pinterest 无限空间）；
- **右侧按需停靠检查器（`320dp`）**：支持与单图预览同步显隐及 `信息 | 相似素材` 标签态，支持物理键盘快捷键（`Ctrl+N` 采集、`Ctrl+F` 搜图、`Ctrl+J` 随处跳转、`Space` 全屏预览）。

---

## 7. 图标体系与微型界面空状态

- **双色功能图标**：直接复用根目录 `Resources/` 下的 48 枚 Charkle 双色 SVG 图标并批量转换为 Android `VectorDrawable`（保留主色/辅色双通道，随 Light/Dark 及选中态动态着色），与 M3 系统图标（`Material Symbols Rounded`）和谐混排。
- **微型界面空状态**：严格继承 `DESIGN.md §5.2`，在空素材库、收件箱清零、无筛选结果、空文件夹、空情绪板 5 个场景使用 `Compose Canvas` / 矢量缩影绘制微型产品界面示意图（Light/Dark 自适应、至多 1 处强调色），禁止使用抽象插画或 Emoji 堆砌。

---

## 8. Android 端交付门禁

每次视觉或核心页面提交必须通过以下 6 项验收：
1. **双区色彩审计**：主画廊 / 情绪板在 Light (`#F6F6F5`) 与 Dark (`#141517`) 下保持绝对中性；单图预览 / 收件箱随不同色相作品平滑变色，且「原色校对模式」一键生效、零紫罗兰误染。
2. **动态对比度与大字号**：在系统字体缩放 `1.3×` 与暗色模式下，所有 Connected Button、Floating Toolbar、分段列表卡片与作品染色态按钮均无截断重叠且满足 AA 对比度。
3. **流畅度与零闪烁**：1,500+ 项瀑布流滚动与双指锚定缩放稳定流畅；切图进入检查器时 EXIF / AI Prompt / 色板零闪现旧图。
4. **边缘到边缘与手势**：透明状态栏/导航栏无内容遮挡；支持原生 Predictive Back 共享元素缩放返回；折叠屏横竖屏旋转不丢失状态与滚动位置。
5. **无障碍降级**：系统关闭动画时自动移除弹簧回弹与位移动画，仅保留状态切换与轻柔淡入淡出。
6. **文案与仓库纯净度**：零工程黑话、零外部竞品/参考产品或作者名称、零个人路径或密钥泄露。
