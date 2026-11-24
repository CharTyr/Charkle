//! Windows Clipboard collector & live `AddClipboardFormatListener` watcher (`clipboard.rs`).
//!
//! Detects images (`CF_DIB`), file drops (`CF_HDROP`), URLs (including X/Threads/Bluesky/GitHub),
//! `#RRGGBB` color hexes, and text snippets without polling.

#![allow(unsafe_code)]

use std::io::Cursor;
use std::path::PathBuf;
use std::sync::atomic::{AtomicIsize, Ordering};
use std::sync::Arc;

use charkle_core::media::resolvers::{GitHubRepoURLParser, SocialPostURLParser, WebURLParser};
use image::{DynamicImage, ImageFormat, RgbaImage};
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum ClipboardSnapshot {
    ImagePng {
        png_bytes: Vec<u8>,
        width: u32,
        height: u32,
    },
    FilePaths {
        paths: Vec<PathBuf>,
    },
    Url {
        url: String,
    },
    ColorHex {
        hex: String,
    },
    Text {
        text: String,
    },
}

/// Summary DTO safe to send over IPC to Shelf / Main UI without transferring large image bytes.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ClipboardPreview {
    pub kind: String,
    pub label: String,
    pub url: Option<String>,
    pub hex: Option<String>,
    pub file_count: usize,
    pub is_social_or_github_url: bool,
}

impl ClipboardSnapshot {
    pub fn to_preview(&self) -> ClipboardPreview {
        match self {
            ClipboardSnapshot::ImagePng { width, height, .. } => ClipboardPreview {
                kind: "image".to_string(),
                label: format!("剪贴板图片 ({width} × {height})"),
                url: None,
                hex: None,
                file_count: 0,
                is_social_or_github_url: false,
            },
            ClipboardSnapshot::FilePaths { paths } => ClipboardPreview {
                kind: "files".to_string(),
                label: if paths.len() == 1 {
                    paths[0]
                        .file_name()
                        .map(|n| n.to_string_lossy().into_owned())
                        .unwrap_or_else(|| "1 个文件".to_string())
                } else {
                    format!("{} 个剪贴板文件", paths.len())
                },
                url: None,
                hex: None,
                file_count: paths.len(),
                is_social_or_github_url: false,
            },
            ClipboardSnapshot::Url { url } => {
                let is_rich = is_directly_parsable_rich_url(url);
                ClipboardPreview {
                    kind: "url".to_string(),
                    label: url.clone(),
                    url: Some(url.clone()),
                    hex: None,
                    file_count: 0,
                    is_social_or_github_url: is_rich,
                }
            }
            ClipboardSnapshot::ColorHex { hex } => ClipboardPreview {
                kind: "color".to_string(),
                label: format!("色卡 {hex}"),
                url: None,
                hex: Some(hex.clone()),
                file_count: 0,
                is_social_or_github_url: false,
            },
            ClipboardSnapshot::Text { text } => {
                let single_line: String =
                    text.lines().next().unwrap_or("").chars().take(48).collect();
                ClipboardPreview {
                    kind: "text".to_string(),
                    label: if single_line.is_empty() {
                        "剪贴板文本".to_string()
                    } else {
                        single_line
                    },
                    url: None,
                    hex: None,
                    file_count: 0,
                    is_social_or_github_url: false,
                }
            }
        }
    }
}

fn is_directly_parsable_rich_url(candidate: &str) -> bool {
    SocialPostURLParser::extract_post_url(candidate).is_some()
        || GitHubRepoURLParser::extract_repo_url(candidate).is_some()
}

fn extract_embedded_rich_url(raw: &str) -> Option<String> {
    SocialPostURLParser::extract_post_url(raw)
        .or_else(|| GitHubRepoURLParser::extract_repo_url(raw))
        .map(|u| u.to_string())
}

