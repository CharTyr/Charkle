# Windows 端同步开发文档：`.eaglepack` 素材包与 `.library` 素材库无损导入

> 本文档面向 Windows（Tauri v2 + Rust Core + React/TS）开发会话，对应 macOS 已落地并通过全量回归验证的 `.eaglepack` / `.library` 外部素材包无损导入能力。
>
> macOS 参考实现见 [`Sources/CharkleCore/Media/EaglePackImporter.swift`](../../../Sources/CharkleCore/Media/EaglePackImporter.swift)、[`Sources/CharkleCore/LiveCharkleEngine.swift`](../../../Sources/CharkleCore/LiveCharkleEngine.swift) 与 [`Tests/CharkleTests/EaglePackImporterTests.swift`](../../../Tests/CharkleTests/EaglePackImporterTests.swift)。Windows 侧严格遵守 [`windows/AGENTS.md`](../../../windows/AGENTS.md) 与 [`charkle-windows-ship`](../../../.agents/skills/charkle-windows-ship/SKILL.md)。

---

## 1. 功能总览与 Windows 文件精准映射

| 层级 | 核心职责 | macOS 参考实现 | Windows 对应目标文件 |
| :--- | :--- | :--- | :--- |
| **Core 解析与安全解压** | 自动识别 `.eaglepack`（ZIP 归档 / 已解压目录）、`.library` 目录与显式选择的 `.zip` 导出包；防 Zip-Slip 与符号链接逃逸；解析目录树、`pack.json`、`metadata.json`、`<ID>.info/` 载荷与离线 `.url` 缩略图 | `Sources/CharkleCore/Media/EaglePackImporter.swift` | `windows/crates/charkle-core/src/media/eaglepack.rs`（新增，在 `media/mod.rs` 导出） |
| **统一入库管线接入** | 在目录递归展开之前拦截素材包（绝不把 `<ID>.info/metadata.json` 或 `*_thumbnail.png` 当普通文件入库）；镜像创建目录树与目录配色；透传标题、标签、评分、注释、来源 URL、原始时间及离线书签缩略图；新增 `import_material_package` 返回结构化统计 | `Sources/CharkleCore/Contracts/CoreServiceProtocols.swift`, `Sources/CharkleCore/LiveCharkleEngine.swift` | `windows/crates/charkle-core/src/engine.rs`、`windows/crates/charkle-core/src/media/pipeline.rs` |
| **Tauri 命令 & 拖放/CLI 联动** | 新增 Tauri 命令 `import_material_packages`（支持原生文件选择 `.eaglepack`/`.zip` 及 `.library` 目录选择）；主画廊/侧边栏/情绪板/Win32 顶部悬浮托盘 Drop Catcher 与 `charkle ingest` / MCP `ingest_asset` 通过统一 `engine.ingest` 自动生效 | `Sources/CharkleApp/Stores/LibraryStore.swift`, `Sources/CharkleApp/CharkleAppEntry.swift` | `windows/src-tauri/src/commands/assets.rs`, `windows/src-tauri/src/lib.rs`, `windows/ui/src/api/transport.ts` |
| **前端入口与反馈** | 新增快捷键 **`Ctrl+Shift+I`**、侧边栏「文件夹」标题栏导入图标按钮、`设置 → 素材库 → 外部素材包导入` 入口；导入中提示 + 完成后汇总 Toast（新建文件夹数 + 收入素材数）并自动定位至新导入根目录 | `SidebarView.swift`, `LibrarySettingsPane.swift`, `SettingsOverlayView.swift`, `MainWindowView.swift` | `windows/ui/src/App.tsx`, `windows/ui/src/features/sidebar/SidebarView.tsx`, `windows/ui/src/features/settings/`（素材库设置页） |

---

## 2. `.eaglepack` / `.library` 格式解析规范（全变体 1:1 对齐）

### 2.1 容器识别规则
1. **`.eaglepack` 归档文件**：扩展名为 `.eaglepack` 的常规 ZIP 文件（同时支持 Store/Deflate、UTF-8 中文文件名及 ZIP64 大包；Rust 侧使用 `zip` crate）。
2. **已解压 `.eaglepack` 目录或 `.library` 目录**：
   - 先做**单层顶层套壳目录自动解包**（忽略 `__MACOSX` 与 `.` 开头隐藏项，若仅含 1 个非 `.info` 子目录且根目录无 `pack.json`/`metadata.json`，自动下钻一层）。
   - 满足以下任一即识别为素材包目录：
     - 存在 `pack.json`；
     - 存在 `metadata.json` 且存在 `images/` 子目录（或目录名以 `.library` 结尾）。
