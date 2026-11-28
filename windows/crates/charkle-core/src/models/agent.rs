//! External Agent Pure MCP v2 policy models mirroring
//! `Sources/CharkleCore/Intelligence/ExternalAgentPolicy.swift`.

use std::collections::BTreeMap;
use std::sync::Arc;

use chrono::{DateTime, Utc};
use rand::RngCore;
use serde::{Deserialize, Deserializer, Serialize, Serializer};
use sha2::{Digest, Sha256};
use uuid::Uuid;

/// 3-tier permission boundary governing External AI Agents across both local `stdio` MCP
/// and remote/local Streamable HTTP MCP.
///
/// Security invariant: External agents are NEVER permitted to permanently delete user assets
/// or delete folders under any access level.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum ExternalAgentAccessLevel {
    #[default]
    ReadOnly,
    InboxAndEnrich,
    ReadWriteOrganize,
}

impl ExternalAgentAccessLevel {
    pub fn as_str(&self) -> &'static str {
        match self {
            Self::ReadOnly => "readOnly",
            Self::InboxAndEnrich => "inboxAndEnrich",
            Self::ReadWriteOrganize => "readWriteOrganize",
        }
    }

    pub fn display_title(&self) -> &'static str {
        match self {
            Self::ReadOnly => "仅只读",
            Self::InboxAndEnrich => "仅收件箱与打标",
            Self::ReadWriteOrganize => "全局整理与生板",
        }
    }

    pub fn allows_inbox_and_enrich_writes(&self) -> bool {
        matches!(self, Self::InboxAndEnrich | Self::ReadWriteOrganize)
    }

    pub fn allows_global_organize_writes(&self) -> bool {
        matches!(self, Self::ReadWriteOrganize)
    }
}

/// Transport channel over which an MCP request arrived.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum ExternalAgentTransport {
    #[default]
    Stdio,
    Http,
}

impl ExternalAgentTransport {
    pub fn as_str(&self) -> &'static str {
        match self {
            Self::Stdio => "stdio",
            Self::Http => "http",
        }
    }
}

/// Scoped Bearer token persisted strictly as SHA-256 hash + display prefix
/// (zero plaintext tokens stored on disk).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ExternalAgentToken {
    #[serde(with = "crate::wire::swift_codec::upper_uuid")]
    pub id: Uuid,
    pub name: String,
    pub token_prefix: String,
    pub token_hash: String,
    pub access_level: ExternalAgentAccessLevel,
    #[serde(default = "default_true")]
    pub is_enabled: bool,
    pub created_at: DateTime<Utc>,
}

fn default_true() -> bool {
    true
}

impl ExternalAgentToken {
    /// Generates a cryptographically random scoped MCP token (`ck_mcp_<48 hex>`), returning
    /// both the persistable hash record and the one-time plaintext secret.
    pub fn mint(name: impl Into<String>, access_level: ExternalAgentAccessLevel) -> (Self, String) {
        let mut bytes = [0u8; 24];
        rand::rngs::OsRng.fill_bytes(&mut bytes);
        let plaintext = format!("ck_mcp_{}", hex::encode(bytes));
        let token_prefix: String = plaintext.chars().take(15).collect();
        let token_hash = Self::sha256_hex(&plaintext);
        let clean = name.into().trim().to_string();
        let record = Self {
            id: Uuid::new_v4(),
            name: if clean.is_empty() {
                "远程 Agent 密钥".to_string()
            } else {
                clean
            },
            token_prefix,
            token_hash,
            access_level,
            is_enabled: true,
            created_at: Utc::now(),
        };
        (record, plaintext)
    }

    pub fn sha256_hex(raw: &str) -> String {
        hex::encode(Sha256::digest(raw.as_bytes()))
    }

    /// Constant-time verification of a presented Bearer token string against `token_hash`.
    pub fn matches(&self, candidate: &str) -> bool {
        if !self.is_enabled || candidate.is_empty() {
            return false;
        }
        let candidate_hash = Self::sha256_hex(candidate);
        constant_time_equals(candidate_hash.as_bytes(), self.token_hash.as_bytes())
    }
}

fn constant_time_equals(a: &[u8], b: &[u8]) -> bool {
    if a.len() != b.len() || a.is_empty() {
        return false;
    }
    let mut diff = 0u8;
    for (&x, &y) in a.iter().zip(b.iter()) {
        diff |= x ^ y;
    }
    diff == 0
}

/// Unified Pure MCP v2 configuration shared between `Charkle.exe` (HTTP MCP + Settings UI)
/// and the bundled headless `charkle-cli.exe` stdio MCP helper.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ExternalAgentConfig {
    /// Controls local headless `stdio` MCP (`charkle-cli.exe mcp`).
    pub mcp_enabled: bool,
    /// Controls embedded Streamable HTTP MCP endpoint (`POST /api/v1/mcp`).
    pub http_mcp_enabled: bool,
    /// When `true`, binds HTTP server on `0.0.0.0` for LAN / Tailscale / remote MCP access
    /// while strictly keeping browser-extension endpoints restricted to loopback (`127.0.0.1`).
    pub allow_remote_http_mcp: bool,
    /// Default access level for local `stdio` MCP sessions.
    pub access_level: ExternalAgentAccessLevel,
    /// Scoped Bearer tokens governing HTTP `/api/v1/mcp` access.
    pub tokens: Vec<ExternalAgentToken>,
}

impl Default for ExternalAgentConfig {
    fn default() -> Self {
        Self {
            mcp_enabled: true,
            http_mcp_enabled: true,
            allow_remote_http_mcp: false,
            access_level: ExternalAgentAccessLevel::ReadOnly,
            tokens: Vec::new(),
        }
    }
}

