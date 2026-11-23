# PRD: M5 — Motion Polish, Cross-Platform Sync Parity & Full E2E QA

- **Parent Task**: `11-23-web-version`
- **Dependencies**: `11-23-web-m1-core-db-media-sync` through `11-23-web-m4-ai-typesafe-settings-shelf-mcp`

## Goal
Bring Charkle Web to finished, cohesive product polish: enforce calibrated motion continuity & accessibility fallbacks across every surface, validate 100% lossless macOS ↔ Web `/.charkle/` sync and `.charkleboard` Figma Bridge interoperability, execute real-browser E2E & visual QA across Light and Dark modes, and record Web architecture conventions in `.trellis/spec/`.

## Requirements
1. **Motion & Continuity Audit**:
   - Verify exact role-mapped easing tokens (`--ease-out`, `--ease-out-strong`, `--ease-in`, `--ease-in-out`, `--ease-overshoot` ≤64px only, spring settle) with zero generic `ease-in-out` or bouncy dialogs.
   - Polish Card ↔ Quick Look smooth scale/opacity hero transition, Sidebar active pill sliding continuity, Auto Editorial ↔ Freeform smooth coordinate interpolation, Popover trigger-origin scaling, Auto Editorial drag-reorder ripple (`A * 0.7^n`), and Quick Drop Shelf spring morphing.
   - Verify `prefers-reduced-motion` and `prefers-reduced-transparency` fallbacks work cleanly.
2. **Cross-Platform Interop Verification**:
   - Automated golden-fixture tests verifying a macOS-generated `/.charkle/` directory (Swift `JSONEncoder` Cocoa dates, uppercase UUIDs, keyed enums, Base64 `SyncFields`, boards, folders, assets) imports cleanly into Web `DriveSyncEngine`, edits made on Web export back to valid macOS-decodable ops/boards, and `.charkleboard` ZIP archives pass `Resources/FigmaPlugin/code.js` contract checks.
3. **Real-Browser Visual & Functional E2E QA**:
   - Boot the live full-stack app (`npm run build && npm start` or `npm run dev`) and verify in a real browser across **both Light (`#F6F6F5`) and Dark (`#141517`) modes**:
     - Sample library browsing across Vertical Masonry, Horizontal Justified, and Gallery Filmstrip
     - Search (including Chinese pinyin), color filter, smart folder creation, folder nesting/customization
     - Inbox triage (`1–9` & AI recommendation), `⌘J` Jump Anywhere, Inspector edits, Quick Look across media kinds
     - Moodboard generation (with live Agent Harness steps), Candidate Pool swap, Auto Editorial ↔ Freeform editing (notes, frames, connectors, ink, Undo/Redo), PNG & `.charkleboard` export
     - Quick Drop Shelf capture & 6-tab Settings Center & MCP endpoint
     - Zero console errors, zero uncaught page errors, clean visual hierarchy with restrained Liquid Glass.
4. **Spec & Baseline Integrity**:
   - Update `.trellis/spec/` with Charkle Web conventions and verify native `swift test` remains untouched and passing.

## Acceptance Criteria
- `cd web && npm run typecheck && npm test && npm run build` all pass with 0 errors/warnings.
- Live browser E2E walkthrough passes in both Light & Dark modes with zero console errors and visually verified layout/material fidelity.
- Existing native `swift test` passes unchanged.
- `.trellis/spec/` documents the Web package structure, `SwiftWireCodec` contract, and UI design tokens.
