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
use crate::intelligence::{MoodboardAgentHarness, TypeSafeImagePreparer};
use crate::layout::{EditorialLayoutResult, EditorialLayoutSolver};
use crate::media::artwork::MediaArtwork;
use crate::media::metadata::ImageMetadataExtractor;
use crate::media::resolvers::{
    GitHubRepoResolver, GitHubRepoURLParser, SocialPostResolver, SocialPostURLParser,
    WebBookmarkResolver,
};
use crate::media::xiaohongshu::XiaohongshuURLParser;
use crate::media::{LocalVisualDescriptor, MediaPipeline, SampleLibrarySeeder};
use crate::models::core::{
    AssetBatchPatch, AssetRecord, FilterCriteria, FolderRecord, FolderSuggestion, LabColor,
    MediaKind, QuickJumpMatch, ScoredAsset, SmartFolderRecord, SocialMediaAttachmentKind,
    SocialPlatform, TagCount,
};
use crate::models::media::{
    cosine_similarity, AssetVector, CacheStats, CaptureInput, ThumbnailTier,
};
use crate::models::moodboard::{
    AutoLayoutConfig, BoardLayoutMode, BoardNode, BoardNodeKind, BoardRect, MoodboardAgentStep,
    MoodboardCurationRequest, MoodboardDocument, MoodboardProposal, MoodboardSummary,
};
use crate::models::sync::{
    DriveSyncConfig, DriveTransportMode, StorageMigrationReport, SyncOperationChange, SyncReport,
    SyncStatus,
};
use crate::sync::{
    validate_drive_name, validate_path_segments, DirectAPITransport, DriveSyncEngine,
    DriveTransport, GoogleOAuthClient, LocalFolderTransport, MountedVolumeTransport,
    StorageMigration, WebDAVTransport,
};
use crate::traits::{
    BasicVolumeMountInspector, InMemorySecretVault, NativeOcrProvider, NoopOcrProvider,
    SecretVault, VolumeMountInspector,
};
use crate::wire::swift_codec::{format_swift_uuid, upper_uuid, upper_uuid_vec};

const WEBDAV_PASSWORD_VAULT_KEY: &str = "sync.webdav.password";

/// Single ranked hit returned by [`LiveCharkleEngine::semantic_search_local`].
#[derive(Debug, Clone)]
pub struct LocalSemanticSearchHit {
    pub asset: AssetRecord,
    pub score: f64,
    pub reason: String,
    pub source_label: &'static str,
}

/// Report returned by [`LiveCharkleEngine::semantic_search_local`].
#[derive(Debug, Clone)]
pub struct LocalSemanticSearchReport {
    pub query: String,
    pub summary: String,
    pub hits: Vec<LocalSemanticSearchHit>,
}

