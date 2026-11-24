# Windows 开发交接文档（Round 6）：v1.1.0 环形画廊升级、小红书 3:4 卡片解析、免配置本地扩展桥接与实战踩坑汇总

> 本文档承接 [`11-24-windows-macos-round5-parity-and-pitfalls/prd.md`](../11-24-windows-macos-round5-parity-and-pitfalls/prd.md)，完整覆盖 macOS 主线在 `e8593f2..v1.1.0` 期间交付的全部新特性、跨端 HTTP 协议、UI 细节以及在真实浏览器/桌面联调中踩过的 7 个关键坑。
>
> 权威视觉与跨端契约以根目录 [`DESIGN.md`](../../../DESIGN.md) 和 [`.trellis/spec/cross-platform/index.md`](../../spec/cross-platform/index.md) §5.6、§5.9 为准；Windows 侧可直接复用仓库共享的浏览器扩展源码 [`Resources/BrowserExtension/`](../../../Resources/BrowserExtension/)，无需重复开发 Chrome / Edge / Arc / Brave 扩展前端。

---

## 1. Round 6 变更总览与 Windows 里程碑映射

| 模块 | 新增 / 升级能力 | 对应 Windows 里程碑 | macOS 参考实现 |
| :--- | :--- | :--- | :--- |
| **3D 环形画廊视口铺满 + 不等宽横图零裁切 + 默认参数定稿** | 按视口宽高自适应缩放横向铺满 ~94%；沿用横向瀑布流不等宽排布（固定高度 `300`，宽度按真实纵横比动态计算，横图零裁切）；定稿默认参数：`透视距离 1500px`、`景深模糊 2px`、`远端淡出 96%`、`卡片圆角 32px` | **M2（Gallery 第 4 视图 WebGL2）** | `Sources/CharkleCanvas/RingGalleryMath.swift`, `RingGalleryMetalView.swift`, `Sources/CharkleApp/Views/GalleryRingView.swift` |
| **小红书全链解析 + 原生 3:4 封面信息流卡片 + 旧素材无感迁移** | 支持 `/explore/<id>`、`/discovery/item/<id>`、`/user/profile/<uid>/<id>`、`xhslink.com` 短链与移动端分享口令；解析 `window.__INITIAL_STATE__` 与多 `og:image` 兜底；画廊卡片按 **竖版 3:4 封面（`900×1200`）+ `240px` 标题/作者/点赞信息栏（总尺寸 `900×1440`）** 渲染；启动后台自动将旧尺寸小红书素材无感升级为新卡片 | **M1（Rust Core 解析/制图/迁移） + M2（画廊与 Quick Look）** | `Sources/CharkleCore/Media/XiaohongshuPostResolver.swift`, `SocialPostResolver.swift`, `MediaArtwork.swift`, `LiveCharkleEngine.swift`, `Sources/CharkleApp/Views/QuickLookRichViewers.swift` |
| **本机扩展桥接服务 + 同机免配置自动配对（防呆与安全隔离）** | 仅绑定 `127.0.0.1:41937`（冲突自动顺延至 `41946`），提供与 Charkle Web 一致的 `/api/v1/*` 协议；新增 `POST /api/v1/auth/local-pair` 实现**同机安装插件即用、免填地址与令牌**，严格拦截外部网页与 localhost 网页来源；设置页默认隐藏手动令牌进「高级」折叠项 | **M1（Rust `axum`/`hyper` Loopback 服务） + M5（设置「插件与扩展」与安装包内嵌扩展）** | `Sources/CharkleCore/Services/LocalExtensionBridgeServer.swift`, `Sources/CharkleApp/Services/ExtensionBridgeController.swift`, `Sources/CharkleApp/Views/Settings/ExtensionsSettingsPane.swift` |
| **共享 Chrome / Edge / Arc / Brave 浏览器扩展（X 与小红书一键批量收藏同步）** | 直接复用 `Resources/BrowserExtension/`（Manifest V3，零构建步骤），内置跨站拖图、批量抓图、右键菜单、快捷键，以及 **X（含新版「历史 / X」`/i/history*`、书签、喜欢）与小红书收藏夹** 全自动滚动采集、增量去重、页面实时进度 HUD 与自愈重连 | **M5（打包内嵌 `BrowserExtension/` + 设置页一键在资源管理器定位）** | `Resources/BrowserExtension/`（完整单测见 `Resources/BrowserExtension/tests/extension.test.mjs`） |

