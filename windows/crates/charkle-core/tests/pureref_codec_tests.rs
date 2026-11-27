//! Round-trip binary codec tests for PureRef (`.pur`) v1.10 & v2.0+ scenes.
//! Mirrors `Tests/CharkleTests/PureRefCodecTests.swift`.

use std::collections::HashMap;
use std::io::Cursor;

use charkle_core::engine::LiveCharkleEngine;
use charkle_core::media::{
    PureRefAssetInput, PureRefCodec, PureRefColor, PureRefImageBlob, PureRefImageFormat,
    PureRefImagePlacement, PureRefScene, PureRefTextNote,
};
use charkle_core::models::moodboard::{
    BoardLayoutMode, BoardNode, BoardNodeKind, BoardRect, MoodboardDocument, NormalizedCropRect,
    NoteStyle,
};
use image::{DynamicImage, ImageFormat, Rgba, RgbaImage};
use md5::{Digest as _, Md5};
use tempfile::tempdir;
use uuid::Uuid;

fn make_png(w: u32, h: u32, rgba: [u8; 4]) -> Vec<u8> {
    let img = DynamicImage::ImageRgba8(RgbaImage::from_pixel(w, h, Rgba(rgba)));
    let mut out = Vec::new();
    img.write_to(&mut Cursor::new(&mut out), ImageFormat::Png)
        .unwrap();
    out
}

fn make_jpeg(w: u32, h: u32, rgb: [u8; 3]) -> Vec<u8> {
    let img = DynamicImage::ImageRgb8(image::RgbImage::from_pixel(w, h, image::Rgb(rgb)));
    let mut out = Vec::new();
    img.write_to(&mut Cursor::new(&mut out), ImageFormat::Jpeg)
        .unwrap();
    out
}

#[test]
fn round_trips_v110_scene_preserving_md5_transforms_crops_duplicates_and_notes() {
    let png1 = make_png(240, 160, [214, 72, 54, 255]);
    let png2 = make_png(120, 180, [48, 122, 224, 255]);
    let crop = NormalizedCropRect {
        x: 0.12,
        y: 0.18,
        width: 0.65,
        height: 0.58,
    };

    let scene = PureRefScene {
        format_version: "1.10".to_string(),
        zoom: 1.25,
        view_x: 42,
        view_y: -18,
        folder_location: "StudioRefs".to_string(),
        images: vec![
            PureRefImageBlob {
                index: 0,
                data: png1.clone(),
                format: PureRefImageFormat::Png,
                pixel_width: 240,
                pixel_height: 160,
                source_path: Some("hero.png".to_string()),
                display_name: Some("Hero Shot".to_string()),
            },
            PureRefImageBlob {
                index: 1,
                data: png2.clone(),
                format: PureRefImageFormat::Png,
                pixel_width: 120,
                pixel_height: 180,
                source_path: Some("portrait.png".to_string()),
                display_name: Some("Portrait".to_string()),
            },
        ],
        placements: vec![
            PureRefImagePlacement {
                image_index: 0,
                name: Some("Hero Primary".to_string()),
                source_path: Some("hero.png".to_string()),
                center_x: -180.0,
                center_y: 40.0,
                width: 300.0,
                height: 200.0,
                rotation_degrees: 15.0,
                flip_horizontal: true,
                flip_vertical: false,
                z_layer: 1.0,
                crop: Some(crop),
                child_notes: vec![PureRefTextNote {
                    text: "Rim light cue".to_string(),
                    center_x: 0.0,
                    center_y: 120.0,
                    scale: 1.0,
                    z_layer: 2.0,
                    ..PureRefTextNote::default()
                }],
            },
            // Duplicate placement sharing image_index 0
            PureRefImagePlacement {
                image_index: 0,
                name: Some("Hero Duplicate".to_string()),
                source_path: Some("hero.png".to_string()),
                center_x: 240.0,
                center_y: -30.0,
                width: 240.0,
                height: 160.0,
                rotation_degrees: -10.0,
                flip_horizontal: false,
                flip_vertical: true,
                z_layer: 3.0,
                crop: None,
                child_notes: Vec::new(),
            },
            PureRefImagePlacement {
                image_index: 1,
                name: Some("Portrait".to_string()),
                source_path: Some("portrait.png".to_string()),
                center_x: 520.0,
                center_y: 110.0,
                width: 180.0,
                height: 270.0,
                rotation_degrees: 0.0,
                flip_horizontal: false,
                flip_vertical: false,
                z_layer: 4.0,
                crop: None,
                child_notes: Vec::new(),
            },
        ],
        notes: vec![PureRefTextNote {
            text: "Color Direction\nWarm Ochre + Slate".to_string(),
            center_x: 0.0,
            center_y: -260.0,
            scale: 1.2,
            z_layer: 8.0,
            foreground: PureRefColor::from_note_style(NoteStyle::Warm).0,
            background: PureRefColor::from_note_style(NoteStyle::Warm).1,
            child_notes: Vec::new(),
        }],
        ..PureRefScene::default()
    };

    let encoded = PureRefCodec::encode(&scene).expect("encode .pur");
    assert!(encoded.len() > 224);

    // Verify UTF-16BE MD5 integrity checksum at [44..108] matches MD5(encoded[108..])
    let mut md5 = Md5::new();
    md5.update(&encoded[108..]);
    let expected_hex = hex::encode(md5.finalize());
    let mut units = Vec::with_capacity(32);
    for chunk in encoded[44..108].chunks_exact(2) {
        units.push(u16::from_be_bytes([chunk[0], chunk[1]]));
    }
    assert_eq!(String::from_utf16_lossy(&units), expected_hex);

    let decoded = PureRefCodec::decode_bytes(&encoded, "RoundTrip").expect("decode .pur");
    assert_eq!(decoded.format_version, "1.10");
    assert!(!decoded.used_fallback_extraction);
    assert_eq!(
        decoded.images.len(),
        2,
        "duplicate reference must share 1 blob"
    );
    assert_eq!(decoded.placements.len(), 3);
    assert_eq!(decoded.notes.len(), 1);
    assert_eq!(decoded.notes[0].text, "Color Direction\nWarm Ochre + Slate");
    assert_eq!(
        decoded.notes[0].background.inferred_note_style(),
        NoteStyle::Warm
    );

    let p0 = &decoded.placements[0];
    assert!((p0.center_x - (-180.0)).abs() < 0.01);
    assert!((p0.center_y - 40.0).abs() < 0.01);
    assert!((p0.rotation_degrees - 15.0).abs() < 0.15);
    assert!(p0.flip_horizontal);
    assert!(!p0.flip_vertical);
    let dec_crop = p0.crop.expect("crop preserved");
    assert!((dec_crop.x - crop.x).abs() < 0.02);
    assert!((dec_crop.width - crop.width).abs() < 0.02);
    assert_eq!(p0.child_notes.len(), 1);
    assert_eq!(p0.child_notes[0].text, "Rim light cue");

    let p1 = &decoded.placements[1];
    assert_eq!(p1.image_index, 0);
    assert!(p1.flip_vertical);
    assert!((p1.rotation_degrees - (-10.0)).abs() < 0.15);
}

