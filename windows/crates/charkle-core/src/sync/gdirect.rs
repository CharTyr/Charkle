//! In-app `gdirect` CLI installer (from `mizorewww/gdirect` GitHub Releases with HTTPS +
//! SHA-256 + Windows PE verification + Zip-Slip-safe extraction into `%LOCALAPPDATA%\Charkle\bin`)
//! and lightweight hidden-window CLI probing (`--version`, `accounts`, `scan --list`).

use std::fs::{self, File};
use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::{Duration, Instant};

use reqwest::header::{ACCEPT, USER_AGENT};
use reqwest::StatusCode;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use url::Url;
use uuid::Uuid;

use crate::error::{CoreError, CoreResult};
use crate::models::sync::{GDirectEndpoint, GDirectEnvironmentSnapshot};
use crate::updater::{extract_sha256_from_asset_digest, GitHubReleaseAssetDto, GitHubReleaseDto};

pub const GDIRECT_GITHUB_OWNER: &str = "mizorewww";
pub const GDIRECT_GITHUB_REPO: &str = "gdirect";
const MAX_GDIRECT_ARCHIVE_BYTES: u64 = 128 * 1024 * 1024;
const MAX_EXTRACTED_BINARY_BYTES: u64 = 96 * 1024 * 1024;

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct GDirectInstallProgress {
    pub phase: String,
    pub message: String,
    pub downloaded_bytes: u64,
    pub total_bytes: u64,
    pub fraction: f64,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct GDirectInstallResult {
    pub tag_name: String,
    pub version: String,
    pub cli_path: String,
    pub asset_name: String,
    pub verified_sha256: String,
    pub size_bytes: u64,
}

/// Default per-user writable install directory checked by `detect_gdirect_binary()`.
pub fn default_charkle_bin_dir() -> PathBuf {
    std::env::var_os("LOCALAPPDATA")
        .map(PathBuf::from)
        .unwrap_or_else(std::env::temp_dir)
        .join("Charkle")
        .join("bin")
}

fn is_https_url(raw: &str) -> bool {
    Url::parse(raw.trim())
        .map(|u| u.scheme().eq_ignore_ascii_case("https"))
        .unwrap_or(false)
}

/// Selects the Windows x64 CLI archive/binary from `mizorewww/gdirect` GitHub Release assets,
/// excluding desktop installers (`.msi`, `*desktop*`) and non-Windows assets.
pub fn select_windows_gdirect_cli_asset(
    assets: &[GitHubReleaseAssetDto],
) -> Option<&GitHubReleaseAssetDto> {
    let mut best: Option<(i32, &GitHubReleaseAssetDto)> = None;

    for asset in assets {
        let lower = asset.name.trim().to_ascii_lowercase();
        if !is_https_url(&asset.browser_download_url) {
            continue;
        }
        if lower.contains("desktop")
            || lower.ends_with(".msi")
            || lower.contains("darwin")
            || lower.contains("macos")
            || lower.contains("linux")
            || lower.contains("source")
        {
            continue;
        }
        let is_zip = lower.ends_with(".zip");
        let is_exe = lower.ends_with(".exe");
        if !is_zip && !is_exe {
            continue;
        }
        if !lower.contains("windows") && !lower.contains("win64") && !lower.contains("win32") {
            continue;
        }

        let mut score = 20;
        if is_zip {
            score += 40;
        }
        if lower.contains("x86_64") || lower.contains("x64") || lower.contains("amd64") {
            score += 60;
        }
        if lower.contains("pc-windows") {
            score += 20;
        }
        if lower.contains("arm64") || lower.contains("aarch64") || lower.contains("i686") {
            score -= 30;
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

/// Parses standard `SHA256SUMS` text (`<64-hex>  <filename>`) for the matching asset filename.
pub fn extract_sha256_from_sums_file(sums_text: &str, asset_name: &str) -> Option<String> {
    let target = asset_name.trim().to_ascii_lowercase();
    if target.is_empty() {
        return None;
    }
    for line in sums_text.lines() {
        let mut parts = line.split_whitespace();
        let Some(hash) = parts.next() else {
            continue;
        };
        let Some(raw_name) = parts.next() else {
            continue;
        };
        let cleaned_name = raw_name.trim_start_matches('*').to_ascii_lowercase();
        if (cleaned_name == target || cleaned_name.ends_with(&format!("/{target}")))
            && hash.len() == 64
            && hash.bytes().all(|b| b.is_ascii_hexdigit())
        {
            return Some(hash.to_ascii_lowercase());
        }
    }
    None
}

/// Extracts `gdirect.exe` (and any companion `.dll` in the same zip directory) into `install_dir`
/// using strict Zip-Slip protection, PE `MZ` header checks, and atomic file replacement.
pub fn extract_gdirect_zip_to_dir(zip_path: &Path, install_dir: &Path) -> CoreResult<PathBuf> {
    fs::create_dir_all(install_dir)?;
    let file = File::open(zip_path)?;
    let mut archive = zip::ZipArchive::new(file)
        .map_err(|e| CoreError::Media(format!("无法解压 gdirect 安装包：{e}")))?;

    // First locate `gdirect.exe` inside the zip archive.
    let mut exe_index: Option<usize> = None;
    let mut exe_parent: Option<String> = None;
    for idx in 0..archive.len() {
        let entry = archive
            .by_index(idx)
            .map_err(|e| CoreError::Media(format!("读取 zip 条目失败：{e}")))?;
        if entry.is_dir() {
            continue;
        }
        let normalized = entry.name().replace('\\', "/");
        if normalized.contains("..") {
            continue;
        }
        let file_name = normalized.rsplit('/').next().unwrap_or("");
        if file_name.eq_ignore_ascii_case("gdirect.exe") {
            exe_index = Some(idx);
            exe_parent = normalized
                .rsplit_once('/')
                .map(|(parent, _)| parent.to_string());
            break;
        }
    }

    let Some(exe_idx) = exe_index else {
        return Err(CoreError::Media(
            "压缩包中未找到 gdirect.exe 可执行文件。".to_string(),
        ));
    };

    // Extract `gdirect.exe` and any companion `.dll` files from the same directory.
    let mut target_indices = vec![(exe_idx, "gdirect.exe".to_string(), true)];
    for idx in 0..archive.len() {
        if idx == exe_idx {
            continue;
        }
        let entry = archive
            .by_index(idx)
            .map_err(|e| CoreError::Media(format!("读取 zip 条目失败：{e}")))?;
        if entry.is_dir() {
            continue;
        }
        let normalized = entry.name().replace('\\', "/");
        if normalized.contains("..") {
            continue;
        }
        let (parent, name) = match normalized.rsplit_once('/') {
            Some((p, n)) => (Some(p.to_string()), n),
            None => (None, normalized.as_str()),
        };
        if parent == exe_parent && name.to_ascii_lowercase().ends_with(".dll") {
            target_indices.push((idx, name.to_string(), false));
        }
    }

    let mut installed_exe_path: Option<PathBuf> = None;
    for (idx, file_name, is_main_exe) in target_indices {
        let mut entry = archive
            .by_index(idx)
            .map_err(|e| CoreError::Media(format!("解压条目失败：{e}")))?;
        if entry.size() > MAX_EXTRACTED_BINARY_BYTES {
            return Err(CoreError::Media(format!(
                "解压目标 {file_name} 超出安全体积限制。"
            )));
        }

        let tmp_path = install_dir.join(format!("{file_name}.{}.tmp", Uuid::new_v4().simple()));
        let final_path = install_dir.join(&file_name);

        let mut buf = Vec::with_capacity(entry.size().min(16 * 1024 * 1024) as usize);
        entry
            .by_ref()
            .take(MAX_EXTRACTED_BINARY_BYTES + 1)
            .read_to_end(&mut buf)?;
        if buf.len() as u64 > MAX_EXTRACTED_BINARY_BYTES {
            return Err(CoreError::Media(format!(
                "解压目标 {file_name} 实际体积超出安全限制。"
            )));
        }
        if buf.len() < 2 || &buf[..2] != b"MZ" {
            return Err(CoreError::Media(format!(
                "解压目标 {file_name} 不是有效的 Windows PE 二进制文件。"
            )));
        }

        fs::write(&tmp_path, &buf)?;
        if let Err(rename_err) = fs::rename(&tmp_path, &final_path) {
            // If an older file already exists on Windows, remove & retry rename cleanly.
            let _ = fs::remove_file(&final_path);
            if let Err(retry_err) = fs::rename(&tmp_path, &final_path) {
                let _ = fs::remove_file(&tmp_path);
                return Err(CoreError::Media(format!(
                    "无法写入 {}（请关闭正在运行的 gdirect 后重试）：{} / {}",
                    final_path.display(),
                    rename_err,
                    retry_err
                )));
            }
        }
        if is_main_exe {
            installed_exe_path = Some(final_path);
        }
    }

    installed_exe_path
        .ok_or_else(|| CoreError::Media("安装 gdirect.exe 未生成目标文件。".to_string()))
}

/// Downloads the latest Windows `gdirect` CLI from GitHub Releases (`mizorewww/gdirect`),
/// verifies SHA-256 and Windows PE headers, and installs atomically into `install_dir`.
pub async fn install_gdirect_cli_windows<F>(
    install_dir: Option<&Path>,
    mut on_progress: F,
) -> CoreResult<GDirectInstallResult>
where
    F: FnMut(GDirectInstallProgress),
{
    on_progress(GDirectInstallProgress {
        phase: "checking".to_string(),
        message: "正在查询 gdirect 最新 Windows 版本…".to_string(),
        downloaded_bytes: 0,
        total_bytes: 0,
        fraction: 0.05,
    });

    let client = reqwest::Client::builder()
        .connect_timeout(Duration::from_secs(15))
        .timeout(Duration::from_secs(180))
        .redirect(reqwest::redirect::Policy::limited(8))
        .build()?;

    let latest_url = format!(
        "https://api.github.com/repos/{GDIRECT_GITHUB_OWNER}/{GDIRECT_GITHUB_REPO}/releases/latest"
    );
    let resp = client
        .get(&latest_url)
        .header(ACCEPT, "application/vnd.github+json")
        .header("X-GitHub-Api-Version", "2022-11-28")
        .header(USER_AGENT, "Charkle-Windows/gdirect-installer")
        .send()
        .await?;

    if matches!(
        resp.status(),
        StatusCode::FORBIDDEN | StatusCode::TOO_MANY_REQUESTS
    ) {
        return Err(CoreError::Http {
            status_code: resp.status().as_u16(),
            message: "GitHub API 频率受限，请稍后再试。".to_string(),
        });
    }
    if !resp.status().is_success() {
        return Err(CoreError::Http {
            status_code: resp.status().as_u16(),
            message: "查询 gdirect 最新发布版本失败。".to_string(),
        });
    }

    let release: GitHubReleaseDto = resp
        .json()
        .await
        .map_err(|e| CoreError::InvalidPayload(format!("解析 gdirect 发布数据失败：{e}")))?;

    let asset = select_windows_gdirect_cli_asset(&release.assets).ok_or_else(|| {
        CoreError::NotFound(format!(
            "gdirect {} 中未找到适用的 Windows x64 CLI 安装包。",
            release.tag_name
        ))
    })?;

    // Resolve expected SHA-256 from native GitHub asset digest or `SHA256SUMS` asset.
    let mut expected_sha256 = extract_sha256_from_asset_digest(asset.digest.as_deref());
    if expected_sha256.is_none() {
        if let Some(sums_asset) = release.assets.iter().find(|a| {
            a.name.eq_ignore_ascii_case("SHA256SUMS") && is_https_url(&a.browser_download_url)
        }) {
            if let Ok(sums_resp) = client
                .get(&sums_asset.browser_download_url)
                .header(USER_AGENT, "Charkle-Windows/gdirect-installer")
                .timeout(Duration::from_secs(15))
                .send()
                .await
            {
                if sums_resp.status().is_success() {
                    if let Ok(sums_text) = sums_resp.text().await {
                        expected_sha256 = extract_sha256_from_sums_file(&sums_text, &asset.name);
                    }
                }
            }
        }
    }

    on_progress(GDirectInstallProgress {
        phase: "downloading".to_string(),
        message: format!("正在下载 {}…", asset.name),
        downloaded_bytes: 0,
        total_bytes: asset.size,
        fraction: 0.1,
    });

    let mut dl_resp = client
        .get(&asset.browser_download_url)
        .header(USER_AGENT, "Charkle-Windows/gdirect-installer")
        .send()
        .await?;

    if !dl_resp.url().scheme().eq_ignore_ascii_case("https") {
        return Err(CoreError::InvalidOperation(
            "已拒绝非 HTTPS 的 gdirect 下载跳转地址。".to_string(),
        ));
    }
    if !dl_resp.status().is_success() {
        return Err(CoreError::Http {
            status_code: dl_resp.status().as_u16(),
            message: "下载 gdirect 安装包失败。".to_string(),
        });
    }

    let total_bytes = dl_resp
        .content_length()
        .filter(|&len| len > 0)
        .unwrap_or(asset.size);
    if total_bytes > MAX_GDIRECT_ARCHIVE_BYTES {
        return Err(CoreError::Media(
            "gdirect 下载包超出安全体积限制。".to_string(),
        ));
    }

    let staging_dir =
        std::env::temp_dir().join(format!("charkle-gdirect-{}", Uuid::new_v4().simple()));
    fs::create_dir_all(&staging_dir)?;
    let archive_path = staging_dir.join(&asset.name);

    let result = async {
        let mut out_file = File::create(&archive_path)?;
        let mut hasher = Sha256::new();
        let mut downloaded_bytes: u64 = 0;
        let mut last_emit = Instant::now() - Duration::from_secs(1);

        while let Some(chunk) = dl_resp.chunk().await? {
            downloaded_bytes = downloaded_bytes.saturating_add(chunk.len() as u64);
            if downloaded_bytes > MAX_GDIRECT_ARCHIVE_BYTES {
                return Err(CoreError::Media(
                    "gdirect 下载包超出安全体积限制。".to_string(),
                ));
            }
            hasher.update(&chunk);
            out_file.write_all(&chunk)?;

            if Instant::now().duration_since(last_emit) >= Duration::from_millis(90) {
                let effective_total = total_bytes.max(downloaded_bytes);
                let dl_ratio = if effective_total > 0 {
                    (downloaded_bytes as f64 / effective_total as f64).clamp(0.0, 1.0)
                } else {
                    0.0
                };
                on_progress(GDirectInstallProgress {
                    phase: "downloading".to_string(),
                    message: format!("正在下载 {}…", asset.name),
                    downloaded_bytes,
                    total_bytes: effective_total,
                    fraction: 0.1 + dl_ratio * 0.75,
                });
                last_emit = Instant::now();
            }
        }
        out_file.flush()?;
        drop(out_file);

        let actual_sha256 = hex::encode(hasher.finalize());
        on_progress(GDirectInstallProgress {
            phase: "verifying".to_string(),
            message: "正在校验 SHA-256 并解压安装 gdirect.exe…".to_string(),
            downloaded_bytes,
            total_bytes: total_bytes.max(downloaded_bytes),
            fraction: 0.9,
        });

        if let Some(ref expected) = expected_sha256 {
            if !actual_sha256.eq_ignore_ascii_case(expected) {
                return Err(CoreError::Media(format!(
                    "gdirect 安装包 SHA-256 校验失败（期望 {expected}，实际 {actual_sha256}）。"
                )));
            }
        }

        let target_dir = install_dir
            .map(PathBuf::from)
            .unwrap_or_else(default_charkle_bin_dir);
        let installed_path = if asset.name.to_ascii_lowercase().ends_with(".zip") {
            extract_gdirect_zip_to_dir(&archive_path, &target_dir)?
        } else {
            fs::create_dir_all(&target_dir)?;
            let bytes = fs::read(&archive_path)?;
            if bytes.len() < 2 || &bytes[..2] != b"MZ" {
                return Err(CoreError::Media(
                    "下载的 gdirect.exe 不是有效的 Windows 可执行文件。".to_string(),
                ));
            }
            let dest = target_dir.join("gdirect.exe");
            fs::write(&dest, bytes)?;
            dest
        };

        let detected_version = run_gdirect_command(&installed_path, &["--version"])
            .as_deref()
            .and_then(parse_gdirect_version)
            .unwrap_or_else(|| release.tag_name.trim_start_matches(['v', 'V']).to_string());

        on_progress(GDirectInstallProgress {
            phase: "done".to_string(),
            message: format!("已安装 gdirect v{detected_version}"),
            downloaded_bytes,
            total_bytes: total_bytes.max(downloaded_bytes),
            fraction: 1.0,
        });

        Ok(GDirectInstallResult {
            tag_name: release.tag_name.clone(),
            version: detected_version,
            cli_path: installed_path.to_string_lossy().into_owned(),
            asset_name: asset.name.clone(),
            verified_sha256: actual_sha256,
            size_bytes: downloaded_bytes,
        })
    }
    .await;

    let _ = fs::remove_dir_all(&staging_dir);
    result
}

// =========================================================================
// Lightweight Hidden-Window CLI Probing & Parsers
// =========================================================================

fn run_gdirect_command(binary: &Path, args: &[&str]) -> Option<String> {
    let mut cmd = Command::new(binary);
    cmd.args(args);
    #[cfg(target_os = "windows")]
    {
        use std::os::windows::process::CommandExt;
        const CREATE_NO_WINDOW: u32 = 0x0800_0000;
        cmd.creation_flags(CREATE_NO_WINDOW);
    }
    let output = cmd.output().ok()?;
    let stdout = String::from_utf8_lossy(&output.stdout).into_owned();
    if !stdout.trim().is_empty() {
        Some(stdout)
    } else {
        let stderr = String::from_utf8_lossy(&output.stderr).into_owned();
        if !stderr.trim().is_empty() {
            Some(stderr)
        } else {
            None
        }
    }
}

pub fn parse_gdirect_version(output: &str) -> Option<String> {
    for token in output.split_whitespace() {
        let trimmed =
            token.trim_matches(|c: char| !c.is_ascii_alphanumeric() && c != '.' && c != '-');
        let cleaned = trimmed
            .strip_prefix('v')
            .or_else(|| trimmed.strip_prefix('V'))
            .unwrap_or(trimmed);
        let parts: Vec<&str> = cleaned.split('.').collect();
        if parts.len() >= 3
            && parts[0].bytes().all(|b| b.is_ascii_digit())
            && !parts[0].is_empty()
            && parts[1].bytes().all(|b| b.is_ascii_digit())
            && !parts[1].is_empty()
        {
            return Some(cleaned.to_string());
        }
    }
    None
}

pub fn parse_gdirect_accounts(output: &str) -> (Vec<String>, Option<String>) {
    let mut accounts = Vec::new();
    let mut default_account = None;
    for line in output.lines() {
        for token in line.split_whitespace() {
            let cleaned =
                token.trim_matches(|c: char| matches!(c, '(' | ')' | ',' | ';' | '"' | '\''));
            if let Some((local, domain)) = cleaned.split_once('@') {
                if !local.is_empty()
                    && domain.contains('.')
                    && !cleaned.contains('\\')
                    && !cleaned.contains('/')
                {
                    let email = cleaned.to_string();
                    if !accounts.contains(&email) {
                        accounts.push(email.clone());
                    }
                    if line.trim_start().starts_with('*') || line.contains("(default)") {
                        default_account = Some(email);
                    }
                    break;
                }
            }
        }
    }
    (accounts, default_account)
}

pub fn parse_gdirect_scan_list(output: &str) -> Vec<GDirectEndpoint> {
    let mut endpoints = Vec::new();
    for line in output.lines() {
        let fields: Vec<&str> = line.split_whitespace().collect();
        if fields.len() < 2 {
            continue;
        }
        let ip = fields[0];
        if ip.parse::<std::net::IpAddr>().is_err() {
            continue;
        }
        let healthy = fields[1].eq_ignore_ascii_case("OK");
        let latency_ms = fields
            .iter()
            .skip(2)
            .find_map(|tok| {
                let digits: String = tok.chars().take_while(|c| c.is_ascii_digit()).collect();
                digits.parse::<i32>().ok()
            })
            .unwrap_or(i32::MAX);
        endpoints.push(GDirectEndpoint {
            ip: ip.to_string(),
            latency_ms,
            healthy,
        });
    }
    endpoints.sort_by(|a, b| {
        b.healthy
            .cmp(&a.healthy)
            .then_with(|| a.latency_ms.cmp(&b.latency_ms))
            .then_with(|| a.ip.cmp(&b.ip))
    });
    endpoints
}

/// Builds a rich `GDirectEnvironmentSnapshot` when `cli_path` is detected.
pub fn probe_gdirect_environment(
    cli_path: Option<PathBuf>,
    mount_path: String,
    is_mount_active: bool,
) -> GDirectEnvironmentSnapshot {
    let Some(binary) = cli_path else {
        return GDirectEnvironmentSnapshot {
            mount_path,
            is_mount_active,
            ..Default::default()
        };
    };

    let cli_version = run_gdirect_command(&binary, &["--version"])
        .as_deref()
        .and_then(parse_gdirect_version);
    let (accounts, default_account) = run_gdirect_command(&binary, &["accounts"])
        .as_deref()
        .map(parse_gdirect_accounts)
        .unwrap_or_default();
    let endpoints = run_gdirect_command(&binary, &["scan", "--list"])
        .as_deref()
        .map(parse_gdirect_scan_list)
        .unwrap_or_default();

    GDirectEnvironmentSnapshot {
        cli_path: Some(binary.display().to_string()),
        cli_version,
        accounts,
        default_account,
        endpoints,
        mount_path,
        is_mount_active,
        ..Default::default()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::TempDir;

    #[test]
    fn selects_windows_cli_zip_and_ignores_desktop_msi_and_macos() {
        let assets = vec![
            GitHubReleaseAssetDto {
                name: "gdirect-0.13.2-aarch64-apple-darwin.tar.gz".to_string(),
                browser_download_url: "https://github.com/mizorewww/gdirect/releases/download/v0.13.2/gdirect-0.13.2-aarch64-apple-darwin.tar.gz".to_string(),
                size: 10_000_000,
                content_type: None,
                digest: None,
            },
            GitHubReleaseAssetDto {
                name: "gdirect-desktop-windows-x64.msi".to_string(),
                browser_download_url: "https://github.com/mizorewww/gdirect/releases/download/v0.13.2/gdirect-desktop-windows-x64.msi".to_string(),
                size: 42_000_000,
                content_type: None,
                digest: None,
            },
            GitHubReleaseAssetDto {
                name: "gdirect-0.13.2-x86_64-pc-windows-gnu.zip".to_string(),
                browser_download_url: "https://github.com/mizorewww/gdirect/releases/download/v0.13.2/gdirect-0.13.2-x86_64-pc-windows-gnu.zip".to_string(),
                size: 13_600_000,
                content_type: None,
                digest: Some("sha256:006b409608bf0681045fee71430006876f4332625bd8403014f4d21756838b73".to_string()),
            },
        ];

        let picked = select_windows_gdirect_cli_asset(&assets).expect("should select cli zip");
        assert_eq!(picked.name, "gdirect-0.13.2-x86_64-pc-windows-gnu.zip");
    }

    #[test]
    fn parses_sha256sums_and_cli_outputs() {
        let sums = "006b409608bf0681045fee71430006876f4332625bd8403014f4d21756838b73  gdirect-0.13.2-x86_64-pc-windows-gnu.zip\n";
        assert_eq!(
            extract_sha256_from_sums_file(sums, "gdirect-0.13.2-x86_64-pc-windows-gnu.zip")
                .as_deref(),
            Some("006b409608bf0681045fee71430006876f4332625bd8403014f4d21756838b73")
        );

        assert_eq!(
            parse_gdirect_version("gdirect 0.13.2").as_deref(),
            Some("0.13.2")
        );

        let (accounts, default_acc) =
            parse_gdirect_accounts("  alice@example.com\n* bob@example.com\n");
        assert_eq!(accounts, vec!["alice@example.com", "bob@example.com"]);
        assert_eq!(default_acc.as_deref(), Some("bob@example.com"));

        let endpoints =
            parse_gdirect_scan_list("142.250.4.100 FAIL 999ms\n142.250.4.101 OK 38ms\n");
        assert_eq!(endpoints.len(), 2);
        assert!(endpoints[0].healthy);
        assert_eq!(endpoints[0].ip, "142.250.4.101");
        assert_eq!(endpoints[0].latency_ms, 38);
    }

    #[test]
    fn extracts_gdirect_exe_from_nested_zip_and_rejects_traversal() {
        let tmp = TempDir::new().unwrap();
        let zip_path = tmp.path().join("gdirect.zip");
        let install_dir = tmp.path().join("bin");

        {
            let file = File::create(&zip_path).unwrap();
            let mut writer = zip::ZipWriter::new(file);
            let opts = zip::write::SimpleFileOptions::default();

            // Traversal entry must be skipped
            writer.start_file("../evil.exe", opts).unwrap();
            writer.write_all(b"MZevil").unwrap();

            // Legitimate nested gdirect.exe
            writer
                .start_file("gdirect-0.13.2-x86_64-pc-windows-gnu/gdirect.exe", opts)
                .unwrap();
            writer.write_all(b"MZ\x90\x00fake-pe-binary").unwrap();
            writer.finish().unwrap();
        }

        let installed = extract_gdirect_zip_to_dir(&zip_path, &install_dir).unwrap();
        assert_eq!(installed, install_dir.join("gdirect.exe"));
        assert!(installed.is_file());
        assert!(!tmp.path().join("evil.exe").exists());
    }
}
