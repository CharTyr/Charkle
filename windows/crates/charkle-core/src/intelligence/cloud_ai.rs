//! Hybrid Cloud AI providers (`cloud_ai.rs`) mirroring
//! `Sources/CharkleCore/Intelligence/CloudAIProvider.swift`.
//!
//! Supports all 4 `CloudAIProviderKind` modes:
//! - `Disabled` (local-only, zero cloud calls)
//! - `Gemini` (`x-goog-api-key`, `models/{m}:generateContent` & `:embedContent`)
//! - `OpenAiCompatible` (OpenAI Chat Completions, Anthropic Messages, OpenAI Responses)
//! - `ChatGptSubscription` (PKCE OAuth Bearer token over OpenAI Responses API)

use std::sync::Arc;
use std::time::Duration;

use async_trait::async_trait;
use base64::engine::general_purpose::STANDARD as BASE64;
use base64::Engine;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use url::Url;

use crate::error::{CoreError, CoreResult};
use crate::intelligence::usage_tracker::{CloudAIUsageCategory, CloudAIUsageStore};
use crate::models::media::{
    AIProviderConfig, CloudAIProviderKind, CloudEnrichmentResult, CustomAIEndpointFormat,
};

pub const AI_API_KEY_SECRET_KEY: &str = "ai.provider.api_key.v1";

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AIConnectionTestResult {
    pub ok: bool,
    pub provider_label: String,
    pub model: String,
    pub message: String,
    pub latency_ms: u64,
}

#[async_trait]
pub trait CloudAIProvider: Send + Sync {
    fn provider_label(&self) -> &'static str;
    fn embedding_identity(&self) -> String;
    async fn embed(&self, text: &str) -> CoreResult<Vec<f32>>;
    async fn enrich(
        &self,
        text: &str,
        thumbnail_jpeg: Option<&[u8]>,
    ) -> CoreResult<CloudEnrichmentResult>;
    async fn complete_json(
        &self,
        instructions: &str,
        prompt: &str,
        images_jpeg: &[Vec<u8>],
    ) -> CoreResult<String>;
}

const ENRICHMENT_INSTRUCTION: &str = r#"You are a visual reference curator. Return ONLY valid JSON: {"description": "1 concise sentence in Chinese describing visual subject, lighting, mood, material", "tags": ["tag1", "tag2", "tag3", "tag4"]}."#;

fn validate_and_normalize_base(raw_base: &str, default_path: &str) -> CoreResult<Url> {
    let trimmed = raw_base.trim();
    let parsed = Url::parse(trimmed)
        .map_err(|e| CoreError::InvalidOperation(format!("无效的 AI 接口地址：{e}")))?;
    let host = parsed
        .host_str()
        .map(str::to_ascii_lowercase)
        .unwrap_or_default();
    let is_local = matches!(host.as_str(), "localhost" | "127.0.0.1" | "::1" | "[::1]");
    if parsed.scheme() != "https" && !(parsed.scheme() == "http" && is_local) {
        return Err(CoreError::InvalidOperation(
            "远程 AI 接口必须使用 HTTPS（仅 localhost 允许 HTTP）。".to_string(),
        ));
    }
    let mut normalized = parsed.to_string();
    while normalized.ends_with('/') {
        normalized.pop();
    }
    if parsed.path().is_empty() || parsed.path() == "/" {
        normalized = format!("{normalized}/{default_path}");
    }
    Url::parse(&normalized)
        .map_err(|e| CoreError::InvalidOperation(format!("规范化 AI 地址失败：{e}")))
}

fn parse_caption_json(raw: &str) -> CoreResult<(String, Vec<String>)> {
    let trimmed = raw.trim();
    let cleaned = match (trimmed.find('{'), trimmed.rfind('}')) {
        (Some(start), Some(end)) if start <= end => &trimmed[start..=end],
        _ => trimmed,
    };
    let val: Value = serde_json::from_str(cleaned).unwrap_or_else(|_| {
        json!({
            "description": trimmed.chars().take(180).collect::<String>(),
            "tags": []
        })
    });
    let description = val
        .get("description")
        .and_then(Value::as_str)
        .unwrap_or("")
        .trim()
        .to_string();
    let tags = val
        .get("tags")
        .and_then(Value::as_array)
        .map(|arr| {
            arr.iter()
                .filter_map(Value::as_str)
                .map(|s| s.trim().to_string())
                .filter(|s| !s.is_empty())
                .take(12)
                .collect()
        })
        .unwrap_or_default();
    Ok((description, tags))
}

