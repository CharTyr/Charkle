//! M5 Settings, Hybrid Cloud AI, TypeSafe Jev, External Agent, Storage Migration & Diagnostics IPC commands.

use std::path::{Path, PathBuf};
use std::sync::Arc;

use charkle_core::agent::{ExternalAgentConfigStore, READ_TOOL_NAMES, WRITE_TOOL_NAMES};
use charkle_core::intelligence::{
    test_cloud_ai_connection, AIConnectionTestResult, ChatGPTSignInClient, CloudAIUsageCategory,
    CloudAIUsageSummary, TypeSafeSystemOneClient, VisualGroundingEngine, AI_API_KEY_SECRET_KEY,
    TYPESAFE_API_KEY_SECRET_KEY,
};
use charkle_core::models::agent::ExternalAgentConfig;
use charkle_core::models::core::FilterCriteria;
use charkle_core::models::media::{
    AIProviderConfig, ChatGPTAccountSession, InboxTriageRecommendation, TypeSafeExperimentalConfig,
    TypeSafeModelInfo,
};
use charkle_core::models::sync::{
    DriveSyncConfig, GDirectEnvironmentSnapshot, StorageMigrationReport,
};
use charkle_platform_win::mount::{detect_gdirect_binary, inspect_mount};
use charkle_platform_win::{probe_ocr_diagnostics, OcrDiagnostics};
use serde::{Deserialize, Serialize};
use serde_json::json;
use tauri::State;

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
        resource_count: 2,
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
        app_version: "1.0.1".to_string(),
        schema_version: 2,
        data_dir: state.data_dir.display().to_string(),
        database_path: state.data_dir.join("Library.sqlite3").display().to_string(),
        gdirect,
        ocr,
    }
}

#[tauri::command]
pub fn export_figma_plugin_bundle(destination_dir: String) -> IpcResult<String> {
    let dest = PathBuf::from(destination_dir.trim()).join("Charkle-Figma-Plugin");
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
