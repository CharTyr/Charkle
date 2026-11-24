//! Multi-DPI virtual desktop screenshot capture (`capture.rs`).
//!
//! Enumerates monitors via `EnumDisplayMonitors` + `GetDpiForMonitor`, attempts DXGI
//! Desktop Duplication (`IDXGIOutput1::DuplicateOutput`) when available, and seamlessly
//! falls back to multi-DPI GDI `BitBlt(SRCCOPY | CAPTUREBLT)` with strict RAII cleanup.
//! Produces 1:1 physical-pixel RGBA & PNG frames for zero-copy streaming via `charkle-media://`.

#![allow(unsafe_code)]

use std::io::Cursor;

use image::{DynamicImage, ImageFormat, RgbaImage};
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MonitorCaptureInfo {
    pub index: usize,
    pub left: i32,
    pub top: i32,
    pub width: i32,
    pub height: i32,
    pub dpi_x: u32,
    pub dpi_y: u32,
    pub scale_factor: f64,
    pub is_primary: bool,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct VirtualDesktopBounds {
    pub left: i32,
    pub top: i32,
    pub width: u32,
    pub height: u32,
}

#[derive(Debug, Clone)]
pub struct CapturedDesktopFrame {
    pub bounds: VirtualDesktopBounds,
    pub monitors: Vec<MonitorCaptureInfo>,
    pub width: u32,
    pub height: u32,
    pub rgba: Vec<u8>,
    pub png_bytes: Vec<u8>,
}

#[cfg(target_os = "windows")]
struct PerMonitorV2DpiGuard(windows::Win32::UI::HiDpi::DPI_AWARENESS_CONTEXT);

#[cfg(target_os = "windows")]
impl PerMonitorV2DpiGuard {
    fn enter() -> Self {
        use windows::Win32::UI::HiDpi::{
            SetThreadDpiAwarenessContext, DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2,
        };
        // SAFETY: Restores previous thread DPI awareness context on Drop.
        let prev =
            unsafe { SetThreadDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2) };
        Self(prev)
    }
}

#[cfg(target_os = "windows")]
impl Drop for PerMonitorV2DpiGuard {
    fn drop(&mut self) {
        if !self.0.is_invalid() {
            use windows::Win32::UI::HiDpi::SetThreadDpiAwarenessContext;
            // SAFETY: Restores exact handle returned by `SetThreadDpiAwarenessContext`.
            unsafe {
                let _ = SetThreadDpiAwarenessContext(self.0);
            }
        }
    }
}

/// Enumerates all attached monitors and their per-monitor DPI scaling factors in physical pixels.
#[cfg(target_os = "windows")]
pub fn enumerate_monitors() -> Vec<MonitorCaptureInfo> {
    let _dpi_guard = PerMonitorV2DpiGuard::enter();
    use windows::Win32::Foundation::{BOOL, LPARAM, RECT};
    use windows::Win32::Graphics::Gdi::{
        EnumDisplayMonitors, GetMonitorInfoW, HDC, HMONITOR, MONITORINFO,
    };
    use windows::Win32::UI::HiDpi::{GetDpiForMonitor, MDT_EFFECTIVE_DPI};
    use windows::Win32::UI::WindowsAndMessaging::MONITORINFOF_PRIMARY;

    unsafe extern "system" fn enum_proc(
        hmon: HMONITOR,
        _hdc: HDC,
        _rc: *mut RECT,
        data: LPARAM,
    ) -> BOOL {
        let list = unsafe { &mut *(data.0 as *mut Vec<MonitorCaptureInfo>) };
        let mut info = MONITORINFO {
            cbSize: std::mem::size_of::<MONITORINFO>() as u32,
            ..Default::default()
        };
        if unsafe { GetMonitorInfoW(hmon, &mut info) }.as_bool() {
            let mut dpi_x: u32 = 96;
            let mut dpi_y: u32 = 96;
            let _ = unsafe { GetDpiForMonitor(hmon, MDT_EFFECTIVE_DPI, &mut dpi_x, &mut dpi_y) };
            let r = info.rcMonitor;
            list.push(MonitorCaptureInfo {
                index: list.len(),
                left: r.left,
                top: r.top,
                width: (r.right - r.left).max(1),
                height: (r.bottom - r.top).max(1),
                dpi_x,
                dpi_y,
                scale_factor: (dpi_x as f64 / 96.0).clamp(1.0, 4.0),
                is_primary: (info.dwFlags & MONITORINFOF_PRIMARY) != 0,
            });
        }
        BOOL(1)
    }

    let mut monitors: Vec<MonitorCaptureInfo> = Vec::new();
    // SAFETY: `monitors` lives on the stack for the duration of synchronous `EnumDisplayMonitors`.
    let _ = unsafe {
        EnumDisplayMonitors(
            HDC::default(),
            None,
            Some(enum_proc),
            LPARAM(&mut monitors as *mut Vec<MonitorCaptureInfo> as isize),
        )
    };
    monitors
}

