import Foundation

extension CharkleExternalAgentService {
    public static let serverVersion = "1.2.0"
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
                "name": "Charkle Library Overview",
                "description": "Folders, smart folders, top tags, media distribution, counts, and active external agent permission policy.",
                "mimeType": "application/json"
            ],
            [
                "uri": "charkle://boards",
                "name": "Charkle Moodboards",
                "description": "Summary list of all moodboards in Charkle with palettes and layout modes.",
                "mimeType": "application/json"
            ],
            [
                "uri": "charkle://folders",
                "name": "Charkle Folder Tree",
                "description": "Full hierarchical folder tree with UUIDs, paths, parent IDs, colors, and asset counts.",
                "mimeType": "application/json"
            ],
            [
                "uri": "charkle://smart-folders",
                "name": "Charkle Smart Folders",
                "description": "Saved rule-based smart folders with current match counts.",
                "mimeType": "application/json"
            ]
        ]
    }

    public static func mcpResourceTemplateDefinitions() -> [[String: Any]] {
        [
            [
                "uriTemplate": "charkle://assets/{asset_id}",
                "name": "Charkle Asset Details",
                "description": "Complete metadata for a single asset UUID including EXIF, AI generation prompts, social/GitHub metadata, palette, OCR, and local paths.",
                "mimeType": "application/json"
            ],
            [
                "uriTemplate": "charkle://boards/{board_id}",
                "name": "Charkle Moodboard Context",
                "description": "Full structured design context for a Moodboard UUID including notes, sections, connectors, harmonized palette, and referenced assets.",
                "mimeType": "application/json"
            ]
        ]
    }

    // MARK: - MCP Prompts (Curated Studio Workflows)

    public static func mcpPromptDefinitions() -> [[String: Any]] {
        [
            [
                "name": "triage_inbox",
                "description": "Inspect untriaged Charkle Inbox assets visually with Contact Sheets and folder recommendations, then propose or apply clean folder & tag organization.",
                "arguments": [
                    [
                        "name": "limit",
                        "description": "Maximum number of Inbox items to review in this batch (default 16).",
                        "required": false
                    ],
                    [
                        "name": "apply_changes",
                        "description": "Set to 'true' to apply changes immediately when write access is enabled; otherwise propose a reviewable plan first.",
                        "required": false
                    ]
                ]
            ],
            [
                "name": "curate_moodboard",
                "description": "End-to-end grounded visual curation workflow: inspect the library, recall candidates, inspect Contact Sheets visually, and compose a structured Moodboard.",
                "arguments": [
                    [
                        "name": "brief",
                        "description": "Creative direction, style, mood, or color brief for the moodboard.",
                        "required": true
                    ],
                    [
                        "name": "folder_path",
                        "description": "Optional folder path to restrict candidate assets.",
                        "required": false
                    ],
                    [
                        "name": "count",
                        "description": "Target number of visual references (default 10).",
                        "required": false
                    ]
                ]
            ],
            [
                "name": "extract_design_tokens",
                "description": "Read a Charkle Moodboard's harmonized palette, curator notes, section themes, and exported visual snapshot to generate structured design tokens (CSS / Tailwind / SwiftUI).",
                "arguments": [
                    [
                        "name": "board",
                        "description": "Moodboard title or UUID.",
                        "required": true
                    ],
                    [
                        "name": "format",
                        "description": "Target output format such as 'css', 'tailwind', 'swiftui', or 'json' (default 'css').",
                        "required": false
                    ]
                ]
            ],
            [
                "name": "inspect_ai_prompts",
                "description": "Search AI-generated reference images in Charkle and extract their embedded generation prompts, models, samplers, seeds, and LoRA recipes.",
                "arguments": [
                    [
                        "name": "query",
                        "description": "Optional keyword, model name, or style filter.",
                        "required": false
                    ],
                    [
                        "name": "limit",
                        "description": "Maximum number of assets to inspect (default 12).",
                        "required": false
                    ]
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
                ? "After confirming folder fit and normalized tags, call `organize_assets` to apply the plan (only if write access is enabled; never delete anything permanently)."
                : "Present a concise table of recommended folder, tags, and notes per item for user approval before calling `organize_assets`."
            return [
                "description": "Triage untriaged Inbox assets in Charkle",
                "messages": [[
                    "role": "user",
                    "content": [
                        "type": "text",
                        "text": """
                        Please triage up to \(limit) untriaged assets in my Charkle Inbox:
                        1. Call `library_overview` to understand my existing folder hierarchy and canonical tag vocabulary.
                        2. Call `render_contact_sheet` with `only_inbox: true, limit: \(limit)` so you can visually inspect the items.
                        3. Call `suggest_folder` on those Inbox `asset_ids` to get grounded folder recommendations.
                        4. Reuse existing folder paths and tag naming conventions wherever possible instead of inventing duplicate tags.
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
                ? "Search across the full library."
                : "Focus primarily on folder `\(folder)` (with `include_subfolders: true`)."
            return [
                "description": "Curate a grounded Charkle Moodboard",
                "messages": [[
                    "role": "user",
                    "content": [
                        "type": "text",
                        "text": """
                        Curate a Charkle Moodboard for this brief: "\(effectiveBrief)" (target ~\(count) references).
                        1. Call `library_overview` to discover folders, tags, and media kinds.
                        2. \(scopeHint) Combine `search_assets` / `semantic_search` and `find_similar_assets` around strong anchors to gather ~16–24 candidates.
                        3. Call `render_contact_sheet` on the candidate `asset_ids` to visually inspect composition, lighting, color harmony, and avoid near-duplicates.
                        4. Select the strongest ~\(count) assets grouped into 2–3 purposeful sections with hero picks, then call `compose_moodboard` with explicit `sections`, `hero_asset_ids`, and a concise `curator_note`.
                        """
                    ]
                ]]
            ]

        case "extract_design_tokens":
            let board = strArg("board")
            let format = strArg("format").isEmpty ? "css" : strArg("format")
            let boardHint = board.isEmpty
                ? "First call `list_boards` to locate the target moodboard, then inspect it."
                : "Target moodboard: `\(board)`."
            return [
                "description": "Extract design tokens from a Charkle Moodboard",
                "messages": [[
                    "role": "user",
                    "content": [
                        "type": "text",
                        "text": """
                        Extract production-ready `\(format)` design tokens from my Charkle Moodboard.
                        1. \(boardHint)
                        2. Call `get_board_context` to read the harmonized HEX/CIELAB palette, curator notes, section groupings, connectors, and referenced assets.
                        3. Call `export_board_image` to inspect the actual visual mood, contrast, and hierarchy.
                        4. Output clean semantic tokens (surface, ink, accent, muted, borders, typography/spacing cues) in `\(format)` format grounded directly in the board's palette and notes.
                        """
                    ]
                ]]
            ]

        case "inspect_ai_prompts":
            let query = strArg("query")
            let limit = strArg("limit").isEmpty ? "12" : strArg("limit")
            let searchStep = query.isEmpty
                ? "Call `search_assets` with `media_kinds: [\"image\"]` and `limit: \(limit)`."
                : "Call `search_assets` with `query: \"\(query)\"`, `media_kinds: [\"image\"]`, and `limit: \(limit)`."
            return [
                "description": "Inspect embedded AI generation prompts and parameters",
                "messages": [[
                    "role": "user",
                    "content": [
                        "type": "text",
                        "text": """
                        Inspect AI-generated visual references in my Charkle library:
                        1. \(searchStep)
                        2. Call `get_asset` on relevant candidates to read their hydrated `richMetadata.aiGeneration` fields (`generator`, `modelName`, `prompt`, `negativePrompt`, `sampler`, `steps`, `cfgScale`, `seed`, `loras`).
                        3. Summarize recurring prompt patterns, model/LoRA combinations, and notable parameter differences.
                        """
                    ]
                ]]
            ]

        default:
            return nil
        }
    }

    // MARK: - MCP Tool Schema Registry (20 Safe Tools — Never Permanent Delete)

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

        return [
            // MARK: Read Tools (12)
            tool(
                name: "library_overview",
                title: "Library Overview",
                description: "Get a complete overview of the Charkle visual reference library: total/inbox/untagged/trashed counts, hierarchical folder tree, smart folders, top tags, media distribution, board count, cache stats, and active external agent permissions.",
                properties: [:],
                readOnly: true
            ),
            tool(
                name: "search_assets",
                title: "Search Assets",
                description: "Search and paginate assets in Charkle by full-text query (Chinese, Pinyin, tags, OCR, AI descriptions, EXIF, AI prompts), folder (with optional subfolder recursion), smart folder, tags, CIELAB dominant color, media kinds, aspect shape, rating, recency, or Trash state.",
                properties: [
                    "query": ["type": "string", "description": "Full-text search query across titles, notes, tags, OCR, AI descriptions, EXIF, and AI generation prompts."],
                    "folder_id": ["type": "string", "description": "Optional folder UUID."],
                    "folder_path": ["type": "string", "description": "Optional folder path or name, e.g. 'UI Inspiration' or '插画/常夏'."],
                    "include_subfolders": ["type": "boolean", "description": "When filtering by folder_id or folder_path, include all nested descendant folders (default false)."],
                    "smart_folder_id": ["type": "string", "description": "Optional Smart Folder UUID to evaluate."],
                    "smart_folder_name": ["type": "string", "description": "Optional Smart Folder name lookup."],
                    "tags": ["type": "array", "items": ["type": "string"], "description": "Filter assets having all given tags."],
                    "media_kinds": ["type": "array", "items": ["type": "string", "enum": mediaKindEnum], "description": "Filter by media kinds (image, animatedImage, video, webBookmark, document, designFile, audio, model3D)."],
                    "aspect_shape": ["type": "string", "enum": aspectShapeEnum, "description": "Filter by aspect ratio shape (landscape, portrait, square, ultrawide)."],
                    "color_hex": ["type": "string", "description": "Dominant color hex filter such as '#C86D51'."],
                    "color_tolerance": ["type": "number", "description": "CIELAB DeltaE tolerance (default 28)."],
                    "min_rating": ["type": "integer", "minimum": 0, "maximum": 5, "description": "Minimum star rating (0-5)."],
                    "only_inbox": ["type": "boolean", "description": "Only return untriaged Inbox assets."],
                    "only_untagged": ["type": "boolean", "description": "Only return assets with no tags."],
                    "only_recent_days": ["type": "integer", "minimum": 1, "description": "Only return assets added within the last N days."],
                    "only_pinned_offline": ["type": "boolean", "description": "Only return offline-pinned assets."],
                    "only_trashed": ["type": "boolean", "description": "Only return assets currently in Trash (useful for inspection or restore)."],
                    "include_trashed": ["type": "boolean", "description": "Include trashed assets alongside active assets (default false)."],
                    "sort_by": ["type": "string", "enum": sortByEnum, "description": "Sort order (default 'relevance' when query is provided, otherwise 'newest')."],
                    "offset": ["type": "integer", "minimum": 0, "description": "Pagination offset (default 0)."],
                    "limit": ["type": "integer", "minimum": 1, "maximum": 100, "description": "Max items to return (1-100, default 30)."]
                ],
                readOnly: true
            ),
            tool(
                name: "list_inbox",
                title: "List Inbox",
                description: "List untriaged assets currently in Charkle's Inbox with optional pagination, media-kind filtering, and sorting.",
                properties: [
                    "media_kinds": ["type": "array", "items": ["type": "string", "enum": mediaKindEnum], "description": "Optional media kind filter."],
                    "sort_by": ["type": "string", "enum": sortByEnum, "description": "Sort order (default 'newest')."],
                    "offset": ["type": "integer", "minimum": 0, "description": "Pagination offset (default 0)."],
                    "limit": ["type": "integer", "minimum": 1, "maximum": 100, "description": "Max items to return (1-100, default 40)."]
                ],
                readOnly: true
            ),
            tool(
                name: "get_asset",
                title: "Get Asset Details",
                description: "Get complete metadata for a single asset UUID: dimensions, palette, OCR text, tags, notes, camera EXIF, AI generation prompts/models/LoRAs, social post or GitHub repository metadata, local paths, and optional inline preview JPEG.",
                properties: [
                    "asset_id": ["type": "string", "description": "Asset UUID."],
                    "include_image": ["type": "boolean", "description": "When true, also return an upright JPEG preview image block for direct visual inspection (default false)."],
                    "image_max_side": ["type": "integer", "minimum": 280, "maximum": 1568, "description": "Long-side pixel cap when include_image is true (default 800)."]
                ],
                required: ["asset_id"],
                readOnly: true
            ),
            tool(
                name: "render_contact_sheet",
                title: "Render Visual Contact Sheet",
                description: "Render up to 16 candidate assets into a numbered Visual Contact Sheet JPEG (#01..#16) returned as an image plus grounded slot-to-assetID JSON manifest. Supports pagination (`offset`), subfolder recursion, and all gallery filters.",
                properties: [
                    "asset_ids": ["type": "array", "items": ["type": "string"], "description": "Explicit asset UUIDs to render (up to 16)."],
                    "query": ["type": "string", "description": "Search query when asset_ids is omitted."],
                    "folder_id": ["type": "string", "description": "Optional folder UUID filter."],
                    "folder_path": ["type": "string", "description": "Optional folder path filter."],
                    "include_subfolders": ["type": "boolean", "description": "Include nested descendant folders when filtering by folder (default false)."],
                    "smart_folder_id": ["type": "string", "description": "Optional Smart Folder UUID."],
                    "smart_folder_name": ["type": "string", "description": "Optional Smart Folder name."],
                    "tags": ["type": "array", "items": ["type": "string"], "description": "Optional required tag filter."],
                    "media_kinds": ["type": "array", "items": ["type": "string", "enum": mediaKindEnum], "description": "Optional media kind filter."],
                    "aspect_shape": ["type": "string", "enum": aspectShapeEnum, "description": "Optional aspect shape filter."],
                    "min_rating": ["type": "integer", "minimum": 0, "maximum": 5, "description": "Optional minimum star rating."],
                    "only_inbox": ["type": "boolean", "description": "Render current Inbox assets."],
                    "only_untagged": ["type": "boolean", "description": "Render untagged assets."],
                    "only_trashed": ["type": "boolean", "description": "Render trashed assets."],
                    "color_hex": ["type": "string", "description": "Optional color hex filter."],
                    "color_tolerance": ["type": "number", "description": "Optional CIELAB DeltaE tolerance (default 28)."],
                    "sort_by": ["type": "string", "enum": sortByEnum, "description": "Sort order when filtering."],
                    "offset": ["type": "integer", "minimum": 0, "description": "Pagination offset for browsing beyond 16 items (default 0)."],
                    "limit": ["type": "integer", "minimum": 1, "maximum": 16, "description": "Number of tiles (1-16, default 16)."],
                    "max_width": ["type": "integer", "minimum": 640, "maximum": 1920, "description": "Output canvas width in pixels (default 1280)."],
                    "include_image": ["type": "boolean", "description": "Include inline base64 JPEG in response (default true; set false when only saving output_path)."],
                    "output_path": ["type": "string", "description": "Optional local path to also write the JPEG file."]
                ],
                readOnly: true
            ),
            tool(
                name: "find_similar_assets",
                title: "Find Visually Similar Assets",
                description: "Find visually and stylistically similar assets to a reference asset UUID using Apple Vision FeaturePrint, CIELAB palette proximity, and shared tags. Optionally renders a Contact Sheet of the matches.",
                properties: [
                    "asset_id": ["type": "string", "description": "Reference asset UUID."],
                    "limit": ["type": "integer", "minimum": 1, "maximum": 32, "description": "Max similar assets to return (default 12)."],
                    "render_contact_sheet": ["type": "boolean", "description": "When true, also return a numbered Contact Sheet JPEG of the top similar matches (up to 16)."]
                ],
                required: ["asset_id"],
                readOnly: true
            ),
            tool(
                name: "semantic_search",
                title: "Semantic Search",
                description: "Run hybrid semantic + keyword + visual search across the Charkle library (automatically leverages configured cloud embeddings / visual reranking when available, falling back cleanly to local FTS5 + metadata ranking).",
                properties: [
                    "query": ["type": "string", "description": "Natural-language search description, mood, visual concept, or keywords."],
                    "folder_id": ["type": "string", "description": "Optional folder UUID filter."],
                    "folder_path": ["type": "string", "description": "Optional folder path filter."],
                    "include_subfolders": ["type": "boolean", "description": "Include nested descendant folders (default false)."],
                    "tags": ["type": "array", "items": ["type": "string"], "description": "Optional tag filter."],
                    "media_kinds": ["type": "array", "items": ["type": "string", "enum": mediaKindEnum], "description": "Optional media kind filter."],
                    "color_hex": ["type": "string", "description": "Optional dominant color hex filter."],
                    "min_rating": ["type": "integer", "minimum": 0, "maximum": 5, "description": "Optional minimum star rating."],
                    "limit": ["type": "integer", "minimum": 1, "maximum": 50, "description": "Max ranked hits to return (default 20)."]
                ],
                required: ["query"],
                readOnly: true,
                openWorld: true
            ),
            tool(
                name: "quick_jump",
                title: "Quick Jump",
                description: "Unified fast fuzzy search across folders, moodboards, tags, and assets — mirrors Charkle's Command-J Quick Jump palette.",
                properties: [
                    "query": ["type": "string", "description": "Keyword, Chinese text, or Pinyin initials."],
                    "limit": ["type": "integer", "minimum": 1, "maximum": 50, "description": "Max matches to return (default 20)."]
                ],
                required: ["query"],
                readOnly: true
            ),
            tool(
                name: "suggest_folder",
                title: "Suggest Folder for Assets",
                description: "Recommend the best existing Charkle folder for one or more assets (up to 20 per call) using visual similarity, palette/tag affinity, and smart triage rules.",
                properties: [
                    "asset_id": ["type": "string", "description": "Single asset UUID."],
                    "asset_ids": ["type": "array", "items": ["type": "string"], "description": "Batch of asset UUIDs (up to 20)."]
                ],
                readOnly: true
            ),
            tool(
                name: "list_boards",
                title: "List Moodboards",
                description: "List all Moodboards in Charkle with ID, title, subtitle, layout mode, item count, extracted palette HEX codes, offline pin status, and update timestamp.",
                properties: [:],
                readOnly: true
            ),
            tool(
                name: "get_board_context",
                title: "Get Moodboard Context",
                description: "Read full structured design context of a Moodboard: title, subtitle, curator notes, section groups, node frames, crops, connectors, ink count, harmonized HEX/CIELAB palette, candidate pool, and referenced assets with paths.",
                properties: [
                    "board_id": ["type": "string", "description": "Moodboard UUID."],
                    "title": ["type": "string", "description": "Moodboard title lookup when board_id is omitted."]
                ],
                readOnly: true
            ),
            tool(
                name: "export_board_image",
                title: "Export Moodboard PNG",
                description: "Render a Moodboard headlessly to high-resolution PNG and return the image directly (optionally saving to output_path).",
                properties: [
                    "board_id": ["type": "string", "description": "Moodboard UUID."],
                    "title": ["type": "string", "description": "Moodboard title lookup when board_id is omitted."],
                    "width": ["type": "integer", "minimum": 840, "maximum": 2800, "description": "Canvas width in pixels (default 1440)."],
                    "dark_appearance": ["type": "boolean", "description": "Render in dark studio theme (default false)."],
                    "include_image": ["type": "boolean", "description": "Include inline base64 PNG in response (default true; set false when only saving output_path)."],
                    "output_path": ["type": "string", "description": "Optional path to write the PNG file."]
                ],
                readOnly: true
            ),

            // MARK: Safe Write Tools (8 — Zero Permanent Delete)
            tool(
                name: "organize_assets",
                title: "Organize Assets",
                description: "Batch-organize assets: move to a folder or Inbox, add/remove tags, accept/dismiss suggested tags, set rating, notes, title, offline pin, or overwrite AI visual description. Requires write permission in Charkle Settings.",
                properties: [
                    "asset_ids": ["type": "array", "items": ["type": "string"], "description": "Asset UUIDs to update."],
                    "folder_id": ["type": "string", "description": "Move assets to this folder UUID."],
                    "folder_path": ["type": "string", "description": "Move assets to this folder path/name."],
                    "move_to_inbox": ["type": "boolean", "description": "Move assets back to Inbox."],
                    "add_tags": ["type": "array", "items": ["type": "string"], "description": "Tags to add."],
                    "remove_tags": ["type": "array", "items": ["type": "string"], "description": "Tags to remove."],
                    "dismiss_suggested_tags": ["type": "array", "items": ["type": "string"], "description": "AI suggested tags to dismiss."],
                    "accept_suggested_tags": ["type": "boolean", "description": "Accept all AI suggested tags into regular tags."],
                    "rating": ["type": "integer", "minimum": 0, "maximum": 5, "description": "Star rating 0-5."],
                    "title": ["type": "string", "description": "Set title."],
                    "notes": ["type": "string", "description": "Set notes."],
                    "ai_description": ["type": "string", "description": "Set or overwrite the visual AI description for these assets."],
                    "pinned_offline": ["type": "boolean", "description": "Pin or unpin originals for offline caching."]
                ],
                required: ["asset_ids"],
                readOnly: false,
                idempotent: true
            ),
            tool(
                name: "create_folder",
                title: "Create Folder",
                description: "Create a new folder in Charkle (optionally nested under parent_id or parent_path, with optional color/symbol). Requires write permission.",
                properties: [
                    "name": ["type": "string", "description": "New folder name."],
                    "parent_id": ["type": "string", "description": "Optional parent folder UUID."],
                    "parent_path": ["type": "string", "description": "Optional parent folder path."],
                    "color_hex": ["type": "string", "description": "Optional accent color hex such as '#2A60E0'."],
                    "custom_symbol": ["type": "string", "description": "Optional SF Symbol name for folder icon."]
                ],
                required: ["name"],
                readOnly: false,
                idempotent: false
            ),
            tool(
                name: "update_folder",
                title: "Update Folder",
                description: "Rename a folder, move it under a new parent (or to root), or update its color/symbol. Deleting folders is intentionally disabled for safety. Requires write permission.",
                properties: [
                    "folder_id": ["type": "string", "description": "Target folder UUID."],
                    "folder_path": ["type": "string", "description": "Target folder path or name when folder_id is omitted."],
                    "new_name": ["type": "string", "description": "Optional new folder name."],
                    "parent_id": ["type": "string", "description": "Move folder under this parent UUID."],
                    "parent_path": ["type": "string", "description": "Move folder under this parent path."],
                    "move_to_root": ["type": "boolean", "description": "Move folder to top-level root."],
                    "color_hex": ["type": "string", "description": "Set folder accent color hex (empty string clears)."],
                    "custom_symbol": ["type": "string", "description": "Set custom SF Symbol (empty string clears)."]
                ],
                readOnly: false,
                idempotent: true
            ),
            tool(
                name: "ingest_asset",
                title: "Ingest Asset",
                description: "Import one or more local files/directories, a web URL (including X/Threads/Bluesky posts and GitHub repos), or a text snippet into Charkle with optional folder, board, tags, notes, and rating. Requires write permission.",
                properties: [
                    "file_path": ["type": "string", "description": "Single local file or directory path to import."],
                    "file_paths": ["type": "array", "items": ["type": "string"], "description": "Batch of local file or directory paths to import."],
                    "web_url": ["type": "string", "description": "Web, GitHub repo, or X/Threads/Bluesky URL to bookmark/capture."],
                    "web_urls": ["type": "array", "items": ["type": "string"], "description": "Batch of web, GitHub repo, or X/Threads/Bluesky URLs to bookmark/capture."],
                    "text": ["type": "string", "description": "Text snippet to save as a reference card."],
                    "title": ["type": "string", "description": "Optional title for web_url or text."],
                    "notes": ["type": "string", "description": "Optional initial notes."],
                    "rating": ["type": "integer", "minimum": 0, "maximum": 5, "description": "Optional initial star rating (0-5)."],
                    "folder_id": ["type": "string", "description": "Optional destination folder UUID."],
                    "folder_path": ["type": "string", "description": "Optional destination folder path (defaults to Inbox)."],
                    "target_board_id": ["type": "string", "description": "Optional Moodboard UUID to also place imported assets onto."],
                    "tags": ["type": "array", "items": ["type": "string"], "description": "Optional initial tags."]
                ],
                readOnly: false,
                idempotent: false,
                openWorld: true
            ),
            tool(
                name: "compose_moodboard",
                title: "Compose Moodboard",
                description: "Create and save a new Moodboard in Charkle. Either pass explicit `sections` / `asset_ids` (after inspecting contact sheets) for direct art direction, or pass `prompt` to invoke Charkle's built-in Moodboard Agent Harness. Requires write permission.",
                properties: [
                    "title": ["type": "string", "description": "Moodboard title."],
                    "subtitle": ["type": "string", "description": "Short subtitle."],
                    "curator_note": ["type": "string", "description": "Art direction note card shown on the moodboard."],
                    "layout_style": ["type": "string", "enum": ["magazine", "balanced", "compact"], "description": "Editorial layout rhythm."],
                    "use_freeform": ["type": "boolean", "description": "Use freeform spatial canvas instead of Auto Editorial."],
                    "sections": [
                        "type": "array",
                        "description": "Explicit curated sections with asset_ids and optional hero_asset_ids.",
                        "items": [
                            "type": "object",
                            "properties": [
                                "title": ["type": "string"],
                                "tint": ["type": "string", "enum": ["neutral", "sand", "sage", "slate", "terracotta", "ocean"]],
                                "rationale": ["type": "string"],
                                "asset_ids": ["type": "array", "items": ["type": "string"]],
                                "hero_asset_ids": ["type": "array", "items": ["type": "string"]]
                            ],
                            "required": ["title", "asset_ids"]
                        ]
                    ],
                    "asset_ids": ["type": "array", "items": ["type": "string"], "description": "Flat list of asset UUIDs if not specifying sections."],
                    "hero_asset_ids": ["type": "array", "items": ["type": "string"], "description": "Optional hero asset UUIDs (weight=2)."],
                    "prompt": ["type": "string", "description": "Natural-language brief when delegating curation to Charkle's built-in harness."],
                    "seed_asset_ids": ["type": "array", "items": ["type": "string"], "description": "Optional visual anchor seed asset UUIDs when using prompt mode."],
                    "required_tags": ["type": "array", "items": ["type": "string"], "description": "Optional required tags when using prompt mode."],
                    "target_palette": ["type": "array", "items": ["type": "string"], "description": "Optional target color hexes (e.g. ['#C86D51', '#2A6F97']) when using prompt mode."],
                    "folder_id": ["type": "string", "description": "Optional scope folder UUID when using prompt mode."],
                    "folder_path": ["type": "string", "description": "Optional scope folder path when using prompt mode."],
                    "preferred_count": ["type": "integer", "minimum": 2, "maximum": 24, "description": "Max assets when using prompt mode (default 12)."]
                ],
                readOnly: false,
                idempotent: false
            ),
            tool(
                name: "patch_moodboard",
                title: "Patch Moodboard",
                description: "Modify an existing Moodboard non-destructively: rename, update subtitle, switch layout mode, append asset cards without overlapping existing nodes, remove unlocked cards or specific nodes, add section headers, or append a styled curator note. Requires write permission.",
                properties: [
                    "board_id": ["type": "string", "description": "Target Moodboard UUID."],
                    "title": ["type": "string", "description": "Existing board title lookup if board_id is omitted."],
                    "new_title": ["type": "string", "description": "Optional new title."],
                    "subtitle": ["type": "string", "description": "Optional updated subtitle."],
                    "use_freeform": ["type": "boolean", "description": "Optional switch between freeform and autoEditorial layout mode."],
                    "layout_style": ["type": "string", "enum": ["magazine", "balanced", "compact"], "description": "Optional editorial style when using autoEditorial mode."],
                    "add_asset_ids": ["type": "array", "items": ["type": "string"], "description": "Asset UUIDs to append cleanly below existing content."],
                    "remove_asset_ids": ["type": "array", "items": ["type": "string"], "description": "Unlocked asset UUIDs to remove."],
                    "remove_node_ids": ["type": "array", "items": ["type": "string"], "description": "Unlocked node UUIDs (notes, sections, or cards) to remove."],
                    "add_section": ["type": "string", "description": "Optional section header title to append."],
                    "section_tint": ["type": "string", "enum": ["neutral", "sand", "sage", "slate", "terracotta", "ocean"], "description": "Optional tint for add_section (default 'neutral')."],
                    "add_note": ["type": "string", "description": "Append a note card to the board."],
                    "note_title": ["type": "string", "description": "Title for the appended note card."],
                    "note_style": ["type": "string", "enum": ["paper", "ink", "warm", "sage", "slate"], "description": "Visual style for the appended note card (default 'paper')."]
                ],
                readOnly: false,
                idempotent: false
            ),
            tool(
                name: "trash_assets",
                title: "Move Assets to/from Trash",
                description: "Soft-move assets to Trash (or restore with trashed=false). External agents are NEVER allowed to permanently delete user assets. Requires write permission.",
                properties: [
                    "asset_ids": ["type": "array", "items": ["type": "string"], "description": "Asset UUIDs to move to or restore from Trash."],
                    "trashed": ["type": "boolean", "description": "true to move to Trash (default), false to restore."]
                ],
                required: ["asset_ids"],
                readOnly: false,
                idempotent: true
            ),
            tool(
                name: "analyze_assets",
                title: "Analyze & Hydrate Assets",
                description: "Run local Apple Vision analysis (dominant CIELAB colors, OCR text, FeaturePrint vector) and EXIF/AI prompt extraction on up to 20 assets; optionally refresh live GitHub/Social rich metadata for web bookmarks. Requires write permission.",
                properties: [
                    "asset_ids": ["type": "array", "items": ["type": "string"], "description": "Asset UUIDs to analyze (1-20)."],
                    "refresh_rich_metadata": ["type": "boolean", "description": "Also re-fetch live GitHub repo or X/Threads/Bluesky post metadata when applicable (default false)."]
                ],
                required: ["asset_ids"],
                readOnly: false,
                idempotent: true,
                openWorld: true
            )
        ]
    }
}
