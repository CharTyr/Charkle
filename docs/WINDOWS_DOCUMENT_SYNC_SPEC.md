# Windows Document Stack, Multi-Modal Diff & Tactile Compact View Sync Specification

> **Canonical Reference**: `Sources/CharkleCore/Contracts/CoreModels.swift`, `Sources/CharkleCore/Contracts/DocumentAndVersionModels.swift`, `Sources/CharkleCore/Contracts/CoreServiceProtocols.swift`, `.trellis/spec/cross-platform/index.md`, `.trellis/spec/windows/fluent2-design-system.md`, and `windows/AGENTS.md`.  
> **Companion Trellis Task**: [`.trellis/tasks/11-28-windows-document-stack-diff-and-compact-view-parity/`](../.trellis/tasks/11-28-windows-document-stack-diff-and-compact-view-parity/)  
> **Target Scope**: Strictly `windows/` (`windows/crates/charkle-core`, `windows/crates/charkle-platform-win`, `windows/src-tauri`, `windows/ui`). Do NOT modify `windows/Cargo.toml` workspace `members` or break `android/rust/charkle-android-ffi`.

---

## 1. Wire Contract (`/.charkle/` & `windows/crates/charkle-core/src/wire/swift_codec.rs`)

### 1.1 Canonical Wire JSON Payloads on `AssetRecord.richMetadata`

All synced fields live inside `AssetRecord.richMetadata` (`AssetRichMetadata`) so per-field HLC Last-Write-Wins deltas (`field:richMetadata` in `SyncFields::diff` / `SyncFields::merge`) replicate cleanly across macOS, iOS/iPadOS, Windows, Android, and Web without changing `SyncOperation` envelope schemas.

```json
{
  "versionStack": {
    "changeNote": "核定第三部分预算数字",
    "editorName": "张主任",
    "groupID": "7B9A2E14-6C41-4F8B-9A12-3D5E7F9012AB",
    "isPinnedPrimary": true,
    "parentAssetID": "1F4C8D20-3A19-4E77-8B55-9012ABCDEF34",
    "versionLabel": "v4 · 张主任改",
    "versionNumber": 4
  },
  "document": {
    "diffSummary": {
      "addedBlocks": 2,
      "comparedToAssetID": "1F4C8D20-3A19-4E77-8B55-9012ABCDEF34",
      "highRiskDateChanges": 1,
      "highRiskNumberChanges": 2,
      "minimapBuckets": [0, 0, 1, 0, 0, 2, 2, 0, 1, 0, 2, 0],
      "modifiedBlocks": 5,
      "movedBlocks": 1,
      "removedBlocks": 1
    },
    "formatFamily": "docx",
    "hasNativeRevisions": true,
    "hasTextLayer": true,
    "pageCount": 6,
    "sheetNames": [],
    "wordCount": 3420
  }
}
```

### 1.2 Exact Rust `serde` Structs (`windows/crates/charkle-core/src/models/document.rs` & `core.rs`)

Every UUID MUST use `crate::wire::swift_codec::{upper_uuid, upper_uuid_opt}` (uppercase hyphenated RFC-4122 `XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX`), and every `AssetRecord` timestamp MUST continue using `cocoa_date` / `cocoa_date_opt` (`COCOA_EPOCH_OFFSET_SEC = 978_307_200.0` seconds since `2001-01-01T00:00:00Z`).

```rust
use serde::{Deserialize, Deserializer, Serialize};
use uuid::Uuid;
use crate::models::core::AssetRecord;
use crate::wire::swift_codec::{upper_uuid, upper_uuid_opt};

fn default_version_one() -> i32 {
    1
}

fn default_true() -> bool {
    true
}

fn clamp_min_one<'de, D: Deserializer<'de>>(deserializer: D) -> Result<i32, D::Error> {
    let raw = Option::<i32>::deserialize(deserializer)?.unwrap_or(1);
    Ok(raw.max(1))
}

fn clamp_non_neg<'de, D: Deserializer<'de>>(deserializer: D) -> Result<i32, D::Error> {
    let raw = Option::<i32>::deserialize(deserializer)?.unwrap_or(0);
    Ok(raw.max(0))
}

#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AssetVersionStackMetadata {
    #[serde(rename = "groupID", with = "upper_uuid")]
    pub group_id: Uuid,
    #[serde(default = "default_version_one", deserialize_with = "clamp_min_one")]
    pub version_number: i32,
    #[serde(
        rename = "parentAssetID",
        default,
        skip_serializing_if = "Option::is_none",
        with = "upper_uuid_opt"
    )]
    pub parent_asset_id: Option<Uuid>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub version_label: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub editor_name: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub change_note: Option<String>,
    #[serde(default)]
    pub is_pinned_primary: bool,
}

impl AssetVersionStackMetadata {
    /// Orders stack siblings ascending by `(versionNumber, createdAt, id)` — 1:1 with Swift `sortedVersions(_:)`.
    pub fn sorted_versions(siblings: &[AssetRecord]) -> Vec<AssetRecord> {
        let mut ordered = siblings.to_vec();
        ordered.sort_by(|lhs, rhs| {
            let lv = lhs
                .rich_metadata
                .as_ref()
                .and_then(|m| m.version_stack.as_ref())
                .map_or(1, |s| s.version_number);
            let rv = rhs
                .rich_metadata
                .as_ref()
                .and_then(|m| m.version_stack.as_ref())
                .map_or(1, |s| s.version_number);
            lv.cmp(&rv)
                .then_with(|| lhs.created_at.cmp(&rhs.created_at))
                .then_with(|| {
                    crate::wire::swift_codec::format_swift_uuid(&lhs.id)
                        .cmp(&crate::wire::swift_codec::format_swift_uuid(&rhs.id))
                })
        });
        ordered
    }

    /// Resolves canonical Primary Version: last pinned sibling, else highest `versionNumber` sibling.
    pub fn resolve_primary_asset(siblings: &[AssetRecord]) -> Option<AssetRecord> {
        let ordered = Self::sorted_versions(siblings);
        ordered
            .iter()
            .rev()
            .find(|a| {
                a.rich_metadata
                    .as_ref()
                    .and_then(|m| m.version_stack.as_ref())
                    .is_some_and(|s| s.is_pinned_primary)
            })
            .cloned()
            .or_else(|| ordered.into_iter().last())
    }

    pub fn newer_than_primary_count(siblings: &[AssetRecord]) -> usize {
        let Some(primary) = Self::resolve_primary_asset(siblings) else {
            return 0;
        };
        let Some(primary_ver) = primary
            .rich_metadata
            .as_ref()
            .and_then(|m| m.version_stack.as_ref())
            .map(|s| s.version_number)
        else {
            return 0;
        };
        siblings
            .iter()
            .filter(|a| {
                a.rich_metadata
                    .as_ref()
                    .and_then(|m| m.version_stack.as_ref())
                    .map_or(0, |s| s.version_number)
                    > primary_ver
            })
            .count()
    }
}

pub const MINIMAP_BUCKET_COUNT: usize = 12;

pub fn normalize_minimap_buckets(raw: &[i32]) -> Vec<i32> {
    if raw.is_empty() {
        return vec![0; MINIMAP_BUCKET_COUNT];
    }
    if raw.len() == MINIMAP_BUCKET_COUNT {
        return raw.iter().map(|&v| v.clamp(0, 2)).collect();
    }
    let mut out = vec![0; MINIMAP_BUCKET_COUNT];
    let len = raw.len().max(1);
    for (idx, &val) in raw.iter().enumerate() {
        let clamped = val.clamp(0, 2);
        let bucket = ((idx * MINIMAP_BUCKET_COUNT) / len).min(MINIMAP_BUCKET_COUNT - 1);
        out[bucket] = out[bucket].max(clamped);
    }
    out
}

fn deserialize_buckets<'de, D: Deserializer<'de>>(deserializer: D) -> Result<Vec<i32>, D::Error> {
    let raw = Option::<Vec<i32>>::deserialize(deserializer)?.unwrap_or_default();
    Ok(normalize_minimap_buckets(&raw))
}

fn default_buckets() -> Vec<i32> {
    vec![0; MINIMAP_BUCKET_COUNT]
}

#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DocumentDiffSummary {
    #[serde(rename = "comparedToAssetID", with = "upper_uuid")]
    pub compared_to_asset_id: Uuid,
    #[serde(default, deserialize_with = "clamp_non_neg")]
    pub added_blocks: i32,
    #[serde(default, deserialize_with = "clamp_non_neg")]
    pub removed_blocks: i32,
    #[serde(default, deserialize_with = "clamp_non_neg")]
    pub modified_blocks: i32,
    #[serde(default, deserialize_with = "clamp_non_neg")]
    pub moved_blocks: i32,
    #[serde(default, deserialize_with = "clamp_non_neg")]
    pub high_risk_number_changes: i32,
    #[serde(default, deserialize_with = "clamp_non_neg")]
    pub high_risk_date_changes: i32,
    #[serde(default = "default_buckets", deserialize_with = "deserialize_buckets")]
    pub minimap_buckets: Vec<i32>,
}

impl DocumentDiffSummary {
    pub fn total_changed_blocks(&self) -> i32 {
        self.added_blocks + self.removed_blocks + self.modified_blocks + self.moved_blocks
    }

    /// Matches Swift `DocumentDiffSummary.compactBridgeLabel` (`"Δ 6处 · 数字1 · 时间1"`).
    pub fn compact_bridge_label(&self) -> String {
        let mut parts = vec![format!("Δ {}处", self.total_changed_blocks())];
        if self.high_risk_number_changes > 0 {
            parts.push(format!("数字{}", self.high_risk_number_changes));
        }
        if self.high_risk_date_changes > 0 {
            parts.push(format!("时间{}", self.high_risk_date_changes));
        }
        parts.join(" · ")
    }
}

fn default_format_other() -> String {
    "other".to_string()
}

#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DocumentRichMetadata {
    /// Stored as open `String` on the wire (`docx | xlsx | pptx | pdf | markdown | plainText | legacyOffice | epub | ofd | other`)
    /// so unrecognized future format families never fail `SyncFields::merge`.
    #[serde(default = "default_format_other")]
    pub format_family: String,
    #[serde(default, deserialize_with = "clamp_non_neg")]
    pub word_count: i32,
    #[serde(default, deserialize_with = "clamp_non_neg")]
    pub page_count: i32,
    #[serde(default)]
    pub sheet_names: Vec<String>,
    #[serde(default)]
    pub has_native_revisions: bool,
    #[serde(default = "default_true")]
    pub has_text_layer: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub diff_summary: Option<DocumentDiffSummary>,
}
```

