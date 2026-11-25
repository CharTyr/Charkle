# Windows 端同步开发文档（v1.2.2）：低消耗 CLI/MCP 智能检索升级与顶部悬浮托盘半路提前接引

> 本文档随 macOS **`v1.2.2`（Build 8）** 正式版同步签发，面向 Windows（Tauri v2 + Rust Core + React/TS）开发会话，完整沉淀本轮两大核心升级的精确协议、算法边界、目标文件映射、回归测试要求以及共享 `v1.2.2` GitHub Release 的无损合入流程。
>
> 跨端契约权威见 [`.trellis/spec/cross-platform/index.md`](../../spec/cross-platform/index.md) §3 与仓库共享 Agent Skill [`Resources/AgentSkill/charkle/SKILL.md`](../../../Resources/AgentSkill/charkle/SKILL.md)。Windows 侧严格遵守 [`windows/AGENTS.md`](../../../windows/AGENTS.md) 与 [`charkle-windows-ship`](../../../.agents/skills/charkle-windows-ship/SKILL.md)。

---

## 1. v1.2.2 变更总览与 Windows 文件精准映射

| 主题模块 | macOS v1.2.2 交付内容 | macOS 参考实现 | Windows 对应目标文件 |
| :--- | :--- | :--- | :--- |
| **1. CLI & MCP 极限省 Token 与响应压缩** | MCP 默认紧凑 JSON（无 2-space 缩进）；CLI 管道/重定向自动紧凑单行 JSON（TTY 才格式化）；`tools/list` Schema 瘦身至 `< 18 KB`；全链路 **8 位短 UUID 前缀**解析；新增 `detail: "visual"` 极简清单（随内联 Contact Sheet 自动启用）；`library_overview` 新增 `compact` 与目录语义图谱（`recursiveAssetCount` / `topTags` / `palette` / `dominantAspect`） | `CharkleExternalAgentSchema.swift`, `CharkleExternalAgentService.swift`, `LibraryDatabase.swift`, `CLIFormatter.swift`, `CharkleCLI.swift` | `windows/crates/charkle-core/src/agent/service.rs`, `windows/crates/charkle-core/src/database/`, `windows/crates/charkle-cli/src/main.rs` |
| **2. 双语视觉理解、7 维 CIELAB 色调与负向视觉排斥** | 新增 `VisualQueryIntelligence`：中英文视觉词簇扩展、自然语言色调/画幅/色值解析、7 维本地 CIELAB `VisualTone` 打分过滤（`dark`/`light`/`warm`/`cool`/`vivid`/`muted`/`high_contrast`）；CJK 词边界分词；`search_assets` 默认 `include_subfolders: true` + 自动 `facets`；`semantic_search` / `find_similar_assets` 支持 `seed_asset_ids`、`unlike_asset_ids`、`visual_rerank` 与 Round-Robin 视觉特征去重（`diversify`） | `VisualQueryIntelligence.swift`, `SearchText.swift`, `LiveCharkleEngine.swift`, `CharkleExternalAgentService.swift` | `windows/crates/charkle-core/src/intelligence/`（新增 `visual_query.rs`）, `windows/crates/charkle-core/src/agent/service.rs`, `windows/crates/charkle-cli/src/main.rs` |
| **3. 单次往返 Contact Sheet、多方向合图与批量精查** | `search_assets` / `semantic_search` / `list_inbox` / `find_similar_assets` 支持 `render_contact_sheet: true` + `sheet_max_width`（下限降至 `512`）；`semantic_search` & `render_contact_sheet` 支持 `queries[]`（2–6 方向合一张 Contact Sheet）；`get_asset` & CLI `charkle asset` 支持 `asset_ids[]` 批量查 1–12 张定稿 | `ContactSheetRenderer.swift`, `CharkleExternalAgentService.swift`, `CLIArgParser.swift`, `CLICompletions.swift`, `CharkleCLI.swift` | `windows/crates/charkle-core/src/intelligence/contact_sheet.rs`, `windows/crates/charkle-core/src/agent/service.rs`, `windows/crates/charkle-cli/src/main.rs` |
| **4. 随仓规范 Agent Skill & 设置页示例同步** | 仓库统一沉淀 `Resources/AgentSkill/charkle/SKILL.md`，设置页「外部智能体（MCP & CLI）」更新低消耗 CLI 示例命令 | `Resources/AgentSkill/charkle/SKILL.md`, `ExternalAgentsSettingsPane.swift` | `windows/ui/src/features/settings/`（外部智能体设置页）及安装包资源打包配置 |
| **5. 顶部悬浮托盘半路提前秒开 + 系统边缘防冲突** | 0ms 事件驱动拖拽采样（`~16ms` 节流，空闲保持 0Hz）；三层低位上行接引（直达顶带 + 慢速上拖低位带 + 260ms 快速上甩弹道预测），彻底避免拖文件撞屏幕顶边误触系统手势；`0.45s` 接近防闪退宽限；系统任务视图 / 窗口吸附激活时自动隐藏退让 | `CanvasSupport.swift` (`NotchDropGeometry`), `NotchShelfController.swift`, `PerformanceAndNotchTests.swift` | `windows/src-tauri/src/desktop.rs`（Win32 Drop Catcher 顶边唤醒与鼠标钩子/低位接引），对应 Rust 单测 |
| **6. 左右双侧边栏鼠标拖拽调宽（持久化 + 双击复位 + Quick Look 同步）** | 左侧导航栏（`188–420pt`，默认 `232pt`）与右侧素材信息检查器（`260–480pt`，默认 `300pt`）均支持 `9pt` 隐形拖拽热区、`col-resize` 光标、悬停/拖拽高亮与松手持久化；收起至 `76pt` 图标栏时向右拖拽 `>= 40pt` 可顺滑拉出；双击分隔线动画复位至默认宽度；右侧检查器宽度在主工作区与 Quick Look 预览页 **1:1 双向同步并均可拖拽**；双侧互斥防挤压保障主画廊 `>= 360pt` 且拖拽期间不触发抽屉动画抖动 | `CanvasSupport.swift` (`SidebarResizeGeometry`), `AppCoordinatorStore.swift`, `SidebarView.swift`, `InspectorView.swift`, `MainWindowView.swift`, `QuickLookOverlayView.swift`, `VirtualizedMasonryView.swift`, `NativeRedesignRegressionTests.swift` | `windows/ui/src/stores/`（左右栏宽度状态与持久化）、`windows/ui/src/features/sidebar/`、`windows/ui/src/features/inspector/`、`QuickLook` 覆盖层与主工作区三栏布局组件（React/TS + 单测） |

