import CharkleCanvas
import Foundation
import Synchronization
import Testing
@testable import CharkleCore

@Suite("Fast Initial Google Drive Sync (Metadata & Thumbnails First)")
struct FastInitialSyncTests {

    private final class LatencySpyTransport: DriveTransport, @unchecked Sendable {
        enum Event: Sendable, Equatable {
            case opShard(String)
            case thumbnail(UUID)
            case thumbnailLink(String)
            case original(String)
        }

        struct Metrics: Sendable {
            var events: [Event] = []
            var fileNamesByID: [String: String] = [:]
            var inFlightDataDownloads: Int = 0
            var peakConcurrentDataDownloads: Int = 0
            var thumbnailDownloadOrder: [UUID] = []
            var originalDownloadCount: Int = 0
            var thumbnailLinkFetchCount: Int = 0
        }

        let displayName = "Google Drive API v3 (Spy)"
        private let inner: InMemoryDriveTransport
        private let state = Mutex(Metrics())
        private let injectThumbnailLinks: Bool
        private let fakeThumbnailData: Data?
        private let downloadDelay: Duration

        init(
            inner: InMemoryDriveTransport,
            injectThumbnailLinks: Bool = false,
            fakeThumbnailData: Data? = nil,
            downloadDelay: Duration = .milliseconds(8)
        ) {
            self.inner = inner
            self.injectThumbnailLinks = injectThumbnailLinks
            self.fakeThumbnailData = fakeThumbnailData
            self.downloadDelay = downloadDelay
        }

        var metrics: Metrics {
            state.withLock { $0 }
        }

        func accountInfo() async throws -> DriveAccountInfo {
            await inner.accountInfo()
        }

        func fetchStartPageToken() async throws -> String {
            await inner.fetchStartPageToken()
        }

        func listChanges(pageToken: String) async throws -> DriveChangePage {
            try await inner.listChanges(pageToken: pageToken)
        }

        func findOrCreateFolder(named name: String, parentID: String) async throws -> RemoteDriveFile {
            try await inner.findOrCreateFolder(named: name, parentID: parentID)
        }

        func listFiles(inFolderID folderID: String) async throws -> [RemoteDriveFile] {
            let files = try await inner.listFiles(inFolderID: folderID)
            state.withLock { s in
                for file in files {
                    s.fileNamesByID[file.id] = file.name
                }
            }
            guard injectThumbnailLinks else { return files }
            return files.map { file in
                guard !file.isFolder, !file.name.hasPrefix(".") else { return file }
                return RemoteDriveFile(
                    id: file.id,
                    name: file.name,
                    mimeType: file.mimeType,
                    size: file.size,
                    modifiedTime: file.modifiedTime,
                    md5Checksum: file.md5Checksum,
                    parents: file.parents,
                    trashed: file.trashed,
                    webViewLink: file.webViewLink,
                    thumbnailLink: "https://lh3.googleusercontent.com/drive-storage/fake-\(file.id)=s220"
                )
            }
        }

        func downloadData(fileID: String) async throws -> Data {
            state.withLock { s in
                s.inFlightDataDownloads += 1
                if s.inFlightDataDownloads > s.peakConcurrentDataDownloads {
                    s.peakConcurrentDataDownloads = s.inFlightDataDownloads
                }
            }
            defer {
                state.withLock { $0.inFlightDataDownloads -= 1 }
            }
            if downloadDelay > .zero {
                try? await Task.sleep(for: downloadDelay)
            }
            let data = try await inner.downloadData(fileID: fileID)
            state.withLock { s in
                if let fileName = s.fileNamesByID[fileID] {
                    if fileName.hasPrefix("ops-") && fileName.hasSuffix(".jsonl") {
                        s.events.append(.opShard(fileName))
                    } else if fileName.hasSuffix(".jpg"),
                              let uuid = UUID(uuidString: String(fileName.dropLast(4))) {
                        s.events.append(.thumbnail(uuid))
                        s.thumbnailDownloadOrder.append(uuid)
                    }
                }
            }
            return data
        }

        func downloadFile(fileID: String, to destinationURL: URL) async throws {
            if downloadDelay > .zero {
                try? await Task.sleep(for: downloadDelay)
            }
            state.withLock { s in
                s.originalDownloadCount += 1
                s.events.append(.original(fileID))
            }
            try await inner.downloadFile(fileID: fileID, to: destinationURL)
        }

