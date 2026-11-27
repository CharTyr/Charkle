//! Local loopback HTTP bridge (`http://127.0.0.1:41937..=41946`) speaking the Charkle
//! `/api/v1/*` browser extension protocol so Chrome, Edge, Arc, and Brave extensions can
//! auto-pair and sync bookmarks/images/social posts directly into Charkle Windows with
//! zero idle CPU usage, strict extension-origin pairing enforcement, and constant-time
//! Bearer token verification.
//!
//! Mirrors `Sources/CharkleCore/Extension/LocalExtensionBridgeServer.swift`.

use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use base64::engine::general_purpose::STANDARD as BASE64_STD;
use base64::Engine;
use rand::RngCore;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::{watch, RwLock};
use tokio::task::JoinHandle;
use url::Url;
use uuid::Uuid;

use crate::engine::LiveCharkleEngine;
use crate::error::{CoreError, CoreResult};
use crate::media::eaglepack::StagingDirGuard;
use crate::media::resolvers::{
    canonical_dedup_key, SocialPostReference, SocialPostResolver, SocialPostURLParser,
    WebBookmarkResolver, XPostReference,
};
use crate::media::xiaohongshu::XiaohongshuPostResolver;
use crate::models::core::{
    AssetRecord, FilterCriteria, MediaKind, SocialMediaAttachment, SocialMediaAttachmentKind,
    SocialPlatform, SocialPostMetadata,
};
use crate::models::media::CaptureInput;
use crate::wire::swift_codec::format_swift_uuid;

pub const DEFAULT_EXTENSION_BRIDGE_PORT: u16 = 41937;
pub const FALLBACK_EXTENSION_BRIDGE_PORT_COUNT: u16 = 10;
const BRIDGE_CONFIG_FILE: &str = "extension-bridge.json";
const MAX_REQUEST_BODY_BYTES: usize = 48 * 1024 * 1024;
const MAX_HEADER_BYTES: usize = 64 * 1024;
const CONNECTION_IO_TIMEOUT: Duration = Duration::from_secs(30);
const MUTATION_DEBOUNCE_DELAY: Duration = Duration::from_millis(450);

/// Persisted browser extension bridge configuration stored in `<data_dir>/extension-bridge.json`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ExtensionBridgeConfig {
    #[serde(default = "default_true")]
    pub enabled: bool,
    #[serde(default = "default_true")]
    pub allow_local_auto_pair: bool,
    #[serde(default)]
    pub access_token: String,
}

fn default_true() -> bool {
    true
}

impl Default for ExtensionBridgeConfig {
    fn default() -> Self {
        Self {
            enabled: true,
            allow_local_auto_pair: true,
            access_token: Self::generate_token(),
        }
    }
}

impl ExtensionBridgeConfig {
    /// Generates a cryptographically random 48-character lowercase hex access token (24 bytes).
    pub fn generate_token() -> String {
        let mut bytes = [0u8; 24];
        rand::rngs::OsRng.fill_bytes(&mut bytes);
        hex::encode(bytes)
    }

    /// Loads `<data_dir>/extension-bridge.json`, creating and persisting defaults if absent or empty.
    pub fn load_or_create(data_dir: &Path) -> Self {
        let path = data_dir.join(BRIDGE_CONFIG_FILE);
        if let Ok(raw) = std::fs::read(&path) {
            if let Ok(mut cfg) = serde_json::from_slice::<Self>(&raw) {
                if !cfg.access_token.trim().is_empty() {
                    cfg.access_token = cfg.access_token.trim().to_string();
                    return cfg;
                }
                cfg.access_token = Self::generate_token();
                let _ = cfg.save(data_dir);
                return cfg;
            }
        }
        let cfg = Self::default();
        let _ = cfg.save(data_dir);
        cfg
    }

    /// Atomically persists `<data_dir>/extension-bridge.json`.
    pub fn save(&self, data_dir: &Path) -> CoreResult<()> {
        std::fs::create_dir_all(data_dir)?;
        let path = data_dir.join(BRIDGE_CONFIG_FILE);
        let tmp = data_dir.join(format!("{BRIDGE_CONFIG_FILE}.tmp"));
        let bytes = serde_json::to_vec_pretty(self)?;
        std::fs::write(&tmp, bytes)?;
        if std::fs::rename(&tmp, &path).is_err() {
            if path.exists() {
                let _ = std::fs::remove_file(&path);
            }
            std::fs::rename(&tmp, &path)?;
        }
        Ok(())
    }
}

/// Coalesced debounced mutation notification emitted to the desktop shell after extension imports.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ExtensionBridgeMutation {
    pub imported_count: usize,
    pub folder_created_count: usize,
    pub target_folder_id: Option<Uuid>,
    pub target_board_id: Option<Uuid>,
}

/// Live runtime status snapshot of the local browser extension bridge.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ExtensionBridgeStatus {
    pub enabled: bool,
    pub running: bool,
    pub port: u16,
    pub base_url: String,
    pub allow_local_auto_pair: bool,
    pub access_token: String,
    pub last_error: Option<String>,
}

type MutationCallback = Arc<dyn Fn(ExtensionBridgeMutation) + Send + Sync>;

#[derive(Default)]
struct PendingMutationBatch {
    imported_count: usize,
    folder_created_count: usize,
    target_folder_id: Option<Uuid>,
    target_board_id: Option<Uuid>,
    generation: u64,
}

struct BridgeRuntimeState {
    config: ExtensionBridgeConfig,
    running: bool,
    bound_port: u16,
    last_error: Option<String>,
    shutdown_tx: Option<watch::Sender<bool>>,
    accept_task: Option<JoinHandle<()>>,
}

/// Pure-Tokio loopback HTTP/1.1 bridge server (`127.0.0.1:41937..=41946`).
pub struct LocalExtensionBridgeServer {
    engine: Arc<LiveCharkleEngine>,
    data_dir: PathBuf,
    preferred_port: u16,
    allow_ephemeral_port: bool,
    state: Arc<RwLock<BridgeRuntimeState>>,
    pending_mutations: Arc<Mutex<PendingMutationBatch>>,
    on_mutated: Option<MutationCallback>,
}

impl LocalExtensionBridgeServer {
    /// Creates a bridge configured from `<data_dir>/extension-bridge.json` targeting `127.0.0.1:41937..=41946`.
    pub fn new(
        engine: Arc<LiveCharkleEngine>,
        data_dir: PathBuf,
        on_mutated: Option<MutationCallback>,
    ) -> Self {
        let config = ExtensionBridgeConfig::load_or_create(&data_dir);
        Self::with_options(
            engine,
            data_dir,
            config,
            DEFAULT_EXTENSION_BRIDGE_PORT,
            false,
            on_mutated,
        )
    }

    /// Creates a bridge with explicit config and port options (pass `preferred_port = 0`,
    /// `allow_ephemeral_port = true` for isolated parallel loopback tests).
    pub fn with_options(
        engine: Arc<LiveCharkleEngine>,
        data_dir: PathBuf,
        config: ExtensionBridgeConfig,
        preferred_port: u16,
        allow_ephemeral_port: bool,
        on_mutated: Option<MutationCallback>,
    ) -> Self {
        Self {
            engine,
            data_dir,
            preferred_port,
            allow_ephemeral_port,
            state: Arc::new(RwLock::new(BridgeRuntimeState {
                config,
                running: false,
                bound_port: 0,
                last_error: None,
                shutdown_tx: None,
                accept_task: None,
            })),
            pending_mutations: Arc::new(Mutex::new(PendingMutationBatch::default())),
            on_mutated,
        }
    }

    /// Returns the current live bridge status snapshot.
    pub async fn status(&self) -> ExtensionBridgeStatus {
        let guard = self.state.read().await;
        Self::snapshot_from_guard(&guard)
    }

    /// Starts the loopback TCP listener if not already running.
    pub async fn start(&self) -> CoreResult<ExtensionBridgeStatus> {
        {
            let guard = self.state.read().await;
            if guard.running && guard.bound_port > 0 {
                return Ok(Self::snapshot_from_guard(&guard));
            }
        }

        let candidate_ports: Vec<u16> = if self.allow_ephemeral_port && self.preferred_port == 0 {
            vec![0]
        } else {
            let start = if self.preferred_port == 0 {
                DEFAULT_EXTENSION_BRIDGE_PORT
            } else {
                self.preferred_port
            };
            (0..FALLBACK_EXTENSION_BRIDGE_PORT_COUNT)
                .map(|offset| start.saturating_add(offset))
                .collect()
        };

        let mut bound: Option<(TcpListener, u16)> = None;
        let mut last_err: Option<std::io::Error> = None;
        for port in candidate_ports {
            match TcpListener::bind(("127.0.0.1", port)).await {
                Ok(listener) => {
                    let actual = listener.local_addr().map(|a| a.port()).unwrap_or(port);
                    bound = Some((listener, actual));
                    break;
                }
                Err(err) => {
                    last_err = Some(err);
                }
            }
        }

        let Some((listener, actual_port)) = bound else {
            let msg = last_err
                .map(|e| format!("无法在 127.0.0.1 绑定本地扩展桥接端口：{e}"))
                .unwrap_or_else(|| "无法在 127.0.0.1 绑定本地扩展桥接端口。".to_string());
            let mut guard = self.state.write().await;
            guard.running = false;
            guard.bound_port = 0;
            guard.last_error = Some(msg.clone());
            return Err(CoreError::InvalidOperation(msg));
        };

        let (shutdown_tx, mut shutdown_rx) = watch::channel(false);
        let engine = Arc::clone(&self.engine);
        let shared_state = Arc::clone(&self.state);
        let pending_mutations = Arc::clone(&self.pending_mutations);
        let on_mutated = self.on_mutated.clone();

        let accept_task = tokio::spawn(async move {
            loop {
                tokio::select! {
                    biased;
                    changed = shutdown_rx.changed() => {
                        if changed.is_err() || *shutdown_rx.borrow() {
                            break;
                        }
                    }
                    accepted = listener.accept() => {
                        match accepted {
                            Ok((stream, _peer)) => {
                                let eng = Arc::clone(&engine);
                                let st = Arc::clone(&shared_state);
                                let pm = Arc::clone(&pending_mutations);
                                let cb = on_mutated.clone();
                                tokio::spawn(async move {
                                    handle_connection(stream, eng, st, pm, cb).await;
                                });
                            }
                            Err(err) => {
                                tracing::warn!(%err, "Extension bridge accept error");
                                tokio::time::sleep(Duration::from_millis(50)).await;
                            }
                        }
                    }
                }
            }
        });

        let mut guard = self.state.write().await;
        guard.running = true;
        guard.bound_port = actual_port;
        guard.last_error = None;
        guard.shutdown_tx = Some(shutdown_tx);
        guard.accept_task = Some(accept_task);
        Ok(Self::snapshot_from_guard(&guard))
    }

    /// Stops the loopback listener cleanly.
    pub async fn stop(&self) -> ExtensionBridgeStatus {
        let (tx, handle) = {
            let mut guard = self.state.write().await;
            guard.running = false;
            guard.bound_port = 0;
            (guard.shutdown_tx.take(), guard.accept_task.take())
        };
        if let Some(tx) = tx {
            let _ = tx.send(true);
        }
        if let Some(handle) = handle {
            let _ = tokio::time::timeout(Duration::from_secs(2), handle).await;
        }
        self.status().await
    }

    /// Enables or disables the bridge, persisting config and starting/stopping the listener.
    pub async fn set_enabled(&self, enabled: bool) -> CoreResult<ExtensionBridgeStatus> {
        {
            let mut guard = self.state.write().await;
            guard.config.enabled = enabled;
            guard.config.save(&self.data_dir)?;
            if !enabled {
                guard.last_error = None;
            }
        }
        if enabled {
            self.start().await
        } else {
            Ok(self.stop().await)
        }
    }

    /// Enables or disables zero-config same-machine browser-extension auto-pairing.
    pub async fn set_auto_pair(
        &self,
        allow_local_auto_pair: bool,
    ) -> CoreResult<ExtensionBridgeStatus> {
        let mut guard = self.state.write().await;
        guard.config.allow_local_auto_pair = allow_local_auto_pair;
        guard.config.save(&self.data_dir)?;
        Ok(Self::snapshot_from_guard(&guard))
    }

    /// Rotates the 48-hex bridge access token immediately and persists it.
    pub async fn regenerate_token(&self) -> CoreResult<ExtensionBridgeStatus> {
        let mut guard = self.state.write().await;
        guard.config.access_token = ExtensionBridgeConfig::generate_token();
        guard.config.save(&self.data_dir)?;
        Ok(Self::snapshot_from_guard(&guard))
    }

    fn snapshot_from_guard(guard: &BridgeRuntimeState) -> ExtensionBridgeStatus {
        let base_url = if guard.bound_port > 0 {
            format!("http://127.0.0.1:{}", guard.bound_port)
        } else {
            format!("http://127.0.0.1:{DEFAULT_EXTENSION_BRIDGE_PORT}")
        };
        ExtensionBridgeStatus {
            enabled: guard.config.enabled,
            running: guard.running && guard.bound_port > 0,
            port: guard.bound_port,
            base_url,
            allow_local_auto_pair: guard.config.allow_local_auto_pair,
            access_token: guard.config.access_token.clone(),
            last_error: guard.last_error.clone(),
        }
    }
}

