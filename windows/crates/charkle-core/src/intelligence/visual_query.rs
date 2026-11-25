//! Perceptual CIELAB `VisualTone` classification and cross-lingual EN ↔ ZH
//! `VisualQueryIntelligence` for zero-cloud-cost local semantic recall.
//!
//! Direct 1:1 port of `Sources/CharkleCore/Intelligence/VisualQueryIntelligence.swift`.

use std::collections::HashSet;

use serde::{Deserialize, Serialize};

use crate::db::search_text;
use crate::models::core::{AspectShape, AssetRecord, LabColor};

/// Perceptual visual tone derived directly from an asset's stored CIELAB `dominant_colors`
/// (`L*` lightness, `C*` chroma, `a*/b*` warmth/coolness, and inter-swatch contrast).
/// Runs 100% locally in sub-millisecond time with zero cloud cost.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum VisualTone {
    #[serde(rename = "dark")]
    Dark,
    #[serde(rename = "light")]
    Light,
    #[serde(rename = "warm")]
    Warm,
    #[serde(rename = "cool")]
    Cool,
    #[serde(rename = "vivid")]
    Vivid,
    #[serde(rename = "muted")]
    Muted,
    #[serde(rename = "high_contrast")]
    HighContrast,
}

impl VisualTone {
    pub const ALL: [VisualTone; 7] = [
        VisualTone::Dark,
        VisualTone::Light,
        VisualTone::Warm,
        VisualTone::Cool,
        VisualTone::Vivid,
        VisualTone::Muted,
        VisualTone::HighContrast,
    ];