---

## 2. External Agent / MCP / CLI v1.2.2 精确契约（Windows 1:1 对齐）

### 2.1 低 Token 基础线与短 ID 协议

1. **紧凑 JSON 输出**：
   - **MCP 侧**：所有 tool 响应文本一律序列化为无缩进紧凑 JSON（去掉 pretty-print 空格换行，稳定节省 ~25–35% 文本 token）。
   - **CLI 侧**：检测 stdout 是否为 TTY（Rust 使用 `std::io::IsTerminal`）；**管道/子进程调用时默认输出单行紧凑 JSON**，仅在交互终端或显式传入 `--pretty` / `--human` 时格式化。
2. **精简 `tools/list` Schema 预算**：
   - 保持全部 20 个工具名称、Annotations（`readOnlyHint`、`destructiveHint: false`、`idempotentHint`、`openWorldHint`）与 4 静态资源 + 2 动态模板 + 4 Prompts 不变。
   - 精简冗余属性描述文案，确保 `tools/list` 整体序列化体积 **`< 18,000` 字节**（macOS 实测 `~16.4 KB`），建议在 Rust 集成测试里加同款字节上限断言。
3. **8+ 位短 UUID 前缀解析（全链路通用）**：
   - 数据库层新增主键前缀范围查询（SQLite B-tree：`WHERE id >= ?1 AND id < ?2` 或 `UPPER(id) LIKE '<PREFIX>%'`，按大写规范 UUID 匹配，要求长度 `>= 8` 十六进制/连字符字符）。
   - 所有接受 `asset_id`、`asset_ids`、`folder_id`、`board_id`、`seed_asset_ids`、`unlike_asset_ids`、`exclude_asset_ids` 的 MCP 工具、CLI 子命令及资源 URI（`charkle://assets/{asset_id}`、`charkle://boards/{board_id}`）统一走前缀解析：
     - 精确匹配 1 条 → 解析为完整大写 UUID；
     - 匹配 `>= 2` 条（前缀歧义）→ **显式报错**并列出命中的前若干完整 UUID，绝不猜第一个；
     - 0 条 → 报标准 not-found 错误。
   - `library_overview`、`search_assets`、`semantic_search`、`render_contact_sheet` 的紧凑/视觉清单字段输出精简 `id`（完整 UUID 或按 `detail` 档位提供 8 位 `shortId`；保持与 macOS 字段名对齐，详见 `CharkleExternalAgentService.swift`）。
