//! Google Drive API v3 `DriveTransport` over `reqwest` with optional `gdirect` IP override.
//!
//! Mirrors `Sources/CharkleCore/Sync/DirectAPITransport.swift`.

use std::fs;
use std::net::{IpAddr, SocketAddr};
use std::path::Path;
use std::sync::Arc;
use std::time::Duration;

use async_trait::async_trait;
use chrono::{DateTime, Utc};
use reqwest::{Client, Method, StatusCode};
use serde::Deserialize;
use url::Url;
use uuid::Uuid;

use crate::error::{CoreError, CoreResult};
use crate::models::sync::{
    DriveAccountInfo, DriveChange, DriveChangePage, GDirectEndpoint, RemoteDriveFile,
};
use crate::sync::google_oauth::GoogleOAuthClient;
use crate::sync::transport::{validate_drive_name, DriveTransport};

const DRIVE_API_BASE: &str = "https://www.googleapis.com/drive/v3";
const DRIVE_UPLOAD_BASE: &str = "https://www.googleapis.com/upload/drive/v3";
const FILE_FIELDS: &str = "id,name,mimeType,size,modifiedTime,md5Checksum,parents,trashed,webViewLink,shortcutDetails(targetId,targetMimeType)";
const SHORTCUT_MIME_TYPE: &str = "application/vnd.google-apps.shortcut";

pub struct DirectAPITransport {
    oauth: Arc<GoogleOAuthClient>,
    client: Client,
}

impl DirectAPITransport {
    pub fn new(oauth: Arc<GoogleOAuthClient>, endpoints: &[GDirectEndpoint]) -> Self {
        let mut builder = Client::builder().timeout(Duration::from_secs(120));
        // Optional `gdirect` IP direct-connect override when healthy endpoint is supplied
        if let Some(best) = endpoints
            .iter()
            .filter(|e| e.healthy)
            .min_by_key(|e| e.latency_ms)
        {
            if let Ok(ip) = best.ip.parse::<IpAddr>() {
                builder = builder.resolve("www.googleapis.com", SocketAddr::new(ip, 443));
            }
        }
        let client = builder.build().unwrap_or_else(|_| Client::new());
        Self { oauth, client }
    }

    async fn bearer(&self) -> CoreResult<String> {
        let tok = self.oauth.access_token().await?;
        Ok(format!("Bearer {tok}"))
    }

    fn escape_query(val: &str) -> String {
        val.replace('\\', "\\\\").replace('\'', "\\'")
    }

    fn validate_segment(seg: &str) -> CoreResult<&str> {
        if seg.is_empty() || seg.contains('/') || seg.contains("..") {
            return Err(CoreError::InvalidPayload(format!(
                "Invalid Drive file ID segment: `{seg}`"
            )));
        }
        Ok(seg)
    }

    async fn get_json<T: serde::de::DeserializeOwned>(
        &self,
        path: &str,
        query: &[(&str, &str)],
    ) -> CoreResult<T> {
        let mut url = Url::parse(&format!("{DRIVE_API_BASE}/{path}"))
            .map_err(|e| CoreError::InvalidPayload(e.to_string()))?;
        {
            let mut pairs = url.query_pairs_mut();
            for &(k, v) in query {
                pairs.append_pair(k, v);
            }
        }
        let resp = self
            .client
            .get(url)
            .header(reqwest::header::AUTHORIZATION, self.bearer().await?)
            .send()
            .await?;
        let status = resp.status();
        let body = resp.bytes().await?;
        Self::check_status(status, &body)?;
        Ok(serde_json::from_slice(&body)?)
    }

    fn check_status(status: StatusCode, body: &[u8]) -> CoreResult<()> {
        if status.is_success() {
            return Ok(());
        }
        let code = status.as_u16();
        let text = String::from_utf8_lossy(&body[..body.len().min(300)]).into_owned();
        if code == 401 {
            return Err(CoreError::AuthenticationRequired(text));
        }
        if code == 404 {
            return Err(CoreError::NotFound(text));
        }
        Err(CoreError::Http {
            status_code: code,
            message: text,
        })
    }

