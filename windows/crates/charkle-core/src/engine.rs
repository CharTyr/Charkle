//! High-level async `LiveCharkleEngine` facade unifying database, media pipeline,
//! sync engine, storage migration, and event broadcasting for Tauri UI & CLI/MCP.
//!
//! Mirrors `Sources/CharkleCore/LiveCharkleEngine.swift`.

use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::sync::Arc;

use chrono::Utc;
use serde::{Deserialize, Serialize};
use tokio::sync::broadcast;
use url::Url;
use uuid::Uuid;

use crate::db::{search_text, LibraryDatabase};
use crate::error::{CoreError, CoreResult};
use crate::export::{
    BoardImageExporter, FigmaBridgeExportReport, FigmaBridgeExporter, MoodboardExportOptions,
};
use crate::intelligence::MoodboardAgentHarness;
use crate::layout::{EditorialLayoutResult, EditorialLayoutSolver};
use crate::media::artwork::MediaArtwork;
use crate::media::metadata::ImageMetadataExtractor;
use crate::media::resolvers::{
    GitHubRepoResolver, GitHubRepoURLParser, SocialPostResolver, SocialPostURLParser,
};
use crate::media::{MediaPipeline, SampleLibrarySeeder};
use crate::models::core::{
    AssetBatchPatch, AssetRecord, FilterCriteria, FolderAssignment, FolderRecord, FolderSuggestion,
    MediaKind, QuickJumpMatch, ScoredAsset, SmartFolderRecord, SocialMediaAttachmentKind, TagCount,
};
use crate::models::media::{cosine_similarity, CacheStats, CaptureInput, ThumbnailTier};
use crate::models::moodboard::{
    AutoLayoutConfig, BoardLayoutMode, BoardNode, BoardNodeKind, BoardRect, MoodboardAgentStep,
    MoodboardCurationRequest, MoodboardDocument, MoodboardProposal, MoodboardSummary,
};
use crate::models::sync::{
    tag_map, DeletedAssetFingerprint, DriveSyncConfig, DriveTransportMode, StorageMigrationReport,
    SyncOperationChange, SyncReport, SyncStatus,
};
use crate::sync::{
    validate_drive_name, validate_path_segments, DirectAPITransport, DriveSyncEngine,
    DriveTransport, GoogleOAuthClient, LocalFolderTransport, MountedVolumeTransport,
    StorageMigration, WebDAVTransport, MOUNTED_PATH_ID_PREFIX,
};
use crate::traits::{
    BasicVolumeMountInspector, InMemorySecretVault, NativeOcrProvider, NoopOcrProvider,
    SecretVault, VolumeMountInspector,
};
use crate::wire::swift_codec::{format_swift_uuid, upper_uuid};

const WEBDAV_PASSWORD_VAULT_KEY: &str = "sync.webdav.password";