impl ExternalAgentConfig {
    pub fn fail_closed() -> Self {
        Self {
            mcp_enabled: false,
            http_mcp_enabled: false,
            allow_remote_http_mcp: false,
            access_level: ExternalAgentAccessLevel::ReadOnly,
            tokens: Vec::new(),
        }
    }

    pub fn enabled(&self) -> bool {
        self.mcp_enabled || self.http_mcp_enabled
    }

    pub fn is_enabled_for(&self, transport: ExternalAgentTransport) -> bool {
        match transport {
            ExternalAgentTransport::Stdio => self.mcp_enabled,
            ExternalAgentTransport::Http => self.http_mcp_enabled,
        }
    }

    pub fn matching_token(&self, plaintext: &str) -> Option<&ExternalAgentToken> {
        if !self.http_mcp_enabled {
            return None;
        }
        self.tokens.iter().find(|t| t.matches(plaintext))
    }
}

#[derive(Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct ExternalAgentConfigWire {
    #[serde(default)]
    enabled: Option<bool>,
    #[serde(default)]
    mcp_enabled: Option<bool>,
    #[serde(rename = "httpMCPEnabled", alias = "httpMcpEnabled", default)]
    http_mcp_enabled: Option<bool>,
    #[serde(rename = "allowRemoteHTTPMCP", alias = "allowRemoteHttpMcp", default)]
    allow_remote_http_mcp: Option<bool>,
    #[serde(default)]
    access_level: Option<ExternalAgentAccessLevel>,
    #[serde(default)]
    tokens: Option<Vec<ExternalAgentToken>>,
}

impl Serialize for ExternalAgentConfig {
    fn serialize<S>(&self, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: Serializer,
    {
        ExternalAgentConfigWire {
            enabled: Some(self.enabled()),
            mcp_enabled: Some(self.mcp_enabled),
            http_mcp_enabled: Some(self.http_mcp_enabled),
            allow_remote_http_mcp: Some(self.allow_remote_http_mcp),
            access_level: Some(self.access_level),
            tokens: Some(self.tokens.clone()),
        }
        .serialize(serializer)
    }
}

impl<'de> Deserialize<'de> for ExternalAgentConfig {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: Deserializer<'de>,
    {
        let raw = ExternalAgentConfigWire::deserialize(deserializer)?;
        let legacy_enabled = raw.enabled.unwrap_or(true);
        let decoded_stdio = raw.mcp_enabled.unwrap_or(legacy_enabled);
        Ok(Self {
            mcp_enabled: decoded_stdio,
            http_mcp_enabled: raw.http_mcp_enabled.unwrap_or(decoded_stdio),
            allow_remote_http_mcp: raw.allow_remote_http_mcp.unwrap_or(false),
            access_level: raw
                .access_level
                .unwrap_or(ExternalAgentAccessLevel::ReadOnly),
            tokens: raw.tokens.unwrap_or_default(),
        })
    }
}

/// Callback supplied by HTTP MCP host to mint short-lived signed download URLs for cross-machine asset fetches.
pub type DownloadUrlIssuer = Arc<dyn Fn(Uuid) -> Option<String> + Send + Sync>;

/// Per-request execution context injected by either `stdio` MCP or HTTP `/api/v1/mcp`.
#[derive(Clone)]
pub struct ExternalAgentRequestContext {
    pub transport: ExternalAgentTransport,
    /// Optional token-scoped override for HTTP requests. When `None`, falls back to `ExternalAgentConfig.access_level`.
    pub scoped_access_level: Option<ExternalAgentAccessLevel>,
    /// Human-readable caller label recorded in `AgentRunRecord` audit logs.
    pub actor_label: String,
    /// Optional signed download URL issuer for HTTP MCP `inspect_assets(include_download_url: true)`.
    pub issue_download_url: Option<DownloadUrlIssuer>,
}

impl Default for ExternalAgentRequestContext {
    fn default() -> Self {
        Self::local_stdio()
    }
}

impl ExternalAgentRequestContext {
    pub fn local_stdio() -> Self {
        Self {
            transport: ExternalAgentTransport::Stdio,
            scoped_access_level: None,
            actor_label: "local-stdio".to_string(),
            issue_download_url: None,
        }
    }

    pub fn effective_access_level(&self, policy: &ExternalAgentConfig) -> ExternalAgentAccessLevel {
        self.scoped_access_level.unwrap_or(policy.access_level)
    }

    pub fn is_remote_http(&self) -> bool {
        self.transport == ExternalAgentTransport::Http
    }
}

/// User-editable personal library organization rules exposed via `library_overview` and
/// `charkle://library/taxonomy` (and consumed by Jev closed-set tag alias folding).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct LibraryTaxonomyPolicy {
    #[serde(default = "default_tag_language")]
    pub preferred_tag_language: String,
    #[serde(default)]
    pub tag_aliases: BTreeMap<String, String>,
    #[serde(default)]
    pub folder_guidelines: BTreeMap<String, String>,
    #[serde(default)]
    pub rating_meanings: BTreeMap<String, String>,
    #[serde(default)]
    pub notes: String,
}

fn default_tag_language() -> String {
    "zh".to_string()
}

impl Default for LibraryTaxonomyPolicy {
    fn default() -> Self {
        Self {
            preferred_tag_language: default_tag_language(),
            tag_aliases: BTreeMap::new(),
            folder_guidelines: BTreeMap::new(),
            rating_meanings: BTreeMap::new(),
            notes: String::new(),
        }
    }
}

impl LibraryTaxonomyPolicy {
    pub fn is_empty(&self) -> bool {
        self.tag_aliases.is_empty()
            && self.folder_guidelines.is_empty()
            && self.rating_meanings.is_empty()
            && self.notes.trim().is_empty()
    }
}
