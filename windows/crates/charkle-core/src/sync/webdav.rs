//! RFC 4918 WebDAV `DriveTransport` over `reqwest` + namespace-agnostic `quick-xml` PROPFIND parser.
//!
//! Mirrors `Sources/CharkleCore/Sync/WebDAVTransport.swift`.

use std::collections::{BTreeMap, HashSet};
use std::fs;
use std::path::Path;
use std::time::Duration;

use async_trait::async_trait;
use base64::engine::general_purpose::STANDARD as BASE64_STD;
use base64::Engine;
use chrono::{DateTime, Utc};
use quick_xml::events::Event as XmlEvent;
use quick_xml::Reader as XmlReader;
use reqwest::{Client, Method, StatusCode};
use url::Url;

use crate::error::{CoreError, CoreResult};
use crate::media::MediaPipeline;
use crate::models::sync::{DriveAccountInfo, DriveChange, DriveChangePage, RemoteDriveFile};
use crate::sync::transport::{validate_drive_name, DriveTransport, DRIVE_ROOT_ID};

const PROPFIND_BODY: &str = r#"<?xml version="1.0" encoding="utf-8" ?>
<D:propfind xmlns:D="DAV:">
  <D:prop>
    <D:displayname/>
    <D:resourcetype/>
    <D:getcontentlength/>
    <D:getlastmodified/>
    <D:getcontenttype/>
  </D:prop>
</D:propfind>"#;

pub struct WebDAVTransport {
    base_url: Url,
    username: String,
    auth_header: Option<String>,
    root_path_segments: Vec<String>,
    client: Client,
}

impl WebDAVTransport {
    pub fn new(
        server_url: &str,
        username: &str,
        password: &str,
        remote_path: &str,
    ) -> CoreResult<Self> {
        let trimmed = server_url.trim();
        let mut parsed = Url::parse(trimmed).map_err(|_| {
            CoreError::NotConfigured(
                "请输入有效的 WebDAV 服务器地址（例如 https://dav.jianguoyun.com/dav/）。"
                    .to_string(),
            )
        })?;
        let host = parsed
            .host_str()
            .map(str::to_ascii_lowercase)
            .filter(|h| !h.is_empty())
            .ok_or_else(|| CoreError::NotConfigured("WebDAV URL 缺少主机名。".to_string()))?;

        let scheme = parsed.scheme().to_ascii_lowercase();
        if scheme != "https" && !(scheme == "http" && Self::is_local_or_lan_host(&host)) {
            return Err(CoreError::NotConfigured(
                "远程 WebDAV 服务器请使用 HTTPS 地址（局域网或本机可使用 HTTP）。".to_string(),
            ));
        }

        if !parsed.path().ends_with('/') {
            let new_path = format!("{}/", parsed.path());
            parsed.set_path(&new_path);
        }

        let user = username.trim().to_string();
        let auth_header = if !user.is_empty() || !password.is_empty() {
            Some(format!(
                "Basic {}",
                BASE64_STD.encode(format!("{user}:{password}"))
            ))
        } else {
            None
        };

        let segments = Self::normalize_path_segments(remote_path);
        for seg in &segments {
            validate_drive_name(seg)?;
        }
        let root_path_segments = if segments.is_empty() {
            vec!["Charkle".to_string()]
        } else {
            segments
        };

        let client = Client::builder()
            .timeout(Duration::from_secs(60))
            .build()
            .unwrap_or_else(|_| Client::new());

        Ok(Self {
            base_url: parsed,
            username: user,
            auth_header,
            root_path_segments,
            client,
        })
    }

    pub fn normalize_path_segments(raw: &str) -> Vec<String> {
        raw.split('/')
            .map(str::trim)
            .filter(|s| !s.is_empty() && *s != "." && *s != "..")
            .map(String::from)
            .collect()
    }

