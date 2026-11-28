//! Grounded 10-tool Pure MCP v2 External Agent Service powering BOTH:
//! 1. Local headless **stdio MCP Server (`charkle-cli.exe mcp`)** over JSON-RPC 2.0 (single + batch)
//! 2. Desktop **Streamable HTTP MCP (`POST /api/v1/mcp` + `GET /api/v1/mcp/download/<ticket>`)**
//!
//! Pure MCP v2 Contract (1:1 with `Sources/CharkleCore/Intelligence/CharkleExternalAgentService.swift`):
//! - 10 orthogonal safe tools (`< 12 KB` `tools/list` schema budget), 5 static + 2 template resources, 5 prompts.
//! - Compact JSON default; disk `output_path` strictly retired (inline MCP `image` blocks + signed HTTP tickets).
//! - Universal 8+ char short UUID prefix resolution with explicit ambiguity rejection.
//! - 3-tier permission model (`readOnly` / `inboxAndEnrich` / `readWriteOrganize`) with per-token HTTP scoping.
//! - Every mutating tool records a rollback journal (`runID`) restored via compensating HLC ops (`rollback_run`).
//! - Non-negotiable safety invariant: permanent deletion of assets and deletion of folders are NEVER exposed.

use std::collections::{BTreeSet, HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::sync::Arc;

use base64::engine::general_purpose::STANDARD as BASE64;
use base64::Engine;
use chrono::Utc;
use image::codecs::jpeg::JpegEncoder;
use serde_json::{json, Map, Value};
use url::Url;
use uuid::Uuid;

use crate::agent::policy::ExternalAgentConfigStore;
use crate::agent::run_store::{
    AgentAssetSnapshot, AgentFolderSnapshot, AgentRunRecord, ExternalAgentStateStore,
};
use crate::db::search_text;
use crate::engine::{LiveCharkleEngine, LocalSemanticSearchHit};
use crate::error::{CoreError, CoreResult};
use crate::export::{BoardImageFormat, MoodboardExportOptions};
use crate::intelligence::{
    render_contact_sheet_with_options, ContactSheetOptions, VisualTone,
    CONTACT_SHEET_DEFAULT_WIDTH, CONTACT_SHEET_MAX_ASSETS, CONTACT_SHEET_MAX_WIDTH,
    CONTACT_SHEET_MIN_WIDTH,
};
use crate::media::dedup::{
    DeduplicationResolutionPlan, DeduplicationScanScope, DeduplicationSensitivity,
    DuplicateDisposalMode,
};
use crate::media::eaglepack::StagingDirGuard;
use crate::models::agent::{
    ExternalAgentAccessLevel, ExternalAgentConfig, ExternalAgentRequestContext,
};
use crate::models::core::{
    AspectShape, AssetBatchPatch, AssetRecord, FilterCriteria, FolderAssignment, FolderRecord,
    LabColor, MediaKind, SmartFolderRecord, SortOrder,
};
use crate::models::media::{CaptureInput, ThumbnailTier};
use crate::models::moodboard::{
    AutoLayoutConfig, BoardLayoutMode, BoardNode, BoardNodeKind, BoardRect, EditorialStyle,
    GroupTint, MoodboardCurationRequest, MoodboardDocument, NoteStyle,
};
use crate::wire::swift_codec::format_swift_uuid;

pub const SERVER_VERSION: &str = "2.0.0";

pub const SUPPORTED_PROTOCOL_VERSIONS: &[&str] =
    &["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"];

pub const DEFAULT_PROTOCOL_VERSION: &str = "2025-03-26";

pub const READ_TOOL_NAMES: &[&str] = &[
    "library_overview",
    "query_assets",
    "inspect_assets",
    "get_board",
];

pub const WRITE_TOOL_NAMES: &[&str] = &[
    "ingest_assets",
    "organize_assets",
    "manage_folder",
    "save_moodboard",
    "deduplicate_assets",
    "rollback_run",
];

const MAX_INLINE_FILE_BYTES: usize = 16 * 1024 * 1024;
const MAX_INLINE_BATCH_BYTES: usize = 32 * 1024 * 1024;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum AssetDetailLevel {
    Visual,
    Compact,
    Standard,
    Full,
}

impl AssetDetailLevel {
    fn parse(raw: Option<&Value>, fallback: Self) -> Self {
        match raw
            .and_then(Value::as_str)
            .map(|s| s.trim().to_ascii_lowercase())
            .as_deref()
        {
            Some("visual") => Self::Visual,
            Some("compact") => Self::Compact,
            Some("standard") => Self::Standard,
            Some("full") => Self::Full,
            _ => fallback,
        }
    }
}

#[derive(Debug, Clone, Copy)]
struct NormalizedCropBox {
    x: f64,
    y: f64,
    width: f64,
    height: f64,
}

#[derive(Debug, Clone)]
pub enum ToolContent {
    Text(String),
    Image { mime_type: String, data: Vec<u8> },
}

impl ToolContent {
    pub fn to_mcp_value(&self) -> Value {
        match self {
            Self::Text(text) => json!({ "type": "text", "text": text }),
            Self::Image { mime_type, data } => json!({
                "type": "image",
                "mimeType": mime_type,
                "data": BASE64.encode(data)
            }),
        }
    }
}

#[derive(Debug, Clone)]
pub struct ToolOutput {
    pub content: Vec<ToolContent>,
    pub is_error: bool,
}

impl ToolOutput {
    /// Serializes `value` as compact single-line JSON (zero pretty whitespace) for minimal token cost.
    pub fn json(value: Value) -> Self {
        let text = serde_json::to_string(&value).unwrap_or_else(|_| "{}".to_string());
        Self {
            content: vec![ToolContent::Text(text)],
            is_error: false,
        }
    }

    pub fn error(message: impl Into<String>) -> Self {
        Self {
            content: vec![ToolContent::Text(message.into())],
            is_error: true,
        }
    }

    pub fn first_text(&self) -> String {
        self.content
            .iter()
            .find_map(|c| match c {
                ToolContent::Text(s) => Some(s.clone()),
                _ => None,
            })
            .unwrap_or_default()
    }
}

/// Optional callback fired after any write tool commits so a running desktop shell refreshes live.
pub type WriteWakeHook = Arc<dyn Fn(&str) + Send + Sync>;

struct FolderProfile {
    direct_count: usize,
    recursive_count: usize,
    top_tags: Vec<String>,
    palette: Vec<String>,
    dominant_aspect: Option<String>,
}

struct AttachedContactSheet {
    slot_count: usize,
    jpeg_bytes: Vec<u8>,
    width: u32,
    height: u32,
}

impl AttachedContactSheet {
    fn summary(&self) -> Value {
        json!({
            "tileCount": self.slot_count,
            "width": self.width,
            "height": self.height,
            "bytes": self.jpeg_bytes.len(),
            "mimeType": "image/jpeg"
        })
    }
}

struct MultiQueryRecallResult {
    hits: Vec<(LocalSemanticSearchHit, String)>,
    groups_summary: Vec<Value>,
    total_unique_matched: usize,
}

struct NormalizedOrganizeItem {
    asset_id: Uuid,
    folder_assignment: FolderAssignment,
    folder_target_label: Option<String>,
    add_tags: Vec<String>,
    remove_tags: Vec<String>,
    add_suggested_tags: Vec<String>,
    accept_suggested_tags: bool,
    dismiss_suggested_tags: Vec<String>,
    rating: Option<i32>,
    title: Option<String>,
    notes: Option<String>,
    ai_description: Option<String>,
    pinned_offline: Option<bool>,
    is_trashed: Option<bool>,
    analyze: bool,
    refresh_rich_metadata: bool,
}

impl NormalizedOrganizeItem {
    fn touches_curated_fields(&self) -> bool {
        !matches!(self.folder_assignment, FolderAssignment::Unchanged)
            || !self.add_tags.is_empty()
            || !self.remove_tags.is_empty()
            || self.accept_suggested_tags
            || !self.dismiss_suggested_tags.is_empty()
            || self.rating.is_some()
            || self.title.is_some()
            || self.notes.is_some()
    }

    fn has_batch_patch_fields(&self) -> bool {
        self.touches_curated_fields() || self.pinned_offline.is_some() || self.is_trashed.is_some()
    }
}

pub struct CharkleExternalAgentService {
    engine: Arc<LiveCharkleEngine>,
    data_dir: PathBuf,
    on_write: Option<WriteWakeHook>,
}

impl CharkleExternalAgentService {
    pub fn new(
        engine: Arc<LiveCharkleEngine>,
        data_dir: PathBuf,
        on_write: Option<WriteWakeHook>,
    ) -> Self {
        Self {
            engine,
            data_dir,
            on_write,
        }
    }

    pub fn current_policy(&self) -> ExternalAgentConfig {
        ExternalAgentConfigStore::load(&self.data_dir)
    }

    pub fn negotiate_protocol_version(requested: Option<&str>) -> &'static str {
        if let Some(req) = requested {
            for &supported in SUPPORTED_PROTOCOL_VERSIONS {
                if supported == req {
                    return supported;
                }
            }
        }
        DEFAULT_PROTOCOL_VERSION
    }

    fn notify_write(&self, kind: &str) {
        if let Some(hook) = &self.on_write {
            hook(kind);
        }
    }

    /// Runs internal Pure MCP v2 readiness diagnostics (`charkle-cli doctor` & Settings self-check).
    pub fn run_diagnostics(&self) -> Value {
        let policy = self.current_policy();
        let db_path = self.data_dir.join("Library.sqlite3");
        let db_exists = db_path.exists();
        let assets_res = self.engine.fetch_assets(&FilterCriteria::default());
        let folders_res = self.engine.fetch_folders();
        let boards_res = self.engine.fetch_boards();
        let ok = db_exists && assets_res.is_ok() && folders_res.is_ok() && boards_res.is_ok();
        let tools_schema = Self::mcp_tool_definitions();
        let schema_bytes = serde_json::to_vec(&tools_schema)
            .map(|v| v.len())
            .unwrap_or(0);
        json!({
            "ok": ok,
            "serverVersion": SERVER_VERSION,
            "libraryDir": self.data_dir.display().to_string(),
            "databaseExists": db_exists,
            "mcpEnabled": policy.mcp_enabled,
            "httpMCPEnabled": policy.http_mcp_enabled,
            "allowRemoteHTTPMCP": policy.allow_remote_http_mcp,
            "accessLevel": policy.access_level.as_str(),
            "activeTokenCount": policy.tokens.iter().filter(|t| t.is_enabled).count(),
            "assetCount": assets_res.map(|v| v.len()).unwrap_or(0),
            "folderCount": folders_res.map(|v| v.len()).unwrap_or(0),
            "boardCount": boards_res.map(|v| v.len()).unwrap_or(0),
            "toolCount": tools_schema.len(),
            "resourceCount": Self::mcp_resource_definitions().len() + Self::mcp_resource_template_definitions().len(),
            "promptCount": Self::mcp_prompt_definitions().len(),
            "toolsSchemaBytes": schema_bytes
        })
    }

    // =========================================================================
    // MCP JSON-RPC 2.0 Dispatcher (Single Object + Batch Arrays, Stdio + HTTP)
    // =========================================================================

    pub async fn handle_jsonrpc(&self, raw_payload: &str) -> Option<String> {
        self.handle_jsonrpc_with_context(raw_payload, &ExternalAgentRequestContext::local_stdio())
            .await
    }

    pub async fn handle_jsonrpc_with_context(
        &self,
        raw_payload: &str,
        ctx: &ExternalAgentRequestContext,
    ) -> Option<String> {
        let parsed: Value = match serde_json::from_str(raw_payload) {
            Ok(v) => v,
            Err(_) => {
                return Some(
                    Self::error_value(Value::Null, -32700, "Parse error: invalid JSON").to_string(),
                );
            }
        };

        if let Value::Array(items) = parsed {
            if items.is_empty() {
                return Some(
                    Self::error_value(Value::Null, -32600, "Invalid Request: empty batch")
                        .to_string(),
                );
            }
            let mut responses = Vec::new();
            for item in items {
                if let Some(resp) = self.handle_single_jsonrpc(&item, ctx).await {
                    responses.push(resp);
                }
            }
            return if responses.is_empty() {
                None
            } else {
                serde_json::to_string(&Value::Array(responses)).ok()
            };
        }

        self.handle_single_jsonrpc(&parsed, ctx)
            .await
            .and_then(|v| serde_json::to_string(&v).ok())
    }

    async fn handle_single_jsonrpc(
        &self,
        parsed: &Value,
        ctx: &ExternalAgentRequestContext,
    ) -> Option<Value> {
        if !parsed.is_object() {
            return Some(Self::error_value(
                Value::Null,
                -32600,
                "Invalid Request: expected JSON object",
            ));
        }

        let id = parsed.get("id").cloned();
        let is_notification = id.is_none() || matches!(id, Some(Value::Null));
        let Some(method) = parsed.get("method").and_then(Value::as_str) else {
            return if is_notification {
                None
            } else {
                Some(Self::error_value(
                    id.unwrap_or(Value::Null),
                    -32600,
                    "Invalid Request: missing method",
                ))
            };
        };
        let params = parsed.get("params").cloned().unwrap_or_else(|| json!({}));
        let req_id = id.unwrap_or(Value::Null);

        let disabled_msg = if ctx.is_remote_http() {
            "Charkle HTTP MCP service is disabled in Settings."
        } else {
            "Charkle local stdio MCP service is disabled in Settings."
        };

        match method {
            "initialize" => {
                let policy = self.current_policy();
                if !policy.is_enabled_for(ctx.transport) {
                    return Some(Self::error_value(req_id, -32001, disabled_msg));
                }
                let protocol_version = Self::negotiate_protocol_version(
                    params.get("protocolVersion").and_then(Value::as_str),
                );
                Some(Self::result_value(
                    req_id,
                    json!({
                        "protocolVersion": protocol_version,
                        "capabilities": {
                            "tools": { "listChanged": false },
                            "resources": { "subscribe": false, "listChanged": false },
                            "prompts": { "listChanged": false },
                            "logging": {}
                        },
                        "serverInfo": {
                            "name": "charkle",
                            "version": SERVER_VERSION
                        },
                        "instructions": "Charkle Pure MCP v2 visual reference library & moodboard studio (10 safe tools). Workflow: (1) Call `library_overview` first to inspect compact folder profiles, canonical tags, taxonomy, boards, and active permissions. (2) Use `query_assets` (text/semantic `query` or `queries[]`, `only_inbox`, `tone`, `seed_asset_ids`/`unlike_asset_ids`, `diversify`, `contact_sheet:true`, `include_folder_suggestions`, `session_id`) to visually inspect up to 24 candidates in ONE call. (3) Call `inspect_assets` only on finalists (supports `crop_box` zoom and HTTP `include_download_url`). (4) Batch-commit via `organize_assets(items[], dry_run)` or `save_moodboard`; every write returns a `runID` reversible via `rollback_run`. Permanent deletion is never permitted."
                    }),
                ))
            }
            "notifications/initialized" | "notifications/cancelled" | "initialized" => None,
            "ping" | "logging/setLevel" => Some(Self::result_value(req_id, json!({}))),
            "tools/list" => {
                let policy = self.current_policy();
                if !policy.is_enabled_for(ctx.transport) {
                    return Some(Self::error_value(req_id, -32001, disabled_msg));
                }
                Some(Self::result_value(
                    req_id,
                    json!({ "tools": Self::mcp_tool_definitions() }),
                ))
            }
            "tools/call" => {
                let Some(name) = params.get("name").and_then(Value::as_str) else {
                    return Some(Self::error_value(
                        req_id,
                        -32602,
                        "Invalid params: missing tool name",
                    ));
                };
                let args = params
                    .get("arguments")
                    .cloned()
                    .unwrap_or_else(|| json!({}));
                let output = self.call_tool_with_context(name, &args, ctx).await;
                Some(Self::result_value(
                    req_id,
                    json!({
                        "content": output.content.iter().map(ToolContent::to_mcp_value).collect::<Vec<_>>(),
                        "isError": output.is_error
                    }),
                ))
            }
            "resources/list" => {
                let policy = self.current_policy();
                if !policy.is_enabled_for(ctx.transport) {
                    return Some(Self::error_value(req_id, -32001, disabled_msg));
                }
                Some(Self::result_value(
                    req_id,
                    json!({ "resources": Self::mcp_resource_definitions() }),
                ))
            }
            "resources/templates/list" => {
                let policy = self.current_policy();
                if !policy.is_enabled_for(ctx.transport) {
                    return Some(Self::error_value(req_id, -32001, disabled_msg));
                }
                Some(Self::result_value(
                    req_id,
                    json!({ "resourceTemplates": Self::mcp_resource_template_definitions() }),
                ))
            }
            "resources/read" => {
                let policy = self.current_policy();
                if !policy.is_enabled_for(ctx.transport) {
                    return Some(Self::error_value(req_id, -32001, disabled_msg));
                }
                let Some(uri) = params.get("uri").and_then(Value::as_str) else {
                    return Some(Self::error_value(req_id, -32602, "Missing resource uri"));
                };
                match self.read_resource(uri, ctx).await {
                    Ok(text) => Some(Self::result_value(
                        req_id,
                        json!({
                            "contents": [{
                                "uri": uri,
                                "mimeType": "application/json",
                                "text": text
                            }]
                        }),
                    )),
                    Err(msg) => Some(Self::error_value(req_id, -32002, &msg)),
                }
            }
            "prompts/list" => {
                let policy = self.current_policy();
                if !policy.is_enabled_for(ctx.transport) {
                    return Some(Self::error_value(req_id, -32001, disabled_msg));
                }
                Some(Self::result_value(
                    req_id,
                    json!({ "prompts": Self::mcp_prompt_definitions() }),
                ))
            }
            "prompts/get" => {
                let policy = self.current_policy();
                if !policy.is_enabled_for(ctx.transport) {
                    return Some(Self::error_value(req_id, -32001, disabled_msg));
                }
                let Some(name) = params.get("name").and_then(Value::as_str) else {
                    return Some(Self::error_value(req_id, -32602, "Missing prompt name"));
                };
                let args = params
                    .get("arguments")
                    .cloned()
                    .unwrap_or_else(|| json!({}));
                match Self::render_prompt(name, &args) {
                    Some(prompt) => Some(Self::result_value(req_id, prompt)),
                    None => Some(Self::error_value(
                        req_id,
                        -32602,
                        &format!("Unknown prompt: {name}"),
                    )),
                }
            }
            _ => {
                if is_notification {
                    None
                } else {
                    Some(Self::error_value(
                        req_id,
                        -32601,
                        &format!("Method not found: {method}"),
                    ))
                }
            }
        }
    }

    async fn read_resource(
        &self,
        uri: &str,
        ctx: &ExternalAgentRequestContext,
    ) -> Result<String, String> {
        if uri == "charkle://library/overview" {
            let out = self
                .call_tool_with_context("library_overview", &json!({}), ctx)
                .await;
            return Ok(out.first_text());
        }
        if uri == "charkle://library/taxonomy" {
            let policy = ExternalAgentStateStore::load_taxonomy(self.engine.database());
            let top_tags: Vec<Value> = self
                .engine
                .fetch_tag_counts()
                .unwrap_or_default()
                .into_iter()
                .take(40)
                .map(|t| json!({ "name": t.name, "count": t.count }))
                .collect();
            return Ok(serde_json::to_string(&json!({
                "preferredTagLanguage": policy.preferred_tag_language,
                "tagAliases": policy.tag_aliases,
                "folderGuidelines": policy.folder_guidelines,
                "ratingMeanings": policy.rating_meanings,
                "notes": policy.notes,
                "topCanonicalTags": top_tags
            }))
            .unwrap_or_default());
        }
        if uri == "charkle://boards" {
            let out = self
                .call_tool_with_context("get_board", &json!({}), ctx)
                .await;
            return Ok(out.first_text());
        }
        if uri == "charkle://folders" {
            let folders = self.engine.fetch_folders().map_err(|e| e.to_string())?;
            let active_assets = self
                .engine
                .fetch_assets(&FilterCriteria::default())
                .map_err(|e| e.to_string())?;
            let paths = build_folder_paths(&folders);
            let profiles = build_folder_profiles(&folders, &active_assets);
            let items: Vec<Value> = folders
                .iter()
                .map(|f| {
                    let mut entry = Map::new();
                    entry.insert("id".into(), json!(format_swift_uuid(&f.id)));
                    entry.insert("name".into(), json!(f.name));
                    entry.insert(
                        "path".into(),
                        json!(paths.get(&f.id).cloned().unwrap_or_else(|| f.name.clone())),
                    );
                    if let Some(pid) = f.parent_id {
                        entry.insert("parentID".into(), json!(format_swift_uuid(&pid)));
                    }
                    if let Some(p) = profiles.get(&f.id) {
                        entry.insert("assetCount".into(), json!(p.direct_count));
                        entry.insert("recursiveAssetCount".into(), json!(p.recursive_count));
                        if !p.top_tags.is_empty() {
                            entry.insert("topTags".into(), json!(p.top_tags));
                        }
                        if !p.palette.is_empty() {
                            entry.insert("palette".into(), json!(p.palette));
                        }
                        if let Some(ref asp) = p.dominant_aspect {
                            entry.insert("dominantAspect".into(), json!(asp));
                        }
                    } else {
                        entry.insert("assetCount".into(), json!(f.asset_count));
                    }
                    if let Some(ref hex) = f.color_hex {
                        if !hex.is_empty() {
                            entry.insert("colorHex".into(), json!(hex));
                        }
                    }
                    if let Some(ref sym) = f.custom_symbol {
                        if !sym.is_empty() {
                            entry.insert("customSymbol".into(), json!(sym));
                        }
                    }
                    Value::Object(entry)
                })
                .collect();
            return Ok(serde_json::to_string(&json!({
                "count": items.len(),
                "folders": items
            }))
            .unwrap_or_default());
        }
        if uri == "charkle://smart-folders" {
            let smart_folders = self
                .engine
                .fetch_smart_folders()
                .map_err(|e| e.to_string())?;
            let all_assets = self
                .engine
                .fetch_assets(&FilterCriteria::default())
                .map_err(|e| e.to_string())?;
            let items: Vec<Value> = smart_folders
                .iter()
                .map(|sf| {
                    let match_count = all_assets.iter().filter(|a| sf.rule.matches(a)).count();
                    json!({
                        "id": format_swift_uuid(&sf.id),
                        "name": sf.name,
                        "colorHex": sf.color_hex,
                        "matchCount": match_count,
                        "rule": sf.rule
                    })
                })
                .collect();
            return Ok(serde_json::to_string(&json!({
                "count": items.len(),
                "smartFolders": items
            }))
            .unwrap_or_default());
        }
        if let Some(asset_id) = uri.strip_prefix("charkle://assets/") {
            let out = self
                .call_tool_with_context(
                    "inspect_assets",
                    &json!({ "asset_id": asset_id.trim() }),
                    ctx,
                )
                .await;
            if out.is_error {
                return Err(out.first_text());
            }
            return Ok(out.first_text());
        }
        if let Some(board_id) = uri.strip_prefix("charkle://boards/") {
            let out = self
                .call_tool_with_context("get_board", &json!({ "board_id": board_id.trim() }), ctx)
                .await;
            if out.is_error {
                return Err(out.first_text());
            }
            return Ok(out.first_text());
        }
        Err(format!("Unknown resource URI: {uri}"))
    }

    // =========================================================================
    // Unified 10-Tool Pure MCP v2 Router
    // =========================================================================

    pub async fn call_tool(&self, name: &str, args: &Value) -> ToolOutput {
        self.call_tool_with_context(name, args, &ExternalAgentRequestContext::local_stdio())
            .await
    }

    pub async fn call_tool_with_context(
        &self,
        name: &str,
        args: &Value,
        ctx: &ExternalAgentRequestContext,
    ) -> ToolOutput {
        let policy = self.current_policy();
        if !policy.is_enabled_for(ctx.transport) {
            return ToolOutput::error(if ctx.is_remote_http() {
                "Charkle 远程 / 本地 HTTP MCP 服务已在「设置 → 外部 Agent」中关闭。"
            } else {
                "Charkle 本机 MCP 服务已在「设置 → 外部 Agent」中关闭，请先开启后再试。"
            });
        }

        // Retired disk-write `output_path` is strictly rejected across all Pure MCP v2 tools.
        if args
            .get("output_path")
            .and_then(Value::as_str)
            .is_some_and(|s| !s.trim().is_empty())
        {
            return ToolOutput::error(
                "MCP v2 已移除 `output_path` 写盘参数；请直接使用工具返回的内联图片或 `inspect_assets(include_download_url: true)`。",
            );
        }

        let effective_access = ctx.effective_access_level(&policy);

        let res = match name {
            // Read Tools (4)
            "library_overview" => {
                self.handle_library_overview(args, &policy, effective_access, ctx)
            }
            "query_assets" => self.handle_query_assets(args, ctx),
            "inspect_assets" => self.handle_inspect_assets(args, ctx),
            "get_board" => self.handle_get_board(args, ctx),

            // Safe Write Tools (6 — Zero Permanent Delete, All Emit `runID`)
            "ingest_assets" => self.handle_ingest_assets(args, effective_access, ctx).await,
            "organize_assets" => {
                self.handle_organize_assets(args, effective_access, ctx)
                    .await
            }
            "manage_folder" => self.handle_manage_folder(args, effective_access, ctx),
            "save_moodboard" => {
                self.handle_save_moodboard(args, effective_access, ctx)
                    .await
            }
            "deduplicate_assets" => {
                self.handle_deduplicate_assets(args, effective_access, ctx)
                    .await
            }
            "rollback_run" => self.handle_rollback_run(args, effective_access, ctx),

            _ => return ToolOutput::error(format!("Unknown Charkle MCP tool: {name}")),
        };
        match res {
            Ok(out) => out,
            Err(err) => ToolOutput::error(format!("Tool {name} failed: {err}")),
        }
    }

    // =========================================================================
    // Universal 8+ Char Short UUID Prefix Resolution & Safe Local File Guard
    // =========================================================================

    fn resolve_asset_uuid(&self, raw: &str) -> CoreResult<Uuid> {
        let trimmed = raw.trim();
        if let Ok(uuid) = Uuid::parse_str(trimmed) {
            return Ok(uuid);
        }
        if trimmed.len() >= 8 && trimmed.bytes().all(|b| b.is_ascii_hexdigit() || b == b'-') {
            let matches = self.engine.asset_ids_matching_prefix(trimmed, 5)?;
            return match matches.len() {
                0 => Err(CoreError::NotFound(format!(
                    "Asset not found for prefix: {trimmed}"
                ))),
                1 => Ok(matches[0]),
                _ => {
                    let preview = matches
                        .iter()
                        .take(5)
                        .map(format_swift_uuid)
                        .collect::<Vec<_>>()
                        .join(", ");
                    Err(CoreError::InvalidOperation(format!(
                        "Ambiguous asset ID prefix '{trimmed}' matched {} assets ({preview}). Provide a longer prefix.",
                        matches.len()
                    )))
                }
            };
        }
        Err(CoreError::InvalidOperation(format!(
            "Invalid asset UUID or 8+ char prefix: {trimmed}"
        )))
    }

    fn resolve_asset_uuid_list(&self, val: Option<&Value>) -> CoreResult<Vec<Uuid>> {
        let raw_list = string_array_arg(val);
        let mut out = Vec::with_capacity(raw_list.len());
        for raw in raw_list {
            out.push(self.resolve_asset_uuid(&raw)?);
        }
        Ok(out)
    }

    fn resolve_folder_uuid(&self, raw: &str) -> CoreResult<Uuid> {
        let trimmed = raw.trim();
        if let Ok(uuid) = Uuid::parse_str(trimmed) {
            return Ok(uuid);
        }
        if trimmed.len() >= 8 && trimmed.bytes().all(|b| b.is_ascii_hexdigit() || b == b'-') {
            let matches = self.engine.folder_ids_matching_prefix(trimmed, 5)?;
            return match matches.len() {
                0 => Err(CoreError::NotFound(format!(
                    "Folder not found for prefix: {trimmed}"
                ))),
                1 => Ok(matches[0]),
                _ => {
                    let preview = matches
                        .iter()
                        .take(5)
                        .map(format_swift_uuid)
                        .collect::<Vec<_>>()
                        .join(", ");
                    Err(CoreError::InvalidOperation(format!(
                        "Ambiguous folder ID prefix '{trimmed}' matched {} folders ({preview}).",
                        matches.len()
                    )))
                }
            };
        }
        Err(CoreError::InvalidOperation(format!(
            "Invalid folder UUID or 8+ char prefix: {trimmed}"
        )))
    }

    fn resolve_board_uuid(&self, raw: &str) -> CoreResult<Uuid> {
        let trimmed = raw.trim();
        if let Ok(uuid) = Uuid::parse_str(trimmed) {
            return Ok(uuid);
        }
        if trimmed.len() >= 8 && trimmed.bytes().all(|b| b.is_ascii_hexdigit() || b == b'-') {
            let matches = self.engine.board_ids_matching_prefix(trimmed, 5)?;
            return match matches.len() {
                0 => Err(CoreError::NotFound(format!(
                    "Moodboard not found for prefix: {trimmed}"
                ))),
                1 => Ok(matches[0]),
                _ => {
                    let preview = matches
                        .iter()
                        .take(5)
                        .map(format_swift_uuid)
                        .collect::<Vec<_>>()
                        .join(", ");
                    Err(CoreError::InvalidOperation(format!(
                        "Ambiguous board ID prefix '{trimmed}' matched {} boards ({preview}).",
                        matches.len()
                    )))
                }
            };
        }
        Err(CoreError::InvalidOperation(format!(
            "Invalid board UUID or 8+ char prefix: {trimmed}"
        )))
    }

    fn resolve_optional_folder_id(
        &self,
        args: &Value,
        folders: &[FolderRecord],
        folder_paths: &HashMap<Uuid, String>,
    ) -> CoreResult<Option<Uuid>> {
        if let Some(raw_id) = args
            .get("folder_id")
            .and_then(Value::as_str)
            .map(str::trim)
            .filter(|s| !s.is_empty())
        {
            return Ok(Some(self.resolve_folder_uuid(raw_id)?));
        }
        if let Some(path) = args
            .get("folder_path")
            .and_then(Value::as_str)
            .map(str::trim)
            .filter(|s| !s.is_empty())
        {
            if let Some((id, _)) = folder_paths
                .iter()
                .find(|(_, p)| p.eq_ignore_ascii_case(path))
            {
                return Ok(Some(*id));
            }
            if let Some(f) = folders.iter().find(|f| f.name.eq_ignore_ascii_case(path)) {
                return Ok(Some(f.id));
            }
            return Err(CoreError::NotFound(format!("Folder not found: {path}")));
        }
        Ok(None)
    }

    fn resolve_parent_folder_id(
        &self,
        args: &Value,
        folders: &[FolderRecord],
        folder_paths: &HashMap<Uuid, String>,
    ) -> CoreResult<Option<Uuid>> {
        if let Some(raw_id) = args
            .get("parent_id")
            .and_then(Value::as_str)
            .map(str::trim)
            .filter(|s| !s.is_empty())
        {
            return Ok(Some(self.resolve_folder_uuid(raw_id)?));
        }
        if let Some(ppath) = args
            .get("parent_path")
            .and_then(Value::as_str)
            .map(str::trim)
            .filter(|s| !s.is_empty())
        {
            if let Some((id, _)) = folder_paths
                .iter()
                .find(|(_, p)| p.eq_ignore_ascii_case(ppath))
            {
                return Ok(Some(*id));
            }
            if let Some(f) = folders.iter().find(|f| f.name.eq_ignore_ascii_case(ppath)) {
                return Ok(Some(f.id));
            }
            return Err(CoreError::NotFound(format!(
                "Parent folder not found: {ppath}"
            )));
        }
        Ok(None)
    }

    fn resolve_optional_smart_folder(&self, args: &Value) -> CoreResult<Option<SmartFolderRecord>> {
        let smart_folder_id = args
            .get("smart_folder_id")
            .and_then(Value::as_str)
            .map(str::trim)
            .filter(|s| !s.is_empty());
        let smart_folder_name = args
            .get("smart_folder_name")
            .and_then(Value::as_str)
            .map(str::trim)
            .filter(|s| !s.is_empty());
        if smart_folder_id.is_none() && smart_folder_name.is_none() {
            return Ok(None);
        }
        let sfs = self.engine.fetch_smart_folders()?;
        let found = if let Some(raw_id) = smart_folder_id {
            let upper = raw_id.to_ascii_uppercase();
            sfs.into_iter().find(|sf| {
                let full = format_swift_uuid(&sf.id);
                full == upper || (upper.len() >= 8 && full.starts_with(&upper))
            })
        } else if let Some(name) = smart_folder_name {
            sfs.into_iter()
                .find(|sf| sf.name.eq_ignore_ascii_case(name))
        } else {
            None
        };
        match found {
            Some(sf) => Ok(Some(sf)),
            None => Err(CoreError::NotFound("Smart folder not found.".to_string())),
        }
    }

    fn validate_agent_ingest_file_path(&self, raw: &str) -> Result<PathBuf, String> {
        let trimmed = raw.trim();
        if trimmed.is_empty() {
            return Err("file_path cannot be empty.".to_string());
        }
        if trimmed.starts_with("\\\\") {
            return Err("拒绝从 UNC 网络共享路径导入文件。".to_string());
        }
        let path = PathBuf::from(trimmed);
        if !path.is_absolute() {
            return Err("file_path 必须为本地绝对路径。".to_string());
        }
        let canon = std::fs::canonicalize(&path)
            .map_err(|_| format!("File not found at path: {trimmed}"))?;
        if !canon.is_file() {
            return Err(format!("Path is not a regular file: {trimmed}"));
        }
        if let Ok(data_canon) = std::fs::canonicalize(&self.data_dir) {
            if canon.starts_with(&data_canon) {
                return Err("禁止从 Charkle 内部数据目录重复导入文件。".to_string());
            }
        }
        let lower = canon.to_string_lossy().to_ascii_lowercase();
        for blocked in [
            "\\windows\\",
            "\\program files\\",
            "\\program files (x86)\\",
            "\\programdata\\",
            "/.ssh/",
            "\\.ssh\\",
            "/.gnupg/",
            "\\.gnupg\\",
            "/.aws/",
            "\\.aws\\",
            "/etc/",
            "/proc/",
            "/sys/",
        ] {
            if lower.contains(blocked) {
                return Err("拒绝从系统或敏感凭据目录导入文件。".to_string());
            }
        }
        Ok(canon)
    }

    // =========================================================================
    // Tool 1: library_overview
    // =========================================================================

    fn handle_library_overview(
        &self,
        args: &Value,
        policy: &ExternalAgentConfig,
        effective_access: ExternalAgentAccessLevel,
        ctx: &ExternalAgentRequestContext,
    ) -> CoreResult<ToolOutput> {
        let compact = bool_arg(args.get("compact")).unwrap_or(true);
        let include_profiles = bool_arg(args.get("include_folder_profiles")).unwrap_or(true);
        let include_boards = bool_arg(args.get("include_boards")).unwrap_or(true);
        let top_tags_limit = args
            .get("top_tags_limit")
            .and_then(Value::as_u64)
            .unwrap_or(30)
            .clamp(5, 80) as usize;

        let all_assets = self.engine.fetch_assets(&FilterCriteria::default())?;
        let trashed_assets = self.engine.fetch_assets(&FilterCriteria {
            only_trashed: true,
            ..Default::default()
        })?;
        let folders = self.engine.fetch_folders()?;
        let folder_paths = build_folder_paths(&folders);
        let folder_profiles = build_folder_profiles(&folders, &all_assets);
        let smart_folders = self.engine.fetch_smart_folders()?;
        let boards = self.engine.fetch_boards()?;
        let sync_cfg = self.engine.sync_config();
        let taxonomy = ExternalAgentStateStore::load_taxonomy(self.engine.database());

        let mut inbox_count = 0usize;
        let mut untagged_count = 0usize;
        let mut rated_count = 0usize;
        let mut ai_described_count = 0usize;
        let mut kind_counts: HashMap<String, usize> = HashMap::new();
        let mut aspect_counts: HashMap<String, usize> = HashMap::new();
        let mut global_tags: HashMap<String, usize> = HashMap::new();

        for a in &all_assets {
            if a.folder_id.is_none() {
                inbox_count += 1;
            }
            if a.tags.is_empty() {
                untagged_count += 1;
            }
            if a.rating > 0 {
                rated_count += 1;
            }
            if a.ai_description
                .as_deref()
                .is_some_and(|d| !d.trim().is_empty())
            {
                ai_described_count += 1;
            }
            *kind_counts
                .entry(a.media_kind.raw_value().to_string())
                .or_insert(0) += 1;
            *aspect_counts
                .entry(a.aspect_shape().raw_value().to_string())
                .or_insert(0) += 1;
            for tag in &a.tags {
                *global_tags.entry(tag.clone()).or_insert(0) += 1;
            }
        }

        let mut sorted_folders: Vec<&FolderRecord> = folders.iter().collect();
        sorted_folders.sort_by(|a, b| {
            let pa = folder_paths
                .get(&a.id)
                .map(String::as_str)
                .unwrap_or(&a.name);
            let pb = folder_paths
                .get(&b.id)
                .map(String::as_str)
                .unwrap_or(&b.name);
            pa.cmp(pb)
        });

        let folder_items: Vec<Value> = sorted_folders
            .into_iter()
            .map(|f| {
                let full_id = format_swift_uuid(&f.id);
                let mut entry = Map::new();
                entry.insert(
                    "id".into(),
                    json!(if compact { &full_id[..8] } else { &full_id }),
                );
                entry.insert(
                    "path".into(),
                    json!(folder_paths
                        .get(&f.id)
                        .cloned()
                        .unwrap_or_else(|| f.name.clone())),
                );
                if !compact {
                    entry.insert("name".into(), json!(f.name));
                    if let Some(pid) = f.parent_id {
                        entry.insert("parentID".into(), json!(format_swift_uuid(&pid)));
                    }
                }
                if let Some(profile) = folder_profiles.get(&f.id) {
                    entry.insert("assetCount".into(), json!(profile.direct_count));
                    if profile.recursive_count > profile.direct_count {
                        entry.insert("recursiveAssetCount".into(), json!(profile.recursive_count));
                    }
                    if include_profiles {
                        if !profile.top_tags.is_empty() {
                            entry.insert("topTags".into(), json!(profile.top_tags));
                        }
                        if !profile.palette.is_empty() {
                            entry.insert("palette".into(), json!(profile.palette));
                        }
                        if let Some(ref asp) = profile.dominant_aspect {
                            entry.insert("dominantAspect".into(), json!(asp));
                        }
                    }
                } else {
                    entry.insert("assetCount".into(), json!(f.asset_count));
                }
                if let Some(ref hex) = f.color_hex {
                    if !hex.is_empty() {
                        entry.insert("colorHex".into(), json!(hex));
                    }
                }
                if let Some(ref sym) = f.custom_symbol {
                    if !sym.is_empty() {
                        entry.insert("customSymbol".into(), json!(sym));
                    }
                }
                Value::Object(entry)
            })
            .collect();

        let smart_folder_items: Vec<Value> = smart_folders
            .iter()
            .map(|sf| {
                let full_id = format_swift_uuid(&sf.id);
                let match_count = all_assets.iter().filter(|a| sf.rule.matches(a)).count();
                let mut entry = Map::new();
                entry.insert(
                    "id".into(),
                    json!(if compact { &full_id[..8] } else { &full_id }),
                );
                entry.insert("name".into(), json!(sf.name));
                entry.insert("matchCount".into(), json!(match_count));
                if let Some(ref hex) = sf.color_hex {
                    if !hex.is_empty() {
                        entry.insert("colorHex".into(), json!(hex));
                    }
                }
                Value::Object(entry)
            })
            .collect();

        let mut tag_pairs: Vec<(String, usize)> = global_tags.into_iter().collect();
        tag_pairs.sort_by(|a, b| b.1.cmp(&a.1).then_with(|| a.0.cmp(&b.0)));
        let tag_items: Vec<Value> = tag_pairs
            .into_iter()
            .take(top_tags_limit)
            .map(|(name, count)| json!({ "name": name, "count": count }))
            .collect();

        let mut payload = Map::new();
        payload.insert("totalAssets".into(), json!(all_assets.len()));
        payload.insert("inboxCount".into(), json!(inbox_count));
        payload.insert("untaggedCount".into(), json!(untagged_count));
        payload.insert("trashedCount".into(), json!(trashed_assets.len()));
        payload.insert("ratedCount".into(), json!(rated_count));
        payload.insert("aiDescribedCount".into(), json!(ai_described_count));
        payload.insert("boardCount".into(), json!(boards.len()));
        payload.insert("transport".into(), json!(ctx.transport.as_str()));
        payload.insert("mcpEnabled".into(), json!(policy.mcp_enabled));
        payload.insert("httpMCPEnabled".into(), json!(policy.http_mcp_enabled));
        payload.insert("accessLevel".into(), json!(effective_access.as_str()));
        payload.insert(
            "canWriteInbox".into(),
            json!(effective_access.allows_inbox_and_enrich_writes()),
        );
        payload.insert(
            "canWriteGlobal".into(),
            json!(effective_access.allows_global_organize_writes()),
        );
        payload.insert(
            "syncMode".into(),
            serde_json::to_value(sync_cfg.mode).unwrap_or(json!("localOnly")),
        );
        payload.insert("mediaKindCounts".into(), json!(kind_counts));
        payload.insert("aspectShapeCounts".into(), json!(aspect_counts));
        payload.insert("folders".into(), json!(folder_items));
        payload.insert("smartFolders".into(), json!(smart_folder_items));
        payload.insert("topTags".into(), json!(tag_items));

        if !taxonomy.is_empty() {
            let mut tax_map = Map::new();
            tax_map.insert(
                "preferredTagLanguage".into(),
                json!(taxonomy.preferred_tag_language),
            );
            if !taxonomy.tag_aliases.is_empty() {
                tax_map.insert("tagAliases".into(), json!(taxonomy.tag_aliases));
            }
            if !taxonomy.folder_guidelines.is_empty() {
                tax_map.insert("folderGuidelines".into(), json!(taxonomy.folder_guidelines));
            }
            if !taxonomy.rating_meanings.is_empty() {
                tax_map.insert("ratingMeanings".into(), json!(taxonomy.rating_meanings));
            }
            if !taxonomy.notes.trim().is_empty() {
                tax_map.insert("notes".into(), json!(taxonomy.notes));
            }
            payload.insert("taxonomy".into(), Value::Object(tax_map));
        }

        if !compact {
            let cache = self.engine.cache_stats()?;
            payload.insert(
                "cache".into(),
                serde_json::to_value(cache).unwrap_or(json!({})),
            );
        }

        if include_boards && !boards.is_empty() {
            let board_items: Vec<Value> = boards
                .iter()
                .take(12)
                .map(|b| {
                    let full_id = format_swift_uuid(&b.id);
                    let mut entry = Map::new();
                    entry.insert(
                        "id".into(),
                        json!(if compact { &full_id[..8] } else { &full_id }),
                    );
                    entry.insert("title".into(), json!(b.title));
                    entry.insert("itemCount".into(), json!(b.item_count));
                    if !b.palette_hexes.is_empty() {
                        let pal: Vec<String> = b
                            .palette_hexes
                            .iter()
                            .take(4)
                            .map(|h| h.to_uppercase())
                            .collect();
                        entry.insert("paletteHexes".into(), json!(pal));
                    }
                    Value::Object(entry)
                })
                .collect();
            payload.insert("boards".into(), json!(board_items));
        }

        Ok(ToolOutput::json(Value::Object(payload)))
    }

    // =========================================================================
    // Tool 2: query_assets (6-in-1 Recall + Contact Sheet + Session + Suggestions)
    // =========================================================================

    fn apply_post_filters(
        &self,
        assets: Vec<AssetRecord>,
        args: &Value,
        extra_excluded: &HashSet<Uuid>,
    ) -> CoreResult<Vec<AssetRecord>> {
        let any_tags: HashSet<String> = string_array_arg(args.get("any_tags"))
            .into_iter()
            .map(|t| search_text::normalize(&t))
            .filter(|t| !t.is_empty())
            .collect();
        let exclude_tags: HashSet<String> = string_array_arg(args.get("exclude_tags"))
            .into_iter()
            .map(|t| search_text::normalize(&t))
            .filter(|t| !t.is_empty())
            .collect();
        let mut exclude_ids: HashSet<Uuid> = self
            .resolve_asset_uuid_list(args.get("exclude_asset_ids"))?
            .into_iter()
            .collect();
        exclude_ids.extend(extra_excluded.iter().copied());
        let tones = parse_visual_tones(args.get("tone"));

        if any_tags.is_empty()
            && exclude_tags.is_empty()
            && exclude_ids.is_empty()
            && tones.is_empty()
        {
            return Ok(assets);
        }

        Ok(assets
            .into_iter()
            .filter(|asset| {
                if exclude_ids.contains(&asset.id) {
                    return false;
                }
                if !any_tags.is_empty() || !exclude_tags.is_empty() {
                    let asset_tags: HashSet<String> = asset
                        .tags
                        .iter()
                        .chain(asset.suggested_tags.iter())
                        .map(|t| search_text::normalize(t))
                        .filter(|t| !t.is_empty())
                        .collect();
                    if !any_tags.is_empty() && asset_tags.is_disjoint(&any_tags) {
                        return false;
                    }
                    if !exclude_tags.is_empty() && !asset_tags.is_disjoint(&exclude_tags) {
                        return false;
                    }
                }
                tones.iter().all(|t| t.matches(asset))
            })
            .collect())
    }

    fn diversify_assets(&self, assets: &[AssetRecord], limit: usize) -> Vec<AssetRecord> {
        if assets.len() <= 1 || limit <= 1 {
            return assets.iter().take(limit).cloned().collect();
        }
        let probe_pool: Vec<AssetRecord> =
            assets.iter().take((limit * 6).max(96)).cloned().collect();
        let vectors = self.engine.vectors_map().unwrap_or_default();
        let descriptors = self
            .engine
            .visual_descriptors_for_assets(&probe_pool, &[], 120);

        let mut deduped: Vec<AssetRecord> = Vec::with_capacity(probe_pool.len().min(limit * 3));
        let mut selected_hashes: HashSet<String> = HashSet::new();
        for candidate in probe_pool {
            if !candidate.content_hash.is_empty()
                && selected_hashes.contains(&candidate.content_hash)
            {
                continue;
            }
            let is_near_dup = deduped.iter().any(|chosen| {
                LiveCharkleEngine::visual_pair_similarity(
                    &candidate,
                    chosen,
                    &vectors,
                    &descriptors,
                ) >= 0.78
            });
            if is_near_dup {
                continue;
            }
            if !candidate.content_hash.is_empty() {
                selected_hashes.insert(candidate.content_hash.clone());
            }
            deduped.push(candidate);
            if deduped.len() >= (limit * 3).max(48) {
                break;
            }
        }

        let mut folder_order: Vec<Option<Uuid>> = Vec::new();
        let mut buckets: HashMap<Option<Uuid>, Vec<AssetRecord>> = HashMap::new();
        for asset in deduped {
            if !buckets.contains_key(&asset.folder_id) {
                folder_order.push(asset.folder_id);
            }
            buckets.entry(asset.folder_id).or_default().push(asset);
        }
        if folder_order.len() < 2 {
            return folder_order
                .into_iter()
                .flat_map(|fid| buckets.remove(&fid).unwrap_or_default())
                .take(limit)
                .collect();
        }

        let mut selected = Vec::with_capacity(limit);
        let mut cursors: HashMap<Option<Uuid>, usize> = HashMap::new();
        let per_round = if folder_order.len() >= 4 { 1 } else { 2 };
        while selected.len() < limit {
            let mut progressed = false;
            for &fid in &folder_order {
                if selected.len() >= limit {
                    break;
                }
                let Some(list) = buckets.get(&fid) else {
                    continue;
                };
                let cur = cursors.get(&fid).copied().unwrap_or(0);
                let end = (cur + per_round).min(list.len());
                let mut idx = cur;
                while idx < end && selected.len() < limit {
                    selected.push(list[idx].clone());
                    idx += 1;
                    progressed = true;
                }
                cursors.insert(fid, idx);
            }
            if !progressed {
                break;
            }
        }
        selected
    }

    fn render_attached_contact_sheet(
        &self,
        assets: &[AssetRecord],
        max_width: u32,
        jpeg_quality: u8,
    ) -> CoreResult<Option<AttachedContactSheet>> {
        if assets.is_empty() {
            return Ok(None);
        }
        let sheet = render_contact_sheet_with_options(
            assets,
            self.engine.media(),
            ContactSheetOptions {
                columns: None,
                max_width: max_width.clamp(CONTACT_SHEET_MIN_WIDTH, CONTACT_SHEET_MAX_WIDTH),
                jpeg_quality,
            },
        )?;
        Ok(Some(AttachedContactSheet {
            slot_count: sheet.slots.len(),
            jpeg_bytes: sheet.jpeg_bytes,
            width: sheet.width,
            height: sheet.height,
        }))
    }

    #[allow(clippy::too_many_arguments)]
    fn run_multi_query_recall(
        &self,
        queries: &[String],
        criteria: &FilterCriteria,
        args: &Value,
        extra_excluded: &HashSet<Uuid>,
        seed_ids: &[Uuid],
        unlike_ids: &[Uuid],
        smart_folder: Option<&SmartFolderRecord>,
        limit: usize,
        diversify: bool,
    ) -> CoreResult<MultiQueryRecallResult> {
        let capped: Vec<&String> = queries.iter().take(6).collect();
        if capped.is_empty() {
            return Ok(MultiQueryRecallResult {
                hits: Vec::new(),
                groups_summary: Vec::new(),
                total_unique_matched: 0,
            });
        }
        let per_group_quota = ((limit as f64) / (capped.len() as f64)).ceil().max(1.0) as usize;
        let fetch_per_group = (per_group_quota * 3 + extra_excluded.len()).clamp(18, 120);

        let mut seen_ids: HashSet<Uuid> = HashSet::new();
        let mut all_unique: HashSet<Uuid> = HashSet::new();
        let mut merged: Vec<(LocalSemanticSearchHit, String)> = Vec::new();
        let mut groups_summary: Vec<Value> = Vec::new();

        for q in capped {
            let report = self.engine.semantic_search_local(
                q,
                criteria,
                fetch_per_group,
                seed_ids,
                unlike_ids,
            )?;
            let mut candidates: Vec<AssetRecord> =
                report.hits.iter().map(|h| h.asset.clone()).collect();
            if let Some(sf) = smart_folder {
                candidates.retain(|a| sf.rule.matches(a));
            }
            let post_filtered_ids: HashSet<Uuid> = self
                .apply_post_filters(candidates, args, extra_excluded)?
                .into_iter()
                .map(|a| a.id)
                .collect();
            let mut group_hits: Vec<LocalSemanticSearchHit> = report
                .hits
                .into_iter()
                .filter(|h| post_filtered_ids.contains(&h.asset.id))
                .collect();
            for h in &group_hits {
                all_unique.insert(h.asset.id);
            }
            group_hits.retain(|h| !seen_ids.contains(&h.asset.id));

            let chosen: Vec<LocalSemanticSearchHit> = if diversify && group_hits.len() > 1 {
                let div_assets = self.diversify_assets(
                    &group_hits
                        .iter()
                        .map(|h| h.asset.clone())
                        .collect::<Vec<_>>(),
                    per_group_quota,
                );
                let mut by_id: HashMap<Uuid, LocalSemanticSearchHit> =
                    group_hits.into_iter().map(|h| (h.asset.id, h)).collect();
                div_assets
                    .into_iter()
                    .filter_map(|a| by_id.remove(&a.id))
                    .collect()
            } else {
                group_hits.into_iter().take(per_group_quota).collect()
            };

            let start_slot = merged.len() + 1;
            let mut badges: Vec<String> = Vec::new();
            for h in chosen {
                if merged.len() >= limit {
                    break;
                }
                if seen_ids.insert(h.asset.id) {
                    merged.push((h, q.clone()));
                    badges.push(format!("#{:02}", merged.len()));
                }
            }

            let mut summary = Map::new();
            summary.insert("query".into(), json!(q));
            summary.insert("count".into(), json!(badges.len()));
            if !badges.is_empty() {
                let range = if badges.len() == 1 {
                    badges[0].clone()
                } else {
                    format!(
                        "#{:02}..{}",
                        start_slot,
                        badges.last().unwrap_or(&badges[0])
                    )
                };
                summary.insert("slotRange".into(), json!(range));
            }
            groups_summary.push(Value::Object(summary));
        }

        Ok(MultiQueryRecallResult {
            hits: merged,
            groups_summary,
            total_unique_matched: all_unique.len(),
        })
    }

    fn compute_relaxation_hints(
        &self,
        args: &Value,
        folders: &[FolderRecord],
        folder_paths: &HashMap<Uuid, String>,
    ) -> Vec<String> {
        let mut hints = Vec::new();
        if args.get("tone").is_some() {
            hints.push("Try removing `tone` or using a broader palette filter.".to_string());
        }
        if args.get("color_hex").is_some() {
            hints.push(
                "Try increasing `color_tolerance` (e.g. 38) or omitting `color_hex`.".to_string(),
            );
        }
        if args.get("folder_id").is_some() || args.get("folder_path").is_some() {
            if let Ok(Some(fid)) = self.resolve_optional_folder_id(args, folders, folder_paths) {
                let path = folder_paths
                    .get(&fid)
                    .map(String::as_str)
                    .unwrap_or("folder");
                hints.push(format!(
                    "Try broadening beyond folder `{path}` by omitting `folder_path`/`folder_id`."
                ));
            }
        }
        if !string_array_arg(args.get("tags")).is_empty() {
            hints.push("Try `any_tags` instead of requiring all `tags`, or inspect `library_overview` canonical `topTags`.".to_string());
        }
        if args
            .get("session_id")
            .and_then(Value::as_str)
            .is_some_and(|s| !s.trim().is_empty())
        {
            hints.push("Pass `reset_session: true` if all matching items were already seen in this session.".to_string());
        }
        hints
    }

    fn handle_query_assets(
        &self,
        args: &Value,
        _ctx: &ExternalAgentRequestContext,
    ) -> CoreResult<ToolOutput> {
        let want_sheet = bool_arg(args.get("contact_sheet")).unwrap_or(false);
        let want_folder_suggestions =
            bool_arg(args.get("include_folder_suggestions")).unwrap_or(false);
        let diversify = bool_arg(args.get("diversify")).unwrap_or(false);
        let offset = args.get("offset").and_then(Value::as_u64).unwrap_or(0) as usize;
        let default_limit = if want_sheet { 16 } else { 20 };
        let limit = args
            .get("limit")
            .and_then(Value::as_u64)
            .unwrap_or(default_limit)
            .clamp(1, 100) as usize;
        let default_detail = if want_sheet {
            AssetDetailLevel::Visual
        } else {
            AssetDetailLevel::Compact
        };
        let detail = AssetDetailLevel::parse(args.get("detail"), default_detail);

        let query = args
            .get("query")
            .and_then(Value::as_str)
            .map(str::trim)
            .unwrap_or("");
        let sub_queries = string_array_arg(args.get("queries"));
        let explicit_asset_ids = self.resolve_asset_uuid_list(args.get("asset_ids"))?;
        let seed_ids = self.resolve_asset_uuid_list(args.get("seed_asset_ids"))?;
        let unlike_ids = self.resolve_asset_uuid_list(args.get("unlike_asset_ids"))?;

        let session_id_raw = args
            .get("session_id")
            .and_then(Value::as_str)
            .map(str::trim)
            .unwrap_or("");
        let reset_session = bool_arg(args.get("reset_session")).unwrap_or(false);
        let mut session_excluded: HashSet<Uuid> = HashSet::new();
        if !session_id_raw.is_empty() && !reset_session && explicit_asset_ids.is_empty() {
            let loaded =
                ExternalAgentStateStore::load_session(self.engine.database(), session_id_raw);
            session_excluded.extend(loaded.seen_asset_ids);
        }

        let folders = self.engine.fetch_folders()?;
        let folder_paths = build_folder_paths(&folders);
        let smart_folder = self.resolve_optional_smart_folder(args)?;

        let mut selected_assets: Vec<AssetRecord> = Vec::new();
        let total_matched: usize;
        let all_matched_for_facets: Vec<AssetRecord>;
        let mut score_by_id: HashMap<Uuid, f64> = HashMap::new();
        let mut reason_by_id: HashMap<Uuid, String> = HashMap::new();
        let mut query_group_by_id: HashMap<Uuid, String> = HashMap::new();
        let mut multi_query_groups: Vec<Value> = Vec::new();
        let mode_label: &str;

        if !explicit_asset_ids.is_empty() {
            mode_label = "explicit_ids";
            let mut resolved = Vec::new();
            for uuid in &explicit_asset_ids {
                if let Some(asset) = self.engine.fetch_asset(*uuid)? {
                    resolved.push(asset);
                }
            }
            resolved = self.apply_post_filters(resolved, args, &HashSet::new())?;
            total_matched = resolved.len();
            all_matched_for_facets = resolved.clone();
            selected_assets = if diversify && offset == 0 {
                self.diversify_assets(&resolved, limit)
            } else {
                paginate_slice(&resolved, offset, limit)
            };
        } else if sub_queries.len() >= 2 {
            mode_label = "multi_query";
            let mut criteria = self.build_filter_criteria(args, &folders, &folder_paths)?;
            criteria.search_query.clear();
            let multi = self.run_multi_query_recall(
                &sub_queries,
                &criteria,
                args,
                &session_excluded,
                &seed_ids,
                &unlike_ids,
                smart_folder.as_ref(),
                limit,
                diversify,
            )?;
            for (hit, qg) in multi.hits {
                score_by_id.insert(hit.asset.id, hit.score);
                reason_by_id.insert(hit.asset.id, hit.reason);
                query_group_by_id.insert(hit.asset.id, qg);
                selected_assets.push(hit.asset);
            }
            total_matched = multi.total_unique_matched;
            all_matched_for_facets = selected_assets.clone();
            multi_query_groups = multi.groups_summary;
        } else if (!query.is_empty() || !sub_queries.is_empty() || !seed_ids.is_empty())
            && !bool_arg(args.get("only_trashed")).unwrap_or(false)
        {
            mode_label = if seed_ids.is_empty() {
                "semantic"
            } else {
                "visual_steering"
            };
            let effective_query = if !query.is_empty() {
                query
            } else {
                sub_queries.first().map(String::as_str).unwrap_or("")
            };
            let mut criteria = self.build_filter_criteria(args, &folders, &folder_paths)?;
            criteria.search_query.clear();
            let fetch_limit = ((if diversify { limit * 3 } else { limit })
                + session_excluded.len())
            .clamp(36, 120);

            if effective_query.is_empty()
                && seed_ids.len() == 1
                && criteria.folder_id.is_none()
                && !criteria.only_inbox
                && criteria.tags.is_empty()
                && smart_folder.is_none()
            {
                let mut sim_matches = self.engine.similar_assets(seed_ids[0], fetch_limit)?;
                let unlike_set: HashSet<Uuid> = unlike_ids.iter().copied().collect();
                sim_matches.retain(|m| {
                    !session_excluded.contains(&m.asset.id) && !unlike_set.contains(&m.asset.id)
                });
                let post_ids: HashSet<Uuid> = self
                    .apply_post_filters(
                        sim_matches.iter().map(|m| m.asset.clone()).collect(),
                        args,
                        &session_excluded,
                    )?
                    .into_iter()
                    .map(|a| a.id)
                    .collect();
                let filtered: Vec<_> = sim_matches
                    .into_iter()
                    .filter(|m| post_ids.contains(&m.asset.id))
                    .collect();
                total_matched = filtered.len();
                all_matched_for_facets = filtered.iter().map(|m| m.asset.clone()).collect();
                let chosen: Vec<_> = if diversify && filtered.len() > 1 && offset == 0 {
                    let div = self.diversify_assets(&all_matched_for_facets, limit);
                    let mut by_id: HashMap<Uuid, _> =
                        filtered.into_iter().map(|m| (m.asset.id, m)).collect();
                    div.into_iter()
                        .filter_map(|a| by_id.remove(&a.id))
                        .collect()
                } else {
                    filtered.into_iter().skip(offset).take(limit).collect()
                };
                for item in chosen {
                    score_by_id.insert(item.asset.id, item.score);
                    if let Some(first_reason) = item.match_reasons.first() {
                        reason_by_id.insert(item.asset.id, first_reason.clone());
                    }
                    selected_assets.push(item.asset);
                }
            } else {
                let report = self.engine.semantic_search_local(
                    effective_query,
                    &criteria,
                    fetch_limit,
                    &seed_ids,
                    &unlike_ids,
                )?;
                let mut candidate_hits = report.hits;
                if let Some(ref sf) = smart_folder {
                    candidate_hits.retain(|h| sf.rule.matches(&h.asset));
                }
                let post_ids: HashSet<Uuid> = self
                    .apply_post_filters(
                        candidate_hits.iter().map(|h| h.asset.clone()).collect(),
                        args,
                        &session_excluded,
                    )?
                    .into_iter()
                    .map(|a| a.id)
                    .collect();
                let filtered: Vec<LocalSemanticSearchHit> = candidate_hits
                    .into_iter()
                    .filter(|h| post_ids.contains(&h.asset.id))
                    .collect();
                total_matched = filtered.len();
                all_matched_for_facets = filtered.iter().map(|h| h.asset.clone()).collect();
                let chosen: Vec<LocalSemanticSearchHit> =
                    if diversify && filtered.len() > 1 && offset == 0 {
                        let div = self.diversify_assets(&all_matched_for_facets, limit);
                        let mut by_id: HashMap<Uuid, LocalSemanticSearchHit> =
                            filtered.into_iter().map(|h| (h.asset.id, h)).collect();
                        div.into_iter()
                            .filter_map(|a| by_id.remove(&a.id))
                            .collect()
                    } else {
                        filtered.into_iter().skip(offset).take(limit).collect()
                    };
                for hit in chosen {
                    score_by_id.insert(hit.asset.id, hit.score);
                    reason_by_id.insert(hit.asset.id, hit.reason);
                    selected_assets.push(hit.asset);
                }
            }
        } else {
            mode_label = if bool_arg(args.get("only_inbox")).unwrap_or(false) {
                "inbox"
            } else {
                "filter"
            };
            let criteria = self.build_filter_criteria(args, &folders, &folder_paths)?;
            let mut matches = self.engine.fetch_assets(&criteria)?;
            if let Some(ref sf) = smart_folder {
                matches.retain(|a| sf.rule.matches(a));
            }
            matches = self.apply_post_filters(matches, args, &session_excluded)?;
            total_matched = matches.len();
            all_matched_for_facets = matches.clone();
            selected_assets = if diversify && offset == 0 {
                self.diversify_assets(&matches, limit)
            } else {
                paginate_slice(&matches, offset, limit)
            };
        }

        // Optional 1-call folder recommendations (great for Inbox triage)
        let suggestions_by_id: HashMap<Uuid, crate::models::core::FolderSuggestion> =
            if want_folder_suggestions && !selected_assets.is_empty() {
                let slice_len = selected_assets.len().min(20);
                self.engine
                    .suggest_folders_for_assets(&selected_assets[..slice_len])
                    .unwrap_or_default()
                    .into_iter()
                    .filter_map(|(id, sug)| sug.map(|s| (id, s)))
                    .collect()
            } else {
                HashMap::new()
            };

        let mut serialized_assets: Vec<Value> = selected_assets
            .iter()
            .enumerate()
            .map(|(idx, asset)| {
                let mut dict = serialize_asset_summary(asset, &folder_paths, detail);
                if let Some(obj) = dict.as_object_mut() {
                    if let Some(&score) = score_by_id.get(&asset.id) {
                        obj.insert("rank".into(), json!(idx + 1));
                        obj.insert("score".into(), json!((score * 1000.0).round() / 1000.0));
                    }
                    if detail != AssetDetailLevel::Visual {
                        if let Some(reason) = reason_by_id.get(&asset.id) {
                            if !reason.is_empty() {
                                obj.insert("reason".into(), json!(reason));
                            }
                        }
                    }
                    if let Some(qg) = query_group_by_id.get(&asset.id) {
                        obj.insert("queryGroup".into(), json!(qg));
                    }
                    if let Some(sug) = suggestions_by_id.get(&asset.id) {
                        let fid_str = format_swift_uuid(&sug.folder_id);
                        obj.insert(
                            "suggestedFolder".into(),
                            json!({
                                "id": &fid_str[..8],
                                "path": folder_paths.get(&sug.folder_id).cloned().unwrap_or_else(|| sug.folder_name.clone()),
                                "confidence": (sug.confidence * 1000.0).round() / 1000.0,
                                "reason": sug.reason
                            }),
                        );
                    }
                }
                dict
            })
            .collect();

        let has_more = offset + serialized_assets.len() < total_matched;
        let mut payload = Map::new();
        payload.insert("mode".into(), json!(mode_label));
        payload.insert("totalMatched".into(), json!(total_matched));
        payload.insert("offset".into(), json!(offset));
        payload.insert("returned".into(), json!(serialized_assets.len()));
        payload.insert("hasMore".into(), json!(has_more));
        if has_more {
            payload.insert("nextOffset".into(), json!(offset + serialized_assets.len()));
        }
        if diversify {
            payload.insert("diversified".into(), json!(true));
        }
        if !multi_query_groups.is_empty() {
            payload.insert("queryGroups".into(), json!(multi_query_groups));
        }
        if let Some(ref sf) = smart_folder {
            let sf_id = format_swift_uuid(&sf.id);
            payload.insert(
                "smartFolder".into(),
                json!({ "id": &sf_id[..8], "name": sf.name }),
            );
        }

        if !session_id_raw.is_empty() {
            let seen_ids: Vec<Uuid> = selected_assets.iter().map(|a| a.id).collect();
            let updated_session = ExternalAgentStateStore::record_seen_assets(
                self.engine.database(),
                session_id_raw,
                &seen_ids,
                reset_session,
            );
            payload.insert(
                "session".into(),
                json!({
                    "id": updated_session.id,
                    "seenTotal": updated_session.seen_asset_ids.len(),
                    "skippedSeenCount": session_excluded.len()
                }),
            );
        }

        let include_facets = bool_arg(args.get("include_facets")).unwrap_or(total_matched > limit);
        if include_facets && !all_matched_for_facets.is_empty() {
            payload.insert(
                "facets".into(),
                compute_result_facets(&all_matched_for_facets, &folder_paths),
            );
        }

        if total_matched == 0 {
            let hints = self.compute_relaxation_hints(args, &folders, &folder_paths);
            if !hints.is_empty() {
                payload.insert("relaxationHints".into(), json!(hints));
            }
        }

        if want_sheet && !selected_assets.is_empty() {
            let max_width = args
                .get("sheet_max_width")
                .or_else(|| args.get("max_width"))
                .and_then(Value::as_u64)
                .unwrap_or(CONTACT_SHEET_DEFAULT_WIDTH as u64) as u32;
            let capped_sheet: Vec<AssetRecord> = selected_assets
                .iter()
                .take(CONTACT_SHEET_MAX_ASSETS)
                .cloned()
                .collect();
            if let Some(attached) =
                self.render_attached_contact_sheet(&capped_sheet, max_width, 74)?
            {
                for (idx, item) in serialized_assets
                    .iter_mut()
                    .take(attached.slot_count)
                    .enumerate()
                {
                    if let Some(obj) = item.as_object_mut() {
                        obj.insert("slot".into(), json!(idx + 1));
                        obj.insert("badge".into(), json!(format!("#{:02}", idx + 1)));
                    }
                }
                payload.insert("contactSheet".into(), attached.summary());
                payload.insert("assets".into(), json!(serialized_assets));
                return Ok(ToolOutput {
                    content: vec![
                        ToolContent::Image {
                            mime_type: "image/jpeg".to_string(),
                            data: attached.jpeg_bytes,
                        },
                        ToolContent::Text(
                            serde_json::to_string(&Value::Object(payload)).unwrap_or_default(),
                        ),
                    ],
                    is_error: false,
                });
            }
        }

        payload.insert("assets".into(), json!(serialized_assets));
        Ok(ToolOutput::json(Value::Object(payload)))
    }

    // =========================================================================
    // Tool 3: inspect_assets (Finalist Hydration + Crop Zoom + Download URL)
    // =========================================================================

    fn serialize_asset_detail(
        &self,
        asset: &AssetRecord,
        folder_paths: &HashMap<Uuid, String>,
        ctx: &ExternalAgentRequestContext,
        include_download_url: bool,
    ) -> Value {
        let mut obj = serialize_asset_summary(asset, folder_paths, AssetDetailLevel::Standard);
        if let Some(map) = obj.as_object_mut() {
            if let Some(ref ocr) = asset.ocr_text {
                if !ocr.trim().is_empty() && ocr.trim() != asset.notes.trim() {
                    map.insert("ocrText".into(), json!(ocr));
                }
            }
            if let Some(ref desc) = asset.ai_description {
                if !desc.trim().is_empty() {
                    map.insert("aiDescription".into(), json!(desc));
                }
            }
            if !asset.suggested_tags.is_empty() {
                map.insert("suggestedTags".into(), json!(asset.suggested_tags));
            }
            if let Some(ref domain) = asset.source_domain {
                if !domain.is_empty() {
                    map.insert("sourceDomain".into(), json!(domain));
                }
            }
            map.insert("pinnedOffline".into(), json!(asset.pinned_offline));
            map.insert("fileSizeBytes".into(), json!(asset.file_size_bytes));
            map.insert("pixelWidth".into(), json!(asset.pixel_width));
            map.insert("pixelHeight".into(), json!(asset.pixel_height));
            if let Some(ref rich) = asset.rich_metadata {
                map.insert("richMetadata".into(), json!(rich));
            }
            // Security invariant: hide server local filesystem paths on HTTP MCP transport.
            if !ctx.is_remote_http() {
                let thumb_path = self
                    .engine
                    .media()
                    .thumbnail_url(asset.id, ThumbnailTier::Preview1400)
                    .or_else(|| {
                        self.engine
                            .media()
                            .thumbnail_url(asset.id, ThumbnailTier::Grid520)
                    });
                if let Some(ref tp) = thumb_path {
                    map.insert("thumbnailPath".into(), json!(tp.display().to_string()));
                }
                if let Some(orig) = self.engine.media().cached_original(asset) {
                    map.insert(
                        "localOriginalPath".into(),
                        json!(orig.display().to_string()),
                    );
                }
            }
            if include_download_url {
                if let Some(ref issuer) = ctx.issue_download_url {
                    if let Some(url) = issuer(asset.id) {
                        map.insert("downloadURL".into(), json!(url));
                    }
                }
            }
        }
        obj
    }

    fn prepared_inspection_jpeg(
        &self,
        asset: &AssetRecord,
        max_side: u32,
        crop_box: Option<NormalizedCropBox>,
    ) -> Option<Vec<u8>> {
        // When cropping, prefer full original image if cached, else preview1400, else grid520.
        let source_path = if crop_box.is_some() {
            self.engine
                .media()
                .cached_original(asset)
                .filter(|_| {
                    matches!(
                        asset.media_kind,
                        MediaKind::Image | MediaKind::AnimatedImage
                    )
                })
                .or_else(|| {
                    self.engine
                        .media()
                        .thumbnail_url(asset.id, ThumbnailTier::Preview1400)
                })
                .or_else(|| {
                    self.engine
                        .media()
                        .thumbnail_url(asset.id, ThumbnailTier::Grid520)
                })
        } else {
            self.engine
                .media()
                .thumbnail_url(asset.id, ThumbnailTier::Preview1400)
                .or_else(|| {
                    self.engine
                        .media()
                        .thumbnail_url(asset.id, ThumbnailTier::Grid520)
                })
                .or_else(|| self.engine.media().cached_original(asset))
        }?;

        let raw_bytes = std::fs::read(&source_path).ok()?;
        let Ok(mut img) = image::load_from_memory(&raw_bytes) else {
            return if crop_box.is_none() {
                Some(raw_bytes)
            } else {
                None
            };
        };

        if let Some(cb) = crop_box {
            let iw = img.width().max(1);
            let ih = img.height().max(1);
            let px = ((cb.x * f64::from(iw)).floor() as u32).min(iw - 1);
            let py = ((cb.y * f64::from(ih)).floor() as u32).min(ih - 1);
            let pw = ((cb.width * f64::from(iw)).round() as u32)
                .max(1)
                .min(iw - px);
            let ph = ((cb.height * f64::from(ih)).round() as u32)
                .max(1)
                .min(ih - py);
            img = img.crop_imm(px, py, pw, ph);
        }

        let target = max_side.clamp(280, 1568);
        if img.width().max(img.height()) > target {
            img = img.thumbnail(target, target);
        }

        let rgb = img.to_rgb8();
        let mut out = Vec::new();
        let mut enc = JpegEncoder::new_with_quality(&mut out, 84);
        enc.encode(
            rgb.as_raw(),
            rgb.width(),
            rgb.height(),
            image::ExtendedColorType::Rgb8,
        )
        .ok()?;
        Some(out)
    }

    fn handle_inspect_assets(
        &self,
        args: &Value,
        ctx: &ExternalAgentRequestContext,
    ) -> CoreResult<ToolOutput> {
        let include_image = bool_arg(args.get("include_image")).unwrap_or(false);
        let include_download_url = bool_arg(args.get("include_download_url")).unwrap_or(false);
        let max_side = args
            .get("image_max_side")
            .and_then(Value::as_u64)
            .unwrap_or(768)
            .clamp(280, 1568) as u32;
        let crop_box = parse_crop_box(args.get("crop_box"));

        // Batch finalist inspection: 1..=12 UUIDs or 8+ char prefixes
        let raw_batch = string_array_arg(args.get("asset_ids"));
        if !raw_batch.is_empty() {
            let resolved_batch = self.resolve_asset_uuid_list(args.get("asset_ids"))?;
            let mut unique: Vec<Uuid> = Vec::new();
            let mut seen = HashSet::new();
            for uuid in resolved_batch {
                if seen.insert(uuid) {
                    unique.push(uuid);
                }
            }
            unique.truncate(12);
            if unique.is_empty() {
                return Ok(ToolOutput::error(
                    "`asset_ids` contained no valid asset UUIDs or prefixes.",
                ));
            }

            let folders = self.engine.fetch_folders()?;
            let folder_paths = build_folder_paths(&folders);
            let mut resolved_assets = Vec::new();
            let mut serialized = Vec::new();
            let mut missing_ids = Vec::new();

            for uuid in &unique {
                let _ = self.engine.hydrate_image_metadata(*uuid);
                match self.engine.fetch_asset(*uuid)? {
                    Some(asset) => {
                        serialized.push(self.serialize_asset_detail(
                            &asset,
                            &folder_paths,
                            ctx,
                            include_download_url,
                        ));
                        resolved_assets.push(asset);
                    }
                    None => missing_ids.push(format_swift_uuid(uuid)),
                }
            }

            let mut payload = Map::new();
            payload.insert("requestedCount".into(), json!(unique.len()));
            payload.insert("returned".into(), json!(serialized.len()));
            if !missing_ids.is_empty() {
                payload.insert("missingIDs".into(), json!(missing_ids));
            }

            if include_image && !resolved_assets.is_empty() {
                if resolved_assets.len() == 1 {
                    if let Some(jpeg) =
                        self.prepared_inspection_jpeg(&resolved_assets[0], max_side, crop_box)
                    {
                        payload.insert("assets".into(), json!(serialized));
                        return Ok(ToolOutput {
                            content: vec![
                                ToolContent::Image {
                                    mime_type: "image/jpeg".to_string(),
                                    data: jpeg,
                                },
                                ToolContent::Text(
                                    serde_json::to_string(&Value::Object(payload))
                                        .unwrap_or_default(),
                                ),
                            ],
                            is_error: false,
                        });
                    }
                } else {
                    let sheet_width = max_side.clamp(960, 1600);
                    if let Some(attached) =
                        self.render_attached_contact_sheet(&resolved_assets, sheet_width, 82)?
                    {
                        for (idx, item) in
                            serialized.iter_mut().take(attached.slot_count).enumerate()
                        {
                            if let Some(obj) = item.as_object_mut() {
                                obj.insert("slot".into(), json!(idx + 1));
                                obj.insert("badge".into(), json!(format!("#{:02}", idx + 1)));
                            }
                        }
                        payload.insert("contactSheet".into(), attached.summary());
                        payload.insert("assets".into(), json!(serialized));
                        return Ok(ToolOutput {
                            content: vec![
                                ToolContent::Image {
                                    mime_type: "image/jpeg".to_string(),
                                    data: attached.jpeg_bytes,
                                },
                                ToolContent::Text(
                                    serde_json::to_string(&Value::Object(payload))
                                        .unwrap_or_default(),
                                ),
                            ],
                            is_error: false,
                        });
                    }
                }
            }

            payload.insert("assets".into(), json!(serialized));
            return Ok(ToolOutput::json(Value::Object(payload)));
        }

        // Single asset mode
        let Some(raw_id) = args
            .get("asset_id")
            .or_else(|| args.get("id"))
            .and_then(Value::as_str)
            .map(str::trim)
            .filter(|s| !s.is_empty())
        else {
            return Ok(ToolOutput::error(
                "Missing or invalid UUID / 8-char prefix for `asset_id` (or pass `asset_ids` array).",
            ));
        };
        let uuid = self.resolve_asset_uuid(raw_id)?;
        let _ = self.engine.hydrate_image_metadata(uuid);
        let Some(asset) = self.engine.fetch_asset(uuid)? else {
            return Ok(ToolOutput::error(format!(
                "Asset not found: {}",
                format_swift_uuid(&uuid)
            )));
        };

        let folders = self.engine.fetch_folders()?;
        let folder_paths = build_folder_paths(&folders);
        let mut dict =
            self.serialize_asset_detail(&asset, &folder_paths, ctx, include_download_url);
        if let (Some(cb), Some(map)) = (crop_box, dict.as_object_mut()) {
            map.insert(
                "appliedCropBox".into(),
                json!({
                    "x": (cb.x * 1000.0).round() / 1000.0,
                    "y": (cb.y * 1000.0).round() / 1000.0,
                    "width": (cb.width * 1000.0).round() / 1000.0,
                    "height": (cb.height * 1000.0).round() / 1000.0
                }),
            );
        }

        if include_image {
            if let Some(jpeg) = self.prepared_inspection_jpeg(&asset, max_side, crop_box) {
                return Ok(ToolOutput {
                    content: vec![
                        ToolContent::Image {
                            mime_type: "image/jpeg".to_string(),
                            data: jpeg,
                        },
                        ToolContent::Text(serde_json::to_string(&dict).unwrap_or_default()),
                    ],
                    is_error: false,
                });
            }
        }
        Ok(ToolOutput::json(dict))
    }

    // =========================================================================
    // Tool 4: get_board (List All Boards OR Read Context + Optional Inline PNG)
    // =========================================================================

    fn handle_get_board(
        &self,
        args: &Value,
        ctx: &ExternalAgentRequestContext,
    ) -> CoreResult<ToolOutput> {
        let raw_board_id = args
            .get("board_id")
            .or_else(|| args.get("id"))
            .and_then(Value::as_str)
            .map(str::trim)
            .unwrap_or("");
        let raw_title = args
            .get("title")
            .and_then(Value::as_str)
            .map(str::trim)
            .unwrap_or("");

        // List all boards when no selector is provided
        if raw_board_id.is_empty() && raw_title.is_empty() {
            let boards = self.engine.fetch_boards()?;
            let items: Vec<Value> = boards
                .iter()
                .map(|b| {
                    let full_id = format_swift_uuid(&b.id);
                    json!({
                        "id": full_id,
                        "shortID": &full_id[..8],
                        "title": b.title,
                        "subtitle": b.subtitle,
                        "mode": if b.mode.is_auto_editorial() { "autoEditorial" } else { "freeform" },
                        "itemCount": b.item_count,
                        "paletteHexes": b.palette_hexes.iter().map(|h| h.to_uppercase()).collect::<Vec<_>>(),
                        "pinnedOffline": b.pinned_offline,
                        "updatedAt": b.updated_at.to_rfc3339()
                    })
                })
                .collect();
            return Ok(ToolOutput::json(json!({
                "count": items.len(),
                "boards": items
            })));
        }

        let Some(doc) = self.resolve_board(args)? else {
            let existing = self.engine.fetch_boards().unwrap_or_default();
            let titles: Vec<String> = existing
                .iter()
                .take(5)
                .map(|b| format!("\"{}\" ({})", b.title, &format_swift_uuid(&b.id)[..8]))
                .collect();
            let hint = if titles.is_empty() {
                "No moodboards exist yet.".to_string()
            } else {
                format!("Available boards: [{}].", titles.join(", "))
            };
            return Ok(ToolOutput::error(format!("Moodboard not found. {hint}")));
        };

        let detail = AssetDetailLevel::parse(args.get("detail"), AssetDetailLevel::Compact);
        let include_snapshot = bool_arg(args.get("include_snapshot")).unwrap_or(false);
        let folders = self.engine.fetch_folders()?;
        let folder_paths = build_folder_paths(&folders);

        let mut assets_by_id: HashMap<Uuid, AssetRecord> = HashMap::new();
        let mut needed_ids: HashSet<Uuid> = doc.referenced_asset_ids().into_iter().collect();
        needed_ids.extend(doc.candidate_asset_ids.iter().copied());
        for aid in needed_ids {
            if let Ok(Some(asset)) = self.engine.fetch_asset(aid) {
                assets_by_id.insert(aid, asset);
            }
        }

        let mut notes = Vec::new();
        let mut sections = Vec::new();
        let mut card_refs = Vec::new();

        let mut ordered_nodes = doc.nodes.clone();
        ordered_nodes.sort_by_key(|n| n.editorial_order);

        for n in &ordered_nodes {
            let frame_json = json!({
                "x": n.frame.x.round(),
                "y": n.frame.y.round(),
                "width": n.frame.width.round(),
                "height": n.frame.height.round()
            });
            match &n.kind {
                BoardNodeKind::Note {
                    title, text, style, ..
                } => {
                    let mut item = Map::new();
                    item.insert("nodeID".into(), json!(format_swift_uuid(&n.id)));
                    item.insert("text".into(), json!(text));
                    item.insert(
                        "style".into(),
                        serde_json::to_value(style).unwrap_or(json!("paper")),
                    );
                    item.insert("frame".into(), frame_json);
                    if let Some(t) = title.as_deref().filter(|s| !s.is_empty()) {
                        item.insert("title".into(), json!(t));
                    }
                    if n.is_locked {
                        item.insert("isLocked".into(), json!(true));
                    }
                    notes.push(Value::Object(item));
                }
                BoardNodeKind::GroupFrame { title, tint } => {
                    let mut item = Map::new();
                    item.insert("nodeID".into(), json!(format_swift_uuid(&n.id)));
                    item.insert("title".into(), json!(title));
                    item.insert(
                        "tint".into(),
                        serde_json::to_value(tint).unwrap_or(json!("neutral")),
                    );
                    item.insert("frame".into(), frame_json);
                    if n.is_locked {
                        item.insert("isLocked".into(), json!(true));
                    }
                    sections.push(Value::Object(item));
                }
                BoardNodeKind::AssetRef {
                    asset_id,
                    crop,
                    weight,
                    ..
                } => {
                    if let Some(asset) = assets_by_id.get(asset_id) {
                        let mut summary = serialize_asset_summary(asset, &folder_paths, detail);
                        if let Some(obj) = summary.as_object_mut() {
                            obj.insert("nodeID".into(), json!(format_swift_uuid(&n.id)));
                            obj.insert("weight".into(), json!(weight));
                            if *weight >= 2 {
                                obj.insert("isHero".into(), json!(true));
                            }
                            if n.is_locked {
                                obj.insert("isLocked".into(), json!(true));
                            }
                            obj.insert("frame".into(), frame_json);
                            if let Some(c) = crop {
                                obj.insert(
                                    "crop".into(),
                                    json!({
                                        "x": (c.x * 1000.0).round() / 1000.0,
                                        "y": (c.y * 1000.0).round() / 1000.0,
                                        "width": (c.width.max(0.0) * 1000.0).round() / 1000.0,
                                        "height": (c.height.max(0.0) * 1000.0).round() / 1000.0
                                    }),
                                );
                            }
                            if !ctx.is_remote_http() && detail != AssetDetailLevel::Compact {
                                if let Some(orig) = self.engine.media().cached_original(asset) {
                                    obj.insert(
                                        "localOriginalPath".into(),
                                        json!(orig.display().to_string()),
                                    );
                                }
                            }
                        }
                        card_refs.push(summary);
                    }
                }
                BoardNodeKind::PaletteStrip { .. } => {}
            }
        }

        let connectors: Vec<Value> = doc
            .connectors
            .iter()
            .map(|c| {
                let mut item = Map::new();
                item.insert("id".into(), json!(format_swift_uuid(&c.id)));
                item.insert(
                    "fromNodeID".into(),
                    json!(format_swift_uuid(&c.from_node_id)),
                );
                item.insert("toNodeID".into(), json!(format_swift_uuid(&c.to_node_id)));
                item.insert(
                    "style".into(),
                    serde_json::to_value(c.style).unwrap_or(json!("curved")),
                );
                item.insert("colorHex".into(), json!(c.color_hex.to_uppercase()));
                if let Some(ref lbl) = c.label {
                    if !lbl.is_empty() {
                        item.insert("label".into(), json!(lbl));
                    }
                }
                if c.dashed {
                    item.insert("dashed".into(), json!(true));
                }
                Value::Object(item)
            })
            .collect();

        let candidates: Vec<Value> = doc
            .candidate_asset_ids
            .iter()
            .filter_map(|cid| {
                let asset = assets_by_id.get(cid)?;
                Some(json!({
                    "id": format_swift_uuid(&asset.id),
                    "title": asset.title,
                    "folderPath": asset.folder_id.and_then(|id| folder_paths.get(&id).cloned()).unwrap_or_else(|| "Inbox".to_string())
                }))
            })
            .collect();

        let palette: Vec<Value> = doc
            .extracted_palette
            .iter()
            .map(|c| {
                json!({
                    "hex": c.hex.to_uppercase(),
                    "proportion": (c.proportion * 1000.0).round() / 1000.0,
                    "lab": { "l": c.l.round(), "a": c.a.round(), "b": c.b.round() }
                })
            })
            .collect();

        let mut payload = Map::new();
        payload.insert("id".into(), json!(format_swift_uuid(&doc.id)));
        payload.insert("boardID".into(), json!(format_swift_uuid(&doc.id)));
        payload.insert("title".into(), json!(doc.title));
        payload.insert(
            "mode".into(),
            json!(if doc.mode.is_auto_editorial() {
                "autoEditorial"
            } else {
                "freeform"
            }),
        );
        payload.insert("pinnedOffline".into(), json!(doc.pinned_offline));
        payload.insert("updatedAt".into(), json!(doc.updated_at.to_rfc3339()));
        payload.insert("itemCount".into(), json!(card_refs.len()));
        payload.insert("inkStrokeCount".into(), json!(doc.ink_strokes.len()));
        payload.insert("palette".into(), json!(palette));
        payload.insert("notes".into(), json!(notes));
        payload.insert("sections".into(), json!(sections));
        payload.insert("connectors".into(), json!(connectors));
        payload.insert("assets".into(), json!(card_refs));
        payload.insert("candidatePool".into(), json!(candidates));
        if !doc.subtitle.is_empty() {
            payload.insert("subtitle".into(), json!(doc.subtitle));
        }

        if include_snapshot {
            let dark = bool_arg(args.get("dark_appearance")).unwrap_or(false);
            let width = args
                .get("snapshot_width")
                .or_else(|| args.get("width"))
                .and_then(Value::as_f64)
                .unwrap_or(1440.0)
                .clamp(840.0, 2800.0);
            let opts = MoodboardExportOptions {
                scale: 1.0,
                format: BoardImageFormat::Png,
                include_annotations: true,
                include_palette_strip: true,
                dark_appearance: dark,
                container_width: width,
            };
            if let Ok(png_bytes) = self.engine.export_board_image_bytes(&doc, &opts) {
                payload.insert(
                    "snapshot".into(),
                    json!({
                        "width": width as u32,
                        "darkAppearance": dark,
                        "bytes": png_bytes.len(),
                        "mimeType": "image/png"
                    }),
                );
                return Ok(ToolOutput {
                    content: vec![
                        ToolContent::Image {
                            mime_type: "image/png".to_string(),
                            data: png_bytes,
                        },
                        ToolContent::Text(
                            serde_json::to_string(&Value::Object(payload)).unwrap_or_default(),
                        ),
                    ],
                    is_error: false,
                });
            }
        }

        Ok(ToolOutput::json(Value::Object(payload)))
    }

    // =========================================================================
    // Tool 5: ingest_assets (Cross-Machine `inline_files` + `web_urls` + `text` + stdio `file_paths`)
    // =========================================================================

    async fn handle_ingest_assets(
        &self,
        args: &Value,
        effective_access: ExternalAgentAccessLevel,
        ctx: &ExternalAgentRequestContext,
    ) -> CoreResult<ToolOutput> {
        if !effective_access.allows_inbox_and_enrich_writes() {
            return Ok(ToolOutput::error(format!(
                "当前权限为「{}」，无法导入素材。需要「仅收件箱与打标」或「全局整理与生板」权限。",
                effective_access.display_title()
            )));
        }

        let folders = self.engine.fetch_folders()?;
        let folder_paths = build_folder_paths(&folders);
        let target_folder_id = self.resolve_optional_folder_id(args, &folders, &folder_paths)?;
        let target_board_id = if let Some(raw_bid) = args
            .get("target_board_id")
            .and_then(Value::as_str)
            .map(str::trim)
            .filter(|s| !s.is_empty())
        {
            if !effective_access.allows_global_organize_writes() {
                return Ok(ToolOutput::error(
                    "当前权限为「仅收件箱与打标」，不允许直接写入情绪板（`target_board_id` 需要「全局整理与生板」权限）。",
                ));
            }
            Some(self.resolve_board_uuid(raw_bid)?)
        } else {
            None
        };

        let single_title = args
            .get("title")
            .and_then(Value::as_str)
            .map(str::trim)
            .filter(|s| !s.is_empty())
            .map(ToOwned::to_owned);
        let single_notes = args
            .get("notes")
            .and_then(Value::as_str)
            .map(str::trim)
            .filter(|s| !s.is_empty())
            .map(ToOwned::to_owned);

        let mut inputs: Vec<CaptureInput> = Vec::new();

        // Security invariant: local disk `file_path(s)` are STRICTLY FORBIDDEN over HTTP MCP!
        let file_paths_list = string_array_arg(args.get("file_paths"));
        let single_file_path = args
            .get("file_path")
            .and_then(Value::as_str)
            .map(str::trim)
            .filter(|s| !s.is_empty());
        if !file_paths_list.is_empty() || single_file_path.is_some() {
            if ctx.is_remote_http() {
                return Ok(ToolOutput::error(
                    "远程 HTTP MCP 禁止读取服务端本机路径（`file_path`/`file_paths`）。请改用 `inline_files: [{filename, data_base64}]` 或 `web_urls`。",
                ));
            }
            if !file_paths_list.is_empty() {
                for raw in file_paths_list {
                    match self.validate_agent_ingest_file_path(&raw) {
                        Ok(path) => inputs.push(CaptureInput::FilePath(path)),
                        Err(msg) => return Ok(ToolOutput::error(msg)),
                    }
                }
            } else if let Some(raw) = single_file_path {
                match self.validate_agent_ingest_file_path(raw) {
                    Ok(path) => inputs.push(CaptureInput::FilePath(path)),
                    Err(msg) => return Ok(ToolOutput::error(msg)),
                }
            }
        }

        // Cross-machine inline binary uploads (`inline_files: [{filename, data_base64}]`)
        let mut _staging_guard: Option<StagingDirGuard> = None;
        if let Some(inline_arr) = args.get("inline_files").and_then(Value::as_array) {
            if !inline_arr.is_empty() {
                let scratch = std::env::temp_dir()
                    .join(format!("charkle-mcp-ingest-{}", Uuid::new_v4().simple()));
                std::fs::create_dir_all(&scratch)?;
                let mut guard = StagingDirGuard::new();
                guard.push(scratch.clone());
                _staging_guard = Some(guard);
                let mut total_bytes = 0usize;

                for (idx, item) in inline_arr.iter().take(20).enumerate() {
                    let raw_name = item
                        .get("filename")
                        .or_else(|| item.get("file_name"))
                        .and_then(Value::as_str)
                        .map(str::trim)
                        .unwrap_or("");
                    let clean_name = sanitize_upload_filename(raw_name, idx + 1);
                    let Some(raw_b64) = item
                        .get("data_base64")
                        .or_else(|| item.get("base64_data"))
                        .and_then(Value::as_str)
                        .filter(|s| !s.trim().is_empty())
                    else {
                        return Ok(ToolOutput::error(format!(
                            "inline_files[{idx}] is missing non-empty `data_base64`."
                        )));
                    };
                    let b64_payload = if raw_b64.starts_with("data:") {
                        raw_b64
                            .split_once(',')
                            .map(|(_, rest)| rest)
                            .unwrap_or(raw_b64)
                    } else {
                        raw_b64
                    };
                    let compact_b64: String =
                        b64_payload.chars().filter(|c| !c.is_whitespace()).collect();
                    let decoded = match BASE64.decode(&compact_b64) {
                        Ok(bytes) if !bytes.is_empty() => bytes,
                        _ => {
                            return Ok(ToolOutput::error(format!(
                                "inline_files[{idx}] (`{clean_name}`) contains invalid base64 data."
                            )));
                        }
                    };
                    if decoded.len() > MAX_INLINE_FILE_BYTES {
                        return Ok(ToolOutput::error(format!(
                            "inline_files[{idx}] (`{clean_name}`) exceeds 16 MB per-file limit."
                        )));
                    }
                    total_bytes = total_bytes.saturating_add(decoded.len());
                    if total_bytes > MAX_INLINE_BATCH_BYTES {
                        return Ok(ToolOutput::error(
                            "Total `inline_files` upload size exceeds 32 MB per-call limit.",
                        ));
                    }
                    let item_dir = scratch.join(format!("item-{idx}"));
                    std::fs::create_dir_all(&item_dir)?;
                    let file_path = item_dir.join(&clean_name);
                    std::fs::write(&file_path, &decoded)?;
                    inputs.push(CaptureInput::FilePath(file_path));
                }
            }
        }

        let web_urls_list = string_array_arg(args.get("web_urls"));
        if !web_urls_list.is_empty() {
            for raw in &web_urls_list {
                let parsed = Url::parse(raw)
                    .ok()
                    .filter(|u| matches!(u.scheme(), "http" | "https"));
                if parsed.is_none() {
                    return Ok(ToolOutput::error(format!(
                        "Invalid HTTP(S) URL in `web_urls`: {raw}"
                    )));
                }
                let title_for_url = if web_urls_list.len() == 1 && inputs.is_empty() {
                    single_title.clone()
                } else {
                    None
                };
                inputs.push(CaptureInput::WebUrl {
                    url: raw.clone(),
                    title: title_for_url,
                    notes: single_notes.clone(),
                });
            }
        } else if let Some(web_url) = args
            .get("web_url")
            .and_then(Value::as_str)
            .map(str::trim)
            .filter(|s| !s.is_empty())
        {
            let parsed = Url::parse(web_url)
                .ok()
                .filter(|u| matches!(u.scheme(), "http" | "https"));
            if parsed.is_none() {
                return Ok(ToolOutput::error(format!(
                    "Invalid HTTP(S) `web_url`: {web_url}"
                )));
            }
            let title_for_url = if inputs.is_empty() {
                single_title.clone()
            } else {
                None
            };
            inputs.push(CaptureInput::WebUrl {
                url: web_url.to_string(),
                title: title_for_url,
                notes: single_notes.clone(),
            });
        }

        if inputs.is_empty() {
            if let Some(text) = args
                .get("text")
                .and_then(Value::as_str)
                .map(str::trim)
                .filter(|s| !s.is_empty())
            {
                inputs.push(CaptureInput::TextSnippet {
                    title: single_title.unwrap_or_else(|| "Agent 笔记".to_string()),
                    text: text.to_string(),
                    source_url: None,
                });
            }
        }

        if inputs.is_empty() {
            return Ok(ToolOutput::error(
                "Provide `web_url(s)`, `inline_files`, `text`, or (local stdio only) `file_path(s)`.",
            ));
        }

        let mut created = self
            .engine
            .ingest(inputs, target_folder_id, target_board_id)
            .await?;

        let tags = string_array_arg(args.get("tags"));
        let notes = args
            .get("notes")
            .and_then(Value::as_str)
            .map(ToOwned::to_owned);
        let rating = args
            .get("rating")
            .and_then(Value::as_i64)
            .map(|r| r.clamp(0, 5) as i32);
        if !created.is_empty() && (!tags.is_empty() || notes.is_some() || rating.is_some()) {
            let patch = AssetBatchPatch {
                asset_ids: created.iter().map(|a| a.id).collect(),
                notes,
                rating,
                add_tags: tags,
                ..Default::default()
            };
            let updated = self.engine.update_assets(&patch)?;
            if !updated.is_empty() {
                created = updated;
            }
        }

        let mut run = AgentRunRecord::new(
            "ingest_assets",
            ctx.actor_label.clone(),
            ctx.transport.as_str(),
            format!("导入 {} 项素材", created.len()),
        );
        run.ingested_asset_ids = created.iter().map(|a| a.id).collect();
        ExternalAgentStateStore::record_run(self.engine.database(), &run);

        let latest_paths = build_folder_paths(&self.engine.fetch_folders()?);
        self.notify_write(if target_board_id.is_some() {
            "boards"
        } else {
            "assets"
        });
        Ok(ToolOutput::json(json!({
            "runID": run.id,
            "importedCount": created.len(),
            "assets": created
                .iter()
                .map(|a| serialize_asset_summary(a, &latest_paths, AssetDetailLevel::Compact))
                .collect::<Vec<_>>()
        })))
    }

    // =========================================================================
    // Tool 6: organize_assets (Heterogeneous Batch + Dry-Run + Canonical Tag Folding + Rollback)
    // =========================================================================

    async fn handle_organize_assets(
        &self,
        args: &Value,
        effective_access: ExternalAgentAccessLevel,
        ctx: &ExternalAgentRequestContext,
    ) -> CoreResult<ToolOutput> {
        if !effective_access.allows_inbox_and_enrich_writes() {
            return Ok(ToolOutput::error(
                "当前权限为「仅只读」，无法整理素材。请在 Charkle「设置 → 外部 Agent」升级权限或更换密钥。",
            ));
        }

        let dry_run = bool_arg(args.get("dry_run")).unwrap_or(false);
        let folders = self.engine.fetch_folders()?;
        let folder_paths = build_folder_paths(&folders);
        let taxonomy = ExternalAgentStateStore::load_taxonomy(self.engine.database());

        let mut canonical_tag_lookup: HashMap<String, String> = HashMap::new();
        for tc in self.engine.fetch_tag_counts().unwrap_or_default() {
            canonical_tag_lookup.insert(search_text::normalize(&tc.name), tc.name);
        }
        for (alias, canonical) in &taxonomy.tag_aliases {
            canonical_tag_lookup.insert(search_text::normalize(alias), canonical.clone());
        }

        let mut normalized_tag_pairs: Vec<Value> = Vec::new();
        let mut seen_norm_pairs: HashSet<String> = HashSet::new();
        let mut proposed_new_tags: BTreeSet<String> = BTreeSet::new();

        let mut canonicalize_tags = |raw_tags: Vec<String>| -> Vec<String> {
            let mut out = Vec::new();
            let mut seen = HashSet::new();
            for raw in raw_tags {
                let trimmed = raw.trim();
                if trimmed.is_empty() {
                    continue;
                }
                let key = search_text::normalize(trimmed);
                let resolved = if let Some(canonical) = canonical_tag_lookup.get(&key) {
                    if canonical != trimmed
                        && seen_norm_pairs.insert(format!("{trimmed}->{canonical}"))
                    {
                        normalized_tag_pairs.push(json!({ "from": trimmed, "to": canonical }));
                    }
                    canonical.clone()
                } else {
                    proposed_new_tags.insert(trimmed.to_string());
                    trimmed.to_string()
                };
                if seen.insert(search_text::normalize(&resolved)) {
                    out.push(resolved);
                }
            }
            out
        };

        let mut parse_item = |dict: &Value, asset_id: Uuid| -> CoreResult<NormalizedOrganizeItem> {
            let (folder_assignment, folder_target_label) =
                if bool_arg(dict.get("move_to_inbox")).unwrap_or(false) {
                    (FolderAssignment::Inbox, Some("Inbox".to_string()))
                } else if let Some(fid) =
                    self.resolve_optional_folder_id(dict, &folders, &folder_paths)?
                {
                    (
                        FolderAssignment::Folder(fid),
                        folder_paths.get(&fid).cloned(),
                    )
                } else {
                    (FolderAssignment::Unchanged, None)
                };
            Ok(NormalizedOrganizeItem {
                asset_id,
                folder_assignment,
                folder_target_label,
                add_tags: canonicalize_tags(string_array_arg(dict.get("add_tags"))),
                remove_tags: string_array_arg(dict.get("remove_tags")),
                add_suggested_tags: string_array_arg(dict.get("add_suggested_tags")),
                accept_suggested_tags: bool_arg(dict.get("accept_suggested_tags")).unwrap_or(false),
                dismiss_suggested_tags: string_array_arg(dict.get("dismiss_suggested_tags")),
                rating: dict
                    .get("rating")
                    .and_then(Value::as_i64)
                    .map(|r| r.clamp(0, 5) as i32),
                title: dict
                    .get("title")
                    .and_then(Value::as_str)
                    .map(ToOwned::to_owned),
                notes: dict
                    .get("notes")
                    .and_then(Value::as_str)
                    .map(ToOwned::to_owned),
                ai_description: dict
                    .get("ai_description")
                    .and_then(Value::as_str)
                    .map(|s| s.trim().to_string()),
                pinned_offline: bool_arg(dict.get("pinned_offline")),
                is_trashed: bool_arg(dict.get("trashed")),
                analyze: bool_arg(dict.get("analyze")).unwrap_or(false),
                refresh_rich_metadata: bool_arg(dict.get("refresh_rich_metadata")).unwrap_or(false),
            })
        };

        let mut items: Vec<NormalizedOrganizeItem> = Vec::new();
        if let Some(raw_items) = args.get("items").and_then(Value::as_array) {
            if raw_items.is_empty() {
                return Ok(ToolOutput::error(
                    "`items` must be a non-empty array of `{asset_id, ...}`.",
                ));
            }
            if raw_items.len() > 50 {
                return Ok(ToolOutput::error(
                    "`organize_assets` accepts at most 50 heterogeneous `items` per call.",
                ));
            }
            for (idx, item_val) in raw_items.iter().enumerate() {
                let Some(raw_id) = item_val
                    .get("asset_id")
                    .or_else(|| item_val.get("id"))
                    .and_then(Value::as_str)
                else {
                    return Ok(ToolOutput::error(format!(
                        "items[{idx}] has missing `asset_id`."
                    )));
                };
                let uuid = self.resolve_asset_uuid(raw_id)?;
                items.push(parse_item(item_val, uuid)?);
            }
        } else {
            let ids = self.resolve_asset_uuid_list(args.get("asset_ids"))?;
            if ids.is_empty() {
                return Ok(ToolOutput::error(
                    "Provide either heterogeneous `items: [{asset_id, ...}]` or uniform `asset_ids: [...]`.",
                ));
            }
            if ids.len() > 50 {
                return Ok(ToolOutput::error(
                    "`organize_assets` accepts at most 50 assets per call.",
                ));
            }
            for uuid in ids {
                items.push(parse_item(args, uuid)?);
            }
        }

        // Load pre-mutation assets for scope validation, diff preview, and rollback snapshots
        let mut before_by_id: HashMap<Uuid, AssetRecord> = HashMap::new();
        for item in &items {
            if !before_by_id.contains_key(&item.asset_id) {
                if let Some(asset) = self.engine.fetch_asset(item.asset_id)? {
                    before_by_id.insert(asset.id, asset);
                }
            }
        }

        let mut missing_ids: Vec<String> = Vec::new();
        let mut scope_violations: Vec<String> = Vec::new();
        let mut valid_items: Vec<NormalizedOrganizeItem> = Vec::new();

        for item in items {
            let Some(before) = before_by_id.get(&item.asset_id) else {
                missing_ids.push(format_swift_uuid(&item.asset_id));
                continue;
            };
            if effective_access == ExternalAgentAccessLevel::InboxAndEnrich {
                let short = &format_swift_uuid(&before.id)[..8];
                if item.is_trashed.is_some() {
                    scope_violations.push(format!(
                        "{short}（仅收件箱与打标权限不允许移入/恢复回收站）"
                    ));
                    continue;
                }
                if item.pinned_offline.is_some() {
                    scope_violations
                        .push(format!("{short}（仅收件箱与打标权限不允许修改离线置顶）"));
                    continue;
                }
                if item.touches_curated_fields() && before.folder_id.is_some() {
                    let cur_path = before
                        .folder_id
                        .and_then(|fid| folder_paths.get(&fid).cloned())
                        .unwrap_or_else(|| "已归档目录".to_string());
                    scope_violations.push(format!(
                        "{short} 位于「{cur_path}」（仅收件箱与打标权限仅可整理收件箱素材，或对已归档素材补写 `ai_description`/`add_suggested_tags`）"
                    ));
                    continue;
                }
            }
            valid_items.push(item);
        }

        if !scope_violations.is_empty() {
            return Ok(ToolOutput::error(format!(
                "权限范围拦截：{}",
                scope_violations
                    .iter()
                    .take(5)
                    .cloned()
                    .collect::<Vec<_>>()
                    .join("；")
            )));
        }

        let mut folder_move_count = 0usize;
        let mut trash_count = 0usize;
        let mut restore_count = 0usize;
        let mut preview_items: Vec<Value> = Vec::new();

        for item in &valid_items {
            let Some(before) = before_by_id.get(&item.asset_id) else {
                continue;
            };
            let from_folder = before
                .folder_id
                .and_then(|fid| folder_paths.get(&fid).cloned())
                .unwrap_or_else(|| "Inbox".to_string());
            if let Some(ref to_folder) = item.folder_target_label {
                if to_folder != &from_folder {
                    folder_move_count += 1;
                }
            }
            if item.is_trashed == Some(true) && !before.is_trashed {
                trash_count += 1;
            }
            if item.is_trashed == Some(false) && before.is_trashed {
                restore_count += 1;
            }
            if dry_run {
                let mut diff = Map::new();
                diff.insert("id".into(), json!(&format_swift_uuid(&before.id)[..8]));
                diff.insert("title".into(), json!(before.title));
                diff.insert("fromFolder".into(), json!(from_folder));
                if let Some(ref to_folder) = item.folder_target_label {
                    diff.insert("toFolder".into(), json!(to_folder));
                }
                if !item.add_tags.is_empty() {
                    diff.insert("addTags".into(), json!(item.add_tags));
                }
                if !item.remove_tags.is_empty() {
                    diff.insert("removeTags".into(), json!(item.remove_tags));
                }
                if !item.add_suggested_tags.is_empty() {
                    diff.insert("addSuggestedTags".into(), json!(item.add_suggested_tags));
                }
                if let Some(r) = item.rating {
                    diff.insert("rating".into(), json!(r));
                }
                if let Some(t) = item.is_trashed {
                    diff.insert("trashed".into(), json!(t));
                }
                preview_items.push(Value::Object(diff));
            }
        }

        if dry_run {
            let mut resp = Map::new();
            resp.insert("dryRun".into(), json!(true));
            resp.insert("plannedCount".into(), json!(valid_items.len()));
            resp.insert("folderMoveCount".into(), json!(folder_move_count));
            resp.insert("trashCount".into(), json!(trash_count));
            resp.insert("restoreCount".into(), json!(restore_count));
            resp.insert("items".into(), json!(preview_items));
            if !proposed_new_tags.is_empty() {
                resp.insert("newTags".into(), json!(proposed_new_tags));
            }
            if !normalized_tag_pairs.is_empty() {
                resp.insert("normalizedTags".into(), json!(normalized_tag_pairs));
            }
            if !missing_ids.is_empty() {
                resp.insert("missingIDs".into(), json!(missing_ids));
            }
            return Ok(ToolOutput::json(Value::Object(resp)));
        }

        // Capture full before-snapshots for compensating rollback
        let mut snapshot_set = HashSet::new();
        let mut snapshots = Vec::new();
        for item in &valid_items {
            if snapshot_set.insert(item.asset_id) {
                if let Some(before) = before_by_id.get(&item.asset_id) {
                    snapshots.push(AgentAssetSnapshot::from(before));
                }
            }
        }

        let mut touched_ids: BTreeSet<Uuid> = BTreeSet::new();

        // 1. Apply standard curated/folder/trash patches
        for item in &valid_items {
            if item.has_batch_patch_fields()
                || item
                    .ai_description
                    .as_deref()
                    .is_some_and(|s| !s.is_empty())
            {
                let patch = AssetBatchPatch {
                    asset_ids: vec![item.asset_id],
                    title: item.title.clone(),
                    notes: item.notes.clone(),
                    ai_description: item
                        .ai_description
                        .as_deref()
                        .filter(|s| !s.is_empty())
                        .map(ToOwned::to_owned),
                    source_url: None,
                    folder_assignment: item.folder_assignment,
                    add_tags: item.add_tags.clone(),
                    remove_tags: item.remove_tags.clone(),
                    accept_suggested_tags: item.accept_suggested_tags,
                    dismiss_suggested_tags: item.dismiss_suggested_tags.clone(),
                    rating: item.rating,
                    is_trashed: item.is_trashed,
                    pinned_offline: item.pinned_offline,
                };
                for updated in self.engine.update_assets(&patch)? {
                    touched_ids.insert(updated.id);
                }
            }

            // 2. Append `add_suggested_tags` (emits HLC sync ops cleanly)
            if !item.add_suggested_tags.is_empty() {
                if let Some(mut current) = self.engine.fetch_asset(item.asset_id)? {
                    let mut existing: HashSet<String> = current
                        .tags
                        .iter()
                        .chain(current.suggested_tags.iter())
                        .map(|t| search_text::normalize(t))
                        .collect();
                    let mut changed = false;
                    for raw in &item.add_suggested_tags {
                        let clean = raw.trim();
                        if clean.is_empty() {
                            continue;
                        }
                        if existing.insert(search_text::normalize(clean)) {
                            current.suggested_tags.push(clean.to_string());
                            changed = true;
                        }
                    }
                    if changed {
                        let _ = self.engine.database().save_asset_locally(&current, false)?;
                        touched_ids.insert(current.id);
                    }
                }
            }
        }

        // 3. Optional local analysis & live rich metadata refresh (capped at 20)
        let mut analyze_seen = HashSet::new();
        let analyze_items: Vec<&NormalizedOrganizeItem> = valid_items
            .iter()
            .filter(|i| (i.analyze || i.refresh_rich_metadata) && analyze_seen.insert(i.asset_id))
            .take(20)
            .collect();
        for item in analyze_items {
            if self.engine.hydrate_image_metadata(item.asset_id)?.is_some() {
                touched_ids.insert(item.asset_id);
            }
            if let Ok(Some(_)) = self.engine.run_ocr_for_asset(item.asset_id).await {
                touched_ids.insert(item.asset_id);
            }
            if item.refresh_rich_metadata
                && self.engine.refresh_rich_asset(item.asset_id).await.is_ok()
            {
                touched_ids.insert(item.asset_id);
            }
        }

        let mut run = AgentRunRecord::new(
            "organize_assets",
            ctx.actor_label.clone(),
            ctx.transport.as_str(),
            format!(
                "整理 {} 项素材（移动 {}，移至回收站 {}）",
                touched_ids.len(),
                folder_move_count,
                trash_count
            ),
        );
        run.asset_snapshots = snapshots;
        if !run.asset_snapshots.is_empty() {
            ExternalAgentStateStore::record_run(self.engine.database(), &run);
        }

        if !touched_ids.is_empty() {
            self.notify_write("assets");
        }

        let mut result = Map::new();
        result.insert("runID".into(), json!(run.id));
        result.insert("updatedCount".into(), json!(touched_ids.len()));
        result.insert("folderMoveCount".into(), json!(folder_move_count));
        result.insert("trashCount".into(), json!(trash_count));
        result.insert(
            "assetIDs".into(),
            json!(touched_ids
                .iter()
                .map(format_swift_uuid)
                .collect::<Vec<_>>()),
        );
        if !proposed_new_tags.is_empty() {
            result.insert("newTags".into(), json!(proposed_new_tags));
        }
        if !normalized_tag_pairs.is_empty() {
            result.insert("normalizedTags".into(), json!(normalized_tag_pairs));
        }
        if !missing_ids.is_empty() {
            result.insert("skippedIDs".into(), json!(missing_ids));
        }
        Ok(ToolOutput::json(Value::Object(result)))
    }

    // =========================================================================
    // Tool 7: manage_folder (Create or Update — Delete Strictly Forbidden)
    // =========================================================================

    fn handle_manage_folder(
        &self,
        args: &Value,
        effective_access: ExternalAgentAccessLevel,
        ctx: &ExternalAgentRequestContext,
    ) -> CoreResult<ToolOutput> {
        if !effective_access.allows_global_organize_writes() {
            return Ok(ToolOutput::error(format!(
                "当前权限为「{}」，管理文件夹需要「全局整理与生板」权限。",
                effective_access.display_title()
            )));
        }

        let action = args
            .get("action")
            .and_then(Value::as_str)
            .map(|s| s.trim().to_ascii_lowercase())
            .unwrap_or_default();
        let folders = self.engine.fetch_folders()?;
        let folder_paths = build_folder_paths(&folders);

        match action.as_str() {
            "create" => {
                let name = args
                    .get("name")
                    .and_then(Value::as_str)
                    .map(str::trim)
                    .unwrap_or("");
                if name.is_empty() {
                    return Ok(ToolOutput::error(
                        "Missing non-empty folder `name` for manage_folder(action:'create').",
                    ));
                }
                let parent_id = self.resolve_parent_folder_id(args, &folders, &folder_paths)?;
                let reuse_existing = bool_arg(args.get("reuse_existing")).unwrap_or(true);
                if reuse_existing {
                    if let Some(existing) = folders
                        .iter()
                        .find(|f| f.parent_id == parent_id && f.name.eq_ignore_ascii_case(name))
                    {
                        return Ok(ToolOutput::json(json!({
                            "id": format_swift_uuid(&existing.id),
                            "name": existing.name,
                            "path": folder_paths.get(&existing.id).cloned().unwrap_or_else(|| existing.name.clone()),
                            "parentID": existing.parent_id.map(|id| format_swift_uuid(&id)).unwrap_or_default(),
                            "reusedExisting": true
                        })));
                    }
                }
                let mut created = self.engine.create_folder(name, parent_id)?;
                let color_hex = args
                    .get("color_hex")
                    .and_then(Value::as_str)
                    .map(ToOwned::to_owned);
                let custom_symbol = args
                    .get("custom_symbol")
                    .and_then(Value::as_str)
                    .map(ToOwned::to_owned);
                if color_hex.is_some() || custom_symbol.is_some() {
                    created = self
                        .engine
                        .update_folder_appearance(created.id, color_hex, custom_symbol)?;
                }
                let refreshed_paths = build_folder_paths(&self.engine.fetch_folders()?);
                self.notify_write("folders");
                Ok(ToolOutput::json(json!({
                    "id": format_swift_uuid(&created.id),
                    "name": created.name,
                    "path": refreshed_paths.get(&created.id).cloned().unwrap_or_else(|| created.name.clone()),
                    "parentID": created.parent_id.map(|id| format_swift_uuid(&id)).unwrap_or_default(),
                    "colorHex": created.color_hex.unwrap_or_default(),
                    "customSymbol": created.custom_symbol.unwrap_or_default(),
                    "reusedExisting": false
                })))
            }
            "update" => {
                let Some(folder_id) =
                    self.resolve_optional_folder_id(args, &folders, &folder_paths)?
                else {
                    return Ok(ToolOutput::error(
                        "Folder not found. Pass a valid `folder_id` UUID/prefix or matching `folder_path`.",
                    ));
                };
                let Some(mut current) = folders.iter().find(|f| f.id == folder_id).cloned() else {
                    return Ok(ToolOutput::error("Folder not found."));
                };
                let before_snapshot = AgentFolderSnapshot::from(&current);

                if let Some(new_name) = args
                    .get("new_name")
                    .and_then(Value::as_str)
                    .map(str::trim)
                    .filter(|s| !s.is_empty())
                {
                    current = self.engine.rename_folder(folder_id, new_name)?;
                }

                let move_to_root = bool_arg(args.get("move_to_root")).unwrap_or(false);
                let has_parent_arg = args
                    .get("parent_id")
                    .and_then(Value::as_str)
                    .is_some_and(|s| !s.trim().is_empty())
                    || args
                        .get("parent_path")
                        .and_then(Value::as_str)
                        .is_some_and(|s| !s.trim().is_empty());
                if move_to_root || has_parent_arg {
                    let latest_folders = self.engine.fetch_folders()?;
                    let latest_paths = build_folder_paths(&latest_folders);
                    let new_parent_id = if move_to_root {
                        None
                    } else {
                        self.resolve_parent_folder_id(args, &latest_folders, &latest_paths)?
                    };
                    self.engine.move_folder(folder_id, new_parent_id, None)?;
                }

                if args.get("color_hex").is_some() || args.get("custom_symbol").is_some() {
                    let color_hex = args
                        .get("color_hex")
                        .and_then(Value::as_str)
                        .map(ToOwned::to_owned)
                        .or_else(|| current.color_hex.clone());
                    let custom_symbol = args
                        .get("custom_symbol")
                        .and_then(Value::as_str)
                        .map(ToOwned::to_owned)
                        .or_else(|| current.custom_symbol.clone());
                    current =
                        self.engine
                            .update_folder_appearance(folder_id, color_hex, custom_symbol)?;
                }

                let final_folders = self.engine.fetch_folders()?;
                let final_paths = build_folder_paths(&final_folders);
                let final_folder = final_folders
                    .iter()
                    .find(|f| f.id == folder_id)
                    .cloned()
                    .unwrap_or(current);

                let mut run = AgentRunRecord::new(
                    "manage_folder",
                    ctx.actor_label.clone(),
                    ctx.transport.as_str(),
                    format!("更新文件夹「{}」", final_folder.name),
                );
                run.folder_snapshots.push(before_snapshot);
                ExternalAgentStateStore::record_run(self.engine.database(), &run);

                self.notify_write("folders");
                Ok(ToolOutput::json(json!({
                    "runID": run.id,
                    "id": format_swift_uuid(&final_folder.id),
                    "name": final_folder.name,
                    "path": final_paths.get(&final_folder.id).cloned().unwrap_or_else(|| final_folder.name.clone()),
                    "parentID": final_folder.parent_id.map(|id| format_swift_uuid(&id)).unwrap_or_default(),
                    "colorHex": final_folder.color_hex.unwrap_or_default(),
                    "customSymbol": final_folder.custom_symbol.unwrap_or_default(),
                    "assetCount": final_folder.asset_count
                })))
            }
            _ => Ok(ToolOutput::error(
                "Invalid `action` for manage_folder. Expected 'create' or 'update' (deleting folders is strictly forbidden).",
            )),
        }
    }

    // =========================================================================
    // Tool 8: save_moodboard (Create OR Non-Destructive Patch + Rollback Snapshot)
    // =========================================================================

    async fn handle_save_moodboard(
        &self,
        args: &Value,
        effective_access: ExternalAgentAccessLevel,
        ctx: &ExternalAgentRequestContext,
    ) -> CoreResult<ToolOutput> {
        if !effective_access.allows_global_organize_writes() {
            return Ok(ToolOutput::error(format!(
                "当前权限为「{}」，创建或更新情绪板需要「全局整理与生板」权限。",
                effective_access.display_title()
            )));
        }

        let has_board_id = args
            .get("board_id")
            .or_else(|| args.get("id"))
            .and_then(Value::as_str)
            .is_some_and(|s| !s.trim().is_empty());
        let has_patch_only = args.get("new_title").is_some()
            || args.get("add_asset_ids").is_some()
            || args.get("remove_asset_ids").is_some()
            || args.get("remove_node_ids").is_some()
            || args.get("add_section").is_some()
            || args.get("add_note").is_some();

        if has_board_id || has_patch_only {
            self.patch_existing_moodboard(args, ctx)
        } else {
            self.create_new_moodboard(args, ctx).await
        }
    }

    async fn create_new_moodboard(
        &self,
        args: &Value,
        ctx: &ExternalAgentRequestContext,
    ) -> CoreResult<ToolOutput> {
        let title = args
            .get("title")
            .and_then(Value::as_str)
            .map(str::trim)
            .unwrap_or("");
        let subtitle = args
            .get("subtitle")
            .and_then(Value::as_str)
            .map(str::trim)
            .unwrap_or("");
        let style = match args.get("layout_style").and_then(Value::as_str) {
            Some("balanced") => EditorialStyle::Balanced,
            Some("compact") => EditorialStyle::Compact,
            _ => EditorialStyle::Magazine,
        };
        let use_freeform = bool_arg(args.get("use_freeform")).unwrap_or(false);

        let raw_sections = args
            .get("sections")
            .and_then(Value::as_array)
            .filter(|a| !a.is_empty());
        let flat_asset_ids = self.resolve_asset_uuid_list(args.get("asset_ids"))?;

        let (doc, used_cloud_ai, curated_summary) = if raw_sections.is_some()
            || !flat_asset_ids.is_empty()
        {
            let mut d = MoodboardDocument::new(if title.is_empty() {
                "Agent 策展情绪板"
            } else {
                title
            });
            d.subtitle = subtitle.to_string();
            d.mode = if use_freeform {
                BoardLayoutMode::Freeform
            } else {
                BoardLayoutMode::AutoEditorial(AutoLayoutConfig {
                    columns: 4,
                    spacing: 16.0,
                    style,
                    show_palette_strip: true,
                })
            };

            let mut palette: Vec<LabColor> = Vec::new();
            let mut next_order = 0i32;
            let mut cursor_y = 40.0f64;
            let mut added_any = false;

            if let Some(sections) = raw_sections {
                for sec in sections {
                    let sec_title = sec
                        .get("title")
                        .and_then(Value::as_str)
                        .map(str::trim)
                        .filter(|s| !s.is_empty())
                        .unwrap_or("精选参考");
                    let tint = parse_group_tint(sec.get("tint").and_then(Value::as_str));
                    let hero_set: HashSet<Uuid> = self
                        .resolve_asset_uuid_list(sec.get("hero_asset_ids"))?
                        .into_iter()
                        .collect();
                    let sec_ids = self.resolve_asset_uuid_list(sec.get("asset_ids"))?;
                    let mut sec_assets = Vec::new();
                    for aid in sec_ids {
                        if let Some(asset) = self.engine.fetch_asset(aid)? {
                            sec_assets.push(asset);
                        }
                    }
                    if sec_assets.is_empty() {
                        continue;
                    }
                    added_any = true;
                    d.nodes.push(BoardNode {
                        id: Uuid::new_v4(),
                        kind: BoardNodeKind::GroupFrame {
                            title: sec_title.to_string(),
                            tint,
                        },
                        frame: BoardRect::new(40.0, cursor_y, 1040.0, 56.0),
                        z_index: next_order,
                        rotation_degrees: 0.0,
                        flip_horizontal: false,
                        flip_vertical: false,
                        is_locked: false,
                        editorial_order: next_order,
                        updated_at: Utc::now(),
                    });
                    next_order += 1;
                    cursor_y += 72.0;

                    for (idx, asset) in sec_assets.iter().enumerate() {
                        if let Some(c) = asset.dominant_colors.first() {
                            if palette.len() < 6 {
                                palette.push(c.clone());
                            }
                        }
                        let ratio = asset.aspect_ratio().clamp(0.6, 1.9);
                        let weight = if hero_set.contains(&asset.id) { 2 } else { 1 };
                        let col = (idx % 4) as f64;
                        let row = (idx / 4) as f64;
                        d.nodes.push(BoardNode {
                            id: Uuid::new_v4(),
                            kind: BoardNodeKind::AssetRef {
                                asset_id: asset.id,
                                crop: None,
                                weight,
                                autoplay_loop: matches!(
                                    asset.media_kind,
                                    MediaKind::AnimatedImage | MediaKind::Video
                                ),
                            },
                            frame: BoardRect::new(
                                40.0 + col * 260.0,
                                cursor_y + row * 240.0,
                                240.0,
                                240.0 / ratio,
                            ),
                            z_index: next_order,
                            rotation_degrees: 0.0,
                            flip_horizontal: false,
                            flip_vertical: false,
                            is_locked: false,
                            editorial_order: next_order,
                            updated_at: Utc::now(),
                        });
                        next_order += 1;
                    }
                    let rows = (sec_assets.len().saturating_sub(1) / 4) + 1;
                    cursor_y += (rows as f64) * 240.0 + 32.0;
                }
            } else {
                let hero_set: HashSet<Uuid> = self
                    .resolve_asset_uuid_list(args.get("hero_asset_ids"))?
                    .into_iter()
                    .collect();
                for (idx, aid) in flat_asset_ids.iter().enumerate() {
                    let Some(asset) = self.engine.fetch_asset(*aid)? else {
                        continue;
                    };
                    added_any = true;
                    if let Some(c) = asset.dominant_colors.first() {
                        if palette.len() < 6 {
                            palette.push(c.clone());
                        }
                    }
                    let ratio = asset.aspect_ratio().clamp(0.6, 1.9);
                    let weight = if hero_set.contains(aid) || (hero_set.is_empty() && idx == 0) {
                        2
                    } else {
                        1
                    };
                    d.nodes.push(BoardNode {
                        id: Uuid::new_v4(),
                        kind: BoardNodeKind::AssetRef {
                            asset_id: *aid,
                            crop: None,
                            weight,
                            autoplay_loop: matches!(
                                asset.media_kind,
                                MediaKind::AnimatedImage | MediaKind::Video
                            ),
                        },
                        frame: BoardRect::new(
                            ((idx % 4) as f64) * 260.0 + 40.0,
                            ((idx / 4) as f64) * 240.0 + cursor_y,
                            240.0,
                            240.0 / ratio,
                        ),
                        z_index: next_order,
                        rotation_degrees: 0.0,
                        flip_horizontal: false,
                        flip_vertical: false,
                        is_locked: false,
                        editorial_order: next_order,
                        updated_at: Utc::now(),
                    });
                    next_order += 1;
                }
            }

            if !added_any {
                return Ok(ToolOutput::error(
                    "None of the provided `asset_ids` were found in the Charkle library.",
                ));
            }

            if let Some(note) = args
                .get("curator_note")
                .and_then(Value::as_str)
                .map(str::trim)
                .filter(|s| !s.is_empty())
            {
                d.nodes.push(BoardNode {
                    id: Uuid::new_v4(),
                    kind: BoardNodeKind::Note {
                        title: Some("策展说明".to_string()),
                        text: note.to_string(),
                        style: NoteStyle::Paper,
                        font_size: 13.5,
                    },
                    frame: BoardRect::new(40.0, cursor_y, 320.0, 148.0),
                    z_index: next_order,
                    rotation_degrees: 0.0,
                    flip_horizontal: false,
                    flip_vertical: false,
                    is_locked: false,
                    editorial_order: next_order,
                    updated_at: Utc::now(),
                });
            }
            d.extracted_palette = palette;
            (d, None, None)
        } else {
            let prompt = args
                .get("prompt")
                .and_then(Value::as_str)
                .map(str::trim)
                .filter(|s| !s.is_empty())
                .unwrap_or(title);
            if prompt.is_empty() {
                return Ok(ToolOutput::error(
                    "Provide `sections`/`asset_ids`, `prompt` (create), or `board_id` (patch).",
                ));
            }
            let folders = self.engine.fetch_folders()?;
            let folder_paths = build_folder_paths(&folders);
            let scope_id = self.resolve_optional_folder_id(args, &folders, &folder_paths)?;
            let preferred_count = args
                .get("preferred_count")
                .and_then(Value::as_u64)
                .unwrap_or(12)
                .clamp(2, 24) as usize;
            let target_palette: Vec<LabColor> = string_array_arg(args.get("target_palette"))
                .into_iter()
                .map(|hex| LabColor::from_hex(&hex, 1.0))
                .collect();
            let req = MoodboardCurationRequest {
                prompt: prompt.to_string(),
                seed_asset_ids: self.resolve_asset_uuid_list(args.get("seed_asset_ids"))?,
                scope_folder_ids: scope_id.into_iter().collect(),
                required_tags: string_array_arg(args.get("required_tags")),
                target_palette,
                preferred_count,
                layout_style: style,
                use_freeform_layout: use_freeform,
                include_curator_notes: true,
                ..Default::default()
            };
            let proposal = self.engine.curate_moodboard(&req, |_| {}).await?;
            let mut d = proposal.draft_document;
            if !title.is_empty() {
                d.title = title.to_string();
            }
            if !subtitle.is_empty() {
                d.subtitle = subtitle.to_string();
            }
            (
                d,
                Some(proposal.used_cloud_ai),
                Some(proposal.curated_summary),
            )
        };

        let saved = self.engine.save_board(&doc)?;
        let mut run = AgentRunRecord::new(
            "save_moodboard",
            ctx.actor_label.clone(),
            ctx.transport.as_str(),
            format!("创建情绪板「{}」", saved.title),
        );
        run.created_board_ids.push(saved.id);
        ExternalAgentStateStore::record_run(self.engine.database(), &run);

        self.notify_write("boards");
        let mut resp = Map::new();
        resp.insert("runID".into(), json!(run.id));
        resp.insert("boardID".into(), json!(format_swift_uuid(&saved.id)));
        resp.insert("title".into(), json!(saved.title));
        resp.insert("subtitle".into(), json!(saved.subtitle));
        resp.insert(
            "mode".into(),
            json!(if saved.mode.is_auto_editorial() {
                "autoEditorial"
            } else {
                "freeform"
            }),
        );
        resp.insert(
            "itemCount".into(),
            json!(saved.referenced_asset_ids().len()),
        );
        resp.insert(
            "paletteHexes".into(),
            json!(saved
                .extracted_palette
                .iter()
                .map(|c| c.hex.to_uppercase())
                .collect::<Vec<_>>()),
        );
        if let Some(cloud) = used_cloud_ai {
            resp.insert("usedCloudAI".into(), json!(cloud));
        }
        if let Some(summary) = curated_summary {
            resp.insert("curatedSummary".into(), json!(summary));
        }
        Ok(ToolOutput::json(Value::Object(resp)))
    }

    fn patch_existing_moodboard(
        &self,
        args: &Value,
        ctx: &ExternalAgentRequestContext,
    ) -> CoreResult<ToolOutput> {
        let Some(mut doc) = self.resolve_board(args)? else {
            return Ok(ToolOutput::error(
                "Moodboard not found. Pass a valid `board_id` UUID/prefix or matching `title`.",
            ));
        };
        let before_board = doc.clone();

        if let Some(new_title) = args
            .get("new_title")
            .and_then(Value::as_str)
            .map(str::trim)
            .filter(|s| !s.is_empty())
        {
            doc.title = new_title.to_string();
        }
        if let Some(sub) = args.get("subtitle").and_then(Value::as_str) {
            doc.subtitle = sub.trim().to_string();
        }
        if let Some(use_freeform) = bool_arg(args.get("use_freeform")) {
            if use_freeform {
                doc.mode = BoardLayoutMode::Freeform;
            } else {
                let style = match args.get("layout_style").and_then(Value::as_str) {
                    Some("balanced") => EditorialStyle::Balanced,
                    Some("compact") => EditorialStyle::Compact,
                    _ => EditorialStyle::Magazine,
                };
                doc.mode = BoardLayoutMode::AutoEditorial(AutoLayoutConfig {
                    columns: 4,
                    spacing: 16.0,
                    style,
                    show_palette_strip: true,
                });
            }
        }

        let remove_asset_set: HashSet<Uuid> = self
            .resolve_asset_uuid_list(args.get("remove_asset_ids"))?
            .into_iter()
            .collect();
        let remove_node_set: HashSet<Uuid> = parse_uuid_list_strict(args.get("remove_node_ids"))
            .into_iter()
            .collect();
        let mut removed_count = 0usize;
        let mut skipped_locked_assets: Vec<String> = Vec::new();
        let mut skipped_locked_nodes: Vec<String> = Vec::new();

        if !remove_asset_set.is_empty() || !remove_node_set.is_empty() {
            doc.nodes.retain(|n| {
                let matches_asset = n
                    .referenced_asset_id()
                    .is_some_and(|id| remove_asset_set.contains(&id));
                let matches_node = remove_node_set.contains(&n.id);
                if matches_asset || matches_node {
                    if n.is_locked {
                        if matches_asset {
                            if let Some(aid) = n.referenced_asset_id() {
                                skipped_locked_assets.push(format_swift_uuid(&aid));
                            }
                        }
                        if matches_node {
                            skipped_locked_nodes.push(format_swift_uuid(&n.id));
                        }
                        return true;
                    }
                    removed_count += 1;
                    return false;
                }
                true
            });
            let surviving: HashSet<Uuid> = doc.nodes.iter().map(|n| n.id).collect();
            doc.connectors.retain(|c| {
                surviving.contains(&c.from_node_id) && surviving.contains(&c.to_node_id)
            });
        }

        let mut cursor_y = doc
            .nodes
            .iter()
            .map(|n| n.frame.y + n.frame.height)
            .fold(0.0_f64, f64::max);
        if cursor_y > 0.0 {
            cursor_y += 28.0;
        } else {
            cursor_y = 40.0;
        }
        let mut next_z = doc.nodes.iter().map(|n| n.z_index).max().unwrap_or(0) + 1;
        let mut next_ord = doc
            .nodes
            .iter()
            .map(|n| n.editorial_order)
            .max()
            .unwrap_or(0)
            + 1;

        if let Some(section_title) = args
            .get("add_section")
            .and_then(Value::as_str)
            .map(str::trim)
            .filter(|s| !s.is_empty())
        {
            let tint = parse_group_tint(args.get("section_tint").and_then(Value::as_str));
            doc.nodes.push(BoardNode {
                id: Uuid::new_v4(),
                kind: BoardNodeKind::GroupFrame {
                    title: section_title.chars().take(72).collect(),
                    tint,
                },
                frame: BoardRect::new(40.0, cursor_y, 760.0, 60.0),
                z_index: next_z,
                rotation_degrees: 0.0,
                flip_horizontal: false,
                flip_vertical: false,
                is_locked: false,
                editorial_order: next_ord,
                updated_at: Utc::now(),
            });
            cursor_y += 76.0;
            next_z += 1;
            next_ord += 1;
        }

        let add_ids = self.resolve_asset_uuid_list(args.get("add_asset_ids"))?;
        let mut added_count = 0usize;
        let mut skipped_missing: Vec<String> = Vec::new();
        if !add_ids.is_empty() {
            let mut existing: HashSet<Uuid> = doc.referenced_asset_ids().into_iter().collect();
            for aid in add_ids {
                if !existing.insert(aid) {
                    continue;
                }
                let Some(asset) = self.engine.fetch_asset(aid)? else {
                    skipped_missing.push(format_swift_uuid(&aid));
                    continue;
                };
                let ratio = asset.aspect_ratio().clamp(0.6, 1.9);
                let col = (added_count % 4) as f64;
                let row = (added_count / 4) as f64;
                doc.nodes.push(BoardNode {
                    id: Uuid::new_v4(),
                    kind: BoardNodeKind::AssetRef {
                        asset_id: aid,
                        crop: None,
                        weight: 1,
                        autoplay_loop: matches!(
                            asset.media_kind,
                            MediaKind::AnimatedImage | MediaKind::Video
                        ),
                    },
                    frame: BoardRect::new(
                        40.0 + col * 260.0,
                        cursor_y + row * 240.0,
                        240.0,
                        240.0 / ratio,
                    ),
                    z_index: next_z,
                    rotation_degrees: 0.0,
                    flip_horizontal: false,
                    flip_vertical: false,
                    is_locked: false,
                    editorial_order: next_ord,
                    updated_at: Utc::now(),
                });
                added_count += 1;
                next_z += 1;
                next_ord += 1;
            }
            if added_count > 0 {
                cursor_y += (((added_count - 1) / 4) as f64 + 1.0) * 240.0 + 20.0;
            }
        }

        if let Some(note_text) = args
            .get("add_note")
            .and_then(Value::as_str)
            .map(str::trim)
            .filter(|s| !s.is_empty())
        {
            let note_title = args
                .get("note_title")
                .and_then(Value::as_str)
                .map(str::trim)
                .filter(|s| !s.is_empty())
                .unwrap_or("Agent 批注");
            let note_style = match args.get("note_style").and_then(Value::as_str) {
                Some("ink") => NoteStyle::Ink,
                Some("warm") => NoteStyle::Warm,
                Some("sage") => NoteStyle::Sage,
                Some("slate") => NoteStyle::Slate,
                _ => NoteStyle::Paper,
            };
            doc.nodes.push(BoardNode {
                id: Uuid::new_v4(),
                kind: BoardNodeKind::Note {
                    title: Some(note_title.to_string()),
                    text: note_text.to_string(),
                    style: note_style,
                    font_size: 13.5,
                },
                frame: BoardRect::new(40.0, cursor_y, 320.0, 148.0),
                z_index: next_z,
                rotation_degrees: 0.0,
                flip_horizontal: false,
                flip_vertical: false,
                is_locked: false,
                editorial_order: next_ord,
                updated_at: Utc::now(),
            });
        }

        doc.updated_at = Utc::now();
        let saved = self.engine.save_board(&doc)?;

        let mut run = AgentRunRecord::new(
            "save_moodboard",
            ctx.actor_label.clone(),
            ctx.transport.as_str(),
            format!(
                "修补情绪板「{}」（+{added_count} / -{removed_count}）",
                saved.title
            ),
        );
        run.board_snapshots.push(before_board);
        ExternalAgentStateStore::record_run(self.engine.database(), &run);

        self.notify_write("boards");
        let mut resp = Map::new();
        resp.insert("runID".into(), json!(run.id));
        resp.insert("boardID".into(), json!(format_swift_uuid(&saved.id)));
        resp.insert("title".into(), json!(saved.title));
        resp.insert(
            "mode".into(),
            json!(if saved.mode.is_auto_editorial() {
                "autoEditorial"
            } else {
                "freeform"
            }),
        );
        resp.insert(
            "itemCount".into(),
            json!(saved.referenced_asset_ids().len()),
        );
        resp.insert("addedCount".into(), json!(added_count));
        resp.insert("removedCount".into(), json!(removed_count));
        resp.insert(
            "paletteHexes".into(),
            json!(saved
                .extracted_palette
                .iter()
                .map(|c| c.hex.to_uppercase())
                .collect::<Vec<_>>()),
        );
        if !skipped_locked_assets.is_empty() {
            resp.insert("skippedLockedAssetIDs".into(), json!(skipped_locked_assets));
        }
        if !skipped_locked_nodes.is_empty() {
            resp.insert("skippedLockedNodeIDs".into(), json!(skipped_locked_nodes));
        }
        if !skipped_missing.is_empty() {
            resp.insert("skippedMissingAssetIDs".into(), json!(skipped_missing));
        }
        Ok(ToolOutput::json(Value::Object(resp)))
    }

    // =========================================================================
    // Tool 9: deduplicate_assets (Deterministic Scan + Safe Soft-Trash Merge)
    // =========================================================================

    async fn handle_deduplicate_assets(
        &self,
        args: &Value,
        effective_access: ExternalAgentAccessLevel,
        ctx: &ExternalAgentRequestContext,
    ) -> CoreResult<ToolOutput> {
        let action = args
            .get("action")
            .and_then(Value::as_str)
            .map(|s| s.trim().to_ascii_lowercase())
            .unwrap_or_else(|| "scan".to_string());

        match action.as_str() {
            "scan" => {
                let folders = self.engine.fetch_folders()?;
                let folder_paths = build_folder_paths(&folders);
                let scope_raw = args
                    .get("scope")
                    .and_then(Value::as_str)
                    .map(|s| s.trim().to_ascii_lowercase())
                    .unwrap_or_else(|| "all".to_string());
                let scope = if scope_raw == "inbox" {
                    DeduplicationScanScope::Inbox
                } else if scope_raw == "folder" {
                    let Some(fid) =
                        self.resolve_optional_folder_id(args, &folders, &folder_paths)?
                    else {
                        return Ok(ToolOutput::error(
                            "scope:'folder' requires a valid `folder_id` or `folder_path`.",
                        ));
                    };
                    let inc_sub = bool_arg(args.get("include_subfolders")).unwrap_or(true);
                    DeduplicationScanScope::Folder {
                        folder_id: fid,
                        include_subfolders: inc_sub,
                    }
                } else {
                    DeduplicationScanScope::AllActive
                };
                let sensitivity = match args
                    .get("sensitivity")
                    .and_then(Value::as_str)
                    .map(|s| s.trim().to_ascii_lowercase())
                    .as_deref()
                {
                    Some("strict") => DeduplicationSensitivity::Strict,
                    Some("relaxed") => DeduplicationSensitivity::Relaxed,
                    _ => DeduplicationSensitivity::Balanced,
                };
                let kinds_set = parse_media_kinds(args.get("media_kinds"));
                let kinds_opt = if kinds_set.is_empty() {
                    None
                } else {
                    Some(kinds_set.into_iter().collect::<Vec<_>>())
                };
                let limit = args
                    .get("limit")
                    .and_then(Value::as_u64)
                    .unwrap_or(6)
                    .clamp(1, 20) as usize;
                let want_sheet = bool_arg(args.get("contact_sheet")).unwrap_or(false);

                let report = self
                    .engine
                    .scan_duplicates(scope, sensitivity, kinds_opt)
                    .await?;

                let top_groups: Vec<_> = report.groups.iter().take(limit).collect();
                let mut sheet_assets: Vec<AssetRecord> = Vec::new();
                let mut slot_by_id: HashMap<Uuid, usize> = HashMap::new();
                if want_sheet {
                    for g in &top_groups {
                        for cand in &g.candidates {
                            if sheet_assets.len() >= CONTACT_SHEET_MAX_ASSETS {
                                break;
                            }
                            slot_by_id.entry(cand.asset.id).or_insert_with(|| {
                                sheet_assets.push(cand.asset.clone());
                                sheet_assets.len()
                            });
                        }
                    }
                }

                let serialized_groups: Vec<Value> = top_groups
                    .iter()
                    .enumerate()
                    .map(|(idx, g)| {
                        let candidates: Vec<Value> = g
                            .candidates
                            .iter()
                            .map(|cand| {
                                let full_id = format_swift_uuid(&cand.asset.id);
                                let mut c = Map::new();
                                c.insert("id".into(), json!(&full_id[..8]));
                                c.insert("fullID".into(), json!(full_id));
                                c.insert("title".into(), json!(cand.asset.title));
                                c.insert(
                                    "folderPath".into(),
                                    json!(cand
                                        .asset
                                        .folder_id
                                        .and_then(|fid| folder_paths.get(&fid).cloned())
                                        .unwrap_or_else(|| "Inbox".to_string())),
                                );
                                c.insert("format".into(), json!(cand.format_label));
                                c.insert("fileSizeBytes".into(), json!(cand.asset.file_size_bytes));
                                c.insert(
                                    "qualityScore".into(),
                                    json!((cand.quality_score * 100.0).round() / 100.0),
                                );
                                c.insert(
                                    "isRecommendedKeep".into(),
                                    json!(cand.is_recommended_keep),
                                );
                                c.insert(
                                    "isReferencedByBoard".into(),
                                    json!(cand.is_referenced_by_board),
                                );
                                c.insert("qualityReasons".into(), json!(cand.quality_reasons));
                                if cand.asset.pixel_width > 0 && cand.asset.pixel_height > 0 {
                                    c.insert(
                                        "dimensions".into(),
                                        json!(format!(
                                            "{}x{}",
                                            cand.asset.pixel_width, cand.asset.pixel_height
                                        )),
                                    );
                                }
                                if let Some(&slot) = slot_by_id.get(&cand.asset.id) {
                                    c.insert("slot".into(), json!(slot));
                                    c.insert("badge".into(), json!(format!("#{slot:02}")));
                                }
                                Value::Object(c)
                            })
                            .collect();
                        let keep_full = format_swift_uuid(&g.recommended_keep_asset_id);
                        json!({
                            "groupIndex": idx + 1,
                            "matchKind": serde_json::to_value(g.match_kind).unwrap_or(json!("nearIdentical")),
                            "similarity": (g.similarity_score * 1000.0).round() / 1000.0,
                            "recommendedKeepID": &keep_full[..8],
                            "reclaimableBytes": g.reclaimable_bytes,
                            "candidates": candidates
                        })
                    })
                    .collect();

                let mut payload = Map::new();
                payload.insert(
                    "scannedAssetCount".into(),
                    json!(report.scanned_asset_count),
                );
                payload.insert("totalGroups".into(), json!(report.groups.len()));
                payload.insert("returnedGroups".into(), json!(serialized_groups.len()));
                payload.insert(
                    "totalDuplicateItems".into(),
                    json!(report.total_duplicate_items),
                );
                payload.insert(
                    "totalReclaimableBytes".into(),
                    json!(report.total_reclaimable_bytes),
                );
                payload.insert("groups".into(), json!(serialized_groups));

                if want_sheet && !sheet_assets.is_empty() {
                    let max_width = args
                        .get("sheet_max_width")
                        .and_then(Value::as_u64)
                        .unwrap_or(CONTACT_SHEET_DEFAULT_WIDTH as u64)
                        as u32;
                    if let Some(attached) =
                        self.render_attached_contact_sheet(&sheet_assets, max_width, 76)?
                    {
                        payload.insert("contactSheet".into(), attached.summary());
                        return Ok(ToolOutput {
                            content: vec![
                                ToolContent::Image {
                                    mime_type: "image/jpeg".to_string(),
                                    data: attached.jpeg_bytes,
                                },
                                ToolContent::Text(
                                    serde_json::to_string(&Value::Object(payload))
                                        .unwrap_or_default(),
                                ),
                            ],
                            is_error: false,
                        });
                    }
                }
                Ok(ToolOutput::json(Value::Object(payload)))
            }
            "merge" => {
                if !effective_access.allows_global_organize_writes() {
                    return Ok(ToolOutput::error(format!(
                        "当前权限为「{}」，合并去重需要「全局整理与生板」权限。",
                        effective_access.display_title()
                    )));
                }
                let Some(raw_groups) = args
                    .get("groups")
                    .and_then(Value::as_array)
                    .filter(|a| !a.is_empty())
                else {
                    return Ok(ToolOutput::error(
                        "Provide non-empty `groups: [{keep_asset_id, discard_asset_ids}]` for deduplicate_assets(action:'merge').",
                    ));
                };
                let dry_run = bool_arg(args.get("dry_run")).unwrap_or(false);

                let mut plans: Vec<DeduplicationResolutionPlan> = Vec::new();
                let mut all_touched: HashSet<Uuid> = HashSet::new();
                let mut all_discarded: HashSet<Uuid> = HashSet::new();

                for (idx, g) in raw_groups.iter().take(20).enumerate() {
                    let Some(keep_raw) = g.get("keep_asset_id").and_then(Value::as_str) else {
                        return Ok(ToolOutput::error(format!(
                            "groups[{idx}] has missing `keep_asset_id`."
                        )));
                    };
                    let keep_uuid = self.resolve_asset_uuid(keep_raw)?;
                    let discard_uuids: Vec<Uuid> = self
                        .resolve_asset_uuid_list(g.get("discard_asset_ids"))?
                        .into_iter()
                        .filter(|id| *id != keep_uuid)
                        .collect();
                    if discard_uuids.is_empty() {
                        return Ok(ToolOutput::error(format!(
                            "groups[{idx}] has no valid `discard_asset_ids` distinct from `keep_asset_id`."
                        )));
                    }
                    all_touched.insert(keep_uuid);
                    for &did in &discard_uuids {
                        all_touched.insert(did);
                        all_discarded.insert(did);
                    }
                    plans.push(DeduplicationResolutionPlan {
                        keep_asset_id: keep_uuid,
                        remove_asset_ids: discard_uuids,
                    });
                }

                if dry_run {
                    return Ok(ToolOutput::json(json!({
                        "dryRun": true,
                        "plannedGroups": plans.len(),
                        "discardToTrashCount": all_discarded.len(),
                        "disposal": "moveToTrash",
                        "mergeMetadata": true
                    })));
                }

                let mut asset_snapshots = Vec::new();
                for aid in &all_touched {
                    if let Some(asset) = self.engine.fetch_asset(*aid)? {
                        asset_snapshots.push(AgentAssetSnapshot::from(&asset));
                    }
                }
                let all_boards = self.engine.database().fetch_boards()?;
                let affected_boards: Vec<MoodboardDocument> = all_boards
                    .into_iter()
                    .filter(|b| {
                        let refs: HashSet<Uuid> = b
                            .referenced_asset_ids()
                            .into_iter()
                            .chain(b.candidate_asset_ids.iter().copied())
                            .collect();
                        !refs.is_disjoint(&all_discarded)
                    })
                    .collect();

                // Non-negotiable safety invariant: ALWAYS `MoveToTrash` (never permanent delete)!
                let cleanup = self.engine.resolve_duplicate_groups(
                    &plans,
                    DuplicateDisposalMode::MoveToTrash,
                    true,
                )?;

                let mut run = AgentRunRecord::new(
                    "deduplicate_assets",
                    ctx.actor_label.clone(),
                    ctx.transport.as_str(),
                    format!(
                        "去重合并 {} 组（{} 项移入回收站）",
                        cleanup.resolved_group_count, cleanup.removed_asset_count
                    ),
                );
                run.asset_snapshots = asset_snapshots;
                run.board_snapshots = affected_boards;
                ExternalAgentStateStore::record_run(self.engine.database(), &run);

                self.notify_write("assets");
                Ok(ToolOutput::json(json!({
                    "runID": run.id,
                    "resolvedGroupCount": cleanup.resolved_group_count,
                    "movedToTrashCount": cleanup.removed_asset_count,
                    "reclaimedBytes": cleanup.reclaimed_bytes,
                    "mergedMetadataCount": cleanup.merged_metadata_count,
                    "updatedBoardCount": cleanup.updated_board_count,
                    "note": "Discarded duplicates moved to reversible soft Trash; metadata and Moodboard references preserved."
                })))
            }
            _ => Ok(ToolOutput::error(
                "Invalid `action` for deduplicate_assets. Expected 'scan' or 'merge'.",
            )),
        }
    }

    // =========================================================================
    // Tool 10: rollback_run (Audit Listing + Atomic Compensating HLC Rollback)
    // =========================================================================

    fn handle_rollback_run(
        &self,
        args: &Value,
        effective_access: ExternalAgentAccessLevel,
        _ctx: &ExternalAgentRequestContext,
    ) -> CoreResult<ToolOutput> {
        let action = args
            .get("action")
            .and_then(Value::as_str)
            .map(|s| s.trim().to_ascii_lowercase())
            .unwrap_or_else(|| "list".to_string());

        match action.as_str() {
            "list" => {
                let limit = args
                    .get("limit")
                    .and_then(Value::as_u64)
                    .unwrap_or(15)
                    .clamp(1, 30) as usize;
                let runs = ExternalAgentStateStore::list_runs(self.engine.database(), limit);
                let items: Vec<Value> = runs
                    .iter()
                    .map(|r| {
                        let mut entry = Map::new();
                        entry.insert("runID".into(), json!(r.id));
                        entry.insert("toolName".into(), json!(r.tool_name));
                        entry.insert("actor".into(), json!(r.actor));
                        entry.insert("transport".into(), json!(r.transport));
                        entry.insert("summary".into(), json!(r.summary));
                        entry.insert("affectedCount".into(), json!(r.affected_count()));
                        entry.insert("createdAt".into(), json!(r.created_at.to_rfc3339()));
                        entry.insert("isRolledBack".into(), json!(r.is_rolled_back()));
                        if let Some(rolled) = r.rolled_back_at {
                            entry.insert("rolledBackAt".into(), json!(rolled.to_rfc3339()));
                        }
                        Value::Object(entry)
                    })
                    .collect();
                Ok(ToolOutput::json(json!({
                    "count": items.len(),
                    "runs": items
                })))
            }
            "rollback" => {
                if !effective_access.allows_inbox_and_enrich_writes() {
                    return Ok(ToolOutput::error(
                        "当前权限为「仅只读」，无法执行回滚操作。",
                    ));
                }
                let run_id = args
                    .get("run_id")
                    .and_then(Value::as_str)
                    .map(str::trim)
                    .unwrap_or("");
                if run_id.is_empty() {
                    return Ok(ToolOutput::error(
                        "Missing `run_id` for rollback_run(action:'rollback'). Call rollback_run(action:'list') first.",
                    ));
                }
                let Some(run) = ExternalAgentStateStore::load_run(self.engine.database(), run_id)
                else {
                    return Ok(ToolOutput::error(format!("Agent run not found: {run_id}")));
                };
                if run.is_rolled_back() {
                    return Ok(ToolOutput::error(format!(
                        "Run {} has already been rolled back.",
                        run.id
                    )));
                }
                let requires_global = !run.folder_snapshots.is_empty()
                    || !run.board_snapshots.is_empty()
                    || run
                        .asset_snapshots
                        .iter()
                        .any(|s| s.folder_id.is_some() || s.is_trashed);
                if requires_global && !effective_access.allows_global_organize_writes() {
                    return Ok(ToolOutput::error(format!(
                        "回滚批次 {} 涉及已归档目录、文件夹或情绪板，需要「全局整理与生板」权限。",
                        run.id
                    )));
                }

                // 1. Restore modified assets via compensating HLC sync ops
                let mut restored_asset_count = 0usize;
                for snap in &run.asset_snapshots {
                    if let Some(mut asset) = self.engine.fetch_asset(snap.asset_id)? {
                        asset.title = snap.title.clone();
                        asset.notes = snap.notes.clone();
                        asset.ai_description = snap.ai_description.clone();
                        asset.rating = snap.rating;
                        asset.tags = snap.tags.clone();
                        asset.suggested_tags = snap.suggested_tags.clone();
                        asset.folder_id = snap.folder_id;
                        asset.pinned_offline = snap.pinned_offline;
                        asset.is_trashed = snap.is_trashed;
                        let _ = self.engine.database().save_asset_locally(&asset, true)?;
                        restored_asset_count += 1;
                    }
                }

                // 2. Soft-trash newly ingested assets (never permanent delete)
                let mut soft_trashed_ingested_count = 0usize;
                if !run.ingested_asset_ids.is_empty() {
                    let trashed = self.engine.update_assets(&AssetBatchPatch {
                        asset_ids: run.ingested_asset_ids.clone(),
                        is_trashed: Some(true),
                        ..Default::default()
                    })?;
                    soft_trashed_ingested_count = trashed.len();
                }

                // 3. Restore updated folders
                let mut restored_folder_count = 0usize;
                for f_snap in &run.folder_snapshots {
                    let _ = self.engine.rename_folder(f_snap.folder_id, &f_snap.name);
                    let _ = self
                        .engine
                        .move_folder(f_snap.folder_id, f_snap.parent_id, None);
                    let _ = self.engine.update_folder_appearance(
                        f_snap.folder_id,
                        f_snap.color_hex.clone(),
                        f_snap.custom_symbol.clone(),
                    );
                    restored_folder_count += 1;
                }

                // 4. Restore patched boards
                let mut restored_board_count = 0usize;
                for mut board_snap in run.board_snapshots.clone() {
                    board_snap.updated_at = Utc::now();
                    let _ = self.engine.save_board(&board_snap)?;
                    restored_board_count += 1;
                }

                ExternalAgentStateStore::mark_run_rolled_back(self.engine.database(), &run.id);
                self.notify_write("assets");

                let mut result = Map::new();
                result.insert("rolledBackRunID".into(), json!(run.id));
                result.insert("originalTool".into(), json!(run.tool_name));
                result.insert("restoredAssetCount".into(), json!(restored_asset_count));
                result.insert(
                    "softTrashedIngestedCount".into(),
                    json!(soft_trashed_ingested_count),
                );
                result.insert("restoredFolderCount".into(), json!(restored_folder_count));
                result.insert("restoredBoardCount".into(), json!(restored_board_count));
                if !run.created_board_ids.is_empty() {
                    result.insert(
                        "unremovedCreatedBoardIDs".into(),
                        json!(run
                            .created_board_ids
                            .iter()
                            .map(format_swift_uuid)
                            .collect::<Vec<_>>()),
                    );
                    result.insert(
                        "note".into(),
                        json!("Newly created Moodboards are preserved (hard delete disabled via MCP); delete manually in Charkle if unwanted."),
                    );
                }
                Ok(ToolOutput::json(Value::Object(result)))
            }
            _ => Ok(ToolOutput::error(
                "Invalid `action` for rollback_run. Expected 'list' or 'rollback'.",
            )),
        }
    }

    // =========================================================================
    // Shared Board / Criteria Resolvers
    // =========================================================================

    fn resolve_board(&self, args: &Value) -> CoreResult<Option<MoodboardDocument>> {
        if let Some(raw_id) = args
            .get("board_id")
            .or_else(|| args.get("id"))
            .and_then(Value::as_str)
            .map(str::trim)
            .filter(|s| !s.is_empty())
        {
            let uuid = self.resolve_board_uuid(raw_id)?;
            return self.engine.fetch_board(uuid);
        }
        if let Some(title) = args
            .get("title")
            .and_then(Value::as_str)
            .map(str::trim)
            .filter(|s| !s.is_empty())
        {
            let boards = self.engine.fetch_boards()?;
            if let Some(exact) = boards.iter().find(|b| b.title.eq_ignore_ascii_case(title)) {
                return self.engine.fetch_board(exact.id);
            }
            let lower = title.to_ascii_lowercase();
            if let Some(partial) = boards
                .iter()
                .find(|b| b.title.to_ascii_lowercase().contains(&lower))
            {
                return self.engine.fetch_board(partial.id);
            }
        }
        Ok(None)
    }

    fn build_filter_criteria(
        &self,
        args: &Value,
        folders: &[FolderRecord],
        folder_paths: &HashMap<Uuid, String>,
    ) -> CoreResult<FilterCriteria> {
        let query = args
            .get("query")
            .and_then(Value::as_str)
            .unwrap_or("")
            .trim()
            .to_string();
        let tags: BTreeSet<String> = string_array_arg(args.get("tags")).into_iter().collect();
        let kinds = parse_media_kinds(args.get("media_kinds"));
        let shape = args
            .get("aspect_shape")
            .and_then(Value::as_str)
            .and_then(|s| serde_json::from_value::<AspectShape>(Value::String(s.to_string())).ok());
        let color_hex = args
            .get("color_hex")
            .and_then(Value::as_str)
            .map(str::trim)
            .filter(|s| !s.is_empty())
            .map(ToOwned::to_owned);
        let color_tolerance = args
            .get("color_tolerance")
            .and_then(Value::as_f64)
            .unwrap_or(28.0);
        let min_rating = args
            .get("min_rating")
            .and_then(Value::as_i64)
            .unwrap_or(0)
            .clamp(0, 5) as i32;
        let only_inbox = bool_arg(args.get("only_inbox")).unwrap_or(false);
        let only_untagged = bool_arg(args.get("only_untagged")).unwrap_or(false);
        let include_subfolders = bool_arg(args.get("include_subfolders")).unwrap_or(true);
        let only_recent_days = args
            .get("only_recent_days")
            .and_then(Value::as_i64)
            .map(|d| d.max(1) as i32);
        let only_pinned_offline = bool_arg(args.get("only_pinned_offline")).unwrap_or(false);
        let only_trashed = bool_arg(args.get("only_trashed")).unwrap_or(false);
        let include_trashed = bool_arg(args.get("include_trashed")).unwrap_or(false);
        let sort_by = parse_sort_order(
            args.get("sort_by").and_then(Value::as_str),
            !query.is_empty(),
        );
        let folder_id = if only_inbox {
            None
        } else {
            self.resolve_optional_folder_id(args, folders, folder_paths)?
        };
        Ok(FilterCriteria {
            search_query: query,
            kinds,
            selected_color_hex: color_hex,
            color_tolerance,
            shape,
            min_rating,
            tags,
            folder_id,
            include_subfolders,
            only_inbox,
            only_untagged,
            only_recent_days,
            only_pinned_offline,
            include_trashed,
            only_trashed,
            sort_by,
        })
    }

    // =========================================================================
    // Pure MCP v2 Resources (5+2), Prompts (5) & Lean 10-Tool Schema (< 12 KB)
    // =========================================================================

    pub fn mcp_resource_definitions() -> Vec<Value> {
        vec![
            json!({
                "uri": "charkle://library/overview",
                "name": "Library Overview Atlas",
                "description": "Counts, compact folder semantic profiles (recursive counts, topTags, palettes), smart folders, top tags, aspect/media mix, boards, taxonomy, and permissions.",
                "mimeType": "application/json"
            }),
            json!({
                "uri": "charkle://library/taxonomy",
                "name": "Library Taxonomy & Curation Policy",
                "description": "User's canonical tag language, tag aliases, folder inclusion guidelines, rating meanings, and top canonical tags.",
                "mimeType": "application/json"
            }),
            json!({
                "uri": "charkle://boards",
                "name": "Moodboards",
                "description": "All moodboards with IDs, titles, layout modes, item counts, and palettes.",
                "mimeType": "application/json"
            }),
            json!({
                "uri": "charkle://folders",
                "name": "Folder Tree & Profiles",
                "description": "Hierarchical folder tree with UUIDs, paths, recursive counts, top tags, and palettes.",
                "mimeType": "application/json"
            }),
            json!({
                "uri": "charkle://smart-folders",
                "name": "Smart Folders",
                "description": "Saved rule-based smart folders with match counts.",
                "mimeType": "application/json"
            }),
        ]
    }

    pub fn mcp_resource_template_definitions() -> Vec<Value> {
        vec![
            json!({
                "uriTemplate": "charkle://assets/{asset_id}",
                "name": "Asset Details",
                "description": "Full metadata for an asset UUID or 8+ char prefix (EXIF, AI prompts, social/GitHub, palette, OCR).",
                "mimeType": "application/json"
            }),
            json!({
                "uriTemplate": "charkle://boards/{board_id}",
                "name": "Moodboard Context",
                "description": "Structured context for a Moodboard UUID or 8+ char prefix (notes, sections, connectors, palette, referenced assets).",
                "mimeType": "application/json"
            }),
        ]
    }

    pub fn mcp_prompt_definitions() -> Vec<Value> {
        vec![
            json!({
                "name": "triage_inbox",
                "description": "Inspect Inbox assets with inline Contact Sheet + folder suggestions in 1 call, preview plan via dry_run, then batch-organize atomically.",
                "arguments": [
                    { "name": "limit", "description": "Inbox items per batch (default 16).", "required": false },
                    { "name": "apply_changes", "description": "'true' to commit organize_assets immediately; otherwise dry_run preview first.", "required": false }
                ]
            }),
            json!({
                "name": "curate_moodboard",
                "description": "Token-efficient grounded curation: orient via library_overview, recall diversified multi-direction Contact Sheet in 1 query_assets call, save structured Moodboard.",
                "arguments": [
                    { "name": "brief", "description": "Creative direction, style, mood, or color brief.", "required": true },
                    { "name": "folder_path", "description": "Optional folder path scope.", "required": false },
                    { "name": "count", "description": "Target references (default 10).", "required": false }
                ]
            }),
            json!({
                "name": "deduplicate_library",
                "description": "Scan deterministic duplicate groups with side-by-side Contact Sheet, visually pick the cleanest master per group, and merge losslessly to soft Trash.",
                "arguments": [
                    { "name": "scope", "description": "'all', 'inbox', or 'folder' (default 'all').", "required": false },
                    { "name": "folder_path", "description": "Folder path when scope='folder'.", "required": false }
                ]
            }),
            json!({
                "name": "extract_design_tokens",
                "description": "Read a Moodboard's palette, notes, sections, and visual snapshot in 1 get_board call to generate structured design tokens.",
                "arguments": [
                    { "name": "board", "description": "Moodboard title or UUID.", "required": true },
                    { "name": "format", "description": "'css', 'tailwind', 'swiftui', or 'json' (default 'css').", "required": false }
                ]
            }),
            json!({
                "name": "inspect_ai_prompts",
                "description": "Find AI-generated references and batch-inspect their embedded prompts, models, samplers, seeds, and LoRAs.",
                "arguments": [
                    { "name": "query", "description": "Optional keyword, model, or style filter.", "required": false },
                    { "name": "limit", "description": "Max assets to inspect (default 12).", "required": false }
                ]
            }),
        ]
    }

    pub fn render_prompt(name: &str, args: &Value) -> Option<Value> {
        let str_arg = |key: &str| {
            args.get(key)
                .and_then(Value::as_str)
                .unwrap_or("")
                .trim()
                .to_string()
        };
        match name {
            "triage_inbox" => {
                let limit = {
                    let s = str_arg("limit");
                    if s.is_empty() {
                        "16".to_string()
                    } else {
                        s
                    }
                };
                let apply = str_arg("apply_changes").eq_ignore_ascii_case("true");
                let action = if apply {
                    "Commit in ONE call via `organize_assets(items: [...])` (8-char IDs ok; reuse existing folders/tags; put uncertain tags in `add_suggested_tags`) and share the returned `runID` so the user can rollback anytime."
                } else {
                    "Call `organize_assets(items: [...], dry_run: true)` first and present the concise change summary for user confirmation before committing."
                };
                Some(json!({
                    "description": "Triage untriaged Inbox assets in Charkle",
                    "messages": [{
                        "role": "user",
                        "content": {
                            "type": "text",
                            "text": format!(
                                "Triage up to {limit} Inbox assets in Charkle (low-token MCP v2 workflow):\n1. Call `library_overview` to inspect folder profiles (`topTags`, `palette`), canonical tags, and `taxonomy`.\n2. Call `query_assets` with `only_inbox: true, limit: {limit}, contact_sheet: true, include_folder_suggestions: true` to see thumbnails, short IDs, and folder recommendations in ONE call.\n3. Reuse existing folders and canonical tags; leave truly off-taxonomy items in Inbox instead of misfiling.\n4. {action}"
                            )
                        }
                    }]
                }))
            }
            "curate_moodboard" => {
                let brief = {
                    let s = str_arg("brief");
                    if s.is_empty() {
                        "curated visual moodboard".to_string()
                    } else {
                        s
                    }
                };
                let count = {
                    let s = str_arg("count");
                    if s.is_empty() {
                        "10".to_string()
                    } else {
                        s
                    }
                };
                let folder = str_arg("folder_path");
                let scope = if folder.is_empty() {
                    "Pick best matching folder(s) from `library_overview` folder profiles."
                        .to_string()
                } else {
                    format!("Scope to folder `{folder}` (subfolders included by default).")
                };
                Some(json!({
                    "description": "Curate a grounded Charkle Moodboard",
                    "messages": [{
                        "role": "user",
                        "content": {
                            "type": "text",
                            "text": format!(
                                "Curate a Charkle Moodboard for: \"{brief}\" (target ~{count} assets):\n1. Call `library_overview` to read folder semantic profiles and existing boards.\n2. {scope} Call `query_assets` with `queries: [...]` (or `query`), `diversify: true, contact_sheet: true, session_id: \"curate-1\"` to inspect distinct candidates in ONE Contact Sheet.\n3. For round 2 refinement, call `query_assets` with the same `session_id` (auto-skips seen items) plus `seed_asset_ids` (more like) and `unlike_asset_ids` (less like).\n4. Inspect finalists via `inspect_assets(asset_ids:[...])` only if needed, then call `save_moodboard` with 2-3 `sections`, `hero_asset_ids`, and a concise `curator_note`."
                            )
                        }
                    }]
                }))
            }
            "deduplicate_library" => {
                let scope = {
                    let s = str_arg("scope");
                    if s.is_empty() {
                        "all".to_string()
                    } else {
                        s
                    }
                };
                let folder = str_arg("folder_path");
                let folder_clause = if folder.is_empty() {
                    String::new()
                } else {
                    format!(", folder_path: \"{folder}\"")
                };
                Some(json!({
                    "description": "Scan and visually resolve duplicate assets in Charkle",
                    "messages": [{
                        "role": "user",
                        "content": {
                            "type": "text",
                            "text": format!(
                                "Review duplicate candidates in Charkle safely:\n1. Call `deduplicate_assets(action: \"scan\", scope: \"{scope}\"{folder_clause}, contact_sheet: true, limit: 6)`.\n2. Visually inspect the side-by-side Contact Sheet to verify which candidate in each group is cleanest (highest resolution, unwatermarked, uncropped).\n3. Call `deduplicate_assets(action: \"merge\", groups: [...], dry_run: true)` first, confirm with the user, then commit (`dry_run: false` moves duplicates to reversible soft Trash and merges tags/board refs losslessly)."
                            )
                        }
                    }]
                }))
            }
            "extract_design_tokens" => {
                let board = str_arg("board");
                let format_name = {
                    let s = str_arg("format");
                    if s.is_empty() {
                        "css".to_string()
                    } else {
                        s
                    }
                };
                let board_step = if board.is_empty() {
                    "Call `get_board` with no arguments to list boards, then call `get_board(board_id: ..., include_snapshot: true, snapshot_width: 1200)`.".to_string()
                } else {
                    format!("Call `get_board(title: \"{board}\", include_snapshot: true, snapshot_width: 1200)`.")
                };
                Some(json!({
                    "description": "Extract design tokens from a Charkle Moodboard",
                    "messages": [{
                        "role": "user",
                        "content": {
                            "type": "text",
                            "text": format!(
                                "Extract production-ready `{format_name}` design tokens from my Charkle Moodboard:\n1. {board_step}\n2. Read the harmonized HEX/CIELAB palette, curator notes, sections, and visual snapshot.\n3. Output semantic tokens (surface, ink, accent, muted, borders, typography/spacing cues) in `{format_name}`."
                            )
                        }
                    }]
                }))
            }
            "inspect_ai_prompts" => {
                let query = str_arg("query");
                let limit = {
                    let s = str_arg("limit");
                    if s.is_empty() {
                        "12".to_string()
                    } else {
                        s
                    }
                };
                let search_step = if query.is_empty() {
                    format!("Call `query_assets(media_kinds: [\"image\"], limit: {limit})`.")
                } else {
                    format!(
                        "Call `query_assets(query: \"{query}\", media_kinds: [\"image\"], limit: {limit})`."
                    )
                };
                Some(json!({
                    "description": "Inspect embedded AI generation prompts and parameters",
                    "messages": [{
                        "role": "user",
                        "content": {
                            "type": "text",
                            "text": format!(
                                "Inspect AI-generated references in Charkle:\n1. {search_step}\n2. Batch-call `inspect_assets(asset_ids: [...])` (up to 12 at once) to read `richMetadata.aiGeneration`.\n3. Summarize recurring prompt patterns, model/LoRA recipes, and parameter differences."
                            )
                        }
                    }]
                }))
            }
            _ => None,
        }
    }

    pub fn mcp_tool_definitions() -> Vec<Value> {
        let str_arr = json!({ "type": "array", "items": { "type": "string" } });
        let detail_enum =
            json!({ "type": "string", "enum": ["visual", "compact", "standard", "full"] });
        let sort_enum = json!({ "type": "string", "enum": ["newest", "oldest", "name_asc", "rating_desc", "file_size_desc", "relevance"] });
        let shape_enum =
            json!({ "type": "string", "enum": ["portrait", "landscape", "square", "panoramic"] });
        let media_kind_arr = json!({
            "type": "array",
            "items": {
                "type": "string",
                "enum": ["image", "animatedImage", "video", "audio", "document", "designFile", "model3D", "webBookmark"]
            }
        });

        vec![
            // Read Tools (4)
            tool_def(
                "library_overview",
                "Library Overview Atlas",
                "Library atlas: counts, compact folder profiles (8-char id, path, topTags, palette), smartFolders, topTags, taxonomy, boards, permissions. Call first.",
                json!({
                    "type": "object",
                    "properties": {
                        "compact": { "type": "boolean" },
                        "include_folder_profiles": { "type": "boolean" },
                        "include_boards": { "type": "boolean" },
                        "top_tags_limit": { "type": "integer" }
                    }
                }),
                true,
                true,
                false,
            ),
            tool_def(
                "query_assets",
                "Query & Visual Contact Sheet",
                "6-in-1 recall + numbered Contact Sheet (#01..#24): text/semantic `query` or `queries[]`, Inbox, folder, tags, CIELAB `tone`, `seed_asset_ids`/`unlike_asset_ids`, `diversify`, `include_folder_suggestions`, `session_id`. Accepts 8-char IDs.",
                {
                    let str_t = json!({ "type": "string" });
                    let bool_t = json!({ "type": "boolean" });
                    let int_t = json!({ "type": "integer" });
                    let num_t = json!({ "type": "number" });
                    let mut props = Map::new();
                    for k in [
                        "query",
                        "folder_id",
                        "folder_path",
                        "smart_folder_id",
                        "smart_folder_name",
                        "color_hex",
                        "tone",
                        "session_id",
                    ] {
                        props.insert(k.to_string(), str_t.clone());
                    }
                    for k in [
                        "queries",
                        "asset_ids",
                        "tags",
                        "any_tags",
                        "exclude_tags",
                        "exclude_asset_ids",
                        "seed_asset_ids",
                        "unlike_asset_ids",
                    ] {
                        props.insert(k.to_string(), str_arr.clone());
                    }
                    for k in [
                        "include_subfolders",
                        "only_inbox",
                        "only_untagged",
                        "only_pinned_offline",
                        "only_trashed",
                        "include_trashed",
                        "visual_rerank",
                        "diversify",
                        "contact_sheet",
                        "include_folder_suggestions",
                        "include_facets",
                        "reset_session",
                    ] {
                        props.insert(k.to_string(), bool_t.clone());
                    }
                    for k in [
                        "min_rating",
                        "only_recent_days",
                        "sheet_max_width",
                        "offset",
                        "limit",
                    ] {
                        props.insert(k.to_string(), int_t.clone());
                    }
                    props.insert("media_kinds".to_string(), media_kind_arr.clone());
                    props.insert("aspect_shape".to_string(), shape_enum.clone());
                    props.insert("color_tolerance".to_string(), num_t);
                    props.insert("sort_by".to_string(), sort_enum.clone());
                    props.insert("detail".to_string(), detail_enum.clone());
                    json!({ "type": "object", "properties": Value::Object(props) })
                },
                true,
                true,
                true,
            ),
            tool_def(
                "inspect_assets",
                "Inspect Finalist Assets",
                "Full metadata (EXIF, AI prompts, social/GitHub, OCR, palette) for 1-12 assets. Supports `include_image`, normalized `crop_box` zoom, and `include_download_url`.",
                json!({
                    "type": "object",
                    "properties": {
                        "asset_id": { "type": "string" },
                        "asset_ids": str_arr,
                        "include_image": { "type": "boolean" },
                        "image_max_side": { "type": "integer" },
                        "crop_box": {
                            "type": "object",
                            "properties": {
                                "x": { "type": "number" },
                                "y": { "type": "number" },
                                "width": { "type": "number" },
                                "height": { "type": "number" }
                            }
                        },
                        "include_download_url": { "type": "boolean" }
                    }
                }),
                true,
                true,
                false,
            ),
            tool_def(
                "get_board",
                "Get Moodboard or List Boards",
                "Omit `board_id`/`title` to list boards; pass either for full context (notes, sections, frames, connectors, palette, assets) and optional inline PNG `include_snapshot`.",
                json!({
                    "type": "object",
                    "properties": {
                        "board_id": { "type": "string" },
                        "title": { "type": "string" },
                        "detail": detail_enum,
                        "include_snapshot": { "type": "boolean" },
                        "snapshot_width": { "type": "integer" },
                        "dark_appearance": { "type": "boolean" }
                    }
                }),
                true,
                true,
                false,
            ),
            // Safe Write Tools (6 — Zero Permanent Delete, All Emit `runID`)
            tool_def(
                "ingest_assets",
                "Ingest Assets (Remote & Local)",
                "Import `web_url(s)`, remote `inline_files` (base64), `text`, or local `file_path(s)` (stdio only). Allowed in `inboxAndEnrich`+; emits `runID`.",
                json!({
                    "type": "object",
                    "properties": {
                        "web_url": { "type": "string" },
                        "web_urls": str_arr,
                        "inline_files": {
                            "type": "array",
                            "items": {
                                "type": "object",
                                "properties": {
                                    "filename": { "type": "string" },
                                    "data_base64": { "type": "string" }
                                },
                                "required": ["filename", "data_base64"]
                            }
                        },
                        "text": { "type": "string" },
                        "file_path": { "type": "string" },
                        "file_paths": str_arr,
                        "title": { "type": "string" },
                        "notes": { "type": "string" },
                        "rating": { "type": "integer" },
                        "folder_id": { "type": "string" },
                        "folder_path": { "type": "string" },
                        "target_board_id": { "type": "string" },
                        "tags": str_arr
                    }
                }),
                false,
                false,
                true,
            ),
            tool_def(
                "organize_assets",
                "Batch Organize & Enrich Assets",
                "Atomically update 1-50 assets via heterogeneous `items[]` or uniform `asset_ids[]`. Supports `dry_run:true`, canonical tag folding, soft Trash only, and `runID` rollback.",
                json!({
                    "type": "object",
                    "properties": {
                        "dry_run": { "type": "boolean" },
                        "items": {
                            "type": "array",
                            "items": {
                                "type": "object",
                                "properties": {
                                    "asset_id": { "type": "string" },
                                    "folder_id": { "type": "string" },
                                    "folder_path": { "type": "string" },
                                    "move_to_inbox": { "type": "boolean" },
                                    "add_tags": str_arr,
                                    "remove_tags": str_arr,
                                    "add_suggested_tags": str_arr,
                                    "accept_suggested_tags": { "type": "boolean" },
                                    "dismiss_suggested_tags": str_arr,
                                    "rating": { "type": "integer" },
                                    "title": { "type": "string" },
                                    "notes": { "type": "string" },
                                    "ai_description": { "type": "string" },
                                    "pinned_offline": { "type": "boolean" },
                                    "trashed": { "type": "boolean" },
                                    "analyze": { "type": "boolean" },
                                    "refresh_rich_metadata": { "type": "boolean" }
                                },
                                "required": ["asset_id"]
                            }
                        },
                        "asset_ids": str_arr,
                        "folder_id": { "type": "string" },
                        "folder_path": { "type": "string" },
                        "move_to_inbox": { "type": "boolean" },
                        "add_tags": str_arr,
                        "remove_tags": str_arr,
                        "add_suggested_tags": str_arr,
                        "accept_suggested_tags": { "type": "boolean" },
                        "dismiss_suggested_tags": str_arr,
                        "rating": { "type": "integer" },
                        "title": { "type": "string" },
                        "notes": { "type": "string" },
                        "ai_description": { "type": "string" },
                        "pinned_offline": { "type": "boolean" },
                        "trashed": { "type": "boolean" },
                        "analyze": { "type": "boolean" },
                        "refresh_rich_metadata": { "type": "boolean" }
                    }
                }),
                false,
                true,
                false,
            ),
            tool_def(
                "manage_folder",
                "Create or Update Folder",
                "Create (`reuse_existing` default true) or update (rename/move/color/symbol) a folder. Folder deletion forbidden. Requires `readWriteOrganize`.",
                json!({
                    "type": "object",
                    "required": ["action"],
                    "properties": {
                        "action": { "type": "string", "enum": ["create", "update"] },
                        "name": { "type": "string" },
                        "folder_id": { "type": "string" },
                        "folder_path": { "type": "string" },
                        "new_name": { "type": "string" },
                        "parent_id": { "type": "string" },
                        "parent_path": { "type": "string" },
                        "move_to_root": { "type": "boolean" },
                        "color_hex": { "type": "string" },
                        "custom_symbol": { "type": "string" },
                        "reuse_existing": { "type": "boolean" }
                    }
                }),
                false,
                true,
                false,
            ),
            tool_def(
                "save_moodboard",
                "Create or Patch Moodboard",
                "Create a Moodboard (`sections`/`asset_ids`/`prompt`) or non-destructively patch (`board_id`; preserves locked nodes). Requires `readWriteOrganize`; emits `runID`.",
                json!({
                    "type": "object",
                    "properties": {
                        "board_id": { "type": "string" },
                        "title": { "type": "string" },
                        "new_title": { "type": "string" },
                        "subtitle": { "type": "string" },
                        "curator_note": { "type": "string" },
                        "layout_style": { "type": "string", "enum": ["magazine", "balanced", "compact"] },
                        "use_freeform": { "type": "boolean" },
                        "sections": {
                            "type": "array",
                            "items": {
                                "type": "object",
                                "properties": {
                                    "title": { "type": "string" },
                                    "tint": { "type": "string" },
                                    "rationale": { "type": "string" },
                                    "asset_ids": str_arr,
                                    "hero_asset_ids": str_arr
                                },
                                "required": ["title", "asset_ids"]
                            }
                        },
                        "asset_ids": str_arr,
                        "hero_asset_ids": str_arr,
                        "prompt": { "type": "string" },
                        "seed_asset_ids": str_arr,
                        "required_tags": str_arr,
                        "target_palette": str_arr,
                        "folder_id": { "type": "string" },
                        "folder_path": { "type": "string" },
                        "preferred_count": { "type": "integer" },
                        "add_asset_ids": str_arr,
                        "remove_asset_ids": str_arr,
                        "remove_node_ids": str_arr,
                        "add_section": { "type": "string" },
                        "section_tint": { "type": "string" },
                        "add_note": { "type": "string" },
                        "note_title": { "type": "string" },
                        "note_style": { "type": "string", "enum": ["paper", "ink", "warm", "sage", "slate"] }
                    }
                }),
                false,
                false,
                false,
            ),
            tool_def(
                "deduplicate_assets",
                "Scan & Merge Duplicates",
                "`scan` (read-safe) detects duplicates with optional `contact_sheet:true`. `merge` (`readWriteOrganize`, `dry_run` supported) keeps master & soft-trashes dupes with `runID`.",
                json!({
                    "type": "object",
                    "required": ["action"],
                    "properties": {
                        "action": { "type": "string", "enum": ["scan", "merge"] },
                        "scope": { "type": "string", "enum": ["all", "inbox", "folder"] },
                        "folder_id": { "type": "string" },
                        "folder_path": { "type": "string" },
                        "include_subfolders": { "type": "boolean" },
                        "sensitivity": { "type": "string", "enum": ["strict", "balanced", "relaxed"] },
                        "media_kinds": media_kind_arr,
                        "contact_sheet": { "type": "boolean" },
                        "sheet_max_width": { "type": "integer" },
                        "limit": { "type": "integer" },
                        "dry_run": { "type": "boolean" },
                        "groups": {
                            "type": "array",
                            "items": {
                                "type": "object",
                                "properties": {
                                    "keep_asset_id": { "type": "string" },
                                    "discard_asset_ids": str_arr
                                },
                                "required": ["keep_asset_id", "discard_asset_ids"]
                            }
                        }
                    }
                }),
                false,
                true,
                false,
            ),
            tool_def(
                "rollback_run",
                "List or Rollback Agent Runs",
                "`list` (read-safe) shows recent agent write runs. `rollback` + `run_id` atomically restores assets, folders, and boards via compensating HLC ops.",
                json!({
                    "type": "object",
                    "required": ["action"],
                    "properties": {
                        "action": { "type": "string", "enum": ["list", "rollback"] },
                        "run_id": { "type": "string" },
                        "limit": { "type": "integer" }
                    }
                }),
                false,
                true,
                false,
            ),
        ]
    }

    fn result_value(id: Value, result: Value) -> Value {
        json!({
            "jsonrpc": "2.0",
            "id": id,
            "result": result
        })
    }

    fn error_value(id: Value, code: i32, message: &str) -> Value {
        json!({
            "jsonrpc": "2.0",
            "id": id,
            "error": { "code": code, "message": message }
        })
    }
}

