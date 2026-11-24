//! Top-Edge Drop Shelf Win32 window controller (`shelf_win.rs`).
//!
//! Implements a fixed oversized transparent topmost non-activating window
//! (`WS_POPUP | WS_EX_TOPMOST | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE`) anchored
//! top-center of the active cursor monitor, with dynamic `WM_NCHITTEST` click-through
//! outside the visible capsule bounds, ZERO Windows 11 1px border (while keeping DWM
//! active so Windows never falls back to classic titlebar painting!), and top-edge drag/hover triggers.

#![allow(unsafe_code)]

use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, AtomicIsize, AtomicU64, AtomicU8, Ordering};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::{SystemTime, UNIX_EPOCH};

use serde::{Deserialize, Serialize};

use crate::windowing::ClientRect;

pub const SHELF_LOGICAL_WIDTH: i32 = 1040;
pub const SHELF_LOGICAL_HEIGHT: i32 = 620;
pub const SHELF_COMPACT_LOGICAL_WIDTH: i32 = 668;
pub const SHELF_COMPACT_LOGICAL_HEIGHT: i32 = 330;
pub const TOP_HOTSTRIP_LOGICAL_WIDTH: i32 = 320;
pub const TOP_HOTSTRIP_LOGICAL_HEIGHT: i32 = 4;

pub const SIDE_SHELF_LOGICAL_WIDTH: i32 = 560;
pub const SIDE_SHELF_LOGICAL_HEIGHT: i32 = 760;
pub const SIDE_COMPACT_LOGICAL_WIDTH: i32 = 344;
pub const SIDE_COMPACT_LOGICAL_HEIGHT: i32 = 560;
pub const SIDE_HOTSTRIP_LOGICAL_THICKNESS: i32 = 4;
pub const SIDE_HOTSTRIP_LOGICAL_LENGTH: i32 = 240;

/// Screen edge where the floating Drop Shelf docks (`"top"` | `"left"` | `"right"`).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum ShelfDockEdge {
    #[default]
    Top,
    Left,
    Right,
}

impl ShelfDockEdge {
    pub fn from_str_lossy(raw: &str) -> Self {
        match raw.trim().to_ascii_lowercase().as_str() {
            "left" => Self::Left,
            "right" => Self::Right,
            _ => Self::Top,
        }
    }

    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Top => "top",
            Self::Left => "left",
            Self::Right => "right",
        }
    }

    pub const fn to_u8(self) -> u8 {
        match self {
            Self::Top => 0,
            Self::Left => 1,
            Self::Right => 2,
        }
    }

    pub const fn from_u8(raw: u8) -> Self {
        match raw {
            1 => Self::Left,
            2 => Self::Right,
            _ => Self::Top,
        }
    }
}

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

/// Computes the fixed oversized transparent shelf window placement anchored flush against
/// `edge` (`Top` / `Left` / `Right`) of `monitor` (vertically centered inside `work_area` above
/// the taskbar for `Left` / `Right`) for the given DPI scale factor.
pub fn compute_shelf_window_rect_for_edge(
    monitor: MonitorRect,
    work_area: MonitorRect,
    dpi_scale: f64,
    edge: ShelfDockEdge,
) -> ShelfWindowPlacement {
    let scale = dpi_scale.clamp(1.0, 4.0);
    let (x, y, width, height) = match edge {
        ShelfDockEdge::Top => {
            let desired_w = (SHELF_LOGICAL_WIDTH as f64 * scale).round() as i32;
            let desired_h = (SHELF_LOGICAL_HEIGHT as f64 * scale).round() as i32;
            let width = desired_w.min(monitor.width().max(320));
            let height = desired_h.min(monitor.height().max(240));
            let x = monitor.left + (monitor.width() - width) / 2;
            let y = monitor.top;
            (x, y, width, height)
        }
        ShelfDockEdge::Left | ShelfDockEdge::Right => {
            let desired_w = (SIDE_SHELF_LOGICAL_WIDTH as f64 * scale).round() as i32;
            let desired_h = (SIDE_SHELF_LOGICAL_HEIGHT as f64 * scale).round() as i32;
            let work_h = if work_area.height() > 0 {
                work_area.height()
            } else {
                monitor.height()
            };
            let work_top = if work_area.height() > 0 {
                work_area.top
            } else {
                monitor.top
            };
            let width = desired_w.min(monitor.width().max(320));
            let height = desired_h.min(work_h.max(320));
            let y = work_top + (work_h - height) / 2;
            let x = match edge {
                ShelfDockEdge::Left => monitor.left,
                ShelfDockEdge::Right => monitor.right - width,
                ShelfDockEdge::Top => unreachable!(),
            };
            (x, y, width, height)
        }
    };

    ShelfWindowPlacement {
        x,
        y,
        width,
        height,
        dpi_scale_percent: (scale * 100.0).round() as u32,
    }
}

/// Computes the fixed oversized transparent shelf window placement anchored top-center
/// of `monitor` for the given DPI scale factor (e.g. `1.0`, `1.25`, `1.5`).
pub fn compute_shelf_window_rect(monitor: MonitorRect, dpi_scale: f64) -> ShelfWindowPlacement {
    compute_shelf_window_rect_for_edge(monitor, monitor, dpi_scale, ShelfDockEdge::Top)
}

/// Computes the initial physical-pixel interactive rect for the compact expanded capsule
/// anchored to `edge`, seeded synchronously before showing the shelf window so OS drag-and-drop
/// hits immediately on frame 0 without waiting for CSS transitions or a JS IPC round-trip.
pub fn default_compact_capsule_rect_for_edge(
    placement: ShelfWindowPlacement,
    edge: ShelfDockEdge,
) -> ClientRect {
    let scale = (placement.dpi_scale_percent as f64 / 100.0).clamp(1.0, 4.0);
    let margin = (16.0 * scale).round() as i32;
    match edge {
        ShelfDockEdge::Top => {
            let max_w = (placement.width - margin).max(200);
            let width = ((SHELF_COMPACT_LOGICAL_WIDTH as f64 * scale).round() as i32).min(max_w);
            let height = ((SHELF_COMPACT_LOGICAL_HEIGHT as f64 * scale).round() as i32)
                .min(placement.height.max(160));
            let x = ((placement.width - width) / 2).max(0);
            ClientRect {
                x,
                y: 0,
                width,
                height,
            }
        }
        ShelfDockEdge::Left => {
            let max_w = (placement.width - margin).max(160);
            let max_h = (placement.height - margin).max(200);
            let width = ((SIDE_COMPACT_LOGICAL_WIDTH as f64 * scale).round() as i32).min(max_w);
            let height = ((SIDE_COMPACT_LOGICAL_HEIGHT as f64 * scale).round() as i32).min(max_h);
            let y = ((placement.height - height) / 2).max(0);
            ClientRect {
                x: 0,
                y,
                width,
                height,
            }
        }
        ShelfDockEdge::Right => {
            let max_w = (placement.width - margin).max(160);
            let max_h = (placement.height - margin).max(200);
            let width = ((SIDE_COMPACT_LOGICAL_WIDTH as f64 * scale).round() as i32).min(max_w);
            let height = ((SIDE_COMPACT_LOGICAL_HEIGHT as f64 * scale).round() as i32).min(max_h);
            let x = (placement.width - width).max(0);
            let y = ((placement.height - height) / 2).max(0);
            ClientRect {
                x,
                y,
                width,
                height,
            }
        }
    }
}

/// Computes the initial physical-pixel interactive rect for the top-docked compact capsule.
pub fn default_compact_capsule_rect(placement: ShelfWindowPlacement) -> ClientRect {
    default_compact_capsule_rect_for_edge(placement, ShelfDockEdge::Top)
}