impl Drop for LocalExtensionBridgeServer {
    fn drop(&mut self) {
        if let Ok(mut guard) = self.state.try_write() {
            if let Some(tx) = guard.shutdown_tx.take() {
                let _ = tx.send(true);
            }
            if let Some(handle) = guard.accept_task.take() {
                handle.abort();
            }
        }
    }
}

// =============================================================================
// Debounced Mutation Coalescing (~450ms)
// =============================================================================

fn schedule_debounced_mutation(
    pending: &Arc<Mutex<PendingMutationBatch>>,
    callback: &Option<MutationCallback>,
    imported_delta: usize,
    folder_delta: usize,
    target_folder_id: Option<Uuid>,
    target_board_id: Option<Uuid>,
) {
    let Some(cb) = callback.clone() else {
        return;
    };
    let generation = {
        let Ok(mut batch) = pending.lock() else {
            return;
        };
        batch.imported_count = batch.imported_count.saturating_add(imported_delta);
        batch.folder_created_count = batch.folder_created_count.saturating_add(folder_delta);
        if target_folder_id.is_some() {
            batch.target_folder_id = target_folder_id;
        }
        if target_board_id.is_some() {
            batch.target_board_id = target_board_id;
        }
        batch.generation = batch.generation.wrapping_add(1);
        batch.generation
    };

    let pending_clone = Arc::clone(pending);
    tokio::spawn(async move {
        tokio::time::sleep(MUTATION_DEBOUNCE_DELAY).await;
        let drained = {
            let Ok(mut batch) = pending_clone.lock() else {
                return;
            };
            if batch.generation != generation {
                return;
            }
            let out = ExtensionBridgeMutation {
                imported_count: batch.imported_count,
                folder_created_count: batch.folder_created_count,
                target_folder_id: batch.target_folder_id,
                target_board_id: batch.target_board_id,
            };
            batch.imported_count = 0;
            batch.folder_created_count = 0;
            batch.target_folder_id = None;
            batch.target_board_id = None;
            out
        };
        if drained.imported_count > 0 || drained.folder_created_count > 0 {
            cb(drained);
        }
    });
}

// =============================================================================
// HTTP/1.1 Wire Parser & Router
// =============================================================================

struct HttpRequest {
    method: String,
    raw_target: String,
    headers: HashMap<String, String>,
    body: Vec<u8>,
}

impl HttpRequest {
    fn path_without_query(&self) -> &str {
        self.raw_target
            .split_once('?')
            .map(|(p, _)| p)
            .unwrap_or(&self.raw_target)
    }

    fn header(&self, name: &str) -> Option<&str> {
        self.headers
            .get(&name.to_ascii_lowercase())
            .map(String::as_str)
    }
}

struct HttpResponse {
    status: u16,
    headers: Vec<(String, String)>,
    body: Vec<u8>,
}

impl HttpResponse {
    fn json(status: u16, extra_headers: Vec<(String, String)>, body: Value) -> Self {
        let mut headers = extra_headers;
        headers.push((
            "Content-Type".to_string(),
            "application/json; charset=utf-8".to_string(),
        ));
        let bytes = serde_json::to_vec(&body).unwrap_or_else(|_| b"{}".to_vec());
        Self {
            status,
            headers,
            body: bytes,
        }
    }

    fn serialize(&self) -> Vec<u8> {
        let reason = match self.status {
            200 => "OK",
            201 => "Created",
            204 => "No Content",
            400 => "Bad Request",
            401 => "Unauthorized",
            403 => "Forbidden",
            404 => "Not Found",
            409 => "Conflict",
            413 => "Payload Too Large",
            503 => "Service Unavailable",
            _ => "Internal Server Error",
        };
        let mut head = format!(
            "HTTP/1.1 {} {}\r\nContent-Length: {}\r\nConnection: close\r\n",
            self.status,
            reason,
            self.body.len()
        );
        for (k, v) in &self.headers {
            head.push_str(k);
            head.push_str(": ");
            head.push_str(v);
            head.push_str("\r\n");
        }
        head.push_str("\r\n");
        let mut out = head.into_bytes();
        out.extend_from_slice(&self.body);
        out
    }
}

