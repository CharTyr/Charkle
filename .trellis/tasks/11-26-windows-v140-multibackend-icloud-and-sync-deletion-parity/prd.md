# Windows Parity Handoff (v1.4.0): Simultaneous Multi-Backend Sync, iCloud Drive & Fresh-Install Anti-Resurrection

## Scope
Mirror the `v1.4.0` sync protocol and reliability upgrades shipped on macOS and iOS inside `windows/` (Rust Core + Tauri + Fluent 2 React UI), keeping wire compatibility with `.charkle/ops/*.jsonl`, `.charkle/boards/`, `.charkle/thumbnails/`, and `.charkle/embeddings/`.

## Required Capabilities

### 1. Simultaneous Multi-Backend Sync Profiles & iCloud Drive Support
- Extend `DriveSyncConfig` with optional `backends: [SyncBackendProfile]` while remaining 100% backwards-compatible with single-backend configs.
- Support connecting multiple enabled backends simultaneously (e.g. Google Drive primary + iCloud Drive / WebDAV / local folder secondary):
  - Each backend maintains isolated `backend.opCursor.<backendID>`, `backend.remoteAssets.<backendID>`, and `backend.remoteFolders.<backendID>` state keys so secondary mirrors never clobber primary `driveFileID` bindings.
  - Prune local `sync_ops` only through the minimum op cursor safely acknowledged by all enabled backends.
  - Propagate permanent asset deletions and empty deleted folder cleanup (deepest-first) across secondary backends too.
- Add `iCloudDrive` backend mode (on Windows, detect/allow choosing the iCloud Drive for Windows local folder, e.g. `%USERPROFILE%\iCloudDrive\Charkle`).

### 2. Fresh-Install Anti-Resurrection & Sync Stability Hardening
- **Folder deletion tracking**:
  - Persist `deleted.folder.drive.<remoteID>` and `deleted.folder.path.<normalizedPath>` (`DeletedFolderFingerprint`) in `apply(.deleteFolder)`.
  - Harvest `driveFolderID` / `normalizedPath` even when `.folder` replays after `.deleteFolder` (`clocks.deleted == true`).
  - Skip deleted folders in `reconcile` and trash leftover empty remote folders deepest-first.
- **Asset deletion & cross-device causal replay**:
  - In `apply(.asset)`, if `clocks.deleted == true`, harvest `driveFileID` into `deleted.drive.<id>` and `contentHash` into `deleted.content.<sha256>`.
  - Interleave unseen op shards across devices chronologically while preserving strict ascending per-device sequence numbers, and apply each chunk in global HLC `(stamp.time, stamp.device, seq)` order atomically with cursor updates.
  - Improve unbound `contentHash` matching during `reconcile` so soft-trashed or conflict-renamed unbound assets bind cleanly instead of duplicating as live items.
  - On fresh install (`previous == nil`), trust `.charkle/ops/` location/trash state unless remote `modifiedTime` is strictly newer than `asset.updatedAt + 2s` and the asset is not trashed.
- **Foolproof physical cleanup & transport ID safety**:
  - Enforce per-transport remote ID compatibility before calling remote `moveFile` / `trashFile` (preventing path-based IDs from hitting Google Drive API v3).
  - Trash removed folders deepest-first across multiple convergence passes, strictly only when empty.
  - Execute pending moves even when the cached inventory lacks an entry for the asset's `driveFileID`, and tolerate `404` / `fileNotFound` without aborting the sync run.

## Verification Checklist
- Mirror the new Swift tests in `Tests/CharkleTests/DriveSyncTests.swift` (`freshInstallNeverResurrectsDeletedItems`, `freshInstallHandlesNilDriveIDDeletionsAndUnboundTrashed`) and `Tests/CharkleTests/MultiBackendAndICloudTests.swift` in the Rust test suite.
- Follow `.agents/skills/charkle-windows-ship/SKILL.md` when packaging the Windows `v1.4.0` x64 NSIS installer and updating only the Windows section of GitHub Release `v1.4.0`.
