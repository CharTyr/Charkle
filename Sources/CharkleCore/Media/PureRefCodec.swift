import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - PureRef (.pur) Public Data Models & Reports

public nonisolated enum PureRefCodecError: LocalizedError, Sendable {
    case invalidHeader(String)
    case emptyScene(String)
    case encodingFailed(String)
    case imageConversionFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidHeader(let detail):
            return "无法识别的 PureRef (.pur) 场景文件：\(detail)"
        case .emptyScene(let name):
            return "PureRef 场景「\(name)」中没有可导入的图片或便签内容。"
        case .encodingFailed(let detail):
            return "生成 PureRef (.pur) 文件失败：\(detail)"
        case .imageConversionFailed(let name):
            return "导出素材「\(name)」时无法编码为兼容的 PNG 图像。"
        }
    }
}

public nonisolated enum PureRefImageFormat: String, Codable, Equatable, Sendable {
    case png
    case jpeg
    case webp
    case gif

    public var fileExtension: String {
        switch self {
        case .png: "png"
        case .jpeg: "jpg"
        case .webp: "webp"
        case .gif: "gif"
        }
    }

    public var mimeType: String {
        switch self {
        case .png: "image/png"
        case .jpeg: "image/jpeg"
        case .webp: "image/webp"
        case .gif: "image/gif"
        }
    }
}

public nonisolated struct PureRefColor: Codable, Equatable, Hashable, Sendable {
    public var r: Double
    public var g: Double
    public var b: Double
    public var alpha: Double

    public init(r: Double, g: Double, b: Double, alpha: Double = 1.0) {
        self.r = max(0, min(1, r))
        self.g = max(0, min(1, g))
        self.b = max(0, min(1, b))
        self.alpha = max(0, min(1, alpha))
    }

    public static let defaultNoteForeground = PureRefColor(r: 0.94, g: 0.95, b: 0.97, alpha: 1.0)
    public static let defaultNoteBackground = PureRefColor(r: 0.14, g: 0.15, b: 0.18, alpha: 0.88)

    public static func fromNoteStyle(_ style: NoteStyle) -> (foreground: PureRefColor, background: PureRefColor) {
        switch style {
        case .paper:
            return (PureRefColor(r: 0.14, g: 0.15, b: 0.17, alpha: 1.0), PureRefColor(r: 0.97, g: 0.96, b: 0.94, alpha: 0.96))
        case .ink:
            return (PureRefColor(r: 0.95, g: 0.96, b: 0.98, alpha: 1.0), PureRefColor(r: 0.12, g: 0.13, b: 0.16, alpha: 0.95))
        case .warm:
            return (PureRefColor(r: 0.24, g: 0.18, b: 0.11, alpha: 1.0), PureRefColor(r: 0.98, g: 0.93, b: 0.82, alpha: 0.96))
        case .sage:
            return (PureRefColor(r: 0.14, g: 0.22, b: 0.17, alpha: 1.0), PureRefColor(r: 0.88, g: 0.94, b: 0.89, alpha: 0.96))
        case .slate:
            return (PureRefColor(r: 0.14, g: 0.19, b: 0.27, alpha: 1.0), PureRefColor(r: 0.88, g: 0.92, b: 0.97, alpha: 0.96))
        }
    }

    public func inferredNoteStyle() -> NoteStyle {
        let luminance = 0.2126 * r + 0.7152 * g + 0.0722 * b
        if alpha < 0.25 || luminance < 0.35 {
            return .ink
        }
        if r > b + 0.08 && g >= b {
            return .warm
        }
        if g > r + 0.04 && g >= b {
            return .sage
        }
        if b > r + 0.05 {
            return .slate
        }
        return .paper
    }
}

public nonisolated struct PureRefImageBlob: Equatable, Sendable {
    public var index: Int
    public var data: Data
    public var format: PureRefImageFormat
    public var pixelWidth: Int
    public var pixelHeight: Int
    public var sourcePath: String?
    public var displayName: String?

    public init(
        index: Int,
        data: Data,
        format: PureRefImageFormat,
        pixelWidth: Int,
        pixelHeight: Int,
        sourcePath: String? = nil,
        displayName: String? = nil
    ) {
        self.index = index
        self.data = data
        self.format = format
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.sourcePath = sourcePath
        self.displayName = displayName
    }
}

public nonisolated struct PureRefTextNote: Equatable, Sendable {
    public var text: String
    public var centerX: Double
    public var centerY: Double
    public var scale: Double
    public var zLayer: Double
    public var foreground: PureRefColor
    public var background: PureRefColor
    public var childNotes: [PureRefTextNote]

    public init(
        text: String,
        centerX: Double = 0,
        centerY: Double = 0,
        scale: Double = 1.0,
        zLayer: Double = 1.0,
        foreground: PureRefColor = .defaultNoteForeground,
        background: PureRefColor = .defaultNoteBackground,
        childNotes: [PureRefTextNote] = []
    ) {
        self.text = text
        self.centerX = centerX
        self.centerY = centerY
        self.scale = scale
        self.zLayer = zLayer
        self.foreground = foreground
        self.background = background
        self.childNotes = childNotes
    }
}

public nonisolated struct PureRefImagePlacement: Equatable, Sendable {
    public var imageIndex: Int
    public var name: String?
    public var sourcePath: String?
    public var centerX: Double
    public var centerY: Double
    public var width: Double
    public var height: Double
    public var rotationDegrees: Double
    public var flipHorizontal: Bool
    public var flipVertical: Bool
    public var zLayer: Double
    public var crop: NormalizedCropRect?
    public var childNotes: [PureRefTextNote]

    public init(
        imageIndex: Int,
        name: String? = nil,
        sourcePath: String? = nil,
        centerX: Double,
        centerY: Double,
        width: Double,
        height: Double,
        rotationDegrees: Double = 0,
        flipHorizontal: Bool = false,
        flipVertical: Bool = false,
        zLayer: Double = 0,
        crop: NormalizedCropRect? = nil,
        childNotes: [PureRefTextNote] = []
    ) {
        self.imageIndex = imageIndex
        self.name = name
        self.sourcePath = sourcePath
        self.centerX = centerX
        self.centerY = centerY
        self.width = width
        self.height = height
        self.rotationDegrees = rotationDegrees
        self.flipHorizontal = flipHorizontal
        self.flipVertical = flipVertical
        self.zLayer = zLayer
        self.crop = crop
        self.childNotes = childNotes
    }
}

public nonisolated struct PureRefScene: Equatable, Sendable {
    public var formatVersion: String
    public var usedFallbackExtraction: Bool
    public var canvasRect: BoardRect
    public var zoom: Double
    public var viewX: Int32
    public var viewY: Int32
    public var folderLocation: String
    public var images: [PureRefImageBlob]
    public var placements: [PureRefImagePlacement]
    public var notes: [PureRefTextNote]
    public var skippedMissingLinkCount: Int

    public init(
        formatVersion: String = "1.10",
        usedFallbackExtraction: Bool = false,
        canvasRect: BoardRect = BoardRect(x: -10000, y: -10000, width: 20000, height: 20000),
        zoom: Double = 1.0,
        viewX: Int32 = 0,
        viewY: Int32 = 0,
        folderLocation: String = "",
        images: [PureRefImageBlob] = [],
        placements: [PureRefImagePlacement] = [],
        notes: [PureRefTextNote] = [],
        skippedMissingLinkCount: Int = 0
    ) {
        self.formatVersion = formatVersion
        self.usedFallbackExtraction = usedFallbackExtraction
        self.canvasRect = canvasRect
        self.zoom = zoom
        self.viewX = viewX
        self.viewY = viewY
        self.folderLocation = folderLocation
        self.images = images
        self.placements = placements
        self.notes = notes
        self.skippedMissingLinkCount = skippedMissingLinkCount
    }
}

public nonisolated struct PureRefImportResult: Equatable, Sendable {
    public let sceneName: String
    public let formatVersion: String
    public let usedFallbackExtraction: Bool
    public let importedAssets: [AssetRecord]
    public let rootFolderID: UUID?
    public let createdBoardID: UUID?
    public let createdBoardTitle: String?
    public let importedNoteCount: Int
    public let skippedMissingLinkCount: Int

    public init(
        sceneName: String,
        formatVersion: String,
        usedFallbackExtraction: Bool = false,
        importedAssets: [AssetRecord],
        rootFolderID: UUID?,
        createdBoardID: UUID? = nil,
        createdBoardTitle: String? = nil,
        importedNoteCount: Int = 0,
        skippedMissingLinkCount: Int = 0
    ) {
        self.sceneName = sceneName
        self.formatVersion = formatVersion
        self.usedFallbackExtraction = usedFallbackExtraction
        self.importedAssets = importedAssets
        self.rootFolderID = rootFolderID
        self.createdBoardID = createdBoardID
        self.createdBoardTitle = createdBoardTitle
        self.importedNoteCount = importedNoteCount
        self.skippedMissingLinkCount = skippedMissingLinkCount
    }
}

public nonisolated struct PureRefExportReport: Equatable, Sendable {
    public let fileURL: URL
    public let imageCount: Int
    public let placementCount: Int
    public let noteCount: Int
    public let skippedCount: Int
    public let byteCount: Int

    public init(
        fileURL: URL,
        imageCount: Int,
        placementCount: Int,
        noteCount: Int,
        skippedCount: Int = 0,
        byteCount: Int
    ) {
        self.fileURL = fileURL
        self.imageCount = imageCount
        self.placementCount = placementCount
        self.noteCount = noteCount
        self.skippedCount = skippedCount
        self.byteCount = byteCount
    }
}

