# Design: Web Frontend Design, Motion & v1.0.1 Parity Polish

## Architectural Constraints
1. **Strict Dual-Runtime Portability**: Any new server helper (especially `image-metadata-extractor.ts`) MUST avoid `node:fs` and `node:zlib` inside `@charkle/server/worker`-reachable code. Use `Uint8Array` + Web-standard `DecompressionStream('deflate')` so both Node 22+ and Cloudflare Workers (`workerd`) execute identically.
2. **Single Design Language (`DESIGN.md`)**: Every new primitive (`useDelayedFlag`, `Skeleton`, `SegmentedControl`, `EmptyStateVignette`) lives under `web/packages/client/src/design-system/` and exports via `design-system/index.ts`.
3. **Wire Compatibility**: `PhotoExifMetadata` and `AIGenerationMetadata` field names and JSON encodings MUST match `Sources/CharkleCore/Contracts/CoreModels.swift` verbatim so `/.charkle/` sync remains 100% lossless across macOS, Web, and Windows.
4. **Zero Performance Regression**: Keep all transitions strictly on `transform` and `opacity`; never introduce `transition: all`, `ease-in` exits, or `scale(0)`.
