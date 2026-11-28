//! Camera EXIF/TIFF/GPS extraction and AI generation prompt/parameter parser.
//!
//! Mirrors `Sources/CharkleCore/Media/ImageMetadataExtractor.swift` covering:
//! - Camera EXIF / TIFF / GPS via `kamadak-exif`
//! - PNG binary text chunks (`tEXt`, `iTXt`, `zTXt` with zlib inflation)
//! - XMP & EXIF `UserComment` / `ImageDescription`
//! - Stable Diffusion (A1111/Forge/Civitai), ComfyUI node graphs, NovelAI, InvokeAI,
//!   Midjourney, SwarmUI, Draw Things, and generic prompt metadata.

use std::collections::{BTreeMap, HashMap, HashSet};
use std::fs::File;
use std::io::{BufReader, Cursor, Read};
use std::path::Path;

use exif::{In, Tag, Value as ExifValue};
use flate2::read::ZlibDecoder;
use serde_json::Value as JsonValue;

use crate::models::core::{AIGenerationMetadata, PhotoExifMetadata};

const MAX_BINARY_SCAN_BYTES: usize = 2 * 1024 * 1024;
const PNG_SIGNATURE: [u8; 8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];

#[derive(Debug, Clone, Default, PartialEq)]
pub struct ExtractedImageMetadata {
    pub photo_exif: Option<PhotoExifMetadata>,
    pub ai_generation: Option<AIGenerationMetadata>,
}

pub struct ImageMetadataExtractor;

impl ImageMetadataExtractor {
    /// Extracts both camera EXIF and embedded AI generation prompt metadata from `path`.
    pub fn extract_from_path(path: &Path) -> ExtractedImageMetadata {
        let Ok(mut file) = File::open(path) else {
            return ExtractedImageMetadata::default();
        };
        let mut buf = Vec::new();
        let _ = (&mut file)
            .take(MAX_BINARY_SCAN_BYTES as u64)
            .read_to_end(&mut buf);
        Self::extract_from_bytes(&buf)
    }

    /// Extracts both camera EXIF and embedded AI generation prompt metadata from raw image bytes.
    pub fn extract_from_bytes(data: &[u8]) -> ExtractedImageMetadata {
        let (photo_exif, exif_text_candidates) = Self::parse_exif_and_comments(data);
        let png_chunks = if data.starts_with(&PNG_SIGNATURE) {
            Self::extract_png_text_chunks(data)
        } else {
            HashMap::new()
        };
        let xmp_candidates = Self::extract_xmp_candidates(data, &png_chunks);

        let mut all_text_candidates = exif_text_candidates;
        all_text_candidates.extend(xmp_candidates);

        let ai_generation = Self::extract_ai_generation(&png_chunks, &all_text_candidates);

        ExtractedImageMetadata {
            photo_exif: photo_exif.filter(|e| !e.is_empty()),
            ai_generation: ai_generation.filter(|a| !a.is_empty()),
        }
    }

    /// Detects whether PNG bytes contain an `acTL` animation control chunk (APNG).
    pub fn is_animated_png(data: &[u8]) -> bool {
        if data.len() <= 16 || !data.starts_with(&PNG_SIGNATURE) {
            return false;
        }
        let mut offset = 8usize;
        while offset + 12 <= data.len() {
            let len = u32::from_be_bytes([
                data[offset],
                data[offset + 1],
                data[offset + 2],
                data[offset + 3],
            ]) as usize;
            let chunk_type = &data[offset + 4..offset + 8];
            if chunk_type == b"acTL" {
                return true;
            }
            if chunk_type == b"IDAT" || chunk_type == b"IEND" {
                return false;
            }
            let Some(next) = offset.checked_add(12).and_then(|v| v.checked_add(len)) else {
                return false;
            };
            offset = next;
        }
        false
    }

    // =========================================================================
    // 1. Camera EXIF / TIFF / GPS Extraction
    // =========================================================================