    pub const fn raw_value(self) -> &'static str {
        match self {
            Self::Dark => "dark",
            Self::Light => "light",
            Self::Warm => "warm",
            Self::Cool => "cool",
            Self::Vivid => "vivid",
            Self::Muted => "muted",
            Self::HighContrast => "high_contrast",
        }
    }

    pub fn parse(raw: Option<&str>) -> Option<Self> {
        let cleaned = raw?.trim().to_lowercase();
        if cleaned.is_empty() {
            return None;
        }
        match cleaned.as_str() {
            "dark" | "暗调" | "深色" | "暗" => Some(Self::Dark),
            "light" | "bright" | "浅色" | "明亮" | "白底" | "浅" => Some(Self::Light),
            "warm" | "暖色" | "暖调" | "暖" => Some(Self::Warm),
            "cool" | "cold" | "冷色" | "冷调" | "冷" => Some(Self::Cool),
            "vivid" | "vibrant" | "saturated" | "高饱和" | "鲜艳" => Some(Self::Vivid),
            "muted" | "pastel" | "soft" | "低饱和" | "莫兰迪" | "柔和" => Some(Self::Muted),
            "high_contrast" | "highcontrast" | "contrast" | "高对比" | "强对比" | "撞色" => {
                Some(Self::HighContrast)
            }
            _ => None,
        }
    }

    pub fn matches(self, asset: &AssetRecord) -> bool {
        self.score(asset) >= 0.52
    }

    /// Returns a smooth `0.0..=1.0` perceptual fit score for `asset`'s CIELAB palette.
    pub fn score(self, asset: &AssetRecord) -> f64 {
        let top_swatches: Vec<&LabColor> = asset
            .dominant_colors
            .iter()
            .filter(|c| c.l.is_finite() && c.a.is_finite() && c.b.is_finite())
            .take(5)
            .collect();
        if top_swatches.is_empty() {
            return 0.0;
        }

        let mut total_w = 0.0_f64;
        let mut sum_l = 0.0_f64;
        let mut sum_a = 0.0_f64;
        let mut sum_b = 0.0_f64;
        let mut sum_c = 0.0_f64;
        let mut max_c = 0.0_f64;
        let mut min_l = 100.0_f64;
        let mut max_l = 0.0_f64;
        let mut warm_weight = 0.0_f64;
        let mut cool_weight = 0.0_f64;
        let mut dark_weight = 0.0_f64;
        let mut light_weight = 0.0_f64;

        let count_f = top_swatches.len() as f64;
        for swatch in &top_swatches {
            let w = if swatch.proportion > 0.001 {
                swatch.proportion
            } else {
                1.0 / count_f
            };
            let c = swatch.a.hypot(swatch.b);
            total_w += w;
            sum_l += swatch.l * w;
            sum_a += swatch.a * w;
            sum_b += swatch.b * w;
            sum_c += c * w;
            if w >= 0.08 || top_swatches.len() <= 2 {
                max_c = max_c.max(c);
                min_l = min_l.min(swatch.l);
                max_l = max_l.max(swatch.l);
            }
            if swatch.l <= 34.0 {
                dark_weight += w;
            }
            if swatch.l >= 74.0 {
                light_weight += w;
            }
            if c >= 10.0 {
                if swatch.b > 6.0 || swatch.a > 8.0 {
                    warm_weight += w;
                }
                if swatch.b < -5.0 || (swatch.a < -5.0 && swatch.b <= 6.0) {
                    cool_weight += w;
                }
            }
        }
        if total_w <= 0.0 {
            return 0.0;
        }

        let avg_l = sum_l / total_w;
        let avg_a = sum_a / total_w;
        let avg_b = sum_b / total_w;
        let avg_c = sum_c / total_w;
        let dark_frac = dark_weight / total_w;
        let light_frac = light_weight / total_w;
        let warm_frac = warm_weight / total_w;
        let cool_frac = cool_weight / total_w;

        match self {
            Self::Dark => {
                let l_score = clamp01((52.0 - avg_l) / 34.0);
                let f_score = clamp01(dark_frac / 0.55);
                l_score.max(l_score * 0.65 + f_score * 0.35)
            }
            Self::Light => {
                let l_score = clamp01((avg_l - 54.0) / 32.0);
                let f_score = clamp01(light_frac / 0.55);
                l_score.max(l_score * 0.65 + f_score * 0.35)
            }
            Self::Warm => {
                let axis = clamp01((avg_b * 0.7 + avg_a * 0.55 - 2.0) / 24.0);
                let frac = clamp01(warm_frac / 0.48);
                let chroma_gate = clamp01((max_c - 8.0) / 14.0);
                chroma_gate * (axis * 0.85).max(axis * 0.55 + frac * 0.45)
            }
            Self::Cool => {
                let axis = clamp01(((-avg_b) * 0.75 + (-avg_a) * 0.45 - 1.5) / 22.0);
                let frac = clamp01(cool_frac / 0.45);
                let chroma_gate = clamp01((max_c - 7.0) / 14.0);
                chroma_gate * (axis * 0.85).max(axis * 0.55 + frac * 0.45)
            }
            Self::Vivid => {
                let avg_score = clamp01((avg_c - 20.0) / 28.0);
                let peak_score = clamp01((max_c - 32.0) / 34.0);
                avg_score.max(avg_score * 0.6 + peak_score * 0.4)
            }
            Self::Muted => {
                let low_chroma = clamp01((28.0 - avg_c) / 18.0);
                let mid_light = if (24.0..=86.0).contains(&avg_l) {
                    1.0
                } else {
                    0.45
                };
                let not_extreme_peak = if max_c <= 38.0 {
                    1.0
                } else {
                    clamp01((54.0 - max_c) / 16.0)
                };
                low_chroma * mid_light * not_extreme_peak
            }
            Self::HighContrast => {
                let l_spread = (max_l - min_l).max(0.0);
                let l_score = clamp01((l_spread - 30.0) / 42.0);
                let mut max_delta_e = 0.0_f64;
                let prominent: Vec<&LabColor> = top_swatches
                    .iter()
                    .copied()
                    .filter(|s| s.proportion >= 0.08 || top_swatches.len() <= 2)
                    .collect();
                for i in 0..prominent.len() {
                    for j in (i + 1)..prominent.len() {
                        let d = prominent[i].delta_e_2000(prominent[j]);
                        if d.is_finite() {
                            max_delta_e = max_delta_e.max(d);
                        }
                    }
                }
                let de_score = clamp01((max_delta_e - 34.0) / 36.0);
                (l_score * 0.85)
                    .max(de_score * 0.85)
                    .max(l_score * 0.5 + de_score * 0.5)
            }
        }
    }
}

#[inline]
fn clamp01(v: f64) -> f64 {
    v.clamp(0.0, 1.0)
}