3. **显式导入器中的 `.zip`（`allow_generic_zip = true`）**：
   - **拖拽普通 `.zip` 到画廊时仍按普通压缩包文档入库，绝不误拆用户自己的设计资源包！**
   - 仅当用户通过「导入素材包…」显式选择 `.zip` 时，预扫描 ZIP 目录条目，仅在包含 `pack.json` 或同时包含 `metadata.json` 与 `.info/` 目录时按素材包解包。

### 2.2 安全与临时目录生命周期红线
1. **防 Zip-Slip 路径穿越与超限保护**：
   - 条目上限 `200,000`；目录递归深度上限 `24`（配合 `visited_folder_ids` 防环）。
   - 解压前校验每个 ZIP 条目名：将 `\` 规范化为 `/` 后，拒绝任何以 `/` 开头、含 Windows 盘符（如 `C:`）或包含 `..` 路径段的条目；解压与扫描 `.info/` 时跳过符号链接并校验 `canonicalize()` 严格位于临时解压根目录内。
2. **临时目录生命周期**：
   - 解压到系统临时目录 `charkle-eaglepack-<uuid>`；**必须等到全部素材文件完成拷贝并写入 Charkle 永久库之后**（`ingest` 顶层 `defer` / RAII guard），再递归删除临时目录，绝不可在展开阶段提前清理。
3. **单条损坏容错**：
   - `import_material_package` 模式下，单个损坏/0 字节/缺失载荷项记录到 `skipped_missing_count` 并跳过，不得因 1 条坏数据导致整包数百张好素材全部回滚失败。

### 2.3 目录树与元数据精确映射
1. **目录树来源优先级**：
   - `pack.json` 的 `folder`（单根对象）→ `pack.json` 的 `folders`（数组）→ `.library/metadata.json` 的 `folders`（数组）。
   - 每个目录节点解析 `id`、`name`（空则回退 `"未命名文件夹"`）、`iconColor`（映射至 `FolderRecord.color_hex`）与递归 `children`。
   - **配色映射表**（同步 `#RRGGBB` 合法十六进制直通）：
     - `red` → `#EF4444`、`orange` → `#F97316`、`yellow` → `#EAB308`、`green` → `#22C55E`、`aqua`/`cyan`/`teal` → `#06B6D4`、`blue` → `#3B82F6`、`pink`/`rose` → `#EC4899`、`brown` → `#A16207`、`gray`/`grey` → `#64748B`。
   - **防双重套壳规则**：
     - 仅有 **1 个**顶层根文件夹时（典型导出文件夹 `.eaglepack`），直接在 `target_folder_id` 下镜像该根目录（避免出现 `A/A` 冗余套壳）。
     - 有 **多个**根文件夹（整库 `.library` / 多目录包）或 **0 个**根文件夹（松散选中项导出）时，在 `target_folder_id` 下新建 `<package_name>` 容器目录统一收纳。
     - 根目录若名为 `Inbox`（忽略大小写且 `parent_id == None`），规范化为 `"Inbox 导入"`。
2. **`<ITEM_ID>.info/` 发现与元数据合并**：
   - 同时扫描 `images/<ID>.info/` 与根目录 `<ID>.info/`，与 `pack.json.images[]` 按 `id` 合并（先保留 `pack.json.images[]` 顺序，再补齐其余磁盘发现项）。
   - 合并规则：`<ID>.info/metadata.json` 优先覆盖非空字段，缺失字段由 `pack.json.images[]` 补齐。
   - **`isDeleted == true`**：直接跳过并计入 `skipped_deleted_count`。
3. **载荷文件定位算法（避开 Windows/macOS 改名与缩略图误导）**：
   - 扫描 `<ID>.info/` 内常规非隐藏文件，严格排除：`metadata.json`、`.`/`._` 开头文件，以及文件名主干为 `_thumbnail` 或以 `_thumbnail` 结尾的缩略图文件（保留其中一张作为可选 `thumbnail_path` 供离线书签使用）。
   - 载荷匹配顺序：① 精确 `<name>.<ext>`（含跨平台非法字符 `/ \ : * ? " < > |` 替换为 `_` 后的大小写不敏感匹配）→ ② 同扩展名最大文件 → ③ 剩余常规文件中体积最大者。