#[test]
fn carves_v2_pureref_mixed_png_and_jpeg_streams_with_dedup_and_notes() {
    let mut bytes = vec![0u8; 224];
    // Header version "2.0" (6 bytes UTF-16BE)
    bytes[0..4].copy_from_slice(&6u32.to_be_bytes());
    for (idx, u) in "2.0".encode_utf16().enumerate() {
        bytes[(4 + idx * 2)..(6 + idx * 2)].copy_from_slice(&u.to_be_bytes());
    }

    let png = make_png(96, 64, [20, 180, 90, 255]);
    let jpg = make_jpeg(110, 80, [240, 150, 40]);

    // Embed PNG, duplicate PNG, JPEG, and an opaque UTF-16BE GraphicsTextItem note
    bytes.extend_from_slice(&[0xDE, 0xAD, 0xBE, 0xEF]);
    bytes.extend_from_slice(&png);
    bytes.extend_from_slice(&[0x00, 0x11, 0x22]);
    bytes.extend_from_slice(&png); // duplicate should be SHA-256 deduplicated
    bytes.extend_from_slice(&[0x33, 0x44]);
    bytes.extend_from_slice(&jpg);

    for u in "GraphicsTextItem".encode_utf16() {
        bytes.extend_from_slice(&u.to_be_bytes());
    }
    let note_utf16: Vec<u8> = "Scene v2 Note"
        .encode_utf16()
        .flat_map(|u| u.to_be_bytes())
        .collect();
    bytes.extend_from_slice(&(note_utf16.len() as u32).to_be_bytes());
    bytes.extend_from_slice(&note_utf16);

    let decoded = PureRefCodec::decode_bytes(&bytes, "V2Scene").expect("carve v2 .pur");
    assert_eq!(decoded.format_version, "2.0");
    assert!(decoded.used_fallback_extraction);
    assert_eq!(decoded.images.len(), 2);
    assert_eq!(decoded.images[0].format, PureRefImageFormat::Png);
    assert_eq!(decoded.images[1].format, PureRefImageFormat::Jpeg);
    assert_eq!(decoded.notes.len(), 1);
    assert_eq!(decoded.notes[0].text, "Scene v2 Note");
}