fn checked_embedding(values: Vec<f32>) -> CoreResult<Vec<f32>> {
    if values.is_empty() || values.iter().any(|v| !v.is_finite()) {
        return Err(CoreError::InvalidPayload(
            "云端 AI 返回的向量 Embedding 为空或包含非法数值".to_string(),
        ));
    }
    Ok(values)
}

fn make_http_client() -> CoreResult<reqwest::Client> {
    Ok(reqwest::Client::builder()
        .timeout(Duration::from_secs(60))
        .user_agent("Charkle-Windows/1.0.1")
        .build()?)
}

async fn send_json_post(
    client: &reqwest::Client,
    url: &str,
    headers: &[(&str, String)],
    body: &Value,
) -> CoreResult<Value> {
    let mut req = client.post(url).header("Accept", "application/json");
    for (k, v) in headers {
        req = req.header(*k, v.as_str());
    }
    let resp = req.json(body).send().await?;
    let status = resp.status();
    let text = resp.text().await?;
    if !status.is_success() {
        let preview: String = text.chars().take(240).collect();
        return Err(CoreError::Http {
            status_code: status.as_u16(),
            message: preview,
        });
    }
    serde_json::from_str(&text)
        .map_err(|e| CoreError::InvalidPayload(format!("解析 AI JSON 响应失败：{e}")))
}

// ---------------------------------------------------------------------------
// 1. Google Gemini Provider
// ---------------------------------------------------------------------------

pub struct GeminiProvider {
    client: reqwest::Client,
    base: Url,
    config: AIProviderConfig,
    api_key: String,
    usage: Arc<CloudAIUsageStore>,
}

impl GeminiProvider {
    pub fn new(
        config: AIProviderConfig,
        api_key: String,
        usage: Arc<CloudAIUsageStore>,
    ) -> CoreResult<Self> {
        let key = api_key.trim().to_string();
        if key.is_empty() {
            return Err(CoreError::InvalidOperation(
                "请先填写 Google Gemini API 密钥。".to_string(),
            ));
        }
        let base = validate_and_normalize_base(&config.base_url, "v1beta")?;
        Ok(Self {
            client: make_http_client()?,
            base,
            config,
            api_key: key,
            usage,
        })
    }

    fn clean_model(model: &str) -> &str {
        model.trim().strip_prefix("models/").unwrap_or(model.trim())
    }
}

