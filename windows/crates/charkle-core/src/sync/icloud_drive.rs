//! Windows iCloud Drive filesystem-backed `DriveTransport` (`DriveTransportMode::ICloudDrive`).
//!
//! Mirrors `Sources/CharkleCore/Sync/ICloudDriveTransport.swift` with exact `"icloud-path:"`
//! remote ID prefix, automatic Windows iCloud Drive directory detection (`%USERPROFILE%\iCloudDrive`),
//! custom folder override support, and `.icloud` evicted stub awareness.

use std::collections::{BTreeMap, HashMap, HashSet};
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::Mutex;

use async_trait::async_trait;
use base64::engine::general_purpose::STANDARD as BASE64_STD;
use base64::Engine;
use chrono::{DateTime, Utc};
use uuid::Uuid;

use crate::error::{CoreError, CoreResult};
use crate::media::MediaPipeline;
use crate::models::sync::{
    DriveAccountInfo, DriveChange, DriveChangePage, ICloudDriveAvailability, RemoteDriveFile,
};
use crate::sync::transport::{
    sanitize_windows_filename, validate_drive_name, DriveTransport, DRIVE_ROOT_ID,
};

pub const ICLOUD_PATH_ID_PREFIX: &str = "icloud-path:";

/// Detects the standard Windows iCloud Drive root directory if installed and enabled.
pub fn detect_windows_icloud_drive_root() -> Option<PathBuf> {
    let home = std::env::var_os("USERPROFILE")
        .or_else(|| std::env::var_os("HOME"))
        .map(PathBuf::from)?;

    let candidates = [
        home.join("iCloudDrive"),
        home.join("iCloud Drive"),
        home.join("Library")
            .join("Mobile Documents")
            .join("com~apple~CloudDocs"),
    ];
    candidates.into_iter().find(|candidate| candidate.is_dir())
}

/// Probes local iCloud Drive availability on Windows (and macOS in cross-platform unit tests).
pub fn probe_icloud_drive_availability(
    container_identifier: Option<&str>,
) -> ICloudDriveAvailability {
    let cloud_root = detect_windows_icloud_drive_root();
    let system_cloud_docs_path = cloud_root
        .as_ref()
        .map(|p| p.to_string_lossy().into_owned());

    let trimmed_container = container_identifier
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .unwrap_or("iCloud~com~charkle~app");

    let ubiquity_documents_path = cloud_root.as_ref().and_then(|root| {
        let app_docs = root.join(trimmed_container).join("Documents");
        app_docs
            .is_dir()
            .then(|| app_docs.to_string_lossy().into_owned())
    });

    let default_display_location = if system_cloud_docs_path.is_some() {
        "iCloud Drive / Charkle".to_string()
    } else if ubiquity_documents_path.is_some() {
        "iCloud Drive / Charkle (App 容器)".to_string()
    } else {
        "请安装 Windows 版 iCloud 或手动选择 iCloud Drive 目录".to_string()
    };

    ICloudDriveAvailability {
        is_ubiquity_container_available: ubiquity_documents_path.is_some(),
        ubiquity_documents_path,
        system_cloud_docs_path,
        default_display_location,
    }
}

/// Filesystem-backed iCloud Drive transport supporting both automatic `%USERPROFILE%\iCloudDrive`
/// resolution and explicit user-chosen folders inside iCloud Drive for Windows.
pub struct ICloudDriveTransport {
    base_directory: PathBuf,
    root_segments: Vec<String>,
    account_label: String,
    locations: Mutex<HashMap<String, PathBuf>>,
}

impl ICloudDriveTransport {
    pub fn new(
        base_directory: impl Into<PathBuf>,
        root_folder_name: &str,
        account_label: Option<String>,
    ) -> Self {
        let base_directory = base_directory.into();
        let root_segments: Vec<String> = root_folder_name
            .split(['/', '\\'])
            .map(str::trim)
            .filter(|s| !s.is_empty() && *s != "." && *s != "..")
            .map(String::from)
            .collect();

        let label = match account_label.filter(|s| !s.trim().is_empty()) {
            Some(custom) => custom,
            None if root_segments.is_empty() => {
                let leaf = base_directory
                    .file_name()
                    .and_then(|n| n.to_str())
                    .unwrap_or("Charkle");
                format!("iCloud Drive / {leaf}")
            }
            None => format!("iCloud Drive / {}", root_segments.join("/")),
        };

        Self {
            base_directory,
            root_segments,
            account_label: label,
            locations: Mutex::new(HashMap::new()),
        }
    }

