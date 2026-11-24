//! Bidirectional `/.charkle/` CRDT sync engine and lossless two-way `StorageMigration`.
//!
//! Mirrors `Sources/CharkleCore/Sync/DriveSyncEngine.swift` and
//! `LiveCharkleEngine.migrateLibraryStorage` with full macOS / Web wire compatibility.

use std::collections::{BTreeMap, HashMap, HashSet};
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Instant;

use chrono::{DateTime, Utc};
use md5::{Digest, Md5};
use serde::{Deserialize, Serialize};
use tokio::sync::{Mutex, RwLock};
use uuid::Uuid;

use crate::db::{stable_uuid, LibraryDatabase};
use crate::error::{CoreError, CoreResult};
use crate::media::MediaPipeline;
use crate::models::core::{AssetRecord, FilterCriteria, FolderRecord, MediaKind};
use crate::models::media::ThumbnailTier;
use crate::models::sync::{
    DeletedAssetFingerprint, DriveAccountInfo, DriveSyncConfig, DriveTransportMode,
    RemoteDriveFile, StorageMigrationReport, SyncLogLine, SyncManifest, SyncOperation,
    SyncOperationChange, SyncPhase, SyncReport, SyncStatus,
};
use crate::sync::local_folder::MOUNTED_PATH_ID_PREFIX;
use crate::sync::transport::{validate_drive_name, DriveTransport, DRIVE_ROOT_ID};
use crate::wire::swift_codec::{
    canonical_json_bytes, decode_ops_jsonl, format_ops_shard_file_name, format_swift_uuid,
    parse_ops_shard_file_name,
};

const NON_EXPORTABLE_GOOGLE_MIMES: &[&str] = &[
    "application/vnd.google-apps.shortcut",
    "application/vnd.google-apps.form",
    "application/vnd.google-apps.site",
    "application/vnd.google-apps.map",
    "application/vnd.google-apps.script",
    "application/vnd.google-apps.jam",
    "application/vnd.google-apps.fusiontable",
    "application/vnd.google-apps.drive-sdk",
];

const IGNORED_JUNK_NAMES: &[&str] = &["thumbs.db", "desktop.ini", "icon\r"];
const IGNORED_TEMP_EXTENSIONS: &[&str] = &["crdownload", "part", "download", "tmp", "partial"];
const BINARY_MEDIA_EXTENSIONS: &[&str] = &[
    "png", "jpg", "jpeg", "webp", "gif", "heic", "heif", "avif", "tif", "tiff", "bmp", "mp4",
    "mov", "m4v", "webm", "mkv", "avi", "mp3", "m4a", "wav", "flac", "aac", "ogg", "pdf", "psd",
    "psb", "ai", "eps", "fig", "sketch", "xd", "blend", "zip",
];

#[derive(Debug, Clone)]
struct Layout {
    root: String,
    inbox: String,
    metadata: String,
    ops: String,
    boards: String,
    embeddings: String,
    thumbnails: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct SavedInventory {
    files: BTreeMap<String, RemoteDriveFile>,
    start_page_token: String,
}

#[derive(Debug, Clone)]
struct Inventory {
    files: BTreeMap<String, RemoteDriveFile>,
    start_page_token: String,
}

#[derive(Debug, Clone)]
struct InventoryUpdate {
    previous: BTreeMap<String, RemoteDriveFile>,
    current: SavedInventory,
    ordered_folders: Vec<RemoteDriveFile>,
}

struct ReconcileOutcome {
    discovered: usize,
    discovered_ids: Vec<Uuid>,
    renames: usize,
    deferred_file_ids: HashSet<String>,
    removed_file_ids: HashSet<String>,
}

type StatusCallback = Arc<dyn Fn(SyncStatus) + Send + Sync>;

/// Asynchronous bidirectional `/.charkle/` sync engine.
pub struct DriveSyncEngine {
    db: Arc<LibraryDatabase>,
    media: MediaPipeline,
    status: Arc<RwLock<SyncStatus>>,
    run_guard: Arc<Mutex<()>>,
    on_status: Option<StatusCallback>,
}

impl DriveSyncEngine {
    pub fn new(db: Arc<LibraryDatabase>, media: MediaPipeline) -> Self {
        Self {
            db,
            media,
            status: Arc::new(RwLock::new(SyncStatus::default())),
            run_guard: Arc::new(Mutex::new(())),
            on_status: None,
        }
    }

    pub fn with_status_callback(
        db: Arc<LibraryDatabase>,
        media: MediaPipeline,
        on_status: StatusCallback,
    ) -> Self {
        Self {
            db,
            media,
            status: Arc::new(RwLock::new(SyncStatus::default())),
            run_guard: Arc::new(Mutex::new(())),
            on_status: Some(on_status),
        }
    }

    pub async fn status(&self) -> SyncStatus {
        let mut s = self.status.read().await.clone();
        if let Ok(pending) = self.db.pending_op_count() {
            s.pending_op_count = pending;
        }
        s
    }

    pub async fn restore_status(&self, persisted: SyncStatus) {
        if self.run_guard.try_lock().is_ok() {
            let mut guard = self.status.write().await;
            *guard = persisted;
        }
    }

    pub async fn update_signed_in_account(
        &self,
        account: Option<DriveAccountInfo>,
        active_mode: DriveTransportMode,
    ) {
        let snapshot = {
            let mut s = self.status.write().await;
            s.account = account.clone();
            s.active_mode = active_mode;
            if account.is_some() {
                s.last_error = None;
                if matches!(s.phase, SyncPhase::Error(_)) {
                    s.phase = SyncPhase::Idle;
                }
            } else {
                s.last_synced_at = None;
                s.phase = SyncPhase::Idle;
            }
            s.clone()
        };
        let _ = self.db.set_state("lastSyncStatus", Some(&snapshot));
        self.broadcast(&snapshot);
    }

    async fn update_progress(
        &self,
        phase: Option<SyncPhase>,
        detail: Option<String>,
        progress: Option<f64>,
    ) {
        let snapshot = {
            let mut s = self.status.write().await;
            if let Some(p) = phase {
                s.phase = p;
            }
            s.current_detail = detail;
            s.progress_fraction = progress.map(|v| v.clamp(0.0, 1.0));
            s.clone()
        };
        self.broadcast(&snapshot);
    }

    fn broadcast(&self, status: &SyncStatus) {
        if let Some(ref cb) = self.on_status {
            cb(status.clone());
        }
    }

    /// Executes one complete bidirectional sync cycle against `transport`.
    pub async fn sync(
        &self,
        transport: &dyn DriveTransport,
        config: &DriveSyncConfig,
        allow_local_folder_sync: bool,
    ) -> CoreResult<SyncReport> {
        if config.mode == DriveTransportMode::LocalOnly && !allow_local_folder_sync {
            return Ok(SyncReport::default());
        }

        let _lock = self.run_guard.try_lock().map_err(|_| {
            CoreError::NotConfigured("当前已有同步任务正在运行，请稍候。".to_string())
        })?;

        {
            let mut s = self.status.write().await;
            s.active_mode = config.mode;
            s.last_error = None;
        }
        self.update_progress(
            Some(SyncPhase::Scanning),
            Some(format!("正在连接{}…", config.mode.localized_label())),
            Some(0.04),
        )
        .await;

        let start = Instant::now();
        let outcome = self.run_sync_inner(transport, config).await;

        match outcome {
            Ok(mut report) => {
                report.duration_seconds = start.elapsed().as_secs_f64();
                let pending = self.db.pending_op_count().unwrap_or(0);
                let final_status = {
                    let mut s = self.status.write().await;
                    s.last_synced_at = Some(Utc::now());
                    s.last_error = None;
                    s.pending_op_count = pending;
                    s.phase = SyncPhase::Idle;
                    s.current_detail = None;
                    s.progress_fraction = None;
                    s.clone()
                };
                self.db.set_state("lastSyncStatus", Some(&final_status))?;
                self.broadcast(&final_status);
                Ok(report)
            }
            Err(err) => {
                let msg = err.to_string();
                let err_status = {
                    let mut s = self.status.write().await;
                    s.phase = SyncPhase::Error(msg.clone());
                    s.last_error = Some(msg.clone());
                    s.current_detail = Some(msg);
                    s.progress_fraction = None;
                    s.clone()
                };
                self.broadcast(&err_status);
                Err(err)
            }
        }
    }

