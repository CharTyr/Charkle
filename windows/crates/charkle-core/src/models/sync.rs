//! Sync models and CRDT operation wire contracts mirroring
//! `Sources/CharkleCore/Contracts/SyncModels.swift` and `Sync/SyncOperations.swift`.

use std::collections::{BTreeMap, HashMap};

use chrono::{DateTime, Utc};
use serde::de::DeserializeOwned;
use serde::{Deserialize, Deserializer, Serialize, Serializer};
use url::Url;
use uuid::Uuid;

use crate::error::CoreResult;
use crate::models::core::{AssetRecord, FolderRecord};
use crate::models::media::AssetVector;
use crate::models::moodboard::{BoardConnector, BoardNode, InkStroke, MoodboardDocument};
use crate::wire::swift_codec::{
    base64_field_map, cocoa_date, cocoa_date_opt, format_swift_uuid, upper_uuid, upper_uuid_vec,
    SyncFields,
};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum DriveTransportMode {
    #[serde(rename = "directAPIWithGDirect")]
    DirectApiWithGDirect,
    #[serde(rename = "iCloudDrive")]
    ICloudDrive,
    #[serde(rename = "webDAV")]
    WebDav,
    #[serde(rename = "gdirectMount")]
    GDirectMount,
    #[default]
    LocalOnly,
}

impl DriveTransportMode {
    pub fn localized_label(self) -> &'static str {
        match self {
            Self::DirectApiWithGDirect => "Google Drive",
            Self::ICloudDrive => "iCloud Drive",
            Self::WebDav => "WebDAV 云盘",
            Self::GDirectMount => "gdirect 本地挂载",
            Self::LocalOnly => "纯本地文件夹",
        }
    }

    pub fn is_cloud_backed(self) -> bool {
        !matches!(self, Self::LocalOnly)
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ICloudDriveAvailability {
    pub is_ubiquity_container_available: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub ubiquity_documents_path: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub system_cloud_docs_path: Option<String>,
    pub default_display_location: String,
}

impl Default for ICloudDriveAvailability {
    fn default() -> Self {
        Self {
            is_ubiquity_container_available: false,
            ubiquity_documents_path: None,
            system_cloud_docs_path: None,
            default_display_location: "iCloud Drive / Charkle".to_string(),
        }
    }
}

impl ICloudDriveAvailability {
    pub fn has_automatic_path(&self) -> bool {
        self.ubiquity_documents_path.is_some() || self.system_cloud_docs_path.is_some()
    }
}

fn default_backend_mode() -> DriveTransportMode {
    DriveTransportMode::DirectApiWithGDirect
}

/// Independent sync backend profile enabling simultaneous multi-backend sync
/// (e.g. Google Drive + iCloud Drive + WebDAV connected at the same time).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SyncBackendProfile {
    #[serde(default = "Uuid::new_v4", with = "upper_uuid")]
    pub id: Uuid,
    #[serde(default)]
    pub name: String,
    #[serde(default = "default_backend_mode")]
    pub mode: DriveTransportMode,
    #[serde(default = "default_true")]
    pub is_enabled: bool,
    #[serde(default)]
    pub is_primary: bool,

    // Google Drive / gdirect
    #[serde(default = "default_root_folder_name")]
    pub root_folder_name: String,
    #[serde(rename = "sharedFolderURLOrID", default)]
    pub shared_folder_url_or_id: String,
    #[serde(default = "default_mount_path")]
    pub mount_path: String,
    #[serde(
        rename = "selectedGDirectAccount",
        default,
        skip_serializing_if = "Option::is_none"
    )]
    pub selected_gdirect_account: Option<String>,
    #[serde(rename = "useGDirectIPAcceleration", default = "default_true")]
    pub use_gdirect_ip_acceleration: bool,

    // iCloud Drive
    #[serde(rename = "iCloudFolderName", default = "default_root_folder_name")]
    pub icloud_folder_name: String,
    #[serde(rename = "iCloudCustomFolderPath", default)]
    pub icloud_custom_folder_path: String,
    #[serde(rename = "iCloudContainerIdentifier", default)]
    pub icloud_container_identifier: String,

    // WebDAV
    #[serde(rename = "webDAVServerURL", default)]
    pub webdav_server_url: String,
    #[serde(rename = "webDAVUsername", default)]
    pub webdav_username: String,
    #[serde(rename = "webDAVRemotePath", default = "default_webdav_path")]
    pub webdav_remote_path: String,

    // Local Folder
    #[serde(default = "default_local_library_path")]
    pub local_library_path: String,
}

impl Default for SyncBackendProfile {
    fn default() -> Self {
        Self::new(DriveTransportMode::DirectApiWithGDirect)
    }
}

impl SyncBackendProfile {
    pub const LEGACY_PRIMARY_ID: Uuid = Uuid::from_u128(1);

    pub fn new(mode: DriveTransportMode) -> Self {
        Self {
            id: Uuid::new_v4(),
            name: mode.localized_label().to_string(),
            mode,
            is_enabled: true,
            is_primary: false,
            root_folder_name: default_root_folder_name(),
            shared_folder_url_or_id: String::new(),
            mount_path: default_mount_path(),
            selected_gdirect_account: None,
            use_gdirect_ip_acceleration: true,
            icloud_folder_name: default_root_folder_name(),
            icloud_custom_folder_path: String::new(),
            icloud_container_identifier: String::new(),
            webdav_server_url: String::new(),
            webdav_username: String::new(),
            webdav_remote_path: default_webdav_path(),
            local_library_path: default_local_library_path(),
        }
    }

