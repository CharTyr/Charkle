//! Top-Edge Drop Shelf Win32 window controller (`shelf_win.rs`).
//!
//! Implements a fixed oversized transparent topmost non-activating window
//! (`WS_EX_TOPMOST | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE | WS_EX_LAYERED`) anchored
//! top-center of the active cursor monitor, with dynamic `WM_NCHITTEST` click-through
//! outside the visible capsule bounds and a 3px x 320px top-center drag hotstrip.

#![allow(unsafe_code)]

use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, OnceLock};

use serde::{Deserialize, Serialize};

use crate::windowing::ClientRect;

pub const SHELF_LOGICAL_WIDTH: i32 = 1040;
pub const SHELF_LOGICAL_HEIGHT: i32 = 620;
pub const TOP_HOTSTRIP_LOGICAL_WIDTH: i32 = 320;
pub const TOP_HOTSTRIP_LOGICAL_HEIGHT: i32 = 4;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MonitorRect {
    pub left: i32,
    pub top: i32,
    pub right: i32,
    pub bottom: i32,
}

impl MonitorRect {
    pub fn width(&self) -> i32 {
        (self.right - self.left).max(0)
    }

    pub fn height(&self) -> i32 {
        (self.bottom - self.top).max(0)
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ShelfWindowPlacement {
    pub x: i32,
    pub y: i32,
    pub width: i32,
    pub height: i32,
    pub dpi_scale_percent: u32,
}

/// Computes the fixed oversized transparent shelf window placement anchored top-center
/// of `monitor` for the given DPI scale factor (e.g. `1.0`, `1.25`, `1.5`).
pub fn compute_shelf_window_rect(monitor: MonitorRect, dpi_scale: f64) -> ShelfWindowPlacement {
    let scale = dpi_scale.clamp(1.0, 4.0);
    let desired_w = (SHELF_LOGICAL_WIDTH as f64 * scale).round() as i32;
    let desired_h = (SHELF_LOGICAL_HEIGHT as f64 * scale).round() as i32;
    let width = desired_w.min(monitor.width().max(320));
    let height = desired_h.min(monitor.height().max(240));
    let x = monitor.left + (monitor.width() - width) / 2;
    let y = monitor.top;
    ShelfWindowPlacement {
        x,
        y,
        width,
        height,
        dpi_scale_percent: (scale * 100.0).round() as u32,
    }
}

/// Evaluates whether client-coordinate pixel `(x, y)` inside the fixed shelf window
/// should receive mouse/drag events rather than returning `HTTRANSPARENT`.
pub fn shelf_point_is_interactive(
    x: i32,
    y: i32,
    window_width: i32,
    dpi_scale: f64,
    active_capsule_rect: Option<ClientRect>,
) -> bool {
    if let Some(rect) = active_capsule_rect {
        if rect.contains(x, y) {
            return true;
        }
    }

    // Always keep a thin 3-4px top-center trigger hotstrip receptive without blocking
    // maximized app tabs or caption buttons on the left/right edges.
    let scale = dpi_scale.clamp(1.0, 4.0);
    let strip_w = ((TOP_HOTSTRIP_LOGICAL_WIDTH as f64 * scale).round() as i32).min(window_width);
    let strip_h = (TOP_HOTSTRIP_LOGICAL_HEIGHT as f64 * scale)
        .round()
        .max(3.0) as i32;
    let strip_x = (window_width - strip_w) / 2;
    let hotstrip = ClientRect {
        x: strip_x,
        y: 0,
        width: strip_w,
        height: strip_h,
    };
    hotstrip.contains(x, y)
}

#[derive(Debug, Clone, Copy)]
struct ShelfHitState {
    capsule_rect: Option<ClientRect>,
    dpi_scale: f64,
}

static SHELF_HIT_STATES: OnceLock<Mutex<HashMap<isize, ShelfHitState>>> = OnceLock::new();

fn shelf_hit_states() -> &'static Mutex<HashMap<isize, ShelfHitState>> {
    SHELF_HIT_STATES.get_or_init(|| Mutex::new(HashMap::new()))
}

/// Updates the visible interactive capsule rect (in physical client pixels) for the shelf HWND.
/// Pass `None` when collapsed so only the 3-4px top-center hotstrip remains receptive.
pub fn set_shelf_hit_rect(hwnd_raw: isize, rect: Option<ClientRect>) {
    if let Ok(mut map) = shelf_hit_states().lock() {
        let entry = map.entry(hwnd_raw).or_insert(ShelfHitState {
            capsule_rect: None,
            dpi_scale: 1.0,
        });
        entry.capsule_rect = rect;
    }
}

#[cfg(target_os = "windows")]
const SHELF_SUBCLASS_ID: usize = 0x4348_5348; // "CHSH"

/// Configures the shelf HWND with non-activating topmost transparent extended styles.
#[cfg(target_os = "windows")]
pub fn configure_shelf_window(hwnd_raw: isize) -> Result<ShelfWindowPlacement, String> {
    use windows::Win32::Foundation::HWND;
    use windows::Win32::Graphics::Dwm::DwmExtendFrameIntoClientArea;
    use windows::Win32::UI::Controls::MARGINS;
    use windows::Win32::UI::WindowsAndMessaging::{
        GetWindowLongPtrW, SetWindowLongPtrW, GWL_EXSTYLE, WS_EX_APPWINDOW, WS_EX_LAYERED,
        WS_EX_NOACTIVATE, WS_EX_TOOLWINDOW, WS_EX_TOPMOST,
    };

    let hwnd = HWND(hwnd_raw as *mut _);
    // SAFETY: Configuring Win32 extended styles on our own Tauri shelf HWND.
    unsafe {
        let current = GetWindowLongPtrW(hwnd, GWL_EXSTYLE);
        let desired = (current & !(WS_EX_APPWINDOW.0 as isize))
            | (WS_EX_TOPMOST.0 as isize)
            | (WS_EX_TOOLWINDOW.0 as isize)
            | (WS_EX_NOACTIVATE.0 as isize)
            | (WS_EX_LAYERED.0 as isize);
        let _ = SetWindowLongPtrW(hwnd, GWL_EXSTYLE, desired);

        let margins = MARGINS {
            cxLeftWidth: -1,
            cxRightWidth: -1,
            cyTopHeight: -1,
            cyBottomHeight: -1,
        };
        let _ = DwmExtendFrameIntoClientArea(hwnd, &margins);
    }

    reposition_shelf_to_cursor_monitor(hwnd_raw)
}

#[cfg(not(target_os = "windows"))]
pub fn configure_shelf_window(_hwnd_raw: isize) -> Result<ShelfWindowPlacement, String> {
    Ok(compute_shelf_window_rect(
        MonitorRect {
            left: 0,
            top: 0,
            right: 1920,
            bottom: 1080,
        },
        1.0,
    ))
}

/// Repositions the fixed-size shelf HWND to the top-center of whichever monitor currently
/// hosts the mouse cursor, without stealing foreground focus (`SWP_NOACTIVATE`).
#[cfg(target_os = "windows")]
pub fn reposition_shelf_to_cursor_monitor(hwnd_raw: isize) -> Result<ShelfWindowPlacement, String> {
    use windows::Win32::Foundation::{HWND, POINT};
    use windows::Win32::Graphics::Gdi::{
        GetMonitorInfoW, MonitorFromPoint, MONITORINFO, MONITOR_DEFAULTTONEAREST,
    };
    use windows::Win32::UI::HiDpi::{GetDpiForMonitor, MDT_EFFECTIVE_DPI};
    use windows::Win32::UI::WindowsAndMessaging::{
        GetCursorPos, SetWindowPos, HWND_TOPMOST, SWP_NOACTIVATE, SWP_NOOWNERZORDER,
    };

    let mut pt = POINT::default();
    // SAFETY: Stack-allocated `POINT`.
    let _ = unsafe { GetCursorPos(&mut pt) };

    // SAFETY: `MonitorFromPoint` with `MONITOR_DEFAULTTONEAREST` always returns a valid handle.
    let hmon = unsafe { MonitorFromPoint(pt, MONITOR_DEFAULTTONEAREST) };
    let mut info = MONITORINFO {
        cbSize: std::mem::size_of::<MONITORINFO>() as u32,
        ..Default::default()
    };
    // SAFETY: `info.cbSize` is initialized.
    let ok = unsafe { GetMonitorInfoW(hmon, &mut info) };
    let monitor = if ok.as_bool() {
        MonitorRect {
            left: info.rcMonitor.left,
            top: info.rcMonitor.top,
            right: info.rcMonitor.right,
            bottom: info.rcMonitor.bottom,
        }
    } else {
        MonitorRect {
            left: 0,
            top: 0,
            right: 1920,
            bottom: 1080,
        }
    };

    let mut dpi_x: u32 = 96;
    let mut dpi_y: u32 = 96;
    // SAFETY: Stack pointers for monitor DPI query.
    let _ = unsafe { GetDpiForMonitor(hmon, MDT_EFFECTIVE_DPI, &mut dpi_x, &mut dpi_y) };
    let dpi_scale = (dpi_x as f64 / 96.0).clamp(1.0, 4.0);

    let placement = compute_shelf_window_rect(monitor, dpi_scale);
    if let Ok(mut map) = shelf_hit_states().lock() {
        let entry = map.entry(hwnd_raw).or_insert(ShelfHitState {
            capsule_rect: None,
            dpi_scale,
        });
        entry.dpi_scale = dpi_scale;
    }

    let hwnd = HWND(hwnd_raw as *mut _);
    // SAFETY: Moves shelf window without activating it.
    unsafe {
        let _ = SetWindowPos(
            hwnd,
            HWND_TOPMOST,
            placement.x,
            placement.y,
            placement.width,
            placement.height,
            SWP_NOACTIVATE | SWP_NOOWNERZORDER,
        );
    }

    Ok(placement)
}

#[cfg(not(target_os = "windows"))]
pub fn reposition_shelf_to_cursor_monitor(
    _hwnd_raw: isize,
) -> Result<ShelfWindowPlacement, String> {
    configure_shelf_window(0)
}

/// Installs the Win32 subclass handling `WM_NCHITTEST` click-through and `WM_MOUSEACTIVATE`
/// non-focus-stealing behavior on the shelf window.
#[cfg(target_os = "windows")]
pub fn install_shelf_subclass(hwnd_raw: isize) -> bool {
    use windows::Win32::Foundation::{HWND, LPARAM, LRESULT, POINT, RECT, WPARAM};
    use windows::Win32::Graphics::Gdi::ScreenToClient;
    use windows::Win32::UI::Shell::{DefSubclassProc, RemoveWindowSubclass, SetWindowSubclass};
    use windows::Win32::UI::WindowsAndMessaging::{
        GetClientRect, HTTRANSPARENT, MA_NOACTIVATE, WM_MOUSEACTIVATE, WM_NCDESTROY, WM_NCHITTEST,
    };

    unsafe extern "system" fn shelf_subclass_proc(
        hwnd: HWND,
        msg: u32,
        wparam: WPARAM,
        lparam: LPARAM,
        uid_subclass: usize,
        _ref_data: usize,
    ) -> LRESULT {
        match msg {
            WM_MOUSEACTIVATE => {
                // Strictly prevent the Drop Shelf from ever stealing foreground window focus.
                return LRESULT(MA_NOACTIVATE as isize);
            }
            WM_NCHITTEST => {
                let screen_x = (lparam.0 & 0xFFFF) as i16 as i32;
                let screen_y = ((lparam.0 >> 16) & 0xFFFF) as i16 as i32;
                let mut pt = POINT {
                    x: screen_x,
                    y: screen_y,
                };
                if unsafe { ScreenToClient(hwnd, &mut pt) }.as_bool() {
                    let mut rc = RECT::default();
                    let _ = unsafe { GetClientRect(hwnd, &mut rc) };
                    let win_w = (rc.right - rc.left).max(1);
                    let state = shelf_hit_states()
                        .lock()
                        .ok()
                        .and_then(|m| m.get(&(hwnd.0 as isize)).copied())
                        .unwrap_or(ShelfHitState {
                            capsule_rect: None,
                            dpi_scale: 1.0,
                        });
                    if !shelf_point_is_interactive(
                        pt.x,
                        pt.y,
                        win_w,
                        state.dpi_scale,
                        state.capsule_rect,
                    ) {
                        return LRESULT(HTTRANSPARENT as isize);
                    }
                }
            }
            WM_NCDESTROY => {
                if let Ok(mut map) = shelf_hit_states().lock() {
                    map.remove(&(hwnd.0 as isize));
                }
                let _ =
                    unsafe { RemoveWindowSubclass(hwnd, Some(shelf_subclass_proc), uid_subclass) };
            }
            _ => {}
        }

        unsafe { DefSubclassProc(hwnd, msg, wparam, lparam) }
    }

    let hwnd = HWND(hwnd_raw as *mut _);
    // SAFETY: Installs subclass on our owned shelf HWND.
    unsafe { SetWindowSubclass(hwnd, Some(shelf_subclass_proc), SHELF_SUBCLASS_ID, 0).as_bool() }
}

#[cfg(not(target_os = "windows"))]
pub fn install_shelf_subclass(_hwnd_raw: isize) -> bool {
    false
}

/// Handle returned by [`start_top_edge_drag_monitor`] that stops the background watcher on drop.
pub struct TopEdgeDragMonitorHandle {
    stop: Arc<AtomicBool>,
}

impl Drop for TopEdgeDragMonitorHandle {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::Relaxed);
    }
}

