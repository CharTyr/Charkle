//! Grounded 20-tool External Agent Service (MCP v2 + CLI) powering BOTH:
//! 1. Native Rust **MCP Server (`charkle-cli.exe mcp`)** over stdio JSON-RPC 2.0 (batch + NDJSON/Content-Length)
//! 2. Native Rust **CLI (`charkle-cli.exe <command>`)** for scripts, skills, and terminal workflows
//!
//! v1.2.2 Low-Token & Visual Intelligence Contract (1:1 with `CharkleExternalAgentService.swift`):
//! - Compact JSON default on MCP text payloads; lean `< 18 KB` `tools/list` schema budget.
//! - Universal 8+ char short UUID prefix resolution with explicit ambiguity rejection.
//! - `detail`: `"visual"` (auto-selected with inline Contact Sheets), `"compact"`, `"standard"`, `"full"`.
//! - `library_overview` folder semantic atlas (`recursiveAssetCount`, `topTags`, `palette`, `dominantAspect`).
//! - 7-dimension local CIELAB `VisualTone` filtering, bilingual EN↔ZH expansion, `seed_asset_ids`,
//!   `unlike_asset_ids` repulsion, Round-Robin visual `diversify`, auto `facets`, multi-direction
//!   `queries[]` 3-in-1 Contact Sheets (`512..=1920` px, up to 24 tiles), and batch `get_asset` (1–12).
//! - Security invariant: independent `mcpEnabled`/`cliEnabled` toggles, `readOnly` blocks writes &
//!   disk exports, and permanent deletion of assets/folders is NEVER exposed.

use std::collections::{BTreeSet, HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::sync::Arc;

use base64::engine::general_purpose::STANDARD as BASE64;
use base64::Engine;
use chrono::Utc;
use serde_json::{json, Map, Value};
use url::Url;
use uuid::Uuid;

use crate::agent::policy::ExternalAgentConfigStore;
use crate::db::search_text;
use crate::engine::{LiveCharkleEngine, LocalSemanticSearchHit};
use crate::error::{CoreError, CoreResult};
use crate::export::{BoardImageFormat, MoodboardExportOptions};
use crate::intelligence::{
    render_contact_sheet_with_options, ContactSheetOptions, VisualTone,
    CONTACT_SHEET_DEFAULT_WIDTH, CONTACT_SHEET_MAX_ASSETS, CONTACT_SHEET_MAX_WIDTH,
    CONTACT_SHEET_MIN_WIDTH,
};
use crate::models::agent::{ExternalAgentChannel, ExternalAgentConfig};
use crate::models::core::{
    AspectShape, AssetBatchPatch, AssetRecord, FilterCriteria, FolderAssignment, FolderRecord,
    MediaKind, SortOrder,
};
use crate::models::media::{CaptureInput, ThumbnailTier};
use crate::models::moodboard::{
    AutoLayoutConfig, BoardLayoutMode, BoardNode, BoardNodeKind, BoardRect, EditorialStyle,
    GroupTint, MoodboardCurationRequest, MoodboardDocument, NoteStyle,
};
use crate::wire::swift_codec::format_swift_uuid;

pub const SUPPORTED_PROTOCOL_VERSIONS: &[&str] =
    &["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"];

pub const DEFAULT_PROTOCOL_VERSION: &str = "2025-03-26";

pub const READ_TOOL_NAMES: &[&str] = &[
    "library_overview",
    "search_assets",
    "list_inbox",
    "get_asset",
    "render_contact_sheet",
    "find_similar_assets",
    "semantic_search",
    "quick_jump",
    "suggest_folder",
    "list_boards",
    "get_board_context",
    "export_board_image",
];

pub const WRITE_TOOL_NAMES: &[&str] = &[
    "organize_assets",
    "create_folder",
    "update_folder",
    "ingest_asset",
    "compose_moodboard",
    "patch_moodboard",
    "trash_assets",
    "analyze_assets",
];

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
            .filter_map(|c| match c {
                ToolContent::Text(t) => Some(t.as_str()),
                ToolContent::Image { .. } => None,
            })
            .collect::<Vec<_>>()
            .join("\n")
    }
}

pub type WriteWakeHook = Arc<dyn Fn(&str) + Send + Sync>;

struct FolderProfile {
    direct_count: usize,
    recursive_count: usize,
    top_tags: Vec<String>,
    palette: Vec<String>,
    dominant_aspect: Option<String>,
}

struct AttachedContactSheet {
    jpeg_bytes: Vec<u8>,
    width: u32,
    height: u32,
    slot_count: usize,
    saved_path: Option<String>,
}

impl AttachedContactSheet {
    fn summary(&self) -> Value {
        let mut m = Map::new();
        m.insert("width".into(), json!(self.width));
        m.insert("height".into(), json!(self.height));
        m.insert("slotCount".into(), json!(self.slot_count));
        m.insert("bytes".into(), json!(self.jpeg_bytes.len()));
        if let Some(ref p) = self.saved_path {
            m.insert("savedPath".into(), json!(p));
        }
        Value::Object(m)
    }
}

struct MultiQueryRecallResult {
    hits: Vec<(LocalSemanticSearchHit, String)>,
    groups_summary: Vec<Value>,
    total_unique_matched: usize,
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

    // =========================================================================
    // MCP JSON-RPC 2.0 Dispatcher (Single Object + Batch Arrays)
    // =========================================================================

