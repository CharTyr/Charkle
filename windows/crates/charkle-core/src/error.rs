//! Unified typed error hierarchy for `charkle-core`.

use thiserror::Error;

/// Primary error type across database, media pipeline, sync engine, and serialization.
#[derive(Debug, Error)]
pub enum CoreError {
    #[error("Database error: {0}")]
    Database(String),

    #[error("SQLite error: {0}")]
    Sqlite(#[from] rusqlite::Error),

    #[error("Storage or sync not configured: {0}")]
    NotConfigured(String),

    #[error("Authentication required: {0}")]
    AuthenticationRequired(String),

    #[error("Mount path unavailable: {0}")]
    MountPathUnavailable(String),

    #[error("gdirect executable not found")]
    GDirectNotFound,

    #[error("Command `{command}` failed (exit {exit_code}): {stderr}")]
    CommandFailed {
        command: String,
        stderr: String,
        exit_code: i32,
    },

    #[error("HTTP error ({status_code}): {message}")]
    Http { status_code: u16, message: String },

    #[error("Not found: {0}")]
    NotFound(String),

    #[error("Already exists: {0}")]
    AlreadyExists(String),

    #[error("Invalid response or wire payload: {0}")]
    InvalidPayload(String),

    #[error("Invalid operation: {0}")]
    InvalidOperation(String),

    #[error("Media processing error: {0}")]
    Media(String),

    #[error("I/O error: {0}")]
    Io(#[from] std::io::Error),

    #[error("JSON error: {0}")]
    Json(#[from] serde_json::Error),

    #[error("Network error: {0}")]
    Network(#[from] reqwest::Error),
}

pub type CoreResult<T> = Result<T, CoreError>;