#[async_trait]
impl CloudAIProvider for GeminiProvider {
    fn provider_label(&self) -> &'static str {
        "Google Gemini"
    }

    fn embedding_identity(&self) -> String {
        format!("gemini:{}:{}", self.base, self.config.embedding_model)
    }

    async fn embed(&self, text: &str) -> CoreResult<Vec<f32>> {
        let model = Self::clean_model(&self.config.embedding_model);
        let url = format!("{}/models/{model}:embedContent", self.base);
        let body = json!({ "content": { "parts": [{ "text": text }] } });
        let resp = send_json_post(
            &self.client,
            &url,
            &[("x-goog-api-key", self.api_key.clone())],
            &body,
        )
        .await?;
        let vals = resp["embedding"]["values"]
            .as_array()
            .map(|a| {
                a.iter()
                    .filter_map(|v| v.as_f64().map(|f| f as f32))
                    .collect::<Vec<_>>()
            })
            .unwrap_or_default();
        self.usage.record(
            CloudAIUsageCategory::Standard,
            self.provider_label(),
            model,
            (text.len() as u64 / 4).max(1),
            0,
            None,
        );
        checked_embedding(vals)
    }

    async fn enrich(
        &self,
        text: &str,
        thumbnail_jpeg: Option<&[u8]>,
    ) -> CoreResult<CloudEnrichmentResult> {
        let model = Self::clean_model(&self.config.chat_model);
        let url = format!("{}/models/{model}:generateContent", self.base);
        let mut parts =
            vec![json!({ "text": format!("{ENRICHMENT_INSTRUCTION}\n\nReference:\n{text}") })];
        if self.config.send_thumbnails_to_cloud {
            if let Some(jpeg) = thumbnail_jpeg {
                parts.push(json!({
                    "inline_data": { "mime_type": "image/jpeg", "data": BASE64.encode(jpeg) }
                }));
            }
        }
        let body = json!({
            "contents": [{ "parts": parts }],
            "generationConfig": { "responseMimeType": "application/json" }
        });
        let resp = send_json_post(
            &self.client,
            &url,
            &[("x-goog-api-key", self.api_key.clone())],
            &body,
        )
        .await?;
        let in_tok = resp["usageMetadata"]["promptTokenCount"]
            .as_u64()
            .unwrap_or(0);
        let out_tok = resp["usageMetadata"]["candidatesTokenCount"]
            .as_u64()
            .unwrap_or(0);
        let tot_tok = resp["usageMetadata"]["totalTokenCount"].as_u64();
        self.usage.record(
            CloudAIUsageCategory::Standard,
            self.provider_label(),
            model,
            in_tok,
            out_tok,
            tot_tok,
        );
        let completion = resp["candidates"][0]["content"]["parts"]
            .as_array()
            .map(|arr| {
                arr.iter()
                    .filter_map(|p| p.get("text").and_then(Value::as_str))
                    .collect::<Vec<_>>()
                    .join("\n")
            })
            .unwrap_or_default();
        let (description, suggested_tags) = parse_caption_json(&completion)?;
        let embedding = if !self.config.embedding_model.trim().is_empty() {
            self.embed(&format!("{text}\n{description}")).await.ok()
        } else {
            None
        };
        Ok(CloudEnrichmentResult {
            description: (!description.is_empty()).then_some(description),
            suggested_tags,
            embedding,
        })
    }

    async fn complete_json(
        &self,
        instructions: &str,
        prompt: &str,
        images_jpeg: &[Vec<u8>],
    ) -> CoreResult<String> {
        let model = Self::clean_model(&self.config.chat_model);
        let url = format!("{}/models/{model}:generateContent", self.base);
        let mut parts = vec![json!({ "text": prompt })];
        if self.config.send_thumbnails_to_cloud {
            for jpeg in images_jpeg {
                parts.push(json!({
                    "inline_data": { "mime_type": "image/jpeg", "data": BASE64.encode(jpeg) }
                }));
            }
        }
        let mut body = json!({
            "contents": [{ "parts": parts }],
            "generationConfig": { "responseMimeType": "application/json" }
        });
        if !instructions.trim().is_empty() {
            body["systemInstruction"] = json!({ "parts": [{ "text": instructions }] });
        }
        let resp = send_json_post(
            &self.client,
            &url,
            &[("x-goog-api-key", self.api_key.clone())],
            &body,
        )
        .await?;
        let in_tok = resp["usageMetadata"]["promptTokenCount"]
            .as_u64()
            .unwrap_or(0);
        let out_tok = resp["usageMetadata"]["candidatesTokenCount"]
            .as_u64()
            .unwrap_or(0);
        let tot_tok = resp["usageMetadata"]["totalTokenCount"].as_u64();
        self.usage.record(
            CloudAIUsageCategory::Standard,
            self.provider_label(),
            model,
            in_tok,
            out_tok,
            tot_tok,
        );
        Ok(resp["candidates"][0]["content"]["parts"]
            .as_array()
            .map(|arr| {
                arr.iter()
                    .filter_map(|p| p.get("text").and_then(Value::as_str))
                    .collect::<Vec<_>>()
                    .join("\n")
            })
            .unwrap_or_default())
    }
}

// ---------------------------------------------------------------------------
// 2. OpenAI Chat Completions Compatible Provider
// ---------------------------------------------------------------------------

pub struct OpenAICompatibleProvider {
    client: reqwest::Client,
    base: Url,
    config: AIProviderConfig,
    api_key: Option<String>,
    usage: Arc<CloudAIUsageStore>,
}

impl OpenAICompatibleProvider {
    pub fn new(
        config: AIProviderConfig,
        api_key: Option<String>,
        usage: Arc<CloudAIUsageStore>,
    ) -> CoreResult<Self> {
        let base = validate_and_normalize_base(&config.base_url, "v1")?;
        let cleaned = api_key
            .map(|s| s.trim().to_string())
            .filter(|s| !s.is_empty());
        Ok(Self {
            client: make_http_client()?,
            base,
            config,
            api_key: cleaned,
            usage,
        })
    }

    fn auth_headers(&self) -> Vec<(&'static str, String)> {
        match &self.api_key {
            Some(k) => vec![("Authorization", format!("Bearer {k}"))],
            None => Vec::new(),
        }
    }
}

