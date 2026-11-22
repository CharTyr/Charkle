import Foundation

public enum MediaKind: String, Codable, CaseIterable, Hashable, Sendable {
    case image
    case animatedImage
    case video
    case webBookmark
    case document
    case designFile
    case audio

    public var localizedLabel: String {
        switch self {
        case .image: "图片"
        case .animatedImage: "动图"
        case .video: "视频"
        case .webBookmark: "网页"
        case .document: "文档"
        case .designFile: "设计文件"
        case .audio: "音频"
        }
    }

    public static func detect(fileExtension ext: String, mimeType: String? = nil) -> MediaKind {
        let lower = ext.lowercased()
        switch lower {
        case "gif", "apng":
            return .animatedImage
        case "jpg", "jpeg", "png", "heic", "heif", "webp", "tiff", "tif", "bmp", "avif", "jxl":
            return .image
        case "mp4", "mov", "m4v", "webm", "mkv", "avi":
            return .video
        case "pdf", "md", "markdown", "txt", "rtf", "docx", "pptx", "key", "pages":
            return .document
        case "svg", "psd", "psb", "sketch", "fig", "ai", "eps", "xd", "afdesign", "afphoto":
            return .designFile
        case "mp3", "wav", "m4a", "aac", "flac", "ogg", "aiff":
            return .audio
        case "webloc", "url":
            return .webBookmark
        default:
            if let mime = mimeType?.lowercased() {
                if mime.hasPrefix("image/gif") { return .animatedImage }
                if mime.hasPrefix("image/svg") { return .designFile }
                if mime.hasPrefix("image/") { return .image }
                if mime.hasPrefix("video/") { return .video }
                if mime.hasPrefix("audio/") { return .audio }
                if mime == "application/pdf" || mime.hasPrefix("text/") { return .document }
            }
            return .document
        }
    }
}

public enum AspectShape: String, Codable, CaseIterable, Hashable, Sendable {
    case landscape
    case portrait
    case square
    case ultrawide

    public var localizedLabel: String {
        switch self {
        case .landscape: "横图"
        case .portrait: "竖图"
        case .square: "方图"
        case .ultrawide: "超宽"
        }
    }

    public static func classify(width: Int, height: Int) -> AspectShape {
        guard width > 0, height > 0 else { return .square }
        let ratio = Double(width) / Double(height)
        if ratio >= 2.0 { return .ultrawide }
        if ratio >= 1.15 { return .landscape }
        if ratio <= 0.87 { return .portrait }
        return .square
    }
}

/// Perceptually uniform CIELAB swatch paired with sRGB hex.
public struct LabColor: Codable, Hashable, Sendable {
    public var hex: String
    public var l: Double
    public var a: Double
    public var b: Double
    public var proportion: Double

    public init(hex: String, l: Double, a: Double, b: Double, proportion: Double = 1.0) {
        self.hex = hex
        self.l = l
        self.a = a
        self.b = b
        self.proportion = proportion
    }

    /// CIE76 Euclidean distance in CIELAB space (fast perceptual proximity).
    public func deltaE(to other: LabColor) -> Double {
        let dl = l - other.l
        let da = a - other.a
        let db = b - other.b
        return (dl * dl + da * da + db * db).squareRoot()
    }

    /// Construct a LabColor from an sRGB hex string such as "#3B82F6" or "3B82F6".
    public static func fromHex(_ hexString: String, proportion: Double = 1.0) -> LabColor {
        let cleaned = hexString.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "#", with: "")
        guard cleaned.count == 6, let value = UInt32(cleaned, radix: 16) else {
            return LabColor(hex: "#808080", l: 53.59, a: 0, b: 0, proportion: proportion)
        }
        let r = Double((value >> 16) & 0xFF) / 255.0
        let g = Double((value >> 8) & 0xFF) / 255.0
        let b = Double(value & 0xFF) / 255.0
        let (lVal, aVal, bVal) = Self.sRGBToLab(r: r, g: g, b: b)
        return LabColor(hex: "#\(cleaned.uppercased())", l: lVal, a: aVal, b: bVal, proportion: proportion)
    }

    public static func sRGBToLab(r: Double, g: Double, b: Double) -> (Double, Double, Double) {
        func linearize(_ c: Double) -> Double {
            c <= 0.04045 ? (c / 12.92) : pow((c + 0.055) / 1.055, 2.4)
        }
        let rl = linearize(r)
        let gl = linearize(g)
        let bl = linearize(b)

        let x = (rl * 0.4124564 + gl * 0.3575761 + bl * 0.1804375) / 0.95047
        let y = (rl * 0.2126729 + gl * 0.7151522 + bl * 0.0721750) / 1.00000
        let z = (rl * 0.0193339 + gl * 0.1191920 + bl * 0.9503041) / 1.08883

        func f(_ t: Double) -> Double {
            t > 0.008856 ? cbrt(t) : (7.787 * t + 16.0 / 116.0)
        }
        let fx = f(x)
        let fy = f(y)
        let fz = f(z)

        let lVal = (116.0 * fy) - 16.0
        let aVal = 500.0 * (fx - fy)
        let bVal = 200.0 * (fy - fz)
        return (lVal, aVal, bVal)
    }
}