    fn is_local_or_lan_host(host: &str) -> bool {
        if matches!(host, "localhost" | "127.0.0.1" | "::1" | "[::1]") || host.ends_with(".local") {
            return true;
        }
        if host.starts_with("192.168.") || host.starts_with("10.") {
            return true;
        }
        if host.starts_with("172.") {
            let mut parts = host.split('.');
            let _ = parts.next();
            if let Some(second) = parts.next().and_then(|s| s.parse::<u8>().ok()) {
                return (16..=31).contains(&second);
            }
        }
        false
    }

    fn join_relative(parent: &str, name: &str) -> String {
        if parent == DRIVE_ROOT_ID || parent.is_empty() {
            name.to_string()
        } else {
            format!("{parent}/{name}")
        }
    }

    fn build_url(&self, rel_path: &str, is_dir: bool) -> CoreResult<Url> {
        let mut url = self.base_url.clone();
        {
            let mut segs = url.path_segments_mut().map_err(|_| {
                CoreError::InvalidPayload("WebDAV base URL cannot be a base".to_string())
            })?;
            segs.pop_if_empty();
            for seg in rel_path.split('/').filter(|s| !s.is_empty()) {
                segs.push(seg);
            }
            if is_dir {
                segs.push("");
            }
        }
        Ok(url)
    }

    fn request(&self, method: Method, url: Url) -> reqwest::RequestBuilder {
        let mut req = self.client.request(method, url);
        if let Some(ref auth) = self.auth_header {
            req = req.header(reqwest::header::AUTHORIZATION, auth);
        }
        req
    }

    fn validate_status(status: StatusCode, body: &[u8], allowed: &[u16]) -> CoreResult<()> {
        let code = status.as_u16();
        if allowed.contains(&code) {
            return Ok(());
        }
        if code == 401 || code == 403 {
            return Err(CoreError::AuthenticationRequired(
                "WebDAV 账号或应用密码无效，请检查后重试。".to_string(),
            ));
        }
        if code == 404 {
            return Err(CoreError::NotFound("WebDAV resource not found".to_string()));
        }
        let msg = String::from_utf8_lossy(&body[..body.len().min(300)]).into_owned();
        Err(CoreError::Http {
            status_code: code,
            message: if msg.is_empty() {
                format!("HTTP {code}")
            } else {
                msg
            },
        })
    }

    async fn snapshot(&self) -> CoreResult<BTreeMap<String, RemoteDriveFile>> {
        let root_rel = self.root_path_segments.join("/");
        let mut result = BTreeMap::new();
        let mut queue = vec![root_rel];
        let mut visited = HashSet::new();
        while let Some(folder_id) = queue.pop() {
            if !visited.insert(folder_id.clone()) {
                continue;
            }
            for item in self.list_files(&folder_id).await? {
                let recurse = item.is_folder() && !item.name.starts_with('.');
                let id = item.id.clone();
                result.insert(id.clone(), item);
                if recurse {
                    queue.push(id);
                }
            }
        }
        Ok(result)
    }

