//! Native GitHub Releases in-app update checking, Windows NSIS installer selection,
//! Windows-scoped SHA-256 extraction, streaming download + verification, and 6-hour throttle
//! preferences. Mirrors macOS `Sources/CharkleCore/Services/GitHubReleaseUpdater.swift`
//! for cross-platform behavioral parity while targeting Windows x64 NSIS installers.

use std::cmp::Ordering;
use std::fmt;
use std::fs::{self, File};
use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering as AtomicOrdering};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use reqwest::header::{ACCEPT, USER_AGENT};
use reqwest::StatusCode;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use thiserror::Error;
use url::Url;
use uuid::Uuid;

pub const DEFAULT_GITHUB_OWNER: &str = "CharTyr";
pub const DEFAULT_GITHUB_REPO: &str = "Charkle";
pub const DEFAULT_MINIMUM_CHECK_INTERVAL_MS: i64 = 6 * 60 * 60 * 1000;
pub const UPDATE_PREFERENCES_FILENAME: &str = "update-preferences.json";
pub const DEFAULT_MAX_INSTALLER_BYTES: u64 = 512 * 1024 * 1024;
pub const DEFAULT_MIN_INSTALLER_BYTES: u64 = 64 * 1024;

// =========================================================================
// Semantic Versioning
// =========================================================================

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CharkleSemanticVersion {
    pub major: u64,
    pub minor: u64,
    pub patch: u64,
    pub prerelease: Vec<String>,
}

impl CharkleSemanticVersion {
    /// Parses `v1.2.3`, `1.2.3`, `1.2`, `1.2.3-beta.1+build.9` (build metadata ignored for ordering).
    pub fn parse(raw: &str) -> Option<Self> {
        let trimmed = raw.trim();
        if trimmed.is_empty() {
            return None;
        }
        let without_v = trimmed
            .strip_prefix('v')
            .or_else(|| trimmed.strip_prefix('V'))
            .unwrap_or(trimmed);
        if without_v.is_empty() {
            return None;
        }

        // Strip `+build` metadata
        let without_build = without_v.split('+').next().unwrap_or(without_v);
        if without_build.is_empty() {
            return None;
        }

        // Split core and optional `-prerelease`
        let (core_str, pre_opt) = match without_build.split_once('-') {
            Some((core, pre)) => (core, Some(pre)),
            None => (without_build, None),
        };

        let core_parts: Vec<&str> = core_str.split('.').collect();
        if core_parts.len() < 2 || core_parts.len() > 3 {
            return None;
        }

        let parse_u64 = |part: &str| -> Option<u64> {
            if part.is_empty() || !part.bytes().all(|b| b.is_ascii_digit()) {
                return None;
            }
            part.parse::<u64>().ok()
        };

        let major = parse_u64(core_parts[0])?;
        let minor = parse_u64(core_parts[1])?;
        let patch = if core_parts.len() == 3 {
            parse_u64(core_parts[2])?
        } else {
            0
        };

        let prerelease = if let Some(pre) = pre_opt {
            if pre.is_empty() {
                return None;
            }
            let segments: Vec<String> = pre.split('.').map(str::to_string).collect();
            if segments.iter().any(|s| s.is_empty()) {
                return None;
            }
            segments
        } else {
            Vec::new()
        };

        Some(Self {
            major,
            minor,
            patch,
            prerelease,
        })
    }

    pub fn normalized(&self) -> String {
        let base = format!("{}.{}.{}", self.major, self.minor, self.patch);
        if self.prerelease.is_empty() {
            base
        } else {
            format!("{base}-{}", self.prerelease.join("."))
        }
    }
}

impl fmt::Display for CharkleSemanticVersion {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.normalized())
    }
}

impl Ord for CharkleSemanticVersion {
    fn cmp(&self, other: &Self) -> Ordering {
        self.major
            .cmp(&other.major)
            .then_with(|| self.minor.cmp(&other.minor))
            .then_with(|| self.patch.cmp(&other.patch))
            .then_with(
                || match (self.prerelease.is_empty(), other.prerelease.is_empty()) {
                    (true, true) => Ordering::Equal,
                    (true, false) => Ordering::Greater,
                    (false, true) => Ordering::Less,
                    (false, false) => {
                        for (lhs, rhs) in self.prerelease.iter().zip(other.prerelease.iter()) {
                            let lhs_num = lhs
                                .bytes()
                                .all(|b| b.is_ascii_digit())
                                .then(|| lhs.parse::<u64>().ok())
                                .flatten();
                            let rhs_num = rhs
                                .bytes()
                                .all(|b| b.is_ascii_digit())
                                .then(|| rhs.parse::<u64>().ok())
                                .flatten();
                            let ord = match (lhs_num, rhs_num) {
                                (Some(a), Some(b)) => a.cmp(&b),
                                (Some(_), None) => Ordering::Less,
                                (None, Some(_)) => Ordering::Greater,
                                (None, None) => lhs.cmp(rhs),
                            };
                            if ord != Ordering::Equal {
                                return ord;
                            }
                        }
                        self.prerelease.len().cmp(&other.prerelease.len())
                    }
                },
            )
    }
}

impl PartialOrd for CharkleSemanticVersion {
    fn partial_cmp(&self, other: &Self) -> Option<Ordering> {
        Some(self.cmp(other))
    }
}

