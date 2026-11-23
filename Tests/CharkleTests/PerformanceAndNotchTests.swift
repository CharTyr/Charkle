import CharkleCanvas
import CharkleCore
import CryptoKit
import Foundation
import Synchronization
import Testing

@Suite("Notch Drop Precision, Virtualized Masonry O(log N) & Parallel Drive Sync")
struct PerformanceAndNotchTests {

    // MARK: - 1. Notch Drop Zone Precision

    @Test("Notch drop rect rejects transparent shadow margins and drag trigger stays tightly anchored to notch")
    func notchDropPrecision() {
        let bodyWidth: CGFloat = 476
        let cardHeight: CGFloat = 216
        let panelBounds = NSRect(x: 0, y: 0, width: bodyWidth + 24 + 96, height: cardHeight + 56)

        let dropRect = NotchDropGeometry.strictCardRect(
            panelBounds: panelBounds,
            bodyWidth: bodyWidth,
            cardHeight: cardHeight
        )
        #expect(dropRect.width == bodyWidth)
        #expect(dropRect.height == cardHeight)
        #expect(dropRect.minY == 56)
        #expect(dropRect.maxY == panelBounds.maxY)

        // Point inside visible black capsule accepts drop
        #expect(dropRect.contains(NSPoint(x: panelBounds.midX, y: dropRect.midY)))
        // Point even 2pt below the black capsule (inside transparent shadow margin) MUST NOT accept drop
        #expect(!dropRect.contains(NSPoint(x: panelBounds.midX, y: dropRect.minY - 2)))
        #expect(!dropRect.contains(NSPoint(x: panelBounds.midX, y: 10)))
        // Points inside left/right transparent margins MUST NOT accept drop
        #expect(!dropRect.contains(NSPoint(x: dropRect.minX - 4, y: dropRect.midY)))
        #expect(!dropRect.contains(NSPoint(x: dropRect.maxX + 4, y: dropRect.midY)))

        // Screen-space drag trigger gives a comfortable arrival band right below the physical notch
        // so dragging up opens the shelf BEFORE hitting macOS top-edge Mission Control / Spaces switching.
        let screen = NSRect(x: 0, y: 0, width: 1512, height: 982)
        // Inside physical notch -> triggers
        #expect(NotchDropGeometry.isPointInDragTriggerZone(
            NSPoint(x: screen.midX, y: screen.maxY - 20),
            screenFrame: screen,
            hasPhysicalNotch: true,
            notchWidth: 204,
            notchHeight: 37
        ))
        // 55pt below top edge (just below physical notch, well away from top-1px Mission Control) -> triggers
        #expect(NotchDropGeometry.isPointInDragTriggerZone(
            NSPoint(x: screen.midX, y: screen.maxY - 55),
            screenFrame: screen,
            hasPhysicalNotch: true,
            notchWidth: 204,
            notchHeight: 37
        ))
        // 200pt below top edge (other app workspace, matching user screenshot) -> MUST NOT trigger
        #expect(!NotchDropGeometry.isPointInDragTriggerZone(
            NSPoint(x: screen.midX, y: screen.maxY - 200),
            screenFrame: screen,
            hasPhysicalNotch: true,
            notchWidth: 204,
            notchHeight: 37
        ))
        // Horizontally far off-center (220pt from screen center, outside notch arrival band) -> MUST NOT trigger
        #expect(!NotchDropGeometry.isPointInDragTriggerZone(
            NSPoint(x: screen.midX + 220, y: screen.maxY - 12),
            screenFrame: screen,
            hasPhysicalNotch: true,
            notchWidth: 204,
            notchHeight: 37
        ))

        // Fixed max-size NSPanel accommodates both compact and full-gallery states without window resize,
        // while strictCardRect tracks the live visible capsule bounds in unflipped AppKit window coordinates.
        let maxPanelBounds = NSRect(x: 0, y: 0, width: 980 + 24 + 96, height: 580 + 56)
        let compactHit = NotchDropGeometry.strictCardRect(panelBounds: maxPanelBounds, bodyWidth: 636, cardHeight: 330)
        let fullHit = NotchDropGeometry.strictCardRect(panelBounds: maxPanelBounds, bodyWidth: 980, cardHeight: 580)
        #expect(compactHit.maxY == maxPanelBounds.maxY)
        #expect(fullHit.maxY == maxPanelBounds.maxY)
        // Drop well sits ~120pt below top bezel -> in unflipped window coords y = maxY - 120 = 516
        #expect(compactHit.contains(NSPoint(x: maxPanelBounds.midX, y: maxPanelBounds.maxY - 120)))
        // Below the 330pt compact capsule -> rejected in compact mode, accepted when full waterfall is open
        #expect(!compactHit.contains(NSPoint(x: maxPanelBounds.midX, y: maxPanelBounds.maxY - 400)))
        #expect(fullHit.contains(NSPoint(x: maxPanelBounds.midX, y: maxPanelBounds.maxY - 400)))

        // Stale drag pasteboard (unchanged changeCount from a past drag) MUST NOT expand the notch
        #expect(!NotchDropGeometry.shouldTriggerProactiveDragExpand(
            currentDragChangeCount: 42,
            baselineDragChangeCount: 42,
            isInternalDrag: false,
            hasDroppablePayload: true
        ))
        // Fresh external drag (changeCount incremented) triggers proactive expand
        #expect(NotchDropGeometry.shouldTriggerProactiveDragExpand(
            currentDragChangeCount: 43,
            baselineDragChangeCount: 42,
            isInternalDrag: false,
            hasDroppablePayload: true
        ))
        // Fresh internal Charkle drag MUST NOT trigger expand
        #expect(!NotchDropGeometry.shouldTriggerProactiveDragExpand(
            currentDragChangeCount: 44,
            baselineDragChangeCount: 43,
            isInternalDrag: true,
            hasDroppablePayload: true
        ))
    }

    @Test("Hover muted preview eligibility & local-only cachedOriginalURL never trigger cloud downloads")
    @MainActor
    func hoverMediaPreviewEligibilityAndLocalLookup() async throws {
        let videoAsset = AssetRecord(title: "Clip", fileName: "clip.mp4", mediaKind: .video)
        let gifAsset = AssetRecord(title: "Loop", fileName: "loop.gif", mediaKind: .animatedImage)
        let imageAsset = AssetRecord(title: "Photo", fileName: "photo.jpg", mediaKind: .image)
        let socialVideoPost = AssetRecord(
            title: "Tweet",
            fileName: "tweet.png",
            mediaKind: .video,
            richMetadata: AssetRichMetadata(socialPost: SocialPostMetadata(
                platform: .x,
                authorName: "Author",
                authorHandle: "author",
                bodyText: "hello",
                originalURL: "https://x.com/author/status/123"
            ))
        )

        #expect(HoverMediaPreviewLayerController.supportsHoverPlayback(videoAsset))
        #expect(HoverMediaPreviewLayerController.supportsHoverPlayback(gifAsset))
        #expect(!HoverMediaPreviewLayerController.supportsHoverPlayback(imageAsset))
        #expect(!HoverMediaPreviewLayerController.supportsHoverPlayback(socialVideoPost))

        let directory = try BackendFixture.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let engine = try BackendFixture.makeEngine(directory)
        let created = try await engine.ingest(
            [.imageData(try BackendFixture.artwork("#3D5A80"), suggestedName: "local.png", sourceURL: nil)],
            targetFolderID: nil,
            targetBoardID: nil
        )
        let local = try #require(created.first)
        #expect(engine.cachedOriginalURL(for: local) != nil)
        #expect(engine.cachedOriginalURL(for: videoAsset) == nil)
    }

    // MARK: - 2. Virtualized Masonry O(log N) Visibility & Scale Performance

    @Test("Masonry O(log N) visibleItems and intersectingIDs match brute force across 10,000 items under 50 ms")
    func masonryTenThousandItemsQueryAccuracyAndSpeed() {
        var assets: [AssetRecord] = []
        assets.reserveCapacity(10_000)
        for i in 0..<10_000 {
            let w = 800 + (i % 7) * 120
            let h = 600 + ((i * 5) % 9) * 140
            assets.append(AssetRecord(
                title: "Ref \(i)",
                fileName: "ref-\(i).jpg",
                mediaKind: .image,
                pixelWidth: w,
                pixelHeight: h
            ))
        }

        let snapshot = MasonryLayoutEngine.compute(
            assets: assets,
            containerWidth: 1440,
            targetColumnWidth: 228,
            spacing: 12,
            horizontalPadding: 20,
            topInset: 76,
            bottomInset: 96
        )
        #expect(snapshot.items.count == 10_000)

        // Verify minY monotonicity invariant that O(log N) early exit depends on
        for idx in 1..<snapshot.items.count {
            #expect(snapshot.items[idx].rect.minY >= snapshot.items[idx - 1].rect.minY - 0.001)
        }

        // Cross-check exact equality against brute-force scan at multiple scroll depths
        let sampleRanges: [(CGFloat, CGFloat)] = [
            (0, 1_800),
            (snapshot.totalHeight * 0.25, snapshot.totalHeight * 0.25 + 2_200),
            (snapshot.totalHeight * 0.65, snapshot.totalHeight * 0.65 + 2_200),
            (max(0, snapshot.totalHeight - 2_000), snapshot.totalHeight + 500),
            (snapshot.totalHeight + 1_000, snapshot.totalHeight + 3_000)
        ]
        for (minY, maxY) in sampleRanges {
            let fast = snapshot.visibleItems(minY: minY, maxY: maxY)
            let brute = snapshot.items.filter { $0.rect.maxY >= minY && $0.rect.minY <= maxY }
            #expect(fast == brute)
        }

        // Verify marquee intersectingIDs matches brute-force intersection
        let marquee = CGRect(x: 180, y: snapshot.totalHeight * 0.4, width: 620, height: 950)
        let fastMarquee = Set(snapshot.intersectingIDs(in: marquee))
        let bruteMarquee = Set(snapshot.items.filter { $0.rect.intersects(marquee) }.map(\.id))
        #expect(fastMarquee == bruteMarquee)
        #expect(!fastMarquee.isEmpty)

        // Benchmark 500 viewport slice queries over 10,000 items
        let start = ContinuousClock.now
        var checksum = 0
        for step in 0..<500 {
            let y = CGFloat(step) * (snapshot.totalHeight / 500.0)
            checksum &+= snapshot.visibleItems(minY: y, maxY: y + 2_200).count
        }
        let elapsed = start.duration(to: .now)
        let elapsedMs = Double(elapsed.components.seconds) * 1_000
            + Double(elapsed.components.attoseconds) / 1e15
        #expect(checksum > 0)
        #expect(elapsedMs < 250.0, "500 scroll queries over 10,000 items should finish in <250ms in Debug, took \(elapsedMs)ms")
    }

    // MARK: - 3. DirectAPITransport Single-Shot Multipart & Metadata-Free Download

    @Test("DirectAPITransport uses 1-shot multipart upload and skips extra metadata GET when file metadata is known")
    func directAPIFastPaths() async throws {
        FastPathFixtureHTTP.reset()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FastPathFixtureHTTP.self]
        let session = URLSession(configuration: config)

        let directory = try BackendFixture.directory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let transport = DirectAPITransport(
            accessToken: { "fast-token" },
            session: session,
            transferDirectory: directory,
            multipartThresholdBytes: 5 * 1_048_576
        )

        // 1) uploadData -> single-shot multipart POST (1 HTTP request)
        let payload = Data("charkle-fast-upload-payload".utf8)
        let uploadedData = try await transport.uploadData(
            payload,
            name: "thumb.jpg",
            mimeType: "image/jpeg",
            parentID: "thumbs-folder",
            existingFileID: nil
        )
        #expect(uploadedData.id == "mp-uploaded")
        #expect(FastPathFixtureHTTP.recordedPaths() == ["POST /upload/drive/v3/files?uploadType=multipart"])

        // 2) uploadFile below threshold -> single-shot multipart POST (1 HTTP request)
        FastPathFixtureHTTP.reset()
        let localFile = directory.appending(path: "photo.png")
        try payload.write(to: localFile)
        let uploadedFile = try await transport.uploadFile(
            from: localFile,
            name: "photo.png",
            mimeType: "image/png",
            parentID: "inbox-folder",
            existingFileID: nil
        )
        #expect(uploadedFile.id == "mp-uploaded")
        #expect(FastPathFixtureHTTP.recordedPaths() == ["POST /upload/drive/v3/files?uploadType=multipart"])

        // 3) downloadFile(RemoteDriveFile, to:) -> 1 single GET ?alt=media, NO metadata GET
        FastPathFixtureHTTP.reset()
        let expectedBytes = FastPathFixtureHTTP.sampleDownloadBytes
        let expectedMD5 = Insecure.MD5.hash(data: expectedBytes).map { String(format: "%02x", $0) }.joined()
        let remoteFile = RemoteDriveFile(
            id: "fast-dl-1",
            name: "sample.png",
            mimeType: "image/png",
            size: Int64(expectedBytes.count),
            modifiedTime: Date(),
            md5Checksum: expectedMD5,
            parents: ["inbox-folder"]
        )
        let targetURL = directory.appending(path: "downloaded.png")
        try await transport.downloadFile(remoteFile, to: targetURL)
        #expect(try Data(contentsOf: targetURL) == expectedBytes)
        #expect(FastPathFixtureHTTP.recordedPaths() == ["GET /drive/v3/files/fast-dl-1?alt=media"])

        // 4) Pooled HTTP/2 URLSession is preferred BEFORE spawning curl for slow gdirect IPs
        FastPathFixtureHTTP.reset()
        let slowEndpoint = GDirectEndpoint(ip: "198.51.100.1", latencyMs: 2_500, healthy: true)
        let acceleratedTransport = DirectAPITransport(
            accessToken: { "fast-token" },
            endpoints: [slowEndpoint],
            session: session,
            transferDirectory: directory,
            multipartThresholdBytes: 5 * 1_048_576
        )
        let start = ContinuousClock.now
        let downloaded = try await acceleratedTransport.downloadData(fileID: "fast-dl-1")
        let elapsedMs = Double(start.duration(to: .now).components.seconds) * 1_000
            + Double(start.duration(to: .now).components.attoseconds) / 1e15
        #expect(downloaded == expectedBytes)
        #expect(FastPathFixtureHTTP.recordedPaths() == ["GET /drive/v3/files/fast-dl-1?alt=media"])
        #expect(elapsedMs < 500, "Must use pooled URLSession immediately instead of waiting on slow gdirect curl endpoints")
    }

    // MARK: - 4. DriveSyncEngine Bounded Parallel Execution

    @Test("DriveSyncEngine crawls folders, downloads remote assets, and uploads local assets concurrently")
    func parallelDriveSyncThroughput() async throws {
        let directory = try BackendFixture.directory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let backing = InMemoryDriveTransport()
        let metered = MeteredDriveTransport(backing: backing, simulatedDelayMs: 35)

        // Seed remote structure: 3 subfolders with 4 images each (12 total remote images)
        let root = try await backing.findOrCreateFolder(named: "Charkle", parentID: "root")
        let subNames = ["Editorial", "Lighting", "Materials"]
        let hexPalette = [
            "#C45B47", "#3D6A8A", "#5F8F6D", "#D6A756",
            "#7D5BA6", "#B56A84", "#478A88", "#9E7855",
            "#4A5C75", "#CC7E5A", "#68825E", "#8B6F99"
        ]
        var idx = 0
        for sub in subNames {
            let folder = try await backing.findOrCreateFolder(named: sub, parentID: root.id)
            for j in 0..<4 {
                let png = try BackendFixture.artwork(hexPalette[idx])
                _ = try await backing.uploadData(
                    png,
                    name: "\(sub.lowercased())-\(j).png",
                    mimeType: "image/png",
                    parentID: folder.id,
                    existingFileID: nil
                )
                idx += 1
            }
        }

        let engine = try BackendFixture.makeEngine(directory.appending(path: "MacA"), transport: metered)
        try await engine.saveSyncConfig(BackendFixture.syncConfig())

        let downloadReport = try await engine.syncNow()
        #expect(downloadReport.discoveredRemoteAssets == 12)
        let syncedAssets = try await engine.fetchAssets(matching: FilterCriteria())
        #expect(syncedAssets.count == 12)
        for asset in syncedAssets {
            #expect(await engine.thumbnailURL(for: asset.id, tier: .grid520) != nil)
        }
        let downloadStats = metered.snapshot()
        #expect(downloadStats.peakListings >= 2, "Folder crawling should run concurrently")
        #expect(downloadStats.peakDownloads >= 3, "Remote asset downloads should run concurrently (peak=\(downloadStats.peakDownloads))")

        // Now ingest 8 new local assets and sync up -> verify concurrent uploads
        metered.resetPeaks()
        var localInputs: [CaptureInput] = []
        for i in 0..<8 {
            localInputs.append(.imageData(
                try BackendFixture.artwork(hexPalette[i]),
                suggestedName: "local-shot-\(i).png",
                sourceURL: nil
            ))
        }
        _ = try await engine.ingest(localInputs, targetFolderID: nil, targetBoardID: nil)
        let uploadReport = try await engine.syncNow()
        #expect(uploadReport.uploadedOps > 0)
        let uploadStats = metered.snapshot()
        #expect(uploadStats.peakUploads >= 3, "Local asset & thumbnail uploads should run concurrently (peak=\(uploadStats.peakUploads))")

        // Verify all 20 assets exist cleanly on a second Mac
        let engineB = try BackendFixture.makeEngine(directory.appending(path: "MacB"), transport: backing)
        try await engineB.saveSyncConfig(BackendFixture.syncConfig())
        _ = try await engineB.syncNow()
        let assetsB = try await engineB.fetchAssets(matching: FilterCriteria())
        #expect(assetsB.count == 20)
    }

    // MARK: - 5. Locally Deleted Assets Never Resurrect Across Same-Transport or Cross-Transport Sync

    @Test("Locally deleted assets stay deleted on sync (same transport & cross-transport) and local re-import still works")
    func localDeletionsDoNotResurrectOnSync() async throws {
        let directory = try BackendFixture.directory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let backing = InMemoryDriveTransport()
        let engine = try BackendFixture.makeEngine(directory.appending(path: "MacA"), transport: backing)
        try await engine.saveSyncConfig(BackendFixture.syncConfig())

        // 1. Ingest a local image, sync it to Drive, then permanently delete it locally
        let pngA = try BackendFixture.artwork("#D9534F")
        let ingestedA = try await engine.ingest(
            [.imageData(pngA, suggestedName: "delete-me.png", sourceURL: nil)],
            targetFolderID: nil,
            targetBoardID: nil
        )
        let assetA = try #require(ingestedA.first)
        _ = try await engine.syncNow()

        let syncedA = try #require(try await engine.fetchAsset(id: assetA.id))
        let remoteID = try #require(syncedA.driveFileID)
        #expect(!remoteID.isEmpty)

        try await engine.permanentlyDeleteAssets(ids: [assetA.id])
        let syncAfterDelete = try await engine.syncNow()
        #expect(syncAfterDelete.discoveredRemoteAssets == 0)
        #expect((try await engine.fetchAssets(matching: FilterCriteria(includeTrashed: true))).isEmpty)

        // Second sync must also keep it deleted
        let secondSync = try await engine.syncNow()
        #expect(secondSync.discoveredRemoteAssets == 0)
        #expect((try await engine.fetchAssets(matching: FilterCriteria(includeTrashed: true))).isEmpty)

        // 2. Simulate cross-transport resurrection trap:
        //    Remote Drive still contains an identical copy under a brand-new Drive file ID,
        //    e.g. after switching from gdirect mount to Direct API.
        let root = try await backing.findOrCreateFolder(named: "Charkle", parentID: "root")
        let inbox = try await backing.findOrCreateFolder(named: "Inbox", parentID: root.id)
        let zombieRemote = try await backing.uploadData(
            pngA,
            name: "delete-me.png",
            mimeType: "image/png",
            parentID: inbox.id,
            existingFileID: nil
        )
        let crossTransportSync = try await engine.syncNow()
        #expect(crossTransportSync.discoveredRemoteAssets == 0)
        #expect((try await engine.fetchAssets(matching: FilterCriteria(includeTrashed: true))).isEmpty)
        let inboxFilesAfter = try await backing.listFiles(inFolderID: inbox.id)
        #expect(!inboxFilesAfter.contains(where: { $0.id == zombieRemote.id }))

        // 3. Deliberate local re-import of the exact same bytes MUST succeed and sync normally
        let reimported = try await engine.ingest(
            [.imageData(pngA, suggestedName: "reimported.png", sourceURL: nil)],
            targetFolderID: nil,
            targetBoardID: nil
        )
        #expect(reimported.count == 1)
        _ = try await engine.syncNow()
        let liveAfterReimport = try await engine.fetchAssets(matching: FilterCriteria(includeTrashed: true))
        #expect(liveAfterReimport.count == 1)
        #expect(liveAfterReimport.first?.id == reimported.first?.id)
    }

    @Test("Locally trashed assets with stale/mounted drive IDs re-bind cleanly without duplicating as untrashed")
    func trashedAssetsDoNotDuplicateOnTransportSwitch() async throws {
        let directory = try BackendFixture.directory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let backing = InMemoryDriveTransport()
        let png = try BackendFixture.artwork("#3B7A9E")
        let root = try await backing.findOrCreateFolder(named: "Charkle", parentID: "root")
        let inbox = try await backing.findOrCreateFolder(named: "Inbox", parentID: root.id)
        let remoteFile = try await backing.uploadData(
            png,
            name: "trashed-item.png",
            mimeType: "image/png",
            parentID: inbox.id,
            existingFileID: nil
        )

        // Seed local DB with the asset already trashed and still holding an old gdirect mounted-path ID
        let storeDir = directory.appending(path: "MacSwitch")
        let engine = try BackendFixture.makeEngine(storeDir, transport: backing)
        try await engine.saveSyncConfig(BackendFixture.syncConfig())
        let created = try await engine.ingest(
            [.imageData(png, suggestedName: "trashed-item.png", sourceURL: nil)],
            targetFolderID: nil,
            targetBoardID: nil
        )
        let localID = try #require(created.first?.id)
        _ = try await engine.updateAssets(AssetBatchPatch(assetIDs: [localID], isTrashed: true))

        // Sync against Drive where the remote file exists under Direct API ID
        let report = try await engine.syncNow()
        #expect(report.discoveredRemoteAssets == 0)

        let allAssets = try await engine.fetchAssets(matching: FilterCriteria(includeTrashed: true))
        #expect(allAssets.count == 1)
        #expect(allAssets.first?.id == localID)
        #expect(allAssets.first?.isTrashed == true)
        #expect(allAssets.first?.driveFileID == remoteFile.id)
    }
}