    async fn run_sync_inner(
        &self,
        transport: &dyn DriveTransport,
        config: &DriveSyncConfig,
    ) -> CoreResult<SyncReport> {
        let account = transport.account_info().await?;
        {
            let mut s = self.status.write().await;
            s.account = Some(account.clone());
        }

        self.update_progress(
            Some(SyncPhase::Scanning),
            Some("正在检查云端目录结构…".to_string()),
            Some(0.10),
        )
        .await;

        let shared_root_id = if config.mode == DriveTransportMode::DirectApiWithGDirect {
            config.resolved_shared_folder_id()
        } else {
            None
        };
        let root_path = Self::resolved_root_path(config);
        let (layout, existing_manifest) = self
            .make_layout(transport, &root_path, shared_root_id.as_deref())
            .await?;

        let scope = format!(
            "remote.{}",
            format_swift_uuid(&stable_uuid(&format!(
                "{}:{}:{}",
                transport.display_name(),
                account.email,
                layout.root
            )))
        );

        self.update_manifest(&layout, existing_manifest.as_ref(), &scope, transport)
            .await?;

        let mut report = SyncReport::default();

        self.update_progress(
            Some(SyncPhase::Downloading {
                completed: 0,
                total: 0,
            }),
            Some("正在拉取其他设备的变更记录…".to_string()),
            Some(0.16),
        )
        .await;

        let (pulled_count, mut changed_boards) = self
            .pull_ops(&layout, transport, &scope, config.sync_embeddings)
            .await?;
        report.downloaded_ops += pulled_count;

        let pending = self.db.pending_ops::<SyncOperation>(10_000)?;
        {
            let mut s = self.status.write().await;
            s.pending_op_count = pending.len();
        }

        self.update_progress(
            Some(SyncPhase::Scanning),
            Some("正在扫描云端文件变更…".to_string()),
            Some(0.26),
        )
        .await;

        let inventory = self
            .fetch_inventory(&layout, transport, &scope, shared_root_id.is_some())
            .await?;

        let remote_thumbnails = if config.sync_thumbnails {
            keyed_by_name(&transport.list_files(&layout.thumbnails).await?)
        } else {
            HashMap::new()
        };

        self.update_progress(
            Some(SyncPhase::Merging),
            Some("正在比对云端与本地目录…".to_string()),
            Some(0.32),
        )
        .await;

        let reconciled = self
            .reconcile(
                &inventory,
                &layout,
                transport,
                config,
                &pending,
                &remote_thumbnails,
            )
            .await?;

        report.discovered_remote_assets = reconciled.discovered;
        report.discovered_asset_ids = reconciled.discovered_ids;
        report.reconciled_renames = reconciled.renames;

        let mut saved_files = inventory.current.files.clone();
        for id in &reconciled.deferred_file_ids {
            saved_files.remove(id);
        }
        for id in &reconciled.removed_file_ids {
            saved_files.remove(id);
        }
        let inv_key = format!("{scope}.inventory");
        let mut saved_state = SavedInventory {
            files: saved_files.clone(),
            start_page_token: inventory.current.start_page_token.clone(),
        };
        self.db.set_state(&inv_key, Some(&saved_state))?;

        if !pending.is_empty() {
            self.update_progress(
                Some(SyncPhase::Uploading {
                    completed: 0,
                    total: pending.len(),
                }),
                Some("准备上传本地新增与变更…".to_string()),
                Some(0.62),
            )
            .await;

            let ops_only: Vec<SyncOperation> = pending.iter().map(|(_, op)| op.clone()).collect();
            let removed_by_upload = self
                .upload_physical(&ops_only, &layout, transport, &scope)
                .await?;
            if !removed_by_upload.is_empty() {
                for id in &removed_by_upload {
                    saved_files.remove(id);
                }
                saved_state = SavedInventory {
                    files: saved_files,
                    start_page_token: inventory.current.start_page_token.clone(),
                };
                self.db.set_state(&inv_key, Some(&saved_state))?;
            }
        }

        // Physical uploads can enqueue Drive identity bindings; collect publishable ops atomically.
        let ready = self.db.pending_ops::<SyncOperation>(10_000)?;
        let prepared_ids: HashSet<Uuid> = pending
            .iter()
            .filter_map(|(_, op)| match &op.change {
                SyncOperationChange::Asset(delta) => Some(delta.id),
                _ => None,
            })
            .collect();
        let cutoff = pending.last().map(|(seq, _)| *seq).unwrap_or(0);
        let mut publishable = Vec::new();
        for row in ready {
            if row.0 > cutoff {
                let is_binding_only = match &row.1.change {
                    SyncOperationChange::Asset(delta) => {
                        prepared_ids.contains(&delta.id)
                            && delta.fields.len() == 1
                            && delta.fields.contains_key("driveFileID")
                            && delta.tags_added.is_empty()
                            && delta.tags_removed.is_empty()
                    }
                    _ => false,
                };
                if !is_binding_only {
                    break;
                }
            }
            match &row.1.change {
                SyncOperationChange::Board(delta) => {
                    changed_boards.insert(delta.id);
                }
                SyncOperationChange::DeleteBoard(id) => {
                    changed_boards.insert(*id);
                }
                _ => {}
            }
            publishable.push(row);
        }

        if !publishable.is_empty() {
            self.update_progress(
                Some(SyncPhase::Uploading {
                    completed: 0,
                    total: publishable.len(),
                }),
                Some("正在上传同步日志…".to_string()),
                Some(0.82),
            )
            .await;

            report.uploaded_ops = self
                .push_ops(&publishable, transport, &layout, config.sync_embeddings)
                .await?;

            let (pulled_after, boards_after) = self
                .pull_ops(&layout, transport, &scope, config.sync_embeddings)
                .await?;
            report.downloaded_ops += pulled_after;
            changed_boards.extend(boards_after);
        }

        self.update_progress(
            Some(SyncPhase::Merging),
            Some("正在同步情绪板与缩略图…".to_string()),
            Some(0.88),
        )
        .await;

        self.write_boards(&layout, transport, &scope, &changed_boards)
            .await?;

        if config.sync_thumbnails {
            self.sync_thumbnails(&layout, transport, &scope, Some(&remote_thumbnails))
                .await?;
        }

        // Cross-platform safety: vectors already propagate losslessly via `ops/*.jsonl`.
        // Do NOT overwrite macOS binary-plist `.charkle/embeddings/shard-*.bin` with JSON;
        // clear local Windows projection markers once ops have been published.
        if config.sync_embeddings {
            let dirty_emb: BTreeMap<String, String> =
                self.db.state("projection.embeddings")?.unwrap_or_default();
            if !dirty_emb.is_empty() {
                let pairs: Vec<(String, String)> = dirty_emb.into_iter().collect();
                self.db.clear_projections("embeddings", &pairs)?;
            }
        }

        self.fetch_pinned_originals(transport).await?;

        self.media.cleanup_deleted_media(&self.db)?;

        report.updated_boards = changed_boards.len();
        Ok(report)
    }

    /// Downloads the remote original for `asset_id` into the local LRU cache and updates DB state.
    pub async fn download_original(
        &self,
        asset_id: Uuid,
        transport: &dyn DriveTransport,
    ) -> CoreResult<PathBuf> {
        let asset = self
            .db
            .asset(asset_id)?
            .ok_or_else(|| CoreError::NotFound(format_swift_uuid(&asset_id)))?;
        let remote = asset
            .drive_file_id
            .clone()
            .ok_or_else(|| CoreError::NotFound(format_swift_uuid(&asset_id)))?;

        let staged = self.media.staging.join(format!(
            "original-{}-{}",
            format_swift_uuid(&asset_id),
            Uuid::new_v4().simple()
        ));
        transport.download_file(&remote, &staged).await?;

        let installed = (|| -> CoreResult<PathBuf> {
            let mut current = self
                .db
                .asset(asset_id)?
                .ok_or_else(|| CoreError::NotFound(format_swift_uuid(&asset_id)))?;
            if current.drive_file_id.as_deref() != Some(remote.as_str()) {
                return Err(CoreError::NotFound(format_swift_uuid(&asset_id)));
            }
            let path = self.media.install_original(&staged, &current, true)?;
            current.is_local_original_cached = true;
            self.db.put_asset(&current)?;
            self.db.touch_original(asset_id, Utc::now())?;
            Ok(path)
        })();
        let _ = fs::remove_file(&staged);
        installed
    }

    async fn fetch_pinned_originals(&self, transport: &dyn DriveTransport) -> CoreResult<()> {
        let protected = self.db.protected_asset_ids()?;
        let mut missing = Vec::new();
        for id in protected {
            if let Some(asset) = self.db.asset(id)? {
                if asset.drive_file_id.is_some() && self.media.cached_original(&asset).is_none() {
                    missing.push(id);
                }
            }
        }
        if missing.is_empty() {
            return Ok(());
        }
        let total = missing.len();
        for (idx, id) in missing.into_iter().enumerate() {
            self.update_progress(
                Some(SyncPhase::Downloading {
                    completed: idx,
                    total,
                }),
                Some(format!("下载常驻本地原图 ({idx}/{total})")),
                Some(0.96 + 0.03 * (idx as f64 / total.max(1) as f64)),
            )
            .await;
            let _ = self.download_original(id, transport).await?;
        }
        Ok(())
    }

    fn resolved_root_path(config: &DriveSyncConfig) -> String {
        match config.mode {
            DriveTransportMode::WebDav => config.webdav_remote_path.clone(),
            DriveTransportMode::LocalOnly => {
                let p = Path::new(config.local_library_path.trim());
                p.file_name()
                    .and_then(|n| n.to_str())
                    .filter(|s| !s.is_empty())
                    .unwrap_or("Charkle")
                    .to_string()
            }
            DriveTransportMode::DirectApiWithGDirect | DriveTransportMode::GDirectMount => {
                config.root_folder_name.clone()
            }
        }
    }

    async fn make_layout(
        &self,
        transport: &dyn DriveTransport,
        root_path: &str,
        shared_root_id: Option<&str>,
    ) -> CoreResult<(Layout, Option<RemoteDriveFile>)> {
        let root = if let Some(sid) = shared_root_id.filter(|s| !s.is_empty()) {
            transport.resolve_folder(sid).await?
        } else {
            let segments: Vec<&str> = root_path
                .split('/')
                .map(str::trim)
                .filter(|s| !s.is_empty() && *s != "." && *s != "..")
                .collect();
            let final_segments = if segments.is_empty() {
                vec!["Charkle"]
            } else {
                segments
            };
            let mut parent_id = DRIVE_ROOT_ID.to_string();
            let mut last = None;
            for seg in final_segments {
                validate_drive_name(seg)?;
                let created = transport.find_or_create_folder(seg, &parent_id).await?;
                parent_id = created.id.clone();
                last = Some(created);
            }
            last.ok_or_else(|| {
                CoreError::NotConfigured("请指定有效的素材库保存路径。".to_string())
            })?
        };

        let root_children = transport.list_files(&root.id).await?;
        let inbox = match oldest_subfolder("Inbox", &root_children) {
            Some(f) => f,
            None => transport.find_or_create_folder("Inbox", &root.id).await?,
        };
        let metadata = match oldest_subfolder(".charkle", &root_children) {
            Some(f) => f,
            None => {
                transport
                    .find_or_create_folder(".charkle", &root.id)
                    .await?
            }
        };

        let meta_children = transport.list_files(&metadata.id).await?;
        let manifest_file = meta_children
            .iter()
            .find(|f| !f.is_folder() && f.name == "manifest.json")
            .cloned();

        let ops = match oldest_subfolder("ops", &meta_children) {
            Some(f) => f,
            None => transport.find_or_create_folder("ops", &metadata.id).await?,
        };
        let boards = match oldest_subfolder("boards", &meta_children) {
            Some(f) => f,
            None => {
                transport
                    .find_or_create_folder("boards", &metadata.id)
                    .await?
            }
        };
        let embeddings = match oldest_subfolder("embeddings", &meta_children) {
            Some(f) => f,
            None => {
                transport
                    .find_or_create_folder("embeddings", &metadata.id)
                    .await?
            }
        };
        let thumbnails = match oldest_subfolder("thumbnails", &meta_children) {
            Some(f) => f,
            None => {
                transport
                    .find_or_create_folder("thumbnails", &metadata.id)
                    .await?
            }
        };

        Ok((
            Layout {
                root: root.id,
                inbox: inbox.id,
                metadata: metadata.id,
                ops: ops.id,
                boards: boards.id,
                embeddings: embeddings.id,
                thumbnails: thumbnails.id,
            },
            manifest_file,
        ))
    }