### 1.3 `AssetRichMetadata`, `GalleryLayoutMode` & `MediaKind::detect` Alignment (`models/core.rs`)

1. **`AssetRichMetadata`** (`windows/crates/charkle-core/src/models/core.rs:835`):
   Append two `#[serde(default, skip_serializing_if = "Option::is_none")]` fields:
   ```rust
   #[serde(default, skip_serializing_if = "Option::is_none")]
   pub version_stack: Option<AssetVersionStackMetadata>,
   #[serde(default, skip_serializing_if = "Option::is_none")]
   pub document: Option<DocumentRichMetadata>,
   ```
   Because `AssetRichMetadata` derives `Default`, all existing struct initializers across `charkle-core` and `android/rust/charkle-android-ffi` continue compiling cleanly when using `..Default::default()` (audit any literal `AssetRichMetadata { ... }` sites without `..Default::default()`).

2. **`GalleryLayoutMode`** (`windows/crates/charkle-core/src/models/core.rs:1670`):
   ```rust
   #[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default, Serialize, Deserialize)]
   #[serde(rename_all = "camelCase")]
   pub enum GalleryLayoutMode {
       #[default]
       VerticalMasonry,
       HorizontalJustified,
       GalleryFilmstrip,
       RingGallery,
       CompactList,
   }
   ```

3. **`MediaKind::detect` & `DocumentFormatFamily::detect`** (`models/core.rs:63` & `media/pipeline.rs:305`):
   - Match Swift `CoreModels.swift` 1:1:
     ```rust
     "pdf" | "md" | "markdown" | "txt" | "rtf"
     | "doc" | "docx" | "wps" | "et" | "dps" | "xlsx" | "xls" | "pptx" | "ppt"
     | "odt" | "ods" | "odp" | "epub" | "ofd"
     | "key" | "pages" | "numbers" | "json" | "yaml" | "yml" | "toml" | "csv" => Self::Document,
     ```
   - MIME fallback in `MediaKind::detect`:
     ```rust
     if mime == "application/pdf"
         || mime.starts_with("text/")
         || mime.contains("officedocument")
         || mime.contains("msword")
         || mime.contains("ms-excel")
         || mime.contains("ms-powerpoint")
         || mime.contains("opendocument")
         || mime == "application/epub+zip"
     {
         return Self::Document;
     }
     ```
   - `DocumentFormatFamily::detect(ext)`:
     - `"docx" | "odt"` -> `"docx"` (badge `"DOCX"`)
     - `"xlsx" | "ods" | "csv"` -> `"xlsx"` (badge `"XLSX"`)
     - `"pptx" | "ppt" | "odp" | "dps" | "key"` -> `"pptx"` (badge `"PPTX"`)
     - `"pdf"` -> `"pdf"` (badge `"PDF"`)
     - `"md" | "markdown"` -> `"markdown"` (badge `"MD"`)
     - `"txt" | "json" | "yaml" | "yml" | "toml" | "rtf"` -> `"plainText"` (badge `"TXT"`)
     - `"doc" | "wps" | "xls" | "et" | "pages" | "numbers"` -> `"legacyOffice"` (badge `"DOC"`)
     - `"epub"` -> `"epub"` (badge `"EPUB"`)
     - `"ofd"` -> `"ofd"` (badge `"OFD"`)
     - `_` -> `"other"` (badge `"DOC"`)

---

## 2. SQLite Derived Cache & FTS5 (`windows/crates/charkle-core/src/db/library_db.rs`)

### 2.1 Local-Only `document_content_cache` DDL

Create `document_content_cache` inside `LibraryDatabase::init_connection` (`library_db.rs:181`, right alongside `local_visual_descriptors` so `PRAGMA user_version = 2` remains forward- and backward-compatible with existing Windows/CLI DBs):

```sql
CREATE TABLE IF NOT EXISTS document_content_cache (
    asset_id TEXT PRIMARY KEY REFERENCES assets(id) ON DELETE CASCADE,
    content_hash TEXT NOT NULL,
    schema_version INTEGER NOT NULL DEFAULT 1,
    structured_json BLOB NOT NULL,
    plain_text TEXT NOT NULL,
    simhash64 INTEGER NOT NULL DEFAULT 0,
    updated_at REAL NOT NULL
);
CREATE INDEX IF NOT EXISTS document_content_cache_hash ON document_content_cache(content_hash);
```

> **Critical `rusqlite` Signed-64-Bit Alignment (`Int64` Parity with Swift)**: Both SQLite `INTEGER` and Swift `LibraryDatabase.upsertDocumentContentCache` store `simhash64` as signed `Int64` (`i64::from_ne_bytes(fingerprint_u64.to_ne_bytes())`, i.e., `fingerprint_u64 as i64`). Passing a raw `u64 >= 2^63` directly to `rusqlite::params!` fails at runtime with `ToSqlConversionFailure`. ALWAYS cast `fingerprint_u64 as i64` on write and `val_i64 as u64` when computing XOR Hamming distance!

### 2.2 Cache Invalidation & FTS5 Pinyin Integration Without Sync Bloat (1:1 with `LibraryDatabase.swift` `a33de79`)

1. **Cache Lookup & Invalidation (`DOCUMENT_CACHE_SCHEMA_VERSION = 1`)**:
   - `cached_structured_document(asset_id, expected_content_hash)` returns `Some((payload, simhash64))` ONLY when `row.schema_version == 1 && (expected_content_hash.is_empty() || row.content_hash == expected_content_hash)`.
   - `document_simhashes(excluding_asset_id)` queries `SELECT c.asset_id, c.simhash64 FROM document_content_cache c JOIN assets a ON a.id = c.asset_id WHERE a.trashed = 0 AND c.simhash64 <> 0`.
2. **Exact FTS5 & Pinyin Indexing Bounds (`rebuild_fts_row` & `search_fields`)**:
   - Match `Sources/CharkleCore/Database/LibraryDatabase.swift` (`a33de79`) 1:1:
     - When building `search_fields(asset, cached_document_text)`, append `cached_document_text`, `version_stack` (`version_label`, `editor_name`, `change_note`), and `document.sheet_names.join(" ")` into `extra_ocr` (`fields[4]`).
     - Bound `search_text::index(field)` at `200_000` chars (`field.chars().take(200_000)`) and `search_text::pinyin(field)` at `16_000` chars (`field.chars().take(16_000)`) so multi-hundred-page documents index in milliseconds.
     - Ensure `search_text::pinyin` emits 8-syllable sliding prefix windows (`start in 1..syllables.len().min(256)`, `end = (start + 8).min(syllables.len())`) so FTS5 `prefix*` queries recall any 1..8-character mid-sentence Chinese phrase or initialism in `O(N)` space.
     - In `fetch_assets` SQL `LIKE` fallback, include `OR EXISTS (SELECT 1 FROM document_content_cache dc WHERE dc.asset_id=a.id AND dc.plain_text LIKE ? ESCAPE '\')`.
   - **Sync Payload Cap**: During `MediaPipeline` `.document` ingest, cap `asset.ocr_text` at `plain.chars().take(2_000)` and `rich_metadata.text_excerpt` at `plain.chars().take(1_200)` — full body text stays strictly in local `document_content_cache` and NEVER bloats `/.charkle/ops/*.jsonl`.

