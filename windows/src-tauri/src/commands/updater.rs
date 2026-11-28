//! Typed Tauri v2 IPC commands for native GitHub Releases update checking,
//! streaming HTTPS download with SHA-256 + PE verification, and NSIS passive
//! upgrade + relaunch (`/P /UPDATE /R`).

use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use charkle_core::updater::{
    compute_file_sha256, now_epoch_ms, AppReleaseUpdate, AppUpdateCheckPolicy,
    GitHubReleaseUpdater, UpdateCheckOutcome, UpdatePreferences, UpdaterError,
    VerifiedUpdateInstaller, DEFAULT_GITHUB_OWNER, DEFAULT_GITHUB_REPO,
};
use serde::Serialize;
use tauri::{AppHandle, Emitter, State};

use super::{AppState, IpcError, IpcResult};

pub const CURRENT_APP_VERSION: &str = env!("CARGO_PKG_VERSION");

/// Session-scoped runtime state for the native updater stored in `AppState`.
pub struct UpdaterRuntimeState {
    pub preferences: Mutex<UpdatePreferences>,
    pub cancel_flag: Mutex<Option<Arc<AtomicBool>>>,
    /// Verified `(canonical_installer_path, expected_sha256_hex)` stored after download.
    pub staged_installer: Mutex<Option<(PathBuf, String)>>,
}

impl UpdaterRuntimeState {
    pub fn load(data_dir: &Path) -> Self {
        Self {
            preferences: Mutex::new(UpdatePreferences::load(data_dir)),
            cancel_flag: Mutex::new(None),
            staged_installer: Mutex::new(None),
        }
    }

    fn snapshot_preferences(&self) -> UpdatePreferences {
        self.preferences
            .lock()
            .map(|g| g.clone())
            .unwrap_or_default()
    }

    fn update_preferences(
        &self,
        data_dir: &Path,
        mutate: impl FnOnce(&mut UpdatePreferences),
    ) -> IpcResult<UpdatePreferences> {
        let updated = {
            let mut guard = self.preferences.lock().map_err(|_| IpcError {
                code: "INTERNAL_ERROR",
                message: "更新配置状态锁定失败。".to_string(),
            })?;
            mutate(&mut guard);
            guard.clone()
        };
        updated.save(data_dir).map_err(map_updater_error)?;
        Ok(updated)
    }

