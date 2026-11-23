//! Atomic file-backed External Agent configuration (`external-agent.json`) shared between
//! `charkle-desktop.exe` and `charkle-cli.exe` with zero SQLite lock contention.

use std::path::{Path, PathBuf};

use crate::error::CoreResult;
use crate::models::agent::ExternalAgentConfig;

pub const EXTERNAL_AGENT_CONFIG_FILE: &str = "external-agent.json";

/// Resolves the canonical Charkle data directory on Windows (`%APPDATA%\app.charkle.windows`
/// or `%LOCALAPPDATA%\Charkle`, matching Tauri `app_data_dir()` / fallback).
pub fn resolve_default_data_dir() -> PathBuf {
    if let Ok(explicit) = std::env::var("CHARKLE_LIBRARY_DIR") {
        let trimmed = explicit.trim();
        if !trimmed.is_empty() {
            return PathBuf::from(trimmed);
        }
    }
    if let Some(roaming) = std::env::var_os("APPDATA") {
        let tauri_dir = PathBuf::from(&roaming).join("app.charkle.windows");
        if tauri_dir.join("Library.sqlite3").exists() {
            return tauri_dir;
        }
    }
    if let Some(local) = std::env::var_os("LOCALAPPDATA") {
        let local_charkle = PathBuf::from(&local).join("Charkle");
        if local_charkle.join("Library.sqlite3").exists() {
            return local_charkle;
        }
        return PathBuf::from(local).join("Charkle");
    }
    std::env::temp_dir().join("Charkle")
}

pub struct ExternalAgentConfigStore;

impl ExternalAgentConfigStore {
    pub fn config_path(data_dir: &Path) -> PathBuf {
        data_dir.join(EXTERNAL_AGENT_CONFIG_FILE)
    }

    pub fn load(data_dir: &Path) -> ExternalAgentConfig {
        let path = Self::config_path(data_dir);
        std::fs::read(&path)
            .ok()
            .and_then(|bytes| serde_json::from_slice::<ExternalAgentConfig>(&bytes).ok())
            .unwrap_or_default()
    }

    pub fn save(data_dir: &Path, config: &ExternalAgentConfig) -> CoreResult<()> {
        std::fs::create_dir_all(data_dir)?;
        let path = Self::config_path(data_dir);
        let bytes = serde_json::to_vec_pretty(config)?;
        let tmp = path.with_extension("json.tmp");
        std::fs::write(&tmp, bytes)?;
        std::fs::rename(&tmp, &path)?;
        Ok(())
    }
}
