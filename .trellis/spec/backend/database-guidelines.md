# Database Guidelines (`LibraryDatabase`)

> Executable contracts for SQLite WAL persistence, FTS5 indexing, JSON payload storage, recursive folder queries, and backward-compatible model decoding.

---

## Core Architecture (`Sources/CharkleCore/Database/LibraryDatabase.swift`)

- `LibraryDatabase` is a `public final actor` wrapping a single `SQLiteConnection` configured with:
  `PRAGMA journal_mode = WAL; PRAGMA foreign_keys = ON; PRAGMA synchronous = NORMAL;`
- All multi-step writes MUST run inside `database.transaction { store in ... }`, which wraps statements in `BEGIN IMMEDIATE` / `COMMIT` with `ROLLBACK` on error.
- Schema version is tracked via `PRAGMA user_version` (currently `schemaVersion = 2`). Additive indexes or columns must be gated by `if version < N` migrations inside `init(path:)`.

---

## Table Contracts & Critical Schema Reality

| Table | Indexed Columns | Full Object Storage |
|-------|-----------------|---------------------|
| `assets` | `id`, `drive_id`, `content_hash`, `folder_id`, `kind`, `shape`, `title`, `rating`, `size`, `created`, `pinned`, `trashed` | `payload BLOB` (JSON-encoded `AssetRecord`) |
| `assets_fts` | FTS5 virtual table: `title, fileName, notes, tags, ocrText, aiDescription, sourceDomain, pinyin, initials` | Synced inside `put(_ asset:)` |
| `asset_tags` | `(asset_id, tag COLLATE NOCASE)` | Normalized lookup for tag filters & counts |
| `asset_colors` | `(asset_id, l, a, b)` | CIELAB color search (`deltaE`) |
| `asset_vectors` | `asset_id`, `feature_print BLOB`, `embedding BLOB`, `precision`, `embedding_model` | Vision FeaturePrint + Cloud semantic vectors |
| `folders` | `id TEXT PRIMARY KEY`, `drive_id TEXT` | `payload BLOB` (JSON-encoded `FolderRecord` — **`parentID`, `colorHex`, `customSymbol`, `sortOrder` live ONLY inside `payload`!**) |
| `boards` | `id`, `pinned` | `payload BLOB` (JSON-encoded `MoodboardDocument`) |
| `sync_ops` | `seq AUTOINCREMENT` | `payload BLOB` (JSON-encoded `SyncOperation`) |
| `sync_state` | `key TEXT PRIMARY KEY` | `payload BLOB` (key-value JSON state: `aiConfig`, `typeSafeConfig`, `smart_folders.v1`, `syncConfig`, `cacheBudgetBytes`, `deleted.content.*`, `local.delete.*`) |

---

## Scenario: Recursive Parent Folder Asset Query (`FilterCriteria.includeSubfolders`)

### 1. Scope / Trigger
- Trigger: Cross-layer query contract change spanning `FilterCriteria`, `LibraryDatabase`, `PlaceholderEngine`, `LibraryStore`, and `SidebarView`.

### 2. Signatures
- `CoreModels.swift`: `FilterCriteria.includeSubfolders: Bool = false`
- `LibraryDatabase.swift`: `private func folderSubtreeIDs(rootID: UUID) throws -> [UUID]`
- `LibraryDatabase.swift`: `public func fetchAssets(matching criteria: FilterCriteria, limit: Int? = nil) throws -> [AssetRecord]`

### 3. Contracts
- When `folderID != nil && includeSubfolders == false` (default): matches ONLY direct children (`a.folder_id = ?`). Required by `LiveCharkleEngine.deleteFolder(id:)` and legacy single-folder callers.
- When `folderID != nil && includeSubfolders == true`: expands `rootID` plus all descendant folder IDs via cycle-safe BFS over `folders.payload`, then queries `a.folder_id IN (?, ?, ...)` utilizing the existing `assets_folder(folder_id, trashed)` index.
- `LibraryStore.applyDestination(.folder(let id))` sets `filter.folderID = id` and `filter.includeSubfolders = true`; all other destinations reset `filter.includeSubfolders = false`.

### 4. Validation & Error Matrix
- Unknown `folderID` -> `folderSubtreeIDs` returns `[rootID]`, query returns `[]` (never throws SQL error).
- Cyclic `parentID` corrupted in remote JSON -> `seen: Set<UUID>` terminates BFS cleanly without infinite loop.

### 5. Good / Base / Bad Cases
- **Good**: Clicking top-level folder `"插画"` with 0 direct assets and 6 subfolders returns all 1,200+ nested assets while honoring active search, color, tag, and sort filters.
- **Base**: Clicking leaf folder `"川瀨巴水"` queries `a.folder_id IN (?)` with 1 ID, identical speed to equality lookup.
- **Bad (Prevented)**: Writing `WITH RECURSIVE ... SELECT f.id FROM folders f JOIN tree t ON f.parent_id = t.id` fails at runtime with `no such column: f.parent_id` because `folders` only has `(id, drive_id, payload)`.

### 6. Tests Required
- `Tests/CharkleTests/UpgradeFeaturesTests.swift` (`recursiveFolderQueryAndSocialAttachments`): asserts `includeSubfolders: false` returns `0` for parent-only query and `includeSubfolders: true` returns both child and grandchild assets.

### 7. Wrong vs Correct
```swift
// WRONG: `folders` table has no `parent_id` SQL column
constrain("a.folder_id IN (WITH RECURSIVE tree(id) AS (SELECT ? UNION ALL SELECT f.id FROM folders f JOIN tree t ON f.parent_id = t.id) SELECT id FROM tree)", .text(folder.uuidString))

// CORRECT: Decode folder graph via BFS and bind into indexed `IN (...)`
let subtreeIDs = try folderSubtreeIDs(rootID: folder)
clauses.append("a.folder_id IN (\(Self.placeholders(subtreeIDs.count)))")
args += subtreeIDs.map { SQLValue.text($0.uuidString) }
```

---

## Backward-Compatible `Codable` Evolution (MANDATORY)

Because `assets`, `folders`, `boards`, and `sync_state` store JSON blobs on disk and replicate across devices via `sync_ops`:

- Whenever you add a new property to `AssetRecord`, `FolderRecord`, `AssetRichMetadata`, `SocialPostMetadata`, `GitHubRepoMetadata`, `SmartFolderRecord`, `MoodboardDocument`, `BoardConnector`, or `SyncStatus`, you **MUST** provide a custom `init(from decoder: Decoder)` using `decodeIfPresent(... ) ?? <default>` (or make the property optional).
- Never rename or remove an existing JSON coding key without a fallback decode path (see `SocialPostMetadata.effectiveAttachments` in `CoreModels.swift` and `BoardConnector` decoding in `MoodboardModels.swift`).
- Update `LibraryDatabase.searchFields(for:)` whenever new searchable metadata (e.g., GitHub repo name/description/topics or social post author/body) is added so FTS5 and Quick Jump index it automatically.

---

## Local-Only State vs Synced Operations

- Use `store.record(.asset(asset))` / `store.saveAssetLocally(asset)` ONLY when a user-visible field actually changed and should sync across Macs.
- For purely local telemetry (such as `AssetRecord.lastOpenedAt` in `LiveCharkleEngine.markAssetOpened(id:)`), use `try store.put(asset)` directly so opening an image never floods Google Drive with sync operations.
- In background enrichment (e.g., `runBackgroundOCRIfNeeded`), skip calling `store.saveAssetLocally` entirely when OCR extracts empty text.