enum ParseError {
    BadRequest(&'static str),
    PayloadTooLarge,
    Eof,
}

async fn handle_connection(
    mut stream: TcpStream,
    engine: Arc<LiveCharkleEngine>,
    state: Arc<RwLock<BridgeRuntimeState>>,
    pending_mutations: Arc<Mutex<PendingMutationBatch>>,
    on_mutated: Option<MutationCallback>,
) {
    let response = match tokio::time::timeout(CONNECTION_IO_TIMEOUT, read_http_request(&mut stream))
        .await
    {
        Ok(Ok(req)) => route_request(req, &engine, &state, &pending_mutations, &on_mutated).await,
        Ok(Err(ParseError::PayloadTooLarge)) => HttpResponse::json(
            413,
            build_cors_headers(None, true),
            json!({ "error": "请求体积超出上限（最大 48 MB）。", "code": "PAYLOAD_TOO_LARGE" }),
        ),
        Ok(Err(ParseError::BadRequest(msg))) => HttpResponse::json(
            400,
            build_cors_headers(None, true),
            json!({ "error": msg, "code": "BAD_REQUEST" }),
        ),
        Ok(Err(ParseError::Eof)) | Err(_) => return,
    };

    let bytes = response.serialize();
    let _ = tokio::time::timeout(Duration::from_secs(10), async {
        let _ = stream.write_all(&bytes).await;
        let _ = stream.flush().await;
        let _ = stream.shutdown().await;
    })
    .await;
}

async fn read_http_request(stream: &mut TcpStream) -> Result<HttpRequest, ParseError> {
    let mut buf = Vec::with_capacity(4096);
    let mut tmp = [0u8; 8192];

    let header_end = loop {
        if let Some(pos) = find_bytes(&buf, b"\r\n\r\n") {
            break pos + 4;
        }
        if buf.len() > MAX_HEADER_BYTES {
            return Err(ParseError::BadRequest("请求头过长。"));
        }
        let n = stream.read(&mut tmp).await.map_err(|_| ParseError::Eof)?;
        if n == 0 {
            return Err(ParseError::Eof);
        }
        buf.extend_from_slice(&tmp[..n]);
    };

    let header_text = String::from_utf8_lossy(&buf[..header_end - 4]);
    let mut lines = header_text.split("\r\n");
    let request_line = lines.next().ok_or(ParseError::BadRequest("无效请求。"))?;
    let mut parts = request_line.split_whitespace();
    let method = parts
        .next()
        .ok_or(ParseError::BadRequest("无效请求行。"))?
        .to_ascii_uppercase();
    let raw_target = parts
        .next()
        .ok_or(ParseError::BadRequest("无效请求目标。"))?
        .to_string();

    let mut headers = HashMap::new();
    for line in lines {
        if let Some((k, v)) = line.split_once(':') {
            let key = k.trim().to_ascii_lowercase();
            let val = v.trim().to_string();
            if !key.is_empty() {
                headers.insert(key, val);
            }
        }
    }

    let is_chunked = headers
        .get("transfer-encoding")
        .is_some_and(|v| v.to_ascii_lowercase().contains("chunked"));

    let mut body = Vec::new();
    let already_read = buf[header_end..].to_vec();

    if is_chunked {
        let mut raw_stream = already_read;
        loop {
            while find_bytes(&raw_stream, b"\r\n").is_none() {
                let n = stream.read(&mut tmp).await.map_err(|_| ParseError::Eof)?;
                if n == 0 {
                    return Err(ParseError::BadRequest("分块请求体未完整结束。"));
                }
                raw_stream.extend_from_slice(&tmp[..n]);
                if raw_stream.len() > MAX_REQUEST_BODY_BYTES + 65_536 {
                    return Err(ParseError::PayloadTooLarge);
                }
            }
            let line_end = find_bytes(&raw_stream, b"\r\n").unwrap_or(0);
            let size_line = String::from_utf8_lossy(&raw_stream[..line_end]);
            let hex_part = size_line.split(';').next().unwrap_or("").trim();
            let chunk_len = usize::from_str_radix(hex_part, 16)
                .map_err(|_| ParseError::BadRequest("无效的分块长度。"))?;
            raw_stream.drain(..line_end + 2);
            if chunk_len == 0 {
                break;
            }
            if body.len().saturating_add(chunk_len) > MAX_REQUEST_BODY_BYTES {
                return Err(ParseError::PayloadTooLarge);
            }
            while raw_stream.len() < chunk_len + 2 {
                let n = stream.read(&mut tmp).await.map_err(|_| ParseError::Eof)?;
                if n == 0 {
                    return Err(ParseError::BadRequest("分块内容截断。"));
                }
                raw_stream.extend_from_slice(&tmp[..n]);
            }
            body.extend_from_slice(&raw_stream[..chunk_len]);
            raw_stream.drain(..chunk_len + 2);
        }
    } else if let Some(cl_raw) = headers.get("content-length") {
        let expected = cl_raw
            .trim()
            .parse::<usize>()
            .map_err(|_| ParseError::BadRequest("无效的 Content-Length。"))?;
        if expected > MAX_REQUEST_BODY_BYTES {
            return Err(ParseError::PayloadTooLarge);
        }
        body.reserve(expected.min(1024 * 1024));
        let take_init = already_read.len().min(expected);
        body.extend_from_slice(&already_read[..take_init]);
        while body.len() < expected {
            let remaining = expected - body.len();
            let to_read = remaining.min(tmp.len());
            let n = stream
                .read(&mut tmp[..to_read])
                .await
                .map_err(|_| ParseError::Eof)?;
            if n == 0 {
                return Err(ParseError::BadRequest("请求体提前结束。"));
            }
            body.extend_from_slice(&tmp[..n]);
        }
    }

    Ok(HttpRequest {
        method,
        raw_target,
        headers,
        body,
    })
}

async fn route_request(
    req: HttpRequest,
    engine: &Arc<LiveCharkleEngine>,
    state: &Arc<RwLock<BridgeRuntimeState>>,
    pending_mutations: &Arc<Mutex<PendingMutationBatch>>,
    on_mutated: &Option<MutationCallback>,
) -> HttpResponse {
    let path = req.path_without_query().to_string();
    let origin = req.header("origin");
    let is_local_pair = path == "/api/v1/auth/local-pair";
    // Security red line: `/api/v1/auth/local-pair` ONLY ever echoes CORS Allow-Origin
    // for browser-extension origins (`chrome-extension://`, `safari-web-extension://`,
    // `moz-extension://`) on BOTH OPTIONS preflight and POST responses.
    let cors_headers = build_cors_headers(origin, is_local_pair);

    if req.method == "OPTIONS" {
        return HttpResponse {
            status: 204,
            headers: cors_headers,
            body: Vec::new(),
        };
    }

    let (bound_port, allow_auto_pair, token) = {
        let guard = state.read().await;
        (
            guard.bound_port,
            guard.config.allow_local_auto_pair,
            guard.config.access_token.clone(),
        )
    };

    // 1. Public liveness probe (NEVER exposes token or library contents)
    if req.method == "GET" && path == "/api/v1/health" {
        return HttpResponse::json(
            200,
            cors_headers,
            json!({
                "ok": true,
                "app": "charkle-windows",
                "name": "Charkle Windows",
                "version": env!("CARGO_PKG_VERSION"),
                "port": bound_port,
                "autoPair": allow_auto_pair,
            }),
        );
    }

    // 2. Strictly gated same-machine browser-extension auto-pairing
    if req.method == "POST" && is_local_pair {
        return handle_local_auto_pair(&req, cors_headers, bound_port, allow_auto_pair, &token);
    }

    let is_authorized = validate_bearer_token(req.header("authorization"), &token);

    // 3. Auth status probe (returns 200 with authenticated: true/false matching macOS & Web)
    if req.method == "GET" && path == "/api/v1/auth/status" {
        if is_authorized {
            return HttpResponse::json(
                200,
                cors_headers,
                json!({
                    "initialized": true,
                    "authenticated": true,
                    "app": "charkle-windows",
                    "user": {
                        "id": "local-windows",
                        "username": "desktop",
                        "displayName": "Charkle Windows",
                        "role": "owner",
                    },
                    "sessionCount": 1,
                }),
            );
        }
        return HttpResponse::json(
            200,
            cors_headers,
            json!({
                "initialized": true,
                "authenticated": false,
                "app": "charkle-windows",
                "user": Value::Null,
                "sessionCount": 0,
            }),
        );
    }

    // 4. All remaining routes require valid Bearer token
    if !is_authorized {
        return HttpResponse::json(
            401,
            cors_headers,
            json!({
                "error": "访问令牌无效或已更新，请在 Charkle 桌面端「设置 → 插件与扩展」重新复制。",
                "code": "UNAUTHORIZED",
            }),
        );
    }

    match (req.method.as_str(), path.as_str()) {
        ("GET", "/api/v1/folders") => handle_get_folders(engine, cors_headers),
        ("POST", "/api/v1/folders") => {
            handle_create_folder(&req, engine, cors_headers, pending_mutations, on_mutated)
        }
        ("GET", "/api/v1/boards") => handle_get_boards(engine, cors_headers),
        ("GET", "/api/v1/assets/existing-sources") => {
            handle_get_existing_sources(engine, cors_headers)
        }
        ("POST", "/api/v1/assets/ingest") => {
            handle_ingest(&req, engine, cors_headers, pending_mutations, on_mutated).await
        }
        ("POST", "/api/v1/assets/upload") => {
            handle_multipart_upload(&req, engine, cors_headers, pending_mutations, on_mutated).await
        }
        _ => HttpResponse::json(
            404,
            cors_headers,
            json!({ "error": "接口不存在。", "code": "NOT_FOUND" }),
        ),
    }
}

// =============================================================================
// Route Handlers
// =============================================================================

fn handle_local_auto_pair(
    req: &HttpRequest,
    cors_headers: Vec<(String, String)>,
    bound_port: u16,
    allow_local_auto_pair: bool,
    token: &str,
) -> HttpResponse {
    if !allow_local_auto_pair {
        return HttpResponse::json(
            403,
            cors_headers,
            json!({
                "error": "已在 Charkle 设置中关闭同机自动配对，请开启或手动粘贴访问令牌。",
                "code": "AUTO_PAIR_DISABLED",
            }),
        );
    }

    let origin = req.header("origin");
    if !is_browser_extension_origin(origin) {
        let strict_headers: Vec<(String, String)> = cors_headers
            .into_iter()
            .filter(|(k, _)| !k.eq_ignore_ascii_case("Access-Control-Allow-Origin"))
            .collect();
        return HttpResponse::json(
            403,
            strict_headers,
            json!({
                "error": "仅允许本机已安装的浏览器扩展自动配对。",
                "code": "INVALID_ORIGIN",
            }),
        );
    }

    let ext_marker = req.header("x-charkle-extension").unwrap_or("").trim();
    if ext_marker != "1" {
        return HttpResponse::json(
            403,
            cors_headers,
            json!({
                "error": "缺少扩展握手标识头。",
                "code": "MISSING_EXTENSION_HEADER",
            }),
        );
    }

    HttpResponse::json(
        200,
        cors_headers,
        json!({
            "ok": true,
            "app": "charkle-windows",
            "name": "Charkle Windows",
            "port": bound_port,
            "serverUrl": format!("http://127.0.0.1:{bound_port}"),
            "token": token,
        }),
    )
}

fn handle_get_folders(
    engine: &LiveCharkleEngine,
    cors_headers: Vec<(String, String)>,
) -> HttpResponse {
    let folders = match engine.fetch_folders() {
        Ok(f) => f,
        Err(err) => {
            return HttpResponse::json(
                500,
                cors_headers,
                json!({ "error": err.to_string(), "code": "INTERNAL_ERROR" }),
            );
        }
    };
    let assets = engine
        .fetch_assets(&FilterCriteria::default())
        .unwrap_or_default();
    let mut counts: HashMap<Uuid, usize> = HashMap::new();
    for asset in assets {
        if let Some(fid) = asset.folder_id {
            *counts.entry(fid).or_insert(0) += 1;
        }
    }
    let serialized: Vec<Value> = folders
        .into_iter()
        .map(|f| {
            json!({
                "id": format_swift_uuid(&f.id),
                "name": f.name,
                "parentID": f.parent_id.map(|p| format_swift_uuid(&p)),
                "sortOrder": f.sort_order,
                "assetCount": counts.get(&f.id).copied().unwrap_or(0),
            })
        })
        .collect();
    HttpResponse::json(200, cors_headers, json!({ "folders": serialized }))
}

fn handle_create_folder(
    req: &HttpRequest,
    engine: &LiveCharkleEngine,
    cors_headers: Vec<(String, String)>,
    pending_mutations: &Arc<Mutex<PendingMutationBatch>>,
    on_mutated: &Option<MutationCallback>,
) -> HttpResponse {
    let Ok(Value::Object(obj)) = serde_json::from_slice::<Value>(&req.body) else {
        return HttpResponse::json(
            400,
            cors_headers,
            json!({ "error": "请求内容格式不正确。", "code": "INVALID_JSON" }),
        );
    };
    let raw_name = obj
        .get("name")
        .and_then(Value::as_str)
        .map(str::trim)
        .unwrap_or("");
    if raw_name.is_empty() {
        return HttpResponse::json(
            400,
            cors_headers,
            json!({ "error": "请填写文件夹名称。", "code": "INVALID_NAME" }),
        );
    }
    let parent_id = obj
        .get("parentID")
        .and_then(Value::as_str)
        .and_then(|s| Uuid::parse_str(s.trim()).ok());
    let reuse_existing = obj
        .get("reuseExisting")
        .and_then(Value::as_bool)
        .unwrap_or(true);

    if reuse_existing {
        if let Ok(existing) = engine.fetch_folders() {
            if let Some(matched) = existing
                .into_iter()
                .find(|f| f.parent_id == parent_id && f.name.trim().eq_ignore_ascii_case(raw_name))
            {
                return HttpResponse::json(
                    200,
                    cors_headers,
                    json!({
                        "folder": {
                            "id": format_swift_uuid(&matched.id),
                            "name": matched.name,
                            "parentID": matched.parent_id.map(|p| format_swift_uuid(&p)),
                            "sortOrder": matched.sort_order,
                            "assetCount": matched.asset_count,
                        },
                        "reused": true,
                        "created": false,
                    }),
                );
            }
        }
    }

    match engine.create_folder(raw_name, parent_id) {
        Ok(created) => {
            schedule_debounced_mutation(
                pending_mutations,
                on_mutated,
                0,
                1,
                Some(created.id),
                None,
            );
            HttpResponse::json(
                201,
                cors_headers,
                json!({
                    "folder": {
                        "id": format_swift_uuid(&created.id),
                        "name": created.name,
                        "parentID": created.parent_id.map(|p| format_swift_uuid(&p)),
                        "sortOrder": created.sort_order,
                        "assetCount": 0,
                    },
                    "reused": false,
                    "created": true,
                }),
            )
        }
        Err(CoreError::AlreadyExists(msg)) => HttpResponse::json(
            409,
            cors_headers,
            json!({ "error": msg, "code": "ALREADY_EXISTS" }),
        ),
        Err(err) => HttpResponse::json(
            500,
            cors_headers,
            json!({ "error": err.to_string(), "code": "INTERNAL_ERROR" }),
        ),
    }
}

fn handle_get_boards(
    engine: &LiveCharkleEngine,
    cors_headers: Vec<(String, String)>,
) -> HttpResponse {
    match engine.fetch_boards() {
        Ok(boards) => {
            let serialized: Vec<Value> = boards
                .into_iter()
                .map(|b| {
                    json!({
                        "id": format_swift_uuid(&b.id),
                        "title": b.title,
                        "itemCount": b.item_count,
                    })
                })
                .collect();
            HttpResponse::json(200, cors_headers, json!({ "boards": serialized }))
        }
        Err(err) => HttpResponse::json(
            500,
            cors_headers,
            json!({ "error": err.to_string(), "code": "INTERNAL_ERROR" }),
        ),
    }
}

fn fetch_existing_source_keys(
    engine: &LiveCharkleEngine,
) -> CoreResult<(HashSet<String>, HashSet<String>, HashSet<String>)> {
    let assets = engine.fetch_assets(&FilterCriteria::default())?;
    let mut sources = HashSet::new();
    let mut keys = HashSet::new();
    let mut media_keys = HashSet::new();
    for asset in assets {
        let is_real_media = matches!(
            asset.media_kind,
            MediaKind::Image | MediaKind::AnimatedImage | MediaKind::Video
        );
        if let Some(src) = asset
            .source_url
            .as_deref()
            .map(str::trim)
            .filter(|s| !s.is_empty())
        {
            sources.insert(src.to_string());
            if let Some(k) = canonical_dedup_key(src) {
                if is_real_media {
                    media_keys.insert(k.clone());
                }
                keys.insert(k);
            }
        }
        if let Some(orig) = asset
            .rich_metadata
            .as_ref()
            .and_then(|r| r.social_post.as_ref())
            .map(|p| p.original_url.trim())
            .filter(|s| !s.is_empty())
        {
            sources.insert(orig.to_string());
            if let Some(k) = canonical_dedup_key(orig) {
                if is_real_media {
                    media_keys.insert(k.clone());
                }
                keys.insert(k);
            }
        }
    }
    Ok((sources, keys, media_keys))
}

fn handle_get_existing_sources(
    engine: &LiveCharkleEngine,
    cors_headers: Vec<(String, String)>,
) -> HttpResponse {
    match fetch_existing_source_keys(engine) {
        Ok((sources, keys, media_keys)) => {
            let mut source_list: Vec<String> = sources.into_iter().collect();
            let mut key_list: Vec<String> = keys.into_iter().collect();
            let mut media_key_list: Vec<String> = media_keys.into_iter().collect();
            source_list.sort();
            key_list.sort();
            media_key_list.sort();
            HttpResponse::json(
                200,
                cors_headers,
                json!({
                    "count": key_list.len(),
                    "sources": source_list,
                    "canonicalKeys": key_list,
                    "mediaCanonicalKeys": media_key_list,
                }),
            )
        }
        Err(err) => HttpResponse::json(
            500,
            cors_headers,
            json!({ "error": err.to_string(), "code": "INTERNAL_ERROR" }),
        ),
    }
}

#[derive(Debug, Clone)]
struct SocialMediaBatchItem {
    kind: SocialMediaAttachmentKind,
    url: String,
    thumbnail_url: Option<String>,
}

#[derive(Debug, Clone)]
struct SocialMediaBatchJob {
    platform: SocialPlatform,
    post_id: String,
    dedup_key: String,
    original_url: String,
    author_name: String,
    author_handle: String,
    published_at_text: Option<String>,
    title: String,
    body_text: String,
    subfolder_name: Option<String>,
    organize_mode: String,
    include_videos: bool,
    has_video: bool,
    needs_enrich: bool,
    referer: Option<String>,
    tags: Vec<String>,
    media: Vec<SocialMediaBatchItem>,
}

fn parse_social_media_job(item: &serde_json::Map<String, Value>) -> Option<SocialMediaBatchJob> {
    let raw_url = item
        .get("originalURL")
        .or_else(|| item.get("url"))
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|s| !s.is_empty())?;
    let parsed_url = Url::parse(raw_url).ok()?;
    if !WebBookmarkResolver::is_web_url(&parsed_url) {
        return None;
    }

    let raw_platform = item
        .get("platform")
        .and_then(Value::as_str)
        .unwrap_or("")
        .trim();
    let parsed_ref = SocialPostURLParser::parse(&parsed_url);
    let platform = SocialPlatform::from_raw(raw_platform)
        .or_else(|| parsed_ref.as_ref().map(SocialPostReference::platform))
        .unwrap_or(SocialPlatform::X);

    let post_id = item
        .get("postID")
        .or_else(|| item.get("tweetID"))
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .map(String::from)
        .or_else(|| {
            parsed_ref.as_ref().map(|r| match r {
                SocialPostReference::X(x) => x.tweet_id.clone(),
                SocialPostReference::Threads { post_id, .. } => post_id.clone(),
                SocialPostReference::Bluesky { rkey, .. } => rkey.clone(),
                SocialPostReference::Xiaohongshu(xhs) => {
                    xhs.note_id.clone().unwrap_or_else(|| xhs.dedup_key())
                }
                SocialPostReference::Pixiv { illust_id, .. } => illust_id.clone(),
                SocialPostReference::Instagram { shortcode, .. } => shortcode.clone(),
                SocialPostReference::Video(v) => v.dedup_key(),
            })
        })
        .unwrap_or_else(|| Uuid::new_v4().simple().to_string()[..8].to_string());

    let dedup_key = item
        .get("dedupKey")
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .map(String::from)
        .or_else(|| canonical_dedup_key(raw_url))
        .unwrap_or_else(|| format!("{}:{post_id}", platform.raw_value()));

    let author_name_raw = item
        .get("authorName")
        .and_then(Value::as_str)
        .map(str::trim)
        .unwrap_or("");
    let author_handle_raw = item
        .get("authorHandle")
        .and_then(Value::as_str)
        .map(str::trim)
        .unwrap_or("")
        .trim_start_matches('@');
    let author_handle = if !author_handle_raw.is_empty() {
        author_handle_raw.to_string()
    } else if !author_name_raw.is_empty() {
        author_name_raw.to_string()
    } else {
        platform.raw_value().to_string()
    };
    let author_name = if !author_name_raw.is_empty() {
        author_name_raw.to_string()
    } else {
        author_handle.clone()
    };

