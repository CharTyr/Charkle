//! Event bridge streaming `charkle-core` `EngineEvent`s to Tauri WebView windows.

use std::sync::Arc;

use charkle_core::engine::{EngineEvent, LiveCharkleEngine};
use charkle_core::wire::swift_codec::format_swift_uuid;
use tauri::{AppHandle, Emitter};

pub fn spawn_event_bridge(app: AppHandle, engine: Arc<LiveCharkleEngine>) {
    let mut rx = engine.subscribe_events();
    tauri::async_runtime::spawn(async move {
        loop {
            match rx.recv().await {
                Ok(EngineEvent::LibraryChanged) => {
                    let _ = app.emit("library:changed", ());
                }
                Ok(EngineEvent::SyncStatus(status)) => {
                    let _ = app.emit("sync:status", status);
                }
                Ok(EngineEvent::AssetEnriched(id)) => {
                    let _ = app.emit("asset:enriched", format_swift_uuid(&id));
                }
                Ok(EngineEvent::BoardUpdated(id)) => {
                    let _ = app.emit("board:updated", format_swift_uuid(&id));
                }
                Err(tokio::sync::broadcast::error::RecvError::Lagged(_)) => {
                    let _ = app.emit("library:changed", ());
                }
                Err(tokio::sync::broadcast::error::RecvError::Closed) => break,
            }
        }
    });
}
