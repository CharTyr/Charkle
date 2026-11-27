# 全平台本地开发、构建与测试手册（DEVELOPMENT）

本文档提供 **macOS、iOS/iPadOS、Windows、Android、Web / Cloudflare Workers、浏览器扩展与 Figma 插件** 的一站式环境搭建、开发运行、严格验证与本地凭据配置指南。

> 首次克隆仓库后，建议先初始化 Trellis 开发者身份（用于多人本地日志隔离，不会污染共享文件）：
> ```bash
> python3 ./.trellis/scripts/init_developer.py <your-name>
> ```

---

## 1. macOS 原生端

### 环境要求
- **系统与芯片**：macOS 15.0+（Apple Silicon `arm64` 主目标）
- **工具链**：Swift 6.2（Xcode 16+ 或对应 Command Line Tools）
- **可选**：Node.js 22+（用于跑扩展与 Figma 插件单测）、本地 Apple 代码签名证书（用于发布 `.app` / `.dmg` 与 Safari 扩展）

### 常用命令（仓库根目录执行）

```bash
# 严格零警告编译（含测试目标）与运行全量 Swift Testing 套件
swift build --build-tests -Xswiftc -warnings-as-errors && swift test --skip-build

# 定向运行单个测试套件（示例）
swift test --filter DriveSyncTests
swift test --filter PureRefCodecTests

# 构建本地可运行的签名 App 包（含 charkle-cli 与 CharkleSafariExtension.appex）
./scripts/build-app.sh release

# 一键重新编译并打包带背景图的安装镜像 dist/Charkle-<version>-arm64.dmg
./scripts/build-dmg.sh --rebuild

# 单独验证浏览器扩展与 Figma 插件
node --test Resources/BrowserExtension/tests/extension.test.mjs
node scripts/test-figma-plugin.cjs
```

### 本地关键目录与调试提示
- **产物目录**：`dist/Charkle.app`、`dist/Charkle-<version>-arm64.dmg`（均已 `.gitignore`）。
- **Safari 扩展**：`scripts/build-app.sh` 会自动调用 `scripts/build-safari-extension.sh` 将 `Resources/BrowserExtension/` 打包进 `Contents/PlugIns/CharkleSafariExtension.appex`。
- **编码红线**：动手前必读 [`AGENTS.md`](../AGENTS.md) §3 与 [`.trellis/spec/frontend/index.md`](../.trellis/spec/frontend/index.md) / [`.trellis/spec/backend/index.md`](../.trellis/spec/backend/index.md)（如快捷键修饰键掩码、零闪烁抽屉动画、`.borderlessButton` 的 `.fixedSize()` 等）。

---

## 2. iOS / iPadOS 原生端

### 环境要求
- **系统与工具**：macOS + Xcode 16+，目标系统 **iOS 18.0+ / iPadOS 18.0+**。
- **核心复用**：`ios/CharkleMobile.xcodeproj` 直接以本地 Swift Package 方式依赖根目录 `Sources/CharkleCore`，无需额外桥接编译步骤。

### 快速启动
1. 用 Xcode 打开 `ios/CharkleMobile.xcodeproj`。
2. 分别为 **`CharkleMobile`** 与 **`CharkleShareExtension`** 两个 Target 配置 **Signing & Capabilities → Team**；部署到个人真机时，按需调整 Bundle Identifier 前缀与共享 App Group（默认 `group.com.charkle.mobile`）。
3. 选择 iPhone / iPad 模拟器或真机，按 `⌘R` 运行。

### 相关核心测试
```bash
# 验证移动端 OAuth / 同步 / 共享核心逻辑
swift test --filter MobileOAuthTests
swift test --filter MultiBackendAndICloudTests
```

---

## 3. Windows 原生端

### 环境要求
- **系统**：Windows 11 22H2+ x64（推荐，完整支持 Mica / Acrylic 与 Snap Layouts）或 Windows 10 1903+ x64
- **工具链**：
  - Node.js 22+（LTS）
  - Rust `1.85+`（MSVC toolchain，详见 `windows/rust-toolchain.toml`）
  - Visual Studio 2022 C++ Build Tools（工作负载：*Desktop development with C++*）
  - Microsoft Edge WebView2 Runtime（Windows 11 默认自带）

### 常用命令（在 `windows/` 目录执行）

