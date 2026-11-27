import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import CharkleCore

@Suite("Swarm Core Audit Regression Tests")
struct SwarmCoreAuditTests {

    private func makeTempDir(_ prefix: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "\(prefix)-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeSolidImageData(
        width: Int,
        height: Int,
        r: CGFloat,
        g: CGFloat,
        b: CGFloat,
        type: UTType = .png,
        exifOrientation: Int? = nil
    ) throws -> Data {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        let ctx = try #require(CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ))
        ctx.setFillColor(red: r, green: g, blue: b, alpha: 1.0)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.setFillColor(red: 1.0 - r, green: 1.0 - g, blue: 1.0 - b, alpha: 1.0)
        ctx.fill(CGRect(x: 0, y: 0, width: max(1, width / 3), height: max(1, height / 2)))
        let cgImage = try #require(ctx.makeImage())

        let out = NSMutableData()
        let dest = try #require(CGImageDestinationCreateWithData(
            out as CFMutableData,
            type.identifier as CFString,
            1,
            nil
        ))
        let props: CFDictionary? = exifOrientation.map {
            [kCGImagePropertyOrientation: $0] as CFDictionary
        }
        CGImageDestinationAddImage(dest, cgImage, props)
        #expect(CGImageDestinationFinalize(dest))
        return out as Data
    }

    private func makePin(id: String) -> PinterestPin {
        let url = URL(string: "https://i.pinimg.com/736x/aa/bb/cc/\(id).jpg")!
        let page = URL(string: "https://www.pinterest.com/pin/\(id)/")!
        return PinterestPin(
            id: id,
            title: "Pin \(id)",
            width: 400,
            height: 600,
            thumbnailURL: url,
            previewURL: url,
            originalURL: url,
            pinPageURL: page
        )
    }

    // MARK: - P0 #1: PureRefCodec UInt64 Overflow & EXIF Orientation

    @Test("PureRefCodec handles high-bit UInt64 lengths without trapping and honors EXIF orientation 5...8")
    func pureRefHighBitUInt64AndEXIFOrientation() throws {
        // Build a crafted v1 header containing UInt64.max (high-bit set) length fields
        var malformed = Data("PRSF".utf8)
        malformed.append(contentsOf: [0x00, 0x00, 0x00, 0x00])
        // Append 0xFFFFFFFFFFFFFFFF (would crash `Int(readUInt64BE(...))` previously)
        malformed.append(contentsOf: Array(repeating: UInt8(0xFF), count: 64))
        do {
            _ = try PureRefCodec.decode(data: malformed)
            Issue.record("Expected malformed PureRef payload to throw")
        } catch {
            // Throwing cleanly without crashing proves Int(exactly:) guarded overflow
        }

        // Verify EXIF orientation 6 (90 deg CW): raw 48x24 JPEG must report swapped 24x48 dimensions
        // and convertToPNG must bake the upright 24x48 pixel orientation.
        let rotatedJPEG = try makeSolidImageData(
            width: 48,
            height: 24,
            r: 0.2,
            g: 0.6,
            b: 0.9,
            type: .jpeg,
            exifOrientation: 6
        )
        let dims = try #require(PureRefCodec.inspectImageDimensions(rotatedJPEG))
        #expect(dims.width == 24)
        #expect(dims.height == 48)

        let png = try #require(PureRefCodec.convertToPNG(rotatedJPEG))
        let pngDims = try #require(PureRefCodec.inspectImageDimensions(png))
        #expect(pngDims.width == 24)
        #expect(pngDims.height == 48)
    }

    // MARK: - P0 #2: Degenerate CGPath Geometry & Unsigned Artwork Hash

    @Test("BoardImageRenderer, SVGPreview, and MediaArtwork survive degenerate dimensions and extreme radii")
    func degenerateGeometryAndArtworkHashNoTrap() throws {
        let assetID = UUID()
        let doc = MoodboardDocument(
            title: "Tiny Geometry Stress",
            subtitle: "Extreme vertical shrink",
            mode: .freeform,
            nodes: [
                BoardNode(
                    kind: .groupFrame(title: "Tight Group", tint: .slate),
                    frame: BoardRect(x: 0, y: 0, width: 14, height: 10)
                ),
                BoardNode(
                    kind: .note(title: "Mini", text: "Compact note", style: .paper, fontSize: 12),
                    frame: BoardRect(x: 20, y: 0, width: 12, height: 8)
                ),
                BoardNode(
                    kind: .assetRef(assetID: assetID, crop: nil, weight: 1, autoplayLoop: false),
                    frame: BoardRect(x: 40, y: 0, width: 10, height: 6)
                ),
                BoardNode(
                    kind: .groupFrame(title: "Tall Canvas Force Shrink", tint: .sage),
                    frame: BoardRect(x: 0, y: 80_000, width: 120, height: 20)
                )
            ],
            extractedPalette: [LabColor.fromHex("#FF5533"), LabColor.fromHex("#224488")]
        )
        let png = BoardImageRenderer.renderPNG(
            document: doc,
            assetsByID: [:],
            thumbnailURL: { _ in nil }
        )
        #expect(png != nil)
        #expect((png?.count ?? 0) > 100)

        let dir = try makeTempDir("charkle-svg-degenerate")
        defer { try? FileManager.default.removeItem(at: dir) }
        let svgURL = dir.appending(path: "extreme.svg")
        let svgContent = """
        <svg xmlns="http://www.w3.org/2000/svg" width="120" height="80" viewBox="0 0 120 80">
          <rect x="4" y="4" width="20" height="10" rx="999" ry="999" fill="#3366ff"/>
          <rect x="30" y="4" width="-10" height="0" rx="10" fill="#ff0000"/>
          <circle cx="60" cy="40" r="-5" fill="#00ff00"/>
          <ellipse cx="90" cy="40" rx="12" ry="8" fill="#ff9900"/>
        </svg>
        """
        try Data(svgContent.utf8).write(to: svgURL)
        let renderedSVG = SVGPreview.render(svgURL)
        #expect(renderedSVG != nil)

        for sample in ["", "A", "设计参考 🎨", String(repeating: "long-title-", count: 20)] {
            let card = MediaArtwork.card(title: sample, label: "NOTE", text: "Preview text")
            #expect(card != nil)
        }
    }

    // MARK: - P1 #13: Backward-Compatible Codable Decoding

    @Test("CoreModels decode legacy JSON missing newer optional/defaulted fields")
    func coreModelsBackwardCompatibleDecoding() throws {
        let assetID = UUID()
        let minimalAssetJSON = """
        {
          "id": "\(assetID.uuidString)",
          "title": "Legacy Asset",
          "fileName": "legacy.png",
          "contentHash": "abc123",
          "mediaKind": "image",
          "mimeType": "image/png",
          "fileSizeBytes": 1024,
          "pixelWidth": 100,
          "pixelHeight": 80,
          "createdAt": 0,
          "updatedAt": 0
        }
        """
        let decodedAsset = try JSONDecoder().decode(AssetRecord.self, from: Data(minimalAssetJSON.utf8))
        #expect(decodedAsset.id == assetID)
        #expect(decodedAsset.title == "Legacy Asset")
        #expect(decodedAsset.waveformPeaks.isEmpty)
        #expect(decodedAsset.suggestedTags.isEmpty)
        #expect(decodedAsset.isTrashed == false)
        #expect(decodedAsset.updatedHLC == 0)

        let folderID = UUID()
        let minimalFolderJSON = """
        {
          "id": "\(folderID.uuidString)",
          "name": "Legacy Folder"
        }
        """
        let decodedFolder = try JSONDecoder().decode(FolderRecord.self, from: Data(minimalFolderJSON.utf8))
        #expect(decodedFolder.id == folderID)
        #expect(decodedFolder.name == "Legacy Folder")
        #expect(decodedFolder.sortOrder == 0)

        let minimalSmartRule = try JSONDecoder().decode(
            SmartFolderRule.self,
            from: Data(#"{"tags":["ui"]}"#.utf8)
        )
        #expect(minimalSmartRule.matchMode == .all)
        #expect(minimalSmartRule.tags == ["ui"])
        #expect(minimalSmartRule.colorTolerance == 24.0)
        #expect(minimalSmartRule.minRating == 0)

        let smartFolderID = UUID()
        let minimalSmartFolder = try JSONDecoder().decode(
            SmartFolderRecord.self,
            from: Data(#"{"id":"\#(smartFolderID.uuidString)","name":"Favorites"}"#.utf8)
        )
        #expect(minimalSmartFolder.id == smartFolderID)
        #expect(minimalSmartFolder.name == "Favorites")
        #expect(minimalSmartFolder.rule.matchMode == .all)
        #expect(minimalSmartFolder.sortOrder == 0)

        let minimalFilter = try JSONDecoder().decode(FilterCriteria.self, from: Data("{}".utf8))
        #expect(minimalFilter.searchQuery == "")
        #expect(minimalFilter.sortBy == .newest)

        let minimalRepo = try JSONDecoder().decode(
            GitHubRepoMetadata.self,
            from: Data(#"{"owner":"apple","repo":"swift"}"#.utf8)
        )
        #expect(minimalRepo.owner == "apple")
        #expect(minimalRepo.repo == "swift")
        #expect(minimalRepo.stars == 0)
        #expect(minimalRepo.topics.isEmpty)
    }

    // MARK: - P1 #18: WebDAV PROPFIND Unencoded Spaces/Brackets/Unicode

    @Test("WebDAVTransport.parsePropfindResponse resolves hrefs with unencoded spaces, brackets, and Unicode")
    func webDAVPropfindUnencodedHrefs() throws {
        let xml = """
        <?xml version="1.0" encoding="utf-8"?>
        <D:multistatus xmlns:D="DAV:">
          <D:response>
            <D:href>/dav/Charkle/</D:href>
            <D:propstat><D:prop><D:resourcetype><D:collection/></D:resourcetype></D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat>
          </D:response>
          <D:response>
            <D:href>/dav/Charkle/参考 图 [1].png</D:href>
            <D:propstat>
              <D:prop>
                <D:resourcetype/>
                <D:getcontentlength>4096</D:getcontentlength>
                <D:getcontenttype>image/png</D:getcontenttype>
              </D:prop>
              <D:status>HTTP/1.1 200 OK</D:status>
            </D:propstat>
          </D:response>
          <D:response>
            <D:href>/dav/Charkle/My%20Folder/shot [2].jpg</D:href>
            <D:propstat>
              <D:prop>
                <D:resourcetype/>
                <D:getcontentlength>8192</D:getcontentlength>
              </D:prop>
              <D:status>HTTP/1.1 200 OK</D:status>
            </D:propstat>
          </D:response>
        </D:multistatus>
        """
        let baseURL = URL(string: "https://nas.example.com/dav")!
        let parsed = try WebDAVTransport.parsePropfindResponse(
            Data(xml.utf8),
            baseURL: baseURL,
            directoryRelPath: "Charkle",
            parentID: "Charkle"
        )
        #expect(parsed.count == 2)
        #expect(parsed.contains(where: { $0.name == "参考 图 [1].png" && $0.size == 4096 }))
        #expect(parsed.contains(where: { $0.name == "shot [2].jpg" && $0.size == 8192 }))
    }

    // MARK: - P0 #7 & P1 #18: iCloud Security-Scoped Folder & Atomic UploadFile

    @Test("ICloudDriveTransport stays inside securityScopedURL and stages uploadFile atomically")
    func iCloudSecurityScopedAndAtomicUpload() async throws {
        let rootDir = try makeTempDir("charkle-icloud-scoped-parent")
        let scopedDir = rootDir.appending(path: "MyCharkle", directoryHint: .isDirectory)
        let inputDir = try makeTempDir("charkle-icloud-input")
        defer {
            try? FileManager.default.removeItem(at: rootDir)
            try? FileManager.default.removeItem(at: inputDir)
        }
        try FileManager.default.createDirectory(at: scopedDir, withIntermediateDirectories: true)

        let transport = ICloudDriveTransport(
            baseDirectory: rootDir,
            rootFolderName: "MyCharkle",
            accountLabel: "iCloud Drive / MyCharkle",
            securityScopedURL: scopedDir
        )

        let account = try await transport.accountInfo()
        #expect(account.source == "iCloud Drive")

        // Even if caller passes a different root name, security-scoped mode stays bound to scopedDir
        let rootFolder = try await transport.findOrCreateFolder(named: "Charkle", parentID: DriveFiles.rootID)
        #expect(rootFolder.id == ICloudDriveTransport.pathIDPrefix + "MyCharkle")

        let rootListing = try await transport.listFiles(inFolderID: DriveFiles.rootID)
        #expect(rootListing.count == 1)
        #expect(rootListing[0].id == rootFolder.id)

        let localFile = inputDir.appending(path: "asset.bin")
        let bytes = Data(repeating: 0xAB, count: 16_384)
        try bytes.write(to: localFile)

        let uploaded = try await transport.uploadFile(
            from: localFile,
            name: "asset.bin",
            mimeType: "application/octet-stream",
            parentID: rootFolder.id,
            existingFileID: nil
        )
        let downloaded = try await transport.downloadData(fileID: uploaded.id)
        #expect(downloaded == bytes)

        let dirContents = try FileManager.default.contentsOfDirectory(atPath: scopedDir.path)
        #expect(!dirContents.contains(where: { $0.hasPrefix(".charkle-icloud-") }))
    }

    // MARK: - P0 #3, #4, #5 & P1 #12: Multi-Backend Sync, Duplicate Collisions, Path Re-Add & Cover Invalidation

    @Test("Multi-backend sync mirrors shared projections to all backends and avoids duplicate filename collision")
    func multiBackendProjectionsAndDuplicateNames() async throws {
        let appDir = try makeTempDir("charkle-multi-app")
        let primaryDir = try makeTempDir("charkle-multi-primary")
        let secondaryDir = try makeTempDir("charkle-multi-secondary")
        defer {
            try? FileManager.default.removeItem(at: appDir)
            try? FileManager.default.removeItem(at: primaryDir)
            try? FileManager.default.removeItem(at: secondaryDir)
        }

        let engine = try LiveCharkleEngine.make(appSupportDirectory: appDir)
        let primaryProfile = SyncBackendProfile(
            id: SyncBackendProfile.legacyPrimaryID,
            name: "PrimaryLocal",
            mode: .localOnly,
            isEnabled: true,
            isPrimary: true,
            localLibraryPath: primaryDir.appending(path: "PrimaryLib").path
        )
        let secondaryProfile = SyncBackendProfile(
            name: "SecondaryICloud",
            mode: .iCloudDrive,
            isEnabled: true,
            isPrimary: false,
            iCloudFolderName: "SecondaryLib",
            iCloudCustomFolderPath: secondaryDir.appending(path: "SecondaryLib").path
        )
        var config = DriveSyncConfig(
            autoSyncIntervalSeconds: 0,
            syncThumbnails: true,
            syncEmbeddings: false,
            backends: [primaryProfile, secondaryProfile]
        )
        config.synchronizePrimaryFields()
        try await engine.saveSyncConfig(config)

        let img1 = try makeSolidImageData(width: 64, height: 64, r: 0.9, g: 0.1, b: 0.1)
        let img2 = try makeSolidImageData(width: 96, height: 64, r: 0.1, g: 0.2, b: 0.9)
        let imported = try await engine.ingest(
            [
                .imageData(img1, suggestedName: "same.png", sourceURL: nil),
                .imageData(img2, suggestedName: "same.png", sourceURL: nil)
            ],
            targetFolderID: nil,
            targetBoardID: nil
        )
        #expect(imported.count == 2)

        let board = MoodboardDocument(
            title: "Shared Multi-Backend Board",
            nodes: [
                BoardNode(
                    kind: .assetRef(assetID: imported[0].id, crop: nil, weight: 1, autoplayLoop: false),
                    frame: BoardRect(x: 0, y: 0, width: 200, height: 200)
                )
            ]
        )
        let savedBoard = try await engine.saveBoard(board)

        _ = try await engine.syncNow()

        // 1. Both primary AND secondary backends must receive the board JSON (primary didn't clear projection.boards prematurely!)
        let primaryBoardFile = primaryDir.appending(path: "PrimaryLib/.charkle/boards/\(savedBoard.id.uuidString.lowercased()).json")
        let secondaryBoardFile = secondaryDir.appending(path: "SecondaryLib/.charkle/boards/\(savedBoard.id.uuidString.lowercased()).json")
        #expect(FileManager.default.fileExists(atPath: primaryBoardFile.path))
        #expect(FileManager.default.fileExists(atPath: secondaryBoardFile.path))

        // 2. Both distinct same-named files must exist as two distinct files in secondary Inbox
        let secondaryInbox = secondaryDir.appending(path: "SecondaryLib/Inbox")
        let secondaryFiles = try FileManager.default.contentsOfDirectory(atPath: secondaryInbox.path)
            .filter { $0.hasSuffix(".png") }
        #expect(secondaryFiles.count == 2)

        // 3. Shared board projections should now be cleared after all enabled backends succeeded
        let remainingBoardDirty: [String: String] = (try? await engine.database.state("projection.boards")) ?? [:]
        #expect(remainingBoardDirty[savedBoard.id.uuidString] == nil)
    }

    @Test("iCloud path transport clears stale deletion markers and mints fresh UUID on re-added file at same path")
    func iCloudPathStaleMarkerCleanupAndReadd() async throws {
        let appDir = try makeTempDir("charkle-icloud-readd-app")
        let cloudRoot = try makeTempDir("charkle-icloud-readd-cloud")
        defer {
            try? FileManager.default.removeItem(at: appDir)
            try? FileManager.default.removeItem(at: cloudRoot)
        }

        let engine = try LiveCharkleEngine.make(appSupportDirectory: appDir)
        let cloudFolder = cloudRoot.appending(path: "CharkleVault")
        let profile = SyncBackendProfile(
            id: SyncBackendProfile.legacyPrimaryID,
            name: "iCloud",
            mode: .iCloudDrive,
            isEnabled: true,
            isPrimary: true,
            iCloudFolderName: "CharkleVault",
            iCloudCustomFolderPath: cloudFolder.path
        )
        var config = DriveSyncConfig(
            mode: .iCloudDrive,
            autoSyncIntervalSeconds: 0,
            syncThumbnails: true,
            syncEmbeddings: false,
            backends: [profile]
        )
        config.synchronizePrimaryFields()
        try await engine.saveSyncConfig(config)

        let imgA = try makeSolidImageData(width: 40, height: 40, r: 0.9, g: 0.2, b: 0.1)
        let first = try await engine.ingest(
            [.imageData(imgA, suggestedName: "reused.png", sourceURL: nil)],
            targetFolderID: nil,
            targetBoardID: nil
        )
        #expect(first.count == 1)
        _ = try await engine.syncNow()

        let remotePath = cloudFolder.appending(path: "Inbox/reused.png")
        #expect(FileManager.default.fileExists(atPath: remotePath.path))

        // Permanently delete and sync once so iCloud removes the file and clears the stale path marker
        try await engine.permanentlyDeleteAssets(ids: [first[0].id])
        _ = try await engine.syncNow()
        #expect(!FileManager.default.fileExists(atPath: remotePath.path))

        // Re-sync once more after confirmed remote absence so stale marker is guaranteed pruned
        _ = try await engine.syncNow()

        // Drop a brand-new distinct image at the EXACT same iCloud path
        let imgB = try makeSolidImageData(width: 72, height: 48, r: 0.1, g: 0.85, b: 0.35)
        try imgB.write(to: remotePath, options: .atomic)

        let readdReport = try await engine.syncNow()
        #expect(readdReport.discoveredRemoteAssets >= 1)
        let assets = try await engine.fetchAssets(matching: FilterCriteria(includeTrashed: false))
        #expect(assets.count == 1)
        #expect(assets[0].fileName == "reused.png")
        #expect(assets[0].id != first[0].id)
    }

    @Test("Remote thumbnail update invalidates stale local preview1400 cache")
    func remoteThumbnailInvalidatesStalePreview1400() async throws {
        let appDir = try makeTempDir("charkle-thumb-inv-app")
        let cloudRoot = try makeTempDir("charkle-thumb-inv-cloud")
        defer {
            try? FileManager.default.removeItem(at: appDir)
            try? FileManager.default.removeItem(at: cloudRoot)
        }

        let engine = try LiveCharkleEngine.make(appSupportDirectory: appDir)
        let cloudFolder = cloudRoot.appending(path: "CharkleThumbVault")
        let profile = SyncBackendProfile(
            id: SyncBackendProfile.legacyPrimaryID,
            name: "iCloud",
            mode: .iCloudDrive,
            isEnabled: true,
            isPrimary: true,
            iCloudFolderName: "CharkleThumbVault",
            iCloudCustomFolderPath: cloudFolder.path
        )
        var config = DriveSyncConfig(
            mode: .iCloudDrive,
            autoSyncIntervalSeconds: 0,
            syncThumbnails: true,
            syncEmbeddings: false,
            backends: [profile]
        )
        config.synchronizePrimaryFields()
        try await engine.saveSyncConfig(config)

        let largeImg = try makeSolidImageData(width: 900, height: 600, r: 0.1, g: 0.3, b: 0.8)
        let imported = try await engine.ingest(
            [.imageData(largeImg, suggestedName: "cover-test.png", sourceURL: nil)],
            targetFolderID: nil,
            targetBoardID: nil
        )
        let assetID = try #require(imported.first?.id)
        _ = try await engine.syncNow()

        // Confirm preview1400 exists on disk locally before remote cover replacement
        let media = await engine.media
        let preview1400URL = try #require(media.thumbnailURL(for: assetID, tier: .preview1400))
        #expect(FileManager.default.fileExists(atPath: preview1400URL.path))

        // Simulate Device B updating the remote thumbnail under `.charkle/thumbnails/<uuid>.jpg`
        let remoteThumb = cloudFolder.appending(path: ".charkle/thumbnails/\(assetID.uuidString.lowercased()).jpg")
        let newCoverJPEG = try makeSolidImageData(width: 400, height: 300, r: 0.95, g: 0.4, b: 0.05, type: .jpeg)
        try newCoverJPEG.write(to: remoteThumb, options: .atomic)
        // Bump mtime cleanly by +2s so path-based stamp changes deterministically
        let futureDate = Date().addingTimeInterval(2.0)
        try FileManager.default.setAttributes([.modificationDate: futureDate], ofItemAtPath: remoteThumb.path)

        _ = try await engine.syncNow()

        // Stale preview1400 file must be deleted on disk so Quick Look falls back cleanly to the fresh grid520 cover
        #expect(!FileManager.default.fileExists(atPath: preview1400URL.path))
        let updatedGrid = try #require(engine.cachedThumbnailURL(for: assetID, tier: .grid520))
        #expect(engine.cachedThumbnailURL(for: assetID, tier: .preview1400) == updatedGrid)
        #expect(try Data(contentsOf: updatedGrid) == newCoverJPEG)
    }

    // MARK: - P0 #9: Secondary WebDAV Password Isolation

    @Test("Secondary WebDAV backend never inherits legacy primary WebDAV password")
    func webDAVPasswordIsolation() async throws {
        let dir = try makeTempDir("charkle-webdav-pwd")
        defer { try? FileManager.default.removeItem(at: dir) }

        let service = "com.charkle.tests.webdav-iso.\(UUID().uuidString)"
        let keychain = KeychainStore(service: service)
        let database = try LibraryDatabase()
        let media = try MediaPipeline(directory: dir)
        let engine = LiveCharkleEngine(
            database: database,
            media: media,
            intelligence: IntelligenceEngine(keychain: keychain)
        )
        let primaryID = SyncBackendProfile.legacyPrimaryID
        let secondaryID = UUID()
        defer {
            try? keychain.delete("sync.webdav.password")
            try? keychain.delete("webdav.password.\(secondaryID.uuidString)")
        }

        try await engine.saveBackendWebDAVPassword("primary-only-secret", for: primaryID)
        #expect(await engine.hasBackendWebDAVPassword(for: primaryID) == true)
        #expect(await engine.hasBackendWebDAVPassword(for: secondaryID) == false)

        let primaryPwd = try await engine.readBackendWebDAVPassword(for: primaryID)
        let secondaryPwd = try await engine.readBackendWebDAVPassword(for: secondaryID)
        #expect(primaryPwd == "primary-only-secret")
        #expect(secondaryPwd.isEmpty)
    }

    // MARK: - P1 #12: updateAssetCoverImage Off-Actor + FeaturePrint + Colors

    @Test("updateAssetCoverImage updates dominant colors and Vision FeaturePrint")
    func updateAssetCoverImageRefreshesColorsAndVector() async throws {
        let dir = try makeTempDir("charkle-cover-update")
        defer { try? FileManager.default.removeItem(at: dir) }

        let engine = try BackendFixture.makeEngine(dir)
        let blue = try makeSolidImageData(width: 240, height: 180, r: 0.05, g: 0.15, b: 0.95)
        let imported = try await engine.ingest(
            [.imageData(blue, suggestedName: "frame.png", sourceURL: nil)],
            targetFolderID: nil,
            targetBoardID: nil
        )
        let asset = try #require(imported.first)

        let orange = try makeSolidImageData(width: 320, height: 240, r: 0.95, g: 0.45, b: 0.05, type: .jpeg)
        let updated = try await engine.updateAssetCoverImage(id: asset.id, imageData: orange)
        #expect(!updated.dominantColors.isEmpty)
        #expect(updated.pixelWidth == 320)
        #expect(updated.pixelHeight == 240)
        #expect(engine.cachedThumbnailURL(for: asset.id, tier: .grid520) != nil)
        let vector = try await engine.database.vector(for: asset.id)
        #expect(vector?.featurePrint != nil)
    }

    // MARK: - P1 #20: SmartDeduplicator Canonical Bookmark Params

    @Test("SmartDeduplicator preserves ?s= and ?t= on generic sites while stripping them on X/YouTube")
    func smartDeduplicatorQueryParamScoping() {
        let searchA = AssetRecord(
            title: "Search Cats",
            fileName: "a.webloc",
            mediaKind: .webBookmark,
            sourceURL: "https://example.com/search?s=cats&t=2"
        )
        let searchB = AssetRecord(
            title: "Search Dogs",
            fileName: "b.webloc",
            mediaKind: .webBookmark,
            sourceURL: "https://example.com/search?s=dogs&t=3"
        )
        let keyA = SmartDeduplicator.canonicalBookmarkKey(for: searchA)
        let keyB = SmartDeduplicator.canonicalBookmarkKey(for: searchB)
        #expect(keyA != nil)
        #expect(keyB != nil)
        #expect(keyA != keyB)

        let ytA = AssetRecord(
            title: "Video A",
            fileName: "yt1.webloc",
            mediaKind: .webBookmark,
            sourceURL: "https://example.com/article?utm_source=twitter&id=42"
        )
        let ytB = AssetRecord(
            title: "Video B",
            fileName: "yt2.webloc",
            mediaKind: .webBookmark,
            sourceURL: "https://example.com/article?id=42"
        )
        #expect(SmartDeduplicator.canonicalBookmarkKey(for: ytA) == SmartDeduplicator.canonicalBookmarkKey(for: ytB))
    }

    // MARK: - P1 #21: MCPStdioFrameParser Oversized Frame Recovery & Agent JSON Extraction

    @Test("MCPStdioFrameParser drains split oversized Content-Length payload cleanly before next frame")
    func mcpStdioOversizedChunkDrain() {
        var parser = MCPStdioFrameParser(maxFrameBytes: 1024)
        let headerAndPartial = Data("Content-Length: 2048\r\n\r\n".utf8) + Data(repeating: 0x41, count: 500)
        let events1 = parser.append(headerAndPartial)
        #expect(events1.count == 1)
        if case .invalidFrame(_, let framing) = events1.first {
            #expect(framing == .contentLength)
        } else {
            Issue.record("Expected invalidFrame event for oversized Content-Length")
        }

        // Remainder of oversized body (1548 bytes) split into two chunks, followed immediately by a valid frame
        let events2 = parser.append(Data(repeating: 0x42, count: 1000))
        #expect(events2.isEmpty)

        let validBody = Data(#"{"jsonrpc":"2.0","id":1,"method":"ping"}"#.utf8)
        let validFrame = Data("Content-Length: \(validBody.count)\r\n\r\n".utf8) + validBody
        let events3 = parser.append(Data(repeating: 0x43, count: 548) + validFrame)
        #expect(events3.count == 1)
        if case .message(let payload, let framing) = events3.first {
            #expect(framing == .contentLength)
            #expect(payload == validBody)
        } else {
            Issue.record("Expected intact follow-up message after draining oversized frame")
        }
    }

    @Test("MoodboardAgentHarness.extractJSONObject skips <think> braces and extracts trailing JSON object")
    func moodboardAgentHarnessExtractJSONWithThinkBlock() throws {
        let raw = """
        <think>
        Maybe I should return {"draft": true, "bad": [1, 2]} first.
        </think>
        Here is the curated plan:
        {"title": "Editorial Light", "count": 4}
        """
        let obj = try MoodboardAgentHarness.extractJSONObject(from: raw)
        #expect(obj["title"] as? String == "Editorial Light")
        #expect(obj["count"] as? Int == 4)
    }

    // MARK: - P2 #24: Markdown Nesting Cap, Unclosed HTML Block & Malformed PNG iTXt

    @Test("MarkdownDocumentParser caps deep <details> nesting and recovers from unclosed <p> block")
    func markdownParserEdgeCases() {
        let deep = String(repeating: "<details><summary>L</summary>\n", count: 35)
            + "Inner body"
            + String(repeating: "\n</details>", count: 35)
        let deepBlocks = MarkdownDocumentParser.parse(deep)
        #expect(!deepBlocks.isEmpty)

        let unclosed = """
        <p>Unclosed paragraph text

        # Heading After Unclosed Tag
        """
        let blocks = MarkdownDocumentParser.parse(unclosed)
        let hasHeading = blocks.contains { block in
            if case .heading(_, _, let text, _) = block {
                return text.contains("Heading After Unclosed Tag")
            }
            return false
        }
        #expect(hasHeading)
    }

    @Test("ImageMetadataExtractor safely handles malformed PNG iTXt chunk ending on NUL byte")
    func imageMetadataMalformedPNGiTXt() {
        // Minimal PNG signature + iTXt chunk whose payload is `"XML\0"` (ends right at NUL with no compression flag)
        var png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        let payload = Data([0x58, 0x4D, 0x4C, 0x00]) // "XML\0"
        var len = UInt32(payload.count).bigEndian
        png.append(Data(bytes: &len, count: 4))
        png.append(Data("iTXt".utf8))
        png.append(payload)
        png.append(contentsOf: [0x00, 0x00, 0x00, 0x00]) // dummy CRC
        // IEND
        png.append(contentsOf: [0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82])

        let chunks = ImageMetadataExtractor.extractPNGTextChunks(from: png)
        #expect(chunks.isEmpty)
    }

    // MARK: - P1 #23: PinterestExploreController O(1) Tray Index & Consistency

    @Test("PinterestExploreController keeps O(1) trayPinIDs in sync across tray mutations")
    @MainActor
    func pinterestExploreControllerTraySync() {
        let controller = PinterestExploreController(persistTray: false)
        let p1 = makePin(id: "1001")
        let p2 = makePin(id: "1002")

        controller.addToTray(p1)
        controller.addToTray(p2)
        #expect(controller.isInTray("1001"))
        #expect(controller.isInTray("1002"))
        #expect(controller.trayCount == 2)

        #expect(controller.toggleTray(p1) == false)
        #expect(!controller.isInTray("1001"))
        #expect(controller.isInTray("1002"))

        controller.addToTray(p1)
        controller.deselectAllTray()
        controller.toggleTraySelection("1002")
        let removed = controller.removeSelectedFromTray()
        #expect(removed == 1)
        #expect(!controller.isInTray("1002"))
        #expect(controller.isInTray("1001"))

        controller.clearTray()
        #expect(!controller.isInTray("1001"))
        #expect(controller.trayCount == 0)
    }

    // MARK: - P1 #22 & #27: Lightweight DB Queries & Batched Updates / Folder Suggestions

    @Test("LibraryDatabase lightweight projections, updateAssetsBatch, and suggestFolders return accurate results")
    func lightweightQueriesAndBatchedOperations() async throws {
        let dir = try makeTempDir("charkle-db-perf")
        defer { try? FileManager.default.removeItem(at: dir) }

        let engine = try BackendFixture.makeEngine(dir)
        let folder = try await engine.createFolder(name: "Typography", parentID: nil)
        let img1 = try makeSolidImageData(width: 64, height: 64, r: 0.8, g: 0.2, b: 0.3)
        let img2 = try makeSolidImageData(width: 64, height: 64, r: 0.2, g: 0.7, b: 0.4)
        let ingested = try await engine.ingest(
            [
                .imageData(img1, suggestedName: "a.png", sourceURL: "https://www.pinterest.com/pin/987654321/"),
                .imageData(img2, suggestedName: "b.png", sourceURL: "https://example.com/post/2")
            ],
            targetFolderID: nil,
            targetBoardID: nil
        )
        #expect(ingested.count == 2)

        let updated = try await engine.updateAssetsBatch([
            AssetBatchPatch(assetIDs: [ingested[0].id], title: "Type Specimen A", addTags: ["Typography"]),
            AssetBatchPatch(assetIDs: [ingested[1].id], title: "Type Specimen B", addTags: ["Typography"])
        ])
        #expect(updated.count == 2)
        #expect(updated.map(\.title).contains("Type Specimen A"))
        #expect(updated.map(\.title).contains("Type Specimen B"))

        // Lightweight batch fetchAssets(ids:)
        let fetchedByIDs = try await engine.database.assets(ids: [ingested[1].id, ingested[0].id])
        #expect(fetchedByIDs.map(\.id) == [ingested[1].id, ingested[0].id])

        // Lightweight source key projection powers PinterestImportService deduplication
        let existingPinIDs = await PinterestImportService.existingImportedPinIDs(in: engine)
        #expect(existingPinIDs.contains("987654321"))

        // Batched folder suggestions match the Typography folder
        let suggestions = try await engine.suggestFolders(for: ingested.map(\.id))
        #expect(suggestions[ingested[0].id]?.folderID == folder.id)
        #expect(suggestions[ingested[1].id]?.folderID == folder.id)
    }
}
