//! End-to-end `LiveCharkleEngine` regression tests covering:
//! - Batch trashing and restoring 3+ assets (HLC monotonicity, deduplication, FTS5, Inbox & folder counts)
//! - Batch permanent deletion of 3+ assets (tombstones, FTS5 cleanup, `board_assets` orphan cleanup, disk cleanup)
//! - Moodboard node removal, multi-node removal, full emptying, Undo (`Ctrl+Z`) same-UUID re-add,
//!   re-removal, `board_assets` consistency, and two-device CRDT convergence.

use std::collections::HashSet;
use std::path::Path;
use std::sync::Arc;

use charkle_core::db::LibraryDatabase;
use charkle_core::engine::LiveCharkleEngine;
use charkle_core::media::MediaPipeline;
use charkle_core::models::core::{AssetBatchPatch, FilterCriteria, LabColor};
use charkle_core::models::media::{CaptureInput, ThumbnailTier};
use charkle_core::models::moodboard::{
    BoardConnector, BoardNode, BoardNodeKind, BoardRect, ConnectorAnchor, ConnectorStyle,
    MoodboardDocument,
};
use charkle_core::models::sync::{DriveSyncConfig, DriveTransportMode};
use charkle_core::sync::{DriveTransport, InMemoryDriveTransport};
use charkle_core::traits::{BasicVolumeMountInspector, InMemorySecretVault, NoopOcrProvider};
use chrono::Utc;
use image::{DynamicImage, ImageFormat, Rgba, RgbaImage};
use tempfile::tempdir;
use uuid::Uuid;

