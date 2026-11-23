# Cross-Platform Shared Contracts (macOS · Web · Windows)

> Single source of truth for wire protocols, file formats, safety boundaries, and repository hygiene shared across macOS (`Sources/`), Web (`./web/`), and Windows (`./windows/`).

---

## 1. Lossless `/.charkle/` Bidirectional Sync Wire Contract

### 1. Scope / Trigger
- Trigger: Any modification to `AssetRecord`, `FolderRecord`, `MoodboardDocument`, `SyncOperation`, `SyncManifest`, or `DriveSyncEngine` on any platform (`Sources/CharkleCore/Sync/`, `web/packages/shared/src/sync/swift-codec.ts`, or future `windows/crates/charkle-core/src/sync/`).

### 2. Signatures & Canonical Anchors
- macOS reference: `Sources/CharkleCore/Sync/SyncOperations.swift`, `Sources/CharkleCore/Sync/DriveSyncEngine.swift`, `Sources/CharkleCore/Contracts/*.swift`
- Web codec: `web/packages/shared/src/sync/swift-codec.ts` (`COCOA_REFERENCE_EPOCH_UNIX_SECONDS`, `isoToCocoaSeconds`, `cocoaSecondsToIso`, `toSwiftUUID`, `ASSET_SYNC_EXCLUDED_FIELDS`, `BOARD_SYNC_EXCLUDED_FIELDS`)

### 3. Contracts
1. **Timestamps (Cocoa Reference Epoch)**:
   - Swift default `JSONEncoder` encodes `Date` as floating-point seconds since `2001-01-01T00:00:00Z` (`offset = 978_307_200` seconds from Unix epoch).
   - Encode: `cocoaSec = unixMs / 1000 - 978_307_200`.
   - Decode: accept numeric Cocoa seconds (`new Date((v + 978_307_200) * 1000)`) and ISO-8601 fallback strings.
2. **UUIDs & Binary Data**:
   - UUIDs MUST be canonical **uppercase RFC-4122** (`XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX`).
   - Binary `Data` payloads encode as standard Base64 strings.
3. **Directory Layout inside Library Root**:
   - Human-readable media folders live at `<Root>/Inbox/` and `<Root>/<UserFolder>/...`.
   - Sync metadata lives strictly under `<Root>/.charkle/`:
     - `manifest.json` (`{ "version": 1, "rootFolderID": "...", "directories": { ... } }`)
     - `ops/ops-<deviceId>-<seq>.jsonl` (newline-delimited `SyncOperation` JSON objects)
     - `boards/<UUID>.json` (per-board `MoodboardDocument`)
     - `vectors/` (binary vector shards)
4. **Swift Keyed-Enum Payloads**:
   - `BoardLayoutMode`: `{"autoEditorial":{"_0":{...}}}` or `{"freeform":{}}` (MUST remain decodable on all platforms even when default creation is `freeform`).
   - `BoardNodeKind`: `{"assetRef":{...}}`, `{"note":{...}}`, `{"groupFrame":{...}}`, `{"paletteStrip":{...}}`.
   - `SyncOperation`: `{ "stamp": { "time": Int64, "device": String }, "change": { "<case>": { ... } }, "projectLocation"?: false }`.
   - `AssetChanges.fields` & `BoardChanges.fields`: map of `{ [fieldName]: "<base64-encoded-json-fragment>" }`, excluding `ASSET_SYNC_EXCLUDED_FIELDS` (`id`, `tags`, `isLocalOriginalCached`, `updatedAt`, `updatedHLC`) and `BOARD_SYNC_EXCLUDED_FIELDS` (`id`, `nodes`, `connectors`, `inkStrokes`, `updatedAt`, `updatedHLC`).
5. **Conflict Resolution & Deletion Invariants**:
   - HLC `(time, device)` per-field Last-Write-Wins + tag tombstone sets.
   - Permanently deleted local assets MUST record deletion tombstones so they never respawn from cloud sync; `driveFileID` + `contentHash` track cloud-side renames/moves without losing asset identity.
   - Logical paths inside `/.charkle/` MUST use POSIX `/` separators; Windows clients sanitize illegal OS filename characters (`<>:"/\|?*`) only at local disk projection.