```powershell
# 1. 安装前端依赖并同步共享 SVG 图标
cd windows
node scripts/sync-icons.mjs
cd ui
npm install

# 2. 启动 Tauri 热重载开发模式（Vite 端口 1420）
npm run tauri dev

# 3. 完整提交前质量门禁（图标同步 + UI typecheck/vitest/build + cargo fmt/clippy/test）
cd ..
pwsh -File scripts/verify-windows.ps1

# 4. 打包生产级 x64 NSIS 安装程序（含 charkle-cli.exe sidecar 与 Figma 插件）
pwsh -File scripts/build-release-nsis.ps1
```

### 编码红线
- 动手前必读 [`windows/AGENTS.md`](../windows/AGENTS.md) 与 [`.trellis/spec/windows/fluent2-design-system.md`](../.trellis/spec/windows/fluent2-design-system.md)（重点：禁止跨进程操作 WebView2 子 HWND 的 OLE DropTarget、禁止 IPC 传 Base64 媒体、严格本机 `local_visual_descriptors` 隔离）。

---

## 4. Android 原生端

### 环境要求
- **JDK**：JDK 17 或 JDK 21（`JAVA_HOME`）
- **Android SDK & NDK**：Android Studio / Command-line Tools，安装 Platform 36/37、Build-Tools 与 Android NDK（`ANDROID_HOME`、`ANDROID_NDK_HOME`）
- **Rust 交叉编译**：
  ```bash
  rustup target add aarch64-linux-android x86_64-linux-android
  cargo install cargo-ndk
  ```

### 常用命令（仓库根目录执行）

```bash
# 仅重新交叉编译 Rust 核心（charkle-android-ffi）并刷新 UniFFI Kotlin 绑定
./android/scripts/build-rust-android.sh

# 一键全量校验：Rust 单测 -> cargo-ndk + UniFFI 绑定 -> Kotlin 单测 & Debug APK 编译
./android/scripts/verify-android.sh

# 构建 R8 混淆瘦身后的生产 Release APK（支持通过环境变量注入签名）
# 可选签名环境变量：CHARKLE_KEYSTORE_PATH / CHARKLE_KEYSTORE_PASS / CHARKLE_KEY_ALIAS / CHARKLE_KEY_PASS
./android/scripts/build-release-android.sh
```

> **环境变量说明**：`CHARKLE_ANDROID_ABIS` 默认为 `arm64-v8a`（真机）；在 x86_64 模拟器调试时可设为 `CHARKLE_ANDROID_ABIS="arm64-v8a x86_64"`。  
> **工作区隔离红线**：`android/rust/charkle-android-ffi` 通过相对路径引用 `windows/crates/charkle-core`，**绝不要将其加入 `windows/Cargo.toml` 的 workspace 成员**。

---

## 5. Web 与 Cloudflare Workers

### 环境要求
- **Node.js 22.13+**（使用原生内置 `node:sqlite`，无需编译 C++ SQLite 插件）
- **可选**：Docker（容器部署）、Cloudflare 账号与 Wrangler（Workers + Durable Objects SQLite + R2 部署）

### 常用命令（在 `web/` 目录执行）

```bash
cd web
npm install

# 本地全栈开发（API 服务 :3417 + Vite 前端 :5173）
npm run dev

# 全工作区类型检查、单测与生产构建
npm run typecheck
npm test
node --test packages/extension/tests/extension.test.mjs
npm run build

# 启动自托管生产服务 / 启动 MCP stdio 服务
npm start
npm run mcp
```

### Cloudflare Workers 专项命令（在 `web/` 目录执行）

```bash
# 预打包扩展与 Figma 插件 ZIP 到 packages/worker/src/generated/bundles.ts
npm run cf:pack

# 校验 Worker 类型 & 本地 workerd 仿真（含真实 DO SQLite + 本地 R2 模拟）
npm run cf:typecheck
npm run cf:dev

# 干跑部署校验 & 正式发布
npm run cf:dry-run
npm run cf:deploy
```

- 生产环境必需密钥通过 `npx wrangler secret put CHARKLE_VAULT_KEY --cwd packages/worker` 配置；本地仿真写入 `web/packages/worker/.dev.vars`（已忽略）。详细部署步骤见 [`web/README.md`](../web/README.md)。

---