#[cfg(not(target_os = "windows"))]
pub fn enumerate_monitors() -> Vec<MonitorCaptureInfo> {
    vec![MonitorCaptureInfo {
        index: 0,
        left: 0,
        top: 0,
        width: 1920,
        height: 1080,
        dpi_x: 96,
        dpi_y: 96,
        scale_factor: 1.0,
        is_primary: true,
    }]
}

pub fn compute_virtual_bounds(monitors: &[MonitorCaptureInfo]) -> VirtualDesktopBounds {
    if monitors.is_empty() {
        return VirtualDesktopBounds {
            left: 0,
            top: 0,
            width: 1920,
            height: 1080,
        };
    }
    let min_x = monitors.iter().map(|m| m.left).min().unwrap_or(0);
    let min_y = monitors.iter().map(|m| m.top).min().unwrap_or(0);
    let max_x = monitors
        .iter()
        .map(|m| m.left + m.width)
        .max()
        .unwrap_or(1920);
    let max_y = monitors
        .iter()
        .map(|m| m.top + m.height)
        .max()
        .unwrap_or(1080);

    VirtualDesktopBounds {
        left: min_x,
        top: min_y,
        width: (max_x - min_x).max(1) as u32,
        height: (max_y - min_y).max(1) as u32,
    }
}

/// Captures a frozen 1:1 physical-pixel snapshot of the entire multi-DPI virtual desktop.
/// Uses DXGI Desktop Duplication when available, falling back automatically to GDI `BitBlt`.
pub fn capture_virtual_desktop() -> Result<CapturedDesktopFrame, String> {
    #[cfg(target_os = "windows")]
    let _dpi_guard = PerMonitorV2DpiGuard::enter();

    let monitors = enumerate_monitors();
    let bounds = compute_virtual_bounds(&monitors);

    #[cfg(target_os = "windows")]
    let rgba = match try_capture_dxgi_primary(&bounds, &monitors) {
        Some(pixels) => pixels,
        None => capture_gdi_virtual_desktop(&bounds)?,
    };

    #[cfg(not(target_os = "windows"))]
    let rgba = vec![24u8; (bounds.width as usize) * (bounds.height as usize) * 4];

    if rgba.len() != (bounds.width as usize) * (bounds.height as usize) * 4 {
        return Err("Desktop capture produced invalid pixel buffer".to_string());
    }

    let png_bytes = encode_rgba_png(&rgba, bounds.width, bounds.height)?;
    Ok(CapturedDesktopFrame {
        bounds,
        monitors,
        width: bounds.width,
        height: bounds.height,
        rgba,
        png_bytes,
    })
}

#[cfg(target_os = "windows")]
const CAPTURE_SUBCLASS_ID: usize = 0x4348_4350; // "CHCP"

