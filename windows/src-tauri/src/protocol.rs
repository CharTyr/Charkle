//! Zero-copy `charkle-media://` URI scheme protocol with full RFC 7233 HTTP Range streaming
//! (`206 Partial Content`, `Accept-Ranges: bytes`, `Content-Range`, `ETag`, `Cache-Control`).
//!
//! Routes:
//! - `charkle-media://localhost/thumb/{id}/{tier}` (`grid520` | `preview1400`)
//! - `charkle-media://localhost/original/{id}` (supports `?cachedOnly=1` so hover previews
//!   strictly read local cache and never trigger cloud downloads)
//! - `charkle-media://localhost/capture-frame/{token}` (frozen 1:1 physical-pixel screenshot
//!   frame served directly from RAM without IPC base64 overhead)

use std::fs::File;
use std::io::{Read, Seek, SeekFrom};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::UNIX_EPOCH;

use charkle_core::engine::LiveCharkleEngine;
use charkle_core::media::MediaPipeline;
use charkle_core::models::media::ThumbnailTier;
use tauri::http::{header, Request, Response, StatusCode};
use uuid::Uuid;

use crate::desktop::CaptureFrameStore;

/// Maximum single Range response chunk size (4 MiB) so 4K video/GIF scrubbing never spikes RAM.
const MAX_RANGE_CHUNK_BYTES: u64 = 4 * 1024 * 1024;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ByteRangeResult {
    Full,
    Partial { start: u64, end: u64 },
    Unsatisfiable,
}

/// Parses an RFC 7233 single-range `Range: bytes=...` header against `total_len`.
pub fn parse_byte_range(header_value: &str, total_len: u64) -> ByteRangeResult {
    if total_len == 0 {
        return ByteRangeResult::Unsatisfiable;
    }
    let trimmed = header_value.trim();
    let Some(spec) = trimmed
        .strip_prefix("bytes=")
        .or_else(|| trimmed.strip_prefix("BYTES="))
    else {
        return ByteRangeResult::Full;
    };
    // Take first range if multi-range requested
    let first = spec.split(',').next().unwrap_or("").trim();
    let Some((start_str, end_str)) = first.split_once('-') else {
        return ByteRangeResult::Unsatisfiable;
    };

    if start_str.is_empty() {
        // Suffix byte range: `bytes=-500`
        let Ok(suffix) = end_str.trim().parse::<u64>() else {
            return ByteRangeResult::Unsatisfiable;
        };
        if suffix == 0 {
            return ByteRangeResult::Unsatisfiable;
        }
        let start = total_len.saturating_sub(suffix);
        return ByteRangeResult::Partial {
            start,
            end: total_len - 1,
        };
    }

    let Ok(start) = start_str.trim().parse::<u64>() else {
        return ByteRangeResult::Unsatisfiable;
    };
    if start >= total_len {
        return ByteRangeResult::Unsatisfiable;
    }

    let end = if end_str.trim().is_empty() {
        // Open-ended range: cap single chunk to MAX_RANGE_CHUNK_BYTES for smooth scrubbing
        (start.saturating_add(MAX_RANGE_CHUNK_BYTES - 1)).min(total_len - 1)
    } else {
        let Ok(parsed_end) = end_str.trim().parse::<u64>() else {
            return ByteRangeResult::Unsatisfiable;
        };
        if parsed_end < start {
            return ByteRangeResult::Unsatisfiable;
        }
        parsed_end.min(total_len - 1)
    };

    ByteRangeResult::Partial { start, end }
}

