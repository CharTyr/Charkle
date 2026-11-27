import Foundation

extension CharkleExternalAgentService {
    public static let serverVersion = "2.0.0"
    public static let supportedProtocolVersions: [String] = [
        "2025-11-25",
        "2025-06-18",
        "2025-03-26",
        "2024-11-05"
    ]
    public static let defaultProtocolVersion = "2025-03-26"

    static func negotiateProtocolVersion(_ requested: String?) -> String {
        if let requested, supportedProtocolVersions.contains(requested) {
            return requested
        }
        return defaultProtocolVersion
    }

    // MARK: - MCP Resources & Templates (5 Static + 2 Dynamic)

    public static func mcpResourceDefinitions() -> [[String: Any]] {
        [
            [
                "uri": "charkle://library/overview",
                "name": "Library Overview Atlas",
                "description": "Counts, compact folder semantic profiles (recursive counts, topTags, palettes), smart folders, top tags, aspect/media mix, boards, taxonomy, and permissions.",
                "mimeType": "application/json"
            ],
            [
                "uri": "charkle://library/taxonomy",
                "name": "Library Taxonomy & Curation Policy",
                "description": "User's canonical tag language, tag aliases, folder inclusion guidelines, rating meanings, and top canonical tags.",
                "mimeType": "application/json"
            ],
            [
                "uri": "charkle://boards",
                "name": "Moodboards",
                "description": "All moodboards with IDs, titles, layout modes, item counts, and palettes.",
                "mimeType": "application/json"
            ],
            [
                "uri": "charkle://folders",
                "name": "Folder Tree & Profiles",
                "description": "Hierarchical folder tree with UUIDs, paths, recursive counts, top tags, and palettes.",
                "mimeType": "application/json"
            ],
            [
                "uri": "charkle://smart-folders",
                "name": "Smart Folders",
                "description": "Saved rule-based smart folders with match counts.",
                "mimeType": "application/json"
            ]
        ]
    }

    public static func mcpResourceTemplateDefinitions() -> [[String: Any]] {
        [
            [
                "uriTemplate": "charkle://assets/{asset_id}",
                "name": "Asset Details",
                "description": "Full metadata for an asset UUID or 8+ char prefix (EXIF, AI prompts, social/GitHub, palette, OCR).",
                "mimeType": "application/json"
            ],
            [
                "uriTemplate": "charkle://boards/{board_id}",
                "name": "Moodboard Context",
                "description": "Structured context for a Moodboard UUID or 8+ char prefix (notes, sections, connectors, palette, referenced assets).",
                "mimeType": "application/json"
            ]
        ]
    }

    // MARK: - MCP Prompts (5 Low-Token Visual Workflows)

    public static func mcpPromptDefinitions() -> [[String: Any]] {
        [
            [
                "name": "triage_inbox",
                "description": "Inspect Inbox assets with inline Contact Sheet + folder suggestions in 1 call, preview plan via dry_run, then batch-organize atomically.",
                "arguments": [
                    ["name": "limit", "description": "Inbox items per batch (default 16).", "required": false],
                    ["name": "apply_changes", "description": "'true' to commit organize_assets immediately; otherwise dry_run preview first.", "required": false]
                ]
            ],
            [
                "name": "curate_moodboard",
                "description": "Token-efficient grounded curation: orient via library_overview, recall diversified multi-direction Contact Sheet in 1 query_assets call, save structured Moodboard.",
                "arguments": [
                    ["name": "brief", "description": "Creative direction, style, mood, or color brief.", "required": true],
                    ["name": "folder_path", "description": "Optional folder path scope.", "required": false],
                    ["name": "count", "description": "Target references (default 10).", "required": false]
                ]
            ],
            [
                "name": "deduplicate_library",
                "description": "Scan deterministic duplicate groups with side-by-side Contact Sheet, visually pick the cleanest master per group, and merge losslessly to soft Trash.",
                "arguments": [
                    ["name": "scope", "description": "'all', 'inbox', or 'folder' (default 'all').", "required": false],
                    ["name": "folder_path", "description": "Folder path when scope='folder'.", "required": false]
                ]
            ],
            [
                "name": "extract_design_tokens",
                "description": "Read a Moodboard's palette, notes, sections, and visual snapshot in 1 get_board call to generate structured design tokens.",
                "arguments": [
                    ["name": "board", "description": "Moodboard title or UUID.", "required": true],
                    ["name": "format", "description": "'css', 'tailwind', 'swiftui', or 'json' (default 'css').", "required": false]
                ]
            ],
            [
                "name": "inspect_ai_prompts",
                "description": "Find AI-generated references and batch-inspect their embedded prompts, models, samplers, seeds, and LoRAs.",
                "arguments": [
                    ["name": "query", "description": "Optional keyword, model, or style filter.", "required": false],
                    ["name": "limit", "description": "Max assets to inspect (default 12).", "required": false]
                ]
            ]
        ]
    }

