//! Native Windows OLE outbound file drag (`DoDragDrop` + Shell `IDataObject` / `CF_HDROP`).
//!
//! Enables dragging one or multiple local asset files directly out of Charkle's Gallery,
//! Inspector, or Full-Waterfall Shelf into Windows Explorer, Figma Desktop, Photoshop,
//! Premiere, or any OLE drop target.

#![allow(unsafe_code)]

use std::path::PathBuf;

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

/// Initiates a synchronous Win32 OLE `DoDragDrop` operation on a dedicated STA thread so
/// external applications (Explorer, Figma Desktop, Photoshop, etc.) receive genuine file drops.
pub async fn start_outbound_file_drag(paths: Vec<PathBuf>) -> Result<DragOutOutcome, String> {
    let existing: Vec<PathBuf> = paths.into_iter().filter(|p| p.is_file()).collect();
    if existing.is_empty() {
        return Err("No cached local files available for outbound drag".to_string());
    }

    let (tx, rx) = tokio::sync::oneshot::channel();
    std::thread::Builder::new()
        .name("charkle-ole-drag-out".to_string())
        .spawn(move || {
            let res = run_ole_drag_on_sta(&existing);
            let _ = tx.send(res);
        })
        .map_err(|e| format!("Failed to spawn OLE drag thread: {e}"))?;

    rx.await
        .map_err(|_| "OLE drag thread terminated unexpectedly".to_string())?
}

#[cfg(target_os = "windows")]
fn normalize_shell_path(path: &PathBuf) -> PathBuf {
    let abs = std::fs::canonicalize(path).unwrap_or_else(|_| path.clone());
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
    use windows::core::{implement, HRESULT, PCWSTR};
    use windows::Win32::Foundation::{
        BOOL, DRAGDROP_S_CANCEL, DRAGDROP_S_DROP, DRAGDROP_S_USEDEFAULTCURSORS, S_OK,
    };
    use windows::Win32::System::Com::IDataObject;
    use windows::Win32::System::Ole::{
        DoDragDrop, IDropSource, IDropSource_Impl, OleInitialize, OleUninitialize, DROPEFFECT,
        DROPEFFECT_COPY, DROPEFFECT_LINK, DROPEFFECT_MOVE,
    };
    use windows::Win32::System::SystemServices::{MK_LBUTTON, MODIFIERKEYS_FLAGS};
    use windows::Win32::UI::Shell::Common::ITEMIDLIST;
    use windows::Win32::UI::Shell::{
        BHID_DataObject, ILCreateFromPathW, ILFree, IShellItemArray,
        SHCreateShellItemArrayFromIDLists,
    };

    struct OleGuard(bool);

    impl Drop for OleGuard {
        fn drop(&mut self) {
            if self.0 {
                // SAFETY: Pairs with successful `OleInitialize` on this STA thread.
                unsafe {
                    OleUninitialize();
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
            grfkeystate: MODIFIERKEYS_FLAGS,
        ) -> HRESULT {
            if fescapepressed.as_bool() {
                return DRAGDROP_S_CANCEL;
            }
            if (grfkeystate.0 & MK_LBUTTON.0) == 0 {
                return DRAGDROP_S_DROP;
            }
            S_OK
        }

        fn GiveFeedback(&self, _dweffect: DROPEFFECT) -> HRESULT {
            DRAGDROP_S_USEDEFAULTCURSORS
        }
    }

    pub fn run(paths: &[PathBuf]) -> Result<DragOutOutcome, String> {
        // SAFETY: Dedicated STA thread initializes OLE once.
        let init_hr = unsafe { OleInitialize(None) };
        let _ole_guard = OleGuard(init_hr.is_ok());

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

        // Bind genuine Windows Shell IDataObject (provides CF_HDROP + Shell thumbnail preview)
        // SAFETY: Valid COM call on this STA thread.
        let data_object: IDataObject = unsafe { item_array.BindToHandler(None, &BHID_DataObject) }
            .map_err(|e| format!("BindToHandler(BHID_DataObject) failed: {e}"))?;

        let drop_source: IDropSource = CharkleDropSource.into();
        let mut performed = DROPEFFECT::default();

        // SAFETY: All COM interfaces were created on this STA thread with OLE initialized.
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

#[cfg(target_os = "windows")]
fn run_ole_drag_on_sta(paths: &[PathBuf]) -> Result<DragOutOutcome, String> {
    win_ole::run(paths)
}

#[cfg(not(target_os = "windows"))]
fn run_ole_drag_on_sta(_paths: &[PathBuf]) -> Result<DragOutOutcome, String> {
    Ok(DragOutOutcome::Cancelled)
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
