# Windows & Web Cross-Platform Parity: Pure MCP v2 (stdio + Streamable HTTP) + Skill

## Background & Canonical Reference
macOS (`Sources/CharkleCore`, `Sources/CharkleCLI`, `Sources/CharkleApp`) has migrated to the **Pure MCP v2 + Skill** architecture (Option B: dual-transport MCP with zero business CLI subcommands):
- Canonical contract: `.trellis/spec/cross-platform/index.md` §3
- Canonical macOS reference files:
  - `Sources/CharkleCore/Intelligence/ExternalAgentPolicy.swift`
  - `Sources/CharkleCore/Intelligence/ExternalAgentRunStore.swift`
  - `Sources/CharkleCore/Intelligence/CharkleExternalAgentSchema.swift`
  - `Sources/CharkleCore/Intelligence/CharkleExternalAgentService.swift`
  - `Sources/CharkleCore/Services/LocalExtensionBridgeServer.swift`
  - `Sources/CharkleCLI/CharkleCLI.swift`
  - `Resources/AgentSkill/charkle/SKILL.md`

## Required Parity Work

### 1. Windows (`windows/crates/charkle-core`, `windows/crates/charkle-cli`, `windows/src-tauri`, `windows/ui`)
1. **Policy & Scoped Tokens**:
   - Extend `ExternalAgentAccessLevel` to 3 tiers (`readOnly`, `inboxAndEnrich`, `readWriteOrganize`).
   - Add `httpMCPEnabled`, `allowRemoteHTTPMCP`, and SHA-256 `tokens: [ExternalAgentToken]` to `ExternalAgentConfig` with backward-compatible deserialization.
2. **10-Tool Pure MCP v2 Service & Schema**:
   - Collapse 20 tools into the 10 orthogonal tools (`library_overview`, `query_assets`, `inspect_assets`, `get_board`, `ingest_assets`, `organize_assets`, `manage_folder`, `save_moodboard`, `deduplicate_assets`, `rollback_run`) + 5 static resources (`charkle://library/taxonomy`) + 2 templates + 5 prompts.
   - Retire `output_path` disk writes; add `session_id` seen-tracking, `crop_box` detail zoom, cross-machine `inline_files` (strictly block `file_path` on HTTP transport), `include_download_url`, heterogeneous `organize_assets(items[], dry_run)`, `deduplicate_assets` scan/merge (always soft Trash), and `rollback_run` via SQLite `sync_state` snapshots emitting compensating HLC ops.
3. **Strip `windows/crates/charkle-cli/src/main.rs`**:
   - Remove business CLI subcommands, flag parsers, table formatters, and shell completions; keep only `charkle mcp [--library-dir]`, internal `doctor`, and `--version`/`--help`.
4. **Desktop HTTP MCP Bridge**:
   - Mount `POST /api/v1/mcp` (`GET`/`DELETE` -> `405`) and `GET /api/v1/mcp/download/<ticket>` with Scoped Bearer Token auth on the Windows local bridge server; gate all browser-extension routes strictly to loopback even when `allowRemoteHTTPMCP` binds `0.0.0.0`.
5. **Settings UI**:
   - Replace CLI switch / `PATH` setup with stdio + HTTP MCP controls, 3-tier access picker, and Scoped Token mint/toggle/revoke UI.

### 2. Web / Cloudflare (`web/packages/shared`, `web/packages/server`, `web/packages/worker`, `web/packages/client`)
1. **10-Tool Pure MCP v2 Service & Schema**:
   - Mirror the exact 10-tool schema, 3-tier `ExternalAgentAccessLevel`, `ExternalAgentToken` (SHA-256 hash), `session_id`, heterogeneous `organize_assets(items[], dry_run)`, `deduplicate_assets`, `rollback_run`, and `charkle://library/taxonomy` in `web/packages/server/src/agent/`.
2. **Hardened Streamable HTTP `/api/v1/mcp` & `/api/v1/mcp/download/:ticket`**:
   - Enforce Scoped MCP Bearer Token verification on `POST /api/v1/mcp` (`GET`/`DELETE` -> `405`), hide server local filesystem paths, reject `file_path(s)` over HTTP, and issue 10-minute signed download URLs for `inspect_assets(include_download_url: true)`.
3. **Web Settings UI**:
   - Expose Scoped MCP Token creation/revocation and HTTP MCP JSON snippet in Web Settings.
