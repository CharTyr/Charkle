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

### 3.3 Real Office Page Thumbnails + Fallback Document Poster Card (`IShellItemImageFactory` & `MediaArtwork::document_card`)

Match `Sources/CharkleCore/Media/MediaPipeline.swift`, `LiveCharkleEngine+Documents.swift`, and `MediaArtwork.swift` (`swarm/core-and-thumb-polish` parity) in `windows/crates/charkle-core/src/media/pipeline.rs` & `artwork.rs`:
- **True Office & PDF Page Thumbnails First**:
  - For `.pdf` and all rich-layout / Office document extensions (`docx, doc, wps, xlsx, xls, et, pptx, ppt, dps, rtf, pages, numbers, key, odt, epub, ofd`), ALWAYS invoke the OS shell thumbnail provider (`IShellItemImageFactory` with `SIIGBF_BIGGERSIZEOK` at `1400 × 1400` / PDF first-page raster) FIRST!
  - Whenever it returns a valid page raster (`width >= 160 && height >= 160`), store that crisp true page image and natural `pixel_width × pixel_height` DIRECTLY as the asset's `grid520` / `preview1400` thumbnail (do NOT wrap or overwrite it with `MediaArtwork::document_card`!) so Inspector `素材预览`, Masonry Gallery, Filmstrip, and Compact View show the real document page appearance (red headers, fonts, margins, tables).
  - Never overwrite real Office thumbnails during version-stack updates (`refresh_document_version_posters_if_needed`), and run a one-shot idempotent startup migration re-rendering any existing Office assets still carrying legacy procedural `900 × 1240` posters when a local original file exists.
  - Also attach `diffSummary` (compared to the previous stack sibling) onto newly synthesized `vN+1` assets inside `synthesize_document_version` so the Revision Rail immediately displays `Δ X处`.
- **Fallback Procedural Card (`MediaArtwork::document_card` — `900 × 1240`)**:
  - Used ONLY for plain-text/code formats (`md, markdown, txt, json, yaml, yml, toml, csv`) or as a clean fallback when `IShellItemImageFactory` returns `None` on a headless/clean machine without Office shell handlers.
- **Dimensions**: `900 × 1240` (`stageHeight = 980` warm studio paper `#F3F2EE` on top + `footerHeight = 260` crisp `#FFFFFF` strip on bottom, `2px #E7E6E1` divider, outer `2px #E5E7EB` frame).
- **Format Accent Palette (`documentAccentHex`)**:
  - `is_red_header_style == true` or `pdf` / `ofd` -> `#C83E37`
  - `docx` -> `#2A60E0`
  - `xlsx` (and legacy `XLS` / `ET`) -> `#1D7A46`
  - `pptx` (and legacy `DPS` / `PPT`) -> `#C96A1B`
  - `markdown` -> `#3D5A80`
  - `epub` -> `#0F766E`
  - `plainText` / `other` -> `#475569`
- **Top Page Sheet (`x = 56, y = 44` from top, `788 × 896`, radius `18`, `#FFFFFF`, `2px #DFDDD6` border)**:
  - When `version_stack.version_number > 1`, draw two offset backing sheets (`back2` offset `(+12, -12)` `#E4E2DC` stroke `#D3D0C8`; `back1` offset `(+6, -6)` `#ECEBE6` stroke `#DBD8D0`).
  - Content priority: (1) first-page PDF / `IShellItemImageFactory` snapshot (`aspectFill`); (2) spreadsheet preview (`#F4F6F5` header + up to 12 alternating rows × 2..4 columns); (3) red-header official preview (`#C83E37` double rule `4px + 1.5px` + bold title + body blocks); (4) structured paper preview (`8px` top accent bar + headings/paragraphs).
