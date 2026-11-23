//! Offline WinRT `Windows.Media.Ocr.OcrEngine` provider (`NativeOcrProvider`).
//!
//! Probes Simplified Chinese (`zh-Hans`), Traditional Chinese (`zh-Hant`), English (`en-US`),
//! and user profile OCR languages without requiring cloud APIs. Returns graceful diagnostics
//! when optional Windows OCR language packs are not installed.

use async_trait::async_trait;
use charkle_core::traits::NativeOcrProvider;
use serde::{Deserialize, Serialize};

#[cfg(target_os = "windows")]
use windows::core::HSTRING;
#[cfg(target_os = "windows")]
use windows::Globalization::Language;
#[cfg(target_os = "windows")]
use windows::Graphics::Imaging::BitmapDecoder;
#[cfg(target_os = "windows")]
use windows::Media::Ocr::OcrEngine;
#[cfg(target_os = "windows")]
use windows::Storage::Streams::{DataWriter, InMemoryRandomAccessStream};

const PREFERRED_OCR_TAGS: &[&str] = &["zh-Hans-CN", "zh-Hans", "zh-Hant-TW", "zh-Hant", "en-US"];

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct OcrDiagnostics {
    pub available_languages: Vec<String>,
    pub selected_language: Option<String>,
    pub has_chinese: bool,
    pub has_english: bool,
    pub diagnostic_message: Option<String>,
}

/// Probes installed WinRT OCR recognizer languages and produces user-friendly diagnostics.
pub fn probe_ocr_diagnostics() -> OcrDiagnostics {
    #[cfg(target_os = "windows")]
    {
        let mut available = Vec::new();
        if let Ok(langs) = OcrEngine::AvailableRecognizerLanguages() {
            if let Ok(len) = langs.Size() {
                for idx in 0..len {
                    if let Ok(lang) = langs.GetAt(idx) {
                        if let Ok(tag) = lang.LanguageTag() {
                            available.push(tag.to_string());
                        }
                    }
                }
            }
        }

        let has_chinese = available
            .iter()
            .any(|t| t.to_ascii_lowercase().starts_with("zh"));
        let has_english = available
            .iter()
            .any(|t| t.to_ascii_lowercase().starts_with("en"));

        let selected_language = select_ocr_language_tag(&available);
        let diagnostic_message = if available.is_empty() {
            Some(
                "未检测到 Windows 离线文字识别语言包，请在系统「设置 -> 时间和语言 -> 语言」中安装中文或英文语言功能。"
                    .to_string(),
            )
        } else if !has_chinese {
            Some(
                "当前系统仅安装英文离线识别包；如需识别中文画面文字，可在 Windows 语言设置中补充「中文(简体)」光学字符识别组件。"
                    .to_string(),
            )
        } else {
            None
        };

        OcrDiagnostics {
            available_languages: available,
            selected_language,
            has_chinese,
            has_english,
            diagnostic_message,
        }
    }

    #[cfg(not(target_os = "windows"))]
    {
        OcrDiagnostics {
            available_languages: Vec::new(),
            selected_language: None,
            has_chinese: false,
            has_english: false,
            diagnostic_message: Some("Offline WinRT OCR is only available on Windows.".to_string()),
        }
    }
}

fn select_ocr_language_tag(available: &[String]) -> Option<String> {
    for preferred in PREFERRED_OCR_TAGS {
        if let Some(found) = available
            .iter()
            .find(|tag| tag.eq_ignore_ascii_case(preferred))
        {
            return Some(found.clone());
        }
    }
    if let Some(zh) = available
        .iter()
        .find(|tag| tag.to_ascii_lowercase().starts_with("zh"))
    {
        return Some(zh.clone());
    }
    if let Some(en) = available
        .iter()
        .find(|tag| tag.to_ascii_lowercase().starts_with("en"))
    {
        return Some(en.clone());
    }
    available.first().cloned()
}

/// Offline WinRT OCR provider implementing `charkle_core::traits::NativeOcrProvider`.
#[derive(Debug, Default, Clone, Copy)]
pub struct WinRtOcrProvider;

impl WinRtOcrProvider {
    pub fn new() -> Self {
        Self
    }
}

#[async_trait]
impl NativeOcrProvider for WinRtOcrProvider {
    async fn recognize_text(&self, image_bytes: &[u8]) -> Result<Option<String>, String> {
        if image_bytes.is_empty() {
            return Ok(None);
        }

        #[cfg(target_os = "windows")]
        {
            let owned = image_bytes.to_vec();
            tokio::task::spawn_blocking(move || recognize_text_blocking(&owned))
                .await
                .map_err(|e| format!("WinRT OCR worker panicked: {e}"))?
        }

        #[cfg(not(target_os = "windows"))]
        {
            Ok(None)
        }
    }
}

