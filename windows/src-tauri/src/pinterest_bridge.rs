//! Persistent WebView2 Pinterest session bridge for Windows desktop.
//!
//! Mirrors `Sources/CharkleCore/Services/Pinterest/PinterestSessionBridge.swift` &
//! `Sources/CharkleApp/Views/Pinterest/PinterestLoginSheetMac.swift`:
//! - Shares one persistent non-incognito WebView2 profile directory (`<data_dir>/pinterest-webview2`)
//!   between the visible login window (`pinterest-login`) and the hidden warm background bridge
//!   (`pinterest-bridge`) so Pinterest login cookies survive app restarts.
//! - Uses native WebView2 child popups (`window.open`) inside the same WebView2 environment so
//!   Google / Apple OAuth callbacks (`window.opener.postMessage`) complete reliably.
//! - Executes same-origin `fetch()` calls with `X-CSRFToken` inside `https://www.pinterest.com/`
//!   and resolves async responses deterministically via `ICoreWebView2::add_WebMessageReceived`.

#![allow(unsafe_code)]

use std::collections::{HashMap, HashSet};
use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use charkle_core::error::{CoreError, CoreResult};
use charkle_core::pinterest::{
    PinterestAccount, PinterestBoard, PinterestFeedPage, PinterestFeedSource, PinterestJSONParser,
    PinterestPin, PinterestPinDetailResult,
};
use serde::Deserialize;
use serde_json::{json, Map, Value};
use tauri::webview::PageLoadEvent;
use tauri::{AppHandle, Emitter, Manager, WebviewUrl, WebviewWindowBuilder, WindowEvent};
use tokio::sync::{oneshot, Mutex as AsyncMutex};
use url::Url;
use uuid::Uuid;

const PINTEREST_LOGIN_LABEL: &str = "pinterest-login";
const PINTEREST_BRIDGE_LABEL: &str = "pinterest-bridge";
const PINTEREST_ORIGIN: &str = "https://www.pinterest.com/";
const PINTEREST_LOGIN_URL: &str = "https://www.pinterest.com/login/";
const PINTEREST_BROWSER_UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36";

const PINTEREST_ALLOWED_DOMAINS: &[&str] = &[
    "pinterest.com",
    "pinterest.co.uk",
    "pinterest.jp",
    "pinterest.de",
    "pinterest.fr",
    "pinterest.es",
    "pinterest.it",
    "pinterest.ca",
    "pinterest.com.au",
    "pinterest.com.mx",
    "pinterest.com.br",
    "pinterest.ph",
    "pinterest.pt",
    "pinterest.se",
    "pinterest.ch",
    "pinterest.at",
    "pinterest.cl",
    "pinterest.ie",
    "pinterest.nz",
    "pinterest.dk",
    "pinterest.co.kr",
    "pinterest.ru",
    "pinterest.tw",
    "pinterest.nl",
    "pinterest.be",
    "pinterest.pl",
    "pinterest.in",
    "pinterest.co.in",
    "pinterest.sg",
    "pinterest.hk",
];

fn is_pinterest_host(raw_host: &str) -> bool {
    let host = raw_host.trim().trim_end_matches('.').to_ascii_lowercase();
    PINTEREST_ALLOWED_DOMAINS.iter().any(|domain| {
        host == *domain
            || (host.len() > domain.len()
                && host.ends_with(domain)
                && host.as_bytes()[host.len() - domain.len() - 1] == b'.')
    })
}

fn is_safe_pinterest_token(raw: &str) -> bool {
    !raw.is_empty()
        && raw.len() <= 128
        && !raw.contains("..")
        && raw
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'_' | b'-' | b'.'))
}

#[derive(Debug, Deserialize)]
struct RpcWireMessage {
    #[serde(rename = "__charklePinRpc")]
    magic: bool,
    id: String,
    #[serde(default)]
    status: u16,
    #[serde(default)]
    body: String,
    #[serde(default)]
    error: Option<String>,
}

#[derive(Debug, Clone)]
struct RpcReply {
    status: u16,
    body: String,
    error: Option<String>,
}

#[derive(Debug, Clone, Copy, Default)]
struct CookieAuthState {
    has_session: bool,
    has_auth_one: bool,
}

pub struct PinterestSessionBridge {
    app: AppHandle,
    profile_dir: PathBuf,
    bridge_init_lock: Arc<AsyncMutex<()>>,
    pending_rpc: Arc<Mutex<HashMap<String, oneshot::Sender<RpcReply>>>>,
}

impl PinterestSessionBridge {
    pub fn new(app: AppHandle, data_dir: PathBuf) -> Self {
        let profile_dir = data_dir.join("pinterest-webview2");
        let _ = std::fs::create_dir_all(&profile_dir);
        Self {
            app,
            profile_dir,
            bridge_init_lock: Arc::new(AsyncMutex::new(())),
            pending_rpc: Arc::new(Mutex::new(HashMap::new())),
        }
    }

