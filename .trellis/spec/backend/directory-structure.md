# Backend Directory Structure

> Module layout and dependency boundaries for `Sources/CharkleCore`, `Sources/CharkleCLI`, and `Tests/CharkleTests`.

---

## Target & Module Map

```text
Sources/
├── CharkleCore/                      # nonisolated Swift 6.2 domain engine
│   ├── Contracts/                    # Shared value types & protocol boundaries
│   │   ├── CoreModels.swift          # AssetRecord, FolderRecord, SmartFolderRule, FilterCriteria, SocialPostMetadata, GitHubRepoMetadata
│   │   ├── CoreServiceProtocols.swift# CharkleEngineProtocol, CharkleCoreNotifications
│   │   ├── MediaModels.swift         # CaptureInput, MediaKind, ThumbnailTier, CacheStats
│   │   ├── MoodboardModels.swift     # MoodboardDocument, BoardNode, BoardConnector, AutoLayoutConfig
│   │   └── SyncModels.swift          # DriveSyncConfig, SyncStatus, SyncReport, WebDAV/GDirect configs
│   ├── Database/                     # Local SQLite persistence & search
│   │   ├── LibraryDatabase.swift     # Actor owning SQLiteConnection, WAL, FTS5, vectors, sync_ops, sync_state
│   │   ├── SQLiteConnection.swift    # Low-level sqlite3 C-API wrapper
│   │   ├── AssetVector.swift         # Binary FeaturePrint + float16/float32 semantic embedding codec
│   │   └── SearchText.swift          # FTS5 tokenization, Mandarin Pinyin & initials indexing
│   ├── Media/                        # Ingestion, thumbnails, rich URL resolvers, metadata, LRU cache
│   │   ├── MediaPipeline.swift       # All-media import (raster, animated, video, audio, PDF, MD/text, SVG, 3D)
│   │   ├── MediaPipeline+Cache.swift # 2-tier original cache LRU eviction & offline pin protection
│   │   ├── ImageMetadataExtractor.swift # Full EXIF/TIFF/GPS/IPTC + AI prompt extraction (A1111/ComfyUI/NovelAI/InvokeAI/XMP)
│   │   ├── MarkdownDocumentParser.swift # GitHub README HTML hero, relative image URLs & GFM tables parser
│   │   ├── MediaArtwork.swift        # Procedural CoreGraphics posters (GitHub, Social, 3D, Audio, Swatch)
│   │   ├── GitHubRepoResolver.swift  # github.com/owner/repo parser, API metadata & README.md fetcher
│   │   ├── SocialPostResolver.swift  # X/Twitter, Threads, Bluesky unified post & attachment resolver
│   │   ├── XPostResolver.swift       # X/Twitter URL parser, syndication/fxtwitter fetch & media downloader
│   │   ├── WebBookmark.swift         # .webloc & OpenGraph metadata fetcher
│   │   ├── SVGPreview.swift          # Headless SVG rasterizer
│   │   └── SampleLibrarySeeder.swift # One-time initial sample artwork seeder
│   ├── Intelligence/                 # Local Vision + Cloud AI + Visual Grounding + MCP service
│   │   ├── IntelligenceEngine.swift  # VisionConcurrencyGate(limit: 3), Vision + CloudAI + TypeSafe facade
│   │   ├── VisionAnalyzer.swift      # Apple Vision OCR, FeaturePrint, Attention/Objectness Saliency
│   │   ├── ColorExtractor.swift      # CIELAB / CIEDE2000 dominant & subject-aware palette extraction
│   │   ├── CloudAIProvider.swift     # Gemini, OpenAI Chat/Responses, Anthropic Messages, ChatGPT Subscription
│   │   ├── ChatGPTSignInClient.swift # PKCE + OIDC RS256 JWKS Sign-in-with-ChatGPT client
│   │   ├── TypeSafeSystemOneClient.swift / VisualGroundingEngine.swift # Jev Box/Noul/Score/Choice grounding
│   │   ├── MoodboardCurator.swift / MoodboardAgentHarness.swift / ContactSheetRenderer.swift
│   │   ├── KeychainStore.swift       # macOS Keychain wrapper (isolated per service in tests)
│   │   └── CharkleExternalAgentService.swift / CharkleExternalAgentSchema.swift / MCPStdioFrameParser.swift / CharkleAgentTools.swift / ExternalAgentPolicy.swift
│   ├── Sync/                         # Multi-backend sync transports & sharded op-log sync
│   │   ├── DriveSyncEngine.swift     # Concurrent folder crawl, download, upload, tombstone reconciliation
│   │   ├── DirectAPITransport.swift  # Google Drive v3 pooled URLSession + resumable uploads
│   │   ├── MountedVolumeTransport.swift # Stable mount-relative path IDs (`mounted-path:`) + `st_dev` guard
│   │   ├── WebDAVTransport.swift     # WebDAV PROPFIND XML + streaming upload/download
│   │   ├── GDirectIntegration.swift  # gdirect CLI endpoint discovery & account parsing
│   │   ├── GoogleOAuthClient.swift   # Desktop OAuth PKCE client
│   │   ├── SyncOperations.swift      # CRDT-friendly op records & vector shard encoding
│   │   └── InMemoryDriveTransport.swift # Deterministic in-memory transport for tests
│   ├── Stubs/
│   │   └── PlaceholderEngine.swift   # In-memory CharkleEngineProtocol stub (must track protocol changes)
│   └── LiveCharkleEngine.swift       # Top-level actor implementing CharkleEngineProtocol
├── CharkleCLI/
│   ├── CharkleCLI.swift              # CLI dispatcher & non-blocking MCP stdio server (20 safe tools, soft-trash only)
│   ├── CLIArgParser.swift            # Flag/positional parser (--k=v, short flags, boolean-safe, per-subcommand help)
│   ├── CLIFormatter.swift            # Dual-mode TTY human formatter & pipe-safe auto-JSON output
│   └── CLICompletions.swift          # Shell completion generator (zsh / bash / fish)
└── Tests/CharkleTests/               # Swift Testing suites (no XCTest boilerplate)
```

---

## Placement Rules

| What you are adding | Put it here | Why |
|---------------------|-------------|-----|
| New model, enum, or filter field shared with UI | `Sources/CharkleCore/Contracts/` | Both `CharkleCanvas` and `CharkleApp` depend on `Contracts/` |
| Engine capability called by UI stores | Declare on `CharkleEngineProtocol`, implement in `LiveCharkleEngine` AND `PlaceholderEngine` | Keeps UI decoupled from concrete persistence & preserves previews/stubs |
| New URL/file format importer | `Sources/CharkleCore/Media/` | Media preparation stays pure, testable, and reusable by Sync & CLI |
| New sync backend or protocol parser | `Sources/CharkleCore/Sync/` implementing `DriveTransport` | `DriveSyncEngine` stays transport-agnostic |
| New unit/integration test | `Tests/CharkleTests/<Feature>Tests.swift` using `Testing` (`@Suite`, `@Test`, `#expect`, `#require`) | Fast parallel execution with isolated temp directories |

---

## Anti-Patterns

- **Don't** import `SwiftUI` or reference `@Observable` UI stores inside `CharkleCore`.
- **Don't** mutate `LibraryDatabase` from outside `LiveCharkleEngine` / `DriveSyncEngine` / `MoodboardCurator` / `MoodboardAgentHarness`.
- **Don't** create standalone `URLSession.shared` requests with infinite timeouts inside resolvers; always create an `.ephemeral` session with explicit timeouts and `defer { session.invalidateAndCancel() }` (see `SocialPostResolver.swift`, `GitHubRepoResolver.swift`).
