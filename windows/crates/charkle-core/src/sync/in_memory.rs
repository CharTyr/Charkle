//! Deterministic in-memory `DriveTransport` for multi-device conflict, rename, and migration tests.
//!
//! Mirrors `Sources/CharkleCore/Sync/InMemoryDriveTransport.swift`.

use std::collections::HashMap;
use std::fs;
use std::path::Path;
use std::sync::Mutex;

use async_trait::async_trait;
use chrono::{DateTime, TimeZone, Utc};
use md5::{Digest, Md5};

use crate::error::{CoreError, CoreResult};
use crate::models::sync::{DriveAccountInfo, DriveChange, DriveChangePage, RemoteDriveFile};
use crate::sync::transport::{validate_drive_name, DriveTransport, DRIVE_ROOT_ID};

#[derive(Debug, Clone)]
struct Entry {
    name: String,
    mime_type: String,
    parent: String,
    data: Option<Vec<u8>>,
    modified_time: DateTime<Utc>,
    trashed: bool,
}

impl Entry {
    fn metadata(&self, id: &str) -> RemoteDriveFile {
        RemoteDriveFile {
            id: id.to_string(),
            name: self.name.clone(),
            mime_type: self.mime_type.clone(),
            size: self.data.as_ref().map(|d| d.len() as i64),
            modified_time: Some(self.modified_time),
            md5_checksum: self.data.as_ref().map(|d| hex::encode(Md5::digest(d))),
            parents: vec![self.parent.clone()],
            trashed: self.trashed,
            web_view_link: None,
            thumbnail_link: None,
        }
    }
}

#[derive(Debug, Default)]
struct InnerState {
    entries: HashMap<String, Entry>,
    history: Vec<DriveChange>,
    next_id: usize,
}

impl InnerState {
    fn now(&self) -> DateTime<Utc> {
        let ms = 1_700_000_000_000_i64 + (self.history.len() as i64) * 100;
        Utc.timestamp_millis_opt(ms)
            .single()
            .unwrap_or_else(Utc::now)
    }

    fn require_parent(&self, id: &str) -> CoreResult<()> {
        if id == DRIVE_ROOT_ID {
            return Ok(());
        }
        match self.entries.get(id) {
            Some(e) if e.data.is_none() && !e.trashed => Ok(()),
            _ => Err(CoreError::NotFound(id.to_string())),
        }
    }

    fn allocate_id(&mut self) -> String {
        self.next_id += 1;
        format!("drive-{}", self.next_id)
    }

    fn save(&mut self, entry: Entry, id: String) -> RemoteDriveFile {
        let file = entry.metadata(&id);
        self.entries.insert(id.clone(), entry);
        self.history.push(DriveChange {
            file_id: id,
            removed: false,
            file: Some(file.clone()),
        });
        file
    }
}

pub struct InMemoryDriveTransport {
    email: String,
    page_size: usize,
    state: Mutex<InnerState>,
}

impl Default for InMemoryDriveTransport {
    fn default() -> Self {
        Self::new("charkle@example.invalid", 100)
    }
}

impl InMemoryDriveTransport {
    pub fn new(email: impl Into<String>, page_size: usize) -> Self {
        Self {
            email: email.into(),
            page_size: page_size.max(1),
            state: Mutex::new(InnerState::default()),
        }
    }

    fn lock(&self) -> CoreResult<std::sync::MutexGuard<'_, InnerState>> {
        self.state.lock().map_err(|_| {
            CoreError::InvalidOperation("InMemoryDriveTransport mutex poisoned".to_string())
        })
    }
}

#[async_trait]
impl DriveTransport for InMemoryDriveTransport {
    fn display_name(&self) -> &str {
        "In-memory Drive"
    }

    fn accepts_remote_id(&self, id: &str) -> bool {
        !id.is_empty()
            && !id.starts_with("mounted-")
            && !id.starts_with("icloud-path:")
            && !id.contains('/')
            && !id.contains('\\')
            && !id.contains("..")
    }

    async fn account_info(&self) -> CoreResult<DriveAccountInfo> {
        Ok(DriveAccountInfo {
            email: self.email.clone(),
            display_name: None,
            storage_used_bytes: None,
            storage_limit_bytes: None,
            source: self.display_name().to_string(),
        })
    }

    async fn fetch_start_page_token(&self) -> CoreResult<String> {
        let guard = self.lock()?;
        Ok(guard.history.len().to_string())
    }

    async fn list_changes(&self, page_token: &str) -> CoreResult<DriveChangePage> {
        let guard = self.lock()?;
        let start: usize = page_token.parse().map_err(|_| CoreError::Http {
            status_code: 410,
            message: "Expired change token".to_string(),
        })?;
        if start > guard.history.len() {
            return Err(CoreError::Http {
                status_code: 410,
                message: "Expired change token".to_string(),
            });
        }
        let end = (start + self.page_size).min(guard.history.len());
        let changes = guard.history[start..end].to_vec();
        Ok(DriveChangePage {
            changes,
            next_page_token: (end < guard.history.len()).then(|| end.to_string()),
            new_start_page_token: (end == guard.history.len()).then(|| end.to_string()),
        })
    }

