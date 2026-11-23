//! Comprehensive `MediaPipeline` tests: 8-kind detection (incl. APNG), thumbnails,
//! SVG rasterization (`resvg`), CIELAB dominant colors, EXIF + AI prompt extraction,
//! `symphonia` 48-bar audio waveforms, URL parsers, LRU eviction with `pinnedOffline`
//! protection (assets + Moodboards), and `SampleLibrarySeeder`.

use std::collections::HashSet;
use std::fs;

use charkle_core::db::LibraryDatabase;
use charkle_core::media::metadata::ImageMetadataExtractor;
use charkle_core::media::resolvers::{
    GitHubRepoURLParser, SocialPostReference, SocialPostURLParser, WebBookmarkResolver,
};
use charkle_core::media::{MediaPipeline, SampleLibrarySeeder};
use charkle_core::models::core::{AssetRecord, MediaKind, SocialPlatform};
use charkle_core::models::media::{CaptureInput, ThumbnailTier};
use charkle_core::models::moodboard::{BoardNode, BoardNodeKind, BoardRect, MoodboardDocument};
use chrono::{Duration, Utc};
use image::{DynamicImage, ImageFormat, Rgba, RgbaImage};
use tempfile::tempdir;
use url::Url;
use uuid::Uuid;

fn make_png(width: u32, height: u32, rgba: [u8; 4]) -> Vec<u8> {
    let img = RgbaImage::from_pixel(width, height, Rgba(rgba));
    let mut cursor = std::io::Cursor::new(Vec::new());
    DynamicImage::ImageRgba8(img)
        .write_to(&mut cursor, ImageFormat::Png)
        .expect("encode png");
    cursor.into_inner()
}

/// Inserts a PNG chunk (e.g., `tEXt` or `acTL`) right after the 33-byte PNG signature + IHDR.
fn inject_png_chunk(png: &[u8], chunk_type: &[u8; 4], payload: &[u8]) -> Vec<u8> {
    assert!(png.len() > 33 && &png[..8] == b"\x89PNG\r\n\x1a\n");
    let mut out = Vec::with_capacity(png.len() + payload.len() + 12);
    out.extend_from_slice(&png[..33]);
    out.extend_from_slice(&(payload.len() as u32).to_be_bytes());
    out.extend_from_slice(chunk_type);
    out.extend_from_slice(payload);
    let crc = crc32_ieee(chunk_type, payload);
    out.extend_from_slice(&crc.to_be_bytes());
    out.extend_from_slice(&png[33..]);
    out
}

fn crc32_ieee(chunk_type: &[u8; 4], data: &[u8]) -> u32 {
    let mut crc: u32 = 0xFFFF_FFFF;
    for &b in chunk_type.iter().chain(data.iter()) {
        crc ^= b as u32;
        for _ in 0..8 {
            if (crc & 1) != 0 {
                crc = (crc >> 1) ^ 0xEDB8_8320;
            } else {
                crc >>= 1;
            }
        }
    }
    !crc
}

/// Synthesizes a valid 16-bit mono PCM WAV file with a 440 Hz sine wave.
fn make_sine_wav(sample_rate: u32, duration_secs: f32) -> Vec<u8> {
    let num_samples = (sample_rate as f32 * duration_secs) as usize;
    let data_bytes = (num_samples * 2) as u32;
    let mut wav = Vec::with_capacity(44 + data_bytes as usize);
    wav.extend_from_slice(b"RIFF");
    wav.extend_from_slice(&(36 + data_bytes).to_le_bytes());
    wav.extend_from_slice(b"WAVE");
    wav.extend_from_slice(b"fmt ");
    wav.extend_from_slice(&16u32.to_le_bytes());
    wav.extend_from_slice(&1u16.to_le_bytes()); // PCM
    wav.extend_from_slice(&1u16.to_le_bytes()); // mono
    wav.extend_from_slice(&sample_rate.to_le_bytes());
    wav.extend_from_slice(&(sample_rate * 2).to_le_bytes());
    wav.extend_from_slice(&2u16.to_le_bytes());
    wav.extend_from_slice(&16u16.to_le_bytes());
    wav.extend_from_slice(b"data");
    wav.extend_from_slice(&data_bytes.to_le_bytes());
    for i in 0..num_samples {
        let t = i as f32 / sample_rate as f32;
        // Modulate amplitude over time so peak envelope varies cleanly
        let env = 0.25 + 0.75 * (i as f32 / num_samples as f32);
        let sample = ((2.0 * std::f32::consts::PI * 440.0 * t).sin() * env * 28_000.0) as i16;
        wav.extend_from_slice(&sample.to_le_bytes());
    }
    wav
}

