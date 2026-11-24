//! TypeSafe System One (`Jev`) visual judgment & spatial grounding HTTP client (`typesafe.rs`),
//! mirroring `Sources/CharkleCore/Intelligence/TypeSafeSystemOneClient.swift`.

use std::collections::HashMap;
use std::sync::Arc;
use std::time::Duration;

use reqwest::multipart::{Form, Part};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use url::Url;

use crate::error::{CoreError, CoreResult};
use crate::intelligence::usage_tracker::{CloudAIUsageCategory, CloudAIUsageStore};
use crate::models::media::TypeSafeModelInfo;
use crate::models::moodboard::NormalizedCropRect;

pub const TYPESAFE_API_KEY_SECRET_KEY: &str = "ai.typesafe.api_key.v1";
pub const IMAGES_DANGER_ZONE_HEADER: &str = "TypeSafe-Danger-Zone-Images";

#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
pub struct TypeSafeBoxCoordinates {
    pub top: f64,
    pub bottom: f64,
    pub left: f64,
    pub right: f64,
}

impl TypeSafeBoxCoordinates {
    pub fn normalized_crop_rect(self) -> NormalizedCropRect {
        let left = if self.left.is_finite() {
            self.left
        } else {
            0.0
        };
        let top = if self.top.is_finite() { self.top } else { 0.0 };
        let right = if self.right.is_finite() {
            self.right
        } else {
            1.0
        };
        let bottom = if self.bottom.is_finite() {
            self.bottom
        } else {
            1.0
        };
        let x = left.clamp(0.0, 1.0);
        let y = top.clamp(0.0, 1.0);
        let r = right.clamp(x, 1.0);
        let b = bottom.clamp(y, 1.0);
        NormalizedCropRect {
            x,
            y,
            width: (r - x).max(0.01),
            height: (b - y).max(0.01),
        }
        .clamped()
    }
}

#[derive(Debug, Clone)]
pub struct TypeSafeImageAttachment {
    pub reference_key: String,
    pub part_name: String,
    pub format: String,
    pub data: Vec<u8>,
}

impl TypeSafeImageAttachment {
    pub fn mime_type(&self) -> &'static str {
        if self.format.eq_ignore_ascii_case("png") {
            "image/png"
        } else {
            "image/jpeg"
        }
    }
}

#[derive(Debug, Clone)]
pub enum TypeSafeQuestion {
    Noul {
        instructions: String,
        true_criteria: Option<String>,
        false_criteria: Option<String>,
    },
    Box {
        instructions: String,
    },
    Choice {
        instructions: String,
        criteria: HashMap<String, String>,
    },
    Score {
        instructions: String,
        criteria: Vec<String>,
    },
}

impl TypeSafeQuestion {
    fn uses_danger_zone_images(&self) -> bool {
        matches!(self, Self::Box { .. })
    }

