use std::io::Read;

use charkle_core::models::media::CacheStats;
use tauri::State;
use url::Url;

use super::{parse_uuid, AppState, IpcError, IpcResult};

#[tauri::command]
pub fn cache_stats(state: State<'_, AppState>) -> IpcResult<CacheStats> {
    state.engine.cache_stats().map_err(Into::into)
}

#[tauri::command]
pub fn set_cache_budget_bytes(state: State<'_, AppState>, bytes: i64) -> IpcResult<i64> {
    state
        .engine
        .set_cache_budget_bytes(bytes)
        .map_err(Into::into)
}

#[tauri::command]
pub fn evict_cache_now(state: State<'_, AppState>) -> IpcResult<CacheStats> {
    state.engine.evict_cache_now().map_err(Into::into)
}

/// Reads up to 512 KiB of UTF-8 text/Markdown/code content for Quick Look document preview.
#[tauri::command]
pub fn read_asset_text_content(
    state: State<'_, AppState>,
    id: String,
) -> IpcResult<Option<String>> {
    let uuid = parse_uuid(&id)?;
    let Some(asset) = state.engine.fetch_asset(uuid)? else {
        return Ok(None);
    };
    let Some(path) = state.engine.cached_original_path(&asset) else {
        return Ok(None);
    };
    let file = std::fs::File::open(path).map_err(|e| IpcError {
        code: "IO_ERROR",
        message: e.to_string(),
    })?;
    let mut buf = Vec::new();
    let _ = file.take(512 * 1024).read_to_end(&mut buf);
    Ok(Some(String::from_utf8_lossy(&buf).into_owned()))
}

/// Reveals the cached original file in Windows File Explorer (`explorer.exe /select,<path>`).
#[tauri::command]
pub fn reveal_in_explorer(state: State<'_, AppState>, id: String) -> IpcResult<()> {
    let uuid = parse_uuid(&id)?;
    let asset = state.engine.fetch_asset(uuid)?.ok_or_else(|| IpcError {
        code: "NOT_FOUND",
        message: "Asset not found".to_string(),
    })?;
    let path = state
        .engine
        .cached_original_path(&asset)
        .ok_or_else(|| IpcError {
            code: "NOT_CACHED",
            message: "原文件尚未缓存在本地。".to_string(),
        })?;

    #[cfg(target_os = "windows")]
    {
        std::process::Command::new("explorer.exe")
            .arg(format!("/select,{}", path.display()))
            .spawn()
            .map_err(|e| IpcError {
                code: "IO_ERROR",
                message: format!("无法打开文件资源管理器：{e}"),
            })?;
    }
    #[cfg(not(target_os = "windows"))]
    {
        let _ = path;
    }
    Ok(())
}

/// Opens an existing (or auto-created) directory directly in Windows File Explorer.
#[tauri::command]
pub fn open_directory_in_explorer(path: String) -> IpcResult<()> {
    let trimmed = path.trim();
    if trimmed.is_empty() {
        return Err(IpcError {
            code: "INVALID_PATH",
            message: "目录路径不能为空。".to_string(),
        });
    }
    let dir = std::path::PathBuf::from(trimmed);
    if !dir.exists() {
        std::fs::create_dir_all(&dir).map_err(|e| IpcError {
            code: "IO_ERROR",
            message: format!("无法创建目录：{e}"),
        })?;
    }

    #[cfg(target_os = "windows")]
    {
        std::process::Command::new("explorer.exe")
            .arg(&dir)
            .spawn()
            .map_err(|e| IpcError {
                code: "IO_ERROR",
                message: format!("无法打开文件资源管理器：{e}"),
            })?;
    }
    #[cfg(not(target_os = "windows"))]
    {
        let _ = dir;
    }
    Ok(())
}

/// Validates and opens an HTTP/HTTPS URL in the system default browser without `cmd.exe`
/// metacharacter truncation (safe for OAuth URLs containing `&` query parameters).
pub(crate) fn open_validated_http_url(url: &str) -> IpcResult<()> {
    let parsed = Url::parse(url.trim()).map_err(|_| IpcError {
        code: "INVALID_URL",
        message: "无效的链接地址。".to_string(),
    })?;
    if !matches!(parsed.scheme(), "http" | "https") {
        return Err(IpcError {
            code: "INVALID_URL",
            message: "仅支持打开 http 或 https 链接。".to_string(),
        });
    }

    #[cfg(target_os = "windows")]
    {
        use std::os::windows::process::CommandExt;
        const CREATE_NO_WINDOW: u32 = 0x0800_0000;
        std::process::Command::new("rundll32.exe")
            .args(["url.dll,FileProtocolHandler", parsed.as_str()])
            .creation_flags(CREATE_NO_WINDOW)
            .spawn()
            .map_err(|e| IpcError {
                code: "IO_ERROR",
                message: format!("无法打开浏览器：{e}"),
            })?;
    }
    #[cfg(not(target_os = "windows"))]
    {
        let _ = parsed;
    }
    Ok(())
}

const ALLOWED_MS_SETTINGS_URIS: &[&str] = &[
    "ms-settings:colors",
    "ms-settings:personalization-colors",
    "ms-settings:easeofaccess-visualeffects",
    "ms-settings:display",
];

fn match_allowed_ms_settings_uri(url: &str) -> Option<&'static str> {
    let trimmed = url.trim();
    ALLOWED_MS_SETTINGS_URIS
        .iter()
        .copied()
        .find(|candidate| candidate.eq_ignore_ascii_case(trimmed))
}

/// Opens a validated HTTP/HTTPS external URL in the user's default browser, or opens an
/// allowlisted Windows Settings URI (`ms-settings:colors`, etc.) via File Explorer shell launch.
#[tauri::command]
pub fn open_external_url(url: String) -> IpcResult<()> {
    let trimmed = url.trim();
    if let Some(allowed_uri) = match_allowed_ms_settings_uri(trimmed) {
        #[cfg(target_os = "windows")]
        {
            std::process::Command::new("explorer.exe")
                .arg(allowed_uri)
                .spawn()
                .map_err(|e| IpcError {
                    code: "IO_ERROR",
                    message: format!("无法打开系统设置：{e}"),
                })?;
        }
        #[cfg(not(target_os = "windows"))]
        {
            let _ = allowed_uri;
        }
        return Ok(());
    }
    open_validated_http_url(trimmed)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ms_settings_allowlist_accepts_colors_and_rejects_arbitrary_uris() {
        assert_eq!(
            match_allowed_ms_settings_uri("ms-settings:colors"),
            Some("ms-settings:colors")
        );
        assert_eq!(
            match_allowed_ms_settings_uri("  MS-SETTINGS:COLORS "),
            Some("ms-settings:colors")
        );
        assert_eq!(
            match_allowed_ms_settings_uri("ms-settings:powersleep"),
            None
        );
        assert_eq!(
            match_allowed_ms_settings_uri("file:///C:/Windows/cmd.exe"),
            None
        );
    }
}