    /// Opens or focuses the visible native WebView2 Pinterest login window.
    pub fn open_login_window(&self) -> CoreResult<()> {
        if let Some(existing) = self.app.get_webview_window(PINTEREST_LOGIN_LABEL) {
            let _ = existing.unminimize();
            let _ = existing.show();
            let _ = existing.set_focus();
            return Ok(());
        }

        let _ = std::fs::create_dir_all(&self.profile_dir);
        let login_url = Url::parse(PINTEREST_LOGIN_URL)
            .map_err(|e| CoreError::InvalidPayload(format!("Invalid login URL: {e}")))?;

        let app_for_load = self.app.clone();
        let app_for_close = self.app.clone();
        let win = WebviewWindowBuilder::new(
            &self.app,
            PINTEREST_LOGIN_LABEL,
            WebviewUrl::External(login_url),
        )
        .title("登录 Pinterest")
        .inner_size(1040.0, 740.0)
        .min_inner_size(760.0, 560.0)
        .center()
        .resizable(true)
        .visible(true)
        .focused(true)
        .data_directory(self.profile_dir.clone())
        .user_agent(PINTEREST_BROWSER_UA)
        .on_page_load(move |_win, payload| {
            if matches!(payload.event(), PageLoadEvent::Finished) {
                let url = payload.url();
                let host = url.host_str().unwrap_or_default().to_ascii_lowercase();
                let path = url.path().to_ascii_lowercase();
                if url.scheme() == "https"
                    && is_pinterest_host(&host)
                    && !path.contains("/login")
                    && !path.contains("/oauth")
                    && !path.contains("/connect")
                {
                    let _ = app_for_load.emit("pinterest:auth-changed", true);
                }
            }
        })
        .build()
        .map_err(|e| CoreError::InvalidOperation(format!("无法打开 Pinterest 登录窗口：{e}")))?;

        win.on_window_event(move |event| {
            if matches!(event, WindowEvent::Destroyed) {
                let _ = app_for_close.emit("pinterest:auth-changed", false);
            }
        });

        Ok(())
    }

    pub fn close_login_window(&self) {
        if let Some(win) = self.app.get_webview_window(PINTEREST_LOGIN_LABEL) {
            let _ = win.close();
        }
    }

    pub fn destroy_all_windows(&self) {
        for label in [PINTEREST_LOGIN_LABEL, PINTEREST_BRIDGE_LABEL] {
            if let Some(win) = self.app.get_webview_window(label) {
                let _ = win.destroy();
            }
        }
    }

    // MARK: - Session & Auth

    pub async fn check_session_account(&self) -> CoreResult<Option<PinterestAccount>> {
        let win = self.ensure_bridge_window().await?;
        let cookies = self.inspect_cookies(&win).await;
        if !cookies.has_session {
            return Ok(None);
        }

        // 1. Primary endpoint: UserSettingsResource
        if let Ok((status, data)) = self
            .fetch_resource_raw(
                "/resource/UserSettingsResource/get/",
                "/settings/",
                json!({}),
            )
            .await
        {
            if (200..300).contains(&status) {
                if let Some(account) = PinterestJSONParser::parse_account(&data) {
                    return Ok(Some(account));
                }
            }
        }

        // 2. Fallback: live DOM hydration props
        if let Some(account) = self.extract_account_from_bridge_dom(&win).await {
            return Ok(Some(account));
        }

        // 3. Fallback: UserResource
        if let Ok((status, data)) = self
            .fetch_resource_raw("/resource/UserResource/get/", "/", json!({}))
            .await
        {
            if (200..300).contains(&status) {
                if let Some(account) = PinterestJSONParser::parse_account(&data) {
                    return Ok(Some(account));
                }
            }
        }

        // 4. Final fallback: authenticated `_auth=1` cookie + live Homefeed probe
        if cookies.has_auth_one {
            if let Ok(probe) = self.fetch_home_feed(None, 6).await {
                if !probe.pins.is_empty() {
                    return Ok(Some(PinterestAccount {
                        id: "pinterest-active-session".to_string(),
                        username: String::new(),
                        full_name: "Pinterest 账号".to_string(),
                        avatar_url: None,
                        email: None,
                    }));
                }
            }
        }

        Ok(None)
    }

    pub async fn sign_out(&self) -> CoreResult<()> {
        self.close_login_window();
        if let Ok(win) = self.ensure_bridge_window().await {
            let _ = self.clear_pinterest_cookies(&win).await;
        }
        // Destroy the background bridge window so subsequent logins start fresh.
        let app = self.app.clone();
        let _ = self.app.run_on_main_thread(move || {
            if let Some(win) = app.get_webview_window(PINTEREST_BRIDGE_LABEL) {
                let _ = win.destroy();
            }
        });
        if let Ok(mut pending) = self.pending_rpc.lock() {
            pending.clear();
        }
        Ok(())
    }

    // MARK: - Feeds, Boards & Pin Detail

    pub async fn fetch_feed(
        &self,
        source: &PinterestFeedSource,
        bookmark: Option<&str>,
        page_size: usize,
    ) -> CoreResult<PinterestFeedPage> {
        match source {
            PinterestFeedSource::Home => self.fetch_home_feed(bookmark, page_size).await,
            PinterestFeedSource::Search { query } => {
                self.fetch_search_feed(query, bookmark, page_size).await
            }
            PinterestFeedSource::Board { board } => {
                self.fetch_board_feed(board, bookmark, page_size, true)
                    .await
            }
            PinterestFeedSource::Similar { seed_pin } => {
                self.fetch_similar_pins(seed_pin, bookmark, page_size).await
            }
        }
    }

