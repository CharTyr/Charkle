//! Windows native platform bridge (`charkle-platform-win`).
//!
//! Provides concrete Windows 10/11 implementations of every `charkle-core` OS seam plus
//! desktop UX subsystems:
//! - `windowing`: Win11 22H2+ Mica backdrop, Win10 solid fallback, Snap Layouts (`HTMAXBUTTON`)
//! - `vault`: Windows Credential Manager + DPAPI encrypted `SecretVault`
//! - `ocr`: Offline WinRT `Windows.Media.Ocr.OcrEngine` (`NativeOcrProvider`)
//! - `shell_thumb`: Dedicated STA COM `IShellItemImageFactory` thumbnails (`ShellThumbnailProvider`)
//! - `mount`: Win32 `GetDriveTypeW` / `GetVolumeInformationW` mount checks + `gdirect.exe` detection
//! - `shelf_win`: Top-Edge Drop Shelf fixed transparent non-activating window + click-through
//! - `drag_out`: Native Win32 OLE `DoDragDrop` (`CF_HDROP` + Shell `IDataObject`)
//! - `capture`: Multi-DPI DXGI Desktop Duplication + GDI `BitBlt` virtual desktop capture
//! - `clipboard`: Native clipboard reader (`CF_HDROP`/`CF_DIB`/`CF_UNICODETEXT`) + `AddClipboardFormatListener`

pub mod capture;
pub mod clipboard;
pub mod drag_out;
pub mod mount;
pub mod ocr;
pub mod shelf_win;
pub mod shell_thumb;
pub mod vault;
pub mod wake;
pub mod windowing;

pub use mount::WinVolumeMountInspector;
pub use ocr::{probe_ocr_diagnostics, OcrDiagnostics, WinRtOcrProvider};
pub use shell_thumb::WinShellThumbnailProvider;
pub use vault::WinCredentialVault;

// Legacy M1 stub aliases retained as type aliases for backwards compatibility with any caller.
pub type WinSecretVaultStub = WinCredentialVault;
pub type WinOcrProviderStub = WinRtOcrProvider;
pub type WinShellThumbnailStub = WinShellThumbnailProvider;
pub type WinVolumeMountInspectorStub = WinVolumeMountInspector;
