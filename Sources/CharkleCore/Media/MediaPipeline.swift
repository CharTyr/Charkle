import AVFoundation
import CoreGraphics
import CoreText
import CryptoKit
import Darwin
import Foundation
import ImageIO
import ModelIO
import PDFKit
import QuickLookThumbnailing
import SceneKit
import SceneKit.ModelIO
import Synchronization
import UniformTypeIdentifiers

private nonisolated final class OriginalDirectoryIndex: Sendable {
    private struct State {
        var modSec: Int = -1
        var modNsec: Int = -1
        var ctimeSec: Int = -1
        var ctimeNsec: Int = -1
        var dirSize: Int64 = -1
        var byStem: [String: String] = [:]
        var valid: Bool = false
    }

    private let state = Mutex(State())

    func invalidate() {
        state.withLock { $0.valid = false }
    }

    func lookup(stem: String, in directory: URL) -> URL? {
        var dirStat = stat()
        let statOK = directory.withUnsafeFileSystemRepresentation { path -> Bool in
            guard let path else { return false }
            return stat(path, &dirStat) == 0
        }
        guard statOK else { return nil }

        let modSec = dirStat.st_mtimespec.tv_sec
        let modNsec = dirStat.st_mtimespec.tv_nsec
        let ctimeSec = dirStat.st_ctimespec.tv_sec
        let ctimeNsec = dirStat.st_ctimespec.tv_nsec
        let dirSize = dirStat.st_size

        let cachedName: String?? = state.withLock { st in
            guard st.valid,
                  st.modSec == modSec,
                  st.modNsec == modNsec,
                  st.ctimeSec == ctimeSec,
                  st.ctimeNsec == ctimeNsec,
                  st.dirSize == dirSize else {
                return nil
            }
            return .some(st.byStem[stem])
        }

        if let resolved = cachedName {
            guard let fileName = resolved else { return nil }
            let candidate = directory.appending(path: fileName)
            return MediaPipeline.fileExistsFast(candidate) ? candidate : nil
        }

        let scanned = Self.scanDirectory(directory)
        state.withLock { st in
            st.modSec = modSec
            st.modNsec = modNsec
            st.ctimeSec = ctimeSec
            st.ctimeNsec = ctimeNsec
            st.dirSize = dirSize
            st.byStem = scanned
            st.valid = true
        }
        guard let fileName = scanned[stem] else { return nil }
        let candidate = directory.appending(path: fileName)
        return MediaPipeline.fileExistsFast(candidate) ? candidate : nil
    }

    private static func scanDirectory(_ directory: URL) -> [String: String] {
        var map: [String: String] = [:]
        directory.withUnsafeFileSystemRepresentation { path in
            guard let path, let dir = opendir(path) else { return }
            defer { closedir(dir) }
            while let entryPtr = readdir(dir) {
                let name = withUnsafePointer(to: &entryPtr.pointee.d_name) { ptr in
                    ptr.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN)) { cStr in
                        String(cString: cStr)
                    }
                }
                if name == "." || name == ".." { continue }
                let stem: String
                if let dot = name.lastIndex(of: "."), dot != name.startIndex {
                    stem = String(name[..<dot])
                } else {
                    stem = name
                }
                if map[stem] == nil {
                    map[stem] = name
                }
            }
        }
        return map
    }
}

