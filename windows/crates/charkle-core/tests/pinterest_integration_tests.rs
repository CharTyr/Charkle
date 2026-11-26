//! Offline unit & integration tests for Charkle Windows Pinterest v1.4.1 core engine.
//! Mirrors `Tests/CharkleTests/PinterestIntegrationTests.swift` 1:1.

use std::sync::atomic::{AtomicBool, Ordering};

use charkle_core::engine::LiveCharkleEngine;
use charkle_core::models::core::FilterCriteria;
use charkle_core::pinterest::{
    InfiniteSpatialCamera, PinterestBoard, PinterestBoardImportDestination,
    PinterestBoardImportProgress, PinterestImportService, PinterestJSONParser,
    PinterestMediaPayload, PinterestPin, PinterestSpatialLayout, SpatialPoint, SpatialRect,
    SpatialSize,
};
use tempfile::TempDir;

fn sample_pins(count: usize) -> Vec<PinterestPin> {
    (0..count)
        .map(|idx| {
            let height = 900 + ((idx * 173) % 700) as i32;
            PinterestPin {
                id: format!("pin_{idx}"),
                title: format!("Inspiration {idx}"),
                description: String::new(),
                author_name: None,
                author_username: None,
                author_avatar_url: None,
                board_name: None,
                board_id: None,
                domain: None,
                link_url: None,
                pin_page_url: format!("https://www.pinterest.com/pin/100000{idx}/"),
                original_url: Some(format!("https://i.pinimg.com/originals/p/{idx}.jpg")),
                preview_url: Some(format!("https://i.pinimg.com/736x/p/{idx}.jpg")),
                thumbnail_url: Some(format!("https://i.pinimg.com/236x/p/{idx}.jpg")),
                video_url: None,
                pixel_width: 800,
                pixel_height: height,
                dominant_color_hex: None,
            }
        })
        .collect()
}

fn minimal_png_bytes(r: u8, g: u8, b: u8) -> Vec<u8> {
    let img = image::RgbImage::from_pixel(4, 4, image::Rgb([r, g, b]));
    let mut buf = std::io::Cursor::new(Vec::new());
    image::DynamicImage::ImageRgb8(img)
        .write_to(&mut buf, image::ImageFormat::Png)
        .expect("encode test png");
    buf.into_inner()
}

