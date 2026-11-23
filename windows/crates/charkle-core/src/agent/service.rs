//! Grounded 14-tool External Agent Service powering BOTH:
//! 1. Native Rust **MCP Server (`charkle-cli.exe mcp`)** over stdio JSON-RPC 2.0
//! 2. Native Rust **CLI (`charkle-cli.exe <command>`)** for scripts, skills, and terminal workflows
//!
//! Security invariant (matching `CharkleExternalAgentService.swift`):
//! - Independent `mcpEnabled` and `cliEnabled` channel toggles enforced dynamically per call.
//! - `readOnly` blocks all 6 write tools; `readWriteOrganize` permits organization, ingestion,
//!   moodboard creation/patching, and soft Trash ONLY — permanent deletion is NEVER exposed.

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
    AssetBatchPatch, AssetRecord, FilterCriteria, FolderAssignment, FolderRecord, MediaKind,
    SortOrder,
};
use crate::models::media::{CaptureInput, ThumbnailTier};
use crate::models::moodboard::{
    AutoLayoutConfig, BoardLayoutMode, BoardNode, BoardNodeKind, BoardRect, EditorialStyle,
    MoodboardCurationRequest, MoodboardDocument, NoteStyle,
};
use crate::wire::swift_codec::format_swift_uuid;

pub const READ_TOOL_NAMES: &[&str] = &[
    "library_overview",
    "search_assets",
    "list_inbox",
    "get_asset",
    "render_contact_sheet",
    "list_boards",
    "get_board_context",
    "export_board_image",
];