#[derive(Debug, Clone, Default)]
pub struct ParsedVisualHints {
    pub tones: Vec<VisualTone>,
    pub aspect_shapes: Vec<AspectShape>,
    pub target_colors: Vec<LabColor>,
    pub expanded_terms: Vec<String>,
}

/// Curated design & illustration EN ↔ ZH synonym table matching macOS 1:1.
const BILINGUAL_SYNONYMS: &[(&str, &[&str])] = &[
    // Mediums & Art Styles
    ("woodblock", &["木版画", "浮世绘", "日本风景"]),
    ("ukiyo", &["浮世绘", "木版画", "日本风景"]),
    ("ukiyoe", &["浮世绘", "木版画", "日本风景"]),
    ("japanese", &["日本风景", "木版画", "浮世绘", "和风"]),
    ("anime", &["动漫插画", "人物插画", "二次元"]),
    ("manga", &["动漫插画", "漫画", "手绘风"]),
    (
        "illustration",
        &["插画", "人物插画", "动漫插画", "手绘插画"],
    ),
    ("illustrator", &["插画", "手绘风"]),
    ("drawing", &["手绘风", "手绘插画", "素描"]),
    ("sketch", &["手绘风", "线稿", "草图"]),
    ("lineart", &["线稿", "清线", "手绘风"]),
    ("watercolor", &["水彩", "手绘风"]),
    ("vintage", &["复古", "复古质感", "怀旧"]),
    ("retro", &["复古", "复古质感", "怀旧"]),
    ("film", &["胶片", "复古质感", "摄影"]),
    ("minimal", &["极简", "纯色背景", "白色背景"]),
    ("minimalist", &["极简", "纯色背景", "白色背景"]),
    ("clean", &["极简", "白色背景", "纯色背景"]),
    ("editorial", &["海报", "排版", "平面设计"]),
    ("poster", &["海报", "平面设计"]),
    ("photography", &["摄影", "写真"]),
    ("photo", &["摄影", "写真"]),
    ("cyberpunk", &["赛博朋克", "霓虹", "夜景"]),
    ("neon", &["霓虹", "夜景", "赛博朋克"]),
    ("pixel", &["像素", "复古"]),
    // Subjects, Characters & Clothing
    ("girl", &["女孩", "少女", "人物插画"]),
    ("girls", &["女孩", "少女"]),
    ("woman", &["女孩", "女性", "人物插画"]),
    ("boy", &["男孩", "少年"]),
    ("character", &["人物插画", "动漫插画", "全身像"]),
    ("fullbody", &["全身像", "立绘"]),
    ("standing", &["全身像", "立绘"]),
    ("portrait", &["人物插画", "女孩", "写真", "半身像"]),
    ("fashion", &["服装设计", "穿搭", "休闲穿搭", "服饰"]),
    ("outfit", &["穿搭", "服装设计", "休闲穿搭", "服饰"]),
    ("clothing", &["服装设计", "服饰", "穿搭"]),
    ("clothes", &["服装设计", "服饰", "穿搭"]),
    ("casual", &["休闲穿搭", "宽松穿搭"]),
    ("streetwear", &["休闲穿搭", "宽松穿搭", "街头"]),
    ("uniform", &["制服", "校服", "服饰"]),
    ("dress", &["服装设计", "连衣裙", "穿搭"]),
    ("pose", &["动态构图", "人体", "素体"]),
    ("anatomy", &["人体", "人体写真", "素体"]),
    ("body", &["人体", "人体写真", "全身像"]),
    ("blonde", &["金发"]),
    ("hair", &["金发", "黑发", "长发"]),
    // Environments, Nature & Seasons
    ("summer", &["夏日", "夏天", "晴空", "海滩"]),
    ("winter", &["冬日", "雪景", "冬天"]),
    ("snow", &["雪景", "冬日"]),
    ("autumn", &["秋日", "秋天", "落叶"]),
    ("spring", &["春日", "樱花", "花"]),
    ("beach", &["海滩", "海洋", "海边", "夏日"]),
    ("ocean", &["海洋", "海滩", "海边"]),
    ("sea", &["海洋", "海滩", "海边"]),
    ("coast", &["海滩", "海洋"]),
    ("water", &["海洋", "水面", "湖"]),
    ("boat", &["船只", "帆船"]),
    ("sail", &["帆船", "船只"]),
    ("sky", &["晴空", "蓝天", "天空"]),
    ("cloud", &["晴空", "云", "天空"]),
    ("clouds", &["晴空", "云", "天空"]),
    ("mountain", &["山景", "风景"]),
    ("mountains", &["山景", "风景"]),
    ("landscape", &["风景", "日本风景", "山景"]),
    ("scenery", &["风景", "日本风景"]),
    ("nature", &["风景", "自然", "山景"]),
    ("city", &["城市", "街景", "建筑"]),
    ("street", &["街景", "城市"]),
    ("urban", &["城市", "街景", "建筑"]),
    ("architecture", &["建筑", "室内场景"]),
    ("interior", &["室内场景", "室内"]),
    ("room", &["室内场景", "室内"]),
    ("cafe", &["咖啡馆", "室内场景"]),
    ("night", &["夜景", "夜晚", "暗调"]),
    ("evening", &["夜景", "黄昏"]),
    ("sunset", &["日落", "夕阳", "黄昏", "暖色调"]),
    ("sunrise", &["日出", "暖色调"]),
    ("dusk", &["黄昏", "夕阳"]),
    ("dynamic", &["动态构图", "透视构图"]),
    ("perspective", &["透视构图", "动态构图"]),
    // Background & Colors
    ("white", &["白色背景", "纯色背景"]),
    ("background", &["白色背景", "纯色背景", "室内场景"]),
    ("blue", &["蓝色调", "海洋", "晴空"]),
    ("cyan", &["蓝色调", "晴空"]),
    ("red", &["红色调", "暖色调"]),
    ("warm", &["暖色调", "日落", "复古质感"]),
    ("cool", &["蓝色调", "冷色调", "晴空"]),
    ("green", &["绿色调", "自然", "山景"]),
    ("yellow", &["暖色调", "金发"]),
    ("golden", &["暖色调", "日落", "金发"]),
    ("pink", &["粉色", "柔和"]),
    ("dark", &["夜景", "暗调"]),
    ("light", &["白色背景", "晴空", "明亮"]),
    // Chinese -> English / related Chinese concept bridges
    ("木版画", &["woodblock", "浮世绘", "日本风景"]),
    ("浮世绘", &["ukiyo", "木版画", "日本风景"]),
    ("海边", &["海滩", "海洋", "beach", "ocean"]),
    ("海滩", &["海边", "海洋", "beach"]),
    ("蓝天", &["晴空", "天空", "sky"]),
    ("晴空", &["蓝天", "天空", "sky"]),
    ("白底", &["白色背景", "纯色背景", "极简"]),
    ("留白", &["白色背景", "纯色背景", "极简"]),
    ("立绘", &["全身像", "人物插画", "动漫插画"]),
    ("服装", &["服装设计", "服饰", "穿搭"]),
    ("服饰", &["服装设计", "穿搭", "制服"]),
    ("日落", &["夕阳", "黄昏", "暖色调", "sunset"]),
    ("夕阳", &["日落", "黄昏", "暖色调"]),
    ("夜景", &["夜晚", "night", "暗调"]),
    ("冷色调", &["蓝色调", "蓝", "cool"]),
    ("冷调", &["蓝色调", "冷色调", "cool"]),
    ("暖色调", &["暖调", "日落", "warm"]),
    ("暖调", &["暖色调", "日落", "warm"]),
    ("清线", &["clearline", "手绘风", "动漫插画"]),
    ("撞色", &["高饱和", "对比"]),
    ("赛博", &["赛博朋克", "cyberpunk", "霓虹"]),
    ("海报", &["poster", "平面设计", "版式"]),
];