    async fn update_manifest(
        &self,
        layout: &Layout,
        existing_manifest: Option<&RemoteDriveFile>,
        scope: &str,
        transport: &dyn DriveTransport,
    ) -> CoreResult<()> {
        let verified_key = format!("{scope}.manifestVerified");
        if let Some(known) = existing_manifest {
            let stamp = format!(
                "{}:{}",
                known.id,
                known.md5_checksum.clone().unwrap_or_else(|| {
                    known
                        .modified_time
                        .map(|t| t.timestamp().to_string())
                        .unwrap_or_else(|| "0".to_string())
                })
            );
            if self.db.state::<String>(&verified_key)?.as_deref() == Some(stamp.as_str()) {
                return Ok(());
            }
            let data = transport.download_data(&known.id).await?;
            let manifest: SyncManifest = serde_json::from_slice(&data)?;
            if manifest.version != 1 {
                return Err(CoreError::InvalidPayload(format!(
                    "Unsupported Charkle sync protocol {}.",
                    manifest.version
                )));
            }
            self.db.set_state(&verified_key, Some(&stamp))?;
            return Ok(());
        }

        let mounted = transport.is_mounted_volume();
        let directories = if mounted {
            None
        } else {
            let mut map = BTreeMap::new();
            map.insert("Inbox".to_string(), layout.inbox.clone());
            map.insert("boards".to_string(), layout.boards.clone());
            map.insert("embeddings".to_string(), layout.embeddings.clone());
            map.insert("ops".to_string(), layout.ops.clone());
            map.insert("thumbnails".to_string(), layout.thumbnails.clone());
            Some(map)
        };
        let manifest = SyncManifest {
            version: 1,
            root_folder_id: (!mounted).then(|| layout.root.clone()),
            directories,
        };
        let data = canonical_json_bytes(&manifest)?;
        let uploaded = Self::write_blob(
            &data,
            "manifest.json",
            "application/json",
            &layout.metadata,
            None,
            transport,
            false,
        )
        .await?;
        let stamp = format!(
            "{}:{}",
            uploaded.id,
            uploaded.md5_checksum.clone().unwrap_or_else(|| {
                uploaded
                    .modified_time
                    .map(|t| t.timestamp().to_string())
                    .unwrap_or_else(|| "0".to_string())
            })
        );
        self.db.set_state(&verified_key, Some(&stamp))?;
        Ok(())
    }

    async fn pull_ops(
        &self,
        layout: &Layout,
        transport: &dyn DriveTransport,
        scope: &str,
        sync_embeddings: bool,
    ) -> CoreResult<(usize, HashSet<Uuid>)> {
        let local_device = self.db.device_id()?;
        let mut shards: Vec<(String, i64, RemoteDriveFile)> = transport
            .list_files(&layout.ops)
            .await?
            .into_iter()
            .filter(|f| !f.is_folder())
            .filter_map(|f| {
                let (dev, end_seq) = parse_ops_shard_file_name(&f.name)?;
                (dev != local_device).then_some((dev, end_seq, f))
            })
            .collect();
        shards.sort_by(|a, b| {
            a.0.cmp(&b.0)
                .then_with(|| a.1.cmp(&b.1))
                .then_with(|| a.2.id.cmp(&b.2.id))
        });

        let cursor_key = format!("{scope}.deviceCursors");
        let mut cursors: BTreeMap<String, i64> = self.db.state(&cursor_key)?.unwrap_or_default();
        let mut downloaded = 0usize;
        let mut changed_boards = HashSet::new();

        for (device, end_seq, file) in shards {
            let previous = cursors.get(&device).copied().unwrap_or(0);
            if end_seq <= previous {
                continue;
            }
            let bytes = transport.download_data(&file.id).await?;
            let text = String::from_utf8(bytes).map_err(|_| {
                CoreError::InvalidPayload(format!("Malformed UTF-8 in sync shard {}", file.name))
            })?;
            let lines = decode_ops_jsonl(&text)?;
            let seq_monotonic = lines.windows(2).all(|w| w[0].seq < w[1].seq);
            let all_same_device = lines.iter().all(|l| l.operation.stamp.device == device);
            let ends_right = lines.last().map(|l| l.seq) == Some(end_seq);
            if lines.is_empty() || !ends_right || !all_same_device || !seq_monotonic {
                return Err(CoreError::InvalidPayload(format!(
                    "Malformed sync operation shard {}.",
                    file.name
                )));
            }

            let mut ops_to_apply = Vec::new();
            let mut disabled_vectors = Vec::new();
            let mut unseen_count = 0usize;
            for line in lines.into_iter().filter(|l| l.seq > previous) {
                unseen_count += 1;
                match &line.operation.change {
                    SyncOperationChange::Board(delta) => {
                        changed_boards.insert(delta.id);
                    }
                    SyncOperationChange::DeleteBoard(id) => {
                        changed_boards.insert(*id);
                    }
                    _ => {}
                }
                if matches!(line.operation.change, SyncOperationChange::Vector { .. })
                    && !sync_embeddings
                {
                    disabled_vectors.push((
                        format!("disabled.vector.{device}.{}", line.seq),
                        line.operation,
                    ));
                } else {
                    ops_to_apply.push(line.operation);
                }
            }

            cursors.insert(device, end_seq);
            self.db
                .apply_op_shard(&ops_to_apply, &disabled_vectors, &cursor_key, &cursors)?;
            downloaded += unseen_count;
        }

        if sync_embeddings {
            let _ = self.db.replay_disabled_vectors()?;
        }

        Ok((downloaded, changed_boards))
    }

    async fn push_ops(
        &self,
        operations: &[(i64, SyncOperation)],
        transport: &dyn DriveTransport,
        layout: &Layout,
        sync_embeddings: bool,
    ) -> CoreResult<usize> {
        if operations.is_empty() {
            return Ok(0);
        }
        let device = self.db.device_id()?;
        let known = keyed_by_name(&transport.list_files(&layout.ops).await?);
        let mut uploaded = 0usize;

        for (chunk_idx, chunk) in operations.chunks(200).enumerate() {
            let Some(&(end_seq, _)) = chunk.last() else {
                continue;
            };
            let mut bytes = Vec::new();
            let mut last_included = None;
            let mut line_count = 0usize;

            for (seq, op) in chunk {
                if matches!(op.change, SyncOperationChange::Vector { .. }) && !sync_embeddings {
                    continue;
                }
                let log_line = SyncLogLine {
                    seq: *seq,
                    operation: op.clone(),
                };
                bytes.extend_from_slice(&canonical_json_bytes(&log_line)?);
                bytes.push(b'\n');
                last_included = Some(*seq);
                line_count += 1;
            }

            if let Some(last_seq) = last_included {
                let name = format_ops_shard_file_name(&device, last_seq);
                if let Some(existing) = known.get(&name) {
                    let remote = transport.download_data(&existing.id).await?;
                    if remote != bytes {
                        return Err(CoreError::InvalidPayload(format!(
                            "Conflicting operation shard {name}."
                        )));
                    }
                } else {
                    match transport
                        .upload_data(&bytes, &name, "application/x-ndjson", &layout.ops, None)
                        .await
                    {
                        Ok(_) => {}
                        Err(CoreError::AlreadyExists(_)) => {
                            let fresh = transport.list_files(&layout.ops).await?;
                            if let Some(existing) = fresh.into_iter().find(|f| f.name == name) {
                                let remote = transport.download_data(&existing.id).await?;
                                if remote != bytes {
                                    return Err(CoreError::InvalidPayload(format!(
                                        "Conflicting operation shard {name}."
                                    )));
                                }
                            } else {
                                return Err(CoreError::AlreadyExists(name));
                            }
                        }
                        Err(e) => return Err(e),
                    }
                }
                uploaded += line_count;
            }

            self.db.acknowledge_ops(end_seq)?;
            let done_ops = ((chunk_idx + 1) * 200).min(operations.len());
            self.update_progress(
                Some(SyncPhase::Uploading {
                    completed: done_ops,
                    total: operations.len(),
                }),
                Some(format!("同步变更日志 ({done_ops}/{})", operations.len())),
                Some(0.82 + 0.05 * (done_ops as f64 / operations.len().max(1) as f64)),
            )
            .await;
        }

        Ok(uploaded)
    }

    async fn fetch_inventory(
        &self,
        layout: &Layout,
        transport: &dyn DriveTransport,
        scope: &str,
        force_full_crawl: bool,
    ) -> CoreResult<InventoryUpdate> {
        let inv_key = format!("{scope}.inventory");
        let previous: Option<SavedInventory> = self.db.state(&inv_key)?;

        let mut inventory = if force_full_crawl {
            self.crawl(layout, transport).await?
        } else if let Some(ref prev) = previous {
            match self.read_changes(prev, transport).await {
                Ok(inv) => inv,
                Err(CoreError::Http {
                    status_code: 410, ..
                }) => self.crawl(layout, transport).await?,
                Err(e) => return Err(e),
            }
        } else {
            self.crawl(layout, transport).await?
        };

        let known = previous
            .as_ref()
            .map(|p| p.files.clone())
            .unwrap_or_default();
        let (mut visible_files, mut visible_folders) = self.reachable(&inventory.files, layout);

        if !force_full_crawl && previous.is_some() {
            let new_folders: Vec<RemoteDriveFile> = visible_folders
                .iter()
                .filter(|f| !known.contains_key(&f.id) && f.id != layout.inbox)
                .cloned()
                .collect();
            for folder in new_folders {
                self.collect_children(&folder.id, &mut inventory.files, layout, transport)
                    .await?;
            }
            let recomputed = self.reachable(&inventory.files, layout);
            visible_files = recomputed.0;
            visible_folders = recomputed.1;
        }

        Ok(InventoryUpdate {
            previous: known,
            current: SavedInventory {
                files: visible_files,
                start_page_token: inventory.start_page_token,
            },
            ordered_folders: visible_folders,
        })
    }

