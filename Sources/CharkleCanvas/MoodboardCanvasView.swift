import AppKit
import CharkleCore
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Moodboard Interactive Tool Mode

public enum MoodboardTool: String, CaseIterable, Sendable {
    case select
    case pan
    case connector
    case pen
    case eraser

    public var label: String {
        switch self {
        case .select: "选择"
        case .pan: "抓手"
        case .connector: "连线"
        case .pen: "手绘"
        case .eraser: "橡皮"
        }
    }

    public var shortcutHint: String {
        switch self {
        case .select: "V"
        case .pan: "H"
        case .connector: "C"
        case .pen: "P"
        case .eraser: "E"
        }
    }
}

public struct MoodboardCanvasCallbacks {
    public var onCommitDocument: (MoodboardDocument) -> Void
    public var onPersistViewport: (BoardPoint, Double) -> Void
    public var onUndo: () -> Void
    public var onRedo: () -> Void
    public var onSelectSwapTarget: (UUID?) -> Void
    public var onOpenQuickLook: (AssetRecord) -> Void
    public var onRevealInLibrary: (UUID) -> Void
    public var onRevealInFinder: (UUID) -> Void
    public var onCopyAssets: ([UUID]) -> Void
    public var onCutAssets: ([UUID]) -> Void
    public var onPasteIntoBoard: (BoardPoint?) -> Void
    public var onDropExternalInputs: ([CaptureInput], BoardPoint?) -> Void
    public var onDropLibraryAssetIDs: ([UUID], BoardPoint?) -> Void
    public var onCopyColorHex: (String) -> Void
    public var onSearchByColorHex: (String) -> Void
    public var onCopyExportedImage: (MoodboardExportOptions) -> Void
    public var onSaveExportedImage: (MoodboardExportFormat, MoodboardExportOptions) -> Void
    public var onExportFigmaBundle: (MoodboardExportOptions) -> Void
    public var onOpenFigmaPluginGuide: () -> Void
    public var onSmartFocusNode: (UUID, UUID, String?) -> Void
    public var onVisualMatchCropNode: (UUID, UUID, UUID) -> Void
    public var onCleanCropNode: (UUID, UUID) -> Void
    public var onPinpointAnnotateNode: (UUID, UUID, String, String) -> Void

    public init(
        onCommitDocument: @escaping (MoodboardDocument) -> Void = { _ in },
        onPersistViewport: @escaping (BoardPoint, Double) -> Void = { _, _ in },
        onUndo: @escaping () -> Void = {},
        onRedo: @escaping () -> Void = {},
        onSelectSwapTarget: @escaping (UUID?) -> Void = { _ in },
        onOpenQuickLook: @escaping (AssetRecord) -> Void = { _ in },
        onRevealInLibrary: @escaping (UUID) -> Void = { _ in },
        onRevealInFinder: @escaping (UUID) -> Void = { _ in },
        onCopyAssets: @escaping ([UUID]) -> Void = { _ in },
        onCutAssets: @escaping ([UUID]) -> Void = { _ in },
        onPasteIntoBoard: @escaping (BoardPoint?) -> Void = { _ in },
        onDropExternalInputs: @escaping ([CaptureInput], BoardPoint?) -> Void = { _, _ in },
        onDropLibraryAssetIDs: @escaping ([UUID], BoardPoint?) -> Void = { _, _ in },
        onCopyColorHex: @escaping (String) -> Void = { _ in },
        onSearchByColorHex: @escaping (String) -> Void = { _ in },
        onCopyExportedImage: @escaping (MoodboardExportOptions) -> Void = { _ in },
        onSaveExportedImage: @escaping (MoodboardExportFormat, MoodboardExportOptions) -> Void = { _, _ in },
        onExportFigmaBundle: @escaping (MoodboardExportOptions) -> Void = { _ in },
        onOpenFigmaPluginGuide: @escaping () -> Void = {},
        onSmartFocusNode: @escaping (UUID, UUID, String?) -> Void = { _, _, _ in },
        onVisualMatchCropNode: @escaping (UUID, UUID, UUID) -> Void = { _, _, _ in },
        onCleanCropNode: @escaping (UUID, UUID) -> Void = { _, _ in },
        onPinpointAnnotateNode: @escaping (UUID, UUID, String, String) -> Void = { _, _, _, _ in }
    ) {
        self.onCommitDocument = onCommitDocument
        self.onPersistViewport = onPersistViewport
        self.onUndo = onUndo
        self.onRedo = onRedo
        self.onSelectSwapTarget = onSelectSwapTarget
        self.onOpenQuickLook = onOpenQuickLook
        self.onRevealInLibrary = onRevealInLibrary
        self.onRevealInFinder = onRevealInFinder
        self.onCopyAssets = onCopyAssets
        self.onCutAssets = onCutAssets
        self.onPasteIntoBoard = onPasteIntoBoard
        self.onDropExternalInputs = onDropExternalInputs
        self.onDropLibraryAssetIDs = onDropLibraryAssetIDs
        self.onCopyColorHex = onCopyColorHex
        self.onSearchByColorHex = onSearchByColorHex
        self.onCopyExportedImage = onCopyExportedImage
        self.onSaveExportedImage = onSaveExportedImage
        self.onExportFigmaBundle = onExportFigmaBundle
        self.onOpenFigmaPluginGuide = onOpenFigmaPluginGuide
        self.onSmartFocusNode = onSmartFocusNode
        self.onVisualMatchCropNode = onVisualMatchCropNode
        self.onCleanCropNode = onCleanCropNode
        self.onPinpointAnnotateNode = onPinpointAnnotateNode
    }
}

// MARK: - Dual-Mode Moodboard Studio Canvas

