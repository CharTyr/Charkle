//! Filesystem-backed `LocalFolderTransport` and `MountedVolumeTransport` (behind `VolumeMountInspector`).
//!
//! Enforces deterministic Windows illegal-character & reserved-name sanitization on disk projection
//! while keeping POSIX `/` separators inside logical sync IDs and metadata.

use std::collections::{BTreeMap, HashSet};
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::Arc;

use async_trait::async_trait;
use base64::engine::general_purpose::STANDARD as BASE64_STD;
use base64::Engine;
use chrono::{DateTime, Utc};
use uuid::Uuid;

use crate::error::{CoreError, CoreResult};
use crate::media::MediaPipeline;
use crate::models::sync::{DriveAccountInfo, DriveChange, DriveChangePage, RemoteDriveFile};
use crate::sync::transport::{
    sanitize_windows_filename, validate_drive_name, DriveTransport, DRIVE_ROOT_ID,
};
use crate::traits::{BasicVolumeMountInspector, VolumeMountInspector};

pub const MOUNTED_PATH_ID_PREFIX: &str = "mounted-path:";

/// Shared filesystem transport engine backing both `LocalFolderTransport` and `MountedVolumeTransport`.
struct FsTransportCore {
    root_dir: PathBuf,
    display_name: String,
    mounted_mode: bool,
    inspector: Arc<dyn VolumeMountInspector>,
}

impl FsTransportCore {
    fn ensure_available(&self) -> CoreResult<()> {
        if self.mounted_mode {
            if !self.inspector.is_mount_available(&self.root_dir) {
                return Err(CoreError::MountPathUnavailable(format!(
                    "Mounted path unavailable: {}",
                    self.root_dir.display()
                )));
            }
        } else {
            fs::create_dir_all(&self.root_dir)?;
        }
        Ok(())
    }

    fn make_id(&self, rel_posix: &str) -> String {
        let clean = rel_posix.trim_matches('/');
        if clean.is_empty() {
            return DRIVE_ROOT_ID.to_string();
        }
        if self.mounted_mode {
            format!("{MOUNTED_PATH_ID_PREFIX}{clean}")
        } else {
            clean.to_string()
        }
    }

    fn strip_prefix<'a>(&self, id: &'a str) -> &'a str {
        if id == DRIVE_ROOT_ID {
            return "";
        }
        id.strip_prefix(MOUNTED_PATH_ID_PREFIX)
            .unwrap_or(id)
            .trim_matches('/')
    }

    fn resolve_path(&self, id: &str) -> CoreResult<PathBuf> {
        let rel = self.strip_prefix(id);
        let mut path = self.root_dir.clone();
        if !rel.is_empty() {
            for seg in rel.split('/') {
                if seg.is_empty()
                    || seg == "."
                    || seg == ".."
                    || seg.contains('\\')
                    || seg.contains(':')
                    || seg.contains('\0')
                {
                    return Err(CoreError::InvalidPayload(format!(
                        "Unsafe relative path segment in `{id}`"
                    )));
                }
                path.push(seg);
            }
        }
        Ok(path)
    }

    fn join_rel(&self, parent_id: &str, disk_name: &str) -> String {
        let parent_rel = self.strip_prefix(parent_id);
        if parent_rel.is_empty() {
            disk_name.to_string()
        } else {
            format!("{parent_rel}/{disk_name}")
        }
    }

    fn build_remote_file(
        &self,
        path: &Path,
        parent_id: &str,
        disk_name: &str,
    ) -> CoreResult<RemoteDriveFile> {
        let meta = fs::metadata(path)?;
        let is_dir = meta.is_dir();
        let rel = self.join_rel(parent_id, disk_name);
        let id = self.make_id(&rel);
        let modified: Option<DateTime<Utc>> = meta.modified().ok().map(DateTime::<Utc>::from);
        let mime = if is_dir {
            RemoteDriveFile::FOLDER_MIME_TYPE.to_string()
        } else {
            MediaPipeline::mime_type(disk_name).to_string()
        };
        Ok(RemoteDriveFile {
            id,
            name: disk_name.to_string(),
            mime_type: mime,
            size: (!is_dir).then_some(meta.len() as i64),
            modified_time: modified,
            md5_checksum: None,
            parents: vec![parent_id.to_string()],
            trashed: false,
            web_view_link: None,
            thumbnail_link: None,
        })
    }

    fn list_dir(&self, folder_id: &str) -> CoreResult<Vec<RemoteDriveFile>> {
        self.ensure_available()?;
        let dir = self.resolve_path(folder_id)?;
        if !dir.is_dir() {
            return Ok(Vec::new());
        }
        let mut out = Vec::new();
        for entry in fs::read_dir(&dir)?.flatten() {
            let name = entry.file_name().to_string_lossy().into_owned();
            if name == ".DS_Store" || name.starts_with(".charkle-write-") {
                continue;
            }
            let path = entry.path();
            if let Ok(file) = self.build_remote_file(&path, folder_id, &name) {
                out.push(file);
            }
        }
        out.sort_by(|a, b| a.name.cmp(&b.name).then_with(|| a.id.cmp(&b.id)));
        Ok(out)
    }

    fn snapshot(&self) -> CoreResult<BTreeMap<String, RemoteDriveFile>> {
        self.ensure_available()?;
        let mut map = BTreeMap::new();
        let mut queue = vec![DRIVE_ROOT_ID.to_string()];
        let mut visited = HashSet::new();
        while let Some(folder_id) = queue.pop() {
            if !visited.insert(folder_id.clone()) {
                continue;
            }
            for item in self.list_dir(&folder_id)? {
                let is_folder = item.is_folder();
                let should_recurse = is_folder && !item.name.starts_with('.');
                let item_id = item.id.clone();
                map.insert(item_id.clone(), item);
                if should_recurse {
                    queue.push(item_id);
                }
            }
        }
        Ok(map)
    }
}