    /// Namespace-agnostic RFC 4918 `PROPFIND` XML response parser (unit-testable offline).
    pub fn parse_propfind_response(
        xml_bytes: &[u8],
        base_url: &Url,
        directory_rel_path: &str,
        parent_id: &str,
    ) -> CoreResult<Vec<RemoteDriveFile>> {
        #[derive(Default)]
        struct Entry {
            href: String,
            is_collection: bool,
            content_length: Option<i64>,
            last_modified: Option<DateTime<Utc>>,
            content_type: Option<String>,
        }

        let mut reader = XmlReader::from_reader(xml_bytes);
        reader.config_mut().trim_text(true);
        let mut buf = Vec::new();
        let mut entries: Vec<Entry> = Vec::new();
        let mut current: Option<Entry> = None;
        let mut in_resource_type = false;
        let mut active_tag: Option<String> = None;
        let mut text_buf = String::new();

        loop {
            match reader.read_event_into(&mut buf) {
                Ok(XmlEvent::Start(e)) => {
                    let local = xml_local_name(e.name().as_ref());
                    text_buf.clear();
                    if local == "response" {
                        current = Some(Entry::default());
                    } else if local == "resourcetype" {
                        in_resource_type = true;
                    } else if local == "collection" && in_resource_type {
                        if let Some(ref mut cur) = current {
                            cur.is_collection = true;
                        }
                    } else {
                        active_tag = Some(local);
                    }
                }
                Ok(XmlEvent::Empty(e)) => {
                    let local = xml_local_name(e.name().as_ref());
                    if local == "collection" && in_resource_type {
                        if let Some(ref mut cur) = current {
                            cur.is_collection = true;
                        }
                    }
                }
                Ok(XmlEvent::Text(e)) => {
                    if let Ok(t) = e.unescape() {
                        text_buf.push_str(&t);
                    }
                }
                Ok(XmlEvent::End(e)) => {
                    let local = xml_local_name(e.name().as_ref());
                    if local == "resourcetype" {
                        in_resource_type = false;
                    } else if local == "response" {
                        if let Some(finished) = current.take() {
                            entries.push(finished);
                        }
                    } else if active_tag.as_deref() == Some(local.as_str()) {
                        let val = text_buf.trim().to_string();
                        if let Some(ref mut cur) = current {
                            match local.as_str() {
                                "href" => cur.href = val,
                                "getcontentlength" => cur.content_length = val.parse().ok(),
                                "getlastmodified" => cur.last_modified = parse_webdav_date(&val),
                                "getcontenttype" if !val.is_empty() => cur.content_type = Some(val),
                                _ => {}
                            }
                        }
                        active_tag = None;
                    }
                    text_buf.clear();
                }
                Ok(XmlEvent::Eof) => break,
                Err(e) => {
                    return Err(CoreError::InvalidPayload(format!(
                        "WebDAV PROPFIND XML parse error: {e}"
                    )));
                }
                _ => {}
            }
            buf.clear();
        }

        let base_path = normalize_slash_path(base_url.path());
        let self_rel = directory_rel_path.trim_matches('/');
        let mut results = Vec::new();

        for entry in entries {
            let Ok(resolved) = base_url.join(&entry.href) else {
                continue;
            };
            let decoded_path = percent_decode_path(resolved.path());
            let item_path = normalize_slash_path(&decoded_path);
            let rel = if base_path == "/" {
                item_path.trim_matches('/').to_string()
            } else if let Some(rest) = item_path.strip_prefix(&format!("{base_path}/")) {
                rest.trim_matches('/').to_string()
            } else if item_path == base_path {
                String::new()
            } else {
                continue;
            };

            if rel.is_empty() || rel == self_rel {
                continue;
            }
            let name = rel.rsplit('/').next().unwrap_or(&rel).to_string();
            if name == ".DS_Store" || name.starts_with(".charkle-write-") {
                continue;
            }

            let mime_type = if entry.is_collection {
                RemoteDriveFile::FOLDER_MIME_TYPE.to_string()
            } else if let Some(ct) = entry.content_type {
                ct.split(';').next().unwrap_or(&ct).trim().to_string()
            } else {
                MediaPipeline::mime_type(&name).to_string()
            };

            results.push(RemoteDriveFile {
                id: rel,
                name,
                mime_type,
                size: (!entry.is_collection)
                    .then_some(entry.content_length)
                    .flatten(),
                modified_time: entry.last_modified,
                md5_checksum: None,
                parents: vec![parent_id.to_string()],
                trashed: false,
                web_view_link: None,
                thumbnail_link: None,
            });
        }

        results.sort_by(|a, b| a.name.cmp(&b.name).then_with(|| a.id.cmp(&b.id)));
        Ok(results)
    }
}

#[async_trait]
impl DriveTransport for WebDAVTransport {
    fn display_name(&self) -> &str {
        "WebDAV"
    }

