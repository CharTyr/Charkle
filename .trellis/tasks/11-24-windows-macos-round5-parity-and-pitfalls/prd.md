# Windows 开发交接文档：近期新特性、交互打磨与实测踩坑汇总（macOS `1a5224e..e8593f2`）

> 本文档整理自 macOS 主线在 `11-23-windows-client` 原始规划之后完成的全部迭代（涵盖提交 `1a5224e` → `884bc63` → `590b5a1` → `ce72927` → `3cb9375` → `fced1d5` → `5a8fca6` → `7edc080` → `e8593f2`），按 **Windows 端（Tauri v2 + Pure Rust Core + React/WebView2）** 的里程碑与工程边界归类，并重点沉淀我们在真实使用与调试中踩过的 12 个隐蔽坑，避免 Windows 侧重复返工。
>
> 权威视觉/动效/跨端契约仍以根目录 [`DESIGN.md`](../../../DESIGN.md) 与 [`.trellis/spec/cross-platform/index.md`](../../spec/cross-platform/index.md) 为准。

---

## 1. 增量功能清单与 Windows M1–M5 归属映射

| 模块 | 新增 / 升级能力 | 对应 Windows 里程碑 | macOS 参考实现 |
| :--- | :--- | :--- | :--- |
| **通用全网址解析 + 默认浏览器直达** | 支持任意 `http`/`https`/`www.` 与短分享文案 URL 采集；三层缩略图策略（OG/Twitter/JSON-LD → 离屏 WebView 截图 → 排版兜底书签卡）；普通网页点开直接调默认浏览器，GitHub/推文保持应用内富预览 | **M1（Rust 解析/缩略图） + M2（UI 打开/刷新） + M3（剪贴板/悬浮窗提示）** | `Sources/CharkleCore/Media/WebBookmark.swift`, `MediaArtwork.swift`, `LiveCharkleEngine.swift`, `ClipboardCollector.swift`, `MainWindowView.swift` |
| **画廊第 4 视图「环形画廊」（Outside 3D）** | 外部平视 22 卡 3D 弧形环，直接展示素材库图片（无 Inside、无流体渐变、无翻面），逐像素景深模糊 + Mipmap LOD + 远侧淡出，右下角折叠参数面板实时调参 | **M2（Gallery 第 4 视图，WebView2 可用 WebGL2 / Three.js Shader）** | `Sources/CharkleCanvas/RingGalleryMath.swift`, `RingGalleryMetalView.swift`, `GalleryRingView.swift`, `duotone-gallery-ring.svg` |
| **无缝全出血顶栏与三栏统一** | 透明无割裂顶栏，三栏纵向分割线直抵窗口顶部 `y = 0`，`Ctrl+J` 与侧边栏折叠融入顶部标题行，收起态图标轨加宽至 `76px` 避让窗口控制区 | **M2（Win11 Mica / `WM_NCHITTEST` 自定义顶栏）** | `Sources/CharkleApp/DesignSystem/CharkleTheme.swift`, `MainWindowView.swift`, `SidebarView.swift`, `InspectorView.swift` |
| **情绪板底部三档响应式工具栏 + 根容器防裁切** | 彻底消除画布固定视口尺寸反向撑爆根布局导致的底部裁切；底部工具栏与缩放胶囊统一为 `wide / medium / compact` 三档自适应布局 | **M4（Moodboard Studio）** | `Sources/CharkleCanvas/MoodboardCanvasView.swift`, `MainWindowView.swift` |
| **极简低占用后台悬浮窗模式（Minimal Mode）** | 销毁主窗口 WebView 释放内存与解码缓冲、仅留系统托盘 + 顶部悬浮窗，空闲 CPU `< 1%`；**极简模式下依然保留「最近素材」横条**方便随取随拖 | **M3（Top-Edge Drop Shelf + Tray）** | `Sources/CharkleApp/CharkleAppEntry.swift`, `NotchShelfView.swift`, `NotchShelfController.swift`, `ThumbnailImageLoader.swift` |
| **可靠空格键 Quick Look + 300px 同源侧边检查器** | 窗口级统一空格键开关（屏蔽 CapsLock/NumPad/Fn），Quick Look 复用完整 300px 可编辑 `Inspector` 且显隐与 `信息/相似` Tab 与主窗 1:1 双向同步 | **M2（Quick Look & Inspector）** | `Sources/CharkleApp/Views/MainWindowView.swift`, `QuickLookOverlayView.swift`, `InspectorView.swift`, `CanvasSupport.swift` |
| **精确卡片锚定缩放 + 情绪板反定位素材库** | 连续缩放锁定同一张锚定卡片（光标卡片 > 可见选中卡片 > 视口中心），Row-2+ 在 `scrollY=0` 亦可平稳钉住；情绪板右键「在素材库中定位」自动展开父文件夹、清筛、居中脉冲高亮并附「返回情绪板」Toast | **M2 + M4** | `Sources/CharkleCanvas/VirtualizedMasonryView.swift`, `MainWindowView.swift`, `MoodboardCanvasView.swift` |
| **交互细节打磨套件** | 全行可点击折叠头、带「撤销」CTA 的移入废纸篓 Toast、二次确认 Popconfirm、微型视觉空状态、延迟防闪骨架屏、窄窗口顶栏渐进折叠、官方单色/双色托盘图标 | **M2 + M3 + M5** | `CharkleDisclosureGroup.swift`, `CharklePopconfirm.swift`, `CharkleLoadingKit.swift`, `CharkleEmptyStateVignette.swift`, `CharkleMenuBarIcon.swift`, `MainWindowView.swift` |
| **MCP v2（20 工具）与 CLI v2** | 由原规划的 14 工具升级为 **20 安全工具 + 4 静态/2 动态资源 + 4 Prompts**，支持 JSON-RPC Batch、分片安全的 `Content-Length` 帧解析、分页、EXIF/AI 提示词注水、情绪板无重叠补丁 | **M5（`charkle-cli.exe` + MCP）** | `Sources/CharkleCore/Intelligence/CharkleExternalAgentSchema.swift`, `CharkleExternalAgentService.swift`, `MCPStdioFrameParser.swift`（另见任务 `11-23-web-windows-mcp-cli-v2-parity`） |

