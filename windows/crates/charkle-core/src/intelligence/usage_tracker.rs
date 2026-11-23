//! Local usage telemetry for Cloud AI Enhancement (`usage_tracker.rs`),
//! mirroring `Sources/CharkleCore/Intelligence/CloudAIUsageTracker.swift`.
//!
//! Tracks ordinary Cloud AI models (`standard`: Gemini / ChatGPT / OpenAI / Anthropic)
//! separately from TypeSafe System One (`jev`) visual judgment calls, with automatic
//! local-calendar daily rollover and atomic JSON persistence.

use std::path::{Path, PathBuf};
use std::sync::Mutex;

use chrono::{DateTime, Local, Utc};
use serde::{Deserialize, Serialize};

use crate::wire::swift_codec::cocoa_date_opt;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum CloudAIUsageCategory {
    #[default]
    Standard,
    Jev,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CloudAIUsageBucket {
    pub day_key: String,
    #[serde(default)]
    pub today_requests: u64,
    #[serde(default)]
    pub today_input_tokens: u64,
    #[serde(default)]
    pub today_output_tokens: u64,
    #[serde(default)]
    pub today_total_tokens: u64,
    #[serde(default)]
    pub total_requests: u64,
    #[serde(default)]
    pub total_input_tokens: u64,
    #[serde(default)]
    pub total_output_tokens: u64,
    #[serde(default)]
    pub total_tokens: u64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub last_provider_label: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub last_model: Option<String>,
    #[serde(
        default,
        skip_serializing_if = "Option::is_none",
        with = "cocoa_date_opt"
    )]
    pub last_used_at: Option<DateTime<Utc>>,
    #[serde(default)]
    pub last_call_tokens: u64,
}

impl CloudAIUsageBucket {
    pub fn new(day_key: String) -> Self {
        Self {
            day_key,
            today_requests: 0,
            today_input_tokens: 0,
            today_output_tokens: 0,
            today_total_tokens: 0,
            total_requests: 0,
            total_input_tokens: 0,
            total_output_tokens: 0,
            total_tokens: 0,
            last_provider_label: None,
            last_model: None,
            last_used_at: None,
            last_call_tokens: 0,
        }
    }

    pub fn rollover_if_needed(&mut self, current_day_key: &str) {
        if self.day_key != current_day_key {
            self.day_key = current_day_key.to_string();
            self.today_requests = 0;
            self.today_input_tokens = 0;
            self.today_output_tokens = 0;
            self.today_total_tokens = 0;
        }
    }

    #[allow(clippy::too_many_arguments)]
    pub fn record(
        &mut self,
        provider_label: &str,
        model: &str,
        input_tokens: u64,
        output_tokens: u64,
        total_tokens: u64,
        now: DateTime<Utc>,
        day_key: &str,
    ) {
        self.rollover_if_needed(day_key);
        self.today_requests += 1;
        self.today_input_tokens += input_tokens;
        self.today_output_tokens += output_tokens;
        self.today_total_tokens += total_tokens;
        self.total_requests += 1;
        self.total_input_tokens += input_tokens;
        self.total_output_tokens += output_tokens;
        self.total_tokens += total_tokens;
        self.last_provider_label = Some(provider_label.to_string());
        let trimmed = model.trim();
        if !trimmed.is_empty() {
            self.last_model = Some(trimmed.to_string());
        }
        self.last_used_at = Some(now);
        self.last_call_tokens = total_tokens;
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CloudAIUsageSummary {
    pub day_key: String,
    #[serde(default)]
    pub today_requests: u64,
    #[serde(default)]
    pub today_input_tokens: u64,
    #[serde(default)]
    pub today_output_tokens: u64,
    #[serde(default)]
    pub today_total_tokens: u64,
    #[serde(default)]
    pub total_requests: u64,
    #[serde(default)]
    pub total_input_tokens: u64,
    #[serde(default)]
    pub total_output_tokens: u64,
    #[serde(default)]
    pub total_tokens: u64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub last_provider_label: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub last_model: Option<String>,
    #[serde(
        default,
        skip_serializing_if = "Option::is_none",
        with = "cocoa_date_opt"
    )]
    pub last_used_at: Option<DateTime<Utc>>,
    #[serde(default)]
    pub last_call_tokens: u64,
    pub standard: CloudAIUsageBucket,
    pub jev: CloudAIUsageBucket,
}