pub struct VisualQueryIntelligence;

impl VisualQueryIntelligence {
    pub fn parse_visual_hints(query: &str, base_terms: &[String]) -> ParsedVisualHints {
        let lower = search_text::normalize(query);
        let norm_terms: Vec<String> = base_terms
            .iter()
            .map(|t| search_text::normalize(t))
            .filter(|t| !t.is_empty())
            .collect();
        let base_set: HashSet<String> = norm_terms.iter().cloned().collect();

        let matches_any = |keys: &[&str]| -> bool {
            keys.iter().any(|key| {
                if search_text::contains_han(key) {
                    lower.contains(key)
                } else {
                    base_set.contains(*key)
                }
            })
        };

        // 1. Visual tones
        let mut tones = Vec::new();
        let mut add_tone = |tone: VisualTone| {
            if !tones.contains(&tone) {
                tones.push(tone);
            }
        };
        if matches_any(&[
            "暗调", "暗黑", "深色", "夜景", "夜晚", "黑夜", "dark", "moody", "night", "noir",
            "shadow",
        ]) {
            add_tone(VisualTone::Dark);
        }
        if matches_any(&[
            "浅色",
            "白底",
            "白色背景",
            "明亮",
            "留白",
            "light",
            "bright",
            "airy",
            "white",
        ]) {
            add_tone(VisualTone::Light);
        }
        if matches_any(&[
            "暖色",
            "暖调",
            "温暖",
            "日落",
            "夕阳",
            "黄昏",
            "琥珀",
            "warm",
            "sunset",
            "golden",
            "amber",
            "terracotta",
        ]) {
            add_tone(VisualTone::Warm);
        }
        if matches_any(&[
            "冷色",
            "冷调",
            "蓝调",
            "蓝色调",
            "清冷",
            "冰蓝",
            "cool",
            "cold",
            "icy",
            "blue",
            "cyan",
            "teal",
        ]) {
            add_tone(VisualTone::Cool);
        }
        if matches_any(&[
            "高饱和",
            "鲜艳",
            "浓烈",
            "撞色",
            "艳丽",
            "vivid",
            "vibrant",
            "saturated",
            "colorful",
            "neon",
        ]) {
            add_tone(VisualTone::Vivid);
        }
        if matches_any(&[
            "低饱和",
            "莫兰迪",
            "柔和",
            "灰调",
            "淡雅",
            "素雅",
            "muted",
            "pastel",
            "desaturated",
            "soft",
            "subtle",
        ]) {
            add_tone(VisualTone::Muted);
        }
        if matches_any(&[
            "高对比",
            "强对比",
            "撞色",
            "明暗对比",
            "contrast",
            "dramatic",
            "chiaroscuro",
        ]) {
            add_tone(VisualTone::HighContrast);
        }

        // 2. Aspect shape intents
        let mut shapes = Vec::new();
        let mut add_shape = |shape: AspectShape| {
            if !shapes.contains(&shape) {
                shapes.push(shape);
            }
        };
        if matches_any(&["竖屏", "竖图", "竖版", "纵向", "vertical"])
            || base_set.contains("portrait")
        {
            add_shape(AspectShape::Portrait);
        }
        if matches_any(&["横屏", "横图", "横版", "横向", "horizontal"])
            || base_set.contains("landscape")
        {
            add_shape(AspectShape::Landscape);
        }
        if matches_any(&["方图", "正方形", "方形", "square"]) {
            add_shape(AspectShape::Square);
        }
        if matches_any(&[
            "宽屏",
            "超宽",
            "电影画幅",
            "全景",
            "ultrawide",
            "panoramic",
            "widescreen",
        ]) {
            add_shape(AspectShape::Ultrawide);
        }

        // 3. Soft CIELAB color anchors extracted from color words
        let color_hints: &[(&[&str], &str)] = &[
            (
                &[
                    "蓝",
                    "蓝色",
                    "蓝色调",
                    "青蓝",
                    "海蓝",
                    "blue",
                    "indigo",
                    "cobalt",
                    "navy",
                ],
                "#2A6F97",
            ),
            (
                &["红", "红色", "朱红", "陶土", "red", "crimson", "terracotta"],
                "#C84B31",
            ),
            (
                &["绿", "绿色", "翠绿", "森系", "green", "emerald", "sage"],
                "#2D6A4F",
            ),
            (
                &[
                    "黄", "黄色", "金色", "暖黄", "yellow", "gold", "golden", "amber",
                ],
                "#E9B44C",
            ),
            (&["橙", "橘", "日落", "夕阳", "orange", "sunset"], "#E07A3F"),
            (&["粉", "粉色", "樱花", "pink", "rose"], "#E5989B"),
            (&["紫", "紫色", "purple", "violet", "lavender"], "#6D597A"),
        ];
        let mut target_colors = Vec::new();
        for (keys, hex) in color_hints {
            if matches_any(keys) {
                target_colors.push(LabColor::from_hex(hex, 1.0));
            }
        }

        // 4. Cross-lingual & domain synonym expansion
        let mut expanded = Vec::new();
        let mut seen = base_set;
        let mut add_expanded = |raw: &str| {
            let n = search_text::normalize(raw);
            if !n.is_empty() && seen.insert(n) {
                expanded.push(raw.to_string());
            }
        };
        for term in &norm_terms {
            if let Some((_, mapped)) = BILINGUAL_SYNONYMS.iter().find(|(k, _)| *k == term.as_str())
            {
                for m in *mapped {
                    add_expanded(m);
                }
            }
        }
        for (key, mapped) in BILINGUAL_SYNONYMS {
            if search_text::contains_han(key) && key.chars().count() >= 2 && lower.contains(*key) {
                add_expanded(key);
                for m in *mapped {
                    add_expanded(m);
                }
            }
        }
        expanded.truncate(12);

        ParsedVisualHints {
            tones,
            aspect_shapes: shapes,
            target_colors,
            expanded_terms: expanded,
        }
    }