/// Evaluates whether client-coordinate pixel `(x, y)` inside the fixed shelf window
/// should receive mouse/drag events rather than returning `HTTRANSPARENT` for `edge`.
pub fn shelf_point_is_interactive_for_edge(
    x: i32,
    y: i32,
    window_width: i32,
    window_height: i32,
    dpi_scale: f64,
    active_capsule_rect: Option<ClientRect>,
    edge: ShelfDockEdge,
) -> bool {
    if let Some(rect) = active_capsule_rect {
        if rect.contains(x, y) {
            return true;
        }
    }

    let scale = dpi_scale.clamp(1.0, 4.0);
    let hotstrip = match edge {
        ShelfDockEdge::Top => {
            // Thin 3-4px top-center trigger hotstrip without blocking maximized app tabs/caption buttons.
            let strip_w =
                ((TOP_HOTSTRIP_LOGICAL_WIDTH as f64 * scale).round() as i32).min(window_width);
            let strip_h = (TOP_HOTSTRIP_LOGICAL_HEIGHT as f64 * scale)
                .round()
                .max(3.0) as i32;
            let strip_x = (window_width - strip_w) / 2;
            ClientRect {
                x: strip_x,
                y: 0,
                width: strip_w,
                height: strip_h,
            }
        }
        ShelfDockEdge::Left => {
            let strip_w = (SIDE_HOTSTRIP_LOGICAL_THICKNESS as f64 * scale)
                .round()
                .max(3.0) as i32;
            let strip_h =
                ((SIDE_HOTSTRIP_LOGICAL_LENGTH as f64 * scale).round() as i32).min(window_height);
            let strip_y = (window_height - strip_h) / 2;
            ClientRect {
                x: 0,
                y: strip_y,
                width: strip_w,
                height: strip_h,
            }
        }
        ShelfDockEdge::Right => {
            let strip_w = (SIDE_HOTSTRIP_LOGICAL_THICKNESS as f64 * scale)
                .round()
                .max(3.0) as i32;
            let strip_h =
                ((SIDE_HOTSTRIP_LOGICAL_LENGTH as f64 * scale).round() as i32).min(window_height);
            let strip_x = (window_width - strip_w).max(0);
            let strip_y = (window_height - strip_h) / 2;
            ClientRect {
                x: strip_x,
                y: strip_y,
                width: strip_w,
                height: strip_h,
            }
        }
    };
    hotstrip.contains(x, y)
}

/// Evaluates whether client-coordinate pixel `(x, y)` inside the top-docked shelf window
/// should receive mouse/drag events rather than returning `HTTRANSPARENT`.
pub fn shelf_point_is_interactive(
    x: i32,
    y: i32,
    window_width: i32,
    dpi_scale: f64,
    active_capsule_rect: Option<ClientRect>,
) -> bool {
    shelf_point_is_interactive_for_edge(
        x,
        y,
        window_width,
        SHELF_LOGICAL_HEIGHT,
        dpi_scale,
        active_capsule_rect,
        ShelfDockEdge::Top,
    )
}

#[derive(Debug, Clone, Copy)]
struct ShelfHitState {
    capsule_rect: Option<ClientRect>,
    window_origin: (i32, i32),
    dpi_scale: f64,
    dock_edge: ShelfDockEdge,
    allow_activate: bool,
    outbound_dragging: bool,
}

impl Default for ShelfHitState {
    fn default() -> Self {
        Self {
            capsule_rect: None,
            window_origin: (0, 0),
            dpi_scale: 1.0,
            dock_edge: ShelfDockEdge::Top,
            allow_activate: false,
            outbound_dragging: false,
        }
    }
}

static SHELF_HIT_STATES: OnceLock<Mutex<HashMap<isize, ShelfHitState>>> = OnceLock::new();

fn shelf_hit_states() -> &'static Mutex<HashMap<isize, ShelfHitState>> {
    SHELF_HIT_STATES.get_or_init(|| Mutex::new(HashMap::new()))
}

/// Updates the visible interactive capsule rect (in physical client pixels) for the shelf HWND.
/// Pass `None` when collapsed so only the 3-4px docked bezel hotstrip remains receptive.
pub fn set_shelf_hit_rect(hwnd_raw: isize, rect: Option<ClientRect>) {
    if let Ok(mut map) = shelf_hit_states().lock() {
        let entry = map.entry(hwnd_raw).or_default();
        entry.capsule_rect = rect;
    }
}

/// Updates only the in-memory `allow_activate` flag for `WM_MOUSEACTIVATE` (safe from any thread).
pub fn set_shelf_allow_activate_state_only(hwnd_raw: isize, allow: bool) {
    if let Ok(mut map) = shelf_hit_states().lock() {
        let entry = map.entry(hwnd_raw).or_default();
        entry.allow_activate = allow;
    }
}

/// Reads the current in-memory `allow_activate` flag for `hwnd_raw`.
pub fn get_shelf_allow_activate(hwnd_raw: isize) -> bool {
    shelf_hit_states()
        .lock()
        .ok()
        .and_then(|m| m.get(&hwnd_raw).map(|s| s.allow_activate))
        .unwrap_or(false)
}

/// Updates `allow_activate` state AND toggles `WS_EX_NOACTIVATE` on the shelf HWND.
/// MUST be invoked strictly on the main Win32 UI thread that owns `hwnd_raw`!
pub fn apply_shelf_no_activate_style(hwnd_raw: isize, allow: bool) {
    set_shelf_allow_activate_state_only(hwnd_raw, allow);

    #[cfg(target_os = "windows")]
    if hwnd_raw != 0 {
        use windows::Win32::Foundation::HWND;
        use windows::Win32::UI::WindowsAndMessaging::{
            GetWindowLongPtrW, IsWindow, SetWindowLongPtrW, GWL_EXSTYLE, WS_EX_NOACTIVATE,
        };
        let hwnd = HWND(hwnd_raw as *mut _);
        // SAFETY: Toggles `WS_EX_NOACTIVATE` on our owned shelf HWND on the owning Win32 UI thread.
        unsafe {
            if !IsWindow(hwnd).as_bool() {
                return;
            }
            let cur_ex = GetWindowLongPtrW(hwnd, GWL_EXSTYLE);
            let next_ex = if allow {
                cur_ex & !(WS_EX_NOACTIVATE.0 as isize)
            } else {
                cur_ex | (WS_EX_NOACTIVATE.0 as isize)
            };
            if next_ex != cur_ex {
                let _ = SetWindowLongPtrW(hwnd, GWL_EXSTYLE, next_ex);
            }
        }
    }
}

/// Temporarily permits the shelf window to accept keyboard focus (e.g. while typing in
/// Full-Waterfall search) while keeping normal expand/drag strictly non-activating.
/// MUST be invoked on the main Win32 UI thread.
pub fn set_shelf_allow_activate(hwnd_raw: isize, allow: bool) {
    apply_shelf_no_activate_style(hwnd_raw, allow);
}

/// Marks whether an outbound OLE `DoDragDrop` initiated from the shelf is currently active.
/// While true, `WM_NCHITTEST` returns `HTTRANSPARENT` across the shelf so apps underneath
/// (Desktop, Explorer, Figma, Charkle main window) can receive drops anywhere on screen.
pub fn set_shelf_outbound_dragging(hwnd_raw: isize, dragging: bool) {
    if let Ok(mut map) = shelf_hit_states().lock() {
        let entry = map.entry(hwnd_raw).or_default();
        entry.outbound_dragging = dragging;
    }
}

/// Returns whether an outbound OLE `DoDragDrop` from the shelf HWND is currently active.
pub fn is_shelf_outbound_dragging(hwnd_raw: isize) -> bool {
    shelf_hit_states()
        .lock()
        .ok()
        .and_then(|m| m.get(&hwnd_raw).map(|s| s.outbound_dragging))
        .unwrap_or(false)
}

/// Returns the active capsule bounds in virtual-screen physical pixels (for cursor-leave auto-collapse).
pub fn active_shelf_screen_rect(hwnd_raw: isize) -> Option<ClientRect> {
    let map = shelf_hit_states().lock().ok()?;
    let state = map.get(&hwnd_raw)?;
    let rc = state.capsule_rect?;
    Some(ClientRect {
        x: state.window_origin.0 + rc.x,
        y: state.window_origin.1 + rc.y,
        width: rc.width,
        height: rc.height,
    })
}

#[cfg(target_os = "windows")]
const SHELF_SUBCLASS_ID: usize = 0x4348_5348; // "CHSH"

