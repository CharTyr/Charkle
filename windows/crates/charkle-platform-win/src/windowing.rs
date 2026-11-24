//! Windows 11/10 native window chrome:
//! - True Windows build detection via `ntdll!RtlGetVersion`
//! - Windows 11 22H2+ (build >= 22621) Mica backdrop (`DWMWA_SYSTEMBACKDROP_TYPE`),
//!   rounded corners, immersive dark mode sync, and Win10 / reduced-transparency solid fallback
//! - Custom frameless titlebar Windows 11 Snap Layouts via `SetWindowSubclass` + `WM_NCHITTEST` (`HTMAXBUTTON`)

use std::collections::HashMap;
use std::sync::{Mutex, OnceLock};

use serde::{Deserialize, Serialize};

/// Minimum Windows 11 22H2 build supporting `DWMWA_SYSTEMBACKDROP_TYPE = DWMSBT_MAINWINDOW` (Mica).
pub const WIN11_22H2_BUILD: u32 = 22621;
/// Minimum Windows 10 2004 build supporting modern `DWMWA_USE_IMMERSIVE_DARK_MODE` attribute `20`.
pub const WIN10_DARK_MODE_BUILD: u32 = 19041;
/// Win32 `WS_SYSMENU` style bit (`0x0008_0000`).
const WS_SYSMENU_BIT: u32 = 0x0008_0000;
/// Win32 `WM_NCPAINT` message constant (`0x0085`).
pub const WM_NCPAINT_MSG: u32 = 0x0085;
/// Undocumented `uxtheme.dll` message sent to paint the classic themed window caption bar.
pub const WM_NCUAHDRAWCAPTION: u32 = 0x00AE;
/// Undocumented `uxtheme.dll` message sent to paint the classic themed window frame.
pub const WM_NCUAHDRAWFRAME: u32 = 0x00AF;
/// `WM_NCACTIVATE` `lParam` value (`-1`) telling `DefWindowProcW` to update active state
/// without repainting any non-client caption bar or title text.
pub const WM_NCACTIVATE_NO_REPAINT_LPARAM: isize = -1;

/// Strips `WS_SYSMENU` (`0x0008_0000`) from a Win32 `GWL_STYLE` bitmask while preserving
/// `WS_CAPTION`, `WS_THICKFRAME`, `WS_MINIMIZEBOX`, `WS_MAXIMIZEBOX`, `WS_CLIPSIBLINGS`,
/// and all other style bits.
///
/// Without `WS_SYSMENU`, Windows 11 `uDWM.dll` does not synthesize native Minimize / Maximize /
/// Restore / Close button visuals onto the transparent Mica Alt backdrop (preventing native
/// `— ❐ ×` glyphs from bleeding through behind our custom titlebar buttons when maximized),
/// while keeping rounded corners, DWM shadow, Aero Snap, maximized work-area sizing, and
/// `HTMAXBUTTON` Snap Layouts intact.
pub fn strip_native_caption_menu_style(style: u32) -> u32 {
    style & !WS_SYSMENU_BIT
}

/// Returns `true` for Win32 non-client paint messages (`WM_NCPAINT`, `WM_NCUAHDRAWCAPTION`,
/// `WM_NCUAHDRAWFRAME`) that must return `LRESULT(0)` so Windows / `uxtheme.dll` never paints
/// classic blue titlebar chrome behind our custom frameless Mica titlebar.
pub const fn should_suppress_nc_paint_message(msg: u32) -> bool {
    matches!(
        msg,
        WM_NCPAINT_MSG | WM_NCUAHDRAWCAPTION | WM_NCUAHDRAWFRAME
    )
}