4. **`detail` 档位扩展**：
   - 支持枚举：`["visual", "compact", "standard", "full"]`。
   - **`"visual"`**（极简视觉清单）：仅保留供 Agent 结合 Contact Sheet 编号选图所需的最小字段（`slot`、`shortId`/`id`、`title`、`folderPath`、`aspectShape`、`dominantHex`、`tags`），剔除长段 `aiDescription`、`ocrText`、路径与冗余时间戳。
   - 当调用方传入 `render_contact_sheet: true` 且未显式指定 `detail` 时，**自动切换为 `"visual"`**。
5. **`library_overview` 语义图谱（Folder Semantic Atlas）**：
   - 新增可选入参：`compact: bool`、`include_folder_profiles: bool`（默认 `true`）、`include_boards: bool`（默认 `true`）、`top_tags_limit: int`（`5..80`）。
   - 每个目录条目补充语义画像：
     - `recursiveAssetCount`（含全部子目录的去重/累加素材数）
     - `topTags`（目录子树内频次最高的 Top 5 标签）
     - `palette`（目录子树内占比最高的 Top 3 代表色 HEX）
     - `dominantAspect`（该目录最常见画幅，如 `portrait` / `landscape` / `square`）
   - 顶层同步返回 `aspectShapeCounts` 与 `mediaKindCounts`，让 Agent 首轮 1 次调用即可完成定向选目录。

---

### 2.2 `VisualQueryIntelligence`：双语视觉扩展、7 维 CIELAB 色调与 CJK 分词

直接对照 [`Sources/CharkleCore/Intelligence/VisualQueryIntelligence.swift`](../../../Sources/CharkleCore/Intelligence/VisualQueryIntelligence.swift) 在 `windows/crates/charkle-core/src/intelligence/visual_query.rs` 复刻：

1. **7 维本地 CIELAB `VisualTone` 枚举与精确解析**：
   - 规范 raw value：`dark`、`light`、`warm`、`cool`、`vivid`、`muted`、`high_contrast`。
   - 解析别名兼容中英文：
     - `dark`: `dark` / `暗调` / `深色` / `暗`
     - `light`: `light` / `bright` / `浅色` / `明亮` / `白底` / `浅`
     - `warm`: `warm` / `暖色` / `暖调` / `暖`
     - `cool`: `cool` / `cold` / `冷色` / `冷调` / `冷`
     - `vivid`: `vivid` / `vibrant` / `saturated` / `高饱和` / `鲜艳`
     - `muted`: `muted` / `pastel` / `soft` / `低饱和` / `莫兰迪` / `柔和`
     - `high_contrast`: `high_contrast` / `highcontrast` / `contrast` / `高对比` / `强对比` / `撞色`
   - 基于素材已落盘的 `dominant_colors`（前 5 组 CIELAB `L* / a* / b* / proportion`）在亚毫秒内计算 `0.0..=1.0` 拟合分，阈值 `score >= 0.52` 视为命中 `matches()`（具体加权公式与 `deltaE2000` 对比度公式直接照搬 `VisualQueryIntelligence.swift` L35–L130 即可保证两端检索结果一致）。