#[tokio::test]
async fn ingests_raster_svg_swatch_markdown_audio_and_apng_across_media_kinds() {
    let tmp = tempdir().unwrap();
    let pipeline = MediaPipeline::new(tmp.path().join("media")).unwrap();

    // 1. Large PNG -> both grid520 and preview1400 thumbnails + dominant cobalt color
    let large_png = make_png(1600, 900, [42, 96, 224, 255]);
    let img_res = pipeline
        .ingest(
            CaptureInput::ImageData {
                data: large_png.clone(),
                suggested_name: "CobaltHero.png".to_string(),
                source_url: Some("https://example.com/hero".to_string()),
            },
            None,
            None,
        )
        .await
        .unwrap();
    assert_eq!(img_res.asset.media_kind, MediaKind::Image);
    assert_eq!(img_res.asset.pixel_width, 1600);
    assert_eq!(img_res.asset.pixel_height, 900);
    assert!(pipeline
        .thumbnail_url(img_res.asset.id, ThumbnailTier::Grid520)
        .is_some());
    assert!(pipeline
        .thumbnail_url(img_res.asset.id, ThumbnailTier::Preview1400)
        .is_some());
    assert!(!img_res.asset.dominant_colors.is_empty());

    // 2. APNG promotion (`acTL` chunk) -> MediaKind::AnimatedImage
    let apng_bytes = inject_png_chunk(
        &make_png(200, 200, [200, 80, 60, 255]),
        b"acTL",
        &[0, 0, 0, 2, 0, 0, 0, 0],
    );
    assert!(ImageMetadataExtractor::is_animated_png(&apng_bytes));
    let apng_res = pipeline
        .ingest(
            CaptureInput::ImageData {
                data: apng_bytes,
                suggested_name: "Loop.png".to_string(),
                source_url: None,
            },
            None,
            None,
        )
        .await
        .unwrap();
    assert_eq!(apng_res.asset.media_kind, MediaKind::AnimatedImage);

    // 3. SVG DesignFile rasterized via `resvg`
    let svg_path = tmp.path().join("mark.svg");
    fs::write(
        &svg_path,
        r##"<svg xmlns="http://www.w3.org/2000/svg" width="400" height="400">
            <rect width="400" height="400" fill="#181A20"/>
            <circle cx="200" cy="200" r="120" fill="#E05A47"/>
        </svg>"##,
    )
    .unwrap();
    let svg_res = pipeline
        .ingest(CaptureInput::FilePath(svg_path), None, None)
        .await
        .unwrap();
    assert_eq!(svg_res.asset.media_kind, MediaKind::DesignFile);
    assert!(pipeline
        .thumbnail_url(svg_res.asset.id, ThumbnailTier::Grid520)
        .is_some());
    assert!(!svg_res.asset.dominant_colors.is_empty());

    // 4. ColorSwatch capture
    let swatch_res = pipeline
        .ingest(
            CaptureInput::ColorSwatch {
                hex: "#2A60E0".to_string(),
                title: Some("Cobalt Blue".to_string()),
            },
            None,
            None,
        )
        .await
        .unwrap();
    assert_eq!(swatch_res.asset.title, "Cobalt Blue");
    assert_eq!(swatch_res.asset.media_kind, MediaKind::Image);

    // 5. TextSnippet Markdown capture -> text_excerpt + plain-text ocr_text
    let md_res = pipeline
        .ingest(
            CaptureInput::TextSnippet {
                title: "Design Notes".to_string(),
                text: "# Typography\nUse **clean** Swiss hierarchy.".to_string(),
                source_url: None,
            },
            None,
            None,
        )
        .await
        .unwrap();
    assert_eq!(md_res.asset.media_kind, MediaKind::Document);
    let rich = md_res.asset.rich_metadata.as_ref().unwrap();
    assert!(rich.is_markdown);
    assert!(rich.text_excerpt.as_deref().unwrap().contains("Typography"));
    assert!(md_res.asset.ocr_text.as_deref().unwrap().contains("clean"));

    // 6. Audio WAV -> symphonia duration & 48-bar waveform peaks
    let wav_path = tmp.path().join("tone.wav");
    fs::write(&wav_path, make_sine_wav(16_000, 0.5)).unwrap();
    let wav_res = pipeline
        .ingest(CaptureInput::FilePath(wav_path), None, None)
        .await
        .unwrap();
    assert_eq!(wav_res.asset.media_kind, MediaKind::Audio);
    assert!(wav_res.asset.duration_seconds.unwrap_or(0.0) > 0.35);
    assert_eq!(wav_res.asset.waveform_peaks.len(), 48);
    assert!(wav_res
        .asset
        .waveform_peaks
        .iter()
        .all(|&p| (0.0..=1.0).contains(&p)));
    assert!(wav_res.asset.waveform_peaks.iter().any(|&p| p > 0.5));

    // 7. 3D model detection
    let glb_path = tmp.path().join("chair.glb");
    fs::write(&glb_path, b"glTF\x02\x00\x00\x00").unwrap();
    let model_res = pipeline
        .ingest(CaptureInput::FilePath(glb_path), None, None)
        .await
        .unwrap();
    assert_eq!(model_res.asset.media_kind, MediaKind::Model3D);
    assert_eq!(
        model_res
            .asset
            .rich_metadata
            .as_ref()
            .and_then(|r| r.model_3d_format.as_deref()),
        Some("GLB")
    );
}