/// Pure local folder storage transport (`DriveTransportMode::LocalOnly` / local sync target).
pub struct LocalFolderTransport {
    core: FsTransportCore,
}

impl LocalFolderTransport {
    pub fn new(root_dir: impl Into<PathBuf>) -> Self {
        Self {
            core: FsTransportCore {
                root_dir: root_dir.into(),
                display_name: "Local Folder".to_string(),
                mounted_mode: false,
                inspector: Arc::new(BasicVolumeMountInspector),
            },
        }
    }

    pub fn root_dir(&self) -> &Path {
        &self.core.root_dir
    }
}

/// Mounted cloud drive transport (`G:\`, WinFsp, `rclone`, `gdirect.exe`) guarded by `VolumeMountInspector`.
pub struct MountedVolumeTransport {
    core: FsTransportCore,
}

impl MountedVolumeTransport {
    pub fn new(root_dir: impl Into<PathBuf>, inspector: Arc<dyn VolumeMountInspector>) -> Self {
        Self {
            core: FsTransportCore {
                root_dir: root_dir.into(),
                display_name: "Mounted Drive".to_string(),
                mounted_mode: true,
                inspector,
            },
        }
    }

    pub fn root_dir(&self) -> &Path {
        &self.core.root_dir
    }
}

#[async_trait]
impl DriveTransport for LocalFolderTransport {
    fn display_name(&self) -> &str {
        &self.core.display_name
    }

    async fn account_info(&self) -> CoreResult<DriveAccountInfo> {
        self.core.ensure_available()?;
        let label = self.core.root_dir.to_string_lossy().into_owned();
        Ok(DriveAccountInfo {
            email: label.clone(),
            display_name: Some(label),
            storage_used_bytes: None,
            storage_limit_bytes: None,
            source: self.display_name().to_string(),
        })
    }

    async fn fetch_start_page_token(&self) -> CoreResult<String> {
        let snap = self.core.snapshot()?;
        Ok(BASE64_STD.encode(serde_json::to_vec(&snap)?))
    }