/// Configures the shelf HWND as a pure borderless topmost transparent DWM popup with ZERO
/// Windows 11 1px outer border and ZERO classic titlebar fallback.
///
/// IMPORTANT: Never set `DWMWA_NCRENDERING_POLICY = DWMNCRP_DISABLED` — doing so disables DWM
/// non-client composition and causes Windows to paint a legacy GDI `"Charkle Shelf"` titlebar!
#[cfg(target_os = "windows")]
pub fn configure_shelf_window_for_edge(
    hwnd_raw: isize,
    edge: ShelfDockEdge,
) -> Result<ShelfWindowPlacement, String> {
    use std::ffi::c_void;
    use std::mem::size_of;
    use windows::Win32::Foundation::{BOOL, HWND};
    use windows::Win32::Graphics::Dwm::{
        DwmExtendFrameIntoClientArea, DwmSetWindowAttribute, DWMWA_BORDER_COLOR, DWMWA_COLOR_NONE,
        DWMWA_TRANSITIONS_FORCEDISABLED, DWMWA_WINDOW_CORNER_PREFERENCE, DWMWCP_DONOTROUND,
    };
    use windows::Win32::UI::Controls::MARGINS;
    use windows::Win32::UI::WindowsAndMessaging::{
        GetWindowLongPtrW, SetWindowLongPtrW, SetWindowPos, GWL_EXSTYLE, GWL_STYLE, HWND_TOPMOST,
        SWP_FRAMECHANGED, SWP_NOACTIVATE, SWP_NOMOVE, SWP_NOOWNERZORDER, SWP_NOSIZE, WS_BORDER,
        WS_CAPTION, WS_CLIPCHILDREN, WS_CLIPSIBLINGS, WS_DLGFRAME, WS_EX_APPWINDOW,
        WS_EX_CLIENTEDGE, WS_EX_DLGMODALFRAME, WS_EX_NOACTIVATE, WS_EX_TOOLWINDOW, WS_EX_TOPMOST,
        WS_EX_WINDOWEDGE, WS_MAXIMIZEBOX, WS_MINIMIZEBOX, WS_POPUP, WS_SYSMENU, WS_THICKFRAME,
    };

    let hwnd = HWND(hwnd_raw as *mut _);
    // SAFETY: Configuring Win32 popup styles & disabling Win11 DWM border on our own shelf HWND.
    unsafe {
        // 1. Strip any frame/caption/thickframe/border styles into a pure WS_POPUP window.
        let cur_style = GetWindowLongPtrW(hwnd, GWL_STYLE);
        let strip_style = (WS_CAPTION.0
            | WS_THICKFRAME.0
            | WS_BORDER.0
            | WS_DLGFRAME.0
            | WS_SYSMENU.0
            | WS_MINIMIZEBOX.0
            | WS_MAXIMIZEBOX.0) as isize;
        let desired_style = (cur_style & !strip_style)
            | (WS_POPUP.0 as isize)
            | (WS_CLIPCHILDREN.0 as isize)
            | (WS_CLIPSIBLINGS.0 as isize);
        let _ = SetWindowLongPtrW(hwnd, GWL_STYLE, desired_style);

        // 2. Non-activating topmost tool window without edge borders (keep Tauri DirectComposition).
        let cur_ex = GetWindowLongPtrW(hwnd, GWL_EXSTYLE);
        let strip_ex =
            (WS_EX_APPWINDOW.0 | WS_EX_WINDOWEDGE.0 | WS_EX_CLIENTEDGE.0 | WS_EX_DLGMODALFRAME.0)
                as isize;
        let desired_ex = (cur_ex & !strip_ex)
            | (WS_EX_TOPMOST.0 as isize)
            | (WS_EX_TOOLWINDOW.0 as isize)
            | (WS_EX_NOACTIVATE.0 as isize);
        let _ = SetWindowLongPtrW(hwnd, GWL_EXSTYLE, desired_ex);

        // 3. Keep DWM composition ACTIVE, but explicitly suppress Win11 rounded frame, 1px border,
        // and OS window-show transitions so only our CSS/SVG notch renders cleanly.
        let corner_pref: u32 = DWMWCP_DONOTROUND.0 as u32;
        let _ = DwmSetWindowAttribute(
            hwnd,
            DWMWA_WINDOW_CORNER_PREFERENCE,
            &corner_pref as *const u32 as *const c_void,
            size_of::<u32>() as u32,
        );

        let no_border: u32 = DWMWA_COLOR_NONE;
        let _ = DwmSetWindowAttribute(
            hwnd,
            DWMWA_BORDER_COLOR,
            &no_border as *const u32 as *const c_void,
            size_of::<u32>() as u32,
        );

        let disable_transitions = BOOL::from(true);
        let _ = DwmSetWindowAttribute(
            hwnd,
            DWMWA_TRANSITIONS_FORCEDISABLED,
            &disable_transitions as *const BOOL as *const c_void,
            size_of::<BOOL>() as u32,
        );

        // Flush style changes once on creation
        let _ = SetWindowPos(
            hwnd,
            HWND_TOPMOST,
            0,
            0,
            0,
            0,
            SWP_FRAMECHANGED | SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE | SWP_NOOWNERZORDER,
        );

        // Keep DWM glass sheet extended across the full client area for per-pixel alpha transparency.
        let full_sheet = MARGINS {
            cxLeftWidth: -1,
            cxRightWidth: -1,
            cyTopHeight: -1,
            cyBottomHeight: -1,
        };
        let _ = DwmExtendFrameIntoClientArea(hwnd, &full_sheet);
    }

    reposition_shelf_to_cursor_monitor_for_edge(hwnd_raw, edge)
}

#[cfg(target_os = "windows")]
pub fn configure_shelf_window(hwnd_raw: isize) -> Result<ShelfWindowPlacement, String> {
    configure_shelf_window_for_edge(hwnd_raw, ShelfDockEdge::Top)
}

/// Shows the shelf HWND topmost without activating or stealing foreground focus (`SW_SHOWNOACTIVATE`).
#[cfg(target_os = "windows")]
pub fn show_shelf_no_activate(hwnd_raw: isize) {
    use windows::Win32::Foundation::HWND;
    use windows::Win32::UI::WindowsAndMessaging::{
        SetWindowPos, ShowWindow, HWND_TOPMOST, SWP_NOACTIVATE, SWP_NOMOVE, SWP_NOOWNERZORDER,
        SWP_NOSIZE, SWP_SHOWWINDOW, SW_SHOWNOACTIVATE,
    };
    let hwnd = HWND(hwnd_raw as *mut _);
    // SAFETY: Showing & raising our owned topmost shelf window without stealing foreground focus.
    unsafe {
        let _ = ShowWindow(hwnd, SW_SHOWNOACTIVATE);
        let _ = SetWindowPos(
            hwnd,
            HWND_TOPMOST,
            0,
            0,
            0,
            0,
            SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE | SWP_NOOWNERZORDER | SWP_SHOWWINDOW,
        );
    }
}

#[cfg(not(target_os = "windows"))]
pub fn show_shelf_no_activate(_hwnd_raw: isize) {}

/// Hides the shelf HWND cleanly without blocking on cross-thread Tauri window proxies.
#[cfg(target_os = "windows")]
pub fn hide_shelf_native(hwnd_raw: isize) {
    use windows::Win32::Foundation::HWND;
    use windows::Win32::UI::WindowsAndMessaging::{ShowWindow, SW_HIDE};
    if hwnd_raw == 0 {
        return;
    }
    let hwnd = HWND(hwnd_raw as *mut _);
    // SAFETY: Hiding our owned shelf window.
    unsafe {
        let _ = ShowWindow(hwnd, SW_HIDE);
    }
}

#[cfg(not(target_os = "windows"))]
pub fn hide_shelf_native(_hwnd_raw: isize) {}

/// Returns `true` when the shelf HWND is actually visible on screen (`IsWindowVisible`).
#[cfg(target_os = "windows")]
pub fn is_shelf_window_visible(hwnd_raw: isize) -> bool {
    use windows::Win32::Foundation::HWND;
    use windows::Win32::UI::WindowsAndMessaging::IsWindowVisible;
    if hwnd_raw == 0 {
        return false;
    }
    let hwnd = HWND(hwnd_raw as *mut _);
    // SAFETY: Queries Win32 visibility state of our own shelf HWND.
    unsafe { IsWindowVisible(hwnd).as_bool() }
}

#[cfg(not(target_os = "windows"))]
pub fn is_shelf_window_visible(_hwnd_raw: isize) -> bool {
    false
}

#[cfg(not(target_os = "windows"))]
pub fn configure_shelf_window_for_edge(
    _hwnd_raw: isize,
    edge: ShelfDockEdge,
) -> Result<ShelfWindowPlacement, String> {
    let mon = MonitorRect {
        left: 0,
        top: 0,
        right: 1920,
        bottom: 1080,
    };
    Ok(compute_shelf_window_rect_for_edge(mon, mon, 1.0, edge))
}

#[cfg(not(target_os = "windows"))]
pub fn configure_shelf_window(_hwnd_raw: isize) -> Result<ShelfWindowPlacement, String> {
    configure_shelf_window_for_edge(0, ShelfDockEdge::Top)
}