    async fn crawl(
        &self,
        layout: &Layout,
        transport: &dyn DriveTransport,
    ) -> CoreResult<Inventory> {
        let token = transport.fetch_start_page_token().await?;
        let mut files = BTreeMap::new();
        self.collect_children(&layout.root, &mut files, layout, transport)
            .await?;
        Ok(Inventory {
            files,
            start_page_token: token,
        })
    }

    async fn collect_children(
        &self,
        root: &str,
        files: &mut BTreeMap<String, RemoteDriveFile>,
        layout: &Layout,
        transport: &dyn DriveTransport,
    ) -> CoreResult<()> {
        let mut frontier = vec![root.to_string()];
        let mut seen = HashSet::new();
        while let Some(folder_id) = frontier.pop() {
            if !seen.insert(folder_id.clone()) {
                continue;
            }
            let batch = transport.list_files(&folder_id).await?;
            for file in batch {
                if !is_visible(&file, layout) {
                    continue;
                }
                let is_dir = file.is_folder();
                let id = file.id.clone();
                files.insert(id.clone(), file);
                if is_dir {
                    frontier.push(id);
                }
            }
        }
        Ok(())
    }

    async fn read_changes(
        &self,
        previous: &SavedInventory,
        transport: &dyn DriveTransport,
    ) -> CoreResult<Inventory> {
        let mut files = previous.files.clone();
        let mut token = previous.start_page_token.clone();
        let mut visited = HashSet::new();

        while visited.insert(token.clone()) {
            let page = transport.list_changes(&token).await?;
            for change in page.changes {
                if change.removed || change.file.as_ref().is_some_and(|f| f.trashed) {
                    files.remove(&change.file_id);
                } else if let Some(file) = change.file {
                    files.insert(file.id.clone(), file);
                }
            }
            if let Some(next) = page.next_page_token {
                token = next;
            } else if let Some(final_token) = page.new_start_page_token {
                return Ok(Inventory {
                    files,
                    start_page_token: final_token,
                });
            } else {
                break;
            }
        }

        Err(CoreError::InvalidPayload(
            "Incomplete Drive change cursor chain.".to_string(),
        ))
    }

    fn reachable(
        &self,
        files: &BTreeMap<String, RemoteDriveFile>,
        layout: &Layout,
    ) -> (BTreeMap<String, RemoteDriveFile>, Vec<RemoteDriveFile>) {
        let mut by_parent: HashMap<&str, Vec<&RemoteDriveFile>> = HashMap::new();
        for f in files.values().filter(|f| is_visible(f, layout)) {
            let parent = f.parents.first().map(String::as_str).unwrap_or("");
            by_parent.entry(parent).or_default().push(f);
        }

        let mut reachable_map = BTreeMap::new();
        let mut folders = Vec::new();
        let mut queue = vec![layout.root.as_str()];
        let mut idx = 0;

        while idx < queue.len() {
            let parent = queue[idx];
            idx += 1;
            let Some(entries) = by_parent.get(parent) else {
                continue;
            };
            let mut sorted: Vec<&RemoteDriveFile> = entries.clone();
            sorted.sort_by(|a, b| a.name.cmp(&b.name).then_with(|| a.id.cmp(&b.id)));
            for file in sorted {
                if file.id == layout.root || reachable_map.contains_key(&file.id) {
                    continue;
                }
                reachable_map.insert(file.id.clone(), file.clone());
                if file.is_folder() {
                    queue.push(file.id.as_str());
                    folders.push(file.clone());
                }
            }
        }

        (reachable_map, folders)
    }

    async fn reconcile(
        &self,
        update: &InventoryUpdate,
        layout: &Layout,
        transport: &dyn DriveTransport,
        config: &DriveSyncConfig,
        pending: &[(i64, SyncOperation)],
        remote_thumbnails: &HashMap<String, RemoteDriveFile>,
    ) -> CoreResult<ReconcileOutcome> {
        let is_mounted = transport.is_mounted_volume();
        let mut pending_moves = HashSet::new();
        let mut pending_folders = HashSet::new();
        let mut pending_deleted_drive_ids = HashSet::new();

        for (_, op) in pending {
            match &op.change {
                SyncOperationChange::Asset(delta)
                    if delta.touches_location() && op.project_location != Some(false) =>
                {
                    pending_moves.insert(delta.id);
                }
                SyncOperationChange::Folder(folder) if op.project_location != Some(false) => {
                    pending_folders.insert(folder.id);
                }
                SyncOperationChange::DeleteAsset { id, drive_id } => {
                    if let Some(did) = drive_id {
                        pending_deleted_drive_ids.insert(did.clone());
                    }
                    if is_mounted {
                        let key = format!("local.delete.asset.{}", format_swift_uuid(id));
                        if let Some(local) = self.db.state::<String>(&key)? {
                            pending_deleted_drive_ids.insert(local);
                        }
                    }
                }
                _ => {}
            }
        }

        // Clear stale mounted-path deletion markers once absent on mounted filesystem
        if is_mounted {
            let prefix = format!("deleted.drive.{MOUNTED_PATH_ID_PREFIX}");
            let markers = self.db.states_with_prefix::<bool>(&prefix)?;
            for (key, _) in markers {
                if let Some(remote_id) = key.strip_prefix("deleted.drive.") {
                    if !update.current.files.contains_key(remote_id)
                        && !pending_deleted_drive_ids.contains(remote_id)
                    {
                        self.db.set_state::<bool>(&key, None)?;
                    }
                }
            }
        }

        // 1. Reconcile remote folders
        let mut folder_ids: HashMap<String, Uuid> = HashMap::new();
        let mut folders = self.db.fetch_folders()?;
        for file in &update.ordered_folders {
            if file.id == layout.inbox {
                continue;
            }
            let parent = file
                .parents
                .first()
                .and_then(|pid| folder_ids.get(pid).copied());
            let found_idx = folders
                .iter()
                .position(|f| f.drive_folder_id.as_deref() == Some(file.id.as_str()))
                .or_else(|| {
                    folders
                        .iter()
                        .position(|f| f.parent_id == parent && f.name == file.name)
                });
            let id = found_idx
                .map(|i| folders[i].id)
                .unwrap_or_else(|| stable_uuid(&format!("folder:{}", file.id)));

            if self.db.is_tombstoned("folder", id)? {
                continue;
            }
            let mut folder = self.db.folder(id)?.unwrap_or_else(|| {
                let mut f = FolderRecord::new(&file.name, parent);
                f.id = id;
                f.sort_order = folders.len() as i32;
                f
            });
            let before = folder.clone();
            let prev_remote = update.previous.get(&file.id);
            if !pending_folders.contains(&id)
                && (prev_remote.map(|p| p.name.as_str()) != Some(file.name.as_str())
                    || prev_remote.map(|p| &p.parents) != Some(&file.parents))
            {
                folder.name = file.name.clone();
                folder.parent_id = parent;
            }
            folder.drive_folder_id = Some(file.id.clone());
            if before.name != folder.name
                || before.parent_id != folder.parent_id
                || found_idx.is_none()
            {
                folder.updated_at = file.modified_time.unwrap_or_else(Utc::now);
                self.db
                    .record(SyncOperationChange::Folder(folder.clone()), false)?;
            }
            if let Some(mut stored) = self.db.folder(id)? {
                stored.drive_folder_id = Some(file.id.clone());
                self.db.upsert_folder(&stored)?;
                folder = stored;
            } else {
                self.db.upsert_folder(&folder)?;
            }
            folder_ids.insert(file.id.clone(), folder.id);
            if let Some(i) = found_idx {
                folders[i] = folder;
            } else {
                folders.push(folder);
            }
        }

        // 2. Reconcile visible files
        let mut discovered = 0usize;
        let mut discovered_ids = Vec::new();
        let mut renames = 0usize;
        let mut deferred_file_ids = HashSet::new();
        let mut removed_file_ids = HashSet::new();
        let mut linked: HashMap<String, Uuid> =
            self.db.asset_drive_bindings()?.into_iter().collect();

        let mut visible: Vec<&RemoteDriveFile> = update
            .current
            .files
            .values()
            .filter(|file| {
                if file.is_folder() {
                    return false;
                }
                if update.previous.get(&file.id) != Some(*file) {
                    return true;
                }
                match linked.get(&file.id) {
                    Some(&id) => self
                        .media
                        .thumbnail_url(id, ThumbnailTier::Grid520)
                        .is_none(),
                    None => true,
                }
            })
            .collect();
        visible.sort_by(|a, b| a.id.cmp(&b.id));

        let mut download_jobs: Vec<(&RemoteDriveFile, Option<Uuid>, Option<AssetRecord>)> =
            Vec::new();

        for file in visible {
            if pending_deleted_drive_ids.contains(&file.id) {
                removed_file_ids.insert(file.id.clone());
                continue;
            }
            if self
                .db
                .state::<bool>(&format!("deleted.drive.{}", file.id))?
                == Some(true)
            {
                let compatible = if is_mounted {
                    file.id.starts_with("mounted-")
                } else {
                    !file.id.starts_with("mounted-")
                };
                if compatible {
                    Self::trash_if_present(&file.id, transport).await?;
                }
                removed_file_ids.insert(file.id.clone());
                continue;
            }
            if is_likely_incomplete_zero_byte_media(file) {
                deferred_file_ids.insert(file.id.clone());
                continue;
            }

            let previous = update.previous.get(&file.id);
            let folder_id = file
                .parents
                .first()
                .and_then(|pid| folder_ids.get(pid).copied());
            let existing = match linked.get(&file.id) {
                Some(&aid) => self.db.asset(aid)?,
                None => None,
            };

            if existing.is_none() {
                if let Some(ref md5) = file.md5_checksum {
                    if !md5.is_empty() {
                        if let Some(deleted) = self
                            .db
                            .state::<DeletedAssetFingerprint>(&format!("deleted.md5.{md5}"))?
                        {
                            if self.db.assets_by_content_hash(&deleted.sha256)?.is_empty() {
                                Self::trash_if_present(&file.id, transport).await?;
                                let _ = self
                                    .db
                                    .set_state(&format!("deleted.drive.{}", file.id), Some(&true));
                                removed_file_ids.insert(file.id.clone());
                                continue;
                            }
                        }
                    }
                }
            }

            let changed_content = content_changed(previous, file);
            if let Some(ref existing_asset) = existing {
                if !changed_content || previous.is_none() {
                    if (previous != Some(file)
                        || (existing_asset.folder_id.is_none() && folder_id.is_some()))
                        && self.reconcile_location(
                            file,
                            previous,
                            existing_asset,
                            folder_id,
                            pending_moves.contains(&existing_asset.id),
                        )?
                    {
                        renames += 1;
                    }
                    let thumb_key = format!("{}.jpg", existing_asset.id.hyphenated());
                    if existing_asset.is_trashed
                        || self
                            .media
                            .thumbnail_url(existing_asset.id, ThumbnailTier::Grid520)
                            .is_some()
                        || remote_thumbnails.contains_key(&thumb_key)
                    {
                        continue;
                    }
                    if let Some(cached) = self.media.cached_original(existing_asset) {
                        let rendered = self
                            .media
                            .refresh_from_file(existing_asset.clone(), &cached)
                            .await?;
                        let _ = self.persist_remote_media(
                            rendered,
                            Some(existing_asset),
                            None,
                            config,
                            false,
                        )?;
                        continue;
                    }
                }
            }
            download_jobs.push((file, folder_id, existing));
        }

        // Phase 2: download & process remote files
        let total_downloads = download_jobs.len();
        for (idx, (file, folder_id, existing)) in download_jobs.into_iter().enumerate() {
            let ratio = 0.34 + 0.26 * ((idx + 1) as f64 / total_downloads.max(1) as f64);
            self.update_progress(
                Some(SyncPhase::Downloading {
                    completed: idx,
                    total: total_downloads,
                }),
                Some(format!("拉取：{}", file.name)),
                Some(ratio),
            )
            .await;

            let stage_dir = self.media.staging.join(format!(
                "remote-{}-{}",
                format_swift_uuid(&stable_uuid(&file.id)),
                &Uuid::new_v4().simple().to_string()[..8]
            ));
            let res = self
                .download_and_ingest_remote(
                    file,
                    folder_id,
                    existing.as_ref(),
                    &update.current,
                    transport,
                    config,
                    &stage_dir,
                )
                .await;
            let _ = fs::remove_dir_all(&stage_dir);

            match res {
                Ok(RemoteIngestOutcome::Saved {
                    saved,
                    had_existing,
                    previous_file_name,
                    previous_folder_id,
                }) => {
                    linked.insert(file.id.clone(), saved.id);
                    if !had_existing
                        && (saved.id == stable_uuid(&format!("asset:{}", file.id))
                            || file.id.starts_with(MOUNTED_PATH_ID_PREFIX))
                    {
                        discovered += 1;
                        discovered_ids.push(saved.id);
                    }
                    if had_existing
                        && (previous_file_name.as_deref() != Some(saved.file_name.as_str())
                            || previous_folder_id != saved.folder_id)
                    {
                        renames += 1;
                    }
                }
                Ok(RemoteIngestOutcome::Skipped) => {}
                Ok(RemoteIngestOutcome::DeletedLocally) => {
                    Self::trash_if_present(&file.id, transport).await?;
                    let _ = self
                        .db
                        .set_state(&format!("deleted.drive.{}", file.id), Some(&true));
                    removed_file_ids.insert(file.id.clone());
                }
                Err(err) => {
                    if is_fatal_sync_error(&err) {
                        return Err(err);
                    }
                    deferred_file_ids.insert(file.id.clone());
                }
            }
        }

        // Phase 3: soft-trash assets whose remote files disappeared
        for (id, gone) in &update.previous {
            if gone.is_folder() || update.current.files.contains_key(id) {
                continue;
            }
            let Some(&asset_id) = linked.get(id) else {
                continue;
            };
            if pending_moves.contains(&asset_id) {
                continue;
            }
            if let Some(mut asset) = self.db.asset(asset_id)? {
                if asset.drive_file_id.as_deref() == Some(id.as_str()) && !asset.is_trashed {
                    asset.is_trashed = true;
                    self.db
                        .set_state(&format!("remote.hidden.{id}"), Some(&true))?;
                    let _ = self.db.save_asset_locally(&asset, false)?;
                }
            }
        }

        Ok(ReconcileOutcome {
            discovered,
            discovered_ids,
            renames,
            deferred_file_ids,
            removed_file_ids,
        })
    }

