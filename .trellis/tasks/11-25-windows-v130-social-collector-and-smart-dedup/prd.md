# Windows 端同步开发文档（v1.3.0）：6 大社媒批量采集桥接 + 非 AI 全媒体智能去重

> 本文档面向 Windows（Tauri v2 + Rust Core + React/TS）开发会话，与 [`.trellis/tasks/11-25-windows-eaglepack-library-importer/prd.md`](../11-25-windows-eaglepack-library-importer/prd.md) 共同构成 **Charkle v1.3.0** 的 Windows 端全量对齐清单。
>
> **共享浏览器扩展已就绪**：[`Resources/BrowserExtension/`](../../../Resources/BrowserExtension/) 已升级至 `v1.3.0`（支持 X / Pixiv / Bluesky / Threads / Instagram / 小红书 6 大社媒批量采集，并重构为「语境优先 + 单行存入栏 + 渐进展开」的克制弹窗 UI），Windows 端 Chrome / Edge 直接复用同一套扩展代码，仅需补齐桌面端本地桥接接口与全媒体智能去重引擎及 Fluent 2 审核面板。
>
> Windows 侧严格遵守 [`windows/AGENTS.md`](../../../windows/AGENTS.md)、[`.trellis/spec/windows/fluent2-design-system.md`](../../spec/windows/fluent2-design-system.md) 与 [`charkle-windows-ship`](../../../.agents/skills/charkle-windows-ship/SKILL.md)。

---

## 1. 功能总览与文件精准映射

| 模块 | 核心职责 | macOS 参考实现 | Windows 对应目标文件 |
| :--- | :--- | :--- | :--- |
| **社媒模型与 URL 解析** | `SocialPlatform` 新增 `pixiv` / `instagram`；规范去重键新增 `pixiv:<id>` 与 `ig:<shortcode>` | `Sources/CharkleCore/Contracts/CoreModels.swift`, `Sources/CharkleCore/Media/SocialPostResolver.swift`, `Sources/CharkleApp/Views/QuickLookRichViewers.swift` | `windows/crates/charkle-core/src/models.rs`, `windows/crates/charkle-core/src/media/social.rs`（或对应社媒解析模块）, `windows/ui/src/features/quicklook/SocialPostViewer.tsx` |
| **防盗链媒体下载器 & 桥接批写入** | `GET /api/v1/assets/existing-sources` 新增 `mediaCanonicalKeys`；`POST /api/v1/assets/ingest` 支持 `type: "socialMedia"` 与向后兼容 `"tweetMedia"`；按目标 CDN 自动附加 `Referer`（尤其是 Pixiv `i.pximg.net`） | `Sources/CharkleCore/Services/LocalExtensionBridgeServer.swift`, `Sources/CharkleCore/Media/XPostResolver.swift` | `windows/crates/charkle-core/src/bridge.rs` |
| **非 AI 全媒体智能去重引擎** | 覆盖全部 8 类 `MediaKind`（图片/动图/视频/音频/设计源文件/书签/文档/3D），纯确定性算法零 AI，按大类严格分桶隔离，自动推荐保留最高质量版本；本地指纹缓存 `dedup-fingerprints-v1.json` | `Sources/CharkleCore/Media/SmartDeduplicator.swift`, `Sources/CharkleCore/LiveCharkleEngine.swift` | `windows/crates/charkle-core/src/media/dedup.rs`（新增）, `windows/crates/charkle-core/src/engine.rs` |
| **无损元数据合并 & 情绪板改绑** | 单事务合并标签、取最高评分、补齐缺失目录/来源 URL/备注/EXIF/提示词；自动把情绪板中所有引用被删副本的节点无损改绑至保留母版；默认可恢复移入废纸篓 | `Sources/CharkleCore/LiveCharkleEngine.swift` (`resolveDuplicateGroups`) | `windows/crates/charkle-core/src/engine.rs`, `windows/src-tauri/src/commands/assets.rs`, `windows/src-tauri/src/lib.rs` |
| **去重审核面板与 5 处入口** | 作用域 + 3 档严格度 + 7 类媒体筛选芯片 + 双栏对比审核卡 + 皇冠主卡标记 + 手动「改为保留」覆盖 + 顶部 Quick Look 对比预览；入口含侧边栏按钮、文件夹右键、`Ctrl+Shift+D`、`Ctrl+J` 与设置页 | `Sources/CharkleApp/Views/SmartDeduplicationView.swift`, `SidebarView.swift`, `JumpAnywhereView.swift`, `LibrarySettingsPane.swift` | `windows/ui/src/features/dedup/SmartDeduplicationModal.tsx`（新增）, `SidebarView.tsx`, `JumpAnywhereModal.tsx`, `SettingsOverlay.tsx`, `App.tsx` |

