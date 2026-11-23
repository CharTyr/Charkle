# Implementation Plan: M4 — Hybrid AI, TypeSafe Jev, Settings, Quick Drop Shelf & MCP

1. [ ] Implement server `cloud-ai-provider.ts`, `cloud-ai-usage-tracker.ts`, `typesafe-client.ts`, `visual-grounding-engine.ts`, and `contact-sheet-renderer.ts` + wire `/api/v1/ai/*` and `/api/v1/typesafe/*` routes.
2. [ ] Implement server `agent/external-agent-service.ts` (all 14 tools + 2 resources + policy checks + SSE notify) + `POST /api/v1/mcp` + `src/mcp-stdio.ts` entrypoint.
3. [ ] Implement client `features/shelf/QuickDropShelf.tsx` (top-center dark-glass morphing capsule, global drag-drop, global `⌘V` paste, URL/snippet/swatch capture, screen-capture snapshot, target switcher).
4. [ ] Implement client `features/settings/SettingsModal.tsx` with all 6 tabs (`CloudSyncTab` + `StorageMigrationModal`, `IntelligenceTab` + Usage & TypeSafe Jev, `AppearanceTab`, `ExternalAgentTab`, `StorageCacheTab`, `CaptureShortcutsTab`).
5. [ ] Connect Inspector, TopFilterCapsule (Semantic Search), Inbox (Batch Smart Triage), and MoodboardCanvas (Pinpoint Annotate / Focus Crop / Clean Crop) to live AI & TypeSafe endpoints.
6. [ ] Write Vitest suites covering Cloud AI adapters (mocked fetch), TypeSafe Jev + local fallback, Contact Sheet rendering, External Agent MCP 14-tool protocol & policy enforcement, and Storage Migration.

## Validation Commands
```bash
cd web && npm run typecheck && npm test && npm run build
```
