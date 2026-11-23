//! Multi-device `DriveSyncEngine`, transports, Windows filename sanitization,
//! WebDAV XML parsing, Google PKCE OAuth, lossless two-way `StorageMigration`,
//! and `LiveCharkleEngine` end-to-end integration tests.

use std::path::Path;
use std::sync::Arc;

use charkle_core::db::LibraryDatabase;
use charkle_core::engine::{EngineEvent, LiveCharkleEngine};
use charkle_core::error::CoreError;
use charkle_core::media::MediaPipeline;
use charkle_core::models::core::{AssetBatchPatch, FolderAssignment};
use charkle_core::models::media::CaptureInput;
use charkle_core::models::moodboard::{
    BoardConnector, BoardNode, BoardNodeKind, BoardRect, ConnectorAnchor, ConnectorStyle,
    InkStroke, InkStrokePoint, MoodboardDocument, NoteStyle,
};
use charkle_core::models::sync::{DriveSyncConfig, DriveTransportMode};
use charkle_core::sync::{
    sanitize_windows_filename, DriveSyncEngine, DriveTransport, GoogleOAuthClient,
    GoogleOAuthClientConfig, InMemoryDriveTransport, LocalFolderTransport, MountedVolumeTransport,
    WebDAVTransport,
};
use charkle_core::traits::{
    BasicVolumeMountInspector, InMemorySecretVault, NoopOcrProvider, VolumeMountInspector,
};
use chrono::Utc;
use image::{DynamicImage, ImageFormat, Rgba, RgbaImage};
use tempfile::tempdir;
use url::Url;
use uuid::Uuid;

fn sample_png(color: [u8; 4]) -> Vec<u8> {
    let img = RgbaImage::from_pixel(120, 90, Rgba(color));
    let mut cursor = std::io::Cursor::new(Vec::new());
    DynamicImage::ImageRgba8(img)
        .write_to(&mut cursor, ImageFormat::Png)
        .unwrap();
    cursor.into_inner()
}

fn make_device_engine(dir: &Path, transport: Arc<dyn DriveTransport>) -> LiveCharkleEngine {
    std::fs::create_dir_all(dir).unwrap();
    let db = Arc::new(LibraryDatabase::open(&dir.join("Library.sqlite3")).unwrap());
    let media = MediaPipeline::new(dir).unwrap();
    let engine = LiveCharkleEngine::new(
        db,
        media,
        Arc::new(InMemorySecretVault::new()),
        Arc::new(NoopOcrProvider),
        Arc::new(BasicVolumeMountInspector),
        Some(transport),
    );
    let cfg = DriveSyncConfig {
        mode: DriveTransportMode::DirectApiWithGDirect,
        root_folder_name: "Charkle".to_string(),
        ..DriveSyncConfig::default()
    };
    engine.save_sync_config(cfg).unwrap();
    engine
}

