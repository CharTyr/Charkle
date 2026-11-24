//! Native Windows OLE outbound file drag (`DoDragDrop` + Shell `IDataObject` / `CF_HDROP`
//! + native Shell translucent thumbnail drag preview via `IDragSourceHelper`).
//!
//! CRITICAL WIN32 INVARIANTS:
//! 1. `DoDragDrop` MUST run on the application's Win32 UI STA thread (the same thread that owns
//!    the Tauri HWND), NEVER on a detached background `std::thread::spawn` (a detached thread has
//!    no foreground authority, fails `SetCapture`, and deadlocks inside its modal `GetMessage` loop).
//! 2. Because `WM_LBUTTONDOWN` is processed in WebView2's child process (`msedgewebview2.exe`)
//!    and the Top-Edge Drop Shelf uses `WS_EX_NOACTIVATE`, we temporarily promote the source HWND
//!    to foreground (detaching `AttachThreadInput` BEFORE `DoDragDrop`), release WebView2's capture,
//!    and check hardware button state with `GetAsyncKeyState` inside `QueryContinueDrag`.

#![allow(unsafe_code)]

use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum DragOutOutcome {
    Copied,
    Moved,
    Linked,
    Cancelled,
}

/// Serializes one or more file paths into an exact Win32 `DROPFILES` UTF-16LE binary buffer
/// (`CF_HDROP` format: 20-byte `DROPFILES` header + NUL-separated UTF-16 paths + extra NUL).
pub fn build_hdrop_bytes(paths: &[PathBuf]) -> Vec<u8> {
    const DROPFILES_HEADER_BYTES: usize = 20;
    let mut out = Vec::with_capacity(DROPFILES_HEADER_BYTES + paths.len() * 64);
    // pFiles: u32 = 20
    out.extend_from_slice(&(DROPFILES_HEADER_BYTES as u32).to_le_bytes());
    // pt.x: i32 = 0, pt.y: i32 = 0
    out.extend_from_slice(&0i32.to_le_bytes());
    out.extend_from_slice(&0i32.to_le_bytes());
    // fNC: BOOL = 0
    out.extend_from_slice(&0i32.to_le_bytes());
    // fWide: BOOL = 1 (Unicode UTF-16)
    out.extend_from_slice(&1i32.to_le_bytes());

    for path in paths {
        for unit in path.to_string_lossy().encode_utf16() {
            out.extend_from_slice(&unit.to_le_bytes());
        }
        out.extend_from_slice(&0u16.to_le_bytes());
    }
    // Double NUL terminator
    out.extend_from_slice(&0u16.to_le_bytes());
    out
}

/// Executes a synchronous Win32 OLE `DoDragDrop` directly on the caller's UI STA thread.
/// MUST be invoked inside `app.run_on_main_thread(...)` from Tauri!
pub fn run_outbound_file_drag_on_ui_thread(
    paths: &[PathBuf],
    preview_image_path: Option<&Path>,
    source_hwnd: isize,
    is_shelf_window: bool,
) -> Result<DragOutOutcome, String> {
    let existing: Vec<PathBuf> = paths.iter().filter(|p| p.is_file()).cloned().collect();
    if existing.is_empty() {
        return Err("所选素材尚未缓存在本地磁盘，无法拖出到外部应用".to_string());
    }
    #[cfg(target_os = "windows")]
    {
        win_ole::run(&existing, preview_image_path, source_hwnd, is_shelf_window)
    }
    #[cfg(not(target_os = "windows"))]
    {
        let _ = (preview_image_path, source_hwnd, is_shelf_window);
        Ok(DragOutOutcome::Cancelled)
    }
}