    pub async fn handle_jsonrpc(&self, raw_payload: &str) -> Option<String> {
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
                if let Some(resp) = self.handle_single_jsonrpc(&item).await {
                    responses.push(resp);
                }
            }
            return if responses.is_empty() {
                None
            } else {
                serde_json::to_string(&Value::Array(responses)).ok()
            };
        }

        self.handle_single_jsonrpc(&parsed)
            .await
            .and_then(|v| serde_json::to_string(&v).ok())
    }

    async fn handle_single_jsonrpc(&self, parsed: &Value) -> Option<Value> {
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

        match method {
            "initialize" => {
                let policy = self.current_policy();
                if !policy.allows_read(ExternalAgentChannel::Mcp) {
                    return Some(Self::error_value(
                        req_id,
                        -32001,
                        "Charkle MCP service is disabled in Settings.",
                    ));
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
                            "version": env!("CARGO_PKG_VERSION")
                        },
                        "instructions": "Charkle visual reference library & moodboard studio. Low-token workflow: (1) Call `library_overview` first to read compact folder semantic profiles (`recursiveAssetCount`, `topTags`, `palette`), aspect mix, and boards. (2) Recall + inspect visually in 1 call via `semantic_search` (bilingual EN↔ZH, CIELAB `tone`, multi-direction `queries[]`, `seed_asset_ids`, `unlike_asset_ids` repulsion) or `search_assets` with `diversify:true` and `render_contact_sheet:true` (auto ultra-lean `visual` manifest); use `facets` to narrow large result sets. (3) 8-char short ID prefixes work in all tools; batch-call `get_asset(asset_ids:[...])` only on finalists. Permanent deletion is never permitted."
                    }),
                ))
            }
            "notifications/initialized" | "notifications/cancelled" | "initialized" => None,
            "ping" => Some(Self::result_value(req_id, json!({}))),
            "logging/setLevel" => Some(Self::result_value(req_id, json!({}))),
            "tools/list" => {
                let policy = self.current_policy();
                if !policy.allows_read(ExternalAgentChannel::Mcp) {
                    return Some(Self::error_value(
                        req_id,
                        -32001,
                        "Charkle MCP service is disabled in Settings.",
                    ));
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
                let output = self.call_tool(name, &args, ExternalAgentChannel::Mcp).await;
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
                if !policy.allows_read(ExternalAgentChannel::Mcp) {
                    return Some(Self::error_value(
                        req_id,
                        -32001,
                        "Charkle MCP service is disabled in Settings.",
                    ));
                }
                Some(Self::result_value(
                    req_id,
                    json!({ "resources": Self::mcp_resource_definitions() }),
                ))
            }
            "resources/templates/list" => {
                let policy = self.current_policy();
                if !policy.allows_read(ExternalAgentChannel::Mcp) {
                    return Some(Self::error_value(
                        req_id,
                        -32001,
                        "Charkle MCP service is disabled in Settings.",
                    ));
                }
                Some(Self::result_value(
                    req_id,
                    json!({ "resourceTemplates": Self::mcp_resource_template_definitions() }),
                ))
            }
            "resources/read" => {
                let policy = self.current_policy();
                if !policy.allows_read(ExternalAgentChannel::Mcp) {
                    return Some(Self::error_value(
                        req_id,
                        -32001,
                        "Charkle MCP service is disabled in Settings.",
                    ));
                }
                let Some(uri) = params.get("uri").and_then(Value::as_str) else {
                    return Some(Self::error_value(req_id, -32602, "Missing resource uri"));
                };
                match self.read_resource(uri).await {
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
                if !policy.allows_read(ExternalAgentChannel::Mcp) {
                    return Some(Self::error_value(
                        req_id,
                        -32001,
                        "Charkle MCP service is disabled in Settings.",
                    ));
                }
                Some(Self::result_value(
                    req_id,
                    json!({ "prompts": Self::mcp_prompt_definitions() }),
                ))
            }
            "prompts/get" => {
                let policy = self.current_policy();
                if !policy.allows_read(ExternalAgentChannel::Mcp) {
                    return Some(Self::error_value(
                        req_id,
                        -32001,
                        "Charkle MCP service is disabled in Settings.",
                    ));
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

    async fn read_resource(&self, uri: &str) -> Result<String, String> {
        if uri == "charkle://library/overview" {
            let out = self
                .call_tool("library_overview", &json!({}), ExternalAgentChannel::Mcp)
                .await;
            return Ok(out.first_text());
        }
        if uri == "charkle://boards" {
            let out = self
                .call_tool("list_boards", &json!({}), ExternalAgentChannel::Mcp)
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
                .call_tool(
                    "get_asset",
                    &json!({ "asset_id": asset_id.trim() }),
                    ExternalAgentChannel::Mcp,
                )
                .await;
            if out.is_error {
                return Err(out.first_text());
            }
            return Ok(out.first_text());
        }
        if let Some(board_id) = uri.strip_prefix("charkle://boards/") {
            let out = self
                .call_tool(
                    "get_board_context",
                    &json!({ "board_id": board_id.trim() }),
                    ExternalAgentChannel::Mcp,
                )
                .await;
            if out.is_error {
                return Err(out.first_text());
            }
            return Ok(out.first_text());
        }
        Err(format!("Unknown resource URI: {uri}"))
    }

    // =========================================================================
    // Unified 20-Tool Router (MCP v2 + CLI)
    // =========================================================================

    pub async fn call_tool(
        &self,
        name: &str,
        args: &Value,
        channel: ExternalAgentChannel,
    ) -> ToolOutput {
        let policy = self.current_policy();
        if !policy.allows_read(channel) {
            return match channel {
                ExternalAgentChannel::Mcp => ToolOutput::error(
                    "MCP 服务已在 Charkle「设置 → 外部 Agent」中关闭，请先开启「启用 MCP 服务」后再试。",
                ),
                ExternalAgentChannel::Cli => ToolOutput::error(
                    "CLI 命令行服务已在 Charkle「设置 → 外部 Agent」中关闭，请先开启「启用 CLI 命令行服务」后再试。",
                ),
            };
        }
        if WRITE_TOOL_NAMES.contains(&name) && !policy.allows_write(channel) {
            return ToolOutput::error(format!(
                "当前 Charkle 外部 Agent 权限为「仅只读检索与导出」，无法执行写入操作「{name}」。请在 Charkle「设置 → 外部 Agent」中切换为「允许整理与生成情绪板」。"
            ));
        }

        let res = match name {
            "library_overview" => self.handle_library_overview(args, &policy, channel),
            "search_assets" => self.handle_search_assets(args, &policy, channel),
            "list_inbox" => self.handle_list_inbox(args, &policy, channel),
            "get_asset" => self.handle_get_asset(args),
            "render_contact_sheet" => self.handle_render_contact_sheet(args, &policy, channel),
            "find_similar_assets" => self.handle_find_similar_assets(args, &policy, channel),
            "semantic_search" => self.handle_semantic_search(args, &policy, channel),
            "quick_jump" => self.handle_quick_jump(args),
            "suggest_folder" => self.handle_suggest_folder(args),
            "list_boards" => self.handle_list_boards(),
            "get_board_context" => self.handle_get_board_context(args),
            "export_board_image" => self.handle_export_board_image(args, &policy, channel),
            "organize_assets" => self.handle_organize_assets(args),
            "create_folder" => self.handle_create_folder(args),
            "update_folder" => self.handle_update_folder(args),
            "ingest_asset" => self.handle_ingest_asset(args).await,
            "compose_moodboard" => self.handle_compose_moodboard(args).await,
            "patch_moodboard" => self.handle_patch_moodboard(args),
            "trash_assets" => self.handle_trash_assets(args),
            "analyze_assets" => self.handle_analyze_assets(args).await,
            _ => return ToolOutput::error(format!("Unknown Charkle tool: {name}")),
        };
        match res {
            Ok(out) => out,
            Err(err) => ToolOutput::error(format!("Tool {name} failed: {err}")),
        }
    }

    // =========================================================================
    // Universal 8+ Char Short UUID Prefix Resolution & Safe Export Path Guard
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

    fn validate_export_output_path(
        &self,
        raw_path: &str,
        allowed_extensions: &[&str],
        policy: &ExternalAgentConfig,
        channel: ExternalAgentChannel,
    ) -> Result<PathBuf, String> {
        if !policy.allows_write(channel) {
            return Err(
                "当前为「仅只读检索与导出」模式，禁止通过 `output_path` 写入本地磁盘；请移除 `output_path` 使用内联返回图片，或在设置中开启写入权限。"
                    .to_string(),
            );
        }
        let trimmed = raw_path.trim();
        if trimmed.is_empty()
            || trimmed.chars().any(|c| c.is_control())
            || trimmed.starts_with(r"\\")
            || trimmed.starts_with("//")
        {
            return Err(
                "`output_path` is empty, contains control characters, or points to a UNC path."
                    .to_string(),
            );
        }
        let path = PathBuf::from(trimmed);
        if path
            .components()
            .any(|c| matches!(c, std::path::Component::ParentDir))
        {
            return Err("`output_path` cannot contain `..` path traversal segments.".to_string());
        }
        let ext = path
            .extension()
            .and_then(|s| s.to_str())
            .map(|s| s.to_ascii_lowercase())
            .unwrap_or_default();
        if !allowed_extensions.iter().any(|allowed| *allowed == ext) {
            return Err(format!(
                "Unsupported `output_path` extension '.{ext}'. Allowed: {}",
                allowed_extensions.join(", ")
            ));
        }
        let file_name = path
            .file_name()
            .ok_or_else(|| "`output_path` must include a file name.".to_string())?;
        let parent = path
            .parent()
            .filter(|p| !p.as_os_str().is_empty())
            .unwrap_or_else(|| Path::new("."));

        // Canonicalize the nearest existing ancestor to defeat symlink and lexical traversal bypasses.
        let mut probe = parent.to_path_buf();
        let mut pending_tail: Vec<std::ffi::OsString> = Vec::new();
        while !probe.exists() {
            let Some(name) = probe.file_name() else {
                break;
            };
            pending_tail.push(name.to_os_string());
            let Some(next_parent) = probe.parent() else {
                break;
            };
            probe = next_parent.to_path_buf();
        }
        let mut resolved = std::fs::canonicalize(&probe).unwrap_or(probe);
        for seg in pending_tail.into_iter().rev() {
            resolved.push(seg);
        }
        resolved.push(file_name);

        let resolved_str = resolved
            .to_string_lossy()
            .replace('/', "\\")
            .to_ascii_lowercase();
        if resolved_str.starts_with(r"\\?\unc\") {
            return Err("`output_path` cannot target a remote UNC network share.".to_string());
        }
        let canon_data_dir = std::fs::canonicalize(&self.data_dir)
            .unwrap_or_else(|_| self.data_dir.clone())
            .to_string_lossy()
            .replace('/', "\\")
            .to_ascii_lowercase();
        let norm_resolved = resolved_str.strip_prefix(r"\\?\").unwrap_or(&resolved_str);
        let norm_data_dir = canon_data_dir
            .strip_prefix(r"\\?\")
            .unwrap_or(&canon_data_dir);
        if !norm_data_dir.is_empty()
            && (norm_resolved == norm_data_dir
                || norm_resolved.starts_with(&format!("{norm_data_dir}\\")))
        {
            return Err(
                "`output_path` cannot write inside Charkle's managed library directory."
                    .to_string(),
            );
        }
        for forbidden in [
            "\\.ssh\\",
            "\\.gnupg\\",
            "\\.aws\\",
            "\\windows\\system32\\",
            "\\program files\\",
            "\\program files (x86)\\",
        ] {
            if norm_resolved.contains(forbidden) {
                return Err(format!(
                    "`output_path` points to a protected system directory ({forbidden})."
                ));
            }
        }
        Ok(resolved)
    }

    fn validate_agent_ingest_file_path(&self, raw: &str) -> Result<PathBuf, String> {
        let trimmed = raw.trim();
        if trimmed.is_empty()
            || trimmed.chars().any(|c| c.is_control())
            || trimmed.starts_with(r"\\")
            || trimmed.starts_with("//")
        {
            return Err("Rejected empty, malformed, or UNC file_path.".to_string());
        }
        let path = PathBuf::from(trimmed);
        if path
            .components()
            .any(|c| matches!(c, std::path::Component::ParentDir))
        {
            return Err("`file_path` cannot contain `..` traversal segments.".to_string());
        }
        let canon = std::fs::canonicalize(&path)
            .map_err(|_| format!("File not found or inaccessible: {trimmed}"))?;
        let meta =
            std::fs::metadata(&canon).map_err(|_| format!("Unable to inspect file: {trimmed}"))?;
        if !meta.is_file() {
            return Err("`file_path` must refer to a regular file.".to_string());
        }
        const MAX_AGENT_INGEST_BYTES: u64 = 256 * 1024 * 1024;
        if meta.len() > MAX_AGENT_INGEST_BYTES {
            return Err("`file_path` exceeds 256 MiB ingest limit.".to_string());
        }
        let canon_str = canon
            .to_string_lossy()
            .replace('/', "\\")
            .to_ascii_lowercase();
        if canon_str.starts_with(r"\\?\unc\") {
            return Err("Remote UNC paths are forbidden for agent file ingest.".to_string());
        }
        let norm = canon_str.strip_prefix(r"\\?\").unwrap_or(&canon_str);
        let canon_data_dir = std::fs::canonicalize(&self.data_dir)
            .unwrap_or_else(|_| self.data_dir.clone())
            .to_string_lossy()
            .replace('/', "\\")
            .to_ascii_lowercase();
        let norm_data_dir = canon_data_dir
            .strip_prefix(r"\\?\")
            .unwrap_or(&canon_data_dir);
        if !norm_data_dir.is_empty()
            && (norm == norm_data_dir || norm.starts_with(&format!("{norm_data_dir}\\")))
        {
            return Err(
                "Cannot ingest files from inside Charkle's managed data directory.".to_string(),
            );
        }
        for forbidden in [
            "\\.ssh\\",
            "\\.gnupg\\",
            "\\.aws\\",
            "\\.kube\\",
            "\\windows\\system32\\",
            "\\windows\\syswow64\\",
            "\\programdata\\microsoft\\",
            "\\appdata\\local\\google\\chrome\\user data\\",
            "\\appdata\\local\\microsoft\\edge\\user data\\",
            "\\etc\\shadow",
            "\\etc\\passwd",
        ] {
            if norm.contains(forbidden) {
                return Err(format!(
                    "`file_path` targets a protected system or credential path ({forbidden})."
                ));
            }
        }
        let file_name = canon
            .file_name()
            .and_then(|s| s.to_str())
            .map(|s| s.to_ascii_lowercase())
            .unwrap_or_default();
        if file_name == ".env"
            || file_name.starts_with(".env.")
            || file_name == "id_rsa"
            || file_name == "id_ed25519"
            || file_name.ends_with(".pem")
            || file_name.ends_with(".key")
            || file_name.ends_with(".pfx")
            || file_name.ends_with(".p12")
        {
            return Err(format!(
                "Refused to ingest sensitive secret file `{file_name}`."
            ));
        }
        Ok(canon)
    }

    // =========================================================================
    // 12 Read Tools
    // =========================================================================

    fn handle_library_overview(
        &self,
        args: &Value,
        policy: &ExternalAgentConfig,
        channel: ExternalAgentChannel,
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
                    entry.insert("recursiveAssetCount".into(), json!(profile.recursive_count));
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
                    entry.insert("recursiveAssetCount".into(), json!(f.asset_count));
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
        payload.insert("mcpEnabled".into(), json!(policy.mcp_enabled));
        payload.insert("cliEnabled".into(), json!(policy.cli_enabled));
        payload.insert(
            "accessLevel".into(),
            serde_json::to_value(policy.access_level).unwrap_or(json!("readOnly")),
        );
        payload.insert("canWrite".into(), json!(policy.allows_write(channel)));
        payload.insert("mediaKindCounts".into(), json!(kind_counts));
        payload.insert("aspectShapeCounts".into(), json!(aspect_counts));
        payload.insert("folders".into(), json!(folder_items));
        payload.insert("smartFolders".into(), json!(smart_folder_items));
        payload.insert("topTags".into(), json!(tag_items));

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

    fn fetch_filtered_assets(
        &self,
        args: &Value,
    ) -> CoreResult<(Vec<AssetRecord>, HashMap<Uuid, String>)> {
        let folders = self.engine.fetch_folders()?;
        let folder_paths = build_folder_paths(&folders);
        let criteria = self.build_filter_criteria(args, &folders, &folder_paths)?;
        let mut matches = self.engine.fetch_assets(&criteria)?;

        // Optional Smart Folder evaluation filter
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
        if smart_folder_id.is_some() || smart_folder_name.is_some() {
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
            let Some(sf) = found else {
                return Err(CoreError::NotFound("Smart folder not found.".to_string()));
            };
            matches.retain(|a| sf.rule.matches(a));
        }

        matches = self.apply_post_filters(matches, args)?;
        Ok((matches, folder_paths))
    }

    fn apply_post_filters(
        &self,
        assets: Vec<AssetRecord>,
        args: &Value,
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
        let exclude_ids: HashSet<Uuid> = self
            .resolve_asset_uuid_list(args.get("exclude_asset_ids"))?
            .into_iter()
            .collect();
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

    /// Suppresses visual near-duplicates (identical `content_hash` or calibrated local visual
    /// similarity `>= 0.78`) and interleaves candidates across folders in round-robin passes so
    /// even the first 5–16 tiles maximize visual and stylistic diversity.
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
        columns: Option<u32>,
        output_path: Option<&Path>,
    ) -> CoreResult<Option<AttachedContactSheet>> {
        if assets.is_empty() {
            return Ok(None);
        }
        let sheet = render_contact_sheet_with_options(
            assets,
            self.engine.media(),
            ContactSheetOptions {
                columns,
                max_width: max_width.clamp(CONTACT_SHEET_MIN_WIDTH, CONTACT_SHEET_MAX_WIDTH),
                jpeg_quality,
            },
        )?;
        let mut saved_path = None;
        if let Some(out_path) = output_path {
            if let Some(parent) = out_path.parent() {
                if !parent.as_os_str().is_empty() {
                    std::fs::create_dir_all(parent)?;
                }
            }
            std::fs::write(out_path, &sheet.jpeg_bytes)?;
            saved_path = Some(out_path.display().to_string());
        }
        Ok(Some(AttachedContactSheet {
            slot_count: sheet.slots.len(),
            jpeg_bytes: sheet.jpeg_bytes,
            width: sheet.width,
            height: sheet.height,
            saved_path,
        }))
    }

    #[allow(clippy::too_many_arguments)]
    fn run_multi_query_recall(
        &self,
        queries: &[String],
        criteria: &FilterCriteria,
        args: &Value,
        seed_ids: &[Uuid],
        unlike_ids: &[Uuid],
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
        let fetch_per_group = (per_group_quota * 3).max(18);

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
            let post_filtered_ids: HashSet<Uuid> = self
                .apply_post_filters(report.hits.iter().map(|h| h.asset.clone()).collect(), args)?
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

    fn handle_search_assets(
        &self,
        args: &Value,
        policy: &ExternalAgentConfig,
        channel: ExternalAgentChannel,
    ) -> CoreResult<ToolOutput> {
        let want_sheet = bool_arg(args.get("render_contact_sheet")).unwrap_or(false);
        let include_image = bool_arg(args.get("include_image")).unwrap_or(true);
        let validated_out = if want_sheet {
            if let Some(out_path) = args
                .get("output_path")
                .and_then(Value::as_str)
                .map(str::trim)
                .filter(|s| !s.is_empty())
            {
                match self.validate_export_output_path(out_path, &["jpg", "jpeg"], policy, channel)
                {
                    Ok(p) => Some(p),
                    Err(msg) => return Ok(ToolOutput::error(msg)),
                }
            } else {
                None
            }
        } else {
            None
        };

        let (matches, folder_paths) = self.fetch_filtered_assets(args)?;
        let total_matched = matches.len();
        let offset = args.get("offset").and_then(Value::as_u64).unwrap_or(0) as usize;
        let default_limit = if want_sheet { 16 } else { 20 };
        let limit = args
            .get("limit")
            .and_then(Value::as_u64)
            .unwrap_or(default_limit)
            .clamp(1, 100) as usize;
        let default_detail = if want_sheet && include_image {
            AssetDetailLevel::Visual
        } else {
            AssetDetailLevel::Compact
        };
        let detail = AssetDetailLevel::parse(args.get("detail"), default_detail);
        let diversify = bool_arg(args.get("diversify")).unwrap_or(false);

        let sliced_assets: Vec<AssetRecord> = if diversify && offset == 0 {
            self.diversify_assets(&matches, limit)
        } else {
            matches.iter().skip(offset).take(limit).cloned().collect()
        };

        let mut serialized: Vec<Value> = sliced_assets
            .iter()
            .map(|a| serialize_asset_summary(a, &folder_paths, detail))
            .collect();
        let next_offset = offset + serialized.len();
        let has_more = next_offset < total_matched;

        let mut payload = Map::new();
        payload.insert("totalMatched".into(), json!(total_matched));
        payload.insert("offset".into(), json!(offset));
        payload.insert("returned".into(), json!(serialized.len()));
        payload.insert("hasMore".into(), json!(has_more));
        if has_more {
            payload.insert("nextOffset".into(), json!(next_offset));
        }
        if diversify {
            payload.insert("diversified".into(), json!(true));
        }
        let include_facets = bool_arg(args.get("include_facets")).unwrap_or(total_matched > limit);
        if include_facets && !matches.is_empty() {
            payload.insert(
                "facets".into(),
                compute_result_facets(&matches, &folder_paths),
            );
        }

        if want_sheet && !sliced_assets.is_empty() {
            let max_width = args
                .get("sheet_max_width")
                .or_else(|| args.get("max_width"))
                .and_then(Value::as_u64)
                .unwrap_or(CONTACT_SHEET_DEFAULT_WIDTH as u64) as u32;
            let cap_assets = &sliced_assets[..sliced_assets.len().min(CONTACT_SHEET_MAX_ASSETS)];
            if let Some(attached) = self.render_attached_contact_sheet(
                cap_assets,
                max_width,
                74,
                None,
                validated_out.as_deref(),
            )? {
                for (idx, item) in serialized.iter_mut().take(attached.slot_count).enumerate() {
                    if let Some(obj) = item.as_object_mut() {
                        obj.insert("slot".into(), json!(idx + 1));
                        obj.insert("badge".into(), json!(format!("#{:02}", idx + 1)));
                    }
                }
                payload.insert("contactSheet".into(), attached.summary());
                payload.insert("assets".into(), json!(serialized));
                let mut content = Vec::new();
                if include_image {
                    content.push(ToolContent::Image {
                        mime_type: "image/jpeg".to_string(),
                        data: attached.jpeg_bytes,
                    });
                }
                content.push(ToolContent::Text(
                    serde_json::to_string(&Value::Object(payload)).unwrap_or_default(),
                ));
                return Ok(ToolOutput {
                    content,
                    is_error: false,
                });
            }
        }

        payload.insert("assets".into(), json!(serialized));
        Ok(ToolOutput::json(Value::Object(payload)))
    }

    fn handle_list_inbox(
        &self,
        args: &Value,
        policy: &ExternalAgentConfig,
        channel: ExternalAgentChannel,
    ) -> CoreResult<ToolOutput> {
        let want_sheet = bool_arg(args.get("render_contact_sheet")).unwrap_or(false);
        let include_image = bool_arg(args.get("include_image")).unwrap_or(true);
        let validated_out = if want_sheet {
            if let Some(out_path) = args
                .get("output_path")
                .and_then(Value::as_str)
                .map(str::trim)
                .filter(|s| !s.is_empty())
            {
                match self.validate_export_output_path(out_path, &["jpg", "jpeg"], policy, channel)
                {
                    Ok(p) => Some(p),
                    Err(msg) => return Ok(ToolOutput::error(msg)),
                }
            } else {
                None
            }
        } else {
            None
        };

        let offset = args.get("offset").and_then(Value::as_u64).unwrap_or(0) as usize;
        let limit = args
            .get("limit")
            .and_then(Value::as_u64)
            .unwrap_or(if want_sheet { 16 } else { 20 })
            .clamp(1, 100) as usize;
        let kinds = parse_media_kinds(args.get("media_kinds"));
        let sort_by = parse_sort_order(args.get("sort_by").and_then(Value::as_str), false);
        let default_detail = if want_sheet && include_image {
            AssetDetailLevel::Visual
        } else {
            AssetDetailLevel::Compact
        };
        let detail = AssetDetailLevel::parse(args.get("detail"), default_detail);

        let criteria = FilterCriteria {
            only_inbox: true,
            kinds,
            sort_by,
            ..Default::default()
        };
        let matches = self.engine.fetch_assets(&criteria)?;
        let empty = HashMap::new();
        let sliced_assets: Vec<AssetRecord> =
            matches.iter().skip(offset).take(limit).cloned().collect();
        let mut serialized: Vec<Value> = sliced_assets
            .iter()
            .map(|a| serialize_asset_summary(a, &empty, detail))
            .collect();
        let next_offset = offset + serialized.len();
        let has_more = next_offset < matches.len();

        let mut payload = Map::new();
        payload.insert("inboxTotal".into(), json!(matches.len()));
        payload.insert("offset".into(), json!(offset));
        payload.insert("returned".into(), json!(serialized.len()));
        payload.insert("hasMore".into(), json!(has_more));
        if has_more {
            payload.insert("nextOffset".into(), json!(next_offset));
        }

        if want_sheet && !sliced_assets.is_empty() {
            let max_width = args
                .get("sheet_max_width")
                .or_else(|| args.get("max_width"))
                .and_then(Value::as_u64)
                .unwrap_or(CONTACT_SHEET_DEFAULT_WIDTH as u64) as u32;
            let cap_assets = &sliced_assets[..sliced_assets.len().min(CONTACT_SHEET_MAX_ASSETS)];
            if let Some(attached) = self.render_attached_contact_sheet(
                cap_assets,
                max_width,
                74,
                None,
                validated_out.as_deref(),
            )? {
                for (idx, item) in serialized.iter_mut().take(attached.slot_count).enumerate() {
                    if let Some(obj) = item.as_object_mut() {
                        obj.insert("slot".into(), json!(idx + 1));
                        obj.insert("badge".into(), json!(format!("#{:02}", idx + 1)));
                    }
                }
                payload.insert("contactSheet".into(), attached.summary());
                payload.insert("assets".into(), json!(serialized));
                let mut content = Vec::new();
                if include_image {
                    content.push(ToolContent::Image {
                        mime_type: "image/jpeg".to_string(),
                        data: attached.jpeg_bytes,
                    });
                }
                content.push(ToolContent::Text(
                    serde_json::to_string(&Value::Object(payload)).unwrap_or_default(),
                ));
                return Ok(ToolOutput {
                    content,
                    is_error: false,
                });
            }
        }

        payload.insert("assets".into(), json!(serialized));
        Ok(ToolOutput::json(Value::Object(payload)))
    }

    fn serialize_asset_detail(
        &self,
        asset: &AssetRecord,
        folder_paths: &HashMap<Uuid, String>,
    ) -> Value {
        let mut obj = serialize_asset_summary(asset, folder_paths, AssetDetailLevel::Standard);
        let thumb_path = self
            .engine
            .media()
            .thumbnail_url(asset.id, ThumbnailTier::Preview1400)
            .or_else(|| {
                self.engine
                    .media()
                    .thumbnail_url(asset.id, ThumbnailTier::Grid520)
            });
        let orig_path = self
            .engine
            .media()
            .cached_original(asset)
            .map(|p| p.display().to_string())
            .unwrap_or_default();
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
            if let Some(ref tp) = thumb_path {
                map.insert("thumbnailPath".into(), json!(tp.display().to_string()));
            }
            if !orig_path.is_empty() {
                map.insert("localOriginalPath".into(), json!(orig_path));
            }
        }
        obj
    }

    fn read_preview_jpeg(&self, asset: &AssetRecord) -> Option<Vec<u8>> {
        let thumb_path = self
            .engine
            .media()
            .thumbnail_url(asset.id, ThumbnailTier::Preview1400)
            .or_else(|| {
                self.engine
                    .media()
                    .thumbnail_url(asset.id, ThumbnailTier::Grid520)
            });
        if let Some(path) = thumb_path {
            if let Ok(bytes) = std::fs::read(&path) {
                return Some(bytes);
            }
        }
        None
    }

    fn handle_get_asset(&self, args: &Value) -> CoreResult<ToolOutput> {
        let include_image = bool_arg(args.get("include_image")).unwrap_or(false);
        let max_side = args
            .get("image_max_side")
            .and_then(Value::as_u64)
            .unwrap_or(768)
            .clamp(280, 1568) as u32;

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
                match self.engine.fetch_asset(*uuid)? {
                    Some(asset) => {
                        serialized.push(self.serialize_asset_detail(&asset, &folder_paths));
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
                    if let Some(jpeg) = self.read_preview_jpeg(&resolved_assets[0]) {
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
                    if let Some(attached) = self.render_attached_contact_sheet(
                        &resolved_assets,
                        sheet_width,
                        82,
                        None,
                        None,
                    )? {
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

        // Single asset mode (full UUID or unambiguous 8+ char prefix)
        let raw_id = args
            .get("asset_id")
            .or_else(|| args.get("id"))
            .and_then(Value::as_str)
            .unwrap_or("");
        if raw_id.trim().is_empty() {
            return Ok(ToolOutput::error(
                "Missing or invalid UUID / prefix for `asset_id` (or pass `asset_ids` array).",
            ));
        }
        let uuid = self.resolve_asset_uuid(raw_id)?;
        let Some(asset) = self.engine.fetch_asset(uuid)? else {
            return Ok(ToolOutput::error(format!(
                "Asset not found: {}",
                format_swift_uuid(&uuid)
            )));
        };
        let folders = self.engine.fetch_folders()?;
        let folder_paths = build_folder_paths(&folders);
        let obj = self.serialize_asset_detail(&asset, &folder_paths);

        let mut content = Vec::new();
        if include_image {
            if let Some(bytes) = self.read_preview_jpeg(&asset) {
                content.push(ToolContent::Image {
                    mime_type: "image/jpeg".to_string(),
                    data: bytes,
                });
            }
        }
        content.push(ToolContent::Text(
            serde_json::to_string(&obj).unwrap_or_default(),
        ));
        Ok(ToolOutput {
            content,
            is_error: false,
        })
    }

    fn handle_render_contact_sheet(
        &self,
        args: &Value,
        policy: &ExternalAgentConfig,
        channel: ExternalAgentChannel,
    ) -> CoreResult<ToolOutput> {
        let validated_out = if let Some(out_path) = args
            .get("output_path")
            .and_then(Value::as_str)
            .map(str::trim)
            .filter(|s| !s.is_empty())
        {
            match self.validate_export_output_path(out_path, &["jpg", "jpeg"], policy, channel) {
                Ok(p) => Some(p),
                Err(msg) => return Ok(ToolOutput::error(msg)),
            }
        } else {
            None
        };

        let folders = self.engine.fetch_folders()?;
        let folder_paths = build_folder_paths(&folders);
        let offset = args.get("offset").and_then(Value::as_u64).unwrap_or(0) as usize;
        let limit = args
            .get("limit")
            .and_then(Value::as_u64)
            .unwrap_or(16)
            .clamp(1, CONTACT_SHEET_MAX_ASSETS as u64) as usize;
        let max_width = args
            .get("max_width")
            .or_else(|| args.get("sheet_max_width"))
            .and_then(Value::as_u64)
            .unwrap_or(CONTACT_SHEET_DEFAULT_WIDTH as u64) as u32;
        let columns = args
            .get("columns")
            .and_then(Value::as_u64)
            .map(|c| c.clamp(1, 6) as u32);
        let include_image = bool_arg(args.get("include_image")).unwrap_or(true);
        let diversify = bool_arg(args.get("diversify")).unwrap_or(false);
        let default_detail = if include_image {
            AssetDetailLevel::Visual
        } else {
            AssetDetailLevel::Compact
        };
        let detail = AssetDetailLevel::parse(args.get("detail"), default_detail);

        let sub_queries: Vec<String> = string_array_arg(args.get("queries"));
        let raw_ids = string_array_arg(args.get("asset_ids"));

        let total_matched: usize;
        let mut selected_assets: Vec<AssetRecord> = Vec::new();
        let mut query_group_by_id: HashMap<Uuid, String> = HashMap::new();
        let mut multi_query_groups: Vec<Value> = Vec::new();

        if !raw_ids.is_empty() {
            let resolved_ids = self.resolve_asset_uuid_list(args.get("asset_ids"))?;
            let mut resolved = Vec::new();
            for id in resolved_ids {
                if let Some(a) = self.engine.fetch_asset(id)? {
                    resolved.push(a);
                }
            }
            resolved = self.apply_post_filters(resolved, args)?;
            total_matched = resolved.len();
            selected_assets = if diversify && offset == 0 {
                self.diversify_assets(&resolved, limit)
            } else {
                resolved.into_iter().skip(offset).take(limit).collect()
            };
        } else if !sub_queries.is_empty() {
            let mut criteria = self.build_filter_criteria(args, &folders, &folder_paths)?;
            criteria.search_query.clear();
            let multi = self.run_multi_query_recall(
                &sub_queries,
                &criteria,
                args,
                &[],
                &[],
                limit,
                diversify,
            )?;
            total_matched = multi.total_unique_matched;
            multi_query_groups = multi.groups_summary;
            for (hit, qg) in multi.hits {
                query_group_by_id.insert(hit.asset.id, qg);
                selected_assets.push(hit.asset);
            }
        } else {
            let (matches, _) = self.fetch_filtered_assets(args)?;
            total_matched = matches.len();
            selected_assets = if diversify && offset == 0 {
                self.diversify_assets(&matches, limit)
            } else {
                matches.into_iter().skip(offset).take(limit).collect()
            };
        }

        if selected_assets.is_empty() {
            return Ok(ToolOutput::json(json!({
                "totalMatched": total_matched,
                "offset": offset,
                "slotCount": 0,
                "hasMore": false,
                "slots": [],
                "message": "No assets matched the requested filter or asset_ids."
            })));
        }

        let Some(attached) = self.render_attached_contact_sheet(
            &selected_assets,
            max_width,
            74,
            columns,
            validated_out.as_deref(),
        )?
        else {
            return Ok(ToolOutput::error("Failed to render Contact Sheet image."));
        };

        let slots: Vec<Value> = selected_assets
            .iter()
            .take(attached.slot_count)
            .enumerate()
            .map(|(idx, asset)| {
                let slot = idx + 1;
                let badge = format!("#{slot:02}");
                let folder_path = asset
                    .folder_id
                    .and_then(|id| folder_paths.get(&id).cloned())
                    .unwrap_or_else(|| "Inbox".to_string());
                let full_id = format_swift_uuid(&asset.id);
                let mut entry = Map::new();
                entry.insert("slot".into(), json!(slot));
                entry.insert("badge".into(), json!(badge));
                if detail == AssetDetailLevel::Visual {
                    entry.insert("assetID".into(), json!(&full_id[..8]));
                    entry.insert("title".into(), json!(truncate_text(&asset.title, 42)));
                    entry.insert("folderPath".into(), json!(folder_path));
                    if asset.pixel_width > 0 && asset.pixel_height > 0 {
                        entry.insert(
                            "dimensions".into(),
                            json!(format!("{}x{}", asset.pixel_width, asset.pixel_height)),
                        );
                    } else {
                        entry.insert(
                            "aspectShape".into(),
                            json!(asset.aspect_shape().raw_value()),
                        );
                    }
                    if let Some(c) = asset.dominant_colors.first() {
                        entry.insert("dominantHex".into(), json!(c.hex.to_uppercase()));
                    }
                    if !asset.tags.is_empty() {
                        entry.insert(
                            "tags".into(),
                            json!(asset.tags.iter().take(4).collect::<Vec<_>>()),
                        );
                    }
                    if asset.media_kind != MediaKind::Image {
                        entry.insert("mediaKind".into(), json!(asset.media_kind.raw_value()));
                    }
                    if asset.rating > 0 {
                        entry.insert("rating".into(), json!(asset.rating));
                    }
                } else {
                    entry.insert("assetID".into(), json!(full_id));
                    entry.insert("title".into(), json!(asset.title));
                    entry.insert("mediaKind".into(), json!(asset.media_kind.raw_value()));
                    entry.insert("folderPath".into(), json!(folder_path));
                    entry.insert(
                        "aspectRatio".into(),
                        json!((asset.aspect_ratio() * 100.0).round() / 100.0),
                    );
                    if asset.pixel_width > 0 && asset.pixel_height > 0 {
                        entry.insert(
                            "dimensions".into(),
                            json!(format!("{}x{}", asset.pixel_width, asset.pixel_height)),
                        );
                    }
                    if asset.rating > 0 {
                        entry.insert("rating".into(), json!(asset.rating));
                    }
                    if !asset.tags.is_empty() {
                        entry.insert("tags".into(), json!(asset.tags));
                    }
                    let colors: Vec<String> = asset
                        .dominant_colors
                        .iter()
                        .take(3)
                        .map(|c| c.hex.to_uppercase())
                        .collect();
                    if !colors.is_empty() {
                        entry.insert("dominantColors".into(), json!(colors));
                    }
                    if let Some(ref desc) = asset.ai_description {
                        let d = desc.trim();
                        if !d.is_empty() {
                            entry.insert("aiDescription".into(), json!(truncate_text(d, 110)));
                        }
                    }
                }
                if let Some(qg) = query_group_by_id.get(&asset.id) {
                    entry.insert("queryGroup".into(), json!(qg));
                }
                Value::Object(entry)
            })
            .collect();

        let next_offset = offset + slots.len();
        let has_more = next_offset < total_matched;
        let mut meta = Map::new();
        meta.insert("sheetWidth".into(), json!(attached.width));
        meta.insert("sheetHeight".into(), json!(attached.height));
        meta.insert("width".into(), json!(attached.width));
        meta.insert("height".into(), json!(attached.height));
        meta.insert("totalMatched".into(), json!(total_matched));
        meta.insert("offset".into(), json!(offset));
        meta.insert("slotCount".into(), json!(slots.len()));
        meta.insert("count".into(), json!(slots.len()));
        meta.insert("hasMore".into(), json!(has_more));
        if has_more {
            meta.insert("nextOffset".into(), json!(next_offset));
        }
        if diversify {
            meta.insert("diversified".into(), json!(true));
        }
        if !multi_query_groups.is_empty() {
            meta.insert("queryGroups".into(), json!(multi_query_groups));
        }
        if let Some(ref sp) = attached.saved_path {
            meta.insert("savedPath".into(), json!(sp));
        }
        meta.insert("slots".into(), json!(slots));

        let mut content = Vec::new();
        if include_image {
            content.push(ToolContent::Image {
                mime_type: "image/jpeg".to_string(),
                data: attached.jpeg_bytes,
            });
        }
        content.push(ToolContent::Text(
            serde_json::to_string(&Value::Object(meta)).unwrap_or_default(),
        ));
        Ok(ToolOutput {
            content,
            is_error: false,
        })
    }

    fn handle_find_similar_assets(
        &self,
        args: &Value,
        policy: &ExternalAgentConfig,
        channel: ExternalAgentChannel,
    ) -> CoreResult<ToolOutput> {
        let raw_id = args
            .get("asset_id")
            .or_else(|| args.get("id"))
            .and_then(Value::as_str)
            .unwrap_or("");
        if raw_id.trim().is_empty() {
            return Ok(ToolOutput::error(
                "Missing or invalid UUID / prefix for `asset_id`.",
            ));
        }
        let uuid = self.resolve_asset_uuid(raw_id)?;
        if self.engine.fetch_asset(uuid)?.is_none() {
            return Ok(ToolOutput::error(format!(
                "Asset not found: {}",
                format_swift_uuid(&uuid)
            )));
        }

        let want_sheet = bool_arg(args.get("render_contact_sheet")).unwrap_or(false);
        let include_image = bool_arg(args.get("include_image")).unwrap_or(true);
        let validated_out = if want_sheet {
            if let Some(out_path) = args
                .get("output_path")
                .and_then(Value::as_str)
                .map(str::trim)
                .filter(|s| !s.is_empty())
            {
                match self.validate_export_output_path(out_path, &["jpg", "jpeg"], policy, channel)
                {
                    Ok(p) => Some(p),
                    Err(msg) => return Ok(ToolOutput::error(msg)),
                }
            } else {
                None
            }
        } else {
            None
        };

        let limit = args
            .get("limit")
            .and_then(Value::as_u64)
            .unwrap_or(12)
            .clamp(1, 32) as usize;
        let diversify = bool_arg(args.get("diversify")).unwrap_or(false);
        let default_detail = if want_sheet && include_image {
            AssetDetailLevel::Visual
        } else {
            AssetDetailLevel::Compact
        };
        let detail = AssetDetailLevel::parse(args.get("detail"), default_detail);

        let excluded_ids: HashSet<Uuid> = self
            .resolve_asset_uuid_list(args.get("exclude_asset_ids"))?
            .into_iter()
            .collect();
        let unlike_ids = self.resolve_asset_uuid_list(args.get("unlike_asset_ids"))?;
        let unlike_set: HashSet<Uuid> = unlike_ids.iter().copied().collect();

        let fetch_limit = if diversify || !excluded_ids.is_empty() || !unlike_set.is_empty() {
            (limit * 3).min(64)
        } else {
            limit
        };
        let mut scored = self.engine.similar_assets(uuid, fetch_limit)?;
        if !excluded_ids.is_empty() || !unlike_set.is_empty() {
            scored.retain(|s| {
                !excluded_ids.contains(&s.asset.id) && !unlike_set.contains(&s.asset.id)
            });
        }

        // Apply negative visual repulsion when `unlike_asset_ids` is provided
        if !unlike_ids.is_empty() && !scored.is_empty() {
            let mut unlike_assets = Vec::new();
            for &uid in &unlike_ids {
                if let Some(a) = self.engine.fetch_asset(uid)? {
                    unlike_assets.push(a);
                }
            }
            if !unlike_assets.is_empty() {
                let vectors = self.engine.vectors_map().unwrap_or_default();
                let mut pool: Vec<AssetRecord> = scored.iter().map(|s| s.asset.clone()).collect();
                pool.extend(unlike_assets.iter().cloned());
                let descriptors =
                    self.engine
                        .visual_descriptors_for_assets(&pool, &unlike_ids, 120);
                for item in &mut scored {
                    let max_neg = unlike_assets
                        .iter()
                        .map(|neg| {
                            LiveCharkleEngine::visual_pair_similarity(
                                &item.asset,
                                neg,
                                &vectors,
                                &descriptors,
                            )
                        })
                        .fold(0.0_f64, f64::max);
                    if max_neg >= 0.42 {
                        let penalty = (1.0 - (max_neg - 0.35) * 1.15).max(0.15);
                        item.score *= penalty;
                    }
                }
                scored.sort_by(|a, b| {
                    b.score
                        .partial_cmp(&a.score)
                        .unwrap_or(std::cmp::Ordering::Equal)
                });
            }
        }

        if diversify && scored.len() > 1 {
            let div_assets = self.diversify_assets(
                &scored.iter().map(|s| s.asset.clone()).collect::<Vec<_>>(),
                limit,
            );
            let mut by_id: HashMap<Uuid, _> = scored.into_iter().map(|s| (s.asset.id, s)).collect();
            scored = div_assets
                .into_iter()
                .filter_map(|a| by_id.remove(&a.id))
                .collect();
        } else {
            scored.truncate(limit);
        }

        let folders = self.engine.fetch_folders()?;
        let folder_paths = build_folder_paths(&folders);

        let mut items: Vec<Value> = scored
            .iter()
            .enumerate()
            .map(|(idx, s)| {
                let mut dict = serialize_asset_summary(&s.asset, &folder_paths, detail);
                if let Some(obj) = dict.as_object_mut() {
                    obj.insert("rank".into(), json!(idx + 1));
                    obj.insert("score".into(), json!((s.score * 1000.0).round() / 1000.0));
                    if detail != AssetDetailLevel::Visual && !s.match_reasons.is_empty() {
                        obj.insert("matchReasons".into(), json!(s.match_reasons));
                    }
                }
                dict
            })
            .collect();

        let mut payload = Map::new();
        payload.insert("referenceAssetID".into(), json!(format_swift_uuid(&uuid)));
        payload.insert("returned".into(), json!(items.len()));
        payload.insert("count".into(), json!(items.len()));

        if want_sheet && !scored.is_empty() {
            let max_width = args
                .get("sheet_max_width")
                .or_else(|| args.get("max_width"))
                .and_then(Value::as_u64)
                .unwrap_or(CONTACT_SHEET_DEFAULT_WIDTH as u64) as u32;
            let sheet_assets: Vec<AssetRecord> = scored
                .iter()
                .take(CONTACT_SHEET_MAX_ASSETS)
                .map(|s| s.asset.clone())
                .collect();
            if let Some(attached) = self.render_attached_contact_sheet(
                &sheet_assets,
                max_width,
                74,
                None,
                validated_out.as_deref(),
            )? {
                for (idx, item) in items.iter_mut().take(attached.slot_count).enumerate() {
                    if let Some(obj) = item.as_object_mut() {
                        obj.insert("slot".into(), json!(idx + 1));
                        obj.insert("badge".into(), json!(format!("#{:02}", idx + 1)));
                    }
                }
                payload.insert("contactSheet".into(), attached.summary());
                payload.insert("matches".into(), json!(items));
                let mut content = Vec::new();
                if include_image {
                    content.push(ToolContent::Image {
                        mime_type: "image/jpeg".to_string(),
                        data: attached.jpeg_bytes,
                    });
                }
                content.push(ToolContent::Text(
                    serde_json::to_string(&Value::Object(payload)).unwrap_or_default(),
                ));
                return Ok(ToolOutput {
                    content,
                    is_error: false,
                });
            }
        }

        payload.insert("matches".into(), json!(items));
        Ok(ToolOutput::json(Value::Object(payload)))
    }

    fn handle_semantic_search(
        &self,
        args: &Value,
        policy: &ExternalAgentConfig,
        channel: ExternalAgentChannel,
    ) -> CoreResult<ToolOutput> {
        let query = args
            .get("query")
            .and_then(Value::as_str)
            .map(str::trim)
            .unwrap_or("");
        let sub_queries = string_array_arg(args.get("queries"));
        let seed_ids = self.resolve_asset_uuid_list(args.get("seed_asset_ids"))?;
        let unlike_ids = self.resolve_asset_uuid_list(args.get("unlike_asset_ids"))?;
        if query.is_empty() && sub_queries.is_empty() && seed_ids.is_empty() {
            return Ok(ToolOutput::error(
                "Provide `query`, `queries[]`, or `seed_asset_ids` for semantic_search.",
            ));
        }

        let want_sheet = bool_arg(args.get("render_contact_sheet")).unwrap_or(false);
        let include_image = bool_arg(args.get("include_image")).unwrap_or(true);
        let validated_out = if want_sheet {
            if let Some(out_path) = args
                .get("output_path")
                .and_then(Value::as_str)
                .map(str::trim)
                .filter(|s| !s.is_empty())
            {
                match self.validate_export_output_path(out_path, &["jpg", "jpeg"], policy, channel)
                {
                    Ok(p) => Some(p),
                    Err(msg) => return Ok(ToolOutput::error(msg)),
                }
            } else {
                None
            }
        } else {
            None
        };

        let folders = self.engine.fetch_folders()?;
        let folder_paths = build_folder_paths(&folders);
        let mut criteria = self.build_filter_criteria(args, &folders, &folder_paths)?;
        criteria.search_query.clear();

        let limit = args
            .get("limit")
            .and_then(Value::as_u64)
            .unwrap_or(16)
            .clamp(1, 50) as usize;
        let diversify = bool_arg(args.get("diversify")).unwrap_or(false);
        let default_detail = if want_sheet && include_image {
            AssetDetailLevel::Visual
        } else {
            AssetDetailLevel::Compact
        };
        let detail = AssetDetailLevel::parse(args.get("detail"), default_detail);

        // Multi-direction single-call recall (`queries: [...]`)
        if sub_queries.len() >= 2 {
            let multi = self.run_multi_query_recall(
                &sub_queries,
                &criteria,
                args,
                &seed_ids,
                &unlike_ids,
                limit,
                diversify,
            )?;
            let mut hits: Vec<Value> = multi
                .hits
                .iter()
                .enumerate()
                .map(|(idx, (hit, qg))| {
                    let mut dict = serialize_asset_summary(&hit.asset, &folder_paths, detail);
                    if let Some(obj) = dict.as_object_mut() {
                        obj.insert("rank".into(), json!(idx + 1));
                        obj.insert("score".into(), json!((hit.score * 1000.0).round() / 1000.0));
                        obj.insert("queryGroup".into(), json!(qg));
                        if detail != AssetDetailLevel::Visual && !hit.reason.is_empty() {
                            obj.insert("reason".into(), json!(hit.reason));
                        }
                    }
                    dict
                })
                .collect();

            let mut payload = Map::new();
            payload.insert("queries".into(), json!(sub_queries));
            payload.insert("queryGroups".into(), json!(multi.groups_summary));
            payload.insert("usedCloudEmbedding".into(), json!(false));
            payload.insert("usedVisualRerank".into(), json!(false));
            payload.insert("evaluatedVisualCount".into(), json!(0));
            payload.insert("returned".into(), json!(hits.len()));
            if diversify {
                payload.insert("diversified".into(), json!(true));
            }

            if want_sheet && !multi.hits.is_empty() {
                let max_width =
                    args.get("sheet_max_width")
                        .or_else(|| args.get("max_width"))
                        .and_then(Value::as_u64)
                        .unwrap_or(CONTACT_SHEET_DEFAULT_WIDTH as u64) as u32;
                let sheet_assets: Vec<AssetRecord> = multi
                    .hits
                    .iter()
                    .take(CONTACT_SHEET_MAX_ASSETS)
                    .map(|(h, _)| h.asset.clone())
                    .collect();
                if let Some(attached) = self.render_attached_contact_sheet(
                    &sheet_assets,
                    max_width,
                    74,
                    None,
                    validated_out.as_deref(),
                )? {
                    for (idx, item) in hits.iter_mut().take(attached.slot_count).enumerate() {
                        if let Some(obj) = item.as_object_mut() {
                            obj.insert("slot".into(), json!(idx + 1));
                            obj.insert("badge".into(), json!(format!("#{:02}", idx + 1)));
                        }
                    }
                    payload.insert("contactSheet".into(), attached.summary());
                    payload.insert("hits".into(), json!(hits));
                    let mut content = Vec::new();
                    if include_image {
                        content.push(ToolContent::Image {
                            mime_type: "image/jpeg".to_string(),
                            data: attached.jpeg_bytes,
                        });
                    }
                    content.push(ToolContent::Text(
                        serde_json::to_string(&Value::Object(payload)).unwrap_or_default(),
                    ));
                    return Ok(ToolOutput {
                        content,
                        is_error: false,
                    });
                }
            }
            payload.insert("hits".into(), json!(hits));
            return Ok(ToolOutput::json(Value::Object(payload)));
        }

        let effective_query = if !query.is_empty() {
            query
        } else {
            sub_queries.first().map(String::as_str).unwrap_or("")
        };
        let fetch_limit = if diversify {
            (limit * 3).clamp(36, 64)
        } else {
            limit.clamp(24, 64)
        };
        let report = self.engine.semantic_search_local(
            effective_query,
            &criteria,
            fetch_limit,
            &seed_ids,
            &unlike_ids,
        )?;

        let post_filtered_ids: HashSet<Uuid> = self
            .apply_post_filters(report.hits.iter().map(|h| h.asset.clone()).collect(), args)?
            .into_iter()
            .map(|a| a.id)
            .collect();
        let all_filtered: Vec<LocalSemanticSearchHit> = report
            .hits
            .into_iter()
            .filter(|h| post_filtered_ids.contains(&h.asset.id))
            .collect();
        let matched_total = all_filtered.len();

        let filtered_hits: Vec<LocalSemanticSearchHit> = if diversify && all_filtered.len() > 1 {
            let div_assets = self.diversify_assets(
                &all_filtered
                    .iter()
                    .map(|h| h.asset.clone())
                    .collect::<Vec<_>>(),
                limit,
            );
            let mut by_id: HashMap<Uuid, LocalSemanticSearchHit> = all_filtered
                .iter()
                .cloned()
                .map(|h| (h.asset.id, h))
                .collect();
            div_assets
                .into_iter()
                .filter_map(|a| by_id.remove(&a.id))
                .collect()
        } else {
            all_filtered.iter().take(limit).cloned().collect()
        };

        let mut hits: Vec<Value> = filtered_hits
            .iter()
            .enumerate()
            .map(|(idx, hit)| {
                let mut dict = serialize_asset_summary(&hit.asset, &folder_paths, detail);
                if let Some(obj) = dict.as_object_mut() {
                    obj.insert("rank".into(), json!(idx + 1));
                    obj.insert("score".into(), json!((hit.score * 1000.0).round() / 1000.0));
                    if detail != AssetDetailLevel::Visual && !hit.reason.is_empty() {
                        obj.insert("reason".into(), json!(hit.reason));
                    }
                    if detail != AssetDetailLevel::Visual {
                        obj.insert("source".into(), json!(hit.source_label));
                    }
                }
                dict
            })
            .collect();

        let mut payload = Map::new();
        payload.insert("query".into(), json!(report.query));
        payload.insert("summary".into(), json!(report.summary));
        payload.insert("usedCloudEmbedding".into(), json!(false));
        payload.insert("usedVisualRerank".into(), json!(false));
        payload.insert("evaluatedVisualCount".into(), json!(0));
        payload.insert("returned".into(), json!(hits.len()));
        if diversify {
            payload.insert("diversified".into(), json!(true));
        }
        let include_facets = bool_arg(args.get("include_facets")).unwrap_or(matched_total > limit);
        if include_facets && matched_total > 0 {
            let facet_assets: Vec<AssetRecord> =
                all_filtered.iter().map(|h| h.asset.clone()).collect();
            payload.insert(
                "facets".into(),
                compute_result_facets(&facet_assets, &folder_paths),
            );
        }

        if want_sheet && !filtered_hits.is_empty() {
            let max_width = args
                .get("sheet_max_width")
                .or_else(|| args.get("max_width"))
                .and_then(Value::as_u64)
                .unwrap_or(CONTACT_SHEET_DEFAULT_WIDTH as u64) as u32;
            let sheet_assets: Vec<AssetRecord> = filtered_hits
                .iter()
                .take(CONTACT_SHEET_MAX_ASSETS)
                .map(|h| h.asset.clone())
                .collect();
            if let Some(attached) = self.render_attached_contact_sheet(
                &sheet_assets,
                max_width,
                74,
                None,
                validated_out.as_deref(),
            )? {
                for (idx, item) in hits.iter_mut().take(attached.slot_count).enumerate() {
                    if let Some(obj) = item.as_object_mut() {
                        obj.insert("slot".into(), json!(idx + 1));
                        obj.insert("badge".into(), json!(format!("#{:02}", idx + 1)));
                    }
                }
                payload.insert("contactSheet".into(), attached.summary());
                payload.insert("hits".into(), json!(hits));
                let mut content = Vec::new();
                if include_image {
                    content.push(ToolContent::Image {
                        mime_type: "image/jpeg".to_string(),
                        data: attached.jpeg_bytes,
                    });
                }
                content.push(ToolContent::Text(
                    serde_json::to_string(&Value::Object(payload)).unwrap_or_default(),
                ));
                return Ok(ToolOutput {
                    content,
                    is_error: false,
                });
            }
        }

        payload.insert("hits".into(), json!(hits));
        Ok(ToolOutput::json(Value::Object(payload)))
    }

    fn handle_quick_jump(&self, args: &Value) -> CoreResult<ToolOutput> {
        let query = args
            .get("query")
            .and_then(Value::as_str)
            .map(str::trim)
            .unwrap_or("");
        if query.is_empty() {
            return Ok(ToolOutput::error("Missing required `query` string."));
        }
        let limit = args
            .get("limit")
            .and_then(Value::as_u64)
            .unwrap_or(20)
            .clamp(1, 50) as usize;
        let matches = self.engine.quick_jump(query, limit)?;
        Ok(ToolOutput::json(json!({
            "query": query,
            "returned": matches.len(),
            "count": matches.len(),
            "matches": matches
        })))
    }

    fn handle_suggest_folder(&self, args: &Value) -> CoreResult<ToolOutput> {
        let mut ids = self.resolve_asset_uuid_list(args.get("asset_ids"))?;
        if let Some(raw_single) = args
            .get("asset_id")
            .or_else(|| args.get("id"))
            .and_then(Value::as_str)
            .map(str::trim)
            .filter(|s| !s.is_empty())
        {
            let single = self.resolve_asset_uuid(raw_single)?;
            if !ids.contains(&single) {
                ids.insert(0, single);
            }
        }
        if ids.is_empty() {
            return Ok(ToolOutput::error(
                "Provide `asset_id` or `asset_ids` (up to 20 UUIDs or 8+ char prefixes).",
            ));
        }
        let folders = self.engine.fetch_folders()?;
        let folder_paths = build_folder_paths(&folders);
        let mut recommendations = Vec::new();
        for id in ids.into_iter().take(20) {
            let suggestion = self.engine.suggest_folder(id)?;
            recommendations.push(json!({
                "assetID": format_swift_uuid(&id),
                "suggestion": suggestion.map(|s| json!({
                    "folderID": format_swift_uuid(&s.folder_id),
                    "folderName": s.folder_name,
                    "folderPath": folder_paths.get(&s.folder_id).cloned().unwrap_or_default(),
                    "confidence": s.confidence,
                    "reason": s.reason
                }))
            }));
        }
        Ok(ToolOutput::json(json!({
            "evaluatedCount": recommendations.len(),
            "count": recommendations.len(),
            "recommendations": recommendations,
            "suggestions": recommendations
        })))
    }

    fn handle_list_boards(&self) -> CoreResult<ToolOutput> {
        let boards = self.engine.fetch_boards()?;
        let items: Vec<Value> = boards
            .iter()
            .map(|b| {
                json!({
                    "id": format_swift_uuid(&b.id),
                    "title": b.title,
                    "subtitle": b.subtitle,
                    "itemCount": b.item_count,
                    "paletteHexes": b.palette_hexes,
                    "pinnedOffline": b.pinned_offline
                })
            })
            .collect();
        Ok(ToolOutput::json(json!({
            "count": items.len(),
            "boards": items
        })))
    }

    fn handle_get_board_context(&self, args: &Value) -> CoreResult<ToolOutput> {
        let Some(doc) = self.resolve_board(args)? else {
            return Ok(ToolOutput::error(
                "Moodboard not found. Pass a valid `board_id` UUID/prefix or matching `title`.",
            ));
        };
        let nodes: Vec<Value> = doc
            .nodes
            .iter()
            .map(|n| match &n.kind {
                BoardNodeKind::AssetRef {
                    asset_id, weight, ..
                } => json!({
                    "nodeID": format_swift_uuid(&n.id),
                    "kind": "assetRef",
                    "assetID": format_swift_uuid(asset_id),
                    "weight": weight,
                    "frame": n.frame,
                    "locked": n.is_locked
                }),
                BoardNodeKind::Note {
                    title, text, style, ..
                } => json!({
                    "nodeID": format_swift_uuid(&n.id),
                    "kind": "note",
                    "title": title,
                    "text": text,
                    "style": style,
                    "frame": n.frame
                }),
                BoardNodeKind::GroupFrame { title, tint } => json!({
                    "nodeID": format_swift_uuid(&n.id),
                    "kind": "groupFrame",
                    "title": title,
                    "tint": serde_json::to_value(tint).unwrap_or(json!("neutral")),
                    "frame": n.frame
                }),
                BoardNodeKind::PaletteStrip { colors, .. } => json!({
                    "nodeID": format_swift_uuid(&n.id),
                    "kind": "paletteStrip",
                    "colors": colors.iter().map(|c| c.hex.to_uppercase()).collect::<Vec<_>>()
                }),
            })
            .collect();
        Ok(ToolOutput::json(json!({
            "id": format_swift_uuid(&doc.id),
            "boardID": format_swift_uuid(&doc.id),
            "title": doc.title,
            "subtitle": doc.subtitle,
            "mode": if doc.mode.is_auto_editorial() { "autoEditorial" } else { "freeform" },
            "paletteHexes": doc.extracted_palette.iter().map(|c| c.hex.to_uppercase()).collect::<Vec<_>>(),
            "nodes": nodes,
            "connectorCount": doc.connectors.len(),
            "inkStrokeCount": doc.ink_strokes.len()
        })))
    }

    fn handle_export_board_image(
        &self,
        args: &Value,
        policy: &ExternalAgentConfig,
        channel: ExternalAgentChannel,
    ) -> CoreResult<ToolOutput> {
        let validated_out = if let Some(out_path) = args
            .get("output_path")
            .and_then(Value::as_str)
            .map(str::trim)
            .filter(|s| !s.is_empty())
        {
            match self.validate_export_output_path(
                out_path,
                &["png", "jpg", "jpeg"],
                policy,
                channel,
            ) {
                Ok(p) => Some(p),
                Err(msg) => return Ok(ToolOutput::error(msg)),
            }
        } else {
            None
        };

        let Some(doc) = self.resolve_board(args)? else {
            return Ok(ToolOutput::error(
                "Moodboard not found. Pass a valid `board_id` UUID/prefix or matching `title`.",
            ));
        };
        let format_str = args
            .get("format")
            .and_then(Value::as_str)
            .unwrap_or("png")
            .to_ascii_lowercase();
        let format = if format_str == "jpg" || format_str == "jpeg" {
            BoardImageFormat::Jpeg
        } else {
            BoardImageFormat::Png
        };
        let scale = args
            .get("scale")
            .and_then(Value::as_f64)
            .unwrap_or(1.0)
            .clamp(1.0, 2.0);
        let container_width = args
            .get("width")
            .and_then(Value::as_f64)
            .unwrap_or(1440.0)
            .clamp(840.0, 2800.0);
        let opts = MoodboardExportOptions {
            scale,
            format,
            include_annotations: bool_arg(args.get("include_annotations")).unwrap_or(true),
            include_palette_strip: bool_arg(args.get("include_palette_strip")).unwrap_or(true),
            dark_appearance: bool_arg(args.get("dark_appearance")).unwrap_or(false),
            container_width,
        };
        let bytes = self.engine.export_board_image_bytes(&doc, &opts)?;
        let saved_str = if let Some(ref p) = validated_out {
            if let Some(parent) = p.parent() {
                if !parent.as_os_str().is_empty() {
                    std::fs::create_dir_all(parent)?;
                }
            }
            std::fs::write(p, &bytes)?;
            p.display().to_string()
        } else {
            String::new()
        };
        let mime = match format {
            BoardImageFormat::Png => "image/png",
            BoardImageFormat::Jpeg => "image/jpeg",
        };
        let meta = serde_json::to_string(&json!({
            "boardID": format_swift_uuid(&doc.id),
            "title": doc.title,
            "bytes": bytes.len(),
            "format": format_str,
            "outputPath": saved_str
        }))
        .unwrap_or_default();
        let include_image = bool_arg(args.get("include_image")).unwrap_or(true);
        let mut content = Vec::new();
        if include_image {
            content.push(ToolContent::Image {
                mime_type: mime.to_string(),
                data: bytes,
            });
        }
        content.push(ToolContent::Text(meta));
        Ok(ToolOutput {
            content,
            is_error: false,
        })
    }

    // =========================================================================
    // 8 Safe Write Tools (NO permanent deletion allowed!)
    // =========================================================================

    fn handle_organize_assets(&self, args: &Value) -> CoreResult<ToolOutput> {
        let ids = self.resolve_asset_uuid_list(args.get("asset_ids"))?;
        if ids.is_empty() {
            return Ok(ToolOutput::error(
                "`asset_ids` must be a non-empty array of asset UUIDs or 8+ char prefixes.",
            ));
        }
        let folders = self.engine.fetch_folders()?;
        let folder_paths = build_folder_paths(&folders);
        let folder_assignment = if bool_arg(args.get("move_to_inbox")).unwrap_or(false) {
            FolderAssignment::Inbox
        } else {
            self.resolve_optional_folder_id(args, &folders, &folder_paths)?
                .map(FolderAssignment::Folder)
                .unwrap_or(FolderAssignment::Unchanged)
        };
        let patch = AssetBatchPatch {
            asset_ids: ids.clone(),
            title: args
                .get("title")
                .and_then(Value::as_str)
                .map(ToOwned::to_owned),
            notes: args
                .get("notes")
                .and_then(Value::as_str)
                .map(ToOwned::to_owned),
            ai_description: args
                .get("ai_description")
                .and_then(Value::as_str)
                .map(ToOwned::to_owned),
            source_url: None,
            folder_assignment,
            add_tags: string_array_arg(args.get("add_tags")),
            remove_tags: string_array_arg(args.get("remove_tags")),
            accept_suggested_tags: bool_arg(args.get("accept_suggested_tags")).unwrap_or(false),
            dismiss_suggested_tags: string_array_arg(args.get("dismiss_suggested_tags")),
            rating: args
                .get("rating")
                .and_then(Value::as_i64)
                .map(|r| r.clamp(0, 5) as i32),
            is_trashed: None,
            pinned_offline: bool_arg(args.get("pinned_offline")),
        };
        let updated = self.engine.update_assets(&patch)?;
        let updated_set: HashSet<Uuid> = updated.iter().map(|a| a.id).collect();
        let skipped_ids: Vec<String> = ids
            .iter()
            .filter(|id| !updated_set.contains(id))
            .map(format_swift_uuid)
            .collect();
        self.notify_write("assets");
        Ok(ToolOutput::json(json!({
            "updatedCount": updated.len(),
            "assetIDs": updated.iter().map(|a| format_swift_uuid(&a.id)).collect::<Vec<_>>(),
            "skippedIDs": skipped_ids
        })))
    }

    fn handle_create_folder(&self, args: &Value) -> CoreResult<ToolOutput> {
        let name = args
            .get("name")
            .and_then(Value::as_str)
            .map(str::trim)
            .unwrap_or("");
        if name.is_empty() {
            return Ok(ToolOutput::error("Missing required folder `name`."));
        }
        let folders = self.engine.fetch_folders()?;
        let folder_paths = build_folder_paths(&folders);
        let parent_id = self.resolve_parent_folder_id(args, &folders, &folder_paths)?;
        let mut folder = self.engine.create_folder(name, parent_id)?;
        let color_hex = args
            .get("color_hex")
            .and_then(Value::as_str)
            .map(ToOwned::to_owned);
        let custom_symbol = args
            .get("custom_symbol")
            .and_then(Value::as_str)
            .map(ToOwned::to_owned);
        if color_hex.is_some() || custom_symbol.is_some() {
            folder = self
                .engine
                .update_folder_appearance(folder.id, color_hex, custom_symbol)?;
        }
        self.notify_write("folders");
        Ok(ToolOutput::json(json!({
            "folderID": format_swift_uuid(&folder.id),
            "name": folder.name,
            "parentID": folder.parent_id.map(|id| format_swift_uuid(&id)),
            "colorHex": folder.color_hex,
            "customSymbol": folder.custom_symbol
        })))
    }

    fn handle_update_folder(&self, args: &Value) -> CoreResult<ToolOutput> {
        let folders = self.engine.fetch_folders()?;
        let folder_paths = build_folder_paths(&folders);
        let Some(target_id) = self.resolve_optional_folder_id(args, &folders, &folder_paths)?
        else {
            return Ok(ToolOutput::error(
                "Missing required `folder_id` or `folder_path` to update.",
            ));
        };
        let mut folder = folders
            .iter()
            .find(|f| f.id == target_id)
            .cloned()
            .ok_or_else(|| CoreError::NotFound(format_swift_uuid(&target_id)))?;

        if let Some(new_name) = args
            .get("new_name")
            .and_then(Value::as_str)
            .map(str::trim)
            .filter(|s| !s.is_empty())
        {
            folder = self.engine.rename_folder(target_id, new_name)?;
        }

        let move_to_root = bool_arg(args.get("move_to_root")).unwrap_or(false);
        if move_to_root {
            let updated = self.engine.move_folder(target_id, None, None)?;
            if let Some(f) = updated.into_iter().find(|f| f.id == target_id) {
                folder = f;
            }
        } else if args.get("parent_id").is_some() || args.get("parent_path").is_some() {
            let new_parent = self.resolve_parent_folder_id(args, &folders, &folder_paths)?;
            if new_parent.is_some() {
                let updated = self.engine.move_folder(target_id, new_parent, None)?;
                if let Some(f) = updated.into_iter().find(|f| f.id == target_id) {
                    folder = f;
                }
            }
        }

        if args.get("color_hex").is_some() || args.get("custom_symbol").is_some() {
            let color = if let Some(v) = args.get("color_hex").and_then(Value::as_str) {
                if v.trim().is_empty() {
                    None
                } else {
                    Some(v.trim().to_string())
                }
            } else {
                folder.color_hex.clone()
            };
            let sym = if let Some(v) = args.get("custom_symbol").and_then(Value::as_str) {
                if v.trim().is_empty() {
                    None
                } else {
                    Some(v.trim().to_string())
                }
            } else {
                folder.custom_symbol.clone()
            };
            folder = self
                .engine
                .update_folder_appearance(target_id, color, sym)?;
        }

        self.notify_write("folders");
        let refreshed = self.engine.fetch_folders()?;
        let refreshed_paths = build_folder_paths(&refreshed);
        Ok(ToolOutput::json(json!({
            "folderID": format_swift_uuid(&folder.id),
            "name": folder.name,
            "path": refreshed_paths.get(&folder.id).cloned().unwrap_or_else(|| folder.name.clone()),
            "parentID": folder.parent_id.map(|id| format_swift_uuid(&id)),
            "colorHex": folder.color_hex,
            "customSymbol": folder.custom_symbol
        })))
    }

    async fn handle_ingest_asset(&self, args: &Value) -> CoreResult<ToolOutput> {
        let folders = self.engine.fetch_folders()?;
        let folder_paths = build_folder_paths(&folders);
        let folder_id = self.resolve_optional_folder_id(args, &folders, &folder_paths)?;
        let target_board_id = if let Some(raw_bid) = args
            .get("target_board_id")
            .and_then(Value::as_str)
            .map(str::trim)
            .filter(|s| !s.is_empty())
        {
            Some(self.resolve_board_uuid(raw_bid)?)
        } else {
            None
        };

        let mut inputs = Vec::new();
        for fp in string_array_arg(args.get("file_paths")) {
            let safe_path = match self.validate_agent_ingest_file_path(&fp) {
                Ok(p) => p,
                Err(msg) => return Ok(ToolOutput::error(msg)),
            };
            inputs.push(CaptureInput::FilePath(safe_path));
        }
        if let Some(fp) = args
            .get("file_path")
            .and_then(Value::as_str)
            .map(str::trim)
            .filter(|s| !s.is_empty())
        {
            let safe_path = match self.validate_agent_ingest_file_path(fp) {
                Ok(p) => p,
                Err(msg) => return Ok(ToolOutput::error(msg)),
            };
            inputs.push(CaptureInput::FilePath(safe_path));
        }
        for url in string_array_arg(args.get("web_urls")) {
            let Ok(parsed) = Url::parse(url.trim()) else {
                return Ok(ToolOutput::error(format!("Invalid web URL: {url}")));
            };
            if !crate::net_safety::is_safe_public_url(&parsed, false) {
                return Ok(ToolOutput::error(format!(
                    "Rejected unsafe or non-public web URL: {url}"
                )));
            }
            inputs.push(CaptureInput::WebUrl {
                url: parsed.to_string(),
                title: None,
                notes: None,
            });
        }
        if let Some(url) = args
            .get("web_url")
            .or_else(|| args.get("url"))
            .and_then(Value::as_str)
            .map(str::trim)
            .filter(|s| !s.is_empty())
        {
            let Ok(parsed) = Url::parse(url) else {
                return Ok(ToolOutput::error(format!("Invalid web URL: {url}")));
            };
            if !crate::net_safety::is_safe_public_url(&parsed, false) {
                return Ok(ToolOutput::error(format!(
                    "Rejected unsafe or non-public web URL: {url}"
                )));
            }
            inputs.push(CaptureInput::WebUrl {
                url: parsed.to_string(),
                title: args
                    .get("title")
                    .and_then(Value::as_str)
                    .map(ToOwned::to_owned),
                notes: args
                    .get("notes")
                    .and_then(Value::as_str)
                    .map(ToOwned::to_owned),
            });
        }
        if let Some(hex) = args
            .get("color_hex")
            .and_then(Value::as_str)
            .map(str::trim)
            .filter(|s| !s.is_empty())
        {
            inputs.push(CaptureInput::ColorSwatch {
                hex: hex.to_string(),
                title: args
                    .get("title")
                    .and_then(Value::as_str)
                    .map(ToOwned::to_owned),
            });
        }
        if let Some(text) = args
            .get("text")
            .and_then(Value::as_str)
            .map(str::trim)
            .filter(|s| !s.is_empty())
        {
            inputs.push(CaptureInput::TextSnippet {
                title: args
                    .get("title")
                    .and_then(Value::as_str)
                    .unwrap_or("灵感文本")
                    .to_string(),
                text: text.to_string(),
                source_url: None,
            });
        }

        if inputs.is_empty() {
            return Ok(ToolOutput::error(
                "Provide one of `file_path`, `file_paths`, `web_url`/`web_urls`, `color_hex`, or `text` to ingest.",
            ));
        }

        let mut created = self
            .engine
            .ingest(inputs, folder_id, target_board_id)
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
            created = self.engine.update_assets(&patch)?;
        }

        self.notify_write("assets");
        Ok(ToolOutput::json(json!({
            "ingestedCount": created.len(),
            "assets": created.iter().map(|a| serialize_asset_summary(a, &folder_paths, AssetDetailLevel::Compact)).collect::<Vec<_>>()
        })))
    }

    async fn handle_compose_moodboard(&self, args: &Value) -> CoreResult<ToolOutput> {
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
        let explicit_ids = self.resolve_asset_uuid_list(args.get("asset_ids"))?;
        let hero_set: HashSet<Uuid> = self
            .resolve_asset_uuid_list(args.get("hero_asset_ids"))?
            .into_iter()
            .collect();

        let doc = if !explicit_ids.is_empty() {
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
            let mut palette = Vec::new();
            for (idx, aid) in explicit_ids.iter().enumerate() {
                let Some(asset) = self.engine.fetch_asset(*aid)? else {
                    continue;
                };
                if let Some(c) = asset.dominant_colors.first() {
                    if palette.len() < 6 {
                        palette.push(c.clone());
                    }
                }
                let ratio = asset.aspect_ratio().clamp(0.6, 1.9);
                let weight = if hero_set.contains(aid) || (hero_set.is_empty() && idx < 2) {
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
                        autoplay_loop: asset.media_kind == MediaKind::AnimatedImage,
                    },
                    frame: BoardRect::new(
                        ((idx % 4) as f64) * 260.0 + 40.0,
                        ((idx / 4) as f64) * 240.0 + 40.0,
                        240.0,
                        240.0 / ratio,
                    ),
                    z_index: idx as i32,
                    rotation_degrees: 0.0,
                    flip_horizontal: false,
                    flip_vertical: false,
                    is_locked: false,
                    editorial_order: idx as i32,
                    updated_at: Utc::now(),
                });
            }
            if let Some(note) = args
                .get("curator_note")
                .and_then(Value::as_str)
                .map(str::trim)
                .filter(|s| !s.is_empty())
            {
                let ord = d.nodes.len() as i32;
                d.nodes.push(BoardNode {
                    id: Uuid::new_v4(),
                    kind: BoardNodeKind::Note {
                        title: Some("策展说明".to_string()),
                        text: note.to_string(),
                        style: NoteStyle::Paper,
                        font_size: 13.5,
                    },
                    frame: BoardRect::new(40.0, 40.0, 300.0, 140.0),
                    z_index: ord,
                    rotation_degrees: 0.0,
                    flip_horizontal: false,
                    flip_vertical: false,
                    is_locked: false,
                    editorial_order: ord,
                    updated_at: Utc::now(),
                });
            }
            d.extracted_palette = palette;
            d
        } else {
            let prompt = args
                .get("prompt")
                .and_then(Value::as_str)
                .map(str::trim)
                .filter(|s| !s.is_empty())
                .unwrap_or(title);
            if prompt.is_empty() {
                return Ok(ToolOutput::error(
                    "Provide either `asset_ids` for direct curation or `prompt` for automatic curation.",
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
            let req = MoodboardCurationRequest {
                prompt: prompt.to_string(),
                seed_asset_ids: self.resolve_asset_uuid_list(args.get("seed_asset_ids"))?,
                scope_folder_ids: scope_id.into_iter().collect(),
                required_tags: string_array_arg(args.get("required_tags")),
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
            d
        };

        let saved = self.engine.save_board(&doc)?;
        self.notify_write("boards");
        Ok(ToolOutput::json(json!({
            "boardID": format_swift_uuid(&saved.id),
            "title": saved.title,
            "subtitle": saved.subtitle,
            "itemCount": saved.referenced_asset_ids().len(),
            "paletteHexes": saved.extracted_palette.iter().map(|c| c.hex.to_uppercase()).collect::<Vec<_>>()
        })))
    }

    fn handle_patch_moodboard(&self, args: &Value) -> CoreResult<ToolOutput> {
        let Some(mut doc) = self.resolve_board(args)? else {
            return Ok(ToolOutput::error(
                "Moodboard not found. Pass a valid `board_id` UUID/prefix or matching `title`.",
            ));
        };
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
        let mut skipped_locked_assets: Vec<String> = Vec::new();
        if !remove_asset_set.is_empty() || !remove_node_set.is_empty() {
            doc.nodes.retain(|n| {
                let matches_asset = n
                    .referenced_asset_id()
                    .is_some_and(|id| remove_asset_set.contains(&id));
                let matches_node = remove_node_set.contains(&n.id);
                if matches_asset || matches_node {
                    if n.is_locked {
                        if let Some(aid) = n.referenced_asset_id() {
                            skipped_locked_assets.push(format_swift_uuid(&aid));
                        }
                        return true;
                    }
                    return false;
                }
                true
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
            let tint = match args.get("section_tint").and_then(Value::as_str) {
                Some("sand") => GroupTint::Sand,
                Some("sage") => GroupTint::Sage,
                Some("slate") => GroupTint::Slate,
                Some("terracotta") => GroupTint::Terracotta,
                Some("ocean") => GroupTint::Ocean,
                _ => GroupTint::Neutral,
            };
            doc.nodes.push(BoardNode {
                id: Uuid::new_v4(),
                kind: BoardNodeKind::GroupFrame {
                    title: section_title.to_string(),
                    tint,
                },
                frame: BoardRect::new(40.0, cursor_y, 760.0, 260.0),
                z_index: 0,
                rotation_degrees: 0.0,
                flip_horizontal: false,
                flip_vertical: false,
                is_locked: false,
                editorial_order: next_ord,
                updated_at: Utc::now(),
            });
            cursor_y += 44.0;
            next_ord += 1;
        }

        let add_ids = self.resolve_asset_uuid_list(args.get("add_asset_ids"))?;
        if !add_ids.is_empty() {
            let existing: HashSet<Uuid> = doc.referenced_asset_ids().into_iter().collect();
            let mut added_idx = 0usize;
            for aid in add_ids {
                if existing.contains(&aid) {
                    continue;
                }
                let Some(asset) = self.engine.fetch_asset(aid)? else {
                    continue;
                };
                let ratio = asset.aspect_ratio().clamp(0.6, 1.9);
                let col = (added_idx % 4) as f64;
                let row = (added_idx / 4) as f64;
                doc.nodes.push(BoardNode {
                    id: Uuid::new_v4(),
                    kind: BoardNodeKind::AssetRef {
                        asset_id: aid,
                        crop: None,
                        weight: 1,
                        autoplay_loop: asset.media_kind == MediaKind::AnimatedImage,
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
                added_idx += 1;
                next_z += 1;
                next_ord += 1;
            }
            if added_idx > 0 {
                cursor_y += (((added_idx - 1) / 4) as f64 + 1.0) * 240.0 + 20.0;
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
        self.notify_write("boards");
        Ok(ToolOutput::json(json!({
            "boardID": format_swift_uuid(&saved.id),
            "title": saved.title,
            "itemCount": saved.referenced_asset_ids().len(),
            "skippedLockedAssetIDs": skipped_locked_assets,
            "paletteHexes": saved.extracted_palette.iter().map(|c| c.hex.to_uppercase()).collect::<Vec<_>>()
        })))
    }

    fn handle_trash_assets(&self, args: &Value) -> CoreResult<ToolOutput> {
        let ids = self.resolve_asset_uuid_list(args.get("asset_ids"))?;
        if ids.is_empty() {
            return Ok(ToolOutput::error(
                "`asset_ids` must be a non-empty array of asset UUIDs or 8+ char prefixes.",
            ));
        }
        let trashed = bool_arg(args.get("trashed")).unwrap_or(true);
        let patch = AssetBatchPatch {
            asset_ids: ids,
            is_trashed: Some(trashed),
            ..Default::default()
        };
        let updated = self.engine.update_assets(&patch)?;
        self.notify_write("assets");
        Ok(ToolOutput::json(json!({
            "updatedCount": updated.len(),
            "trashed": trashed,
            "note": "Soft Trash only; external agents can never permanently delete assets."
        })))
    }

    async fn handle_analyze_assets(&self, args: &Value) -> CoreResult<ToolOutput> {
        let ids = self.resolve_asset_uuid_list(args.get("asset_ids"))?;
        if ids.is_empty() {
            return Ok(ToolOutput::error(
                "`asset_ids` must be a non-empty array of asset UUIDs or prefixes (1-20).",
            ));
        }
        let refresh_rich = bool_arg(args.get("refresh_rich_metadata")).unwrap_or(false);
        let mut results = Vec::new();
        for id in ids.into_iter().take(20) {
            let mut hydrated = self.engine.hydrate_image_metadata(id)?;
            if let Ok(Some(ocr_updated)) = self.engine.run_ocr_for_asset(id).await {
                hydrated = Some(ocr_updated);
            }
            if refresh_rich {
                if let Ok(rich_updated) = self.engine.refresh_rich_asset(id).await {
                    hydrated = Some(rich_updated);
                }
            }
            if let Some(asset) = hydrated {
                results.push(json!({
                    "assetID": format_swift_uuid(&asset.id),
                    "title": asset.title,
                    "hasOCR": asset.ocr_text.as_deref().is_some_and(|s| !s.is_empty()),
                    "colorCount": asset.dominant_colors.len(),
                    "hasExif": asset.rich_metadata.as_ref().and_then(|m| m.photo_exif.as_ref()).is_some(),
                    "hasAIGeneration": asset.rich_metadata.as_ref().and_then(|m| m.ai_generation.as_ref()).is_some()
                }));
            }
        }
        self.notify_write("assets");
        Ok(ToolOutput::json(json!({
            "analyzedCount": results.len(),
            "results": results
        })))
    }

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
        // v1.2.2 contract: parent folder queries recurse into nested subfolders by default!
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
    // MCP v2 Resources, Templates, Prompts & Lean <18KB 20-Tool Schema Registry
    // =========================================================================

    pub fn mcp_resource_definitions() -> Vec<Value> {
        vec![
            json!({
                "uri": "charkle://library/overview",
                "name": "Library Overview Atlas",
                "description": "Counts, compact folder semantic profiles (recursive counts, topTags, palettes), smart folders, top tags, aspect/media mix, boards, and permissions.",
                "mimeType": "application/json"
            }),
            json!({
                "uri": "charkle://boards",
                "name": "Moodboards",
                "description": "All moodboards with IDs, titles, layout modes, counts, and palettes.",
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
                "description": "Full metadata for an asset UUID or 8+ char prefix (EXIF, AI prompts, social/GitHub, palette, OCR, local paths).",
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
                "description": "Visually inspect untriaged Inbox assets in 1 Contact Sheet + folder suggestions, then propose or apply clean organization.",
                "arguments": [
                    { "name": "limit", "description": "Inbox items per batch (default 16).", "required": false },
                    { "name": "apply_changes", "description": "'true' to apply via organize_assets; otherwise propose plan first.", "required": false }
                ]
            }),
            json!({
                "name": "curate_moodboard",
                "description": "Token-efficient grounded curation: orient via overview atlas, recall diversified multi-direction Contact Sheet in 1 call, compose structured Moodboard.",
                "arguments": [
                    { "name": "brief", "description": "Creative direction, style, mood, or color brief.", "required": true },
                    { "name": "folder_path", "description": "Optional folder path scope.", "required": false },
                    { "name": "count", "description": "Target references (default 10).", "required": false }
                ]
            }),
            json!({
                "name": "extract_design_tokens",
                "description": "Read a Moodboard's palette, notes, sections, and visual snapshot to generate structured design tokens.",
                "arguments": [
                    { "name": "board", "description": "Moodboard title or UUID.", "required": true },
                    { "name": "format", "description": "'css', 'tailwind', or 'json' (default 'css').", "required": false }
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
                    "Apply via `organize_assets` (8-char short IDs supported; reuse existing folders/tags; never permanently delete)."
                } else {
                    "Present a concise table of recommended folder, tags, and notes for user approval first."
                };
                Some(json!({
                    "description": "Triage untriaged Inbox assets in Charkle",
                    "messages": [{
                        "role": "user",
                        "content": {
                            "type": "text",
                            "text": format!(
                                "Triage up to {limit} Inbox assets in Charkle (low-token workflow):\n1. Call `library_overview` to inspect folder semantic profiles (`topTags`, `palette`) and canonical tags.\n2. Call `list_inbox` with `limit: {limit}, render_contact_sheet: true` (auto `visual` manifest) to see all thumbnails + short IDs in 1 call.\n3. Call `suggest_folder` on those `asset_ids` for grounded folder recommendations.\n4. Reuse existing folder paths and tag vocabulary rather than inventing duplicates.\n5. {action}"
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
                                "Curate a Charkle Moodboard for: \"{brief}\" (target ~{count} assets, minimal token budget):\n1. Call `library_overview` to read folder semantic profiles (`topTags`, `palette`, `recursiveAssetCount`).\n2. {scope} Run `semantic_search` (supports multi-direction `queries:[...]`, bilingual EN/ZH terms, CIELAB `tone`, `diversify:true`, `render_contact_sheet:true`) or `search_assets` to inspect distinct candidates in ONE Contact Sheet.\n3. If refining, pass `seed_asset_ids`, `unlike_asset_ids`, or `exclude_asset_ids` using 8-char short IDs.\n4. Batch-call `get_asset(asset_ids:[...])` only on finalists, then call `compose_moodboard` with `hero_asset_ids` and a concise `curator_note`."
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
                let board_hint = if board.is_empty() {
                    "Call `list_boards` to locate the target moodboard.".to_string()
                } else {
                    format!("Target moodboard: `{board}`.")
                };
                Some(json!({
                    "description": "Extract design tokens from a Charkle Moodboard",
                    "messages": [{
                        "role": "user",
                        "content": {
                            "type": "text",
                            "text": format!(
                                "Extract production-ready `{format_name}` design tokens from my Charkle Moodboard:\n1. {board_hint}\n2. Call `get_board_context` to read the harmonized HEX/CIELAB palette, notes, sections, and connectors.\n3. Call `export_board_image` (use `width: 1200`) to inspect visual mood, contrast, and hierarchy.\n4. Output semantic tokens (surface, ink, accent, muted, borders) in `{format_name}`."
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
                    format!("Call `search_assets` with `media_kinds: [\"image\"], limit: {limit}`.")
                } else {
                    format!("Call `search_assets` with `query: \"{query}\", media_kinds: [\"image\"], limit: {limit}`.")
                };
                Some(json!({
                    "description": "Inspect embedded AI generation prompts and parameters",
                    "messages": [{
                        "role": "user",
                        "content": {
                            "type": "text",
                            "text": format!(
                                "Inspect AI-generated references in Charkle:\n1. {search_step}\n2. Batch-call `get_asset` with `asset_ids: [...]` (up to 12 at once) to read `richMetadata.aiGeneration`.\n3. Summarize recurring prompt patterns, model/LoRA recipes, and parameter differences."
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
            json!({ "type": "string", "enum": ["landscape", "portrait", "square", "ultrawide"] });

        vec![
            // 12 Read Tools
            tool_def(
                "library_overview",
                "Library Overview",
                "Semantic atlas: counts, compact folders (8-char id, path, recursiveAssetCount, topTags, palette), smartFolders, topTags, aspect/media mix, boards, policy. Call first.",
                json!({
                    "type": "object",
                    "properties": {
                        "compact": { "type": "boolean" },
                        "include_folder_profiles": { "type": "boolean" },
                        "include_boards": { "type": "boolean" },
                        "top_tags_limit": { "type": "integer", "minimum": 5, "maximum": 80 }
                    }
                }),
                true,
                true,
                false,
            ),
            tool_def(
                "search_assets",
                "Search Assets",
                "Filter & paginate assets (FTS/Pinyin, folder incl. subfolders, tags=AND, any_tags=OR, exclude_tags/ids, color, tone=dark|light|warm|cool|vivid|muted|high_contrast, kind, shape, rating, smart folder). Supports diversify, auto facets, detail=visual|compact|standard|full, and one-shot render_contact_sheet.",
                json!({
                    "type": "object",
                    "properties": {
                        "query": { "type": "string" },
                        "folder_id": { "type": "string" },
                        "folder_path": { "type": "string" },
                        "include_subfolders": { "type": "boolean" },
                        "smart_folder_id": { "type": "string" },
                        "smart_folder_name": { "type": "string" },
                        "tags": str_arr,
                        "any_tags": str_arr,
                        "exclude_tags": str_arr,
                        "exclude_asset_ids": str_arr,
                        "media_kinds": str_arr,
                        "aspect_shape": shape_enum,
                        "color_hex": { "type": "string" },
                        "color_tolerance": { "type": "number" },
                        "tone": { "type": "string" },
                        "min_rating": { "type": "integer", "minimum": 0, "maximum": 5 },
                        "only_inbox": { "type": "boolean" },
                        "only_untagged": { "type": "boolean" },
                        "only_recent_days": { "type": "integer", "minimum": 1 },
                        "only_pinned_offline": { "type": "boolean" },
                        "only_trashed": { "type": "boolean" },
                        "include_trashed": { "type": "boolean" },
                        "sort_by": sort_enum,
                        "detail": detail_enum,
                        "diversify": { "type": "boolean" },
                        "include_facets": { "type": "boolean" },
                        "render_contact_sheet": { "type": "boolean" },
                        "sheet_max_width": { "type": "integer", "minimum": 512, "maximum": 1920 },
                        "output_path": { "type": "string" },
                        "offset": { "type": "integer", "minimum": 0 },
                        "limit": { "type": "integer", "minimum": 1, "maximum": 100 }
                    }
                }),
                true,
                true,
                false,
            ),
            tool_def(
                "list_inbox",
                "List Inbox",
                "List untriaged Inbox assets (default limit=20). Pass render_contact_sheet=true for inline numbered thumbnails.",
                json!({
                    "type": "object",
                    "properties": {
                        "media_kinds": str_arr,
                        "sort_by": sort_enum,
                        "detail": detail_enum,
                        "render_contact_sheet": { "type": "boolean" },
                        "sheet_max_width": { "type": "integer", "minimum": 512, "maximum": 1920 },
                        "output_path": { "type": "string" },
                        "offset": { "type": "integer", "minimum": 0 },
                        "limit": { "type": "integer", "minimum": 1, "maximum": 100 }
                    }
                }),
                true,
                true,
                false,
            ),
            tool_def(
                "get_asset",
                "Get Asset Details",
                "Full metadata (EXIF, AI prompts, social/GitHub, OCR, local paths) for 1 UUID/8-char prefix (`asset_id`) or 1–12 finalists (`asset_ids`). include_image=true attaches preview JPEG (or zoomed sheet for batch).",
                json!({
                    "type": "object",
                    "properties": {
                        "asset_id": { "type": "string" },
                        "asset_ids": str_arr,
                        "include_image": { "type": "boolean" },
                        "image_max_side": { "type": "integer", "minimum": 280, "maximum": 1568 }
                    }
                }),
                true,
                true,
                false,
            ),
            tool_def(
                "render_contact_sheet",
                "Render Visual Contact Sheet",
                "Render 1–24 assets (default 16, max_width 512..1920, auto visual manifest) into a numbered Contact Sheet JPEG (#01..#24). Accepts asset_ids, multi-intent queries[], or filters + tone + diversify.",
                json!({
                    "type": "object",
                    "properties": {
                        "asset_ids": str_arr,
                        "query": { "type": "string" },
                        "queries": str_arr,
                        "folder_id": { "type": "string" },
                        "folder_path": { "type": "string" },
                        "include_subfolders": { "type": "boolean" },
                        "smart_folder_id": { "type": "string" },
                        "smart_folder_name": { "type": "string" },
                        "tags": str_arr,
                        "any_tags": str_arr,
                        "exclude_tags": str_arr,
                        "exclude_asset_ids": str_arr,
                        "media_kinds": str_arr,
                        "aspect_shape": shape_enum,
                        "min_rating": { "type": "integer", "minimum": 0, "maximum": 5 },
                        "only_inbox": { "type": "boolean" },
                        "only_untagged": { "type": "boolean" },
                        "only_trashed": { "type": "boolean" },
                        "color_hex": { "type": "string" },
                        "color_tolerance": { "type": "number" },
                        "tone": { "type": "string" },
                        "sort_by": sort_enum,
                        "detail": { "type": "string", "enum": ["visual", "compact"] },
                        "diversify": { "type": "boolean" },
                        "columns": { "type": "integer", "minimum": 1, "maximum": 6 },
                        "offset": { "type": "integer", "minimum": 0 },
                        "limit": { "type": "integer", "minimum": 1, "maximum": 24 },
                        "max_width": { "type": "integer", "minimum": 512, "maximum": 1920 },
                        "include_image": { "type": "boolean" },
                        "output_path": { "type": "string" }
                    }
                }),
                true,
                true,
                false,
            ),
            tool_def(
                "find_similar_assets",
                "Find Visually Similar Assets",
                "Find visually similar assets (local visual descriptors + CIELAB palette + tags, default limit=12). Supports unlike_asset_ids repulsion, diversify, and inline render_contact_sheet.",
                json!({
                    "type": "object",
                    "properties": {
                        "asset_id": { "type": "string" },
                        "limit": { "type": "integer", "minimum": 1, "maximum": 32 },
                        "exclude_asset_ids": str_arr,
                        "unlike_asset_ids": str_arr,
                        "detail": detail_enum,
                        "diversify": { "type": "boolean" },
                        "render_contact_sheet": { "type": "boolean" },
                        "sheet_max_width": { "type": "integer", "minimum": 512, "maximum": 1920 },
                        "output_path": { "type": "string" }
                    },
                    "required": ["asset_id"]
                }),
                true,
                true,
                false,
            ),
            tool_def(
                "semantic_search",
                "Semantic Search",
                "Bilingual EN↔ZH + CIELAB tone/aspect + folder/tag + visual seed/unlike hybrid search. Pass `query` or multi-direction `queries[]` (2–6 intents in 1 Contact Sheet), `seed_asset_ids`, `unlike_asset_ids`, `tone`, `diversify`, `render_contact_sheet`.",
                json!({
                    "type": "object",
                    "properties": {
                        "query": { "type": "string" },
                        "queries": str_arr,
                        "seed_asset_ids": str_arr,
                        "unlike_asset_ids": str_arr,
                        "folder_id": { "type": "string" },
                        "folder_path": { "type": "string" },
                        "include_subfolders": { "type": "boolean" },
                        "tags": str_arr,
                        "any_tags": str_arr,
                        "exclude_tags": str_arr,
                        "exclude_asset_ids": str_arr,
                        "media_kinds": str_arr,
                        "aspect_shape": shape_enum,
                        "color_hex": { "type": "string" },
                        "tone": { "type": "string" },
                        "min_rating": { "type": "integer", "minimum": 0, "maximum": 5 },
                        "visual_rerank": { "type": "boolean" },
                        "diversify": { "type": "boolean" },
                        "include_facets": { "type": "boolean" },
                        "detail": detail_enum,
                        "render_contact_sheet": { "type": "boolean" },
                        "sheet_max_width": { "type": "integer", "minimum": 512, "maximum": 1920 },
                        "output_path": { "type": "string" },
                        "limit": { "type": "integer", "minimum": 1, "maximum": 50 }
                    }
                }),
                true,
                true,
                true,
            ),
            tool_def(
                "quick_jump",
                "Quick Jump",
                "Fast fuzzy lookup across folders, moodboards, tags, and assets (Chinese & Pinyin, default limit=20).",
                json!({
                    "type": "object",
                    "properties": {
                        "query": { "type": "string" },
                        "limit": { "type": "integer", "minimum": 1, "maximum": 50 }
                    },
                    "required": ["query"]
                }),
                true,
                true,
                false,
            ),
            tool_def(
                "suggest_folder",
                "Suggest Folder for Assets",
                "Recommend best existing folder for 1–20 assets via visual similarity and tag/palette affinity.",
                json!({
                    "type": "object",
                    "properties": {
                        "asset_id": { "type": "string" },
                        "asset_ids": str_arr
                    }
                }),
                true,
                true,
                false,
            ),
            tool_def(
                "list_boards",
                "List Moodboards",
                "List all Moodboards (ID, title, subtitle, item count, palette).",
                json!({ "type": "object", "properties": {} }),
                true,
                true,
                false,
            ),
            tool_def(
                "get_board_context",
                "Get Moodboard Context",
                "Read Moodboard context: notes, sections, frames, connectors, palette, assets (by board_id/prefix or title).",
                json!({
                    "type": "object",
                    "properties": {
                        "board_id": { "type": "string" },
                        "title": { "type": "string" },
                        "detail": detail_enum
                    }
                }),
                true,
                true,
                false,
            ),
            tool_def(
                "export_board_image",
                "Export Moodboard Image",
                "Render Moodboard to PNG/JPEG (default width=1440, include_image=true, optional output_path).",
                json!({
                    "type": "object",
                    "properties": {
                        "board_id": { "type": "string" },
                        "title": { "type": "string" },
                        "format": { "type": "string", "enum": ["png", "jpg"] },
                        "width": { "type": "integer", "minimum": 840, "maximum": 2800 },
                        "scale": { "type": "number" },
                        "dark_appearance": { "type": "boolean" },
                        "include_image": { "type": "boolean" },
                        "output_path": { "type": "string" }
                    }
                }),
                true,
                true,
                false,
            ),
            // 8 Safe Write Tools (Zero Permanent Delete)
            tool_def(
                "organize_assets",
                "Organize Assets",
                "Batch-update assets (8-char IDs ok): folder/Inbox, add/remove/suggested tags, rating, title, notes, ai_description, offline pin. Requires write permission.",
                json!({
                    "type": "object",
                    "properties": {
                        "asset_ids": str_arr,
                        "folder_id": { "type": "string" },
                        "folder_path": { "type": "string" },
                        "move_to_inbox": { "type": "boolean" },
                        "add_tags": str_arr,
                        "remove_tags": str_arr,
                        "accept_suggested_tags": { "type": "boolean" },
                        "dismiss_suggested_tags": str_arr,
                        "title": { "type": "string" },
                        "notes": { "type": "string" },
                        "ai_description": { "type": "string" },
                        "rating": { "type": "integer", "minimum": 0, "maximum": 5 },
                        "pinned_offline": { "type": "boolean" }
                    },
                    "required": ["asset_ids"]
                }),
                false,
                true,
                false,
            ),
            tool_def(
                "create_folder",
                "Create Folder",
                "Create a folder (optional parent, color, symbol). Requires write permission.",
                json!({
                    "type": "object",
                    "properties": {
                        "name": { "type": "string" },
                        "parent_id": { "type": "string" },
                        "parent_path": { "type": "string" },
                        "color_hex": { "type": "string" },
                        "custom_symbol": { "type": "string" }
                    },
                    "required": ["name"]
                }),
                false,
                false,
                false,
            ),
            tool_def(
                "update_folder",
                "Update Folder",
                "Rename, move, or style a folder (deleting folders is disabled). Requires write permission.",
                json!({
                    "type": "object",
                    "properties": {
                        "folder_id": { "type": "string" },
                        "folder_path": { "type": "string" },
                        "new_name": { "type": "string" },
                        "parent_id": { "type": "string" },
                        "parent_path": { "type": "string" },
                        "move_to_root": { "type": "boolean" },
                        "color_hex": { "type": "string" },
                        "custom_symbol": { "type": "string" }
                    }
                }),
                false,
                true,
                false,
            ),
            tool_def(
                "ingest_asset",
                "Ingest Asset",
                "Import local files/dirs, web/social/GitHub URLs, color swatch, or text snippet with optional folder, board, tags, notes, rating. Requires write permission.",
                json!({
                    "type": "object",
                    "properties": {
                        "file_path": { "type": "string" },
                        "file_paths": str_arr,
                        "web_url": { "type": "string" },
                        "web_urls": str_arr,
                        "color_hex": { "type": "string" },
                        "text": { "type": "string" },
                        "title": { "type": "string" },
                        "notes": { "type": "string" },
                        "rating": { "type": "integer", "minimum": 0, "maximum": 5 },
                        "tags": str_arr,
                        "folder_id": { "type": "string" },
                        "folder_path": { "type": "string" },
                        "target_board_id": { "type": "string" }
                    }
                }),
                false,
                false,
                true,
            ),
            tool_def(
                "compose_moodboard",
                "Compose Moodboard",
                "Create a Moodboard via explicit `asset_ids` (8-char IDs ok) or `prompt` curation. Requires write permission.",
                json!({
                    "type": "object",
                    "properties": {
                        "title": { "type": "string" },
                        "subtitle": { "type": "string" },
                        "prompt": { "type": "string" },
                        "asset_ids": str_arr,
                        "hero_asset_ids": str_arr,
                        "seed_asset_ids": str_arr,
                        "required_tags": str_arr,
                        "folder_id": { "type": "string" },
                        "folder_path": { "type": "string" },
                        "layout_style": { "type": "string", "enum": ["magazine", "balanced", "compact"] },
                        "use_freeform": { "type": "boolean" },
                        "curator_note": { "type": "string" },
                        "preferred_count": { "type": "integer", "minimum": 2, "maximum": 24 }
                    }
                }),
                false,
                false,
                false,
            ),
            tool_def(
                "patch_moodboard",
                "Patch Moodboard",
                "Non-destructively update a Moodboard: rename, layout, append cards/sections/notes without overlap, remove unlocked nodes. Requires write permission.",
                json!({
                    "type": "object",
                    "properties": {
                        "board_id": { "type": "string" },
                        "title": { "type": "string" },
                        "new_title": { "type": "string" },
                        "subtitle": { "type": "string" },
                        "use_freeform": { "type": "boolean" },
                        "layout_style": { "type": "string", "enum": ["magazine", "balanced", "compact"] },
                        "add_asset_ids": str_arr,
                        "remove_asset_ids": str_arr,
                        "remove_node_ids": str_arr,
                        "add_section": { "type": "string" },
                        "section_tint": { "type": "string" },
                        "add_note": { "type": "string" },
                        "note_title": { "type": "string" },
                        "note_style": { "type": "string" }
                    }
                }),
                false,
                false,
                false,
            ),
            tool_def(
                "trash_assets",
                "Move Assets to/from Trash",
                "Soft-move assets to Trash or restore (8-char IDs ok). Permanent deletion is strictly forbidden. Requires write permission.",
                json!({
                    "type": "object",
                    "properties": {
                        "asset_ids": str_arr,
                        "trashed": { "type": "boolean" }
                    },
                    "required": ["asset_ids"]
                }),
                false,
                true,
                false,
            ),
            tool_def(
                "analyze_assets",
                "Analyze & Hydrate Assets",
                "Run local EXIF/AI prompt hydration and offline OCR on 1–20 assets; optional live rich metadata refresh. Requires write permission.",
                json!({
                    "type": "object",
                    "properties": {
                        "asset_ids": str_arr,
                        "refresh_rich_metadata": { "type": "boolean" }
                    },
                    "required": ["asset_ids"]
                }),
                false,
                true,
                true,
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
    use crate::models::agent::ExternalAgentAccessLevel;
    use std::sync::atomic::{AtomicUsize, Ordering};
    use tempfile::tempdir;

    #[tokio::test]
    async fn enforces_mcp_v2_20_tools_resources_prompts_batch_and_soft_trash_only_invariant() {
        let dir = tempdir().unwrap();
        let engine = Arc::new(LiveCharkleEngine::open(dir.path()).unwrap());
        let wake_hits = Arc::new(AtomicUsize::new(0));
        let hits_clone = Arc::clone(&wake_hits);
        let svc = CharkleExternalAgentService::new(
            Arc::clone(&engine),
            dir.path().to_path_buf(),
            Some(Arc::new(move |_| {
                hits_clone.fetch_add(1, Ordering::SeqCst);
            })),
        );

        let init_resp: Value = serde_json::from_str(
            &svc.handle_jsonrpc(
                r#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25"}}"#,
            )
            .await
            .unwrap(),
        )
        .unwrap();
        assert_eq!(init_resp["result"]["serverInfo"]["name"], "charkle");
        assert_eq!(init_resp["result"]["protocolVersion"], "2025-11-25");
        assert!(init_resp["result"]["capabilities"]["prompts"].is_object());

        let batch_resp: Value = serde_json::from_str(
            &svc.handle_jsonrpc(
                r#"[
                    {"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}},
                    {"jsonrpc":"2.0","id":3,"method":"resources/list","params":{}},
                    {"jsonrpc":"2.0","id":4,"method":"resources/templates/list","params":{}},
                    {"jsonrpc":"2.0","id":5,"method":"prompts/list","params":{}},
                    {"jsonrpc":"2.0","id":6,"method":"logging/setLevel","params":{"level":"info"}},
                    {"jsonrpc":"2.0","method":"notifications/initialized","params":{}}
                ]"#,
            )
            .await
            .unwrap(),
        )
        .unwrap();
        let batch = batch_resp.as_array().unwrap();
        assert_eq!(batch.len(), 5);
        assert_eq!(batch[0]["result"]["tools"].as_array().unwrap().len(), 20);
        // Lean schema budget assertion (< 18,000 bytes, v1.2.2 contract)
        let tools_bytes = serde_json::to_string(&batch[0]["result"]).unwrap().len();
        assert!(
            tools_bytes < 18_000,
            "tools/list payload exceeded 18 KB budget: {tools_bytes} bytes"
        );
        for tool in batch[0]["result"]["tools"].as_array().unwrap() {
            assert_eq!(tool["annotations"]["destructiveHint"], false);
        }
        assert_eq!(batch[1]["result"]["resources"].as_array().unwrap().len(), 4);
        assert_eq!(
            batch[2]["result"]["resourceTemplates"]
                .as_array()
                .unwrap()
                .len(),
            2
        );
        assert_eq!(batch[3]["result"]["prompts"].as_array().unwrap().len(), 4);

        let prompt_resp: Value = serde_json::from_str(
            &svc.handle_jsonrpc(
                r#"{"jsonrpc":"2.0","id":7,"method":"prompts/get","params":{"name":"triage_inbox","arguments":{"limit":"8"}}}"#,
            )
            .await
            .unwrap(),
        )
        .unwrap();
        assert!(prompt_resp["result"]["messages"][0]["content"]["text"]
            .as_str()
            .unwrap()
            .contains("suggest_folder"));

        // Write is blocked under readOnly
        let blocked_write = svc
            .call_tool(
                "create_folder",
                &json!({ "name": "Blocked" }),
                ExternalAgentChannel::Mcp,
            )
            .await;
        assert!(blocked_write.is_error);

        // Disk export is also blocked under readOnly
        let blocked_export = svc
            .call_tool(
                "render_contact_sheet",
                &json!({ "output_path": dir.path().join("../out.jpg").display().to_string() }),
                ExternalAgentChannel::Mcp,
            )
            .await;
        assert!(blocked_export.is_error);

        // Independent channel switch
        ExternalAgentConfigStore::save(
            dir.path(),
            &ExternalAgentConfig {
                mcp_enabled: false,
                cli_enabled: true,
                access_level: ExternalAgentAccessLevel::ReadWriteOrganize,
            },
        )
        .unwrap();
        let mcp_denied = svc
            .call_tool("library_overview", &json!({}), ExternalAgentChannel::Mcp)
            .await;
        assert!(mcp_denied.is_error);
        let cli_ok = svc
            .call_tool("library_overview", &json!({}), ExternalAgentChannel::Cli)
            .await;
        assert!(!cli_ok.is_error);
        // Compact JSON default: zero pretty-print newlines
        assert!(!cli_ok.first_text().contains('\n'));

        let created_folder = svc
            .call_tool(
                "create_folder",
                &json!({ "name": "建筑参考" }),
                ExternalAgentChannel::Cli,
            )
            .await;
        assert!(!created_folder.is_error);
        let folder_val: Value = serde_json::from_str(&created_folder.first_text()).unwrap();
        let folder_id = folder_val["folderID"].as_str().unwrap().to_string();

        let renamed_folder = svc
            .call_tool(
                "update_folder",
                &json!({ "folder_id": &folder_id[..8], "new_name": "建筑与光影", "color_hex": "#2A60E0" }),
                ExternalAgentChannel::Cli,
            )
            .await;
        assert!(!renamed_folder.is_error);
        assert!(renamed_folder.first_text().contains("建筑与光影"));

        let ingested = svc
            .call_tool(
                "ingest_asset",
                &json!({ "color_hex": "#2A60E0", "title": "Studio Cobalt", "tags": ["cobalt"] }),
                ExternalAgentChannel::Cli,
            )
            .await;
        assert!(!ingested.is_error);
        let ingested_val: Value = serde_json::from_str(&ingested.first_text()).unwrap();
        let asset_id_str = ingested_val["assets"][0]["id"]
            .as_str()
            .unwrap()
            .to_string();

        // 8-char prefix works in get_asset, find_similar_assets, suggest_folder, analyze_assets
        let get_by_prefix = svc
            .call_tool(
                "get_asset",
                &json!({ "asset_id": &asset_id_str[..8] }),
                ExternalAgentChannel::Cli,
            )
            .await;
        assert!(!get_by_prefix.is_error);
        assert!(get_by_prefix.first_text().contains(&asset_id_str));

        let jump = svc
            .call_tool(
                "quick_jump",
                &json!({ "query": "Cobalt" }),
                ExternalAgentChannel::Cli,
            )
            .await;
        assert!(!jump.is_error);
        let similar = svc
            .call_tool(
                "find_similar_assets",
                &json!({ "asset_id": &asset_id_str[..8] }),
                ExternalAgentChannel::Cli,
            )
            .await;
        assert!(!similar.is_error);
        let suggest = svc
            .call_tool(
                "suggest_folder",
                &json!({ "asset_id": &asset_id_str[..8] }),
                ExternalAgentChannel::Cli,
            )
            .await;
        assert!(!suggest.is_error);
        let analyzed = svc
            .call_tool(
                "analyze_assets",
                &json!({ "asset_ids": [&asset_id_str[..8]] }),
                ExternalAgentChannel::Cli,
            )
            .await;
        assert!(!analyzed.is_error);

        let sheet = svc
            .call_tool(
                "render_contact_sheet",
                &json!({ "asset_ids": [&asset_id_str[..8]], "max_width": 512 }),
                ExternalAgentChannel::Cli,
            )
            .await;
        assert!(!sheet.is_error);
        assert!(sheet.content.iter().any(
            |c| matches!(c, ToolContent::Image { mime_type, .. } if mime_type == "image/jpeg")
        ));

        let board = svc
            .call_tool(
                "compose_moodboard",
                &json!({ "title": "Agent Board", "asset_ids": [&asset_id_str[..8]] }),
                ExternalAgentChannel::Cli,
            )
            .await;
        assert!(!board.is_error);

        let patched = svc
            .call_tool(
                "patch_moodboard",
                &json!({ "title": "Agent Board", "add_section": "光影分区", "add_note": "主色调参考", "note_style": "warm" }),
                ExternalAgentChannel::Cli,
            )
            .await;
        assert!(!patched.is_error);

        let trashed = svc
            .call_tool(
                "trash_assets",
                &json!({ "asset_ids": [&asset_id_str[..8]], "trashed": true }),
                ExternalAgentChannel::Cli,
            )
            .await;
        assert!(!trashed.is_error);
        let still_there = engine
            .fetch_asset(Uuid::parse_str(&asset_id_str).unwrap())
            .unwrap()
            .expect("soft trash must never permanently delete");
        assert!(still_there.is_trashed);

        let perm_attempt = svc
            .call_tool(
                "permanently_delete_assets",
                &json!({ "asset_ids": [&asset_id_str] }),
                ExternalAgentChannel::Cli,
            )
            .await;
        assert!(perm_attempt.is_error);
        assert!(wake_hits.load(Ordering::SeqCst) >= 6);
    }

    #[tokio::test]
    async fn verifies_v122_short_id_ambiguity_visual_tone_facets_subfolders_multiquery_and_batch_get(
    ) {
        let dir = tempdir().unwrap();
        let engine = Arc::new(LiveCharkleEngine::open(dir.path()).unwrap());
        ExternalAgentConfigStore::save(
            dir.path(),
            &ExternalAgentConfig {
                mcp_enabled: true,
                cli_enabled: true,
                access_level: ExternalAgentAccessLevel::ReadWriteOrganize,
            },
        )
        .unwrap();
        let svc =
            CharkleExternalAgentService::new(Arc::clone(&engine), dir.path().to_path_buf(), None);

        // Parent + Child folder hierarchy
        let parent_f = engine.create_folder("插画", None).unwrap();
        let child_f = engine
            .create_folder("ClearLine", Some(parent_f.id))
            .unwrap();

        // Seed 4 distinct assets (2 with shared 8-char prefix to test ambiguity!)
        let shared_prefix_a = Uuid::parse_str("AABBCCDD-0000-4000-8000-000000000001").unwrap();
        let shared_prefix_b = Uuid::parse_str("AABBCCDD-0000-4000-8000-000000000002").unwrap();

        let mut a1 = AssetRecord::new("夏日海边少女", "beach.png");
        a1.id = shared_prefix_a;
        a1.folder_id = Some(child_f.id);
        a1.tags = vec!["夏日".into(), "海边".into(), "蓝天".into()];
        a1.dominant_colors = vec![crate::models::core::LabColor::from_hex("#2A6F97", 0.8)];

        let mut a2 = AssetRecord::new("深色夜景赛博", "night.png");
        a2.id = shared_prefix_b;
        a2.folder_id = Some(parent_f.id);
        a2.tags = vec!["夜景".into(), "暗调".into()];
        a2.dominant_colors = vec![crate::models::core::LabColor::from_hex("#10141C", 0.9)];

        let mut a3 = AssetRecord::new("极简白底留白", "minimal.png");
        a3.folder_id = Some(child_f.id);
        a3.tags = vec!["极简".into(), "白底".into()];
        a3.dominant_colors = vec![crate::models::core::LabColor::from_hex("#F8F9FA", 0.95)];
        engine
            .db()
            .upsert_assets(&[a1.clone(), a2.clone(), a3.clone()])
            .unwrap();

        // 1. Ambiguous 8-char prefix MUST fail explicitly (never guess first!)
        let ambig = svc
            .call_tool(
                "get_asset",
                &json!({ "asset_id": "AABBCCDD" }),
                ExternalAgentChannel::Mcp,
            )
            .await;
        assert!(
            ambig.is_error,
            "ambiguous prefix must return explicit error"
        );
        assert!(ambig.first_text().contains("Ambiguous"));

        // Unique 8-char prefix succeeds
        let a3_prefix = &format_swift_uuid(&a3.id)[..8];
        let unique_hit = svc
            .call_tool(
                "get_asset",
                &json!({ "asset_id": a3_prefix }),
                ExternalAgentChannel::Mcp,
            )
            .await;
        assert!(!unique_hit.is_error);
        assert!(unique_hit.first_text().contains("极简白底留白"));

        // Non-existent prefix fails cleanly
        let not_found = svc
            .call_tool(
                "get_asset",
                &json!({ "asset_id": "DEADBEEF" }),
                ExternalAgentChannel::Mcp,
            )
            .await;
        assert!(not_found.is_error);

        // 2. library_overview semantic atlas (recursiveAssetCount, topTags, palette)
        let ov = svc
            .call_tool("library_overview", &json!({}), ExternalAgentChannel::Mcp)
            .await;
        assert!(!ov.is_error);
        let ov_val: Value = serde_json::from_str(&ov.first_text()).unwrap();
        let parent_entry = ov_val["folders"]
            .as_array()
            .unwrap()
            .iter()
            .find(|f| f["path"] == "插画")
            .expect("parent folder in overview");
        assert_eq!(parent_entry["assetCount"], 1);
        assert_eq!(parent_entry["recursiveAssetCount"], 3);
        assert!(!parent_entry["topTags"].as_array().unwrap().is_empty());
        assert!(!parent_entry["palette"].as_array().unwrap().is_empty());

        // 3. search_assets defaults to include_subfolders=true, supports tone, auto facets, and one-shot visual sheet
        let sub_search = svc
            .call_tool(
                "search_assets",
                &json!({
                    "folder_path": "插画",
                    "limit": 2,
                    "render_contact_sheet": true,
                    "sheet_max_width": 512
                }),
                ExternalAgentChannel::Mcp,
            )
            .await;
        assert!(!sub_search.is_error);
        assert!(sub_search
            .content
            .iter()
            .any(|c| matches!(c, ToolContent::Image { .. })));
        let sub_val: Value = serde_json::from_str(&sub_search.first_text()).unwrap();
        assert_eq!(sub_val["totalMatched"], 3);
        assert!(sub_val["facets"]["topFolders"].is_array());
        assert_eq!(sub_val["assets"][0]["slot"], 1);
        assert_eq!(sub_val["assets"][0]["badge"], "#01");
        assert_eq!(sub_val["assets"][0]["id"].as_str().unwrap().len(), 8);

        // Explicit tone filter ("dark" / "暗调")
        let dark_search = svc
            .call_tool(
                "search_assets",
                &json!({ "tone": "暗调" }),
                ExternalAgentChannel::Mcp,
            )
            .await;
        let dark_val: Value = serde_json::from_str(&dark_search.first_text()).unwrap();
        assert_eq!(dark_val["totalMatched"], 1);
        assert_eq!(dark_val["assets"][0]["title"], "深色夜景赛博");

        // 4. Multi-direction `queries[]` 3-in-1 Contact Sheet in semantic_search
        let multi = svc
            .call_tool(
                "semantic_search",
                &json!({
                    "queries": ["夏日海边蓝天", "暗调夜景", "极简白底"],
                    "diversify": true,
                    "render_contact_sheet": true,
                    "limit": 6
                }),
                ExternalAgentChannel::Mcp,
            )
            .await;
        assert!(!multi.is_error);
        assert!(multi
            .content
            .iter()
            .any(|c| matches!(c, ToolContent::Image { .. })));
        let multi_val: Value = serde_json::from_str(&multi.first_text()).unwrap();
        assert_eq!(multi_val["queryGroups"].as_array().unwrap().len(), 3);
        assert!(multi_val["returned"].as_u64().unwrap() >= 2);

        // 5. Batch `get_asset(asset_ids:[...])` with mixed full & 8-char IDs
        let batch_get = svc
            .call_tool(
                "get_asset",
                &json!({
                    "asset_ids": [format_swift_uuid(&a1.id), a3_prefix],
                    "include_image": true
                }),
                ExternalAgentChannel::Mcp,
            )
            .await;
        assert!(!batch_get.is_error);
        let batch_val: Value = serde_json::from_str(&batch_get.first_text()).unwrap();
        assert_eq!(batch_val["returned"], 2);
        assert!(batch_get
            .content
            .iter()
            .any(|c| matches!(c, ToolContent::Image { .. })));

        // 6. `unlike_asset_ids` repulsion excludes the negative asset cleanly
        let steer = svc
            .call_tool(
                "semantic_search",
                &json!({
                    "query": "蓝天 夜景 白底",
                    "unlike_asset_ids": [format_swift_uuid(&a2.id)]
                }),
                ExternalAgentChannel::Mcp,
            )
            .await;
        assert!(!steer.is_error);
        let steer_val: Value = serde_json::from_str(&steer.first_text()).unwrap();
        let hit_ids: Vec<&str> = steer_val["hits"]
            .as_array()
            .unwrap()
            .iter()
            .filter_map(|h| h["id"].as_str())
            .collect();
        assert!(!hit_ids.contains(&format_swift_uuid(&a2.id).as_str()));
    }
}