fn tool_def(
    name: &str,
    title: &str,
    description: &str,
    input_schema: Value,
    read_only: bool,
    idempotent: bool,
    open_world: bool,
) -> Value {
    json!({
        "name": name,
        "description": description,
        "inputSchema": input_schema,
        "annotations": {
            "title": title,
            "readOnlyHint": read_only,
            "destructiveHint": false,
            "idempotentHint": idempotent,
            "openWorldHint": open_world
        }
    })
}

fn paginate_slice<T: Clone>(items: &[T], offset: usize, limit: usize) -> Vec<T> {
    if offset >= items.len() {
        return Vec::new();
    }
    items[offset..(offset + limit).min(items.len())].to_vec()
}

fn parse_crop_box(val: Option<&Value>) -> Option<NormalizedCropBox> {
    let obj = val?.as_object()?;
    let x = obj.get("x").and_then(Value::as_f64)?.clamp(0.0, 0.99);
    let y = obj.get("y").and_then(Value::as_f64)?.clamp(0.0, 0.99);
    let width = obj
        .get("width")
        .and_then(Value::as_f64)?
        .clamp(0.02, 1.0 - x);
    let height = obj
        .get("height")
        .and_then(Value::as_f64)?
        .clamp(0.02, 1.0 - y);
    if !x.is_finite() || !y.is_finite() || !width.is_finite() || !height.is_finite() {
        return None;
    }
    Some(NormalizedCropBox {
        x,
        y,
        width,
        height,
    })
}

