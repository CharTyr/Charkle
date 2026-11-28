//! Bidirectional PureRef (`.pur`) scene binary codec & Moodboard converter.
//!
//! Mirrors `Sources/CharkleCore/Media/PureRefCodec.swift`:
//! - **Decode Tier 1**: Exact structured Qt QDataStream Big-Endian parser for PureRef v1.x
//!   (`.pur` v1.9 / v1.10 / v1.11.1), preserving images, duplicate transforms, crop polygons,
//!   rotations, flips, z-order, root notes, and child notes.
//! - **Decode Tier 2**: Resilient multi-format embedded stream carver (PNG / JPEG / WebP / GIF)
//!   plus UTF-16BE `GraphicsTextItem` scanner for PureRef v2.0+ scenes with SHA-256 dedup.
//! - **Encode**: Valid v1.10 `.pur` binary generator with PNG embedding, duplicate transform
//!   deduplication, 224-byte Big-Endian header, 20-byte reference table, and UTF-16BE MD5
//!   integrity checksum at `[44..108]`.

use std::collections::{HashMap, HashSet};
use std::fs;
use std::io::Cursor;
use std::path::{Path, PathBuf};

use chrono::Utc;
use md5::{Digest as _, Md5};
use serde::{Deserialize, Deserializer, Serialize, Serializer};
use sha2::Sha256;
use uuid::Uuid;

use crate::error::{CoreError, CoreResult};
use crate::models::core::{AssetRecord, LabColor, MediaKind};
use crate::models::moodboard::{
    BoardLayoutMode, BoardNode, BoardNodeKind, BoardRect, MoodboardDocument, NoteStyle,
};
use crate::wire::swift_codec::{format_swift_uuid, upper_uuid};

const HEADER_SIZE: usize = 224;
const PNG_SIGNATURE: [u8; 8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];

fn image_item_type_utf16be() -> Vec<u8> {
    encode_utf16be("GraphicsImageItem")
}

fn text_item_type_utf16be() -> Vec<u8> {
    encode_utf16be("GraphicsTextItem")
}

mod opt_upper_uuid {
    use super::*;