#[test]
fn extracts_a1111_and_comfyui_ai_generation_prompts_from_png_chunks() {
    let base_png = make_png(64, 64, [120, 120, 120, 255]);

    // Stable Diffusion A1111 `parameters` tEXt chunk
    let a1111_text = "parameters\0cinematic architectural atrium, soft morning light, <lora:arch_v2:0.8>\nNegative prompt: blurry, watermark\nSteps: 28, Sampler: DPM++ 2M Karras, CFG scale: 7.5, Seed: 424242, Size: 1024x1024, Model: juggernautXL_v9, Model hash: abcd1234";
    let a1111_png = inject_png_chunk(&base_png, b"tEXt", a1111_text.as_bytes());
    let extracted = ImageMetadataExtractor::extract_from_bytes(&a1111_png);
    let ai = extracted.ai_generation.expect("A1111 metadata extracted");
    assert!(ai
        .prompt
        .as_deref()
        .unwrap()
        .contains("architectural atrium"));
    assert_eq!(ai.negative_prompt.as_deref(), Some("blurry, watermark"));
    assert_eq!(ai.steps, Some(28));
    assert_eq!(ai.cfg_scale, Some(7.5));
    assert_eq!(ai.seed.as_deref(), Some("424242"));
    assert_eq!(ai.model_name.as_deref(), Some("juggernautXL_v9"));
    assert!(ai.loras.iter().any(|l| l.contains("arch_v2")));

    // ComfyUI `prompt` JSON graph tEXt chunk
    let comfy_json = r#"{"3":{"class_type":"KSampler","inputs":{"seed":987654,"steps":20,"cfg":6.0,"sampler_name":"euler","scheduler":"normal","positive":["6",0],"negative":["7",0]}},"4":{"class_type":"CheckpointLoaderSimple","inputs":{"ckpt_name":"flux_dev.safetensors"}},"6":{"class_type":"CLIPTextEncode","inputs":{"text":"minimalist terracotta pottery on travertine plinth"}},"7":{"class_type":"CLIPTextEncode","inputs":{"text":"plastic, oversaturated"}}}"#;
    let mut comfy_payload = b"prompt\0".to_vec();
    comfy_payload.extend_from_slice(comfy_json.as_bytes());
    let comfy_png = inject_png_chunk(&base_png, b"tEXt", &comfy_payload);
    let comfy_meta = ImageMetadataExtractor::extract_from_bytes(&comfy_png)
        .ai_generation
        .expect("ComfyUI metadata extracted");
    assert_eq!(comfy_meta.generator.as_deref(), Some("ComfyUI"));
    assert!(comfy_meta
        .prompt
        .as_deref()
        .unwrap()
        .contains("terracotta pottery"));
    assert_eq!(
        comfy_meta.negative_prompt.as_deref(),
        Some("plastic, oversaturated")
    );
    assert_eq!(comfy_meta.steps, Some(20));
    assert_eq!(comfy_meta.seed.as_deref(), Some("987654"));
    assert_eq!(
        comfy_meta.model_name.as_deref(),
        Some("flux_dev.safetensors")
    );
}