---

## 2. 重点规格与 Wire Contract（Windows 直接对照实现）

### 2.1 3D 环形画廊（Round 6 定稿参数与算法）

1. **最终默认参数（`RingGalleryParameters.default`）**：
   - `slotCount = 22`（仅用于基准圆环周长 `C = 22 * (180 + 18) = 4356`，`R = C / (2π) ≈ 693.28`）
   - `cardHeight = 300`，`cardGap = 18`，`nearPlane = 140`
   - `perspective = 1500`（范围 `900..2400`）
   - `depthBlur = 2`（范围 `0..30`，已从初版 `14px` 下调至 `2px` 保持侧卡清晰层次）
   - `farFade = 0.96`（范围 `0..1`，即 `96%`，已从 `50%` 上调使背面远卡彻底柔和退隐）
   - `cornerRadius = 32`（范围 `0..60`，超椭圆指数 `4`）
2. **不等宽卡片弧长轨道（`RingCardTrack`，横图零裁切）**：
   - 每张卡共享统一高度 `cardHeight = 300`，宽度按素材自然比例计算：`cardWidth = round(cardHeight * clamp(aspect, 0.52, 2.25))`（竖图约 `180`、方图 `300`、4:3 `400`、16:9 `533`）。
   - 用前缀和数组存储每个索引的弧长中心 `centerArc[i]` 与半宽 `halfW[i]`，相邻卡片边缘沿圆弧间隙严格等于 `cardGap = 18`；二分查找 `O(log N)` 定位最近卡吸附。
   - **背面接缝平滑淡出**：当素材数少于一整圈时自然排布不重复铺假图；超过一整圈时支持无限循环，在背面 `±π` 接缝区域（`|angle| > π * 0.78`）平滑淡出到背景色，避免硬跳变。
3. **窗口双向自适应缩放（横向铺满 ~94%）**：
   - 外部圆环精确投影半宽：`halfW_1x = R * P / sqrt(P * P + 2 * P * R)`。
   - 目标缩放：`cardScale = clamp(min((viewportW * 0.94 * 0.5) / halfW_1x, (usableH * 0.78) / cardHeight), 0.34, 2.8)`。
   - 鼠标拖拽位移、惯性速度与滚轮增量一律除以 `cardScale`，确保任意窗口大小下 1:1 跟手。
   - 中央清晰区半宽随当前居中卡片宽度动态插值：`sharpHalf = min(viewportW * 0.5 * 0.78, max(110, frontCardWidth * 0.54) * cardScale)`，确保宽横图居中时左右两端不被景深误糊。

---

### 2.2 小红书链接解析与原生 3:4 封面信息流卡片

1. **URL 识别与分享文案提取（`XiaohongshuURLParser`）**：
   - 域名白名单：`xiaohongshu.com`、`www.xiaohongshu.com`、`m.xiaohongshu.com` 及短链 `xhslink.com` / `www.xhslink.com`。
   - 支持路径：
     - `/explore/<noteID>`
     - `/discovery/item/<noteID>`
     - `/user/profile/<userID>/<noteID>`（注意：`/user/profile/<userID>` 无 `<noteID>` 为个人主页/收藏列表，**不可**解析为单篇笔记）
     - `xhslink.com/<path>`（需跟踪 HTTP 重定向解析出真实 `noteID` 与 `xsec_token`）
   - 笔记 ID 校验：`^[a-zA-Z0-9]{16,40}$`。
   - **保留查询参数 + 去重键解耦**：存储的 `sourceURL` 与 `originalURL` **必须保留** `xsec_token` 和 `xsec_source`（否则浏览器重新打开可能 404），但规范去重键统一为 `xhs:<noteID.to_lowercase()>`，不受 token 轮换影响。