/// Returns the `lParam` (`-1`) forwarded on `WM_NCACTIVATE` so the windowing layer keeps exact
/// active/focus state tracking while `DefWindowProcW` skips all non-client caption redraws.
pub const fn nc_activate_no_repaint_lparam() -> isize {
    WM_NCACTIVATE_NO_REPAINT_LPARAM
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct WindowsVersion {
    pub major: u32,
    pub minor: u32,
    pub build: u32,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum BackdropKind {
    Mica,
    SolidFallback,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct WindowSurfaceState {
    pub build_number: u32,
    pub backdrop: BackdropKind,
    pub is_dark: bool,
    pub transparency_enabled: bool,
    pub animations_enabled: bool,
    pub snap_layouts_supported: bool,
}

/// Client-area pixel rectangle (physical pixels relative to HWND client top-left).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ClientRect {
    pub x: i32,
    pub y: i32,
    pub width: i32,
    pub height: i32,
}

impl ClientRect {
    pub fn contains(self, px: i32, py: i32) -> bool {
        self.width > 0
            && self.height > 0
            && px >= self.x
            && px < self.x.saturating_add(self.width)
            && py >= self.y
            && py < self.y.saturating_add(self.height)
    }
}

/// Pure policy function deciding whether Windows 11 Mica backdrop should be registered on DWM.
///
/// On Windows 11 22H2+ (`build >= 22621`), we always register `DWMWA_SYSTEMBACKDROP_TYPE`
/// (`DWMSBT_TABBEDWINDOW` / Mica Alt) regardless of the current `EnableTransparency` toggle:
/// Windows DWM itself manages system transparency dynamically (rendering live wallpaper-tinted
/// Mica Alt whenever Transparency Effects is on, clean Win11 solid system tint when off, and
/// transitioning live without an app restart). `WindowSurfaceState::transparency_enabled` still
/// reports the live OS toggle so Settings can offer a quick jump to Windows Colors settings.
pub fn resolve_backdrop_kind(build_number: u32, _transparency_enabled: bool) -> BackdropKind {
    if build_number >= WIN11_22H2_BUILD {
        BackdropKind::Mica
    } else {
        BackdropKind::SolidFallback
    }
}

fn max_button_rects() -> &'static Mutex<HashMap<isize, ClientRect>> {
    static MAP: OnceLock<Mutex<HashMap<isize, ClientRect>>> = OnceLock::new();
    MAP.get_or_init(|| Mutex::new(HashMap::new()))
}

#[cfg(target_os = "windows")]
fn window_dark_modes() -> &'static Mutex<HashMap<isize, bool>> {
    static MAP: OnceLock<Mutex<HashMap<isize, bool>>> = OnceLock::new();
    MAP.get_or_init(|| Mutex::new(HashMap::new()))
}

/// Updates the tracked physical client rect of the custom titlebar's Maximize button
/// so Win32 `WM_NCHITTEST` returns `HTMAXBUTTON` for native Windows 11 Snap Layouts.
pub fn update_maximize_button_rect(hwnd: isize, rect: Option<ClientRect>) {
    if let Ok(mut guard) = max_button_rects().lock() {
        match rect {
            Some(r) if r.width > 0 && r.height > 0 => {
                guard.insert(hwnd, r);
            }
            _ => {
                guard.remove(&hwnd);
            }
        }
    }
}

#[cfg(target_os = "windows")]
#[allow(unsafe_code)]
mod win32_impl {
    use super::*;
    use std::ffi::c_void;
    use std::mem::size_of;

