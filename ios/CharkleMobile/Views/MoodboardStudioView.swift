import CharkleCore
import SwiftUI
import UIKit

/// Interactive Moodboard Studio for iPadOS & iOS:
/// - 1:1 compatible with desktop `MoodboardDocument` (`/.charkle/boards/<UUID>.json`).
/// - Supports both **自由画布** (pan, pinch zoom, drag nodes, corner resize, rotate, flip, lock, z-order)
///   and **自动排版** (`呼吸均衡` / `杂志主次` / `紧凑拼贴`) with seamless mode switching.
/// - Renders asset cards (with crop/rotation/flip), 5-theme sticky notes, 6-tint group frames,
///   extracted palette strips, connectors, and freehand finger / Apple Pencil ink strokes.
/// - High-resolution PNG export via `CharkleCore.BoardImageRenderer`.
struct MoodboardStudioView: View {
    @Bindable var store: MobileAppStore
    let boardID: UUID
    let onOpenAsset: (AssetRecord) -> Void
    let onRevealAssetInLibrary: (UUID) -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var document: MoodboardDocument?
    @State private var assetsByID: [UUID: AssetRecord] = [:]
    @State private var selectedNodeID: UUID?
    @State private var canvasOffset: CGSize = .zero
    @State private var lastCanvasOffset: CGSize = .zero
    @State private var canvasZoom: CGFloat = 1.0
    @State private var lastCanvasZoom: CGFloat = 1.0
    @State private var isDrawingInk: Bool = false
    @State private var activeInkColorHex: String = "#2A60E0"
    @State private var activeStrokePoints: [InkStrokePoint] = []
    @State private var isAddAssetsSheetPresented = false
    @State private var isNoteEditorPresented = false
    @State private var editingNoteNodeID: UUID?
    @State private var noteTitleDraft = ""
    @State private var noteTextDraft = ""
    @State private var noteStyleDraft: NoteStyle = .warm
    @State private var isGroupCreatorPresented = false
    @State private var groupTitleDraft = ""
    @State private var groupTintDraft: GroupTint = .sage
    @State private var exportedImageURL: URL?
    @State private var isExporting = false
    @State private var saveDebounceTask: Task<Void, Never>?
    @State private var hasPendingSave: Bool = false
    @State private var dragStartFrames: [UUID: BoardRect] = [:]
    @State private var activeDraggingNodeID: UUID? = nil
    @State private var didPushGestureUndo: Bool = false
    @State private var isPinchingCanvas: Bool = false
    @State private var pinchStartZoom: CGFloat = 1.0
    @State private var pinchStartOffset: CGSize = .zero
    @State private var pinchStartLocation: CGPoint? = nil
    @State private var undoStack: [MoodboardDocument] = []
    @State private var redoStack: [MoodboardDocument] = []
    @State private var viewportSize: CGSize = .zero
    @State private var lastFittedBoardID: UUID? = nil

    private let maxUndoHistoryCount = 30

    private enum ResizeCorner: CaseIterable {
        case topLeading, topTrailing, bottomLeading, bottomTrailing

        var alignment: Alignment {
            switch self {
            case .topLeading: .topLeading
            case .topTrailing: .topTrailing
            case .bottomLeading: .bottomLeading
            case .bottomTrailing: .bottomTrailing
            }
        }

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

    private let inkColors = ["#2A60E0", "#E05A47", "#249A4B", "#C98212", "#18191C", "#FFFFFF"]