public struct MoodboardCanvasView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public let document: MoodboardDocument
    public let assetsByID: [UUID: AssetRecord]
    public let loader: ThumbnailImageLoader
    public let swappingNodeID: UUID?
    public let canUndo: Bool
    public let canRedo: Bool
    public let isOverlayPresented: Bool
    public let heroNamespace: Namespace.ID
    public let callbacks: MoodboardCanvasCallbacks

    // Canvas viewport & tool state
    @State private var viewportSize: CGSize = CGSize(width: 1080, height: 760)
    @State private var activeTool: MoodboardTool = .select
    @State private var selectedNodeIDs: Set<UUID> = []
    @State private var selectedConnectorID: UUID?
    @State private var isDropTargeted: Bool = false

    // Isolated @Observable camera & hover models so 60-120Hz trackpad panning / zooming
    // NEVER invalidates MoodboardCanvasView.body or re-renders toolbars / node trees!
    @State private var camera = FreeformCameraState()
    @State private var hoverState = FreeformHoverState()
    @State private var gestureStartZoom: CGFloat?
    @State private var panStartCenter: CGPoint?
    @State private var isSpaceKeyPanning: Bool = false

    // Live interactive edits (1:1 pointer tracking without mutating undo stack every frame)
    @State private var activeNodeDragID: UUID?
    @State private var activeNodeDragDelta: CGSize = .zero
    @State private var activeGroupChildIDs: Set<UUID> = []
    @State private var snapGuidesX: [CGFloat] = []
    @State private var snapGuidesY: [CGFloat] = []

    private enum ResizeCorner: CaseIterable {
        case topLeading
        case topTrailing
        case bottomLeading
        case bottomTrailing

        var signX: Double {
            switch self {
            case .topLeading, .bottomLeading: -1
            case .topTrailing, .bottomTrailing: 1
            }
        }

        var signY: Double {
            switch self {
            case .topLeading, .topTrailing: -1
            case .bottomLeading, .bottomTrailing: 1
            }
        }
    }

    @State private var resizingNodeID: UUID?
    @State private var resizingCorner: ResizeCorner?
    @State private var resizeStartFrame: BoardRect?
    @State private var liveResizeFrame: BoardRect?
    @State private var liveGroupReflowChildIDs: [UUID] = []
    @State private var liveGroupReflowFrames: [UUID: BoardRect] = [:]
    @State private var resizingSideEdge: Int = 0 // -1 leading, +1 trailing, 0 corner

    @State private var rotatingNodeID: UUID?
    @State private var rotationStartDegrees: Double = 0
    @State private var rotationDragStartAngle: Double = 0
    @State private var liveRotationDegrees: Double?

    // Connector creation & label editing
    @State private var pendingConnectorSource: (nodeID: UUID, anchor: ConnectorAnchor, startWorld: CGPoint)?
    @State private var pendingConnectorCursorWorld: CGPoint = .zero
    @State private var connectorStyle: ConnectorStyle = .curved
    @State private var connectorDashed: Bool = false
    @State private var editingConnectorLabelID: UUID?
    @State private var connectorLabelDraft: String = ""

    // Freehand Ink Pen
    @State private var inkColorHex: String = "#D95D48"
    @State private var inkWidth: Double = 3.5
    @State private var activeInkPoints: [InkStrokePoint] = []
    @State private var exportIncludeAnnotations: Bool = true
    @State private var exportIncludePalette: Bool = true

    // Marquee selection in Freeform
    @State private var freeformMarqueeStart: CGPoint?
    @State private var freeformMarqueeCurrent: CGPoint?

    // Experimental TypeSafe Box sheets (semantic crop, visual-match crop & pinpoint annotation)
    @State private var semanticCropTarget: (nodeID: UUID, assetID: UUID)?
    @State private var semanticCropQuery: String = ""
    @State private var visualMatchTarget: (nodeID: UUID, assetID: UUID)?
    @State private var pinpointAnnotateTarget: (nodeID: UUID, assetID: UUID)?
    @State private var pinpointTargetQuery: String = ""
    @State private var pinpointNoteDraft: String = ""

    private static let calmInkSwatches: [(name: String, hex: String)] = [
        ("陶红", "#D95D48"),
        ("墨炭", "#2C3038"),
        ("钴蓝", "#3D6A99"),
        ("青苔", "#4D7C5F"),
        ("赭黄", "#C7933B"),
        ("粉白", "#EFECE6")
    ]

    public init(
        document: MoodboardDocument,
        assetsByID: [UUID: AssetRecord],
        loader: ThumbnailImageLoader,
        swappingNodeID: UUID?,
        canUndo: Bool,
        canRedo: Bool,
        isOverlayPresented: Bool = false,
        heroNamespace: Namespace.ID,
        callbacks: MoodboardCanvasCallbacks
    ) {
        self.document = document
        self.assetsByID = assetsByID
        self.loader = loader
        self.swappingNodeID = swappingNodeID
        self.canUndo = canUndo
        self.canRedo = canRedo
        self.isOverlayPresented = isOverlayPresented
        self.heroNamespace = heroNamespace
        self.callbacks = callbacks
    }

    private var showTopPaletteStrip: Bool {
        switch document.mode {
        case .autoEditorial(let cfg): cfg.showPaletteStrip
        case .freeform: true
        }
    }

    public var body: some View {
        ZStack {
            CanvasSurface.ground(for: colorScheme)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture {
                    clearCanvasSelection()
                }

            freeformInfiniteStage

            // Top floating Board Palette Strip (cleanly positioned below main floating search/header)
            VStack {
                if showTopPaletteStrip && !document.extractedPalette.isEmpty {
                    BoardPaletteHeaderStrip(
                        colors: document.extractedPalette,
                        onCopyHex: callbacks.onCopyColorHex,
                        onSearchColor: callbacks.onSearchByColorHex
                    )
                    .padding(.top, 14)
                    .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
                }
                Spacer()
            }

            // Bottom-Right Freeform Zoom Controls (isolated leaf view — only observes camera.zoom)
            VStack {
                Spacer()
                HStack {
                    Spacer()
                    FreeformZoomControlsPill(
                        camera: camera,
                        reduceMotion: reduceMotion,
                        onZoomStep: { factor in
                            applyZoom(factor: factor, anchorScreenPoint: CGPoint(x: viewportSize.width * 0.5, y: viewportSize.height * 0.5))
                            persistCameraViewport()
                        },
                        onResetZoom: {
                            withAnimation(CanvasMotion.accessible(CanvasMotion.uiSpring, reduced: reduceMotion)) {
                                camera.setZoom(1.0)
                            }
                            persistCameraViewport()
                        },
                        onFitBoard: {
                            fitBoardToScreen()
                        }
                    )
                }
                .padding(.trailing, 20)
                .padding(.bottom, 20)
            }

            // Bottom-Center Floating Liquid Glass Transform Pill (when nodes selected) + Tool Dock
            VStack(spacing: 8) {
                Spacer()
                if !selectedUnlockedNodes.isEmpty && activeTool == .select {
                    selectedTransformBar
                        .transition(
                            .opacity
                                .combined(with: .scale(scale: 0.94, anchor: .bottom))
                                .combined(with: .offset(y: 6))
                        )
                }
                floatingToolDock
                    .padding(.bottom, 18)
            }
            .animation(CanvasMotion.accessible(CanvasMotion.settleStrong, reduced: reduceMotion), value: selectedNodeIDs)

            // External drop highlight border
            CanvasDropRingOverlay(isTargeted: isDropTargeted, padding: 10, fillOpacity: 0.04)
        }
        .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
        .background {
            // Measure proposed safe-area viewport completely decoupled from ScrollView content
            // so Auto Editorial width/height never oscillates with scrollbar show/hide.
            Color.clear
                .onGeometryChange(for: CGSize.self) { proxy in
                    CGSize(width: floor(proxy.size.width), height: floor(proxy.size.height))
                } action: { _, newSize in
                    if newSize.width > 120, newSize.height > 120,
                       (abs(newSize.width - viewportSize.width) >= 2 || abs(newSize.height - viewportSize.height) >= 2) {
                        viewportSize = newSize
                    }
                }
        }
        .onAppear {
            syncCameraFromDocument()
            ensureFreeformModeIfLegacy()
        }
        .onChange(of: document.id) { _, _ in
            selectedNodeIDs.removeAll()
            selectedConnectorID = nil
            activeTool = .select
            syncCameraFromDocument()
            ensureFreeformModeIfLegacy()
        }
        .onDrop(of: [.fileURL, .url, .image, .plainText], isTargeted: $isDropTargeted) { providers, location in
            handleCanvasDrop(providers: providers, screenLocation: location)
        }
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.escape) {
            if pendingConnectorSource != nil {
                pendingConnectorSource = nil
                return .handled
            }
            if activeTool != .select {
                activeTool = .select
                return .handled
            }
            selectedNodeIDs.removeAll()
            selectedConnectorID = nil
            callbacks.onSelectSwapTarget(nil)
            return .handled
        }
        .onKeyPress(.delete) {
            guard !isEditingTextInWindow else { return .ignored }
            deleteCurrentSelection()
            return .handled
        }
        .onKeyPress(characters: CharacterSet(charactersIn: "acxvhperACXVHPER")) { press in
            guard !isEditingTextInWindow else { return .ignored }
            let lower = press.characters.lowercased()
            if press.modifiers == [.command] {
                switch lower {
                case "a":
                    selectedNodeIDs = Set(document.nodes.map(\.id))
                    selectedConnectorID = nil
                    return .handled
                case "c":
                    let ids = selectedAssetIDs()
                    guard !ids.isEmpty else { return .ignored }
                    callbacks.onCopyAssets(ids)
                    return .handled
                case "x":
                    guard !selectedNodeIDs.isEmpty else { return .ignored }
                    cutBoardNodes(selectedNodeIDs)
                    return .handled
                case "v":
                    callbacks.onPasteIntoBoard(defaultPasteLocation())
                    return .handled
                default:
                    return .ignored
                }
            }
            // Transform shortcuts work whenever unlocked nodes are selected (both modes)
            if !selectedUnlockedNodes.isEmpty {
                if lower == "r" && press.modifiers.isEmpty {
                    rotateSelectedNodes(by: 90)
                    return .handled
                }
                if lower == "r" && press.modifiers == [.shift] {
                    rotateSelectedNodes(by: -90)
                    return .handled
                }
                if lower == "h" && press.modifiers == [.shift] {
                    flipSelectedNodes(horizontal: true)
                    return .handled
                }
                if lower == "v" && press.modifiers == [.shift] {
                    flipSelectedNodes(horizontal: false)
                    return .handled
                }
            }
            guard press.modifiers.isEmpty else { return .ignored }
            switch lower {
            case "v": activeTool = .select; return .handled
            case "h": activeTool = .pan; return .handled
            case "c": activeTool = .connector; return .handled
            case "p": activeTool = .pen; return .handled
            case "e": activeTool = .eraser; return .handled
            default: return .ignored
            }
        }
        .popover(isPresented: Binding(
            get: { editingConnectorLabelID != nil },
            set: { if !$0 { editingConnectorLabelID = nil } }
        )) {
            connectorLabelEditorPopover
        }
        .sheet(isPresented: Binding(
            get: { semanticCropTarget != nil },
            set: { if !$0 { semanticCropTarget = nil } }
        )) {
            semanticCropSheet
        }
        .sheet(isPresented: Binding(
            get: { visualMatchTarget != nil },
            set: { if !$0 { visualMatchTarget = nil } }
        )) {
            visualMatchPickerSheet
        }
        .sheet(isPresented: Binding(
            get: { pinpointAnnotateTarget != nil },
            set: { if !$0 { pinpointAnnotateTarget = nil } }
        )) {
            pinpointAnnotateSheet
        }
    }

    // MARK: - Freeform Infinite Canvas Mode (GPU-Transformed 120fps Stage)

    private var freeformInfiniteStage: some View {
        let sortedNodes = document.nodes.sorted { lhs, rhs in
            let lGroup = if case .groupFrame = lhs.kind { true } else { false }
            let rGroup = if case .groupFrame = rhs.kind { true } else { false }
            if lGroup != rGroup { return lGroup }
            return lhs.zIndex < rhs.zIndex
        }
        let nodeFramesMap: [UUID: BoardRect] = Dictionary(
            uniqueKeysWithValues: document.nodes.map { ($0.id, effectiveFrame(for: $0)) }
        )
        let allowNodeHitTesting = activeTool != .pen && activeTool != .eraser && activeTool != .pan && !isSpaceKeyPanning

        return ZStack {
            // 1. GPU-tiled architectural dot grid (1 cached CGImage tile + GPU offset, zero Path loop)
            FreeformDotGridLayer(camera: camera, viewportSize: viewportSize)

            // 2. Native macOS trackpad scroll-pan, Option/Cmd zoom, Middle-mouse drag pan, and Hold-Space drag pan
            FreeformInputBridge(
                isSuspended: isOverlayPresented,
                onPanDelta: { dx, dy in
                    hoverState.markPanningActivity()
                    camera.panBy(screenDX: dx, screenDY: dy)
                },
                onPanEnded: {
                    persistCameraViewport()
                },
                onZoomDelta: { factor, cursorInView in
                    hoverState.markPanningActivity()
                    camera.applyZoom(factor: factor, anchorScreenPoint: cursorInView, viewportSize: viewportSize)
                },
                onSpacePanStateChanged: { active in
                    isSpaceKeyPanning = active
                },
                onSpaceQuickTap: {
                    _ = openQuickLookForSelectedNode()
                }
            )
            .allowsHitTesting(false)

            // 3. Interactive background canvas surface: click empty area to deselect, or drag for pan/marquee/pen/eraser
            Color.clear
                .contentShape(Rectangle())
                .gesture(canvasBackgroundGesture)
                .contextMenu {
                    Button {
                        callbacks.onPasteIntoBoard(BoardPoint(camera.center))
                    } label: {
                        Label("粘贴到情绪板", systemImage: "doc.on.clipboard")
                    }
                    Divider()
                    Button {
                        addNoteNode()
                    } label: {
                        Label("添加灵感便签", systemImage: "note.text.badge.plus")
                    }
                    Button {
                        addGroupFrameNode()
                    } label: {
                        Label("添加区域分组框", systemImage: "rectangle.dashed")
                    }
                }

            // 4. Single GPU-transformed world layer: panning/zooming updates ONLY one scaleEffect+offset transform
            //    without re-evaluating FreeformWorldNodesLayer or diffing any BoardAssetNodeView / BoardNoteNodeView!
            FreeformCameraViewport(camera: camera, viewportSize: viewportSize) {
                FreeformWorldNodesLayer(
                    camera: camera,
                    viewportSize: viewportSize,
                    sortedNodes: sortedNodes,
                    nodeFramesMap: nodeFramesMap,
                    selectedNodeIDs: selectedNodeIDs,
                    effectiveRotation: { effectiveRotation(for: $0) },
                    allowNodeHitTesting: allowNodeHitTesting,
                    onHoverChanged: { nodeID, hovering in
                        hoverState.setNodeHovered(nodeID, hovering: hovering)
                    },
                    nodeBuilder: { node in
                        renderNodeBody(node: node, isAutoMode: false)
                            .contentShape(Rectangle())
                            .simultaneousGesture(
                                TapGesture(count: 1).onEnded {
                                    if activeTool == .select && !isSpaceKeyPanning {
                                        let mods = NSEvent.modifierFlags
                                        if mods.contains(.command) || mods.contains(.shift) {
                                            if selectedNodeIDs.contains(node.id) {
                                                selectedNodeIDs.remove(node.id)
                                            } else {
                                                selectedNodeIDs.insert(node.id)
                                            }
                                        } else {
                                            selectedNodeIDs = [node.id]
                                        }
                                        selectedConnectorID = nil
                                    }
                                }
                            )
                            .gesture(activeTool == .select && !isSpaceKeyPanning ? nodeDragGesture(for: node) : nil)
                    }
                )
            }

            // 5. Vector overlay (snap guides, connectors, ink strokes) — completely skipped (zero Canvas!) when empty
            FreeformVectorOverlay(
                camera: camera,
                viewportSize: viewportSize,
                connectors: document.connectors,
                inkStrokes: document.inkStrokes,
                activeInkPoints: activeInkPoints,
                inkColorHex: inkColorHex,
                inkWidth: inkWidth,
                selectedConnectorID: selectedConnectorID,
                pendingConnectorSource: pendingConnectorSource,
                pendingConnectorCursorWorld: pendingConnectorCursorWorld,
                snapGuidesX: snapGuidesX,
                snapGuidesY: snapGuidesY,
                nodeFramesMap: nodeFramesMap
            )

            // 6. Screen-space constant-size resize / rotation / connector port handles
            //    (only observes camera when a node is selected/hovered or connector tool is active)
            FreeformSelectionHandlesLayer(
                camera: camera,
                hoverState: hoverState,
                viewportSize: viewportSize,
                sortedNodes: sortedNodes,
                nodeFramesMap: nodeFramesMap,
                selectedNodeIDs: selectedNodeIDs,
                activeTool: activeTool,
                isSpaceKeyPanning: isSpaceKeyPanning,
                effectiveRotation: { effectiveRotation(for: $0) }
            ) { node, worldRect, screenCenter, screenW, screenH, currentRotation, isSelected, isHovered in
                ZStack {
                    if (activeTool == .connector || isHovered || isSelected) && activeTool != .pen && activeTool != .eraser && !isSpaceKeyPanning {
                        connectorPortsOverlay(node: node, worldRect: worldRect, width: screenW, height: screenH)
                    }
                    if isSelected && !node.isLocked && activeTool == .select && !isSpaceKeyPanning {
                        resizeHandlesOverlay(node: node, width: screenW, height: screenH, currentRotation: currentRotation)
                        rotationHandleOverlay(node: node, screenCenter: screenCenter, height: screenH, currentRotation: currentRotation)
                    }
                }
            }

            // 7. Interactive connector midpoint labels (only instantiated when connectors exist)
            if !document.connectors.isEmpty {
                FreeformConnectorLabelsLayer(
                    camera: camera,
                    viewportSize: viewportSize,
                    connectors: document.connectors,
                    nodeFramesMap: nodeFramesMap,
                    selectedConnectorID: selectedConnectorID,
                    activeTool: activeTool,
                    onSelectConnector: { connector in
                        selectedConnectorID = connector.id
                        connectorLabelDraft = connector.label ?? ""
                        editingConnectorLabelID = connector.id
                    }
                )
            }

            // 8. Freeform rubber-band marquee overlay
            if let s = freeformMarqueeStart, let c = freeformMarqueeCurrent {
                let rect = CGRect(x: min(s.x, c.x), y: min(s.y, c.y), width: abs(c.x - s.x), height: abs(c.y - s.y))
                if rect.width > 3 || rect.height > 3 {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Color.accentColor.opacity(0.11))
                        .overlay(
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .strokeBorder(Color.accentColor.opacity(0.68), lineWidth: 1)
                        )
                        .frame(width: rect.width, height: rect.height)
                        .position(x: rect.midX, y: rect.midY)
                        .allowsHitTesting(false)
                }
            }
        }
        .coordinateSpace(name: "charkle-freeform-stage")
        .clipped()
        .simultaneousGesture(
            MagnifyGesture()
                .onChanged { value in
                    hoverState.markPanningActivity()
                    if gestureStartZoom == nil {
                        gestureStartZoom = camera.zoom
                    }
                    let base = gestureStartZoom ?? camera.zoom
                    camera.setZoom(base * value.magnification)
                }
                .onEnded { _ in
                    gestureStartZoom = nil
                    persistCameraViewport()
                }
        )
    }

    // MARK: - Selection Transform Helpers & Interactive Rotation Handle

    private var selectedUnlockedNodes: [BoardNode] {
        document.nodes.filter { selectedNodeIDs.contains($0.id) && !$0.isLocked }
    }

    private func effectiveRotation(for node: BoardNode) -> Double {
        if rotatingNodeID == node.id, let live = liveRotationDegrees {
            return live
        }
        return node.rotationDegrees
    }

    private func normalizeDegrees(_ degrees: Double) -> Double {
        var d = degrees.truncatingRemainder(dividingBy: 360.0)
        if d > 180.0 { d -= 360.0 }
        if d <= -180.0 { d += 360.0 }
        if abs(d) < 0.05 { d = 0 }
        return d
    }

    private func rotateSelectedNodes(by delta: Double) {
        rotateNodes(Set(selectedUnlockedNodes.map(\.id)), by: delta)
    }

    private func rotateNodes(_ ids: Set<UUID>, by delta: Double) {
        guard !ids.isEmpty else { return }
        var nextDoc = document
        var changed = false
        for idx in nextDoc.nodes.indices where ids.contains(nextDoc.nodes[idx].id) && !nextDoc.nodes[idx].isLocked {
            nextDoc.nodes[idx].rotationDegrees = normalizeDegrees(nextDoc.nodes[idx].rotationDegrees + delta)
            nextDoc.nodes[idx].updatedAt = Date()
            changed = true
        }
        if changed {
            withAnimation(CanvasMotion.accessible(CanvasMotion.settleStrong, reduced: reduceMotion)) {
                callbacks.onCommitDocument(nextDoc)
            }
        }
    }

    private func resetRotation(for ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        var nextDoc = document
        var changed = false
        for idx in nextDoc.nodes.indices where ids.contains(nextDoc.nodes[idx].id) && !nextDoc.nodes[idx].isLocked {
            if abs(nextDoc.nodes[idx].rotationDegrees) > 0.01 {
                nextDoc.nodes[idx].rotationDegrees = 0
                nextDoc.nodes[idx].updatedAt = Date()
                changed = true
            }
        }
        if changed {
            withAnimation(CanvasMotion.accessible(CanvasMotion.settleStrong, reduced: reduceMotion)) {
                callbacks.onCommitDocument(nextDoc)
            }
        }
    }

    private func flipSelectedNodes(horizontal: Bool) {
        flipNodes(Set(selectedUnlockedNodes.map(\.id)), horizontal: horizontal)
    }

    private func flipNodes(_ ids: Set<UUID>, horizontal: Bool) {
        guard !ids.isEmpty else { return }
        var nextDoc = document
        var changed = false
        for idx in nextDoc.nodes.indices where ids.contains(nextDoc.nodes[idx].id) && !nextDoc.nodes[idx].isLocked {
            if horizontal {
                nextDoc.nodes[idx].flipHorizontal.toggle()
            } else {
                nextDoc.nodes[idx].flipVertical.toggle()
            }
            nextDoc.nodes[idx].updatedAt = Date()
            changed = true
        }
        if changed {
            withAnimation(CanvasMotion.accessible(CanvasMotion.settleStrong, reduced: reduceMotion)) {
                callbacks.onCommitDocument(nextDoc)
            }
        }
    }

    /// Top-center interactive rotation knob attached to a selected unlocked node in Freeform mode.
    /// Drag freely to rotate (hold Shift for 15° steps; magnetic snap near 0°/±90°/180°); double-click resets to 0°.
    private func rotationHandleOverlay(
        node: BoardNode,
        screenCenter: CGPoint,
        height: CGFloat,
        currentRotation: Double
    ) -> some View {
        let isDraggingThis = rotatingNodeID == node.id
        return VStack(spacing: 0) {
            ZStack {
                Circle()
                    .fill(isDraggingThis ? Color.accentColor : Color.white)
                    .frame(width: 22, height: 22)
                    .overlay(
                        Circle()
                            .strokeBorder(Color.accentColor, lineWidth: 1.5)
                    )
                    .shadow(color: .black.opacity(0.18), radius: 4, y: 1)

                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(isDraggingThis ? .white : Color.accentColor)
            }
            .overlay(alignment: .top) {
                if isDraggingThis {
                    Text("\(Int(currentRotation.rounded()))°")
                        .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Color.black.opacity(0.76), in: Capsule(style: .continuous))
                        .rotationEffect(.degrees(-currentRotation))
                        .offset(y: -28)
                        .allowsHitTesting(false)
                }
            }
            .contentShape(Circle().inset(by: -6))
            .onTapGesture(count: 2) {
                resetRotation(for: [node.id])
            }
            .highPriorityGesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .named("charkle-freeform-stage"))
                    .onChanged { value in
                        let angleNow = atan2(
                            Double(value.location.y - screenCenter.y),
                            Double(value.location.x - screenCenter.x)
                        ) * 180.0 / .pi
                        if rotatingNodeID == nil {
                            rotatingNodeID = node.id
                            rotationStartDegrees = node.rotationDegrees
                            rotationDragStartAngle = angleNow
                        }
                        var raw = normalizeDegrees(rotationStartDegrees + (angleNow - rotationDragStartAngle))
                        if NSEvent.modifierFlags.contains(.shift) {
                            raw = normalizeDegrees((raw / 15.0).rounded() * 15.0)
                        } else {
                            // Soft magnetic snap near cardinal angles (0°, ±90°, 180°)
                            let cardinals: [Double] = [0, 90, -90, 180, -180]
                            for target in cardinals where abs(raw - target) <= 3.0 {
                                raw = target == -180 ? 180 : target
                                break
                            }
                        }
                        liveRotationDegrees = raw
                    }
                    .onEnded { _ in
                        let finalAngle = liveRotationDegrees
                        rotatingNodeID = nil
                        liveRotationDegrees = nil
                        if let finalAngle, abs(finalAngle - node.rotationDegrees) > 0.05 {
                            var nextDoc = document
                            if let idx = nextDoc.nodes.firstIndex(where: { $0.id == node.id }) {
                                nextDoc.nodes[idx].rotationDegrees = normalizeDegrees(finalAngle)
                                nextDoc.nodes[idx].updatedAt = Date()
                                callbacks.onCommitDocument(nextDoc)
                            }
                        }
                    }
            )
            .help("拖拽自由旋转（按住 ⇧ 以 15° 吸附，双击归零）")

            Rectangle()
                .fill(Color.accentColor.opacity(0.75))
                .frame(width: 1.5, height: 14)
                .allowsHitTesting(false)
        }
        .offset(y: -(height * 0.5 + 18))
    }

    /// Floating Liquid Glass Transform Pill (Rotate ±90°, Reset Angle, Flip Horizontal / Vertical)
    /// shown cleanly above the bottom tool dock whenever ≥1 unlocked node is selected.
    private var selectedTransformBar: some View {
        let targets = selectedUnlockedNodes
        let single = targets.count == 1 ? targets.first : nil
        let singleAngle = single.map { effectiveRotation(for: $0) } ?? 0
        let anyFlippedH = targets.contains(where: \.flipHorizontal)
        let anyFlippedV = targets.contains(where: \.flipVertical)

        return HStack(spacing: 4) {
            if targets.count > 1 {
                Text("已选 \(targets.count) 项")
                    .font(.system(size: 11, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                Divider().frame(height: 16)
            }

            transformPillButton(icon: "rotate.left", label: "逆时针 90° (⇧R)") {
                rotateSelectedNodes(by: -90)
            }
            transformPillButton(icon: "rotate.right", label: "顺时针 90° (R)") {
                rotateSelectedNodes(by: 90)
            }

            if abs(singleAngle) > 0.1 || targets.contains(where: { abs($0.rotationDegrees) > 0.1 }) {
                Button {
                    resetRotation(for: Set(targets.map(\.id)))
                } label: {
                    HStack(spacing: 3) {
                        Text("\(Int(singleAngle.rounded()))°")
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .monospacedDigit()
                        Image(systemName: "arrow.uturn.backward")
                            .font(.system(size: 9.5, weight: .semibold))
                    }
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 5)
                    .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)
                .help("点击重置旋转角度至 0°")
            }

            Divider().frame(height: 16).padding(.horizontal, 2)

            transformPillButton(
                icon: "arrow.left.and.right.righttriangle.left.righttriangle.right",
                label: "水平翻转 (⇧H)",
                isActive: anyFlippedH
            ) {
                flipSelectedNodes(horizontal: true)
            }

            transformPillButton(
                icon: "arrow.up.and.down.righttriangle.up.righttriangle.down",
                label: "上下翻转 (⇧V)",
                isActive: anyFlippedV
            ) {
                flipSelectedNodes(horizontal: false)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .canvasLiquidGlass(in: Capsule(style: .continuous))
    }

    private func transformPillButton(
        icon: String,
        label: String,
        isActive: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(isActive ? Color.accentColor : .primary)
                .frame(width: 28, height: 26)
                .background(
                    isActive ? Color.accentColor.opacity(0.14) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                )
        }
        .buttonStyle(.plain)
        .help(label)
    }

    // MARK: - Selection & Quick Look Helpers

    private var isEditingTextInWindow: Bool {
        guard let responder = NSApp.keyWindow?.firstResponder else { return false }
        return responder is NSTextView || responder is NSTextField
    }

    private func defaultPasteLocation() -> BoardPoint? {
        BoardPoint(camera.center)
    }

    private func effectiveNodeIDs(including anchorNodeID: UUID) -> Set<UUID> {
        if selectedNodeIDs.contains(anchorNodeID) {
            return selectedNodeIDs
        }
        return [anchorNodeID]
    }

    private func selectedAssetIDs() -> [UUID] {
        var seen = Set<UUID>()
        var result: [UUID] = []
        for node in document.nodes where selectedNodeIDs.contains(node.id) {
            if let assetID = node.referencedAssetID, seen.insert(assetID).inserted {
                result.append(assetID)
            }
        }
        return result
    }

    private func effectiveAssetIDs(including anchorNodeID: UUID, fallbackAssetID: UUID) -> [UUID] {
        if selectedNodeIDs.contains(anchorNodeID) {
            let ids = selectedAssetIDs()
            if !ids.isEmpty { return ids }
        }
        return [fallbackAssetID]
    }

    private func cutBoardNodes(_ nodeIDs: Set<UUID>) {
        guard !nodeIDs.isEmpty else { return }
        var seen = Set<UUID>()
        var assetIDs: [UUID] = []
        for node in document.nodes where nodeIDs.contains(node.id) {
            if let assetID = node.referencedAssetID, seen.insert(assetID).inserted {
                assetIDs.append(assetID)
            }
        }
        guard !assetIDs.isEmpty else { return }
        callbacks.onCutAssets(assetIDs)

        let removableNodeIDs = Set(document.nodes.filter { nodeIDs.contains($0.id) && !$0.isLocked }.map(\.id))
        guard !removableNodeIDs.isEmpty else { return }
        var nextDoc = document
        nextDoc.nodes.removeAll { removableNodeIDs.contains($0.id) }
        nextDoc.connectors.removeAll { removableNodeIDs.contains($0.fromNodeID) || removableNodeIDs.contains($0.toNodeID) }
        selectedNodeIDs.subtract(removableNodeIDs)
        if let swapID = swappingNodeID, removableNodeIDs.contains(swapID) {
            callbacks.onSelectSwapTarget(nil)
        }
        callbacks.onCommitDocument(nextDoc)
    }

    private func clearCanvasSelection() {
        selectedNodeIDs.removeAll()
        selectedConnectorID = nil
        editingConnectorLabelID = nil
        callbacks.onSelectSwapTarget(nil)
        NSApp.keyWindow?.makeFirstResponder(nil)
    }

    private func openQuickLookForSelectedNode() -> Bool {
        guard let node = document.nodes.first(where: { selectedNodeIDs.contains($0.id) && $0.referencedAssetID != nil }),
              let assetID = node.referencedAssetID,
              let asset = assetsByID[assetID] else {
            return false
        }
        callbacks.onOpenQuickLook(asset)
        return true
    }

    // MARK: - Freeform Interactive Gestures (Click-to-Deselect, Pan, Marquee, Pen, Eraser, Node Drag, Resize, Ports)

    private var canvasBackgroundGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let distance = hypot(value.translation.width, value.translation.height)
                switch activeTool {
                case .pan:
                    guard distance >= 2 else { return }
                    hoverState.markPanningActivity()
                    if panStartCenter == nil { panStartCenter = camera.center }
                    if let start = panStartCenter {
                        camera.setCenter(CGPoint(
                            x: start.x - value.translation.width / camera.zoom,
                            y: start.y - value.translation.height / camera.zoom
                        ))
                    }
                case .select:
                    if NSEvent.modifierFlags.contains(.option) || isSpaceKeyPanning {
                        guard distance >= 2 else { return }
                        hoverState.markPanningActivity()
                        if panStartCenter == nil { panStartCenter = camera.center }
                        if let start = panStartCenter {
                            camera.setCenter(CGPoint(
                                x: start.x - value.translation.width / camera.zoom,
                                y: start.y - value.translation.height / camera.zoom
                            ))
                        }
                    } else {
                        guard distance >= 4 else { return }
                        if freeformMarqueeStart == nil { freeformMarqueeStart = value.startLocation }
                        freeformMarqueeCurrent = value.location
                        if let s = freeformMarqueeStart {
                            let w1 = screenToWorld(s)
                            let w2 = screenToWorld(value.location)
                            let worldBox = BoardRect(
                                x: min(w1.x, w2.x),
                                y: min(w1.y, w2.y),
                                width: abs(w2.x - w1.x),
                                height: abs(w2.y - w1.y)
                            )
                            selectedNodeIDs = Set(document.nodes.filter { $0.frame.intersects(worldBox) }.map(\.id))
                        }
                    }
                case .pen:
                    guard distance >= 2 else { return }
                    let worldPt = screenToWorld(value.location)
                    if let last = activeInkPoints.last {
                        if hypot(worldPt.x - last.x, worldPt.y - last.y) >= 2.0 / camera.zoom {
                            activeInkPoints.append(InkStrokePoint(x: worldPt.x, y: worldPt.y, pressure: 0.6))
                        }
                    } else {
                        activeInkPoints = [InkStrokePoint(x: worldPt.x, y: worldPt.y, pressure: 0.6)]
                    }
                case .eraser:
                    eraseNear(worldPoint: screenToWorld(value.location))
                case .connector:
                    break
                }
            }
            .onEnded { value in
                let distance = hypot(value.translation.width, value.translation.height)
                if panStartCenter != nil {
                    panStartCenter = nil
                    persistCameraViewport()
                }
                freeformMarqueeStart = nil
                freeformMarqueeCurrent = nil
                if activeTool == .pen && activeInkPoints.count >= 2 {
                    var nextDoc = document
                    let stroke = InkStroke(
                        points: activeInkPoints,
                        colorHex: inkColorHex,
                        lineWidth: inkWidth,
                        opacity: 0.92,
                        zIndex: 1000 + nextDoc.inkStrokes.count
                    )
                    nextDoc.inkStrokes.append(stroke)
                    activeInkPoints = []
                    callbacks.onCommitDocument(nextDoc)
                } else {
                    activeInkPoints = []
                    // Clean click on empty canvas background deselects nodes, connectors, and text focus
                    if distance < 4 && activeTool != .eraser {
                        clearCanvasSelection()
                    }
                }
            }
    }

    private func nodeDragGesture(for node: BoardNode) -> some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .named("charkle-freeform-stage"))
            .onChanged { value in
                guard !node.isLocked, resizingNodeID == nil, rotatingNodeID == nil else { return }
                if activeNodeDragID == nil {
                    activeNodeDragID = node.id
                    if !selectedNodeIDs.contains(node.id) {
                        selectedNodeIDs = [node.id]
                    }
                    // If dragging a groupFrame, capture all enclosed child nodes so they move together!
                    if case .groupFrame = node.kind {
                        let enclosed = document.nodes.filter { other in
                            guard other.id != node.id else { return false }
                            let center = BoardPoint(x: other.frame.midX, y: other.frame.midY)
                            return node.frame.contains(center)
                        }.map(\.id)
                        activeGroupChildIDs = Set(enclosed)
                    } else {
                        activeGroupChildIDs = []
                    }
                }
                var dx = value.translation.width / camera.zoom
                var dy = value.translation.height / camera.zoom

                // Smart alignment snap guides (6pt threshold)
                let snapThreshold = 6.0 / Double(camera.zoom)
                let candidateMinX = node.frame.minX + Double(dx)
                let candidateMidX = node.frame.midX + Double(dx)
                let candidateMinY = node.frame.minY + Double(dy)
                let candidateMidY = node.frame.midY + Double(dy)
                var guidesX: [CGFloat] = []
                var guidesY: [CGFloat] = []

                let movingSet = selectedNodeIDs.union(activeGroupChildIDs).union([node.id])
                for other in document.nodes where !movingSet.contains(other.id) {
                    if abs(candidateMinX - other.frame.minX) < snapThreshold {
                        dx = CGFloat(other.frame.minX - node.frame.minX)
                        guidesX = [CGFloat(other.frame.minX)]
                    } else if abs(candidateMidX - other.frame.midX) < snapThreshold {
                        dx = CGFloat(other.frame.midX - node.frame.midX)
                        guidesX = [CGFloat(other.frame.midX)]
                    }
                    if abs(candidateMinY - other.frame.minY) < snapThreshold {
                        dy = CGFloat(other.frame.minY - node.frame.minY)
                        guidesY = [CGFloat(other.frame.minY)]
                    } else if abs(candidateMidY - other.frame.midY) < snapThreshold {
                        dy = CGFloat(other.frame.midY - node.frame.midY)
                        guidesY = [CGFloat(other.frame.midY)]
                    }
                }
                snapGuidesX = guidesX
                snapGuidesY = guidesY
                activeNodeDragDelta = CGSize(width: dx, height: dy)
            }
            .onEnded { _ in
                defer {
                    activeNodeDragID = nil
                    activeNodeDragDelta = .zero
                    activeGroupChildIDs = []
                    snapGuidesX = []
                    snapGuidesY = []
                }
                guard !node.isLocked,
                      abs(activeNodeDragDelta.width) > 0.5 || abs(activeNodeDragDelta.height) > 0.5 else { return }

                let movingSet = selectedNodeIDs.union(activeGroupChildIDs).union([node.id])
                var nextDoc = document
                for idx in nextDoc.nodes.indices where movingSet.contains(nextDoc.nodes[idx].id) && !nextDoc.nodes[idx].isLocked {
                    nextDoc.nodes[idx].frame.x += Double(activeNodeDragDelta.width)
                    nextDoc.nodes[idx].frame.y += Double(activeNodeDragDelta.height)
                    nextDoc.nodes[idx].updatedAt = Date()
                }
                callbacks.onCommitDocument(nextDoc)
            }
    }

    private func resizeHandlesOverlay(
        node: BoardNode,
        width: CGFloat,
        height: CGFloat,
        currentRotation: Double
    ) -> some View {
        let minSize: (width: Double, height: Double) = switch node.kind {
        case .note: (140, 96)
        case .groupFrame: (180, 120)
        case .paletteStrip: (160, 48)
        case .assetRef: (84, 60)
        }
        let isResizingThis = resizingNodeID == node.id
        let isGroupFrame: Bool = if case .groupFrame = node.kind { true } else { false }

        return ZStack {
            // Dedicated Left & Right Side Edge Resize Bars (<|>) for Smart Auto-Layout Group Frames (Img 4)
            if isGroupFrame {
                ForEach([-1, 1], id: \.self) { side in
                    let isActiveEdge = isResizingThis && resizingSideEdge == side
                    ZStack {
                        Capsule(style: .continuous)
                            .fill(isActiveEdge ? Color.accentColor : Color.white)
                            .frame(width: 5, height: 34)
                            .overlay(
                                Capsule(style: .continuous)
                                    .strokeBorder(Color.accentColor, lineWidth: 1.5)
                            )
                            .shadow(color: .black.opacity(0.28), radius: 4, y: 1)
                    }
                    .frame(width: 24, height: 52)
                    .contentShape(Rectangle())
                    .offset(x: CGFloat(side) * width * 0.5, y: 0)
                    .highPriorityGesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .named("charkle-freeform-stage"))
                            .onChanged { value in
                                if resizingNodeID == nil {
                                    resizingNodeID = node.id
                                    resizingSideEdge = side
                                    resizeStartFrame = node.frame
                                    liveGroupReflowChildIDs = enclosedChildIDs(in: node)
                                }
                                guard let start = resizeStartFrame else { return }
                                let dx = Double(value.translation.width / camera.zoom)
                                let newW = max(minSize.width, start.width + Double(side) * dx)
                                let newX = side < 0 ? (start.maxX - newW) : start.x
                                let updatedRect = BoardRect(x: newX, y: start.y, width: newW, height: start.height)
                                liveResizeFrame = updatedRect
                                updateLiveGroupReflow(for: updatedRect)
                            }
                            .onEnded { _ in
                                commitResizeWithGroupReflow(for: node.id)
                            }
                    )
                    .help("左右拖拽实时缩放并自动重排框内素材")
                }
            }

            ForEach(ResizeCorner.allCases, id: \.self) { corner in
                let isActiveCorner = isResizingThis && resizingSideEdge == 0 && resizingCorner == corner
                ZStack {
                    Circle()
                        .fill(isActiveCorner ? Color.accentColor : Color.white)
                        .frame(width: isActiveCorner ? 12 : 10, height: isActiveCorner ? 12 : 10)
                        .overlay(Circle().strokeBorder(Color.accentColor, lineWidth: 2))
                        .shadow(color: .black.opacity(0.22), radius: 3, y: 1)
                }
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
                .overlay(alignment: .bottom) {
                    if isActiveCorner, let live = liveResizeFrame {
                        Text("\(Int(live.width.rounded())) × \(Int(live.height.rounded()))")
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .monospacedDigit()
                            .foregroundStyle(.white)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Color.black.opacity(0.76), in: Capsule(style: .continuous))
                            .rotationEffect(.degrees(-currentRotation))
                            .offset(y: 26)
                            .allowsHitTesting(false)
                    }
                }
                .offset(
                    x: CGFloat(corner.signX) * width * 0.5,
                    y: CGFloat(corner.signY) * height * 0.5
                )
                .highPriorityGesture(
                    DragGesture(minimumDistance: 1, coordinateSpace: .named("charkle-freeform-stage"))
                        .onChanged { value in
                            if resizingNodeID == nil {
                                resizingNodeID = node.id
                                resizingSideEdge = 0
                                resizingCorner = corner
                                resizeStartFrame = node.frame
                                if case .groupFrame = node.kind {
                                    liveGroupReflowChildIDs = enclosedChildIDs(in: node)
                                } else {
                                    liveGroupReflowChildIDs = []
                                }
                            }
                            guard let start = resizeStartFrame else { return }
                            let stageDX = Double(value.translation.width / camera.zoom)
                            let stageDY = Double(value.translation.height / camera.zoom)

                            // Project world translation onto node's local rotated axes
                            let rad = node.rotationDegrees * .pi / 180.0
                            let cosR = cos(rad)
                            let sinR = sin(rad)
                            let localDX = stageDX * cosR + stageDY * sinR
                            let localDY = -stageDX * sinR + stageDY * cosR

                            let rawW = max(minSize.width, start.width + corner.signX * localDX)
                            let rawH = max(minSize.height, start.height + corner.signY * localDY)

                            let preserveAspect: Bool = switch node.kind {
                            case .assetRef: !NSEvent.modifierFlags.contains(.shift)
                            case .note, .groupFrame, .paletteStrip: NSEvent.modifierFlags.contains(.shift)
                            }

                            var newW = rawW
                            var newH = rawH
                            if preserveAspect {
                                let aspect = start.width / max(1, start.height)
                                let scaleW = rawW / max(1, start.width)
                                let scaleH = rawH / max(1, start.height)
                                let chosenScale = abs(scaleW - 1) >= abs(scaleH - 1) ? scaleW : scaleH
                                newW = max(minSize.width, start.width * chosenScale)
                                newH = max(minSize.height, newW / aspect)
                                if newH < minSize.height {
                                    newH = minSize.height
                                    newW = max(minSize.width, newH * aspect)
                                }
                            }

                            // Keep the opposite corner pinned in world space (works for both 0° and rotated nodes)
                            let deltaW = newW - start.width
                            let deltaH = newH - start.height
                            let localCenterShiftX = corner.signX * deltaW * 0.5
                            let localCenterShiftY = corner.signY * deltaH * 0.5
                            let worldCenterShiftX = localCenterShiftX * cosR - localCenterShiftY * sinR
                            let worldCenterShiftY = localCenterShiftX * sinR + localCenterShiftY * cosR

                            let newCenterX = start.midX + worldCenterShiftX
                            let newCenterY = start.midY + worldCenterShiftY
                            let updatedRect = BoardRect(
                                x: newCenterX - newW * 0.5,
                                y: newCenterY - newH * 0.5,
                                width: newW,
                                height: newH
                            )
                            liveResizeFrame = updatedRect
                            if case .groupFrame = node.kind {
                                updateLiveGroupReflow(for: updatedRect)
                            }
                        }
                        .onEnded { _ in
                            commitResizeWithGroupReflow(for: node.id)
                        }
                )
                .help(
                    node.referencedAssetID != nil
                        ? "拖拽调整尺寸（按住 ⇧ 自由拉伸）"
                        : "拖拽自由调整尺寸（按住 ⇧ 锁定比例）"
                )
            }
        }
    }

    private func connectorPortsOverlay(node: BoardNode, worldRect: BoardRect, width: CGFloat, height: CGFloat) -> some View {
        let anchors: [(ConnectorAnchor, CGSize, CGPoint)] = [
            (.top, CGSize(width: 0, height: -height * 0.5), CGPoint(x: worldRect.midX, y: worldRect.minY)),
            (.bottom, CGSize(width: 0, height: height * 0.5), CGPoint(x: worldRect.midX, y: worldRect.maxY)),
            (.leading, CGSize(width: -width * 0.5, height: 0), CGPoint(x: worldRect.minX, y: worldRect.midY)),
            (.trailing, CGSize(width: width * 0.5, height: 0), CGPoint(x: worldRect.maxX, y: worldRect.midY))
        ]
        return ZStack {
            ForEach(anchors, id: \.0) { anchor, offset, startWorld in
                ZStack {
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 9, height: 9)
                        .overlay(Circle().strokeBorder(Color.white, lineWidth: 1.5))
                }
                .frame(width: 18, height: 18)
                .contentShape(Circle())
                .offset(offset)
                .onHover { hovering in
                    hoverState.setPortHovered(node.id, hovering: hovering)
                }
                .highPriorityGesture(
                    DragGesture(minimumDistance: 2, coordinateSpace: .named("charkle-freeform-stage"))
                        .onChanged { value in
                            if pendingConnectorSource == nil {
                                pendingConnectorSource = (node.id, anchor, startWorld)
                            }
                            pendingConnectorCursorWorld = screenToWorld(value.location)
                        }
                        .onEnded { _ in
                            defer { pendingConnectorSource = nil }
                            guard let pending = pendingConnectorSource else { return }
                            let dropWorld = BoardPoint(pendingConnectorCursorWorld)
                            if let targetNode = document.nodes.first(where: { other in
                                other.id != pending.nodeID && other.frame.contains(dropWorld)
                            }) {
                                var nextDoc = document
                                let conn = BoardConnector(
                                    fromNodeID: pending.nodeID,
                                    fromAnchor: pending.anchor,
                                    toNodeID: targetNode.id,
                                    toAnchor: .auto,
                                    style: connectorStyle,
                                    dashed: connectorDashed
                                )
                                nextDoc.connectors.append(conn)
                                selectedConnectorID = conn.id
                                callbacks.onCommitDocument(nextDoc)
                            }
                        }
                )
            }
        }
    }

    private func eraseNear(worldPoint: CGPoint) {
        let hitRadius = 18.0 / Double(camera.zoom)
        var nextDoc = document
        let oldStrokes = nextDoc.inkStrokes.count
        nextDoc.inkStrokes.removeAll { stroke in
            stroke.points.contains { pt in
                hypot(pt.x - Double(worldPoint.x), pt.y - Double(worldPoint.y)) <= hitRadius
            }
        }
        let oldConnectors = nextDoc.connectors.count
        let frames = Dictionary(uniqueKeysWithValues: nextDoc.nodes.map { ($0.id, $0.frame.cgRect) })
        nextDoc.connectors.removeAll { conn in
            guard let f = frames[conn.fromNodeID], let t = frames[conn.toNodeID] else { return false }
            let (s, e, c1, c2) = ConnectorGeometry.resolvePathPoints(
                fromRect: f,
                fromAnchor: conn.fromAnchor,
                fromNormalizedPoint: conn.fromNormalizedPoint,
                toRect: t,
                toAnchor: conn.toAnchor,
                toNormalizedPoint: conn.toNormalizedPoint,
                style: conn.style
            )
            let mid = ConnectorGeometry.midpoint(start: s, end: e, c1: c1, c2: c2, style: conn.style)
            return hypot(Double(mid.x) - Double(worldPoint.x), Double(mid.y) - Double(worldPoint.y)) <= hitRadius * 1.4
        }
        if nextDoc.inkStrokes.count != oldStrokes || nextDoc.connectors.count != oldConnectors {
            callbacks.onCommitDocument(nextDoc)
        }
    }

    // MARK: - Shared Node Renderer

    @ViewBuilder
    private func renderNodeBody(node: BoardNode, isAutoMode: Bool) -> some View {
        let isSelected = selectedNodeIDs.contains(node.id)
        switch node.kind {
        case .assetRef(let assetID, _, _, _):
            BoardAssetNodeView(
                node: node,
                asset: assetsByID[assetID],
                loader: loader,
                isSelected: isSelected,
                isSwapTarget: swappingNodeID == node.id,
                isAutoEditorial: isAutoMode,
                heroNamespace: heroNamespace,
                onToggleHero: { toggleHeroWeight(nodeID: node.id) },
                onTriggerSwap: { callbacks.onSelectSwapTarget(swappingNodeID == node.id ? nil : node.id) },
                onOpenQuickLook: {
                    if let asset = assetsByID[assetID] {
                        callbacks.onOpenQuickLook(asset)
                    }
                },
                onRevealInLibrary: {
                    callbacks.onRevealInLibrary(assetID)
                },
                onRevealInFinder: {
                    callbacks.onRevealInFinder(assetID)
                },
                onCopy: {
                    callbacks.onCopyAssets(effectiveAssetIDs(including: node.id, fallbackAssetID: assetID))
                },
                onCut: {
                    cutBoardNodes(effectiveNodeIDs(including: node.id))
                },
                onPaste: {
                    callbacks.onPasteIntoBoard(defaultPasteLocation())
                },
                onRotateBy: { delta in rotateNodes([node.id], by: delta) },
                onResetRotation: { resetRotation(for: [node.id]) },
                onFlipHorizontal: { flipNodes([node.id], horizontal: true) },
                onFlipVertical: { flipNodes([node.id], horizontal: false) },
                onSmartFocusSubject: {
                    callbacks.onSmartFocusNode(node.id, assetID, nil)
                },
                onSemanticCropPrompt: {
                    semanticCropQuery = ""
                    semanticCropTarget = (nodeID: node.id, assetID: assetID)
                },
                onVisualMatchCrop: {
                    visualMatchTarget = (nodeID: node.id, assetID: assetID)
                },
                onCleanContentCrop: {
                    callbacks.onCleanCropNode(node.id, assetID)
                },
                onPinpointAnnotate: {
                    pinpointTargetQuery = ""
                    pinpointNoteDraft = ""
                    pinpointAnnotateTarget = (nodeID: node.id, assetID: assetID)
                },
                onResetCrop: {
                    resetNodeCrop(nodeID: node.id)
                },
                onToggleLock: { toggleLock(nodeID: node.id) },
                onDelete: { removeNode(id: node.id) }
            )
        case .note(let title, let text, let style, let fontSize):
            BoardNoteNodeView(
                node: node,
                title: title,
                text: text,
                style: style,
                fontSize: fontSize,
                isSelected: isSelected,
                onUpdate: { newTitle, newText, newStyle, newFontSize in
                    updateNote(nodeID: node.id, title: newTitle, text: newText, style: newStyle, fontSize: newFontSize)
                },
                onDelete: { removeNode(id: node.id) }
            )
        case .groupFrame(let title, let tint):
            let enclosedCount = enclosedChildIDs(in: node).count
            BoardGroupFrameView(
                title: title,
                tint: tint,
                itemCount: enclosedCount,
                isSelected: isSelected,
                onUpdate: { newTitle, newTint in
                    updateGroupFrame(nodeID: node.id, title: newTitle, tint: newTint)
                },
                onReflowInside: {
                    reflowGroupFrameNow(nodeID: node.id)
                },
                onDelete: { removeNode(id: node.id) }
            )
        case .paletteStrip(let colors, let autoSync):
            BoardPaletteStripNodeView(
                colors: autoSync && !document.extractedPalette.isEmpty ? document.extractedPalette : colors,
                autoSync: autoSync,
                isSelected: isSelected,
                onCopyHex: callbacks.onCopyColorHex,
                onSearchColor: callbacks.onSearchByColorHex,
                onToggleAutoSync: { togglePaletteAutoSync(nodeID: node.id) },
                onDelete: { removeNode(id: node.id) }
            )
        }
    }

    // MARK: - Floating Liquid Glass Bottom Tool Dock (Single GlassEffectContainer)

    private var floatingToolDock: some View {
        CanvasGlassContainer(spacing: 10) {
            HStack(spacing: 8) {
                // Freeform Tool Buttons
                ForEach(MoodboardTool.allCases, id: \.self) { tool in
                    let active = activeTool == tool
                    Button {
                        withAnimation(CanvasMotion.accessible(CanvasMotion.settleStrong, reduced: reduceMotion)) {
                            activeTool = tool
                        }
                    } label: {
                        Image(systemName: toolIcon(tool))
                            .font(.system(size: 13, weight: active ? .semibold : .regular))
                            .foregroundStyle(active ? Color.accentColor : .primary.opacity(0.84))
                            .frame(width: 30, height: 30)
                            .background(
                                active ? Color.accentColor.opacity(0.14) : Color.clear,
                                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                            )
                    }
                    .buttonStyle(.plain)
                    .help("\(tool.label) (\(tool.shortcutHint))")
                }

                // Contextual Ink Pen swatch & width controls
                if activeTool == .pen {
                    dockDivider
                    HStack(spacing: 4) {
                        ForEach(Self.calmInkSwatches, id: \.hex) { swatch in
                            Button {
                                inkColorHex = swatch.hex
                            } label: {
                                Circle()
                                    .fill(Color(charkleHex: swatch.hex))
                                    .frame(width: 14, height: 14)
                                    .overlay(
                                        Circle().strokeBorder(
                                            inkColorHex == swatch.hex ? Color.accentColor : Color.white.opacity(0.45),
                                            lineWidth: inkColorHex == swatch.hex ? 2 : 0.75
                                        )
                                    )
                            }
                            .buttonStyle(.plain)
                            .help(swatch.name)
                        }
                        Picker("", selection: $inkWidth) {
                            Text("细").tag(2.0)
                            Text("中").tag(3.5)
                            Text("粗").tag(6.5)
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 84)
                    }
                }

                // Contextual Connector style toggle
                if activeTool == .connector {
                    dockDivider
                    Picker("", selection: $connectorStyle) {
                        Text("曲线").tag(ConnectorStyle.curved)
                        Text("折线").tag(ConnectorStyle.elbow)
                        Text("直线").tag(ConnectorStyle.straight)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 120)
                }

                dockDivider

                // Insert Nodes (Note / Group Frame / Palette Strip)
                dockIconButton(systemName: "note.text.badge.plus", help: "添加便签卡片") {
                    addNoteNode()
                }
                dockIconButton(systemName: "rectangle.dashed", help: "添加区域分组框") {
                    addGroupFrameNode()
                }
                dockIconButton(systemName: "paintpalette", help: "添加全板色卡条") {
                    addPaletteStripNode()
                }

                dockIconButton(systemName: "sparkles.rectangle.stack", help: "重新整齐排版") {
                    tidyFreeformNodes()
                }

                dockDivider

                // Undo / Redo
                dockIconButton(systemName: "arrow.uturn.backward", help: "撤销 (⌘Z)", disabled: !canUndo) {
                    callbacks.onUndo()
                }
                dockIconButton(systemName: "arrow.uturn.forward", help: "重做 (⇧⌘Z)", disabled: !canRedo) {
                    callbacks.onRedo()
                }

                dockDivider

                // Export / Figma Bridge
                Menu {
                    Button {
                        callbacks.onExportFigmaBundle(currentExportOptions)
                    } label: {
                        Label("导出到 Figma / FigJam（可编辑独立图层）…", systemImage: "square.stack.3d.up")
                    }
                    Button {
                        callbacks.onOpenFigmaPluginGuide()
                    } label: {
                        Label("安装 / 获取 Figma Bridge 插件…", systemImage: "puzzlepiece.extension")
                    }
                    Divider()
                    Button("复制 2× 高清图（直接 ⌘V 到 Figma / Keynote）") {
                        callbacks.onCopyExportedImage(currentExportOptions)
                    }
                    Button("导出 2× Retina PNG…") {
                        callbacks.onSaveExportedImage(.png, currentExportOptions)
                    }
                    Button("导出 2× Retina JPG…") {
                        callbacks.onSaveExportedImage(.jpeg, currentExportOptions)
                    }
                    Divider()
                    Toggle("包含连线与手绘批注", isOn: $exportIncludeAnnotations)
                    Toggle("包含顶部板内色卡", isOn: $exportIncludePalette)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 12.5, weight: .semibold))
                        Text("导出")
                            .font(.system(size: 11.5, weight: .semibold))
                    }
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            .padding(8)
            .canvasLiquidGlass(in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
    }

    private func dockIconButton(
        systemName: String,
        help: String,
        disabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(disabled ? Color.secondary.opacity(0.4) : Color.primary.opacity(0.84))
                .frame(width: 28, height: 28)
                .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .help(help)
    }

    private var dockDivider: some View {
        Rectangle()
            .fill(CanvasSurface.hairline(for: colorScheme))
            .frame(width: 1, height: 18)
    }

    private var emptyBoardPlaceholder: some View {
        VStack(spacing: 12) {
            Image(systemName: "rectangle.3.group.bubble")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(.secondary.opacity(0.6))
            Text("把素材拖进来，或从右侧候选池点击加入")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary)
            Text("支持直接从 Finder / 浏览器拖入新图（自动保存在 /Charkle/Inbox/ 并引用上板）")
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
        }
        .multilineTextAlignment(.center)
        .padding(32)
    }

    private var connectorLabelEditorPopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("连线标签与样式")
                .font(.system(size: 12, weight: .semibold))
            TextField("输入说明文字（如：色彩呼应、材质参考）", text: $connectorLabelDraft)
                .textFieldStyle(.roundedBorder)
                .frame(width: 220)
            HStack {
                Button("删除连线", role: .destructive) {
                    if let id = editingConnectorLabelID {
                        var nextDoc = document
                        nextDoc.connectors.removeAll { $0.id == id }
                        callbacks.onCommitDocument(nextDoc)
                    }
                    editingConnectorLabelID = nil
                }
                Spacer()
                Button("保存") {
                    if let id = editingConnectorLabelID,
                       let idx = document.connectors.firstIndex(where: { $0.id == id }) {
                        var nextDoc = document
                        let trimmed = connectorLabelDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                        nextDoc.connectors[idx].label = trimmed.isEmpty ? nil : trimmed
                        nextDoc.connectors[idx].updatedAt = Date()
                        callbacks.onCommitDocument(nextDoc)
                    }
                    editingConnectorLabelID = nil
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(14)
    }

    // MARK: - Camera & Coordinate Helpers

    private func screenToWorld(_ pt: CGPoint) -> CGPoint {
        camera.screenToWorld(pt, viewportSize: viewportSize)
    }

    private func effectiveFrame(for node: BoardNode) -> BoardRect {
        if resizingNodeID == node.id, let live = liveResizeFrame {
            return live
        }
        if let reflowed = liveGroupReflowFrames[node.id] {
            return reflowed
        }
        if activeNodeDragID != nil {
            let movingSet = selectedNodeIDs.union(activeGroupChildIDs).union(activeNodeDragID.map { [$0] } ?? [])
            if movingSet.contains(node.id) && !node.isLocked {
                return BoardRect(
                    x: node.frame.x + Double(activeNodeDragDelta.width),
                    y: node.frame.y + Double(activeNodeDragDelta.height),
                    width: node.frame.width,
                    height: node.frame.height
                )
            }
        }
        return node.frame
    }

    private func enclosedChildIDs(in groupNode: BoardNode) -> [UUID] {
        document.nodes.filter { other in
            guard other.id != groupNode.id, !other.isLocked else { return false }
            if case .groupFrame = other.kind { return false }
            let center = BoardPoint(x: other.frame.midX, y: other.frame.midY)
            return groupNode.frame.contains(center)
        }.map(\.id)
    }

    private func updateLiveGroupReflow(for groupRect: BoardRect) {
        guard !liveGroupReflowChildIDs.isEmpty else {
            liveGroupReflowFrames = [:]
            return
        }
        let idSet = Set(liveGroupReflowChildIDs)
        let children = document.nodes.filter { idSet.contains($0.id) }
        liveGroupReflowFrames = EditorialLayoutSolver.reflowNodesInsideGroupFrame(
            groupRect: groupRect,
            childNodes: children,
            assetsByID: assetsByID
        )
    }

    private func commitResizeWithGroupReflow(for nodeID: UUID) {
        let finalRect = liveResizeFrame
        let finalChildren = liveGroupReflowFrames
        resizingNodeID = nil
        resizingCorner = nil
        resizingSideEdge = 0
        resizeStartFrame = nil
        liveResizeFrame = nil
        liveGroupReflowChildIDs = []
        liveGroupReflowFrames = [:]

        guard let finalRect else { return }
        var nextDoc = document
        if let idx = nextDoc.nodes.firstIndex(where: { $0.id == nodeID }) {
            nextDoc.nodes[idx].frame = finalRect
            nextDoc.nodes[idx].updatedAt = Date()
        }
        for (childID, childRect) in finalChildren {
            if let cIdx = nextDoc.nodes.firstIndex(where: { $0.id == childID }) {
                nextDoc.nodes[cIdx].frame = childRect
                nextDoc.nodes[cIdx].updatedAt = Date()
            }
        }
        callbacks.onCommitDocument(nextDoc)
    }

    private func reflowGroupFrameNow(nodeID: UUID) {
        guard let group = document.nodes.first(where: { $0.id == nodeID }) else { return }
        let ids = Set(enclosedChildIDs(in: group))
        let children = document.nodes.filter { ids.contains($0.id) }
        guard !children.isEmpty else { return }
        let reflowed = EditorialLayoutSolver.reflowNodesInsideGroupFrame(
            groupRect: group.frame,
            childNodes: children,
            assetsByID: assetsByID
        )
        var nextDoc = document
        for (cid, rect) in reflowed {
            if let idx = nextDoc.nodes.firstIndex(where: { $0.id == cid }) {
                nextDoc.nodes[idx].frame = rect
                nextDoc.nodes[idx].updatedAt = Date()
            }
        }
        withAnimation(CanvasMotion.accessible(CanvasMotion.gestureSpring, reduced: reduceMotion)) {
            callbacks.onCommitDocument(nextDoc)
        }
    }

    private func applyZoom(factor: CGFloat, anchorScreenPoint: CGPoint) {
        camera.applyZoom(factor: factor, anchorScreenPoint: anchorScreenPoint, viewportSize: viewportSize)
    }

    private func fitBoardToScreen() {
        guard !document.nodes.isEmpty else {
            camera.set(
                center: CGPoint(x: viewportSize.width * 0.5, y: viewportSize.height * 0.5),
                zoom: 1.0
            )
            return
        }
        let minX = document.nodes.map(\.frame.minX).min() ?? 0
        let minY = document.nodes.map(\.frame.minY).min() ?? 0
        let maxX = document.nodes.map(\.frame.maxX).max() ?? 800
        let maxY = document.nodes.map(\.frame.maxY).max() ?? 600
        let w = max(200, maxX - minX)
        let h = max(200, maxY - minY)
        let fitZoom = min(
            (viewportSize.width - 120) / CGFloat(w),
            (viewportSize.height - 160) / CGFloat(h)
        )
        withAnimation(CanvasMotion.accessible(CanvasMotion.uiSpring, reduced: reduceMotion)) {
            camera.set(
                center: CGPoint(x: (minX + maxX) * 0.5, y: (minY + maxY) * 0.5),
                zoom: max(0.22, min(1.8, fitZoom))
            )
        }
        persistCameraViewport()
    }

    private func syncCameraFromDocument() {
        let initialZoom = max(0.2, min(3.0, CGFloat(document.viewportZoom > 0 ? document.viewportZoom : 1.0)))
        let initialCenter: CGPoint
        if document.viewportCenter == .zero && !document.nodes.isEmpty {
            let minX = document.nodes.map(\.frame.minX).min() ?? 0
            let maxX = document.nodes.map(\.frame.maxX).max() ?? 1000
            let minY = document.nodes.map(\.frame.minY).min() ?? 0
            let maxY = document.nodes.map(\.frame.maxY).max() ?? 600
            initialCenter = CGPoint(x: (minX + maxX) * 0.5, y: min((minY + maxY) * 0.5, 420))
        } else {
            initialCenter = document.viewportCenter.cgPoint
        }
        camera.set(center: initialCenter, zoom: initialZoom)
    }

    private func persistCameraViewport() {
        callbacks.onPersistViewport(BoardPoint(camera.center), Double(camera.zoom))
    }

    // MARK: - Document Mutations

    /// Silently upgrades any legacy `.autoEditorial` board into `.freeform` on open so all boards
    /// live natively on the unified freeform canvas without losing existing placement.
    private func ensureFreeformModeIfLegacy() {
        guard document.mode.isAutoEditorial else { return }
        let frozen = EditorialLayoutSolver.freezeIntoFreeform(
            document: document,
            containerWidth: Double(max(640, viewportSize.width)),
            assetsByID: assetsByID
        )
        camera.set(center: frozen.viewportCenter.cgPoint, zoom: CGFloat(frozen.viewportZoom))
        callbacks.onCommitDocument(frozen)
    }

    private func tidyFreeformNodes() {
        let tidied = EditorialLayoutSolver.tidyNodesInFreeform(
            document: document,
            selectedNodeIDs: selectedNodeIDs,
            assetsByID: assetsByID
        )
        withAnimation(CanvasMotion.accessible(CanvasMotion.gestureSpring, reduced: reduceMotion)) {
            callbacks.onCommitDocument(tidied)
        }
    }

    private func toggleHeroWeight(nodeID: UUID) {
        var nextDoc = document
        guard let idx = nextDoc.nodes.firstIndex(where: { $0.id == nodeID }),
              case .assetRef(let assetID, let crop, let weight, let autoplay) = nextDoc.nodes[idx].kind else { return }
        nextDoc.nodes[idx].kind = .assetRef(assetID: assetID, crop: crop, weight: weight >= 2 ? 1 : 2, autoplayLoop: autoplay)
        nextDoc.nodes[idx].updatedAt = Date()
        withAnimation(CanvasMotion.accessible(CanvasMotion.moveOnScreen, reduced: reduceMotion)) {
            callbacks.onCommitDocument(nextDoc)
        }
    }

    private func resetNodeCrop(nodeID: UUID) {
        var nextDoc = document
        guard let idx = nextDoc.nodes.firstIndex(where: { $0.id == nodeID }),
              case .assetRef(let assetID, _, let weight, let autoplay) = nextDoc.nodes[idx].kind else { return }
        nextDoc.nodes[idx].kind = .assetRef(assetID: assetID, crop: nil, weight: weight, autoplayLoop: autoplay)
        nextDoc.nodes[idx].updatedAt = Date()
        withAnimation(CanvasMotion.accessible(CanvasMotion.moveOnScreen, reduced: reduceMotion)) {
            callbacks.onCommitDocument(nextDoc)
        }
    }

    private var semanticCropSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "text.viewfinder")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("一句话语义裁切 (Jev Box)")
                        .font(.system(size: 14, weight: .semibold))
                    Text("输入想聚焦的局部元素，非破坏性裁切到目标区域，随时可还原。")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
            }

            TextField("例如：黄铜台灯、右上角玻璃按钮、海报主标题、模特鞋履…", text: $semanticCropQuery)
                .textFieldStyle(.roundedBorder)
                .onSubmit {
                    submitSemanticCrop()
                }

            HStack {
                Button("取消") {
                    semanticCropTarget = nil
                }
                .keyboardShortcut(.cancelAction)
                Spacer()
                Button("定位并裁切") {
                    submitSemanticCrop()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(semanticCropQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 400)
    }

    private func submitSemanticCrop() {
        let query = semanticCropQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, let target = semanticCropTarget else { return }
        semanticCropTarget = nil
        callbacks.onSmartFocusNode(target.nodeID, target.assetID, query)
    }

    private var visualMatchPickerSheet: some View {
        let targetAssetID = visualMatchTarget?.assetID
        let boardOtherIDs = document.referencedAssetIDs.filter { $0 != targetAssetID }
        var seen = Set<UUID>()
        var candidates: [AssetRecord] = []
        for id in boardOtherIDs where seen.insert(id).inserted {
            if let asset = assetsByID[id], asset.mediaKind == .image || asset.mediaKind == .webBookmark {
                candidates.append(asset)
            }
        }
        for asset in assetsByID.values.sorted(by: { $0.updatedAt > $1.updatedAt }) where candidates.count < 24 {
            guard asset.id != targetAssetID,
                  asset.mediaKind == .image || asset.mediaKind == .webBookmark,
                  seen.insert(asset.id).inserted else { continue }
            candidates.append(asset)
        }

        return VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "photo.on.rectangle.angled")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("以图找局部 (Jev Visual-Target Box)")
                        .font(.system(size: 14, weight: .semibold))
                    Text("选择一张参考图，Jev Box 会在当前图片中找出与该参考图最匹配的局部并自动裁切。")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
            }

            if candidates.isEmpty {
                Text("当前没有其他可选参考图片，请先导入更多图片素材。")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 24)
            } else {
                ScrollView(.vertical) {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 84, maximum: 100), spacing: 10)], spacing: 10) {
                        ForEach(candidates) { refAsset in
                            Button {
                                guard let target = visualMatchTarget else { return }
                                visualMatchTarget = nil
                                callbacks.onVisualMatchCropNode(target.nodeID, target.assetID, refAsset.id)
                            } label: {
                                VStack(spacing: 4) {
                                    AssetThumbnailSurface(
                                        asset: refAsset,
                                        loader: loader,
                                        tier: .grid520,
                                        cornerRadius: 8
                                    )
                                    .frame(height: 76)
                                    Text(refAsset.title)
                                        .font(.system(size: 10))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .frame(maxHeight: 280)
            }

            HStack {
                Spacer()
                Button("取消") {
                    visualMatchTarget = nil
                }
                .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 480)
    }

    private var pinpointAnnotateSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "scope")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("指物批注 (Jev Box)")
                        .font(.system(size: 14, weight: .semibold))
                    Text("定位画面中的目标元素，并在旁侧自动生成便签与精准指向箭头。")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 5) {
                Text("要指向的图内元素")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.secondary)
                TextField("例如：主标题衬线字、玻璃高光边缘、左下角徽章…", text: $pinpointTargetQuery)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 5) {
                Text("批注内容（留空则自动以元素名为标题）")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.secondary)
                TextField("例如：这里的材质反光层次和留白比例值得借鉴", text: $pinpointNoteDraft)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        submitPinpointAnnotate()
                    }
            }

            HStack {
                Button("取消") {
                    pinpointAnnotateTarget = nil
                }
                .keyboardShortcut(.cancelAction)
                Spacer()
                Button("定位并添加批注") {
                    submitPinpointAnnotate()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(pinpointTargetQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private func submitPinpointAnnotate() {
        let query = pinpointTargetQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, let target = pinpointAnnotateTarget else { return }
        let note = pinpointNoteDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        pinpointAnnotateTarget = nil
        callbacks.onPinpointAnnotateNode(target.nodeID, target.assetID, query, note)
    }

    private func toggleLock(nodeID: UUID) {
        var nextDoc = document
        guard let idx = nextDoc.nodes.firstIndex(where: { $0.id == nodeID }) else { return }
        nextDoc.nodes[idx].isLocked.toggle()
        callbacks.onCommitDocument(nextDoc)
    }

    private func addNoteNode() {
        var nextDoc = document
        let spawn = camera.center
        let node = BoardNode(
            kind: .note(title: "灵感便签", text: "记录构图、材质、光影或排版思路…", style: .warm, fontSize: 14),
            frame: BoardRect(x: Double(spawn.x - 130), y: Double(spawn.y - 90), width: 260, height: 180),
            zIndex: (nextDoc.nodes.map(\.zIndex).max() ?? 0) + 1,
            editorialOrder: nextDoc.nodes.count
        )
        nextDoc.nodes.append(node)
        selectedNodeIDs = [node.id]
        callbacks.onCommitDocument(nextDoc)
    }

    private func addGroupFrameNode() {
        var nextDoc = document
        let spawn = camera.center
        let node = BoardNode(
            kind: .groupFrame(title: "构图参考区", tint: .sand),
            frame: BoardRect(x: Double(spawn.x - 220), y: Double(spawn.y - 160), width: 440, height: 320),
            zIndex: -10,
            editorialOrder: nextDoc.nodes.count
        )
        nextDoc.nodes.append(node)
        selectedNodeIDs = [node.id]
        callbacks.onCommitDocument(nextDoc)
    }

    private func addPaletteStripNode() {
        var nextDoc = document
        let spawn = camera.center
        let colors = nextDoc.extractedPalette.isEmpty
            ? [LabColor.fromHex("#C8B8A6"), LabColor.fromHex("#5C6B73"), LabColor.fromHex("#253237"), LabColor.fromHex("#E0D6CC")]
            : nextDoc.extractedPalette
        let node = BoardNode(
            kind: .paletteStrip(colors: colors, autoSyncWithBoard: true),
            frame: BoardRect(x: Double(spawn.x - 210), y: Double(spawn.y - 42), width: 420, height: 84),
            zIndex: (nextDoc.nodes.map(\.zIndex).max() ?? 0) + 1,
            editorialOrder: nextDoc.nodes.count
        )
        nextDoc.nodes.append(node)
        selectedNodeIDs = [node.id]
        callbacks.onCommitDocument(nextDoc)
    }

    private func updateNote(nodeID: UUID, title: String?, text: String, style: NoteStyle, fontSize: Double) {
        var nextDoc = document
        guard let idx = nextDoc.nodes.firstIndex(where: { $0.id == nodeID }) else { return }
        nextDoc.nodes[idx].kind = .note(title: title, text: text, style: style, fontSize: fontSize)
        nextDoc.nodes[idx].updatedAt = Date()
        callbacks.onCommitDocument(nextDoc)
    }

    private func updateGroupFrame(nodeID: UUID, title: String, tint: GroupTint) {
        var nextDoc = document
        guard let idx = nextDoc.nodes.firstIndex(where: { $0.id == nodeID }) else { return }
        nextDoc.nodes[idx].kind = .groupFrame(title: title, tint: tint)
        nextDoc.nodes[idx].updatedAt = Date()
        callbacks.onCommitDocument(nextDoc)
    }

    private func togglePaletteAutoSync(nodeID: UUID) {
        var nextDoc = document
        guard let idx = nextDoc.nodes.firstIndex(where: { $0.id == nodeID }),
              case .paletteStrip(let colors, let autoSync) = nextDoc.nodes[idx].kind else { return }
        nextDoc.nodes[idx].kind = .paletteStrip(colors: colors, autoSyncWithBoard: !autoSync)
        callbacks.onCommitDocument(nextDoc)
    }

    private func removeNode(id: UUID) {
        var nextDoc = document
        nextDoc.nodes.removeAll { $0.id == id }
        nextDoc.connectors.removeAll { $0.fromNodeID == id || $0.toNodeID == id }
        selectedNodeIDs.remove(id)
        if swappingNodeID == id {
            callbacks.onSelectSwapTarget(nil)
        }
        callbacks.onCommitDocument(nextDoc)
    }

    private func deleteCurrentSelection() {
        var nextDoc = document
        var changed = false
        if !selectedNodeIDs.isEmpty {
            let ids = selectedNodeIDs
            nextDoc.nodes.removeAll { ids.contains($0.id) }
            nextDoc.connectors.removeAll { ids.contains($0.fromNodeID) || ids.contains($0.toNodeID) }
            selectedNodeIDs.removeAll()
            changed = true
        }
        if let connID = selectedConnectorID {
            nextDoc.connectors.removeAll { $0.id == connID }
            selectedConnectorID = nil
            changed = true
        }
        if changed {
            callbacks.onCommitDocument(nextDoc)
        }
    }

    private var currentExportOptions: MoodboardExportOptions {
        MoodboardExportOptions(
            scale: 2.0,
            includeAnnotations: exportIncludeAnnotations,
            includePaletteStrip: exportIncludePalette,
            darkAppearance: colorScheme == .dark
        )
    }

    private func toolIcon(_ tool: MoodboardTool) -> String {
        switch tool {
        case .select: "cursorarrow"
        case .pan: "hand.raised"
        case .connector: "arrow.up.right"
        case .pen: "pencil.tip"
        case .eraser: "eraser"
        }
    }

    // MARK: - Live Drop-In (External Files/URLs OR Internal Charkle Assets)

    private func handleCanvasDrop(providers: [NSItemProvider], screenLocation: CGPoint) -> Bool {
        guard !providers.isEmpty else { return false }
        let dropPoint: BoardPoint? = BoardPoint(screenToWorld(screenLocation))

        Task {
            var internalIDs: [UUID] = []
            var externalInputs: [CaptureInput] = []

            for provider in providers {
                if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier),
                   let str = await loadPlainString(provider: provider) {
                    if let decoded = CharkleDragIdentifiers.decodeAssetIDs(from: str) {
                        internalIDs.append(contentsOf: decoded)
                        continue
                    }
                }
                // Never treat secondary `.fileURL` items from an internal multi-asset drag as external file drops.
                guard internalIDs.isEmpty else { continue }
                if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier),
                   let url = await loadURL(provider: provider, type: UTType.fileURL) {
                    externalInputs.append(.fileURL(url))
                    continue
                }
                if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier),
                   let url = await loadURL(provider: provider, type: UTType.url) {
                    if url.isFileURL {
                        externalInputs.append(.fileURL(url))
                    } else if url.scheme == "http" || url.scheme == "https" {
                        externalInputs.append(.webURL(url, title: nil, notes: nil))
                    }
                    continue
                }
                if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier),
                   let data = await loadData(provider: provider, type: UTType.image) {
                    externalInputs.append(.imageData(data, suggestedName: "BoardDrop-\(Int(Date().timeIntervalSince1970)).png", sourceURL: nil))
                    continue
                }
            }

            if !internalIDs.isEmpty {
                callbacks.onDropLibraryAssetIDs(internalIDs, dropPoint)
            } else if !externalInputs.isEmpty {
                callbacks.onDropExternalInputs(externalInputs, dropPoint)
            }
        }
        return true
    }

    private func loadPlainString(provider: NSItemProvider) async -> String? {
        await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.plainText.identifier, options: nil) { item, _ in
                if let str = item as? String { continuation.resume(returning: str) }
                else if let data = item as? Data, let str = String(data: data, encoding: .utf8) { continuation.resume(returning: str) }
                else { continuation.resume(returning: nil) }
            }
        }
    }

    private func loadURL(provider: NSItemProvider, type: UTType) async -> URL? {
        await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: type.identifier, options: nil) { item, _ in
                if let url = item as? URL { continuation.resume(returning: url) }
                else if let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) { continuation.resume(returning: url) }
                else if let str = item as? String, let url = URL(string: str) { continuation.resume(returning: url) }
                else { continuation.resume(returning: nil) }
            }
        }
    }

    private func loadData(provider: NSItemProvider, type: UTType) async -> Data? {
        await withCheckedContinuation { continuation in
            provider.loadDataRepresentation(forTypeIdentifier: type.identifier) { data, _ in
                continuation.resume(returning: data)
            }
        }
    }
}

