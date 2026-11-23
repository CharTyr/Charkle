# Design: M5 — Motion Polish, Cross-Platform Parity & E2E QA

## Verification Matrix
1. **Motion & A11y Pass**: Audit `tokens.css` and every interactive component against `docs/MOTION_AND_ICON_SPEC.md` (004 concentric corners, 005 drag ripple, 010 restrained Liquid Glass, 011 easing curves, 015 UI continuity, Popover Origin, `prefers-reduced-motion`, `prefers-reduced-transparency`).
2. **Swift ↔ Web Golden Interop Test**: Add dedicated Vitest suite (`packages/server/tests/macos-interop.test.ts`) exercising actual Swift-formatted JSONL ops, `manifest.json`, `boards/*.json`, and verifying `.charkleboard` ZIP output against the exact object fields read by `Resources/FigmaPlugin/code.js`.
3. **Browser E2E & Visual Inspection**: Start live `./web` server, inspect rendered UI and interactive flows in real browser across Light & Dark themes, fix any layout/overflow/contrast/interaction defects immediately.
4. **Documentation Sync**: Record Web architecture & conventions in `.trellis/spec/frontend/` and `.trellis/spec/backend/`.
