//! Offline lossless Moodboard -> Figma / FigJam Bridge exporter (`.charkleboard` ZIP).
//!
//! 1:1 port of `Sources/CharkleCanvas/FigmaBridgeExporter.swift` strictly compliant with
//! `Resources/FigmaPlugin/code.js` validation:
//! - `board.json` + `migration-report.json`
//! - `format: "charkle-figma-bridge"`, `version: 1`
//! - High-res images split cleanly along exact `4096x4096` grid boundaries into lossless
//!   `tiles/*.png` with lowercase 64-char hex SHA-256 checksums
//! - Original GIFs preserved verbatim in `originals/*.gif` for native FigJam `figma.createGif`

use std::collections::{HashMap, HashSet};
use std::fs::File;
use std::io::{Cursor, Write};
use std::path::{Path, PathBuf};

use chrono::Utc;
use image::{DynamicImage, ImageFormat};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use uuid::Uuid;
use zip::write::SimpleFileOptions;
use zip::{CompressionMethod, ZipWriter};

use crate::error::{CoreError, CoreResult};
use crate::export::board_image::{
    group_tint_hex, is_light_hex, note_style_hex, resolve_frames, MoodboardExportOptions,
};
use crate::media::MediaPipeline;
use crate::models::core::{AssetRecord, LabColor, MediaKind};
use crate::models::media::ThumbnailTier;
use crate::models::moodboard::{BoardNodeKind, BoardRect, MoodboardDocument, NormalizedCropRect};
use crate::wire::swift_codec::format_swift_uuid;

const TILE_LIMIT: u32 = 4096;

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct FigmaBridgeExportReport {
    pub object_count: usize,
    pub image_count: usize,
    pub note_count: usize,
    pub group_count: usize,
    pub palette_count: usize,
    pub connector_count: usize,
    pub stroke_count: usize,
    pub review_count: usize,
    pub bundle_path: String,
}

pub struct FigmaBridgeExporter;