---

## 3. Rust `charkle-core` + `charkle-platform-win` Module Blueprint

### 3.1 OS Seam for Legacy Office Formats (`traits/mod.rs` & `charkle-platform-win/src/ifilter.rs`)

To keep `charkle-core` 100% OS-agnostic (required by `android/rust/charkle-android-ffi`):

1. In `windows/crates/charkle-core/src/traits/mod.rs`:
   ```rust
   #[async_trait]
   pub trait LegacyDocumentTextProvider: Send + Sync {
       async fn extract_plain_text(&self, file_path: &Path) -> Result<Option<String>, String>;
   }

   #[derive(Debug, Default, Clone, Copy)]
   pub struct NoopLegacyDocumentTextProvider;

   #[async_trait]
   impl LegacyDocumentTextProvider for NoopLegacyDocumentTextProvider {
       async fn extract_plain_text(&self, _file_path: &Path) -> Result<Option<String>, String> {
           Ok(None)
       }
   }
   ```
   Attach via builder `.with_legacy_document_provider(Arc<dyn LegacyDocumentTextProvider>)` on `MediaPipeline` and `LiveCharkleEngine` (defaulting to `Arc::new(NoopLegacyDocumentTextProvider)`).

2. In `windows/crates/charkle-platform-win/src/ifilter.rs` (`Win32IFilterDocumentProvider`):
   - Add `"Win32_Storage_IndexServer"` (or bind `LoadIFilter` from `query.dll` via raw `windows_core::GUID` + COM vtable if `Win32_Storage_IndexServer` is omitted in `windows 0.58`) inside `windows/crates/charkle-platform-win/Cargo.toml`.
   - Execute inside `tokio::task::spawn_blocking` with `std::panic::catch_unwind` and a 5-second wall-clock deadline:
     1. Initialize COM (`CoInitializeEx(None, COINIT_MULTITHREADED)` with `RPC_E_CHANGED_MODE` tolerance).
     2. Call `LoadIFilter(PCWSTR(wide_path.as_ptr()), None)` -> `IFilter::Init(IFILTER_INIT_CANON_PARAGRAPHS | IFILTER_INIT_HARD_LINE_BREAKS | IFILTER_INIT_APPLY_INDEX_ATTRIBUTES, &[])`.
     3. Loop `GetChunk` (`FILTER_E_END_OF_CHUNKS` terminates); when `(chunk.flags & CHUNK_TEXT) != 0`, loop `GetText` into a `[u16; 4096]` buffer (`FILTER_E_NO_MORE_TEXT` advances to next chunk), capping total extracted text at `512 KiB`.
     4. **Clean-Machine Fallback**: If no `IFilter` handler is registered for `.wps` / `.et` / `.doc` / `.xls` (`E_FAIL` / `REGDB_E_CLASSNOTREG`), scan the OLE Compound File (`\xD0\xCF\x11\xE0`) stream for contiguous printable UTF-16LE CJK/ASCII runs (`>= 6` chars) so offline Chinese workstations without Office desktop `IFilter` packs still recover searchable text!

### 3.2 Native Offline Parsers (`windows/crates/charkle-core/src/media/document_parser.rs`)

All archive reads MUST enforce strict safety bounds (`MAX_ZIP_ENTRIES = 4_096`, `MAX_XML_ENTRY_BYTES = 32 * 1024 * 1024`, `MAX_TOTAL_UNCOMPRESSED_BYTES = 128 * 1024 * 1024`) using `file.take(MAX_XML_ENTRY_BYTES + 1)`.

1. **`.docx` Parser (`zip` + `quick-xml`)**:
   - **`docProps/core.xml`**: Extract `<cp:lastModifiedBy>` (fallback `<dc:creator>`) -> `author_or_editor`, `<dc:title>`.
   - **`word/comments.xml`**: Map `<w:comment w:id="..." w:author="..." w:date="...">` text into `HashMap<String, DocumentComment>`.
   - **`word/document.xml`**:
     - Walk direct children of `<w:body>`:
       - Track `xml_paragraph_index: usize` (0-based ordinal of every direct `<w:body>/<w:p>` element — this exact index anchors Scheme B surgical replacement!).
       - Inside `<w:p>`:
         - Detect heading level from `<w:pStyle w:val="Heading1..6" | "1..6" | "标题1..6">` or `<w:outlineLvl w:val="0..5">`.
         - Detect red-header styling (`is_red_header_style = true`) when early paragraphs (`index < 5`) use red run/border colors (`FF0000`, `C00000`, `D93B30`, `E02020`) or match Chinese official red-header keywords (`文件`, `通知`, `通报`, `决定`, `批复`, `请示`, `报告`, `函`).
         - Normal `<w:r>/<w:t>` appends to paragraph `text` (`<w:tab/>` -> `\t`, `<w:br/>` -> `\n`).
         - Native track changes: `<w:ins w:author="..." w:date="...">` appends to `text` AND pushes `DocumentTrackRevisionSpan { kind: Inserted, ... }` (`has_native_revisions = true`); `<w:del ...>` (`<w:delText>`) does NOT append to clean final `text`, but pushes `DocumentTrackRevisionSpan { kind: Deleted, ... }` (`has_native_revisions = true`).
         - Comments: `<w:commentRangeStart w:id="X"/>` / `<w:commentReference w:id="X"/>` links `comment_ids` and populates `anchor_block_index` + `anchor_excerpt` on `DocumentComment`.
         - **Complex Structure Protection**: Set `is_protected_complex = true` (with human-readable `protection_reason`) whenever `<w:p>` contains `<w:fldChar>`, `<w:instrText>`, `<w:fldSimple>`, `<w:drawing>`, `<w:pict>`, `<mc:AlternateContent>`, `<o:OLEObject>`, `<m:oMath>`, or native `<w:ins>`/`<w:del>`.
       - Inside `<w:body>/<w:tbl>`:
         - Extract `table_rows: Vec<Vec<String>>` across `<w:tr>/<w:tc>`.
         - Emit a `DocumentBlock` with `kind: DocumentBlockKind::Table`. Set `is_protected_complex = true` if the table contains `<w:vMerge>`, `<w:gridSpan>` (`val > 1`), or nested `<w:tbl>` (and note that in Scheme B, ALL `<w:tbl>` blocks are read-only in 2-Way merge, while plain `<w:body>/<w:p>` blocks with `!is_protected_complex` are 2-Way synthesizable!).
     - Estimate `page_count` from `<w:lastRenderedPageBreak/>` + explicit `<w:br w:type="page"/>` count (fallback `(word_count / 550).max(1)`).

2. **`.xlsx` Parser (`zip` + `quick-xml`)**:
   - Parse `xl/_rels/workbook.xml.rels` (`Id -> Target`, normalizing leading `/xl/` vs relative `worksheets/sheet1.xml`).
   - Parse `xl/workbook.xml` `<sheet name="..." r:id="..."/>` in workbook order -> `sheet_names`.
   - Parse `xl/sharedStrings.xml`: collect each `<si>` (concatenating all `<t>` runs, skipping phonetic `<rPh>` furigana!) into `Vec<String>`.
   - Parse each `xl/worksheets/sheet*.xml` (capping preview hydration at `10_000` rows per sheet):
     - Decode cell reference `r="C14"` -> `(col = 2, row = 14)`.
     - Read `<f>` into `formulas_by_col.insert(col, formula_str)`.
     - Resolve `<v>` / `<is>` by `t` attribute (`"s"` -> `shared_strings[idx]`, `"inlineStr"` -> `<is><t>`, `"b"` -> `"TRUE"/"FALSE"`, default -> raw `<v>`).
     - Populate `SpreadsheetSheet { name, sheet_index, headers, rows, column_count, suggested_primary_key_col }`.

3. **`.pptx`, `.odt` & `.epub` ZIP Parsers (`DocumentParserEngine.swift` Parity)**:
   - `.pptx`: Read `ppt/slides/slide1.xml..slideN.xml` sorted numerically; join `<a:t>` runs per `<a:p>`, emitting one `DocumentBlock { kind: Slide, page_number: Some(n), ... }` per slide (`page_count = slide_count`).
   - `.odt`: Read `content.xml` (`<text:h>` -> `Heading`, `<text:p>` -> `Paragraph`, `<table:table>` -> `Table`) and `meta.xml` (`<dc:creator>`).
   - `.epub`: Read `META-INF/container.xml` -> OPF spine -> XHTML chapter paragraphs via `quick-xml` / `scraper`.

4. **`.pdf` Native Text & Scanned-Page Detector**:
   - Count `/Type /Page` (excluding `/Type /Pages`) for `page_count`.
   - Decompress `/FlateDecode` streams (`flate2::read::ZlibDecoder` with raw deflate fallback), scan `BT ... ET` blocks for `(...) Tj`, `[...] TJ`, and hex `<...>`, decoding UTF-16BE BOM (`FEFF`) and PDFDocEncoding escapes.
   - Set `has_text_layer = non_whitespace_char_count >= 24`. When `!has_text_layer`, mark document as a scanned PDF so Quick Look offers 1-click offline WinRT OCR + Visual Page Overlay Diff!

