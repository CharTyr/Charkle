//! Golden macOS `/.charkle/` wire-format round-trip and SwiftWireCodec parity tests.

use charkle_core::models::agent::{
    ExternalAgentAccessLevel, ExternalAgentConfig, ExternalAgentToken, ExternalAgentTransport,
};
use charkle_core::models::core::{AssetRecord, LabColor};
use charkle_core::models::media::EmbeddingPrecision;
use charkle_core::models::moodboard::{
    AutoLayoutConfig, BoardLayoutMode, BoardNodeKind, EditorialStyle, MoodboardDocument,
};
use charkle_core::models::sync::{AssetChanges, DriveSyncConfig, SyncOperationChange};
use charkle_core::wire::swift_codec::{
    canonical_json_string, cocoa_seconds_to_datetime, datetime_to_cocoa_seconds, decode_manifest,
    decode_ops_jsonl, encode_manifest, encode_ops_jsonl, format_ops_shard_file_name,
    format_swift_uuid, parse_ops_shard_file_name, COCOA_EPOCH_OFFSET_SEC,
};
use chrono::{TimeZone, Utc};
use uuid::Uuid;

const GOLDEN_MANIFEST: &str = include_str!("fixtures/manifest.json");
const GOLDEN_OPS: &str = include_str!("fixtures/ops-0123456789abcdef0123456789abcdef-7.jsonl");
const GOLDEN_BOARD: &str = include_str!("fixtures/board-golden.json");

#[test]
fn cocoa_reference_date_matches_swift_exact_epoch() {
    assert_eq!(COCOA_EPOCH_OFFSET_SEC, 978_307_200.0);
    let epoch_2001 = Utc.with_ymd_and_hms(2001, 1, 1, 0, 0, 0).unwrap();
    assert_eq!(datetime_to_cocoa_seconds(epoch_2001), 0.0);
    assert_eq!(cocoa_seconds_to_datetime(0.0).unwrap(), epoch_2001);

    // Date(timeIntervalSince1970: 1_700_000_000) == 721_692_800.0 in Swift
    let dt = Utc.timestamp_opt(1_700_000_000, 0).unwrap();
    assert_eq!(datetime_to_cocoa_seconds(dt), 721_692_800.0);
    assert_eq!(cocoa_seconds_to_datetime(721_692_800.0).unwrap(), dt);
}

#[test]
fn golden_macos_manifest_round_trips_byte_for_byte() {
    let manifest = decode_manifest(GOLDEN_MANIFEST).expect("decode golden manifest");
    assert_eq!(manifest.version, 1);
    assert_eq!(manifest.root_folder_id.as_deref(), Some("drv-root-001"));
    let dirs = manifest.directories.as_ref().expect("directories present");
    assert_eq!(dirs.get("Inbox").map(String::as_str), Some("drv-inbox-001"));
    assert_eq!(dirs.get("ops").map(String::as_str), Some("drv-ops-001"));

    let reencoded = encode_manifest(&manifest).expect("re-encode manifest");
    assert_eq!(reencoded, GOLDEN_MANIFEST.trim());
}

