//! Windows native platform bridge (`charkle-platform-win`).
//!
//! M2 adds real Win32 windowing chrome (Windows 11 22H2+ Mica backdrop, Win10 fallback,
//! immersive dark mode, and custom titlebar Snap Layouts via `WM_NCHITTEST` `HTMAXBUTTON`).
//! Remaining M3 seams (DPAPI vault, WinRT OCR, Shell thumbnails, Drop Shelf, OLE drag-out,
//! DXGI capture) stay behind trait stubs until M3.

pub mod windowing;

use std::path::Path;

use async_trait::async_trait;
use charkle_core::traits::{
    BasicVolumeMountInspector, InMemorySecretVault, NativeOcrProvider, SecretVault,
    ShellThumbnailProvider, VolumeMountInspector,
};

/// M1 stub for Windows Credential Manager / DPAPI secret vault (concrete in M3).
#[derive(Debug, Default)]
pub struct WinSecretVaultStub {
    inner: InMemorySecretVault,
}

impl WinSecretVaultStub {
    pub fn new() -> Self {
        Self::default()
    }
}

#[async_trait]
impl SecretVault for WinSecretVaultStub {
    async fn get_secret(&self, key: &str) -> Result<Option<String>, String> {
        self.inner.get_secret(key).await
    }

    async fn set_secret(&self, key: &str, value: &str) -> Result<(), String> {
        self.inner.set_secret(key, value).await
    }

    async fn delete_secret(&self, key: &str) -> Result<(), String> {
        self.inner.delete_secret(key).await
    }
}

/// M1 stub for WinRT `Windows.Media.Ocr.OcrEngine` (concrete in M3).
#[derive(Debug, Default, Clone, Copy)]
pub struct WinOcrProviderStub;

#[async_trait]
impl NativeOcrProvider for WinOcrProviderStub {
    async fn recognize_text(&self, _image_bytes: &[u8]) -> Result<Option<String>, String> {
        Ok(None)
    }
}

/// M1 stub for Win32 `IShellItemImageFactory` thumbnails (concrete in M3).
#[derive(Debug, Default, Clone, Copy)]
pub struct WinShellThumbnailStub;

#[async_trait]
impl ShellThumbnailProvider for WinShellThumbnailStub {
    async fn generate_thumbnail_png(
        &self,
        _file_path: &Path,
        _max_side: u32,
    ) -> Result<Option<Vec<u8>>, String> {
        Ok(None)
    }
}

/// M1 stub for Win32 `GetDriveTypeW`/`GetVolumeInformationW` mount checks (concrete in M3).
#[derive(Debug, Default, Clone, Copy)]
pub struct WinVolumeMountInspectorStub {
    inner: BasicVolumeMountInspector,
}

impl VolumeMountInspector for WinVolumeMountInspectorStub {
    fn is_mount_available(&self, path: &Path) -> bool {
        self.inner.is_mount_available(path)
    }
}