    async fn list_query(&self, query: &str) -> CoreResult<Vec<RemoteDriveFile>> {
        let fields = format!("nextPageToken,files({FILE_FIELDS})");
        let mut token: Option<String> = None;
        let mut out = Vec::new();
        loop {
            let mut params = vec![
                ("q", query),
                ("supportsAllDrives", "true"),
                ("includeItemsFromAllDrives", "true"),
                ("fields", fields.as_str()),
                ("pageSize", "1000"),
            ];
            let token_owned = token.clone();
            if let Some(ref t) = token_owned {
                params.push(("pageToken", t.as_str()));
            }
            let page: FilesPageDto = self.get_json("files", &params).await?;
            for f in page.files {
                out.push(f.into_record());
            }
            token = page.next_page_token;
            if token.is_none() {
                break;
            }
        }
        Ok(out)
    }

    async fn oldest_folder(&self, query: &str) -> CoreResult<Option<RemoteDriveFile>> {
        let fields = format!("files({FILE_FIELDS},createdTime)");
        let res: FilesPageDto = self
            .get_json(
                "files",
                &[
                    ("q", query),
                    ("supportsAllDrives", "true"),
                    ("includeItemsFromAllDrives", "true"),
                    ("fields", fields.as_str()),
                    ("pageSize", "100"),
                    ("orderBy", "createdTime"),
                ],
            )
            .await?;
        let mut items = res.files;
        items.sort_by(|a, b| {
            a.created_time
                .as_deref()
                .unwrap_or("")
                .cmp(b.created_time.as_deref().unwrap_or(""))
                .then_with(|| a.id.cmp(&b.id))
        });
        Ok(items.into_iter().next().map(FileDto::into_record))
    }

    async fn oldest_folder_shortcut(&self, query: &str) -> CoreResult<Option<FileDto>> {
        let fields = format!("files({FILE_FIELDS},createdTime)");
        let res: FilesPageDto = self
            .get_json(
                "files",
                &[
                    ("q", query),
                    ("supportsAllDrives", "true"),
                    ("includeItemsFromAllDrives", "true"),
                    ("fields", fields.as_str()),
                    ("pageSize", "20"),
                    ("orderBy", "createdTime"),
                ],
            )
            .await?;
        let mut items: Vec<FileDto> = res
            .files
            .into_iter()
            .filter(|f| {
                f.shortcut_details
                    .as_ref()
                    .and_then(|s| s.target_mime_type.as_deref())
                    == Some(RemoteDriveFile::FOLDER_MIME_TYPE)
            })
            .collect();
        items.sort_by(|a, b| {
            a.created_time
                .as_deref()
                .unwrap_or("")
                .cmp(b.created_time.as_deref().unwrap_or(""))
                .then_with(|| a.id.cmp(&b.id))
        });
        Ok(items.into_iter().next())
    }
}

#[async_trait]
impl DriveTransport for DirectAPITransport {
    fn display_name(&self) -> &str {
        "Google Drive API v3"
    }

    async fn account_info(&self) -> CoreResult<DriveAccountInfo> {
        let about: AboutDto = self
            .get_json(
                "about",
                &[(
                    "fields",
                    "user(emailAddress,displayName),storageQuota(usage,limit)",
                )],
            )
            .await?;
        Ok(DriveAccountInfo {
            email: about.user.email_address,
            display_name: about.user.display_name,
            storage_used_bytes: about
                .storage_quota
                .as_ref()
                .and_then(|q| q.usage.as_deref())
                .and_then(|s| s.parse().ok()),
            storage_limit_bytes: about
                .storage_quota
                .as_ref()
                .and_then(|q| q.limit.as_deref())
                .and_then(|s| s.parse().ok()),
            source: self.display_name().to_string(),
        })
    }

