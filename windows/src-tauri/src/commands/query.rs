use charkle_core::models::core::QuickJumpMatch;
use charkle_core::models::moodboard::{MoodboardDocument, MoodboardSummary};
use tauri::State;

use super::{parse_uuid, AppState, IpcResult};

#[tauri::command]
pub fn quick_jump(
    state: State<'_, AppState>,
    query: String,
    limit: Option<usize>,
) -> IpcResult<Vec<QuickJumpMatch>> {
    state
        .engine
        .quick_jump(&query, limit.unwrap_or(24))
        .map_err(Into::into)
}

#[tauri::command]
pub fn fetch_boards(state: State<'_, AppState>) -> IpcResult<Vec<MoodboardSummary>> {
    state.engine.fetch_boards().map_err(Into::into)
}

#[tauri::command]
pub fn fetch_board(state: State<'_, AppState>, id: String) -> IpcResult<Option<MoodboardDocument>> {
    let uuid = parse_uuid(&id)?;
    state.engine.fetch_board(uuid).map_err(Into::into)
}

#[tauri::command]
pub fn save_board(
    state: State<'_, AppState>,
    document: MoodboardDocument,
) -> IpcResult<MoodboardDocument> {
    state.engine.save_board(&document).map_err(Into::into)
}

#[tauri::command]
pub fn delete_board(state: State<'_, AppState>, id: String) -> IpcResult<()> {
    let uuid = parse_uuid(&id)?;
    state.engine.delete_board(uuid).map_err(Into::into)
}

#[tauri::command]
pub fn set_board_pinned_offline(
    state: State<'_, AppState>,
    id: String,
    pinned: bool,
) -> IpcResult<MoodboardDocument> {
    let uuid = parse_uuid(&id)?;
    state
        .engine
        .set_board_pinned_offline(uuid, pinned)
        .map_err(Into::into)
}

#[tauri::command]
pub async fn seed_sample_library_if_empty(state: State<'_, AppState>) -> IpcResult<bool> {
    state
        .engine
        .seed_sample_library_if_empty()
        .await
        .map_err(Into::into)
}
