# Charkle for Windows (`v1.5.1`)

Native-grade **Windows desktop client** for Charkle built with **Tauri v2 + pure Rust Core + React 19 (Fluent 2)**, delivering lossless bidirectional `/.charkle/` sync parity with Charkle for macOS, iOS/iPadOS, Android, and Web.

> **开发必读**：[文档总索引](../docs/README.md) · [协作指南](../CONTRIBUTING.md) · [Windows 工程护栏 `windows/AGENTS.md`](AGENTS.md) · [Windows 架构规范](../.trellis/spec/windows/index.md) · [Fluent 2 设计规范](../.trellis/spec/windows/fluent2-design-system.md)

---

## Workspace Architecture

```text
windows/
├── Cargo.toml                       # Cargo workspace root (Rust 1.85, edition 2021)
├── crates/
│   ├── charkle-core/                # 100% OS-agnostic Rust domain core (ALSO shared by Android via UniFFI!)
│   │                                # SQLite WAL+FTS5+Pinyin, 8-kind Media Pipeline, EXIF/AI prompt,
│   │                                # Smart Dedup, .eaglepack/.library & PureRef .pur, Pinterest,
│   │                                # Multi-backend /.charkle/ HLC Sync, Cloud AI & 20-tool MCP service
│   ├── charkle-platform-win/        # Win32/WinRT native seams: Mica/Acrylic, DPAPI/Credential Manager,
│   │                                # WinRT OCR, Shell thumbnails (STA COM), Top-Edge Shelf, OLE DoDragDrop,
│   │                                # multi-DPI capture, clipboard listener, cross-process wake event
│   └── charkle-cli/                 # Standalone charkle-cli.exe (CLI subcommands + JSON-RPC MCP stdio)
├── src-tauri/                       # Tauri v2 host, typed IPC commands, charkle-media:// HTTP 206 stream,
│                                    # tray, global hotkeys, autostart, deep links, NSIS bundler config
├── ui/                              # React 19 + TypeScript + Tailwind v4 + Base UI + Zustand Fluent 2 UI
└── scripts/
    ├── sync-icons.mjs               # Sync shared duotone/layered SVG icons from macOS Resources
    ├── verify-windows.ps1           # Full pre-commit gate (icons + UI typecheck/test/build + fmt/clippy/test)
    └── build-release-nsis.ps1       # Release x64 NSIS installer with bundled charkle-cli.exe & Figma Plugin
```

> **重要共享核心提醒**：`windows/crates/charkle-core` 同时被 `android/rust/charkle-android-ffi` 直接依赖。修改 `charkle-core` 时必须保持 **零 Win32 / Tauri 依赖**，所有 Windows 平台 API 仅可写在 `crates/charkle-platform-win` 或 `src-tauri` 中。

---

## Shipped Capabilities (`v1.5.1`)

- **Fluent 2 原生桌面体验**：Windows 11 22H2+ Mica Alt / Acrylic 悬浮材质（Win10 及关闭透明效果时无损实色降级）、原生 Snap Layouts、可调宽度侧栏与 300px 检查器、应用内自动更新。
- **4 视图画廊与统一搜图**：纵向瀑布流（锚定缩放）、横向等高、胶片挑图与 3D 环形画廊；FTS5 + 中文拼音 + WinRT 离线 OCR + CIELAB 筛色 + 本机视觉相似检索；`Ctrl+J` 随处跳转与收件箱 `1–9` 闪电归档。
- **视频书签零下载流式播放与选帧设封面（`v1.5.1`）**：Quick Look 支持 YouTube / B站 / 视频网页书签的零下载两级内联流式播放（原生直链代理 + 官方 Embed 自动回退），并支持对本地视频和流式视频书签一键「设当前帧为封面」并同步跨端缩略图。
- **零摩擦原生采集与跨窗拖放**：屏幕顶边悬浮抽屉（含紧凑/瀑布模式与 `CharkleShelfDropCatcher`）、全局热键（`Alt+Shift+A/S/V`）、区域截图、剪贴板监听、支持 `Alt+Tab` 切窗的 OLE `DoDragDrop`（`CF_HDROP`）原图拖出。
- **双模情绪板与多格式互通**：自动排版 ⇄ 自由无限画布、高清 PNG / `.charkleboard`（Figma/FigJam）/ **PureRef `.pur`** 双向编解码、**`.eaglepack` / `.library`** 无损素材包导入、**无 AI 全媒体智能去重**。
- **Pinterest 空间探索 & 6 平台社媒扩展桥接**：无限 2D 空间浏览器 + 托盘 + 按 Board 批量导入；同机免密配对 Chromium/Edge 浏览器扩展（`Resources/BrowserExtension` `v1.3.0`）；视频书签与通用网页解析器。
- **多后端无损双向同步**：Google Drive（API v3 + 可选 `gdirect.exe`）、Windows iCloud Drive、WebDAV、挂载盘与纯本地目录，支持多后端并存与删除墓碑防复活。
- **独立 CLI & MCP**：随安装程序附带 `charkle-cli.exe`，支持低 Token 20 工具 MCP 协议。

---

## Quick Start & Verification

### Prerequisites
- Windows 11 22H2+ x64（或 Windows 10 1903+ x64 + WebView2 Runtime）
- Node.js 22+（LTS）
- Rust 1.85+（MSVC toolchain）
- Visual Studio 2022 C++ Build Tools（*Desktop development with C++*）

### Commands

```powershell
# 1. Sync icons & install UI dependencies
cd windows
node scripts/sync-icons.mjs
cd ui
npm install

# 2. Launch dev app with Vite hot reload (:1420)
npm run tauri dev

# 3. Full pre-commit verification gate (REQUIRED before PR / push)
cd ..
pwsh -File scripts/verify-windows.ps1

# 4. Build x64 NSIS Release installer
pwsh -File scripts/build-release-nsis.ps1
```
