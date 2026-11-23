//! SQLite WAL + FTS5 + Chinese pinyin + CIELAB + vector + CRDT storage engine.
//!
//! Mirrors `Sources/CharkleCore/Database/LibraryDatabase.swift` and
//! `Sources/CharkleCore/Sync/SyncOperations.swift` 1:1 with schema `user_version = 2`.

use std::collections::{BTreeMap, HashMap, HashSet};
use std::path::Path;
use std::sync::Mutex;

use chrono::{DateTime, TimeZone, Utc};
use rusqlite::types::Value as SqlValue;
use rusqlite::{params, Connection, OptionalExtension};
use serde::de::DeserializeOwned;
use serde::Serialize;
use sha2::{Digest, Sha256};
use uuid::Uuid;

use crate::db::search_text;
use crate::error::{CoreError, CoreResult};
use crate::models::core::{
    AssetRecord, FilterCriteria, FolderRecord, LabColor, QuickJumpKind, QuickJumpMatch,
    SmartFolderRecord, SortOrder, TagCount,
};
use crate::models::media::{cosine_similarity, AssetVector, EmbeddingPrecision};
use crate::models::moodboard::{BoardNodeKind, MoodboardDocument};
use crate::models::sync::{
    tag_map, AssetChanges, BoardChanges, DeletedAssetFingerprint, SyncClocks, SyncOperation,
    SyncOperationChange, SyncStamp,
};
use crate::wire::swift_codec::{canonical_json_bytes, format_swift_uuid, SyncFields};

const SCHEMA_VERSION: i32 = 2;
const SMART_FOLDERS_STATE_KEY: &str = "smart_folders.v1";

const INITIAL_SCHEMA: &str = r#"
CREATE TABLE assets (
    id TEXT PRIMARY KEY,
    drive_id TEXT UNIQUE,
    content_hash TEXT NOT NULL,
    folder_id TEXT,
    kind TEXT NOT NULL,
    shape TEXT NOT NULL,
    title TEXT NOT NULL,
    rating INTEGER NOT NULL,
    size INTEGER NOT NULL,
    created REAL NOT NULL,
    pinned INTEGER NOT NULL,
    trashed INTEGER NOT NULL,
    payload BLOB NOT NULL
);
CREATE INDEX assets_folder ON assets(folder_id, trashed);
CREATE INDEX assets_recency ON assets(trashed, created DESC);
CREATE VIRTUAL TABLE assets_fts USING fts5(
    title, fileName, notes, tags, ocrText, aiDescription, sourceDomain, pinyin, initials,
    tokenize='unicode61 remove_diacritics 2', prefix='2 3 4'
);
CREATE TABLE asset_tags (
    asset_id TEXT REFERENCES assets(id) ON DELETE CASCADE,
    tag TEXT NOT NULL COLLATE NOCASE,
    PRIMARY KEY(asset_id, tag)
);
CREATE INDEX asset_tags_lookup ON asset_tags(tag, asset_id);
CREATE TABLE asset_colors (
    asset_id TEXT REFERENCES assets(id) ON DELETE CASCADE,
    l REAL NOT NULL,
    a REAL NOT NULL,
    b REAL NOT NULL
);
CREATE INDEX asset_colors_asset ON asset_colors(asset_id);
CREATE TABLE asset_vectors (
    asset_id TEXT PRIMARY KEY REFERENCES assets(id) ON DELETE CASCADE,
    feature_print BLOB,
    embedding BLOB,
    precision INTEGER,
    embedding_model TEXT
);
CREATE TABLE folders (
    id TEXT PRIMARY KEY,
    drive_id TEXT,
    payload BLOB NOT NULL
);
CREATE TABLE boards (
    id TEXT PRIMARY KEY,
    pinned INTEGER NOT NULL,
    payload BLOB NOT NULL
);
CREATE TABLE board_assets (
    board_id TEXT REFERENCES boards(id) ON DELETE CASCADE,
    asset_id TEXT NOT NULL,
    PRIMARY KEY(board_id, asset_id)
);
CREATE TABLE sync_ops (
    seq INTEGER PRIMARY KEY AUTOINCREMENT,
    payload BLOB NOT NULL
);
CREATE TABLE sync_state (
    key TEXT PRIMARY KEY,
    payload BLOB NOT NULL
);
CREATE TABLE original_cache (
    asset_id TEXT PRIMARY KEY REFERENCES assets(id) ON DELETE CASCADE,
    accessed_at REAL NOT NULL
);
PRAGMA user_version = 1;
"#;

