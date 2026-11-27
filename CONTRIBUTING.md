# Charkle 多人协作与贡献指南（CONTRIBUTING）

欢迎参与 **Charkle** 多端视觉素材库与情绪板工作台的协作开发。本文档定义了多开发者（含 AI 辅助开发）并行推进时的**代码边界、分支与 PR 规范、共享核心修改规则、质量门禁、跨端同步流程与仓库安全红线**。

> 首次加入项目请按顺序阅读：
> 1. [文档总索引](docs/README.md)（按角色定位必读文档）
> 2. [系统架构全景](docs/ARCHITECTURE.md)（理解双原生核心 + Web 全栈的 Monorepo 结构）
> 3. [全平台本地开发与测试指南](docs/DEVELOPMENT.md)（跑通你负责平台的构建与测试）
> 4. [产品视觉与交互宪章](DESIGN.md) 与 [跨端共享协议](.trellis/spec/cross-platform/index.md)

---

## 1. 工作区划分与代码所有权边界

Charkle 采用单一 Monorepo 管理 5 个客户端平台与 3 类伴生集成。**每位开发者 / 每个 PR 原则上只改动自己负责的平台目录**，避免多端同时编辑引发无谓冲突：

| 协作领域 | 目录范围 | 共享影响面（改动前必看） | 平台专属规范 |
| :--- | :--- | :--- | :--- |
| **Apple 共享核心** | `Sources/CharkleCore/` | **同时影响 macOS 与 iOS/iPadOS** | [`.trellis/spec/backend/index.md`](.trellis/spec/backend/index.md) |
| **macOS 桌面端** | `Sources/CharkleApp/`、`Sources/CharkleCanvas/`、`Sources/CharkleCLI/`、`scripts/`、`Resources/Info.plist`、`Resources/SafariExtension/` | 仅 macOS（若动 `CharkleCore` 需兼顾 iOS 编译） | [`AGENTS.md`](AGENTS.md)、[`.trellis/spec/macos/native-design-system.md`](.trellis/spec/macos/native-design-system.md) |
| **iOS / iPadOS 端** | `ios/CharkleMobile/`、`ios/CharkleShareExtension/`、`ios/CharkleMobile.xcodeproj/` | 依赖 `Sources/CharkleCore` | [`ios/README.md`](ios/README.md) |
| **Rust 共享核心** | `windows/crates/charkle-core/` | **同时影响 Windows 与 Android** | [`.trellis/spec/windows/index.md`](.trellis/spec/windows/index.md)、[`.trellis/spec/android/index.md`](.trellis/spec/android/index.md) |
| **Windows 桌面端** | `windows/crates/charkle-platform-win/`、`windows/crates/charkle-cli/`、`windows/src-tauri/`、`windows/ui/`、`windows/scripts/` | 仅 Windows（若动 `charkle-core` 需兼顾 Android FFI） | [`windows/AGENTS.md`](windows/AGENTS.md)、[`.trellis/spec/windows/fluent2-design-system.md`](.trellis/spec/windows/fluent2-design-system.md) |
| **Android 端** | `android/app/`、`android/rust/charkle-android-ffi/`、`android/scripts/` | 通过相对路径引用 `windows/crates/charkle-core`，**禁止修改 `windows/Cargo.toml` 成员列表** | [`android/README.md`](android/README.md)、[`.trellis/spec/android/m3-expressive-design-system.md`](.trellis/spec/android/m3-expressive-design-system.md) |
| **Web / Workers** | `web/`（`@charkle/shared`、`server`、`client`、`worker`） | 若改动 `web/figma-plugin/` 必须与 `Resources/FigmaPlugin/` 逐字节一致 | [`web/README.md`](web/README.md)、[`.trellis/spec/web/index.md`](.trellis/spec/web/index.md) |
| **浏览器扩展** | `Resources/BrowserExtension/` | 被 macOS Safari/Chromium、Windows Chromium 与 Web 共享 | [`Resources/BrowserExtension/README.md`](Resources/BrowserExtension/README.md) |
| **Figma 桥接插件** | `Resources/FigmaPlugin/`、`web/figma-plugin/` | 两处目录**必须保持逐字节一致** | [`.trellis/spec/cross-platform/index.md`](.trellis/spec/cross-platform/index.md) |
| **设计 / 架构 / 任务** | `DESIGN.md`、`docs/`、`.trellis/spec/`、`.trellis/tasks/` | 全平台生效，改动需明确同步给相关端 | [`.trellis/workflow.md`](.trellis/workflow.md) |

### 共享核心协作铁律（最容易踩坑的 4 条）