impl Default for CloudAIUsageSummary {
    fn default() -> Self {
        let day = Self::local_day_key();
        Self {
            day_key: day.clone(),
            today_requests: 0,
            today_input_tokens: 0,
            today_output_tokens: 0,
            today_total_tokens: 0,
            total_requests: 0,
            total_input_tokens: 0,
            total_output_tokens: 0,
            total_tokens: 0,
            last_provider_label: None,
            last_model: None,
            last_used_at: None,
            last_call_tokens: 0,
            standard: CloudAIUsageBucket::new(day.clone()),
            jev: CloudAIUsageBucket::new(day),
        }
    }
}

impl CloudAIUsageSummary {
    pub fn local_day_key() -> String {
        Local::now().format("%Y-%m-%d").to_string()
    }

    pub fn rollover_if_needed(&mut self, day_key: &str) {
        self.day_key = day_key.to_string();
        self.standard.rollover_if_needed(day_key);
        self.jev.rollover_if_needed(day_key);
        self.synchronize_aggregates();
    }

    pub fn synchronize_aggregates(&mut self) {
        self.today_requests = self.standard.today_requests + self.jev.today_requests;
        self.today_input_tokens = self.standard.today_input_tokens + self.jev.today_input_tokens;
        self.today_output_tokens = self.standard.today_output_tokens + self.jev.today_output_tokens;
        self.today_total_tokens = self.standard.today_total_tokens + self.jev.today_total_tokens;
        self.total_requests = self.standard.total_requests + self.jev.total_requests;
        self.total_input_tokens = self.standard.total_input_tokens + self.jev.total_input_tokens;
        self.total_output_tokens = self.standard.total_output_tokens + self.jev.total_output_tokens;
        self.total_tokens = self.standard.total_tokens + self.jev.total_tokens;

        let latest = match (self.standard.last_used_at, self.jev.last_used_at) {
            (Some(a), Some(b)) if b > a => Some(&self.jev),
            (Some(_), _) => Some(&self.standard),
            (None, Some(_)) => Some(&self.jev),
            (None, None) => None,
        };
        if let Some(bucket) = latest {
            self.last_provider_label = bucket.last_provider_label.clone();
            self.last_model = bucket.last_model.clone();
            self.last_used_at = bucket.last_used_at;
            self.last_call_tokens = bucket.last_call_tokens;
        }
    }
}

/// Thread-safe, file-backed usage tracker persisted atomically under `<data_dir>/ai-usage.json`.
pub struct CloudAIUsageStore {
    path: Option<PathBuf>,
    state: Mutex<CloudAIUsageSummary>,
}

impl CloudAIUsageStore {
    pub fn in_memory() -> Self {
        Self {
            path: None,
            state: Mutex::new(CloudAIUsageSummary::default()),
        }
    }

    pub fn open(data_dir: &Path) -> Self {
        let path = data_dir.join("ai-usage.json");
        let loaded = std::fs::read(&path)
            .ok()
            .and_then(|bytes| serde_json::from_slice::<CloudAIUsageSummary>(&bytes).ok())
            .unwrap_or_default();
        Self {
            path: Some(path),
            state: Mutex::new(loaded),
        }
    }

    pub fn snapshot(&self) -> CloudAIUsageSummary {
        let mut guard = self.state.lock().unwrap_or_else(|e| e.into_inner());
        let day = CloudAIUsageSummary::local_day_key();
        guard.rollover_if_needed(&day);
        guard.clone()
    }

