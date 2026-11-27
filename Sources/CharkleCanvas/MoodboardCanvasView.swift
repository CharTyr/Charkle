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
    public var onExportPureRef: () -> Void
    public var onOpenInPureRef: () -> Void
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
        onExportPureRef: @escaping () -> Void = {},
        onOpenInPureRef: @escaping () -> Void = {},
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
        self.onExportPureRef = onExportPureRef
        self.onOpenInPureRef = onOpenInPureRef
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

    // Isolated @Observable camera, hover, and live-gesture models so 60-120Hz trackpad pan/zoom,
    // dragging, resizing, rotating, ink drawing, and marquee selection NEVER invalidate
    // MoodboardCanvasView.body or unrelated toolbars / node trees!
    @State private var camera = FreeformCameraState()
    @State private var hoverState = FreeformHoverState()
    @State private var interaction = FreeformInteractionState()
    @State private var liveDocRef = LiveMoodboardDocumentRef()
    @State private var panStartCenter: CGPoint?
    @State private var isSpaceKeyPanning: Bool = false

    // Connector style & label popover
    @State private var connectorStyle: ConnectorStyle = .curved
    @State private var connectorDashed: Bool = false
    @State private var editingConnectorLabelID: UUID?
    @State private var connectorLabelDraft: String = ""
    @State private var connectorStyleDraft: ConnectorStyle = .curved
    @State private var connectorDashedDraft: Bool = false

    // Freehand Ink Pen options
    @State private var inkColorHex: String = "#D95D48"
    @State private var inkWidth: Double = 3.5
    @State private var exportIncludeAnnotations: Bool = true
    @State private var exportIncludePalette: Bool = true

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
        buildCanvasRoot()
    }

    private func buildCanvasRoot() -> some View {
        liveDocRef.update(document)
        // Use an infinitely flexible Color.clear base so fixed-size inner canvas stages
        // can NEVER inflate the root HStack height or clip the bottom of the app window.
        return Color.clear
            .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
            .onGeometryChange(for: CGSize.self) { proxy in
                CGSize(width: floor(max(1, proxy.size.width)), height: floor(max(1, proxy.size.height)))
            } action: { _, newSize in
                if newSize.width > 40, newSize.height > 40,
                   (abs(newSize.width - viewportSize.width) >= 1 || abs(newSize.height - viewportSize.height) >= 1) {
                    viewportSize = newSize
                }
            }
            .overlay {
                ZStack {
                    CanvasSurface.ground(for: colorScheme)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            clearCanvasSelection()
                        }

                    freeformInfiniteStage
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .clipped()
                        .allowsHitTesting(!isAnyLocalModalPresented)

                    if document.nodes.isEmpty && document.inkStrokes.isEmpty {
                        emptyBoardPlaceholder
                            .allowsHitTesting(false)
                    }

                    // Top floating Board Palette Strip (positioned below window top chrome, clear of trailing button)
                    VStack {
                        if showTopPaletteStrip && !document.extractedPalette.isEmpty {
                            BoardPaletteHeaderStrip(
                                colors: document.extractedPalette,
                                onCopyHex: callbacks.onCopyColorHex,
                                onSearchColor: callbacks.onSearchByColorHex
                            )
                            .padding(.top, 12)
                            .padding(.leading, 14)
                            .padding(.trailing, viewportSize.width < 920 ? 124 : 14)
                            .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
                        }
                        Spacer(minLength: 0)
                    }

                    // Unified Responsive Bottom HUD (Transform Pill + Tool Options + Tool Dock + Zoom Controls)
                    // Adapts cleanly across wide, medium, and narrow window sizes with zero clipping or overlap.
                    VStack(spacing: 8) {
                        Spacer(minLength: 0)

                        if !selectedUnlockedNodes.isEmpty && activeTool == .select {
                            selectedTransformBar
                                .transition(
                                    .opacity
                                        .combined(with: .scale(scale: 0.94, anchor: .bottom))
                                        .combined(with: .offset(y: 6))
                                )
                        }

                        if !shouldInlineToolOptions && (activeTool == .pen || activeTool == .connector) {
                            floatingContextualToolOptionsBar
                                .transition(.opacity.combined(with: .scale(scale: 0.95, anchor: .bottom)))
                        }

                        adaptiveBottomDockAndZoomRow
                    }
                    .padding(.horizontal, 14)
                    .padding(.bottom, 16)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .animation(CanvasMotion.accessible(CanvasMotion.settleStrong, reduced: reduceMotion), value: selectedNodeIDs)
                    .animation(CanvasMotion.accessible(CanvasMotion.settleStrong, reduced: reduceMotion), value: activeTool)

                    // External drop highlight border
                    CanvasDropRingOverlay(isTargeted: isDropTargeted, padding: 10, fillOpacity: 0.04)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
            }
            .onAppear {
                liveDocRef.update(document)
                hoverState.setSuspended(isAnyLocalModalPresented)
                syncCameraFromDocument()
                ensureFreeformModeIfLegacy()
                prefetchBoardThumbnails()
            }
            .onChange(of: isAnyLocalModalPresented) { _, suspended in
                hoverState.setSuspended(suspended)
            }
            .onChange(of: document.id) { _, _ in
                liveDocRef.update(document)
                selectedNodeIDs.removeAll()
                selectedConnectorID = nil
                editingConnectorLabelID = nil
                activeTool = .select
                interaction.resetAll()
                syncCameraFromDocument()
                ensureFreeformModeIfLegacy()
                prefetchBoardThumbnails()
            }
            .onChange(of: document.mode.isAutoEditorial) { _, isAuto in
                if isAuto {
                    ensureFreeformModeIfLegacy()
                }
            }
            .onDrop(of: [.fileURL, .url, .image, .plainText], isTargeted: $isDropTargeted) { providers, location in
                handleCanvasDrop(providers: providers, screenLocation: location)
            }
            .focusable()
            .focusEffectDisabled()
            .onKeyPress(.escape) {
                guard !isAnyLocalModalPresented, !isEditingTextInWindow else { return .ignored }
                return handleEscapeKey() ? .handled : .ignored
            }
            .onKeyPress(.delete) {
                guard !isAnyLocalModalPresented, !isEditingTextInWindow else { return .ignored }
                deleteCurrentSelection()
                return .handled
            }
            .onKeyPress(.deleteForward) {
                guard !isAnyLocalModalPresented, !isEditingTextInWindow else { return .ignored }
                deleteCurrentSelection()
                return .handled
            }
            .onKeyPress(characters: CharacterSet(charactersIn: "acxvhperACXVHPER")) { press in
                guard !isAnyLocalModalPresented, !isEditingTextInWindow else { return .ignored }
                let lower = press.characters.lowercased()
                let mods = press.modifiers.intersection([.command, .option, .control, .shift])
                if mods == [.command] {
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
                // Transform shortcuts work whenever unlocked nodes are selected
                if !selectedUnlockedNodes.isEmpty {
                    if lower == "r" && mods.isEmpty {
                        rotateSelectedNodes(by: 90)
                        return .handled
                    }
                    if lower == "r" && mods == [.shift] {
                        rotateSelectedNodes(by: -90)
                        return .handled
                    }
                    if lower == "h" && mods == [.shift] {
                        flipSelectedNodes(horizontal: true)
                        return .handled
                    }
                    if lower == "v" && mods == [.shift] {
                        flipSelectedNodes(horizontal: false)
                        return .handled
                    }
                }
                guard mods.isEmpty else { return .ignored }
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

    private var isAnyLocalModalPresented: Bool {
        isOverlayPresented
            || semanticCropTarget != nil
            || visualMatchTarget != nil
            || pinpointAnnotateTarget != nil
            || editingConnectorLabelID != nil
    }

    private var freeformInfiniteStage: some View {
        let sortedNodes = document.nodes.sorted { lhs, rhs in
            let lGroup = if case .groupFrame = lhs.kind { true } else { false }
            let rGroup = if case .groupFrame = rhs.kind { true } else { false }
            if lGroup != rGroup { return lGroup }
            return lhs.zIndex < rhs.zIndex
        }
        let nodesByID = Dictionary(uniqueKeysWithValues: document.nodes.map { ($0.id, $0) })
        let groupChildCounts = computeGroupChildCounts(nodes: sortedNodes)
        let allowNodeHitTesting = !isAnyLocalModalPresented && activeTool != .pen && activeTool != .eraser && activeTool != .pan && !isSpaceKeyPanning

        return ZStack {
            // 1. GPU-tiled architectural dot grid (1 cached CGImage tile + GPU offset, zero Path loop)
            FreeformDotGridLayer(camera: camera, viewportSize: viewportSize)

            // 2. Native macOS trackpad scroll-pan, Option/Cmd zoom, Middle-mouse drag pan, Hold-Space pan & focus-safe shortcuts
            FreeformInputBridge(
                isSuspended: isAnyLocalModalPresented,
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
                },
                onKeyCommand: { event in
                    handleWindowKeyCommand(event)
                }
            )
            .allowsHitTesting(false)

            // 3. Interactive background canvas surface: click empty area to deselect/select connector, or drag for pan/marquee/pen/eraser
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
                    interaction: interaction,
                    viewportSize: viewportSize,
                    sortedNodes: sortedNodes,
                    selectedNodeIDs: selectedNodeIDs,
                    allowNodeHitTesting: allowNodeHitTesting,
                    onHoverChanged: { nodeID, hovering in
                        guard !isAnyLocalModalPresented else {
                            hoverState.clearAll()
                            return
                        }
                        hoverState.setNodeHovered(nodeID, hovering: hovering)
                    },
                    nodeBuilder: { node in
                        renderNodeBody(node: node, isAutoMode: false, groupChildCounts: groupChildCounts)
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

            // 5. Vector overlay (snap guides, connectors, ink strokes) — completely isolated from MoodboardCanvasView.body
            FreeformVectorOverlay(
                camera: camera,
                interaction: interaction,
                viewportSize: viewportSize,
                nodesByID: nodesByID,
                selectedNodeIDs: selectedNodeIDs,
                connectors: document.connectors,
                inkStrokes: document.inkStrokes,
                inkColorHex: inkColorHex,
                inkWidth: inkWidth,
                selectedConnectorID: selectedConnectorID
            )

            // 6. Screen-space constant-size resize / rotation / connector port handles
            //    (culled in connector mode; only observes camera when handles are visible)
            FreeformSelectionHandlesLayer(
                camera: camera,
                hoverState: hoverState,
                interaction: interaction,
                viewportSize: viewportSize,
                sortedNodes: sortedNodes,
                selectedNodeIDs: selectedNodeIDs,
                activeTool: activeTool,
                isSpaceKeyPanning: isSpaceKeyPanning
            ) { node, worldRect, screenCenter, screenW, screenH, currentRotation, isSelected, isHovered in
                let isActiveConnectorSource = (interaction.pendingConnectorSource?.nodeID == node.id)
                ZStack {
                    if (activeTool == .connector || isHovered || isSelected || isActiveConnectorSource) && activeTool != .pen && activeTool != .eraser && !isSpaceKeyPanning {
                        connectorPortsOverlay(
                            node: node,
                            worldRect: worldRect,
                            width: screenW,
                            height: screenH,
                            currentRotation: currentRotation,
                            sortedNodes: sortedNodes
                        )
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
                    interaction: interaction,
                    viewportSize: viewportSize,
                    nodesByID: nodesByID,
                    selectedNodeIDs: selectedNodeIDs,
                    connectors: document.connectors,
                    selectedConnectorID: selectedConnectorID,
                    activeTool: activeTool,
                    onSelectConnector: { connector in
                        selectedConnectorID = connector.id
                        selectedNodeIDs.removeAll()
                        connectorLabelDraft = connector.label ?? ""
                        connectorStyleDraft = connector.style
                        connectorDashedDraft = connector.dashed
                        editingConnectorLabelID = connector.id
                    }
                )
            }

            // 8. Isolated Freeform rubber-band marquee overlay (never invalidates node tree while dragging)
            FreeformMarqueeOverlay(interaction: interaction)
        }
        .coordinateSpace(name: "charkle-freeform-stage")
        .clipped()
    }

    // MARK: - Selection Transform Helpers & Interactive Rotation Handle

    private var selectedUnlockedNodes: [BoardNode] {
        document.nodes.filter { selectedNodeIDs.contains($0.id) && !$0.isLocked }
    }

    private func prefetchBoardThumbnails() {
        // Prefetch ONLY the tier each board node actually renders (`weight >= 2` -> `.preview1400`,
        // standard cards -> `.grid520`), capped to the initial visible batch so opening a board
        // never decodes dozens of unused 5.8 MB `.preview1400` bitmaps.
        var gridIDs: [UUID] = []
        var heroIDs: [UUID] = []
        var seenGrid = Set<UUID>()
        var seenHero = Set<UUID>()
        for node in document.nodes {
            guard case .assetRef(let assetID, _, let weight, _) = node.kind else { continue }
            if weight >= 2 {
                if heroIDs.count < 8, seenHero.insert(assetID).inserted {
                    heroIDs.append(assetID)
                }
            } else {
                if gridIDs.count < 24, seenGrid.insert(assetID).inserted {
                    gridIDs.append(assetID)
                }
            }
            if gridIDs.count >= 24 && heroIDs.count >= 8 { break }
        }
        if !gridIDs.isEmpty {
            loader.prefetch(assetIDs: gridIDs, tier: .grid520)
        }
        if !heroIDs.isEmpty {
            for heroID in heroIDs where loader.cachedImage(for: heroID, tier: .preview1400) == nil {
                Task(priority: .utility) {
                    _ = await loader.loadCGImage(for: heroID, tier: .preview1400)
                }
            }
        }
    }

    private func handleEscapeKey() -> Bool {
        if interaction.pendingConnectorSource != nil {
            interaction.pendingConnectorSource = nil
            interaction.pendingConnectorHoverTargetID = nil
            return true
        }
        if interaction.freeformMarqueeStart != nil {
            interaction.freeformMarqueeStart = nil
            interaction.freeformMarqueeCurrent = nil
            interaction.freeformMarqueeBaseSelection = []
            return true
        }
        if editingConnectorLabelID != nil {
            editingConnectorLabelID = nil
            return true
        }
        if activeTool != .select {
            activeTool = .select
            return true
        }
        if !selectedNodeIDs.isEmpty || selectedConnectorID != nil || swappingNodeID != nil {
            selectedNodeIDs.removeAll()
            selectedConnectorID = nil
            callbacks.onSelectSwapTarget(nil)
            return true
        }
        return false
    }

    /// Window-level shortcut dispatcher routed via `CanvasInputCatcherView` so keyboard shortcuts
    /// keep working reliably regardless of Caps Lock (macOS IME switch) or SwiftUI firstResponder drift.
    private func handleWindowKeyCommand(_ event: NSEvent) -> Bool {
        guard !isAnyLocalModalPresented else { return false }
        let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])

        // Backspace (51) or Forward Delete (117)
        if (event.keyCode == 51 || event.keyCode == 117) && mods.isEmpty {
            guard !selectedNodeIDs.isEmpty || selectedConnectorID != nil else { return false }
            deleteCurrentSelection()
            return true
        }

        // Escape (53)
        if event.keyCode == 53 && mods.isEmpty {
            return handleEscapeKey()
        }

        guard let lower = event.charactersIgnoringModifiers?.lowercased(), lower.count == 1 else {
            return false
        }

        if mods == [.command] {
            switch lower {
            case "a":
                selectedNodeIDs = Set(document.nodes.map(\.id))
                selectedConnectorID = nil
                return true
            case "c":
                let ids = selectedAssetIDs()
                guard !ids.isEmpty else { return false }
                callbacks.onCopyAssets(ids)
                return true
            case "x":
                guard !selectedNodeIDs.isEmpty else { return false }
                cutBoardNodes(selectedNodeIDs)
                return true
            case "v":
                callbacks.onPasteIntoBoard(defaultPasteLocation())
                return true
            default:
                return false
            }
        }

        if !selectedUnlockedNodes.isEmpty {
            if lower == "r" && mods.isEmpty {
                rotateSelectedNodes(by: 90)
                return true
            }
            if lower == "r" && mods == [.shift] {
                rotateSelectedNodes(by: -90)
                return true
            }
            if lower == "h" && mods == [.shift] {
                flipSelectedNodes(horizontal: true)
                return true
            }
            if lower == "v" && mods == [.shift] {
                flipSelectedNodes(horizontal: false)
                return true
            }
        }

        guard mods.isEmpty else { return false }
        switch lower {
        case "v": activeTool = .select; return true
        case "h": activeTool = .pan; return true
        case "c": activeTool = .connector; return true
        case "p": activeTool = .pen; return true
        case "e": activeTool = .eraser; return true
        default: return false
        }
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
        let isDraggingThis = interaction.rotatingNodeID == node.id
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
                        if interaction.rotatingNodeID == nil {
                            interaction.rotatingNodeID = node.id
                            interaction.rotationStartDegrees = node.rotationDegrees
                            interaction.rotationDragStartAngle = angleNow
                        }
                        var raw = normalizeDegrees(interaction.rotationStartDegrees + (angleNow - interaction.rotationDragStartAngle))
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
                        interaction.liveRotationDegrees = raw
                    }
                    .onEnded { _ in
                        let finalAngle = interaction.liveRotationDegrees
                        interaction.rotatingNodeID = nil
                        interaction.liveRotationDegrees = nil
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
        let singleAngle = single?.rotationDegrees ?? 0
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
        return responder is NSTextView || responder is NSTextField || responder is NSText
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
                        if interaction.freeformMarqueeStart == nil {
                            interaction.freeformMarqueeStart = value.startLocation
                            let mods = NSEvent.modifierFlags
                            interaction.freeformMarqueeBaseSelection = (mods.contains(.shift) || mods.contains(.command))
                                ? selectedNodeIDs
                                : []
                        }
                        interaction.freeformMarqueeCurrent = value.location
                        if let s = interaction.freeformMarqueeStart {
                            let w1 = screenToWorld(s)
                            let w2 = screenToWorld(value.location)
                            let worldBox = BoardRect(
                                x: min(w1.x, w2.x),
                                y: min(w1.y, w2.y),
                                width: abs(w2.x - w1.x),
                                height: abs(w2.y - w1.y)
                            )
                            var nextSelection = interaction.freeformMarqueeBaseSelection
                            for node in document.nodes where Self.nodeIntersectsWorldBox(node, worldBox: worldBox) {
                                nextSelection.insert(node.id)
                            }
                            if nextSelection != selectedNodeIDs {
                                selectedNodeIDs = nextSelection
                            }
                        }
                    }
                case .pen:
                    guard distance >= 2 else { return }
                    let worldPt = screenToWorld(value.location)
                    if let last = interaction.activeInkPoints.last {
                        if hypot(worldPt.x - last.x, worldPt.y - last.y) >= 2.0 / camera.zoom {
                            interaction.activeInkPoints.append(InkStrokePoint(x: worldPt.x, y: worldPt.y, pressure: 0.6))
                        }
                    } else {
                        interaction.activeInkPoints = [InkStrokePoint(x: worldPt.x, y: worldPt.y, pressure: 0.6)]
                    }
                case .eraser:
                    markEraseNear(worldPoint: screenToWorld(value.location))
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
                interaction.freeformMarqueeStart = nil
                interaction.freeformMarqueeCurrent = nil
                interaction.freeformMarqueeBaseSelection = []
                if activeTool == .pen && interaction.activeInkPoints.count >= 2 {
                    var nextDoc = document
                    let stroke = InkStroke(
                        points: interaction.activeInkPoints,
                        colorHex: inkColorHex,
                        lineWidth: inkWidth,
                        opacity: 0.92,
                        zIndex: 1000 + nextDoc.inkStrokes.count
                    )
                    nextDoc.inkStrokes.append(stroke)
                    interaction.activeInkPoints = []
                    callbacks.onCommitDocument(nextDoc)
                } else if activeTool == .eraser {
                    commitPendingErasures()
                } else {
                    interaction.activeInkPoints = []
                    // Clean click on background: first hit-test connectors (including unlabeled ones), else deselect
                    if distance < 4 {
                        let clickWorld = screenToWorld(value.location)
                        if (activeTool == .select || activeTool == .connector),
                           let hitConnector = hitTestConnector(at: clickWorld) {
                            let wasAlreadySelected = selectedConnectorID == hitConnector.id
                            selectedNodeIDs.removeAll()
                            selectedConnectorID = hitConnector.id
                            if wasAlreadySelected {
                                connectorLabelDraft = hitConnector.label ?? ""
                                connectorStyleDraft = hitConnector.style
                                connectorDashedDraft = hitConnector.dashed
                                editingConnectorLabelID = hitConnector.id
                            }
                        } else {
                            clearCanvasSelection()
                        }
                    }
                }
            }
    }

    internal nonisolated static func nodeIntersectsWorldBox(_ node: BoardNode, worldBox: BoardRect) -> Bool {
        let rot = node.rotationDegrees
        guard rot.isFinite, abs(rot) > 0.1 else {
            return node.frame.intersects(worldBox)
        }
        let rect = node.frame.cgRect
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let corners = [
            CGPoint(x: rect.minX, y: rect.minY),
            CGPoint(x: rect.maxX, y: rect.minY),
            CGPoint(x: rect.minX, y: rect.maxY),
            CGPoint(x: rect.maxX, y: rect.maxY)
        ].map { ConnectorGeometry.rotatedPoint($0, around: center, degrees: rot) }
        guard let minX = corners.map(\.x).min(),
              let maxX = corners.map(\.x).max(),
              let minY = corners.map(\.y).min(),
              let maxY = corners.map(\.y).max() else {
            return node.frame.intersects(worldBox)
        }
        let rotatedAABB = BoardRect(x: Double(minX), y: Double(minY), width: Double(maxX - minX), height: Double(maxY - minY))
        return rotatedAABB.intersects(worldBox)
    }

    internal nonisolated static func resolveBestSnapDelta(
        movingRect: BoardRect,
        rawDX: Double,
        rawDY: Double,
        otherRects: [BoardRect],
        threshold: Double
    ) -> (dx: Double, dy: Double, guidesX: [CGFloat], guidesY: [CGFloat]) {
        guard threshold > 0, !otherRects.isEmpty else {
            return (rawDX, rawDY, [], [])
        }
        let candMinX = movingRect.minX + rawDX
        let candMidX = movingRect.midX + rawDX
        let candMaxX = movingRect.maxX + rawDX
        let candMinY = movingRect.minY + rawDY
        let candMidY = movingRect.midY + rawDY
        let candMaxY = movingRect.maxY + rawDY

        var bestDX = rawDX
        var bestXDist = threshold
        var bestGuideX: CGFloat?

        var bestDY = rawDY
        var bestYDist = threshold
        var bestGuideY: CGFloat?

        for other in otherRects {
            let xPairs: [(cand: Double, target: Double, origin: Double)] = [
                (candMinX, other.minX, movingRect.minX),
                (candMidX, other.midX, movingRect.midX),
                (candMaxX, other.maxX, movingRect.maxX),
                (candMinX, other.maxX, movingRect.minX),
                (candMaxX, other.minX, movingRect.maxX)
            ]
            for pair in xPairs {
                let d = abs(pair.cand - pair.target)
                if d < bestXDist {
                    bestXDist = d
                    bestDX = pair.target - pair.origin
                    bestGuideX = CGFloat(pair.target)
                }
            }

            let yPairs: [(cand: Double, target: Double, origin: Double)] = [
                (candMinY, other.minY, movingRect.minY),
                (candMidY, other.midY, movingRect.midY),
                (candMaxY, other.maxY, movingRect.maxY),
                (candMinY, other.maxY, movingRect.minY),
                (candMaxY, other.minY, movingRect.maxY)
            ]
            for pair in yPairs {
                let d = abs(pair.cand - pair.target)
                if d < bestYDist {
                    bestYDist = d
                    bestDY = pair.target - pair.origin
                    bestGuideY = CGFloat(pair.target)
                }
            }
        }

        return (
            bestDX,
            bestDY,
            bestGuideX.map { [$0] } ?? [],
            bestGuideY.map { [$0] } ?? []
        )
    }

    private func nodeDragGesture(for node: BoardNode) -> some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .named("charkle-freeform-stage"))
            .onChanged { value in
                guard !node.isLocked, interaction.resizingNodeID == nil, interaction.rotatingNodeID == nil else { return }
                if interaction.activeNodeDragID == nil {
                    interaction.activeNodeDragID = node.id
                    if !selectedNodeIDs.contains(node.id) {
                        selectedNodeIDs = [node.id]
                    }
                    // Capture enclosed unlocked children of ALL selected/dragged groupFrames (rotation-aware)
                    let movingGroups = document.nodes.filter { candidate in
                        guard !candidate.isLocked,
                              (candidate.id == node.id || selectedNodeIDs.contains(candidate.id)) else { return false }
                        if case .groupFrame = candidate.kind { return true }
                        return false
                    }
                    if !movingGroups.isEmpty {
                        var enclosed = Set<UUID>()
                        for other in document.nodes where !other.isLocked {
                            if case .groupFrame = other.kind { continue }
                            let center = CGPoint(x: other.frame.midX, y: other.frame.midY)
                            if movingGroups.contains(where: { group in
                                other.id != group.id
                                    && ConnectorGeometry.containsPoint(center, in: group.frame.cgRect, rotationDegrees: group.rotationDegrees)
                            }) {
                                enclosed.insert(other.id)
                            }
                        }
                        interaction.activeGroupChildIDs = enclosed
                    } else {
                        interaction.activeGroupChildIDs = []
                    }
                }
                var dx = value.translation.width / camera.zoom
                var dy = value.translation.height / camera.zoom

                // Smart alignment snap guides (6pt screen threshold, nearest-match across min/mid/max edges; hold ⌘ to bypass)
                if !NSEvent.modifierFlags.contains(.command) {
                    let snapThreshold = 6.0 / Double(camera.zoom)
                    let otherRects = document.nodes.compactMap { other -> BoardRect? in
                        if other.id == node.id
                            || selectedNodeIDs.contains(other.id)
                            || interaction.activeGroupChildIDs.contains(other.id) {
                            return nil
                        }
                        return other.frame
                    }
                    let snapped = Self.resolveBestSnapDelta(
                        movingRect: node.frame,
                        rawDX: Double(dx),
                        rawDY: Double(dy),
                        otherRects: otherRects,
                        threshold: snapThreshold
                    )
                    dx = CGFloat(snapped.dx)
                    dy = CGFloat(snapped.dy)
                    if interaction.snapGuidesX != snapped.guidesX {
                        interaction.snapGuidesX = snapped.guidesX
                    }
                    if interaction.snapGuidesY != snapped.guidesY {
                        interaction.snapGuidesY = snapped.guidesY
                    }
                } else {
                    if !interaction.snapGuidesX.isEmpty { interaction.snapGuidesX = [] }
                    if !interaction.snapGuidesY.isEmpty { interaction.snapGuidesY = [] }
                }
                interaction.activeNodeDragDelta = CGSize(width: dx, height: dy)
            }
            .onEnded { _ in
                let finalDelta = interaction.activeNodeDragDelta
                let movingSet = selectedNodeIDs.union(interaction.activeGroupChildIDs).union([node.id])
                defer {
                    interaction.activeNodeDragID = nil
                    interaction.activeNodeDragDelta = .zero
                    interaction.activeGroupChildIDs = []
                    interaction.snapGuidesX = []
                    interaction.snapGuidesY = []
                }
                guard !node.isLocked,
                      abs(finalDelta.width) > 0.5 || abs(finalDelta.height) > 0.5 else { return }

                var nextDoc = document
                for idx in nextDoc.nodes.indices where movingSet.contains(nextDoc.nodes[idx].id) && !nextDoc.nodes[idx].isLocked {
                    nextDoc.nodes[idx].frame.x += Double(finalDelta.width)
                    nextDoc.nodes[idx].frame.y += Double(finalDelta.height)
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
        let isResizingThis = interaction.resizingNodeID == node.id
        let isGroupFrame: Bool = if case .groupFrame = node.kind { true } else { false }

        return ZStack {
            // Dedicated Left & Right Side Edge Resize Bars (<|>) for Smart Auto-Layout Group Frames
            if isGroupFrame {
                ForEach([-1, 1], id: \.self) { side in
                    let isActiveEdge = isResizingThis && interaction.resizingSideEdge == side
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
                                if interaction.resizingNodeID == nil {
                                    interaction.resizingNodeID = node.id
                                    interaction.resizingSideEdge = side
                                    interaction.resizeStartFrame = node.frame
                                    interaction.liveGroupReflowChildIDs = Set(enclosedChildIDs(in: node))
                                }
                                guard let start = interaction.resizeStartFrame else { return }
                                let stageDX = Double(value.translation.width / camera.zoom)
                                let stageDY = Double(value.translation.height / camera.zoom)
                                // Project world drag onto the group frame's local rotated X axis
                                let rad = node.rotationDegrees * .pi / 180.0
                                let cosR = cos(rad)
                                let sinR = sin(rad)
                                let localDX = stageDX * cosR + stageDY * sinR

                                let newW = max(minSize.width, start.width + Double(side) * localDX)
                                let deltaW = newW - start.width
                                let localCenterShiftX = Double(side) * deltaW * 0.5
                                let newCenterX = start.midX + localCenterShiftX * cosR
                                let newCenterY = start.midY + localCenterShiftX * sinR
                                let updatedRect = BoardRect(
                                    x: newCenterX - newW * 0.5,
                                    y: newCenterY - start.height * 0.5,
                                    width: newW,
                                    height: start.height
                                )
                                interaction.liveResizeFrame = updatedRect
                                if abs(node.rotationDegrees) < 0.1 {
                                    updateLiveGroupReflow(for: updatedRect)
                                }
                            }
                            .onEnded { _ in
                                commitResizeWithGroupReflow(for: node.id)
                            }
                    )
                    .help("左右拖拽实时缩放并自动重排框内素材")
                }
            }

            ForEach(MoodboardResizeCorner.allCases, id: \.self) { corner in
                let isActiveCorner = isResizingThis && interaction.resizingSideEdge == 0 && interaction.resizingCorner == corner
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
                    if isActiveCorner, let live = interaction.liveResizeFrame {
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
                            if interaction.resizingNodeID == nil {
                                interaction.resizingNodeID = node.id
                                interaction.resizingSideEdge = 0
                                interaction.resizingCorner = corner
                                interaction.resizeStartFrame = node.frame
                                if case .groupFrame = node.kind {
                                    interaction.liveGroupReflowChildIDs = Set(enclosedChildIDs(in: node))
                                } else {
                                    interaction.liveGroupReflowChildIDs = []
                                }
                            }
                            guard let start = interaction.resizeStartFrame else { return }
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
                            interaction.liveResizeFrame = updatedRect
                            if case .groupFrame = node.kind, abs(node.rotationDegrees) < 0.1 {
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

    private func findConnectorTargetNode(at worldPoint: CGPoint, excluding sourceNodeID: UUID, sortedNodes: [BoardNode]) -> BoardNode? {
        let reversed = sortedNodes.reversed()
        return reversed.first(where: { other in
            guard other.id != sourceNodeID else { return false }
            if case .groupFrame = other.kind { return false }
            return ConnectorGeometry.containsPoint(worldPoint, in: other.frame.cgRect, rotationDegrees: other.rotationDegrees)
        }) ?? reversed.first(where: { other in
            other.id != sourceNodeID
                && ConnectorGeometry.containsPoint(worldPoint, in: other.frame.cgRect, rotationDegrees: other.rotationDegrees)
        })
    }

    private func connectorPortsOverlay(
        node: BoardNode,
        worldRect: BoardRect,
        width: CGFloat,
        height: CGFloat,
        currentRotation: Double,
        sortedNodes: [BoardNode]
    ) -> some View {
        let rectCG = worldRect.cgRect
        let anchors: [(ConnectorAnchor, CGSize, CGPoint)] = [
            (.top, CGSize(width: 0, height: -height * 0.5), ConnectorGeometry.anchorPoint(for: rectCG, anchor: .top, towards: rectCG, rotationDegrees: currentRotation)),
            (.bottom, CGSize(width: 0, height: height * 0.5), ConnectorGeometry.anchorPoint(for: rectCG, anchor: .bottom, towards: rectCG, rotationDegrees: currentRotation)),
            (.leading, CGSize(width: -width * 0.5, height: 0), ConnectorGeometry.anchorPoint(for: rectCG, anchor: .leading, towards: rectCG, rotationDegrees: currentRotation)),
            (.trailing, CGSize(width: width * 0.5, height: 0), ConnectorGeometry.anchorPoint(for: rectCG, anchor: .trailing, towards: rectCG, rotationDegrees: currentRotation))
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
                    guard !isAnyLocalModalPresented else {
                        hoverState.clearAll()
                        return
                    }
                    hoverState.setPortHovered(node.id, hovering: hovering)
                }
                .highPriorityGesture(
                    DragGesture(minimumDistance: 2, coordinateSpace: .named("charkle-freeform-stage"))
                        .onChanged { value in
                            if interaction.pendingConnectorSource == nil {
                                interaction.pendingConnectorSource = (node.id, anchor, startWorld)
                            }
                            let cursorWorld = screenToWorld(value.location)
                            interaction.pendingConnectorCursorWorld = cursorWorld
                            let hoverTargetID = findConnectorTargetNode(
                                at: cursorWorld,
                                excluding: node.id,
                                sortedNodes: sortedNodes
                            )?.id
                            if interaction.pendingConnectorHoverTargetID != hoverTargetID {
                                interaction.pendingConnectorHoverTargetID = hoverTargetID
                            }
                        }
                        .onEnded { _ in
                            defer {
                                interaction.pendingConnectorSource = nil
                                interaction.pendingConnectorHoverTargetID = nil
                            }
                            guard let pending = interaction.pendingConnectorSource else { return }
                            let dropCG = interaction.pendingConnectorCursorWorld
                            if let targetNode = findConnectorTargetNode(
                                at: dropCG,
                                excluding: pending.nodeID,
                                sortedNodes: sortedNodes
                            ) {
                                var nextDoc = liveDocRef.document ?? document
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
                                selectedNodeIDs.removeAll()
                                callbacks.onCommitDocument(nextDoc)
                            }
                        }
                )
            }
        }
    }

    private func hitTestConnector(at worldPoint: CGPoint) -> BoardConnector? {
        let hitThreshold = max(10.0, 12.0 / camera.zoom)
        let nodesByID = Dictionary(uniqueKeysWithValues: document.nodes.map { ($0.id, $0) })
        var best: (connector: BoardConnector, distance: CGFloat)?
        for conn in document.connectors {
            guard let fromNode = nodesByID[conn.fromNodeID],
                  let toNode = nodesByID[conn.toNodeID] else { continue }
            let (s, e, c1, c2) = ConnectorGeometry.resolvePathPoints(
                fromRect: fromNode.frame.cgRect,
                fromAnchor: conn.fromAnchor,
                fromNormalizedPoint: conn.fromNormalizedPoint,
                fromRotationDegrees: fromNode.rotationDegrees,
                fromFlipHorizontal: fromNode.flipHorizontal,
                fromFlipVertical: fromNode.flipVertical,
                toRect: toNode.frame.cgRect,
                toAnchor: conn.toAnchor,
                toNormalizedPoint: conn.toNormalizedPoint,
                toRotationDegrees: toNode.rotationDegrees,
                toFlipHorizontal: toNode.flipHorizontal,
                toFlipVertical: toNode.flipVertical,
                style: conn.style
            )
            let dist = ConnectorGeometry.distanceToConnector(point: worldPoint, start: s, end: e, c1: c1, c2: c2, style: conn.style)
            if dist <= hitThreshold {
                if best == nil || dist < best!.distance {
                    best = (conn, dist)
                }
            }
        }
        return best?.connector
    }

    private func markEraseNear(worldPoint: CGPoint) {
        let hitRadius = CGFloat(18.0 / Double(camera.zoom))
        for stroke in document.inkStrokes where !interaction.pendingErasedStrokeIDs.contains(stroke.id) {
            let count = stroke.points.count
            guard count > 0 else { continue }
            var hit = false
            if count == 1 {
                let p0 = stroke.points[0]
                hit = hypot(CGFloat(p0.x) - worldPoint.x, CGFloat(p0.y) - worldPoint.y) <= hitRadius
            } else {
                for i in 0..<(count - 1) {
                    let a = stroke.points[i]
                    let b = stroke.points[i + 1]
                    if ConnectorGeometry.distanceFromPoint(
                        worldPoint,
                        toSegment: CGPoint(x: a.x, y: a.y),
                        CGPoint(x: b.x, y: b.y)
                    ) <= hitRadius {
                        hit = true
                        break
                    }
                }
            }
            if hit {
                interaction.pendingErasedStrokeIDs.insert(stroke.id)
            }
        }

        guard !document.connectors.isEmpty else { return }
        let nodesByID = Dictionary(uniqueKeysWithValues: document.nodes.map { ($0.id, $0) })
        for conn in document.connectors where !interaction.pendingErasedConnectorIDs.contains(conn.id) {
            guard let fromNode = nodesByID[conn.fromNodeID],
                  let toNode = nodesByID[conn.toNodeID] else { continue }
            let (s, e, c1, c2) = ConnectorGeometry.resolvePathPoints(
                fromRect: fromNode.frame.cgRect,
                fromAnchor: conn.fromAnchor,
                fromNormalizedPoint: conn.fromNormalizedPoint,
                fromRotationDegrees: fromNode.rotationDegrees,
                fromFlipHorizontal: fromNode.flipHorizontal,
                fromFlipVertical: fromNode.flipVertical,
                toRect: toNode.frame.cgRect,
                toAnchor: conn.toAnchor,
                toNormalizedPoint: conn.toNormalizedPoint,
                toRotationDegrees: toNode.rotationDegrees,
                toFlipHorizontal: toNode.flipHorizontal,
                toFlipVertical: toNode.flipVertical,
                style: conn.style
            )
            if ConnectorGeometry.distanceToConnector(point: worldPoint, start: s, end: e, c1: c1, c2: c2, style: conn.style) <= hitRadius {
                interaction.pendingErasedConnectorIDs.insert(conn.id)
            }
        }
    }

    private func commitPendingErasures() {
        let erasedStrokes = interaction.pendingErasedStrokeIDs
        let erasedConnectors = interaction.pendingErasedConnectorIDs
        interaction.pendingErasedStrokeIDs = []
        interaction.pendingErasedConnectorIDs = []
        guard !erasedStrokes.isEmpty || !erasedConnectors.isEmpty else { return }
        var nextDoc = document
        nextDoc.inkStrokes.removeAll { erasedStrokes.contains($0.id) }
        nextDoc.connectors.removeAll { erasedConnectors.contains($0.id) }
        if let selConn = selectedConnectorID, erasedConnectors.contains(selConn) {
            selectedConnectorID = nil
        }
        callbacks.onCommitDocument(nextDoc)
    }

    private func computeGroupChildCounts(nodes: [BoardNode]) -> [UUID: Int] {
        var groups: [BoardNode] = []
        for node in nodes {
            if case .groupFrame = node.kind {
                groups.append(node)
            }
        }
        guard !groups.isEmpty else { return [:] }
        var counts: [UUID: Int] = [:]
        counts.reserveCapacity(groups.count)
        for other in nodes where !other.isLocked {
            if case .groupFrame = other.kind { continue }
            let center = CGPoint(x: other.frame.midX, y: other.frame.midY)
            for group in groups where ConnectorGeometry.containsPoint(center, in: group.frame.cgRect, rotationDegrees: group.rotationDegrees) {
                counts[group.id, default: 0] += 1
            }
        }
        return counts
    }

    // MARK: - Shared Node Renderer

    @ViewBuilder
    private func renderNodeBody(node: BoardNode, isAutoMode: Bool, groupChildCounts: [UUID: Int]) -> some View {
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
                isHoverSuspended: isAnyLocalModalPresented,
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
            let expectedBoardID = document.id
            BoardNoteNodeView(
                node: node,
                title: title,
                text: text,
                style: style,
                fontSize: fontSize,
                isSelected: isSelected,
                isHoverSuspended: isAnyLocalModalPresented,
                onUpdate: { newTitle, newText, newStyle, newFontSize in
                    updateNote(boardID: expectedBoardID, nodeID: node.id, title: newTitle, text: newText, style: newStyle, fontSize: newFontSize)
                },
                onDelete: { removeNode(id: node.id) }
            )
        case .groupFrame(let title, let tint):
            let enclosedCount = groupChildCounts[node.id] ?? 0
            let expectedBoardID = document.id
            BoardGroupFrameView(
                title: title,
                tint: tint,
                itemCount: enclosedCount,
                isSelected: isSelected,
                isHoverSuspended: isAnyLocalModalPresented,
                onUpdate: { newTitle, newTint in
                    updateGroupFrame(boardID: expectedBoardID, nodeID: node.id, title: newTitle, tint: newTint)
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

    // MARK: - Floating Liquid Glass Bottom Tool Dock (Responsive Adaptive Tiers)

    private var dockLayoutTier: MoodboardDockLayoutTier {
        MoodboardDockLayoutTier.resolve(forWidth: viewportSize.width)
    }

    private var shouldInlineToolOptions: Bool {
        dockLayoutTier == .wide && viewportSize.width >= 960
    }

    @ViewBuilder
    private var adaptiveBottomDockAndZoomRow: some View {
        let tier = dockLayoutTier
        let zoomPill = FreeformZoomControlsPill(
            camera: camera,
            reduceMotion: reduceMotion,
            compact: tier != .wide,
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

        switch tier {
        case .wide:
            ZStack {
                floatingToolDock(
                    compact: false,
                    showExportLabel: true,
                    includeInlineOptions: shouldInlineToolOptions
                )
                HStack {
                    Spacer(minLength: 0)
                    zoomPill
                }
            }
            .frame(maxWidth: .infinity)

        case .medium:
            HStack(spacing: 10) {
                Spacer(minLength: 0)
                floatingToolDock(
                    compact: viewportSize.width < 680,
                    showExportLabel: viewportSize.width >= 700,
                    includeInlineOptions: false
                )
                Spacer(minLength: 6)
                zoomPill
            }
            .frame(maxWidth: .infinity)

        case .compact:
            VStack(spacing: 8) {
                HStack {
                    Spacer(minLength: 0)
                    zoomPill
                }
                let dockView = floatingToolDock(
                    compact: true,
                    showExportLabel: false,
                    includeInlineOptions: false
                )
                if viewportSize.width < 430 {
                    ScrollView(.horizontal, showsIndicators: false) {
                        dockView
                            .padding(.horizontal, 2)
                    }
                    .frame(maxWidth: max(220, viewportSize.width - 28))
                } else {
                    dockView
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    private var floatingContextualToolOptionsBar: some View {
        HStack(spacing: 6) {
            if activeTool == .pen {
                penToolOptionsContent
            } else if activeTool == .connector {
                connectorToolOptionsContent
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .canvasLiquidGlass(in: Capsule(style: .continuous))
    }

    @ViewBuilder
    private var penToolOptionsContent: some View {
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

    @ViewBuilder
    private var connectorToolOptionsContent: some View {
        HStack(spacing: 6) {
            Picker("", selection: $connectorStyle) {
                Text("曲线").tag(ConnectorStyle.curved)
                Text("折线").tag(ConnectorStyle.elbow)
                Text("直线").tag(ConnectorStyle.straight)
            }
            .pickerStyle(.segmented)
            .frame(width: 120)

            Button {
                connectorDashed.toggle()
            } label: {
                Text("虚线")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(connectorDashed ? Color.accentColor : .secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(
                        connectorDashed ? Color.accentColor.opacity(0.14) : Color.primary.opacity(0.06),
                        in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                    )
            }
            .buttonStyle(.plain)
            .help("切换连线实线 / 虚线样式")
        }
    }

    private func floatingToolDock(
        compact: Bool,
        showExportLabel: Bool,
        includeInlineOptions: Bool
    ) -> some View {
        let itemSpacing: CGFloat = compact ? 4 : 8
        let toolSide: CGFloat = compact ? 26 : 30
        let actionSide: CGFloat = compact ? 25 : 28
        let iconSize: CGFloat = compact ? 12 : 13

        return CanvasGlassContainer(spacing: compact ? 6 : 10) {
            HStack(spacing: itemSpacing) {
                // Freeform Tool Buttons
                ForEach(MoodboardTool.allCases, id: \.self) { tool in
                    let active = activeTool == tool
                    Button {
                        withAnimation(CanvasMotion.accessible(CanvasMotion.settleStrong, reduced: reduceMotion)) {
                            activeTool = tool
                        }
                    } label: {
                        Image(systemName: toolIcon(tool))
                            .font(.system(size: iconSize, weight: active ? .semibold : .regular))
                            .foregroundStyle(active ? Color.accentColor : .primary.opacity(0.84))
                            .frame(width: toolSide, height: toolSide)
                            .background(
                                active ? Color.accentColor.opacity(0.14) : Color.clear,
                                in: RoundedRectangle(cornerRadius: compact ? 8 : 10, style: .continuous)
                            )
                    }
                    .buttonStyle(.plain)
                    .help("\(tool.label) (\(tool.shortcutHint))")
                }

                // Contextual Ink Pen swatch & width controls (inline on wide displays)
                if includeInlineOptions && activeTool == .pen {
                    dockDivider
                    penToolOptionsContent
                }

                // Contextual Connector style toggle (inline on wide displays)
                if includeInlineOptions && activeTool == .connector {
                    dockDivider
                    connectorToolOptionsContent
                }

                dockDivider

                // Insert Nodes (Note / Group Frame / Palette Strip)
                dockIconButton(systemName: "note.text.badge.plus", help: "添加便签卡片", side: actionSide, iconSize: iconSize) {
                    addNoteNode()
                }
                dockIconButton(systemName: "rectangle.dashed", help: "添加区域分组框", side: actionSide, iconSize: iconSize) {
                    addGroupFrameNode()
                }
                dockIconButton(systemName: "paintpalette", help: "添加全板色卡条", side: actionSide, iconSize: iconSize) {
                    addPaletteStripNode()
                }

                dockIconButton(systemName: "sparkles.rectangle.stack", help: "重新整齐排版", side: actionSide, iconSize: iconSize) {
                    tidyFreeformNodes()
                }

                dockDivider

                // Undo / Redo
                dockIconButton(systemName: "arrow.uturn.backward", help: "撤销 (⌘Z)", disabled: !canUndo, side: actionSide, iconSize: iconSize) {
                    callbacks.onUndo()
                }
                dockIconButton(systemName: "arrow.uturn.forward", help: "重做 (⇧⌘Z)", disabled: !canRedo, side: actionSide, iconSize: iconSize) {
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
                    Button {
                        callbacks.onOpenInPureRef()
                    } label: {
                        Label("在 PureRef 中打开当前情绪板", systemImage: "arrow.up.forward.app")
                    }
                    Button {
                        callbacks.onExportPureRef()
                    } label: {
                        Label("导出为 PureRef 场景 (.pur)…", systemImage: "square.grid.2x2")
                    }
                    Divider()
                    Button("复制 2× 高清图（直接 ⌘V 到 Figma / Keynote）") {
                        let opts = currentExportOptions
                        Task {
                            await MoodboardExporter.preloadImages(for: document, loader: loader)
                            callbacks.onCopyExportedImage(opts)
                        }
                    }
                    Button("导出 2× Retina PNG…") {
                        let opts = currentExportOptions
                        Task {
                            await MoodboardExporter.preloadImages(for: document, loader: loader)
                            callbacks.onSaveExportedImage(.png, opts)
                        }
                    }
                    Button("导出 2× Retina JPG…") {
                        let opts = currentExportOptions
                        Task {
                            await MoodboardExporter.preloadImages(for: document, loader: loader)
                            callbacks.onSaveExportedImage(.jpeg, opts)
                        }
                    }
                    Divider()
                    Toggle("包含连线与手绘批注", isOn: $exportIncludeAnnotations)
                    Toggle("包含顶部板内色卡", isOn: $exportIncludePalette)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: compact ? 11.5 : 12.5, weight: .semibold))
                        if showExportLabel {
                            Text("导出")
                                .font(.system(size: 11.5, weight: .semibold))
                        }
                    }
                    .foregroundStyle(.primary)
                    .padding(.horizontal, showExportLabel ? 10 : 7)
                    .padding(.vertical, compact ? 5 : 6)
                    .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: compact ? 8 : 10, style: .continuous))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("导出情绪板或复制到 Figma")
            }
            .padding(compact ? 6 : 8)
            .canvasLiquidGlass(in: RoundedRectangle(cornerRadius: compact ? 16 : 20, style: .continuous))
        }
    }

    private func dockIconButton(
        systemName: String,
        help: String,
        disabled: Bool = false,
        side: CGFloat = 28,
        iconSize: CGFloat = 13,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: iconSize, weight: .medium))
                .foregroundStyle(disabled ? Color.secondary.opacity(0.4) : Color.primary.opacity(0.84))
                .frame(width: side, height: side)
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
                .frame(width: 240)
            Picker("线型", selection: $connectorStyleDraft) {
                Text("曲线").tag(ConnectorStyle.curved)
                Text("折线").tag(ConnectorStyle.elbow)
                Text("直线").tag(ConnectorStyle.straight)
            }
            .pickerStyle(.segmented)
            Toggle("虚线样式", isOn: $connectorDashedDraft)
                .font(.system(size: 12))
            HStack {
                Button("删除连线", role: .destructive) {
                    if let id = editingConnectorLabelID {
                        var nextDoc = document
                        nextDoc.connectors.removeAll { $0.id == id }
                        if selectedConnectorID == id { selectedConnectorID = nil }
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
                        nextDoc.connectors[idx].style = connectorStyleDraft
                        nextDoc.connectors[idx].dashed = connectorDashedDraft
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

    private func enclosedChildIDs(in groupNode: BoardNode) -> [UUID] {
        document.nodes.filter { other in
            guard other.id != groupNode.id, !other.isLocked else { return false }
            if case .groupFrame = other.kind { return false }
            let center = CGPoint(x: other.frame.midX, y: other.frame.midY)
            return ConnectorGeometry.containsPoint(center, in: groupNode.frame.cgRect, rotationDegrees: groupNode.rotationDegrees)
        }.map(\.id)
    }

    private func updateLiveGroupReflow(for groupRect: BoardRect) {
        guard !interaction.liveGroupReflowChildIDs.isEmpty else {
            interaction.liveGroupReflowFrames = [:]
            return
        }
        let idSet = interaction.liveGroupReflowChildIDs
        let children = document.nodes.filter { idSet.contains($0.id) }
        interaction.liveGroupReflowFrames = EditorialLayoutSolver.reflowNodesInsideGroupFrame(
            groupRect: groupRect,
            childNodes: children,
            assetsByID: assetsByID
        )
    }

    private func commitResizeWithGroupReflow(for nodeID: UUID) {
        let finalRect = interaction.liveResizeFrame
        let finalChildren = interaction.liveGroupReflowFrames
        interaction.resizingNodeID = nil
        interaction.resizingCorner = nil
        interaction.resizingSideEdge = 0
        interaction.resizeStartFrame = nil
        interaction.liveResizeFrame = nil
        interaction.liveGroupReflowChildIDs = []
        interaction.liveGroupReflowFrames = [:]

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
        let rawZoom = (document.viewportZoom.isFinite && document.viewportZoom > 0) ? document.viewportZoom : 1.0
        let initialZoom = max(0.2, min(3.0, CGFloat(rawZoom)))
        let initialCenter: CGPoint
        let hasFiniteStoredCenter = document.viewportCenter.x.isFinite && document.viewportCenter.y.isFinite
        if (!hasFiniteStoredCenter || document.viewportCenter == .zero) && !document.nodes.isEmpty {
            let finiteFrames = document.nodes.map(\.frame).filter {
                $0.x.isFinite && $0.y.isFinite && $0.width.isFinite && $0.height.isFinite
            }
            let minX = finiteFrames.map(\.minX).min() ?? 0
            let maxX = finiteFrames.map(\.maxX).max() ?? 1000
            let minY = finiteFrames.map(\.minY).min() ?? 0
            let maxY = finiteFrames.map(\.maxY).max() ?? 600
            initialCenter = CGPoint(x: (minX + maxX) * 0.5, y: min((minY + maxY) * 0.5, 420))
        } else if hasFiniteStoredCenter {
            initialCenter = document.viewportCenter.cgPoint
        } else {
            initialCenter = CGPoint(x: viewportSize.width * 0.5, y: viewportSize.height * 0.5)
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
            if let asset = assetsByID[id], !asset.isTrashed, asset.mediaKind == .image || asset.mediaKind == .webBookmark {
                candidates.append(asset)
            }
        }
        let remainingSlots = max(0, 24 - candidates.count)
        if remainingSlots > 0 {
            // Single-pass O(N) top-K selection avoids an O(N log N) full-library sort inside SwiftUI `body`
            var topRecent: [AssetRecord] = []
            topRecent.reserveCapacity(remainingSlots)
            for asset in assetsByID.values {
                guard asset.id != targetAssetID,
                      !asset.isTrashed,
                      asset.mediaKind == .image || asset.mediaKind == .webBookmark,
                      !seen.contains(asset.id) else { continue }
                if topRecent.count < remainingSlots {
                    let insertIdx = topRecent.firstIndex(where: { asset.updatedAt > $0.updatedAt }) ?? topRecent.endIndex
                    topRecent.insert(asset, at: insertIdx)
                } else if let oldest = topRecent.last, asset.updatedAt > oldest.updatedAt {
                    let insertIdx = topRecent.firstIndex(where: { asset.updatedAt > $0.updatedAt }) ?? topRecent.endIndex
                    topRecent.insert(asset, at: insertIdx)
                    topRecent.removeLast()
                }
            }
            for asset in topRecent where seen.insert(asset.id).inserted {
                candidates.append(asset)
            }
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

    private func updateNote(boardID: UUID, nodeID: UUID, title: String?, text: String, style: NoteStyle, fontSize: Double) {
        // Always read the latest live document from `liveDocRef` and verify board identity so
        // 450ms debounced note flushes never overwrite concurrent drags/Undos or a newly switched board.
        guard var nextDoc = liveDocRef.document, nextDoc.id == boardID else { return }
        guard let idx = nextDoc.nodes.firstIndex(where: { $0.id == nodeID }) else { return }
        nextDoc.nodes[idx].kind = .note(title: title, text: text, style: style, fontSize: fontSize)
        nextDoc.nodes[idx].updatedAt = Date()
        callbacks.onCommitDocument(nextDoc)
    }

    private func updateGroupFrame(boardID: UUID, nodeID: UUID, title: String, tint: GroupTint) {
        guard var nextDoc = liveDocRef.document, nextDoc.id == boardID else { return }
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
            let removableIDs = Set(
                nextDoc.nodes
                    .filter { selectedNodeIDs.contains($0.id) && !$0.isLocked }
                    .map(\.id)
            )
            if !removableIDs.isEmpty {
                nextDoc.nodes.removeAll { removableIDs.contains($0.id) }
                nextDoc.connectors.removeAll { removableIDs.contains($0.fromNodeID) || removableIDs.contains($0.toNodeID) }
                selectedNodeIDs.subtract(removableIDs)
                if let swapID = swappingNodeID, removableIDs.contains(swapID) {
                    callbacks.onSelectSwapTarget(nil)
                }
                changed = true
            }
        }
        if let connID = selectedConnectorID {
            let before = nextDoc.connectors.count
            nextDoc.connectors.removeAll { $0.id == connID }
            selectedConnectorID = nil
            if nextDoc.connectors.count != before {
                changed = true
            }
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
                var plainTextCandidate: String?
                if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier),
                   let str = await loadPlainString(provider: provider) {
                    if let decoded = CharkleDragIdentifiers.decodeAssetIDs(from: str) {
                        internalIDs.append(contentsOf: decoded)
                        continue
                    }
                    plainTextCandidate = str
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
                    } else if WebBookmark.isWebURL(url) {
                        externalInputs.append(.webURL(url, title: nil, notes: nil))
                    }
                    continue
                }
                if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier),
                   let data = await loadData(provider: provider, type: UTType.image) {
                    let ext = Self.sniffImageFileExtension(data)
                    let uniqueSuffix = UUID().uuidString.prefix(8)
                    externalInputs.append(.imageData(data, suggestedName: "BoardDrop-\(uniqueSuffix).\(ext)", sourceURL: nil))
                    continue
                }
                if let text = plainTextCandidate,
                   let webURL = SocialPostURLParser.extractPostURL(from: text)
                    ?? GitHubRepoURLParser.extractRepoURL(from: text)
                    ?? WebURLParser.extractWebURL(from: text) {
                    externalInputs.append(.webURL(webURL, title: nil, notes: nil))
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

    private static func sniffImageFileExtension(_ data: Data) -> String {
        let bytes = [UInt8](data.prefix(12))
        if bytes.count >= 8 && bytes[0] == 0x89 && bytes[1] == 0x50 && bytes[2] == 0x4E && bytes[3] == 0x47 {
            return "png"
        }
        if bytes.count >= 3 && bytes[0] == 0xFF && bytes[1] == 0xD8 && bytes[2] == 0xFF {
            return "jpg"
        }
        if bytes.count >= 6 && bytes[0] == 0x47 && bytes[1] == 0x49 && bytes[2] == 0x46 {
            return "gif"
        }
        if bytes.count >= 12 && bytes[0] == 0x52 && bytes[1] == 0x49 && bytes[2] == 0x46 && bytes[3] == 0x46
            && bytes[8] == 0x57 && bytes[9] == 0x45 && bytes[10] == 0x42 && bytes[11] == 0x50 {
            return "webp"
        }
        if bytes.count >= 4 && ((bytes[0] == 0x49 && bytes[1] == 0x49 && bytes[2] == 0x2A && bytes[3] == 0x00)
            || (bytes[0] == 0x4D && bytes[1] == 0x4D && bytes[2] == 0x00 && bytes[3] == 0x2A)) {
            return "tiff"
        }
        if bytes.count >= 12 && bytes[4] == 0x66 && bytes[5] == 0x74 && bytes[6] == 0x79 && bytes[7] == 0x70 {
            return "heic"
        }
        return "png"
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
    let onKeyCommand: (NSEvent) -> Bool

    func makeNSView(context: Context) -> CanvasInputCatcherView {
        let view = CanvasInputCatcherView()
        view.isSuspended = isSuspended
        view.onPanDelta = onPanDelta
        view.onPanEnded = onPanEnded
        view.onZoomDelta = onZoomDelta
        view.onSpacePanStateChanged = onSpacePanStateChanged
        view.onSpaceQuickTap = onSpaceQuickTap
        view.onKeyCommand = onKeyCommand
        return view
    }

    func updateNSView(_ nsView: CanvasInputCatcherView, context: Context) {
        nsView.isSuspended = isSuspended
        nsView.onPanDelta = onPanDelta
        nsView.onPanEnded = onPanEnded
        nsView.onZoomDelta = onZoomDelta
        nsView.onSpacePanStateChanged = onSpacePanStateChanged
        nsView.onSpaceQuickTap = onSpaceQuickTap
        nsView.onKeyCommand = onKeyCommand
    }

    static func dismantleNSView(_ nsView: CanvasInputCatcherView, coordinator: ()) {
        nsView.teardownMonitors()
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
    var onKeyCommand: ((NSEvent) -> Bool)?

    private var eventMonitor: Any?
    private var resignObserver: NSObjectProtocol?

    private var isMiddleDragging = false
    private var isSpaceHeld = false
    private var isSpaceLeftDragging = false
    private var didDragDuringSpace = false
    private var isWheelZoomMomentumSuppressed = false
    private var spaceDownTimestamp: TimeInterval = 0
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
            .magnify,
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

    /// Avoids hijacking Backspace/Cmd+A/C/X/V when keyboard focus is inside a Sidebar outline/table
    /// or Inspector list rather than the Moodboard canvas.
    private func isResponderInExternalListControl(in window: NSWindow) -> Bool {
        guard let view = window.firstResponder as? NSView else { return false }
        var cursor: NSView? = view
        while let cur = cursor {
            if cur === self { return false }
            if cur is NSOutlineView || cur is NSTableView || cur is NSCollectionView {
                return true
            }
            cursor = cur.superview
        }
        return false
    }

    private func isPointInsideActiveTextView(_ windowPoint: NSPoint, in window: NSWindow) -> Bool {
        guard let textView = window.firstResponder as? NSView,
              textView is NSTextView || textView is NSTextField || textView is NSText else {
            return false
        }
        let targetFrame = textView.enclosingScrollView?.convert(textView.enclosingScrollView?.bounds ?? .zero, to: nil)
            ?? textView.convert(textView.bounds, to: nil)
        return targetFrame.contains(windowPoint)
    }

    private func isPointInsideEmbeddedScrollView(_ windowPoint: NSPoint, in window: NSWindow) -> Bool {
        guard let hitView = window.contentView?.hitTest(windowPoint) else { return false }
        var cursor: NSView? = hitView
        while let cur = cursor {
            if cur === self { return false }
            if let sv = cur as? NSScrollView, sv.documentView != nil {
                // Allow embedded UI scroll views (e.g. compact bottom dock horizontal strip) to scroll natively
                let svRect = sv.convert(sv.bounds, to: nil)
                let selfRect = convert(bounds, to: nil)
                if svRect.height < selfRect.height * 0.45 {
                    return true
                }
            }
            cursor = cur.superview
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
        case .magnify:
            guard window.attachedSheet == nil && NSApp?.modalWindow == nil else { return event }
            let locInView = convert(event.locationInWindow, from: nil)
            guard bounds.contains(locInView) else { return event }
            let swiftUIPoint = CGPoint(x: locInView.x, y: bounds.height - locInView.y)
            if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
                onPanEnded?()
                return nil
            }
            let factor = max(0.75, min(1.35, 1.0 + event.magnification))
            if abs(factor - 1.0) > 0.0002 {
                onZoomDelta?(factor, swiftUIPoint)
            }
            return nil

        case .scrollWheel:
            guard window.attachedSheet == nil && NSApp?.modalWindow == nil else { return event }
            let locInView = convert(event.locationInWindow, from: nil)
            guard bounds.contains(locInView) else { return event }
            // Let scroll wheel scroll inside an actively edited Sticky Note TextEditor or compact HUD strip
            if !event.modifierFlags.contains(.option)
                && !event.modifierFlags.contains(.command)
                && (isPointInsideActiveTextView(event.locationInWindow, in: window)
                    || isPointInsideEmbeddedScrollView(event.locationInWindow, in: window)) {
                return event
            }
            let swiftUIPoint = CGPoint(x: locInView.x, y: bounds.height - locInView.y)
            if event.modifierFlags.contains(.option) || event.modifierFlags.contains(.command) {
                // Ignore trailing trackpad momentum during wheel zoom so zoom halts crisply on finger lift
                if !event.momentumPhase.isEmpty {
                    isWheelZoomMomentumSuppressed = (event.momentumPhase != .ended && event.momentumPhase != .cancelled)
                    if !isWheelZoomMomentumSuppressed {
                        onPanEnded?()
                    }
                    return nil
                }
                isWheelZoomMomentumSuppressed = !(event.phase.isEmpty || event.phase == .ended || event.phase == .cancelled)
                let sensitivity: CGFloat = event.hasPreciseScrollingDeltas ? 0.008 : 0.08
                let factor = max(0.82, min(1.22, 1.0 + event.scrollingDeltaY * sensitivity))
                onZoomDelta?(factor, swiftUIPoint)
            } else {
                // If user released Cmd/Option mid-inertia after wheel zoom, swallow leftover zoom momentum
                // instead of abruptly flinging the canvas into a wild pan.
                if !event.momentumPhase.isEmpty && isWheelZoomMomentumSuppressed {
                    if event.momentumPhase == .ended || event.momentumPhase == .cancelled {
                        isWheelZoomMomentumSuppressed = false
                        onPanEnded?()
                    }
                    return nil
                }
                isWheelZoomMomentumSuppressed = false
                let scale: CGFloat = event.hasPreciseScrollingDeltas ? 1.0 : 12.0
                onPanDelta?(event.scrollingDeltaX * scale, event.scrollingDeltaY * scale)
            }
            let isDiscreteWheel = event.phase.isEmpty && event.momentumPhase.isEmpty
            if event.momentumPhase == .ended || (event.phase == .ended && event.momentumPhase.isEmpty) || isDiscreteWheel {
                onPanEnded?()
            }
            return nil

        case .otherMouseDown:
            // Middle mouse button (buttonNumber == 2) pans from anywhere over the canvas
            guard window.attachedSheet == nil && NSApp?.modalWindow == nil else { return event }
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
            guard window.attachedSheet == nil && NSApp?.modalWindow == nil else { return event }
            guard !isEditingText(in: window), !isResponderInExternalListControl(in: window) else { return event }
            if event.keyCode == 49 { // Spacebar
                guard event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty else { return event }
                if !isSpaceHeld {
                    isSpaceHeld = true
                    didDragDuringSpace = false
                    spaceDownTimestamp = event.timestamp
                    onSpacePanStateChanged?(true)
                    NSCursor.openHand.set()
                }
                return nil
            }
            if event.isARepeat {
                let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
                if event.keyCode == 51 || event.keyCode == 117 || event.keyCode == 53 {
                    return nil
                }
                if let lower = event.charactersIgnoringModifiers?.lowercased(),
                   lower.count == 1,
                   "acxvhper".contains(lower),
                   mods.isEmpty || mods == [.command] || mods == [.shift] {
                    return nil
                }
                return event
            }
            if onKeyCommand?(event) == true {
                return nil
            }
            return event

        case .keyUp:
            guard event.keyCode == 49, isSpaceHeld else { return event }
            let holdDuration = max(0, event.timestamp - spaceDownTimestamp)
            let shouldQuickTap = !didDragDuringSpace && holdDuration < 0.45
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
        let wasSpaceHeld = isSpaceHeld
        isMiddleDragging = false
        isSpaceLeftDragging = false
        if isSpaceHeld {
            isSpaceHeld = false
            didDragDuringSpace = false
            onSpacePanStateChanged?(false)
        }
        if hadPan || wasSpaceHeld {
            NSCursor.arrow.set()
        }
        if hadPan {
            onPanEnded?()
        }
    }

    func teardownMonitors() {
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
            self.eventMonitor = nil
        }
        if let resignObserver {
            NotificationCenter.default.removeObserver(resignObserver)
            self.resignObserver = nil
        }
        isWheelZoomMomentumSuppressed = false
        resetActivePanState()
    }

    isolated deinit {
        teardownMonitors()
    }
}

// MARK: - Isolated 120fps Freeform Camera, Interaction, Hover State & GPU-Accelerated Leaf Views

/// Non-observable reference box keeping the latest `MoodboardDocument` available to debounced child
/// callbacks (e.g. Sticky Note / Group Frame text flushes) so delayed commits never mutate a stale
/// document snapshot or overwrite a newly switched board.
internal final class LiveMoodboardDocumentRef {
    var document: MoodboardDocument?

    func update(_ doc: MoodboardDocument) {
        document = doc
    }
}

internal enum MoodboardResizeCorner: CaseIterable {
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

/// Decoupled `@Observable` live-gesture state so 60-120Hz dragging, resizing, rotating,
/// ink drawing, connector dragging, and marquee selection ONLY invalidate the exact layer
/// that consumes those properties (never `MoodboardCanvasView.body` or toolbars).
@Observable
internal final class FreeformInteractionState {
    var activeNodeDragID: UUID?
    var activeNodeDragDelta: CGSize = .zero
    var activeGroupChildIDs: Set<UUID> = []
    var snapGuidesX: [CGFloat] = []
    var snapGuidesY: [CGFloat] = []

    var resizingNodeID: UUID?
    var resizingCorner: MoodboardResizeCorner?
    var resizeStartFrame: BoardRect?
    var liveResizeFrame: BoardRect?
    var liveGroupReflowChildIDs: Set<UUID> = []
    var liveGroupReflowFrames: [UUID: BoardRect] = [:]
    var resizingSideEdge: Int = 0 // -1 leading, +1 trailing, 0 corner

    var rotatingNodeID: UUID?
    var rotationStartDegrees: Double = 0
    var rotationDragStartAngle: Double = 0
    var liveRotationDegrees: Double?

    var pendingConnectorSource: (nodeID: UUID, anchor: ConnectorAnchor, startWorld: CGPoint)?
    var pendingConnectorCursorWorld: CGPoint = .zero
    var pendingConnectorHoverTargetID: UUID?

    var activeInkPoints: [InkStrokePoint] = []
    var pendingErasedStrokeIDs: Set<UUID> = []
    var pendingErasedConnectorIDs: Set<UUID> = []

    var freeformMarqueeStart: CGPoint?
    var freeformMarqueeCurrent: CGPoint?
    var freeformMarqueeBaseSelection: Set<UUID> = []

    func effectiveFrame(for node: BoardNode, selectedNodeIDs: Set<UUID>) -> BoardRect {
        // Gate `liveResizeFrame` and `liveGroupReflowFrames` behind `resizingNodeID != nil` and
        // `liveGroupReflowChildIDs.contains(node.id)` so 120Hz group resizing ONLY invalidates
        // the resizing group and its enclosed children (zero invalidations for stationary nodes).
        if let resizeID = resizingNodeID {
            if resizeID == node.id, let live = liveResizeFrame {
                return live
            }
            if liveGroupReflowChildIDs.contains(node.id), let reflowed = liveGroupReflowFrames[node.id] {
                return reflowed
            }
        }
        if let dragID = activeNodeDragID,
           !node.isLocked,
           (node.id == dragID || selectedNodeIDs.contains(node.id) || activeGroupChildIDs.contains(node.id)) {
            let delta = activeNodeDragDelta
            return BoardRect(
                x: node.frame.x + Double(delta.width),
                y: node.frame.y + Double(delta.height),
                width: node.frame.width,
                height: node.frame.height
            )
        }
        return node.frame
    }

    func effectiveRotation(for node: BoardNode) -> Double {
        if rotatingNodeID == node.id, let live = liveRotationDegrees {
            return live
        }
        return node.rotationDegrees
    }

    func resetAll() {
        activeNodeDragID = nil
        activeNodeDragDelta = .zero
        activeGroupChildIDs = []
        snapGuidesX = []
        snapGuidesY = []
        resizingNodeID = nil
        resizingCorner = nil
        resizeStartFrame = nil
        liveResizeFrame = nil
        liveGroupReflowChildIDs = []
        liveGroupReflowFrames = [:]
        resizingSideEdge = 0
        rotatingNodeID = nil
        rotationStartDegrees = 0
        rotationDragStartAngle = 0
        liveRotationDegrees = nil
        pendingConnectorSource = nil
        pendingConnectorCursorWorld = .zero
        pendingConnectorHoverTargetID = nil
        activeInkPoints = []
        pendingErasedStrokeIDs = []
        pendingErasedConnectorIDs = []
        freeformMarqueeStart = nil
        freeformMarqueeCurrent = nil
        freeformMarqueeBaseSelection = []
    }
}

/// Decoupled `@Observable` camera state so high-frequency trackpad scroll/zoom ticks ONLY update
/// the GPU dot-grid offset and single container transform, leaving toolbars and node views untouched.
@Observable
internal final class FreeformCameraState {
    var center: CGPoint = CGPoint(x: 540, y: 360)
    var zoom: CGFloat = 1.0

    // Quantized culling buckets — only update when crossing 240pt world boundaries or 0.15 zoom steps
    var cullBucketX: Int = 2
    var cullBucketY: Int = 1
    var cullZoomBucket: Int = 6

    private static let bucketWorldStep: CGFloat = 240
    private static let bucketZoomStep: CGFloat = 0.15
    private static let maxWorldCoord: CGFloat = 1_000_000

    private static func sanitizedPoint(_ point: CGPoint, fallback: CGPoint) -> CGPoint {
        CGPoint(
            x: point.x.isFinite ? max(-maxWorldCoord, min(maxWorldCoord, point.x)) : fallback.x,
            y: point.y.isFinite ? max(-maxWorldCoord, min(maxWorldCoord, point.y)) : fallback.y
        )
    }

    private static func sanitizedZoom(_ value: CGFloat, fallback: CGFloat = 1.0) -> CGFloat {
        guard value.isFinite, value > 0 else { return fallback }
        return max(0.2, min(3.0, value))
    }

    func set(center: CGPoint, zoom: CGFloat) {
        self.center = Self.sanitizedPoint(center, fallback: self.center)
        self.zoom = Self.sanitizedZoom(zoom, fallback: self.zoom)
        refreshCullBucketsIfNeeded()
    }

    func setCenter(_ nextCenter: CGPoint) {
        self.center = Self.sanitizedPoint(nextCenter, fallback: self.center)
        refreshCullBucketsIfNeeded()
    }

    func setZoom(_ nextZoom: CGFloat) {
        self.zoom = Self.sanitizedZoom(nextZoom, fallback: self.zoom)
        refreshCullBucketsIfNeeded()
    }

    func panBy(screenDX: CGFloat, screenDY: CGFloat) {
        guard screenDX.isFinite, screenDY.isFinite, screenDX != 0 || screenDY != 0 else { return }
        setCenter(CGPoint(
            x: center.x - screenDX / zoom,
            y: center.y - screenDY / zoom
        ))
    }

    func applyZoom(factor: CGFloat, anchorScreenPoint: CGPoint, viewportSize: CGSize) {
        guard factor.isFinite, factor > 0, anchorScreenPoint.x.isFinite, anchorScreenPoint.y.isFinite else { return }
        let worldBefore = screenToWorld(anchorScreenPoint, viewportSize: viewportSize)
        let nextZoom = Self.sanitizedZoom(zoom * factor, fallback: zoom)
        zoom = nextZoom
        let worldAfter = screenToWorld(anchorScreenPoint, viewportSize: viewportSize)
        setCenter(CGPoint(
            x: center.x + (worldBefore.x - worldAfter.x),
            y: center.y + (worldBefore.y - worldAfter.y)
        ))
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
        let safeX = center.x.isFinite ? max(-Self.maxWorldCoord, min(Self.maxWorldCoord, center.x)) : 0
        let safeY = center.y.isFinite ? max(-Self.maxWorldCoord, min(Self.maxWorldCoord, center.y)) : 0
        let safeZ = Self.sanitizedZoom(zoom)
        let bx = Int(floor(safeX / Self.bucketWorldStep))
        let by = Int(floor(safeY / Self.bucketWorldStep))
        let bz = max(1, Int(floor(safeZ / Self.bucketZoomStep)))
        if bx != cullBucketX { cullBucketX = bx }
        if by != cullBucketY { cullBucketY = by }
        if bz != cullZoomBucket { cullZoomBucket = bz }
    }
}

/// Decoupled hover + active-panning tracker so cursor crossing cards during trackpad glide
/// never invalidates `MoodboardCanvasView` or triggers connector-port flicker.
@Observable
internal final class FreeformHoverState {
    var hoveredNodeID: UUID?
    var hoveredPortNodeID: UUID?
    var isActivelyPanning: Bool = false
    var isSuspended: Bool = false

    @ObservationIgnored private var panIdleTask: Task<Void, Never>?

    var effectiveHoveredNodeID: UUID? {
        if isSuspended || isActivelyPanning { return nil }
        return hoveredPortNodeID ?? hoveredNodeID
    }

    func setSuspended(_ suspended: Bool) {
        if isSuspended != suspended {
            isSuspended = suspended
        }
        if suspended {
            clearAll()
        }
    }

    func clearAll() {
        if hoveredNodeID != nil { hoveredNodeID = nil }
        if hoveredPortNodeID != nil { hoveredPortNodeID = nil }
    }

    func setNodeHovered(_ id: UUID, hovering: Bool) {
        guard !isSuspended else {
            clearAll()
            return
        }
        if hovering {
            if hoveredNodeID != id { hoveredNodeID = id }
        } else if hoveredNodeID == id {
            hoveredNodeID = nil
        }
    }

    func setPortHovered(_ id: UUID, hovering: Bool) {
        guard !isSuspended else {
            clearAll()
            return
        }
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
    private final class TileBox {
        let image: CGImage
        init(_ image: CGImage) { self.image = image }
    }

    static let shared = DotGridTileCache()
    private let cache: NSCache<NSNumber, TileBox> = {
        let c = NSCache<NSNumber, TileBox>()
        c.countLimit = 64
        c.totalCostLimit = 4 * 1024 * 1024
        return c
    }()

    private init() {}

    func tile(step: CGFloat, isDark: Bool, isDimmed: Bool, dotRadius: CGFloat) -> CGImage? {
        let stepKey = Int((step * 2).rounded()) & 0xFFFF
        let radiusKey = Int((dotRadius * 10).rounded()) & 0xFF
        let flags = (isDark ? 1 : 0) | (isDimmed ? 2 : 0)
        let packedKey = NSNumber(value: (stepKey << 10) | (radiusKey << 2) | flags)
        if let existing = cache.object(forKey: packedKey) {
            return existing.image
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
        let cost = max(1, max(img.bytesPerRow * img.height, img.width * img.height * 4))
        cache.setObject(TileBox(img), forKey: packedKey, cost: cost)
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
            // Quantize to 2pt buckets so smooth zoom gestures maintain ~100% DotGridTileCache hit rate
            return max(16, min(64, ((worldStep * zoom) / 2).rounded() * 2))
        }()
        let dotRadius: CGFloat = zoom < 0.7 ? 0.9 : (zoom < 1.3 ? 1.15 : 1.4)

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

/// Per-node transform wrapper: isolates 120Hz drag/resize/rotate `@Observable` dependencies
/// strictly to the moving node(s), so stationary nodes and `FreeformWorldNodesLayer` do ZERO
/// work during high-frequency gestures.
private struct FreeformNodeTransformShell<Content: View>: View {
    let node: BoardNode
    let interaction: FreeformInteractionState
    let selectedNodeIDs: Set<UUID>
    let allowNodeHitTesting: Bool
    let onHoverChanged: (UUID, Bool) -> Void
    let content: Content

    var body: some View {
        let worldRect = interaction.effectiveFrame(for: node, selectedNodeIDs: selectedNodeIDs)
        let worldW = max(24, CGFloat(worldRect.width))
        let worldH = max(24, CGFloat(worldRect.height))
        let rot = interaction.effectiveRotation(for: node)

        content
            .frame(width: worldW, height: worldH)
            .onHover { hovering in
                onHoverChanged(node.id, hovering)
            }
            .allowsHitTesting(allowNodeHitTesting)
            .rotationEffect(.degrees(rot))
            .position(x: CGFloat(worldRect.midX), y: CGFloat(worldRect.midY))
    }
}

/// Static world-space node stage: NEVER reads continuous `camera.center` / `camera.zoom`
/// or per-tick `interaction.activeNodeDragDelta` / `liveResizeFrame` / `liveRotationDegrees`.
private struct FreeformWorldNodesLayer<NodeView: View>: View {
    let camera: FreeformCameraState
    let interaction: FreeformInteractionState
    let viewportSize: CGSize
    let sortedNodes: [BoardNode]
    let selectedNodeIDs: Set<UUID>
    let allowNodeHitTesting: Bool
    let onHoverChanged: (UUID, Bool) -> Void
    @ViewBuilder let nodeBuilder: (BoardNode) -> NodeView

    var body: some View {
        let visibleNodes: [BoardNode] = {
            if sortedNodes.count <= 12 {
                return sortedNodes
            }
            let visibleWorld = camera.bucketedVisibleWorldRect(viewportSize: viewportSize, overscan: 600)
            let dragID = interaction.activeNodeDragID
            let resizeID = interaction.resizingNodeID
            let rotateID = interaction.rotatingNodeID
            return sortedNodes.filter { node in
                node.frame.cgRect.intersects(visibleWorld)
                    || selectedNodeIDs.contains(node.id)
                    || node.id == dragID
                    || node.id == resizeID
                    || node.id == rotateID
            }
        }()

        ZStack(alignment: .topLeading) {
            Color.clear
                .frame(width: viewportSize.width, height: viewportSize.height)
                .allowsHitTesting(false)

            ForEach(visibleNodes) { node in
                FreeformNodeTransformShell(
                    node: node,
                    interaction: interaction,
                    selectedNodeIDs: selectedNodeIDs,
                    allowNodeHitTesting: allowNodeHitTesting,
                    onHoverChanged: onHoverChanged,
                    content: nodeBuilder(node)
                )
            }
        }
    }
}

/// Screen-space constant-size handles for ONLY visible selected/hovered nodes (culled in connector mode).
private struct FreeformSelectionHandlesLayer<HandleContent: View>: View {
    let camera: FreeformCameraState
    let hoverState: FreeformHoverState
    let interaction: FreeformInteractionState
    let viewportSize: CGSize
    let sortedNodes: [BoardNode]
    let selectedNodeIDs: Set<UUID>
    let activeTool: MoodboardTool
    let isSpaceKeyPanning: Bool
    @ViewBuilder let overlayBuilder: (BoardNode, BoardRect, CGPoint, CGFloat, CGFloat, Double, Bool, Bool) -> HandleContent

    var body: some View {
        if activeTool == .pen || activeTool == .eraser || activeTool == .pan || isSpaceKeyPanning {
            EmptyView()
        } else {
            let hovered = hoverState.effectiveHoveredNodeID
            let activeConnectorNodeID = interaction.pendingConnectorSource?.nodeID
            let activeResizeNodeID = interaction.resizingNodeID
            let activeRotateNodeID = interaction.rotatingNodeID
            let activeNodes: [BoardNode] = {
                if activeTool == .connector {
                    let visibleWorld = camera.bucketedVisibleWorldRect(viewportSize: viewportSize, overscan: 240)
                    return sortedNodes.filter { node in
                        let rect = interaction.effectiveFrame(for: node, selectedNodeIDs: selectedNodeIDs)
                        return rect.cgRect.intersects(visibleWorld)
                            || selectedNodeIDs.contains(node.id)
                            || node.id == activeConnectorNodeID
                    }
                }
                if selectedNodeIDs.isEmpty
                    && hovered == nil
                    && activeConnectorNodeID == nil
                    && activeResizeNodeID == nil
                    && activeRotateNodeID == nil {
                    return []
                }
                // Always keep an actively dragged connector-source / resizing / rotating node mounted
                // so leaving hover bounds mid-drag NEVER destroys the gesture host and strands a ghost line.
                return sortedNodes.filter { node in
                    selectedNodeIDs.contains(node.id)
                        || node.id == hovered
                        || node.id == activeConnectorNodeID
                        || node.id == activeResizeNodeID
                        || node.id == activeRotateNodeID
                }
            }()

            if !activeNodes.isEmpty {
                let zoom = camera.zoom
                ZStack {
                    ForEach(activeNodes) { node in
                        let worldRect = interaction.effectiveFrame(for: node, selectedNodeIDs: selectedNodeIDs)
                        let screenCenter = camera.worldToScreen(CGPoint(x: worldRect.midX, y: worldRect.midY), viewportSize: viewportSize)
                        let screenW = max(24, CGFloat(worldRect.width) * zoom)
                        let screenH = max(24, CGFloat(worldRect.height) * zoom)
                        let isSelected = selectedNodeIDs.contains(node.id)
                        let isHovered = hovered == node.id
                        let rot = interaction.effectiveRotation(for: node)

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

/// Vector overlay for snap guides, connectors, and ink strokes — isolated from MoodboardCanvasView.body.
private struct FreeformVectorOverlay: View {
    let camera: FreeformCameraState
    let interaction: FreeformInteractionState
    let viewportSize: CGSize
    let nodesByID: [UUID: BoardNode]
    let selectedNodeIDs: Set<UUID>
    let connectors: [BoardConnector]
    let inkStrokes: [InkStroke]
    let inkColorHex: String
    let inkWidth: Double
    let selectedConnectorID: UUID?

    var body: some View {
        let activeInkPoints = interaction.activeInkPoints
        let pendingConnectorSource = interaction.pendingConnectorSource
        let pendingConnectorCursorWorld = interaction.pendingConnectorCursorWorld
        let pendingConnectorHoverTargetID = interaction.pendingConnectorHoverTargetID
        let snapGuidesX = interaction.snapGuidesX
        let snapGuidesY = interaction.snapGuidesY
        let erasedStrokes = interaction.pendingErasedStrokeIDs
        let erasedConnectors = interaction.pendingErasedConnectorIDs

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
                for connector in connectors where !erasedConnectors.contains(connector.id) {
                    guard let fromNode = nodesByID[connector.fromNodeID],
                          let toNode = nodesByID[connector.toNodeID] else { continue }
                    let fromR = interaction.effectiveFrame(for: fromNode, selectedNodeIDs: selectedNodeIDs)
                    let toR = interaction.effectiveFrame(for: toNode, selectedNodeIDs: selectedNodeIDs)
                    let bounds = fromR.cgRect.union(toR.cgRect).insetBy(dx: -120, dy: -120)
                    guard bounds.intersects(visibleWorld) else { continue }

                    let (startW, endW, c1W, c2W) = ConnectorGeometry.resolvePathPoints(
                        fromRect: fromR.cgRect,
                        fromAnchor: connector.fromAnchor,
                        fromNormalizedPoint: connector.fromNormalizedPoint,
                        fromRotationDegrees: interaction.effectiveRotation(for: fromNode),
                        fromFlipHorizontal: fromNode.flipHorizontal,
                        fromFlipVertical: fromNode.flipVertical,
                        toRect: toR.cgRect,
                        toAnchor: connector.toAnchor,
                        toNormalizedPoint: connector.toNormalizedPoint,
                        toRotationDegrees: interaction.effectiveRotation(for: toNode),
                        toFlipHorizontal: toNode.flipHorizontal,
                        toFlipVertical: toNode.flipVertical,
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
                    if let targetID = pendingConnectorHoverTargetID, let targetNode = nodesByID[targetID] {
                        let targetFrame = interaction.effectiveFrame(for: targetNode, selectedNodeIDs: selectedNodeIDs)
                        let topLeft = toScreen(CGPoint(x: targetFrame.minX, y: targetFrame.minY))
                        let targetScreenRect = CGRect(
                            x: topLeft.x,
                            y: topLeft.y,
                            width: CGFloat(targetFrame.width) * zoom,
                            height: CGFloat(targetFrame.height) * zoom
                        ).insetBy(dx: -3, dy: -3)
                        let highlightPath = Path(roundedRect: targetScreenRect, cornerRadius: max(8, 14 * zoom), style: .continuous)
                        context.stroke(
                            highlightPath,
                            with: .color(Color.accentColor.opacity(0.85)),
                            style: StrokeStyle(lineWidth: 2.2)
                        )
                    }
                    let s = toScreen(pending.startWorld)
                    let e = toScreen(pendingConnectorCursorWorld)
                    let dist = max(36, hypot(e.x - s.x, e.y - s.y) * 0.42)
                    let c1: CGPoint = switch pending.anchor {
                    case .top: CGPoint(x: s.x, y: s.y - dist)
                    case .bottom: CGPoint(x: s.x, y: s.y + dist)
                    case .leading: CGPoint(x: s.x - dist, y: s.y)
                    case .trailing: CGPoint(x: s.x + dist, y: s.y)
                    case .auto: CGPoint(x: s.x + (e.x - s.x) * 0.35, y: s.y)
                    }
                    let c2 = CGPoint(x: e.x - (e.x - c1.x) * 0.35, y: e.y - (e.y - c1.y) * 0.35)
                    var p = Path()
                    p.move(to: s)
                    p.addCurve(to: e, control1: c1, control2: c2)
                    context.stroke(
                        p,
                        with: .color(Color.accentColor.opacity(0.85)),
                        style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [5, 4])
                    )
                }

                // 3. Ink strokes (zero per-frame array allocations: streams directly into Path)
                for stroke in inkStrokes where !erasedStrokes.contains(stroke.id) {
                    Self.drawInkPoints(
                        stroke.points,
                        colorHex: stroke.colorHex,
                        lineWidth: stroke.lineWidth,
                        opacity: stroke.opacity,
                        visibleWorld: visibleWorld,
                        center: center,
                        zoom: zoom,
                        canvasSize: size,
                        into: &context
                    )
                }
                if activeInkPoints.count >= 2 {
                    Self.drawInkPoints(
                        activeInkPoints,
                        colorHex: inkColorHex,
                        lineWidth: inkWidth,
                        opacity: 0.92,
                        visibleWorld: visibleWorld,
                        center: center,
                        zoom: zoom,
                        canvasSize: size,
                        into: &context
                    )
                }
            }
            .allowsHitTesting(false)
        }
    }

    private static func drawInkPoints(
        _ points: [InkStrokePoint],
        colorHex: String,
        lineWidth: Double,
        opacity: Double,
        visibleWorld: CGRect,
        center: CGPoint,
        zoom: CGFloat,
        canvasSize: CGSize,
        into context: inout GraphicsContext
    ) {
        guard points.count >= 2 else { return }
        var minX = Double.greatestFiniteMagnitude
        var minY = Double.greatestFiniteMagnitude
        var maxX = -Double.greatestFiniteMagnitude
        var maxY = -Double.greatestFiniteMagnitude
        for pt in points where pt.x.isFinite && pt.y.isFinite {
            if pt.x < minX { minX = pt.x }
            if pt.y < minY { minY = pt.y }
            if pt.x > maxX { maxX = pt.x }
            if pt.y > maxY { maxY = pt.y }
        }
        guard minX.isFinite, minY.isFinite, maxX.isFinite, maxY.isFinite else { return }
        let box = CGRect(x: minX - 12, y: minY - 12, width: (maxX - minX) + 24, height: (maxY - minY) + 24)
        guard box.intersects(visibleWorld) else { return }

        let halfW = canvasSize.width * 0.5
        let halfH = canvasSize.height * 0.5
        var path = Path()
        var prevPt: CGPoint?
        var validCount = 0
        for raw in points where raw.x.isFinite && raw.y.isFinite {
            let screenPt = CGPoint(
                x: (CGFloat(raw.x) - center.x) * zoom + halfW,
                y: (CGFloat(raw.y) - center.y) * zoom + halfH
            )
            if validCount == 0 {
                path.move(to: screenPt)
            } else if validCount >= 2, let prev = prevPt {
                let mid = CGPoint(x: (prev.x + screenPt.x) * 0.5, y: (prev.y + screenPt.y) * 0.5)
                path.addQuadCurve(to: mid, control: prev)
            }
            prevPt = screenPt
            validCount += 1
        }
        guard validCount >= 2, let lastPt = prevPt else { return }
        path.addLine(to: lastPt)

        context.stroke(
            path,
            with: .color(Color(charkleHex: colorHex).opacity(opacity)),
            style: StrokeStyle(
                lineWidth: max(1.2, CGFloat(lineWidth) * zoom),
                lineCap: .round,
                lineJoin: .round
            )
        )
    }
}

private struct FreeformConnectorLabelsLayer: View {
    @Environment(\.colorScheme) private var colorScheme
    let camera: FreeformCameraState
    let interaction: FreeformInteractionState
    let viewportSize: CGSize
    let nodesByID: [UUID: BoardNode]
    let selectedNodeIDs: Set<UUID>
    let connectors: [BoardConnector]
    let selectedConnectorID: UUID?
    let activeTool: MoodboardTool
    let onSelectConnector: (BoardConnector) -> Void

    var body: some View {
        let erasedConnectors = interaction.pendingErasedConnectorIDs
        let hasAnyRenderableBadge = activeTool == .connector
            || selectedConnectorID != nil
            || connectors.contains { conn in
                !erasedConnectors.contains(conn.id) && !(conn.label ?? "").isEmpty
            }

        if hasAnyRenderableBadge {
            connectorLabelsContent(erasedConnectors: erasedConnectors)
        }
    }

    @ViewBuilder
    private func connectorLabelsContent(erasedConnectors: Set<UUID>) -> some View {
        let visibleWorld = camera.visibleWorldRect(viewportSize: viewportSize, overscan: 120)
        let zoom = camera.zoom

        ZStack {
            ForEach(connectors) { connector in
                connectorBadgeView(
                    connector: connector,
                    erasedConnectors: erasedConnectors,
                    visibleWorld: visibleWorld,
                    zoom: zoom
                )
            }
        }
    }

    @ViewBuilder
    private func connectorBadgeView(
        connector: BoardConnector,
        erasedConnectors: Set<UUID>,
        visibleWorld: CGRect,
        zoom: CGFloat
    ) -> some View {
        let isSel = selectedConnectorID == connector.id
        let hasLabel = !(connector.label ?? "").isEmpty
        if !erasedConnectors.contains(connector.id),
           (hasLabel || isSel || activeTool == .connector),
           let fromNode = nodesByID[connector.fromNodeID],
           let toNode = nodesByID[connector.toNodeID] {
            let fromR = interaction.effectiveFrame(for: fromNode, selectedNodeIDs: selectedNodeIDs)
            let toR = interaction.effectiveFrame(for: toNode, selectedNodeIDs: selectedNodeIDs)
            let (start, end, c1, c2) = ConnectorGeometry.resolvePathPoints(
                fromRect: fromR.cgRect,
                fromAnchor: connector.fromAnchor,
                fromNormalizedPoint: connector.fromNormalizedPoint,
                fromRotationDegrees: interaction.effectiveRotation(for: fromNode),
                fromFlipHorizontal: fromNode.flipHorizontal,
                fromFlipVertical: fromNode.flipVertical,
                toRect: toR.cgRect,
                toAnchor: connector.toAnchor,
                toNormalizedPoint: connector.toNormalizedPoint,
                toRotationDegrees: interaction.effectiveRotation(for: toNode),
                toFlipHorizontal: toNode.flipHorizontal,
                toFlipVertical: toNode.flipVertical,
                style: connector.style
            )
            let midWorld = ConnectorGeometry.midpoint(start: start, end: end, c1: c1, c2: c2, style: connector.style)
            if visibleWorld.contains(midWorld) {
                let midScreen = camera.worldToScreen(midWorld, viewportSize: viewportSize)
                Button {
                    onSelectConnector(connector)
                } label: {
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
                    } else {
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
                .buttonStyle(.plain)
                .position(midScreen)
                .allowsHitTesting(activeTool == .select || activeTool == .connector)
            }
        }
    }
}

/// Isolated marquee selection box so dragging a selection rectangle never re-evaluates MoodboardCanvasView.body.
private struct FreeformMarqueeOverlay: View {
    let interaction: FreeformInteractionState

    var body: some View {
        if let s = interaction.freeformMarqueeStart, let c = interaction.freeformMarqueeCurrent {
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
}

/// Responsive layout tiers for the Moodboard bottom dock and zoom pill.
public nonisolated enum MoodboardDockLayoutTier: Equatable, Sendable {
    case wide
    case medium
    case compact

    public static func resolve(forWidth width: CGFloat) -> MoodboardDockLayoutTier {
        if width >= 820 { return .wide }
        if width >= 560 { return .medium }
        return .compact
    }
}

private struct FreeformZoomControlsPill: View {
    @Environment(\.colorScheme) private var colorScheme
    let camera: FreeformCameraState
    let reduceMotion: Bool
    var compact: Bool = false
    let onZoomStep: (CGFloat) -> Void
    let onResetZoom: () -> Void
    let onFitBoard: () -> Void

    var body: some View {
        let btnSide: CGFloat = compact ? 22 : 24
        HStack(spacing: compact ? 2 : 4) {
            Button {
                onZoomStep(0.82)
            } label: {
                Image(systemName: "minus")
                    .font(.system(size: compact ? 10 : 11, weight: .semibold))
                    .frame(width: btnSide, height: btnSide)
            }
            .buttonStyle(.plain)
            .help("缩小画布")

            Button {
                onResetZoom()
            } label: {
                Text("\(Int((camera.zoom * 100).rounded()))%")
                    .font(.system(size: compact ? 10.5 : 11, weight: .semibold, design: .monospaced))
                    .monospacedDigit()
                    .frame(minWidth: compact ? 36 : 42)
            }
            .buttonStyle(.plain)
            .help("重置为 100%")

            Button {
                onZoomStep(1.22)
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: compact ? 10 : 11, weight: .semibold))
                    .frame(width: btnSide, height: btnSide)
            }
            .buttonStyle(.plain)
            .help("放大画布")

            Rectangle()
                .fill(CanvasSurface.hairline(for: colorScheme))
                .frame(width: 1, height: compact ? 12 : 14)

            Button {
                onFitBoard()
            } label: {
                Image(systemName: "arrow.up.left.and.down.right.magnifyingglass")
                    .font(.system(size: compact ? 10 : 11, weight: .semibold))
                    .frame(width: btnSide, height: btnSide)
            }
            .buttonStyle(.plain)
            .help("适配全板视图")
        }
        .padding(.horizontal, compact ? 6 : 8)
        .padding(.vertical, compact ? 4 : 5)
        .canvasLiquidGlass(in: Capsule(style: .continuous))
    }
}