    fn parse_exif_and_comments(data: &[u8]) -> (Option<PhotoExifMetadata>, Vec<(String, String)>) {
        let mut reader = BufReader::new(Cursor::new(data));
        let Ok(exif_data) = exif::Reader::new().read_from_container(&mut reader) else {
            return (None, Vec::new());
        };

        let get_str = |tag: Tag| -> Option<String> {
            let field = exif_data.get_field(tag, In::PRIMARY)?;
            let raw = match &field.value {
                ExifValue::Ascii(items) => items
                    .iter()
                    .filter_map(|b| std::str::from_utf8(b).ok())
                    .map(|s| s.trim_matches('\0').trim())
                    .find(|s| !s.is_empty())
                    .map(String::from),
                _ => Some(
                    field
                        .display_value()
                        .to_string()
                        .trim_matches('"')
                        .trim()
                        .to_string(),
                ),
            }?;
            clean_str(&raw)
        };

        let get_f64 = |tag: Tag| -> Option<f64> {
            let field = exif_data.get_field(tag, In::PRIMARY)?;
            match &field.value {
                ExifValue::Rational(vals) => vals
                    .first()
                    .filter(|r| r.denom != 0)
                    .map(|r| r.num as f64 / r.denom as f64),
                ExifValue::SRational(vals) => vals
                    .first()
                    .filter(|r| r.denom != 0)
                    .map(|r| r.num as f64 / r.denom as f64),
                ExifValue::Float(vals) => vals.first().map(|&v| v as f64),
                ExifValue::Double(vals) => vals.first().copied(),
                _ => field.value.get_uint(0).map(|v| v as f64),
            }
            .filter(|v| v.is_finite())
        };

        let get_i32 = |tag: Tag| -> Option<i32> {
            let field = exif_data.get_field(tag, In::PRIMARY)?;
            field.value.get_uint(0).map(|v| v as i32)
        };

        let raw_date = get_str(Tag::DateTimeOriginal)
            .or_else(|| get_str(Tag::DateTimeDigitized))
            .or_else(|| get_str(Tag::DateTime));
        let offset = get_str(Tag::OffsetTimeOriginal);
        let captured_at = format_exif_date(raw_date.as_deref(), offset.as_deref());

        let exposure_time = get_f64(Tag::ExposureTime).and_then(Self::format_exposure_time);
        let metering_mode = get_i32(Tag::MeteringMode).and_then(metering_mode_label);
        let flash_fired = get_i32(Tag::Flash).map(|v| (v & 0x1) != 0);
        let white_balance = get_i32(Tag::WhiteBalance).map(|v| {
            if v == 0 {
                "自动".to_string()
            } else {
                "手动".to_string()
            }
        });
        let dpi_width = get_f64(Tag::XResolution).map(|v| v.round() as i32);

        let gps_coord = |tag: Tag, ref_tag: Tag, neg_ref: &str| -> Option<f64> {
            let field = exif_data.get_field(tag, In::PRIMARY)?;
            let ExifValue::Rational(vals) = &field.value else {
                return None;
            };
            if vals.len() < 3 || vals.iter().any(|r| r.denom == 0) {
                return None;
            }
            let d = vals[0].num as f64 / vals[0].denom as f64;
            let m = vals[1].num as f64 / vals[1].denom as f64;
            let s = vals[2].num as f64 / vals[2].denom as f64;
            let mut deg = d + m / 60.0 + s / 3600.0;
            if get_str(ref_tag)
                .as_deref()
                .is_some_and(|r| r.eq_ignore_ascii_case(neg_ref))
            {
                deg = -deg.abs();
            }
            Some(deg)
        };

        let latitude = gps_coord(Tag::GPSLatitude, Tag::GPSLatitudeRef, "S");
        let longitude = gps_coord(Tag::GPSLongitude, Tag::GPSLongitudeRef, "W");
        let altitude_meters = get_f64(Tag::GPSAltitude).map(|alt| {
            if get_i32(Tag::GPSAltitudeRef) == Some(1) {
                -alt.abs()
            } else {
                alt
            }
        });

        let meta = PhotoExifMetadata {
            camera_make: get_str(Tag::Make),
            camera_model: get_str(Tag::Model),
            lens_model: get_str(Tag::LensModel),
            captured_at,
            exposure_time,
            f_number: get_f64(Tag::FNumber),
            iso: get_i32(Tag::PhotographicSensitivity),
            focal_length_mm: get_f64(Tag::FocalLength),
            focal_length_35mm: get_i32(Tag::FocalLengthIn35mmFilm),
            exposure_bias_ev: get_f64(Tag::ExposureBiasValue),
            metering_mode,
            flash_fired,
            white_balance,
            color_profile: None,
            bit_depth: None,
            dpi_width,
            software: get_str(Tag::Software),
            artist: get_str(Tag::Artist),
            copyright: get_str(Tag::Copyright),
            latitude,
            longitude,
            altitude_meters,
        };

        let mut text_candidates = Vec::new();
        if let Some(uc_field) = exif_data.get_field(Tag::UserComment, In::PRIMARY) {
            if let Some(decoded) = decode_exif_user_comment(&uc_field.value) {
                text_candidates.push(("EXIF UserComment".to_string(), decoded));
            }
        }
        if let Some(desc) = get_str(Tag::ImageDescription) {
            text_candidates.push(("TIFF Description".to_string(), desc));
        }

        let photo = if meta.is_empty() { None } else { Some(meta) };
        (photo, text_candidates)
    }

    pub fn format_exposure_time(seconds: f64) -> Option<String> {
        if !seconds.is_finite() || seconds <= 0.0 {
            return None;
        }
        if seconds >= 0.5 {
            if (seconds - seconds.round()).abs() < 0.05 {
                return Some(format!("{}s", seconds.round() as i64));
            }
            return Some(format!("{seconds:.1}s"));
        }
        let denom = ((1.0 / seconds).round() as i64).max(1);
        Some(format!("1/{denom}s"))
    }

    // =========================================================================
    // 2. PNG Binary Text Chunk Scanner (`tEXt`, `iTXt`, `zTXt`)
    // =========================================================================

    pub fn extract_png_text_chunks(data: &[u8]) -> HashMap<String, String> {
        const MAX_PNG_TEXT_CHUNKS: usize = 64;
        const MAX_TOTAL_PNG_TEXT_BYTES: usize = 16 * 1024 * 1024;
        let mut chunks = HashMap::new();
        let mut total_decoded_bytes: usize = 0;
        if data.len() <= 16 || !data.starts_with(&PNG_SIGNATURE) {
            return chunks;
        }
        let mut offset = 8usize;
        while offset + 12 <= data.len() && chunks.len() < MAX_PNG_TEXT_CHUNKS {
            let len = u32::from_be_bytes([
                data[offset],
                data[offset + 1],
                data[offset + 2],
                data[offset + 3],
            ]) as usize;
            let data_start = offset + 8;
            let Some(data_end) = data_start.checked_add(len) else {
                break;
            };
            if data_end + 4 > data.len() {
                break;
            }
            let chunk_type = &data[offset + 4..offset + 8];
            if chunk_type == b"IEND" {
                break;
            }
            if len > 0 && len <= 1_500_000 {
                let payload = &data[data_start..data_end];
                let decoded = match chunk_type {
                    b"tEXt" => decode_png_text(payload),
                    b"iTXt" => decode_png_itxt(payload),
                    b"zTXt" => decode_png_ztxt(payload),
                    _ => None,
                };
                if let Some((k, v)) = decoded {
                    let added = k.len().saturating_add(v.len());
                    if total_decoded_bytes.saturating_add(added) > MAX_TOTAL_PNG_TEXT_BYTES {
                        break;
                    }
                    total_decoded_bytes = total_decoded_bytes.saturating_add(added);
                    chunks.insert(k, v);
                }
            }
            offset = data_end + 4;
        }
        chunks
    }

    // =========================================================================
    // 3. XMP Text Extraction (PNG XMP chunk + raw JPEG/WebP XMP packet scan)
    // =========================================================================

    fn extract_xmp_candidates(
        data: &[u8],
        png_chunks: &HashMap<String, String>,
    ) -> Vec<(String, String)> {
        let mut out = Vec::new();
        let mut xmp_strings = Vec::new();
        for (k, v) in png_chunks {
            if k.eq_ignore_ascii_case("xml:com.adobe.xmp") {
                xmp_strings.push(v.clone());
            }
        }
        if xmp_strings.is_empty() {
            if let Some(raw_xmp) = scan_embedded_xmp_packet(data) {
                xmp_strings.push(raw_xmp);
            }
        }
        for xml in xmp_strings {
            if let Some(uc) = extract_xml_tag_text(&xml, "exif:UserComment") {
                out.push(("XMP UserComment".to_string(), uc));
            }
            if let Some(desc) = extract_xml_tag_text(&xml, "dc:description") {
                out.push(("XMP Description".to_string(), desc));
            }
        }
        out
    }

