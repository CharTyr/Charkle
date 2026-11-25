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
        if hwnd_raw == 0 || !windows::Win32::UI::WindowsAndMessaging::IsWindow(hwnd).as_bool() {
            return Err("Shelf HWND is invalid or already destroyed".to_string());
        }
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
        IsWindow, SetWindowPos, ShowWindow, HWND_TOPMOST, SWP_NOACTIVATE, SWP_NOMOVE,
        SWP_NOOWNERZORDER, SWP_NOSIZE, SWP_SHOWWINDOW, SW_SHOWNOACTIVATE,
    };
    if hwnd_raw == 0 {
        return;
    }
    let hwnd = HWND(hwnd_raw as *mut _);
    // SAFETY: Showing & raising our owned topmost shelf window without stealing foreground focus.
    unsafe {
        if !IsWindow(hwnd).as_bool() {
            return;
        }
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
    use windows::Win32::UI::WindowsAndMessaging::{IsWindow, ShowWindow, SW_HIDE};
    if hwnd_raw == 0 {
        return;
    }
    let hwnd = HWND(hwnd_raw as *mut _);
    // SAFETY: Hiding our owned shelf window.
    unsafe {
        if !IsWindow(hwnd).as_bool() {
            return;
        }
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
        if hwnd_raw == 0 || !windows::Win32::UI::WindowsAndMessaging::IsWindow(hwnd).as_bool() {
            return Err("Shelf HWND is invalid or already destroyed".to_string());
        }
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

static EXTERNAL_DRAG_ACTIVE: AtomicBool = AtomicBool::new(false);

/// Returns `true` when the background edge monitor detected a primary/secondary mouse press
/// originating outside the expanded shelf capsule that is still held down.
pub fn is_external_drag_active() -> bool {
    EXTERNAL_DRAG_ACTIVE.load(Ordering::Relaxed)
}

/// Selects the best OLE `DROPEFFECT` bitmask allowed by the drag source (preferring Copy,
/// then Move, then Link) so Explorer files, folders, virtual/OneDrive items, and browser URLs
/// always display an active drop cursor rather than `DROPEFFECT_NONE`.
pub const fn select_drop_effect(allowed_effects: u32) -> u32 {
    const COPY: u32 = 1;
    const MOVE: u32 = 2;
    const LINK: u32 = 4;
    if allowed_effects == 0 || (allowed_effects & COPY) != 0 {
        COPY
    } else if (allowed_effects & MOVE) != 0 {
        MOVE
    } else if (allowed_effects & LINK) != 0 {
        LINK
    } else {
        COPY
    }
}

/// Pure predicate deciding whether the invisible own-thread Win32 Drop Catcher overlay should
/// cover `capsule_rect` during an active external drag gesture.
pub fn should_show_drop_catcher(
    is_expanded: bool,
    external_drag_active: bool,
    outbound_dragging: bool,
    drag_hovering: bool,
    cursor_x: i32,
    cursor_y: i32,
    capsule_rect: Option<ClientRect>,
) -> Option<ClientRect> {
    if !is_expanded || !external_drag_active || outbound_dragging {
        return None;
    }
    let rc = capsule_rect?;
    if rc.width <= 0 || rc.height <= 0 {
        return None;
    }
    if drag_hovering {
        return Some(rc);
    }
    let margin = 64;
    let near = cursor_x >= rc.x - margin
        && cursor_x <= rc.x + rc.width + margin
        && cursor_y >= rc.y - margin
        && cursor_y <= rc.y + rc.height + margin;
    near.then_some(rc)
}

// =============================================================================
// Predictive Low-Altitude Top Shelf Approach & System UI Auto-Yield (v1.2.2)
// =============================================================================

/// DPI-independent logical pixel rectangle (DIPs, Windows Y-down screen coordinates).
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct ShelfRectDip {
    pub left: f64,
    pub top: f64,
    pub width: f64,
    pub height: f64,
}

impl ShelfRectDip {
    pub fn from_monitor_rect(mon: MonitorRect, dpi_scale: f64) -> Self {
        let scale = dpi_scale.clamp(1.0, 4.0);
        Self {
            left: mon.left as f64 / scale,
            top: mon.top as f64 / scale,
            width: mon.width() as f64 / scale,
            height: mon.height() as f64 / scale,
        }
    }

    pub fn from_client_rect(rc: ClientRect, dpi_scale: f64) -> Self {
        let scale = dpi_scale.clamp(1.0, 4.0);
        Self {
            left: rc.x as f64 / scale,
            top: rc.y as f64 / scale,
            width: rc.width as f64 / scale,
            height: rc.height as f64 / scale,
        }
    }

    pub fn mid_x(&self) -> f64 {
        self.left + self.width * 0.5
    }

    pub fn right(&self) -> f64 {
        self.left + self.width
    }

    pub fn bottom(&self) -> f64 {
        self.top + self.height
    }
}

/// Time-stamped cursor motion sample in DPI-independent logical pixels (Y-down).
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct ShelfDragMotionSample {
    pub x: f64,
    pub y: f64,
    pub timestamp_secs: f64,
}

/// Pure, DPI-independent geometry model for 3-tier predictive upward drag approach toward
/// the Top-Edge Drop Shelf (1:1 parity with macOS `NotchDropGeometry` in logical pixels).
pub struct ShelfDropGeometry;

impl ShelfDropGeometry {
    pub const TOP_DIRECT_BAND_DIP: f64 = 76.0;
    pub const TOP_DIRECT_HALF_WIDTH_DIP: f64 = 176.0;
    pub const TOP_SLOW_BAND_DIP: f64 = 136.0;
    pub const TOP_SLOW_HALF_WIDTH_DIP: f64 = 220.0;
    pub const TOP_SLOW_MIN_UPWARD_TRAVEL_DIP: f64 = 24.0;
    pub const TOP_SLOW_MIN_UPWARD_SPEED_DIP: f64 = 25.0;
    pub const TOP_FAST_MIN_BAND_DIP: f64 = 260.0;
    pub const TOP_FAST_MAX_BAND_DIP: f64 = 350.0;
    pub const TOP_FAST_BAND_RATIO: f64 = 0.32;
    pub const TOP_FAST_MAX_HALF_WIDTH_DIP: f64 = 320.0;
    pub const TOP_FAST_HALF_WIDTH_RATIO: f64 = 0.34;
    pub const TOP_FAST_MIN_UPWARD_TRAVEL_DIP: f64 = 36.0;
    pub const TOP_FAST_MIN_UPWARD_SPEED_DIP: f64 = 240.0;
    pub const TOP_FAST_LEAD_TIME_SECS: f64 = 0.26;
    pub const TOP_FAST_PROJECTED_HALF_WIDTH_DIP: f64 = 290.0;
    pub const TOP_DOWNWARD_CANCEL_DIP: f64 = -14.0;
    pub const APPROACH_GRACE_SECS: f64 = 0.45;
    pub const APPROACH_GRACE_MARGIN_DIP: f64 = 48.0;
    pub const APPROACH_GRACE_REVERSAL_SPEED_DIP: f64 = -80.0;

    /// Computes `(vx_dip_per_sec, upward_vy_dip_per_sec)` where positive `upward_vy` means
    /// moving UP toward the top monitor bezel (decreasing Windows screen Y).
    /// Returns `(0.0, 0.0)` if samples are stale (`> 0.14s`) so pausing mid-drag decays velocity.
    pub fn recent_drag_velocity_dip(
        samples: &[ShelfDragMotionSample],
        now_secs: f64,
    ) -> (f64, f64) {
        let Some(&latest) = samples.last() else {
            return (0.0, 0.0);
        };
        if !now_secs.is_finite() || now_secs - latest.timestamp_secs > 0.14 {
            return (0.0, 0.0);
        }

        let mut anchor: Option<ShelfDragMotionSample> = None;
        for sample in samples.iter().rev().skip(1) {
            let dt = latest.timestamp_secs - sample.timestamp_secs;
            if dt > 0.14 {
                break;
            }
            anchor = Some(*sample);
            if dt >= 0.018 {
                break;
            }
        }
        let Some(anchor) = anchor else {
            return (0.0, 0.0);
        };
        let dt = latest.timestamp_secs - anchor.timestamp_secs;
        if dt < 0.008 {
            return (0.0, 0.0);
        }
        let vx = (latest.x - anchor.x) / dt;
        // Windows Y increases downward, so upward velocity is `(anchor.y - latest.y) / dt`.
        let upward_vy = (anchor.y - latest.y) / dt;
        (vx, upward_vy)
    }

    /// Evaluates the 3-tier predictive low-altitude upward drag trigger in DIP coordinates:
    /// - Tier 1 (Direct arrival): within `76 DIP` of top bezel & `±176 DIP` of center; suppresses
    ///   downward drags (`total_upward_travel <= -14 DIP`) away from app titlebars/tabs.
    /// - Tier 2 (Slow upward approach): within `136 DIP` & `±220 DIP`, upward travel `>= 24 DIP`,
    ///   upward speed `>= 25 DIP/s` and `>= 0.50 * |vx|`.
    /// - Tier 3 (Fast ballistic corridor): within `clamp(H * 0.32, 260, 350)` DIP & `min(320, W * 0.34)`,
    ///   upward travel `>= 36 DIP`, upward speed `>= 240 DIP/s` & `>= 0.65 * |vx|`, and 260ms
    ///   projected arrival within `<= 76 DIP` of top and `±290 DIP` of center.
    pub fn should_trigger_upward_drag_approach(
        point_dip: (f64, f64),
        monitor_dip: ShelfRectDip,
        drag_start_dip: Option<(f64, f64)>,
        samples: &[ShelfDragMotionSample],
        now_secs: f64,
    ) -> bool {
        if monitor_dip.width <= 0.0 || monitor_dip.height <= 0.0 {
            return false;
        }
        let dist_from_top = point_dip.1 - monitor_dip.top;
        if dist_from_top < -8.0 {
            return false;
        }

        let mid_x = monitor_dip.mid_x();
        let dx_from_center = (point_dip.0 - mid_x).abs();
        let total_upward_travel = drag_start_dip.map(|s| s.1 - point_dip.1).unwrap_or(0.0);
        let (vx, upward_vy) = Self::recent_drag_velocity_dip(samples, now_secs);

        // Tier 1: Direct top-center arrival band
        if dist_from_top <= Self::TOP_DIRECT_BAND_DIP
            && dx_from_center <= Self::TOP_DIRECT_HALF_WIDTH_DIP
        {
            if drag_start_dip.is_some() && total_upward_travel <= Self::TOP_DOWNWARD_CANCEL_DIP {
                return false;
            }
            return true;
        }

        // Tier 2: Low-altitude slow/steady upward drag
        if dist_from_top <= Self::TOP_SLOW_BAND_DIP
            && dx_from_center <= Self::TOP_SLOW_HALF_WIDTH_DIP
            && total_upward_travel >= Self::TOP_SLOW_MIN_UPWARD_TRAVEL_DIP
            && upward_vy >= Self::TOP_SLOW_MIN_UPWARD_SPEED_DIP
            && upward_vy >= vx.abs() * 0.50
        {
            return true;
        }

        // Tier 3: Fast upward 260ms ballistic corridor
        let corridor_depth = (monitor_dip.height * Self::TOP_FAST_BAND_RATIO)
            .clamp(Self::TOP_FAST_MIN_BAND_DIP, Self::TOP_FAST_MAX_BAND_DIP);
        let corridor_half_w = Self::TOP_FAST_MAX_HALF_WIDTH_DIP
            .min(monitor_dip.width * Self::TOP_FAST_HALF_WIDTH_RATIO);
        if dist_from_top <= corridor_depth
            && dx_from_center <= corridor_half_w
            && total_upward_travel >= Self::TOP_FAST_MIN_UPWARD_TRAVEL_DIP
            && upward_vy >= Self::TOP_FAST_MIN_UPWARD_SPEED_DIP
            && upward_vy >= vx.abs() * 0.65
        {
            let projected_dist = dist_from_top - upward_vy * Self::TOP_FAST_LEAD_TIME_SECS;
            let projected_x = point_dip.0 + vx * Self::TOP_FAST_LEAD_TIME_SECS;
            if projected_dist <= Self::TOP_DIRECT_BAND_DIP
                && (projected_x - mid_x).abs() <= Self::TOP_FAST_PROJECTED_HALF_WIDTH_DIP
            {
                return true;
            }
        }

        false
    }

    /// Evaluates whether a predictively expanded shelf should stay open during its `0.45s`
    /// approach grace window while the user finishes dragging into the capsule.
    pub fn should_hold_early_expand_grace(
        point_dip: (f64, f64),
        capsule_dip: Option<ShelfRectDip>,
        upward_vy_dip: f64,
        elapsed_since_trigger_secs: f64,
    ) -> bool {
        if elapsed_since_trigger_secs < 0.0
            || elapsed_since_trigger_secs > Self::APPROACH_GRACE_SECS
        {
            return false;
        }
        if upward_vy_dip < Self::APPROACH_GRACE_REVERSAL_SPEED_DIP {
            return false;
        }
        let Some(cap) = capsule_dip else {
            return true;
        };
        let m = Self::APPROACH_GRACE_MARGIN_DIP;
        let near_capsule = point_dip.0 >= cap.left - m
            && point_dip.0 <= cap.right() + m
            && point_dip.1 >= cap.top - 12.0
            && point_dip.1 <= cap.bottom() + m;
        near_capsule
            || (upward_vy_dip >= 0.0
                && point_dip.0 >= cap.left - m * 2.0
                && point_dip.0 <= cap.right() + m * 2.0
                && point_dip.1 <= cap.bottom() + 180.0)
    }
}

/// Returns `true` for Windows Task View / Multitasking / Virtual Desktops shell overlay classes
/// that the Top-Edge Drop Shelf must immediately yield to.
pub fn is_system_task_view_class(class_name: &str) -> bool {
    let trimmed = class_name.trim();
    trimmed.eq_ignore_ascii_case("XamlExplorerHostIslandWindow")
        || trimmed.eq_ignore_ascii_case("MultitaskingViewFrame")
}

/// Returns `true` for ordinary Windows desktop/taskbar shell classes that must NEVER be
/// mistaken for an exclusive fullscreen app.
pub fn is_desktop_shell_class(class_name: &str) -> bool {
    let trimmed = class_name.trim();
    trimmed.eq_ignore_ascii_case("Progman")
        || trimmed.eq_ignore_ascii_case("WorkerW")
        || trimmed.eq_ignore_ascii_case("Shell_TrayWnd")
        || trimmed.eq_ignore_ascii_case("Shell_SecondaryTrayWnd")
}

/// Pure predicate deciding whether a foreground window covering `fg_rect` on `active_monitor`
/// should cause the Drop Shelf to auto-yield (Task View or borderless fullscreen video/game).
pub fn should_yield_for_foreground_window(
    class_name: &str,
    is_own_process: bool,
    is_visible: bool,
    is_minimized: bool,
    fg_rect: MonitorRect,
    active_monitor: MonitorRect,
) -> bool {
    if is_own_process || !is_visible || is_minimized {
        return false;
    }
    if is_system_task_view_class(class_name) {
        return true;
    }
    if is_desktop_shell_class(class_name)
        || active_monitor.width() <= 0
        || active_monitor.height() <= 0
    {
        return false;
    }
    // Borderless fullscreen app/video covering the entire monitor (including taskbar area)
    fg_rect.left <= active_monitor.left
        && fg_rect.top <= active_monitor.top
        && fg_rect.right >= active_monitor.right
        && fg_rect.bottom >= active_monitor.bottom
}

#[cfg(target_os = "windows")]
fn is_system_overlay_or_fullscreen_blocking(active_monitor: MonitorRect) -> bool {
    use windows::Win32::Foundation::RECT;
    use windows::Win32::System::Threading::GetCurrentProcessId;
    use windows::Win32::UI::Shell::{
        SHQueryUserNotificationState, QUNS_BUSY, QUNS_PRESENTATION_MODE,
        QUNS_RUNNING_D3D_FULL_SCREEN,
    };
    use windows::Win32::UI::WindowsAndMessaging::{
        GetClassNameW, GetForegroundWindow, GetWindowRect, GetWindowThreadProcessId, IsIconic,
        IsWindowVisible,
    };

    // 1. OS-level exclusive fullscreen / presentation / fullscreen-video state probe.
    if let Ok(state) = unsafe { SHQueryUserNotificationState() } {
        if matches!(
            state,
            QUNS_BUSY | QUNS_RUNNING_D3D_FULL_SCREEN | QUNS_PRESENTATION_MODE
        ) {
            return true;
        }
    }

    // 2. Foreground window class check for Task View / Virtual Desktops & borderless fullscreen.
    let fg = unsafe { GetForegroundWindow() };
    if fg.0.is_null() {
        return false;
    }
    let mut fg_pid = 0u32;
    unsafe { GetWindowThreadProcessId(fg, Some(&mut fg_pid)) };
    let is_own_process = fg_pid == unsafe { GetCurrentProcessId() };
    let is_visible = unsafe { IsWindowVisible(fg) }.as_bool();
    let is_minimized = unsafe { IsIconic(fg) }.as_bool();

    let mut cls_buf = [0u16; 128];
    let cls_len = unsafe { GetClassNameW(fg, &mut cls_buf) };
    let cls_name = if cls_len > 0 {
        String::from_utf16_lossy(&cls_buf[..cls_len as usize])
    } else {
        String::new()
    };

    let mut rc = RECT::default();
    let fg_rect = if unsafe { GetWindowRect(fg, &mut rc) }.is_ok() {
        MonitorRect {
            left: rc.left,
            top: rc.top,
            right: rc.right,
            bottom: rc.bottom,
        }
    } else {
        MonitorRect {
            left: 0,
            top: 0,
            right: 0,
            bottom: 0,
        }
    };

    should_yield_for_foreground_window(
        &cls_name,
        is_own_process,
        is_visible,
        is_minimized,
        fg_rect,
        active_monitor,
    )
}

/// Starts a lightweight background cursor monitor that:
/// 1. Predictively springs the Top-Edge Drop Shelf open via 3-tier low-altitude upward drag
///    approach (DPI-independent DIPs) or side-edge bezel drag.
/// 2. Optionally springs the Drop Shelf open when hovering at the docked bezel for ~180ms.
/// 3. Smoothly auto-collapses an unpinned Drop Shelf after the cursor leaves the active capsule
///    (respecting a `0.45s` predictive approach grace window).
/// 4. Auto-yields immediately when Windows Task View / Virtual Desktops or an exclusive fullscreen
///    app/video is active.
/// 5. Coordinates the own-thread Win32 Drop Catcher overlay via `on_sync_catcher` during external drags.
pub fn start_top_edge_monitor_with_yield<FOpen, FClose, FYield, FSyncCatcher>(
    config: ShelfMonitorConfig,
    on_open: FOpen,
    on_auto_collapse: FClose,
    on_system_yield: FYield,
    on_sync_catcher: FSyncCatcher,
) -> TopEdgeDragMonitorHandle
where
    FOpen: Fn() + Send + 'static,
    FClose: Fn() + Send + 'static,
    FYield: Fn() + Send + 'static,
    FSyncCatcher: Fn(Option<ClientRect>) + Send + 'static,
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
            use windows::Win32::UI::HiDpi::{GetDpiForMonitor, MDT_EFFECTIVE_DPI};
            use windows::Win32::UI::Input::KeyboardAndMouse::{
                GetAsyncKeyState, VK_LBUTTON, VK_RBUTTON,
            };
            use windows::Win32::UI::WindowsAndMessaging::{
                GetCursorPos, GetSystemMetrics, SM_SWAPBUTTON,
            };

            let start_epoch = Instant::now();
            let mut drag_triggered = false;
            let mut prev_drag_button_down = false;
            let mut external_drag_active = false;
            let mut last_catcher_rect: Option<ClientRect> = None;
            let mut hover_since: Option<Instant> = None;
            let mut outside_since: Option<Instant> = None;
            let mut stale_drag_since: Option<Instant> = None;
            let mut open_cooldown_until: Option<Instant> = None;
            let mut early_expand_at: Option<Instant> = None;
            let mut drag_start_dip: Option<(f64, f64)> = None;
            let mut motion_samples: Vec<ShelfDragMotionSample> = Vec::with_capacity(24);
            let mut last_hmon_key: Option<isize> = None;
            let mut cached_dpi_scale: f64 = 1.0;
            let mut idle_ticks: u32 = 0;

            while !stop_clone.load(Ordering::Relaxed) {
                let active_sampling = external_drag_active
                    || config.shelf_expanded.load(Ordering::Relaxed)
                    || hover_since.is_some();
                std::thread::sleep(Duration::from_millis(if active_sampling { 16 } else { 45 }));

                if !config.enabled.load(Ordering::Relaxed) {
                    drag_triggered = false;
                    prev_drag_button_down = false;
                    external_drag_active = false;
                    drag_start_dip = None;
                    motion_samples.clear();
                    early_expand_at = None;
                    EXTERNAL_DRAG_ACTIVE.store(false, Ordering::Relaxed);
                    if last_catcher_rect.take().is_some() {
                        on_sync_catcher(None);
                    }
                    hover_since = None;
                    outside_since = None;
                    continue;
                }

                let mut pt = POINT::default();
                if unsafe { GetCursorPos(&mut pt) }.is_err() {
                    continue;
                }

                // SAFETY: Stateless Win32 input state probe; respects left-handed swapped mouse buttons
                // and supports both primary-button and secondary-button Explorer drags.
                let swapped = unsafe { GetSystemMetrics(SM_SWAPBUTTON) } != 0;
                let primary_vk = if swapped {
                    VK_RBUTTON.0 as i32
                } else {
                    VK_LBUTTON.0 as i32
                };
                let secondary_vk = if swapped {
                    VK_LBUTTON.0 as i32
                } else {
                    VK_RBUTTON.0 as i32
                };
                let lbutton_down = unsafe { (GetAsyncKeyState(primary_vk) as u16) & 0x8000 } != 0;
                let rbutton_down = unsafe { (GetAsyncKeyState(secondary_vk) as u16) & 0x8000 } != 0;
                let any_drag_button_down = lbutton_down || rbutton_down;

                let is_expanded = config.shelf_expanded.load(Ordering::Relaxed);
                let hwnd_raw = config.shelf_hwnd.load(Ordering::Relaxed);
                let active_rc = active_shelf_screen_rect(hwnd_raw);
                let inside_capsule_strict = is_expanded
                    && active_rc.is_some_and(|rc| {
                        pt.x >= rc.x
                            && pt.x < rc.x + rc.width
                            && pt.y >= rc.y
                            && pt.y < rc.y + rc.height
                    });

                let hmon = unsafe { MonitorFromPoint(pt, MONITOR_DEFAULTTONEAREST) };
                let hmon_key = hmon.0 as isize;
                if last_hmon_key != Some(hmon_key) {
                    last_hmon_key = Some(hmon_key);
                    let mut dpi_x: u32 = 96;
                    let mut dpi_y: u32 = 96;
                    let _ = unsafe {
                        GetDpiForMonitor(hmon, MDT_EFFECTIVE_DPI, &mut dpi_x, &mut dpi_y)
                    };
                    cached_dpi_scale = (dpi_x as f64 / 96.0).clamp(1.0, 4.0);
                    // Reset predictive drag history cleanly on cross-monitor transitions.
                    drag_start_dip = None;
                    motion_samples.clear();
                }

                let mut info = MONITORINFO {
                    cbSize: std::mem::size_of::<MONITORINFO>() as u32,
                    ..Default::default()
                };
                if !unsafe { GetMonitorInfoW(hmon, &mut info) }.as_bool() {
                    continue;
                }

                let mon = info.rcMonitor;
                let work = info.rcWork;
                let mon_rect = MonitorRect {
                    left: mon.left,
                    top: mon.top,
                    right: mon.right,
                    bottom: mon.bottom,
                };
                let mon_dip = ShelfRectDip::from_monitor_rect(mon_rect, cached_dpi_scale);
                let pt_dip = (
                    pt.x as f64 / cached_dpi_scale,
                    pt.y as f64 / cached_dpi_scale,
                );
                let now_secs = start_epoch.elapsed().as_secs_f64();

                if any_drag_button_down && !prev_drag_button_down {
                    // Only treat presses that originated OUTSIDE the visible shelf capsule as
                    // external drags (clicks, marquee box-select, scroll drags, and outbound card
                    // drags starting inside the shelf never activate the drop catcher).
                    external_drag_active = !inside_capsule_strict;
                    if external_drag_active {
                        drag_start_dip = Some(pt_dip);
                        motion_samples.clear();
                        motion_samples.push(ShelfDragMotionSample {
                            x: pt_dip.0,
                            y: pt_dip.1,
                            timestamp_secs: now_secs,
                        });
                    } else {
                        drag_start_dip = None;
                        motion_samples.clear();
                    }
                } else if !any_drag_button_down {
                    external_drag_active = false;
                    drag_triggered = false;
                    drag_start_dip = None;
                    motion_samples.clear();
                    early_expand_at = None;
                } else if external_drag_active {
                    if drag_start_dip.is_none() {
                        drag_start_dip = Some(pt_dip);
                    }
                    motion_samples.push(ShelfDragMotionSample {
                        x: pt_dip.0,
                        y: pt_dip.1,
                        timestamp_secs: now_secs,
                    });
                    let cutoff = now_secs - 0.25;
                    while motion_samples.len() > 24
                        || motion_samples
                            .first()
                            .is_some_and(|s| s.timestamp_secs < cutoff)
                    {
                        motion_samples.remove(0);
                    }
                }
                prev_drag_button_down = any_drag_button_down;
                EXTERNAL_DRAG_ACTIVE.store(external_drag_active, Ordering::Relaxed);

                // Probe Windows Task View / Virtual Desktops / Exclusive Fullscreen auto-yield.
                idle_ticks = idle_ticks.wrapping_add(1);
                let should_probe_system_ui = external_drag_active
                    || is_expanded
                    || hover_since.is_some()
                    || idle_ticks % 6 == 0;
                if should_probe_system_ui && is_system_overlay_or_fullscreen_blocking(mon_rect) {
                    hover_since = None;
                    outside_since = None;
                    early_expand_at = None;
                    if last_catcher_rect.take().is_some() {
                        on_sync_catcher(None);
                    }
                    if is_expanded {
                        on_system_yield();
                    }
                    continue;
                }

                let desired_catcher = should_show_drop_catcher(
                    is_expanded,
                    external_drag_active,
                    is_shelf_outbound_dragging(hwnd_raw),
                    config.shelf_drag_hovering.load(Ordering::Relaxed),
                    pt.x,
                    pt.y,
                    active_rc,
                );
                if desired_catcher != last_catcher_rect {
                    last_catcher_rect = desired_catcher;
                    on_sync_catcher(desired_catcher);
                }

                let center_x = (mon.left + mon.right) / 2;
                let work_center_y = (work.top + work.bottom) / 2;
                let edge = ShelfDockEdge::from_u8(config.dock_edge.load(Ordering::Relaxed));
                let is_pinned = config.shelf_pinned.load(Ordering::Relaxed);

                if !is_expanded {
                    outside_since = None;
                    early_expand_at = None;
                    if external_drag_active {
                        let triggered = match edge {
                            ShelfDockEdge::Top => {
                                ShelfDropGeometry::should_trigger_upward_drag_approach(
                                    pt_dip,
                                    mon_dip,
                                    drag_start_dip,
                                    &motion_samples,
                                    now_secs,
                                )
                            }
                            ShelfDockEdge::Left => {
                                let strip = (10.0 * cached_dpi_scale).round() as i32;
                                let half = (220.0 * cached_dpi_scale).round() as i32;
                                pt.x >= mon.left
                                    && pt.x <= mon.left + strip
                                    && (pt.y - work_center_y).abs() <= half
                            }
                            ShelfDockEdge::Right => {
                                let strip = (10.0 * cached_dpi_scale).round() as i32;
                                let half = (220.0 * cached_dpi_scale).round() as i32;
                                pt.x >= mon.right - strip
                                    && pt.x <= mon.right
                                    && (pt.y - work_center_y).abs() <= half
                            }
                        };
                        if triggered {
                            if !drag_triggered
                                && open_cooldown_until.is_none_or(|t| Instant::now() >= t)
                            {
                                drag_triggered = true;
                                hover_since = None;
                                let now = Instant::now();
                                open_cooldown_until = Some(now + Duration::from_millis(450));
                                if edge == ShelfDockEdge::Top && (pt_dip.1 - mon_dip.top) > 12.0 {
                                    early_expand_at = Some(now);
                                }
                                on_open();
                            }
                            continue;
                        }
                    }

                    // Optional docked-edge hover dwell trigger (~180ms) matching macOS NotchShelfController
                    if !any_drag_button_down && config.hover_trigger_enabled.load(Ordering::Relaxed)
                    {
                        let strip_h = (3.0 * cached_dpi_scale).round().max(3.0) as i32;
                        let strip_half = (140.0 * cached_dpi_scale).round() as i32;
                        let in_hover_strip = match edge {
                            ShelfDockEdge::Top => {
                                pt.y >= mon.top
                                    && pt.y <= mon.top + strip_h
                                    && (pt.x - center_x).abs() <= strip_half
                            }
                            ShelfDockEdge::Left => {
                                pt.x >= mon.left
                                    && pt.x <= mon.left + strip_h
                                    && (pt.y - work_center_y).abs() <= strip_half
                            }
                            ShelfDockEdge::Right => {
                                pt.x >= mon.right - strip_h
                                    && pt.x <= mon.right
                                    && (pt.y - work_center_y).abs() <= strip_half
                            }
                        };
                        if in_hover_strip && open_cooldown_until.is_none_or(|t| Instant::now() >= t)
                        {
                            let started = hover_since.get_or_insert_with(Instant::now);
                            if started.elapsed() >= Duration::from_millis(180) {
                                hover_since = None;
                                open_cooldown_until =
                                    Some(Instant::now() + Duration::from_millis(500));
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
                    if config.shelf_drag_hovering.load(Ordering::Relaxed) && !any_drag_button_down {
                        let started = stale_drag_since.get_or_insert_with(Instant::now);
                        if started.elapsed() >= Duration::from_millis(150) {
                            config.shelf_drag_hovering.store(false, Ordering::SeqCst);
                            stale_drag_since = None;
                        }
                    } else {
                        stale_drag_since = None;
                    }
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

                    // Honor the 0.45s predictive approach grace window unless the user clearly
                    // reverses downward away from the shelf.
                    let (_, upward_vy) =
                        ShelfDropGeometry::recent_drag_velocity_dip(&motion_samples, now_secs);
                    if let Some(early_started) = early_expand_at {
                        let capsule_dip = active_rc
                            .map(|rc| ShelfRectDip::from_client_rect(rc, cached_dpi_scale));
                        if any_drag_button_down
                            && ShelfDropGeometry::should_hold_early_expand_grace(
                                pt_dip,
                                capsule_dip,
                                upward_vy,
                                early_started.elapsed().as_secs_f64(),
                            )
                        {
                            outside_since = None;
                            continue;
                        }
                        early_expand_at = None;
                    }

                    // Auto-collapse unpinned shelf once cursor leaves the active capsule rect
                    // (+24 DIP outward grace, +8 DIP bezel grace on the docked edge).
                    let inside_capsule = if let Some(rc) = active_rc {
                        let margin = (24.0 * cached_dpi_scale).round() as i32;
                        let edge_grace = (8.0 * cached_dpi_scale).round() as i32;
                        match edge {
                            ShelfDockEdge::Top => {
                                pt.x >= rc.x - margin
                                    && pt.x <= rc.x + rc.width + margin
                                    && pt.y >= rc.y - edge_grace
                                    && pt.y <= rc.y + rc.height + margin
                            }
                            ShelfDockEdge::Left => {
                                pt.x >= rc.x - edge_grace
                                    && pt.x <= rc.x + rc.width + margin
                                    && pt.y >= rc.y - margin
                                    && pt.y <= rc.y + rc.height + margin
                            }
                            ShelfDockEdge::Right => {
                                pt.x >= rc.x - margin
                                    && pt.x <= rc.x + rc.width + edge_grace
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
                    } else if !any_drag_button_down
                        || upward_vy < ShelfDropGeometry::APPROACH_GRACE_REVERSAL_SPEED_DIP
                    {
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
    let _ = (
        config,
        on_open,
        on_auto_collapse,
        on_system_yield,
        on_sync_catcher,
        stop_clone,
    );

    TopEdgeDragMonitorHandle { stop }
}

/// Backward-compatible wrapper starting the top-edge monitor with catcher sync.
pub fn start_top_edge_monitor_with_catcher<FOpen, FClose, FSyncCatcher>(
    config: ShelfMonitorConfig,
    on_open: FOpen,
    on_auto_collapse: FClose,
    on_sync_catcher: FSyncCatcher,
) -> TopEdgeDragMonitorHandle
where
    FOpen: Fn() + Send + 'static,
    FClose: Fn() + Send + 'static,
    FSyncCatcher: Fn(Option<ClientRect>) + Send + 'static,
{
    start_top_edge_monitor_with_yield(config, on_open, on_auto_collapse, || {}, on_sync_catcher)
}

/// Starts the top-edge monitor without a separate catcher callback.
pub fn start_top_edge_monitor<FOpen, FClose>(
    config: ShelfMonitorConfig,
    on_open: FOpen,
    on_auto_collapse: FClose,
) -> TopEdgeDragMonitorHandle
where
    FOpen: Fn() + Send + 'static,
    FClose: Fn() + Send + 'static,
{
    start_top_edge_monitor_with_catcher(config, on_open, on_auto_collapse, |_| {})
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
    use windows::Win32::Foundation::{
        BOOL, COLORREF, DRAGDROP_E_INVALIDHWND, HGLOBAL, HINSTANCE, HWND, LPARAM, LRESULT, POINTL,
        RECT, WPARAM,
    };
    use windows::Win32::Graphics::Gdi::{FillRect, GetStockObject, BLACK_BRUSH, HBRUSH, HDC};
    use windows::Win32::System::Com::{
        CoTaskMemFree, IDataObject, DVASPECT_CONTENT, FORMATETC, STGMEDIUM, TYMED_HGLOBAL,
    };
    use windows::Win32::System::DataExchange::RegisterClipboardFormatW;
    use windows::Win32::System::LibraryLoader::GetModuleHandleW;
    use windows::Win32::System::Memory::{GlobalLock, GlobalSize, GlobalUnlock};
    use windows::Win32::System::Ole::{
        IDropTarget, IDropTarget_Impl, OleInitialize, RegisterDragDrop, ReleaseStgMedium,
        RevokeDragDrop, CF_HDROP, CF_UNICODETEXT, DROPEFFECT, DROPEFFECT_NONE,
    };
    use windows::Win32::System::SystemServices::MODIFIERKEYS_FLAGS;
    use windows::Win32::System::Threading::{GetCurrentProcessId, GetCurrentThreadId};
    use windows::Win32::UI::Shell::{
        DragQueryFileW, IShellItemArray, SHCreateShellItemArrayFromDataObject, HDROP,
        SIGDN_FILESYSPATH,
    };
    use windows::Win32::UI::WindowsAndMessaging::{
        CreateWindowExW, DefWindowProcW, DestroyWindow, EnumChildWindows, GetClassNameW,
        GetClientRect, GetPropW, GetWindowThreadProcessId, IsWindow, RegisterClassExW,
        SetLayeredWindowAttributes, SetWindowPos, ShowWindow, HWND_TOPMOST, LWA_ALPHA,
        MA_NOACTIVATE, SWP_NOACTIVATE, SWP_NOOWNERZORDER, SWP_SHOWWINDOW, SW_HIDE,
        SW_SHOWNOACTIVATE, WM_ERASEBKGND, WM_MOUSEACTIVATE, WNDCLASSEXW, WS_EX_LAYERED,
        WS_EX_TOOLWINDOW, WS_EX_TOPMOST, WS_POPUP,
    };

    static SHELF_DROP_CALLBACKS: OnceLock<Mutex<HashMap<isize, ShelfDropCallback>>> =
        OnceLock::new();
    static CATCHER_CLASS_REGISTERED: std::sync::Once = std::sync::Once::new();

    fn drop_callbacks() -> &'static Mutex<HashMap<isize, ShelfDropCallback>> {
        SHELF_DROP_CALLBACKS.get_or_init(|| Mutex::new(HashMap::new()))
    }

    struct InstalledDropTarget {
        _target: IDropTarget,
        installed_prop: usize,
    }

    struct DropCatcherEntry {
        hwnd: HWND,
        _target: IDropTarget,
        visible: bool,
        last_rect: Option<ClientRect>,
    }

    // STA-bound COM `IDropTarget` references and Drop Catcher HWNDs live strictly on the Win32 UI
    // thread that owns the Shelf HWND and registered them, keeping COM lifetimes alive until `WM_NCDESTROY`.
    thread_local! {
        static OLE_INIT_DONE: Cell<bool> = const { Cell::new(false) };
        static REFRESH_IN_PROGRESS: Cell<bool> = const { Cell::new(false) };
        static SHELF_DROP_TARGETS: RefCell<HashMap<isize, HashMap<isize, InstalledDropTarget>>> =
            RefCell::new(HashMap::new());
        static SHELF_DROP_CATCHERS: RefCell<HashMap<isize, DropCatcherEntry>> =
            RefCell::new(HashMap::new());
    }

    unsafe extern "system" fn catcher_wnd_proc(
        hwnd: HWND,
        msg: u32,
        wparam: WPARAM,
        lparam: LPARAM,
    ) -> LRESULT {
        let handled = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| match msg {
            WM_MOUSEACTIVATE => Some(LRESULT(MA_NOACTIVATE as isize)),
            WM_ERASEBKGND => {
                let hdc = HDC(wparam.0 as *mut _);
                if !hdc.is_invalid() {
                    let mut rc = RECT::default();
                    if unsafe { GetClientRect(hwnd, &mut rc) }.is_ok() {
                        let brush = HBRUSH(unsafe { GetStockObject(BLACK_BRUSH) }.0);
                        let _ = unsafe { FillRect(hdc, &rc, brush) };
                    }
                }
                Some(LRESULT(1))
            }
            _ => None,
        }));
        if let Ok(Some(res)) = handled {
            return res;
        }
        unsafe { DefWindowProcW(hwnd, msg, wparam, lparam) }
    }

    fn ensure_catcher_class_registered() -> HINSTANCE {
        let hinst: HINSTANCE = unsafe { GetModuleHandleW(None) }
            .map(Into::into)
            .unwrap_or_default();
        CATCHER_CLASS_REGISTERED.call_once(|| {
            let wc = WNDCLASSEXW {
                cbSize: std::mem::size_of::<WNDCLASSEXW>() as u32,
                lpfnWndProc: Some(catcher_wnd_proc),
                hInstance: hinst,
                hbrBackground: HBRUSH(unsafe { GetStockObject(BLACK_BRUSH) }.0),
                lpszClassName: w!("CharkleShelfDropCatcher"),
                ..Default::default()
            };
            let _ = unsafe { RegisterClassExW(&wc) };
        });
        hinst
    }

    struct RefreshGuard;
    impl Drop for RefreshGuard {
        fn drop(&mut self) {
            REFRESH_IN_PROGRESS.with(|flag| flag.set(false));
        }
    }

    fn is_own_thread_hwnd(hwnd: HWND, cur_pid: u32, cur_tid: u32) -> bool {
        let mut pid = 0u32;
        // SAFETY: Read-only Win32 thread/process ownership query.
        let tid = unsafe { GetWindowThreadProcessId(hwnd, Some(&mut pid)) };
        pid == cur_pid && tid == cur_tid
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
        auto_hide_shelf_raw: isize,
        enter_is_valid: Cell<bool>,
        cursor_effect: Cell<DROPEFFECT>,
    }

    impl ShelfDropTarget {
        fn new(callback: ShelfDropCallback, auto_hide_shelf_raw: isize) -> Self {
            Self {
                callback,
                auto_hide_shelf_raw,
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
            let _ = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                self.enter_is_valid.set(false);
                self.cursor_effect.set(DROPEFFECT_NONE);

                if let Some(payload) = extract_shelf_drop_payload(pdataobj) {
                    let count = payload.item_count();
                    let allowed = if !pdweffect.is_null() {
                        // SAFETY: Valid COM in/out pointer per `IDropTarget::DragEnter`.
                        unsafe { (*pdweffect).0 }
                    } else {
                        0
                    };
                    let chosen = DROPEFFECT(select_drop_effect(allowed));
                    self.enter_is_valid.set(true);
                    self.cursor_effect.set(chosen);
                    if !pdweffect.is_null() {
                        unsafe { *pdweffect = chosen };
                    }
                    (self.callback)(ShelfDropEvent::Enter { count });
                } else if !pdweffect.is_null() {
                    unsafe { *pdweffect = DROPEFFECT_NONE };
                }
            }));
            Ok(())
        }

        fn DragOver(
            &self,
            _grfkeystate: MODIFIERKEYS_FLAGS,
            _pt: &POINTL,
            pdweffect: *mut DROPEFFECT,
        ) -> windows::core::Result<()> {
            let _ = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                if self.enter_is_valid.get() {
                    if !pdweffect.is_null() {
                        let allowed = unsafe { (*pdweffect).0 };
                        let chosen = if allowed == 0 {
                            self.cursor_effect.get()
                        } else {
                            DROPEFFECT(select_drop_effect(allowed))
                        };
                        self.cursor_effect.set(chosen);
                        unsafe { *pdweffect = chosen };
                    }
                    (self.callback)(ShelfDropEvent::Over);
                } else if !pdweffect.is_null() {
                    unsafe { *pdweffect = DROPEFFECT_NONE };
                }
            }));
            Ok(())
        }

        fn DragLeave(&self) -> windows::core::Result<()> {
            let _ = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                let was_valid = self.enter_is_valid.replace(false);
                self.cursor_effect.set(DROPEFFECT_NONE);
                if was_valid {
                    (self.callback)(ShelfDropEvent::Leave);
                }
            }));
            Ok(())
        }

        fn Drop(
            &self,
            pdataobj: Option<&IDataObject>,
            _grfkeystate: MODIFIERKEYS_FLAGS,
            _pt: &POINTL,
            pdweffect: *mut DROPEFFECT,
        ) -> windows::core::Result<()> {
            let _ = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                let fallback_effect = self.cursor_effect.get();
                self.enter_is_valid.set(false);
                self.cursor_effect.set(DROPEFFECT_NONE);

                // Immediately hide the invisible Drop Catcher overlay synchronously on the UI
                // thread so the Drop Shelf underneath is clickable again with 0ms delay.
                if self.auto_hide_shelf_raw != 0 {
                    sync_catcher(self.auto_hide_shelf_raw, None);
                }

                if let Some(payload) = extract_shelf_drop_payload(pdataobj) {
                    if !pdweffect.is_null() {
                        let allowed = unsafe { (*pdweffect).0 };
                        let chosen = if allowed == 0 && fallback_effect.0 != 0 {
                            fallback_effect
                        } else {
                            DROPEFFECT(select_drop_effect(allowed))
                        };
                        unsafe { *pdweffect = chosen };
                    }
                    (self.callback)(ShelfDropEvent::Drop(payload));
                } else {
                    if !pdweffect.is_null() {
                        unsafe { *pdweffect = DROPEFFECT_NONE };
                    }
                    (self.callback)(ShelfDropEvent::Leave);
                }
            }));
            Ok(())
        }
    }

    fn ensure_catcher_exists(shelf_hwnd_raw: isize) -> Option<HWND> {
        if shelf_hwnd_raw == 0 {
            return None;
        }
        let existing = SHELF_DROP_CATCHERS.with(|cell| {
            cell.try_borrow().ok().and_then(|map| {
                map.get(&shelf_hwnd_raw).and_then(|entry| {
                    unsafe { IsWindow(entry.hwnd) }
                        .as_bool()
                        .then_some(entry.hwnd)
                })
            })
        });
        if existing.is_some() {
            return existing;
        }

        let callback = drop_callbacks()
            .lock()
            .ok()
            .and_then(|m| m.get(&shelf_hwnd_raw).cloned())?;

        ensure_sta_ole_initialized();
        let hinst = ensure_catcher_class_registered();

        // Pure own-process, own-thread layered popup (`alpha = 1/255`, visually invisible over
        // the pure-black notch yet 100% hit-testable by Windows OLE `DoDragDrop`). Never sets
        // `WS_EX_NOACTIVATE` or `WS_EX_TRANSPARENT`, and never touches cross-process WebView2 HWNDs.
        let hwnd = unsafe {
            CreateWindowExW(
                WS_EX_TOPMOST | WS_EX_TOOLWINDOW | WS_EX_LAYERED,
                w!("CharkleShelfDropCatcher"),
                w!(""),
                WS_POPUP,
                0,
                0,
                1,
                1,
                None,
                None,
                hinst,
                None,
            )
        }
        .ok()?;

        let _ = unsafe { SetLayeredWindowAttributes(hwnd, COLORREF(0), 1, LWA_ALPHA) };
        let drop_target: IDropTarget = ShelfDropTarget::new(callback, shelf_hwnd_raw).into();
        if let Err(err) = unsafe { RegisterDragDrop(hwnd, &drop_target) } {
            tracing::warn!(%err, "Failed to register OLE IDropTarget on CharkleShelfDropCatcher");
            let _ = unsafe { DestroyWindow(hwnd) };
            return None;
        }

        SHELF_DROP_CATCHERS.with(|cell| {
            if let Ok(mut map) = cell.try_borrow_mut() {
                map.insert(
                    shelf_hwnd_raw,
                    DropCatcherEntry {
                        hwnd,
                        _target: drop_target,
                        visible: false,
                        last_rect: None,
                    },
                );
            }
        });
        tracing::info!(
            shelf_hwnd = shelf_hwnd_raw,
            catcher_hwnd = hwnd.0 as isize,
            "Created pure Win32 CharkleShelfDropCatcher overlay"
        );
        Some(hwnd)
    }

    pub fn sync_catcher(shelf_hwnd_raw: isize, screen_rect: Option<ClientRect>) {
        if shelf_hwnd_raw == 0 {
            return;
        }

        match screen_rect {
            Some(rc) if rc.width > 0 && rc.height > 0 => {
                let Some(hwnd) = ensure_catcher_exists(shelf_hwnd_raw) else {
                    return;
                };
                let needs_update = SHELF_DROP_CATCHERS.with(|cell| {
                    cell.try_borrow()
                        .ok()
                        .and_then(|map| {
                            map.get(&shelf_hwnd_raw)
                                .map(|entry| !entry.visible || entry.last_rect != Some(rc))
                        })
                        .unwrap_or(true)
                });
                if !needs_update {
                    return;
                }
                unsafe {
                    let _ = SetWindowPos(
                        hwnd,
                        HWND_TOPMOST,
                        rc.x,
                        rc.y,
                        rc.width,
                        rc.height,
                        SWP_NOACTIVATE | SWP_NOOWNERZORDER | SWP_SHOWWINDOW,
                    );
                    let _ = ShowWindow(hwnd, SW_SHOWNOACTIVATE);
                }
                SHELF_DROP_CATCHERS.with(|cell| {
                    if let Ok(mut map) = cell.try_borrow_mut() {
                        if let Some(entry) = map.get_mut(&shelf_hwnd_raw) {
                            entry.visible = true;
                            entry.last_rect = Some(rc);
                        }
                    }
                });
            }
            _ => {
                let hide_hwnd = SHELF_DROP_CATCHERS.with(|cell| {
                    cell.try_borrow_mut().ok().and_then(|mut map| {
                        let entry = map.get_mut(&shelf_hwnd_raw)?;
                        if entry.visible {
                            entry.visible = false;
                            entry.last_rect = None;
                            Some(entry.hwnd)
                        } else {
                            None
                        }
                    })
                });
                if let Some(hwnd) = hide_hwnd {
                    if unsafe { IsWindow(hwnd) }.as_bool() {
                        let _ = unsafe { ShowWindow(hwnd, SW_HIDE) };
                    }
                }
            }
        }
    }

    pub fn install(shelf_hwnd_raw: isize, callback: ShelfDropCallback) -> usize {
        if shelf_hwnd_raw == 0 {
            return 0;
        }
        if let Ok(mut map) = drop_callbacks().lock() {
            map.insert(shelf_hwnd_raw, callback);
        }
        let _ = ensure_catcher_exists(shelf_hwnd_raw);
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

        let cur_pid = unsafe { GetCurrentProcessId() };
        let cur_tid = unsafe { GetCurrentThreadId() };
        let root_hwnd = HWND(shelf_hwnd_raw as *mut _);
        if !unsafe { IsWindow(root_hwnd) }.as_bool()
            || !is_own_thread_hwnd(root_hwnd, cur_pid, cur_tid)
        {
            return 0;
        }

        // Collect the shelf root HWND plus descendants, then STRICTLY filter to HWNDs owned by
        // our own process & STA UI thread (`root_hwnd`, `WRY_WEBVIEW`, `Chrome_WidgetWin_0`).
        // NEVER call `RevokeDragDrop` / `RegisterDragDrop` on cross-process `msedgewebview2.exe`
        // HWNDs (`Chrome_RenderWidgetHostHWND` / `Intermediate D3D Window` / `Chrome_WidgetWin_1`):
        // Win32 OLE requires same-thread ownership, and cross-process revocation corrupts WebView2
        // input/COM state and causes crashes when opening the shelf. Because `wry` sets
        // `SetAllowExternalDrop(false)` on WebView2, OLE bubbles drops cleanly up to our
        // own-thread `Chrome_WidgetWin_0` / `root_hwnd` target.
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
            .filter(|&h| {
                unsafe { IsWindow(h) }.as_bool() && is_own_thread_hwnd(h, cur_pid, cur_tid)
            })
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

            let drop_target: IDropTarget = ShelfDropTarget::new(Arc::clone(&callback), 0).into();
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
        // Drain out of RefCell BEFORE calling `RevokeDragDrop` / `DestroyWindow` so re-entrant
        // WM_NCDESTROY / COM pumping can NEVER trigger a `BorrowMutError` panic across `extern "system"`.
        let drained_catcher = SHELF_DROP_CATCHERS.with(|cell| {
            cell.try_borrow_mut()
                .ok()
                .and_then(|mut map| map.remove(&shelf_hwnd_raw))
        });
        if let Some(catcher) = drained_catcher {
            if unsafe { IsWindow(catcher.hwnd) }.as_bool() {
                let _ = unsafe { RevokeDragDrop(catcher.hwnd) };
                let _ = unsafe { DestroyWindow(catcher.hwnd) };
            }
        }
        let drained = SHELF_DROP_TARGETS.with(|cell| {
            cell.try_borrow_mut()
                .ok()
                .and_then(|mut root_map| root_map.remove(&shelf_hwnd_raw))
        });
        if let Some(targets) = drained {
            let cur_pid = unsafe { GetCurrentProcessId() };
            let cur_tid = unsafe { GetCurrentThreadId() };
            for (h_raw, _entry) in targets {
                let h = HWND(h_raw as *mut _);
                if unsafe { IsWindow(h) }.as_bool() && is_own_thread_hwnd(h, cur_pid, cur_tid) {
                    let _ = unsafe { RevokeDragDrop(h) };
                }
            }
        }
    }

    #[cfg(test)]
    pub fn test_get_catcher(shelf_hwnd_raw: isize) -> Option<(HWND, IDropTarget)> {
        SHELF_DROP_CATCHERS.with(|cell| {
            cell.try_borrow().ok().and_then(|map| {
                map.get(&shelf_hwnd_raw)
                    .map(|entry| (entry.hwnd, entry._target.clone()))
            })
        })
    }
}

