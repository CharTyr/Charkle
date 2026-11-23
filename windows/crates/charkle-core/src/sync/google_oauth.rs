//! RFC 8252 native desktop Google OAuth 2.0 client using PKCE (`S256`) and an ephemeral
//! `127.0.0.1` loopback callback server.
//!
//! Mirrors `Sources/CharkleCore/Sync/GoogleOAuthClient.swift`.

use std::sync::Arc;
use std::time::Duration;

use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use base64::Engine;
use chrono::{DateTime, Utc};
use rand::RngCore;
use reqwest::Client;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpListener;
use tokio::sync::Mutex;
use url::Url;
use uuid::Uuid;

use crate::error::{CoreError, CoreResult};
use crate::traits::SecretVault;
use crate::wire::swift_codec::cocoa_date;

const CONFIG_VAULT_KEY: &str = "drive.oauth.config";
const TOKEN_VAULT_KEY: &str = "drive.oauth.token";

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct GoogleOAuthClientConfig {
    #[serde(rename = "clientID")]
    pub client_id: String,
    #[serde(default)]
    pub client_secret: String,
    #[serde(rename = "authURI", default = "default_auth_uri")]
    pub auth_uri: String,
    #[serde(rename = "tokenURI", default = "default_token_uri")]
    pub token_uri: String,
}

fn default_auth_uri() -> String {
    "https://accounts.google.com/o/oauth2/v2/auth".to_string()
}
fn default_token_uri() -> String {
    "https://oauth2.googleapis.com/token".to_string()
}

impl GoogleOAuthClientConfig {
    pub fn new(client_id: impl Into<String>, client_secret: impl Into<String>) -> Self {
        Self {
            client_id: client_id.into(),
            client_secret: client_secret.into(),
            auth_uri: default_auth_uri(),
            token_uri: default_token_uri(),
        }
    }

