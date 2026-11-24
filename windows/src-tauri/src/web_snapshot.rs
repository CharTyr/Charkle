//! Tier 2 Ephemeral Offscreen WebView2 Webpage Snapshotter (`web_snapshot.rs`).
//!
//! Captures a crisp `1280×800` PNG preview + DOM title/description for SPA or OG-less webpages
//! using a hidden, incognito, offscreen Tauri `WebviewWindow` with a hard 6.5s timeout, 420ms
//! post-load settle window, and an RAII drop guard that ALWAYS destroys the ephemeral window
//! so zero WebView2 processes ever leak.

#![allow(unsafe_code)]

use std::sync::{Arc, Mutex};
use std::time::Duration;

use async_trait::async_trait;
use charkle_core::traits::{WebPageSnapshot, WebPageSnapshotProvider};
use serde::Deserialize;
use tauri::webview::PageLoadEvent;
use tauri::{AppHandle, Manager, WebviewUrl, WebviewWindowBuilder};
use tokio::sync::{oneshot, Semaphore};
use url::Url;
use uuid::Uuid;

const SNAPSHOT_BROWSER_UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36";

/// RAII cleanup guard ensuring the ephemeral offscreen WebView2 window is ALWAYS destroyed
/// regardless of success, timeout, error, or future cancellation.
struct EphemeralWindowGuard {
    app: AppHandle,
    label: String,
    destroyed: bool,
}

impl EphemeralWindowGuard {
    fn new(app: AppHandle, label: String) -> Self {
        Self {
            app,
            label,
            destroyed: false,
        }
    }

    fn destroy_now(&mut self) {
        if self.destroyed {
            return;
        }
        self.destroyed = true;
        let app = self.app.clone();
        let label = self.label.clone();
        let _ = self.app.run_on_main_thread(move || {
            if let Some(win) = app.get_webview_window(&label) {
                let _ = win.destroy();
            }
        });
    }
}

impl Drop for EphemeralWindowGuard {
    fn drop(&mut self) {
        self.destroy_now();
    }
}

#[derive(Deserialize)]
struct DomMetaPayload {
    title: Option<String>,
    description: Option<String>,
}

/// Concrete `WebPageSnapshotProvider` backed by an ephemeral hidden offscreen WebView2 window.
pub struct TauriWebViewSnapshotter {
    app: AppHandle,
    /// Serialize snapshots so batch URL imports never spawn concurrent WebView2 processes.
    semaphore: Arc<Semaphore>,
}

impl TauriWebViewSnapshotter {
    pub fn new(app: AppHandle) -> Self {
        Self {
            app,
            semaphore: Arc::new(Semaphore::new(1)),
        }
    }
}

#[async_trait]
impl WebPageSnapshotProvider for TauriWebViewSnapshotter {
    async fn capture_snapshot(&self, raw_url: &str) -> Option<WebPageSnapshot> {
        let parsed = Url::parse(raw_url.trim()).ok()?;
        if !matches!(parsed.scheme(), "http" | "https") {
            return None;
        }
        let _permit = self.semaphore.acquire().await.ok()?;

        #[cfg(not(target_os = "windows"))]
        {
            let _ = (&self.app, parsed);
            return None;
        }

        #[cfg(target_os = "windows")]
        {
            let label = format!("charkle-snap-{}", Uuid::new_v4().simple());
            let mut guard = EphemeralWindowGuard::new(self.app.clone(), label.clone());

            let (loaded_tx, loaded_rx) = oneshot::channel::<()>();
            let loaded_slot = Arc::new(Mutex::new(Some(loaded_tx)));

            let win = WebviewWindowBuilder::new(&self.app, &label, WebviewUrl::External(parsed))
                .title("")
                .inner_size(1280.0, 800.0)
                .position(-32000.0, -32000.0)
                .decorations(false)
                .shadow(false)
                .resizable(false)
                .visible(false)
                .focused(false)
                .skip_taskbar(true)
                .incognito(true)
                .disable_drag_drop_handler()
                .user_agent(SNAPSHOT_BROWSER_UA)
                .on_page_load(move |_win, payload| {
                    if matches!(payload.event(), PageLoadEvent::Finished) {
                        if let Ok(mut slot) = loaded_slot.lock() {
                            if let Some(tx) = slot.take() {
                                let _ = tx.send(());
                            }
                        }
                    }
                })
                .build()
                .ok()?;

            // Wait up to 6.5s for initial page finish; on finish settle 420ms for webfonts/hero.
            let nav_completed = tokio::time::timeout(Duration::from_millis(6500), loaded_rx)
                .await
                .is_ok();
            if nav_completed {
                tokio::time::sleep(Duration::from_millis(420)).await;
            }

            let captured = capture_webview2_preview(&win).await;
            guard.destroy_now();
            captured
        }
    }
}

