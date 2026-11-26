import Foundation
import Testing
@testable import CharkleCore

@Suite("iCloud Drive & Simultaneous Multi-Backend Sync")
struct MultiBackendAndICloudTests {
    private func makeTempDir(_ prefix: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "\(prefix)-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeSamplePNG(in dir: URL, name: String) throws -> URL {
        // Minimal valid 1x1 PNG
        let pngBase64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+a8b8AAAAASUVORK5CYII="
        let data = Data(base64Encoded: pngBase64)!
        let url = dir.appending(path: name)
        try data.write(to: url)
        return url
    }

    @Test("ICloudDriveTransport roundtrips folders, uploads, moves, listings, and downloads")
    func iCloudTransportRoundtrip() async throws {
        let base = try makeTempDir("charkle-icloud-base")
        defer { try? FileManager.default.removeItem(at: base) }

        let transport = ICloudDriveTransport(baseDirectory: base, rootFolderName: "Charkle")
        let account = try await transport.accountInfo()
        #expect(account.source == "iCloud Drive")

        let root = try await transport.findOrCreateFolder(named: "Charkle", parentID: DriveFiles.rootID)
        let sub = try await transport.findOrCreateFolder(named: "References", parentID: root.id)
        #expect(sub.isFolder)

        let payload = Data("hello-icloud-charkle".utf8)
        let uploaded = try await transport.uploadData(
            payload,
            name: "note.txt",
            mimeType: "text/plain",
            parentID: sub.id,
            existingFileID: nil
        )
        #expect(uploaded.id.hasPrefix(ICloudDriveTransport.pathIDPrefix))

        let downloaded = try await transport.downloadData(fileID: uploaded.id)
        #expect(downloaded == payload)

        let listed = try await transport.listFiles(inFolderID: sub.id)
        #expect(listed.contains(where: { $0.name == "note.txt" }))

        let moved = try await transport.moveFile(
            fileID: uploaded.id,
            fromParentID: sub.id,
            toParentID: root.id,
            newName: "renamed.txt"
        )
        #expect(moved.name == "renamed.txt")
        let movedData = try await transport.downloadData(fileID: moved.id)
        #expect(movedData == payload)

        try await transport.trashFile(fileID: moved.id)
        let afterTrash = try await transport.listFiles(inFolderID: root.id)
        #expect(!afterTrash.contains(where: { $0.name == "renamed.txt" }))
    }

    @Test("DriveSyncConfig backwards-compatible decode & multi-backend primary synchronization")
    func multiBackendConfigCodableAndSyncPrimary() throws {
        let legacyJSON = #"{"mode":"directAPIWithGDirect","rootFolderName":"StudioLib"}"#
        let decoded = try JSONDecoder().decode(DriveSyncConfig.self, from: Data(legacyJSON.utf8))
        #expect(decoded.mode == .directAPIWithGDirect)
        #expect(decoded.resolvedBackends.count == 1)
        #expect(decoded.resolvedBackends[0].id == SyncBackendProfile.legacyPrimaryID)
        #expect(decoded.resolvedBackends[0].isPrimary)

        let icloudProfile = SyncBackendProfile(
            name: "iCloud Drive",
            mode: .iCloudDrive,
            isEnabled: true,
            isPrimary: false,
            iCloudFolderName: "Charkle"
        )
        var multi = decoded
        multi.backends = [decoded.resolvedBackends[0], icloudProfile]
        multi.synchronizePrimaryFields()
        #expect(multi.enabledBackends.count == 2)
        #expect(multi.enabledCloudBackends.count == 2)
        #expect(multi.activeStorageLocationSummary.contains("2 个同步后端"))

        let roundtripped = try JSONDecoder().decode(DriveSyncConfig.self, from: try JSONEncoder().encode(multi))
        #expect(roundtripped.backends.count == 2)
        #expect(roundtripped.backends.contains(where: { $0.mode == .iCloudDrive }))
    }

