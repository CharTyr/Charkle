//! Comprehensive `LibraryDatabase` tests: schema v2, FTS5 Chinese pinyin + initials + polyphones,
//! GitHub/social/EXIF/AI prompt indexing, CIELAB SQL search, all 6 SortOrder modes,
//! recursive folder BFS + cycle-safe move/delete, SmartFolderRule, QuickJump, and f16/f32 vectors.

use std::collections::BTreeSet;

use charkle_core::db::LibraryDatabase;
use charkle_core::models::core::{
    AIGenerationMetadata, AspectShape, AssetRecord, AssetRichMetadata, FilterCriteria,
    FolderRecord, GitHubRepoMetadata, LabColor, MediaKind, PhotoExifMetadata, QuickJumpKind,
    SmartFolderMatchMode, SmartFolderRecord, SmartFolderRule, SocialPlatform, SocialPostMetadata,
    SortOrder,
};
use charkle_core::models::media::{AssetVector, EmbeddingPrecision};
use charkle_core::models::moodboard::{BoardNode, BoardNodeKind, BoardRect, MoodboardDocument};
use charkle_core::models::sync::SyncOperationChange;
use chrono::{Duration, Utc};
use uuid::Uuid;

#[test]
fn schema_version_is_v2_and_fts5_searches_chinese_pinyin_initials_and_rich_metadata() {
    let db = LibraryDatabase::open_in_memory().expect("open in-memory db");
    assert_eq!(db.schema_version().unwrap(), 2);

    // Asset 1: Chinese title + polyphone ("重庆" -> chongqing / cq) + tags
    let mut a1 = AssetRecord::new("重庆暖调海报设计", "chongqing-poster.png");
    a1.tags = vec!["瑞士排版".to_string(), "暖色调".to_string()];
    a1.notes = "低角度自然光阴影研究".to_string();
    a1.dominant_colors = vec![LabColor::from_hex("#D93829", 0.7)];
    a1.rating = 5;

    // Asset 2: GitHub repo + README indexing
    let mut a2 = AssetRecord::new("tauri-apps/tauri", "tauri.url");
    a2.media_kind = MediaKind::WebBookmark;
    let mut repo_meta = GitHubRepoMetadata::new("tauri-apps", "tauri");
    repo_meta.description = Some("Build smaller, faster desktop apps".to_string());
    repo_meta.language = Some("Rust".to_string());
    repo_meta.stars = 90_000;
    repo_meta.forks = 2_800;
    repo_meta.topics = vec!["webview2".to_string(), "desktop".to_string()];
    repo_meta.readme_markdown = Some("# Tauri\nNative WebView2 bridge for Windows".to_string());
    a2.rich_metadata = Some(AssetRichMetadata {
        github_repo: Some(repo_meta),
        ..AssetRichMetadata::default()
    });

    // Asset 3: Social post + EXIF + AI prompt indexing
    let mut a3 = AssetRecord::new("Studio Lighting Study", "studio.jpg");
    a3.rich_metadata = Some(AssetRichMetadata {
        social_post: Some(SocialPostMetadata {
            platform: SocialPlatform::Bluesky,
            author_name: "Elena Vance".to_string(),
            author_handle: "elena.bsky.social".to_string(),
            author_avatar_url: None,
            published_at_text: None,
            body_text: "Cinematic tungsten rim light breakdown".to_string(),
            quoted_author: None,
            quoted_text: None,
            article_title: None,
            media_urls: Vec::new(),
            media_thumbnail_urls: Vec::new(),
            attachments: Vec::new(),
            has_video: false,
            video_url: None,
            reply_count: None,
            repost_count: None,
            like_count: None,
            view_count: None,
            original_url: "https://bsky.app/profile/elena.bsky.social/post/3k2abc".to_string(),
            media_fetch_failed: false,
        }),
        photo_exif: Some(PhotoExifMetadata {
            camera_make: Some("Fujifilm".to_string()),
            camera_model: Some("X-T5".to_string()),
            lens_model: Some("XF35mmF1.4 R".to_string()),
            ..PhotoExifMetadata::default()
        }),
        ai_generation: Some(AIGenerationMetadata {
            generator: Some("ComfyUI".to_string()),
            prompt: Some("volumetric chiaroscuro portrait, kodak portra 400".to_string()),
            model_name: Some("flux1-dev".to_string()),
            ..AIGenerationMetadata::default()
        }),
        ..AssetRichMetadata::default()
    });

    db.upsert_assets(&[a1.clone(), a2.clone(), a3.clone()])
        .unwrap();

    // Full pinyin & initials search (including polyphone "重庆" -> chongqing / cq)
    for query in ["haibao", "hb", "chongqing", "cq", "nuandiao", "瑞士"] {
        let hits = db
            .fetch_assets(
                &FilterCriteria {
                    search_query: query.to_string(),
                    ..FilterCriteria::default()
                },
                None,
            )
            .unwrap();
        assert!(
            hits.iter().any(|a| a.id == a1.id),
            "expected query `{query}` to match Chinese asset"
        );
    }

    // GitHub README search
    let gh_hits = db
        .fetch_assets(
            &FilterCriteria {
                search_query: "WebView2".to_string(),
                ..FilterCriteria::default()
            },
            None,
        )
        .unwrap();
    assert_eq!(gh_hits.len(), 1);
    assert_eq!(gh_hits[0].id, a2.id);

    // Social + EXIF + AI prompt search
    for query in ["tungsten", "Fujifilm", "chiaroscuro", "flux1"] {
        let hits = db
            .fetch_assets(
                &FilterCriteria {
                    search_query: query.to_string(),
                    ..FilterCriteria::default()
                },
                None,
            )
            .unwrap();
        assert_eq!(hits.len(), 1, "query `{query}` should match asset 3");
        assert_eq!(hits[0].id, a3.id);
    }

    // CIELAB SQL color search
    let red_hits = db
        .fetch_assets(
            &FilterCriteria {
                selected_color_hex: Some("#DC3B2A".to_string()),
                color_tolerance: 18.0,
                ..FilterCriteria::default()
            },
            None,
        )
        .unwrap();
    assert_eq!(red_hits.len(), 1);
    assert_eq!(red_hits[0].id, a1.id);
}

