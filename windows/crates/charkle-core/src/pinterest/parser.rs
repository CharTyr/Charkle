//! Pure, offline-testable parser for Pinterest Web Resource API JSON responses and embedded
//! SSR HTML payloads mirroring `Sources/CharkleCore/Services/Pinterest/PinterestJSONParser.swift`.

use std::collections::HashSet;

use serde_json::{Map, Value};
use url::Url;

use super::models::{
    PinterestAccount, PinterestBoard, PinterestBoardsPage, PinterestFeedPage, PinterestPin,
};

pub struct PinterestJSONParser;

impl PinterestJSONParser {
    /// Extracts a numeric Pinterest Pin ID from any `https://*.pinterest.*/pin/<id>/...` URL.
    pub fn extract_pin_id(raw_url: &str) -> Option<String> {
        let parsed = Url::parse(raw_url.trim()).ok()?;
        let host = parsed.host_str()?.to_ascii_lowercase();
        if !host.contains("pinterest.") {
            return None;
        }
        let segments: Vec<&str> = parsed.path_segments()?.filter(|s| !s.is_empty()).collect();
        let pin_idx = segments
            .iter()
            .position(|s| s.eq_ignore_ascii_case("pin"))?;
        let candidate = segments.get(pin_idx + 1)?;
        let digits: String = candidate
            .chars()
            .take_while(|c| c.is_ascii_digit())
            .collect();
        if digits.len() >= 6 {
            Some(digits)
        } else {
            None
        }
    }

    // MARK: - Account Parsing

    pub fn parse_account(data: &[u8]) -> Option<PinterestAccount> {
        let root: Value = serde_json::from_slice(data).ok()?;
        Self::parse_account_value(&root)
    }

    pub fn parse_account_value(root: &Value) -> Option<PinterestAccount> {
        let obj = root.as_object()?;
        let candidates: Vec<&Map<String, Value>> = [
            obj.get("resource_response")
                .and_then(|v| v.get("data"))
                .and_then(Value::as_object),
            obj.get("resource_response")
                .and_then(|v| v.get("data"))
                .and_then(|v| v.get("user"))
                .and_then(Value::as_object),
            obj.get("data").and_then(Value::as_object),
            obj.get("user").and_then(Value::as_object),
            Some(obj),
        ]
        .into_iter()
        .flatten()
        .collect();

        for dict in candidates {
            if let Some(account) = Self::extract_account_from_dict(dict) {
                return Some(account);
            }
        }
        None
    }

    fn extract_account_from_dict(dict: &Map<String, Value>) -> Option<PinterestAccount> {
        let username = Self::clean_string(dict.get("username"))?;
        let full_name = Self::clean_string(dict.get("full_name"))
            .or_else(|| {
                let first = Self::clean_string(dict.get("first_name")).unwrap_or_default();
                let last = Self::clean_string(dict.get("last_name")).unwrap_or_default();
                let joined = format!("{first} {last}").trim().to_string();
                (!joined.is_empty()).then_some(joined)
            })
            .unwrap_or_else(|| username.clone());
        let id = Self::clean_string(dict.get("id")).unwrap_or_else(|| username.clone());
        let avatar_url = Self::clean_string(dict.get("image_xlarge_url"))
            .or_else(|| Self::clean_string(dict.get("image_large_url")))
            .or_else(|| Self::clean_string(dict.get("image_medium_url")))
            .or_else(|| Self::clean_string(dict.get("image_small_url")))
            .or_else(|| Self::clean_string(dict.get("profile_image")));
        let email = Self::clean_string(dict.get("email"));

        Some(PinterestAccount {
            id,
            username,
            full_name,
            avatar_url,
            email,
        })
    }

    // MARK: - Feed Page Parsing

    pub fn parse_feed_page(data: &[u8], source_description: &str) -> PinterestFeedPage {
        let Ok(root) = serde_json::from_slice::<Value>(data) else {
            return PinterestFeedPage {
                pins: Vec::new(),
                next_bookmark: None,
                has_more: false,
                source_description: source_description.to_string(),
            };
        };

        let next_bookmark = Self::extract_bookmark(&root);
        let mut pins = Vec::new();
        let mut seen = HashSet::new();
        Self::extract_pin_objects(&root, &mut pins, &mut seen, 0);

        let has_more = next_bookmark
            .as_deref()
            .is_some_and(|bm| !bm.is_empty() && bm != "-end-");

        PinterestFeedPage {
            pins,
            next_bookmark: has_more.then_some(next_bookmark).flatten(),
            has_more,
            source_description: source_description.to_string(),
        }
    }