#[async_trait]
impl CloudAIProvider for OpenAICompatibleProvider {
    fn provider_label(&self) -> &'static str {
        "OpenAI 兼容"
    }

    fn embedding_identity(&self) -> String {
        format!("openai:{}:{}", self.base, self.config.embedding_model)
    }

    async fn embed(&self, text: &str) -> CoreResult<Vec<f32>> {
        let url = format!("{}/embeddings", self.base);
        let body = json!({ "model": self.config.embedding_model, "input": text });
        let resp = send_json_post(&self.client, &url, &self.auth_headers(), &body).await?;
        let vals = resp["data"][0]["embedding"]
            .as_array()
            .map(|a| {
                a.iter()
                    .filter_map(|v| v.as_f64().map(|f| f as f32))
                    .collect::<Vec<_>>()
            })
            .unwrap_or_default();
        self.usage.record(
            CloudAIUsageCategory::Standard,
            self.provider_label(),
            &self.config.embedding_model,
            resp["usage"]["prompt_tokens"].as_u64().unwrap_or(0),
            0,
            resp["usage"]["total_tokens"].as_u64(),
        );
        checked_embedding(vals)
    }

    async fn enrich(
        &self,
        text: &str,
        thumbnail_jpeg: Option<&[u8]>,
    ) -> CoreResult<CloudEnrichmentResult> {
        let url = format!("{}/chat/completions", self.base);
        let prompt = format!("{ENRICHMENT_INSTRUCTION}\n\nReference:\n{text}");
        let content = if self.config.send_thumbnails_to_cloud {
            if let Some(jpeg) = thumbnail_jpeg {
                json!([
                    { "type": "text", "text": prompt },
                    { "type": "image_url", "image_url": { "url": format!("data:image/jpeg;base64,{}", BASE64.encode(jpeg)) } }
                ])
            } else {
                json!(prompt)
            }
        } else {
            json!(prompt)
        };
        let body = json!({
            "model": self.config.chat_model,
            "messages": [{ "role": "user", "content": content }]
        });
        let resp = send_json_post(&self.client, &url, &self.auth_headers(), &body).await?;
        self.usage.record(
            CloudAIUsageCategory::Standard,
            self.provider_label(),
            &self.config.chat_model,
            resp["usage"]["prompt_tokens"].as_u64().unwrap_or(0),
            resp["usage"]["completion_tokens"].as_u64().unwrap_or(0),
            resp["usage"]["total_tokens"].as_u64(),
        );
        let completion = resp["choices"][0]["message"]["content"]
            .as_str()
            .unwrap_or("");
        let (description, suggested_tags) = parse_caption_json(completion)?;
        let embedding = if !self.config.embedding_model.trim().is_empty() {
            self.embed(&format!("{text}\n{description}")).await.ok()
        } else {
            None
        };
        Ok(CloudEnrichmentResult {
            description: (!description.is_empty()).then_some(description),
            suggested_tags,
            embedding,
        })
    }

    async fn complete_json(
        &self,
        instructions: &str,
        prompt: &str,
        images_jpeg: &[Vec<u8>],
    ) -> CoreResult<String> {
        let url = format!("{}/chat/completions", self.base);
        let mut messages = Vec::new();
        if !instructions.trim().is_empty() {
            messages.push(json!({ "role": "system", "content": instructions }));
        }
        let user_content = if self.config.send_thumbnails_to_cloud && !images_jpeg.is_empty() {
            let mut parts = vec![json!({ "type": "text", "text": prompt })];
            for jpeg in images_jpeg {
                parts.push(json!({
                    "type": "image_url",
                    "image_url": { "url": format!("data:image/jpeg;base64,{}", BASE64.encode(jpeg)) }
                }));
            }
            json!(parts)
        } else {
            json!(prompt)
        };
        messages.push(json!({ "role": "user", "content": user_content }));
        let body = json!({ "model": self.config.chat_model, "messages": messages });
        let resp = send_json_post(&self.client, &url, &self.auth_headers(), &body).await?;
        self.usage.record(
            CloudAIUsageCategory::Standard,
            self.provider_label(),
            &self.config.chat_model,
            resp["usage"]["prompt_tokens"].as_u64().unwrap_or(0),
            resp["usage"]["completion_tokens"].as_u64().unwrap_or(0),
            resp["usage"]["total_tokens"].as_u64(),
        );
        Ok(resp["choices"][0]["message"]["content"]
            .as_str()
            .unwrap_or("")
            .to_string())
    }
}

// ---------------------------------------------------------------------------
// 3. OpenAI Responses API Provider (also backs ChatGPT Subscription mode)
// ---------------------------------------------------------------------------

pub struct OpenAIResponsesProvider {
    client: reqwest::Client,
    base: Url,
    config: AIProviderConfig,
    api_key: Option<String>,
    label: &'static str,
    usage: Arc<CloudAIUsageStore>,
}

impl OpenAIResponsesProvider {
    pub fn new(
        config: AIProviderConfig,
        api_key: Option<String>,
        label: &'static str,
        usage: Arc<CloudAIUsageStore>,
    ) -> CoreResult<Self> {
        let base = validate_and_normalize_base(&config.base_url, "v1")?;
        let cleaned = api_key
            .map(|s| s.trim().to_string())
            .filter(|s| !s.is_empty());
        Ok(Self {
            client: make_http_client()?,
            base,
            config,
            api_key: cleaned,
            label,
            usage,
        })
    }