    let published_at_text = item
        .get("publishedAtText")
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .map(String::from);
    let title = item
        .get("title")
        .or_else(|| item.get("articleTitle"))
        .and_then(Value::as_str)
        .map(str::trim)
        .unwrap_or("")
        .to_string();
    let body_text = item
        .get("bodyText")
        .or_else(|| item.get("notes"))
        .and_then(Value::as_str)
        .map(str::trim)
        .unwrap_or("")
        .to_string();
    let subfolder_name = item
        .get("subfolderName")
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .map(String::from);
    let organize_mode = item
        .get("organizeMode")
        .and_then(Value::as_str)
        .map(|s| s.trim().to_ascii_lowercase())
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| "per_post".to_string());
    let include_videos = item
        .get("includeVideos")
        .and_then(Value::as_bool)
        .unwrap_or(true);
    let has_video = item
        .get("hasVideo")
        .and_then(Value::as_bool)
        .unwrap_or(false);
    let needs_enrich = item
        .get("needsEnrich")
        .and_then(Value::as_bool)
        .unwrap_or(false);
    let referer = item
        .get("referer")
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .map(String::from);
    let tags: Vec<String> = item
        .get("tags")
        .and_then(Value::as_array)
        .map(|arr| {
            arr.iter()
                .filter_map(Value::as_str)
                .map(str::trim)
                .filter(|s| !s.is_empty())
                .map(String::from)
                .collect()
        })
        .unwrap_or_default();

    let mut media = Vec::new();
    let mut seen_urls = HashSet::new();
    if let Some(raw_media) = item
        .get("media")
        .or_else(|| item.get("attachments"))
        .and_then(Value::as_array)
    {
        for m in raw_media {
            let Some(u) = m
                .get("url")
                .and_then(Value::as_str)
                .map(str::trim)
                .filter(|s| !s.is_empty())
            else {
                continue;
            };
            if Url::parse(u)
                .ok()
                .is_none_or(|parsed| !WebBookmarkResolver::is_web_url(&parsed))
            {
                continue;
            }
            if !seen_urls.insert(u.to_string()) {
                continue;
            }
            let kind = match m
                .get("kind")
                .and_then(Value::as_str)
                .map(str::to_ascii_lowercase)
                .as_deref()
            {
                Some("video") => SocialMediaAttachmentKind::Video,
                Some("gif" | "animated_gif") => SocialMediaAttachmentKind::Gif,
                _ => SocialMediaAttachmentKind::Photo,
            };
            let thumbnail_url = m
                .get("thumbnailURL")
                .and_then(Value::as_str)
                .map(str::trim)
                .filter(|s| !s.is_empty())
                .map(String::from);
            media.push(SocialMediaBatchItem {
                kind,
                url: u.to_string(),
                thumbnail_url,
            });
        }
    }

    Some(SocialMediaBatchJob {
        platform,
        post_id,
        dedup_key,
        original_url: raw_url.to_string(),
        author_name,
        author_handle,
        published_at_text,
        title,
        body_text,
        subfolder_name,
        organize_mode,
        include_videos,
        has_video,
        needs_enrich,
        referer,
        tags,
        media,
    })
}

fn compact_date_prefix(published_at_text: Option<&str>) -> String {
    let Some(raw) = published_at_text else {
        return String::new();
    };
    let digits: String = raw
        .chars()
        .take(10)
        .filter(|c| c.is_ascii_digit())
        .collect();
    if digits.len() == 8 {
        digits
    } else {
        String::new()
    }
}

fn clean_tweet_headline(body: &str, max_chars: usize) -> String {
    let mut cleaned = String::with_capacity(body.len());
    for token in body.split_whitespace() {
        if token.starts_with("http://t.co/") || token.starts_with("https://t.co/") {
            continue;
        }
        if !cleaned.is_empty() {
            cleaned.push(' ');
        }
        for ch in token.chars() {
            if ch.is_control() || matches!(ch, '/' | '\\' | ':' | '*' | '?' | '"' | '<' | '>' | '|')
            {
                cleaned.push(' ');
            } else {
                cleaned.push(ch);
            }
        }
    }
    let collapsed: String = cleaned.split_whitespace().collect::<Vec<_>>().join(" ");
    collapsed
        .chars()
        .take(max_chars)
        .collect::<String>()
        .trim()
        .to_string()
}

fn synthesize_post_subfolder_name(
    platform: SocialPlatform,
    post_id: &str,
    published_at_text: Option<&str>,
    headline_source: &str,
) -> String {
    let suffix: String = if post_id.chars().count() > 6 {
        post_id
            .chars()
            .rev()
            .take(6)
            .collect::<String>()
            .chars()
            .rev()
            .collect()
    } else {
        post_id.to_string()
    };
    let date_part = published_at_text
        .map(str::trim)
        .filter(|s| s.len() >= 10)
        .and_then(|s| {
            let b = &s.as_bytes()[..10];
            if b[0..4].iter().all(u8::is_ascii_digit)
                && b[4] == b'-'
                && b[5..7].iter().all(u8::is_ascii_digit)
                && b[7] == b'-'
                && b[8..10].iter().all(u8::is_ascii_digit)
            {
                Some(&s[..10])
            } else {
                None
            }
        })
        .unwrap_or("");
    let snippet = clean_tweet_headline(headline_source, 28);
    let mut parts = Vec::new();
    if !date_part.is_empty() {
        parts.push(date_part.to_string());
    }
    if !snippet.is_empty() {
        parts.push(format!("{snippet} [{suffix}]"));
    } else {
        parts.push(format!("{} {post_id}", platform.post_noun()));
    }
    parts.join(" · ")
}

fn sanitize_bridge_filename_part(raw: &str) -> String {
    let cleaned: String = raw
        .chars()
        .map(|c| {
            if c.is_ascii_alphanumeric() || matches!(c, '_' | '-') {
                c
            } else {
                '_'
            }
        })
        .take(40)
        .collect();
    if cleaned.is_empty() {
        "media".to_string()
    } else {
        cleaned
    }
}

async fn ingest_social_media_jobs(
    engine: &LiveCharkleEngine,
    jobs: Vec<SocialMediaBatchJob>,
    root_folder_id: Option<Uuid>,
    target_board_id: Option<Uuid>,
) -> CoreResult<(Vec<AssetRecord>, usize, usize)> {
    let staging_root =
        std::env::temp_dir().join(format!("charkle-social-author-{}", Uuid::new_v4()));
    std::fs::create_dir_all(&staging_root)?;
    let mut staging_guard = StagingDirGuard::new();
    staging_guard.push(staging_root.clone());

    let mut existing_folders = engine.fetch_folders()?;
    let mut created_assets: Vec<AssetRecord> = Vec::new();
    let mut posts_imported = 0usize;
    let mut created_folders_count = 0usize;

    for job in jobs {
        let mut resolved_media = job.media.clone();
        let resolved_title = job.title.clone();
        let mut resolved_body = job.body_text.clone();
        let mut resolved_author_name = job.author_name.clone();
        let mut resolved_handle = job.author_handle.clone();
        let mut resolved_published_at = job.published_at_text.clone();

        let has_direct_video_file = resolved_media.iter().any(|m| {
            matches!(
                m.kind,
                SocialMediaAttachmentKind::Video | SocialMediaAttachmentKind::Gif
            ) && m.url.to_ascii_lowercase().contains(".mp4")
        });
        let should_resolve_online = job.needs_enrich
            || resolved_media.is_empty()
            || (job.platform == SocialPlatform::X
                && job.include_videos
                && job.has_video
                && !has_direct_video_file);

        if should_resolve_online {
            let social_ref_opt = if job.platform == SocialPlatform::X {
                Some(SocialPostReference::X(XPostReference {
                    handle: resolved_handle.clone(),
                    tweet_id: job.post_id.clone(),
                }))
            } else if job.platform == SocialPlatform::Bluesky {
                Url::parse(&job.original_url)
                    .ok()
                    .and_then(|u| SocialPostURLParser::parse(&u))
            } else {
                None
            };
            if let Some(social_ref) = social_ref_opt {
                if let Some(resolved) = SocialPostResolver::resolve(&social_ref).await {
                    let enriched: Vec<SocialMediaBatchItem> = resolved
                        .metadata
                        .effective_attachments()
                        .into_iter()
                        .filter(|att| {
                            Url::parse(&att.url)
                                .ok()
                                .is_some_and(|u| WebBookmarkResolver::is_web_url(&u))
                        })
                        .map(|att| SocialMediaBatchItem {
                            kind: att.kind,
                            url: att.url,
                            thumbnail_url: att.thumbnail_url,
                        })
                        .collect();
                    if !enriched.is_empty() {
                        resolved_media = enriched;
                    }
                    if resolved_body.is_empty() && !resolved.metadata.body_text.trim().is_empty() {
                        resolved_body = resolved.metadata.body_text.trim().to_string();
                    }
                    if !resolved.metadata.author_name.trim().is_empty() {
                        resolved_author_name = resolved.metadata.author_name.trim().to_string();
                    }
                    if !resolved.metadata.author_handle.trim().is_empty() {
                        resolved_handle = resolved.metadata.author_handle.trim().to_string();
                    }
                    if resolved_published_at.is_none() {
                        resolved_published_at = resolved.metadata.published_at_text.clone();
                    }
                }
            }
        }

        if !job.include_videos {
            resolved_media.retain(|m| m.kind == SocialMediaAttachmentKind::Photo);
        }
        if resolved_media.is_empty() {
            continue;
        }

        let post_folder_id = if job.organize_mode == "flat"
            || (job.organize_mode == "multi_only" && resolved_media.len() < 2)
        {
            root_folder_id
        } else {
            let headline_src = if resolved_title.is_empty() {
                resolved_body.as_str()
            } else {
                resolved_title.as_str()
            };
            let folder_name = job
                .subfolder_name
                .clone()
                .unwrap_or_else(|| {
                    synthesize_post_subfolder_name(
                        job.platform,
                        &job.post_id,
                        resolved_published_at.as_deref(),
                        headline_src,
                    )
                })
                .trim()
                .to_string();
            let safe_folder_name = if folder_name.is_empty() {
                format!("{} {}", job.platform.post_noun(), job.post_id)
            } else {
                folder_name
            };
            if let Some(existing) = existing_folders.iter().find(|f| {
                f.parent_id == root_folder_id
                    && f.name.trim().eq_ignore_ascii_case(&safe_folder_name)
            }) {
                Some(existing.id)
            } else {
                let created = engine.create_folder(&safe_folder_name, root_folder_id)?;
                let id = created.id;
                existing_folders.push(created);
                created_folders_count += 1;
                Some(id)
            }
        };

        let post_dir = staging_root.join(format!(
            "{}_{}",
            job.platform.raw_value(),
            sanitize_bridge_filename_part(&job.post_id)
        ));
        let _ = std::fs::create_dir_all(&post_dir);

        let date_compact = compact_date_prefix(resolved_published_at.as_deref());
        let handle_part = sanitize_bridge_filename_part(&resolved_handle);
        let post_id_part = sanitize_bridge_filename_part(&job.post_id);
        let referer_owned = job.referer.clone();

        let mut join_set: tokio::task::JoinSet<(usize, Option<PathBuf>)> =
            tokio::task::JoinSet::new();
        for (idx, item) in resolved_media.iter().cloned().enumerate() {
            let base_name = if date_compact.is_empty() {
                format!("{handle_part}_{post_id_part}_{:02}", idx + 1)
            } else {
                format!("{date_compact}_{handle_part}_{post_id_part}_{:02}", idx + 1)
            };
            let post_dir_clone = post_dir.clone();
            let referer_clone = referer_owned.clone();
            join_set.spawn(async move {
                let primary = SocialPostResolver::download_media_bytes_with_referer(
                    &item.url,
                    item.kind,
                    referer_clone.as_deref(),
                )
                .await;
                let downloaded = match primary {
                    Some(res) => Some(res),
                    None => {
                        if let Some(ref thumb) = item.thumbnail_url {
                            SocialPostResolver::download_media_bytes_with_referer(
                                thumb,
                                SocialMediaAttachmentKind::Photo,
                                referer_clone.as_deref(),
                            )
                            .await
                        } else {
                            None
                        }
                    }
                };
                if let Some((bytes, ext)) = downloaded {
                    let clean_ext = if ext.trim().is_empty() {
                        "jpg"
                    } else {
                        ext.trim().trim_start_matches('.')
                    };
                    let dest = post_dir_clone.join(format!("{base_name}.{clean_ext}"));
                    if std::fs::write(&dest, &bytes).is_ok() {
                        return (idx, Some(dest));
                    }
                }
                (idx, None)
            });
        }

        let mut downloaded_files: Vec<(usize, PathBuf)> = Vec::new();
        while let Some(res) = join_set.join_next().await {
            if let Ok((idx, Some(path))) = res {
                downloaded_files.push((idx, path));
            }
        }
        downloaded_files.sort_by_key(|(idx, _)| *idx);
        if downloaded_files.is_empty() {
            continue;
        }

        let inputs: Vec<CaptureInput> = downloaded_files
            .into_iter()
            .map(|(_, path)| CaptureInput::FilePath(path))
            .collect();
        let ingested = engine
            .ingest(inputs, post_folder_id, target_board_id)
            .await?;
        if ingested.is_empty() {
            continue;
        }

        let clean_snippet = clean_tweet_headline(
            if resolved_title.is_empty() {
                resolved_body.as_str()
            } else {
                resolved_title.as_str()
            },
            36,
        );

        let mut note_sections = Vec::new();
        let author_line = if matches!(
            job.platform,
            SocialPlatform::Pixiv | SocialPlatform::Xiaohongshu
        ) {
            resolved_author_name.clone()
        } else if resolved_author_name.eq_ignore_ascii_case(&resolved_handle) {
            format!("@{resolved_handle}")
        } else {
            format!("{resolved_author_name} (@{resolved_handle})")
        };
        note_sections.push(author_line);
        if !resolved_title.is_empty() {
            note_sections.push(resolved_title.clone());
        }
        if let Some(ref published) = resolved_published_at {
            if !published.is_empty() {
                note_sections.push(format!("发布时间：{published}"));
            }
        }
        if !resolved_body.is_empty() && resolved_body != resolved_title {
            note_sections.push(resolved_body.clone());
        }
        let source_prefix = match job.platform {
            SocialPlatform::X => "原推文：",
            SocialPlatform::Pixiv => "原作品：",
            SocialPlatform::Xiaohongshu => "原笔记：",
            SocialPlatform::Youtube | SocialPlatform::Bilibili => "原视频：",
            SocialPlatform::Bluesky | SocialPlatform::Threads | SocialPlatform::Instagram => {
                "原贴文："
            }
        };
        note_sections.push(format!("{source_prefix}{}", job.original_url));
        let formatted_notes = note_sections.join("\n\n");

        let mut merged_tags: HashSet<String> = job
            .tags
            .iter()
            .map(|t| t.trim().to_string())
            .filter(|t| !t.is_empty())
            .collect();
        merged_tags.insert(job.platform.display_name().to_string());
        if matches!(
            job.platform,
            SocialPlatform::Pixiv | SocialPlatform::Xiaohongshu
        ) {
            if !resolved_author_name.is_empty() {
                merged_tags.insert(resolved_author_name.clone());
            }
        } else {
            merged_tags.insert(format!("@{resolved_handle}"));
            if !resolved_author_name.is_empty()
                && !resolved_author_name.eq_ignore_ascii_case(&resolved_handle)
            {
                merged_tags.insert(resolved_author_name.clone());
            }
        }
        let mut sorted_tags: Vec<String> = merged_tags.into_iter().collect();
        sorted_tags.sort();

        let source_domain = Url::parse(&job.original_url)
            .ok()
            .and_then(|u| u.host_str().map(String::from));
        let author_prefix = if matches!(
            job.platform,
            SocialPlatform::Pixiv | SocialPlatform::Xiaohongshu
        ) {
            resolved_author_name.clone()
        } else {
            format!("@{resolved_handle}")
        };
        let total_count = ingested.len();

        for (idx, mut asset) in ingested.into_iter().enumerate() {
            let base_title = if !clean_snippet.is_empty() {
                format!("{author_prefix} · {clean_snippet}")
            } else {
                format!("{author_prefix} · {}", job.post_id)
            };
            asset.title = if total_count > 1 {
                format!("{base_title} ({}/{total_count})", idx + 1)
            } else {
                base_title
            };
            asset.notes = formatted_notes.clone();
            asset.source_url = Some(job.original_url.clone());
            if asset.source_domain.is_none() {
                asset.source_domain = source_domain.clone();
            }
            let mut tag_seen: HashMap<String, String> = HashMap::new();
            for t in asset.tags.iter().chain(sorted_tags.iter()) {
                let clean = t.trim();
                if !clean.is_empty() {
                    tag_seen
                        .entry(clean.to_lowercase())
                        .or_insert_with(|| clean.to_string());
                }
            }
            let mut final_tags: Vec<String> = tag_seen.into_values().collect();
            final_tags.sort();
            asset.tags = final_tags;

            match engine.database().save_asset_locally(&asset, true) {
                Ok(saved) => created_assets.push(saved),
                Err(_) => created_assets.push(asset),
            }
        }
        posts_imported += 1;
    }

    if !created_assets.is_empty() {
        engine.notify_external_change();
    }

    Ok((created_assets, posts_imported, created_folders_count))
}