    async fn account_info(&self) -> CoreResult<DriveAccountInfo> {
        let method = Method::from_bytes(b"PROPFIND")
            .map_err(|e| CoreError::InvalidPayload(e.to_string()))?;
        let resp = self
            .request(method, self.build_url("", true)?)
            .header("Depth", "0")
            .header(
                reqwest::header::CONTENT_TYPE,
                "application/xml; charset=utf-8",
            )
            .body(PROPFIND_BODY)
            .send()
            .await?;
        let status = resp.status();
        let body = resp.bytes().await?;
        Self::validate_status(status, &body, &[200, 204, 207])?;

        let host = self
            .base_url
            .host_str()
            .unwrap_or(self.base_url.as_str())
            .to_string();
        let label = if self.username.is_empty() {
            host.clone()
        } else {
            format!("{}@{host}", self.username)
        };
        Ok(DriveAccountInfo {
            email: label,
            display_name: Some(host),
            storage_used_bytes: None,
            storage_limit_bytes: None,
            source: self.display_name().to_string(),
        })
    }

    async fn fetch_start_page_token(&self) -> CoreResult<String> {
        let snap = self.snapshot().await?;
        Ok(BASE64_STD.encode(serde_json::to_vec(&snap)?))
    }

    async fn list_changes(&self, page_token: &str) -> CoreResult<DriveChangePage> {
        let prev_bytes = BASE64_STD.decode(page_token).map_err(|_| CoreError::Http {
            status_code: 410,
            message: "WebDAV 变更游标已失效，将重新扫描。".to_string(),
        })?;
        let previous: BTreeMap<String, RemoteDriveFile> = serde_json::from_slice(&prev_bytes)
            .map_err(|_| CoreError::Http {
                status_code: 410,
                message: "WebDAV 变更游标已失效，将重新扫描。".to_string(),
            })?;
        let current = self.snapshot().await?;
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
        let rel = Self::join_relative(parent_id, name);
        let method =
            Method::from_bytes(b"MKCOL").map_err(|e| CoreError::InvalidPayload(e.to_string()))?;
        let resp = self
            .request(method, self.build_url(&rel, true)?)
            .send()
            .await?;
        let status = resp.status();
        let body = resp.bytes().await?;
        Self::validate_status(status, &body, &[200, 201, 204, 405])?;
        Ok(RemoteDriveFile {
            id: rel,
            name: name.to_string(),
            mime_type: RemoteDriveFile::FOLDER_MIME_TYPE.to_string(),
            size: None,
            modified_time: Some(Utc::now()),
            md5_checksum: None,
            parents: vec![parent_id.to_string()],
            trashed: false,
            web_view_link: None,
            thumbnail_link: None,
        })
    }

    async fn list_files(&self, folder_id: &str) -> CoreResult<Vec<RemoteDriveFile>> {
        let rel = if folder_id == DRIVE_ROOT_ID {
            ""
        } else {
            folder_id
        };
        let method = Method::from_bytes(b"PROPFIND")
            .map_err(|e| CoreError::InvalidPayload(e.to_string()))?;
        let resp = self
            .request(method, self.build_url(rel, true)?)
            .header("Depth", "1")
            .header(
                reqwest::header::CONTENT_TYPE,
                "application/xml; charset=utf-8",
            )
            .body(PROPFIND_BODY)
            .send()
            .await?;
        let status = resp.status();
        if status == StatusCode::NOT_FOUND {
            return Ok(Vec::new());
        }
        let body = resp.bytes().await?;
        Self::validate_status(status, &body, &[200, 207])?;
        Self::parse_propfind_response(&body, &self.base_url, rel, folder_id)
    }