    async fn list_changes(&self, page_token: &str) -> CoreResult<DriveChangePage> {
        let prev_bytes = BASE64_STD.decode(page_token).map_err(|_| CoreError::Http {
            status_code: 410,
            message: "Expired local folder change token".to_string(),
        })?;
        let previous: BTreeMap<String, RemoteDriveFile> = serde_json::from_slice(&prev_bytes)
            .map_err(|_| CoreError::Http {
                status_code: 410,
                message: "Corrupt local folder change token".to_string(),
            })?;
        let current = self.core.snapshot()?;
        let mut keys: HashSet<&String> = previous.keys().collect();
        keys.extend(current.keys());
        let mut sorted_keys: Vec<&String> = keys.into_iter().collect();
        sorted_keys.sort();

        let mut changes = Vec::new();
        for k in sorted_keys {
            if previous.get(k) != current.get(k) {
                changes.push(DriveChange {
                    file_id: k.clone(),
                    removed: !current.contains_key(k),
                    file: current.get(k).cloned(),
                });
            }
        }
        let next_token = BASE64_STD.encode(serde_json::to_vec(&current)?);
        Ok(DriveChangePage {
            changes,
            next_page_token: None,
            new_start_page_token: Some(next_token),
        })
    }

    async fn find_or_create_folder(
        &self,
        name: &str,
        parent_id: &str,
    ) -> CoreResult<RemoteDriveFile> {
        validate_drive_name(name)?;
        self.core.ensure_available()?;
        let disk_name = sanitize_windows_filename(name);
        let parent_path = self.core.resolve_path(parent_id)?;
        let target = parent_path.join(&disk_name);
        fs::create_dir_all(&target)?;
        self.core.build_remote_file(&target, parent_id, &disk_name)
    }

    async fn list_files(&self, folder_id: &str) -> CoreResult<Vec<RemoteDriveFile>> {
        self.core.list_dir(folder_id)
    }

    async fn download_data(&self, file_id: &str) -> CoreResult<Vec<u8>> {
        self.core.ensure_available()?;
        let path = self.core.resolve_path(file_id)?;
        if !path.is_file() {
            return Err(CoreError::NotFound(file_id.to_string()));
        }
        Ok(fs::read(path)?)
    }

    async fn download_file(&self, file_id: &str, destination: &Path) -> CoreResult<()> {
        self.core.ensure_available()?;
        let src = self.core.resolve_path(file_id)?;
        if !src.is_file() {
            return Err(CoreError::NotFound(file_id.to_string()));
        }
        if let Some(parent) = destination.parent() {
            fs::create_dir_all(parent)?;
        }
        fs::copy(src, destination)?;
        Ok(())
    }

    async fn upload_data(
        &self,
        data: &[u8],
        name: &str,
        _mime_type: &str,
        parent_id: &str,
        existing_file_id: Option<&str>,
    ) -> CoreResult<RemoteDriveFile> {
        validate_drive_name(name)?;
        self.core.ensure_available()?;
        let disk_name = sanitize_windows_filename(name);
        let target = match existing_file_id {
            Some(eid) => self.core.resolve_path(eid)?,
            None => self.core.resolve_path(parent_id)?.join(&disk_name),
        };
        if let Some(parent) = target.parent() {
            fs::create_dir_all(parent)?;
        }
        let tmp = target.with_file_name(format!(".charkle-write-{}", Uuid::new_v4().simple()));
        fs::write(&tmp, data)?;
        if fs::rename(&tmp, &target).is_err() {
            if target.exists() {
                let _ = fs::remove_file(&target);
            }
            if let Err(err) = fs::rename(&tmp, &target) {
                let _ = fs::remove_file(&tmp);
                return Err(err.into());
            }
        }
        let actual_name = target
            .file_name()
            .and_then(|n| n.to_str())
            .unwrap_or(&disk_name);
        self.core.build_remote_file(&target, parent_id, actual_name)
    }

    async fn upload_file(
        &self,
        local_path: &Path,
        name: &str,
        mime_type: &str,
        parent_id: &str,
        existing_file_id: Option<&str>,
    ) -> CoreResult<RemoteDriveFile> {
        let data = fs::read(local_path)?;
        self.upload_data(&data, name, mime_type, parent_id, existing_file_id)
            .await
    }