fn sanitize_upload_filename(raw: &str, fallback_index: usize) -> String {
    let base = Path::new(raw)
        .file_name()
        .and_then(|s| s.to_str())
        .unwrap_or("")
        .trim();
    let cleaned: String = base
        .chars()
        .filter(|c| {
            !matches!(
                c,
                '/' | '\\' | ':' | '*' | '?' | '"' | '<' | '>' | '|' | '\0'
            ) && !c.is_control()
        })
        .take(120)
        .collect();
    let trimmed = cleaned.trim_matches('.').trim();
    if trimmed.is_empty() {
        format!("upload-{fallback_index}.bin")
    } else {
        trimmed.to_string()
    }
}

fn parse_group_tint(raw: Option<&str>) -> GroupTint {
    match raw.map(|s| s.trim().to_ascii_lowercase()).as_deref() {
        Some("sand") => GroupTint::Sand,
        Some("sage") => GroupTint::Sage,
        Some("slate") => GroupTint::Slate,
        Some("terracotta") => GroupTint::Terracotta,
        Some("ocean") => GroupTint::Ocean,
        _ => GroupTint::Neutral,
    }
}

fn build_folder_paths(folders: &[FolderRecord]) -> HashMap<Uuid, String> {
    let by_id: HashMap<Uuid, &FolderRecord> = folders.iter().map(|f| (f.id, f)).collect();
    let mut out = HashMap::new();
    for f in folders {
        let mut parts = Vec::new();
        let mut cur = Some(f.id);
        let mut seen = HashSet::new();
        while let Some(id) = cur {
            if !seen.insert(id) {
                break;
            }
            if let Some(rec) = by_id.get(&id) {
                parts.push(rec.name.clone());
                cur = rec.parent_id;
            } else {
                break;
            }
        }
        parts.reverse();
        out.insert(f.id, parts.join("/"));
    }
    out
}

