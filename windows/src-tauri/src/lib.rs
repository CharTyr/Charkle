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
pub mod web_snapshot;

use std::backtrace::Backtrace;
use std::io::Write;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, AtomicIsize, AtomicU64, AtomicU8};
use std::sync::{Arc, Mutex};

use charkle_core::bridge::LocalExtensionBridgeServer;
use charkle_core::db::LibraryDatabase;
use charkle_core::engine::LiveCharkleEngine;
use charkle_core::intelligence::CloudAIUsageStore;
use charkle_core::media::MediaPipeline;
use charkle_core::wire::swift_codec::format_swift_uuid;
use charkle_platform_win::clipboard::start_clipboard_listener;
use charkle_platform_win::shelf_win::{start_top_edge_monitor, ShelfDockEdge, ShelfMonitorConfig};
use charkle_platform_win::wake::start_library_wake_listener;
use charkle_platform_win::{
    WinCredentialVault, WinRtOcrProvider, WinShellThumbnailProvider, WinVolumeMountInspector,
};
use tauri::{Emitter, Manager};
use tauri_plugin_autostart::MacosLauncher;
use tauri_plugin_deep_link::DeepLinkExt;

use crate::commands::AppState;
use crate::desktop::{
    configure_main_window, ensure_shelf_window, handle_deep_link_url, hide_shelf_window,
    read_initial_clipboard_preview, register_configured_hotkeys, setup_system_tray,
    show_or_focus_main_window, show_shelf_window_async, CaptureFrameStore, HotkeyConfig,
    ShelfSettings,
};
use crate::web_snapshot::TauriWebViewSnapshotter;

fn resolve_data_dir(app: &tauri::App) -> PathBuf {
    app.path().app_data_dir().unwrap_or_else(|_| {
        std::env::var_os("LOCALAPPDATA")
            .map(PathBuf::from)
            .unwrap_or_else(std::env::temp_dir)
            .join("Charkle")
    })
}

fn crash_log_path() -> PathBuf {
    std::env::var_os("APPDATA")
        .or_else(|| std::env::var_os("LOCALAPPDATA"))
        .map(PathBuf::from)
        .unwrap_or_else(std::env::temp_dir)
        .join("app.charkle.windows")
        .join("crash.log")
}

/// Installs a panic hook that safely appends timestamp, thread, location, message,
/// and backtrace to `%APPDATA%\app.charkle.windows\crash.log` without ever panicking.
fn install_crash_panic_hook() {
    let previous = std::panic::take_hook();
    std::panic::set_hook(Box::new(move |info| {
        let timestamp = chrono::Utc::now().to_rfc3339();
        let thread_name = std::thread::current()
            .name()
            .unwrap_or("<unnamed>")
            .to_string();
        let location = info
            .location()
            .map(|l| format!("{}:{}:{}", l.file(), l.line(), l.column()))
            .unwrap_or_else(|| "<unknown>".to_string());
        let message = if let Some(s) = info.payload().downcast_ref::<&str>() {
            (*s).to_string()
        } else if let Some(s) = info.payload().downcast_ref::<String>() {
            s.clone()
        } else {
            "<non-string panic payload>".to_string()
        };
        let backtrace = Backtrace::force_capture();

        let path = crash_log_path();
        if let Some(parent) = path.parent() {
            let _ = std::fs::create_dir_all(parent);
        }
        if let Ok(mut file) = std::fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(&path)
        {
            let _ = writeln!(
                file,
                "=== Charkle Panic [{timestamp}] ===\nThread: {thread_name}\nLocation: {location}\nMessage: {message}\nBacktrace:\n{backtrace}\n"
            );
            let _ = file.flush();
        }
        previous(info);
    }));
}

