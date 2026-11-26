//! Tauri v2 IPC commands for Pinterest infinite spatial exploration, tray batch import,
//! and batch user-board collection import.

use std::sync::atomic::Ordering;
use std::sync::Arc;

use charkle_core::pinterest::{
    PinterestAccount, PinterestBatchImportReport, PinterestBoard, PinterestBoardImportDestination,
    PinterestBoardsImportReport, PinterestFeedPage, PinterestFeedSource, PinterestImportService,
    PinterestPin, PinterestPinDetailResult,
};
use serde::Serialize;
use tauri::{AppHandle, Emitter, State};

use crate::commands::{parse_optional_uuid, AppState, IpcResult};

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PinterestTrayImportProgress {
    pub completed: usize,
    pub total: usize,
    pub current_title: String,
}

#[tauri::command]
pub async fn pinterest_open_login_window(state: State<'_, AppState>) -> IpcResult<()> {
    state.pinterest.open_login_window()?;
    Ok(())
}

#[tauri::command]
pub async fn pinterest_close_login_window(state: State<'_, AppState>) -> IpcResult<()> {
    state.pinterest.close_login_window();
    Ok(())
}

#[tauri::command]
pub async fn pinterest_check_session(
    state: State<'_, AppState>,
) -> IpcResult<Option<PinterestAccount>> {
    Ok(state.pinterest.check_session_account().await?)
}

#[tauri::command]
pub async fn pinterest_sign_out(state: State<'_, AppState>) -> IpcResult<()> {
    state.pinterest.sign_out().await?;
    Ok(())
}

#[tauri::command]
pub async fn pinterest_fetch_feed(
    state: State<'_, AppState>,
    source: PinterestFeedSource,
    bookmark: Option<String>,
    page_size: Option<usize>,
) -> IpcResult<PinterestFeedPage> {
    let size = page_size.unwrap_or(32).clamp(6, 60);
    Ok(state
        .pinterest
        .fetch_feed(&source, bookmark.as_deref(), size)
        .await?)
}

#[tauri::command]
pub async fn pinterest_fetch_boards(
    state: State<'_, AppState>,
    username: String,
) -> IpcResult<Vec<PinterestBoard>> {
    Ok(state.pinterest.fetch_user_boards(&username).await?)
}

#[tauri::command]
pub async fn pinterest_fetch_pin_detail(
    state: State<'_, AppState>,
    pin: PinterestPin,
) -> IpcResult<PinterestPinDetailResult> {
    Ok(state.pinterest.fetch_pin_detail_and_similar(&pin).await?)
}

#[tauri::command]
pub async fn pinterest_fetch_similar_pins(
    state: State<'_, AppState>,
    pin: PinterestPin,
    bookmark: Option<String>,
    page_size: Option<usize>,
) -> IpcResult<PinterestFeedPage> {
    let size = page_size.unwrap_or(28).clamp(6, 60);
    Ok(state
        .pinterest
        .fetch_similar_pins(&pin, bookmark.as_deref(), size)
        .await?)
}

#[tauri::command]
pub async fn pinterest_existing_imported_pin_ids(
    state: State<'_, AppState>,
) -> IpcResult<Vec<String>> {
    let mut ids: Vec<String> = PinterestImportService::existing_imported_pin_ids(&state.engine)
        .into_iter()
        .collect();
    ids.sort();
    Ok(ids)
}

#[tauri::command]
pub async fn pinterest_import_pins(
    app: AppHandle,
    state: State<'_, AppState>,
    pins: Vec<PinterestPin>,
    target_folder_id: Option<String>,
    extra_tags: Vec<String>,
    skip_duplicates: Option<bool>,
) -> IpcResult<PinterestBatchImportReport> {
    let folder_uuid = parse_optional_uuid(target_folder_id)?;
    let skip = skip_duplicates.unwrap_or(true);
    let report = PinterestImportService::import_pins(
        &pins,
        &state.engine,
        folder_uuid,
        &extra_tags,
        skip,
        |completed, total, pin| {
            let _ = app.emit(
                "pinterest:tray-import-progress",
                PinterestTrayImportProgress {
                    completed,
                    total,
                    current_title: pin.display_title(),
                },
            );
        },
    )
    .await;
    if !report.imported_assets.is_empty() {
        let _ = app.emit("library:changed", ());
    }
    Ok(report)
}

#[tauri::command]
pub async fn pinterest_import_boards(
    app: AppHandle,
    state: State<'_, AppState>,
    boards: Vec<PinterestBoard>,
    destination: PinterestBoardImportDestination,
    extra_tags: Vec<String>,
    skip_duplicates: Option<bool>,
) -> IpcResult<PinterestBoardsImportReport> {
    let cancel_flag = Arc::clone(&state.pinterest_board_import_cancel);
    cancel_flag.store(false, Ordering::SeqCst);

    let bridge = Arc::clone(&state.pinterest);
    let engine = Arc::clone(&state.engine);
    let app_for_progress = app.clone();
    let skip = skip_duplicates.unwrap_or(true);

    let report = PinterestImportService::import_boards(
        &boards,
        &engine,
        destination,
        &extra_tags,
        skip,
        Some(cancel_flag.as_ref()),
        |board| {
            let b = Arc::clone(&bridge);
            async move { b.fetch_all_board_pins(&board, 2000).await }
        },
        |url| async move { PinterestImportService::fetch_media_bytes(&url).await },
        move |progress| {
            let _ = app_for_progress.emit("pinterest:board-import-progress", progress);
        },
    )
    .await;

    if report.imported_asset_count > 0 || !report.created_or_reused_folder_ids.is_empty() {
        let _ = app.emit("library:changed", ());
    }
    Ok(report)
}

#[tauri::command]
pub async fn pinterest_cancel_board_import(state: State<'_, AppState>) -> IpcResult<()> {
    state
        .pinterest_board_import_cancel
        .store(true, Ordering::SeqCst);
    Ok(())
}
