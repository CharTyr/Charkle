//! Moodboard models mirroring `Sources/CharkleCore/Contracts/MoodboardModels.swift`
//! with exact Swift keyed-enum wire serialization.

use chrono::{DateTime, Utc};
use serde::{Deserialize, Deserializer, Serialize, Serializer};
use uuid::Uuid;

use crate::models::core::{LabColor, ScoredAsset};
use crate::wire::swift_codec::{cocoa_date, upper_uuid, upper_uuid_vec};

#[derive(Debug, Clone, Copy, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct BoardPoint {
    pub x: f64,
    pub y: f64,
}

impl BoardPoint {
    pub const ZERO: Self = Self { x: 0.0, y: 0.0 };

    pub fn new(x: f64, y: f64) -> Self {
        Self { x, y }
    }
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct BoardRect {
    pub x: f64,
    pub y: f64,
    pub width: f64,
    pub height: f64,
}

impl BoardRect {
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
    pub fn min_y(self) -> f64 {
        self.y
    }
    pub fn max_x(self) -> f64 {
        self.x + self.width
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
}

#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct NormalizedCropRect {
    pub x: f64,
    pub y: f64,
    pub width: f64,
    pub height: f64,
}

impl Default for NormalizedCropRect {
    fn default() -> Self {
        Self::FULL
    }
}

fn finite_or(v: f64, fallback: f64) -> f64 {
    if v.is_finite() {
        v
    } else {
        fallback
    }
}

impl NormalizedCropRect {
    pub const FULL: Self = Self {
        x: 0.0,
        y: 0.0,
        width: 1.0,
        height: 1.0,
    };

    pub fn from_box(top: f64, bottom: f64, left: f64, right: f64) -> Self {
        let clamped_left = finite_or(left, 0.0).clamp(0.0, 1.0);
        let clamped_right = finite_or(right, 1.0).clamp(clamped_left, 1.0);
        let clamped_top = finite_or(top, 0.0).clamp(0.0, 1.0);
        let clamped_bottom = finite_or(bottom, 1.0).clamp(clamped_top, 1.0);
        Self {
            x: clamped_left,
            y: clamped_top,
            width: (clamped_right - clamped_left).max(0.02),
            height: (clamped_bottom - clamped_top).max(0.02),
        }
    }

    pub fn area(self) -> f64 {
        let w = finite_or(self.width, 0.0).max(0.0);
        let h = finite_or(self.height, 0.0).max(0.0);
        w * h
    }

    pub fn center_point(self) -> BoardPoint {
        let x = finite_or(self.x, 0.0);
        let y = finite_or(self.y, 0.0);
        let w = finite_or(self.width, 1.0);
        let h = finite_or(self.height, 1.0);
        BoardPoint {
            x: (x + w * 0.5).clamp(0.0, 1.0),
            y: (y + h * 0.5).clamp(0.0, 1.0),
        }
    }

    pub fn is_meaningful_subregion(self) -> bool {
        let w = finite_or(self.width, 1.0);
        let h = finite_or(self.height, 1.0);
        w >= 0.04 && h >= 0.04 && self.area() < 0.96
    }

    pub fn clamped(self) -> Self {
        let raw_x = finite_or(self.x, 0.0);
        let raw_y = finite_or(self.y, 0.0);
        let raw_w = finite_or(self.width, 1.0);
        let raw_h = finite_or(self.height, 1.0);
        let left = raw_x.clamp(0.0, 0.98);
        let top = raw_y.clamp(0.0, 0.98);
        let min_right = (left + 0.02).min(1.0);
        let min_bottom = (top + 0.02).min(1.0);
        let right = (raw_x + raw_w).clamp(min_right, 1.0);
        let bottom = (raw_y + raw_h).clamp(min_bottom, 1.0);
        Self {
            x: left,
            y: top,
            width: (right - left).max(0.02),
            height: (bottom - top).max(0.02),
        }
    }

    pub fn padded(self, fraction: f64) -> Self {
        let base = self.clamped();
        let pad = finite_or(fraction, 0.0).clamp(0.0, 0.35);
        let left = (base.x - pad).max(0.0);
        let top = (base.y - pad).max(0.0);
        let right = (base.x + base.width + pad).min(1.0);
        let bottom = (base.y + base.height + pad).min(1.0);
        Self {
            x: left,
            y: top,
            width: (right - left).max(0.02),
            height: (bottom - top).max(0.02),
        }
    }