## 6. 浏览器扩展与 Figma 桥接插件

### 浏览器扩展（`Resources/BrowserExtension/`）
- **零构建设计**：纯 ES Module / 原生 JS + CSS，修改后在浏览器扩展页点击「重新加载」即可生效。
- **单元测试**：
  ```bash
  node --test Resources/BrowserExtension/tests/extension.test.mjs
  ```
- **本地联调**：启动 macOS 或 Windows Charkle 桌面端（默认监听 `127.0.0.1:41937–41946`），在 `chrome://extensions` 加载 `Resources/BrowserExtension/` 即可自动免密配对。

### Figma / FigJam 桥接插件（`Resources/FigmaPlugin/` ≡ `web/figma-plugin/`）
- **双目录一致铁律**：修改 `Resources/FigmaPlugin/` 后必须同步复制到 `web/figma-plugin/`，并执行以下双检查：
  ```bash
  node scripts/test-figma-plugin.cjs
  diff -rq Resources/FigmaPlugin web/figma-plugin
  ```

---

## 7. 本地私密凭据与 OAuth 配置位置（均已 `.gitignore`）

Charkle 开源仓库**不含任何 OAuth 密钥、API Key 或签名证书**。团队成员按需在本地放置以下文件（全部已被 `.gitignore` 忽略，严禁强制 `git add -f`）：

| 用途 | 本地文件 / 存储位置 | 说明 |
| :--- | :--- | :--- |
| **macOS 开箱内置 Google OAuth** | `Resources/GoogleOAuthClient.json` | 存在时由 `scripts/build-app.sh` 自动打包进 `Charkle.app/Contents/Resources/`；也可不放置，运行时在应用「设置 → 同步」手动导入（存入系统 Keychain） |
| **iOS / iPadOS Google OAuth** | `ios/CharkleMobile/GoogleOAuthClient-iOS.plist` | Google Cloud Console 创建的 **iOS 类型** OAuth 客户端（PKCE 无 secret）；也可在 App 同步页直接导入 `.plist` / 粘贴 Client ID |
| **Windows Google OAuth** | 运行时在应用「设置 → 同步」导入 `client_secret.json` | 加密存入 Windows Credential Manager / DPAPI（`WinCredentialVault`），磁盘不留明文 |
| **Android Google OAuth & 签名** | 应用内 Custom Tabs PKCE 导入 `client_secret.json`；本地 SDK 路径写 `android/local.properties` | 密钥存入 Android Keystore；Release 签名通过 `CHARKLE_KEYSTORE_*` 环境变量传入 |
| **Web 本地与 Workers 密钥** | `web/.env`、`web/packages/worker/.dev.vars` | 复制自 `web/.env.example`；生产环境全部走 `wrangler secret put` 或环境变量 |

---

## 8. 常见排障速查

| 现象 | 排查方向 |
| :--- | :--- |
| **macOS 区域截图 `⌥⇧A` 无反应** | 在「系统设置 → 隐私与安全性 → 屏幕录制」重新勾选当前构建出的 `Charkle.app`（重签名或路径变化时需重新授权） |
| **macOS Safari 扩展看不到或无法连回桌面端** | 确认运行的是 `scripts/build-app.sh` 生成的已签名 `dist/Charkle.app`（而非裸 `swift run`），并在 Safari 设置中允许「在所有网站上使用」 |
| **Windows 构建提示找不到 C++ / MSVC 工具** | 确认已安装 Visual Studio 2022 Build Tools 的 *Desktop development with C++* 组件并重启终端 |
| **Android 编译找不到 NDK 或 `.so` 架构不匹配** | 设置 `ANDROID_NDK_HOME`；模拟器运行前使用 `CHARKLE_ANDROID_ABIS="arm64-v8a x86_64" ./android/scripts/build-rust-android.sh` 重新生成 |
| **Web 启动提示找不到 `node:sqlite`** | 运行 `node -v` 确认 Node.js 版本 `>= 22.13.0` |
| **跨端同步出现时间偏差或字段丢失** | 检查是否误用 Unix 毫秒时间戳代替 Cocoa Reference Epoch 秒数，或遗漏了大写 UUID / `Codable` 向后兼容默认值（参见 [`.trellis/spec/cross-platform/index.md`](../.trellis/spec/cross-platform/index.md)） |
