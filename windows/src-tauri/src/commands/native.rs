//! M3 native Windows desktop IPC commands:
//! Top-Edge Drop Shelf, OLE outbound drag (`DoDragDrop`), Multi-DPI Region Capture,
//! Clipboard Collector, Global Hotkeys, Autostart, and offline WinRT OCR.

use std::path::PathBuf;
use std::sync::atomic::Ordering;

use charkle_core::models::core::AssetRecord;
use charkle_core::models::media::CaptureInput;
use charkle_platform_win::capture::crop_captured_frame;
use charkle_platform_win::clipboard::ClipboardPreview;
use charkle_platform_win::drag_out::{start_outbound_file_drag, DragOutOutcome};
use charkle_platform_win::ocr::{probe_ocr_diagnostics, OcrDiagnostics};
use charkle_platform_win::shelf_win::set_shelf_hit_rect as win_set_shelf_hit_rect;
use charkle_platform_win::windowing::ClientRect;
use tauri::{AppHandle, Manager, State};
use tauri_plugin_autostart::ManagerExt as AutostartManagerExt;

use crate::commands::{parse_optional_uuid, parse_uuid, AppState, IpcError, IpcResult};
use crate::desktop::{
    build_desktop_status, collect_clipboard_into_library, hide_shelf_window, launch_region_capture,
    read_initial_clipboard_preview, register_configured_hotkeys, show_or_focus_main_window,
    show_shelf_window, toggle_shelf_window, CaptureSessionInfo, DesktopIntegrationStatus,
    HotkeyConfig,
};

fn native_err(message: impl Into<String>) -> IpcError {
    IpcError {
        code: "NATIVE_WIN_ERROR",
        message: message.into(),
    }
}

#[tauri::command]
pub async fn start_outbound_drag(
    state: State<'_, AppState>,
    asset_ids: Vec<String>,
) -> IpcResult<DragOutOutcome> {
    let mut paths: Vec<PathBuf> = Vec::with_capacity(asset_ids.len());
    for raw in asset_ids {
        let id = parse_uuid(&raw)?;
        if let Some(asset) = state.engine.fetch_asset(id)? {
            if let Some(local_path) = state.engine.cached_original_path(&asset) {
                paths.push(local_path);
            }
        }
    }
    if paths.is_empty() {
        return Err(native_err("所选素材尚未缓存在本地磁盘，无法拖出到外部应用"));
    }
    start_outbound_file_drag(paths).await.map_err(native_err)
}

#[tauri::command]
pub fn set_shelf_hit_rect(app: AppHandle, rect: Option<ClientRect>) -> IpcResult<()> {
    #[cfg(target_os = "windows")]
    if let Some(win) = app.get_webview_window("shelf") {
        if let Ok(hwnd) = win.hwnd() {
            win_set_shelf_hit_rect(hwnd.0 as isize, rect);
        }
    }
    #[cfg(not(target_os = "windows"))]
    let _ = (app, rect, win_set_shelf_hit_rect);
    Ok(())
}

#[tauri::command]
pub fn toggle_shelf(app: AppHandle) -> IpcResult<bool> {
    toggle_shelf_window(&app).map_err(native_err)
}

#[tauri::command]
pub fn show_shelf(app: AppHandle, pinned: Option<bool>) -> IpcResult<()> {
    show_shelf_window(&app, pinned.unwrap_or(false)).map_err(native_err)
}

#[tauri::command]
pub fn hide_shelf(app: AppHandle) -> IpcResult<()> {
    hide_shelf_window(&app);
    Ok(())
}

#[tauri::command]
pub fn set_shelf_pinned(state: State<'_, AppState>, pinned: bool) -> IpcResult<bool> {
    state.shelf_pinned.store(pinned, Ordering::SeqCst);
    Ok(pinned)
}

#[tauri::command]
pub fn start_region_capture(
    app: AppHandle,
    target_folder_id: Option<String>,
    target_board_id: Option<String>,
) -> IpcResult<CaptureSessionInfo> {
    launch_region_capture(&app, target_folder_id, target_board_id).map_err(native_err)
}

#[tauri::command]
pub fn get_capture_session(
    state: State<'_, AppState>,
    token: String,
) -> IpcResult<Option<CaptureSessionInfo>> {
    Ok(state.capture_frames.get_info(&token))
}

