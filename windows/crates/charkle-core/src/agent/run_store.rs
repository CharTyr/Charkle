//! Persisted audit & compensating-rollback journal (`agent.run.<id>`), curation session
//! working sets (`agent.session.<id>`), and taxonomy rules (`agent.taxonomy.v1`) inside
//! SQLite `sync_state` (zero schema migration required, WAL-safe across stdio & HTTP processes).
//!
//! Mirrors `Sources/CharkleCore/Intelligence/ExternalAgentRunStore.swift`.

use std::collections::HashSet;

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

use crate::db::LibraryDatabase;
use crate::error::CoreResult;
use crate::models::agent::LibraryTaxonomyPolicy;
use crate::models::core::{AssetRecord, FolderRecord};
use crate::models::moodboard::MoodboardDocument;

const RUN_KEY_PREFIX: &str = "agent.run.";
const SESSION_KEY_PREFIX: &str = "agent.session.";
const TAXONOMY_KEY: &str = "agent.taxonomy.v1";
const MAX_STORED_RUNS: usize = 30;
const MAX_STORED_SESSIONS: usize = 24;
const MAX_SEEN_PER_SESSION: usize = 300;

/// Reversibility snapshot for a single asset modified by an external MCP agent run.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AgentAssetSnapshot {
    #[serde(rename = "assetID", with = "crate::wire::swift_codec::upper_uuid")]
    pub asset_id: Uuid,
    pub title: String,
    pub notes: String,
    pub ai_description: Option<String>,
    pub rating: i32,
    pub tags: Vec<String>,
    pub suggested_tags: Vec<String>,
    #[serde(
        rename = "folderID",
        default,
        with = "crate::wire::swift_codec::upper_uuid_opt"
    )]
    pub folder_id: Option<Uuid>,
    pub pinned_offline: bool,
    pub is_trashed: bool,
}

impl From<&AssetRecord> for AgentAssetSnapshot {
    fn from(asset: &AssetRecord) -> Self {
        Self {
            asset_id: asset.id,
            title: asset.title.clone(),
            notes: asset.notes.clone(),
            ai_description: asset.ai_description.clone(),
            rating: asset.rating,
            tags: asset.tags.clone(),
            suggested_tags: asset.suggested_tags.clone(),
            folder_id: asset.folder_id,
            pinned_offline: asset.pinned_offline,
            is_trashed: asset.is_trashed,
        }
    }
}

/// Reversibility snapshot for a single folder updated by an external MCP agent run.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AgentFolderSnapshot {
    #[serde(rename = "folderID", with = "crate::wire::swift_codec::upper_uuid")]
    pub folder_id: Uuid,
    pub name: String,
    #[serde(
        rename = "parentID",
        default,
        with = "crate::wire::swift_codec::upper_uuid_opt"
    )]
    pub parent_id: Option<Uuid>,
    pub color_hex: Option<String>,
    pub custom_symbol: Option<String>,
}

impl From<&FolderRecord> for AgentFolderSnapshot {
    fn from(folder: &FolderRecord) -> Self {
        Self {
            folder_id: folder.id,
            name: folder.name.clone(),
            parent_id: folder.parent_id,
            color_hex: folder.color_hex.clone(),
            custom_symbol: folder.custom_symbol.clone(),
        }
    }
}

/// Persisted audit & compensating-rollback journal entry stored inside SQLite `sync_state`.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AgentRunRecord {
    pub id: String,
    pub tool_name: String,
    pub actor: String,
    pub transport: String,
    pub summary: String,
    pub created_at: DateTime<Utc>,
    #[serde(default)]
    pub rolled_back_at: Option<DateTime<Utc>>,
    #[serde(default)]
    pub asset_snapshots: Vec<AgentAssetSnapshot>,
    #[serde(
        rename = "ingestedAssetIDs",
        default,
        with = "crate::wire::swift_codec::upper_uuid_vec"
    )]
    pub ingested_asset_ids: Vec<Uuid>,
    #[serde(default)]
    pub folder_snapshots: Vec<AgentFolderSnapshot>,
    #[serde(default)]
    pub board_snapshots: Vec<MoodboardDocument>,
    #[serde(
        rename = "createdBoardIDs",
        default,
        with = "crate::wire::swift_codec::upper_uuid_vec"
    )]
    pub created_board_ids: Vec<Uuid>,
}

impl AgentRunRecord {
    pub fn make_run_id() -> String {
        let stamp = Utc::now().format("%Y%m%d-%H%M%S");
        let suffix: String = Uuid::new_v4()
            .simple()
            .to_string()
            .chars()
            .take(6)
            .collect();
        format!("run-{stamp}-{suffix}")
    }

    pub fn new(
        tool_name: impl Into<String>,
        actor: impl Into<String>,
        transport: impl Into<String>,
        summary: impl Into<String>,
    ) -> Self {
        Self {
            id: Self::make_run_id(),
            tool_name: tool_name.into(),
            actor: actor.into(),
            transport: transport.into(),
            summary: summary.into(),
            created_at: Utc::now(),
            rolled_back_at: None,
            asset_snapshots: Vec::new(),
            ingested_asset_ids: Vec::new(),
            folder_snapshots: Vec::new(),
            board_snapshots: Vec::new(),
            created_board_ids: Vec::new(),
        }
    }

    pub fn is_rolled_back(&self) -> bool {
        self.rolled_back_at.is_some()
    }

    pub fn affected_count(&self) -> usize {
        self.asset_snapshots.len()
            + self.ingested_asset_ids.len()
            + self.folder_snapshots.len()
            + self.board_snapshots.len()
            + self.created_board_ids.len()
    }
}