/// Repositions the fixed-size shelf HWND to `edge` (`Top`/`Left`/`Right`) of whichever monitor
/// currently hosts the mouse cursor, without stealing foreground focus (`SWP_NOACTIVATE`).
#[cfg(target_os = "windows")]
pub fn reposition_shelf_to_cursor_monitor_for_edge(
    hwnd_raw: isize,
    edge: ShelfDockEdge,
) -> Result<ShelfWindowPlacement, String> {
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
    let (monitor, work_area) = if ok.as_bool() {
        (
            MonitorRect {
                left: info.rcMonitor.left,
                top: info.rcMonitor.top,
                right: info.rcMonitor.right,
                bottom: info.rcMonitor.bottom,
            },
            MonitorRect {
                left: info.rcWork.left,
                top: info.rcWork.top,
                right: info.rcWork.right,
                bottom: info.rcWork.bottom,
            },
        )
    } else {
        let fallback = MonitorRect {
            left: 0,
            top: 0,
            right: 1920,
            bottom: 1080,
        };
        (fallback, fallback)
    };

    let mut dpi_x: u32 = 96;
    let mut dpi_y: u32 = 96;
    // SAFETY: Stack pointers for monitor DPI query.
    let _ = unsafe { GetDpiForMonitor(hmon, MDT_EFFECTIVE_DPI, &mut dpi_x, &mut dpi_y) };
    let dpi_scale = (dpi_x as f64 / 96.0).clamp(1.0, 4.0);

    let placement = compute_shelf_window_rect_for_edge(monitor, work_area, dpi_scale, edge);
    if let Ok(mut map) = shelf_hit_states().lock() {
        let entry = map.entry(hwnd_raw).or_default();
        entry.window_origin = (placement.x, placement.y);
        entry.dpi_scale = dpi_scale;
        entry.dock_edge = edge;
    }

    let hwnd = HWND(hwnd_raw as *mut _);
    // SAFETY: Moves shelf window without activating it (no SWP_FRAMECHANGED storm).
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

#[cfg(target_os = "windows")]
pub fn reposition_shelf_to_cursor_monitor(hwnd_raw: isize) -> Result<ShelfWindowPlacement, String> {
    reposition_shelf_to_cursor_monitor_for_edge(hwnd_raw, ShelfDockEdge::Top)
}

#[cfg(not(target_os = "windows"))]
pub fn reposition_shelf_to_cursor_monitor_for_edge(
    _hwnd_raw: isize,
    edge: ShelfDockEdge,
) -> Result<ShelfWindowPlacement, String> {
    configure_shelf_window_for_edge(0, edge)
}

#[cfg(not(target_os = "windows"))]
pub fn reposition_shelf_to_cursor_monitor(
    _hwnd_raw: isize,
) -> Result<ShelfWindowPlacement, String> {
    configure_shelf_window_for_edge(0, ShelfDockEdge::Top)
}

/// Installs the Win32 subclass handling zero-nonclient-area suppression, `WM_NCHITTEST`
/// click-through, and `WM_MOUSEACTIVATE` non-focus-stealing behavior on the shelf window.
#[cfg(target_os = "windows")]
pub fn install_shelf_subclass(hwnd_raw: isize) -> bool {
    use windows::Win32::Foundation::{HWND, LPARAM, LRESULT, POINT, RECT, WPARAM};
    use windows::Win32::Graphics::Gdi::ScreenToClient;
    use windows::Win32::UI::Shell::{DefSubclassProc, RemoveWindowSubclass, SetWindowSubclass};
    use windows::Win32::UI::WindowsAndMessaging::{
        GetClientRect, HTTRANSPARENT, MA_ACTIVATE, MA_NOACTIVATE, WM_ERASEBKGND, WM_MOUSEACTIVATE,
        WM_NCACTIVATE, WM_NCCALCSIZE, WM_NCDESTROY, WM_NCHITTEST,
    };

    unsafe extern "system" fn shelf_subclass_proc(
        hwnd: HWND,
        msg: u32,
        wparam: WPARAM,
        lparam: LPARAM,
        uid_subclass: usize,
        _ref_data: usize,
    ) -> LRESULT {
        let handled =
            std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| -> Option<LRESULT> {
                match msg {
                    WM_NCCALCSIZE => {
                        // Eliminate ALL non-client border/caption pixels so Windows never reserves a titlebar.
                        return Some(LRESULT(0));
                    }
                    WM_NCACTIVATE => {
                        // Never allow DefWindowProc to paint a classic active/inactive titlebar strip.
                        return Some(LRESULT(1));
                    }
                    m if crate::windowing::should_suppress_nc_paint_message(m) => {
                        // Swallow WM_NCPAINT, WM_NCUAHDRAWCAPTION (0x00AE), and WM_NCUAHDRAWFRAME (0x00AF).
                        return Some(LRESULT(0));
                    }
                    WM_ERASEBKGND => {
                        return Some(LRESULT(1));
                    }
                    WM_MOUSEACTIVATE => {
                        let allow_activate = shelf_hit_states()
                            .lock()
                            .ok()
                            .and_then(|m| m.get(&(hwnd.0 as isize)).map(|s| s.allow_activate))
                            .unwrap_or(false);
                        return Some(LRESULT(if allow_activate {
                            MA_ACTIVATE as isize
                        } else {
                            MA_NOACTIVATE as isize
                        }));
                    }
                    WM_NCHITTEST => {
                        let state = shelf_hit_states()
                            .lock()
                            .ok()
                            .and_then(|m| m.get(&(hwnd.0 as isize)).copied())
                            .unwrap_or_default();

                        // During an active outbound OLE drag from the shelf, let all hit tests pass through
                        // so the user can drop files onto ANY window or desktop area behind the shelf!
                        if state.outbound_dragging {
                            return Some(LRESULT(HTTRANSPARENT as isize));
                        }

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
                            let win_h = (rc.bottom - rc.top).max(1);
                            if !shelf_point_is_interactive_for_edge(
                                pt.x,
                                pt.y,
                                win_w,
                                win_h,
                                state.dpi_scale,
                                state.capsule_rect,
                                state.dock_edge,
                            ) {
                                return Some(LRESULT(HTTRANSPARENT as isize));
                            }
                        }
                    }
                    WM_NCDESTROY => {
                        if let Ok(mut map) = shelf_hit_states().lock() {
                            map.remove(&(hwnd.0 as isize));
                        }
                        cleanup_shelf_drop_targets(hwnd.0 as isize);
                        let _ = unsafe {
                            RemoveWindowSubclass(hwnd, Some(shelf_subclass_proc), uid_subclass)
                        };
                    }
                    _ => {}
                }
                None
            }));

        if let Ok(Some(res)) = handled {
            return res;
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

/// Shared live control flags for the Drop Shelf edge monitor.
#[derive(Clone)]
pub struct ShelfMonitorConfig {
    pub enabled: Arc<AtomicBool>,
    pub hover_trigger_enabled: Arc<AtomicBool>,
    pub dock_edge: Arc<AtomicU8>,
    pub shelf_expanded: Arc<AtomicBool>,
    pub shelf_pinned: Arc<AtomicBool>,
    pub shelf_drag_hovering: Arc<AtomicBool>,
    pub shelf_busy: Arc<AtomicBool>,
    pub shelf_hold_until_ms: Arc<AtomicU64>,
    pub shelf_hwnd: Arc<AtomicIsize>,
}

fn current_epoch_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0)
}