    async fn fetch_start_page_token(&self) -> CoreResult<String> {
        let res: StartTokenDto = self
            .get_json("changes/startPageToken", &[("supportsAllDrives", "true")])
            .await?;
        Ok(res.start_page_token)
    }

    async fn list_changes(&self, page_token: &str) -> CoreResult<DriveChangePage> {
        let fields =
            format!("nextPageToken,newStartPageToken,changes(fileId,removed,file({FILE_FIELDS}))");
        let page: ChangesPageDto = self
            .get_json(
                "changes",
                &[
                    ("pageToken", page_token),
                    ("includeRemoved", "true"),
                    ("spaces", "drive"),
                    ("pageSize", "1000"),
                    ("supportsAllDrives", "true"),
                    ("includeItemsFromAllDrives", "true"),
                    ("fields", fields.as_str()),
                ],
            )
            .await?;
        let changes = page
            .changes
            .into_iter()
            .filter_map(|c| {
                let id = c.file_id?;
                Some(DriveChange {
                    file_id: id,
                    removed: c.removed.unwrap_or(false),
                    file: c.file.map(FileDto::into_record),
                })
            })
            .collect();
        Ok(DriveChangePage {
            changes,
            next_page_token: page.next_page_token,
            new_start_page_token: page.new_start_page_token,
        })
    }

    async fn resolve_folder(&self, id: &str) -> CoreResult<RemoteDriveFile> {
        let seg = Self::validate_segment(id)?;
        let dto: FileDto = self
            .get_json(
                &format!("files/{seg}"),
                &[("supportsAllDrives", "true"), ("fields", FILE_FIELDS)],
            )
            .await?;
        if dto.trashed == Some(true) {
            return Err(CoreError::NotFound(format!("共享目录已在回收站中：{id}")));
        }
        if dto.mime_type == SHORTCUT_MIME_TYPE {
            if let Some(target) = dto.shortcut_details.as_ref() {
                if target.target_mime_type.as_deref() == Some(RemoteDriveFile::FOLDER_MIME_TYPE) {
                    if let Some(ref tid) = target.target_id {
                        if !tid.is_empty() {
                            return Box::pin(self.resolve_folder(tid)).await;
                        }
                    }
                }
            }
        }
        if dto.mime_type != RemoteDriveFile::FOLDER_MIME_TYPE {
            return Err(CoreError::InvalidPayload(format!(
                "指定的 Google Drive 链接不是文件夹（类型为 {}）。",
                dto.mime_type
            )));
        }
        Ok(dto.into_record())
    }

    async fn list_shared_folders(&self) -> CoreResult<Vec<RemoteDriveFile>> {
        let q = format!(
            "sharedWithMe = true and mimeType = '{}' and trashed = false",
            RemoteDriveFile::FOLDER_MIME_TYPE
        );
        let mut shared = self.list_query(&q).await?;
        shared.sort_by_key(|a| std::cmp::Reverse(a.modified_time));
        Ok(shared)
    }

