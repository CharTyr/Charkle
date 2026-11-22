# Backend Development Guidelines (`CharkleCore` & `CharkleCLI`)

> Executable contracts and coding conventions for Charkle's nonisolated Swift 6.2 core library, SQLite database, media pipeline, sync engine, AI/Vision intelligence, and CLI/MCP helper.

---

## Architecture Summary

- **Targets**: `Sources/CharkleCore/` (library, `nonisolated`, links `sqlite3`) and `Sources/CharkleCLI/` (CLI + stdio MCP server executable `charkle-cli`, bundled at `Contents/Helpers/charkle`).
- **Toolchain**: Swift 6.2 (`swift-tools-version: 6.2`), macOS 15+, `NonisolatedNonsendingByDefault`, `InferIsolatedConformances`.
- **Zero UI Coupling**: `CharkleCore` must never import `SwiftUI`. Only AppKit/CoreGraphics/ImageIO/AVFoundation/SceneKit/QuickLookThumbnailing/Vision headless APIs are permitted inside `Media/` and `Intelligence/`.

---

## Guidelines Index

| Guide | Description | Status |
|-------|-------------|--------|
| [Directory Structure](./directory-structure.md) | Target layout, module seams, protocol-first boundaries | Active |
| [Database Guidelines](./database-guidelines.md) | SQLite WAL/FTS5, JSON payload storage, recursive folder queries, backward-compatible `Codable` | Active |
| [Error Handling](./error-handling.md) | Typed errors, cancellation, partial-ingest rollback, cycle & deletion guards | Active |
| [Logging Guidelines](./logging-guidelines.md) | `os.Logger` categories, `.private` redaction, credential & PII zero-leak policy | Active |
| [Quality Guidelines](./quality-guidelines.md) | Swift 6 concurrency gates, Vision throttling, rich media contracts, verification & Release signing | Active |

---

## Pre-Development Checklist

Before editing `Sources/CharkleCore/` or `Sources/CharkleCLI/`:

- [ ] Read `Sources/CharkleCore/Contracts/CoreModels.swift` and `CoreServiceProtocols.swift` before changing cross-layer models or engine methods.
- [ ] Verify whether new `Codable` fields need backward-compatible `init(from:)` defaults for existing user SQLite payloads.
- [ ] Keep `PlaceholderEngine.swift` in sync whenever `CharkleEngineProtocol` or `FilterCriteria` changes.
- [ ] Route all Apple Vision requests through `IntelligenceEngine.analyze(...)` (`VisionConcurrencyGate`), never directly onto an unbounded concurrent queue.
- [ ] Never log or commit `Resources/GoogleOAuthClient.json`, API keys, OAuth tokens, Keychain payloads, or signing certificate identities.

---

## Quality Check (Run Before Finish)

```bash
swift build --build-tests -Xswiftc -warnings-as-errors
swift test --skip-build
node scripts/test-figma-plugin.cjs
```