5. **`.md / .txt / .csv` Multi-Encoding Decoder (`encoding_rs` + `pulldown-cmark`)**:
   - Decode bytes in exact order:
     1. UTF-8 BOM (`EF BB BF`) or valid `std::str::from_utf8(bytes)` -> UTF-8;
     2. UTF-16LE BOM (`FF FE`) -> `encoding_rs::UTF_16LE`;
     3. UTF-16BE BOM (`FE FE` / `FE FF`) -> `encoding_rs::UTF_16BE`;
     4. Null-byte heuristic (even length, `> 20%` alternating `0x00` bytes) -> UTF-16LE/BE;
     5. Fallback -> `encoding_rs::GB18030.decode_without_replacement_handling(bytes)` (losslessly covers ASCII, GB2312, GBK, and GB18030 Chinese government/enterprise `.txt` & `.csv` files!).
   - For `.md` / `.markdown`, parse with `pulldown_cmark::Parser::new_ext(text, Options::ENABLE_TABLES | Options::ENABLE_STRIKETHROUGH)` into `Heading`, `Paragraph`, `ListItem`, `Table`, `CodeBlock`, and `Quote` blocks.

### 3.3 Real Office Page Thumbnails + Fallback Document Poster Card (`IShellItemImageFactory`, `docx-preview` & `MediaArtwork::document_card`)

Match `Sources/CharkleCore/Media/MediaPipeline.swift`, `LiveCharkleEngine+Documents.swift`, and `MediaArtwork.swift` in `windows/crates/charkle-core/src/media/pipeline.rs` & `artwork.rs`:
- **True Office & PDF Page Thumbnails First (Parity with macOS `QLThumbnailGenerator` + AppKit `NSAttributedString` A4 Page Renderer)**:
  - On macOS, when `QLThumbnailGenerator` has no third-party Office thumbnail extension installed, `MediaPipeline` falls back to rendering page 1 of `.docx/.doc/.rtf/.odt` via AppKit `NSAttributedString` + `NSTextStorage` / `NSLayoutManager` / `NSTextContainer(792 × 1120)` onto an opaque pure-white A4 bitmap (`990 × 1400` px with `99pt` margins) so real typography, red headers, and paragraph structure appear everywhere.
  - On Windows, for `.pdf` and all rich-layout / Office document extensions (`docx, doc, wps, xlsx, xls, et, pptx, ppt, dps, rtf, pages, numbers, key, odt, epub, ofd`), invoke the OS shell thumbnail provider (`IShellItemImageFactory` with `SIIGBF_BIGGERSIZEOK` at `1400 × 1400` / PDF first-page raster) first, with optional offscreen `docx-preview` A4 first-page capture when shell handlers are absent on clean machines!
  - Whenever a real page raster (`width >= 160 && height >= 160`, natural `pixel_width × pixel_height != 900 × 1240`) is produced, store that crisp page image DIRECTLY as the asset's `grid520` / `preview1400` thumbnail (do NOT wrap or overwrite it with `MediaArtwork::document_card`!) so Inspector hero preview, Masonry Gallery, Filmstrip, and Compact View display authentic document pages.
  - Never overwrite real Office thumbnails during version updates (`refresh_document_version_posters_if_needed`), and run a one-shot idempotent startup migration upgrading existing Office assets still carrying legacy procedural `900 × 1240` posters when a local original file exists.
  - Attach `diffSummary` (compared to the previous sibling) onto newly merged `vN+1` assets inside `synthesize_document_version` (defaulting `change_note` to `None` when the user leaves the optional note blank — NEVER injecting boilerplate text!) and keep `asset.title` clean without accumulating `_v3` suffixes.
- **Fallback Procedural Card (`MediaArtwork::document_card` — `900 × 1240`, Pure Neutral Palette)**:
  - Used ONLY for plain-text/code formats (`md, markdown, txt, json, yaml, yml, toml, csv`) or when neither `IShellItemImageFactory` nor page rasterization is available.
  - **Dimensions & Pure Neutral Surfaces**: `900 × 1240` (`stageHeight = 980` pure cool-neutral `#F4F5F7` on top + `footerHeight = 260` crisp `#FFFFFF` strip on bottom, `2px #E5E7EB` divider & frame — zero yellowed warm-paper beige).
  - **Format Accent Palette (`documentAccentHex`)**:
    - `is_red_header_style == true` or `pdf` / `ofd` -> `#C83E37`
    - `docx` -> `#2A60E0`
    - `xlsx` (and legacy `XLS` / `ET`) -> `#1D7A46`
    - `pptx` (and legacy `DPS` / `PPT`) -> `#C96A1B`
    - `markdown` -> `#3D5A80`
    - `epub` -> `#0F766E`
    - `plainText` / `other` -> `#475569`
  - **Top Page Sheet (`x = 56, y = 44` from top, `788 × 896`, radius `18`, `#FFFFFF`, `2px #E2E5EA` border)**:
    - When `version_stack.version_number > 1`, draw subtle pure-neutral backing sheets (`#EAEBEC` / `#F4F4F5`).
    - Content priority: (1) first-page raster (`aspectFill`); (2) spreadsheet grid preview; (3) official red-header preview; (4) clean paper preview.
  - **Bottom Footer (`900 × 260`, `#FFFFFF`)**:
    - Clean 2-line bold title (`32px`, `#18191C`), bottom-left format badge + concise spec (`"{N} 表"` or `"{N} 页 · {words} 字"`), and bottom-right version pill (`"主版 vN"` or `"vN"`).

### 3.4 Exact `VersionStemNormalizer` & `DocumentSimHash` (`VersionStackAndDiffEngine.swift` `a33de79` Parity)

1. **Exact Regex Set in `VersionStemNormalizer` (`version_stack.rs`)**:
   Run up to 10 stabilization passes after checking `trailingNameAfterVersionRegex` (`(?:[\-_—·\s]+(?:v\d+|第\d+[版稿]))[\-_—·\s]+([\p{Han}]{2,4})\s*$`):
   - `bracketDupRegex`: `[\s_-]*(?:\(\d{1,3}\)|（\d{1,3}）|\[\d{1,3}\]|【\d{1,3}】)\s*$`
   - `copySuffixRegex` (`(?i)`): `(?:[\s_-]*(?:的?副本\s*\d*|copy(?:\s*\d+)?|\bduplicate\b))\s*$`
   - `copyPrefixRegex` (`(?i)`): `^(?:copy\s+of\s+|副本[\s_-]*)`
   - `editorBracketOrDashRegex`: `(?:[\s_\-—·]+[（(\[【]?|[（(\[【])([\p{Han}A-Za-z]{2,8}?)(?:修改稿|修改版|修订版|批注版|审阅版|核定版|审核版|签批版|改稿|修改|修订|批注|核定|审定|审阅|补充|改|审)[）)\]】]?\s*$` (rejecting stop-words `["最终","终极","最新","正式","内部","公开","打印","盖章","签字","扫描","汇总","修订","修改","初稿","定稿","终稿","副本","红头","全文","正本","附件"]`)
   - `explicitVersionRegex` (`(?i)`): `(?:[\s_.\-—·（(\[【]*(?:v|ver|version)\s*(\d{1,3})(?:\.\d+)?[）)\]】]?|[\s_.\-—·（(\[【]*第\s*(\d{1,3})\s*[版稿次][）)\]】]?)\s*$`
   - `stageKeywordsRegex` (`(?i)`): `[\s_.\-—·]*(?:[（(\[【]?(?:初稿|草稿|讨论稿|征求意见稿|汇报稿|送审稿|报批稿|修改稿|修订稿|审阅稿|核定稿|签批稿|扫描件|签字版|盖章版|定稿|终稿|最终稿|终版|最终版|定版|清样|净版|clean|final|draft|revised|rev\d*)[）)\]】]?)\s*$`
   - `trailingDateRegex`: `[\s_.\-—·]*(?:[（(\[【]?(?:20\d{2}[\-./年]?(?:0[1-9]|1[0-2])[\-./月]?(?:0[1-9]|[12]\d|3[01])日?|(?:0[1-9]|1[0-2])[\-./月](?:0[1-9]|[12]\d|3[01])日?)[）)\]】]?)\s*$`
   - `leadingDateRegex`: `^(?:20\d{2}[\-./]?(?:0[1-9]|1[0-2])[\-./]?(?:0[1-9]|[12]\d|3[01])|(?:0[1-9]|1[0-2])(?:0[1-9]|[12]\d|3[01]))[\s_.\-—·]+`
   - Trim `" _-—·.()（）[]【】"`, then fold width/diacritics/case and retain only Han + alphanumeric chars -> `canonical_stem`.

