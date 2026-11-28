//! Sign in with ChatGPT PKCE OAuth 2.0 client (`chatgpt_oauth.rs`),
//! mirroring `Sources/CharkleCore/Intelligence/ChatGPTSignInClient.swift`.
//!
//! Tokens are stored exclusively inside `SecretVault` (Windows DPAPI / Credential Manager)
//! under `ai.chatgpt.connection.v1` — zero plaintext credentials are ever written to disk.

use std::sync::Arc;
use std::time::Duration;

use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use base64::Engine;
use chrono::{DateTime, Utc};
use rand::RngCore;
use reqwest::Client;
use serde::{Deserialize, Serialize};
use serde_json::Value;
use sha2::{Digest, Sha256};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpListener;
use tokio::sync::Mutex;
use url::Url;

use crate::error::{CoreError, CoreResult};
use crate::models::media::{ChatGPTAccountSession, ChatGPTConnectionStatus};
use crate::traits::SecretVault;

pub const CHATGPT_VAULT_KEY: &str = "ai.chatgpt.connection.v1";
pub const CHATGPT_ISSUER: &str = "https://auth.openai.com";
pub const CHATGPT_RESOURCE: &str = "https://api.openai.com/v1";
pub const CHATGPT_CALLBACK_PATH: &str = "/auth/callback";
pub const CHATGPT_SHARING_SCOPE: &str = "chatgpt.tokens.use.direct";
pub const CHATGPT_SCOPES: &str =
    "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct";

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct StoredChatGPTConnection {
    client_id: String,
    status: ChatGPTConnectionStatus,
    scopes: Vec<String>,
    saved_at: DateTime<Utc>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    subject: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    name: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    email: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    access_token: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    refresh_token: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    expires_at: Option<DateTime<Utc>>,
}

