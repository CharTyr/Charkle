use charkle_platform_win::windowing::{
    apply_window_chrome, register_surface_change_callback, update_maximize_button_rect,
    BackdropKind, ClientRect, WindowSurfaceState,
};
use tauri::window::Color;
use tauri::{Emitter, Manager, WebviewWindow};

use super::{IpcError, IpcResult};

/// Tauri event emitted to the main `WebviewWindow` whenever Windows OS theme, transparency,
/// animation, or DWM system accent settings change live.
pub const SURFACE_CHANGED_EVENT: &str = "charkle://surface-changed";

#[cfg(target_os = "windows")]
fn raw_hwnd(window: &WebviewWindow) -> isize {
    window.hwnd().map(|h| h.0 as isize).unwrap_or(0)
}

#[cfg(not(target_os = "windows"))]
fn raw_hwnd(_window: &WebviewWindow) -> isize {
    0
}

/// Registers (or refreshes) the Win32 surface-change callback on `window` so live OS theme,
/// transparency, animation, and accent-color notifications emit `charkle://surface-changed`
/// with the fresh `WindowSurfaceState` to that window.
///
/// The actual Tauri event emission is queued onto the main thread (`run_on_main_thread`) so it
/// executes cleanly outside synchronous Win32 broadcast `SendMessage` (`WM_SETTINGCHANGE` /
/// `WM_DWMCOLORIZATIONCOLORCHANGED`) contexts. Callback entries are removed automatically on
/// `WM_NCDESTROY`.
pub fn attach_surface_change_emitter(window: &WebviewWindow) {
    let hwnd = raw_hwnd(window);
    if hwnd == 0 {
        return;
    }
    let app_handle = window.app_handle().clone();
    let label = window.label().to_string();
    register_surface_change_callback(hwnd, move |surface| {
        let emit_handle = app_handle.clone();
        let target_label = label.clone();
        let _ = app_handle.run_on_main_thread(move || {
            if let Err(err) = emit_handle.emit_to(&target_label, SURFACE_CHANGED_EVENT, &surface) {
                tracing::debug!(
                    %err,
                    label = %target_label,
                    "Failed to emit live surface-changed event"
                );
            }
        });
    });
}

#[tauri::command]
pub fn set_window_theme(window: WebviewWindow, is_dark: bool) -> WindowSurfaceState {
    if window.label() == "main" {
        attach_surface_change_emitter(&window);
    }
    let surface = apply_window_chrome(raw_hwnd(&window), is_dark);
    let bg = match surface.backdrop {
        BackdropKind::Mica => Color(0, 0, 0, 0),
        BackdropKind::SolidFallback => {
            if is_dark {
                Color(28, 30, 34, 255)
            } else {
                Color(246, 246, 246, 255)
            }
        }
    };
    let _ = window.set_background_color(Some(bg));
    surface
}

#[tauri::command]
pub fn set_maximize_button_rect(window: WebviewWindow, rect: Option<ClientRect>) {
    update_maximize_button_rect(raw_hwnd(&window), rect);
}

#[tauri::command]
pub fn window_minimize(window: WebviewWindow) -> IpcResult<()> {
    window.minimize().map_err(|e| IpcError {
        code: "WINDOW_ERROR",
        message: e.to_string(),
    })
}

#[tauri::command]
pub fn window_toggle_maximize(window: WebviewWindow) -> IpcResult<bool> {
    let maximized = window.is_maximized().unwrap_or(false);
    let res = if maximized {
        window.unmaximize()
    } else {
        window.maximize()
    };
    res.map_err(|e| IpcError {
        code: "WINDOW_ERROR",
        message: e.to_string(),
    })?;
    Ok(!maximized)
}

#[tauri::command]
pub fn window_close(window: WebviewWindow) -> IpcResult<()> {
    window.close().map_err(|e| IpcError {
        code: "WINDOW_ERROR",
        message: e.to_string(),
    })
}

#[tauri::command]
pub fn window_is_maximized(window: WebviewWindow) -> bool {
    window.is_maximized().unwrap_or(false)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn surface_changed_event_name_matches_contract_and_tauri_rules() {
        assert_eq!(SURFACE_CHANGED_EVENT, "charkle://surface-changed");
        assert!(SURFACE_CHANGED_EVENT
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || matches!(c, '-' | '/' | ':' | '_')));
    }

    #[test]
    fn window_surface_state_serializes_system_accent_hex_camel_case() {
        let with_accent = WindowSurfaceState {
            build_number: 26100,
            backdrop: BackdropKind::Mica,
            is_dark: true,
            transparency_enabled: true,
            animations_enabled: false,
            snap_layouts_supported: true,
            system_accent_hex: Some("#0078D4".to_string()),
        };
        let json = serde_json::to_value(&with_accent).expect("serialize with accent");
        assert_eq!(json["buildNumber"], 26100);
        assert_eq!(json["backdrop"], "mica");
        assert_eq!(json["isDark"], true);
        assert_eq!(json["transparencyEnabled"], true);
        assert_eq!(json["animationsEnabled"], false);
        assert_eq!(json["snapLayoutsSupported"], true);
        assert_eq!(json["systemAccentHex"], "#0078D4");

        let round_trip: WindowSurfaceState =
            serde_json::from_value(json).expect("deserialize with accent");
        assert_eq!(round_trip, with_accent);

        let without_accent = WindowSurfaceState {
            system_accent_hex: None,
            ..with_accent
        };
        let null_json = serde_json::to_value(&without_accent).expect("serialize without accent");
        assert!(null_json["systemAccentHex"].is_null());

        // Backwards compatibility when older payload omits systemAccentHex
        let legacy_json = serde_json::json!({
            "buildNumber": 19045,
            "backdrop": "solidFallback",
            "isDark": false,
            "transparencyEnabled": false,
            "animationsEnabled": true,
            "snapLayoutsSupported": false
        });
        let parsed: WindowSurfaceState =
            serde_json::from_value(legacy_json).expect("deserialize legacy payload");
        assert_eq!(parsed.system_accent_hex, None);
    }
}