---

## 2. 6 大社媒批量采集本地桥接协议（1:1 对齐扩展 v1.3.0）

### 2.1 `GET /api/v1/assets/existing-sources` 扩展字段
在保留原有 `sources`（全部来源 URL）与 `canonicalKeys`（全部规范去重键）的基础上，新增：
- **`mediaCanonicalKeys: string[]`**：仅统计 `media_kind` 属于 `image` / `animated_image` / `video` 的非废纸篓素材的 `canonical_dedup_key`（严格排除 `web_bookmark` 社交卡片）。
- **设计意图**：即使用户此前收藏过某条推文或贴文的网页书签卡片，在作者主页批量采集画作原图时仍可完整下载原始图片/视频，且二次运行作者采集时自动跳过已下载的作品。

### 2.2 `POST /api/v1/assets/ingest` 支持 `type: "socialMedia"`（兼容 `"tweetMedia"`）
单个 input 载荷契约：
```json
{
  "type": "socialMedia",
  "platform": "pixiv | x | bluesky | threads | instagram | xiaohongshu",
  "postID": "12556677",
  "tweetID": "12556677",
  "dedupKey": "pixiv:12556677",
  "originalURL": "https://www.pixiv.net/artworks/12556677",
  "authorName": "青岚",
  "authorHandle": "543210",
  "publishedAtText": "2026-11-20 12:00",
  "title": "星夜水彩合集",
  "bodyText": "作品说明",
  "subfolderName": "2026-11-20 · 星夜水彩合集 [556677]",
  "organizeMode": "per_post | per_tweet | multi_only | flat",
  "includeVideos": true,
  "hasVideo": false,
  "needsEnrich": false,
  "referer": "https://www.pixiv.net/",
  "tags": ["Pixiv", "青岚", "水彩"],
  "media": [
    { "kind": "photo | video | gif", "url": "https://...", "thumbnailURL": "https://..." }
  ]
}
```
处理规则：
1. **去重检查**：`skipDuplicates == true` 时对 `mediaCanonicalKeys` 执行 `dedupKey` 去重，命中则累加 `skipped` 并跳过。
2. **可选在线补全**：当 `needsEnrich == true` 或 `media` 为空时，X 平台走 `XPostResolver`（FxTwitter/VxTwitter），Bluesky 走公共 ATProto `getPostThread` 补齐多图与正文。
3. **子目录整理策略**：
   - `flat`：直接写入 `targetFolderID`（作者根目录）。
   - `multi_only`：仅当作品媒体数 ≥ 2 时在 `targetFolderID` 下创建/复用 `subfolderName`，单图直接写入作者根目录。
   - `per_post` / `per_tweet`（默认）：每条作品在 `targetFolderID` 下创建/复用 `subfolderName`（大小写不敏感匹配现有同父目录文件夹）。
4. **防盗链 CDN 下载头（关键红线）**：
   - 校验 `url` 与重定向目标必须为合法公网 `http/https`（禁止内网 SSRF），拒绝 `text/html` / `application/json` / `.m3u8` 误当媒体保存（遇到 `.m3u8` 自动降级尝试 `thumbnailURL` 封面）。
   - **`*.pximg.net`（Pixiv）**：必须附加 `Referer: https://www.pixiv.net/` 与常规浏览器 `User-Agent`，否则必返 `HTTP 403`！
   - **`*.xhscdn.com`（小红书）**：附加 `Referer: https://www.xiaohongshu.com/` 与浏览器 `User-Agent`。
   - **`*.cdninstagram.com` / `*.fbcdn.net`（Instagram / Threads）**：保留全部签名 query 参数，附加 `referer`（默认 `https://www.instagram.com/`）与浏览器 `User-Agent`。
   - **`pbs.twimg.com/media/...`（X）**：优先尝试 `name=orig` 原图，失败再退回原 URL / `thumbnailURL`。