fn build_folder_profiles(
    folders: &[FolderRecord],
    assets: &[AssetRecord],
) -> HashMap<Uuid, FolderProfile> {
    let mut children_by_parent: HashMap<Option<Uuid>, Vec<Uuid>> = HashMap::new();
    for f in folders {
        children_by_parent
            .entry(f.parent_id)
            .or_default()
            .push(f.id);
    }
    let mut direct_by_folder: HashMap<Uuid, Vec<&AssetRecord>> = HashMap::new();
    for a in assets {
        if let Some(fid) = a.folder_id {
            direct_by_folder.entry(fid).or_default().push(a);
        }
    }

    let mut profiles = HashMap::new();
    for folder in folders {
        let mut subtree = vec![folder.id];
        let mut seen = HashSet::from([folder.id]);
        let mut idx = 0usize;
        while idx < subtree.len() {
            let cur = subtree[idx];
            idx += 1;
            if let Some(children) = children_by_parent.get(&cur.into()) {
                for &child in children {
                    if seen.insert(child) {
                        subtree.push(child);
                    }
                }
            }
        }

        let direct_count = direct_by_folder.get(&folder.id).map(Vec::len).unwrap_or(0);
        let mut recursive_count = 0usize;
        let mut tag_counts: HashMap<String, usize> = HashMap::new();
        let mut shape_counts: HashMap<&'static str, usize> = HashMap::new();
        let mut color_weights: HashMap<String, f64> = HashMap::new();
        let mut rep_hex: HashMap<String, String> = HashMap::new();

        for fid in subtree {
            let Some(bucket) = direct_by_folder.get(&fid) else {
                continue;
            };
            recursive_count += bucket.len();
            for asset in bucket {
                *shape_counts
                    .entry(asset.aspect_shape().raw_value())
                    .or_insert(0) += 1;
                for tag in &asset.tags {
                    *tag_counts.entry(tag.clone()).or_insert(0) += 1;
                }
                if let Some(c) = asset.dominant_colors.first() {
                    let key = quantized_hex_bucket(&c.hex);
                    *color_weights.entry(key.clone()).or_insert(0.0) += c.proportion.max(0.15);
                    rep_hex.entry(key).or_insert_with(|| c.hex.to_uppercase());
                }
            }
        }

        let mut tags_vec: Vec<(String, usize)> = tag_counts.into_iter().collect();
        tags_vec.sort_by(|a, b| b.1.cmp(&a.1).then_with(|| a.0.cmp(&b.0)));
        let top_tags = tags_vec.into_iter().take(5).map(|(k, _)| k).collect();

        let mut color_vec: Vec<(String, f64)> = color_weights.into_iter().collect();
        color_vec.sort_by(|a, b| b.1.partial_cmp(&a.1).unwrap_or(std::cmp::Ordering::Equal));
        let palette = color_vec
            .into_iter()
            .take(3)
            .map(|(k, _)| rep_hex.remove(&k).unwrap_or(k))
            .collect();

        let dominant_aspect = if recursive_count >= 3 {
            shape_counts
                .into_iter()
                .max_by_key(|(_, c)| *c)
                .and_then(|(shape, count)| {
                    if (count as f64) / (recursive_count as f64) >= 0.60 {
                        Some(shape.to_string())
                    } else {
                        None
                    }
                })
        } else {
            None
        };

        profiles.insert(
            folder.id,
            FolderProfile {
                direct_count,
                recursive_count,
                top_tags,
                palette,
                dominant_aspect,
            },
        );
    }
    profiles
}