#[tokio::test]
async fn two_devices_converge_tags_concurrent_board_edits_renames_and_permanent_deletes() {
    let tmp = tempdir().unwrap();
    let cloud = Arc::new(InMemoryDriveTransport::default());

    let dev_a = make_device_engine(&tmp.path().join("dev_a"), cloud.clone());
    let dev_b = make_device_engine(&tmp.path().join("dev_b"), cloud.clone());

    // Device A ingests an image, adds tags, creates a folder & Moodboard, and syncs up
    let folder = dev_a.create_folder("References", None).unwrap();
    let assets = dev_a
        .ingest(
            vec![CaptureInput::ImageData {
                data: sample_png([42, 96, 224, 255]),
                suggested_name: "cobalt-study.png".to_string(),
                source_url: None,
            }],
            Some(folder.id),
            None,
        )
        .await
        .unwrap();
    let asset_id = assets[0].id;
    dev_a
        .update_assets(&AssetBatchPatch {
            asset_ids: vec![asset_id],
            add_tags: vec!["blue".to_string(), "draft".to_string()],
            rating: Some(4),
            ..AssetBatchPatch::default()
        })
        .unwrap();

    let mut board = MoodboardDocument::new("Shared Moodboard");
    let node_a_id = Uuid::new_v4();
    board.nodes.push(BoardNode {
        id: node_a_id,
        kind: BoardNodeKind::AssetRef {
            asset_id,
            crop: None,
            weight: 1,
            autoplay_loop: false,
        },
        frame: BoardRect::new(10.0, 10.0, 200.0, 150.0),
        z_index: 0,
        rotation_degrees: 0.0,
        flip_horizontal: false,
        flip_vertical: false,
        is_locked: false,
        editorial_order: 0,
        updated_at: Utc::now(),
    });
    let board = dev_a.save_board(&board).unwrap();

    let rep_a1 = dev_a.sync_now().await.unwrap();
    assert!(rep_a1.uploaded_ops > 0);

    // Device B syncs down and sees folder, asset, tags, and board
    let rep_b1 = dev_b.sync_now().await.unwrap();
    assert!(rep_b1.downloaded_ops > 0);
    let b_asset = dev_b.fetch_asset(asset_id).unwrap().expect("asset on B");
    assert_eq!(b_asset.folder_id, Some(folder.id));
    assert_eq!(b_asset.tags, vec!["blue", "draft"]);
    assert_eq!(b_asset.rating, 4);
    assert!(dev_b.fetch_board(board.id).unwrap().is_some());

    // CONCURRENT EDIT 1: Tag tombstones + Board disjoint node/connector/stroke edits
    // Device A removes "draft" and adds "approved", plus adds a Note node and Connector
    dev_a
        .update_assets(&AssetBatchPatch {
            asset_ids: vec![asset_id],
            add_tags: vec!["approved".to_string()],
            remove_tags: vec!["draft".to_string()],
            ..AssetBatchPatch::default()
        })
        .unwrap();
    let mut board_a = dev_a.fetch_board(board.id).unwrap().unwrap();
    let note_a_id = Uuid::new_v4();
    board_a.nodes.push(BoardNode {
        id: note_a_id,
        kind: BoardNodeKind::Note {
            title: Some("From A".to_string()),
            text: "Lighting note".to_string(),
            style: NoteStyle::Warm,
            font_size: 14.0,
        },
        frame: BoardRect::new(260.0, 20.0, 180.0, 100.0),
        z_index: 1,
        rotation_degrees: 0.0,
        flip_horizontal: false,
        flip_vertical: false,
        is_locked: false,
        editorial_order: 1,
        updated_at: Utc::now(),
    });
    board_a.connectors.push(BoardConnector {
        id: Uuid::new_v4(),
        from_node_id: note_a_id,
        from_anchor: ConnectorAnchor::Leading,
        from_normalized_point: None,
        to_node_id: node_a_id,
        to_anchor: ConnectorAnchor::Trailing,
        to_normalized_point: None,
        label: Some("ref".to_string()),
        color_hex: "#E05A47".to_string(),
        style: ConnectorStyle::Curved,
        dashed: false,
        updated_at: Utc::now(),
    });
    dev_a.save_board(&board_a).unwrap();

    // Device B concurrently adds "editorial" tag + a separate InkStroke on the same board
    dev_b
        .update_assets(&AssetBatchPatch {
            asset_ids: vec![asset_id],
            add_tags: vec!["editorial".to_string()],
            ..AssetBatchPatch::default()
        })
        .unwrap();
    let mut board_b = dev_b.fetch_board(board.id).unwrap().unwrap();
    let stroke_b_id = Uuid::new_v4();
    board_b.ink_strokes.push(InkStroke {
        id: stroke_b_id,
        points: vec![
            InkStrokePoint {
                x: 5.0,
                y: 5.0,
                pressure: 0.5,
            },
            InkStrokePoint {
                x: 50.0,
                y: 40.0,
                pressure: 0.8,
            },
        ],
        color_hex: "#2A60E0".to_string(),
        line_width: 3.0,
        opacity: 0.9,
        z_index: 1000,
        created_at: Utc::now(),
    });
    dev_b.save_board(&board_b).unwrap();

    // Sync A -> Sync B -> Sync A: both devices must converge identically!
    dev_a.sync_now().await.unwrap();
    dev_b.sync_now().await.unwrap();
    dev_a.sync_now().await.unwrap();

    let final_a = dev_a.fetch_asset(asset_id).unwrap().unwrap();
    let final_b = dev_b.fetch_asset(asset_id).unwrap().unwrap();
    assert_eq!(final_a.tags, vec!["approved", "blue", "editorial"]);
    assert_eq!(final_b.tags, final_a.tags);

    let merged_board_a = dev_a.fetch_board(board.id).unwrap().unwrap();
    let merged_board_b = dev_b.fetch_board(board.id).unwrap().unwrap();
    assert_eq!(merged_board_a.nodes.len(), 2);
    assert_eq!(merged_board_a.connectors.len(), 1);
    assert_eq!(merged_board_a.ink_strokes.len(), 1);
    assert_eq!(merged_board_b.nodes.len(), 2);
    assert_eq!(merged_board_b.connectors.len(), 1);
    assert_eq!(merged_board_b.ink_strokes.len(), 1);
    assert_eq!(merged_board_b.ink_strokes[0].id, stroke_b_id);

    // REMOTE RENAME & MOVE TRACKING by `driveFileID` directly on cloud transport
    let drive_id = final_a.drive_file_id.clone().expect("bound driveFileID");
    let root_entries = cloud.list_files("root").await.unwrap();
    let charkle_root = root_entries.iter().find(|f| f.name == "Charkle").unwrap();
    let inbox = cloud
        .list_files(&charkle_root.id)
        .await
        .unwrap()
        .into_iter()
        .find(|f| f.name == "Inbox")
        .unwrap();
    cloud
        .move_file(&drive_id, None, &inbox.id, Some("renamed-on-drive.png"))
        .await
        .unwrap();

    let rep_rename = dev_a.sync_now().await.unwrap();
    assert!(rep_rename.reconciled_renames >= 1);
    let renamed_a = dev_a.fetch_asset(asset_id).unwrap().unwrap();
    assert_eq!(renamed_a.file_name, "renamed-on-drive.png");
    assert_eq!(renamed_a.folder_id, None); // moved into Inbox
    assert_eq!(renamed_a.rating, 4); // preserved user metadata!
    assert_eq!(renamed_a.tags, vec!["approved", "blue", "editorial"]);

    // PERMANENT DELETION TOMBSTONE: prevents respawn across devices
    dev_a.permanently_delete_assets(&[asset_id]).unwrap();
    dev_a.sync_now().await.unwrap();
    dev_b.sync_now().await.unwrap();
    assert!(dev_a.fetch_asset(asset_id).unwrap().is_none());
    assert!(dev_b.fetch_asset(asset_id).unwrap().is_none());
    // Syncing again must NOT resurrect deleted asset
    dev_b.sync_now().await.unwrap();
    assert!(dev_b.fetch_asset(asset_id).unwrap().is_none());
}

