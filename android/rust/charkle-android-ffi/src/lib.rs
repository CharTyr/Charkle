//! UniFFI bridge exposing the platform-agnostic `charkle-core` engine to Android (Kotlin / Compose).

use std::collections::{BTreeMap, HashMap, HashSet};
use std::path::{Component, Path, PathBuf};
use std::sync::{Arc, OnceLock};
use std::time::Duration;

use async_trait::async_trait;
use chrono::{Duration as ChronoDuration, Utc};
use reqwest::Client;
use serde::{Deserialize, Serialize};
use serde_json::{json, Map, Value};
use tokio::runtime::Runtime;
use url::Url;
use uuid::Uuid;

use charkle_core::db::LibraryDatabase;
use charkle_core::engine::{EngineEvent, LiveCharkleEngine};
use charkle_core::error::CoreError;
use charkle_core::export::MoodboardExportOptions;
use charkle_core::media::MediaPipeline;
use charkle_core::models::core::{AssetBatchPatch, AssetRecord, FilterCriteria};
use charkle_core::models::media::{CaptureInput, ThumbnailTier};
use charkle_core::models::moodboard::MoodboardDocument;
use charkle_core::models::sync::{DriveSyncConfig, SyncBackendProfile};
use charkle_core::pinterest::{
    PinterestAccount, PinterestBoard, PinterestBoardImportDestination, PinterestFeedPage,
    PinterestFeedSource, PinterestImportService, PinterestJSONParser, PinterestPin,
    PinterestPinDetailResult, PinterestSpatialLayout,
};
use charkle_core::sync::{GoogleOAuthClient, GoogleOAuthClientConfig, GoogleOAuthToken};
use charkle_core::traits::{
    BasicVolumeMountInspector, NativeOcrProvider, NoopOcrProvider, SecretVault,
};
use charkle_core::wire::swift_codec::format_swift_uuid;

const PINTEREST_BROWSER_UA: &str = "Mozilla/5.0 (Linux; Android 15; Pixel 9 Pro) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Mobile Safari/537.36";

uniffi::setup_scaffolding!();

#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum CharkleFfiError {
    #[error("{detail}")]
    Core { detail: String },
    #[error("Invalid argument: {detail}")]
    InvalidArgument { detail: String },
    #[error("Internal error: {detail}")]
    Internal { detail: String },
}

impl From<CoreError> for CharkleFfiError {
    fn from(err: CoreError) -> Self {
        Self::Core {
            detail: err.to_string(),
        }
    }
}

impl From<serde_json::Error> for CharkleFfiError {
    fn from(err: serde_json::Error) -> Self {
        Self::InvalidArgument {
            detail: format!("JSON codec error: {err}"),
        }
    }
}

/// Kotlin-implemented Android Keystore / EncryptedPreferences secret storage.
#[uniffi::export(callback_interface)]
pub trait AndroidSecretVault: Send + Sync {
    fn get_secret(&self, key: String) -> Option<String>;
    fn set_secret(&self, key: String, value: String) -> Result<(), CharkleFfiError>;
    fn delete_secret(&self, key: String) -> Result<(), CharkleFfiError>;
}

/// Optional Kotlin-implemented offline OCR bridge (e.g. ML Kit Chinese + Latin text recognition).
#[uniffi::export(callback_interface)]
pub trait AndroidOcrBridge: Send + Sync {
    fn recognize_text(&self, image_bytes: Vec<u8>) -> Option<String>;
}

/// Live push listener receiving `EngineEvent` payloads encoded as camelCase JSON.
#[uniffi::export(callback_interface)]
pub trait AndroidEngineEventListener: Send + Sync {
    fn on_event(&self, event_json: String);
}

/// PKCE authorization session returned to Kotlin for launching Chrome Custom Tabs.
#[derive(Debug, Clone, uniffi::Record)]
pub struct GooglePkceStartDto {
    pub auth_url: String,
    pub code_verifier: String,
    pub state: String,
    pub redirect_uri: String,
}

/// Result of importing a Google OAuth `client_secret.json` payload.
#[derive(Debug, Clone, uniffi::Record)]
pub struct GoogleOAuthClientSummaryDto {
    pub client_id: String,
    pub reversed_client_id_scheme: String,
}

struct VaultAdapter {
    inner: Arc<dyn AndroidSecretVault>,
}

#[async_trait]
impl SecretVault for VaultAdapter {
    async fn get_secret(&self, key: &str) -> Result<Option<String>, String> {
        let vault = Arc::clone(&self.inner);
        let key_owned = key.to_string();
        tokio::task::spawn_blocking(move || vault.get_secret(key_owned))
            .await
            .map_err(|e| format!("SecretVault join error: {e}"))
    }

    async fn set_secret(&self, key: &str, value: &str) -> Result<(), String> {
        let vault = Arc::clone(&self.inner);
        let key_owned = key.to_string();
        let value_owned = value.to_string();
        tokio::task::spawn_blocking(move || vault.set_secret(key_owned, value_owned))
            .await
            .map_err(|e| format!("SecretVault join error: {e}"))?
            .map_err(|e| e.to_string())
    }

    async fn delete_secret(&self, key: &str) -> Result<(), String> {
        let vault = Arc::clone(&self.inner);
        let key_owned = key.to_string();
        tokio::task::spawn_blocking(move || vault.delete_secret(key_owned))
            .await
            .map_err(|e| format!("SecretVault join error: {e}"))?
            .map_err(|e| e.to_string())
    }
}

struct OcrAdapter {
    inner: Arc<dyn AndroidOcrBridge>,
}