    fn auth_headers(&self) -> Vec<(&'static str, String)> {
        match &self.api_key {
            Some(k) => vec![("Authorization", format!("Bearer {k}"))],
            None => Vec::new(),
        }
    }

    fn extract_output_text(resp: &Value) -> String {
        if let Some(direct) = resp.get("output_text").and_then(Value::as_str) {
            if !direct.is_empty() {
                return direct.to_string();
            }
        }
        resp.get("output")
            .and_then(Value::as_array)
            .map(|items| {
                items
                    .iter()
                    .filter_map(|it| it.get("content").and_then(Value::as_array))
                    .flatten()
                    .filter_map(|p| p.get("text").and_then(Value::as_str))
                    .collect::<Vec<_>>()
                    .join("\n")
            })
            .unwrap_or_default()
    }
}

#[async_trait]
impl CloudAIProvider for OpenAIResponsesProvider {
    fn provider_label(&self) -> &'static str {
        self.label
    }

    fn embedding_identity(&self) -> String {
        format!(
            "openai-responses:{}:{}",
            self.base, self.config.embedding_model
        )
    }

    async fn embed(&self, text: &str) -> CoreResult<Vec<f32>> {
        let url = format!("{}/embeddings", self.base);
        let body = json!({ "model": self.config.embedding_model, "input": text });
        let resp = send_json_post(&self.client, &url, &self.auth_headers(), &body).await?;
        let vals = resp["data"][0]["embedding"]
            .as_array()
            .map(|a| {
                a.iter()
                    .filter_map(|v| v.as_f64().map(|f| f as f32))
                    .collect::<Vec<_>>()
            })
            .unwrap_or_default();
        self.usage.record(
            CloudAIUsageCategory::Standard,
            self.label,
            &self.config.embedding_model,
            resp["usage"]["prompt_tokens"].as_u64().unwrap_or(0),
            0,
            resp["usage"]["total_tokens"].as_u64(),
        );
        checked_embedding(vals)
    }

    async fn enrich(
        &self,
        text: &str,
        thumbnail_jpeg: Option<&[u8]>,
    ) -> CoreResult<CloudEnrichmentResult> {
        let url = format!("{}/responses", self.base);
        let prompt = format!("{ENRICHMENT_INSTRUCTION}\n\nReference:\n{text}");
        let mut parts = vec![json!({ "type": "input_text", "text": prompt })];
        if self.config.send_thumbnails_to_cloud {
            if let Some(jpeg) = thumbnail_jpeg {
                parts.push(json!({
                    "type": "input_image",
                    "image_url": format!("data:image/jpeg;base64,{}", BASE64.encode(jpeg))
                }));
            }
        }
        let body = json!({
            "model": self.config.chat_model,
            "input": [{ "role": "user", "content": parts }]
        });
        let resp = send_json_post(&self.client, &url, &self.auth_headers(), &body).await?;
        self.usage.record(
            CloudAIUsageCategory::Standard,
            self.label,
            &self.config.chat_model,
            resp["usage"]["input_tokens"].as_u64().unwrap_or(0),
            resp["usage"]["output_tokens"].as_u64().unwrap_or(0),
            resp["usage"]["total_tokens"].as_u64(),
        );
        let completion = Self::extract_output_text(&resp);
        let (description, suggested_tags) = parse_caption_json(&completion)?;
        let embedding = if !self.config.embedding_model.trim().is_empty() {
            self.embed(&format!("{text}\n{description}")).await.ok()
        } else {
            None
        };
        Ok(CloudEnrichmentResult {
            description: (!description.is_empty()).then_some(description),
            suggested_tags,
            embedding,
        })
    }

    async fn complete_json(
        &self,
        instructions: &str,
        prompt: &str,
        images_jpeg: &[Vec<u8>],
    ) -> CoreResult<String> {
        let url = format!("{}/responses", self.base);
        let mut parts = vec![json!({ "type": "input_text", "text": prompt })];
        if self.config.send_thumbnails_to_cloud {
            for jpeg in images_jpeg {
                parts.push(json!({
                    "type": "input_image",
                    "image_url": format!("data:image/jpeg;base64,{}", BASE64.encode(jpeg))
                }));
            }
        }
        let mut body = json!({
            "model": self.config.chat_model,
            "input": [{ "role": "user", "content": parts }]
        });
        if !instructions.trim().is_empty() {
            body["instructions"] = json!(instructions);
        }
        let resp = send_json_post(&self.client, &url, &self.auth_headers(), &body).await?;
        self.usage.record(
            CloudAIUsageCategory::Standard,
            self.label,
            &self.config.chat_model,
            resp["usage"]["input_tokens"].as_u64().unwrap_or(0),
            resp["usage"]["output_tokens"].as_u64().unwrap_or(0),
            resp["usage"]["total_tokens"].as_u64(),
        );
        Ok(Self::extract_output_text(&resp))
    }
}