#[test]
fn windows_filename_sanitization_handles_illegal_chars_trailing_dots_and_reserved_names() {
    assert_eq!(sanitize_windows_filename(".charkle"), ".charkle");
    assert_eq!(
        sanitize_windows_filename("Hero: Light/Shadow? <2026>*.png"),
        "Hero_ Light_Shadow_ _2026__.png"
    );
    assert_eq!(sanitize_windows_filename("trailing...   "), "trailing");
    assert_eq!(sanitize_windows_filename("CON"), "_CON");
    assert_eq!(sanitize_windows_filename("nul.png"), "_nul.png");
    assert_eq!(sanitize_windows_filename("COM1.txt"), "_COM1.txt");
    assert_eq!(sanitize_windows_filename("lpt9.jpg"), "_lpt9.jpg");
    assert_eq!(sanitize_windows_filename("..."), "_file");
}

struct MockMountInspector {
    available: bool,
}
impl VolumeMountInspector for MockMountInspector {
    fn is_mount_available(&self, _path: &Path) -> bool {
        self.available
    }
}

#[tokio::test]
async fn mounted_volume_transport_respects_volume_mount_inspector() {
    let tmp = tempdir().unwrap();
    let offline = MountedVolumeTransport::new(
        tmp.path(),
        Arc::new(MockMountInspector { available: false }),
    );
    let err = offline.account_info().await.unwrap_err();
    assert!(matches!(err, CoreError::MountPathUnavailable(_)));

    let online =
        MountedVolumeTransport::new(tmp.path(), Arc::new(MockMountInspector { available: true }));
    let info = online.account_info().await.unwrap();
    assert_eq!(info.source, "Mounted Drive");
    assert!(online.is_mounted_volume());
    let created = online
        .find_or_create_folder("Charkle", "root")
        .await
        .unwrap();
    assert!(created.id.starts_with("mounted-path:"));
}

