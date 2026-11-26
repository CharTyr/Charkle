//! `DriveTransport` async trait and Windows-safe filesystem filename projection helpers.

use std::path::Path;

use async_trait::async_trait;

use crate::error::{CoreError, CoreResult};
use crate::models::sync::{DriveAccountInfo, DriveChangePage, RemoteDriveFile};

pub const DRIVE_ROOT_ID: &str = "root";

/// Validates a logical POSIX filename / folder name stored inside SQLite or `/.charkle/`.
pub fn validate_drive_name(name: &str) -> CoreResult<()> {
    if name.is_empty()
        || name == "."
        || name == ".."
        || name.contains('/')
        || name.chars().any(char::is_control)
    {
        return Err(CoreError::InvalidPayload(format!(
            "Invalid Drive file name: `{name}`"
        )));
    }
    Ok(())
}

/// Deterministic Windows filename sanitization applied ONLY during local disk projection
/// (`LocalFolderTransport` / `MountedVolumeTransport`), preserving logical titles/names in metadata.
///
/// Handles:
/// - Illegal characters: `< > : " / \ | ? *` and ASCII control characters `0x00..=0x1F`
/// - Trailing dots and spaces (forbidden on NTFS/FAT32)
/// - Windows reserved device names: `CON`, `PRN`, `AUX`, `NUL`, `COM1`..`COM9`, `LPT1`..`LPT9`
pub fn sanitize_windows_filename(name: &str) -> String {
    if name == ".charkle" {
        return ".charkle".to_string();
    }
    let mut cleaned: String = name
        .chars()
        .map(|ch| {
            if matches!(ch, '<' | '>' | ':' | '"' | '/' | '\\' | '|' | '?' | '*') || ch.is_control()
            {
                '_'
            } else {
                ch
            }
        })
        .collect();

    // Trim trailing spaces and dots (Windows silently strips them, causing path mismatches)
    while cleaned.ends_with([' ', '.']) {
        cleaned.pop();
    }
    let trimmed = cleaned.trim_start();
    let mut candidate = if trimmed.is_empty() || trimmed == "." || trimmed == ".." {
        "_file".to_string()
    } else {
        trimmed.to_string()
    };

    // Check reserved DOS/Win32 device names (match stem before first dot, case-insensitive)
    let stem = candidate.split('.').next().unwrap_or("");
    if is_windows_reserved_device_name(stem) {
        candidate = format!("_{candidate}");
    }

    candidate
}

fn is_windows_reserved_device_name(stem: &str) -> bool {
    let upper = stem.to_ascii_uppercase();
    matches!(
        upper.as_str(),
        "CON"
            | "PRN"
            | "AUX"
            | "NUL"
            | "COM1"
            | "COM2"
            | "COM3"
            | "COM4"
            | "COM5"
            | "COM6"
            | "COM7"
            | "COM8"
            | "COM9"
            | "LPT1"
            | "LPT2"
            | "LPT3"
            | "LPT4"
            | "LPT5"
            | "LPT6"
            | "LPT7"
            | "LPT8"
            | "LPT9"
    )
}

/// Primary storage/sync transport abstraction implemented by all 5 backends.
#[async_trait]
pub trait DriveTransport: Send + Sync {
    fn display_name(&self) -> &str;

    /// True for mounted drive/rclone transports that use local `mounted-` IDs and lower concurrency.
    fn is_mounted_volume(&self) -> bool {
        false
    }

    /// True for iCloud Drive filesystem-coordinated transports using `icloud-path:` IDs.
    fn is_icloud_drive(&self) -> bool {
        false
    }

    /// True for path-addressed transports (WebDAV, MountedVolume, LocalFolder, iCloudDrive)
    /// where renaming a folder changes descendant path IDs.
    fn is_path_based_transport(&self) -> bool {
        false
    }

    /// Maximum safe parallel I/O concurrency for this transport.
    fn concurrency_limit(&self, direct_default: usize) -> usize {
        if self.is_mounted_volume() || self.is_icloud_drive() {
            2
        } else {
            direct_default.max(1)
        }
    }

    /// Returns true if `id` is syntactically compatible with this transport's remote ID space.
    /// Prevents path-based IDs from `LocalFolderTransport` / `WebDAVTransport` (containing `/`),
    /// `icloud-path:` IDs, or `mounted-path:` IDs from being sent to opaque-ID APIs such as Google Drive v3.
    fn accepts_remote_id(&self, id: &str) -> bool {
        !id.is_empty() && !id.starts_with("mounted-") && !id.starts_with("icloud-path:")
    }

    async fn account_info(&self) -> CoreResult<DriveAccountInfo>;
    async fn fetch_start_page_token(&self) -> CoreResult<String>;
    async fn list_changes(&self, page_token: &str) -> CoreResult<DriveChangePage>;
    async fn find_or_create_folder(
        &self,
        name: &str,
        parent_id: &str,
    ) -> CoreResult<RemoteDriveFile>;
    async fn list_files(&self, folder_id: &str) -> CoreResult<Vec<RemoteDriveFile>>;
    async fn download_data(&self, file_id: &str) -> CoreResult<Vec<u8>>;
    async fn download_file(&self, file_id: &str, destination: &Path) -> CoreResult<()>;

    /// Optional fast server-side thumbnail fetch (e.g. Google Drive `thumbnailLink`) used when
    /// `.charkle/thumbnails/<uuid>.jpg` is absent, avoiding multi-MB original downloads.
    async fn download_thumbnail_data(
        &self,
        _file: &RemoteDriveFile,
        _max_pixel_size: u32,
    ) -> CoreResult<Option<Vec<u8>>> {
        Ok(None)
    }

    async fn download_remote_file(
        &self,
        file: &RemoteDriveFile,
        destination: &Path,
    ) -> CoreResult<()> {
        self.download_file(&file.id, destination).await
    }

    async fn upload_data(
        &self,
        data: &[u8],
        name: &str,
        mime_type: &str,
        parent_id: &str,
        existing_file_id: Option<&str>,
    ) -> CoreResult<RemoteDriveFile>;

    async fn upload_file(
        &self,
        local_path: &Path,
        name: &str,
        mime_type: &str,
        parent_id: &str,
        existing_file_id: Option<&str>,
    ) -> CoreResult<RemoteDriveFile>;

    async fn move_file(
        &self,
        file_id: &str,
        from_parent_id: Option<&str>,
        to_parent_id: &str,
        new_name: Option<&str>,
    ) -> CoreResult<RemoteDriveFile>;

    async fn trash_file(&self, file_id: &str) -> CoreResult<()>;

    async fn resolve_folder(&self, _id: &str) -> CoreResult<RemoteDriveFile> {
        Err(CoreError::NotConfigured(format!(
            "{} does not support direct shared folder ID resolution.",
            self.display_name()
        )))
    }

    async fn list_shared_folders(&self) -> CoreResult<Vec<RemoteDriveFile>> {
        Ok(Vec::new())
    }
}
