//! Windows Shell thumbnail provider (`IShellItemImageFactory`) running on a dedicated
//! STA COM worker thread with strict RAII `HBITMAP` / `HDC` resource cleanup.
//!
//! Renders native system previews for PSD, AI, PDF, HEIC, video, and 3D assets whenever
//! built-in Rust decoders do not handle the format.

#![allow(unsafe_code)]

use std::path::{Path, PathBuf};

use async_trait::async_trait;
use charkle_core::traits::ShellThumbnailProvider;
use tokio::sync::{mpsc, oneshot};

#[cfg(target_os = "windows")]
use image::{DynamicImage, ImageFormat, RgbaImage};
#[cfg(target_os = "windows")]
use std::io::Cursor;
#[cfg(target_os = "windows")]
use windows::core::PCWSTR;
#[cfg(target_os = "windows")]
use windows::Win32::Foundation::SIZE;
#[cfg(target_os = "windows")]
use windows::Win32::Graphics::Gdi::{
    CreateCompatibleDC, DeleteDC, DeleteObject, GetDIBits, GetObjectW, BITMAP, BITMAPINFO,
    BITMAPINFOHEADER, BI_RGB, DIB_RGB_COLORS, HBITMAP, HDC, HGDIOBJ,
};
#[cfg(target_os = "windows")]
use windows::Win32::System::Com::{
    CoInitializeEx, CoUninitialize, COINIT_APARTMENTTHREADED, COINIT_DISABLE_OLE1DDE,
};
#[cfg(target_os = "windows")]
use windows::Win32::UI::Shell::{
    IShellItemImageFactory, SHCreateItemFromParsingName, SIIGBF_BIGGERSIZEOK, SIIGBF_RESIZETOFIT,
};

struct ThumbJob {
    file_path: PathBuf,
    max_side: u32,
    reply: oneshot::Sender<Result<Option<Vec<u8>>, String>>,
}

#[cfg(target_os = "windows")]
struct ComStaGuard(bool);

#[cfg(target_os = "windows")]
impl Drop for ComStaGuard {
    fn drop(&mut self) {
        if self.0 {
            // SAFETY: Matches successful `CoInitializeEx` on this dedicated STA thread.
            unsafe {
                CoUninitialize();
            }
        }
    }
}

#[cfg(target_os = "windows")]
struct OwnedHBitmap(HBITMAP);

#[cfg(target_os = "windows")]
impl Drop for OwnedHBitmap {
    fn drop(&mut self) {
        if !self.0.is_invalid() {
            // SAFETY: `self.0` is an exclusively owned GDI HBITMAP from `GetImage`.
            unsafe {
                let _ = DeleteObject(HGDIOBJ(self.0 .0));
            }
        }
    }
}

#[cfg(target_os = "windows")]
struct OwnedDC(HDC);

#[cfg(target_os = "windows")]
impl Drop for OwnedDC {
    fn drop(&mut self) {
        if !self.0.is_invalid() {
            // SAFETY: `self.0` was created by `CreateCompatibleDC` and is exclusively owned.
            unsafe {
                let _ = DeleteDC(self.0);
            }
        }
    }
}

/// STA COM worker-backed `ShellThumbnailProvider` safe to share across Tokio async tasks.
#[derive(Debug, Clone)]
pub struct WinShellThumbnailProvider {
    tx: mpsc::Sender<ThumbJob>,
}

impl Default for WinShellThumbnailProvider {
    fn default() -> Self {
        Self::new()
    }
}

impl WinShellThumbnailProvider {
    pub fn new() -> Self {
        const MAX_PENDING_THUMB_JOBS: usize = 128;
        let (tx, mut rx) = mpsc::channel::<ThumbJob>(MAX_PENDING_THUMB_JOBS);

        let _ = std::thread::Builder::new()
            .name("charkle-shell-thumb-sta".to_string())
            .spawn(move || {
                #[cfg(target_os = "windows")]
                let _com_guard = {
                    // SAFETY: Dedicated STA thread initializes COM apartment once.
                    let hr = unsafe {
                        CoInitializeEx(None, COINIT_APARTMENTTHREADED | COINIT_DISABLE_OLE1DDE)
                    };
                    ComStaGuard(hr.is_ok())
                };

                while let Some(job) = rx.blocking_recv() {
                    if job.reply.is_closed() {
                        continue;
                    }
                    let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                        generate_thumbnail_on_sta(&job.file_path, job.max_side)
                    }))
                    .unwrap_or_else(|_| Err("Shell thumbnail STA worker panicked".to_string()));
                    let _ = job.reply.send(result);
                }
            });

        Self { tx }
    }
}

