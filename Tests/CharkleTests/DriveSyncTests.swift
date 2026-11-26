import Foundation
import Testing
@testable import CharkleCore

@Suite("Drive sync")
struct DriveSyncTests {
    @Test("Two Macs preserve concurrent tag adds, field edits, and tag tombstones")
    func concurrentTags() async throws {
        let pair = try await Pair.make()
        defer { pair.cleanup() }
        let asset = try #require(try await pair.a.ingest([.colorSwatch(hex: "#AC553D", title: "Glaze")],
                                                       targetFolderID: nil, targetBoardID: nil).first)
        _ = try await pair.a.updateAssets(AssetBatchPatch(assetIDs: [asset.id], addTags: ["old", "ceramic"]))
        _ = try await pair.a.syncNow()
        _ = try await pair.b.syncNow()
        #expect(try await pair.b.fetchAsset(id: asset.id)?.tags == ["ceramic", "old"])

        async let editA = pair.a.updateAssets(AssetBatchPatch(assetIDs: [asset.id], title: "Rust Glaze", addTags: ["warm"], removeTags: ["old"]))
        async let editB = pair.b.updateAssets(AssetBatchPatch(assetIDs: [asset.id], notes: "Wheel-thrown", addTags: ["matte"]))
        _ = try await (editA, editB)
        async let syncA = pair.a.syncNow()
        async let syncB = pair.b.syncNow()
        _ = try await (syncA, syncB)
        _ = try await pair.a.syncNow()
        _ = try await pair.b.syncNow()
        for engine in [pair.a, pair.b] {
            let merged = try #require(try await engine.fetchAsset(id: asset.id))
            #expect(merged.tags == ["ceramic", "matte", "warm"])
            #expect(merged.title == "Rust Glaze")
            #expect(merged.notes == "Wheel-thrown")
            #expect(merged.driveFileID != nil)
        }
        #expect(try await pair.a.syncNow().uploadedOps == 0)
    }

    @Test("Per-board files and independent edits to nodes and connectors converge")
    func boardsConverge() async throws {
        let pair = try await Pair.make()
        defer { pair.cleanup() }
        let two = try await pair.a.ingest([.colorSwatch(hex: "#9C864D", title: "Brass"),
                                           .colorSwatch(hex: "#426066", title: "Lichen")],
                                          targetFolderID: nil, targetBoardID: nil)
        let board = try await pair.a.saveBoard(MoodboardDocument(title: "Materials", nodes: MoodboardCurator.editorialNodes(two)))
        let other = try await pair.a.saveBoard(MoodboardDocument(title: "Light"))
        _ = try await pair.a.syncNow()
        _ = try await pair.b.syncNow()

        var a = try #require(try await pair.a.fetchBoard(id: board.id))
        var b = try #require(try await pair.b.fetchBoard(id: board.id))
        a.nodes[0].frame.x += 123
        b.nodes[1].frame.y += 77
        b.connectors.append(BoardConnector(fromNodeID: b.nodes[0].id, toNodeID: b.nodes[1].id, label: "Patina"))
        var otherA = try #require(try await pair.a.fetchBoard(id: other.id))
        otherA.title = "North light"
        _ = try await pair.a.saveBoard(a)
        _ = try await pair.a.saveBoard(otherA)
        _ = try await pair.b.saveBoard(b)

        _ = try await pair.a.syncNow()
        _ = try await pair.b.syncNow()
        _ = try await pair.a.syncNow()
        let aMerged = try #require(try await pair.a.fetchBoard(id: board.id))
        let bMerged = try #require(try await pair.b.fetchBoard(id: board.id))
        #expect(aMerged == bMerged)
        #expect(aMerged.nodes[0].frame.x == a.nodes[0].frame.x)
        #expect(aMerged.nodes[1].frame.y == b.nodes[1].frame.y)
        #expect(aMerged.connectors.first?.label == "Patina")
        #expect(try await pair.b.fetchBoard(id: other.id)?.title == "North light")

        let layout = try await pair.folders()
        let files = try await pair.transport.listFiles(inFolderID: layout.boards.id)
        #expect(Set(files.map(\.name)) == [board.id.uuidString.lowercased() + ".json", other.id.uuidString.lowercased() + ".json"])
        let remote = try #require(files.first { $0.name.hasPrefix(board.id.uuidString.lowercased()) })
        let serialized = try await pair.transport.downloadData(fileID: remote.id)
        #expect(try JSONDecoder().decode(MoodboardDocument.self, from: serialized) == aMerged)
    }

    @Test("A web-side rename and move preserve asset identity, and a newly dropped file is indexed")
    func browserEdits() async throws {
        let pair = try await Pair.make()
        defer { pair.cleanup() }
        let asset = try #require(try await pair.a.ingest([.colorSwatch(hex: "#A45A48", title: "Original")],
                                                       targetFolderID: nil, targetBoardID: nil).first)
        let board = try await pair.a.saveBoard(MoodboardDocument(title: "Board", nodes: MoodboardCurator.editorialNodes([asset])))
        _ = try await pair.a.syncNow()
        _ = try await pair.a.syncNow()
        _ = try await pair.b.syncNow()
        let fileID = try #require(try await pair.a.fetchAsset(id: asset.id)?.driveFileID)
        let layout = try await pair.folders()
        let nested = try await pair.transport.findOrCreateFolder(named: "庭院", parentID: layout.root.id)
        _ = try await pair.transport.moveFile(fileID: fileID, fromParentID: layout.inbox.id, toParentID: nested.id, newName: "Garden.png")
        let dropped = try await pair.transport.uploadData(BackendFixture.artwork("#377754"), name: "Fern.png",
                                                         mimeType: "image/png", parentID: layout.root.id, existingFileID: nil)
        let report = try await pair.a.syncNow()
        #expect(report.discoveredRemoteAssets == 1)
        #expect(report.reconciledRenames == 1)
        _ = try await pair.b.syncNow()
        _ = try await pair.a.syncNow()
        for engine in [pair.a, pair.b] {
            let renamed = try #require(try await engine.fetchAsset(id: asset.id))
            #expect(renamed.driveFileID == fileID)
            #expect(renamed.fileName == "Garden.png")
            let folders = try await engine.fetchFolders()
            #expect(folders.first { $0.id == renamed.folderID }?.name == "庭院")
            #expect(try await engine.fetchBoard(id: board.id)?.referencedAssetIDs == [asset.id])
            let matches = try await engine.fetchAssets(matching: FilterCriteria(searchQuery: "fern"))
            let discovered = try #require(matches.first)
            #expect(discovered.driveFileID == dropped.id)
            #expect(await engine.thumbnailURL(for: discovered.id, tier: .grid520) != nil)
        }
        let rootFiles = try await pair.transport.listFiles(inFolderID: layout.root.id)
        #expect(rootFiles.contains { $0.id == dropped.id })
    }

    @Test("A preexisting cursor sees new folders and paginated changes without replaying published edits")
    func tokensAndFileRemoval() async throws {
        let pair = try await Pair.make()
        defer { pair.cleanup() }
        _ = try await pair.a.syncNow()
        let layout = try await pair.folders()
        let folder = try await pair.transport.findOrCreateFolder(named: "New", parentID: layout.root.id)
        let file = try await pair.transport.uploadData(Data("page token".utf8), name: "Notes.md", mimeType: "text/markdown",
                                                       parentID: folder.id, existingFileID: nil)
        let report = try await pair.a.syncNow()
        #expect(report.discoveredRemoteAssets == 1)
        let fetched = try #require(try await pair.a.fetchAssets(matching: FilterCriteria(searchQuery: "page token")).first)
        try await pair.transport.trashFile(fileID: file.id)
        _ = try await pair.a.syncNow()
        #expect(try await pair.a.fetchAsset(id: fetched.id)?.isTrashed == true)
        #expect(try await pair.a.fetchAssets(matching: FilterCriteria(onlyTrashed: true)).count == 1)
    }

    @Test("Enabled feature and semantic vectors replicate through device ops and binary shards")
    func embeddingShards() async throws {
        let pair = try await Pair.make()
        defer { pair.cleanup() }
        var config = BackendFixture.syncConfig()
        config.syncEmbeddings = true
        try await pair.a.saveSyncConfig(config)
        try await pair.b.saveSyncConfig(config)
        let imported = try #require(try await pair.a.ingest([.colorSwatch(hex: "#195C81", title: "Blue")],
                                                          targetFolderID: nil, targetBoardID: nil).first)
        try await pair.a.database.transaction { db in
            try db.record(.vector(imported.id, AssetVector(embedding: [0.25, -0.5, 1], embeddingModel: "testing")))
        }
        _ = try await pair.a.syncNow()
        _ = try await pair.b.syncNow()
        let vector = try #require(try await pair.b.database.vector(for: imported.id))
        #expect(vector.embedding == [0.25, -0.5, 1])
        #expect(vector.featurePrint != nil)
        let metadata = try await pair.folders().metadata
        let directories = try await pair.transport.listFiles(inFolderID: metadata.id)
        let embeddings = try #require(directories.first { $0.name == "embeddings" })
        let shards = try await pair.transport.listFiles(inFolderID: embeddings.id)
        #expect(shards.map(\.name) == ["shard-\(imported.id.uuidString.prefix(2).lowercased()).bin"])
        let blob = try await pair.transport.downloadData(fileID: #require(shards.first).id)
        #expect(blob.starts(with: Data("bplist00".utf8)))
    }

    @Test("Direct drops into Google Drive root, Inbox, and subfolders ingest cleanly while ignoring temp/junk and deferring 0-byte uploads")
    func directDropFilteringAndResilience() async throws {
        let pair = try await Pair.make()
        defer { pair.cleanup() }
        let dirs = try await pair.folders()
        let lookbook = try await pair.transport.findOrCreateFolder(named: "Lookbook", parentID: dirs.root.id)

        let pngA = try BackendFixture.artwork("#CD7854")
        let pngB = try BackendFixture.artwork("#3E709E")
        let pngC = try BackendFixture.artwork("#5F986C")

        _ = try await pair.transport.uploadData(pngA, name: "root-drop.png", mimeType: "image/png", parentID: dirs.root.id, existingFileID: nil)
        _ = try await pair.transport.uploadData(pngB, name: "inbox-drop.png", mimeType: "image/png", parentID: dirs.inbox.id, existingFileID: nil)
        _ = try await pair.transport.uploadData(pngC, name: "shoot.png", mimeType: "image/png", parentID: lookbook.id, existingFileID: nil)
        // Noise files that should be ignored or deferred without aborting sync
        _ = try await pair.transport.uploadData(Data("junk".utf8), name: "Thumbs.db", mimeType: "application/octet-stream", parentID: dirs.inbox.id, existingFileID: nil)
        _ = try await pair.transport.uploadData(Data("partial".utf8), name: "uploading.png.crdownload", mimeType: "application/octet-stream", parentID: dirs.inbox.id, existingFileID: nil)
        _ = try await pair.transport.uploadData(Data(), name: "Survey", mimeType: "application/vnd.google-apps.form", parentID: dirs.root.id, existingFileID: nil)
        let emptyUpload = try await pair.transport.uploadData(Data(), name: "late-finish.png", mimeType: "image/png", parentID: dirs.inbox.id, existingFileID: nil)

        let report1 = try await pair.a.syncNow()
        #expect(report1.discoveredRemoteAssets == 3)
        #expect(report1.discoveredAssetIDs.count == 3)

        let allAssets = try await pair.a.fetchAssets(matching: FilterCriteria())
        let names = Set(allAssets.map(\.fileName))
        #expect(names == ["root-drop.png", "inbox-drop.png", "shoot.png"])
        let folders = try await pair.a.fetchFolders()
        let lookbookFolder = try #require(folders.first { $0.name == "Lookbook" })
        #expect(allAssets.first { $0.fileName == "shoot.png" }?.folderID == lookbookFolder.id)
        #expect(allAssets.first { $0.fileName == "root-drop.png" }?.folderID == nil)
        for asset in allAssets {
            #expect(await pair.a.thumbnailURL(for: asset.id, tier: .grid520) != nil)
        }

        // Once the 0-byte upload finishes receiving bytes, the next sync automatically picks it up
        let pngD = try BackendFixture.artwork("#E6C470")
        _ = try await pair.transport.uploadData(pngD, name: "late-finish.png", mimeType: "image/png", parentID: dirs.inbox.id, existingFileID: emptyUpload.id)
        let report2 = try await pair.a.syncNow()
        #expect(report2.discoveredRemoteAssets == 1)
        let updatedNames = Set(try await pair.a.fetchAssets(matching: FilterCriteria()).map(\.fileName))
        #expect(updatedNames.contains("late-finish.png"))
    }

    @Test("Shared Google Drive folder URL/ID enables multi-user collaborative read/write sync")
    func sharedCollaborativeFolderCoEditing() async throws {
        #expect(DriveSyncConfig.extractGoogleDriveFolderID(from: "https://drive.google.com/drive/folders/1AbCdEfGhIjKlMnOpQrStUvWx?usp=sharing") == "1AbCdEfGhIjKlMnOpQrStUvWx")
        #expect(DriveSyncConfig.extractGoogleDriveFolderID(from: "https://drive.google.com/drive/u/0/folders/1AbCdEfGhIjKlMnOpQrStUvWx") == "1AbCdEfGhIjKlMnOpQrStUvWx")
        #expect(DriveSyncConfig.extractGoogleDriveFolderID(from: "https://drive.google.com/open?id=1AbCdEfGhIjKlMnOpQrStUvWx") == "1AbCdEfGhIjKlMnOpQrStUvWx")
        #expect(DriveSyncConfig.extractGoogleDriveFolderID(from: "1AbCdEfGhIjKlMnOpQrStUvWx") == "1AbCdEfGhIjKlMnOpQrStUvWx")
        #expect(DriveSyncConfig.extractGoogleDriveFolderID(from: "not a valid folder") == nil)

        let directory = try BackendFixture.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let transport = InMemoryDriveTransport()
        let sharedFolder = try await transport.findOrCreateFolder(named: "TeamStudioShared", parentID: "root")

        let sharedURL = "https://drive.google.com/drive/folders/\(sharedFolder.id)?usp=sharing"
        var config = BackendFixture.syncConfig()
        config.sharedFolderURLOrID = sharedURL

        let userA = try BackendFixture.makeEngine(directory.appending(path: "UserA"), transport: transport)
        let userB = try BackendFixture.makeEngine(directory.appending(path: "UserB"), transport: transport)
        try await userA.saveSyncConfig(config)
        try await userB.saveSyncConfig(config)

        // User A creates a folder + ingests an asset + tags it, then syncs to the shared folder
        let paletteFolder = try await userA.createFolder(name: "Lighting", parentID: nil)
        let importedA = try await userA.ingest(
            [.imageData(try BackendFixture.artwork("#E09E5C"), suggestedName: "sunbeam.png", sourceURL: nil)],
            targetFolderID: paletteFolder.id,
            targetBoardID: nil
        )
        _ = try await userA.updateAssets(AssetBatchPatch(assetIDs: [importedA[0].id], addTags: ["warm", "studio"]))
        _ = try await userA.syncNow()

        // Someone also drops a reference directly into the shared folder on Google Drive
        _ = try await transport.uploadData(
            try BackendFixture.artwork("#2C4C70"),
            name: "external-collab.png",
            mimeType: "image/png",
            parentID: sharedFolder.id,
            existingFileID: nil
        )

        // User B syncs from the same shared folder and sees BOTH User A's asset+folder+tags AND the direct Drive drop
        let reportB = try await userB.syncNow()
        #expect(reportB.discoveredRemoteAssets >= 1)
        let assetsB = try await userB.fetchAssets(matching: FilterCriteria())
        #expect(Set(assetsB.map(\.fileName)) == ["sunbeam.png", "external-collab.png"])
        let syncedSunbeam = try #require(assetsB.first { $0.fileName == "sunbeam.png" })
        #expect(syncedSunbeam.tags.contains("warm"))
        #expect(syncedSunbeam.folderID == paletteFolder.id)

        // User B rates the externally dropped file and syncs back; User A converges on both files & rating
        let extAsset = try #require(assetsB.first { $0.fileName == "external-collab.png" })
        _ = try await userB.updateAssets(AssetBatchPatch(assetIDs: [extAsset.id], rating: 5))
        _ = try await userB.syncNow()
        _ = try await userA.syncNow()

        let assetsA = try await userA.fetchAssets(matching: FilterCriteria())
        #expect(Set(assetsA.map(\.fileName)) == ["sunbeam.png", "external-collab.png"])
        #expect(assetsA.first { $0.fileName == "external-collab.png" }?.rating == 5)
    }

    @Test("Fresh install never resurrects deleted folders, permanently deleted assets, cross-device out-of-order deletes, or soft-trashed assets")
    func freshInstallNeverResurrectsDeletedItems() async throws {
        let dir = try BackendFixture.directory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let transport = InMemoryDriveTransport()
        // Force Creator deviceID ("ffff...") > Deleter deviceID ("0000...") to test out-of-order cross-device replay!
        let creator = try BackendFixture.makeEngine(dir.appending(path: "Creator"), transport: transport)
        let deleter = try BackendFixture.makeEngine(dir.appending(path: "Deleter"), transport: transport)
        try await creator.database.setState("deviceID", "ffffffffffffffffffffffffffffffff")
        try await deleter.database.setState("deviceID", "00000000000000000000000000000000")
        try await creator.saveSyncConfig(BackendFixture.syncConfig())
        try await deleter.saveSyncConfig(BackendFixture.syncConfig())

        // 1. Creator creates nested folders Parent/Child, a lingering deleted folder, and 3 distinct assets
        let parent = try await creator.createFolder(name: "Parent", parentID: nil)
        let child = try await creator.createFolder(name: "Child", parentID: parent.id)
        let orphanFolder = try await creator.createFolder(name: "GhostFolder", parentID: nil)
        let keep = try #require(try await creator.ingest(
            [.imageData(try BackendFixture.artwork("#2E6F95"), suggestedName: "keep.png", sourceURL: nil)],
            targetFolderID: nil,
            targetBoardID: nil
        ).first)
        let permDel = try #require(try await creator.ingest(
            [.imageData(try BackendFixture.artwork("#B84A39"), suggestedName: "perm-del.png", sourceURL: nil)],
            targetFolderID: child.id,
            targetBoardID: nil
        ).first)
        let softTrash = try #require(try await creator.ingest(
            [.imageData(try BackendFixture.artwork("#4D7C5B"), suggestedName: "soft-trash.png", sourceURL: nil)],
            targetFolderID: child.id,
            targetBoardID: nil
        ).first)
        let leftoverAsset = try #require(try await creator.ingest(
            [.imageData(try BackendFixture.artwork("#9E7740"), suggestedName: "leftover-del.png", sourceURL: nil)],
            targetFolderID: orphanFolder.id,
            targetBoardID: nil
        ).first)
        _ = try await creator.syncNow()

        // Capture remote IDs for verifying physical cleanup and injecting simulated leftover remote items
        let leftoverRemoteFileID = try #require(try await creator.fetchAsset(id: leftoverAsset.id)?.driveFileID)
        let orphanRemoteFolderID = try #require(try await creator.fetchFolders().first { $0.id == orphanFolder.id }?.driveFolderID)
        let leftoverPayload = try BackendFixture.artwork("#9E7740")

        // 2. Deleter pulls everything, then deletes nested folders (Parent + Child), permanently deletes permDel,
        //    soft-trashes softTrash (moving it to Inbox), and deletes orphanFolder + leftoverAsset.
        _ = try await deleter.syncNow()
        _ = try await deleter.updateAssets(AssetBatchPatch(assetIDs: [softTrash.id], folderAssignment: .inbox, isTrashed: true))
        try await deleter.permanentlyDeleteAssets(ids: [permDel.id, leftoverAsset.id])
        try await deleter.deleteFolder(id: child.id)
        try await deleter.deleteFolder(id: parent.id)
        try await deleter.deleteFolder(id: orphanFolder.id)
        _ = try await deleter.syncNow()

        // Verify deepest-first physical deletion removed Parent, Child, and GhostFolder from Drive!
        let root = try await transport.findOrCreateFolder(named: "Charkle", parentID: "root")
        let rootChildrenAfterDelete = try await transport.listFiles(inFolderID: root.id)
        #expect(!rootChildrenAfterDelete.contains(where: { $0.name == "Parent" }))
        #expect(!rootChildrenAfterDelete.contains(where: { $0.name == "GhostFolder" }))

        // 3. Simulate a legacy/403/network-glitch leftover deleted folder & deleted file STILL sitting on Drive
        //    (using the exact previously deleted remote IDs, plus a duplicate-content leftover copy in a deleted folder)
        let ghostDirStillOnDrive = try await transport.findOrCreateFolder(named: "GhostFolder", parentID: root.id)
        _ = try await transport.uploadData(
            leftoverPayload,
            name: "leftover-del.png",
            mimeType: "image/png",
            parentID: ghostDirStillOnDrive.id,
            existingFileID: nil
        )
        #expect(!leftoverRemoteFileID.isEmpty)
        #expect(!orphanRemoteFolderID.isEmpty)

        // 4. Fresh Install (Device C) connects to Drive and syncs!
        let freshDevice = try BackendFixture.makeEngine(dir.appending(path: "FreshInstall"), transport: transport)
        try await freshDevice.saveSyncConfig(BackendFixture.syncConfig())
        let freshReport = try await freshDevice.syncNow()

        // Verify ZERO deleted folders resurrected and ZERO permanently deleted assets resurrected!
        let freshFolders = try await freshDevice.fetchFolders()
        #expect(freshFolders.isEmpty)

        let freshLiveAssets = try await freshDevice.fetchAssets(matching: FilterCriteria(includeTrashed: false))
        #expect(freshLiveAssets.map(\.id) == [keep.id])

        let freshTrashedAssets = try await freshDevice.fetchAssets(matching: FilterCriteria(onlyTrashed: true))
        #expect(freshTrashedAssets.map(\.id) == [softTrash.id])

        // Verify self-healing cleaned up the leftover file & empty GhostFolder on Drive and pushed zero resurrection ops
        let rootChildrenAfterFresh = try await transport.listFiles(inFolderID: root.id)
        #expect(!rootChildrenAfterFresh.contains(where: { $0.name == "GhostFolder" }))
        #expect(freshReport.discoveredRemoteAssets == 0)
        #expect(freshReport.uploadedOps == 0)

        // A second sync stays completely steady (idempotent)
        let secondReport = try await freshDevice.syncNow()
        #expect(secondReport.discoveredRemoteAssets == 0)
        #expect(secondReport.uploadedOps == 0)
    }

    @Test("Fresh install suppresses nil-driveID mounted deletions and keeps unbound soft-trashed assets in Trash")
    func freshInstallHandlesNilDriveIDDeletionsAndUnboundTrashed() async throws {
        let dir = try BackendFixture.directory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let transport = InMemoryDriveTransport()
        let root = try await transport.findOrCreateFolder(named: "Charkle", parentID: "root")
        let inbox = try await transport.findOrCreateFolder(named: "Inbox", parentID: root.id)
        let staleFolder = try await transport.findOrCreateFolder(named: "MountedDeleted", parentID: root.id)

        // Pre-place two physical files on Drive (as if uploaded earlier via gdirectMount where ops lack Google Drive IDs)
        let deletedPNG = try BackendFixture.artwork("#AA3344")
        let trashedPNG = try BackendFixture.artwork("#336699")
        _ = try await transport.uploadData(deletedPNG, name: "mounted-del.png", mimeType: "image/png", parentID: staleFolder.id, existingFileID: nil)
        _ = try await transport.uploadData(trashedPNG, name: "mounted-trash.png", mimeType: "image/png", parentID: staleFolder.id, existingFileID: nil)

        // Device A writes ops with driveFileID == nil & driveFolderID == nil (matching gdirectMount behavior),
        // permanently deletes mounted-del.png, soft-trashes mounted-trash.png (moving to Inbox), and deletes MountedDeleted.
        let deviceA = try BackendFixture.makeEngine(dir.appending(path: "DeviceA"), transport: transport)
        try await deviceA.saveSyncConfig(BackendFixture.syncConfig())
        let folderA = try await deviceA.createFolder(name: "MountedDeleted", parentID: nil)
        let imported = try await deviceA.ingest(
            [
                .imageData(deletedPNG, suggestedName: "mounted-del.png", sourceURL: nil),
                .imageData(trashedPNG, suggestedName: "mounted-trash.png", sourceURL: nil)
            ],
            targetFolderID: folderA.id,
            targetBoardID: nil
        )
        let delAsset = imported[0]
        let trashAsset = imported[1]
        _ = try await deviceA.updateAssets(AssetBatchPatch(assetIDs: [trashAsset.id], folderAssignment: .inbox, isTrashed: true))
        try await deviceA.permanentlyDeleteAssets(ids: [delAsset.id])
        try await deviceA.deleteFolder(id: folderA.id)

        // Push ONLY the ops shard directly (simulating a mount device whose remote delete didn't run on Drive)
        let meta = try await transport.findOrCreateFolder(named: ".charkle", parentID: root.id)
        let opsDir = try await transport.findOrCreateFolder(named: "ops", parentID: meta.id)
        let devID = try await deviceA.database.deviceID()
        let pendingOps = try await deviceA.database.pendingOps(as: SyncOperation.self, limit: 500)
        struct RawLogLine: Encodable { let seq: Int64; let operation: SyncOperation }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var bytes = Data()
        for (seq, op) in pendingOps {
            bytes.append(try encoder.encode(RawLogLine(seq: seq, operation: op)))
            bytes.append(0x0A)
        }
        let lastSeq = try #require(pendingOps.last?.0)
        _ = try await transport.uploadData(bytes, name: "ops-\(devID)-\(lastSeq).jsonl", mimeType: "application/x-ndjson", parentID: opsDir.id, existingFileID: nil)
        #expect(!inbox.id.isEmpty)

        // Fresh install (Device B) connects via Direct API
        let deviceB = try BackendFixture.makeEngine(dir.appending(path: "DeviceB"), transport: transport)
        try await deviceB.saveSyncConfig(BackendFixture.syncConfig())
        _ = try await deviceB.syncNow()

        // 1. Deleted folder must NOT be resurrected
        #expect(try await deviceB.fetchFolders().isEmpty)
        // 2. Permanently deleted asset must NOT be resurrected AND soft-trashed asset must NOT duplicate into live gallery
        let liveB = try await deviceB.fetchAssets(matching: FilterCriteria(includeTrashed: false))
        #expect(liveB.isEmpty)
        let trashedB = try await deviceB.fetchAssets(matching: FilterCriteria(onlyTrashed: true))
        #expect(trashedB.count == 1)
        #expect(trashedB.first?.id == trashAsset.id)
        #expect(trashedB.first?.isTrashed == true)
    }

    private struct Pair {
        let directory: URL
        let a: LiveCharkleEngine
        let b: LiveCharkleEngine
        let transport: InMemoryDriveTransport

        static func make() async throws -> Pair {
            let directory = try BackendFixture.directory()
            let transport = InMemoryDriveTransport(pageSize: 3)
            let a = try BackendFixture.makeEngine(directory.appending(path: "MacA"), transport: transport)
            let b = try BackendFixture.makeEngine(directory.appending(path: "MacB"), transport: transport)
            try await a.saveSyncConfig(BackendFixture.syncConfig())
            try await b.saveSyncConfig(BackendFixture.syncConfig())
            return Pair(directory: directory, a: a, b: b, transport: transport)
        }

        func cleanup() { try? FileManager.default.removeItem(at: directory) }

        func folders() async throws -> (root: RemoteDriveFile, inbox: RemoteDriveFile, metadata: RemoteDriveFile, boards: RemoteDriveFile) {
            let root = try await transport.findOrCreateFolder(named: "Charkle", parentID: "root")
            let inbox = try await transport.findOrCreateFolder(named: "Inbox", parentID: root.id)
            let meta = try await transport.findOrCreateFolder(named: ".charkle", parentID: root.id)
            let boards = try await transport.findOrCreateFolder(named: "boards", parentID: meta.id)
            return (root, inbox, meta, boards)
        }
    }
}