async fn handle_ingest(
    req: &HttpRequest,
    engine: &LiveCharkleEngine,
    cors_headers: Vec<(String, String)>,
    pending_mutations: &Arc<Mutex<PendingMutationBatch>>,
    on_mutated: &Option<MutationCallback>,
) -> HttpResponse {
    let Ok(Value::Object(body)) = serde_json::from_slice::<Value>(&req.body) else {
        return HttpResponse::json(
            400,
            cors_headers,
            json!({ "error": "请提供至少一个待导入项。", "code": "INVALID_INPUT" }),
        );
    };
    let Some(raw_inputs) = body.get("inputs").and_then(Value::as_array) else {
        return HttpResponse::json(
            400,
            cors_headers,
            json!({ "error": "请提供至少一个待导入项。", "code": "INVALID_INPUT" }),
        );
    };
    if raw_inputs.is_empty() {
        return HttpResponse::json(
            400,
            cors_headers,
            json!({ "error": "请提供至少一个待导入项。", "code": "INVALID_INPUT" }),
        );
    }

    let target_folder_id = body
        .get("targetFolderID")
        .and_then(Value::as_str)
        .and_then(|s| Uuid::parse_str(s.trim()).ok());
    let target_board_id = body
        .get("targetBoardID")
        .and_then(Value::as_str)
        .and_then(|s| Uuid::parse_str(s.trim()).ok());
    let skip_duplicates = body
        .get("skipDuplicates")
        .and_then(Value::as_bool)
        .unwrap_or(false);

    let (mut known_keys, mut known_media_keys) = if skip_duplicates {
        fetch_existing_source_keys(engine)
            .map(|(_, k, mk)| (k, mk))
            .unwrap_or_default()
    } else {
        (HashSet::new(), HashSet::new())
    };

    let mut parsed_inputs: Vec<CaptureInput> = Vec::new();
    let mut social_media_jobs: Vec<SocialMediaBatchJob> = Vec::new();
    let mut skipped: usize = 0;

    for item in raw_inputs {
        let Some(obj) = item.as_object() else {
            continue;
        };
        let Some(kind) = obj.get("type").and_then(Value::as_str) else {
            continue;
        };
        match kind {
            "webURL" => {
                let Some(url_str) = obj
                    .get("url")
                    .and_then(Value::as_str)
                    .map(str::trim)
                    .filter(|s| !s.is_empty())
                else {
                    continue;
                };
                let Ok(url) = Url::parse(url_str) else {
                    continue;
                };
                if !WebBookmarkResolver::is_web_url(&url) {
                    continue;
                }
                if skip_duplicates {
                    if let Some(key) = canonical_dedup_key(url.as_str()) {
                        if !known_keys.insert(key) {
                            skipped += 1;
                            continue;
                        }
                    }
                }
                let title = obj
                    .get("title")
                    .and_then(Value::as_str)
                    .map(str::trim)
                    .filter(|s| !s.is_empty())
                    .map(str::to_string);
                let notes = obj
                    .get("notes")
                    .and_then(Value::as_str)
                    .map(str::trim)
                    .filter(|s| !s.is_empty())
                    .map(str::to_string);
                parsed_inputs.push(CaptureInput::WebUrl {
                    url: url.to_string(),
                    title,
                    notes,
                });
            }
            "imageData" => {
                let Some(raw_b64) = obj.get("base64Data").and_then(Value::as_str) else {
                    continue;
                };
                let Some(data) = decode_base64_payload(raw_b64) else {
                    continue;
                };
                if data.is_empty() {
                    continue;
                }
                let suggested_name = obj
                    .get("suggestedName")
                    .and_then(Value::as_str)
                    .map(str::trim)
                    .filter(|s| !s.is_empty())
                    .unwrap_or("Clip.png")
                    .to_string();
                let source_url = obj
                    .get("sourceURL")
                    .and_then(Value::as_str)
                    .map(str::trim)
                    .filter(|s| !s.is_empty())
                    .map(str::to_string);
                parsed_inputs.push(CaptureInput::ImageData {
                    data,
                    suggested_name,
                    source_url,
                });
            }
            "textSnippet" => {
                let text = obj
                    .get("text")
                    .and_then(Value::as_str)
                    .map(str::trim)
                    .unwrap_or("");
                if text.is_empty() {
                    continue;
                }
                let title = obj
                    .get("title")
                    .and_then(Value::as_str)
                    .map(str::trim)
                    .filter(|s| !s.is_empty())
                    .unwrap_or("文字灵感")
                    .to_string();
                let source_url = obj
                    .get("sourceURL")
                    .and_then(Value::as_str)
                    .map(str::trim)
                    .filter(|s| !s.is_empty())
                    .map(str::to_string);
                parsed_inputs.push(CaptureInput::TextSnippet {
                    title,
                    text: text.to_string(),
                    source_url,
                });
            }
            "colorSwatch" | "swatch" => {
                let Some(hex) = obj
                    .get("hex")
                    .and_then(Value::as_str)
                    .map(str::trim)
                    .filter(|s| !s.is_empty())
                else {
                    continue;
                };
                let title = obj
                    .get("title")
                    .and_then(Value::as_str)
                    .map(str::trim)
                    .filter(|s| !s.is_empty())
                    .map(str::to_string);
                parsed_inputs.push(CaptureInput::ColorSwatch {
                    hex: hex.to_string(),
                    title,
                });
            }
            "socialBookmark" => {
                let Some((meta, cover_image_data, tags)) = parse_social_bookmark_payload(obj)
                else {
                    continue;
                };
                if skip_duplicates {
                    if let Some(key) = canonical_dedup_key(&meta.original_url) {
                        if !known_keys.insert(key) {
                            skipped += 1;
                            continue;
                        }
                    }
                }
                parsed_inputs.push(CaptureInput::SocialBookmark {
                    metadata: Box::new(meta),
                    cover_image_data,
                    tags,
                });
            }
            "socialMedia" | "tweetMedia" => {
                let Some(job) = parse_social_media_job(obj) else {
                    continue;
                };
                if skip_duplicates && !known_media_keys.insert(job.dedup_key.clone()) {
                    skipped += 1;
                    continue;
                }
                social_media_jobs.push(job);
            }
            _ => continue,
        }
    }

    if parsed_inputs.is_empty() && social_media_jobs.is_empty() && skipped > 0 {
        return HttpResponse::json(
            200,
            cors_headers,
            json!({
                "assets": [],
                "created": 0,
                "skipped": skipped,
                "postsImported": 0,
                "tweetsImported": 0,
                "createdFolders": 0,
            }),
        );
    }

    if parsed_inputs.is_empty() && social_media_jobs.is_empty() {
        return HttpResponse::json(
            400,
            cors_headers,
            json!({ "error": "未找到有效的待导入素材。", "code": "INVALID_INPUT" }),
        );
    }

    let mut all_created: Vec<AssetRecord> = Vec::new();
    let mut posts_imported = 0usize;
    let mut created_folders = 0usize;

    if !parsed_inputs.is_empty() {
        match engine
            .ingest(parsed_inputs, target_folder_id, target_board_id)
            .await
        {
            Ok(created) => all_created.extend(created),
            Err(err) => {
                return HttpResponse::json(
                    500,
                    cors_headers,
                    json!({ "error": err.to_string(), "code": "INTERNAL_ERROR" }),
                );
            }
        }
    }

    if !social_media_jobs.is_empty() {
        match ingest_social_media_jobs(engine, social_media_jobs, target_folder_id, target_board_id)
            .await
        {
            Ok((social_assets, imported_posts, folders_created)) => {
                all_created.extend(social_assets);
                posts_imported += imported_posts;
                created_folders += folders_created;
            }
            Err(err) => {
                return HttpResponse::json(
                    500,
                    cors_headers,
                    json!({ "error": err.to_string(), "code": "INTERNAL_ERROR" }),
                );
            }
        }
    }

    if !all_created.is_empty() || created_folders > 0 {
        schedule_debounced_mutation(
            pending_mutations,
            on_mutated,
            all_created.len(),
            created_folders,
            target_folder_id,
            target_board_id,
        );
    }

    let serialized_assets: Vec<Value> = all_created
        .iter()
        .map(|asset| {
            let mut map = serde_json::Map::new();
            map.insert("id".to_string(), json!(format_swift_uuid(&asset.id)));
            map.insert("title".to_string(), json!(asset.title));
            map.insert("mediaKind".to_string(), json!(asset.media_kind.raw_value()));
            if let Some(ref src) = asset.source_url {
                map.insert("sourceURL".to_string(), json!(src));
            }
            if let Some(fid) = asset.folder_id {
                map.insert("folderID".to_string(), json!(format_swift_uuid(&fid)));
            }
            Value::Object(map)
        })
        .collect();

    let status_code = if all_created.is_empty() && skipped > 0 {
        200
    } else {
        201
    };

    HttpResponse::json(
        status_code,
        cors_headers,
        json!({
            "assets": serialized_assets,
            "created": all_created.len(),
            "skipped": skipped,
            "postsImported": posts_imported,
            "tweetsImported": posts_imported,
            "createdFolders": created_folders,
        }),
    )
}