    fn to_json(&self) -> Value {
        match self {
            Self::Noul {
                instructions,
                true_criteria,
                false_criteria,
            } => {
                let mut obj = json!({ "type": "noul", "instructions": instructions });
                if true_criteria.is_some() || false_criteria.is_some() {
                    let mut crit = serde_json::Map::new();
                    if let Some(t) = true_criteria {
                        crit.insert("true".to_string(), json!(t));
                    }
                    if let Some(f) = false_criteria {
                        crit.insert("false".to_string(), json!(f));
                    }
                    obj["criteria"] = Value::Object(crit);
                }
                obj
            }
            Self::Box { instructions } => {
                json!({ "type": "box", "instructions": instructions })
            }
            Self::Choice {
                instructions,
                criteria,
            } => json!({
                "type": "choice",
                "instructions": instructions,
                "criteria": criteria
            }),
            Self::Score {
                instructions,
                criteria,
            } => json!({
                "type": "score",
                "instructions": instructions,
                "criteria": criteria
            }),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Deserialize)]
#[serde(tag = "type", rename_all = "camelCase")]
pub enum TypeSafeAnswer {
    Noul {
        noul: f64,
    },
    Box {
        #[serde(rename = "box")]
        coords: TypeSafeBoxCoordinates,
        #[serde(default)]
        confidence: Option<f64>,
    },
    Choice {
        choice: String,
        #[serde(default)]
        confidence: Option<f64>,
        #[serde(default)]
        probabilities: HashMap<String, f64>,
    },
    Score {
        score: f64,
        #[serde(default)]
        confidence: Option<f64>,
        #[serde(default)]
        probabilities: HashMap<String, f64>,
        #[serde(default)]
        legend: HashMap<String, String>,
    },
}

#[derive(Debug, Clone, Deserialize)]
pub struct TypeSafeUsage {
    #[serde(default)]
    pub input_tokens: u64,
    #[serde(default)]
    pub output_tokens: u64,
}

#[derive(Debug, Clone, Deserialize)]
pub struct TypeSafeSystemOneResponse {
    #[serde(default)]
    pub model: String,
    #[serde(default)]
    pub answers: HashMap<String, TypeSafeAnswer>,
    #[serde(default)]
    pub usage: Option<TypeSafeUsage>,
}

pub struct TypeSafeSystemOneClient {
    client: reqwest::Client,
    base_url: Url,
    api_key: String,
    usage: Arc<CloudAIUsageStore>,
}

impl TypeSafeSystemOneClient {
    pub fn new(base_url: &str, api_key: &str, usage: Arc<CloudAIUsageStore>) -> CoreResult<Self> {
        let trimmed = base_url.trim();
        let effective = if trimmed.is_empty() {
            "https://api.typesafe.ai"
        } else {
            trimmed
        };
        let parsed = Url::parse(effective)
            .map_err(|e| CoreError::InvalidOperation(format!("无效的 TypeSafe 地址：{e}")))?;
        let host = parsed
            .host_str()
            .map(str::to_ascii_lowercase)
            .unwrap_or_default();
        let is_local = matches!(host.as_str(), "localhost" | "127.0.0.1" | "::1" | "[::1]");
        if parsed.scheme() != "https" && !(parsed.scheme() == "http" && is_local) {
            return Err(CoreError::InvalidOperation(
                "无效的 TypeSafe 服务地址，远程接口请使用 HTTPS。".to_string(),
            ));
        }
        let key = api_key.trim().to_string();
        if key.is_empty() {
            return Err(CoreError::InvalidOperation(
                "请先在「设置 → AI 智能」中填写 TypeSafe API 密钥。".to_string(),
            ));
        }
        let mut normalized = parsed.to_string();
        while normalized.ends_with('/') {
            normalized.pop();
        }
        if parsed.path().is_empty() || parsed.path() == "/" {
            normalized.push_str("/v1");
        }
        let base_url = Url::parse(&normalized)
            .map_err(|e| CoreError::InvalidOperation(format!("规范化 TypeSafe 地址失败：{e}")))?;
        let client = reqwest::Client::builder()
            .timeout(Duration::from_secs(45))
            .user_agent(concat!("Charkle-Windows/", env!("CARGO_PKG_VERSION")))
            .build()?;
        Ok(Self {
            client,
            base_url,
            api_key: key,
            usage,
        })
    }

    pub async fn list_models(&self) -> CoreResult<Vec<TypeSafeModelInfo>> {
        #[derive(Deserialize)]
        struct Envelope {
            models: Vec<TypeSafeModelInfo>,
        }
        let url = format!("{}/models", self.base_url);
        let resp = self
            .client
            .get(&url)
            .header("Authorization", format!("Bearer {}", self.api_key))
            .header("Accept", "application/json")
            .send()
            .await?;
        let status = resp.status();
        let text = resp.text().await?;
        if !status.is_success() {
            return Err(CoreError::Http {
                status_code: status.as_u16(),
                message: text.chars().take(200).collect(),
            });
        }
        let env: Envelope = serde_json::from_str(&text)
            .map_err(|e| CoreError::InvalidPayload(format!("解析 TypeSafe 模型列表失败：{e}")))?;
        Ok(env.models)
    }