    // =========================================================================
    // 4. AI Generation Prompt & Parameters Parsers
    // =========================================================================

    fn extract_ai_generation(
        png_chunks: &HashMap<String, String>,
        text_candidates: &[(String, String)],
    ) -> Option<AIGenerationMetadata> {
        let mut lower_png: HashMap<String, &str> = HashMap::new();
        for (k, v) in png_chunks {
            lower_png
                .entry(k.to_ascii_lowercase())
                .or_insert(v.as_str());
        }

        // A. Stable Diffusion WebUI (A1111 / Forge / reForge / Civitai)
        if let Some(params) = lower_png.get("parameters").map(|s| s.trim()) {
            if !params.is_empty() {
                if let Some(parsed) = Self::parse_a1111_parameters(params) {
                    return Some(parsed);
                }
            }
        }

        // B. ComfyUI PNG `prompt` (API graph JSON)
        if let Some(prompt_json) = lower_png.get("prompt").map(|s| s.trim()) {
            if prompt_json.starts_with('{') {
                if let Some(parsed) = Self::parse_comfyui_prompt_json(prompt_json) {
                    return Some(parsed);
                }
            }
        }

        // C. NovelAI PNG (`Software == "NovelAI"` or `Comment` JSON with `uc` / `v4_prompt`)
        if let Some(comment) = lower_png.get("comment").map(|s| s.trim()) {
            let is_nai_software = lower_png
                .get("software")
                .is_some_and(|s| s.to_ascii_lowercase().contains("novelai"));
            if comment.starts_with('{')
                && (is_nai_software
                    || comment.contains("\"uc\"")
                    || comment.contains("\"v4_prompt\""))
            {
                if let Some(parsed) =
                    Self::parse_novelai_metadata(comment, lower_png.get("description").copied())
                {
                    return Some(parsed);
                }
            }
        }

        // D. InvokeAI
        if let Some(invoke_json) = lower_png
            .get("invokeai_metadata")
            .or_else(|| lower_png.get("sd-metadata"))
            .map(|s| s.trim())
        {
            if invoke_json.starts_with('{') {
                if let Some(parsed) = Self::parse_invokeai_metadata(invoke_json) {
                    return Some(parsed);
                }
            }
        }

        // E. Midjourney PNG `Description`
        if let Some(desc) = lower_png.get("description").map(|s| s.trim()) {
            if !desc.is_empty() {
                let author = lower_png.get("author").copied().unwrap_or("");
                if author.to_ascii_lowercase().contains("midjourney")
                    || desc.contains("Job ID:")
                    || desc.contains("--v ")
                    || desc.contains("--ar ")
                    || desc.contains("--niji")
                {
                    return Some(Self::parse_midjourney_description(desc));
                }
            }
        }

        // F. EXIF UserComment / XMP / TIFF Description
        for (_, candidate) in text_candidates {
            let trimmed = candidate.trim();
            if trimmed.is_empty() {
                continue;
            }
            if trimmed.starts_with('{') {
                if let Some(parsed) = Self::parse_generic_ai_json(trimmed) {
                    return Some(parsed);
                }
            }
            if trimmed.contains("Steps:")
                || trimmed.contains("Negative prompt:")
                || trimmed.contains("Sampler:")
            {
                if let Some(parsed) = Self::parse_a1111_parameters(trimmed) {
                    return Some(parsed);
                }
            }
            if trimmed.contains("Job ID:") || trimmed.contains("--v ") || trimmed.contains("--niji")
            {
                return Some(Self::parse_midjourney_description(trimmed));
            }
        }

        // G. Plain text PNG `prompt`
        if let Some(plain_prompt) = lower_png.get("prompt").map(|s| s.trim()) {
            if !plain_prompt.is_empty() && !plain_prompt.starts_with('{') {
                return Some(AIGenerationMetadata {
                    generator: Some(
                        lower_png
                            .get("software")
                            .copied()
                            .unwrap_or("AI 生成")
                            .to_string(),
                    ),
                    prompt: Some(plain_prompt.to_string()),
                    negative_prompt: lower_png
                        .get("negative_prompt")
                        .or_else(|| lower_png.get("negative prompt"))
                        .map(|s| s.trim().to_string())
                        .filter(|s| !s.is_empty()),
                    raw_parameters: Some(plain_prompt.chars().take(8000).collect()),
                    ..AIGenerationMetadata::default()
                });
            }
        }

        None
    }

