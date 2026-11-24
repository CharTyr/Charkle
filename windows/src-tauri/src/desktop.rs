//! Windows desktop integration services for `src-tauri` (M3-R2, M3-R4, M3-R5):
//! - Frozen capture frame store for zero-copy `charkle-media://localhost/capture-frame/{token}`
//! - Multi-window lifecycle for Top-Edge Drop Shelf (`shelf`) and Region Capture (`capture`)
//! - Global hotkeys (`Alt+Shift+A/S/V`), System Tray, Autostart, Single-Instance, and `charkle://` deep links

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use charkle_core::models::media::CaptureInput;
use charkle_core::wire::swift_codec::format_swift_uuid;
use charkle_platform_win::capture::{
    capture_virtual_desktop, configure_capture_window_physical, CapturedDesktopFrame,
    MonitorCaptureInfo, VirtualDesktopBounds,
};
use charkle_platform_win::clipboard::{
    read_current_clipboard, read_current_clipboard_preview, ClipboardPreview, ClipboardSnapshot,
};
use charkle_platform_win::mount::detect_gdirect_binary;
use charkle_platform_win::ocr::{probe_ocr_diagnostics, OcrDiagnostics};
use charkle_platform_win::shelf_win::{
    active_shelf_screen_rect, apply_shelf_no_activate_style, configure_shelf_window_for_edge,
    default_compact_capsule_rect_for_edge, hide_shelf_native, install_shelf_drop_target,
    install_shelf_subclass, is_external_drag_active, is_shelf_window_visible,
    refresh_shelf_drop_targets, reposition_shelf_to_cursor_monitor_for_edge,
    set_shelf_allow_activate_state_only, set_shelf_hit_rect, show_shelf_no_activate,
    sync_shelf_drop_catcher, ShelfDockEdge, ShelfDropEvent, ShelfDropPayload,
};
use charkle_platform_win::windowing::{
    apply_window_chrome, install_snap_layout_subclass, BackdropKind,
};
use serde::{Deserialize, Serialize};
use tauri::menu::{Menu, MenuItem, PredefinedMenuItem};
use tauri::tray::{MouseButton, MouseButtonState, TrayIconBuilder, TrayIconEvent};
use tauri::webview::PageLoadEvent;
use tauri::{AppHandle, Emitter, Manager, WebviewUrl, WebviewWindowBuilder};
use tauri_plugin_autostart::ManagerExt as AutostartManagerExt;
use tauri_plugin_global_shortcut::{GlobalShortcutExt, ShortcutState};
use uuid::Uuid;

use crate::commands::AppState;

pub const DEFAULT_HOTKEY_CAPTURE: &str = "Alt+Shift+A";
pub const DEFAULT_HOTKEY_SHELF: &str = "Alt+Shift+S";
pub const DEFAULT_HOTKEY_CLIPBOARD: &str = "Alt+Shift+V";

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct HotkeyConfig {
    pub enabled: bool,
    pub capture_area: String,
    pub toggle_shelf: String,
    pub collect_clipboard: String,
}

impl Default for HotkeyConfig {
    fn default() -> Self {
        Self {
            enabled: true,
            capture_area: DEFAULT_HOTKEY_CAPTURE.to_string(),
            toggle_shelf: DEFAULT_HOTKEY_SHELF.to_string(),
            collect_clipboard: DEFAULT_HOTKEY_CLIPBOARD.to_string(),
        }
    }
}

fn write_json_atomic(path: &Path, json: &str) {
    if let Some(parent) = path.parent() {
        let _ = std::fs::create_dir_all(parent);
    }
    let tmp = path.with_extension("json.tmp");
    if std::fs::write(&tmp, json).is_ok() && std::fs::rename(&tmp, path).is_err() {
        let _ = std::fs::remove_file(path);
        let _ = std::fs::rename(&tmp, path);
    }
}

impl HotkeyConfig {
    pub fn load(data_dir: &Path) -> Self {
        let path = data_dir.join("hotkeys.json");
        std::fs::read_to_string(&path)
            .ok()
            .and_then(|raw| serde_json::from_str(&raw).ok())
            .unwrap_or_default()
    }

    pub fn save(&self, data_dir: &Path) {
        let path = data_dir.join("hotkeys.json");
        if let Ok(json) = serde_json::to_string_pretty(self) {
            write_json_atomic(&path, &json);
        }
    }
}

