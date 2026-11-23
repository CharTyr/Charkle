# Design: M4 — Hybrid AI, TypeSafe Jev, Settings, Quick Drop Shelf & MCP

## Server Subsystems
- `intelligence/cloud-ai-provider.ts`: Unified adapter for Gemini REST API, OpenAI Chat Completions, OpenAI Responses, Anthropic Messages, and ChatGPT subscription token endpoint; returns structured `{ description, suggestedTags, embedding }` and records usage via `CloudAIUsageTracker`.
- `intelligence/typesafe-client.ts` & `visual-grounding-engine.ts`: Implements TypeSafe System One (Jev) API client (Box/Noul/Choice/Score endpoints) with confidence padding (`minConfidence`, `lowConfidencePadding`, `minPresenceProbability`) + local `sharp` edge-salience & center-crop fallback.
- `intelligence/contact-sheet-renderer.ts`: Renders numbered up-to-16 thumbnail grid PNG via `sharp` + SVG index labels for both the Moodboard Agent Harness and MCP `render_contact_sheet`.
- `agent/external-agent-service.ts` & `mcp-stdio.ts`: Shared JSON-RPC 2.0 dispatcher wired into both Hono `POST /api/v1/mcp` and `stdin/stdout` newline-delimited JSON-RPC for Claude Desktop / Cursor / Antigravity MCP clients.

## Client Subsystems
- `features/shelf/QuickDropShelf.tsx`: Fixed top-center container (`z-index` below Quick Look, above gallery chrome) listening to `window` `dragenter`/`dragover`/`drop` and `paste` (ignoring active `<input>`/`<textarea>`/`contentEditable`); uses `darkNotch` glass tokens (`#0B0C0F/88%`, dual soft shadow, hairline highlight) and spring expand/collapse.
- `features/settings/SettingsModal.tsx`: Left navigation rail (6 tabs with `CharkleIcon`) + scrollable detail pane + `StorageMigrationModal` + live `SyncStatus` indicator.