// =========================================================================
// GitHub Release DTOs & Domain Models
// =========================================================================

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct GitHubReleaseAssetDto {
    pub name: String,
    pub browser_download_url: String,
    pub size: u64,
    #[serde(default)]
    pub content_type: Option<String>,
    #[serde(default)]
    pub digest: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct GitHubReleaseDto {
    pub tag_name: String,
    #[serde(default)]
    pub name: Option<String>,
    #[serde(default)]
    pub body: Option<String>,
    pub html_url: String,
    #[serde(default)]
    pub draft: bool,
    #[serde(default)]
    pub prerelease: bool,
    #[serde(default)]
    pub published_at: Option<String>,
    #[serde(default)]
    pub assets: Vec<GitHubReleaseAssetDto>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AppReleaseUpdate {
    pub tag_name: String,
    pub version: String,
    pub title: String,
    pub release_notes: String,
    pub html_url: String,
    pub published_at: Option<String>,
    pub asset_name: String,
    pub download_url: String,
    pub asset_size_bytes: u64,
    pub expected_sha256: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum UpdateCheckOutcome {
    #[serde(rename_all = "camelCase")]
    UpToDate { latest_version: String },
    #[serde(rename_all = "camelCase")]
    UpdateAvailable { update: AppReleaseUpdate },
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct UpdateDownloadProgress {
    pub tag_name: String,
    pub downloaded_bytes: u64,
    pub total_bytes: u64,
    pub fraction: f64,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct VerifiedUpdateInstaller {
    pub tag_name: String,
    pub version: String,
    pub installer_path: String,
    pub file_name: String,
    pub verified_sha256: String,
    pub size_bytes: u64,
    pub checksum_verified_against_release: bool,
}

// =========================================================================
// Preferences & Throttle Policy
// =========================================================================

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct UpdatePreferences {
    #[serde(default = "default_auto_check")]
    pub auto_check_updates: bool,
    #[serde(default)]
    pub last_update_check_at_ms: Option<i64>,
    #[serde(default)]
    pub skipped_version: Option<String>,
}

fn default_auto_check() -> bool {
    true
}

impl Default for UpdatePreferences {
    fn default() -> Self {
        Self {
            auto_check_updates: true,
            last_update_check_at_ms: None,
            skipped_version: None,
        }
    }
}

impl UpdatePreferences {
    pub fn file_path(data_dir: &Path) -> PathBuf {
        data_dir.join(UPDATE_PREFERENCES_FILENAME)
    }

    pub fn load(data_dir: &Path) -> Self {
        let path = Self::file_path(data_dir);
        let Ok(raw) = fs::read_to_string(&path) else {
            return Self::default();
        };
        serde_json::from_str::<Self>(&raw).unwrap_or_default()
    }

    pub fn save(&self, data_dir: &Path) -> Result<(), UpdaterError> {
        fs::create_dir_all(data_dir).map_err(|e| UpdaterError::Io(e.to_string()))?;
        let path = Self::file_path(data_dir);
        let tmp_path = data_dir.join(format!(
            "{UPDATE_PREFERENCES_FILENAME}.{}.tmp",
            Uuid::new_v4().simple()
        ));
        let payload =
            serde_json::to_string_pretty(self).map_err(|e| UpdaterError::Io(e.to_string()))?;
        fs::write(&tmp_path, payload).map_err(|e| UpdaterError::Io(e.to_string()))?;
        if let Err(rename_err) = fs::rename(&tmp_path, &path) {
            // Windows rename may fail if target exists across antivirus locks; fall back to copy+remove.
            let write_res = fs::write(
                &path,
                fs::read(&tmp_path).map_err(|e| UpdaterError::Io(e.to_string()))?,
            );
            let _ = fs::remove_file(&tmp_path);
            write_res.map_err(|_| UpdaterError::Io(rename_err.to_string()))?;
        }
        Ok(())
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct AppUpdateCheckPolicy {
    pub minimum_interval_ms: i64,
}

impl Default for AppUpdateCheckPolicy {
    fn default() -> Self {
        Self {
            minimum_interval_ms: DEFAULT_MINIMUM_CHECK_INTERVAL_MS,
        }
    }
}

impl AppUpdateCheckPolicy {
    pub fn new(minimum_interval_ms: i64) -> Self {
        Self {
            minimum_interval_ms: minimum_interval_ms.max(0),
        }
    }

    pub fn should_perform_automatic_check(&self, prefs: &UpdatePreferences, now_ms: i64) -> bool {
        if !prefs.auto_check_updates {
            return false;
        }
        let Some(last) = prefs.last_update_check_at_ms else {
            return true;
        };
        now_ms.saturating_sub(last) >= self.minimum_interval_ms
    }

    pub fn is_version_skipped(version: &str, skipped_version: Option<&str>) -> bool {
        let Some(skipped) = skipped_version.map(str::trim).filter(|s| !s.is_empty()) else {
            return false;
        };
        let candidate = version.trim();
        if candidate.is_empty() {
            return false;
        }
        if let (Some(lhs), Some(rhs)) = (
            CharkleSemanticVersion::parse(candidate),
            CharkleSemanticVersion::parse(skipped),
        ) {
            return lhs == rhs;
        }
        candidate.eq_ignore_ascii_case(skipped)
    }

    pub fn should_notify_for_update(
        &self,
        update: &AppReleaseUpdate,
        skipped_version: Option<&str>,
        manual: bool,
    ) -> bool {
        if manual {
            return true;
        }
        !Self::is_version_skipped(&update.version, skipped_version)
            && !Self::is_version_skipped(&update.tag_name, skipped_version)
    }
}

// =========================================================================
// Typed Error
// =========================================================================

#[derive(Debug, Error)]
pub enum UpdaterError {
    #[error("无效的版本号：{0}")]
    InvalidVersion(String),
    #[error("GitHub API 请求频率受限，请稍后再试或直接前往 Release 页面查看。")]
    RateLimited,
    #[error("无法连接到更新服务（HTTP {status}）：{message}")]
    HttpStatus { status: u16, message: String },
    #[error("检查或下载更新时网络异常：{0}")]
    Network(String),
    #[error("无法解析 GitHub Release 更新数据：{0}")]
    InvalidResponse(String),
    #[error("已拒绝不安全的更新下载地址：{0}")]
    InsecureDownloadUrl(String),
    #[error("下载的安装包无效或已损坏：{0}")]
    InvalidInstallerFile(String),
    #[error("安装包 SHA-256 校验未通过（期望 {expected}，实际 {actual}），已自动删除下载文件。")]
    ChecksumMismatch { expected: String, actual: String },
    #[error("已取消更新下载。")]
    Cancelled,
    #[error("本地文件系统错误：{0}")]
    Io(String),
}

// =========================================================================
// Asset Selection & Windows-Scoped SHA-256 Extraction
// =========================================================================

const ALLOWED_RELEASE_DOWNLOAD_DOMAINS: &[&str] = &["github.com", "githubusercontent.com"];

const ALLOWED_RELEASE_REDIRECT_DOMAINS: &[&str] = &[
    "github.com",
    "githubusercontent.com",
    "blob.core.windows.net",
];

fn host_matches_domain_list(url: &Url, allowed_domains: &[&str]) -> bool {
    if !url.scheme().eq_ignore_ascii_case("https")
        || !url.username().is_empty()
        || url.password().is_some()
    {
        return false;
    }
    let Some(raw_host) = url.host_str() else {
        return false;
    };
    let host = raw_host.trim_end_matches('.').to_ascii_lowercase();
    allowed_domains.iter().any(|domain| {
        host == *domain
            || (host.len() > domain.len()
                && host.ends_with(domain)
                && host.as_bytes()[host.len() - domain.len() - 1] == b'.')
    })
}

/// Validates that an update installer download URL uses HTTPS and targets official GitHub Release hosts.
pub fn is_allowed_github_release_url(raw: &str) -> bool {
    Url::parse(raw.trim())
        .map(|u| host_matches_domain_list(&u, ALLOWED_RELEASE_DOWNLOAD_DOMAINS))
        .unwrap_or(false)
}

/// Selects the best Windows installer `.exe` asset from a GitHub Release.
/// Explicitly excludes macOS `.dmg`/`.pkg` and non-HTTPS download URLs.
pub fn select_windows_installer_asset(
    assets: &[GitHubReleaseAssetDto],
) -> Option<&GitHubReleaseAssetDto> {
    let mut best: Option<(i32, &GitHubReleaseAssetDto)> = None;

    for asset in assets {
        let lower_name = asset.name.trim().to_ascii_lowercase();
        if !lower_name.ends_with(".exe") {
            continue;
        }
        if lower_name.contains("macos")
            || lower_name.contains("darwin")
            || lower_name.contains(".dmg")
            || lower_name.contains(".pkg")
        {
            continue;
        }
        if !is_allowed_github_release_url(&asset.browser_download_url) {
            continue;
        }

        let mut score = 10;
        if lower_name.contains("x64-setup.exe") || lower_name.contains("x64_setup.exe") {
            score += 100;
        } else if lower_name.contains("setup.exe") {
            score += 70;
        }
        if lower_name.contains("x64")
            || lower_name.contains("win64")
            || lower_name.contains("amd64")
        {
            score += 25;
        }
        if lower_name.contains("windows") || lower_name.contains("win") {
            score += 15;
        }
        if lower_name.contains("charkle") {
            score += 10;
        }
        // Deprioritize arm64/x86 on x64 builds when x64 is available
        if lower_name.contains("arm64") || lower_name.contains("x86") || lower_name.contains("ia32")
        {
            score -= 20;
        }

        if best
            .map(|(best_score, _)| score > best_score)
            .unwrap_or(true)
        {
            best = Some((score, asset));
        }
    }

    best.map(|(_, asset)| asset)
}

/// Extracts a 64-hex lowercase SHA-256 digest from GitHub Releases' native `asset.digest`
/// field (typically formatted as `sha256:<64-hex>`).
pub fn extract_sha256_from_asset_digest(digest: Option<&str>) -> Option<String> {
    let raw = digest?.trim();
    let candidate = raw
        .strip_prefix("sha256:")
        .or_else(|| raw.strip_prefix("SHA256:"))
        .unwrap_or(raw)
        .trim();
    if is_sha256_hex(candidate) {
        Some(candidate.to_ascii_lowercase())
    } else {
        None
    }
}

fn is_sha256_hex(token: &str) -> bool {
    token.len() == 64 && token.bytes().all(|b| b.is_ascii_hexdigit())
}

fn extract_first_sha256_in_text(text: &str) -> Option<String> {
    for token in text.split(|c: char| !c.is_ascii_hexdigit()) {
        if token.len() == 64 {
            return Some(token.to_ascii_lowercase());
        }
    }
    None
}

fn markdown_heading_level(line: &str) -> Option<(usize, &str)> {
    let trimmed = line.trim_start();
    let hashes = trimmed.bytes().take_while(|&b| b == b'#').count();
    if hashes == 0 || hashes > 6 {
        return None;
    }
    let rest = &trimmed[hashes..];
    if !rest.starts_with(' ') && !rest.starts_with('\t') {
        return None;
    }
    Some((hashes, rest.trim()))
}

fn extract_section_by_platform(body: &str, want_windows: bool) -> String {
    let mut collecting_level: Option<usize> = None;
    let mut out = String::new();

    for line in body.lines() {
        if let Some((level, title)) = markdown_heading_level(line) {
            let lower = title.to_ascii_lowercase();
            let is_win_heading = lower.contains("windows");
            let is_mac_heading = lower.contains("macos") || lower.contains("mac os");
            let matches_target = if want_windows {
                is_win_heading && !is_mac_heading
            } else {
                is_mac_heading && !is_win_heading
            };

            if matches_target {
                collecting_level = Some(level);
                out.push_str(line);
                out.push('\n');
                continue;
            }
            if let Some(active_level) = collecting_level {
                if level <= active_level {
                    collecting_level = None;
                }
            }
        }
        if collecting_level.is_some() {
            out.push_str(line);
            out.push('\n');
        }
    }

    out
}

fn strip_macos_sections(body: &str) -> String {
    let mut skipping_level: Option<usize> = None;
    let mut out = String::new();

    for line in body.lines() {
        if let Some((level, title)) = markdown_heading_level(line) {
            let lower = title.to_ascii_lowercase();
            let is_mac_heading =
                (lower.contains("macos") || lower.contains("mac os")) && !lower.contains("windows");
            if is_mac_heading {
                skipping_level = Some(level);
                continue;
            }
            if let Some(active_level) = skipping_level {
                if level <= active_level {
                    skipping_level = None;
                }
            }
        }
        if skipping_level.is_none() {
            out.push_str(line);
            out.push('\n');
        }
    }

    out
}

fn is_macos_line(lower_line: &str) -> bool {
    lower_line.contains(".dmg")
        || lower_line.contains(".pkg")
        || lower_line.contains("macos")
        || lower_line.contains("apple silicon")
        || lower_line.contains("arm64.dmg")
}

/// Extracts a Windows-scoped SHA-256 checksum from a dual-platform GitHub Release body.
/// Guarantees macOS `.dmg` hashes under `## macOS` sections are never picked on Windows.
pub fn extract_windows_sha256_from_body(body: &str, asset_name: &str) -> Option<String> {
    let trimmed_body = body.trim();
    if trimmed_body.is_empty() {
        return None;
    }
    let lower_asset = asset_name.trim().to_ascii_lowercase();
    let lines: Vec<&str> = trimmed_body.lines().collect();

    // Priority 1: exact asset filename match (same line or immediately following line)
    if !lower_asset.is_empty() {
        for (idx, line) in lines.iter().enumerate() {
            let lower = line.to_ascii_lowercase();
            if lower.contains(&lower_asset) {
                if let Some(hash) = extract_first_sha256_in_text(line) {
                    return Some(hash);
                }
                if let Some(next_line) = lines.get(idx + 1) {
                    if !is_macos_line(&next_line.to_ascii_lowercase()) {
                        if let Some(hash) = extract_first_sha256_in_text(next_line) {
                            return Some(hash);
                        }
                    }
                }
            }
        }
    }

    // Priority 2: dedicated `## Windows` / `### Windows` section
    let windows_section = extract_section_by_platform(trimmed_body, true);
    if !windows_section.is_empty() {
        let win_lines: Vec<&str> = windows_section.lines().collect();
        for line in &win_lines {
            let lower = line.to_ascii_lowercase();
            if is_macos_line(&lower) {
                continue;
            }
            if lower.contains(".exe")
                || lower.contains("setup")
                || lower.contains("x64")
                || lower.contains("windows")
            {
                if let Some(hash) = extract_first_sha256_in_text(line) {
                    return Some(hash);
                }
            }
        }
        for (idx, line) in win_lines.iter().enumerate() {
            let lower = line.to_ascii_lowercase();
            if is_macos_line(&lower) {
                continue;
            }
            if lower.contains("sha-256") || lower.contains("sha256") || lower.contains("校验") {
                if let Some(hash) = extract_first_sha256_in_text(line) {
                    return Some(hash);
                }
                if let Some(next_line) = win_lines.get(idx + 1) {
                    if !is_macos_line(&next_line.to_ascii_lowercase()) {
                        if let Some(hash) = extract_first_sha256_in_text(next_line) {
                            return Some(hash);
                        }
                    }
                }
            }
        }
    }

    // Priority 3: body stripped of macOS sections, requiring explicit Windows/`.exe` marker on the line
    let non_macos_body = strip_macos_sections(trimmed_body);
    for line in non_macos_body.lines() {
        let lower = line.to_ascii_lowercase();
        if is_macos_line(&lower) {
            continue;
        }
        if lower.contains(".exe") || lower.contains("setup.exe") || lower.contains("windows") {
            if let Some(hash) = extract_first_sha256_in_text(line) {
                return Some(hash);
            }
        }
    }

    None
}

/// Resolves the expected SHA-256 for a Windows release asset: prefers Windows-scoped release
/// notes checksum and falls back to GitHub API's native `asset.digest`.
pub fn resolve_expected_windows_sha256(
    body: Option<&str>,
    asset: &GitHubReleaseAssetDto,
) -> Option<String> {
    body.and_then(|text| extract_windows_sha256_from_body(text, &asset.name))
        .or_else(|| extract_sha256_from_asset_digest(asset.digest.as_deref()))
}

// =========================================================================
// GitHubReleaseUpdater Client
// =========================================================================

#[derive(Debug, Clone)]
pub struct GitHubReleaseUpdater {
    owner: String,
    repo: String,
    api_base_url: String,
    client: reqwest::Client,
    min_installer_bytes: u64,
}

impl GitHubReleaseUpdater {
    pub fn new() -> Result<Self, UpdaterError> {
        Self::with_repo(DEFAULT_GITHUB_OWNER, DEFAULT_GITHUB_REPO)
    }

    pub fn with_repo(
        owner: impl Into<String>,
        repo: impl Into<String>,
    ) -> Result<Self, UpdaterError> {
        Self::with_api_base(owner, repo, "https://api.github.com")
    }

    pub fn with_api_base(
        owner: impl Into<String>,
        repo: impl Into<String>,
        api_base_url: impl Into<String>,
    ) -> Result<Self, UpdaterError> {
        let client = reqwest::Client::builder()
            .connect_timeout(Duration::from_secs(15))
            .timeout(Duration::from_secs(300))
            .redirect(reqwest::redirect::Policy::custom(|attempt| {
                if attempt.previous().len() >= 8 {
                    return attempt.error("Too many redirects while downloading update");
                }
                if !host_matches_domain_list(attempt.url(), ALLOWED_RELEASE_REDIRECT_DOMAINS) {
                    return attempt.error("Rejected unsafe or untrusted update redirect target");
                }
                attempt.follow()
            }))
            .build()
            .map_err(|e| UpdaterError::Network(e.to_string()))?;

        Ok(Self {
            owner: owner.into(),
            repo: repo.into(),
            api_base_url: api_base_url.into().trim_end_matches('/').to_string(),
            client,
            min_installer_bytes: DEFAULT_MIN_INSTALLER_BYTES,
        })
    }

    pub fn with_min_installer_bytes(mut self, bytes: u64) -> Self {
        self.min_installer_bytes = bytes;
        self
    }

    pub fn default_releases_page_url(&self) -> String {
        format!("https://github.com/{}/{}/releases", self.owner, self.repo)
    }

    /// Evaluates a single GitHub Release against `current_version`.
    pub fn evaluate_release(
        release: &GitHubReleaseDto,
        current_version: &str,
    ) -> Result<UpdateCheckOutcome, UpdaterError> {
        let current = CharkleSemanticVersion::parse(current_version)
            .ok_or_else(|| UpdaterError::InvalidVersion(current_version.to_string()))?;

        if release.draft || release.prerelease {
            return Ok(UpdateCheckOutcome::UpToDate {
                latest_version: current.normalized(),
            });
        }

        let Some(remote_version) = CharkleSemanticVersion::parse(&release.tag_name) else {
            return Err(UpdaterError::InvalidResponse(format!(
                "无法解析远端版本号：{}",
                release.tag_name
            )));
        };

        if remote_version <= current {
            return Ok(UpdateCheckOutcome::UpToDate {
                latest_version: remote_version.normalized(),
            });
        }

        let Some(asset) = select_windows_installer_asset(&release.assets) else {
            // Release exists (e.g. macOS shipped first) without a Windows installer yet.
            return Ok(UpdateCheckOutcome::UpToDate {
                latest_version: current.normalized(),
            });
        };

        let title = release
            .name
            .as_deref()
            .map(str::trim)
            .filter(|s| !s.is_empty())
            .unwrap_or(&release.tag_name)
            .to_string();
        let notes = release.body.as_deref().unwrap_or("").trim().to_string();
        let expected_sha256 = resolve_expected_windows_sha256(release.body.as_deref(), asset);

        Ok(UpdateCheckOutcome::UpdateAvailable {
            update: AppReleaseUpdate {
                tag_name: release.tag_name.clone(),
                version: remote_version.normalized(),
                title,
                release_notes: notes,
                html_url: release.html_url.clone(),
                published_at: release.published_at.clone(),
                asset_name: asset.name.clone(),
                download_url: asset.browser_download_url.clone(),
                asset_size_bytes: asset.size,
                expected_sha256,
            },
        })
    }

    /// Evaluates a list of releases (e.g. `/releases?per_page=10`) and returns the highest
    /// non-draft, non-prerelease version newer than `current_version` that includes a Windows `.exe`.
    pub fn evaluate_releases(
        releases: &[GitHubReleaseDto],
        current_version: &str,
    ) -> Result<UpdateCheckOutcome, UpdaterError> {
        let current = CharkleSemanticVersion::parse(current_version)
            .ok_or_else(|| UpdaterError::InvalidVersion(current_version.to_string()))?;

        let mut best: Option<(CharkleSemanticVersion, AppReleaseUpdate)> = None;

        for release in releases {
            if release.draft || release.prerelease {
                continue;
            }
            let Some(ver) = CharkleSemanticVersion::parse(&release.tag_name) else {
                continue;
            };
            if ver <= current {
                continue;
            }
            if let UpdateCheckOutcome::UpdateAvailable { update } =
                Self::evaluate_release(release, current_version)?
            {
                if best
                    .as_ref()
                    .map(|(best_ver, _)| ver > *best_ver)
                    .unwrap_or(true)
                {
                    best = Some((ver, update));
                }
            }
        }

        match best {
            Some((_, update)) => Ok(UpdateCheckOutcome::UpdateAvailable { update }),
            None => Ok(UpdateCheckOutcome::UpToDate {
                latest_version: current.normalized(),
            }),
        }
    }

    /// Queries GitHub Releases `/releases/latest` (and falls back to `/releases?per_page=10` if
    /// `/releases/latest` is newer than `current_version` yet lacks a Windows installer asset).
    pub async fn check_for_latest_release(
        &self,
        current_version: &str,
    ) -> Result<UpdateCheckOutcome, UpdaterError> {
        let current = CharkleSemanticVersion::parse(current_version)
            .ok_or_else(|| UpdaterError::InvalidVersion(current_version.to_string()))?;
        let user_agent = format!("Charkle-Windows/{}", current.normalized());
        let latest_url = format!(
            "{}/repos/{}/{}/releases/latest",
            self.api_base_url, self.owner, self.repo
        );

        let resp = self
            .client
            .get(&latest_url)
            .header(ACCEPT, "application/vnd.github+json")
            .header("X-GitHub-Api-Version", "2022-11-28")
            .header(USER_AGENT, &user_agent)
            .timeout(Duration::from_secs(20))
            .send()
            .await
            .map_err(|e| UpdaterError::Network(e.to_string()))?;

        match resp.status() {
            StatusCode::NOT_FOUND => {
                return Ok(UpdateCheckOutcome::UpToDate {
                    latest_version: current.normalized(),
                });
            }
            StatusCode::FORBIDDEN | StatusCode::TOO_MANY_REQUESTS => {
                return Err(UpdaterError::RateLimited);
            }
            status if !status.is_success() => {
                let text = resp.text().await.unwrap_or_default();
                return Err(UpdaterError::HttpStatus {
                    status: status.as_u16(),
                    message: text.chars().take(200).collect(),
                });
            }
            _ => {}
        }

        let latest: GitHubReleaseDto = resp
            .json()
            .await
            .map_err(|e| UpdaterError::InvalidResponse(e.to_string()))?;

        let outcome = Self::evaluate_release(&latest, current_version)?;
        if matches!(outcome, UpdateCheckOutcome::UpdateAvailable { .. }) {
            return Ok(outcome);
        }

        // If `/releases/latest` is newer than `current` (e.g. macOS shipped a newer tag before
        // Windows attached its `.exe`), check recent releases so older Windows versions can still
        // receive the newest available Windows installer.
        let latest_is_newer_without_win_asset = !latest.draft
            && !latest.prerelease
            && CharkleSemanticVersion::parse(&latest.tag_name)
                .map(|v| v > current)
                .unwrap_or(false)
            && select_windows_installer_asset(&latest.assets).is_none();

        if latest_is_newer_without_win_asset {
            let list_url = format!(
                "{}/repos/{}/{}/releases?per_page=10",
                self.api_base_url, self.owner, self.repo
            );
            if let Ok(list_resp) = self
                .client
                .get(&list_url)
                .header(ACCEPT, "application/vnd.github+json")
                .header("X-GitHub-Api-Version", "2022-11-28")
                .header(USER_AGENT, &user_agent)
                .timeout(Duration::from_secs(20))
                .send()
                .await
            {
                if list_resp.status().is_success() {
                    if let Ok(releases) = list_resp.json::<Vec<GitHubReleaseDto>>().await {
                        return Self::evaluate_releases(&releases, current_version);
                    }
                }
            }
        }

        Ok(outcome)
    }

    /// Downloads the update installer over HTTPS into an isolated temp staging directory,
    /// streams SHA-256 verification, checks Windows PE `MZ` signature, and reports throttled
    /// progress callbacks.
    pub async fn download_and_verify_installer<F>(
        &self,
        update: &AppReleaseUpdate,
        current_version: &str,
        staging_root: Option<&Path>,
        cancel_flag: &AtomicBool,
        mut on_progress: F,
    ) -> Result<VerifiedUpdateInstaller, UpdaterError>
    where
        F: FnMut(UpdateDownloadProgress),
    {
        if !is_allowed_github_release_url(&update.download_url) {
            return Err(UpdaterError::InsecureDownloadUrl(
                update.download_url.clone(),
            ));
        }
        let normalized_expected_sha256 = extract_sha256_from_asset_digest(
            update.expected_sha256.as_deref(),
        )
        .ok_or_else(|| {
            UpdaterError::InvalidInstallerFile(
                "发布信息缺少有效的 SHA-256 校验值，已拒绝下载并安装。".to_string(),
            )
        })?;
        let _ = normalized_expected_sha256;

        let safe_filename = sanitize_installer_filename(&update.asset_name)?;
        let root = staging_root
            .map(PathBuf::from)
            .unwrap_or_else(default_staging_root);
        let _ = cleanup_stale_staging_dirs(&root, Duration::from_secs(24 * 3600));

        let staging_dir = root.join(format!("update-{}", Uuid::new_v4().simple()));
        fs::create_dir_all(&staging_dir).map_err(|e| UpdaterError::Io(e.to_string()))?;
        let part_path = staging_dir.join(format!("{safe_filename}.part"));
        let final_path = staging_dir.join(&safe_filename);

        let result = self
            .stream_and_verify_to_paths(
                update,
                current_version,
                &safe_filename,
                &part_path,
                &final_path,
                cancel_flag,
                &mut on_progress,
            )
            .await;

        if result.is_err() {
            let _ = fs::remove_dir_all(&staging_dir);
        }
        result
    }

    #[allow(clippy::too_many_arguments)]
    async fn stream_and_verify_to_paths<F>(
        &self,
        update: &AppReleaseUpdate,
        current_version: &str,
        safe_filename: &str,
        part_path: &Path,
        final_path: &Path,
        cancel_flag: &AtomicBool,
        on_progress: &mut F,
    ) -> Result<VerifiedUpdateInstaller, UpdaterError>
    where
        F: FnMut(UpdateDownloadProgress),
    {
        if cancel_flag.load(AtomicOrdering::Relaxed) {
            return Err(UpdaterError::Cancelled);
        }

        let user_agent = format!("Charkle-Windows/{current_version}");
        let mut response = self
            .client
            .get(&update.download_url)
            .header(USER_AGENT, &user_agent)
            .send()
            .await
            .map_err(|e| UpdaterError::Network(e.to_string()))?;

        // Enforce HTTPS + trusted release host after any GitHub -> Azure/CDN redirect!
        if !host_matches_domain_list(response.url(), ALLOWED_RELEASE_REDIRECT_DOMAINS) {
            return Err(UpdaterError::InsecureDownloadUrl(
                response.url().to_string(),
            ));
        }

        match response.status() {
            StatusCode::FORBIDDEN | StatusCode::TOO_MANY_REQUESTS => {
                return Err(UpdaterError::RateLimited);
            }
            status if !status.is_success() => {
                return Err(UpdaterError::HttpStatus {
                    status: status.as_u16(),
                    message: "下载更新安装包失败".to_string(),
                });
            }
            _ => {}
        }

        let total_bytes = response
            .content_length()
            .filter(|&len| len > 0)
            .unwrap_or(update.asset_size_bytes);

        if total_bytes > DEFAULT_MAX_INSTALLER_BYTES {
            return Err(UpdaterError::InvalidInstallerFile(
                "安装包体积超出安全限制。".to_string(),
            ));
        }

        let mut file = File::create(part_path).map_err(|e| UpdaterError::Io(e.to_string()))?;
        let mut hasher = Sha256::new();
        let mut downloaded_bytes: u64 = 0;
        let mut header_bytes = [0u8; 2];
        let mut header_filled = 0usize;
        let mut last_emit: Option<Instant> = None;
        let mut last_emit_bytes: u64 = 0;

        while let Some(chunk) = response
            .chunk()
            .await
            .map_err(|e| UpdaterError::Network(e.to_string()))?
        {
            if cancel_flag.load(AtomicOrdering::Relaxed) {
                return Err(UpdaterError::Cancelled);
            }

            downloaded_bytes = downloaded_bytes.saturating_add(chunk.len() as u64);
            if downloaded_bytes > DEFAULT_MAX_INSTALLER_BYTES {
                return Err(UpdaterError::InvalidInstallerFile(
                    "安装包体积超出安全限制。".to_string(),
                ));
            }

            if header_filled < 2 {
                let take = (2 - header_filled).min(chunk.len());
                header_bytes[header_filled..header_filled + take].copy_from_slice(&chunk[..take]);
                header_filled += take;
            }

            hasher.update(&chunk);
            file.write_all(&chunk)
                .map_err(|e| UpdaterError::Io(e.to_string()))?;

            let now = Instant::now();
            let should_emit = last_emit
                .map(|prev| now.duration_since(prev) >= Duration::from_millis(80))
                .unwrap_or(true);
            if should_emit || downloaded_bytes.saturating_sub(last_emit_bytes) >= 256 * 1024 {
                let effective_total = total_bytes.max(downloaded_bytes);
                let fraction = if effective_total > 0 {
                    (downloaded_bytes as f64 / effective_total as f64).clamp(0.0, 1.0)
                } else {
                    0.0
                };
                on_progress(UpdateDownloadProgress {
                    tag_name: update.tag_name.clone(),
                    downloaded_bytes,
                    total_bytes: effective_total,
                    fraction,
                });
                last_emit = Some(now);
                last_emit_bytes = downloaded_bytes;
            }
        }

        file.flush().map_err(|e| UpdaterError::Io(e.to_string()))?;
        drop(file);

        // Emit final 100% progress event
        let final_total = total_bytes.max(downloaded_bytes);
        on_progress(UpdateDownloadProgress {
            tag_name: update.tag_name.clone(),
            downloaded_bytes,
            total_bytes: final_total,
            fraction: 1.0,
        });

        let expected_sha256 = extract_sha256_from_asset_digest(update.expected_sha256.as_deref())
            .ok_or_else(|| {
            UpdaterError::InvalidInstallerFile(
                "发布信息缺少有效的 SHA-256 校验值，已拒绝安装。".to_string(),
            )
        })?;
        let streamed_sha256 = hex::encode(hasher.finalize());
        verify_installer_file(
            part_path,
            downloaded_bytes,
            header_filled,
            header_bytes,
            &streamed_sha256,
            Some(&expected_sha256),
            self.min_installer_bytes,
        )?;

        let verified_sha256 = compute_file_sha256(part_path)?;
        if !verified_sha256.eq_ignore_ascii_case(&expected_sha256) {
            return Err(UpdaterError::ChecksumMismatch {
                expected: expected_sha256,
                actual: verified_sha256,
            });
        }
        fs::rename(part_path, final_path).map_err(|e| UpdaterError::Io(e.to_string()))?;

        Ok(VerifiedUpdateInstaller {
            tag_name: update.tag_name.clone(),
            version: update.version.clone(),
            installer_path: final_path.to_string_lossy().into_owned(),
            file_name: safe_filename.to_string(),
            verified_sha256,
            size_bytes: downloaded_bytes,
            checksum_verified_against_release: true,
        })
    }
}

pub fn default_staging_root() -> PathBuf {
    std::env::temp_dir().join("charkle-updater")
}

pub fn sanitize_installer_filename(raw: &str) -> Result<String, UpdaterError> {
    let trimmed = raw.trim();
    if trimmed.is_empty() {
        return Err(UpdaterError::InvalidInstallerFile(
            "缺少有效的安装包文件名。".to_string(),
        ));
    }
    if trimmed.contains("..")
        || trimmed.contains('/')
        || trimmed.contains('\\')
        || trimmed.contains(':')
    {
        return Err(UpdaterError::InvalidInstallerFile(
            "安装包文件名包含非法路径字符。".to_string(),
        ));
    }
    if !trimmed.to_ascii_lowercase().ends_with(".exe") {
        return Err(UpdaterError::InvalidInstallerFile(format!(
            "安装包扩展名不受支持：{trimmed}"
        )));
    }
    Ok(trimmed.to_string())
}

pub fn compute_file_sha256(path: &Path) -> Result<String, UpdaterError> {
    let mut file = File::open(path).map_err(|e| UpdaterError::Io(e.to_string()))?;
    let mut hasher = Sha256::new();
    std::io::copy(&mut file, &mut hasher).map_err(|e| UpdaterError::Io(e.to_string()))?;
    Ok(hex::encode(hasher.finalize()))
}

/// Validates downloaded installer size, Windows PE `MZ` header, and optional SHA-256 checksum.
pub fn verify_installer_file(
    _path: &Path,
    size_bytes: u64,
    header_filled: usize,
    header_bytes: [u8; 2],
    actual_sha256: &str,
    expected_sha256: Option<&str>,
    min_installer_bytes: u64,
) -> Result<(), UpdaterError> {
    if size_bytes < min_installer_bytes {
        return Err(UpdaterError::InvalidInstallerFile(format!(
            "文件体积过小（{size_bytes} 字节），可能下载不完整。"
        )));
    }
    if header_filled < 2 || header_bytes != *b"MZ" {
        return Err(UpdaterError::InvalidInstallerFile(
            "文件头不是有效的 Windows 可执行安装包（缺少 MZ 签名）。".to_string(),
        ));
    }
    let expected = expected_sha256
        .and_then(|raw| extract_sha256_from_asset_digest(Some(raw)))
        .ok_or_else(|| {
            UpdaterError::InvalidInstallerFile(
                "缺少有效的发布包 SHA-256 校验值，已拒绝安装。".to_string(),
            )
        })?;
    let actual_lower = actual_sha256.trim().to_ascii_lowercase();
    if actual_lower != expected {
        return Err(UpdaterError::ChecksumMismatch {
            expected,
            actual: actual_lower,
        });
    }
    Ok(())
}

/// Removes staging subdirectories under `root` older than `max_age`.
pub fn cleanup_stale_staging_dirs(root: &Path, max_age: Duration) -> usize {
    let Ok(entries) = fs::read_dir(root) else {
        return 0;
    };
    let now = SystemTime::now();
    let mut removed = 0usize;
    for entry in entries.flatten() {
        let path = entry.path();
        if !path.is_dir() {
            continue;
        }
        let name = entry.file_name();
        if !name.to_string_lossy().starts_with("update-") {
            continue;
        }
        let is_old = entry
            .metadata()
            .and_then(|m| m.modified())
            .ok()
            .and_then(|modified| now.duration_since(modified).ok())
            .map(|age| age >= max_age)
            .unwrap_or(false);
        if is_old && fs::remove_dir_all(&path).is_ok() {
            removed += 1;
        }
    }
    removed
}

pub fn now_epoch_ms() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}

// =========================================================================
// Unit Tests
// =========================================================================

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::TempDir;

    fn sample_win_asset(name: &str, digest: Option<&str>) -> GitHubReleaseAssetDto {
        GitHubReleaseAssetDto {
            name: name.to_string(),
            browser_download_url: format!(
                "https://github.com/CharTyr/Charkle/releases/download/v1.3.0/{name}"
            ),
            size: 20_500_000,
            content_type: Some("application/x-msdownload".to_string()),
            digest: digest.map(str::to_string),
        }
    }

    fn sample_mac_asset(name: &str) -> GitHubReleaseAssetDto {
        GitHubReleaseAssetDto {
            name: name.to_string(),
            browser_download_url: format!(
                "https://github.com/CharTyr/Charkle/releases/download/v1.3.0/{name}"
            ),
            size: 16_000_000,
            content_type: Some("application/x-apple-diskimage".to_string()),
            digest: Some(
                "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
                    .to_string(),
            ),
        }
    }

    #[test]
    fn semver_parsing_and_ordering_matches_spec() {
        let v1 = CharkleSemanticVersion::parse("v1.2.0").unwrap();
        let v2 = CharkleSemanticVersion::parse("1.2.1").unwrap();
        let v2_pre = CharkleSemanticVersion::parse("v1.2.1-beta.2+build.42").unwrap();
        let v2_pre10 = CharkleSemanticVersion::parse("1.2.1-beta.10").unwrap();
        let v_short = CharkleSemanticVersion::parse("1.2").unwrap();

        assert_eq!(v1, v_short);
        assert_eq!(v1.normalized(), "1.2.0");
        assert!(v1 < v2_pre);
        assert!(v2_pre < v2_pre10);
        assert!(v2_pre10 < v2);

        assert!(CharkleSemanticVersion::parse("").is_none());
        assert!(CharkleSemanticVersion::parse("v1").is_none());
        assert!(CharkleSemanticVersion::parse("1.2.3.4").is_none());
        assert!(CharkleSemanticVersion::parse("1.2.3-").is_none());
        assert!(CharkleSemanticVersion::parse("1.2.3-beta..1").is_none());
    }

    #[test]
    fn windows_asset_selection_prefers_x64_nsis_and_rejects_dmg_and_http() {
        let mac = sample_mac_asset("Charkle-1.3.0-macOS-arm64.dmg");
        let insecure = GitHubReleaseAssetDto {
            name: "Charkle_1.3.0_x64-setup.exe".to_string(),
            browser_download_url: "http://example.com/Charkle_1.3.0_x64-setup.exe".to_string(),
            size: 20_000_000,
            content_type: None,
            digest: None,
        };
        let arm_exe = sample_win_asset("Charkle_1.3.0_arm64-setup.exe", None);
        let x64_exe = sample_win_asset("Charkle_1.3.0_x64-setup.exe", None);

        assert!(select_windows_installer_asset(&[mac.clone(), insecure.clone()]).is_none());
        let candidates = [mac, insecure, arm_exe, x64_exe.clone()];
        let picked =
            select_windows_installer_asset(&candidates).expect("should pick x64 setup exe");
        assert_eq!(picked.name, x64_exe.name);
    }

    #[test]
    fn windows_scoped_sha256_ignores_macos_section_and_falls_back_to_digest() {
        let mac_hash = "1111111111111111111111111111111111111111111111111111111111111111";
        let win_hash = "2222222222222222222222222222222222222222222222222222222222222222";
        let digest_hash = "3333333333333333333333333333333333333333333333333333333333333333";

        let dual_body = format!(
            "## macOS (Apple Silicon)\n\n- `Charkle-1.3.0-macOS-arm64.dmg`\n- SHA-256: `{mac_hash}`\n\n## Windows 11 (x64)\n\n- 安装包：`Charkle_1.3.0_x64-setup.exe`\n- SHA-256: `{win_hash}`\n"
        );
        let asset = sample_win_asset(
            "Charkle_1.3.0_x64-setup.exe",
            Some(&format!("sha256:{digest_hash}")),
        );

        assert_eq!(
            resolve_expected_windows_sha256(Some(&dual_body), &asset).as_deref(),
            Some(win_hash)
        );

        // macOS-only body must NEVER return mac_hash for Windows; should fall back to asset.digest
        let mac_only_body =
            format!("## macOS\n\n- `Charkle-1.3.0-macOS-arm64.dmg`\n- SHA-256: `{mac_hash}`\n");
        assert_eq!(
            extract_windows_sha256_from_body(&mac_only_body, &asset.name),
            None
        );
        assert_eq!(
            resolve_expected_windows_sha256(Some(&mac_only_body), &asset).as_deref(),
            Some(digest_hash)
        );
    }

    #[test]
    fn evaluate_release_and_releases_handle_dual_platform_staggered_shipping() {
        let mac_only_121 = GitHubReleaseDto {
            tag_name: "v1.2.1".to_string(),
            name: Some("Charkle 1.2.1".to_string()),
            body: Some("## macOS\n- macOS only hotfix".to_string()),
            html_url: "https://github.com/CharTyr/Charkle/releases/tag/v1.2.1".to_string(),
            draft: false,
            prerelease: false,
            published_at: Some("2026-11-24T12:00:00Z".to_string()),
            assets: vec![sample_mac_asset("Charkle-1.2.1-macOS-arm64.dmg")],
        };

        let win_120 = GitHubReleaseDto {
            tag_name: "v1.2.0".to_string(),
            name: Some("Charkle 1.2.0".to_string()),
            body: Some("## Windows\n- Charkle_1.2.0_x64-setup.exe".to_string()),
            html_url: "https://github.com/CharTyr/Charkle/releases/tag/v1.2.0".to_string(),
            draft: false,
            prerelease: false,
            published_at: Some("2026-11-23T12:00:00Z".to_string()),
            assets: vec![sample_win_asset(
                "Charkle_1.2.0_x64-setup.exe",
                Some("sha256:4444444444444444444444444444444444444444444444444444444444444444"),
            )],
        };

        // On Windows 1.2.0, macOS-only v1.2.1 yields UpToDate
        let out_120 = GitHubReleaseUpdater::evaluate_release(&mac_only_121, "1.2.0").unwrap();
        assert_eq!(
            out_120,
            UpdateCheckOutcome::UpToDate {
                latest_version: "1.2.0".to_string()
            }
        );

        // On Windows 1.1.0, evaluate_releases skips macOS-only v1.2.1 and offers Windows v1.2.0
        let out_110 =
            GitHubReleaseUpdater::evaluate_releases(&[mac_only_121, win_120], "1.1.0").unwrap();
        match out_110 {
            UpdateCheckOutcome::UpdateAvailable { update } => {
                assert_eq!(update.version, "1.2.0");
                assert_eq!(update.asset_name, "Charkle_1.2.0_x64-setup.exe");
                assert_eq!(
                    update.expected_sha256.as_deref(),
                    Some("4444444444444444444444444444444444444444444444444444444444444444")
                );
            }
            other => panic!("expected UpdateAvailable for 1.2.0, got {other:?}"),
        }
    }

    #[test]
    fn evaluate_release_ignores_draft_and_prerelease() {
        let mut release = GitHubReleaseDto {
            tag_name: "v1.4.0".to_string(),
            name: Some("Draft".to_string()),
            body: None,
            html_url: "https://github.com/CharTyr/Charkle/releases/tag/v1.4.0".to_string(),
            draft: true,
            prerelease: false,
            published_at: None,
            assets: vec![sample_win_asset("Charkle_1.4.0_x64-setup.exe", None)],
        };
        assert_eq!(
            GitHubReleaseUpdater::evaluate_release(&release, "1.2.0").unwrap(),
            UpdateCheckOutcome::UpToDate {
                latest_version: "1.2.0".to_string()
            }
        );

        release.draft = false;
        release.prerelease = true;
        assert_eq!(
            GitHubReleaseUpdater::evaluate_release(&release, "1.2.0").unwrap(),
            UpdateCheckOutcome::UpToDate {
                latest_version: "1.2.0".to_string()
            }
        );
    }

    #[test]
    fn throttle_and_skipped_version_policy_and_preferences_roundtrip() {
        let dir = TempDir::new().unwrap();
        let policy = AppUpdateCheckPolicy::default();
        let mut prefs = UpdatePreferences::default();

        assert!(policy.should_perform_automatic_check(&prefs, 1_000_000));
        prefs.last_update_check_at_ms = Some(1_000_000);
        // 2 hours later -> throttled
        assert!(!policy.should_perform_automatic_check(&prefs, 1_000_000 + 2 * 3600 * 1000));
        // 6 hours later -> allowed
        assert!(policy.should_perform_automatic_check(&prefs, 1_000_000 + 6 * 3600 * 1000));

        prefs.auto_check_updates = false;
        assert!(!policy.should_perform_automatic_check(&prefs, 1_000_000 + 48 * 3600 * 1000));

        prefs.skipped_version = Some("v1.3.0".to_string());
        prefs.save(dir.path()).unwrap();
        let reloaded = UpdatePreferences::load(dir.path());
        assert_eq!(reloaded, prefs);

        let update = AppReleaseUpdate {
            tag_name: "v1.3.0".to_string(),
            version: "1.3.0".to_string(),
            title: "Charkle 1.3.0".to_string(),
            release_notes: String::new(),
            html_url: "https://github.com/CharTyr/Charkle/releases/tag/v1.3.0".to_string(),
            published_at: None,
            asset_name: "Charkle_1.3.0_x64-setup.exe".to_string(),
            download_url: "https://github.com/CharTyr/Charkle/releases/download/v1.3.0/Charkle_1.3.0_x64-setup.exe".to_string(),
            asset_size_bytes: 20_000_000,
            expected_sha256: None,
        };

        assert!(!policy.should_notify_for_update(
            &update,
            reloaded.skipped_version.as_deref(),
            false
        ));
        assert!(policy.should_notify_for_update(
            &update,
            reloaded.skipped_version.as_deref(),
            true
        ));
    }

    #[test]
    fn installer_verification_enforces_mz_header_size_and_sha256() {
        let dir = TempDir::new().unwrap();
        let file_path = dir.path().join("Charkle_1.3.0_x64-setup.exe");
        let mut payload = vec![b'M', b'Z'];
        payload.resize(4096, 0x5Au8);
        fs::write(&file_path, &payload).unwrap();
        let digest = compute_file_sha256(&file_path).unwrap();

        // Valid MZ + matching SHA-256
        verify_installer_file(&file_path, 4096, 2, *b"MZ", &digest, Some(&digest), 1024).unwrap();

        // Wrong SHA-256 rejected
        let wrong_hash = "0".repeat(64);
        let err = verify_installer_file(
            &file_path,
            4096,
            2,
            *b"MZ",
            &digest,
            Some(&wrong_hash),
            1024,
        )
        .unwrap_err();
        assert!(matches!(err, UpdaterError::ChecksumMismatch { .. }));

        // Non-PE header rejected
        let err_hdr =
            verify_installer_file(&file_path, 4096, 2, *b"PK", &digest, Some(&digest), 1024)
                .unwrap_err();
        assert!(matches!(err_hdr, UpdaterError::InvalidInstallerFile(_)));

        // Filename traversal rejected
        assert!(sanitize_installer_filename("..\\evil.exe").is_err());
        assert!(sanitize_installer_filename("archive.dmg").is_err());
        assert_eq!(
            sanitize_installer_filename("Charkle_1.3.0_x64-setup.exe").unwrap(),
            "Charkle_1.3.0_x64-setup.exe"
        );
    }
}
