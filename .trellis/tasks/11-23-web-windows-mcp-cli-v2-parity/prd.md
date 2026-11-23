# Web & Windows MCP v2 + CLI Ergonomics Parity

## Authority
- Canonical contract: `.trellis/spec/cross-platform/index.md` §3
- macOS reference implementation:
  - `Sources/CharkleCore/Intelligence/CharkleExternalAgentSchema.swift`
  - `Sources/CharkleCore/Intelligence/CharkleExternalAgentService.swift`
  - `Sources/CharkleCore/Intelligence/MCPStdioFrameParser.swift`
  - `Sources/CharkleCLI/{CharkleCLI,CLIArgParser,CLIFormatter,CLICompletions}.swift`

## Required Parity Items (Web `./web/` & Windows `./windows/`)
1. **MCP Protocol v2**:
   - Negotiate `protocolVersion` against `["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]`.
   - Support JSON-RPC 2.0 batch arrays, `logging/setLevel`, `resources/templates/list`, `prompts/list`, `prompts/get`.
   - Emit full MCP tool annotations (`title`, `readOnlyHint`, `destructiveHint: false`, `idempotentHint`, `openWorldHint`).
   - Expose 4 static resources (`charkle://library/overview`, `charkle://boards`, `charkle://folders`, `charkle://smart-folders`) + 2 dynamic templates (`charkle://assets/{asset_id}`, `charkle://boards/{board_id}`) + 4 prompts (`triage_inbox`, `curate_moodboard`, `extract_design_tokens`, `inspect_ai_prompts`).
2. **20 Safe Tools (12 Read + 8 Write — Never Permanent Delete)**:
   - Upgrade existing 14 tools:
     - `search_assets` / `list_inbox` / `render_contact_sheet`: `offset`/`hasMore`/`nextOffset` pagination, `include_subfolders`, `media_kinds`, `aspect_shape`, `smart_folder_*`, `only_trashed`, `sort_by`, optional `include_image`.
     - `get_asset`: full `richMetadata` (`photoExif`, `aiGeneration`, `socialPost`, `githubRepo`) + optional inline JPEG preview (`include_image: true`).
     - `organize_assets`: explicit `ai_description` overwrite, `dismiss_suggested_tags`, `pinned_offline`, `skippedIDs`.
     - `ingest_asset`: return post-patch tagged assets, support `folder_id`, `file_paths`, `notes`, `rating`, `target_board_id`.
     - `patch_moodboard`: non-overlapping node placement below existing `maxY`, `add_section`, `remove_node_ids`, `note_style`, `skippedLockedAssetIDs`.
     - `export_board_image`: high-res `preview1400` thumbnails + optional `include_image`.
   - Add 6 new safe tools: `find_similar_assets`, `semantic_search`, `quick_jump`, `suggest_folder`, `update_folder` (never delete), `analyze_assets`.
3. **CLI Ergonomics (Windows `charkle-cli` & Web CLI if added)**:
   - Boolean-safe `--k=v` parser, per-subcommand `--help`, dual-mode TTY human output / pipe-safe auto-JSON (`--json`, `--compact`), `doctor`, `board patch`, `folder list|create|rename|move|update`, `completions`.