1. **修改 `Sources/CharkleCore/` 时**：
   - `CharkleCore` 同时编译到 macOS 15+ 和 iOS 18+，严禁引入未加 `#if os(macOS)` 守卫的 AppKit 专属 API，严禁 `import SwiftUI`。
   - 新增 `Codable` 字段必须提供向后兼容的 `init(from:)` 默认值，避免升级后已有用户 SQLite JSON 解析失败。
   - 同步更新 `Sources/CharkleCore/Stubs/PlaceholderEngine.swift`。
2. **修改 `windows/crates/charkle-core/` 时**：
   - 必须保持 **100% 平台无关**（严禁引入 Win32 / Tauri 依赖），所有系统能力必须通过 `traits/mod.rs` 抽象注入，确保 Windows 和 Android 双方都能零警告编译。
   - 严禁把 `android/rust/charkle-android-ffi` 加进 `windows/Cargo.toml` 的 `members`，避免拖累 Windows 侧构建。
3. **修改 `/.charkle/` 同步协议或情绪板/素材数据模型时**：
   - 必须先更新 [`.trellis/spec/cross-platform/index.md`](.trellis/spec/cross-platform/index.md)，严格遵守 **Cocoa Reference Epoch 秒数**（偏移 `978_307_200`）与 **大写 RFC-4122 UUID** 契约，并确保跨端往返编解码测试全绿。
4. **需要另一端跟进功能时**：
   - **不要直接跨平台顺手改别人目录的代码**；在 `.trellis/tasks/` 下新建或更新结构化任务单（`prd.md` + `task.json`），写清参考实现路径、数据模型契约、边界条件与验收标准，交由该平台负责人落地。

---

## 2. 分支策略、提交规范与 PR 流程

### 2.1 分支策略与命名

采用 **`dev`（多人日常集成分支）+ `main`（稳定发布分支）** 的双主线协作模型：

- **`main`**：稳定发布主干，始终对应可发布 / 已发布的版本基线；仅通过经过全量验证的发布合并（`dev → main`）或紧急热修复进入，并在 `main` 上打 `vX.Y.Z` 发布标签。
- **`dev`**：多人协作日常集成分支（`origin/dev`），所有日常特性、修复与跨端对齐 PR **默认基于 `dev` 拉取并合入 `dev`**。
- **特性 / 修复分支命名**：
  - `feat/<platform>-<short-topic>`（例如 `feat/android-moodboard-ink`、`feat/windows-v152-search`）
  - `fix/<platform>-<short-topic>`（例如 `fix/ios-zoom-flicker`、`fix/web-r2-range`）
  - `docs/<topic>`、`perf/<platform>-<topic>`、`chore/<topic>`
- 提 PR 合入 `dev` 前，优先使用 `git fetch origin && git rebase origin/dev` 保持线性清晰历史。

### 2.2 Commit Message 规范

采用 Conventional Commits 风格，显式标注作用域（`<scope>`）：

```text
<type>(<scope>): <concise summary>
```

- **常用 `type`**：`feat`、`fix`、`perf`、`refactor`、`docs`、`test`、`chore`
- **常用 `scope`**：`macos`、`ios`、`windows`、`android`、`web`、`worker`、`extension`、`sync`、`core`、`release`、`cross-platform`、`trellis`（支持逗号组合，如 `feat(macos,ios): ...`）
- **示例**：
  - `feat(windows): sync v1.5.1 video streaming playback and frame-to-cover selection`
  - `fix(ios): preserve scroll anchor when switching folder filters`
  - `docs(architecture): align multi-platform documentation for team collaboration`

### 2.3 Git 推送纪律

- **仅允许显式推送指定引用**：`git push origin <your-branch>`、`git push origin dev`、`git push origin main` 或 `git push origin vX.Y.Z`。
- **严禁执行 `git push --all` 或 `git push --mirror`**，避免把本地临时 ref 或内部检查点误推远端。

### 2.4 PR 审查清单

提交 Pull Request 时请在描述中写明：
1. **改动范围与所属平台**（以及是否触及共享核心或 `/.charkle/` 协议）。
2. **关联的任务单或 Issue**（如 `.trellis/tasks/<task-dir>/prd.md`）。
3. **验证命令与实际结果**（严禁只贴“本地没问题”而省略实际执行的测试门禁）。
4. **跨端影响说明**：如果新特性仅在当前端落地，需注明是否已创建其他端的对齐任务单。
5. **界面改动截图 / 录屏**：涉及 UI 调整的 PR 需确认 Light / Dark 双模式与 `Reduce Motion` / `Reduce Transparency` 退化表现。

---

## 3. 各平台提交前强制质量门禁

