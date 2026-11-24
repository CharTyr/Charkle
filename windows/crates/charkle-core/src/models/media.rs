//! Media, cache, vector, and intelligence contracts mirroring
//! `Sources/CharkleCore/Contracts/MediaModels.swift` and `Database/AssetVector.swift`.

use std::path::PathBuf;

use chrono::{DateTime, Utc};
use serde::{Deserialize, Deserializer, Serialize, Serializer};
use uuid::Uuid;

use crate::models::core::{AssetRecord, LabColor, SocialPostMetadata};
use crate::models::moodboard::NormalizedCropRect;
use crate::wire::swift_codec::{base64_data_opt, cocoa_date_opt, upper_uuid, upper_uuid_opt};

/// All supported asset ingestion forms matching `CaptureInput` in Swift.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum CaptureInput {
    FilePath(PathBuf),
    ImageData {
        data: Vec<u8>,
        suggested_name: String,
        source_url: Option<String>,
    },
    WebUrl {
        url: String,
        title: Option<String>,
        notes: Option<String>,
    },
    SocialBookmark {
        metadata: Box<SocialPostMetadata>,
        cover_image_data: Option<Vec<u8>>,
        tags: Vec<String>,
    },
    TextSnippet {
        title: String,
        text: String,
        source_url: Option<String>,
    },
    ColorSwatch {
        hex: String,
        title: Option<String>,
    },
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum ThumbnailTier {
    Grid520,
    Preview1400,
}

impl ThumbnailTier {
    pub fn max_side(self) -> u32 {
        match self {
            Self::Grid520 => 520,
            Self::Preview1400 => 1400,
        }
    }