    async fn find_or_create_folder(
        &self,
        name: &str,
        parent_id: &str,
    ) -> CoreResult<RemoteDriveFile> {
        validate_drive_name(name)?;
        let q = format!(
            "'{}' in parents and trashed=false and name='{}' and mimeType='{}'",
            Self::escape_query(parent_id),
            Self::escape_query(name),
            RemoteDriveFile::FOLDER_MIME_TYPE
        );
        if let Some(existing) = self.oldest_folder(&q).await? {
            return Ok(existing);
        }
        let shortcut_q = format!(
            "'{}' in parents and trashed=false and name='{}' and mimeType='{SHORTCUT_MIME_TYPE}'",
            Self::escape_query(parent_id),
            Self::escape_query(name),
        );
        if let Some(shortcut) = self.oldest_folder_shortcut(&shortcut_q).await? {
            if let Some(tid) = shortcut.shortcut_details.and_then(|s| s.target_id) {
                if !tid.is_empty() {
                    return self.resolve_folder(&tid).await;
                }
            }
        }

        let url = format!("{DRIVE_API_BASE}/files?supportsAllDrives=true&fields={FILE_FIELDS}");
        let body = serde_json::json!({
            "name": name,
            "mimeType": RemoteDriveFile::FOLDER_MIME_TYPE,
            "parents": [parent_id],
        });
        let resp = self
            .client
            .post(url)
            .header(reqwest::header::AUTHORIZATION, self.bearer().await?)
            .json(&body)
            .send()
            .await?;
        let status = resp.status();
        let bytes = resp.bytes().await?;
        Self::check_status(status, &bytes)?;
        let created: FileDto = serde_json::from_slice(&bytes)?;
        Ok(self
            .oldest_folder(&q)
            .await?
            .unwrap_or_else(|| created.into_record()))
    }

    async fn list_files(&self, folder_id: &str) -> CoreResult<Vec<RemoteDriveFile>> {
        let q = format!(
            "'{}' in parents and trashed=false",
            Self::escape_query(folder_id)
        );
        self.list_query(&q).await
    }

    async fn download_data(&self, file_id: &str) -> CoreResult<Vec<u8>> {
        let seg = Self::validate_segment(file_id)?;
        let url = format!("{DRIVE_API_BASE}/files/{seg}?alt=media&supportsAllDrives=true");
        let resp = self
            .client
            .get(url)
            .header(reqwest::header::AUTHORIZATION, self.bearer().await?)
            .send()
            .await?;
        let status = resp.status();
        let bytes = resp.bytes().await?;
        Self::check_status(status, &bytes)?;
        Ok(bytes.to_vec())
    }

    async fn download_file(&self, file_id: &str, destination: &Path) -> CoreResult<()> {
        let bytes = self.download_data(file_id).await?;
        if let Some(parent) = destination.parent() {
            fs::create_dir_all(parent)?;
        }
        fs::write(destination, bytes)?;
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
        let boundary = format!("charkle-{}", Uuid::new_v4().simple());
        let metadata = match existing_file_id {
            Some(_) => serde_json::json!({ "name": name }),
            None => serde_json::json!({ "name": name, "parents": [parent_id] }),
        };
        let meta_json = serde_json::to_string(&metadata)?;
        let mut payload = Vec::with_capacity(meta_json.len() + data.len() + 256);
        payload.extend_from_slice(
            format!(
                "--{boundary}\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n{meta_json}\r\n--{boundary}\r\nContent-Type: {mime_type}\r\n\r\n"
            )
            .as_bytes(),
        );
        payload.extend_from_slice(data);
        payload.extend_from_slice(format!("\r\n--{boundary}--\r\n").as_bytes());

        let (method, url) = match existing_file_id {
            Some(eid) => {
                let seg = Self::validate_segment(eid)?;
                (
                    Method::PATCH,
                    format!(
                        "{DRIVE_UPLOAD_BASE}/files/{seg}?uploadType=multipart&supportsAllDrives=true&fields={FILE_FIELDS}"
                    ),
                )
            }
            None => (
                Method::POST,
                format!(
                    "{DRIVE_UPLOAD_BASE}/files?uploadType=multipart&supportsAllDrives=true&fields={FILE_FIELDS}"
                ),
            ),
        };

        let resp = self
            .client
            .request(method, url)
            .header(reqwest::header::AUTHORIZATION, self.bearer().await?)
            .header(
                reqwest::header::CONTENT_TYPE,
                format!("multipart/related; boundary={boundary}"),
            )
            .body(payload)
            .send()
            .await?;
        let status = resp.status();
        let bytes = resp.bytes().await?;
        Self::check_status(status, &bytes)?;
        let dto: FileDto = serde_json::from_slice(&bytes)?;
        Ok(dto.into_record())
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
        from_parent_id: Option<&str>,
        to_parent_id: &str,
        new_name: Option<&str>,
    ) -> CoreResult<RemoteDriveFile> {
        let seg = Self::validate_segment(file_id)?;
        let mut url = Url::parse(&format!("{DRIVE_API_BASE}/files/{seg}"))
            .map_err(|e| CoreError::InvalidPayload(e.to_string()))?;
        {
            let mut q = url.query_pairs_mut();
            q.append_pair("supportsAllDrives", "true")
                .append_pair("fields", FILE_FIELDS)
                .append_pair("addParents", to_parent_id);
            if let Some(prev) = from_parent_id.filter(|p| *p != to_parent_id) {
                q.append_pair("removeParents", prev);
            }
        }
        let body = match new_name {
            Some(n) => {
                validate_drive_name(n)?;
                serde_json::json!({ "name": n })
            }
            None => serde_json::json!({}),
        };
        let resp = self
            .client
            .patch(url)
            .header(reqwest::header::AUTHORIZATION, self.bearer().await?)
            .json(&body)
            .send()
            .await?;
        let status = resp.status();
        let bytes = resp.bytes().await?;
        Self::check_status(status, &bytes)?;
        let dto: FileDto = serde_json::from_slice(&bytes)?;
        Ok(dto.into_record())
    }