// MARK: - AppKit Trackpad Scroll, Option/Cmd Zoom, Middle-Mouse Drag Pan & Hold-Space Drag Pan Bridge

private struct FreeformInputBridge: NSViewRepresentable {
    let isSuspended: Bool
    let onPanDelta: (CGFloat, CGFloat) -> Void
    let onPanEnded: () -> Void
    let onZoomDelta: (CGFloat, CGPoint) -> Void
    let onSpacePanStateChanged: (Bool) -> Void
    let onSpaceQuickTap: () -> Void

    func makeNSView(context: Context) -> CanvasInputCatcherView {
        let view = CanvasInputCatcherView()
        view.isSuspended = isSuspended
        view.onPanDelta = onPanDelta
        view.onPanEnded = onPanEnded
        view.onZoomDelta = onZoomDelta
        view.onSpacePanStateChanged = onSpacePanStateChanged
        view.onSpaceQuickTap = onSpaceQuickTap
        return view
    }

    func updateNSView(_ nsView: CanvasInputCatcherView, context: Context) {
        nsView.isSuspended = isSuspended
        nsView.onPanDelta = onPanDelta
        nsView.onPanEnded = onPanEnded
        nsView.onZoomDelta = onZoomDelta
        nsView.onSpacePanStateChanged = onSpacePanStateChanged
        nsView.onSpaceQuickTap = onSpaceQuickTap
    }
}