---

## 2. 重点新功能规格细节（供 Windows 直接按契约实现）

### 2.1 全网址解析收藏与默认浏览器直达

1. **URL 提取与清洗（`WebURLParser`）**
   - 支持大小写协议（`HTTPS://...`）、Unicode/中文路径自动编码、独立 `www.<host>` 补全为 `https://`。
   - 迭代剥离外层成对包裹符（`<>`、`""`、`''`、`()`、`[]`、`「」`、`《》`、`“”`）及末尾中英文标点（`.,;!?。，；！？、` 等），**但必须统计括号配平**，保留维基百科类链接如 `https://en.wikipedia.org/wiki/Swift_(programming_language)` 的闭合右括号。
   - **短分享文案 vs 长正文区分**：当剪贴板/拖放纯文本为 `<= 320` 字符且 `<= 5` 行时，允许从文案中提取首个明确以 `http://`、`https://` 或 `www.` 开头的链接（兼容 B 站/小红书/浏览器分享复制）；超过该长度或无显式前缀（如 `README.md`、`photo.png`）的文本继续保存为 `.textSnippet`，绝不误伤用户长笔记。
   - 必须拒绝非 `http`/`https` 协议及带 `user:pass@` 凭据的 URL。
   - 覆盖全入口：全局剪贴板采集（`Alt+Shift+V`）、主窗画廊 `Ctrl+V`（含瀑布流、胶片、环形画廊）、顶部悬浮窗拖放与剪贴板提示条（区分推文 / GitHub / 普通网页并显示域名）、画廊/情绪板/侧边栏拖放。