/// Configures a borderless fullscreen Region Capture overlay HWND in exact physical virtual-desktop
/// pixels across mixed-DPI monitors (bypassing Tauri's logical-pixel scaling).
#[cfg(target_os = "windows")]
pub fn configure_capture_window_physical(hwnd_raw: isize, bounds: VirtualDesktopBounds) {
    use std::ffi::c_void;
    use std::mem::size_of;
    use windows::Win32::Foundation::{BOOL, HWND, LPARAM, LRESULT, WPARAM};
    use windows::Win32::Graphics::Dwm::{
        DwmSetWindowAttribute, DWMWA_BORDER_COLOR, DWMWA_COLOR_NONE,
        DWMWA_TRANSITIONS_FORCEDISABLED, DWMWA_WINDOW_CORNER_PREFERENCE, DWMWCP_DONOTROUND,
    };
    use windows::Win32::UI::Shell::{DefSubclassProc, RemoveWindowSubclass, SetWindowSubclass};
    use windows::Win32::UI::WindowsAndMessaging::{
        GetWindowLongPtrW, SetWindowLongPtrW, SetWindowPos, GWL_EXSTYLE, GWL_STYLE, HWND_TOPMOST,
        SWP_FRAMECHANGED, SWP_SHOWWINDOW, WM_NCACTIVATE, WM_NCCALCSIZE, WM_NCDESTROY, WS_BORDER,
        WS_CAPTION, WS_CLIPCHILDREN, WS_CLIPSIBLINGS, WS_DLGFRAME, WS_EX_APPWINDOW,
        WS_EX_CLIENTEDGE, WS_EX_DLGMODALFRAME, WS_EX_TOOLWINDOW, WS_EX_TOPMOST, WS_EX_WINDOWEDGE,
        WS_MAXIMIZEBOX, WS_MINIMIZEBOX, WS_POPUP, WS_SYSMENU, WS_THICKFRAME,
    };

    unsafe extern "system" fn capture_subclass_proc(
        hwnd: HWND,
        msg: u32,
        wparam: WPARAM,
        lparam: LPARAM,
        uid_subclass: usize,
        _ref_data: usize,
    ) -> LRESULT {
        match msg {
            WM_NCCALCSIZE => return LRESULT(0),
            WM_NCACTIVATE => {
                // Keep overlay activation intact so Escape cancels immediately, while preventing
                // DefWindowProcW from painting any classic non-client caption/frame strip.
                return DefSubclassProc(
                    hwnd,
                    msg,
                    wparam,
                    LPARAM(crate::windowing::nc_activate_no_repaint_lparam()),
                );
            }
            m if crate::windowing::should_suppress_nc_paint_message(m) => {
                return LRESULT(0);
            }
            WM_NCDESTROY => {
                let _ = RemoveWindowSubclass(hwnd, Some(capture_subclass_proc), uid_subclass);
            }
            _ => {}
        }
        DefSubclassProc(hwnd, msg, wparam, lparam)
    }

    if hwnd_raw == 0 {
        return;
    }
    let _dpi_guard = PerMonitorV2DpiGuard::enter();
    let hwnd = HWND(hwnd_raw as *mut _);
    // SAFETY: Configures our owned capture overlay HWND in exact physical screen coordinates.
    unsafe {
        // Guard non-client painting BEFORE SWP_FRAMECHANGED / show so no titlebar can flash.
        let _ = SetWindowSubclass(hwnd, Some(capture_subclass_proc), CAPTURE_SUBCLASS_ID, 0);

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

        let cur_ex = GetWindowLongPtrW(hwnd, GWL_EXSTYLE);
        let strip_ex =
            (WS_EX_APPWINDOW.0 | WS_EX_WINDOWEDGE.0 | WS_EX_CLIENTEDGE.0 | WS_EX_DLGMODALFRAME.0)
                as isize;
        let desired_ex =
            (cur_ex & !strip_ex) | (WS_EX_TOPMOST.0 as isize) | (WS_EX_TOOLWINDOW.0 as isize);
        let _ = SetWindowLongPtrW(hwnd, GWL_EXSTYLE, desired_ex);

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

        let _ = SetWindowPos(
            hwnd,
            HWND_TOPMOST,
            bounds.left,
            bounds.top,
            bounds.width as i32,
            bounds.height as i32,
            SWP_FRAMECHANGED | SWP_SHOWWINDOW,
        );
    }
}

#[cfg(not(target_os = "windows"))]
pub fn configure_capture_window_physical(_hwnd_raw: isize, _bounds: VirtualDesktopBounds) {}