#[test]
fn all_six_sort_orders_and_filter_criteria_work_accurately() {
    let db = LibraryDatabase::open_in_memory().unwrap();
    let now = Utc::now();

    let mut a = AssetRecord::new("Alpha Landscape", "alpha.png");
    a.created_at = now - Duration::days(10);
    a.rating = 2;
    a.file_size_bytes = 5_000;
    a.pixel_width = 1600;
    a.pixel_height = 900;
    a.pinned_offline = true;

    let mut b = AssetRecord::new("Beta Portrait", "beta.png");
    b.created_at = now - Duration::days(2);
    b.rating = 5;
    b.file_size_bytes = 500;
    b.pixel_width = 800;
    b.pixel_height = 1400;
    b.tags = vec!["featured".to_string()];

    let mut c = AssetRecord::new("Gamma Square", "gamma.mp4");
    c.media_kind = MediaKind::Video;
    c.created_at = now - Duration::hours(1);
    c.rating = 4;
    c.file_size_bytes = 25_000;
    c.pixel_width = 1000;
    c.pixel_height = 1000;

    db.upsert_assets(&[a.clone(), b.clone(), c.clone()])
        .unwrap();

    let newest = db
        .fetch_assets(
            &FilterCriteria {
                sort_by: SortOrder::Newest,
                ..FilterCriteria::default()
            },
            None,
        )
        .unwrap();
    assert_eq!(
        newest.iter().map(|x| x.id).collect::<Vec<_>>(),
        vec![c.id, b.id, a.id]
    );

    let oldest = db
        .fetch_assets(
            &FilterCriteria {
                sort_by: SortOrder::Oldest,
                ..FilterCriteria::default()
            },
            None,
        )
        .unwrap();
    assert_eq!(
        oldest.iter().map(|x| x.id).collect::<Vec<_>>(),
        vec![a.id, b.id, c.id]
    );

    let by_name = db
        .fetch_assets(
            &FilterCriteria {
                sort_by: SortOrder::NameAsc,
                ..FilterCriteria::default()
            },
            None,
        )
        .unwrap();
    assert_eq!(
        by_name.iter().map(|x| x.id).collect::<Vec<_>>(),
        vec![a.id, b.id, c.id]
    );

    let by_rating = db
        .fetch_assets(
            &FilterCriteria {
                sort_by: SortOrder::RatingDesc,
                ..FilterCriteria::default()
            },
            None,
        )
        .unwrap();
    assert_eq!(
        by_rating.iter().map(|x| x.id).collect::<Vec<_>>(),
        vec![b.id, c.id, a.id]
    );

    let by_size = db
        .fetch_assets(
            &FilterCriteria {
                sort_by: SortOrder::FileSizeDesc,
                ..FilterCriteria::default()
            },
            None,
        )
        .unwrap();
    assert_eq!(
        by_size.iter().map(|x| x.id).collect::<Vec<_>>(),
        vec![c.id, a.id, b.id]
    );

    let by_relevance = db
        .fetch_assets(
            &FilterCriteria {
                search_query: "Portrait".to_string(),
                sort_by: SortOrder::Relevance,
                ..FilterCriteria::default()
            },
            None,
        )
        .unwrap();
    assert_eq!(by_relevance.len(), 1);
    assert_eq!(by_relevance[0].id, b.id);

    // Filter by shape, kind, untagged, pinned, min_rating, recent days
    let portrait = db
        .fetch_assets(
            &FilterCriteria {
                shape: Some(AspectShape::Portrait),
                ..FilterCriteria::default()
            },
            None,
        )
        .unwrap();
    assert_eq!(portrait.len(), 1);
    assert_eq!(portrait[0].id, b.id);

    let video_only = db
        .fetch_assets(
            &FilterCriteria {
                kinds: BTreeSet::from([MediaKind::Video]),
                ..FilterCriteria::default()
            },
            None,
        )
        .unwrap();
    assert_eq!(video_only.len(), 1);
    assert_eq!(video_only[0].id, c.id);

    let untagged = db
        .fetch_assets(
            &FilterCriteria {
                only_untagged: true,
                ..FilterCriteria::default()
            },
            None,
        )
        .unwrap();
    assert_eq!(untagged.len(), 2);

    let pinned = db
        .fetch_assets(
            &FilterCriteria {
                only_pinned_offline: true,
                ..FilterCriteria::default()
            },
            None,
        )
        .unwrap();
    assert_eq!(pinned.len(), 1);
    assert_eq!(pinned[0].id, a.id);

    let recent = db
        .fetch_assets(
            &FilterCriteria {
                only_recent_days: Some(3),
                ..FilterCriteria::default()
            },
            None,
        )
        .unwrap();
    assert_eq!(recent.len(), 2);
}