2. **三层缩略图管线（单次抓取，零重复请求）**
   - **Tier 1（Rust `reqwest` 快速抓取）**：
     - 携带常规桌面浏览器 `User-Agent`、`Accept`、`Accept-Language`；下载图片候选时附带 `Referer: <page_url>` 以通过防盗链 CDN。
     - 若响应 `Content-Type: image/*`，直接将图片解码为缩略图（上限 8MB）。
     - HTML 解码须支持 `Content-Type` header 与 `<meta charset>` 检测（UTF-8 / GB18030 / GBK / Big5 / Shift_JIS / EUC-JP / ISO-8859-1），避免中文站乱码。
     - 标题优先级：`og:title` → `twitter:title` → `<title>` → `<h1>` → URL 路径与域名兜底；过滤反爬/中转占位标题（如 `Just a moment...`、`Attention Required!`、`Access Denied`、`403 Forbidden`、`Checking your browser`、`Loading...`）。
     - 封面图候选优先级：`og:image:secure_url` → `og:image` → `og:image:url` → `twitter:image` → `twitter:image:src` → `<link rel="image_src">` → JSON-LD `"image"`；解析相对路径与 `//cdn...`，要求尺寸 `>= 160×100` 且排除极端长条跟踪像素（宽高比 `> 6.5` 或 `< 0.15`）。
   - **Tier 2（无封面或 SPA 页面的离屏 WebView 截图兜底）**：
     - 仅在 Tier 1 未获得可用封面且非网络不可达（DNS 失败 / 连接拒绝直接跳过，离线秒存）时触发。
     - Windows 侧可复用独立隐藏/离屏 **WebView2**（无痕/独立临时 profile、禁用媒体自动播放、`1280×800` 视口、`6.5s` 硬超时、加载完成后短暂等待 `~400ms` 渲染字体并抓取 `CapturePreview` + `document.title` / `meta description`）；检测到纯白/纯黑空白画布时主动丢弃转入 Tier 3；完成后立即销毁实例，绝不残留后台 WebView2 进程。
   - **Tier 3（排版书签兜底卡）**：
     - 生成 `1200×750` 简洁浅色纸面书签卡：顶部主题色条（取 `meta[name=theme-color]`，过滤过白/过黑后回退域名哈希色板）、真实网站 `apple-touch-icon`/`favicon` 或首字母徽标、站点名与域名、`WEB` 徽标、最多 3 行大标题、3 行摘要、底部规范 URL 与 `↗ 默认浏览器打开` 提示。
   - **存储与刷新**：
     - 原文件仍存轻量 `.webloc`（或 `.url`，注意保持 `mediaKind = .webBookmark` 与跨端一致），写入 `720px` 高清网格缩略图 + `1400px` 预览图，并提取主色板（支持按颜色搜网页）。
     - **核心原则：永远保留用户原始粘贴的 URL 作为 `sourceURL`**，不要被无 Cookie 抓取时的 `/login` 重定向覆盖，确保点开时在用户已登录的默认浏览器直达原页面。
     - 检查器「来源」区提供「默认浏览器打开」+「刷新缩略图」按钮（对应 `refreshRichAsset`）。

3. **点开直达默认浏览器（`isExternalWebLink`）**
   - 判定条件：`mediaKind == .webBookmark && !isGitHubRepo && !isSocialPost && externalWebURL != nil`。
   - **GitHub 仓库**与 **X / Threads / Bluesky 推文**继续使用应用内富卡片阅读器（README / 媒体轮播 / 媒体提取）。
   - **其他所有网页书签**：
     - 单击仍为选中（可编辑标题/标签/评分/拖拽/入情绪板/删除）；
     - 画廊双击、环形画廊双击/按钮、空格键、`Ctrl+J` 跳转、情绪板节点双击/打开、顶部悬浮窗最近素材打开、右侧检查器缩略图点击，一律直接调用系统默认浏览器打开（Windows 使用 `tauri-plugin-opener` / `ShellExecuteW`），记录 `lastOpenedAt` 并弹轻提示 `"已在默认浏览器中打开 <domain>"`，**不弹出 Quick Look 遮罩**；
     - 右键菜单首项与按钮文案自动切换为「在默认浏览器中打开 (Space)」；
     - 胶片视图选中浏览时仅在主舞台展示大缩略图 +「在默认浏览器中打开」按钮（点击舞台或按空格打开，避免左右方向键浏览时连开十几个浏览器标签页）。

### 2.2 画廊第 4 视图「环形画廊」（Outside 3D）

