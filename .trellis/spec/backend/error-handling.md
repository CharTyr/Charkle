# Backend Error Handling

> Error taxonomy, cancellation discipline, rollback invariants, and sync/folder guardrails in `CharkleCore`.

---

## Error Types

| Type | Location | When to Use |
|------|----------|-------------|
| `LibraryDatabaseError` | `Sources/CharkleCore/Database/LibraryDatabase.swift` | SQLite failures, validation rejections (e.g., folder move cycle, missing API key, empty pixel image) |
| `DriveTransportError` | `Sources/CharkleCore/Contracts/SyncModels.swift` | Missing records (`fileNotFound`), auth/config missing (`notConfigured`), transport HTTP/WebDAV/mount failures |

All user-facing error descriptions should be clear Chinese messages (matching Charkle's UI language) with actionable guidance and **zero** raw secrets, tokens, or stack traces.

---

## Transaction & File Rollback Invariants

1. **Ingest Cleanup (`LiveCharkleEngine.ingest`)**:
   - Files staged on disk by `media.ingest(...)` MUST be removed via `media.removeFiles(for: item.asset)` in the `catch` block if parallel preparation OR the committing `database.transaction` fails.
   - Temporary staging subdirectories (e.g., `social-<uuid>`, `social-refresh-<uuid>`, `charkle-social-extract-<uuid>`) MUST use `defer { try? FileManager.default.removeItem(at: stagingDir) }`.
2. **Atomic File Writes**:
   - Never leave half-written originals or thumbnails; write via temporary/atomic helpers (`POSIX` stream writer in `Sync/`, atomic `Data.write(to:options: .atomic)`).
3. **Security-Scoped URLs**:
   - In `expandInputsWithDirectories`, pair `let accessed = url.startAccessingSecurityScopedResource()` immediately with `defer { if accessed { url.stopAccessingSecurityScopedResource() } }`.

---

## Mandatory Guardrails

### Folder Move Cycle Guard (`LiveCharkleEngine.moveFolder`)
- Before changing `moving.parentID = newParentID`, walk the ancestor chain from `newParentID` with a `visited: Set<UUID>` set.
- If `cid == id`, throw `LibraryDatabaseError("不能将文件夹移动到自身或其子目录中。")`.
- Always deduplicate sibling folder names case-insensitively (`"Name 2"`, `"Name 3"`, ...) and forbid naming a root folder `"Inbox"`.

### Recursive Directory Drop Guard (`LiveCharkleEngine.collectDirectoryFiles`)
- Hard-cap recursion depth (`guard depth < 16 else { return [] }`).
- Skip hidden files/directories (`.` / `._` AppleDouble), symlinks (`isSymbolicLink == true`), and noise directories (`.git`, `.svn`, `.hg`, `node_modules`, `__MACOSX`, `.Trash`, `.build`, `DerivedData`).
- Skip macOS packages (`isPackage == true`) from directory expansion so `.app` / `.rtfd` / `.key` bundles aren't exploded into raw files.

### Deletion Suppression Fingerprints (`LiveCharkleEngine.permanentlyDeleteAssets`)
- Permanent deletion records both `deleted.drive.<remoteID>` and content fingerprints (`deleted.content.<sha256>`, `deleted.md5.<md5>`) in `sync_state` so deleted files never respawn on subsequent syncs across Direct API, Mounted Volume, or WebDAV transports.
- Re-importing the same content intentionally clears prior `deleted.content.*` / `deleted.md5.*` keys inside `LiveCharkleEngine.commit(...)`.

### Network Resolver Resilience (`GitHubRepoResolver`, `SocialPostResolver`, `XPostResolver`)
- Always enforce explicit request (`8s`) and resource (`10s–15s`) timeouts on ephemeral `URLSession`s.
- Always degrade gracefully: if GitHub API or social post media download fails, still persist the asset with canonical metadata and `mediaFetchFailed = true` so the user can retry via `refreshRichAsset(id:)` instead of losing the link.
- Check `Task.checkCancellation()` / `guard !Task.isCancelled else { break }` inside all batch loops and background tasks.
