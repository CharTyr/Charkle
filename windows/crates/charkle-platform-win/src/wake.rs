//! Cross-process Windows named-event live-refresh bridge (`wake.rs`) between headless
//! `charkle-cli.exe` (MCP / CLI) and the running `charkle-desktop.exe` application.
//!
//! Uses a Win32 auto-reset named event (`Local\CharkleLibraryChanged`) plus a lightweight
//! `.wake` timestamp file fallback so any external write immediately wakes the desktop UI.

#![allow(unsafe_code)]

use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::{SystemTime, UNIX_EPOCH};

pub const NAMED_EVENT_NAME: &str = "Local\\CharkleLibraryChanged";

/// Signals the running Charkle desktop process that an external CLI/MCP agent wrote to the library.
pub fn pulse_library_changed(data_dir: Option<&Path>) {
    if let Some(dir) = data_dir {
        let now_ms = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|d| d.as_millis())
            .unwrap_or(0);
        let _ = std::fs::write(dir.join(".wake"), now_ms.to_string());
    }

    #[cfg(target_os = "windows")]
    {
        use windows::core::PCWSTR;
        use windows::Win32::Foundation::CloseHandle;
        use windows::Win32::System::Threading::{OpenEventW, SetEvent, EVENT_MODIFY_STATE};

        let wide: Vec<u16> = NAMED_EVENT_NAME
            .encode_utf16()
            .chain(std::iter::once(0))
            .collect();
        // SAFETY: Standard Win32 OpenEventW/SetEvent/CloseHandle for cross-process notification.
        unsafe {
            if let Ok(handle) = OpenEventW(EVENT_MODIFY_STATE, false, PCWSTR(wide.as_ptr())) {
                let _ = SetEvent(handle);
                let _ = CloseHandle(handle);
            }
        }
    }
}

/// Handle stopping the background named-event listener on drop.
pub struct LibraryWakeHandle {
    stop: Arc<AtomicBool>,
}

impl Drop for LibraryWakeHandle {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::SeqCst);
        pulse_library_changed(None);
    }
}

/// Starts a dedicated background thread listening on `Local\CharkleLibraryChanged`
/// (and `.wake` mtime changes as fallback), invoking `on_wake` whenever `charkle-cli.exe` writes.
pub fn start_library_wake_listener<F>(data_dir: PathBuf, on_wake: F) -> LibraryWakeHandle
where
    F: Fn() + Send + Sync + 'static,
{
    let stop = Arc::new(AtomicBool::new(false));
    let stop_flag = Arc::clone(&stop);

    #[cfg(target_os = "windows")]
    {
        let _ = std::thread::Builder::new()
            .name("charkle-cli-wake".to_string())
            .spawn(move || {
                use windows::core::PCWSTR;
                use windows::Win32::Foundation::{CloseHandle, WAIT_OBJECT_0};
                use windows::Win32::System::Threading::{CreateEventW, WaitForSingleObject};

                let wide: Vec<u16> = NAMED_EVENT_NAME
                    .encode_utf16()
                    .chain(std::iter::once(0))
                    .collect();
                // SAFETY: Auto-reset named event created once for the desktop process lifetime.
                let event = unsafe { CreateEventW(None, false, false, PCWSTR(wide.as_ptr())).ok() };
                let wake_file = data_dir.join(".wake");
                let mut last_wake_content = std::fs::read_to_string(&wake_file).ok();

                while !stop_flag.load(Ordering::SeqCst) {
                    let signaled = if let Some(h) = event {
                        // SAFETY: Waiting up to 1000ms on a valid Win32 event handle.
                        unsafe { WaitForSingleObject(h, 1000) == WAIT_OBJECT_0 }
                    } else {
                        std::thread::sleep(std::time::Duration::from_millis(1000));
                        false
                    };
                    if stop_flag.load(Ordering::SeqCst) {
                        break;
                    }
                    let current_wake = std::fs::read_to_string(&wake_file).ok();
                    let file_changed = current_wake.is_some() && current_wake != last_wake_content;
                    if file_changed {
                        last_wake_content = current_wake;
                    }
                    if signaled || file_changed {
                        on_wake();
                    }
                }
                if let Some(h) = event {
                    unsafe {
                        let _ = CloseHandle(h);
                    }
                }
            });
    }

    #[cfg(not(target_os = "windows"))]
    let _ = (data_dir, on_wake, stop_flag);

    LibraryWakeHandle { stop }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::AtomicUsize;

    #[test]
    fn named_event_wakes_listener_immediately() {
        let dir = tempfile::tempdir().unwrap();
        let hits = Arc::new(AtomicUsize::new(0));
        let hits_clone = Arc::clone(&hits);
        let _handle = start_library_wake_listener(dir.path().to_path_buf(), move || {
            hits_clone.fetch_add(1, Ordering::SeqCst);
        });
        std::thread::sleep(std::time::Duration::from_millis(80));
        pulse_library_changed(Some(dir.path()));
        std::thread::sleep(std::time::Duration::from_millis(120));
        assert!(hits.load(Ordering::SeqCst) >= 1);
    }
}
