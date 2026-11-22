import AppKit
import CharkleCanvas
import CharkleCore
import SwiftUI
import UniformTypeIdentifiers
import os

private let notchLogger = Logger(subsystem: "com.charkle.app", category: "NotchShelf")

private final class NotchPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Native AppKit `NSDraggingDestination` hosting view so background cross-app drag-and-drop works
/// reliably from Finder, Chrome, Safari, Arc, Figma, Preview, and Photos without activating Charkle.
private final class NotchDropHostingView: NSHostingView<NotchShelfView> {
    var onDragEntered: ((Int) -> Void)?
    var onDragExited: (() -> Void)?
    var onPerformDrop: ((NSPasteboard, [NSFilePromiseReceiver]) -> Bool)?
    var activeHitRectProvider: (() -> NSRect)?

    private static let supportedTypes: [NSPasteboard.PasteboardType] = {
        var types: [NSPasteboard.PasteboardType] = [
            .fileURL,
            NSPasteboard.PasteboardType("NSFilenamesPboardType"),
            .URL,
            .png,
            .tiff,
            NSPasteboard.PasteboardType(UTType.jpeg.identifier),
            NSPasteboard.PasteboardType(UTType.image.identifier),
            .string
        ]
        types.append(contentsOf: NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) })
        return types
    }()

    required init(rootView: NotchShelfView) {
        super.init(rootView: rootView)
        wantsLayer = true
        layer?.masksToBounds = false
        registerForDraggedTypes(Self.supportedTypes)
    }

    @available(*, unavailable)
    @MainActor @preconcurrency dynamic required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        if let activeRect = activeHitRectProvider?(), !activeRect.contains(point) {
            return nil
        }
        return super.hitTest(point)
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        let count = sender.draggingPasteboard.pasteboardItems?.count ?? 1
        onDragEntered?(max(count, 1))
        return .copy
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        .copy
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        onDragExited?()
    }

    override func draggingEnded(_ sender: any NSDraggingInfo) {
        onDragExited?()
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let pb = sender.draggingPasteboard
        let receivers = (pb.readObjects(forClasses: [NSFilePromiseReceiver.self], options: nil) as? [NSFilePromiseReceiver]) ?? []
        let ok = onPerformDrop?(pb, receivers) ?? false
        onDragExited?()
        return ok
    }
}

/// Ultra-slim transparent sensor strip anchored strictly on the physical MacBook notch / top edge.
private final class NotchSensorView: NSView {
    var onTriggerOpenForDrag: ((Int) -> Void)?
    var onDragExited: (() -> Void)?
    var onTriggerOpenForHover: (() -> Void)?
    var onPerformDrop: ((NSPasteboard, [NSFilePromiseReceiver]) -> Bool)?

    private var trackingAreaRef: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        var types: [NSPasteboard.PasteboardType] = [
            .fileURL,
            NSPasteboard.PasteboardType("NSFilenamesPboardType"),
            .URL,
            .png,
            .tiff,
            NSPasteboard.PasteboardType(UTType.jpeg.identifier),
            NSPasteboard.PasteboardType(UTType.image.identifier),
            .string
        ]
        types.append(contentsOf: NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) })
        registerForDraggedTypes(types)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingAreaRef {
            removeTrackingArea(existing)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingAreaRef = area
    }

    override func mouseEntered(with event: NSEvent) {
        onTriggerOpenForHover?()
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        let count = sender.draggingPasteboard.pasteboardItems?.count ?? 1
        onTriggerOpenForDrag?(max(count, 1))
        return .copy
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        .copy
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        onDragExited?()
    }

    override func draggingEnded(_ sender: any NSDraggingInfo) {
        onDragExited?()
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let pb = sender.draggingPasteboard
        let receivers = (pb.readObjects(forClasses: [NSFilePromiseReceiver.self], options: nil) as? [NSFilePromiseReceiver]) ?? []
        let ok = onPerformDrop?(pb, receivers) ?? false
        onDragExited?()
        return ok
    }
}

