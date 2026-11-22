# Backend Logging & Privacy Guidelines

> Structured `os.Logger` usage and strict secret/PII redaction rules across `CharkleCore`, `CharkleApp`, and `CharkleCLI`.

---

## Logger Convention

Use Apple's unified `os.Logger` with a file-scoped `private let` logger per subsystem and category:

```swift
import os

private let visionLogger = Logger(subsystem: "com.charkle.core", category: "Vision")
private let libraryStoreLogger = Logger(subsystem: "com.charkle.app", category: "LibraryStore")
private let notchLogger = Logger(subsystem: "com.charkle.app", category: "NotchShelf")
```

| Subsystem | Module |
|-----------|--------|
| `com.charkle.core` | `Sources/CharkleCore` |
| `com.charkle.canvas` | `Sources/CharkleCanvas` |
| `com.charkle.app` | `Sources/CharkleApp` |
| `com.charkle.cli` | `Sources/CharkleCLI` |

---

## Log Level Rules

- `.debug`: Expected fallbacks, Vision split-pass retries, cache misses, high-frequency diagnostics.
- `.info`: Significant lifecycle transitions (sync completed, migration completed, MCP server initialized).
- `.warning` / `.error`: Recoverable operational errors (network fetch failures, corrupt media fallback, failed store refresh).
- **Never** use `print()` inside `CharkleCore`, `CharkleCanvas`, or `CharkleApp` (note: `CharkleCLI` reserves `stdout` strictly for JSON-RPC / structured CLI output; diagnostic messages in `CharkleCLI` must go to `stderr`).

---

## Privacy & Secret Redaction (STRICT — ZERO EXCEPTIONS)

1. Mark user-derived strings, file paths, and error descriptions with `privacy: .private` whenever they could contain filenames, URLs, or personal metadata:
   ```swift
   visionLogger.debug("Combined Vision analysis fell back: \(error.localizedDescription, privacy: .private)")
   ```
2. **NEVER** log, print, embed in test fixtures, or commit:
   - `Resources/GoogleOAuthClient.json` (gitignored, bundled only at local build time by `scripts/build-app.sh`)
   - Keychain values (`KeychainStore.read`), OAuth access/refresh tokens, ID tokens, PKCE verifiers
   - User API keys (Gemini, OpenAI, Anthropic, TypeSafe Jev, WebDAV passwords)
   - Code-signing certificate Common Names (CN) or developer emails (when verifying signatures, run `codesign -v --deep dist/Charkle.app`, never `codesign -dvvv` into shared logs)
3. **Keychain Isolation in Tests**: Tests that instantiate `IntelligenceEngine` or `LiveCharkleEngine` MUST inject an isolated `KeychainStore` (via `BackendFixture.makeEngine(...)`) so tests never read or mutate the developer's live macOS login Keychain.
