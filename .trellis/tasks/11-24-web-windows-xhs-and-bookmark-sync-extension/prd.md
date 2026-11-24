# Web & Windows 同步任务：小红书链接解析 + X/小红书一键批量收藏导入扩展

> 权威参考：macOS 已完整落地并验证，参考 [`.trellis/spec/cross-platform/index.md`](../../spec/cross-platform/index.md) §5.9、[`Sources/CharkleCore/Media/XiaohongshuPostResolver.swift`](../../../Sources/CharkleCore/Media/XiaohongshuPostResolver.swift)、[`Sources/CharkleCore/Services/LocalExtensionBridgeServer.swift`](../../../Sources/CharkleCore/Services/LocalExtensionBridgeServer.swift) 及 [`Resources/BrowserExtension/`](../../../Resources/BrowserExtension/)。

## 1. Web 端跟进项 (`./web/`)
1. **`@charkle/shared` & `packages/server/src/media/resolvers/social.ts`**：
   - `SocialPlatform` 新增 `'xiaohongshu'`（展示名 `小红书`，标签色 `#FF2442`，名词 `笔记`）。
   - 解析 `xiaohongshu.com/explore/<id>`、`/discovery/item/<id>`、`/user/profile/<uid>/<id>` 及 `xhslink.com` 短链重定向，保留 `xsec_token` / `xsec_source`，去重键采用 `xhs:<noteID>`（与 `xsec_token` 轮换解耦）。
   - 解析 `window.__INITIAL_STATE__` 前需清洗字符串外的裸 JS `undefined` -> `null`，失败时回退多 `og:image` 提取并过滤失效/验证拦截页；下载 `*.xhscdn.com` 媒体与头像时携带 `Referer: https://www.xiaohongshu.com/`。
   - **3:4 封面 + 标题信息栏渲染**：小红书笔记的画廊卡片统一渲染为原生竖版信息流卡片（总尺寸 `900×1440`，`aspectRatio = 0.625`）：上方为严格竖版 **3:4（`900×1200`）** 满铺封面（多图左上角标 `N 图`，视频居中播放标），下方为 `240px` 白色信息栏保留加粗笔记标题（最多 2 行）+ 作者头像/昵称 + 右对齐点赞数；Quick Look 多图网格按 3:4 对齐并优先加载高清原图。
2. **`packages/server/src/api/routes-core.ts`**：
   - 新增 `GET /api/v1/assets/existing-sources` 返回 `{ count, sources, canonicalKeys }`，支撑浏览器扩展增量去重。
   - `POST /api/v1/folders` 支持可选 `reuseExisting: true`（同级同名复用）。
   - `POST /api/v1/assets/ingest` 支持 `skipDuplicates: true` 与 `type: 'socialBookmark'` 预提取结构化贴文负载，返回 `{ assets, created, skipped }`。
3. **`packages/extension/` & Cloudflare Worker 打包**：
   - 将 `Resources/BrowserExtension/` 的新增能力（`lib/xhs-parser.js`、X 2026 `/i/history*` 与书签/喜欢全路径 + DOM 识别、非阻塞启动 + `window !== window.top` 顶层帧隔离、同机 `POST /api/v1/auth/local-pair` 免配置自动配对与防呆引导、抓图网格 `grid-auto-rows: 103px` + `align-content: start` 修复 WebKit 纵向重叠）同步回 `web/packages/extension/` 并重新运行 `npm run cf:pack` 与 `node --test packages/extension/tests/extension.test.mjs`。

## 2. Windows 端跟进项 (`./windows/`)
1. **Rust Core (`charkle-core`)**：
   - `SocialPlatform` 增补 `Xiaohongshu`，实现 `XiaohongshuPostResolver`（同上 `__INITIAL_STATE__` + `undefined` 清洗 + `Referer` 下载头 + `xhs:<id>` 去重键 + **3:4 `900×1200` 封面海报**）。
   - 提供 `127.0.0.1:41937` 本地扩展桥接服务（与 macOS `LocalExtensionBridgeServer` 100% 协议一致，含 Bearer 恒定时间鉴权、CORS 白名单、`Private-Network` 头、`existing-sources` 增量去重，以及默认开启、仅限 `chrome-extension://` / `safari-web-extension://` / `moz-extension://` + `X-Charkle-Extension: 1` 的同机免密配对 `POST /api/v1/auth/local-pair`）。
2. **设置页与打包**：
   - 设置「插件与扩展」默认展示本地桥接状态 +「同机扩展自动免密配对」开关 + Edge / Chrome 扩展一键定位，将手动地址与访问令牌折叠进高级项，装完即用不增加配置负担（复用 `Resources/BrowserExtension/` 同一套源码）。
