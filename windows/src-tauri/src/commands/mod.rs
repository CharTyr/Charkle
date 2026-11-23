//! Typed Tauri v2 IPC command layer grouped by domain.

pub mod assets;
pub mod folders;
pub mod media;
pub mod query;
pub mod sync;
pub mod window;

use std::sync::Arc;

use charkle_core::engine::LiveCharkleEngine;
use charkle_core::error::CoreError;
use serde::Serialize;
use uuid::Uuid;

pub struct AppState {
    pub engine: Arc<LiveCharkleEngine>,
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