    async fn fetch_home_feed(
        &self,
        bookmark: Option<&str>,
        page_size: usize,
    ) -> CoreResult<PinterestFeedPage> {
        let mut options = Map::new();
        options.insert("isPrefetch".to_string(), json!(false));
        options.insert("field_set_key".to_string(), json!("hf_grid_partner"));
        options.insert("in_nux".to_string(), json!(false));
        options.insert("prependPartner".to_string(), json!(false));
        options.insert("prependUserNews".to_string(), json!(false));
        options.insert("static_feed".to_string(), json!(false));
        options.insert("page_size".to_string(), json!(page_size));
        if let Some(bm) = bookmark.filter(|s| !s.is_empty()) {
            options.insert("bookmarks".to_string(), json!([bm]));
        }

        let (status, data) = self
            .fetch_resource_raw(
                "/resource/UserHomefeedResource/get/",
                "/",
                Value::Object(options),
            )
            .await?;
        Self::validate_status(status)?;

        let mut page = PinterestJSONParser::parse_feed_page(&data, "主页推荐");
        if page.pins.is_empty() && bookmark.is_none() {
            let mut retry_opts = Map::new();
            retry_opts.insert("page_size".to_string(), json!(page_size));
            if let Ok((retry_status, retry_data)) = self
                .fetch_resource_raw(
                    "/resource/UserHomefeedResource/get/",
                    "/",
                    Value::Object(retry_opts),
                )
                .await
            {
                if (200..300).contains(&retry_status) {
                    let retry_page = PinterestJSONParser::parse_feed_page(&retry_data, "主页推荐");
                    if !retry_page.pins.is_empty() {
                        page = retry_page;
                    }
                }
            }
        }

        if page.pins.is_empty() && bookmark.is_none() {
            if let Ok(win) = self.ensure_bridge_window().await {
                if let Some(html) = self.read_bridge_html(&win).await {
                    let html_page = PinterestJSONParser::parse_pins_from_html(&html, "主页推荐");
                    if !html_page.pins.is_empty() {
                        return Ok(html_page);
                    }
                }
            }
        }

        Ok(page)
    }

    async fn fetch_search_feed(
        &self,
        query: &str,
        bookmark: Option<&str>,
        page_size: usize,
    ) -> CoreResult<PinterestFeedPage> {
        let trimmed = query.trim();
        if trimmed.is_empty() {
            return Ok(PinterestFeedPage {
                pins: Vec::new(),
                next_bookmark: None,
                has_more: false,
                source_description: "搜索".to_string(),
            });
        }
        let encoded: String = url::form_urlencoded::byte_serialize(trimmed.as_bytes()).collect();
        let source_url = format!("/search/pins/?q={encoded}");
        let mut options = Map::new();
        options.insert("query".to_string(), json!(trimmed));
        options.insert("scope".to_string(), json!("pins"));
        options.insert("rs".to_string(), json!("typed"));
        options.insert("auto_correction_disabled".to_string(), json!(false));
        options.insert("redux_normalize_feed".to_string(), json!(true));
        options.insert("page_size".to_string(), json!(page_size));
        if let Some(bm) = bookmark.filter(|s| !s.is_empty()) {
            options.insert("bookmarks".to_string(), json!([bm]));
        }

        let (status, data) = self
            .fetch_resource_raw(
                "/resource/BaseSearchResource/get/",
                &source_url,
                Value::Object(options),
            )
            .await?;
        Self::validate_status(status)?;
        Ok(PinterestJSONParser::parse_feed_page(
            &data,
            &format!("搜索：{trimmed}"),
        ))
    }

    async fn fetch_board_feed(
        &self,
        board: &PinterestBoard,
        bookmark: Option<&str>,
        page_size: usize,
        filter_section_pins: bool,
    ) -> CoreResult<PinterestFeedPage> {
        let board_url = board.normalized_url_path();
        let mut options = Map::new();
        options.insert("board_id".to_string(), json!(board.id));
        options.insert("board_url".to_string(), json!(board_url));
        options.insert("currentFilter".to_string(), json!(-1));
        options.insert("field_set_key".to_string(), json!("react_grid_pin"));
        options.insert(
            "filter_section_pins".to_string(),
            json!(filter_section_pins),
        );
        options.insert("sort".to_string(), json!("default"));
        options.insert("layout".to_string(), json!("default"));
        options.insert("page_size".to_string(), json!(page_size));
        options.insert("redux_normalize_feed".to_string(), json!(true));
        if let Some(bm) = bookmark.filter(|s| !s.is_empty()) {
            options.insert("bookmarks".to_string(), json!([bm]));
        }

        let (status, data) = self
            .fetch_resource_raw(
                "/resource/BoardFeedResource/get/",
                &board_url,
                Value::Object(options),
            )
            .await?;
        Self::validate_status(status)?;
        Ok(PinterestJSONParser::parse_feed_page(
            &data,
            &format!("画板：{}", board.name),
        ))
    }

    pub async fn fetch_user_boards(&self, username: &str) -> CoreResult<Vec<PinterestBoard>> {
        let clean_user = username.trim().trim_start_matches('@');
        if clean_user.is_empty() {
            return Ok(Vec::new());
        }
        if !is_safe_pinterest_token(clean_user) {
            return Err(CoreError::InvalidPayload(
                "Invalid Pinterest username".to_string(),
            ));
        }

        let mut all_boards: Vec<PinterestBoard> = Vec::new();
        let mut seen_ids: HashSet<String> = HashSet::new();
        let mut bookmark: Option<String> = None;

        for _ in 0..16 {
            let mut options = Map::new();
            options.insert("isPrefetch".to_string(), json!(false));
            options.insert("privacy_filter".to_string(), json!("all"));
            options.insert("sort".to_string(), json!("last_pinned_to"));
            options.insert("field_set_key".to_string(), json!("profile_grid_item"));
            options.insert("username".to_string(), json!(clean_user));
            options.insert("page_size".to_string(), json!(50));
            options.insert("group_by".to_string(), json!("visibility"));
            options.insert("include_archived".to_string(), json!(false));
            options.insert("redux_normalize_feed".to_string(), json!(true));
            if let Some(ref bm) = bookmark {
                options.insert("bookmarks".to_string(), json!([bm]));
            }

            let (status, data) = self
                .fetch_resource_raw(
                    "/resource/BoardsResource/get/",
                    &format!("/{clean_user}/"),
                    Value::Object(options),
                )
                .await?;
            Self::validate_status(status)?;

            let page = PinterestJSONParser::parse_boards_page(&data);
            for board in page.boards {
                if seen_ids.insert(board.id.clone()) {
                    all_boards.push(board);
                }
            }

            match page.next_bookmark {
                Some(next) if page.has_more && Some(&next) != bookmark.as_ref() => {
                    bookmark = Some(next);
                }
                _ => break,
            }
        }

        all_boards.sort_by_key(|b| std::cmp::Reverse(b.pin_count));
        Ok(all_boards)
    }