    pub fn from_legacy_config(config: &DriveSyncConfig) -> Self {
        Self {
            id: Self::LEGACY_PRIMARY_ID,
            name: config.mode.localized_label().to_string(),
            mode: config.mode,
            is_enabled: true,
            is_primary: true,
            root_folder_name: config.root_folder_name.clone(),
            shared_folder_url_or_id: config.shared_folder_url_or_id.clone(),
            mount_path: config.mount_path.clone(),
            selected_gdirect_account: config.selected_gdirect_account.clone(),
            use_gdirect_ip_acceleration: config.use_gdirect_ip_acceleration,
            icloud_folder_name: config.icloud_folder_name.clone(),
            icloud_custom_folder_path: config.icloud_custom_folder_path.clone(),
            icloud_container_identifier: String::new(),
            webdav_server_url: config.webdav_server_url.clone(),
            webdav_username: config.webdav_username.clone(),
            webdav_remote_path: config.webdav_remote_path.clone(),
            local_library_path: config.local_library_path.clone(),
        }
    }

    pub fn display_name(&self) -> String {
        let trimmed = self.name.trim();
        if trimmed.is_empty() {
            self.mode.localized_label().to_string()
        } else {
            trimmed.to_string()
        }
    }

    pub fn resolved_shared_folder_id(&self) -> Option<String> {
        DriveSyncConfig::extract_google_drive_folder_id(&self.shared_folder_url_or_id)
    }

    pub fn location_summary(&self) -> String {
        match self.mode {
            DriveTransportMode::DirectApiWithGDirect => {
                if let Some(shared_id) = self.resolved_shared_folder_id() {
                    let short_id: String = shared_id.chars().take(10).collect();
                    return format!("Google Drive 共享目录 ({short_id}…)");
                }
                let cleaned = self.root_folder_name.trim_matches(|c| c == '/' || c == ' ');
                let name = if cleaned.is_empty() {
                    "Charkle"
                } else {
                    cleaned
                };
                format!("Google Drive / {name}")
            }
            DriveTransportMode::ICloudDrive => {
                let custom = self.icloud_custom_folder_path.trim();
                if !custom.is_empty() {
                    let leaf = std::path::Path::new(custom)
                        .file_name()
                        .and_then(|n| n.to_str())
                        .filter(|s| !s.is_empty())
                        .unwrap_or("Charkle");
                    return format!("iCloud Drive / {leaf}");
                }
                let cleaned = self
                    .icloud_folder_name
                    .trim_matches(|c| c == '/' || c == '\\' || c == ' ');
                let name = if cleaned.is_empty() {
                    "Charkle"
                } else {
                    cleaned
                };
                format!("iCloud Drive / {name}")
            }
            DriveTransportMode::WebDav => {
                let host = Url::parse(&self.webdav_server_url)
                    .ok()
                    .and_then(|u| u.host_str().map(String::from))
                    .unwrap_or_else(|| self.webdav_server_url.clone());
                let host_label = if host.is_empty() { "未配置" } else { &host };
                let cleaned = self
                    .webdav_remote_path
                    .trim_matches(|c| c == '/' || c == ' ');
                let path = if cleaned.is_empty() {
                    "Charkle"
                } else {
                    cleaned
                };
                format!("WebDAV ({host_label}) / {path}")
            }
            DriveTransportMode::GDirectMount => {
                let cleaned = self.root_folder_name.trim_matches(|c| c == '/' || c == ' ');
                let name = if cleaned.is_empty() {
                    "Charkle"
                } else {
                    cleaned
                };
                format!("{}/{name}", self.mount_path)
            }
            DriveTransportMode::LocalOnly => self.local_library_path.clone(),
        }
    }

    pub fn to_single_backend_config(&self, base: &DriveSyncConfig) -> DriveSyncConfig {
        DriveSyncConfig {
            mode: self.mode,
            root_folder_name: self.root_folder_name.clone(),
            shared_folder_url_or_id: self.shared_folder_url_or_id.clone(),
            mount_path: self.mount_path.clone(),
            selected_gdirect_account: self.selected_gdirect_account.clone(),
            use_gdirect_ip_acceleration: self.use_gdirect_ip_acceleration,
            icloud_folder_name: self.icloud_folder_name.clone(),
            icloud_custom_folder_path: self.icloud_custom_folder_path.clone(),
            webdav_server_url: self.webdav_server_url.clone(),
            webdav_username: self.webdav_username.clone(),
            webdav_remote_path: self.webdav_remote_path.clone(),
            local_library_path: self.local_library_path.clone(),
            auto_sync_interval_seconds: base.auto_sync_interval_seconds,
            sync_thumbnails: base.sync_thumbnails,
            sync_embeddings: base.sync_embeddings,
            backends: Vec::new(),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SyncBackendStatus {
    #[serde(rename = "backendID", with = "upper_uuid")]
    pub backend_id: Uuid,
    pub name: String,
    pub mode: DriveTransportMode,
    #[serde(default = "default_true")]
    pub is_enabled: bool,
    #[serde(default)]
    pub is_primary: bool,
    #[serde(default)]
    pub phase: SyncPhase,
    #[serde(
        default,
        skip_serializing_if = "Option::is_none",
        with = "cocoa_date_opt"
    )]
    pub last_synced_at: Option<DateTime<Utc>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub last_error: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub account: Option<DriveAccountInfo>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub current_detail: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub progress_fraction: Option<f64>,
    #[serde(default)]
    pub location_summary: String,
}

impl SyncBackendStatus {
    pub fn from_profile(profile: &SyncBackendProfile) -> Self {
        Self {
            backend_id: profile.id,
            name: profile.display_name(),
            mode: profile.mode,
            is_enabled: profile.is_enabled,
            is_primary: profile.is_primary,
            phase: SyncPhase::Idle,
            last_synced_at: None,
            last_error: None,
            account: None,
            current_detail: None,
            progress_fraction: None,
            location_summary: profile.location_summary(),
        }
    }