async fn handle_multipart_upload(
    req: &HttpRequest,
    engine: &LiveCharkleEngine,
    cors_headers: Vec<(String, String)>,
    pending_mutations: &Arc<Mutex<PendingMutationBatch>>,
    on_mutated: &Option<MutationCallback>,
) -> HttpResponse {
    let Some(content_type) = req.header("content-type") else {
        return HttpResponse::json(
            400,
            cors_headers,
            json!({ "error": "上传内容格式不正确。", "code": "INVALID_MULTIPART" }),
        );
    };
    let Some(boundary) = extract_multipart_boundary(content_type) else {
        return HttpResponse::json(
            400,
            cors_headers,
            json!({ "error": "上传内容格式不正确。", "code": "INVALID_MULTIPART" }),
        );
    };

    let parts = parse_multipart_form_data(&req.body, &boundary);
    let mut target_folder_id: Option<Uuid> = None;
    let mut target_board_id: Option<Uuid> = None;
    let mut source_url: Option<String> = None;
    let mut files: Vec<(String, Vec<u8>)> = Vec::new();

    for part in parts {
        if let Some(file_name) = part.file_name {
            if !part.data.is_empty() {
                files.push((file_name, part.data));
            }
        } else {
            let text_val = String::from_utf8_lossy(&part.data).trim().to_string();
            match part.name.as_str() {
                "targetFolderID" => target_folder_id = Uuid::parse_str(&text_val).ok(),
                "targetBoardID" => target_board_id = Uuid::parse_str(&text_val).ok(),
                "sourceURL" => {
                    source_url = (!text_val.is_empty()).then_some(text_val);
                }
                _ => {}
            }
        }
    }

    if files.is_empty() {
        return HttpResponse::json(
            400,
            cors_headers,
            json!({ "error": "未检测到上传文件。", "code": "NO_FILES" }),
        );
    }

    let inputs: Vec<CaptureInput> = files
        .into_iter()
        .map(|(name, data)| CaptureInput::ImageData {
            data,
            suggested_name: name,
            source_url: source_url.clone(),
        })
        .collect();

    match engine
        .ingest(inputs, target_folder_id, target_board_id)
        .await
    {
        Ok(created) => {
            if !created.is_empty() {
                schedule_debounced_mutation(
                    pending_mutations,
                    on_mutated,
                    created.len(),
                    0,
                    target_folder_id,
                    target_board_id,
                );
            }
            let serialized_assets: Vec<Value> = created
                .iter()
                .map(|asset| {
                    json!({
                        "id": format_swift_uuid(&asset.id),
                        "title": asset.title,
                        "mediaKind": asset.media_kind.raw_value(),
                    })
                })
                .collect();
            HttpResponse::json(
                201,
                cors_headers,
                json!({
                    "assets": serialized_assets,
                    "created": created.len(),
                }),
            )
        }
        Err(err) => HttpResponse::json(
            500,
            cors_headers,
            json!({ "error": err.to_string(), "code": "INTERNAL_ERROR" }),
        ),
    }
}

// =============================================================================
// Security, Payload & Multipart Helpers
// =============================================================================

fn validate_bearer_token(header: Option<&str>, expected_token: &str) -> bool {
    if expected_token.is_empty() {
        return false;
    }
    let Some(raw) = header else {
        return false;
    };
    let trimmed = raw.trim();
    if trimmed.len() < 7 || !trimmed.as_bytes()[..7].eq_ignore_ascii_case(b"bearer ") {
        return false;
    }
    let supplied = trimmed[7..].trim();
    constant_time_eq(supplied.as_bytes(), expected_token.as_bytes())
}

fn constant_time_eq(lhs: &[u8], rhs: &[u8]) -> bool {
    if lhs.is_empty() || lhs.len() != rhs.len() {
        return false;
    }
    let mut diff = 0u8;
    for (&a, &b) in lhs.iter().zip(rhs.iter()) {
        diff |= a ^ b;
    }
    diff == 0
}

/// Strictly validates browser-extension origins (`chrome-extension://`, `safari-web-extension://`,
/// `moz-extension://`) with a non-empty host. Rejects `http://localhost`, `http://127.0.0.1`,
/// `https://*`, `file://`, and empty/missing origins.
pub fn is_browser_extension_origin(origin: Option<&str>) -> bool {
    let Some(raw) = origin.map(str::trim).filter(|s| !s.is_empty()) else {
        return false;
    };
    let lower = raw.to_ascii_lowercase();
    let rest = if let Some(r) = lower.strip_prefix("chrome-extension://") {
        r
    } else if let Some(r) = lower.strip_prefix("safari-web-extension://") {
        r
    } else if let Some(r) = lower.strip_prefix("moz-extension://") {
        r
    } else {
        return false;
    };
    let host = rest.split('/').next().unwrap_or("");
    !host.is_empty()
        && host
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'-' | b'_' | b'.'))
}

fn is_loopback_http_origin(origin: &str) -> bool {
    let lower = origin.trim().to_ascii_lowercase();
    for prefix in ["http://127.0.0.1", "http://localhost"] {
        if let Some(rest) = lower.strip_prefix(prefix) {
            if rest.is_empty() || rest.starts_with(':') || rest.starts_with('/') {
                return true;
            }
        }
    }
    false
}

fn build_cors_headers(origin: Option<&str>, extension_only: bool) -> Vec<(String, String)> {
    let mut headers = vec![
        (
            "Access-Control-Allow-Methods".to_string(),
            "GET, POST, OPTIONS".to_string(),
        ),
        (
            "Access-Control-Allow-Headers".to_string(),
            "Authorization, Content-Type, Accept, X-Charkle-Extension".to_string(),
        ),
        (
            "Access-Control-Allow-Private-Network".to_string(),
            "true".to_string(),
        ),
        ("Access-Control-Max-Age".to_string(), "600".to_string()),
        ("Vary".to_string(), "Origin".to_string()),
    ];

    if let Some(trimmed) = origin.map(str::trim).filter(|s| !s.is_empty()) {
        let allowed = if extension_only {
            is_browser_extension_origin(Some(trimmed))
        } else {
            is_browser_extension_origin(Some(trimmed)) || is_loopback_http_origin(trimmed)
        };
        if allowed {
            headers.push((
                "Access-Control-Allow-Origin".to_string(),
                trimmed.to_string(),
            ));
        }
    }
    headers
}

fn decode_base64_payload(raw: &str) -> Option<Vec<u8>> {
    let trimmed = raw.trim();
    let payload = if trimmed.len() >= 5 && trimmed.as_bytes()[..5].eq_ignore_ascii_case(b"data:") {
        let comma = trimmed.find(',')?;
        &trimmed[comma + 1..]
    } else {
        trimmed
    };
    let compact: String = payload.chars().filter(|c| !c.is_whitespace()).collect();
    BASE64_STD.decode(compact).ok()
}

fn parse_social_bookmark_payload(
    item: &serde_json::Map<String, Value>,
) -> Option<(SocialPostMetadata, Option<Vec<u8>>, Vec<String>)> {
    let raw_url = item
        .get("originalURL")
        .or_else(|| item.get("url"))
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|s| !s.is_empty())?;
    let parsed_url = Url::parse(raw_url).ok()?;
    if !WebBookmarkResolver::is_web_url(&parsed_url) {
        return None;
    }

    let raw_platform = item
        .get("platform")
        .and_then(Value::as_str)
        .unwrap_or("")
        .trim();
    let platform = SocialPlatform::from_raw(raw_platform)
        .or_else(|| SocialPostURLParser::parse(&parsed_url).map(|r| r.platform()))
        .unwrap_or(SocialPlatform::X);

    let author_name = item
        .get("authorName")
        .and_then(Value::as_str)
        .map(str::trim)
        .unwrap_or("");
    let author_handle = item
        .get("authorHandle")
        .and_then(Value::as_str)
        .map(str::trim)
        .unwrap_or("");
    let effective_name = if !author_name.is_empty() {
        author_name.to_string()
    } else if !author_handle.is_empty() {
        author_handle.to_string()
    } else {
        platform.display_name().to_string()
    };
    let effective_handle = if !author_handle.is_empty() {
        author_handle.to_string()
    } else {
        effective_name.clone()
    };

    let article_title = item
        .get("articleTitle")
        .or_else(|| item.get("title"))
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .map(str::to_string);
    let body_raw = item
        .get("bodyText")
        .or_else(|| item.get("notes"))
        .and_then(Value::as_str)
        .map(str::trim)
        .unwrap_or("");

    let mut attachments = Vec::new();
    if let Some(raw_atts) = item.get("attachments").and_then(Value::as_array) {
        for att in raw_atts {
            let Some(u) = att
                .get("url")
                .and_then(Value::as_str)
                .map(str::trim)
                .filter(|s| !s.is_empty())
            else {
                continue;
            };
            let kind = match att
                .get("kind")
                .and_then(Value::as_str)
                .map(str::to_ascii_lowercase)
                .as_deref()
            {
                Some("video") => SocialMediaAttachmentKind::Video,
                Some("gif") => SocialMediaAttachmentKind::Gif,
                _ => SocialMediaAttachmentKind::Photo,
            };
            let thumb = att
                .get("thumbnailURL")
                .and_then(Value::as_str)
                .map(str::trim)
                .filter(|s| !s.is_empty())
                .map(str::to_string);
            attachments.push(SocialMediaAttachment::new(kind, u.to_string(), thumb));
        }
    }

    let media_urls: Vec<String> = item
        .get("mediaURLs")
        .and_then(Value::as_array)
        .map(|arr| {
            arr.iter()
                .filter_map(Value::as_str)
                .map(str::trim)
                .filter(|s| !s.is_empty())
                .map(str::to_string)
                .collect()
        })
        .unwrap_or_default();
    let media_thumbs: Vec<String> = item
        .get("mediaThumbnailURLs")
        .and_then(Value::as_array)
        .map(|arr| {
            arr.iter()
                .filter_map(Value::as_str)
                .map(str::trim)
                .filter(|s| !s.is_empty())
                .map(str::to_string)
                .collect()
        })
        .unwrap_or_default();

    if attachments.is_empty() && !media_urls.is_empty() {
        for (idx, u) in media_urls.iter().enumerate() {
            let thumb = media_thumbs.get(idx).cloned().unwrap_or_else(|| u.clone());
            attachments.push(SocialMediaAttachment::new(
                SocialMediaAttachmentKind::Photo,
                u.clone(),
                Some(thumb),
            ));
        }
    }

    let video_url = item
        .get("videoURL")
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .map(str::to_string);
    let has_video = item
        .get("hasVideo")
        .and_then(Value::as_bool)
        .unwrap_or_else(|| video_url.is_some());
    let avatar_url = item
        .get("authorAvatarURL")
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .map(str::to_string);
    let published_at = item
        .get("publishedAtText")
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .map(str::to_string);
    let quoted_author = item
        .get("quotedAuthor")
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .map(str::to_string);
    let quoted_text = item
        .get("quotedText")
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .map(str::to_string);

    let final_media_urls = if attachments.is_empty() {
        media_urls
    } else {
        attachments.iter().map(|a| a.url.clone()).collect()
    };
    let final_media_thumbs = if attachments.is_empty() {
        media_thumbs
    } else {
        attachments
            .iter()
            .map(|a| a.thumbnail_url.clone().unwrap_or_else(|| a.url.clone()))
            .collect()
    };

    let body_text = if !body_raw.is_empty() {
        body_raw.to_string()
    } else {
        article_title.clone().unwrap_or_else(|| raw_url.to_string())
    };

    let meta = SocialPostMetadata {
        platform,
        author_name: effective_name,
        author_handle: effective_handle,
        author_avatar_url: avatar_url,
        published_at_text: published_at,
        body_text,
        quoted_author,
        quoted_text,
        article_title,
        media_urls: final_media_urls,
        media_thumbnail_urls: final_media_thumbs,
        attachments,
        has_video,
        video_url,
        reply_count: item
            .get("replyCount")
            .and_then(XiaohongshuPostResolver::parse_chinese_metric_count),
        repost_count: item
            .get("repostCount")
            .and_then(XiaohongshuPostResolver::parse_chinese_metric_count),
        like_count: item
            .get("likeCount")
            .and_then(XiaohongshuPostResolver::parse_chinese_metric_count),
        view_count: item
            .get("viewCount")
            .and_then(XiaohongshuPostResolver::parse_chinese_metric_count),
        original_url: raw_url.to_string(),
        media_fetch_failed: false,
        video_duration_seconds: None,
        video_summary: None,
        video_outline: Vec::new(),
        video_id: None,
        video_cid: None,
    };

    let cover_data = item
        .get("coverDataUrl")
        .and_then(Value::as_str)
        .and_then(decode_base64_payload);
    let tags: Vec<String> = item
        .get("tags")
        .and_then(Value::as_array)
        .map(|arr| {
            arr.iter()
                .filter_map(Value::as_str)
                .map(str::trim)
                .filter(|s| !s.is_empty())
                .map(str::to_string)
                .collect()
        })
        .unwrap_or_default();

    Some((meta, cover_data, tags))
}

struct MultipartPart {
    name: String,
    file_name: Option<String>,
    data: Vec<u8>,
}

fn extract_multipart_boundary(content_type: &str) -> Option<String> {
    for segment in content_type.split(';') {
        let trimmed = segment.trim();
        if trimmed.len() >= 9 && trimmed.as_bytes()[..9].eq_ignore_ascii_case(b"boundary=") {
            let mut val = trimmed[9..].trim();
            if val.starts_with('"') && val.ends_with('"') && val.len() >= 2 {
                val = &val[1..val.len() - 1];
            }
            if !val.is_empty() {
                return Some(val.to_string());
            }
        }
    }
    None
}

