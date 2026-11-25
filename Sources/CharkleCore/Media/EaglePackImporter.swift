import Foundation

/// Summary returned after importing an `.eaglepack` archive or `.library` material package.
public struct MaterialPackageImportResult: Equatable, Sendable {
    public let packageName: String
    public let importedAssets: [AssetRecord]
    public let createdFolderCount: Int
    public let rootFolderID: UUID?
    public let skippedDeletedCount: Int
    public let skippedMissingCount: Int

    public init(
        packageName: String,
        importedAssets: [AssetRecord],
        createdFolderCount: Int,
        rootFolderID: UUID?,
        skippedDeletedCount: Int = 0,
        skippedMissingCount: Int = 0
    ) {
        self.packageName = packageName
        self.importedAssets = importedAssets
        self.createdFolderCount = createdFolderCount
        self.rootFolderID = rootFolderID
        self.skippedDeletedCount = skippedDeletedCount
        self.skippedMissingCount = skippedMissingCount
    }
}

public enum EaglePackImportError: LocalizedError, Sendable {
    case unsupportedPackage(String)
    case unsafeArchivePath(String)
    case extractionFailed(String)
    case emptyPackage(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedPackage(let name):
            return "「\(name)」不是有效的 .eaglepack 素材包或 .library 素材库。"
        case .unsafeArchivePath(let path):
            return "素材包内包含不安全的路径条目（\(path)），已拒绝导入。"
        case .extractionFailed(let detail):
            return "解压素材包失败：\(detail)"
        case .emptyPackage(let name):
            return "素材包「\(name)」中没有可导入的有效素材。"
        }
    }
}

public nonisolated struct ParsedEagleFolder: Equatable, Sendable {
    public let sourceID: String
    public let name: String
    public let colorHex: String?
    public let children: [ParsedEagleFolder]

    public init(
        sourceID: String,
        name: String,
        colorHex: String? = nil,
        children: [ParsedEagleFolder] = []
    ) {
        self.sourceID = sourceID
        self.name = name
        self.colorHex = colorHex
        self.children = children
    }
}