public nonisolated struct MediaPipeline: Sendable {
    public let directory: URL
    let originals: URL
    let staging: URL
    private let thumbnails: URL
    private let previews: URL
    private let originalIndex = OriginalDirectoryIndex()

    public init(directory: URL) throws {
        self.directory = directory
        originals = directory.appending(path: "Originals", directoryHint: .isDirectory)
        thumbnails = directory.appending(path: "Thumbnails", directoryHint: .isDirectory)
        previews = directory.appending(path: "Previews", directoryHint: .isDirectory)
        staging = directory.appending(path: "Staging", directoryHint: .isDirectory)
        for location in [originals, thumbnails, previews, staging] {
            try FileManager.default.createDirectory(at: location, withIntermediateDirectories: true)
        }
    }

    public static let richLayoutDocumentExtensions: Set<String> = [
        "docx", "doc", "wps",
        "xlsx", "xls", "et", "ods",
        "pptx", "ppt", "dps", "odp",
        "rtf", "pages", "numbers", "key",
        "odt", "epub", "ofd"
    ]

    public static func isRichLayoutDocumentExtension(_ ext: String) -> Bool {
        richLayoutDocumentExtensions.contains(ext.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }

    static func fileExistsFast(_ url: URL) -> Bool {
        url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return false }
            return access(path, F_OK) == 0
        }
    }

    func invalidateOriginalIndex() {
        originalIndex.invalidate()
    }

    public func thumbnailURL(for id: UUID, tier: ThumbnailTier) -> URL? {
        let url = thumbnailPath(id, tier: tier)
        return Self.fileExistsFast(url) ? url : nil
    }

    func thumbnailPath(_ id: UUID, tier: ThumbnailTier = .grid520) -> URL {
        (tier == .grid520 ? thumbnails : previews).appending(path: id.uuidString + ".jpg")
    }

    func originalPath(for asset: AssetRecord) -> URL {
        let ext = (asset.fileName as NSString).pathExtension.lowercased()
        let safe = ext.filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
        let name = asset.id.uuidString + (safe.isEmpty ? "" : "." + safe.prefix(16))
        return originals.appending(path: name)
    }

    public func cachedOriginal(for asset: AssetRecord) -> URL? {
        let url = originalPath(for: asset)
        if Self.fileExistsFast(url) { return url }
        // Drive can rename an existing file's extension while the old cache entry is still useful.
        return originalIndex.lookup(stem: asset.id.uuidString, in: originals)
    }

    func installOriginal(_ source: URL, for asset: AssetRecord, moveSource: Bool = false) throws -> URL {
        let destination = originalPath(for: asset)
        if source == destination { return destination }
        let previous = cachedOriginal(for: asset)
        let fm = FileManager.default
        defer { originalIndex.invalidate() }
        if moveSource {
            if fm.fileExists(atPath: destination.path) {
                _ = try fm.replaceItemAt(destination, withItemAt: source)
            } else {
                try fm.moveItem(at: source, to: destination)
            }
            if let previous, previous != destination { try? fm.removeItem(at: previous) }
            return destination
        }
        let temporary = staging.appending(path: UUID().uuidString)
        try fm.copyItem(at: source, to: temporary)
        defer { try? fm.removeItem(at: temporary) }
        if fm.fileExists(atPath: destination.path) {
            _ = try fm.replaceItemAt(destination, withItemAt: temporary)
        } else {
            try fm.moveItem(at: temporary, to: destination)
        }
        if let previous, previous != destination { try? fm.removeItem(at: previous) }
        return destination
    }

    func removeFiles(for asset: AssetRecord) {
        let orig = cachedOriginal(for: asset)
        for url in [orig, thumbnailURL(for: asset.id, tier: .grid520), thumbnailURL(for: asset.id, tier: .preview1400)].compactMap({ $0 }) {
            try? FileManager.default.removeItem(at: url)
        }
        if orig != nil { originalIndex.invalidate() }
    }

    func removeFiles(forIDs ids: Set<UUID>) throws {
        var removedOriginal = false
        for entry in originalEntries() where ids.contains(entry.id) {
            try removeIfPresent(entry.url)
            removedOriginal = true
        }
        if removedOriginal { originalIndex.invalidate() }
        for id in ids {
            for tier in [ThumbnailTier.grid520, .preview1400] {
                try removeIfPresent(thumbnailPath(id, tier: tier))
            }
        }
    }

    private func removeIfPresent(_ url: URL) throws {
        do { try FileManager.default.removeItem(at: url) }
        catch let error as CocoaError where error.code == .fileNoSuchFile { return }
    }

    static func digests(_ url: URL) throws -> (sha256: String, md5: String, bytes: Int64) {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var sha = SHA256()
        var md5 = Insecure.MD5()
        var size: Int64 = 0
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
            sha.update(data: data)
            md5.update(data: data)
            size += Int64(data.count)
        }
        return (hex(sha.finalize()), hex(md5.finalize()), size)
    }

    static func hex(_ bytes: some Sequence<UInt8>) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    static func mimeType(fileName: String) -> String {
        UTType(filenameExtension: (fileName as NSString).pathExtension)?.preferredMIMEType ?? "application/octet-stream"
    }

    struct Import: Sendable {
        var asset: AssetRecord
        let original: URL
        var parsedDocument: DocumentParserEngine.ParsedDocumentBundle?
    }

    @concurrent
    func ingest(_ input: CaptureInput, folderID: UUID?, id: UUID = UUID()) async throws -> Import {
        let temp = staging.appending(path: id.uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: temp) }
        var title: String?
        var notes = ""
        var source: URL?
        let file: URL
        switch input {
        case .fileURL(let url):
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            let source = url.resolvingSymlinksInPath()
            guard try source.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
                throw LibraryDatabaseError("Select a regular file to import.")
            }
            file = temp.appending(path: Self.cleanFileName(url.lastPathComponent))
            try FileManager.default.copyItem(at: source, to: file)
        case .imageData(let data, let name, let sourceURL):
            let name = Self.cleanFileName(name)
            let type = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary)
                .flatMap(CGImageSourceGetType).flatMap { UTType($0 as String) }
            let given = (name as NSString).pathExtension
            let filename: String
            if given.isEmpty {
                filename = name + "." + (type?.preferredFilenameExtension ?? "png")
            } else if let type, let extensionForType = type.preferredFilenameExtension,
                      UTType(filenameExtension: given) != type, !(given.lowercased() == "apng" && type == .png) {
                filename = (name as NSString).deletingPathExtension + "." + extensionForType
            } else {
                filename = name
            }
            file = temp.appending(path: filename)
            source = sourceURL.flatMap(URL.init(string:))
            try data.write(to: file)
        case .webURL(let url, let suppliedTitle, let suppliedNotes):
            guard WebBookmark.isWebURL(url) else {
                throw LibraryDatabaseError("Unsupported bookmark URL scheme.")
            }
            source = url
            title = suppliedTitle
            notes = suppliedNotes ?? ""
            file = temp.appending(path: Self.cleanName(suppliedTitle ?? url.host() ?? "Bookmark") + ".webloc")
            let data = try PropertyListSerialization.data(fromPropertyList: ["URL": url.absoluteString], format: .xml, options: 0)
            try data.write(to: file)
        case .textSnippet(let name, let text, let sourceURL):
            title = name
            source = sourceURL.flatMap(URL.init(string:))
            file = temp.appending(path: Self.cleanName(name) + ".md")
            try Data(text.utf8).write(to: file)
        case .colorSwatch(let hex, let name):
            let color = LabColor.fromHex(hex)
            title = name ?? color.hex
            file = temp.appending(path: Self.cleanName(title ?? "Swatch") + ".png")
            guard let image = MediaArtwork.swatch(color), let data = MediaArtwork.encode(image, type: .png) else {
                throw LibraryDatabaseError("Could not render color swatch.")
            }
            try data.write(to: file)
        case .socialBookmark(let post, _, _):
            let resolved = ResolvedSocialPost(
                metadata: post,
                primaryMediaDownloadURL: nil,
                primaryMediaKind: nil,
                primaryThumbnailURL: nil
            )
            title = resolved.shortTitle
            notes = post.bodyText
            source = URL(string: post.originalURL)
            file = temp.appending(path: Self.cleanName(resolved.shortTitle) + ".md")
            try Data(resolved.markdownDocument.utf8).write(to: file)
        }

        let mime = Self.mimeType(fileName: file.lastPathComponent)
        let digests = try Self.digests(file)
        var asset = AssetRecord(
            id: id, title: title ?? file.deletingPathExtension().lastPathComponent, fileName: file.lastPathComponent,
            folderID: folderID, contentHash: digests.sha256, mediaKind: MediaKind.detect(fileExtension: file.pathExtension, mimeType: mime),
            mimeType: mime, fileSizeBytes: digests.bytes, sourceURL: source?.absoluteString,
            sourceDomain: source?.host(), notes: notes, isLocalOriginalCached: true
        )
        let parsedDoc = try await render(file, for: &asset, preferredTitle: title)
        return Import(asset: asset, original: try installOriginal(file, for: asset), parsedDocument: parsedDoc)
    }

    /// Creates a `.webloc` web bookmark asset from an already-resolved `WebBookmark` in a single pass
    /// (zero redundant HTTP fetch) and writes high-DPI Retina thumbnails (`720px` grid + `1400px` preview).
    @concurrent
    func ingestPreResolvedWebPage(
        url: URL,
        title: String,
        notes: String,
        domain: String,
        poster: CGImage,
        folderID: UUID?,
        id: UUID = UUID()
    ) async throws -> Import {
        guard WebBookmark.isWebURL(url) else {
            throw LibraryDatabaseError("Unsupported bookmark URL scheme.")
        }
        let temp = staging.appending(path: id.uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: temp) }

        let file = temp.appending(path: Self.cleanName(title.isEmpty ? domain : title) + ".webloc")
        let plistData = try PropertyListSerialization.data(fromPropertyList: ["URL": url.absoluteString], format: .xml, options: 0)
        try plistData.write(to: file)

        let mime = Self.mimeType(fileName: file.lastPathComponent)
        let digests = try Self.digests(file)
        var asset = AssetRecord(
            id: id,
            title: title.isEmpty ? domain : title,
            fileName: file.lastPathComponent,
            folderID: folderID,
            contentHash: digests.sha256,
            mediaKind: .webBookmark,
            mimeType: mime,
            fileSizeBytes: digests.bytes,
            sourceURL: url.absoluteString,
            sourceDomain: domain,
            notes: notes,
            isLocalOriginalCached: true
        )
        try writeCustomPoster(poster, for: &asset)
        return Import(asset: asset, original: try installOriginal(file, for: asset))
    }

    @concurrent
    func refreshed(_ asset: AssetRecord, from file: URL) async throws -> AssetRecord {
        var result = asset
        try await render(file, for: &result, preferredTitle: asset.mediaKind == .webBookmark ? nil : asset.title)
        return result
    }

    @discardableResult
    private func render(_ file: URL, for asset: inout AssetRecord, preferredTitle: String?) async throws -> DocumentParserEngine.ParsedDocumentBundle? {
        let ext = (asset.fileName as NSString).pathExtension.lowercased()
        var render: MediaRender? = nil
        var parsedDocument: DocumentParserEngine.ParsedDocumentBundle? = nil
        switch asset.mediaKind {
        case .image, .animatedImage:
            render = Self.raster(file)
            if ext == "png", let duration = render?.duration, duration > 0 { asset.mediaKind = .animatedImage }
            Self.attachExtractedImageMetadata(from: file, to: &asset)
        case .video:
            render = await Self.video(file)
        case .webBookmark:
            let url = asset.sourceURL.flatMap(URL.init(string:)) ?? WebBookmark.url(in: file)
            asset.sourceURL = url?.absoluteString
            asset.sourceDomain = url.flatMap(WebURLParser.cleanDomain) ?? url?.host()
            // Skip duplicate fetch when specialized GitHub/Social resolvers immediately overwrite the bookmark.
            if let url, GitHubRepoURLParser.parse(url) == nil, SocialPostURLParser.parse(url) == nil {
                let bookmark = await WebBookmark.fetch(url, allowWebViewSnapshot: true)
                let resolvedTitle = preferredTitle ?? bookmark.title ?? WebBookmark.fallbackTitle(for: url)
                asset.title = resolvedTitle
                if asset.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                   let desc = bookmark.description, !desc.isEmpty {
                    asset.notes = desc
                }
                if let poster = bookmark.poster {
                    render = MediaRender(poster)
                } else if let card = MediaArtwork.webPageCard(
                    title: asset.title,
                    domain: asset.sourceDomain ?? url.host() ?? "web.link",
                    siteName: bookmark.siteName,
                    description: bookmark.description ?? asset.notes,
                    urlString: asset.sourceURL,
                    themeColorHex: bookmark.themeColorHex,
                    favicon: bookmark.favicon
                ) {
                    render = MediaRender(card)
                }
            }
        case .document:
            parsedDocument = try? await DocumentParserEngine.parse(
                fileURL: file,
                assetID: asset.id,
                preferredTitle: preferredTitle ?? asset.title,
                performOCRIfScanned: false
            )
            var rich = asset.richMetadata ?? AssetRichMetadata()
            if var docMeta = parsedDocument?.richMetadata {
                // Preserve existing diffSummary if re-rendering an already-stacked version
                if docMeta.diffSummary == nil {
                    docMeta.diffSummary = rich.document?.diffSummary
                }
                rich.document = docMeta
            }
            let plain = parsedDocument?.payload.plainText ?? ""
            if !plain.isEmpty {
                rich.textExcerpt = String(plain.prefix(1_200))
            }
            rich.isMarkdown = (ext == "md" || ext == "markdown")
            asset.richMetadata = rich

            let excerptForAssetRecord = plain.isEmpty ? nil : String(plain.prefix(2_000))
            if ext == "pdf" {
                if let pdfRender = Self.pdf(file) {
                    render = MediaRender(
                        pdfRender.poster,
                        width: pdfRender.width,
                        height: pdfRender.height,
                        duration: pdfRender.duration,
                        text: excerptForAssetRecord ?? pdfRender.text
                    )
                } else if let ql = await Self.quickLook(file, scale: 2), ql.width >= 160, ql.height >= 160 {
                    render = MediaRender(ql.poster, width: ql.width, height: ql.height, text: excerptForAssetRecord)
                }
            } else if Self.isRichLayoutDocumentExtension(ext) {
                if let ql = await Self.quickLook(file, scale: 2), ql.width >= 160, ql.height >= 160 {
                    render = MediaRender(
                        ql.poster,
                        width: ql.width,
                        height: ql.height,
                        text: excerptForAssetRecord
                    )
                } else if let docCard = MediaArtwork.documentCard(
                    title: asset.title,
                    fileExtension: ext,
                    payload: parsedDocument?.payload,
                    firstPageImage: nil,
                    versionStack: rich.versionStack
                ) {
                    render = MediaRender(docCard, text: excerptForAssetRecord)
                }
            } else {
                if let docCard = MediaArtwork.documentCard(
                    title: asset.title,
                    fileExtension: ext,
                    payload: parsedDocument?.payload,
                    firstPageImage: nil,
                    versionStack: rich.versionStack
                ) {
                    render = MediaRender(docCard, text: excerptForAssetRecord)
                } else if let ql = await Self.quickLook(file, scale: 2), ql.width >= 160, ql.height >= 160 {
                    render = MediaRender(ql.poster, width: ql.width, height: ql.height, text: excerptForAssetRecord)
                }
            }
        case .designFile:
            render = Self.raster(file)
            if render == nil { render = await Self.quickLook(file) }
            if render == nil, ext == "svg" { render = SVGPreview.render(file).map { MediaRender($0) } }
            Self.attachExtractedImageMetadata(from: file, to: &asset)
        case .audio:
            let audio = await Self.audio(file)
            asset.durationSeconds = audio.duration
            asset.waveformPeaks = audio.peaks
        case .model3D:
            var rich = asset.richMetadata ?? AssetRichMetadata()
            rich.model3DFormat = ext.uppercased()
            asset.richMetadata = rich
            render = await Self.model3D(file, title: asset.title, format: ext)
        }
        if let render {
            asset.pixelWidth = render.width
            asset.pixelHeight = render.height
            asset.durationSeconds = render.duration
            if let text = render.text { asset.ocrText = text }
        }
        try autoreleasepool {
            guard let image = render?.poster ?? MediaArtwork.card(title: asset.title, label: asset.sourceDomain ?? asset.mediaKind.localizedLabel,
                                                                     text: asset.notes, waveform: asset.waveformPeaks),
                  let grid = MediaArtwork.resize(image, maxSide: 520),
                  let jpeg = MediaArtwork.encode(grid, type: .jpeg) else {
                throw LibraryDatabaseError("Could not render thumbnail for \(asset.fileName).")
            }
            if render == nil {
                asset.pixelWidth = image.width
                asset.pixelHeight = image.height
            }
            try jpeg.write(to: thumbnailPath(asset.id), options: .atomic)
            let previewPath = thumbnailPath(asset.id, tier: .preview1400)
            if max(image.width, image.height) > 520 {
                let previewImage: CGImage? = if max(image.width, image.height) <= 1_400 && MediaArtwork.isOpaque(image) {
                    image
                } else {
                    MediaArtwork.resize(image, maxSide: 1_400)
                }
                if let large = previewImage, let preview = MediaArtwork.encode(large, type: .jpeg) {
                    try preview.write(to: previewPath, options: .atomic)
                } else {
                    try removeIfPresent(previewPath)
                }
            } else {
                try removeIfPresent(previewPath)
            }
            if asset.mediaKind != .audio {
                asset.dominantColors = ColorExtractor.extractDominantColors(from: grid)
            }
        }
        return parsedDocument
    }

    private static func attachExtractedImageMetadata(from file: URL, to asset: inout AssetRecord) {
        let extracted = ImageMetadataExtractor.extract(from: file)
        guard extracted.photoExif != nil || extracted.aiGeneration != nil else { return }
        var rich = asset.richMetadata ?? AssetRichMetadata()
        if let exif = extracted.photoExif { rich.photoExif = exif }
        if let aiGen = extracted.aiGeneration { rich.aiGeneration = aiGen }
        asset.richMetadata = rich
    }

    static func cleanName(_ raw: String) -> String {
        let replaced = raw.components(separatedBy: CharacterSet(charactersIn: "/:\\").union(.controlCharacters))
            .joined(separator: "-").trimmingCharacters(in: .whitespacesAndNewlines)
        let name = String(replaced.prefix(140))
        return name.isEmpty || name == "." || name == ".." ? "Reference" : name
    }

    /// Sanitizes an incoming filename while preserving its trailing extension even when >140 chars.
    static func cleanFileName(_ raw: String) -> String {
        let replaced = raw.components(separatedBy: CharacterSet(charactersIn: "/:\\").union(.controlCharacters))
            .joined(separator: "-").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !replaced.isEmpty, replaced != ".", replaced != ".." else { return "Reference" }
        let ns = replaced as NSString
        let ext = ns.pathExtension
        let validExt = !ext.isEmpty && ext.count <= 16 && ext.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
        if validExt {
            let rawStem = ns.deletingPathExtension.trimmingCharacters(in: .whitespacesAndNewlines)
            let maxStem = max(1, 140 - ext.count - 1)
            let stem = String(rawStem.prefix(maxStem))
            let safeStem = (stem.isEmpty || stem == "." || stem == "..") ? "Reference" : stem
            return "\(safeStem).\(ext)"
        }
        let name = String(replaced.prefix(140))
        return name.isEmpty || name == "." || name == ".." ? "Reference" : name
    }

    static func raster(_ url: URL) -> MediaRender? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        return raster(source)
    }

    static func raster(_ source: CGImageSource) -> MediaRender? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 1_400,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        let orientation = props[kCGImagePropertyOrientation] as? Int ?? 1
        let width = props[kCGImagePropertyPixelWidth] as? Int ?? image.width
        let height = props[kCGImagePropertyPixelHeight] as? Int ?? image.height
        let count = CGImageSourceGetCount(source)
        var seconds = 0.0
        if count > 1 {
            for index in 0..<count {
                let frame = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any] ?? [:]
                if let gif = frame[kCGImagePropertyGIFDictionary] as? [CFString: Any] {
                    seconds += gif[kCGImagePropertyGIFUnclampedDelayTime] as? Double
                        ?? gif[kCGImagePropertyGIFDelayTime] as? Double ?? 0.1
                } else if let png = frame[kCGImagePropertyPNGDictionary] as? [CFString: Any] {
                    seconds += png[kCGImagePropertyAPNGUnclampedDelayTime] as? Double
                        ?? png[kCGImagePropertyAPNGDelayTime] as? Double ?? 0.1
                }
            }
        }
        let swapped = (5...8).contains(orientation)
        return MediaRender(image, width: swapped ? height : width, height: swapped ? width : height,
                           duration: seconds > 0 ? seconds : nil)
    }

    static func videoPosterFrame(_ url: URL) async -> CGImage? {
        await video(url)?.poster
    }

    private static func video(_ url: URL) async -> MediaRender? {
        let asset = AVURLAsset(url: url)
        let duration = try? await asset.load(.duration).seconds
        guard let track = try? await asset.loadTracks(withMediaType: .video).first else { return nil }
        let size = try? await track.load(.naturalSize)
        let transform = try? await track.load(.preferredTransform)
        let area = CGRect(origin: .zero, size: size ?? .zero).applying(transform ?? .identity)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1_400, height: 1_400)
        let time = CMTime(seconds: min(1, max(0, (duration ?? 0).isFinite ? (duration ?? 0) * 0.15 : 0)), preferredTimescale: 600)
        guard let frame = try? await generator.image(at: time) else { return nil }
        let safeW: Int? = (area.width.isFinite && area.width > 0 && area.width < 100_000) ? Int(area.width.rounded()) : nil
        let safeH: Int? = (area.height.isFinite && area.height > 0 && area.height < 100_000) ? Int(area.height.rounded()) : nil
        return MediaRender(frame.image, width: safeW, height: safeH, duration: duration)
    }

    private static func pdf(_ url: URL) -> MediaRender? {
        guard let document = PDFDocument(url: url), let page = document.page(at: 0),
              let reference = page.pageRef else { return nil }
        let bounds = page.bounds(for: .cropBox)
        let maxSide = max(bounds.width, bounds.height)
        guard bounds.width.isFinite, bounds.height.isFinite, bounds.width > 0, bounds.height > 0, maxSide >= 1e-6 else { return nil }
        let scale = 1_400 / maxSide
        guard scale.isFinite, (bounds.width * scale).isFinite, (bounds.height * scale).isFinite else { return nil }
        let width = max(1, min(4_096, Int((bounds.width * scale).rounded())))
        let height = max(1, min(4_096, Int((bounds.height * scale).rounded())))
        guard let context = MediaArtwork.context(width: width, height: height) else { return nil }
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(rect)
        context.concatenate(reference.getDrawingTransform(.cropBox, rect: rect, rotate: 0, preserveAspectRatio: true))
        context.drawPDFPage(reference)
        guard let image = context.makeImage() else { return nil }
        let text = (0..<min(5, document.pageCount)).compactMap { document.page(at: $0)?.string }.joined(separator: "\n")
        let safeBoundsW = bounds.width < 1_000_000 ? Int(bounds.width.rounded()) : width
        let safeBoundsH = bounds.height < 1_000_000 ? Int(bounds.height.rounded()) : height
        return MediaRender(image, width: safeBoundsW, height: safeBoundsH,
                           text: String(text.prefix(8_000)))
    }

    static func quickLook(_ url: URL, scale: CGFloat = 2) async -> MediaRender? {
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 1_400, height: 1_400),
                                                    scale: scale, representationTypes: .thumbnail)
        return await withCheckedContinuation { continuation in
            QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { image, _ in
                continuation.resume(returning: image.map { MediaRender($0.cgImage) })
            }
        }
    }

    func writeCustomPoster(_ image: CGImage, for asset: inout AssetRecord) throws {
        try autoreleasepool {
            guard let grid = MediaArtwork.resize(image, maxSide: 720),
                  let jpeg = MediaArtwork.encode(grid, type: .jpeg) else {
                throw LibraryDatabaseError("Could not encode custom poster thumbnail for \(asset.fileName).")
            }
            asset.pixelWidth = image.width
            asset.pixelHeight = image.height
            try jpeg.write(to: thumbnailPath(asset.id), options: .atomic)
            let previewPath = thumbnailPath(asset.id, tier: .preview1400)
            if max(image.width, image.height) > 720 {
                let previewImage: CGImage? = if max(image.width, image.height) <= 1_400 && MediaArtwork.isOpaque(image) {
                    image
                } else {
                    MediaArtwork.resize(image, maxSide: 1_400)
                }
                if let large = previewImage, let preview = MediaArtwork.encode(large, type: .jpeg) {
                    try preview.write(to: previewPath, options: .atomic)
                } else {
                    try removeIfPresent(previewPath)
                }
            } else {
                try removeIfPresent(previewPath)
            }
            asset.dominantColors = ColorExtractor.extractDominantColors(from: grid)
        }
    }

    private static func model3D(_ url: URL, title: String, format: String) async -> MediaRender? {
        if let ql = await quickLook(url) {
            return ql
        }
        if let rendered = renderModelIOSnapshot(url) {
            return MediaRender(rendered)
        }
        if let card = MediaArtwork.model3DCard(title: title, format: format) {
            return MediaRender(card)
        }
        return nil
    }

    private static func renderModelIOSnapshot(_ url: URL) -> CGImage? {
        let mdlAsset = MDLAsset(url: url)
        guard mdlAsset.count > 0 else { return nil }
        let scene = SCNScene(mdlAsset: mdlAsset)
        let renderer = SCNRenderer(device: nil, options: nil)
        renderer.scene = scene
        renderer.autoenablesDefaultLighting = true
        let (center, radius) = scene.rootNode.boundingSphere
        let camNode = SCNNode()
        camNode.camera = SCNCamera()
        camNode.camera?.automaticallyAdjustsZRange = true
        let dist = max(CGFloat(radius) * 2.6, 2.0)
        let cx = CGFloat(center.x) + dist * 0.6
        let cy = CGFloat(center.y) + dist * 0.45
        let cz = CGFloat(center.z) + dist * 0.85
        camNode.position = SCNVector3(cx, cy, cz)
        camNode.look(at: center)
        scene.rootNode.addChildNode(camNode)
        renderer.pointOfView = camNode
        let snapshot = renderer.snapshot(atTime: 0, with: CGSize(width: 900, height: 900), antialiasingMode: .multisampling4X)
        #if canImport(AppKit)
        return snapshot.cgImage(forProposedRect: nil, context: nil, hints: nil)
        #elseif canImport(UIKit)
        return snapshot.cgImage
        #else
        return nil
        #endif
    }

    private static func audio(_ url: URL) async -> (duration: Double?, peaks: [Float]) {
        let asset = AVURLAsset(url: url)
        let loadedDuration = try? await asset.load(.duration).seconds
        let cleanDuration = loadedDuration.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        if let file = try? AVAudioFile(forReading: url),
           let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 8_192),
           file.length > 0 {
            let frameCount = file.length
            let bars = 48
            var peaks = [Float](repeating: 0, count: bars)
            var offset: AVAudioFramePosition = 0
            while offset < frameCount {
                guard (try? file.read(into: buffer)) != nil, let channels = buffer.floatChannelData,
                      buffer.frameLength > 0 else { break }
                for frame in 0..<Int(buffer.frameLength) {
                    let bin = min(bars - 1, Int((offset + Int64(frame)) * Int64(bars) / frameCount))
                    for channel in 0..<Int(buffer.format.channelCount) {
                        peaks[bin] = max(peaks[bin], min(1, abs(channels[channel][frame])))
                    }
                }
                offset += Int64(buffer.frameLength)
            }
            let fallbackDuration: Double? = {
                let rate = file.fileFormat.sampleRate
                guard rate.isFinite, rate > 0 else { return nil }
                let secs = Double(frameCount) / rate
                return secs.isFinite && secs > 0 ? secs : nil
            }()
            return (cleanDuration ?? fallbackDuration, peaks)
        }
        // Fallback via AVAssetReader for compressed formats AVAudioFile may not decode directly
        if let track = try? await asset.loadTracks(withMediaType: .audio).first,
           let reader = try? AVAssetReader(asset: asset) {
            let outputSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false
            ]
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: outputSettings)
            if reader.canAdd(output) {
                reader.add(output)
                if reader.startReading() {
                    var samples: [Float] = []
                    samples.reserveCapacity(4096)
                    while let sampleBuffer = output.copyNextSampleBuffer(),
                          let block = CMSampleBufferGetDataBuffer(sampleBuffer) {
                        let length = CMBlockBufferGetDataLength(block)
                        let floatCount = length / MemoryLayout<Float>.size
                        let byteCount = floatCount * MemoryLayout<Float>.size
                        if floatCount > 0 {
                            var chunk = [Float](repeating: 0, count: floatCount)
                            let status: OSStatus = chunk.withUnsafeMutableBytes { ptr in
                                guard let base = ptr.baseAddress else { return kCMBlockBufferBadLengthParameterErr }
                                return CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: byteCount, destination: base)
                            }
                            guard status == kCMBlockBufferNoErr else { continue }
                            let strideStep = max(1, floatCount / 64)
                            var peak: Float = 0
                            for i in stride(from: 0, to: floatCount, by: strideStep) {
                                peak = max(peak, min(1, abs(chunk[i])))
                            }
                            samples.append(peak)
                        }
                        if samples.count >= 4096 { break }
                    }
                    if !samples.isEmpty {
                        let bars = 48
                        var peaks = [Float](repeating: 0, count: bars)
                        for (idx, val) in samples.enumerated() {
                            let bin = min(bars - 1, idx * bars / samples.count)
                            peaks[bin] = max(peaks[bin], val)
                        }
                        return (cleanDuration, peaks)
                    }
                }
            }
        }
        return (cleanDuration, [])
    }

    func thumbnailBytes() -> Int64 {
        [thumbnails, previews].flatMap {
            (try? FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        }.reduce(0) { $0 + Self.bytes($1) }
    }

    func originalEntries() -> [(id: UUID, url: URL, bytes: Int64)] {
        ((try? FileManager.default.contentsOfDirectory(at: originals, includingPropertiesForKeys: [.fileSizeKey])) ?? [])
            .compactMap { url in
                UUID(uuidString: url.deletingPathExtension().lastPathComponent).map { ($0, url, Self.bytes(url)) }
            }
    }

    private static func bytes(_ url: URL) -> Int64 {
        Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
    }
}

nonisolated struct MediaRender: Sendable {
    let poster: CGImage
    let width: Int
    let height: Int
    let duration: Double?
    let text: String?

    init(_ poster: CGImage, width: Int? = nil, height: Int? = nil, duration: Double? = nil, text: String? = nil) {
        self.poster = poster
        self.width = width ?? poster.width
        self.height = height ?? poster.height
        self.duration = duration.flatMap { $0.isFinite ? $0 : nil }
        self.text = text
    }
}
