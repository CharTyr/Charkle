//! M3 native Windows desktop IPC commands:
//! Top-Edge Drop Shelf, OLE outbound drag (`DoDragDrop`), Multi-DPI Region Capture,
//! Clipboard Collector, Global Hotkeys, Autostart, and offline WinRT OCR.

use std::path::PathBuf;
use std::sync::atomic::Ordering;

use charkle_core::models::core::AssetRecord;
use charkle_core::models::media::{CaptureInput, ThumbnailTier};
use charkle_platform_win::capture::crop_captured_frame;
use charkle_platform_win::clipboard::{copy_files_to_clipboard, ClipboardPreview};
use charkle_platform_win::drag_out::{run_outbound_file_drag_on_ui_thread, DragOutOutcome};
use charkle_platform_win::ocr::{probe_ocr_diagnostics, OcrDiagnostics};
use charkle_platform_win::shelf_win::{
    refresh_shelf_drop_targets, set_shelf_allow_activate as win_set_shelf_allow_activate,
    set_shelf_hit_rect as win_set_shelf_hit_rect,
};
use charkle_platform_win::windowing::ClientRect;
use tauri::{AppHandle, Emitter, State};
use tauri_plugin_autostart::ManagerExt as AutostartManagerExt;

use crate::commands::{parse_optional_uuid, parse_uuid, AppState, IpcError, IpcResult};
use crate::desktop::{
    build_desktop_status, collect_clipboard_into_library, destroy_capture_window,
    hide_shelf_window, launch_region_capture_async, read_initial_clipboard_preview,
    register_configured_hotkeys, set_minimal_mode_state, show_or_focus_main_window,
    show_or_focus_main_window_with_event, show_shelf_window_async, toggle_shelf_window_async,
    CaptureSessionInfo, DesktopIntegrationStatus, HotkeyConfig, ShelfSettings,
};

fn native_err(message: impl Into<String>) -> IpcError {
    IpcError {
        code: "NATIVE_WIN_ERROR",
        message: message.into(),
    }
}

#[tauri::command]
pub async fn start_outbound_drag(
    app: AppHandle,
    window: tauri::WebviewWindow,
    state: State<'_, AppState>,
    asset_ids: Vec<String>,
) -> IpcResult<DragOutOutcome> {
    let mut paths: Vec<PathBuf> = Vec::with_capacity(asset_ids.len());
    let mut preview_path: Option<PathBuf> = None;

    for raw in asset_ids {
        let id = parse_uuid(&raw)?;
        if let Some(asset) = state.engine.fetch_asset(id)? {
            let thumb = state
                .engine
                .cached_thumbnail_path(id, ThumbnailTier::Grid520)
                .or_else(|| {
                    state
                        .engine
                        .cached_thumbnail_path(id, ThumbnailTier::Preview1400)
                });
            if preview_path.is_none() {
                preview_path = thumb.clone();
            }
            if let Some(local_path) = state.engine.cached_original_path(&asset) {
                paths.push(local_path);
            } else if let Some(fallback_thumb) = state
                .engine
                .cached_thumbnail_path(id, ThumbnailTier::Preview1400)
                .or(thumb)
            {
                // Fallback to cached preview image when original is remote-only or bookmark card
                paths.push(fallback_thumb);
            }
        }
    }
    if paths.is_empty() {
        return Err(native_err("所选素材尚未缓存在本地磁盘，无法拖出到外部应用"));
    }

    let is_shelf = window.label() == "shelf";
    if is_shelf {
        state.shelf_busy.store(true, Ordering::SeqCst);
    }
    let shelf_hwnd_raw = state.shelf_hwnd.load(Ordering::SeqCst);
    let (tx, rx) = tokio::sync::oneshot::channel();
    let dispatch = app.run_on_main_thread(move || {
        #[cfg(target_os = "windows")]
        let source_hwnd = if is_shelf && shelf_hwnd_raw != 0 {
            shelf_hwnd_raw
        } else {
            window.hwnd().map(|h| h.0 as isize).unwrap_or(0)
        };
        #[cfg(not(target_os = "windows"))]
        let source_hwnd = 0isize;

        let res = run_outbound_file_drag_on_ui_thread(
            &paths,
            preview_path.as_deref(),
            source_hwnd,
            is_shelf,
        );
        let _ = tx.send(res);
    });
    if let Err(e) = dispatch {
        if is_shelf {
            state.shelf_busy.store(false, Ordering::SeqCst);
        }
        return Err(native_err(format!("拖出文件启动失败：{e}")));
    }

    let outcome = rx
        .await
        .map_err(|_| native_err("拖出会话意外中断"))
        .and_then(|r| r.map_err(native_err));
    if is_shelf {
        state.shelf_busy.store(false, Ordering::SeqCst);
    }
    outcome
}