- **已确认产品范围**：仅实现 **Outside 外部平视视角**（`bend = -1`），**不需要** Inside 玻璃折射视图、流体渐变背景或正反面翻转；卡片直接显示素材库图片（Aspect-Fill Cover UV，无拉伸）。
- **核心几何与渲染参数（默认值 + 视口铺满 + 横图不裁切）**：
  - 基准圆环周长 `C = 22 * 198 = 4356`，半径 `R = C / (2π) ≈ 693.28`，统一卡片高度 `cardHeight = 300`，间距 `gap = 18`，圆角超椭圆指数 `4`（`cornerRadius = 32px`）。
  - **沿用横向瀑布流不等宽排布（横图零裁切）**：每张卡片固定高度 `300`，宽度按真实宽高比动态计算 `cardWidth = round(cardHeight * clamp(aspect, 0.52, 2.25))`（竖图 `180`、方图 `300`、4:3 `400`、16:9 `533`），通过前缀和弧长轨道（`RingCardTrack`）保证任意相邻卡片沿弧间距恒为 `18`，支持 `O(log N)` 最近卡吸附、无限虚拟循环与背面接缝平滑淡出。
  - **双向自适应铺满窗口**：依据精确外部投影半宽 `halfW_1x = R·P / √(P² + 2PR)` 计算动态缩放系数 `cardScale = clamp(min(targetHalfW / halfW_1x, usableH * 0.78 / cardHeight), 0.34, 2.8)`，横向自动铺满约 `94%` 视口宽度并随窗口缩放实时重绘；拖拽位移、惯性速度与滚轮增量同步除以 `cardScale` 保持 1:1 跟手；中央景深清晰区宽度 `sharpHalf = min(halfW * 0.78, max(110, frontCardW * 0.54) * cardScale)` 随当前居中卡片宽度平滑插值，确保横图整幅锐利不糊边。
  - 透视距离 `perspective = 1500px`（可调 `900–2400`），景深模糊 `depthBlur = 14px`（可调 `0–30`），远侧淡出 `farFade = 50%`（可调 `0–100%`），圆角 `cornerRadius = 32px`（可调 `0–60`）。
  - 曲率放置：`c = -1 / R`，`a = s * c`，`x = sin(a) / c`，`z = (1 - cos(a)) / c`；透视投影 `x * P / (P - z) * cardScale`，近裁剪 `P - z < 140` 跳过。
  - 逐像素解析景深模糊（盒式边缘覆盖 alpha + 纹理 Mipmap LOD 采样，避免 CSS `backdrop-filter` 在运动时的闪烁）+ 远侧向浅/深背景色（`#F6F6F5` / `#141517`）平滑淡出；无投影、无反光、无背光发灰。
- **交互与调参面板**：
  - 1:1 拖拽跟随 + 惯性滑行（`target = offset - velocity * 260ms`，吸附最近卡片，时长 `clamp(|dist| * 1.6, 420, 1100)ms`，`cubic-bezier(0.25, 0.6, 0.2, 1)`）；
  - 按压卡片缩至 `0.95`（140ms 进 / 320ms 出），单击侧卡居中（`760ms`），双击打开（图片进 Quick Look、普通网页直达默认浏览器），支持滚轮、左右方向键与右键菜单；
  - `prefers-reduced-motion` 下动效上限 `<= 200ms`；
  - 调参面板默认折叠，点击右下角滑块按钮展开 4 项滑块 + 一键「重置默认」，`Esc` 可关闭。
- **Windows 实现建议**：在 WebView2 中用轻量 **WebGL2**（或 Three.js `ShaderMaterial` + 96 列弯曲条带顶点 + 片元超椭圆 SDF / DoF Shader，直接对照 `Sources/CharkleCanvas/RingGalleryMath.swift` 与 `RingGalleryMetalView.swift` 的 MSL 移植为 GLSL），纹理池设 LRU 上限（约 48 张，开启 `generateMipmap`），并做**按需渲染**（静止时停止 `requestAnimationFrame`，空闲 GPU/CPU 归零）。

---

## 3. 12 条实测踩坑与防复发清单（强烈建议编码前通读）

### 坑 1：情绪板固定视口尺寸反向撑爆根布局，导致整个 App 底部被裁切
- **现象**：打开情绪板后，不仅情绪板底部工具栏和缩放胶囊被截掉一半，连左侧边栏和右侧检查器的底部也一起被顶出窗口；窗口先拉大再缩小时裁切更严重，无法自适应恢复。
- **根因**：画布内层点阵背景和世界坐标系容器直接绑定了固定宽高 `viewportSize`（初始 `1080×760`），作为普通子元素放进布局容器后，容器被撑到 `max(实际窗口尺寸, viewportSize)`，既拒绝缩小又让测量回调用的是撑爆后的尺寸，形成“只涨不缩”死锁，把外层三栏根 `HStack` 一并拉高超出窗口。
- **Windows 端正确做法**：
  - 三栏根容器（Sidebar / Center / Inspector）全部加 `min-h-0 min-w-0 h-full overflow-hidden`；
  - 情绪板外层用纯弹性占位容器（`relative flex-1 min-w-0 min-h-0 overflow-hidden`）挂 `ResizeObserver` 测量真实视口；
  - 画布点阵、节点层、矢量层全部放在 `position: absolute; inset: 0` 内部，绝不参与外层容器的固有尺寸撑开，确保窗口任意放大/缩小都能即时 1:1 双向收敛。