public nonisolated struct ParsedEagleAsset: Equatable, Sendable {
    public let sourceID: String
    public let title: String
    public let fileURL: URL?
    public let thumbnailURL: URL?
    public let isWebBookmark: Bool
    public let sourceURL: URL?
    public let tags: [String]
    public let rating: Int
    public let notes: String
    public let folderIDs: [String]
    public let createdAt: Date?
    public let updatedAt: Date?

    public init(
        sourceID: String,
        title: String,
        fileURL: URL?,
        thumbnailURL: URL? = nil,
        isWebBookmark: Bool = false,
        sourceURL: URL? = nil,
        tags: [String] = [],
        rating: Int = 0,
        notes: String = "",
        folderIDs: [String] = [],
        createdAt: Date? = nil,
        updatedAt: Date? = nil
    ) {
        self.sourceID = sourceID
        self.title = title
        self.fileURL = fileURL
        self.thumbnailURL = thumbnailURL
        self.isWebBookmark = isWebBookmark
        self.sourceURL = sourceURL
        self.tags = tags
        self.rating = rating
        self.notes = notes
        self.folderIDs = folderIDs
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public nonisolated struct ParsedEaglePackage: Sendable {
    public let packageName: String
    public let rootFolders: [ParsedEagleFolder]
    public let items: [ParsedEagleAsset]
    public let skippedDeletedCount: Int
    public let skippedMissingCount: Int
    /// Temporary extraction folder owned by caller (must be removed after all files are copied into storage).
    public let stagingDirectoryToCleanup: URL?

    public init(
        packageName: String,
        rootFolders: [ParsedEagleFolder],
        items: [ParsedEagleAsset],
        skippedDeletedCount: Int,
        skippedMissingCount: Int,
        stagingDirectoryToCleanup: URL?
    ) {
        self.packageName = packageName
        self.rootFolders = rootFolders
        self.items = items
        self.skippedDeletedCount = skippedDeletedCount
        self.skippedMissingCount = skippedMissingCount
        self.stagingDirectoryToCleanup = stagingDirectoryToCleanup
    }
}

/// Lossless reader & safe extractor for `.eaglepack` archives (ZIP) and `.library` / extracted pack directories.
/// Preserves nested folder hierarchies, folder colors, titles, tags, star ratings, annotations,
/// source URLs, creation/modification timestamps, and offline `.url` web bookmark thumbnails.
public nonisolated enum EaglePackImporter {
    private static let maxArchiveEntries = 200_000
    private static let maxFolderDepth = 24

    // MARK: - Package Detection

    public static func isEaglePackArchive(_ url: URL) -> Bool {
        let resolved = url.resolvingSymlinksInPath()
        guard resolved.pathExtension.lowercased() == "eaglepack" else { return false }
        let values = try? resolved.resourceValues(forKeys: [.isRegularFileKey])
        return values?.isRegularFile == true
    }

    public static func isEagleLibraryOrExtractedPackDirectory(_ url: URL) -> Bool {
        let resolved = url.resolvingSymlinksInPath()
        let values = try? resolved.resourceValues(forKeys: [.isDirectoryKey])
        guard values?.isDirectory == true else { return false }

        let fm = FileManager.default
        let contentRoot = unwrapSingleTopLevelDirectory(at: resolved)
        if fm.fileExists(atPath: contentRoot.appendingPathComponent("pack.json").path) {
            return true
        }
        let hasRootMeta = fm.fileExists(atPath: contentRoot.appendingPathComponent("metadata.json").path)
        var imagesIsDir: ObjCBool = false
        let hasImagesDir = fm.fileExists(
            atPath: contentRoot.appendingPathComponent("images").path,
            isDirectory: &imagesIsDir
        ) && imagesIsDir.boolValue
        if hasRootMeta && (hasImagesDir || resolved.pathExtension.lowercased() == "library") {
            return true
        }
        return false
    }

    /// Returns `true` when `url` is a `.eaglepack` archive, extracted pack folder, `.library` folder,
    /// or (when `allowGenericZip == true`) a `.zip` containing `pack.json` or `.library` `metadata.json` + `.info/`.
    public static func isRecognizedMaterialPackage(_ url: URL, allowGenericZip: Bool = false) -> Bool {
        if isEaglePackArchive(url) { return true }
        if isEagleLibraryOrExtractedPackDirectory(url) { return true }
        if allowGenericZip {
            let resolved = url.resolvingSymlinksInPath()
            let values = try? resolved.resourceValues(forKeys: [.isRegularFileKey])
            if values?.isRegularFile == true, resolved.pathExtension.lowercased() == "zip" {
                if let entries = try? listZipEntries(at: resolved) {
                    let lowered = entries.map { $0.lowercased() }
                    let hasPack = lowered.contains { $0 == "pack.json" || $0.hasSuffix("/pack.json") }
                    let hasInfo = lowered.contains { $0.contains(".info/") }
                    let hasMeta = lowered.contains { $0 == "metadata.json" || $0.hasSuffix("/metadata.json") }
                    return hasPack || (hasMeta && hasInfo)
                }
            }
        }
        return false
    }

    // MARK: - Unpack & Parse

    @concurrent
    public static func unpackAndParse(
        at rawURL: URL,
        allowGenericZip: Bool = false
    ) async throws -> ParsedEaglePackage {
        let accessed = rawURL.startAccessingSecurityScopedResource()
        defer { if accessed { rawURL.stopAccessingSecurityScopedResource() } }

        let resolved = rawURL.resolvingSymlinksInPath()
        let fallbackName = cleanPackageDisplayName(from: resolved)
        let values = try? resolved.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])

        var stagingDir: URL?
        let packageRoot: URL

        if values?.isDirectory == true {
            guard isEagleLibraryOrExtractedPackDirectory(resolved) else {
                throw EaglePackImportError.unsupportedPackage(resolved.lastPathComponent)
            }
            packageRoot = unwrapSingleTopLevelDirectory(at: resolved)
        } else if values?.isRegularFile == true {
            let ext = resolved.pathExtension.lowercased()
            guard ext == "eaglepack" || (allowGenericZip && ext == "zip") else {
                throw EaglePackImportError.unsupportedPackage(resolved.lastPathComponent)
            }
            try validateZipEntries(at: resolved)
            let tempRoot = FileManager.default.temporaryDirectory
                .appendingPathComponent("charkle-eaglepack-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
            do {
                try extractArchive(at: resolved, to: tempRoot)
            } catch {
                try? FileManager.default.removeItem(at: tempRoot)
                throw error
            }
            stagingDir = tempRoot
            packageRoot = unwrapSingleTopLevelDirectory(at: tempRoot)
        } else {
            throw EaglePackImportError.unsupportedPackage(resolved.lastPathComponent)
        }

        do {
            let parsed = try parseDirectory(
                packageRoot: packageRoot,
                fallbackName: fallbackName,
                stagingDirectoryToCleanup: stagingDir
            )
            if parsed.items.isEmpty && parsed.rootFolders.isEmpty {
                throw EaglePackImportError.emptyPackage(parsed.packageName)
            }
            return parsed
        } catch {
            if let stagingDir {
                try? FileManager.default.removeItem(at: stagingDir)
            }
            throw error
        }
    }

    // MARK: - Pure Parsing Helpers

    private static func parseDirectory(
        packageRoot: URL,
        fallbackName: String,
        stagingDirectoryToCleanup: URL?
    ) throws -> ParsedEaglePackage {
        let fm = FileManager.default
        let standardizedRootPath = packageRoot.standardizedFileURL.path

        let packJSONURL = packageRoot.appendingPathComponent("pack.json")
        let rootMetaJSONURL = packageRoot.appendingPathComponent("metadata.json")

        let packDict: [String: Any]? = loadJSONDictionary(at: packJSONURL)
        let libraryMetaDict: [String: Any]? = loadJSONDictionary(at: rootMetaJSONURL)

        guard packDict != nil || libraryMetaDict != nil else {
            throw EaglePackImportError.unsupportedPackage(fallbackName)
        }

        // 1. Resolve folder hierarchy (supports `pack.json.folder`, `pack.json.folders`, and `.library/metadata.json.folders`)
        var rawRootFolders: [[String: Any]] = []
        if let singleFolder = packDict?["folder"] as? [String: Any] {
            rawRootFolders.append(singleFolder)
        }
        if let packFolders = packDict?["folders"] as? [[String: Any]] {
            rawRootFolders.append(contentsOf: packFolders)
        }
        if rawRootFolders.isEmpty, let libFolders = libraryMetaDict?["folders"] as? [[String: Any]] {
            rawRootFolders.append(contentsOf: libFolders)
        }
        var visitedFolderIDs = Set<String>()
        let rootFolders = parseFolderList(rawRootFolders, depth: 0, visited: &visitedFolderIDs)

        let declaredPackName = (packDict?["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let packageName: String
        if let declaredPackName, !declaredPackName.isEmpty {
            packageName = declaredPackName
        } else if rootFolders.count == 1, !rootFolders[0].name.isEmpty {
            packageName = rootFolders[0].name
        } else {
            packageName = fallbackName
        }

        // 2. Discover all `<ITEM_ID>.info` directories (both at `images/<ID>.info` and root `<ID>.info`)
        var infoDirsByID: [String: URL] = [:]
        var discoveredOrder: [String] = []
        let candidateInfoParents = [
            packageRoot.appendingPathComponent("images", isDirectory: true),
            packageRoot
        ]
        for parent in candidateInfoParents {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: parent.path, isDirectory: &isDir), isDir.boolValue else { continue }
            let entries = (try? fm.contentsOfDirectory(
                at: parent,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
            )) ?? []
            let sorted = entries.sorted {
                $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
            }
            for entry in sorted {
                guard entry.pathExtension.lowercased() == "info" else { continue }
                let rv = try? entry.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard rv?.isDirectory == true, rv?.isSymbolicLink != true else { continue }
                let standardized = entry.standardizedFileURL
                guard isPath(standardized.path, strictlyInside: standardizedRootPath) else { continue }
                let itemID = entry.deletingPathExtension().lastPathComponent
                if infoDirsByID[itemID] == nil {
                    infoDirsByID[itemID] = standardized
                    discoveredOrder.append(itemID)
                }
            }
        }

        // 3. Index manifest items from `pack.json.images[]`
        var packItemByID: [String: [String: Any]] = [:]
        var orderedItemIDs: [String] = []
        var seenItemIDs = Set<String>()

        if let manifestImages = packDict?["images"] as? [[String: Any]] {
            for raw in manifestImages {
                let rawID = (raw["id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard !rawID.isEmpty else { continue }
                if packItemByID[rawID] == nil {
                    packItemByID[rawID] = raw
                }
                if seenItemIDs.insert(rawID).inserted {
                    orderedItemIDs.append(rawID)
                }
            }
        }
        for id in discoveredOrder where seenItemIDs.insert(id).inserted {
            orderedItemIDs.append(id)
        }

        // 4. Merge per-item metadata and resolve actual payload file inside each `<ID>.info` folder
        var items: [ParsedEagleAsset] = []
        items.reserveCapacity(orderedItemIDs.count)
        var skippedDeletedCount = 0
        var skippedMissingCount = 0

        for itemID in orderedItemIDs {
            let infoDir = infoDirsByID[itemID]
            let sidecarMeta: [String: Any]? = infoDir.flatMap {
                loadJSONDictionary(at: $0.appendingPathComponent("metadata.json"))
            }
            let manifestMeta = packItemByID[itemID]
            let merged = mergeMetadata(sidecar: sidecarMeta, manifest: manifestMeta)

            if boolValue(merged["isDeleted"]) == true {
                skippedDeletedCount += 1
                continue
            }

            let ext = stringValue(merged["ext"])?.lowercased() ?? ""
            let rawName = stringValue(merged["name"]) ?? ""

            let resolvedFiles = infoDir.map {
                resolveMediaAndThumbnail(
                    in: $0,
                    rootPath: standardizedRootPath,
                    preferredName: rawName,
                    preferredExt: ext
                )
            } ?? (payload: nil, thumbnail: nil)

            var sourceURL = parsedWebURL(from: stringValue(merged["url"]))
            let effectiveExt = !ext.isEmpty ? ext : (resolvedFiles.payload?.pathExtension.lowercased() ?? "")
            let isBookmark = effectiveExt == "url" || effectiveExt == "webloc"

            if sourceURL == nil, isBookmark, let payload = resolvedFiles.payload {
                if effectiveExt == "url", let data = try? Data(contentsOf: payload) {
                    sourceURL = parseInternetShortcutURL(from: data)
                } else if effectiveExt == "webloc", let data = try? Data(contentsOf: payload) {
                    sourceURL = parseWeblocURL(from: data)
                }
            }

            if isBookmark {
                guard let validBookmarkURL = sourceURL else {
                    skippedMissingCount += 1
                    continue
                }
                let title = !rawName.isEmpty
                    ? rawName
                    : (validBookmarkURL.host() ?? validBookmarkURL.absoluteString)
                items.append(
                    ParsedEagleAsset(
                        sourceID: itemID,
                        title: title,
                        fileURL: resolvedFiles.payload,
                        thumbnailURL: resolvedFiles.thumbnail,
                        isWebBookmark: true,
                        sourceURL: validBookmarkURL,
                        tags: parseStringList(merged["tags"]),
                        rating: parseRating(merged),
                        notes: stringValue(merged["annotation"]) ?? "",
                        folderIDs: parseStringList(merged["folders"]),
                        createdAt: parseEpochDate(merged["btime"]) ?? parseEpochDate(merged["mtime"]),
                        updatedAt: parseEpochDate(merged["modificationTime"])
                            ?? parseEpochDate(merged["lastModified"])
                            ?? parseEpochDate(merged["mtime"])
                    )
                )
                continue
            }

            guard let payloadURL = resolvedFiles.payload else {
                skippedMissingCount += 1
                continue
            }

            // Skip corrupt 0-byte placeholder files
            let fileSize = (try? payloadURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            if fileSize <= 0 {
                skippedMissingCount += 1
                continue
            }

            let title = !rawName.isEmpty
                ? rawName
                : payloadURL.deletingPathExtension().lastPathComponent

            items.append(
                ParsedEagleAsset(
                    sourceID: itemID,
                    title: title,
                    fileURL: payloadURL,
                    thumbnailURL: resolvedFiles.thumbnail,
                    isWebBookmark: false,
                    sourceURL: sourceURL,
                    tags: parseStringList(merged["tags"]),
                    rating: parseRating(merged),
                    notes: stringValue(merged["annotation"]) ?? "",
                    folderIDs: parseStringList(merged["folders"]),
                    createdAt: parseEpochDate(merged["btime"]) ?? parseEpochDate(merged["mtime"]),
                    updatedAt: parseEpochDate(merged["modificationTime"])
                        ?? parseEpochDate(merged["lastModified"])
                        ?? parseEpochDate(merged["mtime"])
                )
            )
        }

        return ParsedEaglePackage(
            packageName: packageName,
            rootFolders: rootFolders,
            items: items,
            skippedDeletedCount: skippedDeletedCount,
            skippedMissingCount: skippedMissingCount,
            stagingDirectoryToCleanup: stagingDirectoryToCleanup
        )
    }

    private static func parseFolderList(
        _ rawList: [[String: Any]],
        depth: Int,
        visited: inout Set<String>
    ) -> [ParsedEagleFolder] {
        guard depth < maxFolderDepth else { return [] }
        var result: [ParsedEagleFolder] = []
        result.reserveCapacity(rawList.count)
        for raw in rawList {
            let rawID = stringValue(raw["id"]) ?? UUID().uuidString
            guard visited.insert(rawID).inserted else { continue }
            let name = stringValue(raw["name"]) ?? "未命名文件夹"
            let color = mapFolderColorHex(stringValue(raw["iconColor"]))
            let rawChildren = raw["children"] as? [[String: Any]] ?? []
            let children = parseFolderList(rawChildren, depth: depth + 1, visited: &visited)
            result.append(
                ParsedEagleFolder(
                    sourceID: rawID,
                    name: name,
                    colorHex: color,
                    children: children
                )
            )
        }
        return result
    }

    private static func resolveMediaAndThumbnail(
        in infoDir: URL,
        rootPath: String,
        preferredName: String,
        preferredExt: String
    ) -> (payload: URL?, thumbnail: URL?) {
        let fm = FileManager.default
        let entries = (try? fm.contentsOfDirectory(
            at: infoDir,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        var regularFiles: [URL] = []
        var thumbnailCandidate: URL?

        for entry in entries {
            let name = entry.lastPathComponent
            let lower = name.lowercased()
            if lower == "metadata.json" || name.hasPrefix(".") || name.hasPrefix("._") {
                continue
            }
            let rv = try? entry.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard rv?.isRegularFile == true, rv?.isSymbolicLink != true else { continue }
            let standardized = entry.standardizedFileURL
            guard isPath(standardized.path, strictlyInside: rootPath) else { continue }

            let stemLower = entry.deletingPathExtension().lastPathComponent.lowercased()
            if stemLower == "_thumbnail" || stemLower.hasSuffix("_thumbnail") {
                if thumbnailCandidate == nil || lower.hasSuffix(".png") {
                    thumbnailCandidate = standardized
                }
                continue
            }
            regularFiles.append(standardized)
        }

        guard !regularFiles.isEmpty else {
            return (nil, thumbnailCandidate)
        }

        // 1. Exact `<name>.<ext>` (or `<name>` when ext is empty)
        if !preferredName.isEmpty {
            let expectedFile = preferredExt.isEmpty ? preferredName : "\(preferredName).\(preferredExt)"
            if let exact = regularFiles.first(where: { $0.lastPathComponent == expectedFile }) {
                return (exact, thumbnailCandidate)
            }
            let sanitized = sanitizeCrossPlatformFileName(expectedFile)
            if let matched = regularFiles.first(where: {
                $0.lastPathComponent.caseInsensitiveCompare(expectedFile) == .orderedSame
                    || $0.lastPathComponent.caseInsensitiveCompare(sanitized) == .orderedSame
            }) {
                return (matched, thumbnailCandidate)
            }
        }

        // 2. Extension match (largest regular file when multiple exist)
        if !preferredExt.isEmpty {
            let extMatches = regularFiles.filter { $0.pathExtension.lowercased() == preferredExt }
            if let best = extMatches.max(by: { fileSize($0) < fileSize($1) }) {
                return (best, thumbnailCandidate)
            }
        }

        // 3. Fallback to largest remaining non-metadata, non-thumbnail regular file
        let fallback = regularFiles.max(by: { fileSize($0) < fileSize($1) })
        return (fallback, thumbnailCandidate)
    }

    private static func fileSize(_ url: URL) -> Int {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    }

    private static func sanitizeCrossPlatformFileName(_ raw: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/\\:*?\"<>|")
        return raw.components(separatedBy: forbidden).joined(separator: "_")
    }

    private static func mergeMetadata(sidecar: [String: Any]?, manifest: [String: Any]?) -> [String: Any] {
        var result = manifest ?? [:]
        guard let sidecar else { return result }
        for (key, value) in sidecar {
            if let str = value as? String, str.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if result[key] == nil { result[key] = value }
            } else if let arr = value as? [Any], arr.isEmpty {
                if result[key] == nil { result[key] = value }
            } else if !(value is NSNull) {
                result[key] = value
            }
        }
        return result
    }

    /// Parses Windows `[InternetShortcut]` `.url` bookmark files into a validated `http`/`https` URL.
    public static func parseInternetShortcutURL(from data: Data) -> URL? {
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            return nil
        }
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard line.lowercased().hasPrefix("url=") else { continue }
            let rawURL = String(line.dropFirst(4)).trimmingCharacters(in: .whitespacesAndNewlines)
            if let parsed = parsedWebURL(from: rawURL) {
                return parsed
            }
        }
        return nil
    }

    private static func parseWeblocURL(from data: Data) -> URL? {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let raw = plist["URL"] as? String else {
            return nil
        }
        return parsedWebURL(from: raw)
    }

    private static func parsedWebURL(from raw: String?) -> URL? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty,
              let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              (scheme == "http" || scheme == "https"),
              url.host() != nil else {
            return nil
        }
        return url
    }

    /// Parses epoch millisecond or second timestamps into a bounded valid `Date`.
    public static func parseEpochDate(_ raw: Any?) -> Date? {
        let number: Double
        if let d = raw as? Double {
            number = d
        } else if let i = raw as? Int {
            number = Double(i)
        } else if let i64 = raw as? Int64 {
            number = Double(i64)
        } else if let n = raw as? NSNumber {
            number = n.doubleValue
        } else if let s = raw as? String, let parsed = Double(s.trimmingCharacters(in: .whitespacesAndNewlines)) {
            number = parsed
        } else {
            return nil
        }
        guard number.isFinite, number > 0 else { return nil }
        let seconds = number > 10_000_000_000 ? (number / 1000.0) : number
        // Reject implausible dates outside 1990 .. now + 2 days
        let minTimestamp: TimeInterval = 631_152_000
        let maxTimestamp: TimeInterval = Date().timeIntervalSince1970 + 172_800
        guard seconds >= minTimestamp && seconds <= maxTimestamp else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    /// Maps named preset folder color keys or `#RRGGBB` strings to normalized sRGB hex strings.
    public static func mapFolderColorHex(_ raw: String?) -> String? {
        guard let cleaned = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !cleaned.isEmpty else {
            return nil
        }
        if cleaned.hasPrefix("#"), cleaned.count == 7 {
            let hexBody = cleaned.dropFirst()
            if hexBody.allSatisfy({ $0.isHexDigit }) {
                return cleaned.uppercased()
            }
        }
        switch cleaned {
        case "red": return "#EF4444"
        case "orange": return "#F97316"
        case "yellow": return "#EAB308"
        case "green": return "#22C55E"
        case "aqua", "cyan", "teal": return "#06B6D4"
        case "blue": return "#3B82F6"
        case "pink", "rose": return "#EC4899"
        case "brown": return "#A16207"
        case "gray", "grey": return "#64748B"
        default: return nil
        }
    }

    private static func parseRating(_ dict: [String: Any]) -> Int {
        let raw = dict["star"] ?? dict["rating"]
        let value: Int
        if let i = raw as? Int {
            value = i
        } else if let d = raw as? Double, d.isFinite {
            value = Int(d.rounded())
        } else if let n = raw as? NSNumber {
            value = n.intValue
        } else if let s = raw as? String, let parsed = Int(s.trimmingCharacters(in: .whitespacesAndNewlines)) {
            value = parsed
        } else {
            return 0
        }
        return min(5, max(0, value))
    }

    private static func parseStringList(_ raw: Any?) -> [String] {
        guard let arr = raw as? [Any] else { return [] }
        var seen = Set<String>()
        var result: [String] = []
        for entry in arr {
            guard let text = (entry as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty else { continue }
            let key = text.lowercased()
            if seen.insert(key).inserted {
                result.append(text)
            }
        }
        return result
    }

    private static func stringValue(_ raw: Any?) -> String? {
        guard let str = raw as? String else { return nil }
        let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func boolValue(_ raw: Any?) -> Bool? {
        if let b = raw as? Bool { return b }
        if let n = raw as? NSNumber { return n.boolValue }
        if let s = raw as? String {
            switch s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "true", "1", "yes": return true
            case "false", "0", "no": return false
            default: return nil
            }
        }
        return nil
    }

    private static func loadJSONDictionary(at url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return obj
    }

    private static func cleanPackageDisplayName(from url: URL) -> String {
        let stem = url.deletingPathExtension().lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        return stem.isEmpty ? "导入素材包" : stem
    }

    private static func unwrapSingleTopLevelDirectory(at dir: URL) -> URL {
        let fm = FileManager.default
        if fm.fileExists(atPath: dir.appendingPathComponent("pack.json").path)
            || fm.fileExists(atPath: dir.appendingPathComponent("metadata.json").path) {
            return dir
        }
        let children = (try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        let meaningful = children.filter { child in
            let name = child.lastPathComponent
            return name != "__MACOSX" && !name.hasPrefix(".")
        }
        if meaningful.count == 1,
           let only = meaningful.first,
           (try? only.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
           only.pathExtension.lowercased() != "info" {
            return only
        }
        return dir
    }

    private static func isPath(_ candidate: String, strictlyInside root: String) -> Bool {
        let prefix = root.hasSuffix("/") ? root : (root + "/")
        return candidate == root || candidate.hasPrefix(prefix)
    }

    // MARK: - Safe ZIP Validation & Extraction

    private static func listZipEntries(at zipURL: URL) throws -> [String] {
        let result = try runProcess(
            executablePath: "/usr/bin/unzip",
            arguments: ["-Z", "-1", zipURL.path]
        )
        guard result.exitCode == 0 else {
            throw EaglePackImportError.extractionFailed(
                result.stderr.isEmpty ? "无法读取压缩包目录" : result.stderr
            )
        }
        return result.stdout.components(separatedBy: .newlines).filter { !$0.isEmpty }
    }

    private static func validateZipEntries(at zipURL: URL) throws {
        // Pre-validate against path traversal (`..` / leading `/`) when `unzip` lists entries cleanly.
        if let entries = try? listZipEntries(at: zipURL) {
            if entries.count > maxArchiveEntries {
                throw EaglePackImportError.extractionFailed("压缩包条目数量超出安全限制（>\(maxArchiveEntries)）")
            }
            for entry in entries {
                let normalized = entry.replacingOccurrences(of: "\\", with: "/")
                if normalized.hasPrefix("/") {
                    throw EaglePackImportError.unsafeArchivePath(entry)
                }
                let components = normalized.split(separator: "/")
                if components.contains("..") {
                    throw EaglePackImportError.unsafeArchivePath(entry)
                }
            }
        }
    }

    private static func extractArchive(at archiveURL: URL, to destinationDir: URL) throws {
        let result = try runProcess(
            executablePath: "/usr/bin/ditto",
            arguments: ["-x", "-k", "--norsrc", "--noextattr", archiveURL.path, destinationDir.path]
        )
        guard result.exitCode == 0 else {
            let detail = !result.stderr.isEmpty ? result.stderr : (!result.stdout.isEmpty ? result.stdout : "exit \(result.exitCode)")
            throw EaglePackImportError.extractionFailed(detail)
        }
    }

    private static func runProcess(
        executablePath: String,
        arguments: [String]
    ) throws -> (exitCode: Int32, stdout: String, stderr: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        try process.run()

        // Drain stdout & stderr concurrently before waitUntilExit to prevent pipe deadlocks on large archives.
        let group = DispatchGroup()
        final class DataBox: @unchecked Sendable { var data = Data() }
        let outBox = DataBox()
        let errBox = DataBox()

        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            outBox.data = outPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            errBox.data = errPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }

        process.waitUntilExit()
        group.wait()

        return (
            process.terminationStatus,
            String(data: outBox.data, encoding: .utf8) ?? "",
            String(data: errBox.data, encoding: .utf8) ?? ""
        )
    }
}
