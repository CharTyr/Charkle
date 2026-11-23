//! Offline & pluggable Moodboard Curation engine (MMR scoring + 8-phase Agent Harness).

pub mod curator;
pub mod harness;

pub use curator::{IntelligenceEngine, LocalIntelligenceEngine, MoodboardCurator};
pub use harness::MoodboardAgentHarness;