impl StoredChatGPTConnection {
    fn to_public_session(&self) -> ChatGPTAccountSession {
        ChatGPTAccountSession {
            status: self.status,
            sharing_enabled: self.scopes.iter().any(|s| s == CHATGPT_SHARING_SCOPE),
            email: self.email.clone(),
            name: self.name.clone(),
            subject: self.subject.clone(),
            last_updated_at: Some(self.saved_at),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PkceChallengePair {
    pub verifier: String,
    pub challenge: String,
    pub state: String,
    pub nonce: String,
}

#[derive(Debug, Clone, Deserialize)]
struct OidcDiscovery {
    authorization_endpoint: String,
    token_endpoint: String,
}

#[derive(Debug, Clone)]
struct VerifiedIdClaims {
    subject: String,
    email: Option<String>,
    name: Option<String>,
}

pub struct ChatGPTSignInClient {
    vault: Arc<dyn SecretVault>,
    http: Client,
    refresh_lock: Mutex<()>,
}

impl ChatGPTSignInClient {
    pub fn new(vault: Arc<dyn SecretVault>) -> Self {
        let http = Client::builder()
            .timeout(Duration::from_secs(45))
            .build()
            .unwrap_or_else(|_| Client::new());
        Self {
            vault,
            http,
            refresh_lock: Mutex::new(()),
        }
    }

    pub fn generate_pkce_pair() -> PkceChallengePair {
        let random_b64 = || {
            let mut bytes = [0u8; 32];
            rand::thread_rng().fill_bytes(&mut bytes);
            URL_SAFE_NO_PAD.encode(bytes)
        };
        let verifier = random_b64();
        let challenge = URL_SAFE_NO_PAD.encode(Sha256::digest(verifier.as_bytes()));
        PkceChallengePair {
            verifier,
            challenge,
            state: random_b64(),
            nonce: random_b64(),
        }
    }

    pub async fn build_authorize_url(
        &self,
        redirect_uri: &str,
        pkce: &PkceChallengePair,
        reconsent: bool,
    ) -> CoreResult<String> {
        let existing = self.load_connection().await;
        let mut url = Url::parse(&format!("{CHATGPT_ISSUER}/oauth/authorize"))
            .map_err(|e| CoreError::InvalidOperation(format!("构建 ChatGPT 授权地址失败：{e}")))?;
        {
            let mut pairs = url.query_pairs_mut();
            let client_id = existing
                .as_ref()
                .map(|c| c.client_id.as_str())
                .unwrap_or("dynamic_agent_client");
            pairs.append_pair("client_id", client_id);
            pairs.append_pair("response_type", "code");
            pairs.append_pair("redirect_uri", redirect_uri);
            pairs.append_pair("scope", CHATGPT_SCOPES);
            pairs.append_pair("resource", CHATGPT_RESOURCE);
            pairs.append_pair("state", &pkce.state);
            pairs.append_pair("nonce", &pkce.nonce);
            pairs.append_pair("code_challenge_method", "S256");
            pairs.append_pair("code_challenge", &pkce.challenge);
            if existing.is_none() {
                pairs.append_pair("agent_name_hint", "Charkle");
            }
            if reconsent {
                pairs.append_pair("prompt", "consent");
            }
        }
        Ok(url.to_string())
    }

    pub async fn current_session(&self) -> ChatGPTAccountSession {
        self.load_connection()
            .await
            .map(|c| c.to_public_session())
            .unwrap_or_default()
    }

    #[allow(clippy::too_many_arguments)]
    pub async fn save_connected_session(
        &self,
        client_id: String,
        access_token: String,
        refresh_token: Option<String>,
        email: Option<String>,
        name: Option<String>,
        subject: Option<String>,
        scopes: Vec<String>,
    ) -> CoreResult<ChatGPTAccountSession> {
        let rec = StoredChatGPTConnection {
            client_id,
            status: ChatGPTConnectionStatus::Connected,
            scopes,
            saved_at: Utc::now(),
            subject,
            name,
            email,
            access_token: Some(access_token),
            refresh_token,
            expires_at: None,
        };
        let encoded = serde_json::to_string(&rec)?;
        self.vault
            .set_secret(CHATGPT_VAULT_KEY, &encoded)
            .await
            .map_err(CoreError::InvalidOperation)?;
        Ok(rec.to_public_session())
    }

    pub async fn valid_access_token(&self) -> CoreResult<String> {
        let _guard = self.refresh_lock.lock().await;
        let conn = self.load_connection().await.ok_or_else(|| {
            CoreError::InvalidOperation(
                "请先在「设置 → 智能与搜索」中登录 ChatGPT 订阅账号。".to_string(),
            )
        })?;
        if conn.status != ChatGPTConnectionStatus::Connected {
            return Err(CoreError::InvalidOperation(
                "ChatGPT 登录会话已断开，请重新登录。".to_string(),
            ));
        }
        if !conn.scopes.iter().any(|s| s == CHATGPT_SHARING_SCOPE) {
            return Err(CoreError::InvalidOperation(
                "已登录 ChatGPT，但尚未开启订阅额度共享权限，请重新授权。".to_string(),
            ));
        }

        let needs_refresh = conn
            .expires_at
            .is_some_and(|exp| Utc::now() + chrono::Duration::seconds(60) >= exp);
        if needs_refresh {
            let Some(refresh) = conn.refresh_token.as_deref().filter(|s| !s.is_empty()) else {
                return Err(CoreError::AuthenticationRequired(
                    "ChatGPT 访问令牌已过期且缺少刷新令牌，请重新登录。".to_string(),
                ));
            };
            let discovery = self.fetch_discovery().await?;
            let token_json = self
                .post_token_form(
                    &discovery.token_endpoint,
                    &[
                        ("grant_type", "refresh_token"),
                        ("client_id", conn.client_id.as_str()),
                        ("refresh_token", refresh),
                        ("resource", CHATGPT_RESOURCE),
                    ],
                )
                .await?;
            let new_access = token_json
                .get("access_token")
                .and_then(Value::as_str)
                .filter(|s| !s.is_empty())
                .ok_or_else(|| {
                    CoreError::InvalidOperation(
                        "刷新 ChatGPT 访问令牌失败，请重新登录。".to_string(),
                    )
                })?
                .to_string();
            let new_refresh = token_json
                .get("refresh_token")
                .and_then(Value::as_str)
                .filter(|s| !s.is_empty())
                .map(String::from)
                .or_else(|| conn.refresh_token.clone());
            let expires_in = token_json
                .get("expires_in")
                .and_then(Value::as_i64)
                .unwrap_or(3600)
                .max(60);
            let mut updated = conn.clone();
            updated.access_token = Some(new_access.clone());
            updated.refresh_token = new_refresh;
            updated.expires_at = Some(Utc::now() + chrono::Duration::seconds(expires_in));
            updated.saved_at = Utc::now();
            self.persist_connection(&updated).await?;
            return Ok(new_access);
        }

        conn.access_token.filter(|t| !t.is_empty()).ok_or_else(|| {
            CoreError::InvalidOperation("ChatGPT 访问令牌缺失，请重新登录。".to_string())
        })
    }

    /// Runs the full interactive Sign in with ChatGPT PKCE OAuth 2.0 + OIDC flow on
    /// `http://127.0.0.1:<port>/auth/callback` (mirroring `ChatGPTSignInClient.swift`).
    pub async fn sign_in_interactive<F, Fut>(
        &self,
        reconsent: bool,
        switch_account: bool,
        open_browser: F,
    ) -> CoreResult<ChatGPTAccountSession>
    where
        F: FnOnce(Url) -> Fut,
        Fut: std::future::Future<Output = ()>,
    {
        let existing = if switch_account {
            None
        } else {
            self.load_connection().await
        };
        let discovery = self.fetch_discovery().await?;
        let pkce = Self::generate_pkce_pair();

        let listener = TcpListener::bind("127.0.0.1:0").await?;
        let port = listener.local_addr()?.port();
        let redirect_uri = format!("http://127.0.0.1:{port}{CHATGPT_CALLBACK_PATH}");

        let mut auth_url = Url::parse(&discovery.authorization_endpoint).map_err(|_| {
            CoreError::InvalidOperation("无法构建 ChatGPT 登录授权链接。".to_string())
        })?;
        if auth_url.scheme() != "https" || auth_url.host_str() != Some("auth.openai.com") {
            return Err(CoreError::InvalidOperation(
                "检测到异常的 ChatGPT 授权服务地址。".to_string(),
            ));
        }
        {
            let mut pairs = auth_url.query_pairs_mut();
            let client_id = existing
                .as_ref()
                .map(|c| c.client_id.as_str())
                .unwrap_or("dynamic_agent_client");
            pairs.append_pair("client_id", client_id);
            pairs.append_pair("response_type", "code");
            pairs.append_pair("redirect_uri", &redirect_uri);
            pairs.append_pair("scope", CHATGPT_SCOPES);
            pairs.append_pair("resource", CHATGPT_RESOURCE);
            pairs.append_pair("state", &pkce.state);
            pairs.append_pair("nonce", &pkce.nonce);
            pairs.append_pair("code_challenge_method", "S256");
            pairs.append_pair("code_challenge", &pkce.challenge);
            if existing.is_none() {
                pairs.append_pair("agent_name_hint", "Charkle");
            }
            if let Some(email) = existing
                .as_ref()
                .and_then(|c| c.email.as_deref())
                .filter(|s| !s.is_empty())
            {
                pairs.append_pair("login_hint", email);
            }
            if reconsent {
                pairs.append_pair("prompt", "consent");
            }
        }

        open_browser(auth_url).await;

        let saved_client_id = existing.as_ref().map(|c| c.client_id.clone());
        let (code, returned_state, issued_client_id) = tokio::time::timeout(
            Duration::from_secs(300),
            wait_for_chatgpt_callback_with_state(
                listener,
                saved_client_id.clone(),
                Some(&pkce.state),
            ),
        )
        .await
        .map_err(|_| {
            CoreError::AuthenticationRequired("ChatGPT 登录超时，请重试。".to_string())
        })??;

        if returned_state.as_deref() != Some(pkce.state.as_str()) {
            return Err(CoreError::AuthenticationRequired(
                "登录状态校验不匹配，请重试。".to_string(),
            ));
        }

        let effective_client_id = issued_client_id
            .or(saved_client_id)
            .filter(|s| !s.trim().is_empty())
            .ok_or_else(|| {
                CoreError::AuthenticationRequired(
                    "ChatGPT 回调缺少客户端标识，请重新登录。".to_string(),
                )
            })?;

        // Persist updated client_id only when refreshing an existing connection (never clobber
        // an active session with `Disconnected` before account-switch token exchange succeeds).
        if let Some(mut reg) = existing.clone() {
            reg.client_id = effective_client_id.clone();
            reg.saved_at = Utc::now();
            self.persist_connection(&reg).await?;
        }

        let token_json = self
            .post_token_form(
                &discovery.token_endpoint,
                &[
                    ("grant_type", "authorization_code"),
                    ("client_id", effective_client_id.as_str()),
                    ("code", code.as_str()),
                    ("code_verifier", pkce.verifier.as_str()),
                    ("redirect_uri", redirect_uri.as_str()),
                    ("resource", CHATGPT_RESOURCE),
                ],
            )
            .await?;

        let id_token = token_json
            .get("id_token")
            .and_then(Value::as_str)
            .filter(|s| !s.is_empty())
            .ok_or_else(|| {
                CoreError::AuthenticationRequired(
                    "ChatGPT 未返回可验证的身份令牌，请重新登录。".to_string(),
                )
            })?;
        let identity = parse_and_validate_id_token(id_token, &effective_client_id, &pkce.nonce)?;

        if let Some(prior_sub) = existing
            .as_ref()
            .and_then(|c| c.subject.as_deref())
            .filter(|s| !s.is_empty())
        {
            if prior_sub != identity.subject {
                return Err(CoreError::AuthenticationRequired(
                    "本次登录的 ChatGPT 账号与原账号不一致。请登录原账号，或点击「切换账号」重新绑定。"
                        .to_string(),
                ));
            }
        }

        let access_token = token_json
            .get("access_token")
            .and_then(Value::as_str)
            .filter(|s| !s.is_empty())
            .ok_or_else(|| {
                CoreError::AuthenticationRequired(
                    "ChatGPT 未返回访问令牌，请重新登录。".to_string(),
                )
            })?
            .to_string();
        let refresh_token = token_json
            .get("refresh_token")
            .and_then(Value::as_str)
            .filter(|s| !s.is_empty())
            .map(String::from);
        let scopes: Vec<String> = token_json
            .get("scope")
            .and_then(Value::as_str)
            .map(|s| s.split_whitespace().map(String::from).collect())
            .unwrap_or_else(|| {
                CHATGPT_SCOPES
                    .split_whitespace()
                    .map(String::from)
                    .collect()
            });
        let expires_in = token_json
            .get("expires_in")
            .and_then(Value::as_i64)
            .unwrap_or(3600)
            .max(60);

        let connected = StoredChatGPTConnection {
            client_id: effective_client_id,
            status: ChatGPTConnectionStatus::Connected,
            scopes,
            saved_at: Utc::now(),
            subject: Some(identity.subject),
            name: identity.name,
            email: identity.email,
            access_token: Some(access_token),
            refresh_token,
            expires_at: Some(Utc::now() + chrono::Duration::seconds(expires_in)),
        };
        self.persist_connection(&connected).await?;
        Ok(connected.to_public_session())
    }

    pub async fn disconnect(&self) -> CoreResult<()> {
        self.vault
            .delete_secret(CHATGPT_VAULT_KEY)
            .await
            .map_err(CoreError::InvalidOperation)
    }

    async fn fetch_discovery(&self) -> CoreResult<OidcDiscovery> {
        let fallback = OidcDiscovery {
            authorization_endpoint: format!("{CHATGPT_ISSUER}/oauth/authorize"),
            token_endpoint: format!("{CHATGPT_ISSUER}/oauth/token"),
        };
        let url = format!("{CHATGPT_ISSUER}/.well-known/openid-configuration");
        let Ok(resp) = self.http.get(&url).send().await else {
            return Ok(fallback);
        };
        if !resp.status().is_success() {
            return Ok(fallback);
        }
        let Ok(doc) = resp.json::<OidcDiscovery>().await else {
            return Ok(fallback);
        };
        let auth_ok = Url::parse(&doc.authorization_endpoint)
            .ok()
            .is_some_and(|u| u.scheme() == "https" && u.host_str() == Some("auth.openai.com"));
        let token_ok = Url::parse(&doc.token_endpoint)
            .ok()
            .is_some_and(|u| u.scheme() == "https" && u.host_str() == Some("auth.openai.com"));
        if auth_ok && token_ok {
            Ok(doc)
        } else {
            Ok(fallback)
        }
    }

    async fn post_token_form(&self, endpoint: &str, params: &[(&str, &str)]) -> CoreResult<Value> {
        let resp = self
            .http
            .post(endpoint)
            .header("Accept", "application/json")
            .form(params)
            .send()
            .await?;
        let status = resp.status();
        let body = resp.text().await.unwrap_or_default();
        if !status.is_success() {
            let detail = serde_json::from_str::<Value>(&body)
                .ok()
                .and_then(|v| {
                    v.get("error_description")
                        .or_else(|| v.get("error"))
                        .and_then(Value::as_str)
                        .map(String::from)
                })
                .unwrap_or_else(|| format!("HTTP {}", status.as_u16()));
            return Err(CoreError::AuthenticationRequired(format!(
                "ChatGPT 授权交换失败：{detail}"
            )));
        }
        serde_json::from_str(&body).map_err(|_| {
            CoreError::AuthenticationRequired("无法解析 ChatGPT 令牌响应。".to_string())
        })
    }

    async fn persist_connection(&self, rec: &StoredChatGPTConnection) -> CoreResult<()> {
        let encoded = serde_json::to_string(rec)?;
        self.vault
            .set_secret(CHATGPT_VAULT_KEY, &encoded)
            .await
            .map_err(CoreError::InvalidOperation)
    }

    async fn load_connection(&self) -> Option<StoredChatGPTConnection> {
        let raw = self.vault.get_secret(CHATGPT_VAULT_KEY).await.ok()??;
        serde_json::from_str(&raw).ok()
    }
}

fn parse_and_validate_id_token(
    jwt: &str,
    expected_client_id: &str,
    expected_nonce: &str,
) -> CoreResult<VerifiedIdClaims> {
    let mut parts = jwt.split('.');
    let _header = parts.next();
    let payload_b64 = parts.next().ok_or_else(|| {
        CoreError::AuthenticationRequired("ChatGPT 身份令牌格式无效。".to_string())
    })?;
    let payload_bytes = URL_SAFE_NO_PAD
        .decode(payload_b64)
        .or_else(|_| base64::engine::general_purpose::URL_SAFE.decode(payload_b64))
        .map_err(|_| CoreError::AuthenticationRequired("ChatGPT 身份令牌解码失败。".to_string()))?;
    let claims: Value = serde_json::from_slice(&payload_bytes)
        .map_err(|_| CoreError::AuthenticationRequired("ChatGPT 身份令牌内容无效。".to_string()))?;

    let iss = claims.get("iss").and_then(Value::as_str).ok_or_else(|| {
        CoreError::AuthenticationRequired("ChatGPT 身份令牌缺少签发方。".to_string())
    })?;
    if iss.trim_end_matches('/') != CHATGPT_ISSUER {
        return Err(CoreError::AuthenticationRequired(
            "ChatGPT 身份令牌签发方不匹配。".to_string(),
        ));
    }
    let nonce = claims.get("nonce").and_then(Value::as_str).ok_or_else(|| {
        CoreError::AuthenticationRequired("ChatGPT 身份令牌缺少随机数声明。".to_string())
    })?;
    if nonce != expected_nonce {
        return Err(CoreError::AuthenticationRequired(
            "ChatGPT 登录随机数校验失败，请重试。".to_string(),
        ));
    }
    let aud = claims.get("aud").ok_or_else(|| {
        CoreError::AuthenticationRequired("ChatGPT 身份令牌缺少受众声明。".to_string())
    })?;
    let aud_matches = match aud {
        Value::String(s) => s == expected_client_id,
        Value::Array(arr) => arr
            .iter()
            .any(|item| item.as_str() == Some(expected_client_id)),
        _ => false,
    };
    if !aud_matches {
        return Err(CoreError::AuthenticationRequired(
            "ChatGPT 身份令牌受众不匹配。".to_string(),
        ));
    }
    if let Some(exp) = claims.get("exp").and_then(Value::as_i64) {
        if exp + 60 < Utc::now().timestamp() {
            return Err(CoreError::AuthenticationRequired(
                "ChatGPT 身份令牌已过期，请重新登录。".to_string(),
            ));
        }
    }
    let subject = claims
        .get("sub")
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .ok_or_else(|| {
            CoreError::AuthenticationRequired("ChatGPT 身份令牌缺少用户标识。".to_string())
        })?
        .to_string();
    let email = claims
        .get("email")
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .map(String::from);
    let name = claims
        .get("name")
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .map(String::from);

    Ok(VerifiedIdClaims {
        subject,
        email,
        name,
    })
}

#[allow(dead_code)]
async fn wait_for_chatgpt_callback(
    listener: TcpListener,
    saved_client_id: Option<String>,
) -> CoreResult<(String, Option<String>, Option<String>)> {
    wait_for_chatgpt_callback_with_state(listener, saved_client_id, None).await
}

async fn wait_for_chatgpt_callback_with_state(
    listener: TcpListener,
    saved_client_id: Option<String>,
    expected_state: Option<&str>,
) -> CoreResult<(String, Option<String>, Option<String>)> {
    loop {
        let (mut socket, _) = listener.accept().await?;
        let mut buf = [0u8; 8192];
        let n = match tokio::time::timeout(Duration::from_secs(5), socket.read(&mut buf)).await {
            Ok(Ok(n)) => n,
            _ => {
                let _ = socket.shutdown().await;
                continue;
            }
        };
        let req = String::from_utf8_lossy(&buf[..n]);
        let first_line = req.lines().next().unwrap_or("");
        let path_part = first_line.split_whitespace().nth(1).unwrap_or("/");
        let req_path = path_part.split('?').next().unwrap_or("");
        if n == 0 || req_path != CHATGPT_CALLBACK_PATH {
            let _ = socket
                .write_all(
                    b"HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
                )
                .await;
            let _ = socket.shutdown().await;
            continue;
        }
        let parsed = Url::parse(&format!("http://127.0.0.1{path_part}")).ok();
        let mut code = None;
        let mut state = None;
        let mut client_id = saved_client_id.clone();
        let mut error = None;
        if let Some(url) = parsed {
            for (k, v) in url.query_pairs() {
                match k.as_ref() {
                    "code" => code = Some(v.into_owned()),
                    "state" => state = Some(v.into_owned()),
                    "client_id" if !v.is_empty() => client_id = Some(v.into_owned()),
                    "error" => error = Some(v.into_owned()),
                    _ => {}
                }
            }
        }
        if let Some(exp) = expected_state {
            if state.as_deref() != Some(exp) {
                let _ = socket
                    .write_all(
                        b"HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
                    )
                    .await;
                let _ = socket.shutdown().await;
                continue;
            }
        }
        let body = if code.is_some() {
            "<html><head><meta charset=\"utf-8\"></head><body style=\"font-family:system-ui;padding:48px;text-align:center\"><h2>已完成 ChatGPT 登录</h2><p>请返回 Charkle 继续使用。</p></body></html>"
        } else {
            "<html><head><meta charset=\"utf-8\"></head><body style=\"font-family:system-ui;padding:48px;text-align:center\"><h2>ChatGPT 登录未完成</h2><p>请关闭此页面并在 Charkle 中重试。</p></body></html>"
        };
        let resp = format!(
            "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
            body.len(),
            body
        );
        let _ = socket.write_all(resp.as_bytes()).await;
        let _ = socket.shutdown().await;

        if let Some(err) = error {
            return Err(CoreError::AuthenticationRequired(format!(
                "ChatGPT 授权被拒绝或取消：{err}"
            )));
        }
        if let Some(code) = code.filter(|s| !s.is_empty()) {
            return Ok((code, state, client_id));
        }
        return Err(CoreError::AuthenticationRequired(
            "ChatGPT 回调未包含授权码，请重试。".to_string(),
        ));
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::traits::InMemorySecretVault;

    #[tokio::test]
    async fn pkce_url_and_vault_session_round_trip() {
        let vault = Arc::new(InMemorySecretVault::new());
        let client = ChatGPTSignInClient::new(vault);
        let pkce = ChatGPTSignInClient::generate_pkce_pair();
        assert_ne!(pkce.verifier, pkce.challenge);

        let url = client
            .build_authorize_url("http://127.0.0.1:43123/auth/callback", &pkce, true)
            .await
            .unwrap();
        assert!(url.contains("code_challenge_method=S256"));
        assert!(url.contains("agent_name_hint=Charkle"));
        assert!(url.contains("prompt=consent"));

        let session = client
            .save_connected_session(
                "client-1".into(),
                "tok-abc".into(),
                Some("ref-xyz".into()),
                Some("designer@example.com".into()),
                Some("Designer".into()),
                Some("sub-1".into()),
                vec!["openid".into(), CHATGPT_SHARING_SCOPE.into()],
            )
            .await
            .unwrap();
        assert_eq!(session.status, ChatGPTConnectionStatus::Connected);
        assert!(session.sharing_enabled);
        assert_eq!(client.valid_access_token().await.unwrap(), "tok-abc");

        client.disconnect().await.unwrap();
        assert_eq!(
            client.current_session().await.status,
            ChatGPTConnectionStatus::Disconnected
        );
    }
}
