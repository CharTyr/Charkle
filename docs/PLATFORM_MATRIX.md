# 跨端版本、功能对齐矩阵与协作待办（PLATFORM MATRIX）

> 本矩阵用于多人协作时的**进度对齐与需求交接**：清晰标注每个平台当前版本号、各项能力落地状态、共享核心影响面以及待认领的跨端对齐任务单。

---

## 1. 各平台与组件当前状态总览

| 平台 / 组件 | 代码目录 | 当前版本 | 底层技术栈 | 发布形态 |
| :--- | :--- | :--- | :--- | :--- |
| **macOS 原生端** | `Sources/` | **`v1.5.1`**（Build 13） | Swift 6.2 · SwiftUI + AppKit + Metal · `CharkleCore` | `Charkle-*-arm64.dmg` + 应用内自更新 |
| **iOS / iPadOS 原生端** | `ios/` | **`v1.5.1`**（Build 13） | Swift 6.2 · SwiftUI + UIKit · 共享 `CharkleCore` | Xcode / TestFlight / IPA |
| **Windows 原生端** | `windows/` | **`v1.5.1`** | Tauri v2 · Rust 1.85 (`charkle-core`) · React 19 Fluent 2 | `Charkle_*_x64-setup.exe`（NSIS）+ 应用内自更新 |
| **Android 原生端** | `android/` | **`v1.5.0-alpha01`**（已合入主干，持续迭代） | Kotlin · Jetpack Compose M3 Expressive · UniFFI 共享 `charkle-core` | Debug / Release APK（arm64-v8a / x86_64） |
| **Web / Cloudflare Workers** | `web/` | **`v1.0` + R4 / R2 演进** | TypeScript · Node.js `node:sqlite` + Hono + React 19 / Cloudflare DO + R2 | Docker 镜像 / Cloudflare Workers |
| **浏览器扩展** | `Resources/BrowserExtension/` | **`v1.3.0`** | Manifest V3（零构建 JS）+ macOS Safari `.appex` | 随桌面包内置 / Chromium 解压加载 |
| **Figma / FigJam 桥接** | `Resources/FigmaPlugin/` ≡ `web/figma-plugin/` | **`v1.0`** | Figma Plugin API (`dynamic-page`) | 随桌面与 Web 包内置 |
| **CLI & MCP Server** | `Sources/CharkleCLI/`、`windows/crates/charkle-cli/`、`web/packages/server/` | **MCP v2（20 工具）** | JSON-RPC 2.0 stdio / HTTP + 低 Token 短 ID & Contact Sheet | `charkle-cli` / `charkle-cli.exe` / `npm run mcp` |

---

## 2. 全平台核心功能对齐矩阵

图例：`✅` 已上线 · `🚧` 开发/对齐中 · `📋` 已出任务单待认领 · `—` 平台不适用

| 能力模块 | macOS (`v1.5.1`) | iOS/iPadOS (`v1.5.1`) | Windows (`v1.5.1`) | Android (`alpha`) | Web / CF Workers |
| :--- | :---: | :---: | :---: | :---: | :---: |
| **纯图虚拟化瀑布流 & 锚定双指/滚轮缩放** | ✅ | ✅ | ✅ | 🚧 | ✅ |
| **多画廊视图（瀑布流 / 等高 / 胶片 / 3D 环形）** | ✅（4 视图含 Metal 3D 环） | ✅（瀑布流 + 预览胶片条） | ✅（4 视图含 3D 环） | 🚧（瀑布流 + 胶片条） | ✅（3 视图） |
| **收件箱清理台（快捷键 / 逐张归档 / 推荐目录）** | ✅（`1–9` 闪电归档） | ✅（逐张归档 / 瀑布流双模） | ✅（`1–9` 闪电归档） | 🚧（手势归档 + 作品主色融合） | ✅ |
| **统一搜图（FTS5 + 拼音 + 离线 OCR + CIELAB 筛色 + 相似图）** | ✅（Apple Vision） | ✅（Apple Vision） | ✅（WinRT OCR + 本地指纹） | 🚧（ML Kit + Rust 指纹） | ✅（FTS5 + 颜色） |
| **Quick Look 全格式预览（图/GIF/视频/音频/PDF/MD/3D/社媒）** | ✅（同步 300pt 检查器） | ✅（原图缩放 + 检查器） | ✅（同步 300px 检查器） | 🚧（Zone B 作品主色 + 原色校对） | ✅（同步 300px 检查器） |
| **视频书签（YouTube / B站）与通用网页批量提取** | ✅ | ✅ | ✅ | 🚧（复用 Rust Core） | 📋 |
| **视频书签零下载内联流式播放 + 设当前帧为封面（v1.5.1）** | ✅ | ✅ | ✅ | 📋 | 📋 |
| **双模情绪板工作室（自动 ⇄ 自由、便签、分组、连线、手绘）** | ✅ | ✅ | ✅ | 🚧 | ✅ |
| **情绪板互通导出（高清 PNG / `.charkleboard` Figma / PureRef `.pur`）** | ✅（全部 3 种） | ✅（全部 3 种） | ✅（全部 3 种） | 🚧（复用 Rust Core） | ✅（PNG + `.charkleboard`） |
| **Pinterest 无限 2D 空间浏览器、托盘与按板批量导入** | ✅ | ✅ | ✅ | 🚧（复用 Rust Core） | — |
| **无 AI 全媒体智能去重（8 类媒体、保最高质量、无损合并）** | ✅ | ✅（Core 能力） | ✅ | 🚧（复用 Rust Core） | 📋 |
| **`.eaglepack` / `.library` 素材包无损导入** | ✅ | ✅（Core 能力） | ✅ | 🚧（复用 Rust Core） | 📋 |
| **多后端 `/.charkle/` 同步（GDrive / iCloud / WebDAV / Local + 防复活）** | ✅（含 `gdirect`） | ✅（含 iCloud 原生容器） | ✅（含 Win iCloud / `gdirect`） | 🚧（GDrive / WebDAV / SAF） | ✅（GDrive / WebDAV / R2） |
| **平台原生零摩擦采集** | ✅（刘海浮窗 + 全局截图/剪贴板） | ✅（Share Extension + 相册/相机） | ✅（顶边抽屉 + OLE 拖出 + 全局截图） | 🚧（ShareActivity + 磁贴 + 微件） | ✅（浏览器扩展 / 拖拽） |
| **同机免密浏览器扩展桥接（6 平台社媒批量采集）** | ✅（Safari + Chromium） | — | ✅（Chromium / Edge） | — | ✅（REST Token 连接） |
| **独立 CLI & 低 Token MCP Server（20 工具）** | ✅（`charkle-cli`） | — | ✅（`charkle-cli.exe`） | — | 🚧（见 MCP v2 任务单） |

