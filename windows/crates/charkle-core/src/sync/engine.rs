//! Bidirectional `/.charkle/` CRDT sync engine and lossless two-way `StorageMigration`.
//!
//! Mirrors `Sources/CharkleCore/Sync/DriveSyncEngine.swift` and
//! `LiveCharkleEngine.migrateLibraryStorage` with full macOS / Web wire compatibility.

use std::collections::{BTreeMap, HashMap, HashSet};
use std::fs;
use std::future::Future;
use std::path::{Path, PathBuf};
use std::pin::Pin;
use std::sync::Arc;
use std::task::Poll;
use std::time::{Duration, Instant};

use chrono::{DateTime, Utc};
use image::codecs::jpeg::JpegEncoder;
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
    DeletedAssetFingerprint, DeletedFolderFingerprint, DriveAccountInfo, DriveSyncConfig,
    DriveTransportMode, RemoteDriveFile, StorageMigrationReport, SyncBackendProfile,
    SyncBackendStatus, SyncLogLine, SyncManifest, SyncOperation, SyncOperationChange, SyncPhase,
    SyncReport, SyncStatus,
};
use crate::sync::icloud_drive::ICLOUD_PATH_ID_PREFIX;
use crate::sync::local_folder::MOUNTED_PATH_ID_PREFIX;
use crate::sync::transport::{
    sanitize_windows_filename, validate_drive_name, DriveTransport, DRIVE_ROOT_ID,
};
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

/// Progressive UI hydration notifications emitted during cloud sync so fresh installs
/// paint folders, metadata, and newest-first thumbnails within seconds.
#[derive(Debug, Clone)]
pub enum SyncProgressiveEvent {
    Metadata { has_boards: bool },
    Thumbnails { asset_ids: Vec<Uuid> },
}

/// Execution options for single- or multi-backend sync cycles.
#[derive(Debug, Clone)]
pub struct SyncExecutionOptions {
    pub backend_id: Option<Uuid>,
    pub is_primary_backend: bool,
    pub defer_op_pruning: bool,
    pub progress_prefix: Option<String>,
}

impl Default for SyncExecutionOptions {
    fn default() -> Self {
        Self {
            backend_id: None,
            is_primary_backend: true,
            defer_op_pruning: false,
            progress_prefix: None,
        }
    }
}

type StatusCallback = Arc<dyn Fn(SyncStatus) + Send + Sync>;
type ProgressiveCallback = Arc<dyn Fn(SyncProgressiveEvent) + Send + Sync>;

/// Safe sliding-window bounded concurrency executor over borrowed async futures (zero `unsafe`,
/// zero `'static` requirement, saturates HTTP/2 connection pools cleanly).
async fn run_bounded_stream<'a, I, T, F, Fut, C>(
    items: Vec<I>,
    max_concurrent: usize,
    mut make_fut: F,
    mut on_complete: C,
) where
    F: FnMut(I) -> Fut,
    Fut: Future<Output = T> + 'a,
    C: FnMut(T),
{
    let limit = max_concurrent.max(1);
    let mut iter = items.into_iter();
    let mut in_flight: Vec<Pin<Box<Fut>>> = Vec::with_capacity(limit);

    std::future::poll_fn(|cx| loop {
        while in_flight.len() < limit {
            if let Some(item) = iter.next() {
                in_flight.push(Box::pin(make_fut(item)));
            } else {
                break;
            }
        }

        if in_flight.is_empty() {
            return Poll::Ready(());
        }

        let mut made_progress = false;
        let mut idx = 0;
        while idx < in_flight.len() {
            match in_flight[idx].as_mut().poll(cx) {
                Poll::Ready(val) => {
                    in_flight.swap_remove(idx);
                    on_complete(val);
                    made_progress = true;
                }
                Poll::Pending => {
                    idx += 1;
                }
            }
        }

        if !made_progress {
            return Poll::Pending;
        }
    })
    .await;
}

async fn run_bounded<'a, I, T, F, Fut>(items: Vec<I>, max_concurrent: usize, make_fut: F) -> Vec<T>
where
    F: FnMut(I) -> Fut,
    Fut: Future<Output = T> + 'a,
{
    let mut out = Vec::with_capacity(items.len());
    run_bounded_stream(items, max_concurrent, make_fut, |val| out.push(val)).await;
    out
}

fn concurrency_limit(transport: &dyn DriveTransport, direct_default: usize) -> usize {
    transport.concurrency_limit(direct_default)
}

/// Validates raw image bytes returned by a server-side thumbnail endpoint (`thumbnailLink`)
/// and normalizes them into a compact `<= max_pixel` JPEG for `.grid520` caching.
fn normalized_thumbnail_jpeg(raw: &[u8], max_pixel: u32) -> Option<Vec<u8>> {
    if raw.is_empty() {
        return None;
    }
    let decoded = image::load_from_memory(raw).ok()?;
    let target = max_pixel.clamp(200, 1024);
    let resized = if decoded.width() > target || decoded.height() > target {
        decoded.thumbnail(target, target)
    } else {
        decoded
    };
    let rgb = resized.to_rgb8();
    let mut out = Vec::with_capacity(24 * 1024);
    let mut encoder = JpegEncoder::new_with_quality(&mut out, 84);
    encoder.encode_image(&rgb).ok()?;
    (!out.is_empty()).then_some(out)
}

/// Asynchronous bidirectional `/.charkle/` sync engine.
pub struct DriveSyncEngine {
    db: Arc<LibraryDatabase>,
    media: MediaPipeline,
    status: Arc<RwLock<SyncStatus>>,
    active_progress_prefix: Arc<RwLock<Option<String>>>,
    run_guard: Arc<Mutex<()>>,
    on_status: Option<StatusCallback>,
    on_progressive: Option<ProgressiveCallback>,
}

impl DriveSyncEngine {
    pub fn new(db: Arc<LibraryDatabase>, media: MediaPipeline) -> Self {
        Self {
            db,
            media,
            status: Arc::new(RwLock::new(SyncStatus::default())),
            active_progress_prefix: Arc::new(RwLock::new(None)),
            run_guard: Arc::new(Mutex::new(())),
            on_status: None,
            on_progressive: None,
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
            active_progress_prefix: Arc::new(RwLock::new(None)),
            run_guard: Arc::new(Mutex::new(())),
            on_status: Some(on_status),
            on_progressive: None,
        }
    }

    pub fn with_callbacks(
        db: Arc<LibraryDatabase>,
        media: MediaPipeline,
        on_status: StatusCallback,
        on_progressive: ProgressiveCallback,
    ) -> Self {
        Self {
            db,
            media,
            status: Arc::new(RwLock::new(SyncStatus::default())),
            active_progress_prefix: Arc::new(RwLock::new(None)),
            run_guard: Arc::new(Mutex::new(())),
            on_status: Some(on_status),
            on_progressive: Some(on_progressive),
        }
    }

    fn notify_progressive_metadata(&self, has_boards: bool) {
        if let Some(ref cb) = self.on_progressive {
            cb(SyncProgressiveEvent::Metadata { has_boards });
        }
    }

