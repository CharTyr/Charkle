import Foundation

extension CharkleExternalAgentService {
    public static let serverVersion = "1.3.0"
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

    // MARK: - MCP Resources & Templates

    public static func mcpResourceDefinitions() -> [[String: Any]] {
        [
            [
                "uri": "charkle://library/overview",
                "name": "Library Overview Atlas",
                "description": "Counts, compact folder semantic profiles (recursive counts, topTags, palettes), smart folders, top tags, aspect/media mix, boards, and permissions.",
                "mimeType": "application/json"
            ],
            [
                "uri": "charkle://boards",
                "name": "Moodboards",
                "description": "All moodboards with IDs, titles, layout modes, counts, and palettes.",
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
                "description": "Full metadata for an asset UUID or 8+ char prefix (EXIF, AI prompts, social/GitHub, palette, OCR, local paths).",
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

    // MARK: - MCP Prompts (Low-Token Visual Workflows)

    public static func mcpPromptDefinitions() -> [[String: Any]] {
        [
            [
                "name": "triage_inbox",
                "description": "Visually inspect untriaged Inbox assets in 1 Contact Sheet + folder suggestions, then propose or apply clean organization.",
                "arguments": [
                    ["name": "limit", "description": "Inbox items per batch (default 16).", "required": false],
                    ["name": "apply_changes", "description": "'true' to apply via organize_assets; otherwise propose plan first.", "required": false]
                ]
            ],
            [
                "name": "curate_moodboard",
                "description": "Token-efficient grounded curation: orient via overview atlas, recall diversified multi-direction Contact Sheet in 1 call, compose structured Moodboard.",
                "arguments": [
                    ["name": "brief", "description": "Creative direction, style, mood, or color brief.", "required": true],
                    ["name": "folder_path", "description": "Optional folder path scope.", "required": false],
                    ["name": "count", "description": "Target references (default 10).", "required": false]
                ]
            ],
            [
                "name": "extract_design_tokens",
                "description": "Read a Moodboard's palette, notes, sections, and visual snapshot to generate structured design tokens.",
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
                ? "Apply via `organize_assets` (8-char short IDs supported; reuse existing folders/tags; never permanently delete)."
                : "Present a concise table of recommended folder, tags, and notes for user approval first."
            return [
                "description": "Triage untriaged Inbox assets in Charkle",
                "messages": [[
                    "role": "user",
                    "content": [
                        "type": "text",
                        "text": """
                        Triage up to \(limit) Inbox assets in Charkle (low-token workflow):
                        1. Call `library_overview` to inspect folder semantic profiles (`topTags`, `palette`) and canonical tags.
                        2. Call `list_inbox` with `limit: \(limit), render_contact_sheet: true` (auto `visual` manifest) to see all thumbnails + short IDs in 1 call.
                        3. Call `suggest_folder` on those `asset_ids` for grounded folder recommendations.
                        4. Reuse existing folder paths and tag vocabulary rather than inventing duplicates.
                        5. \(actionLine)
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
                        Curate a Charkle Moodboard for: "\(effectiveBrief)" (target ~\(count) assets, minimal token budget):
                        1. Call `library_overview` to read folder semantic profiles (`topTags`, `palette`, `recursiveAssetCount`).
                        2. \(scopeHint) Run `semantic_search` (supports multi-direction `queries:[...]`, bilingual EN/ZH terms, CIELAB `tone`, `diversify:true`, `render_contact_sheet:true`) or `search_assets` to inspect distinct candidates in ONE Contact Sheet.
                        3. If refining, pass `seed_asset_ids` (more like these), `unlike_asset_ids` (steer away from these styles), or `exclude_asset_ids` using 8-char short IDs.
                        4. Batch-call `get_asset(asset_ids:[...])` only if finalist details are needed, then call `compose_moodboard` with 2–3 `sections`, `hero_asset_ids`, and a concise `curator_note`.
                        """
                    ]
                ]]
            ]

        case "extract_design_tokens":
            let board = strArg("board")
            let format = strArg("format").isEmpty ? "css" : strArg("format")
            let boardHint = board.isEmpty
                ? "Call `list_boards` to locate the target moodboard."
                : "Target moodboard: `\(board)`."
            return [
                "description": "Extract design tokens from a Charkle Moodboard",
                "messages": [[
                    "role": "user",
                    "content": [
                        "type": "text",
                        "text": """
                        Extract production-ready `\(format)` design tokens from my Charkle Moodboard:
                        1. \(boardHint)
                        2. Call `get_board_context` to read the harmonized HEX/CIELAB palette, notes, sections, and connectors.
                        3. Call `export_board_image` (use `width: 1200`) to inspect visual mood, contrast, and hierarchy.
                        4. Output semantic tokens (surface, ink, accent, muted, borders, typography/spacing cues) in `\(format)`.
                        """
                    ]
                ]]
            ]

        case "inspect_ai_prompts":
            let query = strArg("query")
            let limit = strArg("limit").isEmpty ? "12" : strArg("limit")
            let searchStep = query.isEmpty
                ? "Call `search_assets` with `media_kinds: [\"image\"], limit: \(limit)`."
                : "Call `search_assets` with `query: \"\(query)\", media_kinds: [\"image\"], limit: \(limit)`."
            return [
                "description": "Inspect embedded AI generation prompts and parameters",
                "messages": [[
                    "role": "user",
                    "content": [
                        "type": "text",
                        "text": """
                        Inspect AI-generated references in Charkle:
                        1. \(searchStep)
                        2. Batch-call `get_asset` with `asset_ids: [...]` (up to 12 at once) to read `richMetadata.aiGeneration` (`generator`, `modelName`, `prompt`, `negativePrompt`, `sampler`, `steps`, `cfgScale`, `seed`, `loras`).
                        3. Summarize recurring prompt patterns, model/LoRA recipes, and parameter differences.
                        """
                    ]
                ]]
            ]

        default:
            return nil
        }
    }

    // MARK: - MCP Tool Schema Registry (20 Safe Tools — Lean, Token-Efficient, Never Permanent Delete)

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
            // MARK: Read Tools (12)
            tool(
                name: "library_overview",
                title: "Library Overview",
                description: "Semantic atlas: counts, compact folders (8-char id, path, recursiveAssetCount, topTags, palette), smartFolders, topTags, aspect/media mix, boards, policy. Call first.",
                properties: [
                    "compact": ["type": "boolean"],
                    "include_folder_profiles": ["type": "boolean"],
                    "include_boards": ["type": "boolean"],
                    "top_tags_limit": ["type": "integer", "minimum": 5, "maximum": 80]
                ],
                readOnly: true
            ),
            tool(
                name: "search_assets",
                title: "Search Assets",
                description: "Filter & paginate assets (FTS/Pinyin, folder incl. subfolders, tags=AND, any_tags=OR, exclude_tags/ids, color, tone=dark|light|warm|cool|vivid|muted|high_contrast, kind, shape, rating, smart folder). Supports diversify=true, auto facets, detail=visual|compact|standard|full, and one-shot render_contact_sheet=true (auto visual manifest, 8-char IDs accepted everywhere).",
                properties: [
                    "query": ["type": "string"],
                    "folder_id": ["type": "string"],
                    "folder_path": ["type": "string"],
                    "include_subfolders": ["type": "boolean"],
                    "smart_folder_id": ["type": "string"],
                    "smart_folder_name": ["type": "string"],
                    "tags": strArray,
                    "any_tags": strArray,
                    "exclude_tags": strArray,
                    "exclude_asset_ids": strArray,
                    "media_kinds": ["type": "array", "items": ["type": "string", "enum": mediaKindEnum]],
                    "aspect_shape": ["type": "string", "enum": aspectShapeEnum],
                    "color_hex": ["type": "string"],
                    "color_tolerance": ["type": "number"],
                    "tone": ["type": "string"],
                    "min_rating": ["type": "integer", "minimum": 0, "maximum": 5],
                    "only_inbox": ["type": "boolean"],
                    "only_untagged": ["type": "boolean"],
                    "only_recent_days": ["type": "integer", "minimum": 1],
                    "only_pinned_offline": ["type": "boolean"],
                    "only_trashed": ["type": "boolean"],
                    "include_trashed": ["type": "boolean"],
                    "sort_by": ["type": "string", "enum": sortByEnum],
                    "detail": ["type": "string", "enum": detailEnum],
                    "diversify": ["type": "boolean"],
                    "include_facets": ["type": "boolean"],
                    "render_contact_sheet": ["type": "boolean"],
                    "sheet_max_width": ["type": "integer", "minimum": 512, "maximum": 1920],
                    "output_path": ["type": "string"],
                    "offset": ["type": "integer", "minimum": 0],
                    "limit": ["type": "integer", "minimum": 1, "maximum": 100]
                ],
                readOnly: true
            ),
            tool(
                name: "list_inbox",
                title: "List Inbox",
                description: "List untriaged Inbox assets (default limit=20). Pass render_contact_sheet=true for inline numbered thumbnails.",
                properties: [
                    "media_kinds": ["type": "array", "items": ["type": "string", "enum": mediaKindEnum]],
                    "sort_by": ["type": "string", "enum": sortByEnum],
                    "detail": ["type": "string", "enum": detailEnum],
                    "render_contact_sheet": ["type": "boolean"],
                    "sheet_max_width": ["type": "integer", "minimum": 512, "maximum": 1920],
                    "offset": ["type": "integer", "minimum": 0],
                    "limit": ["type": "integer", "minimum": 1, "maximum": 100]
                ],
                readOnly: true
            ),
            tool(
                name: "get_asset",
                title: "Get Asset Details",
                description: "Full metadata (EXIF, AI prompts, social/GitHub, OCR, local paths) for 1 UUID/8-char prefix (`asset_id`) or 1–12 finalists (`asset_ids`). include_image=true attaches preview JPEG (or zoomed sheet for batch).",
                properties: [
                    "asset_id": ["type": "string"],
                    "asset_ids": strArray,
                    "include_image": ["type": "boolean"],
                    "image_max_side": ["type": "integer", "minimum": 280, "maximum": 1568]
                ],
                readOnly: true
            ),
            tool(
                name: "render_contact_sheet",
                title: "Render Visual Contact Sheet",
                description: "Render 1–24 assets (default 16, max_width=1024, auto visual manifest) into a numbered Contact Sheet JPEG (#01..#24). Accepts asset_ids, multi-intent queries[], or filters + tone + diversify.",
                properties: [
                    "asset_ids": strArray,
                    "query": ["type": "string"],
                    "queries": strArray,
                    "folder_id": ["type": "string"],
                    "folder_path": ["type": "string"],
                    "include_subfolders": ["type": "boolean"],
                    "smart_folder_id": ["type": "string"],
                    "smart_folder_name": ["type": "string"],
                    "tags": strArray,
                    "any_tags": strArray,
                    "exclude_tags": strArray,
                    "exclude_asset_ids": strArray,
                    "media_kinds": ["type": "array", "items": ["type": "string", "enum": mediaKindEnum]],
                    "aspect_shape": ["type": "string", "enum": aspectShapeEnum],
                    "min_rating": ["type": "integer", "minimum": 0, "maximum": 5],
                    "only_inbox": ["type": "boolean"],
                    "only_untagged": ["type": "boolean"],
                    "only_trashed": ["type": "boolean"],
                    "color_hex": ["type": "string"],
                    "color_tolerance": ["type": "number"],
                    "tone": ["type": "string"],
                    "sort_by": ["type": "string", "enum": sortByEnum],
                    "detail": ["type": "string", "enum": ["visual", "compact"]],
                    "diversify": ["type": "boolean"],
                    "offset": ["type": "integer", "minimum": 0],
                    "limit": ["type": "integer", "minimum": 1, "maximum": 24],
                    "max_width": ["type": "integer", "minimum": 512, "maximum": 1920],
                    "include_image": ["type": "boolean"],
                    "output_path": ["type": "string"]
                ],
                readOnly: true
            ),
            tool(
                name: "find_similar_assets",
                title: "Find Visually Similar Assets",
                description: "Find visually similar assets (Vision FeaturePrint + CIELAB palette + tags, default limit=12). Supports unlike_asset_ids repulsion, diversify, and inline render_contact_sheet.",
                properties: [
                    "asset_id": ["type": "string"],
                    "limit": ["type": "integer", "minimum": 1, "maximum": 32],
                    "exclude_asset_ids": strArray,
                    "unlike_asset_ids": strArray,
                    "detail": ["type": "string", "enum": detailEnum],
                    "diversify": ["type": "boolean"],
                    "render_contact_sheet": ["type": "boolean"],
                    "sheet_max_width": ["type": "integer", "minimum": 512, "maximum": 1920]
                ],
                required: ["asset_id"],
                readOnly: true
            ),
            tool(
                name: "semantic_search",
                title: "Semantic Search",
                description: "Bilingual EN↔ZH + CIELAB tone/aspect + folder/tag + Vision seed/unlike hybrid search. Pass `query` or multi-direction `queries[]` (2–6 intents in 1 Contact Sheet!), `seed_asset_ids` (more like), `unlike_asset_ids` (less like), `tone` (dark|light|warm|cool|vivid|muted|high_contrast), `diversify`, `render_contact_sheet`.",
                properties: [
                    "query": ["type": "string"],
                    "queries": strArray,
                    "seed_asset_ids": strArray,
                    "unlike_asset_ids": strArray,
                    "folder_id": ["type": "string"],
                    "folder_path": ["type": "string"],
                    "include_subfolders": ["type": "boolean"],
                    "tags": strArray,
                    "any_tags": strArray,
                    "exclude_tags": strArray,
                    "exclude_asset_ids": strArray,
                    "media_kinds": ["type": "array", "items": ["type": "string", "enum": mediaKindEnum]],
                    "aspect_shape": ["type": "string", "enum": aspectShapeEnum],
                    "color_hex": ["type": "string"],
                    "tone": ["type": "string"],
                    "min_rating": ["type": "integer", "minimum": 0, "maximum": 5],
                    "visual_rerank": ["type": "boolean"],
                    "diversify": ["type": "boolean"],
                    "include_facets": ["type": "boolean"],
                    "detail": ["type": "string", "enum": detailEnum],
                    "render_contact_sheet": ["type": "boolean"],
                    "sheet_max_width": ["type": "integer", "minimum": 512, "maximum": 1920],
                    "output_path": ["type": "string"],
                    "limit": ["type": "integer", "minimum": 1, "maximum": 50]
                ],
                readOnly: true,
                openWorld: true
            ),
            tool(
                name: "quick_jump",
                title: "Quick Jump",
                description: "Fast fuzzy lookup across folders, moodboards, tags, and assets (Chinese & Pinyin, default limit=20).",
                properties: [
                    "query": ["type": "string"],
                    "limit": ["type": "integer", "minimum": 1, "maximum": 50]
                ],
                required: ["query"],
                readOnly: true
            ),
            tool(
                name: "suggest_folder",
                title: "Suggest Folder for Assets",
                description: "Recommend best existing folder for 1–20 assets via visual similarity and tag/palette affinity.",
                properties: [
                    "asset_id": ["type": "string"],
                    "asset_ids": strArray
                ],
                readOnly: true
            ),
            tool(
                name: "list_boards",
                title: "List Moodboards",
                description: "List all Moodboards (ID, title, subtitle, layout mode, item count, palette, updatedAt).",
                properties: [:],
                readOnly: true
            ),
            tool(
                name: "get_board_context",
                title: "Get Moodboard Context",
                description: "Read Moodboard context: notes, sections, frames, crops, connectors, palette, candidates, assets (by board_id/prefix or title).",
                properties: [
                    "board_id": ["type": "string"],
                    "title": ["type": "string"],
                    "detail": ["type": "string", "enum": detailEnum]
                ],
                readOnly: true
            ),
            tool(
                name: "export_board_image",
                title: "Export Moodboard PNG",
                description: "Headlessly render Moodboard to PNG (default width=1440, include_image=true, optional output_path).",
                properties: [
                    "board_id": ["type": "string"],
                    "title": ["type": "string"],
                    "width": ["type": "integer", "minimum": 840, "maximum": 2800],
                    "dark_appearance": ["type": "boolean"],
                    "include_image": ["type": "boolean"],
                    "output_path": ["type": "string"]
                ],
                readOnly: true
            ),

            // MARK: Safe Write Tools (8 — Zero Permanent Delete)
            tool(
                name: "organize_assets",
                title: "Organize Assets",
                description: "Batch-update assets (8-char IDs ok): folder/Inbox, add/remove/suggested tags, rating, title, notes, ai_description, offline pin. Requires write permission.",
                properties: [
                    "asset_ids": strArray,
                    "folder_id": ["type": "string"],
                    "folder_path": ["type": "string"],
                    "move_to_inbox": ["type": "boolean"],
                    "add_tags": strArray,
                    "remove_tags": strArray,
                    "dismiss_suggested_tags": strArray,
                    "accept_suggested_tags": ["type": "boolean"],
                    "rating": ["type": "integer", "minimum": 0, "maximum": 5],
                    "title": ["type": "string"],
                    "notes": ["type": "string"],
                    "ai_description": ["type": "string"],
                    "pinned_offline": ["type": "boolean"]
                ],
                required: ["asset_ids"],
                readOnly: false,
                idempotent: true
            ),
            tool(
                name: "create_folder",
                title: "Create Folder",
                description: "Create a folder (optional parent, color, SF Symbol). Requires write permission.",
                properties: [
                    "name": ["type": "string"],
                    "parent_id": ["type": "string"],
                    "parent_path": ["type": "string"],
                    "color_hex": ["type": "string"],
                    "custom_symbol": ["type": "string"]
                ],
                required: ["name"],
                readOnly: false,
                idempotent: false
            ),
            tool(
                name: "update_folder",
                title: "Update Folder",
                description: "Rename, move, or style a folder (deleting folders is disabled). Requires write permission.",
                properties: [
                    "folder_id": ["type": "string"],
                    "folder_path": ["type": "string"],
                    "new_name": ["type": "string"],
                    "parent_id": ["type": "string"],
                    "parent_path": ["type": "string"],
                    "move_to_root": ["type": "boolean"],
                    "color_hex": ["type": "string"],
                    "custom_symbol": ["type": "string"]
                ],
                readOnly: false,
                idempotent: true
            ),
            tool(
                name: "ingest_asset",
                title: "Ingest Asset",
                description: "Import local files/dirs, web/social/GitHub URLs, or text snippet with optional folder, board, tags, notes, rating. Requires write permission.",
                properties: [
                    "file_path": ["type": "string"],
                    "file_paths": strArray,
                    "web_url": ["type": "string"],
                    "web_urls": strArray,
                    "text": ["type": "string"],
                    "title": ["type": "string"],
                    "notes": ["type": "string"],
                    "rating": ["type": "integer", "minimum": 0, "maximum": 5],
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
                name: "compose_moodboard",
                title: "Compose Moodboard",
                description: "Create a Moodboard via explicit `sections`/`asset_ids` (8-char IDs ok) or `prompt` harness mode. Requires write permission.",
                properties: [
                    "title": ["type": "string"],
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
                                "tint": ["type": "string", "enum": ["neutral", "sand", "sage", "slate", "terracotta", "ocean"]],
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
                    "preferred_count": ["type": "integer", "minimum": 2, "maximum": 24]
                ],
                readOnly: false,
                idempotent: false
            ),
            tool(
                name: "patch_moodboard",
                title: "Patch Moodboard",
                description: "Non-destructively update a Moodboard: rename, layout, append cards/sections/notes without overlap, remove unlocked nodes. Requires write permission.",
                properties: [
                    "board_id": ["type": "string"],
                    "title": ["type": "string"],
                    "new_title": ["type": "string"],
                    "subtitle": ["type": "string"],
                    "use_freeform": ["type": "boolean"],
                    "layout_style": ["type": "string", "enum": ["magazine", "balanced", "compact"]],
                    "add_asset_ids": strArray,
                    "remove_asset_ids": strArray,
                    "remove_node_ids": strArray,
                    "add_section": ["type": "string"],
                    "section_tint": ["type": "string", "enum": ["neutral", "sand", "sage", "slate", "terracotta", "ocean"]],
                    "add_note": ["type": "string"],
                    "note_title": ["type": "string"],
                    "note_style": ["type": "string", "enum": ["paper", "ink", "warm", "sage", "slate"]]
                ],
                readOnly: false,
                idempotent: false
            ),
            tool(
                name: "trash_assets",
                title: "Move Assets to/from Trash",
                description: "Soft-move assets to Trash (`trashed:true`, default) or restore (`trashed:false`). Permanent deletion is forbidden.",
                properties: [
                    "asset_ids": strArray,
                    "trashed": ["type": "boolean"]
                ],
                required: ["asset_ids"],
                readOnly: false,
                idempotent: true
            ),
            tool(
                name: "analyze_assets",
                title: "Analyze & Hydrate Assets",
                description: "Run local Apple Vision (colors/OCR/FeaturePrint) + EXIF/AI prompt extraction on 1–20 assets; optionally refresh live web metadata.",
                properties: [
                    "asset_ids": strArray,
                    "refresh_rich_metadata": ["type": "boolean"]
                ],
                required: ["asset_ids"],
                readOnly: false,
                idempotent: true,
                openWorld: true
            )
        ]
    }
}