### 4. Validation & Error Matrix
- Malformed or non-finite timestamp -> reject/throw decode error rather than writing `NaN` into `manifest.json` or `ops/*.jsonl`.
- Unknown enum case or future optional `Codable` field -> decode safely with backward-compatible defaults; never drop existing board/asset records.

### 5. Good / Base / Bad Cases
- **Good**: A moodboard created on macOS syncs via Google Drive into Web and Windows with identical UUIDs, timestamps, node frames, and tags, and edits converge cleanly.
- **Base**: Legacy `.autoEditorial` boards decode without error and seamlessly upgrade/render.
- **Bad (Prevented)**: Encoding Unix milliseconds instead of Cocoa seconds shifts every synced asset date by 31+ years on macOS.

### 6. Tests Required
- macOS: `Tests/CharkleTests/DriveSyncTests.swift`
- Web: `web/packages/shared/tests/swift-codec.test.ts` (`swift-codec` round-trip verification)

### 7. Wrong vs Correct
```ts
// WRONG: Writing Unix timestamp and lowercase UUID into /.charkle/ops/
{ id: id.toLowerCase(), updatedAt: Date.now() }

// CORRECT: Canonical uppercase UUID and Cocoa epoch seconds
{ id: toSwiftUUID(id), updatedAt: isoToCocoaSeconds(nowIso) }
```

---

## 2. `.charkleboard` Figma / FigJam Bridge Contract

- **Format**: Standard ZIP archive with `.charkleboard` extension (`format: "charkle-figma-bridge"`, `version: 1`).
- **Required Entries**:
  - `manifest.json`: board metadata, `objects[]` (`image`, `note`, `groupFrame`, `paletteStrip`, `connector`, `inkStroke`, `unsupported` with `geometry: { x, y, width, height, angle, flipX, flipY }`), `originals[]`, `warnings[]`.
  - `tiles/<hash>_r<row>_c<col>.png`: lossless PNG tiles strictly `<= 4096×4096 px` with 64-char hex SHA-256 checksums.
  - `originals/<assetUUID>.<ext>`: raw files required for native `figma.createGif` animated GIFs in FigJam.
- **Plugin Parity**: `Resources/FigmaPlugin/` and `web/figma-plugin/` MUST stay byte-identical and pass `node scripts/test-figma-plugin.cjs`.

---

## 3. External Agent & MCP Safety Policy (14 Tools)

- **Read Tools (8)**: `library_overview`, `search_assets`, `list_inbox`, `get_asset`, `render_contact_sheet`, `list_boards`, `get_board_context`, `export_board_image`.
- **Write Tools (6)**: `organize_assets`, `create_folder`, `ingest_asset`, `compose_moodboard`, `patch_moodboard`, `trash_assets`.
- **Resources (2)**: `charkle://library/overview`, `charkle://boards`.
- **Non-Negotiable Invariant**: Permanent deletion is **STRICTLY FORBIDDEN** through any External Agent / MCP / CLI surface (`trash_assets` is soft-trash only). Channel switches (`mcpEnabled` / `cliEnabled`) and access level (`readOnly` / `readWriteOrganize`) are enforced independently.

---

## 4. Repository Purity, Privacy & Acknowledgements Policy

- **Zero External Inspiration / Author Mentions**: Never include names of external reference/competitor products, design-tip authors, or third-party icon-tool branding anywhere in tracked source code, comments, test fixtures, specs, docs, or user-facing UI strings.
- **Approved Integration Credits**: Actual runtime integrations and tools (e.g., Google Drive, WebDAV, Figma / FigJam, X / Threads / Bluesky / GitHub) are referenced strictly as technical integrations; [`gdirect`](https://github.com/mizorewww/gdirect) is explicitly credited in the root `README.md` **Acknowledgements** section as the Google Drive direct-connection fallback.
- **Zero Local Path / Secret Leaks**: Never commit `/Users/<name>/...` personal absolute paths, `Resources/GoogleOAuthClient.json`, `.env*`, `.dev.vars*`, API keys, OAuth tokens, or code-signing certificate identities.
- **Git Push Discipline**: Always push explicitly (`git push origin main` or specific tag) — NEVER run `git push --all` or `--mirror` (which would leak local internal checkpoint refs).