fn parse_multipart_form_data(body: &[u8], boundary: &str) -> Vec<MultipartPart> {
    let delimiter = format!("--{boundary}").into_bytes();
    let mut parts = Vec::new();

    let Some(first) = find_bytes(body, &delimiter) else {
        return parts;
    };
    let mut cursor = first + delimiter.len();

    while cursor < body.len() {
        if body[cursor..].starts_with(b"--") {
            break;
        }
        if body[cursor..].starts_with(b"\r\n") {
            cursor += 2;
        } else if body[cursor..].starts_with(b"\n") {
            cursor += 1;
        }
        let Some(rel_next) = find_bytes(&body[cursor..], &delimiter) else {
            break;
        };
        let chunk = &body[cursor..cursor + rel_next];
        cursor = cursor + rel_next + delimiter.len();

        let (header_bytes, raw_payload) = if let Some(sep) = find_bytes(chunk, b"\r\n\r\n") {
            (&chunk[..sep], &chunk[sep + 4..])
        } else if let Some(sep) = find_bytes(chunk, b"\n\n") {
            (&chunk[..sep], &chunk[sep + 2..])
        } else {
            continue;
        };

        let mut payload = raw_payload.to_vec();
        if payload.ends_with(b"\r\n") {
            payload.truncate(payload.len() - 2);
        } else if payload.ends_with(b"\n") {
            payload.truncate(payload.len() - 1);
        }

        let header_str = String::from_utf8_lossy(header_bytes);
        let mut part_name = String::new();
        let mut file_name = None;
        for line in header_str.lines() {
            let trimmed = line.trim();
            if trimmed.len() >= 20
                && trimmed.as_bytes()[..20].eq_ignore_ascii_case(b"content-disposition:")
            {
                if let Some(n) = extract_quoted_param("name", trimmed) {
                    part_name = n;
                }
                file_name = extract_quoted_param("filename", trimmed);
            }
        }
        if !part_name.is_empty() {
            parts.push(MultipartPart {
                name: part_name,
                file_name,
                data: payload,
            });
        }
    }
    parts
}

fn extract_quoted_param(key: &str, header_line: &str) -> Option<String> {
    let lower = header_line.to_ascii_lowercase();
    let needle = format!("{}=\"", key.to_ascii_lowercase());
    let start = lower.find(&needle)? + needle.len();
    let rest = &header_line[start..];
    let end = rest.find('"')?;
    Some(rest[..end].to_string())
}