    use windows::core::w;
    use windows::Win32::Foundation::{BOOL, HWND, LPARAM, LRESULT, POINT, WPARAM};
    use windows::Win32::Graphics::Dwm::{
        DwmExtendFrameIntoClientArea, DwmSetWindowAttribute, DWMSBT_MAINWINDOW,
        DWMSBT_TABBEDWINDOW, DWMWA_SYSTEMBACKDROP_TYPE, DWMWA_USE_IMMERSIVE_DARK_MODE,
        DWMWA_WINDOW_CORNER_PREFERENCE, DWMWCP_ROUND,
    };
    use windows::Win32::Graphics::Gdi::ScreenToClient;
    use windows::Win32::System::LibraryLoader::{GetModuleHandleW, GetProcAddress};
    use windows::Win32::System::Registry::{RegGetValueW, HKEY_CURRENT_USER, RRF_RT_REG_DWORD};
    use windows::Win32::UI::Controls::MARGINS;
    use windows::Win32::UI::Input::KeyboardAndMouse::VK_F4;
    use windows::Win32::UI::Shell::{DefSubclassProc, RemoveWindowSubclass, SetWindowSubclass};
    use windows::Win32::UI::WindowsAndMessaging::{
        GetWindowLongW, IsZoomed, PostMessageW, SetWindowLongW, SetWindowPos, ShowWindow,
        SystemParametersInfoW, GWL_STYLE, HTMAXBUTTON, SC_CLOSE, SPI_GETCLIENTAREAANIMATION,
        STYLESTRUCT, SWP_FRAMECHANGED, SWP_NOACTIVATE, SWP_NOMOVE, SWP_NOSIZE, SWP_NOZORDER,
        SW_MAXIMIZE, SW_RESTORE, SYSTEM_PARAMETERS_INFO_UPDATE_FLAGS, WM_CLOSE, WM_NCACTIVATE,
        WM_NCDESTROY, WM_NCHITTEST, WM_NCLBUTTONDOWN, WM_NCLBUTTONUP, WM_SETICON, WM_SETTEXT,
        WM_SETTINGCHANGE, WM_STYLECHANGING, WM_SYSCOMMAND, WM_SYSKEYDOWN, WM_THEMECHANGED,
        WS_VISIBLE,
    };

    const SNAP_SUBCLASS_ID: usize = 0x4348_4B31; // "CHK1"

    #[repr(C)]
    struct RtlOsVersionInfoW {
        dw_os_version_info_size: u32,
        dw_major_version: u32,
        dw_minor_version: u32,
        dw_build_number: u32,
        dw_platform_id: u32,
        sz_csd_version: [u16; 128],
    }

    pub fn query_windows_version() -> WindowsVersion {
        unsafe {
            let Ok(ntdll) = GetModuleHandleW(w!("ntdll.dll")) else {
                return WindowsVersion {
                    major: 10,
                    minor: 0,
                    build: 0,
                };
            };
            let Some(proc_addr) = GetProcAddress(ntdll, windows::core::s!("RtlGetVersion")) else {
                return WindowsVersion {
                    major: 10,
                    minor: 0,
                    build: 0,
                };
            };
            let rtl_get_version: extern "system" fn(*mut RtlOsVersionInfoW) -> i32 =
                std::mem::transmute(proc_addr);
            let mut info = RtlOsVersionInfoW {
                dw_os_version_info_size: size_of::<RtlOsVersionInfoW>() as u32,
                dw_major_version: 0,
                dw_minor_version: 0,
                dw_build_number: 0,
                dw_platform_id: 0,
                sz_csd_version: [0; 128],
            };
            if rtl_get_version(&mut info) == 0 {
                WindowsVersion {
                    major: info.dw_major_version,
                    minor: info.dw_minor_version,
                    build: info.dw_build_number,
                }
            } else {
                WindowsVersion {
                    major: 10,
                    minor: 0,
                    build: 0,
                }
            }
        }
    }

    pub fn is_transparency_enabled() -> bool {
        unsafe {
            let mut value: u32 = 1;
            let mut size = size_of::<u32>() as u32;
            let status = RegGetValueW(
                HKEY_CURRENT_USER,
                w!("Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize"),
                w!("EnableTransparency"),
                RRF_RT_REG_DWORD,
                None,
                Some((&mut value as *mut u32).cast::<c_void>()),
                Some(&mut size),
            );
            if status.is_ok() {
                value != 0
            } else {
                true
            }
        }
    }

    pub fn are_animations_enabled() -> bool {
        unsafe {
            let mut enabled = BOOL::from(true);
            let ok = SystemParametersInfoW(
                SPI_GETCLIENTAREAANIMATION,
                0,
                Some((&mut enabled as *mut BOOL).cast::<c_void>()),
                SYSTEM_PARAMETERS_INFO_UPDATE_FLAGS(0),
            );
            if ok.is_ok() {
                enabled.as_bool()
            } else {
                true
            }
        }
    }

