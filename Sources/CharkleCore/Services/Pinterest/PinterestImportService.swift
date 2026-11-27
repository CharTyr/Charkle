import Foundation

public nonisolated struct PinterestBatchImportReport: Sendable {
    public let importedAssets: [AssetRecord]
    public let importedPinIDs: Set<String>
    public let failedPinIDs: [String]
    public let skippedDuplicatePinIDs: Set<String>

    public init(
        importedAssets: [AssetRecord],
        importedPinIDs: Set<String>,
        failedPinIDs: [String],
        skippedDuplicatePinIDs: Set<String>
    ) {
        self.importedAssets = importedAssets
        self.importedPinIDs = importedPinIDs
        self.failedPinIDs = failedPinIDs
        self.skippedDuplicatePinIDs = skippedDuplicatePinIDs
    }
}

/// Where board-organized folders should be created when batch-importing a user's Pinterest collections.
public nonisolated enum PinterestBoardImportDestination: Hashable, Sendable {
    /// Creates or reuses a top-level `"Pinterest"` folder, then creates/reuses one subfolder per board.
    case pinterestRootFolder
    /// Creates or reuses one top-level folder directly in the library root for each board.
    case libraryRoot
    /// Creates or reuses one subfolder per board inside an existing Charkle folder.
    case existingFolder(UUID)
}

public nonisolated struct PinterestBoardImportProgress: Sendable, Equatable {
    public enum Stage: Sendable, Equatable {
        case fetchingPins(boardName: String, fetchedCount: Int)
        case importingPins(boardName: String, completedInBoard: Int, totalInBoard: Int)
    }

    public let boardIndex: Int
    public let totalBoards: Int
    public let stage: Stage
    public let overallImported: Int
    public let overallSkipped: Int
    public let overallFailed: Int

    public init(
        boardIndex: Int,
        totalBoards: Int,
        stage: Stage,
        overallImported: Int,
        overallSkipped: Int,
        overallFailed: Int
    ) {
        self.boardIndex = boardIndex
        self.totalBoards = totalBoards
        self.stage = stage
        self.overallImported = overallImported
        self.overallSkipped = overallSkipped
        self.overallFailed = overallFailed
    }

    public var fractionCompleted: Double {
        guard totalBoards > 0 else { return 0 }
        let base = Double(max(0, boardIndex - 1)) / Double(totalBoards)
        switch stage {
        case .fetchingPins:
            return min(1.0, base + (0.15 / Double(totalBoards)))
        case .importingPins(_, let done, let total):
            let sub = total > 0 ? (Double(done) / Double(total)) : 1.0
            return min(1.0, base + ((0.15 + 0.85 * sub) / Double(totalBoards)))
        }
    }

    public var statusText: String {
        switch stage {
        case .fetchingPins(let name, let fetched):
            return "正在读取画板 \(boardIndex)/\(totalBoards)「\(name)」 · 已发现 \(fetched) 项"
        case .importingPins(let name, let done, let total):
            return "正在导入画板 \(boardIndex)/\(totalBoards)「\(name)」 · \(done)/\(total)"
        }
    }
}

public nonisolated struct PinterestBoardsImportReport: Sendable {
    public let boardsProcessed: Int
    public let foldersCreated: Int
    public let importedAssets: [AssetRecord]
    public let importedPinIDs: Set<String>
    public let skippedDuplicatePinIDs: Set<String>
    public let failedPinIDs: [String]
    public let failedBoardNames: [String]
    public let wasCancelled: Bool

    public init(
        boardsProcessed: Int,
        foldersCreated: Int,
        importedAssets: [AssetRecord],
        importedPinIDs: Set<String>,
        skippedDuplicatePinIDs: Set<String>,
        failedPinIDs: [String],
        failedBoardNames: [String],
        wasCancelled: Bool
    ) {
        self.boardsProcessed = boardsProcessed
        self.foldersCreated = foldersCreated
        self.importedAssets = importedAssets
        self.importedPinIDs = importedPinIDs
        self.skippedDuplicatePinIDs = skippedDuplicatePinIDs
        self.failedPinIDs = failedPinIDs
        self.failedBoardNames = failedBoardNames
        self.wasCancelled = wasCancelled
    }
}