    /// Parses A1111 / Forge / reForge / Civitai `parameters` text block.
    pub fn parse_a1111_parameters(raw: &str) -> Option<AIGenerationMetadata> {
        let normalized = raw
            .replace("\r\n", "\n")
            .replace('\r', "\n")
            .trim()
            .to_string();
        if normalized.is_empty() {
            return None;
        }
        let lines: Vec<&str> = normalized.split('\n').collect();
        let mut param_line_idx: Option<usize> = None;
        for idx in (0..lines.len()).rev() {
            let line = lines[idx].trim();
            if line.starts_with("Steps:") || (line.contains("Sampler:") && line.contains("Seed:")) {
                param_line_idx = Some(idx);
                break;
            }
        }

        let (header_text, param_line) = if let Some(idx) = param_line_idx {
            (lines[..idx].join("\n"), lines[idx..].join(", "))
        } else {
            (lines.join("\n"), String::new())
        };

        let (positive_prompt, negative_prompt) =
            if let Some(pos) = find_ascii_case_insensitive(&header_text, "Negative prompt:") {
                let pos_part = header_text[..pos].trim().to_string();
                let neg_part = header_text[pos + "Negative prompt:".len()..]
                    .trim()
                    .to_string();
                (
                    pos_part,
                    if neg_part.is_empty() {
                        None
                    } else {
                        Some(neg_part)
                    },
                )
            } else {
                (header_text.trim().to_string(), None)
            };

        let kv = parse_comma_separated_kv(&param_line);
        let steps = kv.get("Steps").and_then(|v| v.parse::<i32>().ok());
        let sampler = kv.get("Sampler").cloned();
        let scheduler = kv
            .get("Schedule type")
            .or_else(|| kv.get("Scheduler"))
            .cloned();
        let cfg_scale = kv
            .get("CFG scale")
            .or_else(|| kv.get("Distilled CFG Scale"))
            .and_then(|v| v.parse::<f64>().ok());
        let seed = kv.get("Seed").cloned();
        let size_text = kv.get("Size").map(|s| s.replace('x', " × "));
        let model_name = kv.get("Model").cloned();
        let model_hash = kv.get("Model hash").cloned();
        let clip_skip = kv.get("Clip skip").and_then(|v| v.parse::<i32>().ok());

        let mut loras = extract_lora_tags(&positive_prompt);
        if let Some(lora_hashes) = kv.get("Lora hashes") {
            for pair in lora_hashes.split(',') {
                let name = pair
                    .split(':')
                    .next()
                    .unwrap_or("")
                    .trim_matches(|c: char| c.is_whitespace() || c == '"');
                if !name.is_empty() && !loras.iter().any(|l| l == name) {
                    loras.push(name.to_string());
                }
            }
        }

        let known_keys: HashSet<&str> = [
            "Steps",
            "Sampler",
            "Schedule type",
            "Scheduler",
            "CFG scale",
            "Seed",
            "Size",
            "Model",
            "Model hash",
            "Clip skip",
            "Lora hashes",
        ]
        .into_iter()
        .collect();
        let mut extras = BTreeMap::new();
        for (k, v) in &kv {
            if !known_keys.contains(k.as_str()) && extras.len() < 8 {
                extras.insert(k.clone(), v.clone());
            }
        }

        let generator = match kv.get("Version").filter(|v| !v.is_empty()) {
            Some(version) => {
                let lower = version.to_ascii_lowercase();
                if lower.contains("forge") {
                    "SD WebUI Forge".to_string()
                } else if lower.contains("comfy") {
                    "ComfyUI".to_string()
                } else {
                    format!("Stable Diffusion ({version})")
                }
            }
            None => "Stable Diffusion (A1111)".to_string(),
        };

        let meta = AIGenerationMetadata {
            generator: Some(generator),
            prompt: if positive_prompt.is_empty() {
                None
            } else {
                Some(positive_prompt)
            },
            negative_prompt,
            model_name,
            model_hash,
            sampler,
            scheduler,
            steps,
            cfg_scale,
            seed,
            size_text,
            clip_skip,
            loras,
            extra_parameters: extras,
            raw_parameters: Some(normalized.chars().take(8000).collect()),
        };
        if meta.is_empty() {
            None
        } else {
            Some(meta)
        }
    }

    /// Parses ComfyUI node-graph JSON (`prompt` chunk).
    pub fn parse_comfyui_prompt_json(raw_json: &str) -> Option<AIGenerationMetadata> {
        let root: serde_json::Map<String, JsonValue> = serde_json::from_str(raw_json).ok()?;
        if root.is_empty() {
            return None;
        }

        struct Node<'a> {
            class_type: &'a str,
            inputs: &'a serde_json::Map<String, JsonValue>,
        }

        let mut nodes: HashMap<String, Node<'_>> = HashMap::new();
        for (id, val) in &root {
            let Some(obj) = val.as_object() else { continue };
            let Some(class_type) = obj.get("class_type").and_then(JsonValue::as_str) else {
                continue;
            };
            let Some(inputs) = obj.get("inputs").and_then(JsonValue::as_object) else {
                continue;
            };
            nodes.insert(id.clone(), Node { class_type, inputs });
        }
        if nodes.is_empty() {
            return None;
        }

        fn linked_node_id(val: Option<&JsonValue>) -> Option<String> {
            let arr = val?.as_array()?;
            let first = arr.first()?;
            if let Some(s) = first.as_str() {
                Some(s.to_string())
            } else {
                first.as_i64().map(|n| n.to_string())
            }
        }

        const MAX_COMFY_GRAPH_DEPTH: usize = 64;
        const MAX_COMFY_GRAPH_STEPS: usize = 2_000;

        fn collect_prompts(
            start_id: Option<String>,
            nodes: &HashMap<String, Node<'_>>,
            visited: &mut HashSet<String>,
            depth: usize,
            steps_remaining: &mut usize,
        ) -> Vec<String> {
            if depth >= MAX_COMFY_GRAPH_DEPTH || *steps_remaining == 0 {
                return Vec::new();
            }
            let Some(node_id) = start_id else {
                return Vec::new();
            };
            if !visited.insert(node_id.clone()) {
                return Vec::new();
            }
            *steps_remaining -= 1;
            let Some(node) = nodes.get(&node_id) else {
                return Vec::new();
            };
            let mut found = Vec::new();
            for key in [
                "text", "clip_l", "t5xxl", "text_g", "text_l", "prompt", "positive", "string",
                "value",
            ] {
                if let Some(val) = node.inputs.get(key) {
                    if let Some(s) = val.as_str().and_then(clean_str) {
                        if !found.contains(&s) {
                            found.push(s);
                        }
                    } else if let Some(linked) = linked_node_id(Some(val)) {
                        found.extend(collect_prompts(
                            Some(linked),
                            nodes,
                            visited,
                            depth + 1,
                            steps_remaining,
                        ));
                    }
                }
            }
            let lower = node.class_type.to_ascii_lowercase();
            if found.is_empty() || lower.contains("combine") || lower.contains("concat") {
                for key in [
                    "conditioning",
                    "conditioning_1",
                    "conditioning_2",
                    "conditioning_to",
                    "conditioning_from",
                    "positive",
                    "guider",
                ] {
                    if let Some(linked) = linked_node_id(node.inputs.get(key)) {
                        found.extend(collect_prompts(
                            Some(linked),
                            nodes,
                            visited,
                            depth + 1,
                            steps_remaining,
                        ));
                    }
                }
            }
            found
        }

        let mut positive_texts = Vec::new();
        let mut negative_texts = Vec::new();
        let mut steps: Option<i32> = None;
        let mut cfg: Option<f64> = None;
        let mut sampler: Option<String> = None;
        let mut scheduler: Option<String> = None;
        let mut seed: Option<String> = None;
        let mut model_name: Option<String> = None;
        let mut size_text: Option<String> = None;
        let mut loras: Vec<String> = Vec::new();