#[test]
fn webdav_propfind_xml_parser_handles_mixed_namespaces_and_https_policy() {
    // Reject remote plain HTTP; allow localhost HTTP and remote HTTPS
    assert!(WebDAVTransport::new("http://dav.example.com/dav/", "u", "p", "/Charkle").is_err());
    assert!(WebDAVTransport::new("http://127.0.0.1:8080/dav/", "u", "p", "/Charkle").is_ok());
    assert!(WebDAVTransport::new("https://dav.example.com/dav/", "u", "p", "/Charkle").is_ok());

    let xml = br#"<?xml version="1.0" encoding="utf-8"?>
    <d:multistatus xmlns:d="DAV:">
      <d:response>
        <d:href>/dav/Charkle/Inbox/</d:href>
        <d:propstat>
          <d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop>
        </d:propstat>
      </d:response>
      <d:response>
        <d:href>/dav/Charkle/Inbox/Poster%20Study.png</d:href>
        <d:propstat>
          <d:prop>
            <d:resourcetype/>
            <d:getcontentlength>4096</d:getcontentlength>
            <d:getlastmodified>Wed, 21 Oct 2026 07:28:00 GMT</d:getlastmodified>
            <d:getcontenttype>image/png</d:getcontenttype>
          </d:prop>
        </d:propstat>
      </d:response>
      <d:response>
        <d:href>/dav/Charkle/Inbox/SubFolder/</d:href>
        <d:propstat>
          <d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop>
        </d:propstat>
      </d:response>
    </d:multistatus>"#;

    let base = Url::parse("https://dav.example.com/dav/").unwrap();
    let items =
        WebDAVTransport::parse_propfind_response(xml, &base, "Charkle/Inbox", "Charkle/Inbox")
            .expect("parse PROPFIND");
    assert_eq!(items.len(), 2);
    let poster = items.iter().find(|i| i.name == "Poster Study.png").unwrap();
    assert!(!poster.is_folder());
    assert_eq!(poster.size, Some(4096));
    assert_eq!(poster.mime_type, "image/png");
    let sub = items.iter().find(|i| i.name == "SubFolder").unwrap();
    assert!(sub.is_folder());
}