/// Crops an exact 1:1 physical-pixel region from a frozen [`CapturedDesktopFrame`] into PNG bytes.
pub fn crop_captured_frame(
    frame: &CapturedDesktopFrame,
    x: u32,
    y: u32,
    width: u32,
    height: u32,
) -> Result<Vec<u8>, String> {
    if width == 0 || height == 0 || frame.width == 0 || frame.height == 0 {
        return Err("Crop region cannot be empty".to_string());
    }
    let expected_len = (frame.width as usize)
        .checked_mul(frame.height as usize)
        .and_then(|px| px.checked_mul(4))
        .ok_or_else(|| "Capture frame dimensions overflow".to_string())?;
    if frame.rgba.len() < expected_len {
        return Err("Capture frame pixel buffer is truncated".to_string());
    }
    let sx = x.min(frame.width.saturating_sub(1));
    let sy = y.min(frame.height.saturating_sub(1));
    let cw = width.min(frame.width.saturating_sub(sx)).max(1);
    let ch = height.min(frame.height.saturating_sub(sy)).max(1);

    let mut out = vec![0u8; (cw as usize) * (ch as usize) * 4];
    let src_stride = (frame.width as usize) * 4;
    let dst_stride = (cw as usize) * 4;

    for row in 0..(ch as usize) {
        let src_off = ((sy as usize) + row) * src_stride + (sx as usize) * 4;
        let dst_off = row * dst_stride;
        out[dst_off..dst_off + dst_stride]
            .copy_from_slice(&frame.rgba[src_off..src_off + dst_stride]);
    }

    encode_rgba_png(&out, cw, ch)
}

fn encode_rgba_png(rgba: &[u8], width: u32, height: u32) -> Result<Vec<u8>, String> {
    let img = RgbaImage::from_raw(width, height, rgba.to_vec())
        .ok_or_else(|| "Invalid RGBA buffer dimensions".to_string())?;
    let mut png = Vec::new();
    DynamicImage::ImageRgba8(img)
        .write_to(&mut Cursor::new(&mut png), ImageFormat::Png)
        .map_err(|e| format!("Failed to encode capture PNG: {e}"))?;
    Ok(png)
}

/// Returns `true` only for 8-bit BGRA desktop surfaces (`DXGI_FORMAT_B8G8R8A8_UNORM = 87` and
/// `DXGI_FORMAT_B8G8R8A8_UNORM_SRGB = 91`). HDR outputs (`R16G16B16A16_FLOAT = 10`,
/// `R10G10B10A2_UNORM = 24`) return `false` so capture falls back to DWM tone-mapped GDI `BitBlt`.
pub fn is_supported_dxgi_bgra8_format(dxgi_format: u32) -> bool {
    matches!(dxgi_format, 87 | 91)
}

