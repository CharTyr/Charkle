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

## Charkle Monorepo & Native Desktop Engineering Guardrails

### 1. Three-Platform Control & Division of Labor
- **Canonical Authority**: Root `DESIGN.md` (visual/motion/interaction language), `.trellis/spec/cross-platform/index.md` (sync wire contract, `.charkleboard`, MCP safety, interaction parity), `.trellis/spec/macos/native-design-system.md` (macOS native shell), and `.trellis/spec/windows/fluent2-design-system.md` + `windows/AGENTS.md` (Windows Fluent 2 / WinUI 3 native shell, Win32/OLE guardrails, local visual engine invariants) govern native desktop work alongside Web (`./web/`).
- **Workspace Scope**: Keep platform edits strictly scoped to the active platform (`Sources/`, `Tests/`, `scripts/` for macOS; `windows/` for Windows; `web/` for Web). For cross-platform follow-ups outside the active session's target platform, issue or update structured tasks under `.trellis/tasks/` instead of editing other platform folders directly unless explicitly instructed.

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
- **Zero-Flicker Drawer Transitions (`SidebarView`, `InspectorView`, `CharkleCanvas`)**:
  - Never let SwiftUI animations drive per-frame width reflows on virtualized galleries or Metal ring views. Keep fixed internal widths (`76pt` / `232pt` Sidebar, `300pt` Inspector) inside animated outer clip slots using unified `CharkleMotion.drawerEase`, pass single-shot `paneTransitionTargetWidth` into `MasonryLayoutEngine` with layer-backed `MasonryClipView` (`origin.x = 0` clamp + `CATransaction`-guarded height updates), and commit `RingGalleryMTKView` resizes atomically via `presentsWithTransaction`.
- **Full-Bleed Overlay Safe-Area & Traffic-Light Alignment**:
  - Because `CharkleWindowChromeBridge` uses `.fullSizeContentView` and `mainWorkspaceBody` ignores top safe area, every full-window overlay (`QuickLookOverlayView`, `SettingsOverlayView`, `JumpAnywhereView`, `OnboardingView`) must apply `.ignoresSafeArea(.all)` / `.ignoresSafeArea(.container, edges: .top)` on its **outermost** container and clipped panes (not solely an inner backdrop behind `.clipped()`), preventing the main top bar or a duplicate Inspector header from bleeding through. Overlay top headers extending into the titlebar zone must reserve `~88pt` leading clearance for macOS traffic lights and host `CharkleWindowDragArea()`.
- **macOS `Menu(.borderlessButton)` Sizing, SF Symbol Validity & Adaptive Breadcrumbs**:
  - Every icon-only or compact `Menu` using `.menuStyle(.borderlessButton)` inside an `HStack` or Liquid Glass capsule must include `.menuIndicator(.hidden)` and `.fixedSize()` (otherwise macOS SwiftUI expands it to `.infinity` and distorts the bar). Always verify SF Symbol names exist on macOS (`NSImage(systemSymbolName:accessibilityDescription:) != nil`) because nonexistent names compile with zero warnings yet render blank.
  - Never constrain leading top-bar context/breadcrumbs behind narrow hardcoded `maxWidth` caps or subordinate them below greedy search/passive-label widths; render multi-level folder breadcrumbs with tiered `ViewThatFits(in: .horizontal)` (full path -> readable bounded parent + current -> collapsed clickable `…` ancestor menu + current) so ancestor names never crush into clipped half-glyphs.