    #[allow(clippy::too_many_arguments)]
    async fn download_and_ingest_remote(
        &self,
        file: &RemoteDriveFile,
        folder_id: Option<Uuid>,
        existing: Option<&AssetRecord>,
        current: &SavedInventory,
        transport: &dyn DriveTransport,
        config: &DriveSyncConfig,
        stage_dir: &Path,
    ) -> CoreResult<RemoteIngestOutcome> {
        fs::create_dir_all(stage_dir)?;
        let is_google_doc = file.mime_type.starts_with("application/vnd.google-apps.");
        let filename = original_name(file);
        let ext: String = Path::new(&filename)
            .extension()
            .and_then(|e| e.to_str())
            .unwrap_or("")
            .chars()
            .filter(|c| c.is_ascii_alphanumeric())
            .collect();
        let temp_path = stage_dir.join(if ext.is_empty() {
            "content".to_string()
        } else {
            format!("content.{ext}")
        });

        transport.download_remote_file(file, &temp_path).await?;
        let digests = MediaPipeline::digests(&temp_path)?;

        let matching: Option<AssetRecord> = if let Some(ex) = existing {
            Some(ex.clone())
        } else {
            let candidates: Vec<AssetRecord> = self
                .db
                .assets_by_content_hash(&digests.sha256)?
                .into_iter()
                .filter(|a| {
                    (a.drive_file_id.is_none()
                        && a.file_name == filename
                        && a.folder_id == folder_id)
                        || a.drive_file_id
                            .as_ref()
                            .is_some_and(|did| !current.files.contains_key(did))
                })
                .collect();
            if candidates.len() == 1 {
                candidates.into_iter().next()
            } else {
                let exact: Vec<AssetRecord> = candidates
                    .into_iter()
                    .filter(|a| a.file_name == filename && a.folder_id == folder_id)
                    .collect();
                if exact.len() == 1 {
                    exact.into_iter().next()
                } else {
                    None
                }
            }
        };

        if matching.is_none()
            && self
                .db
                .state::<DeletedAssetFingerprint>(&format!("deleted.content.{}", digests.sha256))?
                .is_some()
            && self.db.assets_by_content_hash(&digests.sha256)?.is_empty()
        {
            return Ok(RemoteIngestOutcome::DeletedLocally);
        }

        let mut id = matching
            .as_ref()
            .map(|m| m.id)
            .unwrap_or_else(|| stable_uuid(&format!("asset:{}", file.id)));
        if self.db.is_tombstoned("asset", id)? {
            if matching.is_none() && file.id.starts_with(MOUNTED_PATH_ID_PREFIX) {
                id = Uuid::new_v4();
            } else {
                return Ok(RemoteIngestOutcome::Skipped);
            }
        }

        let mime = if is_google_doc {
            "application/pdf".to_string()
        } else {
            file.mime_type.clone()
        };
        let natural_title = file_stem_or_full(&filename);
        let mut asset = matching.clone().unwrap_or_else(|| {
            let mut created = AssetRecord::new(&natural_title, &filename);
            created.id = id;
            created.created_at = file.modified_time.unwrap_or_else(Utc::now);
            created
        });
        if asset.title == file_stem_or_full(&asset.file_name) {
            asset.title = natural_title;
        }
        asset.file_name = filename;
        asset.drive_file_id = Some(file.id.clone());
        asset.folder_id = folder_id;
        asset.media_kind = MediaKind::detect(&ext, Some(&mime));
        asset.mime_type = mime;
        asset.content_hash = digests.sha256;
        asset.file_size_bytes = digests.bytes;

        let rendered = self.media.refresh_from_file(asset, &temp_path).await?;
        let saved =
            self.persist_remote_media(rendered, matching.as_ref(), Some(&temp_path), config, true)?;

        match saved {
            Some(saved_asset) => Ok(RemoteIngestOutcome::Saved {
                saved: Box::new(saved_asset),
                had_existing: existing.is_some(),
                previous_file_name: existing.map(|e| e.file_name.clone()),
                previous_folder_id: existing.and_then(|e| e.folder_id),
            }),
            None => Ok(RemoteIngestOutcome::Skipped),
        }
    }

    fn persist_remote_media(
        &self,
        mut result: AssetRecord,
        matching: Option<&AssetRecord>,
        temporary: Option<&Path>,
        config: &DriveSyncConfig,
        move_temp: bool,
    ) -> CoreResult<Option<AssetRecord>> {
        if self.db.is_tombstoned("asset", result.id)? {
            return Ok(None);
        }
        if let (Some(current), Some(matched)) = (self.db.asset(result.id)?, matching) {
            if current.drive_file_id != matched.drive_file_id {
                return Ok(None);
            }
            result.notes = current.notes;
            result.tags = current.tags;
            result.suggested_tags = current.suggested_tags;
            result.ai_description = current.ai_description;
            result.rating = current.rating;
            result.is_trashed = current.is_trashed;
            result.pinned_offline = current.pinned_offline;
            if current.title != matched.title {
                result.title = current.title;
            }
            if current.file_name != matched.file_name {
                result.file_name = current.file_name;
            }
            if current.folder_id != matched.folder_id {
                result.folder_id = current.folder_id;
            }
        }
        if let Some(temp_path) = temporary {
            let _ = self.media.install_original(temp_path, &result, move_temp)?;
            result.is_local_original_cached = true;
        }
        let saved = self.db.save_asset_locally(&result, false)?;
        if saved.is_local_original_cached {
            self.db.touch_original(saved.id, Utc::now())?;
        }
        if config.sync_thumbnails {
            self.db.mark_projection("thumbnails", saved.id)?;
        }
        Ok(Some(saved))
    }