- **Bottom Footer (`900 × 260`, `#FFFFFF`)**:
  - Clean 2-line bold title (`32px`, `#18191C`, max 25 CJK chars/line).
  - Bottom-left format badge pill (`accentHex` at `13%` alpha fill, bold `19px` `accentHex` text) + metadata summary (`"{N} 工作表"` or `"{N} 页"` · `"扫描件"` or `"{words} 字"` · `{editorName}` in `#5C6069`).
  - Bottom-right version pill when `version_stack.is_some()`: `"主版 vN"` (`#2A60E0` `13%` alpha fill + `#2A60E0` ink when `is_pinned_primary`) or `"vN"` (`#ECEBE6` fill + `#3F434A` ink).

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

1. **`GalleryCompactView.tsx` (5th Universal Gallery Mode, Shortcut `5` / `Ctrl+5`)**:
   - **Toolbar & Per-Destination Layout Memory**:
     - Add `'compactList'` (`紧凑视图`, Fluent `TextBulletListLtr16Regular` / `TextBulletListLtr16Filled` via `CharkleIcon`) as the 5th option in `TopFilterCapsule.tsx` (`layoutModes`), `SettingsPanesFoundation.tsx`, `OnboardingStudio.tsx`, and `App.tsx` keyboard handler (`5` / `Ctrl+5`).
     - In `coordinatorStore.ts`, persist `destinationLayoutOverrides: Record<string, GalleryLayoutMode>` (`localStorage` key `'charkle.win.destinationLayouts.v1'`) keyed identically to `AppCoordinatorStore.layoutDestinationKey(for:)` (`"allItems" | "inbox" | "untagged" | "recent" | "trash" | "folder:<UUID>" | "smartFolder:<UUID>" | "tag:<lowercased>"`, returning `null` for `moodboardsHome / moodboard / pinterest`), automatically restoring a destination's preferred layout on navigation while `setDefaultGalleryLayoutMode` clears `"allItems"` override and updates un-overridden destinations.
     - Inside `GalleryCompactView.tsx` sub-bar (with optional quick media scope filter pills `全部` / `文档叠` / `视觉·媒体` matching `QuickMediaScope`), provide a compact 2-item Fluent `SegmentedControl`: **`双列索引卡`** (`columns = 2`, auto-collapsing to `1` column when stage width `< 680px`, matching `CompactIndexLayoutMetrics.twoColumnMinViewportWidth = 680`) ⇄ **`单列折页条`** (`columns = 1`, persisted in `'charkle.win.compactColumnMode'`).
   - **Virtualized Tactile Index Card Geometry**:
     - Virtualize rows (`rowHeight = 76px` collapsed; dynamic measured height when Revision Rail is expanded, spanning `col-span-2` in 2-col grid) so 10,000+ item libraries scroll at 120Hz with `< 1%` idle CPU.
     - **Surface Tokens**: `bg-[var(--bg-elevated)]` (`#FFFFFF` Light / `#24262C` Dark), `border border-[var(--win-stroke-card)]`, `.win-control-elevation`, `rounded-[var(--win-radius-card)]` (`8px`), selected ring `ring-[1.5px] ring-[var(--accent)]`. Zero violet hues, zero `transition: all`.
     - **3D Micro-Folio Left Artifact (`44 × 52px`, `perspective: 420px`)**:
       - When `stackSiblings.length > 1`, render 2 layered backing sheets (`--ck-paper-back2`, `--ck-paper-back1`) behind the cover sheet (`transform-origin: 0% 85%`). Under `@media (hover: hover) and (pointer: fine)` (and ONLY when `prefers-reduced-motion: no-preference` and `data-animations !== 'disabled'`), hovering the card fans the cover (`rotateY(-26deg) translateX(-1px)`), sheet-1 (`rotateY(-14deg) translateX(4px) translateY(-2px) rotate(4deg)`), and sheet-2 (`translateX(8px) translateY(-3.5px) rotate(8deg)`) using `cubic-bezier(0.22, 1.18, 0.36, 1)` (`280ms`), matching `CompactIndexLayoutMetrics.microFolioLayerPoses` 1:1.
       - Cover content adapts by `MediaKind`: for `document`, render the real `grid520` page thumbnail inside the front folio sheet whenever available, falling back to miniature red-header / green-grid / page skeleton + non-truncating format badge (`whitespace-nowrap shrink-0` so `DOCX`/`XLSX` never clips to `"D..."`); crisp `grid520` thumbnail + 4-swatch bottom palette bar for `image / animatedImage / designFile`; 8-bar accent mini-waveform for `audio`; domain favicon/cover for `webBookmark`.
     - **Center Identity, Stack Pill & Rubber-Band Marquee Multi-Selection**:
       - Truncated title (`min-w-0`, Tooltip when truncated) + interactive stack pill (`主版 v4 · +1 新版` in warm amber accent when `newerThanPrimaryCount > 0`, else `主版 v4 · 共N版`).
       - Adaptive metadata line (`charkle-tabular`): `6 页 · 张主任` / `3 工作表` for `document`, `4032 × 3024` for `image`, `18:42 · M4A` for `audio`, plus up to 2 tag chips (`+N` overflow).
       - **Scoped Outbound Drag Hit Target + Rubber-Band Marquee Box Multi-Select**: Scope the outbound Win32 OLE drag trigger (`PointerDragContext` -> `startOutboundDrag`) strictly to the left `CompactMicroFolioArtifact` + intrinsic title/tags block (NOT stretching `flex-1` across the open middle expanse of 1-column Folio Strips, though single-clicking anywhere on the row still selects it). Dragging starting in stage margins, row/column gaps, open middle strip whitespace, or empty space below rows draws a live Explorer/Finder-style rubber-band marquee rectangle (`rounded-[4px]`, `color-mix(in srgb, var(--accent) 11%, transparent)` fill, `1px` `color-mix(in srgb, var(--accent) 68%, transparent)` border) in both `单列折页条` and `双列索引卡`, intersecting tracked card rects in real time to update `selectedAssetIds` (replacing selection on unmodified drag; toggling/unioning against `baseSelection` when `Ctrl` or `Shift` is held; smoothly auto-scrolling near top/bottom viewport edges).
     - **Right Action & 12-Segment Diff Minimap**:
       - Fine-pointer hover quick button **`拷贝文件`** (`copyAssetsToClipboard([primaryAsset.id])` -> toast `已拷贝「…」原文件实体，切微信直接 Ctrl+V 发送`).
       - 12 vertical `3px`-wide rounded bars (`h-2` neutral `--win-stroke-control-bevel` for `0`, `h-3` `--success` for `1`, `h-3.5` `--danger` for `2`) above `charkle-tabular` relative timestamp.
     - **Inline Expandable Revision Rail**:
       - Clicking the stack pill toggles inline rail expansion (`CharkleDisclosureGroup` / smooth transform-opacity reveal) showing horizontal version nodes separated by clickable **`Δ 6处 · 数字1`** (`compactBridgeLabel`) pills (stripping any redundant leading `^v\d+\s*(?:[·•:：\-]\s*)?` prefix from `versionLabel` / `changeNote` in both Revision Rail cards and `InspectorView.tsx` so `"v1 v1"` never occurs):
         - Clicking any version card's **`设为主版`** (or clicking a version node action) invokes `manageVersionStack({ action: 'setPrimary', assetIDs: [ver.id], primaryAssetID: ver.id, pinAsPrimary: true })`.
         - Clicking any **`Δ`** bridge pill (or **`进入精细对比与取舍 →`**) opens `QuickLookOverlay` directly in Diff mode comparing `(prevVer.id, ver.id)`!