/// Downloads full-resolution originals for selected Pinterest pins from the collection tray
/// and ingests them cleanly into Charkle's library with preserved title, notes, author, board,
/// source URL, and deduplication against previously collected pins.
public nonisolated enum PinterestImportService {
    private static let downloadSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpMaximumConnectionsPerHost = 6
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 60
        config.urlCache = nil
        return URLSession(configuration: config)
    }()

    /// Scans existing non-trashed library assets and returns the set of Pinterest Pin IDs already in Charkle.
    public static func existingImportedPinIDs(in engine: any CharkleEngineProtocol) async -> Set<String> {
        let existing = (try? await engine.fetchAssets(matching: FilterCriteria(includeTrashed: false))) ?? []
        var ids = Set<String>()
        for asset in existing {
            if let source = asset.sourceURL, let pinID = PinterestJSONParser.extractPinID(from: source) {
                ids.insert(pinID)
            }
        }
        return ids
    }

    public static func importPins(
        _ pins: [PinterestPin],
        into engine: any CharkleEngineProtocol,
        targetFolderID: UUID?,
        extraTags: [String] = [],
        skipDuplicates: Bool = true,
        onProgress: (@Sendable (Int, Int) -> Void)? = nil
    ) async -> PinterestBatchImportReport {
        guard !pins.isEmpty else {
            return PinterestBatchImportReport(importedAssets: [], importedPinIDs: [], failedPinIDs: [], skippedDuplicatePinIDs: [])
        }

        let alreadyImported = skipDuplicates ? await existingImportedPinIDs(in: engine) : []
        var skipped = Set<String>()
        var toImport: [PinterestPin] = []
        var seenInBatch = Set<String>()
        for pin in pins {
            guard seenInBatch.insert(pin.id).inserted else { continue }
            if alreadyImported.contains(pin.id) {
                skipped.insert(pin.id)
            } else {
                toImport.append(pin)
            }
        }

        let total = toImport.count
        var completed = 0
        var importedAssets: [AssetRecord] = []
        var importedPinIDs = Set<String>()
        var failedPinIDs: [String] = []

        onProgress?(0, total)

        for pin in toImport {
            if Task.isCancelled { break }
            if let asset = await importSinglePin(
                pin,
                into: engine,
                targetFolderID: targetFolderID,
                extraTags: extraTags
            ) {
                importedAssets.append(asset)
                importedPinIDs.insert(pin.id)
            } else {
                failedPinIDs.append(pin.id)
            }
            completed += 1
            onProgress?(completed, total)
        }

        return PinterestBatchImportReport(
            importedAssets: importedAssets,
            importedPinIDs: importedPinIDs,
            failedPinIDs: failedPinIDs,
            skippedDuplicatePinIDs: skipped
        )
    }

    /// Batch-imports multiple Pinterest Boards into Charkle, creating or reusing a dedicated folder
    /// per Pinterest Board under `destination` so the user's Pinterest hierarchy stays cleanly organized.
    public static func importBoards(
        _ boards: [PinterestBoard],
        into engine: any CharkleEngineProtocol,
        destination: PinterestBoardImportDestination = .pinterestRootFolder,
        extraTags: [String] = [],
        skipDuplicates: Bool = true,
        pinProvider: @Sendable (PinterestBoard, @escaping @Sendable (Int) -> Void) async throws -> [PinterestPin],
        singlePinImporter: (@Sendable (PinterestPin, any CharkleEngineProtocol, UUID?, [String]) async -> AssetRecord?)? = nil,
        onProgress: (@Sendable (PinterestBoardImportProgress) -> Void)? = nil
    ) async -> PinterestBoardsImportReport {
        guard !boards.isEmpty else {
            return PinterestBoardsImportReport(
                boardsProcessed: 0,
                foldersCreated: 0,
                importedAssets: [],
                importedPinIDs: [],
                skippedDuplicatePinIDs: [],
                failedPinIDs: [],
                failedBoardNames: [],
                wasCancelled: false
            )
        }

        var existingFolders = (try? await engine.fetchFolders()) ?? []
        var foldersCreated = 0

        let parentFolderID: UUID?
        switch destination {
        case .pinterestRootFolder:
            if let resolved = await resolveOrCreateFolder(
                named: "Pinterest",
                parentID: nil,
                existingFolders: &existingFolders,
                engine: engine
            ) {
                parentFolderID = resolved.folder.id
                if resolved.created { foldersCreated += 1 }
            } else {
                parentFolderID = nil
            }
        case .libraryRoot:
            parentFolderID = nil
        case .existingFolder(let id):
            parentFolderID = existingFolders.contains(where: { $0.id == id }) ? id : nil
        }

        var knownImportedPinIDs = skipDuplicates ? await existingImportedPinIDs(in: engine) : Set<String>()
        var totalImportedAssets: [AssetRecord] = []
        var totalImportedPinIDs = Set<String>()
        var totalSkippedPinIDs = Set<String>()
        var totalFailedPinIDs: [String] = []
        var failedBoardNames: [String] = []
        var boardsProcessed = 0
        var wasCancelled = false

        let totalBoards = boards.count

        for (index, board) in boards.enumerated() {
            if Task.isCancelled {
                wasCancelled = true
                break
            }
            let boardNum = index + 1
            let sanitizedName = sanitizedFolderName(board.name, fallback: "Pinterest 画板 \(boardNum)")

            let capturedImported = totalImportedAssets.count
            let capturedSkipped = totalSkippedPinIDs.count
            let capturedFailed = totalFailedPinIDs.count
            onProgress?(PinterestBoardImportProgress(
                boardIndex: boardNum,
                totalBoards: totalBoards,
                stage: .fetchingPins(boardName: sanitizedName, fetchedCount: 0),
                overallImported: capturedImported,
                overallSkipped: capturedSkipped,
                overallFailed: capturedFailed
            ))

            let pins: [PinterestPin]
            do {
                pins = try await pinProvider(board) { fetchedCount in
                    onProgress?(PinterestBoardImportProgress(
                        boardIndex: boardNum,
                        totalBoards: totalBoards,
                        stage: .fetchingPins(boardName: sanitizedName, fetchedCount: fetchedCount),
                        overallImported: capturedImported,
                        overallSkipped: capturedSkipped,
                        overallFailed: capturedFailed
                    ))
                }
            } catch {
                failedBoardNames.append(sanitizedName)
                continue
            }

            if Task.isCancelled {
                wasCancelled = true
                break
            }

            // Create/reuse the folder for this Pinterest Board before importing its pins.
            let targetFolderID: UUID?
            if let resolved = await resolveOrCreateFolder(
                named: sanitizedName,
                parentID: parentFolderID,
                existingFolders: &existingFolders,
                engine: engine
            ) {
                targetFolderID = resolved.folder.id
                if resolved.created { foldersCreated += 1 }
            } else {
                targetFolderID = parentFolderID
            }

            // Deduplicate against library + earlier boards in this batch.
            var seenInBoard = Set<String>()
            var pendingPins: [PinterestPin] = []
            for pin in pins {
                guard seenInBoard.insert(pin.id).inserted else { continue }
                if skipDuplicates && knownImportedPinIDs.contains(pin.id) {
                    totalSkippedPinIDs.insert(pin.id)
                } else {
                    pendingPins.append(pin)
                }
            }

            let boardTotal = pendingPins.count
            onProgress?(PinterestBoardImportProgress(
                boardIndex: boardNum,
                totalBoards: totalBoards,
                stage: .importingPins(boardName: sanitizedName, completedInBoard: 0, totalInBoard: boardTotal),
                overallImported: totalImportedAssets.count,
                overallSkipped: totalSkippedPinIDs.count,
                overallFailed: totalFailedPinIDs.count
            ))

            var boardTags = extraTags
            if !boardTags.contains(where: { $0.caseInsensitiveCompare(sanitizedName) == .orderedSame }),
               sanitizedName.count <= 32 {
                boardTags.append(sanitizedName)
            }

            for (pinIdx, pin) in pendingPins.enumerated() {
                if Task.isCancelled {
                    wasCancelled = true
                    break
                }
                let created: AssetRecord?
                if let singlePinImporter {
                    created = await singlePinImporter(pin, engine, targetFolderID, boardTags)
                } else {
                    created = await importSinglePin(
                        pin,
                        into: engine,
                        targetFolderID: targetFolderID,
                        extraTags: boardTags
                    )
                }
                if let created {
                    totalImportedAssets.append(created)
                    totalImportedPinIDs.insert(pin.id)
                    knownImportedPinIDs.insert(pin.id)
                } else {
                    totalFailedPinIDs.append(pin.id)
                }

                onProgress?(PinterestBoardImportProgress(
                    boardIndex: boardNum,
                    totalBoards: totalBoards,
                    stage: .importingPins(boardName: sanitizedName, completedInBoard: pinIdx + 1, totalInBoard: boardTotal),
                    overallImported: totalImportedAssets.count,
                    overallSkipped: totalSkippedPinIDs.count,
                    overallFailed: totalFailedPinIDs.count
                ))
            }

            if wasCancelled { break }
            boardsProcessed += 1
        }

        return PinterestBoardsImportReport(
            boardsProcessed: boardsProcessed,
            foldersCreated: foldersCreated,
            importedAssets: totalImportedAssets,
            importedPinIDs: totalImportedPinIDs,
            skippedDuplicatePinIDs: totalSkippedPinIDs,
            failedPinIDs: totalFailedPinIDs,
            failedBoardNames: failedBoardNames,
            wasCancelled: wasCancelled
        )
    }

    public static func resolveOrCreateFolder(
        named rawName: String,
        parentID: UUID?,
        existingFolders: inout [FolderRecord],
        engine: any CharkleEngineProtocol
    ) async -> (folder: FolderRecord, created: Bool)? {
        let name = sanitizedFolderName(rawName, fallback: "Pinterest")
        if let existing = existingFolders.first(where: {
            $0.parentID == parentID && $0.name.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(name) == .orderedSame
        }) {
            return (existing, false)
        }
        guard let created = try? await engine.createFolder(name: name, parentID: parentID) else {
            return nil
        }
        existingFolders.append(created)
        return (created, true)
    }

    public static func sanitizedFolderName(_ raw: String, fallback: String) -> String {
        let cleaned = raw
            .replacingOccurrences(of: "/", with: "·")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? fallback : String(cleaned.prefix(64))
    }

    private static func importSinglePin(
        _ pin: PinterestPin,
        into engine: any CharkleEngineProtocol,
        targetFolderID: UUID?,
        extraTags: [String]
    ) async -> AssetRecord? {
        let candidateURLs: [URL] = {
            var list: [URL] = []
            if let video = pin.videoURL { list.append(video) }
            list.append(pin.originalURL)
            if pin.previewURL != pin.originalURL { list.append(pin.previewURL) }
            if pin.thumbnailURL != pin.previewURL && pin.thumbnailURL != pin.originalURL {
                list.append(pin.thumbnailURL)
            }
            return list
        }()

        var downloaded: (data: Data, ext: String, isVideo: Bool)?
        for url in candidateURLs {
            if let result = await fetchMediaBytes(from: url) {
                downloaded = result
                break
            }
        }
        guard let downloaded else { return nil }

        let baseTitle = sanitizedFileStem(pin.displayTitle, fallback: "Pinterest-\(pin.id)")
        let fileName = "\(baseTitle).\(downloaded.ext)"

        let input: CaptureInput
        var tempVideoURL: URL?
        defer {
            if let tempVideoURL { try? FileManager.default.removeItem(at: tempVideoURL) }
        }

        if downloaded.isVideo {
            let tmp = FileManager.default.temporaryDirectory
                .appending(path: "charkle-pin-\(pin.id)-\(UUID().uuidString).\(downloaded.ext)")
            guard (try? downloaded.data.write(to: tmp, options: .atomic)) != nil else { return nil }
            tempVideoURL = tmp
            input = .fileURL(tmp)
        } else {
            input = .imageData(
                downloaded.data,
                suggestedName: fileName,
                sourceURL: pin.pinPageURL.absoluteString
            )
        }

        guard let created = (try? await engine.ingest([input], targetFolderID: targetFolderID, targetBoardID: nil))?.first else {
            return nil
        }

        let notes = composeNotes(for: pin)
        var tags: [String] = ["Pinterest"]
        if let board = pin.boardName?.trimmingCharacters(in: .whitespacesAndNewlines), !board.isEmpty, board.count <= 32 {
            tags.append(board)
        }
        tags.append(contentsOf: extraTags)

        let patch = AssetBatchPatch(
            assetIDs: [created.id],
            title: pin.displayTitle,
            notes: notes.isEmpty ? nil : notes,
            sourceURL: pin.pinPageURL.absoluteString,
            addTags: tags
        )
        return (try? await engine.updateAssets(patch))?.first ?? created
    }

    private static func fetchMediaBytes(from url: URL) async -> (data: Data, ext: String, isVideo: Bool)? {
        guard WebBookmark.isSafeRemoteFetchURL(url) else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue("https://www.pinterest.com/", forHTTPHeaderField: "Referer")
        request.setValue("Charkle/1.5.0 (+https://charkle.app)", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await downloadSession.data(for: request),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              !data.isEmpty,
              data.count <= 90 * 1024 * 1024 else {
            return nil
        }
        let mime = http.mimeType?.lowercased() ?? ""
        if mime.contains("text/html") || mime.contains("application/json") {
            return nil
        }
        let pathExt = url.pathExtension.lowercased()
        let isVideo = mime.contains("video/") || pathExt == "mp4" || pathExt == "mov"
        let ext: String
        if isVideo {
            ext = pathExt == "mov" ? "mov" : "mp4"
        } else if mime.contains("png") || pathExt == "png" {
            ext = "png"
        } else if mime.contains("webp") || pathExt == "webp" {
            ext = "webp"
        } else if mime.contains("gif") || pathExt == "gif" {
            ext = "gif"
        } else {
            ext = "jpg"
        }
        return (data, ext, isVideo)
    }

    public static func composeNotes(for pin: PinterestPin) -> String {
        var lines: [String] = []
        let desc = pin.descriptionText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !desc.isEmpty && desc != pin.title {
            lines.append(desc)
        }
        var metaParts: [String] = []
        if let pinner = pin.pinnerName?.trimmingCharacters(in: .whitespacesAndNewlines), !pinner.isEmpty {
            metaParts.append("作者：\(pinner)")
        }
        if let board = pin.boardName?.trimmingCharacters(in: .whitespacesAndNewlines), !board.isEmpty {
            metaParts.append("画板：\(board)")
        }
        if let extLink = pin.externalLinkURL {
            metaParts.append("来源：\(extLink.absoluteString)")
        }
        if !metaParts.isEmpty {
            lines.append(metaParts.joined(separator: " · "))
        }
        return lines.joined(separator: "\n\n")
    }

    private static func sanitizedFileStem(_ raw: String, fallback: String) -> String {
        let disallowed = CharacterSet(charactersIn: "/:\\*?\"<>|\n\r\t").union(.controlCharacters)
        let cleaned = raw
            .components(separatedBy: disallowed)
            .joined(separator: "-")
            .trimmingCharacters(in: CharacterSet(charactersIn: ". -"))
        let clipped = String(cleaned.prefix(56)).trimmingCharacters(in: CharacterSet(charactersIn: ". -"))
        return clipped.isEmpty ? fallback : clipped
    }
}