    pub async fn fetch_all_board_pins(
        &self,
        board: &PinterestBoard,
        max_pins: usize,
    ) -> CoreResult<Vec<PinterestPin>> {
        let mut collected: Vec<PinterestPin> = Vec::new();
        let mut seen_ids: HashSet<String> = HashSet::new();
        let mut bookmark: Option<String> = None;

        for _ in 0..48 {
            if collected.len() >= max_pins {
                break;
            }
            let page = self
                .fetch_board_feed(board, bookmark.as_deref(), 50, false)
                .await?;

            let mut added = 0usize;
            for mut pin in page.pins {
                if collected.len() >= max_pins {
                    break;
                }
                if seen_ids.insert(pin.id.clone()) {
                    if pin
                        .board_name
                        .as_deref()
                        .map(str::trim)
                        .unwrap_or("")
                        .is_empty()
                    {
                        pin.board_name = Some(board.name.clone());
                    }
                    if pin.board_id.is_none() {
                        pin.board_id = Some(board.id.clone());
                    }
                    collected.push(pin);
                    added += 1;
                }
            }

            if !page.has_more || added == 0 {
                break;
            }
            match page.next_bookmark {
                Some(next) if Some(&next) != bookmark.as_ref() => {
                    bookmark = Some(next);
                }
                _ => break,
            }
        }

        Ok(collected)
    }

    pub async fn fetch_pin_detail_and_similar(
        &self,
        pin: &PinterestPin,
    ) -> CoreResult<PinterestPinDetailResult> {
        if !is_safe_pinterest_token(pin.id.trim()) {
            return Err(CoreError::InvalidPayload(
                "Invalid Pinterest pin ID".to_string(),
            ));
        }
        let mut detailed = pin.clone();
        if let Ok((status, data)) = self
            .fetch_resource_raw(
                "/resource/PinResource/get/",
                &format!("/pin/{}/", pin.id),
                json!({
                    "id": pin.id,
                    "field_set_key": "detailed"
                }),
            )
            .await
        {
            if (200..300).contains(&status) {
                if let Some(parsed) = PinterestJSONParser::parse_single_pin(&data) {
                    detailed = parsed;
                }
            }
        }

        let similar_page = self.fetch_similar_pins(&detailed, None, 28).await?;
        let filtered_similar: Vec<PinterestPin> = similar_page
            .pins
            .into_iter()
            .filter(|p| p.id != detailed.id)
            .collect();

        Ok(PinterestPinDetailResult {
            pin: detailed,
            similar_pins: filtered_similar,
            next_similar_bookmark: similar_page.next_bookmark,
            has_more_similar: similar_page.has_more,
        })
    }

    pub async fn fetch_similar_pins(
        &self,
        pin: &PinterestPin,
        bookmark: Option<&str>,
        page_size: usize,
    ) -> CoreResult<PinterestFeedPage> {
        if !is_safe_pinterest_token(pin.id.trim()) {
            return Err(CoreError::InvalidPayload(
                "Invalid Pinterest pin ID".to_string(),
            ));
        }
        let source_url = format!("/pin/{}/", pin.id.trim());

        // 1. Primary: RelatedModulesResource
        let mut primary_opts = Map::new();
        primary_opts.insert("pin_id".to_string(), json!(pin.id));
        primary_opts.insert("context_pin_ids".to_string(), json!([]));
        primary_opts.insert("page_size".to_string(), json!(page_size));
        primary_opts.insert("search_query".to_string(), json!(""));
        primary_opts.insert("source".to_string(), json!("deep_link"));
        primary_opts.insert("top_level_source".to_string(), json!("deep_link"));
        primary_opts.insert("top_level_source_depth".to_string(), json!(1));
        primary_opts.insert("is_pdp".to_string(), json!(false));
        if let Some(bm) = bookmark.filter(|s| !s.is_empty()) {
            primary_opts.insert("bookmarks".to_string(), json!([bm]));
        }

        if let Ok((status, data)) = self
            .fetch_resource_raw(
                "/resource/RelatedModulesResource/get/",
                &source_url,
                Value::Object(primary_opts),
            )
            .await
        {
            if status == 401 || status == 403 {
                Self::validate_status(status)?;
            }
            if (200..300).contains(&status) {
                let page = PinterestJSONParser::parse_feed_page(&data, "相似灵感");
                if !page.pins.is_empty() {
                    return Ok(page);
                }
            }
        }

        // 2. Fallback: RelatedPinFeedResource
        let mut fallback_opts = Map::new();
        fallback_opts.insert("pin".to_string(), json!(pin.id));
        fallback_opts.insert("field_set_key".to_string(), json!("grid_item"));
        fallback_opts.insert("prepend".to_string(), json!(false));
        fallback_opts.insert("page_size".to_string(), json!(page_size));
        if let Some(bm) = bookmark.filter(|s| !s.is_empty()) {
            fallback_opts.insert("bookmarks".to_string(), json!([bm]));
        }

        if let Ok((status, data)) = self
            .fetch_resource_raw(
                "/resource/RelatedPinFeedResource/get/",
                &source_url,
                Value::Object(fallback_opts),
            )
            .await
        {
            if status == 401 || status == 403 {
                Self::validate_status(status)?;
            }
            if (200..300).contains(&status) {
                let page = PinterestJSONParser::parse_feed_page(&data, "相似灵感");
                if !page.pins.is_empty() {
                    return Ok(page);
                }
            }
        }

        // 3. Final fallback: keyword search seeded by pin title or board name
        if bookmark.is_none() {
            let seed_raw = if !pin.title.trim().is_empty() {
                pin.title.trim()
            } else {
                pin.board_name.as_deref().unwrap_or("").trim()
            };
            let seed: String = seed_raw.chars().take(48).collect();
            if !seed.is_empty() {
                if let Ok(search_page) = self.fetch_search_feed(&seed, None, page_size).await {
                    let filtered: Vec<PinterestPin> = search_page
                        .pins
                        .into_iter()
                        .filter(|p| p.id != pin.id)
                        .collect();
                    return Ok(PinterestFeedPage {
                        pins: filtered,
                        next_bookmark: search_page.next_bookmark,
                        has_more: search_page.has_more,
                        source_description: "相似灵感".to_string(),
                    });
                }
            }
        }

        Ok(PinterestFeedPage {
            pins: Vec::new(),
            next_bookmark: None,
            has_more: false,
            source_description: "相似灵感".to_string(),
        })
    }

