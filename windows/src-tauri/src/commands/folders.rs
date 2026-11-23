use charkle_core::models::core::{FolderRecord, SmartFolderRecord, TagCount};
use tauri::State;

use super::{parse_optional_uuid, parse_uuid, AppState, IpcResult};

#[tauri::command]
pub fn fetch_folders(state: State<'_, AppState>) -> IpcResult<Vec<FolderRecord>> {
    state.engine.fetch_folders().map_err(Into::into)
}

#[tauri::command]
pub fn create_folder(
    state: State<'_, AppState>,
    name: String,
    parent_id: Option<String>,
) -> IpcResult<FolderRecord> {
    let parent = parse_optional_uuid(parent_id)?;
    state
        .engine
        .create_folder(&name, parent)
        .map_err(Into::into)
}

#[tauri::command]
pub fn rename_folder(
    state: State<'_, AppState>,
    id: String,
    new_name: String,
) -> IpcResult<FolderRecord> {
    let uuid = parse_uuid(&id)?;
    state
        .engine
        .rename_folder(uuid, &new_name)
        .map_err(Into::into)
}

#[tauri::command]
pub fn move_folder(
    state: State<'_, AppState>,
    id: String,
    new_parent_id: Option<String>,
    insert_at_index: Option<usize>,
) -> IpcResult<Vec<FolderRecord>> {
    let uuid = parse_uuid(&id)?;
    let parent = parse_optional_uuid(new_parent_id)?;
    state
        .engine
        .move_folder(uuid, parent, insert_at_index)
        .map_err(Into::into)
}

#[tauri::command]
pub fn update_folder_appearance(
    state: State<'_, AppState>,
    id: String,
    color_hex: Option<String>,
    custom_symbol: Option<String>,
) -> IpcResult<FolderRecord> {
    let uuid = parse_uuid(&id)?;
    state
        .engine
        .update_folder_appearance(uuid, color_hex, custom_symbol)
        .map_err(Into::into)
}

#[tauri::command]
pub fn delete_folder(
    state: State<'_, AppState>,
    id: String,
    trash_contents: Option<bool>,
) -> IpcResult<()> {
    let uuid = parse_uuid(&id)?;
    state
        .engine
        .delete_folder(uuid, trash_contents.unwrap_or(false))
        .map_err(Into::into)
}

#[tauri::command]
pub fn fetch_smart_folders(state: State<'_, AppState>) -> IpcResult<Vec<SmartFolderRecord>> {
    state.engine.fetch_smart_folders().map_err(Into::into)
}

#[tauri::command]
pub fn save_smart_folder(
    state: State<'_, AppState>,
    folder: SmartFolderRecord,
) -> IpcResult<Vec<SmartFolderRecord>> {
    state.engine.save_smart_folder(folder).map_err(Into::into)
}

#[tauri::command]
pub fn delete_smart_folder(
    state: State<'_, AppState>,
    id: String,
) -> IpcResult<Vec<SmartFolderRecord>> {
    let uuid = parse_uuid(&id)?;
    state.engine.delete_smart_folder(uuid).map_err(Into::into)
}

#[tauri::command]
pub fn fetch_tag_counts(state: State<'_, AppState>) -> IpcResult<Vec<TagCount>> {
    state.engine.fetch_tag_counts().map_err(Into::into)
}

#[tauri::command]
pub fn inbox_count(state: State<'_, AppState>) -> IpcResult<usize> {
    state.engine.inbox_count().map_err(Into::into)
}