/// Starts a lightweight background cursor monitor that:
/// 1. Springs the Drop Shelf open immediately when dragging (`VK_LBUTTON` pressed) into any display's top-center strip.
/// 2. Optionally springs the Drop Shelf open when hovering at the top-center bezel for ~180ms (`hover_trigger_enabled`).
/// 3. Smoothly auto-collapses an unpinned Drop Shelf after the cursor leaves the active capsule for ~320ms.
pub fn start_top_edge_monitor<FOpen, FClose>(
    config: ShelfMonitorConfig,
    on_open: FOpen,
    on_auto_collapse: FClose,
) -> TopEdgeDragMonitorHandle
where
    FOpen: Fn() + Send + 'static,
    FClose: Fn() + Send + 'static,
{
    let stop = Arc::new(AtomicBool::new(false));
    let stop_clone = Arc::clone(&stop);

    #[cfg(target_os = "windows")]
    let _ = std::thread::Builder::new()
        .name("charkle-top-edge-monitor".to_string())
        .spawn(move || {
            use std::time::{Duration, Instant};
            use windows::Win32::Foundation::POINT;
            use windows::Win32::Graphics::Gdi::{
                GetMonitorInfoW, MonitorFromPoint, MONITORINFO, MONITOR_DEFAULTTONEAREST,
            };
            use windows::Win32::UI::Input::KeyboardAndMouse::{
                GetAsyncKeyState, VK_LBUTTON, VK_RBUTTON,
            };
            use windows::Win32::UI::WindowsAndMessaging::{
                GetCursorPos, GetSystemMetrics, SM_SWAPBUTTON,
            };

            let mut drag_triggered = false;
            let mut hover_since: Option<Instant> = None;
            let mut outside_since: Option<Instant> = None;
            let mut stale_drag_since: Option<Instant> = None;

            while !stop_clone.load(Ordering::Relaxed) {
                std::thread::sleep(Duration::from_millis(35));

                if !config.enabled.load(Ordering::Relaxed) {
                    drag_triggered = false;
                    hover_since = None;
                    outside_since = None;
                    continue;
                }

                let mut pt = POINT::default();
                if unsafe { GetCursorPos(&mut pt) }.is_err() {
                    continue;
                }

                // SAFETY: Stateless Win32 input state probe; respects left-handed swapped mouse buttons.
                let primary_vk = if unsafe { GetSystemMetrics(SM_SWAPBUTTON) } != 0 {
                    VK_RBUTTON.0 as i32
                } else {
                    VK_LBUTTON.0 as i32
                };
                let lbutton_down = unsafe { (GetAsyncKeyState(primary_vk) as u16) & 0x8000 } != 0;
                if !lbutton_down {
                    drag_triggered = false;
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
                let work = info.rcWork;
                let center_x = (mon.left + mon.right) / 2;
                let work_center_y = (work.top + work.bottom) / 2;
                let edge = ShelfDockEdge::from_u8(config.dock_edge.load(Ordering::Relaxed));
                let is_expanded = config.shelf_expanded.load(Ordering::Relaxed);
                let is_pinned = config.shelf_pinned.load(Ordering::Relaxed);

                if !is_expanded {
                    outside_since = None;
                    let in_drag_strip = match edge {
                        ShelfDockEdge::Top => {
                            pt.y >= mon.top
                                && pt.y <= mon.top + 10
                                && (pt.x - center_x).abs() <= 220
                        }
                        ShelfDockEdge::Left => {
                            pt.x >= mon.left
                                && pt.x <= mon.left + 10
                                && (pt.y - work_center_y).abs() <= 220
                        }
                        ShelfDockEdge::Right => {
                            pt.x >= mon.right - 10
                                && pt.x <= mon.right
                                && (pt.y - work_center_y).abs() <= 220
                        }
                    };
                    if lbutton_down && in_drag_strip {
                        if !drag_triggered {
                            drag_triggered = true;
                            hover_since = None;
                            on_open();
                        }
                        continue;
                    }
                    if !lbutton_down {
                        drag_triggered = false;
                    }

                    // Optional docked-edge hover dwell trigger (~180ms) matching macOS NotchShelfController
                    if !lbutton_down && config.hover_trigger_enabled.load(Ordering::Relaxed) {
                        let in_hover_strip = match edge {
                            ShelfDockEdge::Top => {
                                pt.y >= mon.top
                                    && pt.y <= mon.top + 3
                                    && (pt.x - center_x).abs() <= 140
                            }
                            ShelfDockEdge::Left => {
                                pt.x >= mon.left
                                    && pt.x <= mon.left + 3
                                    && (pt.y - work_center_y).abs() <= 140
                            }
                            ShelfDockEdge::Right => {
                                pt.x >= mon.right - 3
                                    && pt.x <= mon.right
                                    && (pt.y - work_center_y).abs() <= 140
                            }
                        };
                        if in_hover_strip {
                            let started = hover_since.get_or_insert_with(Instant::now);
                            if started.elapsed() >= Duration::from_millis(180) {
                                hover_since = None;
                                on_open();
                            }
                        } else {
                            hover_since = None;
                        }
                    } else {
                        hover_since = None;
                    }
                } else {
                    hover_since = None;
                    // Guard against a missed `DragLeave` (e.g. drag cancelled off-screen):
                    // if mouse button is released for >= 150ms, clear stale `shelf_drag_hovering`
                    // so an unpinned shelf can NEVER wedge open permanently (Pitfall 5).
                    if config.shelf_drag_hovering.load(Ordering::Relaxed) && !lbutton_down {
                        let started = stale_drag_since.get_or_insert_with(Instant::now);
                        if started.elapsed() >= Duration::from_millis(150) {
                            config.shelf_drag_hovering.store(false, Ordering::SeqCst);
                            stale_drag_since = None;
                        }
                    } else {
                        stale_drag_since = None;
                    }
                    let hwnd_raw = config.shelf_hwnd.load(Ordering::Relaxed);
                    let hold_until = config.shelf_hold_until_ms.load(Ordering::Relaxed);
                    let hold_active = hold_until > 0 && current_epoch_ms() < hold_until;
                    if is_pinned
                        || config.shelf_drag_hovering.load(Ordering::Relaxed)
                        || config.shelf_busy.load(Ordering::Relaxed)
                        || hold_active
                        || is_shelf_outbound_dragging(hwnd_raw)
                    {
                        outside_since = None;
                        continue;
                    }

                    // Auto-collapse unpinned shelf once cursor leaves the active capsule rect
                    // (+24px outward grace, +8px bezel grace on the docked edge).
                    let inside_capsule = if let Some(rc) = active_shelf_screen_rect(hwnd_raw) {
                        let margin = 24;
                        match edge {
                            ShelfDockEdge::Top => {
                                pt.x >= rc.x - margin
                                    && pt.x <= rc.x + rc.width + margin
                                    && pt.y >= rc.y - 8
                                    && pt.y <= rc.y + rc.height + margin
                            }
                            ShelfDockEdge::Left => {
                                pt.x >= rc.x - 8
                                    && pt.x <= rc.x + rc.width + margin
                                    && pt.y >= rc.y - margin
                                    && pt.y <= rc.y + rc.height + margin
                            }
                            ShelfDockEdge::Right => {
                                pt.x >= rc.x - margin
                                    && pt.x <= rc.x + rc.width + 8
                                    && pt.y >= rc.y - margin
                                    && pt.y <= rc.y + rc.height + margin
                            }
                        }
                    } else {
                        // Capsule still animating in; keep it open until hit rect arrives
                        true
                    };

                    if inside_capsule {
                        outside_since = None;
                    } else if !lbutton_down {
                        let started = outside_since.get_or_insert_with(Instant::now);
                        if started.elapsed() >= Duration::from_millis(320) {
                            outside_since = None;
                            on_auto_collapse();
                        }
                    }
                }
            }
        });

    #[cfg(not(target_os = "windows"))]
    let _ = (config, on_open, on_auto_collapse, stop_clone);

    TopEdgeDragMonitorHandle { stop }
}

/// Backward-compatible wrapper starting drag-only top-edge monitoring.
pub fn start_top_edge_drag_monitor<F>(on_drag_hover_top: F) -> TopEdgeDragMonitorHandle
where
    F: Fn() + Send + 'static,
{
    start_top_edge_monitor(
        ShelfMonitorConfig {
            enabled: Arc::new(AtomicBool::new(true)),
            hover_trigger_enabled: Arc::new(AtomicBool::new(false)),
            dock_edge: Arc::new(AtomicU8::new(ShelfDockEdge::Top.to_u8())),
            shelf_expanded: Arc::new(AtomicBool::new(false)),
            shelf_pinned: Arc::new(AtomicBool::new(false)),
            shelf_drag_hovering: Arc::new(AtomicBool::new(false)),
            shelf_busy: Arc::new(AtomicBool::new(false)),
            shelf_hold_until_ms: Arc::new(AtomicU64::new(0)),
            shelf_hwnd: Arc::new(AtomicIsize::new(0)),
        },
        on_drag_hover_top,
        || {},
    )
}

// =============================================================================
// Native Win32 OLE IDropTarget Injector for Top-Edge Drop Shelf
// =============================================================================

/// Authoritative payload delivered by the Shelf's native Win32 OLE `IDropTarget`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ShelfDropPayload {
    Files(Vec<PathBuf>),
    Url(String),
    Text(String),
}

impl ShelfDropPayload {
    pub fn item_count(&self) -> usize {
        match self {
            Self::Files(paths) => paths.len().max(1),
            Self::Url(_) | Self::Text(_) => 1,
        }
    }
}

/// Lifecycle events delivered by the Shelf's native Win32 OLE `IDropTarget`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ShelfDropEvent {
    Enter { count: usize },
    Over,
    Leave,
    Drop(ShelfDropPayload),
}

pub type ShelfDropCallback = Arc<dyn Fn(ShelfDropEvent) + Send + Sync>;

/// Classifies dropped URL / Unicode text payloads into either a web URL (`http://`/`https://`)
/// or plain text / `#RRGGBB` color swatch text, sharing the canonical `WebURLParser`.
pub fn classify_dropped_text(raw: &str) -> Option<ShelfDropPayload> {
    let trimmed = raw.trim_matches(|c: char| c.is_whitespace() || c == '\0');
    if trimmed.is_empty() {
        return None;
    }
    if let Some(social_url) =
        charkle_core::media::resolvers::SocialPostURLParser::extract_post_url(trimmed)
    {
        return Some(ShelfDropPayload::Url(social_url.to_string()));
    }
    if let Some(gh_url) =
        charkle_core::media::resolvers::GitHubRepoURLParser::extract_repo_url(trimmed)
    {
        return Some(ShelfDropPayload::Url(gh_url.to_string()));
    }
    if let Some(web_url) =
        charkle_core::media::resolvers::WebURLParser::extract_web_url(trimmed, true)
    {
        return Some(ShelfDropPayload::Url(web_url.to_string()));
    }
    Some(ShelfDropPayload::Text(trimmed.to_string()))
}

