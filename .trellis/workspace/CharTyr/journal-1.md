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

- Gallery 3 views (Vertical, Justified, Filmstrip), gesture zoom GPU animation, Kubai Duotone in-app icons (36 SVGs), collapsible sidebar, smart folders, folder customization & recursive parent-folder display.
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