代码合入 `dev` 或 `main` 前，对应改动平台必须全部通过以下检查：

| 改动范围 | 必须通过的命令 |
| :--- | :--- |
| **macOS / `CharkleCore`** | `swift build --build-tests -Xswiftc -warnings-as-errors && swift test --skip-build` |
| **iOS / iPadOS** | 在 Xcode 中编译运行 `ios/CharkleMobile.xcodeproj`（含 `CharkleShareExtension`）+ 跑通 `swift test --filter MobileOAuthTests` 及相关 Core 单测 |
| **Windows** | `pwsh -File windows/scripts/verify-windows.ps1`（涵盖图标同步、`tsc`、`vitest`、`vite build`、`cargo fmt --check`、`cargo clippy --workspace --all-targets -- -D warnings`、`cargo test --workspace`） |
| **Android** | `./android/scripts/verify-android.sh`（涵盖 `charkle-android-ffi` Rust 单测、`cargo-ndk` + UniFFI 绑定生成、`:app:assembleDebug`、`:app:testDebugUnitTest`） |
| **Web / Cloudflare Workers** | `cd web && npm run typecheck && npm test && npm run build`；若改 Worker 还需 `npm run cf:typecheck && npm run cf:dry-run` |
| **浏览器扩展** | `node --test Resources/BrowserExtension/tests/extension.test.mjs` |
| **Figma 桥接插件** | `node scripts/test-figma-plugin.cjs` + 验证 `diff -rq Resources/FigmaPlugin web/figma-plugin` 无差异 |

---

## 4. Trellis 任务与多人 AI 协作约定

仓库内置 `.trellis/` 工作流系统，帮助多位开发者（与各自使用的 AI 编程助手）共享规范与上下文、避免重复踩坑：

1. **初始化个人身份（首次克隆后执行一次）**：
   ```bash
   python3 ./.trellis/scripts/init_developer.py <your-name>
   ```
   该命令会创建被 `.gitignore` 忽略的 `.trellis/.developer` 与个人日志目录 `.trellis/workspace/<your-name>/`。
2. **动工前读规范**：按负责平台阅读 `.trellis/spec/<layer>/index.md` 中的 **Pre-Development Checklist**。
3. **跨端功能与复杂需求建任务单**：使用 `python3 ./.trellis/scripts/task.py create "<title>" --slug <name>` 在 `.trellis/tasks/` 下记录 `prd.md`、`task.json`（复杂任务补充 `design.md` 与 `implement.md`）。
4. **沉淀踩坑经验**：遇到非显而易见的平台坑、并发/线程/窗口生命周期问题或协议边界，务必在同一个 PR 中补记到对应的 `.trellis/spec/` 文档，避免团队成员反复踩雷。

---

## 5. 安全、隐私与仓库纯净度红线

合入 `dev` 或 `main` 前务必自查，**以下内容绝对禁止进入任何被 Git 跟踪的文件（含源码、注释、测试夹具、文档与任务单）**：

1. **零密钥与本地私密文件**：
   - `Resources/GoogleOAuthClient.json`、`ios/**/GoogleOAuthClient*.plist` / `*.json`
   - `.env*`、`.dev.vars*`、`android/local.properties`、Android `.keystore` / `.jks`
   - 任何 API Key、OAuth Client Secret / Token、WebDAV 密码、代码签名证书 CN / 个人邮箱
2. **零个人绝对路径**：
   - 禁止在代码、脚本或文档中硬编码本机路径（如 `/Users/<name>/...`、`C:\Users\<name>\...`），一律使用仓库相对路径或环境变量/占位符。
3. **零未跟踪设计源稿**：
   - 根目录可能存在本地未跟踪的 `Charkle.svg` / `Charkle-Light.svg` 图标源稿，**切勿 `git add .` 误提交**。
4. **外部产品与归属文案纯净**：
   - 禁止在源码、注释、测试、规范或 UI 文案中提及外部参考/竞品名称或无关第三方设计作者名；实际集成的运行期服务与互通文件格式（如 Google Drive、iCloud Drive、WebDAV、Figma / FigJam、`.eaglepack` / `.library`、PureRef `.pur`、各社媒平台）仅作为纯技术集成客观描述。
   - `gdirect` 仅在根目录 `README.md` 的致谢段落鸣谢，其余位置只作技术通道说明。

---

## 6. 发版与版本协同

多端共用同一个 GitHub Release（例如 `v1.5.1`）分发安装包。发版顺序、版本号同步清单与非破坏性 Release Notes 合并规则详见 **[多端版本与协作发布规范](docs/RELEASE_AND_COLLABORATION.md)**。