#[test]
fn parse_homefeed_json_extracts_pins_bookmarks_and_deduplicates() {
    let sample = br##"{
      "resource_response": {
        "bookmark": "Y2JOb3hNVGcxTmpF",
        "data": [
          {
            "id": "109876543210",
            "grid_title": "Brutalist Poster Grid",
            "description": "Swiss typography study with stark shadows",
            "dominant_color": "#262220",
            "domain": "design.example.com",
            "link": "https://design.example.com/brutalist",
            "pinner": {
              "username": "studio_nord",
              "full_name": "Studio Nord",
              "image_medium_url": "https://i.pinimg.com/75x75_RS/avatar.jpg"
            },
            "board": {
              "id": "990011",
              "name": "Graphic Posters"
            },
            "images": {
              "236x": { "url": "https://i.pinimg.com/236x/aa/bb/cc/poster.jpg", "width": 236, "height": 354 },
              "736x": { "url": "https://i.pinimg.com/736x/aa/bb/cc/poster.jpg", "width": 736, "height": 1104 },
              "orig": { "url": "https://i.pinimg.com/originals/aa/bb/cc/poster.jpg", "width": 1600, "height": 2400 }
            }
          },
          {
            "id": "109876543210",
            "title": "Duplicate should be filtered",
            "images": {
              "orig": { "url": "https://i.pinimg.com/originals/aa/bb/cc/poster.jpg", "width": 1600, "height": 2400 }
            }
          },
          {
            "id": "209876543211",
            "title": "Kinetic Motion Loop",
            "image_signature": "abcdef1234567890",
            "videos": {
              "video_list": {
                "V_720P": { "url": "https://v1.pinimg.com/videos/mc/720p/loop.mp4" }
              }
            }
          }
        ]
      }
    }"##;

    let page = PinterestJSONParser::parse_feed_page(sample, "主页推荐");
    assert_eq!(page.pins.len(), 2);
    assert_eq!(page.next_bookmark.as_deref(), Some("Y2JOb3hNVGcxTmpF"));
    assert!(page.has_more);

    let first = &page.pins[0];
    assert_eq!(first.id, "109876543210");
    assert_eq!(first.title, "Brutalist Poster Grid");
    assert_eq!(first.pixel_width, 1600);
    assert_eq!(first.pixel_height, 2400);
    assert_eq!(first.author_name.as_deref(), Some("Studio Nord"));
    assert_eq!(first.board_name.as_deref(), Some("Graphic Posters"));
    assert_eq!(first.dominant_color_hex.as_deref(), Some("#262220"));
    assert_eq!(
        first.original_url.as_deref(),
        Some("https://i.pinimg.com/originals/aa/bb/cc/poster.jpg")
    );
    assert_eq!(
        first.display_image_url(120.0),
        Some("https://i.pinimg.com/236x/aa/bb/cc/poster.jpg")
    );
    assert_eq!(
        first.display_image_url(260.0),
        Some("https://i.pinimg.com/736x/aa/bb/cc/poster.jpg")
    );
    assert_eq!(
        first.display_image_url(900.0),
        Some("https://i.pinimg.com/originals/aa/bb/cc/poster.jpg")
    );

    let second = &page.pins[1];
    assert_eq!(second.id, "209876543211");
    assert_eq!(
        second.video_url.as_deref(),
        Some("https://v1.pinimg.com/videos/mc/720p/loop.mp4")
    );
    assert_eq!(
        second.best_import_media_url(),
        Some("https://v1.pinimg.com/videos/mc/720p/loop.mp4")
    );
    assert_eq!(
        second.original_url.as_deref(),
        Some("https://i.pinimg.com/originals/ab/cd/ef/abcdef1234567890.jpg")
    );
}

#[test]
fn parse_account_and_boards_json() {
    let account_json = br#"{
      "resource_response": {
        "data": {
          "id": "5544332211",
          "username": "atelier_lin",
          "full_name": "Atelier Lin",
          "email": "lin@example.com",
          "image_large_url": "https://i.pinimg.com/280x280_RS/lin.jpg"
        }
      }
    }"#;

    let account = PinterestJSONParser::parse_account(account_json).expect("account parsed");
    assert_eq!(account.username, "atelier_lin");
    assert_eq!(account.full_name, "Atelier Lin");
    assert_eq!(account.display_name(), "Atelier Lin");

    let boards_json = br#"{
      "resource_response": {
        "bookmark": "board_cursor_2",
        "data": [
          {
            "type": "board",
            "id": "88001",
            "name": "UI Microinteractions",
            "url": "/atelier_lin/ui-microinteractions/",
            "pin_count": 48,
            "privacy": "public",
            "image_cover_hd_url": "https://i.pinimg.com/400x300/cover1.jpg"
          },
          {
            "type": "board",
            "id": "88002",
            "name": "Secret Lighting",
            "url": "/atelier_lin/secret-lighting/",
            "pin_count": 12,
            "privacy": "secret"
          }
        ]
      }
    }"#;

    let boards_page = PinterestJSONParser::parse_boards_page(boards_json);
    assert_eq!(boards_page.boards.len(), 2);
    assert_eq!(boards_page.next_bookmark.as_deref(), Some("board_cursor_2"));
    assert!(boards_page.has_more);
    assert_eq!(boards_page.boards[0].name, "UI Microinteractions");
    assert_eq!(boards_page.boards[0].pin_count, 48);
    assert!(!boards_page.boards[0].is_secret);
    assert!(boards_page.boards[1].is_secret);
}