    fn notify_progressive_thumbnails(&self, asset_ids: Vec<Uuid>) {
        if asset_ids.is_empty() {
            return;
        }
        if let Some(ref cb) = self.on_progressive {
            cb(SyncProgressiveEvent::Thumbnails { asset_ids });
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

    /// Synchronously clears any in-memory `account` that does not belong to `active_mode`
    /// when switching storage modes (e.g. `LocalOnly` -> `DirectApiWithGDirect`).
    pub fn clear_mismatched_account_if_idle(&self, active_mode: DriveTransportMode) {
        if let Ok(mut guard) = self.status.try_write() {
            if matches!(guard.phase, SyncPhase::Idle | SyncPhase::Error(_)) {
                guard.active_mode = active_mode;
                if let Some(ref account) = guard.account {
                    if !account.matches_mode(active_mode) {
                        guard.account = None;
                    }
                }
            }
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

    #[allow(clippy::too_many_arguments)]
    pub async fn update_backend_statuses(
        &self,
        statuses: Vec<SyncBackendStatus>,
        active_mode: Option<DriveTransportMode>,
        phase: Option<SyncPhase>,
        detail: Option<Option<String>>,
        progress: Option<Option<f64>>,
        last_error: Option<Option<String>>,
        mark_synced_now: bool,
    ) {
        let pending = self.db.pending_op_count().unwrap_or(0);
        let snapshot = {
            let mut s = self.status.write().await;
            s.backend_statuses = statuses;
            if let Some(m) = active_mode {
                s.active_mode = m;
            }
            if let Some(p) = phase {
                s.phase = p;
            }
            if let Some(d) = detail {
                s.current_detail = d;
            }
            if let Some(pr) = progress {
                s.progress_fraction = pr.map(|v| v.clamp(0.0, 1.0));
            }
            if let Some(err) = last_error {
                s.last_error = err;
            }
            if mark_synced_now {
                s.last_synced_at = Some(Utc::now());
            }
            s.pending_op_count = pending;
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
        let prefix = self.active_progress_prefix.read().await.clone();
        let formatted_detail = match (prefix, detail) {
            (Some(pfx), Some(msg)) if !pfx.is_empty() && !msg.is_empty() => {
                Some(format!("{pfx} {msg}"))
            }
            (_, msg) => msg,
        };
        let snapshot = {
            let mut s = self.status.write().await;
            if let Some(p) = phase {
                s.phase = p;
            }
            s.current_detail = formatted_detail;
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
        self.sync_with_options(
            transport,
            config,
            allow_local_folder_sync,
            SyncExecutionOptions::default(),
        )
        .await
    }

    /// Executes one bidirectional sync cycle with multi-backend execution options.
    pub async fn sync_with_options(
        &self,
        transport: &dyn DriveTransport,
        config: &DriveSyncConfig,
        allow_local_folder_sync: bool,
        options: SyncExecutionOptions,
    ) -> CoreResult<SyncReport> {
        if config.mode == DriveTransportMode::LocalOnly && !allow_local_folder_sync {
            return Ok(SyncReport::default());
        }

        let _lock = self.run_guard.try_lock().map_err(|_| {
            CoreError::NotConfigured("当前已有同步任务正在运行，请稍候。".to_string())
        })?;

        *self.active_progress_prefix.write().await = options.progress_prefix.clone();

        let result = if !options.is_primary_backend {
            self.sync_secondary_backend(transport, config, &options)
                .await
        } else {
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
            match self.run_sync_inner(transport, config, &options).await {
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
        };

        *self.active_progress_prefix.write().await = None;
        result
    }

    async fn run_sync_inner(
        &self,
        transport: &dyn DriveTransport,
        config: &DriveSyncConfig,
        options: &SyncExecutionOptions,
    ) -> CoreResult<SyncReport> {
        let shared_root_id = if config.mode == DriveTransportMode::DirectApiWithGDirect {
            config.resolved_shared_folder_id()
        } else {
            None
        };
        let root_path = Self::resolved_root_path(config);
        let op_cursor_key = options
            .backend_id
            .map(|id| format!("backend.opCursor.{}", format_swift_uuid(&id)));

        self.update_progress(
            Some(SyncPhase::Scanning),
            Some(format!(
                "正在连接{}并检查目录…",
                config.mode.localized_label()
            )),
            Some(0.06),
        )
        .await;

        let (account, (layout, existing_manifest)) = tokio::try_join!(
            transport.account_info(),
            self.make_layout(transport, &root_path, shared_root_id.as_deref()),
        )?;
        {
            let mut s = self.status.write().await;
            s.account = Some(account.clone());
        }

        let scope_prefix = match options.backend_id {
            Some(bid) if bid != SyncBackendProfile::LEGACY_PRIMARY_ID => {
                format!("remote.backend.{}.", format_swift_uuid(&bid))
            }
            _ => "remote.".to_string(),
        };
        let scope = format!(
            "{scope_prefix}{}",
            format_swift_uuid(&stable_uuid(&format!(
                "{}:{}:{}",
                transport.display_name(),
                account.email,
                layout.root
            )))
        );

        let mut report = SyncReport::default();

        self.update_progress(
            Some(SyncPhase::Downloading {
                completed: 0,
                total: 0,
            }),
            Some("正在并行拉取元数据与目录结构…".to_string()),
            Some(0.12),
        )
        .await;

        // Run folder inventory crawl concurrently alongside Stage 1 (manifest + thumbnail list +
        // parallel ops pull) AND Stage 2 (newest-first 12-way thumbnail hydration) so a fresh
        // install surfaces folders, metadata, and crisp top-of-gallery thumbnails within seconds.
        let inventory_fut =
            self.fetch_inventory(&layout, transport, &scope, shared_root_id.is_some());
        let stage12_fut = async {
            let (manifest_res, remote_thumbs_res, pulled_res) = tokio::join!(
                self.update_manifest(&layout, existing_manifest.as_ref(), &scope, transport),
                async {
                    if config.sync_thumbnails {
                        Ok(keyed_by_name(
                            &transport.list_files(&layout.thumbnails).await?,
                        ))
                    } else {
                        Ok::<HashMap<String, RemoteDriveFile>, CoreError>(HashMap::new())
                    }
                },
                self.pull_ops(&layout, transport, &scope, config.sync_embeddings),
            );
            manifest_res?;
            let remote_thumbnails = remote_thumbs_res?;
            let (pulled_count, changed_boards) = pulled_res?;
            if pulled_count > 0 {
                // Immediately surface folders, tags, titles, dimensions, dominant colors, and
                // moodboards in the UI before waiting on inventory crawls or any original bytes.
                self.notify_progressive_metadata(!changed_boards.is_empty());
            }

            // Stage 2 (Thumbnail-First Fast Hydration): download missing remote thumbnails BEFORE
            // reconcile's heavy original downloads, uploads, or pinned-original fetches.
            let (prefetched_stamps, stage2_thumb_count) =
                if config.sync_thumbnails && !remote_thumbnails.is_empty() {
                    let (stamps, dl_count) = self
                        .download_missing_remote_thumbnails(
                            &remote_thumbnails,
                            None,
                            &scope,
                            transport,
                            0.22,
                            0.22,
                            None,
                        )
                        .await?;
                    (Some(stamps), dl_count)
                } else {
                    (None, 0)
                };

            Ok::<_, CoreError>((
                remote_thumbnails,
                pulled_count,
                changed_boards,
                prefetched_stamps,
                stage2_thumb_count,
            ))
        };

        let (inventory_res, stage12_res) = tokio::join!(inventory_fut, stage12_fut);
        let inventory = inventory_res?;
        let (
            remote_thumbnails,
            pulled_count,
            mut changed_boards,
            prefetched_stamps,
            stage2_thumb_count,
        ) = stage12_res?;

        report.downloaded_ops += pulled_count;
        report.downloaded_thumbnails += stage2_thumb_count;

        let cursor_seq: i64 = if options.defer_op_pruning {
            op_cursor_key
                .as_deref()
                .and_then(|k| self.db.state::<i64>(k).ok().flatten())
                .unwrap_or(0)
        } else {
            0
        };
        let pending = if options.defer_op_pruning {
            self.db
                .pending_ops_after::<SyncOperation>(cursor_seq, 10_000)?
        } else {
            self.db.pending_ops::<SyncOperation>(10_000)?
        };
        {
            let mut s = self.status.write().await;
            s.pending_op_count = pending.len();
        }

        self.update_progress(
            Some(SyncPhase::Merging),
            Some("正在比对云端与本地目录…".to_string()),
            Some(0.46),
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
                Some(0.68),
            )
            .await;

            let ops_only: Vec<SyncOperation> = pending.iter().map(|(_, op)| op.clone()).collect();
            let (removed_by_upload, removed_folders_by_upload) = self
                .upload_physical(&ops_only, &layout, transport, &scope)
                .await?;
            if !removed_by_upload.is_empty() || !removed_folders_by_upload.is_empty() {
                for id in &removed_by_upload {
                    saved_files.remove(id);
                }
                for id in &removed_folders_by_upload {
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
        let ready = if options.defer_op_pruning {
            self.db
                .pending_ops_after::<SyncOperation>(cursor_seq, 10_000)?
        } else {
            self.db.pending_ops::<SyncOperation>(10_000)?
        };
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
                .push_ops(
                    &publishable,
                    transport,
                    &layout,
                    config.sync_embeddings,
                    options.defer_op_pruning,
                    op_cursor_key.as_deref(),
                )
                .await?;

            let (pulled_after, boards_after) = self
                .pull_ops(&layout, transport, &scope, config.sync_embeddings)
                .await?;
            report.downloaded_ops += pulled_after;
            changed_boards.extend(boards_after);
        } else if options.defer_op_pruning {
            if let Some(ref key) = op_cursor_key {
                let latest_seq = self.db.max_pending_op_seq().unwrap_or(cursor_seq);
                if latest_seq > cursor_seq {
                    let _ = self.db.set_state(key, Some(&latest_seq));
                }
            }
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
            self.upload_dirty_thumbnails(&layout, transport, Some(&remote_thumbnails))
                .await?;
            let (_, straggler_count) = self
                .download_missing_remote_thumbnails(
                    &remote_thumbnails,
                    None,
                    &scope,
                    transport,
                    0.91,
                    0.03,
                    prefetched_stamps,
                )
                .await?;
            report.downloaded_thumbnails += straggler_count;
        }

        if report.discovered_remote_assets > 0
            || report.reconciled_renames > 0
            || !changed_boards.is_empty()
        {
            self.notify_progressive_metadata(!changed_boards.is_empty());
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

    /// Non-clobbering bidirectional mirror sync for simultaneously connected secondary backends
    /// (e.g. iCloud Drive or WebDAV running alongside primary Google Drive).
    /// Keeps its own per-backend remote folder/asset ID maps and op cursor so primary `driveFileID`
    /// bindings are never overwritten and local changes & deletions fan out cleanly across all backends.
    async fn sync_secondary_backend(
        &self,
        transport: &dyn DriveTransport,
        config: &DriveSyncConfig,
        options: &SyncExecutionOptions,
    ) -> CoreResult<SyncReport> {
        let backend_id = options.backend_id.unwrap_or_else(Uuid::new_v4);
        let backend_id_str = format_swift_uuid(&backend_id);
        let start = Instant::now();
        let op_cursor_key = format!("backend.opCursor.{backend_id_str}");
        let remote_assets_key = format!("backend.remoteAssets.{backend_id_str}");
        let remote_folders_key = format!("backend.remoteFolders.{backend_id_str}");

        self.update_progress(
            Some(SyncPhase::Scanning),
            Some(format!("正在连接{}…", config.mode.localized_label())),
            Some(0.08),
        )
        .await;

        let shared_root_id = if config.mode == DriveTransportMode::DirectApiWithGDirect {
            config.resolved_shared_folder_id()
        } else {
            None
        };
        let root_path = Self::resolved_root_path(config);

        let (account, (layout, existing_manifest)) = tokio::try_join!(
            transport.account_info(),
            self.make_layout(transport, &root_path, shared_root_id.as_deref()),
        )?;
        let scope = format!(
            "remote.backend.{backend_id_str}.{}",
            format_swift_uuid(&stable_uuid(&format!(
                "{}:{}:{}",
                transport.display_name(),
                account.email,
                layout.root
            )))
        );

        let mut report = SyncReport::default();
        self.update_manifest(&layout, existing_manifest.as_ref(), &scope, transport)
            .await?;

        // 1. Pull remote metadata ops & missing thumbnails from this secondary backend
        self.update_progress(
            Some(SyncPhase::Downloading {
                completed: 0,
                total: 0,
            }),
            Some("拉取增量元数据与缩略图…".to_string()),
            Some(0.20),
        )
        .await;
        let (pulled_count, mut changed_boards) = self
            .pull_ops(&layout, transport, &scope, config.sync_embeddings)
            .await?;
        report.downloaded_ops += pulled_count;
        if pulled_count > 0 {
            self.notify_progressive_metadata(!changed_boards.is_empty());
        }

        let remote_thumbnails: HashMap<String, RemoteDriveFile> = if config.sync_thumbnails {
            keyed_by_name(&transport.list_files(&layout.thumbnails).await?)
        } else {
            HashMap::new()
        };
        let prefetched_stamps = if config.sync_thumbnails && !remote_thumbnails.is_empty() {
            let (stamps, dl_count) = self
                .download_missing_remote_thumbnails(
                    &remote_thumbnails,
                    None,
                    &scope,
                    transport,
                    0.25,
                    0.15,
                    None,
                )
                .await?;
            report.downloaded_thumbnails += dl_count;
            Some(stamps)
        } else {
            None
        };

        // 2. Load isolated secondary remote folder & asset maps
        let mut remote_folders: HashMap<String, String> =
            self.db.state(&remote_folders_key)?.unwrap_or_default();
        let mut remote_assets: HashMap<String, String> =
            self.db.state(&remote_assets_key)?.unwrap_or_default();

        let all_folders = self.db.fetch_folders()?;
        let folders_by_id: HashMap<Uuid, FolderRecord> =
            all_folders.iter().cloned().map(|f| (f.id, f)).collect();
        let existing_asset_ids = self.db.existing_asset_ids()?;

        // 2a. Propagate permanent asset deletions to this secondary backend
        let mut stale_asset_keys: Vec<(String, String)> = Vec::new();
        for (asset_id_str, remote_file_id) in &remote_assets {
            let still_exists = Uuid::parse_str(asset_id_str)
                .ok()
                .is_some_and(|uid| existing_asset_ids.contains(&uid));
            if !still_exists {
                stale_asset_keys.push((asset_id_str.clone(), remote_file_id.clone()));
            }
        }
        if !stale_asset_keys.is_empty() {
            let trash_concurrency = concurrency_limit(transport, 4);
            let trash_results = run_bounded(
                stale_asset_keys.clone(),
                trash_concurrency,
                |(_, remote_id)| async move {
                    if transport.accepts_remote_id(&remote_id) {
                        Self::trash_if_present(&remote_id, transport).await?;
                    }
                    Ok::<(), CoreError>(())
                },
            )
            .await;
            for res in trash_results {
                res?;
            }
            for (key, _) in stale_asset_keys {
                remote_assets.remove(&key);
            }
        }

        // 2b. Propagate deleted folders to this secondary backend (deepest-first, strictly only when empty)
        let mut stale_folder_keys: Vec<(String, String)> = Vec::new();
        for (folder_id_str, remote_folder_id) in &remote_folders {
            let still_exists = Uuid::parse_str(folder_id_str)
                .ok()
                .is_some_and(|uid| folders_by_id.contains_key(&uid));
            if !still_exists {
                stale_folder_keys.push((folder_id_str.clone(), remote_folder_id.clone()));
            }
        }
        if !stale_folder_keys.is_empty() {
            let compatible_folder_ids: Vec<String> = stale_folder_keys
                .iter()
                .map(|(_, rid)| rid.clone())
                .filter(|rid| transport.accepts_remote_id(rid))
                .collect();
            let empty_inv = BTreeMap::new();
            let _ = Self::trash_empty_folders_deepest_first(
                &compatible_folder_ids,
                &empty_inv,
                transport,
            )
            .await?;
            for (key, _) in stale_folder_keys {
                remote_folders.remove(&key);
            }
        }

        // 2c. Mirror active folder hierarchy into secondary transport
        self.update_progress(
            Some(SyncPhase::Uploading {
                completed: 0,
                total: all_folders.len(),
            }),
            Some("同步目录结构…".to_string()),
            Some(0.45),
        )
        .await;
        for folder in &all_folders {
            let _ = self
                .ensure_secondary_folder(
                    folder.id,
                    &folders_by_id,
                    &layout.root,
                    transport,
                    &mut remote_folders,
                    &mut HashSet::new(),
                )
                .await?;
        }

        // 3. Mirror locally cached active assets without clobbering primary `drive_file_id`
        let active_assets = self.db.fetch_assets(
            &FilterCriteria {
                include_trashed: false,
                ..FilterCriteria::default()
            },
            None,
        )?;
        let mut parent_listing_cache: HashMap<String, Vec<RemoteDriveFile>> = HashMap::new();
        let unmapped_cached: Vec<AssetRecord> = active_assets
            .into_iter()
            .filter(|a| {
                !remote_assets.contains_key(&format_swift_uuid(&a.id))
                    && self.media.cached_original(a).is_some()
            })
            .collect();
        if !unmapped_cached.is_empty() {
            let total = unmapped_cached.len();
            for (index, asset) in unmapped_cached.into_iter().enumerate() {
                let Some(local_path) = self.media.cached_original(&asset) else {
                    continue;
                };
                let target_parent_id = match asset.folder_id {
                    Some(fid) => {
                        self.ensure_secondary_folder(
                            fid,
                            &folders_by_id,
                            &layout.root,
                            transport,
                            &mut remote_folders,
                            &mut HashSet::new(),
                        )
                        .await?
                    }
                    None => layout.inbox.clone(),
                };
                let existing_files = match parent_listing_cache.get(&target_parent_id) {
                    Some(cached) => cached.clone(),
                    None => {
                        let listed = transport
                            .list_files(&target_parent_id)
                            .await
                            .unwrap_or_default();
                        parent_listing_cache.insert(target_parent_id.clone(), listed.clone());
                        listed
                    }
                };

                let safe_name = sanitize_windows_filename(&asset.file_name);
                let asset_id_str = format_swift_uuid(&asset.id);
                let short_id = asset_id_str[..8].to_lowercase();
                if let Some(matched) = existing_files.iter().find(|f| {
                    !f.is_folder()
                        && (f.name == safe_name || f.name.to_lowercase().contains(&short_id))
                }) {
                    remote_assets.insert(asset_id_str, matched.id.clone());
                    continue;
                }

                let uploaded_name = if existing_files
                    .iter()
                    .any(|f| f.name.eq_ignore_ascii_case(&safe_name))
                {
                    let stem = file_stem_or_full(&safe_name);
                    let ext = Path::new(&safe_name)
                        .extension()
                        .and_then(|e| e.to_str())
                        .unwrap_or("");
                    if ext.is_empty() {
                        format!("{stem} ({short_id})")
                    } else {
                        format!("{stem} ({short_id}).{ext}")
                    }
                } else {
                    safe_name
                };

                let mime = MediaPipeline::mime_type(&uploaded_name);
                let uploaded = transport
                    .upload_file(&local_path, &uploaded_name, mime, &target_parent_id, None)
                    .await?;
                remote_assets.insert(asset_id_str, uploaded.id.clone());
                parent_listing_cache
                    .entry(target_parent_id)
                    .or_default()
                    .push(uploaded);

                let frac = 0.50 + 0.25 * ((index + 1) as f64 / total.max(1) as f64);
                self.update_progress(
                    Some(SyncPhase::Uploading {
                        completed: index + 1,
                        total,
                    }),
                    Some(format!("镜像素材 ({}/{total})", index + 1)),
                    Some(frac),
                )
                .await;
            }
        }

        self.db
            .set_state(&remote_folders_key, Some(&remote_folders))?;
        self.db
            .set_state(&remote_assets_key, Some(&remote_assets))?;

        // 4. Push local metadata/board ops after this backend's cursor (excluding primary-only driveFileID bindings)
        let cursor_seq: i64 = self.db.state(&op_cursor_key)?.unwrap_or(0);
        let pending_after_cursor = self
            .db
            .pending_ops_after::<SyncOperation>(cursor_seq, 10_000)?;
        let secondary_ops: Vec<(i64, SyncOperation)> = pending_after_cursor
            .iter()
            .filter(|(_, op)| match &op.change {
                SyncOperationChange::Asset(delta) => {
                    let is_primary_binding_only = op.project_location == Some(false)
                        && delta.fields.contains_key("driveFileID")
                        && delta
                            .fields
                            .keys()
                            .all(|k| k == "driveFileID" || k == "fileName")
                        && delta.tags_added.is_empty()
                        && delta.tags_removed.is_empty();
                    !is_primary_binding_only
                }
                SyncOperationChange::Folder(_) => op.project_location != Some(false),
                _ => true,
            })
            .cloned()
            .collect();

        if !secondary_ops.is_empty() {
            self.update_progress(
                Some(SyncPhase::Uploading {
                    completed: 0,
                    total: secondary_ops.len(),
                }),
                Some("上传同步日志…".to_string()),
                Some(0.78),
            )
            .await;
            report.uploaded_ops = self
                .push_ops(
                    &secondary_ops,
                    transport,
                    &layout,
                    config.sync_embeddings,
                    true,
                    Some(&op_cursor_key),
                )
                .await?;
            let (pulled_after, boards_after) = self
                .pull_ops(&layout, transport, &scope, config.sync_embeddings)
                .await?;
            report.downloaded_ops += pulled_after;
            changed_boards.extend(boards_after);
        }
        if let Some((last_seq, _)) = pending_after_cursor.last() {
            if *last_seq > cursor_seq {
                self.db.set_state(&op_cursor_key, Some(last_seq))?;
            }
        }

        // 5. Mirror boards, thumbnails, and clear local embeddings projection markers
        self.update_progress(
            Some(SyncPhase::Merging),
            Some("同步情绪板与缩略图…".to_string()),
            Some(0.88),
        )
        .await;
        self.write_boards(&layout, transport, &scope, &changed_boards)
            .await?;
        if config.sync_thumbnails {
            self.upload_dirty_thumbnails(&layout, transport, Some(&remote_thumbnails))
                .await?;
            let (_, straggler_count) = self
                .download_missing_remote_thumbnails(
                    &remote_thumbnails,
                    None,
                    &scope,
                    transport,
                    0.91,
                    0.03,
                    prefetched_stamps,
                )
                .await?;
            report.downloaded_thumbnails += straggler_count;
        }
        if config.sync_embeddings {
            let dirty_emb: BTreeMap<String, String> =
                self.db.state("projection.embeddings")?.unwrap_or_default();
            if !dirty_emb.is_empty() {
                let pairs: Vec<(String, String)> = dirty_emb.into_iter().collect();
                self.db.clear_projections("embeddings", &pairs)?;
            }
        }

        report.updated_boards = changed_boards.len();
        report.duration_seconds = start.elapsed().as_secs_f64();
        Ok(report)
    }

    fn ensure_secondary_folder<'a>(
        &'a self,
        folder_id: Uuid,
        folders_by_id: &'a HashMap<Uuid, FolderRecord>,
        layout_root: &'a str,
        transport: &'a dyn DriveTransport,
        remote_folders: &'a mut HashMap<String, String>,
        visited: &'a mut HashSet<Uuid>,
    ) -> std::pin::Pin<Box<dyn std::future::Future<Output = CoreResult<String>> + Send + 'a>> {
        Box::pin(async move {
            let key = format_swift_uuid(&folder_id);
            if let Some(cached) = remote_folders.get(&key) {
                return Ok(cached.clone());
            }
            if !visited.insert(folder_id) {
                return Ok(layout_root.to_string());
            }
            let Some(folder) = folders_by_id.get(&folder_id) else {
                visited.remove(&folder_id);
                return Ok(layout_root.to_string());
            };
            let parent_remote_id = match folder.parent_id {
                Some(pid) => {
                    self.ensure_secondary_folder(
                        pid,
                        folders_by_id,
                        layout_root,
                        transport,
                        remote_folders,
                        visited,
                    )
                    .await?
                }
                None => layout_root.to_string(),
            };
            visited.remove(&folder_id);
            let safe_name = sanitize_windows_filename(&folder.name);
            let remote = transport
                .find_or_create_folder(&safe_name, &parent_remote_id)
                .await?;
            remote_folders.insert(key, remote.id.clone());
            Ok(remote.id)
        })
    }

    /// Downloads the remote original for `asset_id` into the local LRU cache and updates DB state.
    pub async fn download_original(
        &self,
        asset_id: Uuid,
        transport: &dyn DriveTransport,
    ) -> CoreResult<PathBuf> {
        self.download_original_with_override(asset_id, transport, None)
            .await
    }

    /// Downloads the remote original for `asset_id`, optionally using a secondary backend's
    /// mapped remote file ID override (`backend.remoteAssets.<id>[assetID]`).
    pub async fn download_original_with_override(
        &self,
        asset_id: Uuid,
        transport: &dyn DriveTransport,
        remote_file_id_override: Option<&str>,
    ) -> CoreResult<PathBuf> {
        let asset = self
            .db
            .asset(asset_id)?
            .ok_or_else(|| CoreError::NotFound(format_swift_uuid(&asset_id)))?;
        let remote = remote_file_id_override
            .map(str::to_string)
            .or_else(|| asset.drive_file_id.clone())
            .filter(|id| transport.accepts_remote_id(id))
            .ok_or_else(|| CoreError::NotFound(format_swift_uuid(&asset_id)))?;

        let staged = self.media.staging.join(format!(
            "original-{}-{}",
            format_swift_uuid(&asset_id),
            Uuid::new_v4().simple()
        ));
        transport.download_file(&remote, &staged).await?;

        let has_override = remote_file_id_override.is_some();
        let installed = (|| -> CoreResult<PathBuf> {
            let mut current = self
                .db
                .asset(asset_id)?
                .ok_or_else(|| CoreError::NotFound(format_swift_uuid(&asset_id)))?;
            if !has_override && current.drive_file_id.as_deref() != Some(remote.as_str()) {
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
            DriveTransportMode::ICloudDrive => {
                let custom = config.icloud_custom_folder_path.trim();
                if !custom.is_empty() {
                    return Path::new(custom)
                        .file_name()
                        .and_then(|n| n.to_str())
                        .filter(|s| !s.is_empty())
                        .unwrap_or("Charkle")
                        .to_string();
                }
                let cleaned = config.icloud_folder_name.trim();
                if cleaned.is_empty() {
                    "Charkle".to_string()
                } else {
                    cleaned.to_string()
                }
            }
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
        let raw_shards: Vec<(String, i64, RemoteDriveFile)> = transport
            .list_files(&layout.ops)
            .await?
            .into_iter()
            .filter(|f| !f.is_folder())
            .filter_map(|f| {
                let (dev, end_seq) = parse_ops_shard_file_name(&f.name)?;
                (dev != local_device).then_some((dev, end_seq, f))
            })
            .collect();

        let cursor_key = format!("{scope}.deviceCursors");
        let mut cursors: BTreeMap<String, i64> = self.db.state(&cursor_key)?.unwrap_or_default();

        // Keep each device's shards strictly ascending by `end_seq`, while interleaving across devices
        // in chronological `modified_time` order so multi-device create/delete logs replay causally.
        let mut grouped_by_device: BTreeMap<String, Vec<(String, i64, RemoteDriveFile)>> =
            BTreeMap::new();
        for entry in raw_shards {
            if entry.1 > cursors.get(&entry.0).copied().unwrap_or(0) {
                grouped_by_device
                    .entry(entry.0.clone())
                    .or_default()
                    .push(entry);
            }
        }
        let mut queues: Vec<Vec<(String, i64, RemoteDriveFile)>> =
            Vec::with_capacity(grouped_by_device.len());
        for (_, mut list) in grouped_by_device {
            list.sort_by(|a, b| a.1.cmp(&b.1).then_with(|| a.2.id.cmp(&b.2.id)));
            queues.push(list);
        }
        let mut queue_offsets = vec![0usize; queues.len()];
        let mut pending_entries: Vec<(String, i64, RemoteDriveFile)> = Vec::new();
        loop {
            let mut best_queue: Option<usize> = None;
            let mut best_key: Option<(DateTime<Utc>, &str, i64, &str)> = None;
            for (idx, q) in queues.iter().enumerate() {
                let offset = queue_offsets[idx];
                if offset >= q.len() {
                    continue;
                }
                let cand = &q[offset];
                let key = (
                    cand.2.modified_time.unwrap_or(DateTime::<Utc>::UNIX_EPOCH),
                    cand.0.as_str(),
                    cand.1,
                    cand.2.id.as_str(),
                );
                if best_key.is_none_or(|cur| key < cur) {
                    best_key = Some(key);
                    best_queue = Some(idx);
                }
            }
            let Some(chosen) = best_queue else {
                break;
            };
            pending_entries.push(queues[chosen][queue_offsets[chosen]].clone());
            queue_offsets[chosen] += 1;
        }

        let mut downloaded = 0usize;
        let mut changed_boards = HashSet::new();

        if !pending_entries.is_empty() {
            let concurrency = concurrency_limit(transport, 10);
            let total_shards = pending_entries.len();
            let mut completed_shards = 0usize;
            const CHUNK_SIZE: usize = 40;

            for (chunk_idx, chunk) in pending_entries.chunks(CHUNK_SIZE).enumerate() {
                let indexed: Vec<(usize, &(String, i64, RemoteDriveFile))> =
                    chunk.iter().enumerate().collect();

                let raw_results = run_bounded(indexed, concurrency, |(idx, entry)| async move {
                    let (ref device, end_seq, ref file) = *entry;
                    let bytes = transport.download_data(&file.id).await?;
                    let text = String::from_utf8(bytes).map_err(|_| {
                        CoreError::InvalidPayload(format!(
                            "Malformed UTF-8 in sync shard {}",
                            file.name
                        ))
                    })?;
                    let lines = decode_ops_jsonl(&text)?;
                    let seq_monotonic = lines.windows(2).all(|w| w[0].seq < w[1].seq);
                    let all_same_device = lines.iter().all(|l| l.operation.stamp.device == *device);
                    let ends_right = lines.last().map(|l| l.seq) == Some(end_seq);
                    if lines.is_empty() || !ends_right || !all_same_device || !seq_monotonic {
                        return Err(CoreError::InvalidPayload(format!(
                            "Malformed sync operation shard {}.",
                            file.name
                        )));
                    }
                    Ok::<_, CoreError>((idx, device.clone(), end_seq, lines))
                })
                .await;

                let mut parsed_shards = Vec::with_capacity(raw_results.len());
                for res in raw_results {
                    parsed_shards.push(res?);
                }
                parsed_shards.sort_by_key(|(idx, _, _, _)| *idx);

                let mut pending_batch: Vec<(String, SyncLogLine)> = Vec::with_capacity(512);
                let mut chunk_boards = HashSet::new();

                for (_, device, end_seq, lines) in parsed_shards {
                    let previous = cursors.get(&device).copied().unwrap_or(0);
                    cursors.insert(device.clone(), previous.max(end_seq));
                    for line in lines.into_iter().filter(|l| l.seq > previous) {
                        downloaded += 1;
                        match &line.operation.change {
                            SyncOperationChange::Board(delta) => {
                                changed_boards.insert(delta.id);
                                chunk_boards.insert(delta.id);
                            }
                            SyncOperationChange::DeleteBoard(id) => {
                                changed_boards.insert(*id);
                                chunk_boards.insert(*id);
                            }
                            _ => {}
                        }
                        pending_batch.push((device.clone(), line));
                    }
                    completed_shards += 1;
                }

                // Apply cross-device ops in global causal HLC order inside ONE atomic transaction
                // together with the chunk's updated cursors so a crash never skips unapplied ops.
                pending_batch.sort_by(|lhs, rhs| {
                    lhs.1
                        .operation
                        .stamp
                        .cmp(&rhs.1.operation.stamp)
                        .then_with(|| lhs.0.cmp(&rhs.0))
                        .then_with(|| lhs.1.seq.cmp(&rhs.1.seq))
                });

                let mut ops_batch: Vec<SyncOperation> = Vec::with_capacity(pending_batch.len());
                let mut disabled_batch: Vec<(String, SyncOperation)> = Vec::new();
                for (device, line) in pending_batch {
                    if matches!(line.operation.change, SyncOperationChange::Vector { .. })
                        && !sync_embeddings
                    {
                        disabled_batch.push((
                            format!("disabled.vector.{device}.{}", line.seq),
                            line.operation,
                        ));
                    } else {
                        ops_batch.push(line.operation);
                    }
                }

                if !ops_batch.is_empty() || !disabled_batch.is_empty() {
                    self.db
                        .apply_op_shard(&ops_batch, &disabled_batch, &cursor_key, &cursors)?;
                } else {
                    self.db.set_state(&cursor_key, Some(&cursors))?;
                }

                let ratio = 0.12 + 0.10 * (completed_shards as f64 / total_shards.max(1) as f64);
                self.update_progress(
                    Some(SyncPhase::Downloading {
                        completed: completed_shards,
                        total: total_shards,
                    }),
                    Some(format!(
                        "拉取素材元数据 ({completed_shards}/{total_shards})"
                    )),
                    Some(ratio),
                )
                .await;

                if total_shards > CHUNK_SIZE && (chunk_idx + 1) * CHUNK_SIZE < total_shards {
                    self.notify_progressive_metadata(!chunk_boards.is_empty());
                }
            }
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
        defer_op_pruning: bool,
        cursor_key: Option<&str>,
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

            if defer_op_pruning {
                if let Some(key) = cursor_key {
                    self.db.set_state(key, Some(&end_seq))?;
                }
            } else {
                self.db.acknowledge_ops(end_seq)?;
            }
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
        let mut pending_deleted_folder_drive_ids = HashSet::new();

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
                    if let Some(did) = drive_id.as_deref().filter(|s| !s.is_empty()) {
                        pending_deleted_drive_ids.insert(did.to_string());
                    }
                    if is_mounted {
                        let key = format!("local.delete.asset.{}", format_swift_uuid(id));
                        if let Some(local) = self.db.state::<String>(&key)? {
                            pending_deleted_drive_ids.insert(local);
                        }
                    }
                }
                SyncOperationChange::DeleteFolder { id, drive_id } => {
                    if let Some(did) = drive_id.as_deref().filter(|s| !s.is_empty()) {
                        pending_deleted_folder_drive_ids.insert(did.to_string());
                    }
                    if is_mounted {
                        let key = format!("local.delete.folder.{}", format_swift_uuid(id));
                        if let Some(local) = self.db.state::<String>(&key)? {
                            pending_deleted_folder_drive_ids.insert(local);
                        }
                    }
                }
                _ => {}
            }
        }

        // Clear stale mounted-path deletion markers once absent on mounted filesystem
        if is_mounted {
            let mut markers_to_clear: Vec<String> = Vec::new();
            let prefix = format!("deleted.drive.{MOUNTED_PATH_ID_PREFIX}");
            for (key, _) in self.db.states_with_prefix::<bool>(&prefix)? {
                if let Some(remote_id) = key.strip_prefix("deleted.drive.") {
                    if !update.current.files.contains_key(remote_id)
                        && !pending_deleted_drive_ids.contains(remote_id)
                    {
                        markers_to_clear.push(key);
                    }
                }
            }
            let folder_prefix = format!("deleted.folder.drive.{MOUNTED_PATH_ID_PREFIX}");
            for (key, _) in self.db.states_with_prefix::<bool>(&folder_prefix)? {
                if let Some(remote_id) = key.strip_prefix("deleted.folder.drive.") {
                    if !update.current.files.contains_key(remote_id)
                        && !pending_deleted_folder_drive_ids.contains(remote_id)
                    {
                        markers_to_clear.push(key);
                    }
                }
            }
            let _ = self.db.clear_state_keys_batch(&markers_to_clear);
        }

        let deleted_folder_drive_ids: HashSet<String> = self
            .db
            .states_with_prefix::<bool>("deleted.folder.drive.")
            .unwrap_or_default()
            .into_iter()
            .filter_map(|(k, v)| {
                v.then(|| k.strip_prefix("deleted.folder.drive.").map(str::to_string))
                    .flatten()
            })
            .collect();
        let deleted_folder_paths: HashMap<String, DeletedFolderFingerprint> = self
            .db
            .states_with_prefix::<DeletedFolderFingerprint>("deleted.folder.path.")
            .unwrap_or_default()
            .into_iter()
            .filter_map(|(k, fp)| {
                k.strip_prefix("deleted.folder.path.")
                    .map(|p| (p.to_string(), fp))
            })
            .collect();

        let mut removed_file_ids = HashSet::new();
        let mut deleted_remote_folders_to_clean: Vec<(String, bool)> = Vec::new();

        // 1. Reconcile all remote folders in ONE batched SQLite transaction, skipping
        //    any folder previously deleted in Charkle so a fresh install never resurrects it.
        let folder_reconcile = self.db.reconcile_remote_folders_batch(
            &update.ordered_folders,
            &update.previous,
            &layout.inbox,
            &pending_folders,
            &pending_deleted_folder_drive_ids,
            &deleted_folder_drive_ids,
            &deleted_folder_paths,
            |fid| stable_uuid(&format!("folder:{fid}")),
        )?;
        let folder_ids = folder_reconcile.map;
        for id in folder_reconcile.skipped_pending {
            removed_file_ids.insert(id);
        }
        for (id, persist_marker) in folder_reconcile.skipped_deleted {
            removed_file_ids.insert(id.clone());
            if transport.accepts_remote_id(&id) {
                deleted_remote_folders_to_clean.push((id, persist_marker));
            }
        }

        // 2. Reconcile visible files using 4 bulk preloads instead of O(N) per-file SQLite queries.
        let mut discovered = 0usize;
        let mut discovered_ids = Vec::new();
        let mut renames = 0usize;
        let mut deferred_file_ids = HashSet::new();
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

        let all_local_assets = self.db.fetch_assets(
            &FilterCriteria {
                include_trashed: true,
                ..FilterCriteria::default()
            },
            None,
        )?;
        let assets_by_id: HashMap<Uuid, AssetRecord> =
            all_local_assets.into_iter().map(|a| (a.id, a)).collect();

        let deleted_drive_ids: HashSet<String> = self
            .db
            .states_with_prefix::<bool>("deleted.drive.")
            .unwrap_or_default()
            .into_iter()
            .filter_map(|(k, v)| {
                v.then(|| k.strip_prefix("deleted.drive.").map(str::to_string))
                    .flatten()
            })
            .collect();
        let deleted_md5s: HashMap<String, DeletedAssetFingerprint> = self
            .db
            .states_with_prefix::<DeletedAssetFingerprint>("deleted.md5.")
            .unwrap_or_default()
            .into_iter()
            .filter_map(|(k, fp)| k.strip_prefix("deleted.md5.").map(|m| (m.to_string(), fp)))
            .collect();
        let remote_hidden_ids: HashSet<String> = self
            .db
            .states_with_prefix::<bool>("remote.hidden.")
            .unwrap_or_default()
            .into_iter()
            .filter_map(|(k, v)| {
                v.then(|| k.strip_prefix("remote.hidden.").map(str::to_string))
                    .flatten()
            })
            .collect();

        let mut download_jobs: Vec<(&RemoteDriveFile, Option<Uuid>, Option<AssetRecord>)> =
            Vec::new();
        let mut thumbnail_link_jobs: Vec<(&RemoteDriveFile, Option<Uuid>, AssetRecord)> =
            Vec::new();
        let mut location_updates: Vec<crate::db::library_db::RemoteLocationUpdate> = Vec::new();
        let mut remote_trash_from_deleted: Vec<(String, bool)> = Vec::new();

        for file in visible {
            if pending_deleted_drive_ids.contains(&file.id) {
                removed_file_ids.insert(file.id.clone());
                continue;
            }
            if deleted_drive_ids.contains(&file.id) {
                if transport.accepts_remote_id(&file.id) {
                    remote_trash_from_deleted.push((file.id.clone(), false));
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
            let existing = linked
                .get(&file.id)
                .and_then(|aid| assets_by_id.get(aid))
                .cloned();

            if existing.is_none() {
                if let Some(ref md5) = file.md5_checksum {
                    if !md5.is_empty() {
                        if let Some(deleted) = deleted_md5s.get(md5) {
                            if self.db.assets_by_content_hash(&deleted.sha256)?.is_empty() {
                                if transport.accepts_remote_id(&file.id) {
                                    remote_trash_from_deleted.push((file.id.clone(), true));
                                }
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
                    // Only enqueue a SQLite location update if a genuinely newer Drive-side rename/move
                    // or hidden-trash restoration occurred. On a fresh install (`previous.is_none()`),
                    // trust authoritative `.charkle/ops/` metadata instead of reverting trashed/moved items.
                    if !pending_moves.contains(&existing_asset.id) {
                        let remote_name = original_name(file);
                        let unhide_needs_update = remote_hidden_ids.contains(&file.id);
                        let (name_needs_update, folder_needs_update) = if let Some(prev) = previous
                        {
                            (
                                prev.name.as_str() != file.name.as_str()
                                    && existing_asset.file_name != remote_name,
                                prev.parents != file.parents
                                    && existing_asset.folder_id != folder_id,
                            )
                        } else if !existing_asset.is_trashed
                            && file.modified_time.is_some_and(|remote_mod| {
                                remote_mod
                                    > existing_asset.updated_at + chrono::Duration::seconds(2)
                            })
                        {
                            (
                                existing_asset.file_name != remote_name,
                                existing_asset.folder_id != folder_id
                                    && (folder_id.is_some() || existing_asset.folder_id.is_none()),
                            )
                        } else {
                            (false, false)
                        };
                        if name_needs_update || folder_needs_update || unhide_needs_update {
                            location_updates.push(crate::db::library_db::RemoteLocationUpdate {
                                asset_id: existing_asset.id,
                                drive_id: file.id.clone(),
                                new_filename: name_needs_update.then_some(remote_name),
                                new_folder_id: folder_id,
                                update_folder: folder_needs_update,
                                clear_hidden: unhide_needs_update,
                            });
                        }
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
                    // Fast-path for already-synced assets missing `.charkle/thumbnails/<uuid>.jpg`:
                    // fetch Google Drive's server-generated thumbnail (~40ms) instead of multi-MB original.
                    if file.thumbnail_link.is_some() {
                        thumbnail_link_jobs.push((file, folder_id, existing_asset.clone()));
                        continue;
                    }
                }
            }
            download_jobs.push((file, folder_id, existing));
        }

        if !remote_trash_from_deleted.is_empty() {
            let trash_concurrency = concurrency_limit(transport, 6);
            let trash_results = run_bounded(
                remote_trash_from_deleted,
                trash_concurrency,
                |(file_id, persist_marker)| async move {
                    Self::trash_if_present(&file_id, transport).await?;
                    Ok::<_, CoreError>(persist_marker.then_some(file_id))
                },
            )
            .await;
            let mut markers_to_save = Vec::new();
            for res in trash_results {
                if let Some(fid) = res? {
                    markers_to_save.push(fid);
                }
            }
            let _ = self.db.mark_deleted_drive_markers_batch(&markers_to_save);
        }

        if !location_updates.is_empty() {
            renames += self
                .db
                .apply_remote_location_updates_batch(&location_updates)?;
        }

        // Phase 1.5: fast 12-way parallel Google Drive `thumbnailLink` hydration for already-synced
        // assets lacking `.charkle/thumbnails/<uuid>.jpg`.
        if !thumbnail_link_jobs.is_empty() {
            let thumb_concurrency = concurrency_limit(transport, 12);
            let fallback_results = run_bounded(
                thumbnail_link_jobs,
                thumb_concurrency,
                |(file, folder_id, existing_asset)| async move {
                    let ok = match transport.download_thumbnail_data(file, 640).await {
                        Ok(Some(raw_bytes)) => {
                            if let Some(jpeg) = normalized_thumbnail_jpeg(&raw_bytes, 520) {
                                self.media
                                    .write_thumbnail_bytes(
                                        existing_asset.id,
                                        ThumbnailTier::Grid520,
                                        &jpeg,
                                    )
                                    .is_ok()
                            } else {
                                false
                            }
                        }
                        _ => false,
                    };
                    (file, folder_id, existing_asset, ok)
                },
            )
            .await;

            let mut hydrated_ids = Vec::new();
            for (file, folder_id, existing_asset, ok) in fallback_results {
                if ok {
                    hydrated_ids.push(existing_asset.id);
                } else {
                    download_jobs.push((file, folder_id, Some(existing_asset)));
                }
            }
            if !hydrated_ids.is_empty() {
                self.notify_progressive_thumbnails(hydrated_ids);
            }
        }

        // Phase 2: bounded parallel remote download + thumbnail rendering (up to 6 concurrent)
        if !download_jobs.is_empty() {
            let dl_concurrency = concurrency_limit(transport, 6);
            let total_downloads = download_jobs.len();
            self.update_progress(
                Some(SyncPhase::Downloading {
                    completed: 0,
                    total: total_downloads,
                }),
                Some(format!("并行拉取 {total_downloads} 项素材…")),
                Some(0.48),
            )
            .await;

            let mut completed_downloads = 0usize;
            let mut since_last_progressive = 0usize;
            let mut last_progressive_at = Instant::now();
            let mut fatal_error: Option<CoreError> = None;
            let mut pending_deleted_locally: Vec<String> = Vec::new();
            let current_inv = &update.current;

            run_bounded_stream(
                download_jobs,
                dl_concurrency,
                |(file, folder_id, existing)| async move {
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
                            current_inv,
                            transport,
                            config,
                            &stage_dir,
                        )
                        .await;
                    let _ = fs::remove_dir_all(&stage_dir);
                    (file, res)
                },
                |(file, res)| {
                    if fatal_error.is_some() {
                        return;
                    }
                    completed_downloads += 1;
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
                            since_last_progressive += 1;
                            let now = Instant::now();
                            if since_last_progressive >= 12
                                || now.duration_since(last_progressive_at)
                                    >= Duration::from_millis(800)
                            {
                                since_last_progressive = 0;
                                last_progressive_at = now;
                                self.notify_progressive_metadata(false);
                            }
                        }
                        Ok(RemoteIngestOutcome::Skipped) => {}
                        Ok(RemoteIngestOutcome::DeletedLocally) => {
                            pending_deleted_locally.push(file.id.clone());
                            removed_file_ids.insert(file.id.clone());
                        }
                        Err(err) => {
                            if is_fatal_sync_error(&err) {
                                fatal_error = Some(err);
                            } else {
                                deferred_file_ids.insert(file.id.clone());
                            }
                        }
                    }
                },
            )
            .await;

            if let Some(err) = fatal_error {
                return Err(err);
            }
            if !pending_deleted_locally.is_empty() {
                for fid in &pending_deleted_locally {
                    if transport.accepts_remote_id(fid) {
                        Self::trash_if_present(fid, transport).await?;
                    }
                }
                let _ = self
                    .db
                    .mark_deleted_drive_markers_batch(&pending_deleted_locally);
            }
            if since_last_progressive > 0 {
                self.notify_progressive_metadata(false);
            }
            self.update_progress(
                Some(SyncPhase::Downloading {
                    completed: completed_downloads,
                    total: total_downloads,
                }),
                Some(format!(
                    "已完成素材拉取 ({completed_downloads}/{total_downloads})"
                )),
                Some(0.66),
            )
            .await;
        }

        // Phase 2.5: After both Phase 1 and Phase 2 have trashed any deleted remote files, safely
        // clean up leftover deleted remote folders (deepest-first, strictly only when empty).
        if !deleted_remote_folders_to_clean.is_empty() {
            let folder_ids_to_clean: Vec<String> = deleted_remote_folders_to_clean
                .iter()
                .map(|(id, _)| id.clone())
                .collect();
            let trashed_folder_ids = Self::trash_empty_folders_deepest_first(
                &folder_ids_to_clean,
                &update.current.files,
                transport,
            )
            .await?;
            let persist_ids: Vec<String> = deleted_remote_folders_to_clean
                .iter()
                .filter(|(id, persist)| *persist && trashed_folder_ids.contains(id))
                .map(|(id, _)| id.clone())
                .collect();
            let _ = self
                .db
                .mark_deleted_folder_drive_markers_batch(&persist_ids);
            for fid in trashed_folder_ids {
                removed_file_ids.insert(fid);
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
            let same_hash = self.db.assets_by_content_hash(&digests.sha256)?;
            let primary_matches: Vec<AssetRecord> = same_hash
                .iter()
                .filter(|a| {
                    (a.drive_file_id.is_none()
                        && a.file_name == filename
                        && a.folder_id == folder_id)
                        || a.drive_file_id
                            .as_ref()
                            .is_some_and(|did| !current.files.contains_key(did))
                })
                .cloned()
                .collect();
            if primary_matches.len() == 1 {
                primary_matches.into_iter().next()
            } else {
                let exact: Vec<AssetRecord> = primary_matches
                    .into_iter()
                    .filter(|a| a.file_name == filename && a.folder_id == folder_id)
                    .collect();
                if exact.len() == 1 {
                    exact.into_iter().next()
                } else {
                    // Also bind unbound local records (e.g. synced via mounted drive or soft-trashed
                    // when a folder was deleted) whose fileName or conflict-suffixed name matches,
                    // so a fresh install never resurrects a soft-trashed asset as a brand-new live copy.
                    let unbound: Vec<AssetRecord> = same_hash
                        .into_iter()
                        .filter(|a| a.drive_file_id.is_none())
                        .collect();
                    let by_name_or_conflict: Vec<AssetRecord> = unbound
                        .iter()
                        .filter(|cand| {
                            if cand.file_name.eq_ignore_ascii_case(&filename) {
                                return true;
                            }
                            let short = format_swift_uuid(&cand.id)[..8].to_lowercase();
                            let alt = conflict_file_name(&cand.file_name, &short, 1);
                            alt.eq_ignore_ascii_case(&filename)
                        })
                        .cloned()
                        .collect();
                    if by_name_or_conflict.len() == 1 {
                        by_name_or_conflict.into_iter().next()
                    } else {
                        let unbound_trashed: Vec<AssetRecord> =
                            unbound.into_iter().filter(|a| a.is_trashed).collect();
                        if unbound_trashed.len() == 1 {
                            unbound_trashed.into_iter().next()
                        } else {
                            None
                        }
                    }
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
            if current.folder_id != matched.folder_id || current.is_trashed {
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

    async fn upload_physical(
        &self,
        operations: &[SyncOperation],
        layout: &Layout,
        transport: &dyn DriveTransport,
        scope: &str,
    ) -> CoreResult<(HashSet<String>, HashSet<String>)> {
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
                    match transport
                        .move_file(
                            &remote_file.id,
                            remote_file.parents.first().map(String::as_str),
                            &parent,
                            rename,
                        )
                        .await
                    {
                        Ok(moved) => {
                            if moved.id != remote_file.id {
                                if let Some(mut current) = self.db.asset(asset_id)? {
                                    current.drive_file_id = Some(moved.id);
                                    let _ = self.db.save_asset_locally(&current, false)?;
                                }
                            }
                        }
                        Err(CoreError::NotFound(_))
                        | Err(CoreError::Http {
                            status_code: 404, ..
                        }) => {}
                        Err(e) => return Err(e),
                    }
                }
                continue;
            }

            if moved_assets.contains(&asset_id) {
                if let Some(remote_id) = asset
                    .drive_file_id
                    .as_deref()
                    .filter(|id| transport.accepts_remote_id(id))
                {
                    match transport
                        .move_file(remote_id, None, &parent, Some(&asset.file_name))
                        .await
                    {
                        Ok(moved) => {
                            if moved.id != remote_id {
                                if let Some(mut current) = self.db.asset(asset_id)? {
                                    current.drive_file_id = Some(moved.id);
                                    let _ = self.db.save_asset_locally(&current, false)?;
                                }
                            }
                        }
                        Err(CoreError::NotFound(_))
                        | Err(CoreError::Http {
                            status_code: 404, ..
                        }) => {}
                        Err(e) => return Err(e),
                    }
                    continue;
                }
            }

            let needs_upload = asset.drive_file_id.as_deref().is_none_or(|s| {
                !transport.accepts_remote_id(s)
                    || s.starts_with("mounted-")
                    || s.starts_with(ICLOUD_PATH_ID_PREFIX)
            });
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
                let _ = self.bind_uploaded_asset(&asset, &cand, transport).await?;
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
            let deleted_in_flight = self
                .bind_uploaded_asset(&asset, &uploaded, transport)
                .await?;
            if !deleted_in_flight {
                listings.entry(parent.clone()).or_default().push(uploaded);
            }
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
            .filter(|id| transport.accepts_remote_id(id))
            .collect();
        for id in &compatible_removed_files {
            Self::trash_if_present(id, transport).await?;
        }

        let empty_inv = BTreeMap::new();
        let inv_files = inventory.as_ref().map(|i| &i.files).unwrap_or(&empty_inv);
        let removed_folders_vec: Vec<String> = removed_folders.into_iter().collect();
        let trashed_folders =
            Self::trash_empty_folders_deepest_first(&removed_folders_vec, inv_files, transport)
                .await?;

        Ok((compatible_removed_files, trashed_folders))
    }

    async fn bind_uploaded_asset(
        &self,
        asset: &AssetRecord,
        uploaded: &RemoteDriveFile,
        transport: &dyn DriveTransport,
    ) -> CoreResult<bool> {
        let Some(mut current) = self.db.asset(asset.id)? else {
            // An in-flight deletion must trash the uploaded original and prevent resurrection.
            self.db
                .set_state(&format!("deleted.drive.{}", uploaded.id), Some(&true))?;
            self.db.record(
                SyncOperationChange::DeleteAsset {
                    id: asset.id,
                    drive_id: Some(uploaded.id.clone()),
                },
                true,
            )?;
            if transport.accepts_remote_id(&uploaded.id) {
                let _ = Self::trash_if_present(&uploaded.id, transport).await;
            }
            return Ok(true);
        };
        current.drive_file_id = Some(uploaded.id.clone());
        if current.file_name == asset.file_name {
            current.file_name = uploaded.name.clone();
        }
        let _ = self.db.save_asset_locally(&current, false)?;
        Ok(false)
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

            let remote = if let Some(known) = folder
                .drive_folder_id
                .as_deref()
                .filter(|id| transport.accepts_remote_id(id))
            {
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

    async fn upload_dirty_thumbnails(
        &self,
        layout: &Layout,
        transport: &dyn DriveTransport,
        prefetched: Option<&HashMap<String, RemoteDriveFile>>,
    ) -> CoreResult<()> {
        let dirty: BTreeMap<String, String> =
            self.db.state("projection.thumbnails")?.unwrap_or_default();
        if dirty.is_empty() {
            return Ok(());
        }

        let fetched_owned;
        let files = match prefetched {
            Some(map) => map,
            None => {
                fetched_owned = keyed_by_name(&transport.list_files(&layout.thumbnails).await?);
                &fetched_owned
            }
        };

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
        Ok(())
    }

    /// Downloads missing or updated `.grid520` remote thumbnails in newest-first (`created_at DESC`)
    /// priority order with 12-way sliding-window HTTP/2 concurrency and progressive UI painting
    /// notifications (flushing first 12 immediately, then every 32 / 500ms).
    #[allow(clippy::too_many_arguments)]
    async fn download_missing_remote_thumbnails(
        &self,
        files: &HashMap<String, RemoteDriveFile>,
        dirty_override: Option<&BTreeMap<String, String>>,
        scope: &str,
        transport: &dyn DriveTransport,
        progress_start: f64,
        progress_span: f64,
        initial_stamps: Option<BTreeMap<String, String>>,
    ) -> CoreResult<(BTreeMap<String, String>, usize)> {
        let dirty_owned;
        let dirty = match dirty_override {
            Some(map) => map,
            None => {
                dirty_owned = self
                    .db
                    .state::<BTreeMap<String, String>>("projection.thumbnails")?
                    .unwrap_or_default();
                &dirty_owned
            }
        };

        let created_at_by_id = self.db.asset_created_at_by_id()?;
        let stamps_key = format!("{scope}.thumbnails");
        let mut stamps: BTreeMap<String, String> = match initial_stamps {
            Some(existing) => existing,
            None => self.db.state(&stamps_key)?.unwrap_or_default(),
        };
        let mut stamps_dirty = false;

        struct ThumbJob {
            uuid: Uuid,
            id_upper: String,
            file_id: String,
            stamp: String,
            created_at: f64,
        }

        let mut jobs: Vec<ThumbJob> = Vec::with_capacity(files.len().min(created_at_by_id.len()));
        for (name, file) in files {
            if file.is_folder() || !transport.accepts_remote_id(&file.id) {
                continue;
            }
            let lower_name = name.to_ascii_lowercase();
            let Some(stem) = lower_name.strip_suffix(".jpg") else {
                continue;
            };
            let Ok(uuid) = Uuid::parse_str(stem) else {
                continue;
            };
            let Some(&created_at) = created_at_by_id.get(&uuid) else {
                continue;
            };
            let id_upper = format_swift_uuid(&uuid);
            if dirty.contains_key(&id_upper) {
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

            jobs.push(ThumbJob {
                uuid,
                id_upper,
                file_id: file.id.clone(),
                stamp,
                created_at,
            });
        }

        // Prioritize newest / top-of-gallery assets first so the visible viewport populates immediately.
        jobs.sort_by(|a, b| {
            b.created_at
                .total_cmp(&a.created_at)
                .then_with(|| a.id_upper.cmp(&b.id_upper))
        });

        let total = jobs.len();
        let mut downloaded_count = 0usize;

        if total > 0 {
            let concurrency = concurrency_limit(transport, 12);
            let mut completed = 0usize;
            let mut unsaved_count = 0usize;
            let mut pending_notify_ids: Vec<Uuid> = Vec::with_capacity(32);
            let mut did_initial_paint_flush = false;
            let mut last_notify_at = Instant::now();
            let mut last_progress_at = Instant::now();

            self.update_progress(
                Some(SyncPhase::Downloading {
                    completed: 0,
                    total,
                }),
                Some(format!("优先拉取缩略图 (0/{total})")),
                Some(progress_start),
            )
            .await;

            run_bounded_stream(
                jobs,
                concurrency,
                |job| async move {
                    let dl = transport.download_data(&job.file_id).await;
                    (job, dl)
                },
                |(job, dl)| {
                    completed += 1;
                    match dl {
                        Ok(data) if !data.is_empty() => {
                            if self
                                .media
                                .write_thumbnail_bytes(job.uuid, ThumbnailTier::Grid520, &data)
                                .is_ok()
                            {
                                stamps.insert(job.id_upper, job.stamp);
                                stamps_dirty = true;
                                downloaded_count += 1;
                                unsaved_count += 1;
                                pending_notify_ids.push(job.uuid);
                            }
                        }
                        Ok(_) => {
                            tracing::warn!(file_id = %job.file_id, "Skipping empty remote thumbnail payload");
                        }
                        Err(err) => {
                            tracing::warn!(file_id = %job.file_id, %err, "Failed to download remote thumbnail; continuing");
                        }
                    }

                    let now = Instant::now();
                    let flush_threshold = if did_initial_paint_flush { 32 } else { 12 };
                    if pending_notify_ids.len() >= flush_threshold
                        || (!pending_notify_ids.is_empty()
                            && now.duration_since(last_notify_at) >= Duration::from_millis(500))
                    {
                        let batch = std::mem::replace(&mut pending_notify_ids, Vec::with_capacity(32));
                        did_initial_paint_flush = true;
                        last_notify_at = now;
                        self.notify_progressive_thumbnails(batch);
                    }

                    if unsaved_count >= 100 {
                        unsaved_count = 0;
                        let _ = self.db.set_state(&stamps_key, Some(&stamps));
                        stamps_dirty = false;
                    }

                    if now.duration_since(last_progress_at) >= Duration::from_millis(250)
                        || completed == total
                    {
                        last_progress_at = now;
                        let ratio =
                            progress_start + progress_span * (completed as f64 / total.max(1) as f64);
                        if let Ok(mut s) = self.status.try_write() {
                            s.phase = SyncPhase::Downloading { completed, total };
                            s.current_detail = Some(format!("拉取缩略图 ({completed}/{total})"));
                            s.progress_fraction = Some(ratio.clamp(0.0, 1.0));
                            self.broadcast(&s);
                        }
                    }
                },
            )
            .await;

            if !pending_notify_ids.is_empty() {
                self.notify_progressive_thumbnails(pending_notify_ids);
            }
        }

        if stamps_dirty {
            self.db.set_state(&stamps_key, Some(&stamps))?;
        }
        Ok((stamps, downloaded_count))
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

    /// Trashes empty remote folders deepest-child-first across multiple passes so deleting nested
    /// folder trees cleanly removes children before their parents without ever deleting non-empty folders.
    async fn trash_empty_folders_deepest_first(
        folder_ids: &[String],
        inventory_files: &BTreeMap<String, RemoteDriveFile>,
        transport: &dyn DriveTransport,
    ) -> CoreResult<HashSet<String>> {
        let mut seen = HashSet::new();
        let mut unique: Vec<String> = Vec::new();
        for id in folder_ids {
            if transport.accepts_remote_id(id) && seen.insert(id.clone()) {
                unique.push(id.clone());
            }
        }
        if unique.is_empty() {
            return Ok(HashSet::new());
        }

        let depth_of = |id: &str| -> usize {
            let mut count = 0usize;
            let mut cursor = id;
            let mut visited = HashSet::new();
            while visited.insert(cursor) {
                let Some(parent) = inventory_files
                    .get(cursor)
                    .and_then(|f| f.parents.first())
                    .map(String::as_str)
                    .filter(|p| !p.is_empty())
                else {
                    break;
                };
                count += 1;
                cursor = parent;
            }
            if count == 0 {
                count = id.split('/').filter(|s| !s.is_empty()).count();
            }
            count
        };

        unique.sort_by(|lhs, rhs| depth_of(rhs).cmp(&depth_of(lhs)).then_with(|| rhs.cmp(lhs)));

        let mut remaining = unique;
        let mut trashed = HashSet::new();
        let max_passes = remaining.len().clamp(1, 12);
        for _ in 0..max_passes {
            if remaining.is_empty() {
                break;
            }
            let mut next_remaining = Vec::new();
            let mut progress = false;
            for id in remaining {
                match transport.list_files(&id).await {
                    Ok(children) if children.is_empty() => {
                        Self::trash_if_present(&id, transport).await?;
                        trashed.insert(id);
                        progress = true;
                    }
                    Ok(_) => {
                        next_remaining.push(id);
                    }
                    Err(CoreError::NotFound(_))
                    | Err(CoreError::Http {
                        status_code: 404, ..
                    }) => {
                        trashed.insert(id);
                        progress = true;
                    }
                    Err(CoreError::Http {
                        status_code: 403, ..
                    }) => {
                        // Shared folder without delete permission: skip cleanly without aborting sync.
                    }
                    Err(e) => return Err(e),
                }
            }
            remaining = next_remaining;
            if !progress {
                break;
            }
        }
        Ok(trashed)
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

/// Lossless two-way storage backend migration (Pure Local Folder <-> iCloud Drive <-> Google Drive <-> WebDAV).
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
        if !target_config.icloud_folder_name.trim().is_empty() {
            validate_path_segments(&target_config.icloud_folder_name)?;
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