    pub async fn system_one(
        &self,
        model: &str,
        state: Value,
        questions: HashMap<String, TypeSafeQuestion>,
        images: Vec<TypeSafeImageAttachment>,
    ) -> CoreResult<TypeSafeSystemOneResponse> {
        if questions.is_empty() {
            return Err(CoreError::InvalidOperation(
                "TypeSafe System One 请求至少需要一个问题。".to_string(),
            ));
        }
        let resolved_model = if model.trim().is_empty() {
            "jev-latest"
        } else {
            model.trim()
        };
        let needs_images_header = !images.is_empty()
            || questions
                .values()
                .any(TypeSafeQuestion::uses_danger_zone_images);

        let q_map: serde_json::Map<String, Value> = questions
            .iter()
            .map(|(k, v)| (k.clone(), v.to_json()))
            .collect();
        let mut payload = json!({
            "model": resolved_model,
            "state": state,
            "questions": q_map
        });

        let url = format!("{}/systemone", self.base_url);
        let mut req = self
            .client
            .post(&url)
            .header("Authorization", format!("Bearer {}", self.api_key))
            .header("Accept", "application/json");
        if needs_images_header {
            req = req.header(IMAGES_DANGER_ZONE_HEADER, "true");
        }

        let resp = if images.is_empty() {
            req.json(&payload).send().await
        } else {
            let mut assets_map = serde_json::Map::new();
            for img in &images {
                assets_map.insert(
                    img.reference_key.clone(),
                    json!({ "type": "image", "part": img.part_name }),
                );
            }
            payload["assets"] = Value::Object(assets_map);
            let json_bytes = serde_json::to_vec(&payload)?;
            let mut form = Form::new().part(
                "request",
                Part::bytes(json_bytes).mime_str("application/json")?,
            );
            for img in images {
                let filename = format!("{}.{}", img.part_name, img.format);
                let mime = img.mime_type();
                let part = Part::bytes(img.data).file_name(filename).mime_str(mime)?;
                form = form.part(img.part_name, part);
            }
            req.multipart(form).send().await
        }?;

        let status = resp.status();
        let text = resp.text().await?;
        if !status.is_success() {
            return Err(CoreError::Http {
                status_code: status.as_u16(),
                message: text.chars().take(240).collect(),
            });
        }
        let decoded: TypeSafeSystemOneResponse = serde_json::from_str(&text)
            .map_err(|e| CoreError::InvalidPayload(format!("解析 TypeSafe 响应失败：{e}")))?;
        let used_model = if decoded.model.is_empty() {
            resolved_model
        } else {
            decoded.model.as_str()
        };
        self.usage.record(
            CloudAIUsageCategory::Jev,
            "TypeSafe (Jev)",
            used_model,
            decoded.usage.as_ref().map_or(0, |u| u.input_tokens),
            decoded.usage.as_ref().map_or(0, |u| u.output_tokens),
            None,
        );
        Ok(decoded)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    use tokio::net::TcpListener;

    #[tokio::test]
    async fn typesafe_client_lists_models_and_parses_noul_box_answers() {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        tokio::spawn(async move {
            for _ in 0..2 {
                let Ok((mut stream, _)) = listener.accept().await else {
                    break;
                };
                let mut buf = vec![0u8; 16384];
                let n = stream.read(&mut buf).await.unwrap_or(0);
                let req_str = String::from_utf8_lossy(&buf[..n]);
                let body = if req_str.starts_with("GET ") {
                    r#"{"models":[{"name":"jev-latest","description":"System One Visual","release_date":"2026-09"}]}"#
                } else {
                    r#"{"model":"jev-latest","answers":{"present":{"type":"noul","noul":0.94},"region":{"type":"box","box":{"top":0.15,"bottom":0.82,"left":0.20,"right":0.78},"confidence":0.89}},"usage":{"input_tokens":180,"output_tokens":32}}"#
                };
                let http = format!(
                    "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
                    body.len(),
                    body
                );
                let _ = stream.write_all(http.as_bytes()).await;
                let _ = stream.shutdown().await;
            }
        });

        let usage = Arc::new(CloudAIUsageStore::in_memory());
        let client = TypeSafeSystemOneClient::new(
            &format!("http://127.0.0.1:{}", addr.port()),
            "ts-test-key",
            Arc::clone(&usage),
        )
        .unwrap();

        let models = client.list_models().await.unwrap();
        assert_eq!(models.len(), 1);
        assert_eq!(models[0].name, "jev-latest");

        let mut questions = HashMap::new();
        questions.insert(
            "present".to_string(),
            TypeSafeQuestion::Noul {
                instructions: "Is hero object visible?".to_string(),
                true_criteria: None,
                false_criteria: None,
            },
        );
        questions.insert(
            "region".to_string(),
            TypeSafeQuestion::Box {
                instructions: "hero object".to_string(),
            },
        );
        let resp = client
            .system_one("jev-latest", json!({"photo": "img-1"}), questions, vec![])
            .await
            .unwrap();
        assert_eq!(resp.model, "jev-latest");
        assert!(matches!(
            resp.answers.get("present"),
            Some(TypeSafeAnswer::Noul { noul }) if *noul > 0.9
        ));
        assert!(matches!(
            resp.answers.get("region"),
            Some(TypeSafeAnswer::Box { .. })
        ));
        assert_eq!(usage.snapshot().jev.today_requests, 1);
        assert_eq!(usage.snapshot().jev.total_tokens, 212);
    }
}