    pub fn serialize<S>(val: &Option<Uuid>, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: Serializer,
    {
        match val {
            Some(id) => serializer.serialize_some(&format_swift_uuid(id)),
            None => serializer.serialize_none(),
        }
    }

    pub fn deserialize<'de, D>(deserializer: D) -> Result<Option<Uuid>, D::Error>
    where
        D: Deserializer<'de>,
    {
        let opt = Option::<String>::deserialize(deserializer)?;
        match opt {
            Some(s) => Uuid::parse_str(&s)
                .map(Some)
                .map_err(serde::de::Error::custom),
            None => Ok(None),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum PureRefImageFormat {
    Png,
    Jpeg,
    Webp,
    Gif,
}

impl PureRefImageFormat {
    pub fn file_extension(self) -> &'static str {
        match self {
            Self::Png => "png",
            Self::Jpeg => "jpg",
            Self::Webp => "webp",
            Self::Gif => "gif",
        }
    }

    pub fn mime_type(self) -> &'static str {
        match self {
            Self::Png => "image/png",
            Self::Jpeg => "image/jpeg",
            Self::Webp => "image/webp",
            Self::Gif => "image/gif",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PureRefColor {
    pub r: f64,
    pub g: f64,
    pub b: f64,
    pub alpha: f64,
}

impl PureRefColor {
    pub fn new(r: f64, g: f64, b: f64, alpha: f64) -> Self {
        Self {
            r: r.clamp(0.0, 1.0),
            g: g.clamp(0.0, 1.0),
            b: b.clamp(0.0, 1.0),
            alpha: alpha.clamp(0.0, 1.0),
        }
    }

    pub const DEFAULT_NOTE_FOREGROUND: Self = Self {
        r: 0.94,
        g: 0.95,
        b: 0.97,
        alpha: 1.0,
    };

    pub const DEFAULT_NOTE_BACKGROUND: Self = Self {
        r: 0.14,
        g: 0.15,
        b: 0.18,
        alpha: 0.88,
    };

    pub fn from_note_style(style: NoteStyle) -> (Self, Self) {
        match style {
            NoteStyle::Paper => (
                Self::new(0.14, 0.15, 0.17, 1.0),
                Self::new(0.97, 0.96, 0.94, 0.96),
            ),
            NoteStyle::Ink => (
                Self::new(0.95, 0.96, 0.98, 1.0),
                Self::new(0.12, 0.13, 0.16, 0.95),
            ),
            NoteStyle::Warm => (
                Self::new(0.24, 0.18, 0.11, 1.0),
                Self::new(0.98, 0.93, 0.82, 0.96),
            ),
            NoteStyle::Sage => (
                Self::new(0.14, 0.22, 0.17, 1.0),
                Self::new(0.88, 0.94, 0.89, 0.96),
            ),
            NoteStyle::Slate => (
                Self::new(0.14, 0.19, 0.27, 1.0),
                Self::new(0.88, 0.92, 0.97, 0.96),
            ),
        }
    }

    pub fn inferred_note_style(self) -> NoteStyle {
        let luminance = 0.2126 * self.r + 0.7152 * self.g + 0.0722 * self.b;
        if self.alpha < 0.25 || luminance < 0.35 {
            return NoteStyle::Ink;
        }
        if self.r > self.b + 0.08 && self.g >= self.b {
            return NoteStyle::Warm;
        }
        if self.g > self.r + 0.04 && self.g >= self.b {
            return NoteStyle::Sage;
        }
        if self.b > self.r + 0.05 {
            return NoteStyle::Slate;
        }
        NoteStyle::Paper
    }
}

#[derive(Debug, Clone, PartialEq)]
pub struct PureRefImageBlob {
    pub index: usize,
    pub data: Vec<u8>,
    pub format: PureRefImageFormat,
    pub pixel_width: u32,
    pub pixel_height: u32,
    pub source_path: Option<String>,
    pub display_name: Option<String>,
}

#[derive(Debug, Clone, PartialEq)]
pub struct PureRefTextNote {
    pub text: String,
    pub center_x: f64,
    pub center_y: f64,
    pub scale: f64,
    pub z_layer: f64,
    pub foreground: PureRefColor,
    pub background: PureRefColor,
    pub child_notes: Vec<PureRefTextNote>,
}

impl Default for PureRefTextNote {
    fn default() -> Self {
        Self {
            text: String::new(),
            center_x: 0.0,
            center_y: 0.0,
            scale: 1.0,
            z_layer: 1.0,
            foreground: PureRefColor::DEFAULT_NOTE_FOREGROUND,
            background: PureRefColor::DEFAULT_NOTE_BACKGROUND,
            child_notes: Vec::new(),
        }
    }
}

#[derive(Debug, Clone, PartialEq)]
pub struct PureRefImagePlacement {
    pub image_index: usize,
    pub name: Option<String>,
    pub source_path: Option<String>,
    pub center_x: f64,
    pub center_y: f64,
    pub width: f64,
    pub height: f64,
    pub rotation_degrees: f64,
    pub flip_horizontal: bool,
    pub flip_vertical: bool,
    pub z_layer: f64,
    pub crop: Option<crate::models::moodboard::NormalizedCropRect>,
    pub child_notes: Vec<PureRefTextNote>,
}

#[derive(Debug, Clone, PartialEq)]
pub struct PureRefScene {
    pub format_version: String,
    pub used_fallback_extraction: bool,
    pub canvas_rect: BoardRect,
    pub zoom: f64,
    pub view_x: i32,
    pub view_y: i32,
    pub folder_location: String,
    pub images: Vec<PureRefImageBlob>,
    pub placements: Vec<PureRefImagePlacement>,
    pub notes: Vec<PureRefTextNote>,
    pub skipped_missing_link_count: usize,
}

impl Default for PureRefScene {
    fn default() -> Self {
        Self {
            format_version: "1.10".to_string(),
            used_fallback_extraction: false,
            canvas_rect: BoardRect::new(-10000.0, -10000.0, 20000.0, 20000.0),
            zoom: 1.0,
            view_x: 0,
            view_y: 0,
            folder_location: String::new(),
            images: Vec::new(),
            placements: Vec::new(),
            notes: Vec::new(),
            skipped_missing_link_count: 0,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PureRefImportResult {
    pub scene_name: String,
    pub format_version: String,
    pub used_fallback_extraction: bool,
    pub imported_assets: Vec<AssetRecord>,
    #[serde(
        rename = "rootFolderID",
        default,
        skip_serializing_if = "Option::is_none",
        with = "opt_upper_uuid"
    )]
    pub root_folder_id: Option<Uuid>,
    #[serde(
        rename = "createdBoardID",
        default,
        skip_serializing_if = "Option::is_none",
        with = "opt_upper_uuid"
    )]
    pub created_board_id: Option<Uuid>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub created_board_title: Option<String>,
    pub imported_note_count: usize,
    pub skipped_missing_link_count: usize,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PureRefExportReport {
    pub file_path: String,
    pub image_count: usize,
    pub placement_count: usize,
    pub note_count: usize,
    pub skipped_count: usize,
    pub byte_count: usize,
}

#[derive(Debug, Clone)]
pub struct PureRefAssetInput {
    pub id: Uuid,
    pub title: String,
    pub file_name: String,
    pub pixel_width: u32,
    pub pixel_height: u32,
    pub image_data: Vec<u8>,
}

#[derive(Debug, Clone)]
struct RawV1ImageItem {
    id: u32,
    source: Option<String>,
    name: Option<String>,
    matrix: (f64, f64, f64, f64),
    x: f64,
    y: f64,
    z_layer: f64,
    x_crop: f64,
    y_crop: f64,
    crop_points: Vec<(f64, f64)>,
    child_notes: Vec<PureRefTextNote>,
}

const MAX_PUREREF_FILE_BYTES: u64 = 256 * 1024 * 1024;
const MAX_PUREREF_TOTAL_BLOB_BYTES: usize = 512 * 1024 * 1024;
const MAX_PUREREF_NOTE_DEPTH: usize = 64;

pub struct PureRefCodec;

impl PureRefCodec {
    pub fn is_pure_ref_path(path: &Path) -> bool {
        path.extension()
            .and_then(|e| e.to_str())
            .is_some_and(|ext| ext.eq_ignore_ascii_case("pur"))
    }

    pub fn decode_path(path: &Path) -> CoreResult<PureRefScene> {
        let meta = fs::metadata(path)?;
        if meta.len() > MAX_PUREREF_FILE_BYTES {
            return Err(CoreError::Media(format!(
                "PureRef (.pur) 场景文件过大（{} 字节，超过安全限制）",
                meta.len()
            )));
        }
        let data = fs::read(path)?;
        let source_name = path
            .file_stem()
            .and_then(|s| s.to_str())
            .filter(|s| !s.trim().is_empty())
            .unwrap_or("PureRef");
        Self::decode_bytes(&data, source_name)
    }

    pub fn decode_bytes(bytes: &[u8], source_name: &str) -> CoreResult<PureRefScene> {
        if bytes.len() < HEADER_SIZE {
            return Err(CoreError::Media(format!(
                "无法识别的 PureRef (.pur) 场景文件：文件过小（{} 字节）",
                bytes.len()
            )));
        }
        let version_len = read_u32_be(bytes, 0) as usize;
        if !(4..=32).contains(&version_len) || version_len % 2 != 0 || 4 + version_len > HEADER_SIZE
        {
            return Err(CoreError::Media(format!(
                "无法识别的 PureRef (.pur) 场景文件：文件头版本号长度异常（{version_len}）"
            )));
        }
        let version = decode_utf16be(&bytes[4..(4 + version_len)])
            .trim()
            .to_string();
        if !version.chars().next().is_some_and(|c| c.is_ascii_digit()) {
            return Err(CoreError::Media(
                "无法识别的 PureRef (.pur) 场景文件：版本号不可读".to_string(),
            ));
        }

        if version.starts_with("1.") {
            if let Some(scene) = Self::decode_v1_structured(bytes, &version) {
                if !scene.images.is_empty() || !scene.notes.is_empty() {
                    return Ok(scene);
                }
            }
        }

        let fallback = Self::decode_resilient_v2(bytes, &version);
        if fallback.images.is_empty() && fallback.notes.is_empty() {
            return Err(CoreError::Media(format!(
                "PureRef 场景「{source_name}」中没有可导入的图片或便签内容。"
            )));
        }
        Ok(fallback)
    }

    // -------------------------------------------------------------------------
    // Tier 1: Exact Structured v1.x QDataStream Parser
    // -------------------------------------------------------------------------

    fn decode_v1_structured(bytes: &[u8], version: &str) -> Option<PureRefScene> {
        if bytes.len() < HEADER_SIZE {
            return None;
        }
        let file_length = usize::try_from(read_u64_be(bytes, 16)).unwrap_or(bytes.len());
        let canvas_x = read_f64_be(bytes, 112);
        let canvas_y = read_f64_be(bytes, 120);
        let canvas_w = read_f64_be(bytes, 128);
        let canvas_h = read_f64_be(bytes, 136);
        let zoom = read_f64_be(bytes, 144);
        let view_x = read_i32_be(bytes, 216);
        let view_y = read_i32_be(bytes, 220);

        let canvas_rect = BoardRect::new(
            if canvas_x.is_finite() {
                canvas_x
            } else {
                -10000.0
            },
            if canvas_y.is_finite() {
                canvas_y
            } else {
                -10000.0
            },
            if canvas_w.is_finite() && canvas_w > 0.0 {
                canvas_w
            } else {
                20000.0
            },
            if canvas_h.is_finite() && canvas_h > 0.0 {
                canvas_h
            } else {
                20000.0
            },
        );

        let mut ref_by_transform_id: HashMap<u32, (usize, usize)> = HashMap::new();
        let mut max_image_end = HEADER_SIZE;
        if file_length >= HEADER_SIZE && file_length <= bytes.len() {
            let mut ref_cursor = file_length;
            while ref_cursor + 20 <= bytes.len() {
                let ref_id = read_u32_be(bytes, ref_cursor);
                let start = usize::try_from(read_u64_be(bytes, ref_cursor + 4)).unwrap_or(0);
                let end = usize::try_from(read_u64_be(bytes, ref_cursor + 12)).unwrap_or(0);
                ref_cursor += 20;
                if start >= HEADER_SIZE && end > start && end <= file_length {
                    ref_by_transform_id.insert(ref_id, (start, end));
                    if end > max_image_end {
                        max_image_end = end;
                    }
                }
            }
        }

        let search_limit = if file_length >= HEADER_SIZE && file_length <= bytes.len() {
            file_length
        } else {
            bytes.len()
        };

        let img_type = image_item_type_utf16be();
        let txt_type = text_item_type_utf16be();

        let mut cursor =
            Self::find_first_item_offset(bytes, max_image_end, search_limit, &img_type, &txt_type)
                .or_else(|| {
                    Self::find_first_item_offset(
                        bytes,
                        HEADER_SIZE,
                        search_limit,
                        &img_type,
                        &txt_type,
                    )
                })
                .unwrap_or(search_limit);

        let mut raw_images: Vec<RawV1ImageItem> = Vec::new();
        let mut root_notes: Vec<PureRefTextNote> = Vec::new();

        while cursor + 12 <= search_limit {
            let type_len = read_u32_be(bytes, cursor + 8) as usize;
            if type_len == img_type.len()
                && cursor + 12 + type_len <= search_limit
                && bytes[(cursor + 12)..(cursor + 12 + type_len)] == img_type[..]
            {
                let Some(parsed) = Self::parse_v1_image_item(bytes, &mut cursor, search_limit)
                else {
                    break;
                };
                raw_images.push(parsed);
            } else if type_len == txt_type.len()
                && cursor + 12 + type_len <= search_limit
                && bytes[(cursor + 12)..(cursor + 12 + type_len)] == txt_type[..]
            {
                let Some(parsed) = Self::parse_v1_text_item(bytes, &mut cursor, search_limit, 0)
                else {
                    break;
                };
                root_notes.push(parsed);
            } else {
                break;
            }
        }

        let mut folder_location = String::new();
        if cursor + 4 <= search_limit {
            let folder_len = read_u32_be(bytes, cursor) as usize;
            if folder_len > 0 && folder_len % 2 == 0 && cursor + 4 + folder_len <= search_limit {
                folder_location = decode_utf16be(&bytes[(cursor + 4)..(cursor + 4 + folder_len)]);
            }
        }

        if raw_images.is_empty() && root_notes.is_empty() {
            return None;
        }

        let mut image_index_by_primary_id: HashMap<u32, usize> = HashMap::new();
        let mut image_index_by_start_offset: HashMap<usize, usize> = HashMap::new();
        let mut blobs: Vec<PureRefImageBlob> = Vec::new();
        let mut total_blob_bytes: usize = 0;
        let mut skipped_missing_links = 0usize;

        for raw in &raw_images {
            let Some(&(start, end)) = ref_by_transform_id.get(&raw.id) else {
                continue;
            };
            let span_len = end.saturating_sub(start);
            if span_len <= 4 {
                continue;
            }
            if let Some(&existing_idx) = image_index_by_start_offset.get(&start) {
                image_index_by_primary_id.insert(raw.id, existing_idx);
                continue;
            }
            if total_blob_bytes.saturating_add(span_len) > MAX_PUREREF_TOTAL_BLOB_BYTES {
                skipped_missing_links += 1;
                continue;
            }
            let blob_data = bytes[start..end].to_vec();
            let Some(format) = Self::detect_image_format(&blob_data) else {
                continue;
            };
            let Some((w, h)) = Self::inspect_image_dimensions(&blob_data) else {
                continue;
            };
            total_blob_bytes = total_blob_bytes.saturating_add(blob_data.len());
            let idx = blobs.len();
            blobs.push(PureRefImageBlob {
                index: idx,
                data: blob_data,
                format,
                pixel_width: w,
                pixel_height: h,
                source_path: raw.source.clone(),
                display_name: raw.name.clone(),
            });
            image_index_by_start_offset.insert(start, idx);
            image_index_by_primary_id.insert(raw.id, idx);
        }

        let mut placements: Vec<PureRefImagePlacement> = Vec::with_capacity(raw_images.len());
        for raw in raw_images {
            let mut resolved_idx = image_index_by_primary_id.get(&raw.id).copied();
            if resolved_idx.is_none() {
                if let Some(&(start, end)) = ref_by_transform_id.get(&raw.id) {
                    if end.saturating_sub(start) == 4 {
                        let ref_val = read_u32_be(bytes, start);
                        if ref_val == 0xFFFF_FFFF {
                            // Security: never auto-read arbitrary external local or UNC/SMB paths
                            // referenced by an untrusted `.pur` scene file (prevents local file
                            // exfiltration and NTLM credential leaks over UNC paths).
                            skipped_missing_links += 1;
                        } else {
                            resolved_idx = image_index_by_primary_id.get(&ref_val).copied();
                        }
                    }
                }
            }

            let Some(img_idx) = resolved_idx.filter(|&i| i < blobs.len()) else {
                continue;
            };
            let blob = &blobs[img_idx];
            placements.push(Self::build_placement(
                raw,
                img_idx,
                blob.pixel_width,
                blob.pixel_height,
            ));
        }

        Some(PureRefScene {
            format_version: version.to_string(),
            used_fallback_extraction: false,
            canvas_rect,
            zoom: if zoom.is_finite() && zoom > 0.0 {
                zoom
            } else {
                1.0
            },
            view_x,
            view_y,
            folder_location,
            images: blobs,
            placements,
            notes: root_notes,
            skipped_missing_link_count: skipped_missing_links,
        })
    }

    fn find_first_item_offset(
        bytes: &[u8],
        start: usize,
        limit: usize,
        img_type: &[u8],
        txt_type: &[u8],
    ) -> Option<usize> {
        let clamped_start = start.max(HEADER_SIZE);
        if clamped_start + 12 + txt_type.len() > limit {
            return None;
        }
        let max_offset = limit.saturating_sub(12 + txt_type.len());
        for offset in clamped_start..=max_offset {
            let end_addr = usize::try_from(read_u64_be(bytes, offset)).unwrap_or(0);
            if end_addr <= offset + 12 || end_addr > limit {
                continue;
            }
            let type_len = read_u32_be(bytes, offset + 8) as usize;
            if type_len == img_type.len()
                && offset + 12 + type_len <= limit
                && bytes[(offset + 12)..(offset + 12 + type_len)] == img_type[..]
            {
                return Some(offset);
            }
            if type_len == txt_type.len()
                && offset + 12 + type_len <= limit
                && bytes[(offset + 12)..(offset + 12 + type_len)] == txt_type[..]
            {
                return Some(offset);
            }
        }
        None
    }

    fn parse_v1_image_item(
        bytes: &[u8],
        cursor: &mut usize,
        limit: usize,
    ) -> Option<RawV1ImageItem> {
        if *cursor + 12 > limit {
            return None;
        }
        let end_address = usize::try_from(read_u64_be(bytes, *cursor)).unwrap_or(0);
        let type_len = read_u32_be(bytes, *cursor + 8) as usize;
        if end_address <= *cursor + 12 + type_len || end_address > limit {
            return None;
        }
        let mut pos = *cursor + 12 + type_len;

        let mut brute_force_loaded = false;
        if pos + 4 <= end_address && read_u32_be(bytes, pos) == 0 {
            brute_force_loaded = true;
            pos += 4;
        }

        let mut source = read_optional_qstring(bytes, &mut pos, end_address);
        let mut name = if brute_force_loaded {
            None
        } else {
            read_optional_qstring(bytes, &mut pos, end_address)
        };
        if brute_force_loaded {
            if let Some(first) = source.clone() {
                if first != "BruteForceLoaded" {
                    name = Some(first);
                    source = None;
                }
            }
        }

        pos += 8; // unknown double (1.0)
        if pos + 48 + 16 + 8 + 4 + 8 > end_address {
            *cursor = end_address;
            return None;
        }

        let matrix = read_matrix_6_doubles(bytes, &mut pos);
        let x = read_f64_be(bytes, pos);
        pos += 8;
        let y = read_f64_be(bytes, pos);
        pos += 8;
        pos += 8; // second 1.0 double
        let id = read_u32_be(bytes, pos);
        pos += 4;
        let z_layer = read_f64_be(bytes, pos);
        pos += 8;

        let mut x_crop = 0.0;
        let mut y_crop = 0.0;
        let mut crop_points: Vec<(f64, f64)> = Vec::new();
        let mut child_count = 0usize;

        if pos + 48 + 24 + 4 <= end_address {
            let _ = read_matrix_6_doubles(bytes, &mut pos);
            x_crop = read_f64_be(bytes, pos);
            pos += 8;
            y_crop = read_f64_be(bytes, pos);
            pos += 8;
            pos += 8; // scaleCrop
            let point_count = read_u32_be(bytes, pos) as usize;
            pos += 4;
            if point_count > 0 && point_count <= 64 {
                for _ in 0..point_count {
                    if pos + 20 > end_address {
                        break;
                    }
                    pos += 4; // QPainterPath element type
                    let px = read_f64_be(bytes, pos);
                    pos += 8;
                    let py = read_f64_be(bytes, pos);
                    pos += 8;
                    crop_points.push((px, py));
                }
            }
            if pos + 25 <= end_address {
                child_count = read_u32_be(bytes, pos + 21) as usize;
            }
        }

        *cursor = end_address;
        let mut children = Vec::new();
        if child_count > 0 && child_count <= 256 {
            for _ in 0..child_count {
                let Some(child) = Self::parse_v1_text_item(bytes, cursor, limit, 1) else {
                    break;
                };
                children.push(child);
            }
        }

        Some(RawV1ImageItem {
            id,
            source,
            name,
            matrix,
            x: if x.is_finite() { x } else { 0.0 },
            y: if y.is_finite() { y } else { 0.0 },
            z_layer: if z_layer.is_finite() { z_layer } else { 0.0 },
            x_crop: if x_crop.is_finite() { x_crop } else { 0.0 },
            y_crop: if y_crop.is_finite() { y_crop } else { 0.0 },
            crop_points,
            child_notes: children,
        })
    }

    fn parse_v1_text_item(
        bytes: &[u8],
        cursor: &mut usize,
        limit: usize,
        depth: usize,
    ) -> Option<PureRefTextNote> {
        if depth >= MAX_PUREREF_NOTE_DEPTH || *cursor + 12 > limit {
            return None;
        }
        let end_address = usize::try_from(read_u64_be(bytes, *cursor)).unwrap_or(0);
        let type_len = read_u32_be(bytes, *cursor + 8) as usize;
        if end_address <= *cursor + 12 + type_len || end_address > limit {
            return None;
        }
        let mut pos = *cursor + 12 + type_len;
        let text = read_optional_qstring(bytes, &mut pos, end_address).unwrap_or_default();
        if pos + 48 + 16 + 8 + 4 + 8 > end_address {
            *cursor = end_address;
            return None;
        }

        let matrix = read_matrix_6_doubles(bytes, &mut pos);
        let x = read_f64_be(bytes, pos);
        pos += 8;
        let y = read_f64_be(bytes, pos);
        pos += 8;
        pos += 8; // 1.0 double
        let _id = read_u32_be(bytes, pos);
        pos += 4;
        let z_layer = read_f64_be(bytes, pos);
        pos += 8;

        let mut fg = PureRefColor::DEFAULT_NOTE_FOREGROUND;
        let mut bg = PureRefColor::DEFAULT_NOTE_BACKGROUND;
        let mut child_count = 0usize;

        if pos + 9 <= end_address {
            fg = read_qcolor(bytes, &mut pos);
            pos = (pos + 2).min(end_address);
        }
        if pos + 9 <= end_address {
            bg = read_qcolor(bytes, &mut pos);
            if pos + 6 <= end_address {
                child_count = read_u32_be(bytes, pos + 2) as usize;
            }
        }

        *cursor = end_address;
        let mut children = Vec::new();
        if child_count > 0 && child_count <= 128 && depth + 1 < MAX_PUREREF_NOTE_DEPTH {
            for _ in 0..child_count {
                let Some(child) = Self::parse_v1_text_item(bytes, cursor, limit, depth + 1) else {
                    break;
                };
                children.push(child);
            }
        }

        let scale_x = matrix.0.hypot(matrix.1);
        let scale_y = matrix.2.hypot(matrix.3);
        let scale = ((scale_x + scale_y) * 0.5).clamp(0.2, 8.0);

        Some(PureRefTextNote {
            text,
            center_x: if x.is_finite() { x } else { 0.0 },
            center_y: if y.is_finite() { y } else { 0.0 },
            scale: if scale.is_finite() { scale } else { 1.0 },
            z_layer: if z_layer.is_finite() { z_layer } else { 1.0 },
            foreground: fg,
            background: bg,
            child_notes: children,
        })
    }

    fn build_placement(
        raw: RawV1ImageItem,
        image_index: usize,
        pixel_width: u32,
        pixel_height: u32,
    ) -> PureRefImagePlacement {
        let base_w = pixel_width.max(1) as f64;
        let base_h = pixel_height.max(1) as f64;
        let (sx, sy, rot_deg, flip_h, flip_v) = Self::decompose_matrix(raw.matrix);

        let mut visible_local_w = base_w;
        let mut visible_local_h = base_h;
        let mut crop = None;

        if raw.crop_points.len() >= 3 {
            let xs: Vec<f64> = raw
                .crop_points
                .iter()
                .map(|p| p.0)
                .filter(|v| v.is_finite())
                .collect();
            let ys: Vec<f64> = raw
                .crop_points
                .iter()
                .map(|p| p.1)
                .filter(|v| v.is_finite())
                .collect();
            let min_x = xs.iter().copied().reduce(f64::min);
            let max_x = xs.iter().copied().reduce(f64::max);
            let min_y = ys.iter().copied().reduce(f64::min);
            let max_y = ys.iter().copied().reduce(f64::max);
            if let (Some(min_x), Some(max_x), Some(min_y), Some(max_y)) =
                (min_x, max_x, min_y, max_y)
            {
                if max_x - min_x > 2.0 && max_y - min_y > 2.0 {
                    visible_local_w = max_x - min_x;
                    visible_local_h = max_y - min_y;

                    let origin_x = if raw.x_crop.is_finite() && raw.x_crop != 0.0 {
                        raw.x_crop
                    } else {
                        -base_w * 0.5
                    };
                    let origin_y = if raw.y_crop.is_finite() && raw.y_crop != 0.0 {
                        raw.y_crop
                    } else {
                        -base_h * 0.5
                    };
                    let norm = crate::models::moodboard::NormalizedCropRect {
                        x: (min_x - origin_x) / base_w,
                        y: (min_y - origin_y) / base_h,
                        width: (max_x - min_x) / base_w,
                        height: (max_y - min_y) / base_h,
                    }
                    .clamped();
                    if norm.is_meaningful_subregion() {
                        crop = Some(norm);
                    }
                }
            }
        }

        let display_w = (visible_local_w * sx).max(24.0);
        let display_h = (visible_local_h * sy).max(24.0);

        PureRefImagePlacement {
            image_index,
            name: raw.name,
            source_path: raw.source,
            center_x: raw.x,
            center_y: raw.y,
            width: display_w,
            height: display_h,
            rotation_degrees: rot_deg,
            flip_horizontal: flip_h,
            flip_vertical: flip_v,
            z_layer: raw.z_layer,
            crop,
            child_notes: raw.child_notes,
        }
    }

    // -------------------------------------------------------------------------
    // Tier 2: Resilient Multi-Format Extractor (PureRef 2.0+ PNG/JPEG/WebP/GIF)
    // -------------------------------------------------------------------------

    fn decode_resilient_v2(bytes: &[u8], version: &str) -> PureRefScene {
        let mut blobs: Vec<PureRefImageBlob> = Vec::new();
        let mut seen_hashes: HashSet<String> = HashSet::new();
        let mut cursor = HEADER_SIZE.min(bytes.len());
        let count = bytes.len();

        while cursor + 12 < count {
            let b0 = bytes[cursor];
            let mut carved: Option<(Vec<u8>, PureRefImageFormat, usize)> = None;

            if b0 == 0x89 && cursor + 8 <= count && bytes[cursor..(cursor + 8)] == PNG_SIGNATURE {
                if let Some(end) = walk_png_end(bytes, cursor) {
                    carved = Some((bytes[cursor..end].to_vec(), PureRefImageFormat::Png, end));
                }
            } else if b0 == 0xFF && bytes[cursor + 1] == 0xD8 && bytes[cursor + 2] == 0xFF {
                if let Some(end) = walk_jpeg_end(bytes, cursor) {
                    carved = Some((bytes[cursor..end].to_vec(), PureRefImageFormat::Jpeg, end));
                }
            } else if b0 == 0x52
                && bytes[cursor + 1] == 0x49
                && bytes[cursor + 2] == 0x46
                && bytes[cursor + 3] == 0x46
                && cursor + 12 <= count
                && bytes[cursor + 8] == 0x57
                && bytes[cursor + 9] == 0x45
                && bytes[cursor + 10] == 0x42
                && bytes[cursor + 11] == 0x50
            {
                let riff_size = read_u32_le(bytes, cursor + 4) as usize;
                let end = cursor.saturating_add(8).saturating_add(riff_size);
                if riff_size >= 12 && end <= count {
                    carved = Some((bytes[cursor..end].to_vec(), PureRefImageFormat::Webp, end));
                }
            } else if b0 == 0x47
                && bytes[cursor + 1] == 0x49
                && bytes[cursor + 2] == 0x46
                && bytes[cursor + 3] == 0x38
                && (bytes[cursor + 4] == 0x37 || bytes[cursor + 4] == 0x39)
                && bytes[cursor + 5] == 0x61
            {
                if let Some(end) = walk_gif_end(bytes, cursor) {
                    carved = Some((bytes[cursor..end].to_vec(), PureRefImageFormat::Gif, end));
                }
            }

            if let Some((data, format, next_cursor)) = carved {
                if data.len() >= 64 {
                    if let Some((w, h)) = Self::inspect_image_dimensions(&data) {
                        let hash = hex::encode(Sha256::digest(&data));
                        if seen_hashes.insert(hash) {
                            blobs.push(PureRefImageBlob {
                                index: blobs.len(),
                                data,
                                format,
                                pixel_width: w,
                                pixel_height: h,
                                source_path: None,
                                display_name: None,
                            });
                        }
                        cursor = next_cursor.max(cursor + 1);
                        continue;
                    }
                }
            }
            cursor += 1;
        }

        let placements = Self::auto_layout_placements(&blobs, 340.0, 18.0);
        let notes = Self::scan_readable_text_notes(bytes);
        let canvas_rect = Self::compute_canvas_rect(&placements, &notes);

        PureRefScene {
            format_version: version.to_string(),
            used_fallback_extraction: true,
            canvas_rect,
            zoom: 1.0,
            view_x: 0,
            view_y: 0,
            folder_location: String::new(),
            images: blobs,
            placements,
            notes,
            skipped_missing_link_count: 0,
        }
    }

    fn scan_readable_text_notes(bytes: &[u8]) -> Vec<PureRefTextNote> {
        let mut notes = Vec::new();
        let mut seen = HashSet::new();
        let needle = text_item_type_utf16be();
        let count = bytes.len();
        if count <= HEADER_SIZE + needle.len() + 8 {
            return notes;
        }
        let mut i = HEADER_SIZE;
        while i + needle.len() + 8 < count {
            if bytes[i] == needle[0]
                && bytes[i + 1] == needle[1]
                && bytes[i..(i + needle.len())] == needle[..]
            {
                let mut pos = i + needle.len();
                let limit = count.min(pos + 16_384);
                if let Some(raw_text) = read_optional_qstring(bytes, &mut pos, limit) {
                    let trimmed = raw_text.trim();
                    if !trimmed.is_empty() && seen.insert(trimmed.to_string()) {
                        notes.push(PureRefTextNote {
                            text: trimmed.to_string(),
                            center_x: 0.0,
                            center_y: (notes.len() as f64) * 140.0,
                            scale: 1.0,
                            z_layer: (notes.len() as f64) + 100.0,
                            ..PureRefTextNote::default()
                        });
                    }
                }
                i += needle.len();
            } else {
                i += 1;
            }
        }
        notes
    }

    // -------------------------------------------------------------------------
    // Encode (PureRefScene -> Valid v1.10 .pur with UTF-16BE MD5 Checksum)
    // -------------------------------------------------------------------------

    pub fn encode(scene: &PureRefScene) -> CoreResult<Vec<u8>> {
        if scene.images.is_empty() && scene.notes.is_empty() {
            return Err(CoreError::Media(
                "生成 PureRef (.pur) 文件失败：场景中没有可导出的图片或便签。".to_string(),
            ));
        }

        let mut png_blobs: Vec<Vec<u8>> = Vec::with_capacity(scene.images.len());
        for img in &scene.images {
            if img.format == PureRefImageFormat::Png
                && img.data.len() >= 8
                && img.data[..8] == PNG_SIGNATURE
            {
                png_blobs.push(img.data.clone());
            } else if let Some(converted) = Self::convert_to_png(&img.data) {
                png_blobs.push(converted);
            } else {
                let name = img
                    .display_name
                    .clone()
                    .unwrap_or_else(|| format!("image_{}", img.index));
                return Err(CoreError::Media(format!(
                    "导出素材「{name}」时无法编码为兼容的 PNG 图像。"
                )));
            }
        }

        let mut placements_by_image: Vec<Vec<usize>> = vec![Vec::new(); png_blobs.len()];
        for (p_idx, placement) in scene.placements.iter().enumerate() {
            if placement.image_index < png_blobs.len() {
                placements_by_image[placement.image_index].push(p_idx);
            }
        }

        let mut transform_id_by_placement: HashMap<usize, u32> = HashMap::new();
        let mut ordered_placement_indices: Vec<usize> = Vec::new();
        let mut next_id: u32 = 0;
        for group in &placements_by_image {
            for &p_idx in group {
                transform_id_by_placement.insert(p_idx, next_id);
                ordered_placement_indices.push(p_idx);
                next_id += 1;
            }
        }

        fn count_notes(list: &[PureRefTextNote], depth: usize) -> u32 {
            if depth >= MAX_PUREREF_NOTE_DEPTH {
                return 0;
            }
            list.iter()
                .map(|n| 1u32.saturating_add(count_notes(&n.child_notes, depth + 1)))
                .fold(0u32, u32::saturating_add)
        }

        let total_child_notes: u32 = ordered_placement_indices
            .iter()
            .map(|&p_idx| count_notes(&scene.placements[p_idx].child_notes, 0))
            .fold(0u32, u32::saturating_add);
        let total_root_notes = count_notes(&scene.notes, 0);
        let image_transform_count = ordered_placement_indices.len() as u32;
        let total_id_count = image_transform_count + total_child_notes + total_root_notes;

        let mut out: Vec<u8> = vec![0u8; HEADER_SIZE];

        write_u32_be(&mut out, 0, 8);
        let v110 = encode_utf16be("1.10");
        out[4..12].copy_from_slice(&v110);

        let total_root_item_count = ordered_placement_indices.len() + scene.notes.len();
        write_u16_be(
            &mut out,
            12,
            total_root_item_count.min(u16::MAX as usize) as u16,
        );
        write_u16_be(
            &mut out,
            14,
            ordered_placement_indices.len().min(u16::MAX as usize) as u16,
        );

        write_u32_be(&mut out, 24, 12);
        let v1111 = encode_utf16be("1.11.1");
        out[28..40].copy_from_slice(&v1111);
        write_u32_be(&mut out, 40, 64);

        write_u32_be(&mut out, 108, total_id_count);

        let rect = Self::compute_canvas_rect(&scene.placements, &scene.notes);
        write_f64_be(&mut out, 112, rect.x);
        write_f64_be(&mut out, 120, rect.y);
        write_f64_be(&mut out, 128, rect.width);
        write_f64_be(&mut out, 136, rect.height);

        let zoom = if scene.zoom.is_finite() && scene.zoom > 0.0 {
            scene.zoom
        } else {
            1.0
        };
        write_f64_be(&mut out, 144, zoom);
        write_f64_be(&mut out, 176, zoom);
        write_f64_be(&mut out, 208, 1.0);
        write_i32_be(&mut out, 216, scene.view_x);
        write_i32_be(&mut out, 220, scene.view_y);

        // Images section
        let mut ref_entries: Vec<(u32, u64, u64)> =
            Vec::with_capacity(ordered_placement_indices.len());
        for (img_idx, group) in placements_by_image.iter().enumerate() {
            if group.is_empty() {
                continue;
            }
            let start_offset = out.len() as u64;
            out.extend_from_slice(&png_blobs[img_idx]);
            let end_offset = out.len() as u64;

            let primary_id = *transform_id_by_placement.get(&group[0]).unwrap_or(&0);
            ref_entries.push((primary_id, start_offset, end_offset));

            for &dup_p_idx in group.iter().skip(1) {
                let dup_start = out.len() as u64;
                append_u32_be(&mut out, primary_id);
                let dup_end = out.len() as u64;
                let dup_id = *transform_id_by_placement.get(&dup_p_idx).unwrap_or(&0);
                ref_entries.push((dup_id, dup_start, dup_end));
            }
        }

        // Items section
        let img_type = image_item_type_utf16be();
        let txt_type = text_item_type_utf16be();
        let mut next_note_id = image_transform_count;

        fn append_text_item(
            out: &mut Vec<u8>,
            txt_type: &[u8],
            note: &PureRefTextNote,
            next_note_id: &mut u32,
        ) {
            let end_addr_pos = out.len();
            append_u64_be(out, 0);
            append_u32_be(out, txt_type.len() as u32);
            out.extend_from_slice(txt_type);

            append_qstring(out, &note.text);

            let s = if note.scale.is_finite() && note.scale > 0.0 {
                note.scale
            } else {
                1.0
            };
            append_matrix_6_doubles(out, s, 0.0, 0.0, s);
            append_f64_be(out, note.center_x);
            append_f64_be(out, note.center_y);
            append_f64_be(out, 1.0);

            let note_id = *next_note_id;
            *next_note_id += 1;
            append_u32_be(out, note_id);
            append_f64_be(out, note.z_layer);

            append_qcolor(out, note.foreground);
            append_u16_be(out, 0);
            append_qcolor(out, note.background);
            append_u16_be(out, 0);
            append_u32_be(out, note.child_notes.len() as u32);

            let end_now = out.len() as u64;
            write_u64_be(out, end_addr_pos, end_now);

            for child in &note.child_notes {
                append_text_item(out, txt_type, child, next_note_id);
            }
        }

        for &p_idx in &ordered_placement_indices {
            let placement = &scene.placements[p_idx];
            let img = &scene.images[placement.image_index];
            let item_id = *transform_id_by_placement.get(&p_idx).unwrap_or(&0);
            let base_w = img.pixel_width.max(1) as f64;
            let base_h = img.pixel_height.max(1) as f64;

            let crop = placement.crop.map(|c| c.clamped());
            let cx = crop.map_or(0.0, |c| c.x);
            let cy = crop.map_or(0.0, |c| c.y);
            let cw = crop.map_or(1.0, |c| c.width);
            let ch = crop.map_or(1.0, |c| c.height);

            let x0 = -base_w * 0.5 + cx * base_w;
            let x1 = -base_w * 0.5 + (cx + cw) * base_w;
            let y0 = -base_h * 0.5 + cy * base_h;
            let y1 = -base_h * 0.5 + (cy + ch) * base_h;

            let local_w = (x1 - x0).max(1.0);
            let local_h = (y1 - y0).max(1.0);
            let sx = (placement.width / local_w).max(0.01);
            let sy = (placement.height / local_h).max(0.01);
            let (m11, m12, m21, m22) = Self::compose_matrix(
                sx,
                sy,
                placement.rotation_degrees,
                placement.flip_horizontal,
                placement.flip_vertical,
            );

            let end_addr_pos = out.len();
            append_u64_be(&mut out, 0);
            append_u32_be(&mut out, img_type.len() as u32);
            out.extend_from_slice(&img_type);

            let safe_name = placement
                .name
                .as_deref()
                .or(img.display_name.as_deref())
                .map(str::trim)
                .filter(|s| !s.is_empty())
                .map(String::from)
                .unwrap_or_else(|| format!("Image {}", item_id + 1));
            let safe_source = placement
                .source_path
                .as_deref()
                .or(img.source_path.as_deref())
                .map(str::trim)
                .filter(|s| !s.is_empty())
                .unwrap_or(&safe_name);
            append_qstring(
                &mut out,
                if safe_source.is_empty() {
                    "CharkleAsset"
                } else {
                    safe_source
                },
            );
            append_qstring(&mut out, &safe_name);

            append_f64_be(&mut out, 1.0);
            append_matrix_6_doubles(&mut out, m11, m12, m21, m22);
            append_f64_be(&mut out, placement.center_x);
            append_f64_be(&mut out, placement.center_y);
            append_f64_be(&mut out, 1.0);

            append_u32_be(&mut out, item_id);
            append_f64_be(&mut out, placement.z_layer);
            append_matrix_6_doubles(&mut out, 1.0, 0.0, 0.0, 1.0);
            append_f64_be(&mut out, -base_w * 0.5);
            append_f64_be(&mut out, -base_h * 0.5);
            append_f64_be(&mut out, 1.0);

            let crop_pts = [(x0, y0), (x1, y0), (x1, y1), (x0, y1), (x0, y0)];
            append_u32_be(&mut out, crop_pts.len() as u32);
            for (idx, (px, py)) in crop_pts.iter().enumerate() {
                append_u32_be(&mut out, if idx == 0 { 0 } else { 1 });
                append_f64_be(&mut out, *px);
                append_f64_be(&mut out, *py);
            }

            append_f64_be(&mut out, 0.0);
            append_u32_be(&mut out, 1);
            out.push(0);
            append_i64_be(&mut out, -1);
            append_u32_be(&mut out, placement.child_notes.len() as u32);

            let end_now = out.len() as u64;
            write_u64_be(&mut out, end_addr_pos, end_now);

            for child in &placement.child_notes {
                append_text_item(&mut out, &txt_type, child, &mut next_note_id);
            }
        }

        for note in &scene.notes {
            append_text_item(&mut out, &txt_type, note, &mut next_note_id);
        }

        append_qstring(&mut out, &scene.folder_location);
        let ref_table_offset = out.len() as u64;
        write_u64_be(&mut out, 16, ref_table_offset);

        for (id, start, end) in ref_entries {
            append_u32_be(&mut out, id);
            append_u64_be(&mut out, start);
            append_u64_be(&mut out, end);
        }

        // PureRef integrity checksum: lowercase 32-char MD5 hex of bytes[108..] as UTF-16BE at [44..108]
        let mut md5 = Md5::new();
        md5.update(&out[108..]);
        let md5_hex = hex::encode(md5.finalize());
        let md5_utf16 = encode_utf16be(&md5_hex);
        if md5_utf16.len() == 64 {
            out[44..108].copy_from_slice(&md5_utf16);
        }

        Ok(out)
    }

    // -------------------------------------------------------------------------
    // Scene Builders (Assets / MoodboardDocument <-> PureRefScene)
    // -------------------------------------------------------------------------

    pub fn build_scene_from_assets(inputs: &[PureRefAssetInput]) -> PureRefScene {
        let mut blobs = Vec::with_capacity(inputs.len());
        for input in inputs {
            let Some(format) = Self::detect_image_format(&input.image_data) else {
                continue;
            };
            let Some((w, h)) = Self::inspect_image_dimensions(&input.image_data) else {
                continue;
            };
            let width = if w > 0 { w } else { input.pixel_width.max(1) };
            let height = if h > 0 { h } else { input.pixel_height.max(1) };
            blobs.push(PureRefImageBlob {
                index: blobs.len(),
                data: input.image_data.clone(),
                format,
                pixel_width: width,
                pixel_height: height,
                source_path: Some(input.file_name.clone()),
                display_name: Some(if input.title.trim().is_empty() {
                    input.file_name.clone()
                } else {
                    input.title.clone()
                }),
            });
        }
        let placements = Self::auto_layout_placements(&blobs, 340.0, 18.0);
        let canvas_rect = Self::compute_canvas_rect(&placements, &[]);
        PureRefScene {
            format_version: "1.10".to_string(),
            canvas_rect,
            zoom: 1.0,
            images: blobs,
            placements,
            notes: Vec::new(),
            ..PureRefScene::default()
        }
    }

    pub fn build_scene_from_board(
        board: &MoodboardDocument,
        assets_by_id: &HashMap<Uuid, PureRefAssetInput>,
    ) -> (PureRefScene, usize) {
        let mut sorted_nodes = board.nodes.clone();
        sorted_nodes.sort_by_key(|n| n.z_index);

        let mut min_x = f64::INFINITY;
        let mut min_y = f64::INFINITY;
        let mut max_x = f64::NEG_INFINITY;
        let mut max_y = f64::NEG_INFINITY;
        for node in &sorted_nodes {
            min_x = min_x.min(node.frame.min_x());
            min_y = min_y.min(node.frame.min_y());
            max_x = max_x.max(node.frame.max_x());
            max_y = max_y.max(node.frame.max_y());
        }
        let origin_x = if min_x.is_finite() && max_x.is_finite() {
            (min_x + max_x) * 0.5
        } else {
            0.0
        };
        let origin_y = if min_y.is_finite() && max_y.is_finite() {
            (min_y + max_y) * 0.5
        } else {
            0.0
        };

        let mut blobs: Vec<PureRefImageBlob> = Vec::new();
        let mut blob_index_by_asset_id: HashMap<Uuid, usize> = HashMap::new();
        let mut placements: Vec<PureRefImagePlacement> = Vec::new();
        let mut notes: Vec<PureRefTextNote> = Vec::new();
        let mut skipped_count = 0usize;

        for node in &sorted_nodes {
            match &node.kind {
                BoardNodeKind::AssetRef { asset_id, crop, .. } => {
                    let Some(input) = assets_by_id.get(asset_id) else {
                        skipped_count += 1;
                        continue;
                    };
                    let (Some(format), Some((w, h))) = (
                        Self::detect_image_format(&input.image_data),
                        Self::inspect_image_dimensions(&input.image_data),
                    ) else {
                        skipped_count += 1;
                        continue;
                    };
                    let blob_idx = if let Some(&existing) = blob_index_by_asset_id.get(asset_id) {
                        existing
                    } else {
                        let idx = blobs.len();
                        blobs.push(PureRefImageBlob {
                            index: idx,
                            data: input.image_data.clone(),
                            format,
                            pixel_width: w,
                            pixel_height: h,
                            source_path: Some(input.file_name.clone()),
                            display_name: Some(if input.title.trim().is_empty() {
                                input.file_name.clone()
                            } else {
                                input.title.clone()
                            }),
                        });
                        blob_index_by_asset_id.insert(*asset_id, idx);
                        idx
                    };
                    placements.push(PureRefImagePlacement {
                        image_index: blob_idx,
                        name: Some(if input.title.trim().is_empty() {
                            input.file_name.clone()
                        } else {
                            input.title.clone()
                        }),
                        source_path: Some(input.file_name.clone()),
                        center_x: node.frame.mid_x() - origin_x,
                        center_y: node.frame.mid_y() - origin_y,
                        width: node.frame.width.max(24.0),
                        height: node.frame.height.max(24.0),
                        rotation_degrees: node.rotation_degrees,
                        flip_horizontal: node.flip_horizontal,
                        flip_vertical: node.flip_vertical,
                        z_layer: f64::from(node.z_index),
                        crop: crop.filter(|c| c.is_meaningful_subregion()),
                        child_notes: Vec::new(),
                    });
                }
                BoardNodeKind::Note {
                    title,
                    text,
                    style,
                    font_size,
                } => {
                    let clean_title = title.as_deref().unwrap_or("").trim();
                    let clean_body = text.trim();
                    let combined = match (clean_title.is_empty(), clean_body.is_empty()) {
                        (true, true) => continue,
                        (true, false) => clean_body.to_string(),
                        (false, true) => clean_title.to_string(),
                        (false, false) => format!("{clean_title}\n{clean_body}"),
                    };
                    let (fg, bg) = PureRefColor::from_note_style(*style);
                    notes.push(PureRefTextNote {
                        text: combined,
                        center_x: node.frame.mid_x() - origin_x,
                        center_y: node.frame.mid_y() - origin_y,
                        scale: (font_size / 15.0).clamp(0.6, 3.0),
                        z_layer: f64::from(node.z_index),
                        foreground: fg,
                        background: bg,
                        child_notes: Vec::new(),
                    });
                }
                BoardNodeKind::GroupFrame { title, .. } => {
                    let clean_title = title.trim();
                    if clean_title.is_empty() {
                        continue;
                    }
                    let (fg, bg) = PureRefColor::from_note_style(NoteStyle::Slate);
                    notes.push(PureRefTextNote {
                        text: clean_title.to_string(),
                        center_x: node.frame.mid_x() - origin_x,
                        center_y: node.frame.min_y() + 20.0 - origin_y,
                        scale: 1.15,
                        z_layer: f64::from(node.z_index),
                        foreground: fg,
                        background: bg,
                        child_notes: Vec::new(),
                    });
                }
                BoardNodeKind::PaletteStrip { .. } => {}
            }
        }

        let canvas_rect = Self::compute_canvas_rect(&placements, &notes);
        let scene = PureRefScene {
            format_version: "1.10".to_string(),
            canvas_rect,
            zoom: 1.0,
            images: blobs,
            placements,
            notes,
            ..PureRefScene::default()
        };
        (scene, skipped_count)
    }

    pub fn build_moodboard_document(
        title: &str,
        scene: &PureRefScene,
        asset_by_image_index: &HashMap<usize, AssetRecord>,
        palette: Vec<LabColor>,
    ) -> (MoodboardDocument, usize) {
        let mut widths: Vec<f64> = scene
            .placements
            .iter()
            .map(|p| p.width)
            .filter(|w| w.is_finite() && *w > 1.0)
            .collect();
        widths.sort_by(|a, b| a.total_cmp(b));
        let median_w = if widths.is_empty() {
            320.0
        } else {
            widths[widths.len() / 2]
        };
        let layout_scale = if median_w > 540.0 {
            340.0 / median_w
        } else if median_w < 120.0 {
            240.0 / median_w.max(24.0)
        } else {
            1.0
        };

        let mut min_x = f64::INFINITY;
        let mut min_y = f64::INFINITY;
        for p in &scene.placements {
            min_x = min_x.min((p.center_x - p.width * 0.5) * layout_scale);
            min_y = min_y.min((p.center_y - p.height * 0.5) * layout_scale);
        }
        for n in &scene.notes {
            min_x = min_x.min(n.center_x * layout_scale - 110.0);
            min_y = min_y.min(n.center_y * layout_scale - 40.0);
        }
        let shift_x = if min_x.is_finite() {
            80.0 - min_x
        } else {
            80.0
        };
        let shift_y = if min_y.is_finite() {
            80.0 - min_y
        } else {
            80.0
        };

        let now = Utc::now();
        let mut nodes: Vec<BoardNode> = Vec::new();
        let mut note_count = 0usize;
        let mut order_counter = 0i32;

        let mut sorted_placements = scene.placements.clone();
        sorted_placements.sort_by(|a, b| a.z_layer.total_cmp(&b.z_layer));

        for placement in &sorted_placements {
            let Some(asset) = asset_by_image_index.get(&placement.image_index) else {
                continue;
            };
            let w = (placement.width * layout_scale).max(60.0);
            let h = (placement.height * layout_scale).max(60.0);
            let cx = placement.center_x * layout_scale + shift_x;
            let cy = placement.center_y * layout_scale + shift_y;
            let z_idx = placement.z_layer.round() as i32;

            nodes.push(BoardNode {
                id: Uuid::new_v4(),
                kind: BoardNodeKind::AssetRef {
                    asset_id: asset.id,
                    crop: placement.crop,
                    weight: 1,
                    autoplay_loop: asset.media_kind == MediaKind::AnimatedImage,
                },
                frame: BoardRect::new(cx - w * 0.5, cy - h * 0.5, w, h),
                z_index: z_idx,
                rotation_degrees: placement.rotation_degrees,
                flip_horizontal: placement.flip_horizontal,
                flip_vertical: placement.flip_vertical,
                is_locked: false,
                editorial_order: order_counter,
                updated_at: now,
            });
            order_counter += 1;

            for (child_idx, child) in placement.child_notes.iter().enumerate() {
                let clean = child.text.trim();
                if clean.is_empty() {
                    continue;
                }
                let line_count = clean.split('\n').count().max(1);
                let nw = ((clean.chars().count() as f64) * 9.5 + 48.0).clamp(160.0, 360.0);
                let nh = ((line_count as f64) * 24.0 + 44.0).clamp(64.0, 220.0);
                let ncx = cx + child.center_x * layout_scale;
                let ncy = cy
                    + if child.center_y != 0.0 {
                        child.center_y * layout_scale
                    } else {
                        h * 0.5 + 42.0 + (child_idx as f64) * 76.0
                    };
                nodes.push(BoardNode {
                    id: Uuid::new_v4(),
                    kind: BoardNodeKind::Note {
                        title: None,
                        text: clean.to_string(),
                        style: child.background.inferred_note_style(),
                        font_size: (14.0 * child.scale).clamp(12.0, 28.0),
                    },
                    frame: BoardRect::new(ncx - nw * 0.5, ncy - nh * 0.5, nw, nh),
                    z_index: (z_idx + 1).max(child.z_layer.round() as i32),
                    rotation_degrees: 0.0,
                    flip_horizontal: false,
                    flip_vertical: false,
                    is_locked: false,
                    editorial_order: order_counter,
                    updated_at: now,
                });
                order_counter += 1;
                note_count += 1;
            }
        }

        #[allow(clippy::too_many_arguments)]
        fn append_note_tree(
            list: &[PureRefTextNote],
            parent_offset_x: f64,
            parent_offset_y: f64,
            layout_scale: f64,
            now: chrono::DateTime<Utc>,
            nodes: &mut Vec<BoardNode>,
            order_counter: &mut i32,
            note_count: &mut usize,
            depth: usize,
        ) {
            if depth >= MAX_PUREREF_NOTE_DEPTH {
                return;
            }
            for note in list {
                let clean = note.text.trim();
                let ncx = note.center_x * layout_scale + parent_offset_x;
                let ncy = note.center_y * layout_scale + parent_offset_y;
                if !clean.is_empty() {
                    let lines: Vec<&str> = clean.split('\n').collect();
                    let max_line_len = lines.iter().map(|l| l.chars().count()).max().unwrap_or(12);
                    let nw = ((max_line_len as f64) * 11.0 + 52.0).clamp(170.0, 400.0);
                    let nh = ((lines.len().max(1) as f64) * 24.0 + 48.0).clamp(72.0, 280.0);
                    nodes.push(BoardNode {
                        id: Uuid::new_v4(),
                        kind: BoardNodeKind::Note {
                            title: None,
                            text: clean.to_string(),
                            style: note.background.inferred_note_style(),
                            font_size: (15.0 * note.scale).clamp(12.0, 32.0),
                        },
                        frame: BoardRect::new(ncx - nw * 0.5, ncy - nh * 0.5, nw, nh),
                        z_index: note.z_layer.round() as i32 + 10,
                        rotation_degrees: 0.0,
                        flip_horizontal: false,
                        flip_vertical: false,
                        is_locked: false,
                        editorial_order: *order_counter,
                        updated_at: now,
                    });
                    *order_counter += 1;
                    *note_count += 1;
                }
                if !note.child_notes.is_empty() {
                    append_note_tree(
                        &note.child_notes,
                        ncx,
                        ncy,
                        layout_scale,
                        now,
                        nodes,
                        order_counter,
                        note_count,
                        depth + 1,
                    );
                }
            }
        }

        append_note_tree(
            &scene.notes,
            shift_x,
            shift_y,
            layout_scale,
            now,
            &mut nodes,
            &mut order_counter,
            &mut note_count,
            0,
        );

        let mut sorted_indices: Vec<usize> = (0..nodes.len()).collect();
        sorted_indices.sort_by(|&a, &b| {
            nodes[a]
                .z_index
                .cmp(&nodes[b].z_index)
                .then_with(|| a.cmp(&b))
        });
        for (rank, idx) in sorted_indices.into_iter().enumerate() {
            nodes[idx].z_index = rank as i32;
        }

        let clean_title = title.trim();
        let mut doc = MoodboardDocument::new(if clean_title.is_empty() {
            "PureRef 场景"
        } else {
            clean_title
        });
        doc.mode = BoardLayoutMode::Freeform;
        doc.nodes = nodes;
        doc.extracted_palette = palette;
        (doc, note_count)
    }

    pub fn auto_layout_placements(
        blobs: &[PureRefImageBlob],
        target_row_height: f64,
        spacing: f64,
    ) -> Vec<PureRefImagePlacement> {
        if blobs.is_empty() {
            return Vec::new();
        }
        let target_row_width = if blobs.len() <= 3 {
            1150.0
        } else if blobs.len() <= 10 {
            1560.0
        } else {
            2100.0
        };

        let mut rows: Vec<Vec<(&PureRefImageBlob, f64)>> = Vec::new();
        let mut current_row: Vec<(&PureRefImageBlob, f64)> = Vec::new();
        let mut current_natural_w = 0.0;

        for blob in blobs {
            let aspect = (f64::from(blob.pixel_width.max(1)) / f64::from(blob.pixel_height.max(1)))
                .clamp(0.28, 3.6);
            let item_w = target_row_height * aspect;
            if !current_row.is_empty() && (current_natural_w + spacing + item_w) > target_row_width
            {
                rows.push(current_row);
                current_row = Vec::new();
                current_natural_w = 0.0;
            }
            current_row.push((blob, aspect));
            current_natural_w += if current_row.len() > 1 { spacing } else { 0.0 } + item_w;
        }
        if !current_row.is_empty() {
            rows.push(current_row);
        }

        let mut raw_placements: Vec<PureRefImagePlacement> = Vec::with_capacity(blobs.len());
        let mut y_cursor = 0.0;
        let mut z_counter = 0.0;

        for (row_idx, row) in rows.iter().enumerate() {
            let sum_aspects: f64 = row.iter().map(|(_, a)| *a).sum();
            let is_last_row = row_idx + 1 == rows.len();
            let gaps_w = spacing * (row.len().saturating_sub(1) as f64);
            let row_height = if is_last_row
                && rows.len() > 1
                && (sum_aspects * target_row_height + gaps_w) < target_row_width * 0.72
            {
                target_row_height
            } else {
                ((target_row_width - gaps_w) / sum_aspects.max(0.1))
                    .clamp(target_row_height * 0.65, target_row_height * 1.45)
            };

            let mut x_cursor = 0.0;
            for &(blob, aspect) in row {
                let w = row_height * aspect;
                let h = row_height;
                raw_placements.push(PureRefImagePlacement {
                    image_index: blob.index,
                    name: blob.display_name.clone(),
                    source_path: blob.source_path.clone(),
                    center_x: x_cursor + w * 0.5,
                    center_y: y_cursor + h * 0.5,
                    width: w,
                    height: h,
                    rotation_degrees: 0.0,
                    flip_horizontal: false,
                    flip_vertical: false,
                    z_layer: z_counter,
                    crop: None,
                    child_notes: Vec::new(),
                });
                x_cursor += w + spacing;
                z_counter += 1.0;
            }
            y_cursor += row_height + spacing;
        }

        let min_x = raw_placements
            .iter()
            .map(|p| p.center_x - p.width * 0.5)
            .reduce(f64::min)
            .unwrap_or(0.0);
        let max_x = raw_placements
            .iter()
            .map(|p| p.center_x + p.width * 0.5)
            .reduce(f64::max)
            .unwrap_or(0.0);
        let min_y = raw_placements
            .iter()
            .map(|p| p.center_y - p.height * 0.5)
            .reduce(f64::min)
            .unwrap_or(0.0);
        let max_y = raw_placements
            .iter()
            .map(|p| p.center_y + p.height * 0.5)
            .reduce(f64::max)
            .unwrap_or(0.0);
        let cx = (min_x + max_x) * 0.5;
        let cy = (min_y + max_y) * 0.5;

        for p in &mut raw_placements {
            p.center_x -= cx;
            p.center_y -= cy;
        }
        raw_placements
    }

    // -------------------------------------------------------------------------
    // Matrix & Image Utilities
    // -------------------------------------------------------------------------

    pub fn compose_matrix(
        sx: f64,
        sy: f64,
        rotation_degrees: f64,
        flip_horizontal: bool,
        flip_vertical: bool,
    ) -> (f64, f64, f64, f64) {
        let theta = rotation_degrees.to_radians();
        let cos_t = theta.cos();
        let sin_t = theta.sin();
        let fx = if flip_horizontal { -1.0 } else { 1.0 };
        let fy = if flip_vertical { -1.0 } else { 1.0 };
        (
            sx * fx * cos_t,
            sx * fx * sin_t,
            -sy * fy * sin_t,
            sy * fy * cos_t,
        )
    }

    pub fn decompose_matrix(m: (f64, f64, f64, f64)) -> (f64, f64, f64, bool, bool) {
        let (m11, m12, m21, m22) = m;
        let sx = m11.hypot(m12).max(0.001);
        let sy = m21.hypot(m22).max(0.001);
        let det = m11 * m22 - m12 * m21;

        let mut flip_h = false;
        let mut flip_v = false;
        let radians = if det < 0.0 {
            flip_h = true;
            (-m12).atan2(-m11)
        } else {
            m12.atan2(m11)
        };
        let mut degrees = radians.to_degrees();
        if flip_h && degrees.abs() > 135.0 {
            flip_h = false;
            flip_v = true;
            degrees = if degrees > 0.0 {
                degrees - 180.0
            } else {
                degrees + 180.0
            };
        }
        if degrees.abs() < 0.05 {
            degrees = 0.0;
        }
        (sx, sy, degrees, flip_h, flip_v)
    }

    pub fn detect_image_format(data: &[u8]) -> Option<PureRefImageFormat> {
        if data.len() < 12 {
            return None;
        }
        if data[..8] == PNG_SIGNATURE {
            return Some(PureRefImageFormat::Png);
        }
        if data[0] == 0xFF && data[1] == 0xD8 && data[2] == 0xFF {
            return Some(PureRefImageFormat::Jpeg);
        }
        if &data[0..4] == b"RIFF" && &data[8..12] == b"WEBP" {
            return Some(PureRefImageFormat::Webp);
        }
        if &data[0..4] == b"GIF8" && (data[4] == b'7' || data[4] == b'9') && data[5] == b'a' {
            return Some(PureRefImageFormat::Gif);
        }
        None
    }

    pub fn inspect_image_dimensions(data: &[u8]) -> Option<(u32, u32)> {
        let reader = image::ImageReader::new(Cursor::new(data))
            .with_guessed_format()
            .ok()?;
        let (w, h) = reader.into_dimensions().ok()?;
        if w == 0 || h == 0 {
            return None;
        }
        if matches!(read_exif_orientation(data), Some(5..=8)) {
            Some((h, w))
        } else {
            Some((w, h))
        }
    }

    pub fn convert_to_png(data: &[u8]) -> Option<Vec<u8>> {
        let raw_img = image::load_from_memory(data).ok()?;
        let img = match read_exif_orientation(data) {
            Some(2) => raw_img.fliph(),
            Some(3) => raw_img.rotate180(),
            Some(4) => raw_img.flipv(),
            Some(5) => raw_img.rotate90().fliph(),
            Some(6) => raw_img.rotate90(),
            Some(7) => raw_img.rotate270().fliph(),
            Some(8) => raw_img.rotate270(),
            _ => raw_img,
        };
        let mut buf = Vec::new();
        img.write_to(&mut Cursor::new(&mut buf), image::ImageFormat::Png)
            .ok()?;
        Some(buf)
    }

    fn compute_canvas_rect(
        placements: &[PureRefImagePlacement],
        notes: &[PureRefTextNote],
    ) -> BoardRect {
        let mut min_x = -2000.0f64;
        let mut min_y = -2000.0f64;
        let mut max_x = 2000.0f64;
        let mut max_y = 2000.0f64;
        for p in placements {
            min_x = min_x.min(p.center_x - p.width * 0.5 - 600.0);
            min_y = min_y.min(p.center_y - p.height * 0.5 - 600.0);
            max_x = max_x.max(p.center_x + p.width * 0.5 + 600.0);
            max_y = max_y.max(p.center_y + p.height * 0.5 + 600.0);
        }
        for n in notes {
            min_x = min_x.min(n.center_x - 600.0);
            min_y = min_y.min(n.center_y - 600.0);
            max_x = max_x.max(n.center_x + 600.0);
            max_y = max_y.max(n.center_y + 600.0);
        }
        BoardRect::new(
            min_x.min(-10000.0),
            min_y.min(-10000.0),
            (max_x - min_x).max(20000.0),
            (max_y - min_y).max(20000.0),
        )
    }
}

// -----------------------------------------------------------------------------
// Binary Stream Walkers (PNG / JPEG / GIF) & EXIF Orientation Helper
// -----------------------------------------------------------------------------

fn read_exif_orientation(data: &[u8]) -> Option<u32> {
    let mut cursor = Cursor::new(data);
    let exif_data = exif::Reader::new().read_from_container(&mut cursor).ok()?;
    exif_data
        .get_field(exif::Tag::Orientation, exif::In::PRIMARY)
        .and_then(|f| f.value.get_uint(0))
}

fn walk_png_end(bytes: &[u8], start: usize) -> Option<usize> {
    let mut pos = start + 8;
    let count = bytes.len();
    let mut saw_ihdr = false;
    while pos + 12 <= count {
        let chunk_len = read_u32_be(bytes, pos) as usize;
        if chunk_len > 128 * 1024 * 1024 {
            return None;
        }
        let t = &bytes[(pos + 4)..(pos + 8)];
        if !t.iter().all(|b| b.is_ascii_alphabetic()) {
            return None;
        }
        let next_pos = pos.checked_add(12)?.checked_add(chunk_len)?;
        if next_pos > count {
            return None;
        }
        if t == b"IHDR" {
            saw_ihdr = true;
        }
        if t == b"IEND" {
            return saw_ihdr.then_some(next_pos);
        }
        pos = next_pos;
    }
    None
}

fn walk_jpeg_end(bytes: &[u8], start: usize) -> Option<usize> {
    let mut pos = start + 2;
    let count = bytes.len();
    let mut saw_sof = false;
    let mut saw_sos = false;
    while pos + 2 <= count {
        if bytes[pos] != 0xFF {
            return None;
        }
        while pos < count && bytes[pos] == 0xFF {
            pos += 1;
        }
        if pos >= count {
            return None;
        }
        let marker = bytes[pos];
        pos += 1;
        if marker == 0xD9 {
            return (saw_sof && saw_sos).then_some(pos);
        }
        if marker == 0x01 || (0xD0..=0xD8).contains(&marker) {
            continue;
        }
        if pos + 2 > count {
            return None;
        }
        let seg_len = read_u16_be(bytes, pos) as usize;
        if seg_len < 2 || pos + seg_len > count {
            return None;
        }
        if matches!(
            marker,
            0xC0..=0xC3 | 0xC5..=0xC7 | 0xC9..=0xCB | 0xCD..=0xCF
        ) {
            saw_sof = true;
        }
        pos += seg_len;
        if marker == 0xDA {
            saw_sos = true;
            while pos + 1 < count {
                if bytes[pos] == 0xFF {
                    let next = bytes[pos + 1];
                    if next == 0x00 || (0xD0..=0xD7).contains(&next) {
                        pos += 2;
                        continue;
                    }
                    if next == 0xFF {
                        pos += 1;
                        continue;
                    }
                    if next == 0xD9 {
                        return saw_sof.then_some(pos + 2);
                    }
                    break;
                }
                pos += 1;
            }
        }
    }
    None
}

fn walk_gif_end(bytes: &[u8], start: usize) -> Option<usize> {
    let count = bytes.len();
    if start + 13 > count {
        return None;
    }
    let packed = bytes[start + 10];
    let mut pos = start + 13;
    if (packed & 0x80) != 0 {
        let gct_size = 3 * (1usize << ((packed & 0x07) as usize + 1));
        pos += gct_size;
    }
    if pos >= count {
        return None;
    }

    let skip_sub_blocks = |pos: &mut usize| -> bool {
        while *pos < count {
            let block_len = bytes[*pos] as usize;
            *pos += 1;
            if block_len == 0 {
                return true;
            }
            *pos += block_len;
            if *pos > count {
                return false;
            }
        }
        false
    };

    while pos < count {
        let intro = bytes[pos];
        pos += 1;
        match intro {
            0x3B => return Some(pos),
            0x21 => {
                if pos >= count {
                    return None;
                }
                pos += 1;
                if !skip_sub_blocks(&mut pos) {
                    return None;
                }
            }
            0x2C => {
                if pos + 9 > count {
                    return None;
                }
                let img_packed = bytes[pos + 8];
                pos += 9;
                if (img_packed & 0x80) != 0 {
                    let lct_size = 3 * (1usize << ((img_packed & 0x07) as usize + 1));
                    pos += lct_size;
                }
                if pos >= count {
                    return None;
                }
                pos += 1;
                if !skip_sub_blocks(&mut pos) {
                    return None;
                }
            }
            _ => return None,
        }
    }
    None
}

// -----------------------------------------------------------------------------
// Low-Level Big-Endian QDataStream Helpers
// -----------------------------------------------------------------------------

fn read_u16_be(b: &[u8], i: usize) -> u16 {
    u16::from_be_bytes([b[i], b[i + 1]])
}

fn read_u32_be(b: &[u8], i: usize) -> u32 {
    u32::from_be_bytes([b[i], b[i + 1], b[i + 2], b[i + 3]])
}

fn read_u32_le(b: &[u8], i: usize) -> u32 {
    u32::from_le_bytes([b[i], b[i + 1], b[i + 2], b[i + 3]])
}

fn read_i32_be(b: &[u8], i: usize) -> i32 {
    i32::from_be_bytes([b[i], b[i + 1], b[i + 2], b[i + 3]])
}

fn read_u64_be(b: &[u8], i: usize) -> u64 {
    u64::from_be_bytes([
        b[i],
        b[i + 1],
        b[i + 2],
        b[i + 3],
        b[i + 4],
        b[i + 5],
        b[i + 6],
        b[i + 7],
    ])
}

fn read_f64_be(b: &[u8], i: usize) -> f64 {
    f64::from_bits(read_u64_be(b, i))
}

fn read_matrix_6_doubles(b: &[u8], pos: &mut usize) -> (f64, f64, f64, f64) {
    let m11 = read_f64_be(b, *pos);
    let m12 = read_f64_be(b, *pos + 8);
    let m21 = read_f64_be(b, *pos + 24);
    let m22 = read_f64_be(b, *pos + 32);
    *pos += 48;
    (
        if m11.is_finite() { m11 } else { 1.0 },
        if m12.is_finite() { m12 } else { 0.0 },
        if m21.is_finite() { m21 } else { 0.0 },
        if m22.is_finite() { m22 } else { 1.0 },
    )
}

fn read_optional_qstring(b: &[u8], pos: &mut usize, limit: usize) -> Option<String> {
    if *pos + 4 > limit {
        return None;
    }
    let signed_len = read_i32_be(b, *pos);
    *pos += 4;
    if signed_len < 0 {
        return None;
    }
    let byte_len = signed_len as usize;
    if byte_len > 0 && (byte_len > limit - *pos || byte_len % 2 != 0) {
        return None;
    }
    if byte_len == 0 {
        return Some(String::new());
    }
    let s = decode_utf16be(&b[*pos..(*pos + byte_len)]);
    *pos += byte_len;
    Some(s)
}

fn read_qcolor(b: &[u8], pos: &mut usize) -> PureRefColor {
    let spec = b[*pos] as i8;
    *pos += 1;
    let alpha = f64::from(read_u16_be(b, *pos)) / 65535.0;
    *pos += 2;
    let c1 = f64::from(read_u16_be(b, *pos));
    *pos += 2;
    let c2 = f64::from(read_u16_be(b, *pos));
    *pos += 2;
    let c3 = f64::from(read_u16_be(b, *pos));
    *pos += 2;

    if spec == 2 {
        let mut h = (c1 / 35900.0) % 1.0;
        if h < 0.0 {
            h += 1.0;
        }
        let s = (c2 / 65535.0).clamp(0.0, 1.0);
        let v = (c3 / 65535.0).clamp(0.0, 1.0);
        let (r, g, bl) = hsv_to_rgb(h, s, v);
        PureRefColor::new(r, g, bl, alpha)
    } else {
        PureRefColor::new(c1 / 65535.0, c2 / 65535.0, c3 / 65535.0, alpha)
    }
}

fn hsv_to_rgb(h: f64, s: f64, v: f64) -> (f64, f64, f64) {
    if s <= 0.0 {
        return (v, v, v);
    }
    let sector = h * 6.0;
    let i = (sector.floor() as i32).rem_euclid(6);
    let f = sector - sector.floor();
    let p = v * (1.0 - s);
    let q = v * (1.0 - s * f);
    let t = v * (1.0 - s * (1.0 - f));
    match i {
        0 => (v, t, p),
        1 => (q, v, p),
        2 => (p, v, t),
        3 => (p, q, v),
        4 => (t, p, v),
        _ => (v, p, q),
    }
}

fn decode_utf16be(slice: &[u8]) -> String {
    let mut units = Vec::with_capacity(slice.len() / 2);
    let mut i = 0;
    while i + 1 < slice.len() {
        units.push(u16::from_be_bytes([slice[i], slice[i + 1]]));
        i += 2;
    }
    String::from_utf16_lossy(&units)
}

fn encode_utf16be(s: &str) -> Vec<u8> {
    let mut out = Vec::with_capacity(s.len() * 2);
    for u in s.encode_utf16() {
        out.extend_from_slice(&u.to_be_bytes());
    }
    out
}

fn write_u16_be(out: &mut [u8], i: usize, v: u16) {
    out[i..(i + 2)].copy_from_slice(&v.to_be_bytes());
}

fn write_u32_be(out: &mut [u8], i: usize, v: u32) {
    out[i..(i + 4)].copy_from_slice(&v.to_be_bytes());
}

fn write_i32_be(out: &mut [u8], i: usize, v: i32) {
    out[i..(i + 4)].copy_from_slice(&v.to_be_bytes());
}

fn write_u64_be(out: &mut [u8], i: usize, v: u64) {
    out[i..(i + 8)].copy_from_slice(&v.to_be_bytes());
}

fn write_f64_be(out: &mut [u8], i: usize, v: f64) {
    write_u64_be(out, i, v.to_bits());
}

fn append_u16_be(out: &mut Vec<u8>, v: u16) {
    out.extend_from_slice(&v.to_be_bytes());
}

fn append_u32_be(out: &mut Vec<u8>, v: u32) {
    out.extend_from_slice(&v.to_be_bytes());
}

fn append_u64_be(out: &mut Vec<u8>, v: u64) {
    out.extend_from_slice(&v.to_be_bytes());
}

fn append_i64_be(out: &mut Vec<u8>, v: i64) {
    out.extend_from_slice(&v.to_be_bytes());
}

fn append_f64_be(out: &mut Vec<u8>, v: f64) {
    append_u64_be(out, v.to_bits());
}

fn append_qstring(out: &mut Vec<u8>, s: &str) {
    let encoded = encode_utf16be(s);
    append_u32_be(out, encoded.len() as u32);
    out.extend_from_slice(&encoded);
}

fn append_matrix_6_doubles(out: &mut Vec<u8>, m11: f64, m12: f64, m21: f64, m22: f64) {
    append_f64_be(out, m11);
    append_f64_be(out, m12);
    append_f64_be(out, 0.0);
    append_f64_be(out, m21);
    append_f64_be(out, m22);
    append_f64_be(out, 0.0);
}

fn append_qcolor(out: &mut Vec<u8>, color: PureRefColor) {
    out.push(1); // QColor::Rgb
    append_u16_be(out, (color.alpha.clamp(0.0, 1.0) * 65535.0).round() as u16);
    append_u16_be(out, (color.r.clamp(0.0, 1.0) * 65535.0).round() as u16);
    append_u16_be(out, (color.g.clamp(0.0, 1.0) * 65535.0).round() as u16);
    append_u16_be(out, (color.b.clamp(0.0, 1.0) * 65535.0).round() as u16);
}

/// Ensures unused imports are clean even if some fields evolve.
#[allow(dead_code)]
fn _assert_types() -> (PathBuf, fn(&Uuid) -> String) {
    let _ = upper_uuid::serialize::<serde_json::value::Serializer>;
    (PathBuf::new(), format_swift_uuid)
}
