//! M5 Settings, Hybrid Cloud AI, TypeSafe Jev, External Agent, Storage Migration & Diagnostics IPC commands.

use std::path::{Path, PathBuf};
use std::sync::Arc;

use charkle_core::agent::{ExternalAgentConfigStore, READ_TOOL_NAMES, WRITE_TOOL_NAMES};
use charkle_core::bridge::ExtensionBridgeStatus;
use charkle_core::intelligence::{
    test_cloud_ai_connection, AIConnectionTestResult, ChatGPTSignInClient, CloudAIUsageCategory,
    CloudAIUsageSummary, TypeSafeSystemOneClient, VisualGroundingEngine, AI_API_KEY_SECRET_KEY,
    TYPESAFE_API_KEY_SECRET_KEY,
};
use charkle_core::models::agent::{ExternalAgentAccessLevel, ExternalAgentConfig};
use charkle_core::models::core::{FilterCriteria, MediaKind};
use charkle_core::models::media::{
    AIProviderConfig, ChatGPTAccountSession, CloudAIProviderKind, InboxTriageRecommendation,
    TypeSafeExperimentalConfig, TypeSafeModelInfo,
};
use charkle_core::models::sync::{
    DriveSyncConfig, GDirectEnvironmentSnapshot, StorageMigrationReport,
};
use charkle_platform_win::mount::{detect_gdirect_binary, inspect_mount};
use charkle_platform_win::{probe_ocr_diagnostics, OcrDiagnostics};
use serde::{Deserialize, Serialize};
use serde_json::json;
use tauri::State;

use super::media::open_validated_http_url;
use super::{AppState, IpcError, IpcResult};

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
    pub read_tool_count: usize,
    pub write_tool_count: usize,
    pub resource_count: usize,
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
    save_json_atomic(&state.data_dir.join(TYPESAFE_CONFIG_FILE), &payload.config)?;
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

#[tauri::command]
pub fn run_inbox_smart_triage(
    state: State<'_, AppState>,
) -> IpcResult<Vec<InboxTriageRecommendation>> {
    let inbox = state
        .engine
        .fetch_assets(&FilterCriteria {
            only_inbox: true,
            ..Default::default()
        })
        .map_err(IpcError::from)?;
    let folders = state.engine.fetch_folders().map_err(IpcError::from)?;
    Ok(VisualGroundingEngine::recommend_inbox_triage(
        &inbox, &folders,
    ))
}

#[tauri::command]
pub fn get_external_agent_state(state: State<'_, AppState>) -> ExternalAgentStateDto {
    let config = ExternalAgentConfigStore::load(&state.data_dir);
    let cli_binary_path = resolve_cli_binary_path();
    let library_dir = state.data_dir.display().to_string();
    let mcp_config_json = serde_json::to_string_pretty(&json!({
        "mcpServers": {
            "charkle": {
                "command": cli_binary_path,
                "args": ["--library-dir", library_dir, "mcp"]
            }
        }
    }))
    .unwrap_or_default();
    ExternalAgentStateDto {
        config,
        cli_binary_path,
        library_dir,
        mcp_config_json,
        read_tool_count: READ_TOOL_NAMES.len(),
        write_tool_count: WRITE_TOOL_NAMES.len(),
        resource_count: 6,
    }
}

#[tauri::command]
pub fn save_external_agent_config(
    state: State<'_, AppState>,
    config: ExternalAgentConfig,
) -> IpcResult<ExternalAgentStateDto> {
    ExternalAgentConfigStore::save(&state.data_dir, &config).map_err(IpcError::from)?;
    Ok(get_external_agent_state(state))
}

#[tauri::command]
pub fn run_external_agent_self_check(
    state: State<'_, AppState>,
) -> IpcResult<ExternalAgentSelfCheckDto> {
    let config = ExternalAgentConfigStore::load(&state.data_dir);
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

    let mode_label = match config.access_level {
        ExternalAgentAccessLevel::ReadOnly => "只读模式",
        ExternalAgentAccessLevel::ReadWriteOrganize => "读写整理模式",
    };

    if !db_exists {
        return Ok(ExternalAgentSelfCheckDto {
            ok: false,
            summary: "未检测到本地素材库数据库文件，请先完成初始化。".to_string(),
        });
    }
    if !cli_exists {
        return Ok(ExternalAgentSelfCheckDto {
            ok: false,
            summary: format!(
                "素材库可正常读取（{} 项素材、{} 个目录、{} 个灵感板），但未在应用目录找到配套命令行工具。",
                assets.len(),
                folders.len(),
                boards.len()
            ),
        });
    }

    let enabled_services = match (config.mcp_enabled, config.cli_enabled) {
        (true, true) => "MCP 与 CLI 已启用",
        (true, false) => "仅 MCP 已启用",
        (false, true) => "仅 CLI 已启用",
        (false, false) => "外部工具接入当前已关闭",
    };

    let available_tools = match config.access_level {
        ExternalAgentAccessLevel::ReadOnly => READ_TOOL_NAMES.len(),
        ExternalAgentAccessLevel::ReadWriteOrganize => {
            READ_TOOL_NAMES.len() + WRITE_TOOL_NAMES.len()
        }
    };

    Ok(ExternalAgentSelfCheckDto {
        ok: true,
        summary: format!(
            "自检通过：{enabled_services}（{mode_label}，可用工具 {available_tools} 项）；素材库含 {} 项素材、{} 个目录、{} 个灵感板。",
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
pub fn get_system_diagnostics(state: State<'_, AppState>) -> SystemDiagnosticsDto {
    let sync_cfg = state.engine.sync_config();
    let mount_info = inspect_mount(Path::new(&sync_cfg.mount_path));
    let gdirect = GDirectEnvironmentSnapshot {
        cli_path: detect_gdirect_binary().map(|p| p.display().to_string()),
        mount_path: sync_cfg.mount_path,
        is_mount_active: mount_info.available,
        ..Default::default()
    };
    let ocr = probe_ocr_diagnostics();
    SystemDiagnosticsDto {
        app_version: "1.2.0".to_string(),
        schema_version: 2,
        data_dir: state.data_dir.display().to_string(),
        database_path: state.data_dir.join("Library.sqlite3").display().to_string(),
        gdirect,
        ocr,
    }
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
