use charkle_core::models::sync::{DriveSyncConfig, SyncReport, SyncStatus};
use tauri::State;

use super::{AppState, IpcResult};

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