fn compute_result_facets(assets: &[AssetRecord], folder_paths: &HashMap<Uuid, String>) -> Value {
    let mut folder_counts: HashMap<String, usize> = HashMap::new();
    let mut tag_counts: HashMap<String, usize> = HashMap::new();
    let mut shape_counts: HashMap<&'static str, usize> = HashMap::new();
    let mut color_weights: HashMap<String, f64> = HashMap::new();

    for asset in assets {
        let folder = asset
            .folder_id
            .and_then(|id| folder_paths.get(&id).cloned())
            .unwrap_or_else(|| "Inbox".to_string());
        *folder_counts.entry(folder).or_insert(0) += 1;
        *shape_counts
            .entry(asset.aspect_shape().raw_value())
            .or_insert(0) += 1;
        for tag in &asset.tags {
            *tag_counts.entry(tag.clone()).or_insert(0) += 1;
        }
        if let Some(c) = asset.dominant_colors.first() {
            *color_weights
                .entry(quantized_hex_bucket(&c.hex))
                .or_insert(0.0) += c.proportion.max(0.1);
        }
    }

    let mut folders_vec: Vec<(String, usize)> = folder_counts.into_iter().collect();
    folders_vec.sort_by(|a, b| b.1.cmp(&a.1).then_with(|| a.0.cmp(&b.0)));
    let top_folders: Vec<Value> = folders_vec
        .into_iter()
        .take(6)
        .map(|(path, count)| json!({ "path": path, "count": count }))
        .collect();

    let mut tags_vec: Vec<(String, usize)> = tag_counts.into_iter().collect();
    tags_vec.sort_by(|a, b| b.1.cmp(&a.1).then_with(|| a.0.cmp(&b.0)));
    let top_tags: Vec<Value> = tags_vec
        .into_iter()
        .take(10)
        .map(|(name, count)| json!({ "name": name, "count": count }))
        .collect();

    let mut colors_vec: Vec<(String, f64)> = color_weights.into_iter().collect();
    colors_vec.sort_by(|a, b| b.1.partial_cmp(&a.1).unwrap_or(std::cmp::Ordering::Equal));
    let top_colors: Vec<String> = colors_vec.into_iter().take(5).map(|(h, _)| h).collect();

    let mut out = Map::new();
    out.insert("topFolders".into(), json!(top_folders));
    out.insert("topTags".into(), json!(top_tags));
    out.insert("aspectShapes".into(), json!(shape_counts));
    if !top_colors.is_empty() {
        out.insert("topColors".into(), json!(top_colors));
    }
    Value::Object(out)
}