#[tauri::command]
pub fn set_shelf_hit_rect(
    app: AppHandle,
    state: State<'_, AppState>,
    rect: Option<ClientRect>,
) -> IpcResult<()> {
    // Never let a stale collapsed initial React render wipe the frame-0 pre-seeded hit rect
    // while the shelf is already marked expanded on the Rust side.
    if rect.is_none() && state.shelf_expanded.load(Ordering::SeqCst) {
        return Ok(());
    }
    let raw = state.shelf_hwnd.load(Ordering::SeqCst);
    if raw != 0 {
        win_set_shelf_hit_rect(raw, rect);
        if rect.is_some() {
            let _ = app.run_on_main_thread(move || {
                let _ = refresh_shelf_drop_targets(raw);
            });
        }
    }
    Ok(())
}

#[tauri::command]
pub async fn toggle_shelf(app: AppHandle) -> IpcResult<bool> {
    toggle_shelf_window_async(&app).await.map_err(native_err)
}

#[tauri::command]
pub async fn show_shelf(app: AppHandle, pinned: Option<bool>) -> IpcResult<()> {
    show_shelf_window_async(&app, pinned.unwrap_or(false))
        .await
        .map_err(native_err)
}

#[tauri::command]
pub async fn hide_shelf(app: AppHandle) -> IpcResult<()> {
    hide_shelf_window(&app);
    Ok(())
}

#[tauri::command]
pub fn set_shelf_pinned(state: State<'_, AppState>, pinned: bool) -> IpcResult<bool> {
    state.shelf_pinned.store(pinned, Ordering::SeqCst);
    Ok(pinned)
}

#[tauri::command]
pub async fn start_region_capture(
    app: AppHandle,
    target_folder_id: Option<String>,
    target_board_id: Option<String>,
) -> IpcResult<CaptureSessionInfo> {
    launch_region_capture_async(app, target_folder_id, target_board_id)
        .await
        .map_err(native_err)
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
    let (frame, window_label) = state
        .capture_frames
        .remove_with_label(&token)
        .ok_or_else(|| native_err("Capture frame not found or already closed"))?;

    destroy_capture_window(&app, window_label.as_deref());

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
    let window_label = state
        .capture_frames
        .remove_with_label(&token)
        .and_then(|(_, label)| label);
    destroy_capture_window(&app, window_label.as_deref());
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
    let previous = state.hotkeys.lock().ok().map(|g| g.clone());
    if let Err(err) = register_configured_hotkeys(&app, &config) {
        if let Some(prev) = previous {
            let _ = register_configured_hotkeys(&app, &prev);
        }
        return Err(native_err(err));
    }
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

#[tauri::command]
pub fn open_main_window(app: AppHandle) -> IpcResult<()> {
    show_or_focus_main_window(&app);
    Ok(())
}

#[tauri::command]
pub fn set_minimal_mode(app: AppHandle, enabled: bool) -> IpcResult<ShelfSettings> {
    set_minimal_mode_state(&app, enabled).map_err(native_err)
}

#[tauri::command]
pub fn open_asset_in_main_window(
    app: AppHandle,
    state: State<'_, AppState>,
    asset_id: String,
    open_quick_look: Option<bool>,
) -> IpcResult<()> {
    if state.shelf_expanded.load(Ordering::SeqCst) {
        hide_shelf_window(&app);
    }
    show_or_focus_main_window_with_event(
        &app,
        Some((
            "main:open-asset",
            serde_json::json!({
                "assetId": asset_id,
                "openQuickLook": open_quick_look.unwrap_or(true),
            }),
        )),
    );
    Ok(())
}

#[tauri::command]
pub async fn copy_assets_to_clipboard(
    state: State<'_, AppState>,
    asset_ids: Vec<String>,
) -> IpcResult<usize> {
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
        return Err(native_err(
            "所选素材尚未缓存在本地磁盘，无法复制文件到剪贴板",
        ));
    }
    tokio::task::spawn_blocking(move || copy_files_to_clipboard(&paths))
        .await
        .map_err(|e| native_err(format!("Clipboard worker failed: {e}")))?
        .map_err(native_err)
}

#[tauri::command]
pub fn get_shelf_settings(state: State<'_, AppState>) -> IpcResult<ShelfSettings> {
    Ok(state
        .shelf_settings
        .lock()
        .map(|g| g.clone())
        .unwrap_or_default())
}

#[tauri::command]
pub fn save_shelf_settings(
    app: AppHandle,
    state: State<'_, AppState>,
    settings: ShelfSettings,
) -> IpcResult<ShelfSettings> {
    state
        .shelf_enabled
        .store(settings.enabled, Ordering::SeqCst);
    state
        .shelf_hover_trigger
        .store(settings.hover_trigger_enabled, Ordering::SeqCst);
    if !settings.enabled {
        hide_shelf_window(&app);
    }
    settings.save(&state.data_dir);
    if let Ok(mut guard) = state.shelf_settings.lock() {
        *guard = settings.clone();
    }
    let _ = app.emit("shelf:settings", &settings);
    Ok(settings)
}

#[tauri::command]
pub fn set_shelf_allow_activate(state: State<'_, AppState>, allow: bool) -> IpcResult<()> {
    let raw = state.shelf_hwnd.load(Ordering::SeqCst);
    if raw != 0 {
        win_set_shelf_allow_activate(raw, allow);
    }
    Ok(())
}