// ---------------------------------------------------------------------------
// 4. Anthropic Messages Provider
// ---------------------------------------------------------------------------

pub struct AnthropicMessagesProvider {
    client: reqwest::Client,
    base: Url,
    config: AIProviderConfig,
    api_key: String,
    usage: Arc<CloudAIUsageStore>,
}

impl AnthropicMessagesProvider {
    pub fn new(
        config: AIProviderConfig,
        api_key: String,
        usage: Arc<CloudAIUsageStore>,
    ) -> CoreResult<Self> {
        let key = api_key.trim().to_string();
        if key.is_empty() {
            return Err(CoreError::InvalidOperation(
                "请先填写 Anthropic API 密钥。".to_string(),
            ));
        }
        let base = validate_and_normalize_base(&config.base_url, "v1")?;
        Ok(Self {
            client: make_http_client()?,
            base,
            config,
            api_key: key,
            usage,
        })
    }

    fn headers(&self) -> Vec<(&'static str, String)> {
        vec![
            ("x-api-key", self.api_key.clone()),
            ("anthropic-version", "2023-06-01".to_string()),
        ]
    }
}

#[async_trait]
impl CloudAIProvider for AnthropicMessagesProvider {
    fn provider_label(&self) -> &'static str {
        "Anthropic"
    }

    fn embedding_identity(&self) -> String {
        format!("anthropic:{}:{}", self.base, self.config.chat_model)
    }

    async fn embed(&self, _text: &str) -> CoreResult<Vec<f32>> {
        Err(CoreError::InvalidOperation(
            "Anthropic Messages 接口不提供向量 Embedding 端点，将自动使用本机离线视觉特征搜索。"
                .to_string(),
        ))
    }

    async fn enrich(
        &self,
        text: &str,
        thumbnail_jpeg: Option<&[u8]>,
    ) -> CoreResult<CloudEnrichmentResult> {
        let url = format!("{}/messages", self.base);
        let mut blocks = Vec::new();
        if self.config.send_thumbnails_to_cloud {
            if let Some(jpeg) = thumbnail_jpeg {
                blocks.push(json!({
                    "type": "image",
                    "source": {
                        "type": "base64",
                        "media_type": "image/jpeg",
                        "data": BASE64.encode(jpeg)
                    }
                }));
            }
        }
        blocks.push(json!({ "type": "text", "text": format!("{ENRICHMENT_INSTRUCTION}\n\nReference:\n{text}") }));
        let body = json!({
            "model": self.config.chat_model,
            "max_tokens": 1024,
            "messages": [{ "role": "user", "content": blocks }]
        });
        let resp = send_json_post(&self.client, &url, &self.headers(), &body).await?;
        self.usage.record(
            CloudAIUsageCategory::Standard,
            self.provider_label(),
            &self.config.chat_model,
            resp["usage"]["input_tokens"].as_u64().unwrap_or(0),
            resp["usage"]["output_tokens"].as_u64().unwrap_or(0),
            None,
        );
        let joined = resp["content"]
            .as_array()
            .map(|a| {
                a.iter()
                    .filter_map(|b| b.get("text").and_then(Value::as_str))
                    .collect::<Vec<_>>()
                    .join("\n")
            })
            .unwrap_or_default();
        let (description, suggested_tags) = parse_caption_json(&joined)?;
        Ok(CloudEnrichmentResult {
            description: (!description.is_empty()).then_some(description),
            suggested_tags,
            embedding: None,
        })
    }

    async fn complete_json(
        &self,
        instructions: &str,
        prompt: &str,
        images_jpeg: &[Vec<u8>],
    ) -> CoreResult<String> {
        let url = format!("{}/messages", self.base);
        let mut blocks = Vec::new();
        if self.config.send_thumbnails_to_cloud {
            for jpeg in images_jpeg {
                blocks.push(json!({
                    "type": "image",
                    "source": {
                        "type": "base64",
                        "media_type": "image/jpeg",
                        "data": BASE64.encode(jpeg)
                    }
                }));
            }
        }
        blocks.push(json!({ "type": "text", "text": prompt }));
        let mut body = json!({
            "model": self.config.chat_model,
            "max_tokens": 2048,
            "messages": [{ "role": "user", "content": blocks }]
        });
        if !instructions.trim().is_empty() {
            body["system"] = json!(instructions);
        }
        let resp = send_json_post(&self.client, &url, &self.headers(), &body).await?;
        self.usage.record(
            CloudAIUsageCategory::Standard,
            self.provider_label(),
            &self.config.chat_model,
            resp["usage"]["input_tokens"].as_u64().unwrap_or(0),
            resp["usage"]["output_tokens"].as_u64().unwrap_or(0),
            None,
        );
        Ok(resp["content"]
            .as_array()
            .map(|a| {
                a.iter()
                    .filter_map(|b| b.get("text").and_then(Value::as_str))
                    .collect::<Vec<_>>()
                    .join("\n")
            })
            .unwrap_or_default())
    }
}