    fn reconcile_location(
        &self,
        file: &RemoteDriveFile,
        previous: Option<&RemoteDriveFile>,
        existing: &AssetRecord,
        folder_id: Option<Uuid>,
        pending_move: bool,
    ) -> CoreResult<bool> {
        if pending_move {
            return Ok(false);
        }
        let filename = original_name(file);
        let Some(mut current) = self.db.asset(existing.id)? else {
            return Ok(false);
        };
        if current.drive_file_id.as_deref() != Some(file.id.as_str()) {
            return Ok(false);
        }
        let before = current.clone();
        if previous.map(|p| p.name.as_str()) != Some(file.name.as_str())
            && current.file_name != filename
        {
            if current.title == file_stem_or_full(&current.file_name) {
                current.title = file_stem_or_full(&filename);
            }
            current.file_name = filename;
        }
        if previous.map(|p| &p.parents) != Some(&file.parents) {
            current.folder_id = folder_id;
        }
        let hidden_key = format!("remote.hidden.{}", file.id);
        if self.db.state::<bool>(&hidden_key)? == Some(true) {
            current.is_trashed = false;
            self.db.set_state::<bool>(&hidden_key, None)?;
        }
        if current != before {
            let _ = self.db.save_asset_locally(&current, false)?;
            Ok(true)
        } else {
            Ok(false)
        }
    }

    async fn upload_physical(
        &self,
        operations: &[SyncOperation],
        layout: &Layout,
        transport: &dyn DriveTransport,
        scope: &str,
    ) -> CoreResult<HashSet<String>> {
        let is_mounted = transport.is_mounted_volume();
        let mut changed_folders = HashSet::new();
        let mut moved_assets = HashSet::new();
        let mut visited_assets = HashSet::new();
        let mut removed_files = HashSet::new();
        let mut removed_folders = HashSet::new();

        for op in operations {
            if op.project_location == Some(false) {
                continue;
            }
            match &op.change {
                SyncOperationChange::Folder(f) => {
                    changed_folders.insert(f.id);
                }
                SyncOperationChange::Asset(delta) => {
                    visited_assets.insert(delta.id);
                    if delta.touches_location() {
                        moved_assets.insert(delta.id);
                    }
                }
                SyncOperationChange::DeleteAsset { id, drive_id } => {
                    if let Some(did) = drive_id {
                        removed_files.insert(did.clone());
                    } else if is_mounted {
                        let key = format!("local.delete.asset.{}", format_swift_uuid(id));
                        if let Some(local) = self.db.state::<String>(&key)? {
                            removed_files.insert(local);
                        }
                    }
                }
                SyncOperationChange::DeleteFolder { id, drive_id } => {
                    if let Some(did) = drive_id {
                        removed_folders.insert(did.clone());
                    } else if is_mounted {
                        let key = format!("local.delete.folder.{}", format_swift_uuid(id));
                        if let Some(local) = self.db.state::<String>(&key)? {
                            removed_folders.insert(local);
                        }
                    }
                }
                _ => {}
            }
        }

        let mut parents: HashMap<Uuid, String> = HashMap::new();
        let mut sorted_folders: Vec<Uuid> = changed_folders.into_iter().collect();
        sorted_folders.sort_by_key(format_swift_uuid);
        for id in sorted_folders {
            if self.db.folder(id)?.is_some() {
                let _ = self
                    .resolve_folder(id, layout, transport, &mut HashSet::new(), &mut parents)
                    .await?;
            }
        }

        let inventory: Option<SavedInventory> = self.db.state(&format!("{scope}.inventory"))?;
        let mut ordered_assets: Vec<Uuid> = visited_assets.into_iter().collect();
        ordered_assets.sort_by_key(format_swift_uuid);

        let mut listings: HashMap<String, Vec<RemoteDriveFile>> = HashMap::new();
        let mut taken_by_parent: HashMap<String, HashSet<String>> = HashMap::new();
        let mut uploaded_count = 0usize;
        let total_assets = ordered_assets.len().max(1);

        for asset_id in ordered_assets {
            let Some(asset) = self.db.asset(asset_id)? else {
                continue;
            };
            let remote = asset
                .drive_file_id
                .as_deref()
                .and_then(|did| inventory.as_ref().and_then(|inv| inv.files.get(did)));
            if remote.is_some() && !moved_assets.contains(&asset_id) {
                continue;
            }
            let parent = match asset.folder_id {
                Some(fid) => {
                    self.resolve_folder(fid, layout, transport, &mut HashSet::new(), &mut parents)
                        .await?
                }
                None => layout.inbox.clone(),
            };

            if let Some(remote_file) = remote {
                let rename = if original_name(remote_file) == asset.file_name {
                    None
                } else {
                    Some(asset.file_name.as_str())
                };
                if remote_file.parents.first().map(String::as_str) != Some(parent.as_str())
                    || rename.is_some()
                {
                    let moved = transport
                        .move_file(
                            &remote_file.id,
                            remote_file.parents.first().map(String::as_str),
                            &parent,
                            rename,
                        )
                        .await?;
                    if moved.id != remote_file.id {
                        if let Some(mut current) = self.db.asset(asset_id)? {
                            current.drive_file_id = Some(moved.id);
                            let _ = self.db.save_asset_locally(&current, false)?;
                        }
                    }
                }
                continue;
            }

            let needs_upload = asset.drive_file_id.is_none()
                || asset
                    .drive_file_id
                    .as_deref()
                    .is_some_and(|s| s.starts_with("mounted-"));
            if !needs_upload {
                continue;
            }
            let Some(local_path) = self.media.cached_original(&asset) else {
                continue;
            };

            if !listings.contains_key(&parent) {
                let entries = transport.list_files(&parent).await?;
                let taken: HashSet<String> =
                    entries.iter().map(|e| e.name.to_lowercase()).collect();
                taken_by_parent.insert(parent.clone(), taken);
                listings.insert(parent.clone(), entries);
            }

            let hash = MediaPipeline::digests(&local_path)?;
            let short_id = format_swift_uuid(&asset.id)[..8].to_lowercase();
            let preferred = &asset.file_name;
            let alt = conflict_file_name(preferred, &short_id, 1);

            let choices = listings.get(&parent).cloned().unwrap_or_default();
            let mut matched_remote = choices
                .iter()
                .find(|e| {
                    !e.is_folder()
                        && (e.name.eq_ignore_ascii_case(preferred)
                            || e.name.eq_ignore_ascii_case(&alt))
                        && e.md5_checksum.as_deref() == Some(hash.md5.as_str())
                })
                .cloned();

            let mut unbound = match matched_remote {
                Some(ref cand) => self.db.asset_by_drive_id(&cand.id)?.is_none(),
                None => false,
            };

            if matched_remote.is_none() || !unbound {
                for entry in &choices {
                    if entry.is_folder()
                        || entry.md5_checksum.is_some()
                        || entry.size != Some(hash.bytes)
                        || hash.bytes <= 0
                    {
                        continue;
                    }
                    if !(entry.name.eq_ignore_ascii_case(preferred)
                        || entry.name.eq_ignore_ascii_case(&alt))
                    {
                        continue;
                    }
                    if self.db.asset_by_drive_id(&entry.id)?.is_some() {
                        continue;
                    }
                    if self
                        .remote_file_matches_sha256(&entry.id, &hash.sha256, transport)
                        .await?
                    {
                        matched_remote = Some(entry.clone());
                        unbound = true;
                        break;
                    }
                }
            }

            if let Some(cand) = matched_remote.filter(|_| unbound) {
                self.bind_uploaded_asset(&asset, &cand)?;
                uploaded_count += 1;
                continue;
            }

            let taken = taken_by_parent.entry(parent.clone()).or_default();
            let reserved = next_available_file_name(preferred, &short_id, taken, 0);
            taken.insert(reserved.to_lowercase());

            let uploaded = self
                .upload_with_conflict_retry(
                    &local_path,
                    preferred,
                    &reserved,
                    &short_id,
                    &asset.mime_type,
                    &parent,
                    taken,
                    transport,
                )
                .await?;
            self.bind_uploaded_asset(&asset, &uploaded)?;
            listings.entry(parent.clone()).or_default().push(uploaded);
            uploaded_count += 1;

            self.update_progress(
                Some(SyncPhase::Uploading {
                    completed: uploaded_count,
                    total: total_assets,
                }),
                Some(format!("上传：{}", asset.file_name)),
                Some(0.62 + 0.19 * (uploaded_count as f64 / total_assets as f64)),
            )
            .await;
        }

        let compatible_removed_files: HashSet<String> = removed_files
            .into_iter()
            .filter(|id| {
                if is_mounted {
                    id.starts_with("mounted-")
                } else {
                    !id.starts_with("mounted-")
                }
            })
            .collect();
        for id in &compatible_removed_files {
            Self::trash_if_present(id, transport).await?;
        }

        let compatible_removed_folders: Vec<String> = removed_folders
            .into_iter()
            .filter(|id| {
                if is_mounted {
                    id.starts_with("mounted-")
                } else {
                    !id.starts_with("mounted-")
                }
            })
            .collect();
        for id in compatible_removed_folders {
            match transport.list_files(&id).await {
                Ok(children) if children.is_empty() => {
                    Self::trash_if_present(&id, transport).await?;
                }
                Ok(_) => {}
                Err(CoreError::NotFound(_))
                | Err(CoreError::Http {
                    status_code: 404, ..
                }) => {}
                Err(e) => return Err(e),
            }
        }

        Ok(compatible_removed_files)
    }

