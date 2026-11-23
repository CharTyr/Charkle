//! Exact Swift `/.charkle/` wire-format codec.
//!
//! Matches `Sources/CharkleCore/Sync/SyncOperations.swift`, `DriveSyncEngine.swift`,
//! and `web/packages/shared/src/sync/swift-codec.ts`:
//! - Dates encoded as Cocoa reference seconds since `2001-01-01T00:00:00Z` (`978_307_200.0`)
//! - UUIDs encoded as uppercase hyphenated RFC-4122 strings
//! - Binary `Data` encoded as standard Base64
//! - Canonical JSON objects serialized with lexicographically sorted keys and unescaped `/`
//! - `SyncFields` encoded as `{ "<field>": "<base64-of-sorted-json-fragment>" }`

use std::collections::{BTreeMap, HashSet};

use base64::engine::general_purpose::STANDARD as BASE64_STD;
use base64::Engine;
use chrono::{DateTime, TimeZone, Utc};
use serde::de::DeserializeOwned;
use serde::{Deserialize, Deserializer, Serialize, Serializer};
use serde_json::{Map, Value};
use uuid::Uuid;

use crate::error::{CoreError, CoreResult};
use crate::models::sync::{SyncClocks, SyncLogLine, SyncManifest, SyncStamp};

/// Seconds between Unix epoch (`1970-01-01T00:00:00Z`) and Apple Cocoa Reference Date (`2001-01-01T00:00:00Z`).
pub const COCOA_EPOCH_OFFSET_SEC: f64 = 978_307_200.0;

/// Converts a UTC `DateTime` to Apple Cocoa reference seconds.
pub fn datetime_to_cocoa_seconds(dt: DateTime<Utc>) -> f64 {
    let millis = dt.timestamp_millis() as f64;
    (millis / 1000.0) - COCOA_EPOCH_OFFSET_SEC
}

/// Converts Apple Cocoa reference seconds to a UTC `DateTime` (millisecond precision).
pub fn cocoa_seconds_to_datetime(seconds: f64) -> CoreResult<DateTime<Utc>> {
    if !seconds.is_finite() {
        return Err(CoreError::InvalidPayload(format!(
            "Non-finite Cocoa timestamp: {seconds}"
        )));
    }
    let unix_ms = ((seconds + COCOA_EPOCH_OFFSET_SEC) * 1000.0).round() as i64;
    Utc.timestamp_millis_opt(unix_ms).single().ok_or_else(|| {
        CoreError::InvalidPayload(format!("Out-of-range Cocoa timestamp: {seconds}"))
    })
}

/// Decodes a flexible wire date value accepting both Cocoa float/int seconds and RFC-3339 strings.
pub fn decode_flexible_date(value: &Value) -> CoreResult<DateTime<Utc>> {
    match value {
        Value::Number(num) => {
            let secs = num.as_f64().ok_or_else(|| {
                CoreError::InvalidPayload(format!("Invalid numeric timestamp: {num}"))
            })?;
            cocoa_seconds_to_datetime(secs)
        }
        Value::String(s) => DateTime::parse_from_rfc3339(s)
            .map(|dt| dt.with_timezone(&Utc))
            .map_err(|e| {
                CoreError::InvalidPayload(format!("Invalid ISO-8601 timestamp `{s}`: {e}"))
            }),
        other => Err(CoreError::InvalidPayload(format!(
            "Expected Cocoa timestamp or RFC-3339 date string, got {other}"
        ))),
    }
}

/// Format a `Uuid` in Swift's canonical uppercase hyphenated form.
pub fn format_swift_uuid(id: &Uuid) -> String {
    id.hyphenated()
        .encode_upper(&mut Uuid::encode_buffer())
        .to_string()
}

/// Serde module for `DateTime<Utc>` using Swift Cocoa reference seconds.
pub mod cocoa_date {
    use super::*;