2. **中英文视觉同义词词簇扩展 + 自然语言提示提取**：
   - 复用 `VisualQueryIntelligence.swift` 中的中英文设计/视觉词簇（涵盖光照/色调、材质、排版、风格、插画、摄影、UI/网页、场景等）做查询扩展，同时自动从自然语言 query 中提取隐含的 `VisualTone` 与 `AspectShape`（如「竖版暗黑赛博海报」→ 自动抽出 `aspect=portrait`、`tone=dark` 并扩展双语视觉词）。
   - **CJK 分词**：Windows Rust 侧如尚未接入中文词边界切分，针对连续 CJK 字符串可结合词典/二元与三元切词（bigram/trigram fallback）确保「夏日海边蓝天女孩」等无空格中文短语能命中 FTS 里的「海边」「蓝天」「女孩」标签或描述。
3. **默认包含子目录 & 自动 `facets`**：
   - `search_assets`、`semantic_search`、`render_contact_sheet` 中 `include_subfolders` **默认值改为 `true`**（显式传 `false` 才仅限直属目录）。
   - 新增 `include_facets: bool`（大结果集或显式请求时返回 `facets: { topFolders, topTags, aspectShapes, topColors }`），供 Agent 下一轮精准收敛。
4. **正向引导 + 负向视觉排斥 + 视觉多样性去重（`diversify`）**：
   - `semantic_search` 与 `find_similar_assets` 支持：
     - `seed_asset_ids: string[]`（“更像这几张”）
     - `unlike_asset_ids: string[]`（“避开这几张的视觉风格/构图/色调”，在融合评分中扣除与负例视觉向量/CIELAB 色板过近的候选分）
     - `visual_rerank: bool`（CLI `--fast` / `--no-visual-rerank` 可跳过云端视觉重排实现毫秒级本地召回）
     - `diversify: bool`：基于本机视觉特征相似度（Windows 侧使用本地视觉特征向量 + CIELAB 色差）执行 **Round-Robin 聚类去重**，避免连拍/同系列重复图霸占前 16 个候选位。

---

### 2.3 单次往返 Contact Sheet、多意图合图与批量精查

1. **Contact Sheet 宽度下限降至 `512`**：
   - `ContactSheetRenderer` 的 `max_width` 合法范围调整为 **`512..=1920`**（默认 `1024`，单页最多 `24` 张编号 `#01..#24`）。
2. **One-Shot 内联 Contact Sheet**：
   - `search_assets`、`semantic_search`、`list_inbox`、`find_similar_assets` 均新增参数：
     - `render_contact_sheet: bool`
     - `sheet_max_width: int`（`512..=1920`）
     - `output_path: string`（可选落盘路径，需校验禁止写入素材库目录或敏感系统目录，且 `readOnly` 模式禁止写盘）
   - 一次工具调用同时返回极简 `visual` 文本清单 + 内联 Contact Sheet JPEG（MCP `image` content block）。
3. **多方向三合一 Contact Sheet（`queries[]`）**：
   - `semantic_search` 与 `render_contact_sheet` 支持 `queries: string[]`（接受 2–6 个并列创意方向，例如 `["人物动态", "夏日海边晴空", "极简白底"]`）。
   - 按各子查询轮询配额去重汇聚候选并拼入同一张带序号的 Contact Sheet，一次视觉看图覆盖多个方向，将原本 3–4 轮工具调用压成 1 轮。
4. **批量定稿精查（`get_asset` & CLI `charkle asset`）**：
   - `get_asset` 支持 `asset_ids: string[]`（1–12 个完整 UUID 或 8+ 位前缀，向后兼容单参数 `asset_id`）；`include_image: true` 时单张返回原/预览图 JPEG，批量返回高分辨率放大拼图或逐项精查预览。
   - CLI `charkle asset <id1> [id2 ...]` 支持多位置参数批量查询。
