# Charkle 文档总索引（Documentation Hub）

欢迎查阅 **Charkle** 完整项目文档。本索引帮助团队成员在 30 秒内按角色定位**权威规范、架构设计、开发手册与当前跨端进度**，消除多端协作中的信息差。

---

## 1. 按角色快速上手路径

| 你的角色 | 建议按顺序阅读 |
| :--- | :--- |
| **所有新加入成员（必读）** | 1. [产品概览](../README.md) → 2. [多人协作指南](../CONTRIBUTING.md) → 3. [系统架构全景](ARCHITECTURE.md) → 4. [跨端功能与版本矩阵](PLATFORM_MATRIX.md) |
| **macOS 开发者（SwiftUI / AppKit / Metal）** | 1. [本地开发指南 §macOS](DEVELOPMENT.md#1-macos-原生端) → 2. [根工程护栏 `AGENTS.md`](../AGENTS.md) → 3. [macOS 设计规范](../.trellis/spec/macos/native-design-system.md) → 4. [核心层规范](../.trellis/spec/backend/index.md) & [UI/Canvas 规范](../.trellis/spec/frontend/index.md) |
| **iOS / iPadOS 开发者（SwiftUI / UIKit）** | 1. [`ios/README.md`](../ios/README.md) → 2. [本地开发指南 §iOS](DEVELOPMENT.md#2-ios--ipados-原生端) → 3. [核心层规范](../.trellis/spec/backend/index.md) → 4. [跨端协议](../.trellis/spec/cross-platform/index.md) |
| **Windows 开发者（Tauri v2 / Rust / React）** | 1. [`windows/README.md`](../windows/README.md) → 2. [本地开发指南 §Windows](DEVELOPMENT.md#3-windows-原生端) → 3. [`windows/AGENTS.md`](../windows/AGENTS.md) → 4. [Windows 架构规范](../.trellis/spec/windows/index.md) & [Fluent 2 设计规范](../.trellis/spec/windows/fluent2-design-system.md) |
| **Android 开发者（Kotlin / Compose / UniFFI）** | 1. [`android/README.md`](../android/README.md) → 2. [本地开发指南 §Android](DEVELOPMENT.md#4-android-原生端) → 3. [Android 架构契约](../.trellis/spec/android/index.md) & [M3 Expressive 设计规范](../.trellis/spec/android/m3-expressive-design-system.md) |
| **Web / Cloudflare 开发者（TypeScript / Node / Workers）** | 1. [`web/README.md`](../web/README.md) → 2. [本地开发指南 §Web](DEVELOPMENT.md#5-web-与-cloudflare-workers) → 3. [Web 开发规范](../.trellis/spec/web/index.md) & [双运行时指南](../.trellis/spec/web/dual-runtime-guidelines.md) |
| **浏览器扩展 / Figma 插件 / MCP 开发者** | 1. [浏览器扩展说明](../Resources/BrowserExtension/README.md) → 2. [跨端协议 §2–§3 & §5.9](../.trellis/spec/cross-platform/index.md) → 3. [Agent Skill 手册](../Resources/AgentSkill/charkle/SKILL.md) |
| **产品 / 设计 / 发版负责人** | 1. [视觉与体验宪章 `DESIGN.md`](../DESIGN.md) → 2. [动效与图标细则](MOTION_AND_ICON_SPEC.md) → 3. [跨端矩阵与待办](PLATFORM_MATRIX.md) → 4. [多端发布规范](RELEASE_AND_COLLABORATION.md) |

---

## 2. 权威层级（文档冲突时的裁决顺序）

当不同文档的细节表述存在时间差时，以以下权威优先级为准：

1. **跨端协议与安全红线**：[`.trellis/spec/cross-platform/index.md`](../.trellis/spec/cross-platform/index.md)（`/.charkle/` 同步线协议、`.charkleboard` 格式、MCP 安全策略、交互契约）
2. **全平台视觉与交互宪章**：[`DESIGN.md`](../DESIGN.md)（中性画布、色彩 Token、动效原则、同魂不同壳）
3. **平台专属工程护栏与设计系统**：
   - macOS：[`AGENTS.md`](../AGENTS.md) + [`.trellis/spec/macos/native-design-system.md`](../.trellis/spec/macos/native-design-system.md)
   - Windows：[`windows/AGENTS.md`](../windows/AGENTS.md) + [`.trellis/spec/windows/fluent2-design-system.md`](../.trellis/spec/windows/fluent2-design-system.md)
   - Android：[`.trellis/spec/android/index.md`](../.trellis/spec/android/index.md) + [`.trellis/spec/android/m3-expressive-design-system.md`](../.trellis/spec/android/m3-expressive-design-system.md)
   - Web：[`.trellis/spec/web/index.md`](../.trellis/spec/web/index.md) + [`.trellis/spec/web/dual-runtime-guidelines.md`](../.trellis/spec/web/dual-runtime-guidelines.md)
4. **当前工程实现总览**：[`docs/ARCHITECTURE.md`](ARCHITECTURE.md)、[`docs/DEVELOPMENT.md`](DEVELOPMENT.md)、[`docs/PLATFORM_MATRIX.md`](PLATFORM_MATRIX.md)
5. **历史档案**：[`docs/BLUEPRINT.md`](BLUEPRINT.md)（v1.0 立项设计初稿，仅作产品初心与历史背景参考，不代表最新架构）

---

## 3. 全仓库文档目录地图

### 根目录文档
- [`README.md`](../README.md) — 面向用户与贡献者的项目首页
- [`CONTRIBUTING.md`](../CONTRIBUTING.md) — 多人协作边界、分支/PR 规范、质量门禁与安全红线
- [`DESIGN.md`](../DESIGN.md) — 全平台视觉设计系统与交互原则
- [`AGENTS.md`](../AGENTS.md) — 五端总控护栏、仓库纯净度纪律与 macOS UI 不变量

### `docs/` 工程中枢文档
- [`docs/README.md`](README.md) — 本索引
- [`docs/ARCHITECTURE.md`](ARCHITECTURE.md) — 最新五端 + 伴生插件系统架构、核心子系统与目录总览
- [`docs/DEVELOPMENT.md`](DEVELOPMENT.md) — 各端本地环境搭建、构建、测试、凭据配置与排障手册
- [`docs/PLATFORM_MATRIX.md`](PLATFORM_MATRIX.md) — 全平台版本、功能对齐矩阵、共享核心耦合表与待办清单
- [`docs/RELEASE_AND_COLLABORATION.md`](RELEASE_AND_COLLABORATION.md) — 多端版本号同步、预检打包与 GitHub Release 协同发布手册
- [`docs/MOTION_AND_ICON_SPEC.md`](MOTION_AND_ICON_SPEC.md) — 动效曲线 Token、连续圆角与双色/分层图标规范
- [`docs/BLUEPRINT.md`](BLUEPRINT.md) — （历史归档）v1.0 初始蓝图规划稿

### 各子项目 README
- [`ios/README.md`](../ios/README.md) — iOS / iPadOS 原生端与 Share Extension 说明
- [`windows/README.md`](../windows/README.md) — Windows 原生端（Tauri v2 + Rust + React/Fluent 2）说明
- [`windows/AGENTS.md`](../windows/AGENTS.md) — Windows Win32/OLE、Mica 与本地视觉引擎工程不变量
- [`android/README.md`](../android/README.md) — Android 原生端（Kotlin + Compose M3 Expressive + UniFFI）说明
- [`web/README.md`](../web/README.md) — Web 全栈与 Cloudflare Workers 部署说明
- [`Resources/BrowserExtension/README.md`](../Resources/BrowserExtension/README.md) — Safari / Chromium 6 平台社媒采集扩展说明
- [`Resources/AgentSkill/charkle/SKILL.md`](../Resources/AgentSkill/charkle/SKILL.md) — 低 Token CLI/MCP 检索与策展工作流说明

### `.trellis/` 规范、任务与发版技能
- [`.trellis/workflow.md`](../.trellis/workflow.md) — Trellis 任务生命周期与工作流状态机
- [`.trellis/spec/`](../.trellis/spec/cross-platform/index.md) — 分层可执行编码规范（`cross-platform/`、`backend/`、`frontend/`、`macos/`、`windows/`、`android/`、`web/`、`guides/`）
- `.trellis/tasks/` — 进行中的跨端对齐任务单与架构 PRD
- [`.agents/skills/charkle-macos-ship/SKILL.md`](../.agents/skills/charkle-macos-ship/SKILL.md) — macOS 预检、签名打包与发版流水线
- [`.agents/skills/charkle-windows-ship/SKILL.md`](../.agents/skills/charkle-windows-ship/SKILL.md) — Windows 预检、NSIS 打包与协同发版流水线