/// Lightweight persisted working set for `session_id` deduplication across multi-round discovery.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AgentCurationSession {
    pub id: String,
    #[serde(
        rename = "seenAssetIDs",
        default,
        with = "crate::wire::swift_codec::upper_uuid_vec"
    )]
    pub seen_asset_ids: Vec<Uuid>,
    pub updated_at: DateTime<Utc>,
}

impl AgentCurationSession {
    pub fn new(id: impl Into<String>) -> Self {
        Self {
            id: id.into(),
            seen_asset_ids: Vec::new(),
            updated_at: Utc::now(),
        }
    }
}

pub struct ExternalAgentStateStore;

impl ExternalAgentStateStore {
    pub fn load_taxonomy(db: &LibraryDatabase) -> LibraryTaxonomyPolicy {
        db.state::<LibraryTaxonomyPolicy>(TAXONOMY_KEY)
            .ok()
            .flatten()
            .unwrap_or_default()
    }

    pub fn save_taxonomy(db: &LibraryDatabase, policy: &LibraryTaxonomyPolicy) -> CoreResult<()> {
        db.set_state(TAXONOMY_KEY, Some(policy))
    }

    pub fn record_run(db: &LibraryDatabase, run: &AgentRunRecord) {
        let key = format!("{RUN_KEY_PREFIX}{}", run.id);
        if db.set_state(&key, Some(run)).is_err() {
            return;
        }
        if let Ok(mut existing) = db.states_with_prefix::<AgentRunRecord>(RUN_KEY_PREFIX) {
            if existing.len() > MAX_STORED_RUNS {
                existing.sort_by_key(|a| std::cmp::Reverse(a.1.created_at));
                for (overflow_key, _) in existing.into_iter().skip(MAX_STORED_RUNS) {
                    let _ = db.set_state::<AgentRunRecord>(&overflow_key, None);
                }
            }
        }
    }

    pub fn list_runs(db: &LibraryDatabase, limit: usize) -> Vec<AgentRunRecord> {
        let mut rows: Vec<AgentRunRecord> = db
            .states_with_prefix::<AgentRunRecord>(RUN_KEY_PREFIX)
            .unwrap_or_default()
            .into_iter()
            .map(|(_, r)| r)
            .collect();
        rows.sort_by_key(|a| std::cmp::Reverse(a.created_at));
        rows.truncate(limit.clamp(1, 50));
        rows
    }

    pub fn load_run(db: &LibraryDatabase, id: &str) -> Option<AgentRunRecord> {
        let clean = id.trim();
        if clean.is_empty() {
            return None;
        }
        if let Ok(Some(exact)) = db.state::<AgentRunRecord>(&format!("{RUN_KEY_PREFIX}{clean}")) {
            return Some(exact);
        }
        let lowered = clean.to_ascii_lowercase();
        let all = Self::list_runs(db, 50);
        let mut matches: Vec<AgentRunRecord> = all
            .into_iter()
            .filter(|r| r.id.to_ascii_lowercase().starts_with(&lowered))
            .collect();
        if matches.len() == 1 {
            matches.pop()
        } else {
            None
        }
    }

    pub fn mark_run_rolled_back(db: &LibraryDatabase, id: &str) {
        let Some(mut run) = Self::load_run(db, id) else {
            return;
        };
        run.rolled_back_at = Some(Utc::now());
        let _ = db.set_state(&format!("{RUN_KEY_PREFIX}{}", run.id), Some(&run));
    }

    pub fn load_session(db: &LibraryDatabase, id: &str) -> AgentCurationSession {
        let safe_id = sanitize_session_id(id);
        db.state::<AgentCurationSession>(&format!("{SESSION_KEY_PREFIX}{safe_id}"))
            .ok()
            .flatten()
            .unwrap_or_else(|| AgentCurationSession::new(safe_id))
    }

    pub fn record_seen_assets(
        db: &LibraryDatabase,
        session_id: &str,
        asset_ids: &[Uuid],
        reset: bool,
    ) -> AgentCurationSession {
        let safe_id = sanitize_session_id(session_id);
        let mut session = if reset {
            AgentCurationSession::new(&safe_id)
        } else {
            Self::load_session(db, &safe_id)
        };
        let mut existing: HashSet<Uuid> = session.seen_asset_ids.iter().copied().collect();
        for &aid in asset_ids {
            if existing.insert(aid) {
                session.seen_asset_ids.push(aid);
            }
        }
        if session.seen_asset_ids.len() > MAX_SEEN_PER_SESSION {
            let excess = session.seen_asset_ids.len() - MAX_SEEN_PER_SESSION;
            session.seen_asset_ids.drain(..excess);
        }
        session.updated_at = Utc::now();
        let _ = db.set_state(&format!("{SESSION_KEY_PREFIX}{safe_id}"), Some(&session));

        if let Ok(mut all) = db.states_with_prefix::<AgentCurationSession>(SESSION_KEY_PREFIX) {
            if all.len() > MAX_STORED_SESSIONS {
                all.sort_by_key(|a| std::cmp::Reverse(a.1.updated_at));
                for (overflow_key, _) in all.into_iter().skip(MAX_STORED_SESSIONS) {
                    let _ = db.set_state::<AgentCurationSession>(&overflow_key, None);
                }
            }
        }
        session
    }
}

fn sanitize_session_id(raw: &str) -> String {
    let cleaned: String = raw
        .trim()
        .chars()
        .filter(|c| c.is_alphanumeric() || *c == '-' || *c == '_')
        .take(48)
        .collect();
    if cleaned.is_empty() {
        "default".to_string()
    } else {
        cleaned
    }
}