### 坑 2：情绪板底部工具栏与右下角缩放胶囊在窄/中屏碰撞重叠
- **现象**：底部工具栏居中、缩放胶囊靠右下分别独立叠放；一旦开启侧边栏 + 右侧检查器，中间画布宽度缩至 `~650px`，两者立即重叠，开启画笔/连线扩展项后还会直接溢出裁切。
- **Windows 端正确做法**：
  - 合并为一个统一底部 HUD，按画布实时宽度 `viewportWidth` 分三档响应（与 `MoodboardDockLayoutTier` 一致）：
    - **宽屏（`>= 820px`）**：工具栏光学居中 + 右侧缩放胶囊；仅在 `>= 960px` 时把画笔/连线选项内联进主栏，否则自动上浮为独立子胶囊避免撑宽；
    - **中屏（`560–819px`）**：单行 `flex` 自动分配左右间距（`< 700px` 隐藏「导出」文字仅留图标，`< 680px` 收缩按钮尺寸），零重叠；
    - **窄屏（`< 560px`）**：缩放胶囊自动叠放到工具栏右上方一排，`< 430px` 时工具栏容器启用横向无滚动条滑动兜底；
  - 顶部右侧「候选替换池 / 收起候选栏」按钮在 `< 520px` 时收缩为纯图标，且顶部「板内色卡」在 `< 680px` 时增加右侧留白避让。

### 坑 3：窄窗口顶部工具栏与悬浮窗「活跃情绪板」按钮互相挤压变形
- **现象**：窗口缩窄时，画廊顶栏右侧按钮被挤出裁切；悬浮窗点击「活跃情绪板」后右侧选择器撑宽，导致左侧「区域截图 / 剪贴板 / 主窗」按钮文字换行挤压变形。
- **Windows 端正确做法**：
  - 操作按钮统一 `shrink-0 whitespace-nowrap`（SwiftUI 为 `.fixedSize(horizontal: true, vertical: false)`），动态情绪板名称胶囊设置 `min-w-0 max-w-[160px] truncate`；
  - 画廊顶栏按容器实时宽度渐进折叠（完整态 → 隐藏文字标签仅留图标 → 隐藏密度滑块与次要操作进「更多」菜单），保证任何允许的最小窗口宽度下按钮均不变形、不裁切。

### 坑 4：空格键 Quick Look 无法退出或与输入法/画布热键冲突
- **现象**：开启大小写锁定（含中文输入法切换状态）时空格键失灵；或者在主窗按空格打开 Quick Look 后，再按空格无法退出（或焦点留在搜索框导致输入空格）。
- **根因**：
  1. 用全量修饰键掩码判空会误把 `CapsLock` / `NumLock` / `Fn` 当成组合键；
  2. 局部监听器与可选链回调写法若误把“已消费事件 (`null`/`preventDefault`)”回退成未消费，会导致下层监听再次打开 Quick Look；
  3. 打开 Quick Look 时未主动 `blur()` 搜索框焦点，且未在 `isOverlayPresented` 时挂起下层情绪板 Space-Pan / 环形画廊键盘监听。
- **Windows 端正确做法**：
  - 仅检查 `!e.ctrlKey && !e.altKey && !e.metaKey && !e.shiftKey`（绝不检查 `CapsLock` / `NumLock`）；
  - 在应用顶层统一用 capture 阶段 `keydown` 协调器托管 `Space`：Quick Look 打开时按空格直接关闭（仅在 Quick Look 内右侧检查器文本输入聚焦或模态弹窗打开时放行），关闭时则打开当前选中项（普通网页直达默认浏览器）；
  - 打开 Quick Look 瞬间主动 `document.activeElement?.blur()`，并通过 `isOverlayPresented` 彻底暂停下层情绪板画布和 3D 环形画廊的键盘与滚轮监听。