    /// Evaluates how well `asset` aligns with parsed visual hints (tones, aspect shapes, soft color anchors).
    pub fn visual_hint_score(
        asset: &AssetRecord,
        hints: &ParsedVisualHints,
    ) -> Option<(f64, String)> {
        let mut components: Vec<(f64, String)> = Vec::new();

        if !hints.tones.is_empty() {
            let scores: Vec<(VisualTone, f64)> =
                hints.tones.iter().map(|&t| (t, t.score(asset))).collect();
            let avg = scores.iter().map(|(_, s)| *s).sum::<f64>() / scores.len() as f64;
            if avg >= 0.42 {
                let matched_labels: Vec<&str> = scores
                    .iter()
                    .filter(|(_, s)| *s >= 0.48)
                    .map(|(t, _)| t.raw_value())
                    .collect();
                let label = if matched_labels.is_empty() {
                    "氛围吻合".to_string()
                } else {
                    format!("氛围:{}", matched_labels.join("/"))
                };
                components.push((avg, label));
            }
        }

        if !hints.aspect_shapes.is_empty() {
            let shape = asset.aspect_shape();
            if hints.aspect_shapes.contains(&shape) {
                components.push((0.85, format!("画幅:{}", aspect_shape_raw(shape))));
            }
        }

        if !hints.target_colors.is_empty() && !asset.dominant_colors.is_empty() {
            let valid: Vec<&LabColor> = asset
                .dominant_colors
                .iter()
                .take(4)
                .filter(|c| c.l.is_finite() && c.a.is_finite() && c.b.is_finite())
                .collect();
            let mut min_de = f64::INFINITY;
            for c in &valid {
                for target in &hints.target_colors {
                    let de = c.delta_e_2000(target);
                    if de.is_finite() && de < min_de {
                        min_de = de;
                    }
                }
            }
            if min_de < 28.0 {
                let sim = (1.0 - min_de / 28.0).max(0.0);
                if sim >= 0.35 {
                    components.push((sim, "色相吻合".to_string()));
                }
            }
        }

        if components.is_empty() {
            return None;
        }
        let avg_score = components.iter().map(|(s, _)| *s).sum::<f64>() / components.len() as f64;
        let reason = components
            .into_iter()
            .map(|(_, r)| r)
            .collect::<Vec<_>>()
            .join("·");
        Some((avg_score.min(1.0), reason))
    }
}

