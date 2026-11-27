# Charkle 灵感剪藏与 6 平台社媒批量采集扩展（`v1.3.0`）

跨浏览器零构建（Manifest V3）灵感采集与批量收藏导入扩展，支持 **Safari（随 macOS `Charkle.app` 原生内嵌 `.appex`）** 及 **Chrome / Arc / Edge / Brave（macOS & Windows）**，可直连本机 **Charkle 桌面端** 或 **Charkle Web 服务端**。

> **开发必读**：[文档总索引](../../docs/README.md) · [协作指南](../../CONTRIBUTING.md) · [跨端扩展桥接契约](../../.trellis/spec/cross-platform/index.md)

---

## 核心能力

- **6 平台社媒作者画作与收藏批量采集**：
  - 覆盖 **X（推特）**、**Pixiv**、**Bluesky**、**Threads**、**Instagram** 与 **小红书**。
  - 支持在作者主页按推文 / 作品自动分目录批量采集全量高清原图与视频，以及在 `x.com/i/bookmarks`、小红书个人「收藏」/专辑页一键增量批量导入。
  - **自动增量去重**：导入前通过 `/api/v1/assets/existing-sources` 比对已有来源，支持「遇到连续已导入项时自动停止」，后续增量同步数秒完成。
  - **页面实时进度浮窗**：关闭弹窗不中断任务，支持随时暂停、继续或提前停止并保存已扫描条目。
- **克制工作室弹窗 UI 与全能单页剪藏**：
  - 自动识别小红书笔记、X / Threads / Bluesky / Pixiv / Instagram 贴文、GitHub 仓库、YouTube / B站视频与普通网页书签。
  - 支持页面截屏、批量抓图（WebKit 显式行高防重叠网格）、文字灵感、吸管取色、右键菜单与跨站拖图收藏。
  - 默认快捷键：`Alt+Shift+K` 打开面板，`Alt+Shift+C` 快捷收藏当前网页。

---

## 目录结构（零构建）

```text
Resources/BrowserExtension/
├── manifest.json            # MV3 清单（v1.3.0）
├── background.js            # 后台服务（Safari 兼容单文件打包入口）
├── content.js               # 页面注入脚本（抓图、进度浮窗、跨站拖图）
├── x-bridge-loader.js       # 社媒页面网络载荷桥接加载器
├── page-bridge.js           # 主世界 GraphQL/接口拦截桥
├── popup.{html,css,js}      # 工具栏弹窗 UI
├── options.{html,css,js}    # 独立设置页
├── lib/
│   ├── api.js               # 桌面桥接 / Web API 客户端与自动免密配对
│   ├── social-collectors.js # 6 平台社媒无 DOM 纯解析器
│   ├── x-author-media.js    # X/Twitter 作者媒体与按推文分目录引擎
│   ├── xhs-parser.js        # 小红书笔记解析器
│   ├── image-filter.js      # 批量抓图尺寸与过滤规则
│   ├── url-detect.js        # URL 与平台类型识别
│   └── storage.js           # 扩展状态持久化封装
└── tests/
    └── extension.test.mjs   # Node 原生单测套件（node --test）
```

---

## 安装与连接

启动本机 **Charkle macOS 或 Windows 桌面端**（默认监听回环地址 `127.0.0.1:41937–41946`）后，Safari 与 Chromium 扩展均支持**同机自动免密配对与断线自愈**：

### Safari（macOS）
1. 运行正式打包后的 `Charkle.app`（内置已签名 `CharkleSafariExtension.appex`）。
2. 在 Charkle「设置 → 插件与扩展」点击 **打开 Safari 扩展设置**，勾选 **Charkle** 并允许在所有网站上使用。
3. 保持桌面端运行即可自动配对；也可点击工具栏 Charkle 图标中的 **一键自动连接本机 Charkle**。

### Chrome / Arc / Edge / Brave（macOS & Windows）
1. 打开 `chrome://extensions`（或对应浏览器扩展页），开启 **开发者模式**。
2. 点击 **加载已解压的扩展程序**，选择本目录（`Resources/BrowserExtension`）或桌面端设置页定位的内置 `BrowserExtension` 目录。
3. 保持桌面端运行即自动完成免密配对。

### 连接自建 Charkle Web 服务
若关闭了「同机扩展自动免密配对」或需连接远程 **Charkle Web 服务端**，在弹窗展开 **手动配置 / 连接自建网页服务**（或打开扩展设置），填入服务地址与访问令牌并点击 **测试并保存**。

---

## 测试

```bash
node --test Resources/BrowserExtension/tests/extension.test.mjs
```
