//! Charkle Windows Tauri v2 desktop application shell.
//!
//! Wires `charkle-core` (`LiveCharkleEngine`), `charkle-platform-win` (Win11 Mica + Snap Layouts),
//! zero-copy `charkle-media://` HTTP Range protocol, typed IPC commands, and live event bridge.

pub mod commands;
pub mod events;
pub mod protocol;

use std::path::PathBuf;
use std::sync::Arc;

use charkle_core::engine::LiveCharkleEngine;
use charkle_platform_win::windowing::{apply_window_chrome, install_snap_layout_subclass};
use tauri::Manager;

use crate::commands::AppState;

fn resolve_data_dir(app: &tauri::App) -> PathBuf {
    app.path().app_data_dir().unwrap_or_else(|_| {
        std::env::var_os("LOCALAPPDATA")
            .map(PathBuf::from)
            .unwrap_or_else(std::env::temp_dir)
            .join("Charkle")
    })
}

pub fn run() {
    let _ = tracing_subscriber::fmt()
        .with_writer(std::io::stderr)
        .try_init();

    tauri::Builder::default()
        .plugin(tauri_plugin_dialog::init())
        .register_uri_scheme_protocol("charkle-media", |ctx, request| {
            let state = ctx.app_handle().state::<AppState>();
            protocol::handle_media_request(&state.engine, &request)
        })
        .setup(|app| {
            let data_dir = resolve_data_dir(app);
            tracing::info!("Opening Charkle library at {}", data_dir.display());
            let engine = Arc::new(
                LiveCharkleEngine::open(&data_dir)
                    .map_err(|e| Box::new(e) as Box<dyn std::error::Error>)?,
            );
            app.manage(AppState {
                engine: Arc::clone(&engine),
            });

            events::spawn_event_bridge(app.handle().clone(), Arc::clone(&engine));

            if let Some(main_win) = app.get_webview_window("main") {
                #[cfg(target_os = "windows")]
                if let Ok(hwnd) = main_win.hwnd() {
                    let raw = hwnd.0 as isize;
                    let surface = apply_window_chrome(raw, false);
                    let snap_ok = install_snap_layout_subclass(raw);
                    tracing::info!(
                        build = surface.build_number,
                        backdrop = ?surface.backdrop,
                        snap_ok,
                        "Applied Windows chrome"
                    );
                }
            }

            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            // Assets
            commands::assets::fetch_assets,
            commands::assets::fetch_asset,
            commands::assets::ingest_files,
            commands::assets::ingest_url,
            commands::assets::ingest_text,
            commands::assets::ingest_swatch,
            commands::assets::ingest_image_base64,
            commands::assets::update_assets,
            commands::assets::permanently_delete_assets,
            commands::assets::mark_asset_opened,
            commands::assets::similar_assets,
            commands::assets::suggest_folder,
            commands::assets::hydrate_image_metadata,
            commands::assets::refresh_rich_asset,
            // Folders, Smart Folders & Tags
            commands::folders::fetch_folders,
            commands::folders::create_folder,
            commands::folders::rename_folder,
            commands::folders::move_folder,
            commands::folders::update_folder_appearance,
            commands::folders::delete_folder,
            commands::folders::fetch_smart_folders,
            commands::folders::save_smart_folder,
            commands::folders::delete_smart_folder,
            commands::folders::fetch_tag_counts,
            commands::folders::inbox_count,
            // Query, Boards & Seeding
            commands::query::quick_jump,
            commands::query::fetch_boards,
            commands::query::fetch_board,
            commands::query::save_board,
            commands::query::delete_board,
            commands::query::set_board_pinned_offline,
            commands::query::seed_sample_library_if_empty,
            // Media Cache & Explorer
            commands::media::cache_stats,
            commands::media::set_cache_budget_bytes,
            commands::media::evict_cache_now,
            commands::media::read_asset_text_content,
            commands::media::reveal_in_explorer,
            commands::media::open_external_url,
            // Sync
            commands::sync::sync_config,
            commands::sync::save_sync_config,
            commands::sync::sync_status,
            commands::sync::sync_now,
            // Window Chrome & Snap Layouts
            commands::window::set_window_theme,
            commands::window::set_maximize_button_rect,
            commands::window::window_minimize,
            commands::window::window_toggle_maximize,
            commands::window::window_close,
            commands::window::window_is_maximized,
        ])
        .run(tauri::generate_context!())
        .expect("error while running Charkle desktop application");
}
