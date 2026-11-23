//! macOS Swift `JSONEncoder` / `JSONDecoder` wire-format adapters for lossless `/.charkle/` parity.

pub mod swift_codec;

pub use swift_codec::{
    canonical_json_bytes, canonical_json_string, canonicalize_value, cocoa_seconds_to_datetime,
    datetime_to_cocoa_seconds, decode_manifest, decode_ops_jsonl, encode_manifest,
    encode_ops_jsonl, format_ops_shard_file_name, parse_ops_shard_file_name, SyncFields,
    COCOA_EPOCH_OFFSET_SEC,
};
