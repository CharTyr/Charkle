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

    /// Construct from TypeSafe `Box` edges (`top`, `bottom`, `left`, `right` in `[0, 1]`, top-left origin).
    public init(boxTop top: Double, bottom: Double, left: Double, right: Double) {
        let clampedLeft = max(0.0, min(1.0, left))
        let clampedRight = max(clampedLeft, min(1.0, right))
        let clampedTop = max(0.0, min(1.0, top))
        let clampedBottom = max(clampedTop, min(1.0, bottom))
        self.x = clampedLeft
        self.y = clampedTop
        self.width = max(0.02, clampedRight - clampedLeft)
        self.height = max(0.02, clampedBottom - clampedTop)
    }

    public static let full = NormalizedCropRect()

    public var minX: Double { x }
    public var minY: Double { y }
    public var maxX: Double { min(1.0, x + width) }
    public var maxY: Double { min(1.0, y + height) }
    public var area: Double { max(0.0, width) * max(0.0, height) }

    public var centerPoint: BoardPoint {
        BoardPoint(x: max(0.0, min(1.0, x + width * 0.5)), y: max(0.0, min(1.0, y + height * 0.5)))
    }

    /// True when this rect represents a genuine sub-region (not effectively the whole frame).
    public var isMeaningfulSubregion: Bool {
        width >= 0.04 && height >= 0.04 && area < 0.96
    }

    /// Clamp edges safely inside `[0, 1]`.
    public func clamped() -> NormalizedCropRect {
        let left = max(0.0, min(0.98, x))
        let top = max(0.0, min(0.98, y))
        let right = max(left + 0.02, min(1.0, x + width))
        let bottom = max(top + 0.02, min(1.0, y + height))
        return NormalizedCropRect(x: left, y: top, width: right - left, height: bottom - top)
    }

    /// Expand each edge outward by `fraction` of full image dimensions, clamped inside `[0, 1]`.
    public func padded(by fraction: Double) -> NormalizedCropRect {
        let pad = max(0.0, min(0.35, fraction))
        let left = max(0.0, x - pad)
        let top = max(0.0, y - pad)
        let right = min(1.0, x + width + pad)
        let bottom = min(1.0, y + height + pad)
        return NormalizedCropRect(x: left, y: top, width: max(0.02, right - left), height: max(0.02, bottom - top))
    }

    /// Map a normalized point in full-image coordinates into the visible coordinate space of this crop.
    public func mappingImagePointToVisible(_ point: BoardPoint) -> BoardPoint {
        guard width > 0.01, height > 0.01 else { return point }
        let vx = (point.x - x) / width
        let vy = (point.y - y) / height
        return BoardPoint(x: max(0.02, min(0.98, vx)), y: max(0.02, min(0.98, vy)))
    }
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
    public var flipHorizontal: Bool
    public var flipVertical: Bool
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
        flipHorizontal: Bool = false,
        flipVertical: Bool = false,
        isLocked: Bool = false,
        editorialOrder: Int = 0,
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.kind = kind
        self.frame = frame
        self.zIndex = zIndex
        self.rotationDegrees = rotationDegrees
        self.flipHorizontal = flipHorizontal
        self.flipVertical = flipVertical
        self.isLocked = isLocked
        self.editorialOrder = editorialOrder
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, frame, zIndex, rotationDegrees, flipHorizontal, flipVertical, isLocked, editorialOrder, updatedAt
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        kind = try c.decode(BoardNodeKind.self, forKey: .kind)
        frame = try c.decode(BoardRect.self, forKey: .frame)
        zIndex = try c.decodeIfPresent(Int.self, forKey: .zIndex) ?? 0
        rotationDegrees = try c.decodeIfPresent(Double.self, forKey: .rotationDegrees) ?? 0
        flipHorizontal = try c.decodeIfPresent(Bool.self, forKey: .flipHorizontal) ?? false
        flipVertical = try c.decodeIfPresent(Bool.self, forKey: .flipVertical) ?? false
        isLocked = try c.decodeIfPresent(Bool.self, forKey: .isLocked) ?? false
        editorialOrder = try c.decodeIfPresent(Int.self, forKey: .editorialOrder) ?? 0
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
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
    /// Optional normalized point (`0...1` inside `fromNode.frame`) for pinpoint callouts.
    public var fromNormalizedPoint: BoardPoint?
    public var toNodeID: UUID
    public var toAnchor: ConnectorAnchor
    /// Optional normalized point (`0...1` inside `toNode.frame`) so arrows can point directly onto an object inside an image.
    public var toNormalizedPoint: BoardPoint?
    public var label: String?
    public var colorHex: String
    public var style: ConnectorStyle
    public var dashed: Bool
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        fromNodeID: UUID,
        fromAnchor: ConnectorAnchor = .auto,
        fromNormalizedPoint: BoardPoint? = nil,
        toNodeID: UUID,
        toAnchor: ConnectorAnchor = .auto,
        toNormalizedPoint: BoardPoint? = nil,
        label: String? = nil,
        colorHex: String = "#5C6672",
        style: ConnectorStyle = .curved,
        dashed: Bool = false,
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.fromNodeID = fromNodeID
        self.fromAnchor = fromAnchor
        self.fromNormalizedPoint = fromNormalizedPoint
        self.toNodeID = toNodeID
        self.toAnchor = toAnchor
        self.toNormalizedPoint = toNormalizedPoint
        self.label = label
        self.colorHex = colorHex
        self.style = style
        self.dashed = dashed
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, fromNodeID, fromAnchor, fromNormalizedPoint, toNodeID, toAnchor, toNormalizedPoint
        case label, colorHex, style, dashed, updatedAt
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        fromNodeID = try c.decode(UUID.self, forKey: .fromNodeID)
        fromAnchor = try c.decodeIfPresent(ConnectorAnchor.self, forKey: .fromAnchor) ?? .auto
        fromNormalizedPoint = try c.decodeIfPresent(BoardPoint.self, forKey: .fromNormalizedPoint)
        toNodeID = try c.decode(UUID.self, forKey: .toNodeID)
        toAnchor = try c.decodeIfPresent(ConnectorAnchor.self, forKey: .toAnchor) ?? .auto
        toNormalizedPoint = try c.decodeIfPresent(BoardPoint.self, forKey: .toNormalizedPoint)
        label = try c.decodeIfPresent(String.self, forKey: .label)
        colorHex = try c.decodeIfPresent(String.self, forKey: .colorHex) ?? "#5C6672"
        style = try c.decodeIfPresent(ConnectorStyle.self, forKey: .style) ?? .curved
        dashed = try c.decodeIfPresent(Bool.self, forKey: .dashed) ?? false
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
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