private final class CanvasInputCatcherView: NSView {
    var isSuspended: Bool = false {
        didSet {
            if isSuspended && !oldValue {
                resetActivePanState()
            }
        }
    }
    var onPanDelta: ((CGFloat, CGFloat) -> Void)?
    var onPanEnded: (() -> Void)?
    var onZoomDelta: ((CGFloat, CGPoint) -> Void)?
    var onSpacePanStateChanged: ((Bool) -> Void)?
    var onSpaceQuickTap: (() -> Void)?

    private var eventMonitor: Any?
    private var resignObserver: NSObjectProtocol?

    private var isMiddleDragging = false
    private var isSpaceHeld = false
    private var isSpaceLeftDragging = false
    private var didDragDuringSpace = false
    private var lastWindowPoint: NSPoint = .zero

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        teardownMonitors()
        guard let hostWindow = window else { return }

        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: hostWindow,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.resetActivePanState()
            }
        }

        let mask: NSEvent.EventTypeMask = [
            .scrollWheel,
            .otherMouseDown,
            .otherMouseDragged,
            .otherMouseUp,
            .keyDown,
            .keyUp,
            .leftMouseDown,
            .leftMouseDragged,
            .leftMouseUp
        ]

        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            guard let self, let win = self.window, event.window === win else { return event }
            return self.handleLocalEvent(event, in: win)
        }
    }

    private func isEditingText(in window: NSWindow) -> Bool {
        if let responder = window.firstResponder,
           responder is NSTextView || responder is NSTextField || responder is NSText {
            return true
        }
        return false
    }

    private func isPointInsideCanvas(_ windowPoint: NSPoint) -> Bool {
        let local = convert(windowPoint, from: nil)
        return bounds.contains(local)
    }

    private func handleLocalEvent(_ event: NSEvent, in window: NSWindow) -> NSEvent? {
        guard !isSuspended else { return event }
        switch event.type {
        case .scrollWheel:
            let locInView = convert(event.locationInWindow, from: nil)
            guard bounds.contains(locInView) else { return event }
            let swiftUIPoint = CGPoint(x: locInView.x, y: bounds.height - locInView.y)
            if event.modifierFlags.contains(.option) || event.modifierFlags.contains(.command) {
                let factor = max(0.85, min(1.18, 1.0 + event.scrollingDeltaY * 0.008))
                onZoomDelta?(factor, swiftUIPoint)
            } else {
                let scale: CGFloat = event.hasPreciseScrollingDeltas ? 1.0 : 12.0
                onPanDelta?(event.scrollingDeltaX * scale, event.scrollingDeltaY * scale)
            }
            if event.momentumPhase == .ended || (event.phase == .ended && event.momentumPhase.isEmpty) {
                onPanEnded?()
            }
            return nil

        case .otherMouseDown:
            // Middle mouse button (buttonNumber == 2) pans from anywhere over the canvas
            guard event.buttonNumber == 2, isPointInsideCanvas(event.locationInWindow) else { return event }
            isMiddleDragging = true
            lastWindowPoint = event.locationInWindow
            NSCursor.closedHand.set()
            return nil

        case .otherMouseDragged:
            guard isMiddleDragging else { return event }
            let cur = event.locationInWindow
            let dx = cur.x - lastWindowPoint.x
            let dy = -(cur.y - lastWindowPoint.y)
            lastWindowPoint = cur
            onPanDelta?(dx, dy)
            return nil

        case .otherMouseUp:
            guard isMiddleDragging else { return event }
            isMiddleDragging = false
            (isSpaceHeld ? NSCursor.openHand : NSCursor.arrow).set()
            onPanEnded?()
            return nil

        case .keyDown:
            guard event.keyCode == 49 else { return event } // Spacebar
            guard window.attachedSheet == nil && NSApp.modalWindow == nil else { return event }
            guard event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty else { return event }
            guard !isEditingText(in: window) else { return event }
            if !isSpaceHeld {
                isSpaceHeld = true
                didDragDuringSpace = false
                onSpacePanStateChanged?(true)
                NSCursor.openHand.set()
            }
            return nil

        case .keyUp:
            guard event.keyCode == 49, isSpaceHeld else { return event }
            let shouldQuickTap = !didDragDuringSpace
            let wasDragging = isSpaceLeftDragging
            isSpaceHeld = false
            isSpaceLeftDragging = false
            didDragDuringSpace = false
            onSpacePanStateChanged?(false)
            NSCursor.arrow.set()
            if wasDragging {
                onPanEnded?()
            } else if shouldQuickTap {
                onSpaceQuickTap?()
            }
            return nil

        case .leftMouseDown:
            guard isSpaceHeld, isPointInsideCanvas(event.locationInWindow) else { return event }
            isSpaceLeftDragging = true
            didDragDuringSpace = true
            lastWindowPoint = event.locationInWindow
            NSCursor.closedHand.set()
            return nil

        case .leftMouseDragged:
            guard isSpaceLeftDragging else { return event }
            let cur = event.locationInWindow
            let dx = cur.x - lastWindowPoint.x
            let dy = -(cur.y - lastWindowPoint.y)
            lastWindowPoint = cur
            onPanDelta?(dx, dy)
            return nil

        case .leftMouseUp:
            guard isSpaceLeftDragging else { return event }
            isSpaceLeftDragging = false
            (isSpaceHeld ? NSCursor.openHand : NSCursor.arrow).set()
            onPanEnded?()
            return nil

        default:
            return event
        }
    }

    private func resetActivePanState() {
        let hadPan = isMiddleDragging || isSpaceLeftDragging
        isMiddleDragging = false
        isSpaceLeftDragging = false
        if isSpaceHeld {
            isSpaceHeld = false
            didDragDuringSpace = false
            onSpacePanStateChanged?(false)
        }
        NSCursor.arrow.set()
        if hadPan {
            onPanEnded?()
        }
    }

    private func teardownMonitors() {
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
            self.eventMonitor = nil
        }
        if let resignObserver {
            NotificationCenter.default.removeObserver(resignObserver)
            self.resignObserver = nil
        }
        resetActivePanState()
    }

    isolated deinit {
        teardownMonitors()
    }
}

