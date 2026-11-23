//! Charkle Windows Tauri v2 desktop application shell.
//!
//! Wires `charkle-core` (`LiveCharkleEngine`) with concrete `charkle-platform-win`
//! Win32/WinRT providers (DPAPI/Credential Manager, WinRT OCR, STA Shell Thumbnails,
//! Volume Mount Inspector, Win11 Mica + Snap Layouts, Top-Edge Drop Shelf, OLE drag-out,
//! multi-DPI Region Capture, Clipboard Listener, Global Hotkeys, System Tray, Autostart,
//! Single-Instance, and `charkle://` deep links).

pub mod commands;
pub mod desktop;
pub mod events;
pub mod protocol;

use std::path::PathBuf;
use std::sync::atomic::AtomicBool;
use std::sync::{Arc, Mutex};

use charkle_core::db::LibraryDatabase;
use charkle_core::engine::LiveCharkleEngine;
use charkle_core::media::MediaPipeline;
use charkle_platform_win::clipboard::start_clipboard_listener;
use charkle_platform_win::shelf_win::start_top_edge_drag_monitor;
use charkle_platform_win::windowing::{apply_window_chrome, install_snap_layout_subclass};
use charkle_platform_win::{
    WinCredentialVault, WinRtOcrProvider, WinShellThumbnailProvider, WinVolumeMountInspector,
};
use tauri::{Emitter, Manager};
use tauri_plugin_autostart::MacosLauncher;
use tauri_plugin_deep_link::DeepLinkExt;

use crate::commands::AppState;
use crate::desktop::{
    ensure_shelf_window, handle_deep_link_url, read_initial_clipboard_preview,
    register_configured_hotkeys, setup_system_tray, show_or_focus_main_window, show_shelf_window,
    CaptureFrameStore, HotkeyConfig,
};

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
        // Single-instance MUST be registered first so secondary invocations forward args & exit
        .plugin(tauri_plugin_single_instance::init(|app, args, _cwd| {
            show_or_focus_main_window(app);
            for arg in args.iter().skip(1) {
                if arg.starts_with("charkle://") {
                    handle_deep_link_url(app, arg);
                }
            }
        }))
        .plugin(tauri_plugin_deep_link::init())
        .plugin(tauri_plugin_autostart::init(
            MacosLauncher::LaunchAgent,
            Some(vec!["--autostart"]),
        ))
        .plugin(tauri_plugin_global_shortcut::Builder::new().build())
        .plugin(tauri_plugin_dialog::init())
        .register_uri_scheme_protocol("charkle-media", |ctx, request| {
            let state = ctx.app_handle().state::<AppState>();
            protocol::handle_media_request(&state.engine, Some(&state.capture_frames), &request)
        })
        .setup(|app| {
            let data_dir = resolve_data_dir(app);
            std::fs::create_dir_all(&data_dir)?;
            tracing::info!("Opening Charkle library at {}", data_dir.display());

            let db = Arc::new(
                LibraryDatabase::open(&data_dir.join("Library.sqlite3"))
                    .map_err(|e| Box::new(e) as Box<dyn std::error::Error>)?,
            );
            let shell_thumbs = Arc::new(WinShellThumbnailProvider::new());
            let media = MediaPipeline::with_shell_thumbnail_provider(&data_dir, shell_thumbs)
                .map_err(|e| Box::new(e) as Box<dyn std::error::Error>)?;
            let vault = Arc::new(WinCredentialVault::new());
            let ocr = Arc::new(WinRtOcrProvider::new());
            let mount_inspector = Arc::new(WinVolumeMountInspector::new());

            let engine = Arc::new(LiveCharkleEngine::new(
                db,
                media,
                vault,
                ocr,
                mount_inspector,
                None,
            ));

            let hotkey_cfg = HotkeyConfig::load(&data_dir);
            let latest_clipboard = Arc::new(Mutex::new(read_initial_clipboard_preview()));

            // Live Win32 clipboard format listener (`AddClipboardFormatListener`)
            let app_for_clip = app.handle().clone();
            let clip_slot = Arc::clone(&latest_clipboard);
            let clipboard_listener = start_clipboard_listener(move |preview| {
                if let Ok(mut guard) = clip_slot.lock() {
                    *guard = Some(preview.clone());
                }
                let _ = app_for_clip.emit("clipboard:changed", preview);
            });

            // Top-edge external drag hover detector to spring open the non-activating Drop Shelf
            let app_for_edge = app.handle().clone();
            let top_edge_monitor = start_top_edge_drag_monitor(move || {
                let handle = app_for_edge.clone();
                let _ = app_for_edge.run_on_main_thread(move || {
                    let _ = show_shelf_window(&handle, false);
                });
            });

            app.manage(AppState {
                engine: Arc::clone(&engine),
                data_dir,
                capture_frames: Arc::new(CaptureFrameStore::default()),
                hotkeys: Arc::new(Mutex::new(hotkey_cfg.clone())),
                shelf_pinned: Arc::new(AtomicBool::new(false)),
                latest_clipboard,
                _clipboard_listener: Some(clipboard_listener),
                _top_edge_monitor: Some(top_edge_monitor),
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

            // Pre-warm hidden transparent Top-Edge Drop Shelf window
            if let Err(err) = ensure_shelf_window(app.handle()) {
                tracing::warn!(%err, "Failed to pre-warm Drop Shelf window");
            }

            // System Tray icon & quick menu
            if let Err(err) = setup_system_tray(app.handle()) {
                tracing::warn!(%err, "Failed to initialize system tray");
            }

            // Global shortcuts (Alt+Shift+A/S/V)
            if let Err(err) = register_configured_hotkeys(app.handle(), &hotkey_cfg) {
                tracing::warn!(%err, "Failed to register global hotkeys");
            }

            // Deep link runtime handler (`charkle://`)
            let app_for_link = app.handle().clone();
            app.deep_link().on_open_url(move |event| {
                for url in event.urls() {
                    handle_deep_link_url(&app_for_link, url.as_str());
                }
            });

            // Handle any `charkle://` URL passed at cold start
            for arg in std::env::args().skip(1) {
                if arg.starts_with("charkle://") {
                    handle_deep_link_url(app.handle(), &arg);
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
            // M3 Native Windows Shelf, OLE Drag-Out, Capture, Clipboard, Hotkeys, Autostart & OCR
            commands::native::start_outbound_drag,
            commands::native::set_shelf_hit_rect,
            commands::native::toggle_shelf,
            commands::native::show_shelf,
            commands::native::hide_shelf,
            commands::native::set_shelf_pinned,
            commands::native::start_region_capture,
            commands::native::get_capture_session,
            commands::native::commit_region_capture,
            commands::native::cancel_region_capture,
            commands::native::collect_clipboard_now,
            commands::native::get_clipboard_preview,
            commands::native::get_desktop_integration_status,
            commands::native::set_autostart_enabled,
            commands::native::update_hotkeys,
            commands::native::get_ocr_diagnostics,
            commands::native::run_asset_ocr,
            commands::native::focus_main_window,
        ])
        .run(tauri::generate_context!())
        .expect("error while running Charkle desktop application");
}
