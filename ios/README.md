# Charkle for iPadOS & iOS (`v1.5.1`)

Universal native SwiftUI + UIKit client for **iPadOS 18+** and **iOS 18+**, directly sharing [`Sources/CharkleCore`](../Sources/CharkleCore) and the lossless `/.charkle/` multi-backend bidirectional sync protocol with Charkle for macOS, Windows, Android, and Web.

> **开发必读**：[文档总索引](../docs/README.md) · [协作指南](../CONTRIBUTING.md) · [Apple Core 后端规范](../.trellis/spec/backend/index.md) · [跨端协议](../.trellis/spec/cross-platform/index.md)

---

## Capabilities (`v1.5.1`)

- **Universal Adaptive Shell**：
  - **iPad**：`NavigationSplitView` 侧栏（素材库、收件箱、最近、未标记、回收站、多级折叠文件夹、智能文件夹、标签云、同步状态）+ 多列纯图瀑布流 + 320pt 停靠检查器 + 外接键盘快捷键（`⌘N`、`⌘R`、`⇧⌘V`）。
  - **iPhone**：原生 Liquid Glass 变形悬浮底栏（`LiquidGlassMorphingTabBar`）与横向手势切换 + 上滑目录抽屉 + 沉浸全屏预览与层级目录选择器（`HierarchicalFolderPicker`）。
- **Multi-Source Capture & Share Extension**：
  - 系统分享扩展 **`CharkleShareExtension`**：从小红书、X、Safari、相册与文件 App 一键保存到收件箱或任意同步文件夹。
  - 应用内采集：相册多选（图/视频）、相机速拍、文件导入、一键剪贴板、小红书/X/YouTube/B站/通用网页链接解析与批量提取。
- **Browse, Visual Search & Video Preview**：
  - 全文 + 中文拼音 + 离线 OCR 检索、10 枚 `DESIGN.md` 标定色板 + 色轮 + 容差筛选、格式/比例/评分排序、Apple Vision 本机相似素材搜索。
  - 原生 `UIScrollView` 缩放协同预览、长图全宽滚动、EXIF / AI 绘图提示词查看；**v1.5.1 新增**视频书签零下载内联流式播放与本地/流式视频一键「设当前帧为封面」。
- **Moodboard Studio & Pinterest Spatial Explorer**：
  - 完整情绪板工作室（读写 `/.charkle/boards/<UUID>.json`，自由画布与自动排版切换、便签/分组/色卡/连线/手绘笔迹、导出高清 PNG / `.charkleboard` / PureRef `.pur`）。
  - **Pinterest 无限 2D 空间浏览器**（双指锚定连续缩放、托盘、WebView 登录桥接与按 Board 批量建文件夹导入）。
- **Multi-Backend Bidirectional Sync**：
  - 支持 **Google Drive**（RFC 8252 `ASWebAuthenticationSession` + PKCE `S256` + 共享目录协作）、**iCloud Drive**（原生容器）、**WebDAV** 与 **本地目录**多后端并存，渐进式缩略图优先加载、删除墓碑防复活、LRU 原图缓存上限与离线置顶。

---

## Quick Start in Xcode

1. Open `ios/CharkleMobile.xcodeproj` in Xcode 16+.
2. In **Signing & Capabilities** for both **`CharkleMobile`** and **`CharkleShareExtension`**, select your Apple Development Team (and update the bundle identifier prefix / App Group `group.com.charkle.mobile` when deploying to a personal physical device).
3. Select an iPad or iPhone simulator/device and press **Run (`⌘R`)**.

### Related Core Tests

```bash
swift test --filter MobileOAuthTests
swift test --filter MultiBackendAndICloudTests
```

---

## Setting Up Google Drive Sign-In on iOS / iPadOS

Google OAuth on iOS/iPadOS requires an **iOS OAuth Client ID** (PKCE with no client secret):

1. Open **Google Cloud Console → APIs & Services → Credentials → Create Credentials → OAuth client ID**.
2. Choose **iOS** as the application type and enter your app's Bundle Identifier (default `com.charkle.mobile`).
3. Download the `.plist` (or copy the generated `<prefix>.apps.googleusercontent.com` Client ID).
4. In the app, open **同步 → Google 账号与授权凭据**, import the `.plist` / `.json` file or paste the Client ID, then tap **使用 Google 账号登录**.

> Tip: For zero-config local builds, you may place your local `GoogleOAuthClient-iOS.plist` (gitignored, never commit) into `ios/CharkleMobile/` and include it in the app target's Copy Bundle Resources phase.