#[test]
fn recursive_folders_cycle_guard_delete_modes_and_smart_folders() {
    let db = LibraryDatabase::open_in_memory().unwrap();

    let root = FolderRecord::new("Design", None);
    let child = FolderRecord::new("Posters", Some(root.id));
    let grandchild = FolderRecord::new("2026", Some(child.id));
    let other = FolderRecord::new("Posters", None);

    for f in [&root, &child, &grandchild, &other] {
        db.record(SyncOperationChange::Folder(f.clone()), true)
            .unwrap();
    }

    let mut a1 = AssetRecord::new("Root Item", "root.png");
    a1.folder_id = Some(root.id);
    let mut a2 = AssetRecord::new("Deep Item", "deep.png");
    a2.folder_id = Some(grandchild.id);
    a2.tags = vec!["poster".to_string(), "swiss".to_string()];
    a2.rating = 5;
    db.save_asset_locally(&a1, true).unwrap();
    db.save_asset_locally(&a2, true).unwrap();

    // Direct vs recursive subfolder query
    let direct = db
        .fetch_assets(
            &FilterCriteria {
                folder_id: Some(root.id),
                include_subfolders: false,
                ..FilterCriteria::default()
            },
            None,
        )
        .unwrap();
    assert_eq!(direct.len(), 1);
    assert_eq!(direct[0].id, a1.id);

    let recursive = db
        .fetch_assets(
            &FilterCriteria {
                folder_id: Some(root.id),
                include_subfolders: true,
                ..FilterCriteria::default()
            },
            None,
        )
        .unwrap();
    assert_eq!(recursive.len(), 2);

    // Cycle guard: cannot move `root` under its descendant `grandchild`
    assert!(db.move_folder(root.id, Some(grandchild.id), None).is_err());

    // Moving `child` ("Posters") to root deduplicates against `other` ("Posters")
    let updated = db.move_folder(child.id, None, Some(0)).unwrap();
    let moved_child = updated.iter().find(|f| f.id == child.id).unwrap();
    assert_eq!(moved_child.parent_id, None);
    assert_eq!(moved_child.name, "Posters (2)");

    // Delete `child` with `trash_contents = true` trashes subtree asset `a2`
    db.delete_folder(child.id, true).unwrap();
    assert!(db.folder(child.id).unwrap().is_none());
    assert!(db.folder(grandchild.id).unwrap().is_none());
    let trashed_a2 = db.asset(a2.id).unwrap().unwrap();
    assert!(trashed_a2.is_trashed);

    // SmartFolderRule persistence & evaluation
    let smart = SmartFolderRecord::new(
        "5-Star Swiss Posters",
        SmartFolderRule {
            match_mode: SmartFolderMatchMode::All,
            tags: vec!["poster".to_string(), "swiss".to_string()],
            min_rating: 5,
            ..SmartFolderRule::default()
        },
    );
    let saved_list = db.save_smart_folder(smart.clone()).unwrap();
    assert_eq!(saved_list.len(), 1);
    assert!(smart.rule.matches(&a2));
    assert!(!smart.rule.matches(&a1));
    assert!(db.delete_smart_folder(smart.id).unwrap().is_empty());
}