    var body: some View {
        ZStack(alignment: .bottom) {
            MobileTheme.galleryGround(for: colorScheme)
                .ignoresSafeArea()

            if let doc = document {
                VStack(spacing: 0) {
                    if !doc.extractedPalette.isEmpty {
                        boardPaletteRibbon(doc.extractedPalette)
                    }

                    if case .autoEditorial(let config) = doc.mode {
                        autoEditorialCanvas(doc: doc, config: config)
                    } else {
                        freeformInteractiveCanvas(doc: doc)
                    }
                }

                VStack(spacing: 8) {
                    if let selID = selectedNodeID,
                       let node = doc.nodes.first(where: { $0.id == selID }),
                       !isDrawingInk {
                        selectedNodeActionPill(node: node)
                            .transition(.opacity.combined(with: .move(edge: .bottom)))
                    }

                    if isDrawingInk {
                        inkToolStrip
                            .transition(.opacity.combined(with: .move(edge: .bottom)))
                    }

                    moodboardBottomDock(doc: doc)
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 12)
                .animation(MobileMotion.accessible(MobileMotion.settleStrong, reduced: reduceMotion), value: selectedNodeID)
                .animation(MobileMotion.accessible(MobileMotion.settleStrong, reduced: reduceMotion), value: isDrawingInk)
            } else {
                ProgressView("正在加载情绪板…")
                    .font(.system(size: 13.5))
                    .foregroundStyle(MobileTheme.secondaryInk(for: colorScheme))
            }
        }
        .navigationTitle(document?.title ?? "情绪板")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if let doc = document {
                    Menu {
                        Button {
                            toggleLayoutMode(toFreeform: true)
                        } label: {
                            Label("自由画布" + (!doc.mode.isAutoEditorial ? "  ✓" : ""), systemImage: "hand.draw")
                        }
                        Menu("自动排版") {
                            ForEach(EditorialStyle.allCases, id: \.self) { style in
                                Button(style.localizedLabel) {
                                    applyEditorialStyle(style)
                                }
                            }
                        }
                        Divider()
                        Button {
                            Task { await exportHighResPNG() }
                        } label: {
                            Label("导出高清图片", systemImage: "square.and.arrow.up")
                        }
                        Button {
                            Task { await exportPureRefScene() }
                        } label: {
                            Label("导出 PureRef (.pur)", systemImage: "square.grid.2x2")
                        }
                    } label: {
                        if isExporting {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "ellipsis.circle")
                        }
                    }
                }
            }
        }
        .task(id: boardID) {
            await flushPendingSaveAsync()
            undoStack.removeAll()
            redoStack.removeAll()
            selectedNodeID = nil
            lastFittedBoardID = nil
            await loadBoard()
            if viewportSize.width > 10, viewportSize.height > 10 {
                fitCanvasToViewport(viewportSize)
                lastFittedBoardID = boardID
            }
        }
        .onDisappear {
            flushPendingSave()
        }
        .background {
            moodboardKeyboardShortcutsBridge
        }
        .sheet(isPresented: $isAddAssetsSheetPresented) {
            NavigationStack {
                MoodboardAssetPickerSheet(store: store) { selectedIDs in
                    isAddAssetsSheetPresented = false
                    Task { await appendAssetsToBoard(selectedIDs) }
                }
            }
            .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $isNoteEditorPresented) {
            NavigationStack {
                Form {
                    Section("便签内容") {
                        TextField("标题（可选）", text: $noteTitleDraft)
                        TextField("输入灵感批注或文字…", text: $noteTextDraft, axis: .vertical)
                            .lineLimit(3...8)
                    }
                    Section("配色风格") {
                        Picker("便签主题", selection: $noteStyleDraft) {
                            Text("纸白").tag(NoteStyle.paper)
                            Text("墨黑").tag(NoteStyle.ink)
                            Text("暖米").tag(NoteStyle.warm)
                            Text("鼠尾草").tag(NoteStyle.sage)
                            Text("石板蓝").tag(NoteStyle.slate)
                        }
                        .pickerStyle(.segmented)
                    }
                }
                .navigationTitle(editingNoteNodeID == nil ? "新增便签" : "编辑便签")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("取消") { isNoteEditorPresented = false }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("保存") {
                            saveNoteDraft()
                            isNoteEditorPresented = false
                        }
                        .fontWeight(.semibold)
                        .disabled(noteTextDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && noteTitleDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
            .presentationDetents([.medium])
        }
        .sheet(isPresented: $isGroupCreatorPresented) {
            NavigationStack {
                Form {
                    Section("分组框") {
                        TextField("分组标题（如：色彩方向 / 构图参考）", text: $groupTitleDraft)
                        Picker("色系", selection: $groupTintDraft) {
                            Text("中性灰").tag(GroupTint.neutral)
                            Text("砂岩").tag(GroupTint.sand)
                            Text("苔绿").tag(GroupTint.sage)
                            Text("石青").tag(GroupTint.slate)
                            Text("陶土").tag(GroupTint.terracotta)
                            Text("海蓝").tag(GroupTint.ocean)
                        }
                    }
                }
                .navigationTitle("新增分组框")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("取消") { isGroupCreatorPresented = false }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("添加") {
                            addGroupFrame(title: groupTitleDraft.isEmpty ? "新建分组" : groupTitleDraft, tint: groupTintDraft)
                            groupTitleDraft = ""
                            isGroupCreatorPresented = false
                        }
                        .fontWeight(.semibold)
                    }
                }
            }
            .presentationDetents([.medium])
        }
        .sheet(isPresented: Binding(
            get: { exportedImageURL != nil },
            set: { if !$0 { exportedImageURL = nil } }
        )) {
            if let exportedImageURL {
                ActivityShareSheet(items: [exportedImageURL])
            }
        }
    }

    // MARK: - Top Board Palette Ribbon

    private func boardPaletteRibbon(_ colors: [LabColor]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Text("主色板")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(MobileTheme.secondaryInk(for: colorScheme))
                ForEach(colors.prefix(8), id: \.hex) { swatch in
                    Button {
                        UIPasteboard.general.string = swatch.hex
                        MobileHaptics.light()
                        store.showToast("已复制色值 \(swatch.hex)", tone: .info)
                    } label: {
                        HStack(spacing: 5) {
                            Circle()
                                .fill(Color(charkleHex: swatch.hex))
                                .frame(width: 14, height: 14)
                                .overlay(Circle().strokeBorder(MobileTheme.hairline(for: colorScheme), lineWidth: 0.6))
                            Text(swatch.hex)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.primary)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(MobileTheme.surfaceElevated(for: colorScheme), in: Capsule())
                        .overlay(Capsule().strokeBorder(MobileTheme.hairline(for: colorScheme), lineWidth: 0.6))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
        }
        .background(MobileTheme.galleryGround(for: colorScheme))
    }

    // MARK: - Auto Editorial Mode (Balanced / Magazine / Compact)

    private func autoEditorialCanvas(doc: MoodboardDocument, config: AutoLayoutConfig) -> some View {
        GeometryReader { proxy in
            let layout = computeAutoEditorialFrames(nodes: doc.nodes, config: config, width: Double(proxy.size.width))
            ScrollView {
                ZStack(alignment: .topLeading) {
                    Color.clear
                        .frame(width: proxy.size.width, height: max(proxy.size.height, CGFloat(layout.contentHeight)))
                        .contentShape(Rectangle())
                        .onTapGesture { selectedNodeID = nil }

                    ForEach(doc.nodes.sorted(by: { $0.zIndex < $1.zIndex })) { node in
                        if let rect = layout.frames[node.id] {
                            MoodboardNodeTile(
                                node: node,
                                asset: node.referencedAssetID.flatMap { assetsByID[$0] },
                                thumbnails: store.thumbnails,
                                isSelected: selectedNodeID == node.id,
                                onTap: {
                                    selectedNodeID = (selectedNodeID == node.id) ? nil : node.id
                                },
                                onDoubleTap: {
                                    handleNodeDoubleTap(node)
                                }
                            )
                            .frame(width: rect.width, height: rect.height)
                            .rotationEffect(.degrees(node.rotationDegrees))
                            .position(x: rect.x + rect.width * 0.5, y: rect.y + rect.height * 0.5)
                        }
                    }
                }
                .padding(.bottom, 92)
            }
        }
    }

    // MARK: - Freeform Interactive Infinite Canvas (Pan / Pinch / Drag Nodes / Connectors / Ink)

    private func freeformInteractiveCanvas(doc: MoodboardDocument) -> some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                // Subtle dot-grid studio background
                Canvas { context, size in
                    let step = max(18.0, 28.0 * canvasZoom)
                    let offX = canvasOffset.width.truncatingRemainder(dividingBy: step)
                    let offY = canvasOffset.height.truncatingRemainder(dividingBy: step)
                    let dotColor = colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.08)
                    var y = offY
                    while y < size.height {
                        var x = offX
                        while x < size.width {
                            context.fill(Path(ellipseIn: CGRect(x: x, y: y, width: 2, height: 2)), with: .color(dotColor))
                            x += step
                        }
                        y += step
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    selectedNodeID = nil
                }

                // World layer 1: Group frames behind everything
                ZStack(alignment: .topLeading) {
                    ForEach(doc.nodes.filter { if case .groupFrame = $0.kind { return true }; return false }.sorted(by: { $0.zIndex < $1.zIndex })) { node in
                        draggableBoardNode(node)
                    }
                }
                .scaleEffect(canvasZoom, anchor: .topLeading)
                .offset(canvasOffset)

                // World layer 2: Unclipped viewport-space Connectors
                Canvas { context, _ in
                    context.translateBy(x: canvasOffset.width, y: canvasOffset.height)
                    context.scaleBy(x: canvasZoom, y: canvasZoom)
                    drawConnectors(doc.connectors, nodes: doc.nodes, in: &context)
                }
                .allowsHitTesting(false)

                // World layer 3: Asset cards, Notes, Palette strips
                ZStack(alignment: .topLeading) {
                    ForEach(doc.nodes.filter { if case .groupFrame = $0.kind { return false }; return true }.sorted(by: { $0.zIndex < $1.zIndex })) { node in
                        draggableBoardNode(node)
                    }
                }
                .scaleEffect(canvasZoom, anchor: .topLeading)
                .offset(canvasOffset)

                // World layer 4: Unclipped viewport-space persisted + live Ink Strokes
                Canvas { context, _ in
                    context.translateBy(x: canvasOffset.width, y: canvasOffset.height)
                    context.scaleBy(x: canvasZoom, y: canvasZoom)
                    for stroke in doc.inkStrokes {
                        drawInkStroke(stroke.points, colorHex: stroke.colorHex, lineWidth: stroke.lineWidth, opacity: stroke.opacity, in: &context)
                    }
                    if activeStrokePoints.count >= 2 {
                        drawInkStroke(activeStrokePoints, colorHex: activeInkColorHex, lineWidth: 3.5, opacity: 0.92, in: &context)
                    }
                }
                .allowsHitTesting(false)
            }
            .coordinateSpace(name: "moodboardViewport")
            .clipped()
            .contentShape(Rectangle())
            .gesture(isDrawingInk ? nil : canvasPanGesture)
            .simultaneousGesture(canvasPinchGesture)
            .highPriorityGesture(isDrawingInk ? inkDrawGesture : nil)
            .onAppear {
                viewportSize = proxy.size
                if lastFittedBoardID != doc.id {
                    fitCanvasToViewport(proxy.size)
                    lastFittedBoardID = doc.id
                }
            }
            .onChange(of: proxy.size) { _, newSize in
                viewportSize = newSize
                if lastFittedBoardID != doc.id, newSize.width > 10, newSize.height > 10 {
                    fitCanvasToViewport(newSize)
                    lastFittedBoardID = doc.id
                }
            }
            .onChange(of: doc.id) { _, newID in
                if lastFittedBoardID != newID, viewportSize.width > 10, viewportSize.height > 10 {
                    fitCanvasToViewport(viewportSize)
                    lastFittedBoardID = newID
                }
            }
        }
    }

    private func draggableBoardNode(_ node: BoardNode) -> some View {
        let invZoom = CGFloat(1.0 / max(0.25, canvasZoom))
        let isSelected = selectedNodeID == node.id
        let isAssetNode: Bool = {
            if case .assetRef = node.kind { return true }
            return false
        }()

        return MoodboardNodeTile(
            node: node,
            asset: node.referencedAssetID.flatMap { assetsByID[$0] },
            thumbnails: store.thumbnails,
            isSelected: isSelected,
            selectionLineWidth: max(2.0, 2.5 * invZoom),
            onTap: {
                guard !isDrawingInk, !isPinchingCanvas else { return }
                selectedNodeID = node.id
            },
            onDoubleTap: {
                guard !isDrawingInk, !isPinchingCanvas else { return }
                handleNodeDoubleTap(node)
            }
        )
        .frame(width: node.frame.width, height: node.frame.height)
        .gesture(
            (!isDrawingInk && !node.isLocked)
                ? DragGesture(minimumDistance: 4, coordinateSpace: .named("moodboardViewport"))
                    .onChanged { val in
                        guard !isPinchingCanvas else { return }
                        selectedNodeID = node.id
                        activeDraggingNodeID = node.id
                        moveNode(node.id, translation: val.translation)
                    }
                    .onEnded { _ in
                        if activeDraggingNodeID == node.id {
                            activeDraggingNodeID = nil
                        }
                        dragStartFrames.removeValue(forKey: node.id)
                        didPushGestureUndo = false
                        if !isPinchingCanvas {
                            scheduleSave()
                        }
                    }
                : nil
        )
        .overlay {
            if isSelected && !node.isLocked && !isDrawingInk {
                let visualSize = min(38, max(14, 16 * invZoom))
                let hitSize = min(96, max(44, 44 * invZoom))
                let strokeW = min(4.5, max(1.8, 2.2 * invZoom))

                ZStack {
                    ForEach(ResizeCorner.allCases, id: \.self) { corner in
                        ZStack {
                            Color.clear
                                .frame(width: hitSize, height: hitSize)
                                .contentShape(Rectangle())
                            Circle()
                                .fill(MobileTheme.accent(for: colorScheme))
                                .frame(width: visualSize, height: visualSize)
                                .overlay(Circle().strokeBorder(.white, lineWidth: strokeW))
                                .shadow(color: .black.opacity(0.28), radius: 3 * invZoom, y: 1 * invZoom)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: corner.alignment)
                        .offset(
                            x: CGFloat(corner.signX) * (hitSize * 0.5 - 2 * invZoom),
                            y: CGFloat(corner.signY) * (hitSize * 0.5 - 2 * invZoom)
                        )
                        .highPriorityGesture(
                            DragGesture(minimumDistance: 2, coordinateSpace: .named("moodboardViewport"))
                                .onChanged { val in
                                    guard !isPinchingCanvas else { return }
                                    resizeNode(
                                        node.id,
                                        corner: corner,
                                        translation: val.translation,
                                        rotationDegrees: node.rotationDegrees,
                                        preserveAspect: isAssetNode
                                    )
                                }
                                .onEnded { _ in
                                    dragStartFrames.removeValue(forKey: node.id)
                                    didPushGestureUndo = false
                                    if !isPinchingCanvas {
                                        scheduleSave()
                                    }
                                }
                        )
                    }
                }
            }
        }
        // Rotate the ENTIRE node + selection border + corner handles as one rigid unit!
        .rotationEffect(.degrees(node.rotationDegrees))
        .position(x: node.frame.x + node.frame.width * 0.5, y: node.frame.y + node.frame.height * 0.5)
    }

    private var canvasPanGesture: some Gesture {
        DragGesture(coordinateSpace: .named("moodboardViewport"))
            .onChanged { val in
                guard !isPinchingCanvas else { return }
                canvasOffset = CGSize(
                    width: lastCanvasOffset.width + val.translation.width,
                    height: lastCanvasOffset.height + val.translation.height
                )
            }
            .onEnded { _ in
                if !isPinchingCanvas {
                    lastCanvasOffset = canvasOffset
                }
            }
    }

    private var canvasPinchGesture: some Gesture {
        MagnifyGesture()
            .onChanged { val in
                if !isPinchingCanvas {
                    isPinchingCanvas = true
                    pinchStartZoom = canvasZoom
                    pinchStartOffset = canvasOffset
                    pinchStartLocation = val.startLocation

                    // Cancel any stray ink stroke started as the second finger touched down for pinch zoom
                    if !activeStrokePoints.isEmpty {
                        activeStrokePoints = []
                    }

                    // If a 1-finger node drag started right before the 2nd finger landed, revert it immediately!
                    if let draggingID = activeDraggingNodeID,
                       let startFrame = dragStartFrames[draggingID],
                       var doc = document,
                       let idx = doc.nodes.firstIndex(where: { $0.id == draggingID }) {
                        doc.nodes[idx].frame = startFrame
                        document = doc
                        dragStartFrames.removeValue(forKey: draggingID)
                        activeDraggingNodeID = nil
                        if didPushGestureUndo {
                            _ = undoStack.popLast()
                            didPushGestureUndo = false
                        }
                    }
                }

                let newZoom = max(0.25, min(3.2, pinchStartZoom * val.magnification))
                let anchor = pinchStartLocation ?? val.startLocation
                let worldX = (anchor.x - pinchStartOffset.width) / max(0.05, pinchStartZoom)
                let worldY = (anchor.y - pinchStartOffset.height) / max(0.05, pinchStartZoom)
                canvasZoom = newZoom
                canvasOffset = CGSize(
                    width: anchor.x - worldX * newZoom,
                    height: anchor.y - worldY * newZoom
                )
            }
            .onEnded { _ in
                lastCanvasZoom = canvasZoom
                lastCanvasOffset = canvasOffset
                pinchStartLocation = nil
                isPinchingCanvas = false
            }
    }

    private var inkDrawGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { val in
                guard !isPinchingCanvas else { return }
                let wx = Double((val.location.x - canvasOffset.width) / max(0.05, canvasZoom))
                let wy = Double((val.location.y - canvasOffset.height) / max(0.05, canvasZoom))
                if let last = activeStrokePoints.last,
                   hypot(wx - last.x, wy - last.y) < 2.5 {
                    return
                }
                activeStrokePoints.append(InkStrokePoint(x: wx, y: wy, pressure: 0.6))
            }
            .onEnded { _ in
                defer { activeStrokePoints = [] }
                guard !isPinchingCanvas, activeStrokePoints.count >= 2, var doc = document else { return }
                pushUndoSnapshot(doc)
                let stroke = InkStroke(
                    points: activeStrokePoints,
                    colorHex: activeInkColorHex,
                    lineWidth: 3.5,
                    opacity: 0.92
                )
                doc.inkStrokes.append(stroke)
                document = doc
                scheduleSave()
            }
    }

    // MARK: - Floating Selected Node Bar, Ink Strip & Bottom Dock (Icon-Only Studio Chrome)

    private func selectedNodeActionPill(node: BoardNode) -> some View {
        HStack(spacing: 4) {
            if let assetID = node.referencedAssetID {
                pillIconAction("快速预览", icon: "eye") {
                    if let asset = assetsByID[assetID] {
                        onOpenAsset(asset)
                    }
                }
                pillIconAction("在素材库定位", icon: "scope") {
                    onRevealAssetInLibrary(assetID)
                }
            } else if case .note = node.kind {
                pillIconAction("编辑便签", icon: "pencil") {
                    handleNodeDoubleTap(node)
                }
            }

            pillIconAction("顺时针旋转 90°", icon: "rotate.right") {
                mutateNode(node.id) { $0.rotationDegrees += 90 }
            }
            pillIconAction("水平翻转", icon: "arrow.left.and.right.righttriangle.left.righttriangle.right") {
                mutateNode(node.id) { $0.flipHorizontal.toggle() }
            }
            pillIconAction(node.isLocked ? "解锁" : "锁定", icon: node.isLocked ? "lock.open" : "lock") {
                mutateNode(node.id) { $0.isLocked.toggle() }
            }
            pillIconAction("置于顶层", icon: "square.3.layers.3d.top.filled") {
                let topZ = (document?.nodes.map(\.zIndex).max() ?? 0) + 1
                mutateNode(node.id) { $0.zIndex = topZ }
            }
            Button(role: .destructive) {
                MobileHaptics.light()
                removeNode(node.id)
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(MobileTheme.destructive(for: colorScheme))
                    .frame(width: 36, height: 34)
                    .contentShape(Circle())
            }
            .buttonStyle(MobileTactileButtonStyle())
            .accessibilityLabel("移除节点")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .charkleFloatingCapsule(interactive: true)
    }

    private func pillIconAction(_ label: String, icon: String, action: @escaping () -> Void) -> some View {
        Button {
            MobileHaptics.light()
            action()
        } label: {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.primary)
                .frame(width: 36, height: 34)
                .contentShape(Circle())
        }
        .buttonStyle(MobileTactileButtonStyle())
        .accessibilityLabel(label)
    }

    private var inkToolStrip: some View {
        HStack(spacing: 10) {
            ForEach(inkColors, id: \.self) { hex in
                Button {
                    activeInkColorHex = hex
                    MobileHaptics.light()
                } label: {
                    Circle()
                        .fill(Color(charkleHex: hex))
                        .frame(width: 22, height: 22)
                        .overlay(
                            Circle().strokeBorder(
                                activeInkColorHex == hex ? MobileTheme.accent(for: colorScheme) : MobileTheme.borderStrong(for: colorScheme),
                                lineWidth: activeInkColorHex == hex ? 2.5 : 0.8
                            )
                        )
                }
                .buttonStyle(.plain)
            }
            Divider().frame(height: 18)
            Button {
                guard var doc = document, !doc.inkStrokes.isEmpty else { return }
                pushUndoSnapshot(doc)
                doc.inkStrokes.removeLast()
                document = doc
                scheduleSave()
                MobileHaptics.light()
            } label: {
                Image(systemName: "arrow.uturn.backward")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 32, height: 28)
            }
            .disabled(document?.inkStrokes.isEmpty ?? true)
            .accessibilityLabel("撤销上一笔")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .charkleFloatingCapsule(interactive: true)
    }

    private func moodboardBottomDock(doc: MoodboardDocument) -> some View {
        HStack(spacing: 4) {
            dockIconButton("撤销", icon: "arrow.uturn.backward", isActive: false, isDisabled: undoStack.isEmpty) {
                undoBoardEdit()
            }
            dockIconButton("重做", icon: "arrow.uturn.forward", isActive: false, isDisabled: redoStack.isEmpty) {
                redoBoardEdit()
            }
            Divider().frame(height: 18).padding(.horizontal, 2)
            dockIconButton("添加素材", icon: "photo.badge.plus", isActive: false) {
                isAddAssetsSheetPresented = true
            }
            dockIconButton("新建便签", icon: "note.text.badge.plus", isActive: false) {
                editingNoteNodeID = nil
                noteTitleDraft = ""
                noteTextDraft = ""
                noteStyleDraft = .warm
                isNoteEditorPresented = true
            }
            dockIconButton("新建分组框", icon: "rectangle.dashed", isActive: false) {
                isGroupCreatorPresented = true
            }
            if !doc.mode.isAutoEditorial {
                dockIconButton("画笔批注", icon: "pencil.tip.crop.circle", isActive: isDrawingInk) {
                    isDrawingInk.toggle()
                    if isDrawingInk { selectedNodeID = nil }
                }
            }
            dockIconButton(
                doc.mode.isAutoEditorial ? "切换为自由画布" : "切换为自动排版",
                icon: doc.mode.isAutoEditorial ? "hand.draw" : "rectangle.grid.2x2",
                isActive: false
            ) {
                if doc.mode.isAutoEditorial {
                    toggleLayoutMode(toFreeform: true)
                } else {
                    applyEditorialStyle(.balanced)
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .charkleFloatingCapsule(interactive: true)
    }

    private func dockIconButton(
        _ label: String,
        icon: String,
        isActive: Bool,
        isDisabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            MobileHaptics.light()
            action()
        } label: {
            Image(systemName: icon)
                .font(.system(size: 16.5, weight: .medium))
                .foregroundStyle(isActive ? .white : (isDisabled ? MobileTheme.tertiaryInk(for: colorScheme) : .primary))
                .frame(width: 40, height: 36)
                .background(
                    isActive ? MobileTheme.accentButtonFill(for: colorScheme) : .clear,
                    in: Capsule()
                )
                .contentShape(Capsule())
        }
        .buttonStyle(MobileTactileButtonStyle())
        .disabled(isDisabled)
        .accessibilityLabel(label)
    }

    @ViewBuilder
    private var moodboardKeyboardShortcutsBridge: some View {
        Group {
            Button("") {
                guard !isNoteEditorPresented && !isGroupCreatorPresented else { return }
                undoBoardEdit()
            }
            .keyboardShortcut("z", modifiers: .command)
            Button("") {
                guard !isNoteEditorPresented && !isGroupCreatorPresented else { return }
                redoBoardEdit()
            }
            .keyboardShortcut("z", modifiers: [.command, .shift])
            Button("") {
                if let selID = selectedNodeID, !isNoteEditorPresented, !isGroupCreatorPresented {
                    MobileHaptics.light()
                    removeNode(selID)
                }
            }
            .keyboardShortcut(.delete, modifiers: .command)
        }
        .frame(width: 0, height: 0)
        .opacity(0.001)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    // MARK: - Data, Undo/Redo & Mutations

    private func pushUndoSnapshot(_ snapshot: MoodboardDocument) {
        undoStack.append(snapshot)
        if undoStack.count > maxUndoHistoryCount {
            undoStack.removeFirst(undoStack.count - maxUndoHistoryCount)
        }
        redoStack.removeAll()
    }

    private func undoBoardEdit() {
        guard let previous = undoStack.popLast(), let current = document else { return }
        redoStack.append(current)
        if redoStack.count > maxUndoHistoryCount {
            redoStack.removeFirst(redoStack.count - maxUndoHistoryCount)
        }
        document = previous
        if let selID = selectedNodeID, !previous.nodes.contains(where: { $0.id == selID }) {
            selectedNodeID = nil
        }
        scheduleSave()
    }

    private func redoBoardEdit() {
        guard let next = redoStack.popLast(), let current = document else { return }
        undoStack.append(current)
        if undoStack.count > maxUndoHistoryCount {
            undoStack.removeFirst(undoStack.count - maxUndoHistoryCount)
        }
        document = next
        if let selID = selectedNodeID, !next.nodes.contains(where: { $0.id == selID }) {
            selectedNodeID = nil
        }
        scheduleSave()
    }

    private func loadBoard() async {
        guard let loaded = await store.fetchBoardDocument(id: boardID) else { return }
        document = loaded
        assetsByID = await store.fetchAssetsByID(loaded.referencedAssetIDs)
    }

    private func scheduleSave() {
        guard let current = document else { return }
        hasPendingSave = true
        saveDebounceTask?.cancel()
        saveDebounceTask = Task {
            try? await Task.sleep(for: .milliseconds(320))
            guard !Task.isCancelled else { return }
            hasPendingSave = false
            _ = await store.saveBoardDocument(current, quiet: true)
        }
    }

    private func flushPendingSave() {
        guard hasPendingSave, let current = document else { return }
        hasPendingSave = false
        saveDebounceTask?.cancel()
        saveDebounceTask = nil
        Task {
            _ = await store.saveBoardDocument(current, quiet: true)
        }
    }

    private func flushPendingSaveAsync() async {
        guard hasPendingSave, let current = document else { return }
        hasPendingSave = false
        saveDebounceTask?.cancel()
        saveDebounceTask = nil
        _ = await store.saveBoardDocument(current, quiet: true)
    }

    private func handleNodeDoubleTap(_ node: BoardNode) {
        switch node.kind {
        case .assetRef(let assetID, _, _, _):
            if let asset = assetsByID[assetID] {
                onOpenAsset(asset)
            }
        case .note(let title, let text, let style, _):
            editingNoteNodeID = node.id
            noteTitleDraft = title ?? ""
            noteTextDraft = text
            noteStyleDraft = style
            isNoteEditorPresented = true
        default:
            break
        }
    }

    private func mutateNode(_ id: UUID, _ mutate: (inout BoardNode) -> Void) {
        guard var doc = document, let idx = doc.nodes.firstIndex(where: { $0.id == id }) else { return }
        pushUndoSnapshot(doc)
        mutate(&doc.nodes[idx])
        doc.nodes[idx].updatedAt = Date()
        document = doc
        scheduleSave()
    }

    private func moveNode(_ id: UUID, translation: CGSize) {
        guard var doc = document, let idx = doc.nodes.firstIndex(where: { $0.id == id }) else { return }
        let start = dragStartFrames[id] ?? doc.nodes[idx].frame
        if dragStartFrames[id] == nil {
            pushUndoSnapshot(doc)
            didPushGestureUndo = true
            dragStartFrames[id] = start
        }
        let zoom = Double(max(0.1, canvasZoom))
        doc.nodes[idx].frame.x = start.x + Double(translation.width) / zoom
        doc.nodes[idx].frame.y = start.y + Double(translation.height) / zoom
        document = doc
    }

    private func resizeNode(
        _ id: UUID,
        corner: ResizeCorner,
        translation: CGSize,
        rotationDegrees: Double,
        preserveAspect: Bool
    ) {
        guard var doc = document, let idx = doc.nodes.firstIndex(where: { $0.id == id }) else { return }
        let start = dragStartFrames[id] ?? doc.nodes[idx].frame
        if dragStartFrames[id] == nil {
            pushUndoSnapshot(doc)
            didPushGestureUndo = true
            dragStartFrames[id] = start
        }

        let zoom = Double(max(0.1, canvasZoom))
        let worldDX = Double(translation.width) / zoom
        let worldDY = Double(translation.height) / zoom

        // Project world drag delta into the node's local rotated axes
        let radians = -rotationDegrees * .pi / 180.0
        let cosR = cos(radians)
        let sinR = sin(radians)
        let localDX = worldDX * cosR - worldDY * sinR
        let localDY = worldDX * sinR + worldDY * cosR

        var deltaW = localDX * corner.signX
        var deltaH = localDY * corner.signY

        if preserveAspect, start.width > 1, start.height > 1 {
            let aspect = start.width / start.height
            let scaleW = (start.width + deltaW) / start.width
            let scaleH = (start.height + deltaH) / start.height
            let uniformScale = max(0.25, (abs(deltaW) >= abs(deltaH)) ? scaleW : scaleH)
            var newW = max(90, start.width * uniformScale)
            var newH = newW / aspect
            if newH < 72 {
                newH = 72
                newW = max(90, newH * aspect)
            }
            deltaW = newW - start.width
            deltaH = newH - start.height
        } else {
            deltaW = max(90 - start.width, deltaW)
            deltaH = max(72 - start.height, deltaH)
        }

        let newW = start.width + deltaW
        let newH = start.height + deltaH

        // Keep opposite corner fixed in world coordinates even when the node is rotated
        let localCenterShiftX = corner.signX * (deltaW * 0.5)
        let localCenterShiftY = corner.signY * (deltaH * 0.5)
        let invRad = rotationDegrees * .pi / 180.0
        let worldCenterShiftX = localCenterShiftX * cos(invRad) - localCenterShiftY * sin(invRad)
        let worldCenterShiftY = localCenterShiftX * sin(invRad) + localCenterShiftY * cos(invRad)

        let newMidX = start.midX + worldCenterShiftX
        let newMidY = start.midY + worldCenterShiftY
        doc.nodes[idx].frame = BoardRect(
            x: newMidX - newW * 0.5,
            y: newMidY - newH * 0.5,
            width: newW,
            height: newH
        )
        document = doc
    }

    private func removeNode(_ id: UUID) {
        guard var doc = document else { return }
        pushUndoSnapshot(doc)
        doc.nodes.removeAll { $0.id == id }
        doc.connectors.removeAll { $0.fromNodeID == id || $0.toNodeID == id }
        if selectedNodeID == id { selectedNodeID = nil }
        document = doc
        scheduleSave()
    }

    private func saveNoteDraft() {
        guard var doc = document else { return }
        pushUndoSnapshot(doc)
        let title = noteTitleDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = noteTextDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if let editID = editingNoteNodeID, let idx = doc.nodes.firstIndex(where: { $0.id == editID }) {
            doc.nodes[idx].kind = .note(title: title.isEmpty ? nil : title, text: text, style: noteStyleDraft, fontSize: 15)
            doc.nodes[idx].updatedAt = Date()
        } else {
            let maxY = doc.nodes.map(\.frame.maxY).max() ?? 20
            let node = BoardNode(
                kind: .note(title: title.isEmpty ? nil : title, text: text, style: noteStyleDraft, fontSize: 15),
                frame: BoardRect(x: 40, y: doc.nodes.isEmpty ? 40 : maxY + 24, width: 250, height: 150),
                zIndex: (doc.nodes.map(\.zIndex).max() ?? 0) + 1,
                editorialOrder: (doc.nodes.map(\.editorialOrder).max() ?? -1) + 1
            )
            doc.nodes.append(node)
        }
        document = doc
        scheduleSave()
    }

    private func addGroupFrame(title: String, tint: GroupTint) {
        guard var doc = document else { return }
        pushUndoSnapshot(doc)
        let maxY = doc.nodes.map(\.frame.maxY).max() ?? 20
        let node = BoardNode(
            kind: .groupFrame(title: title, tint: tint),
            frame: BoardRect(x: 24, y: doc.nodes.isEmpty ? 24 : maxY + 28, width: 580, height: 340),
            zIndex: (doc.nodes.map(\.zIndex).min() ?? 0) - 1,
            editorialOrder: (doc.nodes.map(\.editorialOrder).max() ?? -1) + 1
        )
        doc.nodes.append(node)
        document = doc
        scheduleSave()
    }

    private func appendAssetsToBoard(_ ids: [UUID]) async {
        guard !ids.isEmpty else { return }
        await flushPendingSaveAsync()
        await store.addAssets(ids, toBoard: boardID)
        await loadBoard()
    }

    private func toggleLayoutMode(toFreeform: Bool) {
        guard var doc = document else { return }
        pushUndoSnapshot(doc)
        if toFreeform, case .autoEditorial(let cfg) = doc.mode {
            let solved = computeAutoEditorialFrames(nodes: doc.nodes, config: cfg, width: 960)
            for idx in doc.nodes.indices {
                if let r = solved.frames[doc.nodes[idx].id] {
                    doc.nodes[idx].frame = r
                }
            }
            doc.mode = .freeform
        } else if !toFreeform {
            doc.mode = .autoEditorial(AutoLayoutConfig())
        }
        document = doc
        scheduleSave()
    }

    private func applyEditorialStyle(_ style: EditorialStyle) {
        guard var doc = document else { return }
        pushUndoSnapshot(doc)
        isDrawingInk = false
        doc.mode = .autoEditorial(AutoLayoutConfig(columns: 3, spacing: 14, style: style, showPaletteStrip: true))
        document = doc
        scheduleSave()
    }

    private func fitCanvasToViewport(_ size: CGSize) {
        guard let doc = document, !doc.nodes.isEmpty else { return }
        let minX = doc.nodes.map(\.frame.minX).min() ?? 0
        let minY = doc.nodes.map(\.frame.minY).min() ?? 0
        let maxX = doc.nodes.map(\.frame.maxX).max() ?? 400
        let maxY = doc.nodes.map(\.frame.maxY).max() ?? 400
        let worldW = max(120, maxX - minX)
        let worldH = max(120, maxY - minY)
        let pad: CGFloat = 32
        let scaleX = max(0.25, (size.width - pad * 2) / CGFloat(worldW))
        let scaleY = max(0.25, (size.height - pad * 2 - 80) / CGFloat(worldH))
        let fit = min(1.0, min(scaleX, scaleY))
        canvasZoom = fit
        lastCanvasZoom = fit
        let ox = (size.width - CGFloat(worldW) * fit) * 0.5 - CGFloat(minX) * fit
        let oy = pad - CGFloat(minY) * fit
        canvasOffset = CGSize(width: ox, height: oy)
        lastCanvasOffset = canvasOffset
    }

    private func exportHighResPNG() async {
        guard let doc = document else { return }
        isExporting = true
        defer { isExporting = false }
        exportedImageURL = await store.exportBoardPNGURL(
            document: doc,
            darkAppearance: colorScheme == .dark
        )
    }

    private func exportPureRefScene() async {
        guard let doc = document else { return }
        isExporting = true
        defer { isExporting = false }
        exportedImageURL = await store.exportBoardPureRefURL(document: doc)
    }

    // MARK: - Editorial Auto-Layout Solver (Matching Desktop Semantics)

    private func computeAutoEditorialFrames(
        nodes: [BoardNode],
        config: AutoLayoutConfig,
        width: Double
    ) -> (frames: [UUID: BoardRect], contentHeight: Double) {
        let pad: Double = config.style == .compact ? 10 : 16
        let spacing: Double = config.style == .compact ? 6 : (config.style == .magazine ? 16 : 12)
        let usableW = max(260, width - pad * 2)
        let cols: Int = {
            switch config.style {
            case .compact: return max(3, min(5, Int(usableW / 120)))
            case .magazine: return max(2, min(3, Int(usableW / 180)))
            case .balanced: return max(2, min(4, Int(usableW / 165)))
            }
        }()
        let colW = (usableW - spacing * Double(cols - 1)) / Double(cols)
        var heights = Array(repeating: pad, count: cols)
        var frames: [UUID: BoardRect] = [:]

        let sorted = nodes.sorted {
            if $0.editorialOrder != $1.editorialOrder { return $0.editorialOrder < $1.editorialOrder }
            return $0.id.uuidString < $1.id.uuidString
        }

        for (index, node) in sorted.enumerated() {
            switch node.kind {
            case .groupFrame:
                let y = heights.max() ?? pad
                let h = 48.0
                frames[node.id] = BoardRect(x: pad, y: y, width: usableW, height: h)
                for c in 0..<cols { heights[c] = y + h + spacing }
            case .paletteStrip:
                let y = heights.max() ?? pad
                let h = 58.0
                frames[node.id] = BoardRect(x: pad, y: y, width: usableW, height: h)
                for c in 0..<cols { heights[c] = y + h + spacing }
            case .note(_, let text, _, _):
                let c = shortestCol(heights)
                let h = max(110, min(220, Double(max(3, text.count / 16 + 2)) * 22 + 32))
                frames[node.id] = BoardRect(x: pad + Double(c) * (colW + spacing), y: heights[c], width: colW, height: h)
                heights[c] += h + spacing
            case .assetRef(let assetID, _, let weight, _):
                let aspect = max(0.55, min(2.0, assetsByID[assetID]?.aspectRatio ?? 1.2))
                if config.style == .magazine && cols >= 2 && (index == 0 || weight >= 2) {
                    let spanW = colW * 2 + spacing
                    let y = max(heights[0], heights[1])
                    let h = spanW / max(0.9, min(1.85, aspect))
                    frames[node.id] = BoardRect(x: pad, y: y, width: spanW, height: h)
                    heights[0] = y + h + spacing
                    heights[1] = y + h + spacing
                } else {
                    let c = shortestCol(heights)
                    let h = colW / aspect
                    frames[node.id] = BoardRect(x: pad + Double(c) * (colW + spacing), y: heights[c], width: colW, height: h)
                    heights[c] += h + spacing
                }
            }
        }
        return (frames, (heights.max() ?? pad) + 40)
    }

    private func shortestCol(_ heights: [Double]) -> Int {
        var best = 0
        for i in 1..<heights.count where heights[i] < heights[best] { best = i }
        return best
    }

    // MARK: - Canvas Rendering for Connectors & Ink Strokes

    private func drawConnectors(_ connectors: [BoardConnector], nodes: [BoardNode], in context: inout GraphicsContext) {
        let byID = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })
        for conn in connectors {
            guard let fromNode = byID[conn.fromNodeID], let toNode = byID[conn.toNodeID] else { continue }
            let start = CGPoint(x: fromNode.frame.midX, y: fromNode.frame.midY)
            let end = CGPoint(x: toNode.frame.midX, y: toNode.frame.midY)
            var path = Path()
            path.move(to: start)
            if conn.style == .straight {
                path.addLine(to: end)
            } else {
                let midX = (start.x + end.x) * 0.5
                path.addCurve(to: end, control1: CGPoint(x: midX, y: start.y), control2: CGPoint(x: midX, y: end.y))
            }
            let style = StrokeStyle(lineWidth: 2.2, lineCap: .round, dash: conn.dashed ? [6, 5] : [])
            context.stroke(path, with: .color(Color(charkleHex: conn.colorHex)), style: style)
        }
    }

    private func drawInkStroke(_ points: [InkStrokePoint], colorHex: String, lineWidth: Double, opacity: Double, in context: inout GraphicsContext) {
        guard points.count >= 2 else { return }
        var path = Path()
        path.move(to: CGPoint(x: points[0].x, y: points[0].y))
        for pt in points.dropFirst() {
            path.addLine(to: CGPoint(x: pt.x, y: pt.y))
        }
        context.stroke(
            path,
            with: .color(Color(charkleHex: colorHex).opacity(opacity)),
            style: StrokeStyle(lineWidth: max(1.5, lineWidth), lineCap: .round, lineJoin: .round)
        )
    }
}