2. **Stack Folding in `libraryStore.ts`, Active Drop Banner & `InspectorView.tsx`**:
   - **Store Folding**: Keep raw `allAssets: AssetRecord[]` intact in `libraryStore.ts`, and compute `versionStacksByGroupId: Record<string, AssetRecord[]>` + folded `displayAssets: AssetRecord[]` (replacing each `groupID` cluster with `resolvePrimaryAsset(siblings)`). Expose `getStackSiblings(assetId)` and `getPrimaryAsset(assetId)`.
   - **Active Drop Candidate Banner (`TopEdgeDropShelf.tsx` & `GalleryView.tsx`)**:
     - After OS file drop (`useTauriFileDrop.ts` / `shelf_win.rs` drop event), check newly ingested assets via `detectVersionStackCandidate({ assetId })`.
     - When matched, display a non-blocking `.win-acrylic` banner (`叠入《{targetTitle}》作为 v{nextVersionNumber}？`) with pre-filled `editorName` input + 1-line `changeNote` input + **`叠入版本叠 (Enter)`** & **`独立保留 (Esc)`** buttons. In `TopEdgeDropShelf.tsx`, update `setShelfHitRect` immediately when the banner mounts/unmounts (without re-registering OLE drop targets per `windows/AGENTS.md`!).
   - **`InspectorView.tsx` (`版本叠` Section)**:
     - Render inside `CharkleDisclosureGroup` (1:1 shared between main workspace and Quick Look): lists all versions (`v1..vN`), shows `主版` badge & `设为主版` action, inline editable `editorName` & `changeNote`, `对比差异`, and `拆出为独立素材`.

