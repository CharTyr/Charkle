<!-- TRELLIS:START -->
# Trellis Instructions

These instructions are for AI assistants working in this project.

This project is managed by Trellis. The working knowledge you need lives under `.trellis/`:

- `.trellis/workflow.md` — development phases, when to create tasks, skill routing
- `.trellis/spec/` — package- and layer-scoped coding guidelines (read before writing code in a given layer)
- `.trellis/workspace/` — per-developer journals and session traces
- `.trellis/tasks/` — active and archived tasks (PRDs, research, jsonl context)

If a Trellis command is available on your platform (e.g. `/trellis:finish-work`, `/trellis:continue`), prefer it over manual steps. Not every platform exposes every command.

If you're using Codex or another agent-capable tool, additional project-scoped helpers may live in:
- `.agents/skills/` — reusable Trellis skills
- `.codex/agents/` — optional custom subagents

Managed by Trellis. Edits outside this block are preserved; edits inside may be overwritten by a future `trellis update`.

<!-- TRELLIS:END -->

## Charkle Monorepo & macOS Engineering Guardrails

### 1. Three-Platform Control & Division of Labor
- **Canonical Authority**: Root `DESIGN.md` (visual/motion/interaction language) and `.trellis/spec/cross-platform/index.md` (sync wire contract, `.charkleboard`, MCP safety, interaction parity) govern all three editions: macOS (`Sources/`), Web (`./web/`), and Windows (`./windows/`).
- **Workspace Scope**: In macOS-focused sessions, implement code directly under `Sources/`, `Tests/`, and `scripts/`. For Web or Windows follow-ups, issue or update structured tasks under `.trellis/tasks/` instead of editing `./web/` or `./windows/` directly unless explicitly instructed for that platform.

### 2. Repository Purity, Privacy & Git Push Discipline
- **Zero External Inspiration / Author Mentions**: Never introduce names of external reference/competitor products, design-tip authors, or unrelated third-party tooling in tracked source, comments, tests, specs, docs, or Trellis tasks. Only cite actual runtime integrations; credit `gdirect` solely in root `README.md` **Acknowledgements**.
- **Zero Secrets / Local Paths / Scratch Files**: Never commit or echo personal absolute paths (`/Users/<name>/...`), `Resources/GoogleOAuthClient.json`, `.env*`, API tokens, code-signing certificate identities/CN/emails, or untracked root SVG assets (`Charkle*.svg`).
- **Explicit Push Only**: Always push explicit refs (`git push origin main` or a specific tag). Never run `git push --all` or `git push --mirror`.

### 3. macOS Native UI & Event Invariants (SwiftUI + AppKit)
- **Keyboard & Spacebar Quick Look**:
  - Never test unmodified shortcuts with `modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty` — that breaks whenever Caps Lock (including macOS Chinese/English switch) is active or arrow keys set `[.numericPad, .function]`. Always mask against `[.command, .option, .control, .shift]`.
  - Handle window-wide shortcuts like Spacebar Quick Look via a root `NSEvent` local monitor (`WindowKeyEventBridge`) so `firstResponder` drift across Sidebar/Toolbar/Inspector never breaks previews; always respect active sheets/alerts and `NSText`/`NSTextView`/`NSTextField` editing.
  - Resign underlying text focus when opening Quick Look, and suspend underlying canvas monitors (`isOverlayPresented`) while Quick Look or modal overlays are presented.
- **Quick Look & Inspector Continuity**:
  - Reuse the full-height `300pt` `InspectorView` inside Quick Look rather than building a shrunk or read-only drawer, and keep visibility (`coordinator.isInspectorVisible`) plus active tab (`coordinator.selectedInspectorTab`) synchronized 1:1 with the main workspace.
- **Full-Row Expandable Hit Targets**:
  - Never use bare SwiftUI `DisclosureGroup` on macOS (it only accepts clicks on its tiny leading chevron). Always use `CharkleDisclosureGroup` (or full-width `.buttonStyle(.plain)` headers with `.contentShape(Rectangle())` and hover feedback) for collapsible sections.
- **Photos-Style Gallery Zoom (`VirtualizedMasonryView`)**:
  - Lock consecutive zoom steps onto one persistent exact asset anchor (`sessionZoomAnchor`: cursor card > visible selected card > viewport center) until the user manually scrolls or changes selection.
  - Apply anchor-locked `newScrollY` *before* syncing tiles (keeping Row-1 flush beneath `topInset` at top, while Row-2+ cards scroll automatically even from `scrollY == 0`) and project pre-handoff rects via `ΔscrollY` + optical rebase compensation for 0pt frame-0 jump.
  - Keep the exact anchor card gliding continuously on raised `zPosition`; softly crossfade far-wrapping non-anchor cards instead of flying them across the viewport.