2. **Exact 64-Bit Paragraph & 2-Gram SimHash (`DocumentSimHash` — Bit-Identical to Swift)**:
   ```rust
   pub fn fnv1a64_avalanche(text: &str) -> u64 {
       let mut hash: u64 = 0xCBF2_9CE4_8422_2325;
       for &byte in text.as_bytes() {
           hash ^= u64::from(byte);
           hash = hash.wrapping_mul(0x0000_0100_0000_01B3);
       }
       // Murmur3 fmix64 finalizer matching Sources/CharkleCore/Media/VersionStackAndDiffEngine.swift
       hash ^= hash >> 33;
       hash = hash.wrapping_mul(0xFF51_AFD7_ED55_8CCD);
       hash ^= hash >> 33;
       hash = hash.wrapping_mul(0xC4CE_B9FE_1A85_EC53);
       hash ^= hash >> 33;
       hash
   }

   pub fn simhash_similarity(lhs: i64, rhs: i64) -> f64 {
       if lhs == 0 || rhs == 0 {
           return 0.0;
       }
       let hamming = ((lhs as u64) ^ (rhs as u64)).count_ones();
       //CRITICAL: Divide by 32.0 (orthogonal random baseline = 0.0), NOT 64.0!
       (1.0 - f64::from(hamming) / 32.0).max(0.0)
   }
   ```
   - Per normalized paragraph (`clean` = Han + alphanumeric chars lowercased):
     - Whole-paragraph `fnv1a64_avalanche(&clean)` accumulated with **`weight = 3`**.
     - 2-character shingles (`step = if chars.len() > 400 { 2 } else { 1 }`) accumulated with **`weight = 1`**.
   - **Candidate Matching & Scoring (`LiveCharkleEngine+Documents.swift` Parity)**:
     - Compatible media kinds: `a == b` OR both in `{Image, AnimatedImage, DesignFile}` (allowing `poster_v1.psd` + `poster_v2.png` visual stacks!).
     - `stem_matched`: `canonical_stem.chars().count() >= 2` matching any group member's `fileName` or `title` canonical stem.
     - `sim_matched`: `incoming_kind == Document && incoming_simhash != 0 && incoming_word_count >= 12 && best_sim >= 0.45` (`hamming <= 17`).
     - Score: `StemAndSimHash` -> `(0.92 + best_sim * 0.08).min(1.0)`; `ExactStem` -> `0.90`; `ContentSimHash` -> `best_sim`. Tie-break within `0.02`: `preferred_folder_id` match > `max(updated_at)`.

### 3.5 Multi-Modal Diff, High-Risk Radar & Excel PK Row Alignment (`document_diff.rs` — Exact `a33de79` Parity)

1. **2-Stage Block Alignment + Move Detection**:
   - **Stage 1a**: Pair identical `normalize_block_key` (`"{kind}:{whitespace_collapsed_text}"`) sequentially with shared positive cluster IDs.
   - **Stage 1b**: Pair remaining same-kind blocks whose atom Jaccard `block_similarity >= 0.52` (greedy descending by similarity, tie-broken by `|bi - ti|`) with shared positive cluster IDs so stationary edited paragraphs stay anchored on the LCS spine.
   - **Stage 2**: Run `compute_lcs_anchors` (O(N) prefix/suffix trim + DP up to `250_000` cells + unique-item greedy fallback); inside gaps, pair sequential blocks with `sim >= 0.25` (or equal gap lengths & same `kind`) as `Modified`.
   - **Cross-Gap Move Detection**: Match pure `Removed` and pure `Added` steps (`t_key.chars().count() >= 6`) when exact key matches or `block_similarity >= 0.88` -> convert to `DocumentDiffChangeKind::Moved` (`moved_from_index`, `moved_to_index`) and suppress the duplicate `Removed` hunk.
   - **Inline Atom Tokenizer**: `(?:[¥￥\$]?\d[\d,./:%‰\-年月日万亿元]*|\p{Han}|[A-Za-z]+|\s+|[^\s\p{Han}A-Za-z\d])`.

2. **Exact High-Risk Date/Time & Number Regexes (`scan_high_risk_entities`)**:
   Evaluate `date_risk_regex` FIRST, then strip/mask any matched date/time byte ranges BEFORE running `number_risk_regex` or bare-digit changed-span scanning (so clock times like `14:30 -> 15:00`, years like `2026年`, and dotted dates like `11.28` classify strictly as `high_risk_date_changes` and NEVER leak into `high_risk_number_changes`!). Compare base vs target extracted token lists via ordered LCS multiset diff (`diff_ordered_multiset`) so unchanged numbers/dates in the same paragraph NEVER false-alarm:
   - **`date_risk_regex` (`(?i)`)**:
     `(?:20\d{2}\s*[年\-/.]\s*\d{1,2}\s*[月\-/.]\s*\d{1,2}\s*日?(?:前|内|底|止)?|(?:19|20)\d{2}\s*[—–\-~至]\s*(?:19|20)\d{2}\s*年?|\d{4}\s*年\s*\d{1,2}\s*月(?:底|前|初|中旬|下旬)?|(?:19|20)\d{2}\s*年|\d{1,2}\s*月\s*\d{1,2}\s*日(?:前|内|底|止)?|(?:[01]?\d|2[0-3])\s*[:：]\s*[0-5]\d(?:\s*[:：]\s*[0-5]\d)?|(?:上午|下午|中午|晚|凌晨)?\s*\d{1,2}\s*[点时](?:\s*\d{1,2}\s*分|半|整)?|Q[1-4]|第[一二三四1-4]季度|\d{1,3}\s*(?:个?工作日|自然日|天|小时|个月|周)(?:内|前|以上|以内)?)`
     *(Plus dotted month-day `(?:1[0-2]|0?[1-9])\.(?:3[01]|[12]\d|0?[1-9])` when not preceded by a digit and followed by `日|的|舆情|会议|活动|通报|事故|专项` or word boundary.)*
   - **`number_risk_regex` (`(?i)`)**:
     `(?:(?:人民币|RMB|CNY|USD|HKD|EUR|¥|￥|\$)\s*[-+]?\d[\d,]*(?:\.\d+)?\s*(?:万亿元|亿元|万元|千元|百元|元|万|亿|美元)?|[-+]?\d[\d,]*(?:\.\d+)?\s*(?:%|‰|万亿元|亿元|万元|元|万|亿|人|名|户|家|处|项|台|套|件|个|批|次|吨|公斤|平方米|㎡|公顷|亩|公里|km|米|倍|分)|[-+]?\d{1,3}(?:,\d{3})+(?:\.\d+)?|[-+]?\d+\.\d+|(?<![A-Za-z0-9.])\d{2,}(?![A-Za-z0-9.]))`
   -*(Note for Rust `regex` crate, which omits look-around: implement the final `\d{2,}` branch by matching `\d{2,}` and checking the immediately preceding/following byte is not `[A-Za-z0-9.]`, plus the bare-digit changed-span fallback `\d+(?:\.\d+)?` when `datePairCount == 0 && numPairCount == 0`!)*

3. **12-Bucket Minimap Projection (`build_minimap_buckets`)**:
   For `hunks` (`count = 12`), for each `(idx, hunk)` where `hunk.change_kind != Unchanged`, set `slot = ((idx * 12) / hunks.len().max(1)).min(11)` and `buckets[slot] = buckets[slot].max(if is_high_risk { 2 } else { 1 })`.

4. **Excel Primary-Key Row Alignment (`SpreadsheetSheetDiff`)**:
   - Auto-detect `candidate_primary_key_cols` scoring uniqueness, non-empty ratio, and identifier header keywords (`编号|序号|代码|工号|ID|名称|项目|科室|部门|科目`).
   - Disambiguate duplicate PK values deterministically as `count == 1 -> norm`, `count > 1 -> "{norm}##{count}"` (empty cell fallback `"行{row_number}"`), emitting rows in target order with removed base rows interleaved at their predecessor anchor and comparing both `values[col]` and `formulas_by_col.get(&col)`.

### 3.6 Scheme B Zero-Corruption 2-Way Synthesizer (`document_merge.rs`)

1. **Supported Formats**:
   - `.md / .markdown / .txt`: `can_synthesize_two_way = true` (100% lossless text block assembly, preserving original UTF-8 / UTF-16 / GB18030 line-ending style `\r\n` vs `\n`).
   - `.docx`: `can_synthesize_two_way = true` when at least one changed hunk is a non-protected plain `<w:body>/<w:p>` paragraph.
   - `.xlsx / .pdf / .pptx / legacyOffice`: `can_synthesize_two_way = false`, `synthesis_unavailable_reason = Some("当前格式仅支持只读精细对比，请使用系统默认应用修改原稿。")`.