2. **元数据解析（`XiaohongshuPostResolver`）**：
   - 请求头携带标准桌面浏览器 `User-Agent`、`Accept-Language: zh-CN,zh;q=0.9`、`Referer: https://www.xiaohongshu.com/`。
   - **主解析路径**：提取 HTML 内 `window.__INITIAL_STATE__ = {...}` 平衡大括号 JSON，**先运行字符串感知的裸 `undefined -> null` 清洗器**（跳过双引号字符串内部），再交给 `serde_json` 反序列化。
   - 读取 `note.noteDetailMap[noteId].note`（或回退首个有效项 / `note.note`）：
     - `title` -> `articleTitle`；`desc` 清洗 `[话题]#` 后 -> `bodyText`；
     - `user.nickname` -> `authorName`；`user.redId ?? user.userId` -> `authorHandle`（**UI 展示规则**：若 `authorHandle` 为 24 位十六进制内部 `userId`、`xiaohongshu` 或与 `authorName` 相同，副标题 `displayHandleLine` 返回 `None` 不展示乱码 ID）；
     - `interactInfo.{likedCount, commentCount, collectedCount/shareCount}` 使用中文计数解析（支持 `1.2万` / `3.5千` / `10万+` / 逗号千分位）；
     - `imageList` 优先取 `imageScene == "WB_DFT"`（高清原图）作 `url`，`WB_PRV` 作 `thumbnailURL`，全部 `http://` 升级为 `https://`；
     - 视频笔记从 `video.media.stream.{h264, av1, h265}` 取 `masterUrl`/`backupUrls`，兜底 `https://sns-video-bd.xhscdn.com/<video.consumer.originVideoKey>`。
   - **兜底路径**：若 `__INITIAL_STATE__` 缺失，解析多条 `meta[property/name="og:image"]`、`og:title`（剥离尾部 ` - 小红书`）、`og:description`；若命中验证/404 拦截页（如“你访问的页面不见了”“安全限制”“登录查看”），直接拒绝不写垃圾卡片。
   - **防盗链下载头**：拉取任何 `*.xhscdn.com` 或 `*.xiaohongshu.com` 媒体图、视频、作者头像时，**必须附带 `Referer: https://www.xiaohongshu.com/`**（包括 Rust 后端下载与前端 Quick Look 图片代理/加载）。
3. **原生小红书竖版卡片制图（`900×1440`）与 Quick Look**：
   - 总画布 **`900 × 1440`**（纵横比 `0.625`，在瀑布流 clamp 区间 `[0.55, 2.15]` 内零裁切完整显示）：
     - **上方封面区（`900 × 1200`）**：严格竖版 **3:4** `aspect-fill` 满铺封面；多图笔记左上角绘制半透明深色胶囊 `N 图`（避开画廊右上角 `小红书` 徽标）；视频笔记居中绘制半透明圆形播放角标。
     - **底部分割线 + 白色信息栏（`900 × 240`）**：`#FFFFFF` 纸白背景 + `#EFEFEF` 顶分割线 + `#E5E7EB` 外描边；最多 2 行加粗标题（`articleTitle`，无标题时取 `bodyText` 首段）+ 底部圆形作者头像与昵称 + 右对齐 `♥ <likes>`。
     - **纯文字无图兜底**：同样保持 `900 × 1440` 尺寸，顶部 `#FF2442` 红条 + 作者头 + 标题与正文节选 + 底部互动指标。
   - **Quick Look 预览**：
     - 照片附件优先加载 `attachment.url`（高清 `WB_DFT`）而非低清 `thumbnailURL`；
     - 小红书多图（2 列网格）每个网格项按 `aspect-ratio: 3 / 4` 对齐裁剪展示，单图按 `object-fit: contain` 最大高度 `520px` 完整展示（不裁长图文）；
     - 保留单张与「全部提取为独立素材」按钮，平台胶囊色 `#FF2442`，名词使用「笔记」。
   - **旧素材无感后台迁移（`upgradeLegacyXiaohongshuCoversIfNeeded`）**：
     - 启动完成首次列表加载后在后台异步扫描 `platform == xiaohongshu && (pixelWidth != 900 || pixelHeight != 1440)` 的历史记录，重新生成 `900×1440` 卡片并写入缩略图与数据库，完成后失效内存缩略图缓存并刷新画廊；
     - **防降级规则**：若笔记原本有声明图片附件但当前离线拉图失败，**跳过该条目**留待下次联网迁移，绝不将其降级成纯文字卡。

