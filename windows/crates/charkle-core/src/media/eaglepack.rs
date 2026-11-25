//! Lossless reader & safe extractor for `.eaglepack` archives (ZIP) and `.library` / extracted
//! pack directories.
//!
//! Mirrors `Sources/CharkleCore/Media/EaglePackImporter.swift` 1:1:
//! - Preserves multi-level folder hierarchies & folder colors, titles, tags, star ratings,
//!   annotations, source URLs, creation/modification timestamps, and offline `.url`/`.webloc`
//!   web bookmark thumbnails.
//! - Enforces Zip-Slip path traversal rejection, Windows drive-letter rejection, symlink skipping,
//!   200,000 archive entry cap, and folder recursion depth cap (24 + cycle guard).

use std::collections::{HashMap, HashSet};
use std::fs::{self, File};
use std::io::Read;
use std::path::{Component, Path, PathBuf};

use chrono::{DateTime, TimeZone, Utc};
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value};
use url::Url;
use uuid::Uuid;

use crate::error::{CoreError, CoreResult};
use crate::models::core::AssetRecord;
use crate::wire::swift_codec::upper_uuid_opt;

/// Summary returned after importing an `.eaglepack` archive or `.library` material package.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MaterialPackageImportResult {
    pub package_name: String,
    pub imported_asset_count: usize,
    pub created_folder_count: usize,
    #[serde(rename = "rootFolderID", with = "upper_uuid_opt")]
    pub root_folder_id: Option<Uuid>,
    pub skipped_deleted_count: usize,
    pub skipped_missing_count: usize,
    #[serde(skip)]
    pub imported_assets: Vec<AssetRecord>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ParsedEagleFolder {
    pub source_id: String,
    pub name: String,
    pub color_hex: Option<String>,
    pub children: Vec<ParsedEagleFolder>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ParsedEagleAsset {
    pub source_id: String,
    pub title: String,
    pub file_path: Option<PathBuf>,
    pub thumbnail_path: Option<PathBuf>,
    pub is_web_bookmark: bool,
    pub source_url: Option<Url>,
    pub tags: Vec<String>,
    pub rating: i32,
    pub notes: String,
    pub folder_ids: Vec<String>,
    pub created_at: Option<DateTime<Utc>>,
    pub updated_at: Option<DateTime<Utc>>,
}

#[derive(Debug)]
pub struct ParsedEaglePackage {
    pub package_name: String,
    pub root_folders: Vec<ParsedEagleFolder>,
    pub items: Vec<ParsedEagleAsset>,
    pub skipped_deleted_count: usize,
    pub skipped_missing_count: usize,
    /// Temporary extraction directory owned by caller; MUST be cleaned up only after all payload
    /// files have been copied into Charkle's permanent library storage.
    pub staging_directory_to_cleanup: Option<PathBuf>,
}

/// RAII cleanup guard ensuring temporary extraction directories are always removed on drop.
pub struct StagingDirGuard {
    dirs: Vec<PathBuf>,
}

impl StagingDirGuard {
    pub fn new() -> Self {
        Self { dirs: Vec::new() }
    }

    pub fn push(&mut self, dir: PathBuf) {
        self.dirs.push(dir);
    }
}

impl Default for StagingDirGuard {
    fn default() -> Self {
        Self::new()
    }
}

impl Drop for StagingDirGuard {
    fn drop(&mut self) {
        for dir in &self.dirs {
            let _ = fs::remove_dir_all(dir);
        }
    }
}

pub struct EaglePackImporter;

impl EaglePackImporter {
    const MAX_ARCHIVE_ENTRIES: usize = 200_000;
    const MAX_FOLDER_DEPTH: usize = 24;

    // =========================================================================
    // Package Detection
    // =========================================================================

    pub fn is_eaglepack_archive(path: &Path) -> bool {
        let Ok(meta) = fs::metadata(path) else {
            return false;
        };
        if !meta.is_file() {
            return false;
        }
        path.extension()
            .and_then(|e| e.to_str())
            .is_some_and(|e| e.eq_ignore_ascii_case("eaglepack"))
    }

    pub fn is_eagle_library_or_extracted_pack_dir(path: &Path) -> bool {
        let Ok(meta) = fs::metadata(path) else {
            return false;
        };
        if !meta.is_dir() {
            return false;
        }
        let content_root = unwrap_single_top_level_dir(path);
        if content_root.join("pack.json").is_file() {
            return true;
        }
        let has_root_meta = content_root.join("metadata.json").is_file();
        let has_images_dir = content_root.join("images").is_dir();
        let is_library_ext = path
            .extension()
            .and_then(|e| e.to_str())
            .is_some_and(|e| e.eq_ignore_ascii_case("library"));
        has_root_meta && (has_images_dir || is_library_ext)
    }

    /// Returns `true` when `path` is an `.eaglepack` archive, extracted pack dir, `.library` dir,
    /// or (when `allow_generic_zip == true`) a `.zip` containing `pack.json` or `metadata.json` + `.info/`.
    pub fn is_recognized_material_package(path: &Path, allow_generic_zip: bool) -> bool {
        if Self::is_eaglepack_archive(path) {
            return true;
        }
        if Self::is_eagle_library_or_extracted_pack_dir(path) {
            return true;
        }
        if allow_generic_zip {
            let is_zip = fs::metadata(path).is_ok_and(|m| m.is_file())
                && path
                    .extension()
                    .and_then(|e| e.to_str())
                    .is_some_and(|e| e.eq_ignore_ascii_case("zip"));
            if is_zip {
                if let Ok(entries) = list_zip_entries(path) {
                    let mut has_pack = false;
                    let mut has_meta = false;
                    let mut has_info = false;
                    for raw in entries {
                        let lower = raw.replace('\\', "/").to_ascii_lowercase();
                        if lower == "pack.json" || lower.ends_with("/pack.json") {
                            has_pack = true;
                        }
                        if lower == "metadata.json" || lower.ends_with("/metadata.json") {
                            has_meta = true;
                        }
                        if lower.contains(".info/") {
                            has_info = true;
                        }
                    }
                    return has_pack || (has_meta && has_info);
                }
            }
        }
        false
    }

    // =========================================================================
    // Safe Unpack & Parse
    // =========================================================================

    pub fn unpack_and_parse(
        raw_path: &Path,
        allow_generic_zip: bool,
    ) -> CoreResult<ParsedEaglePackage> {
        let fallback_name = clean_package_display_name(raw_path);
        let meta = fs::metadata(raw_path).map_err(|_| {
            CoreError::InvalidOperation(format!(
                "「{}」不是有效的 .eaglepack 素材包或 .library 素材库。",
                raw_path
                    .file_name()
                    .and_then(|n| n.to_str())
                    .unwrap_or(&fallback_name)
            ))
        })?;

        let mut staging_dir: Option<PathBuf> = None;
        let package_root: PathBuf;

        if meta.is_dir() {
            if !Self::is_eagle_library_or_extracted_pack_dir(raw_path) {
                return Err(CoreError::InvalidOperation(format!(
                    "「{}」不是有效的 .eaglepack 素材包或 .library 素材库。",
                    raw_path
                        .file_name()
                        .and_then(|n| n.to_str())
                        .unwrap_or(&fallback_name)
                )));
            }
            package_root = unwrap_single_top_level_dir(raw_path);
        } else if meta.is_file() {
            let ext = raw_path
                .extension()
                .and_then(|e| e.to_str())
                .unwrap_or("")
                .to_ascii_lowercase();
            if ext != "eaglepack" && !(allow_generic_zip && ext == "zip") {
                return Err(CoreError::InvalidOperation(format!(
                    "「{}」不是有效的 .eaglepack 素材包或 .library 素材库。",
                    raw_path
                        .file_name()
                        .and_then(|n| n.to_str())
                        .unwrap_or(&fallback_name)
                )));
            }
            let temp_root =
                std::env::temp_dir().join(format!("charkle-eaglepack-{}", Uuid::new_v4()));
            fs::create_dir_all(&temp_root)?;
            if let Err(err) = extract_zip_safely(raw_path, &temp_root) {
                let _ = fs::remove_dir_all(&temp_root);
                return Err(err);
            }
            staging_dir = Some(temp_root.clone());
            package_root = unwrap_single_top_level_dir(&temp_root);
        } else {
            return Err(CoreError::InvalidOperation(format!(
                "「{fallback_name}」不是有效的 .eaglepack 素材包或 .library 素材库。"
            )));
        }

        match parse_directory(&package_root, &fallback_name, staging_dir.clone()) {
            Ok(parsed) => {
                if parsed.items.is_empty() && parsed.root_folders.is_empty() {
                    if let Some(ref dir) = staging_dir {
                        let _ = fs::remove_dir_all(dir);
                    }
                    return Err(CoreError::InvalidOperation(format!(
                        "素材包「{}」中没有可导入的有效素材。",
                        parsed.package_name
                    )));
                }
                Ok(parsed)
            }
            Err(err) => {
                if let Some(ref dir) = staging_dir {
                    let _ = fs::remove_dir_all(dir);
                }
                Err(err)
            }
        }
    }

    // =========================================================================
    // Public Helpers (also unit-tested directly)
    // =========================================================================

    /// Maps named preset folder color keys or `#RRGGBB` hex strings to normalized `#RRGGBB`.
    pub fn map_folder_color_hex(raw: Option<&str>) -> Option<String> {
        let cleaned = raw?.trim().to_ascii_lowercase();
        if cleaned.is_empty() {
            return None;
        }
        if let Some(hex_body) = cleaned.strip_prefix('#') {
            if hex_body.len() == 6 && hex_body.bytes().all(|b| b.is_ascii_hexdigit()) {
                return Some(cleaned.to_ascii_uppercase());
            }
        }
        match cleaned.as_str() {
            "red" => Some("#EF4444".to_string()),
            "orange" => Some("#F97316".to_string()),
            "yellow" => Some("#EAB308".to_string()),
            "green" => Some("#22C55E".to_string()),
            "aqua" | "cyan" | "teal" => Some("#06B6D4".to_string()),
            "blue" => Some("#3B82F6".to_string()),
            "pink" | "rose" => Some("#EC4899".to_string()),
            "brown" => Some("#A16207".to_string()),
            "gray" | "grey" => Some("#64748B".to_string()),
            _ => None,
        }
    }

    /// Parses Windows `[InternetShortcut]` `.url` bookmark files into a validated `http`/`https` URL.
    pub fn parse_internet_shortcut_url(data: &[u8]) -> Option<Url> {
        let text = String::from_utf8_lossy(data);
        for raw_line in text.lines() {
            let line = raw_line.trim();
            if line.len() >= 4 && line[..4].eq_ignore_ascii_case("url=") {
                let raw_url = line[4..].trim();
                if let Some(parsed) = parse_web_url(Some(raw_url)) {
                    return Some(parsed);
                }
            }
        }
        None
    }

    /// Parses XML `.webloc` plist files into a validated `http`/`https` URL.
    pub fn parse_webloc_url(data: &[u8]) -> Option<Url> {
        let text = String::from_utf8_lossy(data);
        // Look for `<key>URL</key>` followed by `<string>...</string>`
        if let Some(key_pos) = text.find("<key>URL</key>") {
            let rest = &text[key_pos + "<key>URL</key>".len()..];
            if let Some(start) = rest.find("<string>") {
                let after = &rest[start + "<string>".len()..];
                if let Some(end) = after.find("</string>") {
                    let raw = after[..end]
                        .replace("&amp;", "&")
                        .replace("&lt;", "<")
                        .replace("&gt;", ">")
                        .replace("&quot;", "\"")
                        .replace("&apos;", "'");
                    if let Some(parsed) = parse_web_url(Some(&raw)) {
                        return Some(parsed);
                    }
                }
            }
        }
        // Fallback scan for binary plist ASCII http(s) URL string
        for scheme in ["https://", "http://"] {
            if let Some(pos) = text.find(scheme) {
                let slice = &text[pos..];
                let end = slice
                    .find(|c: char| {
                        c.is_whitespace() || c.is_control() || matches!(c, '<' | '>' | '"' | '\'')
                    })
                    .unwrap_or(slice.len());
                if let Some(parsed) = parse_web_url(Some(&slice[..end])) {
                    return Some(parsed);
                }
            }
        }
        None
    }

    /// Parses epoch millisecond or second timestamps into a bounded valid `DateTime<Utc>`.
    pub fn parse_epoch_date(raw: Option<&Value>) -> Option<DateTime<Utc>> {
        let number: f64 = match raw? {
            Value::Number(n) => n.as_f64()?,
            Value::String(s) => s.trim().parse::<f64>().ok()?,
            _ => return None,
        };
        if !number.is_finite() || number <= 0.0 {
            return None;
        }
        let seconds = if number > 10_000_000_000.0 {
            number / 1000.0
        } else {
            number
        };
        const MIN_TIMESTAMP: f64 = 631_152_000.0; // 1990-01-01T00:00:00Z
        let max_timestamp = (Utc::now().timestamp() + 172_800) as f64;
        if !(MIN_TIMESTAMP..=max_timestamp).contains(&seconds) {
            return None;
        }
        let secs_i64 = seconds.trunc() as i64;
        let nanos = ((seconds.fract().max(0.0)) * 1_000_000_000.0).round() as u32;
        Utc.timestamp_opt(secs_i64, nanos.min(999_999_999)).single()
    }
}

// =============================================================================
// Internal Safe ZIP Extraction & Directory Parsing
// =============================================================================

fn list_zip_entries(zip_path: &Path) -> CoreResult<Vec<String>> {
    let file = File::open(zip_path)?;
    let archive = zip::ZipArchive::new(file)
        .map_err(|e| CoreError::InvalidOperation(format!("解压素材包失败：{e}")))?;
    let mut names = Vec::with_capacity(archive.len().min(EaglePackImporter::MAX_ARCHIVE_ENTRIES));
    for name in archive.file_names() {
        names.push(name.to_string());
    }
    Ok(names)
}

fn validate_safe_archive_entry_name(entry_name: &str) -> CoreResult<PathBuf> {
    let normalized = entry_name.replace('\\', "/");
    if normalized.starts_with('/') {
        return Err(CoreError::InvalidOperation(format!(
            "素材包内包含不安全的路径条目（{entry_name}），已拒绝导入。"
        )));
    }
    let mut rel = PathBuf::new();
    for seg in normalized.split('/') {
        if seg.is_empty() || seg == "." {
            continue;
        }
        if seg == ".." || seg.contains(':') {
            return Err(CoreError::InvalidOperation(format!(
                "素材包内包含不安全的路径条目（{entry_name}），已拒绝导入。"
            )));
        }
        rel.push(seg);
    }
    for comp in rel.components() {
        if matches!(
            comp,
            Component::Prefix(_) | Component::RootDir | Component::ParentDir
        ) {
            return Err(CoreError::InvalidOperation(format!(
                "素材包内包含不安全的路径条目（{entry_name}），已拒绝导入。"
            )));
        }
    }
    Ok(rel)
}

fn extract_zip_safely(zip_path: &Path, dst_root: &Path) -> CoreResult<()> {
    let file = File::open(zip_path)?;
    let mut archive = zip::ZipArchive::new(file)
        .map_err(|e| CoreError::InvalidOperation(format!("解压素材包失败：{e}")))?;

    if archive.len() > EaglePackImporter::MAX_ARCHIVE_ENTRIES {
        return Err(CoreError::InvalidOperation(format!(
            "压缩包条目数量超出安全限制（>{}）",
            EaglePackImporter::MAX_ARCHIVE_ENTRIES
        )));
    }

    // Pre-validate every entry name before writing a single byte to disk
    let mut rel_paths = Vec::with_capacity(archive.len());
    for i in 0..archive.len() {
        let entry = archive
            .by_index(i)
            .map_err(|e| CoreError::InvalidOperation(format!("解压素材包失败：{e}")))?;
        let name = entry.name().to_string();
        let rel = validate_safe_archive_entry_name(&name)?;
        rel_paths.push(rel);
    }

    let canon_root = fs::canonicalize(dst_root).unwrap_or_else(|_| dst_root.to_path_buf());

    for (i, rel) in rel_paths.into_iter().enumerate() {
        let mut entry = archive
            .by_index(i)
            .map_err(|e| CoreError::InvalidOperation(format!("解压素材包失败：{e}")))?;
        if rel.as_os_str().is_empty() {
            continue;
        }
        // Skip symlinks stored inside POSIX archives
        if entry
            .unix_mode()
            .is_some_and(|mode| (mode & 0o170_000) == 0o120_000)
        {
            continue;
        }
        let target = canon_root.join(&rel);
        if entry.is_dir() {
            fs::create_dir_all(&target)?;
            continue;
        }
        if let Some(parent) = target.parent() {
            fs::create_dir_all(parent)?;
            let canon_parent = fs::canonicalize(parent).unwrap_or_else(|_| parent.to_path_buf());
            if !canon_parent.starts_with(&canon_root) {
                return Err(CoreError::InvalidOperation(format!(
                    "素材包内包含不安全的路径条目（{}），已拒绝导入。",
                    entry.name()
                )));
            }
        }
        let mut out = File::create(&target)?;
        std::io::copy(&mut entry, &mut out)?;
    }

    Ok(())
}

fn parse_directory(
    package_root: &Path,
    fallback_name: &str,
    staging_directory_to_cleanup: Option<PathBuf>,
) -> CoreResult<ParsedEaglePackage> {
    let canon_root = fs::canonicalize(package_root).unwrap_or_else(|_| package_root.to_path_buf());

    let pack_dict = load_json_object(&canon_root.join("pack.json"));
    let lib_meta_dict = load_json_object(&canon_root.join("metadata.json"));

    if pack_dict.is_none() && lib_meta_dict.is_none() {
        return Err(CoreError::InvalidOperation(format!(
            "「{fallback_name}」不是有效的 .eaglepack 素材包或 .library 素材库。"
        )));
    }

    // 1. Folder hierarchy priority: pack.json.folder -> pack.json.folders -> metadata.json.folders
    let mut raw_root_folders: Vec<&Map<String, Value>> = Vec::new();
    if let Some(ref pack) = pack_dict {
        if let Some(single) = pack.get("folder").and_then(Value::as_object) {
            raw_root_folders.push(single);
        }
        if let Some(arr) = pack.get("folders").and_then(Value::as_array) {
            for item in arr {
                if let Some(obj) = item.as_object() {
                    raw_root_folders.push(obj);
                }
            }
        }
    }
    if raw_root_folders.is_empty() {
        if let Some(ref lib) = lib_meta_dict {
            if let Some(arr) = lib.get("folders").and_then(Value::as_array) {
                for item in arr {
                    if let Some(obj) = item.as_object() {
                        raw_root_folders.push(obj);
                    }
                }
            }
        }
    }

    let mut visited_folder_ids = HashSet::new();
    let root_folders = parse_folder_list(&raw_root_folders, 0, &mut visited_folder_ids);

    let declared_pack_name = pack_dict.as_ref().and_then(|p| string_value(p.get("name")));
    let package_name = if let Some(name) = declared_pack_name {
        name
    } else if root_folders.len() == 1 && !root_folders[0].name.is_empty() {
        root_folders[0].name.clone()
    } else {
        fallback_name.to_string()
    };

    // 2. Discover all `<ITEM_ID>.info/` directories under `images/` and package root
    let mut info_dirs_by_id: HashMap<String, PathBuf> = HashMap::new();
    let mut discovered_order: Vec<String> = Vec::new();
    for parent in [canon_root.join("images"), canon_root.clone()] {
        if !parent.is_dir() {
            continue;
        }
        let Ok(read_dir) = fs::read_dir(&parent) else {
            continue;
        };
        let mut entries: Vec<PathBuf> = read_dir.filter_map(|e| e.ok().map(|x| x.path())).collect();
        entries.sort_by(|a, b| {
            let na = a
                .file_name()
                .and_then(|n| n.to_str())
                .unwrap_or("")
                .to_ascii_lowercase();
            let nb = b
                .file_name()
                .and_then(|n| n.to_str())
                .unwrap_or("")
                .to_ascii_lowercase();
            na.cmp(&nb)
        });
        for entry in entries {
            let Some(name) = entry.file_name().and_then(|n| n.to_str()) else {
                continue;
            };
            if name.starts_with('.') {
                continue;
            }
            if !entry
                .extension()
                .and_then(|e| e.to_str())
                .is_some_and(|e| e.eq_ignore_ascii_case("info"))
            {
                continue;
            }
            let Ok(sym_meta) = fs::symlink_metadata(&entry) else {
                continue;
            };
            if sym_meta.file_type().is_symlink() || !sym_meta.is_dir() {
                continue;
            }
            let Ok(canon_entry) = fs::canonicalize(&entry) else {
                continue;
            };
            if !canon_entry.starts_with(&canon_root) {
                continue;
            }
            let Some(item_id) = entry.file_stem().and_then(|s| s.to_str()) else {
                continue;
            };
            if item_id.is_empty() {
                continue;
            }
            if !info_dirs_by_id.contains_key(item_id) {
                info_dirs_by_id.insert(item_id.to_string(), canon_entry);
                discovered_order.push(item_id.to_string());
            }
        }
    }

    // 3. Index manifest items from `pack.json.images[]`
    let mut pack_item_by_id: HashMap<String, &Map<String, Value>> = HashMap::new();
    let mut ordered_item_ids: Vec<String> = Vec::new();
    let mut seen_item_ids: HashSet<String> = HashSet::new();

    if let Some(ref pack) = pack_dict {
        if let Some(arr) = pack.get("images").and_then(Value::as_array) {
            for raw in arr {
                let Some(obj) = raw.as_object() else {
                    continue;
                };
                let Some(raw_id) = string_value(obj.get("id")) else {
                    continue;
                };
                pack_item_by_id.entry(raw_id.clone()).or_insert(obj);
                if seen_item_ids.insert(raw_id.clone()) {
                    ordered_item_ids.push(raw_id);
                }
            }
        }
    }
    for id in discovered_order {
        if seen_item_ids.insert(id.clone()) {
            ordered_item_ids.push(id);
        }
    }

    // 4. Merge metadata & resolve payloads
    let mut items = Vec::with_capacity(ordered_item_ids.len());
    let mut skipped_deleted_count = 0usize;
    let mut skipped_missing_count = 0usize;

    for item_id in ordered_item_ids {
        let info_dir = info_dirs_by_id.get(&item_id);
        let sidecar_meta = info_dir.and_then(|d| load_json_object(&d.join("metadata.json")));
        let manifest_meta = pack_item_by_id.get(&item_id).copied();
        let merged = merge_metadata(sidecar_meta.as_ref(), manifest_meta);

        if bool_value(merged.get("isDeleted")) == Some(true) {
            skipped_deleted_count += 1;
            continue;
        }

        let ext = string_value(merged.get("ext"))
            .unwrap_or_default()
            .to_ascii_lowercase();
        let raw_name = string_value(merged.get("name")).unwrap_or_default();

        let (payload, thumbnail) = match info_dir {
            Some(dir) => resolve_media_and_thumbnail(dir, &canon_root, &raw_name, &ext),
            None => (None, None),
        };

        let mut source_url = parse_web_url(string_value(merged.get("url")).as_deref());
        let effective_ext = if !ext.is_empty() {
            ext
        } else {
            payload
                .as_ref()
                .and_then(|p| p.extension())
                .and_then(|e| e.to_str())
                .unwrap_or("")
                .to_ascii_lowercase()
        };
        let is_bookmark = effective_ext == "url" || effective_ext == "webloc";

        if source_url.is_none() && is_bookmark {
            if let Some(ref p) = payload {
                if let Ok(bytes) = fs::read(p) {
                    source_url = if effective_ext == "url" {
                        EaglePackImporter::parse_internet_shortcut_url(&bytes)
                    } else {
                        EaglePackImporter::parse_webloc_url(&bytes)
                    };
                }
            }
        }

        let tags = parse_string_list(merged.get("tags"));
        let rating = parse_rating(&merged);
        let notes = string_value(merged.get("annotation")).unwrap_or_default();
        let folder_ids = parse_string_list(merged.get("folders"));
        let created_at = EaglePackImporter::parse_epoch_date(merged.get("btime"))
            .or_else(|| EaglePackImporter::parse_epoch_date(merged.get("mtime")));
        let updated_at = EaglePackImporter::parse_epoch_date(merged.get("modificationTime"))
            .or_else(|| EaglePackImporter::parse_epoch_date(merged.get("lastModified")))
            .or_else(|| EaglePackImporter::parse_epoch_date(merged.get("mtime")));

        if is_bookmark {
            let Some(valid_url) = source_url else {
                skipped_missing_count += 1;
                continue;
            };
            let title = if !raw_name.is_empty() {
                raw_name
            } else {
                valid_url
                    .host_str()
                    .unwrap_or(valid_url.as_str())
                    .to_string()
            };
            items.push(ParsedEagleAsset {
                source_id: item_id,
                title,
                file_path: payload,
                thumbnail_path: thumbnail,
                is_web_bookmark: true,
                source_url: Some(valid_url),
                tags,
                rating,
                notes,
                folder_ids,
                created_at,
                updated_at,
            });
            continue;
        }

        let Some(payload_path) = payload else {
            skipped_missing_count += 1;
            continue;
        };
        let file_size = fs::metadata(&payload_path).map(|m| m.len()).unwrap_or(0);
        if file_size == 0 {
            skipped_missing_count += 1;
            continue;
        }
        let title = if !raw_name.is_empty() {
            raw_name
        } else {
            payload_path
                .file_stem()
                .and_then(|s| s.to_str())
                .unwrap_or("Reference")
                .to_string()
        };
        items.push(ParsedEagleAsset {
            source_id: item_id,
            title,
            file_path: Some(payload_path),
            thumbnail_path: thumbnail,
            is_web_bookmark: false,
            source_url,
            tags,
            rating,
            notes,
            folder_ids,
            created_at,
            updated_at,
        });
    }

    Ok(ParsedEaglePackage {
        package_name,
        root_folders,
        items,
        skipped_deleted_count,
        skipped_missing_count,
        staging_directory_to_cleanup,
    })
}

fn parse_folder_list(
    raw_list: &[&Map<String, Value>],
    depth: usize,
    visited: &mut HashSet<String>,
) -> Vec<ParsedEagleFolder> {
    if depth >= EaglePackImporter::MAX_FOLDER_DEPTH {
        return Vec::new();
    }
    let mut result = Vec::with_capacity(raw_list.len());
    for raw in raw_list {
        let raw_id = string_value(raw.get("id")).unwrap_or_else(|| Uuid::new_v4().to_string());
        if !visited.insert(raw_id.clone()) {
            continue;
        }
        let name = string_value(raw.get("name")).unwrap_or_else(|| "未命名文件夹".to_string());
        let color_hex =
            EaglePackImporter::map_folder_color_hex(string_value(raw.get("iconColor")).as_deref());
        let raw_children: Vec<&Map<String, Value>> = raw
            .get("children")
            .and_then(Value::as_array)
            .map(|arr| arr.iter().filter_map(Value::as_object).collect())
            .unwrap_or_default();
        let children = parse_folder_list(&raw_children, depth + 1, visited);
        result.push(ParsedEagleFolder {
            source_id: raw_id,
            name,
            color_hex,
            children,
        });
    }
    result
}

fn resolve_media_and_thumbnail(
    info_dir: &Path,
    canon_root: &Path,
    preferred_name: &str,
    preferred_ext: &str,
) -> (Option<PathBuf>, Option<PathBuf>) {
    let Ok(read_dir) = fs::read_dir(info_dir) else {
        return (None, None);
    };

    let mut regular_files: Vec<(PathBuf, u64)> = Vec::new();
    let mut thumbnail_candidate: Option<PathBuf> = None;

    for entry in read_dir.flatten() {
        let path = entry.path();
        let Some(name) = path.file_name().and_then(|n| n.to_str()) else {
            continue;
        };
        let lower = name.to_ascii_lowercase();
        if lower == "metadata.json" || name.starts_with('.') || name.starts_with("._") {
            continue;
        }
        let Ok(sym_meta) = fs::symlink_metadata(&path) else {
            continue;
        };
        if sym_meta.file_type().is_symlink() || !sym_meta.is_file() {
            continue;
        }
        let Ok(canon) = fs::canonicalize(&path) else {
            continue;
        };
        if !canon.starts_with(canon_root) {
            continue;
        }

        let stem_lower = path
            .file_stem()
            .and_then(|s| s.to_str())
            .unwrap_or("")
            .to_ascii_lowercase();
        if stem_lower == "_thumbnail" || stem_lower.ends_with("_thumbnail") {
            if thumbnail_candidate.is_none() || lower.ends_with(".png") {
                thumbnail_candidate = Some(canon);
            }
            continue;
        }
        regular_files.push((canon, sym_meta.len()));
    }

    if regular_files.is_empty() {
        return (None, thumbnail_candidate);
    }

    // 1. Exact `<name>.<ext>` or cross-platform sanitized match
    if !preferred_name.is_empty() {
        let expected = if preferred_ext.is_empty() {
            preferred_name.to_string()
        } else {
            format!("{preferred_name}.{preferred_ext}")
        };
        if let Some((exact, _)) = regular_files
            .iter()
            .find(|(p, _)| p.file_name().and_then(|n| n.to_str()) == Some(expected.as_str()))
        {
            return (Some(exact.clone()), thumbnail_candidate);
        }
        let sanitized = sanitize_cross_platform_filename(&expected);
        if let Some((matched, _)) = regular_files.iter().find(|(p, _)| {
            p.file_name().and_then(|n| n.to_str()).is_some_and(|n| {
                n.eq_ignore_ascii_case(&expected) || n.eq_ignore_ascii_case(&sanitized)
            })
        }) {
            return (Some(matched.clone()), thumbnail_candidate);
        }
    }

    // 2. Same extension, largest regular file
    if !preferred_ext.is_empty() {
        if let Some((best, _)) = regular_files
            .iter()
            .filter(|(p, _)| {
                p.extension()
                    .and_then(|e| e.to_str())
                    .is_some_and(|e| e.eq_ignore_ascii_case(preferred_ext))
            })
            .max_by_key(|(_, sz)| *sz)
        {
            return (Some(best.clone()), thumbnail_candidate);
        }
    }

    // 3. Largest remaining regular file
    let fallback = regular_files
        .iter()
        .max_by_key(|(_, sz)| *sz)
        .map(|(p, _)| p.clone());
    (fallback, thumbnail_candidate)
}

fn sanitize_cross_platform_filename(raw: &str) -> String {
    raw.chars()
        .map(|c| {
            if matches!(c, '/' | '\\' | ':' | '*' | '?' | '"' | '<' | '>' | '|') {
                '_'
            } else {
                c
            }
        })
        .collect()
}

fn merge_metadata(
    sidecar: Option<&Map<String, Value>>,
    manifest: Option<&Map<String, Value>>,
) -> Map<String, Value> {
    let mut result = manifest.cloned().unwrap_or_default();
    let Some(sidecar) = sidecar else {
        return result;
    };
    for (k, v) in sidecar {
        match v {
            Value::Null => {}
            Value::String(s) if s.trim().is_empty() => {
                result.entry(k.clone()).or_insert_with(|| v.clone());
            }
            Value::Array(arr) if arr.is_empty() => {
                result.entry(k.clone()).or_insert_with(|| v.clone());
            }
            _ => {
                result.insert(k.clone(), v.clone());
            }
        }
    }
    result
}

fn parse_web_url(raw: Option<&str>) -> Option<Url> {
    let trimmed = raw?.trim();
    if trimmed.is_empty() {
        return None;
    }
    let url = Url::parse(trimmed).ok()?;
    if matches!(url.scheme(), "http" | "https") && url.host_str().is_some() {
        Some(url)
    } else {
        None
    }
}

fn parse_rating(dict: &Map<String, Value>) -> i32 {
    let raw = dict.get("star").or_else(|| dict.get("rating"));
    let val = match raw {
        Some(Value::Number(n)) => n
            .as_i64()
            .or_else(|| {
                n.as_f64()
                    .filter(|f| f.is_finite())
                    .map(|f| f.round() as i64)
            })
            .unwrap_or(0),
        Some(Value::String(s)) => s.trim().parse::<i64>().unwrap_or(0),
        _ => 0,
    };
    (val as i32).clamp(0, 5)
}

fn parse_string_list(raw: Option<&Value>) -> Vec<String> {
    let Some(arr) = raw.and_then(Value::as_array) else {
        return Vec::new();
    };
    let mut seen = HashSet::new();
    let mut out = Vec::new();
    for entry in arr {
        let Some(text) = entry.as_str().map(str::trim).filter(|s| !s.is_empty()) else {
            continue;
        };
        if seen.insert(text.to_lowercase()) {
            out.push(text.to_string());
        }
    }
    out
}

fn string_value(raw: Option<&Value>) -> Option<String> {
    raw.and_then(Value::as_str)
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .map(String::from)
}

fn bool_value(raw: Option<&Value>) -> Option<bool> {
    match raw? {
        Value::Bool(b) => Some(*b),
        Value::Number(n) => n.as_i64().map(|v| v != 0),
        Value::String(s) => match s.trim().to_ascii_lowercase().as_str() {
            "true" | "1" | "yes" => Some(true),
            "false" | "0" | "no" => Some(false),
            _ => None,
        },
        _ => None,
    }
}

fn load_json_object(path: &Path) -> Option<Map<String, Value>> {
    let mut file = File::open(path).ok()?;
    let mut buf = Vec::new();
    file.read_to_end(&mut buf).ok()?;
    let val: Value = serde_json::from_slice(&buf).ok()?;
    val.as_object().cloned()
}

fn clean_package_display_name(path: &Path) -> String {
    let stem = path
        .file_stem()
        .and_then(|s| s.to_str())
        .map(str::trim)
        .unwrap_or("");
    if stem.is_empty() {
        "导入素材包".to_string()
    } else {
        stem.to_string()
    }
}

fn unwrap_single_top_level_dir(dir: &Path) -> PathBuf {
    if dir.join("pack.json").is_file() || dir.join("metadata.json").is_file() {
        return dir.to_path_buf();
    }
    let Ok(read_dir) = fs::read_dir(dir) else {
        return dir.to_path_buf();
    };
    let meaningful: Vec<PathBuf> = read_dir
        .flatten()
        .map(|e| e.path())
        .filter(|p| {
            p.file_name()
                .and_then(|n| n.to_str())
                .is_some_and(|n| n != "__MACOSX" && !n.starts_with('.'))
        })
        .collect();
    if meaningful.len() == 1 {
        let only = &meaningful[0];
        let is_info = only
            .extension()
            .and_then(|e| e.to_str())
            .is_some_and(|e| e.eq_ignore_ascii_case("info"));
        if only.is_dir() && !is_info {
            return only.clone();
        }
    }
    dir.to_path_buf()
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;
    use tempfile::tempdir;
    use zip::write::SimpleFileOptions;

    fn tiny_png_bytes() -> Vec<u8> {
        let img = image::DynamicImage::ImageRgba8(image::RgbaImage::from_pixel(
            16,
            16,
            image::Rgba([64, 128, 224, 255]),
        ));
        crate::media::artwork::MediaArtwork::encode_png(&img).unwrap()
    }

    #[test]
    fn maps_folder_colors_and_parses_epoch_timestamps_and_bookmarks() {
        assert_eq!(
            EaglePackImporter::map_folder_color_hex(Some("aqua")).as_deref(),
            Some("#06B6D4")
        );
        assert_eq!(
            EaglePackImporter::map_folder_color_hex(Some("#2a60e0")).as_deref(),
            Some("#2A60E0")
        );
        assert_eq!(
            EaglePackImporter::map_folder_color_hex(Some("unknown")),
            None
        );

        // Milliseconds and seconds both parse accurately
        let ms_dt =
            EaglePackImporter::parse_epoch_date(Some(&serde_json::json!(1_700_000_000_000i64)))
                .expect("ms date");
        assert_eq!(ms_dt.timestamp(), 1_700_000_000);
        let sec_dt =
            EaglePackImporter::parse_epoch_date(Some(&serde_json::json!(1_700_000_000i64)))
                .expect("sec date");
        assert_eq!(sec_dt.timestamp(), 1_700_000_000);
        // Reject out-of-range year 1975
        assert!(
            EaglePackImporter::parse_epoch_date(Some(&serde_json::json!(157_766_400i64))).is_none()
        );

        // InternetShortcut rejects file:// and accepts https://
        let bad_url = b"[InternetShortcut]\r\nURL=file:///C:/Windows/win.ini\r\n";
        assert!(EaglePackImporter::parse_internet_shortcut_url(bad_url).is_none());
        let ok_url = b"[InternetShortcut]\r\nURL=https://charkle.app/docs\r\n";
        assert_eq!(
            EaglePackImporter::parse_internet_shortcut_url(ok_url)
                .unwrap()
                .as_str(),
            "https://charkle.app/docs"
        );
    }

    #[test]
    fn rejects_zip_slip_and_drive_letter_traversal_archives() {
        let tmp = tempdir().unwrap();
        let bad_zip = tmp.path().join("evil.eaglepack");
        {
            let f = File::create(&bad_zip).unwrap();
            let mut zw = zip::ZipWriter::new(f);
            zw.start_file("../evil.png", SimpleFileOptions::default())
                .unwrap();
            zw.write_all(&tiny_png_bytes()).unwrap();
            zw.finish().unwrap();
        }
        let err = EaglePackImporter::unpack_and_parse(&bad_zip, false).unwrap_err();
        assert!(err.to_string().contains("不安全的路径"));

        let bad_drive = tmp.path().join("drive.eaglepack");
        {
            let f = File::create(&bad_drive).unwrap();
            let mut zw = zip::ZipWriter::new(f);
            zw.start_file("C:/temp/evil.png", SimpleFileOptions::default())
                .unwrap();
            zw.write_all(&tiny_png_bytes()).unwrap();
            zw.finish().unwrap();
        }
        assert!(EaglePackImporter::unpack_and_parse(&bad_drive, false).is_err());
    }

    #[test]
    fn parses_wrapped_eaglepack_zip_with_macosx_nested_folders_bookmarks_and_deleted_skip() {
        let tmp = tempdir().unwrap();
        let pack_path = tmp.path().join("DesignRefs.eaglepack");
        let png = tiny_png_bytes();

        let pack_json = serde_json::json!({
            "folder": {
                "id": "F_ROOT",
                "name": "Poster Studies",
                "iconColor": "blue",
                "children": [
                    { "id": "F_SUB", "name": "Swiss Grid", "iconColor": "red", "children": [] }
                ]
            },
            "images": [
                {
                    "id": "ITEM_1",
                    "name": "UI / Hero Reference",
                    "ext": "png",
                    "tags": ["Swiss", "swiss", "Grid"],
                    "star": 5,
                    "annotation": "Bold negative space",
                    "url": "https://example.com/poster",
                    "btime": 1_710_000_000_000i64,
                    "folders": ["F_SUB"]
                },
                {
                    "id": "ITEM_DEL",
                    "name": "Deleted Item",
                    "ext": "png",
                    "isDeleted": true,
                    "folders": ["F_ROOT"]
                },
                {
                    "id": "ITEM_BM",
                    "name": "Offline Bookmark",
                    "ext": "url",
                    "tags": ["Web"],
                    "folders": ["F_ROOT"]
                }
            ]
        });

        {
            let f = File::create(&pack_path).unwrap();
            let mut zw = zip::ZipWriter::new(f);
            let opts = SimpleFileOptions::default();
            // Add __MACOSX noise + single top-level wrapper folder
            zw.start_file("__MACOSX/._pack.json", opts).unwrap();
            zw.write_all(b"junk").unwrap();
            zw.start_file("WrappedRoot/pack.json", opts).unwrap();
            zw.write_all(pack_json.to_string().as_bytes()).unwrap();
            // ITEM_1 payload with cross-platform `/` -> `_` filename plus sidecar thumbnail
            zw.start_file(
                "WrappedRoot/images/ITEM_1.info/UI _ Hero Reference.png",
                opts,
            )
            .unwrap();
            zw.write_all(&png).unwrap();
            zw.start_file(
                "WrappedRoot/images/ITEM_1.info/UI _ Hero Reference_thumbnail.png",
                opts,
            )
            .unwrap();
            zw.write_all(&png).unwrap();
            zw.start_file("WrappedRoot/images/ITEM_1.info/metadata.json", opts)
                .unwrap();
            zw.write_all(br#"{"id":"ITEM_1","rating":4}"#).unwrap();
            // ITEM_DEL
            zw.start_file("WrappedRoot/images/ITEM_DEL.info/Deleted Item.png", opts)
                .unwrap();
            zw.write_all(&png).unwrap();
            // ITEM_BM offline .url + pre-rendered thumbnail
            zw.start_file("WrappedRoot/images/ITEM_BM.info/Offline Bookmark.url", opts)
                .unwrap();
            zw.write_all(b"[InternetShortcut]\r\nURL=https://charkle.app/design\r\n")
                .unwrap();
            zw.start_file(
                "WrappedRoot/images/ITEM_BM.info/Offline Bookmark_thumbnail.png",
                opts,
            )
            .unwrap();
            zw.write_all(&png).unwrap();
            zw.finish().unwrap();
        }

        assert!(EaglePackImporter::is_recognized_material_package(
            &pack_path, false
        ));
        let parsed = EaglePackImporter::unpack_and_parse(&pack_path, false).unwrap();
        let staging = parsed.staging_directory_to_cleanup.clone().unwrap();
        assert_eq!(parsed.package_name, "Poster Studies");
        assert_eq!(parsed.root_folders.len(), 1);
        assert_eq!(parsed.root_folders[0].color_hex.as_deref(), Some("#3B82F6"));
        assert_eq!(
            parsed.root_folders[0].children[0].color_hex.as_deref(),
            Some("#EF4444")
        );
        assert_eq!(parsed.skipped_deleted_count, 1);
        assert_eq!(parsed.items.len(), 2);

        let first = &parsed.items[0];
        assert_eq!(first.title, "UI / Hero Reference");
        assert_eq!(first.tags, vec!["Swiss".to_string(), "Grid".to_string()]);
        assert_eq!(first.rating, 5);
        assert_eq!(first.notes, "Bold negative space");
        assert!(first.file_path.as_ref().unwrap().exists());
        assert_eq!(first.created_at.unwrap().timestamp(), 1_710_000_000);

        let bm = &parsed.items[1];
        assert!(bm.is_web_bookmark);
        assert_eq!(
            bm.source_url.as_ref().map(Url::as_str),
            Some("https://charkle.app/design")
        );
        assert!(bm.thumbnail_path.as_ref().unwrap().exists());

        fs::remove_dir_all(&staging).unwrap();
    }
}