    pub fn apply_window_chrome(hwnd_raw: isize, is_dark: bool) -> WindowSurfaceState {
        let ver = query_windows_version();
        let transparency_enabled = is_transparency_enabled();
        let animations_enabled = are_animations_enabled();
        let mut backdrop = resolve_backdrop_kind(ver.build, transparency_enabled);

        if hwnd_raw != 0 {
            if let Ok(mut modes) = window_dark_modes().lock() {
                modes.insert(hwnd_raw, is_dark);
            }
            let hwnd = HWND(hwnd_raw as *mut c_void);
            unsafe {
                // Strip WS_SYSMENU once (idempotent) so Windows 11 uDWM.dll never synthesizes
                // native Minimize/Maximize/Close glyphs behind our custom titlebar buttons on
                // the transparent Mica Alt surface (especially when maximized).
                let cur_style = GetWindowLongW(hwnd, GWL_STYLE) as u32;
                let next_style = strip_native_caption_menu_style(cur_style);
                if next_style != cur_style {
                    let _ = SetWindowLongW(hwnd, GWL_STYLE, next_style as i32);
                    let _ = SetWindowPos(
                        hwnd,
                        None,
                        0,
                        0,
                        0,
                        0,
                        SWP_FRAMECHANGED | SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE,
                    );
                }

                if ver.build >= WIN10_DARK_MODE_BUILD {
                    let dark_flag = BOOL::from(is_dark);
                    let _ = DwmSetWindowAttribute(
                        hwnd,
                        DWMWA_USE_IMMERSIVE_DARK_MODE,
                        (&dark_flag as *const BOOL).cast::<c_void>(),
                        size_of::<BOOL>() as u32,
                    );
                }

                if ver.build >= WIN11_22H2_BUILD {
                    let corner = DWMWCP_ROUND;
                    let _ = DwmSetWindowAttribute(
                        hwnd,
                        DWMWA_WINDOW_CORNER_PREFERENCE,
                        std::ptr::from_ref(&corner).cast::<c_void>(),
                        size_of::<u32>() as u32,
                    );

                    // Extend the DWM glass frame across the entire client area so transparent
                    // WebView2 regions (`Color(0,0,0,0)`) composite directly over live Mica Alt.
                    let margins = MARGINS {
                        cxLeftWidth: -1,
                        cxRightWidth: -1,
                        cyTopHeight: -1,
                        cyBottomHeight: -1,
                    };
                    let _ = DwmExtendFrameIntoClientArea(hwnd, &margins);

                    // Register Mica Alt (`DWMSBT_TABBEDWINDOW`) on Win11 22H2+ regardless of the
                    // current `EnableTransparency` toggle so Windows DWM manages live wallpaper
                    // tint dynamically without restarting; fall back to `DWMSBT_MAINWINDOW` if
                    // an older build rejects `DWMSBT_TABBEDWINDOW`.
                    let tabbed = DWMSBT_TABBEDWINDOW;
                    let applied = DwmSetWindowAttribute(
                        hwnd,
                        DWMWA_SYSTEMBACKDROP_TYPE,
                        std::ptr::from_ref(&tabbed).cast::<c_void>(),
                        size_of::<i32>() as u32,
                    )
                    .is_ok()
                        || {
                            let main_mica = DWMSBT_MAINWINDOW;
                            DwmSetWindowAttribute(
                                hwnd,
                                DWMWA_SYSTEMBACKDROP_TYPE,
                                std::ptr::from_ref(&main_mica).cast::<c_void>(),
                                size_of::<i32>() as u32,
                            )
                            .is_ok()
                        };
                    if !applied {
                        backdrop = BackdropKind::SolidFallback;
                    }
                }
            }
        }

        WindowSurfaceState {
            build_number: ver.build,
            backdrop,
            is_dark,
            transparency_enabled,
            animations_enabled,
            snap_layouts_supported: ver.build >= 22000,
        }
    }