    pub fn serialize<S>(dt: &DateTime<Utc>, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: Serializer,
    {
        serializer.serialize_f64(datetime_to_cocoa_seconds(*dt))
    }

    pub fn deserialize<'de, D>(deserializer: D) -> Result<DateTime<Utc>, D::Error>
    where
        D: Deserializer<'de>,
    {
        let raw = Value::deserialize(deserializer)?;
        decode_flexible_date(&raw).map_err(serde::de::Error::custom)
    }
}

/// Serde module for `Option<DateTime<Utc>>` using Swift Cocoa reference seconds.
pub mod cocoa_date_opt {
    use super::*;

    pub fn serialize<S>(dt: &Option<DateTime<Utc>>, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: Serializer,
    {
        match dt {
            Some(v) => serializer.serialize_f64(datetime_to_cocoa_seconds(*v)),
            None => serializer.serialize_none(),
        }
    }

    pub fn deserialize<'de, D>(deserializer: D) -> Result<Option<DateTime<Utc>>, D::Error>
    where
        D: Deserializer<'de>,
    {
        let raw = Option::<Value>::deserialize(deserializer)?;
        match raw {
            None | Some(Value::Null) => Ok(None),
            Some(val) => decode_flexible_date(&val)
                .map(Some)
                .map_err(serde::de::Error::custom),
        }
    }
}

/// Serde module for `Uuid` serialized as uppercase hyphenated RFC-4122.
pub mod upper_uuid {
    use super::*;

    pub fn serialize<S>(id: &Uuid, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: Serializer,
    {
        serializer.serialize_str(&format_swift_uuid(id))
    }

    pub fn deserialize<'de, D>(deserializer: D) -> Result<Uuid, D::Error>
    where
        D: Deserializer<'de>,
    {
        let s = String::deserialize(deserializer)?;
        Uuid::parse_str(s.trim()).map_err(serde::de::Error::custom)
    }
}

/// Serde module for `Option<Uuid>` serialized as uppercase hyphenated RFC-4122.
pub mod upper_uuid_opt {
    use super::*;

    pub fn serialize<S>(id: &Option<Uuid>, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: Serializer,
    {
        match id {
            Some(v) => serializer.serialize_str(&format_swift_uuid(v)),
            None => serializer.serialize_none(),
        }
    }

    pub fn deserialize<'de, D>(deserializer: D) -> Result<Option<Uuid>, D::Error>
    where
        D: Deserializer<'de>,
    {
        let opt = Option::<String>::deserialize(deserializer)?;
        match opt {
            None => Ok(None),
            Some(s) if s.trim().is_empty() => Ok(None),
            Some(s) => Uuid::parse_str(s.trim())
                .map(Some)
                .map_err(serde::de::Error::custom),
        }
    }
}

/// Serde module for `Vec<Uuid>` serialized as uppercase hyphenated RFC-4122 strings.
pub mod upper_uuid_vec {
    use super::*;

    pub fn serialize<S>(ids: &[Uuid], serializer: S) -> Result<S::Ok, S::Error>
    where
        S: Serializer,
    {
        let strs: Vec<String> = ids.iter().map(format_swift_uuid).collect();
        strs.serialize(serializer)
    }

    pub fn deserialize<'de, D>(deserializer: D) -> Result<Vec<Uuid>, D::Error>
    where
        D: Deserializer<'de>,
    {
        let strs = Vec::<String>::deserialize(deserializer)?;
        strs.into_iter()
            .map(|s| Uuid::parse_str(s.trim()).map_err(serde::de::Error::custom))
            .collect()
    }
}

/// Serde module for `Vec<u8>` serialized as standard Base64.
pub mod base64_data {
    use super::*;

    pub fn serialize<S>(bytes: &[u8], serializer: S) -> Result<S::Ok, S::Error>
    where
        S: Serializer,
    {
        serializer.serialize_str(&BASE64_STD.encode(bytes))
    }

    pub fn deserialize<'de, D>(deserializer: D) -> Result<Vec<u8>, D::Error>
    where
        D: Deserializer<'de>,
    {
        let s = String::deserialize(deserializer)?;
        let cleaned: String = s.chars().filter(|c| !c.is_whitespace()).collect();
        BASE64_STD.decode(cleaned).map_err(serde::de::Error::custom)
    }
}

/// Serde module for `Option<Vec<u8>>` serialized as standard Base64.
pub mod base64_data_opt {
    use super::*;

