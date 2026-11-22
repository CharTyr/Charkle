import Foundation

public struct BoardPoint: Codable, Hashable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    public static let zero = BoardPoint(x: 0, y: 0)
}

public struct BoardRect: Codable, Hashable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var minX: Double { x }
    public var minY: Double { y }
    public var maxX: Double { x + width }
    public var maxY: Double { y + height }
    public var midX: Double { x + width * 0.5 }
    public var midY: Double { y + height * 0.5 }
}

public struct NormalizedCropRect: Codable, Hashable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double = 0, y: Double = 0, width: Double = 1, height: Double = 1) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public static let full = NormalizedCropRect()
}

public enum EditorialStyle: String, Codable, CaseIterable, Hashable, Sendable {
    case balanced
    case magazine
    case compact

    public var localizedLabel: String {
        switch self {
        case .balanced: "呼吸均衡"
        case .magazine: "杂志主次"
        case .compact: "紧凑拼贴"
        }
    }
}

public struct AutoLayoutConfig: Codable, Hashable, Sendable {
    public var columns: Int
    public var spacing: Double
    public var style: EditorialStyle
    public var showPaletteStrip: Bool

    public init(
        columns: Int = 4,
        spacing: Double = 16,
        style: EditorialStyle = .balanced,
        showPaletteStrip: Bool = true
    ) {
        self.columns = columns
        self.spacing = spacing
        self.style = style
        self.showPaletteStrip = showPaletteStrip
    }
}

public enum BoardLayoutMode: Codable, Hashable, Sendable {
    case autoEditorial(AutoLayoutConfig)
    case freeform

    public var isAutoEditorial: Bool {
        if case .autoEditorial = self { return true }
        return false
    }
}

public enum NoteStyle: String, Codable, CaseIterable, Hashable, Sendable {
    case paper
    case ink
    case warm
    case sage
    case slate
}

public enum GroupTint: String, Codable, CaseIterable, Hashable, Sendable {
    case neutral
    case sand
    case sage
    case slate
    case terracotta
    case ocean
}

public enum BoardNodeKind: Codable, Hashable, Sendable {
    case assetRef(assetID: UUID, crop: NormalizedCropRect?, weight: Int, autoplayLoop: Bool)
    case note(title: String?, text: String, style: NoteStyle, fontSize: Double)
    case groupFrame(title: String, tint: GroupTint)
    case paletteStrip(colors: [LabColor], autoSyncWithBoard: Bool)
}

public struct BoardNode: Codable, Hashable, Identifiable, Sendable {
    public let id: UUID
    public var kind: BoardNodeKind
    public var frame: BoardRect
    public var zIndex: Int
    public var rotationDegrees: Double
    public var isLocked: Bool
    public var editorialOrder: Int
    public var updatedAt: Date

    public var referencedAssetID: UUID? {
        if case .assetRef(let assetID, _, _, _) = kind { return assetID }
        return nil
    }

    public init(
        id: UUID = UUID(),
        kind: BoardNodeKind,
        frame: BoardRect,
        zIndex: Int = 0,
        rotationDegrees: Double = 0,
        isLocked: Bool = false,
        editorialOrder: Int = 0,
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.kind = kind
        self.frame = frame
        self.zIndex = zIndex
        self.rotationDegrees = rotationDegrees
        self.isLocked = isLocked
        self.editorialOrder = editorialOrder
        self.updatedAt = updatedAt
    }
}

public enum ConnectorAnchor: String, Codable, CaseIterable, Hashable, Sendable {
    case auto
    case top
    case bottom
    case leading
    case trailing
}

public enum ConnectorStyle: String, Codable, CaseIterable, Hashable, Sendable {
    case curved
    case elbow
    case straight
}

public struct BoardConnector: Codable, Hashable, Identifiable, Sendable {
    public let id: UUID
    public var fromNodeID: UUID
    public var fromAnchor: ConnectorAnchor
    public var toNodeID: UUID
    public var toAnchor: ConnectorAnchor
    public var label: String?
    public var colorHex: String
    public var style: ConnectorStyle
    public var dashed: Bool
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        fromNodeID: UUID,
        fromAnchor: ConnectorAnchor = .auto,
        toNodeID: UUID,
        toAnchor: ConnectorAnchor = .auto,
        label: String? = nil,
        colorHex: String = "#5C6672",
        style: ConnectorStyle = .curved,
        dashed: Bool = false,
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.fromNodeID = fromNodeID
        self.fromAnchor = fromAnchor
        self.toNodeID = toNodeID
        self.toAnchor = toAnchor
        self.label = label
        self.colorHex = colorHex
        self.style = style
        self.dashed = dashed
        self.updatedAt = updatedAt
    }
}

