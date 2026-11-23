# Implementation Plan: M5 — Motion Polish, Cross-Platform Parity & E2E QA

1. [ ] Audit & refine calibrated motion tokens, Quick Look continuity, Sidebar travelling pill, Auto Editorial ↔ Freeform interpolation, Popover trigger-origin scaling, and `prefers-reduced-motion`/`prefers-reduced-transparency` fallbacks.
2. [ ] Add & run `macos-interop.test.ts` validating `/.charkle/` bidirectional Swift-codec sync and `.charkleboard` Figma Plugin contract compatibility.
3. [ ] Launch full-stack Web app and run real-browser E2E & visual QA across Light & Dark modes; resolve any UI/UX/console issues.
4. [ ] Run full validation suite (`web` typecheck + test + build, and native `swift test`).
5. [ ] Update `.trellis/spec/` guidelines with Charkle Web patterns and summarize final delivery.

## Validation Commands
```bash
cd web && npm run typecheck && npm test && npm run build
cd . && swift test
```