// MARK: - Individual Moodboard Node Renderer

private struct MoodboardNodeTile: View {
    let node: BoardNode
    let asset: AssetRecord?
    let thumbnails: MobileThumbnailCache
    let isSelected: Bool
    var selectionLineWidth: CGFloat = 2.5
    let onTap: () -> Void
    let onDoubleTap: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var image: UIImage?

    var body: some View {
        Group {
            switch node.kind {
            case .assetRef(let assetID, _, _, _):
                ZStack {
                    RoundedRectangle(cornerRadius: MobileTheme.Radius.cardOuter, style: .continuous)
                        .fill(MobileTheme.surfaceSubtle(for: colorScheme))
                    if let image {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: MobileTheme.Radius.cardOuter, style: .continuous))
                .scaleEffect(x: node.flipHorizontal ? -1 : 1, y: node.flipVertical ? -1 : 1)
                .shadow(color: .black.opacity(colorScheme == .dark ? 0.34 : 0.10), radius: 10, y: 4)
                .task(id: "\(assetID.uuidString)-\(thumbnails.revision)") {
                    if let hit = thumbnails.cachedImage(for: assetID, tier: .grid520) {
                        image = hit
                        return
                    }
                    image = await thumbnails.loadImage(for: assetID, tier: .grid520)
                }

            case .note(let title, let text, let style, let fontSize):
                let colors = noteThemeColors(style)
                VStack(alignment: .leading, spacing: 6) {
                    if let title, !title.isEmpty {
                        Text(title)
                            .font(.system(size: max(13, fontSize), weight: .bold))
                            .foregroundStyle(colors.fg)
                            .lineLimit(2)
                    }
                    Text(text)
                        .font(.system(size: max(12.5, fontSize - 1)))
                        .foregroundStyle(colors.fg.opacity(0.88))
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
                .padding(14)
                .background(colors.bg, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(MobileTheme.hairline(for: colorScheme), lineWidth: 0.75)
                )

            case .groupFrame(let title, let tint):
                let tintColor = groupTintColor(tint)
                VStack(alignment: .leading) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(tintColor)
                        .padding(.horizontal, 12)
                        .padding(.top, 10)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(tintColor.opacity(colorScheme == .dark ? 0.14 : 0.10), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(tintColor.opacity(0.42), style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                )

            case .paletteStrip(let colors, _):
                HStack(spacing: 4) {
                    ForEach(colors.prefix(8), id: \.hex) { swatch in
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color(charkleHex: swatch.hex))
                    }
                }
                .padding(6)
                .background(MobileTheme.surfaceElevated(for: colorScheme), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: MobileTheme.Radius.cardOuter, style: .continuous)
                .strokeBorder(isSelected ? MobileTheme.accent(for: colorScheme) : .clear, lineWidth: selectionLineWidth)
        )
        .onTapGesture(count: 2, perform: onDoubleTap)
        .onTapGesture(count: 1, perform: onTap)
    }

    private func noteThemeColors(_ style: NoteStyle) -> (bg: Color, fg: Color) {
        switch style {
        case .paper: (Color(charkleHex: "#FFFFFF"), Color(charkleHex: "#1D1F23"))
        case .ink: (Color(charkleHex: "#1D1F24"), Color(charkleHex: "#F1F2F4"))
        case .warm: (Color(charkleHex: "#F7F0E4"), Color(charkleHex: "#392F22"))
        case .sage: (Color(charkleHex: "#E8F0EA"), Color(charkleHex: "#203227"))
        case .slate: (Color(charkleHex: "#E9EEF3"), Color(charkleHex: "#1F2B36"))
        }
    }

    private func groupTintColor(_ tint: GroupTint) -> Color {
        switch tint {
        case .neutral: Color(charkleHex: "#7D838B")
        case .sand: Color(charkleHex: "#B5956B")
        case .sage: Color(charkleHex: "#6B8E76")
        case .slate: Color(charkleHex: "#627A94")
        case .terracotta: Color(charkleHex: "#BA6B55")
        case .ocean: Color(charkleHex: "#4D7E97")
        }
    }
}

// MARK: - Searchable Library Asset Picker Sheet for Adding to Moodboard

private struct MoodboardAssetPickerSheet: View {
    @Bindable var store: MobileAppStore
    let onConfirm: ([UUID]) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @State private var query = ""
    @State private var libraryAssets: [AssetRecord] = []
    @State private var pickedIDs: Set<UUID> = []

    private var filtered: [AssetRecord] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return libraryAssets }
        return libraryAssets.filter {
            $0.title.lowercased().contains(q)
                || $0.tags.contains(where: { $0.lowercased().contains(q) })
        }
    }

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 6)], spacing: 6) {
                ForEach(filtered) { asset in
                    let selected = pickedIDs.contains(asset.id)
                    Button {
                        MobileHaptics.light()
                        if selected { pickedIDs.remove(asset.id) } else { pickedIDs.insert(asset.id) }
                    } label: {
                        ZStack(alignment: .topTrailing) {
                            PickerThumbCell(asset: asset, thumbnails: store.thumbnails)
                                .aspectRatio(1, contentMode: .fit)
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .strokeBorder(selected ? MobileTheme.accent(for: colorScheme) : .clear, lineWidth: 2.5)
                                )
                            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundStyle(selected ? MobileTheme.accent(for: colorScheme) : .white)
                                .shadow(radius: 2)
                                .padding(6)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(12)
        }
        .searchable(text: $query, prompt: "搜索素材标题或标签")
        .navigationTitle("选择素材加入情绪板")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("取消") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("加入 (\(pickedIDs.count))") {
                    onConfirm(Array(pickedIDs))
                }
                .fontWeight(.semibold)
                .disabled(pickedIDs.isEmpty)
            }
        }
        .task {
            libraryAssets = (try? await store.engine.fetchAssets(matching: FilterCriteria(sortBy: .newest))) ?? []
        }
    }
}

private struct PickerThumbCell: View {
    let asset: AssetRecord
    let thumbnails: MobileThumbnailCache
    @State private var image: UIImage?

    var body: some View {
        Color(.secondarySystemFill)
            .overlay {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                }
            }
            .clipped()
            .task(id: asset.id) {
                if let hit = thumbnails.cachedImage(for: asset.id, tier: .grid520) {
                    image = hit
                    return
                }
                image = await thumbnails.loadImage(for: asset.id, tier: .grid520)
            }
    }
}