### 坑 5：顶部悬浮窗（Top-Edge Shelf）未勾选固定却卡死不自动收回
- **现象**：鼠标滑出或处理完拖放提示横幅后，顶部悬浮窗停在屏幕上不再自动收起。
- **根因**：自动收起定时器被新的状态切换（如横幅展示、拖拽进入、取消固定）打断时，只做了 `clearTimeout` 但未把保存的 timer 句柄置空，或覆盖了旧句柄未先取消，导致后续判断 `if (!hideTimer)` 误以为已有定时器在跑，永久不再调度收起。
- **Windows 端正确做法**：
  - 封装唯一原子方法 `cancelAutoCollapse()`（同时 `clearTimeout(hideTimer); hideTimer = null`），在所有状态切换点（悬停进入、拖入、横幅展示、固定、手动收起、窗口失焦）统一调用；
  - 每次横幅结束或鼠标离开热区且 `!isPinned && !isDragging && !processingMessage` 时，先清旧再建新。

### 坑 6：极简低占用后台模式（Minimal Shelf Mode）的内存释放与最近素材留存
- **现象**：用户只开悬浮窗随时收图时，希望内存和 CPU 接近零占用，但之前隐藏主窗后极简模式顺带隐藏了「最近素材」，导致无法快速把刚收的图拖给其他软件。
- **Windows 端正确做法**：
  - 进入极简模式时，真正销毁主窗口 WebView2（而非仅 `hide()` 留着全套画廊 DOM 与 GPU 图层），同时主动清理前端缩略图 ObjectURL / 解码缓存，仅保留轻量最近素材列表（16 条小尺寸 `grid520` 缩略图）供顶部悬浮窗单行横条快速预览与 OLE `CF_HDROP` 拖出；
  - 悬浮窗收起态暂停一切轮询定时器与动效，确保空闲 CPU `< 1%`。

### 坑 7：通用网址解析的真实世界边界坑
- **登录重定向覆盖原链接**：无 Cookie 抓取 Notion / Linear / Figma / 知乎 / 小红书时常被 302 跳转到 `/login`；**绝不能用重定向后的登录页 URL 覆写 `asset.sourceURL`**，必须保留原始收藏 URL。
- **中转页标题污染**：屏蔽 Cloudflare / 防爬占位标题（`Just a moment...`、`403 Forbidden` 等），退回可读的 `路径尾段 — 域名`。
- **CJK 编码乱码与防盗链封面 403**：必须解析 `<meta charset>` 与 HTTP `Content-Type` 的 `gbk`/`gb18030`/`big5`/`shift_jis`，下载封面图务必带 `Referer` + 常规桌面浏览器 UA。
- **括号与尾标点顺序**：先迭代剥离成对包裹符再剥离尾标点并循环收敛，同时计入圆括号配平，防止 `<https://.../Swift_(lang)>。` 残留左尖括号 `<` 或误删 URL 末尾有效 `)`。
- **离线/局域网不可达卡死**：连接拒绝或 DNS 失败时立刻短路跳过离屏 WebView 截图，毫秒级落盘排版兜底卡。

### 坑 8：普通网页书签缩略图强行写死 `1.25` 纵横比导致封面文字被裁
- **现象**：绝大多数网页 OG 图是 `1200×630`（`1.90`）或 `1280×800`（`1.60`），瀑布流若对 `.webBookmark` 写死 `1.25`，会把标题左右切掉；胶片视图若因已有 `grid520` 缓存就跳过加载 `preview1400`，网页截图文字会发糊。
- **Windows 端正确做法**：瀑布流纵横比优先使用真实 `pixelWidth / pixelHeight`（仅缺失时回退 `1.6`），胶片视图与检查器正常升级加载 `preview1400`。

### 坑 9：画廊缩放（Photos-style）画面漂移与首帧跳变
- **要点**：连续缩放（触控板捏合 / `Ctrl+滚轮` / 密度滑块 / `−` `+`）必须锁定单一持久化精确锚定卡片 `sessionZoomAnchor`（优先级：光标下卡片 > 视口内已选卡片 > 视口中心卡片），仅在用户手动滚动或切换选中后释放；先按新布局计算并施加锚定 `scrollTop`，再提交卡片重排，且第 2 行及以下卡片即使从 `scrollTop === 0` 放大也要自动滚动保持屏幕 Y 不漂移，第 1 行贴紧浮动顶栏下方。

