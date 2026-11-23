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

/// Pure policy function deciding whether Mica backdrop should activate.
pub fn resolve_backdrop_kind(build_number: u32, transparency_enabled: bool) -> BackdropKind {
    if build_number >= WIN11_22H2_BUILD && transparency_enabled {
        BackdropKind::Mica
    } else {
        BackdropKind::SolidFallback
    }
}

fn max_button_rects() -> &'static Mutex<HashMap<isize, ClientRect>> {
    static MAP: OnceLock<Mutex<HashMap<isize, ClientRect>>> = OnceLock::new();
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
        DwmExtendFrameIntoClientArea, DwmSetWindowAttribute, DWMSBT_MAINWINDOW, DWMSBT_NONE,
        DWMWA_SYSTEMBACKDROP_TYPE, DWMWA_USE_IMMERSIVE_DARK_MODE, DWMWA_WINDOW_CORNER_PREFERENCE,
        DWMWCP_ROUND,
    };
    use windows::Win32::Graphics::Gdi::ScreenToClient;
    use windows::Win32::System::LibraryLoader::{GetModuleHandleW, GetProcAddress};
    use windows::Win32::System::Registry::{RegGetValueW, HKEY_CURRENT_USER, RRF_RT_REG_DWORD};
    use windows::Win32::UI::Controls::MARGINS;
    use windows::Win32::UI::Shell::{DefSubclassProc, RemoveWindowSubclass, SetWindowSubclass};
    use windows::Win32::UI::WindowsAndMessaging::{
        IsZoomed, ShowWindow, SystemParametersInfoW, HTMAXBUTTON, SPI_GETCLIENTAREAANIMATION,
        SW_MAXIMIZE, SW_RESTORE, SYSTEM_PARAMETERS_INFO_UPDATE_FLAGS, WM_NCDESTROY, WM_NCHITTEST,
        WM_NCLBUTTONDOWN, WM_NCLBUTTONUP,
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
            let hwnd = HWND(hwnd_raw as *mut c_void);
            unsafe {
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

                    let margins = MARGINS {
                        cxLeftWidth: -1,
                        cxRightWidth: -1,
                        cyTopHeight: -1,
                        cyBottomHeight: -1,
                    };
                    let _ = DwmExtendFrameIntoClientArea(hwnd, &margins);

                    let backdrop_type = if backdrop == BackdropKind::Mica {
                        DWMSBT_MAINWINDOW
                    } else {
                        DWMSBT_NONE
                    };
                    if DwmSetWindowAttribute(
                        hwnd,
                        DWMWA_SYSTEMBACKDROP_TYPE,
                        std::ptr::from_ref(&backdrop_type).cast::<c_void>(),
                        size_of::<i32>() as u32,
                    )
                    .is_err()
                    {
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
            WM_NCDESTROY => {
                update_maximize_button_rect(hwnd_key, None);
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
    fn backdrop_policy_enables_mica_only_on_win11_22h2_with_transparency() {
        assert_eq!(resolve_backdrop_kind(22621, true), BackdropKind::Mica);
        assert_eq!(resolve_backdrop_kind(26100, true), BackdropKind::Mica);
        assert_eq!(
            resolve_backdrop_kind(22621, false),
            BackdropKind::SolidFallback
        );
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
