# Charkle Motion, Visual Material & Icon Specification

This spec defines Charkle's motion curves, continuous concentric radii, restrained glass materials, and bundled SVG iconography for SwiftUI + AppKit (and cross-platform Web / Windows parity).

---

## 1. Motion Tokens (`CharkleMotion`)

Never leave animations on default `.easeInOut` or `.linear` for spatial motion. Every transition uses one of these exact role-mapped curves:

| Role | Token | SwiftUI `Animation` | Duration | Use Cases |
| :--- | :--- | :--- | :--- | :--- |
| **Enter** | `--ease-out` `(0.23, 1, 0.32, 1)` | `.timingCurve(0.23, 1, 0.32, 1, duration:)` | Small: `0.18s`, Medium: `0.24s`, Large: `0.28s` | Toasts, menus, popovers, inspector panels, dialogs appearing |
| **Responsive Settle** | `--ease-out-strong` `(0.22, 1, 0.36, 1)` | `.timingCurve(0.22, 1, 0.36, 1, duration:)` | `0.22s` | Active tab pill, icon toggle, selected filter chip, stepped inner content reveal |
| **Exit** | `--ease-out` `(0.23, 1, 0.32, 1)` | `.timingCurve(0.23, 1, 0.32, 1, duration:)` | `0.13s`–`0.17s` (always shorter than enter!) | Dismissing toast/popover/panel/menu with immediate response |
| **On-Screen Move** | `--ease-in-out` `(0.77, 0, 0.175, 1)` | `.timingCurve(0.77, 0, 0.175, 1, duration:)` | `0.24s` | Moving/resizing elements already on screen (segmented indicator, sidebar divider, reflow) |
| **Drawer / Side Panel** | `--ease-drawer` `(0.32, 0.72, 0, 1)` | `.timingCurve(0.32, 0.72, 0, 1, duration: 0.30)` | `0.30s` | Sidebar, Inspector, Quick Look drawer, Candidate Pool slide |
| **Micro Confirmation** | `--ease-overshoot` `(0.34, 1.56, 0.64, 1)` | `.timingCurve(0.34, 1.56, 0.64, 1, duration: 0.26)` | `0.26s` | Tiny ≤64px confirmations ONLY: checkbox tick, rating star, badge count pop. NEVER on dialogs/sheets! |
| **Gesture / Drag Release / Notch** | `--ease-spring` | `.spring(duration: 0.36, bounce: 0.10)` (momentum) / `.spring(duration: 0.28, bounce: 0.0)` (critically damped UI) | Natural settle | Drag-to-reorder drop, Notch Shelf morphing, Quick Look zoom-to-card, Moodboard reflow |
| **Hover & Press** | Micro tactile | `.timingCurve(0.23, 1, 0.32, 1, duration: 0.12)` | `0.12s` | Press `scaleEffect(0.97)` on pointer-down, subtle hover brightness. NEVER animate layout on hover! |

### Non-Negotiable Motion Rules
1. **UI Continuity**:
   - Card → Quick Look (`Space`): continuous expansion from card geometry (`matchedGeometryEffect` / source-rect hero zoom), background dims softly, secondary controls fade in after 45% progress; closing shrinks directly back into the exact card frame.
   - Sidebar & Segmented Indicators: single travelling pill indicator (`matchedGeometryEffect`), never hard-cutting highlights.
   - Moodboard Auto Editorial ↔ Freeform switch: nodes animate continuously from exact editorial rects into freeform coordinates (zero jump).
   - MacBook Notch Shelf: fixed oversized transparent `NSPanel` anchored flush to `screen.frame.maxY`; expand/collapse animates inner shape morphing + scale/corner-radius from top-center anchor (`UnitPoint.top`), interruptible mid-flight, never mutating `NSWindow.frame` abruptly.
2. **Popover Origin**:
   - Every custom menu, color popover, tag picker, and quick-action bar MUST apply `.scaleEffect(..., anchor:)` aligned to its trigger edge (top-leading/top-center when below trigger, bottom when above), growing from `0.96 → 1.0` with opacity `0 → 1` (`0.16s` enter, `0.11s` exit).
3. **Drag-to-Reorder Ripple**:
   - In Moodboard Auto Editorial reorder and Sidebar folder/board reordering: lifted item tracks pointer 1:1 (`0.94` scale), thin 15%-ink insertion line grows from center, neighboring items lean away by `A * pow(0.7, n)` (`A = 8pt` cards / `6pt` rows) with `24ms * n` stagger on quick spring settle.
4. **Reduced Motion & Transparency**:
   - Always check `@Environment(\.accessibilityReduceMotion)` → collapse spatial movement/springs into a clean `0.15s` opacity cross-fade.
   - Always check `@Environment(\.accessibilityReduceTransparency)` → replace Liquid Glass with solid high-contrast surface tokens.

---

## 2. Continuous Concentric Corners

- Always use `RoundedRectangle(cornerRadius: ..., style: .continuous)` (macOS continuous superellipse curvature).
- **Concentric formula**: `innerRadius = max(4, outerRadius - padding)`.
  - Floating Glass Dock / Modal Shell: `R = 20`, padding `8` → inner button/tile `r = 12`.
  - Asset Card: `R = 12`, inner overlay badge padding `6` → inner badge `r = 6` (or capsule).
  - Settings Section Card: `R = 14`, padding `6` → inner control `r = 8`.
  - Keep all spacing, gaps, and radii on a `4pt` grid (`4, 8, 12, 16, 20, 24`).

---

## 3. Restrained Apple Liquid Glass Policy (macOS 26+ Native + macOS 15 Fallback)

- **Glass Surfaces ONLY** (floating over media/canvas; use `#available(macOS 26, *)` `.glassEffect(.regular, in: ...)` & `GlassEffectContainer`, with calibrated macOS 15 `.ultraThinMaterial` + crisp rim highlight fallback):
  1. Top Floating Search & Visual Filter Capsule (over scrolling gallery with `.scrollEdgeEffectStyle(.soft, for: .top)`).
  2. Moodboard Floating Bottom Tool Dock (single `GlassEffectContainer` grouping tools, insert actions, and Export).
  3. Multi-Select Floating Batch Action Pill.
  4. Quick Look Floating HUD Controls.
  5. Notch Shelf dark glass expansion capsule.
- **Keep Solid / Neutral** (zero glass-on-glass, zero color pollution):
  - Main Gallery Background & Moodboard Canvas Ground (neutral low-chroma light `#F6F6F5` / dark `#141517`).
  - Asset Cards themselves (clean artwork, no text clutter underneath by default).
  - Never use generic purple/violet AI gradients anywhere in chrome.

---

## 4. Iconography

- **UI Functional Icons (16–24pt, Duotone Solid on 16-grid)**: bundled at `Sources/CharkleApp/Resources/Icons/duotone-<name>.svg` with dynamic Light/Dark/Active palette adaptation and SF Symbol fallback via `CharkleIcon`.
- **Featured Brand & Empty-State Icons (32–96pt, Layered Style)** + **AppIcon.icns**: bundled at `Sources/CharkleApp/Resources/Icons/layered-<name>.svg` and `Resources/AppIcon.icns`.
- Canonical icon names:
  - Navigation: `library`, `inbox`, `moodboard`, `folder`, `untagged`, `recent`, `trash`, `tag`
  - Moodboard & Canvas: `sparkle-board`, `auto-layout`, `freeform`, `note`, `group-frame`, `connector`, `ink-pen`, `palette`, `export`, `swap`, `pin-offline`
  - Capture & Sync: `notch`, `screenshot`, `drive-sync`, `filter`, `search`, `settings`, `quicklook`