/// Handles a `charkle-media://` request synchronously from disk or ephemeral capture frame
/// store without copying whole large files when a `Range` header is supplied.
pub fn handle_media_request(
    engine: &Arc<LiveCharkleEngine>,
    capture_frames: Option<&Arc<CaptureFrameStore>>,
    request: &Request<Vec<u8>>,
) -> Response<Vec<u8>> {
    if request.method() == "OPTIONS" {
        return Response::builder()
            .status(StatusCode::NO_CONTENT)
            .header(header::ACCESS_CONTROL_ALLOW_ORIGIN, "*")
            .header(header::ACCESS_CONTROL_ALLOW_METHODS, "GET, HEAD, OPTIONS")
            .header(header::ACCESS_CONTROL_ALLOW_HEADERS, "Range, If-None-Match")
            .body(Vec::new())
            .unwrap_or_else(|_| Response::new(Vec::new()));
    }

    let path = request.uri().path();
    let query = request.uri().query().unwrap_or("");
    let segments: Vec<&str> = path.split('/').filter(|s| !s.is_empty()).collect();

    if let ["capture-frame", token] = segments.as_slice() {
        let Some(store) = capture_frames else {
            return error_response(StatusCode::NOT_FOUND, "Capture store unavailable");
        };
        let Some(frame) = store.get_frame(token) else {
            return error_response(StatusCode::NOT_FOUND, "Capture frame expired");
        };
        let body = if request.method() == "HEAD" {
            Vec::new()
        } else {
            frame.png_bytes.clone()
        };
        return Response::builder()
            .status(StatusCode::OK)
            .header(header::CONTENT_TYPE, "image/png")
            .header(header::CONTENT_LENGTH, frame.png_bytes.len().to_string())
            .header(header::CACHE_CONTROL, "no-store")
            .header(header::ACCESS_CONTROL_ALLOW_ORIGIN, "*")
            .body(body)
            .unwrap_or_else(|_| Response::new(Vec::new()));
    }

    let resolved: Option<(PathBuf, String, &'static str)> = match segments.as_slice() {
        ["thumb", id_str, tier_str] => {
            let Ok(id) = Uuid::parse_str(id_str) else {
                return error_response(StatusCode::BAD_REQUEST, "Invalid asset UUID");
            };
            let tier = match *tier_str {
                "preview1400" => ThumbnailTier::Preview1400,
                _ => ThumbnailTier::Grid520,
            };
            engine
                .cached_thumbnail_path(id, tier)
                .map(|p| (p, "image/jpeg".to_string(), "public, max-age=3600"))
        }
        ["original", id_str] => {
            let Ok(id) = Uuid::parse_str(id_str) else {
                return error_response(StatusCode::BAD_REQUEST, "Invalid asset UUID");
            };
            let _cached_only = query.split('&').any(|pair| pair == "cachedOnly=1");
            let Ok(Some(asset)) = engine.fetch_asset(id) else {
                return error_response(StatusCode::NOT_FOUND, "Asset not found");
            };
            engine.cached_original_path(&asset).map(|p| {
                let mime = if !asset.mime_type.is_empty()
                    && asset.mime_type != "application/octet-stream"
                {
                    asset.mime_type.clone()
                } else {
                    MediaPipeline::mime_type(&asset.file_name).to_string()
                };
                (p, mime, "public, max-age=300")
            })
        }
        _ => return error_response(StatusCode::NOT_FOUND, "Unknown media route"),
    };

    let Some((file_path, mime_type, cache_control)) = resolved else {
        return error_response(StatusCode::NOT_FOUND, "Media file not cached locally");
    };

    serve_file_with_range(request, &file_path, &mime_type, cache_control)
}