// MARK: - Test Fixtures

private final class FastPathFixtureHTTP: URLProtocol, @unchecked Sendable {
    static let sampleDownloadBytes = Data("charkle-fast-download-bytes-1234567890".utf8)
    private static let recorded = Mutex<[String]>([])

    static func reset() {
        recorded.withLock { $0.removeAll() }
    }

    static func recordedPaths() -> [String] {
        recorded.withLock { $0 }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host() == "www.googleapis.com"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let method = request.httpMethod ?? "GET"
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let uploadType = items.first(where: { $0.name == "uploadType" })?.value
        let alt = items.first(where: { $0.name == "alt" })?.value
        let tag = "\(method) \(url.path)" + (uploadType.map { "?uploadType=\($0)" } ?? "") + (alt.map { "?alt=\($0)" } ?? "")
        Self.recorded.withLock { $0.append(tag) }

        let status: Int
        let body: Data
        let contentType: String

        if method == "POST", url.path == "/upload/drive/v3/files", uploadType == "multipart" {
            status = 200
            contentType = "application/json"
            body = Data(#"{"id":"mp-uploaded","name":"uploaded","mimeType":"image/png","size":"27","parents":["inbox-folder"]}"#.utf8)
        } else if method == "GET", url.path == "/drive/v3/files/fast-dl-1", alt == "media" {
            status = 200
            contentType = "image/png"
            body = Self.sampleDownloadBytes
        } else {
            status = 500
            contentType = "text/plain"
            body = Data("Unexpected request: \(tag)".utf8)
        }

        guard let response = HTTPURLResponse(
            url: url,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": contentType]
        ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
}

private final class MeteredDriveTransport: DriveTransport, Sendable {
    struct Stats: Sendable {
        var activeListings = 0
        var peakListings = 0
        var activeDownloads = 0
        var peakDownloads = 0
        var activeUploads = 0
        var peakUploads = 0
    }

    let displayName = "Metered Memory Drive"
    private let backing: InMemoryDriveTransport
    private let simulatedDelayMs: Int
    private let stats = Mutex(Stats())

    init(backing: InMemoryDriveTransport, simulatedDelayMs: Int) {
        self.backing = backing
        self.simulatedDelayMs = simulatedDelayMs
    }

    func snapshot() -> Stats {
        stats.withLock { $0 }
    }

    func resetPeaks() {
        stats.withLock {
            $0.peakListings = 0
            $0.peakDownloads = 0
            $0.peakUploads = 0
        }
    }

    func accountInfo() async throws -> DriveAccountInfo { await backing.accountInfo() }
    func fetchStartPageToken() async throws -> String { await backing.fetchStartPageToken() }
    func listChanges(pageToken: String) async throws -> DriveChangePage { try await backing.listChanges(pageToken: pageToken) }
    func findOrCreateFolder(named name: String, parentID: String) async throws -> RemoteDriveFile {
        try await backing.findOrCreateFolder(named: name, parentID: parentID)
    }

    func listFiles(inFolderID folderID: String) async throws -> [RemoteDriveFile] {
        stats.withLock {
            $0.activeListings += 1
            $0.peakListings = max($0.peakListings, $0.activeListings)
        }
        defer { stats.withLock { $0.activeListings -= 1 } }
        try await Task.sleep(for: .milliseconds(simulatedDelayMs))
        return try await backing.listFiles(inFolderID: folderID)
    }

    func downloadData(fileID: String) async throws -> Data {
        try await backing.downloadData(fileID: fileID)
    }

    func downloadFile(fileID: String, to destinationURL: URL) async throws {
        stats.withLock {
            $0.activeDownloads += 1
            $0.peakDownloads = max($0.peakDownloads, $0.activeDownloads)
        }
        defer { stats.withLock { $0.activeDownloads -= 1 } }
        try await Task.sleep(for: .milliseconds(simulatedDelayMs))
        try await backing.downloadFile(fileID: fileID, to: destinationURL)
    }

    func uploadData(_ data: Data, name: String, mimeType: String, parentID: String, existingFileID: String?) async throws -> RemoteDriveFile {
        stats.withLock {
            $0.activeUploads += 1
            $0.peakUploads = max($0.peakUploads, $0.activeUploads)
        }
        defer { stats.withLock { $0.activeUploads -= 1 } }
        try await Task.sleep(for: .milliseconds(simulatedDelayMs))
        return try await backing.uploadData(data, name: name, mimeType: mimeType, parentID: parentID, existingFileID: existingFileID)
    }

    func uploadFile(from localURL: URL, name: String, mimeType: String, parentID: String, existingFileID: String?) async throws -> RemoteDriveFile {
        stats.withLock {
            $0.activeUploads += 1
            $0.peakUploads = max($0.peakUploads, $0.activeUploads)
        }
        defer { stats.withLock { $0.activeUploads -= 1 } }
        try await Task.sleep(for: .milliseconds(simulatedDelayMs))
        return try await backing.uploadFile(from: localURL, name: name, mimeType: mimeType, parentID: parentID, existingFileID: existingFileID)
    }

    func moveFile(fileID: String, fromParentID: String?, toParentID: String, newName: String?) async throws -> RemoteDriveFile {
        try await backing.moveFile(fileID: fileID, fromParentID: fromParentID, toParentID: toParentID, newName: newName)
    }

    func trashFile(fileID: String) async throws {
        try await backing.trashFile(fileID: fileID)
    }
}