#[test]
fn parse_pins_from_embedded_html_script() {
    let html = r#"<!doctype html><html><head><script id="__PWS_INITIAL_PROPS__" type="application/json">{"initialReduxState":{"pins":{"777888999":{"id":"777888999","title":"Ceramic Vase","images":{"orig":{"url":"https://i.pinimg.com/originals/11/22/33/vase.jpg","width":1200,"height":1500}}}}}}</script></head><body></body></html>"#;

    let page = PinterestJSONParser::parse_pins_from_html(html, "HTML");
    assert_eq!(page.pins.len(), 1);
    assert_eq!(page.pins[0].id, "777888999");
    assert_eq!(page.pins[0].title, "Ceramic Vase");
}

#[test]
fn extract_pin_id_matches_pinterest_domains() {
    assert_eq!(
        PinterestJSONParser::extract_pin_id("https://www.pinterest.com/pin/49258189623456789/"),
        Some("49258189623456789".to_string())
    );
    assert_eq!(
        PinterestJSONParser::extract_pin_id("https://jp.pinterest.com/pin/123456789/?nic_v3=1"),
        Some("123456789".to_string())
    );
    assert_eq!(
        PinterestJSONParser::extract_pin_id("https://example.com/pin/123456789/"),
        None
    );
}

#[test]
fn spatial_layout_is_non_overlapping_append_stable_and_four_quadrant() {
    let mut layout = PinterestSpatialLayout::new(220.0, 16.0);
    let first_batch = sample_pins(40);
    let placed_first = layout.append(&first_batch);
    assert_eq!(placed_first.len(), 40);

    let first_frames: std::collections::HashMap<String, SpatialRect> = placed_first
        .iter()
        .map(|c| (c.id.clone(), c.frame))
        .collect();

    let second_batch: Vec<PinterestPin> = (40..90)
        .map(|idx| PinterestPin {
            id: format!("pin_{idx}"),
            title: format!("Pin {idx}"),
            description: String::new(),
            author_name: None,
            author_username: None,
            author_avatar_url: None,
            board_name: None,
            board_id: None,
            domain: None,
            link_url: None,
            pin_page_url: format!("https://www.pinterest.com/pin/200000{idx}/"),
            original_url: Some(format!("https://i.pinimg.com/originals/p/{idx}.jpg")),
            preview_url: Some(format!("https://i.pinimg.com/736x/p/{idx}.jpg")),
            thumbnail_url: Some(format!("https://i.pinimg.com/236x/p/{idx}.jpg")),
            video_url: None,
            pixel_width: 900,
            pixel_height: 1200,
            dominant_color_hex: None,
        })
        .collect();

    layout.append(&second_batch);
    assert_eq!(layout.cards().len(), 90);

    // 1. Existing cards NEVER shift on append (0pt jump).
    for card in layout.cards().iter().take(40) {
        let orig = first_frames.get(&card.id).copied().unwrap();
        assert_eq!(card.frame, orig);
    }

    // 2. Non-overlapping geometry across all cards.
    let cards = layout.cards();
    for i in 0..cards.len() {
        for j in (i + 1)..cards.len() {
            assert!(
                !cards[i].frame.intersects(cards[j].frame),
                "Cards {} and {} overlap",
                cards[i].id,
                cards[j].id
            );
        }
    }

    // 3. Content spans all four quadrants around origin.
    let bounds = layout.content_bounds();
    assert!(bounds.min_x() < 0.0);
    assert!(bounds.max_x() > 0.0);
    assert!(bounds.min_y() < 0.0);
    assert!(bounds.max_y() > 0.0);

    // 4. Viewport culling returns a strict subset.
    let small_rect = SpatialRect::new(-180.0, -180.0, 360.0, 360.0);
    let visible = layout.visible_cards(small_rect, 40.0);
    assert!(!visible.is_empty());
    assert!(visible.len() < cards.len());

    // 5. Edge detection triggers near boundary and stays false near center.
    assert!(!layout.is_approaching_edge(SpatialRect::new(-50.0, -50.0, 100.0, 100.0), 120.0));
    assert!(layout.is_approaching_edge(
        SpatialRect::new(bounds.max_x() - 100.0, 0.0, 200.0, 200.0),
        220.0
    ));
}

