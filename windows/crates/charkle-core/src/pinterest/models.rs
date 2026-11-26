//! Pinterest domain models, bidirectional infinite spatial layout engine, and cursor-anchored
//! camera mirroring `Sources/CharkleCore/Services/Pinterest/PinterestModels.swift`.

use std::collections::{HashMap, HashSet};

use serde::{Deserialize, Serialize};
use uuid::Uuid;

use crate::models::core::AssetRecord;
use crate::wire::swift_codec::{upper_uuid, upper_uuid_vec};

// MARK: - Account & Board Models

#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PinterestAccount {
    pub id: String,
    pub username: String,
    pub full_name: String,
    #[serde(rename = "avatarURL", default, skip_serializing_if = "Option::is_none")]
    pub avatar_url: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub email: Option<String>,
}

impl PinterestAccount {
    pub fn display_name(&self) -> String {
        let trimmed_full = self.full_name.trim();
        if !trimmed_full.is_empty() {
            return trimmed_full.to_string();
        }
        let trimmed_user = self.username.trim();
        if !trimmed_user.is_empty() {
            return format!("@{trimmed_user}");
        }
        "Pinterest 账号".to_string()
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PinterestBoard {
    pub id: String,
    pub name: String,
    pub url_path: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub description: Option<String>,
    #[serde(default)]
    pub pin_count: i64,
    #[serde(
        rename = "coverImageURL",
        default,
        skip_serializing_if = "Option::is_none"
    )]
    pub cover_image_url: Option<String>,
    #[serde(default)]
    pub is_secret: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub owner_username: Option<String>,
}

impl PinterestBoard {
    pub fn normalized_url_path(&self) -> String {
        let trimmed = self.url_path.trim();
        if trimmed.is_empty() {
            return "/".to_string();
        }
        let with_leading = if trimmed.starts_with('/') {
            trimmed.to_string()
        } else {
            format!("/{trimmed}")
        };
        if with_leading.ends_with('/') {
            with_leading
        } else {
            format!("{with_leading}/")
        }
    }

    pub fn web_url(&self) -> String {
        format!("https://www.pinterest.com{}", self.normalized_url_path())
    }
}

// MARK: - Pin & Feed Models

#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PinterestPin {
    pub id: String,
    #[serde(default)]
    pub title: String,
    #[serde(default)]
    pub description: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub author_name: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub author_username: Option<String>,
    #[serde(
        rename = "authorAvatarURL",
        default,
        skip_serializing_if = "Option::is_none"
    )]
    pub author_avatar_url: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub board_name: Option<String>,
    #[serde(rename = "boardID", default, skip_serializing_if = "Option::is_none")]
    pub board_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub domain: Option<String>,
    #[serde(rename = "linkURL", default, skip_serializing_if = "Option::is_none")]
    pub link_url: Option<String>,
    #[serde(rename = "pinPageURL")]
    pub pin_page_url: String,
    #[serde(
        rename = "originalURL",
        default,
        skip_serializing_if = "Option::is_none"
    )]
    pub original_url: Option<String>,
    #[serde(
        rename = "previewURL",
        default,
        skip_serializing_if = "Option::is_none"
    )]
    pub preview_url: Option<String>,
    #[serde(
        rename = "thumbnailURL",
        default,
        skip_serializing_if = "Option::is_none"
    )]
    pub thumbnail_url: Option<String>,
    #[serde(rename = "videoURL", default, skip_serializing_if = "Option::is_none")]
    pub video_url: Option<String>,
    #[serde(default)]
    pub pixel_width: i32,
    #[serde(default)]
    pub pixel_height: i32,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub dominant_color_hex: Option<String>,
}

impl PinterestPin {
    pub fn aspect_ratio(&self) -> f64 {
        if self.pixel_width > 0 && self.pixel_height > 0 {
            let raw = f64::from(self.pixel_width) / f64::from(self.pixel_height);
            raw.clamp(0.45, 2.1)
        } else {
            0.78
        }
    }