        for node in nodes.values() {
            let lower = node.class_type.to_ascii_lowercase();
            let inputs = node.inputs;

            if lower.contains("ksampler")
                || lower.contains("samplercustom")
                || lower.contains("sampler")
            {
                if steps.is_none() {
                    steps = json_i32(inputs.get("steps"));
                }
                if cfg.is_none() {
                    cfg = json_f64(inputs.get("cfg"));
                }
                if sampler.is_none() {
                    sampler = json_clean_str(inputs.get("sampler_name"));
                }
                if scheduler.is_none() {
                    scheduler = json_clean_str(inputs.get("scheduler"));
                }
                if seed.is_none() {
                    seed = json_seed_str(inputs.get("seed").or_else(|| inputs.get("noise_seed")));
                }
                let mut v_pos = HashSet::new();
                let mut pos_budget = MAX_COMFY_GRAPH_STEPS;
                if let Some(pos_id) = linked_node_id(inputs.get("positive")) {
                    positive_texts.extend(collect_prompts(
                        Some(pos_id),
                        &nodes,
                        &mut v_pos,
                        0,
                        &mut pos_budget,
                    ));
                } else if let Some(guider_id) = linked_node_id(inputs.get("guider")) {
                    positive_texts.extend(collect_prompts(
                        Some(guider_id),
                        &nodes,
                        &mut v_pos,
                        0,
                        &mut pos_budget,
                    ));
                }
                let mut v_neg = HashSet::new();
                let mut neg_budget = MAX_COMFY_GRAPH_STEPS;
                if let Some(neg_id) = linked_node_id(inputs.get("negative")) {
                    negative_texts.extend(collect_prompts(
                        Some(neg_id),
                        &nodes,
                        &mut v_neg,
                        0,
                        &mut neg_budget,
                    ));
                }
            }

            if lower.contains("randomnoise") && seed.is_none() {
                seed = json_seed_str(inputs.get("noise_seed"));
            }
            if lower.contains("basicscheduler") {
                if steps.is_none() {
                    steps = json_i32(inputs.get("steps"));
                }
                if scheduler.is_none() {
                    scheduler = json_clean_str(inputs.get("scheduler"));
                }
            }
            if lower.contains("ksamplerselect") && sampler.is_none() {
                sampler = json_clean_str(inputs.get("sampler_name"));
            }
            if lower.contains("fluxguidance") && cfg.is_none() {
                cfg = json_f64(inputs.get("guidance"));
            }
            if (lower.contains("checkpointloader")
                || lower.contains("unetloader")
                || lower.contains("diffusionmodel"))
                && model_name.is_none()
            {
                if let Some(ckpt) = json_clean_str(inputs.get("ckpt_name"))
                    .or_else(|| json_clean_str(inputs.get("unet_name")))
                    .or_else(|| json_clean_str(inputs.get("model_name")))
                {
                    model_name = Some(path_basename(&ckpt));
                }
            }
            if lower.contains("lora") {
                if let Some(lora) = json_clean_str(inputs.get("lora_name")) {
                    let clean = path_basename(&lora);
                    if !loras.contains(&clean) {
                        loras.push(clean);
                    }
                }
            }
            if lower.contains("latentimage") && size_text.is_none() {
                if let (Some(w), Some(h)) = (
                    json_i32(inputs.get("width")),
                    json_i32(inputs.get("height")),
                ) {
                    if w > 0 && h > 0 {
                        size_text = Some(format!("{w} × {h}"));
                    }
                }
            }
        }

        if positive_texts.is_empty() {
            let mut sorted_ids: Vec<&String> = nodes.keys().collect();
            sorted_ids.sort_by_key(|k| k.parse::<i64>().unwrap_or(0));
            let mut candidates = Vec::new();
            for id in sorted_ids {
                let node = &nodes[id];
                if !node
                    .class_type
                    .to_ascii_lowercase()
                    .contains("cliptextencode")
                {
                    continue;
                }
                if let Some(txt) = json_clean_str(node.inputs.get("text"))
                    .or_else(|| json_clean_str(node.inputs.get("t5xxl")))
                    .or_else(|| json_clean_str(node.inputs.get("clip_l")))
                {
                    if !candidates.contains(&txt) {
                        candidates.push(txt);
                    }
                }
            }
            if let Some(first) = candidates.first() {
                positive_texts.push(first.clone());
            }
            if candidates.len() >= 2 && negative_texts.is_empty() {
                negative_texts.push(candidates[1].clone());
            }
        }

        let pos_joined = deduplicated_lines(&positive_texts).join("\n");
        let neg_joined = deduplicated_lines(&negative_texts).join("\n");

