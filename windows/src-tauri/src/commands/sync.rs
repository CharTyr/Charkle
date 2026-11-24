use std::sync::Arc;

use charkle_core::models::sync::{DriveSyncConfig, SyncReport, SyncStatus};
use charkle_core::sync::{
    DirectAPITransport, DriveTransport, GoogleOAuthClientConfig, WebDAVTransport,
};
use serde::Serialize;
use tauri::State;

use super::media::open_validated_http_url;
use super::{AppState, IpcError, IpcResult};

const WEBDAV_PASSWORD_VAULT_KEY: &str = "sync.webdav.password";

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SyncAuthStateDto {
    pub has_google_oauth_client: bool,
    pub has_webdav_password: bool,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct WebdavTestResultDto {
    pub ok: bool,
    pub message: String,
}

#[tauri::command]
pub fn sync_config(state: State<'_, AppState>) -> DriveSyncConfig {
    state.engine.sync_config()
}

#[tauri::command]
pub fn save_sync_config(state: State<'_, AppState>, config: DriveSyncConfig) -> IpcResult<()> {
    state.engine.save_sync_config(config).map_err(Into::into)
}

#[tauri::command]
pub async fn sync_status(state: State<'_, AppState>) -> IpcResult<SyncStatus> {
    Ok(state.engine.sync_status().await)
}

#[tauri::command]
pub async fn sync_now(state: State<'_, AppState>) -> IpcResult<SyncReport> {
    state.engine.sync_now().await.map_err(Into::into)
}

#[tauri::command]
pub async fn get_sync_auth_state(state: State<'_, AppState>) -> IpcResult<SyncAuthStateDto> {
    let has_google_oauth_client = state
        .engine
        .oauth()
        .stored_config()
        .await
        .ok()
        .flatten()
        .is_some();
    let has_webdav_password = state.engine.has_webdav_password().await;
    Ok(SyncAuthStateDto {
        has_google_oauth_client,
        has_webdav_password,
    })
}

#[tauri::command]
pub async fn save_google_oauth_client(
    state: State<'_, AppState>,
    client_id: String,
    client_secret: String,
) -> IpcResult<bool> {
    let cfg = GoogleOAuthClientConfig::new(client_id, client_secret);
    state
        .engine
        .oauth()
        .save_client_config(&cfg)
        .await
        .map_err(IpcError::from)?;
    Ok(true)
}

#[tauri::command]
pub async fn import_google_oauth_secret_file(
    state: State<'_, AppState>,
    file_path: String,
) -> IpcResult<bool> {
    let trimmed = file_path.trim();
    if trimmed.is_empty() {
        return Err(IpcError {
            code: "INVALID_PATH",
            message: "请选择有效的 JSON 凭证文件。".to_string(),
        });
    }
    let data = std::fs::read(trimmed).map_err(|e| IpcError {
        code: "IO_ERROR",
        message: format!("无法读取凭证文件：{e}"),
    })?;
    let cfg = GoogleOAuthClientConfig::parse_client_secret_json(&data).map_err(IpcError::from)?;
    state
        .engine
        .oauth()
        .save_client_config(&cfg)
        .await
        .map_err(IpcError::from)?;
    Ok(true)
}

#[tauri::command]
pub async fn sign_in_google_drive(state: State<'_, AppState>) -> IpcResult<SyncStatus> {
    let cfg = state
        .engine
        .oauth()
        .stored_config()
        .await
        .map_err(IpcError::from)?
        .ok_or_else(|| IpcError {
            code: "NOT_CONFIGURED",
            message: "请先配置 Google OAuth Client ID 或导入凭证文件。".to_string(),
        })?;
    let sync_cfg = state.engine.sync_config();
    let full_drive_scope = !sync_cfg.shared_folder_url_or_id.trim().is_empty();

    state
        .engine
        .oauth()
        .authorize_interactive(&cfg, full_drive_scope, |url| async move {
            let _ = open_validated_http_url(url.as_str());
        })
        .await
        .map_err(IpcError::from)?;

    let transport = DirectAPITransport::new(Arc::clone(state.engine.oauth()), &[]);
    if let Ok(info) = transport.account_info().await {
        state
            .engine
            .sync_engine()
            .update_signed_in_account(Some(info), sync_cfg.mode)
            .await;
    }
    Ok(state.engine.sync_status().await)
}

#[tauri::command]
pub async fn sign_out_google_drive(state: State<'_, AppState>) -> IpcResult<SyncStatus> {
    state
        .engine
        .oauth()
        .sign_out()
        .await
        .map_err(IpcError::from)?;
    let sync_cfg = state.engine.sync_config();
    state
        .engine
        .sync_engine()
        .update_signed_in_account(None, sync_cfg.mode)
        .await;
    Ok(state.engine.sync_status().await)
}

#[tauri::command]
pub async fn test_webdav_connection(
    state: State<'_, AppState>,
    config: DriveSyncConfig,
    password: Option<String>,
) -> IpcResult<WebdavTestResultDto> {
    let effective_password = match password.as_deref().map(str::trim) {
        Some(pw) if !pw.is_empty() => {
            state
                .engine
                .save_webdav_password(pw)
                .await
                .map_err(IpcError::from)?;
            pw.to_string()
        }
        _ => state
            .engine
            .vault()
            .get_secret(WEBDAV_PASSWORD_VAULT_KEY)
            .await
            .ok()
            .flatten()
            .unwrap_or_default(),
    };

    let transport = match WebDAVTransport::new(
        &config.webdav_server_url,
        &config.webdav_username,
        &effective_password,
        &config.webdav_remote_path,
    ) {
        Ok(t) => t,
        Err(err) => {
            return Ok(WebdavTestResultDto {
                ok: false,
                message: err.to_string(),
            });
        }
    };

    match transport.account_info().await {
        Ok(info) => {
            let target = info
                .display_name
                .as_deref()
                .filter(|s| !s.is_empty())
                .unwrap_or(info.email.as_str());
            Ok(WebdavTestResultDto {
                ok: true,
                message: format!("连接成功（{target}），远程目录可正常访问。"),
            })
        }
        Err(err) => Ok(WebdavTestResultDto {
            ok: false,
            message: err.to_string(),
        }),
    }
}