5. **CLI 新增/对齐参数一览**（详见 `Sources/CharkleCLI/CLIArgParser.swift` & `CharkleCLI.swift`）：
   - 全局/输出：`--compact`、`--pretty`、`--human`、`--json`
   - 检索过滤：`--tone <dark|light|warm|cool|vivid|muted|high_contrast>`、`--any-tag <csv>`、`--exclude-tag <csv>`、`--subfolders` / `--no-subfolders`、`--diversify`、`--facets` / `--no-facets`
   - 语义与视觉引导：`--queries <csv>`（或重复 `--query`）、`--seed-ids <csv>`、`--unlike-ids <csv>`、`--fast` / `--no-visual-rerank`
   - 视觉单次输出：`--detail <visual|compact|standard|full>`、`--contact-sheet`、`--out <path>`、`--max-width <512..1920>`

---

## 3. 顶部悬浮托盘低位提前接引与系统边缘防冲突（Windows Top Shelf 同步建议）

macOS v1.2.2 彻底解决了「拖文件往顶部刘海甩时，尚未展开就撞上屏幕顶边触发 Mission Control」的高频痛点。Windows 11 上存在完全对称的体验冲突：**拖文件/窗口撞到屏幕顶边易触发 Snap Layouts 顶边吸附条，且高速上拖时若等到指针进入顶边窄条带才慢半拍轮询唤醒，同样会冲过头**。

建议在 `windows/src-tauri/src/desktop.rs`（以及纯函数几何模块）按以下三点对齐改造：

1. **0ms 事件驱动拖拽采样（保持 0Hz 空载 CPU）**：
   - 仅在外部拖拽会话活跃（或悬浮托盘展开）期间监听指针移动，收到首条拖拽移动事件 **0ms 立即判定**（后续 `~16ms` 节流，备用定时器 `~33ms`）；非拖拽收起状态立即停止采样，空载 CPU 保持 `< 0.5%`。
   - 多显示器场景切换显示器时重置 `drag_start_location` 与采样队列，所有高度阈值按当前显示器逻辑像素（DIP / 除缩放比 `scale_factor`）计算，确保 100% / 125% / 150% / 200% DPI 行为一致。
2. **三层低位上行接引纯函数（对照 `Sources/CharkleCanvas/CanvasSupport.swift` 中 `NotchDropGeometry::shouldTriggerUpwardDragApproach`）**：
   - **Tier 1（顶部直达带）**：距顶 `76` 逻辑像素、水平居中 `±176` 逻辑像素；若从顶部起拖且明显**向下拖离**（`total_upward_travel <= -14`），抑制展开（避免从浏览器地址栏往下拖链接误触）。
   - **Tier 2（慢速上拖低位接引带）**：距顶 `136` 逻辑像素、水平居中 `±220` 逻辑像素；要求确实从下方累计向上拖动 `>= 24` 逻辑像素、垂直向上速度 `vy >= 25 px/s` 且上行占主导（`vy >= |vx| * 0.50`）。
   - **Tier 3（快速上甩 260ms 弹道预测走廊）**：屏幕上方 `clamp(screen_height * 0.32, 260, 350)` 逻辑像素高度、水平 `min(max(320), screen_width * 0.34)`；要求累计上移 `>= 36` 逻辑像素、`vy >= 240 px/s`、`vy >= |vx| * 0.65`，且沿当前速度前推 `0.26s` 的预测落点进入顶部中心接引区（`projected_y` 落入 `76` 顶带且 `|projected_x - mid_x| <= 290`）。
   - **防闪退宽限**：提前展开后给予 `0.45s` 接近宽限（卡片外扩 `48` 逻辑像素且未明显向下反转 `vy >= -80` 时不中途闪退）；若用户反悔向下拖离或在外部松手则迅速收起。
3. **系统界面自动退让（Windows 专属）**：
   - 检测到 **Task View (`Win+Tab`) / 多桌面切换视图**（前景窗口类 `XamlExplorerHostIslandWindow` / `MultitaskingViewFrame`）或**独占全屏应用**时，主动收起顶部悬浮窗并临时隐藏 Win32 Drop Catcher 顶边捕获层，退出后自动恢复；同时确认 Drop Catcher 窗口保留 `WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW`，绝不抢焦点或出现在 `Alt+Tab` 列表。

