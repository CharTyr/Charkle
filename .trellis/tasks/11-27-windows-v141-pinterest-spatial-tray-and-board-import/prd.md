# Windows Parity Handoff (v1.4.1): Pinterest Infinite Space, Collection Tray & Board Import

## Scope
Mirror the macOS & iOS `v1.4.1` Pinterest integration inside `windows/` without modifying macOS or iOS files.

## Core Feature Parity Requirements
1. **Persistent Account Login (WebView2)**
   - Provide a visible Pinterest login window using a persistent WebView2 profile so Email, Google, Apple, 2FA, and human verification work directly.
   - Support true child popup windows (`NewWindowRequested`) so OAuth popups keep `window.opener.postMessage()` and close cleanly after auth.
   - Read `csrftoken` cookie for `X-CSRFToken` on same-origin `fetch()` calls to `UserSettingsResource`, `UserHomefeedResource`, `BaseSearchResource`, `BoardsResource`, `BoardFeedResource`, `PinResource`, `RelatedModulesResource`, and `RelatedPinFeedResource`.

2. **Omnidirectional 2D Infinite Spatial Canvas**
   - Match `PinterestSpatialLayout` (non-overlapping concentric-ring bidirectional columns, 0pt layout shift on append) and `InfiniteSpatialCamera` (anchor-locked continuous zoom `0.24x..3.20x`).
   - Add velocity-projected directional lookahead thumbnail prefetching (`predictivePrefetchCards`) and proactive edge ring expansion before reaching the outer boundary.
   - Icon-only bottom-left Browse / Fast-Pick toggle; browse mode hides `+` on cards (showing `✓` only for collected items), while fast-pick mode reveals `+` for rapid batch collection.
   - Ensure sidebar collapse/expand remains accessible in Pinterest mode, and floating controls never leak clicks to underlying cards.

3. **Shopping-Cart Collection Tray ("托盘")**
   - Persist tray items across sessions.
   - Render expanded tray as an aspect-preserving horizontal waterfall strip (zero forced square cropping).
   - Support checkbox subset selection, selective removal, clear all, folder + tag batch import (original high-res download with Pin ID deduplication), and clicking any tray card to open its floating Pin detail overlay.

4. **Aspect-Adaptive Floating Pin Detail Overlay + Similar Pins**
   - Side-by-side adaptive hero layout keeping portrait/landscape artwork compact with zero pillarbox dead space so Pinterest's similar pins waterfall is immediately visible below on screen 1.
   - Support clicking hero artwork for full-resolution lightbox preview, back-stack navigation across similar pins, 1-click tray toggle, direct import, and "Explore Similar in Infinite Space".

5. **Batch Import Saved Collections by Board**
   - Paginate all user boards and all pins inside selected boards (`filter_section_pins: false`).
   - Create or reuse per-board folders under `"Pinterest"` root (default), library root, or a user-selected existing folder, skipping already-imported Pin IDs for repeatable incremental sync.

## Release Coordination
- Target shared release tag: `v1.4.1` (macOS DMG and iOS unsigned IPA already attached).
- When publishing Windows x64 installer for `v1.4.1`, preserve the macOS and iOS release note sections verbatim and replace only the Windows placeholder block.