    pub fn mapping_image_point_to_visible(self, point: BoardPoint) -> BoardPoint {
        let w = finite_or(self.width, 1.0);
        let h = finite_or(self.height, 1.0);
        if w <= 0.01 || h <= 0.01 {
            return BoardPoint {
                x: finite_or(point.x, 0.5).clamp(0.0, 1.0),
                y: finite_or(point.y, 0.5).clamp(0.0, 1.0),
            };
        }
        let vx = (finite_or(point.x, 0.5) - finite_or(self.x, 0.0)) / w;
        let vy = (finite_or(point.y, 0.5) - finite_or(self.y, 0.0)) / h;
        BoardPoint {
            x: finite_or(vx, 0.5).clamp(0.02, 0.98),
            y: finite_or(vy, 0.5).clamp(0.02, 0.98),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum EditorialStyle {
    #[default]
    Balanced,
    Magazine,
    Compact,
}

#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AutoLayoutConfig {
    #[serde(default = "default_columns")]
    pub columns: i32,
    #[serde(default = "default_spacing")]
    pub spacing: f64,
    #[serde(default)]
    pub style: EditorialStyle,
    #[serde(default = "default_true")]
    pub show_palette_strip: bool,
}

fn default_columns() -> i32 {
    4
}
fn default_spacing() -> f64 {
    16.0
}
fn default_true() -> bool {
    true
}

impl Default for AutoLayoutConfig {
    fn default() -> Self {
        Self {
            columns: 4,
            spacing: 16.0,
            style: EditorialStyle::Balanced,
            show_palette_strip: true,
        }
    }
}

/// Swift-wire-compatible `BoardLayoutMode`:
/// - `AutoEditorial(cfg)` <-> `{"autoEditorial":{"_0":{...}}}`
/// - `Freeform` <-> `{"freeform":{}}`
#[derive(Debug, Clone, Copy, PartialEq, Default)]
pub enum BoardLayoutMode {
    AutoEditorial(AutoLayoutConfig),
    #[default]
    Freeform,
}

impl BoardLayoutMode {
    pub fn is_auto_editorial(self) -> bool {
        matches!(self, Self::AutoEditorial(_))
    }
}

#[derive(Serialize, Deserialize)]
struct SwiftAutoEditorialWrapper {
    #[serde(rename = "_0")]
    inner: AutoLayoutConfig,
}

#[derive(Serialize, Deserialize)]
struct SwiftEmptyObject {}

#[derive(Serialize, Deserialize)]
enum SwiftBoardLayoutModeWire {
    #[serde(rename = "autoEditorial")]
    AutoEditorial(SwiftAutoEditorialWrapper),
    #[serde(rename = "freeform")]
    Freeform(SwiftEmptyObject),
}

impl Serialize for BoardLayoutMode {
    fn serialize<S>(&self, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: Serializer,
    {
        match *self {
            Self::AutoEditorial(cfg) => {
                SwiftBoardLayoutModeWire::AutoEditorial(SwiftAutoEditorialWrapper { inner: cfg })
                    .serialize(serializer)
            }
            Self::Freeform => {
                SwiftBoardLayoutModeWire::Freeform(SwiftEmptyObject {}).serialize(serializer)
            }
        }
    }
}

impl<'de> Deserialize<'de> for BoardLayoutMode {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: Deserializer<'de>,
    {
        match SwiftBoardLayoutModeWire::deserialize(deserializer)? {
            SwiftBoardLayoutModeWire::AutoEditorial(w) => Ok(Self::AutoEditorial(w.inner)),
            SwiftBoardLayoutModeWire::Freeform(_) => Ok(Self::Freeform),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum NoteStyle {
    #[default]
    Paper,
    Ink,
    Warm,
    Sage,
    Slate,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum GroupTint {
    #[default]
    Neutral,
    Sand,
    Sage,
    Slate,
    Terracotta,
    Ocean,
}

/// Swift-wire-compatible `BoardNodeKind`:
/// - `AssetRef` <-> `{"assetRef":{"assetID":...,"crop":...,"weight":...,"autoplayLoop":...}}`
/// - `Note` <-> `{"note":{"title":...,"text":...,"style":...,"fontSize":...}}`
/// - `GroupFrame` <-> `{"groupFrame":{"title":...,"tint":...}}`
/// - `PaletteStrip` <-> `{"paletteStrip":{"colors":...,"autoSyncWithBoard":...}}`
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum BoardNodeKind {
    AssetRef {
        #[serde(rename = "assetID", with = "upper_uuid")]
        asset_id: Uuid,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        crop: Option<NormalizedCropRect>,
        #[serde(default = "default_weight")]
        weight: i32,
        #[serde(rename = "autoplayLoop", default)]
        autoplay_loop: bool,
    },
    Note {
        #[serde(default, skip_serializing_if = "Option::is_none")]
        title: Option<String>,
        #[serde(default)]
        text: String,
        #[serde(default)]
        style: NoteStyle,
        #[serde(rename = "fontSize", default = "default_font_size")]
        font_size: f64,
    },
    GroupFrame {
        #[serde(default)]
        title: String,
        #[serde(default)]
        tint: GroupTint,
    },
    PaletteStrip {
        #[serde(default)]
        colors: Vec<LabColor>,
        #[serde(rename = "autoSyncWithBoard", default)]
        auto_sync_with_board: bool,
    },
}

fn default_weight() -> i32 {
    1
}
fn default_font_size() -> f64 {
    14.0
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct BoardNode {
    #[serde(with = "upper_uuid")]
    pub id: Uuid,
    pub kind: BoardNodeKind,
    #[serde(default)]
    pub frame: BoardRect,
    #[serde(default)]
    pub z_index: i32,
    #[serde(default)]
    pub rotation_degrees: f64,
    #[serde(default)]
    pub flip_horizontal: bool,
    #[serde(default)]
    pub flip_vertical: bool,
    #[serde(default)]
    pub is_locked: bool,
    #[serde(default)]
    pub editorial_order: i32,
    #[serde(default = "Utc::now", with = "cocoa_date")]
    pub updated_at: DateTime<Utc>,
}

impl BoardNode {
    pub fn referenced_asset_id(&self) -> Option<Uuid> {
        match self.kind {
            BoardNodeKind::AssetRef { asset_id, .. } => Some(asset_id),
            _ => None,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum ConnectorAnchor {
    #[default]
    Auto,
    Top,
    Bottom,
    Leading,
    Trailing,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum ConnectorStyle {
    #[default]
    Curved,
    Elbow,
    Straight,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct BoardConnector {
    #[serde(with = "upper_uuid")]
    pub id: Uuid,
    #[serde(rename = "fromNodeID", with = "upper_uuid")]
    pub from_node_id: Uuid,
    #[serde(default)]
    pub from_anchor: ConnectorAnchor,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub from_normalized_point: Option<BoardPoint>,
    #[serde(rename = "toNodeID", with = "upper_uuid")]
    pub to_node_id: Uuid,
    #[serde(default)]
    pub to_anchor: ConnectorAnchor,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub to_normalized_point: Option<BoardPoint>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub label: Option<String>,
    #[serde(default = "default_connector_color")]
    pub color_hex: String,
    #[serde(default)]
    pub style: ConnectorStyle,
    #[serde(default)]
    pub dashed: bool,
    #[serde(default = "Utc::now", with = "cocoa_date")]
    pub updated_at: DateTime<Utc>,
}

fn default_connector_color() -> String {
    "#5C6672".to_string()
}

#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct InkStrokePoint {
    pub x: f64,
    pub y: f64,
    #[serde(default = "default_pressure")]
    pub pressure: f64,
}

fn default_pressure() -> f64 {
    0.5
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct InkStroke {
    #[serde(with = "upper_uuid")]
    pub id: Uuid,
    #[serde(default)]
    pub points: Vec<InkStrokePoint>,
    #[serde(default = "default_ink_color")]
    pub color_hex: String,
    #[serde(default = "default_ink_width")]
    pub line_width: f64,
    #[serde(default = "default_ink_opacity")]
    pub opacity: f64,
    #[serde(default = "default_ink_z_index")]
    pub z_index: i32,
    #[serde(default = "Utc::now", with = "cocoa_date")]
    pub created_at: DateTime<Utc>,
}

fn default_ink_color() -> String {
    "#E05A47".to_string()
}
fn default_ink_width() -> f64 {
    3.0
}
fn default_ink_opacity() -> f64 {
    0.92
}
fn default_ink_z_index() -> i32 {
    1000
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MoodboardDocument {
    #[serde(with = "upper_uuid")]
    pub id: Uuid,
    pub title: String,
    #[serde(default)]
    pub subtitle: String,
    #[serde(default)]
    pub mode: BoardLayoutMode,
    #[serde(default)]
    pub nodes: Vec<BoardNode>,
    #[serde(default)]
    pub connectors: Vec<BoardConnector>,
    #[serde(default)]
    pub ink_strokes: Vec<InkStroke>,
    #[serde(default)]
    pub extracted_palette: Vec<LabColor>,
    #[serde(rename = "candidateAssetIDs", default, with = "upper_uuid_vec")]
    pub candidate_asset_ids: Vec<Uuid>,
    #[serde(default)]
    pub pinned_offline: bool,
    #[serde(default)]
    pub viewport_center: BoardPoint,
    #[serde(default = "default_zoom")]
    pub viewport_zoom: f64,
    #[serde(with = "cocoa_date")]
    pub created_at: DateTime<Utc>,
    #[serde(with = "cocoa_date")]
    pub updated_at: DateTime<Utc>,
    #[serde(rename = "updatedHLC", default)]
    pub updated_hlc: i64,
}

fn default_zoom() -> f64 {
    1.0
}

impl MoodboardDocument {
    pub fn new(title: impl Into<String>) -> Self {
        let now = Utc::now();
        Self {
            id: Uuid::new_v4(),
            title: title.into(),
            subtitle: String::new(),
            mode: BoardLayoutMode::Freeform,
            nodes: Vec::new(),
            connectors: Vec::new(),
            ink_strokes: Vec::new(),
            extracted_palette: Vec::new(),
            candidate_asset_ids: Vec::new(),
            pinned_offline: false,
            viewport_center: BoardPoint::ZERO,
            viewport_zoom: 1.0,
            created_at: now,
            updated_at: now,
            updated_hlc: 0,
        }
    }

    pub fn referenced_asset_ids(&self) -> Vec<Uuid> {
        self.nodes
            .iter()
            .filter_map(BoardNode::referenced_asset_id)
            .collect()
    }

    pub fn to_summary(&self) -> MoodboardSummary {
        let preview_asset_ids: Vec<Uuid> =
            self.referenced_asset_ids().into_iter().take(4).collect();
        let palette_hexes: Vec<String> = self
            .extracted_palette
            .iter()
            .map(|c| c.hex.clone())
            .collect();
        MoodboardSummary {
            id: self.id,
            title: self.title.clone(),
            subtitle: self.subtitle.clone(),
            mode: self.mode,
            item_count: self.nodes.len(),
            preview_asset_ids,
            palette_hexes,
            pinned_offline: self.pinned_offline,
            updated_at: self.updated_at,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MoodboardSummary {
    #[serde(with = "upper_uuid")]
    pub id: Uuid,
    pub title: String,
    #[serde(default)]
    pub subtitle: String,
    #[serde(default)]
    pub mode: BoardLayoutMode,
    #[serde(default)]
    pub item_count: usize,
    #[serde(rename = "previewAssetIDs", default, with = "upper_uuid_vec")]
    pub preview_asset_ids: Vec<Uuid>,
    #[serde(default)]
    pub palette_hexes: Vec<String>,
    #[serde(default)]
    pub pinned_offline: bool,
    #[serde(with = "cocoa_date")]
    pub updated_at: DateTime<Utc>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum MoodboardSeed {
    Prompt(String),
    SeedAssets(#[serde(with = "upper_uuid_vec")] Vec<Uuid>),
    Palette {
        colors: Vec<LabColor>,
        tolerance: f64,
    },
    ManualSelection(#[serde(with = "upper_uuid_vec")] Vec<Uuid>),
    Combined {
        prompt: Option<String>,
        #[serde(rename = "seedAssetIDs", with = "upper_uuid_vec")]
        seed_asset_ids: Vec<Uuid>,
        palette: Vec<LabColor>,
    },
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum MoodboardAgentPhase {
    Planning,
    Retrieving,
    InspectingVisuals,
    Composing,
    Verifying,
    Repairing,
    Completed,
    FallbackOffline,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum MoodboardAgentStepStatus {
    #[default]
    Running,
    Done,
    Warning,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MoodboardAgentStep {
    #[serde(with = "upper_uuid")]
    pub id: Uuid,
    pub phase: MoodboardAgentPhase,
    pub title: String,
    #[serde(default)]
    pub detail: String,
    #[serde(default)]
    pub status: MoodboardAgentStepStatus,
    #[serde(with = "cocoa_date")]
    pub timestamp: DateTime<Utc>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MoodboardSectionDraft {
    #[serde(with = "upper_uuid")]
    pub id: Uuid,
    pub title: String,
    #[serde(default)]
    pub tint: GroupTint,
    #[serde(default)]
    pub rationale: String,
    #[serde(rename = "assetIDs", with = "upper_uuid_vec")]
    pub asset_ids: Vec<Uuid>,
    #[serde(rename = "heroAssetIDs", default, with = "upper_uuid_vec")]
    pub hero_asset_ids: Vec<Uuid>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MoodboardCurationRequest {
    #[serde(default)]
    pub prompt: String,
    #[serde(rename = "seedAssetIDs", default, with = "upper_uuid_vec")]
    pub seed_asset_ids: Vec<Uuid>,
    #[serde(rename = "scopeFolderIDs", default, with = "upper_uuid_vec")]
    pub scope_folder_ids: Vec<Uuid>,
    #[serde(default)]
    pub required_tags: Vec<String>,
    #[serde(default)]
    pub target_palette: Vec<LabColor>,
    #[serde(default = "default_curation_tolerance")]
    pub color_tolerance: f64,
    #[serde(default = "default_preferred_count")]
    pub preferred_count: usize,
    #[serde(default = "default_candidate_count")]
    pub candidate_count: usize,
    #[serde(default = "default_magazine_style")]
    pub layout_style: EditorialStyle,
    #[serde(default = "default_true")]
    pub use_freeform_layout: bool,
    #[serde(default = "default_true")]
    pub include_curator_notes: bool,
    #[serde(rename = "excludedAssetIDs", default, with = "upper_uuid_vec")]
    pub excluded_asset_ids: Vec<Uuid>,
    #[serde(rename = "lockedAssetIDs", default, with = "upper_uuid_vec")]
    pub locked_asset_ids: Vec<Uuid>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub existing_board: Option<MoodboardDocument>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub refinement_instruction: Option<String>,
    #[serde(default)]
    pub auto_focus_detail_crop: bool,
}

fn default_curation_tolerance() -> f64 {
    28.0
}
fn default_preferred_count() -> usize {
    12
}
fn default_candidate_count() -> usize {
    24
}
fn default_magazine_style() -> EditorialStyle {
    EditorialStyle::Magazine
}

impl Default for MoodboardCurationRequest {
    fn default() -> Self {
        Self {
            prompt: String::new(),
            seed_asset_ids: Vec::new(),
            scope_folder_ids: Vec::new(),
            required_tags: Vec::new(),
            target_palette: Vec::new(),
            color_tolerance: 28.0,
            preferred_count: 12,
            candidate_count: 24,
            layout_style: EditorialStyle::Magazine,
            use_freeform_layout: true,
            include_curator_notes: true,
            excluded_asset_ids: Vec::new(),
            locked_asset_ids: Vec::new(),
            existing_board: None,
            refinement_instruction: None,
            auto_focus_detail_crop: false,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MoodboardProposal {
    pub draft_document: MoodboardDocument,
    pub primary_matches: Vec<ScoredAsset>,
    pub candidate_pool: Vec<ScoredAsset>,
    pub extracted_palette: Vec<LabColor>,
    pub used_cloud_ai: bool,
    #[serde(default)]
    pub curated_summary: String,
    #[serde(default)]
    pub agent_trace: Vec<MoodboardAgentStep>,
    #[serde(default)]
    pub sections: Vec<MoodboardSectionDraft>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub rejected_summary: Option<String>,
    #[serde(default)]
    pub cached_visual_insights_count: usize,
}
