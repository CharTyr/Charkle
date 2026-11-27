//! OS-level abstraction seams keeping `charkle-core` strictly platform-agnostic.
//!
//! Concrete Win32 / WinRT implementations live in `charkle-platform-win` (M3).

use std::collections::HashMap;
use std::path::Path;
use std::sync::RwLock;

use async_trait::async_trait;

/// Secure credential store seam (Windows Credential Manager / DPAPI in M3).
#[async_trait]
pub trait SecretVault: Send + Sync {
    async fn get_secret(&self, key: &str) -> Result<Option<String>, String>;
    async fn set_secret(&self, key: &str, value: &str) -> Result<(), String>;
    async fn delete_secret(&self, key: &str) -> Result<(), String>;
}

/// Offline OCR seam (WinRT `Windows.Media.Ocr.OcrEngine` in M3).
#[async_trait]
pub trait NativeOcrProvider: Send + Sync {
    async fn recognize_text(&self, image_bytes: &[u8]) -> Result<Option<String>, String>;
}

/// System shell thumbnail seam (Win32 `IShellItemImageFactory` in M3).
#[async_trait]
pub trait ShellThumbnailProvider: Send + Sync {
    async fn generate_thumbnail_png(
        &self,
        file_path: &Path,
        max_side: u32,
    ) -> Result<Option<Vec<u8>>, String>;
}

/// Mounted drive / volume health seam (`GetDriveTypeW` / `GetVolumeInformationW` in M3).
pub trait VolumeMountInspector: Send + Sync {
    fn is_mount_available(&self, path: &Path) -> bool;
}

/// Captured offscreen webpage screenshot + DOM metadata (Tier 2 / Layer 5 SPA web bookmark fallback).
#[derive(Debug, Clone, Default)]
pub struct WebPageSnapshot {
    pub png_bytes: Vec<u8>,
    pub title: Option<String>,
    pub description: Option<String>,
    pub site_name: Option<String>,
    pub author_name: Option<String>,
    pub hero_image_urls: Vec<String>,
    pub video_urls: Vec<String>,
    pub final_url: Option<String>,
}

/// Offscreen browser webpage snapshot seam (ephemeral hidden WebView2 in `src-tauri`).
#[async_trait]
pub trait WebPageSnapshotProvider: Send + Sync {
    async fn capture_snapshot(&self, url: &str) -> Option<WebPageSnapshot>;
}

/// No-op webpage snapshot provider used in headless tests and CLI.
#[derive(Debug, Default, Clone, Copy)]
pub struct NoopWebPageSnapshotProvider;

#[async_trait]
impl WebPageSnapshotProvider for NoopWebPageSnapshotProvider {
    async fn capture_snapshot(&self, _url: &str) -> Option<WebPageSnapshot> {
        None
    }
}

/// In-memory `SecretVault` default for tests and headless usage.
#[derive(Debug, Default)]
pub struct InMemorySecretVault {
    entries: RwLock<HashMap<String, String>>,
}

impl InMemorySecretVault {
    pub fn new() -> Self {
        Self::default()
    }
}

#[async_trait]
impl SecretVault for InMemorySecretVault {
    async fn get_secret(&self, key: &str) -> Result<Option<String>, String> {
        let guard = self
            .entries
            .read()
            .map_err(|_| "SecretVault lock poisoned".to_string())?;
        Ok(guard.get(key).cloned())
    }

    async fn set_secret(&self, key: &str, value: &str) -> Result<(), String> {
        let mut guard = self
            .entries
            .write()
            .map_err(|_| "SecretVault lock poisoned".to_string())?;
        guard.insert(key.to_string(), value.to_string());
        Ok(())
    }

    async fn delete_secret(&self, key: &str) -> Result<(), String> {
        let mut guard = self
            .entries
            .write()
            .map_err(|_| "SecretVault lock poisoned".to_string())?;
        guard.remove(key);
        Ok(())
    }
}

/// No-op OCR provider used until WinRT OCR is wired in M3.
#[derive(Debug, Default, Clone, Copy)]
pub struct NoopOcrProvider;

#[async_trait]
impl NativeOcrProvider for NoopOcrProvider {
    async fn recognize_text(&self, _image_bytes: &[u8]) -> Result<Option<String>, String> {
        Ok(None)
    }
}

/// No-op Shell thumbnail provider used until `IShellItemImageFactory` is wired in M3.
#[derive(Debug, Default, Clone, Copy)]
pub struct NoopShellThumbnailProvider;

#[async_trait]
impl ShellThumbnailProvider for NoopShellThumbnailProvider {
    async fn generate_thumbnail_png(
        &self,
        _file_path: &Path,
        _max_side: u32,
    ) -> Result<Option<Vec<u8>>, String> {
        Ok(None)
    }
}

/// Default filesystem mount inspector checking directory existence and readability.
#[derive(Debug, Default, Clone, Copy)]
pub struct BasicVolumeMountInspector;

impl VolumeMountInspector for BasicVolumeMountInspector {
    fn is_mount_available(&self, path: &Path) -> bool {
        path.is_dir() && std::fs::read_dir(path).is_ok()
    }
}