impl FigmaBridgeExporter {
    /// Exports a `MoodboardDocument` to an offline lossless `.charkleboard` ZIP archive.
    pub fn export_bundle(
        document: &MoodboardDocument,
        assets_by_id: &HashMap<Uuid, AssetRecord>,
        media: &MediaPipeline,
        options: &MoodboardExportOptions,
        destination_path: &Path,
    ) -> CoreResult<FigmaBridgeExportReport> {
        let resolved_frames = resolve_frames(document, assets_by_id, options.container_width);

        let mut ordered_nodes = document.nodes.clone();
        ordered_nodes.sort_by(|lhs, rhs| {
            let l_grp = matches!(lhs.kind, BoardNodeKind::GroupFrame { .. });
            let r_grp = matches!(rhs.kind, BoardNodeKind::GroupFrame { .. });
            r_grp
                .cmp(&l_grp)
                .then_with(|| lhs.z_index.cmp(&rhs.z_index))
                .then_with(|| lhs.editorial_order.cmp(&rhs.editorial_order))
        });

        let mut objects: Vec<Value> = Vec::new();
        let mut warnings: Vec<Value> = Vec::new();
        let mut originals: Vec<Value> = Vec::new();
        let mut zip_entries: HashMap<String, Vec<u8>> = HashMap::new();
        let mut archived_originals: HashMap<Uuid, (String, String, bool)> = HashMap::new();
        let mut cached_tile_payloads: HashMap<String, Value> = HashMap::new();

        let mut image_count = 0usize;
        let mut note_count = 0usize;
        let mut group_count = 0usize;
        let mut palette_count = 0usize;

        // Optional top Board Palette Strip
        if options.include_palette_strip && !document.extracted_palette.is_empty() {
            let min_x = resolved_frames
                .values()
                .map(|r| r.min_x())
                .fold(f64::INFINITY, f64::min);
            let min_y = resolved_frames
                .values()
                .map(|r| r.min_y())
                .fold(f64::INFINITY, f64::min);
            let max_x = resolved_frames
                .values()
                .map(|r| r.max_x())
                .fold(f64::NEG_INFINITY, f64::max);
            let origin_x = if min_x.is_finite() { min_x } else { 0.0 };
            let origin_y = if min_y.is_finite() { min_y } else { 0.0 };
            let span_x = if max_x.is_finite() {
                max_x - origin_x
            } else {
                420.0
            };
            let strip_w = span_x.clamp(320.0, 560.0);
            let strip_h = 54.0;

            let swatches: Vec<Value> = document
                .extracted_palette
                .iter()
                .take(7)
                .map(|s| {
                    let hex = s.hex.to_uppercase();
                    json!({ "hex": hex, "isLight": is_light_hex(&hex) })
                })
                .collect();

            objects.push(json!({
                "id": "board-palette-header",
                "kind": "paletteStrip",
                "name": "板内色卡",
                "locked": false,
                "geometry": geometry_json(BoardRect::new(origin_x, origin_y - strip_h - 24.0, strip_w, strip_h), 0.0, false, false),
                "palette": { "swatches": swatches },
                "warnings": []
            }));
            palette_count += 1;
        }

        for node in &ordered_nodes {
            let Some(&frame) = resolved_frames.get(&node.id) else {
                continue;
            };
            if !frame.x.is_finite()
                || !frame.y.is_finite()
                || !frame.width.is_finite()
                || !frame.height.is_finite()
                || frame.width <= 0.0
                || frame.height <= 0.0
            {
                continue;
            }
            let node_id_str = format_swift_uuid(&node.id);
            let geom = geometry_json(
                frame,
                if node.rotation_degrees.is_finite() {
                    node.rotation_degrees
                } else {
                    0.0
                },
                node.flip_horizontal,
                node.flip_vertical,
            );

            match &node.kind {
                BoardNodeKind::AssetRef { asset_id, crop, .. } => {
                    let asset = assets_by_id.get(asset_id);
                    let display_name = asset
                        .map(|a| a.title.clone())
                        .unwrap_or_else(|| "素材".to_string());
                    let mut item_warnings: Vec<String> = Vec::new();

                    let original_path = asset.and_then(|a| media.cached_original(a));
                    let fallback_preview = if original_path.is_none() {
                        media
                            .thumbnail_url(*asset_id, ThumbnailTier::Preview1400)
                            .or_else(|| media.thumbnail_url(*asset_id, ThumbnailTier::Grid520))
                    } else {
                        None
                    };

                    let Some(source_path) = original_path.as_ref().or(fallback_preview.as_ref())
                    else {
                        item_warnings
                            .push("素材原图与预览图均未缓存在本地，无法导入像素".to_string());
                        warnings.push(json!({ "id": node_id_str, "name": display_name, "issues": item_warnings }));
                        objects.push(json!({
                            "id": node_id_str,
                            "kind": "unsupported",
                            "name": display_name,
                            "locked": node.is_locked,
                            "geometry": geom,
                            "warnings": item_warnings
                        }));
                        continue;
                    };

                    if original_path.is_none() {
                        item_warnings.push("原文件未缓存在本地，已使用高清预览图导出".to_string());
                    }

                    let file_data = match std::fs::read(source_path) {
                        Ok(d) => d,
                        Err(err) => {
                            item_warnings.push(format!("读取素材文件失败：{err}"));
                            warnings.push(json!({ "id": node_id_str, "name": display_name, "issues": item_warnings }));
                            objects.push(json!({
                                "id": node_id_str,
                                "kind": "unsupported",
                                "name": display_name,
                                "locked": node.is_locked,
                                "geometry": geom,
                                "warnings": item_warnings
                            }));
                            continue;
                        }
                    };

                    let asset_uuid_str = format_swift_uuid(asset_id);
                    let archived_info = if let Some(existing) = archived_originals.get(asset_id) {
                        existing.clone()
                    } else {
                        let raw_ext = asset
                            .and_then(|a| Path::new(&a.file_name).extension())
                            .or_else(|| source_path.extension())
                            .and_then(|e| e.to_str())
                            .unwrap_or("")
                            .to_ascii_lowercase();
                        let safe_ext: String = raw_ext
                            .chars()
                            .filter(|c| c.is_ascii_alphanumeric())
                            .take(12)
                            .collect();
                        let file_name = if safe_ext.is_empty() {
                            asset_uuid_str.clone()
                        } else {
                            format!("{asset_uuid_str}.{safe_ext}")
                        };
                        let rel_path = format!("originals/{file_name}");
                        let digest = sha256_hex(&file_data);
                        let is_gif = safe_ext == "gif"
                            || asset.is_some_and(|a| a.media_kind == MediaKind::AnimatedImage);
                        originals.push(json!({
                            "id": asset_uuid_str,
                            "name": asset.map(|a| a.file_name.as_str()).unwrap_or(&file_name),
                            "file": rel_path,
                            "sha256": digest,
                            "bytes": file_data.len()
                        }));
                        zip_entries.insert(rel_path.clone(), file_data.clone());
                        let entry = (rel_path, digest, is_gif);
                        archived_originals.insert(*asset_id, entry.clone());
                        entry
                    };

                    let mut decoded = image::load_from_memory(&file_data).ok();
                    let mut is_animated_gif = archived_info.2 && is_multiframe_gif(&file_data);
                    if decoded.is_none() {
                        let thumb_path = media
                            .thumbnail_url(*asset_id, ThumbnailTier::Preview1400)
                            .or_else(|| media.thumbnail_url(*asset_id, ThumbnailTier::Grid520));
                        if let Some(tp) = thumb_path {
                            if let Ok(img) = image::open(&tp) {
                                decoded = Some(img);
                                item_warnings.push(
                                    "非静态图片素材已以静态预览导出，原始文件已归档在 originals/"
                                        .to_string(),
                                );
                                is_animated_gif = false;
                            }
                        }
                    }

                    let Some(mut img) = decoded.filter(|d| d.width() >= 1 && d.height() >= 1)
                    else {
                        item_warnings.push(
                            "无法解码该素材的画面像素，原始文件已归档在 originals/".to_string(),
                        );
                        warnings.push(json!({ "id": node_id_str, "name": display_name, "issues": item_warnings }));
                        objects.push(json!({
                            "id": node_id_str,
                            "kind": "unsupported",
                            "name": display_name,
                            "locked": node.is_locked,
                            "geometry": geom,
                            "warnings": item_warnings
                        }));
                        continue;
                    };

                    let crop_key = if let Some(c) = crop {
                        let iw = img.width() as f64;
                        let ih = img.height() as f64;
                        if iw >= 2.0
                            && ih >= 2.0
                            && *c != NormalizedCropRect::FULL
                            && c.x.is_finite()
                            && c.y.is_finite()
                            && c.width.is_finite()
                            && c.height.is_finite()
                            && c.width > 0.05
                            && c.height > 0.05
                        {
                            let clamped = c.clamped();
                            let max_rx = (iw - 1.0).max(0.0);
                            let max_ry = (ih - 1.0).max(0.0);
                            let rx = (clamped.x * iw).floor().clamp(0.0, max_rx) as u32;
                            let ry = (clamped.y * ih).floor().clamp(0.0, max_ry) as u32;
                            let avail_w = (iw - rx as f64).max(1.0);
                            let avail_h = (ih - ry as f64).max(1.0);
                            let rw = (clamped.width * iw).round().clamp(1.0, avail_w) as u32;
                            let rh = (clamped.height * ih).round().clamp(1.0, avail_h) as u32;
                            if rw >= 1
                                && rh >= 1
                                && rx.saturating_add(rw) <= img.width()
                                && ry.saturating_add(rh) <= img.height()
                            {
                                img = img.crop_imm(rx, ry, rw, rh);
                            }
                            format!(
                                "{:.3}-{:.3}-{:.3}-{:.3}",
                                clamped.x, clamped.y, clamped.width, clamped.height
                            )
                        } else {
                            "full".to_string()
                        }
                    } else {
                        "full".to_string()
                    };

                    let cache_key = format!("{asset_uuid_str}-{crop_key}");
                    let image_payload = if let Some(cached) = cached_tile_payloads.get(&cache_key) {
                        cached.clone()
                    } else {
                        let prefix = if crop_key == "full" {
                            asset_uuid_str.clone()
                        } else {
                            let digest = sha256_hex(crop_key.as_bytes());
                            let hash_suffix = digest.get(..6).unwrap_or("crop");
                            format!("{asset_uuid_str}-C{hash_suffix}")
                        };
                        let tiles = build_lossless_tiles(&img, &prefix, &mut zip_entries)?;
                        let mut desc = json!({
                            "pixelWidth": img.width(),
                            "pixelHeight": img.height(),
                            "tiles": tiles,
                            "animated": is_animated_gif
                        });
                        if is_animated_gif
                            && crop_key == "full"
                            && archived_info.0.to_ascii_lowercase().ends_with(".gif")
                        {
                            desc["animation"] = json!({
                                "file": archived_info.0,
                                "sha256": archived_info.1
                            });
                            item_warnings.push(
                                "动画 GIF 在 Figma Design 中以静态首帧导入，原始 GIF 已归档"
                                    .to_string(),
                            );
                        }
                        cached_tile_payloads.insert(cache_key, desc.clone());
                        desc
                    };

                    if !item_warnings.is_empty() {
                        warnings.push(json!({ "id": node_id_str, "name": display_name, "issues": item_warnings }));
                    }
                    objects.push(json!({
                        "id": node_id_str,
                        "kind": "image",
                        "name": display_name,
                        "cornerRadius": 12,
                        "locked": node.is_locked,
                        "geometry": geom,
                        "image": image_payload,
                        "warnings": item_warnings
                    }));
                    image_count += 1;
                }

                BoardNodeKind::Note {
                    title,
                    text,
                    style,
                    font_size,
                } => {
                    let (bg_hex, fg_hex, border_hex) = note_style_hex(*style);
                    let note_name = title
                        .as_deref()
                        .map(str::trim)
                        .filter(|s| !s.is_empty())
                        .map(ToOwned::to_owned)
                        .unwrap_or_else(|| {
                            let snippet: String = text.chars().take(24).collect();
                            if snippet.is_empty() {
                                "灵感便签".to_string()
                            } else {
                                snippet
                            }
                        });
                    objects.push(json!({
                        "id": node_id_str,
                        "kind": "note",
                        "name": note_name,
                        "locked": node.is_locked,
                        "geometry": geom,
                        "note": {
                            "title": title.as_deref().unwrap_or(""),
                            "text": text,
                            "style": serde_json::to_value(style).unwrap_or(json!("paper")),
                            "fontSize": font_size,
                            "backgroundHex": bg_hex,
                            "foregroundHex": fg_hex,
                            "borderHex": border_hex
                        },
                        "warnings": []
                    }));
                    note_count += 1;
                }

                BoardNodeKind::GroupFrame { title, tint } => {
                    objects.push(json!({
                        "id": node_id_str,
                        "kind": "groupFrame",
                        "name": if title.is_empty() { "分组区域" } else { title.as_str() },
                        "locked": node.is_locked,
                        "geometry": geom,
                        "group": {
                            "title": title,
                            "tint": serde_json::to_value(tint).unwrap_or(json!("neutral")),
                            "accentHex": group_tint_hex(*tint)
                        },
                        "warnings": []
                    }));
                    group_count += 1;
                }

                BoardNodeKind::PaletteStrip {
                    colors,
                    auto_sync_with_board,
                } => {
                    let active: Vec<LabColor> =
                        if *auto_sync_with_board && !document.extracted_palette.is_empty() {
                            document.extracted_palette.clone()
                        } else if !colors.is_empty() {
                            colors.clone()
                        } else {
                            vec![LabColor {
                                hex: "#8B95A1".to_string(),
                                l: 61.0,
                                a: -2.0,
                                b: -7.0,
                                proportion: 1.0,
                            }]
                        };
                    let swatches: Vec<Value> = active
                        .iter()
                        .map(|s| {
                            let hex = s.hex.to_uppercase();
                            json!({ "hex": hex, "isLight": is_light_hex(&hex) })
                        })
                        .collect();
                    objects.push(json!({
                        "id": node_id_str,
                        "kind": "paletteStrip",
                        "name": "色卡条",
                        "locked": node.is_locked,
                        "geometry": geom,
                        "palette": { "swatches": swatches },
                        "warnings": []
                    }));
                    palette_count += 1;
                }
            }
        }

        if objects.is_empty() {
            return Err(CoreError::InvalidOperation(
                "当前情绪板里没有可导出的对象".to_string(),
            ));
        }

        let mut connector_jsons: Vec<Value> = Vec::new();
        let mut stroke_jsons: Vec<Value> = Vec::new();
        if options.include_annotations {
            let exported_ids: HashSet<String> = objects
                .iter()
                .filter_map(|o| o.get("id").and_then(Value::as_str).map(ToOwned::to_owned))
                .collect();
            for conn in &document.connectors {
                let from_id = format_swift_uuid(&conn.from_node_id);
                let to_id = format_swift_uuid(&conn.to_node_id);
                if !exported_ids.contains(&from_id) || !exported_ids.contains(&to_id) {
                    continue;
                }
                connector_jsons.push(json!({
                    "id": format_swift_uuid(&conn.id),
                    "fromNodeID": from_id,
                    "fromAnchor": serde_json::to_value(conn.from_anchor).unwrap_or(json!("auto")),
                    "toNodeID": to_id,
                    "toAnchor": serde_json::to_value(conn.to_anchor).unwrap_or(json!("auto")),
                    "style": serde_json::to_value(conn.style).unwrap_or(json!("curved")),
                    "colorHex": conn.color_hex,
                    "dashed": conn.dashed,
                    "label": conn.label.as_deref().unwrap_or("")
                }));
            }
            for stroke in &document.ink_strokes {
                if stroke.points.len() < 2 {
                    continue;
                }
                stroke_jsons.push(json!({
                    "id": format_swift_uuid(&stroke.id),
                    "points": stroke.points.iter().map(|p| json!({ "x": p.x, "y": p.y })).collect::<Vec<_>>(),
                    "colorHex": stroke.color_hex,
                    "lineWidth": stroke.line_width,
                    "opacity": stroke.opacity
                }));
            }
        }

        let report_json = json!({
            "objectCount": objects.len(),
            "imageCount": image_count,
            "noteCount": note_count,
            "groupCount": group_count,
            "paletteCount": palette_count,
            "connectorCount": connector_jsons.len(),
            "strokeCount": stroke_jsons.len(),
            "reviewCount": warnings.len(),
            "warnings": warnings
        });

        let board_json = json!({
            "format": "charkle-figma-bridge",
            "version": 1,
            "boardId": format_swift_uuid(&document.id),
            "name": document.title,
            "subtitle": document.subtitle,
            "mode": if document.mode.is_auto_editorial() { "autoEditorial" } else { "freeform" },
            "darkAppearance": options.dark_appearance,
            "exportedAt": Utc::now().to_rfc3339(),
            "sourceOS": "Windows",
            "objects": objects,
            "connectors": connector_jsons,
            "inkStrokes": stroke_jsons,
            "originals": originals,
            "report": report_json
        });

        let board_bytes = serde_json::to_vec_pretty(&board_json)
            .map_err(|e| CoreError::Media(format!("Serialize board.json failed: {e}")))?;
        let report_bytes = serde_json::to_vec_pretty(&report_json).map_err(|e| {
            CoreError::Media(format!("Serialize migration-report.json failed: {e}"))
        })?;

        if let Some(parent) = destination_path.parent() {
            std::fs::create_dir_all(parent)?;
        }
        let tmp_path = PathBuf::from(format!("{}.tmp", destination_path.display()));
        let write_result: CoreResult<()> = (|| {
            let file = File::create(&tmp_path)?;
            let mut zip = ZipWriter::new(file);
            let deflate_opts =
                SimpleFileOptions::default().compression_method(CompressionMethod::Deflated);
            let stored_opts =
                SimpleFileOptions::default().compression_method(CompressionMethod::Stored);

            zip.start_file("board.json", deflate_opts)
                .map_err(|e| CoreError::Media(format!("ZIP start board.json failed: {e}")))?;
            zip.write_all(&board_bytes)?;

            zip.start_file("migration-report.json", deflate_opts)
                .map_err(|e| CoreError::Media(format!("ZIP start report failed: {e}")))?;
            zip.write_all(&report_bytes)?;

            let mut sorted_keys: Vec<String> = zip_entries.keys().cloned().collect();
            sorted_keys.sort();
            for entry_path in sorted_keys {
                if let Some(bytes) = zip_entries.get(&entry_path) {
                    zip.start_file(&entry_path, stored_opts).map_err(|e| {
                        CoreError::Media(format!("ZIP start {entry_path} failed: {e}"))
                    })?;
                    zip.write_all(bytes)?;
                }
            }
            zip.finish()
                .map_err(|e| CoreError::Media(format!("ZIP finalize failed: {e}")))?;
            Ok(())
        })();
        if let Err(err) = write_result {
            let _ = std::fs::remove_file(&tmp_path);
            return Err(err);
        }
        if destination_path.exists() {
            let _ = std::fs::remove_file(destination_path);
        }
        if let Err(err) = std::fs::rename(&tmp_path, destination_path) {
            let _ = std::fs::remove_file(&tmp_path);
            return Err(err.into());
        }

        Ok(FigmaBridgeExportReport {
            object_count: objects.len(),
            image_count,
            note_count,
            group_count,
            palette_count,
            connector_count: connector_jsons.len(),
            stroke_count: stroke_jsons.len(),
            review_count: warnings.len(),
            bundle_path: destination_path.to_string_lossy().into_owned(),
        })
    }
}