fn quantized_hex_bucket(hex: &str) -> String {
    let clean = hex.trim().trim_start_matches('#');
    if clean.len() != 6 || !clean.is_ascii() {
        return hex.to_uppercase();
    }
    let Ok(val) = u32::from_str_radix(clean, 16) else {
        return hex.to_uppercase();
    };
    let r = ((val >> 16) & 0xFF) & 0xE0;
    let g = ((val >> 8) & 0xFF) & 0xE0;
    let b = (val & 0xFF) & 0xE0;
    format!("#{:02X}{:02X}{:02X}", r + 16, g + 16, b + 16)
}

fn serialize_asset_summary(
    asset: &AssetRecord,
    folder_paths: &HashMap<Uuid, String>,
    detail: AssetDetailLevel,
) -> Value {
    let folder_path = asset
        .folder_id
        .and_then(|id| folder_paths.get(&id).cloned())
        .unwrap_or_else(|| "Inbox".to_string());
    let full_id = format_swift_uuid(&asset.id);

    if detail == AssetDetailLevel::Visual {
        let mut dict = Map::new();
        dict.insert("id".into(), json!(&full_id[..8]));
        dict.insert("shortId".into(), json!(&full_id[..8]));
        dict.insert("title".into(), json!(truncate_text(&asset.title, 42)));
        dict.insert("folderPath".into(), json!(folder_path));
        if asset.pixel_width > 0 && asset.pixel_height > 0 {
            dict.insert(
                "dimensions".into(),
                json!(format!("{}x{}", asset.pixel_width, asset.pixel_height)),
            );
        }
        dict.insert(
            "aspectShape".into(),
            json!(asset.aspect_shape().raw_value()),
        );
        if let Some(c) = asset.dominant_colors.first() {
            dict.insert("dominantHex".into(), json!(c.hex.to_uppercase()));
        }
        if !asset.tags.is_empty() {
            dict.insert(
                "tags".into(),
                json!(asset.tags.iter().take(4).collect::<Vec<_>>()),
            );
        }
        if asset.media_kind != MediaKind::Image {
            dict.insert("mediaKind".into(), json!(asset.media_kind.raw_value()));
        }
        if asset.rating > 0 {
            dict.insert("rating".into(), json!(asset.rating));
        }
        return Value::Object(dict);
    }

    let rounded_ratio = (asset.aspect_ratio() * 100.0).round() / 100.0;
    if detail == AssetDetailLevel::Full {
        let mut dict = Map::new();
        dict.insert("id".into(), json!(full_id));
        dict.insert("title".into(), json!(asset.title));
        dict.insert("fileName".into(), json!(asset.file_name));
        dict.insert("mediaKind".into(), json!(asset.media_kind.raw_value()));
        dict.insert(
            "folderID".into(),
            json!(asset
                .folder_id
                .map(|id| format_swift_uuid(&id))
                .unwrap_or_default()),
        );
        dict.insert("folderPath".into(), json!(folder_path));
        dict.insert("tags".into(), json!(asset.tags));
        dict.insert("rating".into(), json!(asset.rating));
        dict.insert("aspectRatio".into(), json!(rounded_ratio));
        dict.insert(
            "aspectShape".into(),
            json!(asset.aspect_shape().raw_value()),
        );
        dict.insert(
            "dominantColors".into(),
            json!(asset
                .dominant_colors
                .iter()
                .take(5)
                .map(|c| c.hex.to_uppercase())
                .collect::<Vec<_>>()),
        );
        dict.insert(
            "aiDescription".into(),
            json!(asset.ai_description.clone().unwrap_or_default()),
        );
        dict.insert("notes".into(), json!(asset.notes));
        dict.insert(
            "sourceURL".into(),
            json!(asset.source_url.clone().unwrap_or_default()),
        );
        dict.insert("isTrashed".into(), json!(asset.is_trashed));
        if asset.pixel_width > 0 && asset.pixel_height > 0 {
            dict.insert(
                "dimensions".into(),
                json!(format!("{}x{}", asset.pixel_width, asset.pixel_height)),
            );
        }
        return Value::Object(dict);
    }

    let mut dict = Map::new();
    dict.insert("id".into(), json!(full_id));
    dict.insert("title".into(), json!(asset.title));
    dict.insert("mediaKind".into(), json!(asset.media_kind.raw_value()));
    dict.insert("folderPath".into(), json!(folder_path));
    dict.insert("aspectRatio".into(), json!(rounded_ratio));
    dict.insert(
        "aspectShape".into(),
        json!(asset.aspect_shape().raw_value()),
    );
    if asset.pixel_width > 0 && asset.pixel_height > 0 {
        dict.insert(
            "dimensions".into(),
            json!(format!("{}x{}", asset.pixel_width, asset.pixel_height)),
        );
    }
    if asset.rating > 0 {
        dict.insert("rating".into(), json!(asset.rating));
    }
    if !asset.tags.is_empty() {
        dict.insert("tags".into(), json!(asset.tags));
    }
    let color_cap = if detail == AssetDetailLevel::Compact {
        3
    } else {
        5
    };
    let colors: Vec<String> = asset
        .dominant_colors
        .iter()
        .take(color_cap)
        .map(|c| c.hex.to_uppercase())
        .collect();
    if !colors.is_empty() {
        dict.insert("dominantColors".into(), json!(colors));
    }
    let desc = asset.ai_description.as_deref().unwrap_or("").trim();
    if !desc.is_empty() {
        let rendered = if detail == AssetDetailLevel::Compact {
            truncate_text(desc, 160)
        } else {
            desc.to_string()
        };
        dict.insert("aiDescription".into(), json!(rendered));
    }

    if detail == AssetDetailLevel::Standard {
        if let Some(fid) = asset.folder_id {
            dict.insert("folderID".into(), json!(format_swift_uuid(&fid)));
        }
        dict.insert("fileName".into(), json!(asset.file_name));
        let clean_notes = asset.notes.trim();
        if !clean_notes.is_empty() {
            dict.insert("notes".into(), json!(truncate_text(clean_notes, 400)));
        }
        if let Some(ref url) = asset.source_url {
            if !url.is_empty() {
                dict.insert("sourceURL".into(), json!(url));
            }
        }
    } else {
        let base_stem = Path::new(&asset.file_name)
            .file_stem()
            .and_then(|s| s.to_str())
            .unwrap_or("");
        if !asset.file_name.is_empty()
            && !base_stem.eq_ignore_ascii_case(&asset.title)
            && !asset.title.starts_with(base_stem)
        {
            dict.insert("fileName".into(), json!(asset.file_name));
        }
        let clean_notes = asset.notes.trim();
        if !clean_notes.is_empty() {
            let excerpt = truncate_text(clean_notes, 100);
            let prefix_check: String = excerpt.chars().take(24).collect();
            if desc.is_empty() || !desc.contains(&prefix_check) {
                dict.insert("notesExcerpt".into(), json!(excerpt));
            }
        }
        if asset.media_kind == MediaKind::WebBookmark {
            if let Some(ref url) = asset.source_url {
                if !url.is_empty() {
                    dict.insert("sourceURL".into(), json!(url));
                }
            }
        }
    }

    Value::Object(dict)
}