    public static func renderPrompt(name: String, arguments: [String: Any]) -> [String: Any]? {
        func strArg(_ key: String) -> String {
            ((arguments[key] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        }

        switch name {
        case "triage_inbox":
            let limit = strArg("limit").isEmpty ? "16" : strArg("limit")
            let apply = strArg("apply_changes").lowercased() == "true"
            let actionLine = apply
                ? "Commit in ONE call via `organize_assets(items: [...])` (8-char IDs ok; reuse existing folders/tags; put uncertain tags in `add_suggested_tags`) and share the returned `run_id` so the user can rollback anytime."
                : "Call `organize_assets(items: [...], dry_run: true)` first and present the concise change summary for user confirmation before committing."
            return [
                "description": "Triage untriaged Inbox assets in Charkle",
                "messages": [[
                    "role": "user",
                    "content": [
                        "type": "text",
                        "text": """
                        Triage up to \(limit) Inbox assets in Charkle (low-token MCP v2 workflow):
                        1. Call `library_overview` to inspect folder profiles (`topTags`, `palette`), canonical tags, and `taxonomy`.
                        2. Call `query_assets` with `only_inbox: true, limit: \(limit), contact_sheet: true, include_folder_suggestions: true` to see thumbnails, short IDs, and folder recommendations in ONE call.
                        3. Reuse existing folders and canonical tags; leave truly off-taxonomy items in Inbox instead of misfiling.
                        4. \(actionLine)
                        """
                    ]
                ]]
            ]

        case "curate_moodboard":
            let brief = strArg("brief")
            let effectiveBrief = brief.isEmpty ? "curated visual moodboard" : brief
            let folder = strArg("folder_path")
            let count = strArg("count").isEmpty ? "10" : strArg("count")
            let scopeHint = folder.isEmpty
                ? "Pick best matching folder(s) from `library_overview` folder profiles."
                : "Scope to folder `\(folder)` (subfolders included by default)."
            return [
                "description": "Curate a grounded Charkle Moodboard",
                "messages": [[
                    "role": "user",
                    "content": [
                        "type": "text",
                        "text": """
                        Curate a Charkle Moodboard for: "\(effectiveBrief)" (target ~\(count) assets):
                        1. Call `library_overview` to read folder semantic profiles and existing boards.
                        2. \(scopeHint) Call `query_assets` with `queries: [...]` (or `query`), `diversify: true, contact_sheet: true, session_id: "curate-1"` to inspect distinct candidates in ONE Contact Sheet.
                        3. For round 2 refinement, call `query_assets` with the same `session_id` (auto-skips seen items) plus `seed_asset_ids` (more like) and `unlike_asset_ids` (less like).
                        4. Inspect finalists via `inspect_assets(asset_ids:[...])` only if needed, then call `save_moodboard` with 2–3 `sections`, `hero_asset_ids`, and a concise `curator_note`.
                        """
                    ]
                ]]
            ]

        case "deduplicate_library":
            let scope = strArg("scope").isEmpty ? "all" : strArg("scope")
            let folder = strArg("folder_path")
            let folderClause = folder.isEmpty ? "" : ", folder_path: \"\(folder)\""
            return [
                "description": "Scan and visually resolve duplicate assets in Charkle",
                "messages": [[
                    "role": "user",
                    "content": [
                        "type": "text",
                        "text": """
                        Review duplicate candidates in Charkle safely:
                        1. Call `deduplicate_assets(action: "scan", scope: "\(scope)"\(folderClause), contact_sheet: true, limit: 6)`.
                        2. Visually inspect the side-by-side Contact Sheet to verify which candidate in each group is cleanest (highest resolution, unwatermarked, uncropped).
                        3. Call `deduplicate_assets(action: "merge", groups: [...], dry_run: true)` first, confirm with the user, then commit (`dry_run: false` moves duplicates to reversible soft Trash and merges tags/board refs losslessly).
                        """
                    ]
                ]]
            ]

        case "extract_design_tokens":
            let board = strArg("board")
            let format = strArg("format").isEmpty ? "css" : strArg("format")
            let boardStep = board.isEmpty
                ? "Call `get_board` with no arguments to list boards, then call `get_board(board_id: ..., include_snapshot: true, snapshot_width: 1200)`."
                : "Call `get_board(title: \"\(board)\", include_snapshot: true, snapshot_width: 1200)`."
            return [
                "description": "Extract design tokens from a Charkle Moodboard",
                "messages": [[
                    "role": "user",
                    "content": [
                        "type": "text",
                        "text": """
                        Extract production-ready `\(format)` design tokens from my Charkle Moodboard:
                        1. \(boardStep)
                        2. Read the harmonized HEX/CIELAB palette, curator notes, sections, and visual snapshot.
                        3. Output semantic tokens (surface, ink, accent, muted, borders, typography/spacing cues) in `\(format)`.
                        """
                    ]
                ]]
            ]

        case "inspect_ai_prompts":
            let query = strArg("query")
            let limit = strArg("limit").isEmpty ? "12" : strArg("limit")
            let searchStep = query.isEmpty
                ? "Call `query_assets(media_kinds: [\"image\"], limit: \(limit))`."
                : "Call `query_assets(query: \"\(query)\", media_kinds: [\"image\"], limit: \(limit))`."
            return [
                "description": "Inspect embedded AI generation prompts and parameters",
                "messages": [[
                    "role": "user",
                    "content": [
                        "type": "text",
                        "text": """
                        Inspect AI-generated references in Charkle:
                        1. \(searchStep)
                        2. Batch-call `inspect_assets(asset_ids: [...])` (up to 12 at once) to read `richMetadata.aiGeneration` (`generator`, `modelName`, `prompt`, `negativePrompt`, `sampler`, `steps`, `cfgScale`, `seed`, `loras`).
                        3. Summarize recurring prompt patterns, model/LoRA recipes, and parameter differences.
                        """
                    ]
                ]]
            ]

        default:
            return nil
        }
    }

    // MARK: - MCP Tool Schema Registry (10 Orthogonal Safe Tools — Pure MCP v2, < 10 KB Budget)

    public static func mcpToolDefinitions() -> [[String: Any]] {
        func tool(
            name: String,
            title: String,
            description: String,
            properties: [String: Any],
            required: [String] = [],
            readOnly: Bool,
            idempotent: Bool = true,
            openWorld: Bool = false
        ) -> [String: Any] {
            var schema: [String: Any] = [
                "type": "object",
                "properties": properties
            ]
            if !required.isEmpty {
                schema["required"] = required
            }
            return [
                "name": name,
                "description": description,
                "inputSchema": schema,
                "annotations": [
                    "title": title,
                    "readOnlyHint": readOnly,
                    "destructiveHint": false,
                    "idempotentHint": idempotent,
                    "openWorldHint": openWorld
                ]
            ]
        }

        let mediaKindEnum = MediaKind.allCases.map(\.rawValue)
        let aspectShapeEnum = AspectShape.allCases.map(\.rawValue)
        let sortByEnum = ["newest", "oldest", "name_asc", "rating_desc", "file_size_desc", "relevance"]
        let detailEnum = ["visual", "compact", "standard", "full"]
        let strArray: [String: Any] = ["type": "array", "items": ["type": "string"]]

        return [
            // MARK: Read Tools (4)
            tool(
                name: "library_overview",
                title: "Library Overview Atlas",
                description: "Library atlas: counts, compact folder profiles (8-char id, path, topTags, palette), smartFolders, topTags, taxonomy, boards, permissions. Call first.",
                properties: [
                    "compact": ["type": "boolean"],
                    "include_folder_profiles": ["type": "boolean"],
                    "include_boards": ["type": "boolean"],
                    "top_tags_limit": ["type": "integer"]
                ],
                readOnly: true
            ),
            tool(
                name: "query_assets",
                title: "Query & Visual Contact Sheet",
                description: "6-in-1 recall + numbered Contact Sheet (#01..#24): text/semantic `query` or `queries[]`, Inbox, folder, tags, CIELAB `tone`, `seed_asset_ids`/`unlike_asset_ids`, `diversify`, `include_folder_suggestions`, `session_id`. Accepts 8-char IDs.",
                properties: [
                    "query": ["type": "string"],
                    "queries": strArray,
                    "asset_ids": strArray,
                    "folder_id": ["type": "string"],
                    "folder_path": ["type": "string"],
                    "include_subfolders": ["type": "boolean"],
                    "smart_folder_id": ["type": "string"],
                    "smart_folder_name": ["type": "string"],
                    "tags": strArray,
                    "any_tags": strArray,
                    "exclude_tags": strArray,
                    "exclude_asset_ids": strArray,
                    "seed_asset_ids": strArray,
                    "unlike_asset_ids": strArray,
                    "media_kinds": ["type": "array", "items": ["type": "string", "enum": mediaKindEnum]],
                    "aspect_shape": ["type": "string", "enum": aspectShapeEnum],
                    "color_hex": ["type": "string"],
                    "color_tolerance": ["type": "number"],
                    "tone": ["type": "string"],
                    "min_rating": ["type": "integer"],
                    "only_inbox": ["type": "boolean"],
                    "only_untagged": ["type": "boolean"],
                    "only_recent_days": ["type": "integer"],
                    "only_pinned_offline": ["type": "boolean"],
                    "only_trashed": ["type": "boolean"],
                    "include_trashed": ["type": "boolean"],
                    "visual_rerank": ["type": "boolean"],
                    "diversify": ["type": "boolean"],
                    "contact_sheet": ["type": "boolean"],
                    "sheet_max_width": ["type": "integer"],
                    "include_folder_suggestions": ["type": "boolean"],
                    "include_facets": ["type": "boolean"],
                    "session_id": ["type": "string"],
                    "reset_session": ["type": "boolean"],
                    "sort_by": ["type": "string", "enum": sortByEnum],
                    "detail": ["type": "string", "enum": detailEnum],
                    "offset": ["type": "integer"],
                    "limit": ["type": "integer"]
                ],
                readOnly: true,
                openWorld: true
            ),
            tool(
                name: "inspect_assets",
                title: "Inspect Finalist Assets",
                description: "Full metadata (EXIF, AI prompts, social/GitHub, OCR, palette) for 1–12 assets. Supports `include_image`, normalized `crop_box` zoom, and `include_download_url`.",
                properties: [
                    "asset_id": ["type": "string"],
                    "asset_ids": strArray,
                    "include_image": ["type": "boolean"],
                    "image_max_side": ["type": "integer"],
                    "crop_box": [
                        "type": "object",
                        "properties": [
                            "x": ["type": "number"],
                            "y": ["type": "number"],
                            "width": ["type": "number"],
                            "height": ["type": "number"]
                        ]
                    ],
                    "include_download_url": ["type": "boolean"]
                ],
                readOnly: true
            ),
            tool(
                name: "get_board",
                title: "Get Moodboard or List Boards",
                description: "Omit `board_id`/`title` to list boards; pass either for full context (notes, sections, frames, connectors, palette, assets) and optional inline PNG `include_snapshot`.",
                properties: [
                    "board_id": ["type": "string"],
                    "title": ["type": "string"],
                    "detail": ["type": "string", "enum": detailEnum],
                    "include_snapshot": ["type": "boolean"],
                    "snapshot_width": ["type": "integer"],
                    "dark_appearance": ["type": "boolean"]
                ],
                readOnly: true
            ),

            // MARK: Safe Write Tools (6 — Zero Permanent Delete, All Emit `run_id`)
            tool(
                name: "ingest_assets",
                title: "Ingest Assets (Remote & Local)",
                description: "Import `web_url(s)`, remote `inline_files` (base64), `text`, or local `file_path(s)` (stdio only). Allowed in `inboxAndEnrich`+; emits `run_id`.",
                properties: [
                    "web_url": ["type": "string"],
                    "web_urls": strArray,
                    "inline_files": [
                        "type": "array",
                        "items": [
                            "type": "object",
                            "properties": [
                                "filename": ["type": "string"],
                                "data_base64": ["type": "string"]
                            ],
                            "required": ["filename", "data_base64"]
                        ]
                    ],
                    "text": ["type": "string"],
                    "file_path": ["type": "string"],
                    "file_paths": strArray,
                    "title": ["type": "string"],
                    "notes": ["type": "string"],
                    "rating": ["type": "integer"],
                    "folder_id": ["type": "string"],
                    "folder_path": ["type": "string"],
                    "target_board_id": ["type": "string"],
                    "tags": strArray
                ],
                readOnly: false,
                idempotent: false,
                openWorld: true
            ),
            tool(
                name: "organize_assets",
                title: "Batch Organize & Enrich Assets",
                description: "Atomically update 1–50 assets via heterogeneous `items[]` or uniform `asset_ids[]`. Supports `dry_run:true`, canonical tag folding, soft Trash only, and `run_id` rollback.",
                properties: [
                    "dry_run": ["type": "boolean"],
                    "items": [
                        "type": "array",
                        "items": [
                            "type": "object",
                            "properties": [
                                "asset_id": ["type": "string"],
                                "folder_id": ["type": "string"],
                                "folder_path": ["type": "string"],
                                "move_to_inbox": ["type": "boolean"],
                                "add_tags": strArray,
                                "remove_tags": strArray,
                                "add_suggested_tags": strArray,
                                "accept_suggested_tags": ["type": "boolean"],
                                "dismiss_suggested_tags": strArray,
                                "rating": ["type": "integer"],
                                "title": ["type": "string"],
                                "notes": ["type": "string"],
                                "ai_description": ["type": "string"],
                                "pinned_offline": ["type": "boolean"],
                                "trashed": ["type": "boolean"],
                                "analyze": ["type": "boolean"],
                                "refresh_rich_metadata": ["type": "boolean"]
                            ],
                            "required": ["asset_id"]
                        ]
                    ],
                    "asset_ids": strArray,
                    "folder_id": ["type": "string"],
                    "folder_path": ["type": "string"],
                    "move_to_inbox": ["type": "boolean"],
                    "add_tags": strArray,
                    "remove_tags": strArray,
                    "add_suggested_tags": strArray,
                    "accept_suggested_tags": ["type": "boolean"],
                    "dismiss_suggested_tags": strArray,
                    "rating": ["type": "integer"],
                    "title": ["type": "string"],
                    "notes": ["type": "string"],
                    "ai_description": ["type": "string"],
                    "pinned_offline": ["type": "boolean"],
                    "trashed": ["type": "boolean"],
                    "analyze": ["type": "boolean"],
                    "refresh_rich_metadata": ["type": "boolean"]
                ],
                readOnly: false,
                idempotent: true
            ),
            tool(
                name: "manage_folder",
                title: "Create or Update Folder",
                description: "Create (`reuse_existing` default true) or update (rename/move/color/symbol) a folder. Folder deletion forbidden. Requires `readWriteOrganize`.",
                properties: [
                    "action": ["type": "string", "enum": ["create", "update"]],
                    "name": ["type": "string"],
                    "folder_id": ["type": "string"],
                    "folder_path": ["type": "string"],
                    "new_name": ["type": "string"],
                    "parent_id": ["type": "string"],
                    "parent_path": ["type": "string"],
                    "move_to_root": ["type": "boolean"],
                    "color_hex": ["type": "string"],
                    "custom_symbol": ["type": "string"],
                    "reuse_existing": ["type": "boolean"]
                ],
                required: ["action"],
                readOnly: false,
                idempotent: true
            ),
            tool(
                name: "save_moodboard",
                title: "Create or Patch Moodboard",
                description: "Create a Moodboard (`sections`/`asset_ids`/`prompt`) or non-destructively patch (`board_id`; preserves locked nodes). Requires `readWriteOrganize`; emits `run_id`.",
                properties: [
                    "board_id": ["type": "string"],
                    "title": ["type": "string"],
                    "new_title": ["type": "string"],
                    "subtitle": ["type": "string"],
                    "curator_note": ["type": "string"],
                    "layout_style": ["type": "string", "enum": ["magazine", "balanced", "compact"]],
                    "use_freeform": ["type": "boolean"],
                    "sections": [
                        "type": "array",
                        "items": [
                            "type": "object",
                            "properties": [
                                "title": ["type": "string"],
                                "tint": ["type": "string"],
                                "rationale": ["type": "string"],
                                "asset_ids": strArray,
                                "hero_asset_ids": strArray
                            ],
                            "required": ["title", "asset_ids"]
                        ]
                    ],
                    "asset_ids": strArray,
                    "hero_asset_ids": strArray,
                    "prompt": ["type": "string"],
                    "seed_asset_ids": strArray,
                    "required_tags": strArray,
                    "target_palette": strArray,
                    "folder_id": ["type": "string"],
                    "folder_path": ["type": "string"],
                    "preferred_count": ["type": "integer"],
                    "add_asset_ids": strArray,
                    "remove_asset_ids": strArray,
                    "remove_node_ids": strArray,
                    "add_section": ["type": "string"],
                    "section_tint": ["type": "string"],
                    "add_note": ["type": "string"],
                    "note_title": ["type": "string"],
                    "note_style": ["type": "string", "enum": ["paper", "ink", "warm", "sage", "slate"]]
                ],
                readOnly: false,
                idempotent: false
            ),
            tool(
                name: "deduplicate_assets",
                title: "Scan & Merge Duplicates",
                description: "`scan` (read-safe) detects duplicates with optional `contact_sheet:true`. `merge` (`readWriteOrganize`, `dry_run` supported) keeps master & soft-trashes dupes with `run_id`.",
                properties: [
                    "action": ["type": "string", "enum": ["scan", "merge"]],
                    "scope": ["type": "string", "enum": ["all", "inbox", "folder"]],
                    "folder_id": ["type": "string"],
                    "folder_path": ["type": "string"],
                    "include_subfolders": ["type": "boolean"],
                    "sensitivity": ["type": "string", "enum": ["strict", "balanced", "relaxed"]],
                    "media_kinds": ["type": "array", "items": ["type": "string", "enum": mediaKindEnum]],
                    "contact_sheet": ["type": "boolean"],
                    "sheet_max_width": ["type": "integer"],
                    "limit": ["type": "integer"],
                    "dry_run": ["type": "boolean"],
                    "groups": [
                        "type": "array",
                        "items": [
                            "type": "object",
                            "properties": [
                                "keep_asset_id": ["type": "string"],
                                "discard_asset_ids": strArray
                            ],
                            "required": ["keep_asset_id", "discard_asset_ids"]
                        ]
                    ]
                ],
                required: ["action"],
                readOnly: false,
                idempotent: true
            ),
            tool(
                name: "rollback_run",
                title: "List or Rollback Agent Runs",
                description: "`list` (read-safe) shows recent agent write runs. `rollback` + `run_id` atomically restores assets, folders, and boards via compensating HLC ops.",
                properties: [
                    "action": ["type": "string", "enum": ["list", "rollback"]],
                    "run_id": ["type": "string"],
                    "limit": ["type": "integer"]
                ],
                required: ["action"],
                readOnly: false,
                idempotent: true
            )
        ]
    }
}