#[async_trait]
impl ShellThumbnailProvider for WinShellThumbnailProvider {
    async fn generate_thumbnail_png(
        &self,
        file_path: &Path,
        max_side: u32,
    ) -> Result<Option<Vec<u8>>, String> {
        let (reply_tx, reply_rx) = oneshot::channel();
        let job = ThumbJob {
            file_path: file_path.to_path_buf(),
            max_side: max_side.clamp(32, 2048),
            reply: reply_tx,
        };
        self.tx
            .send(job)
            .await
            .map_err(|_| "Shell thumbnail STA worker is shut down".to_string())?;
        reply_rx
            .await
            .map_err(|_| "Shell thumbnail STA worker dropped response".to_string())?
    }
}

#[cfg(target_os = "windows")]
fn normalize_shell_path(path: &Path) -> PathBuf {
    let abs = std::fs::canonicalize(path).unwrap_or_else(|_| path.to_path_buf());
    let s = abs.to_string_lossy();
    if let Some(stripped) = s.strip_prefix(r"\\?\UNC\") {
        PathBuf::from(format!(r"\\{stripped}"))
    } else if let Some(stripped) = s.strip_prefix(r"\\?\") {
        PathBuf::from(stripped)
    } else {
        abs
    }
}

#[cfg(target_os = "windows")]
fn generate_thumbnail_on_sta(file_path: &Path, max_side: u32) -> Result<Option<Vec<u8>>, String> {
    if !file_path.is_file() {
        return Ok(None);
    }

    let clean_path = normalize_shell_path(file_path);
    let wide: Vec<u16> = clean_path
        .to_string_lossy()
        .encode_utf16()
        .chain(std::iter::once(0))
        .collect();

    // SAFETY: STA COM is initialized on this worker thread; `wide` is NUL-terminated UTF-16.
    let factory: IShellItemImageFactory =
        match unsafe { SHCreateItemFromParsingName(PCWSTR(wide.as_ptr()), None) } {
            Ok(f) => f,
            Err(_) => return Ok(None),
        };

    let side = max_side.clamp(32, 2048) as i32;
    // SAFETY: `factory` is a valid COM interface on this STA thread; returned HBITMAP is
    // immediately wrapped in `OwnedHBitmap`.
    let raw_hbitmap = match unsafe {
        factory.GetImage(
            SIZE { cx: side, cy: side },
            SIIGBF_RESIZETOFIT | SIIGBF_BIGGERSIZEOK,
        )
    } {
        Ok(bmp) => bmp,
        Err(_) => return Ok(None),
    };
    let hbitmap = OwnedHBitmap(raw_hbitmap);

    let mut bm = BITMAP::default();
    // SAFETY: `hbitmap.0` is live; `bm` has exact `BITMAP` layout.
    let got = unsafe {
        GetObjectW(
            HGDIOBJ(hbitmap.0 .0),
            std::mem::size_of::<BITMAP>() as i32,
            Some((&mut bm as *mut BITMAP).cast()),
        )
    };
    if got == 0 || bm.bmWidth <= 0 || bm.bmHeight <= 0 || bm.bmWidth > 8192 || bm.bmHeight > 8192 {
        return Ok(None);
    }

    let width = bm.bmWidth as u32;
    let height = bm.bmHeight as u32;
    let bgra_len = (width as usize)
        .checked_mul(height as usize)
        .and_then(|px| px.checked_mul(4))
        .ok_or_else(|| "Shell thumbnail dimensions overflow".to_string())?;

    // SAFETY: Compatible memory DC is immediately guarded by `OwnedDC`.
    let hdc = OwnedDC(unsafe { CreateCompatibleDC(HDC::default()) });
    if hdc.0.is_invalid() {
        return Err("CreateCompatibleDC failed".to_string());
    }

    let mut bmi = BITMAPINFO {
        bmiHeader: BITMAPINFOHEADER {
            biSize: std::mem::size_of::<BITMAPINFOHEADER>() as u32,
            biWidth: width as i32,
            biHeight: -(height as i32), // Top-down DIB
            biPlanes: 1,
            biBitCount: 32,
            biCompression: BI_RGB.0,
            ..Default::default()
        },
        ..Default::default()
    };

    let mut bgra = vec![0u8; bgra_len];
    // SAFETY: `bgra` has exact size `width * height * 4` matching 32-bit top-down `bmi`.
    let scanlines = unsafe {
        GetDIBits(
            hdc.0,
            hbitmap.0,
            0,
            height,
            Some(bgra.as_mut_ptr().cast()),
            &mut bmi,
            DIB_RGB_COLORS,
        )
    };
    if scanlines == 0 {
        return Ok(None);
    }

    // Convert BGRA -> RGBA and fix fully-zero alpha channels on opaque bitmaps
    let mut has_nonzero_alpha = false;
    for px in bgra.chunks_exact_mut(4) {
        px.swap(0, 2);
        if px[3] != 0 {
            has_nonzero_alpha = true;
        }
    }
    if !has_nonzero_alpha {
        for px in bgra.chunks_exact_mut(4) {
            px[3] = 255;
        }
    }

    let Some(rgba_img) = RgbaImage::from_raw(width, height, bgra) else {
        return Ok(None);
    };
    let mut png_bytes = Vec::new();
    DynamicImage::ImageRgba8(rgba_img)
        .write_to(&mut Cursor::new(&mut png_bytes), ImageFormat::Png)
        .map_err(|e| format!("Failed to encode shell thumbnail PNG: {e}"))?;

    Ok(Some(png_bytes))
}