public struct AssetRecord: Codable, Hashable, Identifiable, Sendable {
    public let id: UUID
    public var title: String
    public var fileName: String
    public var folderID: UUID?
    public var driveFileID: String?
    public var contentHash: String
    public var mediaKind: MediaKind
    public var mimeType: String
    public var fileSizeBytes: Int64
    public var pixelWidth: Int
    public var pixelHeight: Int
    public var durationSeconds: Double?
    public var waveformPeaks: [Float]
    public var sourceURL: String?
    public var sourceDomain: String?
    public var notes: String
    public var tags: [String]
    public var suggestedTags: [String]
    public var aiDescription: String?
    public var ocrText: String?
    public var dominantColors: [LabColor]
    public var rating: Int
    public var pinnedOffline: Bool
    public var isLocalOriginalCached: Bool
    public var isTrashed: Bool
    public var createdAt: Date
    public var updatedAt: Date
    public var updatedHLC: Int64

    public var aspectRatio: Double {
        guard pixelWidth > 0, pixelHeight > 0 else { return 1.0 }
        return Double(pixelWidth) / Double(pixelHeight)
    }

    public var aspectShape: AspectShape {
        AspectShape.classify(width: pixelWidth, height: pixelHeight)
    }

    public var isInInbox: Bool {
        folderID == nil && !isTrashed
    }

    public init(
        id: UUID = UUID(),
        title: String,
        fileName: String,
        folderID: UUID? = nil,
        driveFileID: String? = nil,
        contentHash: String = "",
        mediaKind: MediaKind = .image,
        mimeType: String = "image/jpeg",
        fileSizeBytes: Int64 = 0,
        pixelWidth: Int = 1200,
        pixelHeight: Int = 900,
        durationSeconds: Double? = nil,
        waveformPeaks: [Float] = [],
        sourceURL: String? = nil,
        sourceDomain: String? = nil,
        notes: String = "",
        tags: [String] = [],
        suggestedTags: [String] = [],
        aiDescription: String? = nil,
        ocrText: String? = nil,
        dominantColors: [LabColor] = [],
        rating: Int = 0,
        pinnedOffline: Bool = false,
        isLocalOriginalCached: Bool = false,
        isTrashed: Bool = false,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        updatedHLC: Int64 = 0
    ) {
        self.id = id
        self.title = title
        self.fileName = fileName
        self.folderID = folderID
        self.driveFileID = driveFileID
        self.contentHash = contentHash
        self.mediaKind = mediaKind
        self.mimeType = mimeType
        self.fileSizeBytes = fileSizeBytes
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.durationSeconds = durationSeconds
        self.waveformPeaks = waveformPeaks
        self.sourceURL = sourceURL
        self.sourceDomain = sourceDomain
        self.notes = notes
        self.tags = tags
        self.suggestedTags = suggestedTags
        self.aiDescription = aiDescription
        self.ocrText = ocrText
        self.dominantColors = dominantColors
        self.rating = rating
        self.pinnedOffline = pinnedOffline
        self.isLocalOriginalCached = isLocalOriginalCached
        self.isTrashed = isTrashed
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.updatedHLC = updatedHLC
    }
}

public struct FolderRecord: Codable, Hashable, Identifiable, Sendable {
    public let id: UUID
    public var name: String
    public var parentID: UUID?
    public var driveFolderID: String?
    public var colorHex: String?
    public var sortOrder: Int
    public var assetCount: Int
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        parentID: UUID? = nil,
        driveFolderID: String? = nil,
        colorHex: String? = nil,
        sortOrder: Int = 0,
        assetCount: Int = 0,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.parentID = parentID
        self.driveFolderID = driveFolderID
        self.colorHex = colorHex
        self.sortOrder = sortOrder
        self.assetCount = assetCount
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct TagCount: Codable, Hashable, Identifiable, Sendable {
    public var id: String { name }
    public let name: String
    public let count: Int

    public init(name: String, count: Int) {
        self.name = name
        self.count = count
    }
}

public enum SortOrder: String, Codable, CaseIterable, Hashable, Sendable {
    case newest
    case oldest
    case nameAsc
    case ratingDesc
    case fileSizeDesc
    case relevance

