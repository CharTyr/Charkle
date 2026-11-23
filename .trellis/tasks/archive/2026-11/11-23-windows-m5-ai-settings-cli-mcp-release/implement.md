# Implementation Checklist: Windows M5

## Prerequisites
- `11-23-windows-m1` through `11-23-windows-m4` completed and verified on Windows.

## Ordered Steps
1. Implement `crates/charkle-core/src/intelligence/{cloud_ai,chatgpt_oauth,usage_tracker,typesafe,visual_grounding,contact_sheet}.rs` + unit/mock HTTP tests.
2. Implement `crates/charkle-core/src/agent/{policy,service}.rs` (14 tools, 2 resources, contact sheet rendering) and `crates/charkle-cli/src/main.rs` (`mcp` stdio + CLI subcommands + `Local\CharkleLibraryChanged` wake pulse).
3. Implement `ui/src/features/settings/` (centered 9-pane Settings overlay across 4 sections + Lossless Storage Migration Wizard + MCP JSON snippet copy) and `ui/src/features/onboarding/` (skippable Onboarding Studio).
4. Audit motion tokens, reduced-motion / reduced-transparency / Win10 fallbacks across Light & Dark modes.
5. Run real macOS ↔ Windows `/.charkle/` bidirectional sync verification (Drive/WebDAV/Local), MCP/CLI policy tests, and `.charkleboard` Figma import validation.
6. Configure NSIS bundler (`tauri.conf.json` bundling `charkle-cli.exe`), build `x64` `.exe` installer, verify clean install/launch/uninstall on Windows, and update `.trellis/spec/`.

## Validation Commands
```powershell
cd windows
cargo fmt --all -- --check
cargo clippy --workspace --all-targets -- -D warnings
cargo test --workspace
cd ui
npm run typecheck
npm test
npm run build
npm run tauri build -- --bundles nsis

# Smoke-test built native CLI & MCP policy
..\target\release\charkle-cli.exe --version
..\target\release\charkle-cli.exe status
```