    pub fn serialize<S>(bytes: &Option<Vec<u8>>, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: Serializer,
    {
        match bytes {
            Some(b) => serializer.serialize_str(&BASE64_STD.encode(b)),
            None => serializer.serialize_none(),
        }
    }

    pub fn deserialize<'de, D>(deserializer: D) -> Result<Option<Vec<u8>>, D::Error>
    where
        D: Deserializer<'de>,
    {
        let opt = Option::<String>::deserialize(deserializer)?;
        match opt {
            None => Ok(None),
            Some(s) => {
                let cleaned: String = s.chars().filter(|c| !c.is_whitespace()).collect();
                BASE64_STD
                    .decode(cleaned)
                    .map(Some)
                    .map_err(serde::de::Error::custom)
            }
        }
    }
}

/// Serde module for `BTreeMap<String, Vec<u8>>` matching Swift `[String: Data]` (Base64 values).
pub mod base64_field_map {
    use super::*;

    pub fn serialize<S>(map: &BTreeMap<String, Vec<u8>>, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: Serializer,
    {
        let encoded: BTreeMap<&String, String> =
            map.iter().map(|(k, v)| (k, BASE64_STD.encode(v))).collect();
        encoded.serialize(serializer)
    }

    pub fn deserialize<'de, D>(deserializer: D) -> Result<BTreeMap<String, Vec<u8>>, D::Error>
    where
        D: Deserializer<'de>,
    {
        let raw = BTreeMap::<String, String>::deserialize(deserializer)?;
        let mut out = BTreeMap::new();
        for (k, v) in raw {
            let cleaned: String = v.chars().filter(|c| !c.is_whitespace()).collect();
            let decoded = BASE64_STD
                .decode(cleaned)
                .map_err(serde::de::Error::custom)?;
            out.insert(k, decoded);
        }
        Ok(out)
    }
}

/// Recursively sorts all object keys lexicographically to match Swift
/// `JSONEncoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]`.
pub fn canonicalize_value(value: Value) -> Value {
    match value {
        Value::Array(items) => Value::Array(items.into_iter().map(canonicalize_value).collect()),
        Value::Object(map) => {
            let sorted: BTreeMap<String, Value> = map
                .into_iter()
                .map(|(k, v)| (k, canonicalize_value(v)))
                .collect();
            let mut out = Map::with_capacity(sorted.len());
            for (k, v) in sorted {
                out.insert(k, v);
            }
            Value::Object(out)
        }
        other => other,
    }
}

/// Serializes any `Serialize` value into a deterministic sorted-key JSON string without escaping `/`.
pub fn canonical_json_string<T: Serialize>(value: &T) -> CoreResult<String> {
    let val = serde_json::to_value(value)?;
    let sorted = canonicalize_value(val);
    Ok(serde_json::to_string(&sorted)?)
}

/// Serializes any `Serialize` value into deterministic sorted-key UTF-8 JSON bytes.
pub fn canonical_json_bytes<T: Serialize>(value: &T) -> CoreResult<Vec<u8>> {
    Ok(canonical_json_string(value)?.into_bytes())
}

/// Field-level delta diff and LWW merge matching `Sources/CharkleCore/Sync/SyncOperations.swift`.
pub struct SyncFields;

impl SyncFields {
    /// Computes per-field JSON-fragment diffs between `value` and `previous`, omitting `excluding`.
    pub fn diff<T: Serialize>(
        value: &T,
        previous: Option<&T>,
        excluding: &[&str],
    ) -> CoreResult<BTreeMap<String, Vec<u8>>> {
        let excluded: HashSet<&str> = excluding.iter().copied().collect();
        let new_obj = to_json_object(value)?;
        let old_obj = match previous {
            Some(prev) => to_json_object(prev)?,
            None => Map::new(),
        };

        let mut all_keys: Vec<String> = new_obj.keys().chain(old_obj.keys()).cloned().collect();
        all_keys.sort();
        all_keys.dedup();

        let mut changes = BTreeMap::new();
        for key in all_keys {
            if excluded.contains(key.as_str()) {
                continue;
            }
            let new_bytes = match new_obj.get(&key) {
                Some(v) => canonical_json_bytes(v)?,
                None => b"null".to_vec(),
            };
            let old_bytes = match old_obj.get(&key) {
                Some(v) => Some(canonical_json_bytes(v)?),
                None => None,
            };
            if old_bytes.as_deref() != Some(new_bytes.as_slice()) {
                changes.insert(key, new_bytes);
            }
        }
        Ok(changes)
    }