    /// Resolves an `ICloudDriveTransport` from an explicit custom folder path or automatic
    /// Windows iCloud Drive detection (`%USERPROFILE%\iCloudDrive`).
    pub fn from_config(
        folder_name: &str,
        custom_folder_path: &str,
        container_identifier: &str,
    ) -> CoreResult<Self> {
        let cleaned_folder = folder_name.trim_matches(|c| c == '/' || c == '\\' || c == ' ');
        let effective_folder = if cleaned_folder.is_empty() {
            "Charkle"
        } else {
            cleaned_folder
        };

        let trimmed_custom = custom_folder_path.trim();
        if !trimmed_custom.is_empty() {
            let expanded = PathBuf::from(trimmed_custom);
            let leaf = expanded
                .file_name()
                .and_then(|n| n.to_str())
                .filter(|s| !s.is_empty())
                .unwrap_or(effective_folder)
                .to_string();
            let parent = expanded
                .parent()
                .filter(|p| !p.as_os_str().is_empty())
                .map(Path::to_path_buf)
                .unwrap_or_else(|| expanded.clone());
            return Ok(Self::new(
                parent,
                &leaf,
                Some(format!("iCloud Drive / {leaf}")),
            ));
        }

        if let Some(cloud_root) = detect_windows_icloud_drive_root() {
            let trimmed_container = container_identifier.trim();
            if !trimmed_container.is_empty() {
                let app_docs = cloud_root.join(trimmed_container).join("Documents");
                if app_docs.is_dir() {
                    return Ok(Self::new(
                        app_docs,
                        effective_folder,
                        Some(format!("iCloud Drive / {effective_folder}")),
                    ));
                }
            }
            return Ok(Self::new(
                cloud_root,
                effective_folder,
                Some(format!("iCloud Drive / {effective_folder}")),
            ));
        }

        Err(CoreError::NotConfigured(
            "未检测到本机 iCloud Drive 目录。请安装并登录 Windows 版 iCloud，或在设置中手动选择 iCloud Drive 文件夹。".to_string(),
        ))
    }

    pub fn base_directory(&self) -> &Path {
        &self.base_directory
    }

    fn verify_base_directory(&self) -> CoreResult<()> {
        if !self.base_directory.exists() {
            fs::create_dir_all(&self.base_directory)?;
        }
        if !self.base_directory.is_dir() {
            return Err(CoreError::MountPathUnavailable(
                self.base_directory.display().to_string(),
            ));
        }
        Ok(())
    }

    fn make_id(rel_posix: &str) -> String {
        let clean = rel_posix.trim_matches('/');
        if clean.is_empty() {
            DRIVE_ROOT_ID.to_string()
        } else {
            format!("{ICLOUD_PATH_ID_PREFIX}{clean}")
        }
    }

    fn strip_prefix(id: &str) -> Option<&str> {
        if id == DRIVE_ROOT_ID {
            return Some("");
        }
        id.strip_prefix(ICLOUD_PATH_ID_PREFIX)
            .map(|rel| rel.trim_matches('/'))
    }

    fn join_rel(parent_id: &str, disk_name: &str) -> String {
        let parent_rel = Self::strip_prefix(parent_id).unwrap_or("");
        if parent_rel.is_empty() {
            disk_name.to_string()
        } else {
            format!("{parent_rel}/{disk_name}")
        }
    }

    fn locate(&self, id: &str) -> CoreResult<PathBuf> {
        if id == DRIVE_ROOT_ID {
            return Ok(self.base_directory.clone());
        }
        if let Some(rel) = Self::strip_prefix(id) {
            if rel.is_empty() {
                return Err(CoreError::NotFound(id.to_string()));
            }
            let mut path = self.base_directory.clone();
            for seg in rel.split('/') {
                if seg.is_empty()
                    || seg == "."
                    || seg == ".."
                    || seg.contains('\\')
                    || seg.contains(':')
                    || seg.contains('\0')
                {
                    return Err(CoreError::InvalidPayload(format!(
                        "Unsafe iCloud relative path segment in `{id}`"
                    )));
                }
                path.push(seg);
            }
            if let Ok(mut guard) = self.locations.lock() {
                guard.insert(id.to_string(), path.clone());
            }
            return Ok(path);
        }
        if let Ok(guard) = self.locations.lock() {
            if let Some(cached) = guard.get(id) {
                return Ok(cached.clone());
            }
        }
        Err(CoreError::NotFound(id.to_string()))
    }

    fn is_evicted_stub_name(name: &str) -> bool {
        name.starts_with('.') && name.ends_with(".icloud") && name.len() > 8
    }

    fn logical_name_from_entry(raw_name: &str) -> String {
        if Self::is_evicted_stub_name(raw_name) {
            raw_name[1..raw_name.len() - ".icloud".len()].to_string()
        } else {
            raw_name.to_string()
        }
    }

    fn evicted_stub_path(logical_path: &Path) -> Option<PathBuf> {
        let name = logical_path.file_name()?.to_str()?;
        if name.is_empty() || name.starts_with('.') {
            return None;
        }
        Some(logical_path.with_file_name(format!(".{name}.icloud")))
    }