#[test]
fn predictive_prefetch_prioritizes_offscreen_cards_in_pan_direction() {
    let mut layout = PinterestSpatialLayout::new(220.0, 16.0);
    layout.append(&sample_pins(90));

    let viewport = SpatialRect::new(-220.0, -180.0, 440.0, 360.0);
    let eastward = layout.predictive_prefetch_cards(
        viewport,
        SpatialSize {
            width: 560.0,
            height: 0.0,
        },
        720.0,
        12,
    );
    assert!(!eastward.is_empty());
    for card in &eastward {
        assert!(!card.frame.intersects(viewport));
    }
    let avg_east_x: f64 =
        eastward.iter().map(|c| c.frame.mid_x()).sum::<f64>() / eastward.len() as f64;
    assert!(avg_east_x > viewport.mid_x());

    let westward = layout.predictive_prefetch_cards(
        viewport,
        SpatialSize {
            width: -560.0,
            height: 0.0,
        },
        720.0,
        12,
    );
    assert!(!westward.is_empty());
    let avg_west_x: f64 =
        westward.iter().map(|c| c.frame.mid_x()).sum::<f64>() / westward.len() as f64;
    assert!(avg_west_x < viewport.mid_x());
}

#[test]
fn spatial_camera_zoom_keeps_anchor_world_point_stationary() {
    let mut camera = InfiniteSpatialCamera::default();
    camera.center_on_origin(
        SpatialSize {
            width: 1200.0,
            height: 800.0,
        },
        1.0,
    );

    let anchor = SpatialPoint { x: 840.0, y: 260.0 };
    let world_before = camera.screen_to_world(anchor);

    camera.zoom(1.85, anchor);
    let world_after = camera.screen_to_world(anchor);

    assert!((world_before.x - world_after.x).abs() < 0.001);
    assert!((world_before.y - world_after.y).abs() < 0.001);
}

