//! 8-kind media pipeline, EXIF/AI prompt metadata extractor, CIELAB color extraction,
//! audio waveform analysis, native rich URL resolvers, LRU cache, and sample seeder.

pub mod artwork;
pub mod audio;
pub mod color;
pub mod metadata;
pub mod pipeline;
pub mod resolvers;
pub mod visual_fingerprint;
pub mod xiaohongshu;

pub use artwork::MediaArtwork;
pub use audio::{analyze_audio, AudioAnalysis, WAVEFORM_BARS};
pub use color::ColorExtractor;
pub use metadata::{ExtractedImageMetadata, ImageMetadataExtractor};
pub use pipeline::{
    FileDigests, MediaImportResult, MediaPipeline, OriginalEntry, SampleLibrarySeeder,
    MAX_CACHE_BUDGET_BYTES, MIN_CACHE_BUDGET_BYTES,
};
pub use resolvers::{
    canonical_dedup_key, fetch_or_cache_social_media, social_proxy_cache_key,
    validate_social_proxy_url, GitHubRepoReference, GitHubRepoResolver, GitHubRepoURLParser,
    ParsedWebHtml, ResolvedSocialPost, ResolvedWebBookmark, SocialPostReference,
    SocialPostResolver, SocialPostURLParser, WebBookmarkResolver, WebURLParser, XPostReference,
    XPostURLParser,
};
pub use visual_fingerprint::LocalVisualDescriptor;
pub use xiaohongshu::{
    fetch_or_cache_xhs_media, validate_xhs_proxy_url, XhsProxyError, XhsProxyResponse,
    XiaohongshuNoteReference, XiaohongshuPostResolver, XiaohongshuURLParser, XIAOHONGSHU_REFERER,
};