    pub fn install_snap_layout_subclass(hwnd_raw: isize) -> bool {
        if hwnd_raw == 0 {
            return false;
        }
        let hwnd = HWND(hwnd_raw as *mut c_void);
        unsafe { SetWindowSubclass(hwnd, Some(snap_subclass_proc), SNAP_SUBCLASS_ID, 0).as_bool() }
    }

    unsafe extern "system" fn snap_subclass_proc(
        hwnd: HWND,
        msg: u32,
        wparam: WPARAM,
        lparam: LPARAM,
        uid_subclass: usize,
        _ref_data: usize,
    ) -> LRESULT {
        let hwnd_key = hwnd.0 as isize;
        match msg {
            WM_STYLECHANGING if wparam.0 as i32 == GWL_STYLE.0 => {
                // Prevent the windowing layer from re-adding WS_SYSMENU on maximize/restore
                // or window state diffs.
                let ss = lparam.0 as *mut STYLESTRUCT;
                if !ss.is_null() {
                    (*ss).styleNew = strip_native_caption_menu_style((*ss).styleNew);
                }
            }
            WM_NCACTIVATE => {
                // Forward lParam = -1 so the windowing layer preserves exact active/focus state
                // (inspecting wParam) while DefWindowProcW skips all non-client caption redraws
                // (preventing the classic blue "Charkle" titlebar from bleeding through on focus
                // transitions).
                return DefSubclassProc(hwnd, msg, wparam, LPARAM(nc_activate_no_repaint_lparam()));
            }
            m if should_suppress_nc_paint_message(m) => {
                // Suppress legacy GDI WM_NCPAINT and uxtheme WM_NCUAHDRAWCAPTION (0x00AE) /
                // WM_NCUAHDRAWFRAME (0x00AF) painting over the frameless Mica Alt surface.
                return LRESULT(0);
            }
            WM_SETTEXT | WM_SETICON => {
                // Suppress DefWindowProcW's non-client caption redraw on title/icon updates while
                // visible (temporarily strip WS_VISIBLE without SWP_FRAMECHANGED, forward to
                // DefSubclassProc, then restore WS_VISIBLE).
                let style = GetWindowLongW(hwnd, GWL_STYLE) as u32;
                if (style & WS_VISIBLE.0) != 0 {
                    let _ = SetWindowLongW(hwnd, GWL_STYLE, (style & !WS_VISIBLE.0) as i32);
                    let res = DefSubclassProc(hwnd, msg, wparam, lparam);
                    let after = GetWindowLongW(hwnd, GWL_STYLE) as u32;
                    let _ = SetWindowLongW(hwnd, GWL_STYLE, (after | WS_VISIBLE.0) as i32);
                    return res;
                }
            }
            WM_SYSKEYDOWN if wparam.0 == usize::from(VK_F4.0) && (lparam.0 & (1 << 29)) != 0 => {
                // Keep Alt+F4 working cleanly without WS_SYSMENU; WM_CLOSE routes through
                // Tauri's CloseRequested handler (including Minimal Background Shelf Mode).
                let _ = PostMessageW(hwnd, WM_CLOSE, WPARAM(0), LPARAM(0));
                return LRESULT(0);
            }
            WM_SYSCOMMAND if (wparam.0 & 0xFFF0) == SC_CLOSE as usize => {
                // Keep Taskbar Close working cleanly without WS_SYSMENU.
                let _ = PostMessageW(hwnd, WM_CLOSE, WPARAM(0), LPARAM(0));
                return LRESULT(0);
            }
            WM_NCHITTEST => {
                let maybe_rect = max_button_rects()
                    .lock()
                    .ok()
                    .and_then(|map| map.get(&hwnd_key).copied());
                if let Some(rect) = maybe_rect {
                    // Extract signed 16-bit screen coordinates (supports multi-monitor negative X/Y)
                    let x = (lparam.0 as i32 & 0xFFFF) as i16 as i32;
                    let y = ((lparam.0 as i32 >> 16) & 0xFFFF) as i16 as i32;
                    let mut pt = POINT { x, y };
                    if ScreenToClient(hwnd, &mut pt).as_bool() && rect.contains(pt.x, pt.y) {
                        return LRESULT(HTMAXBUTTON as isize);
                    }
                }
            }
            WM_NCLBUTTONDOWN if wparam.0 == HTMAXBUTTON as usize => {
                // Consume down event so Windows doesn't trigger legacy non-client drag/flicker
                return LRESULT(0);
            }
            WM_NCLBUTTONUP if wparam.0 == HTMAXBUTTON as usize => {
                let cmd = if IsZoomed(hwnd).as_bool() {
                    SW_RESTORE
                } else {
                    SW_MAXIMIZE
                };
                let _ = ShowWindow(hwnd, cmd);
                return LRESULT(0);
            }
            WM_SETTINGCHANGE | WM_THEMECHANGED => {
                // Re-sync DWM Mica Alt + immersive dark mode whenever the user toggles Windows
                // Transparency Effects or updates desktop wallpaper/theme live.
                let is_dark = window_dark_modes()
                    .lock()
                    .ok()
                    .and_then(|map| map.get(&hwnd_key).copied())
                    .unwrap_or(false);
                let _ = apply_window_chrome(hwnd_key, is_dark);
            }
            WM_NCDESTROY => {
                update_maximize_button_rect(hwnd_key, None);
                if let Ok(mut modes) = window_dark_modes().lock() {
                    modes.remove(&hwnd_key);
                }
                let _ = RemoveWindowSubclass(hwnd, Some(snap_subclass_proc), uid_subclass);
            }
            _ => {}
        }
        DefSubclassProc(hwnd, msg, wparam, lparam)
    }
}

