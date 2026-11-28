//! M5 Settings, Hybrid Cloud AI, TypeSafe Jev, External Agent, Storage Migration & Diagnostics IPC commands.

use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::sync::Arc;

use charkle_core::agent::{ExternalAgentConfigStore, READ_TOOL_NAMES, WRITE_TOOL_NAMES};
use charkle_core::bridge::ExtensionBridgeStatus;
use charkle_core::intelligence::{
    build_cloud_ai_provider, test_cloud_ai_connection, AIConnectionTestResult, ChatGPTSignInClient,
    CloudAIProvider, CloudAIUsageCategory, CloudAIUsageSummary, FolderOptionInput,
    TypeSafeSystemOneClient, VisualGroundingEngine, AI_API_KEY_SECRET_KEY,
    TYPESAFE_API_KEY_SECRET_KEY,
};
use charkle_core::models::agent::{
    ExternalAgentAccessLevel, ExternalAgentConfig, ExternalAgentToken,
};
use charkle_core::models::core::{
    AssetRecord, FilterCriteria, FolderRecord, FolderSuggestion, MediaKind,
};
use charkle_core::models::media::{
    AIProviderConfig, ChatGPTAccountSession, CloudAIProviderKind, InboxTriageRecommendation,
    TypeSafeExperimentalConfig, TypeSafeModelInfo, VisualRegionSource,
};
use charkle_core::models::sync::{
    DriveSyncConfig, GDirectEnvironmentSnapshot, StorageMigrationReport,
};
use charkle_core::sync::gdirect::{
    install_gdirect_cli_windows, probe_gdirect_environment, GDirectInstallResult,
};
use charkle_platform_win::mount::{detect_gdirect_binary, inspect_mount};
use charkle_platform_win::{probe_ocr_diagnostics, OcrDiagnostics};
use serde::{Deserialize, Serialize};
use serde_json::json;
use tauri::{Emitter, State};
use tokio::sync::Semaphore;
use uuid::Uuid;

use super::media::open_validated_http_url;
use super::{parse_uuid, AppState, IpcError, IpcResult};