    fn build_remote_file(
        &self,
        path: &Path,
        parent_id: &str,
        raw_disk_name: &str,
    ) -> CoreResult<RemoteDriveFile> {
        let meta = fs::metadata(path)?;
        let is_dir = meta.is_dir();
        let logical_name = Self::logical_name_from_entry(raw_disk_name);
        let rel = Self::join_rel(parent_id, &logical_name);
        let id = Self::make_id(&rel);
        let logical_path = path
            .parent()
            .map(|p| p.join(&logical_name))
            .unwrap_or_else(|| path.to_path_buf());
        if let Ok(mut guard) = self.locations.lock() {
            guard.insert(id.clone(), logical_path);
        }
        let modified: Option<DateTime<Utc>> = meta.modified().ok().map(DateTime::<Utc>::from);
        let mime = if is_dir {
            RemoteDriveFile::FOLDER_MIME_TYPE.to_string()
        } else {
            MediaPipeline::mime_type(&logical_name).to_string()
        };
        Ok(RemoteDriveFile {
            id,
            name: logical_name,
            mime_type: mime,
            size: (!is_dir).then_some(meta.len() as i64),
            modified_time: modified,
            md5_checksum: None,
            parents: if parent_id.is_empty() {
                Vec::new()
            } else {
                vec![parent_id.to_string()]
            },
            trashed: false,
            web_view_link: None,
            thumbnail_link: None,
        })
    }

    fn list_dir(&self, folder_id: &str) -> CoreResult<Vec<RemoteDriveFile>> {
        self.verify_base_directory()?;
        let dir = self.locate(folder_id)?;
        if !dir.is_dir() {
            return Ok(Vec::new());
        }
        let mut seen_ids = HashSet::new();
        let mut out = Vec::new();
        for entry in fs::read_dir(&dir)?.flatten() {
            let raw_name = entry.file_name().to_string_lossy().into_owned();
            if raw_name == ".DS_Store"
                || raw_name.eq_ignore_ascii_case("desktop.ini")
                || raw_name.eq_ignore_ascii_case("thumbs.db")
                || raw_name.starts_with(".charkle-icloud-")
                || raw_name.starts_with("._")
            {
                continue;
            }
            let is_stub = Self::is_evicted_stub_name(&raw_name);
            if raw_name.starts_with('.') && raw_name != ".charkle" && !is_stub {
                continue;
            }
            if let Ok(file) = self.build_remote_file(&entry.path(), folder_id, &raw_name) {
                if seen_ids.insert(file.id.clone()) {
                    out.push(file);
                }
            }
        }
        out.sort_by(|a, b| {
            a.name
                .to_lowercase()
                .cmp(&b.name.to_lowercase())
                .then_with(|| a.id.cmp(&b.id))
        });
        Ok(out)
    }

    fn snapshot(&self, include_metadata: bool) -> CoreResult<BTreeMap<String, RemoteDriveFile>> {
        self.verify_base_directory()?;
        let mut url = self.base_directory.clone();
        let mut parent_id = DRIVE_ROOT_ID.to_string();
        let mut result = BTreeMap::new();

        let root_id = if self.root_segments.is_empty() {
            DRIVE_ROOT_ID.to_string()
        } else {
            let mut last_id = DRIVE_ROOT_ID.to_string();
            for seg in &self.root_segments {
                validate_drive_name(seg)?;
                let disk_seg = sanitize_windows_filename(seg);
                url = url.join(&disk_seg);
                if !url.exists() {
                    return Ok(result);
                }
                let entry = self.build_remote_file(&url, &parent_id, &disk_seg)?;
                parent_id = entry.id.clone();
                last_id = entry.id;
            }
            last_id
        };

        let mut queue = vec![root_id];
        let mut visited = HashSet::new();
        while let Some(folder_id) = queue.pop() {
            if !visited.insert(folder_id.clone()) {
                continue;
            }
            for child in self.list_dir(&folder_id)? {
                if !include_metadata && child.name == ".charkle" {
                    continue;
                }
                let is_folder = child.is_folder();
                let child_id = child.id.clone();
                result.insert(child_id.clone(), child);
                if is_folder {
                    queue.push(child_id);
                }
            }
        }
        Ok(result)
    }
}

#[async_trait]
impl DriveTransport for ICloudDriveTransport {
    fn display_name(&self) -> &str {
        "iCloud Drive"
    }

    fn is_icloud_drive(&self) -> bool {
        true
    }

    fn is_path_based_transport(&self) -> bool {
        true
    }

    fn concurrency_limit(&self, _direct_default: usize) -> usize {
        2
    }

    fn accepts_remote_id(&self, id: &str) -> bool {
        id == DRIVE_ROOT_ID || id.starts_with(ICLOUD_PATH_ID_PREFIX)
    }