/// Backward-compatible helper (prefer `run_outbound_file_drag_on_ui_thread` from Tauri UI thread).
pub async fn start_outbound_file_drag(paths: Vec<PathBuf>) -> Result<DragOutOutcome, String> {
    let existing: Vec<PathBuf> = paths.into_iter().filter(|p| p.is_file()).collect();
    if existing.is_empty() {
        return Err("No cached local files available for outbound drag".to_string());
    }
    run_outbound_file_drag_on_ui_thread(&existing, None, 0, false)
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
mod win_ole {
    use super::*;
    use crate::shelf_win::{set_shelf_allow_activate, set_shelf_outbound_dragging};
    use std::ffi::c_void;
    use windows::core::{implement, HRESULT, PCWSTR};
    use windows::Win32::Foundation::{
        BOOL, COLORREF, DRAGDROP_S_CANCEL, DRAGDROP_S_DROP, DRAGDROP_S_USEDEFAULTCURSORS, HWND,
        LPARAM, POINT, SIZE, S_OK, WPARAM,
    };
    use windows::Win32::Graphics::Gdi::{
        CreateDIBSection, DeleteObject, BITMAPINFO, BITMAPINFOHEADER, BI_RGB, DIB_RGB_COLORS,
    };
    use windows::Win32::System::Com::{CoCreateInstance, IDataObject, CLSCTX_INPROC_SERVER};
    use windows::Win32::System::Ole::{
        DoDragDrop, IDropSource, IDropSource_Impl, OleInitialize, OleUninitialize, DROPEFFECT,
        DROPEFFECT_COPY, DROPEFFECT_LINK, DROPEFFECT_MOVE,
    };
    use windows::Win32::System::SystemServices::MODIFIERKEYS_FLAGS;
    use windows::Win32::System::Threading::{AttachThreadInput, GetCurrentThreadId};
    use windows::Win32::UI::Input::KeyboardAndMouse::{
        GetAsyncKeyState, ReleaseCapture, VK_ESCAPE, VK_LBUTTON, VK_RBUTTON,
    };
    use windows::Win32::UI::Shell::Common::ITEMIDLIST;
    use windows::Win32::UI::Shell::{
        BHID_DataObject, CLSID_DragDropHelper, IDragSourceHelper, ILCreateFromPathW, ILFree,
        IShellItemArray, SHCreateShellItemArrayFromIDLists, SHDRAGIMAGE,
    };
    use windows::Win32::UI::WindowsAndMessaging::{
        GetForegroundWindow, GetSystemMetrics, GetWindowLongPtrW, GetWindowThreadProcessId,
        PostMessageW, SetForegroundWindow, SetWindowLongPtrW, GWL_EXSTYLE, SM_SWAPBUTTON,
        WM_CANCELMODE, WS_EX_NOACTIVATE,
    };

    fn primary_mouse_vk() -> i32 {
        // SAFETY: Stateless Win32 query.
        if unsafe { GetSystemMetrics(SM_SWAPBUTTON) } != 0 {
            VK_RBUTTON.0 as i32
        } else {
            VK_LBUTTON.0 as i32
        }
    }

    fn is_primary_mouse_down() -> bool {
        let vk = primary_mouse_vk();
        // SAFETY: Stateless hardware key probe.
        ((unsafe { GetAsyncKeyState(vk) } as u16) & 0x8000) != 0
    }

    struct OleGuard(bool);

    impl Drop for OleGuard {
        fn drop(&mut self) {
            if self.0 {
                // SAFETY: Pairs with our own `OleInitialize` call.
                unsafe {
                    OleUninitialize();
                }
            }
        }
    }

    struct ShelfDragGuard {
        hwnd_raw: isize,
        orig_ex_style: Option<isize>,
        is_shelf: bool,
    }

    impl Drop for ShelfDragGuard {
        fn drop(&mut self) {
            if !self.is_shelf || self.hwnd_raw == 0 {
                return;
            }
            set_shelf_outbound_dragging(self.hwnd_raw, false);
            set_shelf_allow_activate(self.hwnd_raw, false);
            if let Some(orig) = self.orig_ex_style {
                let hwnd = HWND(self.hwnd_raw as *mut c_void);
                // SAFETY: Restoring original WS_EX_NOACTIVATE style on our own shelf HWND.
                unsafe {
                    let _ = SetWindowLongPtrW(hwnd, GWL_EXSTYLE, orig);
                }
            }
        }
    }

    struct PidlList(Vec<*mut ITEMIDLIST>);

    impl Drop for PidlList {
        fn drop(&mut self) {
            for pidl in self.0.drain(..) {
                if !pidl.is_null() {
                    // SAFETY: Each pointer came from `ILCreateFromPathW`.
                    unsafe {
                        ILFree(Some(pidl.cast_const()));
                    }
                }
            }
        }
    }

    #[implement(IDropSource)]
    struct CharkleDropSource;

    impl IDropSource_Impl for CharkleDropSource_Impl {
        fn QueryContinueDrag(
            &self,
            fescapepressed: BOOL,
            _grfkeystate: MODIFIERKEYS_FLAGS,
        ) -> HRESULT {
            let esc = fescapepressed.as_bool()
                || ((unsafe { GetAsyncKeyState(VK_ESCAPE.0 as i32) } as u16) & 0x8000) != 0;
            if esc {
                return DRAGDROP_S_CANCEL;
            }
            // Query true physical mouse state via GetAsyncKeyState rather than `grfkeystate`
            // because WebView2's child process received the original WM_LBUTTONDOWN.
            if !is_primary_mouse_down() {
                return DRAGDROP_S_DROP;
            }
            S_OK
        }

        fn GiveFeedback(&self, _dweffect: DROPEFFECT) -> HRESULT {
            DRAGDROP_S_USEDEFAULTCURSORS
        }
    }

    /// Best-effort attaches a crisp translucent Shell drag thumbnail (`<= 112px`) to `data_object`
    /// so Windows renders a floating image preview next to the cursor while dragging.
    fn attach_drag_preview_bitmap(data_object: &IDataObject, preview_path: Option<&Path>) {
        let Some(path) = preview_path.filter(|p| p.is_file()) else {
            return;
        };
        let Ok(img) = image::open(path) else {
            return;
        };
        let thumb = img.thumbnail(112, 112).to_rgba8();
        let (w, h) = thumb.dimensions();
        if w == 0 || h == 0 {
            return;
        }

        let bmi = BITMAPINFO {
            bmiHeader: BITMAPINFOHEADER {
                biSize: std::mem::size_of::<BITMAPINFOHEADER>() as u32,
                biWidth: w as i32,
                biHeight: -(h as i32), // top-down DIB
                biPlanes: 1,
                biBitCount: 32,
                biCompression: BI_RGB.0,
                ..Default::default()
            },
            ..Default::default()
        };

        let mut bits_ptr: *mut c_void = std::ptr::null_mut();
        // SAFETY: Valid BITMAPINFO; `CreateDIBSection` allocates pixel buffer owned by `hbmp`.
        let Ok(hbmp) =
            (unsafe { CreateDIBSection(None, &bmi, DIB_RGB_COLORS, &mut bits_ptr, None, 0) })
        else {
            return;
        };
        if hbmp.is_invalid() {
            return;
        }
        if bits_ptr.is_null() {
            unsafe {
                let _ = DeleteObject(hbmp);
            }
            return;
        }

        // Convert RGBA -> premultiplied BGRA for Windows Shell alpha drag image
        let pixel_count = (w * h) as usize;
        // SAFETY: `bits_ptr` points to `w * h * 4` writable bytes allocated by `CreateDIBSection`.
        let dst = unsafe { std::slice::from_raw_parts_mut(bits_ptr as *mut u8, pixel_count * 4) };
        let src = thumb.as_raw();
        for i in 0..pixel_count {
            let r = src[i * 4] as u16;
            let g = src[i * 4 + 1] as u16;
            let b = src[i * 4 + 2] as u16;
            let a = src[i * 4 + 3] as u16;
            dst[i * 4] = ((b * a) / 255) as u8;
            dst[i * 4 + 1] = ((g * a) / 255) as u8;
            dst[i * 4 + 2] = ((r * a) / 255) as u8;
            dst[i * 4 + 3] = a as u8;
        }

        let helper: Result<IDragSourceHelper, _> =
            unsafe { CoCreateInstance(&CLSID_DragDropHelper, None, CLSCTX_INPROC_SERVER) };
        if let Ok(helper) = helper {
            let sdi = SHDRAGIMAGE {
                sizeDragImage: SIZE {
                    cx: w as i32,
                    cy: h as i32,
                },
                ptOffset: POINT {
                    x: (w / 2) as i32,
                    y: (h / 2) as i32,
                },
                hbmpDragImage: hbmp,
                crColorKey: COLORREF(0x00FF_00FF),
            };
            // On success, Windows Shell takes ownership of `hbmpDragImage`; on failure we free it.
            let ok = unsafe { helper.InitializeFromBitmap(&sdi, data_object) }.is_ok();
            if !ok {
                unsafe {
                    let _ = DeleteObject(hbmp);
                }
            }
        } else {
            unsafe {
                let _ = DeleteObject(hbmp);
            }
        }
    }

    pub fn run(
        paths: &[PathBuf],
        preview_image_path: Option<&Path>,
        source_hwnd: isize,
        is_shelf_window: bool,
    ) -> Result<DragOutOutcome, String> {
        // Never enter DoDragDrop if the user already released the primary mouse button!
        if !is_primary_mouse_down() {
            return Ok(DragOutOutcome::Cancelled);
        }

        // Ensure OLE is initialized on this STA thread (S_FALSE means already initialized, still paired).
        let init_hr = unsafe { OleInitialize(None) };
        let _ole_guard = OleGuard(init_hr.is_ok());

        let mut orig_ex_style = None;
        if source_hwnd != 0 {
            let hwnd = HWND(source_hwnd as *mut c_void);
            unsafe {
                if is_shelf_window {
                    let cur_ex = GetWindowLongPtrW(hwnd, GWL_EXSTYLE);
                    orig_ex_style = Some(cur_ex);
                    set_shelf_allow_activate(source_hwnd, true);
                    let _ = SetWindowLongPtrW(
                        hwnd,
                        GWL_EXSTYLE,
                        cur_ex & !(WS_EX_NOACTIVATE.0 as isize),
                    );
                }

                // Release any lingering mouse capture and briefly promote our UI thread to foreground
                // so `ole32!DoDragDrop`'s internal `SetCapture` succeeds globally across all monitors.
                // Detach `AttachThreadInput` BEFORE `DoDragDrop` so drop targets never deadlock!
                let fg = GetForegroundWindow();
                let cur_tid = GetCurrentThreadId();
                let fg_tid = if !fg.0.is_null() {
                    GetWindowThreadProcessId(fg, None)
                } else {
                    0
                };
                if fg_tid != 0 && fg_tid != cur_tid {
                    let attached = AttachThreadInput(cur_tid, fg_tid, true).as_bool();
                    let _ = SetForegroundWindow(hwnd);
                    let _ = ReleaseCapture();
                    if attached {
                        let _ = AttachThreadInput(cur_tid, fg_tid, false);
                    }
                } else {
                    let _ = ReleaseCapture();
                }

                // Inform WebView2 cleanly to cancel its internal pointer capture
                let _ = PostMessageW(hwnd, WM_CANCELMODE, WPARAM(0), LPARAM(0));
            }
        }

        let _shelf_guard = ShelfDragGuard {
            hwnd_raw: source_hwnd,
            orig_ex_style,
            is_shelf: is_shelf_window,
        };

        let mut pidls = PidlList(Vec::with_capacity(paths.len()));
        for path in paths {
            let clean = normalize_shell_path(path);
            let wide: Vec<u16> = clean
                .to_string_lossy()
                .encode_utf16()
                .chain(std::iter::once(0))
                .collect();
            // SAFETY: `wide` is NUL-terminated UTF-16; returned PIDL is owned by `PidlList`.
            let pidl = unsafe { ILCreateFromPathW(PCWSTR(wide.as_ptr())) };
            if !pidl.is_null() {
                pidls.0.push(pidl);
            }
        }

        if pidls.0.is_empty() {
            return Err("Failed to resolve Shell PIDLs for outbound drag".to_string());
        }

        let const_pidls: Vec<*const ITEMIDLIST> = pidls.0.iter().map(|p| p.cast_const()).collect();

        // SAFETY: `const_pidls` stays valid for the duration of `SHCreateShellItemArrayFromIDLists`.
        let item_array: IShellItemArray =
            unsafe { SHCreateShellItemArrayFromIDLists(&const_pidls) }
                .map_err(|e| format!("SHCreateShellItemArrayFromIDLists failed: {e}"))?;

        // Bind genuine Windows Shell IDataObject (CF_HDROP + Shell IDList Array)
        let data_object: IDataObject = unsafe { item_array.BindToHandler(None, &BHID_DataObject) }
            .map_err(|e| format!("BindToHandler(BHID_DataObject) failed: {e}"))?;

        // Attach floating translucent image preview thumbnail for native OS drag feedback
        attach_drag_preview_bitmap(
            &data_object,
            preview_image_path.or(paths.first().map(PathBuf::as_path)),
        );

        // Re-check mouse button right before entering DoDragDrop
        if !is_primary_mouse_down() {
            return Ok(DragOutOutcome::Cancelled);
        }

        // Make the shelf click-through while DoDragDrop runs so you can drop behind the shelf too
        if is_shelf_window && source_hwnd != 0 {
            set_shelf_outbound_dragging(source_hwnd, true);
        }

        let drop_source: IDropSource = CharkleDropSource.into();
        let mut performed = DROPEFFECT::default();

        // SAFETY: Running directly on the foreground UI STA thread with valid COM interfaces.
        let hr = unsafe {
            DoDragDrop(
                &data_object,
                &drop_source,
                DROPEFFECT_COPY | DROPEFFECT_LINK,
                &mut performed,
            )
        };

        if hr == DRAGDROP_S_DROP {
            if (performed.0 & DROPEFFECT_MOVE.0) != 0 {
                Ok(DragOutOutcome::Moved)
            } else if (performed.0 & DROPEFFECT_LINK.0) != 0 {
                Ok(DragOutOutcome::Linked)
            } else {
                Ok(DragOutOutcome::Copied)
            }
        } else {
            Ok(DragOutOutcome::Cancelled)
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn hdrop_buffer_encodes_dropfiles_header_and_double_null_utf16_paths() {
        let paths = vec![
            PathBuf::from(r"C:\Temp\a.png"),
            PathBuf::from(r"C:\Temp\海报.jpg"),
        ];
        let buf = build_hdrop_bytes(&paths);
        // Header offset == 20, fWide == 1
        assert_eq!(u32::from_le_bytes(buf[0..4].try_into().unwrap()), 20);
        assert_eq!(i32::from_le_bytes(buf[16..20].try_into().unwrap()), 1);
        // Ends with double UTF-16 NUL (4 zero bytes)
        assert_eq!(&buf[buf.len() - 4..], &[0, 0, 0, 0]);
        // Decode UTF-16 payload
        let units: Vec<u16> = buf[20..]
            .chunks_exact(2)
            .map(|c| u16::from_le_bytes([c[0], c[1]]))
            .collect();
        let parts: Vec<String> = units
            .split(|&u| u == 0)
            .filter(|s| !s.is_empty())
            .map(String::from_utf16_lossy)
            .collect();
        assert_eq!(parts, vec![r"C:\Temp\a.png", r"C:\Temp\海报.jpg"]);
    }
}