fn sample_png(color: [u8; 4]) -> Vec<u8> {
    let img = RgbaImage::from_pixel(96, 72, Rgba(color));
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

fn make_asset_ref_node(node_id: Uuid, asset_id: Uuid, order: i32) -> BoardNode {
    BoardNode {
        id: node_id,
        kind: BoardNodeKind::AssetRef {
            asset_id,
            crop: None,
            weight: 1,
            autoplay_loop: false,
        },
        frame: BoardRect::new((order as f64) * 240.0, 40.0, 200.0, 150.0),
        z_index: order,
        rotation_degrees: 0.0,
        flip_horizontal: false,
        flip_vertical: false,
        is_locked: false,
        editorial_order: order,
        updated_at: Utc::now(),
    }
}

#[tokio::test]
async fn batch_update_assets_trashes_and_restores_all_selected_items() {
    let tmp = tempdir().unwrap();
    let engine = LiveCharkleEngine::open(tmp.path().join("batch_trash")).unwrap();

    let folder = engine.create_folder("Posters", None).unwrap();

    // Ingest 2 Inbox assets + 2 Folder assets
    let inbox_assets = engine
        .ingest(
            vec![
                CaptureInput::ImageData {
                    data: sample_png([220, 60, 40, 255]),
                    suggested_name: "batch-alpha.png".to_string(),
                    source_url: None,
                },
                CaptureInput::ImageData {
                    data: sample_png([40, 160, 90, 255]),
                    suggested_name: "batch-beta.png".to_string(),
                    source_url: None,
                },
            ],
            None,
            None,
        )
        .await
        .unwrap();
    let folder_assets = engine
        .ingest(
            vec![
                CaptureInput::ImageData {
                    data: sample_png([40, 90, 220, 255]),
                    suggested_name: "batch-gamma.png".to_string(),
                    source_url: None,
                },
                CaptureInput::ImageData {
                    data: sample_png([230, 180, 30, 255]),
                    suggested_name: "batch-keep.png".to_string(),
                    source_url: None,
                },
            ],
            Some(folder.id),
            None,
        )
        .await
        .unwrap();

    let a = inbox_assets[0].id;
    let b = inbox_assets[1].id;
    let c = folder_assets[0].id;
    let keep = folder_assets[1].id;

    // Tag all 4 items so tag counts + FTS are exercised too
    engine
        .update_assets(&AssetBatchPatch {
            asset_ids: vec![a, b, c, keep],
            add_tags: vec!["editorial".to_string()],
            ..AssetBatchPatch::default()
        })
        .unwrap();

    assert_eq!(engine.inbox_count().unwrap(), 2);
    assert_eq!(engine.fetch_folders().unwrap()[0].asset_count, 2);
    assert_eq!(engine.fetch_tag_counts().unwrap()[0].count, 4);

    // Batch trash 3 assets (with duplicate `a` to verify order-preserving deduplication)
    let trashed = engine
        .update_assets(&AssetBatchPatch {
            asset_ids: vec![a, b, c, a],
            is_trashed: Some(true),
            ..AssetBatchPatch::default()
        })
        .unwrap();
    assert_eq!(trashed.len(), 3, "must update all 3 deduplicated assets");
    assert!(trashed.iter().all(|item| item.is_trashed));
    // Strictly monotonic HLC stamps across rapid in-transaction batch writes
    assert!(trashed[0].updated_hlc < trashed[1].updated_hlc);
    assert!(trashed[1].updated_hlc < trashed[2].updated_hlc);

    // Active gallery excludes all 3 trashed assets
    let active = engine.fetch_assets(&FilterCriteria::default()).unwrap();
    assert_eq!(active.len(), 1);
    assert_eq!(active[0].id, keep);

    // FTS query in active library also excludes all 3 trashed assets
    let fts_active = engine
        .fetch_assets(&FilterCriteria {
            search_query: "batch".to_string(),
            ..FilterCriteria::default()
        })
        .unwrap();
    assert_eq!(fts_active.len(), 1);
    assert_eq!(fts_active[0].id, keep);

    // Trash view contains all 3 trashed assets
    let in_trash = engine
        .fetch_assets(&FilterCriteria {
            only_trashed: true,
            ..FilterCriteria::default()
        })
        .unwrap();
    let trashed_ids: HashSet<Uuid> = in_trash.iter().map(|item| item.id).collect();
    assert_eq!(trashed_ids, HashSet::from([a, b, c]));

    // Inbox, folder, and tag counts drop immediately
    assert_eq!(engine.inbox_count().unwrap(), 0);
    assert_eq!(engine.fetch_folders().unwrap()[0].asset_count, 1);
    assert_eq!(engine.fetch_tag_counts().unwrap()[0].count, 1);

    // Batch restore all 3 assets atomically
    let restored = engine
        .update_assets(&AssetBatchPatch {
            asset_ids: vec![a, b, c],
            is_trashed: Some(false),
            ..AssetBatchPatch::default()
        })
        .unwrap();
    assert_eq!(restored.len(), 3);
    assert!(restored.iter().all(|item| !item.is_trashed));

    // All 4 items are back in active gallery, Trash is empty, counts fully restored
    let active_after = engine.fetch_assets(&FilterCriteria::default()).unwrap();
    assert_eq!(active_after.len(), 4);
    let trash_after = engine
        .fetch_assets(&FilterCriteria {
            only_trashed: true,
            ..FilterCriteria::default()
        })
        .unwrap();
    assert!(trash_after.is_empty());
    assert_eq!(engine.inbox_count().unwrap(), 2);
    assert_eq!(engine.fetch_folders().unwrap()[0].asset_count, 2);
    assert_eq!(engine.fetch_tag_counts().unwrap()[0].count, 4);
}

#[tokio::test]
async fn batch_permanently_delete_assets_deletes_all_selected_items() {
    let tmp = tempdir().unwrap();
    let engine = LiveCharkleEngine::open(tmp.path().join("batch_perm_delete")).unwrap();

    let assets = engine
        .ingest(
            vec![
                CaptureInput::ImageData {
                    data: sample_png([180, 40, 40, 255]),
                    suggested_name: "perm-one.png".to_string(),
                    source_url: None,
                },
                CaptureInput::ImageData {
                    data: sample_png([40, 180, 40, 255]),
                    suggested_name: "perm-two.png".to_string(),
                    source_url: None,
                },
                CaptureInput::ImageData {
                    data: sample_png([40, 40, 180, 255]),
                    suggested_name: "perm-three.png".to_string(),
                    source_url: None,
                },
                CaptureInput::ImageData {
                    data: sample_png([200, 200, 60, 255]),
                    suggested_name: "perm-survivor.png".to_string(),
                    source_url: None,
                },
            ],
            None,
            None,
        )
        .await
        .unwrap();

    let a = assets[0].id;
    let b = assets[1].id;
    let c = assets[2].id;
    let survivor = assets[3].id;

    // Attach all 4 to a pinned moodboard so `board_assets` & `protected_asset_ids` contain them
    let mut board = MoodboardDocument::new("Pinned Ref Board");
    board.pinned_offline = true;
    for (idx, &aid) in [a, b, c, survivor].iter().enumerate() {
        board
            .nodes
            .push(make_asset_ref_node(Uuid::new_v4(), aid, idx as i32));
    }
    let board = engine.save_board(&board).unwrap();
    assert_eq!(
        engine.database().board_asset_ids(board.id).unwrap().len(),
        4
    );
    assert_eq!(engine.database().protected_asset_ids().unwrap().len(), 4);

    // Record on-disk media paths before permanent delete
    let deleted_paths: Vec<_> = [assets[0].clone(), assets[1].clone(), assets[2].clone()]
        .iter()
        .map(|item| {
            (
                engine.cached_original_path(item).expect("cached original"),
                engine
                    .cached_thumbnail_path(item.id, ThumbnailTier::Grid520)
                    .expect("grid thumb"),
                engine
                    .cached_thumbnail_path(item.id, ThumbnailTier::Preview1400)
                    .expect("preview thumb"),
            )
        })
        .collect();

    // Move 3 items to Trash, then permanently delete all 3 in one batch
    engine
        .update_assets(&AssetBatchPatch {
            asset_ids: vec![a, b, c],
            is_trashed: Some(true),
            ..AssetBatchPatch::default()
        })
        .unwrap();
    engine.permanently_delete_assets(&[a, b, c]).unwrap();

    // Zero trace in assets, include_trashed, Trash, FTS5, board_assets, or protected_asset_ids
    for id in [a, b, c] {
        assert!(engine.fetch_asset(id).unwrap().is_none());
        assert!(engine.database().is_tombstoned("asset", id).unwrap());
    }
    let all_including_trash = engine
        .fetch_assets(&FilterCriteria {
            include_trashed: true,
            ..FilterCriteria::default()
        })
        .unwrap();
    assert_eq!(all_including_trash.len(), 1);
    assert_eq!(all_including_trash[0].id, survivor);

    let trash_remaining = engine
        .fetch_assets(&FilterCriteria {
            only_trashed: true,
            ..FilterCriteria::default()
        })
        .unwrap();
    assert!(trash_remaining.is_empty());

    let fts_hits = engine
        .fetch_assets(&FilterCriteria {
            search_query: "perm".to_string(),
            include_trashed: true,
            ..FilterCriteria::default()
        })
        .unwrap();
    assert_eq!(fts_hits.len(), 1);
    assert_eq!(fts_hits[0].id, survivor);

    let remaining_board_assets = engine.database().board_asset_ids(board.id).unwrap();
    assert_eq!(remaining_board_assets, HashSet::from([survivor]));
    assert_eq!(
        engine.database().protected_asset_ids().unwrap(),
        HashSet::from([survivor])
    );

    // Originals and thumbnails for all 3 deleted assets are removed from disk; survivor stays intact
    for (orig, grid, preview) in deleted_paths {
        assert!(!orig.exists(), "original should be deleted: {orig:?}");
        assert!(!grid.exists(), "grid thumb should be deleted: {grid:?}");
        assert!(
            !preview.exists(),
            "preview thumb should be deleted: {preview:?}"
        );
    }
    assert!(engine.cached_original_path(&assets[3]).is_some());

    // Idempotent repeat delete & mixed update with deleted + surviving IDs must succeed cleanly
    engine.permanently_delete_assets(&[a, b, c]).unwrap();
    let updated = engine
        .update_assets(&AssetBatchPatch {
            asset_ids: vec![a, survivor, c],
            rating: Some(5),
            ..AssetBatchPatch::default()
        })
        .unwrap();
    assert_eq!(updated.len(), 1);
    assert_eq!(updated[0].id, survivor);
    assert_eq!(updated[0].rating, 5);
}

#[tokio::test]
async fn save_board_removes_single_and_multiple_nodes_and_survives_undo_roundtrip() {
    let tmp = tempdir().unwrap();
    let cloud = Arc::new(InMemoryDriveTransport::default());
    let dev_a = make_device_engine(&tmp.path().join("board_dev_a"), cloud.clone());
    let dev_b = make_device_engine(&tmp.path().join("board_dev_b"), cloud.clone());

    let assets = dev_a
        .ingest(
            vec![
                CaptureInput::ColorSwatch {
                    hex: "#D93829".to_string(),
                    title: Some("Vermilion".to_string()),
                },
                CaptureInput::ColorSwatch {
                    hex: "#2A60E0".to_string(),
                    title: Some("Cobalt".to_string()),
                },
                CaptureInput::ColorSwatch {
                    hex: "#10B981".to_string(),
                    title: Some("Emerald".to_string()),
                },
            ],
            None,
            None,
        )
        .await
        .unwrap();
    let a1 = assets[0].id;
    let a2 = assets[1].id;
    let a3 = assets[2].id;

    let n1_id = Uuid::new_v4();
    let n2_id = Uuid::new_v4();
    let n3_id = Uuid::new_v4();
    let conn_id = Uuid::new_v4();

    let n1 = make_asset_ref_node(n1_id, a1, 0);
    let n2 = make_asset_ref_node(n2_id, a2, 1);
    let n3 = make_asset_ref_node(n3_id, a3, 2);
    let connector = BoardConnector {
        id: conn_id,
        from_node_id: n1_id,
        from_anchor: ConnectorAnchor::Trailing,
        from_normalized_point: None,
        to_node_id: n2_id,
        to_anchor: ConnectorAnchor::Leading,
        to_normalized_point: None,
        label: Some("pair".to_string()),
        color_hex: "#5C6672".to_string(),
        style: ConnectorStyle::Curved,
        dashed: false,
        updated_at: Utc::now(),
    };

    // Step 1: Create board with 3 assetRef nodes + connector + palette, and sync to dev_b
    let mut board = MoodboardDocument::new("Editorial Removal Roundtrip");
    board.nodes = vec![n1.clone(), n2.clone(), n3.clone()];
    board.connectors = vec![connector.clone()];
    board.extracted_palette = vec![
        LabColor::from_hex("#D93829", 0.4),
        LabColor::from_hex("#2A60E0", 0.3),
        LabColor::from_hex("#10B981", 0.3),
    ];
    let mut board = dev_a.save_board(&board).unwrap();
    assert_eq!(board.nodes.len(), 3);
    assert_eq!(dev_a.fetch_boards().unwrap()[0].item_count, 3);
    assert_eq!(
        dev_a.database().board_asset_ids(board.id).unwrap(),
        HashSet::from([a1, a2, a3])
    );

    // Sync initial state so both devices hold established CRDT clocks for n1/n2/n3
    dev_a.sync_now().await.unwrap();
    dev_b.sync_now().await.unwrap();
    assert_eq!(dev_b.fetch_board(board.id).unwrap().unwrap().nodes.len(), 3);

    // Step 2: Remove 1 node (`n1`) and its connector -> verify 2 persisted
    board.nodes.retain(|n| n.id != n1_id);
    board.connectors.retain(|c| c.id != conn_id);
    let mut board = dev_a.save_board(&board).unwrap();
    assert_eq!(board.nodes.len(), 2);
    assert!(board.connectors.is_empty());
    let loaded_step2 = dev_a.fetch_board(board.id).unwrap().unwrap();
    assert_eq!(loaded_step2.nodes.len(), 2);
    assert!(!loaded_step2.nodes.iter().any(|n| n.id == n1_id));
    assert_eq!(dev_a.fetch_boards().unwrap()[0].item_count, 2);
    assert_eq!(
        dev_a.database().board_asset_ids(board.id).unwrap(),
        HashSet::from([a2, a3])
    );

    // Step 3: Undo (`Ctrl+Z`) re-adding `n1` and `connector` with the EXACT SAME UUIDs
    board.nodes.push(n1.clone());
    board.connectors.push(connector.clone());
    let mut board = dev_a.save_board(&board).unwrap();
    assert_eq!(board.nodes.len(), 3);
    assert_eq!(board.connectors.len(), 1);
    let loaded_step3 = dev_a.fetch_board(board.id).unwrap().unwrap();
    assert_eq!(loaded_step3.nodes.len(), 3);
    assert!(loaded_step3.nodes.iter().any(|n| n.id == n1_id));
    assert_eq!(loaded_step3.connectors.len(), 1);
    assert_eq!(dev_a.fetch_boards().unwrap()[0].item_count, 3);
    assert_eq!(
        dev_a.database().board_asset_ids(board.id).unwrap(),
        HashSet::from([a1, a2, a3])
    );

    // Step 4: Remove 2 nodes (`n1` AGAIN + `n2`) -> verify only `n3` persisted
    board.nodes.retain(|n| n.id != n1_id && n.id != n2_id);
    board.connectors.clear();
    let mut board = dev_a.save_board(&board).unwrap();
    assert_eq!(board.nodes.len(), 1);
    assert_eq!(board.nodes[0].id, n3_id);
    let loaded_step4 = dev_a.fetch_board(board.id).unwrap().unwrap();
    assert_eq!(loaded_step4.nodes.len(), 1);
    assert_eq!(loaded_step4.nodes[0].id, n3_id);
    assert_eq!(dev_a.fetch_boards().unwrap()[0].item_count, 1);
    assert_eq!(
        dev_a.database().board_asset_ids(board.id).unwrap(),
        HashSet::from([a3])
    );

    // Step 5: Remove last node (`n3`) and clear `extracted_palette` -> verify 0 persisted & empty `board_assets`
    board.nodes.clear();
    board.extracted_palette.clear();
    let saved_empty = dev_a.save_board(&board).unwrap();
    assert!(saved_empty.nodes.is_empty());
    assert!(saved_empty.extracted_palette.is_empty());

    let loaded_step5 = dev_a.fetch_board(board.id).unwrap().unwrap();
    assert!(loaded_step5.nodes.is_empty());
    assert!(loaded_step5.connectors.is_empty());
    assert!(loaded_step5.extracted_palette.is_empty());
    let summary = dev_a.fetch_boards().unwrap().remove(0);
    assert_eq!(summary.item_count, 0);
    assert!(summary.preview_asset_ids.is_empty());
    assert!(summary.palette_hexes.is_empty());
    assert!(dev_a
        .database()
        .board_asset_ids(board.id)
        .unwrap()
        .is_empty());

    // Step 6: Sync the full remove -> undo -> remove-again -> empty op stream to dev_b
    dev_a.sync_now().await.unwrap();
    dev_b.sync_now().await.unwrap();
    let remote_board = dev_b.fetch_board(board.id).unwrap().unwrap();
    assert!(remote_board.nodes.is_empty());
    assert!(remote_board.connectors.is_empty());
    assert!(remote_board.extracted_palette.is_empty());
    assert!(dev_b
        .database()
        .board_asset_ids(board.id)
        .unwrap()
        .is_empty());
}
