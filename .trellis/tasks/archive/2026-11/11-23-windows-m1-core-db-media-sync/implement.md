# Implementation Checklist: Windows M1

## Prerequisites
- Windows 10/11 `x64` machine with VS 2022 C++ Build Tools, Rust stable (`x86_64-pc-windows-msvc`), and Node.js 22+ installed (see `../11-23-windows-client/research/windows-tauri-architecture.md` §5).

## Ordered Steps
1. Scaffold `./windows/Cargo.toml`, `rust-toolchain.toml`, empty crate skeletons (`charkle-core`, `charkle-platform-win`, `charkle-cli`, `src-tauri`), `scripts/sync-icons.mjs`, and `scripts/verify-windows.ps1`.
2. Implement `models/` + `wire/swift_codec.rs` + golden macOS wire fixtures & round-trip tests.
3. Implement `db/` (`LibraryDatabase`, FTS5 + `pinyin`, CIELAB color query, vectors, folders/smart-folders/boards/sync tables) + unit tests.
4. Implement `media/` (8 `MediaKind` pipeline, thumbnails, CIELAB extraction, EXIF/AI prompt extractor, audio waveform peaks, LRU cache + pin protection, X/Threads/Bluesky/GitHub/Web resolvers, `SampleLibrarySeeder`) + unit tests.
5. Implement `sync/` (`DriveSyncEngine`, 5 transports, PKCE OAuth loopback, `StorageMigration`) + multi-device conflict/rename tests.
6. Wire `LiveCharkleEngine` facade + run full validation gate.

## Validation Commands
```powershell
cd windows
node scripts/sync-icons.mjs
cargo fmt --all -- --check
cargo clippy --workspace --all-targets -- -D warnings
cargo test --workspace
```
