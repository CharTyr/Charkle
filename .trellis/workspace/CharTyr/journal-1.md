# Journal - CharTyr (Part 1)

> AI development session journal
> Started: 2026-11-22

---



## Session 1: Major UX Upgrade, Stability Fixes & Trellis Spec Bootstrap
<!-- trellis-session: v=2 fp=c46415f872d94087 -->

**Date**: 2026-11-23
**Task**: Major UX Upgrade, Stability Fixes & Trellis Spec Bootstrap
**Branch**: `main`

### Summary

Shipped full gallery/notch/folder/rich-media/moodboard upgrade, fixed Swift 6 multi-item drag crash & Vision concurrency deadlock, and populated .trellis/spec/ from the live codebase.

### Main Changes

- Gallery 3 views (Vertical, Justified, Filmstrip), gesture zoom GPU animation, bundled duotone in-app icons (36 SVGs), collapsible sidebar, smart folders, folder customization & recursive parent-folder display.
- Structured Social Post (X/Threads/Bluesky) & GitHub Repo rich viewers in QuickLook + Gallery with standalone photo & video extraction; Moodboard candidate drag & smart frame resize.
- Fixed multi-item drag SIGTRAP (nonisolated isFlipped), bounded VisionConcurrencyGate(limit: 3), cached Notch drag pasteboard & recent activity, and clipped Notch morphing animation.
- Bootstrapped .trellis/spec/{backend,frontend,guides} with executable contracts and archived 00-bootstrap-guidelines.

### Git Commits

| Hash | Message |
|------|---------|
| `ac8f723` | feat: major UX upgrade across gallery, notch shelf, folders, rich media, moodboards, and drag stability |
| `bb32a9e` | docs(trellis): bootstrap backend, frontend, and cross-layer specs from Charkle codebase |

### Testing

- [OK] swift build --build-tests -Xswiftc -warnings-as-errors (0 warnings)
- [OK] swift test --skip-build (75/75 tests in 17 suites passed)
- [OK] node scripts/test-figma-plugin.cjs & ./scripts/build-app.sh release + codesign -v --deep dist/Charkle.app (SIGN_OK)

### Status

[OK] **Completed**


## Session 2: Charkle v1.0.1 Release, Multi-Platform Monorepo Merge & Purity Cleanup
<!-- trellis-session: v=2 fp=dc8499a7925e6dba -->

**Date**: 2026-11-23
**Task**: Charkle v1.0.1 Release, Multi-Platform Monorepo Merge & Purity Cleanup
**Package**: macos
**Branch**: `main`

### Summary

Shipped macOS Charkle v1.0.1 (original long-strip Quick Look, full EXIF + AI prompt extraction, reorderable zero-flicker Inspector, signed arm64 DMG & GitHub Release), unified Charkle-Web into ./web/ via git subtree, reserved ./windows/, removed external inspiration/author mentions while crediting gdirect in README, and refreshed Trellis monorepo specs & task archives.

### Main Changes

- macOS v1.0.1: fixed macOS 15.1 launch crash, added 9-pane Settings & Onboarding, independent MCP/CLI switches, full camera EXIF + AI prompt parser (ImageMetadataExtractor), original full-res & long-strip Quick Look, persisted drag-reorderable Inspector cards with Frame-0 sync cache & loadedAssetID anti-flicker, and signed arm64 DMG packaging (scripts/build-dmg.sh) published as GitHub Release v1.0.1.
- Unified Monorepo: merged Charkle-Web (11 commits, Node/Docker + Cloudflare Workers DO SQLite & R2) into ./web/ via git subtree, reserved ./windows/ for Tauri v2 + Rust Core, unified root README.md (with gdirect acknowledgement) and .gitignore.
- Repo Purity & Trellis Refresh: removed vendored design/icons/ tool, eliminated all external reference/author mentions and local paths across all tracked files, configured Monorepo packages in .trellis/config.yaml, added .trellis/spec/web/ and .trellis/spec/cross-platform/, updated macOS specs with v1.0.1 contracts, and archived completed 11-23-web-* planning tasks.

### Git Commits

| Hash | Message |
|------|---------|
| `4527bb6` | fix(app): resolve macOS 15.1 launch crash and keep hotkey Notch Shelf pinned |
| `8e388f4` | feat(settings,onboarding): redesign 9-pane Settings overlay and add skippable Onboarding Studio |
| `7a730c9` | feat(agent): support independent MCP and CLI service toggles with v1.0.0 migration |
| `b7f046d` | feat(core): add folder tree, GitHub OG/README parser, X avatars, and EXIF/AI prompt extraction |
| `283bbfe` | feat(ui): hierarchical folder menus, reorderable Inspector cards, original long-strip QuickLook & animation polish |
| `ce09814` | chore(release): bump version to 1.0.1 (build 2) and add DMG packaging script |
| `729c15e` | feat(web): merge Charkle-Web into ./web/ monorepo workspace |
| `08e26ed` | chore(monorepo): unify README, gitignore, Windows workspace placeholder, and sanitize Web paths |
| `5d8b768` | docs(trellis): add Windows client (Tauri v2 + Rust Core) parent and M1-M5 planning tasks |
| `4777a8e` | chore: remove external inspiration/author references, drop vendored icon tool, and credit gdirect in README |
| `1f3e135` | chore(trellis): clean external reference mentions from Windows planning tasks |

### Testing

- [OK] macOS: swift test passed 81/81 tests in 18 suites; swift build --build-tests -Xswiftc -warnings-as-errors passed with 0 warnings; DMG verified with codesign -v --deep --strict.
- [OK] Web & Extension: npm run typecheck clean across 4 workspaces; 94/94 tests passed (shared 23, server 50, worker 11, extension 10).
- [OK] Full Python audit across all tracked files confirmed 0 external inspiration/author mentions and 0 personal path leaks.

### Status

[OK] **Completed**

### Next Steps

- Begin Windows client M1 (11-23-windows-m1-core-db-media-sync) on Windows x64 machine following .trellis/spec/cross-platform/index.md.
- Keep macOS and Web feature/wire parity aligned via .trellis/spec/cross-platform/index.md.