        func downloadThumbnailData(for file: RemoteDriveFile, maxPixelSize: Int) async throws -> Data? {
            guard injectThumbnailLinks, file.thumbnailLink != nil, let fakeThumbnailData else { return nil }
            state.withLock { s in
                s.thumbnailLinkFetchCount += 1
                s.events.append(.thumbnailLink(file.id))
            }
            return fakeThumbnailData
        }

        func uploadData(_ data: Data, name: String, mimeType: String, parentID: String, existingFileID: String?) async throws -> RemoteDriveFile {
            try await inner.uploadData(data, name: name, mimeType: mimeType, parentID: parentID, existingFileID: existingFileID)
        }

        func uploadFile(from localURL: URL, name: String, mimeType: String, parentID: String, existingFileID: String?) async throws -> RemoteDriveFile {
            try await inner.uploadFile(from: localURL, name: name, mimeType: mimeType, parentID: parentID, existingFileID: existingFileID)
        }

        func moveFile(fileID: String, fromParentID: String?, toParentID: String, newName: String?) async throws -> RemoteDriveFile {
            try await inner.moveFile(fileID: fileID, fromParentID: fromParentID, toParentID: toParentID, newName: newName)
        }

        func trashFile(fileID: String) async throws {
            try await inner.trashFile(fileID: fileID)
        }
    }

