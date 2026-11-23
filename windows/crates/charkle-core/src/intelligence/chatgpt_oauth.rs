//! Sign in with ChatGPT PKCE OAuth 2.0 client (`chatgpt_oauth.rs`),
//! mirroring `Sources/CharkleCore/Intelligence/ChatGPTSignInClient.swift`.
//!
//! Tokens are stored exclusively inside `SecretVault` (Windows DPAPI / Credential Manager)
//! under `ai.chatgpt.connection.v1` — zero plaintext credentials are ever written to disk.

use std::sync::Arc;

use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use base64::Engine;
use chrono::{DateTime, Utc};
use rand::RngCore;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use url::Url;

use crate::error::{CoreError, CoreResult};
use crate::models::media::{ChatGPTAccountSession, ChatGPTConnectionStatus};
use crate::traits::SecretVault;

pub const CHATGPT_VAULT_KEY: &str = "ai.chatgpt.connection.v1";
pub const CHATGPT_ISSUER: &str = "https://auth.openai.com";
pub const CHATGPT_RESOURCE: &str = "https://api.openai.com/v1";
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

pub struct ChatGPTSignInClient {
    vault: Arc<dyn SecretVault>,
}

impl ChatGPTSignInClient {
    pub fn new(vault: Arc<dyn SecretVault>) -> Self {
        Self { vault }
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
        let conn = self.load_connection().await.ok_or_else(|| {
            CoreError::InvalidOperation(
                "请先在「设置 → AI 智能」中登录 ChatGPT 订阅账号。".to_string(),
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
        conn.access_token.filter(|t| !t.is_empty()).ok_or_else(|| {
            CoreError::InvalidOperation("ChatGPT 访问令牌缺失，请重新登录。".to_string())
        })
    }

    pub async fn disconnect(&self) -> CoreResult<()> {
        self.vault
            .delete_secret(CHATGPT_VAULT_KEY)
            .await
            .map_err(CoreError::InvalidOperation)
    }

    async fn load_connection(&self) -> Option<StoredChatGPTConnection> {
        let raw = self.vault.get_secret(CHATGPT_VAULT_KEY).await.ok()??;
        serde_json::from_str(&raw).ok()
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