#[test]
fn vectors_cosine_search_quick_jump_and_local_open_timestamp() {
    let db = LibraryDatabase::open_in_memory().unwrap();

    let a1 = db
        .save_asset_locally(&AssetRecord::new("Cobalt Interface", "cobalt.png"), true)
        .unwrap();
    let a2 = db
        .save_asset_locally(&AssetRecord::new("Warm Ceramic", "ceramic.png"), true)
        .unwrap();

    // Local `mark_asset_opened` MUST NOT enqueue any sync_ops
    let ops_before = db.pending_op_count().unwrap();
    let opened = db.mark_asset_opened(a1.id).unwrap().unwrap();
    assert!(opened.last_opened_at.is_some());
    assert_eq!(db.pending_op_count().unwrap(), ops_before);

    // Float16 & Float32 vector round-trip and cosine ranking
    let v1 = AssetVector {
        feature_print: Some(vec![1, 2, 3, 4]),
        embedding: Some(vec![1.0, 0.0, 0.0, 0.0]),
        embedding_model: Some("text-embedding-3-small".to_string()),
        precision: EmbeddingPrecision::Float16,
    };
    let v2 = AssetVector {
        feature_print: None,
        embedding: Some(vec![0.0, 1.0, 0.0, 0.0]),
        embedding_model: Some("text-embedding-3-small".to_string()),
        precision: EmbeddingPrecision::Float32,
    };
    db.save_vector(a1.id, &v1).unwrap();
    db.save_vector(a2.id, &v2).unwrap();

    let loaded_v1 = db.vector(a1.id).unwrap().unwrap();
    assert_eq!(loaded_v1.precision, EmbeddingPrecision::Float16);
    assert_eq!(
        loaded_v1.feature_print.as_deref(),
        Some(&[1u8, 2, 3, 4][..])
    );

    let matches = db
        .search_by_embedding(&[0.98, 0.15, 0.0, 0.0], 5, 0.5)
        .unwrap();
    assert_eq!(matches.len(), 1);
    assert_eq!(matches[0].0, a1.id);
    assert!(matches[0].1 > 0.95);

    // QuickJump across folders, boards, tags, and assets
    let mut board = MoodboardDocument::new("Cobalt Moodboard");
    board.pinned_offline = true;
    board.nodes.push(BoardNode {
        id: Uuid::new_v4(),
        kind: BoardNodeKind::AssetRef {
            asset_id: a1.id,
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
    db.save_board_locally(&board).unwrap();

    // Pinned board protects its referenced asset!
    let protected = db.protected_asset_ids().unwrap();
    assert!(protected.contains(&a1.id));
    assert!(!protected.contains(&a2.id));

    let qj = db.quick_jump("Cobalt", 10).unwrap();
    assert!(qj.iter().any(|m| m.kind == QuickJumpKind::Moodboard));
    assert!(qj.iter().any(|m| m.kind == QuickJumpKind::Asset));
}