// MARK: - Isolated 120fps Freeform Camera, Hover State & GPU-Accelerated Leaf Views

/// Decoupled `@Observable` camera state so high-frequency trackpad scroll/zoom ticks ONLY update
/// the GPU dot-grid offset and single container transform, leaving toolbars and node views untouched.
@Observable
private final class FreeformCameraState {
    var center: CGPoint = CGPoint(x: 540, y: 360)
    var zoom: CGFloat = 1.0

    // Quantized culling buckets — only update when crossing 240pt world boundaries or 0.15 zoom steps
    var cullBucketX: Int = 2
    var cullBucketY: Int = 1
    var cullZoomBucket: Int = 6

    private static let bucketWorldStep: CGFloat = 240
    private static let bucketZoomStep: CGFloat = 0.15

    func set(center: CGPoint, zoom: CGFloat) {
        self.center = center
        self.zoom = max(0.2, min(3.0, zoom))
        refreshCullBucketsIfNeeded()
    }

    func setCenter(_ nextCenter: CGPoint) {
        self.center = nextCenter
        refreshCullBucketsIfNeeded()
    }

    func setZoom(_ nextZoom: CGFloat) {
        self.zoom = max(0.2, min(3.0, nextZoom))
        refreshCullBucketsIfNeeded()
    }