/// Instantiates the active `CloudAIProvider` from `AIProviderConfig` and DPAPI-retrieved secret.
pub fn build_cloud_ai_provider(
    config: &AIProviderConfig,
    secret_token: Option<String>,
    usage: Arc<CloudAIUsageStore>,
) -> CoreResult<Option<Box<dyn CloudAIProvider>>> {
    match config.provider {
        CloudAIProviderKind::Disabled => Ok(None),
        CloudAIProviderKind::Gemini => Ok(Some(Box::new(GeminiProvider::new(
            config.clone(),
            secret_token.unwrap_or_default(),
            usage,
        )?))),
        CloudAIProviderKind::ChatGptSubscription => {
            let token = secret_token
                .map(|s| s.trim().to_string())
                .filter(|s| !s.is_empty())
                .ok_or_else(|| {
                    CoreError::InvalidOperation(
                        "请先在「设置 → AI 智能」中登录 ChatGPT 订阅账号。".to_string(),
                    )
                })?;
            let mut effective = config.clone();
            if effective.base_url.trim().is_empty()
                || effective
                    .base_url
                    .contains("generativelanguage.googleapis.com")
            {
                effective.base_url = "https://api.openai.com/v1".to_string();
            }
            Ok(Some(Box::new(OpenAIResponsesProvider::new(
                effective,
                Some(token),
                "ChatGPT 订阅",
                usage,
            )?)))
        }
        CloudAIProviderKind::OpenAiCompatible => match config.custom_endpoint_format {
            CustomAIEndpointFormat::OpenAiChatCompletions => Ok(Some(Box::new(
                OpenAICompatibleProvider::new(config.clone(), secret_token, usage)?,
            ))),
            CustomAIEndpointFormat::OpenAiResponses => {
                Ok(Some(Box::new(OpenAIResponsesProvider::new(
                    config.clone(),
                    secret_token,
                    "OpenAI Responses",
                    usage,
                )?)))
            }
            CustomAIEndpointFormat::AnthropicMessages => {
                Ok(Some(Box::new(AnthropicMessagesProvider::new(
                    config.clone(),
                    secret_token.unwrap_or_default(),
                    usage,
                )?)))
            }
        },
    }
}