#[test]
fn golden_macos_ops_jsonl_decodes_all_seven_variants_and_round_trips() {
    let lines = decode_ops_jsonl(GOLDEN_OPS).expect("decode golden ops JSONL");
    assert_eq!(lines.len(), 7);
    let expected_device = "0123456789abcdef0123456789abcdef";
    let asset_id = Uuid::parse_str("550E8400-E29B-41D4-A716-446655440000").unwrap();
    let board_id = Uuid::parse_str("660E8400-E29B-41D4-A716-446655440001").unwrap();
    let folder_id = Uuid::parse_str("770E8400-E29B-41D4-A716-446655440002").unwrap();

    // 1. Asset delta
    assert_eq!(lines[0].seq, 1);
    assert_eq!(lines[0].operation.stamp.device, expected_device);
    match &lines[0].operation.change {
        SyncOperationChange::Asset(delta) => {
            assert_eq!(delta.id, asset_id);
            assert_eq!(
                std::str::from_utf8(delta.fields.get("title").unwrap()).unwrap(),
                "\"海报参考\""
            );
            assert_eq!(delta.fields.get("folderID").unwrap(), b"null");
            assert_eq!(delta.fields.get("rating").unwrap(), b"5");
            assert_eq!(delta.tags_added, vec!["平面设计", "海报"]);
            assert_eq!(delta.tags_removed, vec!["草稿"]);
        }
        other => panic!("expected Asset change, got {other:?}"),
    }

    // 2. Board delta
    assert_eq!(lines[1].seq, 2);
    match &lines[1].operation.change {
        SyncOperationChange::Board(delta) => {
            assert_eq!(delta.id, board_id);
            assert_eq!(delta.fields.get("mode").unwrap(), br#"{"freeform":{}}"#);
            assert_eq!(delta.nodes.removed.len(), 1);
        }
        other => panic!("expected Board change, got {other:?}"),
    }

    // 3. Folder with projectLocation = false
    assert_eq!(lines[2].seq, 3);
    assert_eq!(lines[2].operation.project_location, Some(false));
    match &lines[2].operation.change {
        SyncOperationChange::Folder(folder) => {
            assert_eq!(folder.id, folder_id);
            assert_eq!(folder.name, "Typography");
            assert_eq!(folder.sort_order, 2);
            assert_eq!(datetime_to_cocoa_seconds(folder.created_at), 721_692_800.0);
        }
        other => panic!("expected Folder change, got {other:?}"),
    }

    // 4-6. Deletes
    assert_eq!(
        lines[3].operation.change,
        SyncOperationChange::DeleteAsset {
            id: asset_id,
            drive_id: Some("drv-file-123".to_string())
        }
    );
    assert_eq!(
        lines[4].operation.change,
        SyncOperationChange::DeleteBoard(board_id)
    );
    assert_eq!(
        lines[5].operation.change,
        SyncOperationChange::DeleteFolder {
            id: folder_id,
            drive_id: None
        }
    );

    // 7. Vector
    match &lines[6].operation.change {
        SyncOperationChange::Vector { id, vector } => {
            assert_eq!(*id, asset_id);
            assert_eq!(vector.feature_print.as_deref(), Some(&[1u8, 2, 3, 4][..]));
            assert_eq!(
                vector.embedding.as_deref(),
                Some(&[0.25f32, -0.5, 0.75][..])
            );
            assert_eq!(
                vector.embedding_model.as_deref(),
                Some("gemini-embedding-001")
            );
            assert_eq!(vector.precision, EmbeddingPrecision::Float16);
        }
        other => panic!("expected Vector change, got {other:?}"),
    }

    // Lossless re-encode -> re-decode round-trip
    let reencoded = encode_ops_jsonl(&lines).expect("re-encode ops JSONL");
    let redecoded = decode_ops_jsonl(&reencoded).expect("re-decode ops JSONL");
    assert_eq!(redecoded, lines);
    // Ensure uppercase UUIDs on wire
    assert!(reencoded.contains("550E8400-E29B-41D4-A716-446655440000"));
    assert!(!reencoded.contains("550e8400-e29b-41d4-a716-446655440000"));
}

#[test]
fn golden_macos_board_round_trips_all_node_kinds_and_modes() {
    let mut doc: MoodboardDocument =
        serde_json::from_str(GOLDEN_BOARD).expect("decode golden board JSON");
    assert_eq!(doc.title, "Editorial Direction");
    assert_eq!(doc.nodes.len(), 4);
    assert_eq!(doc.connectors.len(), 1);
    assert_eq!(doc.ink_strokes.len(), 1);
    assert!(doc.pinned_offline);
    assert_eq!(
        doc.mode,
        BoardLayoutMode::AutoEditorial(AutoLayoutConfig {
            style: EditorialStyle::Magazine,
            columns: 3,
            spacing: 20.0,
            show_palette_strip: true,
        })
    );
    assert!(matches!(doc.nodes[0].kind, BoardNodeKind::AssetRef { .. }));
    assert!(matches!(doc.nodes[1].kind, BoardNodeKind::Note { .. }));
    assert!(matches!(
        doc.nodes[2].kind,
        BoardNodeKind::GroupFrame { .. }
    ));
    assert!(matches!(
        doc.nodes[3].kind,
        BoardNodeKind::PaletteStrip { .. }
    ));

    // Mutate to Freeform and verify exact Swift keyed enum encoding `{"freeform":{}}`
    doc.mode = BoardLayoutMode::Freeform;
    let serialized = canonical_json_string(&doc).expect("canonical board serialize");
    assert!(serialized.contains(r#""mode":{"freeform":{}}"#));
    assert!(serialized.contains("11111111-2222-4333-8444-555555555555"));
    assert!(serialized.contains("550E8400-E29B-41D4-A716-446655440000"));

    let redecoded: MoodboardDocument = serde_json::from_str(&serialized).expect("re-decode board");
    assert_eq!(redecoded, doc);
}

#[test]
fn ops_shard_filename_and_sync_fields_diff_match_swift() {
    let dev = "0123456789abcdef0123456789abcdef";
    let name = format_ops_shard_file_name(dev, 42);
    assert_eq!(name, "ops-0123456789abcdef0123456789abcdef-42.jsonl");
    assert_eq!(
        parse_ops_shard_file_name(&name),
        Some((dev.to_string(), 42))
    );
    assert_eq!(parse_ops_shard_file_name("ops-short-42.jsonl"), None);
    assert_eq!(
        parse_ops_shard_file_name("ops-0123456789abcdef0123456789abcdef-0.jsonl"),
        None
    );

    let mut before = AssetRecord::new("Old", "old.png");
    before.folder_id = Some(Uuid::new_v4());
    let mut after = before.clone();
    after.title = "New".to_string();
    after.folder_id = None;
    after.is_local_original_cached = !before.is_local_original_cached; // excluded
    after.updated_at = Utc::now(); // excluded
    after.tags = vec!["design".to_string()];

    let delta = AssetChanges::diff(&after, Some(&before)).expect("diff asset");
    assert_eq!(delta.fields.len(), 2);
    assert_eq!(delta.fields.get("title").unwrap(), br#""New""#);
    assert_eq!(delta.fields.get("folderID").unwrap(), b"null");
    assert_eq!(delta.tags_added, vec!["design"]);
    assert!(delta.touches_location());
    assert_eq!(
        format_swift_uuid(&before.id),
        before.id.hyphenated().to_string().to_uppercase()
    );
}

#[test]
fn external_agent_policy_and_drive_shared_folder_parser_compatibility() {
    // Legacy JSON with only `enabled` must map both stdio & HTTP MCP cleanly to ReadOnly
    let legacy = r#"{"enabled":true}"#;
    let cfg: ExternalAgentConfig = serde_json::from_str(legacy).expect("decode legacy config");
    assert!(cfg.enabled());
    assert!(cfg.is_enabled_for(ExternalAgentTransport::Stdio));
    assert!(cfg.is_enabled_for(ExternalAgentTransport::Http));
    assert!(!cfg.allow_remote_http_mcp);
    assert!(!cfg.access_level.allows_inbox_and_enrich_writes());
    assert_eq!(cfg.access_level, ExternalAgentAccessLevel::ReadOnly);

    // Legacy `cliEnabled` key is ignored gracefully while 3-tier access + httpMCPEnabled decode cleanly
    let rw: ExternalAgentConfig = serde_json::from_str(
        r#"{"mcpEnabled":true,"cliEnabled":false,"httpMCPEnabled":false,"accessLevel":"readWriteOrganize"}"#,
    )
    .expect("decode rw config");
    assert!(rw.is_enabled_for(ExternalAgentTransport::Stdio));
    assert!(!rw.is_enabled_for(ExternalAgentTransport::Http));
    assert!(rw.access_level.allows_global_organize_writes());

    let inbox_tier: ExternalAgentConfig = serde_json::from_str(
        r#"{"mcpEnabled":true,"httpMCPEnabled":true,"accessLevel":"inboxAndEnrich"}"#,
    )
    .expect("decode inboxAndEnrich config");
    assert!(inbox_tier.access_level.allows_inbox_and_enrich_writes());
    assert!(!inbox_tier.access_level.allows_global_organize_writes());

    let (tok, plain) =
        ExternalAgentToken::mint("Test HTTP Agent", ExternalAgentAccessLevel::ReadOnly);
    assert!(plain.starts_with("ck_mcp_"));
    assert!(tok.matches(&plain));
    assert!(!tok.matches("ck_mcp_wrong"));

    assert_eq!(
        DriveSyncConfig::extract_google_drive_folder_id(
            "https://drive.google.com/drive/folders/1AbCdEfGhIjKlMnOpQrStUvWxYz?usp=sharing"
        ),
        Some("1AbCdEfGhIjKlMnOpQrStUvWxYz".to_string())
    );
    assert_eq!(
        DriveSyncConfig::extract_google_drive_folder_id(
            "https://drive.google.com/open?id=1AbCdEfGhIjKlMnOp"
        ),
        Some("1AbCdEfGhIjKlMnOp".to_string())
    );
    assert_eq!(
        DriveSyncConfig::extract_google_drive_folder_id("raw_folder_id_12345"),
        Some("raw_folder_id_12345".to_string())
    );

    // CIELAB ΔE & ΔE2000 sanity
    let blue = LabColor::from_hex("#2A60E0", 1.0);
    let near_blue = LabColor::from_hex("#2F64E4", 1.0);
    let red = LabColor::from_hex("#DC3E2B", 1.0);
    assert!(blue.delta_e(&near_blue) < 5.0);
    assert!(blue.delta_e_2000(&near_blue) < 5.0);
    assert!(blue.delta_e(&red) > 50.0);
    assert!(blue.delta_e_2000(&red) > 40.0);
}