const AI_CONFIG_FILE: &str = "ai-provider.json";
const TYPESAFE_CONFIG_FILE: &str = "typesafe-config.json";

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct AIProviderStateDto {
    pub config: AIProviderConfig,
    pub has_api_key: bool,
    pub chatgpt_session: ChatGPTAccountSession,
    pub usage: CloudAIUsageSummary,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct TypeSafeStateDto {
    pub config: TypeSafeExperimentalConfig,
    pub has_api_key: bool,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct TypeSafeTestResultDto {
    pub ok: bool,
    pub message: String,
    pub models: Vec<TypeSafeModelInfo>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ExternalAgentStateDto {
    pub config: ExternalAgentConfig,
    pub cli_binary_path: String,
    pub library_dir: String,
    pub mcp_config_json: String,
    pub http_mcp_endpoint_url: String,
    pub http_mcp_running: bool,
    pub http_mcp_config_json: String,
    pub read_tool_count: usize,
    pub write_tool_count: usize,
    pub resource_count: usize,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct MintExternalAgentTokenDto {
    pub state: ExternalAgentStateDto,
    pub token: ExternalAgentToken,
    pub plaintext: String,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ExternalAgentSelfCheckDto {
    pub ok: bool,
    pub summary: String,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct RebuildIndexResultDto {
    pub processed: usize,
    pub total: usize,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SystemDiagnosticsDto {
    pub app_version: String,
    pub schema_version: i32,
    pub data_dir: String,
    pub database_path: String,
    pub gdirect: GDirectEnvironmentSnapshot,
    pub ocr: OcrDiagnostics,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SaveAIProviderPayload {
    pub config: AIProviderConfig,
    #[serde(default)]
    pub api_key: Option<String>,
    #[serde(default)]
    pub clear_api_key: bool,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SaveTypeSafePayload {
    pub config: TypeSafeExperimentalConfig,
    #[serde(default)]
    pub api_key: Option<String>,
    #[serde(default)]
    pub clear_api_key: bool,
}

fn load_json_or_default<T: serde::de::DeserializeOwned + Default>(path: &Path) -> T {
    std::fs::read(path)
        .ok()
        .and_then(|bytes| serde_json::from_slice::<T>(&bytes).ok())
        .unwrap_or_default()
}

fn save_json_atomic<T: Serialize>(path: &Path, value: &T) -> IpcResult<()> {
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent).map_err(|e| IpcError {
            code: "IO_ERROR",
            message: e.to_string(),
        })?;
    }
    let bytes = serde_json::to_vec_pretty(value).map_err(|e| IpcError {
        code: "SERIALIZE_ERROR",
        message: e.to_string(),
    })?;
    let tmp = path.with_extension("json.tmp");
    std::fs::write(&tmp, bytes).map_err(|e| IpcError {
        code: "IO_ERROR",
        message: e.to_string(),
    })?;
    std::fs::rename(&tmp, path).map_err(|e| IpcError {
        code: "IO_ERROR",
        message: e.to_string(),
    })?;
    Ok(())
}

async fn read_vault_utf8(state: &AppState, key: &str) -> Option<String> {
    state
        .engine
        .vault()
        .get_secret(key)
        .await
        .ok()
        .flatten()
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
}

fn resolve_cli_binary_path() -> String {
    if let Ok(exe) = std::env::current_exe() {
        if let Some(dir) = exe.parent() {
            for candidate in [
                dir.join("charkle-cli.exe"),
                dir.join("charkle-cli-x86_64-pc-windows-msvc.exe"),
                dir.join("binaries").join("charkle-cli.exe"),
            ] {
                if candidate.exists() {
                    return candidate.display().to_string();
                }
            }
            return dir.join("charkle-cli.exe").display().to_string();
        }
    }
    "charkle-cli.exe".to_string()
}

async fn build_ai_provider_state(state: &AppState) -> AIProviderStateDto {
    let config: AIProviderConfig = load_json_or_default(&state.data_dir.join(AI_CONFIG_FILE));
    let has_api_key = read_vault_utf8(state, AI_API_KEY_SECRET_KEY)
        .await
        .is_some();
    let chatgpt = ChatGPTSignInClient::new(Arc::clone(state.engine.vault()));
    AIProviderStateDto {
        config,
        has_api_key,
        chatgpt_session: chatgpt.current_session().await,
        usage: state.usage_store.snapshot(),
    }
}

#[tauri::command]
pub async fn get_ai_provider_state(state: State<'_, AppState>) -> IpcResult<AIProviderStateDto> {
    Ok(build_ai_provider_state(&state).await)
}

#[tauri::command]
pub async fn save_ai_provider_config(
    state: State<'_, AppState>,
    payload: SaveAIProviderPayload,
) -> IpcResult<AIProviderStateDto> {
    save_json_atomic(&state.data_dir.join(AI_CONFIG_FILE), &payload.config)?;
    if payload.clear_api_key {
        state
            .engine
            .vault()
            .delete_secret(AI_API_KEY_SECRET_KEY)
            .await
            .map_err(|message| IpcError {
                code: "VAULT_ERROR",
                message,
            })?;
    } else if let Some(key) = payload.api_key.as_deref().map(str::trim) {
        if !key.is_empty() {
            state
                .engine
                .vault()
                .set_secret(AI_API_KEY_SECRET_KEY, key)
                .await
                .map_err(|message| IpcError {
                    code: "VAULT_ERROR",
                    message,
                })?;
        }
    }
    Ok(build_ai_provider_state(&state).await)
}

#[tauri::command]
pub async fn test_ai_provider_connection(
    state: State<'_, AppState>,
) -> IpcResult<AIConnectionTestResult> {
    let config: AIProviderConfig = load_json_or_default(&state.data_dir.join(AI_CONFIG_FILE));
    let secret = if config.provider
        == charkle_core::models::media::CloudAIProviderKind::ChatGptSubscription
    {
        let client = ChatGPTSignInClient::new(Arc::clone(state.engine.vault()));
        client.valid_access_token().await.ok()
    } else {
        read_vault_utf8(&state, AI_API_KEY_SECRET_KEY).await
    };
    Ok(test_cloud_ai_connection(&config, secret, Arc::clone(&state.usage_store)).await)
}

#[tauri::command]
pub fn reset_ai_usage(
    state: State<'_, AppState>,
    category: Option<CloudAIUsageCategory>,
) -> CloudAIUsageSummary {
    state.usage_store.reset(category)
}

#[tauri::command]
pub async fn sign_in_with_chatgpt(
    state: State<'_, AppState>,
    reconsent: Option<bool>,
    switch_account: Option<bool>,
) -> IpcResult<AIProviderStateDto> {
    let client = ChatGPTSignInClient::new(Arc::clone(state.engine.vault()));
    let session = client
        .sign_in_interactive(
            reconsent.unwrap_or(false),
            switch_account.unwrap_or(false),
            |url| async move {
                let _ = open_validated_http_url(url.as_str());
            },
        )
        .await
        .map_err(IpcError::from)?;

    if session.sharing_enabled {
        let mut config: AIProviderConfig =
            load_json_or_default(&state.data_dir.join(AI_CONFIG_FILE));
        config.provider = CloudAIProviderKind::ChatGptSubscription;
        if config.chat_model.trim().is_empty()
            || config.chat_model.starts_with("gemini")
            || config.chat_model.starts_with("claude")
        {
            config.chat_model = "gpt-5.4-mini".to_string();
        }
        if config.base_url.trim().is_empty()
            || config
                .base_url
                .contains("generativelanguage.googleapis.com")
        {
            config.base_url = "https://api.openai.com/v1".to_string();
        }
        let _ = save_json_atomic(&state.data_dir.join(AI_CONFIG_FILE), &config);
    }

    Ok(build_ai_provider_state(&state).await)
}

#[tauri::command]
pub async fn disconnect_chatgpt_account(
    state: State<'_, AppState>,
) -> IpcResult<ChatGPTAccountSession> {
    let client = ChatGPTSignInClient::new(Arc::clone(state.engine.vault()));
    client.disconnect().await.map_err(IpcError::from)?;
    Ok(client.current_session().await)
}

async fn build_typesafe_state(state: &AppState) -> TypeSafeStateDto {
    let config: TypeSafeExperimentalConfig =
        load_json_or_default(&state.data_dir.join(TYPESAFE_CONFIG_FILE));
    let has_api_key = read_vault_utf8(state, TYPESAFE_API_KEY_SECRET_KEY)
        .await
        .is_some();
    TypeSafeStateDto {
        config,
        has_api_key,
    }
}

#[tauri::command]
pub async fn get_typesafe_state(state: State<'_, AppState>) -> IpcResult<TypeSafeStateDto> {
    Ok(build_typesafe_state(&state).await)
}

#[tauri::command]
pub async fn save_typesafe_config(
    state: State<'_, AppState>,
    payload: SaveTypeSafePayload,
) -> IpcResult<TypeSafeStateDto> {
    let sanitized = payload.config.sanitized();
    save_json_atomic(&state.data_dir.join(TYPESAFE_CONFIG_FILE), &sanitized)?;
    if payload.clear_api_key {
        state
            .engine
            .vault()
            .delete_secret(TYPESAFE_API_KEY_SECRET_KEY)
            .await
            .map_err(|message| IpcError {
                code: "VAULT_ERROR",
                message,
            })?;
    } else if let Some(key) = payload.api_key.as_deref().map(str::trim) {
        if !key.is_empty() {
            state
                .engine
                .vault()
                .set_secret(TYPESAFE_API_KEY_SECRET_KEY, key)
                .await
                .map_err(|message| IpcError {
                    code: "VAULT_ERROR",
                    message,
                })?;
        }
    }
    Ok(build_typesafe_state(&state).await)
}

/// Runs Hybrid Cloud AI + TypeSafe System One (`Jev`) closed-set auto-tagging using the
/// stored desktop configs and Windows Credential Manager secrets.
pub(crate) async fn enrich_assets_with_stored_configs(
    engine: Arc<charkle_core::engine::LiveCharkleEngine>,
    data_dir: PathBuf,
    usage_store: Arc<charkle_core::intelligence::CloudAIUsageStore>,
    asset_ids: Vec<Uuid>,
) -> charkle_core::error::CoreResult<Vec<AssetRecord>> {
    if asset_ids.is_empty() {
        return Ok(Vec::new());
    }
    let ai_config: AIProviderConfig = load_json_or_default(&data_dir.join(AI_CONFIG_FILE));
    let ts_config: TypeSafeExperimentalConfig =
        load_json_or_default::<TypeSafeExperimentalConfig>(&data_dir.join(TYPESAFE_CONFIG_FILE))
            .sanitized();

    let ai_secret = if ai_config.provider == CloudAIProviderKind::ChatGptSubscription {
        let client = ChatGPTSignInClient::new(Arc::clone(engine.vault()));
        client.valid_access_token().await.ok()
    } else if ai_config.provider != CloudAIProviderKind::Disabled {
        engine
            .vault()
            .get_secret(AI_API_KEY_SECRET_KEY)
            .await
            .ok()
            .flatten()
            .map(|s| s.trim().to_string())
            .filter(|s| !s.is_empty())
    } else {
        None
    };

    let ts_key = engine
        .vault()
        .get_secret(TYPESAFE_API_KEY_SECRET_KEY)
        .await
        .ok()
        .flatten()
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty());

    engine
        .enrich_assets_with_ai(
            &asset_ids,
            &ai_config,
            ai_secret,
            &ts_config,
            ts_key,
            usage_store,
        )
        .await
}

/// Background auto-analysis trigger on newly ingested assets when `autoAnalyzeOnImport` is enabled
/// (unlocked for both Cloud AI providers AND pure-Jev closed-set tagging when VLM is disabled).
pub(crate) fn spawn_auto_analyze_if_enabled(state: &AppState, assets: &[AssetRecord]) {
    if assets.is_empty() {
        return;
    }
    let ai_config: AIProviderConfig = load_json_or_default(&state.data_dir.join(AI_CONFIG_FILE));
    if !ai_config.auto_analyze_on_import {
        return;
    }
    let ts_config: TypeSafeExperimentalConfig =
        load_json_or_default(&state.data_dir.join(TYPESAFE_CONFIG_FILE));
    let might_run = ai_config.provider != CloudAIProviderKind::Disabled
        || (ts_config.enabled && ts_config.enable_closed_set_tagging);
    if !might_run {
        return;
    }

    let ids: Vec<Uuid> = assets
        .iter()
        .filter(|a| !a.is_trashed)
        .map(|a| a.id)
        .collect();
    if ids.is_empty() {
        return;
    }
    let engine = Arc::clone(&state.engine);
    let data_dir = state.data_dir.clone();
    let usage_store = Arc::clone(&state.usage_store);
    tauri::async_runtime::spawn(async move {
        if let Err(err) =
            enrich_assets_with_stored_configs(engine, data_dir, usage_store, ids).await
        {
            tracing::warn!(%err, "Background auto-analyze on import skipped/failed");
        }
    });
}

#[tauri::command]
pub async fn enrich_assets(
    state: State<'_, AppState>,
    asset_ids: Vec<String>,
) -> IpcResult<Vec<AssetRecord>> {
    let mut uuids = Vec::with_capacity(asset_ids.len());
    for raw in asset_ids {
        uuids.push(parse_uuid(&raw)?);
    }
    enrich_assets_with_stored_configs(
        Arc::clone(&state.engine),
        state.data_dir.clone(),
        Arc::clone(&state.usage_store),
        uuids,
    )
    .await
    .map_err(IpcError::from)
}

#[tauri::command]
pub async fn test_typesafe_connection(
    state: State<'_, AppState>,
) -> IpcResult<TypeSafeTestResultDto> {
    let config: TypeSafeExperimentalConfig =
        load_json_or_default(&state.data_dir.join(TYPESAFE_CONFIG_FILE));
    let Some(key) = read_vault_utf8(&state, TYPESAFE_API_KEY_SECRET_KEY).await else {
        return Ok(TypeSafeTestResultDto {
            ok: false,
            message: "尚未配置 TypeSafe API 密钥（离线显著性兜底仍可用）。".to_string(),
            models: Vec::new(),
        });
    };
    let client = match TypeSafeSystemOneClient::new(
        &config.base_url,
        &key,
        Arc::clone(&state.usage_store),
    ) {
        Ok(c) => c,
        Err(err) => {
            return Ok(TypeSafeTestResultDto {
                ok: false,
                message: err.to_string(),
                models: Vec::new(),
            });
        }
    };
    match client.list_models().await {
        Ok(models) => Ok(TypeSafeTestResultDto {
            ok: true,
            message: format!("已连接 TypeSafe System One，可用模型 {} 个。", models.len()),
            models,
        }),
        Err(err) => Ok(TypeSafeTestResultDto {
            ok: false,
            message: err.to_string(),
            models: Vec::new(),
        }),
    }
}

fn build_folder_triage_options(
    folders: &[FolderRecord],
    all_assets: &[AssetRecord],
) -> Vec<FolderOptionInput> {
    let by_id: HashMap<Uuid, &FolderRecord> = folders.iter().map(|f| (f.id, f)).collect();
    let mut tags_by_folder: HashMap<Uuid, HashMap<String, usize>> = HashMap::new();
    let mut titles_by_folder: HashMap<Uuid, Vec<String>> = HashMap::new();

    for asset in all_assets {
        let Some(fid) = asset.folder_id else {
            continue;
        };
        let entry = tags_by_folder.entry(fid).or_default();
        for tag in asset.tags.iter().chain(asset.suggested_tags.iter()) {
            let trimmed = tag.trim();
            if !trimmed.is_empty() {
                *entry.entry(trimmed.to_string()).or_insert(0) += 1;
            }
        }
        let titles = titles_by_folder.entry(fid).or_default();
        if titles.len() < 4 && !asset.title.trim().is_empty() {
            titles.push(asset.title.trim().chars().take(48).collect());
        }
    }

    folders
        .iter()
        .map(|folder| {
            let mut parts = Vec::new();
            let mut visited = HashSet::new();
            let mut cur = Some(folder);
            while let Some(node) = cur {
                if !visited.insert(node.id) {
                    break;
                }
                parts.push(node.name.as_str());
                cur = node.parent_id.and_then(|pid| by_id.get(&pid).copied());
            }
            parts.reverse();
            let display_path = parts.join(" / ");

            let mut tag_vec: Vec<(String, usize)> = tags_by_folder
                .remove(&folder.id)
                .unwrap_or_default()
                .into_iter()
                .collect();
            tag_vec.sort_by(|a, b| b.1.cmp(&a.1).then_with(|| a.0.cmp(&b.0)));
            let sample_tags = tag_vec.into_iter().take(6).map(|(t, _)| t).collect();
            let sample_titles = titles_by_folder.remove(&folder.id).unwrap_or_default();

            FolderOptionInput {
                id: folder.id,
                name: folder.name.clone(),
                display_path,
                sample_tags,
                sample_titles,
            }
        })
        .collect()
}

fn offline_triage_recommendation(
    asset: &AssetRecord,
    suggestion: Option<&FolderSuggestion>,
) -> InboxTriageRecommendation {
    if let Some(sug) = suggestion {
        InboxTriageRecommendation {
            asset_id: asset.id,
            asset_title: asset.title.clone(),
            recommended_folder_id: Some(sug.folder_id),
            recommended_folder_name: Some(sug.folder_name.clone()),
            confidence: sug.confidence,
            fit_probability: sug.confidence,
            reason: sug.reason.clone(),
            source: VisualRegionSource::AppleVisionSaliency,
        }
    } else {
        InboxTriageRecommendation {
            asset_id: asset.id,
            asset_title: asset.title.clone(),
            recommended_folder_id: None,
            recommended_folder_name: None,
            confidence: 0.0,
            fit_probability: 0.0,
            reason: "离线未匹配到明确目录，建议暂留收件箱".to_string(),
            source: VisualRegionSource::AppleVisionSaliency,
        }
    }
}

fn sort_triage_recommendations(recs: &mut [InboxTriageRecommendation]) {
    recs.sort_by(|a, b| {
        let a_has = a.recommended_folder_id.is_some();
        let b_has = b.recommended_folder_id.is_some();
        b_has
            .cmp(&a_has)
            .then_with(|| {
                if (a.confidence - b.confidence).abs() > 0.005 {
                    b.confidence
                        .partial_cmp(&a.confidence)
                        .unwrap_or(std::cmp::Ordering::Equal)
                } else {
                    b.fit_probability
                        .partial_cmp(&a.fit_probability)
                        .unwrap_or(std::cmp::Ordering::Equal)
                }
            })
            .then_with(|| a.asset_title.cmp(&b.asset_title))
    });
}

#[tauri::command]
pub async fn run_inbox_smart_triage(
    state: State<'_, AppState>,
    asset_ids: Option<Vec<String>>,
    max_count: Option<usize>,
) -> IpcResult<Vec<InboxTriageRecommendation>> {
    let folders = state.engine.fetch_folders().map_err(IpcError::from)?;
    if folders.is_empty() {
        return Err(IpcError {
            code: "NO_FOLDERS",
            message: "请先在左侧栏创建至少一个目标文件夹，再使用智能分拣。".to_string(),
        });
    }

    let limit = max_count.unwrap_or(24).clamp(1, 64);
    let targets: Vec<AssetRecord> = match asset_ids {
        Some(ids) if !ids.is_empty() => {
            let mut loaded = Vec::with_capacity(ids.len().min(limit));
            for raw in ids.into_iter().take(limit) {
                let uuid = parse_uuid(&raw)?;
                if let Some(asset) = state.engine.fetch_asset(uuid).map_err(IpcError::from)? {
                    if !asset.is_trashed {
                        loaded.push(asset);
                    }
                }
            }
            loaded
        }
        _ => state
            .engine
            .fetch_assets(&FilterCriteria {
                only_inbox: true,
                ..Default::default()
            })
            .map_err(IpcError::from)?
            .into_iter()
            .take(limit)
            .collect(),
    };
    if targets.is_empty() {
        return Ok(Vec::new());
    }

    // Compute local multi-signal visual/palette/tag suggestions once (used both offline and as error fallback)
    let offline_map: HashMap<Uuid, Option<FolderSuggestion>> = state
        .engine
        .suggest_folders_for_assets(&targets)
        .map_err(IpcError::from)?
        .into_iter()
        .collect();
    let folder_name_by_id: HashMap<Uuid, String> =
        folders.iter().map(|f| (f.id, f.name.clone())).collect();

    // Tier 1: TypeSafe System One (Jev) closed-set Choice + companion Noul
    let ts_config: TypeSafeExperimentalConfig =
        load_json_or_default(&state.data_dir.join(TYPESAFE_CONFIG_FILE));
    let ts_key = read_vault_utf8(&state, TYPESAFE_API_KEY_SECRET_KEY).await;
    if ts_config.enabled && ts_config.enable_inbox_smart_triage {
        if let Some(key) = ts_key {
            let all_assets = state
                .engine
                .fetch_assets(&FilterCriteria {
                    include_trashed: false,
                    ..Default::default()
                })
                .unwrap_or_default();
            let options = Arc::new(build_folder_triage_options(&folders, &all_assets));
            let grounding = Arc::new(VisualGroundingEngine::new(Arc::clone(&state.usage_store)));
            let sem = Arc::new(Semaphore::new(4));
            let mut handles = Vec::with_capacity(targets.len());

            for asset in targets {
                let jpeg = state.engine.prepare_visual_grounding_jpeg(&asset, 384);
                let offline_fb = offline_triage_recommendation(
                    &asset,
                    offline_map.get(&asset.id).and_then(|o| o.as_ref()),
                );
                let grounding = Arc::clone(&grounding);
                let options = Arc::clone(&options);
                let sem = Arc::clone(&sem);
                let cfg = ts_config.clone();
                let key = key.clone();
                let folder_names = folder_name_by_id.clone();

                handles.push(tokio::spawn(async move {
                    let _permit = sem.acquire_owned().await;
                    let tags: Vec<String> = asset
                        .tags
                        .iter()
                        .chain(asset.suggested_tags.iter())
                        .cloned()
                        .collect();
                    let notes = format!(
                        "{} {}",
                        asset.notes,
                        asset.ai_description.as_deref().unwrap_or("")
                    );
                    match grounding
                        .classify_into_folders(
                            &asset.title,
                            &tags,
                            &notes,
                            jpeg.as_deref(),
                            &options,
                            &cfg,
                            &key,
                        )
                        .await
                    {
                        Ok(res) => InboxTriageRecommendation {
                            asset_id: asset.id,
                            asset_title: asset.title,
                            recommended_folder_id: res.folder_id,
                            recommended_folder_name: res
                                .folder_id
                                .and_then(|fid| folder_names.get(&fid).cloned()),
                            confidence: res.confidence,
                            fit_probability: res.fit_probability,
                            reason: res.reason,
                            source: res.source,
                        },
                        Err(_) => offline_fb,
                    }
                }));
            }

            let mut recs = Vec::with_capacity(handles.len());
            for handle in handles {
                if let Ok(rec) = handle.await {
                    recs.push(rec);
                }
            }
            sort_triage_recommendations(&mut recs);
            return Ok(recs);
        }
    }

    // Tier 2: Configured Cloud AI provider (Gemini, OpenAI Compatible, Anthropic, ChatGPT Subscription)
    let ai_config: AIProviderConfig = load_json_or_default(&state.data_dir.join(AI_CONFIG_FILE));
    if ai_config.provider != CloudAIProviderKind::Disabled {
        let secret = if ai_config.provider == CloudAIProviderKind::ChatGptSubscription {
            let client = ChatGPTSignInClient::new(Arc::clone(state.engine.vault()));
            client.valid_access_token().await.ok()
        } else {
            read_vault_utf8(&state, AI_API_KEY_SECRET_KEY).await
        };
        if let Ok(Some(provider)) =
            build_cloud_ai_provider(&ai_config, secret, Arc::clone(&state.usage_store))
        {
            let provider: Arc<dyn CloudAIProvider> = Arc::from(provider);
            let all_assets = state
                .engine
                .fetch_assets(&FilterCriteria {
                    include_trashed: false,
                    ..Default::default()
                })
                .unwrap_or_default();
            let options = Arc::new(build_folder_triage_options(&folders, &all_assets));
            let sem = Arc::new(Semaphore::new(4));
            let send_thumbs = ai_config.send_thumbnails_to_cloud;
            let mut handles = Vec::with_capacity(targets.len());

            for asset in targets {
                let jpeg = if send_thumbs {
                    state.engine.prepare_visual_grounding_jpeg(&asset, 384)
                } else {
                    None
                };
                let offline_fb = offline_triage_recommendation(
                    &asset,
                    offline_map.get(&asset.id).and_then(|o| o.as_ref()),
                );
                let provider = Arc::clone(&provider);
                let options = Arc::clone(&options);
                let sem = Arc::clone(&sem);
                let folder_names = folder_name_by_id.clone();

                handles.push(tokio::spawn(async move {
                    let _permit = sem.acquire_owned().await;
                    match VisualGroundingEngine::classify_into_folders_cloud_ai(
                        provider.as_ref(),
                        &asset,
                        jpeg.as_deref(),
                        &options,
                    )
                    .await
                    {
                        Ok(res) => InboxTriageRecommendation {
                            asset_id: asset.id,
                            asset_title: asset.title,
                            recommended_folder_id: res.folder_id,
                            recommended_folder_name: res
                                .folder_id
                                .and_then(|fid| folder_names.get(&fid).cloned()),
                            confidence: res.confidence,
                            fit_probability: res.fit_probability,
                            reason: res.reason,
                            source: res.source,
                        },
                        Err(_) => offline_fb,
                    }
                }));
            }

            let mut recs = Vec::with_capacity(handles.len());
            for handle in handles {
                if let Ok(rec) = handle.await {
                    recs.push(rec);
                }
            }
            sort_triage_recommendations(&mut recs);
            return Ok(recs);
        }
    }

    // Tier 3: Offline Local Multi-Signal Visual + Palette + Tag + Name Matching (never forces folders[0])
    let mut recs: Vec<InboxTriageRecommendation> = targets
        .iter()
        .map(|asset| {
            offline_triage_recommendation(
                asset,
                offline_map.get(&asset.id).and_then(|o| o.as_ref()),
            )
        })
        .collect();
    sort_triage_recommendations(&mut recs);
    Ok(recs)
}

async fn build_external_agent_state(state: &AppState) -> ExternalAgentStateDto {
    let config = ExternalAgentConfigStore::load(&state.data_dir);
    let cli_binary_path = resolve_cli_binary_path();
    let library_dir = state.data_dir.display().to_string();
    let bridge_status = state.extension_bridge.status().await;
    let http_mcp_endpoint_url = bridge_status.mcp_endpoint_url;
    let http_mcp_running = bridge_status.running && config.http_mcp_enabled;
    let mcp_config_json = serde_json::to_string_pretty(&json!({
        "mcpServers": {
            "charkle": {
                "command": cli_binary_path,
                "args": ["--library-dir", library_dir, "mcp"]
            }
        }
    }))
    .unwrap_or_default();
    let http_mcp_config_json = serde_json::to_string_pretty(&json!({
        "mcpServers": {
            "charkle-http": {
                "type": "http",
                "url": http_mcp_endpoint_url,
                "headers": {
                    "Authorization": "Bearer <YOUR_SCOPED_MCP_TOKEN>"
                }
            }
        }
    }))
    .unwrap_or_default();
    ExternalAgentStateDto {
        config,
        cli_binary_path,
        library_dir,
        mcp_config_json,
        http_mcp_endpoint_url,
        http_mcp_running,
        http_mcp_config_json,
        read_tool_count: READ_TOOL_NAMES.len(),
        write_tool_count: WRITE_TOOL_NAMES.len(),
        resource_count: 7,
    }
}

#[tauri::command]
pub async fn get_external_agent_state(
    state: State<'_, AppState>,
) -> IpcResult<ExternalAgentStateDto> {
    Ok(build_external_agent_state(&state).await)
}

#[tauri::command]
pub async fn save_external_agent_config(
    state: State<'_, AppState>,
    config: ExternalAgentConfig,
) -> IpcResult<ExternalAgentStateDto> {
    ExternalAgentConfigStore::save(&state.data_dir, &config).map_err(IpcError::from)?;
    let _ = state.extension_bridge.sync_mcp_network_binding().await;
    Ok(build_external_agent_state(&state).await)
}

#[tauri::command]
pub async fn mint_external_agent_token(
    state: State<'_, AppState>,
    name: String,
    access_level: ExternalAgentAccessLevel,
) -> IpcResult<MintExternalAgentTokenDto> {
    let mut config = ExternalAgentConfigStore::load(&state.data_dir);
    let (token, plaintext) = ExternalAgentToken::mint(name, access_level);
    config.tokens.push(token.clone());
    ExternalAgentConfigStore::save(&state.data_dir, &config).map_err(IpcError::from)?;
    let _ = state.extension_bridge.sync_mcp_network_binding().await;
    Ok(MintExternalAgentTokenDto {
        state: build_external_agent_state(&state).await,
        token,
        plaintext,
    })
}

#[tauri::command]
pub async fn toggle_external_agent_token(
    state: State<'_, AppState>,
    token_id: String,
    enabled: bool,
) -> IpcResult<ExternalAgentStateDto> {
    let uuid = parse_uuid(&token_id)?;
    let mut config = ExternalAgentConfigStore::load(&state.data_dir);
    let Some(entry) = config.tokens.iter_mut().find(|t| t.id == uuid) else {
        return Err(IpcError {
            code: "NOT_FOUND",
            message: "未找到指定的 Scoped Token。".to_string(),
        });
    };
    entry.is_enabled = enabled;
    ExternalAgentConfigStore::save(&state.data_dir, &config).map_err(IpcError::from)?;
    Ok(build_external_agent_state(&state).await)
}

#[tauri::command]
pub async fn revoke_external_agent_token(
    state: State<'_, AppState>,
    token_id: String,
) -> IpcResult<ExternalAgentStateDto> {
    let uuid = parse_uuid(&token_id)?;
    let mut config = ExternalAgentConfigStore::load(&state.data_dir);
    let before = config.tokens.len();
    config.tokens.retain(|t| t.id != uuid);
    if config.tokens.len() == before {
        return Err(IpcError {
            code: "NOT_FOUND",
            message: "未找到指定的 Scoped Token。".to_string(),
        });
    }
    ExternalAgentConfigStore::save(&state.data_dir, &config).map_err(IpcError::from)?;
    Ok(build_external_agent_state(&state).await)
}

#[tauri::command]
pub async fn run_external_agent_self_check(
    state: State<'_, AppState>,
) -> IpcResult<ExternalAgentSelfCheckDto> {
    let config = ExternalAgentConfigStore::load(&state.data_dir);
    let bridge_status = state.extension_bridge.status().await;
    let cli_path = resolve_cli_binary_path();
    let cli_exists = Path::new(&cli_path).exists();
    let db_path = state.data_dir.join("Library.sqlite3");
    let db_exists = db_path.exists();

    let assets = state
        .engine
        .fetch_assets(&FilterCriteria::default())
        .map_err(IpcError::from)?;
    let folders = state.engine.fetch_folders().map_err(IpcError::from)?;
    let boards = state.engine.fetch_boards().map_err(IpcError::from)?;

    let mode_label = config.access_level.display_title();
    let active_tokens = config.tokens.iter().filter(|t| t.is_enabled).count();

    if !db_exists {
        return Ok(ExternalAgentSelfCheckDto {
            ok: false,
            summary: "未检测到本地素材库数据库文件，请先完成初始化。".to_string(),
        });
    }
    if config.mcp_enabled && !cli_exists {
        return Ok(ExternalAgentSelfCheckDto {
            ok: false,
            summary: format!(
                "素材库可正常读取（{} 项素材、{} 个目录、{} 个灵感板），但未在应用目录找到本地 stdio MCP 助手程序（charkle-cli.exe）。",
                assets.len(),
                folders.len(),
                boards.len()
            ),
        });
    }
    if config.http_mcp_enabled && !bridge_status.running {
        return Ok(ExternalAgentSelfCheckDto {
            ok: false,
            summary: format!(
                "HTTP MCP 已开启但本地 HTTP 监听未运行（{}）。请重试开关或检查端口占用。",
                bridge_status.last_error.as_deref().unwrap_or("端口未就绪")
            ),
        });
    }

    let enabled_services = match (config.mcp_enabled, config.http_mcp_enabled) {
        (true, true) => "本地 stdio MCP 与 Streamable HTTP MCP 均已启用",
        (true, false) => "仅本地 stdio MCP 已启用",
        (false, true) => "仅 Streamable HTTP MCP 已启用",
        (false, false) => "MCP 外部接入当前已关闭",
    };

    let available_tools = match config.access_level {
        ExternalAgentAccessLevel::ReadOnly => READ_TOOL_NAMES.len(),
        ExternalAgentAccessLevel::InboxAndEnrich => READ_TOOL_NAMES.len() + 2,
        ExternalAgentAccessLevel::ReadWriteOrganize => {
            READ_TOOL_NAMES.len() + WRITE_TOOL_NAMES.len()
        }
    };

    Ok(ExternalAgentSelfCheckDto {
        ok: true,
        summary: format!(
            "自检通过：{enabled_services}（本地默认权限：{mode_label}，可用工具 {available_tools}/10 项，活跃 HTTP 令牌 {active_tokens} 个）；素材库含 {} 项素材、{} 个目录、{} 个灵感板。",
            assets.len(),
            folders.len(),
            boards.len()
        ),
    })
}

#[tauri::command]
pub async fn rebuild_local_visual_index(
    state: State<'_, AppState>,
) -> IpcResult<RebuildIndexResultDto> {
    let assets = state
        .engine
        .fetch_assets(&FilterCriteria::default())
        .map_err(IpcError::from)?;
    let eligible: Vec<_> = assets
        .into_iter()
        .filter(|a| {
            matches!(
                a.media_kind,
                MediaKind::Image | MediaKind::AnimatedImage | MediaKind::DesignFile
            )
        })
        .collect();
    let total = eligible.len();
    let mut processed = 0usize;

    for asset in eligible {
        let mut touched = false;
        if state.engine.index_local_visual_descriptor(&asset) {
            touched = true;
        }
        let has_rich = asset
            .rich_metadata
            .as_ref()
            .is_some_and(|r| r.photo_exif.is_some() || r.ai_generation.is_some());
        if !has_rich {
            if let Ok(Some(_)) = state.engine.hydrate_image_metadata(asset.id) {
                touched = true;
            }
        }
        let needs_ocr = asset
            .ocr_text
            .as_deref()
            .map(str::trim)
            .is_none_or(str::is_empty);
        if needs_ocr {
            if let Ok(Some(_)) = state.engine.run_ocr_for_asset(asset.id).await {
                touched = true;
            }
        }
        if touched || !needs_ocr || has_rich {
            processed += 1;
        }
    }

    Ok(RebuildIndexResultDto { processed, total })
}

#[tauri::command]
pub async fn save_webdav_password(state: State<'_, AppState>, password: String) -> IpcResult<()> {
    state
        .engine
        .save_webdav_password(&password)
        .await
        .map_err(IpcError::from)
}

#[tauri::command]
pub async fn run_storage_migration(
    state: State<'_, AppState>,
    target_config: DriveSyncConfig,
    webdav_password: Option<String>,
) -> IpcResult<StorageMigrationReport> {
    state
        .engine
        .migrate_storage(target_config, webdav_password.as_deref(), None, None)
        .await
        .map_err(IpcError::from)
}

#[tauri::command]
pub async fn get_system_diagnostics(state: State<'_, AppState>) -> IpcResult<SystemDiagnosticsDto> {
    let sync_cfg = state.engine.sync_config();
    let mount_path = sync_cfg.mount_path.clone();
    let data_dir = state.data_dir.clone();

    let (gdirect, ocr) = tokio::task::spawn_blocking(move || {
        let mount_info = inspect_mount(Path::new(&mount_path));
        let gdirect =
            probe_gdirect_environment(detect_gdirect_binary(), mount_path, mount_info.available);
        let ocr = probe_ocr_diagnostics();
        (gdirect, ocr)
    })
    .await
    .unwrap_or_else(|_| {
        (
            GDirectEnvironmentSnapshot {
                mount_path: sync_cfg.mount_path,
                ..Default::default()
            },
            probe_ocr_diagnostics(),
        )
    });

    Ok(SystemDiagnosticsDto {
        app_version: env!("CARGO_PKG_VERSION").to_string(),
        schema_version: 2,
        data_dir: data_dir.display().to_string(),
        database_path: data_dir.join("Library.sqlite3").display().to_string(),
        gdirect,
        ocr,
    })
}

/// Downloads, SHA-256 verifies, and installs the official Windows `gdirect` CLI binary into
/// `%LOCALAPPDATA%\Charkle\bin\gdirect.exe` with live progress events (`gdirect:install-progress`).
#[tauri::command]
pub async fn install_gdirect_cli(app: tauri::AppHandle) -> IpcResult<GDirectInstallResult> {
    let app_for_progress = app.clone();
    install_gdirect_cli_windows(None, move |progress| {
        let _ = app_for_progress.emit("gdirect:install-progress", &progress);
    })
    .await
    .map_err(IpcError::from)
}

#[tauri::command]
pub fn export_figma_plugin_bundle(destination_dir: String) -> IpcResult<String> {
    let trimmed = destination_dir.trim();
    if trimmed.is_empty() {
        return Err(IpcError {
            code: "INVALID_PATH",
            message: "请选择有效的导出目标目录。".to_string(),
        });
    }
    let dest = PathBuf::from(trimmed).join("Charkle-Figma-Plugin");
    std::fs::create_dir_all(&dest).map_err(|e| IpcError {
        code: "IO_ERROR",
        message: e.to_string(),
    })?;

    let mut search_roots = Vec::new();
    if let Ok(exe) = std::env::current_exe() {
        if let Some(dir) = exe.parent() {
            search_roots.push(dir.join("Resources").join("FigmaPlugin"));
            search_roots.push(dir.join("FigmaPlugin"));
        }
    }
    if let Ok(cwd) = std::env::current_dir() {
        search_roots.push(cwd.join("Resources").join("FigmaPlugin"));
        if let Some(parent) = cwd.parent() {
            search_roots.push(parent.join("Resources").join("FigmaPlugin"));
        }
    }

    let source_dir = search_roots
        .into_iter()
        .find(|p| p.join("manifest.json").exists() && p.join("code.js").exists())
        .ok_or_else(|| IpcError {
            code: "NOT_FOUND",
            message: "未找到 Figma 插件源文件目录（Resources/FigmaPlugin）。".to_string(),
        })?;

    for file in ["manifest.json", "code.js", "ui.html"] {
        let src = source_dir.join(file);
        if src.exists() {
            std::fs::copy(&src, dest.join(file)).map_err(|e| IpcError {
                code: "IO_ERROR",
                message: format!("复制 {file} 失败：{e}"),
            })?;
        }
    }
    Ok(dest.display().to_string())
}

// =============================================================================
// Local Browser Extension Bridge IPC (Chrome / Edge / Arc / Brave)
// =============================================================================

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ExtensionBridgeStateDto {
    pub enabled: bool,
    pub running: bool,
    pub port: u16,
    pub base_url: String,
    pub allow_local_auto_pair: bool,
    pub access_token: String,
    pub last_error: Option<String>,
    pub bundled_extension_dir: Option<String>,
    pub bundled_extension_manifest_path: Option<String>,
}

fn resolve_bundled_browser_extension_dir() -> Option<PathBuf> {
    let mut candidates = Vec::new();
    if let Ok(exe) = std::env::current_exe() {
        if let Some(dir) = exe.parent() {
            candidates.push(dir.join("Resources").join("BrowserExtension"));
            candidates.push(dir.join("resources").join("BrowserExtension"));
            candidates.push(dir.join("BrowserExtension"));
        }
    }
    if let Ok(cwd) = std::env::current_dir() {
        candidates.push(cwd.join("resources").join("BrowserExtension"));
        candidates.push(
            cwd.join("src-tauri")
                .join("resources")
                .join("BrowserExtension"),
        );
        candidates.push(
            cwd.join("windows")
                .join("src-tauri")
                .join("resources")
                .join("BrowserExtension"),
        );
        if let Some(parent) = cwd.parent() {
            candidates.push(parent.join("resources").join("BrowserExtension"));
            candidates.push(
                parent
                    .join("src-tauri")
                    .join("resources")
                    .join("BrowserExtension"),
            );
        }
    }
    candidates
        .into_iter()
        .find(|dir| dir.join("manifest.json").is_file())
}

fn extension_bridge_dto_from_status(status: ExtensionBridgeStatus) -> ExtensionBridgeStateDto {
    let ext_dir = resolve_bundled_browser_extension_dir();
    let manifest_path = ext_dir.as_ref().map(|d| d.join("manifest.json"));
    ExtensionBridgeStateDto {
        enabled: status.enabled,
        running: status.running,
        port: status.port,
        base_url: status.base_url,
        allow_local_auto_pair: status.allow_local_auto_pair,
        access_token: status.access_token,
        last_error: status.last_error,
        bundled_extension_dir: ext_dir.map(|d| d.display().to_string()),
        bundled_extension_manifest_path: manifest_path.map(|p| p.display().to_string()),
    }
}

#[tauri::command]
pub async fn get_extension_bridge_state(
    state: State<'_, AppState>,
) -> IpcResult<ExtensionBridgeStateDto> {
    let status = state.extension_bridge.status().await;
    Ok(extension_bridge_dto_from_status(status))
}

#[tauri::command]
pub async fn set_extension_bridge_enabled(
    state: State<'_, AppState>,
    enabled: bool,
) -> IpcResult<ExtensionBridgeStateDto> {
    let status = state
        .extension_bridge
        .set_enabled(enabled)
        .await
        .map_err(IpcError::from)?;
    Ok(extension_bridge_dto_from_status(status))
}

#[tauri::command]
pub async fn set_extension_auto_pair(
    state: State<'_, AppState>,
    allow_local_auto_pair: bool,
) -> IpcResult<ExtensionBridgeStateDto> {
    let status = state
        .extension_bridge
        .set_auto_pair(allow_local_auto_pair)
        .await
        .map_err(IpcError::from)?;
    Ok(extension_bridge_dto_from_status(status))
}

#[tauri::command]
pub async fn regenerate_extension_bridge_token(
    state: State<'_, AppState>,
) -> IpcResult<ExtensionBridgeStateDto> {
    let status = state
        .extension_bridge
        .regenerate_token()
        .await
        .map_err(IpcError::from)?;
    Ok(extension_bridge_dto_from_status(status))
}

#[tauri::command]
pub fn reveal_bundled_browser_extension() -> IpcResult<String> {
    let ext_dir = resolve_bundled_browser_extension_dir().ok_or_else(|| IpcError {
        code: "NOT_FOUND",
        message: "未找到内置浏览器扩展目录（BrowserExtension/manifest.json）。".to_string(),
    })?;
    let manifest_path = ext_dir.join("manifest.json");
    let target = if manifest_path.is_file() {
        manifest_path.clone()
    } else {
        ext_dir
    };

    #[cfg(target_os = "windows")]
    {
        std::process::Command::new("explorer.exe")
            .arg(format!("/select,{}", target.display()))
            .spawn()
            .map_err(|e| IpcError {
                code: "IO_ERROR",
                message: format!("无法打开文件资源管理器：{e}"),
            })?;
    }

    Ok(target.display().to_string())
}