### 坑 10：可折叠区域仅小三角可点 & 无损撤销体验
- 侧边栏、检查器、设置面板中所有可折叠区块**严禁**只把点击事件绑在左侧小箭头上，必须使用整行满宽 `<button>` + hover 高亮反馈；
- 移入废纸篓等高频操作提供带「撤销」按钮的交互 Toast；清空/永久删除/断开云端使用轻量化就地二次确认（Popconfirm），避免生硬系统弹窗。

### 坑 11：全出血顶栏与收起态侧边栏的视觉一致性
- Windows 11 下利用 `WM_NCHITTEST` 与 `data-tauri-drag-region` 实现透明全出血顶栏，让侧边栏与检查器竖向分割线直抵窗口顶边 `y = 0`（不出现顶栏下方一条额外灰白横条）；
- 侧边栏收起态宽度给到 `76px`（而非 `56px`），避免收起图标轨显得局促或与顶部操作区拥挤；画廊浮动顶栏与检查器顶部 Tab 胶囊统一顶部留白 `10px` 水平对齐。

### 坑 12：3D 环形画廊的渲染开销与自遮挡边界
- Outside 弧形环中，处于左右切线边界（`x ≈ ±R`）的卡片其近侧与远侧会跨越切线自折返，若开启半透明直接单次绘制会产生双倍 alpha 重叠伪影：需在顶点/网格按切线 `s = ±πR/2` 拆分为前后两段并按画家顺序从远到近绘制；
- 必须严格**按需渲染**：拖拽惯性结束、点击居中动画完毕后立即停止 `requestAnimationFrame`，静止时 GPU/CPU 消耗归零；
- 远离中心的淡出颜色必须与当前 Light (`#F6F6F5`) / Dark (`#141517`) 页面底色保持同色域（sRGB）精确一致，防止卡片边缘发灰或出现白边。

---

## 4. Windows 侧分项验收清单

1. **通用网址与默认浏览器直达**
   - [ ] 粘贴/拖入任意带 OG 图网站（如博客/新闻/Figma/B 站）、无 OG 图 SPA 网站、中文 GBK 网站、短分享文案以及离线链接，均能在画廊生成清晰缩略图（不覆盖原始 `sourceURL`）。
   - [ ] 在瀑布流、3D 环形画廊、胶片视图、情绪板、顶部悬浮窗最近素材与检查器中点开普通网页书签，均直接呼出系统默认浏览器；GitHub 与推文仍走应用内富卡片阅读器。
   - [ ] 检查器「刷新缩略图」可重新抓取并即时刷新画廊卡片。
2. **情绪板底部自适应与全 App 防裁切**
   - [ ] 在 `700px` 矮窗口及先放大到 `1080p` 再缩小到最小尺寸的过程中，打开情绪板时侧边栏底部、情绪板底部工具栏/缩放胶囊、右侧检查器底部均 100% 完整可见，绝不裁切。
   - [ ] 在画布宽度 `1200px`、`720px`、`520px`、`400px` 下切换选择/画笔/连线工具，底部工具栏与缩放胶囊无任何碰撞或文字挤压。
3. **画廊第 4 视图「环形画廊」**
   - [ ] 顶部视图切换器支持 4 种模式，切换至「环形画廊」呈现 Outside 22 卡 3D 弧形环，支持拖拽惯性、滚轮、方向键、点击居中、双击打开/直达浏览器、右键菜单与右下角折叠调参面板（4 滑块 + 重置默认）；静止时 GPU/CPU 占用趋近 `0%`。
4. **顶栏、极简后台悬浮窗与交互稳定性**
   - [ ] 顶栏无缝全出血、三栏分割线直通顶部；窄窗口顶栏与悬浮窗「活跃情绪板」按钮均无挤压变形。
   - [ ] 极简后台悬浮窗模式释放主窗内存且保留「最近素材」横条，未固定时移出必自动收回，空闲 CPU `< 1%`。
   - [ ] 大写锁定 / 中文输入法开启状态下，空格键可在所有画廊视图与 Quick Look 间稳定开关；Quick Look 右侧 300px 检查器显隐与 Tab 与主窗实时同步。
   - [ ] 遵循 [`.trellis/spec/cross-platform/index.md`](../../spec/cross-platform/index.md) 的仓库纯净度要求（零外部竞品/灵感来源/作者提及，零个人本机路径与密钥）。