        let meta = AIGenerationMetadata {
            generator: Some("ComfyUI".to_string()),
            prompt: if pos_joined.is_empty() {
                None
            } else {
                Some(pos_joined)
            },
            negative_prompt: if neg_joined.is_empty() {
                None
            } else {
                Some(neg_joined)
            },
            model_name,
            sampler,
            scheduler,
            steps,
            cfg_scale: cfg,
            seed,
            size_text,
            loras,
            raw_parameters: Some(raw_json.chars().take(8000).collect()),
            ..AIGenerationMetadata::default()
        };
        if meta.is_empty() {
            None
        } else {
            Some(meta)
        }
    }

    fn parse_novelai_metadata(
        comment_json: &str,
        description: Option<&str>,
    ) -> Option<AIGenerationMetadata> {
        let obj = serde_json::from_str::<JsonValue>(comment_json)
            .ok()?
            .as_object()?
            .clone();
        let prompt = json_clean_str(obj.get("prompt")).or_else(|| description.and_then(clean_str));
        let size_text = match (json_i32(obj.get("width")), json_i32(obj.get("height"))) {
            (Some(w), Some(h)) if w > 0 && h > 0 => Some(format!("{w} × {h}")),
            _ => None,
        };
        let meta = AIGenerationMetadata {
            generator: Some("NovelAI".to_string()),
            prompt,
            negative_prompt: json_clean_str(obj.get("uc")),
            sampler: json_clean_str(obj.get("sampler")),
            steps: json_i32(obj.get("steps")),
            cfg_scale: json_f64(obj.get("scale")),
            seed: json_seed_str(obj.get("seed")),
            size_text,
            raw_parameters: Some(comment_json.chars().take(8000).collect()),
            ..AIGenerationMetadata::default()
        };
        if meta.is_empty() {
            None
        } else {
            Some(meta)
        }
    }

    fn parse_invokeai_metadata(raw_json: &str) -> Option<AIGenerationMetadata> {
        let obj = serde_json::from_str::<JsonValue>(raw_json)
            .ok()?
            .as_object()?
            .clone();
        let model_name = obj
            .get("model")
            .and_then(JsonValue::as_object)
            .and_then(|m| json_clean_str(m.get("name")))
            .or_else(|| json_clean_str(obj.get("model_name")));
        let size_text = match (json_i32(obj.get("width")), json_i32(obj.get("height"))) {
            (Some(w), Some(h)) if w > 0 && h > 0 => Some(format!("{w} × {h}")),
            _ => None,
        };
        let meta = AIGenerationMetadata {
            generator: Some("InvokeAI".to_string()),
            prompt: json_clean_str(obj.get("positive_prompt"))
                .or_else(|| json_clean_str(obj.get("prompt"))),
            negative_prompt: json_clean_str(obj.get("negative_prompt")),
            model_name,
            sampler: json_clean_str(obj.get("scheduler"))
                .or_else(|| json_clean_str(obj.get("sampler"))),
            steps: json_i32(obj.get("steps")),
            cfg_scale: json_f64(obj.get("cfg_scale")),
            seed: json_seed_str(obj.get("seed")),
            size_text,
            raw_parameters: Some(raw_json.chars().take(8000).collect()),
            ..AIGenerationMetadata::default()
        };
        if meta.is_empty() {
            None
        } else {
            Some(meta)
        }
    }

    pub fn parse_midjourney_description(desc: &str) -> AIGenerationMetadata {
        let mut clean_prompt = desc.to_string();
        let mut extras = BTreeMap::new();
        if let Some(pos) = clean_prompt.find("Job ID:") {
            let job_id = clean_prompt[pos + "Job ID:".len()..].trim().to_string();
            if !job_id.is_empty() {
                extras.insert("Job ID".to_string(), job_id);
            }
            clean_prompt = clean_prompt[..pos].trim().to_string();
        }
        let mut model_name = None;
        let tokens: Vec<&str> = clean_prompt.split_whitespace().collect();
        for i in 0..tokens.len() {
            if (tokens[i] == "--v" || tokens[i] == "--version") && i + 1 < tokens.len() {
                model_name = Some(format!("Midjourney v{}", tokens[i + 1]));
                break;
            }
            if tokens[i] == "--niji" {
                model_name = Some("Midjourney Niji".to_string());
                break;
            }
        }
        let mut seed = None;
        for i in 0..tokens.len() {
            if tokens[i] == "--seed" && i + 1 < tokens.len() {
                let candidate = tokens[i + 1];
                if candidate.chars().all(|c| c.is_ascii_digit()) {
                    seed = Some(candidate.to_string());
                    break;
                }
            }
        }
        AIGenerationMetadata {
            generator: Some("Midjourney".to_string()),
            prompt: Some(clean_prompt),
            model_name,
            seed,
            extra_parameters: extras,
            raw_parameters: Some(desc.chars().take(8000).collect()),
            ..AIGenerationMetadata::default()
        }
    }

    fn parse_generic_ai_json(raw_json: &str) -> Option<AIGenerationMetadata> {
        let obj = serde_json::from_str::<JsonValue>(raw_json)
            .ok()?
            .as_object()?
            .clone();

        if let Some(sui) = obj.get("sui_image_params").and_then(JsonValue::as_object) {
            let meta = AIGenerationMetadata {
                generator: Some("SwarmUI".to_string()),
                prompt: json_clean_str(sui.get("prompt")),
                negative_prompt: json_clean_str(sui.get("negativeprompt")),
                model_name: json_clean_str(sui.get("model")),
                sampler: json_clean_str(sui.get("sampler")),
                scheduler: json_clean_str(sui.get("scheduler")),
                steps: json_i32(sui.get("steps")),
                cfg_scale: json_f64(sui.get("cfgscale")),
                seed: json_seed_str(sui.get("seed")),
                raw_parameters: Some(raw_json.chars().take(8000).collect()),
                ..AIGenerationMetadata::default()
            };
            if !meta.is_empty() {
                return Some(meta);
            }
        }

        if let Some(c_prompt) = json_clean_str(obj.get("c")) {
            let meta = AIGenerationMetadata {
                generator: Some("Draw Things".to_string()),
                prompt: Some(c_prompt),
                negative_prompt: json_clean_str(obj.get("uc")),
                model_name: json_clean_str(obj.get("model")),
                sampler: json_clean_str(obj.get("sampler")),
                steps: json_i32(obj.get("steps")),
                cfg_scale: json_f64(obj.get("scale")),
                seed: json_seed_str(obj.get("seed")),
                size_text: json_clean_str(obj.get("size")),
                raw_parameters: Some(raw_json.chars().take(8000).collect()),
                ..AIGenerationMetadata::default()
            };
            if !meta.is_empty() {
                return Some(meta);
            }
        }

        if let Some(comfy) = Self::parse_comfyui_prompt_json(raw_json) {
            return Some(comfy);
        }
        if let Some(nai) = Self::parse_novelai_metadata(raw_json, None) {
            return Some(nai);
        }

        if let Some(prompt) =
            json_clean_str(obj.get("prompt")).or_else(|| json_clean_str(obj.get("positive_prompt")))
        {
            let meta = AIGenerationMetadata {
                generator: json_clean_str(obj.get("generator"))
                    .or_else(|| json_clean_str(obj.get("software")))
                    .or_else(|| Some("AI 生成".to_string())),
                prompt: Some(prompt),
                negative_prompt: json_clean_str(obj.get("negative_prompt"))
                    .or_else(|| json_clean_str(obj.get("uc"))),
                model_name: json_clean_str(obj.get("model")),
                sampler: json_clean_str(obj.get("sampler")),
                steps: json_i32(obj.get("steps")),
                cfg_scale: json_f64(
                    obj.get("cfg_scale")
                        .or_else(|| obj.get("cfg"))
                        .or_else(|| obj.get("scale")),
                ),
                seed: json_seed_str(obj.get("seed")),
                raw_parameters: Some(raw_json.chars().take(8000).collect()),
                ..AIGenerationMetadata::default()
            };
            if !meta.is_empty() {
                return Some(meta);
            }
        }
        None
    }
}