    pub fn raw_value(self) -> &'static str {
        match self {
            Self::Grid520 => "grid520",
            Self::Preview1400 => "preview1400",
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CacheStats {
    pub thumbnail_bytes: i64,
    pub original_cache_bytes: i64,
    pub pinned_offline_bytes: i64,
    pub budget_bytes: i64,
    pub cached_original_count: usize,
    pub pinned_asset_count: usize,
}

impl Default for CacheStats {
    fn default() -> Self {
        Self {
            thumbnail_bytes: 0,
            original_cache_bytes: 0,
            pinned_offline_bytes: 0,
            budget_bytes: 10 * 1024 * 1024 * 1024,
            cached_original_count: 0,
            pinned_asset_count: 0,
        }
    }
}

/// Embedding BLOB numeric precision matching Swift `EmbeddingPrecision` (`16` or `32`).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default)]
pub enum EmbeddingPrecision {
    #[default]
    Float16,
    Float32,
}

impl EmbeddingPrecision {
    pub fn raw_value(self) -> i32 {
        match self {
            Self::Float16 => 16,
            Self::Float32 => 32,
        }
    }

    pub fn from_raw(value: i32) -> Self {
        if value == 32 {
            Self::Float32
        } else {
            Self::Float16
        }
    }

    pub fn encode(self, values: &[f32]) -> Vec<u8> {
        match self {
            Self::Float16 => {
                let mut out = Vec::with_capacity(values.len() * 2);
                for &v in values {
                    out.extend_from_slice(&f32_to_f16_bits(v).to_le_bytes());
                }
                out
            }
            Self::Float32 => {
                let mut out = Vec::with_capacity(values.len() * 4);
                for &v in values {
                    out.extend_from_slice(&v.to_bits().to_le_bytes());
                }
                out
            }
        }
    }

    pub fn decode(self, bytes: &[u8]) -> Vec<f32> {
        match self {
            Self::Float16 => bytes
                .chunks_exact(2)
                .map(|c| f16_bits_to_f32(u16::from_le_bytes([c[0], c[1]])))
                .collect(),
            Self::Float32 => bytes
                .chunks_exact(4)
                .map(|c| f32::from_bits(u32::from_le_bytes([c[0], c[1], c[2], c[3]])))
                .collect(),
        }
    }
}

impl Serialize for EmbeddingPrecision {
    fn serialize<S>(&self, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: Serializer,
    {
        serializer.serialize_i32(self.raw_value())
    }
}

impl<'de> Deserialize<'de> for EmbeddingPrecision {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: Deserializer<'de>,
    {
        let raw = i32::deserialize(deserializer)?;
        Ok(Self::from_raw(raw))
    }
}

/// IEEE-754 binary32 -> binary16 conversion (round-to-nearest-even).
pub fn f32_to_f16_bits(value: f32) -> u16 {
    let bits = value.to_bits();
    let sign = ((bits >> 16) & 0x8000) as u16;
    let exp = ((bits >> 23) & 0xFF) as i32;
    let frac = bits & 0x007F_FFFF;

    if exp == 0xFF {
        if frac == 0 {
            return sign | 0x7C00; // Inf
        }
        return sign | 0x7E00 | ((frac >> 13) as u16); // NaN
    }

    let unbiased = exp - 127;
    if unbiased > 15 {
        return sign | 0x7C00; // Overflow to Inf
    }
    if unbiased < -24 {
        return sign; // Underflow to signed zero
    }
    if unbiased < -14 {
        // Subnormal binary16
        let mant = frac | 0x0080_0000;
        let shift = (-14 - unbiased) as u32 + 13;
        let half_mant = mant >> shift;
        let rem = mant & ((1u32 << shift) - 1);
        let halfway = 1u32 << (shift - 1);
        let rounded = if rem > halfway || (rem == halfway && (half_mant & 1) != 0) {
            half_mant + 1
        } else {
            half_mant
        };
        return sign | (rounded as u16);
    }

    let h_exp = ((unbiased + 15) as u16) << 10;
    let h_frac = (frac >> 13) as u16;
    let rem = frac & 0x1FFF;
    let rounded = if rem > 0x1000 || (rem == 0x1000 && (h_frac & 1) != 0) {
        (h_exp | h_frac) + 1
    } else {
        h_exp | h_frac
    };
    sign | rounded
}

/// IEEE-754 binary16 -> binary32 conversion.
pub fn f16_bits_to_f32(bits: u16) -> f32 {
    let sign = ((bits & 0x8000) as u32) << 16;
    let exp = ((bits >> 10) & 0x1F) as u32;
    let frac = (bits & 0x03FF) as u32;

    if exp == 0 {
        if frac == 0 {
            return f32::from_bits(sign);
        }
        let mut f = frac;
        let mut e = 127 - 14;
        while (f & 0x0400) == 0 {
            f <<= 1;
            e -= 1;
        }
        f &= 0x03FF;
        return f32::from_bits(sign | (e << 23) | (f << 13));
    }
    if exp == 0x1F {
        if frac == 0 {
            return f32::from_bits(sign | 0x7F80_0000);
        }
        return f32::from_bits(sign | 0x7FC0_0000 | (frac << 13));
    }
    let f_exp = (exp + (127 - 15)) << 23;
    f32::from_bits(sign | f_exp | (frac << 13))
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AssetVector {
    #[serde(
        default,
        skip_serializing_if = "Option::is_none",
        with = "base64_data_opt"
    )]
    pub feature_print: Option<Vec<u8>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub embedding: Option<Vec<f32>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub embedding_model: Option<String>,
    #[serde(default)]
    pub precision: EmbeddingPrecision,
}

impl Default for AssetVector {
    fn default() -> Self {
        Self {
            feature_print: None,
            embedding: None,
            embedding_model: None,
            precision: EmbeddingPrecision::Float16,
        }
    }
}

/// Computes cosine similarity in `[-1.0, 1.0]` between two equal-length embeddings.
pub fn cosine_similarity(a: &[f32], b: &[f32]) -> Option<f32> {
    if a.is_empty() || a.len() != b.len() {
        return None;
    }
    let mut dot = 0.0_f64;
    let mut norm_a = 0.0_f64;
    let mut norm_b = 0.0_f64;
    for (&x, &y) in a.iter().zip(b.iter()) {
        let xf = x as f64;
        let yf = y as f64;
        dot += xf * yf;
        norm_a += xf * xf;
        norm_b += yf * yf;
    }
    let denom = norm_a.sqrt() * norm_b.sqrt();
    if denom <= f64::EPSILON {
        return None;
    }
    Some((dot / denom).clamp(-1.0, 1.0) as f32)
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum CloudAIProviderKind {
    #[default]
    Disabled,
    #[serde(rename = "chatGPTSubscription")]
    ChatGptSubscription,
    Gemini,
    #[serde(rename = "openAICompatible")]
    OpenAiCompatible,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum ChatGPTConnectionStatus {
    #[default]
    Disconnected,
    Connected,
    ReauthRequired,
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ChatGPTAccountSession {
    #[serde(default)]
    pub status: ChatGPTConnectionStatus,
    #[serde(default)]
    pub sharing_enabled: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub email: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub name: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub subject: Option<String>,
    #[serde(
        default,
        skip_serializing_if = "Option::is_none",
        with = "cocoa_date_opt"
    )]
    pub last_updated_at: Option<DateTime<Utc>>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ChatGPTModelInfo {
    pub slug: String,
    pub display_name: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum CustomAIEndpointFormat {
    #[default]
    #[serde(rename = "openAIChatCompletions")]
    OpenAiChatCompletions,
    AnthropicMessages,
    #[serde(rename = "openAIResponses")]
    OpenAiResponses,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AIProviderConfig {
    #[serde(default)]
    pub provider: CloudAIProviderKind,
    #[serde(default)]
    pub custom_endpoint_format: CustomAIEndpointFormat,
    #[serde(rename = "baseURL", default = "default_gemini_base_url")]
    pub base_url: String,
    #[serde(default = "default_gemini_chat_model")]
    pub chat_model: String,
    #[serde(default = "default_gemini_embedding_model")]
    pub embedding_model: String,
    #[serde(default)]
    pub auto_analyze_on_import: bool,
    #[serde(default = "default_true")]
    pub send_thumbnails_to_cloud: bool,
}

fn default_gemini_base_url() -> String {
    "https://generativelanguage.googleapis.com".to_string()
}
fn default_gemini_chat_model() -> String {
    "gemini-2.5-flash".to_string()
}
fn default_gemini_embedding_model() -> String {
    "gemini-embedding-001".to_string()
}
fn default_true() -> bool {
    true
}

impl Default for AIProviderConfig {
    fn default() -> Self {
        Self {
            provider: CloudAIProviderKind::Disabled,
            custom_endpoint_format: CustomAIEndpointFormat::OpenAiChatCompletions,
            base_url: default_gemini_base_url(),
            chat_model: default_gemini_chat_model(),
            embedding_model: default_gemini_embedding_model(),
            auto_analyze_on_import: false,
            send_thumbnails_to_cloud: true,
        }
    }
}

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct LocalAnalysisResult {
    #[serde(default)]
    pub dominant_colors: Vec<LabColor>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub ocr_text: Option<String>,
    #[serde(
        default,
        skip_serializing_if = "Option::is_none",
        with = "base64_data_opt"
    )]
    pub feature_print_data: Option<Vec<u8>>,
}

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CloudEnrichmentResult {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub description: Option<String>,
    #[serde(default)]
    pub suggested_tags: Vec<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub embedding: Option<Vec<f32>>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TypeSafeExperimentalConfig {
    #[serde(default)]
    pub enabled: bool,
    #[serde(rename = "baseURL", default = "default_typesafe_base_url")]
    pub base_url: String,
    #[serde(default = "default_typesafe_model")]
    pub model: String,
    #[serde(default = "default_min_confidence")]
    pub min_confidence: f64,
    #[serde(default = "default_low_conf_padding")]
    pub low_confidence_padding: f64,
    #[serde(default = "default_min_presence")]
    pub min_presence_probability: f64,
    #[serde(default = "default_true")]
    pub enable_moodboard_focus_crop: bool,
    #[serde(default = "default_true")]
    pub enable_auto_clean_crop: bool,
    #[serde(default = "default_true")]
    pub enable_subject_palette: bool,
    #[serde(default = "default_true")]
    pub enable_pinpoint_annotations: bool,
    #[serde(default = "default_true")]
    pub enable_semantic_search: bool,
    #[serde(default = "default_true")]
    pub enable_inbox_smart_triage: bool,
    #[serde(default = "default_true")]
    pub enable_curator_visual_rerank: bool,
}

fn default_typesafe_base_url() -> String {
    "https://api.typesafe.ai".to_string()
}
fn default_typesafe_model() -> String {
    "jev-latest".to_string()
}
fn default_min_confidence() -> f64 {
    0.60
}
fn default_low_conf_padding() -> f64 {
    0.05
}
fn default_min_presence() -> f64 {
    0.45
}

impl Default for TypeSafeExperimentalConfig {
    fn default() -> Self {
        Self {
            enabled: false,
            base_url: default_typesafe_base_url(),
            model: default_typesafe_model(),
            min_confidence: default_min_confidence(),
            low_confidence_padding: default_low_conf_padding(),
            min_presence_probability: default_min_presence(),
            enable_moodboard_focus_crop: true,
            enable_auto_clean_crop: true,
            enable_subject_palette: true,
            enable_pinpoint_annotations: true,
            enable_semantic_search: true,
            enable_inbox_smart_triage: true,
            enable_curator_visual_rerank: true,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct TypeSafeModelInfo {
    pub name: String,
    #[serde(default)]
    pub description: String,
    #[serde(default)]
    pub release_date: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum VisualRegionSource {
    TypeSafeJev,
    AppleVisionSaliency,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct VisualRegionResult {
    pub crop: NormalizedCropRect,
    pub raw_box: NormalizedCropRect,
    pub presence_probability: f64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub confidence: Option<f64>,
    pub did_apply_padding: bool,
    pub found: bool,
    pub source: VisualRegionSource,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub model: Option<String>,
    #[serde(default)]
    pub summary: String,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CleanBoundsResult {
    pub has_noise: bool,
    pub noise_probability: f64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub recommended_crop: Option<NormalizedCropRect>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub confidence: Option<f64>,
    pub did_apply_padding: bool,
    pub source: VisualRegionSource,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub model: Option<String>,
    #[serde(default)]
    pub summary: String,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SubjectPaletteResult {
    pub colors: Vec<LabColor>,
    pub subject_region: VisualRegionResult,
    pub updated_asset: AssetRecord,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SemanticSearchHit {
    pub asset: AssetRecord,
    pub score: f64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub confidence: Option<f64>,
    #[serde(default)]
    pub reason: String,
    #[serde(default)]
    pub source_label: String,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SemanticSearchReport {
    pub query: String,
    pub hits: Vec<SemanticSearchHit>,
    #[serde(default)]
    pub used_type_safe_jev: bool,
    #[serde(default)]
    pub used_cloud_embedding: bool,
    #[serde(default)]
    pub evaluated_visual_count: usize,
    #[serde(default)]
    pub summary: String,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct InboxTriageRecommendation {
    #[serde(rename = "assetID", with = "upper_uuid")]
    pub asset_id: Uuid,
    pub asset_title: String,
    #[serde(
        rename = "recommendedFolderID",
        default,
        skip_serializing_if = "Option::is_none",
        with = "upper_uuid_opt"
    )]
    pub recommended_folder_id: Option<Uuid>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub recommended_folder_name: Option<String>,
    pub confidence: f64,
    pub fit_probability: f64,
    pub reason: String,
    pub source: VisualRegionSource,
}