    async fn move_file(
        &self,
        file_id: &str,
        _from_parent_id: Option<&str>,
        to_parent_id: &str,
        new_name: Option<&str>,
    ) -> CoreResult<RemoteDriveFile> {
        self.core.ensure_available()?;
        let src = self.core.resolve_path(file_id)?;
        if !src.exists() {
            return Err(CoreError::NotFound(file_id.to_string()));
        }
        let current_name = src
            .file_name()
            .and_then(|n| n.to_str())
            .unwrap_or("item")
            .to_string();
        let disk_name = match new_name {
            Some(n) => {
                validate_drive_name(n)?;
                sanitize_windows_filename(n)
            }
            None => current_name,
        };
        let dst_parent = self.core.resolve_path(to_parent_id)?;
        fs::create_dir_all(&dst_parent)?;
        let dst = dst_parent.join(&disk_name);
        if src != dst {
            fs::rename(&src, &dst)?;
        }
        self.core.build_remote_file(&dst, to_parent_id, &disk_name)
    }

    async fn trash_file(&self, file_id: &str) -> CoreResult<()> {
        self.core.ensure_available()?;
        let path = self.core.resolve_path(file_id)?;
        if !path.exists() {
            return Ok(());
        }
        if path.is_dir() {
            fs::remove_dir_all(path)?;
        } else {
            fs::remove_file(path)?;
        }
        Ok(())
    }
}

#[async_trait]
impl DriveTransport for MountedVolumeTransport {
    fn display_name(&self) -> &str {
        &self.core.display_name
    }

    fn is_mounted_volume(&self) -> bool {
        true
    }

    fn accepts_remote_id(&self, id: &str) -> bool {
        id == DRIVE_ROOT_ID || id.starts_with(MOUNTED_PATH_ID_PREFIX)
    }

    async fn account_info(&self) -> CoreResult<DriveAccountInfo> {
        self.core.ensure_available()?;
        let label = self.core.root_dir.to_string_lossy().into_owned();
        Ok(DriveAccountInfo {
            email: label.clone(),
            display_name: Some(label),
            storage_used_bytes: None,
            storage_limit_bytes: None,
            source: self.display_name().to_string(),
        })
    }

    async fn fetch_start_page_token(&self) -> CoreResult<String> {
        let snap = self.core.snapshot()?;
        Ok(BASE64_STD.encode(serde_json::to_vec(&snap)?))
    }

    async fn list_changes(&self, page_token: &str) -> CoreResult<DriveChangePage> {
        let prev_bytes = BASE64_STD.decode(page_token).map_err(|_| CoreError::Http {
            status_code: 410,
            message: "Expired mounted volume change token".to_string(),
        })?;
        let previous: BTreeMap<String, RemoteDriveFile> = serde_json::from_slice(&prev_bytes)
            .map_err(|_| CoreError::Http {
                status_code: 410,
                message: "Corrupt mounted volume change token".to_string(),
            })?;
        let current = self.core.snapshot()?;
        let mut keys: HashSet<&String> = previous.keys().collect();
        keys.extend(current.keys());
        let mut sorted_keys: Vec<&String> = keys.into_iter().collect();
        sorted_keys.sort();

        let mut changes = Vec::new();
        for k in sorted_keys {
            if previous.get(k) != current.get(k) {
                changes.push(DriveChange {
                    file_id: k.clone(),
                    removed: !current.contains_key(k),
                    file: current.get(k).cloned(),
                });
            }
        }
        let next_token = BASE64_STD.encode(serde_json::to_vec(&current)?);
        Ok(DriveChangePage {
            changes,
            next_page_token: None,
            new_start_page_token: Some(next_token),
        })
    }

    async fn find_or_create_folder(
        &self,
        name: &str,
        parent_id: &str,
    ) -> CoreResult<RemoteDriveFile> {
        validate_drive_name(name)?;
        self.core.ensure_available()?;
        let disk_name = sanitize_windows_filename(name);
        let parent_path = self.core.resolve_path(parent_id)?;
        let target = parent_path.join(&disk_name);
        fs::create_dir_all(&target)?;
        self.core.build_remote_file(&target, parent_id, &disk_name)
    }

    async fn list_files(&self, folder_id: &str) -> CoreResult<Vec<RemoteDriveFile>> {
        self.core.list_dir(folder_id)
    }