5. **批量落库与返回**：
   - 并发下载至临时目录后统一走 `engine.ingest`，逐条补写规范化标题（多图带 `(1/N)`）、来源链接 `originalURL`、正文备注与平台/作者标签。
   - 响应 JSON 同时返回 `postsImported` 与 `tweetsImported`、`created`、`createdFolders`、`skipped` 与 `assets`。

### 2.3 新增 `SocialPlatform` 变体与去重键
- `pixiv`：展示名 `"Pixiv"`，作品名词 `"作品"`，徽章色 `#0096FA`；URL 解析支持 `/artworks/<id>`、`/<locale>/artworks/<id>` 与 `/member_illust.php?illust_id=<id>` → `pixiv:<id>`。
- `instagram`：展示名 `"Instagram"`，作品名词 `"贴文"`，徽章色 `#D93B58`（严禁使用紫罗兰色相区）；URL 解析支持 `/p/<code>`、`/reel/<code>`、`/tv/<code>` 及 `/<user>/p/<code>` → `ig:<code>`。

---

## 3. 非 AI 全媒体智能去重引擎规范（覆盖全部 8 类媒体）

严格遵守**零 AI 模型、零云端调用、纯经典确定性算法**原则，参考 [`Sources/CharkleCore/Media/SmartDeduplicator.swift`](../../../Sources/CharkleCore/Media/SmartDeduplicator.swift)：

### 3.1 分桶隔离与各媒体检测算法

所有候选严格按大类分桶匹配，**严禁跨大类误合并**（例如导出的 `.png` 与原始 `.psd` 源文件即使缩略图相同也绝不合并）：

| 媒体桶 | 匹配算法 | 自动推荐保留（最高质量）评分顺序 |
| :--- | :--- | :--- |
| **图片 / 动图** (`image`, `animated_image`) | ① SHA-256 精确匹配；② 2D-DCT 8×8 `pHash`（32×32 亮度）+ 9×8 `dHash` 汉明距离预筛；③ 16×16 归一化亮度 ZNCC + 8×8 RGB 色彩 MAD（防止不同配色变体与纯色色卡误合并）；④ 纵横比容差校验；⑤ `N > 4000` 自动切换 4×16-bit Multi-Index Hashing (MIH) + 反链式聚合 | 动图优先于静图 → 像素总数（分辨率）→ 无损/高保真格式（PNG/TIFF/HEIC/WebP/JPG）→ 有效码率 → 拉普拉斯清晰度 → 元数据完整度 |
| **视频** (`video`) | SHA-256 精确匹配 + 时长容差校验 + 封面帧视觉指纹与色彩校验 | 分辨率 → 码率 (Mbps) → 容器质量 → 清晰度 |
| **音频** (`audio`) | SHA-256 精确匹配 + 时长容差校验 + 复用库内 `waveform_peaks` 计算 64-bin 归一化波形包络 ZNCC 与 L1 MAD | 无损格式（FLAC/WAV/AIFF/ALAC）→ 高码率 (kbps) → 文件体积 |
| **设计源文件** (`design_file`) | SHA-256 精确匹配 + 独立渲染预览图视觉匹配（与 `image` 桶严格隔离） | 矢量/分层可编辑格式（SVG/PSD/AI/FIG/SKETCH 等）→ 像素分辨率 → 文件体积 |
| **网页书签** (`web_bookmark`) | 规范化 URL 与社交帖子 ID（去除追踪参数，`x:` / `xhs:` / `threads:` / `bsky:` / `pixiv:` / `ig:` / `github:` / 归一化 `web:`） | 富媒体附件数与标题/摘要/笔记完整度 |
| **文档** (`document`) | SHA-256 精确匹配 + 空白/换行折叠后的规范化正文 SHA-256（纯文本/Markdown 或已有 OCR 文本 ≥ 48 字符） | 正文与元数据完整度 → 文件体积 |
| **3D 模型** (`model_3d`) | SHA-256 精确匹配 + 严格预览图视觉匹配 | PBR 富格式（BLEND/USDZ/GLB/FBX > OBJ/STL）→ 文件体积 |