#[tokio::test]
async fn engine_imports_and_exports_pureref_moodboard_bidirectionally() {
    let tmp = tempdir().unwrap();
    let engine = LiveCharkleEngine::open(tmp.path()).unwrap();

    // Seed two real images via export_assets_to_pure_ref -> import_pure_ref_scene -> export_moodboard_to_pure_ref
    let png_a = make_png(320, 200, [210, 60, 70, 255]);
    let png_b = make_png(200, 320, [50, 120, 215, 255]);
    let a_id = Uuid::new_v4();
    let b_id = Uuid::new_v4();

    let mut board = MoodboardDocument::new("Lighting Study");
    board.mode = BoardLayoutMode::Freeform;
    board.nodes = vec![
        BoardNode {
            id: Uuid::new_v4(),
            kind: BoardNodeKind::AssetRef {
                asset_id: a_id,
                crop: Some(NormalizedCropRect {
                    x: 0.1,
                    y: 0.1,
                    width: 0.7,
                    height: 0.7,
                }),
                weight: 1,
                autoplay_loop: false,
            },
            frame: BoardRect::new(100.0, 120.0, 320.0, 200.0),
            z_index: 0,
            rotation_degrees: 12.0,
            flip_horizontal: true,
            flip_vertical: false,
            is_locked: false,
            editorial_order: 0,
            updated_at: chrono::Utc::now(),
        },
        BoardNode {
            id: Uuid::new_v4(),
            kind: BoardNodeKind::AssetRef {
                asset_id: b_id,
                crop: None,
                weight: 1,
                autoplay_loop: false,
            },
            frame: BoardRect::new(460.0, 120.0, 200.0, 320.0),
            z_index: 1,
            rotation_degrees: 0.0,
            flip_horizontal: false,
            flip_vertical: false,
            is_locked: false,
            editorial_order: 1,
            updated_at: chrono::Utc::now(),
        },
        BoardNode {
            id: Uuid::new_v4(),
            kind: BoardNodeKind::Note {
                title: Some("Key Light".to_string()),
                text: "45deg tungsten".to_string(),
                style: NoteStyle::Sage,
                font_size: 15.0,
            },
            frame: BoardRect::new(120.0, 380.0, 240.0, 96.0),
            z_index: 2,
            rotation_degrees: 0.0,
            flip_horizontal: false,
            flip_vertical: false,
            is_locked: false,
            editorial_order: 2,
            updated_at: chrono::Utc::now(),
        },
    ];

    let mut inputs_by_id = HashMap::new();
    inputs_by_id.insert(
        a_id,
        PureRefAssetInput {
            id: a_id,
            title: "Warm Key".to_string(),
            file_name: "warm.png".to_string(),
            pixel_width: 320,
            pixel_height: 200,
            image_data: png_a,
        },
    );
    inputs_by_id.insert(
        b_id,
        PureRefAssetInput {
            id: b_id,
            title: "Cool Fill".to_string(),
            file_name: "cool.png".to_string(),
            pixel_width: 200,
            pixel_height: 320,
            image_data: png_b,
        },
    );

    let (scene, skipped) = PureRefCodec::build_scene_from_board(&board, &inputs_by_id);
    assert_eq!(skipped, 0);
    let pur_path = tmp.path().join("Lighting Study.pur");
    std::fs::write(&pur_path, PureRefCodec::encode(&scene).unwrap()).unwrap();

    // Import into LiveCharkleEngine -> creates folder + assets + freeform Moodboard
    let imported = engine
        .import_pure_ref_scene(&pur_path, None, true)
        .await
        .expect("import_pure_ref_scene");
    assert_eq!(imported.imported_assets.len(), 2);
    assert_eq!(imported.imported_note_count, 1);
    assert!(imported.root_folder_id.is_some());
    let board_id = imported.created_board_id.expect("created board");
    let saved_board = engine.fetch_board(board_id).unwrap().expect("board in db");
    assert_eq!(saved_board.nodes.len(), 3);

    // Export the imported board back out to a new .pur file
    let reexport_path = tmp.path().join("Lighting Study Out.pur");
    let export_report = engine
        .export_moodboard_to_pure_ref(&saved_board, &reexport_path)
        .expect("export_moodboard_to_pure_ref");
    assert_eq!(export_report.image_count, 2);
    assert_eq!(export_report.note_count, 1);
    assert!(export_report.byte_count > 224);

    // Export assets directly from library
    let asset_ids: Vec<Uuid> = imported.imported_assets.iter().map(|a| a.id).collect();
    let gallery_pur = tmp.path().join("Selection.pur");
    let sel_report = engine
        .export_assets_to_pure_ref(&asset_ids, &gallery_pur)
        .expect("export_assets_to_pure_ref");
    assert_eq!(sel_report.image_count, 2);
}