    /// Applies per-field LWW changes from `delta` onto `original`, governed by `clocks`.
    pub fn merge<T: Serialize + DeserializeOwned>(
        delta: &BTreeMap<String, Vec<u8>>,
        original: &T,
        excluding: &[&str],
        stamp: &SyncStamp,
        clocks: &mut SyncClocks,
    ) -> CoreResult<T> {
        let excluded: HashSet<&str> = excluding.iter().copied().collect();
        let mut fields = to_json_object(original)?;

        for (field, data) in delta {
            if excluded.contains(field.as_str()) {
                continue;
            }
            let clock_key = format!("field:{field}");
            if !clocks.accept(stamp, &clock_key) {
                continue;
            }
            let parsed: Value = serde_json::from_slice(data)?;
            if parsed.is_null() {
                fields.remove(field);
            } else {
                fields.insert(field.clone(), parsed);
            }
        }

        let merged = serde_json::from_value(Value::Object(fields))?;
        Ok(merged)
    }
}

fn to_json_object<T: Serialize>(value: &T) -> CoreResult<Map<String, Value>> {
    match serde_json::to_value(value)? {
        Value::Object(map) => Ok(map),
        _ => Err(CoreError::InvalidPayload(
            "Invalid sync payload: expected JSON object.".to_string(),
        )),
    }
}

/// Encodes `SyncLogLine` items as newline-delimited canonical Swift JSONL.
pub fn encode_ops_jsonl(lines: &[SyncLogLine]) -> CoreResult<String> {
    if lines.is_empty() {
        return Ok(String::new());
    }
    let mut out = String::new();
    for line in lines {
        out.push_str(&canonical_json_string(line)?);
        out.push('\n');
    }
    Ok(out)
}

/// Decodes newline-delimited Swift JSONL ops into `SyncLogLine` entries.
pub fn decode_ops_jsonl(content: &str) -> CoreResult<Vec<SyncLogLine>> {
    let mut result = Vec::new();
    for line in content.lines() {
        let trimmed = line.trim();
        if trimmed.is_empty() {
            continue;
        }
        let parsed: SyncLogLine = serde_json::from_str(trimmed)?;
        result.push(parsed);
    }
    Ok(result)
}

/// Encodes `SyncManifest` into canonical sorted-key JSON.
pub fn encode_manifest(manifest: &SyncManifest) -> CoreResult<String> {
    canonical_json_string(manifest)
}

/// Decodes `SyncManifest` from JSON.
pub fn decode_manifest(json: &str) -> CoreResult<SyncManifest> {
    Ok(serde_json::from_str(json)?)
}

/// Parses `.charkle/ops/ops-<device32hex>-<endSeq>.jsonl`, matching Swift `DriveSyncEngine.LogFile`.
pub fn parse_ops_shard_file_name(name: &str) -> Option<(String, i64)> {
    let body = name.strip_prefix("ops-")?.strip_suffix(".jsonl")?;
    let (device, seq_str) = body.split_once('-')?;
    if device.len() != 32 || !device.chars().all(|c| c.is_ascii_hexdigit()) {
        return None;
    }
    if seq_str.is_empty() || !seq_str.chars().all(|c| c.is_ascii_digit()) {
        return None;
    }
    let end_seq: i64 = seq_str.parse().ok()?;
    if end_seq <= 0 {
        return None;
    }
    Some((device.to_string(), end_seq))
}

/// Formats `.charkle/ops/ops-<device32hex>-<endSeq>.jsonl`.
pub fn format_ops_shard_file_name(device: &str, end_seq: i64) -> String {
    format!("ops-{device}-{end_seq}.jsonl")
}