fn truncate_text(text: &str, max_chars: usize) -> String {
    if text.chars().count() <= max_chars {
        return text.to_string();
    }
    let keep = max_chars.saturating_sub(1).max(1);
    let prefix: String = text.chars().take(keep).collect();
    format!("{prefix}…")
}

fn parse_visual_tones(val: Option<&Value>) -> Vec<VisualTone> {
    match val {
        Some(Value::String(s)) => s
            .split([',', '，'])
            .filter_map(|p| VisualTone::parse(Some(p)))
            .collect(),
        Some(Value::Array(arr)) => arr
            .iter()
            .filter_map(Value::as_str)
            .filter_map(|p| VisualTone::parse(Some(p)))
            .collect(),
        _ => Vec::new(),
    }
}

fn parse_media_kinds(val: Option<&Value>) -> BTreeSet<MediaKind> {
    string_array_arg(val)
        .into_iter()
        .filter_map(|raw| serde_json::from_value::<MediaKind>(Value::String(raw)).ok())
        .collect()
}

fn parse_sort_order(raw: Option<&str>, has_query: bool) -> SortOrder {
    match raw.map(|s| s.trim().to_ascii_lowercase()).as_deref() {
        Some("oldest") => SortOrder::Oldest,
        Some("name_asc") | Some("nameasc") | Some("name") => SortOrder::NameAsc,
        Some("rating_desc") | Some("ratingdesc") | Some("rating") => SortOrder::RatingDesc,
        Some("file_size_desc") | Some("filesizedesc") | Some("size") => SortOrder::FileSizeDesc,
        Some("relevance") => SortOrder::Relevance,
        Some("newest") => SortOrder::Newest,
        _ => {
            if has_query {
                SortOrder::Relevance
            } else {
                SortOrder::Newest
            }
        }
    }
}