#[tokio::test]
async fn google_oauth_pkce_s256_and_client_secret_json_validation() {
    let verifier = GoogleOAuthClient::generate_code_verifier();
    assert!(verifier.len() >= 43);
    let challenge = GoogleOAuthClient::code_challenge_s256(&verifier);
    assert_eq!(challenge.len(), 43);
    assert!(!challenge.contains('='));

    let valid_json = br#"{
      "installed": {
        "client_id": "123456.apps.googleusercontent.com",
        "client_secret": "GOCSPX-test-secret",
        "auth_uri": "https://accounts.google.com/o/oauth2/v2/auth",
        "token_uri": "https://oauth2.googleapis.com/token"
      }
    }"#;
    let parsed = GoogleOAuthClientConfig::parse_client_secret_json(valid_json).unwrap();
    assert_eq!(parsed.client_id, "123456.apps.googleusercontent.com");
    assert_eq!(parsed.client_secret, "GOCSPX-test-secret");

    // Reject untrusted OAuth hosts
    let spoofed = br#"{
      "installed": {
        "client_id": "123456.apps.googleusercontent.com",
        "auth_uri": "https://evil.example.com/auth",
        "token_uri": "https://oauth2.googleapis.com/token"
      }
    }"#;
    assert!(GoogleOAuthClientConfig::parse_client_secret_json(spoofed).is_err());

    let vault = Arc::new(InMemorySecretVault::new());
    let client = GoogleOAuthClient::new(vault);
    client.save_client_config(&parsed).await.unwrap();
    assert_eq!(client.stored_config().await.unwrap(), Some(parsed));
}

#[tokio::test]
async fn lossless_two_way_storage_migration_between_drive_and_local_folder() {
    let tmp = tempdir().unwrap();
    let engine_dir = tmp.path().join("engine");
    let local_mirror_parent = tmp.path().join("local_mirror_root");
    let local_library_dir = local_mirror_parent.join("Charkle");

    let cloud_a = Arc::new(InMemoryDriveTransport::new("user@example.invalid", 100));
    let engine = LiveCharkleEngine::open(&engine_dir).unwrap();
    let drive_cfg = DriveSyncConfig {
        mode: DriveTransportMode::DirectApiWithGDirect,
        root_folder_name: "Charkle".to_string(),
        ..DriveSyncConfig::default()
    };
    engine.save_sync_config(drive_cfg).unwrap();

    // Populate folder + asset + moodboard and sync to Cloud A
    let folder = engine.create_folder("Studio: Shots?", None).unwrap();
    let ingested = engine
        .ingest(
            vec![CaptureInput::ImageData {
                data: sample_png([217, 56, 41, 255]),
                suggested_name: "CON.png".to_string(),
                source_url: None,
            }],
            Some(folder.id),
            None,
        )
        .await
        .unwrap();
    let asset = &ingested[0];
    let mut board = MoodboardDocument::new("Migration Board");
    board.nodes.push(BoardNode {
        id: Uuid::new_v4(),
        kind: BoardNodeKind::AssetRef {
            asset_id: asset.id,
            crop: None,
            weight: 1,
            autoplay_loop: false,
        },
        frame: BoardRect::new(0.0, 0.0, 200.0, 200.0),
        z_index: 0,
        rotation_degrees: 0.0,
        flip_horizontal: false,
        flip_vertical: false,
        is_locked: false,
        editorial_order: 0,
        updated_at: Utc::now(),
    });
    engine.save_board(&board).unwrap();

    engine
        .sync_with_transport(cloud_a.as_ref(), false)
        .await
        .unwrap();

    // Simulate cache eviction of original before migration so migration MUST download it first!
    let bound_asset = engine.fetch_asset(asset.id).unwrap().unwrap();
    let orig_path = engine.cached_original_path(&bound_asset).unwrap();
    std::fs::remove_file(&orig_path).unwrap();
    assert!(engine.cached_original_path(&bound_asset).is_none());

    // Migrate Cloud A -> Local Folder (with Windows filename sanitization for `Studio: Shots?` & `CON.png`)
    let local_cfg = DriveSyncConfig {
        mode: DriveTransportMode::LocalOnly,
        local_library_path: local_library_dir.to_string_lossy().into_owned(),
        ..DriveSyncConfig::default()
    };
    let local_transport = LocalFolderTransport::new(&local_mirror_parent);
    let report1 = engine
        .migrate_storage(
            local_cfg,
            None,
            Some(cloud_a.as_ref()),
            Some(&local_transport),
        )
        .await
        .unwrap();
    assert_eq!(report1.downloaded_originals, 1);
    assert_eq!(report1.migrated_assets, 1);
    assert_eq!(report1.migrated_folders, 1);
    assert_eq!(report1.migrated_boards, 1);

    // Verify sanitized Windows disk paths exist inside local mirror AND `.charkle/manifest.json` was written
    assert!(local_library_dir
        .join(".charkle")
        .join("manifest.json")
        .is_file());
    assert!(local_library_dir
        .join("Studio_ Shots_")
        .join("_CON.png")
        .is_file());

    // Migrate Local Folder -> fresh Cloud B and verify a brand-new second device restores everything!
    let cloud_b = Arc::new(InMemoryDriveTransport::new("user2@example.invalid", 100));
    let drive_b_cfg = DriveSyncConfig {
        mode: DriveTransportMode::DirectApiWithGDirect,
        root_folder_name: "Charkle".to_string(),
        ..DriveSyncConfig::default()
    };
    let report2 = engine
        .migrate_storage(drive_b_cfg.clone(), None, None, Some(cloud_b.as_ref()))
        .await
        .unwrap();
    assert_eq!(report2.migrated_assets, 1);
    assert_eq!(report2.migrated_boards, 1);

    // Brand-new Device 2 connects to Cloud B and syncs cleanly
    let device2_dir = tmp.path().join("device2");
    let db2 = Arc::new(LibraryDatabase::open(&device2_dir.join("Library.sqlite3")).unwrap());
    let media2 = MediaPipeline::new(&device2_dir).unwrap();
    let sync2 = DriveSyncEngine::new(Arc::clone(&db2), media2);
    let rep2 = sync2
        .sync(cloud_b.as_ref(), &drive_b_cfg, false)
        .await
        .unwrap();
    assert!(rep2.downloaded_ops > 0);
    assert!(db2.asset(asset.id).unwrap().is_some());
    assert!(db2.board(board.id).unwrap().is_some());
}