    fn bind_uploaded_asset(
        &self,
        asset: &AssetRecord,
        uploaded: &RemoteDriveFile,
    ) -> CoreResult<()> {
        let Some(mut current) = self.db.asset(asset.id)? else {
            self.db.record(
                SyncOperationChange::DeleteAsset {
                    id: asset.id,
                    drive_id: Some(uploaded.id.clone()),
                },
                true,
            )?;
            return Ok(());
        };
        current.drive_file_id = Some(uploaded.id.clone());
        if current.file_name == asset.file_name {
            current.file_name = uploaded.name.clone();
        }
        let _ = self.db.save_asset_locally(&current, false)?;
        Ok(())
    }

    #[allow(clippy::too_many_arguments)]
    async fn upload_with_conflict_retry(
        &self,
        local_path: &Path,
        preferred_name: &str,
        reserved_name: &str,
        short_id: &str,
        mime_type: &str,
        parent_id: &str,
        taken_names: &mut HashSet<String>,
        transport: &dyn DriveTransport,
    ) -> CoreResult<RemoteDriveFile> {
        for attempt in 0..8 {
            let remote_name = if attempt == 0 {
                reserved_name.to_string()
            } else {
                next_available_file_name(preferred_name, short_id, taken_names, attempt)
            };
            match transport
                .upload_file(local_path, &remote_name, mime_type, parent_id, None)
                .await
            {
                Ok(uploaded) => return Ok(uploaded),
                Err(CoreError::AlreadyExists(_)) => {
                    taken_names.insert(remote_name.to_lowercase());
                    if let Ok(fresh) = transport.list_files(parent_id).await {
                        for item in fresh {
                            taken_names.insert(item.name.to_lowercase());
                        }
                    }
                }
                Err(e) => return Err(e),
            }
        }
        Err(CoreError::AlreadyExists(preferred_name.to_string()))
    }

    fn resolve_folder<'a>(
        &'a self,
        id: Uuid,
        layout: &'a Layout,
        transport: &'a dyn DriveTransport,
        path: &'a mut HashSet<Uuid>,
        resolved: &'a mut HashMap<Uuid, String>,
    ) -> std::pin::Pin<Box<dyn std::future::Future<Output = CoreResult<String>> + Send + 'a>> {
        Box::pin(async move {
            if let Some(existing) = resolved.get(&id) {
                return Ok(existing.clone());
            }
            if !path.insert(id) {
                return Err(CoreError::InvalidPayload(
                    "Folder hierarchy contains a cycle.".to_string(),
                ));
            }
            let Some(folder) = self.db.folder(id)? else {
                path.remove(&id);
                return Ok(layout.inbox.clone());
            };
            let parent_remote = match folder.parent_id {
                Some(pid) => {
                    self.resolve_folder(pid, layout, transport, path, resolved)
                        .await?
                }
                None => layout.root.clone(),
            };
            path.remove(&id);

            let remote = if let Some(ref known) = folder.drive_folder_id {
                match transport
                    .move_file(known, None, &parent_remote, Some(&folder.name))
                    .await
                {
                    Ok(moved) => moved,
                    Err(CoreError::NotFound(_))
                    | Err(CoreError::Http {
                        status_code: 404, ..
                    }) => {
                        transport
                            .find_or_create_folder(&folder.name, &parent_remote)
                            .await?
                    }
                    Err(e) => return Err(e),
                }
            } else {
                transport
                    .find_or_create_folder(&folder.name, &parent_remote)
                    .await?
            };

            if let Some(mut current) = self.db.folder(id)? {
                if current.drive_folder_id.as_deref() != Some(remote.id.as_str()) {
                    current.drive_folder_id = Some(remote.id.clone());
                    if !remote.id.starts_with("mounted-") {
                        self.db
                            .record(SyncOperationChange::Folder(current.clone()), false)?;
                    }
                    self.db.upsert_folder(&current)?;
                }
            }
            resolved.insert(id, remote.id.clone());
            Ok(remote.id)
        })
    }

    async fn write_boards(
        &self,
        layout: &Layout,
        transport: &dyn DriveTransport,
        scope: &str,
        changed_boards: &HashSet<Uuid>,
    ) -> CoreResult<()> {
        let dirty: BTreeMap<String, String> =
            self.db.state("projection.boards")?.unwrap_or_default();
        let synced_key = format!("{scope}.boardsSynced");
        let initialized = self.db.state::<bool>(&synced_key)?.unwrap_or(false);
        if dirty.is_empty() && changed_boards.is_empty() && initialized {
            return Ok(());
        }

        let files = keyed_by_name(&transport.list_files(&layout.boards).await?);
        let documents = self.db.fetch_boards()?;
        let mut cleared = Vec::new();
        let mut active_ids = HashSet::new();

        for doc in &documents {
            let id_upper = format_swift_uuid(&doc.id);
            let name = format!("{}.json", id_upper.to_lowercase());
            let bytes = canonical_json_bytes(doc)?;
            let _ = Self::write_blob(
                &bytes,
                &name,
                "application/json",
                &layout.boards,
                files.get(&name),
                transport,
                true,
            )
            .await?;
            if let Some(ver) = dirty.get(&id_upper) {
                cleared.push((id_upper.clone(), ver.clone()));
            }
            active_ids.insert(id_upper);
        }

        for (id_upper, ver) in &dirty {
            if !active_ids.contains(id_upper) {
                let name = format!("{}.json", id_upper.to_lowercase());
                if let Some(remote) = files.get(&name) {
                    Self::trash_if_present(&remote.id, transport).await?;
                }
                cleared.push((id_upper.clone(), ver.clone()));
            }
        }

        self.db.clear_projections("boards", &cleared)?;
        self.db.set_state(&synced_key, Some(&true))?;
        Ok(())
    }

    async fn sync_thumbnails(
        &self,
        layout: &Layout,
        transport: &dyn DriveTransport,
        scope: &str,
        prefetched: Option<&HashMap<String, RemoteDriveFile>>,
    ) -> CoreResult<()> {
        let fetched_owned;
        let files = match prefetched {
            Some(map) => map,
            None => {
                fetched_owned = keyed_by_name(&transport.list_files(&layout.thumbnails).await?);
                &fetched_owned
            }
        };

        let dirty: BTreeMap<String, String> =
            self.db.state("projection.thumbnails")?.unwrap_or_default();

        // 1. Upload or remove dirty local thumbnails
        let mut cleared = Vec::new();
        for (id_upper, ver) in &dirty {
            let Ok(uuid) = Uuid::parse_str(id_upper) else {
                continue;
            };
            let name = format!("{}.jpg", id_upper.to_lowercase());
            let asset_exists = self.db.asset(uuid)?.is_some();
            if asset_exists {
                if let Some(local_path) = self.media.thumbnail_url(uuid, ThumbnailTier::Grid520) {
                    let bytes = fs::read(local_path)?;
                    let _ = Self::write_blob(
                        &bytes,
                        &name,
                        "image/jpeg",
                        &layout.thumbnails,
                        files.get(&name),
                        transport,
                        true,
                    )
                    .await?;
                }
            } else if let Some(remote) = files.get(&name) {
                Self::trash_if_present(&remote.id, transport).await?;
            }
            cleared.push((id_upper.clone(), ver.clone()));
        }
        self.db.clear_projections("thumbnails", &cleared)?;

        // 2. Download missing or updated remote thumbnails
        let stamps_key = format!("{scope}.thumbnails");
        let mut stamps: BTreeMap<String, String> = self.db.state(&stamps_key)?.unwrap_or_default();
        let mut stamps_dirty = false;

        for (name, file) in files {
            if file.is_folder() {
                continue;
            }
            let Some(stem) = name.strip_suffix(".jpg") else {
                continue;
            };
            let Ok(uuid) = Uuid::parse_str(stem) else {
                continue;
            };
            let id_upper = format_swift_uuid(&uuid);
            if dirty.contains_key(&id_upper) || self.db.asset(uuid)?.is_none() {
                continue;
            }
            let stamp = file.md5_checksum.clone().unwrap_or_else(|| {
                format!(
                    "{}{}",
                    file.id,
                    file.modified_time.map(|t| t.timestamp()).unwrap_or(0)
                )
            });

            if let Some(local_path) = self.media.thumbnail_url(uuid, ThumbnailTier::Grid520) {
                if stamps.get(&id_upper).map(String::as_str) == Some(stamp.as_str()) {
                    continue;
                }
                if let Some(ref remote_md5) = file.md5_checksum {
                    if let Ok(local_data) = fs::read(&local_path) {
                        if hex::encode(Md5::digest(&local_data)) == *remote_md5 {
                            stamps.insert(id_upper, stamp);
                            stamps_dirty = true;
                            continue;
                        }
                    }
                }
            }

            let data = transport.download_data(&file.id).await?;
            self.media
                .write_thumbnail_bytes(uuid, ThumbnailTier::Grid520, &data)?;
            stamps.insert(id_upper, stamp);
            stamps_dirty = true;
        }

        if stamps_dirty {
            self.db.set_state(&stamps_key, Some(&stamps))?;
        }
        Ok(())
    }

    async fn remote_file_matches_sha256(
        &self,
        file_id: &str,
        expected_sha256: &str,
        transport: &dyn DriveTransport,
    ) -> CoreResult<bool> {
        let probe = self
            .media
            .staging
            .join(format!("verify-{}", Uuid::new_v4().simple()));
        let res = async {
            transport.download_file(file_id, &probe).await?;
            Ok::<bool, CoreError>(MediaPipeline::digests(&probe)?.sha256 == expected_sha256)
        }
        .await;
        let _ = fs::remove_file(&probe);
        res
    }

    async fn write_blob(
        data: &[u8],
        name: &str,
        mime: &str,
        parent: &str,
        existing: Option<&RemoteDriveFile>,
        transport: &dyn DriveTransport,
        allow_overwrite_existing: bool,
    ) -> CoreResult<RemoteDriveFile> {
        if let Some(ex) = existing {
            if let Some(ref checksum) = ex.md5_checksum {
                if hex::encode(Md5::digest(data)) == *checksum {
                    return Ok(ex.clone());
                }
            } else if transport.download_data(&ex.id).await.ok().as_deref() == Some(data) {
                return Ok(ex.clone());
            }
        }
        match transport
            .upload_data(data, name, mime, parent, existing.map(|e| e.id.as_str()))
            .await
        {
            Ok(uploaded) => Ok(uploaded),
            Err(err) => {
                if existing.is_none() {
                    if let Ok(entries) = transport.list_files(parent).await {
                        if let Some(concurrent) = entries
                            .into_iter()
                            .find(|f| f.name.eq_ignore_ascii_case(name))
                        {
                            if transport
                                .download_data(&concurrent.id)
                                .await
                                .ok()
                                .as_deref()
                                == Some(data)
                            {
                                return Ok(concurrent);
                            }
                            if allow_overwrite_existing {
                                return transport
                                    .upload_data(
                                        data,
                                        &concurrent.name,
                                        mime,
                                        parent,
                                        Some(&concurrent.id),
                                    )
                                    .await;
                            }
                        }
                    }
                }
                Err(err)
            }
        }
    }

    async fn trash_if_present(file_id: &str, transport: &dyn DriveTransport) -> CoreResult<()> {
        match transport.trash_file(file_id).await {
            Ok(()) => Ok(()),
            Err(CoreError::NotFound(_))
            | Err(CoreError::Http {
                status_code: 404 | 403,
                ..
            }) => Ok(()),
            Err(e) => Err(e),
        }
    }
}