    func panBy(screenDX: CGFloat, screenDY: CGFloat) {
        guard screenDX != 0 || screenDY != 0 else { return }
        center = CGPoint(
            x: center.x - screenDX / zoom,
            y: center.y - screenDY / zoom
        )
        refreshCullBucketsIfNeeded()
    }

    func applyZoom(factor: CGFloat, anchorScreenPoint: CGPoint, viewportSize: CGSize) {
        let worldBefore = screenToWorld(anchorScreenPoint, viewportSize: viewportSize)
        let nextZoom = max(0.2, min(3.0, zoom * factor))
        zoom = nextZoom
        let worldAfter = screenToWorld(anchorScreenPoint, viewportSize: viewportSize)
        center = CGPoint(
            x: center.x + (worldBefore.x - worldAfter.x),
            y: center.y + (worldBefore.y - worldAfter.y)
        )
        refreshCullBucketsIfNeeded()
    }

    func worldToScreen(_ pt: CGPoint, viewportSize: CGSize) -> CGPoint {
        CGPoint(
            x: (pt.x - center.x) * zoom + viewportSize.width * 0.5,
            y: (pt.y - center.y) * zoom + viewportSize.height * 0.5
        )
    }

    func screenToWorld(_ pt: CGPoint, viewportSize: CGSize) -> CGPoint {
        CGPoint(
            x: (pt.x - viewportSize.width * 0.5) / zoom + center.x,
            y: (pt.y - viewportSize.height * 0.5) / zoom + center.y
        )
    }