/// Attempts fast GPU DXGI Desktop Duplication on single-monitor setups; falls back to
/// multi-monitor GDI `BitBlt` automatically on multi-GPU / HDR / RDP / timeout environments.
#[cfg(target_os = "windows")]
fn try_capture_dxgi_primary(
    bounds: &VirtualDesktopBounds,
    monitors: &[MonitorCaptureInfo],
) -> Option<Vec<u8>> {
    // Only use fast single-output DXGI path when 1 monitor matches bounds; multi-monitor
    // compositing uses unified virtual-screen GDI BitBlt to keep exact mixed-DPI alignment.
    if monitors.len() != 1 {
        return None;
    }

    use windows::core::Interface;
    use windows::Win32::Graphics::Direct3D::{D3D_DRIVER_TYPE_UNKNOWN, D3D_FEATURE_LEVEL_11_0};
    use windows::Win32::Graphics::Direct3D11::{
        D3D11CreateDevice, ID3D11Device, ID3D11DeviceContext, ID3D11Texture2D,
        D3D11_CPU_ACCESS_READ, D3D11_CREATE_DEVICE_BGRA_SUPPORT, D3D11_MAPPED_SUBRESOURCE,
        D3D11_MAP_READ, D3D11_SDK_VERSION, D3D11_TEXTURE2D_DESC, D3D11_USAGE_STAGING,
    };
    use windows::Win32::Graphics::Dxgi::{
        CreateDXGIFactory1, IDXGIFactory1, IDXGIOutput1, DXGI_OUTDUPL_FRAME_INFO,
    };

    // SAFETY: Standard DXGI Desktop Duplication sequence; all COM interfaces are RAII-dropped.
    unsafe {
        let factory: IDXGIFactory1 = CreateDXGIFactory1().ok()?;
        let adapter = factory.EnumAdapters1(0).ok()?;
        let output = adapter.EnumOutputs(0).ok()?;
        let output1: IDXGIOutput1 = output.cast().ok()?;

        let mut device: Option<ID3D11Device> = None;
        let mut context: Option<ID3D11DeviceContext> = None;
        let feature_levels = [D3D_FEATURE_LEVEL_11_0];
        D3D11CreateDevice(
            &adapter,
            D3D_DRIVER_TYPE_UNKNOWN,
            None,
            D3D11_CREATE_DEVICE_BGRA_SUPPORT,
            Some(&feature_levels),
            D3D11_SDK_VERSION,
            Some(&mut device),
            None,
            Some(&mut context),
        )
        .ok()?;
        let device = device?;
        let context = context?;

        let duplication = output1.DuplicateOutput(&device).ok()?;
        let mut frame_info = DXGI_OUTDUPL_FRAME_INFO::default();
        let mut resource = None;
        // Acquire frame with short timeout; retry once if first DXGI frame has LastPresentTime == 0
        // (black/empty initial frame before DWM presents), otherwise fall back cleanly to GDI BitBlt.
        let mut acquired = false;
        for attempt in 0..2 {
            let timeout = if attempt == 0 { 120 } else { 80 };
            if duplication
                .AcquireNextFrame(timeout, &mut frame_info, &mut resource)
                .is_err()
            {
                return None;
            }
            if frame_info.LastPresentTime != 0 && resource.is_some() {
                acquired = true;
                break;
            }
            resource = None;
            let _ = duplication.ReleaseFrame();
        }
        if !acquired {
            return None;
        }
        let resource = match resource {
            Some(r) => r,
            None => {
                let _ = duplication.ReleaseFrame();
                return None;
            }
        };

        let tex: ID3D11Texture2D = match resource.cast() {
            Ok(t) => t,
            Err(_) => {
                let _ = duplication.ReleaseFrame();
                return None;
            }
        };
        let mut desc = D3D11_TEXTURE2D_DESC::default();
        tex.GetDesc(&mut desc);
        if desc.Width != bounds.width
            || desc.Height != bounds.height
            || !is_supported_dxgi_bgra8_format(desc.Format.0 as u32)
        {
            let _ = duplication.ReleaseFrame();
            return None;
        }

        let staging_desc = D3D11_TEXTURE2D_DESC {
            Width: desc.Width,
            Height: desc.Height,
            MipLevels: 1,
            ArraySize: 1,
            Format: desc.Format,
            SampleDesc: desc.SampleDesc,
            Usage: D3D11_USAGE_STAGING,
            BindFlags: 0,
            CPUAccessFlags: D3D11_CPU_ACCESS_READ.0 as u32,
            MiscFlags: 0,
        };
        let mut staging: Option<ID3D11Texture2D> = None;
        if device
            .CreateTexture2D(&staging_desc, None, Some(&mut staging))
            .is_err()
        {
            let _ = duplication.ReleaseFrame();
            return None;
        }
        let Some(staging) = staging else {
            let _ = duplication.ReleaseFrame();
            return None;
        };
        context.CopyResource(&staging, &tex);
        let _ = duplication.ReleaseFrame();

        let mut mapped = D3D11_MAPPED_SUBRESOURCE::default();
        context
            .Map(&staging, 0, D3D11_MAP_READ, 0, Some(&mut mapped))
            .ok()?;

        let w = bounds.width as usize;
        let h = bounds.height as usize;
        let pitch = mapped.RowPitch as usize;
        let src_ptr = mapped.pData as *const u8;
        let row_bytes = w.checked_mul(4);
        if src_ptr.is_null() || row_bytes.is_none_or(|rb| pitch < rb) {
            context.Unmap(&staging, 0);
            return None;
        }
        let mut rgba = vec![0u8; w * h * 4];
        for row in 0..h {
            let src_row = std::slice::from_raw_parts(src_ptr.add(row * pitch), w * 4);
            let dst_row = &mut rgba[row * w * 4..(row + 1) * w * 4];
            for (s, d) in src_row.chunks_exact(4).zip(dst_row.chunks_exact_mut(4)) {
                d[0] = s[2];
                d[1] = s[1];
                d[2] = s[0];
                d[3] = 255;
            }
        }
        context.Unmap(&staging, 0);
        Some(rgba)
    }
}