2. **Byte-Preserving `.docx` Surgical `<w:p>` Replacement**:
   - Choose template `.docx` archive: `target` when `prefer_target_as_template == true` (default), else `base`.
   - Open template `.docx` with `zip::ZipArchive`. Open a staging output `.docx` with `zip::ZipWriter`.
   - For every entry in template `.docx`:
     - If `entry.name() != "word/document.xml"`: copy raw bytes verbatim (`ZipWriter::raw_copy_file` or read + write with identical `FileOptions` compression method) so `word/styles.xml`, `word/numbering.xml`, `word/header*.xml`, `word/footer*.xml`, `word/media/*`, `_rels/*`, and `[Content_Types].xml` remain **100% untouched**.
     - For `"word/document.xml"`:
       - Record exact byte ranges `[start..end]` of every direct `<w:body>/<w:p>` element using `quick_xml::Reader::buffer_position()` while tracking element nesting depth.
       - For each `DocumentMergeDecision` where the hunk is `!is_protected_complex` and overrides the template (`keepBase` when template is `target`, `acceptTarget` when template is `base`, or `customText`):
         - Extract the existing `<w:pPr>...</w:pPr>` block (if present) from the template's `<w:p>` slice so **all paragraph indentation, numbering, line spacing, and red-header/heading styles are preserved**.
         -Extract the first `<w:rPr>...</w:rPr>` run formatting block (if present) from the template's `<w:p>` so **font family (e.g. 仿宋_GB2312 / 方正小标宋), font size, and color are preserved**.
         - If replacement text is deleted (`None` — e.g. rejecting an `Added` paragraph in `target`), splice out that `<w:p>...</w:p>` range.
         - If replacement text is `Some(new_text)`, replace that `<w:p>...</w:p>` range with:
           `<w:p>{preserved_pPr}<w:r>{preserved_rPr}<w:t xml:space="preserve">{xml_escaped_text}</w:t></w:r></w:p>` (splitting `\n` into `<w:br/>` runs).
   - **Mandatory Pre-Commit Validation**:
     1. Parse the synthesized `word/document.xml` from start to `Event::Eof` with `quick_xml::Reader` (`check_end_names = true`). Any XML error aborts synthesis before touching library state!
     2. Re-open the staging `.docx` with `zip::ZipArchive::new` and run `document_parser::parse_docx` on it to verify valid OOXML structure.
   - **Ingest & Stack Attachment**:
     - Save as `<clean_stem>_v{next_v}.docx` (or `.md`/`.txt`), ingest into the stack's `folder_id`, attach `AssetVersionStackMetadata` (`group_id`, `version_number = next_v`, `parent_asset_id = Some(target.id)`, `editor_name`, `change_note`, `is_pinned_primary = true`), clear `is_pinned_primary` on older siblings, compute `diff_summary` against `target.id`, and record normal HLC `SyncOperation`s!

---

## 4. Tauri v2 IPC & Fluent 2 React UI (`windows/src-tauri` + `windows/ui`)

### 4.1 Exact Tauri v2 IPC Commands (`windows/src-tauri/src/commands/documents.rs`)

Register in `windows/src-tauri/src/commands/mod.rs` and `windows/src-tauri/src/lib.rs` `tauri::generate_handler![...]`:

| Tauri Command | Request Arguments (camelCase in TS -> snake_case in Tauri) | Return Payload (`IpcResult<T>`) |
| :--- | :--- | :--- |
| `detect_version_stack_candidate` | `{ filePath?: string, fileName?: string, targetFolderId?: string, assetId?: string }` | `VersionStackCandidate \| null` |
| `manage_version_stack` | `{ mutation: VersionStackMutation }` (accepting `{ action: 'join' \| 'create' \| 'setPrimary' \| 'unstack' \| 'updateMeta', assetIDs: string[], targetAssetOrGroupID?: string, primaryAssetID?: string, editorName?: string, changeNote?: string, versionLabel?: string, pinAsPrimary?: boolean, adoptTargetFolder?: boolean }`) | `AssetRecord[]` |
| `read_structured_document` (alias `read_document_structured`) | `{ assetId: string }` | `StructuredDocumentPayload` |
| `compare_document_versions` | `{ baseAssetId: string, targetAssetId: string, sheetName?: string, primaryKeyCol?: number, useOcrIfScanned?: boolean }` | `DocumentComparisonReport` |
| `synthesize_document_version` | `{ baseAssetId: string, targetAssetId: string, preferTargetAsTemplate?: boolean, decisions: DocumentMergeDecision[], editorName?: string, changeNote?: string }` | `SynthesizeDocumentResult` (`{ createdAsset: AssetRecord, updatedStackAssets: AssetRecord[] }`) |

