//! M4 Moodboard Studio IPC commands:
//! 4+1 MMR Curation & 8-phase streaming Agent Harness, deterministic Editorial Layout solver,
//! 1x/2x PNG/JPEG image export, clipboard copy, and offline `.charkleboard` Figma Bridge ZIP export.

use std::path::PathBuf;

use charkle_core::export::{BoardImageFormat, FigmaBridgeExportReport, MoodboardExportOptions};
use charkle_core::layout::EditorialLayoutResult;
use charkle_core::models::moodboard::{
    MoodboardCurationRequest, MoodboardDocument, MoodboardProposal,
};
use charkle_platform_win::clipboard::write_png_to_clipboard;
use tauri::{AppHandle, Emitter, State};

use crate::commands::{AppState, IpcError, IpcResult};

#[tauri::command]
pub async fn curate_moodboard(
    app: AppHandle,
    state: State<'_, AppState>,
    request: MoodboardCurationRequest,
) -> IpcResult<MoodboardProposal> {
    let proposal = state
        .engine
        .curate_moodboard(&request, |step| {
            let _ = app.emit("moodboard:agent-step", &step);
        })
        .await?;
    Ok(proposal)
}

#[tauri::command]
pub fn solve_editorial_layout(
    state: State<'_, AppState>,
    document: MoodboardDocument,
    container_width: f64,
) -> IpcResult<EditorialLayoutResult> {
    state
        .engine
        .solve_editorial_layout(&document, container_width)
        .map_err(Into::into)
}

#[tauri::command]
pub async fn export_board_image_file(
    state: State<'_, AppState>,
    document: MoodboardDocument,
    options: MoodboardExportOptions,
    destination_path: String,
) -> IpcResult<usize> {
    let engine = state.engine.clone();
    let path = PathBuf::from(destination_path);
    let bytes = tokio::task::spawn_blocking(move || {
        let rendered = engine.export_board_image_bytes(&document, &options)?;
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent)?;
        }
        std::fs::write(&path, &rendered)?;
        Ok::<usize, charkle_core::error::CoreError>(rendered.len())
    })
    .await
    .map_err(|e| IpcError {
        code: "EXPORT_FAILED",
        message: format!("Board image export worker failed: {e}"),
    })??;
    Ok(bytes)
}

#[tauri::command]
pub async fn copy_board_image_to_clipboard(
    state: State<'_, AppState>,
    document: MoodboardDocument,
    mut options: MoodboardExportOptions,
) -> IpcResult<usize> {
    options.format = BoardImageFormat::Png;
    let engine = state.engine.clone();
    let byte_len = tokio::task::spawn_blocking(move || {
        let png = engine
            .export_board_image_bytes(&document, &options)
            .map_err(|e| e.to_string())?;
        let len = png.len();
        write_png_to_clipboard(&png)?;
        Ok::<usize, String>(len)
    })
    .await
    .map_err(|e| IpcError {
        code: "CLIPBOARD_EXPORT_FAILED",
        message: format!("Clipboard export worker failed: {e}"),
    })?
    .map_err(|msg| IpcError {
        code: "CLIPBOARD_EXPORT_FAILED",
        message: msg,
    })?;
    Ok(byte_len)
}

#[tauri::command]
pub async fn export_board_figma_bridge(
    state: State<'_, AppState>,
    document: MoodboardDocument,
    options: MoodboardExportOptions,
    destination_path: String,
) -> IpcResult<FigmaBridgeExportReport> {
    let engine = state.engine.clone();
    let path = PathBuf::from(destination_path);
    let report = tokio::task::spawn_blocking(move || {
        engine.export_board_figma_bridge(&document, &options, &path)
    })
    .await
    .map_err(|e| IpcError {
        code: "FIGMA_EXPORT_FAILED",
        message: format!("Figma bridge export worker failed: {e}"),
    })??;
    Ok(report)
}
