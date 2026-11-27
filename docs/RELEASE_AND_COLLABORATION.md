# 多端版本管理与协同发布规范（RELEASE & COLLABORATION）

Charkle 采用 **「同版本号、共享 GitHub Release、各端非破坏性追加安装包」** 的发布策略。多人协作分别负责 macOS / iOS / Windows / Android 发布时，严格按本文档执行，可彻底避免版本号错位、Release Notes 被覆盖或安装包误删。

> 自动化发版细节可同步参考仓库内置技能手册：
> - macOS 发版流水线：[`.agents/skills/charkle-macos-ship/SKILL.md`](../.agents/skills/charkle-macos-ship/SKILL.md)
> - Windows 发版流水线：[`.agents/skills/charkle-windows-ship/SKILL.md`](../.agents/skills/charkle-windows-ship/SKILL.md)

---

## 1. 各平台版本号位置清单（发版前务必全量对齐）

升版（例如 `v1.5.1` → `v1.5.2` 或 `v1.6.0`）时，各平台必须同步更新以下文件中的版本号：

### macOS（`vX.Y.Z` + 递增 Build 号）
1. `Resources/Info.plist`（`CFBundleShortVersionString`、`CFBundleVersion`）
2. `Resources/SafariExtension/Info.plist`（`CFBundleShortVersionString`、`CFBundleVersion`）
3. `Sources/CharkleApp/Stores/AppUpdateStore.swift`（版本回退字符串）
4. `Sources/CharkleApp/Views/Settings/AdvancedAboutSettingsPane.swift`（关于页版本回退展示）
5. `Sources/CharkleCanvas/CanvasSupport.swift`（导出/元信息版本标记）
6. `Sources/CharkleCore/Intelligence/CharkleExternalAgentSchema.swift`（MCP `serverInfo.version`）
7. `scripts/build-dmg.sh`（默认版本回退值）

### iOS / iPadOS
1. `ios/CharkleMobile.xcodeproj/project.pbxproj`（`CharkleMobile` 与 `CharkleShareExtension` 的 Debug / Release 四处 `MARKETING_VERSION` 与 `CURRENT_PROJECT_VERSION`）

### Windows
1. `windows/Cargo.toml`（`[workspace.package].version`）
2. `windows/src-tauri/tauri.conf.json`（`"version"`）
3. `windows/ui/package.json`（`"version"`）
4. `windows/crates/charkle-core/src/updater.rs` 及对应单测中的默认回退版本（如有）

### Android
1. `android/app/build.gradle.kts`（`versionName` 与递增 `versionCode`）

### 浏览器扩展
1. `Resources/BrowserExtension/manifest.json`（`"version"`，仅在扩展功能/修复变更时递增）

---

## 2. 发版前强制预检门禁

在任何平台打 Tag 或上传 Release 资产前，**必须全部满足以下条件**：

1. **构建与测试全绿（零警告）**：
   - macOS：`swift build --build-tests -Xswiftc -warnings-as-errors && swift test --skip-build`、`node --test Resources/BrowserExtension/tests/extension.test.mjs`、`node scripts/test-figma-plugin.cjs`
   - Windows：`pwsh -File windows/scripts/verify-windows.ps1`
   - Android：`./android/scripts/verify-android.sh`（正式版跑 `./android/scripts/build-release-android.sh`）
   - Web：`cd web && npm run typecheck && npm test && npm run build`（Worker 另加 `cf:typecheck` & `cf:dry-run`）
2. **安装包完整性与签名校验**：
   - **macOS**：`./scripts/build-dmg.sh --rebuild` → `hdiutil verify dist/Charkle-<ver>-arm64.dmg` → 拷贝 `.app` 至干净 `/tmp` 副本剥离扩展属性后执行 `codesign --verify --deep --strict`（覆盖主程序 `Charkle.app` 与 `CharkleSafariExtension.appex`）→ 记录精确字节数与 `shasum -a 256` → 重启本机新版 App 验证静置 CPU `< 1%`。
   - **Windows**：`pwsh -File windows/scripts/build-release-nsis.ps1` → 确认 `charkle-cli-x86_64-pc-windows-msvc.exe` sidecar 与 `FigmaPlugin` 已正确打入安装包 → 记录 `Charkle_<ver>_x64-setup.exe` 精确字节数与 SHA-256。
   - **Android**：确认 Release APK 已启用 R8 混淆与资源瘦身，并在目标架构真机/模拟器安装验证冷启动与基础流程。