public enum MoodboardAgentPhase: String, Codable, Hashable, Sendable {
    case planning
    case retrieving
    case inspectingVisuals
    case composing
    case verifying
    case repairing
    case completed
    case fallbackOffline
}

public enum MoodboardAgentStepStatus: String, Codable, Hashable, Sendable {
    case running
    case done
    case warning
}

public struct MoodboardAgentStep: Codable, Hashable, Identifiable, Sendable {
    public let id: UUID
    public var phase: MoodboardAgentPhase
    public var title: String
    public var detail: String
    public var status: MoodboardAgentStepStatus
    public var timestamp: Date

    public init(
        id: UUID = UUID(),
        phase: MoodboardAgentPhase,
        title: String,
        detail: String = "",
        status: MoodboardAgentStepStatus = .running,
        timestamp: Date = Date()
    ) {
        self.id = id
        self.phase = phase
        self.title = title
        self.detail = detail
        self.status = status
        self.timestamp = timestamp
    }
}

public struct MoodboardSectionDraft: Codable, Hashable, Identifiable, Sendable {
    public let id: UUID
    public var title: String
    public var tint: GroupTint
    public var rationale: String
    public var assetIDs: [UUID]
    public var heroAssetIDs: [UUID]

    public init(
        id: UUID = UUID(),
        title: String,
        tint: GroupTint = .neutral,
        rationale: String = "",
        assetIDs: [UUID],
        heroAssetIDs: [UUID] = []
    ) {
        self.id = id
        self.title = title
        self.tint = tint
        self.rationale = rationale
        self.assetIDs = assetIDs
        self.heroAssetIDs = heroAssetIDs
    }
}

/// Composable multi-signal curation brief powering both the built-in Moodboard Agent Harness
/// and external Agent tools (MCP / CLI).
public struct MoodboardCurationRequest: Codable, Hashable, Sendable {
    public var prompt: String
    public var seedAssetIDs: [UUID]
    public var scopeFolderIDs: [UUID]
    public var requiredTags: [String]
    public var targetPalette: [LabColor]
    public var colorTolerance: Double
    public var preferredCount: Int
    public var candidateCount: Int
    public var layoutStyle: EditorialStyle
    public var useFreeformLayout: Bool
    public var includeCuratorNotes: Bool
    public var excludedAssetIDs: [UUID]
    public var lockedAssetIDs: [UUID]
    public var existingBoard: MoodboardDocument?
    public var refinementInstruction: String?
    /// Phase 2: Automatically run Jev Box detail-focus crop on selected primary assets matching `prompt`.
    public var autoFocusDetailCrop: Bool