---

### 2.3 本机扩展桥接服务（`127.0.0.1:41937`）与免配置自动配对协议

Windows 侧在 Rust Core 中启动轻量本地 HTTP 服务（推荐 `axum` / `tokio::net::TcpListener`，仅绑定 `127.0.0.1`，默认端口 `41937`，占用时顺序尝试 `41938..41946`），**严格对齐以下协议**即可直接无缝兼容 `Resources/BrowserExtension/`：

| Method & Path | 鉴权要求 | 说明与关键字段 |
| :--- | :--- | :--- |
| `OPTIONS *` | 无（CORS 预检） | 返回 `Access-Control-Allow-Methods: GET, POST, OPTIONS`、`Access-Control-Allow-Headers: Authorization, Content-Type, Accept, X-Charkle-Extension`、`Access-Control-Allow-Private-Network: true`、`Vary: Origin`；仅当 `Origin` 为 `chrome-extension://`、`safari-web-extension://`、`moz-extension://`、`http://127.0.0.1*`、`http://localhost*` 时回显 `Access-Control-Allow-Origin` |
| `GET /api/v1/health` | 公开（无敏感数据） | `{ "ok": true, "app": "charkle-windows", "name": "Charkle Windows", "port": 41937, "autoPair": true }`（**绝不**返回 `token`） |
| `POST /api/v1/auth/local-pair` | **严格扩展来源 + 自定义头** | **同机免配置自动配对接口**（见下方安全红线）。成功返回 `200`：`{ "ok": true, "app": "charkle-windows", "name": "Charkle Windows", "port": 41937, "serverUrl": "http://127.0.0.1:41937", "token": "<bridgeToken>" }` |
| `GET /api/v1/auth/status` | 可选 Bearer | 恒定时间比对 Bearer Token，返回 `{ "initialized": true, "authenticated": <bool>, "app": "charkle-windows", "user": { "id": "local-windows", "username": "desktop", "displayName": "Charkle Windows", "role": "owner" } \| null, "sessionCount": 1 \| 0 }` |
| `GET /api/v1/folders` | 必须 Bearer | `{ "folders": [{ "id", "name", "parentID", "sortOrder", "assetCount" }] }` |
| `POST /api/v1/folders` | 必须 Bearer | 请求 `{ "name", "parentID"?: string\|null, "reuseExisting"?: bool }`；同名同父级且 `reuseExisting: true` 时返回 `200 { "folder", "reused": true }`，新建返回 `201 { "folder", "reused": false }` |
| `GET /api/v1/boards` | 必须 Bearer | `{ "boards": [{ "id", "title", "itemCount" }] }` |
| `GET /api/v1/assets/existing-sources` | 必须 Bearer | `{ "count": N, "sources": [...], "canonicalKeys": ["x:<id>", "xhs:<id>", ...] }`，支撑扩展秒级增量去重 |
| `POST /api/v1/assets/ingest` | 必须 Bearer | 请求体上限 `48MB`，支持 `inputs` 数组项类型：`webURL`、`imageData`（base64/dataURL）、`textSnippet`、`colorSwatch`、`socialBookmark`（预提取结构化贴文负载，可选 `coverDataUrl` 与 `tags`）；支持 `targetFolderID`、`targetBoardID`、`skipDuplicates: bool`；返回 `201`（全跳重返回 `200`）`{ "assets": [...], "created": N, "skipped": M }` |
| `POST /api/v1/assets/upload` | 必须 Bearer | `multipart/form-data`（`file` + 可选 `targetFolderID` / `targetBoardID` / `sourceURL`），大图片超 14MB JSON 阈值时自动走此路由 |

