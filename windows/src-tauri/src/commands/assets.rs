use std::path::PathBuf;

use base64::engine::general_purpose::STANDARD as BASE64_STD;
use base64::Engine;
use charkle_core::engine::BatchLinkMediaExtractionReport;
use charkle_core::media::{
    DeduplicationCleanupResult, DeduplicationResolutionPlan, DeduplicationScanReport,
    DeduplicationScanScope, DeduplicationSensitivity, DuplicateDisposalMode,
    MaterialPackageImportResult, PureRefExportReport, PureRefImportResult, VideoStreamPlaybackPlan,
};
use charkle_core::models::core::{
    AssetBatchPatch, AssetRecord, FilterCriteria, FolderSuggestion, MediaKind, ScoredAsset,
    SocialMediaAttachmentKind,
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

#[tauri::command]
pub async fn ingest_files(
    state: State<'_, AppState>,
    paths: Vec<String>,
    target_folder_id: Option<String>,
    target_board_id: Option<String>,
) -> IpcResult<Vec<AssetRecord>> {
    let folder = parse_optional_uuid(target_folder_id)?;
    let board = parse_optional_uuid(target_board_id)?;
    let path_bufs: Vec<PathBuf> = paths.into_iter().map(PathBuf::from).collect();
    let report = state
        .engine
        .ingest_local_paths(path_bufs, folder, board)
        .await?;
    Ok(report.assets)
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

#[tauri::command]
pub async fn import_material_packages(
    state: State<'_, AppState>,
    paths: Vec<String>,
    target_folder_id: Option<String>,
    target_board_id: Option<String>,
) -> IpcResult<Vec<MaterialPackageImportResult>> {
    let folder = parse_optional_uuid(target_folder_id)?;
    let board = parse_optional_uuid(target_board_id)?;
    let mut results = Vec::with_capacity(paths.len());
    for raw in paths {
        let trimmed = raw.trim();
        if trimmed.is_empty() {
            continue;
        }
        let path = PathBuf::from(trimmed);
        let imported = state
            .engine
            .import_material_package(&path, folder, board)
            .await?;
        results.push(imported);
    }
    Ok(results)
}

#[tauri::command]
pub async fn scan_duplicates(
    state: State<'_, AppState>,
    scope: DeduplicationScanScope,
    sensitivity: DeduplicationSensitivity,
    media_kinds: Option<Vec<MediaKind>>,
) -> IpcResult<DeduplicationScanReport> {
    state
        .engine
        .scan_duplicates(scope, sensitivity, media_kinds)
        .await
        .map_err(Into::into)
}

#[tauri::command]
pub fn resolve_duplicate_groups(
    state: State<'_, AppState>,
    plans: Vec<DeduplicationResolutionPlan>,
    disposal: DuplicateDisposalMode,
    merge_metadata: bool,
) -> IpcResult<DeduplicationCleanupResult> {
    state
        .engine
        .resolve_duplicate_groups(&plans, disposal, merge_metadata)
        .map_err(Into::into)
}

#[tauri::command]
pub async fn import_pureref_scenes(
    state: State<'_, AppState>,
    paths: Vec<String>,
    target_folder_id: Option<String>,
    create_moodboard: Option<bool>,
) -> IpcResult<Vec<PureRefImportResult>> {
    let folder = parse_optional_uuid(target_folder_id)?;
    let make_board = create_moodboard.unwrap_or(true);
    let mut results = Vec::with_capacity(paths.len());
    for raw in paths {
        let trimmed = raw.trim();
        if trimmed.is_empty() {
            continue;
        }
        let path = PathBuf::from(trimmed);
        let res = state
            .engine
            .import_pure_ref_scene(&path, folder, make_board)
            .await?;
        results.push(res);
    }
    Ok(results)
}

#[tauri::command]
pub async fn export_assets_to_pureref(
    state: State<'_, AppState>,
    asset_ids: Vec<String>,
    destination_path: String,
) -> IpcResult<PureRefExportReport> {
    let uuids: Vec<_> = asset_ids
        .iter()
        .map(|s| parse_uuid(s))
        .collect::<IpcResult<Vec<_>>>()?;
    let engine = state.engine.clone();
    let dest = PathBuf::from(destination_path);
    let report =
        tokio::task::spawn_blocking(move || engine.export_assets_to_pure_ref(&uuids, &dest))
            .await
            .map_err(|e| IpcError {
                code: "PUREREF_EXPORT_FAILED",
                message: format!("PureRef export worker failed: {e}"),
            })??;
    Ok(report)
}

#[tauri::command]
pub async fn extract_link_media_attachment(
    state: State<'_, AppState>,
    asset_id: String,
    attachment_url: String,
    attachment_kind: SocialMediaAttachmentKind,
    attachment_index: Option<usize>,
) -> IpcResult<AssetRecord> {
    let uuid = parse_uuid(&asset_id)?;
    state
        .engine
        .extract_link_media_attachment(uuid, attachment_url, attachment_kind, attachment_index)
        .await
        .map_err(Into::into)
}

#[tauri::command]
pub async fn batch_extract_link_media(
    state: State<'_, AppState>,
    asset_ids: Vec<String>,
) -> IpcResult<BatchLinkMediaExtractionReport> {
    let uuids: Vec<_> = asset_ids
        .iter()
        .map(|s| parse_uuid(s))
        .collect::<IpcResult<Vec<_>>>()?;
    state
        .engine
        .batch_extract_link_media(&uuids)
        .await
        .map_err(Into::into)
}

#[tauri::command]
pub async fn resolve_video_playback_plan(
    state: State<'_, AppState>,
    asset_id: String,
) -> IpcResult<VideoStreamPlaybackPlan> {
    let uuid = parse_uuid(&asset_id)?;
    state
        .engine
        .resolve_video_playback_plan(uuid)
        .await
        .map_err(Into::into)
}

#[tauri::command]
pub async fn update_asset_cover_image(
    state: State<'_, AppState>,
    asset_id: String,
    image_base64: String,
) -> IpcResult<AssetRecord> {
    let uuid = parse_uuid(&asset_id)?;
    let clean = image_base64
        .split_once(',')
        .map(|(_, b64)| b64)
        .unwrap_or(&image_base64);
    let data = BASE64_STD.decode(clean.trim()).map_err(|e| IpcError {
        code: "INVALID_BASE64",
        message: format!("封面图片编码无效: {e}"),
    })?;
    let engine = state.engine.clone();
    tokio::task::spawn_blocking(move || engine.update_asset_cover_image(uuid, &data))
        .await
        .map_err(|e| IpcError {
            code: "COVER_UPDATE_FAILED",
            message: format!("更新封面任务失败: {e}"),
        })?
        .map_err(Into::into)
}

#[tauri::command]
pub async fn capture_webview_region_jpeg(
    window: tauri::WebviewWindow,
    x: f64,
    y: f64,
    width: f64,
    height: f64,
    device_pixel_ratio: Option<f64>,
) -> IpcResult<String> {
    let dpr = device_pixel_ratio.unwrap_or(1.0);
    let jpeg = crate::web_snapshot::capture_window_region_jpeg(&window, x, y, width, height, dpr)
        .await
        .map_err(|message| IpcError {
            code: "CAPTURE_REGION_FAILED",
            message,
        })?;
    Ok(BASE64_STD.encode(jpeg))
}