    async fn trash_file(&self, file_id: &str) -> CoreResult<()> {
        let seg = Self::validate_segment(file_id)?;
        let url = format!("{DRIVE_API_BASE}/files/{seg}?supportsAllDrives=true");
        let resp = self
            .client
            .patch(url)
            .header(reqwest::header::AUTHORIZATION, self.bearer().await?)
            .json(&serde_json::json!({ "trashed": true }))
            .send()
            .await?;
        let status = resp.status();
        if status == StatusCode::NOT_FOUND {
            return Ok(());
        }
        let bytes = resp.bytes().await?;
        Self::check_status(status, &bytes)?;
        Ok(())
    }
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct AboutDto {
    user: AboutUserDto,
    storage_quota: Option<AboutQuotaDto>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct AboutUserDto {
    email_address: String,
    display_name: Option<String>,
}

#[derive(Deserialize)]
struct AboutQuotaDto {
    usage: Option<String>,
    limit: Option<String>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct StartTokenDto {
    start_page_token: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ChangesPageDto {
    #[serde(default)]
    changes: Vec<ChangeDto>,
    next_page_token: Option<String>,
    new_start_page_token: Option<String>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ChangeDto {
    file_id: Option<String>,
    removed: Option<bool>,
    file: Option<FileDto>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct FilesPageDto {
    #[serde(default)]
    files: Vec<FileDto>,
    next_page_token: Option<String>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ShortcutDetailsDto {
    target_id: Option<String>,
    target_mime_type: Option<String>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct FileDto {
    id: String,
    name: String,
    mime_type: String,
    size: Option<String>,
    modified_time: Option<String>,
    created_time: Option<String>,
    md5_checksum: Option<String>,
    #[serde(default)]
    parents: Vec<String>,
    trashed: Option<bool>,
    web_view_link: Option<String>,
    shortcut_details: Option<ShortcutDetailsDto>,
}

impl FileDto {
    fn into_record(self) -> RemoteDriveFile {
        RemoteDriveFile {
            id: self.id,
            name: self.name,
            mime_type: self.mime_type,
            size: self.size.as_deref().and_then(|s| s.parse().ok()),
            modified_time: self
                .modified_time
                .as_deref()
                .and_then(|s| DateTime::parse_from_rfc3339(s).ok())
                .map(|d| d.with_timezone(&Utc)),
            md5_checksum: self.md5_checksum,
            parents: self.parents,
            trashed: self.trashed.unwrap_or(false),
            web_view_link: self.web_view_link,
        }
    }
}
