//! Windows Clipboard collector & live `AddClipboardFormatListener` watcher (`clipboard.rs`).
//!
//! Detects images (`CF_DIB`), file drops (`CF_HDROP`), URLs (including X/Threads/Bluesky/GitHub),
//! `#RRGGBB` color hexes, and text snippets without polling.

#![allow(unsafe_code)]

use std::io::Cursor;
use std::path::PathBuf;
use std::sync::atomic::{AtomicIsize, Ordering};
use std::sync::Arc;

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
                let lower = url.to_ascii_lowercase();
                let is_rich = lower.contains("x.com/")
                    || lower.contains("twitter.com/")
                    || lower.contains("threads.net/")
                    || lower.contains("bsky.app/")
                    || lower.contains("github.com/");
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

/// Classifies plain clipboard text into a URL, `#RRGGBB` color swatch, or text snippet.
pub fn classify_clipboard_text(raw: &str) -> Option<ClipboardSnapshot> {
    let trimmed = raw.trim();
    if trimmed.is_empty() {
        return None;
    }

    // Color hex (`#RRGGBB` or `RRGGBB` when standalone)
    let hex_candidate = trimmed.strip_prefix('#').unwrap_or(trimmed);
    if trimmed.starts_with('#')
        && hex_candidate.len() == 6
        && hex_candidate.chars().all(|c| c.is_ascii_hexdigit())
    {
        return Some(ClipboardSnapshot::ColorHex {
            hex: format!("#{}", hex_candidate.to_ascii_uppercase()),
        });
    }

    // Single-line URL
    if !trimmed.contains(char::is_whitespace)
        && (trimmed.starts_with("https://") || trimmed.starts_with("http://"))
    {
        return Some(ClipboardSnapshot::Url {
            url: trimmed.to_string(),
        });
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
    let header_size = u32::from_le_bytes(dib[0..4].try_into().unwrap()) as usize;
    let width_i = i32::from_le_bytes(dib[4..8].try_into().unwrap());
    let height_i = i32::from_le_bytes(dib[8..12].try_into().unwrap());
    let bit_count = u16::from_le_bytes(dib[14..16].try_into().unwrap());
    let compression = u32::from_le_bytes(dib[16..20].try_into().unwrap());
    let clr_used = u32::from_le_bytes(dib[32..36].try_into().unwrap()) as usize;

    if width_i <= 0 || height_i == 0 {
        return Err("Invalid DIB dimensions".to_string());
    }
    let width = width_i as u32;
    let height = height_i.unsigned_abs();
    let top_down = height_i < 0;

    // BI_RGB (0) or BI_BITFIELDS (3)
    let extra_masks = if compression == 3 && header_size == 40 {
        12
    } else {
        0
    };
    let palette_bytes = if bit_count <= 8 {
        let entries = if clr_used > 0 {
            clr_used
        } else {
            1usize << bit_count
        };
        entries * 4
    } else {
        clr_used * 4
    };
    let pixel_offset = header_size + extra_masks + palette_bytes;
    if pixel_offset >= dib.len() {
        return Err("CF_DIB pixel offset out of range".to_string());
    }
    let pixels = &dib[pixel_offset..];

    let mut rgba = vec![0u8; (width as usize) * (height as usize) * 4];
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

/// Reads the current Windows clipboard snapshot (`CF_HDROP` -> `CF_DIB` -> `CF_UNICODETEXT`).
#[cfg(target_os = "windows")]
pub fn read_current_clipboard() -> Result<Option<ClipboardSnapshot>, String> {
    use windows::Win32::Foundation::{HGLOBAL, HWND};
    use windows::Win32::System::DataExchange::{
        CloseClipboard, GetClipboardData, IsClipboardFormatAvailable, OpenClipboard,
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

        // 2. Bitmap image (CF_DIB)
        if IsClipboardFormatAvailable(CF_DIB.0 as u32).is_ok() {
            if let Ok(handle) = GetClipboardData(CF_DIB.0 as u32) {
                let hglobal = HGLOBAL(handle.0);
                let size = GlobalSize(hglobal);
                let ptr = GlobalLock(hglobal);
                if !ptr.is_null() && size >= 40 {
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

        // 3. Unicode text / URL / Hex color (CF_UNICODETEXT)
        if IsClipboardFormatAvailable(CF_UNICODETEXT.0 as u32).is_ok() {
            if let Ok(handle) = GetClipboardData(CF_UNICODETEXT.0 as u32) {
                let hglobal = HGLOBAL(handle.0);
                let size = GlobalSize(hglobal);
                let ptr = GlobalLock(hglobal);
                if !ptr.is_null() && size >= 2 {
                    let _lock = GlobalLockGuard(hglobal);
                    let units = std::slice::from_raw_parts(ptr as *const u16, size / 2);
                    let len = units.iter().position(|&c| c == 0).unwrap_or(units.len());
                    let text = String::from_utf16_lossy(&units[..len]);
                    return Ok(classify_clipboard_text(&text));
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
        assert_eq!(classify_clipboard_text("   "), None);
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
}