#[async_trait]
impl NativeOcrProvider for OcrAdapter {
    async fn recognize_text(&self, image_bytes: &[u8]) -> Result<Option<String>, String> {
        let bridge = Arc::clone(&self.inner);
        let bytes = image_bytes.to_vec();
        tokio::task::spawn_blocking(move || bridge.recognize_text(bytes))
            .await
            .map_err(|e| format!("OCR bridge join error: {e}"))
    }
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct SemanticSearchHitDto {
    asset: AssetRecord,
    score: f64,
    reason: String,
    source_label: String,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct SemanticSearchReportDto {
    query: String,
    summary: String,
    hits: Vec<SemanticSearchHitDto>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct CachedMediaPathsDto {
    #[serde(skip_serializing_if = "Option::is_none")]
    grid_thumb_path: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    preview_thumb_path: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    original_path: Option<String>,
}

#[derive(Deserialize)]
struct OAuthTokenEndpointResponse {
    access_token: String,
    #[serde(default)]
    refresh_token: Option<String>,
    #[serde(default)]
    expires_in: Option<i64>,
}

fn parse_uuid(raw: &str) -> Result<Uuid, CharkleFfiError> {
    Uuid::parse_str(raw.trim()).map_err(|_| CharkleFfiError::InvalidArgument {
        detail: format!("Invalid UUID: {raw}"),
    })
}

fn parse_opt_uuid(raw: Option<String>) -> Result<Option<Uuid>, CharkleFfiError> {
    match raw {
        Some(s) if !s.trim().is_empty() => Ok(Some(parse_uuid(&s)?)),
        _ => Ok(None),
    }
}

fn validate_charkleboard_export_path(
    raw: &str,
    data_dir: &Path,
) -> Result<PathBuf, CharkleFfiError> {
    let trimmed = raw.trim();
    if trimmed.is_empty() || trimmed.contains('\0') {
        return Err(CharkleFfiError::InvalidArgument {
            detail: "Export destination path must not be empty or contain NUL bytes".to_string(),
        });
    }
    let path = PathBuf::from(trimmed);
    if !path.is_absolute() {
        return Err(CharkleFfiError::InvalidArgument {
            detail: "Export destination path must be absolute".to_string(),
        });
    }
    if path
        .components()
        .any(|c| matches!(c, Component::ParentDir))
    {
        return Err(CharkleFfiError::InvalidArgument {
            detail: "Export destination path must not contain parent traversal ('..')".to_string(),
        });
    }
    let ext_ok = path
        .extension()
        .and_then(|e| e.to_str())
        .is_some_and(|e| e.eq_ignore_ascii_case("charkleboard"));
    if !ext_ok || path.file_stem().and_then(|s| s.to_str()).unwrap_or("").is_empty() {
        return Err(CharkleFfiError::InvalidArgument {
            detail: "Export destination must end with a valid .charkleboard file name".to_string(),
        });
    }
    if path.is_dir() {
        return Err(CharkleFfiError::InvalidArgument {
            detail: "Export destination must be a file path, not a directory".to_string(),
        });
    }
    let canonical_root = data_dir
        .canonicalize()
        .unwrap_or_else(|_| data_dir.to_path_buf());
    let candidate_parent = path
        .parent()
        .and_then(|p| p.canonicalize().ok())
        .unwrap_or_else(|| path.parent().map(Path::to_path_buf).unwrap_or_default());
    if path.starts_with(data_dir)
        || path.starts_with(&canonical_root)
        || candidate_parent.starts_with(&canonical_root)
    {
        return Err(CharkleFfiError::InvalidArgument {
            detail: "Export destination must not write inside the internal library data directory"
                .to_string(),
        });
    }
    Ok(path)
}

fn derive_reversed_client_scheme(client_id: &str) -> String {
    let trimmed = client_id.trim();
    if let Some(prefix) = trimmed.strip_suffix(".apps.googleusercontent.com") {
        format!("com.googleusercontent.apps.{prefix}")
    } else {
        trimmed.split('.').rev().collect::<Vec<_>>().join(".")
    }
}

fn shared_runtime() -> Result<&'static Runtime, CharkleFfiError> {
    static RUNTIME: OnceLock<Result<Runtime, String>> = OnceLock::new();
    match RUNTIME.get_or_init(|| {
        tokio::runtime::Builder::new_multi_thread()
            .worker_threads(2)
            .enable_all()
            .build()
            .map_err(|e| format!("Failed to create Tokio runtime: {e}"))
    }) {
        Ok(rt) => Ok(rt),
        Err(msg) => Err(CharkleFfiError::Internal {
            detail: msg.clone(),
        }),
    }
}

/// Long-lived engine handle owned by `CharkleApplication` on Android.
#[derive(uniffi::Object)]
pub struct AndroidEngineHandle {
    engine: Arc<LiveCharkleEngine>,
    data_dir: PathBuf,
    runtime: &'static Runtime,
    http: Client,
}

#[uniffi::export]
impl AndroidEngineHandle {
    /// Opens a persistent Charkle library inside `data_dir` (`Library.sqlite3`, `Originals/`, `Thumbnails/`).
    #[uniffi::constructor]
    pub fn open(
        data_dir: String,
        vault: Box<dyn AndroidSecretVault>,
        ocr: Option<Box<dyn AndroidOcrBridge>>,
    ) -> Result<Arc<Self>, CharkleFfiError> {
        let root = PathBuf::from(data_dir.trim());
        if root.as_os_str().is_empty() {
            return Err(CharkleFfiError::InvalidArgument {
                detail: "data_dir must not be empty".to_string(),
            });
        }
        std::fs::create_dir_all(&root).map_err(|e| CharkleFfiError::Internal {
            detail: format!("Failed to create library directory: {e}"),
        })?;

        let runtime = shared_runtime()?;

        let db = Arc::new(LibraryDatabase::open(&root.join("Library.sqlite3"))?);
        let media = MediaPipeline::new(&root)?;
        let vault_arc: Arc<dyn SecretVault> = Arc::new(VaultAdapter {
            inner: Arc::from(vault),
        });
        let ocr_arc: Arc<dyn NativeOcrProvider> = match ocr {
            Some(bridge) => Arc::new(OcrAdapter {
                inner: Arc::from(bridge),
            }),
            None => Arc::new(NoopOcrProvider),
        };

        let engine = Arc::new(LiveCharkleEngine::new(
            db,
            media,
            vault_arc,
            ocr_arc,
            Arc::new(BasicVolumeMountInspector),
            None,
        ));

        let http = Client::builder()
            .connect_timeout(Duration::from_secs(12))
            .timeout(Duration::from_secs(30))
            .redirect(reqwest::redirect::Policy::limited(8))
            .build()
            .unwrap_or_else(|_| Client::new());

        Ok(Arc::new(Self {
            engine,
            data_dir: root,
            runtime,
            http,
        }))
    }

    /// Registers a listener receiving live engine / sync events as camelCase JSON strings.
    pub fn subscribe_events(&self, listener: Box<dyn AndroidEngineEventListener>) {
        let mut rx = self.engine.subscribe_events();
        let listener: Arc<dyn AndroidEngineEventListener> = Arc::from(listener);
        self.runtime.spawn(async move {
            loop {
                match rx.recv().await {
                    Ok(event) => {
                        if let Ok(json) = serde_json::to_string(&event) {
                            let cb = Arc::clone(&listener);
                            let _ = tokio::task::spawn_blocking(move || cb.on_event(json)).await;
                        }
                    }
                    Err(tokio::sync::broadcast::error::RecvError::Lagged(_)) => {
                        if let Ok(json) = serde_json::to_string(&EngineEvent::LibraryChanged) {
                            let cb = Arc::clone(&listener);
                            let _ = tokio::task::spawn_blocking(move || cb.on_event(json)).await;
                        }
                    }
                    Err(tokio::sync::broadcast::error::RecvError::Closed) => break,
                }
            }
        });
    }

    pub fn engine_version(&self) -> String {
        env!("CARGO_PKG_VERSION").to_string()
    }

    // =========================================================================
    // Assets, Queries, Similarity & Quick Jump
    // =========================================================================

    pub fn fetch_assets_json(&self, criteria_json: String) -> Result<String, CharkleFfiError> {
        let criteria: FilterCriteria = if criteria_json.trim().is_empty() {
            FilterCriteria::default()
        } else {
            serde_json::from_str(&criteria_json)?
        };
        let assets = self.engine.fetch_assets(&criteria)?;
        Ok(serde_json::to_string(&assets)?)
    }

    pub fn fetch_asset_json(&self, asset_id: String) -> Result<Option<String>, CharkleFfiError> {
        let id = parse_uuid(&asset_id)?;
        let maybe = self.engine.fetch_asset(id)?;
        Ok(match maybe {
            Some(asset) => Some(serde_json::to_string(&asset)?),
            None => None,
        })
    }

    pub fn update_assets_json(&self, patch_json: String) -> Result<String, CharkleFfiError> {
        let patch: AssetBatchPatch = serde_json::from_str(&patch_json)?;
        let updated = self.engine.update_assets(&patch)?;
        Ok(serde_json::to_string(&updated)?)
    }

    pub fn permanently_delete_assets(&self, asset_ids: Vec<String>) -> Result<(), CharkleFfiError> {
        let ids: Vec<Uuid> = asset_ids
            .iter()
            .map(|s| parse_uuid(s))
            .collect::<Result<_, _>>()?;
        self.engine.permanently_delete_assets(&ids)?;
        Ok(())
    }

    pub fn mark_asset_opened_json(
        &self,
        asset_id: String,
    ) -> Result<Option<String>, CharkleFfiError> {
        let id = parse_uuid(&asset_id)?;
        let maybe = self.engine.mark_asset_opened(id)?;
        Ok(match maybe {
            Some(asset) => Some(serde_json::to_string(&asset)?),
            None => None,
        })
    }

    pub fn hydrate_image_metadata_json(
        &self,
        asset_id: String,
    ) -> Result<Option<String>, CharkleFfiError> {
        let id = parse_uuid(&asset_id)?;
        let maybe = self.engine.hydrate_image_metadata(id)?;
        Ok(match maybe {
            Some(asset) => Some(serde_json::to_string(&asset)?),
            None => None,
        })
    }

    pub fn similar_assets_json(
        &self,
        asset_id: String,
        limit: u32,
    ) -> Result<String, CharkleFfiError> {
        let id = parse_uuid(&asset_id)?;
        let items = self.engine.similar_assets(id, limit as usize)?;
        Ok(serde_json::to_string(&items)?)
    }

    pub fn suggest_folder_json(&self, asset_id: String) -> Result<Option<String>, CharkleFfiError> {
        let id = parse_uuid(&asset_id)?;
        let suggestion = self.engine.suggest_folder(id)?;
        Ok(match suggestion {
            Some(s) => Some(serde_json::to_string(&s)?),
            None => None,
        })
    }

    pub fn quick_jump_json(&self, query: String, limit: u32) -> Result<String, CharkleFfiError> {
        let matches = self.engine.quick_jump(&query, limit as usize)?;
        Ok(serde_json::to_string(&matches)?)
    }

    pub fn semantic_search_local_json(
        &self,
        query: String,
        criteria_json: String,
        limit: u32,
    ) -> Result<String, CharkleFfiError> {
        let criteria: FilterCriteria = if criteria_json.trim().is_empty() {
            FilterCriteria::default()
        } else {
            serde_json::from_str(&criteria_json)?
        };
        let report =
            self.engine
                .semantic_search_local(&query, &criteria, limit as usize, &[], &[])?;
        let dto = SemanticSearchReportDto {
            query: report.query,
            summary: report.summary,
            hits: report
                .hits
                .into_iter()
                .map(|h| SemanticSearchHitDto {
                    asset: h.asset,
                    score: h.score,
                    reason: h.reason,
                    source_label: h.source_label.to_string(),
                })
                .collect(),
        };
        Ok(serde_json::to_string(&dto)?)
    }

    pub fn inbox_count(&self) -> Result<u64, CharkleFfiError> {
        Ok(self.engine.inbox_count()? as u64)
    }

    pub fn fetch_tag_counts_json(&self) -> Result<String, CharkleFfiError> {
        let counts = self.engine.fetch_tag_counts()?;
        Ok(serde_json::to_string(&counts)?)
    }

    // =========================================================================
    // Folders & Smart Folders
    // =========================================================================

    pub fn fetch_folders_json(&self) -> Result<String, CharkleFfiError> {
        Ok(serde_json::to_string(&self.engine.fetch_folders()?)?)
    }

    pub fn create_folder_json(
        &self,
        name: String,
        parent_id: Option<String>,
    ) -> Result<String, CharkleFfiError> {
        let folder = self
            .engine
            .create_folder(&name, parse_opt_uuid(parent_id)?)?;
        Ok(serde_json::to_string(&folder)?)
    }

    pub fn rename_folder_json(
        &self,
        folder_id: String,
        new_name: String,
    ) -> Result<String, CharkleFfiError> {
        let folder = self.engine.rename_folder(parse_uuid(&folder_id)?, &new_name)?;
        Ok(serde_json::to_string(&folder)?)
    }

    pub fn move_folder_json(
        &self,
        folder_id: String,
        new_parent_id: Option<String>,
        insert_at_index: Option<u32>,
    ) -> Result<String, CharkleFfiError> {
        let folders = self.engine.move_folder(
            parse_uuid(&folder_id)?,
            parse_opt_uuid(new_parent_id)?,
            insert_at_index.map(|i| i as usize),
        )?;
        Ok(serde_json::to_string(&folders)?)
    }

    pub fn update_folder_appearance_json(
        &self,
        folder_id: String,
        color_hex: Option<String>,
        custom_symbol: Option<String>,
    ) -> Result<String, CharkleFfiError> {
        let folder = self.engine.update_folder_appearance(
            parse_uuid(&folder_id)?,
            color_hex,
            custom_symbol,
        )?;
        Ok(serde_json::to_string(&folder)?)
    }

    pub fn delete_folder(
        &self,
        folder_id: String,
        trash_contents: bool,
    ) -> Result<(), CharkleFfiError> {
        self.engine
            .delete_folder(parse_uuid(&folder_id)?, trash_contents)?;
        Ok(())
    }

    pub fn fetch_smart_folders_json(&self) -> Result<String, CharkleFfiError> {
        Ok(serde_json::to_string(&self.engine.fetch_smart_folders()?)?)
    }

    /// Fetches non-trashed assets matching a Smart Folder's rule composed with optional user filters.
    pub fn fetch_smart_folder_assets_json(
        &self,
        smart_folder_id: String,
        criteria_json: String,
    ) -> Result<String, CharkleFfiError> {
        let target_id = parse_uuid(&smart_folder_id)?;
        let smart_folders = self.engine.fetch_smart_folders()?;
        let Some(smart_folder) = smart_folders.into_iter().find(|sf| sf.id == target_id) else {
            return Ok("[]".to_string());
        };
        let mut criteria: FilterCriteria = if criteria_json.trim().is_empty() {
            FilterCriteria::default()
        } else {
            serde_json::from_str(&criteria_json)?
        };
        criteria.folder_id = None;
        criteria.only_inbox = false;
        criteria.only_trashed = false;
        criteria.include_trashed = false;

        let candidates = self.engine.fetch_assets(&criteria)?;
        let matched: Vec<AssetRecord> = candidates
            .into_iter()
            .filter(|asset| smart_folder.rule.matches(asset))
            .collect();
        Ok(serde_json::to_string(&matched)?)
    }

    // =========================================================================
    // Moodboards
    // =========================================================================

    pub fn fetch_boards_json(&self) -> Result<String, CharkleFfiError> {
        Ok(serde_json::to_string(&self.engine.fetch_boards()?)?)
    }

    pub fn fetch_board_json(&self, board_id: String) -> Result<Option<String>, CharkleFfiError> {
        let maybe = self.engine.fetch_board(parse_uuid(&board_id)?)?;
        Ok(match maybe {
            Some(doc) => Some(serde_json::to_string(&doc)?),
            None => None,
        })
    }

    pub fn create_board_json(&self, title: String) -> Result<String, CharkleFfiError> {
        let clean = title.trim();
        let doc = MoodboardDocument::new(if clean.is_empty() { "未命名情绪板" } else { clean });
        let saved = self.engine.save_board(&doc)?;
        Ok(serde_json::to_string(&saved)?)
    }

    pub fn save_board_json(&self, document_json: String) -> Result<String, CharkleFfiError> {
        let doc: MoodboardDocument = serde_json::from_str(&document_json)?;
        let saved = self.engine.save_board(&doc)?;
        Ok(serde_json::to_string(&saved)?)
    }

    pub fn solve_editorial_layout_json(
        &self,
        document_json: String,
        container_width: f64,
    ) -> Result<String, CharkleFfiError> {
        let doc: MoodboardDocument = serde_json::from_str(&document_json)?;
        let result = self.engine.solve_editorial_layout(&doc, container_width)?;
        Ok(serde_json::to_string(&result)?)
    }

    pub fn delete_board(&self, board_id: String) -> Result<(), CharkleFfiError> {
        self.engine.delete_board(parse_uuid(&board_id)?)?;
        Ok(())
    }

    pub fn set_board_pinned_offline_json(
        &self,
        board_id: String,
        pinned: bool,
    ) -> Result<String, CharkleFfiError> {
        let doc = self
            .engine
            .set_board_pinned_offline(parse_uuid(&board_id)?, pinned)?;
        Ok(serde_json::to_string(&doc)?)
    }

    pub fn export_board_image_bytes(
        &self,
        board_id: String,
        options_json: String,
    ) -> Result<Vec<u8>, CharkleFfiError> {
        let doc = self
            .engine
            .fetch_board(parse_uuid(&board_id)?)?
            .ok_or_else(|| CharkleFfiError::Core {
                detail: format!("Board not found: {board_id}"),
            })?;
        let options: MoodboardExportOptions = if options_json.trim().is_empty() {
            MoodboardExportOptions::default()
        } else {
            serde_json::from_str(&options_json)?
        };
        Ok(self.engine.export_board_image_bytes(&doc, &options)?)
    }

    pub fn export_board_figma_bridge_json(
        &self,
        board_id: String,
        options_json: String,
        destination_path: String,
    ) -> Result<String, CharkleFfiError> {
        let safe_dest = validate_charkleboard_export_path(&destination_path, &self.data_dir)?;
        let doc = self
            .engine
            .fetch_board(parse_uuid(&board_id)?)?
            .ok_or_else(|| CharkleFfiError::Core {
                detail: format!("Board not found: {board_id}"),
            })?;
        let options: MoodboardExportOptions = if options_json.trim().is_empty() {
            MoodboardExportOptions::default()
        } else {
            serde_json::from_str(&options_json)?
        };
        let report = self
            .engine
            .export_board_figma_bridge(&doc, &options, &safe_dest)?;
        Ok(serde_json::to_string(&report)?)
    }

    // =========================================================================
    // Pinterest Spatial Layout & Library Duplicate Index
    // =========================================================================

    pub fn pinterest_existing_imported_pin_ids(&self) -> Vec<String> {
        let mut ids: Vec<String> = PinterestImportService::existing_imported_pin_ids(&self.engine)
            .into_iter()
            .collect();
        ids.sort();
        ids
    }

    pub fn pinterest_compute_spatial_layout_json(
        &self,
        pins_json: String,
        card_width: f64,
        gap: f64,
    ) -> Result<String, CharkleFfiError> {
        let pins: Vec<PinterestPin> = serde_json::from_str(&pins_json)?;
        let mut layout = PinterestSpatialLayout::new(card_width, gap);
        layout.append(&pins);
        Ok(serde_json::to_string(layout.cards())?)
    }

    // =========================================================================
    // Media Paths & Cache Budget
    // =========================================================================

    /// Batch-resolves cached grid thumbnail, preview thumbnail, and original file paths
    /// in a single O(M + N) pass so Android UI never executes synchronous FFI/stat calls on main thread.
    pub fn resolve_media_paths_json(
        &self,
        asset_ids: Vec<String>,
    ) -> Result<String, CharkleFfiError> {
        if asset_ids.is_empty() {
            return Ok("{}".to_string());
        }
        let media = self.engine.media();
        let originals_by_id: HashMap<Uuid, PathBuf> = media
            .original_entries()
            .into_iter()
            .map(|entry| (entry.id, entry.path))
            .collect();

        let mut resolved: BTreeMap<String, CachedMediaPathsDto> = BTreeMap::new();
        for raw_id in asset_ids {
            let Ok(id) = Uuid::parse_str(raw_id.trim()) else {
                continue;
            };
            let canonical_key = format_swift_uuid(&id);
            if resolved.contains_key(&canonical_key) {
                continue;
            }
            let grid = media
                .thumbnail_url(id, ThumbnailTier::Grid520)
                .map(|p| p.to_string_lossy().into_owned());
            let preview = media
                .thumbnail_url(id, ThumbnailTier::Preview1400)
                .map(|p| p.to_string_lossy().into_owned());
            let original = originals_by_id
                .get(&id)
                .map(|p| p.to_string_lossy().into_owned());
            resolved.insert(
                canonical_key,
                CachedMediaPathsDto {
                    grid_thumb_path: grid,
                    preview_thumb_path: preview,
                    original_path: original,
                },
            );
        }
        Ok(serde_json::to_string(&resolved)?)
    }

    pub fn cached_thumbnail_path(
        &self,
        asset_id: String,
        preview_tier: bool,
    ) -> Result<Option<String>, CharkleFfiError> {
        let tier = if preview_tier {
            ThumbnailTier::Preview1400
        } else {
            ThumbnailTier::Grid520
        };
        Ok(self
            .engine
            .cached_thumbnail_path(parse_uuid(&asset_id)?, tier)
            .map(|p| p.to_string_lossy().into_owned()))
    }

    pub fn cached_original_path(
        &self,
        asset_id: String,
    ) -> Result<Option<String>, CharkleFfiError> {
        let id = parse_uuid(&asset_id)?;
        let Some(asset) = self.engine.fetch_asset(id)? else {
            return Ok(None);
        };
        Ok(self
            .engine
            .cached_original_path(&asset)
            .map(|p| p.to_string_lossy().into_owned()))
    }

    pub fn cache_stats_json(&self) -> Result<String, CharkleFfiError> {
        Ok(serde_json::to_string(&self.engine.cache_stats()?)?)
    }

    pub fn set_cache_budget_bytes(&self, bytes: i64) -> Result<i64, CharkleFfiError> {
        Ok(self.engine.set_cache_budget_bytes(bytes)?)
    }

    pub fn evict_cache_now_json(&self) -> Result<String, CharkleFfiError> {
        Ok(serde_json::to_string(&self.engine.evict_cache_now()?)?)
    }

    // =========================================================================
    // Sync Configuration (Sync-Free Read/Write)
    // =========================================================================

    pub fn sync_config_json(&self) -> Result<String, CharkleFfiError> {
        Ok(serde_json::to_string(&self.engine.sync_config())?)
    }

    pub fn save_sync_config_json(&self, config_json: String) -> Result<(), CharkleFfiError> {
        let config: DriveSyncConfig = serde_json::from_str(&config_json)?;
        self.engine.save_sync_config(config)?;
        Ok(())
    }
}

/// Async operations executed on Tokio so Kotlin calls them cleanly as `suspend fun`.
#[uniffi::export(async_runtime = "tokio")]
impl AndroidEngineHandle {
    pub async fn seed_sample_library_if_empty(&self) -> Result<bool, CharkleFfiError> {
        let engine = Arc::clone(&self.engine);
        self.runtime
            .spawn(async move { engine.seed_sample_library_if_empty().await })
            .await
            .map_err(|e| CharkleFfiError::Internal {
                detail: format!("Task join failed: {e}"),
            })?
            .map_err(Into::into)
    }

    pub async fn ingest_local_files_json(
        &self,
        paths: Vec<String>,
        target_folder_id: Option<String>,
        target_board_id: Option<String>,
    ) -> Result<String, CharkleFfiError> {
        let folder_id = parse_opt_uuid(target_folder_id)?;
        let board_id = parse_opt_uuid(target_board_id)?;
        let inputs: Vec<CaptureInput> = paths
            .into_iter()
            .map(|p| CaptureInput::FilePath(PathBuf::from(p)))
            .collect();
        let engine = Arc::clone(&self.engine);
        let assets = self
            .runtime
            .spawn(async move { engine.ingest(inputs, folder_id, board_id).await })
            .await
            .map_err(|e| CharkleFfiError::Internal {
                detail: format!("Ingest task failed: {e}"),
            })??;
        Ok(serde_json::to_string(&assets)?)
    }

    pub async fn ingest_web_url_json(
        &self,
        url: String,
        title: Option<String>,
        notes: Option<String>,
        target_folder_id: Option<String>,
    ) -> Result<String, CharkleFfiError> {
        let folder_id = parse_opt_uuid(target_folder_id)?;
        let engine = Arc::clone(&self.engine);
        let input = CaptureInput::WebUrl { url, title, notes };
        let assets = self
            .runtime
            .spawn(async move { engine.ingest(vec![input], folder_id, None).await })
            .await
            .map_err(|e| CharkleFfiError::Internal {
                detail: format!("Web ingest task failed: {e}"),
            })??;
        Ok(serde_json::to_string(&assets)?)
    }

    pub async fn ingest_image_bytes_json(
        &self,
        data: Vec<u8>,
        suggested_name: String,
        source_url: Option<String>,
        target_folder_id: Option<String>,
    ) -> Result<String, CharkleFfiError> {
        let folder_id = parse_opt_uuid(target_folder_id)?;
        let engine = Arc::clone(&self.engine);
        let input = CaptureInput::ImageData {
            data,
            suggested_name,
            source_url,
        };
        let assets = self
            .runtime
            .spawn(async move { engine.ingest(vec![input], folder_id, None).await })
            .await
            .map_err(|e| CharkleFfiError::Internal {
                detail: format!("Image ingest task failed: {e}"),
            })??;
        Ok(serde_json::to_string(&assets)?)
    }

    pub async fn original_path_or_download(&self, asset_id: String) -> Result<String, CharkleFfiError> {
        let id = parse_uuid(&asset_id)?;
        let engine = Arc::clone(&self.engine);
        let path = self
            .runtime
            .spawn(async move { engine.original_path_or_download(id).await })
            .await
            .map_err(|e| CharkleFfiError::Internal {
                detail: format!("Download task failed: {e}"),
            })??;
        Ok(path.to_string_lossy().into_owned())
    }

    pub async fn sync_status_json(&self) -> Result<String, CharkleFfiError> {
        let engine = Arc::clone(&self.engine);
        let status = self
            .runtime
            .spawn(async move { engine.sync_status().await })
            .await
            .map_err(|e| CharkleFfiError::Internal {
                detail: format!("Sync status task failed: {e}"),
            })?;
        Ok(serde_json::to_string(&status)?)
    }

    pub async fn sync_now_json(&self) -> Result<String, CharkleFfiError> {
        let engine = Arc::clone(&self.engine);
        let report = self
            .runtime
            .spawn(async move { engine.sync_now().await })
            .await
            .map_err(|e| CharkleFfiError::Internal {
                detail: format!("Sync task failed: {e}"),
            })??;
        Ok(serde_json::to_string(&report)?)
    }

    pub async fn sync_backend_json(&self, backend_id: String) -> Result<String, CharkleFfiError> {
        let id = parse_uuid(&backend_id)?;
        let engine = Arc::clone(&self.engine);
        let report = self
            .runtime
            .spawn(async move { engine.sync_backend(id).await })
            .await
            .map_err(|e| CharkleFfiError::Internal {
                detail: format!("Backend sync task failed: {e}"),
            })??;
        Ok(serde_json::to_string(&report)?)
    }

    pub async fn test_backend_connection_json(
        &self,
        profile_json: String,
        webdav_password: Option<String>,
    ) -> Result<String, CharkleFfiError> {
        let profile: SyncBackendProfile = serde_json::from_str(&profile_json)?;
        let engine = Arc::clone(&self.engine);
        let info = self
            .runtime
            .spawn(async move {
                engine
                    .test_backend_connection(&profile, webdav_password.as_deref())
                    .await
            })
            .await
            .map_err(|e| CharkleFfiError::Internal {
                detail: format!("Connection test failed: {e}"),
            })??;
        Ok(serde_json::to_string(&info)?)
    }

    pub async fn save_backend_webdav_password(
        &self,
        backend_id: String,
        password: String,
    ) -> Result<(), CharkleFfiError> {
        let id = parse_uuid(&backend_id)?;
        let engine = Arc::clone(&self.engine);
        self.runtime
            .spawn(async move { engine.save_backend_webdav_password(id, &password).await })
            .await
            .map_err(|e| CharkleFfiError::Internal {
                detail: format!("Save password failed: {e}"),
            })??;
        Ok(())
    }

    pub async fn has_backend_webdav_password(&self, backend_id: String) -> Result<bool, CharkleFfiError> {
        let id = parse_uuid(&backend_id)?;
        let engine = Arc::clone(&self.engine);
        self.runtime
            .spawn(async move { engine.has_backend_webdav_password(id).await })
            .await
            .map_err(|e| CharkleFfiError::Internal {
                detail: format!("Password check failed: {e}"),
            })
    }

    pub async fn save_google_oauth_client_id(
        &self,
        client_id: String,
        client_secret: Option<String>,
    ) -> Result<GoogleOAuthClientSummaryDto, CharkleFfiError> {
        let trimmed_id = client_id.trim();
        if trimmed_id.is_empty() {
            return Err(CharkleFfiError::InvalidArgument {
                detail: "Google OAuth Client ID 不能为空".to_string(),
            });
        }
        let cfg = GoogleOAuthClientConfig::new(
            trimmed_id,
            client_secret.unwrap_or_default().trim(),
        );
        let summary = GoogleOAuthClientSummaryDto {
            client_id: cfg.client_id.clone(),
            reversed_client_id_scheme: derive_reversed_client_scheme(&cfg.client_id),
        };
        let engine = Arc::clone(&self.engine);
        self.runtime
            .spawn(async move { engine.oauth().save_client_config(&cfg).await })
            .await
            .map_err(|e| CharkleFfiError::Internal {
                detail: format!("OAuth save failed: {e}"),
            })??;
        Ok(summary)
    }

    pub async fn import_google_oauth_client_json(
        &self,
        raw_json: Vec<u8>,
    ) -> Result<GoogleOAuthClientSummaryDto, CharkleFfiError> {
        let cfg = GoogleOAuthClientConfig::parse_client_secret_json(&raw_json)?;
        let summary = GoogleOAuthClientSummaryDto {
            client_id: cfg.client_id.clone(),
            reversed_client_id_scheme: derive_reversed_client_scheme(&cfg.client_id),
        };
        let engine = Arc::clone(&self.engine);
        self.runtime
            .spawn(async move { engine.oauth().save_client_config(&cfg).await })
            .await
            .map_err(|e| CharkleFfiError::Internal {
                detail: format!("OAuth import failed: {e}"),
            })??;
        Ok(summary)
    }

    pub async fn has_google_oauth_client(&self) -> Result<bool, CharkleFfiError> {
        let engine = Arc::clone(&self.engine);
        let cfg = self
            .runtime
            .spawn(async move { engine.oauth().stored_config().await })
            .await
            .map_err(|e| CharkleFfiError::Internal {
                detail: format!("OAuth config lookup failed: {e}"),
            })??;
        Ok(cfg.is_some())
    }

    pub async fn google_oauth_sign_out(&self) -> Result<(), CharkleFfiError> {
        let engine = Arc::clone(&self.engine);
        self.runtime
            .spawn(async move { engine.oauth().sign_out().await })
            .await
            .map_err(|e| CharkleFfiError::Internal {
                detail: format!("OAuth sign out failed: {e}"),
            })??;
        Ok(())
    }

    /// Generates an RFC 8252 PKCE (`S256`) Google OAuth authorization URL for Chrome Custom Tabs.
    pub async fn prepare_google_pkce_auth(
        &self,
        redirect_uri: String,
        full_drive_scope: bool,
    ) -> Result<GooglePkceStartDto, CharkleFfiError> {
        let clean_redirect = redirect_uri.trim();
        if clean_redirect.is_empty() || Url::parse(clean_redirect).is_err() {
            return Err(CharkleFfiError::InvalidArgument {
                detail: "Invalid OAuth redirect URI".to_string(),
            });
        }
        let engine = Arc::clone(&self.engine);
        let cfg = self
            .runtime
            .spawn(async move { engine.oauth().stored_config().await })
            .await
            .map_err(|e| CharkleFfiError::Internal {
                detail: format!("OAuth config lookup failed: {e}"),
            })??
            .ok_or_else(|| CharkleFfiError::Core {
                detail: "请先填写 Google OAuth Client ID 或导入凭据文件。".to_string(),
            })?;

        let code_verifier = GoogleOAuthClient::generate_code_verifier();
        let code_challenge = GoogleOAuthClient::code_challenge_s256(&code_verifier);
        let state = Uuid::new_v4().simple().to_string();
        let scope = if full_drive_scope {
            "https://www.googleapis.com/auth/drive"
        } else {
            "https://www.googleapis.com/auth/drive.file"
        };

        let mut auth_url = Url::parse(&cfg.auth_uri).map_err(|_| CharkleFfiError::InvalidArgument {
            detail: "Invalid OAuth auth URI".to_string(),
        })?;
        auth_url
            .query_pairs_mut()
            .append_pair("client_id", &cfg.client_id)
            .append_pair("redirect_uri", clean_redirect)
            .append_pair("response_type", "code")
            .append_pair("scope", scope)
            .append_pair("code_challenge", &code_challenge)
            .append_pair("code_challenge_method", "S256")
            .append_pair("access_type", "offline")
            .append_pair("prompt", "consent")
            .append_pair("state", &state);

        Ok(GooglePkceStartDto {
            auth_url: auth_url.to_string(),
            code_verifier,
            state,
            redirect_uri: clean_redirect.to_string(),
        })
    }

    /// Exchanges an authorization code returned to Android's Custom Tabs redirect URI for a token
    /// and stores it inside the Android Keystore-backed `SecretVault`.
    pub async fn complete_google_pkce_auth(
        &self,
        code: String,
        code_verifier: String,
        redirect_uri: String,
    ) -> Result<(), CharkleFfiError> {
        if code.trim().is_empty()
            || code_verifier.trim().is_empty()
            || redirect_uri.trim().is_empty()
        {
            return Err(CharkleFfiError::InvalidArgument {
                detail: "OAuth code, verifier, and redirect URI must not be empty".to_string(),
            });
        }
        let engine = Arc::clone(&self.engine);
        let http = self.http.clone();
        self.runtime
            .spawn(async move {
                let cfg = engine
                    .oauth()
                    .stored_config()
                    .await?
                    .ok_or_else(|| CoreError::NotConfigured("缺少 Google OAuth 配置".to_string()))?;

                let mut form: Vec<(&str, &str)> = vec![
                    ("client_id", cfg.client_id.as_str()),
                    ("code", code.trim()),
                    ("code_verifier", code_verifier.trim()),
                    ("grant_type", "authorization_code"),
                    ("redirect_uri", redirect_uri.trim()),
                ];
                if !cfg.client_secret.is_empty() {
                    form.push(("client_secret", cfg.client_secret.as_str()));
                }

                let response = http.post(&cfg.token_uri).form(&form).send().await?;

                let status = response.status();
                let body = response.text().await?;

                if !status.is_success() {
                    let snippet: String = body.chars().take(240).collect();
                    return Err(CoreError::AuthenticationRequired(format!(
                        "Google 授权失败（HTTP {}）：{}",
                        status.as_u16(),
                        snippet
                    )));
                }

                let parsed: OAuthTokenEndpointResponse = serde_json::from_str(&body)?;
                if parsed.access_token.trim().is_empty() {
                    return Err(CoreError::AuthenticationRequired(
                        "Google 未返回有效访问令牌".to_string(),
                    ));
                }
                let expires_in = parsed.expires_in.unwrap_or(3600).max(60);
                let token = GoogleOAuthToken {
                    access_token: parsed.access_token,
                    refresh_token: parsed.refresh_token,
                    expires_at: Utc::now() + ChronoDuration::seconds(expires_in),
                };
                engine.oauth().save_token(&token).await?;
                Ok::<(), CoreError>(())
            })
            .await
            .map_err(|e| CharkleFfiError::Internal {
                detail: format!("OAuth token exchange join error: {e}"),
            })??;
        Ok(())
    }

    // =========================================================================
    // Pinterest Authenticated Web Resource API & Batch Import
    // =========================================================================

    pub async fn pinterest_check_session_json(
        &self,
        cookie_header: String,
    ) -> Result<Option<String>, CharkleFfiError> {
        let http = self.http.clone();
        let maybe_account = self
            .runtime
            .spawn(async move { pinterest_check_session_inner(&http, &cookie_header).await })
            .await
            .map_err(|e| CharkleFfiError::Internal {
                detail: format!("Pinterest session check failed: {e}"),
            })??;
        Ok(match maybe_account {
            Some(acc) => Some(serde_json::to_string(&acc)?),
            None => None,
        })
    }

    pub async fn pinterest_fetch_feed_json(
        &self,
        cookie_header: String,
        source_json: String,
        bookmark: Option<String>,
        page_size: u32,
    ) -> Result<String, CharkleFfiError> {
        let source: PinterestFeedSource = serde_json::from_str(&source_json)?;
        let http = self.http.clone();
        let page = self
            .runtime
            .spawn(async move {
                pinterest_fetch_feed_inner(
                    &http,
                    &cookie_header,
                    &source,
                    bookmark.as_deref(),
                    (page_size as usize).clamp(6, 50),
                )
                .await
            })
            .await
            .map_err(|e| CharkleFfiError::Internal {
                detail: format!("Pinterest feed task failed: {e}"),
            })??;
        Ok(serde_json::to_string(&page)?)
    }

    pub async fn pinterest_fetch_user_boards_json(
        &self,
        cookie_header: String,
        username: String,
    ) -> Result<String, CharkleFfiError> {
        let http = self.http.clone();
        let boards = self
            .runtime
            .spawn(async move {
                pinterest_fetch_user_boards_inner(&http, &cookie_header, &username).await
            })
            .await
            .map_err(|e| CharkleFfiError::Internal {
                detail: format!("Pinterest boards task failed: {e}"),
            })??;
        Ok(serde_json::to_string(&boards)?)
    }

    pub async fn pinterest_fetch_pin_detail_json(
        &self,
        cookie_header: String,
        pin_json: String,
    ) -> Result<String, CharkleFfiError> {
        let pin: PinterestPin = serde_json::from_str(&pin_json)?;
        let http = self.http.clone();
        let detail = self
            .runtime
            .spawn(async move {
                pinterest_fetch_pin_detail_inner(&http, &cookie_header, &pin).await
            })
            .await
            .map_err(|e| CharkleFfiError::Internal {
                detail: format!("Pinterest pin detail task failed: {e}"),
            })??;
        Ok(serde_json::to_string(&detail)?)
    }

    pub async fn pinterest_import_pins_json(
        &self,
        pins_json: String,
        target_folder_id: Option<String>,
        extra_tags: Vec<String>,
        skip_duplicates: bool,
    ) -> Result<String, CharkleFfiError> {
        let pins: Vec<PinterestPin> = serde_json::from_str(&pins_json)?;
        let folder_id = parse_opt_uuid(target_folder_id)?;
        let engine = Arc::clone(&self.engine);
        let report = self
            .runtime
            .spawn(async move {
                PinterestImportService::import_pins(
                    &pins,
                    &engine,
                    folder_id,
                    &extra_tags,
                    skip_duplicates,
                    |_, _, _| {},
                )
                .await
            })
            .await
            .map_err(|e| CharkleFfiError::Internal {
                detail: format!("Pinterest pin import failed: {e}"),
            })?;
        Ok(serde_json::to_string(&report)?)
    }

    pub async fn pinterest_import_boards_json(
        &self,
        cookie_header: String,
        boards_json: String,
        destination_json: String,
        extra_tags: Vec<String>,
        skip_duplicates: bool,
    ) -> Result<String, CharkleFfiError> {
        let boards: Vec<PinterestBoard> = serde_json::from_str(&boards_json)?;
        let destination: PinterestBoardImportDestination = serde_json::from_str(&destination_json)?;
        let engine = Arc::clone(&self.engine);
        let http = self.http.clone();
        let report = self
            .runtime
            .spawn(async move {
                PinterestImportService::import_boards(
                    &boards,
                    &engine,
                    destination,
                    &extra_tags,
                    skip_duplicates,
                    None,
                    |board| {
                        let http_cloned = http.clone();
                        let cookie_cloned = cookie_header.clone();
                        async move {
                            pinterest_fetch_all_board_pins_inner(
                                &http_cloned,
                                &cookie_cloned,
                                &board,
                                400,
                            )
                            .await
                        }
                    },
                    |url| async move { PinterestImportService::fetch_media_bytes(&url).await },
                    |_| {},
                )
                .await
            })
            .await
            .map_err(|e| CharkleFfiError::Internal {
                detail: format!("Pinterest board import failed: {e}"),
            })?;
        Ok(serde_json::to_string(&report)?)
    }
}

fn sanitize_header_value(raw: &str) -> String {
    raw.chars()
        .filter(|&c| c != '\r' && c != '\n' && c != '\0' && (c == ' ' || c == '\t' || (c as u32) >= 0x20))
        .collect::<String>()
        .trim()
        .to_string()
}

fn is_valid_cookie_name(name: &str) -> bool {
    !name.is_empty()
        && name.bytes().all(|b| {
            b.is_ascii_alphanumeric()
                || matches!(
                    b,
                    b'!' | b'#' | b'$' | b'%' | b'&' | b'\'' | b'*' | b'+' | b'-' | b'.' | b'^'
                        | b'_' | b'`' | b'|' | b'~'
                )
        })
}

fn sanitize_cookie_header(raw: &str) -> String {
    raw.split([';', '\r', '\n'])
        .filter_map(|segment| {
            let trimmed = segment.trim();
            let (k, v) = trimmed.split_once('=')?;
            let key = k.trim();
            let val = v.trim();
            if !is_valid_cookie_name(key)
                || val.is_empty()
                || !val.bytes().all(|b| (0x21..=0x7E).contains(&b) && b != b';')
            {
                return None;
            }
            Some(format!("{key}={val}"))
        })
        .collect::<Vec<_>>()
        .join("; ")
}

fn sanitize_pinterest_path_segment(raw: &str) -> Option<String> {
    let trimmed = raw.trim();
    if trimmed.is_empty()
        || trimmed.contains('/')
        || trimmed.contains('\\')
        || trimmed.contains("..")
        || trimmed.contains('?')
        || trimmed.contains('#')
        || trimmed.chars().any(char::is_whitespace)
    {
        return None;
    }
    Some(trimmed.to_string())
}

fn extract_cookie_value(cookie_header: &str, name: &str) -> Option<String> {
    cookie_header.split([';', '\r', '\n']).find_map(|pair| {
        let (k, v) = pair.trim().split_once('=')?;
        if k.trim().eq_ignore_ascii_case(name) {
            let trimmed = v.trim().trim_matches('"').trim();
            if !trimmed.is_empty()
                && trimmed
                    .bytes()
                    .all(|b| (0x21..=0x7E).contains(&b) && b != b';')
            {
                Some(trimmed.to_string())
            } else {
                None
            }
        } else {
            None
        }
    })
}

fn has_pinterest_session_cookies(cookie_header: &str) -> (bool, bool) {
    let has_sess = extract_cookie_value(cookie_header, "_pinterest_sess").is_some()
        || extract_cookie_value(cookie_header, "_auth").is_some();
    let has_auth_one = extract_cookie_value(cookie_header, "_auth")
        .map(|v| v == "1")
        .unwrap_or(false);
    (has_sess, has_auth_one)
}

async fn pinterest_fetch_resource_raw(
    http: &Client,
    cookie_header: &str,
    resource_path: &str,
    source_url: &str,
    options: Value,
) -> Result<(u16, Vec<u8>), CoreError> {
    let clean_source = sanitize_header_value(source_url);
    let normalized_source = if clean_source.starts_with('/') {
        clean_source
    } else {
        format!("/{clean_source}")
    };
    let clean_cookie = sanitize_cookie_header(cookie_header);

    let data_payload = json!({
        "options": options,
        "context": {}
    })
    .to_string();
    let ts = Utc::now().timestamp_millis().to_string();

    let mut url = Url::parse(&format!("https://www.pinterest.com{resource_path}"))
        .map_err(|e| CoreError::InvalidPayload(format!("Invalid Pinterest URL: {e}")))?;
    url.query_pairs_mut()
        .append_pair("source_url", &normalized_source)
        .append_pair("data", &data_payload)
        .append_pair("_", &ts);

    let mut req = http
        .get(url)
        .header("User-Agent", PINTEREST_BROWSER_UA)
        .header("Accept", "application/json, text/javascript, */*; q=0.01")
        .header("X-Requested-With", "XMLHttpRequest")
        .header("X-Pinterest-AppState", "active")
        .header("X-Pinterest-Source-Url", &normalized_source)
        .header("Referer", format!("https://www.pinterest.com{normalized_source}"));

    if !clean_cookie.is_empty() {
        req = req.header("Cookie", &clean_cookie);
    }
    if let Some(csrf) = extract_cookie_value(&clean_cookie, "csrftoken") {
        req = req.header("X-CSRFToken", csrf);
    }

    let resp = req.send().await?;
    let status = resp.status().as_u16();
    let bytes = resp.bytes().await?.to_vec();
    Ok((status, bytes))
}

fn validate_pinterest_status(status: u16) -> Result<(), CoreError> {
    if status == 401 || status == 403 {
        return Err(CoreError::AuthenticationRequired(
            "Pinterest 登录状态已失效，请重新登录。".to_string(),
        ));
    }
    if !(200..300).contains(&status) {
        return Err(CoreError::InvalidPayload(format!(
            "Pinterest 接口返回 HTTP {status}"
        )));
    }
    Ok(())
}

async fn pinterest_check_session_inner(
    http: &Client,
    cookie_header: &str,
) -> Result<Option<PinterestAccount>, CoreError> {
    let (has_sess, has_auth_one) = has_pinterest_session_cookies(cookie_header);
    if !has_sess {
        return Ok(None);
    }

    if let Ok((status, data)) = pinterest_fetch_resource_raw(
        http,
        cookie_header,
        "/resource/UserSettingsResource/get/",
        "/settings/",
        json!({}),
    )
    .await
    {
        if (200..300).contains(&status) {
            if let Some(acc) = PinterestJSONParser::parse_account(&data) {
                return Ok(Some(acc));
            }
        }
    }

    if let Ok((status, data)) = pinterest_fetch_resource_raw(
        http,
        cookie_header,
        "/resource/UserResource/get/",
        "/",
        json!({}),
    )
    .await
    {
        if (200..300).contains(&status) {
            if let Some(acc) = PinterestJSONParser::parse_account(&data) {
                return Ok(Some(acc));
            }
        }
    }

    if has_auth_one {
        if let Ok(probe) = pinterest_fetch_home_inner(http, cookie_header, None, 8).await {
            if !probe.pins.is_empty() {
                return Ok(Some(PinterestAccount {
                    id: "pinterest-active-session".to_string(),
                    username: String::new(),
                    full_name: "Pinterest 账号".to_string(),
                    avatar_url: None,
                    email: None,
                }));
            }
        }
    }

    Ok(None)
}

async fn pinterest_fetch_home_inner(
    http: &Client,
    cookie_header: &str,
    bookmark: Option<&str>,
    page_size: usize,
) -> Result<PinterestFeedPage, CoreError> {
    let mut options = Map::new();
    options.insert("isPrefetch".to_string(), json!(false));
    options.insert("field_set_key".to_string(), json!("hf_grid_partner"));
    options.insert("in_nux".to_string(), json!(false));
    options.insert("prependPartner".to_string(), json!(false));
    options.insert("prependUserNews".to_string(), json!(false));
    options.insert("static_feed".to_string(), json!(false));
    options.insert("page_size".to_string(), json!(page_size));
    if let Some(bm) = bookmark.filter(|s| !s.is_empty()) {
        options.insert("bookmarks".to_string(), json!([bm]));
    }

    let (status, data) = pinterest_fetch_resource_raw(
        http,
        cookie_header,
        "/resource/UserHomefeedResource/get/",
        "/",
        Value::Object(options),
    )
    .await?;
    validate_pinterest_status(status)?;

    let mut page = PinterestJSONParser::parse_feed_page(&data, "主页推荐");
    if page.pins.is_empty() && bookmark.is_none() {
        let mut retry_opts = Map::new();
        retry_opts.insert("page_size".to_string(), json!(page_size));
        if let Ok((retry_status, retry_data)) = pinterest_fetch_resource_raw(
            http,
            cookie_header,
            "/resource/UserHomefeedResource/get/",
            "/",
            Value::Object(retry_opts),
        )
        .await
        {
            if (200..300).contains(&retry_status) {
                let retry_page = PinterestJSONParser::parse_feed_page(&retry_data, "主页推荐");
                if !retry_page.pins.is_empty() {
                    page = retry_page;
                }
            }
        }
    }
    Ok(page)
}

async fn pinterest_fetch_search_inner(
    http: &Client,
    cookie_header: &str,
    query: &str,
    bookmark: Option<&str>,
    page_size: usize,
) -> Result<PinterestFeedPage, CoreError> {
    let trimmed = query.trim();
    if trimmed.is_empty() {
        return Ok(PinterestFeedPage {
            pins: Vec::new(),
            next_bookmark: None,
            has_more: false,
            source_description: "搜索".to_string(),
        });
    }
    let encoded: String = url::form_urlencoded::byte_serialize(trimmed.as_bytes()).collect();
    let source_url = format!("/search/pins/?q={encoded}");
    let mut options = Map::new();
    options.insert("query".to_string(), json!(trimmed));
    options.insert("scope".to_string(), json!("pins"));
    options.insert("rs".to_string(), json!("typed"));
    options.insert("auto_correction_disabled".to_string(), json!(false));
    options.insert("redux_normalize_feed".to_string(), json!(true));
    options.insert("page_size".to_string(), json!(page_size));
    if let Some(bm) = bookmark.filter(|s| !s.is_empty()) {
        options.insert("bookmarks".to_string(), json!([bm]));
    }

    let (status, data) = pinterest_fetch_resource_raw(
        http,
        cookie_header,
        "/resource/BaseSearchResource/get/",
        &source_url,
        Value::Object(options),
    )
    .await?;
    validate_pinterest_status(status)?;
    Ok(PinterestJSONParser::parse_feed_page(
        &data,
        &format!("搜索：{trimmed}"),
    ))
}

async fn pinterest_fetch_board_feed_inner(
    http: &Client,
    cookie_header: &str,
    board: &PinterestBoard,
    bookmark: Option<&str>,
    page_size: usize,
    filter_section_pins: bool,
) -> Result<PinterestFeedPage, CoreError> {
    let board_url = board.normalized_url_path();
    let mut options = Map::new();
    options.insert("board_id".to_string(), json!(board.id));
    options.insert("board_url".to_string(), json!(board_url));
    options.insert("currentFilter".to_string(), json!(-1));
    options.insert("field_set_key".to_string(), json!("react_grid_pin"));
    options.insert("filter_section_pins".to_string(), json!(filter_section_pins));
    options.insert("sort".to_string(), json!("default"));
    options.insert("layout".to_string(), json!("default"));
    options.insert("page_size".to_string(), json!(page_size));
    options.insert("redux_normalize_feed".to_string(), json!(true));
    if let Some(bm) = bookmark.filter(|s| !s.is_empty()) {
        options.insert("bookmarks".to_string(), json!([bm]));
    }

    let (status, data) = pinterest_fetch_resource_raw(
        http,
        cookie_header,
        "/resource/BoardFeedResource/get/",
        &board_url,
        Value::Object(options),
    )
    .await?;
    validate_pinterest_status(status)?;
    Ok(PinterestJSONParser::parse_feed_page(
        &data,
        &format!("画板：{}", board.name),
    ))
}

async fn pinterest_fetch_similar_inner(
    http: &Client,
    cookie_header: &str,
    pin: &PinterestPin,
    bookmark: Option<&str>,
    page_size: usize,
) -> Result<PinterestFeedPage, CoreError> {
    let safe_pin_id = sanitize_pinterest_path_segment(&pin.id).ok_or_else(|| {
        CoreError::InvalidPayload(format!("Invalid Pinterest pin ID: {}", pin.id))
    })?;
    let source_url = format!("/pin/{safe_pin_id}/");
    let mut primary_opts = Map::new();
    primary_opts.insert("pin_id".to_string(), json!(safe_pin_id));
    primary_opts.insert("context_pin_ids".to_string(), json!([]));
    primary_opts.insert("page_size".to_string(), json!(page_size));
    primary_opts.insert("search_query".to_string(), json!(""));
    primary_opts.insert("source".to_string(), json!("deep_link"));
    primary_opts.insert("top_level_source".to_string(), json!("deep_link"));
    primary_opts.insert("top_level_source_depth".to_string(), json!(1));
    primary_opts.insert("is_pdp".to_string(), json!(false));
    if let Some(bm) = bookmark.filter(|s| !s.is_empty()) {
        primary_opts.insert("bookmarks".to_string(), json!([bm]));
    }

    if let Ok((status, data)) = pinterest_fetch_resource_raw(
        http,
        cookie_header,
        "/resource/RelatedModulesResource/get/",
        &source_url,
        Value::Object(primary_opts),
    )
    .await
    {
        if status == 401 || status == 403 {
            validate_pinterest_status(status)?;
        }
        if (200..300).contains(&status) {
            let page = PinterestJSONParser::parse_feed_page(&data, "相似灵感");
            if !page.pins.is_empty() {
                return Ok(page);
            }
        }
    }

    let mut fallback_opts = Map::new();
    fallback_opts.insert("pin".to_string(), json!(pin.id));
    fallback_opts.insert("field_set_key".to_string(), json!("grid_item"));
    fallback_opts.insert("prepend".to_string(), json!(false));
    fallback_opts.insert("page_size".to_string(), json!(page_size));
    if let Some(bm) = bookmark.filter(|s| !s.is_empty()) {
        fallback_opts.insert("bookmarks".to_string(), json!([bm]));
    }

    if let Ok((status, data)) = pinterest_fetch_resource_raw(
        http,
        cookie_header,
        "/resource/RelatedPinFeedResource/get/",
        &source_url,
        Value::Object(fallback_opts),
    )
    .await
    {
        if status == 401 || status == 403 {
            validate_pinterest_status(status)?;
        }
        if (200..300).contains(&status) {
            let page = PinterestJSONParser::parse_feed_page(&data, "相似灵感");
            if !page.pins.is_empty() {
                return Ok(page);
            }
        }
    }

    if bookmark.is_none() {
        let seed_raw = if !pin.title.trim().is_empty() {
            pin.title.trim()
        } else {
            pin.board_name.as_deref().unwrap_or("").trim()
        };
        let seed: String = seed_raw.chars().take(48).collect();
        if !seed.is_empty() {
            if let Ok(search_page) =
                pinterest_fetch_search_inner(http, cookie_header, &seed, None, page_size).await
            {
                let filtered = search_page
                    .pins
                    .into_iter()
                    .filter(|p| p.id != pin.id)
                    .collect();
                return Ok(PinterestFeedPage {
                    pins: filtered,
                    next_bookmark: search_page.next_bookmark,
                    has_more: search_page.has_more,
                    source_description: "相似灵感".to_string(),
                });
            }
        }
    }

    Ok(PinterestFeedPage {
        pins: Vec::new(),
        next_bookmark: None,
        has_more: false,
        source_description: "相似灵感".to_string(),
    })
}

async fn pinterest_fetch_feed_inner(
    http: &Client,
    cookie_header: &str,
    source: &PinterestFeedSource,
    bookmark: Option<&str>,
    page_size: usize,
) -> Result<PinterestFeedPage, CoreError> {
    match source {
        PinterestFeedSource::Home => {
            pinterest_fetch_home_inner(http, cookie_header, bookmark, page_size).await
        }
        PinterestFeedSource::Search { query } => {
            pinterest_fetch_search_inner(http, cookie_header, query, bookmark, page_size).await
        }
        PinterestFeedSource::Board { board } => {
            pinterest_fetch_board_feed_inner(http, cookie_header, board, bookmark, page_size, true)
                .await
        }
        PinterestFeedSource::Similar { seed_pin } => {
            pinterest_fetch_similar_inner(http, cookie_header, seed_pin, bookmark, page_size).await
        }
    }
}

async fn pinterest_fetch_user_boards_inner(
    http: &Client,
    cookie_header: &str,
    username: &str,
) -> Result<Vec<PinterestBoard>, CoreError> {
    let Some(clean_user) = sanitize_pinterest_path_segment(username.trim().trim_start_matches('@'))
    else {
        return Ok(Vec::new());
    };
    let encoded_user: String =
        url::form_urlencoded::byte_serialize(clean_user.as_bytes()).collect();
    let mut all_boards: Vec<PinterestBoard> = Vec::new();
    let mut seen_ids: HashSet<String> = HashSet::new();
    let mut bookmark: Option<String> = None;

    for _ in 0..16 {
        let mut options = Map::new();
        options.insert("isPrefetch".to_string(), json!(false));
        options.insert("privacy_filter".to_string(), json!("all"));
        options.insert("sort".to_string(), json!("last_pinned_to"));
        options.insert("field_set_key".to_string(), json!("profile_grid_item"));
        options.insert("username".to_string(), json!(&clean_user));
        options.insert("page_size".to_string(), json!(50));
        options.insert("group_by".to_string(), json!("visibility"));
        options.insert("include_archived".to_string(), json!(false));
        options.insert("redux_normalize_feed".to_string(), json!(true));
        if let Some(ref bm) = bookmark {
            options.insert("bookmarks".to_string(), json!([bm]));
        }

        let (status, data) = pinterest_fetch_resource_raw(
            http,
            cookie_header,
            "/resource/BoardsResource/get/",
            &format!("/{encoded_user}/"),
            Value::Object(options),
        )
        .await?;
        validate_pinterest_status(status)?;

        let page = PinterestJSONParser::parse_boards_page(&data);
        for board in page.boards {
            if seen_ids.insert(board.id.clone()) {
                all_boards.push(board);
            }
        }
        match page.next_bookmark {
            Some(next) if page.has_more && Some(&next) != bookmark.as_ref() => {
                bookmark = Some(next);
            }
            _ => break,
        }
    }
    all_boards.sort_by_key(|b| std::cmp::Reverse(b.pin_count));
    Ok(all_boards)
}

async fn pinterest_fetch_all_board_pins_inner(
    http: &Client,
    cookie_header: &str,
    board: &PinterestBoard,
    max_pins: usize,
) -> Result<Vec<PinterestPin>, CoreError> {
    let mut collected = Vec::new();
    let mut seen_ids = HashSet::new();
    let mut bookmark: Option<String> = None;

    for _ in 0..24 {
        if collected.len() >= max_pins {
            break;
        }
        let page = pinterest_fetch_board_feed_inner(
            http,
            cookie_header,
            board,
            bookmark.as_deref(),
            50,
            false,
        )
        .await?;
        let mut added = 0usize;
        for mut pin in page.pins {
            if collected.len() >= max_pins {
                break;
            }
            if seen_ids.insert(pin.id.clone()) {
                if pin
                    .board_name
                    .as_deref()
                    .map(str::trim)
                    .unwrap_or("")
                    .is_empty()
                {
                    pin.board_name = Some(board.name.clone());
                }
                if pin.board_id.is_none() {
                    pin.board_id = Some(board.id.clone());
                }
                collected.push(pin);
                added += 1;
            }
        }
        if !page.has_more || added == 0 {
            break;
        }
        match page.next_bookmark {
            Some(next) if Some(&next) != bookmark.as_ref() => bookmark = Some(next),
            _ => break,
        }
    }
    Ok(collected)
}

async fn pinterest_fetch_pin_detail_inner(
    http: &Client,
    cookie_header: &str,
    pin: &PinterestPin,
) -> Result<PinterestPinDetailResult, CoreError> {
    let safe_pin_id = sanitize_pinterest_path_segment(&pin.id).ok_or_else(|| {
        CoreError::InvalidPayload(format!("Invalid Pinterest pin ID: {}", pin.id))
    })?;
    let mut detailed = pin.clone();
    if let Ok((status, data)) = pinterest_fetch_resource_raw(
        http,
        cookie_header,
        "/resource/PinResource/get/",
        &format!("/pin/{safe_pin_id}/"),
        json!({ "id": safe_pin_id, "field_set_key": "detailed" }),
    )
    .await
    {
        if (200..300).contains(&status) {
            if let Some(parsed) = PinterestJSONParser::parse_single_pin(&data) {
                detailed = parsed;
            }
        }
    }

    let similar_page = pinterest_fetch_similar_inner(http, cookie_header, &detailed, None, 28).await?;
    let filtered = similar_page
        .pins
        .into_iter()
        .filter(|p| p.id != detailed.id)
        .collect();
    Ok(PinterestPinDetailResult {
        pin: detailed,
        similar_pins: filtered,
        next_similar_bookmark: similar_page.next_bookmark,
        has_more_similar: similar_page.has_more,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashMap;
    use std::sync::Mutex;

    #[derive(Default)]
    struct TestVault {
        map: Mutex<HashMap<String, String>>,
    }

    impl AndroidSecretVault for TestVault {
        fn get_secret(&self, key: String) -> Option<String> {
            self.map.lock().ok()?.get(&key).cloned()
        }

        fn set_secret(&self, key: String, value: String) -> Result<(), CharkleFfiError> {
            self.map
                .lock()
                .map_err(|_| CharkleFfiError::Internal {
                    detail: "lock poisoned".to_string(),
                })?
                .insert(key, value);
            Ok(())
        }

        fn delete_secret(&self, key: String) -> Result<(), CharkleFfiError> {
            self.map
                .lock()
                .map_err(|_| CharkleFfiError::Internal {
                    detail: "lock poisoned".to_string(),
                })?
                .remove(&key);
            Ok(())
        }
    }

    #[tokio::test]
    async fn roundtrip_sample_library_and_folder_crud() {
        let dir = tempfile::tempdir().expect("tempdir");
        let handle = AndroidEngineHandle::open(
            dir.path().to_string_lossy().into_owned(),
            Box::new(TestVault::default()),
            None,
        )
        .expect("open handle");

        let seeded = handle
            .seed_sample_library_if_empty()
            .await
            .expect("seed samples");
        assert!(seeded, "fresh library should seed sample artworks");

        let assets_json = handle
            .fetch_assets_json("{}".to_string())
            .expect("fetch assets");
        let assets: Vec<AssetRecord> =
            serde_json::from_str(&assets_json).expect("decode assets JSON");
        assert!(!assets.is_empty(), "seeded library must contain assets");

        let first = &assets[0];
        let thumb = handle
            .cached_thumbnail_path(first.id.to_string(), false)
            .expect("thumbnail lookup");
        assert!(thumb.is_some(), "seeded asset must have cached thumbnail");

        let folder_json = handle
            .create_folder_json("色彩灵感".to_string(), None)
            .expect("create folder");
        assert!(folder_json.contains("色彩灵感"));

        let summary = handle
            .save_google_oauth_client_id(
                "123456789-abc.apps.googleusercontent.com".to_string(),
                None,
            )
            .await
            .expect("save oauth id");
        assert_eq!(
            summary.reversed_client_id_scheme,
            "com.googleusercontent.apps.123456789-abc"
        );

        // Moodboard creation + editorial solver + Figma bridge bundle export roundtrip
        let board_json = handle
            .create_board_json("建筑光影情绪板".to_string())
            .expect("create board");
        let mut board: MoodboardDocument =
            serde_json::from_str(&board_json).expect("decode board");
        board.nodes.push(charkle_core::models::moodboard::BoardNode {
            id: Uuid::new_v4(),
            kind: charkle_core::models::moodboard::BoardNodeKind::AssetRef {
                asset_id: first.id,
                crop: None,
                weight: 2,
                autoplay_loop: false,
            },
            frame: charkle_core::models::moodboard::BoardRect::new(40.0, 40.0, 260.0, 320.0),
            z_index: 1,
            rotation_degrees: 0.0,
            flip_horizontal: false,
            flip_vertical: false,
            is_locked: false,
            editorial_order: 0,
            updated_at: Utc::now(),
        });
        let saved_board_json = handle
            .save_board_json(serde_json::to_string(&board).expect("encode board"))
            .expect("save board");
        let editorial_json = handle
            .solve_editorial_layout_json(saved_board_json, 720.0)
            .expect("solve editorial layout");
        assert!(editorial_json.contains("orderedNodeIds"));

        let export_dir = tempfile::tempdir().expect("export tempdir");
        let bridge_path = export_dir.path().join("test.charkleboard");
        let bridge_report = handle
            .export_board_figma_bridge_json(
                board.id.to_string(),
                "{}".to_string(),
                bridge_path.to_string_lossy().into_owned(),
            )
            .expect("export figma bridge");
        assert!(bridge_report.contains("\"imageCount\":1"));
        assert!(bridge_path.exists());

        // Reject export path inside library data_dir
        let unsafe_inside = dir.path().join("escape.charkleboard");
        assert!(handle
            .export_board_figma_bridge_json(
                board.id.to_string(),
                "{}".to_string(),
                unsafe_inside.to_string_lossy().into_owned(),
            )
            .is_err());

        // Batch media path resolution accepts lowercase UUIDs and returns uppercase canonical keys
        let lower_id = first.id.to_string().to_lowercase();
        let batch_json = handle
            .resolve_media_paths_json(vec![lower_id, "not-a-uuid".to_string()])
            .expect("resolve media paths batch");
        let parsed_paths: HashMap<String, Value> =
            serde_json::from_str(&batch_json).expect("decode paths map");
        let upper_key = format_swift_uuid(&first.id);
        assert!(parsed_paths.contains_key(&upper_key));
        assert!(parsed_paths[&upper_key]["gridThumbPath"].as_str().is_some());

        // Pinterest spatial layout computation
        let sample_pin = PinterestPin {
            id: "123456789".to_string(),
            title: "Architectural Concrete".to_string(),
            description: String::new(),
            author_name: None,
            author_username: None,
            author_avatar_url: None,
            board_name: None,
            board_id: None,
            domain: None,
            link_url: None,
            pin_page_url: "https://www.pinterest.com/pin/123456789/".to_string(),
            original_url: Some("https://i.pinimg.com/originals/aa/bb/cc/test.jpg".to_string()),
            preview_url: None,
            thumbnail_url: None,
            video_url: None,
            pixel_width: 800,
            pixel_height: 1200,
            dominant_color_hex: Some("#D4A373".to_string()),
        };
        let spatial_json = handle
            .pinterest_compute_spatial_layout_json(
                serde_json::to_string(&vec![sample_pin]).expect("encode pins"),
                224.0,
                16.0,
            )
            .expect("compute spatial layout");
        assert!(spatial_json.contains("123456789"));
    }

    #[tokio::test]
    async fn smart_folder_assets_filtering_and_security_guards() {
        let dir = tempfile::tempdir().expect("tempdir");
        let handle = AndroidEngineHandle::open(
            dir.path().to_string_lossy().into_owned(),
            Box::new(TestVault::default()),
            None,
        )
        .expect("open handle");

        handle.seed_sample_library_if_empty().await.expect("seed");
        let all_assets: Vec<AssetRecord> =
            serde_json::from_str(&handle.fetch_assets_json("{}".to_string()).expect("assets"))
                .expect("decode assets");
        assert!(!all_assets.is_empty());

        // Tag first asset and create a matching smart folder
        let target_asset = &all_assets[0];
        let patch = json!({
            "assetIDs": [format_swift_uuid(&target_asset.id)],
            "addTags": ["smart-audit-tag"],
            "rating": 5
        });
        handle
            .update_assets_json(patch.to_string())
            .expect("tag asset");

        let sf = charkle_core::models::core::SmartFolderRecord::new(
            "五星精选",
            charkle_core::models::core::SmartFolderRule {
                tags: vec!["smart-audit-tag".to_string()],
                min_rating: 5,
                ..Default::default()
            },
        );
        let sf_id = sf.id;
        handle.engine.save_smart_folder(sf).expect("save smart folder");

        let matched_json = handle
            .fetch_smart_folder_assets_json(sf_id.to_string().to_lowercase(), "{}".to_string())
            .expect("fetch smart folder assets");
        let matched: Vec<AssetRecord> =
            serde_json::from_str(&matched_json).expect("decode matched");
        assert_eq!(matched.len(), 1);
        assert_eq!(matched[0].id, target_asset.id);

        // Export path safety validation
        let ext_dir = tempfile::tempdir().expect("ext dir");
        assert!(validate_charkleboard_export_path("", dir.path()).is_err());
        assert!(validate_charkleboard_export_path("relative.charkleboard", dir.path()).is_err());
        assert!(validate_charkleboard_export_path(
            &format!("{}/../escape.charkleboard", ext_dir.path().display()),
            dir.path()
        )
        .is_err());
        assert!(validate_charkleboard_export_path(
            &ext_dir.path().join("bad.zip").to_string_lossy(),
            dir.path()
        )
        .is_err());
        assert!(validate_charkleboard_export_path(
            &ext_dir.path().join("ok.charkleboard").to_string_lossy(),
            dir.path()
        )
        .is_ok());

        // Pinterest cookie/CSRF extraction & header injection protection
        assert_eq!(
            extract_cookie_value(
                "_auth=1; CSRFTOKEN=\"abc_123\"\r\nX-Injected: bad; _pinterest_sess=xyz",
                "csrftoken"
            ),
            Some("abc_123".to_string())
        );
        assert_eq!(
            extract_cookie_value("csrftoken=bad value with spaces", "csrftoken"),
            None
        );
        assert!(sanitize_pinterest_path_segment("123456789").is_some());
        assert!(sanitize_pinterest_path_segment("../etc/passwd").is_none());
        assert!(sanitize_pinterest_path_segment("123?foo=bar").is_none());

        // OAuth input validation
        assert!(handle
            .save_google_oauth_client_id("   ".to_string(), None)
            .await
            .is_err());
        assert!(handle
            .prepare_google_pkce_auth("not a uri".to_string(), true)
            .await
            .is_err());
        assert!(handle
            .complete_google_pkce_auth("".to_string(), "v".to_string(), "charkle-android://oauth/callback".to_string())
            .await
            .is_err());
    }
}