#[cfg(not(target_os = "windows"))]
fn generate_thumbnail_on_sta(_file_path: &Path, _max_side: u32) -> Result<Option<Vec<u8>>, String> {
    Ok(None)
}

#[cfg(test)]
mod tests {
    use super::*;
    use image::{DynamicImage, ImageFormat, Rgba, RgbaImage};
    use tempfile::tempdir;

    #[cfg(target_os = "windows")]
    fn current_gdi_handle_count() -> u32 {
        use windows::Win32::System::Threading::{
            GetCurrentProcess, GetGuiResources, GR_GDIOBJECTS,
        };
        // SAFETY: Read-only query on current process handle.
        unsafe { GetGuiResources(GetCurrentProcess(), GR_GDIOBJECTS) }
    }

    #[tokio::test]
    async fn shell_thumbnail_generates_png_with_zero_gdi_handle_leaks_over_500_calls() {
        let dir = tempdir().expect("tempdir");
        let sample = dir.path().join("sample.png");
        let img = RgbaImage::from_pixel(256, 192, Rgba([42, 96, 224, 255]));
        DynamicImage::ImageRgba8(img)
            .save_with_format(&sample, ImageFormat::Png)
            .expect("save sample");

        let provider = WinShellThumbnailProvider::new();

        // Warmup shell COM caches
        for _ in 0..5 {
            let png = provider
                .generate_thumbnail_png(&sample, 256)
                .await
                .expect("warmup thumb");
            #[cfg(target_os = "windows")]
            assert!(png.is_some(), "Shell should return a valid PNG thumbnail");
            let _ = png;
        }

        #[cfg(target_os = "windows")]
        let gdi_before = current_gdi_handle_count();

        for _ in 0..500 {
            let png = provider
                .generate_thumbnail_png(&sample, 256)
                .await
                .expect("stress thumb");
            #[cfg(target_os = "windows")]
            assert!(png.as_ref().is_some_and(|b| b.starts_with(b"\x89PNG")));
            let _ = png;
        }

        #[cfg(target_os = "windows")]
        {
            let gdi_after = current_gdi_handle_count();
            assert!(
                gdi_after <= gdi_before + 4,
                "GDI handle leak detected across 500 thumbnail calls: before={gdi_before}, after={gdi_after}"
            );
        }
    }
}