pub fn run() {
    install_crash_panic_hook();

    let _ = tracing_subscriber::fmt()
        .with_writer(std::io::stderr)
        .try_init();

    tauri::Builder::default()
        // Single-instance MUST be registered first so secondary invocations forward args & exit
        .plugin(tauri_plugin_single_instance::init(|app, args, _cwd| {
            let deep_links: Vec<&str> = args
                .iter()
                .skip(1)
                .filter(|arg| arg.starts_with("charkle://"))
                .map(String::as_str)
                .collect();
            if deep_links.is_empty() {
                show_or_focus_main_window(app);
            } else {
                for link in deep_links {
                    handle_deep_link_url(app, link);
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
        .register_asynchronous_uri_scheme_protocol("charkle-media", |ctx, request, responder| {
            let app = ctx.app_handle().clone();
            if protocol::is_xhs_proxy_route(&request) {
                let data_dir = app.state::<AppState>().data_dir.clone();
                tauri::async_runtime::spawn(async move {
                    let response = protocol::handle_xhs_proxy_request(&data_dir, &request).await;
                    responder.respond(response);
                });
            } else if request.method() == "OPTIONS" {
                let state = app.state::<AppState>();
                let response = protocol::handle_media_request(
                    &state.engine,
                    Some(&state.capture_frames),
                    &request,
                );
                responder.respond(response);
            } else {
                // Offload all disk I/O, range reads, and SQLite lookups off the Win32 WebView2 UI
                // thread so opening the Drop Shelf or fast-scrolling never stalls message pumping.
                let state = app.state::<AppState>();
                let engine = Arc::clone(&state.engine);
                let capture_frames = Arc::clone(&state.capture_frames);
                tauri::async_runtime::spawn_blocking(move || {
                    let response =
                        protocol::handle_media_request(&engine, Some(&capture_frames), &request);
                    responder.respond(response);
                });
            }
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
            let web_snapshotter = Arc::new(TauriWebViewSnapshotter::new(app.handle().clone()));
            let media = MediaPipeline::with_shell_thumbnail_provider(&data_dir, shell_thumbs)
                .map_err(|e| Box::new(e) as Box<dyn std::error::Error>)?
                .with_web_snapshotter(web_snapshotter);
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
            let shelf_cfg = ShelfSettings::load(&data_dir);
            let shelf_enabled = Arc::new(AtomicBool::new(shelf_cfg.enabled));
            let shelf_hover_trigger = Arc::new(AtomicBool::new(shelf_cfg.hover_trigger_enabled));
            let shelf_dock_edge = Arc::new(AtomicU8::new(
                ShelfDockEdge::from_str_lossy(&shelf_cfg.dock_edge).to_u8(),
            ));
            let shelf_expanded = Arc::new(AtomicBool::new(false));
            let shelf_pinned = Arc::new(AtomicBool::new(false));
            let shelf_drag_hovering = Arc::new(AtomicBool::new(false));
            let shelf_busy = Arc::new(AtomicBool::new(false));
            let shelf_hold_until_ms = Arc::new(AtomicU64::new(0));
            let shelf_hwnd = Arc::new(AtomicIsize::new(0));
            let shelf_anim_gen = Arc::new(AtomicU64::new(0));
            let shelf_minimal_mode = Arc::new(AtomicBool::new(false));
            let explicit_quit = Arc::new(AtomicBool::new(false));
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

            // Top-edge drag & hover detector + unpinned auto-collapse monitor
            let app_for_edge_open = app.handle().clone();
            let app_for_edge_close = app.handle().clone();
            let top_edge_monitor = start_top_edge_monitor(
                ShelfMonitorConfig {
                    enabled: Arc::clone(&shelf_enabled),
                    hover_trigger_enabled: Arc::clone(&shelf_hover_trigger),
                    dock_edge: Arc::clone(&shelf_dock_edge),
                    shelf_expanded: Arc::clone(&shelf_expanded),
                    shelf_pinned: Arc::clone(&shelf_pinned),
                    shelf_drag_hovering: Arc::clone(&shelf_drag_hovering),
                    shelf_busy: Arc::clone(&shelf_busy),
                    shelf_hold_until_ms: Arc::clone(&shelf_hold_until_ms),
                    shelf_hwnd: Arc::clone(&shelf_hwnd),
                },
                move || {
                    let handle = app_for_edge_open.clone();
                    tauri::async_runtime::spawn(async move {
                        if let Err(err) = show_shelf_window_async(&handle, false).await {
                            tracing::warn!(%err, "Top-edge monitor failed to open Drop Shelf");
                        }
                    });
                },
                move || {
                    let handle = app_for_edge_close.clone();
                    let _ = app_for_edge_close.run_on_main_thread(move || {
                        hide_shelf_window(&handle);
                    });
                },
            );

            let usage_store = Arc::new(CloudAIUsageStore::open(&data_dir));
            let engine_for_wake = Arc::clone(&engine);
            let app_for_wake = app.handle().clone();
            let wake_listener = start_library_wake_listener(data_dir.clone(), move || {
                engine_for_wake.notify_external_change();
                let _ = app_for_wake.emit("board:updated", "external-cli");
            });

            // Local Browser Extension Bridge (`127.0.0.1:41937..=41946`) with ~450ms debounced
            // live UI refresh (`extension:imported` + `library:changed`).
            #[derive(Clone, serde::Serialize)]
            #[serde(rename_all = "camelCase")]
            struct ExtensionImportedEvent {
                count: usize,
                target_folder_id: Option<String>,
                target_board_id: Option<String>,
            }
            let app_for_ext = app.handle().clone();
            let extension_bridge = Arc::new(LocalExtensionBridgeServer::new(
                Arc::clone(&engine),
                data_dir.clone(),
                Some(Arc::new(move |mutation| {
                    if mutation.imported_count > 0 {
                        let _ = app_for_ext.emit(
                            "extension:imported",
                            ExtensionImportedEvent {
                                count: mutation.imported_count,
                                target_folder_id: mutation
                                    .target_folder_id
                                    .map(|id| format_swift_uuid(&id)),
                                target_board_id: mutation
                                    .target_board_id
                                    .map(|id| format_swift_uuid(&id)),
                            },
                        );
                    }
                    let _ = app_for_ext.emit("library:changed", ());
                })),
            ));

            let bridge_for_boot = Arc::clone(&extension_bridge);
            tauri::async_runtime::spawn(async move {
                let status = bridge_for_boot.status().await;
                if status.enabled {
                    if let Err(err) = bridge_for_boot.start().await {
                        tracing::warn!(%err, "Failed to start local browser extension bridge");
                    }
                }
            });

            // Idempotent startup background upgrade for legacy non-900x1440 Xiaohongshu covers.
            let engine_for_xhs = Arc::clone(&engine);
            tauri::async_runtime::spawn(async move {
                let upgraded = engine_for_xhs
                    .upgrade_legacy_xiaohongshu_covers_if_needed()
                    .await;
                if !upgraded.is_empty() {
                    tracing::info!(
                        count = upgraded.len(),
                        "Upgraded legacy Xiaohongshu covers to native 900x1440 cards"
                    );
                }
            });

            app.manage(AppState {
                engine: Arc::clone(&engine),
                extension_bridge,
                data_dir,
                usage_store,
                capture_frames: Arc::new(CaptureFrameStore::default()),
                hotkeys: Arc::new(Mutex::new(hotkey_cfg.clone())),
                shelf_settings: Arc::new(Mutex::new(shelf_cfg)),
                shelf_enabled,
                shelf_hover_trigger,
                shelf_dock_edge,
                shelf_expanded,
                shelf_pinned,
                shelf_drag_hovering,
                shelf_busy,
                shelf_hold_until_ms,
                shelf_hwnd,
                shelf_anim_gen,
                shelf_minimal_mode,
                explicit_quit,
                latest_clipboard,
                _clipboard_listener: Some(clipboard_listener),
                _top_edge_monitor: Some(top_edge_monitor),
                _wake_listener: Some(wake_listener),
            });

            events::spawn_event_bridge(app.handle().clone(), Arc::clone(&engine));

            if let Some(main_win) = app.get_webview_window("main") {
                configure_main_window(app.handle(), &main_win);
                commands::window::attach_surface_change_emitter(&main_win);
                let _ = main_win.show();
                let _ = main_win.set_focus();
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
            commands::media::open_directory_in_explorer,
            commands::media::open_external_url,
            // Sync
            commands::sync::sync_config,
            commands::sync::save_sync_config,
            commands::sync::sync_status,
            commands::sync::sync_now,
            commands::sync::get_sync_auth_state,
            commands::sync::save_google_oauth_client,
            commands::sync::import_google_oauth_secret_file,
            commands::sync::sign_in_google_drive,
            commands::sync::sign_out_google_drive,
            commands::sync::test_webdav_connection,
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
            commands::native::open_main_window,
            commands::native::set_minimal_mode,
            commands::native::open_asset_in_main_window,
            commands::native::copy_assets_to_clipboard,
            commands::native::get_shelf_settings,
            commands::native::save_shelf_settings,
            commands::native::set_shelf_allow_activate,
            // M4 Moodboard Studio, Curator Harness & Exporters
            commands::moodboard::curate_moodboard,
            commands::moodboard::solve_editorial_layout,
            commands::moodboard::export_board_image_file,
            commands::moodboard::copy_board_image_to_clipboard,
            commands::moodboard::export_board_figma_bridge,
            // M5 Hybrid Cloud AI, TypeSafe Jev, External Agent, Migration & Diagnostics
            commands::settings::get_ai_provider_state,
            commands::settings::save_ai_provider_config,
            commands::settings::test_ai_provider_connection,
            commands::settings::reset_ai_usage,
            commands::settings::sign_in_with_chatgpt,
            commands::settings::disconnect_chatgpt_account,
            commands::settings::get_typesafe_state,
            commands::settings::save_typesafe_config,
            commands::settings::test_typesafe_connection,
            commands::settings::run_inbox_smart_triage,
            commands::settings::get_external_agent_state,
            commands::settings::save_external_agent_config,
            commands::settings::run_external_agent_self_check,
            commands::settings::rebuild_local_visual_index,
            commands::settings::save_webdav_password,
            commands::settings::run_storage_migration,
            commands::settings::get_system_diagnostics,
            commands::settings::export_figma_plugin_bundle,
            commands::settings::get_extension_bridge_state,
            commands::settings::set_extension_bridge_enabled,
            commands::settings::set_extension_auto_pair,
            commands::settings::regenerate_extension_bridge_token,
            commands::settings::reveal_bundled_browser_extension,
        ])
        .build(tauri::generate_context!())
        .expect("error while building Charkle desktop application")
        .run(|app_handle, event| match event {
            tauri::RunEvent::ExitRequested { api, .. } => {
                if let Some(state) = app_handle.try_state::<AppState>() {
                    if state
                        .shelf_minimal_mode
                        .load(std::sync::atomic::Ordering::SeqCst)
                        && !state
                            .explicit_quit
                            .load(std::sync::atomic::Ordering::SeqCst)
                    {
                        api.prevent_exit();
                    }
                }
            }
            tauri::RunEvent::Exit => {
                if let Some(state) = app_handle.try_state::<AppState>() {
                    let bridge = Arc::clone(&state.extension_bridge);
                    tauri::async_runtime::block_on(async move {
                        let _ = bridge.stop().await;
                    });
                }
            }
            _ => {}
        });
}