/// Animation-ready MacBook Notch Shelf controller:
/// - Maintains a fixed oversized transparent `NSPanel` flush to `screen.frame.maxY`
///   (never mutating `NSWindow.frame` during expand/collapse!).
/// - Monitors `NSPasteboard(.drag).changeCount` to proactively drop down below the menu bar during
///   external drags, avoiding macOS Mission Control / Spaces desktop switching.
/// - Supports 3-way target ingestion (Inbox / Folder / Active Moodboard).
public final class NotchShelfController {
    private let coordinator: AppCoordinatorStore
    private let library: LibraryStore
    private let moodboards: MoodboardStore
    private let onCaptureArea: () -> Void
    private let onCollectClipboard: () -> Void
    private let onOpenMainWindow: () -> Void

    public let shelfState = NotchShelfState()

    private var panel: NotchPanel?
    private var sensorWindow: NotchPanel?
    private var pollTimer: Timer?
    private var hideWorkItem: DispatchWorkItem?
    private var bannerResetTask: Task<Void, Never>?
    private let promiseQueue = OperationQueue()

    private var isSensorDragging = false
    private var isPanelDragging = false
    private var lastObservedDragChangeCount: Int = NSPasteboard(name: .drag).changeCount
    private var lastObservedGeneralPasteboardChangeCount: Int = -1
    private var autoOpenedBySystemDrag: Bool = false
    private var lastAnchoredScreenFrame: NSRect = .zero
    private var screenObserver: (any NSObjectProtocol)?
    private var keyMonitor: Any?