### 3.2 三档严格度与指纹缓存
- **严格度**：`strict`（仅极近似/无损重编码）、`balanced`（默认，覆盖主流缩放与压缩版本）、`relaxed`（覆盖更强二次压缩与小幅裁边）。
- **指纹缓存**：本地持久化 `dedup-fingerprints-v1.json`（按 `asset_id` + `content_hash` 索引），二次扫描跳过已算素材实现毫秒级复扫。

### 3.3 安全无损清理契约（`resolve_duplicate_groups`）
在单次 SQLite 事务内执行：
1. 若 `merge_metadata == true`（默认开启）：
   - 合并所有待删副本的标签到保留母版（去重排序）；
   - 评分取组内最大值；
   - 若母版位于收件箱（`folder_id == None`）而某副本已归档至文件夹，则继承该 `folder_id`；
   - 补齐母版缺失的 `source_url`、`notes`、EXIF、`ai_prompt` 与 `pinned_offline`；
   - **情绪板无损改绑**：扫描所有情绪板文档，将引用待删 `asset_id` 的节点 `asset_ref` 自动重写为保留母版的 `asset_id`（同一画板若已存在母版节点则安全去重避免重叠冲突）。
2. **处置方式**：默认 `trash`（可恢复移入废纸篓）；仅当用户显式切换为 `permanent_delete` 时才执行不可逆彻底删除（并在执行前通过居中 Dialog 二次确认）。

### 3.4 Windows Fluent 2 UI 审核面板与入口
- **入口（5 处）**：
  1. 侧边栏「素材库」标题栏右侧去重图标按钮；
  2. 侧边栏任意文件夹右键菜单「在此文件夹中智能去重…」；
  3. 全局快捷键 **`Ctrl+Shift+D`**；
  4. 快速跳转 `Ctrl+J` 命令「智能去重」；
  5. 设置 → 素材库 → 导入与智能整理 →「扫描重复素材…」。
- **面板层级与交互**：
  - 居中 Modal（z-index 严格低于 Quick Look，支持从任意对比卡片点击打开 Quick Look 大图核验且关闭后保留扫描结果）；
  - 顶部作用域选择器（全库 / 指定文件夹 / 收件箱）、3 档严格度 Segmented Control、7 类媒体筛选芯片；
  - 左侧重复组列表（含匹配类型标签与可释放空间统计），右侧主卡（皇冠标记 + 保留依据徽章）与副本并排对比卡（支持一键点击「改为保留」手动指定母版）；
  - 底部提供「合并元数据与情绪板引用」勾选、废纸篓 / 彻底删除切换及汇总清理按钮。

---

## 4. 必补测试、验证门禁与 v1.3.0 协同发版说明

1. **Rust 核心单测（`windows/crates/charkle-core`）**：
   - `SmartDeduplicator`：高分 PNG vs 缩放压缩 JPG 自动选留 PNG；同构图不同配色 & 纯色色卡零误报；音频波形/书签链接/文档规范文本/视频清晰度多类型聚类；PSD 与导出 PNG 严格隔离；端到端 `resolve_duplicate_groups` 验证标签/评分/目录继承与情绪板引用改绑。
   - `bridge.rs`：`GET /api/v1/assets/existing-sources` 独立返回 `mediaCanonicalKeys`（不混入 `web_bookmark`）；`POST /api/v1/assets/ingest` 解析 `socialMedia`（含 Pixiv/Instagram/Bluesky/Threads/X）与向后兼容 `tweetMedia`；Pixiv `Referer` 头注入校验。
2. **门禁验证**：
   - `cd windows/ui && npm run typecheck && npm run test && npm run build`
   - `cd windows && cargo fmt --all -- --check && cargo clippy --workspace --all-targets -- -D warnings && cargo test --workspace`
3. **协同发版（共享 `v1.3.0` Release）**：
   - Windows 端完成本任务 + [`.eaglepack` / `.library` 导入任务](../11-25-windows-eaglepack-library-importer/prd.md) 后，将 Windows 版本号升至 `1.3.0`，遵循 [`charkle-windows-ship`](../../../.agents/skills/charkle-windows-ship/SKILL.md) 上传 `Charkle_1.3.0_x64-setup.exe` 至已发布的 `v1.3.0` GitHub Release，并在 `## Windows（v1.3.0 · x64）` 区块填写发布说明与 SHA-256，**完整保留 macOS 区块正文不覆盖**。