fn parse_uuid_list_strict(val: Option<&Value>) -> Vec<Uuid> {
    val.and_then(Value::as_array)
        .map(|arr| {
            arr.iter()
                .filter_map(Value::as_str)
                .filter_map(|s| Uuid::parse_str(s.trim()).ok())
                .collect()
        })
        .unwrap_or_default()
}

fn string_array_arg(val: Option<&Value>) -> Vec<String> {
    val.and_then(Value::as_array)
        .map(|arr| {
            arr.iter()
                .filter_map(Value::as_str)
                .map(|s| s.trim().to_string())
                .filter(|s| !s.is_empty())
                .collect()
        })
        .unwrap_or_default()
}

fn bool_arg(val: Option<&Value>) -> Option<bool> {
    match val {
        Some(Value::Bool(b)) => Some(*b),
        Some(Value::String(s)) => match s.trim().to_ascii_lowercase().as_str() {
            "true" | "1" | "yes" => Some(true),
            "false" | "0" | "no" => Some(false),
            _ => None,
        },
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::models::agent::{ExternalAgentToken, ExternalAgentTransport, LibraryTaxonomyPolicy};
    use image::{ImageBuffer, Rgba};
    use std::sync::atomic::{AtomicUsize, Ordering};
    use tempfile::tempdir;

    fn sample_png_bytes(rgba: [u8; 4], w: u32, h: u32) -> Vec<u8> {
        let img = ImageBuffer::from_fn(w, h, |_, _| Rgba(rgba));
        let mut buf = Vec::new();
        image::DynamicImage::ImageRgba8(img)
            .write_to(&mut std::io::Cursor::new(&mut buf), image::ImageFormat::Png)
            .unwrap();
        buf
    }

    #[tokio::test]
    async fn enforces_pure_mcp_v2_10_tools_schema_budget_3_tiers_and_rollback() {
        let dir = tempdir().unwrap();
        let engine = Arc::new(LiveCharkleEngine::open(dir.path()).unwrap());
        let wake_hits = Arc::new(AtomicUsize::new(0));
        let wake_clone = Arc::clone(&wake_hits);
        let svc = CharkleExternalAgentService::new(
            Arc::clone(&engine),
            dir.path().to_path_buf(),
            Some(Arc::new(move |_| {
                wake_clone.fetch_add(1, Ordering::SeqCst);
            })),
        );

        // 1. Verify schema count (10 tools, 5+2 resources, 5 prompts) and < 12 KB schema budget
        let tools = CharkleExternalAgentService::mcp_tool_definitions();
        assert_eq!(tools.len(), 10);
        let schema_bytes = serde_json::to_vec(&tools).unwrap().len();
        assert!(
            schema_bytes < 12 * 1024,
            "Pure MCP v2 tools/list schema must stay under 12 KB, got {schema_bytes}"
        );
        assert_eq!(
            CharkleExternalAgentService::mcp_resource_definitions().len(),
            5
        );
        assert_eq!(
            CharkleExternalAgentService::mcp_resource_template_definitions().len(),
            2
        );
        assert_eq!(
            CharkleExternalAgentService::mcp_prompt_definitions().len(),
            5
        );

        // 2. Verify JSON-RPC batch initialize + tools/list + resources/read(taxonomy)
        let mut tax = LibraryTaxonomyPolicy::default();
        tax.tag_aliases
            .insert("手绘风".to_string(), "手绘插画".to_string());
        ExternalAgentStateStore::save_taxonomy(engine.database(), &tax).unwrap();

        let batch = json!([
            { "jsonrpc": "2.0", "id": 1, "method": "initialize", "params": { "protocolVersion": "2025-11-25" } },
            { "jsonrpc": "2.0", "id": 2, "method": "tools/list" },
            { "jsonrpc": "2.0", "id": 3, "method": "resources/read", "params": { "uri": "charkle://library/taxonomy" } }
        ]);
        let reply = svc.handle_jsonrpc(&batch.to_string()).await.unwrap();
        let parsed: Vec<Value> = serde_json::from_str(&reply).unwrap();
        assert_eq!(parsed.len(), 3);
        assert_eq!(parsed[0]["result"]["protocolVersion"], "2025-11-25");
        assert_eq!(parsed[1]["result"]["tools"].as_array().unwrap().len(), 10);
        assert!(parsed[2]["result"]["contents"][0]["text"]
            .as_str()
            .unwrap()
            .contains("手绘插画"));

        // 3. Retired `output_path` is strictly rejected
        let out_path_err = svc
            .call_tool(
                "query_assets",
                &json!({ "contact_sheet": true, "output_path": "/tmp/hack.jpg" }),
            )
            .await;
        assert!(out_path_err.is_error);

        // 4. Default `readOnly` blocks writes, while `inboxAndEnrich` permits inline_files ingest
        let read_only_block = svc
            .call_tool("ingest_assets", &json!({ "text": "hello" }))
            .await;
        assert!(read_only_block.is_error);

        // HTTP context with `inboxAndEnrich` token blocks `file_path` but allows `inline_files`
        let http_inbox_ctx = ExternalAgentRequestContext {
            transport: ExternalAgentTransport::Http,
            scoped_access_level: Some(ExternalAgentAccessLevel::InboxAndEnrich),
            actor_label: "http:inbox-bot".to_string(),
            issue_download_url: Some(Arc::new(|id| {
                Some(format!("http://127.0.0.1:41937/api/v1/mcp/download/{id}"))
            })),
        };
        let blocked_local_path = svc
            .call_tool_with_context(
                "ingest_assets",
                &json!({ "file_path": "/etc/passwd" }),
                &http_inbox_ctx,
            )
            .await;
        assert!(blocked_local_path.is_error);

        let png_b64 = BASE64.encode(sample_png_bytes([220, 120, 60, 255], 40, 30));
        let ingested = svc
            .call_tool_with_context(
                "ingest_assets",
                &json!({
                    "inline_files": [{ "filename": "sunset.png", "data_base64": png_b64 }],
                    "tags": ["日落"]
                }),
                &http_inbox_ctx,
            )
            .await;
        assert!(!ingested.is_error, "{}", ingested.first_text());
        let ing_json: Value = serde_json::from_str(&ingested.first_text()).unwrap();
        let asset_id = ing_json["assets"][0]["id"].as_str().unwrap().to_string();
        let short_id = &asset_id[..8];

        // 5. inspect_assets over HTTP hides localOriginalPath, returns downloadURL, and supports crop_box
        let inspected = svc
            .call_tool_with_context(
                "inspect_assets",
                &json!({
                    "asset_id": short_id,
                    "include_image": true,
                    "include_download_url": true,
                    "crop_box": { "x": 0.1, "y": 0.1, "width": 0.5, "height": 0.5 }
                }),
                &http_inbox_ctx,
            )
            .await;
        assert!(!inspected.is_error, "{}", inspected.first_text());
        assert!(inspected
            .content
            .iter()
            .any(|c| matches!(c, ToolContent::Image { .. })));
        let insp_json: Value = serde_json::from_str(&inspected.first_text()).unwrap();
        assert!(insp_json.get("localOriginalPath").is_none());
        assert!(insp_json["downloadURL"]
            .as_str()
            .unwrap()
            .contains("/api/v1/mcp/download/"));
        assert!(insp_json.get("appliedCropBox").is_some());

        // 6. `inboxAndEnrich` forbids trashing, permits dry_run & organizing inbox asset with alias folding
        let trash_blocked = svc
            .call_tool_with_context(
                "organize_assets",
                &json!({ "asset_ids": [short_id], "trashed": true }),
                &http_inbox_ctx,
            )
            .await;
        assert!(trash_blocked.is_error);

        let dry = svc
            .call_tool_with_context(
                "organize_assets",
                &json!({
                    "dry_run": true,
                    "items": [{ "asset_id": short_id, "add_tags": ["手绘风"], "rating": 4 }]
                }),
                &http_inbox_ctx,
            )
            .await;
        assert!(!dry.is_error, "{}", dry.first_text());
        let dry_json: Value = serde_json::from_str(&dry.first_text()).unwrap();
        assert_eq!(dry_json["dryRun"], true);
        assert_eq!(dry_json["items"][0]["addTags"][0], "手绘插画");

        // Commit heterogeneous organize_assets, verify rollback_run restores pre-mutation state!
        let committed = svc
            .call_tool_with_context(
                "organize_assets",
                &json!({
                    "items": [{ "asset_id": short_id, "add_tags": ["手绘风"], "rating": 5, "ai_description": "暖色黄昏" }]
                }),
                &http_inbox_ctx,
            )
            .await;
        assert!(!committed.is_error, "{}", committed.first_text());
        let commit_json: Value = serde_json::from_str(&committed.first_text()).unwrap();
        let run_id = commit_json["runID"].as_str().unwrap().to_string();

        let after_org = engine
            .fetch_asset(Uuid::parse_str(&asset_id).unwrap())
            .unwrap()
            .unwrap();
        assert_eq!(after_org.rating, 5);
        assert!(after_org.tags.contains(&"手绘插画".to_string()));
        assert_eq!(after_org.ai_description.as_deref(), Some("暖色黄昏"));

        // Rollback the organize run
        let rolled = svc
            .call_tool_with_context(
                "rollback_run",
                &json!({ "action": "rollback", "run_id": run_id }),
                &http_inbox_ctx,
            )
            .await;
        assert!(!rolled.is_error, "{}", rolled.first_text());
        let after_rb = engine
            .fetch_asset(Uuid::parse_str(&asset_id).unwrap())
            .unwrap()
            .unwrap();
        assert_eq!(after_rb.rating, 0);
        assert!(!after_rb.tags.contains(&"手绘插画".to_string()));
        assert_eq!(after_rb.ai_description, None);

        // 7. session_id seen-tracking across multi-round query_assets
        let r1 = svc
            .call_tool(
                "query_assets",
                &json!({ "session_id": "curate-1", "limit": 5 }),
            )
            .await;
        assert!(!r1.is_error);
        let r1_json: Value = serde_json::from_str(&r1.first_text()).unwrap();
        assert_eq!(r1_json["returned"], 1);
        let r2 = svc
            .call_tool(
                "query_assets",
                &json!({ "session_id": "curate-1", "limit": 5 }),
            )
            .await;
        let r2_json: Value = serde_json::from_str(&r2.first_text()).unwrap();
        assert_eq!(r2_json["returned"], 0);
        assert_eq!(r2_json["session"]["skippedSeenCount"], 1);

        // 8. Scoped Token minting + constant-time matching + global write (manage_folder, save_moodboard, deduplicate_assets)
        let (tok, plaintext) =
            ExternalAgentToken::mint("Claude Remote", ExternalAgentAccessLevel::ReadWriteOrganize);
        assert!(tok.matches(&plaintext));
        assert!(!tok.matches("ck_mcp_wrong"));
        let mut cfg = ExternalAgentConfig {
            access_level: ExternalAgentAccessLevel::ReadWriteOrganize,
            ..Default::default()
        };
        cfg.tokens.push(tok);
        ExternalAgentConfigStore::save(dir.path(), &cfg).unwrap();

        let created_folder = svc
            .call_tool(
                "manage_folder",
                &json!({ "action": "create", "name": "海报参考" }),
            )
            .await;
        assert!(!created_folder.is_error, "{}", created_folder.first_text());
        let reused_folder = svc
            .call_tool(
                "manage_folder",
                &json!({ "action": "create", "name": "海报参考" }),
            )
            .await;
        let reused_json: Value = serde_json::from_str(&reused_folder.first_text()).unwrap();
        assert_eq!(reused_json["reusedExisting"], true);

        let board_res = svc
            .call_tool(
                "save_moodboard",
                &json!({ "title": "黄昏情绪板", "asset_ids": [short_id], "curator_note": "温暖基调" }),
            )
            .await;
        assert!(!board_res.is_error, "{}", board_res.first_text());
        let board_json: Value = serde_json::from_str(&board_res.first_text()).unwrap();
        let board_id = board_json["boardID"].as_str().unwrap();

        let get_b = svc
            .call_tool("get_board", &json!({ "board_id": &board_id[..8] }))
            .await;
        assert!(!get_b.is_error, "{}", get_b.first_text());

        // Ingest identical duplicate and verify deduplicate_assets(scan + merge -> soft trash only)
        let dup_ing = svc
            .call_tool_with_context(
                "ingest_assets",
                &json!({ "inline_files": [{ "filename": "sunset-copy.png", "data_base64": png_b64 }] }),
                &http_inbox_ctx,
            )
            .await;
        assert!(!dup_ing.is_error);
        let scan_res = svc
            .call_tool("deduplicate_assets", &json!({ "action": "scan" }))
            .await;
        assert!(!scan_res.is_error, "{}", scan_res.first_text());
        let scan_json: Value = serde_json::from_str(&scan_res.first_text()).unwrap();
        assert_eq!(scan_json["totalGroups"], 1);
        let cands = scan_json["groups"][0]["candidates"].as_array().unwrap();
        let keep_id = cands[0]["id"].as_str().unwrap();
        let drop_id = cands[1]["id"].as_str().unwrap();

        let merge_res = svc
            .call_tool(
                "deduplicate_assets",
                &json!({
                    "action": "merge",
                    "groups": [{ "keep_asset_id": keep_id, "discard_asset_ids": [drop_id] }]
                }),
            )
            .await;
        assert!(!merge_res.is_error, "{}", merge_res.first_text());
        let merge_json: Value = serde_json::from_str(&merge_res.first_text()).unwrap();
        assert_eq!(merge_json["movedToTrashCount"], 1);
        let trashed_assets = engine
            .fetch_assets(&FilterCriteria {
                only_trashed: true,
                ..Default::default()
            })
            .unwrap();
        assert_eq!(
            trashed_assets.len(),
            1,
            "deduplicate_assets merge must soft-trash duplicates, never permanently delete"
        );
        assert!(wake_hits.load(Ordering::SeqCst) > 0);
    }
}