/// Classifies plain clipboard text into a URL, `#RRGGBB` color swatch, or text snippet.
pub fn classify_clipboard_text(raw: &str) -> Option<ClipboardSnapshot> {
    let trimmed = raw.trim();
    if trimmed.is_empty() {
        return None;
    }

    // Color hex (`#RRGGBB`)
    let hex_candidate = trimmed.strip_prefix('#').unwrap_or(trimmed);
    if trimmed.starts_with('#')
        && hex_candidate.len() == 6
        && hex_candidate.chars().all(|c| c.is_ascii_hexdigit())
    {
        return Some(ClipboardSnapshot::ColorHex {
            hex: format!("#{}", hex_candidate.to_ascii_uppercase()),
        });
    }

    // Single-line or short share-copy web URL parsed via canonical `WebURLParser`
    // (accepts case-insensitive http(s), standalone `www.`, balanced parens, and <= 320 chars / <= 5 lines
    // share text while rejecting long prose, bare filenames, and local `localhost` dev URLs).
    if let Some(url) = WebURLParser::extract_web_url(trimmed, true) {
        let host = url.host_str().unwrap_or("");
        if host.contains('.') && !host.eq_ignore_ascii_case("localhost") {
            return Some(ClipboardSnapshot::Url {
                url: url.to_string(),
            });
        }
    }

    // Embedded X/Threads/Bluesky/GitHub URL inside a share snippet (parity with macOS ClipboardCollector)
    if let Some(url) = extract_embedded_rich_url(trimmed) {
        return Some(ClipboardSnapshot::Url { url });
    }

    Some(ClipboardSnapshot::Text {
        text: trimmed.to_string(),
    })
}

/// Converts a Windows `CF_DIB` (`BITMAPINFOHEADER` + BGR/BGRA pixel payload) into PNG bytes.
pub fn dib_bytes_to_png(dib: &[u8]) -> Result<(Vec<u8>, u32, u32), String> {
    if dib.len() < 40 {
        return Err("CF_DIB buffer smaller than BITMAPINFOHEADER".to_string());
    }
    let header_size = u32::from_le_bytes([dib[0], dib[1], dib[2], dib[3]]) as usize;
    let width_i = i32::from_le_bytes([dib[4], dib[5], dib[6], dib[7]]);
    let height_i = i32::from_le_bytes([dib[8], dib[9], dib[10], dib[11]]);
    let bit_count = u16::from_le_bytes([dib[14], dib[15]]);
    let compression = u32::from_le_bytes([dib[16], dib[17], dib[18], dib[19]]);
    let clr_used = u32::from_le_bytes([dib[32], dib[33], dib[34], dib[35]]) as usize;

    if header_size < 40 || width_i <= 0 || height_i == 0 {
        return Err("Invalid DIB dimensions".to_string());
    }
    let width = width_i as u32;
    let height = height_i.unsigned_abs();
    if width > 16_384 || height > 16_384 {
        return Err("DIB dimensions exceed safe maximum".to_string());
    }
    let top_down = height_i < 0;

    // BI_RGB (0) or BI_BITFIELDS (3)
    let extra_masks = if compression == 3 && header_size == 40 {
        12usize
    } else {
        0usize
    };
    let palette_bytes = if bit_count <= 8 {
        let entries = if clr_used > 0 {
            clr_used
        } else {
            1usize.checked_shl(bit_count as u32).unwrap_or(0)
        };
        entries
            .checked_mul(4)
            .ok_or_else(|| "DIB palette overflow".to_string())?
    } else {
        clr_used
            .checked_mul(4)
            .ok_or_else(|| "DIB palette overflow".to_string())?
    };
    let pixel_offset = header_size
        .checked_add(extra_masks)
        .and_then(|v| v.checked_add(palette_bytes))
        .ok_or_else(|| "CF_DIB pixel offset overflow".to_string())?;
    if pixel_offset >= dib.len() {
        return Err("CF_DIB pixel offset out of range".to_string());
    }
    let pixels = &dib[pixel_offset..];

    let rgba_len = (width as usize)
        .checked_mul(height as usize)
        .and_then(|px| px.checked_mul(4))
        .ok_or_else(|| "DIB pixel buffer overflow".to_string())?;
    let mut rgba = vec![0u8; rgba_len];
    match bit_count {
        32 => {
            let row_stride = (width as usize) * 4;
            if pixels.len() < row_stride * (height as usize) {
                return Err("Truncated 32-bit DIB payload".to_string());
            }
            let mut any_alpha = false;
            for y in 0..(height as usize) {
                let src_y = if top_down {
                    y
                } else {
                    (height as usize) - 1 - y
                };
                let src_row = &pixels[src_y * row_stride..(src_y + 1) * row_stride];
                let dst_row = &mut rgba[y * row_stride..(y + 1) * row_stride];
                for (s, d) in src_row.chunks_exact(4).zip(dst_row.chunks_exact_mut(4)) {
                    d[0] = s[2];
                    d[1] = s[1];
                    d[2] = s[0];
                    d[3] = s[3];
                    if s[3] != 0 {
                        any_alpha = true;
                    }
                }
            }
            if !any_alpha {
                for px in rgba.chunks_exact_mut(4) {
                    px[3] = 255;
                }
            }
        }
        24 => {
            let row_stride = ((width as usize) * 3 + 3) & !3;
            if pixels.len() < row_stride * (height as usize) {
                return Err("Truncated 24-bit DIB payload".to_string());
            }
            for y in 0..(height as usize) {
                let src_y = if top_down {
                    y
                } else {
                    (height as usize) - 1 - y
                };
                let src_row =
                    &pixels[src_y * row_stride..src_y * row_stride + (width as usize) * 3];
                let dst_row = &mut rgba[y * (width as usize) * 4..(y + 1) * (width as usize) * 4];
                for (s, d) in src_row.chunks_exact(3).zip(dst_row.chunks_exact_mut(4)) {
                    d[0] = s[2];
                    d[1] = s[1];
                    d[2] = s[0];
                    d[3] = 255;
                }
            }
        }
        other => return Err(format!("Unsupported DIB bit depth: {other}")),
    }

    let img = RgbaImage::from_raw(width, height, rgba)
        .ok_or_else(|| "Failed to assemble RGBA image from DIB".to_string())?;
    let mut png = Vec::new();
    DynamicImage::ImageRgba8(img)
        .write_to(&mut Cursor::new(&mut png), ImageFormat::Png)
        .map_err(|e| format!("Failed to encode clipboard PNG: {e}"))?;
    Ok((png, width, height))
}

