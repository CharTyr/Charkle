use charkle_platform_win::windowing::{
    apply_window_chrome, update_maximize_button_rect, BackdropKind, ClientRect, WindowSurfaceState,
};
use tauri::window::Color;
use tauri::WebviewWindow;

use super::{IpcError, IpcResult};

#[cfg(target_os = "windows")]
fn raw_hwnd(window: &WebviewWindow) -> isize {
    window.hwnd().map(|h| h.0 as isize).unwrap_or(0)
}

#[cfg(not(target_os = "windows"))]
fn raw_hwnd(_window: &WebviewWindow) -> isize {
    0
}

#[tauri::command]
pub fn set_window_theme(window: WebviewWindow, is_dark: bool) -> WindowSurfaceState {
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