// =============================================================================
// Internal Helpers
// =============================================================================

fn decode_png_text(payload: &[u8]) -> Option<(String, String)> {
    let nul = payload.iter().position(|&b| b == 0)?;
    let key = String::from_utf8_lossy(&payload[..nul]).to_string();
    if key.is_empty() {
        return None;
    }
    let val = decode_utf8_or_latin1(&payload[nul + 1..]);
    Some((key, val))
}

fn decode_png_ztxt(payload: &[u8]) -> Option<(String, String)> {
    let nul = payload.iter().position(|&b| b == 0)?;
    if nul + 2 > payload.len() || payload[nul + 1] != 0 {
        return None;
    }
    let key = String::from_utf8_lossy(&payload[..nul]).to_string();
    if key.is_empty() {
        return None;
    }
    let inflated = inflate_zlib(&payload[nul + 2..])?;
    Some((key, decode_utf8_or_latin1(&inflated)))
}

fn decode_png_itxt(payload: &[u8]) -> Option<(String, String)> {
    let nul1 = payload.iter().position(|&b| b == 0)?;
    let key = String::from_utf8_lossy(&payload[..nul1]).to_string();
    if key.is_empty() || nul1 + 3 >= payload.len() {
        return None;
    }
    let is_compressed = payload[nul1 + 1] == 1;
    let lang_start = nul1 + 3;
    let nul2_rel = payload[lang_start..].iter().position(|&b| b == 0)?;
    let translated_start = lang_start + nul2_rel + 1;
    if translated_start >= payload.len() {
        return None;
    }
    let nul3_rel = payload[translated_start..].iter().position(|&b| b == 0)?;
    let text_start = translated_start + nul3_rel + 1;
    let raw_text = &payload[text_start..];
    let final_bytes = if is_compressed {
        inflate_zlib(raw_text)?
    } else {
        raw_text.to_vec()
    };
    Some((key, decode_utf8_or_latin1(&final_bytes)))
}

fn inflate_zlib(compressed: &[u8]) -> Option<Vec<u8>> {
    const MAX_SINGLE_ZLIB_BYTES: u64 = 4 * 1024 * 1024;
    let decoder = ZlibDecoder::new(compressed);
    let mut out = Vec::new();
    decoder
        .take(MAX_SINGLE_ZLIB_BYTES + 1)
        .read_to_end(&mut out)
        .ok()?;
    if out.is_empty() || out.len() as u64 > MAX_SINGLE_ZLIB_BYTES {
        None
    } else {
        Some(out)
    }
}

fn decode_utf8_or_latin1(bytes: &[u8]) -> String {
    match std::str::from_utf8(bytes) {
        Ok(s) => s.to_string(),
        Err(_) => bytes.iter().map(|&b| b as char).collect(),
    }
}

fn decode_exif_user_comment(val: &ExifValue) -> Option<String> {
    let bytes: &[u8] = match val {
        ExifValue::Undefined(b, _) => b.as_slice(),
        ExifValue::Byte(b) => b.as_slice(),
        ExifValue::Ascii(v) => v.first()?.as_slice(),
        _ => return None,
    };
    if bytes.is_empty() {
        return None;
    }
    if bytes.len() > 8 {
        let prefix = &bytes[..8];
        let body = &bytes[8..];
        if prefix.starts_with(b"UNICODE") {
            let decoded = decode_utf16_auto(body);
            if let Some(clean) = clean_str(&decoded) {
                return Some(clean);
            }
        } else if prefix.starts_with(b"ASCII") {
            let decoded = decode_utf8_or_latin1(body);
            if let Some(clean) = clean_str(&decoded) {
                return Some(clean);
            }
        }
    }
    clean_exif_comment_prefix(&decode_utf8_or_latin1(bytes))
}

fn decode_utf16_auto(bytes: &[u8]) -> String {
    let mut u16_be = Vec::with_capacity(bytes.len() / 2);
    let mut u16_le = Vec::with_capacity(bytes.len() / 2);
    for chunk in bytes.chunks_exact(2) {
        u16_be.push(u16::from_be_bytes([chunk[0], chunk[1]]));
        u16_le.push(u16::from_le_bytes([chunk[0], chunk[1]]));
    }
    let be_str = String::from_utf16_lossy(&u16_be);
    let le_str = String::from_utf16_lossy(&u16_le);
    let be_ascii = be_str
        .chars()
        .filter(|c| c.is_ascii_graphic() || *c == ' ')
        .count();
    let le_ascii = le_str
        .chars()
        .filter(|c| c.is_ascii_graphic() || *c == ' ')
        .count();
    if be_ascii >= le_ascii {
        be_str
    } else {
        le_str
    }
}

fn clean_exif_comment_prefix(raw: &str) -> Option<String> {
    let mut s = raw.replace('\0', "");
    for prefix in ["UNICODE", "ASCII", "JIS"] {
        if let Some(rest) = s.strip_prefix(prefix) {
            let rest_trimmed = rest.trim();
            if rest_trimmed.starts_with('{')
                || rest_trimmed.contains("Steps:")
                || rest_trimmed.contains("Negative prompt:")
            {
                s = rest_trimmed.to_string();
            }
        }
    }
    clean_str(&s)
}

fn scan_embedded_xmp_packet(data: &[u8]) -> Option<String> {
    let needle_start = b"<x:xmpmeta";
    let needle_end = b"</x:xmpmeta>";
    let start = data
        .windows(needle_start.len())
        .position(|w| w == needle_start)?;
    let end_rel = data[start..]
        .windows(needle_end.len())
        .position(|w| w == needle_end)?;
    let end = start + end_rel + needle_end.len();
    Some(String::from_utf8_lossy(&data[start..end]).into_owned())
}