fn build_lossless_tiles(
    img: &DynamicImage,
    prefix: &str,
    zip_entries: &mut HashMap<String, Vec<u8>>,
) -> CoreResult<Vec<Value>> {
    let w_total = img.width();
    let h_total = img.height();
    let mut tiles = Vec::new();
    let mut y = 0u32;
    while y < h_total {
        let h = TILE_LIMIT.min(h_total - y);
        let mut x = 0u32;
        while x < w_total {
            let w = TILE_LIMIT.min(w_total - x);
            let sub = img.crop_imm(x, y, w, h);
            let mut png_bytes = Vec::new();
            sub.write_to(&mut Cursor::new(&mut png_bytes), ImageFormat::Png)
                .map_err(|e| CoreError::Media(format!("PNG tile encode failed: {e}")))?;
            let rel_path = format!("tiles/{prefix}-{x}-{y}.png");
            let digest = sha256_hex(&png_bytes);
            zip_entries.insert(rel_path.clone(), png_bytes);
            tiles.push(json!({
                "file": rel_path,
                "x": x,
                "y": y,
                "width": w,
                "height": h,
                "sha256": digest
            }));
            x += TILE_LIMIT;
        }
        y += TILE_LIMIT;
    }
    Ok(tiles)
}

fn geometry_json(rect: BoardRect, angle: f64, flip_x: bool, flip_y: bool) -> Value {
    let finite = |v: f64, fb: f64| if v.is_finite() { v } else { fb };
    json!({
        "x": finite(rect.x, 0.0),
        "y": finite(rect.y, 0.0),
        "width": finite(rect.width, 1.0).max(1.0),
        "height": finite(rect.height, 1.0).max(1.0),
        "angle": finite(angle, 0.0),
        "flipX": flip_x,
        "flipY": flip_y
    })
}