/// Deterministic RFC-4122 v5-shaped UUID derived from SHA-256 of `key`, matching
/// `DriveFiles.stableUUID(_:)` in Swift byte-for-byte.
pub fn stable_uuid(key: &str) -> Uuid {
    let hash = Sha256::digest(key.as_bytes());
    let mut bytes = [0u8; 16];
    bytes.copy_from_slice(&hash[..16]);
    bytes[6] = (bytes[6] & 0x0F) | 0x50;
    bytes[8] = (bytes[8] & 0x3F) | 0x80;
    Uuid::from_bytes(bytes)
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct MigrationRequeueCounts {
    pub assets: usize,
    pub folders: usize,
    pub boards: usize,
}

/// Thread-safe SQLite-backed library index and CRDT sync journal.
pub struct LibraryDatabase {
    conn: Mutex<Connection>,
}

impl LibraryDatabase {
    /// Opens or initializes a persistent SQLite database at `path`.
    pub fn open(path: &Path) -> CoreResult<Self> {
        if let Some(parent) = path.parent() {
            if !parent.as_os_str().is_empty() {
                std::fs::create_dir_all(parent)?;
            }
        }
        let conn = Connection::open(path)?;
        Self::init_connection(conn)
    }

    /// Opens an isolated in-memory SQLite database for tests.
    pub fn open_in_memory() -> CoreResult<Self> {
        let conn = Connection::open_in_memory()?;
        Self::init_connection(conn)
    }

    fn init_connection(conn: Connection) -> CoreResult<Self> {
        conn.execute_batch(
            "PRAGMA journal_mode = WAL; PRAGMA foreign_keys = ON; PRAGMA synchronous = NORMAL; PRAGMA busy_timeout = 5000;",
        )?;
        conn.execute_batch("BEGIN IMMEDIATE")?;
        let res: CoreResult<()> = (|| {
            let version: i32 = conn.query_row("PRAGMA user_version", [], |row| row.get(0))?;
            if version > SCHEMA_VERSION {
                return Err(CoreError::Database(format!(
                    "Library schema {version} requires a newer version of Charkle."
                )));
            }
            if version == 0 {
                conn.execute_batch(INITIAL_SCHEMA)?;
            }
            if version < 2 {
                conn.execute_batch(
                    "CREATE INDEX IF NOT EXISTS assets_hash ON assets(content_hash) WHERE content_hash <> '';
                     PRAGMA user_version = 2;",
                )?;
            }
            Ok(())
        })();

        match res {
            Ok(()) => {
                conn.execute_batch("COMMIT")?;
                Ok(Self {
                    conn: Mutex::new(conn),
                })
            }
            Err(err) => {
                let _ = conn.execute_batch("ROLLBACK");
                Err(err)
            }
        }
    }

    fn lock_conn(&self) -> CoreResult<std::sync::MutexGuard<'_, Connection>> {
        self.conn
            .lock()
            .map_err(|_| CoreError::Database("SQLite connection mutex poisoned".to_string()))
    }

    /// Executes `work` atomically inside a `BEGIN IMMEDIATE` SQLite transaction.
    pub fn with_transaction<T, F>(&self, work: F) -> CoreResult<T>
    where
        F: FnOnce(&Connection) -> CoreResult<T>,
    {
        let conn = self.lock_conn()?;
        conn.execute_batch("BEGIN IMMEDIATE")?;
        match work(&conn) {
            Ok(value) => {
                conn.execute_batch("COMMIT")?;
                Ok(value)
            }
            Err(err) => {
                let _ = conn.execute_batch("ROLLBACK");
                Err(err)
            }
        }
    }

    pub fn schema_version(&self) -> CoreResult<i32> {
        let conn = self.lock_conn()?;
        Ok(conn.query_row("PRAGMA user_version", [], |row| row.get(0))?)
    }

    // =========================================================================
    // Assets CRUD & FTS5 / CIELAB / Recursive Folder Queries
    // =========================================================================

    pub fn upsert_assets(&self, assets: &[AssetRecord]) -> CoreResult<()> {
        self.with_transaction(|conn| {
            for asset in assets {
                Self::put_asset_conn(conn, asset)?;
            }
            Ok(())
        })
    }

    pub fn put_asset(&self, asset: &AssetRecord) -> CoreResult<()> {
        let conn = self.lock_conn()?;
        Self::put_asset_conn(&conn, asset)
    }

    pub(crate) fn put_asset_conn(conn: &Connection, asset: &AssetRecord) -> CoreResult<()> {
        let id = format_swift_uuid(&asset.id);
        let old = Self::asset_by_id_conn(conn, asset.id)?;
        let payload = canonical_json_bytes(asset)?;
        let created_unix = asset.created_at.timestamp_millis() as f64 / 1000.0;
        let folder_id_str = asset.folder_id.map(|u| format_swift_uuid(&u));

        conn.execute(
            "INSERT INTO assets VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13)
             ON CONFLICT(id) DO UPDATE SET
                drive_id=excluded.drive_id,
                content_hash=excluded.content_hash,
                folder_id=excluded.folder_id,
                kind=excluded.kind,
                shape=excluded.shape,
                title=excluded.title,
                rating=excluded.rating,
                size=excluded.size,
                created=excluded.created,
                pinned=excluded.pinned,
                trashed=excluded.trashed,
                payload=excluded.payload",
            params![
                id,
                asset.drive_file_id,
                asset.content_hash,
                folder_id_str,
                asset.media_kind.raw_value(),
                asset.aspect_shape().raw_value(),
                asset.title,
                asset.rating,
                asset.file_size_bytes,
                created_unix,
                i32::from(asset.pinned_offline),
                i32::from(asset.is_trashed),
                payload,
            ],
        )?;

        if old.as_ref().map(|a| &a.tags) != Some(&asset.tags) {
            conn.execute("DELETE FROM asset_tags WHERE asset_id=?1", params![id])?;
            let mut stmt =
                conn.prepare_cached("INSERT OR IGNORE INTO asset_tags VALUES (?1, ?2)")?;
            for tag in &asset.tags {
                if !tag.is_empty() {
                    stmt.execute(params![id, tag])?;
                }
            }
        }

        if old.as_ref().map(|a| &a.dominant_colors) != Some(&asset.dominant_colors) {
            conn.execute("DELETE FROM asset_colors WHERE asset_id=?1", params![id])?;
            let mut stmt =
                conn.prepare_cached("INSERT INTO asset_colors VALUES (?1, ?2, ?3, ?4)")?;
            for color in &asset.dominant_colors {
                if color.l.is_finite() && color.a.is_finite() && color.b.is_finite() {
                    stmt.execute(params![id, color.l, color.a, color.b])?;
                }
            }
        }

        let fields = Self::search_fields(asset);
        let old_fields = old.as_ref().map(Self::search_fields);
        if old_fields.as_ref() != Some(&fields) {
            let row_id: i64 =
                conn.query_row("SELECT rowid FROM assets WHERE id=?1", params![id], |r| {
                    r.get(0)
                })?;
            if old.is_some() {
                conn.execute("DELETE FROM assets_fts WHERE rowid=?1", params![row_id])?;
            }
            let pinyins: Vec<(String, String)> =
                fields.iter().map(|f| search_text::pinyin(f)).collect();
            let indexed: Vec<String> = fields.iter().map(|f| search_text::index(f)).collect();
            let full_py = pinyins
                .iter()
                .map(|(f, _)| f.as_str())
                .filter(|s| !s.is_empty())
                .collect::<Vec<_>>()
                .join(" ");
            let init_py = pinyins
                .iter()
                .map(|(_, i)| i.as_str())
                .filter(|s| !s.is_empty())
                .collect::<Vec<_>>()
                .join(" ");

            conn.execute(
                "INSERT INTO assets_fts(rowid,title,fileName,notes,tags,ocrText,aiDescription,sourceDomain,pinyin,initials)
                 VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10)",
                params![
                    row_id,
                    indexed[0],
                    indexed[1],
                    indexed[2],
                    indexed[3],
                    indexed[4],
                    indexed[5],
                    indexed[6],
                    full_py,
                    init_py,
                ],
            )?;
        }

        Ok(())
    }

    fn search_fields(asset: &AssetRecord) -> [String; 7] {
        let mut extra_ocr = asset.ocr_text.clone().unwrap_or_default();
        let append_block = |target: &mut String, block: String| {
            if !block.is_empty() {
                if !target.is_empty() {
                    target.push('\n');
                }
                target.push_str(&block);
            }
        };

        if let Some(ref rich) = asset.rich_metadata {
            if let Some(ref repo) = rich.github_repo {
                let readme_prefix: String = repo
                    .readme_markdown
                    .as_deref()
                    .unwrap_or("")
                    .chars()
                    .take(4000)
                    .collect();
                let parts: Vec<&str> = [
                    repo.full_name.as_str(),
                    repo.description.as_deref().unwrap_or(""),
                    repo.language.as_deref().unwrap_or(""),
                ]
                .into_iter()
                .filter(|s| !s.is_empty())
                .collect();
                let mut lines: Vec<String> = parts.into_iter().map(String::from).collect();
                if !repo.topics.is_empty() {
                    lines.push(repo.topics.join(" "));
                }
                if !readme_prefix.is_empty() {
                    lines.push(readme_prefix);
                }
                append_block(&mut extra_ocr, lines.join("\n"));
            }

            if let Some(ref post) = rich.social_post {
                let handle = format!("@{}", post.author_handle);
                let lines: Vec<&str> = [
                    post.platform.display_name(),
                    post.author_name.as_str(),
                    handle.as_str(),
                    post.article_title.as_deref().unwrap_or(""),
                    post.body_text.as_str(),
                    post.quoted_text.as_deref().unwrap_or(""),
                ]
                .into_iter()
                .filter(|s| !s.is_empty())
                .collect();
                append_block(&mut extra_ocr, lines.join("\n"));
            }

            if let Some(ref exif) = rich.photo_exif {
                let cam = exif.camera_display_name().unwrap_or_default();
                let exp = exif.exposure_summary().unwrap_or_default();
                let parts: Vec<&str> = [
                    cam.as_str(),
                    exif.lens_model.as_deref().unwrap_or(""),
                    exp.as_str(),
                    exif.software.as_deref().unwrap_or(""),
                    exif.artist.as_deref().unwrap_or(""),
                ]
                .into_iter()
                .filter(|s| !s.is_empty())
                .collect();
                append_block(&mut extra_ocr, parts.join(" "));
            }

            if let Some(ref ai) = rich.ai_generation {
                let prompt_prefix: String = ai
                    .prompt
                    .as_deref()
                    .unwrap_or("")
                    .chars()
                    .take(2000)
                    .collect();
                let neg_prefix: String = ai
                    .negative_prompt
                    .as_deref()
                    .unwrap_or("")
                    .chars()
                    .take(600)
                    .collect();
                let loras_str = ai.loras.join(" ");
                let lines: Vec<&str> = [
                    ai.generator.as_deref().unwrap_or(""),
                    ai.model_name.as_deref().unwrap_or(""),
                    ai.sampler.as_deref().unwrap_or(""),
                    loras_str.as_str(),
                    prompt_prefix.as_str(),
                    neg_prefix.as_str(),
                ]
                .into_iter()
                .filter(|s| !s.is_empty())
                .collect();
                append_block(&mut extra_ocr, lines.join("\n"));
            }
        }

        [
            asset.title.clone(),
            asset.file_name.clone(),
            asset.notes.clone(),
            asset.tags.join(" "),
            extra_ocr,
            asset.ai_description.clone().unwrap_or_default(),
            asset.source_domain.clone().unwrap_or_default(),
        ]
    }

    pub fn asset(&self, id: Uuid) -> CoreResult<Option<AssetRecord>> {
        let conn = self.lock_conn()?;
        Self::asset_by_id_conn(&conn, id)
    }

    fn asset_by_id_conn(conn: &Connection, id: Uuid) -> CoreResult<Option<AssetRecord>> {
        let blob: Option<Vec<u8>> = conn
            .query_row(
                "SELECT payload FROM assets WHERE id=?1",
                params![format_swift_uuid(&id)],
                |r| r.get(0),
            )
            .optional()?;
        match blob {
            Some(bytes) => Ok(Some(serde_json::from_slice(&bytes)?)),
            None => Ok(None),
        }
    }

    pub fn asset_by_drive_id(&self, drive_id: &str) -> CoreResult<Option<AssetRecord>> {
        let conn = self.lock_conn()?;
        Self::asset_by_drive_id_conn(&conn, drive_id)
    }

    fn asset_by_drive_id_conn(
        conn: &Connection,
        drive_id: &str,
    ) -> CoreResult<Option<AssetRecord>> {
        let blob: Option<Vec<u8>> = conn
            .query_row(
                "SELECT payload FROM assets WHERE drive_id=?1",
                params![drive_id],
                |r| r.get(0),
            )
            .optional()?;
        match blob {
            Some(bytes) => Ok(Some(serde_json::from_slice(&bytes)?)),
            None => Ok(None),
        }
    }

    pub fn asset_drive_bindings(&self) -> CoreResult<Vec<(String, Uuid)>> {
        let conn = self.lock_conn()?;
        let mut stmt =
            conn.prepare("SELECT drive_id, id FROM assets WHERE drive_id IS NOT NULL")?;
        let rows = stmt.query_map([], |r| {
            let drive_id: String = r.get(0)?;
            let id_str: String = r.get(1)?;
            Ok((drive_id, id_str))
        })?;
        let mut out = Vec::new();
        for row in rows {
            let (drive_id, id_str) = row?;
            if let Ok(uuid) = Uuid::parse_str(&id_str) {
                out.push((drive_id, uuid));
            }
        }
        Ok(out)
    }

    pub fn assets_by_content_hash(&self, content_hash: &str) -> CoreResult<Vec<AssetRecord>> {
        let conn = self.lock_conn()?;
        let mut stmt = conn.prepare("SELECT payload FROM assets WHERE content_hash=?1")?;
        let rows = stmt.query_map(params![content_hash], |r| r.get::<_, Vec<u8>>(0))?;
        let mut out = Vec::new();
        for row in rows {
            let bytes = row?;
            out.push(serde_json::from_slice(&bytes)?);
        }
        Ok(out)
    }

    pub fn remove_asset(&self, id: Uuid) -> CoreResult<()> {
        let conn = self.lock_conn()?;
        Self::remove_asset_conn(&conn, id)
    }

    fn remove_asset_conn(conn: &Connection, id: Uuid) -> CoreResult<()> {
        let id_str = format_swift_uuid(&id);
        conn.execute(
            "DELETE FROM assets_fts WHERE rowid IN (SELECT rowid FROM assets WHERE id=?1)",
            params![id_str],
        )?;
        conn.execute("DELETE FROM assets WHERE id=?1", params![id_str])?;
        Ok(())
    }

    /// Updates `last_opened_at` locally without enqueuing a cloud sync op.
    pub fn mark_asset_opened(&self, id: Uuid) -> CoreResult<Option<AssetRecord>> {
        self.with_transaction(|conn| {
            let Some(mut asset) = Self::asset_by_id_conn(conn, id)? else {
                return Ok(None);
            };
            asset.last_opened_at = Some(Utc::now());
            Self::put_asset_conn(conn, &asset)?;
            Ok(Some(asset))
        })
    }

    pub fn fetch_assets(
        &self,
        criteria: &FilterCriteria,
        limit: Option<usize>,
    ) -> CoreResult<Vec<AssetRecord>> {
        let conn = self.lock_conn()?;
        Self::fetch_assets_conn(&conn, criteria, limit)
    }

    fn fetch_assets_conn(
        conn: &Connection,
        criteria: &FilterCriteria,
        limit: Option<usize>,
    ) -> CoreResult<Vec<AssetRecord>> {
        let rows = Self::query_assets_conn(conn, criteria, limit, "a.payload", |row| {
            let bytes: Vec<u8> = row.get(0)?;
            Ok(bytes)
        })?;
        let mut out = Vec::with_capacity(rows.len());
        for bytes in rows {
            out.push(serde_json::from_slice(&bytes)?);
        }
        Ok(out)
    }

    pub fn search_ranks(&self, query: &str) -> CoreResult<HashMap<Uuid, f64>> {
        if search_text::fts_query(query).is_empty() {
            return Ok(HashMap::new());
        }
        let conn = self.lock_conn()?;
        let criteria = FilterCriteria {
            search_query: query.to_string(),
            sort_by: SortOrder::Relevance,
            ..FilterCriteria::default()
        };
        let ids = Self::query_assets_conn(&conn, &criteria, None, "a.id", |row| {
            row.get::<_, String>(0)
        })?;
        let parsed: Vec<Uuid> = ids
            .into_iter()
            .filter_map(|s| Uuid::parse_str(&s).ok())
            .collect();
        let denom = (parsed.len() / 4).max(8) as f64;
        Ok(parsed
            .into_iter()
            .enumerate()
            .map(|(idx, id)| (id, 1.0 / (1.0 + (idx as f64) / denom)))
            .collect())
    }

    fn folder_subtree_ids_conn(conn: &Connection, root_id: Uuid) -> CoreResult<Vec<Uuid>> {
        let all = Self::fetch_folders_raw_conn(conn)?;
        let mut children_by_parent: HashMap<Uuid, Vec<Uuid>> = HashMap::new();
        for f in &all {
            if let Some(pid) = f.parent_id {
                children_by_parent.entry(pid).or_default().push(f.id);
            }
        }
        let mut result = vec![root_id];
        let mut seen: HashSet<Uuid> = [root_id].into_iter().collect();
        let mut queue = vec![root_id];
        while let Some(curr) = queue.pop() {
            if let Some(kids) = children_by_parent.get(&curr) {
                for &child_id in kids {
                    if seen.insert(child_id) {
                        result.push(child_id);
                        queue.push(child_id);
                    }
                }
            }
        }
        Ok(result)
    }

    fn query_assets_conn<T, F>(
        conn: &Connection,
        filters: &FilterCriteria,
        limit: Option<usize>,
        projection: &str,
        mut read: F,
    ) -> CoreResult<Vec<T>>
    where
        F: FnMut(&rusqlite::Row<'_>) -> rusqlite::Result<T>,
    {
        let mut clauses: Vec<String> = Vec::new();
        let mut args: Vec<SqlValue> = Vec::new();

        // Color filter uses numbered params ?1..=?4 first, so build it first if active.
        if let Some(ref hex) = filters.selected_color_hex {
            let color = LabColor::from_hex(hex, 1.0);
            let tolerance = filters.color_tolerance.max(0.0);
            clauses.push(
                "EXISTS (SELECT 1 FROM asset_colors c WHERE c.asset_id=a.id \
                 AND (c.l-?1)*(c.l-?1)+(c.a-?2)*(c.a-?2)+(c.b-?3)*(c.b-?3)<=?4)"
                    .to_string(),
            );
            args.push(SqlValue::Real(color.l));
            args.push(SqlValue::Real(color.a));
            args.push(SqlValue::Real(color.b));
            args.push(SqlValue::Real(tolerance * tolerance));
        }

        if filters.only_trashed {
            clauses.push("a.trashed=1".to_string());
        } else if !filters.include_trashed {
            clauses.push("a.trashed=0".to_string());
        }

        if filters.only_inbox {
            clauses.push("a.folder_id IS NULL AND a.trashed=0".to_string());
        }

        if let Some(folder_id) = filters.folder_id {
            if filters.include_subfolders {
                let subtree = Self::folder_subtree_ids_conn(conn, folder_id)?;
                let placeholders = vec!["?"; subtree.len()].join(",");
                clauses.push(format!("a.folder_id IN ({placeholders})"));
                for id in subtree {
                    args.push(SqlValue::Text(format_swift_uuid(&id)));
                }
            } else {
                clauses.push("a.folder_id=?".to_string());
                args.push(SqlValue::Text(format_swift_uuid(&folder_id)));
            }
        }

        if let Some(shape) = filters.shape {
            clauses.push("a.shape=?".to_string());
            args.push(SqlValue::Text(shape.raw_value().to_string()));
        }

        if filters.min_rating > 0 {
            clauses.push("a.rating>=?".to_string());
            args.push(SqlValue::Integer(i64::from(filters.min_rating)));
        }

        if filters.only_pinned_offline {
            clauses.push("a.pinned=1".to_string());
        }

        if let Some(days) = filters.only_recent_days {
            let cutoff =
                (Utc::now().timestamp_millis() as f64 / 1000.0) - (days.max(0) as f64) * 86_400.0;
            clauses.push("a.created>=?".to_string());
            args.push(SqlValue::Real(cutoff));
        }

        if !filters.kinds.is_empty() {
            let mut kinds: Vec<&str> = filters.kinds.iter().map(|k| k.raw_value()).collect();
            kinds.sort_unstable();
            let placeholders = vec!["?"; kinds.len()].join(",");
            clauses.push(format!("a.kind IN ({placeholders})"));
            for k in kinds {
                args.push(SqlValue::Text(k.to_string()));
            }
        }

        if filters.only_untagged {
            clauses.push("NOT EXISTS (SELECT 1 FROM asset_tags WHERE asset_id=a.id)".to_string());
        }

        for tag in &filters.tags {
            clauses.push(
                "EXISTS (SELECT 1 FROM asset_tags WHERE asset_id=a.id AND tag=?)".to_string(),
            );
            args.push(SqlValue::Text(tag.clone()));
        }

        let fts_q = search_text::fts_query(&filters.search_query);
        if !fts_q.is_empty() {
            clauses.push("assets_fts MATCH ?".to_string());
            args.push(SqlValue::Text(fts_q.clone()));
        }

        let source = if fts_q.is_empty() {
            "assets a"
        } else {
            "assets_fts JOIN assets a ON a.rowid=assets_fts.rowid"
        };

        let order = match filters.sort_by {
            SortOrder::Newest => "a.created DESC",
            SortOrder::Oldest => "a.created",
            SortOrder::NameAsc => "a.title COLLATE NOCASE",
            SortOrder::RatingDesc => "a.rating DESC, a.created DESC",
            SortOrder::FileSizeDesc => "a.size DESC, a.created DESC",
            SortOrder::Relevance => {
                if fts_q.is_empty() {
                    "a.created DESC"
                } else {
                    "bm25(assets_fts, 8, 3, 1, 5, 2, 2, 1, 3, 2), a.created DESC"
                }
            }
        };

        let filter_sql = if clauses.is_empty() {
            String::new()
        } else {
            format!(" WHERE {}", clauses.join(" AND "))
        };
        let limit_sql = limit.map(|n| format!(" LIMIT {n}")).unwrap_or_default();

        let sql = format!(
            "SELECT {projection} FROM {source}{filter_sql} ORDER BY {order}, a.id{limit_sql}"
        );
        let mut stmt = conn.prepare(&sql)?;
        let rows = stmt.query_map(rusqlite::params_from_iter(args.iter()), |row| read(row))?;
        let mut out = Vec::new();
        for item in rows {
            out.push(item?);
        }
        Ok(out)
    }

    // =========================================================================
    // Folders & Smart Folders
    // =========================================================================

    fn fetch_folders_raw_conn(conn: &Connection) -> CoreResult<Vec<FolderRecord>> {
        let mut stmt = conn.prepare("SELECT payload FROM folders")?;
        let rows = stmt.query_map([], |r| r.get::<_, Vec<u8>>(0))?;
        let mut out = Vec::new();
        for row in rows {
            let bytes = row?;
            out.push(serde_json::from_slice(&bytes)?);
        }
        Ok(out)
    }

    pub fn fetch_folders(&self) -> CoreResult<Vec<FolderRecord>> {
        let conn = self.lock_conn()?;
        Self::fetch_folders_conn(&conn)
    }

    fn fetch_folders_conn(conn: &Connection) -> CoreResult<Vec<FolderRecord>> {
        let mut stmt = conn.prepare(
            "SELECT payload, (SELECT COUNT(*) FROM assets WHERE folder_id=f.id AND trashed=0)
             FROM folders f",
        )?;
        let rows = stmt.query_map([], |r| {
            let bytes: Vec<u8> = r.get(0)?;
            let count: i32 = r.get(1)?;
            Ok((bytes, count))
        })?;
        let mut folders = Vec::new();
        for row in rows {
            let (bytes, count) = row?;
            let mut folder: FolderRecord = serde_json::from_slice(&bytes)?;
            folder.asset_count = count;
            folders.push(folder);
        }
        folders.sort_by(|a, b| {
            a.sort_order
                .cmp(&b.sort_order)
                .then_with(|| a.name.cmp(&b.name))
                .then_with(|| format_swift_uuid(&a.id).cmp(&format_swift_uuid(&b.id)))
        });
        Ok(folders)
    }

    pub fn folder(&self, id: Uuid) -> CoreResult<Option<FolderRecord>> {
        let conn = self.lock_conn()?;
        Self::folder_by_id_conn(&conn, id)
    }

    fn folder_by_id_conn(conn: &Connection, id: Uuid) -> CoreResult<Option<FolderRecord>> {
        let blob: Option<Vec<u8>> = conn
            .query_row(
                "SELECT payload FROM folders WHERE id=?1",
                params![format_swift_uuid(&id)],
                |r| r.get(0),
            )
            .optional()?;
        match blob {
            Some(bytes) => Ok(Some(serde_json::from_slice(&bytes)?)),
            None => Ok(None),
        }
    }

    pub fn upsert_folder(&self, folder: &FolderRecord) -> CoreResult<()> {
        let conn = self.lock_conn()?;
        Self::put_folder_conn(&conn, folder)
    }

    pub(crate) fn put_folder_conn(conn: &Connection, folder: &FolderRecord) -> CoreResult<()> {
        let id = format_swift_uuid(&folder.id);
        let payload = canonical_json_bytes(folder)?;
        conn.execute(
            "INSERT INTO folders VALUES (?1, ?2, ?3)
             ON CONFLICT(id) DO UPDATE SET drive_id=excluded.drive_id, payload=excluded.payload",
            params![id, folder.drive_folder_id, payload],
        )?;
        Ok(())
    }

    pub fn remove_folder(&self, id: Uuid) -> CoreResult<()> {
        let conn = self.lock_conn()?;
        Self::remove_folder_conn(&conn, id)
    }

    fn remove_folder_conn(conn: &Connection, id: Uuid) -> CoreResult<()> {
        conn.execute(
            "DELETE FROM folders WHERE id=?1",
            params![format_swift_uuid(&id)],
        )?;
        Ok(())
    }

    /// Moves `folder_id` under `new_parent_id` with cycle protection, sibling name deduplication,
    /// and deterministic `sort_order` reindexing.
    pub fn move_folder(
        &self,
        folder_id: Uuid,
        new_parent_id: Option<Uuid>,
        insert_at_index: Option<usize>,
    ) -> CoreResult<Vec<FolderRecord>> {
        self.with_transaction(|conn| {
            let Some(mut target) = Self::folder_by_id_conn(conn, folder_id)? else {
                return Err(CoreError::NotFound(format_swift_uuid(&folder_id)));
            };

            if let Some(pid) = new_parent_id {
                let subtree = Self::folder_subtree_ids_conn(conn, folder_id)?;
                if subtree.contains(&pid) {
                    return Err(CoreError::InvalidOperation(
                        "Cannot move a folder into itself or one of its descendants.".to_string(),
                    ));
                }
                if Self::folder_by_id_conn(conn, pid)?.is_none() {
                    return Err(CoreError::NotFound(format_swift_uuid(&pid)));
                }
            }

            let all = Self::fetch_folders_conn(conn)?;
            let mut siblings: Vec<FolderRecord> = all
                .into_iter()
                .filter(|f| f.parent_id == new_parent_id && f.id != folder_id)
                .collect();

            // Auto-deduplicate sibling name on collision
            let existing_names: HashSet<String> =
                siblings.iter().map(|f| f.name.to_lowercase()).collect();
            if existing_names.contains(&target.name.to_lowercase()) {
                let base = target.name.clone();
                let mut n = 2;
                loop {
                    let candidate = format!("{base} ({n})");
                    if !existing_names.contains(&candidate.to_lowercase()) {
                        target.name = candidate;
                        break;
                    }
                    n += 1;
                }
            }

            target.parent_id = new_parent_id;
            target.updated_at = Utc::now();

            let idx = insert_at_index
                .unwrap_or(siblings.len())
                .min(siblings.len());
            siblings.insert(idx, target);

            for (order, mut sib) in siblings.into_iter().enumerate() {
                sib.sort_order = order as i32;
                sib.updated_at = Utc::now();
                Self::record_conn(conn, SyncOperationChange::Folder(sib), true)?;
            }

            Self::fetch_folders_conn(conn)
        })
    }

    /// Deletes a folder. When `trash_contents == false`, moves direct assets to Inbox.
    /// When `trash_contents == true`, trashes all non-trashed assets in subtree and deletes subtree post-order.
    pub fn delete_folder(&self, id: Uuid, trash_contents: bool) -> CoreResult<()> {
        self.with_transaction(|conn| {
            let Some(root) = Self::folder_by_id_conn(conn, id)? else {
                return Ok(());
            };
            if !trash_contents {
                let direct_assets = Self::fetch_assets_conn(
                    conn,
                    &FilterCriteria {
                        folder_id: Some(id),
                        include_trashed: true,
                        ..FilterCriteria::default()
                    },
                    None,
                )?;
                for mut asset in direct_assets {
                    asset.folder_id = None;
                    Self::save_asset_locally_conn(conn, &asset, true)?;
                }
                Self::record_conn(
                    conn,
                    SyncOperationChange::DeleteFolder {
                        id,
                        drive_id: root.drive_folder_id,
                    },
                    true,
                )?;
                return Ok(());
            }

            let subtree_ids = Self::folder_subtree_ids_conn(conn, id)?;
            let assets_in_subtree = Self::fetch_assets_conn(
                conn,
                &FilterCriteria {
                    folder_id: Some(id),
                    include_subfolders: true,
                    include_trashed: false,
                    ..FilterCriteria::default()
                },
                None,
            )?;
            for mut asset in assets_in_subtree {
                asset.folder_id = None;
                asset.is_trashed = true;
                Self::save_asset_locally_conn(conn, &asset, true)?;
            }
            // Delete children before parent (reverse BFS order is valid post-order)
            for fid in subtree_ids.into_iter().rev() {
                let drive_id = Self::folder_by_id_conn(conn, fid)?.and_then(|f| f.drive_folder_id);
                Self::record_conn(
                    conn,
                    SyncOperationChange::DeleteFolder { id: fid, drive_id },
                    true,
                )?;
            }
            Ok(())
        })
    }

    pub fn fetch_smart_folders(&self) -> CoreResult<Vec<SmartFolderRecord>> {
        let mut folders: Vec<SmartFolderRecord> =
            self.state(SMART_FOLDERS_STATE_KEY)?.unwrap_or_default();
        folders.sort_by(|a, b| {
            a.sort_order
                .cmp(&b.sort_order)
                .then_with(|| a.name.cmp(&b.name))
        });
        Ok(folders)
    }

    pub fn save_smart_folder(
        &self,
        folder: SmartFolderRecord,
    ) -> CoreResult<Vec<SmartFolderRecord>> {
        let mut folders = self.fetch_smart_folders()?;
        if let Some(existing) = folders.iter_mut().find(|f| f.id == folder.id) {
            *existing = folder;
        } else {
            folders.push(folder);
        }
        folders.sort_by(|a, b| {
            a.sort_order
                .cmp(&b.sort_order)
                .then_with(|| a.name.cmp(&b.name))
        });
        self.set_state(SMART_FOLDERS_STATE_KEY, Some(&folders))?;
        Ok(folders)
    }

    pub fn delete_smart_folder(&self, id: Uuid) -> CoreResult<Vec<SmartFolderRecord>> {
        let mut folders = self.fetch_smart_folders()?;
        folders.retain(|f| f.id != id);
        self.set_state(SMART_FOLDERS_STATE_KEY, Some(&folders))?;
        Ok(folders)
    }

    // =========================================================================
    // Tags, Counts, Boards & Quick Jump
    // =========================================================================

    pub fn fetch_tag_counts(&self) -> CoreResult<Vec<TagCount>> {
        let conn = self.lock_conn()?;
        Self::fetch_tag_counts_conn(&conn)
    }

    fn fetch_tag_counts_conn(conn: &Connection) -> CoreResult<Vec<TagCount>> {
        let mut stmt = conn.prepare(
            "SELECT tag, COUNT(*) n FROM asset_tags t JOIN assets a ON t.asset_id=a.id
             WHERE a.trashed=0 GROUP BY tag ORDER BY n DESC, tag",
        )?;
        let rows = stmt.query_map([], |r| {
            Ok(TagCount {
                name: r.get(0)?,
                count: r.get(1)?,
            })
        })?;
        let mut out = Vec::new();
        for row in rows {
            out.push(row?);
        }
        Ok(out)
    }

    pub fn inbox_count(&self) -> CoreResult<usize> {
        let conn = self.lock_conn()?;
        let count: i64 = conn.query_row(
            "SELECT COUNT(*) FROM assets WHERE folder_id IS NULL AND trashed=0",
            [],
            |r| r.get(0),
        )?;
        Ok(count.max(0) as usize)
    }

    pub fn is_empty(&self) -> CoreResult<bool> {
        let conn = self.lock_conn()?;
        let exists: Option<i64> = conn
            .query_row(
                "SELECT 1 FROM assets UNION ALL SELECT 1 FROM boards UNION ALL SELECT 1 FROM folders LIMIT 1",
                [],
                |r| r.get(0),
            )
            .optional()?;
        Ok(exists.is_none())
    }

    pub fn fetch_boards(&self) -> CoreResult<Vec<MoodboardDocument>> {
        let conn = self.lock_conn()?;
        Self::fetch_boards_conn(&conn)
    }

    fn fetch_boards_conn(conn: &Connection) -> CoreResult<Vec<MoodboardDocument>> {
        let mut stmt = conn.prepare("SELECT payload FROM boards")?;
        let rows = stmt.query_map([], |r| r.get::<_, Vec<u8>>(0))?;
        let mut boards = Vec::new();
        for row in rows {
            let bytes = row?;
            boards.push(serde_json::from_slice::<MoodboardDocument>(&bytes)?);
        }
        boards.sort_by(|a, b| {
            b.updated_at
                .cmp(&a.updated_at)
                .then_with(|| format_swift_uuid(&b.id).cmp(&format_swift_uuid(&a.id)))
        });
        Ok(boards)
    }

    pub fn board(&self, id: Uuid) -> CoreResult<Option<MoodboardDocument>> {
        let conn = self.lock_conn()?;
        Self::board_by_id_conn(&conn, id)
    }

    fn board_by_id_conn(conn: &Connection, id: Uuid) -> CoreResult<Option<MoodboardDocument>> {
        let blob: Option<Vec<u8>> = conn
            .query_row(
                "SELECT payload FROM boards WHERE id=?1",
                params![format_swift_uuid(&id)],
                |r| r.get(0),
            )
            .optional()?;
        match blob {
            Some(bytes) => Ok(Some(serde_json::from_slice(&bytes)?)),
            None => Ok(None),
        }
    }

    pub fn upsert_board(&self, board: &MoodboardDocument) -> CoreResult<()> {
        self.with_transaction(|conn| Self::put_board_conn(conn, board))
    }

    pub(crate) fn put_board_conn(conn: &Connection, board: &MoodboardDocument) -> CoreResult<()> {
        let id = format_swift_uuid(&board.id);
        let payload = canonical_json_bytes(board)?;
        conn.execute(
            "INSERT INTO boards VALUES (?1, ?2, ?3)
             ON CONFLICT(id) DO UPDATE SET pinned=excluded.pinned, payload=excluded.payload",
            params![id, i32::from(board.pinned_offline), payload],
        )?;
        conn.execute("DELETE FROM board_assets WHERE board_id=?1", params![id])?;
        let unique_assets: HashSet<Uuid> = board.referenced_asset_ids().into_iter().collect();
        let mut stmt = conn.prepare_cached("INSERT INTO board_assets VALUES (?1, ?2)")?;
        for asset_id in unique_assets {
            stmt.execute(params![id, format_swift_uuid(&asset_id)])?;
        }
        Ok(())
    }

    pub fn remove_board(&self, id: Uuid) -> CoreResult<()> {
        let conn = self.lock_conn()?;
        Self::remove_board_conn(&conn, id)
    }

    fn remove_board_conn(conn: &Connection, id: Uuid) -> CoreResult<()> {
        conn.execute(
            "DELETE FROM boards WHERE id=?1",
            params![format_swift_uuid(&id)],
        )?;
        Ok(())
    }

    pub fn protected_asset_ids(&self) -> CoreResult<HashSet<Uuid>> {
        let conn = self.lock_conn()?;
        let mut stmt = conn.prepare(
            "SELECT id FROM assets WHERE pinned=1
             UNION SELECT asset_id FROM board_assets a JOIN boards b ON a.board_id=b.id WHERE b.pinned=1",
        )?;
        let rows = stmt.query_map([], |r| r.get::<_, String>(0))?;
        let mut out = HashSet::new();
        for row in rows {
            let s = row?;
            if let Ok(uuid) = Uuid::parse_str(&s) {
                out.insert(uuid);
            }
        }
        Ok(out)
    }

    pub fn quick_jump(&self, query: &str, limit: usize) -> CoreResult<Vec<QuickJumpMatch>> {
        if limit == 0 {
            return Ok(Vec::new());
        }
        let conn = self.lock_conn()?;
        let mut matches = Vec::new();

        let add = |matches: &mut Vec<QuickJumpMatch>,
                   title: String,
                   kind: QuickJumpKind,
                   subtitle: String,
                   uuid: Option<Uuid>,
                   tag: Option<String>| {
            if let Some(score) = search_text::fuzzy_score(query, &title) {
                let suffix = uuid
                    .map(|u| format_swift_uuid(&u))
                    .unwrap_or_else(|| title.clone());
                matches.push(QuickJumpMatch {
                    id: format!("{}-{suffix}", kind.raw_value()),
                    kind,
                    title,
                    subtitle,
                    target_uuid: uuid,
                    tag_name: tag,
                    score,
                });
            }
        };

        for board in Self::fetch_boards_conn(&conn)? {
            add(
                &mut matches,
                board.title.clone(),
                QuickJumpKind::Moodboard,
                format!("情绪板 · {} 项", board.nodes.len()),
                Some(board.id),
                None,
            );
        }
        for folder in Self::fetch_folders_conn(&conn)? {
            add(
                &mut matches,
                folder.name.clone(),
                QuickJumpKind::Folder,
                "文件夹".to_string(),
                Some(folder.id),
                None,
            );
        }
        for tag in Self::fetch_tag_counts_conn(&conn)? {
            add(
                &mut matches,
                tag.name.clone(),
                QuickJumpKind::Tag,
                format!("标签 · {} 项", tag.count),
                None,
                Some(tag.name.clone()),
            );
        }

        let filters = FilterCriteria {
            search_query: query.to_string(),
            sort_by: SortOrder::Relevance,
            ..FilterCriteria::default()
        };
        for item in Self::fetch_assets_conn(&conn, &filters, Some(limit.max(60)))? {
            let score = search_text::fuzzy_score(query, &item.title).unwrap_or(0.55);
            matches.push(QuickJumpMatch {
                id: format!("asset-{}", format_swift_uuid(&item.id)),
                kind: QuickJumpKind::Asset,
                title: item.title,
                subtitle: item.media_kind.localized_label().to_string(),
                target_uuid: Some(item.id),
                tag_name: None,
                score,
            });
        }

        matches.sort_by(|a, b| {
            b.score
                .partial_cmp(&a.score)
                .unwrap_or(std::cmp::Ordering::Equal)
                .then_with(|| a.title.cmp(&b.title))
                .then_with(|| a.id.cmp(&b.id))
        });
        matches.truncate(limit);
        Ok(matches)
    }

    // =========================================================================
    // Key-Value Sync State, Sync Ops Journal & Original Cache LRU Timestamps
    // =========================================================================

    pub fn state<T: DeserializeOwned>(&self, key: &str) -> CoreResult<Option<T>> {
        let conn = self.lock_conn()?;
        Self::state_conn(&conn, key)
    }

    fn state_conn<T: DeserializeOwned>(conn: &Connection, key: &str) -> CoreResult<Option<T>> {
        let blob: Option<Vec<u8>> = conn
            .query_row(
                "SELECT payload FROM sync_state WHERE key=?1",
                params![key],
                |r| r.get(0),
            )
            .optional()?;
        match blob {
            Some(bytes) => Ok(Some(serde_json::from_slice(&bytes)?)),
            None => Ok(None),
        }
    }

    pub fn states_with_prefix<T: DeserializeOwned>(
        &self,
        prefix: &str,
    ) -> CoreResult<Vec<(String, T)>> {
        let conn = self.lock_conn()?;
        Self::states_with_prefix_conn(&conn, prefix)
    }

    fn states_with_prefix_conn<T: DeserializeOwned>(
        conn: &Connection,
        prefix: &str,
    ) -> CoreResult<Vec<(String, T)>> {
        let mut stmt = conn
            .prepare("SELECT key, payload FROM sync_state WHERE substr(key, 1, length(?1)) = ?1")?;
        let rows = stmt.query_map(params![prefix], |r| {
            Ok((r.get::<_, String>(0)?, r.get::<_, Vec<u8>>(1)?))
        })?;
        let mut out = Vec::new();
        for row in rows {
            let (k, bytes) = row?;
            out.push((k, serde_json::from_slice(&bytes)?));
        }
        Ok(out)
    }

    pub fn set_state<T: Serialize>(&self, key: &str, value: Option<&T>) -> CoreResult<()> {
        let conn = self.lock_conn()?;
        Self::set_state_conn(&conn, key, value)
    }

    fn set_state_conn<T: Serialize>(
        conn: &Connection,
        key: &str,
        value: Option<&T>,
    ) -> CoreResult<()> {
        match value {
            Some(v) => {
                let bytes = canonical_json_bytes(v)?;
                conn.execute(
                    "INSERT OR REPLACE INTO sync_state VALUES (?1, ?2)",
                    params![key, bytes],
                )?;
            }
            None => {
                conn.execute("DELETE FROM sync_state WHERE key=?1", params![key])?;
            }
        }
        Ok(())
    }

    pub fn append_op<T: Serialize>(&self, op: &T) -> CoreResult<()> {
        let conn = self.lock_conn()?;
        Self::append_op_conn(&conn, op)
    }

    fn append_op_conn<T: Serialize>(conn: &Connection, op: &T) -> CoreResult<()> {
        let bytes = canonical_json_bytes(op)?;
        conn.execute("INSERT INTO sync_ops(payload) VALUES (?1)", params![bytes])?;
        Ok(())
    }

    pub fn pending_ops<T: DeserializeOwned>(&self, limit: usize) -> CoreResult<Vec<(i64, T)>> {
        let conn = self.lock_conn()?;
        let mut stmt = conn.prepare("SELECT seq, payload FROM sync_ops ORDER BY seq LIMIT ?1")?;
        let rows = stmt.query_map(params![limit as i64], |r| {
            Ok((r.get::<_, i64>(0)?, r.get::<_, Vec<u8>>(1)?))
        })?;
        let mut out = Vec::new();
        for row in rows {
            let (seq, bytes) = row?;
            out.push((seq, serde_json::from_slice(&bytes)?));
        }
        Ok(out)
    }

    pub fn acknowledge_ops(&self, through_seq: i64) -> CoreResult<()> {
        let conn = self.lock_conn()?;
        conn.execute("DELETE FROM sync_ops WHERE seq<=?1", params![through_seq])?;
        Ok(())
    }

    pub fn pending_op_count(&self) -> CoreResult<usize> {
        let conn = self.lock_conn()?;
        let count: i64 = conn.query_row("SELECT COUNT(*) FROM sync_ops", [], |r| r.get(0))?;
        Ok(count.max(0) as usize)
    }

    pub fn clear_migration_sync_state(&self) -> CoreResult<()> {
        let conn = self.lock_conn()?;
        Self::clear_migration_sync_state_conn(&conn)
    }

    fn clear_migration_sync_state_conn(conn: &Connection) -> CoreResult<()> {
        conn.execute("DELETE FROM sync_ops", [])?;
        conn.execute(
            "DELETE FROM sync_state
             WHERE key LIKE 'remote.%'
                OR key LIKE 'local.delete.%'
                OR key LIKE 'deleted.drive.%'
                OR key LIKE 'clock.%'
                OR key LIKE 'projection.%'",
            [],
        )?;
        Ok(())
    }

    pub fn touch_original(&self, id: Uuid, now: DateTime<Utc>) -> CoreResult<()> {
        let conn = self.lock_conn()?;
        let ts = now.timestamp_millis() as f64 / 1000.0;
        conn.execute(
            "INSERT OR REPLACE INTO original_cache VALUES (?1, ?2)",
            params![format_swift_uuid(&id), ts],
        )?;
        Ok(())
    }

    pub fn original_access_times(&self) -> CoreResult<HashMap<Uuid, DateTime<Utc>>> {
        let conn = self.lock_conn()?;
        let mut stmt = conn.prepare("SELECT asset_id, accessed_at FROM original_cache")?;
        let rows = stmt.query_map([], |r| Ok((r.get::<_, String>(0)?, r.get::<_, f64>(1)?)))?;
        let mut out = HashMap::new();
        for row in rows {
            let (id_str, ts) = row?;
            if let Ok(uuid) = Uuid::parse_str(&id_str) {
                let ms = (ts * 1000.0).round() as i64;
                if let Some(dt) = Utc.timestamp_millis_opt(ms).single() {
                    out.insert(uuid, dt);
                }
            }
        }
        Ok(out)
    }

    // =========================================================================
    // Asset Vectors (Feature Print + Float16/Float32 Cosine Search)
    // =========================================================================

    pub fn save_vector(&self, id: Uuid, vector: &AssetVector) -> CoreResult<()> {
        let conn = self.lock_conn()?;
        Self::save_vector_conn(&conn, id, vector)
    }

    fn save_vector_conn(conn: &Connection, id: Uuid, vector: &AssetVector) -> CoreResult<()> {
        let current = Self::vector_conn(conn, id)?;
        let feature = vector
            .feature_print
            .clone()
            .or_else(|| current.as_ref().and_then(|c| c.feature_print.clone()));
        let embedding = vector
            .embedding
            .clone()
            .or_else(|| current.as_ref().and_then(|c| c.embedding.clone()));
        let model = if vector.embedding.is_none() {
            current.as_ref().and_then(|c| c.embedding_model.clone())
        } else {
            vector.embedding_model.clone()
        };
        let precision = if vector.embedding.is_none() {
            current
                .as_ref()
                .map(|c| c.precision)
                .unwrap_or(EmbeddingPrecision::Float16)
        } else {
            vector.precision
        };
        let emb_blob = embedding.as_deref().map(|e| precision.encode(e));

        conn.execute(
            "INSERT OR REPLACE INTO asset_vectors VALUES (?1, ?2, ?3, ?4, ?5)",
            params![
                format_swift_uuid(&id),
                feature,
                emb_blob,
                precision.raw_value(),
                model,
            ],
        )?;
        Ok(())
    }

    pub fn vector(&self, id: Uuid) -> CoreResult<Option<AssetVector>> {
        let conn = self.lock_conn()?;
        Self::vector_conn(&conn, id)
    }

    fn vector_conn(conn: &Connection, id: Uuid) -> CoreResult<Option<AssetVector>> {
        conn.query_row(
            "SELECT feature_print, embedding, precision, embedding_model FROM asset_vectors WHERE asset_id=?1",
            params![format_swift_uuid(&id)],
            Self::read_vector_row,
        )
        .optional()
        .map_err(Into::into)
    }

    pub fn vectors(&self) -> CoreResult<HashMap<Uuid, AssetVector>> {
        let conn = self.lock_conn()?;
        Self::vectors_conn(&conn)
    }

    fn vectors_conn(conn: &Connection) -> CoreResult<HashMap<Uuid, AssetVector>> {
        let mut stmt = conn.prepare(
            "SELECT feature_print, embedding, precision, embedding_model, asset_id FROM asset_vectors",
        )?;
        let rows = stmt.query_map([], |r| {
            let vec = Self::read_vector_row(r)?;
            let id_str: String = r.get(4)?;
            Ok((id_str, vec))
        })?;
        let mut out = HashMap::new();
        for row in rows {
            let (id_str, vec) = row?;
            if let Ok(uuid) = Uuid::parse_str(&id_str) {
                out.insert(uuid, vec);
            }
        }
        Ok(out)
    }

    fn read_vector_row(row: &rusqlite::Row<'_>) -> rusqlite::Result<AssetVector> {
        let feature_print: Option<Vec<u8>> = row.get(0)?;
        let emb_blob: Option<Vec<u8>> = row.get(1)?;
        let precision_raw: Option<i32> = row.get(2)?;
        let model: Option<String> = row.get(3)?;
        let precision = EmbeddingPrecision::from_raw(precision_raw.unwrap_or(16));
        let embedding = emb_blob.as_deref().map(|b| precision.decode(b));
        let embedding_model = model.filter(|s| !s.is_empty());
        Ok(AssetVector {
            feature_print,
            embedding,
            embedding_model,
            precision,
        })
    }

    /// Returns top `limit` assets ranked by embedding cosine similarity above `min_score`.
    pub fn search_by_embedding(
        &self,
        query_embedding: &[f32],
        limit: usize,
        min_score: f32,
    ) -> CoreResult<Vec<(Uuid, f32)>> {
        let all = self.vectors()?;
        let mut scored: Vec<(Uuid, f32)> = all
            .into_iter()
            .filter_map(|(id, vec)| {
                let emb = vec.embedding.as_deref()?;
                let sim = cosine_similarity(query_embedding, emb)?;
                if sim >= min_score {
                    Some((id, sim))
                } else {
                    None
                }
            })
            .collect();
        scored.sort_by(|a, b| {
            b.1.partial_cmp(&a.1)
                .unwrap_or(std::cmp::Ordering::Equal)
                .then_with(|| format_swift_uuid(&a.0).cmp(&format_swift_uuid(&b.0)))
        });
        scored.truncate(limit);
        Ok(scored)
    }

    // =========================================================================
    // CRDT Sync Operations Engine (1:1 with SyncOperations.swift)
    // =========================================================================

    pub fn device_id(&self) -> CoreResult<String> {
        self.with_transaction(Self::device_id_conn)
    }

    fn device_id_conn(conn: &Connection) -> CoreResult<String> {
        if let Some(id) = Self::state_conn::<String>(conn, "deviceID")? {
            return Ok(id);
        }
        let id = Uuid::new_v4().simple().to_string();
        Self::set_state_conn(conn, "deviceID", Some(&id))?;
        Ok(id)
    }

    pub fn record(&self, change: SyncOperationChange, project_location: bool) -> CoreResult<()> {
        self.with_transaction(|conn| Self::record_conn(conn, change, project_location))
    }

    fn record_conn(
        conn: &Connection,
        change: SyncOperationChange,
        project_location: bool,
    ) -> CoreResult<()> {
        let previous: i64 = Self::state_conn(conn, "hlc")?.unwrap_or(0);
        let now = Utc::now().timestamp_millis() * 1_024;
        let stamp = SyncStamp {
            time: now.max(previous + 1),
            device: Self::device_id_conn(conn)?,
        };
        let op = SyncOperation {
            stamp,
            change,
            project_location: if project_location { None } else { Some(false) },
        };
        Self::apply_op_conn(conn, &op)?;
        Self::append_op_conn(conn, &op)?;
        Ok(())
    }

    pub fn save_asset_locally(
        &self,
        value: &AssetRecord,
        project_location: bool,
    ) -> CoreResult<AssetRecord> {
        self.with_transaction(|conn| Self::save_asset_locally_conn(conn, value, project_location))
    }

    fn save_asset_locally_conn(
        conn: &Connection,
        value: &AssetRecord,
        project_location: bool,
    ) -> CoreResult<AssetRecord> {
        if Self::is_tombstoned_conn(conn, "asset", value.id)? {
            return Err(CoreError::NotFound(format_swift_uuid(&value.id)));
        }
        let existing = Self::asset_by_id_conn(conn, value.id)?;
        let mut asset = value.clone();
        let mut prior = existing;
        // Mounted filesystem IDs are local view identifiers and must not propagate remotely.
        if asset
            .drive_file_id
            .as_deref()
            .is_some_and(|s| s.starts_with("mounted-"))
        {
            asset.drive_file_id = prior.as_ref().and_then(|p| p.drive_file_id.clone());
        }
        if prior
            .as_ref()
            .and_then(|p| p.drive_file_id.as_deref())
            .is_some_and(|s| s.starts_with("mounted-"))
        {
            if let Some(ref mut p) = prior {
                p.drive_file_id = None;
            }
            if asset
                .drive_file_id
                .as_deref()
                .is_some_and(|s| s.starts_with("mounted-"))
            {
                asset.drive_file_id = None;
            }
        }

        let delta = AssetChanges::diff(&asset, prior.as_ref())?;
        if !delta.is_empty() {
            Self::record_conn(conn, SyncOperationChange::Asset(delta), project_location)?;
        }
        let mut saved = Self::asset_by_id_conn(conn, value.id)?.unwrap_or_else(|| value.clone());
        saved.is_local_original_cached = value.is_local_original_cached;
        saved.drive_file_id = value.drive_file_id.clone();
        Self::put_asset_conn(conn, &saved)?;
        Ok(saved)
    }

    pub fn save_board_locally(&self, board: &MoodboardDocument) -> CoreResult<MoodboardDocument> {
        self.with_transaction(|conn| {
            if Self::is_tombstoned_conn(conn, "board", board.id)? {
                return Err(CoreError::NotFound(format_swift_uuid(&board.id)));
            }
            let existing = Self::board_by_id_conn(conn, board.id)?;
            let delta = BoardChanges::diff(board, existing.as_ref())?;
            if !delta.is_empty() {
                Self::record_conn(conn, SyncOperationChange::Board(delta), true)?;
            }
            Ok(Self::board_by_id_conn(conn, board.id)?.unwrap_or_else(|| board.clone()))
        })
    }

    /// Rebuilds the sync operation queue cleanly from authoritative local library state when
    /// migrating between storage backends (Local Folder <-> Google Drive <-> WebDAV).
    pub fn requeue_library_for_backend_migration(
        &self,
        sync_thumbnails: bool,
        sync_embeddings: bool,
    ) -> CoreResult<MigrationRequeueCounts> {
        self.with_transaction(|conn| {
            Self::clear_migration_sync_state_conn(conn)?;

            // Topological parent-before-child folder order
            let existing_folders = Self::fetch_folders_conn(conn)?;
            let folder_by_id: HashMap<Uuid, FolderRecord> =
                existing_folders.iter().map(|f| (f.id, f.clone())).collect();
            let mut ordered_folders = Vec::new();
            let mut visited = HashSet::new();

            fn visit(
                f: &FolderRecord,
                by_id: &HashMap<Uuid, FolderRecord>,
                visited: &mut HashSet<Uuid>,
                out: &mut Vec<FolderRecord>,
            ) {
                if !visited.insert(f.id) {
                    return;
                }
                if let Some(pid) = f.parent_id {
                    if let Some(parent) = by_id.get(&pid) {
                        visit(parent, by_id, visited, out);
                    }
                }
                out.push(f.clone());
            }

            for f in &existing_folders {
                visit(f, &folder_by_id, &mut visited, &mut ordered_folders);
            }

            for mut folder in ordered_folders.clone() {
                folder.drive_folder_id = None;
                Self::put_folder_conn(conn, &folder)?;
                Self::record_conn(conn, SyncOperationChange::Folder(folder), true)?;
            }

            let all_assets = Self::fetch_assets_conn(
                conn,
                &FilterCriteria {
                    include_trashed: false,
                    ..FilterCriteria::default()
                },
                None,
            )?;
            let all_vectors = Self::vectors_conn(conn)?;

            for mut asset in all_assets.clone() {
                asset.drive_file_id = None;
                Self::put_asset_conn(conn, &asset)?;
                let delta = AssetChanges::diff(&asset, None)?;
                if !delta.is_empty() {
                    Self::record_conn(conn, SyncOperationChange::Asset(delta), true)?;
                }
                if sync_thumbnails {
                    Self::mark_projection_conn(conn, "thumbnails", asset.id)?;
                }
                if sync_embeddings {
                    if let Some(vector) = all_vectors.get(&asset.id) {
                        Self::record_conn(
                            conn,
                            SyncOperationChange::Vector {
                                id: asset.id,
                                vector: vector.clone(),
                            },
                            true,
                        )?;
                    }
                }
            }

            let all_boards = Self::fetch_boards_conn(conn)?;
            for board in &all_boards {
                let delta = BoardChanges::diff(board, None)?;
                if !delta.is_empty() {
                    Self::record_conn(conn, SyncOperationChange::Board(delta), true)?;
                }
                Self::mark_projection_conn(conn, "boards", board.id)?;
            }

            Ok(MigrationRequeueCounts {
                assets: all_assets.len(),
                folders: ordered_folders.len(),
                boards: all_boards.len(),
            })
        })
    }

    pub fn apply_op(&self, op: &SyncOperation) -> CoreResult<()> {
        self.with_transaction(|conn| Self::apply_op_conn(conn, op))
    }

    /// Applies an entire pulled operation shard and persists updated device cursors atomically.
    pub fn apply_op_shard<T: Serialize>(
        &self,
        ops_to_apply: &[SyncOperation],
        deferred_disabled_vectors: &[(String, SyncOperation)],
        cursor_state_key: &str,
        cursors: &T,
    ) -> CoreResult<()> {
        self.with_transaction(|conn| {
            for op in ops_to_apply {
                Self::apply_op_conn(conn, op)?;
            }
            for (key, op) in deferred_disabled_vectors {
                Self::set_state_conn(conn, key, Some(op))?;
            }
            Self::set_state_conn(conn, cursor_state_key, Some(cursors))?;
            Ok(())
        })
    }

    /// Applies any previously deferred `disabled.vector.*` operations once `sync_embeddings` is enabled.
    pub fn replay_disabled_vectors(&self) -> CoreResult<usize> {
        self.with_transaction(|conn| {
            let items = Self::states_with_prefix_conn::<SyncOperation>(conn, "disabled.vector.")?;
            let count = items.len();
            for (key, op) in items {
                Self::apply_op_conn(conn, &op)?;
                Self::set_state_conn::<SyncOperation>(conn, &key, None)?;
            }
            Ok(count)
        })
    }

    /// Atomically clears multiple projection versions (boards / thumbnails / embeddings).
    pub fn clear_projections(&self, name: &str, pairs: &[(String, String)]) -> CoreResult<()> {
        if pairs.is_empty() {
            return Ok(());
        }
        self.with_transaction(|conn| {
            let key = format!("projection.{name}");
            let mut dirty: BTreeMap<String, String> =
                Self::state_conn(conn, &key)?.unwrap_or_default();
            for (id, version) in pairs {
                if dirty.get(id).map(String::as_str) == Some(version.as_str()) {
                    dirty.remove(id);
                }
            }
            Self::set_state_conn(conn, &key, Some(&dirty))
        })
    }

    fn apply_op_conn(conn: &Connection, op: &SyncOperation) -> CoreResult<()> {
        let stamp = &op.stamp;
        if stamp.time <= 0 || stamp.time >= i64::MAX - 1 {
            return Err(CoreError::InvalidPayload("Invalid sync clock.".to_string()));
        }
        let observed: i64 = Self::state_conn(conn, "hlc")?.unwrap_or(0);
        if observed < stamp.time {
            Self::set_state_conn(conn, "hlc", Some(&stamp.time))?;
        }
        let date = Utc
            .timestamp_millis_opt(stamp.time / 1_024)
            .single()
            .unwrap_or_else(Utc::now);

        match &op.change {
            SyncOperationChange::Asset(delta) => {
                let id_str = format_swift_uuid(&delta.id);
                let key = format!("clock.asset.{id_str}");
                let mut clocks: SyncClocks = Self::state_conn(conn, &key)?.unwrap_or_default();
                if clocks.deleted() {
                    return Ok(());
                }
                let current = Self::asset_by_id_conn(conn, delta.id)?.unwrap_or_else(|| {
                    let mut blank = AssetRecord::new("", "");
                    blank.id = delta.id;
                    blank.is_local_original_cached = false;
                    blank.created_at = date;
                    blank.updated_at = date;
                    blank
                });
                let excluded: Vec<&str> = if current
                    .drive_file_id
                    .as_deref()
                    .is_some_and(|s| s.starts_with("mounted-"))
                {
                    let mut v = AssetChanges::EXCLUDED.to_vec();
                    v.push("driveFileID");
                    v
                } else {
                    AssetChanges::EXCLUDED.to_vec()
                };

                let mut merged =
                    SyncFields::merge(&delta.fields, &current, &excluded, stamp, &mut clocks)?;

                let mut tags = tag_map(&current.tags);
                for tag in &delta.tags_removed {
                    let normalized = search_text::normalize(tag);
                    let clock_key = format!("tag:{normalized}");
                    if !normalized.is_empty() && clocks.accept(stamp, &clock_key) {
                        tags.remove(&normalized);
                    }
                }
                for tag in &delta.tags_added {
                    let normalized = search_text::normalize(tag);
                    let clock_key = format!("tag:{normalized}");
                    if !normalized.is_empty() && clocks.accept(stamp, &clock_key) {
                        tags.insert(normalized, tag.trim().to_string());
                    }
                }
                let mut tag_values: Vec<String> = tags.into_values().collect();
                tag_values.sort();
                merged.tags = tag_values;

                if current.updated_hlc <= stamp.time {
                    merged.updated_hlc = stamp.time;
                    merged.updated_at = date;
                }

                if let Some(ref drive_id) = merged.drive_file_id.clone() {
                    if let Some(duplicate) = Self::asset_by_drive_id_conn(conn, drive_id)? {
                        if duplicate.id != delta.id {
                            if duplicate.id == stable_uuid(&format!("asset:{drive_id}")) {
                                Self::remap_discovered_asset_conn(conn, &duplicate, delta.id)?;
                            } else {
                                merged.drive_file_id = current.drive_file_id.clone();
                            }
                        }
                    }
                }

                Self::put_asset_conn(conn, &merged)?;
                Self::set_state_conn(conn, &key, Some(&clocks))?;

                // Replay any deferred vectors that arrived before the asset record
                let deferred_key = format!("deferred.vector.{id_str}");
                if let Some(ops) = Self::state_conn::<Vec<SyncOperation>>(conn, &deferred_key)? {
                    for deferred in ops {
                        Self::apply_op_conn(conn, &deferred)?;
                    }
                    Self::set_state_conn::<Vec<SyncOperation>>(conn, &deferred_key, None)?;
                }
            }
            SyncOperationChange::Board(delta) => {
                let id_str = format_swift_uuid(&delta.id);
                let key = format!("clock.board.{id_str}");
                let mut clocks: SyncClocks = Self::state_conn(conn, &key)?.unwrap_or_default();
                if clocks.deleted() {
                    return Ok(());
                }
                let current = Self::board_by_id_conn(conn, delta.id)?.unwrap_or_else(|| {
                    let mut blank = MoodboardDocument::new("");
                    blank.id = delta.id;
                    blank.created_at = date;
                    blank.updated_at = date;
                    blank
                });

                let mut merged = SyncFields::merge(
                    &delta.fields,
                    &current,
                    BoardChanges::EXCLUDED,
                    stamp,
                    &mut clocks,
                )?;
                merged.nodes = delta
                    .nodes
                    .apply(&current.nodes, "node:", stamp, &mut clocks);
                merged.nodes.sort_by(|a, b| {
                    a.editorial_order
                        .cmp(&b.editorial_order)
                        .then_with(|| a.z_index.cmp(&b.z_index))
                        .then_with(|| format_swift_uuid(&a.id).cmp(&format_swift_uuid(&b.id)))
                });
                merged.connectors =
                    delta
                        .connectors
                        .apply(&current.connectors, "connector:", stamp, &mut clocks);
                merged.ink_strokes =
                    delta
                        .strokes
                        .apply(&current.ink_strokes, "stroke:", stamp, &mut clocks);
                merged.ink_strokes.sort_by(|a, b| {
                    a.z_index
                        .cmp(&b.z_index)
                        .then_with(|| a.created_at.cmp(&b.created_at))
                        .then_with(|| format_swift_uuid(&a.id).cmp(&format_swift_uuid(&b.id)))
                });

                if current.updated_hlc <= stamp.time {
                    merged.updated_hlc = stamp.time;
                    merged.updated_at = date;
                }
                merged = Self::resolving_asset_aliases_conn(conn, merged)?;
                Self::put_board_conn(conn, &merged)?;
                Self::set_state_conn(conn, &key, Some(&clocks))?;
                Self::mark_projection_conn(conn, "boards", delta.id)?;
            }
            SyncOperationChange::Folder(incoming) => {
                let mut folder = incoming.clone();
                let id_str = format_swift_uuid(&folder.id);
                let key = format!("clock.folder.{id_str}");
                let mut clocks: SyncClocks = Self::state_conn(conn, &key)?.unwrap_or_default();
                if clocks.deleted() || !clocks.accept(stamp, "value") {
                    return Ok(());
                }
                let current = Self::folder_by_id_conn(conn, folder.id)?;
                if folder
                    .drive_folder_id
                    .as_deref()
                    .is_some_and(|s| s.starts_with("mounted-"))
                    || folder.drive_folder_id.is_none()
                {
                    folder.drive_folder_id = current.and_then(|c| c.drive_folder_id);
                }
                folder.asset_count = 0;
                Self::put_folder_conn(conn, &folder)?;
                Self::set_state_conn(conn, &key, Some(&clocks))?;
            }
            SyncOperationChange::DeleteAsset { id, drive_id } => {
                let existing = Self::asset_by_id_conn(conn, *id)?;
                let known_id = existing
                    .as_ref()
                    .and_then(|a| a.drive_file_id.clone())
                    .or_else(|| drive_id.clone());
                if let Some(ref did) = known_id {
                    Self::set_state_conn(conn, &format!("deleted.drive.{did}"), Some(&true))?;
                }
                if let Some(ref ex) = existing {
                    if !ex.content_hash.is_empty() {
                        let fp = DeletedAssetFingerprint {
                            asset_id: *id,
                            sha256: ex.content_hash.clone(),
                            md5: None,
                            file_name: ex.file_name.clone(),
                            deleted_at: Utc::now(),
                        };
                        Self::set_state_conn(
                            conn,
                            &format!("deleted.content.{}", ex.content_hash),
                            Some(&fp),
                        )?;
                    }
                }
                Self::tombstone_conn(conn, "asset", *id, stamp)?;
                Self::remove_asset_conn(conn, *id)?;
                let id_str = format_swift_uuid(id);
                Self::set_state_conn(conn, &format!("media.cleanup.{id_str}"), Some(&true))?;
                Self::set_state_conn::<Vec<SyncOperation>>(
                    conn,
                    &format!("deferred.vector.{id_str}"),
                    None,
                )?;
                Self::mark_projection_conn(conn, "thumbnails", *id)?;
                Self::mark_projection_conn(conn, "embeddings", *id)?;
            }
            SyncOperationChange::DeleteBoard(id) => {
                Self::tombstone_conn(conn, "board", *id, stamp)?;
                Self::remove_board_conn(conn, *id)?;
                Self::mark_projection_conn(conn, "boards", *id)?;
            }
            SyncOperationChange::DeleteFolder { id, .. } => {
                Self::tombstone_conn(conn, "folder", *id, stamp)?;
                Self::remove_folder_conn(conn, *id)?;
            }
            SyncOperationChange::Vector { id, vector } => {
                let id_str = format_swift_uuid(id);
                let key = format!("clock.vector.{id_str}");
                let mut clocks: SyncClocks = Self::state_conn(conn, &key)?.unwrap_or_default();
                if Self::asset_by_id_conn(conn, *id)?.is_none() {
                    if !Self::is_tombstoned_conn(conn, "asset", *id)? {
                        Self::store_deferred_vector_conn(conn, vector, *id, stamp)?;
                    }
                    return Ok(());
                }
                let feature = vector
                    .feature_print
                    .as_ref()
                    .and_then(|fp| clocks.accept(stamp, "feature").then(|| fp.clone()));
                let embedding = vector
                    .embedding
                    .as_ref()
                    .and_then(|emb| clocks.accept(stamp, "embedding").then(|| emb.clone()));
                if feature.is_some() || embedding.is_some() {
                    let merged_vec = AssetVector {
                        feature_print: feature,
                        embedding,
                        embedding_model: vector.embedding_model.clone(),
                        precision: vector.precision,
                    };
                    Self::save_vector_conn(conn, *id, &merged_vec)?;
                    Self::set_state_conn(conn, &key, Some(&clocks))?;
                    Self::mark_projection_conn(conn, "embeddings", *id)?;
                }
            }
        }

        Ok(())
    }

    fn store_deferred_vector_conn(
        conn: &Connection,
        vector: &AssetVector,
        id: Uuid,
        stamp: &SyncStamp,
    ) -> CoreResult<()> {
        let key = format!("deferred.vector.{}", format_swift_uuid(&id));
        let mut pending: Vec<SyncOperation> = Self::state_conn(conn, &key)?.unwrap_or_default();
        pending.retain(|op| {
            if &op.stamp > stamp {
                return true;
            }
            if let SyncOperationChange::Vector { vector: prior, .. } = &op.change {
                let emb_covered = prior.embedding.is_none() || vector.embedding.is_some();
                let fp_covered = prior.feature_print.is_none() || vector.feature_print.is_some();
                !(emb_covered && fp_covered)
            } else {
                true
            }
        });
        pending.push(SyncOperation {
            stamp: stamp.clone(),
            change: SyncOperationChange::Vector {
                id,
                vector: vector.clone(),
            },
            project_location: None,
        });
        Self::set_state_conn(conn, &key, Some(&pending))
    }

    pub fn mark_projection(&self, name: &str, id: Uuid) -> CoreResult<()> {
        let conn = self.lock_conn()?;
        Self::mark_projection_conn(&conn, name, id)
    }

    fn mark_projection_conn(conn: &Connection, name: &str, id: Uuid) -> CoreResult<()> {
        let key = format!("projection.{name}");
        let mut dirty: BTreeMap<String, String> = Self::state_conn(conn, &key)?.unwrap_or_default();
        dirty.insert(format_swift_uuid(&id), format_swift_uuid(&Uuid::new_v4()));
        Self::set_state_conn(conn, &key, Some(&dirty))
    }

    pub fn clear_projection(&self, name: &str, id: &str, if_version: &str) -> CoreResult<()> {
        let conn = self.lock_conn()?;
        let key = format!("projection.{name}");
        let mut dirty: BTreeMap<String, String> =
            Self::state_conn(&conn, &key)?.unwrap_or_default();
        if dirty.get(id).map(String::as_str) == Some(if_version) {
            dirty.remove(id);
            Self::set_state_conn(&conn, &key, Some(&dirty))?;
        }
        Ok(())
    }

    pub fn is_tombstoned(&self, entity: &str, id: Uuid) -> CoreResult<bool> {
        let conn = self.lock_conn()?;
        Self::is_tombstoned_conn(&conn, entity, id)
    }

    fn is_tombstoned_conn(conn: &Connection, entity: &str, id: Uuid) -> CoreResult<bool> {
        let key = format!("clock.{entity}.{}", format_swift_uuid(&id));
        Ok(Self::state_conn::<SyncClocks>(conn, &key)?.is_some_and(|c| c.deleted()))
    }

    fn tombstone_conn(
        conn: &Connection,
        entity: &str,
        id: Uuid,
        stamp: &SyncStamp,
    ) -> CoreResult<()> {
        let key = format!("clock.{entity}.{}", format_swift_uuid(&id));
        let mut clocks: SyncClocks = Self::state_conn(conn, &key)?.unwrap_or_default();
        if clocks.accept(stamp, "deleted") {
            Self::set_state_conn(conn, &key, Some(&clocks))?;
        }
        Ok(())
    }

    fn remap_discovered_asset_conn(
        conn: &Connection,
        asset: &AssetRecord,
        canonical_id: Uuid,
    ) -> CoreResult<()> {
        let old_str = format_swift_uuid(&asset.id);
        let canonical_str = format_swift_uuid(&canonical_id);
        Self::set_state_conn(
            conn,
            &format!("alias.asset.{old_str}"),
            Some(&canonical_str),
        )?;

        for board in Self::fetch_boards_conn(conn)? {
            let refs = board.referenced_asset_ids();
            if refs.contains(&asset.id) || board.candidate_asset_ids.contains(&asset.id) {
                let updated = Self::resolving_asset_aliases_conn(conn, board)?;
                Self::put_board_conn(conn, &updated)?;
                Self::mark_projection_conn(conn, "boards", updated.id)?;
            }
        }
        Self::remove_asset_conn(conn, asset.id)?;
        Self::set_state_conn(conn, &format!("media.cleanup.{old_str}"), Some(&true))?;
        Ok(())
    }

    fn resolving_asset_aliases_conn(
        conn: &Connection,
        mut board: MoodboardDocument,
    ) -> CoreResult<MoodboardDocument> {
        for node in &mut board.nodes {
            if let BoardNodeKind::AssetRef { asset_id, .. } = &mut node.kind {
                let key = format!("alias.asset.{}", format_swift_uuid(asset_id));
                if let Some(canonical_str) = Self::state_conn::<String>(conn, &key)? {
                    if let Ok(canonical) = Uuid::parse_str(&canonical_str) {
                        *asset_id = canonical;
                    }
                }
            }
        }
        for cid in &mut board.candidate_asset_ids {
            let key = format!("alias.asset.{}", format_swift_uuid(cid));
            if let Some(canonical_str) = Self::state_conn::<String>(conn, &key)? {
                if let Ok(canonical) = Uuid::parse_str(&canonical_str) {
                    *cid = canonical;
                }
            }
        }
        Ok(board)
    }

    /// Returns all asset IDs queued for media cleanup and clears their `media.cleanup.*` markers.
    pub fn drain_media_cleanup_ids(&self) -> CoreResult<HashSet<Uuid>> {
        self.with_transaction(|conn| {
            let entries = Self::states_with_prefix_conn::<bool>(conn, "media.cleanup.")?;
            let mut ids = HashSet::new();
            for (key, _) in entries {
                if let Some(suffix) = key.strip_prefix("media.cleanup.") {
                    if let Ok(uuid) = Uuid::parse_str(suffix) {
                        ids.insert(uuid);
                    }
                }
                Self::set_state_conn::<bool>(conn, &key, None)?;
            }
            Ok(ids)
        })
    }
}