fn serve_file_with_range(
    request: &Request<Vec<u8>>,
    file_path: &Path,
    mime_type: &str,
    cache_control: &str,
) -> Response<Vec<u8>> {
    let Ok(meta) = std::fs::metadata(file_path) else {
        return error_response(StatusCode::NOT_FOUND, "File missing on disk");
    };
    let total_len = meta.len();
    let mtime_secs = meta
        .modified()
        .ok()
        .and_then(|t| t.duration_since(UNIX_EPOCH).ok())
        .map(|d| d.as_secs())
        .unwrap_or(0);
    let etag = format!("\"{total_len:x}-{mtime_secs:x}\"");

    if let Some(if_none_match) = request
        .headers()
        .get(header::IF_NONE_MATCH)
        .and_then(|v| v.to_str().ok())
    {
        if if_none_match.trim() == etag {
            return Response::builder()
                .status(StatusCode::NOT_MODIFIED)
                .header(header::ETAG, &etag)
                .header(header::CACHE_CONTROL, cache_control)
                .header(header::ACCESS_CONTROL_ALLOW_ORIGIN, "*")
                .body(Vec::new())
                .unwrap_or_else(|_| Response::new(Vec::new()));
        }
    }

    let range_header = request
        .headers()
        .get(header::RANGE)
        .and_then(|v| v.to_str().ok());

    let range = match range_header {
        Some(h) => parse_byte_range(h, total_len),
        None => ByteRangeResult::Full,
    };

    match range {
        ByteRangeResult::Unsatisfiable => Response::builder()
            .status(StatusCode::RANGE_NOT_SATISFIABLE)
            .header(header::CONTENT_RANGE, format!("bytes */{total_len}"))
            .header(header::ACCEPT_RANGES, "bytes")
            .header(header::ACCESS_CONTROL_ALLOW_ORIGIN, "*")
            .body(Vec::new())
            .unwrap_or_else(|_| Response::new(Vec::new())),
        ByteRangeResult::Partial { start, end } => {
            let chunk_len = end - start + 1;
            let mut body = Vec::new();
            if request.method() != "HEAD" {
                let Ok(mut file) = File::open(file_path) else {
                    return error_response(
                        StatusCode::INTERNAL_SERVER_ERROR,
                        "Failed to open file",
                    );
                };
                if file.seek(SeekFrom::Start(start)).is_err() {
                    return error_response(StatusCode::INTERNAL_SERVER_ERROR, "Seek failed");
                }
                body.reserve(chunk_len as usize);
                if file.take(chunk_len).read_to_end(&mut body).is_err() {
                    return error_response(StatusCode::INTERNAL_SERVER_ERROR, "Read failed");
                }
            }
            Response::builder()
                .status(StatusCode::PARTIAL_CONTENT)
                .header(header::CONTENT_TYPE, mime_type)
                .header(header::CONTENT_LENGTH, chunk_len.to_string())
                .header(
                    header::CONTENT_RANGE,
                    format!("bytes {start}-{end}/{total_len}"),
                )
                .header(header::ACCEPT_RANGES, "bytes")
                .header(header::ETAG, &etag)
                .header(header::CACHE_CONTROL, cache_control)
                .header(header::ACCESS_CONTROL_ALLOW_ORIGIN, "*")
                .body(body)
                .unwrap_or_else(|_| Response::new(Vec::new()))
        }
        ByteRangeResult::Full => {
            let body = if request.method() == "HEAD" {
                Vec::new()
            } else {
                match std::fs::read(file_path) {
                    Ok(bytes) => bytes,
                    Err(_) => {
                        return error_response(
                            StatusCode::INTERNAL_SERVER_ERROR,
                            "Failed to read media file",
                        );
                    }
                }
            };
            Response::builder()
                .status(StatusCode::OK)
                .header(header::CONTENT_TYPE, mime_type)
                .header(header::CONTENT_LENGTH, total_len.to_string())
                .header(header::ACCEPT_RANGES, "bytes")
                .header(header::ETAG, &etag)
                .header(header::CACHE_CONTROL, cache_control)
                .header(header::ACCESS_CONTROL_ALLOW_ORIGIN, "*")
                .body(body)
                .unwrap_or_else(|_| Response::new(Vec::new()))
        }
    }
}

fn error_response(status: StatusCode, msg: &str) -> Response<Vec<u8>> {
    Response::builder()
        .status(status)
        .header(header::CONTENT_TYPE, "text/plain; charset=utf-8")
        .header(header::ACCESS_CONTROL_ALLOW_ORIGIN, "*")
        .body(msg.as_bytes().to_vec())
        .unwrap_or_else(|_| Response::new(Vec::new()))
}