fn extract_xml_tag_text(xml: &str, tag_name: &str) -> Option<String> {
    let open = format!("<{tag_name}");
    let close = format!("</{tag_name}>");
    let start = find_ascii_case_insensitive(xml, &open)?;
    let after_open = xml[start..].find('>')? + start + 1;
    let end = find_ascii_case_insensitive(&xml[after_open..], &close)? + after_open;
    let inner = &xml[after_open..end];
    // Strip nested RDF tags
    let mut stripped = String::with_capacity(inner.len());
    let mut in_tag = false;
    for ch in inner.chars() {
        match ch {
            '<' => in_tag = true,
            '>' => in_tag = false,
            _ if !in_tag => stripped.push(ch),
            _ => {}
        }
    }
    clean_str(&decode_basic_html_entities(&stripped))
}

fn decode_basic_html_entities(input: &str) -> String {
    input
        .replace("&quot;", "\"")
        .replace("&#39;", "'")
        .replace("&apos;", "'")
        .replace("&lt;", "<")
        .replace("&gt;", ">")
        .replace("&nbsp;", " ")
        .replace("&amp;", "&")
}

fn format_exif_date(raw: Option<&str>, offset: Option<&str>) -> Option<String> {
    let raw = raw?.trim();
    if raw.is_empty() {
        return None;
    }
    let mut normalized = raw.to_string();
    let bytes = normalized.as_bytes();
    if bytes.len() >= 10 && bytes[4] == b':' && bytes[7] == b':' {
        normalized.replace_range(4..5, "-");
        normalized.replace_range(7..8, "-");
    }
    if let Some(off) = offset.map(str::trim).filter(|s| !s.is_empty()) {
        if !normalized.contains(off) {
            return Some(format!("{normalized} ({off})"));
        }
    }
    Some(normalized)
}

fn metering_mode_label(code: i32) -> Option<String> {
    let label = match code {
        1 => "平均测光",
        2 => "中央重点测光",
        3 => "点测光",
        4 => "多点测光",
        5 => "评价测光",
        6 => "局部测光",
        _ => return None,
    };
    Some(label.to_string())
}

fn parse_comma_separated_kv(raw: &str) -> BTreeMap<String, String> {
    let mut pairs = BTreeMap::new();
    if raw.is_empty() {
        return pairs;
    }
    let mut parts = Vec::new();
    let mut current = String::new();
    let mut in_quotes = false;
    let mut brace_depth = 0i32;

    for ch in raw.chars() {
        if ch == '"' {
            in_quotes = !in_quotes;
            current.push(ch);
        } else if !in_quotes && (ch == '{' || ch == '[') {
            brace_depth += 1;
            current.push(ch);
        } else if !in_quotes && (ch == '}' || ch == ']') {
            brace_depth = (brace_depth - 1).max(0);
            current.push(ch);
        } else if ch == ',' && !in_quotes && brace_depth == 0 {
            parts.push(std::mem::take(&mut current));
        } else {
            current.push(ch);
        }
    }
    if !current.is_empty() {
        parts.push(current);
    }

    for part in parts {
        let Some((k, v)) = part.split_once(':') else {
            continue;
        };
        let key = k.trim();
        let mut val = v.trim();
        if val.starts_with('"') && val.ends_with('"') && val.len() >= 2 {
            val = &val[1..val.len() - 1];
        }
        if !key.is_empty() && !val.is_empty() {
            pairs.insert(key.to_string(), val.to_string());
        }
    }
    pairs
}

fn extract_lora_tags(prompt: &str) -> Vec<String> {
    let mut out = Vec::new();
    let mut rest = prompt;
    while let Some(start) = rest.find("<lora:") {
        let after = &rest[start + 6..];
        let Some(end) = after.find('>') else {
            break;
        };
        let inner = &after[..end];
        let mut split = inner.splitn(2, ':');
        let name = split.next().unwrap_or("").trim();
        let weight = split.next().map(str::trim).filter(|w| !w.is_empty());
        if !name.is_empty() {
            let label = match weight {
                Some(w) => format!("{name}:{w}"),
                None => name.to_string(),
            };
            if !out.contains(&label) {
                out.push(label);
            }
        }
        rest = &after[end + 1..];
    }
    out
}

fn find_ascii_case_insensitive(haystack: &str, needle: &str) -> Option<usize> {
    let h_bytes = haystack.as_bytes();
    let n_bytes = needle.as_bytes();
    if n_bytes.is_empty() || n_bytes.len() > h_bytes.len() {
        return None;
    }
    h_bytes
        .windows(n_bytes.len())
        .position(|w| w.eq_ignore_ascii_case(n_bytes))
}

fn deduplicated_lines(items: &[String]) -> Vec<String> {
    let mut seen = HashSet::new();
    let mut out = Vec::new();
    for item in items {
        let trimmed = item.trim();
        if !trimmed.is_empty() && seen.insert(trimmed.to_string()) {
            out.push(trimmed.to_string());
        }
    }
    out
}

fn clean_str(s: &str) -> Option<String> {
    let trimmed = s.trim_matches(|c: char| c.is_whitespace() || c.is_control());
    if trimmed.is_empty() {
        None
    } else {
        Some(trimmed.to_string())
    }
}

fn path_basename(raw: &str) -> String {
    raw.rsplit(['/', '\\'])
        .next()
        .unwrap_or(raw)
        .trim()
        .to_string()
}

fn json_clean_str(val: Option<&JsonValue>) -> Option<String> {
    val?.as_str().and_then(clean_str)
}

fn json_i32(val: Option<&JsonValue>) -> Option<i32> {
    let v = val?;
    if let Some(i) = v.as_i64() {
        return Some(i as i32);
    }
    if let Some(f) = v.as_f64() {
        return Some(f.round() as i32);
    }
    v.as_str().and_then(|s| s.trim().parse::<i32>().ok())
}

fn json_f64(val: Option<&JsonValue>) -> Option<f64> {
    let v = val?;
    if let Some(f) = v.as_f64() {
        return f.is_finite().then_some(f);
    }
    v.as_str()
        .and_then(|s| s.trim().parse::<f64>().ok())
        .filter(|f| f.is_finite())
}

fn json_seed_str(val: Option<&JsonValue>) -> Option<String> {
    let v = val?;
    if let Some(i) = v.as_i64() {
        return Some(i.to_string());
    }
    if let Some(u) = v.as_u64() {
        return Some(u.to_string());
    }
    v.as_str().and_then(clean_str)
}