    pub fn is_syncing(&self) -> bool {
        matches!(
            self.phase,
            SyncPhase::Scanning
                | SyncPhase::Uploading { .. }
                | SyncPhase::Downloading { .. }
                | SyncPhase::Merging
        )
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DriveAccountInfo {
    pub email: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub display_name: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub storage_used_bytes: Option<i64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub storage_limit_bytes: Option<i64>,
    #[serde(default = "default_drive_source")]
    pub source: String,
}

fn default_drive_source() -> String {
    "Google Drive".to_string()
}

fn looks_like_filesystem_path(raw: &str) -> bool {
    let trimmed = raw.trim();
    if trimmed.is_empty() {
        return false;
    }
    let bytes = trimmed.as_bytes();
    if bytes.len() >= 3
        && bytes[0].is_ascii_alphabetic()
        && bytes[1] == b':'
        && (bytes[2] == b'\\' || bytes[2] == b'/')
    {
        return true;
    }
    trimmed.starts_with("\\\\") || trimmed.starts_with('/')
}

impl DriveAccountInfo {
    /// Returns true only when this account represents a real Google Drive Direct API OAuth
    /// session (or test in-memory drive), never a local folder path, mounted drive, or WebDAV.
    pub fn is_google_direct_api(&self) -> bool {
        let email = self.email.trim();
        if email.is_empty() || !email.contains('@') || looks_like_filesystem_path(email) {
            return false;
        }
        let source = self.source.trim().to_ascii_lowercase();
        if matches!(
            source.as_str(),
            "webdav"
                | "icloud drive"
                | "icloud"
                | "local folder"
                | "本地文件夹"
                | "mounted drive"
                | "gdirect"
                | "gdirect mount"
        ) {
            return false;
        }
        source.contains("google")
            || source == "in-memory drive"
            || source == "directapi"
            || source == "direct api"
    }

    /// Returns true if this account belongs to the requested `DriveTransportMode`.
    pub fn matches_mode(&self, mode: DriveTransportMode) -> bool {
        let source = self.source.trim().to_ascii_lowercase();
        match mode {
            DriveTransportMode::DirectApiWithGDirect => self.is_google_direct_api(),
            DriveTransportMode::ICloudDrive => {
                source == "icloud drive" || source.contains("icloud")
            }
            DriveTransportMode::WebDav => {
                source == "webdav" || source.contains("webdav") || source == "in-memory drive"
            }
            DriveTransportMode::GDirectMount => {
                source == "mounted drive"
                    || source == "gdirect mount"
                    || source == "gdirect"
                    || source.contains("mount")
            }
            DriveTransportMode::LocalOnly => source == "local folder" || source == "本地文件夹",
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct GDirectEndpoint {
    pub ip: String,
    pub latency_ms: i32,
    #[serde(default = "default_true")]
    pub healthy: bool,
}

fn default_true() -> bool {
    true
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct GDirectEnvironmentSnapshot {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cli_path: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cli_version: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub app_version: Option<String>,
    #[serde(default)]
    pub has_version_mismatch: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub rclone_path: Option<String>,
    #[serde(default)]
    pub accounts: Vec<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub default_account: Option<String>,
    #[serde(default)]
    pub endpoints: Vec<GDirectEndpoint>,
    #[serde(default)]
    pub mount_path: String,
    #[serde(default)]
    pub is_mount_active: bool,
    #[serde(default = "default_true")]
    pub bypass_tun_enabled: bool,
}

impl Default for GDirectEnvironmentSnapshot {
    fn default() -> Self {
        Self {
            cli_path: None,
            cli_version: None,
            app_version: None,
            has_version_mismatch: false,
            rclone_path: None,
            accounts: Vec::new(),
            default_account: None,
            endpoints: Vec::new(),
            mount_path: default_mount_path(),
            is_mount_active: false,
            bypass_tun_enabled: true,
        }
    }
}

fn default_mount_path() -> String {
    if let Ok(profile) = std::env::var("USERPROFILE") {
        format!("{profile}\\GoogleDrive")
    } else if let Ok(home) = std::env::var("HOME") {
        format!("{home}/GoogleDrive")
    } else {
        "G:\\".to_string()
    }
}

fn default_local_library_path() -> String {
    if let Ok(profile) = std::env::var("USERPROFILE") {
        format!("{profile}\\Pictures\\Charkle")
    } else if let Ok(home) = std::env::var("HOME") {
        format!("{home}/Pictures/Charkle")
    } else {
        "./Charkle".to_string()
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DriveSyncConfig {
    #[serde(default)]
    pub mode: DriveTransportMode,
    #[serde(default = "default_root_folder_name")]
    pub root_folder_name: String,
    #[serde(rename = "sharedFolderURLOrID", default)]
    pub shared_folder_url_or_id: String,
    #[serde(default = "default_mount_path")]
    pub mount_path: String,
    #[serde(
        rename = "selectedGDirectAccount",
        default,
        skip_serializing_if = "Option::is_none"
    )]
    pub selected_gdirect_account: Option<String>,
    #[serde(rename = "useGDirectIPAcceleration", default = "default_true")]
    pub use_gdirect_ip_acceleration: bool,
    #[serde(rename = "iCloudFolderName", default = "default_root_folder_name")]
    pub icloud_folder_name: String,
    #[serde(rename = "iCloudCustomFolderPath", default)]
    pub icloud_custom_folder_path: String,
    #[serde(rename = "webDAVServerURL", default)]
    pub webdav_server_url: String,
    #[serde(rename = "webDAVUsername", default)]
    pub webdav_username: String,
    #[serde(rename = "webDAVRemotePath", default = "default_webdav_path")]
    pub webdav_remote_path: String,
    #[serde(default = "default_local_library_path")]
    pub local_library_path: String,
    #[serde(default = "default_sync_interval")]
    pub auto_sync_interval_seconds: i32,
    #[serde(default = "default_true")]
    pub sync_thumbnails: bool,
    #[serde(default = "default_true")]
    pub sync_embeddings: bool,
    #[serde(default)]
    pub backends: Vec<SyncBackendProfile>,
}

fn default_root_folder_name() -> String {
    "Charkle".to_string()
}
fn default_webdav_path() -> String {
    "/Charkle".to_string()
}
fn default_sync_interval() -> i32 {
    120
}

impl Default for DriveSyncConfig {
    fn default() -> Self {
        Self {
            mode: DriveTransportMode::DirectApiWithGDirect,
            root_folder_name: default_root_folder_name(),
            shared_folder_url_or_id: String::new(),
            mount_path: default_mount_path(),
            selected_gdirect_account: None,
            use_gdirect_ip_acceleration: true,
            icloud_folder_name: default_root_folder_name(),
            icloud_custom_folder_path: String::new(),
            webdav_server_url: String::new(),
            webdav_username: String::new(),
            webdav_remote_path: default_webdav_path(),
            local_library_path: default_local_library_path(),
            auto_sync_interval_seconds: default_sync_interval(),
            sync_thumbnails: true,
            sync_embeddings: true,
            backends: Vec::new(),
        }
    }
}

impl DriveSyncConfig {
    /// Parses a Google Drive folder URL (`.../folders/<id>`, `...open?id=<id>`) or raw folder ID.
    pub fn extract_google_drive_folder_id(raw: &str) -> Option<String> {
        let trimmed = raw.trim();
        if trimmed.is_empty() {
            return None;
        }
        let is_valid = |candidate: &str| {
            (4..=128).contains(&candidate.len())
                && candidate
                    .bytes()
                    .all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_')
        };

        if let Ok(url) = Url::parse(trimmed) {
            if url
                .host_str()
                .is_some_and(|h| h.to_ascii_lowercase().contains("google.com"))
            {
                if let Some(segments) = url.path_segments() {
                    let parts: Vec<&str> = segments.collect();
                    if let Some(idx) = parts.iter().position(|&p| p == "folders") {
                        if let Some(&candidate) = parts.get(idx + 1) {
                            if is_valid(candidate) {
                                return Some(candidate.to_string());
                            }
                        }
                    }
                }
                for (k, v) in url.query_pairs() {
                    if k == "id" && is_valid(&v) {
                        return Some(v.into_owned());
                    }
                }
                return None;
            }
        }

        if !trimmed.contains('/') && !trimmed.contains(' ') && is_valid(trimmed) {
            return Some(trimmed.to_string());
        }
        None
    }

    pub fn resolved_shared_folder_id(&self) -> Option<String> {
        Self::extract_google_drive_folder_id(&self.shared_folder_url_or_id)
    }

    /// Synthesizes a normalized list of backend profiles, keeping legacy single-backend configs 100% seamless.
    pub fn resolved_backends(&self) -> Vec<SyncBackendProfile> {
        if !self.backends.is_empty() {
            let mut list: Vec<SyncBackendProfile> = self
                .backends
                .iter()
                .cloned()
                .map(|mut b| {
                    if b.name.trim().is_empty() {
                        b.name = b.mode.localized_label().to_string();
                    }
                    b
                })
                .collect();
            if !list.iter().any(|b| b.is_primary) {
                list[0].is_primary = true;
            }
            return list;
        }
        vec![SyncBackendProfile {
            id: SyncBackendProfile::LEGACY_PRIMARY_ID,
            name: self.mode.localized_label().to_string(),
            mode: self.mode,
            is_enabled: true,
            is_primary: true,
            root_folder_name: self.root_folder_name.clone(),
            shared_folder_url_or_id: self.shared_folder_url_or_id.clone(),
            mount_path: self.mount_path.clone(),
            selected_gdirect_account: self.selected_gdirect_account.clone(),
            use_gdirect_ip_acceleration: self.use_gdirect_ip_acceleration,
            icloud_folder_name: self.icloud_folder_name.clone(),
            icloud_custom_folder_path: self.icloud_custom_folder_path.clone(),
            icloud_container_identifier: String::new(),
            webdav_server_url: self.webdav_server_url.clone(),
            webdav_username: self.webdav_username.clone(),
            webdav_remote_path: self.webdav_remote_path.clone(),
            local_library_path: self.local_library_path.clone(),
        }]
    }

    pub fn enabled_backends(&self) -> Vec<SyncBackendProfile> {
        self.resolved_backends()
            .into_iter()
            .filter(|b| b.is_enabled)
            .collect()
    }

    pub fn enabled_cloud_backends(&self) -> Vec<SyncBackendProfile> {
        self.enabled_backends()
            .into_iter()
            .filter(|b| b.mode.is_cloud_backed())
            .collect()
    }

    pub fn primary_backend(&self) -> SyncBackendProfile {
        let resolved = self.resolved_backends();
        resolved
            .iter()
            .find(|b| b.is_primary)
            .cloned()
            .unwrap_or_else(|| resolved[0].clone())
    }

    /// Mirrors the primary backend inside `backends` back to top-level fields so legacy readers remain consistent.
    pub fn synchronize_primary_fields(&mut self) {
        if self.backends.is_empty() {
            return;
        }
        let primary_idx = self
            .backends
            .iter()
            .position(|b| b.is_primary && b.is_enabled)
            .or_else(|| self.backends.iter().position(|b| b.is_primary))
            .or_else(|| self.backends.iter().position(|b| b.is_enabled))
            .unwrap_or(0);
        for (idx, backend) in self.backends.iter_mut().enumerate() {
            backend.is_primary = idx == primary_idx;
            if backend.name.trim().is_empty() {
                backend.name = backend.mode.localized_label().to_string();
            }
        }
        let primary = self.backends[primary_idx].clone();
        self.mode = primary.mode;
        self.root_folder_name = primary.root_folder_name;
        self.shared_folder_url_or_id = primary.shared_folder_url_or_id;
        self.mount_path = primary.mount_path;
        self.selected_gdirect_account = primary.selected_gdirect_account;
        self.use_gdirect_ip_acceleration = primary.use_gdirect_ip_acceleration;
        self.icloud_folder_name = primary.icloud_folder_name;
        self.icloud_custom_folder_path = primary.icloud_custom_folder_path;
        self.webdav_server_url = primary.webdav_server_url;
        self.webdav_username = primary.webdav_username;
        self.webdav_remote_path = primary.webdav_remote_path;
        self.local_library_path = primary.local_library_path;
    }

    pub fn active_storage_location_summary(&self) -> String {
        let active = self.enabled_backends();
        if active.len() > 1 {
            let names: Vec<String> = active
                .iter()
                .map(SyncBackendProfile::display_name)
                .collect();
            return format!("{}（{} 个同步后端）", names.join(" + "), active.len());
        }
        if let Some(single) = active.first() {
            return single.location_summary();
        }
        "未启用同步后端".to_string()
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct StorageMigrationReport {
    pub source_mode: DriveTransportMode,
    pub target_mode: DriveTransportMode,
    pub target_location: String,
    pub downloaded_originals: usize,
    pub migrated_assets: usize,
    pub migrated_folders: usize,
    pub migrated_boards: usize,
    pub duration_seconds: f64,
}

#[derive(Debug, Clone, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum SyncPhase {
    #[default]
    Idle,
    Scanning,
    Uploading {
        completed: usize,
        total: usize,
    },
    Downloading {
        completed: usize,
        total: usize,
    },
    Merging,
    Error(String),
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SyncStatus {
    #[serde(default)]
    pub phase: SyncPhase,
    #[serde(
        default,
        skip_serializing_if = "Option::is_none",
        with = "cocoa_date_opt"
    )]
    pub last_synced_at: Option<DateTime<Utc>>,
    #[serde(default)]
    pub pending_op_count: usize,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub account: Option<DriveAccountInfo>,
    #[serde(default)]
    pub active_mode: DriveTransportMode,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub last_error: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub current_detail: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub progress_fraction: Option<f64>,
    #[serde(default)]
    pub backend_statuses: Vec<SyncBackendStatus>,
}

impl Default for SyncStatus {
    fn default() -> Self {
        Self {
            phase: SyncPhase::Idle,
            last_synced_at: None,
            pending_op_count: 0,
            account: None,
            active_mode: DriveTransportMode::LocalOnly,
            last_error: None,
            current_detail: None,
            progress_fraction: None,
            backend_statuses: Vec::new(),
        }
    }
}

impl SyncStatus {
    pub fn is_syncing(&self) -> bool {
        matches!(
            self.phase,
            SyncPhase::Scanning
                | SyncPhase::Uploading { .. }
                | SyncPhase::Downloading { .. }
                | SyncPhase::Merging
        ) || self
            .backend_statuses
            .iter()
            .any(SyncBackendStatus::is_syncing)
    }
}

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SyncReport {
    #[serde(default)]
    pub uploaded_ops: usize,
    #[serde(default)]
    pub downloaded_ops: usize,
    #[serde(default)]
    pub discovered_remote_assets: usize,
    #[serde(rename = "discoveredAssetIDs", default, with = "upper_uuid_vec")]
    pub discovered_asset_ids: Vec<Uuid>,
    #[serde(default)]
    pub updated_boards: usize,
    #[serde(default)]
    pub reconciled_renames: usize,
    #[serde(default)]
    pub downloaded_thumbnails: usize,
    #[serde(default)]
    pub duration_seconds: f64,
}

impl SyncReport {
    pub fn has_visible_library_changes(&self) -> bool {
        self.discovered_remote_assets > 0
            || self.downloaded_ops > 0
            || self.reconciled_renames > 0
            || self.updated_boards > 0
            || self.downloaded_thumbnails > 0
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RemoteDriveFile {
    pub id: String,
    pub name: String,
    pub mime_type: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub size: Option<i64>,
    #[serde(
        default,
        skip_serializing_if = "Option::is_none",
        with = "cocoa_date_opt"
    )]
    pub modified_time: Option<DateTime<Utc>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub md5_checksum: Option<String>,
    #[serde(default)]
    pub parents: Vec<String>,
    #[serde(default)]
    pub trashed: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub web_view_link: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub thumbnail_link: Option<String>,
}

impl RemoteDriveFile {
    pub const FOLDER_MIME_TYPE: &'static str = "application/vnd.google-apps.folder";

    pub fn is_folder(&self) -> bool {
        self.mime_type == Self::FOLDER_MIME_TYPE
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DriveChange {
    #[serde(rename = "fileID")]
    pub file_id: String,
    pub removed: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub file: Option<RemoteDriveFile>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DriveChangePage {
    pub changes: Vec<DriveChange>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub next_page_token: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub new_start_page_token: Option<String>,
}

// =============================================================================
// CRDT Sync Operations & Wire Schema (1:1 with SyncOperations.swift)
// =============================================================================

#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
pub struct SyncStamp {
    pub time: i64,
    pub device: String,
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct SyncClocks {
    #[serde(default)]
    clocks: BTreeMap<String, SyncStamp>,
}

impl SyncClocks {
    pub fn accept(&mut self, stamp: &SyncStamp, key: &str) -> bool {
        if let Some(current) = self.clocks.get(key) {
            if current >= stamp {
                return false;
            }
        }
        self.clocks.insert(key.to_string(), stamp.clone());
        true
    }

    pub fn deleted(&self) -> bool {
        self.clocks.contains_key("deleted")
    }
}

/// Normalizes a tag list into `{ normalized_key -> display_tag }` matching `tagMap` in Swift.
pub fn tag_map(tags: &[String]) -> BTreeMap<String, String> {
    let mut result = BTreeMap::new();
    for tag in tags {
        let clean = tag.trim();
        let key = crate::db::search_text::normalize(clean);
        if !key.is_empty() {
            result.insert(key, clean.to_string());
        }
    }
    result
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AssetChanges {
    #[serde(with = "upper_uuid")]
    pub id: Uuid,
    #[serde(default, with = "base64_field_map")]
    pub fields: BTreeMap<String, Vec<u8>>,
    #[serde(default)]
    pub tags_added: Vec<String>,
    #[serde(default)]
    pub tags_removed: Vec<String>,
}

impl AssetChanges {
    pub const EXCLUDED: &'static [&'static str] = &[
        "id",
        "tags",
        "isLocalOriginalCached",
        "updatedAt",
        "updatedHLC",
    ];

    pub fn diff(value: &AssetRecord, previous: Option<&AssetRecord>) -> CoreResult<Self> {
        let fields = SyncFields::diff(value, previous, Self::EXCLUDED)?;
        let old_tags = previous.map(|p| tag_map(&p.tags)).unwrap_or_default();
        let new_tags = tag_map(&value.tags);

        let tags_added = new_tags
            .iter()
            .filter_map(|(k, v)| {
                if old_tags.get(k) == Some(v) {
                    None
                } else {
                    Some(v.clone())
                }
            })
            .collect();
        let tags_removed = old_tags
            .keys()
            .filter(|k| !new_tags.contains_key(*k))
            .cloned()
            .collect();

        Ok(Self {
            id: value.id,
            fields,
            tags_added,
            tags_removed,
        })
    }

    pub fn is_empty(&self) -> bool {
        self.fields.is_empty() && self.tags_added.is_empty() && self.tags_removed.is_empty()
    }

    pub fn touches_location(&self) -> bool {
        self.fields.contains_key("folderID") || self.fields.contains_key("fileName")
    }
}

pub trait IdentifiableUuid {
    fn item_id(&self) -> Uuid;
}

impl IdentifiableUuid for BoardNode {
    fn item_id(&self) -> Uuid {
        self.id
    }
}
impl IdentifiableUuid for BoardConnector {
    fn item_id(&self) -> Uuid {
        self.id
    }
}
impl IdentifiableUuid for InkStroke {
    fn item_id(&self) -> Uuid {
        self.id
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(bound(serialize = "T: Serialize", deserialize = "T: DeserializeOwned"))]
pub struct CollectionChanges<T> {
    #[serde(default)]
    pub updated: Vec<T>,
    #[serde(default, with = "upper_uuid_vec")]
    pub removed: Vec<Uuid>,
}

impl<T> Default for CollectionChanges<T> {
    fn default() -> Self {
        Self {
            updated: Vec::new(),
            removed: Vec::new(),
        }
    }
}

impl<T: Clone + PartialEq + IdentifiableUuid> CollectionChanges<T> {
    pub fn diff(values: &[T], previous: &[T]) -> Self {
        let mut before: HashMap<Uuid, &T> = HashMap::new();
        for item in previous {
            before.insert(item.item_id(), item);
        }
        let mut after: HashMap<Uuid, &T> = HashMap::new();
        for item in values {
            after.insert(item.item_id(), item);
        }

        let mut updated: Vec<T> = after
            .values()
            .filter(|item| before.get(&item.item_id()) != Some(*item))
            .map(|item| (*item).clone())
            .collect();
        updated.sort_by_key(|item| format_swift_uuid(&item.item_id()));

        let mut removed: Vec<Uuid> = before
            .keys()
            .filter(|id| !after.contains_key(*id))
            .copied()
            .collect();
        removed.sort_by_key(format_swift_uuid);

        Self { updated, removed }
    }

    pub fn is_empty(&self) -> bool {
        self.updated.is_empty() && self.removed.is_empty()
    }

    pub fn apply(
        &self,
        values: &[T],
        component: &str,
        stamp: &SyncStamp,
        clocks: &mut SyncClocks,
    ) -> Vec<T> {
        let mut indexed: HashMap<Uuid, T> = HashMap::new();
        for item in values {
            indexed.insert(item.item_id(), item.clone());
        }
        for id in &self.removed {
            let key = format!("{component}{}", format_swift_uuid(id));
            if clocks.accept(stamp, &key) {
                indexed.remove(id);
            }
        }
        for item in &self.updated {
            let key = format!("{component}{}", format_swift_uuid(&item.item_id()));
            if clocks.accept(stamp, &key) {
                indexed.insert(item.item_id(), item.clone());
            }
        }
        let mut out: Vec<T> = indexed.into_values().collect();
        out.sort_by_key(|item| format_swift_uuid(&item.item_id()));
        out
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct BoardChanges {
    #[serde(with = "upper_uuid")]
    pub id: Uuid,
    #[serde(default, with = "base64_field_map")]
    pub fields: BTreeMap<String, Vec<u8>>,
    #[serde(default)]
    pub nodes: CollectionChanges<BoardNode>,
    #[serde(default)]
    pub connectors: CollectionChanges<BoardConnector>,
    #[serde(default)]
    pub strokes: CollectionChanges<InkStroke>,
}

impl BoardChanges {
    pub const EXCLUDED: &'static [&'static str] = &[
        "id",
        "nodes",
        "connectors",
        "inkStrokes",
        "updatedAt",
        "updatedHLC",
    ];

    pub fn diff(
        value: &MoodboardDocument,
        previous: Option<&MoodboardDocument>,
    ) -> CoreResult<Self> {
        let fields = SyncFields::diff(value, previous, Self::EXCLUDED)?;
        let prev_nodes = previous.map(|p| p.nodes.as_slice()).unwrap_or(&[]);
        let prev_connectors = previous.map(|p| p.connectors.as_slice()).unwrap_or(&[]);
        let prev_strokes = previous.map(|p| p.ink_strokes.as_slice()).unwrap_or(&[]);

        Ok(Self {
            id: value.id,
            fields,
            nodes: CollectionChanges::diff(&value.nodes, prev_nodes),
            connectors: CollectionChanges::diff(&value.connectors, prev_connectors),
            strokes: CollectionChanges::diff(&value.ink_strokes, prev_strokes),
        })
    }

    pub fn is_empty(&self) -> bool {
        self.fields.is_empty()
            && self.nodes.is_empty()
            && self.connectors.is_empty()
            && self.strokes.is_empty()
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DeletedAssetFingerprint {
    #[serde(rename = "assetID", with = "upper_uuid")]
    pub asset_id: Uuid,
    pub sha256: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub md5: Option<String>,
    pub file_name: String,
    #[serde(with = "cocoa_date")]
    pub deleted_at: DateTime<Utc>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DeletedFolderFingerprint {
    #[serde(rename = "folderID", with = "upper_uuid")]
    pub folder_id: Uuid,
    pub normalized_path: String,
    #[serde(with = "cocoa_date")]
    pub deleted_at: DateTime<Utc>,
}

/// Exact Swift synthesized Codable enum wire layout for `SyncOperation.Change`.
#[derive(Debug, Clone, PartialEq)]
pub enum SyncOperationChange {
    Asset(AssetChanges),
    Board(BoardChanges),
    Folder(FolderRecord),
    DeleteAsset { id: Uuid, drive_id: Option<String> },
    DeleteBoard(Uuid),
    DeleteFolder { id: Uuid, drive_id: Option<String> },
    Vector { id: Uuid, vector: AssetVector },
}

#[derive(Serialize, Deserialize)]
struct SwiftSinglePayload<T> {
    #[serde(rename = "_0")]
    inner: T,
}

#[derive(Serialize, Deserialize)]
struct SwiftSingleUuid {
    #[serde(rename = "_0", with = "upper_uuid")]
    inner: Uuid,
}

#[derive(Serialize, Deserialize)]
struct SwiftDeleteWithDriveId {
    #[serde(rename = "_0", with = "upper_uuid")]
    id: Uuid,
    #[serde(rename = "driveID", default, skip_serializing_if = "Option::is_none")]
    drive_id: Option<String>,
}

#[derive(Serialize, Deserialize)]
struct SwiftVectorPayload {
    #[serde(rename = "_0", with = "upper_uuid")]
    id: Uuid,
    #[serde(rename = "_1")]
    vector: AssetVector,
}

#[derive(Serialize, Deserialize)]
enum SwiftSyncOperationChangeWire {
    #[serde(rename = "asset")]
    Asset(SwiftSinglePayload<AssetChanges>),
    #[serde(rename = "board")]
    Board(SwiftSinglePayload<BoardChanges>),
    #[serde(rename = "folder")]
    Folder(SwiftSinglePayload<FolderRecord>),
    #[serde(rename = "deleteAsset")]
    DeleteAsset(SwiftDeleteWithDriveId),
    #[serde(rename = "deleteBoard")]
    DeleteBoard(SwiftSingleUuid),
    #[serde(rename = "deleteFolder")]
    DeleteFolder(SwiftDeleteWithDriveId),
    #[serde(rename = "vector")]
    Vector(SwiftVectorPayload),
}

impl Serialize for SyncOperationChange {
    fn serialize<S>(&self, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: Serializer,
    {
        let wire = match self {
            Self::Asset(delta) => SwiftSyncOperationChangeWire::Asset(SwiftSinglePayload {
                inner: delta.clone(),
            }),
            Self::Board(delta) => SwiftSyncOperationChangeWire::Board(SwiftSinglePayload {
                inner: delta.clone(),
            }),
            Self::Folder(folder) => SwiftSyncOperationChangeWire::Folder(SwiftSinglePayload {
                inner: folder.clone(),
            }),
            Self::DeleteAsset { id, drive_id } => {
                SwiftSyncOperationChangeWire::DeleteAsset(SwiftDeleteWithDriveId {
                    id: *id,
                    drive_id: drive_id.clone(),
                })
            }
            Self::DeleteBoard(id) => {
                SwiftSyncOperationChangeWire::DeleteBoard(SwiftSingleUuid { inner: *id })
            }
            Self::DeleteFolder { id, drive_id } => {
                SwiftSyncOperationChangeWire::DeleteFolder(SwiftDeleteWithDriveId {
                    id: *id,
                    drive_id: drive_id.clone(),
                })
            }
            Self::Vector { id, vector } => {
                SwiftSyncOperationChangeWire::Vector(SwiftVectorPayload {
                    id: *id,
                    vector: vector.clone(),
                })
            }
        };
        wire.serialize(serializer)
    }
}

impl<'de> Deserialize<'de> for SyncOperationChange {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: Deserializer<'de>,
    {
        match SwiftSyncOperationChangeWire::deserialize(deserializer)? {
            SwiftSyncOperationChangeWire::Asset(w) => Ok(Self::Asset(w.inner)),
            SwiftSyncOperationChangeWire::Board(w) => Ok(Self::Board(w.inner)),
            SwiftSyncOperationChangeWire::Folder(w) => Ok(Self::Folder(w.inner)),
            SwiftSyncOperationChangeWire::DeleteAsset(w) => Ok(Self::DeleteAsset {
                id: w.id,
                drive_id: w.drive_id,
            }),
            SwiftSyncOperationChangeWire::DeleteBoard(w) => Ok(Self::DeleteBoard(w.inner)),
            SwiftSyncOperationChangeWire::DeleteFolder(w) => Ok(Self::DeleteFolder {
                id: w.id,
                drive_id: w.drive_id,
            }),
            SwiftSyncOperationChangeWire::Vector(w) => Ok(Self::Vector {
                id: w.id,
                vector: w.vector,
            }),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SyncOperation {
    pub stamp: SyncStamp,
    pub change: SyncOperationChange,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub project_location: Option<bool>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SyncLogLine {
    pub seq: i64,
    pub operation: SyncOperation,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SyncManifest {
    pub version: i32,
    #[serde(
        rename = "rootFolderID",
        default,
        skip_serializing_if = "Option::is_none"
    )]
    pub root_folder_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub directories: Option<BTreeMap<String, String>>,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn drive_account_mode_isolation_rejects_local_path_for_google_drive() {
        let local_path_account = DriveAccountInfo {
            email: r"C:\Users\demo\Pictures".to_string(),
            display_name: Some(r"C:\Users\demo\Pictures".to_string()),
            storage_used_bytes: None,
            storage_limit_bytes: None,
            source: "Local Folder".to_string(),
        };
        assert!(!local_path_account.is_google_direct_api());
        assert!(!local_path_account.matches_mode(DriveTransportMode::DirectApiWithGDirect));
        assert!(!local_path_account.matches_mode(DriveTransportMode::WebDav));
        assert!(local_path_account.matches_mode(DriveTransportMode::LocalOnly));

        let mounted_account = DriveAccountInfo {
            email: r"G:\My Drive".to_string(),
            display_name: Some(r"G:\My Drive".to_string()),
            storage_used_bytes: None,
            storage_limit_bytes: None,
            source: "Mounted Drive".to_string(),
        };
        assert!(!mounted_account.is_google_direct_api());
        assert!(!mounted_account.matches_mode(DriveTransportMode::DirectApiWithGDirect));
        assert!(mounted_account.matches_mode(DriveTransportMode::GDirectMount));

        let google_account = DriveAccountInfo {
            email: "designer@example.com".to_string(),
            display_name: Some("Designer".to_string()),
            storage_used_bytes: Some(1024),
            storage_limit_bytes: Some(10240),
            source: "Google Drive API v3".to_string(),
        };
        assert!(google_account.is_google_direct_api());
        assert!(google_account.matches_mode(DriveTransportMode::DirectApiWithGDirect));
        assert!(!google_account.matches_mode(DriveTransportMode::LocalOnly));
        assert!(!google_account.matches_mode(DriveTransportMode::WebDav));
    }
}