    #[allow(clippy::too_many_arguments)]
    pub fn record(
        &self,
        category: CloudAIUsageCategory,
        provider_label: &str,
        model: &str,
        input_tokens: u64,
        output_tokens: u64,
        total_tokens: Option<u64>,
    ) -> CloudAIUsageSummary {
        let now = Utc::now();
        let day = CloudAIUsageSummary::local_day_key();
        let effective_total =
            total_tokens.unwrap_or_else(|| input_tokens.saturating_add(output_tokens));

        let mut guard = self.state.lock().unwrap_or_else(|e| e.into_inner());
        guard.rollover_if_needed(&day);
        match category {
            CloudAIUsageCategory::Standard => guard.standard.record(
                provider_label,
                model,
                input_tokens,
                output_tokens,
                effective_total,
                now,
                &day,
            ),
            CloudAIUsageCategory::Jev => guard.jev.record(
                provider_label,
                model,
                input_tokens,
                output_tokens,
                effective_total,
                now,
                &day,
            ),
        }
        guard.synchronize_aggregates();
        let snap = guard.clone();
        drop(guard);
        self.persist(&snap);
        snap
    }

    pub fn reset(&self, category: Option<CloudAIUsageCategory>) -> CloudAIUsageSummary {
        let day = CloudAIUsageSummary::local_day_key();
        let mut guard = self.state.lock().unwrap_or_else(|e| e.into_inner());
        match category {
            None => *guard = CloudAIUsageSummary::default(),
            Some(CloudAIUsageCategory::Standard) => {
                guard.standard = CloudAIUsageBucket::new(day);
                guard.synchronize_aggregates();
            }
            Some(CloudAIUsageCategory::Jev) => {
                guard.jev = CloudAIUsageBucket::new(day);
                guard.synchronize_aggregates();
            }
        }
        let snap = guard.clone();
        drop(guard);
        self.persist(&snap);
        snap
    }

    fn persist(&self, summary: &CloudAIUsageSummary) {
        let Some(path) = &self.path else {
            return;
        };
        if let Some(parent) = path.parent() {
            let _ = std::fs::create_dir_all(parent);
        }
        if let Ok(bytes) = serde_json::to_vec_pretty(summary) {
            let tmp = path.with_extension("json.tmp");
            if std::fs::write(&tmp, &bytes).is_ok() {
                let _ = std::fs::rename(&tmp, path);
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::tempdir;

    #[test]
    fn tracks_standard_and_jev_buckets_independently_and_rolls_over_daily() {
        let dir = tempdir().unwrap();
        let store = CloudAIUsageStore::open(dir.path());
        store.record(
            CloudAIUsageCategory::Standard,
            "Google Gemini",
            "gemini-2.5-flash",
            120,
            45,
            None,
        );
        store.record(
            CloudAIUsageCategory::Jev,
            "TypeSafe (Jev)",
            "jev-latest",
            300,
            80,
            None,
        );

        let snap = store.snapshot();
        assert_eq!(snap.standard.today_requests, 1);
        assert_eq!(snap.standard.total_tokens, 165);
        assert_eq!(snap.jev.today_requests, 1);
        assert_eq!(snap.jev.total_tokens, 380);
        assert_eq!(snap.today_requests, 2);
        assert_eq!(snap.total_tokens, 545);

        // Reload from disk verifies atomic persistence
        let reloaded = CloudAIUsageStore::open(dir.path());
        assert_eq!(reloaded.snapshot().total_tokens, 545);

        // Simulate daily rollover
        let mut rolled = reloaded.snapshot();
        rolled.rollover_if_needed("2099-01-01");
        assert_eq!(rolled.today_requests, 0);
        assert_eq!(rolled.total_requests, 2);
        assert_eq!(rolled.total_tokens, 545);
    }
}