#### `POST /api/v1/auth/local-pair` 安全红线（必须严格执行）
1. **默认开启、用户可关**：持久化开关 `allowLocalAutoPair`（默认 `true`）；关闭时返回 `403 { "code": "AUTO_PAIR_DISABLED", "error": "..." }`。
2. **仅允许浏览器扩展 `Origin`**：`Origin` 请求头**必须**以 `chrome-extension://`、`safari-web-extension://` 或 `moz-extension://` 开头；**拒绝**一切 `http://`、`https://`（包括 `http://localhost` 与 `http://127.0.0.1` 网页！）以及缺少 `Origin` 的请求，返回 `403 { "code": "INVALID_ORIGIN" }` 且**不附带** `Access-Control-Allow-Origin`。
3. **强制非简单自定义头**：必须携带 `X-Charkle-Extension: 1`，缺失返回 `403 { "code": "MISSING_EXTENSION_HEADER" }`（强迫浏览器执行 CORS 预检，彻底阻断表单/脚本 CSRF）。
4. **桌面端设置页 UX（防呆设计）**：
   - 顶行展示本地桥接状态徽标（`已就绪` / `已暂停`）+ 总开关，副标题明确提示「装好扩展后自动直连，无需填写地址或令牌」。
   - 次行提供「同机扩展自动免密配对」开关（附说明仅限本机浏览器扩展来源，外部网页一律拦截）。
   - 提供「Chrome / Edge / Arc / Brave 扩展」一键在资源管理器中定位内嵌 `BrowserExtension` 目录的按钮与 3 步安装折叠指南。
   - **手动服务地址与访问令牌收进底部「高级」折叠区**（保留显示/复制/重置按钮），不给普通桌面用户制造配置焦虑。
   - 每次写入新素材后通过 ~`450ms` 防抖事件通知 Tauri 前端刷新画廊与目标情绪板，并弹轻提示「浏览器扩展已导入 N 项素材」。

---

## 3. Round 6 新增 7 条实测踩坑清单（Windows & Web 务必避开）

### 坑 13：X 新版将书签入口合并为「历史 / X」，SPA 改写 URL 导致路径白名单误判
- **现象**：用户已打开 X 收藏/书签页（左侧导航为「历史」、顶部双标签「书签 | 喜欢」），扩展弹窗顶部显示「X 书签收藏页」，但点击「一键扫描并批量导入」后内容脚本却报错「请先打开 X 书签页或小红书收藏页」。
- **根因**：X 将书签页通过 SPA `history.replaceState` 路由到 `/i/history*` 或 `/<handle>/bookmarks`，浏览器 `tabs.query` 的 URL 可能滞后，而内容脚本旧白名单只认 `/i/bookmarks` 与 `/*/likes`。
- **正确做法**（已在 `Resources/BrowserExtension/` 修复）：
  - 路由同时覆盖 `/i/bookmarks*`、`/i/history*`、`/*/bookmarks`、`/*/likes`、`/*/history`、`/i/lists/*`；
  - 结合实时 DOM 信号（`[role="tab"][aria-selected="true"]` 文本、`document.title`、`main h2[role="heading"]`）精准区分书签/喜欢；
  - 在 `x.com` / `xiaohongshu.com` 域名下若存在推文/笔记卡片允许直接导入当前页列表（但悬浮启动按钮与自动切 Tab 仅在真正的收藏/历史/个人页触发，不打扰正常刷信息流）。

### 坑 14：批量导入消息 `START_BOOKMARK_IMPORT` 若 await 完整滚动循环，会冻结弹窗并触发消息通道超时
- **现象**：点击一键导入后按钮一直卡在「正在启动…」，多分钟后扩展消息端口断开。
- **正确做法**：`START_BOOKMARK_IMPORT` 必须在 `< 5ms` 内同步初始化任务状态、呼出页面内 Shadow DOM 进度 HUD、以 detached 异步循环启动采集并**立即同步 `sendResponse({ ok: true, job })`**；后续实时进度通过 `BOOKMARK_JOB_STATUS_PUSH` -> `BOOKMARK_JOB_UPDATE` 推送，关闭弹窗也不中断采集。

### 坑 15：页面内隐藏 `<iframe>` 劫持 `tabs.sendMessage`
- **现象**：X / 小红书页面嵌套了第三方登录或广告 iframe，消息发到子帧导致读取到错误 `window.location.href`。
- **正确做法**：内容脚本顶部第一行强制 `if (window !== window.top) return;`，且弹窗与后台向标签页发消息时显式传递 `{ frameId: 0 }`（兼容不支持 options 的运行时兜底）。