#[cfg(target_os = "windows")]
async fn capture_webview2_preview(win: &tauri::WebviewWindow) -> Option<WebPageSnapshot> {
    use webview2_com::Microsoft::Web::WebView2::Win32::{
        ICoreWebView2_8, COREWEBVIEW2_CAPTURE_PREVIEW_IMAGE_FORMAT_PNG,
    };
    use webview2_com::{CapturePreviewCompletedHandler, ExecuteScriptCompletedHandler};
    use windows::core::{w, Interface, PWSTR};
    use windows::Win32::Foundation::HGLOBAL;
    use windows::Win32::System::Com::StructuredStorage::{
        CreateStreamOnHGlobal, GetHGlobalFromStream,
    };
    use windows::Win32::System::Com::{CoTaskMemFree, STATFLAG_NONAME, STATSTG};
    use windows::Win32::System::Memory::{GlobalLock, GlobalSize, GlobalUnlock};

    let (png_tx, png_rx) = oneshot::channel::<Option<Vec<u8>>>();
    let (meta_tx, meta_rx) = oneshot::channel::<Option<DomMetaPayload>>();
    let (url_tx, url_rx) = oneshot::channel::<Option<String>>();

    let png_slot = Arc::new(Mutex::new(Some(png_tx)));
    let meta_slot = Arc::new(Mutex::new(Some(meta_tx)));
    let url_slot = Arc::new(Mutex::new(Some(url_tx)));

    let dispatch_res = win.with_webview(move |platform_wv| {
        let controller = platform_wv.controller();
        let Ok(core) = (unsafe { controller.CoreWebView2() }) else {
            return;
        };

        // Ensure silent offscreen rendering (mute any auto-playing media).
        if let Ok(core8) = core.cast::<ICoreWebView2_8>() {
            let _ = unsafe { core8.SetIsMuted(true) };
        }

        // Capture resolved URL (informational only; callers NEVER overwrite user's source_url).
        let mut src_pwstr = PWSTR::null();
        let final_url = if unsafe { core.Source(&mut src_pwstr) }.is_ok() && !src_pwstr.is_null() {
            let text = unsafe { src_pwstr.to_string() }.ok();
            unsafe { CoTaskMemFree(Some(src_pwstr.0 as _)) };
            text
        } else {
            None
        };
        if let Ok(mut s) = url_slot.lock() {
            if let Some(tx) = s.take() {
                let _ = tx.send(final_url);
            }
        }

        // Capture DOM title & meta description via ExecuteScript.
        let meta_slot_cb = Arc::clone(&meta_slot);
        let script = w!(
            "JSON.stringify({title: document.title || '', description: (document.querySelector('meta[property=\"og:description\"]')?.content || document.querySelector('meta[name=\"description\"]')?.content || '')})"
        );
        let script_handler = ExecuteScriptCompletedHandler::create(Box::new(move |hr, raw_json| {
            let parsed = if hr.is_ok() {
                serde_json::from_str::<String>(&raw_json)
                    .ok()
                    .and_then(|inner| serde_json::from_str::<DomMetaPayload>(&inner).ok())
            } else {
                None
            };
            if let Ok(mut s) = meta_slot_cb.lock() {
                if let Some(tx) = s.take() {
                    let _ = tx.send(parsed);
                }
            }
            Ok(())
        }));
        let _ = unsafe { core.ExecuteScript(script, &script_handler) };

        // Capture 1280×800 PNG preview into an in-memory COM IStream.
        let Ok(stream) = (unsafe { CreateStreamOnHGlobal(HGLOBAL::default(), true) }) else {
            if let Ok(mut s) = png_slot.lock() {
                if let Some(tx) = s.take() {
                    let _ = tx.send(None);
                }
            }
            return;
        };
        let stream_for_cb = stream.clone();
        let png_slot_cb = Arc::clone(&png_slot);
        let preview_handler = CapturePreviewCompletedHandler::create(Box::new(move |hr| {
            let bytes = if hr.is_ok() {
                unsafe { GetHGlobalFromStream(&stream_for_cb) }
                    .ok()
                    .and_then(|hglobal| {
                        let alloc_size = unsafe { GlobalSize(hglobal) };
                        if alloc_size == 0 {
                            return None;
                        }
                        let mut stat = STATSTG::default();
                        let exact_len =
                            if unsafe { stream_for_cb.Stat(&mut stat, STATFLAG_NONAME) }.is_ok()
                                && stat.cbSize > 0
                            {
                                (stat.cbSize as usize).min(alloc_size)
                            } else {
                                alloc_size
                            };
                        let ptr = unsafe { GlobalLock(hglobal) };
                        if ptr.is_null() {
                            return None;
                        }
                        let data =
                            unsafe { std::slice::from_raw_parts(ptr as *const u8, exact_len) }
                                .to_vec();
                        let _ = unsafe { GlobalUnlock(hglobal) };
                        Some(data)
                    })
            } else {
                None
            };
            if let Ok(mut s) = png_slot_cb.lock() {
                if let Some(tx) = s.take() {
                    let _ = tx.send(bytes);
                }
            }
            Ok(())
        }));

        if unsafe {
            core.CapturePreview(
                COREWEBVIEW2_CAPTURE_PREVIEW_IMAGE_FORMAT_PNG,
                &stream,
                &preview_handler,
            )
        }
        .is_err()
        {
            if let Ok(mut s) = png_slot.lock() {
                if let Some(tx) = s.take() {
                    let _ = tx.send(None);
                }
            }
        }
    });

    if dispatch_res.is_err() {
        return None;
    }

    let png_bytes = tokio::time::timeout(Duration::from_millis(2200), png_rx)
        .await
        .ok()?
        .ok()??;
    if png_bytes.is_empty() {
        return None;
    }

    let meta = tokio::time::timeout(Duration::from_millis(800), meta_rx)
        .await
        .ok()
        .and_then(Result::ok)
        .flatten();
    let final_url = tokio::time::timeout(Duration::from_millis(200), url_rx)
        .await
        .ok()
        .and_then(Result::ok)
        .flatten();

    let clean_title = meta
        .as_ref()
        .and_then(|m| m.title.as_deref())
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .map(|s| s.chars().take(220).collect());
    let clean_desc = meta
        .as_ref()
        .and_then(|m| m.description.as_deref())
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .map(|s| s.chars().take(420).collect());

    Some(WebPageSnapshot {
        png_bytes,
        title: clean_title,
        description: clean_desc,
        final_url,
    })
}