#[cfg(target_os = "windows")]
fn capture_gdi_virtual_desktop(bounds: &VirtualDesktopBounds) -> Result<Vec<u8>, String> {
    use windows::core::PCWSTR;
    use windows::Win32::Foundation::HWND;
    use windows::Win32::Graphics::Gdi::{
        BitBlt, CreateCompatibleBitmap, CreateCompatibleDC, CreateDCW, DeleteDC, DeleteObject,
        GetDC, GetDIBits, ReleaseDC, SelectObject, BITMAPINFO, BITMAPINFOHEADER, BI_RGB,
        CAPTUREBLT, DIB_RGB_COLORS, HBITMAP, HDC, HGDIOBJ, SRCCOPY,
    };

    enum SourceDC {
        Display(HDC),
        Screen(HDC),
    }
    impl SourceDC {
        fn raw(&self) -> HDC {
            match self {
                SourceDC::Display(hdc) | SourceDC::Screen(hdc) => *hdc,
            }
        }
    }
    impl Drop for SourceDC {
        fn drop(&mut self) {
            match self {
                SourceDC::Display(hdc) if !hdc.is_invalid() => unsafe {
                    let _ = DeleteDC(*hdc);
                },
                SourceDC::Screen(hdc) if !hdc.is_invalid() => unsafe {
                    let _ = ReleaseDC(HWND::default(), *hdc);
                },
                _ => {}
            }
        }
    }

    struct MemDC(HDC);
    impl Drop for MemDC {
        fn drop(&mut self) {
            if !self.0.is_invalid() {
                unsafe {
                    let _ = DeleteDC(self.0);
                }
            }
        }
    }

    struct OwnedBmp(HBITMAP);
    impl Drop for OwnedBmp {
        fn drop(&mut self) {
            if !self.0.is_invalid() {
                unsafe {
                    let _ = DeleteObject(HGDIOBJ(self.0 .0));
                }
            }
        }
    }

    // SAFETY: All GDI objects are immediately wrapped in RAII Drop guards.
    unsafe {
        let display_name: Vec<u16> = "DISPLAY\0".encode_utf16().collect();
        let display_dc = CreateDCW(
            PCWSTR(display_name.as_ptr()),
            PCWSTR::null(),
            PCWSTR::null(),
            None,
        );
        let screen_dc = if !display_dc.is_invalid() {
            SourceDC::Display(display_dc)
        } else {
            let fallback = GetDC(HWND::default());
            if fallback.is_invalid() {
                return Err("CreateDCW(DISPLAY) and GetDC(screen) both failed".to_string());
            }
            SourceDC::Screen(fallback)
        };

        let mem_dc = MemDC(CreateCompatibleDC(screen_dc.raw()));
        if mem_dc.0.is_invalid() {
            return Err("CreateCompatibleDC failed".to_string());
        }
        let bmp = OwnedBmp(CreateCompatibleBitmap(
            screen_dc.raw(),
            bounds.width as i32,
            bounds.height as i32,
        ));
        if bmp.0.is_invalid() {
            return Err("CreateCompatibleBitmap failed".to_string());
        }

        let prev = SelectObject(mem_dc.0, HGDIOBJ(bmp.0 .0));
        let blt_res = BitBlt(
            mem_dc.0,
            0,
            0,
            bounds.width as i32,
            bounds.height as i32,
            screen_dc.raw(),
            bounds.left,
            bounds.top,
            SRCCOPY | CAPTUREBLT,
        )
        .or_else(|_| {
            BitBlt(
                mem_dc.0,
                0,
                0,
                bounds.width as i32,
                bounds.height as i32,
                screen_dc.raw(),
                bounds.left,
                bounds.top,
                SRCCOPY,
            )
        });
        let _ = SelectObject(mem_dc.0, prev);
        blt_res.map_err(|e| format!("BitBlt failed: {e}"))?;

        let mut bmi = BITMAPINFO {
            bmiHeader: BITMAPINFOHEADER {
                biSize: std::mem::size_of::<BITMAPINFOHEADER>() as u32,
                biWidth: bounds.width as i32,
                biHeight: -(bounds.height as i32), // Top-down
                biPlanes: 1,
                biBitCount: 32,
                biCompression: BI_RGB.0,
                ..Default::default()
            },
            ..Default::default()
        };

        let mut rgba = vec![0u8; (bounds.width as usize) * (bounds.height as usize) * 4];
        let lines = GetDIBits(
            mem_dc.0,
            bmp.0,
            0,
            bounds.height,
            Some(rgba.as_mut_ptr().cast()),
            &mut bmi,
            DIB_RGB_COLORS,
        );
        if lines == 0 {
            return Err("GetDIBits failed during desktop capture".to_string());
        }

        for px in rgba.chunks_exact_mut(4) {
            px.swap(0, 2);
            px[3] = 255;
        }
        Ok(rgba)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn computes_mixed_dpi_virtual_bounds_and_crops_exact_physical_pixels() {
        let mixed_monitors = vec![
            MonitorCaptureInfo {
                index: 0,
                left: 0,
                top: 0,
                width: 1920,
                height: 1080,
                dpi_x: 96,
                dpi_y: 96,
                scale_factor: 1.0,
                is_primary: true,
            },
            MonitorCaptureInfo {
                index: 1,
                left: 1920,
                top: -180,
                width: 2560,
                height: 1440,
                dpi_x: 144,
                dpi_y: 144,
                scale_factor: 1.5,
                is_primary: false,
            },
        ];
        let bounds = compute_virtual_bounds(&mixed_monitors);
        assert_eq!(bounds.left, 0);
        assert_eq!(bounds.top, -180);
        assert_eq!(bounds.width, 4480);
        assert_eq!(bounds.height, 1440);

        // Deterministic 1:1 physical crop verification
        let w = 160u32;
        let h = 120u32;
        let mut rgba = vec![0u8; (w * h * 4) as usize];
        for y in 0..h {
            for x in 0..w {
                let off = ((y * w + x) * 4) as usize;
                rgba[off] = (x & 0xFF) as u8;
                rgba[off + 1] = (y & 0xFF) as u8;
                rgba[off + 2] = 200;
                rgba[off + 3] = 255;
            }
        }
        let synthetic = CapturedDesktopFrame {
            bounds: VirtualDesktopBounds {
                left: 0,
                top: 0,
                width: w,
                height: h,
            },
            monitors: mixed_monitors,
            width: w,
            height: h,
            rgba,
            png_bytes: Vec::new(),
        };
        let cropped = crop_captured_frame(&synthetic, 40, 30, 64, 48).expect("crop");
        let decoded = image::load_from_memory(&cropped)
            .expect("decode")
            .to_rgba8();
        assert_eq!((decoded.width(), decoded.height()), (64, 48));
        assert_eq!(decoded.get_pixel(0, 0).0, [40, 30, 200, 255]);
        assert_eq!(decoded.get_pixel(10, 5).0, [50, 35, 200, 255]);
    }

    #[test]
    fn enumerates_host_monitors_and_probes_live_desktop_capture() {
        let monitors = enumerate_monitors();
        assert!(!monitors.is_empty());
        let bounds = compute_virtual_bounds(&monitors);
        assert!(bounds.width > 0 && bounds.height > 0);

        match capture_virtual_desktop() {
            Ok(frame) => {
                assert!(frame.png_bytes.starts_with(b"\x89PNG"));
                let crop =
                    crop_captured_frame(&frame, 0, 0, 64.min(frame.width), 48.min(frame.height))
                        .expect("crop live");
                assert!(crop.starts_with(b"\x89PNG"));
            }
            Err(err) => {
                // Non-interactive / locked Windows desktops deny BitBlt with E_HANDLE (0x80070006)
                assert!(
                    err.contains("0x80070006") || err.contains("BitBlt"),
                    "Unexpected desktop capture failure: {err}"
                );
            }
        }
    }

    #[test]
    fn dxgi_bgra8_format_guard_rejects_hdr_surfaces() {
        assert!(is_supported_dxgi_bgra8_format(87)); // DXGI_FORMAT_B8G8R8A8_UNORM
        assert!(is_supported_dxgi_bgra8_format(91)); // DXGI_FORMAT_B8G8R8A8_UNORM_SRGB
        assert!(!is_supported_dxgi_bgra8_format(10)); // DXGI_FORMAT_R16G16B16A16_FLOAT (HDR)
        assert!(!is_supported_dxgi_bgra8_format(24)); // DXGI_FORMAT_R10G10B10A2_UNORM (10-bit HDR)
        assert!(!is_supported_dxgi_bgra8_format(0)); // DXGI_FORMAT_UNKNOWN
    }
}