3. **Universal `Ctrl+J` -> `Ctrl+C` Primary File Copy (`JumpAnywhereModal.tsx`)**:
   - In `JumpAnywhereModal.tsx` keydown listener: when `activeRow.kind === 'match' && activeRow.match.kind === 'asset'` and the user presses `Ctrl+C` (while `inputRef.current` has `selectionStart === selectionEnd`, or `Ctrl+Shift+C` anytime), call `e.preventDefault()`, invoke `getTransport().copyAssetsToClipboard([targetUUID])`, close or keep palette responsive, and push toast `已拷贝原文件到剪贴板，可直接切微信 Ctrl+V 发送`. Also render a subtle `Ctrl+C 拷贝文件` hint badge on active asset rows.

4. **Quick Look Document Studio, True-Layout `docx-preview` & `pdfjs-dist` Visual Diff (`DocumentStudioViewer.tsx` & `PdfDocumentViewer.tsx`)**:
   - **Clean Readers (Default Mode — `原版版式` ⇄ `结构与批注` Toggle)**:
     - **`.docx` True-Layout + Structured Dual Reader**:
       - Add a compact top-right/floating Fluent capsule toggle **`原版版式` ⇄ `结构与批注`** (defaulting to **`原版版式`** whenever local original `.docx` bytes are cached, and falling back cleanly to **`结构与批注`** for `.odt`, legacy `.doc/.wps`, or uncached cloud items).
       - **`原版版式` (True-Layout OOXML Page View)**: Render original `.docx` bytes streamed from `http://charkle-media.localhost/original/<uuid>` (zero Base64 IPC, 100% offline, zero external network calls) via client-side **`docx-preview`** (`renderAsync(arrayBuffer, containerEl, undefined, { inWrapper: true, ignoreWidth: false, ignoreHeight: false, breakPages: true, renderHeaders: true, renderFooters: true, renderFootnotes: true, renderEndnotes: true })`) inside a studio neutral scroll stage — faithfully reproducing real A4/Letter page margins, CJK 2-character first-line indents (`w:firstLineChars`), fonts (`仿宋_GB2312` / `方正小标宋` / `SimSun`), official red headers (`w:pBdr` & crimson runs), embedded `word/media/*` images/seals, and complex merged tables (`vMerge` / `gridSpan`). Tear down the rendered DOM container cleanly on unmount/asset switch.
       - **`结构与批注` (Structured Blocks & Comments View)**: Paper-proportioned reader sheet (`max-w-[780px]`) rendering extracted headings, body paragraphs, clean bordered tables, toggleable native `<w:ins>`/`<w:del>` track-change pills, and right-margin / collapsible `word/comments.xml` comment cards (with comment count badge on the `结构与批注` pill).
     - `.xlsx`: Bottom/top sheet tab strip + sticky-header tabular grid (`font-variant-numeric: tabular-nums`), formula bar tooltip on cells with `formulasByCol`.
     - `.pdf`: Existing HiDPI `PdfDocumentViewer.tsx` (`http://charkle-media.localhost/original/<uuid>`) enhanced with scanned-PDF badge when `!hasTextLayer`.
     - `.md / .txt`: Existing `DocumentMarkdownViewer.tsx` (`marked` + `DOMPurify` rendered ⇄ raw source toggle).
   - **Multi-Modal Diff Stage (`对比差异` Toggle)**:
     - Top bar: Base version `CustomSelect` (`v3`) ⇄ Target version `CustomSelect` (`v4`) + **`对比差异`** toggle + **`按差异合成新版本`** button (enabled when `report.canSynthesizeTwoWay`).
     - **High-Risk Radar Filter Strip**: Capsule buttons (`全部改动`, `数字变动`, `日期时间`, `表格变动`, `原生修订/批注`, using a pure number badge icon such as `NumberCircle` rather than `¥`) with live counts + **`仅看改动段落`** `Switch` (default `true`) + `J` / `K` keyboard hunk stepping (guarded by `!isTypingInsideQuickLook`).
     - **Word / Text View Modes & Icon-Gutter Selective Highlighting**:
       - **`行内审阅`** (inline unified diff with red strikethrough deleted tokens, green highlighted inserted tokens, high-risk amber/crimson callout badges, and `↕ 段落自第 N 节移入` Move badge) ⇄ **`左右分栏`** (synchronized scroll ratio between base & target panes using compact `− v{base}` / `+ v{target}` icon headers rather than bare `"旧版"` / `"新版"` text labels).
       - **Icon-Gutter Diff Fallback Rows**: Whenever rendering separate base/target rows in diff cards, use `flex items-start gap-2` **hanging-indent icon-gutter rows** — leading `−` (`DismissCircle` / `SubtractCircle16Filled` badge in `--danger`, `aria-label="修改前"`) and `+` (`AddCircle` / `AddCircle16Filled` badge in `--success`, `aria-label="修改后"`) with selective `inlineTokens` span highlighting (`equal` tokens in calm normal `--text-primary` ink without strikethrough or background fill; ONLY `deleted` tokens in `--danger` + `line-through` + `13%` crimson tint; ONLY `inserted` tokens in `--success` + `font-semibold` + `14%` green tint). **Strictly forbid** `"旧版："` / `"新版："` leading text prefixes or painting entire multi-line paragraphs solid green / solid struck-through red.
     - **Excel Diff View**: Sheet tabs with changed-row count badges + **`主键列`** `CustomSelect` (pre-selecting `primaryKeyCol`, allowing manual override which re-invokes `compareDocumentVersions`) + row status (`新增行` / `删除行` / `修改`) + inline cell `旧值 → 新值` & `fx` formula diff badges.
     - **PDF Text/OCR + Dual-Canvas Visual Diff (`PdfVisualDiffStage.tsx`)**:
       - Mode switcher: **`文本对比`** (with **`离线 OCR 识别对比`** button passing `useOcrIfScanned: true` into `compareDocumentVersions` -> `WinRtOcrProvider`) ⇄ **`红青叠层 (Red-Cyan)`** ⇄ **`左右卷帘 (Split Curtain)`**.
       - Render `base` page `P` and `target` page `P` offscreen via `pdfjs-dist` at matching HiDPI scale (`maxDimension = 1100`):
         - **Red-Cyan Blend (`PDFVisualDiffRenderer.makeRedCyanOverlayRGBA` 1:1 Parity)**: For each pixel `i`, compute `baseInk = 255 - ((r*299 + g*587 + b*114) >> 0) / 1000` and `targetInk = 255 - ((r*299 + g*587 + b*114) >> 0) / 1000`, `diff = Math.abs(baseInk - targetInk)`:
           - `diff <= 18`: unchanged ink -> `avg = Math.max(0, Math.min(255, 255 - Math.floor(((baseInk + targetInk) >> 1) * 3 / 4)))`, RGBA `[avg, avg, avg, 255]`.
           - `baseInk > targetInk`: removed/shifted from Base -> `s = Math.min(255, Math.floor(diff * 1.5))`, RGBA `[235, Math.max(0, 245 - s), Math.max(0, 245 - s), 255]`.
           - `targetInk > baseInk`: added in Target (signature/stamp) -> `s = Math.min(255, Math.floor(diff * 1.5))`, RGBA `[Math.max(0, 245 - s), Math.max(0, 250 - (s >> 1)), 242, 255]`.
         - **Split Curtain Wipe**: Stack target `<canvas>` over base `<canvas>` with `clip-path: inset(0 0 0 ${curtainPercent}%)` driven by a pointer-captured vertical divider handle (`0%..100%`, zero React re-render during drag via ref/style update, keyboard `←/→` fine step).
   - **Scheme B 2-Way Synthesis Drawer/View (`按差异合成新版本`)**:
     - Template selector (`以新版 vN 为底稿（推荐）` vs `以旧版为底稿`).
     - **Icon-Gutter Per-Hunk Decision Cards (Zero `"旧版："` / `"新版："` Prefixes)**:
       - Render two clean `flex items-start gap-2` hanging-indent rows when `choice !== 'customText'` and `!hunk.isProtectedComplex`:
         - **Base (`−`) row**: leading `18×18px` shrink-0 `DismissCircle` / minus circle gutter badge (`--danger`, never struck through) + selective `inlineTokens` span renderer filtering `'equal' | 'deleted'` (`equal` in calm normal ink without strikethrough; ONLY `deleted` spans in `--danger` with `line-through` & `13%` soft crimson background).
         - **Target (`+`) row**: leading `18×18px` shrink-0 `AddCircle` / plus circle gutter badge (`--success`) + selective `inlineTokens` span renderer filtering `'equal' | 'inserted'` (`equal` in calm normal-weight ink; ONLY `inserted` spans in `--success` with `font-semibold` & `14%` soft green background).
         - Highlight the currently chosen row (`keepBase` vs `acceptTarget`) with a subtle `1px` semantic border/tint while dimming the unchosen row (`opacity-75`), and provide **`保留旧版`** (`keepBase`) / **`采用新版`** (`acceptTarget`) / **`当场微调`** (`customText` inline `<textarea>`). Complex hunks (`isProtectedComplex === true`) display a neutral lock pill (`受保护结构 · 保持底稿原样`) + **`用默认应用打开`** (`openWithDefaultApp`).
     - **`净版预览`** modal/pane showing `previewMergedText` + **`生成净版 vN+1`** primary CTA invoking `synthesizeDocumentVersion`, automatically pinning `vN+1` as Primary Version and offering 1-click **`拷贝文件发微信`**.

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
   - Chinese office filename stem normalizer + SimHash64 candidate matching, `isPinnedPrimary` anti-override when `v5` joins after pinned `v4`, High-Risk Number/Currency & Date radar, Excel PK row-insertion alignment, and `.docx` Scheme B surgical 2-Way merge preserving non-document ZIP entries byte-for-byte with valid output XML.
2. **`windows/ui/src/__tests__/document-stack-compact-view.test.tsx`**:
   - `GalleryCompactView` 2-col Index Grid ⇄ 1-col Folio Strip toggle, rubber-band marquee box multi-selection from open strip whitespace/margins, per-destination layout memory, 12-segment Diff Minimap rendering, inline Revision Rail expand/collapse (verifying `Δ X处 · 数字Y` bridge labels and deduplicated `v1` labels), `设为主版` (`isPinnedPrimary` lock), and `Δ` bridge opening Quick Look Diff.
   - Active drop candidate stacking banner (`Enter` joins stack), `Ctrl+J` -> `Ctrl+C` invoking `copyAssetsToClipboard` with the Primary Version ID, Quick Look `.docx` (`原版版式` `docx-preview` ⇄ `结构与批注` toggle) / `.xlsx` readers, High-Risk Radar filtering, icon-gutter (`−` / `+`) selective `inlineTokens` diff & merge rows (verifying zero `"旧版："`/`"新版："` prefixes), Excel PK selector, PDF Red-Cyan / Split Curtain mode switching, and Scheme B 2-Way synthesis creating `vN+1`.