#[test]
fn parses_social_github_and_bookmark_shortcut_urls() {
    let x_url = Url::parse("https://x.com/design_user/status/1890123456789012345").unwrap();
    let x_ref = SocialPostURLParser::parse(&x_url).unwrap();
    assert_eq!(x_ref.platform(), SocialPlatform::X);
    match x_ref {
        SocialPostReference::X(r) => {
            assert_eq!(r.handle, "design_user");
            assert_eq!(r.tweet_id, "1890123456789012345");
        }
        other => panic!("expected X ref, got {other:?}"),
    }

    let threads_url = Url::parse("https://www.threads.net/@studio.test/post/C9AbCdEf123").unwrap();
    let th_ref = SocialPostURLParser::parse(&threads_url).unwrap();
    assert_eq!(th_ref.platform(), SocialPlatform::Threads);
    match th_ref {
        SocialPostReference::Threads { post_id, .. } => {
            assert_eq!(post_id, "C9AbCdEf123");
        }
        other => panic!("expected Threads ref, got {other:?}"),
    }

    let bsky_url = Url::parse("https://bsky.app/profile/alice.bsky.social/post/3k2abcxyz").unwrap();
    let bs_ref = SocialPostURLParser::parse(&bsky_url).unwrap();
    assert_eq!(bs_ref.platform(), SocialPlatform::Bluesky);
    match bs_ref {
        SocialPostReference::Bluesky { rkey, .. } => {
            assert_eq!(rkey, "3k2abcxyz");
        }
        other => panic!("expected Bluesky ref, got {other:?}"),
    }

    let gh_url = Url::parse("https://github.com/tauri-apps/tauri/tree/dev").unwrap();
    let gh_ref = GitHubRepoURLParser::parse(&gh_url).unwrap();
    assert_eq!(gh_ref.owner, "tauri-apps");
    assert_eq!(gh_ref.repo, "tauri");
    assert!(GitHubRepoURLParser::parse(
        &Url::parse("https://github.com/tauri-apps/tauri/issues/123").unwrap()
    )
    .is_none());

    // Windows `.url` and macOS `.webloc` extraction
    let tmp = tempdir().unwrap();
    let win_url_file = tmp.path().join("site.url");
    fs::write(
        &win_url_file,
        "[InternetShortcut]\r\nURL=https://tauri.app/\r\n",
    )
    .unwrap();
    assert_eq!(
        WebBookmarkResolver::url_in_file(&win_url_file)
            .unwrap()
            .as_str(),
        "https://tauri.app/"
    );

    let webloc_file = tmp.path().join("mac.webloc");
    fs::write(
        &webloc_file,
        r#"<?xml version="1.0" encoding="UTF-8"?>
        <plist version="1.0"><dict><key>URL</key><string>https://rust-lang.org/</string></dict></plist>"#,
    )
    .unwrap();
    assert_eq!(
        WebBookmarkResolver::url_in_file(&webloc_file)
            .unwrap()
            .as_str(),
        "https://rust-lang.org/"
    );
}