#[cfg(not(target_os = "windows"))]
mod win32_impl {
    use super::*;

    pub fn query_windows_version() -> WindowsVersion {
        WindowsVersion {
            major: 0,
            minor: 0,
            build: 0,
        }
    }

    pub fn is_transparency_enabled() -> bool {
        true
    }

    pub fn are_animations_enabled() -> bool {
        true
    }

    pub fn apply_window_chrome(_hwnd_raw: isize, is_dark: bool) -> WindowSurfaceState {
        WindowSurfaceState {
            build_number: 0,
            backdrop: BackdropKind::SolidFallback,
            is_dark,
            transparency_enabled: true,
            animations_enabled: true,
            snap_layouts_supported: false,
        }
    }

    pub fn install_snap_layout_subclass(_hwnd_raw: isize) -> bool {
        false
    }
}

pub use win32_impl::{
    apply_window_chrome, are_animations_enabled, install_snap_layout_subclass,
    is_transparency_enabled, query_windows_version,
};

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn backdrop_policy_enables_mica_on_win11_22h2_regardless_of_transparency_toggle() {
        assert_eq!(resolve_backdrop_kind(22621, true), BackdropKind::Mica);
        assert_eq!(resolve_backdrop_kind(22621, false), BackdropKind::Mica);
        assert_eq!(resolve_backdrop_kind(26100, true), BackdropKind::Mica);
        assert_eq!(resolve_backdrop_kind(26200, false), BackdropKind::Mica);
        assert_eq!(
            resolve_backdrop_kind(19045, true),
            BackdropKind::SolidFallback
        );
        assert_eq!(
            resolve_backdrop_kind(22000, true),
            BackdropKind::SolidFallback
        );
    }

    #[test]
    fn client_rect_hit_test_respects_boundaries() {
        let rect = ClientRect {
            x: 1180,
            y: 0,
            width: 46,
            height: 36,
        };
        assert!(rect.contains(1180, 0));
        assert!(rect.contains(1225, 35));
        assert!(!rect.contains(1179, 10));
        assert!(!rect.contains(1226, 10));
        assert!(!rect.contains(1200, 36));
    }

    #[test]
    fn strip_native_caption_menu_style_clears_ws_sysmenu_only() {
        const WS_CAPTION_BIT: u32 = 0x00C0_0000;
        const WS_THICKFRAME_BIT: u32 = 0x0004_0000;
        const WS_MINIMIZEBOX_BIT: u32 = 0x0002_0000;
        const WS_MAXIMIZEBOX_BIT: u32 = 0x0001_0000;
        const WS_CLIPSIBLINGS_BIT: u32 = 0x0400_0000;
        const WS_VISIBLE_BIT: u32 = 0x1000_0000;
        const WS_MAXIMIZE_BIT: u32 = 0x0100_0000;

        let kept = WS_CAPTION_BIT
            | WS_THICKFRAME_BIT
            | WS_MINIMIZEBOX_BIT
            | WS_MAXIMIZEBOX_BIT
            | WS_CLIPSIBLINGS_BIT
            | WS_VISIBLE_BIT
            | WS_MAXIMIZE_BIT;
        let with_sysmenu = kept | WS_SYSMENU_BIT;

        let stripped = strip_native_caption_menu_style(with_sysmenu);
        assert_eq!(stripped & WS_SYSMENU_BIT, 0, "WS_SYSMENU must be cleared");
        assert_eq!(
            stripped, kept,
            "all other window chrome/snap/sizing bits must be preserved"
        );
        // Idempotent on already-stripped styles and zero.
        assert_eq!(strip_native_caption_menu_style(stripped), stripped);
        assert_eq!(strip_native_caption_menu_style(0), 0);

        #[cfg(target_os = "windows")]
        {
            use windows::Win32::UI::WindowsAndMessaging::{
                WS_CAPTION, WS_CLIPSIBLINGS, WS_MAXIMIZE, WS_MAXIMIZEBOX, WS_MINIMIZEBOX,
                WS_SYSMENU, WS_THICKFRAME, WS_VISIBLE,
            };
            assert_eq!(WS_SYSMENU_BIT, WS_SYSMENU.0);
            let native_style = WS_CAPTION.0
                | WS_THICKFRAME.0
                | WS_MINIMIZEBOX.0
                | WS_MAXIMIZEBOX.0
                | WS_CLIPSIBLINGS.0
                | WS_VISIBLE.0
                | WS_MAXIMIZE.0
                | WS_SYSMENU.0;
            assert_eq!(
                strip_native_caption_menu_style(native_style),
                native_style & !WS_SYSMENU.0
            );
        }
    }

    #[test]
    fn nc_paint_suppression_and_nc_activate_no_repaint_contract() {
        assert_eq!(WM_NCPAINT_MSG, 0x0085);
        assert_eq!(WM_NCUAHDRAWCAPTION, 0x00AE);
        assert_eq!(WM_NCUAHDRAWFRAME, 0x00AF);
        assert_eq!(nc_activate_no_repaint_lparam(), -1);

        assert!(should_suppress_nc_paint_message(WM_NCPAINT_MSG));
        assert!(should_suppress_nc_paint_message(WM_NCUAHDRAWCAPTION));
        assert!(should_suppress_nc_paint_message(WM_NCUAHDRAWFRAME));

        // Ordinary client/hit-test/activation messages must NOT be classified as NC-paint
        assert!(!should_suppress_nc_paint_message(0x000F)); // WM_PAINT
        assert!(!should_suppress_nc_paint_message(0x0084)); // WM_NCHITTEST
        assert!(!should_suppress_nc_paint_message(0x0086)); // WM_NCACTIVATE

        #[cfg(target_os = "windows")]
        {
            use windows::Win32::UI::WindowsAndMessaging::{WM_NCACTIVATE, WM_NCPAINT};
            assert_eq!(WM_NCPAINT_MSG, WM_NCPAINT);
            assert!(should_suppress_nc_paint_message(WM_NCPAINT));
            assert!(!should_suppress_nc_paint_message(WM_NCACTIVATE));
        }
    }

    #[test]
    fn windows_version_probe_returns_valid_host_build() {
        let ver = query_windows_version();
        #[cfg(target_os = "windows")]
        assert!(
            ver.build >= 10240,
            "expected real Windows build, got {ver:?}"
        );
        #[cfg(not(target_os = "windows"))]
        assert_eq!(ver.build, 0);
    }
}