public nonisolated struct PureRefAssetInput: Sendable {
    public let id: UUID
    public let title: String
    public let fileName: String
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let imageData: Data

    public init(
        id: UUID,
        title: String,
        fileName: String,
        pixelWidth: Int,
        pixelHeight: Int,
        imageData: Data
    ) {
        self.id = id
        self.title = title
        self.fileName = fileName
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.imageData = imageData
    }
}

// MARK: - Bidirectional PureRef (.pur) Binary Codec

public nonisolated enum PureRefCodec {
    private static let headerSize = 224
    private static let pngSignature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
    private static let imageItemTypeUTF16BE = Array("GraphicsImageItem".utf16).flatMap { [UInt8($0 >> 8), UInt8($0 & 0xFF)] }
    private static let textItemTypeUTF16BE = Array("GraphicsTextItem".utf16).flatMap { [UInt8($0 >> 8), UInt8($0 & 0xFF)] }

    public static func isPureRefFileURL(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == "pur"
    }

    // MARK: - Decode (.pur -> PureRefScene)

    public static func decode(contentsOf url: URL) throws -> PureRefScene {
        let data = try Data(contentsOf: url)
        return try decode(data: data, sourceName: url.deletingPathExtension().lastPathComponent)
    }

    public static func decode(data: Data, sourceName: String = "PureRef") throws -> PureRefScene {
        guard data.count >= headerSize else {
            throw PureRefCodecError.invalidHeader("文件过小（\(data.count) 字节）")
        }

        let bytes = [UInt8](data)
        let versionLen = Int(readUInt32BE(bytes, at: 0))
        guard versionLen >= 4, versionLen <= 32, versionLen % 2 == 0, 4 + versionLen <= headerSize else {
            throw PureRefCodecError.invalidHeader("文件头版本号长度异常（\(versionLen)）")
        }
        let versionString = decodeUTF16BE(bytes[4..<(4 + versionLen)])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !versionString.isEmpty, versionString.first?.isNumber == true else {
            throw PureRefCodecError.invalidHeader("版本号不可读")
        }

        // Tier 1: Exact structured QDataStream parser for PureRef 1.x scenes (v1.9 / v1.10 / v1.11.1)
        if versionString.hasPrefix("1.") {
            if let structured = try? decodeV1Structured(bytes: bytes, data: data, version: versionString),
               (!structured.images.isEmpty || !structured.notes.isEmpty) {
                return structured
            }
        }

        // Tier 2: Resilient multi-format embedded image + note extractor for PureRef 2.0+ (PNG/JPEG/WebP/GIF)
        let fallback = decodeResilientV2(bytes: bytes, data: data, version: versionString)
        guard !fallback.images.isEmpty || !fallback.notes.isEmpty else {
            throw PureRefCodecError.emptyScene(sourceName)
        }
        return fallback
    }

    // MARK: - Tier 1: Exact Structured v1.x Parser

    private struct RawV1ImageItem {
        var id: UInt32
        var source: String?
        var name: String?
        var matrix: (m11: Double, m12: Double, m21: Double, m22: Double)
        var x: Double
        var y: Double
        var zLayer: Double
        var xCrop: Double
        var yCrop: Double
        var cropPoints: [(x: Double, y: Double)]
        var childNotes: [PureRefTextNote]
    }

    private static func decodeV1Structured(bytes: [UInt8], data: Data, version: String) throws -> PureRefScene? {
        guard bytes.count >= headerSize else { return nil }
        guard let fileLength = Int(exactly: readUInt64BE(bytes, at: 16)) else { return nil }
        let canvasX = readDoubleBE(bytes, at: 112)
        let canvasY = readDoubleBE(bytes, at: 120)
        let canvasW = readDoubleBE(bytes, at: 128)
        let canvasH = readDoubleBE(bytes, at: 136)
        let zoom = readDoubleBE(bytes, at: 144)
        let viewX = readInt32BE(bytes, at: 216)
        let viewY = readInt32BE(bytes, at: 220)

        let canvasRect = BoardRect(
            x: canvasX.isFinite ? canvasX : -10000,
            y: canvasY.isFinite ? canvasY : -10000,
            width: canvasW.isFinite && canvasW > 0 ? canvasW : 20000,
            height: canvasH.isFinite && canvasH > 0 ? canvasH : 20000
        )

        // Parse reference table located at `fileLength` (20 bytes per entry: UInt32 id + UInt64 start + UInt64 end)
        var refByTransformID: [UInt32: (start: Int, end: Int)] = [:]
        var maxImageEndOffset = headerSize
        if fileLength >= headerSize && fileLength <= bytes.count {
            var refCursor = fileLength
            while refCursor + 20 <= bytes.count {
                let refID = readUInt32BE(bytes, at: refCursor)
                let startOpt = Int(exactly: readUInt64BE(bytes, at: refCursor + 4))
                let endOpt = Int(exactly: readUInt64BE(bytes, at: refCursor + 12))
                refCursor += 20
                if let start = startOpt, let end = endOpt,
                   start >= headerSize && end > start && end <= fileLength {
                    refByTransformID[refID] = (start, end)
                    if end > maxImageEndOffset {
                        maxImageEndOffset = end
                    }
                }
            }
        }

        // Locate the start of the serialized item stream (right after embedded images & 4-byte duplicate refs)
        let searchLimit = (fileLength >= headerSize && fileLength <= bytes.count) ? fileLength : bytes.count
        var cursor = findFirstItemOffset(in: bytes, from: maxImageEndOffset, limit: searchLimit)
            ?? findFirstItemOffset(in: bytes, from: headerSize, limit: searchLimit)
            ?? searchLimit

        var rawImages: [RawV1ImageItem] = []
        var rootNotes: [PureRefTextNote] = []

        while cursor + 12 <= searchLimit {
            let typeLen = Int(readUInt32BE(bytes, at: cursor + 8))
            if typeLen == imageItemTypeUTF16BE.count,
               cursor + 12 + typeLen <= searchLimit,
               Array(bytes[(cursor + 12)..<(cursor + 12 + typeLen)]) == imageItemTypeUTF16BE {
                guard let parsed = parseV1ImageItem(bytes: bytes, cursor: &cursor, limit: searchLimit) else { break }
                rawImages.append(parsed)
            } else if typeLen == textItemTypeUTF16BE.count,
                      cursor + 12 + typeLen <= searchLimit,
                      Array(bytes[(cursor + 12)..<(cursor + 12 + typeLen)]) == textItemTypeUTF16BE {
                guard let parsed = parseV1TextItem(bytes: bytes, cursor: &cursor, limit: searchLimit) else { break }
                rootNotes.append(parsed)
            } else {
                break
            }
        }

        // Read optional folderLocation QString before reference table
        var folderLocation = ""
        if cursor + 4 <= searchLimit {
            let folderLen = Int(readUInt32BE(bytes, at: cursor))
            if folderLen > 0, folderLen % 2 == 0, cursor + 4 + folderLen <= searchLimit {
                folderLocation = decodeUTF16BE(bytes[(cursor + 4)..<(cursor + 4 + folderLen)])
            }
        }

        guard !rawImages.isEmpty || !rootNotes.isEmpty else { return nil }

        // Resolve image blobs per unique embedded start offset (preserving duplicate transform sharing!)
        var imageIndexByPrimaryID: [UInt32: Int] = [:]
        var imageIndexByStartOffset: [Int: Int] = [:]
        var blobs: [PureRefImageBlob] = []
        var skippedMissingLinks = 0

        // Pass 1: materialize all primary (non-duplicate) image payloads
        for raw in rawImages {
            guard let range = refByTransformID[raw.id] else { continue }
            let sliceLen = range.end - range.start
            guard sliceLen > 4 else { continue }

            if let existingIdx = imageIndexByStartOffset[range.start] {
                imageIndexByPrimaryID[raw.id] = existingIdx
                continue
            }

            let blobData = data.subdata(in: range.start..<range.end)
            guard let format = detectImageFormat(in: blobData),
                  let dims = inspectImageDimensions(blobData) else {
                continue
            }
            let idx = blobs.count
            blobs.append(PureRefImageBlob(
                index: idx,
                data: blobData,
                format: format,
                pixelWidth: dims.width,
                pixelHeight: dims.height,
                sourcePath: raw.source,
                displayName: raw.name
            ))
            imageIndexByStartOffset[range.start] = idx
            imageIndexByPrimaryID[raw.id] = idx
        }

        // Pass 2: resolve duplicates (4-byte primary transform ID) and external file links (0xFFFFFFFF)
        var placements: [PureRefImagePlacement] = []
        placements.reserveCapacity(rawImages.count)

        for raw in rawImages {
            var resolvedImageIndex = imageIndexByPrimaryID[raw.id]

            if resolvedImageIndex == nil, let range = refByTransformID[raw.id], range.end - range.start == 4 {
                let refVal = readUInt32BE(bytes, at: range.start)
                if refVal == 0xFFFF_FFFF {
                    // External linked image (not embedded): load from local disk if accessible
                    if let sourcePath = raw.source,
                       !sourcePath.isEmpty,
                       sourcePath != "BruteForceLoaded",
                       FileManager.default.fileExists(atPath: sourcePath),
                       let linkedData = try? Data(contentsOf: URL(fileURLWithPath: sourcePath)),
                       let format = detectImageFormat(in: linkedData),
                       let dims = inspectImageDimensions(linkedData) {
                        let idx = blobs.count
                        blobs.append(PureRefImageBlob(
                            index: idx,
                            data: linkedData,
                            format: format,
                            pixelWidth: dims.width,
                            pixelHeight: dims.height,
                            sourcePath: sourcePath,
                            displayName: raw.name
                        ))
                        resolvedImageIndex = idx
                    } else {
                        skippedMissingLinks += 1
                    }
                } else {
                    resolvedImageIndex = imageIndexByPrimaryID[refVal]
                }
            }

            guard let imageIndex = resolvedImageIndex, imageIndex < blobs.count else { continue }
            let blob = blobs[imageIndex]
            let placement = buildPlacement(from: raw, imageIndex: imageIndex, pixelWidth: blob.pixelWidth, pixelHeight: blob.pixelHeight)
            placements.append(placement)
        }

        return PureRefScene(
            formatVersion: version,
            usedFallbackExtraction: false,
            canvasRect: canvasRect,
            zoom: zoom.isFinite && zoom > 0 ? zoom : 1.0,
            viewX: viewX,
            viewY: viewY,
            folderLocation: folderLocation,
            images: blobs,
            placements: placements,
            notes: rootNotes,
            skippedMissingLinkCount: skippedMissingLinks
        )
    }

    private static func findFirstItemOffset(in bytes: [UInt8], from start: Int, limit: Int) -> Int? {
        let clampedStart = max(headerSize, start)
        guard clampedStart + 12 + textItemTypeUTF16BE.count <= limit else { return nil }
        for offset in clampedStart...(limit - 12 - textItemTypeUTF16BE.count) {
            guard let endAddr = Int(exactly: readUInt64BE(bytes, at: offset)),
                  endAddr > offset + 12, endAddr <= limit else { continue }
            let typeLen = Int(readUInt32BE(bytes, at: offset + 8))
            if typeLen == imageItemTypeUTF16BE.count,
               offset + 12 + typeLen <= limit,
               Array(bytes[(offset + 12)..<(offset + 12 + typeLen)]) == imageItemTypeUTF16BE {
                return offset
            }
            if typeLen == textItemTypeUTF16BE.count,
               offset + 12 + typeLen <= limit,
               Array(bytes[(offset + 12)..<(offset + 12 + typeLen)]) == textItemTypeUTF16BE {
                return offset
            }
        }
        return nil
    }

    private static func parseV1ImageItem(bytes: [UInt8], cursor: inout Int, limit: Int) -> RawV1ImageItem? {
        guard cursor + 12 <= limit else { return nil }
        guard let endAddress = Int(exactly: readUInt64BE(bytes, at: cursor)) else { return nil }
        let typeLen = Int(readUInt32BE(bytes, at: cursor + 8))
        guard endAddress > cursor + 12 + typeLen, endAddress <= limit else { return nil }

        var pos = cursor + 12 + typeLen

        // Optional BruteForceLoaded zero marker (or empty source QString)
        var bruteForceLoaded = false
        if pos + 4 <= endAddress, readUInt32BE(bytes, at: pos) == 0 {
            bruteForceLoaded = true
            pos += 4
        }

        var source = readOptionalQString(bytes, pos: &pos, limit: endAddress)
        var name: String? = bruteForceLoaded ? nil : readOptionalQString(bytes, pos: &pos, limit: endAddress)
        if bruteForceLoaded, let first = source, first != "BruteForceLoaded" {
            name = first
            source = nil
        }

        // Unknown 8-byte double (1.0)
        pos += 8
        guard pos + 48 + 16 + 8 + 4 + 8 <= endAddress else {
            cursor = endAddress
            return nil
        }

        let matrix = readMatrix6Doubles(bytes, pos: &pos)
        let x = readDoubleBE(bytes, at: pos); pos += 8
        let y = readDoubleBE(bytes, at: pos); pos += 8
        pos += 8 // second 1.0 double
        let id = readUInt32BE(bytes, at: pos); pos += 4
        let zLayer = readDoubleBE(bytes, at: pos); pos += 8

        var xCrop = 0.0
        var yCrop = 0.0
        var cropPoints: [(Double, Double)] = []
        var childCount = 0

        if pos + 48 + 24 + 4 <= endAddress {
            _ = readMatrix6Doubles(bytes, pos: &pos) // matrixBeforeCrop
            xCrop = readDoubleBE(bytes, at: pos); pos += 8
            yCrop = readDoubleBE(bytes, at: pos); pos += 8
            _ = readDoubleBE(bytes, at: pos); pos += 8 // scaleCrop

            let pointCount = Int(readUInt32BE(bytes, at: pos)); pos += 4
            if pointCount > 0 && pointCount <= 64 {
                for _ in 0..<pointCount {
                    guard pos + 20 <= endAddress else { break }
                    pos += 4 // QPainterPath element type (0 = MoveTo, 1 = LineTo)
                    let px = readDoubleBE(bytes, at: pos); pos += 8
                    let py = readDoubleBE(bytes, at: pos); pos += 8
                    cropPoints.append((px, py))
                }
            }
            // 21 trailing bytes before UInt32 children count
            if pos + 25 <= endAddress {
                childCount = Int(readUInt32BE(bytes, at: pos + 21))
            }
        }

        cursor = endAddress
        var children: [PureRefTextNote] = []
        if childCount > 0 && childCount <= 256 {
            for _ in 0..<childCount {
                guard let child = parseV1TextItem(bytes: bytes, cursor: &cursor, limit: limit) else { break }
                children.append(child)
            }
        }

        return RawV1ImageItem(
            id: id,
            source: source,
            name: name,
            matrix: matrix,
            x: x.isFinite ? x : 0,
            y: y.isFinite ? y : 0,
            zLayer: zLayer.isFinite ? zLayer : 0,
            xCrop: xCrop.isFinite ? xCrop : 0,
            yCrop: yCrop.isFinite ? yCrop : 0,
            cropPoints: cropPoints,
            childNotes: children
        )
    }

    private static let maxTextNoteNestingDepth = 16

    private static func parseV1TextItem(bytes: [UInt8], cursor: inout Int, limit: Int, depth: Int = 0) -> PureRefTextNote? {
        guard depth < maxTextNoteNestingDepth, cursor + 12 <= limit else { return nil }
        guard let endAddress = Int(exactly: readUInt64BE(bytes, at: cursor)) else { return nil }
        let typeLen = Int(readUInt32BE(bytes, at: cursor + 8))
        guard endAddress > cursor + 12 + typeLen, endAddress <= limit else { return nil }

        var pos = cursor + 12 + typeLen
        let text = readOptionalQString(bytes, pos: &pos, limit: endAddress) ?? ""
        guard pos + 48 + 16 + 8 + 4 + 8 <= endAddress else {
            cursor = endAddress
            return nil
        }

        let matrix = readMatrix6Doubles(bytes, pos: &pos)
        let x = readDoubleBE(bytes, at: pos); pos += 8
        let y = readDoubleBE(bytes, at: pos); pos += 8
        pos += 8 // 1.0 double
        _ = readUInt32BE(bytes, at: pos); pos += 4 // id
        let zLayer = readDoubleBE(bytes, at: pos); pos += 8

        var fg = PureRefColor.defaultNoteForeground
        var bg = PureRefColor.defaultNoteBackground
        var childCount = 0

        if pos + 9 <= endAddress {
            fg = readQColor(bytes, pos: &pos)
            pos += 2 // QColor pad
        }
        if pos + 9 <= endAddress {
            bg = readQColor(bytes, pos: &pos)
            if pos + 6 <= endAddress {
                childCount = Int(readUInt32BE(bytes, at: pos + 2))
            }
        }

        cursor = endAddress
        var children: [PureRefTextNote] = []
        if childCount > 0 && childCount <= 128 && depth + 1 < maxTextNoteNestingDepth {
            for _ in 0..<childCount {
                guard let child = parseV1TextItem(bytes: bytes, cursor: &cursor, limit: limit, depth: depth + 1) else { break }
                children.append(child)
            }
        }

        let scaleX = hypot(matrix.m11, matrix.m12)
        let scaleY = hypot(matrix.m21, matrix.m22)
        let scale = max(0.2, min(8.0, (scaleX + scaleY) * 0.5))

        return PureRefTextNote(
            text: text,
            centerX: x.isFinite ? x : 0,
            centerY: y.isFinite ? y : 0,
            scale: scale.isFinite ? scale : 1.0,
            zLayer: zLayer.isFinite ? zLayer : 1.0,
            foreground: fg,
            background: bg,
            childNotes: children
        )
    }

    private static func buildPlacement(
        from raw: RawV1ImageItem,
        imageIndex: Int,
        pixelWidth: Int,
        pixelHeight: Int
    ) -> PureRefImagePlacement {
        let baseW = Double(max(1, pixelWidth))
        let baseH = Double(max(1, pixelHeight))

        // Decompose 2x2 linear matrix into scale, rotation, and flip
        let (sx, sy, rotDeg, flipH, flipV) = decomposeMatrix(raw.matrix)

        // Compute crop box from crop polygon if present
        var visibleLocalW = baseW
        var visibleLocalH = baseH
        var crop: NormalizedCropRect?

        if raw.cropPoints.count >= 3 {
            let xs = raw.cropPoints.map(\.x).filter(\.isFinite)
            let ys = raw.cropPoints.map(\.y).filter(\.isFinite)
            if let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max(),
               maxX - minX > 2, maxY - minY > 2 {
                visibleLocalW = maxX - minX
                visibleLocalH = maxY - minY

                let originX = raw.xCrop.isFinite && raw.xCrop != 0 ? raw.xCrop : -baseW * 0.5
                let originY = raw.yCrop.isFinite && raw.yCrop != 0 ? raw.yCrop : -baseH * 0.5
                let norm = NormalizedCropRect(
                    x: (minX - originX) / baseW,
                    y: (minY - originY) / baseH,
                    width: (maxX - minX) / baseW,
                    height: (maxY - minY) / baseH
                ).clamped()
                if norm.isMeaningfulSubregion {
                    crop = norm
                }
            }
        }

        let displayW = max(24, visibleLocalW * sx)
        let displayH = max(24, visibleLocalH * sy)

        return PureRefImagePlacement(
            imageIndex: imageIndex,
            name: raw.name,
            sourcePath: raw.source,
            centerX: raw.x,
            centerY: raw.y,
            width: displayW,
            height: displayH,
            rotationDegrees: rotDeg,
            flipHorizontal: flipH,
            flipVertical: flipV,
            zLayer: raw.zLayer,
            crop: crop,
            childNotes: raw.childNotes
        )
    }

    // MARK: - Tier 2: Resilient Multi-Format Extractor (PureRef 2.0+ PNG / JPEG / WebP / GIF)

    private static func decodeResilientV2(bytes: [UInt8], data: Data, version: String) -> PureRefScene {
        var blobs: [PureRefImageBlob] = []
        var seenHashes = Set<String>()
        var cursor = min(headerSize, bytes.count)
        let count = bytes.count

        while cursor + 12 < count {
            let b0 = bytes[cursor]
            var carved: (data: Data, format: PureRefImageFormat, nextCursor: Int)?

            if b0 == 0x89 && cursor + 8 <= count && bytes[cursor + 1] == 0x50 && bytes[cursor + 2] == 0x4E && bytes[cursor + 3] == 0x47
                && bytes[cursor + 4] == 0x0D && bytes[cursor + 5] == 0x0A && bytes[cursor + 6] == 0x1A && bytes[cursor + 7] == 0x0A {
                if let end = walkPNGEnd(bytes: bytes, start: cursor) {
                    carved = (data.subdata(in: cursor..<end), .png, end)
                }
            } else if b0 == 0xFF && bytes[cursor + 1] == 0xD8 && bytes[cursor + 2] == 0xFF {
                if let end = walkJPEGEnd(bytes: bytes, start: cursor) {
                    carved = (data.subdata(in: cursor..<end), .jpeg, end)
                }
            } else if b0 == 0x52 && bytes[cursor + 1] == 0x49 && bytes[cursor + 2] == 0x46 && bytes[cursor + 3] == 0x46
                        && cursor + 12 <= count
                        && bytes[cursor + 8] == 0x57 && bytes[cursor + 9] == 0x45 && bytes[cursor + 10] == 0x42 && bytes[cursor + 11] == 0x50 {
                let riffSize = Int(readUInt32LE(bytes, at: cursor + 4))
                let end = cursor + 8 + riffSize
                if riffSize >= 12 && end <= count {
                    carved = (data.subdata(in: cursor..<end), .webp, end)
                }
            } else if b0 == 0x47 && bytes[cursor + 1] == 0x49 && bytes[cursor + 2] == 0x46 && bytes[cursor + 3] == 0x38
                        && (bytes[cursor + 4] == 0x37 || bytes[cursor + 4] == 0x39) && bytes[cursor + 5] == 0x61 {
                if let end = walkGIFEnd(bytes: bytes, start: cursor) {
                    carved = (data.subdata(in: cursor..<end), .gif, end)
                }
            }

            if let found = carved,
               found.data.count >= 64,
               let dims = inspectImageDimensions(found.data) {
                let hash = SHA256.hash(data: found.data).map { String(format: "%02x", $0) }.joined()
                if seenHashes.insert(hash).inserted {
                    blobs.append(PureRefImageBlob(
                        index: blobs.count,
                        data: found.data,
                        format: found.format,
                        pixelWidth: dims.width,
                        pixelHeight: dims.height
                    ))
                }
                cursor = max(cursor + 1, found.nextCursor)
            } else {
                cursor += 1
            }
        }

        let placements = autoLayoutPlacements(for: blobs)
        let notes = scanReadableTextNotes(in: bytes)

        return PureRefScene(
            formatVersion: version,
            usedFallbackExtraction: true,
            canvasRect: computeCanvasRect(placements: placements, notes: notes),
            zoom: 1.0,
            viewX: 0,
            viewY: 0,
            folderLocation: "",
            images: blobs,
            placements: placements,
            notes: notes
        )
    }

    /// Strict chunk-by-chunk PNG walker (`length + type(4) + payload(length) + crc(4)` until `IEND`).
    private static func walkPNGEnd(bytes: [UInt8], start: Int) -> Int? {
        var pos = start + 8
        let count = bytes.count
        var sawIHDR = false
        while pos + 12 <= count {
            let chunkLen = Int(readUInt32BE(bytes, at: pos))
            guard chunkLen >= 0, chunkLen <= 128 * 1024 * 1024 else { return nil }
            let t0 = bytes[pos + 4], t1 = bytes[pos + 5], t2 = bytes[pos + 6], t3 = bytes[pos + 7]
            guard isASCIIAlpha(t0), isASCIIAlpha(t1), isASCIIAlpha(t2), isASCIIAlpha(t3) else { return nil }
            let nextPos = pos + 12 + chunkLen
            guard nextPos <= count else { return nil }
            if t0 == 0x49 && t1 == 0x48 && t2 == 0x44 && t3 == 0x52 { // IHDR
                sawIHDR = true
            }
            if t0 == 0x49 && t1 == 0x45 && t2 == 0x4E && t3 == 0x44 { // IEND
                return sawIHDR ? nextPos : nil
            }
            pos = nextPos
        }
        return nil
    }

    /// Strict marker-by-marker JPEG walker handling APP/DQT/SOF/DHT/SOS entropy data until EOI (`FF D9`).
    private static func walkJPEGEnd(bytes: [UInt8], start: Int) -> Int? {
        var pos = start + 2
        let count = bytes.count
        var sawSOF = false
        var sawSOS = false
        while pos + 2 <= count {
            guard bytes[pos] == 0xFF else { return nil }
            while pos < count && bytes[pos] == 0xFF { pos += 1 }
            guard pos < count else { return nil }
            let marker = bytes[pos]
            pos += 1
            if marker == 0xD9 { // EOI
                return (sawSOF && sawSOS) ? pos : nil
            }
            if marker == 0x01 || (marker >= 0xD0 && marker <= 0xD8) {
                continue
            }
            guard pos + 2 <= count else { return nil }
            let segLen = Int(readUInt16BE(bytes, at: pos))
            guard segLen >= 2, pos + segLen <= count else { return nil }
            if (marker >= 0xC0 && marker <= 0xC3) || (marker >= 0xC5 && marker <= 0xC7)
                || (marker >= 0xC9 && marker <= 0xCB) || (marker >= 0xCD && marker <= 0xCF) {
                sawSOF = true
            }
            pos += segLen
            if marker == 0xDA { // SOS -> scan entropy-coded stream skipping FF 00 & RST0..7
                sawSOS = true
                while pos + 1 < count {
                    if bytes[pos] == 0xFF {
                        let next = bytes[pos + 1]
                        if next == 0x00 || (next >= 0xD0 && next <= 0xD7) {
                            pos += 2
                            continue
                        }
                        if next == 0xFF {
                            pos += 1
                            continue
                        }
                        if next == 0xD9 {
                            return sawSOF ? (pos + 2) : nil
                        }
                        break
                    }
                    pos += 1
                }
            }
        }
        return nil
    }

    /// Strict GIF87a/GIF89a block walker until trailer `0x3B`.
    private static func walkGIFEnd(bytes: [UInt8], start: Int) -> Int? {
        let count = bytes.count
        guard start + 13 <= count else { return nil }
        let packed = bytes[start + 10]
        var pos = start + 13
        if (packed & 0x80) != 0 {
            let gctSize = 3 * (1 << (Int(packed & 0x07) + 1))
            pos += gctSize
        }
        guard pos < count else { return nil }

        func skipSubBlocks() -> Bool {
            while pos < count {
                let blockLen = Int(bytes[pos])
                pos += 1
                if blockLen == 0 { return true }
                pos += blockLen
                if pos > count { return false }
            }
            return false
        }

        while pos < count {
            let intro = bytes[pos]
            pos += 1
            if intro == 0x3B {
                return pos
            } else if intro == 0x21 { // Extension
                guard pos < count else { return nil }
                pos += 1 // label
                guard skipSubBlocks() else { return nil }
            } else if intro == 0x2C { // Image descriptor
                guard pos + 9 <= count else { return nil }
                let imgPacked = bytes[pos + 8]
                pos += 9
                if (imgPacked & 0x80) != 0 {
                    let lctSize = 3 * (1 << (Int(imgPacked & 0x07) + 1))
                    pos += lctSize
                }
                guard pos < count else { return nil }
                pos += 1 // LZW min code size
                guard skipSubBlocks() else { return nil }
            } else {
                return nil
            }
        }
        return nil
    }

    private static func scanReadableTextNotes(in bytes: [UInt8]) -> [PureRefTextNote] {
        var notes: [PureRefTextNote] = []
        var seen = Set<String>()
        let needle = textItemTypeUTF16BE
        let count = bytes.count
        guard count > headerSize + needle.count + 8 else { return [] }
        var i = headerSize
        while i + needle.count + 8 < count {
            if bytes[i] == needle[0],
               bytes[i + 1] == needle[1],
               Array(bytes[i..<(i + needle.count)]) == needle {
                var pos = i + needle.count
                if let rawText = readOptionalQString(bytes, pos: &pos, limit: min(count, pos + 16384)) {
                    let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty && seen.insert(trimmed).inserted {
                        notes.append(PureRefTextNote(
                            text: trimmed,
                            centerX: 0,
                            centerY: Double(notes.count) * 140,
                            scale: 1.0,
                            zLayer: Double(notes.count) + 100
                        ))
                    }
                }
                i += needle.count
            } else {
                i += 1
            }
        }
        return notes
    }

    // MARK: - Encode (PureRefScene -> Valid v1.10 .pur with MD5 Checksum)

    public static func encode(_ scene: PureRefScene) throws -> Data {
        guard !scene.images.isEmpty || !scene.notes.isEmpty else {
            throw PureRefCodecError.encodingFailed("场景中没有可导出的图片或便签。")
        }

        // Convert every image blob to valid PNG for 100% PureRef 1.x + 2.x compatibility
        var pngBlobs: [Data] = []
        pngBlobs.reserveCapacity(scene.images.count)
        for img in scene.images {
            if img.format == .png, img.data.count >= 8, Array(img.data.prefix(8)) == pngSignature {
                pngBlobs.append(img.data)
            } else if let converted = convertToPNG(img.data) {
                pngBlobs.append(converted)
            } else {
                throw PureRefCodecError.imageConversionFailed(img.displayName ?? "image_\(img.index)")
            }
        }

        // Group placements by imageIndex so multiple references to one image share 1 embedded PNG
        var placementsByImage: [[Int]] = Array(repeating: [], count: pngBlobs.count)
        for (pIdx, placement) in scene.placements.enumerated() {
            guard placement.imageIndex >= 0 && placement.imageIndex < pngBlobs.count else { continue }
            placementsByImage[placement.imageIndex].append(pIdx)
        }

        // Assign deterministic transform IDs matching PureRef's ordering
        var transformIDByPlacementIndex: [Int: UInt32] = [:]
        var orderedPlacementIndices: [Int] = []
        var nextID: UInt32 = 0
        for group in placementsByImage {
            for pIdx in group {
                transformIDByPlacementIndex[pIdx] = nextID
                orderedPlacementIndices.append(pIdx)
                nextID += 1
            }
        }

        func countNotes(_ list: [PureRefTextNote]) -> UInt32 {
            var total: UInt32 = 0
            for note in list {
                total += 1 + countNotes(note.childNotes)
            }
            return total
        }
        var totalChildNotes: UInt32 = 0
        for pIdx in orderedPlacementIndices {
            totalChildNotes += countNotes(scene.placements[pIdx].childNotes)
        }
        let totalRootNotes = countNotes(scene.notes)
        let imageTransformCount = UInt32(orderedPlacementIndices.count)
        let totalIDCount = imageTransformCount + totalChildNotes + totalRootNotes

        var out: [UInt8] = Array(repeating: 0, count: headerSize)

        // Header fields (224 bytes, Big-Endian)
        writeUInt32BE(&out, at: 0, value: 8)
        let v110 = encodeUTF16BE("1.10")
        out.replaceSubrange(4..<12, with: v110)

        let totalRootItemCount = orderedPlacementIndices.count + scene.notes.count
        writeUInt16BE(&out, at: 12, value: UInt16(min(Int(UInt16.max), totalRootItemCount)))
        writeUInt16BE(&out, at: 14, value: UInt16(min(Int(UInt16.max), orderedPlacementIndices.count)))

        writeUInt32BE(&out, at: 24, value: 12)
        let v1111 = encodeUTF16BE("1.11.1") // 12 bytes
        out.replaceSubrange(28..<40, with: v1111)
        writeUInt32BE(&out, at: 40, value: 64) // MD5 QString byte length

        writeUInt32BE(&out, at: 108, value: totalIDCount)

        let rect = computeCanvasRect(placements: scene.placements, notes: scene.notes)
        writeDoubleBE(&out, at: 112, value: rect.x)
        writeDoubleBE(&out, at: 120, value: rect.y)
        writeDoubleBE(&out, at: 128, value: rect.width)
        writeDoubleBE(&out, at: 136, value: rect.height)

        let zoom = scene.zoom.isFinite && scene.zoom > 0 ? scene.zoom : 1.0
        writeDoubleBE(&out, at: 144, value: zoom)
        writeDoubleBE(&out, at: 176, value: zoom)
        writeDoubleBE(&out, at: 208, value: 1.0)
        writeInt32BE(&out, at: 216, value: scene.viewX)
        writeInt32BE(&out, at: 220, value: scene.viewY)

        // Images section
        var refEntries: [(id: UInt32, start: UInt64, end: UInt64)] = []
        refEntries.reserveCapacity(orderedPlacementIndices.count)

        for (imgIdx, group) in placementsByImage.enumerated() where !group.isEmpty {
            let startOffset = UInt64(out.count)
            out.append(contentsOf: pngBlobs[imgIdx])
            let endOffset = UInt64(out.count)

            let primaryID = transformIDByPlacementIndex[group[0]] ?? 0
            refEntries.append((id: primaryID, start: startOffset, end: endOffset))

            for dupIndex in 1..<group.count {
                let dupStart = UInt64(out.count)
                appendUInt32BE(&out, primaryID)
                let dupEnd = UInt64(out.count)
                let dupID = transformIDByPlacementIndex[group[dupIndex]] ?? 0
                refEntries.append((id: dupID, start: dupStart, end: dupEnd))
            }
        }

        // Items section
        var nextNoteID = imageTransformCount

        func appendTextItem(_ note: PureRefTextNote) {
            let endAddrPos = out.count
            appendUInt64BE(&out, 0)
            appendUInt32BE(&out, UInt32(textItemTypeUTF16BE.count))
            out.append(contentsOf: textItemTypeUTF16BE)

            appendQString(&out, note.text)

            let s = note.scale.isFinite && note.scale > 0 ? note.scale : 1.0
            appendMatrix6Doubles(&out, m11: s, m12: 0, m21: 0, m22: s)
            appendDoubleBE(&out, note.centerX)
            appendDoubleBE(&out, note.centerY)
            appendDoubleBE(&out, 1.0)

            let noteID = nextNoteID
            nextNoteID += 1
            appendUInt32BE(&out, noteID)
            appendDoubleBE(&out, note.zLayer)

            appendQColor(&out, note.foreground)
            appendUInt16BE(&out, 0)
            appendQColor(&out, note.background)
            appendUInt16BE(&out, 0)
            appendUInt32BE(&out, UInt32(note.childNotes.count))

            writeUInt64BE(&out, at: endAddrPos, value: UInt64(out.count))

            for child in note.childNotes {
                appendTextItem(child)
            }
        }

        for pIdx in orderedPlacementIndices {
            let placement = scene.placements[pIdx]
            let img = scene.images[placement.imageIndex]
            let itemID = transformIDByPlacementIndex[pIdx] ?? 0
            let baseW = Double(max(1, img.pixelWidth))
            let baseH = Double(max(1, img.pixelHeight))

            let crop = placement.crop?.clamped()
            let x0 = -baseW * 0.5 + (crop?.x ?? 0.0) * baseW
            let x1 = -baseW * 0.5 + ((crop?.x ?? 0.0) + (crop?.width ?? 1.0)) * baseW
            let y0 = -baseH * 0.5 + (crop?.y ?? 0.0) * baseH
            let y1 = -baseH * 0.5 + ((crop?.y ?? 0.0) + (crop?.height ?? 1.0)) * baseH

            let localW = max(1.0, x1 - x0)
            let localH = max(1.0, y1 - y0)
            let sx = max(0.01, placement.width / localW)
            let sy = max(0.01, placement.height / localH)
            let m = composeMatrix(
                sx: sx,
                sy: sy,
                rotationDegrees: placement.rotationDegrees,
                flipHorizontal: placement.flipHorizontal,
                flipVertical: placement.flipVertical
            )

            let endAddrPos = out.count
            appendUInt64BE(&out, 0)
            appendUInt32BE(&out, UInt32(imageItemTypeUTF16BE.count))
            out.append(contentsOf: imageItemTypeUTF16BE)

            let safeName = (placement.name ?? img.displayName ?? "Image \(itemID + 1)")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let safeSource = (placement.sourcePath ?? img.sourcePath ?? safeName)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            appendQString(&out, safeSource.isEmpty ? "CharkleAsset" : safeSource)
            appendQString(&out, safeName.isEmpty ? "Image \(itemID + 1)" : safeName)

            appendDoubleBE(&out, 1.0)
            appendMatrix6Doubles(&out, m11: m.m11, m12: m.m12, m21: m.m21, m22: m.m22)
            appendDoubleBE(&out, placement.centerX)
            appendDoubleBE(&out, placement.centerY)
            appendDoubleBE(&out, 1.0)

            appendUInt32BE(&out, itemID)
            appendDoubleBE(&out, placement.zLayer)
            appendMatrix6Doubles(&out, m11: 1.0, m12: 0.0, m21: 0.0, m22: 1.0)
            appendDoubleBE(&out, -baseW * 0.5)
            appendDoubleBE(&out, -baseH * 0.5)
            appendDoubleBE(&out, 1.0)

            // 5-vertex closed QPainterPath crop polygon
            let cropPts: [(Double, Double)] = [
                (x0, y0), (x1, y0), (x1, y1), (x0, y1), (x0, y0)
            ]
            appendUInt32BE(&out, UInt32(cropPts.count))
            for (idx, pt) in cropPts.enumerated() {
                appendUInt32BE(&out, idx == 0 ? 0 : 1)
                appendDoubleBE(&out, pt.0)
                appendDoubleBE(&out, pt.1)
            }

            // Standard 21-byte image item footer + child note count
            appendDoubleBE(&out, 0.0)
            appendUInt32BE(&out, 1)
            out.append(0)
            appendInt64BE(&out, -1)
            appendUInt32BE(&out, UInt32(placement.childNotes.count))

            writeUInt64BE(&out, at: endAddrPos, value: UInt64(out.count))

            for child in placement.childNotes {
                appendTextItem(child)
            }
        }

        for note in scene.notes {
            appendTextItem(note)
        }

        // Folder location string + header `file_length` pointer to reference table
        appendQString(&out, scene.folderLocation)
        writeUInt64BE(&out, at: 16, value: UInt64(out.count))

        // Reference table (20 bytes per image transform)
        for entry in refEntries {
            appendUInt32BE(&out, entry.id)
            appendUInt64BE(&out, entry.start)
            appendUInt64BE(&out, entry.end)
        }

        // PureRef integrity checksum: 32-char lowercase MD5 hex of bytes[108...] encoded as UTF-16BE at [44..<108]
        let payloadSlice = Data(out[108...])
        let md5Hex = Insecure.MD5.hash(data: payloadSlice)
            .map { String(format: "%02x", $0) }
            .joined()
        let md5UTF16 = encodeUTF16BE(md5Hex)
        if md5UTF16.count == 64 {
            out.replaceSubrange(44..<108, with: md5UTF16)
        }

        return Data(out)
    }

    // MARK: - Scene Builders (Library Assets / Charkle Moodboard <-> PureRef)

    /// Builds a cleanly packed, aspect-preserving justified masonry PureRef scene from selected assets.
    public static func buildScene(fromAssets inputs: [PureRefAssetInput]) -> PureRefScene {
        var blobs: [PureRefImageBlob] = []
        blobs.reserveCapacity(inputs.count)

        for input in inputs {
            guard let format = detectImageFormat(in: input.imageData),
                  let dims = inspectImageDimensions(input.imageData) else {
                continue
            }
            let width = dims.width > 0 ? dims.width : max(1, input.pixelWidth)
            let height = dims.height > 0 ? dims.height : max(1, input.pixelHeight)
            blobs.append(PureRefImageBlob(
                index: blobs.count,
                data: input.imageData,
                format: format,
                pixelWidth: width,
                pixelHeight: height,
                sourcePath: input.fileName,
                displayName: input.title.isEmpty ? input.fileName : input.title
            ))
        }

        let placements = autoLayoutPlacements(for: blobs)
        return PureRefScene(
            formatVersion: "1.10",
            canvasRect: computeCanvasRect(placements: placements, notes: []),
            zoom: 1.0,
            images: blobs,
            placements: placements,
            notes: []
        )
    }

    /// Builds a PureRef scene faithfully preserving a Charkle Moodboard's spatial positions,
    /// sizes, rotations, crops, flips, z-order, notes, and group titles.
    public static func buildScene(
        fromBoard board: MoodboardDocument,
        assetsByID: [UUID: PureRefAssetInput]
    ) -> (scene: PureRefScene, skippedCount: Int) {
        let sortedNodes = board.nodes.sorted { $0.zIndex < $1.zIndex }

        // Compute content center so the board opens centered neatly at PureRef's origin (0, 0)
        var minX = Double.greatestFiniteMagnitude
        var minY = Double.greatestFiniteMagnitude
        var maxX = -Double.greatestFiniteMagnitude
        var maxY = -Double.greatestFiniteMagnitude
        for node in sortedNodes {
            minX = min(minX, node.frame.minX)
            minY = min(minY, node.frame.minY)
            maxX = max(maxX, node.frame.maxX)
            maxY = max(maxY, node.frame.maxY)
        }
        let originX = minX.isFinite && maxX.isFinite ? (minX + maxX) * 0.5 : 0
        let originY = minY.isFinite && maxY.isFinite ? (minY + maxY) * 0.5 : 0

        var blobs: [PureRefImageBlob] = []
        var blobIndexByAssetID: [UUID: Int] = [:]
        var placements: [PureRefImagePlacement] = []
        var notes: [PureRefTextNote] = []
        var skippedCount = 0

        for node in sortedNodes {
            switch node.kind {
            case .assetRef(let assetID, let crop, _, _):
                guard let input = assetsByID[assetID],
                      let format = detectImageFormat(in: input.imageData),
                      let dims = inspectImageDimensions(input.imageData) else {
                    skippedCount += 1
                    continue
                }
                let blobIndex: Int
                if let existing = blobIndexByAssetID[assetID] {
                    blobIndex = existing
                } else {
                    blobIndex = blobs.count
                    blobs.append(PureRefImageBlob(
                        index: blobIndex,
                        data: input.imageData,
                        format: format,
                        pixelWidth: dims.width,
                        pixelHeight: dims.height,
                        sourcePath: input.fileName,
                        displayName: input.title.isEmpty ? input.fileName : input.title
                    ))
                    blobIndexByAssetID[assetID] = blobIndex
                }
                placements.append(PureRefImagePlacement(
                    imageIndex: blobIndex,
                    name: input.title.isEmpty ? input.fileName : input.title,
                    sourcePath: input.fileName,
                    centerX: node.frame.midX - originX,
                    centerY: node.frame.midY - originY,
                    width: max(24, node.frame.width),
                    height: max(24, node.frame.height),
                    rotationDegrees: node.rotationDegrees,
                    flipHorizontal: node.flipHorizontal,
                    flipVertical: node.flipVertical,
                    zLayer: Double(node.zIndex),
                    crop: crop?.isMeaningfulSubregion == true ? crop : nil
                ))

            case .note(let title, let text, let style, let fontSize):
                let combined: String = {
                    let cleanTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    let cleanBody = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if cleanTitle.isEmpty { return cleanBody }
                    if cleanBody.isEmpty { return cleanTitle }
                    return "\(cleanTitle)\n\(cleanBody)"
                }()
                guard !combined.isEmpty else { continue }
                let palette = PureRefColor.fromNoteStyle(style)
                notes.append(PureRefTextNote(
                    text: combined,
                    centerX: node.frame.midX - originX,
                    centerY: node.frame.midY - originY,
                    scale: max(0.6, min(3.0, fontSize / 15.0)),
                    zLayer: Double(node.zIndex),
                    foreground: palette.foreground,
                    background: palette.background
                ))

            case .groupFrame(let title, _):
                let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !cleanTitle.isEmpty else { continue }
                let palette = PureRefColor.fromNoteStyle(.slate)
                notes.append(PureRefTextNote(
                    text: cleanTitle,
                    centerX: node.frame.midX - originX,
                    centerY: node.frame.minY + 20 - originY,
                    scale: 1.15,
                    zLayer: Double(node.zIndex),
                    foreground: palette.foreground,
                    background: palette.background
                ))

            case .paletteStrip:
                continue
            }
        }

        let scene = PureRefScene(
            formatVersion: "1.10",
            canvasRect: computeCanvasRect(placements: placements, notes: notes),
            zoom: 1.0,
            images: blobs,
            placements: placements,
            notes: notes
        )
        return (scene, skippedCount)
    }

    /// Converts a decoded `PureRefScene` + ingested Charkle `AssetRecord`s (keyed by `imageIndex`)
    /// into a ready-to-edit `.freeform` `MoodboardDocument` preserving full spatial geometry and notes.
    public static func buildMoodboardDocument(
        title: String,
        scene: PureRefScene,
        assetByImageIndex: [Int: AssetRecord],
        palette: [LabColor] = []
    ) -> (document: MoodboardDocument, noteCount: Int) {
        // Compute a comfortable studio canvas scale so extreme PureRef coordinates (e.g. 4000px cards)
        // normalize cleanly into Charkle's ~280pt editorial scale while keeping 100% relative layout fidelity.
        let widths = scene.placements.map(\.width).filter { $0.isFinite && $0 > 1 }.sorted()
        let medianWidth = widths.isEmpty ? 320.0 : widths[widths.count / 2]
        let layoutScale: Double = {
            if medianWidth > 540 { return 340.0 / medianWidth }
            if medianWidth < 120 { return 240.0 / max(24.0, medianWidth) }
            return 1.0
        }()

        // Find bounding top-left so imported board starts cleanly around (80, 80)
        var minX = Double.greatestFiniteMagnitude
        var minY = Double.greatestFiniteMagnitude
        for p in scene.placements {
            minX = min(minX, (p.centerX - p.width * 0.5) * layoutScale)
            minY = min(minY, (p.centerY - p.height * 0.5) * layoutScale)
        }
        for n in scene.notes {
            minX = min(minX, n.centerX * layoutScale - 110)
            minY = min(minY, n.centerY * layoutScale - 40)
        }
        let shiftX = minX.isFinite ? (80.0 - minX) : 80.0
        let shiftY = minY.isFinite ? (80.0 - minY) : 80.0

        var nodes: [BoardNode] = []
        var noteCount = 0
        var orderCounter = 0

        let sortedPlacements = scene.placements.sorted { $0.zLayer < $1.zLayer }
        for placement in sortedPlacements {
            guard let asset = assetByImageIndex[placement.imageIndex] else { continue }
            let w = max(60.0, placement.width * layoutScale)
            let h = max(60.0, placement.height * layoutScale)
            let cx = placement.centerX * layoutScale + shiftX
            let cy = placement.centerY * layoutScale + shiftY
            let zIdx = Int(placement.zLayer.rounded())

            nodes.append(BoardNode(
                kind: .assetRef(
                    assetID: asset.id,
                    crop: placement.crop,
                    weight: 1,
                    autoplayLoop: asset.mediaKind == .animatedImage
                ),
                frame: BoardRect(x: cx - w * 0.5, y: cy - h * 0.5, width: w, height: h),
                zIndex: zIdx,
                rotationDegrees: placement.rotationDegrees,
                flipHorizontal: placement.flipHorizontal,
                flipVertical: placement.flipVertical,
                editorialOrder: orderCounter
            ))
            orderCounter += 1

            for (childIdx, child) in placement.childNotes.enumerated() {
                let clean = child.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !clean.isEmpty else { continue }
                let nw = max(160.0, min(360.0, Double(clean.count) * 9.5 + 48.0))
                let nh = max(64.0, min(220.0, Double(clean.split(separator: "\n").count) * 24.0 + 44.0))
                let ncx = cx + child.centerX * layoutScale
                let ncy = cy + (child.centerY != 0 ? child.centerY * layoutScale : (h * 0.5 + 42.0 + Double(childIdx) * 76.0))
                nodes.append(BoardNode(
                    kind: .note(
                        title: nil,
                        text: clean,
                        style: child.background.inferredNoteStyle(),
                        fontSize: max(12, min(28, 14.0 * child.scale))
                    ),
                    frame: BoardRect(x: ncx - nw * 0.5, y: ncy - nh * 0.5, width: nw, height: nh),
                    zIndex: max(zIdx + 1, Int(child.zLayer.rounded())),
                    editorialOrder: orderCounter
                ))
                orderCounter += 1
                noteCount += 1
            }
        }

        func appendNoteTree(_ list: [PureRefTextNote], parentOffsetX: Double, parentOffsetY: Double) {
            for note in list {
                let clean = note.text.trimmingCharacters(in: .whitespacesAndNewlines)
                let ncx = note.centerX * layoutScale + parentOffsetX
                let ncy = note.centerY * layoutScale + parentOffsetY
                if !clean.isEmpty {
                    let lines = clean.split(separator: "\n", omittingEmptySubsequences: false)
                    let maxLineLen = lines.map(\.count).max() ?? 12
                    let nw = max(170.0, min(400.0, Double(maxLineLen) * 11.0 + 52.0))
                    let nh = max(72.0, min(280.0, Double(max(1, lines.count)) * 24.0 + 48.0))
                    nodes.append(BoardNode(
                        kind: .note(
                            title: nil,
                            text: clean,
                            style: note.background.inferredNoteStyle(),
                            fontSize: max(12, min(32, 15.0 * note.scale))
                        ),
                        frame: BoardRect(x: ncx - nw * 0.5, y: ncy - nh * 0.5, width: nw, height: nh),
                        zIndex: Int(note.zLayer.rounded()) + 10,
                        editorialOrder: orderCounter
                    ))
                    orderCounter += 1
                    noteCount += 1
                }
                if !note.childNotes.isEmpty {
                    appendNoteTree(note.childNotes, parentOffsetX: ncx, parentOffsetY: ncy)
                }
            }
        }

        appendNoteTree(scene.notes, parentOffsetX: shiftX, parentOffsetY: shiftY)

        // Normalize z-indices cleanly to 0...N-1 preserving relative stacking order
        let sortedIndices = nodes.indices.sorted {
            if nodes[$0].zIndex != nodes[$1].zIndex { return nodes[$0].zIndex < nodes[$1].zIndex }
            return $0 < $1
        }
        for (rank, idx) in sortedIndices.enumerated() {
            nodes[idx].zIndex = rank
        }

        let doc = MoodboardDocument(
            title: title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "PureRef 场景" : title,
            mode: .freeform,
            nodes: nodes,
            extractedPalette: palette
        )
        return (doc, noteCount)
    }

    // MARK: - Justified Auto-Layout Helper

    /// Arranges images into balanced horizontal justified rows centered around `(0, 0)`.
    public static func autoLayoutPlacements(
        for blobs: [PureRefImageBlob],
        targetRowHeight: Double = 340,
        spacing: Double = 18
    ) -> [PureRefImagePlacement] {
        guard !blobs.isEmpty else { return [] }
        let targetRowWidth: Double = blobs.count <= 3 ? 1150 : (blobs.count <= 10 ? 1560 : 2100)

        struct RowItem {
            let blob: PureRefImageBlob
            let aspect: Double
        }

        var rows: [[RowItem]] = []
        var currentRow: [RowItem] = []
        var currentNaturalWidth = 0.0

        for blob in blobs {
            let aspect = max(0.28, min(3.6, Double(max(1, blob.pixelWidth)) / Double(max(1, blob.pixelHeight))))
            let itemWidth = targetRowHeight * aspect
            if !currentRow.isEmpty && (currentNaturalWidth + spacing + itemWidth) > targetRowWidth {
                rows.append(currentRow)
                currentRow = []
                currentNaturalWidth = 0
            }
            currentRow.append(RowItem(blob: blob, aspect: aspect))
            currentNaturalWidth += (currentRow.count > 1 ? spacing : 0) + itemWidth
        }
        if !currentRow.isEmpty {
            rows.append(currentRow)
        }

        var rawPlacements: [PureRefImagePlacement] = []
        rawPlacements.reserveCapacity(blobs.count)
        var yCursor = 0.0
        var zCounter = 0.0

        for (rowIndex, row) in rows.enumerated() {
            let sumAspects = row.reduce(0.0) { $0 + $1.aspect }
            let isLastRow = rowIndex == rows.count - 1
            let gapsWidth = spacing * Double(max(0, row.count - 1))
            let rowHeight: Double = {
                if isLastRow && rows.count > 1 && (sumAspects * targetRowHeight + gapsWidth) < targetRowWidth * 0.72 {
                    return targetRowHeight
                }
                let ideal = (targetRowWidth - gapsWidth) / max(0.1, sumAspects)
                return max(targetRowHeight * 0.65, min(targetRowHeight * 1.45, ideal))
            }()

            var xCursor = 0.0
            for item in row {
                let w = rowHeight * item.aspect
                let h = rowHeight
                rawPlacements.append(PureRefImagePlacement(
                    imageIndex: item.blob.index,
                    name: item.blob.displayName,
                    sourcePath: item.blob.sourcePath,
                    centerX: xCursor + w * 0.5,
                    centerY: yCursor + h * 0.5,
                    width: w,
                    height: h,
                    zLayer: zCounter
                ))
                xCursor += w + spacing
                zCounter += 1.0
            }
            yCursor += rowHeight + spacing
        }

        // Center layout neatly around PureRef origin (0, 0)
        let minX = rawPlacements.map { $0.centerX - $0.width * 0.5 }.min() ?? 0
        let maxX = rawPlacements.map { $0.centerX + $0.width * 0.5 }.max() ?? 0
        let minY = rawPlacements.map { $0.centerY - $0.height * 0.5 }.min() ?? 0
        let maxY = rawPlacements.map { $0.centerY + $0.height * 0.5 }.max() ?? 0
        let cx = (minX + maxX) * 0.5
        let cy = (minY + maxY) * 0.5

        return rawPlacements.map { p in
            var copy = p
            copy.centerX -= cx
            copy.centerY -= cy
            return copy
        }
    }

    // MARK: - Matrix & Image Utilities

    static func composeMatrix(
        sx: Double,
        sy: Double,
        rotationDegrees: Double,
        flipHorizontal: Bool,
        flipVertical: Bool
    ) -> (m11: Double, m12: Double, m21: Double, m22: Double) {
        let theta = rotationDegrees * .pi / 180.0
        let cosT = cos(theta)
        let sinT = sin(theta)
        let fx = flipHorizontal ? -1.0 : 1.0
        let fy = flipVertical ? -1.0 : 1.0
        return (
            m11: sx * fx * cosT,
            m12: sx * fx * sinT,
            m21: -sy * fy * sinT,
            m22: sy * fy * cosT
        )
    }

    static func decomposeMatrix(
        _ m: (m11: Double, m12: Double, m21: Double, m22: Double)
    ) -> (sx: Double, sy: Double, rotationDegrees: Double, flipHorizontal: Bool, flipVertical: Bool) {
        let sx = max(0.001, hypot(m.m11, m.m12))
        let sy = max(0.001, hypot(m.m21, m.m22))
        let det = m.m11 * m.m22 - m.m12 * m.m21

        var flipH = false
        var flipV = false
        var radians: Double

        if det < 0 {
            flipH = true
            radians = atan2(-m.m12, -m.m11)
        } else {
            radians = atan2(m.m12, m.m11)
        }

        var degrees = radians * 180.0 / .pi
        if flipH && abs(degrees) > 135 {
            flipH = false
            flipV = true
            degrees = degrees > 0 ? degrees - 180.0 : degrees + 180.0
        }
        if abs(degrees) < 0.05 { degrees = 0 }
        return (sx, sy, degrees, flipH, flipV)
    }

    public static func detectImageFormat(in data: Data) -> PureRefImageFormat? {
        guard data.count >= 12 else { return nil }
        let b = [UInt8](data.prefix(12))
        if b.prefix(8).elementsEqual(pngSignature) { return .png }
        if b[0] == 0xFF && b[1] == 0xD8 && b[2] == 0xFF { return .jpeg }
        if b[0] == 0x52 && b[1] == 0x49 && b[2] == 0x46 && b[3] == 0x46
            && b[8] == 0x57 && b[9] == 0x45 && b[10] == 0x42 && b[11] == 0x50 {
            return .webp
        }
        if b[0] == 0x47 && b[1] == 0x49 && b[2] == 0x46 && b[3] == 0x38
            && (b[4] == 0x37 || b[4] == 0x39) && b[5] == 0x61 {
            return .gif
        }
        return nil
    }

    public static func inspectImageDimensions(_ data: Data) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int,
              let h = props[kCGImagePropertyPixelHeight] as? Int,
              w > 0, h > 0 else {
            return nil
        }
        let orientation = (props[kCGImagePropertyOrientation] as? Int)
            ?? (props[kCGImagePropertyOrientation] as? NSNumber)?.intValue
            ?? 1
        if (5...8).contains(orientation) {
            return (h, w)
        }
        return (w, h)
    }

    public static func convertToPNG(_ data: Data) -> Data? {
        autoreleasepool {
            guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else {
                return nil
            }
            let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
            let orientation = (props?[kCGImagePropertyOrientation] as? Int)
                ?? (props?[kCGImagePropertyOrientation] as? NSNumber)?.intValue
                ?? 1
            let cgImage: CGImage?
            if orientation != 1,
               let rawW = props?[kCGImagePropertyPixelWidth] as? Int,
               let rawH = props?[kCGImagePropertyPixelHeight] as? Int,
               rawW > 0, rawH > 0 {
                let thumbOpts: [CFString: Any] = [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: max(rawW, rawH),
                    kCGImageSourceShouldCacheImmediately: true
                ]
                cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOpts as CFDictionary)
                    ?? CGImageSourceCreateImageAtIndex(source, 0, nil)
            } else {
                cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil)
            }
            guard let cgImage else { return nil }
            let mutable = NSMutableData()
            guard let dest = CGImageDestinationCreateWithData(
                mutable as CFMutableData,
                UTType.png.identifier as CFString,
                1,
                nil
            ) else {
                return nil
            }
            CGImageDestinationAddImage(dest, cgImage, nil)
            guard CGImageDestinationFinalize(dest) else { return nil }
            return mutable as Data
        }
    }

    private static func computeCanvasRect(placements: [PureRefImagePlacement], notes: [PureRefTextNote]) -> BoardRect {
        var minX = -2000.0
        var minY = -2000.0
        var maxX = 2000.0
        var maxY = 2000.0
        for p in placements {
            minX = min(minX, p.centerX - p.width * 0.5 - 600)
            minY = min(minY, p.centerY - p.height * 0.5 - 600)
            maxX = max(maxX, p.centerX + p.width * 0.5 + 600)
            maxY = max(maxY, p.centerY + p.height * 0.5 + 600)
        }
        for n in notes {
            minX = min(minX, n.centerX - 600)
            minY = min(minY, n.centerY - 600)
            maxX = max(maxX, n.centerX + 600)
            maxY = max(maxY, n.centerY + 600)
        }
        return BoardRect(
            x: min(-10000, minX),
            y: min(-10000, minY),
            width: max(20000, maxX - minX),
            height: max(20000, maxY - minY)
        )
    }

    // MARK: - Low-Level Big-Endian QDataStream Helpers

    private static func isASCIIAlpha(_ b: UInt8) -> Bool {
        (b >= 0x41 && b <= 0x5A) || (b >= 0x61 && b <= 0x7A)
    }

    private static func readUInt16BE(_ b: [UInt8], at i: Int) -> UInt16 {
        (UInt16(b[i]) << 8) | UInt16(b[i + 1])
    }

    private static func readUInt32BE(_ b: [UInt8], at i: Int) -> UInt32 {
        (UInt32(b[i]) << 24) | (UInt32(b[i + 1]) << 16) | (UInt32(b[i + 2]) << 8) | UInt32(b[i + 3])
    }

    private static func readUInt32LE(_ b: [UInt8], at i: Int) -> UInt32 {
        UInt32(b[i]) | (UInt32(b[i + 1]) << 8) | (UInt32(b[i + 2]) << 16) | (UInt32(b[i + 3]) << 24)
    }

    private static func readInt32BE(_ b: [UInt8], at i: Int) -> Int32 {
        Int32(bitPattern: readUInt32BE(b, at: i))
    }

    private static func readUInt64BE(_ b: [UInt8], at i: Int) -> UInt64 {
        var v: UInt64 = 0
        for k in 0..<8 {
            v = (v << 8) | UInt64(b[i + k])
        }
        return v
    }

    private static func readDoubleBE(_ b: [UInt8], at i: Int) -> Double {
        Double(bitPattern: readUInt64BE(b, at: i))
    }

    private static func readMatrix6Doubles(
        _ b: [UInt8],
        pos: inout Int
    ) -> (m11: Double, m12: Double, m21: Double, m22: Double) {
        let m11 = readDoubleBE(b, at: pos)
        let m12 = readDoubleBE(b, at: pos + 8)
        let m21 = readDoubleBE(b, at: pos + 24)
        let m22 = readDoubleBE(b, at: pos + 32)
        pos += 48
        return (
            m11.isFinite ? m11 : 1.0,
            m12.isFinite ? m12 : 0.0,
            m21.isFinite ? m21 : 0.0,
            m22.isFinite ? m22 : 1.0
        )
    }

    private static func readOptionalQString(_ b: [UInt8], pos: inout Int, limit: Int) -> String? {
        guard pos + 4 <= limit else { return nil }
        let signedLen = readInt32BE(b, at: pos)
        pos += 4
        if signedLen < 0 {
            return nil
        }
        let byteLen = Int(signedLen)
        guard byteLen == 0 || (byteLen <= limit - pos && byteLen % 2 == 0) else {
            return nil
        }
        if byteLen == 0 { return "" }
        let str = decodeUTF16BE(b[pos..<(pos + byteLen)])
        pos += byteLen
        return str
    }

    private static func readQColor(_ b: [UInt8], pos: inout Int) -> PureRefColor {
        let spec = Int8(bitPattern: b[pos]); pos += 1
        let alpha16 = Double(readUInt16BE(b, at: pos)) / 65535.0; pos += 2
        let c1 = Double(readUInt16BE(b, at: pos)); pos += 2
        let c2 = Double(readUInt16BE(b, at: pos)); pos += 2
        let c3 = Double(readUInt16BE(b, at: pos)); pos += 2

        if spec == 2 { // HSV
            let h = (c1 / 35900.0).truncatingRemainder(dividingBy: 1.0)
            let s = max(0, min(1, c2 / 65535.0))
            let v = max(0, min(1, c3 / 65535.0))
            let (r, g, bl) = hsvToRGB(h: h < 0 ? h + 1 : h, s: s, v: v)
            return PureRefColor(r: r, g: g, b: bl, alpha: alpha16)
        }
        return PureRefColor(r: c1 / 65535.0, g: c2 / 65535.0, b: c3 / 65535.0, alpha: alpha16)
    }

    private static func hsvToRGB(h: Double, s: Double, v: Double) -> (Double, Double, Double) {
        if s <= 0 { return (v, v, v) }
        let sector = h * 6.0
        let i = Int(floor(sector)) % 6
        let f = sector - floor(sector)
        let p = v * (1.0 - s)
        let q = v * (1.0 - s * f)
        let t = v * (1.0 - s * (1.0 - f))
        switch i {
        case 0: return (v, t, p)
        case 1: return (q, v, p)
        case 2: return (p, v, t)
        case 3: return (p, q, v)
        case 4: return (t, p, v)
        default: return (v, p, q)
        }
    }

    private static func decodeUTF16BE(_ slice: ArraySlice<UInt8>) -> String {
        var units: [UInt16] = []
        units.reserveCapacity(slice.count / 2)
        var i = slice.startIndex
        while i + 1 < slice.endIndex {
            units.append((UInt16(slice[i]) << 8) | UInt16(slice[i + 1]))
            i += 2
        }
        return String(decoding: units, as: UTF16.self)
    }

    private static func encodeUTF16BE(_ string: String) -> [UInt8] {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(string.utf16.count * 2)
        for u in string.utf16 {
            bytes.append(UInt8(u >> 8))
            bytes.append(UInt8(u & 0xFF))
        }
        return bytes
    }

    private static func writeUInt16BE(_ out: inout [UInt8], at i: Int, value: UInt16) {
        out[i] = UInt8(value >> 8)
        out[i + 1] = UInt8(value & 0xFF)
    }

    private static func writeUInt32BE(_ out: inout [UInt8], at i: Int, value: UInt32) {
        out[i] = UInt8((value >> 24) & 0xFF)
        out[i + 1] = UInt8((value >> 16) & 0xFF)
        out[i + 2] = UInt8((value >> 8) & 0xFF)
        out[i + 3] = UInt8(value & 0xFF)
    }

    private static func writeInt32BE(_ out: inout [UInt8], at i: Int, value: Int32) {
        writeUInt32BE(&out, at: i, value: UInt32(bitPattern: value))
    }

    private static func writeUInt64BE(_ out: inout [UInt8], at i: Int, value: UInt64) {
        for k in 0..<8 {
            out[i + k] = UInt8((value >> UInt64((7 - k) * 8)) & 0xFF)
        }
    }

    private static func writeDoubleBE(_ out: inout [UInt8], at i: Int, value: Double) {
        writeUInt64BE(&out, at: i, value: value.bitPattern)
    }

    private static func appendUInt16BE(_ out: inout [UInt8], _ value: UInt16) {
        out.append(UInt8(value >> 8))
        out.append(UInt8(value & 0xFF))
    }

    private static func appendUInt32BE(_ out: inout [UInt8], _ value: UInt32) {
        out.append(UInt8((value >> 24) & 0xFF))
        out.append(UInt8((value >> 16) & 0xFF))
        out.append(UInt8((value >> 8) & 0xFF))
        out.append(UInt8(value & 0xFF))
    }

    private static func appendUInt64BE(_ out: inout [UInt8], _ value: UInt64) {
        for k in 0..<8 {
            out.append(UInt8((value >> UInt64((7 - k) * 8)) & 0xFF))
        }
    }

    private static func appendInt64BE(_ out: inout [UInt8], _ value: Int64) {
        appendUInt64BE(&out, UInt64(bitPattern: value))
    }

    private static func appendDoubleBE(_ out: inout [UInt8], _ value: Double) {
        appendUInt64BE(&out, value.bitPattern)
    }

    private static func appendQString(_ out: inout [UInt8], _ string: String) {
        let encoded = encodeUTF16BE(string)
        appendUInt32BE(&out, UInt32(encoded.count))
        out.append(contentsOf: encoded)
    }

    private static func appendMatrix6Doubles(
        _ out: inout [UInt8],
        m11: Double,
        m12: Double,
        m21: Double,
        m22: Double
    ) {
        appendDoubleBE(&out, m11)
        appendDoubleBE(&out, m12)
        appendDoubleBE(&out, 0.0)
        appendDoubleBE(&out, m21)
        appendDoubleBE(&out, m22)
        appendDoubleBE(&out, 0.0)
    }

    private static func appendQColor(_ out: inout [UInt8], _ color: PureRefColor) {
        out.append(1) // QColor::Rgb
        appendUInt16BE(&out, UInt16((max(0, min(1, color.alpha)) * 65535.0).rounded()))
        appendUInt16BE(&out, UInt16((max(0, min(1, color.r)) * 65535.0).rounded()))
        appendUInt16BE(&out, UInt16((max(0, min(1, color.g)) * 65535.0).rounded()))
        appendUInt16BE(&out, UInt16((max(0, min(1, color.b)) * 65535.0).rounded()))
    }
}
