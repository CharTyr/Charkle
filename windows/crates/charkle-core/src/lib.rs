//! Pure OS-agnostic Charkle core library for Windows.
//!
//! Mirrors macOS `Sources/CharkleCore` with lossless `/.charkle/` sync parity.

pub mod agent;
pub mod bridge;
pub mod db;
pub mod engine;
pub mod error;
pub mod export;
pub mod intelligence;
pub mod layout;
pub mod media;
pub mod models;
pub mod pinterest;
pub mod sync;
pub mod traits;
pub mod updater;
pub mod wire;