    pub fn parse_single_pin(data: &[u8]) -> Option<PinterestPin> {
        let root: Value = serde_json::from_slice(data).ok()?;
        let obj = root.as_object()?;
        if let Some(rr_data) = obj
            .get("resource_response")
            .and_then(|v| v.get("data"))
            .and_then(Value::as_object)
        {
            if let Some(pin) = Self::parse_pin_dictionary(rr_data) {
                return Some(pin);
            }
        }
        let mut collected = Vec::new();
        let mut seen = HashSet::new();
        Self::extract_pin_objects(&root, &mut collected, &mut seen, 0);
        collected.into_iter().next()
    }

    // MARK: - Boards Parsing

    pub fn parse_boards(data: &[u8]) -> Vec<PinterestBoard> {
        Self::parse_boards_page(data).boards
    }

    pub fn parse_boards_page(data: &[u8]) -> PinterestBoardsPage {
        let Ok(root) = serde_json::from_slice::<Value>(data) else {
            return PinterestBoardsPage {
                boards: Vec::new(),
                next_bookmark: None,
                has_more: false,
            };
        };

        let next_bookmark = Self::extract_bookmark(&root);
        let mut boards = Vec::new();
        let mut seen = HashSet::new();
        Self::extract_board_objects(&root, &mut boards, &mut seen, 0);

        let has_more = next_bookmark
            .as_deref()
            .is_some_and(|bm| !bm.is_empty() && bm != "-end-");

        PinterestBoardsPage {
            boards,
            next_bookmark: has_more.then_some(next_bookmark).flatten(),
            has_more,
        }
    }

    // MARK: - HTML Embedded JSON Fallback

    pub fn parse_pins_from_html(html: &str, source_description: &str) -> PinterestFeedPage {
        let mut collected = Vec::new();
        let mut seen = HashSet::new();

        for json_blob in Self::extract_script_json_blobs(html) {
            if let Ok(value) = serde_json::from_str::<Value>(&json_blob) {
                Self::extract_pin_objects(&value, &mut collected, &mut seen, 0);
            }
        }

        PinterestFeedPage {
            pins: collected,
            next_bookmark: None,
            has_more: false,
            source_description: source_description.to_string(),
        }
    }

    fn extract_script_json_blobs(html: &str) -> Vec<String> {
        let mut out = Vec::new();
        let lower = html.to_ascii_lowercase();
        let mut cursor = 0usize;
        while let Some(open_rel) = lower[cursor..].find("<script") {
            let open_start = cursor + open_rel;
            let Some(tag_end_rel) = html[open_start..].find('>') else {
                break;
            };
            let tag_header = &html[open_start..open_start + tag_end_rel + 1];
            let content_start = open_start + tag_end_rel + 1;
            let Some(close_rel) = lower[content_start..].find("</script>") else {
                break;
            };
            let content_end = content_start + close_rel;
            cursor = content_end + "</script>".len();

            let header_lower = tag_header.to_ascii_lowercase();
            let interesting = header_lower.contains("__pws_initial_props__")
                || header_lower.contains("__pws_data__")
                || header_lower.contains("application/json")
                || header_lower.contains("data-relay-response");
            if interesting {
                let body = html[content_start..content_end].trim();
                if body.starts_with('{') || body.starts_with('[') {
                    out.push(body.to_string());
                }
            }
        }
        out
    }

    // MARK: - Pin Dictionary Normalization