---

## 3. 共享核心与跨端耦合速查表

多人协作时，修改下表左列路径**必须**通知或验证右列所有受影响端：

| 修改路径 | 直接受影响端 | 必须遵守的兼容约束 |
| :--- | :--- | :--- |
| `Sources/CharkleCore/` | **macOS** + **iOS/iPadOS** | 平台条件编译 `#if os(macOS)` / `#if os(iOS)`、禁止 `import SwiftUI`、向后兼容 `Codable` |
| `windows/crates/charkle-core/` | **Windows** + **Android** | 零 Win32/Tauri 依赖、通过 `traits/mod.rs` 注入平台能力、保持 UniFFI 导出兼容 |
| `/.charkle/` 线协议（`SyncOperations` / `swift_codec`） | **全部 5 端** | Cocoa Reference Epoch 秒数、大写 RFC-4122 UUID、未知字段/枚举值向后容错、不可删墓碑逻辑 |
| `Resources/BrowserExtension/` | **macOS Safari/Chromium** + **Windows** + **Web** | 保持 MV3 零构建、Safari 经典兼容（`build-safari-extension.sh`）、通过 `extension.test.mjs` |
| `Resources/FigmaPlugin/` | **macOS** + **Windows** + **iOS** + **Web** | 必须与 `web/figma-plugin/` 逐字节一致，且通过 `node scripts/test-figma-plugin.cjs` |
| `DESIGN.md` | **全部 5 端** | 视觉 Token、禁止紫罗兰 AI 渐变、中性画布底色、交互与文案底线 |

---

## 4. 当前活跃任务单清单（`.trellis/tasks/`）

以下任务单位于仓库 `.trellis/tasks/`，新成员可直接按需认领或查看历史交接背景：

### 当前待推进 / 进行中重点任务
| 任务目录 | 目标平台 | 状态 | 核心内容 |
| :--- | :--- | :--- | :--- |
| [`11-27-android-m3-expressive-app`](../.trellis/tasks/11-27-android-m3-expressive-app/prd.md) | Android | **主干已落地，持续完善** | Phase 0–3：UniFFI 桥接 `charkle-core` + Material 3 Expressive 原生 UI + 对齐 iOS v1.5 能力 + Android 原生分享/磁贴/Glance 微件 |
| [`11-23-web-windows-mcp-cli-v2-parity`](../.trellis/tasks/11-23-web-windows-mcp-cli-v2-parity/prd.md) | Web | **待对齐** | Web 端 `external-agent-service.ts` 与 `mcp-stdio.ts` 补齐 20 工具 MCP v2 契约（Windows 侧已在 `v1.2.2+` 完成） |
| [`11-23-web-design-motion-polish`](../.trellis/tasks/11-23-web-design-motion-polish/prd.md) | Web | **部分完成/待收口** | Web 端 `DESIGN.md` 交互细节、动效与桌面端体验持续对齐 |
| [`11-24-web-windows-xhs-and-bookmark-sync-extension`](../.trellis/tasks/11-24-web-windows-xhs-and-bookmark-sync-extension/prd.md) | Web | **Web 侧待对齐** | Web 端小红书解析与扩展同步对齐（Windows 侧已在 `v1.1.0–v1.3.0` 完成） |

### 已完成落地、保留作参考归档的 Windows 历史交接单
以下任务单对应能力均已合入 `main` 的 `windows/` 目录（可作为代码实现参考，后续可按需用 `task.py archive` 归档）：
- `11-24-windows-macos-round5-parity-and-pitfalls` & `11-24-windows-macos-round6-xhs-extension-ring-parity`（已合入 `v1.1.0–v1.2.0`）
- `11-25-windows-macos-v122-cli-mcp-shelf-parity`（已合入 `v1.2.2`）
- `11-25-windows-eaglepack-library-importer` & `11-25-windows-v130-social-collector-and-smart-dedup`（已合入 `v1.3.0`）
- `11-26-windows-v140-multibackend-icloud-and-sync-deletion-parity`（已合入 `v1.4.0`）
- `11-27-windows-v141-pinterest-spatial-tray-and-board-import`（已合入 `v1.4.1`）
- `11-27-windows-v150-unified-search-pureref-video-bookmarks-and-universal-parser`（已合入 `v1.5.0`）
- `11-27-windows-v151-video-streaming-playback-and-frame-cover`（已合入 `v1.5.1`，`c620085`）