**Primary-Version Resolution in Existing Native Commands (`windows/src-tauri/src/commands/native.rs`)**:
- Update `copy_assets_to_clipboard` (`native.rs:376`) and `start_outbound_drag` (`native.rs:43`) with an optional `exact_version: Option<bool>` parameter (default `false`):
  - When `exact_version != Some(true)` and a requested `asset_id` belongs to a `version_stack`, resolve `state.engine.resolve_primary_stack_asset(id)` so dragging or pressing `Ctrl+C` on a collapsed gallery card, Compact View row, Top-Edge Shelf item, or `Ctrl+J` Quick Jump result **physically guarantees** exporting the `isPinnedPrimary` file (`CF_HDROP` with `\\?\` prefix stripped in `clipboard.rs:872` for WeChat PC `Ctrl+V` compatibility)!
  - When copying/dragging a specific historical version inside the Revision Rail or Inspector (`exact_version: true`), export that exact version's file.

### 4.2 Exact TypeScript Domain Interfaces (`windows/ui/src/types/domain.ts`)

Mirror `Sources/CharkleCore/Contracts/DocumentAndVersionModels.swift` 1:1:

```ts
export type GalleryLayoutMode =
  | 'verticalMasonry'
  | 'horizontalJustified'
  | 'galleryFilmstrip'
  | 'ringGallery'
  | 'compactList';

export type DocumentFormatFamily =
  | 'docx'
  | 'xlsx'
  | 'pptx'
  | 'pdf'
  | 'markdown'
  | 'plainText'
  | 'legacyOffice'
  | 'epub'
  | 'ofd'
  | 'other'
  | (string & {});

export interface AssetVersionStackMetadata {
  groupID: string;
  versionNumber: number;
  parentAssetID?: string | null;
  versionLabel?: string | null;
  editorName?: string | null;
  changeNote?: string | null;
  isPinnedPrimary: boolean;
}

export interface DocumentDiffSummary {
  comparedToAssetID: string;
  addedBlocks: number;
  removedBlocks: number;
  modifiedBlocks: number;
  movedBlocks: number;
  highRiskNumberChanges: number;
  highRiskDateChanges: number;
  /** Length-12 array of 0 (unchanged) | 1 (added/modified/moved) | 2 (high-risk number/date). */
  minimapBuckets: number[];
}

export interface DocumentRichMetadata {
  formatFamily: DocumentFormatFamily;
  wordCount: number;
  pageCount: number;
  sheetNames: string[];
  hasNativeRevisions: boolean;
  hasTextLayer: boolean;
  diffSummary?: DocumentDiffSummary | null;
}
```
*(Plus `DocumentBlock`, `SpreadsheetRow`, `SpreadsheetSheet`, `DocumentComment`, `StructuredDocumentPayload`, `VersionStackCandidate`, `VersionStackMutation`, `DocumentDiffRiskFlag`, `DocumentDiffChangeKind`, `DocumentInlineDiffToken`, `DocumentHighRiskValuePair`, `DocumentTableCellDiff`, `DocumentDiffHunk`, `SpreadsheetRowDiff`, `SpreadsheetSheetDiff`, `DocumentCommentDiff`, `DocumentMergeDecision`, and `DocumentComparisonReport` matching `DocumentAndVersionModels.swift` field-for-field — note `formulasByCol: Record<number, string>` in `SpreadsheetRow` and `riskFlags: DocumentDiffRiskFlag[]` in JSON arrays.)*

### 4.3 Fluent 2 React UI Components & Interaction Specifications (`windows/ui/src/`)

> **Pure Neutral Surface & Plain-Language Guardrails (1:1 with macOS & iOS/iPadOS)**:
> - **Surface Tokens (Zero Yellow / Beige Cast, Zero Violet Cast)**: `--bg-gallery` Light `#F5F5F6` / Dark `#141518`; `--bg-elevated` & `--bg-inspector` Light `#FFFFFF` / Dark `#1C1D20`; `--bg-subtle` & `--bg-inspector-field` Light `#F4F4F5` (hover `#EAEBEC`) / Dark `#25262B` (hover `#2E3036`); hairline `rgba(0,0,0,0.065)` Light / `rgba(255,255,255,0.075)` Dark.
> - **Quiet Monochromatic Controls**: Segmented controls use a neutral `#F4F4F5` (`#25262B` dark) well with a crisp pure-white (`#FFFFFF` / `#2C2E34`) floating active pill (`0 1px 2px rgba(0,0,0,0.06)`) and high-contrast neutral ink — never loud royal-blue pill soup.
> - **Standard Everyday Chinese Naming (Zero Coined Jargon, Zero Tutorial Banners)**: Use `全部 / 文档 / 媒体`, `单列 / 双列` (tooltips `单列列表 / 双列网格`), `历史版本`, `合并版本`, `归入历史版本`, `拆分为独立素材`, `阅读 / 对比 / 合并`, `以新版为准 / 以旧版为准`, `合并预览`, and `保存为新版本`. Never introduce coined labels or instructional banners anywhere in Compact View, Inspector, or Document Studio.

1. **`GalleryCompactView.tsx` (5th Universal Gallery Mode, Shortcut `5` / `Ctrl+5`)**:
   - **Minimal Sub-Toolbar & Per-Destination Layout Memory**:
     - Add `'compactList'` (`紧凑视图`, Fluent `TextBulletListLtr16Regular` / `TextBulletListLtr16Filled` via `CharkleIcon`) as the 5th option in `TopFilterCapsule.tsx` (`layoutModes`), `SettingsPanesFoundation.tsx`, `OnboardingStudio.tsx`, and `App.tsx` keyboard handler (`5` / `Ctrl+5`).
     - In `coordinatorStore.ts`, persist `destinationLayoutOverrides: Record<string, GalleryLayoutMode>` (`localStorage` key `'charkle.win.destinationLayouts.v1'`) keyed identically to `AppCoordinatorStore.layoutDestinationKey(for:)` (`"allItems" | "inbox" | "untagged" | "recent" | "trash" | "folder:<UUID>" | "smartFolder:<UUID>" | "tag:<lowercased>"`, returning `null` for `moodboardsHome / moodboard / pinterest`), automatically restoring a destination's preferred layout on navigation.
     - Left side of sub-toolbar: show category pills (`全部`, `文档`, `媒体`) **ONLY** when `(documentCount > 0 && mediaCount > 0) || quickScope !== 'all'`; when the folder is homogeneous, show a quiet secondary count `"{assets.length} 项"`.
     - Right side (when stage width `>= 680px`): icon-only 2-segment control switching **`单列`** (`columns = 1`, `TextBulletListLtr`, tooltip `单列列表`) ⇄ **`双列`** (`columns = 2`, `Grid`, tooltip `双列网格`, persisted in `'charkle.win.compactColumnMode'`). Delete all tutorial strings.
   - **1-Column Mode (`columns === 1`) — Sleek Unified Hairline Tracklist Surface**:
     - Render virtualized rows (`rowHeight = 52px`) inside ONE elevated rounded table container (`bg-[var(--bg-elevated)]`, `rounded-[12px]`, single `1px`/`0.5pt` hairline border — zero per-row puffy cards or drop shadows).
     - Separate rows with a `1px`/`0.5pt` hairline inset from `leading: 60px` (aligned directly beneath the title column), **suppressing the divider whenever the current or next row is hovered or selected**. Render row hover (`rgba(0,0,0,0.04)`) and selection (`var(--accent-soft)`) as an inset `rounded-[9px]` highlight (`mx-1.5`).
     - **Single-Axis Horizontal Row**:
       - **Col 1 — Crisp Miniature Artwork / Page Cover (`36 × 46px` docs / `38 × 44px` media)**: continuous `6px` squircle corners, `0.5px` optical inner rim (`rgba(0,0,0,0.08)` so white pages stay razor-crisp on `#FFFFFF`), delicate print shadow (`0 1.5px 3px rgba(0,0,0,0.08)`), and a single subtle offset back-sheet when `hasStack` (fanning gently on fine-pointer hover when motion is enabled). Plain `.md/.txt` files without a raster cover show a clean minimal paper sheet with a muted monospaced `MD`/`TXT` label — zero cartoon red/blue skeleton bars.
       - **Col 2 — Primary Title + Subtle Inline Tags**: tight outbound OLE drag handle (`PointerDragContext` -> `startOutboundDrag`) wrapping ONLY the thumbnail + intrinsic `Title` (`line-clamp-1`, middle/end truncation) + optional `★` rating + up to 2 quiet `#tag` pills (`rgba(0,0,0,0.055)`), followed by an open `flex-1` middle zone outside drag initiation so rubber-band marquee box selection works anywhere in open row whitespace!
       - **Col 3 — Right-Aligned Tabular Metadata & Quiet Actions**:
         - Fine-pointer hover icon button (`拷贝文件` `Copy16Regular` -> `copyAssetsToClipboard([primaryAsset.id])`).
         - **Quiet Version Trigger Capsule (`hasStack` only)**: neutral `rgba(0,0,0,0.055)` (hover `0.09`, active `var(--accent-soft)`) displaying stack icon + `v{primaryVer}/{siblings.length}` (`tabular-nums`) + optional `5px` amber dot when `newerThanPrimaryCount > 0` + chevron `▾`.
         - **Audio-Only Waveform Sparkbar**: rendered **ONLY** when `mediaKind === 'audio'`. **Completely omit the 12-stick red/green document minimap barcode** from Compact View rows (`minimapBuckets` remains strictly in the wire schema for sync compatibility).
         - **Concise Spec Text**: `4 页 · 1,365 字`, `4032 × 3024`, or `23 KB` (`tabular-nums`, omitting editor `"xxx核定"` suffixes and `changeNote`).
         - **Tabular Timestamp Column (`w-[68px] text-right tabular-nums`)**: razor-straight right-edge alignment.
   - **2-Column Mode (`columns === 2`) — Clean Non-Splitting Bento Grid**:
     - Pair items strictly 2-by-2 (`0,1`, `2,3`, ...) with tight `8px` horizontal and vertical gaps; **NEVER split `.pair` rows into full-width single rows**.
     - Each cell is a clean `58px`-tall horizontal tile (`bg-[var(--bg-elevated)]`, `0.5px`/`1px` hairline border, `1.5px` `--accent` border + `--accent-soft` fill when selected, zero heavy drop shadows): `[36×46 Crisp Cover] + [Title (1 line) / Spec · Timestamp (1 line)] + Spacer + [Quiet vN/M ▾ capsule if hasStack]`.
   - **Universal Vertical Version History Flyout / Popover (`VersionTimelinePopover`)**:
     - Clicking the quiet `vN/M ▾` capsule in **BOTH** 1-column AND 2-column modes opens an anchored Fluent 2 `Flyout` / vibrancy `Popover` (`width: 312px`, `rounded-[14px]`, `#FFFFFF` / `#1C1D20` with acrylic/blur elevation and solid fallback under Reduced Transparency) — completely replacing the inline horizontal box-and-arrow rail:
       - **Header**: `"历史版本"` + count + `"对比差异"` button (launching Quick Look Diff for default pair).
       - **Newest-First Vertical Timeline (`vN → ... → v1`)**: continuous `1px` vertical hairline spine on the left connecting `8px` circular nodes (filled `--accent` `●` on `isPrimary`, hollow `1.5px` stroke `○` on historical versions), deduplicated clean version descriptor (`cleanDisplayDescriptor` stripping redundant `vN` prefixes and suppressing `"本机"`, `"初稿"`, `"修订版"`, and merge boilerplate, never repeating the parent document title), `"主版"` tag on primary, compact `"Δ N"` pill **ONLY when `totalChangedBlocks > 0`** (clicking opens `prev → ver` diff; never render `"Δ 0处"`), and 1-click `Pin` icon button on non-primary rows to set Primary Version.

2. **Stack Folding in `libraryStore.ts`, Active Drop Banner & Pure-White `InspectorView.tsx`**:
   - **Store Folding**: Keep raw `allAssets: AssetRecord[]` intact in `libraryStore.ts`, and compute `versionStacksByGroupId: Record<string, AssetRecord[]>` + folded `displayAssets: AssetRecord[]` (replacing each `groupID` cluster with `resolvePrimaryAsset(siblings)`).
   - **Active Drop Candidate Banner (`TopEdgeDropShelf.tsx` & `GalleryView.tsx`)**:
     - After OS file drop, invoke `detectVersionStackCandidate({ assetId })` and show a concise `.win-acrylic` prompt (`归入《{targetTitle}》历史版本 (v{nextVersionNumber})？`) with optional `"修改人"` + `"备注（可选）"` inputs, `"同时设为主版本"` toggle, and **`归入版本 (Enter)`** / **`单独保留 (Esc)`** buttons (updating `setShelfHitRect` without re-registering OLE drop targets per `windows/AGENTS.md`).
   - **`InspectorView.tsx` (`历史版本` Section on Pure `#FFFFFF` / `#1C1D20` Rail)**:
     - Right Inspector uses a pure `#FFFFFF` (Dark `#1C1D20`) rail (zero muddy ambient color-smear gradient, `0` opacity reorder grips at rest, clean typographic section headers without leading icon clutter, Photos-Info-style centered squircle hero preview, 1-row continuous color swatch bar hidden on `.document` assets, and zero prison-bar dividers between `CharkleSpecRow` lines).
     - Inside `CharkleDisclosureGroup("历史版本")`, render the matching newest-first (`vN → v1`) **Vertical Timeline Spine**, concise empty state (`"合并同一文档或设计稿的历次修改"`), concise `"对比差异"` + `"设为主版"` top action row, deduplicated labels (never repeating `ver.title` or `"本机"`), `"Δ N"` badge only when `N > 0`, and `"拆分为独立素材"`.

3. **Universal `Ctrl+J` -> `Ctrl+C` Primary File Copy (`JumpAnywhereModal.tsx`)**:
   - Pressing `Ctrl+C` on an active asset row (when `selectionStart === selectionEnd`) invokes `copyAssetsToClipboard([targetUUID])` (`CF_HDROP` Primary Version file) with concise toast confirmation (`已拷贝「{title}」`).

4. **Quick Look Document Studio: Single Header, Continuous Paper Diff & Interactive Paper Merge (`DocumentStudioViewer.tsx` & `PdfDocumentViewer.tsx`)**:
   - **Single Unified `46px` Top Header Bar (Zero Second Version Pill Row!)**:
     - Left: format badge (`DOCX`, `XLSX`, `PDF`, `MD`) + `asset.title` (`line-clamp-1`) + concise spec (`4 页 · 1,365 字`, `tabular-nums`).
     - Right: when `siblings.length >= 2` and `mode === 'reader'`, render a compact **`v{currentVer} ▾`** dropdown menu (listing `vN → v1` + `"设当前版为主版本"`); alongside a quiet 3-segment control **`阅读` | `对比` | `合并`** and external `"打开"` button.
   - **Mode 1 (`阅读` — Full-Bleed Paper Fidelity, Zero Instructional Bars)**:
     - `.docx`: defaults to pure offline **`docx-preview`** (`http://charkle-media.localhost/original/<uuid>`) reproducing real A4 margins, CJK indents, fonts, red headers, embedded images, and merged tables, paired with a floating vibrancy **`原版版式` ⇄ `正文批注`** toggle (and **`原版版式` ⇄ `数据表格`** for `.xlsx`).
     - `.pdf`: full-bleed HiDPI `PdfDocumentViewer.tsx` with a quiet floating page/mode pill (`扫描件` tag only when `!hasTextLayer`, zero verbose banners).
   - **Mode 2 (`对比` — Continuous Document Paper Sheet & Lockstep 2-Column Split Sheet)**:
     - **Slim `38px` Diff Control Bar**: `v1 ▾ → v2 ▾` pickers + compact monochromatic filter chips (`全部 N`, `数字 N`, `时间 N`, `表格 N`, `批注 N` — hiding 0-count secondary chips) on the left; `审阅 | 双栏` (text/Word) or `文本 | 叠层 | 卷帘` (PDF) + `仅看改动` toggle + `↑ / ↓` (`J / K`) steppers on the right.
     - **Continuous Paper Sheet (`审阅`, Default)**: ONE centered elevated paper container (`max-w-[780px]`, `bg-[var(--bg-elevated)]`, `rounded-[10px]`, `0.5px` hairline border, soft paper shadow over `--bg-gallery`) where paragraphs flow in natural reading order — **no separate gray rounded boxes per hunk**! Each paragraph carries a `3px` left margin status bar (`--success` added, `--danger` removed, `--accent` modified/moved), subtle `#idx` + `数字`/`时间` tags when changed, inline word-level token diff (or hanging-indent `−` / `+` selective-token rows), and inline **`"⋯ 省略未改动段落"`** fold dividers whenever unchanged blocks are collapsed.
     - **Synchronized 2-Column Split Paper (`双栏`)**: ONE unified split sheet (`max-w-[980px]`) with a sticky `32px` header (`− v{base} | + v{target}`) and lockstep horizontal paragraph rows (`grid-cols-2`) separated by `0.5px` hairlines and subtle `4%` red/green cell washes with selective token highlighting.
     - **Excel Smart PK Diff**: Sheet tabs + `主键` selector + clean `3px` status-bar row diffs (`旧值 → 新值` & `fx` formula changes).
     - **PDF Dual-Canvas Visual Diff (`PdfVisualDiffStage.tsx`)**: Offscreen `pdfjs-dist` Red-Cyan blend (showing only compact `● 旧版 / ● 新版` legend dots) and pointer-captured Split Curtain Wipe (`v1` / `v2` corner pills, zero tutorial sentences).
   - **Mode 3 (`合并` — Interactive Continuous Paper Merge, Default Empty Note)**:
     - Slim `38px` top bar: `底稿` + **`以新版为准` | `以旧版为准`** segmented control + `"{N} 处差异"`.
     - Centered Continuous Paper Sheet (`max-w-[780px]`): each changed paragraph displays compact `保留 v{base} | 采纳 v{target} | 微调` pills AND allows clicking either the `−` row or `+` row directly on the paper to choose that version (chosen row highlighted with `--accent-soft` + `1px` border + checkmark; unchosen row dimmed to `0.48` opacity; `isProtectedComplex` hunks show a quiet `受保护结构` lock + `打开`), followed by a collapsible **`"合并预览"`** section at the bottom of the paper.
     - Clean `46px` bottom bar: `"修改人"` input + `"备注（可选）"` input (**default `""` empty string — NEVER pre-filled with boilerplate!**) + primary CTA **`"保存为新版本 (v{N+1})"`**.

---

## 5. Mandatory Verification Matrix

Execute all checks from `windows/` and repo root before opening or merging the Windows PR:

```powershell
# 1. Rust formatting, strict zero-warning Clippy & full workspace unit/integration tests
cd windows
cargo fmt --all -- --check
cargo clippy --workspace --all-targets -- -D warnings
cargo test --workspace

# 2. Verify Android UniFFI crate still compiles cleanly against charkle-core
cd ../android/rust/charkle-android-ffi
cargo check

# 3. Frontend TypeScript, Vitest suite (incl. document-stack-compact-view.test.tsx) & Vite production build
cd ../../../windows/ui
npm run typecheck
npm test
npm run build

# 4. Full Windows purity, extension parity & Figma bridge gates
cd ../..
pwsh -NoProfile -ExecutionPolicy Bypass -File windows/scripts/verify-windows.ps1
node --test Resources/BrowserExtension/tests/extension.test.mjs
node scripts/test-figma-plugin.cjs
```

### Required Automated Test Coverage
1. **`windows/crates/charkle-core/tests/document_and_version_stack_tests.rs`**:
   - Golden JSON wire round-trip (`swift_codec::SyncFields::diff` + `SyncFields::merge` + `encode_ops_jsonl`) for `AssetRichMetadata.version_stack` and `AssetRichMetadata.document` (verifying uppercase UUIDs, Cocoa timestamps, 12-bucket `minimapBuckets` clamping, and unknown `formatFamily` forward compatibility).
   - `.docx` parser (headings, paragraphs, tables, `<w:ins>`/`<w:del>`, comments, `cp:lastModifiedBy`, `is_protected_complex`), `.xlsx` parser (sharedStrings, `<f>` formulas, multi-sheet), `.pptx` slide text, `.pdf` text & scanned detection, and `GB18030` + `UTF-16LE` decoding.
   - `document_content_cache` `content_hash` invalidation, high-bit `u64` `simhash64` storage (`>= 0x8000_0000_0000_0000`), and `assets_fts` Chinese + Pinyin recall without polluting `sync_ops`.
   - Chinese office filename stem normalizer + SimHash64 candidate matching, `isPinnedPrimary` anti-override when `v5` joins after pinned `v4`, High-Risk Number/Currency & Date radar, Excel PK row-insertion alignment, and `.docx` Scheme B surgical 2-Way merge preserving non-document ZIP entries byte-for-byte with valid output XML and `None` default `change_note` when unspecified.
2. **`windows/ui/src/__tests__/document-stack-compact-view.test.tsx`**:
   - `GalleryCompactView` 1-col unified hairline table (with smart divider suppression & audio-only sparkbar, zero 12-stick document barcode) ⇄ 2-col non-splitting Bento grid toggle, rubber-band marquee box multi-selection from open row whitespace/margins, per-destination layout memory, and anchored newest-first Vertical Version Timeline Flyout/Popover (`历史版本`, `●`/`○` spine, `Δ N` diff trigger when `N > 0`, deduplicated labels without `"本机"`, 1-click `设为主版`).
   - Active drop candidate prompt (`归入历史版本`), `Ctrl+J` -> `Ctrl+C` invoking `copyAssetsToClipboard` with the Primary Version ID, Quick Look single unified header (`阅读 | 对比 | 合并` + `vN ▾` dropdown), `.docx` (`原版版式` `docx-preview` ⇄ `正文批注`) / `.xlsx` readers, Continuous Paper Diff (`3px` margin status bar + `"⋯ 省略未改动段落"` fold dividers) & Lockstep 2-Column Split Sheet, Excel PK selector, PDF Red-Cyan / Split Curtain visual diff, and interactive Continuous Paper Merge (`保存为新版本` with empty default note).
