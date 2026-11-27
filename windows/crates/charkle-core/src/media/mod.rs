//! 8-kind media pipeline, EXIF/AI prompt metadata extractor, CIELAB color extraction,
//! audio waveform analysis, native rich URL resolvers, LRU cache, and sample seeder.

pub mod artwork;
pub mod audio;
pub mod color;
pub mod dedup;
pub mod douyin;
pub mod eaglepack;
pub mod metadata;
pub mod pipeline;
pub mod pureref;
pub mod resolvers;
pub mod video_platform;
pub mod visual_fingerprint;
pub mod xiaohongshu;

pub use artwork::MediaArtwork;
pub use audio::{analyze_audio, AudioAnalysis, WAVEFORM_BARS};
pub use color::ColorExtractor;
pub use dedup::{
    CachedDedupFingerprintEntry, ClassicalImageFingerprint, DeduplicationCleanupResult,
    DeduplicationResolutionPlan, DeduplicationScanReport, DeduplicationScanScope,
    DeduplicationSensitivity, DuplicateAssetCandidate, DuplicateDisposalMode, DuplicateGroup,
    DuplicateMatchKind, IndexedMediaAsset, SmartDeduplicator,
};
pub use douyin::{
    douyin_classification_tag, DouyinPostReference, DouyinPostResolver, DouyinURLParser,
    DOUYIN_PHOTO_NOTE_TAG, DOUYIN_REFERER, DOUYIN_VIDEO_TAG,
};
pub use eaglepack::{
    EaglePackImporter, MaterialPackageImportResult, ParsedEagleAsset, ParsedEagleFolder,
    ParsedEaglePackage, StagingDirGuard,
};
pub use metadata::{ExtractedImageMetadata, ImageMetadataExtractor};
pub use pipeline::{
    FileDigests, MediaImportResult, MediaPipeline, OriginalEntry, SampleLibrarySeeder,
    MAX_CACHE_BUDGET_BYTES, MIN_CACHE_BUDGET_BYTES,
};
pub use pureref::{
    PureRefAssetInput, PureRefCodec, PureRefColor, PureRefExportReport, PureRefImageBlob,
    PureRefImageFormat, PureRefImagePlacement, PureRefImportResult, PureRefScene, PureRefTextNote,
};
pub use resolvers::{
    canonical_dedup_key, fetch_or_cache_social_media, resolve_media_extension,
    social_proxy_cache_key, validate_social_proxy_url, GitHubRepoReference, GitHubRepoResolver,
    GitHubRepoURLParser, ParsedWebHtml, ResolvedSocialPost, ResolvedWebBookmark,
    SocialPostReference, SocialPostResolver, SocialPostURLParser, WebBookmarkResolver,
    WebURLParser, XPostReference, XPostURLParser,
};
pub use video_platform::{
    compute_bounded_upstream_range, crop_png_region_to_jpeg, fetch_video_stream_chunk,
    normalize_video_stream_content_type, VideoDirectStream, VideoEmbedPlayer,
    VideoPlatformReference, VideoPlatformResolver, VideoPlatformURLParser, VideoStreamPlaybackPlan,
    VideoStreamProxyError, VideoStreamProxyResponse, STREAM_ANDROID_YOUTUBE_UA, STREAM_BROWSER_UA,
    STREAM_IOS_YOUTUBE_UA,
};
pub use visual_fingerprint::LocalVisualDescriptor;
pub use xiaohongshu::{
    fetch_or_cache_xhs_media, validate_xhs_proxy_url, XhsProxyError, XhsProxyResponse,
    XiaohongshuNoteReference, XiaohongshuPostResolver, XiaohongshuURLParser, XIAOHONGSHU_REFERER,
};