    async fn download_data(&self, file_id: &str) -> CoreResult<Vec<u8>> {
        let resp = self
            .request(Method::GET, self.build_url(file_id, false)?)
            .send()
            .await?;
        let status = resp.status();
        if status == StatusCode::NOT_FOUND {
            return Err(CoreError::NotFound(file_id.to_string()));
        }
        let body = resp.bytes().await?;
        Self::validate_status(status, &body, &[200, 206])?;
        Ok(body.to_vec())
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
        let rel = existing_file_id
            .map(String::from)
            .unwrap_or_else(|| Self::join_relative(parent_id, name));
        let resp = self
            .request(Method::PUT, self.build_url(&rel, false)?)
            .header(reqwest::header::CONTENT_TYPE, mime_type)
            .body(data.to_vec())
            .send()
            .await?;
        let status = resp.status();
        let body = resp.bytes().await?;
        Self::validate_status(status, &body, &[200, 201, 204])?;
        Ok(RemoteDriveFile {
            id: rel,
            name: name.to_string(),
            mime_type: mime_type.to_string(),
            size: Some(data.len() as i64),
            modified_time: Some(Utc::now()),
            md5_checksum: None,
            parents: vec![parent_id.to_string()],
            trashed: false,
            web_view_link: None,
            thumbnail_link: None,
        })
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
        let current_name = file_id.rsplit('/').next().unwrap_or(file_id);
        let final_name = new_name.unwrap_or(current_name);
        validate_drive_name(final_name)?;
        let target_rel = Self::join_relative(to_parent_id, final_name);
        if target_rel != file_id {
            let method = Method::from_bytes(b"MOVE")
                .map_err(|e| CoreError::InvalidPayload(e.to_string()))?;
            let dest_url = self.build_url(&target_rel, false)?;
            let resp = self
                .request(method, self.build_url(file_id, false)?)
                .header("Destination", dest_url.as_str())
                .header("Overwrite", "T")
                .send()
                .await?;
            let status = resp.status();
            let body = resp.bytes().await?;
            Self::validate_status(status, &body, &[200, 201, 204])?;
        }
        Ok(RemoteDriveFile {
            id: target_rel,
            name: final_name.to_string(),
            mime_type: MediaPipeline::mime_type(final_name).to_string(),
            size: None,
            modified_time: Some(Utc::now()),
            md5_checksum: None,
            parents: vec![to_parent_id.to_string()],
            trashed: false,
            web_view_link: None,
            thumbnail_link: None,
        })
    }

    async fn trash_file(&self, file_id: &str) -> CoreResult<()> {
        let resp = self
            .request(Method::DELETE, self.build_url(file_id, false)?)
            .send()
            .await?;
        let status = resp.status();
        if status == StatusCode::NOT_FOUND {
            return Ok(());
        }
        let body = resp.bytes().await?;
        Self::validate_status(status, &body, &[200, 204])?;
        Ok(())
    }
}

fn xml_local_name(raw: &[u8]) -> String {
    let s = String::from_utf8_lossy(raw);
    match s.rsplit_once(':') {
        Some((_, local)) => local.to_ascii_lowercase(),
        None => s.to_ascii_lowercase(),
    }
}

fn normalize_slash_path(path: &str) -> String {
    let trimmed = path.trim_matches('/');
    if trimmed.is_empty() {
        "/".to_string()
    } else {
        format!("/{trimmed}")
    }
}

fn percent_decode_path(path: &str) -> String {
    let bytes = path.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%' && i + 2 < bytes.len() {
            if let Ok(hex_str) = std::str::from_utf8(&bytes[i + 1..i + 3]) {
                if let Ok(val) = u8::from_str_radix(hex_str, 16) {
                    out.push(val);
                    i += 3;
                    continue;
                }
            }
        }
        out.push(bytes[i]);
        i += 1;
    }
    String::from_utf8_lossy(&out).into_owned()
}

fn parse_webdav_date(raw: &str) -> Option<DateTime<Utc>> {
    if let Ok(dt) = DateTime::parse_from_rfc2822(raw) {
        return Some(dt.with_timezone(&Utc));
    }
    if let Ok(dt) = DateTime::parse_from_rfc3339(raw) {
        return Some(dt.with_timezone(&Utc));
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn accepts_ipv6_loopback_and_rejects_plaintext_remote_http() {
        assert!(WebDAVTransport::new("http://[::1]:8080/dav/", "u", "p", "/Charkle").is_ok());
        assert!(WebDAVTransport::new("http://127.0.0.1:8080/dav/", "u", "p", "/Charkle").is_ok());
        assert!(WebDAVTransport::new("https://dav.example.com/dav/", "u", "p", "/Charkle").is_ok());
        assert!(WebDAVTransport::new("http://dav.example.com/dav/", "u", "p", "/Charkle").is_err());
    }
}
