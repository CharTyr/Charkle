//! Typed Tauri v2 IPC command layer grouped by domain.

pub mod assets;
pub mod folders;
pub mod media;
pub mod moodboard;
pub mod native;
pub mod query;
pub mod settings;
pub mod sync;
pub mod updater;
pub mod window;

use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, AtomicIsize, AtomicU64, AtomicU8};
use std::sync::{Arc, Mutex};

use charkle_core::bridge::LocalExtensionBridgeServer;
use charkle_core::engine::LiveCharkleEngine;
use charkle_core::error::CoreError;
use charkle_core::intelligence::CloudAIUsageStore;
use charkle_platform_win::clipboard::{ClipboardListenerHandle, ClipboardPreview};
use charkle_platform_win::shelf_win::TopEdgeDragMonitorHandle;
use charkle_platform_win::wake::LibraryWakeHandle;
use serde::Serialize;
use uuid::Uuid;

use crate::commands::updater::UpdaterRuntimeState;
use crate::desktop::{CaptureFrameStore, HotkeyConfig, ShelfSettings};

pub struct AppState {
    pub engine: Arc<LiveCharkleEngine>,
    pub extension_bridge: Arc<LocalExtensionBridgeServer>,
    pub updater: Arc<UpdaterRuntimeState>,
    pub data_dir: PathBuf,
    pub usage_store: Arc<CloudAIUsageStore>,
    pub capture_frames: Arc<CaptureFrameStore>,
    pub hotkeys: Arc<Mutex<HotkeyConfig>>,
    pub shelf_settings: Arc<Mutex<ShelfSettings>>,
    pub shelf_enabled: Arc<AtomicBool>,
    pub shelf_hover_trigger: Arc<AtomicBool>,
    pub shelf_dock_edge: Arc<AtomicU8>,
    pub shelf_expanded: Arc<AtomicBool>,
    pub shelf_pinned: Arc<AtomicBool>,
    pub shelf_drag_hovering: Arc<AtomicBool>,
    pub shelf_busy: Arc<AtomicBool>,
    pub shelf_hold_until_ms: Arc<AtomicU64>,
    pub shelf_hwnd: Arc<AtomicIsize>,
    pub shelf_anim_gen: Arc<AtomicU64>,
    pub shelf_minimal_mode: Arc<AtomicBool>,
    pub explicit_quit: Arc<AtomicBool>,
    pub latest_clipboard: Arc<Mutex<Option<ClipboardPreview>>>,
    pub _clipboard_listener: Option<ClipboardListenerHandle>,
    pub _top_edge_monitor: Option<TopEdgeDragMonitorHandle>,
    pub _wake_listener: Option<LibraryWakeHandle>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct IpcError {
    pub code: &'static str,
    pub message: String,
}

impl From<CoreError> for IpcError {
    fn from(err: CoreError) -> Self {
        let code = match &err {
            CoreError::NotFound(_) => "NOT_FOUND",
            CoreError::AlreadyExists(_) => "ALREADY_EXISTS",
            CoreError::AuthenticationRequired(_) => "AUTH_REQUIRED",
            CoreError::NotConfigured(_) => "NOT_CONFIGURED",
            CoreError::MountPathUnavailable(_) => "MOUNT_UNAVAILABLE",
            CoreError::InvalidOperation(_) => "INVALID_OPERATION",
            CoreError::InvalidPayload(_) => "INVALID_PAYLOAD",
            CoreError::Media(_) => "MEDIA_ERROR",
            CoreError::Database(_) | CoreError::Sqlite(_) => "DATABASE_ERROR",
            CoreError::Http { .. } | CoreError::Network(_) => "NETWORK_ERROR",
            CoreError::Io(_) => "IO_ERROR",
            _ => "INTERNAL_ERROR",
        };
        Self {
            code,
            message: err.to_string(),
        }
    }
}

pub type IpcResult<T> = Result<T, IpcError>;

pub fn parse_uuid(raw: &str) -> IpcResult<Uuid> {
    Uuid::parse_str(raw.trim()).map_err(|_| IpcError {
        code: "INVALID_UUID",
        message: format!("Invalid UUID: `{raw}`"),
    })
}

pub fn parse_optional_uuid(raw: Option<String>) -> IpcResult<Option<Uuid>> {
    match raw {
        None => Ok(None),
        Some(s) if s.trim().is_empty() => Ok(None),
        Some(s) => Ok(Some(parse_uuid(&s)?)),
    }
}
