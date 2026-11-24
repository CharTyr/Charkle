//! Intelligence layer: Moodboard Curator + 8-phase Agent Harness + Hybrid Cloud AI +
//! ChatGPT PKCE OAuth + Usage Telemetry + TypeSafe System One (Jev) Visual Grounding + Contact Sheet.

pub mod chatgpt_oauth;
pub mod cloud_ai;
pub mod contact_sheet;
pub mod curator;
pub mod harness;
pub mod typesafe;
pub mod usage_tracker;
pub mod visual_grounding;

pub use chatgpt_oauth::{ChatGPTSignInClient, PkceChallengePair, CHATGPT_VAULT_KEY};
pub use cloud_ai::{
    build_cloud_ai_provider, test_cloud_ai_connection, AIConnectionTestResult,
    AnthropicMessagesProvider, CloudAIProvider, GeminiProvider, OpenAICompatibleProvider,
    OpenAIResponsesProvider, AI_API_KEY_SECRET_KEY,
};
pub use contact_sheet::{render_contact_sheet, ContactSheetResult};
pub use curator::{IntelligenceEngine, LocalIntelligenceEngine, MoodboardCurator};
pub use harness::MoodboardAgentHarness;
pub use typesafe::{
    TypeSafeAnswer, TypeSafeBoxCoordinates, TypeSafeImageAttachment, TypeSafeQuestion,
    TypeSafeSystemOneClient, TypeSafeSystemOneResponse, TypeSafeUsage, TYPESAFE_API_KEY_SECRET_KEY,
};
pub use usage_tracker::{
    CloudAIUsageBucket, CloudAIUsageCategory, CloudAIUsageStore, CloudAIUsageSummary,
};
pub use visual_grounding::{
    offline_saliency_box, FolderClassificationResult, FolderOptionInput, TypeSafeImagePreparer,
    VisualGroundingEngine,
};