    func visibleWorldRect(viewportSize: CGSize, overscan: CGFloat) -> CGRect {
        let topLeft = screenToWorld(CGPoint(x: -overscan, y: -overscan), viewportSize: viewportSize)
        let bottomRight = screenToWorld(CGPoint(x: viewportSize.width + overscan, y: viewportSize.height + overscan), viewportSize: viewportSize)
        return CGRect(
            x: topLeft.x,
            y: topLeft.y,
            width: max(1, bottomRight.x - topLeft.x),
            height: max(1, bottomRight.y - topLeft.y)
        )
    }

    /// Coarse bucketed rect — depends ONLY on `cullBucketX/Y/Zoom`, NEVER on continuous `center`/`zoom`.
    func bucketedVisibleWorldRect(viewportSize: CGSize, overscan: CGFloat) -> CGRect {
        let approxCenterX = (CGFloat(cullBucketX) + 0.5) * Self.bucketWorldStep
        let approxCenterY = (CGFloat(cullBucketY) + 0.5) * Self.bucketWorldStep
        let approxZoom = max(0.2, CGFloat(cullZoomBucket) * Self.bucketZoomStep)
        let halfW = (viewportSize.width * 0.5 + overscan) / approxZoom + Self.bucketWorldStep
        let halfH = (viewportSize.height * 0.5 + overscan) / approxZoom + Self.bucketWorldStep
        return CGRect(
            x: approxCenterX - halfW,
            y: approxCenterY - halfH,
            width: halfW * 2,
            height: halfH * 2
        )
    }

    private func refreshCullBucketsIfNeeded() {
        let bx = Int(floor(center.x / Self.bucketWorldStep))
        let by = Int(floor(center.y / Self.bucketWorldStep))
        let bz = max(1, Int(floor(zoom / Self.bucketZoomStep)))
        if bx != cullBucketX { cullBucketX = bx }
        if by != cullBucketY { cullBucketY = by }
        if bz != cullZoomBucket { cullZoomBucket = bz }
    }
}

/// Decoupled hover + active-panning tracker so cursor crossing cards during trackpad glide
/// never invalidates `MoodboardCanvasView` or triggers connector-port flicker.
@Observable
private final class FreeformHoverState {
    var hoveredNodeID: UUID?
    var hoveredPortNodeID: UUID?
    var isActivelyPanning: Bool = false

    @ObservationIgnored private var panIdleTask: Task<Void, Never>?

    var effectiveHoveredNodeID: UUID? {
        if isActivelyPanning { return nil }
        return hoveredPortNodeID ?? hoveredNodeID
    }

    func setNodeHovered(_ id: UUID, hovering: Bool) {
        if hovering {
            if hoveredNodeID != id { hoveredNodeID = id }
        } else if hoveredNodeID == id {
            hoveredNodeID = nil
        }
    }

    func setPortHovered(_ id: UUID, hovering: Bool) {
        if hovering {
            if hoveredPortNodeID != id { hoveredPortNodeID = id }
        } else if hoveredPortNodeID == id {
            hoveredPortNodeID = nil
        }
    }

    func markPanningActivity() {
        if !isActivelyPanning {
            isActivelyPanning = true
        }
        panIdleTask?.cancel()
        panIdleTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled, let self else { return }
            self.isActivelyPanning = false
        }
    }
}

private final class DotGridTileCache {
    static let shared = DotGridTileCache()
    private var tiles: [String: CGImage] = [:]

    private init() {}

    func tile(step: CGFloat, isDark: Bool, isDimmed: Bool, dotRadius: CGFloat) -> CGImage? {
        let radiusKey = Int((dotRadius * 10).rounded())
        let key = "\(step)-\(isDark ? 1 : 0)-\(isDimmed ? 1 : 0)-\(radiusKey)"
        if let existing = tiles[key] {
            return existing
        }

        let scale: CGFloat = 2.0
        let pixelSize = max(16, Int((step * scale).rounded()))
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: pixelSize,
            height: pixelSize,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }
        ctx.scaleBy(x: scale, y: scale)
        ctx.setAllowsAntialiasing(true)
        ctx.setShouldAntialias(true)

        let alpha: CGFloat = isDimmed ? 0.05 : 0.10
        let shade: CGFloat = isDark ? 1.0 : 0.0
        ctx.setFillColor(CGColor(red: shade, green: shade, blue: shade, alpha: alpha))

        let logicalSize = CGFloat(pixelSize) / scale
        let center = logicalSize * 0.5
        let dotRect = CGRect(
            x: center - dotRadius,
            y: center - dotRadius,
            width: dotRadius * 2,
            height: dotRadius * 2
        )
        ctx.fillEllipse(in: dotRect)

        guard let img = ctx.makeImage() else { return nil }
        if tiles.count >= 96 {
            tiles.removeAll(keepingCapacity: true)
        }
        tiles[key] = img
        return img
    }
}

/// GPU-tiled dot grid: 1 cached CGImage tile + 1 GPU offset instead of 2,000+ per-frame Path fills.
private struct FreeformDotGridLayer: View {
    @Environment(\.colorScheme) private var colorScheme
    let camera: FreeformCameraState
    let viewportSize: CGSize

    var body: some View {
        let zoom = camera.zoom
        let quantizedStep: CGFloat = {
            var worldStep: CGFloat = 28
            while worldStep * zoom < 16 { worldStep *= 2 }
            while worldStep * zoom > 56 { worldStep *= 0.5 }
            return max(16, min(64, (worldStep * zoom * 2).rounded() / 2))
        }()
        let dotRadius: CGFloat = max(0.8, min(1.5, zoom))

        let originX = -camera.center.x * zoom + viewportSize.width * 0.5
        let originY = -camera.center.y * zoom + viewportSize.height * 0.5
        let phaseX = positiveMod(originX, quantizedStep)
        let phaseY = positiveMod(originY, quantizedStep)

        if let cgTile = DotGridTileCache.shared.tile(
            step: quantizedStep,
            isDark: colorScheme == .dark,
            isDimmed: zoom < 0.35,
            dotRadius: dotRadius
        ) {
            Image(decorative: cgTile, scale: 2.0)
                .resizable(resizingMode: .tile)
                .frame(
                    width: viewportSize.width + quantizedStep * 3,
                    height: viewportSize.height + quantizedStep * 3
                )
                .offset(
                    x: phaseX - quantizedStep * 1.5,
                    y: phaseY - quantizedStep * 1.5
                )
                .frame(width: viewportSize.width, height: viewportSize.height, alignment: .topLeading)
                .clipped()
                .allowsHitTesting(false)
        }
    }

    private func positiveMod(_ a: CGFloat, _ m: CGFloat) -> CGFloat {
        let r = a.truncatingRemainder(dividingBy: m)
        return r < 0 ? r + m : r
    }
}

/// Single GPU transform wrapper: updates ONLY `scaleEffect` + `offset` on the pre-built world stage.
private struct FreeformCameraViewport<Content: View>: View {
    let camera: FreeformCameraState
    let viewportSize: CGSize
    let content: Content

    init(camera: FreeformCameraState, viewportSize: CGSize, @ViewBuilder content: () -> Content) {
        self.camera = camera
        self.viewportSize = viewportSize
        self.content = content()
    }

    var body: some View {
        let z = camera.zoom
        let tx = viewportSize.width * 0.5 - camera.center.x * z
        let ty = viewportSize.height * 0.5 - camera.center.y * z
        content
            .frame(width: viewportSize.width, height: viewportSize.height, alignment: .topLeading)
            .scaleEffect(z, anchor: .topLeading)
            .offset(x: tx, y: ty)
    }
}

/// Static world-space node stage: NEVER reads continuous `camera.center` / `camera.zoom`.
private struct FreeformWorldNodesLayer<NodeView: View>: View {
    let camera: FreeformCameraState
    let viewportSize: CGSize
    let sortedNodes: [BoardNode]
    let nodeFramesMap: [UUID: BoardRect]
    let selectedNodeIDs: Set<UUID>
    let effectiveRotation: (BoardNode) -> Double
    let allowNodeHitTesting: Bool
    let onHoverChanged: (UUID, Bool) -> Void
    @ViewBuilder let nodeBuilder: (BoardNode) -> NodeView

    var body: some View {
        let visibleNodes: [BoardNode] = {
            if sortedNodes.count <= 40 {
                return sortedNodes
            }
            let visibleWorld = camera.bucketedVisibleWorldRect(viewportSize: viewportSize, overscan: 600)
            return sortedNodes.filter { node in
                let rect = nodeFramesMap[node.id] ?? node.frame
                return rect.cgRect.intersects(visibleWorld) || selectedNodeIDs.contains(node.id)
            }
        }()

        ZStack(alignment: .topLeading) {
            Color.clear
                .frame(width: viewportSize.width, height: viewportSize.height)
                .allowsHitTesting(false)

            ForEach(visibleNodes) { node in
                let worldRect = nodeFramesMap[node.id] ?? node.frame
                let worldW = max(24, CGFloat(worldRect.width))
                let worldH = max(24, CGFloat(worldRect.height))
                let rot = effectiveRotation(node)

                nodeBuilder(node)
                    .frame(width: worldW, height: worldH)
                    .onHover { hovering in
                        onHoverChanged(node.id, hovering)
                    }
                    .allowsHitTesting(allowNodeHitTesting)
                    .rotationEffect(.degrees(rot))
                    .position(x: CGFloat(worldRect.midX), y: CGFloat(worldRect.midY))
            }
        }
    }
}