    pub fn parse_pin_dictionary(dict: &Map<String, Value>) -> Option<PinterestPin> {
        if let Some(kind) = Self::clean_string(dict.get("type")).map(|s| s.to_ascii_lowercase()) {
            if matches!(kind.as_str(), "board" | "user" | "story" | "ad_campaign") {
                return None;
            }
        }
        if dict.get("is_promoted").and_then(Value::as_bool) == Some(true)
            && dict.get("images").is_none()
        {
            return None;
        }

        let raw_id = Self::clean_string(dict.get("id"))
            .or_else(|| Self::clean_string(dict.get("entityId")))
            .or_else(|| Self::clean_string(dict.get("pin_id")))?;
        if raw_id.len() < 4 || raw_id.contains('/') || raw_id.contains(' ') {
            return None;
        }

        let mut original_url: Option<String> = None;
        let mut preview_url: Option<String> = None;
        let mut thumbnail_url: Option<String> = None;
        let mut pixel_width = Self::parse_i32(dict.get("width")).unwrap_or(0);
        let mut pixel_height = Self::parse_i32(dict.get("height")).unwrap_or(0);

        if let Some(images) = dict.get("images").and_then(Value::as_object) {
            if let Some(orig) = images.get("orig").and_then(Value::as_object) {
                original_url = Self::clean_string(orig.get("url"));
                pixel_width = Self::parse_i32(orig.get("width")).unwrap_or(pixel_width);
                pixel_height = Self::parse_i32(orig.get("height")).unwrap_or(pixel_height);
            }
            for key in ["736x", "564x", "474x"] {
                if preview_url.is_none() {
                    if let Some(entry) = images.get(key).and_then(Value::as_object) {
                        preview_url = Self::clean_string(entry.get("url"));
                        if pixel_width == 0 {
                            pixel_width = Self::parse_i32(entry.get("width")).unwrap_or(0);
                        }
                        if pixel_height == 0 {
                            pixel_height = Self::parse_i32(entry.get("height")).unwrap_or(0);
                        }
                    }
                }
            }
            for key in ["236x", "474x", "170x"] {
                if thumbnail_url.is_none() {
                    if let Some(entry) = images.get(key).and_then(Value::as_object) {
                        thumbnail_url = Self::clean_string(entry.get("url"));
                    }
                }
            }
            if original_url.is_none() && preview_url.is_none() && thumbnail_url.is_none() {
                for entry in images.values().filter_map(Value::as_object) {
                    if let Some(url) = Self::clean_string(entry.get("url")) {
                        preview_url = Some(url);
                        if pixel_width == 0 {
                            pixel_width = Self::parse_i32(entry.get("width")).unwrap_or(0);
                        }
                        if pixel_height == 0 {
                            pixel_height = Self::parse_i32(entry.get("height")).unwrap_or(0);
                        }
                        break;
                    }
                }
            }
        }

        if original_url.is_none() && preview_url.is_none() && thumbnail_url.is_none() {
            if let Some(spec) = Self::clean_string(dict.get("image_large_url"))
                .or_else(|| Self::clean_string(dict.get("image_medium_url")))
                .or_else(|| Self::clean_string(dict.get("image_url")))
            {
                preview_url = Some(spec);
            } else if let Some(sig) = Self::clean_string(dict.get("image_signature")) {
                if sig.len() >= 12 {
                    let chars: Vec<char> = sig.chars().collect();
                    let p1: String = chars[0..2].iter().collect();
                    let p2: String = chars[2..4].iter().collect();
                    let p3: String = chars[4..6].iter().collect();
                    original_url = Some(format!(
                        "https://i.pinimg.com/originals/{p1}/{p2}/{p3}/{sig}.jpg"
                    ));
                    preview_url = Some(format!(
                        "https://i.pinimg.com/736x/{p1}/{p2}/{p3}/{sig}.jpg"
                    ));
                    thumbnail_url = Some(format!(
                        "https://i.pinimg.com/236x/{p1}/{p2}/{p3}/{sig}.jpg"
                    ));
                }
            }
        }

        let video_url = Self::extract_video_url(dict);
        if original_url.is_none()
            && preview_url.is_none()
            && thumbnail_url.is_none()
            && video_url.is_none()
        {
            return None;
        }

        if original_url.is_none() {
            original_url = preview_url.clone().or_else(|| thumbnail_url.clone());
        }
        if preview_url.is_none() {
            preview_url = original_url.clone().or_else(|| thumbnail_url.clone());
        }
        if thumbnail_url.is_none() {
            thumbnail_url = preview_url.clone().or_else(|| original_url.clone());
        }

        let title = Self::clean_string(dict.get("grid_title"))
            .or_else(|| Self::clean_string(dict.get("title")))
            .or_else(|| Self::clean_string(dict.get("seo_title")))
            .unwrap_or_default();
        let description = Self::clean_string(dict.get("description"))
            .or_else(|| Self::clean_string(dict.get("closeup_unified_description")))
            .or_else(|| Self::clean_string(dict.get("auto_alt_text")))
            .unwrap_or_default();

        let pinner = dict
            .get("pinner")
            .and_then(Value::as_object)
            .or_else(|| dict.get("native_creator").and_then(Value::as_object));
        let author_name = pinner.and_then(|p| {
            Self::clean_string(p.get("full_name")).or_else(|| Self::clean_string(p.get("username")))
        });
        let author_username = pinner.and_then(|p| Self::clean_string(p.get("username")));
        let author_avatar_url = pinner.and_then(|p| {
            Self::clean_string(p.get("image_medium_url"))
                .or_else(|| Self::clean_string(p.get("image_small_url")))
                .or_else(|| Self::clean_string(p.get("image_large_url")))
        });

        let board = dict.get("board").and_then(Value::as_object);
        let board_name = board.and_then(|b| Self::clean_string(b.get("name")));
        let board_id = board.and_then(|b| Self::clean_string(b.get("id")));

        let domain = Self::clean_string(dict.get("domain"));
        let link_url = Self::clean_string(dict.get("link"))
            .or_else(|| Self::clean_string(dict.get("tracked_link")));
        let dominant_color_hex = Self::clean_string(dict.get("dominant_color"));
        let pin_page_url = format!("https://www.pinterest.com/pin/{raw_id}/");

        Some(PinterestPin {
            id: raw_id,
            title,
            description,
            author_name,
            author_username,
            author_avatar_url,
            board_name,
            board_id,
            domain,
            link_url,
            pin_page_url,
            original_url,
            preview_url,
            thumbnail_url,
            video_url,
            pixel_width: pixel_width.max(0),
            pixel_height: pixel_height.max(0),
            dominant_color_hex,
        })
    }

