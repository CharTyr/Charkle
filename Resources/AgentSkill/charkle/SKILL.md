---
name: charkle
description: >-
  Search, visually inspect, deduplicate, curate moodboards, and organize assets in a local or
  remote Charkle visual reference library via Charkle MCP v2 with minimal token/context cost.
  Use whenever finding visual references, selecting images by style/color/tone/aspect, triaging
  Charkle Inbox, resolving duplicates, inspecting EXIF/AI prompts, fetching original files across
  machines, or composing/patching Charkle Moodboards.
---

# Charkle Visual Reference Library — Pure MCP v2 Playbook

Operate Charkle through its **10 orthogonal MCP tools** (works identically over local `stdio` MCP and cross-machine HTTP `/api/v1/mcp`).

## 1. Low-Token 3-Step Visual Funnel

1. **Orient first (`library_overview`)**:
   - Read compact folder profiles (`recursiveAssetCount`, `topTags`, `palette`, `dominantAspect`), `topTags`, `taxonomy`, `boards`, and current permissions (`readOnly` | `inboxAndEnrich` | `readWriteOrganize`).
   - Pick target folder(s) immediately; parent folders include nested subfolders by default (`include_subfolders: true`).
2. **Recall + see in ONE call (`query_assets`)**:
   - Pass `contact_sheet: true, diversify: true, limit: 16` to get an inline numbered `#01..#16` Contact Sheet JPEG + ultra-lean `visual` manifest in a single turn.
   - Use `queries: ["方向A", "方向B", "方向C"]` to inspect multiple creative directions in **one** Contact Sheet.
   - Pass a stable `session_id` across multi-round visual discovery so already-seen assets are skipped automatically without manually repeating `exclude_asset_ids`.
   - Steer round 2 with `seed_asset_ids` ("more like #03"), `unlike_asset_ids` ("steer away from #07"), CIELAB `tone` (`dark|light|warm|cool|vivid|muted|high_contrast`), `aspect_shape`, and returned `facets` / `relaxationHints`.
   - For Inbox triage, call `query_assets(only_inbox: true, contact_sheet: true, include_folder_suggestions: true, limit: 16)` in ONE call.
3. **Inspect finalists in ONE batch (`inspect_assets`)**:
   - Call `inspect_assets(asset_ids: [...])` (1–12 finalists, 8-char short IDs accepted everywhere) only when EXIF, AI generation prompts, social text, zoomed `crop_box` detail, or a cross-machine `include_download_url: true` link is needed.

## 2. Taxonomy & Organization Discipline

- **Reuse before inventing**: Match existing folder paths and canonical `topTags` from `library_overview` / `charkle://library/taxonomy`. Put uncertain exploratory tags in `add_suggested_tags` instead of polluting confirmed `tags`.
- **Never force misfiling**: If an Inbox asset does not truly fit any existing folder, leave it in Inbox and tell the user rather than guessing.
- **Batch heterogeneous edits in 1 call**: Use `organize_assets(items: [{ asset_id, folder_path, add_tags, ... }, ...])` to triage an entire Contact Sheet atomically in one request.
- **Preview large or sensitive writes first**: Before modifying >15 assets, trashing items, or merging duplicates, run with `dry_run: true` to show the user the exact impact diff first.
- **Cross-machine file transfer**: Over remote HTTP MCP, never pass local `file_path`; upload files via `ingest_assets(inline_files: [{ filename, data_base64 }])` or `web_urls`, and pull originals via `inspect_assets(include_download_url: true)`.

## 3. Safety & Reversibility

- Permanent deletion of assets and deletion of folders are **strictly disabled** across all MCP tools (`trashed: true` and `deduplicate_assets(action: "merge")` always use reversible soft Trash).
- Every write tool returns a `runID`. Always mention the `runID` after bulk changes; if the user wants to undo a batch, call `rollback_run(action: "rollback", run_id: "...")` to atomically revert assets, folders, and moodboards across all synced devices.