---

## 4. 左右双侧边栏鼠标拖拽调宽（Resizable Sidebar & Inspector，Windows 1:1 交互契约）

对照 macOS `SidebarResizeGeometry`、`AppCoordinatorStore`、`SidebarView`、`InspectorView`、`MainWindowView` 与 `QuickLookOverlayView` 的实现，Windows React/TS 主窗口三栏布局及 Quick Look 同步补齐以下行为：

1. **双侧尺寸边界、互斥夹紧与持久化**：
   - **左侧导航栏**：`collapsedSidebarWidth = 76`、`defaultSidebarWidth = 232`、`minSidebarWidth = 188`、`maxSidebarWidth = 420`（单位 `px`）。
   - **右侧素材信息检查器（Inspector）**：`defaultInspectorWidth = 300`、`minInspectorWidth = 260`、`maxInspectorWidth = 480`（单位 `px`），**主工作区与 Quick Look 预览页共享同一份持久化宽度并双向同步**。
   - **中心工作区保护**：`minCenterWorkspaceWidth = 360`；任一侧变宽或窗口缩窄时，自动以当前对侧占用宽度计算动态上限：
     - 左侧上限：`max(188, min(420, windowWidth - (inspectorVisible ? inspectorWidth + 1 : 0) - 360 - 1))`
     - 右侧上限：`max(260, min(480, windowWidth - sidebarOccupiedWidth - 360 - 1))`（Quick Look 中 `sidebarOccupiedWidth = 0`）
     - 窗口拉宽后自动恢复用户偏好的持久化宽度。
   - 持久化存储于本地 UI 配置（如 `localStorage` / Settings store），拖拽过程中仅更新实时内存宽度，**松手时写入一次持久化存储**，避免 60/120Hz 写盘抖动。
2. **对称分隔线拖拽手柄与视觉细节**：
   - 左侧栏右缘与右侧 Inspector 左缘（含 Quick Look 内 Inspector 左缘）均保持 `1px` 细分隔线，并在其中心叠加 **`9px` 宽（左右各 `4px`）的透明拖拽热区**（置于裁切容器之外避免半边被裁切），使用 Pointer Capture（`setPointerCapture`）跟踪屏幕/视口增量：
     - 左侧栏：`rawWidth = startWidth + deltaX`
     - 右侧 Inspector：`rawWidth = startWidth - deltaX`（向左拖变宽，向右拖变窄）
   - 光标：展开态悬停/拖拽使用 `col-resize`（`ew-resize`），左侧栏收起态（`76px` 图标栏）悬停使用 `e-resize`；悬停时细线柔和亮起，拖拽时呈现 `2px` 主题强调色细线。
   - **双击分隔线**：平滑过渡复位至对应默认宽度（左侧 `232px` / 右侧 `300px`）。
   - **从图标栏向右拉出**：左侧栏收起状态下按住分隔线向右拖出 `>= 40px` 自动取消收起并顺滑衔接实时调宽。