/// Screen-space constant-size handles for ONLY selected/hovered nodes (skips observing `camera` when idle).
private struct FreeformSelectionHandlesLayer<HandleContent: View>: View {
    let camera: FreeformCameraState
    let hoverState: FreeformHoverState
    let viewportSize: CGSize
    let sortedNodes: [BoardNode]
    let nodeFramesMap: [UUID: BoardRect]
    let selectedNodeIDs: Set<UUID>
    let activeTool: MoodboardTool
    let isSpaceKeyPanning: Bool
    let effectiveRotation: (BoardNode) -> Double
    @ViewBuilder let overlayBuilder: (BoardNode, BoardRect, CGPoint, CGFloat, CGFloat, Double, Bool, Bool) -> HandleContent

    var body: some View {
        if activeTool == .pen || activeTool == .eraser || activeTool == .pan || isSpaceKeyPanning {
            EmptyView()
        } else {
            let hovered = hoverState.effectiveHoveredNodeID
            let activeNodes: [BoardNode] = if activeTool == .connector {
                sortedNodes
            } else if selectedNodeIDs.isEmpty && hovered == nil {
                []
            } else {
                sortedNodes.filter { selectedNodeIDs.contains($0.id) || $0.id == hovered }
            }

            if !activeNodes.isEmpty {
                let zoom = camera.zoom
                ZStack {
                    ForEach(activeNodes) { node in
                        if let worldRect = nodeFramesMap[node.id] {
                            let screenCenter = camera.worldToScreen(CGPoint(x: worldRect.midX, y: worldRect.midY), viewportSize: viewportSize)
                            let screenW = max(24, CGFloat(worldRect.width) * zoom)
                            let screenH = max(24, CGFloat(worldRect.height) * zoom)
                            let isSelected = selectedNodeIDs.contains(node.id)
                            let isHovered = hovered == node.id
                            let rot = effectiveRotation(node)

                            overlayBuilder(node, worldRect, screenCenter, screenW, screenH, rot, isSelected, isHovered)
                                .frame(width: screenW + 44, height: screenH + 88)
                                .rotationEffect(.degrees(rot))
                                .position(screenCenter)
                        }
                    }
                }
            }
        }
    }
}

/// Vector overlay for snap guides, connectors, and ink strokes — completely skipped when empty.
private struct FreeformVectorOverlay: View {
    let camera: FreeformCameraState
    let viewportSize: CGSize
    let connectors: [BoardConnector]
    let inkStrokes: [InkStroke]
    let activeInkPoints: [InkStrokePoint]
    let inkColorHex: String
    let inkWidth: Double
    let selectedConnectorID: UUID?
    let pendingConnectorSource: (nodeID: UUID, anchor: ConnectorAnchor, startWorld: CGPoint)?
    let pendingConnectorCursorWorld: CGPoint
    let snapGuidesX: [CGFloat]
    let snapGuidesY: [CGFloat]
    let nodeFramesMap: [UUID: BoardRect]

    var body: some View {
        let hasVectors = !connectors.isEmpty
            || !inkStrokes.isEmpty
            || activeInkPoints.count >= 2
            || pendingConnectorSource != nil
            || !snapGuidesX.isEmpty
            || !snapGuidesY.isEmpty

        if hasVectors {
            let center = camera.center
            let zoom = camera.zoom
            let visibleWorld = camera.visibleWorldRect(viewportSize: viewportSize, overscan: 240)

            Canvas { context, size in
                let toScreen: (CGPoint) -> CGPoint = { pt in
                    CGPoint(
                        x: (pt.x - center.x) * zoom + size.width * 0.5,
                        y: (pt.y - center.y) * zoom + size.height * 0.5
                    )
                }

                // 1. Snap alignment guides
                if !snapGuidesX.isEmpty || !snapGuidesY.isEmpty {
                    let guideColor = Color.accentColor.opacity(0.65)
                    for wx in snapGuidesX {
                        let sx = toScreen(CGPoint(x: wx, y: 0)).x
                        var path = Path()
                        path.move(to: CGPoint(x: sx, y: 0))
                        path.addLine(to: CGPoint(x: sx, y: size.height))
                        context.stroke(path, with: .color(guideColor), style: StrokeStyle(lineWidth: 0.75, dash: [4, 4]))
                    }
                    for wy in snapGuidesY {
                        let sy = toScreen(CGPoint(x: 0, y: wy)).y
                        var path = Path()
                        path.move(to: CGPoint(x: 0, y: sy))
                        path.addLine(to: CGPoint(x: size.width, y: sy))
                        context.stroke(path, with: .color(guideColor), style: StrokeStyle(lineWidth: 0.75, dash: [4, 4]))
                    }
                }

                // 2. Connectors & pending connector drag preview
                for connector in connectors {
                    guard let fromR = nodeFramesMap[connector.fromNodeID],
                          let toR = nodeFramesMap[connector.toNodeID] else { continue }
                    let bounds = fromR.cgRect.union(toR.cgRect).insetBy(dx: -80, dy: -80)
                    guard bounds.intersects(visibleWorld) else { continue }

                    let (startW, endW, c1W, c2W) = ConnectorGeometry.resolvePathPoints(
                        fromRect: fromR.cgRect,
                        fromAnchor: connector.fromAnchor,
                        fromNormalizedPoint: connector.fromNormalizedPoint,
                        toRect: toR.cgRect,
                        toAnchor: connector.toAnchor,
                        toNormalizedPoint: connector.toNormalizedPoint,
                        style: connector.style
                    )
                    let start = toScreen(startW)
                    let end = toScreen(endW)
                    let c1 = toScreen(c1W)
                    let c2 = toScreen(c2W)

                    let isSel = selectedConnectorID == connector.id
                    let strokeColor = isSel ? Color.accentColor : Color(charkleHex: connector.colorHex)
                    var path = Path()
                    path.move(to: start)
                    switch connector.style {
                    case .curved:
                        path.addCurve(to: end, control1: c1, control2: c2)
                    case .elbow:
                        let midX = (start.x + end.x) * 0.5
                        path.addLine(to: CGPoint(x: midX, y: start.y))
                        path.addLine(to: CGPoint(x: midX, y: end.y))
                        path.addLine(to: end)
                    case .straight:
                        path.addLine(to: end)
                    }

                    let style = StrokeStyle(
                        lineWidth: max(1.5, (isSel ? 2.6 : 2.0) * zoom),
                        lineCap: .round,
                        lineJoin: .round,
                        dash: connector.dashed ? [7 * zoom, 5 * zoom] : []
                    )
                    context.stroke(path, with: .color(strokeColor), style: style)

                    let tangentSrc: CGPoint = switch connector.style {
                    case .curved: c2
                    case .elbow: CGPoint(x: (start.x + end.x) * 0.5, y: end.y)
                    case .straight: start
                    }
                    let angle = atan2(end.y - tangentSrc.y, end.x - tangentSrc.x)
                    let arrowLen = max(7, 10 * zoom)
                    let spread: CGFloat = .pi / 6.5
                    var head = Path()
                    head.move(to: CGPoint(x: end.x - arrowLen * cos(angle - spread), y: end.y - arrowLen * sin(angle - spread)))
                    head.addLine(to: end)
                    head.addLine(to: CGPoint(x: end.x - arrowLen * cos(angle + spread), y: end.y - arrowLen * sin(angle + spread)))
                    context.stroke(head, with: .color(strokeColor), style: StrokeStyle(lineWidth: max(1.5, 2.0 * zoom), lineCap: .round, lineJoin: .round))

                    if connector.toNormalizedPoint != nil {
                        let haloRadius = max(6.0, 9.0 * zoom)
                        let haloRect = CGRect(
                            x: end.x - haloRadius,
                            y: end.y - haloRadius,
                            width: haloRadius * 2,
                            height: haloRadius * 2
                        )
                        context.fill(Path(ellipseIn: haloRect), with: .color(strokeColor.opacity(0.22)))

                        let dotRadius = max(2.8, 3.6 * zoom)
                        let dotRect = CGRect(
                            x: end.x - dotRadius,
                            y: end.y - dotRadius,
                            width: dotRadius * 2,
                            height: dotRadius * 2
                        )
                        context.fill(Path(ellipseIn: dotRect), with: .color(strokeColor))
                        context.stroke(
                            Path(ellipseIn: dotRect),
                            with: .color(Color.white.opacity(0.92)),
                            style: StrokeStyle(lineWidth: max(1.1, 1.4 * zoom))
                        )
                    }
                }

                if let pending = pendingConnectorSource {
                    let s = toScreen(pending.startWorld)
                    let e = toScreen(pendingConnectorCursorWorld)
                    let dist = max(36, hypot(e.x - s.x, e.y - s.y) * 0.35)
                    var p = Path()
                    p.move(to: s)
                    p.addCurve(
                        to: e,
                        control1: CGPoint(x: s.x + dist * 0.5, y: s.y),
                        control2: CGPoint(x: e.x - dist * 0.5, y: e.y)
                    )
                    context.stroke(
                        p,
                        with: .color(Color.accentColor.opacity(0.85)),
                        style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [5, 4])
                    )
                }

                // 3. Ink strokes
                let allStrokes: [InkStroke] = if activeInkPoints.count >= 2 {
                    inkStrokes + [InkStroke(points: activeInkPoints, colorHex: inkColorHex, lineWidth: inkWidth)]
                } else {
                    inkStrokes
                }

                for stroke in allStrokes where stroke.points.count >= 2 {
                    var minX = Double.greatestFiniteMagnitude
                    var minY = Double.greatestFiniteMagnitude
                    var maxX = -Double.greatestFiniteMagnitude
                    var maxY = -Double.greatestFiniteMagnitude
                    for pt in stroke.points {
                        if pt.x < minX { minX = pt.x }
                        if pt.y < minY { minY = pt.y }
                        if pt.x > maxX { maxX = pt.x }
                        if pt.y > maxY { maxY = pt.y }
                    }
                    let box = CGRect(x: minX - 12, y: minY - 12, width: (maxX - minX) + 24, height: (maxY - minY) + 24)
                    guard box.intersects(visibleWorld) else { continue }

                    let screenPts = stroke.points.map { toScreen(CGPoint(x: $0.x, y: $0.y)) }
                    var path = Path()
                    path.move(to: screenPts[0])
                    if screenPts.count == 2 {
                        path.addLine(to: screenPts[1])
                    } else {
                        for i in 1..<(screenPts.count - 1) {
                            let mid = CGPoint(
                                x: (screenPts[i].x + screenPts[i + 1].x) * 0.5,
                                y: (screenPts[i].y + screenPts[i + 1].y) * 0.5
                            )
                            path.addQuadCurve(to: mid, control: screenPts[i])
                        }
                        if let last = screenPts.last {
                            path.addLine(to: last)
                        }
                    }
                    context.stroke(
                        path,
                        with: .color(Color(charkleHex: stroke.colorHex).opacity(stroke.opacity)),
                        style: StrokeStyle(
                            lineWidth: max(1.2, CGFloat(stroke.lineWidth) * zoom),
                            lineCap: .round,
                            lineJoin: .round
                        )
                    )
                }
            }
            .allowsHitTesting(false)
        }
    }
}

private struct FreeformConnectorLabelsLayer: View {
    @Environment(\.colorScheme) private var colorScheme
    let camera: FreeformCameraState
    let viewportSize: CGSize
    let connectors: [BoardConnector]
    let nodeFramesMap: [UUID: BoardRect]
    let selectedConnectorID: UUID?
    let activeTool: MoodboardTool
    let onSelectConnector: (BoardConnector) -> Void

    var body: some View {
        let visibleWorld = camera.visibleWorldRect(viewportSize: viewportSize, overscan: 120)
        let zoom = camera.zoom

        ZStack {
            ForEach(connectors) { connector in
                if let fromR = nodeFramesMap[connector.fromNodeID],
                   let toR = nodeFramesMap[connector.toNodeID] {
                    let (start, end, c1, c2) = ConnectorGeometry.resolvePathPoints(
                        fromRect: fromR.cgRect,
                        fromAnchor: connector.fromAnchor,
                        fromNormalizedPoint: connector.fromNormalizedPoint,
                        toRect: toR.cgRect,
                        toAnchor: connector.toAnchor,
                        toNormalizedPoint: connector.toNormalizedPoint,
                        style: connector.style
                    )
                    let midWorld = ConnectorGeometry.midpoint(start: start, end: end, c1: c1, c2: c2, style: connector.style)
                    if visibleWorld.contains(midWorld) {
                        let midScreen = camera.worldToScreen(midWorld, viewportSize: viewportSize)
                        let isSel = selectedConnectorID == connector.id
                        Button {
                            onSelectConnector(connector)
                        } label: {
                            Group {
                                if let label = connector.label, !label.isEmpty {
                                    Text(label)
                                        .font(.system(size: max(9, 11 * min(1.2, zoom)), weight: .medium))
                                        .foregroundStyle(.primary)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 3)
                                        .background(CanvasSurface.elevated(for: colorScheme), in: Capsule(style: .continuous))
                                        .overlay(
                                            Capsule(style: .continuous)
                                                .strokeBorder(isSel ? Color.accentColor : CanvasSurface.hairline(for: colorScheme), lineWidth: isSel ? 1.5 : 0.75)
                                        )
                                } else if isSel || activeTool == .connector {
                                    Circle()
                                        .fill(CanvasSurface.elevated(for: colorScheme))
                                        .frame(width: 14, height: 14)
                                        .overlay(
                                            Image(systemName: "tag")
                                                .font(.system(size: 7))
                                                .foregroundStyle(.secondary)
                                        )
                                        .overlay(Circle().strokeBorder(Color.accentColor.opacity(0.6), lineWidth: 1))
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .position(midScreen)
                        .allowsHitTesting(activeTool == .select || activeTool == .connector)
                    }
                }
            }
        }
    }
}

private struct FreeformZoomControlsPill: View {
    @Environment(\.colorScheme) private var colorScheme
    let camera: FreeformCameraState
    let reduceMotion: Bool
    let onZoomStep: (CGFloat) -> Void
    let onResetZoom: () -> Void
    let onFitBoard: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Button {
                onZoomStep(0.82)
            } label: {
                Image(systemName: "minus")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .help("缩小画布")

            Button {
                onResetZoom()
            } label: {
                Text("\(Int((camera.zoom * 100).rounded()))%")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .monospacedDigit()
                    .frame(minWidth: 42)
            }
            .buttonStyle(.plain)
            .help("重置为 100%")

            Button {
                onZoomStep(1.22)
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .help("放大画布")

            Rectangle()
                .fill(CanvasSurface.hairline(for: colorScheme))
                .frame(width: 1, height: 14)

            Button {
                onFitBoard()
            } label: {
                Image(systemName: "arrow.up.left.and.down.right.magnifyingglass")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .help("适配全板视图")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .canvasLiquidGlass(in: Capsule(style: .continuous))
    }
}