public struct InkStrokePoint: Codable, Hashable, Sendable {
    public var x: Double
    public var y: Double
    public var pressure: Double

    public init(x: Double, y: Double, pressure: Double = 0.5) {
        self.x = x
        self.y = y
        self.pressure = pressure
    }
}

public struct InkStroke: Codable, Hashable, Identifiable, Sendable {
    public let id: UUID
    public var points: [InkStrokePoint]
    public var colorHex: String
    public var lineWidth: Double
    public var opacity: Double
    public var zIndex: Int
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        points: [InkStrokePoint],
        colorHex: String = "#E05A47",
        lineWidth: Double = 3.0,
        opacity: Double = 0.92,
        zIndex: Int = 1000,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.points = points
        self.colorHex = colorHex
        self.lineWidth = lineWidth
        self.opacity = opacity
        self.zIndex = zIndex
        self.createdAt = createdAt
    }
}

public struct MoodboardDocument: Codable, Hashable, Identifiable, Sendable {
    public let id: UUID
    public var title: String
    public var subtitle: String
    public var mode: BoardLayoutMode
    public var nodes: [BoardNode]
    public var connectors: [BoardConnector]
    public var inkStrokes: [InkStroke]
    public var extractedPalette: [LabColor]
    public var candidateAssetIDs: [UUID]
    public var pinnedOffline: Bool
    public var viewportCenter: BoardPoint
    public var viewportZoom: Double
    public var createdAt: Date
    public var updatedAt: Date
    public var updatedHLC: Int64

    public var referencedAssetIDs: [UUID] {
        nodes.compactMap(\.referencedAssetID)
    }

    public init(
        id: UUID = UUID(),
        title: String,
        subtitle: String = "",
        mode: BoardLayoutMode = .autoEditorial(AutoLayoutConfig()),
        nodes: [BoardNode] = [],
        connectors: [BoardConnector] = [],
        inkStrokes: [InkStroke] = [],
        extractedPalette: [LabColor] = [],
        candidateAssetIDs: [UUID] = [],
        pinnedOffline: Bool = false,
        viewportCenter: BoardPoint = .zero,
        viewportZoom: Double = 1.0,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        updatedHLC: Int64 = 0
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.mode = mode
        self.nodes = nodes
        self.connectors = connectors
        self.inkStrokes = inkStrokes
        self.extractedPalette = extractedPalette
        self.candidateAssetIDs = candidateAssetIDs
        self.pinnedOffline = pinnedOffline
        self.viewportCenter = viewportCenter
        self.viewportZoom = viewportZoom
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.updatedHLC = updatedHLC
    }
}

public struct MoodboardSummary: Codable, Hashable, Identifiable, Sendable {
    public let id: UUID
    public var title: String
    public var subtitle: String
    public var mode: BoardLayoutMode
    public var itemCount: Int
    public var previewAssetIDs: [UUID]
    public var paletteHexes: [String]
    public var pinnedOffline: Bool
    public var updatedAt: Date

    public init(
        id: UUID,
        title: String,
        subtitle: String = "",
        mode: BoardLayoutMode = .autoEditorial(AutoLayoutConfig()),
        itemCount: Int = 0,
        previewAssetIDs: [UUID] = [],
        paletteHexes: [String] = [],
        pinnedOffline: Bool = false,
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.mode = mode
        self.itemCount = itemCount
        self.previewAssetIDs = previewAssetIDs
        self.paletteHexes = paletteHexes
        self.pinnedOffline = pinnedOffline
        self.updatedAt = updatedAt
    }
}

public enum MoodboardSeed: Codable, Hashable, Sendable {
    case prompt(String)
    case seedAssets([UUID])
    case palette([LabColor], tolerance: Double)
    case manualSelection([UUID])
    case combined(prompt: String?, seedAssetIDs: [UUID], palette: [LabColor])
}

public struct MoodboardProposal: Codable, Hashable, Sendable {
    public var draftDocument: MoodboardDocument
    public var primaryMatches: [ScoredAsset]
    public var candidatePool: [ScoredAsset]
    public var extractedPalette: [LabColor]
    public var usedCloudAI: Bool

    public init(
        draftDocument: MoodboardDocument,
        primaryMatches: [ScoredAsset],
        candidatePool: [ScoredAsset],
        extractedPalette: [LabColor],
        usedCloudAI: Bool
    ) {
        self.draftDocument = draftDocument
        self.primaryMatches = primaryMatches
        self.candidatePool = candidatePool
        self.extractedPalette = extractedPalette
        self.usedCloudAI = usedCloudAI
    }
}