    public var localizedLabel: String {
        switch self {
        case .newest: "最新添加"
        case .oldest: "最早添加"
        case .nameAsc: "名称 A→Z"
        case .ratingDesc: "评分最高"
        case .fileSizeDesc: "文件最大"
        case .relevance: "最相关"
        }
    }
}

public enum SidebarDestination: Hashable, Sendable {
    case allItems
    case inbox
    case moodboardsHome
    case moodboard(UUID)
    case untagged
    case recent
    case trash
    case folder(UUID)
    case tag(String)
}

public struct FilterCriteria: Codable, Hashable, Sendable {
    public var searchQuery: String
    public var kinds: Set<MediaKind>
    public var selectedColorHex: String?
    public var colorTolerance: Double
    public var shape: AspectShape?
    public var minRating: Int
    public var tags: Set<String>
    public var folderID: UUID?
    public var onlyInbox: Bool
    public var onlyUntagged: Bool
    public var onlyRecentDays: Int?
    public var onlyPinnedOffline: Bool
    public var includeTrashed: Bool
    public var onlyTrashed: Bool
    public var sortBy: SortOrder

    public init(
        searchQuery: String = "",
        kinds: Set<MediaKind> = [],
        selectedColorHex: String? = nil,
        colorTolerance: Double = 28.0,
        shape: AspectShape? = nil,
        minRating: Int = 0,
        tags: Set<String> = [],
        folderID: UUID? = nil,
        onlyInbox: Bool = false,
        onlyUntagged: Bool = false,
        onlyRecentDays: Int? = nil,
        onlyPinnedOffline: Bool = false,
        includeTrashed: Bool = false,
        onlyTrashed: Bool = false,
        sortBy: SortOrder = .newest
    ) {
        self.searchQuery = searchQuery
        self.kinds = kinds
        self.selectedColorHex = selectedColorHex
        self.colorTolerance = colorTolerance
        self.shape = shape
        self.minRating = minRating
        self.tags = tags
        self.folderID = folderID
        self.onlyInbox = onlyInbox
        self.onlyUntagged = onlyUntagged
        self.onlyRecentDays = onlyRecentDays
        self.onlyPinnedOffline = onlyPinnedOffline
        self.includeTrashed = includeTrashed
        self.onlyTrashed = onlyTrashed
        self.sortBy = sortBy
    }

    public var hasActiveVisualFilters: Bool {
        !kinds.isEmpty
            || selectedColorHex != nil
            || shape != nil
            || minRating > 0
            || !tags.isEmpty
            || onlyPinnedOffline
    }

    public mutating func clearVisualFilters() {
        kinds.removeAll()
        selectedColorHex = nil
        shape = nil
        minRating = 0
        tags.removeAll()
        onlyPinnedOffline = false
    }
}

public enum FolderAssignment: Codable, Hashable, Sendable {
    case unchanged
    case inbox
    case folder(UUID)
}

public struct AssetBatchPatch: Codable, Hashable, Sendable {
    public var assetIDs: [UUID]
    public var title: String?
    public var notes: String?
    public var rating: Int?
    public var addTags: [String]
    public var removeTags: [String]
    public var acceptSuggestedTags: Bool
    public var dismissSuggestedTags: [String]
    public var folderAssignment: FolderAssignment
    public var pinnedOffline: Bool?
    public var isTrashed: Bool?

    public init(
        assetIDs: [UUID],
        title: String? = nil,
        notes: String? = nil,
        rating: Int? = nil,
        addTags: [String] = [],
        removeTags: [String] = [],
        acceptSuggestedTags: Bool = false,
        dismissSuggestedTags: [String] = [],
        folderAssignment: FolderAssignment = .unchanged,
        pinnedOffline: Bool? = nil,
        isTrashed: Bool? = nil
    ) {
        self.assetIDs = assetIDs
        self.title = title
        self.notes = notes
        self.rating = rating
        self.addTags = addTags
        self.removeTags = removeTags
        self.acceptSuggestedTags = acceptSuggestedTags
        self.dismissSuggestedTags = dismissSuggestedTags
        self.folderAssignment = folderAssignment
        self.pinnedOffline = pinnedOffline
        self.isTrashed = isTrashed
    }
}

public enum QuickJumpKind: String, Codable, Hashable, Sendable {
    case folder
    case moodboard
    case tag
    case asset
}

public struct QuickJumpMatch: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public let kind: QuickJumpKind
    public let title: String
    public let subtitle: String
    public let targetUUID: UUID?
    public let tagName: String?
    public let score: Double

    public init(
        id: String,
        kind: QuickJumpKind,
        title: String,
        subtitle: String,
        targetUUID: UUID? = nil,
        tagName: String? = nil,
        score: Double
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.subtitle = subtitle
        self.targetUUID = targetUUID
        self.tagName = tagName
        self.score = score
    }
}

public struct ScoredAsset: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID { asset.id }
    public let asset: AssetRecord
    public let score: Double
    public let matchReasons: [String]

    public init(asset: AssetRecord, score: Double, matchReasons: [String] = []) {
        self.asset = asset
        self.score = score
        self.matchReasons = matchReasons
    }
}

public struct FolderSuggestion: Codable, Hashable, Sendable {
    public let folderID: UUID
    public let folderName: String
    public let confidence: Double
    public let reason: String

    public init(folderID: UUID, folderName: String, confidence: Double, reason: String) {
        self.folderID = folderID
        self.folderName = folderName
        self.confidence = confidence
        self.reason = reason
    }
}