#[tokio::test]
async fn batch_board_import_creates_folders_deduplicates_and_supports_cancellation() {
    let temp = TempDir::new().expect("tempdir");
    let engine = LiveCharkleEngine::open(temp.path()).expect("open engine");

    let boards = vec![
        PinterestBoard {
            id: "b1".to_string(),
            name: "Editorial / Type".to_string(),
            url_path: "/demo/editorial-type/".to_string(),
            description: None,
            pin_count: 2,
            cover_image_url: None,
            is_secret: false,
            owner_username: Some("demo".to_string()),
        },
        PinterestBoard {
            id: "b2".to_string(),
            name: "Color Palettes".to_string(),
            url_path: "/demo/color-palettes/".to_string(),
            description: None,
            pin_count: 1,
            cover_image_url: None,
            is_secret: false,
            owner_username: Some("demo".to_string()),
        },
    ];

    let pin_a = PinterestPin {
        id: "70000001".to_string(),
        title: "Swiss Grid Poster".to_string(),
        description: "Bold typography study".to_string(),
        author_name: Some("Studio A".to_string()),
        author_username: Some("studioa".to_string()),
        author_avatar_url: None,
        board_name: Some("Editorial / Type".to_string()),
        board_id: Some("b1".to_string()),
        domain: Some("example.com".to_string()),
        link_url: Some("https://example.com/a".to_string()),
        pin_page_url: "https://www.pinterest.com/pin/70000001/".to_string(),
        original_url: Some("https://i.pinimg.com/originals/a.png".to_string()),
        preview_url: None,
        thumbnail_url: None,
        video_url: None,
        pixel_width: 4,
        pixel_height: 4,
        dominant_color_hex: None,
    };
    let pin_b = PinterestPin {
        id: "70000002".to_string(),
        title: "Warm Terracotta Swatch".to_string(),
        description: String::new(),
        author_name: None,
        author_username: None,
        author_avatar_url: None,
        board_name: Some("Color Palettes".to_string()),
        board_id: Some("b2".to_string()),
        domain: None,
        link_url: None,
        pin_page_url: "https://www.pinterest.com/pin/70000002/".to_string(),
        original_url: Some("https://i.pinimg.com/originals/b.png".to_string()),
        preview_url: None,
        thumbnail_url: None,
        video_url: None,
        pixel_width: 4,
        pixel_height: 4,
        dominant_color_hex: None,
    };

    let pin_a_c = pin_a.clone();
    let pin_b_c = pin_b.clone();
    let mut progress_events: Vec<PinterestBoardImportProgress> = Vec::new();

    let first_report = PinterestImportService::import_boards(
        &boards,
        &engine,
        PinterestBoardImportDestination::PinterestRootFolder,
        &["灵感库".to_string()],
        true,
        None,
        |board| {
            let pa = pin_a_c.clone();
            let pb = pin_b_c.clone();
            async move {
                if board.id == "b1" {
                    Ok(vec![pa])
                } else {
                    Ok(vec![pb])
                }
            }
        },
        |url| async move {
            let bytes = if url.ends_with("a.png") {
                minimal_png_bytes(220, 60, 40)
            } else {
                minimal_png_bytes(40, 140, 210)
            };
            Ok(PinterestMediaPayload {
                data: bytes,
                mime_type: "image/png".to_string(),
                suggested_extension: "png".to_string(),
            })
        },
        |p| progress_events.push(p),
    )
    .await;

    assert!(!first_report.was_cancelled);
    assert_eq!(first_report.imported_asset_count, 2);
    assert_eq!(first_report.skipped_duplicate_count, 0);
    assert_eq!(first_report.failed_pin_count, 0);
    assert!(!progress_events.is_empty());

    let folders = engine.fetch_folders().expect("folders");
    let root = folders
        .iter()
        .find(|f| f.name == "Pinterest" && f.parent_id.is_none())
        .expect("Pinterest root folder created");
    assert!(folders
        .iter()
        .any(|f| f.parent_id == Some(root.id) && f.name == "Editorial · Type"));
    assert!(folders
        .iter()
        .any(|f| f.parent_id == Some(root.id) && f.name == "Color Palettes"));

    let existing_ids = PinterestImportService::existing_imported_pin_ids(&engine);
    assert!(existing_ids.contains("70000001"));
    assert!(existing_ids.contains("70000002"));

    let assets = engine
        .fetch_assets(&FilterCriteria::default())
        .expect("assets");
    assert_eq!(assets.len(), 2);
    assert!(assets
        .iter()
        .all(|a| a.tags.contains(&"Pinterest".to_string())));
    assert!(assets
        .iter()
        .all(|a| a.tags.contains(&"灵感库".to_string())));

    // Incremental re-import skips already-imported pins cleanly.
    let second_report = PinterestImportService::import_boards(
        &boards,
        &engine,
        PinterestBoardImportDestination::PinterestRootFolder,
        &[],
        true,
        None,
        |board| {
            let pa = pin_a.clone();
            let pb = pin_b.clone();
            async move {
                if board.id == "b1" {
                    Ok(vec![pa])
                } else {
                    Ok(vec![pb])
                }
            }
        },
        |_url| async move {
            Ok(PinterestMediaPayload {
                data: minimal_png_bytes(1, 2, 3),
                mime_type: "image/png".to_string(),
                suggested_extension: "png".to_string(),
            })
        },
        |_| {},
    )
    .await;

    assert_eq!(second_report.imported_asset_count, 0);
    assert_eq!(second_report.skipped_duplicate_count, 2);

    // Pre-cancelled flag stops immediately.
    let cancel = AtomicBool::new(true);
    let cancelled_report = PinterestImportService::import_boards(
        &boards,
        &engine,
        PinterestBoardImportDestination::LibraryRoot,
        &[],
        false,
        Some(&cancel),
        |_board| async move { Ok(vec![]) },
        |_url| async move {
            Ok(PinterestMediaPayload {
                data: minimal_png_bytes(9, 9, 9),
                mime_type: "image/png".to_string(),
                suggested_extension: "png".to_string(),
            })
        },
        |_| {},
    )
    .await;
    assert!(cancelled_report.was_cancelled);
    assert!(cancel.load(Ordering::SeqCst));
}