    @Test("LiveCharkleEngine simultaneously syncs two backends (Local Primary + iCloud Secondary) without clobbering primary IDs or dropping ops")
    func simultaneousMultiBackendSync() async throws {
        let appDir = try makeTempDir("charkle-app-support")
        let primaryDir = try makeTempDir("charkle-primary-local")
        let iCloudDir = try makeTempDir("charkle-secondary-icloud")
        let sampleDir = try makeTempDir("charkle-sample-input")
        defer {
            try? FileManager.default.removeItem(at: appDir)
            try? FileManager.default.removeItem(at: primaryDir)
            try? FileManager.default.removeItem(at: iCloudDir)
            try? FileManager.default.removeItem(at: sampleDir)
        }

        let engine = try LiveCharkleEngine.make(appSupportDirectory: appDir)
        let primaryProfile = SyncBackendProfile(
            id: SyncBackendProfile.legacyPrimaryID,
            name: "本地主库",
            mode: .localOnly,
            isEnabled: true,
            isPrimary: true,
            localLibraryPath: primaryDir.appending(path: "CharklePrimary").path
        )
        let iCloudProfile = SyncBackendProfile(
            name: "iCloud Drive",
            mode: .iCloudDrive,
            isEnabled: true,
            isPrimary: false,
            iCloudFolderName: "CharkleICloud",
            iCloudCustomFolderPath: iCloudDir.appending(path: "CharkleICloud").path
        )
        var config = DriveSyncConfig(
            autoSyncIntervalSeconds: 0,
            syncThumbnails: true,
            syncEmbeddings: false,
            backends: [primaryProfile, iCloudProfile]
        )
        config.synchronizePrimaryFields()
        try await engine.saveSyncConfig(config)

        let folder = try await engine.createFolder(name: "Editorial", parentID: nil)
        let pngURL = try makeSamplePNG(in: sampleDir, name: "poster.png")
        let imported = try await engine.ingest([.fileURL(pngURL)], targetFolderID: folder.id, targetBoardID: nil)
        #expect(imported.count == 1)

        let report = try await engine.syncNow()
        #expect(report.uploadedOps > 0)

        let status = await engine.syncStatus()
        #expect(status.backendStatuses.count == 2)
        #expect(status.backendStatuses.allSatisfy { $0.lastSyncedAt != nil && $0.lastError == nil })

        // Verify BOTH primary local folder AND secondary iCloud folder received the human-readable folder + original + .charkle ops!
        let primaryAssetFile = primaryDir.appending(path: "CharklePrimary/Editorial/poster.png")
        let iCloudAssetFile = iCloudDir.appending(path: "CharkleICloud/Editorial/poster.png")
        let iCloudOpsDir = iCloudDir.appending(path: "CharkleICloud/.charkle/ops")
        #expect(FileManager.default.fileExists(atPath: primaryAssetFile.path))
        #expect(FileManager.default.fileExists(atPath: iCloudAssetFile.path))
        let opsFiles = (try? FileManager.default.contentsOfDirectory(atPath: iCloudOpsDir.path)) ?? []
        #expect(!opsFiles.isEmpty)

        // Verify primary asset's driveFileID remained bound to primary (not clobbered by secondary iCloud path)
        let reloaded = try await engine.fetchAsset(id: imported[0].id)
        #expect(reloaded?.driveFileID?.hasPrefix(ICloudDriveTransport.pathIDPrefix) == false)

        // Permanently delete asset & folder and sync again: verify BOTH primary AND secondary iCloud Drive remove them cleanly!
        try await engine.permanentlyDeleteAssets(ids: [imported[0].id])
        try await engine.deleteFolder(id: folder.id)
        _ = try await engine.syncNow()

        #expect(!FileManager.default.fileExists(atPath: primaryAssetFile.path))
        #expect(!FileManager.default.fileExists(atPath: iCloudAssetFile.path))
        #expect(!FileManager.default.fileExists(atPath: primaryDir.appending(path: "CharklePrimary/Editorial").path))
        #expect(!FileManager.default.fileExists(atPath: iCloudDir.appending(path: "CharkleICloud/Editorial").path))
    }
}