/// Decides whether our native Shelf OLE `IDropTarget` needs to be (re-)installed on an HWND.
///
/// Returns `true` when we have never registered on this HWND, when `OleDropTargetInterface` is
/// absent (`0`), or when WebView2/Chromium replaced the window property with a different pointer.
pub const fn should_reinstall_drop_target(
    installed_prop: Option<usize>,
    current_prop: usize,
) -> bool {
    !matches!(installed_prop, Some(expected) if expected != 0 && current_prop == expected)
}

#[cfg(target_os = "windows")]
mod drop_target {
    use super::*;
    use std::cell::{Cell, RefCell};
    use std::ffi::OsString;
    use std::os::windows::ffi::OsStringExt;
    use std::ptr;

    use windows::core::{implement, w};
    use windows::Win32::Foundation::{BOOL, DRAGDROP_E_INVALIDHWND, HGLOBAL, HWND, LPARAM, POINTL};
    use windows::Win32::System::Com::{
        CoTaskMemFree, IDataObject, DVASPECT_CONTENT, FORMATETC, STGMEDIUM, TYMED_HGLOBAL,
    };
    use windows::Win32::System::DataExchange::RegisterClipboardFormatW;
    use windows::Win32::System::Memory::{GlobalLock, GlobalSize, GlobalUnlock};
    use windows::Win32::System::Ole::{
        IDropTarget, IDropTarget_Impl, OleInitialize, RegisterDragDrop, ReleaseStgMedium,
        RevokeDragDrop, CF_HDROP, CF_UNICODETEXT, DROPEFFECT, DROPEFFECT_COPY, DROPEFFECT_NONE,
    };
    use windows::Win32::System::SystemServices::MODIFIERKEYS_FLAGS;
    use windows::Win32::UI::Shell::{
        DragQueryFileW, IShellItemArray, SHCreateShellItemArrayFromDataObject, HDROP,
        SIGDN_FILESYSPATH,
    };
    use windows::Win32::UI::WindowsAndMessaging::{
        EnumChildWindows, GetClassNameW, GetPropW, IsWindow,
    };

    static SHELF_DROP_CALLBACKS: OnceLock<Mutex<HashMap<isize, ShelfDropCallback>>> =
        OnceLock::new();