#[cfg(test)]
mod tests {
    use super::*;
    use charkle_core::models::media::CaptureInput;
    use tempfile::tempdir;

    #[test]
    fn byte_range_parser_handles_partial_open_suffix_and_invalid() {
        assert_eq!(
            parse_byte_range("bytes=0-99", 1000),
            ByteRangeResult::Partial { start: 0, end: 99 }
        );
        assert_eq!(
            parse_byte_range("bytes=500-", 1000),
            ByteRangeResult::Partial {
                start: 500,
                end: 999
            }
        );
        assert_eq!(
            parse_byte_range("bytes=-100", 1000),
            ByteRangeResult::Partial {
                start: 900,
                end: 999
            }
        );
        assert_eq!(
            parse_byte_range("bytes=1000-1200", 1000),
            ByteRangeResult::Unsatisfiable
        );
        assert_eq!(
            parse_byte_range("bytes=500-200", 1000),
            ByteRangeResult::Unsatisfiable
        );
    }

    #[tokio::test]
    async fn media_protocol_serves_thumbnails_and_206_range_originals() {
        let tmp = tempdir().unwrap();
        let engine = Arc::new(LiveCharkleEngine::open(tmp.path()).unwrap());
        let assets = engine
            .ingest(
                vec![CaptureInput::TextSnippet {
                    title: "RangeTest".to_string(),
                    text: "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ".to_string(),
                    source_url: None,
                }],
                None,
                None,
            )
            .await
            .unwrap();
        let id = assets[0].id;

        // 1. Thumbnail request
        let thumb_req = Request::builder()
            .uri(format!("http://charkle-media.localhost/thumb/{id}/grid520"))
            .body(Vec::new())
            .unwrap();
        let thumb_res = handle_media_request(&engine, None, &thumb_req);
        assert_eq!(thumb_res.status(), StatusCode::OK);
        assert_eq!(
            thumb_res.headers().get(header::CONTENT_TYPE).unwrap(),
            "image/jpeg"
        );
        assert!(!thumb_res.body().is_empty());

        // 2. Partial Content Range request on original
        let range_req = Request::builder()
            .uri(format!(
                "http://charkle-media.localhost/original/{id}?cachedOnly=1"
            ))
            .header(header::RANGE, "bytes=10-19")
            .body(Vec::new())
            .unwrap();
        let range_res = handle_media_request(&engine, None, &range_req);
        assert_eq!(range_res.status(), StatusCode::PARTIAL_CONTENT);
        assert_eq!(range_res.body(), b"ABCDEFGHIJ");
        assert_eq!(
            range_res.headers().get(header::CONTENT_RANGE).unwrap(),
            "bytes 10-19/36"
        );
        assert_eq!(
            range_res.headers().get(header::ACCEPT_RANGES).unwrap(),
            "bytes"
        );

        // 3. Frozen capture-frame zero-copy serving
        let store = Arc::new(CaptureFrameStore::default());
        let info = store.insert(
            charkle_platform_win::capture::CapturedDesktopFrame {
                bounds: charkle_platform_win::capture::VirtualDesktopBounds {
                    left: 0,
                    top: 0,
                    width: 2,
                    height: 2,
                },
                monitors: Vec::new(),
                width: 2,
                height: 2,
                rgba: vec![255u8; 16],
                png_bytes: b"\x89PNG\r\n\x1a\nMOCK".to_vec(),
            },
            None,
            None,
        );
        let cap_req = Request::builder()
            .uri(format!(
                "http://charkle-media.localhost/capture-frame/{}",
                info.token
            ))
            .body(Vec::new())
            .unwrap();
        let cap_res = handle_media_request(&engine, Some(&store), &cap_req);
        assert_eq!(cap_res.status(), StatusCode::OK);
        assert_eq!(
            cap_res.headers().get(header::CONTENT_TYPE).unwrap(),
            "image/png"
        );
        assert!(cap_res.body().starts_with(b"\x89PNG"));
    }
}