    // MARK: - Private Walkers

    fn extract_pin_objects(
        node: &Value,
        results: &mut Vec<PinterestPin>,
        seen: &mut HashSet<String>,
        depth: usize,
    ) {
        if depth > 14 {
            return;
        }
        match node {
            Value::Array(arr) => {
                for item in arr {
                    Self::extract_pin_objects(item, results, seen, depth + 1);
                }
            }
            Value::Object(dict) => {
                if dict.contains_key("images") || dict.contains_key("image_signature") {
                    if let Some(pin) = Self::parse_pin_dictionary(dict) {
                        if seen.insert(pin.id.clone()) {
                            results.push(pin);
                        }
                        return;
                    }
                }
                for key in [
                    "resource_response",
                    "data",
                    "results",
                    "items",
                    "pins",
                    "bookmark_pins",
                    "objects",
                    "pin",
                    "props",
                    "initialReduxState",
                    "resources",
                    "response",
                ] {
                    if let Some(child) = dict.get(key) {
                        Self::extract_pin_objects(child, results, seen, depth + 1);
                    }
                }
                if depth <= 6 {
                    for (key, value) in dict {
                        if matches!(
                            key.as_str(),
                            "pinner" | "board" | "videos" | "images" | "rich_summary"
                        ) {
                            continue;
                        }
                        if value.is_object() || value.is_array() {
                            Self::extract_pin_objects(value, results, seen, depth + 1);
                        }
                    }
                }
            }
            _ => {}
        }
    }

    fn extract_board_objects(
        node: &Value,
        results: &mut Vec<PinterestBoard>,
        seen: &mut HashSet<String>,
        depth: usize,
    ) {
        if depth > 10 {
            return;
        }
        match node {
            Value::Array(arr) => {
                for item in arr {
                    Self::extract_board_objects(item, results, seen, depth + 1);
                }
            }
            Value::Object(dict) => {
                let kind = Self::clean_string(dict.get("type")).map(|s| s.to_ascii_lowercase());
                let looks_like_board = kind.as_deref() == Some("board")
                    || (dict.contains_key("pin_count")
                        && dict.contains_key("url")
                        && dict.contains_key("name"));
                if looks_like_board {
                    if let (Some(id), Some(name), Some(url_path)) = (
                        Self::clean_string(dict.get("id")),
                        Self::clean_string(dict.get("name")),
                        Self::clean_string(dict.get("url")),
                    ) {
                        if seen.insert(id.clone()) {
                            let pin_count = Self::parse_i64(dict.get("pin_count")).unwrap_or(0);
                            let privacy = Self::clean_string(dict.get("privacy"))
                                .map(|s| s.to_ascii_lowercase());
                            let cover_image_url =
                                Self::clean_string(dict.get("image_cover_hd_url"))
                                    .or_else(|| Self::clean_string(dict.get("image_cover_url")))
                                    .or_else(|| {
                                        dict.get("pin_thumbnail_urls")
                                            .and_then(Value::as_array)
                                            .and_then(|arr| arr.first())
                                            .and_then(|v| Self::clean_string(Some(v)))
                                    })
                                    .or_else(|| {
                                        dict.get("cover_images")
                                            .and_then(Value::as_object)
                                            .and_then(|m| m.values().next())
                                            .and_then(Value::as_object)
                                            .and_then(|m| Self::clean_string(m.get("url")))
                                    });
                            let owner_username = dict
                                .get("owner")
                                .and_then(Value::as_object)
                                .and_then(|o| Self::clean_string(o.get("username")));
                            results.push(PinterestBoard {
                                id,
                                name,
                                url_path,
                                description: Self::clean_string(dict.get("description")),
                                pin_count,
                                cover_image_url,
                                is_secret: privacy.as_deref() == Some("secret"),
                                owner_username,
                            });
                        }
                        return;
                    }
                }
                for value in dict.values() {
                    if value.is_object() || value.is_array() {
                        Self::extract_board_objects(value, results, seen, depth + 1);
                    }
                }
            }
            _ => {}
        }
    }