#[tokio::test]
async fn lru_cache_eviction_protects_pinned_assets_pinned_boards_and_local_only_files() {
    let tmp = tempdir().unwrap();
    let db = LibraryDatabase::open_in_memory().unwrap();
    let pipeline = MediaPipeline::new(tmp.path().join("media")).unwrap();

    // Helper creating an asset with a 4 KB original file
    let payload = vec![0xABu8; 4096];
    let make_asset = |name: &str, drive_id: Option<&str>, pinned: bool| -> AssetRecord {
        let mut a = AssetRecord::new(name, name);
        a.drive_file_id = drive_id.map(String::from);
        a.pinned_offline = pinned;
        a.is_local_original_cached = true;
        let src = tmp.path().join(format!("{}-{name}", a.id));
        fs::write(&src, &payload).unwrap();
        pipeline.install_original(&src, &a, true).unwrap();
        db.put_asset(&a).unwrap();
        a
    };

    let now = Utc::now();
    let old_evictable = make_asset("old.bin", Some("drv-1"), false);
    let newer_evictable = make_asset("newer.bin", Some("drv-2"), false);
    let pinned_asset = make_asset("pinned.bin", Some("drv-3"), true);
    let board_protected = make_asset("board-ref.bin", Some("drv-4"), false);
    let local_unbacked = make_asset("local-only.bin", None, false);

    db.touch_original(old_evictable.id, now - Duration::hours(10))
        .unwrap();
    db.touch_original(newer_evictable.id, now - Duration::hours(1))
        .unwrap();
    db.touch_original(pinned_asset.id, now - Duration::hours(20))
        .unwrap();
    db.touch_original(board_protected.id, now - Duration::hours(20))
        .unwrap();
    db.touch_original(local_unbacked.id, now - Duration::hours(20))
        .unwrap();

    // Pin a Moodboard referencing `board_protected`
    let mut board = MoodboardDocument::new("Offline Board");
    board.pinned_offline = true;
    board.nodes.push(BoardNode {
        id: Uuid::new_v4(),
        kind: BoardNodeKind::AssetRef {
            asset_id: board_protected.id,
            crop: None,
            weight: 1,
            autoplay_loop: false,
        },
        frame: BoardRect::new(0.0, 0.0, 100.0, 100.0),
        z_index: 0,
        rotation_degrees: 0.0,
        flip_horizontal: false,
        flip_vertical: false,
        is_locked: false,
        editorial_order: 0,
        updated_at: now,
    });
    db.upsert_board(&board).unwrap();

    // Set a tight override budget of 16 KB (4 files fit; 5 files = 20 KB -> evict oldest 1)
    let stats = pipeline
        .cache_stats_and_evict(&db, true, &HashSet::new(), Some(16_384))
        .unwrap();
    assert!(pipeline.cached_original(&old_evictable).is_none());
    assert!(
        !db.asset(old_evictable.id)
            .unwrap()
            .unwrap()
            .is_local_original_cached
    );
    assert!(pipeline.cached_original(&newer_evictable).is_some());
    assert!(pipeline.cached_original(&pinned_asset).is_some());
    assert!(pipeline.cached_original(&board_protected).is_some());
    assert!(pipeline.cached_original(&local_unbacked).is_some());
    assert_eq!(stats.pinned_asset_count, 2);

    // Tightest budget (0 bytes): evicts `newer_evictable`, NEVER evicts pinned / board-pinned / local-only
    let _ = pipeline
        .cache_stats_and_evict(&db, true, &HashSet::new(), Some(0))
        .unwrap();
    assert!(pipeline.cached_original(&newer_evictable).is_none());
    assert!(pipeline.cached_original(&pinned_asset).is_some());
    assert!(pipeline.cached_original(&board_protected).is_some());
    assert!(pipeline.cached_original(&local_unbacked).is_some());
}

#[tokio::test]
async fn sample_library_seeder_populates_empty_db_and_is_idempotent() {
    let tmp = tempdir().unwrap();
    let db = LibraryDatabase::open_in_memory().unwrap();
    let pipeline = MediaPipeline::new(tmp.path().join("media")).unwrap();

    let first = SampleLibrarySeeder::seed_if_empty(&db, &pipeline)
        .await
        .unwrap();
    assert!(first);
    assert_eq!(db.fetch_folders().unwrap().len(), 4);
    assert_eq!(
        db.fetch_assets(&Default::default(), None).unwrap().len(),
        10
    );
    assert_eq!(db.fetch_boards().unwrap().len(), 1);

    // Second invocation must be a strict no-op
    let second = SampleLibrarySeeder::seed_if_empty(&db, &pipeline)
        .await
        .unwrap();
    assert!(!second);
    assert_eq!(
        db.fetch_assets(&Default::default(), None).unwrap().len(),
        10
    );
}
