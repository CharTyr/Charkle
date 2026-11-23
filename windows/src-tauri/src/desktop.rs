//! Windows desktop integration services for `src-tauri` (M3-R2, M3-R4, M3-R5):
//! - Frozen capture frame store for zero-copy `charkle-media://localhost/capture-frame/{token}`
//! - Multi-window lifecycle for Top-Edge Drop Shelf (`shelf`) and Region Capture (`capture`)
//! - Global hotkeys (`Alt+Shift+A/S/V`), System Tray, Autostart, Single-Instance, and `charkle://` deep links

use std::collections::HashMap;
use std::path::Path;
use std::sync::atomic::Ordering;
use std::sync::{Arc, Mutex};

use charkle_core::models::media::CaptureInput;
use charkle_core::wire::swift_codec::format_swift_uuid;
use charkle_platform_win::capture::{
    capture_virtual_desktop, CapturedDesktopFrame, MonitorCaptureInfo, VirtualDesktopBounds,
};
use charkle_platform_win::clipboard::{
    read_current_clipboard, ClipboardPreview, ClipboardSnapshot,
};
use charkle_platform_win::mount::detect_gdirect_binary;
use charkle_platform_win::ocr::{probe_ocr_diagnostics, OcrDiagnostics};
use charkle_platform_win::shelf_win::{
    configure_shelf_window, install_shelf_subclass, reposition_shelf_to_cursor_monitor,
    set_shelf_hit_rect,
};
use serde::{Deserialize, Serialize};
use tauri::menu::{Menu, MenuItem, PredefinedMenuItem};
use tauri::tray::{MouseButton, MouseButtonState, TrayIconBuilder, TrayIconEvent};
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
            let _ = std::fs::write(path, json);
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
                },
            );
        }
        info
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

pub fn show_or_focus_main_window(app: &AppHandle) {
    if let Some(main_win) = app.get_webview_window("main") {
        let _ = main_win.unminimize();
        let _ = main_win.show();
        let _ = main_win.set_focus();
    }
}

/// Ensures the fixed transparent non-activating Top-Edge Drop Shelf window exists.
pub fn ensure_shelf_window(app: &AppHandle) -> Result<(), String> {
    if app.get_webview_window("shelf").is_some() {
        return Ok(());
    }

    let win = WebviewWindowBuilder::new(app, "shelf", WebviewUrl::App("shelf.html".into()))
        .title("Charkle Shelf")
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
        .map_err(|e| format!("Failed to create shelf window: {e}"))?;

    #[cfg(target_os = "windows")]
    if let Ok(hwnd) = win.hwnd() {
        let raw = hwnd.0 as isize;
        let _ = configure_shelf_window(raw);
        let _ = install_shelf_subclass(raw);
    }
    let _ = win;
    Ok(())
}

pub fn show_shelf_window(app: &AppHandle, pinned: bool) -> Result<(), String> {
    ensure_shelf_window(app)?;
    let state = app.state::<AppState>();
    if pinned {
        state.shelf_pinned.store(true, Ordering::SeqCst);
    }
    if let Some(win) = app.get_webview_window("shelf") {
        #[cfg(target_os = "windows")]
        if let Ok(hwnd) = win.hwnd() {
            let _ = reposition_shelf_to_cursor_monitor(hwnd.0 as isize);
        }
        let _ = win.show();
        let _ = app.emit(
            "shelf:state",
            serde_json::json!({
                "expanded": true,
                "pinned": state.shelf_pinned.load(Ordering::SeqCst),
            }),
        );
    }
    Ok(())
}

pub fn hide_shelf_window(app: &AppHandle) {
    let state = app.state::<AppState>();
    state.shelf_pinned.store(false, Ordering::SeqCst);
    if let Some(win) = app.get_webview_window("shelf") {
        #[cfg(target_os = "windows")]
        if let Ok(hwnd) = win.hwnd() {
            set_shelf_hit_rect(hwnd.0 as isize, None);
        }
        let _ = win.hide();
        let _ = app.emit(
            "shelf:state",
            serde_json::json!({ "expanded": false, "pinned": false }),
        );
    }
}

pub fn toggle_shelf_window(app: &AppHandle) -> Result<bool, String> {
    ensure_shelf_window(app)?;
    if let Some(win) = app.get_webview_window("shelf") {
        let currently_visible = win.is_visible().unwrap_or(false);
        if currently_visible {
            hide_shelf_window(app);
            return Ok(false);
        }
        show_shelf_window(app, true)?;
        return Ok(true);
    }
    Ok(false)
}