    fn extract_bookmark(root: &Value) -> Option<String> {
        let dict = root.as_object()?;
        let rr = dict.get("resource_response").and_then(Value::as_object);
        let resource = dict.get("resource").and_then(Value::as_object);

        if let Some(bm) = rr.and_then(|m| Self::clean_string(m.get("bookmark"))) {
            return Some(bm);
        }
        if let Some(bms) = rr
            .and_then(|m| m.get("bookmarks"))
            .and_then(Value::as_array)
        {
            if let Some(first) = bms.first().and_then(|v| Self::clean_string(Some(v))) {
                return Some(first);
            }
        }
        if let Some(bms) = resource
            .and_then(|m| m.get("options"))
            .and_then(Value::as_object)
            .and_then(|m| m.get("bookmarks"))
            .and_then(Value::as_array)
        {
            if let Some(first) = bms.first().and_then(|v| Self::clean_string(Some(v))) {
                return Some(first);
            }
        }
        if let Some(bm) = dict
            .get("resource_response")
            .and_then(|v| v.get("data"))
            .and_then(Value::as_object)
            .and_then(|m| Self::clean_string(m.get("bookmark")))
        {
            return Some(bm);
        }
        None
    }

    fn extract_video_url(dict: &Map<String, Value>) -> Option<String> {
        let videos = dict.get("videos").and_then(Value::as_object).or_else(|| {
            dict.get("story_pin_data")
                .and_then(Value::as_object)
                .and_then(|m| m.get("pages"))
                .and_then(Value::as_array)
                .and_then(|arr| arr.first())
                .and_then(Value::as_object)
                .and_then(|m| m.get("blocks"))
                .and_then(Value::as_array)
                .and_then(|arr| arr.first())
                .and_then(Value::as_object)
                .and_then(|m| m.get("video"))
                .and_then(Value::as_object)
        })?;
        let video_list = videos.get("video_list").and_then(Value::as_object)?;
        for key in ["V_720P", "V_HLSV4", "V_EXP7"] {
            if let Some(url) = video_list
                .get(key)
                .and_then(Value::as_object)
                .and_then(|v| Self::clean_string(v.get("url")))
            {
                if url.to_ascii_lowercase().contains(".mp4") {
                    return Some(url);
                }
            }
        }
        for entry in video_list.values().filter_map(Value::as_object) {
            if let Some(url) = Self::clean_string(entry.get("url")) {
                if url.to_ascii_lowercase().contains(".mp4") {
                    return Some(url);
                }
            }
        }
        None
    }

    fn clean_string(value: Option<&Value>) -> Option<String> {
        match value? {
            Value::String(s) => {
                let trimmed = s.trim();
                (!trimmed.is_empty()).then(|| trimmed.to_string())
            }
            Value::Number(n) => Some(n.to_string()),
            _ => None,
        }
    }

    fn parse_i32(value: Option<&Value>) -> Option<i32> {
        match value? {
            Value::Number(n) => n
                .as_i64()
                .and_then(|v| i32::try_from(v).ok())
                .or_else(|| n.as_f64().map(|v| v as i32)),
            Value::String(s) => s.trim().parse::<i32>().ok(),
            _ => None,
        }
    }

    fn parse_i64(value: Option<&Value>) -> Option<i64> {
        match value? {
            Value::Number(n) => n.as_i64().or_else(|| n.as_f64().map(|v| v as i64)),
            Value::String(s) => s.trim().parse::<i64>().ok(),
            _ => None,
        }
    }
}