/// Starts a lightweight background cursor monitor that detects when the user drags an item
/// (left mouse button pressed) into the top-center trigger strip of any display so the Drop Shelf
/// springs open immediately without stealing foreground focus.
pub fn start_top_edge_drag_monitor<F>(on_drag_hover_top: F) -> TopEdgeDragMonitorHandle
where
    F: Fn() + Send + 'static,
{
    let stop = Arc::new(AtomicBool::new(false));
    let stop_clone = Arc::clone(&stop);

    #[cfg(target_os = "windows")]
    let _ = std::thread::Builder::new()
        .name("charkle-top-edge-drag".to_string())
        .spawn(move || {
            use std::time::Duration;
            use windows::Win32::Foundation::POINT;
            use windows::Win32::Graphics::Gdi::{
                GetMonitorInfoW, MonitorFromPoint, MONITORINFO, MONITOR_DEFAULTTONEAREST,
            };
            use windows::Win32::UI::Input::KeyboardAndMouse::{GetAsyncKeyState, VK_LBUTTON};
            use windows::Win32::UI::WindowsAndMessaging::GetCursorPos;

            let mut was_triggered = false;
            while !stop_clone.load(Ordering::Relaxed) {
                std::thread::sleep(Duration::from_millis(45));

                // SAFETY: Stateless Win32 input state probes.
                let lbutton_down =
                    unsafe { (GetAsyncKeyState(VK_LBUTTON.0 as i32) as u16) & 0x8000 } != 0;
                if !lbutton_down {
                    was_triggered = false;
                    continue;
                }

                let mut pt = POINT::default();
                if unsafe { GetCursorPos(&mut pt) }.is_err() {
                    continue;
                }

                let hmon = unsafe { MonitorFromPoint(pt, MONITOR_DEFAULTTONEAREST) };
                let mut info = MONITORINFO {
                    cbSize: std::mem::size_of::<MONITORINFO>() as u32,
                    ..Default::default()
                };
                if !unsafe { GetMonitorInfoW(hmon, &mut info) }.as_bool() {
                    continue;
                }

                let mon = info.rcMonitor;
                let center_x = (mon.left + mon.right) / 2;
                let in_top_strip =
                    pt.y >= mon.top && pt.y <= mon.top + 8 && (pt.x - center_x).abs() <= 210;

                if in_top_strip && !was_triggered {
                    was_triggered = true;
                    on_drag_hover_top();
                } else if !in_top_strip {
                    was_triggered = false;
                }
            }
        });

    #[cfg(not(target_os = "windows"))]
    let _ = (on_drag_hover_top, stop_clone);

    TopEdgeDragMonitorHandle { stop }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn shelf_geometry_anchors_top_center_across_dpi_scales() {
        let mon = MonitorRect {
            left: 1920,
            top: 0,
            right: 4480, // 2560px wide secondary display
            bottom: 1440,
        };
        let p = compute_shelf_window_rect(mon, 1.5);
        assert_eq!(p.width, 1560);
        assert_eq!(p.height, 930);
        assert_eq!(p.y, 0);
        assert_eq!(p.x, 1920 + (2560 - 1560) / 2);
        assert_eq!(p.dpi_scale_percent, 150);
    }

    #[test]
    fn shelf_hit_test_passes_through_outside_capsule_and_keeps_top_hotstrip() {
        let win_w = 1040;
        // Collapsed: top-center 3px strip is interactive, corners & lower area pass through
        assert!(shelf_point_is_interactive(520, 1, win_w, 1.0, None));
        assert!(!shelf_point_is_interactive(10, 1, win_w, 1.0, None));
        assert!(!shelf_point_is_interactive(520, 40, win_w, 1.0, None));

        // Expanded capsule: points inside capsule hit; points outside pass through
        let capsule = ClientRect {
            x: 180,
            y: 0,
            width: 680,
            height: 320,
        };
        assert!(shelf_point_is_interactive(
            500,
            160,
            win_w,
            1.0,
            Some(capsule)
        ));
        assert!(!shelf_point_is_interactive(
            50,
            160,
            win_w,
            1.0,
            Some(capsule)
        ));
        assert!(!shelf_point_is_interactive(
            500,
            420,
            win_w,
            1.0,
            Some(capsule)
        ));
    }
}