    // MARK: - Low-Level WebView2 Same-Origin Bridge

    fn validate_status(status: u16) -> CoreResult<()> {
        if status == 401 || status == 403 {
            return Err(CoreError::AuthenticationRequired(
                "Pinterest 登录状态已失效，请重新登录。".to_string(),
            ));
        }
        if !(200..300).contains(&status) {
            return Err(CoreError::Http {
                status_code: status,
                message: format!("Pinterest 请求失败（HTTP {status}）"),
            });
        }
        Ok(())
    }

    async fn fetch_resource_raw(
        &self,
        resource_path: &str,
        source_url: &str,
        options: Value,
    ) -> CoreResult<(u16, Vec<u8>)> {
        let win = self.ensure_bridge_window().await?;
        let payload = json!({
            "options": options,
            "context": {}
        });
        let data_json = serde_json::to_string(&payload)
            .map_err(|e| CoreError::InvalidPayload(e.to_string()))?;

        let resource_path_json = serde_json::to_string(resource_path)
            .map_err(|e| CoreError::InvalidPayload(e.to_string()))?;
        let source_url_json = serde_json::to_string(source_url)
            .map_err(|e| CoreError::InvalidPayload(e.to_string()))?;
        let data_arg_json = serde_json::to_string(&data_json)
            .map_err(|e| CoreError::InvalidPayload(e.to_string()))?;

        let script = format!(
            r#"(async () => {{
                const resourcePath = {resource_path_json};
                const sourceURL = {source_url_json};
                const dataJSON = {data_arg_json};
                const cookieMatch = document.cookie.match(/(?:^|;\s*)csrftoken=([^;]+)/);
                const csrf = cookieMatch ? decodeURIComponent(cookieMatch[1]) : '';
                const params = new URLSearchParams();
                params.set('source_url', sourceURL);
                params.set('data', dataJSON);
                params.set('_', String(Date.now()));
                const url = resourcePath + '?' + params.toString();
                const headers = {{
                    'Accept': 'application/json, text/javascript, */*, q=0.01',
                    'X-Requested-With': 'XMLHttpRequest',
                    'X-Pinterest-AppState': 'active',
                    'X-Pinterest-Source-Url': sourceURL,
                    'X-Pinterest-PWS-Handler': 'www/index.js'
                }};
                if (csrf) headers['X-CSRFToken'] = csrf;
                const resp = await fetch(url, {{
                    method: 'GET',
                    credentials: 'include',
                    headers
                }});
                const text = await resp.text();
                return {{ status: resp.status, body: text }};
            }})()"#
        );

        let reply = self.run_bridge_rpc(&win, &script).await?;
        if let Some(err) = reply.error {
            return Err(CoreError::InvalidOperation(format!(
                "Pinterest 页面通信失败：{err}"
            )));
        }
        Ok((reply.status, reply.body.into_bytes()))
    }

    async fn extract_account_from_bridge_dom(
        &self,
        win: &tauri::WebviewWindow,
    ) -> Option<PinterestAccount> {
        let script = r#"(async () => {
            const scripts = [
                document.getElementById('__PWS_INITIAL_PROPS__'),
                document.getElementById('__PWS_DATA__'),
                ...Array.from(document.querySelectorAll('script[data-relay-response="true"]'))
            ].filter(Boolean);
            for (const s of scripts) {
                try {
                    const obj = JSON.parse(s.textContent || '');
                    const queue = [obj];
                    let visited = 0;
                    while (queue.length && visited < 400) {
                        const cur = queue.shift();
                        visited++;
                        if (!cur || typeof cur !== 'object') continue;
                        if (typeof cur.username === 'string' && cur.username.length > 0 &&
                            (cur.full_name || cur.is_authenticated || cur.email || cur.image_medium_url)) {
                            return { status: 200, body: JSON.stringify(cur) };
                        }
                        for (const v of Object.values(cur)) {
                            if (v && typeof v === 'object') queue.push(v);
                        }
                    }
                } catch (_) {}
            }
            return { status: 204, body: '' };
        })()"#;

        let reply = self.run_bridge_rpc(win, script).await.ok()?;
        if reply.body.trim().is_empty() {
            return None;
        }
        PinterestJSONParser::parse_account(reply.body.as_bytes())
    }

    async fn read_bridge_html(&self, win: &tauri::WebviewWindow) -> Option<String> {
        let script = r#"(async () => ({ status: 200, body: document.documentElement ? document.documentElement.outerHTML : '' }))()"#;
        let reply = self.run_bridge_rpc(win, script).await.ok()?;
        (!reply.body.is_empty()).then_some(reply.body)
    }

    async fn ensure_bridge_window(&self) -> CoreResult<tauri::WebviewWindow> {
        if let Some(existing) = self.app.get_webview_window(PINTEREST_BRIDGE_LABEL) {
            return Ok(existing);
        }

        let _guard = self.bridge_init_lock.lock().await;
        if let Some(existing) = self.app.get_webview_window(PINTEREST_BRIDGE_LABEL) {
            return Ok(existing);
        }

        let _ = std::fs::create_dir_all(&self.profile_dir);
        let origin_url = Url::parse(PINTEREST_ORIGIN)
            .map_err(|e| CoreError::InvalidPayload(format!("Invalid origin URL: {e}")))?;

        let (loaded_tx, loaded_rx) = oneshot::channel::<()>();
        let loaded_slot = Arc::new(Mutex::new(Some(loaded_tx)));

        let win = WebviewWindowBuilder::new(
            &self.app,
            PINTEREST_BRIDGE_LABEL,
            WebviewUrl::External(origin_url),
        )
        .title("")
        .inner_size(1200.0, 820.0)
        .position(-32000.0, -32000.0)
        .decorations(false)
        .shadow(false)
        .resizable(false)
        .visible(false)
        .focused(false)
        .skip_taskbar(true)
        .disable_drag_drop_handler()
        .data_directory(self.profile_dir.clone())
        .user_agent(PINTEREST_BROWSER_UA)
        .on_page_load(move |_win, payload| {
            if matches!(payload.event(), PageLoadEvent::Finished) {
                if let Ok(mut slot) = loaded_slot.lock() {
                    if let Some(tx) = slot.take() {
                        let _ = tx.send(());
                    }
                }
            }
        })
        .build()
        .map_err(|e| CoreError::InvalidOperation(format!("无法初始化 Pinterest 会话窗口：{e}")))?;

        self.attach_bridge_handlers(&win).await?;

        let _ = tokio::time::timeout(Duration::from_secs(15), loaded_rx).await;
        tokio::time::sleep(Duration::from_millis(320)).await;
        Ok(win)
    }

    #[cfg(target_os = "windows")]
    async fn attach_bridge_handlers(&self, win: &tauri::WebviewWindow) -> CoreResult<()> {
        use webview2_com::Microsoft::Web::WebView2::Win32::ICoreWebView2_8;
        use webview2_com::WebMessageReceivedEventHandler;
        use windows::core::{Interface, PWSTR};
        use windows::Win32::System::Com::CoTaskMemFree;

        let pending = Arc::clone(&self.pending_rpc);
        let (done_tx, done_rx) = oneshot::channel::<Result<(), String>>();
        let done_slot = Arc::new(Mutex::new(Some(done_tx)));

        let dispatch = win.with_webview(move |platform_wv| {
            let controller = platform_wv.controller();
            let result = (|| -> Result<(), String> {
                // SAFETY: Running inside Tauri's `with_webview` callback on the UI STA thread.
                let core = unsafe { controller.CoreWebView2() }.map_err(|e| e.to_string())?;
                if let Ok(core8) = core.cast::<ICoreWebView2_8>() {
                    // SAFETY: `core8` is a valid `ICoreWebView2_8` interface on the UI thread.
                    let _ = unsafe { core8.SetIsMuted(true) };
                }

                let pending_cb = Arc::clone(&pending);
                let handler = WebMessageReceivedEventHandler::create(Box::new(move |_wv, args| {
                    if let Some(args) = args {
                        // Strictly verify that the WebMessage originated from an HTTPS Pinterest origin.
                        let mut source_ptr = PWSTR::null();
                        let source_allowed = if unsafe { args.Source(&mut source_ptr) }.is_ok()
                            && !source_ptr.is_null()
                        {
                            // SAFETY: `source_ptr` was allocated by WebView2 via CoTaskMemAlloc.
                            let source_url = unsafe { source_ptr.to_string() }.unwrap_or_default();
                            unsafe { CoTaskMemFree(Some(source_ptr.0 as _)) };
                            Url::parse(&source_url).ok().is_some_and(|u| {
                                u.scheme() == "https"
                                    && is_pinterest_host(u.host_str().unwrap_or_default())
                            })
                        } else {
                            false
                        };
                        if !source_allowed {
                            return Ok(());
                        }

                        let mut raw = PWSTR::null();
                        // SAFETY: `raw` receives a CoTaskMem-allocated UTF-16 string freed immediately below.
                        if unsafe { args.TryGetWebMessageAsString(&mut raw) }.is_ok()
                            && !raw.is_null()
                        {
                            let text = unsafe { raw.to_string() }.unwrap_or_default();
                            unsafe { CoTaskMemFree(Some(raw.0 as _)) };
                            if let Ok(msg) = serde_json::from_str::<RpcWireMessage>(&text) {
                                if msg.magic {
                                    if let Ok(mut map) = pending_cb.lock() {
                                        if let Some(tx) = map.remove(&msg.id) {
                                            let _ = tx.send(RpcReply {
                                                status: msg.status,
                                                body: msg.body,
                                                error: msg.error,
                                            });
                                        }
                                    }
                                }
                            }
                        }
                    }
                    Ok(())
                }));

                let mut token: i64 = 0;
                // SAFETY: `handler` is a COM-refcounted WebView2 callback kept alive by `core`.
                unsafe { core.add_WebMessageReceived(&handler, &mut token) }
                    .map_err(|e| e.to_string())?;
                Ok(())
            })();

            if let Ok(mut slot) = done_slot.lock() {
                if let Some(tx) = slot.take() {
                    let _ = tx.send(result);
                }
            }
        });

        if let Err(err) = dispatch {
            return Err(CoreError::InvalidOperation(format!(
                "无法绑定 Pinterest WebView2 消息桥：{err}"
            )));
        }

        match tokio::time::timeout(Duration::from_secs(5), done_rx).await {
            Ok(Ok(Ok(()))) => Ok(()),
            Ok(Ok(Err(msg))) => Err(CoreError::InvalidOperation(msg)),
            _ => Err(CoreError::InvalidOperation(
                "绑定 Pinterest WebView2 消息桥超时".to_string(),
            )),
        }
    }

    #[cfg(not(target_os = "windows"))]
    async fn attach_bridge_handlers(&self, _win: &tauri::WebviewWindow) -> CoreResult<()> {
        Ok(())
    }

    #[cfg(target_os = "windows")]
    async fn run_bridge_rpc(
        &self,
        win: &tauri::WebviewWindow,
        async_iife_js: &str,
    ) -> CoreResult<RpcReply> {
        use webview2_com::ExecuteScriptCompletedHandler;
        use windows::core::HSTRING;

        struct PendingRpcGuard {
            pending: Arc<Mutex<HashMap<String, oneshot::Sender<RpcReply>>>>,
            req_id: String,
        }
        impl Drop for PendingRpcGuard {
            fn drop(&mut self) {
                if let Ok(mut map) = self.pending.lock() {
                    map.remove(&self.req_id);
                }
            }
        }

        let req_id = Uuid::new_v4().simple().to_string();
        let (tx, rx) = oneshot::channel::<RpcReply>();
        if let Ok(mut map) = self.pending_rpc.lock() {
            map.insert(req_id.clone(), tx);
        }
        let _pending_guard = PendingRpcGuard {
            pending: Arc::clone(&self.pending_rpc),
            req_id: req_id.clone(),
        };

        let req_id_json =
            serde_json::to_string(&req_id).map_err(|e| CoreError::InvalidPayload(e.to_string()))?;
        let wrapped = format!(
            r#"(function() {{
                const __reqId = {req_id_json};
                Promise.resolve().then(() => {async_iife_js}).then((res) => {{
                    window.chrome.webview.postMessage(JSON.stringify({{
                        __charklePinRpc: true,
                        id: __reqId,
                        status: (res && typeof res.status === 'number') ? res.status : 200,
                        body: (res && typeof res.body === 'string') ? res.body : ''
                    }}));
                }}).catch((err) => {{
                    window.chrome.webview.postMessage(JSON.stringify({{
                        __charklePinRpc: true,
                        id: __reqId,
                        status: 0,
                        body: '',
                        error: String(err && err.message ? err.message : err)
                    }}));
                }});
            }})();"#
        );

        let script_hstring = HSTRING::from(wrapped);
        let pending_for_exec = Arc::clone(&self.pending_rpc);
        let req_id_for_exec = req_id.clone();
        let dispatch_err = win.with_webview(move |platform_wv| {
            let controller = platform_wv.controller();
            let fail_pending = |msg: String| {
                if let Ok(mut map) = pending_for_exec.lock() {
                    if let Some(sender) = map.remove(&req_id_for_exec) {
                        let _ = sender.send(RpcReply {
                            status: 0,
                            body: String::new(),
                            error: Some(msg),
                        });
                    }
                }
            };
            // SAFETY: Executing on the WebView2 UI thread inside `with_webview`.
            let Ok(core) = (unsafe { controller.CoreWebView2() }) else {
                fail_pending("CoreWebView2 unavailable".to_string());
                return;
            };
            let pending_cb = Arc::clone(&pending_for_exec);
            let req_id_cb = req_id_for_exec.clone();
            let handler = ExecuteScriptCompletedHandler::create(Box::new(move |hr, _res| {
                if let Err(err) = hr {
                    if let Ok(mut map) = pending_cb.lock() {
                        if let Some(sender) = map.remove(&req_id_cb) {
                            let _ = sender.send(RpcReply {
                                status: 0,
                                body: String::new(),
                                error: Some(format!("ExecuteScript failed: {err}")),
                            });
                        }
                    }
                }
                Ok(())
            }));
            // SAFETY: `script_hstring` and `handler` stay valid for the `ExecuteScript` call.
            if let Err(err) = unsafe { core.ExecuteScript(&script_hstring, &handler) } {
                fail_pending(format!("ExecuteScript dispatch failed: {err}"));
            }
        });

        if let Err(err) = dispatch_err {
            return Err(CoreError::InvalidOperation(format!(
                "无法执行 Pinterest 页面脚本：{err}"
            )));
        }

        match tokio::time::timeout(Duration::from_secs(24), rx).await {
            Ok(Ok(reply)) => Ok(reply),
            Ok(Err(_)) => Err(CoreError::InvalidOperation(
                "Pinterest 会话桥在等待响应时关闭".to_string(),
            )),
            Err(_) => Err(CoreError::InvalidOperation(
                "Pinterest 请求超时，请检查网络连接后重试".to_string(),
            )),
        }
    }

    #[cfg(not(target_os = "windows"))]
    async fn run_bridge_rpc(
        &self,
        _win: &tauri::WebviewWindow,
        _async_iife_js: &str,
    ) -> CoreResult<RpcReply> {
        Err(CoreError::InvalidOperation(
            "Pinterest WebView2 bridge is only available on Windows".to_string(),
        ))
    }

    #[cfg(target_os = "windows")]
    async fn inspect_cookies(&self, win: &tauri::WebviewWindow) -> CookieAuthState {
        use webview2_com::GetCookiesCompletedHandler;
        use webview2_com::Microsoft::Web::WebView2::Win32::ICoreWebView2_2;
        use windows::core::{w, Interface, PWSTR};
        use windows::Win32::System::Com::CoTaskMemFree;

        let (tx, rx) = oneshot::channel::<CookieAuthState>();
        let slot = Arc::new(Mutex::new(Some(tx)));

        let dispatch = win.with_webview(move |platform_wv| {
            let controller = platform_wv.controller();
            let send_now = |state: CookieAuthState| {
                if let Ok(mut guard) = slot.lock() {
                    if let Some(sender) = guard.take() {
                        let _ = sender.send(state);
                    }
                }
            };

            let Ok(core) = (unsafe { controller.CoreWebView2() }) else {
                send_now(CookieAuthState::default());
                return;
            };
            let Ok(core2) = core.cast::<ICoreWebView2_2>() else {
                send_now(CookieAuthState::default());
                return;
            };
            let Ok(manager) = (unsafe { core2.CookieManager() }) else {
                send_now(CookieAuthState::default());
                return;
            };

            let slot_cb = Arc::clone(&slot);
            let handler = GetCookiesCompletedHandler::create(Box::new(move |hr, list| {
                let mut state = CookieAuthState::default();
                if hr.is_ok() {
                    if let Some(list) = list {
                        let mut count = 0u32;
                        if unsafe { list.Count(&mut count) }.is_ok() {
                            for idx in 0..count {
                                if let Ok(cookie) = unsafe { list.GetValueAtIndex(idx) } {
                                    let mut name_ptr = PWSTR::null();
                                    let mut val_ptr = PWSTR::null();
                                    let name = if unsafe { cookie.Name(&mut name_ptr) }.is_ok()
                                        && !name_ptr.is_null()
                                    {
                                        let s = unsafe { name_ptr.to_string() }.unwrap_or_default();
                                        unsafe { CoTaskMemFree(Some(name_ptr.0 as _)) };
                                        s
                                    } else {
                                        String::new()
                                    };
                                    let val = if unsafe { cookie.Value(&mut val_ptr) }.is_ok()
                                        && !val_ptr.is_null()
                                    {
                                        let s = unsafe { val_ptr.to_string() }.unwrap_or_default();
                                        unsafe { CoTaskMemFree(Some(val_ptr.0 as _)) };
                                        s
                                    } else {
                                        String::new()
                                    };
                                    if name == "_auth" && val == "1" {
                                        state.has_auth_one = true;
                                        state.has_session = true;
                                    } else if name == "_pinterest_sess" && !val.trim().is_empty() {
                                        state.has_session = true;
                                    }
                                }
                            }
                        }
                    }
                }
                if let Ok(mut guard) = slot_cb.lock() {
                    if let Some(sender) = guard.take() {
                        let _ = sender.send(state);
                    }
                }
                Ok(())
            }));

            if unsafe { manager.GetCookies(w!("https://www.pinterest.com"), &handler) }.is_err() {
                send_now(CookieAuthState::default());
            }
        });

        if dispatch.is_err() {
            return CookieAuthState::default();
        }
        tokio::time::timeout(Duration::from_secs(5), rx)
            .await
            .ok()
            .and_then(Result::ok)
            .unwrap_or_default()
    }

    #[cfg(not(target_os = "windows"))]
    async fn inspect_cookies(&self, _win: &tauri::WebviewWindow) -> CookieAuthState {
        CookieAuthState::default()
    }

    #[cfg(target_os = "windows")]
    async fn clear_pinterest_cookies(&self, win: &tauri::WebviewWindow) -> CoreResult<()> {
        use webview2_com::GetCookiesCompletedHandler;
        use webview2_com::Microsoft::Web::WebView2::Win32::ICoreWebView2_2;
        use windows::core::{w, Interface};

        let (tx, rx) = oneshot::channel::<()>();
        let slot = Arc::new(Mutex::new(Some(tx)));

        let _ = win.with_webview(move |platform_wv| {
            let finish = || {
                if let Ok(mut guard) = slot.lock() {
                    if let Some(sender) = guard.take() {
                        let _ = sender.send(());
                    }
                }
            };
            let Ok(core) = (unsafe { platform_wv.controller().CoreWebView2() }) else {
                finish();
                return;
            };
            let Ok(core2) = core.cast::<ICoreWebView2_2>() else {
                finish();
                return;
            };
            let Ok(manager) = (unsafe { core2.CookieManager() }) else {
                finish();
                return;
            };

            let manager_cb = manager.clone();
            let slot_cb = Arc::clone(&slot);
            let handler = GetCookiesCompletedHandler::create(Box::new(move |hr, list| {
                if hr.is_ok() {
                    if let Some(list) = list {
                        let mut count = 0u32;
                        if unsafe { list.Count(&mut count) }.is_ok() {
                            for idx in 0..count {
                                if let Ok(cookie) = unsafe { list.GetValueAtIndex(idx) } {
                                    let _ = unsafe { manager_cb.DeleteCookie(&cookie) };
                                }
                            }
                        }
                    }
                }
                if let Ok(mut guard) = slot_cb.lock() {
                    if let Some(sender) = guard.take() {
                        let _ = sender.send(());
                    }
                }
                Ok(())
            }));

            if unsafe { manager.GetCookies(w!("https://www.pinterest.com"), &handler) }.is_err() {
                finish();
            }
        });

        let _ = tokio::time::timeout(Duration::from_secs(5), rx).await;
        Ok(())
    }

    #[cfg(not(target_os = "windows"))]
    async fn clear_pinterest_cookies(&self, _win: &tauri::WebviewWindow) -> CoreResult<()> {
        Ok(())
    }
}
