---
name: charkle
description: >-
  Search, visually inspect, curate moodboards, and organize assets in a local Charkle visual
  reference library via Charkle MCP or the `charkle` CLI with minimal token/context cost.
  Use whenever finding visual references, selecting images by style/color/tone/aspect, triaging
  Charkle Inbox, inspecting EXIF/AI generation prompts, or composing/patching Charkle Moodboards.
---

# Charkle Visual Reference Library — Low-Token Agent Playbook

Use this 3-step funnel whether calling **Charkle MCP tools** or the **`charkle` CLI** (`charkle` auto-outputs compact single-line JSON when piped).

## Core Token-Saving Rules

1. **Always orient in 1 call first**: Call `library_overview` (CLI: `charkle overview`).
   - Read each folder's semantic profile (`recursiveAssetCount`, `topTags`, `palette`, `dominantAspect`), plus library `aspectShapeCounts` and `boards`.
   - Pick the right target folder(s) immediately instead of blindly scanning the whole library.
   - Parent folders recurse into nested subfolders by default (`include_subfolders: true`).
2. **Recall + visually inspect in ONE call** (never dump 30+ full text summaries before looking at images):
   - **MCP**: Call `semantic_search` or `search_assets` with `diversify: true, render_contact_sheet: true, limit: 16` (auto-switches manifest to ultra-lean `detail: "visual"`, ~1,160 vision tokens + ~1.3 KB text for 16 distinct thumbnails).
   - **Multi-direction brief (3 calls -> 1 call)**: Pass `queries: ["人物动态", "夏日海边晴空", "极简白底"]` to `semantic_search` or `render_contact_sheet` to inspect all directions in **one single Contact Sheet**.
   - **CLI**: `charkle semantic "夏日海边蓝天女孩" --fast --diversify --limit 16 --detail visual --out /tmp/candidates.jpg` (then view `/tmp/candidates.jpg` with your image reader).
3. **Use 8-character short IDs everywhere**: Every tool accepts unambiguous 8+ char prefixes (`69ED8DCB`) for `asset_id(s)`, `folder_id`, `board_id`, `seed_asset_ids`, `unlike_asset_ids`, and `exclude_asset_ids`.
4. **Refine with visual steering instead of paging**:
   - Use returned `facets` (`topFolders`, `topTags`, `aspectShapes`, `topColors`) to narrow large result sets.
   - Use `tone` (`dark` | `light` | `warm` | `cool` | `vivid` | `muted` | `high_contrast`) and `aspect_shape` (`portrait` | `landscape` | `square` | `ultrawide`) to match perceptual lighting/framing via local CIELAB math.
   - Use `seed_asset_ids` ("more like #03") and `unlike_asset_ids` ("steer away from #07's visual style") plus `exclude_asset_ids` for high-precision round 2 refinement.
5. **Inspect finalists in ONE batch**: Call `get_asset(asset_ids: ["id1", "id2", "id3"], include_image: true)` (CLI: `charkle asset id1 id2 id3`) only on the 2–6 finalists that need resolution, EXIF, AI generation prompt, or close-up verification.

## Quick CLI Cheat Sheet

```bash
# 1. Library atlas (folders + topTags + palettes + recursive counts)
charkle overview

# 2. Fast local semantic recall (bilingual EN/ZH + CIELAB tone/aspect + diversity)
charkle semantic "japanese woodblock night blue" --fast --diversify --limit 12
charkle semantic --queries "人物动态,夏日海边晴空,极简白底" --diversify --out /tmp/brief.jpg

# 3. Structured filtering (OR tags, exclusions, CIELAB tone, facets)
charkle search --folder 插画 --any-tag 海滩,海洋,晴空 --exclude-tag 素体 --tone cool --shape portrait --diversify --limit 16 --out /tmp/picks.jpg

# 4. Visual anchor + negative repulsion ("more like A, less like B")
charkle similar <id-prefix> --unlike-ids <avoid-prefix> --diversify --limit 12

# 5. Batch finalist metadata (1..12 IDs in one call)
charkle asset <id1> <id2> <id3>

# 6. Safe write operations (permanent delete is strictly disabled)
charkle organize --ids <id1>,<id2> --folder "插画/ClearLine" --add-tags 精选 --rating 5
charkle board compose --title "夏日视觉方向" --ids <id1>,<id2>,<id3> --layout magazine
charkle board export <board-id> --out /tmp/board.png --width 1440
```

## Safety Invariants

- Permanent deletion of assets or folders is strictly disabled across both CLI and MCP (`trash_assets` is soft Trash only, reversible with `--restore` / `trashed: false`).
- `output_path` / `--out` refuses writes inside Charkle's library directory, `~/.ssh`, or protected system paths, and is blocked in `readOnly` mode (use inline MCP images in `readOnly` mode).
