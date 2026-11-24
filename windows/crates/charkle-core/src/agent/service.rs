//! Grounded 20-tool External Agent Service (MCP v2 + CLI) powering BOTH:
//! 1. Native Rust **MCP Server (`charkle-cli.exe mcp`)** over stdio JSON-RPC 2.0 (batch + NDJSON/Content-Length)
//! 2. Native Rust **CLI (`charkle-cli.exe <command>`)** for scripts, skills, and terminal workflows
//!
//! Security invariant (matching `CharkleExternalAgentService.swift` & `.trellis/spec/cross-platform/index.md` §3):
//! - Independent `mcpEnabled` and `cliEnabled` channel toggles enforced dynamically per call.
//! - `readOnly` blocks all 8 write tools; `readWriteOrganize` permits organization, ingestion,
//!   folder creation/update, moodboard creation/patching, asset analysis, and soft Trash ONLY —
//!   permanent deletion is NEVER exposed.

use std::collections::{BTreeSet, HashMap, HashSet};
use std::path::PathBuf;
use std::sync::Arc;

use base64::engine::general_purpose::STANDARD as BASE64;
use base64::Engine;
use chrono::Utc;
use serde_json::{json, Value};
use uuid::Uuid;

use crate::agent::policy::ExternalAgentConfigStore;
use crate::engine::LiveCharkleEngine;
use crate::error::{CoreError, CoreResult};
use crate::export::{BoardImageFormat, MoodboardExportOptions};
use crate::intelligence::render_contact_sheet;
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
    pub fn json(value: Value) -> Self {
        let text = serde_json::to_string_pretty(&value).unwrap_or_else(|_| "{}".to_string());
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
                            "version": "1.2.0"
                        },
                        "instructions": "Charkle is a cross-platform visual reference library and moodboard studio. Use `library_overview` to inspect folders and tags, `search_assets` / `semantic_search` / `find_similar_assets` / `quick_jump` / `list_inbox` to locate candidates, `render_contact_sheet` to visually inspect up to 16 numbered thumbnails in one image, `get_board_context` / `export_board_image` to inspect moodboards, and safe write tools (`organize_assets`, `create_folder`, `update_folder`, `ingest_asset`, `compose_moodboard`, `patch_moodboard`, `trash_assets`, `analyze_assets`) when write access is enabled in Charkle Settings."
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
            let paths = build_folder_paths(&folders);
            let items: Vec<Value> = folders
                .iter()
                .map(|f| {
                    json!({
                        "id": format_swift_uuid(&f.id),
                        "name": f.name,
                        "path": paths.get(&f.id).cloned().unwrap_or_else(|| f.name.clone()),
                        "parentID": f.parent_id.map(|id| format_swift_uuid(&id)),
                        "colorHex": f.color_hex,
                        "customSymbol": f.custom_symbol,
                        "assetCount": f.asset_count
                    })
                })
                .collect();
            return Ok(serde_json::to_string_pretty(&json!({
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
            return Ok(serde_json::to_string_pretty(&json!({
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
            "library_overview" => self.handle_library_overview(&policy, channel),
            "search_assets" => self.handle_search_assets(args),
            "list_inbox" => self.handle_list_inbox(args),
            "get_asset" => self.handle_get_asset(args),
            "render_contact_sheet" => self.handle_render_contact_sheet(args),
            "find_similar_assets" => self.handle_find_similar_assets(args),
            "semantic_search" => self.handle_semantic_search(args),
            "quick_jump" => self.handle_quick_jump(args),
            "suggest_folder" => self.handle_suggest_folder(args),
            "list_boards" => self.handle_list_boards(),
            "get_board_context" => self.handle_get_board_context(args),
            "export_board_image" => self.handle_export_board_image(args),
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

    // --- 12 Read Tools ---

    fn handle_library_overview(
        &self,
        policy: &ExternalAgentConfig,
        channel: ExternalAgentChannel,
    ) -> CoreResult<ToolOutput> {
        let all_assets = self.engine.fetch_assets(&FilterCriteria::default())?;
        let trashed_assets = self.engine.fetch_assets(&FilterCriteria {
            only_trashed: true,
            ..Default::default()
        })?;
        let untagged_count = all_assets.iter().filter(|a| a.tags.is_empty()).count();
        let folders = self.engine.fetch_folders()?;
        let folder_paths = build_folder_paths(&folders);
        let smart_folders = self.engine.fetch_smart_folders()?;
        let inbox_count = self.engine.inbox_count()?;
        let boards = self.engine.fetch_boards()?;
        let top_tags = self.engine.fetch_tag_counts()?;

        let mut kind_counts: HashMap<String, usize> = HashMap::new();
        for a in &all_assets {
            let k = serde_json::to_value(a.media_kind)
                .ok()
                .and_then(|v| v.as_str().map(ToOwned::to_owned))
                .unwrap_or_else(|| "image".to_string());
            *kind_counts.entry(k).or_insert(0) += 1;
        }

        let folder_items: Vec<Value> = folders
            .iter()
            .map(|f| {
                json!({
                    "id": format_swift_uuid(&f.id),
                    "name": f.name,
                    "path": folder_paths.get(&f.id).cloned().unwrap_or_else(|| f.name.clone()),
                    "parentID": f.parent_id.map(|id| format_swift_uuid(&id)),
                    "colorHex": f.color_hex,
                    "assetCount": f.asset_count
                })
            })
            .collect();
        let smart_folder_items: Vec<Value> = smart_folders
            .iter()
            .map(|sf| {
                let match_count = all_assets.iter().filter(|a| sf.rule.matches(a)).count();
                json!({
                    "id": format_swift_uuid(&sf.id),
                    "name": sf.name,
                    "matchCount": match_count
                })
            })
            .collect();
        let tag_items: Vec<Value> = top_tags
            .iter()
            .take(40)
            .map(|t| json!({ "name": t.name, "count": t.count }))
            .collect();

        Ok(ToolOutput::json(json!({
            "totalAssets": all_assets.len(),
            "inboxCount": inbox_count,
            "untaggedCount": untagged_count,
            "trashedCount": trashed_assets.len(),
            "boardCount": boards.len(),
            "mcpEnabled": policy.mcp_enabled,
            "cliEnabled": policy.cli_enabled,
            "accessLevel": serde_json::to_value(policy.access_level).unwrap_or(json!("readOnly")),
            "canWrite": policy.allows_write(channel),
            "mediaKindCounts": kind_counts,
            "folders": folder_items,
            "smartFolders": smart_folder_items,
            "topTags": tag_items
        })))
    }

    fn fetch_filtered_assets(
        &self,
        args: &Value,
    ) -> CoreResult<(Vec<AssetRecord>, HashMap<Uuid, String>)> {
        let folders = self.engine.fetch_folders()?;
        let folder_paths = build_folder_paths(&folders);
        let criteria = build_filter_criteria(args, &folders, &folder_paths)?;
        let mut matches = self.engine.fetch_assets(&criteria)?;

        // Optional Smart Folder evaluation filter
        let smart_folder_id = args
            .get("smart_folder_id")
            .and_then(Value::as_str)
            .and_then(|s| Uuid::parse_str(s.trim()).ok());
        let smart_folder_name = args
            .get("smart_folder_name")
            .and_then(Value::as_str)
            .map(str::trim)
            .filter(|s| !s.is_empty());
        if smart_folder_id.is_some() || smart_folder_name.is_some() {
            let sfs = self.engine.fetch_smart_folders()?;
            let found = if let Some(id) = smart_folder_id {
                sfs.into_iter().find(|sf| sf.id == id)
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

        Ok((matches, folder_paths))
    }

    fn handle_search_assets(&self, args: &Value) -> CoreResult<ToolOutput> {
        let (matches, folder_paths) = self.fetch_filtered_assets(args)?;
        let offset = args.get("offset").and_then(Value::as_u64).unwrap_or(0) as usize;
        let limit = args
            .get("limit")
            .and_then(Value::as_u64)
            .unwrap_or(30)
            .clamp(1, 100) as usize;
        let sliced: Vec<Value> = matches
            .iter()
            .skip(offset)
            .take(limit)
            .map(|a| serialize_asset_summary(a, &folder_paths))
            .collect();
        let next_offset = offset + sliced.len();
        let has_more = next_offset < matches.len();
        Ok(ToolOutput::json(json!({
            "totalMatched": matches.len(),
            "offset": offset,
            "returned": sliced.len(),
            "hasMore": has_more,
            "nextOffset": if has_more { Some(next_offset) } else { None },
            "assets": sliced
        })))
    }

    fn handle_list_inbox(&self, args: &Value) -> CoreResult<ToolOutput> {
        let offset = args.get("offset").and_then(Value::as_u64).unwrap_or(0) as usize;
        let limit = args
            .get("limit")
            .and_then(Value::as_u64)
            .unwrap_or(40)
            .clamp(1, 100) as usize;
        let kinds = parse_media_kinds(args.get("media_kinds"));
        let sort_by = parse_sort_order(args.get("sort_by").and_then(Value::as_str), false);
        let criteria = FilterCriteria {
            only_inbox: true,
            kinds,
            sort_by,
            ..Default::default()
        };
        let matches = self.engine.fetch_assets(&criteria)?;
        let empty = HashMap::new();
        let sliced: Vec<Value> = matches
            .iter()
            .skip(offset)
            .take(limit)
            .map(|a| serialize_asset_summary(a, &empty))
            .collect();
        let next_offset = offset + sliced.len();
        let has_more = next_offset < matches.len();
        Ok(ToolOutput::json(json!({
            "inboxTotal": matches.len(),
            "offset": offset,
            "returned": sliced.len(),
            "hasMore": has_more,
            "nextOffset": if has_more { Some(next_offset) } else { None },
            "assets": sliced
        })))
    }

    fn handle_get_asset(&self, args: &Value) -> CoreResult<ToolOutput> {
        let raw_id = args
            .get("asset_id")
            .or_else(|| args.get("id"))
            .and_then(Value::as_str)
            .unwrap_or("");
        let Ok(uuid) = Uuid::parse_str(raw_id.trim()) else {
            return Ok(ToolOutput::error("Missing or invalid UUID for `asset_id`."));
        };
        let Some(asset) = self.engine.fetch_asset(uuid)? else {
            return Ok(ToolOutput::error(format!(
                "Asset not found: {}",
                format_swift_uuid(&uuid)
            )));
        };
        let folders = self.engine.fetch_folders()?;
        let folder_paths = build_folder_paths(&folders);
        let mut obj = serialize_asset_summary(&asset, &folder_paths);
        let thumb_path = self
            .engine
            .media()
            .thumbnail_url(uuid, ThumbnailTier::Preview1400)
            .or_else(|| {
                self.engine
                    .media()
                    .thumbnail_url(uuid, ThumbnailTier::Grid520)
            });
        let orig_path = self
            .engine
            .media()
            .cached_original(&asset)
            .map(|p| p.display().to_string())
            .unwrap_or_default();
        if let Some(map) = obj.as_object_mut() {
            map.insert(
                "ocrText".into(),
                json!(asset.ocr_text.clone().unwrap_or_default()),
            );
            map.insert(
                "aiDescription".into(),
                json!(asset.ai_description.clone().unwrap_or_default()),
            );
            map.insert("suggestedTags".into(), json!(asset.suggested_tags));
            map.insert(
                "sourceDomain".into(),
                json!(asset.source_domain.clone().unwrap_or_default()),
            );
            map.insert("pinnedOffline".into(), json!(asset.pinned_offline));
            map.insert("fileSizeBytes".into(), json!(asset.file_size_bytes));
            map.insert("pixelWidth".into(), json!(asset.pixel_width));
            map.insert("pixelHeight".into(), json!(asset.pixel_height));
            map.insert("richMetadata".into(), json!(asset.rich_metadata));
            map.insert(
                "thumbnailPath".into(),
                json!(thumb_path
                    .as_ref()
                    .map(|p| p.display().to_string())
                    .unwrap_or_default()),
            );
            map.insert("localOriginalPath".into(), json!(orig_path));
        }

        let include_image = args
            .get("include_image")
            .and_then(Value::as_bool)
            .unwrap_or(false);
        let mut content = vec![ToolContent::Text(
            serde_json::to_string_pretty(&obj).unwrap_or_default(),
        )];
        if include_image {
            if let Some(path) = thumb_path {
                if let Ok(bytes) = std::fs::read(&path) {
                    content.push(ToolContent::Image {
                        mime_type: "image/jpeg".to_string(),
                        data: bytes,
                    });
                }
            }
        }
        Ok(ToolOutput {
            content,
            is_error: false,
        })
    }

    fn handle_render_contact_sheet(&self, args: &Value) -> CoreResult<ToolOutput> {
        let ids = parse_uuid_list(args.get("asset_ids"));
        let offset = args.get("offset").and_then(Value::as_u64).unwrap_or(0) as usize;
        let limit = args
            .get("limit")
            .and_then(Value::as_u64)
            .unwrap_or(16)
            .clamp(1, 16) as usize;
        let mut assets = Vec::new();
        let total_matched;
        if !ids.is_empty() {
            total_matched = ids.len();
            for id in ids.into_iter().skip(offset).take(limit) {
                if let Some(a) = self.engine.fetch_asset(id)? {
                    assets.push(a);
                }
            }
        } else {
            let (matches, _) = self.fetch_filtered_assets(args)?;
            total_matched = matches.len();
            assets = matches.into_iter().skip(offset).take(limit).collect();
        }
        if assets.is_empty() {
            return Ok(ToolOutput::error(
                "No matching assets available to render contact sheet.",
            ));
        }
        let cols = args
            .get("columns")
            .and_then(Value::as_u64)
            .unwrap_or(4)
            .clamp(1, 4) as u32;
        let sheet = render_contact_sheet(&assets, self.engine.media(), cols)?;

        if let Some(out_path) = args
            .get("output_path")
            .and_then(Value::as_str)
            .map(str::trim)
            .filter(|s| !s.is_empty())
        {
            std::fs::write(out_path, &sheet.jpeg_bytes)?;
        }

        let manifest: Vec<Value> = sheet
            .slots
            .iter()
            .map(|(slot, a)| {
                json!({
                    "slot": slot,
                    "assetID": format_swift_uuid(&a.id),
                    "title": a.title,
                    "tags": a.tags,
                    "dominantHex": a.dominant_colors.first().map(|c| c.hex.to_uppercase()).unwrap_or_default()
                })
            })
            .collect();
        let next_offset = offset + manifest.len();
        let has_more = next_offset < total_matched;
        let meta_text = serde_json::to_string_pretty(&json!({
            "width": sheet.width,
            "height": sheet.height,
            "totalMatched": total_matched,
            "offset": offset,
            "count": manifest.len(),
            "hasMore": has_more,
            "nextOffset": if has_more { Some(next_offset) } else { None },
            "slots": manifest
        }))
        .unwrap_or_default();

        let include_image = args
            .get("include_image")
            .and_then(Value::as_bool)
            .unwrap_or(true);
        let mut content = vec![ToolContent::Text(meta_text)];
        if include_image {
            content.push(ToolContent::Image {
                mime_type: "image/jpeg".to_string(),
                data: sheet.jpeg_bytes,
            });
        }

        Ok(ToolOutput {
            content,
            is_error: false,
        })
    }

    fn handle_find_similar_assets(&self, args: &Value) -> CoreResult<ToolOutput> {
        let raw_id = args
            .get("asset_id")
            .or_else(|| args.get("id"))
            .and_then(Value::as_str)
            .unwrap_or("");
        let Ok(uuid) = Uuid::parse_str(raw_id.trim()) else {
            return Ok(ToolOutput::error("Missing or invalid UUID for `asset_id`."));
        };
        let limit = args
            .get("limit")
            .and_then(Value::as_u64)
            .unwrap_or(12)
            .clamp(1, 32) as usize;
        let folders = self.engine.fetch_folders()?;
        let folder_paths = build_folder_paths(&folders);
        let scored = self.engine.similar_assets(uuid, limit)?;
        let matches_json: Vec<Value> = scored
            .iter()
            .map(|s| {
                json!({
                    "score": (s.score * 1000.0).round() / 1000.0,
                    "matchReasons": s.match_reasons,
                    "asset": serialize_asset_summary(&s.asset, &folder_paths)
                })
            })
            .collect();

        let mut content = vec![ToolContent::Text(
            serde_json::to_string_pretty(&json!({
                "referenceAssetID": format_swift_uuid(&uuid),
                "count": matches_json.len(),
                "matches": matches_json
            }))
            .unwrap_or_default(),
        )];

        let with_sheet = args
            .get("render_contact_sheet")
            .and_then(Value::as_bool)
            .unwrap_or(false);
        if with_sheet && !scored.is_empty() {
            let sheet_assets: Vec<AssetRecord> =
                scored.iter().take(16).map(|s| s.asset.clone()).collect();
            if let Ok(sheet) = render_contact_sheet(&sheet_assets, self.engine.media(), 4) {
                content.push(ToolContent::Image {
                    mime_type: "image/jpeg".to_string(),
                    data: sheet.jpeg_bytes,
                });
            }
        }

        Ok(ToolOutput {
            content,
            is_error: false,
        })
    }

    fn handle_semantic_search(&self, args: &Value) -> CoreResult<ToolOutput> {
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

        let (matches, folder_paths) = self.fetch_filtered_assets(args)?;
        let tokens: Vec<String> = query
            .split_whitespace()
            .map(|s| s.to_lowercase())
            .filter(|s| !s.is_empty())
            .collect();
        let mut ranked: Vec<(f64, &AssetRecord)> = matches
            .iter()
            .map(|a| {
                let mut score = 0.45_f64;
                let title_l = a.title.to_lowercase();
                let notes_l = a.notes.to_lowercase();
                let desc_l = a.ai_description.as_deref().unwrap_or("").to_lowercase();
                let ocr_l = a.ocr_text.as_deref().unwrap_or("").to_lowercase();
                for tok in &tokens {
                    if title_l.contains(tok) {
                        score += 0.25;
                    }
                    if a.tags.iter().any(|t| t.to_lowercase().contains(tok)) {
                        score += 0.2;
                    }
                    if desc_l.contains(tok) || notes_l.contains(tok) {
                        score += 0.15;
                    }
                    if ocr_l.contains(tok) {
                        score += 0.1;
                    }
                }
                score += (a.rating as f64) * 0.02;
                (score.min(1.0), a)
            })
            .collect();
        ranked.sort_by(|a, b| b.0.partial_cmp(&a.0).unwrap_or(std::cmp::Ordering::Equal));

        let hits: Vec<Value> = ranked
            .into_iter()
            .take(limit)
            .map(|(score, a)| {
                json!({
                    "score": (score * 1000.0).round() / 1000.0,
                    "asset": serialize_asset_summary(a, &folder_paths)
                })
            })
            .collect();
        Ok(ToolOutput::json(json!({
            "query": query,
            "mode": "hybridLocal",
            "count": hits.len(),
            "hits": hits
        })))
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
            "count": matches.len(),
            "matches": matches
        })))
    }

    fn handle_suggest_folder(&self, args: &Value) -> CoreResult<ToolOutput> {
        let mut ids = parse_uuid_list(args.get("asset_ids"));
        if let Some(single) = args
            .get("asset_id")
            .and_then(Value::as_str)
            .and_then(|s| Uuid::parse_str(s.trim()).ok())
        {
            if !ids.contains(&single) {
                ids.insert(0, single);
            }
        }
        if ids.is_empty() {
            return Ok(ToolOutput::error(
                "Provide `asset_id` or `asset_ids` (up to 20 UUIDs).",
            ));
        }
        let folders = self.engine.fetch_folders()?;
        let folder_paths = build_folder_paths(&folders);
        let mut suggestions = Vec::new();
        for id in ids.into_iter().take(20) {
            let suggestion = self.engine.suggest_folder(id)?;
            suggestions.push(json!({
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
            "count": suggestions.len(),
            "suggestions": suggestions
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
                "Moodboard not found. Pass a valid `board_id` UUID or matching `title`.",
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

    fn handle_export_board_image(&self, args: &Value) -> CoreResult<ToolOutput> {
        let Some(doc) = self.resolve_board(args)? else {
            return Ok(ToolOutput::error(
                "Moodboard not found. Pass a valid `board_id` UUID or matching `title`.",
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
            include_annotations: args
                .get("include_annotations")
                .and_then(Value::as_bool)
                .unwrap_or(true),
            include_palette_strip: args
                .get("include_palette_strip")
                .and_then(Value::as_bool)
                .unwrap_or(true),
            dark_appearance: args
                .get("dark_appearance")
                .and_then(Value::as_bool)
                .unwrap_or(false),
            container_width,
        };
        let bytes = self.engine.export_board_image_bytes(&doc, &opts)?;
        let saved_path = args
            .get("output_path")
            .and_then(Value::as_str)
            .map(str::trim)
            .filter(|s| !s.is_empty());
        if let Some(p) = saved_path {
            std::fs::write(p, &bytes)?;
        }
        let mime = match format {
            BoardImageFormat::Png => "image/png",
            BoardImageFormat::Jpeg => "image/jpeg",
        };
        let meta = serde_json::to_string_pretty(&json!({
            "boardID": format_swift_uuid(&doc.id),
            "title": doc.title,
            "bytes": bytes.len(),
            "format": format_str,
            "outputPath": saved_path.unwrap_or("")
        }))
        .unwrap_or_default();
        let include_image = args
            .get("include_image")
            .and_then(Value::as_bool)
            .unwrap_or(true);
        let mut content = vec![ToolContent::Text(meta)];
        if include_image {
            content.push(ToolContent::Image {
                mime_type: mime.to_string(),
                data: bytes,
            });
        }
        Ok(ToolOutput {
            content,
            is_error: false,
        })
    }

    // --- 8 Safe Write Tools (NO permanent deletion allowed!) ---

    fn handle_organize_assets(&self, args: &Value) -> CoreResult<ToolOutput> {
        let ids = parse_uuid_list(args.get("asset_ids"));
        if ids.is_empty() {
            return Ok(ToolOutput::error(
                "`asset_ids` must be a non-empty array of asset UUID strings.",
            ));
        }
        let folders = self.engine.fetch_folders()?;
        let folder_paths = build_folder_paths(&folders);
        let folder_assignment = if args
            .get("move_to_inbox")
            .and_then(Value::as_bool)
            .unwrap_or(false)
        {
            FolderAssignment::Inbox
        } else {
            resolve_optional_folder_id(args, &folders, &folder_paths)?
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
            folder_assignment,
            add_tags: string_array_arg(args.get("add_tags")),
            remove_tags: string_array_arg(args.get("remove_tags")),
            accept_suggested_tags: args
                .get("accept_suggested_tags")
                .and_then(Value::as_bool)
                .unwrap_or(false),
            dismiss_suggested_tags: string_array_arg(args.get("dismiss_suggested_tags")),
            rating: args
                .get("rating")
                .and_then(Value::as_i64)
                .map(|r| r.clamp(0, 5) as i32),
            is_trashed: None,
            pinned_offline: args.get("pinned_offline").and_then(Value::as_bool),
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
        let parent_id = if let Some(pid) = args
            .get("parent_id")
            .and_then(Value::as_str)
            .and_then(|s| Uuid::parse_str(s.trim()).ok())
        {
            Some(pid)
        } else if let Some(ppath) = args
            .get("parent_path")
            .and_then(Value::as_str)
            .map(str::trim)
            .filter(|s| !s.is_empty())
        {
            folder_paths
                .iter()
                .find(|(_, p)| p.eq_ignore_ascii_case(ppath))
                .map(|(id, _)| *id)
                .or_else(|| {
                    folders
                        .iter()
                        .find(|f| f.name.eq_ignore_ascii_case(ppath))
                        .map(|f| f.id)
                })
        } else {
            None
        };
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
        let Some(target_id) = resolve_optional_folder_id(args, &folders, &folder_paths)? else {
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

        let move_to_root = args
            .get("move_to_root")
            .and_then(Value::as_bool)
            .unwrap_or(false);
        if move_to_root {
            let updated = self.engine.move_folder(target_id, None, None)?;
            if let Some(f) = updated.into_iter().find(|f| f.id == target_id) {
                folder = f;
            }
        } else if args.get("parent_id").is_some() || args.get("parent_path").is_some() {
            let new_parent = if let Some(pid) = args
                .get("parent_id")
                .and_then(Value::as_str)
                .and_then(|s| Uuid::parse_str(s.trim()).ok())
            {
                Some(pid)
            } else if let Some(ppath) = args
                .get("parent_path")
                .and_then(Value::as_str)
                .map(str::trim)
                .filter(|s| !s.is_empty())
            {
                folder_paths
                    .iter()
                    .find(|(_, p)| p.eq_ignore_ascii_case(ppath))
                    .map(|(id, _)| *id)
                    .or_else(|| {
                        folders
                            .iter()
                            .find(|f| f.name.eq_ignore_ascii_case(ppath))
                            .map(|f| f.id)
                    })
            } else {
                None
            };
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
        let folder_id = resolve_optional_folder_id(args, &folders, &folder_paths)?;
        let target_board_id = args
            .get("target_board_id")
            .and_then(Value::as_str)
            .and_then(|s| Uuid::parse_str(s.trim()).ok());

        let mut inputs = Vec::new();
        for fp in string_array_arg(args.get("file_paths")) {
            inputs.push(CaptureInput::FilePath(PathBuf::from(fp)));
        }
        if let Some(fp) = args
            .get("file_path")
            .and_then(Value::as_str)
            .map(str::trim)
            .filter(|s| !s.is_empty())
        {
            inputs.push(CaptureInput::FilePath(PathBuf::from(fp)));
        }
        if let Some(url) = args
            .get("web_url")
            .or_else(|| args.get("url"))
            .and_then(Value::as_str)
            .map(str::trim)
            .filter(|s| !s.is_empty())
        {
            inputs.push(CaptureInput::WebUrl {
                url: url.to_string(),
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
                "Provide one of `file_path`, `file_paths`, `web_url`/`url`, `color_hex`, or `text` to ingest.",
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
            "assets": created.iter().map(|a| serialize_asset_summary(a, &folder_paths)).collect::<Vec<_>>()
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
        let use_freeform = args
            .get("use_freeform")
            .and_then(Value::as_bool)
            .unwrap_or(false);
        let explicit_ids = parse_uuid_list(args.get("asset_ids"));
        let hero_set: HashSet<Uuid> = parse_uuid_list(args.get("hero_asset_ids"))
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
            let scope_id = resolve_optional_folder_id(args, &folders, &folder_paths)?;
            let preferred_count = args
                .get("preferred_count")
                .and_then(Value::as_u64)
                .unwrap_or(12)
                .clamp(2, 24) as usize;
            let req = MoodboardCurationRequest {
                prompt: prompt.to_string(),
                seed_asset_ids: parse_uuid_list(args.get("seed_asset_ids")),
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
                "Moodboard not found. Pass a valid `board_id` UUID or matching `title`.",
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
        if let Some(use_freeform) = args.get("use_freeform").and_then(Value::as_bool) {
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

        let remove_asset_set: HashSet<Uuid> = parse_uuid_list(args.get("remove_asset_ids"))
            .into_iter()
            .collect();
        let remove_node_set: HashSet<Uuid> = parse_uuid_list(args.get("remove_node_ids"))
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

        // Compute non-overlapping placement baseline below existing maxY
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

        let add_ids = parse_uuid_list(args.get("add_asset_ids"));
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
        let ids = parse_uuid_list(args.get("asset_ids"));
        if ids.is_empty() {
            return Ok(ToolOutput::error(
                "`asset_ids` must be a non-empty array of asset UUID strings.",
            ));
        }
        let trashed = args.get("trashed").and_then(Value::as_bool).unwrap_or(true);
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
        let ids = parse_uuid_list(args.get("asset_ids"));
        if ids.is_empty() {
            return Ok(ToolOutput::error(
                "`asset_ids` must be a non-empty array of asset UUID strings (1-20).",
            ));
        }
        let refresh_rich = args
            .get("refresh_rich_metadata")
            .and_then(Value::as_bool)
            .unwrap_or(false);
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
        {
            if let Ok(uuid) = Uuid::parse_str(raw_id) {
                return self.engine.fetch_board(uuid);
            }
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

    // =========================================================================
    // MCP v2 Resources, Templates, Prompts & 20 Annotated Tools
    // =========================================================================

    pub fn mcp_resource_definitions() -> Vec<Value> {
        vec![
            json!({
                "uri": "charkle://library/overview",
                "name": "Charkle Library Overview",
                "description": "Folders, smart folders, top tags, media distribution, counts, and active external agent permission policy.",
                "mimeType": "application/json"
            }),
            json!({
                "uri": "charkle://boards",
                "name": "Charkle Moodboards",
                "description": "Summary list of all moodboards in Charkle with palettes and layout modes.",
                "mimeType": "application/json"
            }),
            json!({
                "uri": "charkle://folders",
                "name": "Charkle Folder Tree",
                "description": "Full hierarchical folder tree with UUIDs, paths, parent IDs, colors, and asset counts.",
                "mimeType": "application/json"
            }),
            json!({
                "uri": "charkle://smart-folders",
                "name": "Charkle Smart Folders",
                "description": "Saved rule-based smart folders with current match counts.",
                "mimeType": "application/json"
            }),
        ]
    }

    pub fn mcp_resource_template_definitions() -> Vec<Value> {
        vec![
            json!({
                "uriTemplate": "charkle://assets/{asset_id}",
                "name": "Charkle Asset Details",
                "description": "Complete metadata for a single asset UUID including EXIF, AI generation prompts, social/GitHub metadata, palette, OCR, and local paths.",
                "mimeType": "application/json"
            }),
            json!({
                "uriTemplate": "charkle://boards/{board_id}",
                "name": "Charkle Moodboard Context",
                "description": "Full structured design context for a Moodboard UUID including notes, sections, connectors, harmonized palette, and referenced assets.",
                "mimeType": "application/json"
            }),
        ]
    }

    pub fn mcp_prompt_definitions() -> Vec<Value> {
        vec![
            json!({
                "name": "triage_inbox",
                "description": "Inspect untriaged Charkle Inbox assets visually with Contact Sheets and folder recommendations, then propose or apply clean folder & tag organization.",
                "arguments": [
                    { "name": "limit", "description": "Maximum number of Inbox items to review in this batch (default 16).", "required": false },
                    { "name": "apply_changes", "description": "Set to 'true' to apply changes immediately when write access is enabled; otherwise propose a plan first.", "required": false }
                ]
            }),
            json!({
                "name": "curate_moodboard",
                "description": "End-to-end grounded visual curation workflow: inspect the library, recall candidates, inspect Contact Sheets visually, and compose a structured Moodboard.",
                "arguments": [
                    { "name": "brief", "description": "Creative direction, style, mood, or color brief for the moodboard.", "required": true },
                    { "name": "folder_path", "description": "Optional folder path to restrict candidate assets.", "required": false },
                    { "name": "count", "description": "Target number of visual references (default 10).", "required": false }
                ]
            }),
            json!({
                "name": "extract_design_tokens",
                "description": "Read a Charkle Moodboard's harmonized palette, curator notes, section themes, and exported visual snapshot to generate structured design tokens.",
                "arguments": [
                    { "name": "board", "description": "Moodboard title or UUID.", "required": true },
                    { "name": "format", "description": "Target format such as 'css', 'tailwind', or 'json' (default 'css').", "required": false }
                ]
            }),
            json!({
                "name": "inspect_ai_prompts",
                "description": "Search AI-generated reference images in Charkle and extract their embedded generation prompts, models, samplers, seeds, and LoRA recipes.",
                "arguments": [
                    { "name": "query", "description": "Optional keyword, model name, or style filter.", "required": false },
                    { "name": "limit", "description": "Maximum number of assets to inspect (default 12).", "required": false }
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
                    "After confirming folder fit and normalized tags, call `organize_assets` to apply the plan (never delete anything permanently)."
                } else {
                    "Present a concise table of recommended folder, tags, and notes per item for user approval before calling `organize_assets`."
                };
                Some(json!({
                    "description": "Triage untriaged Inbox assets in Charkle",
                    "messages": [{
                        "role": "user",
                        "content": {
                            "type": "text",
                            "text": format!(
                                "Please triage up to {limit} untriaged assets in my Charkle Inbox:\n1. Call `library_overview` to understand my existing folder hierarchy and canonical tag vocabulary.\n2. Call `render_contact_sheet` with `only_inbox: true, limit: {limit}` so you can visually inspect the items.\n3. Call `suggest_folder` on those Inbox `asset_ids` to get grounded folder recommendations.\n4. Reuse existing folder paths and tag naming conventions wherever possible.\n5. {action}"
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
                    "Search across the full library.".to_string()
                } else {
                    format!(
                        "Focus primarily on folder `{folder}` (with `include_subfolders: true`)."
                    )
                };
                Some(json!({
                    "description": "Curate a grounded Charkle Moodboard",
                    "messages": [{
                        "role": "user",
                        "content": {
                            "type": "text",
                            "text": format!(
                                "Curate a Charkle Moodboard for this brief: \"{brief}\" (target ~{count} references).\n1. Call `library_overview` to discover folders, tags, and media kinds.\n2. {scope} Combine `search_assets` / `semantic_search` and `find_similar_assets` around strong anchors to gather ~16–24 candidates.\n3. Call `render_contact_sheet` on the candidate `asset_ids` to visually inspect composition, lighting, and color harmony.\n4. Select the strongest ~{count} assets and call `compose_moodboard` with `hero_asset_ids` and a concise `curator_note`."
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
                    "First call `list_boards` to locate the target moodboard, then inspect it."
                        .to_string()
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
                                "Extract production-ready `{format_name}` design tokens from my Charkle Moodboard.\n1. {board_hint}\n2. Call `get_board_context` to read the harmonized palette, curator notes, section groupings, connectors, and referenced assets.\n3. Call `export_board_image` to inspect visual mood, contrast, and hierarchy.\n4. Output clean semantic tokens in `{format_name}` format."
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
                    format!("Call `search_assets` with `media_kinds: [\"image\"]` and `limit: {limit}`.")
                } else {
                    format!("Call `search_assets` with `query: \"{query}\"`, `media_kinds: [\"image\"]`, and `limit: {limit}`.")
                };
                Some(json!({
                    "description": "Inspect embedded AI generation prompts and parameters",
                    "messages": [{
                        "role": "user",
                        "content": {
                            "type": "text",
                            "text": format!(
                                "Inspect AI-generated visual references in my Charkle library:\n1. {search_step}\n2. Call `get_asset` on relevant candidates to read their `richMetadata.aiGeneration` fields.\n3. Summarize recurring prompt patterns, model/LoRA combinations, and notable parameter differences."
                            )
                        }
                    }]
                }))
            }
            _ => None,
        }
    }

    pub fn mcp_tool_definitions() -> Vec<Value> {
        vec![
            // 12 Read Tools
            tool_def(
                "library_overview",
                "Library Overview",
                "Inspect total/inbox/untagged/trashed counts, hierarchical folders, smart folders, top tags, media distribution, boards, and active external-agent permissions.",
                json!({ "type": "object", "properties": {} }),
                true,
                true,
                false,
            ),
            tool_def(
                "search_assets",
                "Search Assets",
                "Search and paginate assets by full-text query, folder (with include_subfolders), smart folder, tags, CIELAB color, media_kinds, aspect_shape, rating, recency, or Trash state.",
                json!({
                    "type": "object",
                    "properties": {
                        "query": { "type": "string" },
                        "folder_id": { "type": "string" },
                        "folder_path": { "type": "string" },
                        "include_subfolders": { "type": "boolean" },
                        "smart_folder_id": { "type": "string" },
                        "smart_folder_name": { "type": "string" },
                        "tags": { "type": "array", "items": { "type": "string" } },
                        "media_kinds": { "type": "array", "items": { "type": "string" } },
                        "aspect_shape": { "type": "string" },
                        "color_hex": { "type": "string" },
                        "color_tolerance": { "type": "number" },
                        "min_rating": { "type": "integer" },
                        "only_inbox": { "type": "boolean" },
                        "only_untagged": { "type": "boolean" },
                        "only_recent_days": { "type": "integer" },
                        "only_pinned_offline": { "type": "boolean" },
                        "only_trashed": { "type": "boolean" },
                        "include_trashed": { "type": "boolean" },
                        "sort_by": { "type": "string" },
                        "offset": { "type": "integer" },
                        "limit": { "type": "integer" }
                    }
                }),
                true,
                true,
                false,
            ),
            tool_def(
                "list_inbox",
                "List Inbox",
                "List newest untriaged assets currently waiting in the Charkle Inbox with pagination and optional media-kind filtering.",
                json!({
                    "type": "object",
                    "properties": {
                        "media_kinds": { "type": "array", "items": { "type": "string" } },
                        "sort_by": { "type": "string" },
                        "offset": { "type": "integer" },
                        "limit": { "type": "integer" }
                    }
                }),
                true,
                true,
                false,
            ),
            tool_def(
                "get_asset",
                "Get Asset Details",
                "Fetch complete metadata, EXIF, AI generation prompts, social/GitHub richMetadata, OCR text, tags, dimensions, local paths, and optional inline preview JPEG for one asset UUID.",
                json!({
                    "type": "object",
                    "properties": {
                        "asset_id": { "type": "string" },
                        "include_image": { "type": "boolean" },
                        "image_max_side": { "type": "integer" }
                    },
                    "required": ["asset_id"]
                }),
                true,
                true,
                false,
            ),
            tool_def(
                "render_contact_sheet",
                "Render Visual Contact Sheet",
                "Render up to 16 numbered asset thumbnails into a visual contact-sheet JPEG with pagination, subfolder recursion, and slot-to-assetID manifest.",
                json!({
                    "type": "object",
                    "properties": {
                        "asset_ids": { "type": "array", "items": { "type": "string" } },
                        "query": { "type": "string" },
                        "folder_id": { "type": "string" },
                        "folder_path": { "type": "string" },
                        "include_subfolders": { "type": "boolean" },
                        "smart_folder_id": { "type": "string" },
                        "smart_folder_name": { "type": "string" },
                        "tags": { "type": "array", "items": { "type": "string" } },
                        "media_kinds": { "type": "array", "items": { "type": "string" } },
                        "only_inbox": { "type": "boolean" },
                        "only_untagged": { "type": "boolean" },
                        "only_trashed": { "type": "boolean" },
                        "color_hex": { "type": "string" },
                        "columns": { "type": "integer" },
                        "offset": { "type": "integer" },
                        "limit": { "type": "integer" },
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
                "Find visually and stylistically similar assets to a reference asset UUID using palette proximity, embeddings, and shared tags; optionally render a Contact Sheet.",
                json!({
                    "type": "object",
                    "properties": {
                        "asset_id": { "type": "string" },
                        "limit": { "type": "integer" },
                        "render_contact_sheet": { "type": "boolean" }
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
                "Run hybrid semantic + keyword + metadata search across the Charkle library.",
                json!({
                    "type": "object",
                    "properties": {
                        "query": { "type": "string" },
                        "folder_id": { "type": "string" },
                        "folder_path": { "type": "string" },
                        "include_subfolders": { "type": "boolean" },
                        "tags": { "type": "array", "items": { "type": "string" } },
                        "media_kinds": { "type": "array", "items": { "type": "string" } },
                        "color_hex": { "type": "string" },
                        "min_rating": { "type": "integer" },
                        "limit": { "type": "integer" }
                    },
                    "required": ["query"]
                }),
                true,
                true,
                true,
            ),
            tool_def(
                "quick_jump",
                "Quick Jump",
                "Unified fast fuzzy search across folders, moodboards, tags, and assets mirroring Ctrl+J.",
                json!({
                    "type": "object",
                    "properties": {
                        "query": { "type": "string" },
                        "limit": { "type": "integer" }
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
                "Recommend the best existing Charkle folder for one or more assets (up to 20 per call).",
                json!({
                    "type": "object",
                    "properties": {
                        "asset_id": { "type": "string" },
                        "asset_ids": { "type": "array", "items": { "type": "string" } }
                    }
                }),
                true,
                true,
                false,
            ),
            tool_def(
                "list_boards",
                "List Moodboards",
                "List all moodboards with item counts, palettes, and offline pin status.",
                json!({ "type": "object", "properties": {} }),
                true,
                true,
                false,
            ),
            tool_def(
                "get_board_context",
                "Get Moodboard Context",
                "Inspect nodes, notes, group frames, palette strips, connectors, and strokes of a moodboard.",
                json!({
                    "type": "object",
                    "properties": {
                        "board_id": { "type": "string" },
                        "title": { "type": "string" }
                    }
                }),
                true,
                true,
                false,
            ),
            tool_def(
                "export_board_image",
                "Export Moodboard Image",
                "Render a moodboard to high-resolution PNG/JPEG (and optionally save to output_path).",
                json!({
                    "type": "object",
                    "properties": {
                        "board_id": { "type": "string" },
                        "title": { "type": "string" },
                        "format": { "type": "string", "enum": ["png", "jpg"] },
                        "width": { "type": "integer" },
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
                "[Write] Batch-organize assets: move to folder/Inbox, add/remove tags, accept/dismiss suggested tags, update title/notes/ai_description/rating/pinned_offline.",
                json!({
                    "type": "object",
                    "properties": {
                        "asset_ids": { "type": "array", "items": { "type": "string" } },
                        "folder_id": { "type": "string" },
                        "folder_path": { "type": "string" },
                        "move_to_inbox": { "type": "boolean" },
                        "add_tags": { "type": "array", "items": { "type": "string" } },
                        "remove_tags": { "type": "array", "items": { "type": "string" } },
                        "accept_suggested_tags": { "type": "boolean" },
                        "dismiss_suggested_tags": { "type": "array", "items": { "type": "string" } },
                        "title": { "type": "string" },
                        "notes": { "type": "string" },
                        "ai_description": { "type": "string" },
                        "rating": { "type": "integer" },
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
                "[Write] Create a new root or nested folder in the library.",
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
                "[Write] Rename a folder, move it under a new parent or root, or update its color/symbol. Deleting folders is intentionally forbidden.",
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
                "[Write] Ingest one or more local files, a web/GitHub/Social URL, color swatch, or text snippet into Charkle with optional folder, board, tags, notes, and rating.",
                json!({
                    "type": "object",
                    "properties": {
                        "file_path": { "type": "string" },
                        "file_paths": { "type": "array", "items": { "type": "string" } },
                        "web_url": { "type": "string" },
                        "url": { "type": "string" },
                        "color_hex": { "type": "string" },
                        "text": { "type": "string" },
                        "title": { "type": "string" },
                        "notes": { "type": "string" },
                        "rating": { "type": "integer" },
                        "tags": { "type": "array", "items": { "type": "string" } },
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
                "[Write] Create a curated moodboard from explicit `asset_ids` or automatic `prompt` curation.",
                json!({
                    "type": "object",
                    "properties": {
                        "title": { "type": "string" },
                        "subtitle": { "type": "string" },
                        "prompt": { "type": "string" },
                        "asset_ids": { "type": "array", "items": { "type": "string" } },
                        "hero_asset_ids": { "type": "array", "items": { "type": "string" } },
                        "layout_style": { "type": "string", "enum": ["magazine", "balanced", "compact"] },
                        "use_freeform": { "type": "boolean" },
                        "curator_note": { "type": "string" },
                        "preferred_count": { "type": "integer" }
                    }
                }),
                false,
                false,
                false,
            ),
            tool_def(
                "patch_moodboard",
                "Patch Moodboard",
                "[Write] Non-destructively update a moodboard: rename, switch layout mode, append assets below maxY, add section headers or styled notes, or remove unlocked items.",
                json!({
                    "type": "object",
                    "properties": {
                        "board_id": { "type": "string" },
                        "title": { "type": "string" },
                        "new_title": { "type": "string" },
                        "subtitle": { "type": "string" },
                        "use_freeform": { "type": "boolean" },
                        "layout_style": { "type": "string", "enum": ["magazine", "balanced", "compact"] },
                        "add_asset_ids": { "type": "array", "items": { "type": "string" } },
                        "remove_asset_ids": { "type": "array", "items": { "type": "string" } },
                        "remove_node_ids": { "type": "array", "items": { "type": "string" } },
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
                "[Write] Soft-move assets to Trash or restore them. Permanent deletion is strictly forbidden.",
                json!({
                    "type": "object",
                    "properties": {
                        "asset_ids": { "type": "array", "items": { "type": "string" } },
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
                "[Write] Run local EXIF/AI prompt hydration and offline OCR on up to 20 assets; optionally refresh live GitHub/Social rich metadata.",
                json!({
                    "type": "object",
                    "properties": {
                        "asset_ids": { "type": "array", "items": { "type": "string" } },
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

fn resolve_optional_folder_id(
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
        let uuid = Uuid::parse_str(raw_id).map_err(|_| {
            CoreError::InvalidOperation(format!("Invalid folder_id UUID: {raw_id}"))
        })?;
        return Ok(Some(uuid));
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

fn parse_media_kinds(val: Option<&Value>) -> BTreeSet<MediaKind> {
    string_array_arg(val)
        .into_iter()
        .filter_map(|raw| serde_json::from_value::<MediaKind>(Value::String(raw)).ok())
        .collect()
}

fn parse_sort_order(raw: Option<&str>, has_query: bool) -> SortOrder {
    match raw.map(|s| s.trim().to_ascii_lowercase()).as_deref() {
        Some("oldest") => SortOrder::Oldest,
        Some("name_asc") | Some("nameasc") => SortOrder::NameAsc,
        Some("rating_desc") | Some("ratingdesc") => SortOrder::RatingDesc,
        Some("file_size_desc") | Some("filesizedesc") => SortOrder::FileSizeDesc,
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

fn build_filter_criteria(
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
    let only_inbox = args
        .get("only_inbox")
        .and_then(Value::as_bool)
        .unwrap_or(false);
    let only_untagged = args
        .get("only_untagged")
        .and_then(Value::as_bool)
        .unwrap_or(false);
    let include_subfolders = args
        .get("include_subfolders")
        .and_then(Value::as_bool)
        .unwrap_or(false);
    let only_recent_days = args
        .get("only_recent_days")
        .and_then(Value::as_i64)
        .map(|d| d.max(1) as i32);
    let only_pinned_offline = args
        .get("only_pinned_offline")
        .and_then(Value::as_bool)
        .unwrap_or(false);
    let only_trashed = args
        .get("only_trashed")
        .and_then(Value::as_bool)
        .unwrap_or(false);
    let include_trashed = args
        .get("include_trashed")
        .and_then(Value::as_bool)
        .unwrap_or(false);
    let sort_by = parse_sort_order(
        args.get("sort_by").and_then(Value::as_str),
        !query.is_empty(),
    );
    let folder_id = if only_inbox {
        None
    } else {
        resolve_optional_folder_id(args, folders, folder_paths)?
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

fn serialize_asset_summary(asset: &AssetRecord, folder_paths: &HashMap<Uuid, String>) -> Value {
    json!({
        "id": format_swift_uuid(&asset.id),
        "title": asset.title,
        "fileName": asset.file_name,
        "mediaKind": asset.media_kind,
        "folderID": asset.folder_id.map(|id| format_swift_uuid(&id)),
        "folderPath": asset.folder_id.and_then(|id| folder_paths.get(&id).cloned()).unwrap_or_else(|| "Inbox".to_string()),
        "tags": asset.tags,
        "rating": asset.rating,
        "notes": asset.notes,
        "dominantColors": asset.dominant_colors.iter().map(|c| c.hex.to_uppercase()).collect::<Vec<_>>(),
        "isTrashed": asset.is_trashed
    })
}

fn parse_uuid_list(val: Option<&Value>) -> Vec<Uuid> {
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

        // 1. Default policy: mcp=true, cli=true, accessLevel=readOnly; protocol negotiation
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

        // JSON-RPC 2.0 batch array + tools/list + resources + templates + prompts + logging/setLevel
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
        // Every tool must carry MCP annotations with destructiveHint: false
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

        // Prompt get renders curated studio workflow
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

        // 2. Independent channel switch: disable MCP while keeping CLI enabled
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

        // 3. CLI write tools work (including update_folder, quick_jump, suggest_folder, analyze_assets)
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
                &json!({ "folder_id": folder_id, "new_name": "建筑与光影", "color_hex": "#2A60E0" }),
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

        // Quick jump, similar assets, suggest folder, analyze assets
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
                &json!({ "asset_id": &asset_id_str }),
                ExternalAgentChannel::Cli,
            )
            .await;
        assert!(!similar.is_error);
        let suggest = svc
            .call_tool(
                "suggest_folder",
                &json!({ "asset_id": &asset_id_str }),
                ExternalAgentChannel::Cli,
            )
            .await;
        assert!(!suggest.is_error);
        let analyzed = svc
            .call_tool(
                "analyze_assets",
                &json!({ "asset_ids": [&asset_id_str] }),
                ExternalAgentChannel::Cli,
            )
            .await;
        assert!(!analyzed.is_error);

        // Contact sheet renders real JPEG image payload with pagination fields
        let sheet = svc
            .call_tool(
                "render_contact_sheet",
                &json!({ "asset_ids": [&asset_id_str] }),
                ExternalAgentChannel::Cli,
            )
            .await;
        assert!(!sheet.is_error);
        assert!(sheet.content.iter().any(
            |c| matches!(c, ToolContent::Image { mime_type, .. } if mime_type == "image/jpeg")
        ));

        // Compose moodboard + Patch with non-overlapping placement + Soft trash
        let board = svc
            .call_tool(
                "compose_moodboard",
                &json!({ "title": "Agent Board", "asset_ids": [&asset_id_str] }),
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
                &json!({ "asset_ids": [&asset_id_str], "trashed": true }),
                ExternalAgentChannel::Cli,
            )
            .await;
        assert!(!trashed.is_error);
        // Security invariant: asset MUST still exist in DB with is_trashed = true!
        let still_there = engine
            .fetch_asset(Uuid::parse_str(&asset_id_str).unwrap())
            .unwrap()
            .expect("soft trash must never permanently delete");
        assert!(still_there.is_trashed);

        // Permanent delete tool does not exist at all
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
}