3. **零抖动过渡保护**：
   - 任一侧分隔线拖拽期间临时禁用抽屉宽度 CSS `transition`（避免每一帧都在追逐 `300ms` 缓动），让瀑布流、横向瀑布流、3D 环形画廊、情绪板与 Quick Look 舞台实时跟手重排；松手后恢复 `⌘\`/`Ctrl+\` 与 `⌥⌘I`/`Ctrl+Alt+I` 抽屉过渡动画。
   - 对应前端单测：覆盖左右双侧边界夹紧（极窄/极宽/NaN/窄窗+双栏互斥）、持久化读写与双击复位逻辑。

---

## 5. Windows v1.2.2 版本升级、验证与共享 GitHub Release 合入清单

### 5.1 版本号统一升至 `1.2.2`（对照 v1.2.1 提交 `7731611`）
- `windows/Cargo.toml` & `windows/Cargo.lock`
- `windows/src-tauri/tauri.conf.json`
- `windows/ui/package.json`
- `windows/crates/charkle-cli/src/main.rs`
- `windows/crates/charkle-core/src/agent/service.rs`（`serverVersion`）
- `windows/crates/charkle-core/src/bridge.rs`
- `windows/crates/charkle-core/src/intelligence/cloud_ai.rs` & `typesafe.rs`
- `windows/ui/src/api/transport.ts`、`windows/ui/src/stores/appUpdateStore.ts`、`windows/ui/src/features/settings/SettingsPanesCaptureSystem.tsx`、`windows/ui/src/__tests__/app-updater.test.tsx`

### 5.2 必跑质量门禁（完整流程见 `charkle-windows-ship`）
1. 前端：`cd windows/ui && npm run typecheck && npm run test && npm run build`
2. Rust：`cd windows && cargo fmt --all -- --check && cargo clippy --workspace --all-targets -- -D warnings && cargo test --workspace`
   - 必须补齐 Rust 单元测试：
     - 8 位短 ID 解析（精确命中 / 歧义报错 / 不存在）
     - 7 维 `VisualTone` CIELAB 打分与中英文别名解析
     - `tools/list` 总字节数 `< 18,000` 断言
     - `search_assets` 默认 `include_subfolders: true`、`detail: "visual"`、auto `facets`、`render_contact_sheet`、`queries[]` 三合一、`get_asset` 批量查询、`unlike_asset_ids` 排斥
     - `ShelfDropGeometry` 三层低位上行预测 + 防误触（横向/向下/角落/停顿衰减）断言
3. 纯净度审计：确保零外部竞品/参考产品名、零个人路径、零密钥泄露。
4. 打包 NSIS `Charkle_1.2.2_x64-setup.exe`（内嵌最新版 `charkle.exe` CLI/MCP sidecar 与 `BrowserExtension`），记录字节数与 SHA-256，本机部署并验证空载 CPU `< 1%`。

### 5.3 共享 `v1.2.2` GitHub Release 无损追加流程
macOS 端已先创建共享 Release **`v1.2.2`** 并预留了 `## Windows（v1.2.2 · x64）` 占位区块。Windows 端构建校验通过后：
1. 先 `git fetch origin && git rebase origin/main`，再用显式 `git push origin main` 推送 Windows 提交（绝不运行 `git push --all`）。
2. 上传 Windows 安装包：
   ```bash
   gh release upload v1.2.2 Charkle_1.2.2_x64-setup.exe --clobber
   ```
3. **非破坏性更新 Release 正文**：先拉取线上实时 body（`gh release view v1.2.2 --json body --jq '.body'`），**一字不改保留 `## macOS（v1.2.2 · Build 8 · Apple Silicon）` 全部内容与 macOS SHA-256**，仅将 `## Windows（v1.2.2 · x64）` 占位区块替换为 Windows 正式更新说明、安装包大小与 SHA-256，再用 `gh release edit v1.2.2 --notes-file <file>` 更新并核验双平台资产完整。

---

## 6. 实战避坑提醒

1. **严格零外部竞品名**：调研时提及的任何第三方 macOS/Windows 工具名称**绝不可**写入 Rust/TS 源码、注释、测试、文档或 Release Notes。
2. **CLI 管道纯净契约**：`charkle` 在非 TTY 管道下 stdout 必须保持合法单行 JSON，任何日志或警告必须走 stderr，避免破坏 Agent 解析。
3. **短 ID 歧义必须显式拒绝**：前缀命中多条记录时务必返回明确错误与候选前缀，防止写入类工具（如 `organize_assets` / `trash_assets`）误操作其他素材。
4. **`VisualTone` 过滤与排序一致**：当用户在自然语言 query 中同时写了「暗黑 极简 蓝」时，先走 CIELAB 拟合分加权排序而非硬性直接清空低置信候选项，仅在显式传入 `tone` 参数时执行强过滤（`score >= 0.52`），避免小图库召回 0 结果。
5. **高 DPI 统一用逻辑像素**：Windows 侧计算 `76 / 136 / 260..350` 高度与 `240 px/s` 速度阈值时，务必使用显示器逻辑像素（DIP），避免 200% 缩放屏上物理像素翻倍导致触发过早。
