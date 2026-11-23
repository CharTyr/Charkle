# PRD: M4 — Hybrid AI, TypeSafe Jev, 6-Tab Settings, Quick Drop Shelf & MCP

- **Parent Task**: `11-23-web-version`
- **Dependencies**: `11-23-web-m1-core-db-media-sync`, `11-23-web-m2-gallery-nav-quicklook`, `11-23-web-m3-moodboard-studio-figma`

## Goal
Complete all intelligence, configuration, capture, and external agent subsystems so Charkle Web matches macOS Charkle end-to-end: multi-provider Cloud AI + usage tracking, Experimental TypeSafe System One (Jev) visual grounding, complete 6-tab Settings Center + lossless Storage Migration Wizard, Web Quick Drop Shelf (Notch Shelf counterpart), and the 14-tool External Agent / MCP Server with policy gating and live SSE UI refresh.

## Requirements
1. **Hybrid AI & Usage Telemetry**:
   - Server-side `CloudAIProvider` supporting `disabled`, `chatGPTSubscription` (token/session flow + model list), `gemini` (multimodal + embedding), and `openAICompatible` across all 3 endpoint formats (`openAIChatCompletions`, `anthropicMessages`, `openAIResponses`).
   - Encrypted local secret vault (`0600`) for API keys and OAuth tokens; `autoAnalyzeOnImport` and `sendThumbnailsToCloud` privacy toggles; `CloudAIUsageTracker` recording per-provider/model requests, input/output tokens, and estimated USD cost.
2. **Experimental TypeSafe System One (Jev) Visual Grounding**:
   - `TypeSafeSystemOneClient` + `VisualGroundingEngine` supporting connection testing & model discovery, `locateVisualRegion` (semantic focus crop w/ low-confidence padding), `locateVisualMatch` (reference-to-target region match), `detectCleanContentBounds` (auto clean-crop chrome/margins), `extractSubjectPalette` (subject-aware CIELAB extraction), pinpoint callout annotations on Moodboard nodes, `semanticSearch` (hybrid visual + FTS5 + embedding), `batchTriageInbox` (folder classification with confidence & fit probability), and curator visual rerank — with graceful deterministic local fallback when Jev is disabled or unreachable.
3. **Complete 6-Tab Settings Center (`SettingsModal`)**:
   - `存储与同步`: Google Drive API v3 (OAuth Client ID/Secret setup, sign-in/out, root path, shared folder URL/ID + picker), WebDAV (server URL, username, password, remote path, connection test), Pure Local Folder path, `gdirect` interoperability guidance, auto-sync interval, thumbnail/embedding sync toggles, live `SyncStatus` bar, and **Lossless Storage Migration Wizard**.
   - `智能与搜索`: Cloud AI provider selector, endpoint format/model/API key config, ChatGPT account session status, Cloud AI usage dashboard, Experimental TypeSafe Jev toggle + thresholds + 7 scenario checkboxes + connection test.
   - `外观与图标`: Light / Dark / System appearance switcher, icon pack showcase (Duotone & Layered), reduced transparency / motion preview awareness.
   - `外部 Agent 与 MCP`: Enable toggle, permission level (`仅只读检索与导出` vs `允许整理与生成情绪板`), live HTTP MCP endpoint & stdio command snippet with 1-click copy, tool inventory preview.
   - `缓存空间`: Live `CacheStats` breakdown (thumbnails, cached originals, pinned offline, budget), 2–100 GB slider, manual "立即按 LRU 清理" button.
   - `采集与快捷键`: Quick Drop Shelf toggle & default drop target, Browser Screen Snapshot capture helper, full keyboard shortcut reference table.
4. **Web Quick Drop Shelf（顶部灵动灵感投放胶囊）**:
   - Top-center dark-glass expandable pill (matching macOS `darkNotch` surface & spring morphing) that auto-expands on window drag-enter or click/hover.
   - Supports dragging files/images/URLs from OS or browser, global `⌘V` clipboard paste (image blob, URL, text snippet, `#HEX` color swatch), inline quick URL/note/swatch capture, browser screen-capture snapshot button, and target switcher (`收件箱` / `指定文件夹` / `当前活跃情绪板`).
5. **External Agent & MCP Server (14 Tools + 2 Resources)**:
   - Implement `ExternalAgentService` exposing JSON-RPC 2.0 over BOTH HTTP (`POST /api/v1/mcp`) and stdio CLI (`web/packages/server/src/mcp-stdio.ts`), covering all 8 read tools (`library_overview`, `search_assets`, `list_inbox`, `get_asset`, `render_contact_sheet`, `list_boards`, `get_board_context`, `export_board_image`), all 6 write tools (`organize_assets`, `create_folder`, `ingest_asset`, `compose_moodboard`, `patch_moodboard`, `trash_assets`), and both resources (`charkle://library/overview`, `charkle://boards`).
   - Enforce `ExternalAgentConfig` dynamically on every call and emit SSE `library.changed` / `board.updated` events on writes so open browser tabs refresh immediately.

## Acceptance Criteria
- All 6 Settings tabs persist configuration cleanly and drive live backend behavior (including lossless storage migration between Local Folder and InMemory/WebDAV/Drive).
- Quick Drop Shelf captures files, URLs (including GitHub/Social), clipboard images, text snippets, and hex swatches directly into Inbox, a chosen Folder, or the Active Moodboard with instant UI reflection.
- `ExternalAgentService` passes Vitest suite verifying JSON-RPC 2.0 `initialize`, `tools/list` (14 tools), `resources/list`/`read`, `render_contact_sheet` image output, policy blocking (`disabled` / `readOnly` / `readWrite`), and SSE refresh emission.
- TypeSafe Jev actions work end-to-end with mocked API and gracefully fall back locally when disabled.