    /// Parses standard Google Cloud Console `client_secret_*.json` (`installed` or `web`).
    pub fn parse_client_secret_json(data: &[u8]) -> CoreResult<Self> {
        let root: serde_json::Value = serde_json::from_slice(data)?;
        let obj = root
            .get("installed")
            .or_else(|| root.get("web"))
            .unwrap_or(&root)
            .as_object()
            .ok_or_else(|| CoreError::InvalidPayload("JSON 格式无效".to_string()))?;

        let client_id = obj
            .get("client_id")
            .and_then(|v| v.as_str())
            .map(str::trim)
            .filter(|s| !s.is_empty())
            .ok_or_else(|| {
                CoreError::InvalidPayload("未在 client_secret JSON 中找到 client_id".to_string())
            })?
            .to_string();
        let client_secret = obj
            .get("client_secret")
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .trim()
            .to_string();
        let auth_uri = obj
            .get("auth_uri")
            .and_then(|v| v.as_str())
            .unwrap_or("https://accounts.google.com/o/oauth2/v2/auth")
            .to_string();
        let token_uri = obj
            .get("token_uri")
            .and_then(|v| v.as_str())
            .unwrap_or("https://oauth2.googleapis.com/token")
            .to_string();

        let auth_parsed = Url::parse(&auth_uri)
            .map_err(|_| CoreError::InvalidPayload("Invalid auth_uri".to_string()))?;
        let token_parsed = Url::parse(&token_uri)
            .map_err(|_| CoreError::InvalidPayload("Invalid token_uri".to_string()))?;
        if auth_parsed.scheme() != "https"
            || auth_parsed.host_str() != Some("accounts.google.com")
            || token_parsed.scheme() != "https"
            || token_parsed.host_str() != Some("oauth2.googleapis.com")
        {
            return Err(CoreError::InvalidPayload(
                "Expected Google Desktop OAuth endpoints.".to_string(),
            ));
        }

        Ok(Self {
            client_id,
            client_secret,
            auth_uri,
            token_uri,
        })
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct GoogleOAuthToken {
    pub access_token: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub refresh_token: Option<String>,
    #[serde(with = "cocoa_date")]
    pub expires_at: DateTime<Utc>,
}

impl GoogleOAuthToken {
    pub fn is_expired_or_expiring_soon(&self) -> bool {
        Utc::now() + chrono::Duration::seconds(90) >= self.expires_at
    }
}

pub struct GoogleOAuthClient {
    vault: Arc<dyn SecretVault>,
    client: Client,
    refresh_lock: Mutex<()>,
}

impl GoogleOAuthClient {
    pub fn new(vault: Arc<dyn SecretVault>) -> Self {
        let client = Client::builder()
            .timeout(Duration::from_secs(30))
            .build()
            .unwrap_or_else(|_| Client::new());
        Self {
            vault,
            client,
            refresh_lock: Mutex::new(()),
        }
    }

    pub fn generate_code_verifier() -> String {
        let mut bytes = [0u8; 32];
        rand::thread_rng().fill_bytes(&mut bytes);
        URL_SAFE_NO_PAD.encode(bytes)
    }

    pub fn code_challenge_s256(verifier: &str) -> String {
        let digest = Sha256::digest(verifier.as_bytes());
        URL_SAFE_NO_PAD.encode(digest)
    }

    pub async fn save_client_config(&self, config: &GoogleOAuthClientConfig) -> CoreResult<()> {
        let trimmed_id = config.client_id.trim();
        if trimmed_id.is_empty() {
            return Err(CoreError::NotConfigured(
                "请输入有效的 Google OAuth Client ID。".to_string(),
            ));
        }
        let normalized = GoogleOAuthClientConfig {
            client_id: trimmed_id.to_string(),
            client_secret: config.client_secret.trim().to_string(),
            auth_uri: config.auth_uri.clone(),
            token_uri: config.token_uri.clone(),
        };
        if let Some(prev) = self.stored_config().await? {
            if prev.client_id != normalized.client_id {
                let _ = self.vault.delete_secret(TOKEN_VAULT_KEY).await;
            }
        }
        let json = serde_json::to_string(&normalized)?;
        self.vault
            .set_secret(CONFIG_VAULT_KEY, &json)
            .await
            .map_err(CoreError::InvalidOperation)?;
        Ok(())
    }

    pub async fn stored_config(&self) -> CoreResult<Option<GoogleOAuthClientConfig>> {
        let raw = self
            .vault
            .get_secret(CONFIG_VAULT_KEY)
            .await
            .map_err(CoreError::InvalidOperation)?;
        match raw {
            Some(s) => Ok(Some(serde_json::from_str(&s)?)),
            None => Ok(None),
        }
    }

    pub async fn save_token(&self, token: &GoogleOAuthToken) -> CoreResult<()> {
        let json = serde_json::to_string(token)?;
        self.vault
            .set_secret(TOKEN_VAULT_KEY, &json)
            .await
            .map_err(CoreError::InvalidOperation)?;
        Ok(())
    }

    pub async fn stored_token(&self) -> CoreResult<Option<GoogleOAuthToken>> {
        let raw = self
            .vault
            .get_secret(TOKEN_VAULT_KEY)
            .await
            .map_err(CoreError::InvalidOperation)?;
        match raw {
            Some(s) => Ok(Some(serde_json::from_str(&s)?)),
            None => Ok(None),
        }
    }

    pub async fn sign_out(&self) -> CoreResult<()> {
        self.vault
            .delete_secret(TOKEN_VAULT_KEY)
            .await
            .map_err(CoreError::InvalidOperation)?;
        Ok(())
    }

    /// Returns a fresh access token, automatically refreshing via `refresh_token` if needed.
    pub async fn access_token(&self) -> CoreResult<String> {
        let config = self.stored_config().await?.ok_or_else(|| {
            CoreError::NotConfigured("请先在设置中完成 Google 登录配置。".to_string())
        })?;
        self.valid_access_token(&config).await
    }

    pub async fn valid_access_token(&self, config: &GoogleOAuthClientConfig) -> CoreResult<String> {
        let _guard = self.refresh_lock.lock().await;
        let token = self.stored_token().await?.ok_or_else(|| {
            CoreError::AuthenticationRequired("尚未完成 Google Drive OAuth 登录".to_string())
        })?;
        if !token.is_expired_or_expiring_soon() {
            return Ok(token.access_token);
        }
        let refresh = token
            .refresh_token
            .as_deref()
            .filter(|s| !s.is_empty())
            .ok_or_else(|| {
                CoreError::AuthenticationRequired(
                    "访问令牌已过期且无 Refresh Token，请重新登录".to_string(),
                )
            })?;
        let refreshed = self.refresh_access_token(refresh, config).await?;
        self.save_token(&refreshed).await?;
        Ok(refreshed.access_token)
    }

    /// Runs the complete PKCE (`S256`) loopback OAuth flow on `http://127.0.0.1:<port>/oauth2callback`.
    pub async fn authorize_interactive<F, Fut>(
        &self,
        config: &GoogleOAuthClientConfig,
        full_drive_scope: bool,
        open_browser: F,
    ) -> CoreResult<GoogleOAuthToken>
    where
        F: FnOnce(Url) -> Fut,
        Fut: std::future::Future<Output = ()>,
    {
        if config.client_id.trim().is_empty() {
            return Err(CoreError::NotConfigured(
                "请先填写 Google OAuth Client ID 或导入 client_secret.json".to_string(),
            ));
        }

        let code_verifier = Self::generate_code_verifier();
        let code_challenge = Self::code_challenge_s256(&code_verifier);
        let state = Uuid::new_v4().simple().to_string();

        let listener = TcpListener::bind("127.0.0.1:0").await?;
        let port = listener.local_addr()?.port();
        let redirect_uri = format!("http://127.0.0.1:{port}/oauth2callback");

        let scope = if full_drive_scope {
            "https://www.googleapis.com/auth/drive"
        } else {
            "https://www.googleapis.com/auth/drive.file"
        };

        let mut auth_url = Url::parse(&config.auth_uri)
            .map_err(|_| CoreError::InvalidPayload("Invalid auth URI".to_string()))?;
        if auth_url.scheme() != "https" || auth_url.host_str() != Some("accounts.google.com") {
            return Err(CoreError::InvalidPayload(
                "Invalid Google authorization endpoint.".to_string(),
            ));
        }
        auth_url
            .query_pairs_mut()
            .append_pair("client_id", &config.client_id)
            .append_pair("redirect_uri", &redirect_uri)
            .append_pair("response_type", "code")
            .append_pair("scope", scope)
            .append_pair("code_challenge", &code_challenge)
            .append_pair("code_challenge_method", "S256")
            .append_pair("access_type", "offline")
            .append_pair("prompt", "consent")
            .append_pair("state", &state);

        open_browser(auth_url).await;

        let (code, returned_state) =
            tokio::time::timeout(Duration::from_secs(180), wait_for_loopback_code(listener))
                .await
                .map_err(|_| {
                    CoreError::AuthenticationRequired("Google 登录超时，请重试。".to_string())
                })??;

        if returned_state.as_deref() != Some(state.as_str()) {
            return Err(CoreError::AuthenticationRequired(
                "OAuth State 校验不匹配，请重试".to_string(),
            ));
        }

        let token = self
            .exchange_code(&code, &code_verifier, &redirect_uri, config)
            .await?;
        self.save_token(&token).await?;
        Ok(token)
    }

    async fn exchange_code(
        &self,
        code: &str,
        code_verifier: &str,
        redirect_uri: &str,
        config: &GoogleOAuthClientConfig,
    ) -> CoreResult<GoogleOAuthToken> {
        let mut form = vec![
            ("client_id", config.client_id.as_str()),
            ("code", code),
            ("code_verifier", code_verifier),
            ("grant_type", "authorization_code"),
            ("redirect_uri", redirect_uri),
        ];
        if !config.client_secret.is_empty() {
            form.push(("client_secret", config.client_secret.as_str()));
        }
        self.post_token(&form, &config.token_uri, None).await
    }

    async fn refresh_access_token(
        &self,
        refresh_token: &str,
        config: &GoogleOAuthClientConfig,
    ) -> CoreResult<GoogleOAuthToken> {
        let mut form = vec![
            ("client_id", config.client_id.as_str()),
            ("refresh_token", refresh_token),
            ("grant_type", "refresh_token"),
        ];
        if !config.client_secret.is_empty() {
            form.push(("client_secret", config.client_secret.as_str()));
        }
        self.post_token(&form, &config.token_uri, Some(refresh_token.to_string()))
            .await
    }

    async fn post_token(
        &self,
        form: &[(&str, &str)],
        token_uri: &str,
        fallback_refresh: Option<String>,
    ) -> CoreResult<GoogleOAuthToken> {
        let parsed = Url::parse(token_uri)
            .map_err(|_| CoreError::InvalidPayload(format!("无效的 Token URL: {token_uri}")))?;
        if parsed.scheme() != "https" || parsed.host_str() != Some("oauth2.googleapis.com") {
            return Err(CoreError::InvalidPayload(format!(
                "无效的 Token URL: {token_uri}"
            )));
        }
        let resp = self.client.post(parsed).form(form).send().await?;
        let status = resp.status();
        let body = resp.bytes().await?;
        if !status.is_success() {
            let text = String::from_utf8_lossy(&body);
            return Err(CoreError::Http {
                status_code: status.as_u16(),
                message: text.chars().take(300).collect(),
            });
        }
        let dto: TokenResponse = serde_json::from_slice(&body)?;
        let expires_in = dto.expires_in.unwrap_or(3600).max(60);
        Ok(GoogleOAuthToken {
            access_token: dto.access_token,
            refresh_token: dto.refresh_token.or(fallback_refresh),
            expires_at: Utc::now() + chrono::Duration::seconds(expires_in),
        })
    }
}

#[derive(Deserialize)]
struct TokenResponse {
    access_token: String,
    refresh_token: Option<String>,
    expires_in: Option<i64>,
}

async fn wait_for_loopback_code(listener: TcpListener) -> CoreResult<(String, Option<String>)> {
    let (mut stream, _) = listener.accept().await?;
    let mut buf = vec![0u8; 8192];
    let n = stream.read(&mut buf).await?;
    let req_text = String::from_utf8_lossy(&buf[..n]);
    let first_line = req_text.lines().next().unwrap_or("");
    let path_and_query = first_line.split_whitespace().nth(1).unwrap_or("/");
    let parsed = Url::parse(&format!("http://127.0.0.1{path_and_query}"))
        .map_err(|_| CoreError::AuthenticationRequired("无效的 OAuth 回调请求".to_string()))?;

    let mut code: Option<String> = None;
    let mut state: Option<String> = None;
    let mut error: Option<String> = None;
    for (k, v) in parsed.query_pairs() {
        match k.as_ref() {
            "code" => code = Some(v.into_owned()),
            "state" => state = Some(v.into_owned()),
            "error" => error = Some(v.into_owned()),
            _ => {}
        }
    }

    let html = if error.is_some() || code.is_none() {
        "<html><body><h3>Authorization failed. You may close this tab.</h3></body></html>"
    } else {
        "<html><body><h3>Charkle connected to Google Drive. You may close this tab.</h3></body></html>"
    };
    let response = format!(
        "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
        html.len(),
        html
    );
    let _ = stream.write_all(response.as_bytes()).await;
    let _ = stream.shutdown().await;

    if let Some(err) = error {
        return Err(CoreError::AuthenticationRequired(format!(
            "Google OAuth 授权被拒绝：{err}"
        )));
    }
    let code = code
        .ok_or_else(|| CoreError::AuthenticationRequired("OAuth 回调中缺少授权码。".to_string()))?;
    Ok((code, state))
}