pub const fn aspect_shape_raw(shape: AspectShape) -> &'static str {
    match shape {
        AspectShape::Portrait => "portrait",
        AspectShape::Landscape => "landscape",
        AspectShape::Square => "square",
        AspectShape::Ultrawide => "ultrawide",
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn asset_with_hexes(hexes: &[(&str, f64)], w: i32, h: i32) -> AssetRecord {
        let mut a = AssetRecord::new("Test", "test.jpg");
        a.pixel_width = w;
        a.pixel_height = h;
        a.dominant_colors = hexes
            .iter()
            .map(|(hex, prop)| LabColor::from_hex(hex, *prop))
            .collect();
        a
    }

    #[test]
    fn parses_all_seven_visual_tones_bilingually() {
        assert_eq!(VisualTone::parse(Some("dark")), Some(VisualTone::Dark));
        assert_eq!(VisualTone::parse(Some("暗调")), Some(VisualTone::Dark));
        assert_eq!(VisualTone::parse(Some("白底")), Some(VisualTone::Light));
        assert_eq!(VisualTone::parse(Some("暖调")), Some(VisualTone::Warm));
        assert_eq!(VisualTone::parse(Some("冷色")), Some(VisualTone::Cool));
        assert_eq!(VisualTone::parse(Some("高饱和")), Some(VisualTone::Vivid));
        assert_eq!(VisualTone::parse(Some("莫兰迪")), Some(VisualTone::Muted));
        assert_eq!(
            VisualTone::parse(Some("高对比")),
            Some(VisualTone::HighContrast)
        );
        assert_eq!(
            VisualTone::parse(Some("high_contrast")),
            Some(VisualTone::HighContrast)
        );
        assert_eq!(VisualTone::parse(Some("unknown")), None);
    }

    #[test]
    fn scores_all_seven_cielab_tones_accurately() {
        let dark = asset_with_hexes(&[("#10141C", 0.7), ("#1F2430", 0.3)], 1000, 1000);
        assert!(VisualTone::Dark.matches(&dark));
        assert!(!VisualTone::Light.matches(&dark));

        let light = asset_with_hexes(&[("#F8F9FA", 0.75), ("#E6E9EE", 0.25)], 1000, 1000);
        assert!(VisualTone::Light.matches(&light));
        assert!(!VisualTone::Dark.matches(&light));

        let warm = asset_with_hexes(&[("#E07A3F", 0.65), ("#C84B31", 0.35)], 1000, 1000);
        assert!(VisualTone::Warm.matches(&warm));
        assert!(!VisualTone::Cool.matches(&warm));

        let cool = asset_with_hexes(&[("#2A6F97", 0.65), ("#1B4965", 0.35)], 1000, 1000);
        assert!(VisualTone::Cool.matches(&cool));
        assert!(!VisualTone::Warm.matches(&cool));

        let vivid = asset_with_hexes(&[("#FF0055", 0.6), ("#00D9FF", 0.4)], 1000, 1000);
        assert!(VisualTone::Vivid.matches(&vivid));
        assert!(!VisualTone::Muted.matches(&vivid));

        let muted = asset_with_hexes(&[("#B8B2A6", 0.6), ("#9FA6A0", 0.4)], 1000, 1000);
        assert!(VisualTone::Muted.matches(&muted));
        assert!(!VisualTone::Vivid.matches(&muted));

        let contrast = asset_with_hexes(&[("#080808", 0.55), ("#FAFAFA", 0.45)], 1000, 1000);
        assert!(VisualTone::HighContrast.matches(&contrast));
    }

    #[test]
    fn extracts_bilingual_hints_and_synonyms() {
        let base = vec![
            "japanese".to_string(),
            "woodblock".to_string(),
            "night".to_string(),
            "blue".to_string(),
        ];
        let hints =
            VisualQueryIntelligence::parse_visual_hints("japanese woodblock night blue", &base);
        assert!(hints.tones.contains(&VisualTone::Dark));
        assert!(hints.tones.contains(&VisualTone::Cool));
        assert!(!hints.target_colors.is_empty());
        assert!(hints.expanded_terms.iter().any(|t| t == "浮世绘"));
        assert!(hints.expanded_terms.iter().any(|t| t == "木版画"));

        let zh = VisualQueryIntelligence::parse_visual_hints("竖版暗黑赛博海报", &[]);
        assert!(zh.aspect_shapes.contains(&AspectShape::Portrait));
        assert!(zh.tones.contains(&VisualTone::Dark) || !zh.expanded_terms.is_empty());
    }
}