enum RemoteIngestOutcome {
    Saved {
        saved: Box<AssetRecord>,
        had_existing: bool,
        previous_file_name: Option<String>,
        previous_folder_id: Option<Uuid>,
    },
    Skipped,
    DeletedLocally,
}

/// Lossless two-way storage backend migration (Pure Local Folder <-> Google Drive <-> WebDAV).
pub struct StorageMigration;

impl StorageMigration {
    /// Downloads any missing cached originals from `source_transport`, validates `target_transport`,
    /// re-queues the authoritative local library, switches `driveConfig`, and runs a full sync.
    pub async fn migrate_storage(
        db: &Arc<LibraryDatabase>,
        media: &MediaPipeline,
        sync_engine: &DriveSyncEngine,
        source_config: &DriveSyncConfig,
        source_transport: Option<&dyn DriveTransport>,
        target_config: &DriveSyncConfig,
        target_transport: &dyn DriveTransport,
    ) -> CoreResult<StorageMigrationReport> {
        let start = Instant::now();

        validate_path_segments(&target_config.root_folder_name)?;
        if !target_config.webdav_remote_path.trim().is_empty() {
            validate_path_segments(&target_config.webdav_remote_path)?;
        }

        // 1. Validate target backend reachability FIRST before mutating local DB
        let _ = target_transport.account_info().await?;

        // 2. Ensure ALL non-trashed originals are locally downloaded before detaching from source
        let mut downloaded_originals = 0usize;
        if source_config.mode != DriveTransportMode::LocalOnly {
            let active_assets = db.fetch_assets(
                &FilterCriteria {
                    include_trashed: false,
                    ..FilterCriteria::default()
                },
                None,
            )?;
            let uncached: Vec<AssetRecord> = active_assets
                .into_iter()
                .filter(|a| a.drive_file_id.is_some() && media.cached_original(a).is_none())
                .collect();
            if !uncached.is_empty() {
                let src = source_transport.ok_or_else(|| {
                    CoreError::NotConfigured(
                        "迁移前需要连接旧云端存储以下载尚未缓存的原始文件。".to_string(),
                    )
                })?;
                for asset in uncached {
                    let _ = sync_engine.download_original(asset.id, src).await?;
                    downloaded_originals += 1;
                }
            }
        }

        // 3. Re-queue the entire authoritative local library cleanly for the new backend
        let counts = db.requeue_library_for_backend_migration(
            target_config.sync_thumbnails,
            target_config.sync_embeddings,
        )?;

        // 4. Persist target config and immediately sync all folders, originals, and boards
        db.set_state("driveConfig", Some(target_config))?;
        let _ = sync_engine
            .sync(target_transport, target_config, true)
            .await?;

        if target_config.mode != DriveTransportMode::LocalOnly {
            let _ = media.cache_stats_and_evict(db, true, &HashSet::new(), None)?;
        }

        Ok(StorageMigrationReport {
            source_mode: source_config.mode,
            target_mode: target_config.mode,
            target_location: target_config.active_storage_location_summary(),
            downloaded_originals,
            migrated_assets: counts.assets,
            migrated_folders: counts.folders,
            migrated_boards: counts.boards,
            duration_seconds: start.elapsed().as_secs_f64(),
        })
    }
}

pub fn validate_path_segments(raw: &str) -> CoreResult<()> {
    for seg in raw.split('/').map(str::trim).filter(|s| !s.is_empty()) {
        validate_drive_name(seg)?;
    }
    Ok(())
}

fn oldest_subfolder(name: &str, files: &[RemoteDriveFile]) -> Option<RemoteDriveFile> {
    files
        .iter()
        .filter(|f| f.is_folder() && f.name == name)
        .min_by(|a, b| {
            let ta: DateTime<Utc> = a.modified_time.unwrap_or(DateTime::<Utc>::UNIX_EPOCH);
            let tb: DateTime<Utc> = b.modified_time.unwrap_or(DateTime::<Utc>::UNIX_EPOCH);
            ta.cmp(&tb).then_with(|| a.id.cmp(&b.id))
        })
        .cloned()
}

fn keyed_by_name(files: &[RemoteDriveFile]) -> HashMap<String, RemoteDriveFile> {
    let mut non_folders: Vec<&RemoteDriveFile> = files.iter().filter(|f| !f.is_folder()).collect();
    non_folders.sort_by(|a, b| {
        let ta = a.modified_time.unwrap_or(DateTime::<Utc>::UNIX_EPOCH);
        let tb = b.modified_time.unwrap_or(DateTime::<Utc>::UNIX_EPOCH);
        tb.cmp(&ta).then_with(|| b.id.cmp(&a.id))
    });
    let mut map = HashMap::new();
    for f in non_folders {
        map.entry(f.name.clone()).or_insert_with(|| f.clone());
    }
    map
}

fn is_visible(file: &RemoteDriveFile, layout: &Layout) -> bool {
    if file.trashed || file.id == layout.metadata || file.name.starts_with('.') {
        return false;
    }
    if NON_EXPORTABLE_GOOGLE_MIMES.contains(&file.mime_type.as_str()) {
        return false;
    }
    let lower = file.name.to_lowercase();
    if IGNORED_JUNK_NAMES.contains(&lower.as_str()) {
        return false;
    }
    if !file.is_folder() {
        let ext = Path::new(&lower)
            .extension()
            .and_then(|e| e.to_str())
            .unwrap_or("");
        if IGNORED_TEMP_EXTENSIONS.contains(&ext) {
            return false;
        }
    }
    true
}

fn is_likely_incomplete_zero_byte_media(file: &RemoteDriveFile) -> bool {
    if file.is_folder() || file.size != Some(0) {
        return false;
    }
    let ext = Path::new(&file.name)
        .extension()
        .and_then(|e| e.to_str())
        .unwrap_or("")
        .to_ascii_lowercase();
    BINARY_MEDIA_EXTENSIONS.contains(&ext.as_str())
}

fn is_fatal_sync_error(err: &CoreError) -> bool {
    matches!(
        err,
        CoreError::AuthenticationRequired(_)
            | CoreError::MountPathUnavailable(_)
            | CoreError::GDirectNotFound
            | CoreError::NotConfigured(_)
            | CoreError::Network(_)
    )
}

fn content_changed(before: Option<&RemoteDriveFile>, after: &RemoteDriveFile) -> bool {
    let Some(prev) = before else {
        return false;
    };
    if prev == after {
        return false;
    }
    if let (Some(a), Some(b)) = (&prev.md5_checksum, &after.md5_checksum) {
        return a != b;
    }
    if let (Some(a), Some(b)) = (prev.size, after.size) {
        if a != b {
            return true;
        }
    }
    prev.name == after.name
        && prev.parents == after.parents
        && prev.modified_time != after.modified_time
}

fn original_name(file: &RemoteDriveFile) -> String {
    if file.mime_type.starts_with("application/vnd.google-apps.")
        && !file.name.to_ascii_lowercase().ends_with(".pdf")
    {
        format!("{}.pdf", file.name)
    } else {
        file.name.clone()
    }
}

fn file_stem_or_full(name: &str) -> String {
    Path::new(name)
        .file_stem()
        .and_then(|s| s.to_str())
        .filter(|s| !s.is_empty())
        .unwrap_or(name)
        .to_string()
}

fn conflict_file_name(preferred: &str, short_id: &str, index: usize) -> String {
    let stem = file_stem_or_full(preferred);
    let ext = Path::new(preferred)
        .extension()
        .and_then(|e| e.to_str())
        .unwrap_or("");
    let suffix = if ext.is_empty() {
        String::new()
    } else {
        format!(".{ext}")
    };
    if index <= 1 {
        format!("{stem}-{short_id}{suffix}")
    } else {
        format!("{stem}-{short_id}-{index}{suffix}")
    }
}

fn next_available_file_name(
    preferred: &str,
    short_id: &str,
    taken_lower: &HashSet<String>,
    start_index: usize,
) -> String {
    if start_index == 0 && !taken_lower.contains(&preferred.to_lowercase()) {
        return preferred.to_string();
    }
    let first_alt = conflict_file_name(preferred, short_id, 1);
    if start_index <= 1 && !taken_lower.contains(&first_alt.to_lowercase()) {
        return first_alt;
    }
    let mut counter = start_index.max(2);
    while counter < 10_000 {
        let candidate = conflict_file_name(preferred, short_id, counter);
        if !taken_lower.contains(&candidate.to_lowercase()) {
            return candidate;
        }
        counter += 1;
    }
    let random_short = &Uuid::new_v4().simple().to_string()[..8];
    conflict_file_name(preferred, random_short, 1)
}