    @Test("Fresh install downloads ops & thumbnails in parallel, prioritizes newest thumbnails first, and emits progressive UI updates before pinned originals")
    func freshInstallMetadataAndThumbnailsFirst() async throws {
        let dir = try BackendFixture.directory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let backing = InMemoryDriveTransport()
        let deviceA = try BackendFixture.makeEngine(dir.appending(path: "DeviceA"), transport: backing)
        try await deviceA.saveSyncConfig(BackendFixture.syncConfig())

        let folder1 = try await deviceA.createFolder(name: "Architecture", parentID: nil)
        let folder2 = try await deviceA.createFolder(name: "Editorial", parentID: folder1.id)

        // Create 3 separate sync batches so Device A publishes multiple immutable ops-*.jsonl shards
        // AND assets have strictly ascending creation timestamps.
        var createdIDsInChronologicalOrder: [UUID] = []
        let hexPalette = ["#A65A46", "#3E6B89", "#5C8A67", "#C69B4B", "#7A5F4B", "#35536B"]
        for batch in 0..<3 {
            var batchInputs: [CaptureInput] = []
            for idx in 0..<8 {
                let globalIdx = batch * 8 + idx
                let hex = hexPalette[globalIdx % hexPalette.count]
                batchInputs.append(.colorSwatch(hex: hex, title: String(format: "Item-%02d", globalIdx)))
            }
            let targetFolder = batch == 0 ? folder1.id : (batch == 1 ? folder2.id : nil)
            let created = try await deviceA.ingest(batchInputs, targetFolderID: targetFolder, targetBoardID: nil)
            createdIDsInChronologicalOrder.append(contentsOf: created.map(\.id))
            if batch == 0, let first = created.first {
                _ = try await deviceA.updateAssets(AssetBatchPatch(assetIDs: [first.id], pinnedOffline: true))
            }
            _ = try await deviceA.syncNow()
            try await Task.sleep(for: .milliseconds(15))
        }

        // Also create a Moodboard on Device A and sync once more (4th shard)
        let allOnA = try await deviceA.fetchAssets(matching: FilterCriteria())
        let board = try await deviceA.saveBoard(
            MoodboardDocument(title: "Hydration Board", nodes: MoodboardCurator.editorialNodes(Array(allOnA.prefix(4))))
        )
        _ = try await deviceA.syncNow()

        // Fresh install (Device B) with latency spy transport
        let spy = LatencySpyTransport(inner: backing, downloadDelay: .milliseconds(12))
        let deviceB = try BackendFixture.makeEngine(dir.appending(path: "DeviceB"), transport: spy)
        try await deviceB.saveSyncConfig(BackendFixture.syncConfig())

        let progressiveKinds = Mutex<[String]>([])
        let progressiveThumbnailBatches = Mutex<[[UUID]]>([])
        let originalCountAtFirstMetadata = Mutex<Int?>(nil)
        let originalCountAtFirstThumbnailBatch = Mutex<Int?>(nil)

        let observer = NotificationCenter.default.addObserver(
            forName: CharkleSyncNotifications.didSyncProgressively,
            object: nil,
            queue: nil
        ) { note in
            let kind = note.userInfo?[CharkleSyncNotifications.progressKindKey] as? String ?? ""
            let thumbIDs = note.userInfo?[CharkleSyncNotifications.thumbnailAssetIDsKey] as? [UUID] ?? []
            progressiveKinds.withLock { $0.append(kind) }
            if kind == CharkleSyncNotifications.progressKindMetadata {
                originalCountAtFirstMetadata.withLock {
                    if $0 == nil { $0 = spy.metrics.originalDownloadCount }
                }
            } else if kind == CharkleSyncNotifications.progressKindThumbnails {
                progressiveThumbnailBatches.withLock { $0.append(thumbIDs) }
                originalCountAtFirstThumbnailBatch.withLock {
                    if $0 == nil { $0 = spy.metrics.originalDownloadCount }
                }
            }
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        let report = try await deviceB.syncNow()
        let metrics = spy.metrics

        // 1. Metadata, folders, boards, and ALL 24 thumbnails hydrated cleanly
        let assetsB = try await deviceB.fetchAssets(matching: FilterCriteria())
        #expect(assetsB.count == 24)
        #expect(try await deviceB.fetchFolders().count == 2)
        #expect(try await deviceB.fetchBoard(id: board.id)?.title == "Hydration Board")
        #expect(report.downloadedOps > 0)
        for asset in assetsB {
            #expect(await deviceB.thumbnailURL(for: asset.id, tier: .grid520) != nil)
        }

        // 2. Parallel ops & thumbnail downloads achieved true concurrency (> 1 in-flight)
        #expect(metrics.peakConcurrentDataDownloads >= 2)

        // 3. Only the 1 pinned asset downloaded its full-res original; the other 23 skipped originals completely!
        #expect(metrics.originalDownloadCount == 1)

        // 4. Progressive UI notifications fired for BOTH metadata and thumbnails BEFORE the pinned original downloaded!
        let kinds = progressiveKinds.withLock { $0 }
        #expect(kinds.contains(CharkleSyncNotifications.progressKindMetadata))
        #expect(kinds.contains(CharkleSyncNotifications.progressKindThumbnails))
        #expect(originalCountAtFirstMetadata.withLock { $0 } == 0)
        #expect(originalCountAtFirstThumbnailBatch.withLock { $0 } == 0)
        let totalNotifiedThumbnails = progressiveThumbnailBatches.withLock { $0.reduce(0) { $0 + $1.count } }
        #expect(totalNotifiedThumbnails == 24)

        // 5. Strict stage order: ALL remote thumbnails finished downloading BEFORE the pinned original started!
        let lastThumbEventIndex = metrics.events.lastIndex {
            if case .thumbnail = $0 { return true }
            return false
        }
        let firstOriginalEventIndex = metrics.events.firstIndex {
            if case .original = $0 { return true }
            return false
        }
        #expect(lastThumbEventIndex != nil)
        #expect(firstOriginalEventIndex != nil)
        if let lastThumb = lastThumbEventIndex, let firstOrig = firstOriginalEventIndex {
            #expect(lastThumb < firstOrig)
        }

        // 6. Newest-first priority: the newest batch of assets started downloading ahead of the oldest batch
        let newestSet = Set(createdIDsInChronologicalOrder.suffix(8))
        let first12Downloaded = metrics.thumbnailDownloadOrder.prefix(12)
        let newestHitsInFirst12 = first12Downloaded.filter { newestSet.contains($0) }.count
        #expect(newestHitsInFirst12 >= 6)
    }

    @Test("Already-synced assets missing .charkle/thumbnails fall back to fast Drive thumbnailLink instead of downloading originals")
    func thumbnailLinkFastFallbackSkipsOriginals() async throws {
        let dir = try BackendFixture.directory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let backing = InMemoryDriveTransport()
        let deviceA = try BackendFixture.makeEngine(dir.appending(path: "DeviceA"), transport: backing)
        var noThumbConfig = BackendFixture.syncConfig()
        noThumbConfig.syncThumbnails = false
        try await deviceA.saveSyncConfig(noThumbConfig)

        let created = try await deviceA.ingest(
            [
                .imageData(try BackendFixture.artwork("#B86B4B"), suggestedName: "poster-a.png", sourceURL: nil),
                .imageData(try BackendFixture.artwork("#3D6E70"), suggestedName: "poster-b.png", sourceURL: nil)
            ],
            targetFolderID: nil,
            targetBoardID: nil
        )
        #expect(created.count == 2)
        _ = try await deviceA.syncNow()

        let spy = LatencySpyTransport(
            inner: backing,
            injectThumbnailLinks: true,
            fakeThumbnailData: try BackendFixture.artwork("#4D7EA8"),
            downloadDelay: .zero
        )
        let deviceB = try BackendFixture.makeEngine(dir.appending(path: "DeviceB"), transport: spy)
        try await deviceB.saveSyncConfig(BackendFixture.syncConfig())

        _ = try await deviceB.syncNow()
        let metrics = spy.metrics

        #expect(metrics.thumbnailLinkFetchCount == 2)
        #expect(metrics.originalDownloadCount == 0)
        for asset in created {
            #expect(await deviceB.thumbnailURL(for: asset.id, tier: .grid520) != nil)
        }
    }

    @Test("DirectAPITransport.scaledThumbnailURL upgrades Google thumbnail links safely and RemoteDriveFile ignores transient thumbnailLink in equality/coding")
    func scaledThumbnailURLAndTransientFieldContracts() throws {
        let upgraded = DirectAPITransport.scaledThumbnailURL(
            from: "https://lh3.googleusercontent.com/drive-storage/abc123=s220",
            maxPixelSize: 640
        )
        #expect(upgraded?.absoluteString == "https://lh3.googleusercontent.com/drive-storage/abc123=s640")

        let withQuery = DirectAPITransport.scaledThumbnailURL(
            from: "https://lh3.googleusercontent.com/drive-storage/abc123=s220?authuser=0",
            maxPixelSize: 520
        )
        #expect(withQuery?.absoluteString == "https://lh3.googleusercontent.com/drive-storage/abc123=s520?authuser=0")

        // Reject non-HTTPS and non-Google hosts
        #expect(DirectAPITransport.scaledThumbnailURL(from: "http://lh3.googleusercontent.com/a=s220") == nil)
        #expect(DirectAPITransport.scaledThumbnailURL(from: "https://evil.example.com/a=s220") == nil)

        // Rotating thumbnailLink tokens must never cause SavedInventory diffs or re-reconcile storms
        let fileA = RemoteDriveFile(
            id: "drive-1",
            name: "photo.jpg",
            mimeType: "image/jpeg",
            size: 1024,
            md5Checksum: "abc",
            parents: ["root"],
            thumbnailLink: "https://lh3.googleusercontent.com/token-1=s220"
        )
        let fileB = RemoteDriveFile(
            id: "drive-1",
            name: "photo.jpg",
            mimeType: "image/jpeg",
            size: 1024,
            md5Checksum: "abc",
            parents: ["root"],
            thumbnailLink: "https://lh3.googleusercontent.com/token-2=s220"
        )
        #expect(fileA == fileB)
        #expect(fileA.hashValue == fileB.hashValue)
        let encoded = try JSONEncoder().encode(fileA)
        let decoded = try JSONDecoder().decode(RemoteDriveFile.self, from: encoded)
        #expect(decoded == fileA)
        #expect(decoded.thumbnailLink == nil)
    }

    @Test("ThumbnailImageLoader.invalidate(assetIDs:) increments invalidationVersion once per batch and ignores empty batches")
    @MainActor
    func batchThumbnailInvalidationIncrementsOnce() {
        let loader = ThumbnailImageLoader(engine: PlaceholderCharkleEngine())
        let initial = loader.invalidationVersion
        loader.invalidate(assetIDs: [])
        #expect(loader.invalidationVersion == initial)

        loader.invalidate(assetIDs: [UUID(), UUID(), UUID()])
        #expect(loader.invalidationVersion == initial + 1)
    }
}
