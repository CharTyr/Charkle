import CharkleCore
import Foundation
import Testing

@Suite("Material Package Importer (.eaglepack & .library)")
struct EaglePackImporterTests {

    private func zipDirectory(_ sourceDir: URL, to archiveURL: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", "--norsrc", "--noextattr", sourceDir.path, archiveURL.path]
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
    }

    private func writeJSON(_ object: Any, to url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url)
    }

    @Test("Imports .eaglepack ZIP losslessly with nested folders, colors, tags, star rating, notes, source URL, timestamps, offline .url bookmark, and skips deleted items & sidecar thumbnails")
    func importFullEaglePackArchive() async throws {
        let root = try BackendFixture.directory()
        defer { try? FileManager.default.removeItem(at: root) }

        let packSource = root.appending(path: "pack-build", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: packSource, withIntermediateDirectories: true)

        let btimeMs: Int64 = 1_704_067_200_000 // 2024-01-01T00:00:00Z
        let packManifest: [String: Any] = [
            "folder": [
                "id": "FLD_ROOT",
                "name": "插画灵感包",
                "iconColor": "blue",
                "children": [
                    [
                        "id": "FLD_CHAR",
                        "name": "角色设定",
                        "iconColor": "#F97316",
                        "children": []
                    ],
                    [
                        "id": "FLD_WEB",
                        "name": "参考网站",
                        "iconColor": "aqua",
                        "children": []
                    ]
                ]
            ],
            "images": [
                ["id": "ITEM_ART_01", "name": "夏日立绘"],
                ["id": "ITEM_WEB_02", "name": "设计灵感站"],
                ["id": "ITEM_DEL_03", "name": "已删除草稿"]
            ]
        ]
        try writeJSON(packManifest, to: packSource.appending(path: "pack.json"))

        // Item 1: PNG artwork with sidecar _thumbnail.png (must NOT be imported as a second asset)
        let artInfo = packSource.appending(path: "ITEM_ART_01.info", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: artInfo, withIntermediateDirectories: true)
        let artBytes = try BackendFixture.artwork("#2E6F95")
        try artBytes.write(to: artInfo.appending(path: "夏日立绘.png"))
        try (try BackendFixture.artwork("#111111")).write(to: artInfo.appending(path: "夏日立绘_thumbnail.png"))
        try writeJSON([
            "id": "ITEM_ART_01",
            "name": "夏日立绘",
            "ext": "png",
            "tags": ["插画", "清爽蓝", "插画"],
            "folders": ["FLD_CHAR"],
            "star": 5,
            "annotation": "高饱和夏日逆光参考",
            "url": "https://example.com/art/summer-01",
            "btime": btimeMs,
            "modificationTime": btimeMs + 60_000,
            "isDeleted": false
        ] as [String: Any], to: artInfo.appending(path: "metadata.json"))

        // Item 2: Offline .url web bookmark with pre-rendered _thumbnail.png (must import offline with zero network fetch)
        let webInfo = packSource.appending(path: "ITEM_WEB_02.info", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: webInfo, withIntermediateDirectories: true)
        try Data("[InternetShortcut]\r\nURL=https://example.org/design-guide\r\n".utf8)
            .write(to: webInfo.appending(path: "设计灵感站.url"))
        try (try BackendFixture.artwork("#D97706")).write(to: webInfo.appending(path: "设计灵感站_thumbnail.png"))
        try writeJSON([
            "id": "ITEM_WEB_02",
            "name": "设计灵感站",
            "ext": "url",
            "tags": ["网页", "排版"],
            "folders": ["FLD_WEB"],
            "rating": 4,
            "annotation": "离线书签截图测试",
            "btime": btimeMs + 120_000
        ] as [String: Any], to: webInfo.appending(path: "metadata.json"))

        // Item 3: Deleted item (must be skipped completely)
        let delInfo = packSource.appending(path: "ITEM_DEL_03.info", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: delInfo, withIntermediateDirectories: true)
        try artBytes.write(to: delInfo.appending(path: "已删除草稿.png"))
        try writeJSON([
            "id": "ITEM_DEL_03",
            "name": "已删除草稿",
            "ext": "png",
            "folders": ["FLD_CHAR"],
            "isDeleted": true
        ] as [String: Any], to: delInfo.appending(path: "metadata.json"))

        let archiveURL = root.appending(path: "插画灵感包.eaglepack")
        try zipDirectory(packSource, to: archiveURL)
        #expect(EaglePackImporter.isEaglePackArchive(archiveURL))
        #expect(EaglePackImporter.isRecognizedMaterialPackage(archiveURL))

        let engine = try BackendFixture.makeEngine(root.appending(path: "app-support", directoryHint: .isDirectory))
        let result = try await engine.importMaterialPackage(at: archiveURL, targetFolderID: nil, targetBoardID: nil)

        #expect(result.packageName == "插画灵感包")
        #expect(result.createdFolderCount == 3)
        #expect(result.skippedDeletedCount == 1)
        #expect(result.skippedMissingCount == 0)
        #expect(result.importedAssets.count == 2)

        let folders = try await engine.fetchFolders()
        let rootFolder = try #require(folders.first(where: { $0.name == "插画灵感包" && $0.parentID == nil }))
        #expect(rootFolder.colorHex == "#3B82F6")
        let charFolder = try #require(folders.first(where: { $0.name == "角色设定" && $0.parentID == rootFolder.id }))
        #expect(charFolder.colorHex == "#F97316")
        let webFolder = try #require(folders.first(where: { $0.name == "参考网站" && $0.parentID == rootFolder.id }))
        #expect(webFolder.colorHex == "#06B6D4")
        #expect(result.rootFolderID == rootFolder.id)

        let artAsset = try #require(result.importedAssets.first(where: { $0.title == "夏日立绘" }))
        #expect(artAsset.folderID == charFolder.id)
        #expect(artAsset.rating == 5)
        #expect(artAsset.notes == "高饱和夏日逆光参考")
        #expect(artAsset.sourceURL == "https://example.com/art/summer-01")
        #expect(artAsset.sourceDomain == "example.com")
        #expect(Set(artAsset.tags) == Set(["插画", "清爽蓝"]))
        #expect(abs(artAsset.createdAt.timeIntervalSince1970 - 1_704_067_200) < 2)

        let webAsset = try #require(result.importedAssets.first(where: { $0.title == "设计灵感站" }))
        #expect(webAsset.folderID == webFolder.id)
        #expect(webAsset.mediaKind == .webBookmark)
        #expect(webAsset.rating == 4)
        #expect(webAsset.sourceURL == "https://example.org/design-guide")
        #expect(webAsset.sourceDomain == "example.org")
        #expect(webAsset.notes == "离线书签截图测试")
        #expect(Set(webAsset.tags) == Set(["网页", "排版"]))
    }

    @Test("Drag-dropping an uncompressed .library folder mirrors folders cleanly without importing metadata.json or .info directories")
    func dragDropLibraryBundleDirectlyViaIngest() async throws {
        let root = try BackendFixture.directory()
        defer { try? FileManager.default.removeItem(at: root) }

        let libDir = root.appending(path: "DesignRef.library", directoryHint: .isDirectory)
        let imagesDir = libDir.appending(path: "images", directoryHint: .isDirectory)
        let infoDir = imagesDir.appending(path: "K9ABC123.info", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: infoDir, withIntermediateDirectories: true)

        try writeJSON([
            "folders": [
                ["id": "F1", "name": "界面组件", "children": []],
                ["id": "F2", "name": "海报排版", "children": []]
            ]
        ], to: libDir.appending(path: "metadata.json"))

        // Filename sanitized on disk (`foo_bar.png`) while metadata name contains `/` (`foo/bar`)
        try (try BackendFixture.artwork("#10B981")).write(to: infoDir.appending(path: "foo_bar.png"))
        try (try BackendFixture.artwork("#000000")).write(to: infoDir.appending(path: "_thumbnail.png"))
        try writeJSON([
            "id": "K9ABC123",
            "name": "foo/bar",
            "ext": "png",
            "tags": ["UI", "绿色"],
            "folders": ["F1"],
            "star": 3,
            "annotation": "组件库卡片"
        ] as [String: Any], to: infoDir.appending(path: "metadata.json"))

        #expect(EaglePackImporter.isEagleLibraryOrExtractedPackDirectory(libDir))

        let engine = try BackendFixture.makeEngine(root.appending(path: "app-support", directoryHint: .isDirectory))
        let imported = try await engine.ingest([.fileURL(libDir)], targetFolderID: nil, targetBoardID: nil)

        #expect(imported.count == 1)
        let folders = try await engine.fetchFolders()
        #expect(!folders.contains(where: { $0.name.hasSuffix(".info") || $0.name == "images" }))
        let container = try #require(folders.first(where: { $0.name == "DesignRef" && $0.parentID == nil }))
        let uiFolder = try #require(folders.first(where: { $0.name == "界面组件" && $0.parentID == container.id }))
        #expect(folders.contains(where: { $0.name == "海报排版" && $0.parentID == container.id }))

        let item = try #require(imported.first)
        #expect(item.title == "foo/bar")
        #expect(item.folderID == uiFolder.id)
        #expect(item.rating == 3)
        #expect(item.notes == "组件库卡片")
        #expect(Set(item.tags) == Set(["UI", "绿色"]))
    }

    @Test("Helper parsers handle .url INI shortcuts, ms/sec epochs, folder color presets, and reject non-packages")
    func helperParsersAndValidation() async throws {
        let iniData = Data("[InternetShortcut]\nURL=https://charkle.app/showcase?tab=1\n".utf8)
        #expect(EaglePackImporter.parseInternetShortcutURL(from: iniData)?.absoluteString == "https://charkle.app/showcase?tab=1")
        let badScheme = Data("[InternetShortcut]\nURL=file:///etc/passwd\n".utf8)
        #expect(EaglePackImporter.parseInternetShortcutURL(from: badScheme) == nil)

        let msDate = try #require(EaglePackImporter.parseEpochDate(1_704_067_200_000))
        let secDate = try #require(EaglePackImporter.parseEpochDate(1_704_067_200))
        #expect(abs(msDate.timeIntervalSince(secDate)) < 1)
        #expect(EaglePackImporter.parseEpochDate(-100) == nil)

        #expect(EaglePackImporter.mapFolderColorHex("blue") == "#3B82F6")
        #expect(EaglePackImporter.mapFolderColorHex("#12ab34") == "#12AB34")
        #expect(EaglePackImporter.mapFolderColorHex("invalid") == nil)

        let root = try BackendFixture.directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let plainText = root.appending(path: "notes.txt")
        try Data("hello".utf8).write(to: plainText)
        #expect(!EaglePackImporter.isRecognizedMaterialPackage(plainText))
        await #expect(throws: EaglePackImportError.self) {
            _ = try await EaglePackImporter.unpackAndParse(at: plainText)
        }
    }
}
