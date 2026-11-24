use std::path::PathBuf;

use base64::engine::general_purpose::STANDARD as BASE64_STD;
use base64::Engine;
use charkle_core::models::core::{
    AssetBatchPatch, AssetRecord, FilterCriteria, FolderSuggestion, ScoredAsset,
};
use charkle_core::models::media::CaptureInput;
use tauri::State;

use super::{parse_optional_uuid, parse_uuid, AppState, IpcError, IpcResult};

#[tauri::command]
pub fn fetch_assets(
    state: State<'_, AppState>,
    criteria: FilterCriteria,
) -> IpcResult<Vec<AssetRecord>> {
    state.engine.fetch_assets(&criteria).map_err(Into::into)
}

#[tauri::command]
pub fn fetch_asset(state: State<'_, AppState>, id: String) -> IpcResult<Option<AssetRecord>> {
    let uuid = parse_uuid(&id)?;
    state.engine.fetch_asset(uuid).map_err(Into::into)
}

pub(crate) fn collect_ingestable_paths(raw_paths: Vec<String>) -> Vec<PathBuf> {
    fn is_ignored_name(name: &str) -> bool {
        let lower = name.to_ascii_lowercase();
        lower.starts_with('.')
            || lower == "thumbs.db"
            || lower == "desktop.ini"
            || lower == "__macosx"
    }

    fn walk(path: &std::path::Path, out: &mut Vec<PathBuf>, depth: usize) {
        if depth > 8 || out.len() >= 500 {
            return;
        }
        if path.is_file() {
            if let Some(name) = path.file_name().and_then(|n| n.to_str()) {
                if !is_ignored_name(name) {
                    out.push(path.to_path_buf());
                }
            }
            return;
        }
        if path.is_dir() {
            if let Some(name) = path.file_name().and_then(|n| n.to_str()) {
                if depth > 0 && is_ignored_name(name) {
                    return;
                }
            }
            if let Ok(entries) = std::fs::read_dir(path) {
                let mut children: Vec<PathBuf> =
                    entries.filter_map(|e| e.ok().map(|v| v.path())).collect();
                children.sort();
                for child in children {
                    walk(&child, out, depth + 1);
                    if out.len() >= 500 {
                        break;
                    }
                }
            }
        }
    }

    let mut collected = Vec::new();
    for raw in raw_paths {
        let p = PathBuf::from(raw);
        walk(&p, &mut collected, 0);
    }
    collected
}

#[tauri::command]
pub async fn ingest_files(
    state: State<'_, AppState>,
    paths: Vec<String>,
    target_folder_id: Option<String>,
    target_board_id: Option<String>,
) -> IpcResult<Vec<AssetRecord>> {
    let folder = parse_optional_uuid(target_folder_id)?;
    let board = parse_optional_uuid(target_board_id)?;
    let expanded_paths = tokio::task::spawn_blocking(move || collect_ingestable_paths(paths))
        .await
        .unwrap_or_default();
    let inputs: Vec<CaptureInput> = expanded_paths
        .into_iter()
        .map(CaptureInput::FilePath)
        .collect();
    state
        .engine
        .ingest(inputs, folder, board)
        .await
        .map_err(Into::into)
}

#[tauri::command]
pub async fn ingest_url(
    state: State<'_, AppState>,
    url: String,
    title: Option<String>,
    notes: Option<String>,
    target_folder_id: Option<String>,
    target_board_id: Option<String>,
) -> IpcResult<Vec<AssetRecord>> {
    let folder = parse_optional_uuid(target_folder_id)?;
    let board = parse_optional_uuid(target_board_id)?;
    state
        .engine
        .ingest(
            vec![CaptureInput::WebUrl { url, title, notes }],
            folder,
            board,
        )
        .await
        .map_err(Into::into)
}