### 坑 16：扩展弹窗「抓图」网格在 `max-height` 下使用 `aspect-ratio: 1/1` 导致 WebKit 纵向严重挤压重叠
- **现象**：扫描到 12 张及以上图片时，缩略图上下层层叠压，分辨率角标被下一行盖住，图片越多挤得越严重。
- **根因**：`display: grid` 在有界 `max-height` + `overflow-y: auto` 下若未声明 `grid-auto-rows` 与 `align-content: start`，WebKit 会把隐式行高按总行数压缩，而 `aspect-ratio: 1/1` 的 `<button>` 仍按正方形绘制并向下溢出。
- **正确做法**：显式声明 `grid-template-columns: repeat(3, minmax(0, 1fr))`、`grid-auto-rows: 103px`、`align-content: start`，`.image-tile` 设固定 `height: 103px; appearance: none;`，图片 `position: absolute; inset: 0; width: 100%; height: 100%; object-fit: cover;`。

### 坑 17：小红书 `xsec_token` 每次访问会轮换，直接按 URL 去重会反复重复导入
- **正确做法**：存储的 `sourceURL` 保留原链接里的 `xsec_token` / `xsec_source` 保证外链可打开，但去重索引（`existing-sources` 与 `skipDuplicates`）必须按 `xhs:<noteID>` 计算；推文同理按 `x:<tweetID>`。

### 坑 18：小红书 CDN 防盗链 403 与 `__INITIAL_STATE__` 裸 `undefined` 解析失败
- **正确做法**：
  - 所有 `*.xhscdn.com` / `*.xiaohongshu.com` 媒体与头像请求必须带 `Referer: https://www.xiaohongshu.com/`；
  - 解析 `window.__INITIAL_STATE__` JSON 前必须做字符串感知的裸 `undefined -> null` 替换，不可用简单全局正则（防止破坏正文字符串里的 `"undefined"`）。

### 坑 19：小红书卡片改成 3:4 后，不能把用户已解析的历史素材留在旧比例，也不能丢失标题
- **正确做法**：
  - 画廊卡片采用小红书原生结构：**上方严格竖版 3:4 封面（`900×1200`）+ 下方 `240px` 白色标题/作者/点赞栏**（总尺寸 `900×1440`），避免无标题看不清内容，也避免套用 X 横向推文卡裁扁封面；
  - 随版本附带幂等后台自动迁移任务，启动时静默把历史旧尺寸小红书卡片升级为 `900×1440` 并刷新缩略图缓存；离线拉图失败时保留原卡不降级。

---

## 4. Windows 侧验收检查清单

- [ ] **3D 环形画廊**：默认参数为 `1500px / 2px / 96% / 32px`；放大/缩窄窗口自动 ~94% 横向铺满；横图（16:9 / 4:3）与竖图混排零裁切；静止 0% GPU。
- [ ] **小红书解析与卡片**：粘贴 `/explore/<id>`、`xhslink.com` 口令与扩展批量同步均可解析多图、视频与中文计数；画廊显示为 `900×1440`（上方 3:4 封面 + 下方加粗标题/作者/点赞），Quick Look 显示高清原图与 3:4 多图网格；旧尺寸小红书素材启动后自动无感升级。
- [ ] **本地扩展桥接与免配置直连**：
  - 安装 `Resources/BrowserExtension/` 到 Edge / Chrome 后，**无需任何地址或令牌配置**，点击插件直接显示 `Charkle Windows` 已连接并同步文件夹/情绪板；
  - `POST /api/v1/auth/local-pair` 用 `Origin: https://evil.example` 与 `Origin: http://127.0.0.1:3000` 测试均返回 `403`；关闭自动免密开关后同样返回 `403 AUTO_PAIR_DISABLED` 且插件自动展开手动令牌框；
  - 关闭 Charkle 应用后点击插件出现清晰的防呆两步提示与「一键自动连接」按钮，打开应用后点按钮即恢复；重置令牌或端口顺延后插件自动自愈重连。
- [ ] **抓图与收藏批量导入**：抓图网格 12–60 张图片整齐 3 列无挤压重叠；X 新版「历史 / X」书签/喜欢与小红书收藏页均可一键滚动采集、去重与暂停/停止保存。