#[allow(clippy::too_many_arguments)]
#[tauri::command]
pub async fn commit_region_capture(
    app: AppHandle,
    state: State<'_, AppState>,
    token: String,
    x: u32,
    y: u32,
    width: u32,
    height: u32,
    target_folder_id: Option<String>,
    target_board_id: Option<String>,
) -> IpcResult<Vec<AssetRecord>> {
    let frame = state
        .capture_frames
        .remove(&token)
        .ok_or_else(|| native_err("Capture frame not found or already closed"))?;

    if let Some(win) = app.get_webview_window("capture") {
        let _ = win.close();
    }

    let png_bytes =
        tokio::task::spawn_blocking(move || crop_captured_frame(&frame, x, y, width, height))
            .await
            .map_err(|e| native_err(format!("Crop worker failed: {e}")))?
            .map_err(native_err)?;

    let fid = parse_optional_uuid(target_folder_id)?;
    let bid = parse_optional_uuid(target_board_id)?;
    let input = CaptureInput::ImageData {
        data: png_bytes,
        suggested_name: format!(
            "screenshot-{}.png",
            chrono::Utc::now().format("%Y%m%d-%H%M%S")
        ),
        source_url: None,
    };

    let created = state.engine.ingest(vec![input], fid, bid).await?;
    Ok(created)
}

#[tauri::command]
pub fn cancel_region_capture(
    app: AppHandle,
    state: State<'_, AppState>,
    token: String,
) -> IpcResult<()> {
    let _ = state.capture_frames.remove(&token);
    if let Some(win) = app.get_webview_window("capture") {
        let _ = win.close();
    }
    Ok(())
}

#[tauri::command]
pub async fn collect_clipboard_now(
    app: AppHandle,
    target_folder_id: Option<String>,
    target_board_id: Option<String>,
) -> IpcResult<usize> {
    let fid = parse_optional_uuid(target_folder_id)?;
    let bid = parse_optional_uuid(target_board_id)?;
    collect_clipboard_into_library(&app, fid, bid)
        .await
        .map_err(native_err)
}

#[tauri::command]
pub async fn get_clipboard_preview(
    state: State<'_, AppState>,
) -> IpcResult<Option<ClipboardPreview>> {
    let fresh = tokio::task::spawn_blocking(read_initial_clipboard_preview)
        .await
        .ok()
        .flatten();
    if let Ok(mut guard) = state.latest_clipboard.lock() {
        *guard = fresh.clone();
    }
    Ok(fresh)
}

#[tauri::command]
pub fn get_desktop_integration_status(
    app: AppHandle,
    state: State<'_, AppState>,
) -> IpcResult<DesktopIntegrationStatus> {
    Ok(build_desktop_status(&app, &state))
}

#[tauri::command]
pub fn set_autostart_enabled(app: AppHandle, enabled: bool) -> IpcResult<bool> {
    let mgr = app.autolaunch();
    if enabled {
        mgr.enable().map_err(|e| native_err(e.to_string()))?;
    } else {
        mgr.disable().map_err(|e| native_err(e.to_string()))?;
    }
    Ok(mgr.is_enabled().unwrap_or(enabled))
}

#[tauri::command]
pub fn update_hotkeys(
    app: AppHandle,
    state: State<'_, AppState>,
    config: HotkeyConfig,
) -> IpcResult<HotkeyConfig> {
    register_configured_hotkeys(&app, &config).map_err(native_err)?;
    config.save(&state.data_dir);
    if let Ok(mut guard) = state.hotkeys.lock() {
        *guard = config.clone();
    }
    Ok(config)
}

#[tauri::command]
pub fn get_ocr_diagnostics() -> IpcResult<OcrDiagnostics> {
    Ok(probe_ocr_diagnostics())
}

#[tauri::command]
pub async fn run_asset_ocr(
    state: State<'_, AppState>,
    id: String,
) -> IpcResult<Option<AssetRecord>> {
    let uuid = parse_uuid(&id)?;
    Ok(state.engine.run_ocr_for_asset(uuid).await?)
}

#[tauri::command]
pub fn focus_main_window(app: AppHandle) -> IpcResult<()> {
    show_or_focus_main_window(&app);
    Ok(())
}
