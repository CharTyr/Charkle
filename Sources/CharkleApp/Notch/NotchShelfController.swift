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
    /// Visible black notch capsule rect in **unflipped AppKit window coordinates** (`y = 0` at bottom of panel,
    /// `y = window.frame.height` at top screen bezel). Avoids `NSHostingView.isFlipped` mismatch when the
    /// backing panel is taller than the compact capsule.
    var activeWindowRectProvider: (() -> NSRect)?

    private static let supportedTypes: [NSPasteboard.PasteboardType] = {
        var types: [NSPasteboard.PasteboardType] = [
            .fileURL,
            NSPasteboard.PasteboardType("NSFilenamesPboardType"),
            .URL,
            NSPasteboard.PasteboardType("public.url"),
            .png,
            .tiff,
            NSPasteboard.PasteboardType(UTType.jpeg.identifier),
            NSPasteboard.PasteboardType(UTType.gif.identifier),
            NSPasteboard.PasteboardType(UTType.webP.identifier),
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
        guard let activeWindowRect = activeWindowRectProvider?(), !activeWindowRect.isEmpty else {
            return nil
        }
        let windowPoint = superview?.convert(point, to: nil) ?? convert(point, to: nil)
        guard activeWindowRect.contains(windowPoint) else {
            return nil
        }
        return super.hitTest(point)
    }

    private var cachedDragChangeCount: Int = -1
    private var cachedDragIsInternal: Bool = false
    private var cachedDragItemCount: Int = 1
    private var lastReportedInsideCard: Bool = false

    private func inspectPasteboardIfNeeded(_ pasteboard: NSPasteboard) {
        let count = pasteboard.changeCount
        guard count != cachedDragChangeCount else { return }
        cachedDragChangeCount = count
        if let rawString = pasteboard.string(forType: .string), CharkleDragIdentifiers.isInternalDrag(rawString) {
            cachedDragIsInternal = true
            cachedDragItemCount = 0
        } else {
            cachedDragIsInternal = false
            cachedDragItemCount = max(1, pasteboard.pasteboardItems?.count ?? 1)
        }
    }

    private func acceptsDrag(_ sender: any NSDraggingInfo) -> Bool {
        inspectPasteboardIfNeeded(sender.draggingPasteboard)
        guard !cachedDragIsInternal else { return false }
        guard let activeWindowRect = activeWindowRectProvider?(), !activeWindowRect.isEmpty else { return false }
        // `sender.draggingLocation` is already in unflipped AppKit window coordinates.
        return activeWindowRect.contains(sender.draggingLocation)
    }

    override func wantsPeriodicDraggingUpdates() -> Bool {
        false
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard acceptsDrag(sender) else {
            if lastReportedInsideCard {
                lastReportedInsideCard = false
                onDragExited?()
            }
            return []
        }
        if !lastReportedInsideCard {
            lastReportedInsideCard = true
            onDragEntered?(cachedDragItemCount)
        }
        return .copy
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard acceptsDrag(sender) else {
            if lastReportedInsideCard {
                lastReportedInsideCard = false
                onDragExited?()
            }
            return []
        }
        if !lastReportedInsideCard {
            lastReportedInsideCard = true
            onDragEntered?(cachedDragItemCount)
        }
        return .copy
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        if lastReportedInsideCard {
            lastReportedInsideCard = false
            onDragExited?()
        }
    }

    override func draggingEnded(_ sender: any NSDraggingInfo) {
        lastReportedInsideCard = false
        onDragExited?()
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard acceptsDrag(sender) else {
            lastReportedInsideCard = false
            onDragExited?()
            return false
        }
        lastReportedInsideCard = false
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
    var onHoverExited: (() -> Void)?
    var onPerformDrop: ((NSPasteboard, [NSFilePromiseReceiver]) -> Bool)?

    private var trackingAreaRef: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        var types: [NSPasteboard.PasteboardType] = [
            .fileURL,
            NSPasteboard.PasteboardType("NSFilenamesPboardType"),
            .URL,
            NSPasteboard.PasteboardType("public.url"),
            .png,
            .tiff,
            NSPasteboard.PasteboardType(UTType.jpeg.identifier),
            NSPasteboard.PasteboardType(UTType.gif.identifier),
            NSPasteboard.PasteboardType(UTType.webP.identifier),
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

    override func mouseExited(with event: NSEvent) {
        onHoverExited?()
    }

    private var cachedSensorChangeCount: Int = -1
    private var cachedSensorIsInternal: Bool = false
    private var cachedSensorItemCount: Int = 1

    private func inspectSensorPasteboard(_ pasteboard: NSPasteboard) {
        let count = pasteboard.changeCount
        guard count != cachedSensorChangeCount else { return }
        cachedSensorChangeCount = count
        if let rawString = pasteboard.string(forType: .string), CharkleDragIdentifiers.isInternalDrag(rawString) {
            cachedSensorIsInternal = true
            cachedSensorItemCount = 0
        } else {
            cachedSensorIsInternal = false
            cachedSensorItemCount = max(1, pasteboard.pasteboardItems?.count ?? 1)
        }
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        inspectSensorPasteboard(sender.draggingPasteboard)
        guard !cachedSensorIsInternal else { return [] }
        onTriggerOpenForDrag?(cachedSensorItemCount)
        return .copy
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        inspectSensorPasteboard(sender.draggingPasteboard)
        guard !cachedSensorIsInternal else { return [] }
        return .copy
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        onDragExited?()
    }

    override func draggingEnded(_ sender: any NSDraggingInfo) {
        onDragExited?()
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        inspectSensorPasteboard(sender.draggingPasteboard)
        guard !cachedSensorIsInternal else {
            onDragExited?()
            return false
        }
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
    private var hoverExpandWorkItem: DispatchWorkItem?
    private var bannerResetTask: Task<Void, Never>?
    private let promiseQueue = OperationQueue()

    private var isSensorDragging = false
    private var isPanelDragging = false
    private var lastObservedGeneralPasteboardChangeCount: Int = -1
    private var lastObservedDragPasteboardChangeCount: Int = -1
    private var baselineDragChangeCount: Int = NSPasteboard(name: .drag).changeCount
    private var lastBaselineSyncTime: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()
    private var wasMouseButtonDown: Bool = false
    private var cachedDragPBIsInternal: Bool = false
    private var cachedDragPBHasDroppable: Bool = false
    private var lastAnchoredScreenFrame: NSRect = .zero
    private var lastSensorScreenFrame: NSRect = .zero
    private var lastObservedNotchEnabled: Bool = true
    private var screenObserver: (any NSObjectProtocol)?
    private var keyMonitor: Any?

    private static let shelfWindowLevel = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) + 4)
    private static let sensorWindowLevel = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) + 3)

    // Keep transparent margin tight (~2.5× shadow blur) so drop shadows feather cleanly
    // while minimizing transparent overhang beyond the visible black notch capsule.
    private static let shadowHorizontalMargin: CGFloat = 48
    private static let shadowBottomMargin: CGFloat = 56

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
        self.shelfState.targetMode = coordinator.defaultNotchTargetMode

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
            // Keep explicitly toggled Notch Shelf open (via ⌥⇧S hotkey, Menu Bar, or Preview button)
            // even when the cursor is elsewhere on screen; pressing ⌥⇧S / Esc / × or unpinning dismisses it.
            expand(forDrag: false, pinOpen: true)
        }
    }

    public func expand(forDrag: Bool = false, pinOpen: Bool = false) {
        guard coordinator.notchShelfEnabled else { return }
        hideWorkItem?.cancel()
        cancelHoverExpand()
        anchorFixedPanelIfScreenChanged()
        refreshClipboardHint(force: true)
        guard let panel else { return }

        panel.ignoresMouseEvents = false
        if !panel.isVisible {
            panel.orderFrontRegardless()
        }
        if pinOpen {
            shelfState.isPinnedOpen = true
        }
        shelfState.isExpanded = true
    }

    public func collapse() {
        guard shelfState.isExpanded else { return }
        if shelfState.isDropTargeted || shelfState.processingMessage != nil { return }
        hideWorkItem?.cancel()
        cancelHoverExpand()
        shelfState.isExpanded = false
        shelfState.isFullGalleryExpanded = false
        shelfState.isPinnedOpen = false
        baselineDragChangeCount = NSPasteboard(name: .drag).changeCount
        lastBaselineSyncTime = CFAbsoluteTimeGetCurrent()
        // Immediately let pointer events pass through to underlying apps even during spring settle.
        // Never resize the backing NSPanel here so the closing spring never clips or hitches.
        panel?.ignoresMouseEvents = true
    }

    private func scheduleHoverExpand() {
        guard !shelfState.isExpanded,
              coordinator.notchShelfEnabled,
              coordinator.notchHoverTriggerEnabled,
              NSEvent.pressedMouseButtons == 0,
              hoverExpandWorkItem == nil else { return }

        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.hoverExpandWorkItem = nil
            guard !self.shelfState.isExpanded,
                  self.coordinator.notchShelfEnabled,
                  self.coordinator.notchHoverTriggerEnabled,
                  NSEvent.pressedMouseButtons == 0 else { return }
            let loc = NSEvent.mouseLocation
            let screen = self.screenUnderCursor(at: loc)
            let metrics = self.notchMetrics(for: screen)
            let stillInHover = NotchDropGeometry.isPointInHoverTriggerZone(
                loc,
                screenFrame: screen.frame,
                hasPhysicalNotch: metrics.hasPhysicalNotch,
                notchWidth: metrics.notchWidth,
                notchHeight: metrics.notchHeight
            )
            if stillInHover {
                self.expand(forDrag: false)
            }
        }
        hoverExpandWorkItem = item
        // 240ms dwell debounce prevents accidental pop-open when casually moving past the menu bar/notch
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.24, execute: item)
    }

    private func cancelHoverExpand() {
        hoverExpandWorkItem?.cancel()
        hoverExpandWorkItem = nil
    }

    public func toggleFullGallery(_ expanded: Bool) {
        shelfState.isFullGalleryExpanded = expanded
        if expanded {
            shelfState.isPinnedOpen = true
        }
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
            onToggleFullGallery: { [weak self] full in
                self?.toggleFullGallery(full)
            },
            onOpenAssetInQuickLook: { [weak self] asset in
                guard let self else { return }
                self.library.markAssetOpened(asset.id)
                self.collapse()
                self.onOpenMainWindow()
                self.library.selectedAssetIDs = [asset.id]
                self.coordinator.openQuickLook(assetID: asset.id, playlist: [asset.id])
            },
            onResolveDragFileURL: { [weak self] assetID in
                guard let self else { return nil }
                return self.library.engine.cachedThumbnailURL(for: assetID, tier: .preview1400)
                    ?? self.library.engine.cachedThumbnailURL(for: assetID, tier: .grid520)
            },
            onClose: { [weak self] in
                self?.collapse()
            }
        )

        let initialPanelWidth = shelfState.maxPanelShapeWidth + Self.shadowHorizontalMargin * 2
        let initialPanelHeight = shelfState.maxPanelCardHeight + Self.shadowBottomMargin

        let hosting = NotchDropHostingView(rootView: rootView)
        hosting.frame = NSRect(x: 0, y: 0, width: initialPanelWidth, height: initialPanelHeight)
        hosting.autoresizingMask = [.width, .height]

        hosting.onDragEntered = { [weak self] count in
            guard let self else { return }
            self.hideWorkItem?.cancel()
            if self.shelfState.dragItemCount != count {
                self.shelfState.dragItemCount = count
            }
            if !self.isPanelDragging {
                self.isPanelDragging = true
                self.syncDropTargetedState()
            }
        }
        hosting.onDragExited = { [weak self] in
            guard let self, self.isPanelDragging else { return }
            self.isPanelDragging = false
            self.syncDropTargetedState()
        }
        hosting.onPerformDrop = { [weak self] pasteboard, receivers in
            guard let self else { return false }
            return self.handleAppKitDrop(pasteboard: pasteboard, promiseReceivers: receivers)
        }
        hosting.activeWindowRectProvider = { [weak self, weak hosting] in
            guard let self, let hosting, self.shelfState.isExpanded else { return .zero }
            let panelSize = hosting.window?.frame.size ?? hosting.bounds.size
            return NotchDropGeometry.strictCardRect(
                panelBounds: NSRect(origin: .zero, size: panelSize),
                bodyWidth: self.shelfState.expandedBodyWidth,
                cardHeight: self.shelfState.expandedCardHeight
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
        if abs(shelfState.activeScreenWidth - screen.frame.width) > 1 {
            shelfState.activeScreenWidth = screen.frame.width
        }
        if abs(shelfState.activeScreenHeight - screen.frame.height) > 1 {
            shelfState.activeScreenHeight = screen.frame.height
        }

        let panelWidth = shelfState.maxPanelShapeWidth + Self.shadowHorizontalMargin * 2
        let panelHeight = shelfState.maxPanelCardHeight + Self.shadowBottomMargin
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
            self.scheduleHoverExpand()
        }
        sensorView.onHoverExited = { [weak self] in
            self?.cancelHoverExpand()
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

    private func repositionSensorWindow(for precomputedScreen: NSScreen? = nil) {
        guard let sensorWindow else { return }
        let enabled = coordinator.notchShelfEnabled
        guard enabled else {
            if lastObservedNotchEnabled || sensorWindow.isVisible {
                lastObservedNotchEnabled = false
                sensorWindow.orderOut(nil)
            }
            return
        }
        let screen = precomputedScreen ?? screenUnderCursor()
        if lastObservedNotchEnabled, lastSensorScreenFrame == screen.frame, sensorWindow.isVisible {
            return
        }
        lastObservedNotchEnabled = true
        lastSensorScreenFrame = screen.frame
        let metrics = notchMetrics(for: screen)
        let sensorWidth: CGFloat = metrics.hasPhysicalNotch ? (metrics.notchWidth + 12) : 210
        let sensorHeight: CGFloat = metrics.hasPhysicalNotch ? max(metrics.notchHeight, 34) : 6
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
        let timer = Timer.scheduledTimer(withTimeInterval: 0.10, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.pollCursorAndDragState()
            }
        }
        timer.tolerance = 0.04
        pollTimer = timer
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
            NSPasteboard.PasteboardType("public.url"),
            .png,
            .tiff,
            NSPasteboard.PasteboardType(UTType.jpeg.identifier),
            NSPasteboard.PasteboardType(UTType.gif.identifier),
            NSPasteboard.PasteboardType(UTType.webP.identifier),
            NSPasteboard.PasteboardType(UTType.image.identifier),
            NSPasteboard.PasteboardType("com.apple.NSFilePromiseItemMetaData")
        ]
        if types.contains(where: { accepted.contains($0) }) {
            return true
        }
        if let text = pb.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
           text.hasPrefix("http://") || text.hasPrefix("https://") {
            return URL(string: text) != nil
        }
        return false
    }

    private func inspectSystemDragPasteboard() -> (changeCount: Int, isInternal: Bool, hasDroppable: Bool) {
        let dragPB = NSPasteboard(name: .drag)
        let cc = dragPB.changeCount
        if cc != lastObservedDragPasteboardChangeCount {
            lastObservedDragPasteboardChangeCount = cc
            let rawString = dragPB.string(forType: .string) ?? ""
            cachedDragPBIsInternal = CharkleDragIdentifiers.isInternalDrag(rawString)
            cachedDragPBHasDroppable = !cachedDragPBIsInternal && dragPasteboardHasDroppablePayload(dragPB)
        }
        return (cc, cachedDragPBIsInternal, cachedDragPBHasDroppable)
    }

    private func pollCursorAndDragState() {
        let enabled = coordinator.notchShelfEnabled
        let isMouseButtonDown = NSEvent.pressedMouseButtons != 0
        let now = CFAbsoluteTimeGetCurrent()

        // Keep idle drag-pasteboard baseline synced so stale files from past drags never trigger false opens
        // when the user later clicks browser tabs, menu bar items, or window title bars near the notch.
        if !isMouseButtonDown {
            if wasMouseButtonDown || (now - lastBaselineSyncTime) >= 0.5 {
                baselineDragChangeCount = NSPasteboard(name: .drag).changeCount
                lastBaselineSyncTime = now
            }
        }
        wasMouseButtonDown = isMouseButtonDown

        // Fast idle exit when collapsed, no button pressed, and hover-open disabled:
        // avoids iterating NSScreen.screens or computing notch metrics 10x/sec while idle.
        if !shelfState.isExpanded,
           enabled == lastObservedNotchEnabled,
           !isMouseButtonDown,
           !coordinator.notchHoverTriggerEnabled {
            cancelHoverExpand()
            return
        }

        let loc = NSEvent.mouseLocation
        let screen = screenUnderCursor(at: loc)
        repositionSensorWindow(for: screen)
        guard enabled else {
            cancelHoverExpand()
            if shelfState.isExpanded { collapse() }
            return
        }

        let metrics = notchMetrics(for: screen)

        let inDragTrigger = NotchDropGeometry.isPointInDragTriggerZone(
            loc,
            screenFrame: screen.frame,
            hasPhysicalNotch: metrics.hasPhysicalNotch,
            notchWidth: metrics.notchWidth,
            notchHeight: metrics.notchHeight
        )
        let inHoverTrigger = NotchDropGeometry.isPointInHoverTriggerZone(
            loc,
            screenFrame: screen.frame,
            hasPhysicalNotch: metrics.hasPhysicalNotch,
            notchWidth: metrics.notchWidth,
            notchHeight: metrics.notchHeight
        )

        if shelfState.isExpanded {
            refreshClipboardHint()
        }

        if !shelfState.isExpanded {
            if isMouseButtonDown && inDragTrigger {
                cancelHoverExpand()
                let state = inspectSystemDragPasteboard()
                if NotchDropGeometry.shouldTriggerProactiveDragExpand(
                    currentDragChangeCount: state.changeCount,
                    baselineDragChangeCount: baselineDragChangeCount,
                    isInternalDrag: state.isInternal,
                    hasDroppablePayload: state.hasDroppable
                ) {
                    expand(forDrag: true)
                }
            } else if !isMouseButtonDown && inHoverTrigger && coordinator.notchHoverTriggerEnabled {
                scheduleHoverExpand()
            } else {
                cancelHoverExpand()
            }
            return
        }

        // Re-anchor only if the user moved across displays (never resizes on compact <-> full toggle).
        if lastAnchoredScreenFrame.midX != screen.frame.midX || lastAnchoredScreenFrame.maxY != screen.frame.maxY {
            anchorFixedPanelIfScreenChanged()
        }

        guard let panelFrame = panel?.frame else { return }
        let strictCardRect = NotchDropGeometry.strictScreenCardRect(
            panelFrame: panelFrame,
            bodyWidth: shelfState.expandedBodyWidth,
            cardHeight: shelfState.expandedCardHeight
        )
        let insideActiveArea = strictCardRect.contains(loc) || (isMouseButtonDown ? inDragTrigger : inHoverTrigger)

        if !insideActiveArea && isPanelDragging {
            isPanelDragging = false
            syncDropTargetedState()
        }

        // If user dragged an internal asset OUT of the Notch Shelf onto another window, gently collapse once cursor exits
        if isMouseButtonDown && !insideActiveArea {
            let state = inspectSystemDragPasteboard()
            if state.changeCount != baselineDragChangeCount && state.isInternal {
                shelfState.isPinnedOpen = false
                collapse()
                return
            }
        }

        if shelfState.statusBanner != nil || shelfState.processingMessage != nil || isSensorDragging || shelfState.isPinnedOpen {
            hideWorkItem?.cancel()
            return
        }

        if insideActiveArea {
            hideWorkItem?.cancel()
        } else if hideWorkItem == nil {
            scheduleAutoCollapse(delay: isMouseButtonDown ? 0.14 : 0.45)
        }
    }

    private func screenUnderCursor(at location: NSPoint? = nil) -> NSScreen {
        let loc = location ?? NSEvent.mouseLocation
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
        hoverExpandWorkItem?.cancel()
        sensorWindow?.orderOut(nil)
        panel?.orderOut(nil)
    }
}