/// Shows or hides the pure own-thread Win32 `CharkleShelfDropCatcher` overlay above `shelf_hwnd_raw`.
/// MUST be called on the Win32 STA UI thread.
pub fn sync_shelf_drop_catcher(shelf_hwnd_raw: isize, screen_rect: Option<ClientRect>) {
    #[cfg(target_os = "windows")]
    {
        drop_target::sync_catcher(shelf_hwnd_raw, screen_rect);
    }
    #[cfg(not(target_os = "windows"))]
    {
        let _ = (shelf_hwnd_raw, screen_rect);
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

    #[cfg(target_os = "windows")]
    #[test]
    fn install_and_refresh_drop_target_on_real_own_thread_hwnd_is_idempotent() {
        use windows::core::w;
        use windows::Win32::Foundation::HWND;
        use windows::Win32::System::LibraryLoader::GetModuleHandleW;
        use windows::Win32::UI::WindowsAndMessaging::{
            CreateWindowExW, DestroyWindow, GetPropW, HWND_MESSAGE, WINDOW_EX_STYLE, WINDOW_STYLE,
        };

        let hinst = unsafe { GetModuleHandleW(None) }.unwrap_or_default();
        let hwnd = unsafe {
            CreateWindowExW(
                WINDOW_EX_STYLE(0),
                w!("STATIC"),
                w!("CharkleShelfDropTest"),
                WINDOW_STYLE(0),
                0,
                0,
                0,
                0,
                HWND_MESSAGE,
                None,
                hinst,
                None,
            )
        }
        .expect("create message window");
        let raw = hwnd.0 as isize;

        let installed = install_shelf_drop_target(raw, Arc::new(|_| {}));
        assert_eq!(
            installed, 1,
            "first install must register our own-thread HWND"
        );

        let prop_after =
            unsafe { GetPropW(HWND(raw as *mut _), w!("OleDropTargetInterface")) }.0 as usize;
        assert_ne!(
            prop_after, 0,
            "OLE RegisterDragDrop must set non-zero OleDropTargetInterface property"
        );

        // Second refresh must be a zero-churn no-op
        let second = refresh_shelf_drop_targets(raw);
        assert_eq!(second, 0, "idempotent refresh must not revoke/re-register");

        cleanup_shelf_drop_targets(raw);
        let prop_cleaned =
            unsafe { GetPropW(HWND(raw as *mut _), w!("OleDropTargetInterface")) }.0 as usize;
        assert_eq!(
            prop_cleaned, 0,
            "cleanup must cleanly revoke OleDropTargetInterface"
        );

        let _ = unsafe { DestroyWindow(hwnd) };
    }

    #[test]
    fn select_drop_effect_negotiates_copy_move_and_link() {
        // Explorer default COPY|MOVE|LINK -> COPY (1)
        assert_eq!(select_drop_effect(1 | 2 | 4), 1);
        // Move-only source -> MOVE (2)
        assert_eq!(select_drop_effect(2), 2);
        // Link-only source (e.g., browser URL) -> LINK (4)
        assert_eq!(select_drop_effect(4), 4);
        // Zero / unspecified -> COPY (1)
        assert_eq!(select_drop_effect(0), 1);
    }

    #[test]
    fn should_show_drop_catcher_gates_on_external_drag_and_proximity() {
        let rc = ClientRect {
            x: 600,
            y: 0,
            width: 668,
            height: 330,
        };
        // Internal shelf click/drag -> NEVER show catcher
        assert_eq!(
            should_show_drop_catcher(true, false, false, false, 800, 120, Some(rc)),
            None
        );
        // Outbound drag from shelf -> NEVER show catcher
        assert_eq!(
            should_show_drop_catcher(true, true, true, false, 800, 120, Some(rc)),
            None
        );
        // Collapsed shelf -> NEVER show catcher
        assert_eq!(
            should_show_drop_catcher(false, true, false, false, 800, 120, Some(rc)),
            None
        );
        // External drag far from shelf -> stay hidden
        assert_eq!(
            should_show_drop_catcher(true, true, false, false, 100, 900, Some(rc)),
            None
        );
        // External drag approaching shelf within 64px margin -> show catcher at exact capsule rect
        assert_eq!(
            should_show_drop_catcher(true, true, false, false, 800, 380, Some(rc)),
            Some(rc)
        );
        // Active drag hover -> stay shown
        assert_eq!(
            should_show_drop_catcher(true, true, false, true, 100, 900, Some(rc)),
            Some(rc)
        );
    }

    #[cfg(target_os = "windows")]
    #[test]
    fn drop_catcher_accepts_real_com_hdrop_files_and_folders_and_auto_hides() {
        use std::sync::Mutex;
        use windows::core::w;
        use windows::Win32::Foundation::{HWND, POINTL};
        use windows::Win32::System::LibraryLoader::GetModuleHandleW;
        use windows::Win32::System::Ole::{
            DROPEFFECT, DROPEFFECT_COPY, DROPEFFECT_LINK, DROPEFFECT_MOVE,
        };
        use windows::Win32::System::SystemServices::MODIFIERKEYS_FLAGS;
        use windows::Win32::UI::WindowsAndMessaging::{
            CreateWindowExW, DestroyWindow, IsWindowVisible, HWND_MESSAGE, WINDOW_EX_STYLE,
            WINDOW_STYLE,
        };

        let tmp = tempfile::tempdir().unwrap();
        let file_path = tmp.path().join("sample.png");
        let dir_path = tmp.path().join("SampleFolder");
        std::fs::write(&file_path, b"png").unwrap();
        std::fs::create_dir_all(&dir_path).unwrap();

        let hinst = unsafe { GetModuleHandleW(None) }.unwrap_or_default();
        let shelf_hwnd = unsafe {
            CreateWindowExW(
                WINDOW_EX_STYLE(0),
                w!("STATIC"),
                w!("CharkleShelfCatcherHostTest"),
                WINDOW_STYLE(0),
                0,
                0,
                0,
                0,
                HWND_MESSAGE,
                None,
                hinst,
                None,
            )
        }
        .expect("create host window");
        let raw = shelf_hwnd.0 as isize;

        let events: Arc<Mutex<Vec<ShelfDropEvent>>> = Arc::new(Mutex::new(Vec::new()));
        let events_cb = Arc::clone(&events);
        let _ = install_shelf_drop_target(
            raw,
            Arc::new(move |ev| {
                events_cb.lock().unwrap().push(ev);
            }),
        );

        let rect = ClientRect {
            x: 100,
            y: 100,
            width: 300,
            height: 200,
        };
        sync_shelf_drop_catcher(raw, Some(rect));

        // Build a real Shell IDataObject holding both a file and a folder path.
        let data_obj = crate::drag_out::build_hdrop_data_object_for_test(&[
            file_path.clone(),
            dir_path.clone(),
        ])
        .expect("build CF_HDROP IDataObject");

        // Retrieve the catcher HWND & IDropTarget registered on our thread and invoke COM DragEnter/Over/Drop.
        let (catcher_hwnd, drop_target) = drop_target::test_get_catcher(raw)
            .expect("catcher HWND and IDropTarget must exist after sync_shelf_drop_catcher");
        assert!(unsafe { IsWindowVisible(catcher_hwnd) }.as_bool());

        let mut effect = DROPEFFECT_COPY | DROPEFFECT_MOVE | DROPEFFECT_LINK;
        let pt = POINTL { x: 150, y: 150 };
        unsafe {
            drop_target
                .DragEnter(&data_obj, MODIFIERKEYS_FLAGS(0), pt, &mut effect)
                .expect("DragEnter");
        }
        assert_eq!(effect, DROPEFFECT_COPY);

        let mut over_effect = DROPEFFECT_COPY | DROPEFFECT_MOVE;
        unsafe {
            drop_target
                .DragOver(MODIFIERKEYS_FLAGS(0), pt, &mut over_effect)
                .expect("DragOver");
        }
        assert_eq!(over_effect, DROPEFFECT_COPY);

        let mut drop_effect = DROPEFFECT_COPY | DROPEFFECT_MOVE;
        unsafe {
            drop_target
                .Drop(&data_obj, MODIFIERKEYS_FLAGS(0), pt, &mut drop_effect)
                .expect("Drop");
        }
        assert_eq!(drop_effect, DROPEFFECT_COPY);
        assert!(
            !unsafe { IsWindowVisible(catcher_hwnd) }.as_bool(),
            "Drop Catcher must auto-hide synchronously on Drop so shelf stays immediately clickable"
        );

        let recorded = events.lock().unwrap().clone();
        assert!(
            matches!(recorded.first(), Some(ShelfDropEvent::Enter { count: 2 })),
            "Expected Enter(2), got: {recorded:?}"
        );
        assert!(
            matches!(
                recorded.last(),
                Some(ShelfDropEvent::Drop(ShelfDropPayload::Files(paths)))
                    if paths.len() == 2 && paths[0] == file_path && paths[1] == dir_path
            ),
            "Expected Drop(Files([file, folder])), got: {recorded:?}"
        );

        let _ = DROPEFFECT(0);
        cleanup_shelf_drop_targets(raw);
        let _ = unsafe { DestroyWindow(HWND(raw as *mut _)) };
    }

    #[test]
    fn predictive_top_approach_covers_three_tiers_and_suppresses_false_positives() {
        // 2560x1440 monitor at 150% DPI -> 1706.67 x 960 DIP
        let mon_px = MonitorRect {
            left: 0,
            top: 0,
            right: 2560,
            bottom: 1440,
        };
        let mon = ShelfRectDip::from_monitor_rect(mon_px, 1.5);
        let cx = mon.mid_x();

        // Tier 1: Direct top-center arrival band (<= 76 DIP, |dx| <= 176 DIP) triggers immediately
        assert!(ShelfDropGeometry::should_trigger_upward_drag_approach(
            (cx + 120.0, 64.0),
            mon,
            Some((cx + 120.0, 200.0)),
            &[],
            1.0,
        ));

        // Tier 1 false-positive suppression: dragging DOWN away from app titlebar/tab strip (<= -14 DIP)
        assert!(!ShelfDropGeometry::should_trigger_upward_drag_approach(
            (cx, 50.0),
            mon,
            Some((cx, 20.0)), // moved downward by 30 DIP -> total_upward_travel = -30
            &[
                ShelfDragMotionSample {
                    x: cx,
                    y: 20.0,
                    timestamp_secs: 0.90
                },
                ShelfDragMotionSample {
                    x: cx,
                    y: 50.0,
                    timestamp_secs: 1.00
                },
            ],
            1.0,
        ));

        // Tier 2: Low-altitude slow/steady upward drag (<= 136 DIP, |dx| <= 220 DIP, travel >= 24, vy >= 25)
        let slow_samples = [
            ShelfDragMotionSample {
                x: cx + 10.0,
                y: 150.0,
                timestamp_secs: 0.90,
            },
            ShelfDragMotionSample {
                x: cx + 12.0,
                y: 120.0,
                timestamp_secs: 1.00,
            }, // vy = 300 DIP/s, vx = 20
        ];
        assert!(ShelfDropGeometry::should_trigger_upward_drag_approach(
            (cx + 12.0, 120.0),
            mon,
            Some((cx, 170.0)), // upward travel = 50 DIP
            &slow_samples,
            1.0,
        ));

        // Tier 2 false-positive suppression: mostly horizontal swipe across top area (|vx| dominates)
        let horiz_samples = [
            ShelfDragMotionSample {
                x: cx - 100.0,
                y: 126.0,
                timestamp_secs: 0.90,
            },
            ShelfDragMotionSample {
                x: cx + 20.0,
                y: 120.0,
                timestamp_secs: 1.00,
            }, // vx = 1200, vy = 60 (< 0.5*|vx|)
        ];
        assert!(!ShelfDropGeometry::should_trigger_upward_drag_approach(
            (cx + 20.0, 120.0),
            mon,
            Some((cx - 100.0, 150.0)),
            &horiz_samples,
            1.0,
        ));

        // Tier 3: Fast upward 260ms ballistic corridor (depth ~307 DIP on 960 DIP height)
        let fast_samples = [
            ShelfDragMotionSample {
                x: cx - 40.0,
                y: 310.0,
                timestamp_secs: 0.92,
            },
            ShelfDragMotionSample {
                x: cx - 32.0,
                y: 230.0,
                timestamp_secs: 1.00,
            }, // vy = 1000 DIP/s -> projected dist = -30 <= 76
        ];
        assert!(ShelfDropGeometry::should_trigger_upward_drag_approach(
            (cx - 32.0, 230.0),
            mon,
            Some((cx - 40.0, 360.0)), // upward travel = 130 >= 36
            &fast_samples,
            1.0,
        ));

        // Tier 3 false-positive suppression: corner/sidebar drag outside horizontal corridor
        let corner_samples = [
            ShelfDragMotionSample {
                x: 80.0,
                y: 310.0,
                timestamp_secs: 0.92,
            },
            ShelfDragMotionSample {
                x: 80.0,
                y: 230.0,
                timestamp_secs: 1.00,
            },
        ];
        assert!(!ShelfDropGeometry::should_trigger_upward_drag_approach(
            (80.0, 230.0),
            mon,
            Some((80.0, 360.0)),
            &corner_samples,
            1.0,
        ));

        // Pause decay: stale samples (> 0.14s old) decay velocity to 0 so Tier 2/3 do NOT fire
        assert!(!ShelfDropGeometry::should_trigger_upward_drag_approach(
            (cx, 120.0),
            mon,
            Some((cx, 200.0)),
            &slow_samples,
            1.30, // 0.30s after latest sample -> velocity = 0
        ));
    }

    #[test]
    fn approach_grace_holds_briefly_and_cancels_on_downward_reversal() {
        let cap = ShelfRectDip {
            left: 600.0,
            top: 0.0,
            width: 668.0,
            height: 330.0,
        };
        assert!(ShelfDropGeometry::should_hold_early_expand_grace(
            (920.0, 355.0),
            Some(cap),
            40.0,
            0.20,
        ));
        // Cancels immediately on sharp downward reversal (< -80 DIP/s)
        assert!(!ShelfDropGeometry::should_hold_early_expand_grace(
            (920.0, 355.0),
            Some(cap),
            -120.0,
            0.15,
        ));
        // Expires cleanly after 0.45s
        assert!(!ShelfDropGeometry::should_hold_early_expand_grace(
            (920.0, 355.0),
            Some(cap),
            40.0,
            0.46,
        ));
    }

    #[test]
    fn system_task_view_and_fullscreen_yield_classifier_is_accurate() {
        let mon = MonitorRect {
            left: 0,
            top: 0,
            right: 2560,
            bottom: 1440,
        };
        let normal_rect = MonitorRect {
            left: 100,
            top: 100,
            right: 1400,
            bottom: 900,
        };

        assert!(is_system_task_view_class("XamlExplorerHostIslandWindow"));
        assert!(is_system_task_view_class("MultitaskingViewFrame"));
        assert!(is_system_task_view_class("xamlexplorerhostislandwindow"));
        assert!(!is_system_task_view_class("Chrome_WidgetWin_1"));

        // Task View yields immediately
        assert!(should_yield_for_foreground_window(
            "XamlExplorerHostIslandWindow",
            false,
            true,
            false,
            normal_rect,
            mon,
        ));
        // Borderless fullscreen external app covering entire monitor yields
        assert!(should_yield_for_foreground_window(
            "Chrome_WidgetWin_1",
            false,
            true,
            false,
            mon,
            mon,
        ));
        // Desktop wallpaper / taskbar shells NEVER trigger fullscreen yield
        assert!(!should_yield_for_foreground_window(
            "WorkerW", false, true, false, mon, mon,
        ));
        assert!(!should_yield_for_foreground_window(
            "Progman", false, true, false, mon, mon,
        ));
        // Our own process never blocks itself
        assert!(!should_yield_for_foreground_window(
            "Chrome_WidgetWin_1",
            true,
            true,
            false,
            mon,
            mon,
        ));
        // Ordinary restored window does not yield
        assert!(!should_yield_for_foreground_window(
            "Chrome_WidgetWin_1",
            false,
            true,
            false,
            normal_rect,
            mon,
        ));
    }
}