    async fn download_data(&self, file_id: &str) -> CoreResult<Vec<u8>> {
        self.core.ensure_available()?;
        let path = self.core.resolve_path(file_id)?;
        if !path.is_file() {
            return Err(CoreError::NotFound(file_id.to_string()));
        }
        Ok(fs::read(path)?)
    }

    async fn download_file(&self, file_id: &str, destination: &Path) -> CoreResult<()> {
        self.core.ensure_available()?;
        let src = self.core.resolve_path(file_id)?;
        if !src.is_file() {
            return Err(CoreError::NotFound(file_id.to_string()));
        }
        if let Some(parent) = destination.parent() {
            fs::create_dir_all(parent)?;
        }
        fs::copy(src, destination)?;
        Ok(())
    }

    async fn upload_data(
        &self,
        data: &[u8],
        name: &str,
        _mime_type: &str,
        parent_id: &str,
        existing_file_id: Option<&str>,
    ) -> CoreResult<RemoteDriveFile> {
        validate_drive_name(name)?;
        self.core.ensure_available()?;
        let disk_name = sanitize_windows_filename(name);
        let target = match existing_file_id {
            Some(eid) => self.core.resolve_path(eid)?,
            None => self.core.resolve_path(parent_id)?.join(&disk_name),
        };
        if let Some(parent) = target.parent() {
            fs::create_dir_all(parent)?;
        }
        // Write directly without O_EXCL / exclusive locks for rclone / WinFsp mount compatibility.
        fs::write(&target, data)?;
        let actual_name = target
            .file_name()
            .and_then(|n| n.to_str())
            .unwrap_or(&disk_name);
        self.core.build_remote_file(&target, parent_id, actual_name)
    }

    async fn upload_file(
        &self,
        local_path: &Path,
        name: &str,
        mime_type: &str,
        parent_id: &str,
        existing_file_id: Option<&str>,
    ) -> CoreResult<RemoteDriveFile> {
        let data = fs::read(local_path)?;
        self.upload_data(&data, name, mime_type, parent_id, existing_file_id)
            .await
    }

    async fn move_file(
        &self,
        file_id: &str,
        _from_parent_id: Option<&str>,
        to_parent_id: &str,
        new_name: Option<&str>,
    ) -> CoreResult<RemoteDriveFile> {
        self.core.ensure_available()?;
        let src = self.core.resolve_path(file_id)?;
        if !src.exists() {
            return Err(CoreError::NotFound(file_id.to_string()));
        }
        let current_name = src
            .file_name()
            .and_then(|n| n.to_str())
            .unwrap_or("item")
            .to_string();
        let disk_name = match new_name {
            Some(n) => {
                validate_drive_name(n)?;
                sanitize_windows_filename(n)
            }
            None => current_name,
        };
        let dst_parent = self.core.resolve_path(to_parent_id)?;
        fs::create_dir_all(&dst_parent)?;
        let dst = dst_parent.join(&disk_name);
        if src != dst {
            fs::rename(&src, &dst)?;
        }
        self.core.build_remote_file(&dst, to_parent_id, &disk_name)
    }

    async fn trash_file(&self, file_id: &str) -> CoreResult<()> {
        self.core.ensure_available()?;
        let path = self.core.resolve_path(file_id)?;
        if !path.exists() {
            return Ok(());
        }
        if path.is_dir() {
            fs::remove_dir_all(path)?;
        } else {
            fs::remove_file(path)?;
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn resolve_path_blocks_windows_backslash_and_drive_letter_traversal() {
        let tmp = tempfile::tempdir().unwrap();
        let transport = LocalFolderTransport::new(tmp.path());
        for bad in [
            "../outside.txt",
            "folder/../../outside.txt",
            "C:\\Windows\\System32\\cmd.exe",
            "folder/sub\\..\\escape",
            "D:evil.txt",
        ] {
            assert!(
                transport.core.resolve_path(bad).is_err(),
                "expected traversal rejection for `{bad}`"
            );
        }
        let ok = transport.core.resolve_path("Inbox/poster.png").unwrap();
        assert!(ok.starts_with(tmp.path()));
    }
}
