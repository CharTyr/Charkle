//! 8-kind media pipeline, EXIF/AI prompt metadata extractor, CIELAB color extraction,
//! audio waveform analysis, native rich URL resolvers, LRU cache, and sample seeder.

pub mod artwork;
pub mod audio;
pub mod color;
pub mod metadata;
pub mod pipeline;
pub mod resolvers;

pub use artwork::MediaArtwork;
pub use audio::{analyze_audio, AudioAnalysis, WAVEFORM_BARS};
pub use color::ColorExtractor;
pub use metadata::{ExtractedImageMetadata, ImageMetadataExtractor};
pub use pipeline::{
    FileDigests, MediaImportResult, MediaPipeline, OriginalEntry, SampleLibrarySeeder,
    MAX_CACHE_BUDGET_BYTES, MIN_CACHE_BUDGET_BYTES,
};
pub use resolvers::{
    GitHubRepoReference, GitHubRepoResolver, GitHubRepoURLParser, ResolvedSocialPost,
    ResolvedWebBookmark, SocialPostReference, SocialPostResolver, SocialPostURLParser,
    WebBookmarkResolver, XPostReference, XPostURLParser,
};