fn default_dock_edge() -> String {
    "top".to_string()
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ShelfSettings {
    pub enabled: bool,
    pub hover_trigger_enabled: bool,
    pub default_target_mode: String,
    #[serde(default)]
    pub default_folder_id: Option<String>,
    #[serde(default)]
    pub minimal_mode: bool,
    #[serde(default = "default_dock_edge")]
    pub dock_edge: String,
}

impl Default for ShelfSettings {
    fn default() -> Self {
        Self {
            enabled: true,
            hover_trigger_enabled: true,
            default_target_mode: "inbox".to_string(),
            default_folder_id: None,
            minimal_mode: false,
            dock_edge: default_dock_edge(),
        }
    }
}

impl ShelfSettings {
    pub fn load(data_dir: &Path) -> Self {
        let path = data_dir.join("shelf-settings.json");
        std::fs::read_to_string(&path)
            .ok()
            .and_then(|raw| serde_json::from_str(&raw).ok())
            .unwrap_or_default()
    }

    pub fn save(&self, data_dir: &Path) {
        let path = data_dir.join("shelf-settings.json");
        if let Ok(json) = serde_json::to_string_pretty(self) {
            write_json_atomic(&path, &json);
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CaptureSessionInfo {
    pub token: String,
    pub bounds: VirtualDesktopBounds,
    pub monitors: Vec<MonitorCaptureInfo>,
    pub width: u32,
    pub height: u32,
    pub target_folder_id: Option<String>,
    pub target_board_id: Option<String>,
}

struct StoredCaptureEntry {
    frame: Arc<CapturedDesktopFrame>,
    info: CaptureSessionInfo,
    window_label: Option<String>,
}

/// Thread-safe ephemeral store holding frozen multi-DPI capture frames served via
/// `charkle-media://localhost/capture-frame/{token}` with zero IPC base64 overhead.
#[derive(Default)]
pub struct CaptureFrameStore {
    entries: Mutex<HashMap<String, StoredCaptureEntry>>,
}

impl CaptureFrameStore {
    pub fn insert(
        &self,
        frame: CapturedDesktopFrame,
        target_folder_id: Option<String>,
        target_board_id: Option<String>,
    ) -> CaptureSessionInfo {
        let token = format_swift_uuid(&Uuid::new_v4());
        let info = CaptureSessionInfo {
            token: token.clone(),
            bounds: frame.bounds,
            monitors: frame.monitors.clone(),
            width: frame.width,
            height: frame.height,
            target_folder_id,
            target_board_id,
        };
        if let Ok(mut guard) = self.entries.lock() {
            // Keep at most 2 frames in memory to prevent RAM accumulation
            if guard.len() >= 2 {
                guard.clear();
            }
            guard.insert(
                token,
                StoredCaptureEntry {
                    frame: Arc::new(frame),
                    info: info.clone(),
                    window_label: None,
                },
            );
        }
        info
    }

    pub fn set_window_label(&self, token: &str, label: String) {
        if let Ok(mut guard) = self.entries.lock() {
            if let Some(entry) = guard.get_mut(token) {
                entry.window_label = Some(label);
            }
        }
    }

    pub fn active_window_labels(&self) -> Vec<String> {
        self.entries
            .lock()
            .ok()
            .map(|g| {
                g.values()
                    .filter_map(|e| e.window_label.clone())
                    .collect::<Vec<_>>()
            })
            .unwrap_or_default()
    }

    pub fn get_frame(&self, token: &str) -> Option<Arc<CapturedDesktopFrame>> {
        self.entries
            .lock()
            .ok()
            .and_then(|g| g.get(token).map(|e| Arc::clone(&e.frame)))
    }

    pub fn get_info(&self, token: &str) -> Option<CaptureSessionInfo> {
        self.entries
            .lock()
            .ok()
            .and_then(|g| g.get(token).map(|e| e.info.clone()))
    }

    pub fn remove(&self, token: &str) -> Option<Arc<CapturedDesktopFrame>> {
        self.entries
            .lock()
            .ok()
            .and_then(|mut g| g.remove(token).map(|e| e.frame))
    }

    pub fn remove_with_label(
        &self,
        token: &str,
    ) -> Option<(Arc<CapturedDesktopFrame>, Option<String>)> {
        self.entries
            .lock()
            .ok()
            .and_then(|mut g| g.remove(token).map(|e| (e.frame, e.window_label)))
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DesktopIntegrationStatus {
    pub hotkeys: HotkeyConfig,
    pub autostart_enabled: bool,
    pub tray_active: bool,
    pub deep_link_scheme: String,
    pub ocr: OcrDiagnostics,
    pub gdirect_path: Option<String>,
    pub shelf_visible: bool,
    pub shelf_pinned: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "action", rename_all = "camelCase")]
pub enum DeepLinkPayload {
    OpenAsset { id: String },
    OpenFolder { id: String },
    OpenBoard { id: String },
    CaptureArea,
    ToggleShelf,
}

/// Parses a `charkle://` deep-link URL into a structured action.
pub fn parse_deep_link(raw_url: &str) -> Option<DeepLinkPayload> {
    let parsed = url::Url::parse(raw_url.trim()).ok()?;
    if !parsed.scheme().eq_ignore_ascii_case("charkle") {
        return None;
    }
    let host = parsed.host_str().unwrap_or("").to_ascii_lowercase();
    let segments: Vec<&str> = parsed
        .path_segments()
        .map(|it| it.filter(|s| !s.is_empty()).collect())
        .unwrap_or_default();

    match (host.as_str(), segments.as_slice()) {
        ("capture", _) => Some(DeepLinkPayload::CaptureArea),
        ("shelf", _) => Some(DeepLinkPayload::ToggleShelf),
        ("open", ["asset", id]) | ("asset", [id]) => Some(DeepLinkPayload::OpenAsset {
            id: (*id).to_string(),
        }),
        ("open", ["folder", id]) | ("folder", [id]) => Some(DeepLinkPayload::OpenFolder {
            id: (*id).to_string(),
        }),
        ("open", ["board", id]) | ("moodboard", [id]) | ("board", [id]) => {
            Some(DeepLinkPayload::OpenBoard {
                id: (*id).to_string(),
            })
        }
        _ => None,
    }
}

fn now_epoch_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0)
}

/// Resolves the active Drop Shelf target (`folder_id`, `board_id`, and user-facing label),
/// gracefully falling back if a previously chosen folder was deleted or no board exists.
fn resolve_shelf_target(state: &AppState) -> (Option<Uuid>, Option<Uuid>, String) {
    let shelf_cfg = state
        .shelf_settings
        .lock()
        .map(|g| g.clone())
        .unwrap_or_default();

    match shelf_cfg.default_target_mode.as_str() {
        "folder" => {
            if let Ok(folders) = state.engine.fetch_folders() {
                let wanted = shelf_cfg
                    .default_folder_id
                    .as_deref()
                    .and_then(|s| Uuid::parse_str(s.trim()).ok());
                let matched = wanted
                    .and_then(|id| folders.iter().find(|f| f.id == id))
                    .or_else(|| folders.first());
                if let Some(folder) = matched {
                    return (Some(folder.id), None, folder.name.clone());
                }
            }
            (None, None, "收件箱".to_string())
        }
        "activeMoodboard" => {
            if let Ok(boards) = state.engine.fetch_boards() {
                if let Some(board) = boards.first() {
                    let label = if board.title.trim().is_empty() {
                        "活跃情绪板".to_string()
                    } else {
                        board.title.clone()
                    };
                    return (None, Some(board.id), label);
                }
            }
            (None, None, "收件箱".to_string())
        }
        _ => (None, None, "收件箱".to_string()),
    }
}

/// Applies Win11 Mica Alt backdrop, transparent clear color, Snap Layouts (`HTMAXBUTTON`),
/// and the Minimal Background Shelf Mode close-request hook onto the `"main"` window.
pub fn configure_main_window(app: &AppHandle, main_win: &tauri::WebviewWindow) {
    #[cfg(target_os = "windows")]
    if let Ok(hwnd) = main_win.hwnd() {
        let raw = hwnd.0 as isize;
        // Install the Win32 subclass BEFORE apply_window_chrome so SWP_FRAMECHANGED,
        // WM_STYLECHANGING, WM_NCPAINT, WM_NCUAHDRAWCAPTION/FRAME, and WM_NCACTIVATE are
        // guarded from Frame 0 (zero classic blue titlebar or duplicate caption buttons).
        let snap_ok = install_snap_layout_subclass(raw);
        let surface = apply_window_chrome(raw, false);
        let bg = match surface.backdrop {
            BackdropKind::Mica => tauri::window::Color(0, 0, 0, 0),
            BackdropKind::SolidFallback => tauri::window::Color(246, 246, 246, 255),
        };
        let _ = main_win.set_background_color(Some(bg));
        tracing::info!(
            build = surface.build_number,
            backdrop = ?surface.backdrop,
            transparency = surface.transparency_enabled,
            snap_ok,
            "Applied Windows chrome to main window"
        );
    }

    let app_for_close = app.clone();
    main_win.on_window_event(move |event| {
        if let tauri::WindowEvent::CloseRequested { api, .. } = event {
            let state = app_for_close.state::<AppState>();
            let explicit = state.explicit_quit.load(Ordering::SeqCst);
            let auto_minimal = state
                .shelf_settings
                .lock()
                .map(|cfg| cfg.minimal_mode)
                .unwrap_or(false);
            if auto_minimal && !explicit {
                api.prevent_close();
                enter_minimal_mode_session(&app_for_close);
            } else {
                state.explicit_quit.store(true, Ordering::SeqCst);
            }
        }
    });
}

pub fn current_shelf_dock_edge(state: &AppState) -> ShelfDockEdge {
    ShelfDockEdge::from_u8(state.shelf_dock_edge.load(Ordering::SeqCst))
}

fn emit_shelf_minimal_state(app: &AppHandle, state: &AppState) {
    let default_target = state
        .shelf_settings
        .lock()
        .map(|g| g.default_target_mode.clone())
        .unwrap_or_else(|_| "inbox".to_string());
    let edge = current_shelf_dock_edge(state);
    let payload = serde_json::json!({
        "expanded": state.shelf_expanded.load(Ordering::SeqCst),
        "pinned": state.shelf_pinned.load(Ordering::SeqCst),
        "defaultTargetMode": default_target,
        "minimalMode": state.shelf_minimal_mode.load(Ordering::SeqCst),
        "dockEdge": edge.as_str(),
    });
    // `app.emit` already broadcasts to all webviews ("main" + "shelf"); avoid emitting twice!
    let _ = app.emit("shelf:state", payload);
}

/// Tears down the `"main"` WebviewWindow to release all gallery DOM/GPU/decoded-image memory
/// while keeping System Tray + Top-Edge Drop Shelf & Recent Assets strip ready (`< 1%` idle CPU).
pub fn enter_minimal_mode_session(app: &AppHandle) {
    let state = app.state::<AppState>();
    state.shelf_minimal_mode.store(true, Ordering::SeqCst);
    emit_shelf_minimal_state(app, &state);

    let handle = app.clone();
    tauri::async_runtime::spawn(async move {
        let _ = ensure_shelf_window_async(&handle).await;
        let ui_handle = handle.clone();
        let _ = handle.run_on_main_thread(move || {
            if let Some(main_win) = ui_handle.get_webview_window("main") {
                let _ = main_win.destroy();
                tracing::info!("Entered Minimal Background Shelf Mode (destroyed main window)");
            }
            let st = ui_handle.state::<AppState>();
            emit_shelf_minimal_state(&ui_handle, &st);
        });
    });
}

/// Persists `ShelfSettings.minimal_mode` and transitions immediately into or out of Minimal Mode.
pub fn set_minimal_mode_state(app: &AppHandle, enabled: bool) -> Result<ShelfSettings, String> {
    let updated = {
        let state = app.state::<AppState>();
        let mut cfg = state
            .shelf_settings
            .lock()
            .map(|g| g.clone())
            .unwrap_or_default();
        cfg.minimal_mode = enabled;
        if enabled && !cfg.enabled {
            cfg.enabled = true;
            state.shelf_enabled.store(true, Ordering::SeqCst);
        }
        cfg.save(&state.data_dir);
        if let Ok(mut guard) = state.shelf_settings.lock() {
            *guard = cfg.clone();
        }
        cfg
    };

    let _ = app.emit("shelf:settings", &updated);
    if enabled {
        enter_minimal_mode_session(app);
    } else {
        show_or_focus_main_window(app);
    }
    Ok(updated)
}

/// Focuses the existing `"main"` window, or recreates it with full Win11 Mica Alt chrome and
/// Snap Layouts if it was destroyed by Ultra-Low-Resource Minimal Background Shelf Mode.
pub fn show_or_focus_main_window(app: &AppHandle) {
    show_or_focus_main_window_with_event(app, None);
}

/// Focuses or recreates `"main"` and guarantees delivery of an optional post-mount event
/// (e.g. `main:open-asset` or `deep-link:navigate`) even when waking from Minimal Mode.
pub fn show_or_focus_main_window_with_event(
    app: &AppHandle,
    pending_event: Option<(&'static str, serde_json::Value)>,
) {
    let state = app.state::<AppState>();
    state.shelf_minimal_mode.store(false, Ordering::SeqCst);

    if let Some(main_win) = app.get_webview_window("main") {
        let ui_handle = app.clone();
        let _ = app.run_on_main_thread(move || {
            let _ = main_win.unminimize();
            let _ = main_win.show();
            let _ = main_win.set_focus();
            let st = ui_handle.state::<AppState>();
            emit_shelf_minimal_state(&ui_handle, &st);
            if let Some((event_name, payload)) = pending_event {
                let _ = ui_handle.emit_to("main", event_name, payload);
            }
        });
        return;
    }

    // Build WebviewWindow off the Win32 main thread so WebView2 creation never deadlocks,
    // then apply Win11 Mica Alt chrome + focus on the main thread.
    let handle = app.clone();
    tauri::async_runtime::spawn(async move {
        if let Some(existing) = handle.get_webview_window("main") {
            let ui_handle = handle.clone();
            let _ = handle.run_on_main_thread(move || {
                let _ = existing.unminimize();
                let _ = existing.show();
                let _ = existing.set_focus();
                let st = ui_handle.state::<AppState>();
                emit_shelf_minimal_state(&ui_handle, &st);
                if let Some((event_name, payload)) = pending_event {
                    let _ = ui_handle.emit_to("main", event_name, payload);
                }
            });
            return;
        }

        let mut builder =
            WebviewWindowBuilder::new(&handle, "main", WebviewUrl::App("index.html".into()))
                .title("Charkle")
                .inner_size(1360.0, 860.0)
                .min_inner_size(960.0, 620.0)
                .center()
                .decorations(false)
                .transparent(false)
                .shadow(true)
                .resizable(true)
                .visible(false);

        if let Some((event_name, payload)) = pending_event {
            let delivered = Arc::new(AtomicBool::new(false));
            let emit_handle = handle.clone();
            builder = builder.on_page_load(move |_window, load_payload| {
                if load_payload.event() == PageLoadEvent::Finished
                    && !delivered.swap(true, Ordering::SeqCst)
                {
                    let app_clone = emit_handle.clone();
                    let payload_clone = payload.clone();
                    tauri::async_runtime::spawn(async move {
                        // Allow React's root effect to attach Tauri event listeners.
                        tokio::time::sleep(Duration::from_millis(260)).await;
                        let _ = app_clone.emit_to("main", event_name, payload_clone);
                    });
                }
            });
        }

        match builder.build() {
            Ok(main_win) => {
                let ui_handle = handle.clone();
                let _ = handle.run_on_main_thread(move || {
                    configure_main_window(&ui_handle, &main_win);
                    let _ = main_win.show();
                    let _ = main_win.set_focus();
                    let st = ui_handle.state::<AppState>();
                    emit_shelf_minimal_state(&ui_handle, &st);
                    tracing::info!("Recreated Charkle main window from Minimal Shelf Mode");
                });
            }
            Err(err) => {
                tracing::warn!(%err, "Failed to recreate Charkle main window");
            }
        }
    });
}

type RecentShelfDrop = Arc<Mutex<Option<(String, Instant)>>>;

fn dedup_shelf_drop(recent_drop: &RecentShelfDrop, key: String) -> bool {
    if let Ok(mut guard) = recent_drop.lock() {
        let now = Instant::now();
        if let Some((prev_key, prev_at)) = guard.as_ref() {
            if *prev_key == key && now.duration_since(*prev_at) < Duration::from_millis(600) {
                return true;
            }
        }
        *guard = Some((key, now));
    }
    false
}

fn shelf_drag_enter(drop_app: &AppHandle, count: usize, source: &str) {
    let state = drop_app.state::<AppState>();
    // Cancel any in-flight collapse timer and keep the shelf open while dragging.
    state.shelf_anim_gen.fetch_add(1, Ordering::SeqCst);
    state.shelf_drag_hovering.store(true, Ordering::SeqCst);
    state.shelf_expanded.store(true, Ordering::SeqCst);
    let count = count.max(1);
    tracing::info!(count, source, "Drop Shelf DragDrop Enter");
    let _ = drop_app.emit_to(
        "shelf",
        "shelf:drag-hover",
        serde_json::json!({ "active": true, "count": count }),
    );
}

fn shelf_drag_over(drop_app: &AppHandle) {
    let state = drop_app.state::<AppState>();
    state.shelf_anim_gen.fetch_add(1, Ordering::SeqCst);
    state.shelf_drag_hovering.store(true, Ordering::SeqCst);
    state.shelf_expanded.store(true, Ordering::SeqCst);
}

fn shelf_drag_leave(drop_app: &AppHandle) {
    let state = drop_app.state::<AppState>();
    state.shelf_drag_hovering.store(false, Ordering::SeqCst);
    let _ = drop_app.emit_to(
        "shelf",
        "shelf:drag-hover",
        serde_json::json!({ "active": false, "count": 0 }),
    );
}

fn is_hex_color_literal(raw: &str) -> bool {
    let trimmed = raw.trim();
    trimmed.len() == 7
        && trimmed.starts_with('#')
        && trimmed[1..].bytes().all(|b| b.is_ascii_hexdigit())
}

fn spawn_shelf_single_input_ingest(
    drop_app: &AppHandle,
    input: CaptureInput,
    processing_msg: &'static str,
) {
    let state = drop_app.state::<AppState>();
    state.shelf_anim_gen.fetch_add(1, Ordering::SeqCst);
    state.shelf_expanded.store(true, Ordering::SeqCst);
    state.shelf_busy.store(true, Ordering::SeqCst);
    let _ = drop_app.emit_to(
        "shelf",
        "shelf:drop-status",
        serde_json::json!({
            "phase": "processing",
            "message": processing_msg,
        }),
    );

    let handle = drop_app.clone();
    tauri::async_runtime::spawn(async move {
        let state = handle.state::<AppState>();
        let (target_folder_id, target_board_id, dest_label) = resolve_shelf_target(&state);
        let res = state
            .engine
            .ingest(vec![input], target_folder_id, target_board_id)
            .await;
        state.shelf_busy.store(false, Ordering::SeqCst);
        state
            .shelf_hold_until_ms
            .store(now_epoch_ms().saturating_add(2600), Ordering::SeqCst);

        match res {
            Ok(created) => {
                let count = created.len().max(1);
                tracing::info!(
                    count,
                    destination = %dest_label,
                    "Drop Shelf ingested dropped items"
                );
                let _ = handle.emit_to(
                    "shelf",
                    "shelf:drop-status",
                    serde_json::json!({
                        "phase": "done",
                        "message": format!("已收入「{dest_label}」({count} 项)")
                    }),
                );
            }
            Err(err) => {
                tracing::warn!(%err, "Drop Shelf ingest failed");
                let _ = handle.emit_to(
                    "shelf",
                    "shelf:drop-status",
                    serde_json::json!({
                        "phase": "error",
                        "message": format!("导入失败：{err}")
                    }),
                );
            }
        }
    });
}

fn ingest_shelf_dropped_files(
    drop_app: &AppHandle,
    paths: Vec<PathBuf>,
    recent_drop: &RecentShelfDrop,
    source: &str,
) {
    if paths.is_empty() {
        return;
    }

    let raw_paths: Vec<String> = paths
        .iter()
        .map(|p| p.to_string_lossy().into_owned())
        .collect();
    let dedup_key = format!("files:{}", raw_paths.join("\u{001f}"));
    if dedup_shelf_drop(recent_drop, dedup_key) {
        return;
    }

    let state = drop_app.state::<AppState>();
    let raw_count = raw_paths.len();
    tracing::info!(count = raw_count, source, "Drop Shelf DragDrop Drop");
    state.shelf_anim_gen.fetch_add(1, Ordering::SeqCst);
    state.shelf_expanded.store(true, Ordering::SeqCst);
    state.shelf_busy.store(true, Ordering::SeqCst);

    let _ = drop_app.emit_to(
        "shelf",
        "shelf:drop-status",
        serde_json::json!({
            "phase": "processing",
            "message": format!("正在收藏 {raw_count} 项素材…")
        }),
    );

    let handle = drop_app.clone();
    tauri::async_runtime::spawn(async move {
        let state = handle.state::<AppState>();
        let (target_folder_id, target_board_id, dest_label) = resolve_shelf_target(&state);

        let res = state
            .engine
            .ingest_local_paths(paths, target_folder_id, target_board_id)
            .await;
        state.shelf_busy.store(false, Ordering::SeqCst);
        state
            .shelf_hold_until_ms
            .store(now_epoch_ms().saturating_add(2600), Ordering::SeqCst);

        match res {
            Ok(report)
                if report.assets.is_empty()
                    && report.created_folders.is_empty()
                    && report.matched_folder_names.is_empty() =>
            {
                let _ = handle.emit_to(
                    "shelf",
                    "shelf:drop-status",
                    serde_json::json!({
                        "phase": "error",
                        "message": "未检测到可导入的文件或文件夹"
                    }),
                );
            }
            Ok(report) => {
                let count = report.assets.len();
                let message = if !report.created_folders.is_empty() {
                    if count == 0 {
                        if report.created_folders.len() == 1 {
                            format!("已建立文件夹「{}」", report.created_folders[0].name)
                        } else {
                            format!("已建立 {} 个文件夹", report.created_folders.len())
                        }
                    } else if report.matched_folder_names.len() == 1
                        && report.created_folders.len() == 1
                    {
                        format!(
                            "已建文件夹「{}」并导入 {} 项",
                            report.matched_folder_names[0], count
                        )
                    } else {
                        format!(
                            "已建 {} 个文件夹并导入 {} 项",
                            report.created_folders.len(),
                            count
                        )
                    }
                } else if !report.matched_folder_names.is_empty() {
                    if report.matched_folder_names.len() == 1 {
                        format!(
                            "已导入至文件夹「{}」({} 项)",
                            report.matched_folder_names[0], count
                        )
                    } else {
                        format!(
                            "已导入至 {} 个文件夹 ({} 项)",
                            report.matched_folder_names.len(),
                            count
                        )
                    }
                } else {
                    format!("已收入「{dest_label}」({count} 项)")
                };
                tracing::info!(
                    count,
                    created_folders = report.created_folders.len(),
                    skipped_files = report.skipped_files,
                    destination = %dest_label,
                    "Drop Shelf ingested dropped items"
                );
                let _ = handle.emit_to(
                    "shelf",
                    "shelf:drop-status",
                    serde_json::json!({
                        "phase": "done",
                        "message": message
                    }),
                );
            }
            Err(err) => {
                tracing::warn!(%err, "Drop Shelf ingest failed");
                let _ = handle.emit_to(
                    "shelf",
                    "shelf:drop-status",
                    serde_json::json!({
                        "phase": "error",
                        "message": format!("导入失败：{err}")
                    }),
                );
            }
        }
    });
}

/// Authoritative handler for our native Win32 OLE `IDropTarget` installed across the Shelf
/// root HWND and all WebView2 child HWNDs (`Chrome_WidgetWin_0/1`, `Chrome_RenderWidgetHostHWND`).
fn handle_shelf_native_drop_event(
    drop_app: &AppHandle,
    event: ShelfDropEvent,
    recent_drop: &RecentShelfDrop,
) {
    match event {
        ShelfDropEvent::Enter { count } => shelf_drag_enter(drop_app, count, "native-ole"),
        ShelfDropEvent::Over => shelf_drag_over(drop_app),
        ShelfDropEvent::Leave => shelf_drag_leave(drop_app),
        ShelfDropEvent::Drop(payload) => {
            shelf_drag_leave(drop_app);
            match payload {
                ShelfDropPayload::Files(paths) => {
                    ingest_shelf_dropped_files(drop_app, paths, recent_drop, "native-ole");
                }
                ShelfDropPayload::Url(url) => {
                    if dedup_shelf_drop(recent_drop, format!("url:{url}")) {
                        return;
                    }
                    tracing::info!(url = %url, "Drop Shelf native OLE URL drop");
                    spawn_shelf_single_input_ingest(
                        drop_app,
                        CaptureInput::WebUrl {
                            url,
                            title: None,
                            notes: None,
                        },
                        "正在收藏链接…",
                    );
                }
                ShelfDropPayload::Text(text) => {
                    if dedup_shelf_drop(recent_drop, format!("text:{text}")) {
                        return;
                    }
                    if is_hex_color_literal(&text) {
                        let hex = text.trim().to_ascii_uppercase();
                        tracing::info!(hex = %hex, "Drop Shelf native OLE color drop");
                        spawn_shelf_single_input_ingest(
                            drop_app,
                            CaptureInput::ColorSwatch { hex, title: None },
                            "正在收藏色卡…",
                        );
                    } else {
                        let title = text
                            .lines()
                            .map(str::trim)
                            .find(|l| !l.is_empty())
                            .map(|l| l.chars().take(48).collect::<String>())
                            .unwrap_or_else(|| "拖拽文本".to_string());
                        tracing::info!(
                            chars = text.chars().count(),
                            "Drop Shelf native OLE text drop"
                        );
                        spawn_shelf_single_input_ingest(
                            drop_app,
                            CaptureInput::TextSnippet {
                                title,
                                text,
                                source_url: None,
                            },
                            "正在收藏文本…",
                        );
                    }
                }
            }
        }
    }
}

/// Shared fallback handler for Tauri `WebviewEvent::DragDrop` and `WindowEvent::DragDrop`,
/// deduplicated cleanly against our native Win32 OLE `IDropTarget` via `recent_drop` (600ms).
fn handle_shelf_drag_drop(
    drop_app: &AppHandle,
    dd: &tauri::DragDropEvent,
    recent_drop: &RecentShelfDrop,
) {
    match dd {
        tauri::DragDropEvent::Enter { paths, .. } => {
            shelf_drag_enter(drop_app, paths.len(), "tauri-webview");
        }
        tauri::DragDropEvent::Over { .. } => shelf_drag_over(drop_app),
        tauri::DragDropEvent::Leave => shelf_drag_leave(drop_app),
        tauri::DragDropEvent::Drop { paths, .. } => {
            shelf_drag_leave(drop_app);
            ingest_shelf_dropped_files(drop_app, paths.clone(), recent_drop, "tauri-webview");
        }
        _ => {}
    }
}

fn attach_shelf_drag_drop_listeners(
    app: &AppHandle,
    win: &tauri::WebviewWindow,
    recent_drop: RecentShelfDrop,
) {
    // Keep deduplicated Tauri drag-drop listeners as fallback on non-Windows or top-level edges.
    let webview_drop_app = app.clone();
    let webview_recent_drop = Arc::clone(&recent_drop);
    win.on_webview_event(move |event| {
        if let tauri::WebviewEvent::DragDrop(dd) = event {
            handle_shelf_drag_drop(&webview_drop_app, dd, &webview_recent_drop);
        }
    });

    let window_drop_app = app.clone();
    win.on_window_event(move |event| {
        if let tauri::WindowEvent::DragDrop(dd) = event {
            handle_shelf_drag_drop(&window_drop_app, dd, &recent_drop);
        }
    });
}

fn build_shelf_webview_window(app: &AppHandle) -> Result<tauri::WebviewWindow, String> {
    WebviewWindowBuilder::new(app, "shelf", WebviewUrl::App("shelf.html".into()))
        .title("")
        .inner_size(1040.0, 620.0)
        .decorations(false)
        .transparent(true)
        .shadow(false)
        .resizable(false)
        .always_on_top(true)
        .skip_taskbar(true)
        .visible(false)
        .focused(false)
        .build()
        .map_err(|e| format!("Failed to create shelf window: {e}"))
}

/// Ensures the fixed transparent non-activating Top-Edge Drop Shelf window exists.
/// Safe to invoke during `.setup` on the main thread or when `"shelf"` already exists.
pub fn ensure_shelf_window(app: &AppHandle) -> Result<(), String> {
    if let Some(existing) = app.get_webview_window("shelf") {
        #[cfg(target_os = "windows")]
        if let Ok(hwnd) = existing.hwnd() {
            let state = app.state::<AppState>();
            state.shelf_hwnd.store(hwnd.0 as isize, Ordering::SeqCst);
        }
        return Ok(());
    }

    let win = build_shelf_webview_window(app)?;
    let recent_drop: RecentShelfDrop = Arc::new(Mutex::new(None));

    #[cfg(target_os = "windows")]
    if let Ok(hwnd) = win.hwnd() {
        let raw = hwnd.0 as isize;
        let state = app.state::<AppState>();
        let edge = current_shelf_dock_edge(&state);
        state.shelf_hwnd.store(raw, Ordering::SeqCst);
        // Install subclass BEFORE configure_shelf_window_for_edge so Frame-0 SWP_FRAMECHANGED is guarded.
        let _ = install_shelf_subclass(raw);
        let _ = configure_shelf_window_for_edge(raw, edge);

        let native_drop_app = app.clone();
        let native_recent_drop = Arc::clone(&recent_drop);
        let _ = app.run_on_main_thread(move || {
            let _ = install_shelf_drop_target(
                raw,
                Arc::new(move |ev| {
                    handle_shelf_native_drop_event(&native_drop_app, ev, &native_recent_drop);
                }),
            );
        });
    }

    attach_shelf_drag_drop_listeners(app, &win, recent_drop);
    Ok(())
}

static SHELF_BUILD_LOCK: OnceLock<tokio::sync::Mutex<()>> = OnceLock::new();

fn shelf_build_lock() -> &'static tokio::sync::Mutex<()> {
    SHELF_BUILD_LOCK.get_or_init(|| tokio::sync::Mutex::new(()))
}

/// Async-safe version of [`ensure_shelf_window`] for Tokio worker threads / async IPC commands.
/// Serialized by a single-flight async mutex so rapid hover/hotkey/tray opens can NEVER race to
/// construct duplicate `"shelf"` WebView2 windows.
/// Returns `Ok(true)` if the shelf window was freshly created, `Ok(false)` if it already existed.
pub async fn ensure_shelf_window_async(app: &AppHandle) -> Result<bool, String> {
    if let Some(existing) = app.get_webview_window("shelf") {
        #[cfg(target_os = "windows")]
        if let Ok(hwnd) = existing.hwnd() {
            let state = app.state::<AppState>();
            state.shelf_hwnd.store(hwnd.0 as isize, Ordering::SeqCst);
        }
        return Ok(false);
    }

    let _guard = shelf_build_lock().lock().await;
    if let Some(existing) = app.get_webview_window("shelf") {
        #[cfg(target_os = "windows")]
        if let Ok(hwnd) = existing.hwnd() {
            let state = app.state::<AppState>();
            state.shelf_hwnd.store(hwnd.0 as isize, Ordering::SeqCst);
        }
        return Ok(false);
    }

    let win = build_shelf_webview_window(app)?;
    let recent_drop: RecentShelfDrop = Arc::new(Mutex::new(None));

    #[cfg(target_os = "windows")]
    {
        let raw_opt = win.hwnd().ok().map(|h| h.0 as isize);
        if let Some(raw) = raw_opt {
            let state = app.state::<AppState>();
            let edge = current_shelf_dock_edge(&state);
            state.shelf_hwnd.store(raw, Ordering::SeqCst);

            let native_drop_app = app.clone();
            let native_recent_drop = Arc::clone(&recent_drop);
            let (tx, rx) = tokio::sync::oneshot::channel::<()>();
            let _ = app.run_on_main_thread(move || {
                let _ = install_shelf_subclass(raw);
                let _ = configure_shelf_window_for_edge(raw, edge);
                let _ = install_shelf_drop_target(
                    raw,
                    Arc::new(move |ev| {
                        handle_shelf_native_drop_event(&native_drop_app, ev, &native_recent_drop);
                    }),
                );
                let _ = tx.send(());
            });
            let _ = rx.await;
        }
    }

    attach_shelf_drag_drop_listeners(app, &win, recent_drop);
    Ok(true)
}

fn shelf_state_payload(app: &AppHandle, expanded: bool) -> serde_json::Value {
    let state = app.state::<AppState>();
    let default_target = state
        .shelf_settings
        .lock()
        .map(|g| g.default_target_mode.clone())
        .unwrap_or_else(|_| "inbox".to_string());
    let edge = current_shelf_dock_edge(&state);
    serde_json::json!({
        "expanded": expanded,
        "pinned": if expanded { state.shelf_pinned.load(Ordering::SeqCst) } else { false },
        "defaultTargetMode": default_target,
        "minimalMode": state.shelf_minimal_mode.load(Ordering::SeqCst),
        "dockEdge": edge.as_str(),
    })
}

pub fn emit_shelf_state_all(app: &AppHandle, expanded: bool) {
    let payload = shelf_state_payload(app, expanded);
    // `app.emit` broadcasts to every open webview ("main" and "shelf") once — no duplicate delivery!
    let _ = app.emit("shelf:state", payload);
}

#[cfg(target_os = "windows")]
fn spawn_delayed_shelf_drop_target_refreshes(app: &AppHandle, raw: isize) {
    let app_for_refresh = app.clone();
    tauri::async_runtime::spawn(async move {
        tokio::time::sleep(Duration::from_millis(320)).await;
        let _ = app_for_refresh.run_on_main_thread(move || {
            let _ = refresh_shelf_drop_targets(raw);
        });
    });
}

fn spawn_cold_start_shelf_reemit(app: &AppHandle, my_gen: u64) {
    let handle = app.clone();
    tauri::async_runtime::spawn(async move {
        tokio::time::sleep(Duration::from_millis(90)).await;
        let st = handle.state::<AppState>();
        if st.shelf_anim_gen.load(Ordering::SeqCst) == my_gen
            && st.shelf_expanded.load(Ordering::SeqCst)
        {
            emit_shelf_state_all(&handle, true);
        }
    });
}

/// Shows the shelf window synchronously when called on the Win32 main thread (e.g., from the
/// top-edge drag/hover monitor). If `"shelf"` has not been created yet, hands off creation to an
/// async Tokio task so the main event loop never deadlocks on `WebviewWindowBuilder::build()`.
pub fn show_shelf_window(app: &AppHandle, pinned: bool) -> Result<(), String> {
    if app.get_webview_window("shelf").is_none() {
        let handle = app.clone();
        tauri::async_runtime::spawn(async move {
            let _ = show_shelf_window_async(&handle, pinned).await;
        });
        return Ok(());
    }

    let state = app.state::<AppState>();
    state.shelf_anim_gen.fetch_add(1, Ordering::SeqCst);
    state.shelf_expanded.store(true, Ordering::SeqCst);
    state
        .shelf_hold_until_ms
        .store(now_epoch_ms().saturating_add(900), Ordering::SeqCst);
    if pinned {
        state.shelf_pinned.store(true, Ordering::SeqCst);
    }

    if let Some(win) = app.get_webview_window("shelf") {
        #[cfg(target_os = "windows")]
        if let Ok(hwnd) = win.hwnd() {
            let raw = hwnd.0 as isize;
            let edge = current_shelf_dock_edge(&state);
            state.shelf_hwnd.store(raw, Ordering::SeqCst);
            let _ = app.run_on_main_thread(move || {
                if let Ok(placement) = reposition_shelf_to_cursor_monitor_for_edge(raw, edge) {
                    set_shelf_hit_rect(
                        raw,
                        Some(default_compact_capsule_rect_for_edge(placement, edge)),
                    );
                }
                show_shelf_no_activate(raw);
                let _ = refresh_shelf_drop_targets(raw);
                if is_external_drag_active() {
                    sync_shelf_drop_catcher(raw, active_shelf_screen_rect(raw));
                }
            });
            spawn_delayed_shelf_drop_target_refreshes(app, raw);
        }
        #[cfg(not(target_os = "windows"))]
        let _ = win.show();

        emit_shelf_state_all(app, true);
    }
    Ok(())
}

async fn show_shelf_window_inner_async(
    app: &AppHandle,
    pinned: bool,
    freshly_created: bool,
) -> Result<(), String> {
    let state = app.state::<AppState>();
    let my_gen = state.shelf_anim_gen.fetch_add(1, Ordering::SeqCst) + 1;
    state.shelf_expanded.store(true, Ordering::SeqCst);
    state
        .shelf_hold_until_ms
        .store(now_epoch_ms().saturating_add(900), Ordering::SeqCst);
    if pinned {
        state.shelf_pinned.store(true, Ordering::SeqCst);
    }

    if let Some(win) = app.get_webview_window("shelf") {
        #[cfg(target_os = "windows")]
        {
            let raw_opt = win.hwnd().ok().map(|h| h.0 as isize);
            if let Some(raw) = raw_opt {
                let edge = current_shelf_dock_edge(&state);
                state.shelf_hwnd.store(raw, Ordering::SeqCst);
                let (tx, rx) = tokio::sync::oneshot::channel::<()>();
                let _ = app.run_on_main_thread(move || {
                    if let Ok(placement) = reposition_shelf_to_cursor_monitor_for_edge(raw, edge) {
                        // Seed the settled compact capsule hit-rect synchronously BEFORE showing so
                        // OS file drags immediately hit the drop well on frame 0 (never HTTRANSPARENT).
                        set_shelf_hit_rect(
                            raw,
                            Some(default_compact_capsule_rect_for_edge(placement, edge)),
                        );
                    }
                    show_shelf_no_activate(raw);
                    let _ = refresh_shelf_drop_targets(raw);
                    if is_external_drag_active() {
                        sync_shelf_drop_catcher(raw, active_shelf_screen_rect(raw));
                    }
                    let _ = tx.send(());
                });
                let _ = rx.await;
                if freshly_created {
                    spawn_delayed_shelf_drop_target_refreshes(app, raw);
                }
            }
        }
        #[cfg(not(target_os = "windows"))]
        let _ = win.show();

        emit_shelf_state_all(app, true);
        if freshly_created {
            spawn_cold_start_shelf_reemit(app, my_gen);
        }
    }
    Ok(())
}

pub async fn show_shelf_window_async(app: &AppHandle, pinned: bool) -> Result<(), String> {
    let freshly_created = ensure_shelf_window_async(app).await?;
    show_shelf_window_inner_async(app, pinned, freshly_created).await
}

pub fn hide_shelf_window_immediate(app: &AppHandle) {
    let state = app.state::<AppState>();
    state.shelf_anim_gen.fetch_add(1, Ordering::SeqCst);
    state.shelf_expanded.store(false, Ordering::SeqCst);
    state.shelf_pinned.store(false, Ordering::SeqCst);
    state.shelf_drag_hovering.store(false, Ordering::SeqCst);
    state.shelf_hold_until_ms.store(0, Ordering::SeqCst);
    let raw = state.shelf_hwnd.load(Ordering::SeqCst);
    if raw != 0 {
        set_shelf_allow_activate_state_only(raw, false);
    }
    let handle = app.clone();
    let _ = app.run_on_main_thread(move || {
        if raw != 0 {
            sync_shelf_drop_catcher(raw, None);
            apply_shelf_no_activate_style(raw, false);
            set_shelf_hit_rect(raw, None);
            hide_shelf_native(raw);
        } else if let Some(win) = handle.get_webview_window("shelf") {
            let _ = win.hide();
        }
    });
    emit_shelf_state_all(app, false);
}

async fn hide_shelf_window_immediate_async(app: &AppHandle) -> bool {
    let state = app.state::<AppState>();
    let raw = state.shelf_hwnd.load(Ordering::SeqCst);
    let was_visible =
        state.shelf_expanded.load(Ordering::SeqCst) || (raw != 0 && is_shelf_window_visible(raw));
    state.shelf_anim_gen.fetch_add(1, Ordering::SeqCst);
    state.shelf_expanded.store(false, Ordering::SeqCst);
    state.shelf_pinned.store(false, Ordering::SeqCst);
    state.shelf_drag_hovering.store(false, Ordering::SeqCst);
    state.shelf_hold_until_ms.store(0, Ordering::SeqCst);
    if raw != 0 {
        set_shelf_allow_activate_state_only(raw, false);
    }

    let handle = app.clone();
    let (tx, rx) = tokio::sync::oneshot::channel::<()>();
    let _ = app.run_on_main_thread(move || {
        if raw != 0 {
            sync_shelf_drop_catcher(raw, None);
            apply_shelf_no_activate_style(raw, false);
            set_shelf_hit_rect(raw, None);
            hide_shelf_native(raw);
        } else if let Some(win) = handle.get_webview_window("shelf") {
            let _ = win.hide();
        }
        let _ = tx.send(());
    });
    let _ = rx.await;
    emit_shelf_state_all(app, false);
    was_visible
}

pub fn hide_shelf_window(app: &AppHandle) {
    let state = app.state::<AppState>();
    let my_gen = state.shelf_anim_gen.fetch_add(1, Ordering::SeqCst) + 1;
    state.shelf_expanded.store(false, Ordering::SeqCst);
    state.shelf_pinned.store(false, Ordering::SeqCst);
    state.shelf_drag_hovering.store(false, Ordering::SeqCst);
    state.shelf_hold_until_ms.store(0, Ordering::SeqCst);

    let raw = state.shelf_hwnd.load(Ordering::SeqCst);
    if raw != 0 {
        // Update shared flag synchronously; ALWAYS dispatch Win32 style/window ops to the main UI thread!
        set_shelf_allow_activate_state_only(raw, false);
        let _ = app.run_on_main_thread(move || {
            sync_shelf_drop_catcher(raw, None);
            apply_shelf_no_activate_style(raw, false);
        });
    }

    // First trigger the smooth spring collapse back into the top bezel,
    // then hide the backing transparent HWND on the main UI thread (NEVER blocking Tokio!).
    emit_shelf_state_all(app, false);

    let app_clone = app.clone();
    tauri::async_runtime::spawn(async move {
        tokio::time::sleep(std::time::Duration::from_millis(260)).await;
        let handle = app_clone.clone();
        let _ = app_clone.run_on_main_thread(move || {
            let st = handle.state::<AppState>();
            if st.shelf_anim_gen.load(Ordering::SeqCst) != my_gen {
                return;
            }
            let hwnd_raw = st.shelf_hwnd.load(Ordering::SeqCst);
            if hwnd_raw != 0 {
                set_shelf_hit_rect(hwnd_raw, None);
                hide_shelf_native(hwnd_raw);
            } else if let Some(w) = handle.get_webview_window("shelf") {
                let _ = w.hide();
            }
        });
    });
}

pub async fn toggle_shelf_window_async(app: &AppHandle) -> Result<bool, String> {
    let freshly_created = ensure_shelf_window_async(app).await?;
    let state = app.state::<AppState>();
    let hwnd_raw = state.shelf_hwnd.load(Ordering::SeqCst);
    let currently_visible = !freshly_created
        && state.shelf_expanded.load(Ordering::SeqCst)
        && (hwnd_raw == 0 || is_shelf_window_visible(hwnd_raw));
    if currently_visible {
        hide_shelf_window(app);
        return Ok(false);
    }
    show_shelf_window_inner_async(app, true, freshly_created).await?;
    Ok(true)
}

/// Synchronously destroys the active Region Capture overlay window on the Win32 UI thread.
pub fn destroy_capture_window(app: &AppHandle, label: Option<&str>) {
    let mut labels: Vec<String> = Vec::with_capacity(2);
    if let Some(lbl) = label {
        if !lbl.is_empty() {
            labels.push(lbl.to_string());
        }
    }
    if !labels.iter().any(|l| l == "capture") {
        labels.push("capture".to_string());
    }
    let handle = app.clone();
    let _ = app.run_on_main_thread(move || {
        for lbl in labels {
            if let Some(win) = handle.get_webview_window(&lbl) {
                let _ = win.destroy();
            }
        }
    });
}

/// Freezes the multi-DPI virtual desktop off the UI thread and opens the fullscreen `capture.html`
/// crop overlay from an async Tokio task so WebView2 creation NEVER deadlocks the Win32 loop.
pub async fn launch_region_capture_async(
    app: AppHandle,
    target_folder_id: Option<String>,
    target_board_id: Option<String>,
) -> Result<CaptureSessionInfo, String> {
    // 1. Hide shelf immediately on the main thread so it never obscures the frozen screenshot.
    let shelf_was_visible = hide_shelf_window_immediate_async(&app).await;

    // 2. Cleanly destroy any stale capture overlay windows (using `destroy()`, not async `close()`).
    let mut stale_labels = {
        let state = app.state::<AppState>();
        state.capture_frames.active_window_labels()
    };
    if !stale_labels.iter().any(|l| l == "capture") {
        stale_labels.push("capture".to_string());
    }
    let existing_labels: Vec<String> = stale_labels
        .into_iter()
        .filter(|lbl| app.get_webview_window(lbl).is_some())
        .collect();
    if !existing_labels.is_empty() {
        let handle = app.clone();
        let to_destroy = existing_labels.clone();
        let (tx, rx) = tokio::sync::oneshot::channel::<()>();
        let _ = app.run_on_main_thread(move || {
            for lbl in to_destroy {
                if let Some(existing) = handle.get_webview_window(&lbl) {
                    let _ = existing.destroy();
                }
            }
            let _ = tx.send(());
        });
        let _ = rx.await;
        // Wait briefly for Tauri's window manager to deregister destroyed labels.
        tokio::time::sleep(Duration::from_millis(30)).await;
        for _ in 0..10 {
            if existing_labels
                .iter()
                .all(|lbl| app.get_webview_window(lbl).is_none())
            {
                break;
            }
            tokio::time::sleep(Duration::from_millis(15)).await;
        }
    } else if shelf_was_visible {
        // Let DWM composite one clean frame without the shelf before grabbing the desktop.
        tokio::time::sleep(Duration::from_millis(35)).await;
    }

    // 3. Capture virtual desktop OFF the UI thread via spawn_blocking.
    let frame = tokio::task::spawn_blocking(capture_virtual_desktop)
        .await
        .map_err(|e| format!("桌面截图工作线程失败：{e}"))??;

    let info = {
        let state = app.state::<AppState>();
        state
            .capture_frames
            .insert(frame, target_folder_id, target_board_id)
    };

    // 4. Build the capture WebviewWindow from this async Tokio task (NEVER inside a sync command
    // or run_on_main_thread!). Prefer canonical `"capture"` (full default capabilities), falling
    // back to a unique `"capture-<8hex>"` label if a slow OS teardown ever collides.
    let url = format!("capture.html?token={}", info.token);
    let build_overlay = |label: &str| {
        WebviewWindowBuilder::new(&app, label, WebviewUrl::App(url.clone().into()))
            .title("")
            .decorations(false)
            .transparent(true)
            .shadow(false)
            .resizable(false)
            .always_on_top(true)
            .skip_taskbar(true)
            .visible(false)
            .build()
    };

    let (active_label, win) = match build_overlay("capture") {
        Ok(win) => ("capture".to_string(), win),
        Err(first_err) => {
            let suffix: String = info.token.chars().take(8).collect();
            let fallback_label = format!("capture-{suffix}");
            tracing::warn!(
                %first_err,
                fallback = %fallback_label,
                "Canonical capture label busy; retrying with unique capture window label"
            );
            let win =
                build_overlay(&fallback_label).map_err(|e| format!("无法打开区域截图浮层：{e}"))?;
            (fallback_label, win)
        }
    };

    {
        let state = app.state::<AppState>();
        state
            .capture_frames
            .set_window_label(&info.token, active_label);
    }

    // 5. Configure physical virtual-desktop bounds & focus cleanly on the Win32 main thread.
    let bounds = info.bounds;
    let win_for_ui = win.clone();
    let (tx, rx) = tokio::sync::oneshot::channel::<()>();
    let _ = app.run_on_main_thread(move || {
        #[cfg(target_os = "windows")]
        if let Ok(hwnd) = win_for_ui.hwnd() {
            configure_capture_window_physical(hwnd.0 as isize, bounds);
        }
        #[cfg(not(target_os = "windows"))]
        let _ = win_for_ui.show();
        let _ = win_for_ui.set_focus();
        let _ = tx.send(());
    });
    let _ = rx.await;

    Ok(info)
}

/// Immediately reads the current Windows clipboard and ingests detected image / files / URL /
/// color swatch / text snippet into the library.
pub async fn collect_clipboard_into_library(
    app: &AppHandle,
    target_folder_id: Option<Uuid>,
    target_board_id: Option<Uuid>,
) -> Result<usize, String> {
    let snapshot = tokio::task::spawn_blocking(read_current_clipboard)
        .await
        .map_err(|e| format!("读取剪贴板失败：{e}"))??;

    let Some(snapshot) = snapshot else {
        return Ok(0);
    };

    let input = match snapshot {
        ClipboardSnapshot::ImagePng { png_bytes, .. } => CaptureInput::ImageData {
            data: png_bytes,
            suggested_name: format!(
                "clipboard-{}.png",
                chrono::Utc::now().format("%Y%m%d-%H%M%S")
            ),
            source_url: None,
        },
        ClipboardSnapshot::FilePaths { paths } => {
            if paths.is_empty() {
                return Ok(0);
            }
            let state = app.state::<AppState>();
            let report = state
                .engine
                .ingest_local_paths(paths, target_folder_id, target_board_id)
                .await
                .map_err(|e| e.to_string())?;
            let count = report.assets.len().max(report.created_folders.len());
            let _ = app.emit("clipboard:collected", count);
            return Ok(count);
        }
        ClipboardSnapshot::Url { url } => CaptureInput::WebUrl {
            url,
            title: None,
            notes: None,
        },
        ClipboardSnapshot::ColorHex { hex } => CaptureInput::ColorSwatch { hex, title: None },
        ClipboardSnapshot::Text { text } => {
            let title: String = text
                .lines()
                .next()
                .unwrap_or("剪贴板笔记")
                .chars()
                .take(48)
                .collect();
            CaptureInput::TextSnippet {
                title,
                text,
                source_url: None,
            }
        }
    };

    let state = app.state::<AppState>();
    let created = state
        .engine
        .ingest(vec![input], target_folder_id, target_board_id)
        .await
        .map_err(|e| e.to_string())?;
    let count = created.len();
    let _ = app.emit("clipboard:collected", count);
    Ok(count)
}

/// Collects clipboard content into the user's currently configured shelf target (used by
/// global hotkey `Alt+Shift+V` and tray action) and reports status when the shelf is visible.
pub async fn collect_clipboard_with_shelf_target(app: AppHandle) {
    let (target_folder_id, target_board_id, dest_label) = {
        let state = app.state::<AppState>();
        resolve_shelf_target(&state)
    };
    match collect_clipboard_into_library(&app, target_folder_id, target_board_id).await {
        Ok(count) if count > 0 => {
            let state = app.state::<AppState>();
            if state.shelf_expanded.load(Ordering::SeqCst) {
                state
                    .shelf_hold_until_ms
                    .store(now_epoch_ms().saturating_add(2400), Ordering::SeqCst);
                let _ = app.emit_to(
                    "shelf",
                    "shelf:drop-status",
                    serde_json::json!({
                        "phase": "done",
                        "message": format!("已收入「{dest_label}」({count} 项)")
                    }),
                );
            }
        }
        _ => {}
    }
}

pub fn handle_deep_link_url(app: &AppHandle, raw_url: &str) {
    let Some(payload) = parse_deep_link(raw_url) else {
        return;
    };
    match &payload {
        DeepLinkPayload::CaptureArea => {
            let handle = app.clone();
            tauri::async_runtime::spawn(async move {
                if let Err(err) = launch_region_capture_async(handle, None, None).await {
                    tracing::warn!(%err, "Deep-link region capture launch failed");
                }
            });
        }
        DeepLinkPayload::ToggleShelf => {
            let handle = app.clone();
            tauri::async_runtime::spawn(async move {
                if let Err(err) = toggle_shelf_window_async(&handle).await {
                    tracing::warn!(%err, "Deep-link toggle shelf failed");
                }
            });
        }
        DeepLinkPayload::OpenAsset { .. }
        | DeepLinkPayload::OpenFolder { .. }
        | DeepLinkPayload::OpenBoard { .. } => {
            if let Ok(value) = serde_json::to_value(&payload) {
                show_or_focus_main_window_with_event(app, Some(("deep-link:navigate", value)));
            } else {
                show_or_focus_main_window(app);
            }
        }
    }
}

/// Validates that no two enabled global shortcuts collide case-insensitively.
pub fn validate_hotkey_config(config: &HotkeyConfig) -> Result<(), String> {
    if !config.enabled {
        return Ok(());
    }
    let slots = [
        ("区域截图", config.capture_area.trim()),
        ("显示/隐藏顶部抽屉", config.toggle_shelf.trim()),
        ("收集剪贴板", config.collect_clipboard.trim()),
    ];
    let mut seen: HashMap<String, &'static str> = HashMap::new();
    for (label, raw) in slots {
        if raw.is_empty() {
            continue;
        }
        let normalized = raw.to_ascii_lowercase();
        if let Some(prev_label) = seen.insert(normalized, label) {
            return Err(format!(
                "快捷键「{raw}」在「{prev_label}」与「{label}」之间冲突，请设置不同的组合键。"
            ));
        }
    }
    Ok(())
}

/// Registers (or re-registers) configured system-wide shortcuts (`Alt+Shift+A/S/V`).
pub fn register_configured_hotkeys(app: &AppHandle, config: &HotkeyConfig) -> Result<(), String> {
    validate_hotkey_config(config)?;
    let gs = app.global_shortcut();
    let _ = gs.unregister_all();
    if !config.enabled {
        return Ok(());
    }

    let bindings: [(&str, &'static str, &'static str); 3] = [
        (&config.capture_area, "capture", "区域截图"),
        (&config.toggle_shelf, "shelf", "顶部抽屉"),
        (&config.collect_clipboard, "clipboard", "收集剪贴板"),
    ];

    let mut failures: Vec<String> = Vec::new();
    for (shortcut_str, action, label) in bindings {
        let trimmed = shortcut_str.trim();
        if trimmed.is_empty() {
            continue;
        }
        let action_id = action;
        if let Err(err) = gs.on_shortcut(trimmed, move |app_handle, _shortcut, event| {
            if event.state() != ShortcutState::Pressed {
                return;
            }
            match action_id {
                "capture" => {
                    let handle = app_handle.clone();
                    tauri::async_runtime::spawn(async move {
                        if let Err(err) = launch_region_capture_async(handle, None, None).await {
                            tracing::warn!(%err, "Hotkey region capture launch failed");
                        }
                    });
                }
                "shelf" => {
                    let handle = app_handle.clone();
                    tauri::async_runtime::spawn(async move {
                        if let Err(err) = toggle_shelf_window_async(&handle).await {
                            tracing::warn!(%err, "Hotkey toggle shelf failed");
                        }
                    });
                }
                "clipboard" => {
                    let handle = app_handle.clone();
                    tauri::async_runtime::spawn(collect_clipboard_with_shelf_target(handle));
                }
                _ => {}
            }
        }) {
            tracing::warn!(shortcut = trimmed, %err, "Failed to register global hotkey");
            failures.push(format!("{label}（{trimmed}）：{err}"));
        }
    }
    if !failures.is_empty() {
        return Err(format!(
            "全局快捷键注册失败（可能语法无效或被其他应用占用）：{}",
            failures.join("；")
        ));
    }
    Ok(())
}

/// Installs the Windows System Tray icon and native quick-action context menu.
pub fn setup_system_tray(app: &AppHandle) -> Result<(), String> {
    let open_item = MenuItem::with_id(app, "tray:open", "打开 Charkle", true, None::<&str>)
        .map_err(|e| e.to_string())?;
    let shelf_item = MenuItem::with_id(
        app,
        "tray:shelf",
        "显示 / 隐藏顶部抽屉 (Alt+Shift+S)",
        true,
        None::<&str>,
    )
    .map_err(|e| e.to_string())?;
    let minimal_item = MenuItem::with_id(
        app,
        "tray:minimal",
        "极简低占用后台模式（仅保留顶部抽屉）",
        true,
        None::<&str>,
    )
    .map_err(|e| e.to_string())?;
    let capture_item = MenuItem::with_id(
        app,
        "tray:capture",
        "区域截图采集 (Alt+Shift+A)",
        true,
        None::<&str>,
    )
    .map_err(|e| e.to_string())?;
    let clip_item = MenuItem::with_id(
        app,
        "tray:clipboard",
        "快速采集剪贴板 (Alt+Shift+V)",
        true,
        None::<&str>,
    )
    .map_err(|e| e.to_string())?;
    let sep1 = PredefinedMenuItem::separator(app).map_err(|e| e.to_string())?;
    let sync_item = MenuItem::with_id(app, "tray:sync", "立即同步素材库", true, None::<&str>)
        .map_err(|e| e.to_string())?;
    let sep2 = PredefinedMenuItem::separator(app).map_err(|e| e.to_string())?;
    let quit_item = MenuItem::with_id(app, "tray:quit", "退出 Charkle", true, None::<&str>)
        .map_err(|e| e.to_string())?;

    let menu = Menu::with_items(
        app,
        &[
            &open_item,
            &shelf_item,
            &minimal_item,
            &capture_item,
            &clip_item,
            &sep1,
            &sync_item,
            &sep2,
            &quit_item,
        ],
    )
    .map_err(|e| e.to_string())?;

    let mut builder = TrayIconBuilder::with_id("charkle-tray")
        .menu(&menu)
        .tooltip("Charkle")
        .show_menu_on_left_click(false)
        .on_menu_event(|app_handle, event| match event.id().as_ref() {
            "tray:open" => show_or_focus_main_window(app_handle),
            "tray:shelf" => {
                let handle = app_handle.clone();
                tauri::async_runtime::spawn(async move {
                    if let Err(err) = toggle_shelf_window_async(&handle).await {
                        tracing::warn!(%err, "Tray toggle shelf failed");
                    }
                });
            }
            "tray:minimal" => {
                let _ = set_minimal_mode_state(app_handle, true);
            }
            "tray:capture" => {
                let handle = app_handle.clone();
                tauri::async_runtime::spawn(async move {
                    if let Err(err) = launch_region_capture_async(handle, None, None).await {
                        tracing::warn!(%err, "Tray region capture launch failed");
                    }
                });
            }
            "tray:clipboard" => {
                let handle = app_handle.clone();
                tauri::async_runtime::spawn(collect_clipboard_with_shelf_target(handle));
            }
            "tray:sync" => {
                let handle = app_handle.clone();
                tauri::async_runtime::spawn(async move {
                    let state = handle.state::<AppState>();
                    let _ = state.engine.sync_now().await;
                });
            }
            "tray:quit" => {
                let state = app_handle.state::<AppState>();
                state.explicit_quit.store(true, Ordering::SeqCst);
                app_handle.exit(0);
            }
            _ => {}
        })
        .on_tray_icon_event(|tray, event| {
            if let TrayIconEvent::Click {
                button: MouseButton::Left,
                button_state: MouseButtonState::Up,
                ..
            } = event
            {
                show_or_focus_main_window(tray.app_handle());
            }
        });

    if let Some(icon) = app.default_window_icon() {
        builder = builder.icon(icon.clone());
    }

    builder.build(app).map_err(|e| e.to_string())?;
    Ok(())
}

pub fn build_desktop_status(app: &AppHandle, state: &AppState) -> DesktopIntegrationStatus {
    let hotkeys = state.hotkeys.lock().map(|g| g.clone()).unwrap_or_default();
    let autostart_enabled = app.autolaunch().is_enabled().unwrap_or(false);
    let hwnd_raw = state.shelf_hwnd.load(Ordering::SeqCst);
    let shelf_visible = state.shelf_expanded.load(Ordering::SeqCst)
        && (hwnd_raw == 0 || is_shelf_window_visible(hwnd_raw));
    let shelf_pinned = state.shelf_pinned.load(Ordering::SeqCst);

    DesktopIntegrationStatus {
        hotkeys,
        autostart_enabled,
        tray_active: app.tray_by_id("charkle-tray").is_some(),
        deep_link_scheme: "charkle".to_string(),
        ocr: probe_ocr_diagnostics(),
        gdirect_path: detect_gdirect_binary().map(|p| p.to_string_lossy().into_owned()),
        shelf_visible,
        shelf_pinned,
    }
}

pub fn read_initial_clipboard_preview() -> Option<ClipboardPreview> {
    read_current_clipboard_preview().ok().flatten()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_charkle_deep_link_routes() {
        assert_eq!(
            parse_deep_link("charkle://open/asset/20000000-0000-4000-8000-000000000001"),
            Some(DeepLinkPayload::OpenAsset {
                id: "20000000-0000-4000-8000-000000000001".to_string()
            })
        );
        assert_eq!(
            parse_deep_link("charkle://open/folder/10000000-0000-4000-8000-000000000001"),
            Some(DeepLinkPayload::OpenFolder {
                id: "10000000-0000-4000-8000-000000000001".to_string()
            })
        );
        assert_eq!(
            parse_deep_link("charkle://open/board/40000000-0000-4000-8000-000000000001"),
            Some(DeepLinkPayload::OpenBoard {
                id: "40000000-0000-4000-8000-000000000001".to_string()
            })
        );
        assert_eq!(
            parse_deep_link("charkle://capture"),
            Some(DeepLinkPayload::CaptureArea)
        );
        assert_eq!(
            parse_deep_link("charkle://shelf"),
            Some(DeepLinkPayload::ToggleShelf)
        );
        assert_eq!(parse_deep_link("https://example.com"), None);
    }

    #[test]
    fn shelf_settings_minimal_mode_and_dock_edge_default_and_round_trip() {
        let legacy_json =
            r#"{"enabled":true,"hoverTriggerEnabled":true,"defaultTargetMode":"inbox"}"#;
        let decoded: ShelfSettings = serde_json::from_str(legacy_json).expect("decode legacy");
        assert!(!decoded.minimal_mode);
        assert_eq!(decoded.dock_edge, "top");

        for (edge, expected_enum) in [
            ("top", ShelfDockEdge::Top),
            ("left", ShelfDockEdge::Left),
            ("right", ShelfDockEdge::Right),
        ] {
            assert_eq!(
                serde_json::to_string(&expected_enum).expect("serialize enum"),
                format!("\"{edge}\"")
            );
            let decoded_enum: ShelfDockEdge =
                serde_json::from_str(&format!("\"{edge}\"")).expect("deserialize enum");
            assert_eq!(decoded_enum, expected_enum);

            let updated = ShelfSettings {
                minimal_mode: true,
                dock_edge: edge.to_string(),
                ..decoded.clone()
            };
            let encoded = serde_json::to_string(&updated).expect("encode");
            assert!(encoded.contains("\"minimalMode\":true"));
            assert!(encoded.contains(&format!("\"dockEdge\":\"{edge}\"")));
            let roundtrip: ShelfSettings = serde_json::from_str(&encoded).expect("roundtrip");
            assert!(roundtrip.minimal_mode);
            assert_eq!(roundtrip.dock_edge, edge);
        }
    }

    #[test]
    fn capture_frame_store_tracks_and_removes_window_labels() {
        let store = CaptureFrameStore::default();
        let frame = CapturedDesktopFrame {
            bounds: VirtualDesktopBounds {
                left: 0,
                top: 0,
                width: 4,
                height: 4,
            },
            monitors: Vec::new(),
            width: 4,
            height: 4,
            rgba: vec![0u8; 64],
            png_bytes: Vec::new(),
        };
        let info = store.insert(frame, None, None);
        assert!(store.active_window_labels().is_empty());

        store.set_window_label(&info.token, "capture-12345678".to_string());
        assert_eq!(
            store.active_window_labels(),
            vec!["capture-12345678".to_string()]
        );

        let (_removed_frame, label) = store.remove_with_label(&info.token).expect("entry");
        assert_eq!(label.as_deref(), Some("capture-12345678"));
        assert!(store.active_window_labels().is_empty());
    }

    #[test]
    fn default_capabilities_allow_fallback_capture_windows() {
        let cap: serde_json::Value =
            serde_json::from_str(include_str!("../capabilities/default.json"))
                .expect("valid default capability json");
        let windows: Vec<&str> = cap["windows"]
            .as_array()
            .expect("windows array")
            .iter()
            .filter_map(serde_json::Value::as_str)
            .collect();
        assert!(windows.contains(&"main"));
        assert!(windows.contains(&"shelf"));
        assert!(windows.contains(&"capture"));
        assert!(windows.contains(&"capture-*"));
    }

    #[test]
    fn validate_hotkey_config_rejects_case_insensitive_duplicates() {
        let dup = HotkeyConfig {
            enabled: true,
            capture_area: "Alt+Shift+A".to_string(),
            toggle_shelf: "alt+shift+a".to_string(),
            collect_clipboard: "Alt+Shift+V".to_string(),
        };
        assert!(validate_hotkey_config(&dup).is_err());

        let disabled_dup = HotkeyConfig {
            enabled: false,
            ..dup
        };
        assert!(validate_hotkey_config(&disabled_dup).is_ok());

        assert!(validate_hotkey_config(&HotkeyConfig::default()).is_ok());
    }

    #[test]
    fn hotkey_and_shelf_settings_atomic_save_round_trip() {
        let tmp = tempfile::tempdir().expect("tempdir");
        let hk = HotkeyConfig {
            enabled: true,
            capture_area: "Ctrl+Alt+1".to_string(),
            toggle_shelf: "Ctrl+Alt+2".to_string(),
            collect_clipboard: "Ctrl+Alt+3".to_string(),
        };
        hk.save(tmp.path());
        let loaded_hk = HotkeyConfig::load(tmp.path());
        assert_eq!(loaded_hk.capture_area, "Ctrl+Alt+1");
        assert!(!tmp.path().join("hotkeys.json.tmp").exists());

        let shelf = ShelfSettings {
            enabled: false,
            hover_trigger_enabled: false,
            default_target_mode: "folder".to_string(),
            default_folder_id: Some("10000000-0000-4000-8000-000000000001".to_string()),
            minimal_mode: true,
            dock_edge: "right".to_string(),
        };
        shelf.save(tmp.path());
        let loaded_shelf = ShelfSettings::load(tmp.path());
        assert!(loaded_shelf.minimal_mode);
        assert_eq!(loaded_shelf.dock_edge, "right");
        assert_eq!(
            loaded_shelf.default_folder_id.as_deref(),
            Some("10000000-0000-4000-8000-000000000001")
        );
        assert!(!tmp.path().join("shelf-settings.json.tmp").exists());
    }
}