    public init(
        prompt: String = "",
        seedAssetIDs: [UUID] = [],
        scopeFolderIDs: [UUID] = [],
        requiredTags: [String] = [],
        targetPalette: [LabColor] = [],
        colorTolerance: Double = 28.0,
        preferredCount: Int = 12,
        candidateCount: Int = 24,
        layoutStyle: EditorialStyle = .magazine,
        useFreeformLayout: Bool = false,
        includeCuratorNotes: Bool = true,
        excludedAssetIDs: [UUID] = [],
        lockedAssetIDs: [UUID] = [],
        existingBoard: MoodboardDocument? = nil,
        refinementInstruction: String? = nil,
        autoFocusDetailCrop: Bool = false
    ) {
        self.prompt = prompt
        self.seedAssetIDs = seedAssetIDs
        self.scopeFolderIDs = scopeFolderIDs
        self.requiredTags = requiredTags
        self.targetPalette = targetPalette
        self.colorTolerance = colorTolerance
        self.preferredCount = preferredCount
        self.candidateCount = candidateCount
        self.layoutStyle = layoutStyle
        self.useFreeformLayout = useFreeformLayout
        self.includeCuratorNotes = includeCuratorNotes
        self.excludedAssetIDs = excludedAssetIDs
        self.lockedAssetIDs = lockedAssetIDs
        self.existingBoard = existingBoard
        self.refinementInstruction = refinementInstruction
        self.autoFocusDetailCrop = autoFocusDetailCrop
    }

    private enum CodingKeys: String, CodingKey {
        case prompt, seedAssetIDs, scopeFolderIDs, requiredTags, targetPalette, colorTolerance
        case preferredCount, candidateCount, layoutStyle, useFreeformLayout, includeCuratorNotes
        case excludedAssetIDs, lockedAssetIDs, existingBoard, refinementInstruction, autoFocusDetailCrop
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        prompt = try c.decodeIfPresent(String.self, forKey: .prompt) ?? ""
        seedAssetIDs = try c.decodeIfPresent([UUID].self, forKey: .seedAssetIDs) ?? []
        scopeFolderIDs = try c.decodeIfPresent([UUID].self, forKey: .scopeFolderIDs) ?? []
        requiredTags = try c.decodeIfPresent([String].self, forKey: .requiredTags) ?? []
        targetPalette = try c.decodeIfPresent([LabColor].self, forKey: .targetPalette) ?? []
        colorTolerance = try c.decodeIfPresent(Double.self, forKey: .colorTolerance) ?? 28.0
        preferredCount = try c.decodeIfPresent(Int.self, forKey: .preferredCount) ?? 12
        candidateCount = try c.decodeIfPresent(Int.self, forKey: .candidateCount) ?? 24
        layoutStyle = try c.decodeIfPresent(EditorialStyle.self, forKey: .layoutStyle) ?? .magazine
        useFreeformLayout = try c.decodeIfPresent(Bool.self, forKey: .useFreeformLayout) ?? false
        includeCuratorNotes = try c.decodeIfPresent(Bool.self, forKey: .includeCuratorNotes) ?? true
        excludedAssetIDs = try c.decodeIfPresent([UUID].self, forKey: .excludedAssetIDs) ?? []
        lockedAssetIDs = try c.decodeIfPresent([UUID].self, forKey: .lockedAssetIDs) ?? []
        existingBoard = try c.decodeIfPresent(MoodboardDocument.self, forKey: .existingBoard)
        refinementInstruction = try c.decodeIfPresent(String.self, forKey: .refinementInstruction)
        autoFocusDetailCrop = try c.decodeIfPresent(Bool.self, forKey: .autoFocusDetailCrop) ?? false
    }
}

public struct MoodboardProposal: Codable, Hashable, Sendable {
    public var draftDocument: MoodboardDocument
    public var primaryMatches: [ScoredAsset]
    public var candidatePool: [ScoredAsset]
    public var extractedPalette: [LabColor]
    public var usedCloudAI: Bool
    public var curatedSummary: String
    public var agentTrace: [MoodboardAgentStep]
    public var sections: [MoodboardSectionDraft]
    public var rejectedSummary: String?
    public var cachedVisualInsightsCount: Int

    public init(
        draftDocument: MoodboardDocument,
        primaryMatches: [ScoredAsset],
        candidatePool: [ScoredAsset],
        extractedPalette: [LabColor],
        usedCloudAI: Bool,
        curatedSummary: String = "",
        agentTrace: [MoodboardAgentStep] = [],
        sections: [MoodboardSectionDraft] = [],
        rejectedSummary: String? = nil,
        cachedVisualInsightsCount: Int = 0
    ) {
        self.draftDocument = draftDocument
        self.primaryMatches = primaryMatches
        self.candidatePool = candidatePool
        self.extractedPalette = extractedPalette
        self.usedCloudAI = usedCloudAI
        self.curatedSummary = curatedSummary
        self.agentTrace = agentTrace
        self.sections = sections
        self.rejectedSummary = rejectedSummary
        self.cachedVisualInsightsCount = cachedVisualInsightsCount
    }
}