#[tokio::test]
async fn live_engine_broadcasts_events_and_handles_batch_patch_and_folder_ops() {
    let tmp = tempdir().unwrap();
    let engine = LiveCharkleEngine::open(tmp.path().join("app")).unwrap();
    let mut rx = engine.subscribe_events();

    let f_parent = engine.create_folder("Projects", None).unwrap();
    let f_child = engine.create_folder("Brand", Some(f_parent.id)).unwrap();
    assert!(matches!(rx.try_recv(), Ok(EngineEvent::LibraryChanged)));
    assert!(matches!(rx.try_recv(), Ok(EngineEvent::LibraryChanged)));

    let ingested = engine
        .ingest(
            vec![CaptureInput::ColorSwatch {
                hex: "#10B981".to_string(),
                title: Some("Emerald".to_string()),
            }],
            Some(f_child.id),
            None,
        )
        .await
        .unwrap();
    let aid = ingested[0].id;
    assert!(matches!(rx.try_recv(), Ok(EngineEvent::LibraryChanged)));

    let patched = engine
        .update_assets(&AssetBatchPatch {
            asset_ids: vec![aid],
            title: Some("Emerald Primary".to_string()),
            notes: Some("Primary accent".to_string()),
            rating: Some(5),
            add_tags: vec!["green".to_string()],
            folder_assignment: FolderAssignment::Inbox,
            pinned_offline: Some(true),
            ..AssetBatchPatch::default()
        })
        .unwrap();
    assert_eq!(patched[0].title, "Emerald Primary");
    assert_eq!(patched[0].folder_id, None);
    assert!(patched[0].pinned_offline);
    assert_eq!(engine.inbox_count().unwrap(), 1);

    // Deleting parent folder with `trash_contents = false` reparents `f_child` to root
    engine.delete_folder(f_parent.id, false).unwrap();
    let remaining = engine.fetch_folders().unwrap();
    assert_eq!(remaining.len(), 1);
    assert_eq!(remaining[0].id, f_child.id);
    assert_eq!(remaining[0].parent_id, None);
}