fn sha256_hex(bytes: &[u8]) -> String {
    hex::encode(Sha256::digest(bytes))
}

/// Lightweight GIF multi-frame detector (checks GIF87a/GIF89a header and >= 2 Graphic Control
/// Extension / Image Descriptor blocks).
fn is_multiframe_gif(data: &[u8]) -> bool {
    if data.len() < 14 || (!data.starts_with(b"GIF89a") && !data.starts_with(b"GIF87a")) {
        return false;
    }
    let mut frames = 0usize;
    let mut i = 13usize;
    // Skip global color table if present
    let packed = data[10];
    if (packed & 0x80) != 0 {
        let gct_size = 3 * (1usize << ((packed & 0x07) + 1));
        i = i.saturating_add(gct_size);
    }
    while i < data.len() {
        match data[i] {
            0x2C => {
                // Image Descriptor
                frames += 1;
                if frames >= 2 {
                    return true;
                }
                i = i.saturating_add(10);
                if i > data.len() {
                    break;
                }
                let l_packed = data[i - 1];
                if (l_packed & 0x80) != 0 {
                    let lct = 3 * (1usize << ((l_packed & 0x07) + 1));
                    i = i.saturating_add(lct);
                }
                i = i.saturating_add(1); // LZW min code size
                while i < data.len() && data[i] != 0 {
                    i = i.saturating_add(1 + data[i] as usize);
                }
                i = i.saturating_add(1);
            }
            0x21 => {
                // Extension block
                i = i.saturating_add(2);
                while i < data.len() && data[i] != 0 {
                    i = i.saturating_add(1 + data[i] as usize);
                }
                i = i.saturating_add(1);
            }
            0x3B => break, // Trailer
            _ => i = i.saturating_add(1),
        }
    }
    frames >= 2
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::export::BoardImageExporter;
    use crate::models::core::LabColor;
    use crate::models::moodboard::{
        BoardConnector, BoardLayoutMode, BoardNode, ConnectorAnchor, ConnectorStyle, GroupTint,
        InkStroke, InkStrokePoint, NoteStyle,
    };
    use image::{Rgba, RgbaImage};
    use std::io::Read;
    use tempfile::tempdir;
    use zip::ZipArchive;

    #[test]
    fn exports_5k_tiled_charkleboard_zip_and_2x_png_passing_figma_schema_rules() {
        let dir = tempdir().unwrap();
        let media = MediaPipeline::new(dir.path()).unwrap();

        // Create a real >4096px wide (5000 x 120) image to verify exact 4096 grid tiling
        let big_img = RgbaImage::from_pixel(5000, 120, Rgba([98, 168, 229, 255]));
        let src_path = dir.path().join("wide5k.png");
        DynamicImage::ImageRgba8(big_img)
            .save_with_format(&src_path, ImageFormat::Png)
            .unwrap();

        let asset_id = Uuid::new_v4();
        let mut asset = AssetRecord::new("5K 超清参考图", "wide5k.png");
        asset.id = asset_id;
        asset.media_kind = MediaKind::Image;
        asset.mime_type = "image/png".to_string();
        asset.content_hash = "h1".to_string();
        asset.pixel_width = 5000;
        asset.pixel_height = 120;
        asset.dominant_colors = vec![LabColor {
            hex: "#62A8E5".to_string(),
            l: 67.0,
            a: -8.0,
            b: -36.0,
            proportion: 1.0,
        }];
        media.install_original(&src_path, &asset, false).unwrap();

        let mut assets = HashMap::new();
        assets.insert(asset_id, asset);

        let img_node_id = Uuid::new_v4();
        let note_node_id = Uuid::new_v4();
        let grp_node_id = Uuid::new_v4();
        let pal_node_id = Uuid::new_v4();

        let mut doc = MoodboardDocument::new("晴空下的夏日片刻");
        doc.mode = BoardLayoutMode::Freeform;
        doc.extracted_palette = vec![
            LabColor {
                hex: "#62A8E5".to_string(),
                l: 67.0,
                a: -8.0,
                b: -36.0,
                proportion: 0.6,
            },
            LabColor {
                hex: "#F3EAD8".to_string(),
                l: 92.0,
                a: 1.0,
                b: 9.0,
                proportion: 0.4,
            },
        ];
        doc.nodes = vec![
            BoardNode {
                id: grp_node_id,
                kind: BoardNodeKind::GroupFrame {
                    title: "构图参考区".to_string(),
                    tint: GroupTint::Sand,
                },
                frame: BoardRect::new(40.0, 40.0, 900.0, 600.0),
                z_index: 0,
                rotation_degrees: 0.0,
                flip_horizontal: false,
                flip_vertical: false,
                is_locked: false,
                editorial_order: 0,
                updated_at: Utc::now(),
            },
            BoardNode {
                id: img_node_id,
                kind: BoardNodeKind::AssetRef {
                    asset_id,
                    crop: None,
                    weight: 2,
                    autoplay_loop: false,
                },
                frame: BoardRect::new(80.0, 120.0, 420.0, 260.0),
                z_index: 1,
                rotation_degrees: 0.0,
                flip_horizontal: false,
                flip_vertical: false,
                is_locked: false,
                editorial_order: 1,
                updated_at: Utc::now(),
            },
            BoardNode {
                id: note_node_id,
                kind: BoardNodeKind::Note {
                    title: Some("光影思路".to_string()),
                    text: "保持高明度日光与通透空气感".to_string(),
                    style: NoteStyle::Warm,
                    font_size: 14.0,
                },
                frame: BoardRect::new(560.0, 140.0, 260.0, 180.0),
                z_index: 2,
                rotation_degrees: 0.0,
                flip_horizontal: false,
                flip_vertical: false,
                is_locked: false,
                editorial_order: 2,
                updated_at: Utc::now(),
            },
            BoardNode {
                id: pal_node_id,
                kind: BoardNodeKind::PaletteStrip {
                    colors: doc.extracted_palette.clone(),
                    auto_sync_with_board: true,
                },
                frame: BoardRect::new(80.0, 460.0, 420.0, 72.0),
                z_index: 3,
                rotation_degrees: 0.0,
                flip_horizontal: false,
                flip_vertical: false,
                is_locked: false,
                editorial_order: 3,
                updated_at: Utc::now(),
            },
        ];
        doc.connectors = vec![BoardConnector {
            id: Uuid::new_v4(),
            from_node_id: img_node_id,
            from_anchor: ConnectorAnchor::Trailing,
            from_normalized_point: None,
            to_node_id: note_node_id,
            to_anchor: ConnectorAnchor::Leading,
            to_normalized_point: None,
            label: Some("色调呼应".to_string()),
            color_hex: "#5C6B73".to_string(),
            style: ConnectorStyle::Curved,
            dashed: false,
            updated_at: Utc::now(),
        }];
        doc.ink_strokes = vec![InkStroke {
            id: Uuid::new_v4(),
            points: vec![
                InkStrokePoint {
                    x: 120.0,
                    y: 200.0,
                    pressure: 0.5,
                },
                InkStrokePoint {
                    x: 240.0,
                    y: 260.0,
                    pressure: 0.5,
                },
            ],
            color_hex: "#D95D48".to_string(),
            line_width: 3.5,
            opacity: 0.92,
            z_index: 1000,
            created_at: Utc::now(),
        }];

        // 1. High-DPI 2x PNG & JPEG export
        let png_bytes = BoardImageExporter::render_bytes(
            &doc,
            &assets,
            &media,
            &MoodboardExportOptions::default(),
        )
        .unwrap();
        assert!(png_bytes.starts_with(b"\x89PNG"));
        let jpg_opts = MoodboardExportOptions {
            scale: 1.0,
            format: crate::export::BoardImageFormat::Jpeg,
            ..Default::default()
        };
        let jpg_bytes = BoardImageExporter::render_bytes(&doc, &assets, &media, &jpg_opts).unwrap();
        assert_eq!(&jpg_bytes[0..2], &[0xFF, 0xD8]);

        // 2. Offline lossless .charkleboard ZIP export
        let zip_path = dir.path().join("summer.charkleboard");
        let report = FigmaBridgeExporter::export_bundle(
            &doc,
            &assets,
            &media,
            &MoodboardExportOptions::default(),
            &zip_path,
        )
        .unwrap();
        assert_eq!(report.image_count, 1);
        assert_eq!(report.note_count, 1);
        assert_eq!(report.group_count, 1);
        assert_eq!(report.connector_count, 1);
        assert_eq!(report.stroke_count, 1);

        // Verify ZIP entries & 4096 tile grid + SHA-256 checksums
        let mut archive = ZipArchive::new(File::open(&zip_path).unwrap()).unwrap();
        let mut board_str = String::new();
        archive
            .by_name("board.json")
            .unwrap()
            .read_to_string(&mut board_str)
            .unwrap();
        let board_val: Value = serde_json::from_str(&board_str).unwrap();
        assert_eq!(board_val["format"], "charkle-figma-bridge");
        assert_eq!(board_val["version"], 1);

        let img_obj = board_val["objects"]
            .as_array()
            .unwrap()
            .iter()
            .find(|o| o["kind"] == "image")
            .unwrap();
        let tiles = img_obj["image"]["tiles"].as_array().unwrap();
        assert_eq!(tiles.len(), 2); // 5000px splits into [0..4096] + [4096..5000]
        assert_eq!(tiles[0]["x"], 0);
        assert_eq!(tiles[0]["width"], 4096);
        assert_eq!(tiles[1]["x"], 4096);
        assert_eq!(tiles[1]["width"], 904);
        for t in tiles {
            let file = t["file"].as_str().unwrap();
            let expected_sha = t["sha256"].as_str().unwrap();
            let mut tile_bytes = Vec::new();
            archive
                .by_name(file)
                .unwrap()
                .read_to_end(&mut tile_bytes)
                .unwrap();
            assert_eq!(sha256_hex(&tile_bytes), expected_sha);
            assert!(tile_bytes.starts_with(b"\x89PNG"));
        }

        // Optional dump hook for cross-language FigmaPlugin/code.js end-to-end verification
        if let Ok(dump_path) = std::env::var("CHARKLE_VERIFY_FIGMA_ZIP") {
            std::fs::copy(&zip_path, &dump_path).expect("copy test .charkleboard for JS check");
        }
    }

    #[test]
    fn exports_animated_gif_and_roundtrips_swift_wire_moodboard_json() {
        let dir = tempdir().unwrap();
        let media = MediaPipeline::new(dir.path()).unwrap();

        // Build a real 2-frame animated GIF on disk
        let src_gif_path = dir.path().join("loop.gif");
        {
            use image::codecs::gif::{GifEncoder, Repeat};
            use image::Frame;
            let file = File::create(&src_gif_path).unwrap();
            let mut enc = GifEncoder::new(file);
            enc.set_repeat(Repeat::Infinite).unwrap();
            let f1 = Frame::new(RgbaImage::from_pixel(
                64,
                64,
                image::Rgba([220, 90, 70, 255]),
            ));
            let f2 = Frame::new(RgbaImage::from_pixel(
                64,
                64,
                image::Rgba([42, 96, 224, 255]),
            ));
            enc.encode_frame(f1).unwrap();
            enc.encode_frame(f2).unwrap();
        }
        let mut gif_asset = AssetRecord::new("Motion Loop", "loop.gif");
        gif_asset.media_kind = MediaKind::AnimatedImage;
        gif_asset.mime_type = "image/gif".to_string();
        gif_asset.content_hash = "gifhash".to_string();
        gif_asset.pixel_width = 64;
        gif_asset.pixel_height = 64;
        media
            .install_original(&src_gif_path, &gif_asset, false)
            .unwrap();

        let mut assets = HashMap::new();
        assets.insert(gif_asset.id, gif_asset.clone());

        let gif_node_id = Uuid::new_v4();
        let palette_node_id = Uuid::new_v4();
        let mut doc = MoodboardDocument::new("动效与配色板");
        doc.mode = BoardLayoutMode::AutoEditorial(crate::models::moodboard::AutoLayoutConfig {
            columns: 3,
            spacing: 16.0,
            style: crate::models::moodboard::EditorialStyle::Magazine,
            show_palette_strip: true,
        });
        doc.extracted_palette = vec![LabColor {
            hex: "#2A60E0".to_string(),
            l: 45.0,
            a: 20.0,
            b: -60.0,
            proportion: 0.6,
        }];
        doc.nodes = vec![
            BoardNode {
                id: gif_node_id,
                kind: BoardNodeKind::AssetRef {
                    asset_id: gif_asset.id,
                    crop: None,
                    weight: 2,
                    autoplay_loop: true,
                },
                frame: BoardRect::new(40.0, 40.0, 260.0, 260.0),
                z_index: 1,
                rotation_degrees: 0.0,
                flip_horizontal: false,
                flip_vertical: false,
                is_locked: false,
                editorial_order: 0,
                updated_at: Utc::now(),
            },
            BoardNode {
                id: palette_node_id,
                kind: BoardNodeKind::PaletteStrip {
                    colors: doc.extracted_palette.clone(),
                    auto_sync_with_board: true,
                },
                frame: BoardRect::new(40.0, 320.0, 360.0, 56.0),
                z_index: 2,
                rotation_degrees: 0.0,
                flip_horizontal: false,
                flip_vertical: false,
                is_locked: false,
                editorial_order: 1,
                updated_at: Utc::now(),
            },
        ];

        // 1. Verify bidirectional Swift-compatible MoodboardDocument JSON wire format
        let wire_json = serde_json::to_string_pretty(&doc).unwrap();
        assert!(wire_json.contains("\"autoEditorial\""));
        assert!(wire_json.contains("\"_0\""));
        assert!(wire_json.contains("\"assetRef\""));
        assert!(wire_json.contains("\"assetID\""));
        assert!(wire_json.contains("\"paletteStrip\""));
        let decoded: MoodboardDocument = serde_json::from_str(&wire_json).unwrap();
        assert_eq!(decoded.id, doc.id);
        assert_eq!(decoded.nodes.len(), 2);
        assert!(decoded.mode.is_auto_editorial());

        // 2. Verify animated GIF export archives verbatim originals/<UUID>.gif + animation metadata
        let zip_path = dir.path().join("motion.charkleboard");
        let report = FigmaBridgeExporter::export_bundle(
            &doc,
            &assets,
            &media,
            &MoodboardExportOptions::default(),
            &zip_path,
        )
        .unwrap();
        assert_eq!(report.image_count, 1);
        assert_eq!(report.palette_count, 2); // 1 top board-palette-header + 1 explicit paletteStrip node
        assert_eq!(report.review_count, 1);

        let mut archive = ZipArchive::new(File::open(&zip_path).unwrap()).unwrap();
        let mut board_str = String::new();
        archive
            .by_name("board.json")
            .unwrap()
            .read_to_string(&mut board_str)
            .unwrap();
        let board_val: Value = serde_json::from_str(&board_str).unwrap();
        let img_obj = board_val["objects"]
            .as_array()
            .unwrap()
            .iter()
            .find(|o| o["kind"] == "image")
            .unwrap();
        assert_eq!(img_obj["image"]["animated"], true);
        let anim_file = img_obj["image"]["animation"]["file"].as_str().unwrap();
        assert!(anim_file.starts_with("originals/"));
        assert!(anim_file.ends_with(".gif"));
        let mut gif_zip_bytes = Vec::new();
        archive
            .by_name(anim_file)
            .unwrap()
            .read_to_end(&mut gif_zip_bytes)
            .unwrap();
        assert_eq!(
            sha256_hex(&gif_zip_bytes),
            img_obj["image"]["animation"]["sha256"].as_str().unwrap()
        );
        assert!(gif_zip_bytes.starts_with(b"GIF8"));
    }

    #[test]
    fn handles_1x1_image_extreme_crop_nan_values_and_non_ascii_hex_without_panicking() {
        let dir = tempdir().unwrap();
        let media = MediaPipeline::new(dir.path()).unwrap();

        let tiny = RgbaImage::from_pixel(1, 1, Rgba([180, 120, 90, 255]));
        let tiny_path = dir.path().join("tiny1x1.png");
        DynamicImage::ImageRgba8(tiny)
            .save_with_format(&tiny_path, ImageFormat::Png)
            .unwrap();

        let mut asset = AssetRecord::new("Tiny 1x1", "tiny1x1.png");
        asset.media_kind = MediaKind::Image;
        asset.mime_type = "image/png".to_string();
        asset.content_hash = "tinyhash".to_string();
        asset.pixel_width = 1;
        asset.pixel_height = 1;
        media.install_original(&tiny_path, &asset, false).unwrap();

        let mut assets = HashMap::new();
        assets.insert(asset.id, asset.clone());

        let node_id = Uuid::new_v4();
        let mut doc = MoodboardDocument::new("边界健壮性测试");
        doc.mode = BoardLayoutMode::Freeform;
        doc.extracted_palette = vec![LabColor {
            hex: "中文色".to_string(),
            l: 50.0,
            a: 0.0,
            b: 0.0,
            proportion: 1.0,
        }];
        doc.nodes = vec![BoardNode {
            id: node_id,
            kind: BoardNodeKind::AssetRef {
                asset_id: asset.id,
                crop: Some(NormalizedCropRect {
                    x: 1.0,
                    y: 1.0,
                    width: 0.5,
                    height: 0.5,
                }),
                weight: 1,
                autoplay_loop: false,
            },
            frame: BoardRect::new(10.0, 10.0, 120.0, 120.0),
            z_index: 1,
            rotation_degrees: f64::NAN,
            flip_horizontal: false,
            flip_vertical: false,
            is_locked: false,
            editorial_order: 0,
            updated_at: Utc::now(),
        }];

        let png_bytes = BoardImageExporter::render_bytes(
            &doc,
            &assets,
            &media,
            &MoodboardExportOptions::default(),
        )
        .unwrap();
        assert!(png_bytes.starts_with(b"\x89PNG"));

        let zip_path = dir.path().join("tiny.charkleboard");
        let report = FigmaBridgeExporter::export_bundle(
            &doc,
            &assets,
            &media,
            &MoodboardExportOptions::default(),
            &zip_path,
        )
        .unwrap();
        assert_eq!(report.image_count, 1);

        // Verify NormalizedCropRect NaN safety
        let clamped_nan = NormalizedCropRect {
            x: f64::NAN,
            y: f64::INFINITY,
            width: f64::NAN,
            height: -5.0,
        }
        .clamped();
        assert!(clamped_nan.x.is_finite());
        assert!(clamped_nan.y.is_finite());
        assert!(clamped_nan.width >= 0.02);
        assert!(clamped_nan.height >= 0.02);
    }
}