3. **仓库纯净度与隐私审计**：
   - 确认工作区无意外暂存的私密文件（`Resources/GoogleOAuthClient.json`、`.env*`、`.dev.vars*`、`android/local.properties`、`.keystore`、`Charkle*.svg`）。
   - 确认变更文件与 Release Notes 中**零密钥、零个人绝对路径、零签名证书 CN/邮箱、零无关外部竞品或作者名**。
4. **分支合流、并发同步与显式推送**：
   - 日常协作功能先在特性分支开发并合入 `dev`（`origin/dev`）；准备发版时，将通过全量验证的 `dev` 合入（或 fast-forward）到 `main`。
   - 推送前先 `git fetch origin && git rebase origin/main`，确认落后提交数为 `0`。
   - 显式推送分支与注释标签（发版后同步确保 `dev` 包含最新发版提交）：
     ```bash
     git push origin main
     git tag -a vX.Y.Z -m "Charkle vX.Y.Z"
     git push origin vX.Y.Z
     git checkout dev && git merge --ff-only main && git push origin dev
     ```
   - 严禁 `git push --all` 或 `git push --mirror`。

---

## 3. 多端协同 GitHub Release 协议（防互相覆盖）

同一版本 `vX.Y.Z` 在 GitHub Releases 中**只创建一个 Release**，各平台按时间顺序协同发布：

### 3.1 首发端（通常为 macOS + iOS）
1. 创建 `vX.Y.Z` Release 并上传对应资产（如 `Charkle-X.Y.Z-arm64.dmg`）。
2. Release Notes 必须按平台分节编写，并为尚未发布的端预留明确占位段落：
   ```markdown
   ## macOS（vX.Y.Z · Build N · Apple Silicon）
   - 更新内容...
   - 安装包校验：`Charkle-X.Y.Z-arm64.dmg`（体积 / SHA-256）

   ## iOS / iPadOS（vX.Y.Z · Build N）
   - 更新内容...

   ## Windows（vX.Y.Z · x64）
   > 同步适配构建中，完成后将追加 `Charkle_X.Y.Z_x64-setup.exe` 安装包并更新本节说明。
   ```

### 3.2 后续跟进端（如 Windows / Android）
1. **绝不删除或重建已有 Release，也绝不覆写其他平台段落**。
2. 追加上传本端安装包（需热替换本端安装包时仅用 `--clobber` 覆盖同名文件）：
   ```bash
   gh release upload vX.Y.Z <installer-file> --clobber
   ```
3. 先拉取当前线上 Release Notes，**仅精准替换自己平台的 `## <Platform>（vX.Y.Z ...）` 段落**（逐字保留其他平台内容与校验码），再执行 `gh release edit vX.Y.Z --notes-file <updated-notes.md>`。
4. 发布后运行 `gh release view vX.Y.Z --json url,tagName,assets` 核对所有端资产名称、状态（`uploaded`）与 SHA-256 摘要无误。

---

## 4. 跨端功能交接标准流程（单端领先时）

当某位开发者率先在一个平台完成新功能（例如 macOS + iOS 率先推出 `v1.5.1`）：
1. 在代码合入与发版的同时，在 `.trellis/tasks/<MM-DD>-<platform>-<topic>/` 下创建标准任务单（`prd.md` + `task.json`），写清：
   - 参考源码路径与关键符号名；
   - 涉及的数据模型与 `/.charkle/` 线协议字段（精确到字段名与类型）；
   - 边界情况与验收测试点；
   - 是否需要追加到已有 `vX.Y.Z` Release。
2. 更新 [`docs/PLATFORM_MATRIX.md`](PLATFORM_MATRIX.md) 中的版本与功能状态。
3. 目标平台负责人拉取最新 `dev` 后，在自己平台的特性分支内按任务单实现并验证，合入 `dev` 并按发版窗口并入 `main`，完成后归档任务单并追加上传安装包。