pub const WRITE_TOOL_NAMES: &[&str] = &[
    "organize_assets",
    "create_folder",
    "ingest_asset",
    "compose_moodboard",
    "patch_moodboard",
    "trash_assets",
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

    fn notify_write(&self, kind: &str) {
        if let Some(hook) = &self.on_write {
            hook(kind);
        }
    }

    // =========================================================================
    // MCP JSON-RPC 2.0 Dispatcher
    // =========================================================================

    pub async fn handle_jsonrpc(&self, raw_line: &str) -> Option<String> {
        let parsed: Value = match serde_json::from_str(raw_line) {
            Ok(v) => v,
            Err(_) => {
                return Some(Self::error_response(
                    Value::Null,
                    -32700,
                    "Parse error: invalid JSON",
                ));
            }
        };

        let id = parsed.get("id").cloned();
        let is_notification = id.is_none() || matches!(id, Some(Value::Null));
        let Some(method) = parsed.get("method").and_then(Value::as_str) else {
            return if is_notification {
                None
            } else {
                Some(Self::error_response(
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
                    return Some(Self::error_response(
                        req_id,
                        -32001,
                        "Charkle MCP service is disabled in Settings.",
                    ));
                }
                let protocol_version = params
                    .get("protocolVersion")
                    .and_then(Value::as_str)
                    .unwrap_or("2025-03-26");
                Some(Self::result_response(
                    req_id,
                    json!({
                        "protocolVersion": protocol_version,
                        "capabilities": {
                            "tools": { "listChanged": false },
                            "resources": { "subscribe": false, "listChanged": false }
                        },
                        "serverInfo": {
                            "name": "charkle",
                            "version": "1.0.1"
                        },
                        "instructions": "Charkle is a cross-platform visual reference library and moodboard studio. Use `library_overview` to inspect folders and tags, `search_assets` / `list_inbox` to find candidates, `render_contact_sheet` to visually inspect up to 16 numbered thumbnails in one image, `get_board_context` / `export_board_image` to inspect moodboards, and write tools (`organize_assets`, `create_folder`, `ingest_asset`, `compose_moodboard`, `patch_moodboard`, `trash_assets`) when write access is enabled in Charkle Settings."
                    }),
                ))
            }
            "notifications/initialized" | "notifications/cancelled" | "initialized" => None,
            "ping" => Some(Self::result_response(req_id, json!({}))),
            "tools/list" => {
                let policy = self.current_policy();
                if !policy.allows_read(ExternalAgentChannel::Mcp) {
                    return Some(Self::error_response(
                        req_id,
                        -32001,
                        "Charkle MCP service is disabled in Settings.",
                    ));
                }
                Some(Self::result_response(
                    req_id,
                    json!({ "tools": Self::mcp_tool_definitions() }),
                ))
            }
            "tools/call" => {
                let Some(name) = params.get("name").and_then(Value::as_str) else {
                    return Some(Self::error_response(
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
                Some(Self::result_response(
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
                    return Some(Self::error_response(
                        req_id,
                        -32001,
                        "Charkle MCP service is disabled in Settings.",
                    ));
                }
                Some(Self::result_response(
                    req_id,
                    json!({
                        "resources": [
                            {
                                "uri": "charkle://library/overview",
                                "name": "Charkle Library Overview",
                                "description": "Folders, top tags, media distribution, and counts for the local Charkle library.",
                                "mimeType": "application/json"
                            },
                            {
                                "uri": "charkle://boards",
                                "name": "Charkle Moodboards",
                                "description": "Summary list of all moodboards in Charkle.",
                                "mimeType": "application/json"
                            }
                        ]
                    }),
                ))
            }
            "resources/read" => {
                let policy = self.current_policy();
                if !policy.allows_read(ExternalAgentChannel::Mcp) {
                    return Some(Self::error_response(
                        req_id,
                        -32001,
                        "Charkle MCP service is disabled in Settings.",
                    ));
                }
                let Some(uri) = params.get("uri").and_then(Value::as_str) else {
                    return Some(Self::error_response(req_id, -32602, "Missing resource uri"));
                };
                let tool_name = match uri {
                    "charkle://library/overview" => "library_overview",
                    "charkle://boards" => "list_boards",
                    _ => {
                        return Some(Self::error_response(
                            req_id,
                            -32002,
                            &format!("Unknown resource URI: {uri}"),
                        ));
                    }
                };
                let out = self
                    .call_tool(tool_name, &json!({}), ExternalAgentChannel::Mcp)
                    .await;
                Some(Self::result_response(
                    req_id,
                    json!({
                        "contents": [{
                            "uri": uri,
                            "mimeType": "application/json",
                            "text": out.first_text()
                        }]
                    }),
                ))
            }
            _ => {
                if is_notification {
                    None
                } else {
                    Some(Self::error_response(
                        req_id,
                        -32601,
                        &format!("Method not found: {method}"),
                    ))
                }
            }
        }
    }

    // =========================================================================
    // Unified 14-Tool Router (MCP + CLI)
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
            "list_boards" => self.handle_list_boards(),
            "get_board_context" => self.handle_get_board_context(args),
            "export_board_image" => self.handle_export_board_image(args),
            "organize_assets" => self.handle_organize_assets(args),
            "create_folder" => self.handle_create_folder(args),
            "ingest_asset" => self.handle_ingest_asset(args).await,
            "compose_moodboard" => self.handle_compose_moodboard(args).await,
            "patch_moodboard" => self.handle_patch_moodboard(args),
            "trash_assets" => self.handle_trash_assets(args),
            _ => return ToolOutput::error(format!("Unknown Charkle tool: {name}")),
        };
        match res {
            Ok(out) => out,
            Err(err) => ToolOutput::error(format!("Tool {name} failed: {err}")),
        }
    }

    // --- 8 Read Tools ---

    fn handle_library_overview(
        &self,
        policy: &ExternalAgentConfig,
        channel: ExternalAgentChannel,
    ) -> CoreResult<ToolOutput> {
        let all_assets = self.engine.fetch_assets(&FilterCriteria::default())?;
        let folders = self.engine.fetch_folders()?;
        let folder_paths = build_folder_paths(&folders);
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
                    "assetCount": f.asset_count
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
            "boardCount": boards.len(),
            "mcpEnabled": policy.mcp_enabled,
            "cliEnabled": policy.cli_enabled,
            "accessLevel": serde_json::to_value(policy.access_level).unwrap_or(json!("readOnly")),
            "canWrite": policy.allows_write(channel),
            "mediaKindCounts": kind_counts,
            "folders": folder_items,
            "topTags": tag_items
        })))
    }

    fn handle_search_assets(&self, args: &Value) -> CoreResult<ToolOutput> {
        let folders = self.engine.fetch_folders()?;
        let folder_paths = build_folder_paths(&folders);
        let criteria = build_filter_criteria(args, &folders, &folder_paths)?;
        let limit = args
            .get("limit")
            .and_then(Value::as_u64)
            .unwrap_or(30)
            .clamp(1, 100) as usize;
        let matches = self.engine.fetch_assets(&criteria)?;
        let sliced: Vec<Value> = matches
            .iter()
            .take(limit)
            .map(|a| serialize_asset_summary(a, &folder_paths))
            .collect();
        Ok(ToolOutput::json(json!({
            "totalMatched": matches.len(),
            "returned": sliced.len(),
            "assets": sliced
        })))
    }

    fn handle_list_inbox(&self, args: &Value) -> CoreResult<ToolOutput> {
        let limit = args
            .get("limit")
            .and_then(Value::as_u64)
            .unwrap_or(40)
            .clamp(1, 100) as usize;
        let criteria = FilterCriteria {
            only_inbox: true,
            sort_by: SortOrder::Newest,
            ..Default::default()
        };
        let matches = self.engine.fetch_assets(&criteria)?;
        let empty = HashMap::new();
        let sliced: Vec<Value> = matches
            .iter()
            .take(limit)
            .map(|a| serialize_asset_summary(a, &empty))
            .collect();
        Ok(ToolOutput::json(json!({
            "inboxTotal": matches.len(),
            "returned": sliced.len(),
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
            .thumbnail_url(uuid, ThumbnailTier::Grid520)
            .map(|p| p.display().to_string())
            .unwrap_or_default();
        let orig_path = self
            .engine
            .media()
            .cached_original(&asset)
            .map(|p| p.display().to_string())
            .unwrap_or_default();
        if let Some(map) = obj.as_object_mut() {
            map.insert("ocrText".into(), json!(asset.ocr_text.unwrap_or_default()));
            map.insert("suggestedTags".into(), json!(asset.suggested_tags));
            map.insert(
                "sourceDomain".into(),
                json!(asset.source_domain.unwrap_or_default()),
            );
            map.insert("fileSizeBytes".into(), json!(asset.file_size_bytes));
            map.insert("pixelWidth".into(), json!(asset.pixel_width));
            map.insert("pixelHeight".into(), json!(asset.pixel_height));
            map.insert("thumbnailPath".into(), json!(thumb_path));
            map.insert("localOriginalPath".into(), json!(orig_path));
        }
        Ok(ToolOutput::json(obj))
    }

    fn handle_render_contact_sheet(&self, args: &Value) -> CoreResult<ToolOutput> {
        let ids = parse_uuid_list(args.get("asset_ids"));
        let mut assets = Vec::new();
        if !ids.is_empty() {
            for id in ids.into_iter().take(16) {
                if let Some(a) = self.engine.fetch_asset(id)? {
                    assets.push(a);
                }
            }
        } else {
            let folders = self.engine.fetch_folders()?;
            let folder_paths = build_folder_paths(&folders);
            let criteria = build_filter_criteria(args, &folders, &folder_paths)?;
            assets = self
                .engine
                .fetch_assets(&criteria)?
                .into_iter()
                .take(16)
                .collect();
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
        let meta_text = serde_json::to_string_pretty(&json!({
            "width": sheet.width,
            "height": sheet.height,
            "count": manifest.len(),
            "slots": manifest
        }))
        .unwrap_or_default();

        Ok(ToolOutput {
            content: vec![
                ToolContent::Text(meta_text),
                ToolContent::Image {
                    mime_type: "image/jpeg".to_string(),
                    data: sheet.jpeg_bytes,
                },
            ],
            is_error: false,
        })
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
                    "locked": n.is_locked
                }),
                BoardNodeKind::Note { title, text, .. } => json!({
                    "nodeID": format_swift_uuid(&n.id),
                    "kind": "note",
                    "title": title,
                    "text": text
                }),
                BoardNodeKind::GroupFrame { title, tint } => json!({
                    "nodeID": format_swift_uuid(&n.id),
                    "kind": "groupFrame",
                    "title": title,
                    "tint": serde_json::to_value(tint).unwrap_or(json!("neutral"))
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
            container_width: 1120.0,
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
        Ok(ToolOutput {
            content: vec![
                ToolContent::Text(meta),
                ToolContent::Image {
                    mime_type: mime.to_string(),
                    data: bytes,
                },
            ],
            is_error: false,
        })
    }

    // --- 6 Write Tools (NO permanent deletion allowed!) ---

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
            asset_ids: ids,
            title: args
                .get("title")
                .and_then(Value::as_str)
                .map(ToOwned::to_owned),
            notes: args
                .get("notes")
                .and_then(Value::as_str)
                .map(ToOwned::to_owned),
            folder_assignment,
            add_tags: string_array_arg(args.get("add_tags")),
            remove_tags: string_array_arg(args.get("remove_tags")),
            rating: args
                .get("rating")
                .and_then(Value::as_i64)
                .map(|r| r.clamp(0, 5) as i32),
            is_trashed: None,
            pinned_offline: args.get("pinned_offline").and_then(Value::as_bool),
            ..Default::default()
        };
        let updated = self.engine.update_assets(&patch)?;
        self.notify_write("assets");
        Ok(ToolOutput::json(json!({
            "updatedCount": updated.len(),
            "assetIDs": updated.iter().map(|a| format_swift_uuid(&a.id)).collect::<Vec<_>>()
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
        let parent_id = args
            .get("parent_id")
            .and_then(Value::as_str)
            .and_then(|s| Uuid::parse_str(s.trim()).ok());
        let folder = self.engine.create_folder(name, parent_id)?;
        self.notify_write("folders");
        Ok(ToolOutput::json(json!({
            "folderID": format_swift_uuid(&folder.id),
            "name": folder.name,
            "parentID": folder.parent_id.map(|id| format_swift_uuid(&id))
        })))
    }

    async fn handle_ingest_asset(&self, args: &Value) -> CoreResult<ToolOutput> {
        let folders = self.engine.fetch_folders()?;
        let folder_paths = build_folder_paths(&folders);
        let folder_id = resolve_optional_folder_id(args, &folders, &folder_paths)?;
        let input = if let Some(fp) = args
            .get("file_path")
            .and_then(Value::as_str)
            .map(str::trim)
            .filter(|s| !s.is_empty())
        {
            CaptureInput::FilePath(PathBuf::from(fp))
        } else if let Some(url) = args
            .get("url")
            .and_then(Value::as_str)
            .map(str::trim)
            .filter(|s| !s.is_empty())
        {
            CaptureInput::WebUrl {
                url: url.to_string(),
                title: args
                    .get("title")
                    .and_then(Value::as_str)
                    .map(ToOwned::to_owned),
                notes: args
                    .get("notes")
                    .and_then(Value::as_str)
                    .map(ToOwned::to_owned),
            }
        } else if let Some(hex) = args
            .get("color_hex")
            .and_then(Value::as_str)
            .map(str::trim)
            .filter(|s| !s.is_empty())
        {
            CaptureInput::ColorSwatch {
                hex: hex.to_string(),
                title: args
                    .get("title")
                    .and_then(Value::as_str)
                    .map(ToOwned::to_owned),
            }
        } else if let Some(text) = args
            .get("text")
            .and_then(Value::as_str)
            .map(str::trim)
            .filter(|s| !s.is_empty())
        {
            CaptureInput::TextSnippet {
                title: args
                    .get("title")
                    .and_then(Value::as_str)
                    .unwrap_or("灵感文本")
                    .to_string(),
                text: text.to_string(),
                source_url: None,
            }
        } else {
            return Ok(ToolOutput::error(
                "Provide one of `file_path`, `url`, `color_hex`, or `text` to ingest.",
            ));
        };
        let created = self.engine.ingest(vec![input], folder_id, None).await?;
        self.notify_write("assets");
        Ok(ToolOutput::json(json!({
            "ingestedCount": created.len(),
            "assets": created.iter().map(|a| json!({
                "id": format_swift_uuid(&a.id),
                "title": a.title,
                "mediaKind": a.media_kind
            })).collect::<Vec<_>>()
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
                d.nodes.push(BoardNode {
                    id: Uuid::new_v4(),
                    kind: BoardNodeKind::AssetRef {
                        asset_id: *aid,
                        crop: None,
                        weight: if idx < 2 { 2 } else { 1 },
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
                scope_folder_ids: scope_id.into_iter().collect(),
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
        let remove_set: HashSet<Uuid> = parse_uuid_list(args.get("remove_asset_ids"))
            .into_iter()
            .collect();
        if !remove_set.is_empty() {
            doc.nodes.retain(|n| {
                if n.is_locked {
                    return true;
                }
                n.referenced_asset_id()
                    .is_none_or(|id| !remove_set.contains(&id))
            });
        }
        let add_ids = parse_uuid_list(args.get("add_asset_ids"));
        if !add_ids.is_empty() {
            let existing: HashSet<Uuid> = doc.referenced_asset_ids().into_iter().collect();
            let mut next_z = doc.nodes.iter().map(|n| n.z_index).max().unwrap_or(0) + 1;
            let mut next_ord = doc
                .nodes
                .iter()
                .map(|n| n.editorial_order)
                .max()
                .unwrap_or(0)
                + 1;
            for aid in add_ids {
                if existing.contains(&aid) {
                    continue;
                }
                let Some(asset) = self.engine.fetch_asset(aid)? else {
                    continue;
                };
                let ratio = asset.aspect_ratio().clamp(0.6, 1.9);
                let idx = doc.nodes.len();
                doc.nodes.push(BoardNode {
                    id: Uuid::new_v4(),
                    kind: BoardNodeKind::AssetRef {
                        asset_id: aid,
                        crop: None,
                        weight: 1,
                        autoplay_loop: asset.media_kind == MediaKind::AnimatedImage,
                    },
                    frame: BoardRect::new(
                        ((idx % 4) as f64) * 260.0 + 40.0,
                        ((idx / 4) as f64) * 240.0 + 40.0,
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
                next_z += 1;
                next_ord += 1;
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
            let next_z = doc.nodes.iter().map(|n| n.z_index).max().unwrap_or(0) + 1;
            let next_ord = doc
                .nodes
                .iter()
                .map(|n| n.editorial_order)
                .max()
                .unwrap_or(0)
                + 1;
            doc.nodes.push(BoardNode {
                id: Uuid::new_v4(),
                kind: BoardNodeKind::Note {
                    title: Some(note_title.to_string()),
                    text: note_text.to_string(),
                    style: NoteStyle::Paper,
                    font_size: 13.5,
                },
                frame: BoardRect::new(40.0, 40.0, 320.0, 148.0),
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
    // Exact 14 MCP Tool Definitions
    // =========================================================================

    pub fn mcp_tool_definitions() -> Vec<Value> {
        vec![
            tool_def(
                "library_overview",
                "Inspect total assets, inbox count, boards, folder tree, top tags, and active external-agent permissions.",
                json!({ "type": "object", "properties": {} }),
            ),
            tool_def(
                "search_assets",
                "Search Charkle visual references by keywords, tags, color hex, folder, rating, or media kind.",
                json!({
                    "type": "object",
                    "properties": {
                        "query": { "type": "string" },
                        "tags": { "type": "array", "items": { "type": "string" } },
                        "color_hex": { "type": "string" },
                        "color_tolerance": { "type": "number" },
                        "folder_id": { "type": "string" },
                        "folder_path": { "type": "string" },
                        "min_rating": { "type": "integer" },
                        "only_inbox": { "type": "boolean" },
                        "only_untagged": { "type": "boolean" },
                        "limit": { "type": "integer" }
                    }
                }),
            ),
            tool_def(
                "list_inbox",
                "List newest untriaged assets currently waiting in the Charkle Inbox.",
                json!({ "type": "object", "properties": { "limit": { "type": "integer" } } }),
            ),
            tool_def(
                "get_asset",
                "Fetch full metadata, OCR text, tags, dimensions, and local paths for one asset UUID.",
                json!({
                    "type": "object",
                    "properties": { "asset_id": { "type": "string" } },
                    "required": ["asset_id"]
                }),
            ),
            tool_def(
                "render_contact_sheet",
                "Render up to 16 numbered asset thumbnails into a single visual contact-sheet JPEG image for multimodal inspection.",
                json!({
                    "type": "object",
                    "properties": {
                        "asset_ids": { "type": "array", "items": { "type": "string" } },
                        "query": { "type": "string" },
                        "columns": { "type": "integer" },
                        "output_path": { "type": "string" }
                    }
                }),
            ),
            tool_def(
                "list_boards",
                "List all moodboards with item counts, palettes, and offline pin status.",
                json!({ "type": "object", "properties": {} }),
            ),
            tool_def(
                "get_board_context",
                "Inspect nodes, notes, group frames, palette strips, connectors, and strokes of a moodboard.",
                json!({
                    "type": "object",
                    "properties": {
                        "board_id": { "type": "string" },
                        "title": { "type": "string" }
                    }
                }),
            ),
            tool_def(
                "export_board_image",
                "Render a moodboard to PNG/JPEG bytes (and optionally save to disk).",
                json!({
                    "type": "object",
                    "properties": {
                        "board_id": { "type": "string" },
                        "title": { "type": "string" },
                        "format": { "type": "string", "enum": ["png", "jpg"] },
                        "scale": { "type": "number" },
                        "output_path": { "type": "string" }
                    }
                }),
            ),
            tool_def(
                "organize_assets",
                "[Write] Move assets to a folder or Inbox, add/remove tags, update title/notes/rating.",
                json!({
                    "type": "object",
                    "properties": {
                        "asset_ids": { "type": "array", "items": { "type": "string" } },
                        "folder_id": { "type": "string" },
                        "folder_path": { "type": "string" },
                        "move_to_inbox": { "type": "boolean" },
                        "add_tags": { "type": "array", "items": { "type": "string" } },
                        "remove_tags": { "type": "array", "items": { "type": "string" } },
                        "rating": { "type": "integer" }
                    },
                    "required": ["asset_ids"]
                }),
            ),
            tool_def(
                "create_folder",
                "[Write] Create a new root or nested folder in the library.",
                json!({
                    "type": "object",
                    "properties": {
                        "name": { "type": "string" },
                        "parent_id": { "type": "string" }
                    },
                    "required": ["name"]
                }),
            ),
            tool_def(
                "ingest_asset",
                "[Write] Ingest a local file, URL, color hex swatch, or text snippet into Charkle.",
                json!({
                    "type": "object",
                    "properties": {
                        "file_path": { "type": "string" },
                        "url": { "type": "string" },
                        "color_hex": { "type": "string" },
                        "text": { "type": "string" },
                        "title": { "type": "string" },
                        "folder_id": { "type": "string" }
                    }
                }),
            ),
            tool_def(
                "compose_moodboard",
                "[Write] Create a curated moodboard from explicit `asset_ids` or automatic `prompt` curation.",
                json!({
                    "type": "object",
                    "properties": {
                        "title": { "type": "string" },
                        "subtitle": { "type": "string" },
                        "prompt": { "type": "string" },
                        "asset_ids": { "type": "array", "items": { "type": "string" } },
                        "layout_style": { "type": "string", "enum": ["magazine", "balanced", "compact"] },
                        "use_freeform": { "type": "boolean" },
                        "curator_note": { "type": "string" }
                    }
                }),
            ),
            tool_def(
                "patch_moodboard",
                "[Write] Update a moodboard title/subtitle, add/remove unlocked assets, or append a curator note.",
                json!({
                    "type": "object",
                    "properties": {
                        "board_id": { "type": "string" },
                        "title": { "type": "string" },
                        "new_title": { "type": "string" },
                        "add_asset_ids": { "type": "array", "items": { "type": "string" } },
                        "remove_asset_ids": { "type": "array", "items": { "type": "string" } },
                        "add_note": { "type": "string" }
                    }
                }),
            ),
            tool_def(
                "trash_assets",
                "[Write] Soft-move assets to Trash or restore them. Permanent deletion is strictly forbidden.",
                json!({
                    "type": "object",
                    "properties": {
                        "asset_ids": { "type": "array", "items": { "type": "string" } },
                        "trashed": { "type": "boolean" }
                    },
                    "required": ["asset_ids"]
                }),
            ),
        ]
    }

    fn result_response(id: Value, result: Value) -> String {
        serde_json::to_string(&json!({
            "jsonrpc": "2.0",
            "id": id,
            "result": result
        }))
        .unwrap_or_default()
    }

    fn error_response(id: Value, code: i32, message: &str) -> String {
        serde_json::to_string(&json!({
            "jsonrpc": "2.0",
            "id": id,
            "error": { "code": code, "message": message }
        }))
        .unwrap_or_default()
    }
}

fn tool_def(name: &str, description: &str, input_schema: Value) -> Value {
    json!({
        "name": name,
        "description": description,
        "inputSchema": input_schema
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
    let folder_id = if only_inbox {
        None
    } else {
        resolve_optional_folder_id(args, folders, folder_paths)?
    };
    Ok(FilterCriteria {
        search_query: query,
        selected_color_hex: color_hex,
        color_tolerance,
        min_rating,
        tags,
        folder_id,
        only_inbox,
        only_untagged,
        sort_by: SortOrder::Newest,
        ..Default::default()
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
    async fn enforces_independent_channel_switches_readonly_and_soft_trash_only_invariant() {
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

        // 1. Default policy: mcp=true, cli=true, accessLevel=readOnly
        let init_resp: Value = serde_json::from_str(
            &svc.handle_jsonrpc(r#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"#)
                .await
                .unwrap(),
        )
        .unwrap();
        assert_eq!(init_resp["result"]["serverInfo"]["name"], "charkle");

        let list_resp: Value = serde_json::from_str(
            &svc.handle_jsonrpc(r#"{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}"#)
                .await
                .unwrap(),
        )
        .unwrap();
        assert_eq!(list_resp["result"]["tools"].as_array().unwrap().len(), 14);

        let res_list: Value = serde_json::from_str(
            &svc.handle_jsonrpc(
                r#"{"jsonrpc":"2.0","id":3,"method":"resources/list","params":{}}"#,
            )
            .await
            .unwrap(),
        )
        .unwrap();
        assert_eq!(res_list["result"]["resources"].as_array().unwrap().len(), 2);

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

        // 3. CLI write tools work, pulse wake hook, and trash_assets NEVER permanently deletes
        let created_folder = svc
            .call_tool(
                "create_folder",
                &json!({ "name": "建筑参考" }),
                ExternalAgentChannel::Cli,
            )
            .await;
        assert!(!created_folder.is_error);
        let ingested = svc
            .call_tool(
                "ingest_asset",
                &json!({ "color_hex": "#2A60E0", "title": "Studio Cobalt" }),
                ExternalAgentChannel::Cli,
            )
            .await;
        assert!(!ingested.is_error);
        let ingested_val: Value = serde_json::from_str(&ingested.first_text()).unwrap();
        let asset_id_str = ingested_val["assets"][0]["id"]
            .as_str()
            .unwrap()
            .to_string();

        // Contact sheet renders real JPEG image payload
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

        // Compose moodboard + Soft trash
        let board = svc
            .call_tool(
                "compose_moodboard",
                &json!({ "title": "Agent Board", "asset_ids": [&asset_id_str] }),
                ExternalAgentChannel::Cli,
            )
            .await;
        assert!(!board.is_error);

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
        assert!(wake_hits.load(Ordering::SeqCst) >= 4);
    }
}
