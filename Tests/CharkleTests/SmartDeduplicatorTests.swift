import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import CharkleCore

@Suite("Non-AI Multi-Media Smart Deduplication Tests")
struct SmartDeduplicatorTests {
    // MARK: - Deterministic Synthetic Image Generators

    private func renderSyntheticArtwork(
        width: Int,
        height: Int,
        paletteVariant: Int = 0,
        pattern: Int = 0
    ) -> CGImage {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        )!
        let w = CGFloat(width)
        let h = CGFloat(height)

        if pattern == 0 {
            // Structured geometric illustration with distinct sky, sun, mountain, and foreground shapes
            let bg: CGColor = paletteVariant == 0
                ? CGColor(srgbRed: 0.12, green: 0.24, blue: 0.56, alpha: 1)
                : CGColor(srgbRed: 0.72, green: 0.18, blue: 0.14, alpha: 1)
            let mid: CGColor = paletteVariant == 0
                ? CGColor(srgbRed: 0.94, green: 0.76, blue: 0.34, alpha: 1)
                : CGColor(srgbRed: 0.18, green: 0.82, blue: 0.78, alpha: 1)
            let fg: CGColor = paletteVariant == 0
                ? CGColor(srgbRed: 0.16, green: 0.42, blue: 0.32, alpha: 1)
                : CGColor(srgbRed: 0.54, green: 0.16, blue: 0.58, alpha: 1)

            ctx.setFillColor(bg)
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))

            ctx.setFillColor(mid)
            ctx.fillEllipse(in: CGRect(x: w * 0.62, y: h * 0.58, width: w * 0.24, height: h * 0.28))

            ctx.setFillColor(fg)
            ctx.beginPath()
            ctx.move(to: CGPoint(x: 0, y: 0))
            ctx.addLine(to: CGPoint(x: w * 0.38, y: h * 0.62))
            ctx.addLine(to: CGPoint(x: w * 0.72, y: h * 0.28))
            ctx.addLine(to: CGPoint(x: w, y: h * 0.52))
            ctx.addLine(to: CGPoint(x: w, y: 0))
            ctx.closePath()
            ctx.fillPath()

            ctx.setFillColor(CGColor(srgbRed: 0.96, green: 0.95, blue: 0.92, alpha: 1))
            ctx.fill(CGRect(x: w * 0.12, y: h * 0.14, width: w * 0.18, height: h * 0.34))
        } else {
            // Completely different composition (diagonal checker + dark ring)
            ctx.setFillColor(CGColor(srgbRed: 0.92, green: 0.91, blue: 0.88, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            ctx.setFillColor(CGColor(srgbRed: 0.11, green: 0.12, blue: 0.15, alpha: 1))
            ctx.fill(CGRect(x: 0, y: h * 0.5, width: w * 0.5, height: h * 0.5))
            ctx.fill(CGRect(x: w * 0.5, y: 0, width: w * 0.5, height: h * 0.5))
            ctx.setFillColor(CGColor(srgbRed: 0.86, green: 0.25, blue: 0.20, alpha: 1))
            ctx.fillEllipse(in: CGRect(x: w * 0.3, y: h * 0.3, width: w * 0.4, height: h * 0.4))
        }
        return ctx.makeImage()!
    }

    private func renderSolidColor(width: Int, height: Int, r: CGFloat, g: CGFloat, b: CGFloat) -> CGImage {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        )!
        ctx.setFillColor(CGColor(srgbRed: r, green: g, blue: b, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()!
    }

    private func encodeImage(_ image: CGImage, type: UTType, quality: Double = 0.9) -> Data {
        let data = NSMutableData()
        let dest = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil)!
        let opts: [CFString: Any] = type == .jpeg
            ? [kCGImageDestinationLossyCompressionQuality: quality]
            : [:]
        CGImageDestinationAddImage(dest, image, opts as CFDictionary)
        CGImageDestinationFinalize(dest)
        return data as Data
    }

    // MARK: - 1. Classical Perceptual Matching & Highest Quality Selection

    @Test("Detects high-res PNG vs downscaled low-quality JPEG and keeps highest quality version")
    func detectsRescaledRecompressedDuplicateAndPicksBest() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "charkle-dedup-test-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let highCG = renderSyntheticArtwork(width: 1200, height: 900, paletteVariant: 0, pattern: 0)
        let lowCG = renderSyntheticArtwork(width: 400, height: 300, paletteVariant: 0, pattern: 0)
        let diffCG = renderSyntheticArtwork(width: 1200, height: 900, paletteVariant: 0, pattern: 1)

        let highData = encodeImage(highCG, type: .png)
        let lowData = encodeImage(lowCG, type: .jpeg, quality: 0.45)
        let diffData = encodeImage(diffCG, type: .png)

        let highURL = dir.appending(path: "art-master.png")
        let lowURL = dir.appending(path: "art-thumb.jpg")
        let diffURL = dir.appending(path: "other.png")
        try highData.write(to: highURL)
        try lowData.write(to: lowURL)
        try diffData.write(to: diffURL)

        let fpHigh = try #require(SmartDeduplicator.computeFingerprint(from: highURL, declaredAspectRatio: 4.0 / 3.0))
        let fpLow = try #require(SmartDeduplicator.computeFingerprint(from: lowURL, declaredAspectRatio: 4.0 / 3.0))
        let fpDiff = try #require(SmartDeduplicator.computeFingerprint(from: diffURL, declaredAspectRatio: 4.0 / 3.0))

        let highAsset = AssetRecord(
            title: "Art Master",
            fileName: "art-master.png",
            contentHash: "hash-high",
            mediaKind: .image,
            mimeType: "image/png",
            fileSizeBytes: Int64(highData.count),
            pixelWidth: 1200,
            pixelHeight: 900
        )
        let lowAsset = AssetRecord(
            title: "Art Thumb",
            fileName: "art-thumb.jpg",
            contentHash: "hash-low",
            mediaKind: .image,
            mimeType: "image/jpeg",
            fileSizeBytes: Int64(lowData.count),
            pixelWidth: 400,
            pixelHeight: 300
        )
        let diffAsset = AssetRecord(
            title: "Unrelated Poster",
            fileName: "other.png",
            contentHash: "hash-diff",
            mediaKind: .image,
            mimeType: "image/png",
            fileSizeBytes: Int64(diffData.count),
            pixelWidth: 1200,
            pixelHeight: 900
        )

        let groups = SmartDeduplicator.clusterDuplicates(
            items: [
                .init(asset: highAsset, fingerprint: fpHigh),
                .init(asset: lowAsset, fingerprint: fpLow),
                .init(asset: diffAsset, fingerprint: fpDiff),
            ],
            sensitivity: .balanced,
            boardReferencedAssetIDs: []
        )

        #expect(groups.count == 1)
        let group = try #require(groups.first)
        #expect(group.matchKind == .nearIdentical)
        #expect(group.candidates.count == 2)
        #expect(group.recommendedKeepAssetID == highAsset.id)
        #expect(group.candidates[0].asset.id == highAsset.id)
        #expect(group.candidates[0].isRecommendedKeep == true)
        #expect(group.candidates[0].isLosslessFormat == true)
        #expect(group.candidates[1].asset.id == lowAsset.id)
    }

    // MARK: - 2. Zero False Positives (Recolored Variants & Solid Color Swatches)

    @Test("Does not falsely merge different colorways or solid color swatches")
    func rejectsColorVariantsAndSolidSwatches() throws {
        let blueArt = renderSyntheticArtwork(width: 600, height: 450, paletteVariant: 0, pattern: 0)
        let redArt = renderSyntheticArtwork(width: 600, height: 450, paletteVariant: 1, pattern: 0)
        let blueSwatch = renderSolidColor(width: 400, height: 400, r: 0.16, g: 0.38, b: 0.88)
        let redSwatch = renderSolidColor(width: 400, height: 400, r: 0.88, g: 0.16, b: 0.38)

        let fpBlueArt = try #require(SmartDeduplicator.computeFingerprint(from: blueArt))
        let fpRedArt = try #require(SmartDeduplicator.computeFingerprint(from: redArt))
        let fpBlueSwatch = try #require(SmartDeduplicator.computeFingerprint(from: blueSwatch))
        let fpRedSwatch = try #require(SmartDeduplicator.computeFingerprint(from: redSwatch))

        #expect(SmartDeduplicator.visualSimilarity(between: fpBlueArt, and: fpRedArt, sensitivity: .balanced) == nil)
        #expect(SmartDeduplicator.visualSimilarity(between: fpBlueSwatch, and: fpRedSwatch, sensitivity: .relaxed) == nil)
    }

    // MARK: - 3. Multi-Media Coverage: Audio, Web Bookmarks, Documents, Video & Cross-Kind Isolation

    @Test("Covers Audio waveform matching, Canonical Bookmarks, Normalized Text Docs, Video, and isolates Design Files")
    func multiMediaKindDeduplicationCoverage() throws {
        // Audio: FLAC lossless vs MP3 128k with matching waveform envelope
        let peaksA: [Float] = (0..<48).map { Float(0.15 + 0.75 * abs(sin(Double($0) * 0.28))) }
        let peaksB: [Float] = peaksA.map { min(1.0, max(0.0, $0 * 0.97 + 0.01)) }
        let peaksOther: [Float] = (0..<48).map { Float(0.1 + 0.8 * abs(cos(Double($0) * 0.71))) }

        let flac = AssetRecord(
            title: "Theme Lossless", fileName: "theme.flac", contentHash: "aud-1",
            mediaKind: .audio, mimeType: "audio/flac", fileSizeBytes: 24_000_000,
            pixelWidth: 0, pixelHeight: 0, durationSeconds: 180.0, waveformPeaks: peaksA
        )
        let mp3 = AssetRecord(
            title: "Theme MP3", fileName: "theme.mp3", contentHash: "aud-2",
            mediaKind: .audio, mimeType: "audio/mpeg", fileSizeBytes: 2_900_000,
            pixelWidth: 0, pixelHeight: 0, durationSeconds: 180.2, waveformPeaks: peaksB
        )
        let otherTrack = AssetRecord(
            title: "Other SFX", fileName: "sfx.mp3", contentHash: "aud-3",
            mediaKind: .audio, mimeType: "audio/mpeg", fileSizeBytes: 3_000_000,
            pixelWidth: 0, pixelHeight: 0, durationSeconds: 180.0, waveformPeaks: peaksOther
        )

        // Web Bookmarks: X tweet with tracking params vs Twitter legacy host
        let richPost = AssetRecord(
            title: "@artist · Rich Tweet", fileName: "post1.md", contentHash: "bm-1",
            mediaKind: .webBookmark, mimeType: "text/markdown", fileSizeBytes: 2048,
            sourceURL: "https://x.com/artist/status/1899999999?s=20&t=xyz",
            richMetadata: AssetRichMetadata(socialPost: SocialPostMetadata(
                platform: .x, authorName: "Artist", authorHandle: "artist",
                bodyText: "Full illustration breakdown with 3 attached photos",
                attachments: [
                    SocialMediaAttachment(kind: .photo, url: "https://pbs.twimg.com/media/A.jpg"),
                    SocialMediaAttachment(kind: .photo, url: "https://pbs.twimg.com/media/B.jpg"),
                ],
                originalURL: "https://x.com/artist/status/1899999999"
            ))
        )
        let sparsePost = AssetRecord(
            title: "Sparse Tweet", fileName: "post2.webloc", contentHash: "bm-2",
            mediaKind: .webBookmark, mimeType: "application/xml", fileSizeBytes: 240,
            sourceURL: "https://twitter.com/artist/status/1899999999",
            richMetadata: AssetRichMetadata(socialPost: SocialPostMetadata(
                platform: .x, authorName: "Artist", authorHandle: "artist",
                bodyText: "Short",
                originalURL: "https://twitter.com/artist/status/1899999999",
                mediaFetchFailed: true
            ))
        )

        // Documents: CRLF vs LF normalized text match
        let docBody = "Charkle visual design notes and color palette study for autumn editorial moodboard layout."
        let docA = AssetRecord(
            title: "Notes A", fileName: "notes-a.md", contentHash: "doc-1",
            mediaKind: .document, mimeType: "text/markdown", fileSizeBytes: 512,
            ocrText: docBody
        )
        let docB = AssetRecord(
            title: "Notes B", fileName: "notes-b.md", contentHash: "doc-2",
            mediaKind: .document, mimeType: "text/markdown", fileSizeBytes: 256,
            ocrText: "  \(docBody)  \r\n"
        )

        // Design file vs exported PNG with identical thumbnail MUST stay isolated
        let sharedCG = renderSyntheticArtwork(width: 640, height: 480, paletteVariant: 0, pattern: 0)
        let sharedFP = try #require(SmartDeduplicator.computeFingerprint(from: sharedCG))
        let psdFile = AssetRecord(
            title: "Layer Master", fileName: "scene.psd", contentHash: "psd-1",
            mediaKind: .designFile, mimeType: "image/vnd.adobe.photoshop", fileSizeBytes: 45_000_000,
            pixelWidth: 2000, pixelHeight: 1500
        )
        let exportedPNG = AssetRecord(
            title: "Exported Preview", fileName: "scene.png", contentHash: "png-1",
            mediaKind: .image, mimeType: "image/png", fileSizeBytes: 3_000_000,
            pixelWidth: 2000, pixelHeight: 1500
        )

        // Video: 1080p high bitrate vs 480p low bitrate same duration & poster
        let vid1080 = AssetRecord(
            title: "Clip 1080p", fileName: "clip-hd.mp4", contentHash: "vid-1",
            mediaKind: .video, mimeType: "video/mp4", fileSizeBytes: 18_000_000,
            pixelWidth: 1920, pixelHeight: 1080, durationSeconds: 12.0
        )
        let vid480 = AssetRecord(
            title: "Clip 480p", fileName: "clip-sd.mp4", contentHash: "vid-2",
            mediaKind: .video, mimeType: "video/mp4", fileSizeBytes: 2_500_000,
            pixelWidth: 854, pixelHeight: 480, durationSeconds: 12.2
        )
        let vidDifferentLen = AssetRecord(
            title: "Long Intro", fileName: "long.mp4", contentHash: "vid-3",
            mediaKind: .video, mimeType: "video/mp4", fileSizeBytes: 60_000_000,
            pixelWidth: 1920, pixelHeight: 1080, durationSeconds: 95.0
        )

        let items: [SmartDeduplicator.IndexedMediaAsset] = [
            .init(asset: flac),
            .init(asset: mp3),
            .init(asset: otherTrack),
            .init(asset: richPost, canonicalBookmarkKey: SmartDeduplicator.canonicalBookmarkKey(for: richPost)),
            .init(asset: sparsePost, canonicalBookmarkKey: SmartDeduplicator.canonicalBookmarkKey(for: sparsePost)),
            .init(asset: docA, normalizedTextHash: SmartDeduplicator.normalizedDocumentTextHash(for: docA, cachedFileURL: nil)),
            .init(asset: docB, normalizedTextHash: SmartDeduplicator.normalizedDocumentTextHash(for: docB, cachedFileURL: nil)),
            .init(asset: psdFile, fingerprint: sharedFP),
            .init(asset: exportedPNG, fingerprint: sharedFP),
            .init(asset: vid1080, fingerprint: sharedFP),
            .init(asset: vid480, fingerprint: sharedFP),
            .init(asset: vidDifferentLen, fingerprint: sharedFP),
        ]

        let groups = SmartDeduplicator.clusterDuplicates(
            items: items,
            sensitivity: .balanced,
            boardReferencedAssetIDs: []
        )

        // Expect 4 clean groups: audio, bookmark, document, video (PSD & PNG stay isolated; long video stays separate)
        #expect(groups.count == 4)

        let audioGroup = try #require(groups.first(where: { $0.matchKind == .audioWaveform }))
        #expect(audioGroup.recommendedKeepAssetID == flac.id)
        #expect(audioGroup.candidates.count == 2)

        let linkGroup = try #require(groups.first(where: { $0.matchKind == .canonicalLink }))
        #expect(linkGroup.recommendedKeepAssetID == richPost.id)

        let docGroup = try #require(groups.first(where: { $0.matchKind == .normalizedText }))
        #expect(docGroup.recommendedKeepAssetID == docA.id)

        let videoGroup = try #require(groups.first(where: { $0.primaryMediaKind == .video }))
        #expect(videoGroup.recommendedKeepAssetID == vid1080.id)
        #expect(videoGroup.candidates.count == 2)
    }

    // MARK: - 4. End-to-End LiveCharkleEngine Scan + Lossless Metadata & Moodboard Merge

    @Test("LiveCharkleEngine scans duplicates, keeps highest quality PNG, merges metadata, and rewrites Moodboard references")
    func endToEndLiveEngineDedupAndBoardMerge() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "charkle-dedup-e2e-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let engine = try LiveCharkleEngine.make(appSupportDirectory: root)
        let folder = try await engine.createFolder(name: "画师参考", parentID: nil)

        let highPNG = encodeImage(renderSyntheticArtwork(width: 1000, height: 750, paletteVariant: 0, pattern: 0), type: .png)
        let lowJPG = encodeImage(renderSyntheticArtwork(width: 360, height: 270, paletteVariant: 0, pattern: 0), type: .jpeg, quality: 0.45)

        // High-res PNG sits unorganized in Inbox with no tags; low-res JPG has folder, tags, rating, notes & Moodboard ref!
        let highCreated = try await engine.ingest(
            [.imageData(highPNG, suggestedName: "hero-master.png", sourceURL: nil)],
            targetFolderID: nil,
            targetBoardID: nil
        )
        let lowCreated = try await engine.ingest(
            [.imageData(lowJPG, suggestedName: "hero-low.jpg", sourceURL: "https://x.com/artist/status/11223344")],
            targetFolderID: folder.id,
            targetBoardID: nil
        )
        let highAsset = try #require(highCreated.first)
        let lowAsset = try #require(lowCreated.first)

        _ = try await engine.updateAssets(AssetBatchPatch(
            assetIDs: [lowAsset.id],
            notes: "光影参考笔记",
            rating: 5,
            addTags: ["光影", "赛博"]
        ))

        let board = MoodboardDocument(
            title: "主视觉板",
            nodes: [
                BoardNode(
                    kind: .assetRef(assetID: lowAsset.id, crop: nil, weight: 2, autoplayLoop: false),
                    frame: BoardRect(x: 40, y: 40, width: 320, height: 240)
                )
            ]
        )
        let savedBoard = try await engine.saveBoard(board)

        let report = try await engine.scanDuplicateImages(
            scope: .allActive,
            sensitivity: .balanced,
            mediaKinds: nil,
            onProgress: nil
        )
        #expect(report.groups.count == 1)
        let group = try #require(report.groups.first)
        #expect(group.recommendedKeepAssetID == highAsset.id)

        let plan = DeduplicationResolutionPlan(
            keepAssetID: highAsset.id,
            removeAssetIDs: [lowAsset.id]
        )
        let cleanup = try await engine.resolveDuplicateGroups([plan], disposal: .moveToTrash, mergeMetadata: true)

        #expect(cleanup.resolvedGroupCount == 1)
        #expect(cleanup.removedAssetCount == 1)
        #expect(cleanup.mergedMetadataCount == 1)
        #expect(cleanup.updatedBoardCount == 1)

        // Verify keeper inherited folder, tags, rating, notes, and sourceURL
        let updatedHigh = try #require(try await engine.fetchAsset(id: highAsset.id))
        #expect(updatedHigh.isTrashed == false)
        #expect(updatedHigh.folderID == folder.id)
        #expect(updatedHigh.rating == 5)
        #expect(updatedHigh.tags.contains("光影"))
        #expect(updatedHigh.tags.contains("赛博"))
        #expect(updatedHigh.notes.contains("光影参考笔记"))
        #expect(updatedHigh.sourceURL == "https://x.com/artist/status/11223344")

        // Verify duplicate was safely moved to Trash
        let trashedLow = try #require(try await engine.fetchAsset(id: lowAsset.id))
        #expect(trashedLow.isTrashed == true)

        // Verify Moodboard reference now points to the high-res master!
        let updatedBoard = try #require(try await engine.fetchBoard(id: savedBoard.id))
        #expect(updatedBoard.referencedAssetIDs == [highAsset.id])
    }

    // MARK: - 5. LocalExtensionBridgeServer `mediaCanonicalKeys` & `tweetMedia` Contract

    @Test("LocalExtensionBridgeServer separates mediaCanonicalKeys from webBookmark canonicalKeys")
    func bridgeSeparatesMediaCanonicalKeysFromBookmarks() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "charkle-bridge-media-keys-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let engine = try LiveCharkleEngine.make(appSupportDirectory: root)
        let bookmarkMeta = SocialPostMetadata(
            platform: .x,
            authorName: "Artist",
            authorHandle: "artist",
            bodyText: "Saved as bookmark only",
            originalURL: "https://x.com/artist/status/1900000000000000111"
        )
        _ = try await engine.ingest(
            [.socialBookmark(bookmarkMeta, coverImageData: nil, tags: ["X"])],
            targetFolderID: nil,
            targetBoardID: nil
        )
        let sampleImg = encodeImage(renderSyntheticArtwork(width: 200, height: 200), type: .png)
        _ = try await engine.ingest(
            [
                .imageData(sampleImg, suggestedName: "art.png", sourceURL: "https://x.com/artist/status/1900000000000000222"),
                .imageData(sampleImg, suggestedName: "pixiv-p0.png", sourceURL: "https://www.pixiv.net/en/artworks/123456789"),
                .imageData(sampleImg, suggestedName: "ig-01.png", sourceURL: "https://www.instagram.com/p/C9AbCdEf123/"),
            ],
            targetFolderID: nil,
            targetBoardID: nil
        )

        let token = "test-bridge-token-123456"
        let server = LocalExtensionBridgeServer(
            engine: engine,
            token: token,
            allowLocalAutoPair: false,
            preferredPort: 0,
            allowEphemeralPort: true
        )
        let status = try await server.start()
        defer { Task { await server.stop() } }

        var req = URLRequest(url: URL(string: "\(status.baseURL)/api/v1/assets/existing-sources")!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: req)
        let http = try #require(response as? HTTPURLResponse)
        #expect(http.statusCode == 200)

        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let canonicalKeys = Set(json["canonicalKeys"] as? [String] ?? [])
        let mediaKeys = Set(json["mediaCanonicalKeys"] as? [String] ?? [])

        #expect(canonicalKeys.contains("x:1900000000000000111"))
        #expect(canonicalKeys.contains("x:1900000000000000222"))
        #expect(!mediaKeys.contains("x:1900000000000000111"))
        #expect(mediaKeys.contains("x:1900000000000000222"))
        #expect(mediaKeys.contains("pixiv:123456789"))
        #expect(mediaKeys.contains("ig:C9AbCdEf123"))

        // Verify Pixiv & Instagram canonical URL parsing directly
        #expect(SocialPostResolver.canonicalDedupKey(for: "https://www.pixiv.net/member_illust.php?mode=medium&illust_id=556677") == "pixiv:556677")
        #expect(SocialPostResolver.canonicalDedupKey(for: "https://www.instagram.com/artist/reel/D9XyZ_11/") == "ig:D9XyZ_11")
    }
}
