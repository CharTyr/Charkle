# PRD: Windows M5 — Hybrid AI, TypeSafe Jev, 9-Pane Settings, CLI/MCP & NSIS Release

> Parent Task: `11-23-windows-client` · Depends On: `11-23-windows-m1` through `11-23-windows-m4`

## 1. Goal & User Value

Complete full macOS v1.0.1 feature parity on Windows and ship a production-ready `x64` NSIS `.exe` installer: Hybrid Cloud AI + TypeSafe System One (Jev) visual grounding, the centered **9-pane Settings overlay** + skippable **Onboarding Studio**, native **`charkle-cli.exe`** + 14-tool External Agent MCP/CLI service with independent channel switches, final Kubai motion/a11y polish, cross-platform macOS ↔ Windows sync QA, and release packaging.

## 2. Requirements

- **M5-R1 Hybrid Cloud AI & Usage Telemetry**:
  - Support all 4 `AIProviderConfig` modes: `disabled` (Local-only), `chatGPTSubscription` (PKCE OAuth), `gemini`, and `openAICompatible` (OpenAI Chat Completions, Anthropic Messages, OpenAI Responses).
  - Store all API keys/OAuth tokens exclusively in Windows DPAPI / Credential Manager (`SecretVault`), honor thumbnail-sending privacy toggle, auto-analyze on import, and record telemetry in `CloudAIUsageTracker`.
- **M5-R2 Experimental TypeSafe System One (Jev) Visual Grounding**:
  - Implement `TypeSafeSystemOneClient` & `VisualGroundingEngine` (connection test & model listing, semantic focus crop, visual-match crop, auto clean-content crop, subject-aware palette, pinpoint callout annotations, hybrid semantic search, batch inbox smart triage, curator visual rerank) with graceful offline fallback when disabled or unreachable.
- **M5-R3 Centered 9-Pane Settings Overlay & Skippable Onboarding Studio**:
  - Mirror `CharkleSettingsTab.swift` 1:1 across 4 sections and 9 focused panes:
    1. **基础与存储**: `通用` (Theme/Appearance/Startup/Language), `素材库` (Local library location, live `CacheStats`, 2–100 GB LRU slider, manual evict), `云同步` (Google Drive OAuth + shared folder URL/ID + WebDAV + Windows Mounted Drive / optional `gdirect.exe` diagnostics + Local Folder + Lossless Storage Migration Wizard).
    2. **采集与操作**: `顶部悬浮窗` (Windows counterpart to `刘海浮窗`: enable/preview/default target/hotstrip sensitivity), `采集与快捷键` (`Alt+Shift+A/S/V` toggles + shortcut cheat sheet).
    3. **生态与智能**: `AI 智能` (Cloud AI + usage stats + WinRT OCR language pack status + TypeSafe Jev controls), `外部 Agent` (independent `mcpEnabled` & `cliEnabled` toggles, `readOnly` / `readWriteOrganize` policy selector, `charkle-cli.exe` path & MCP JSON config copy), `插件与扩展` (Figma Plugin bundle export/instructions, browser capture guide).
    4. **系统**: `高级与关于` (Diagnostics, log export, schema/version info, reset/re-run onboarding).
  - Implement skippable first-launch **Onboarding Studio** matching `OnboardingView.swift`.
- **M5-R4 Native `charkle-cli.exe` & 14-Tool External Agent Service**:
  - Build native `crates/charkle-cli` (`charkle-cli.exe`) supporting `--library-dir <path>`, `mcp` (JSON-RPC 2.0 stdio), and CLI subcommands (`status`, `overview`, `inbox`, `search`, `organize`, `board`, etc.).
  - Expose all 14 tools (8 read + 6 write) and 2 MCP resources (`charkle://library/overview`, `charkle://boards`) with Rust contact-sheet image renderer; enforce security invariant (**permanent delete NEVER allowed via external agents — soft trash only**) and independent `mcpEnabled`/`cliEnabled` switches; signal running desktop app via Windows named event (`Local\CharkleLibraryChanged`) for live UI refresh.
- **M5-R5 Motion/A11y Polish, Cross-Platform QA, Spec Update & NSIS Release**:
  - Final audit of Kubai motion tokens, `prefers-reduced-motion` / `prefers-reduced-transparency` / Windows Transparency Effects Off fallbacks across Light & Dark modes.
  - End-to-end bidirectional `/.charkle/` sync test between macOS Charkle v1.0.1 and Windows Charkle (assets, nested folders, tags, smart folders, dual-mode moodboards, renames).
  - Package `x64` NSIS `.exe` installer via Tauri v2 bundler (bundling `charkle-cli.exe` sidecar/tool binary cleanly alongside the app) + verify clean install/launch/uninstall on Windows 11 (and Windows 10 1903+ fallback).
  - Update `.trellis/spec/` with Windows Tauri/Rust coding & interop conventions; verify existing macOS `swift test` remains untouched/green.

## 3. Out of Scope

- Microsoft Store MSIX sandboxing or EV code-signing certificate procurement (installer builds cleanly unsigned or with user-supplied signing cert via env vars).
- ARM64 Windows bundle (deferred post-v1.0).

## 4. Acceptance Criteria

- [ ] All 4 Cloud AI modes + TypeSafe Jev sidecar + WinRT OCR fallback operate cleanly with keys persisted only in DPAPI/Credential Manager (zero plaintext keys on disk).
- [ ] All 9 Settings panes + Lossless Migration Wizard + Onboarding Studio function with Light/Dark & reduced-transparency/motion fallbacks.
- [ ] `charkle-cli.exe mcp` and `charkle-cli.exe status/search/inbox` enforce independent `mcpEnabled`/`cliEnabled` + `readOnly`/`readWriteOrganize` policy, block permanent deletion, and live-refresh the running desktop app on writes.
- [ ] `npm run tauri build -- --bundles nsis` produces a clean `x64` NSIS `.exe` installer that installs, launches, syncs bidirectionally with a real macOS `/.charkle/` library, and exports valid `.charkleboard` bundles.
- [ ] `.trellis/spec/` is updated and macOS `Sources/`/`Tests/`/`Package.swift` remain untouched.