#[cfg(target_os = "windows")]
fn create_best_ocr_engine() -> Option<OcrEngine> {
    let diag = probe_ocr_diagnostics();
    if let Some(tag) = diag.selected_language {
        if let Ok(lang) = Language::CreateLanguage(&HSTRING::from(tag.as_str())) {
            if OcrEngine::IsLanguageSupported(&lang).unwrap_or(false) {
                if let Ok(engine) = OcrEngine::TryCreateFromLanguage(&lang) {
                    return Some(engine);
                }
            }
        }
    }
    OcrEngine::TryCreateFromUserProfileLanguages().ok()
}

#[cfg(target_os = "windows")]
fn recognize_text_blocking(image_bytes: &[u8]) -> Result<Option<String>, String> {
    let Some(engine) = create_best_ocr_engine() else {
        tracing::debug!("WinRT OcrEngine unavailable (no OCR language packs installed)");
        return Ok(None);
    };

    let stream = InMemoryRandomAccessStream::new()
        .map_err(|e| format!("Failed to create WinRT stream: {e}"))?;
    let writer = DataWriter::CreateDataWriter(&stream)
        .map_err(|e| format!("Failed to create WinRT DataWriter: {e}"))?;
    writer
        .WriteBytes(image_bytes)
        .map_err(|e| format!("DataWriter::WriteBytes failed: {e}"))?;
    writer
        .StoreAsync()
        .map_err(|e| format!("DataWriter::StoreAsync failed: {e}"))?
        .get()
        .map_err(|e| format!("DataWriter::StoreAsync wait failed: {e}"))?;
    writer
        .FlushAsync()
        .map_err(|e| format!("DataWriter::FlushAsync failed: {e}"))?
        .get()
        .map_err(|e| format!("DataWriter::FlushAsync wait failed: {e}"))?;
    let _ = writer.DetachStream();
    stream
        .Seek(0)
        .map_err(|e| format!("Stream seek failed: {e}"))?;

    let decoder = BitmapDecoder::CreateAsync(&stream)
        .map_err(|e| format!("BitmapDecoder::CreateAsync failed: {e}"))?
        .get()
        .map_err(|e| format!("BitmapDecoder decode failed: {e}"))?;
    let bitmap = decoder
        .GetSoftwareBitmapAsync()
        .map_err(|e| format!("GetSoftwareBitmapAsync failed: {e}"))?
        .get()
        .map_err(|e| format!("GetSoftwareBitmapAsync wait failed: {e}"))?;

    let result = engine
        .RecognizeAsync(&bitmap)
        .map_err(|e| format!("OcrEngine::RecognizeAsync failed: {e}"))?
        .get()
        .map_err(|e| format!("OcrEngine::RecognizeAsync wait failed: {e}"))?;

    let lines = result
        .Lines()
        .map_err(|e| format!("OcrResult::Lines failed: {e}"))?;
    let count = lines.Size().unwrap_or(0);
    let mut collected = Vec::with_capacity(count as usize);
    for idx in 0..count {
        if let Ok(line) = lines.GetAt(idx) {
            if let Ok(text) = line.Text() {
                let s = text.to_string();
                let trimmed = s.trim();
                if !trimmed.is_empty() {
                    collected.push(trimmed.to_string());
                }
            }
        }
    }

    if collected.is_empty() {
        Ok(None)
    } else {
        Ok(Some(collected.join("\n")))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use image::{DynamicImage, ImageFormat, Rgba, RgbaImage};
    use std::io::Cursor;

    #[test]
    fn ocr_language_selector_prefers_chinese_then_english() {
        let avail = vec![
            "fr-FR".to_string(),
            "en-US".to_string(),
            "zh-Hans-CN".to_string(),
        ];
        assert_eq!(
            select_ocr_language_tag(&avail).as_deref(),
            Some("zh-Hans-CN")
        );

        let en_only = vec!["de-DE".to_string(), "en-US".to_string()];
        assert_eq!(select_ocr_language_tag(&en_only).as_deref(), Some("en-US"));
    }

    #[tokio::test]
    async fn winrt_ocr_provider_probes_and_handles_valid_png_without_panic() {
        let diag = probe_ocr_diagnostics();
        // Verify diagnostics struct is populated cleanly regardless of installed OS packs
        if diag.available_languages.is_empty() {
            assert!(diag.diagnostic_message.is_some());
        } else {
            assert!(diag.selected_language.is_some());
        }

        let img = RgbaImage::from_pixel(120, 48, Rgba([255, 255, 255, 255]));
        let mut png = Vec::new();
        DynamicImage::ImageRgba8(img)
            .write_to(&mut Cursor::new(&mut png), ImageFormat::Png)
            .expect("encode png");

        let provider = WinRtOcrProvider::new();
        let res = provider.recognize_text(&png).await.expect("ocr run");
        assert!(res.is_none());
    }
}