/// Executes a lightweight JSON round-trip probe to verify credentials, endpoint & model reachability.
pub async fn test_cloud_ai_connection(
    config: &AIProviderConfig,
    secret_token: Option<String>,
    usage: Arc<CloudAIUsageStore>,
) -> AIConnectionTestResult {
    let start = std::time::Instant::now();
    if config.provider == CloudAIProviderKind::Disabled {
        return AIConnectionTestResult {
            ok: true,
            provider_label: "纯本机离线模式".to_string(),
            model: "local-offline".to_string(),
            message: "已关闭云端 AI，所有检索与情绪板均在本机离线运行。".to_string(),
            latency_ms: 0,
        };
    }

    match build_cloud_ai_provider(config, secret_token, usage) {
        Err(err) => AIConnectionTestResult {
            ok: false,
            provider_label: format!("{:?}", config.provider),
            model: config.chat_model.clone(),
            message: err.to_string(),
            latency_ms: start.elapsed().as_millis() as u64,
        },
        Ok(None) => AIConnectionTestResult {
            ok: true,
            provider_label: "纯本机离线模式".to_string(),
            model: "local-offline".to_string(),
            message: "纯本机模式就绪。".to_string(),
            latency_ms: 0,
        },
        Ok(Some(provider)) => {
            let label = provider.provider_label().to_string();
            match provider
                .complete_json(
                    "Reply with valid JSON: {\"ok\": true}",
                    "Connection check",
                    &[],
                )
                .await
            {
                Ok(text) => AIConnectionTestResult {
                    ok: true,
                    provider_label: label,
                    model: config.chat_model.clone(),
                    message: format!(
                        "连接成功（{}），已收到模型响应。",
                        text.trim().chars().take(48).collect::<String>()
                    ),
                    latency_ms: start.elapsed().as_millis() as u64,
                },
                Err(err) => AIConnectionTestResult {
                    ok: false,
                    provider_label: label,
                    model: config.chat_model.clone(),
                    message: err.to_string(),
                    latency_ms: start.elapsed().as_millis() as u64,
                },
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    use tokio::net::TcpListener;

    async fn spawn_mock_http_server(response_json: &'static str) -> String {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        tokio::spawn(async move {
            for _ in 0..4 {
                let Ok((mut stream, _)) = listener.accept().await else {
                    break;
                };
                let mut buf = vec![0u8; 8192];
                let _ = stream.read(&mut buf).await;
                let http = format!(
                    "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
                    response_json.len(),
                    response_json
                );
                let _ = stream.write_all(http.as_bytes()).await;
                let _ = stream.shutdown().await;
            }
        });
        format!("http://127.0.0.1:{}", addr.port())
    }

    #[tokio::test]
    async fn openai_chat_anthropic_and_gemini_providers_parse_responses_and_record_usage() {
        // 1. OpenAI Chat Completions mock
        let base_oa = spawn_mock_http_server(
            r#"{"choices":[{"message":{"content":"{\"description\":\"暖阳建筑立面\",\"tags\":[\"建筑\",\"暖光\"]}"}}],"usage":{"prompt_tokens":50,"completion_tokens":20,"total_tokens":70}}"#,
        )
        .await;
        let usage = Arc::new(CloudAIUsageStore::in_memory());
        let cfg_oa = AIProviderConfig {
            provider: CloudAIProviderKind::OpenAiCompatible,
            custom_endpoint_format: CustomAIEndpointFormat::OpenAiChatCompletions,
            base_url: base_oa,
            chat_model: "gpt-4.1-mini".to_string(),
            embedding_model: String::new(),
            auto_analyze_on_import: true,
            send_thumbnails_to_cloud: false,
        };
        let provider_oa =
            build_cloud_ai_provider(&cfg_oa, Some("sk-test".into()), Arc::clone(&usage))
                .unwrap()
                .unwrap();
        let enriched = provider_oa
            .enrich("Architecture sample", None)
            .await
            .unwrap();
        assert_eq!(enriched.description.as_deref(), Some("暖阳建筑立面"));
        assert_eq!(enriched.suggested_tags, vec!["建筑", "暖光"]);
        assert_eq!(usage.snapshot().standard.total_tokens, 70);

        // 2. Anthropic Messages mock
        let base_anth = spawn_mock_http_server(
            r#"{"content":[{"type":"text","text":"{\"description\":\"极简杂志网格\",\"tags\":[\"排版\"]}"}],"usage":{"input_tokens":40,"output_tokens":15}}"#,
        )
        .await;
        let cfg_anth = AIProviderConfig {
            provider: CloudAIProviderKind::OpenAiCompatible,
            custom_endpoint_format: CustomAIEndpointFormat::AnthropicMessages,
            base_url: base_anth,
            chat_model: "claude-sonnet-4-5".to_string(),
            embedding_model: String::new(),
            auto_analyze_on_import: false,
            send_thumbnails_to_cloud: true,
        };
        let provider_anth =
            build_cloud_ai_provider(&cfg_anth, Some("sk-ant-test".into()), Arc::clone(&usage))
                .unwrap()
                .unwrap();
        let res_anth = provider_anth.enrich("Editorial grid", None).await.unwrap();
        assert_eq!(res_anth.description.as_deref(), Some("极简杂志网格"));
        assert_eq!(usage.snapshot().standard.total_tokens, 125);

        // 3. Gemini mock
        let base_gem = spawn_mock_http_server(
            r#"{"candidates":[{"content":{"parts":[{"text":"{\"ok\":true}"}]}}],"usageMetadata":{"promptTokenCount":12,"candidatesTokenCount":8,"totalTokenCount":20}}"#,
        )
        .await;
        let cfg_gem = AIProviderConfig {
            provider: CloudAIProviderKind::Gemini,
            custom_endpoint_format: CustomAIEndpointFormat::OpenAiChatCompletions,
            base_url: base_gem,
            chat_model: "gemini-2.5-flash".to_string(),
            embedding_model: String::new(),
            auto_analyze_on_import: false,
            send_thumbnails_to_cloud: true,
        };
        let probe =
            test_cloud_ai_connection(&cfg_gem, Some("gem-key".into()), Arc::clone(&usage)).await;
        assert!(probe.ok);
        assert_eq!(usage.snapshot().standard.today_requests, 3);
    }
}