/// Broadcast events pushed to Tauri WebView or CLI listeners.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "type", content = "payload", rename_all = "camelCase")]
pub enum EngineEvent {
    SyncStatus(SyncStatus),
    LibraryChanged,
    AssetEnriched(#[serde(with = "upper_uuid")] Uuid),
    BoardUpdated(#[serde(with = "upper_uuid")] Uuid),
}

/// Primary engine facade owning database, media storage, sync engine, and platform trait hooks.
pub struct LiveCharkleEngine {
    db: Arc<LibraryDatabase>,
    media: MediaPipeline,
    sync: Arc<DriveSyncEngine>,
    oauth: Arc<GoogleOAuthClient>,
    vault: Arc<dyn SecretVault>,
    ocr: Arc<dyn NativeOcrProvider>,
    mount_inspector: Arc<dyn VolumeMountInspector>,
    injected_transport: Option<Arc<dyn DriveTransport>>,
    events: broadcast::Sender<EngineEvent>,
}

impl LiveCharkleEngine {
    /// Opens a persistent engine rooted at `data_dir` (`Library.sqlite3`, `Originals/`, `Thumbnails/`, etc.).
    pub fn open(data_dir: impl AsRef<Path>) -> CoreResult<Self> {
        let root = data_dir.as_ref();
        std::fs::create_dir_all(root)?;
        let db = Arc::new(LibraryDatabase::open(&root.join("Library.sqlite3"))?);
        let media = MediaPipeline::new(root)?;
        Ok(Self::new(
            db,
            media,
            Arc::new(InMemorySecretVault::default()),
            Arc::new(NoopOcrProvider),
            Arc::new(BasicVolumeMountInspector),
            None,
        ))
    }

    /// Constructs an engine with explicit trait implementations and optional injected transport.
    pub fn new(
        db: Arc<LibraryDatabase>,
        media: MediaPipeline,
        vault: Arc<dyn SecretVault>,
        ocr: Arc<dyn NativeOcrProvider>,
        mount_inspector: Arc<dyn VolumeMountInspector>,
        injected_transport: Option<Arc<dyn DriveTransport>>,
    ) -> Self {
        let (events, _) = broadcast::channel(128);
        let events_for_sync = events.clone();
        let sync = Arc::new(DriveSyncEngine::with_status_callback(
            Arc::clone(&db),
            media.clone(),
            Arc::new(move |status| {
                let _ = events_for_sync.send(EngineEvent::SyncStatus(status));
            }),
        ));
        let oauth = Arc::new(GoogleOAuthClient::new(Arc::clone(&vault)));

        Self {
            db,
            media,
            sync,
            oauth,
            vault,
            ocr,
            mount_inspector,
            injected_transport,
            events,
        }
    }

    pub fn database(&self) -> &Arc<LibraryDatabase> {
        &self.db
    }

    pub fn media(&self) -> &MediaPipeline {
        &self.media
    }

    pub fn sync_engine(&self) -> &Arc<DriveSyncEngine> {
        &self.sync
    }

    pub fn oauth(&self) -> &Arc<GoogleOAuthClient> {
        &self.oauth
    }

    pub fn subscribe_events(&self) -> broadcast::Receiver<EngineEvent> {
        self.events.subscribe()
    }

    fn emit(&self, event: EngineEvent) {
        let _ = self.events.send(event);
    }

    // =========================================================================
    // Assets CRUD, Capture Ingest, Batch Patching & Permanent Deletion
    // =========================================================================

    pub fn fetch_assets(&self, criteria: &FilterCriteria) -> CoreResult<Vec<AssetRecord>> {
        self.db.fetch_assets(criteria, None)
    }

    pub fn fetch_asset(&self, id: Uuid) -> CoreResult<Option<AssetRecord>> {
        self.db.asset(id)
    }

    /// Ingests one or more `CaptureInput` items into the library and optional target folder/board.
    pub async fn ingest(
        &self,
        inputs: Vec<CaptureInput>,
        target_folder_id: Option<Uuid>,
        target_board_id: Option<Uuid>,
    ) -> CoreResult<Vec<AssetRecord>> {
        if let Some(fid) = target_folder_id {
            if self.db.folder(fid)?.is_none() {
                return Err(CoreError::NotFound(format_swift_uuid(&fid)));
            }
        }
        if let Some(bid) = target_board_id {
            if self.db.board(bid)?.is_none() {
                return Err(CoreError::NotFound(format_swift_uuid(&bid)));
            }
        }
        if inputs.is_empty() {
            return Ok(Vec::new());
        }

        let mut prepared = Vec::with_capacity(inputs.len());
        for input in inputs {
            let mut result = match self.media.ingest(input, target_folder_id, None).await {
                Ok(item) => item,
                Err(err) => {
                    for prev in &prepared {
                        self.media.remove_files_for_asset(prev);
                    }
                    return Err(err);
                }
            };

            // Optional OS-provided OCR when text wasn't already extracted from document/social content
            if result.asset.ocr_text.is_none()
                && matches!(
                    result.asset.media_kind,
                    MediaKind::Image | MediaKind::AnimatedImage | MediaKind::DesignFile
                )
            {
                if let Some(thumb) = self
                    .media
                    .thumbnail_url(result.asset.id, ThumbnailTier::Grid520)
                {
                    if let Ok(bytes) = std::fs::read(&thumb) {
                        if let Ok(Some(text)) = self.ocr.recognize_text(&bytes).await {
                            let trimmed = text.trim();
                            if !trimmed.is_empty() {
                                result.asset.ocr_text = Some(trimmed.to_string());
                            }
                        }
                    }
                }
            }
            prepared.push(result.asset);
        }

        let config = self.sync_config();
        let mut committed = Vec::with_capacity(prepared.len());
        for asset in prepared {
            let saved = self.db.save_asset_locally(&asset, true)?;
            self.db.touch_original(saved.id, Utc::now())?;
            if config.sync_thumbnails {
                self.db.mark_projection("thumbnails", saved.id)?;
            }
            committed.push(saved);
        }

        if let Some(bid) = target_board_id {
            if let Some(mut board) = self.db.board(bid)? {
                let base_order = board
                    .nodes
                    .iter()
                    .map(|n| n.editorial_order)
                    .max()
                    .unwrap_or(-1)
                    + 1;
                let base_z = board.nodes.iter().map(|n| n.z_index).max().unwrap_or(-1) + 1;
                let top = board
                    .nodes
                    .iter()
                    .map(|n| n.frame.y + n.frame.height)
                    .fold(-16.0_f64, f64::max)
                    + 16.0;

                for (idx, asset) in committed.iter().enumerate() {
                    let w = 280.0;
                    let h = (w / asset.aspect_ratio().clamp(0.5, 2.0)).round();
                    let offset = idx as i32;
                    board.nodes.push(BoardNode {
                        id: Uuid::new_v4(),
                        kind: BoardNodeKind::AssetRef {
                            asset_id: asset.id,
                            crop: None,
                            weight: 1,
                            autoplay_loop: true,
                        },
                        frame: BoardRect::new((idx as f64) * 304.0, top, w, h),
                        z_index: base_z + offset,
                        rotation_degrees: 0.0,
                        flip_horizontal: false,
                        flip_vertical: false,
                        is_locked: false,
                        editorial_order: base_order + offset,
                        updated_at: Utc::now(),
                    });
                }
                let _ = self.db.save_board_locally(&board)?;
                self.emit(EngineEvent::BoardUpdated(bid));
            }
        }

        let keep_ids: HashSet<Uuid> = committed.iter().map(|a| a.id).collect();
        let _ = self
            .media
            .cache_stats_and_evict(&self.db, true, &keep_ids, None)?;

        self.emit(EngineEvent::LibraryChanged);
        Ok(committed)
    }

    /// Applies an `AssetBatchPatch` atomically across one or more assets with CRDT delta recording.
    pub fn update_assets(&self, patch: &AssetBatchPatch) -> CoreResult<Vec<AssetRecord>> {
        if let FolderAssignment::Folder(fid) = patch.folder_assignment {
            if self.db.folder(fid)?.is_none() {
                return Err(CoreError::NotFound(format_swift_uuid(&fid)));
            }
        }

        let mut changed = Vec::new();
        for &id in &patch.asset_ids {
            let Some(mut asset) = self.db.asset(id)? else {
                continue;
            };
            if let Some(ref title) = patch.title {
                let clean = title.trim();
                if !clean.is_empty() {
                    asset.title = clean.to_string();
                }
            }
            if let Some(ref notes) = patch.notes {
                asset.notes = notes.clone();
            }
            if let Some(rating) = patch.rating {
                asset.rating = rating.clamp(0, 5);
            }

            let mut tags = tag_map(&asset.tags);
            if patch.accept_suggested_tags {
                for sug in &asset.suggested_tags {
                    let clean = sug.trim();
                    let key = search_text::normalize(clean);
                    if !key.is_empty() {
                        tags.insert(key, clean.to_string());
                    }
                }
                asset.suggested_tags.clear();
            }
            if !patch.dismiss_suggested_tags.is_empty() {
                let dismiss: HashSet<String> = patch
                    .dismiss_suggested_tags
                    .iter()
                    .map(|t| search_text::normalize(t))
                    .collect();
                asset
                    .suggested_tags
                    .retain(|t| !dismiss.contains(&search_text::normalize(t)));
            }
            for tag in &patch.add_tags {
                let clean = tag.trim();
                let key = search_text::normalize(clean);
                if !key.is_empty() {
                    tags.insert(key.clone(), clean.to_string());
                    asset
                        .suggested_tags
                        .retain(|s| search_text::normalize(s) != key);
                }
            }
            for tag in &patch.remove_tags {
                tags.remove(&search_text::normalize(tag));
            }
            let mut sorted_tags: Vec<String> = tags.into_values().collect();
            sorted_tags.sort();
            asset.tags = sorted_tags;

            match patch.folder_assignment {
                FolderAssignment::Unchanged => {}
                FolderAssignment::Inbox => asset.folder_id = None,
                FolderAssignment::Folder(fid) => asset.folder_id = Some(fid),
            }
            if let Some(pinned) = patch.pinned_offline {
                asset.pinned_offline = pinned;
            }
            if let Some(trashed) = patch.is_trashed {
                asset.is_trashed = trashed;
            }

            changed.push(self.db.save_asset_locally(&asset, true)?);
        }

        if patch.pinned_offline == Some(false) {
            let _ = self
                .media
                .cache_stats_and_evict(&self.db, true, &HashSet::new(), None)?;
        }
        if !changed.is_empty() {
            self.emit(EngineEvent::LibraryChanged);
        }
        Ok(changed)
    }

    /// Permanently deletes assets, records tombstones + anti-respawn content fingerprints,
    /// and removes cached original + thumbnail files.
    pub fn permanently_delete_assets(&self, ids: &[Uuid]) -> CoreResult<()> {
        let config = self.sync_config();
        let root_segments: Vec<&str> = config
            .root_folder_name
            .split('/')
            .map(str::trim)
            .filter(|s| !s.is_empty() && *s != "." && *s != "..")
            .collect();
        let root_prefix = if root_segments.is_empty() {
            "Charkle".to_string()
        } else {
            root_segments.join("/")
        };

        let unique_ids: HashSet<Uuid> = ids.iter().copied().collect();
        let mut precomputed_md5: HashMap<Uuid, String> = HashMap::new();
        for &id in &unique_ids {
            if let Some(asset) = self.db.asset(id)? {
                if let Some(cached) = self.media.cached_original(&asset) {
                    if let Ok(digest) = MediaPipeline::digests(&cached) {
                        precomputed_md5.insert(id, digest.md5);
                    }
                }
            }
        }

        let folders = self.db.fetch_folders()?;
        let folder_by_id: HashMap<Uuid, FolderRecord> =
            folders.into_iter().map(|f| (f.id, f)).collect();

        for id in unique_ids {
            let Some(asset) = self.db.asset(id)? else {
                continue;
            };
            let mounted = asset
                .drive_file_id
                .as_deref()
                .is_some_and(|s| s.starts_with("mounted-"));
            if mounted {
                if let Some(ref remote) = asset.drive_file_id {
                    let resolved_remote = if remote.starts_with(MOUNTED_PATH_ID_PREFIX) {
                        remote.clone()
                    } else {
                        let rel_dir = mounted_relative_folder_path(asset.folder_id, &folder_by_id);
                        format!(
                            "{MOUNTED_PATH_ID_PREFIX}{root_prefix}/{rel_dir}/{}",
                            asset.file_name
                        )
                    };
                    self.db.set_state(
                        &format!("local.delete.asset.{}", format_swift_uuid(&id)),
                        Some(&resolved_remote),
                    )?;
                    self.db
                        .set_state(&format!("deleted.drive.{resolved_remote}"), Some(&true))?;
                    if resolved_remote != *remote {
                        self.db
                            .set_state(&format!("deleted.drive.{remote}"), Some(&true))?;
                    }
                }
            } else if let Some(ref remote) = asset.drive_file_id {
                if !remote.is_empty() {
                    self.db
                        .set_state(&format!("deleted.drive.{remote}"), Some(&true))?;
                }
            }

            if !asset.content_hash.is_empty() {
                let md5 = precomputed_md5.get(&id).cloned();
                let fp = DeletedAssetFingerprint {
                    asset_id: id,
                    sha256: asset.content_hash.clone(),
                    md5: md5.clone(),
                    file_name: asset.file_name.clone(),
                    deleted_at: Utc::now(),
                };
                self.db.set_state(
                    &format!("deleted.content.{}", asset.content_hash),
                    Some(&fp),
                )?;
                if let Some(m) = md5.filter(|s| !s.is_empty()) {
                    self.db.set_state(&format!("deleted.md5.{m}"), Some(&fp))?;
                }
            }

            self.db.record(
                SyncOperationChange::DeleteAsset {
                    id,
                    drive_id: if mounted {
                        None
                    } else {
                        asset.drive_file_id.clone()
                    },
                },
                true,
            )?;
        }

        let cleanup_ids = self.db.drain_media_cleanup_ids()?;
        if !cleanup_ids.is_empty() {
            self.media.remove_files_for_ids(&cleanup_ids)?;
        }
        self.emit(EngineEvent::LibraryChanged);
        Ok(())
    }

    /// Updates `last_opened_at` locally without emitting a cloud sync operation.
    pub fn mark_asset_opened(&self, id: Uuid) -> CoreResult<Option<AssetRecord>> {
        self.db.mark_asset_opened(id)
    }

    // =========================================================================
    // Folders, Smart Folders, Tags & Quick Jump
    // =========================================================================

    pub fn fetch_folders(&self) -> CoreResult<Vec<FolderRecord>> {
        self.db.fetch_folders()
    }

    pub fn create_folder(&self, name: &str, parent_id: Option<Uuid>) -> CoreResult<FolderRecord> {
        let clean = normalize_folder_name(name, parent_id)?;
        let folders = self.db.fetch_folders()?;
        if let Some(pid) = parent_id {
            if !folders.iter().any(|f| f.id == pid) {
                return Err(CoreError::NotFound(format_swift_uuid(&pid)));
            }
        }
        ensure_unique_folder(&clean, parent_id, None, &folders)?;
        let next_order = folders.iter().map(|f| f.sort_order).max().unwrap_or(-1) + 1;
        let mut folder = FolderRecord::new(clean, parent_id);
        folder.sort_order = next_order;
        self.db
            .record(SyncOperationChange::Folder(folder.clone()), true)?;
        self.emit(EngineEvent::LibraryChanged);
        Ok(folder)
    }

    pub fn rename_folder(&self, id: Uuid, new_name: &str) -> CoreResult<FolderRecord> {
        let Some(mut folder) = self.db.folder(id)? else {
            return Err(CoreError::NotFound(format_swift_uuid(&id)));
        };
        let clean = normalize_folder_name(new_name, folder.parent_id)?;
        let folders = self.db.fetch_folders()?;
        ensure_unique_folder(&clean, folder.parent_id, Some(id), &folders)?;
        if clean != folder.name {
            folder.name = clean;
            folder.updated_at = Utc::now();
            self.db
                .record(SyncOperationChange::Folder(folder.clone()), true)?;
            self.emit(EngineEvent::LibraryChanged);
        }
        Ok(folder)
    }

    pub fn move_folder(
        &self,
        id: Uuid,
        new_parent_id: Option<Uuid>,
        insert_at_index: Option<usize>,
    ) -> CoreResult<Vec<FolderRecord>> {
        let folders = self.db.move_folder(id, new_parent_id, insert_at_index)?;
        self.emit(EngineEvent::LibraryChanged);
        Ok(folders)
    }

    pub fn update_folder_appearance(
        &self,
        id: Uuid,
        color_hex: Option<String>,
        custom_symbol: Option<String>,
    ) -> CoreResult<FolderRecord> {
        let Some(mut folder) = self.db.folder(id)? else {
            return Err(CoreError::NotFound(format_swift_uuid(&id)));
        };
        folder.color_hex = color_hex
            .map(|s| s.trim().to_string())
            .filter(|s| !s.is_empty());
        folder.custom_symbol = custom_symbol
            .map(|s| s.trim().to_string())
            .filter(|s| !s.is_empty());
        folder.updated_at = Utc::now();
        self.db
            .record(SyncOperationChange::Folder(folder.clone()), true)?;
        self.emit(EngineEvent::LibraryChanged);
        Ok(folder)
    }

    pub fn delete_folder(&self, id: Uuid, trash_contents: bool) -> CoreResult<()> {
        if trash_contents {
            self.db.delete_folder(id, true)?;
            self.emit(EngineEvent::LibraryChanged);
            return Ok(());
        }

        let all_folders = self.db.fetch_folders()?;
        let Some(target) = all_folders.iter().find(|f| f.id == id).cloned() else {
            return Ok(());
        };
        // Reparent direct children to `target.parent_id` with sibling deduplication (matching macOS)
        let mut siblings: Vec<FolderRecord> = all_folders
            .iter()
            .filter(|f| f.parent_id == target.parent_id && f.id != id)
            .cloned()
            .collect();
        let children: Vec<FolderRecord> = all_folders
            .iter()
            .filter(|f| f.parent_id == Some(id))
            .cloned()
            .collect();
        for mut child in children {
            let base = child.name.clone();
            let mut candidate = base.clone();
            let mut suffix = 2;
            while (target.parent_id.is_none() && candidate.eq_ignore_ascii_case("Inbox"))
                || siblings
                    .iter()
                    .any(|s| s.name.eq_ignore_ascii_case(&candidate))
            {
                candidate = format!("{base} {suffix}");
                suffix += 1;
            }
            child.name = candidate;
            child.parent_id = target.parent_id;
            child.updated_at = Utc::now();
            self.db
                .record(SyncOperationChange::Folder(child.clone()), true)?;
            siblings.push(child);
        }

        self.db.delete_folder(id, false)?;
        self.emit(EngineEvent::LibraryChanged);
        Ok(())
    }

    pub fn fetch_smart_folders(&self) -> CoreResult<Vec<SmartFolderRecord>> {
        self.db.fetch_smart_folders()
    }

    pub fn save_smart_folder(
        &self,
        mut folder: SmartFolderRecord,
    ) -> CoreResult<Vec<SmartFolderRecord>> {
        folder.name = folder.name.trim().to_string();
        if folder.name.is_empty() {
            folder.name = "未命名智能文件夹".to_string();
        }
        folder.updated_at = Utc::now();
        let out = self.db.save_smart_folder(folder)?;
        self.emit(EngineEvent::LibraryChanged);
        Ok(out)
    }

    pub fn delete_smart_folder(&self, id: Uuid) -> CoreResult<Vec<SmartFolderRecord>> {
        let out = self.db.delete_smart_folder(id)?;
        self.emit(EngineEvent::LibraryChanged);
        Ok(out)
    }

    pub fn fetch_tag_counts(&self) -> CoreResult<Vec<TagCount>> {
        self.db.fetch_tag_counts()
    }

    pub fn inbox_count(&self) -> CoreResult<usize> {
        self.db.inbox_count()
    }

    pub fn quick_jump(&self, query: &str, limit: usize) -> CoreResult<Vec<QuickJumpMatch>> {
        self.db.quick_jump(query, limit)
    }

    pub fn search_similar_by_embedding(
        &self,
        query_embedding: &[f32],
        limit: usize,
        min_score: f32,
    ) -> CoreResult<Vec<(Uuid, f32)>> {
        self.db
            .search_by_embedding(query_embedding, limit, min_score)
    }

    /// Computes local similarity rankings using available embeddings, CIELAB dominant color
    /// harmony, tag overlap, and media kind affinity.
    pub fn similar_assets(&self, asset_id: Uuid, limit: usize) -> CoreResult<Vec<ScoredAsset>> {
        if limit == 0 {
            return Ok(Vec::new());
        }
        let Some(anchor) = self.db.asset(asset_id)? else {
            return Ok(Vec::new());
        };
        let all = self.db.fetch_assets(
            &FilterCriteria {
                include_trashed: false,
                ..FilterCriteria::default()
            },
            None,
        )?;
        let vectors = self.db.vectors().unwrap_or_default();
        let anchor_emb = vectors.get(&asset_id).and_then(|v| v.embedding.as_deref());
        let anchor_tags: HashSet<String> = anchor
            .tags
            .iter()
            .map(|t| search_text::normalize(t))
            .filter(|t| !t.is_empty())
            .collect();

        let mut scored = Vec::new();
        for cand in all {
            if cand.id == asset_id {
                continue;
            }
            let mut score = 0.0_f64;
            let mut reasons = Vec::new();

            if let (Some(a_emb), Some(c_emb)) = (
                anchor_emb,
                vectors.get(&cand.id).and_then(|v| v.embedding.as_deref()),
            ) {
                if let Some(sim) = cosine_similarity(a_emb, c_emb) {
                    if sim > 0.25 {
                        score += f64::from(sim) * 0.55;
                        reasons.push("语义与视觉风格相近".to_string());
                    }
                }
            }

            if !anchor.dominant_colors.is_empty() && !cand.dominant_colors.is_empty() {
                let mut best_de = f64::MAX;
                for ac in anchor.dominant_colors.iter().take(3) {
                    for cc in cand.dominant_colors.iter().take(3) {
                        best_de = best_de.min(ac.delta_e_2000(cc));
                    }
                }
                if best_de < 28.0 {
                    let color_sim = (1.0 - (best_de / 28.0)).clamp(0.0, 1.0);
                    score += color_sim * 0.35;
                    reasons.push("相近色板".to_string());
                }
            }

            if !anchor_tags.is_empty() && !cand.tags.is_empty() {
                let shared: Vec<String> = cand
                    .tags
                    .iter()
                    .filter(|t| anchor_tags.contains(&search_text::normalize(t)))
                    .cloned()
                    .collect();
                if !shared.is_empty() {
                    let ratio = shared.len() as f64 / anchor_tags.len().max(1) as f64;
                    score += ratio.min(1.0) * 0.35;
                    reasons.push(format!(
                        "共同标签：{}",
                        shared.into_iter().take(2).collect::<Vec<_>>().join("、")
                    ));
                }
            }

            if cand.media_kind == anchor.media_kind {
                score += 0.08;
            }
            if anchor.folder_id.is_some() && cand.folder_id == anchor.folder_id {
                score += 0.06;
            }

            if score >= 0.16 {
                scored.push(ScoredAsset {
                    asset: cand,
                    score: score.min(1.0),
                    match_reasons: reasons,
                });
            }
        }

        scored.sort_by(|a, b| {
            b.score
                .partial_cmp(&a.score)
                .unwrap_or(std::cmp::Ordering::Equal)
                .then_with(|| b.asset.created_at.cmp(&a.asset.created_at))
        });
        scored.truncate(limit);
        Ok(scored)
    }

    /// Suggests the best-fitting existing folder for Inbox Triage using local tag, title,
    /// and color-palette affinity.
    pub fn suggest_folder(&self, asset_id: Uuid) -> CoreResult<Option<FolderSuggestion>> {
        let Some(asset) = self.db.asset(asset_id)? else {
            return Ok(None);
        };
        let folders = self.db.fetch_folders()?;
        if folders.is_empty() {
            return Ok(None);
        }
        let all_assets = self.db.fetch_assets(
            &FilterCriteria {
                include_trashed: false,
                ..FilterCriteria::default()
            },
            None,
        )?;
        let mut by_folder: HashMap<Uuid, Vec<&AssetRecord>> = HashMap::new();
        for item in &all_assets {
            if item.id != asset_id {
                if let Some(fid) = item.folder_id {
                    by_folder.entry(fid).or_default().push(item);
                }
            }
        }

        let asset_tags: HashSet<String> = asset
            .tags
            .iter()
            .chain(asset.suggested_tags.iter())
            .map(|t| search_text::normalize(t))
            .filter(|t| !t.is_empty())
            .collect();
        let asset_text = search_text::normalize(&format!("{} {}", asset.title, asset.notes));

        let mut best: Option<(f64, FolderSuggestion)> = None;
        for folder in folders {
            if Some(folder.id) == asset.folder_id {
                continue;
            }
            let mut score = 0.0_f64;
            let mut reason = String::new();
            let folder_norm = search_text::normalize(&folder.name);
            if !folder_norm.is_empty() && asset_text.contains(&folder_norm) {
                score += 0.55;
                reason = format!("标题或备注包含「{}」", folder.name);
            }

            if let Some(members) = by_folder.get(&folder.id) {
                if !asset_tags.is_empty() {
                    let mut shared_hits = 0usize;
                    let mut sample_tag = None;
                    for m in members {
                        for t in &m.tags {
                            if asset_tags.contains(&search_text::normalize(t)) {
                                shared_hits += 1;
                                if sample_tag.is_none() {
                                    sample_tag = Some(t.clone());
                                }
                            }
                        }
                    }
                    if shared_hits > 0 {
                        let bonus = (0.35 + (shared_hits as f64 * 0.12)).min(0.82);
                        if bonus > score {
                            score = bonus;
                            if let Some(tag) = sample_tag {
                                reason = format!("与该目录中标签「{tag}」高度一致");
                            }
                        }
                    }
                }

                if score < 0.45 && !asset.dominant_colors.is_empty() {
                    let mut min_de = f64::MAX;
                    for m in members.iter().take(24) {
                        for ac in asset.dominant_colors.iter().take(2) {
                            for mc in m.dominant_colors.iter().take(2) {
                                min_de = min_de.min(ac.delta_e_2000(mc));
                            }
                        }
                    }
                    if min_de < 16.0 {
                        let color_score = (0.42 + (16.0 - min_de) / 40.0).min(0.70);
                        if color_score > score {
                            score = color_score;
                            reason = "色彩风格与该目录素材接近".to_string();
                        }
                    }
                }
            }

            if score >= 0.35 && best.as_ref().is_none_or(|(b, _)| score > *b) {
                best = Some((
                    score,
                    FolderSuggestion {
                        folder_id: folder.id,
                        folder_name: folder.name,
                        confidence: score.min(0.98),
                        reason: if reason.is_empty() {
                            "根据目录内容匹配推荐".to_string()
                        } else {
                            reason
                        },
                    },
                ));
            }
        }
        Ok(best.map(|(_, s)| s))
    }

    /// Re-extracts EXIF and AI prompt metadata from the cached original if absent.
    pub fn hydrate_image_metadata(&self, id: Uuid) -> CoreResult<Option<AssetRecord>> {
        let Some(mut asset) = self.db.asset(id)? else {
            return Ok(None);
        };
        if !matches!(
            asset.media_kind,
            MediaKind::Image | MediaKind::AnimatedImage | MediaKind::DesignFile
        ) {
            return Ok(None);
        }
        let already_present = asset
            .rich_metadata
            .as_ref()
            .is_some_and(|r| r.photo_exif.is_some() || r.ai_generation.is_some());
        if already_present {
            return Ok(Some(asset));
        }
        let Some(orig) = self.media.cached_original(&asset) else {
            return Ok(None);
        };
        let extracted = ImageMetadataExtractor::extract_from_path(&orig);
        if extracted.photo_exif.is_none() && extracted.ai_generation.is_none() {
            return Ok(None);
        }
        let mut rich = asset.rich_metadata.clone().unwrap_or_default();
        if let Some(exif) = extracted.photo_exif {
            rich.photo_exif = Some(exif);
        }
        if let Some(ai) = extracted.ai_generation {
            rich.ai_generation = Some(ai);
        }
        asset.rich_metadata = Some(rich);
        let saved = self.db.save_asset_locally(&asset, true)?;
        self.emit(EngineEvent::AssetEnriched(saved.id));
        Ok(Some(saved))
    }

    /// Re-resolves rich GitHub repository or Social Post metadata and regenerates its poster card.
    pub async fn refresh_rich_asset(&self, id: Uuid) -> CoreResult<AssetRecord> {
        let Some(mut current) = self.db.asset(id)? else {
            return Err(CoreError::NotFound(format_swift_uuid(&id)));
        };
        let Some(url) = current
            .source_url
            .as_deref()
            .and_then(|s| Url::parse(s).ok())
        else {
            return Ok(current);
        };

        if let Some(repo_ref) = GitHubRepoURLParser::parse(&url) {
            let repo = GitHubRepoResolver::resolve(&repo_ref).await;
            let mut rich = current.rich_metadata.clone().unwrap_or_default();
            current.title = repo.full_name.clone();
            if let Some(ref desc) = repo.description {
                if !desc.is_empty() {
                    current.notes = desc.clone();
                }
            }
            let poster = GitHubRepoResolver::fetch_open_graph_image(&repo)
                .await
                .unwrap_or_else(|| MediaArtwork::github_repo_card(&repo));
            let _ = self.media.write_custom_poster(&poster, &mut current);
            rich.github_repo = Some(repo);
            current.rich_metadata = Some(rich);
            let saved = self.db.save_asset_locally(&current, true)?;
            self.emit(EngineEvent::AssetEnriched(saved.id));
            return Ok(saved);
        }

        if let Some(social_ref) = SocialPostURLParser::parse(&url) {
            if let Some(resolved) = SocialPostResolver::resolve(&social_ref).await {
                let mut cover = None;
                if let Some(ref thumb) = resolved.primary_thumbnail_url {
                    if let Some((bytes, _)) = SocialPostResolver::download_media_bytes(
                        thumb,
                        SocialMediaAttachmentKind::Photo,
                    )
                    .await
                    {
                        cover = image::load_from_memory(&bytes).ok();
                    }
                }
                let card = MediaArtwork::social_post_card(&resolved.metadata, cover.as_ref());
                let _ = self.media.write_custom_poster(&card, &mut current);
                current.title = resolved.short_title();
                current.media_kind = MediaKind::WebBookmark;
                if !resolved.metadata.body_text.is_empty() {
                    current.ocr_text = Some(resolved.metadata.body_text.clone());
                }
                let mut rich = current.rich_metadata.clone().unwrap_or_default();
                rich.social_post = Some(resolved.metadata);
                current.rich_metadata = Some(rich);
                let saved = self.db.save_asset_locally(&current, true)?;
                self.emit(EngineEvent::AssetEnriched(saved.id));
                return Ok(saved);
            }
        }

        Ok(current)
    }

    // =========================================================================
    // Moodboards
    // =========================================================================

    pub fn fetch_boards(&self) -> CoreResult<Vec<MoodboardSummary>> {
        Ok(self
            .db
            .fetch_boards()?
            .into_iter()
            .map(|b| b.to_summary())
            .collect())
    }

    pub fn fetch_board(&self, id: Uuid) -> CoreResult<Option<MoodboardDocument>> {
        self.db.board(id)
    }

    pub fn save_board(&self, document: &MoodboardDocument) -> CoreResult<MoodboardDocument> {
        let saved = self.db.save_board_locally(document)?;
        self.emit(EngineEvent::BoardUpdated(saved.id));
        Ok(saved)
    }

    pub fn delete_board(&self, id: Uuid) -> CoreResult<()> {
        if self.db.board(id)?.is_none() {
            return Ok(());
        }
        self.db.record(SyncOperationChange::DeleteBoard(id), true)?;
        let _ = self
            .media
            .cache_stats_and_evict(&self.db, true, &HashSet::new(), None)?;
        self.emit(EngineEvent::LibraryChanged);
        Ok(())
    }

    pub fn set_board_pinned_offline(
        &self,
        id: Uuid,
        pinned: bool,
    ) -> CoreResult<MoodboardDocument> {
        let Some(mut board) = self.db.board(id)? else {
            return Err(CoreError::NotFound(format_swift_uuid(&id)));
        };
        board.pinned_offline = pinned;
        let saved = self.db.save_board_locally(&board)?;
        if !pinned {
            let _ = self
                .media
                .cache_stats_and_evict(&self.db, true, &HashSet::new(), None)?;
        }
        self.emit(EngineEvent::BoardUpdated(saved.id));
        Ok(saved)
    }

    // =========================================================================
    // Media Cache & Sample Seeder
    // =========================================================================

    pub fn cached_thumbnail_path(&self, asset_id: Uuid, tier: ThumbnailTier) -> Option<PathBuf> {
        self.media
            .thumbnail_url(asset_id, tier)
            .or_else(|| self.media.thumbnail_url(asset_id, ThumbnailTier::Grid520))
    }

    pub fn cached_original_path(&self, asset: &AssetRecord) -> Option<PathBuf> {
        self.media.cached_original(asset)
    }

    pub async fn original_path_or_download(&self, asset_id: Uuid) -> CoreResult<PathBuf> {
        if let Some(mut asset) = self.db.asset(asset_id)? {
            if let Some(path) = self.media.cached_original(&asset) {
                if !asset.is_local_original_cached {
                    asset.is_local_original_cached = true;
                    self.db.put_asset(&asset)?;
                }
                self.db.touch_original(asset_id, Utc::now())?;
                return Ok(path);
            }
        }
        let config = self.sync_config();
        let transport = self.build_transport(&config, false).await?;
        let downloaded = self
            .sync
            .download_original(asset_id, transport.as_ref())
            .await?;
        let mut keep = HashSet::new();
        keep.insert(asset_id);
        let _ = self
            .media
            .cache_stats_and_evict(&self.db, true, &keep, None)?;
        Ok(downloaded)
    }

    pub fn cache_stats(&self) -> CoreResult<CacheStats> {
        self.media
            .cache_stats_and_evict(&self.db, false, &HashSet::new(), None)
    }

    pub fn set_cache_budget_bytes(&self, bytes: i64) -> CoreResult<i64> {
        let clamped = MediaPipeline::set_cache_budget_bytes(&self.db, bytes)?;
        let _ = self
            .media
            .cache_stats_and_evict(&self.db, true, &HashSet::new(), None)?;
        Ok(clamped)
    }

    pub fn evict_cache_now(&self) -> CoreResult<CacheStats> {
        self.media
            .cache_stats_and_evict(&self.db, true, &HashSet::new(), None)
    }

    pub async fn seed_sample_library_if_empty(&self) -> CoreResult<bool> {
        let seeded = SampleLibrarySeeder::seed_if_empty(&self.db, &self.media).await?;
        if seeded {
            self.emit(EngineEvent::LibraryChanged);
        }
        Ok(seeded)
    }

    // =========================================================================
    // Sync Configuration, Transport Construction & Storage Migration
    // =========================================================================

    pub fn sync_config(&self) -> DriveSyncConfig {
        self.db
            .state::<DriveSyncConfig>("driveConfig")
            .ok()
            .flatten()
            .unwrap_or_default()
    }

    pub fn save_sync_config(&self, mut config: DriveSyncConfig) -> CoreResult<()> {
        validate_path_segments(&config.root_folder_name)?;
        if !config.webdav_remote_path.trim().is_empty() {
            validate_path_segments(&config.webdav_remote_path)?;
        }
        config.shared_folder_url_or_id = config.shared_folder_url_or_id.trim().to_string();
        if !config.shared_folder_url_or_id.is_empty()
            && config.resolved_shared_folder_id().is_none()
        {
            return Err(CoreError::InvalidPayload(
                "共享目录格式无效，请粘贴完整的 Google Drive 文件夹链接（含 /folders/…）或目录 ID。"
                    .to_string(),
            ));
        }
        config.auto_sync_interval_seconds = config.auto_sync_interval_seconds.max(0);
        self.db.set_state("driveConfig", Some(&config))
    }

    pub async fn sync_status(&self) -> SyncStatus {
        let mut status = self.sync.status().await;
        if status.last_synced_at.is_none()
            && matches!(status.phase, crate::models::sync::SyncPhase::Idle)
        {
            if let Ok(Some(persisted)) = self.db.state::<SyncStatus>("lastSyncStatus") {
                self.sync.restore_status(persisted).await;
                status = self.sync.status().await;
            }
        }
        let config = self.sync_config();
        if matches!(status.phase, crate::models::sync::SyncPhase::Idle) {
            status.active_mode = config.mode;
        }
        status
    }

    pub async fn has_webdav_password(&self) -> bool {
        self.vault
            .get_secret(WEBDAV_PASSWORD_VAULT_KEY)
            .await
            .ok()
            .flatten()
            .is_some_and(|s| !s.is_empty())
    }

    pub async fn save_webdav_password(&self, password: &str) -> CoreResult<()> {
        let trimmed = password.trim();
        let res = if trimmed.is_empty() {
            self.vault.delete_secret(WEBDAV_PASSWORD_VAULT_KEY).await
        } else {
            self.vault
                .set_secret(WEBDAV_PASSWORD_VAULT_KEY, trimmed)
                .await
        };
        res.map_err(CoreError::InvalidOperation)
    }

    pub async fn build_transport(
        &self,
        config: &DriveSyncConfig,
        allow_local_folder: bool,
    ) -> CoreResult<Arc<dyn DriveTransport>> {
        if let Some(ref injected) = self.injected_transport {
            return Ok(Arc::clone(injected));
        }
        match config.mode {
            DriveTransportMode::LocalOnly => {
                if !allow_local_folder {
                    return Err(CoreError::NotConfigured(
                        "当前为纯本地保存模式。".to_string(),
                    ));
                }
                let raw = config.local_library_path.trim();
                if raw.is_empty() {
                    return Err(CoreError::NotConfigured(
                        "请先选择一个本地文件夹作为素材库保存路径。".to_string(),
                    ));
                }
                let path = PathBuf::from(raw);
                let parent = path
                    .parent()
                    .filter(|p| !p.as_os_str().is_empty())
                    .map(Path::to_path_buf)
                    .unwrap_or(path);
                Ok(Arc::new(LocalFolderTransport::new(parent)))
            }
            DriveTransportMode::WebDav => {
                let password = self
                    .vault
                    .get_secret(WEBDAV_PASSWORD_VAULT_KEY)
                    .await
                    .ok()
                    .flatten()
                    .unwrap_or_default();
                let transport = WebDAVTransport::new(
                    &config.webdav_server_url,
                    &config.webdav_username,
                    &password,
                    &config.webdav_remote_path,
                )?;
                Ok(Arc::new(transport))
            }
            DriveTransportMode::GDirectMount => Ok(Arc::new(MountedVolumeTransport::new(
                &config.mount_path,
                Arc::clone(&self.mount_inspector),
            ))),
            DriveTransportMode::DirectApiWithGDirect => Ok(Arc::new(DirectAPITransport::new(
                Arc::clone(&self.oauth),
                &[],
            ))),
        }
    }

    /// Runs a full bidirectional sync cycle using the configured or injected transport.
    pub async fn sync_now(&self) -> CoreResult<SyncReport> {
        let config = self.sync_config();
        if config.mode == DriveTransportMode::LocalOnly
            && config.local_library_path.trim().is_empty()
        {
            return Ok(SyncReport::default());
        }
        let transport = self.build_transport(&config, true).await?;
        let report = self
            .sync
            .sync(
                transport.as_ref(),
                &config,
                config.mode == DriveTransportMode::LocalOnly,
            )
            .await?;
        if config.mode != DriveTransportMode::LocalOnly {
            let _ = self
                .media
                .cache_stats_and_evict(&self.db, true, &HashSet::new(), None)?;
        }
        if report.has_visible_library_changes() {
            self.emit(EngineEvent::LibraryChanged);
        }
        Ok(report)
    }

    /// Runs a full bidirectional sync cycle against an explicitly supplied `transport`.
    pub async fn sync_with_transport(
        &self,
        transport: &dyn DriveTransport,
        allow_local_folder_sync: bool,
    ) -> CoreResult<SyncReport> {
        let config = self.sync_config();
        let report = self
            .sync
            .sync(transport, &config, allow_local_folder_sync)
            .await?;
        if report.has_visible_library_changes() {
            self.emit(EngineEvent::LibraryChanged);
        }
        Ok(report)
    }

    /// Performs lossless two-way storage backend migration (Pure Local <-> Drive <-> WebDAV).
    pub async fn migrate_storage(
        &self,
        target_config: DriveSyncConfig,
        webdav_password: Option<&str>,
        source_transport_override: Option<&dyn DriveTransport>,
        target_transport_override: Option<&dyn DriveTransport>,
    ) -> CoreResult<StorageMigrationReport> {
        if let Some(pw) = webdav_password {
            if !pw.trim().is_empty() {
                self.save_webdav_password(pw).await?;
            }
        }
        let source_config = self.sync_config();

        let owned_target;
        let target_transport: &dyn DriveTransport = match target_transport_override {
            Some(t) => t,
            None => {
                owned_target = self.build_transport(&target_config, true).await?;
                owned_target.as_ref()
            }
        };

        let owned_source;
        let source_transport: Option<&dyn DriveTransport> = match source_transport_override {
            Some(t) => Some(t),
            None if source_config.mode != DriveTransportMode::LocalOnly => {
                owned_source = self.build_transport(&source_config, false).await.ok();
                owned_source.as_deref()
            }
            None => None,
        };

        let report = StorageMigration::migrate_storage(
            &self.db,
            &self.media,
            &self.sync,
            &source_config,
            source_transport,
            &target_config,
            target_transport,
        )
        .await?;
        self.emit(EngineEvent::LibraryChanged);
        Ok(report)
    }

    /// Runs the configured OS `NativeOcrProvider` on an existing asset's original or preview image
    /// and persists extracted text into SQLite + FTS5 immediately.
    pub async fn run_ocr_for_asset(&self, id: Uuid) -> CoreResult<Option<AssetRecord>> {
        let Some(mut asset) = self.db.asset(id)? else {
            return Ok(None);
        };
        let path = self
            .media
            .cached_original(&asset)
            .or_else(|| self.media.thumbnail_url(id, ThumbnailTier::Preview1400))
            .or_else(|| self.media.thumbnail_url(id, ThumbnailTier::Grid520));
        let Some(path) = path else {
            return Ok(Some(asset));
        };
        let bytes = std::fs::read(&path)?;
        if let Ok(Some(text)) = self.ocr.recognize_text(&bytes).await {
            let trimmed = text.trim();
            if !trimmed.is_empty() {
                asset.ocr_text = Some(trimmed.to_string());
                let saved = self.db.save_asset_locally(&asset, false)?;
                self.emit(EngineEvent::AssetEnriched(id));
                return Ok(Some(saved));
            }
        }
        Ok(Some(asset))
    }

    // =========================================================================
    // M4 Moodboard Curation, Editorial Layout & Exporters
    // =========================================================================

    pub async fn curate_moodboard<F>(
        &self,
        request: &MoodboardCurationRequest,
        on_step: F,
    ) -> CoreResult<MoodboardProposal>
    where
        F: FnMut(MoodboardAgentStep),
    {
        MoodboardAgentHarness::run(&self.db, request, None, on_step).await
    }

    pub fn solve_editorial_layout(
        &self,
        document: &MoodboardDocument,
        container_width: f64,
    ) -> CoreResult<EditorialLayoutResult> {
        let assets = self.load_board_asset_map(document)?;
        let cfg = match document.mode {
            BoardLayoutMode::AutoEditorial(c) => c,
            BoardLayoutMode::Freeform => AutoLayoutConfig::default(),
        };
        Ok(EditorialLayoutSolver::solve(
            &document.nodes,
            cfg,
            container_width,
            &assets,
            28.0,
        ))
    }

    pub fn export_board_image_bytes(
        &self,
        document: &MoodboardDocument,
        options: &MoodboardExportOptions,
    ) -> CoreResult<Vec<u8>> {
        let assets = self.load_board_asset_map(document)?;
        BoardImageExporter::render_bytes(document, &assets, &self.media, options)
    }

    pub fn export_board_figma_bridge(
        &self,
        document: &MoodboardDocument,
        options: &MoodboardExportOptions,
        destination_path: &Path,
    ) -> CoreResult<FigmaBridgeExportReport> {
        let assets = self.load_board_asset_map(document)?;
        FigmaBridgeExporter::export_bundle(
            document,
            &assets,
            &self.media,
            options,
            destination_path,
        )
    }

    fn load_board_asset_map(
        &self,
        document: &MoodboardDocument,
    ) -> CoreResult<HashMap<Uuid, AssetRecord>> {
        let mut map = HashMap::new();
        for id in document.referenced_asset_ids() {
            if let Some(asset) = self.db.asset(id)? {
                map.insert(id, asset);
            }
        }
        Ok(map)
    }
}

fn normalize_folder_name(raw: &str, parent: Option<Uuid>) -> CoreResult<String> {
    let trimmed = raw.trim();
    validate_drive_name(trimmed)?;
    if trimmed.starts_with('.') || (parent.is_none() && trimmed.eq_ignore_ascii_case("Inbox")) {
        return Err(CoreError::InvalidOperation(
            "This folder name is reserved.".to_string(),
        ));
    }
    Ok(trimmed.to_string())
}

fn ensure_unique_folder(
    name: &str,
    parent: Option<Uuid>,
    except: Option<Uuid>,
    folders: &[FolderRecord],
) -> CoreResult<()> {
    if folders
        .iter()
        .any(|f| Some(f.id) != except && f.parent_id == parent && f.name.eq_ignore_ascii_case(name))
    {
        return Err(CoreError::AlreadyExists(format!(
            "A folder named {name} already exists here."
        )));
    }
    Ok(())
}

fn mounted_relative_folder_path(
    folder_id: Option<Uuid>,
    folder_by_id: &HashMap<Uuid, FolderRecord>,
) -> String {
    let Some(mut cursor) = folder_id else {
        return "Inbox".to_string();
    };
    let mut parts = Vec::new();
    let mut visited = HashSet::new();
    while visited.insert(cursor) {
        let Some(f) = folder_by_id.get(&cursor) else {
            break;
        };
        parts.push(f.name.clone());
        match f.parent_id {
            Some(pid) => cursor = pid,
            None => break,
        }
    }
    if parts.is_empty() {
        "Inbox".to_string()
    } else {
        parts.reverse();
        parts.join("/")
    }
}