    fn drop_callbacks() -> &'static Mutex<HashMap<isize, ShelfDropCallback>> {
        SHELF_DROP_CALLBACKS.get_or_init(|| Mutex::new(HashMap::new()))
    }

    struct InstalledDropTarget {
        _target: IDropTarget,
        installed_prop: usize,
    }

    // STA-bound COM `IDropTarget` references live strictly on the Win32 UI thread that owns the
    // Shelf HWND and registered them, keeping COM lifetimes alive until `WM_NCDESTROY`.
    thread_local! {
        static OLE_INIT_DONE: Cell<bool> = const { Cell::new(false) };
        static REFRESH_IN_PROGRESS: Cell<bool> = const { Cell::new(false) };
        static SHELF_DROP_TARGETS: RefCell<HashMap<isize, HashMap<isize, InstalledDropTarget>>> =
            RefCell::new(HashMap::new());
    }

    struct RefreshGuard;
    impl Drop for RefreshGuard {
        fn drop(&mut self) {
            REFRESH_IN_PROGRESS.with(|flag| flag.set(false));
        }
    }

    struct StgMediumGuard(STGMEDIUM);
    impl Drop for StgMediumGuard {
        fn drop(&mut self) {
            // SAFETY: Releases the OS `STGMEDIUM` acquired from `IDataObject::GetData`.
            unsafe {
                ReleaseStgMedium(&mut self.0);
            }
        }
    }

    struct GlobalLockGuard(HGLOBAL);
    impl Drop for GlobalLockGuard {
        fn drop(&mut self) {
            // SAFETY: Pairs with a successful `GlobalLock` call.
            unsafe {
                let _ = GlobalUnlock(self.0);
            }
        }
    }

    fn ensure_sta_ole_initialized() {
        OLE_INIT_DONE.with(|done| {
            if !done.get() {
                // SAFETY: Initializes OLE on the current Win32 STA UI thread once.
                let _ = unsafe { OleInitialize(None) };
                done.set(true);
            }
        });
    }

    fn hwnd_class_name(hwnd: HWND) -> String {
        let mut buf = [0u16; 128];
        // SAFETY: Valid stack buffer for Win32 class name query.
        let len = unsafe { GetClassNameW(hwnd, &mut buf) };
        if len > 0 {
            String::from_utf16_lossy(&buf[..len as usize])
        } else {
            String::new()
        }
    }

    fn extract_hdrop_paths(data_obj: &IDataObject) -> Vec<PathBuf> {
        let fmt = FORMATETC {
            cfFormat: CF_HDROP.0,
            ptd: ptr::null_mut(),
            dwAspect: DVASPECT_CONTENT.0,
            lindex: -1,
            tymed: TYMED_HGLOBAL.0 as u32,
        };
        // SAFETY: Standard `CF_HDROP` extraction with RAII `ReleaseStgMedium` cleanup.
        let Ok(medium) = (unsafe { data_obj.GetData(&fmt) }) else {
            return Vec::new();
        };
        let guard = StgMediumGuard(medium);
        let hglobal = unsafe { guard.0.u.hGlobal };
        if hglobal.0.is_null() {
            return Vec::new();
        }
        let hdrop = HDROP(hglobal.0);
        let count = unsafe { DragQueryFileW(hdrop, 0xFFFF_FFFF, None) };
        let mut out = Vec::with_capacity(count as usize);
        for i in 0..count {
            let char_len = unsafe { DragQueryFileW(hdrop, i, None) } as usize;
            if char_len == 0 {
                continue;
            }
            let mut buf = vec![0u16; char_len + 1];
            let written = unsafe { DragQueryFileW(hdrop, i, Some(&mut buf)) } as usize;
            if written > 0 {
                out.push(PathBuf::from(OsString::from_wide(&buf[..written])));
            }
        }
        out
    }

    fn extract_shell_item_paths(data_obj: &IDataObject) -> Vec<PathBuf> {
        // SAFETY: Shell fallback for long (>260 char) paths when Explorer omits `CF_HDROP`.
        let Ok(items) =
            (unsafe { SHCreateShellItemArrayFromDataObject::<_, IShellItemArray>(data_obj) })
        else {
            return Vec::new();
        };
        let count = unsafe { items.GetCount() }.unwrap_or(0);
        let mut out = Vec::with_capacity(count as usize);
        for i in 0..count {
            let Ok(item) = (unsafe { items.GetItemAt(i) }) else {
                continue;
            };
            let Ok(name) = (unsafe { item.GetDisplayName(SIGDN_FILESYSPATH) }) else {
                continue;
            };
            let path_str = unsafe { OsString::from_wide(name.as_wide()) };
            unsafe { CoTaskMemFree(Some(name.0 as _)) };
            if !path_str.is_empty() {
                out.push(PathBuf::from(path_str));
            }
        }
        out
    }

    fn read_hglobal_utf16_format(data_obj: &IDataObject, cf_format: u16) -> Option<String> {
        let fmt = FORMATETC {
            cfFormat: cf_format,
            ptd: ptr::null_mut(),
            dwAspect: DVASPECT_CONTENT.0,
            lindex: -1,
            tymed: TYMED_HGLOBAL.0 as u32,
        };
        // SAFETY: Reads UTF-16LE `TYMED_HGLOBAL` clipboard format and releases `STGMEDIUM`.
        let medium = unsafe { data_obj.GetData(&fmt) }.ok()?;
        let guard = StgMediumGuard(medium);
        let hglobal = unsafe { guard.0.u.hGlobal };
        if hglobal.0.is_null() {
            return None;
        }
        const MAX_DROP_UTF16_BYTES: usize = 4 * 1024 * 1024;
        let size = unsafe { GlobalSize(hglobal) };
        if size < 2 {
            return None;
        }
        let bounded_bytes = size.min(MAX_DROP_UTF16_BYTES);
        let ptr = unsafe { GlobalLock(hglobal) };
        if ptr.is_null() {
            return None;
        }
        let _lock = GlobalLockGuard(hglobal);
        let units = unsafe { std::slice::from_raw_parts(ptr as *const u16, bounded_bytes / 2) };
        let len = units.iter().position(|&c| c == 0).unwrap_or(units.len());
        Some(String::from_utf16_lossy(&units[..len]))
    }

    fn extract_shelf_drop_payload(data_obj: Option<&IDataObject>) -> Option<ShelfDropPayload> {
        let data_obj = data_obj?;

        // 1. OS file & folder drops (`CF_HDROP` + `IShellItemArray` fallback for >260-char paths)
        let mut paths = extract_hdrop_paths(data_obj);
        if paths.is_empty() {
            paths = extract_shell_item_paths(data_obj);
        }
        if !paths.is_empty() {
            return Some(ShelfDropPayload::Files(paths));
        }

        // 2. Browser dragged links (`UniformResourceLocatorW`)
        let url_fmt = unsafe { RegisterClipboardFormatW(w!("UniformResourceLocatorW")) };
        if url_fmt != 0 {
            if let Some(raw_url) = read_hglobal_utf16_format(data_obj, url_fmt as u16) {
                if let Some(payload) = classify_dropped_text(&raw_url) {
                    return Some(payload);
                }
            }
        }

        // 3. Unicode text / URL / `#RRGGBB` color drops (`CF_UNICODETEXT`)
        if let Some(raw_text) = read_hglobal_utf16_format(data_obj, CF_UNICODETEXT.0) {
            if let Some(payload) = classify_dropped_text(&raw_text) {
                return Some(payload);
            }
        }

        None
    }

    #[implement(IDropTarget)]
    struct ShelfDropTarget {
        callback: ShelfDropCallback,
        enter_is_valid: Cell<bool>,
        cursor_effect: Cell<DROPEFFECT>,
    }

    impl ShelfDropTarget {
        fn new(callback: ShelfDropCallback) -> Self {
            Self {
                callback,
                enter_is_valid: Cell::new(false),
                cursor_effect: Cell::new(DROPEFFECT_NONE),
            }
        }
    }

    #[allow(non_snake_case)]
    impl IDropTarget_Impl for ShelfDropTarget_Impl {
        fn DragEnter(
            &self,
            pdataobj: Option<&IDataObject>,
            _grfkeystate: MODIFIERKEYS_FLAGS,
            _pt: &POINTL,
            pdweffect: *mut DROPEFFECT,
        ) -> windows::core::Result<()> {
            self.enter_is_valid.set(false);
            self.cursor_effect.set(DROPEFFECT_NONE);

            if let Some(payload) = extract_shelf_drop_payload(pdataobj) {
                let count = payload.item_count();
                self.enter_is_valid.set(true);
                self.cursor_effect.set(DROPEFFECT_COPY);
                if !pdweffect.is_null() {
                    // SAFETY: Out-pointer validated non-null per COM `IDropTarget::DragEnter`.
                    unsafe { *pdweffect = DROPEFFECT_COPY };
                }
                (self.callback)(ShelfDropEvent::Enter { count });
            } else if !pdweffect.is_null() {
                unsafe { *pdweffect = DROPEFFECT_NONE };
            }
            Ok(())
        }

        fn DragOver(
            &self,
            _grfkeystate: MODIFIERKEYS_FLAGS,
            _pt: &POINTL,
            pdweffect: *mut DROPEFFECT,
        ) -> windows::core::Result<()> {
            if self.enter_is_valid.get() {
                if !pdweffect.is_null() {
                    unsafe { *pdweffect = self.cursor_effect.get() };
                }
                (self.callback)(ShelfDropEvent::Over);
            } else if !pdweffect.is_null() {
                unsafe { *pdweffect = DROPEFFECT_NONE };
            }
            Ok(())
        }

        fn DragLeave(&self) -> windows::core::Result<()> {
            let was_valid = self.enter_is_valid.replace(false);
            self.cursor_effect.set(DROPEFFECT_NONE);
            if was_valid {
                (self.callback)(ShelfDropEvent::Leave);
            }
            Ok(())
        }

        fn Drop(
            &self,
            pdataobj: Option<&IDataObject>,
            _grfkeystate: MODIFIERKEYS_FLAGS,
            _pt: &POINTL,
            pdweffect: *mut DROPEFFECT,
        ) -> windows::core::Result<()> {
            self.enter_is_valid.set(false);
            self.cursor_effect.set(DROPEFFECT_NONE);

            if let Some(payload) = extract_shelf_drop_payload(pdataobj) {
                if !pdweffect.is_null() {
                    unsafe { *pdweffect = DROPEFFECT_COPY };
                }
                (self.callback)(ShelfDropEvent::Drop(payload));
            } else {
                if !pdweffect.is_null() {
                    unsafe { *pdweffect = DROPEFFECT_NONE };
                }
                (self.callback)(ShelfDropEvent::Leave);
            }
            Ok(())
        }
    }

    pub fn install(shelf_hwnd_raw: isize, callback: ShelfDropCallback) -> usize {
        if shelf_hwnd_raw == 0 {
            return 0;
        }
        if let Ok(mut map) = drop_callbacks().lock() {
            map.insert(shelf_hwnd_raw, callback);
        }
        refresh(shelf_hwnd_raw)
    }

    pub fn refresh(shelf_hwnd_raw: isize) -> usize {
        if shelf_hwnd_raw == 0 {
            return 0;
        }
        let already_busy = REFRESH_IN_PROGRESS.with(|flag| {
            if flag.get() {
                true
            } else {
                flag.set(true);
                false
            }
        });
        if already_busy {
            return 0;
        }
        let _refresh_guard = RefreshGuard;

        let callback = drop_callbacks()
            .lock()
            .ok()
            .and_then(|m| m.get(&shelf_hwnd_raw).cloned());
        let Some(callback) = callback else {
            return 0;
        };

        ensure_sta_ole_initialized();

        let root_hwnd = HWND(shelf_hwnd_raw as *mut _);
        if !unsafe { IsWindow(root_hwnd) }.as_bool() {
            return 0;
        }

        // Collect the shelf root HWND plus ALL descendant HWNDs (including WebView2's
        // `Chrome_WidgetWin_0`, `Chrome_WidgetWin_1`, and `Chrome_RenderWidgetHostHWND`)
        // mirroring `wry`'s `DragDropController`. WebView2's child render HWND covers 100%
        // of the shelf surface and intercepts OLE `WindowFromPoint`, so skipping it causes
        // WebView2's disabled `AllowExternalDrop(false)` target to reject every drop!
        let mut all_hwnds: Vec<HWND> = vec![root_hwnd];
        unsafe extern "system" fn collect_child(child: HWND, lparam: LPARAM) -> BOOL {
            let list = unsafe { &mut *(lparam.0 as *mut Vec<HWND>) };
            list.push(child);
            BOOL::from(true)
        }
        unsafe {
            let _ = EnumChildWindows(
                root_hwnd,
                Some(collect_child),
                LPARAM(&mut all_hwnds as *mut Vec<HWND> as isize),
            );
        }
        let valid_hwnds: Vec<HWND> = all_hwnds
            .into_iter()
            .filter(|&h| unsafe { IsWindow(h) }.as_bool())
            .collect();

        // Snapshot tracked HWND -> installed `OleDropTargetInterface` pointer under a SHORT
        // RefCell borrow — ALWAYS release `SHELF_DROP_TARGETS` BEFORE any COM
        // `RevokeDragDrop`/`RegisterDragDrop` call (which can pump Win32 STA messages!).
        let tracked_props: HashMap<isize, usize> = SHELF_DROP_TARGETS.with(|cell| {
            let Ok(mut root_map) = cell.try_borrow_mut() else {
                return HashMap::new();
            };
            let targets = root_map.entry(shelf_hwnd_raw).or_default();
            targets.retain(|&h_raw, _| unsafe { IsWindow(HWND(h_raw as *mut _)) }.as_bool());
            targets
                .iter()
                .map(|(&h_raw, entry)| (h_raw, entry.installed_prop))
                .collect()
        });

        let mut registered_batch: Vec<(isize, InstalledDropTarget)> = Vec::new();
        for h in valid_hwnds {
            let h_raw = h.0 as isize;
            let current_prop = unsafe { GetPropW(h, w!("OleDropTargetInterface")) }.0 as usize;
            if !should_reinstall_drop_target(tracked_props.get(&h_raw).copied(), current_prop) {
                continue;
            }

            let cls = hwnd_class_name(h);
            let revoke_res = unsafe { RevokeDragDrop(h) };
            if revoke_res == Err(DRAGDROP_E_INVALIDHWND.into()) {
                continue;
            }

            let drop_target: IDropTarget = ShelfDropTarget::new(Arc::clone(&callback)).into();
            match unsafe { RegisterDragDrop(h, &drop_target) } {
                Ok(()) => {
                    let installed_prop =
                        unsafe { GetPropW(h, w!("OleDropTargetInterface")) }.0 as usize;
                    registered_batch.push((
                        h_raw,
                        InstalledDropTarget {
                            _target: drop_target,
                            installed_prop,
                        },
                    ));
                    tracing::info!(
                        hwnd = h_raw,
                        class = %cls,
                        "Installed native Shelf IDropTarget"
                    );
                }
                Err(err) => {
                    tracing::debug!(
                        hwnd = h_raw,
                        class = %cls,
                        %err,
                        "Skipped native Shelf IDropTarget registration"
                    );
                }
            }
        }

        let newly_installed = registered_batch.len();
        if !registered_batch.is_empty() {
            SHELF_DROP_TARGETS.with(|cell| {
                if let Ok(mut root_map) = cell.try_borrow_mut() {
                    let targets = root_map.entry(shelf_hwnd_raw).or_default();
                    for (h_raw, entry) in registered_batch {
                        targets.insert(h_raw, entry);
                    }
                }
            });
        }

        newly_installed
    }

    pub fn cleanup(shelf_hwnd_raw: isize) {
        if let Ok(mut map) = drop_callbacks().lock() {
            map.remove(&shelf_hwnd_raw);
        }
        // Drain out of RefCell BEFORE calling `RevokeDragDrop` so re-entrant WM_NCDESTROY /
        // COM pumping can NEVER trigger a `BorrowMutError` panic across `extern "system"`.
        let drained = SHELF_DROP_TARGETS.with(|cell| {
            cell.try_borrow_mut()
                .ok()
                .and_then(|mut root_map| root_map.remove(&shelf_hwnd_raw))
        });
        if let Some(targets) = drained {
            for (h_raw, _entry) in targets {
                let h = HWND(h_raw as *mut _);
                if unsafe { IsWindow(h) }.as_bool() {
                    let _ = unsafe { RevokeDragDrop(h) };
                }
            }
        }
    }
}