/// Freezes the multi-DPI virtual desktop and opens the fullscreen `capture.html` crop overlay.
pub fn launch_region_capture(
    app: &AppHandle,
    target_folder_id: Option<String>,
    target_board_id: Option<String>,
) -> Result<CaptureSessionInfo, String> {
    // Hide shelf if open so it does not obscure the screenshot
    hide_shelf_window(app);

    let frame = capture_virtual_desktop()?;
    let state = app.state::<AppState>();
    let info = state
        .capture_frames
        .insert(frame, target_folder_id, target_board_id);

    // Close any stale capture overlay before creating fresh fullscreen window
    if let Some(existing) = app.get_webview_window("capture") {
        let _ = existing.close();
    }

    let url = format!("capture.html?token={}", info.token);
    let win = WebviewWindowBuilder::new(app, "capture", WebviewUrl::App(url.into()))
        .title("Charkle Capture")
        .decorations(false)
        .transparent(true)
        .shadow(false)
        .resizable(false)
        .always_on_top(true)
        .skip_taskbar(true)
        .position(info.bounds.left as f64, info.bounds.top as f64)
        .inner_size(info.bounds.width as f64, info.bounds.height as f64)
        .build()
        .map_err(|e| format!("Failed to create capture overlay window: {e}"))?;

    let _ = win.set_focus();
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
        .map_err(|e| format!("Clipboard reader failed: {e}"))??;

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
            let state = app.state::<AppState>();
            let inputs: Vec<CaptureInput> = paths
                .into_iter()
                .filter(|p| p.is_file())
                .map(CaptureInput::FilePath)
                .collect();
            if inputs.is_empty() {
                return Ok(0);
            }
            let created = state
                .engine
                .ingest(inputs, target_folder_id, target_board_id)
                .await
                .map_err(|e| e.to_string())?;
            let count = created.len();
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

pub fn handle_deep_link_url(app: &AppHandle, raw_url: &str) {
    let Some(payload) = parse_deep_link(raw_url) else {
        return;
    };
    match &payload {
        DeepLinkPayload::CaptureArea => {
            let _ = launch_region_capture(app, None, None);
        }
        DeepLinkPayload::ToggleShelf => {
            let _ = toggle_shelf_window(app);
        }
        DeepLinkPayload::OpenAsset { .. }
        | DeepLinkPayload::OpenFolder { .. }
        | DeepLinkPayload::OpenBoard { .. } => {
            show_or_focus_main_window(app);
            let _ = app.emit("deep-link:navigate", &payload);
        }
    }
}

/// Registers (or re-registers) configured system-wide shortcuts (`Alt+Shift+A/S/V`).
pub fn register_configured_hotkeys(app: &AppHandle, config: &HotkeyConfig) -> Result<(), String> {
    let gs = app.global_shortcut();
    let _ = gs.unregister_all();
    if !config.enabled {
        return Ok(());
    }

    let bindings: [(&str, &'static str); 3] = [
        (&config.capture_area, "capture"),
        (&config.toggle_shelf, "shelf"),
        (&config.collect_clipboard, "clipboard"),
    ];

    for (shortcut_str, action) in bindings {
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
                    let _ = launch_region_capture(app_handle, None, None);
                }
                "shelf" => {
                    let _ = toggle_shelf_window(app_handle);
                }
                "clipboard" => {
                    let handle = app_handle.clone();
                    tauri::async_runtime::spawn(async move {
                        let _ = collect_clipboard_into_library(&handle, None, None).await;
                    });
                }
                _ => {}
            }
        }) {
            tracing::warn!(shortcut = trimmed, %err, "Failed to register global hotkey");
        }
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
        .tooltip("Charkle — 灵感素材库")
        .show_menu_on_left_click(false)
        .on_menu_event(|app_handle, event| match event.id().as_ref() {
            "tray:open" => show_or_focus_main_window(app_handle),
            "tray:shelf" => {
                let _ = toggle_shelf_window(app_handle);
            }
            "tray:capture" => {
                let _ = launch_region_capture(app_handle, None, None);
            }
            "tray:clipboard" => {
                let handle = app_handle.clone();
                tauri::async_runtime::spawn(async move {
                    let _ = collect_clipboard_into_library(&handle, None, None).await;
                });
            }
            "tray:sync" => {
                let handle = app_handle.clone();
                tauri::async_runtime::spawn(async move {
                    let state = handle.state::<AppState>();
                    let _ = state.engine.sync_now().await;
                });
            }
            "tray:quit" => {
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
    let shelf_visible = app
        .get_webview_window("shelf")
        .and_then(|w| w.is_visible().ok())
        .unwrap_or(false);
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
    read_current_clipboard()
        .ok()
        .flatten()
        .map(|s| s.to_preview())
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
}