fn find_bytes(haystack: &[u8], needle: &[u8]) -> Option<usize> {
    if needle.is_empty() || needle.len() > haystack.len() {
        return None;
    }
    haystack
        .windows(needle.len())
        .position(|window| window == needle)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::media::artwork::MediaArtwork;
    use image::{DynamicImage, Rgba, RgbaImage};
    use tempfile::tempdir;

    async fn spawn_test_bridge() -> (
        tempfile::TempDir,
        Arc<LiveCharkleEngine>,
        Arc<LocalExtensionBridgeServer>,
        u16,
        String,
    ) {
        let tmp = tempdir().unwrap();
        let engine = Arc::new(LiveCharkleEngine::open(tmp.path()).unwrap());
        let cfg = ExtensionBridgeConfig {
            enabled: true,
            allow_local_auto_pair: true,
            access_token: "test_bridge_secret_token_0123456789abcdef01234567".to_string(),
        };
        let bridge = Arc::new(LocalExtensionBridgeServer::with_options(
            Arc::clone(&engine),
            tmp.path().to_path_buf(),
            cfg.clone(),
            0,
            true,
            None,
        ));
        let status = bridge.start().await.expect("start loopback bridge");
        assert!(status.running);
        assert!(status.port > 0);
        (tmp, engine, bridge, status.port, cfg.access_token)
    }

    #[tokio::test]
    async fn health_and_local_pair_enforce_strict_origin_header_and_toggle_security() {
        let (_tmp, _engine, bridge, port, expected_token) = spawn_test_bridge().await;
        let client = reqwest::Client::new();
        let base = format!("http://127.0.0.1:{port}");

        // 1. GET /api/v1/health never leaks token
        let health = client
            .get(format!("{base}/api/v1/health"))
            .send()
            .await
            .unwrap();
        assert_eq!(health.status(), 200);
        let health_json: Value = health.json().await.unwrap();
        assert_eq!(health_json["ok"], true);
        assert_eq!(health_json["app"], "charkle-windows");
        assert_eq!(health_json["port"], port);
        assert_eq!(health_json["autoPair"], true);
        assert!(health_json.get("token").is_none());

        // 2. Valid chrome-extension:// + X-Charkle-Extension: 1 -> 200 with token & matching CORS
        let ok_pair = client
            .post(format!("{base}/api/v1/auth/local-pair"))
            .header("Origin", "chrome-extension://abcdefghijklmnop")
            .header("X-Charkle-Extension", "1")
            .send()
            .await
            .unwrap();
        assert_eq!(ok_pair.status(), 200);
        assert_eq!(
            ok_pair
                .headers()
                .get("access-control-allow-origin")
                .and_then(|v| v.to_str().ok()),
            Some("chrome-extension://abcdefghijklmnop")
        );
        let ok_body: Value = ok_pair.json().await.unwrap();
        assert_eq!(ok_body["ok"], true);
        assert_eq!(ok_body["token"], expected_token);
        assert_eq!(ok_body["serverUrl"], base);

        // 3. Rejected origins (localhost, 127.0.0.1, evil.com, missing Origin) -> 403 INVALID_ORIGIN & NO ACAO
        for bad_origin in [
            Some("http://localhost:3000"),
            Some("http://127.0.0.1:8080"),
            Some("https://evil.com"),
            None,
        ] {
            let mut req = client
                .post(format!("{base}/api/v1/auth/local-pair"))
                .header("X-Charkle-Extension", "1");
            if let Some(o) = bad_origin {
                req = req.header("Origin", o);
            }
            let resp = req.send().await.unwrap();
            assert_eq!(resp.status(), 403, "expected 403 for origin {bad_origin:?}");
            assert!(
                resp.headers().get("access-control-allow-origin").is_none(),
                "must NEVER echo ACAO for rejected origin {bad_origin:?}"
            );
            let body: Value = resp.json().await.unwrap();
            assert_eq!(body["code"], "INVALID_ORIGIN");
        }

        // OPTIONS preflight on /local-pair with http://localhost MUST ALSO omit ACAO
        let opt_localhost = client
            .request(
                reqwest::Method::OPTIONS,
                format!("{base}/api/v1/auth/local-pair"),
            )
            .header("Origin", "http://localhost:5173")
            .send()
            .await
            .unwrap();
        assert_eq!(opt_localhost.status(), 204);
        assert!(opt_localhost
            .headers()
            .get("access-control-allow-origin")
            .is_none());

        // 4. Missing X-Charkle-Extension header -> 403 MISSING_EXTENSION_HEADER
        let missing_hdr = client
            .post(format!("{base}/api/v1/auth/local-pair"))
            .header("Origin", "chrome-extension://abcdefghijklmnop")
            .send()
            .await
            .unwrap();
        assert_eq!(missing_hdr.status(), 403);
        let missing_body: Value = missing_hdr.json().await.unwrap();
        assert_eq!(missing_body["code"], "MISSING_EXTENSION_HEADER");

        // 5. Disabled allowLocalAutoPair -> 403 AUTO_PAIR_DISABLED
        bridge.set_auto_pair(false).await.unwrap();
        let disabled = client
            .post(format!("{base}/api/v1/auth/local-pair"))
            .header("Origin", "chrome-extension://abcdefghijklmnop")
            .header("X-Charkle-Extension", "1")
            .send()
            .await
            .unwrap();
        assert_eq!(disabled.status(), 403);
        let disabled_body: Value = disabled.json().await.unwrap();
        assert_eq!(disabled_body["code"], "AUTO_PAIR_DISABLED");

        bridge.stop().await;
    }

    #[tokio::test]
    async fn authenticated_folders_dedup_social_ingest_and_multipart_upload_work_end_to_end() {
        let (_tmp, engine, bridge, port, token) = spawn_test_bridge().await;
        let client = reqwest::Client::new();
        let base = format!("http://127.0.0.1:{port}");
        let auth = format!("Bearer {token}");

        // 1. Invalid Bearer -> 401 on protected endpoint, authenticated: false on /auth/status
        let unauth = client
            .get(format!("{base}/api/v1/folders"))
            .header("Authorization", "Bearer wrong-token")
            .send()
            .await
            .unwrap();
        assert_eq!(unauth.status(), 401);

        let bad_status = client
            .get(format!("{base}/api/v1/auth/status"))
            .header("Authorization", "Bearer wrong-token")
            .send()
            .await
            .unwrap();
        assert_eq!(bad_status.status(), 200);
        assert_eq!(
            bad_status.json::<Value>().await.unwrap()["authenticated"],
            false
        );

        let ok_status = client
            .get(format!("{base}/api/v1/auth/status"))
            .header("Authorization", &auth)
            .send()
            .await
            .unwrap();
        assert_eq!(ok_status.status(), 200);
        assert_eq!(
            ok_status.json::<Value>().await.unwrap()["authenticated"],
            true
        );

        // 2. POST /api/v1/folders create + case-insensitive reuseExisting
        let created_folder = client
            .post(format!("{base}/api/v1/folders"))
            .header("Authorization", &auth)
            .json(&json!({ "name": "小红书收藏", "reuseExisting": true }))
            .send()
            .await
            .unwrap();
        assert_eq!(created_folder.status(), 201);
        let folder_json: Value = created_folder.json().await.unwrap();
        let folder_id = folder_json["folder"]["id"].as_str().unwrap().to_string();
        assert_eq!(folder_json["reused"], false);
        assert_eq!(folder_json["created"], true);

        let reused_folder = client
            .post(format!("{base}/api/v1/folders"))
            .header("Authorization", &auth)
            .json(&json!({ "name": " 小红书收藏 ", "reuseExisting": true }))
            .send()
            .await
            .unwrap();
        assert_eq!(reused_folder.status(), 200);
        let reused_json: Value = reused_folder.json().await.unwrap();
        assert_eq!(
            reused_json["folder"]["id"].as_str(),
            Some(folder_id.as_str())
        );
        assert_eq!(reused_json["reused"], true);
        assert_eq!(reused_json["created"], false);

        // 3. POST /api/v1/assets/ingest with Xiaohongshu socialBookmark + embedded PNG cover
        let cover_png = MediaArtwork::encode_png(&DynamicImage::ImageRgba8(RgbaImage::from_pixel(
            60,
            80,
            Rgba([255, 36, 66, 255]),
        )))
        .unwrap();
        let cover_data_url = format!("data:image/png;base64,{}", BASE64_STD.encode(&cover_png));

        let ingest_res = client
            .post(format!("{base}/api/v1/assets/ingest"))
            .header("Authorization", &auth)
            .json(&json!({
                "targetFolderID": folder_id,
                "skipDuplicates": true,
                "inputs": [{
                    "type": "socialBookmark",
                    "platform": "xiaohongshu",
                    "originalURL": "https://www.xiaohongshu.com/explore/67a1b2c3d4e5f60718293a4b?xsec_token=FIRST_TOKEN",
                    "authorName": "纸感研究所",
                    "authorHandle": "5f11223344556677889900aa",
                    "articleTitle": "极简网格画册排版参考",
                    "bodyText": "分享一组 3:4 纸感画册网格参考与字体比例",
                    "likeCount": "1.2万",
                    "attachments": [
                        { "kind": "photo", "url": "https://sns-webpic-qc.xhscdn.com/a1.webp" },
                        { "kind": "photo", "url": "https://sns-webpic-qc.xhscdn.com/a2.webp" }
                    ],
                    "coverDataUrl": cover_data_url,
                    "tags": ["排版", "平面设计"]
                }]
            }))
            .send()
            .await
            .unwrap();
        assert_eq!(ingest_res.status(), 201);
        let ingest_json: Value = ingest_res.json().await.unwrap();
        assert_eq!(ingest_json["created"], 1);
        assert_eq!(ingest_json["skipped"], 0);
        let asset_id = Uuid::parse_str(ingest_json["assets"][0]["id"].as_str().unwrap()).unwrap();
        let stored = engine.fetch_asset(asset_id).unwrap().expect("stored asset");
        assert_eq!((stored.pixel_width, stored.pixel_height), (900, 1440));
        assert!(stored.tags.iter().any(|t| t == "小红书"));
        assert!(stored.tags.iter().any(|t| t == "排版"));

        // 4. GET /api/v1/assets/existing-sources returns xhs:<noteID> canonical key
        let existing = client
            .get(format!("{base}/api/v1/assets/existing-sources"))
            .header("Authorization", &auth)
            .send()
            .await
            .unwrap();
        assert_eq!(existing.status(), 200);
        let existing_json: Value = existing.json().await.unwrap();
        let keys: Vec<&str> = existing_json["canonicalKeys"]
            .as_array()
            .unwrap()
            .iter()
            .filter_map(Value::as_str)
            .collect();
        assert!(keys.contains(&"xhs:67a1b2c3d4e5f60718293a4b"));

        // 5. Re-ingest same note with ROTATED xsec_token and skipDuplicates=true -> skipped=1
        let dup_res = client
            .post(format!("{base}/api/v1/assets/ingest"))
            .header("Authorization", &auth)
            .json(&json!({
                "targetFolderID": folder_id,
                "skipDuplicates": true,
                "inputs": [{
                    "type": "socialBookmark",
                    "platform": "xiaohongshu",
                    "originalURL": "https://www.xiaohongshu.com/discovery/item/67A1B2C3D4E5F60718293A4B?xsec_token=ROTATED_TOKEN",
                    "authorName": "纸感研究所",
                    "articleTitle": "极简网格画册排版参考",
                    "bodyText": "分享一组 3:4 纸感画册网格参考与字体比例",
                    "attachments": [
                        { "kind": "photo", "url": "https://sns-webpic-qc.xhscdn.com/a1.webp" },
                        { "kind": "photo", "url": "https://sns-webpic-qc.xhscdn.com/a2.webp" }
                    ]
                }]
            }))
            .send()
            .await
            .unwrap();
        assert_eq!(dup_res.status(), 200);
        let dup_json: Value = dup_res.json().await.unwrap();
        assert_eq!(dup_json["created"], 0);
        assert_eq!(dup_json["skipped"], 1);

        // 6. POST /api/v1/assets/upload (multipart/form-data)
        let boundary = "----CharkleTestBoundary7MA4YWxkTrZu0gW";
        let mut mp_body = Vec::new();
        mp_body.extend_from_slice(
            format!(
                "--{boundary}\r\nContent-Disposition: form-data; name=\"targetFolderID\"\r\n\r\n{folder_id}\r\n"
            )
            .as_bytes(),
        );
        mp_body.extend_from_slice(
            format!(
                "--{boundary}\r\nContent-Disposition: form-data; name=\"sourceURL\"\r\n\r\nhttps://example.com/gallery\r\n"
            )
            .as_bytes(),
        );
        mp_body.extend_from_slice(
            format!(
                "--{boundary}\r\nContent-Disposition: form-data; name=\"file\"; filename=\"clip.png\"\r\nContent-Type: image/png\r\n\r\n"
            )
            .as_bytes(),
        );
        mp_body.extend_from_slice(&cover_png);
        mp_body.extend_from_slice(format!("\r\n--{boundary}--\r\n").as_bytes());

        let upload_res = client
            .post(format!("{base}/api/v1/assets/upload"))
            .header("Authorization", &auth)
            .header(
                "Content-Type",
                format!("multipart/form-data; boundary={boundary}"),
            )
            .body(mp_body)
            .send()
            .await
            .unwrap();
        assert_eq!(upload_res.status(), 201);
        let upload_json: Value = upload_res.json().await.unwrap();
        assert_eq!(upload_json["created"], 1);
        assert_eq!(upload_json["assets"].as_array().unwrap().len(), 1);

        bridge.stop().await;
    }

    #[tokio::test]
    async fn bridge_stop_restart_rebinds_port_and_handles_chunked_and_trashed_reimport() {
        use crate::models::core::AssetBatchPatch;
        use tokio::io::{AsyncReadExt, AsyncWriteExt};
        use tokio::net::TcpStream;

        let dir = tempfile::tempdir().unwrap();
        let engine = Arc::new(LiveCharkleEngine::open(dir.path()).unwrap());
        let cfg = ExtensionBridgeConfig {
            enabled: true,
            allow_local_auto_pair: true,
            access_token: "11223344556677889900aabbccddeeff1122334455667788".to_string(),
        };

        // Pick a free ephemeral port, release it, then bind the bridge explicitly on that port
        let probe = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let fixed_port = probe.local_addr().unwrap().port();
        drop(probe);

        let bridge = LocalExtensionBridgeServer::with_options(
            Arc::clone(&engine),
            dir.path().to_path_buf(),
            cfg.clone(),
            fixed_port,
            false,
            None,
        );
        let st1 = bridge.start().await.unwrap();
        assert!(st1.running);
        assert_eq!(st1.port, fixed_port);

        // Stop and immediately restart on the exact same port (no AddrInUse)
        let stopped = bridge.stop().await;
        assert!(!stopped.running);
        let st2 = bridge.start().await.unwrap();
        assert!(st2.running);
        assert_eq!(st2.port, fixed_port);

        // Fragmented Transfer-Encoding: chunked POST to /api/v1/assets/ingest
        let payload = serde_json::to_string(&json!({
            "skipDuplicates": true,
            "inputs": [{
                "type": "textSnippet",
                "title": "Chunked Note",
                "text": "Split across TCP frames",
                "sourceURL": "https://example.com/chunked-article?utm_source=x"
            }]
        }))
        .unwrap();
        let mid = payload.len() / 2;
        let part1 = &payload[..mid];
        let part2 = &payload[mid..];

        let mut stream = TcpStream::connect(("127.0.0.1", fixed_port)).await.unwrap();
        let header = format!(
            "POST /api/v1/assets/ingest HTTP/1.1\r\nHost: 127.0.0.1:{fixed_port}\r\nAuthorization: Bearer {}\r\nContent-Type: application/json\r\nTransfer-Encoding: chunked\r\n\r\n",
            cfg.access_token
        );
        stream.write_all(header.as_bytes()).await.unwrap();
        stream.flush().await.unwrap();
        stream
            .write_all(format!("{:x}\r\n{}\r\n", part1.len(), part1).as_bytes())
            .await
            .unwrap();
        stream.flush().await.unwrap();
        stream
            .write_all(format!("{:x}\r\n{}\r\n0\r\n\r\n", part2.len(), part2).as_bytes())
            .await
            .unwrap();
        stream.flush().await.unwrap();

        let mut raw_resp = Vec::new();
        stream.read_to_end(&mut raw_resp).await.unwrap();
        let resp_str = String::from_utf8_lossy(&raw_resp);
        assert!(
            resp_str.starts_with("HTTP/1.1 201 Created"),
            "unexpected chunked response: {resp_str}"
        );

        let all_assets = engine.fetch_assets(&FilterCriteria::default()).unwrap();
        assert_eq!(all_assets.len(), 1);
        let first_id = all_assets[0].id;

        // Trash the asset -> re-importing the same sourceURL with skipDuplicates=true MUST succeed
        engine
            .update_assets(&AssetBatchPatch {
                asset_ids: vec![first_id],
                is_trashed: Some(true),
                ..Default::default()
            })
            .unwrap();

        let client = reqwest::Client::new();
        let reimport = client
            .post(format!(
                "http://127.0.0.1:{fixed_port}/api/v1/assets/ingest"
            ))
            .header("Authorization", format!("Bearer {}", cfg.access_token))
            .json(&json!({
                "skipDuplicates": true,
                "inputs": [{
                    "type": "textSnippet",
                    "title": "Chunked Note Reimported",
                    "text": "Restored via fresh import",
                    "sourceURL": "https://example.com/chunked-article"
                }]
            }))
            .send()
            .await
            .unwrap();
        assert_eq!(reimport.status(), 201);
        let body: Value = reimport.json().await.unwrap();
        assert_eq!(body["created"], 1);
        assert_eq!(body["skipped"], 0);

        bridge.stop().await;
    }

    #[tokio::test]
    async fn existing_sources_media_keys_exclude_web_bookmarks_and_parse_v130_social_jobs() {
        let (_tmp, engine, bridge, port, token) = spawn_test_bridge().await;
        let client = reqwest::Client::new();
        let base = format!("http://127.0.0.1:{port}");
        let auth = format!("Bearer {token}");

        // 1. Ingest a Pixiv socialBookmark (WebBookmark) -> appears in canonicalKeys, NOT mediaCanonicalKeys
        let cover_png = MediaArtwork::encode_png(&DynamicImage::ImageRgba8(RgbaImage::from_pixel(
            48,
            48,
            Rgba([0, 150, 250, 255]),
        )))
        .unwrap();
        let cover_data_url = format!("data:image/png;base64,{}", BASE64_STD.encode(&cover_png));

        let bm_res = client
            .post(format!("{base}/api/v1/assets/ingest"))
            .header("Authorization", &auth)
            .json(&json!({
                "skipDuplicates": true,
                "inputs": [{
                    "type": "socialBookmark",
                    "platform": "pixiv",
                    "originalURL": "https://www.pixiv.net/artworks/12556677",
                    "authorName": "青岚",
                    "authorHandle": "543210",
                    "articleTitle": "星夜水彩合集",
                    "bodyText": "水彩插画练习",
                    "coverDataUrl": cover_data_url,
                    "tags": ["水彩"]
                }]
            }))
            .send()
            .await
            .unwrap();
        assert_eq!(bm_res.status(), 201);

        let existing1: Value = client
            .get(format!("{base}/api/v1/assets/existing-sources"))
            .header("Authorization", &auth)
            .send()
            .await
            .unwrap()
            .json()
            .await
            .unwrap();
        let canonical1: Vec<&str> = existing1["canonicalKeys"]
            .as_array()
            .unwrap()
            .iter()
            .filter_map(Value::as_str)
            .collect();
        let media1: Vec<&str> = existing1["mediaCanonicalKeys"]
            .as_array()
            .unwrap()
            .iter()
            .filter_map(Value::as_str)
            .collect();
        assert!(canonical1.contains(&"pixiv:12556677"));
        assert!(
            !media1.contains(&"pixiv:12556677"),
            "WebBookmark must NOT pollute mediaCanonicalKeys"
        );

        // 2. Ingest an actual image asset whose sourceURL is the same Pixiv artwork -> now in mediaCanonicalKeys
        let img_res = client
            .post(format!("{base}/api/v1/assets/ingest"))
            .header("Authorization", &auth)
            .json(&json!({
                "inputs": [{
                    "type": "imageData",
                    "base64Data": cover_data_url,
                    "suggestedName": "pixiv_12556677_p0.png",
                    "sourceURL": "https://www.pixiv.net/en/artworks/12556677"
                }]
            }))
            .send()
            .await
            .unwrap();
        assert_eq!(img_res.status(), 201);

        let existing2: Value = client
            .get(format!("{base}/api/v1/assets/existing-sources"))
            .header("Authorization", &auth)
            .send()
            .await
            .unwrap()
            .json()
            .await
            .unwrap();
        let media2: Vec<&str> = existing2["mediaCanonicalKeys"]
            .as_array()
            .unwrap()
            .iter()
            .filter_map(Value::as_str)
            .collect();
        assert!(media2.contains(&"pixiv:12556677"));

        // 3. Re-submitting socialMedia with same dedupKey & skipDuplicates=true skips cleanly
        let dup_social = client
            .post(format!("{base}/api/v1/assets/ingest"))
            .header("Authorization", &auth)
            .json(&json!({
                "skipDuplicates": true,
                "inputs": [{
                    "type": "socialMedia",
                    "platform": "pixiv",
                    "postID": "12556677",
                    "dedupKey": "pixiv:12556677",
                    "originalURL": "https://www.pixiv.net/artworks/12556677",
                    "authorName": "青岚",
                    "authorHandle": "543210",
                    "media": [{ "kind": "photo", "url": "https://i.pximg.net/img-original/img/12556677_p0.png" }]
                }]
            }))
            .send()
            .await
            .unwrap();
        assert_eq!(dup_social.status(), 200);
        let dup_json: Value = dup_social.json().await.unwrap();
        assert_eq!(dup_json["skipped"], 1);
        assert_eq!(dup_json["created"], 0);
        assert_eq!(dup_json["postsImported"], 0);

        // 4. Unit-check socialMedia & legacy tweetMedia job parsing across all 6 platforms + Pixiv Referer
        let pixiv_obj = json!({
            "type": "socialMedia",
            "platform": "pixiv",
            "postID": "99887766",
            "originalURL": "https://www.pixiv.net/artworks/99887766",
            "authorName": "青岚",
            "authorHandle": "543210",
            "organizeMode": "multi_only",
            "referer": "https://www.pixiv.net/",
            "media": [{ "kind": "photo", "url": "https://i.pximg.net/img-original/img/99887766_p0.jpg" }]
        });
        let job_px = parse_social_media_job(pixiv_obj.as_object().unwrap()).unwrap();
        assert_eq!(job_px.platform, SocialPlatform::Pixiv);
        assert_eq!(job_px.dedup_key, "pixiv:99887766");
        assert_eq!(job_px.organize_mode, "multi_only");
        assert_eq!(
            SocialPostResolver::resolve_cdn_referer(
                &Url::parse(&job_px.media[0].url).unwrap(),
                None
            ),
            Some("https://www.pixiv.net/")
        );

        let ig_obj = json!({
            "type": "socialMedia",
            "platform": "instagram",
            "originalURL": "https://www.instagram.com/p/C9AbCdEfGhI/",
            "authorHandle": "@studio_ig",
            "media": [{ "kind": "photo", "url": "https://scontent.cdninstagram.com/v/t51/photo.jpg?sig=abc" }]
        });
        let job_ig = parse_social_media_job(ig_obj.as_object().unwrap()).unwrap();
        assert_eq!(job_ig.platform, SocialPlatform::Instagram);
        assert_eq!(job_ig.dedup_key, "ig:C9AbCdEfGhI");
        assert_eq!(job_ig.author_handle, "studio_ig");

        let legacy_x = json!({
            "type": "tweetMedia",
            "tweetID": "1889900112233445566",
            "originalURL": "https://x.com/artist_x/status/1889900112233445566",
            "authorHandle": "artist_x",
            "media": [{ "kind": "photo", "url": "https://pbs.twimg.com/media/AbCdEfG.jpg" }]
        });
        let job_x = parse_social_media_job(legacy_x.as_object().unwrap()).unwrap();
        assert_eq!(job_x.platform, SocialPlatform::X);
        assert_eq!(job_x.post_id, "1889900112233445566");
        assert_eq!(job_x.dedup_key, "x:1889900112233445566");

        let bsky_obj = json!({
            "type": "socialMedia",
            "platform": "bluesky",
            "originalURL": "https://bsky.app/profile/alice.bsky.social/post/3kabcdefg",
            "media": []
        });
        let job_bsky = parse_social_media_job(bsky_obj.as_object().unwrap()).unwrap();
        assert_eq!(job_bsky.platform, SocialPlatform::Bluesky);
        assert_eq!(job_bsky.dedup_key, "bsky:alice.bsky.social:3kabcdefg");

        let _ = engine;
        bridge.stop().await;
    }
}
