# Design: Windows M5 — Hybrid AI, CLI/MCP IPC & NSIS Release Packaging

## External Agent & Live Desktop Wake (`crates/charkle-cli` ↔ `src-tauri`)
- `charkle-cli.exe` opens `%LOCALAPPDATA%\Charkle\library.sqlite` directly in SQLite `WAL` mode (concurrent readers + safe `busy_timeout = 5000ms` writer lock), using the exact same `charkle-core` library and `ExternalAgentPolicy` (`mcpEnabled`, `cliEnabled`, `accessLevel`).
- After any write tool (`organize_assets`, `create_folder`, `ingest_asset`, `compose_moodboard`, `patch_moodboard`, `trash_assets`), `charkle-cli.exe` pulses a Windows named event (`OpenEventW` / `SetEvent` on `Local\CharkleLibraryChanged`) and touches a lightweight `.wake` timestamp file; the running Tauri desktop app listens on a background thread and broadcasts `library:changed` to open main/shelf WebViews immediately.
- Security invariant enforced in `ExternalAgentService` (matching `ExternalAgentPolicy.swift`): permanent deletion APIs are completely absent from the external tool router; `trash_assets` only sets `is_trashed = true`.

## NSIS Release Bundling (`src-tauri/tauri.conf.json`)
- Target: `nsis` (`x86_64-pc-windows-msvc`), WebView2 `embedBootstrapper` (or `downloadBootstrapper` fallback), per-user install default (no UAC elevation needed for personal library + user `PATH` option for `charkle-cli.exe`).
- Bundles `charkle-cli.exe` in the installation directory alongside `Charkle.exe` (and registers optional user PATH entry / Settings copyable absolute path for Claude Desktop / Cursor / Codex MCP config JSON).
- Supports optional Authenticode signing via `TAURI_SIGNING_PRIVATE_KEY` / `signtool` env hooks without blocking local unsigned builds.