    private static let shelfWindowLevel = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) + 4)
    private static let sensorWindowLevel = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) + 3)

    // Generous transparent margin (≥ 3× shadow radius on left/right/bottom) so drop shadows
    // feather cleanly to 0% alpha without ever clipping into a rectangular borderless panel edge.
    private static let shadowHorizontalMargin: CGFloat = 96
    private static let shadowBottomMargin: CGFloat = 120

    private struct ScreenNotchMetrics {
        let hasPhysicalNotch: Bool
        let notchWidth: CGFloat
        let notchHeight: CGFloat
    }

    public init(
        coordinator: AppCoordinatorStore,
        library: LibraryStore,
        moodboards: MoodboardStore,
        onCaptureArea: @escaping () -> Void,
        onCollectClipboard: @escaping () -> Void,
        onOpenMainWindow: @escaping () -> Void
    ) {
        self.coordinator = coordinator
        self.library = library
        self.moodboards = moodboards
        self.onCaptureArea = onCaptureArea
        self.onCollectClipboard = onCollectClipboard
        self.onOpenMainWindow = onOpenMainWindow

        promiseQueue.name = "com.charkle.notch.filepromises"
        createFixedPanel()
        setupSensorWindow()
        startCursorAndDragWatcher()

        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.anchorFixedPanelIfScreenChanged()
                self?.repositionSensorWindow()
            }
        }

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.shelfState.isExpanded, self.panel?.isKeyWindow == true else {
                return event
            }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if flags == .command, event.charactersIgnoringModifiers?.lowercased() == "v" {
                self.onCollectClipboard()
                return nil
            }
            if event.keyCode == 53 { // Escape
                self.collapse()
                return nil
            }
            return event
        }
    }

    public func toggle() {
        if shelfState.isExpanded {
            collapse()
        } else {
            expand(forDrag: false)
        }
    }

    public func expand(forDrag: Bool = false) {
        guard coordinator.notchShelfEnabled else { return }
        hideWorkItem?.cancel()
        anchorFixedPanelIfScreenChanged()
        refreshClipboardHint(force: true)
        guard let panel else { return }

        panel.ignoresMouseEvents = false
        if !panel.isVisible {
            panel.orderFrontRegardless()
        }
        shelfState.isExpanded = true
    }

    public func collapse() {
        guard shelfState.isExpanded else { return }
        if shelfState.isDropTargeted || shelfState.processingMessage != nil { return }
        hideWorkItem?.cancel()
        shelfState.isExpanded = false
        // Immediately let pointer events pass through to underlying apps even during spring settle
        panel?.ignoresMouseEvents = true
    }

    /// Shows an active in-progress spinner in the Notch Shelf (e.g. while downloading X post media).
    public func showProcessing(_ message: String) {
        expand(forDrag: false)
        bannerResetTask?.cancel()
        hideWorkItem?.cancel()
        shelfState.statusBanner = nil
        shelfState.processingMessage = message
    }

    /// Shows a brief confirmation in the Notch Shelf (e.g. after screenshot, clipboard, or X post collect).
    public func flashConfirmation(_ message: String) {
        expand(forDrag: false)
        bannerResetTask?.cancel()
        shelfState.processingMessage = nil
        shelfState.statusBanner = message
        shelfState.lastDropTimestamp = Date()
        hideWorkItem?.cancel()
        bannerResetTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.8))
            guard !Task.isCancelled, let self else { return }
            self.shelfState.statusBanner = nil
            self.scheduleAutoCollapse(delay: 0.45)
        }
    }

    private func refreshClipboardHint(force: Bool = false) {
        let count = NSPasteboard.general.changeCount
        guard force || count != lastObservedGeneralPasteboardChangeCount else { return }
        lastObservedGeneralPasteboardChangeCount = count
        shelfState.clipboardXPostURL = ClipboardCollector.detectedXPostURL(from: .general)
    }

    // MARK: - Fixed Oversized Transparent NSPanel Setup

    private func createFixedPanel() {
        let rootView = NotchShelfView(
            shelfState: shelfState,
            coordinator: coordinator,
            library: library,
            moodboards: moodboards,
            onCaptureArea: { [weak self] in
                self?.collapse()
                self?.onCaptureArea()
            },
            onCollectClipboard: { [weak self] in
                self?.onCollectClipboard()
            },
            onOpenMainWindow: { [weak self] in
                self?.collapse()
                self?.onOpenMainWindow()
            },
            onClose: { [weak self] in
                self?.collapse()
            }
        )

        let initialPanelWidth = shelfState.expandedShapeWidth + Self.shadowHorizontalMargin * 2
        let initialPanelHeight = shelfState.expandedCardHeight + Self.shadowBottomMargin

        let hosting = NotchDropHostingView(rootView: rootView)
        hosting.frame = NSRect(x: 0, y: 0, width: initialPanelWidth, height: initialPanelHeight)
        hosting.autoresizingMask = [.width, .height]

        hosting.onDragEntered = { [weak self] count in
            guard let self else { return }
            self.hideWorkItem?.cancel()
            self.shelfState.dragItemCount = count
            self.isPanelDragging = true
            self.syncDropTargetedState()
        }
        hosting.onDragExited = { [weak self] in
            guard let self else { return }
            self.isPanelDragging = false
            self.syncDropTargetedState()
        }
        hosting.onPerformDrop = { [weak self] pasteboard, receivers in
            guard let self else { return false }
            return self.handleAppKitDrop(pasteboard: pasteboard, promiseReceivers: receivers)
        }
        hosting.activeHitRectProvider = { [weak self, weak hosting] in
            guard let self, let hosting, self.shelfState.isExpanded else { return .zero }
            let bounds = hosting.bounds
            let cardW = self.shelfState.expandedShapeWidth
            let cardH = self.shelfState.expandedCardHeight + 12
            return NSRect(
                x: bounds.midX - (cardW / 2.0) - 8,
                y: bounds.maxY - cardH,
                width: cardW + 16,
                height: cardH
            )
        }

        let panel = NotchPanel(
            contentRect: NSRect(x: 0, y: 0, width: initialPanelWidth, height: initialPanelHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentView = hosting
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = Self.shelfWindowLevel
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.hidesOnDeactivate = false
        panel.worksWhenModal = true
        panel.isMovableByWindowBackground = false
        panel.ignoresMouseEvents = true
        self.panel = panel

        anchorFixedPanelIfScreenChanged()
        panel.orderFrontRegardless()
    }

    private func notchMetrics(for screen: NSScreen) -> ScreenNotchMetrics {
        let safeTop = screen.safeAreaInsets.top
        let auxLeft = screen.auxiliaryTopLeftArea
        let auxRight = screen.auxiliaryTopRightArea
        let auxHeight = max(auxLeft?.height ?? 0, auxRight?.height ?? 0)
        let hasNotch = safeTop > 0

        let measuredWidth: CGFloat
        if let left = auxLeft, let right = auxRight {
            measuredWidth = max(0, screen.frame.width - left.width - right.width)
        } else {
            measuredWidth = 0
        }

        // Always keep generous notch dimensions so UI never collides with any MacBook Pro/Air camera housing
        let notchWidth: CGFloat = hasNotch ? max(measuredWidth, 192) : 204
        let notchHeight: CGFloat = hasNotch ? max(safeTop, auxHeight, 36) : 0
        return ScreenNotchMetrics(
            hasPhysicalNotch: hasNotch,
            notchWidth: notchWidth,
            notchHeight: notchHeight
        )
    }

    private func anchorFixedPanelIfScreenChanged() {
        guard let panel else { return }
        let screen = screenUnderCursor()
        let metrics = notchMetrics(for: screen)

        if shelfState.hasPhysicalNotch != metrics.hasPhysicalNotch {
            shelfState.hasPhysicalNotch = metrics.hasPhysicalNotch
        }
        if abs(shelfState.physicalNotchWidth - metrics.notchWidth) > 0.5 {
            shelfState.physicalNotchWidth = metrics.notchWidth
        }
        if abs(shelfState.physicalNotchHeight - metrics.notchHeight) > 0.5 {
            shelfState.physicalNotchHeight = metrics.notchHeight
        }

        let panelWidth = shelfState.expandedShapeWidth + Self.shadowHorizontalMargin * 2
        let panelHeight = shelfState.expandedCardHeight + Self.shadowBottomMargin
        let targetFrame = NSRect(
            x: screen.frame.midX - panelWidth / 2.0,
            y: screen.frame.maxY - panelHeight,
            width: panelWidth,
            height: panelHeight
        )
        if lastAnchoredScreenFrame != targetFrame {
            lastAnchoredScreenFrame = targetFrame
            panel.setFrame(targetFrame, display: false)
        }
    }

    private func setupSensorWindow() {
        let sensorView = NotchSensorView(frame: NSRect(x: 0, y: 0, width: 220, height: 32))
        sensorView.onTriggerOpenForDrag = { [weak self] count in
            guard let self, self.coordinator.notchShelfEnabled else { return }
            self.shelfState.dragItemCount = count
            self.isSensorDragging = true
            self.syncDropTargetedState()
            self.expand(forDrag: true)
        }
        sensorView.onDragExited = { [weak self] in
            guard let self else { return }
            self.isSensorDragging = false
            self.syncDropTargetedState()
        }
        sensorView.onTriggerOpenForHover = { [weak self] in
            guard let self, self.coordinator.notchShelfEnabled, self.coordinator.notchHoverTriggerEnabled else { return }
            self.expand(forDrag: false)
        }
        sensorView.onPerformDrop = { [weak self] pasteboard, receivers in
            guard let self else { return false }
            self.isSensorDragging = false
            self.syncDropTargetedState()
            return self.handleAppKitDrop(pasteboard: pasteboard, promiseReceivers: receivers)
        }

        let sensor = NotchPanel(
            contentRect: NSRect(x: 0, y: 0, width: 220, height: 32),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        sensor.contentView = sensorView
        sensor.isOpaque = false
        // Near-zero alpha so macOS WindowServer still delivers drag & tracking hit tests
        sensor.backgroundColor = NSColor.black.withAlphaComponent(0.002)
        sensor.hasShadow = false
        sensor.level = Self.sensorWindowLevel
        sensor.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        sensor.hidesOnDeactivate = false
        sensor.worksWhenModal = true
        sensor.ignoresMouseEvents = false
        self.sensorWindow = sensor

        repositionSensorWindow()
        sensor.orderFrontRegardless()
    }

    private func repositionSensorWindow() {
        guard let sensorWindow else { return }
        guard coordinator.notchShelfEnabled else {
            sensorWindow.orderOut(nil)
            return
        }
        let screen = screenUnderCursor()
        let metrics = notchMetrics(for: screen)
        let sensorWidth: CGFloat = metrics.hasPhysicalNotch ? (metrics.notchWidth + 24) : 230
        let sensorHeight: CGFloat = metrics.hasPhysicalNotch ? max(metrics.notchHeight, 34) : 8
        let rect = NSRect(
            x: screen.frame.midX - sensorWidth / 2.0,
            y: screen.frame.maxY - sensorHeight,
            width: sensorWidth,
            height: sensorHeight
        )
        if sensorWindow.frame != rect {
            sensorWindow.setFrame(rect, display: false)
        }
        if !sensorWindow.isVisible {
            sensorWindow.orderFrontRegardless()
        }
    }

    // MARK: - System Drag Pasteboard Watcher (Mission Control Avoidance)

    private func startCursorAndDragWatcher() {
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.10, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.pollCursorAndDragState()
            }
        }
    }

    private func syncDropTargetedState() {
        shelfState.isDropTargeted = isSensorDragging || isPanelDragging
        if !shelfState.isDropTargeted {
            shelfState.dragItemCount = 0
        }
    }

    private func dragPasteboardHasDroppablePayload(_ pb: NSPasteboard) -> Bool {
        guard let types = pb.types, !types.isEmpty else { return false }
        let accepted: Set<NSPasteboard.PasteboardType> = [
            .fileURL,
            NSPasteboard.PasteboardType("NSFilenamesPboardType"),
            .URL,
            .png,
            .tiff,
            NSPasteboard.PasteboardType(UTType.jpeg.identifier),
            NSPasteboard.PasteboardType(UTType.image.identifier),
            NSPasteboard.PasteboardType("com.apple.NSFilePromiseItemMetaData")
        ]
        return types.contains(where: { accepted.contains($0) })
    }

    private func pollCursorAndDragState() {
        repositionSensorWindow()
        guard coordinator.notchShelfEnabled else {
            if shelfState.isExpanded { collapse() }
            return
        }

        let loc = NSEvent.mouseLocation
        let screen = screenUnderCursor()
        let isMouseButtonDown = NSEvent.pressedMouseButtons != 0

        // Proactively expand Notch Shelf BELOW the menu bar whenever an external Finder/Browser drag starts,
        // so the user drops safely without slamming into macOS's top-1px Mission Control / Spaces trigger!
        let dragPB = NSPasteboard(name: .drag)
        let currentDragCount = dragPB.changeCount
        if currentDragCount != lastObservedDragChangeCount {
            lastObservedDragChangeCount = currentDragCount
            let rawString = dragPB.string(forType: .string) ?? ""
            let isInternalCardDrag = CharkleDragIdentifiers.decodeAssetIDs(from: rawString) != nil
            if isMouseButtonDown && !isInternalCardDrag && dragPasteboardHasDroppablePayload(dragPB) {
                autoOpenedBySystemDrag = true
                if !shelfState.isExpanded {
                    expand(forDrag: true)
                }
            }
        }

        if autoOpenedBySystemDrag {
            if isMouseButtonDown {
                hideWorkItem?.cancel()
                return
            } else {
                autoOpenedBySystemDrag = false
                if !isPanelDragging && shelfState.statusBanner == nil {
                    scheduleAutoCollapse(delay: 0.35)
                }
                return
            }
        }

        let metrics = notchMetrics(for: screen)
        let topBandHeight: CGFloat = isMouseButtonDown ? 68 : max(metrics.notchHeight, 10)
        let horizontalHalfSpan: CGFloat = isMouseButtonDown ? 190 : max(metrics.notchWidth / 2.0 + 16, 120)
        let nearTopCenter = loc.y >= screen.frame.maxY - topBandHeight
            && abs(loc.x - screen.frame.midX) <= horizontalHalfSpan

        if shelfState.isExpanded {
            refreshClipboardHint()
        }

        if nearTopCenter && !shelfState.isExpanded {
            if isMouseButtonDown || coordinator.notchHoverTriggerEnabled {
                expand(forDrag: isMouseButtonDown)
            }
        } else if shelfState.isExpanded, let panelFrame = panel?.frame {
            if shelfState.isDropTargeted || shelfState.statusBanner != nil || shelfState.processingMessage != nil {
                hideWorkItem?.cancel()
                return
            }
            let cardWidth = shelfState.expandedShapeWidth
            let cardHeight = shelfState.expandedCardHeight
            let activeCardRect = NSRect(
                x: panelFrame.midX - (cardWidth / 2.0) - 12,
                y: panelFrame.maxY - cardHeight - 12,
                width: cardWidth + 24,
                height: cardHeight + 12
            )
            if activeCardRect.contains(loc) || nearTopCenter {
                hideWorkItem?.cancel()
            } else if hideWorkItem == nil {
                scheduleAutoCollapse()
            }
        }
    }

    private func screenUnderCursor() -> NSScreen {
        let loc = NSEvent.mouseLocation
        return NSScreen.screens.first(where: { $0.frame.contains(loc) })
            ?? NSScreen.main
            ?? NSScreen.screens[0]
    }

    private func scheduleAutoCollapse(delay: TimeInterval = 0.55) {
        hideWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.hideWorkItem = nil
            self?.collapse()
        }
        hideWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    // MARK: - 3-Way Target Ingestion (Inbox / Folder / Active Moodboard)

    private func resolvedDropTargets() -> (folderID: UUID?, boardID: UUID?, destinationLabel: String) {
        switch shelfState.targetMode {
        case .inbox:
            return (nil, nil, "收件箱")
        case .folder:
            let folderID = shelfState.selectedFolderID ?? library.folders.first?.id
            let name = library.folders.first(where: { $0.id == folderID })?.name ?? "收件箱"
            return (folderID, nil, name)
        case .activeMoodboard:
            let boardID = coordinator.activeMoodboardID ?? moodboards.boards.first?.id
            let boardTitle = moodboards.boards.first(where: { $0.id == boardID })?.title ?? "活跃情绪板"
            // Single Source of Truth: new assets live in /Charkle/Inbox/ (folderID = nil) and attach to boardID
            return (nil, boardID, boardTitle)
        }
    }

    private func handleAppKitDrop(pasteboard: NSPasteboard, promiseReceivers: [NSFilePromiseReceiver]) -> Bool {
        let (targetFolderID, targetBoardID, destLabel) = resolvedDropTargets()

        // 1. Standard synchronous pasteboard payloads (files, images, URLs, X posts, hex colors, text)
        let directInputs = ClipboardCollector.extractInputs(from: pasteboard)
        if !directInputs.isEmpty {
            let hasXPost = directInputs.contains { input in
                if case .webURL(let url, _, _) = input { return XPostURLParser.parse(url) != nil }
                return false
            }
            notchLogger.info("NotchShelf received \(directInputs.count) payload(s) -> \(destLabel, privacy: .public)")
            if hasXPost {
                showProcessing("正在保存 X 推文及媒体…")
            }
            Task { @MainActor in
                let created = await library.ingest(
                    directInputs,
                    targetFolderID: targetFolderID,
                    targetBoardID: targetBoardID
                )
                if let boardID = targetBoardID {
                    await moodboards.reloadActiveBoardIfNeeded(id: boardID)
                    await moodboards.refreshBoards()
                }
                let count = max(created.count, directInputs.count)
                let message = hasXPost
                    ? "已保存 X 推文及媒体至「\(destLabel)」(\(count) 项)"
                    : "已收入「\(destLabel)」(\(count) 项)"
                flashConfirmation(message)
            }
            return true
        }

        // 2. File promises (Photos.app, Safari dragged images, Mail attachments)
        if !promiseReceivers.isEmpty {
            let tempDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("charkle-drop-\(UUID().uuidString)", isDirectory: true)
            try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            for receiver in promiseReceivers {
                receiver.receivePromisedFiles(atDestination: tempDir, options: [:], operationQueue: promiseQueue) { [weak self] fileURL, error in
                    guard error == nil, let self else { return }
                    Task { @MainActor in
                        _ = await self.library.ingest(
                            [.fileURL(fileURL)],
                            targetFolderID: targetFolderID,
                            targetBoardID: targetBoardID
                        )
                        if let boardID = targetBoardID {
                            await self.moodboards.reloadActiveBoardIfNeeded(id: boardID)
                            await self.moodboards.refreshBoards()
                        }
                        self.flashConfirmation("已收入「\(destLabel)」")
                        try? FileManager.default.removeItem(at: fileURL)
                    }
                }
            }
            return true
        }

        return false
    }

    isolated deinit {
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
        }
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
        }
        pollTimer?.invalidate()
        bannerResetTask?.cancel()
        hideWorkItem?.cancel()
        sensorWindow?.orderOut(nil)
        panel?.orderOut(nil)
    }
}