#[tauri::command]
pub async fn ingest_text(
    state: State<'_, AppState>,
    title: String,
    text: String,
    source_url: Option<String>,
    target_folder_id: Option<String>,
    target_board_id: Option<String>,
) -> IpcResult<Vec<AssetRecord>> {
    let folder = parse_optional_uuid(target_folder_id)?;
    let board = parse_optional_uuid(target_board_id)?;
    state
        .engine
        .ingest(
            vec![CaptureInput::TextSnippet {
                title,
                text,
                source_url,
            }],
            folder,
            board,
        )
        .await
        .map_err(Into::into)
}

#[tauri::command]
pub async fn ingest_swatch(
    state: State<'_, AppState>,
    hex: String,
    title: Option<String>,
    target_folder_id: Option<String>,
    target_board_id: Option<String>,
) -> IpcResult<Vec<AssetRecord>> {
    let folder = parse_optional_uuid(target_folder_id)?;
    let board = parse_optional_uuid(target_board_id)?;
    state
        .engine
        .ingest(
            vec![CaptureInput::ColorSwatch { hex, title }],
            folder,
            board,
        )
        .await
        .map_err(Into::into)
}

#[tauri::command]
pub async fn ingest_image_base64(
    state: State<'_, AppState>,
    data_base64: String,
    suggested_name: String,
    source_url: Option<String>,
    target_folder_id: Option<String>,
    target_board_id: Option<String>,
) -> IpcResult<Vec<AssetRecord>> {
    let folder = parse_optional_uuid(target_folder_id)?;
    let board = parse_optional_uuid(target_board_id)?;
    let clean = data_base64
        .split_once(',')
        .map(|(_, b64)| b64)
        .unwrap_or(&data_base64);
    let data = BASE64_STD.decode(clean.trim()).map_err(|e| IpcError {
        code: "INVALID_BASE64",
        message: format!("Invalid base64 image payload: {e}"),
    })?;
    state
        .engine
        .ingest(
            vec![CaptureInput::ImageData {
                data,
                suggested_name,
                source_url,
            }],
            folder,
            board,
        )
        .await
        .map_err(Into::into)
}

#[tauri::command]
pub fn update_assets(
    state: State<'_, AppState>,
    patch: AssetBatchPatch,
) -> IpcResult<Vec<AssetRecord>> {
    state.engine.update_assets(&patch).map_err(Into::into)
}

#[tauri::command]
pub fn permanently_delete_assets(state: State<'_, AppState>, ids: Vec<String>) -> IpcResult<()> {
    let uuids: Vec<_> = ids
        .iter()
        .map(|s| parse_uuid(s))
        .collect::<IpcResult<Vec<_>>>()?;
    state
        .engine
        .permanently_delete_assets(&uuids)
        .map_err(Into::into)
}

#[tauri::command]
pub fn mark_asset_opened(state: State<'_, AppState>, id: String) -> IpcResult<Option<AssetRecord>> {
    let uuid = parse_uuid(&id)?;
    state.engine.mark_asset_opened(uuid).map_err(Into::into)
}

#[tauri::command]
pub fn similar_assets(
    state: State<'_, AppState>,
    asset_id: String,
    limit: Option<usize>,
) -> IpcResult<Vec<ScoredAsset>> {
    let uuid = parse_uuid(&asset_id)?;
    state
        .engine
        .similar_assets(uuid, limit.unwrap_or(12))
        .map_err(Into::into)
}

#[tauri::command]
pub fn suggest_folder(
    state: State<'_, AppState>,
    asset_id: String,
) -> IpcResult<Option<FolderSuggestion>> {
    let uuid = parse_uuid(&asset_id)?;
    state.engine.suggest_folder(uuid).map_err(Into::into)
}

#[tauri::command]
pub fn hydrate_image_metadata(
    state: State<'_, AppState>,
    id: String,
) -> IpcResult<Option<AssetRecord>> {
    let uuid = parse_uuid(&id)?;
    state
        .engine
        .hydrate_image_metadata(uuid)
        .map_err(Into::into)
}

#[tauri::command]
pub async fn refresh_rich_asset(state: State<'_, AppState>, id: String) -> IpcResult<AssetRecord> {
    let uuid = parse_uuid(&id)?;
    state
        .engine
        .refresh_rich_asset(uuid)
        .await
        .map_err(Into::into)
}