4. **字段无损落库**：
   - `name` → `asset.title`（保留原始未清洗名称，例如含 `/` 的展示标题）
   - `tags` → 去空白、大小写不敏感去重、排序后合并至 `asset.tags`
   - `star` 或 `rating` → 夹紧 `0..=5` 写入 `asset.rating`
   - `annotation` → `asset.notes`
   - `url` → 仅接受合法 `http`/`https`，写入 `asset.source_url` 与 `asset.source_domain`
   - `btime` / `mtime` / `modificationTime` / `lastModified` → 自动兼容毫秒（`> 10_000_000_000` 除 `1000`）与秒时间戳，限定 `1990..now+2d` 有效区间，分别还原 `created_at` 与 `updated_at`
   - `folders` → 取首个命中 `folder_id_map` 的 Charkle `folder_id`，未命中则落入包容器根目录
5. **`.url` / `.webloc` 网页书签离线秒导**：
   - 当 `ext` 为 `url` 或 `webloc` 时，若 `metadata.url` 为空，解析 Windows `[InternetShortcut]\r\nURL=https://...` 或 `.webloc` plist 提取 `http`/`https` 链接（拒绝 `file://` 等非 web 协议）。
   - 若 `<ID>.info/` 内存在 `*_thumbnail.*` 预渲染网页截图，直接本地解码走 `ingest_pre_resolved_web_page` 离线生成高分书签缩略图，**避免导入含几十条书签的素材包时触发大批量网络/WebView 抓取阻塞**；无缩略图时再走常规网页书签抓取。

---

## 3. Windows 前端与交互细节

1. **返回结构 `MaterialPackageImportResult`**：
   ```ts
   export interface MaterialPackageImportResult {
     packageName: string;
     importedAssetCount: number;
     createdFolderCount: number;
     rootFolderID: string | null;
     skippedDeletedCount: number;
     skippedMissingCount: number;
   }
   ```
2. **Windows 原生文件/目录选择体验**：
   - Windows 原生文件对话框不能在单次弹窗里同时混选文件与文件夹：
     - 主操作「导入素材包（.eaglepack / .zip）…」（`Ctrl+Shift+I` & 侧边栏文件夹栏图标按钮）使用多选文件对话框筛选 `*.eaglepack;*.zip`；
     - 在「设置 → 素材库 → 外部素材包导入」同时提供 **`选择素材包 (.eaglepack)…`** 与 **`选择素材库目录 (.library)…`** 两个清晰按钮（侧边栏也可做轻量下拉菜单或双按钮），同时直接拖拽 `.eaglepack` 文件或 `.library` 文件夹到主窗口/侧边栏/情绪板/顶部 Win32 Drop Catcher 均自动生效！
3. **导入反馈与导航**：
   - 开始时展示轻提示「正在解析并导入素材包…」，完成后自动刷新素材库，若单包导入且存在 `rootFolderID` 则自动选中并展开该目录，展示 Toast：`已导入「{packageName}」：新建 {createdFolderCount} 个文件夹，收入 {importedAssetCount} 项素材`。

---

## 4. 必补测试与验证清单

1. **Rust 单元测试（`windows/crates/charkle-core`）**：
   - 完整 `.eaglepack` ZIP 端到端导入：单根 `folder` + 嵌套子目录 + 目录配色 + 标签去重 + `star`/`rating` + `annotation` + `url` + 毫秒 `btime` + 离线 `.url` 书签复用 `*_thumbnail.png` + 跳过 `isDeleted: true` + 绝不把 `metadata.json`/`*_thumbnail.png` 重复导入。
   - 直接拖入 `.library` 目录走 `engine.ingest`：自动拦截不产生 `.info` / `images` 垃圾目录，正确还原跨平台改名文件（如标题含 `/` 磁盘为 `_`）。
   - 顶层套壳目录 + `__MACOSX` 兼容与松散无目录 `images[]` 容器化。
   - 安全测试：含 `../evil.png` 或绝对路径的恶意 ZIP 被拒绝，非 `http`/`https` 的 `.url`（如 `file:///...`）被拒绝，临时目录在导入后彻底删除。
2. **门禁验证**：
   - `cd windows/ui && npm run typecheck && npm run test && npm run build`
   - `cd windows && cargo fmt --all -- --check && cargo clippy --workspace --all-targets -- -D warnings && cargo test --workspace`