/// Registers our native Win32 OLE `IDropTarget` across the Shelf HWND and all current child HWNDs.
/// MUST be called on the Win32 STA UI thread.
pub fn install_shelf_drop_target(shelf_hwnd_raw: isize, callback: ShelfDropCallback) -> usize {
    #[cfg(target_os = "windows")]
    {
        drop_target::install(shelf_hwnd_raw, callback)
    }
    #[cfg(not(target_os = "windows"))]
    {
        let _ = (shelf_hwnd_raw, callback);
        0
    }
}

/// Re-scans the Shelf HWND hierarchy and injects our native `IDropTarget` onto any newly spawned
/// WebView2 child HWNDs (`Chrome_WidgetWin_1`, `Chrome_RenderWidgetHostHWND`) lacking
/// `OleDropTargetInterface`. MUST be called on the Win32 STA UI thread.
pub fn refresh_shelf_drop_targets(shelf_hwnd_raw: isize) -> usize {
    #[cfg(target_os = "windows")]
    {
        drop_target::refresh(shelf_hwnd_raw)
    }
    #[cfg(not(target_os = "windows"))]
    {
        let _ = shelf_hwnd_raw;
        0
    }
}

#[cfg(target_os = "windows")]
fn cleanup_shelf_drop_targets(shelf_hwnd_raw: isize) {
    drop_target::cleanup(shelf_hwnd_raw);
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

    #[test]
    fn default_compact_capsule_rect_seeds_centered_physical_bounds() {
        let mon = MonitorRect {
            left: 0,
            top: 0,
            right: 2560,
            bottom: 1440,
        };
        let placement = compute_shelf_window_rect(mon, 1.5);
        let rc = default_compact_capsule_rect(placement);
        assert_eq!(rc.y, 0);
        assert_eq!(rc.width, (668.0 * 1.5_f64).round() as i32);
        assert_eq!(rc.height, (330.0 * 1.5_f64).round() as i32);
        assert_eq!(rc.x, (placement.width - rc.width) / 2);
        // Center of compact drop well must immediately be interactive at frame 0
        assert!(shelf_point_is_interactive(
            placement.width / 2,
            rc.height / 2,
            placement.width,
            1.5,
            Some(rc)
        ));
    }

    #[test]
    fn classifies_dropped_urls_hex_colors_and_plain_text_cleanly() {
        assert_eq!(
            classify_dropped_text("https://tauri.app\0"),
            Some(ShelfDropPayload::Url("https://tauri.app/".to_string()))
        );
        assert_eq!(
            classify_dropped_text("https://github.com/tauri-apps/tauri"),
            Some(ShelfDropPayload::Url(
                "https://github.com/tauri-apps/tauri".to_string()
            ))
        );
        assert_eq!(
            classify_dropped_text("Look at this tweet https://x.com/charkle/status/123456!"),
            Some(ShelfDropPayload::Url(
                "https://x.com/charkle/status/123456".to_string()
            ))
        );
        assert_eq!(
            classify_dropped_text("#2A60E0"),
            Some(ShelfDropPayload::Text("#2A60E0".to_string()))
        );
        assert_eq!(
            classify_dropped_text("Liquid glass surface notes"),
            Some(ShelfDropPayload::Text(
                "Liquid glass surface notes".to_string()
            ))
        );
        assert_eq!(classify_dropped_text("   \0\n "), None);

        let files = ShelfDropPayload::Files(vec![PathBuf::from("a.png"), PathBuf::from("b.png")]);
        assert_eq!(files.item_count(), 2);
        assert_eq!(ShelfDropPayload::Files(Vec::new()).item_count(), 1);
    }

    #[test]
    fn shelf_dock_edge_parses_and_round_trips_u8_and_str() {
        for (raw, expected, canonical) in [
            ("top", ShelfDockEdge::Top, "top"),
            ("LEFT", ShelfDockEdge::Left, "left"),
            (" Right ", ShelfDockEdge::Right, "right"),
            ("unknown", ShelfDockEdge::Top, "top"),
        ] {
            let parsed = ShelfDockEdge::from_str_lossy(raw);
            assert_eq!(parsed, expected);
            assert_eq!(parsed.as_str(), canonical);
            assert_eq!(ShelfDockEdge::from_u8(parsed.to_u8()), expected);
        }
        assert_eq!(ShelfDockEdge::from_u8(99), ShelfDockEdge::Top);
    }

    #[test]
    fn side_edge_window_placement_centers_in_work_area_and_flushes_bezel() {
        let mon = MonitorRect {
            left: 0,
            top: 0,
            right: 2560,
            bottom: 1440,
        };
        // Simulated 60px Windows taskbar at the bottom
        let work = MonitorRect {
            left: 0,
            top: 0,
            right: 2560,
            bottom: 1380,
        };

        let left_p = compute_shelf_window_rect_for_edge(mon, work, 1.5, ShelfDockEdge::Left);
        assert_eq!(left_p.x, 0);
        assert_eq!(left_p.width, (560.0 * 1.5_f64).round() as i32);
        assert_eq!(left_p.height, (760.0 * 1.5_f64).round() as i32);
        assert_eq!(left_p.y, (1380 - left_p.height) / 2);

        let right_p = compute_shelf_window_rect_for_edge(mon, work, 1.5, ShelfDockEdge::Right);
        assert_eq!(right_p.x, mon.right - right_p.width);
        assert_eq!(right_p.y, left_p.y);
        assert_eq!(right_p.width, left_p.width);
        assert_eq!(right_p.height, left_p.height);

        // Compact frame-0 hit rects stay flush on the docked bezel and vertically centered
        let left_cap = default_compact_capsule_rect_for_edge(left_p, ShelfDockEdge::Left);
        assert_eq!(left_cap.x, 0);
        assert_eq!(left_cap.y, (left_p.height - left_cap.height) / 2);

        let right_cap = default_compact_capsule_rect_for_edge(right_p, ShelfDockEdge::Right);
        assert_eq!(right_cap.x, right_p.width - right_cap.width);
        assert_eq!(right_cap.y, (right_p.height - right_cap.height) / 2);

        // Collapsed bezel hotstrip hit-testing works on Left & Right edges
        assert!(shelf_point_is_interactive_for_edge(
            1,
            left_p.height / 2,
            left_p.width,
            left_p.height,
            1.5,
            None,
            ShelfDockEdge::Left
        ));
        assert!(!shelf_point_is_interactive_for_edge(
            40,
            left_p.height / 2,
            left_p.width,
            left_p.height,
            1.5,
            None,
            ShelfDockEdge::Left
        ));
        assert!(shelf_point_is_interactive_for_edge(
            right_p.width - 1,
            right_p.height / 2,
            right_p.width,
            right_p.height,
            1.5,
            None,
            ShelfDockEdge::Right
        ));
        assert!(!shelf_point_is_interactive_for_edge(
            10,
            right_p.height / 2,
            right_p.width,
            right_p.height,
            1.5,
            None,
            ShelfDockEdge::Right
        ));
    }

    #[test]
    fn drop_target_reinstall_detects_missing_or_overwritten_ole_prop() {
        // Never registered -> must install
        assert!(should_reinstall_drop_target(None, 0));
        assert!(should_reinstall_drop_target(None, 0x1234));
        // Previously registered with matching non-zero OleDropTargetInterface -> skip
        assert!(!should_reinstall_drop_target(Some(0xABCD), 0xABCD));
        // WebView2 replaced OleDropTargetInterface with a different pointer -> must reclaim
        assert!(should_reinstall_drop_target(Some(0xABCD), 0xDEAD));
        // Property was cleared -> must reinstall
        assert!(should_reinstall_drop_target(Some(0xABCD), 0));
        // Recorded zero prop -> must reinstall
        assert!(should_reinstall_drop_target(Some(0), 0));
    }
}