    async fn find_or_create_folder(
        &self,
        name: &str,
        parent_id: &str,
    ) -> CoreResult<RemoteDriveFile> {
        validate_drive_name(name)?;
        let mut guard = self.lock()?;
        guard.require_parent(parent_id)?;
        if let Some((id, entry)) = guard.entries.iter().find(|(_, e)| {
            e.name == name && e.parent == parent_id && !e.trashed && e.data.is_none()
        }) {
            return Ok(entry.metadata(id));
        }
        let id = guard.allocate_id();
        let entry = Entry {
            name: name.to_string(),
            mime_type: RemoteDriveFile::FOLDER_MIME_TYPE.to_string(),
            parent: parent_id.to_string(),
            data: None,
            modified_time: guard.now(),
            trashed: false,
        };
        Ok(guard.save(entry, id))
    }

    async fn list_files(&self, folder_id: &str) -> CoreResult<Vec<RemoteDriveFile>> {
        let guard = self.lock()?;
        guard.require_parent(folder_id)?;
        let mut items: Vec<RemoteDriveFile> = guard
            .entries
            .iter()
            .filter(|(_, e)| e.parent == folder_id && !e.trashed)
            .map(|(id, e)| e.metadata(id))
            .collect();
        items.sort_by(|a, b| a.name.cmp(&b.name).then_with(|| a.id.cmp(&b.id)));
        Ok(items)
    }

    async fn download_data(&self, file_id: &str) -> CoreResult<Vec<u8>> {
        let guard = self.lock()?;
        let entry = guard
            .entries
            .get(file_id)
            .filter(|e| !e.trashed)
            .ok_or_else(|| CoreError::NotFound(file_id.to_string()))?;
        entry
            .data
            .clone()
            .ok_or_else(|| CoreError::NotFound(file_id.to_string()))
    }

    async fn download_file(&self, file_id: &str, destination: &Path) -> CoreResult<()> {
        let data = self.download_data(file_id).await?;
        if let Some(parent) = destination.parent() {
            fs::create_dir_all(parent)?;
        }
        fs::write(destination, data)?;
        Ok(())
    }

    async fn upload_data(
        &self,
        data: &[u8],
        name: &str,
        mime_type: &str,
        parent_id: &str,
        existing_file_id: Option<&str>,
    ) -> CoreResult<RemoteDriveFile> {
        validate_drive_name(name)?;
        let mut guard = self.lock()?;
        guard.require_parent(parent_id)?;
        if let Some(existing) = existing_file_id {
            if guard
                .entries
                .get(existing)
                .and_then(|e| e.data.as_ref())
                .is_none()
            {
                return Err(CoreError::NotFound(existing.to_string()));
            }
        }
        let id = match existing_file_id {
            Some(eid) => eid.to_string(),
            None => guard.allocate_id(),
        };
        let entry = Entry {
            name: name.to_string(),
            mime_type: mime_type.to_string(),
            parent: parent_id.to_string(),
            data: Some(data.to_vec()),
            modified_time: guard.now(),
            trashed: false,
        };
        Ok(guard.save(entry, id))
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
        let mut guard = self.lock()?;
        guard.require_parent(to_parent_id)?;
        let mut entry = guard
            .entries
            .get(file_id)
            .filter(|e| !e.trashed)
            .cloned()
            .ok_or_else(|| CoreError::NotFound(file_id.to_string()))?;

        // Cycle guard
        let mut parent = to_parent_id;
        while parent != DRIVE_ROOT_ID {
            if parent == file_id {
                return Err(CoreError::InvalidPayload(
                    "Invalid folder move.".to_string(),
                ));
            }
            parent = guard
                .entries
                .get(parent)
                .map(|e| e.parent.as_str())
                .ok_or_else(|| CoreError::InvalidPayload("Invalid folder move.".to_string()))?;
        }

        if let Some(name) = new_name {
            validate_drive_name(name)?;
            entry.name = name.to_string();
        }
        entry.parent = to_parent_id.to_string();
        entry.modified_time = guard.now();
        Ok(guard.save(entry, file_id.to_string()))
    }

    async fn trash_file(&self, file_id: &str) -> CoreResult<()> {
        let mut guard = self.lock()?;
        let mut entry = guard
            .entries
            .get(file_id)
            .cloned()
            .ok_or_else(|| CoreError::NotFound(file_id.to_string()))?;
        entry.trashed = true;
        entry.modified_time = guard.now();
        let _ = guard.save(entry, file_id.to_string());
        Ok(())
    }

    async fn resolve_folder(&self, id: &str) -> CoreResult<RemoteDriveFile> {
        let guard = self.lock()?;
        let entry = guard
            .entries
            .get(id)
            .filter(|e| e.data.is_none() && !e.trashed)
            .ok_or_else(|| CoreError::NotFound(id.to_string()))?;
        Ok(entry.metadata(id))
    }

    async fn list_shared_folders(&self) -> CoreResult<Vec<RemoteDriveFile>> {
        let guard = self.lock()?;
        let mut folders: Vec<RemoteDriveFile> = guard
            .entries
            .iter()
            .filter(|(_, e)| e.data.is_none() && !e.trashed)
            .map(|(id, e)| e.metadata(id))
            .collect();
        folders.sort_by(|a, b| a.name.cmp(&b.name).then_with(|| a.id.cmp(&b.id)));
        Ok(folders)
    }
}
