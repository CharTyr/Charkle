# Design: Windows M1 — `charkle-core` Architecture

## Module Boundaries
- `crates/charkle-core/src/traits/mod.rs`: Defines 4 OS seams (`SecretVault`, `NativeOcrProvider`, `ShellThumbnailProvider`, `VolumeMountInspector`) with in-memory/noop defaults so `charkle-core` stays 100% testable without Win32 dependencies.
- `crates/charkle-core/src/wire/swift_codec.rs`: Dedicated serde helpers (`cocoa_date`, `upper_uuid`, `base64_data`, Swift keyed-enum adapters, sorted-key `SyncFields` diff/merge) isolating macOS wire-format rules from internal Rust models.
- `crates/charkle-core/src/db/`: `LibraryDatabase` backed by `rusqlite` connection pool / single-writer mutex (`BEGIN IMMEDIATE` transactions matching `LibraryDatabase.swift`), `SearchText` pinyin/initials indexer, and `AssetVector` BLOB cosine matcher.
- `crates/charkle-core/src/media/`: `MediaPipeline` + `CacheManager` + `ImageMetadataExtractor` + `ColorExtractor` (sRGB → XYZ → CIELAB + ΔE2000) + `RichResolvers` (`x`, `social`, `github`, `bookmark`) + `SampleLibrarySeeder`.
- `crates/charkle-core/src/sync/`: `DriveTransport` async trait + 5 concrete transports (`direct_api`, `webdav`, `mounted_volume`, `local_folder`, `in_memory`) + `DriveSyncEngine` + `StorageMigration`.
- `crates/charkle-core/src/engine.rs`: `LiveCharkleEngine` facade exposing async methods and a broadcast `EngineEvent` channel (`SyncStatus`, `LibraryChanged`, `AssetEnriched`, `BoardUpdated`).

## Windows Path Normalization Invariant
- Inside SQLite and `/.charkle/` sync ops, folder paths always use POSIX `/` separators and preserve original logical names.
- On local Windows filesystem projection (`LocalFolderTransport` / `MountedVolumeTransport`), sanitize reserved characters (`<>:"/\|?*`) and reserved names (`CON`, `PRN`, `AUX`, `NUL`, `COM1–9`, `LPT1–9`) deterministically while preserving logical `title`/`fileName` in metadata.