/// Broadcast events pushed to Tauri WebView or CLI listeners.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "type", content = "payload", rename_all = "camelCase")]
pub enum EngineEvent {
    SyncStatus(SyncStatus),
    SyncProgressiveMetadata { has_boards: bool },
    SyncProgressiveThumbnails(#[serde(with = "upper_uuid_vec")] Vec<Uuid>),
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
        let (events, _) = broadcast::channel(256);
        let events_for_sync = events.clone();
        let events_for_progressive = events.clone();
        let sync = Arc::new(DriveSyncEngine::with_callbacks(
            Arc::clone(&db),
            media.clone(),
            Arc::new(move |status| {
                let _ = events_for_sync.send(EngineEvent::SyncStatus(status));
            }),
            Arc::new(move |prog| match prog {
                crate::sync::SyncProgressiveEvent::Metadata { has_boards } => {
                    let _ = events_for_progressive
                        .send(EngineEvent::SyncProgressiveMetadata { has_boards });
                }
                crate::sync::SyncProgressiveEvent::Thumbnails { asset_ids } => {
                    let _ = events_for_progressive
                        .send(EngineEvent::SyncProgressiveThumbnails(asset_ids));
                }
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

    pub fn vault(&self) -> &Arc<dyn SecretVault> {
        &self.vault
    }

    pub fn notify_external_change(&self) {
        self.emit(EngineEvent::LibraryChanged);
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

    pub fn asset_ids_matching_prefix(&self, prefix: &str, limit: usize) -> CoreResult<Vec<Uuid>> {
        self.db.asset_ids_matching_prefix(prefix, limit)
    }

    pub fn folder_ids_matching_prefix(&self, prefix: &str, limit: usize) -> CoreResult<Vec<Uuid>> {
        self.db.folder_ids_matching_prefix(prefix, limit)
    }

    pub fn board_ids_matching_prefix(&self, prefix: &str, limit: usize) -> CoreResult<Vec<Uuid>> {
        self.db.board_ids_matching_prefix(prefix, limit)
    }

    pub fn visual_descriptors_for_assets(
        &self,
        assets: &[AssetRecord],
        priority_ids: &[Uuid],
        max_extract: usize,
    ) -> HashMap<Uuid, LocalVisualDescriptor> {
        self.ensure_visual_descriptors(assets, priority_ids, max_extract)
    }

    pub fn vectors_map(&self) -> CoreResult<HashMap<Uuid, AssetVector>> {
        self.db.vectors()
    }

    #[cfg(test)]
    pub(crate) fn db(&self) -> &LibraryDatabase {
        &self.db
    }

    /// Computes calibrated pairwise visual similarity in `0.0..=1.0` between two assets using
    /// local perceptual visual descriptors, cached embeddings, and weighted CIELAB palette proximity.
    pub fn visual_pair_similarity(
        a: &AssetRecord,
        b: &AssetRecord,
        vectors: &HashMap<Uuid, crate::models::media::AssetVector>,
        descriptors: &HashMap<Uuid, LocalVisualDescriptor>,
    ) -> f64 {
        let mut best = 0.0_f64;
        if let (Some(da), Some(db)) = (descriptors.get(&a.id), descriptors.get(&b.id)) {
            best = best.max(da.similarity(db));
        }
        if let (Some(va), Some(vb)) = (vectors.get(&a.id), vectors.get(&b.id)) {
            if let (Some(ea), Some(eb)) = (va.embedding.as_deref(), vb.embedding.as_deref()) {
                if ea.len() == eb.len() && !ea.is_empty() {
                    if let Some(cos) = crate::models::media::cosine_similarity(ea, eb) {
                        best = best.max(f64::from(cos.clamp(0.0, 1.0)));
                    }
                }
            }
        }
        if !a.dominant_colors.is_empty() && !b.dominant_colors.is_empty() {
            let mut min_de = f64::INFINITY;
            for ca in a.dominant_colors.iter().take(3) {
                for cb in b.dominant_colors.iter().take(3) {
                    let de = ca.delta_e_2000(cb);
                    if de.is_finite() && de < min_de {
                        min_de = de;
                    }
                }
            }
            if min_de < 22.0 {
                best = best.max((1.0 - min_de / 22.0) * 0.65);
            }
        }
        best.clamp(0.0, 1.0)
    }

    /// Local bilingual EN↔ZH + CJK tokenization + CIELAB tone/aspect/color + positive seed
    /// + negative `unlike_asset_ids` repulsion hybrid semantic search.
    pub fn semantic_search_local(
        &self,
        query: &str,
        criteria: &FilterCriteria,
        limit: usize,
        seed_asset_ids: &[Uuid],
        unlike_asset_ids: &[Uuid],
    ) -> CoreResult<LocalSemanticSearchReport> {
        use crate::intelligence::VisualQueryIntelligence;

        let trimmed = query.trim();
        let mut base_criteria = criteria.clone();
        base_criteria.search_query.clear();
        let candidates = self.db.fetch_assets(&base_criteria, None)?;
        if candidates.is_empty() {
            return Ok(LocalSemanticSearchReport {
                query: trimmed.to_string(),
                summary: format!("语义检索「{trimmed}」未命中匹配素材"),
                hits: Vec::new(),
            });
        }

        let folders = self.db.fetch_folders()?;
        let folder_by_id: HashMap<Uuid, &FolderRecord> =
            folders.iter().map(|f| (f.id, f)).collect();
        let folder_paths: HashMap<Uuid, String> = folders
            .iter()
            .map(|f| (f.id, build_folder_display_path(f.id, &folder_by_id)))
            .collect();

        let base_terms = search_text::query_terms(trimmed);
        let visual_hints = VisualQueryIntelligence::parse_visual_hints(trimmed, &base_terms);
        let norm_base_terms: Vec<String> = base_terms
            .iter()
            .map(|t| search_text::normalize(t))
            .filter(|t| !t.is_empty())
            .collect();
        let norm_expanded_terms: Vec<String> = visual_hints
            .expanded_terms
            .iter()
            .map(|t| search_text::normalize(t))
            .filter(|t| !t.is_empty())
            .collect();
        let norm_full_query = search_text::normalize(trimmed);

        let vectors = self.db.vectors().unwrap_or_default();
        let mut seed_assets = Vec::new();
        for &sid in seed_asset_ids {
            if let Some(a) = self.db.asset(sid)? {
                seed_assets.push(a);
            }
        }
        let mut unlike_assets = Vec::new();
        for &uid in unlike_asset_ids {
            if let Some(a) = self.db.asset(uid)? {
                unlike_assets.push(a);
            }
        }
        let need_visual = !seed_assets.is_empty() || !unlike_assets.is_empty();
        let descriptors = if need_visual {
            let mut all_for_desc = candidates.clone();
            all_for_desc.extend(seed_assets.iter().cloned());
            all_for_desc.extend(unlike_assets.iter().cloned());
            let mut priority = Vec::new();
            priority.extend_from_slice(seed_asset_ids);
            priority.extend_from_slice(unlike_asset_ids);
            self.ensure_visual_descriptors(&all_for_desc, &priority, 200)
        } else {
            HashMap::new()
        };

        let seed_set: HashSet<Uuid> = seed_asset_ids.iter().copied().collect();
        let unlike_set: HashSet<Uuid> = unlike_asset_ids.iter().copied().collect();
        let has_visual_hints = !visual_hints.tones.is_empty()
            || !visual_hints.aspect_shapes.is_empty()
            || !visual_hints.target_colors.is_empty();

        let mut hits: Vec<LocalSemanticSearchHit> = Vec::new();
        for asset in candidates {
            if unlike_set.contains(&asset.id) {
                continue;
            }
            if trimmed.is_empty() && seed_set.contains(&asset.id) {
                continue;
            }

            let folder_path = asset
                .folder_id
                .and_then(|fid| folder_paths.get(&fid))
                .map(String::as_str)
                .unwrap_or("");
            let title_norm = search_text::normalize(&asset.title);
            let file_norm = search_text::normalize(&asset.file_name);
            let desc_norm = search_text::normalize(asset.ai_description.as_deref().unwrap_or(""));
            let notes_norm = search_text::normalize(&asset.notes);
            let ocr_norm = search_text::normalize(asset.ocr_text.as_deref().unwrap_or(""));
            let folder_norm = search_text::normalize(folder_path);
            let tags_norm: Vec<String> = asset
                .tags
                .iter()
                .chain(asset.suggested_tags.iter())
                .map(|t| search_text::normalize(t))
                .filter(|t| !t.is_empty())
                .collect();

            let mut raw_text = 0.0_f64;
            let mut ft_boost = 0.0_f64;

            if !norm_full_query.is_empty() {
                if title_norm.contains(&norm_full_query) {
                    raw_text += 0.55;
                } else if tags_norm.iter().any(|t| t == &norm_full_query) {
                    ft_boost += 0.55;
                } else if desc_norm.contains(&norm_full_query)
                    || notes_norm.contains(&norm_full_query)
                {
                    raw_text += 0.42;
                } else if folder_norm.contains(&norm_full_query) {
                    ft_boost += 0.36;
                }
            }

            if !norm_base_terms.is_empty() {
                let mut matched_base = 0usize;
                for term in &norm_base_terms {
                    let mut term_hit = false;
                    if tags_norm.iter().any(|t| t == term || t.contains(term)) {
                        ft_boost += 0.30;
                        term_hit = true;
                    }
                    if folder_norm.contains(term) {
                        ft_boost += 0.22;
                        term_hit = true;
                    }
                    if title_norm.contains(term) || file_norm.contains(term) {
                        raw_text += 0.26;
                        term_hit = true;
                    } else if desc_norm.contains(term)
                        || notes_norm.contains(term)
                        || ocr_norm.contains(term)
                    {
                        raw_text += 0.18;
                        term_hit = true;
                    } else if search_text::fuzzy_score(term, &asset.title).is_some() {
                        raw_text += 0.14;
                        term_hit = true;
                    }
                    if term_hit {
                        matched_base += 1;
                    }
                }
                if matched_base > 0 {
                    let coverage = matched_base as f64 / norm_base_terms.len() as f64;
                    raw_text += coverage * 0.22;
                }
            }

            if !norm_expanded_terms.is_empty() {
                let mut exp_hits = 0usize;
                for term in &norm_expanded_terms {
                    if tags_norm.iter().any(|t| t == term || t.contains(term)) {
                        ft_boost += 0.22;
                        exp_hits += 1;
                    } else if folder_norm.contains(term) {
                        ft_boost += 0.16;
                        exp_hits += 1;
                    } else if title_norm.contains(term)
                        || desc_norm.contains(term)
                        || notes_norm.contains(term)
                    {
                        raw_text += 0.14;
                        exp_hits += 1;
                    }
                }
                if exp_hits > 0 {
                    raw_text += (exp_hits.min(3) as f64) * 0.05;
                }
            }

            let t_score = (raw_text + ft_boost).min(1.0);

            let s_score = if !seed_assets.is_empty() {
                seed_assets
                    .iter()
                    .map(|seed| Self::visual_pair_similarity(&asset, seed, &vectors, &descriptors))
                    .fold(0.0_f64, f64::max)
            } else {
                0.0
            };

            let hint_match = VisualQueryIntelligence::visual_hint_score(&asset, &visual_hints);
            let h_score = hint_match.as_ref().map(|(s, _)| *s).unwrap_or(0.0);

            let mut reasons: Vec<String> = Vec::new();
            let mut combined: f64;
            let source_label: &'static str;

            if s_score >= 0.22 && t_score > 0.05 {
                reasons.push(format!(
                    "种子视觉相似 {}%",
                    (s_score * 100.0).round() as i32
                ));
                reasons.push("语义分词/标签命中".to_string());
                if let Some((hs, ref hr)) = hint_match {
                    if hs >= 0.48 {
                        reasons.push(hr.clone());
                    }
                }
                combined = (s_score * 0.50 + t_score * 0.52 + h_score * 0.14).min(1.0);
                source_label = "本地多信号(视觉+全文)";
            } else if s_score >= 0.25 && trimmed.is_empty() {
                reasons.push(format!(
                    "种子视觉相似 {}%",
                    (s_score * 100.0).round() as i32
                ));
                combined = s_score;
                source_label = "种子视觉相似";
            } else if t_score > 0.05 {
                if ft_boost > 0.0 && raw_text > 0.0 {
                    reasons.push("双语分词 + 标签/目录命中".to_string());
                } else if ft_boost > 0.0 {
                    reasons.push("标签/目录命中".to_string());
                } else {
                    reasons.push("分词/标签/拼音匹配".to_string());
                }
                if let Some((hs, ref hr)) = hint_match {
                    if hs >= 0.45 {
                        reasons.push(hr.clone());
                        combined = (t_score * 0.78 + hs * 0.26).min(1.0);
                    } else {
                        let aspect_penalty = if !visual_hints.aspect_shapes.is_empty()
                            && !visual_hints.aspect_shapes.contains(&asset.aspect_shape())
                        {
                            0.78
                        } else {
                            1.0
                        };
                        combined = t_score * 0.88 * aspect_penalty;
                    }
                } else {
                    let aspect_penalty = if !visual_hints.aspect_shapes.is_empty()
                        && !visual_hints.aspect_shapes.contains(&asset.aspect_shape())
                    {
                        0.78
                    } else {
                        1.0
                    };
                    combined = t_score * 0.88 * aspect_penalty;
                }
                source_label = "本机多信号";
            } else if let Some((hs, ref hr)) = hint_match {
                if hs >= 0.62 && !visual_hints.tones.is_empty() {
                    reasons.push(hr.clone());
                    combined = hs * 0.72;
                    source_label = "CIELAB 视觉氛围";
                } else {
                    continue;
                }
            } else {
                continue;
            }

            // Apply negative visual repulsion when `unlike_asset_ids` is provided
            if !unlike_assets.is_empty() {
                let max_neg = unlike_assets
                    .iter()
                    .map(|neg| Self::visual_pair_similarity(&asset, neg, &vectors, &descriptors))
                    .fold(0.0_f64, f64::max);
                if max_neg >= 0.42 {
                    let penalty = (1.0 - (max_neg - 0.35) * 1.15).max(0.15);
                    combined *= penalty;
                }
            }

            combined = (combined + (asset.rating as f64) * 0.015).min(1.0);
            if combined < 0.08 {
                continue;
            }

            hits.push(LocalSemanticSearchHit {
                asset,
                score: combined,
                reason: reasons.join(" · "),
                source_label,
            });
        }

        hits.sort_by(|a, b| {
            b.score
                .partial_cmp(&a.score)
                .unwrap_or(std::cmp::Ordering::Equal)
        });
        hits.truncate(limit.max(1));

        let mut engines = Vec::new();
        if !seed_assets.is_empty() {
            engines.push("本地种子视觉");
        }
        if !unlike_assets.is_empty() {
            engines.push("负向视觉排斥");
        }
        if has_visual_hints {
            engines.push("CIELAB氛围/画幅");
        }
        if engines.is_empty() {
            engines.push("本机双语分词/标签/拼音");
        }
        let summary = if hits.is_empty() {
            format!(
                "语义检索「{trimmed}」未命中高度相关素材（{}）",
                engines.join(" + ")
            )
        } else {
            format!(
                "语义检索「{trimmed}」命中 {} 项素材（{}）",
                hits.len(),
                engines.join(" + ")
            )
        };

        Ok(LocalSemanticSearchReport {
            query: trimmed.to_string(),
            summary,
            hits,
        })
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
            let _ = self.index_local_visual_descriptor(&saved);
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

    /// Ingests raw OS file and/or folder paths, mirroring any dropped directories as Charkle
    /// folders (and nested subfolders) under `target_folder_id`, reusing case-insensitively
    /// matching sibling folders when present, and importing loose files directly into
    /// `target_folder_id`.
    ///
    /// Unlike single-batch `ingest`, per-file failures inside dropped directories are skipped
    /// with a warning rather than rolling back valid siblings, and empty dropped folders still
    /// create their corresponding library folder(s).
    pub async fn ingest_local_paths(
        &self,
        raw_paths: Vec<PathBuf>,
        target_folder_id: Option<Uuid>,
        target_board_id: Option<Uuid>,
    ) -> CoreResult<IngestPathsReport> {
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
        if raw_paths.is_empty() {
            return Ok(IngestPathsReport::default());
        }

        let plan = tokio::task::spawn_blocking(move || plan_local_path_ingest(raw_paths))
            .await
            .map_err(|e| CoreError::Media(format!("Path scan task failed: {e}")))?;

        let mut report = IngestPathsReport::default();
        let mut folders_snapshot = self.db.fetch_folders()?;
        let mut ingest_groups: Vec<(Option<Uuid>, Vec<PathBuf>)> = Vec::new();

        if !plan.loose_files.is_empty() {
            ingest_groups.push((target_folder_id, plan.loose_files));
        }

        #[allow(clippy::too_many_arguments)]
        fn materialize_folder_tree(
            engine: &LiveCharkleEngine,
            node: PlannedFolderNode,
            parent_id: Option<Uuid>,
            is_top_level: bool,
            folders_snapshot: &mut Vec<FolderRecord>,
            created_folders: &mut Vec<FolderRecord>,
            matched_folder_names: &mut Vec<String>,
            ingest_groups: &mut Vec<(Option<Uuid>, Vec<PathBuf>)>,
        ) -> CoreResult<()> {
            let folder = ensure_or_create_import_folder(
                engine,
                &node.name,
                parent_id,
                folders_snapshot,
                created_folders,
            )?;
            if is_top_level {
                matched_folder_names.push(folder.name.clone());
            }
            if !node.files.is_empty() {
                ingest_groups.push((Some(folder.id), node.files));
            }
            for child in node.children {
                materialize_folder_tree(
                    engine,
                    child,
                    Some(folder.id),
                    false,
                    folders_snapshot,
                    created_folders,
                    matched_folder_names,
                    ingest_groups,
                )?;
            }
            Ok(())
        }

        for root_node in plan.root_folders {
            materialize_folder_tree(
                self,
                root_node,
                target_folder_id,
                true,
                &mut folders_snapshot,
                &mut report.created_folders,
                &mut report.matched_folder_names,
                &mut ingest_groups,
            )?;
        }

        let total_planned_files: usize = ingest_groups.iter().map(|(_, files)| files.len()).sum();
        let mut last_error: Option<CoreError> = None;

        for (group_folder_id, files) in ingest_groups {
            if total_planned_files == 1 && report.matched_folder_names.is_empty() {
                // Single loose file: preserve strict error propagation.
                let created = self
                    .ingest(
                        files.into_iter().map(CaptureInput::FilePath).collect(),
                        group_folder_id,
                        target_board_id,
                    )
                    .await?;
                report.assets.extend(created);
                continue;
            }

            // Multi-file or folder drop: ingest resiliently per file so one unreadable/locked
            // file inside an OS folder never rolls back the rest of the folder import.
            for file_path in files {
                match self
                    .ingest(
                        vec![CaptureInput::FilePath(file_path.clone())],
                        group_folder_id,
                        target_board_id,
                    )
                    .await
                {
                    Ok(created) => report.assets.extend(created),
                    Err(err) => {
                        tracing::warn!(
                            path = %file_path.display(),
                            %err,
                            "Skipped uningestable file during folder/batch drop"
                        );
                        report.skipped_files += 1;
                        last_error = Some(err);
                    }
                }
            }
        }

        if report.assets.is_empty()
            && report.created_folders.is_empty()
            && report.matched_folder_names.is_empty()
        {
            if let Some(err) = last_error {
                return Err(err);
            }
        }

        Ok(report)
    }

    /// Applies an `AssetBatchPatch` atomically across one or more assets with CRDT delta recording.
    pub fn update_assets(&self, patch: &AssetBatchPatch) -> CoreResult<Vec<AssetRecord>> {
        let changed = self.db.update_assets_locally(patch)?;

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

        let deleted =
            self.db
                .permanently_delete_assets_locally(ids, &root_prefix, &precomputed_md5)?;

        let _ = self.media.cleanup_deleted_media(&self.db);
        if deleted > 0 {
            self.emit(EngineEvent::LibraryChanged);
        }
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
        self.db.delete_folder(id, trash_contents)?;
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

    /// Extracts and caches a strictly local perceptual visual descriptor for `asset`
    /// from its `Grid520.jpg` thumbnail (or cached original image if no thumbnail exists).
    pub fn index_local_visual_descriptor(&self, asset: &AssetRecord) -> bool {
        let Some(path) = self.visual_descriptor_source_path(asset) else {
            return false;
        };
        let Some(desc) = LocalVisualDescriptor::extract_from_path(&path) else {
            return false;
        };
        let fp = visual_descriptor_fingerprint(asset);
        self.db
            .save_local_visual_descriptor(asset.id, &fp, &desc.to_bytes())
            .is_ok()
    }

    fn visual_descriptor_source_path(&self, asset: &AssetRecord) -> Option<PathBuf> {
        if let Some(thumb) = self.media.thumbnail_url(asset.id, ThumbnailTier::Grid520) {
            return Some(thumb);
        }
        if matches!(
            asset.media_kind,
            MediaKind::Image | MediaKind::AnimatedImage | MediaKind::DesignFile
        ) {
            return self.media.cached_original(asset);
        }
        None
    }

    /// Loads and resizes an asset's preview into a TypeSafe-compliant upright JPEG (`280..=1568px`)
    /// for visual grounding or cloud AI Inbox triage.
    pub fn prepare_visual_grounding_jpeg(
        &self,
        asset: &AssetRecord,
        target_long_side: u32,
    ) -> Option<Vec<u8>> {
        let path = self.visual_descriptor_source_path(asset)?;
        let img = image::open(&path).ok()?;
        TypeSafeImagePreparer::prepare_jpeg(&img, target_long_side).ok()
    }

    fn ensure_visual_descriptors(
        &self,
        assets: &[AssetRecord],
        priority_ids: &[Uuid],
        max_compute: usize,
    ) -> HashMap<Uuid, LocalVisualDescriptor> {
        let cached = self.db.local_visual_descriptors().unwrap_or_default();
        let mut out = HashMap::with_capacity(assets.len());
        let mut missing_priority: Vec<&AssetRecord> = Vec::new();
        let mut missing_others: Vec<&AssetRecord> = Vec::new();
        let priority_set: HashSet<Uuid> = priority_ids.iter().copied().collect();

        for asset in assets {
            let fp = visual_descriptor_fingerprint(asset);
            if let Some((cached_fp, bytes)) = cached.get(&asset.id) {
                if cached_fp == &fp {
                    if let Some(desc) = LocalVisualDescriptor::from_bytes(bytes) {
                        out.insert(asset.id, desc);
                        continue;
                    }
                }
            }
            if priority_set.contains(&asset.id) {
                missing_priority.push(asset);
            } else {
                missing_others.push(asset);
            }
        }

        let mut computed = 0usize;
        for asset in missing_priority.into_iter().chain(missing_others) {
            if computed >= max_compute && !priority_set.contains(&asset.id) {
                break;
            }
            let Some(path) = self.visual_descriptor_source_path(asset) else {
                continue;
            };
            let Some(desc) = LocalVisualDescriptor::extract_from_path(&path) else {
                continue;
            };
            let fp = visual_descriptor_fingerprint(asset);
            let _ = self
                .db
                .save_local_visual_descriptor(asset.id, &fp, &desc.to_bytes());
            out.insert(asset.id, desc);
            computed += 1;
        }
        out
    }

    /// Computes multi-signal similarity rankings using cloud semantic embeddings, local
    /// perceptual visual descriptors, symmetric weighted CIELAB palette harmony, tag overlap,
    /// lexical content affinity, and MMR diversity reranking.
    ///
    /// Never pads unrelated assets with free `media_kind` or `folder_id` points; returns an
    /// empty list honestly when no genuinely similar asset exists.
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
        let descriptors = self.ensure_visual_descriptors(&all, &[asset_id], 180);

        let anchor_ctx =
            AssetMatchContext::new(&anchor, vectors.get(&asset_id), descriptors.get(&asset_id));

        let mut matches = Vec::new();
        for cand in all {
            if cand.id == asset_id {
                continue;
            }
            let scored = score_asset_pair(
                &anchor_ctx,
                cand,
                vectors.get(&asset_id),
                &vectors,
                &descriptors,
            );
            if !scored.match_reasons.is_empty() && scored.score >= 0.24 {
                matches.push(scored);
            }
        }

        Ok(rerank_similar_mmr(matches, &vectors, &descriptors, limit))
    }

    /// Suggests the best-fitting existing folder for Inbox Triage using folder-name/path
    /// word-boundary matching, IDF-weighted folder tag profiles, and multi-signal peer
    /// similarity (local visual descriptors, embeddings, weighted palette harmony, shared tags).
    ///
    /// Returns `Ok(None)` honestly when no folder genuinely fits rather than forcing a fallback.
    pub fn suggest_folder(&self, asset_id: Uuid) -> CoreResult<Option<FolderSuggestion>> {
        let Some(asset) = self.db.asset(asset_id)? else {
            return Ok(None);
        };
        let mut results = self.suggest_folders_for_assets(&[asset])?;
        Ok(results.pop().and_then(|(_, suggestion)| suggestion))
    }

    /// Batch version of [`Self::suggest_folder`] that loads folders, peers, vectors, and local
    /// visual descriptors once across all target assets.
    pub fn suggest_folders_for_assets(
        &self,
        targets: &[AssetRecord],
    ) -> CoreResult<Vec<(Uuid, Option<FolderSuggestion>)>> {
        if targets.is_empty() {
            return Ok(Vec::new());
        }
        let folders = self.db.fetch_folders()?;
        if folders.is_empty() {
            return Ok(targets.iter().map(|a| (a.id, None)).collect());
        }
        let all_assets = self.db.fetch_assets(
            &FilterCriteria {
                include_trashed: false,
                ..FilterCriteria::default()
            },
            None,
        )?;
        let vectors = self.db.vectors().unwrap_or_default();
        let priority_ids: Vec<Uuid> = targets.iter().map(|a| a.id).collect();
        let descriptors = self.ensure_visual_descriptors(&all_assets, &priority_ids, 220);

        let folder_by_id: HashMap<Uuid, &FolderRecord> =
            folders.iter().map(|f| (f.id, f)).collect();
        let folder_paths: HashMap<Uuid, String> = folders
            .iter()
            .map(|f| (f.id, build_folder_display_path(f.id, &folder_by_id)))
            .collect();

        let mut by_folder: HashMap<Uuid, Vec<&AssetRecord>> = HashMap::new();
        for item in &all_assets {
            if let Some(fid) = item.folder_id {
                by_folder.entry(fid).or_default().push(item);
            }
        }

        // Build per-folder tag frequency profiles and cross-folder document frequency (IDF)
        let mut folder_tag_counts: HashMap<Uuid, HashMap<String, (usize, String)>> = HashMap::new();
        let mut tag_folder_df: HashMap<String, usize> = HashMap::new();
        for (&fid, members) in &by_folder {
            let mut counts: HashMap<String, (usize, String)> = HashMap::new();
            for m in members {
                let mut seen_in_member = HashSet::new();
                for raw_tag in m.tags.iter().chain(m.suggested_tags.iter()) {
                    let norm = search_text::normalize(raw_tag);
                    if norm.is_empty() || !seen_in_member.insert(norm.clone()) {
                        continue;
                    }
                    counts
                        .entry(norm)
                        .and_modify(|(c, _)| *c += 1)
                        .or_insert_with(|| (1, raw_tag.clone()));
                }
            }
            for norm in counts.keys() {
                *tag_folder_df.entry(norm.clone()).or_insert(0) += 1;
            }
            folder_tag_counts.insert(fid, counts);
        }
        let non_empty_folder_count = by_folder.len().max(1) as f64;

        let mut output = Vec::with_capacity(targets.len());
        for asset in targets {
            let anchor_ctx =
                AssetMatchContext::new(asset, vectors.get(&asset.id), descriptors.get(&asset.id));
            let asset_full_text_norm = search_text::normalize(&format!(
                "{} {} {} {} {} {} {}",
                asset.title,
                asset.file_name,
                asset.notes,
                asset.tags.join(" "),
                asset.suggested_tags.join(" "),
                asset.ai_description.as_deref().unwrap_or(""),
                asset.ocr_text.as_deref().unwrap_or("")
            ));

            let mut best: Option<(f64, FolderSuggestion)> = None;
            for folder in &folders {
                if Some(folder.id) == asset.folder_id {
                    continue;
                }

                // 1. Folder name / path match (word-boundary ASCII + CJK phrase match)
                let path_str = folder_paths
                    .get(&folder.id)
                    .map(String::as_str)
                    .unwrap_or(&folder.name);
                let name_score = score_folder_name_match(
                    &folder.name,
                    path_str,
                    &anchor_ctx.tags,
                    &anchor_ctx.tokens,
                    &asset_full_text_norm,
                );

                // 2. Folder characteristic tag profile match (IDF-weighted)
                let mut tag_profile_score = 0.0_f64;
                let mut top_matched_tag: Option<String> = None;
                if let Some(tag_map) = folder_tag_counts.get(&folder.id) {
                    let member_total = by_folder
                        .get(&folder.id)
                        .map(|v| v.len())
                        .unwrap_or(1)
                        .max(1) as f64;
                    let mut best_idf = 0.0_f64;
                    let mut accum = 0.0_f64;
                    for (norm_tag, (cnt, display)) in tag_map {
                        let asset_has_tag = anchor_ctx.tags.contains(norm_tag)
                            || anchor_ctx.tokens.contains(norm_tag);
                        if !asset_has_tag {
                            continue;
                        }
                        let df = *tag_folder_df.get(norm_tag).unwrap_or(&1) as f64;
                        let idf = ((non_empty_folder_count + 1.0) / (df + 0.5)).ln().max(0.35);
                        let prevalence = (*cnt as f64 / member_total).clamp(0.15, 1.0);
                        let contrib = (0.34 + 0.28 * prevalence) * (idf / 1.4).clamp(0.5, 1.35);
                        accum += contrib;
                        if contrib > best_idf {
                            best_idf = contrib;
                            top_matched_tag = Some(display.clone());
                        }
                    }
                    tag_profile_score = accum.min(0.86);
                }

                // 3. Peer visual / embedding / palette / tag similarity against categorized members
                let mut peer_affinity = 0.0_f64;
                let mut matched_peer_count = 0usize;
                let mut top_peer_reason: Option<String> = None;
                if let Some(members) = by_folder.get(&folder.id) {
                    let mut peer_scores: Vec<(f64, String)> = Vec::new();
                    for &member in members {
                        if member.id == asset.id {
                            continue;
                        }
                        let scored = score_asset_pair(
                            &anchor_ctx,
                            member.clone(),
                            vectors.get(&asset.id),
                            &vectors,
                            &descriptors,
                        );
                        if !scored.match_reasons.is_empty() && scored.score >= 0.24 {
                            let primary_reason = scored
                                .match_reasons
                                .first()
                                .cloned()
                                .unwrap_or_else(|| "视觉风格相近".to_string());
                            peer_scores.push((scored.score, primary_reason));
                        }
                    }
                    peer_scores
                        .sort_by(|a, b| b.0.partial_cmp(&a.0).unwrap_or(std::cmp::Ordering::Equal));
                    matched_peer_count = peer_scores.len();
                    if !peer_scores.is_empty() {
                        let top_k = &peer_scores[..peer_scores.len().min(3)];
                        let mean_top =
                            top_k.iter().map(|(s, _)| *s).sum::<f64>() / (top_k.len() as f64);
                        let support_bonus = if matched_peer_count >= 3 {
                            0.08
                        } else if matched_peer_count == 2 {
                            0.04
                        } else {
                            0.0
                        };
                        peer_affinity = (mean_top * 0.92 + support_bonus).min(0.92);
                        top_peer_reason = Some(top_k[0].1.clone());
                    }
                }

                // Combine independent evidence cleanly (never blindly fabricate a score when all 3 are 0)
                let primary = name_score.max(tag_profile_score).max(peer_affinity);
                if primary < 0.34 {
                    continue;
                }
                let supporting =
                    (name_score + tag_profile_score + peer_affinity - primary).min(0.45);
                let combined = (primary + supporting * 0.28).min(0.98);

                let reason = if name_score >= tag_profile_score && name_score >= peer_affinity {
                    format!("标题或标签与目录「{}」主题吻合", folder.name)
                } else if tag_profile_score >= peer_affinity {
                    if let Some(tag) = top_matched_tag {
                        format!("与「{}」中标签「{tag}」一致", folder.name)
                    } else {
                        format!("标签特征与「{}」高度一致", folder.name)
                    }
                } else if let Some(peer_reason) = top_peer_reason {
                    if matched_peer_count >= 2 {
                        format!(
                            "与「{}」内 {matched_peer_count} 项素材{peer_reason}",
                            folder.name
                        )
                    } else {
                        format!("与「{}」内已有素材{peer_reason}", folder.name)
                    }
                } else {
                    format!("与「{}」目录内容相近", folder.name)
                };

                let is_better = best.as_ref().is_none_or(|(b_score, b_sug)| {
                    combined > *b_score + 1e-6
                        || ((combined - *b_score).abs() <= 1e-6 && folder.name < b_sug.folder_name)
                });
                if is_better {
                    best = Some((
                        combined,
                        FolderSuggestion {
                            folder_id: folder.id,
                            folder_name: folder.name.clone(),
                            confidence: combined,
                            reason,
                        },
                    ));
                }
            }
            output.push((asset.id, best.map(|(_, s)| s)));
        }

        Ok(output)
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
                if !desc.is_empty() && current.notes.trim().is_empty() {
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
                let merged_meta = match current
                    .rich_metadata
                    .as_ref()
                    .and_then(|r| r.social_post.clone())
                {
                    Some(existing) => {
                        SocialPostResolver::merge_metadata(resolved.metadata, existing)
                    }
                    None => resolved.metadata,
                };
                let mut cover = None;
                let mut cover_candidates = Vec::new();
                if let Some(ref thumb) = resolved.primary_thumbnail_url {
                    cover_candidates.push(thumb.clone());
                }
                if resolved.primary_media_kind == Some(SocialMediaAttachmentKind::Photo) {
                    if let Some(ref primary_url) = resolved.primary_media_download_url {
                        if !cover_candidates.contains(primary_url) {
                            cover_candidates.push(primary_url.clone());
                        }
                    }
                }
                for att in merged_meta.effective_attachments() {
                    if att.kind == SocialMediaAttachmentKind::Photo
                        && !cover_candidates.contains(&att.url)
                    {
                        cover_candidates.push(att.url);
                    }
                    if let Some(ref t) = att.thumbnail_url {
                        if !cover_candidates.contains(t) {
                            cover_candidates.push(t.clone());
                        }
                    }
                }
                for cand in cover_candidates.iter().take(4) {
                    if let Some((bytes, _)) = SocialPostResolver::download_media_bytes(
                        cand,
                        SocialMediaAttachmentKind::Photo,
                    )
                    .await
                    {
                        if let Ok(img) = image::load_from_memory(&bytes) {
                            cover = Some(img);
                            break;
                        }
                    }
                }
                let avatar = match merged_meta.author_avatar_url.as_deref() {
                    Some(av_url) if !av_url.trim().is_empty() => {
                        SocialPostResolver::fetch_avatar_image(av_url).await
                    }
                    _ => None,
                };
                let card = MediaArtwork::social_post_card_with_avatar(
                    &merged_meta,
                    cover.as_ref(),
                    avatar.as_ref(),
                );
                let _ = self.media.write_custom_poster(&card, &mut current);
                let title_helper = crate::media::resolvers::ResolvedSocialPost {
                    metadata: merged_meta.clone(),
                    primary_media_download_url: None,
                    primary_media_kind: None,
                    primary_thumbnail_url: None,
                    extracted_tags: resolved.extracted_tags.clone(),
                };
                current.title = title_helper.short_title();
                current.media_kind = MediaKind::WebBookmark;
                if !merged_meta.body_text.trim().is_empty() {
                    current.ocr_text = Some(merged_meta.body_text.clone());
                }
                for tag in resolved.extracted_tags {
                    let clean = tag.trim();
                    if !clean.is_empty()
                        && !current.tags.iter().any(|t| t.eq_ignore_ascii_case(clean))
                    {
                        current.tags.push(clean.to_string());
                    }
                }
                if XiaohongshuURLParser::parse(&url).is_some_and(|r| r.is_short_link) {
                    if let Ok(canon) = Url::parse(&merged_meta.original_url) {
                        if XiaohongshuURLParser::parse(&canon).is_some_and(|r| r.note_id.is_some())
                        {
                            current.source_url = Some(canon.to_string());
                            current.source_domain = canon.host_str().map(String::from);
                        }
                    }
                }
                let mut rich = current.rich_metadata.clone().unwrap_or_default();
                rich.social_post = Some(merged_meta);
                current.rich_metadata = Some(rich);
                let saved = self.db.save_asset_locally(&current, true)?;
                self.emit(EngineEvent::AssetEnriched(saved.id));
                return Ok(saved);
            }
        }

        if current.media_kind == MediaKind::WebBookmark && WebBookmarkResolver::is_web_url(&url) {
            let bm =
                WebBookmarkResolver::fetch_with_snapshot(&url, self.media.web_snapshotter()).await;
            let clean_domain = url
                .host_str()
                .unwrap_or("web")
                .trim_start_matches("www.")
                .to_string();
            if let Some(ref title) = bm.title {
                if !title.trim().is_empty() {
                    current.title = title.clone();
                }
            }
            if let Some(ref desc) = bm.description {
                if !desc.trim().is_empty() {
                    if current.notes.trim().is_empty() {
                        current.notes = desc.clone();
                    }
                    let mut rich = current.rich_metadata.clone().unwrap_or_default();
                    rich.text_excerpt = Some(desc.clone());
                    current.rich_metadata = Some(rich);
                }
            }
            let mut ocr_parts = vec![current.title.clone(), clean_domain.clone()];
            if let Some(ref site) = bm.site_name {
                ocr_parts.push(site.clone());
            }
            if let Some(ref desc) = bm.description {
                ocr_parts.push(desc.clone());
            }
            current.ocr_text = Some(ocr_parts.join("\n"));
            // CRITICAL (Pitfall 7): NEVER overwrite `current.source_url` with 302 `/login` redirects;
            // keep the original collected URL and its host domain intact.
            current.source_domain = url.host_str().map(String::from);
            let poster = bm.poster_image.unwrap_or_else(|| {
                MediaArtwork::web_page_card(
                    &current.title,
                    &clean_domain,
                    bm.site_name.as_deref(),
                    bm.description.as_deref(),
                    current.source_url.as_deref(),
                    bm.theme_color.as_deref(),
                    bm.favicon_image.as_ref(),
                )
            });
            let _ = self.media.write_custom_poster(&poster, &mut current);
            let saved = self.db.save_asset_locally(&current, true)?;
            self.emit(EngineEvent::AssetEnriched(saved.id));
            return Ok(saved);
        }

        Ok(current)
    }

    /// Automatically migrates legacy Xiaohongshu social-bookmark assets whose covers were rendered
    /// with non-native dimensions (not `900×1440`) to the native 3:4 cover + title/author/likes card.
    /// Idempotent and zero-overhead once migrated; skips media-bearing notes when offline so covers
    /// are never degraded to text-only cards.
    pub async fn upgrade_legacy_xiaohongshu_covers_if_needed(&self) -> Vec<Uuid> {
        let Ok(all_assets) = self.db.fetch_assets(
            &FilterCriteria {
                include_trashed: true,
                ..FilterCriteria::default()
            },
            None,
        ) else {
            return Vec::new();
        };

        let candidates: Vec<AssetRecord> = all_assets
            .into_iter()
            .filter(|asset| {
                let is_xhs = asset
                    .rich_metadata
                    .as_ref()
                    .and_then(|r| r.social_post.as_ref())
                    .is_some_and(|p| p.platform == SocialPlatform::Xiaohongshu);
                is_xhs && (asset.pixel_width != 900 || asset.pixel_height != 1_440)
            })
            .collect();

        if candidates.is_empty() {
            return Vec::new();
        }

        let mut upgraded_ids = Vec::new();
        for mut asset in candidates {
            let Some(mut meta) = asset
                .rich_metadata
                .as_ref()
                .and_then(|r| r.social_post.clone())
            else {
                continue;
            };

            let has_declared_media = !meta.effective_attachments().is_empty()
                || !meta.media_urls.is_empty()
                || !meta.media_thumbnail_urls.is_empty();

            let mut candidate_urls: Vec<String> = Vec::new();
            for att in meta.effective_attachments() {
                if att.kind == SocialMediaAttachmentKind::Photo
                    && !candidate_urls.contains(&att.url)
                {
                    candidate_urls.push(att.url);
                }
                if let Some(ref thumb) = att.thumbnail_url {
                    if !candidate_urls.contains(thumb) {
                        candidate_urls.push(thumb.clone());
                    }
                }
            }
            for raw in meta
                .media_urls
                .iter()
                .chain(meta.media_thumbnail_urls.iter())
            {
                if !candidate_urls.contains(raw) {
                    candidate_urls.push(raw.clone());
                }
            }

            let mut cover_img = None;
            for photo_url in &candidate_urls {
                if let Some((bytes, _)) = SocialPostResolver::download_media_bytes(
                    photo_url,
                    SocialMediaAttachmentKind::Photo,
                )
                .await
                {
                    if let Ok(img) = image::load_from_memory(&bytes) {
                        cover_img = Some(img);
                        break;
                    }
                }
            }

            // If CDN URLs expired, re-resolve the original Xiaohongshu URL once to obtain a fresh cover.
            if cover_img.is_none() && has_declared_media {
                let src_str = asset
                    .source_url
                    .as_deref()
                    .unwrap_or(meta.original_url.as_str());
                if let Ok(src_url) = Url::parse(src_str) {
                    if let Some(social_ref) = SocialPostURLParser::parse(&src_url) {
                        if let Some(live) = SocialPostResolver::resolve(&social_ref).await {
                            meta = SocialPostResolver::merge_metadata(live.metadata, meta);
                            if let Some(fresh_url) = live
                                .primary_thumbnail_url
                                .or(live.primary_media_download_url)
                            {
                                if let Some((bytes, _)) = SocialPostResolver::download_media_bytes(
                                    &fresh_url,
                                    SocialMediaAttachmentKind::Photo,
                                )
                                .await
                                {
                                    cover_img = image::load_from_memory(&bytes).ok();
                                }
                            }
                        }
                    }
                }
            }

            // Never degrade a media-bearing note to text-only if offline / temporarily unreachable.
            if has_declared_media && cover_img.is_none() {
                continue;
            }

            let avatar_img = match meta.author_avatar_url.as_deref() {
                Some(av_url) if !av_url.trim().is_empty() => {
                    SocialPostResolver::fetch_avatar_image(av_url).await
                }
                _ => None,
            };

            let card = MediaArtwork::social_post_card_with_avatar(
                &meta,
                cover_img.as_ref(),
                avatar_img.as_ref(),
            );
            let mut rich = asset.rich_metadata.clone().unwrap_or_default();
            rich.social_post = Some(meta);
            asset.rich_metadata = Some(rich);
            if self.media.write_custom_poster(&card, &mut asset).is_ok() {
                if let Ok(saved) = self.db.save_asset_locally(&asset, true) {
                    upgraded_ids.push(saved.id);
                    self.emit(EngineEvent::AssetEnriched(saved.id));
                }
            }
        }

        if !upgraded_ids.is_empty() {
            self.emit(EngineEvent::LibraryChanged);
        }
        upgraded_ids
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
        let previous_mode = self.sync_config().mode;
        self.db.set_state("driveConfig", Some(&config))?;

        // Prevent a stale account from another backend (such as LocalFolderTransport's
        // local directory path) from leaking across mode switches.
        if previous_mode != config.mode {
            self.sync.clear_mismatched_account_if_idle(config.mode);
            if let Ok(Some(mut persisted)) = self.db.state::<SyncStatus>("lastSyncStatus") {
                persisted.active_mode = config.mode;
                if persisted
                    .account
                    .as_ref()
                    .is_some_and(|acc| !acc.matches_mode(config.mode))
                {
                    persisted.account = None;
                }
                let _ = self.db.set_state("lastSyncStatus", Some(&persisted));
            }
        }
        Ok(())
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
        if status
            .account
            .as_ref()
            .is_some_and(|acc| !acc.matches_mode(config.mode))
        {
            status.account = None;
            if matches!(status.phase, crate::models::sync::SyncPhase::Idle) {
                self.sync.restore_status(status.clone()).await;
                let _ = self.db.set_state("lastSyncStatus", Some(&status));
            }
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

/// Summary returned by [`LiveCharkleEngine::ingest_local_paths`].
#[derive(Debug, Clone, Default)]
pub struct IngestPathsReport {
    pub assets: Vec<AssetRecord>,
    pub created_folders: Vec<FolderRecord>,
    pub matched_folder_names: Vec<String>,
    pub skipped_files: usize,
}

#[derive(Debug, Clone)]
struct PlannedFolderNode {
    name: String,
    files: Vec<PathBuf>,
    children: Vec<PlannedFolderNode>,
}

#[derive(Debug, Default)]
struct LocalPathIngestPlan {
    loose_files: Vec<PathBuf>,
    root_folders: Vec<PlannedFolderNode>,
}

fn is_ignored_import_file_name(name: &str) -> bool {
    let lower = name.to_ascii_lowercase();
    lower.starts_with('.')
        || lower.starts_with("~$")
        || lower == "thumbs.db"
        || lower == "desktop.ini"
        || lower == "__macosx"
}

fn is_ignored_import_dir_name(name: &str) -> bool {
    let lower = name.to_ascii_lowercase();
    lower.starts_with('.')
        || lower == "__macosx"
        || lower == "node_modules"
        || lower == "$recycle.bin"
        || lower == "system volume information"
}

fn sanitize_import_folder_name(raw: &str, parent: Option<Uuid>) -> String {
    let cleaned: String = raw
        .trim()
        .chars()
        .map(|c| {
            if c.is_control() || matches!(c, '/' | '\\' | ':' | '*' | '?' | '"' | '<' | '>' | '|') {
                '_'
            } else {
                c
            }
        })
        .collect();
    let no_dots = cleaned.trim().trim_start_matches('.').trim();
    let truncated: String = no_dots.chars().take(120).collect();
    let base = truncated.trim();
    if base.is_empty() {
        return "导入文件夹".to_string();
    }
    if parent.is_none() && base.eq_ignore_ascii_case("Inbox") {
        return "Inbox (导入)".to_string();
    }
    base.to_string()
}

fn ensure_or_create_import_folder(
    engine: &LiveCharkleEngine,
    raw_name: &str,
    parent_id: Option<Uuid>,
    folders_snapshot: &mut Vec<FolderRecord>,
    created_folders: &mut Vec<FolderRecord>,
) -> CoreResult<FolderRecord> {
    let clean = sanitize_import_folder_name(raw_name, parent_id);
    if let Some(existing) = folders_snapshot
        .iter()
        .find(|f| f.parent_id == parent_id && f.name.eq_ignore_ascii_case(&clean))
    {
        return Ok(existing.clone());
    }
    let created = engine.create_folder(&clean, parent_id)?;
    folders_snapshot.push(created.clone());
    created_folders.push(created.clone());
    Ok(created)
}

fn plan_local_path_ingest(raw_paths: Vec<PathBuf>) -> LocalPathIngestPlan {
    const MAX_DEPTH: usize = 8;
    const MAX_FILES: usize = 500;
    const MAX_FOLDERS: usize = 100;

    fn walk_dir(
        dir: &Path,
        depth: usize,
        total_files: &mut usize,
        total_folders: &mut usize,
    ) -> Option<PlannedFolderNode> {
        if depth > MAX_DEPTH || *total_folders >= MAX_FOLDERS {
            return None;
        }
        let raw_name = dir
            .file_name()
            .and_then(|n| n.to_str())
            .filter(|s| !s.trim().is_empty())
            .unwrap_or("导入文件夹");
        if depth > 0 && is_ignored_import_dir_name(raw_name) {
            return None;
        }

        *total_folders += 1;
        let mut node = PlannedFolderNode {
            name: raw_name.to_string(),
            files: Vec::new(),
            children: Vec::new(),
        };

        if let Ok(entries) = std::fs::read_dir(dir) {
            let mut entries_vec: Vec<(PathBuf, std::fs::FileType)> = entries
                .filter_map(|e| {
                    let entry = e.ok()?;
                    let ft = entry.file_type().ok()?;
                    Some((entry.path(), ft))
                })
                .collect();
            entries_vec.sort_by(|a, b| a.0.cmp(&b.0));

            for (child_path, ft) in entries_vec {
                // Skip symlinks to prevent directory traversal cycles.
                if ft.is_symlink() {
                    continue;
                }
                if ft.is_file() {
                    if *total_files >= MAX_FILES {
                        continue;
                    }
                    if let Some(name) = child_path.file_name().and_then(|n| n.to_str()) {
                        if !is_ignored_import_file_name(name) {
                            node.files.push(child_path);
                            *total_files += 1;
                        }
                    }
                } else if ft.is_dir() && depth < MAX_DEPTH && *total_folders < MAX_FOLDERS {
                    if let Some(child_node) =
                        walk_dir(&child_path, depth + 1, total_files, total_folders)
                    {
                        node.children.push(child_node);
                    }
                }
            }
        }

        Some(node)
    }

    let mut plan = LocalPathIngestPlan::default();
    let mut total_files = 0usize;
    let mut total_folders = 0usize;

    for raw in raw_paths {
        let Ok(meta) = std::fs::metadata(&raw) else {
            continue;
        };
        if meta.is_file() {
            if total_files < MAX_FILES {
                if let Some(name) = raw.file_name().and_then(|n| n.to_str()) {
                    if !is_ignored_import_file_name(name) {
                        plan.loose_files.push(raw);
                        total_files += 1;
                    }
                }
            }
        } else if meta.is_dir() {
            if let Some(node) = walk_dir(&raw, 0, &mut total_files, &mut total_folders) {
                plan.root_folders.push(node);
            }
        }
    }

    plan
}

fn visual_descriptor_fingerprint(asset: &AssetRecord) -> String {
    if !asset.content_hash.is_empty() {
        asset.content_hash.clone()
    } else {
        format!(
            "{}:{}:{}",
            asset.file_name, asset.pixel_width, asset.pixel_height
        )
    }
}

struct AssetMatchContext<'a> {
    asset: &'a AssetRecord,
    tags: HashSet<String>,
    tokens: HashSet<String>,
    descriptor: Option<&'a LocalVisualDescriptor>,
    has_embedding: bool,
}

impl<'a> AssetMatchContext<'a> {
    fn new(
        asset: &'a AssetRecord,
        vector: Option<&'a AssetVector>,
        descriptor: Option<&'a LocalVisualDescriptor>,
    ) -> Self {
        let tags: HashSet<String> = asset
            .tags
            .iter()
            .chain(asset.suggested_tags.iter())
            .map(|t| search_text::normalize(t))
            .filter(|t| !t.is_empty())
            .collect();
        let tokens = extract_meaningful_tokens(&format!(
            "{} {} {} {}",
            asset.title,
            asset.notes,
            asset.ocr_text.as_deref().unwrap_or(""),
            asset.ai_description.as_deref().unwrap_or("")
        ));
        let has_embedding = vector.and_then(|v| v.embedding.as_ref()).is_some();
        Self {
            asset,
            tags,
            tokens,
            descriptor,
            has_embedding,
        }
    }
}

fn score_asset_pair(
    anchor: &AssetMatchContext<'_>,
    cand: AssetRecord,
    anchor_vector: Option<&AssetVector>,
    vectors: &HashMap<Uuid, AssetVector>,
    descriptors: &HashMap<Uuid, LocalVisualDescriptor>,
) -> ScoredAsset {
    // Tuple: (signal_value, weight, min_display_threshold, reason)
    let mut signals: Vec<(f64, f64, f64, String)> = Vec::new();

    // 1. Cloud semantic embedding cosine similarity (same model identity)
    if anchor.has_embedding {
        if let (Some(a_vec), Some(c_vec)) = (anchor_vector, vectors.get(&cand.id)) {
            if let (Some(a_emb), Some(c_emb)) =
                (a_vec.embedding.as_deref(), c_vec.embedding.as_deref())
            {
                if a_vec.embedding_model == c_vec.embedding_model {
                    let cos = cosine_similarity(a_emb, c_emb)
                        .map(f64::from)
                        .unwrap_or(0.0)
                        .clamp(0.0, 1.0);
                    signals.push((cos, 0.40, 0.45, "语义接近".to_string()));
                }
            }
        }
    }

    // 2. Local perceptual visual descriptor similarity (spatial CIELAB + chromatic mood + edge HOG)
    if let (Some(a_desc), Some(c_desc)) = (anchor.descriptor, descriptors.get(&cand.id)) {
        let vis = a_desc.similarity(c_desc);
        signals.push((vis, 0.36, 0.24, "视觉特征接近".to_string()));
    }

    // 3. Symmetric proportion-weighted CIELAB palette harmony (avoids dark/white border false positives)
    if !anchor.asset.dominant_colors.is_empty() && !cand.dominant_colors.is_empty() {
        let sim = match symmetric_weighted_palette_distance(
            &cand.dominant_colors,
            &anchor.asset.dominant_colors,
        ) {
            Some(avg_de) if avg_de <= 6.0 => 1.0,
            Some(avg_de) if avg_de < 22.0 => ((22.0 - avg_de) / 16.0).powf(1.1),
            _ => 0.0,
        };
        signals.push((sim, 0.26, 0.35, "配色相近".to_string()));
    }

    // 4. Tag Jaccard overlap across confirmed + suggested tags
    if !anchor.tags.is_empty() {
        let mut cand_tags = HashSet::new();
        let mut shared_display = Vec::new();
        let mut seen_display = HashSet::new();
        for raw in cand.tags.iter().chain(cand.suggested_tags.iter()) {
            let norm = search_text::normalize(raw);
            if norm.is_empty() {
                continue;
            }
            if anchor.tags.contains(&norm) && seen_display.insert(norm.clone()) {
                shared_display.push(raw.clone());
            }
            cand_tags.insert(norm);
        }
        let overlap = if cand_tags.is_empty() {
            0.0
        } else {
            let inter = anchor.tags.intersection(&cand_tags).count();
            let union = anchor.tags.union(&cand_tags).count().max(1);
            inter as f64 / union as f64
        };
        let label = if shared_display.is_empty() {
            "相同标签".to_string()
        } else {
            format!(
                "相同标签：{}",
                shared_display
                    .into_iter()
                    .take(2)
                    .collect::<Vec<_>>()
                    .join("、")
            )
        };
        signals.push((overlap, 0.20, 0.18, label));
    }

    // 5. Lexical keyword affinity (title / notes / OCR / AI description)
    if !anchor.tokens.is_empty() {
        let cand_tokens = extract_meaningful_tokens(&format!(
            "{} {} {} {}",
            cand.title,
            cand.notes,
            cand.ocr_text.as_deref().unwrap_or(""),
            cand.ai_description.as_deref().unwrap_or("")
        ));
        if !cand_tokens.is_empty() {
            let inter = anchor.tokens.intersection(&cand_tokens).count();
            if inter > 0 {
                let denom = anchor.tokens.len().min(cand_tokens.len()).max(1) as f64;
                let lexical = (inter as f64 / denom).clamp(0.0, 1.0);
                signals.push((lexical, 0.14, 0.28, "主题相近".to_string()));
            }
        }
    }

    let weighted_sum: f64 = signals.iter().map(|(v, w, _, _)| v * w).sum();
    let capacity: f64 = signals.iter().map(|(_, w, _, _)| *w).sum::<f64>().max(0.35);
    let base_score = (weighted_sum / capacity).clamp(0.0, 1.0);

    let mut qualified: Vec<(f64, String)> = signals
        .into_iter()
        .filter(|(v, _, threshold, _)| *v >= *threshold)
        .map(|(v, w, _, reason)| (v * w, reason))
        .collect();
    qualified.sort_by(|a, b| b.0.partial_cmp(&a.0).unwrap_or(std::cmp::Ordering::Equal));
    let match_reasons: Vec<String> = qualified.into_iter().map(|(_, r)| r).collect();

    // Only apply a subtle rating tie-break when at least one real similarity signal matched.
    let rating = f64::from(cand.rating.clamp(0, 5)) / 5.0;
    let final_score = if match_reasons.is_empty() {
        base_score
    } else {
        (0.96 * base_score + 0.04 * rating).min(1.0)
    };

    ScoredAsset {
        asset: cand,
        score: final_score,
        match_reasons,
    }
}

fn rerank_similar_mmr(
    mut pool: Vec<ScoredAsset>,
    vectors: &HashMap<Uuid, AssetVector>,
    descriptors: &HashMap<Uuid, LocalVisualDescriptor>,
    limit: usize,
) -> Vec<ScoredAsset> {
    pool.sort_by(|a, b| {
        b.score
            .partial_cmp(&a.score)
            .unwrap_or(std::cmp::Ordering::Equal)
            .then_with(|| b.asset.rating.cmp(&a.asset.rating))
            .then_with(|| b.asset.id.cmp(&a.asset.id))
    });
    let count = limit.min(pool.len());
    if count == 0 {
        return Vec::new();
    }
    let pool_cap = (count.saturating_mul(6)).max(120);
    pool.truncate(pool_cap);

    let mut redundancy = vec![0.0_f64; pool.len()];
    let mut available = vec![true; pool.len()];
    let mut results = Vec::with_capacity(count);

    for _ in 0..count {
        let mut best_idx = None;
        let mut best_rank = f64::NEG_INFINITY;
        for i in 0..pool.len() {
            if !available[i] {
                continue;
            }
            let rank = 0.70 * pool[i].score - 0.30 * redundancy[i];
            if rank > best_rank {
                best_rank = rank;
                best_idx = Some(i);
            }
        }
        let Some(chosen) = best_idx else {
            break;
        };
        available[chosen] = false;
        let chosen_asset = pool[chosen].asset.clone();
        results.push(pool[chosen].clone());
        if results.len() < count {
            for i in 0..pool.len() {
                if available[i] {
                    let red =
                        pairwise_redundancy(&chosen_asset, &pool[i].asset, vectors, descriptors);
                    if red > redundancy[i] {
                        redundancy[i] = red;
                    }
                }
            }
        }
    }
    results
}

fn pairwise_redundancy(
    lhs: &AssetRecord,
    rhs: &AssetRecord,
    vectors: &HashMap<Uuid, AssetVector>,
    descriptors: &HashMap<Uuid, LocalVisualDescriptor>,
) -> f64 {
    if !lhs.content_hash.is_empty() && lhs.content_hash == rhs.content_hash {
        return 1.0;
    }
    let mut red = 0.0_f64;
    if let (Some(lv), Some(rv)) = (vectors.get(&lhs.id), vectors.get(&rhs.id)) {
        if lv.embedding_model == rv.embedding_model {
            if let (Some(le), Some(re)) = (lv.embedding.as_deref(), rv.embedding.as_deref()) {
                if let Some(cos) = cosine_similarity(le, re) {
                    red = red.max((f64::from(cos) * 0.92).clamp(0.0, 1.0));
                }
            }
        }
    }
    if let (Some(ld), Some(rd)) = (descriptors.get(&lhs.id), descriptors.get(&rhs.id)) {
        red = red.max(ld.similarity(rd));
    }
    if let Some(de) = symmetric_weighted_palette_distance(
        &lhs.dominant_colors[..lhs.dominant_colors.len().min(2)],
        &rhs.dominant_colors[..rhs.dominant_colors.len().min(2)],
    ) {
        red = red.max(0.55 * (-de / 17.0).exp());
    }
    red
}

fn significant_swatches(colors: &[LabColor], max_count: usize) -> Vec<&LabColor> {
    let valid: Vec<&LabColor> = colors
        .iter()
        .filter(|c| c.l.is_finite() && c.a.is_finite() && c.b.is_finite())
        .collect();
    let has_proportions = valid.iter().any(|c| c.proportion > 0.001);
    if has_proportions {
        let major: Vec<&LabColor> = valid
            .iter()
            .copied()
            .filter(|c| c.proportion >= 0.08)
            .collect();
        if !major.is_empty() {
            return major.into_iter().take(max_count).collect();
        }
    }
    valid.into_iter().take(max_count).collect()
}

fn directed_weighted_palette_distance(src: &[&LabColor], dst: &[&LabColor]) -> Option<f64> {
    if src.is_empty() || dst.is_empty() {
        return None;
    }
    let mut weighted_sum = 0.0_f64;
    let mut total_weight = 0.0_f64;
    for s in src {
        let nearest = dst
            .iter()
            .map(|d| s.delta_e_2000(d))
            .filter(|d| d.is_finite())
            .fold(f64::INFINITY, f64::min);
        if !nearest.is_finite() {
            continue;
        }
        let w = if s.proportion > 0.001 {
            s.proportion
        } else {
            1.0
        };
        weighted_sum += nearest * w;
        total_weight += w;
    }
    (total_weight > 0.0).then_some(weighted_sum / total_weight)
}

fn symmetric_weighted_palette_distance(a: &[LabColor], b: &[LabColor]) -> Option<f64> {
    let sa = significant_swatches(a, 3);
    let sb = significant_swatches(b, 4);
    let dab = directed_weighted_palette_distance(&sa, &sb)?;
    let dba = directed_weighted_palette_distance(&sb, &sa)?;
    Some(0.5 * (dab + dba))
}

fn is_generic_stopword(tok: &str) -> bool {
    matches!(
        tok,
        "img"
            | "image"
            | "photo"
            | "pic"
            | "picture"
            | "screenshot"
            | "screen"
            | "shot"
            | "capture"
            | "untitled"
            | "file"
            | "asset"
            | "copy"
            | "final"
            | "new"
            | "png"
            | "jpg"
            | "jpeg"
            | "webp"
            | "gif"
            | "svg"
            | "mp4"
            | "mov"
            | "pdf"
            | "the"
            | "and"
            | "for"
            | "with"
            | "from"
            | "that"
            | "this"
            | "http"
            | "https"
            | "www"
            | "com"
            | "net"
            | "org"
            | "截图"
            | "图片"
            | "未命名"
            | "素材"
    )
}

fn is_cjk(c: char) -> bool {
    matches!(
        c as u32,
        0x4E00..=0x9FFF | 0x3400..=0x4DBF | 0xF900..=0xFAFF | 0x3040..=0x30FF | 0xAC00..=0xD7AF
    )
}

/// Extracts meaningful ASCII word tokens (word-boundary, skipping filename noise & pure digits)
/// and CJK terms (`>= 2` chars, plus bigrams for longer runs) for honest lexical matching.
fn extract_meaningful_tokens(text: &str) -> HashSet<String> {
    let mut out = HashSet::new();
    let lower = text.to_lowercase();
    let mut ascii_buf = String::new();
    let mut cjk_buf: Vec<char> = Vec::new();

    let flush_ascii = |buf: &mut String, set: &mut HashSet<String>| {
        if buf.len() >= 2 && !buf.chars().all(|c| c.is_ascii_digit()) && !is_generic_stopword(buf) {
            set.insert(buf.clone());
        }
        buf.clear();
    };
    let flush_cjk = |buf: &mut Vec<char>, set: &mut HashSet<String>| {
        if buf.len() >= 2 {
            let full: String = buf.iter().collect();
            if !is_generic_stopword(&full) {
                set.insert(full);
            }
            if buf.len() > 2 && buf.len() <= 16 {
                for w in buf.windows(2) {
                    let bi: String = w.iter().collect();
                    if !is_generic_stopword(&bi) {
                        set.insert(bi);
                    }
                }
            }
        }
        buf.clear();
    };

    for ch in lower.chars() {
        if ch.is_ascii_alphanumeric() {
            flush_cjk(&mut cjk_buf, &mut out);
            ascii_buf.push(ch);
        } else if is_cjk(ch) {
            flush_ascii(&mut ascii_buf, &mut out);
            cjk_buf.push(ch);
        } else {
            flush_ascii(&mut ascii_buf, &mut out);
            flush_cjk(&mut cjk_buf, &mut out);
        }
    }
    flush_ascii(&mut ascii_buf, &mut out);
    flush_cjk(&mut cjk_buf, &mut out);
    out
}

fn score_folder_name_match(
    folder_name: &str,
    folder_path: &str,
    asset_tags: &HashSet<String>,
    asset_tokens: &HashSet<String>,
    asset_full_text_norm: &str,
) -> f64 {
    let folder_norm = search_text::normalize(folder_name);
    if folder_norm.is_empty() {
        return 0.0;
    }

    // Exact tag match against folder name (highest confidence)
    if asset_tags.contains(&folder_norm) {
        return 0.88;
    }

    // Full folder name match: word-boundary for pure ASCII, direct phrase for CJK (>= 2 chars)
    let is_ascii_folder = folder_norm.is_ascii();
    if !is_ascii_folder
        && folder_norm.chars().count() >= 2
        && asset_full_text_norm.contains(&folder_norm)
    {
        return 0.82;
    }

    // Token-level word-boundary match (prevents "ui" from matching "building" or "fluid")
    let name_tokens = extract_meaningful_tokens(folder_name);
    if !name_tokens.is_empty() {
        let tag_hits = name_tokens
            .iter()
            .filter(|t| asset_tags.contains(*t))
            .count();
        let text_hits = name_tokens
            .iter()
            .filter(|t| asset_tokens.contains(*t) || asset_tags.contains(*t))
            .count();

        if text_hits == name_tokens.len() {
            return if tag_hits > 0 { 0.86 } else { 0.78 };
        }
        if tag_hits > 0 {
            return (0.52 + 0.24 * (tag_hits as f64 / name_tokens.len() as f64)).min(0.80);
        }
        if text_hits > 0 {
            let ratio = text_hits as f64 / name_tokens.len() as f64;
            // Require strong ratio or an informative token (>= 3 chars or CJK) so single generic words don't over-trigger
            let has_strong_token = name_tokens.iter().any(|t| {
                (asset_tokens.contains(t))
                    && (!t.is_ascii() || t.len() >= 3 || t == "ui" || t == "ux" || t == "3d")
            });
            if has_strong_token && ratio >= 0.5 {
                return (0.44 + 0.22 * ratio).min(0.68);
            }
        }
    }

    // Hierarchical parent path token match (weaker than leaf folder name)
    if folder_path != folder_name {
        let path_tokens = extract_meaningful_tokens(folder_path);
        let hits = path_tokens
            .iter()
            .filter(|t| asset_tags.contains(*t) || asset_tokens.contains(*t))
            .count();
        if hits > 0 && !path_tokens.is_empty() {
            let ratio = hits as f64 / path_tokens.len() as f64;
            if ratio >= 0.5 {
                return (0.36 + 0.16 * ratio).min(0.52);
            }
        }
    }

    let _ = is_ascii_folder;
    0.0
}

fn build_folder_display_path(
    folder_id: Uuid,
    folder_by_id: &HashMap<Uuid, &FolderRecord>,
) -> String {
    let mut parts = Vec::new();
    let mut visited = HashSet::new();
    let mut cur = folder_by_id.get(&folder_id).copied();
    while let Some(folder) = cur {
        if !visited.insert(folder.id) {
            break;
        }
        parts.push(folder.name.as_str());
        cur = folder
            .parent_id
            .and_then(|pid| folder_by_id.get(&pid).copied());
    }
    parts.reverse();
    parts.join(" / ")
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::models::core::{
        AssetRichMetadata, SocialMediaAttachment, SocialMediaAttachmentKind, SocialPostMetadata,
    };
    use tempfile::tempdir;

    #[tokio::test]
    async fn upgrades_legacy_xiaohongshu_covers_idempotently_without_degrading_offline_media() {
        let tmp = tempdir().unwrap();
        let engine = LiveCharkleEngine::open(tmp.path()).unwrap();

        // 1. Legacy text-only Xiaohongshu asset (800×620) -> MUST upgrade to 900×1440
        let mut text_asset = AssetRecord::new("小红书笔记", "note.md");
        text_asset.media_kind = MediaKind::WebBookmark;
        text_asset.pixel_width = 800;
        text_asset.pixel_height = 620;
        text_asset.source_url =
            Some("https://www.xiaohongshu.com/explore/67a1b2c3d4e5f60718293a4b".to_string());
        text_asset.rich_metadata = Some(AssetRichMetadata {
            social_post: Some(SocialPostMetadata {
                platform: SocialPlatform::Xiaohongshu,
                author_name: "排版实验室".to_string(),
                author_handle: "5f11223344556677889900aa".to_string(),
                author_avatar_url: None,
                published_at_text: None,
                body_text: "纯文字排版心得".to_string(),
                quoted_author: None,
                quoted_text: None,
                article_title: Some("极简网格系统".to_string()),
                media_urls: Vec::new(),
                media_thumbnail_urls: Vec::new(),
                attachments: Vec::new(),
                has_video: false,
                video_url: None,
                reply_count: None,
                repost_count: None,
                like_count: Some(128),
                view_count: None,
                original_url: "https://www.xiaohongshu.com/explore/67a1b2c3d4e5f60718293a4b"
                    .to_string(),
                media_fetch_failed: false,
            }),
            ..AssetRichMetadata::default()
        });
        let saved_text = engine.db.save_asset_locally(&text_asset, false).unwrap();

        // 2. Legacy media-bearing Xiaohongshu asset (800×920) whose CDN URL is unreachable ->
        // MUST be skipped rather than degraded to text-only!
        let mut media_asset = AssetRecord::new("图集笔记", "media.md");
        media_asset.media_kind = MediaKind::WebBookmark;
        media_asset.pixel_width = 800;
        media_asset.pixel_height = 920;
        media_asset.source_url = Some("http://127.0.0.1:1/unreachable-note".to_string());
        media_asset.rich_metadata = Some(AssetRichMetadata {
            social_post: Some(SocialPostMetadata {
                platform: SocialPlatform::Xiaohongshu,
                author_name: "光影集".to_string(),
                author_handle: "5f11223344556677889900bb".to_string(),
                author_avatar_url: None,
                published_at_text: None,
                body_text: "有封面图的笔记".to_string(),
                quoted_author: None,
                quoted_text: None,
                article_title: Some("胶片质感调色".to_string()),
                media_urls: vec!["http://127.0.0.1:1/cover.jpg".to_string()],
                media_thumbnail_urls: vec![],
                attachments: vec![SocialMediaAttachment::new(
                    SocialMediaAttachmentKind::Photo,
                    "http://127.0.0.1:1/cover.jpg",
                    None,
                )],
                has_video: false,
                video_url: None,
                reply_count: None,
                repost_count: None,
                like_count: Some(520),
                view_count: None,
                original_url: "http://127.0.0.1:1/unreachable-note".to_string(),
                media_fetch_failed: false,
            }),
            ..AssetRichMetadata::default()
        });
        let saved_media = engine.db.save_asset_locally(&media_asset, false).unwrap();

        let upgraded = engine.upgrade_legacy_xiaohongshu_covers_if_needed().await;
        assert_eq!(upgraded, vec![saved_text.id]);

        let refreshed_text = engine.fetch_asset(saved_text.id).unwrap().unwrap();
        assert_eq!(
            (refreshed_text.pixel_width, refreshed_text.pixel_height),
            (900, 1440)
        );

        // Media-bearing offline asset stayed untouched at 800×920 (never downgraded)
        let refreshed_media = engine.fetch_asset(saved_media.id).unwrap().unwrap();
        assert_eq!(
            (refreshed_media.pixel_width, refreshed_media.pixel_height),
            (800, 920)
        );

        // Second run is idempotent for already-migrated text asset
        let second_run = engine.upgrade_legacy_xiaohongshu_covers_if_needed().await;
        assert!(second_run.is_empty());
    }

    fn write_test_card_png(dir: &Path, name: &str, bg: [u8; 3], accent: [u8; 3]) -> PathBuf {
        let mut img =
            image::RgbaImage::from_pixel(160, 160, image::Rgba([bg[0], bg[1], bg[2], 255]));
        // Shared dark outer border (the exact pattern that fooled old single-min color matching)
        for x in 0..160 {
            for b in 0..8 {
                img.put_pixel(x, b, image::Rgba([16, 18, 22, 255]));
                img.put_pixel(x, 159 - b, image::Rgba([16, 18, 22, 255]));
            }
        }
        for y in 0..160 {
            for b in 0..8 {
                img.put_pixel(b, y, image::Rgba([16, 18, 22, 255]));
                img.put_pixel(159 - b, y, image::Rgba([16, 18, 22, 255]));
            }
        }
        for y in 36..112 {
            for x in 56..132 {
                let dx = x as i32 - 94;
                let dy = y as i32 - 74;
                if dx * dx + dy * dy <= 34 * 34 {
                    img.put_pixel(x, y, image::Rgba([accent[0], accent[1], accent[2], 255]));
                }
            }
        }
        let path = dir.join(name);
        img.save(&path).unwrap();
        path
    }

    #[tokio::test]
    async fn similar_assets_returns_distinct_visual_matches_and_abstains_for_outliers() {
        let tmp = tempdir().unwrap();
        let src_dir = tmp.path().join("src");
        std::fs::create_dir_all(&src_dir).unwrap();
        let engine = LiveCharkleEngine::open(tmp.path().join("lib")).unwrap();

        let p_emerald_a =
            write_test_card_png(&src_dir, "emerald_a.png", [16, 46, 36], [22, 186, 118]);
        let p_emerald_b =
            write_test_card_png(&src_dir, "emerald_b.png", [20, 54, 42], [28, 174, 110]);
        let p_mustard_a =
            write_test_card_png(&src_dir, "mustard_a.png", [228, 168, 26], [214, 44, 34]);
        let p_mustard_b =
            write_test_card_png(&src_dir, "mustard_b.png", [218, 158, 22], [204, 52, 38]);
        let p_beige =
            write_test_card_png(&src_dir, "beige_unique.png", [210, 198, 182], [116, 98, 82]);

        let ingested = engine
            .ingest(
                vec![
                    CaptureInput::FilePath(p_emerald_a),
                    CaptureInput::FilePath(p_emerald_b),
                    CaptureInput::FilePath(p_mustard_a),
                    CaptureInput::FilePath(p_mustard_b),
                    CaptureInput::FilePath(p_beige),
                ],
                None,
                None,
            )
            .await
            .unwrap();

        let emerald_a = ingested[0].id;
        let emerald_b = ingested[1].id;
        let mustard_a = ingested[2].id;
        let mustard_b = ingested[3].id;
        let beige = ingested[4].id;

        let sim_emerald = engine.similar_assets(emerald_a, 8).unwrap();
        assert_eq!(
            sim_emerald.first().map(|s| s.asset.id),
            Some(emerald_b),
            "Emerald card should rank matching Emerald card #1, got: {:?}",
            sim_emerald
                .iter()
                .map(|s| (&s.asset.title, s.score, &s.match_reasons))
                .collect::<Vec<_>>()
        );
        assert!(
            !sim_emerald
                .iter()
                .any(|s| s.asset.id == mustard_a || s.asset.id == beige),
            "Emerald card should not falsely match unrelated mustard or beige cards"
        );

        let sim_mustard = engine.similar_assets(mustard_a, 8).unwrap();
        assert_eq!(
            sim_mustard.first().map(|s| s.asset.id),
            Some(mustard_b),
            "Mustard card should rank matching Mustard card #1"
        );
        assert!(
            !sim_mustard
                .iter()
                .any(|s| s.asset.id == emerald_a || s.asset.id == beige),
            "Mustard card should not falsely match unrelated emerald or beige cards"
        );

        let sim_beige = engine.similar_assets(beige, 8).unwrap();
        assert!(
            sim_beige.is_empty(),
            "Unique outlier card should return empty similar list instead of forced picks, got: {:?}",
            sim_beige.iter().map(|s| (&s.asset.title, s.score, &s.match_reasons)).collect::<Vec<_>>()
        );
    }

    #[tokio::test]
    async fn suggest_folder_matches_by_visual_peers_and_abstains_instead_of_picking_first() {
        let tmp = tempdir().unwrap();
        let src_dir = tmp.path().join("src");
        std::fs::create_dir_all(&src_dir).unwrap();
        let engine = LiveCharkleEngine::open(tmp.path().join("lib")).unwrap();

        let f_ui = engine.create_folder("UI Inspiration", None).unwrap();
        let f_arch = engine.create_folder("Architecture", None).unwrap();
        let f_editorial = engine.create_folder("Editorial", None).unwrap();

        // Populate Architecture with warm mustard visual reference + tag, and Editorial with emerald reference
        let p_arch_peer =
            write_test_card_png(&src_dir, "arch_peer.png", [228, 168, 26], [214, 44, 34]);
        let p_ed_peer = write_test_card_png(&src_dir, "ed_peer.png", [16, 46, 36], [22, 186, 118]);
        let arch_ingested = engine
            .ingest(
                vec![CaptureInput::FilePath(p_arch_peer)],
                Some(f_arch.id),
                None,
            )
            .await
            .unwrap();
        let _ = engine
            .update_assets(&AssetBatchPatch {
                asset_ids: vec![arch_ingested[0].id],
                add_tags: vec!["建筑".to_string(), "光影".to_string()],
                ..AssetBatchPatch::default()
            })
            .unwrap();
        let ed_ingested = engine
            .ingest(
                vec![CaptureInput::FilePath(p_ed_peer)],
                Some(f_editorial.id),
                None,
            )
            .await
            .unwrap();
        let _ = engine
            .update_assets(&AssetBatchPatch {
                asset_ids: vec![ed_ingested[0].id],
                add_tags: vec!["杂志排版".to_string()],
                ..AssetBatchPatch::default()
            })
            .unwrap();

        // 1. Visually similar inbox image (no tags, generic filename) should route to Editorial, NOT folders[0] (UI Inspiration)!
        let p_inbox_ed = write_test_card_png(
            &src_dir,
            "GCqrsxJbUAAbbdB.png",
            [20, 54, 42],
            [28, 174, 110],
        );
        // 2. Unrelated beige image named "building_sketch.png" must NOT falsely match "UI Inspiration" via "ui" inside "building",
        //    and must abstain honestly (None)!
        let p_inbox_unrelated = write_test_card_png(
            &src_dir,
            "building_sketch.png",
            [210, 198, 182],
            [116, 98, 82],
        );
        // 3. Explicit UI asset should match UI Inspiration
        let p_inbox_ui = write_test_card_png(
            &src_dir,
            "mobile_ui_kit.png",
            [210, 198, 182],
            [116, 98, 82],
        );

        let inbox = engine
            .ingest(
                vec![
                    CaptureInput::FilePath(p_inbox_ed),
                    CaptureInput::FilePath(p_inbox_unrelated),
                    CaptureInput::FilePath(p_inbox_ui),
                ],
                None,
                None,
            )
            .await
            .unwrap();

        let sug_ed = engine.suggest_folder(inbox[0].id).unwrap();
        assert_eq!(
            sug_ed.as_ref().map(|s| s.folder_id),
            Some(f_editorial.id),
            "Inbox image visually matching Editorial peer should recommend Editorial, got: {sug_ed:?}"
        );

        let sug_unrelated = engine.suggest_folder(inbox[1].id).unwrap();
        assert!(
            sug_unrelated.is_none(),
            "Unrelated 'building_sketch.png' must abstain (None) instead of falsely matching 'UI' or picking folders[0], got: {sug_unrelated:?}"
        );

        let sug_ui = engine.suggest_folder(inbox[2].id).unwrap();
        assert_eq!(
            sug_ui.as_ref().map(|s| s.folder_id),
            Some(f_ui.id),
            "Asset with word-boundary 'ui' token should match UI Inspiration, got: {sug_ui:?}"
        );
    }

    #[tokio::test]
    async fn ingest_local_paths_mirrors_nested_folders_reuses_existing_and_handles_empty_or_reserved(
    ) {
        let tmp = tempfile::tempdir().unwrap();
        let engine = LiveCharkleEngine::open(tmp.path().join("lib")).unwrap();

        let drop_root = tmp.path().join("drop_src");
        let brand_dir = drop_root.join("BrandKit");
        let icons_dir = brand_dir.join("Icons");
        let ignored_git = brand_dir.join(".git");
        let empty_dir = drop_root.join("EmptyMood");
        let reserved_inbox_dir = drop_root.join("Inbox");
        std::fs::create_dir_all(&icons_dir).unwrap();
        std::fs::create_dir_all(&ignored_git).unwrap();
        std::fs::create_dir_all(&empty_dir).unwrap();
        std::fs::create_dir_all(&reserved_inbox_dir).unwrap();

        let loose_file =
            write_test_card_png(&drop_root, "loose.png", [40, 80, 160], [220, 220, 240]);
        let _brand_cover =
            write_test_card_png(&brand_dir, "cover.png", [20, 50, 40], [30, 180, 110]);
        let _icon_one =
            write_test_card_png(&icons_dir, "arrow.png", [210, 198, 182], [116, 98, 82]);
        // Hidden / noise files that must be skipped
        std::fs::write(brand_dir.join(".DS_Store"), b"noise").unwrap();
        std::fs::write(brand_dir.join("Thumbs.db"), b"noise").unwrap();
        std::fs::write(ignored_git.join("HEAD"), b"ref: refs/heads/main").unwrap();

        // 1. Mixed drop (loose file + nested folder + empty folder + reserved root "Inbox" folder)
        let report = engine
            .ingest_local_paths(
                vec![
                    loose_file.clone(),
                    brand_dir.clone(),
                    empty_dir.clone(),
                    reserved_inbox_dir.clone(),
                ],
                None,
                None,
            )
            .await
            .unwrap();

        assert_eq!(report.assets.len(), 3);
        assert_eq!(report.created_folders.len(), 4); // BrandKit, Icons, EmptyMood, Inbox (导入)
        let folders = engine.fetch_folders().unwrap();
        let f_brand = folders
            .iter()
            .find(|f| f.name == "BrandKit" && f.parent_id.is_none())
            .expect("BrandKit root folder created");
        let f_icons = folders
            .iter()
            .find(|f| f.name == "Icons" && f.parent_id == Some(f_brand.id))
            .expect("Icons child folder created under BrandKit");
        let f_empty = folders
            .iter()
            .find(|f| f.name == "EmptyMood" && f.parent_id.is_none())
            .expect("EmptyMood root folder created");
        assert!(folders
            .iter()
            .any(|f| f.name == "Inbox (导入)" && f.parent_id.is_none()));
        assert!(!folders.iter().any(|f| f.name == ".git"));

        let loose_asset = report
            .assets
            .iter()
            .find(|a| a.file_name.to_ascii_lowercase().contains("loose"))
            .unwrap();
        assert_eq!(loose_asset.folder_id, None);
        let cover_asset = report
            .assets
            .iter()
            .find(|a| a.file_name.to_ascii_lowercase().contains("cover"))
            .unwrap();
        assert_eq!(cover_asset.folder_id, Some(f_brand.id));
        let icon_asset = report
            .assets
            .iter()
            .find(|a| a.file_name.to_ascii_lowercase().contains("arrow"))
            .unwrap();
        assert_eq!(icon_asset.folder_id, Some(f_icons.id));

        // 2. Re-dropping BrandKit with a new file reuses existing BrandKit & Icons folders (no AlreadyExists error)
        let _extra = write_test_card_png(&brand_dir, "extra.png", [220, 60, 40], [250, 200, 30]);
        let report2 = engine
            .ingest_local_paths(vec![brand_dir.clone()], None, None)
            .await
            .unwrap();
        assert!(
            report2.created_folders.is_empty(),
            "Existing folders must be reused rather than duplicated"
        );
        assert_eq!(report2.matched_folder_names, vec!["BrandKit".to_string()]);
        assert_eq!(report2.assets.len(), 3);

        // 3. Dropping a folder INTO an existing parent folder (EmptyMood) nests it as a child folder
        let sub_drop = drop_root.join("SubDrop");
        std::fs::create_dir_all(&sub_drop).unwrap();
        let _sub_img = write_test_card_png(&sub_drop, "sub.png", [15, 25, 35], [100, 160, 240]);
        let report3 = engine
            .ingest_local_paths(vec![sub_drop], Some(f_empty.id), None)
            .await
            .unwrap();
        assert_eq!(report3.created_folders.len(), 1);
        assert_eq!(report3.created_folders[0].name, "SubDrop");
        assert_eq!(report3.created_folders[0].parent_id, Some(f_empty.id));
        assert_eq!(report3.assets.len(), 1);
        assert_eq!(
            report3.assets[0].folder_id,
            Some(report3.created_folders[0].id)
        );
    }
}