/// Reads the current Windows clipboard snapshot (`CF_HDROP` -> `"PNG"` -> `CF_DIB` -> `CF_UNICODETEXT`).
#[cfg(target_os = "windows")]
pub fn read_current_clipboard() -> Result<Option<ClipboardSnapshot>, String> {
    use windows::core::w;
    use windows::Win32::Foundation::{HGLOBAL, HWND};
    use windows::Win32::System::DataExchange::{
        CloseClipboard, GetClipboardData, IsClipboardFormatAvailable, OpenClipboard,
        RegisterClipboardFormatW,
    };
    use windows::Win32::System::Memory::{GlobalLock, GlobalSize, GlobalUnlock};
    use windows::Win32::System::Ole::{CF_DIB, CF_HDROP, CF_UNICODETEXT};
    use windows::Win32::UI::Shell::{DragQueryFileW, HDROP};

    struct ClipboardGuard;
    impl Drop for ClipboardGuard {
        fn drop(&mut self) {
            unsafe {
                let _ = CloseClipboard();
            }
        }
    }

    struct GlobalLockGuard(HGLOBAL);
    impl Drop for GlobalLockGuard {
        fn drop(&mut self) {
            unsafe {
                let _ = GlobalUnlock(self.0);
            }
        }
    }

    // SAFETY: Standard Win32 clipboard lock guarded by RAII `ClipboardGuard`.
    unsafe {
        if OpenClipboard(HWND::default()).is_err() {
            return Ok(None);
        }
        let _clip_guard = ClipboardGuard;

        // 1. File drop list (CF_HDROP)
        if IsClipboardFormatAvailable(CF_HDROP.0 as u32).is_ok() {
            if let Ok(handle) = GetClipboardData(CF_HDROP.0 as u32) {
                let hdrop = HDROP(handle.0);
                let count = DragQueryFileW(hdrop, 0xFFFF_FFFF, None);
                let mut paths = Vec::with_capacity(count as usize);
                for idx in 0..count {
                    let needed = DragQueryFileW(hdrop, idx, None);
                    if needed > 0 {
                        let mut buf = vec![0u16; (needed as usize) + 1];
                        let written = DragQueryFileW(hdrop, idx, Some(&mut buf));
                        if written > 0 {
                            paths.push(PathBuf::from(String::from_utf16_lossy(
                                &buf[..written as usize],
                            )));
                        }
                    }
                }
                if !paths.is_empty() {
                    return Ok(Some(ClipboardSnapshot::FilePaths { paths }));
                }
            }
        }

        // 2. Registered "PNG" clipboard format (preserves transparency from Figma / Chrome / Electron)
        let png_fmt = RegisterClipboardFormatW(w!("PNG"));
        if png_fmt != 0 && IsClipboardFormatAvailable(png_fmt).is_ok() {
            if let Ok(handle) = GetClipboardData(png_fmt) {
                let hglobal = HGLOBAL(handle.0);
                let size = GlobalSize(hglobal);
                if (24..=64 * 1024 * 1024).contains(&size) {
                    let ptr = GlobalLock(hglobal);
                    if !ptr.is_null() {
                        let _lock = GlobalLockGuard(hglobal);
                        let slice = std::slice::from_raw_parts(ptr as *const u8, size);
                        if slice.starts_with(b"\x89PNG\r\n\x1a\n") {
                            if let Ok(reader) =
                                image::ImageReader::new(Cursor::new(slice)).with_guessed_format()
                            {
                                if let Ok((width, height)) = reader.into_dimensions() {
                                    if width > 0
                                        && height > 0
                                        && width <= 16_384
                                        && height <= 16_384
                                    {
                                        return Ok(Some(ClipboardSnapshot::ImagePng {
                                            png_bytes: slice.to_vec(),
                                            width,
                                            height,
                                        }));
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }

        // 3. Bitmap image (CF_DIB)
        if IsClipboardFormatAvailable(CF_DIB.0 as u32).is_ok() {
            if let Ok(handle) = GetClipboardData(CF_DIB.0 as u32) {
                let hglobal = HGLOBAL(handle.0);
                let size = GlobalSize(hglobal);
                if (40..=128 * 1024 * 1024).contains(&size) {
                    let ptr = GlobalLock(hglobal);
                    if !ptr.is_null() {
                        let _lock = GlobalLockGuard(hglobal);
                        let slice = std::slice::from_raw_parts(ptr as *const u8, size);
                        if let Ok((png_bytes, width, height)) = dib_bytes_to_png(slice) {
                            return Ok(Some(ClipboardSnapshot::ImagePng {
                                png_bytes,
                                width,
                                height,
                            }));
                        }
                    }
                }
            }
        }

        // 4. Unicode text / URL / Hex color (CF_UNICODETEXT)
        const MAX_CLIPBOARD_UTF16_BYTES: usize = 4 * 1024 * 1024;
        if IsClipboardFormatAvailable(CF_UNICODETEXT.0 as u32).is_ok() {
            if let Ok(handle) = GetClipboardData(CF_UNICODETEXT.0 as u32) {
                let hglobal = HGLOBAL(handle.0);
                let size = GlobalSize(hglobal);
                if size >= 2 {
                    let bounded_bytes = size.min(MAX_CLIPBOARD_UTF16_BYTES);
                    let ptr = GlobalLock(hglobal);
                    if !ptr.is_null() {
                        let _lock = GlobalLockGuard(hglobal);
                        let units =
                            std::slice::from_raw_parts(ptr as *const u16, bounded_bytes / 2);
                        let len = units.iter().position(|&c| c == 0).unwrap_or(units.len());
                        let text = String::from_utf16_lossy(&units[..len]);
                        return Ok(classify_clipboard_text(&text));
                    }
                }
            }
        }

        Ok(None)
    }
}

#[cfg(not(target_os = "windows"))]
pub fn read_current_clipboard() -> Result<Option<ClipboardSnapshot>, String> {
    Ok(None)
}

/// Converts PNG bytes into a Windows `CF_DIB` buffer (40-byte `BITMAPINFOHEADER` + bottom-up 32-bit BGRA).
pub fn png_bytes_to_dib(png_bytes: &[u8]) -> Result<Vec<u8>, String> {
    let rgba = image::load_from_memory(png_bytes)
        .map_err(|e| format!("Failed to decode PNG for clipboard: {e}"))?
        .to_rgba8();
    let w = rgba.width();
    let h = rgba.height();
    let mut dib = Vec::with_capacity(40 + (w as usize) * (h as usize) * 4);
    dib.extend_from_slice(&40u32.to_le_bytes()); // biSize
    dib.extend_from_slice(&(w as i32).to_le_bytes()); // biWidth
    dib.extend_from_slice(&(h as i32).to_le_bytes()); // biHeight (positive = bottom-up for max compatibility)
    dib.extend_from_slice(&1u16.to_le_bytes()); // biPlanes
    dib.extend_from_slice(&32u16.to_le_bytes()); // biBitCount
    dib.extend_from_slice(&0u32.to_le_bytes()); // BI_RGB
    dib.extend_from_slice(&((w * h * 4) as u32).to_le_bytes()); // biSizeImage
    dib.extend_from_slice(&0i32.to_le_bytes()); // biXPelsPerMeter
    dib.extend_from_slice(&0i32.to_le_bytes()); // biYPelsPerMeter
    dib.extend_from_slice(&0u32.to_le_bytes()); // biClrUsed
    dib.extend_from_slice(&0u32.to_le_bytes()); // biClrImportant

    let raw = rgba.as_raw();
    let row_stride = (w as usize) * 4;
    for y in (0..(h as usize)).rev() {
        let row = &raw[y * row_stride..(y + 1) * row_stride];
        for px in row.chunks_exact(4) {
            dib.push(px[2]); // B
            dib.push(px[1]); // G
            dib.push(px[0]); // R
            dib.push(px[3]); // A
        }
    }
    Ok(dib)
}

/// Copies PNG bytes onto the Windows system clipboard as `CF_DIB` for direct `Ctrl+V` into
/// Figma, PowerPoint, Photoshop, and Explorer.
#[cfg(target_os = "windows")]
pub fn write_png_to_clipboard(png_bytes: &[u8]) -> Result<(), String> {
    use windows::Win32::Foundation::{GlobalFree, HANDLE, HWND};
    use windows::Win32::System::DataExchange::{
        CloseClipboard, EmptyClipboard, OpenClipboard, SetClipboardData,
    };
    use windows::Win32::System::Memory::{GlobalAlloc, GlobalLock, GlobalUnlock, GMEM_MOVEABLE};
    use windows::Win32::System::Ole::CF_DIB;

    let dib = png_bytes_to_dib(png_bytes)?;

    struct ClipboardGuard;
    impl Drop for ClipboardGuard {
        fn drop(&mut self) {
            unsafe {
                let _ = CloseClipboard();
            }
        }
    }

    // SAFETY: Standard Win32 clipboard write sequence transferring owned HGLOBAL to OS on success.
    unsafe {
        OpenClipboard(HWND::default()).map_err(|e| format!("OpenClipboard failed: {e}"))?;
        let _guard = ClipboardGuard;
        EmptyClipboard().map_err(|e| format!("EmptyClipboard failed: {e}"))?;

        let hmem = GlobalAlloc(GMEM_MOVEABLE, dib.len())
            .map_err(|e| format!("GlobalAlloc failed: {e}"))?;
        let ptr = GlobalLock(hmem);
        if ptr.is_null() {
            let _ = GlobalFree(hmem);
            return Err("GlobalLock failed".to_string());
        }
        std::ptr::copy_nonoverlapping(dib.as_ptr(), ptr.cast::<u8>(), dib.len());
        let _ = GlobalUnlock(hmem);

        if let Err(err) = SetClipboardData(CF_DIB.0 as u32, HANDLE(hmem.0)) {
            let _ = GlobalFree(hmem);
            return Err(format!("SetClipboardData failed: {err}"));
        }
        Ok(())
    }
}

#[cfg(not(target_os = "windows"))]
pub fn write_png_to_clipboard(_png_bytes: &[u8]) -> Result<(), String> {
    Ok(())
}

/// Handle stopping the background `AddClipboardFormatListener` message window on drop.
pub struct ClipboardListenerHandle {
    hwnd_raw: Arc<AtomicIsize>,
}

impl Drop for ClipboardListenerHandle {
    fn drop(&mut self) {
        #[cfg(target_os = "windows")]
        {
            let raw = self.hwnd_raw.swap(0, Ordering::SeqCst);
            if raw != 0 {
                use windows::Win32::Foundation::{HWND, LPARAM, WPARAM};
                use windows::Win32::UI::WindowsAndMessaging::{PostMessageW, WM_CLOSE};
                unsafe {
                    let _ = PostMessageW(HWND(raw as *mut _), WM_CLOSE, WPARAM(0), LPARAM(0));
                }
            }
        }
    }
}

/// Starts a dedicated hidden `HWND_MESSAGE` Win32 message loop registered with
/// `AddClipboardFormatListener`, invoking `on_update` on every `WM_CLIPBOARDUPDATE`.
pub fn start_clipboard_listener<F>(on_update: F) -> ClipboardListenerHandle
where
    F: Fn(ClipboardPreview) + Send + Sync + 'static,
{
    let hwnd_raw = Arc::new(AtomicIsize::new(0));
    let hwnd_slot = Arc::clone(&hwnd_raw);

    #[cfg(target_os = "windows")]
    let _ = std::thread::Builder::new()
        .name("charkle-clipboard-listener".to_string())
        .spawn(move || {
            use windows::core::PCWSTR;
            use windows::Win32::Foundation::{HWND, LPARAM, LRESULT, WPARAM};
            use windows::Win32::System::DataExchange::{
                AddClipboardFormatListener, RemoveClipboardFormatListener,
            };
            use windows::Win32::System::LibraryLoader::GetModuleHandleW;
            use windows::Win32::UI::WindowsAndMessaging::{
                CreateWindowExW, DefWindowProcW, DestroyWindow, DispatchMessageW, GetMessageW,
                GetWindowLongPtrW, PostQuitMessage, RegisterClassW, SetWindowLongPtrW,
                GWLP_USERDATA, HWND_MESSAGE, MSG, WINDOW_EX_STYLE, WINDOW_STYLE,
                WM_CLIPBOARDUPDATE, WM_CLOSE, WM_DESTROY, WNDCLASSW,
            };

            type CallbackBox = Box<dyn Fn(ClipboardPreview) + Send + Sync>;

            unsafe extern "system" fn wnd_proc(
                hwnd: HWND,
                msg: u32,
                wparam: WPARAM,
                lparam: LPARAM,
            ) -> LRESULT {
                match msg {
                    WM_CLIPBOARDUPDATE => {
                        let ptr =
                            unsafe { GetWindowLongPtrW(hwnd, GWLP_USERDATA) } as *const CallbackBox;
                        if !ptr.is_null() {
                            if let Ok(Some(snap)) = read_current_clipboard() {
                                let cb = unsafe { &*ptr };
                                cb(snap.to_preview());
                            }
                        }
                        return LRESULT(0);
                    }
                    WM_CLOSE => {
                        let _ = unsafe { DestroyWindow(hwnd) };
                        return LRESULT(0);
                    }
                    WM_DESTROY => {
                        let _ = unsafe { RemoveClipboardFormatListener(hwnd) };
                        let ptr = unsafe { SetWindowLongPtrW(hwnd, GWLP_USERDATA, 0) }
                            as *mut CallbackBox;
                        if !ptr.is_null() {
                            let _ = unsafe { Box::from_raw(ptr) };
                        }
                        unsafe { PostQuitMessage(0) };
                        return LRESULT(0);
                    }
                    _ => {}
                }
                unsafe { DefWindowProcW(hwnd, msg, wparam, lparam) }
            }

            let class_name: Vec<u16> = format!("CharkleClipboardListener_{}\0", std::process::id())
                .encode_utf16()
                .collect();
            unsafe {
                let hinst = GetModuleHandleW(None).unwrap_or_default();
                let wc = WNDCLASSW {
                    lpfnWndProc: Some(wnd_proc),
                    hInstance: hinst.into(),
                    lpszClassName: PCWSTR(class_name.as_ptr()),
                    ..Default::default()
                };
                let _ = RegisterClassW(&wc);

                let Ok(hwnd) = CreateWindowExW(
                    WINDOW_EX_STYLE(0),
                    PCWSTR(class_name.as_ptr()),
                    PCWSTR::null(),
                    WINDOW_STYLE(0),
                    0,
                    0,
                    0,
                    0,
                    HWND_MESSAGE,
                    None,
                    hinst,
                    None,
                ) else {
                    return;
                };

                let boxed: Box<CallbackBox> = Box::new(Box::new(on_update));
                let raw_cb = Box::into_raw(boxed) as isize;
                let _ = SetWindowLongPtrW(hwnd, GWLP_USERDATA, raw_cb);
                let _ = AddClipboardFormatListener(hwnd);
                hwnd_slot.store(hwnd.0 as isize, Ordering::SeqCst);

                let mut msg = MSG::default();
                while GetMessageW(&mut msg, HWND::default(), 0, 0).as_bool() {
                    let _ = DispatchMessageW(&msg);
                }
            }
        });

    #[cfg(not(target_os = "windows"))]
    let _ = (on_update, hwnd_slot);

    ClipboardListenerHandle { hwnd_raw }
}

/// Writes one or more existing local file paths to the Windows system clipboard as `CF_HDROP`
/// so users can press `Ctrl+V` directly in Windows Explorer, Figma, Photoshop, or PowerPoint.
pub fn copy_files_to_clipboard(paths: &[PathBuf]) -> Result<usize, String> {
    let existing: Vec<PathBuf> = paths.iter().filter(|p| p.is_file()).cloned().collect();
    if existing.is_empty() {
        return Err("No cached local files available to copy".to_string());
    }

    #[cfg(target_os = "windows")]
    {
        use crate::drag_out::build_hdrop_bytes;
        use windows::Win32::Foundation::{GlobalFree, HANDLE, HWND};
        use windows::Win32::System::DataExchange::{
            CloseClipboard, EmptyClipboard, OpenClipboard, SetClipboardData,
        };
        use windows::Win32::System::Memory::{
            GlobalAlloc, GlobalLock, GlobalUnlock, GMEM_MOVEABLE,
        };
        use windows::Win32::System::Ole::CF_HDROP;

        let normalized: Vec<PathBuf> = existing
            .iter()
            .map(|p| {
                let abs = std::fs::canonicalize(p).unwrap_or_else(|_| p.clone());
                let s = abs.to_string_lossy();
                if let Some(stripped) = s.strip_prefix(r"\\?\UNC\") {
                    PathBuf::from(format!(r"\\{stripped}"))
                } else if let Some(stripped) = s.strip_prefix(r"\\?\") {
                    PathBuf::from(stripped)
                } else {
                    abs
                }
            })
            .collect();
        let hdrop_bytes = build_hdrop_bytes(&normalized);

        // SAFETY: Standard Win32 clipboard ownership transfer for CF_HDROP global buffer.
        unsafe {
            OpenClipboard(HWND::default()).map_err(|e| format!("OpenClipboard failed: {e}"))?;
            let result = (|| -> Result<usize, String> {
                EmptyClipboard().map_err(|e| format!("EmptyClipboard failed: {e}"))?;
                let hmem = GlobalAlloc(GMEM_MOVEABLE, hdrop_bytes.len())
                    .map_err(|e| format!("GlobalAlloc failed: {e}"))?;
                let ptr = GlobalLock(hmem);
                if ptr.is_null() {
                    let _ = GlobalFree(hmem);
                    return Err("GlobalLock failed".to_string());
                }
                std::ptr::copy_nonoverlapping(
                    hdrop_bytes.as_ptr(),
                    ptr as *mut u8,
                    hdrop_bytes.len(),
                );
                let _ = GlobalUnlock(hmem);
                if let Err(err) = SetClipboardData(CF_HDROP.0 as u32, HANDLE(hmem.0)) {
                    let _ = GlobalFree(hmem);
                    return Err(format!("SetClipboardData(CF_HDROP) failed: {err}"));
                }
                Ok(normalized.len())
            })();
            let _ = CloseClipboard();
            result
        }
    }

    #[cfg(not(target_os = "windows"))]
    {
        Ok(existing.len())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn classifies_urls_hex_colors_and_text_accurately() {
        assert_eq!(
            classify_clipboard_text("https://x.com/user/status/123"),
            Some(ClipboardSnapshot::Url {
                url: "https://x.com/user/status/123".to_string()
            })
        );
        assert_eq!(
            classify_clipboard_text("#2a60e0"),
            Some(ClipboardSnapshot::ColorHex {
                hex: "#2A60E0".to_string()
            })
        );
        assert_eq!(
            classify_clipboard_text("design system notes"),
            Some(ClipboardSnapshot::Text {
                text: "design system notes".to_string()
            })
        );
        assert_eq!(
            classify_clipboard_text("Check this post: https://x.com/user/status/987654321!"),
            Some(ClipboardSnapshot::Url {
                url: "https://x.com/user/status/987654321".to_string()
            })
        );
        assert_eq!(classify_clipboard_text("   "), None);
    }

    #[test]
    fn filters_clipboard_preview_banner_flags_strictly() {
        // Plain English prompt text MUST stay kind == "text" and never trigger URL banner flags
        let prompt = classify_clipboard_text("Give the cards and panels in my product a liquid")
            .expect("plain text classifies");
        let prompt_preview = prompt.to_preview();
        assert_eq!(prompt_preview.kind, "text");
        assert!(prompt_preview.url.is_none());
        assert!(!prompt_preview.is_social_or_github_url);

        // Non-dotted bare URL MUST stay plain text (not a valid web bookmark link)
        let bare = classify_clipboard_text("http://localhost:3000/test").expect("bare text");
        assert_eq!(bare.to_preview().kind, "text");

        // Generic website URL classifies as "url" (eligible for universal web link banner)
        let web = classify_clipboard_text("https://tauri.app").expect("generic website");
        let web_preview = web.to_preview();
        assert_eq!(web_preview.kind, "url");
        assert_eq!(web_preview.url.as_deref(), Some("https://tauri.app/"));
        assert!(!web_preview.is_social_or_github_url);

        // Non-repo GitHub settings URL classifies as generic "url", NOT a GitHub repo card
        let gh_settings =
            classify_clipboard_text("https://github.com/settings/profile").expect("gh settings");
        let gh_settings_preview = gh_settings.to_preview();
        assert_eq!(gh_settings_preview.kind, "url");
        assert!(!gh_settings_preview.is_social_or_github_url);

        // Canonical GitHub repository URL sets is_social_or_github_url = true
        let gh_repo =
            classify_clipboard_text("https://github.com/tauri-apps/tauri").expect("gh repo");
        let gh_repo_preview = gh_repo.to_preview();
        assert_eq!(gh_repo_preview.kind, "url");
        assert!(gh_repo_preview.is_social_or_github_url);

        // Canonical X post URL sets is_social_or_github_url = true
        let x_post = classify_clipboard_text("https://x.com/charkle_design/status/1900000001")
            .expect("x post");
        let x_preview = x_post.to_preview();
        assert_eq!(x_preview.kind, "url");
        assert!(x_preview.is_social_or_github_url);

        // Xiaohongshu share copy (short link & canonical note URL) classifies as rich social URL
        let xhs_share = classify_clipboard_text(
            "67 设计师发布了一篇小红书笔记，快来看吧！😆 http://xhslink.com/a/K9xYzAbC12 复制本条信息，打开【小红书】App查看精彩内容！",
        )
        .expect("xhs share copy");
        let xhs_preview = xhs_share.to_preview();
        assert_eq!(xhs_preview.kind, "url");
        assert_eq!(
            xhs_preview.url.as_deref(),
            Some("http://xhslink.com/a/K9xYzAbC12")
        );
        assert!(xhs_preview.is_social_or_github_url);

        let xhs_note = classify_clipboard_text(
            "https://www.xiaohongshu.com/explore/67a1b2c3d4e5f60718293a4b?xsec_token=ABC123",
        )
        .expect("xhs note");
        assert!(xhs_note.to_preview().is_social_or_github_url);
    }

    #[test]
    fn converts_32bit_dib_to_valid_png() {
        let mut dib = vec![0u8; 40 + 2 * 2 * 4];
        dib[0..4].copy_from_slice(&40u32.to_le_bytes()); // biSize
        dib[4..8].copy_from_slice(&2i32.to_le_bytes()); // width = 2
        dib[8..12].copy_from_slice(&(-2i32).to_le_bytes()); // top-down height = 2
        dib[12..14].copy_from_slice(&1u16.to_le_bytes()); // planes = 1
        dib[14..16].copy_from_slice(&32u16.to_le_bytes()); // 32-bit BGRA
                                                           // First pixel: B=224, G=96, R=42, A=255 -> RGBA (42, 96, 224, 255)
        dib[40..44].copy_from_slice(&[224, 96, 42, 255]);

        let (png, w, h) = dib_bytes_to_png(&dib).expect("dib to png");
        assert_eq!((w, h), (2, 2));
        assert!(png.starts_with(b"\x89PNG"));
        let img = image::load_from_memory(&png).expect("decode").to_rgba8();
        assert_eq!(img.get_pixel(0, 0).0, [42, 96, 224, 255]);
    }

    #[test]
    fn roundtrips_png_bytes_to_cf_dib_and_back() {
        let mut src = RgbaImage::new(4, 3);
        src.put_pixel(0, 0, image::Rgba([210, 88, 64, 255]));
        src.put_pixel(3, 2, image::Rgba([42, 96, 224, 255]));
        let mut png_bytes = Vec::new();
        DynamicImage::ImageRgba8(src)
            .write_to(&mut Cursor::new(&mut png_bytes), ImageFormat::Png)
            .expect("encode png");

        let dib = png_bytes_to_dib(&png_bytes).expect("png to dib");
        assert_eq!(dib.len(), 40 + 4 * 3 * 4);
        let (decoded_png, w, h) = dib_bytes_to_png(&dib).expect("dib back to png");
        assert_eq!((w, h), (4, 3));
        let roundtripped = image::load_from_memory(&decoded_png)
            .expect("decode roundtrip")
            .to_rgba8();
        assert_eq!(roundtripped.get_pixel(0, 0).0, [210, 88, 64, 255]);
        assert_eq!(roundtripped.get_pixel(3, 2).0, [42, 96, 224, 255]);
    }
}