    /// Highest-resolution media URL for importing into Charkle.
    pub fn best_import_media_url(&self) -> Option<&str> {
        self.video_url
            .as_deref()
            .filter(|s| !s.trim().is_empty())
            .or_else(|| {
                self.original_url
                    .as_deref()
                    .filter(|s| !s.trim().is_empty())
            })
            .or_else(|| self.preview_url.as_deref().filter(|s| !s.trim().is_empty()))
            .or_else(|| {
                self.thumbnail_url
                    .as_deref()
                    .filter(|s| !s.trim().is_empty())
            })
    }

    /// Optimal display image tier given rendered width in logical pixels.
    pub fn display_image_url(&self, rendered_width: f64) -> Option<&str> {
        if rendered_width <= 150.0 {
            self.thumbnail_url
                .as_deref()
                .or(self.preview_url.as_deref())
                .or(self.original_url.as_deref())
        } else if rendered_width <= 420.0 {
            self.preview_url
                .as_deref()
                .or(self.original_url.as_deref())
                .or(self.thumbnail_url.as_deref())
        } else {
            self.original_url
                .as_deref()
                .or(self.preview_url.as_deref())
                .or(self.thumbnail_url.as_deref())
        }
    }

    pub fn display_title(&self) -> String {
        let trimmed_title = self.title.trim();
        if !trimmed_title.is_empty() {
            return trimmed_title.to_string();
        }
        let trimmed_desc = self.description.trim();
        if !trimmed_desc.is_empty() {
            return trimmed_desc.chars().take(72).collect();
        }
        if let Some(ref board) = self.board_name {
            let clean = board.trim();
            if !clean.is_empty() {
                return clean.to_string();
            }
        }
        format!("Pinterest {}", self.id)
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum PinterestFeedSource {
    Home,
    Search {
        query: String,
    },
    Board {
        board: Box<PinterestBoard>,
    },
    Similar {
        #[serde(rename = "seedPin")]
        seed_pin: Box<PinterestPin>,
    },
}

impl PinterestFeedSource {
    pub fn display_title(&self) -> String {
        match self {
            Self::Home => "主页推荐".to_string(),
            Self::Search { query } => format!("搜索：{query}"),
            Self::Board { board } => format!("画板：{}", board.name),
            Self::Similar { seed_pin } => format!("相似灵感：{}", seed_pin.display_title()),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PinterestFeedPage {
    pub pins: Vec<PinterestPin>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub next_bookmark: Option<String>,
    pub has_more: bool,
    pub source_description: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PinterestBoardsPage {
    pub boards: Vec<PinterestBoard>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub next_bookmark: Option<String>,
    pub has_more: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PinterestPinDetailResult {
    pub pin: PinterestPin,
    pub similar_pins: Vec<PinterestPin>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub next_similar_bookmark: Option<String>,
    pub has_more_similar: bool,
}

// MARK: - 2D Geometry & Bidirectional Infinite Spatial Layout Engine

#[derive(Debug, Clone, Copy, PartialEq, Default, Serialize, Deserialize)]
pub struct SpatialPoint {
    pub x: f64,
    pub y: f64,
}

#[derive(Debug, Clone, Copy, PartialEq, Default, Serialize, Deserialize)]
pub struct SpatialSize {
    pub width: f64,
    pub height: f64,
}

#[derive(Debug, Clone, Copy, PartialEq, Default, Serialize, Deserialize)]
pub struct SpatialRect {
    pub x: f64,
    pub y: f64,
    pub width: f64,
    pub height: f64,
}

impl SpatialRect {
    pub const ZERO: Self = Self {
        x: 0.0,
        y: 0.0,
        width: 0.0,
        height: 0.0,
    };

    pub fn new(x: f64, y: f64, width: f64, height: f64) -> Self {
        Self {
            x,
            y,
            width,
            height,
        }
    }

    pub fn min_x(self) -> f64 {
        self.x
    }

    pub fn max_x(self) -> f64 {
        self.x + self.width
    }

    pub fn min_y(self) -> f64 {
        self.y
    }

    pub fn max_y(self) -> f64 {
        self.y + self.height
    }

    pub fn mid_x(self) -> f64 {
        self.x + self.width * 0.5
    }

    pub fn mid_y(self) -> f64 {
        self.y + self.height * 0.5
    }

    pub fn inset_by(self, dx: f64, dy: f64) -> Self {
        Self {
            x: self.x + dx,
            y: self.y + dy,
            width: self.width - dx * 2.0,
            height: self.height - dy * 2.0,
        }
    }

    pub fn intersects(self, other: Self) -> bool {
        self.min_x() < other.max_x()
            && self.max_x() > other.min_x()
            && self.min_y() < other.max_y()
            && self.max_y() > other.min_y()
    }

    pub fn union(self, other: Self) -> Self {
        if self.width == 0.0 && self.height == 0.0 {
            return other;
        }
        let min_x = self.min_x().min(other.min_x());
        let min_y = self.min_y().min(other.min_y());
        let max_x = self.max_x().max(other.max_x());
        let max_y = self.max_y().max(other.max_y());
        Self::new(min_x, min_y, max_x - min_x, max_y - min_y)
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PinterestSpatialCard {
    pub id: String,
    pub pin: PinterestPin,
    pub frame: SpatialRect,
    pub column_index: i32,
    pub ring_index: i32,
}

#[derive(Debug, Clone, Copy)]
struct ColumnBounds {
    top_y: f64,
    bottom_y: f64,
}

/// Deterministic, append-only bidirectional masonry spatial layout centered around `(0, 0)`.
///
/// Mirrors Swift `PinterestSpatialLayout` 1:1:
/// - Existing cards NEVER shift when new pins are appended (`0px` shift).
/// - Cards expand outward across all 4 quadrants around the origin.
/// - Zero overlapping rectangles across all columns.
#[derive(Debug, Clone)]
pub struct PinterestSpatialLayout {
    pub card_width: f64,
    pub gap: f64,
    cards: Vec<PinterestSpatialCard>,
    placed_ids: HashSet<String>,
    columns: HashMap<i32, ColumnBounds>,
    active_radius: i32,
    content_bounds: SpatialRect,
}

impl Default for PinterestSpatialLayout {
    fn default() -> Self {
        Self::new(224.0, 16.0)
    }
}

impl PinterestSpatialLayout {
    pub fn new(card_width: f64, gap: f64) -> Self {
        Self {
            card_width: card_width.max(120.0),
            gap: gap.max(6.0),
            cards: Vec::new(),
            placed_ids: HashSet::new(),
            columns: HashMap::new(),
            active_radius: 2,
            content_bounds: SpatialRect::ZERO,
        }
    }

    pub fn cards(&self) -> &[PinterestSpatialCard] {
        &self.cards
    }

    pub fn content_bounds(&self) -> SpatialRect {
        self.content_bounds
    }

    pub fn reset(&mut self) {
        self.cards.clear();
        self.placed_ids.clear();
        self.columns.clear();
        self.active_radius = 2;
        self.content_bounds = SpatialRect::ZERO;
    }

    pub fn append(&mut self, pins: &[PinterestPin]) -> Vec<PinterestSpatialCard> {
        let mut inserted = Vec::new();
        let stride = self.card_width + self.gap;

        for pin in pins {
            if !self.placed_ids.insert(pin.id.clone()) {
                continue;
            }

            let desired_radius = (((self.cards.len() + 1) as f64).sqrt() * 0.62).floor() as i32 + 1;
            self.active_radius = self.active_radius.max(desired_radius.max(2));

            let ratio = pin.aspect_ratio();
            let card_height = (self.card_width / ratio).clamp(110.0, 460.0).round();

            let mut best_col: i32 = 0;
            let mut best_y: f64 = 0.0;
            let mut best_place_south = true;
            let mut best_score = f64::INFINITY;

            for col in -self.active_radius..=self.active_radius {
                let col_center_x = f64::from(col) * stride;
                if let Some(&bounds) = self.columns.get(&col) {
                    let south_y = bounds.bottom_y + self.gap;
                    let south_center_y = south_y + card_height * 0.5;
                    let south_dist = col_center_x.hypot(south_center_y);
                    if south_dist < best_score {
                        best_score = south_dist;
                        best_col = col;
                        best_y = south_y;
                        best_place_south = true;
                    }

                    let north_y = bounds.top_y - self.gap - card_height;
                    let north_center_y = north_y + card_height * 0.5;
                    let north_dist = col_center_x.hypot(north_center_y);
                    if north_dist < best_score {
                        best_score = north_dist;
                        best_col = col;
                        best_y = north_y;
                        best_place_south = false;
                    }
                } else {
                    let stagger = Self::column_stagger(col, self.gap);
                    let initial_y = -card_height * 0.5 + stagger;
                    let center_y = initial_y + card_height * 0.5;
                    let dist = col_center_x.hypot(center_y);
                    if dist < best_score {
                        best_score = dist;
                        best_col = col;
                        best_y = initial_y;
                        best_place_south = true;
                    }
                }
            }

            let frame_x = f64::from(best_col) * stride - self.card_width * 0.5;
            let frame = SpatialRect::new(frame_x, best_y, self.card_width, card_height);

            if let Some(bounds) = self.columns.get_mut(&best_col) {
                if best_place_south {
                    bounds.bottom_y = frame.max_y();
                } else {
                    bounds.top_y = frame.min_y();
                }
            } else {
                self.columns.insert(
                    best_col,
                    ColumnBounds {
                        top_y: frame.min_y(),
                        bottom_y: frame.max_y(),
                    },
                );
            }

            let ring_index = (frame.mid_x().hypot(frame.mid_y()) / stride.max(1.0)).round() as i32;
            let card = PinterestSpatialCard {
                id: pin.id.clone(),
                pin: pin.clone(),
                frame,
                column_index: best_col,
                ring_index,
            };
            self.cards.push(card.clone());
            inserted.push(card);

            if self.cards.len() == 1 {
                self.content_bounds = frame;
            } else {
                self.content_bounds = self.content_bounds.union(frame);
            }
        }

        inserted
    }

    pub fn visible_cards(
        &self,
        world_rect: SpatialRect,
        overscan: f64,
    ) -> Vec<&PinterestSpatialCard> {
        let query = world_rect.inset_by(-overscan, -overscan);
        self.cards
            .iter()
            .filter(|card| card.frame.intersects(query))
            .collect()
    }

    pub fn is_approaching_edge(&self, world_rect: SpatialRect, threshold: f64) -> bool {
        if self.cards.is_empty() {
            return true;
        }
        world_rect.min_x() <= self.content_bounds.min_x() + threshold
            || world_rect.max_x() >= self.content_bounds.max_x() - threshold
            || world_rect.min_y() <= self.content_bounds.min_y() + threshold
            || world_rect.max_y() >= self.content_bounds.max_y() - threshold
    }

    /// Returns offscreen cards inside the directional lookahead halo ordered nearest to the
    /// projected focus center so media prefetching prioritizes incoming travel direction.
    pub fn predictive_prefetch_cards(
        &self,
        world_rect: SpatialRect,
        lookahead_offset: SpatialSize,
        halo: f64,
        limit: usize,
    ) -> Vec<&PinterestSpatialCard> {
        if self.cards.is_empty() || limit == 0 {
            return Vec::new();
        }

        let projected = SpatialRect::new(
            world_rect.x + lookahead_offset.width,
            world_rect.y + lookahead_offset.height,
            world_rect.width,
            world_rect.height,
        );
        let search_rect = world_rect.union(projected).inset_by(-halo, -halo);
        let focus_x = world_rect.mid_x() + lookahead_offset.width * 0.72;
        let focus_y = world_rect.mid_y() + lookahead_offset.height * 0.72;

        let mut scored: Vec<(&PinterestSpatialCard, f64)> = Vec::new();
        for card in &self.cards {
            if !card.frame.intersects(search_rect) || card.frame.intersects(world_rect) {
                continue;
            }
            let dx = card.frame.mid_x() - focus_x;
            let dy = card.frame.mid_y() - focus_y;
            scored.push((card, dx * dx + dy * dy));
        }

        scored.sort_by(|a, b| a.1.total_cmp(&b.1));
        scored.into_iter().take(limit).map(|(c, _)| c).collect()
    }

    fn column_stagger(col: i32, gap: f64) -> f64 {
        const PATTERN: [f64; 7] = [0.0, 38.0, -28.0, 52.0, -18.0, 26.0, -44.0];
        let idx = (col.unsigned_abs() as usize) % PATTERN.len();
        let sign = if col < 0 { -1.0 } else { 1.0 };
        PATTERN[idx] * sign + if col == 0 { 0.0 } else { gap * 0.25 }
    }
}

// MARK: - 2D Camera Transform

#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
pub struct InfiniteSpatialCamera {
    pub offset: SpatialPoint,
    pub scale: f64,
}

impl Default for InfiniteSpatialCamera {
    fn default() -> Self {
        Self {
            offset: SpatialPoint::default(),
            scale: 0.90,
        }
    }
}

impl InfiniteSpatialCamera {
    pub const MIN_SCALE: f64 = 0.24;
    pub const MAX_SCALE: f64 = 3.20;

    pub fn new(offset: SpatialPoint, scale: f64) -> Self {
        Self {
            offset,
            scale: scale.clamp(Self::MIN_SCALE, Self::MAX_SCALE),
        }
    }

    pub fn world_to_screen(self, world: SpatialPoint) -> SpatialPoint {
        SpatialPoint {
            x: world.x * self.scale + self.offset.x,
            y: world.y * self.scale + self.offset.y,
        }
    }

    pub fn screen_to_world(self, screen: SpatialPoint) -> SpatialPoint {
        let safe_scale = self.scale.max(0.001);
        SpatialPoint {
            x: (screen.x - self.offset.x) / safe_scale,
            y: (screen.y - self.offset.y) / safe_scale,
        }
    }

    /// Anchor-locked zoom keeping the world point underneath `anchor` stationary on screen.
    pub fn zoom(&mut self, new_scale: f64, anchor: SpatialPoint) {
        let clamped = new_scale.clamp(Self::MIN_SCALE, Self::MAX_SCALE);
        let world_before = self.screen_to_world(anchor);
        self.scale = clamped;
        self.offset = SpatialPoint {
            x: anchor.x - world_before.x * clamped,
            y: anchor.y - world_before.y * clamped,
        };
    }

    pub fn visible_world_rect(self, viewport: SpatialSize) -> SpatialRect {
        let top_left = self.screen_to_world(SpatialPoint { x: 0.0, y: 0.0 });
        let bottom_right = self.screen_to_world(SpatialPoint {
            x: viewport.width,
            y: viewport.height,
        });
        SpatialRect::new(
            top_left.x,
            top_left.y,
            (bottom_right.x - top_left.x).max(0.0),
            (bottom_right.y - top_left.y).max(0.0),
        )
    }

    pub fn center_on_origin(&mut self, viewport: SpatialSize, scale: f64) {
        self.scale = scale.clamp(Self::MIN_SCALE, Self::MAX_SCALE);
        self.offset = SpatialPoint {
            x: viewport.width * 0.5,
            y: viewport.height * 0.5,
        };
    }
}

// MARK: - Batch Import & Board Import Models

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PinterestBatchImportReport {
    pub imported_assets: Vec<AssetRecord>,
    #[serde(rename = "skippedDuplicatePinIDs")]
    pub skipped_duplicate_pin_ids: Vec<String>,
    #[serde(rename = "failedPinIDs")]
    pub failed_pin_ids: Vec<String>,
    pub errors: Vec<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum PinterestBoardImportDestination {
    /// Creates or reuses top-level `"Pinterest"` folder and creates one subfolder per board.
    PinterestRootFolder,
    /// Creates each board directly as a top-level folder in Charkle library root.
    LibraryRoot,
    /// Creates each board as a subfolder inside an existing Charkle folder.
    ExistingFolder {
        #[serde(rename = "folderID", with = "upper_uuid")]
        folder_id: Uuid,
    },
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PinterestBoardImportProgress {
    pub total_boards: usize,
    pub completed_boards: usize,
    pub current_board_name: String,
    pub current_board_index: usize,
    pub current_board_pin_count: usize,
    pub current_board_processed_pins: usize,
    pub imported_count: usize,
    pub skipped_count: usize,
    pub failed_count: usize,
    pub phase_message: String,
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PinterestBoardsImportReport {
    #[serde(rename = "createdOrReusedFolderIDs", with = "upper_uuid_vec")]
    pub created_or_reused_folder_ids: Vec<Uuid>,
    pub imported_asset_count: usize,
    pub skipped_duplicate_count: usize,
    pub failed_pin_count: usize,
    pub errors: Vec<String>,
    pub was_cancelled: bool,
}
