# Charkle

Native macOS 15+ visual reference library & rapid moodboard studio backed by human-readable Google Drive + [`gdirect`](https://github.com/mizorewww/gdirect).

## Architecture
- `Sources/CharkleCore` (`nonisolated`): SQLite (WAL + FTS5 + vectors), All-Media Pipeline + 2-tier LRU cache, Dual-Channel Google Drive + `gdirect` Sharded Incremental Sync, Hybrid AI & Moodboard Curator.
- `Sources/CharkleCanvas` (`@MainActor`): High-FPS Virtualized Masonry Grid & Dual-Mode Moodboard Infinite Canvas (Auto Editorial ↔ Freeform, notes, frames, palette strip, arrow connectors, freehand ink annotations, high-DPI export).
- `Sources/CharkleApp` (`@MainActor`): Gallery-First macOS UI with restrained Apple Liquid Glass floating controls, Inbox Triage Station, Full-Media Quick Look, Notch Shelf, Kubai motion tokens & Kubai icons.
- `Tests/CharkleTests`: Swift Testing suites across deep-module interfaces.

See `docs/BLUEPRINT.md` and `docs/MOTION_AND_ICON_SPEC.md`.