    fn validate_staged_installer(&self, raw_path: &str) -> IpcResult<PathBuf> {
        let (staged, expected_sha256) = self
            .staged_installer
            .lock()
            .ok()
            .and_then(|g| g.clone())
            .ok_or_else(|| IpcError {
            code: "INVALID_OPERATION",
            message: "未找到已校验的更新安装包，请重新下载更新。".to_string(),
        })?;

        let requested = PathBuf::from(raw_path.trim());
        let canon_staged = std::fs::canonicalize(&staged).map_err(|_| IpcError {
            code: "NOT_FOUND",
            message: "已下载的更新安装包不存在或已被清理，请重新下载。".to_string(),
        })?;
        let canon_requested = std::fs::canonicalize(&requested).map_err(|_| IpcError {
            code: "NOT_FOUND",
            message: "指定的更新安装包不存在。".to_string(),
        })?;

        if canon_staged != canon_requested {
            return Err(IpcError {
                code: "INVALID_OPERATION",
                message: "已拒绝运行非当前会话校验通过的安装包路径。".to_string(),
            });
        }
        if !canon_staged
            .extension()
            .and_then(|e| e.to_str())
            .map(|ext| ext.eq_ignore_ascii_case("exe"))
            .unwrap_or(false)
        {
            return Err(IpcError {
                code: "INVALID_OPERATION",
                message: "仅允许启动 .exe 更新安装程序。".to_string(),
            });
        }

        // Re-verify SHA-256 right before launch to mitigate TOCTOU tampering in %TEMP%.
        let actual_sha256 = compute_file_sha256(&canon_staged).map_err(map_updater_error)?;
        if !actual_sha256.eq_ignore_ascii_case(&expected_sha256) {
            if let Ok(mut slot) = self.staged_installer.lock() {
                *slot = None;
            }
            return Err(IpcError {
                code: "CHECKSUM_MISMATCH",
                message: "更新安装包在启动前校验不一致，可能已被修改，请重新下载。".to_string(),
            });
        }

        Ok(canon_staged)
    }
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct UpdatePreferencesDto {
    pub current_version: String,
    pub auto_check_updates: bool,
    pub last_update_check_at_ms: Option<i64>,
    pub skipped_version: Option<String>,
    pub releases_page_url: String,
}

impl UpdatePreferencesDto {
    fn from_prefs(prefs: UpdatePreferences) -> Self {
        Self {
            current_version: CURRENT_APP_VERSION.to_string(),
            auto_check_updates: prefs.auto_check_updates,
            last_update_check_at_ms: prefs.last_update_check_at_ms,
            skipped_version: prefs.skipped_version,
            releases_page_url: format!(
                "https://github.com/{DEFAULT_GITHUB_OWNER}/{DEFAULT_GITHUB_REPO}/releases"
            ),
        }
    }
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct UpdateCheckResponseDto {
    pub current_version: String,
    pub outcome: UpdateCheckOutcome,
    pub checked_at_ms: i64,
    pub should_notify: bool,
    pub preferences: UpdatePreferencesDto,
}

fn map_updater_error(err: UpdaterError) -> IpcError {
    let code = match &err {
        UpdaterError::RateLimited => "RATE_LIMITED",
        UpdaterError::HttpStatus { .. } | UpdaterError::Network(_) => "NETWORK_ERROR",
        UpdaterError::ChecksumMismatch { .. } => "CHECKSUM_MISMATCH",
        UpdaterError::InsecureDownloadUrl(_) => "INSECURE_URL",
        UpdaterError::InvalidInstallerFile(_) | UpdaterError::InvalidResponse(_) => {
            "INVALID_PAYLOAD"
        }
        UpdaterError::Cancelled => "CANCELLED",
        UpdaterError::InvalidVersion(_) => "INVALID_VERSION",
        UpdaterError::Io(_) => "IO_ERROR",
    };
    IpcError {
        code,
        message: err.to_string(),
    }
}

#[tauri::command]
pub fn get_update_preferences(state: State<'_, AppState>) -> IpcResult<UpdatePreferencesDto> {
    Ok(UpdatePreferencesDto::from_prefs(
        state.updater.snapshot_preferences(),
    ))
}

#[tauri::command]
pub fn set_auto_check_updates(
    state: State<'_, AppState>,
    enabled: bool,
) -> IpcResult<UpdatePreferencesDto> {
    let updated = state.updater.update_preferences(&state.data_dir, |prefs| {
        prefs.auto_check_updates = enabled;
    })?;
    Ok(UpdatePreferencesDto::from_prefs(updated))
}

#[tauri::command]
pub fn skip_update_version(
    state: State<'_, AppState>,
    version: String,
) -> IpcResult<UpdatePreferencesDto> {
    let trimmed = version.trim().to_string();
    let updated = state.updater.update_preferences(&state.data_dir, |prefs| {
        prefs.skipped_version = if trimmed.is_empty() {
            None
        } else {
            Some(trimmed)
        };
    })?;
    Ok(UpdatePreferencesDto::from_prefs(updated))
}

#[tauri::command]
pub fn clear_skipped_update_version(state: State<'_, AppState>) -> IpcResult<UpdatePreferencesDto> {
    let updated = state.updater.update_preferences(&state.data_dir, |prefs| {
        prefs.skipped_version = None;
    })?;
    Ok(UpdatePreferencesDto::from_prefs(updated))
}

#[tauri::command]
pub async fn check_for_updates(
    state: State<'_, AppState>,
    manual: Option<bool>,
) -> IpcResult<UpdateCheckResponseDto> {
    let is_manual = manual.unwrap_or(true);
    let updater = GitHubReleaseUpdater::new().map_err(map_updater_error)?;
    let outcome = updater
        .check_for_latest_release(CURRENT_APP_VERSION)
        .await
        .map_err(map_updater_error)?;

    let checked_at_ms = now_epoch_ms();
    let updated_prefs = state.updater.update_preferences(&state.data_dir, |prefs| {
        prefs.last_update_check_at_ms = Some(checked_at_ms);
    })?;

    let policy = AppUpdateCheckPolicy::default();
    let should_notify = match &outcome {
        UpdateCheckOutcome::UpdateAvailable { update } => policy.should_notify_for_update(
            update,
            updated_prefs.skipped_version.as_deref(),
            is_manual,
        ),
        UpdateCheckOutcome::UpToDate { .. } => false,
    };

    Ok(UpdateCheckResponseDto {
        current_version: CURRENT_APP_VERSION.to_string(),
        outcome,
        checked_at_ms,
        should_notify,
        preferences: UpdatePreferencesDto::from_prefs(updated_prefs),
    })
}

#[tauri::command]
pub async fn download_and_verify_update(
    app: AppHandle,
    state: State<'_, AppState>,
    update: AppReleaseUpdate,
) -> IpcResult<VerifiedUpdateInstaller> {
    let cancel_flag = Arc::new(AtomicBool::new(false));
    if let Ok(mut guard) = state.updater.cancel_flag.lock() {
        if let Some(prev) = guard.replace(Arc::clone(&cancel_flag)) {
            prev.store(true, Ordering::SeqCst);
        }
    }

    let updater = GitHubReleaseUpdater::new().map_err(map_updater_error)?;
    let app_for_progress = app.clone();
    let result = updater
        .download_and_verify_installer(
            &update,
            CURRENT_APP_VERSION,
            None,
            &cancel_flag,
            move |progress| {
                let _ = app_for_progress.emit("updater:progress", &progress);
                if progress.fraction >= 1.0 {
                    let _ = app_for_progress.emit("updater:phase", "verifying");
                }
            },
        )
        .await;

    // Clear active cancel handle only if it still points to this download.
    if let Ok(mut guard) = state.updater.cancel_flag.lock() {
        if guard
            .as_ref()
            .map(|existing| Arc::ptr_eq(existing, &cancel_flag))
            .unwrap_or(false)
        {
            *guard = None;
        }
    }

    let verified = result.map_err(map_updater_error)?;
    if let Ok(mut staged) = state.updater.staged_installer.lock() {
        *staged = Some((
            PathBuf::from(&verified.installer_path),
            verified.verified_sha256.clone(),
        ));
    }

    Ok(verified)
}

#[tauri::command]
pub fn cancel_update_download(state: State<'_, AppState>) -> IpcResult<()> {
    if let Ok(guard) = state.updater.cancel_flag.lock() {
        if let Some(flag) = guard.as_ref() {
            flag.store(true, Ordering::SeqCst);
        }
    }
    Ok(())
}

/// Launches the verified NSIS installer in passive upgrade + auto-relaunch mode (`/P /UPDATE /R`)
/// via a detached waiter process so `charkle-desktop.exe` releases all file locks cleanly first.
#[tauri::command]
pub async fn install_and_relaunch_update(
    app: AppHandle,
    state: State<'_, AppState>,
    installer_path: String,
) -> IpcResult<()> {
    let verified_path = state.updater.validate_staged_installer(&installer_path)?;

    // Release local extension bridge port cleanly before exiting for upgrade.
    let _ = state.extension_bridge.stop().await;

    #[cfg(target_os = "windows")]
    {
        use std::os::windows::process::CommandExt;

        const CREATE_NO_WINDOW: u32 = 0x0800_0000;
        const DETACHED_PROCESS: u32 = 0x0000_0008;
        const CREATE_NEW_PROCESS_GROUP: u32 = 0x0000_0200;

        let current_pid = std::process::id();
        // Pass PID and installer path via environment variables rather than shell interpolation
        // so spaces, quotes, or special characters in TEMP paths can never break or inject.
        let ps_script = "$p = [int]$env:CHARKLE_UPDATE_WAIT_PID; \
            if ($p -gt 0) { Wait-Process -Id $p -Timeout 6 -ErrorAction SilentlyContinue }; \
            Start-Process -FilePath $env:CHARKLE_UPDATE_INSTALLER -ArgumentList @('/P','/UPDATE','/R')";

        std::process::Command::new("powershell.exe")
            .args([
                "-NoProfile",
                "-NonInteractive",
                "-WindowStyle",
                "Hidden",
                "-Command",
                ps_script,
            ])
            .env("CHARKLE_UPDATE_WAIT_PID", current_pid.to_string())
            .env("CHARKLE_UPDATE_INSTALLER", &verified_path)
            .creation_flags(CREATE_NO_WINDOW | DETACHED_PROCESS | CREATE_NEW_PROCESS_GROUP)
            .spawn()
            .map_err(|e| IpcError {
                code: "INSTALL_LAUNCH_FAILED",
                message: format!("无法启动更新安装程序：{e}"),
            })?;
    }

    #[cfg(not(target_os = "windows"))]
    {
        let _ = verified_path;
    }

    state.explicit_quit.store(true, Ordering::SeqCst);
    let app_to_exit = app.clone();
    tauri::async_runtime::spawn(async move {
        tokio::time::sleep(Duration::from_millis(180)).await;
        app_to_exit.exit(0);
    });

    Ok(())
}

/// Opens the verified NSIS installer interactively without forcing app shutdown (fallback path).
#[tauri::command]
pub fn open_update_installer(state: State<'_, AppState>, installer_path: String) -> IpcResult<()> {
    let verified_path = state.updater.validate_staged_installer(&installer_path)?;

    #[cfg(target_os = "windows")]
    {
        std::process::Command::new(&verified_path)
            .spawn()
            .map_err(|e| IpcError {
                code: "IO_ERROR",
                message: format!("无法打开更新安装程序：{e}"),
            })?;
    }
    #[cfg(not(target_os = "windows"))]
    {
        let _ = verified_path;
    }

    Ok(())
}

/// Reveals the verified installer in Windows File Explorer (`explorer.exe /select,<path>`).
#[tauri::command]
pub fn reveal_update_installer(
    state: State<'_, AppState>,
    installer_path: String,
) -> IpcResult<()> {
    let verified_path = state.updater.validate_staged_installer(&installer_path)?;

    #[cfg(target_os = "windows")]
    {
        super::media::spawn_explorer_select(&verified_path).map_err(|e| IpcError {
            code: "IO_ERROR",
            message: format!("无法在资源管理器中显示安装包：{e}"),
        })?;
    }
    #[cfg(not(target_os = "windows"))]
    {
        let _ = verified_path;
    }

    Ok(())
}
