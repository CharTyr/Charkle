# Charkle 灵感剪藏与批量收藏导入扩展（Safari & Chrome）

跨浏览器零构建灵感采集与收藏夹批量导入扩展，支持 **Safari（随 `Charkle.app` 原生内嵌）** 及 **Chrome / Arc / Edge / Brave**，可直连本机 **Charkle macOS 桌面端** 或 **Charkle Web 服务端**。

## 核心能力

- **一键批量导入小红书收藏 & X（推特）书签**：
  - 打开 `x.com/i/bookmarks`（含书签文件夹与喜欢列表）或 `xiaohongshu.com` 个人主页「收藏」/收藏专辑页，即可在页面右下角或扩展工作台「收藏导入」一键启动全自动滚动导入。
  - **自动增量去重**：导入前自动比对素材库已有记录，跳过已导入条目；开启「遇到连续已导入项时自动停止」后，后续增量同步数秒即可完成。
  - **小红书完整多图与正文提取**：在已登录浏览器会话内自动解析每条小红书笔记的完整轮播高清图、视频流、标签与正文，保留 `xsec_token` 来源链接。
  - **页面实时进度浮窗**：关闭工具栏弹窗不中断任务，支持随时暂停、继续或提前停止并保存已扫描条目。
- **全能单页剪藏**：自动识别小红书笔记、X / Threads / Bluesky 贴文、GitHub 仓库与普通网页书签，支持页面截屏、批量抓图、文字灵感、色卡取色、5 项右键菜单与跨站拖图收藏。

## 安装与连接

### Safari
1. 运行正式打包后的 `Charkle.app`（内置原生 Safari 扩展）。
2. 在 Charkle「设置 → 插件与扩展」点击 **打开 Safari 扩展设置**，勾选 **Charkle** 并允许在所有网站上使用。
3. 复制 Charkle 设置中的本机地址（默认 `http://127.0.0.1:41937`）与访问令牌，粘贴到扩展中并点击 **测试并保存**。

### Chrome / Arc / Edge / Brave
1. 打开 `chrome://extensions`（或对应浏览器扩展页），开启 **开发者模式**。
2. 点击 **加载已解压的扩展程序**，选择 Charkle 设置中定位的 `BrowserExtension` 目录。
3. 点击工具栏 Charkle 图标，点击 **自动检测本机桌面端** 并粘贴访问令牌即可直连。

## 测试

```bash
node --test Resources/BrowserExtension/tests/extension.test.mjs
```