    async fn account_info(&self) -> CoreResult<DriveAccountInfo> {
        self.verify_base_directory()?;
        Ok(DriveAccountInfo {
            email: self.account_label.clone(),
            display_name: Some("iCloud Drive".to_string()),
            storage_used_bytes: None,
            storage_limit_bytes: None,
            source: self.display_name().to_string(),
        })
    }

    async fn fetch_start_page_token(&self) -> CoreResult<String> {
        let snap = self.snapshot(false)?;
        Ok(BASE64_STD.encode(serde_json::to_vec(&snap)?))
    }

    async fn list_changes(&self, page_token: &str) -> CoreResult<DriveChangePage> {
        let prev_bytes = BASE64_STD.decode(page_token).map_err(|_| CoreError::Http {
            status_code: 410,
            message: "Invalid iCloud Drive cursor".to_string(),
        })?;
        let previous: BTreeMap<String, RemoteDriveFile> = serde_json::from_slice(&prev_bytes)
            .map_err(|_| CoreError::Http {
                status_code: 410,
                message: "Invalid iCloud Drive cursor".to_string(),
            })?;
        let current = self.snapshot(false)?;
        let mut keys: HashSet<&String> = previous.keys().collect();
        keys.extend(current.keys());
        let mut sorted: Vec<&String> = keys.into_iter().collect();
        sorted.sort();

        let mut changes = Vec::new();
        for id in sorted {
            if previous.get(id) != current.get(id) {
                changes.push(DriveChange {
                    file_id: id.clone(),
                    removed: !current.contains_key(id),
                    file: current.get(id).cloned(),
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
        self.verify_base_directory()?;
        let disk_name = sanitize_windows_filename(name);
        let parent_path = self.locate(parent_id)?;
        let target = parent_path.join(&disk_name);
        if !target.exists() {
            fs::create_dir_all(&target)?;
        }
        let file = self.build_remote_file(&target, parent_id, &disk_name)?;
        if !file.is_folder() {
            return Err(CoreError::InvalidPayload(format!(
                "iCloud Drive 同名路径已被文件占用：{name}"
            )));
        }
        Ok(file)
    }

    async fn list_files(&self, folder_id: &str) -> CoreResult<Vec<RemoteDriveFile>> {
        self.list_dir(folder_id)
    }

    async fn download_data(&self, file_id: &str) -> CoreResult<Vec<u8>> {
        self.verify_base_directory()?;
        let path = self.locate(file_id)?;
        if !path.is_file() {
            return Err(CoreError::NotFound(file_id.to_string()));
        }
        Ok(fs::read(path)?)
    }

    async fn download_file(&self, file_id: &str, destination: &Path) -> CoreResult<()> {
        self.verify_base_directory()?;
        let src = self.locate(file_id)?;
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
        self.verify_base_directory()?;
        let disk_name = sanitize_windows_filename(name);
        let parent_path = self.locate(parent_id)?;
        let target = parent_path.join(&disk_name);

        if let Some(eid) = existing_file_id {
            let existing = self.locate(eid)?;
            if existing != target {
                return Err(CoreError::InvalidPayload(
                    "iCloud Drive 目标文件路径已变化。".to_string(),
                ));
            }
        } else if target.exists() {
            return Err(CoreError::AlreadyExists(name.to_string()));
        }

        if let Some(parent) = target.parent() {
            fs::create_dir_all(parent)?;
        }
        let tmp = target.with_file_name(format!(".charkle-icloud-{}", Uuid::new_v4().simple()));
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
        self.build_remote_file(&target, parent_id, &disk_name)
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
        self.verify_base_directory()?;
        let src = self.locate(file_id)?;
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
        let dst_parent = self.locate(to_parent_id)?;
        fs::create_dir_all(&dst_parent)?;
        let dst = dst_parent.join(&disk_name);
        if src != dst {
            if dst.exists() {
                if dst.is_dir() {
                    fs::remove_dir_all(&dst)?;
                } else {
                    fs::remove_file(&dst)?;
                }
            }
            fs::rename(&src, &dst)?;
        }
        self.build_remote_file(&dst, to_parent_id, &disk_name)
    }

    async fn trash_file(&self, file_id: &str) -> CoreResult<()> {
        self.verify_base_directory()?;
        let path = self.locate(file_id)?;
        if path.exists() {
            if path.is_dir() {
                fs::remove_dir_all(&path)?;
            } else {
                fs::remove_file(&path)?;
            }
        } else if let Some(stub) = Self::evicted_stub_path(&path) {
            if stub.exists() {
                let _ = fs::remove_file(&stub);
            }
        }
        if let Ok(mut guard) = self.locations.lock() {
            guard.remove(file_id);
        }
        Ok(())
    }
}
