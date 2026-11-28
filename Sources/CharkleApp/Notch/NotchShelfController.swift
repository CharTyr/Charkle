import AppKit
import CharkleCanvas
import CharkleCore
import SwiftUI
import UniformTypeIdentifiers
import os

private let notchLogger = Logger(subsystem: "com.charkle.app", category: "NotchShelf")

private nonisolated final class NotchPromiseBatchTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var remaining: Int
    private var succeededCount: Int = 0
    private var createdCount: Int = 0

    init(total: Int) {
        self.remaining = total
    }

    func record(succeeded: Bool, created: Int = 0) -> (done: Bool, totalSucceeded: Int, totalCreated: Int) {
        lock.lock()
        defer { lock.unlock() }
        if succeeded { succeededCount += 1 }
        createdCount += max(0, created)
        remaining -= 1
        return (remaining <= 0, succeededCount, createdCount)
    }
}

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
        if CharkleDragPasteboardResolver.isInternalDrag(pasteboard: pasteboard) {
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
        if CharkleDragPasteboardResolver.isInternalDrag(pasteboard: pasteboard) {
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
    private var sensorWindows: [NotchPanel] = []
    private var pollTimer: Timer?
    private var pollTimerInterval: TimeInterval = 0
    private var hideWorkItem: DispatchWorkItem?
    private var hoverExpandWorkItem: DispatchWorkItem?
    private var panelOrderOutWorkItem: DispatchWorkItem?
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
    private var cachedDragPBItemCount: Int = 1
    private var dragStartLocation: NSPoint?
    private var dragStartScreenFrame: NSRect?
    private var dragMotionSamples: [NotchDragMotionSample] = []
    private var lastImmediateDragEvalTime: CFAbsoluteTime = 0
    private var lastPredictiveDragExpandTime: CFAbsoluteTime = 0
    private var cachedDockPIDs: Set<pid_t> = []
    private var lastDockPIDRefreshTime: CFAbsoluteTime = 0
    private var lastMissionControlCheckTime: CFAbsoluteTime = 0
    private var isMissionControlActiveCached: Bool = false
    private var isHiddenForMissionControl: Bool = false
    private var lastAnchoredScreenFrame: NSRect = .zero
    private var lastSensorScreenFrames: [NSRect] = []
    private var lastObservedNotchEnabled: Bool = true
    private var lastObservedPresentationMode: NotchShelfPresentationMode = .alwaysShowRecent
    private var screenObserver: (any NSObjectProtocol)?
    private var activeSpaceObserver: (any NSObjectProtocol)?
    private var menuBeginObserver: (any NSObjectProtocol)?
    private var menuEndObserver: (any NSObjectProtocol)?
    private var isMenuTracking: Bool = false
    private var keyMonitor: Any?
    private var globalMouseMonitor: Any?
    private var localMouseMonitor: Any?
    private var isObservingSettings: Bool = false

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
        self.lastObservedPresentationMode = coordinator.notchPresentationMode
        self.shelfState.isRecentStripExpanded = NotchShelfState.shouldShowRecentStripOnExpand(
            presentationMode: coordinator.notchPresentationMode,
            trigger: .manual
        )

        promiseQueue.name = "com.charkle.notch.filepromises"
        createFixedPanel()
        repositionSensorWindows()
        if coordinator.notchShelfEnabled {
            installEventDrivenWatchers()
        }
        startObservingNotchSettings()

        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.anchorFixedPanelIfScreenChanged()
                self?.repositionSensorWindows()
            }
        }

        activeSpaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleActiveSpaceDidChange()
            }
        }

        menuBeginObserver = NotificationCenter.default.addObserver(
            forName: NSMenu.didBeginTrackingNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isMenuTracking = true
                self.cancelAutoCollapse()
            }
        }

        menuEndObserver = NotificationCenter.default.addObserver(
            forName: NSMenu.didEndTrackingNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isMenuTracking = false
                if self.shelfState.isExpanded && !self.shelfState.isPinnedOpen {
                    self.pollCursorAndDragState()
                }
            }
        }

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.shelfState.isExpanded else {
                return event
            }
            let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
            let isPanelKey = (self.panel?.isKeyWindow == true) || (event.window === self.panel)
            let isEditingInPanel: Bool = {
                guard let resp = self.panel?.firstResponder else { return false }
                return resp is NSTextView || resp is NSTextField || resp is NSText
            }()

            if isPanelKey, flags == .command, event.charactersIgnoringModifiers?.lowercased() == "v" {
                if isEditingInPanel {
                    return event
                }
                self.onCollectClipboard()
                return nil
            }
            if flags.isEmpty, event.keyCode == 53 { // Escape
                if isPanelKey && isEditingInPanel {
                    self.panel?.makeFirstResponder(nil)
                    return nil
                }
                if isPanelKey {
                    self.collapse(force: true)
                    return nil
                }
                // Only collapse from another Charkle window when no higher-priority modal, sheet,
                // alert, or active text editor owns Escape first.
                let keyWindow = NSApp.keyWindow
                let isEditingInKeyWindow: Bool = {
                    guard let resp = keyWindow?.firstResponder else { return false }
                    return resp is NSTextView || resp is NSTextField || resp is NSText
                }()
                let hasHigherPriorityModal = self.coordinator.isModalOverlayPresented
                    || NSApp.modalWindow != nil
                    || keyWindow?.attachedSheet != nil
                    || isEditingInKeyWindow
                if NSApp.isActive && !hasHigherPriorityModal {
                    self.collapse(force: true)
                    return nil
                }
            }
            return event
        }
    }

    public func setMinimalCaptureMode(_ enabled: Bool) {
        shelfState.isMinimalCaptureOnly = enabled
        if enabled {
            shelfState.isFullGalleryExpanded = false
            shelfState.isPinnedOpen = false
        }
    }

    public func toggle() {
        if shelfState.isExpanded {
            collapse(force: true)
        } else {
            // Keep explicitly toggled Notch Shelf open (via ⌥⇧S hotkey, Menu Bar, or Preview button)
            // even when the cursor is elsewhere on screen; pressing ⌥⇧S / Esc / × or unpinning dismisses it.
            expand(trigger: .manual, pinOpen: true)
        }
    }

    public func expand(forDrag: Bool = false, pinOpen: Bool = false) {
        let trigger: NotchExpandTrigger = forDrag ? .drag : (pinOpen ? .manual : .hover)
        expand(trigger: trigger, pinOpen: pinOpen)
    }

    public func expand(trigger: NotchExpandTrigger, pinOpen: Bool = false) {
        guard coordinator.notchShelfEnabled, !isHiddenForMissionControl else { return }
        let forDrag = (trigger == .drag)
        let wasExpanded = shelfState.isExpanded
        cancelAutoCollapse()
        cancelHoverExpand()
        cancelPanelOrderOut()
        anchorFixedPanelIfScreenChanged()
        refreshClipboardHint(force: !forDrag)
        guard let panel else { return }

        if !wasExpanded {
            shelfState.isFullGalleryExpanded = false
            shelfState.isRecentStripExpanded = NotchShelfState.shouldShowRecentStripOnExpand(
                presentationMode: coordinator.notchPresentationMode,
                trigger: trigger
            )
        }

        panel.ignoresMouseEvents = false
        if !panel.isVisible {
            panel.orderFrontRegardless()
        }
        if pinOpen && !forDrag {
            panel.makeKey()
        }
        if pinOpen {
            shelfState.isPinnedOpen = true
        }
        shelfState.isExpanded = true
        let isDraggingNow = forDrag || NSEvent.pressedMouseButtons != 0
        if shelfState.isPinnedOpen && !isDraggingNow && !isHiddenForMissionControl {
            stopPollTimer()
        } else {
            ensurePollTimerRunning(fastForDrag: isDraggingNow)
        }
    }

    public func setRecentStripExpanded(_ expanded: Bool) {
        cancelAutoCollapse()
        if !expanded {
            shelfState.isFullGalleryExpanded = false
        }
        shelfState.isRecentStripExpanded = expanded
    }

    public func collapse(force: Bool = false) {
        guard shelfState.isExpanded else { return }
        if !force && (shelfState.isDropTargeted || shelfState.processingMessage != nil || isMenuTracking) { return }
        cancelAutoCollapse()
        cancelHoverExpand()
        shelfState.isExpanded = false
        shelfState.isFullGalleryExpanded = false
        shelfState.isPinnedOpen = false
        baselineDragChangeCount = NSPasteboard(name: .drag).changeCount
        lastBaselineSyncTime = CFAbsoluteTimeGetCurrent()
        // Immediately let pointer events pass through to underlying apps even during spring settle.
        // Never resize the backing NSPanel here so the closing spring never clips or hitches;
        // once the closing spring settles, orderOut releases the oversized CoreAnimation backing store.
        panel?.ignoresMouseEvents = true
        schedulePanelOrderOut()
        if NSEvent.pressedMouseButtons == 0 && !isHiddenForMissionControl {
            stopPollTimer()
        }
    }

    private func schedulePanelOrderOut() {
        cancelPanelOrderOut()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.panelOrderOutWorkItem = nil
            guard !self.shelfState.isExpanded else { return }
            self.panel?.orderOut(nil)
        }
        panelOrderOutWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: item)
    }

    private func cancelPanelOrderOut() {
        panelOrderOutWorkItem?.cancel()
        panelOrderOutWorkItem = nil
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
            guard let screen = self.screenUnderCursor(at: loc) else { return }
            let metrics = self.notchMetrics(for: screen)
            let stillInHover = NotchDropGeometry.isPointInHoverTriggerZone(
                loc,
                screenFrame: screen.frame,
                hasPhysicalNotch: metrics.hasPhysicalNotch,
                notchWidth: metrics.notchWidth,
                notchHeight: metrics.notchHeight
            )
            if stillInHover {
                self.expand(trigger: .hover)
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
        if expanded && shelfState.isMinimalCaptureOnly {
            return
        }
        if expanded {
            shelfState.isRecentStripExpanded = true
        }
        shelfState.isFullGalleryExpanded = expanded
        if expanded {
            shelfState.isPinnedOpen = true
            if NSEvent.pressedMouseButtons == 0 && !isHiddenForMissionControl && !isSensorDragging && !isPanelDragging {
                stopPollTimer()
            }
        }
    }

    /// Shows an active in-progress spinner in the Notch Shelf (e.g. while downloading X post media).
    public func showProcessing(_ message: String) {
        expand(trigger: .statusBanner)
        bannerResetTask?.cancel()
        cancelAutoCollapse()
        shelfState.statusBanner = nil
        shelfState.processingMessage = message
    }

    /// Shows a brief confirmation in the Notch Shelf (e.g. after screenshot, clipboard, or X post collect).
    public func flashConfirmation(_ message: String) {
        expand(trigger: .statusBanner)
        bannerResetTask?.cancel()
        shelfState.processingMessage = nil
        shelfState.statusBanner = message
        shelfState.lastDropTimestamp = Date()
        cancelAutoCollapse()
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
        let detected = ClipboardCollector.detectedClipboardLink(from: .general)
        shelfState.clipboardLink = detected
        if case .social(let url) = detected {
            shelfState.clipboardXPostURL = url
        } else {
            shelfState.clipboardXPostURL = nil
        }
    }

    // MARK: - Fixed Oversized Transparent NSPanel Setup

    private func createFixedPanel() {
        let rootView = NotchShelfView(
            shelfState: shelfState,
            coordinator: coordinator,
            library: library,
            moodboards: moodboards,
            onCaptureArea: { [weak self] in
                self?.collapse(force: true)
                self?.onCaptureArea()
            },
            onCollectClipboard: { [weak self] in
                self?.onCollectClipboard()
            },
            onOpenMainWindow: { [weak self] in
                self?.collapse(force: true)
                self?.onOpenMainWindow()
            },
            onToggleFullGallery: { [weak self] full in
                self?.toggleFullGallery(full)
            },
            onToggleRecentStrip: { [weak self] showRecent in
                self?.setRecentStripExpanded(showRecent)
            },
            onOpenAssetInQuickLook: { [weak self] asset in
                guard let self else { return }
                self.library.markAssetOpened(asset.id)
                self.collapse(force: true)
                if asset.isExternalWebLink, let url = asset.externalWebURL {
                    NSWorkspace.shared.open(url)
                    return
                }
                self.onOpenMainWindow()
                self.library.selectedAssetIDs = [asset.id]
                self.coordinator.openQuickLook(assetID: asset.id, playlist: [asset.id])
            },
            onResolveDragFileURL: { [weak self] assetID in
                guard let self else { return nil }
                if let asset = self.library.allAssetsByID[assetID],
                   let origURL = self.library.engine.cachedOriginalURL(for: asset) {
                    return origURL
                }
                return self.library.engine.cachedThumbnailURL(for: assetID, tier: .preview1400)
                    ?? self.library.engine.cachedThumbnailURL(for: assetID, tier: .grid520)
            },
            onClose: { [weak self] in
                self?.collapse(force: true)
            }
        )

        let initialPanelWidth = shelfState.maxPanelShapeWidth + Self.shadowHorizontalMargin * 2
        let initialPanelHeight = shelfState.maxPanelCardHeight + Self.shadowBottomMargin

        let hosting = NotchDropHostingView(rootView: rootView)
        hosting.frame = NSRect(x: 0, y: 0, width: initialPanelWidth, height: initialPanelHeight)
        hosting.autoresizingMask = [.width, .height]

        hosting.onDragEntered = { [weak self] count in
            guard let self else { return }
            self.cancelAutoCollapse()
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
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.worksWhenModal = true
        panel.isMovableByWindowBackground = false
        panel.ignoresMouseEvents = true
        self.panel = panel

        // Stay ordered out until first expand() so macOS doesn't retain an ~11 MB backing store while idle.
        anchorFixedPanelIfScreenChanged()
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
        guard let panel, let screen = screenUnderCursor() else { return }
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

    private func makeSensorWindow() -> NotchPanel {
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
        sensor.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        sensor.hidesOnDeactivate = false
        sensor.worksWhenModal = true
        sensor.ignoresMouseEvents = false
        return sensor
    }

    /// Maintains one lightweight top-bezel sensor panel per connected `NSScreen` so hover & drag
    /// detection works across multi-display setups with zero `.mouseMoved` global event monitoring.
    private func repositionSensorWindows() {
        let enabled = coordinator.notchShelfEnabled && !isHiddenForMissionControl
        guard enabled else {
            if lastObservedNotchEnabled || sensorWindows.contains(where: \.isVisible) {
                lastObservedNotchEnabled = false
                for window in sensorWindows {
                    window.orderOut(nil)
                }
            }
            return
        }

        let screens = NSScreen.screens
        guard !screens.isEmpty else { return }
        let targetRects: [NSRect] = screens.map { screen in
            let metrics = notchMetrics(for: screen)
            let sensorWidth: CGFloat = metrics.hasPhysicalNotch ? (metrics.notchWidth + 12) : 210
            let sensorHeight: CGFloat = metrics.hasPhysicalNotch ? max(metrics.notchHeight, 34) : 6
            return NSRect(
                x: screen.frame.midX - sensorWidth / 2.0,
                y: screen.frame.maxY - sensorHeight,
                width: sensorWidth,
                height: sensorHeight
            )
        }

        if lastObservedNotchEnabled,
           lastSensorScreenFrames == targetRects,
           sensorWindows.count == screens.count,
           sensorWindows.allSatisfy(\.isVisible) {
            return
        }

        while sensorWindows.count < screens.count {
            sensorWindows.append(makeSensorWindow())
        }
        while sensorWindows.count > screens.count {
            let removed = sensorWindows.removeLast()
            removed.orderOut(nil)
        }

        for (window, rect) in zip(sensorWindows, targetRects) {
            if window.frame != rect {
                window.setFrame(rect, display: false)
            }
            if !window.isVisible {
                window.orderFrontRegardless()
            }
        }
        lastObservedNotchEnabled = true
        lastSensorScreenFrames = targetRects
    }

    // MARK: - Event-Driven Drag & Cursor Watcher (0Hz Idle, Mission Control Avoidance)

    private func startObservingNotchSettings() {
        guard !isObservingSettings else { return }
        isObservingSettings = true
        trackNotchSettingsLoop()
    }

    private func trackNotchSettingsLoop() {
        withObservationTracking {
            _ = coordinator.notchShelfEnabled
            _ = coordinator.notchHoverTriggerEnabled
            _ = coordinator.notchPresentationMode
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.syncNotchEnabledState()
                self.trackNotchSettingsLoop()
            }
        }
    }

    private func syncNotchEnabledState() {
        let enabled = coordinator.notchShelfEnabled
        let mode = coordinator.notchPresentationMode
        if mode != lastObservedPresentationMode {
            lastObservedPresentationMode = mode
            if shelfState.isExpanded && !shelfState.isFullGalleryExpanded && !isSensorDragging && !isPanelDragging {
                shelfState.isRecentStripExpanded = NotchShelfState.shouldShowRecentStripOnExpand(
                    presentationMode: mode,
                    trigger: .manual
                )
            }
        }
        if !enabled {
            cancelHoverExpand()
            collapse(force: true)
            cancelPanelOrderOut()
            panel?.orderOut(nil)
            isHiddenForMissionControl = false
            resetDragMotionTracking()
            stopPollTimer()
            removeEventDrivenWatchers()
        } else {
            installEventDrivenWatchers()
        }
        repositionSensorWindows()
    }

    private func installEventDrivenWatchers() {
        guard globalMouseMonitor == nil && localMouseMonitor == nil else { return }
        // Only observe drag/click lifecycle events — never `.mouseMoved` — so cursor movement
        // across other apps causes zero wakeups (true 0Hz idle CPU).
        let dragEvents: NSEvent.EventTypeMask = [.leftMouseDown, .leftMouseDragged, .leftMouseUp]
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: dragEvents) { [weak self] event in
            MainActor.assumeIsolated {
                self?.handleObservedMouseEvent(event)
            }
        }
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: dragEvents) { [weak self] event in
            self?.handleObservedMouseEvent(event)
            return event
        }
    }

    private func removeEventDrivenWatchers() {
        if let globalMouseMonitor {
            NSEvent.removeMonitor(globalMouseMonitor)
            self.globalMouseMonitor = nil
        }
        if let localMouseMonitor {
            NSEvent.removeMonitor(localMouseMonitor)
            self.localMouseMonitor = nil
        }
    }

    private func resetDragMotionTracking() {
        dragStartLocation = nil
        dragStartScreenFrame = nil
        dragMotionSamples.removeAll(keepingCapacity: true)
        lastImmediateDragEvalTime = 0
    }

    private func recordDragMotionSample(location: NSPoint, screenFrame: NSRect, now: CFAbsoluteTime) {
        if dragStartLocation == nil || dragStartScreenFrame != screenFrame {
            dragStartLocation = location
            dragStartScreenFrame = screenFrame
            dragMotionSamples.removeAll(keepingCapacity: true)
        }
        if let last = dragMotionSamples.last,
           abs(last.location.x - location.x) < 0.5,
           abs(last.location.y - location.y) < 0.5,
           now - last.timestamp < 0.012 {
            return
        }
        dragMotionSamples.append(NotchDragMotionSample(location: location, timestamp: now))
        let cutoff = now - 0.24
        if dragMotionSamples.count > 24 || (dragMotionSamples.first?.timestamp ?? now) < cutoff {
            dragMotionSamples.removeAll { $0.timestamp < cutoff }
            if dragMotionSamples.count > 24 {
                dragMotionSamples.removeFirst(dragMotionSamples.count - 24)
            }
        }
    }

    private func refreshDockPIDsIfNeeded(now: CFAbsoluteTime, force: Bool = false) {
        if !force && !cachedDockPIDs.isEmpty && (now - lastDockPIDRefreshTime) < 5.0 {
            return
        }
        cachedDockPIDs = Set(
            NSRunningApplication
                .runningApplications(withBundleIdentifier: "com.apple.dock")
                .map(\.processIdentifier)
        )
        lastDockPIDRefreshTime = now
    }

    private func isMissionControlActive(now: CFAbsoluteTime, force: Bool = false) -> Bool {
        if !force && (now - lastMissionControlCheckTime) < 0.16 {
            return isMissionControlActiveCached
        }
        lastMissionControlCheckTime = now
        refreshDockPIDsIfNeeded(now: now, force: force)
        guard !cachedDockPIDs.isEmpty else {
            isMissionControlActiveCached = false
            return false
        }
        guard let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else {
            isMissionControlActiveCached = false
            return false
        }
        var dockWindows: [NotchDockWindowSnapshot] = []
        dockWindows.reserveCapacity(4)
        for info in windowList {
            guard let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                  cachedDockPIDs.contains(pid),
                  let layer = info[kCGWindowLayer as String] as? Int else {
                continue
            }
            let sharing = (info[kCGWindowSharingState as String] as? Int) ?? 0
            let boundsDict = info[kCGWindowBounds as String] as? NSDictionary
            let bounds = boundsDict.flatMap { CGRect(dictionaryRepresentation: $0) } ?? .zero
            dockWindows.append(NotchDockWindowSnapshot(layer: layer, sharingState: sharing, bounds: bounds))
        }
        let active = NotchDropGeometry.containsMissionControlOverlay(dockWindows: dockWindows)
        isMissionControlActiveCached = active
        return active
    }

    private func updateMissionControlYieldState(now: CFAbsoluteTime, forceCheck: Bool = false) -> Bool {
        let active = isMissionControlActive(now: now, force: forceCheck)
        if active {
            if !isHiddenForMissionControl {
                isHiddenForMissionControl = true
                cancelHoverExpand()
                cancelAutoCollapse()
                if shelfState.isExpanded {
                    collapse(force: true)
                }
                cancelPanelOrderOut()
                panel?.orderOut(nil)
                repositionSensorWindows()
            }
            ensurePollTimerRunning(fastForDrag: false)
            return true
        }
        if isHiddenForMissionControl {
            isHiddenForMissionControl = false
            repositionSensorWindows()
        }
        return false
    }

    private func handleActiveSpaceDidChange() {
        let now = CFAbsoluteTimeGetCurrent()
        if shelfState.isExpanded && !shelfState.isPinnedOpen && shelfState.processingMessage == nil {
            collapse(force: true)
        }
        _ = updateMissionControlYieldState(now: now, forceCheck: true)
        if !isHiddenForMissionControl {
            anchorFixedPanelIfScreenChanged()
            repositionSensorWindows()
        }
    }

    private func handleObservedMouseEvent(_ event: NSEvent) {
        guard coordinator.notchShelfEnabled else { return }
        let now = CFAbsoluteTimeGetCurrent()
        switch event.type {
        case .leftMouseDown:
            // Record pre-drag pasteboard baseline and start coordinates without waking any idle timer on clicks.
            let loc = NSEvent.mouseLocation
            resetDragMotionTracking()
            if let screen = screenUnderCursor(at: loc) {
                dragStartLocation = loc
                dragStartScreenFrame = screen.frame
                dragMotionSamples.append(NotchDragMotionSample(location: loc, timestamp: now))
            }
            if !shelfState.isExpanded && pollTimer == nil {
                baselineDragChangeCount = NSPasteboard(name: .drag).changeCount
                lastBaselineSyncTime = now
            } else if shelfState.isExpanded {
                refreshClipboardHint()
            }
        case .leftMouseDragged:
            ensurePollTimerRunning(fastForDrag: true)
            // Zero-latency direct evaluation (throttled to ~60Hz) so upward drags open the shelf well below
            // the menu bar instead of waiting for a slow timer tick and colliding with macOS Mission Control.
            if now - lastImmediateDragEvalTime >= 0.016 {
                lastImmediateDragEvalTime = now
                pollCursorAndDragState()
            }
        case .leftMouseUp:
            resetDragMotionTracking()
            if !shelfState.isExpanded {
                baselineDragChangeCount = NSPasteboard(name: .drag).changeCount
                lastBaselineSyncTime = now
                if !isHiddenForMissionControl {
                    stopPollTimer()
                }
            } else {
                // Re-evaluate after SwiftUI button actions settle (e.g. unpinning the shelf) so
                // hover auto-collapse resumes immediately without leaving the timer stopped.
                DispatchQueue.main.async { [weak self] in
                    self?.pollCursorAndDragState()
                }
            }
        default:
            break
        }
    }

    private func ensurePollTimerRunning(fastForDrag: Bool = false) {
        guard coordinator.notchShelfEnabled else { return }
        let desiredInterval: TimeInterval
        let desiredTolerance: TimeInterval
        if fastForDrag {
            desiredInterval = 0.033
            desiredTolerance = 0.01
        } else if isHiddenForMissionControl {
            desiredInterval = 0.25
            desiredTolerance = 0.08
        } else {
            desiredInterval = 0.10
            desiredTolerance = 0.04
        }

        if pollTimer != nil, abs(pollTimerInterval - desiredInterval) <= 0.005 {
            return
        }
        pollTimer?.invalidate()
        pollTimerInterval = desiredInterval
        let timer = Timer.scheduledTimer(withTimeInterval: desiredInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.pollCursorAndDragState()
            }
        }
        timer.tolerance = desiredTolerance
        pollTimer = timer
    }

    private func stopPollTimer() {
        pollTimer?.invalidate()
        pollTimer = nil
        pollTimerInterval = 0
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
            NSPasteboard.PasteboardType("WebURLsWithTitlesPboardType"),
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
        if let text = pb.string(forType: .string),
           WebURLParser.extractWebURL(from: text) != nil {
            return true
        }
        return false
    }

    private func inspectSystemDragPasteboard() -> (changeCount: Int, isInternal: Bool, hasDroppable: Bool, itemCount: Int) {
        let dragPB = NSPasteboard(name: .drag)
        let cc = dragPB.changeCount
        if cc != lastObservedDragPasteboardChangeCount {
            lastObservedDragPasteboardChangeCount = cc
            let rawString = dragPB.string(forType: .string) ?? ""
            cachedDragPBIsInternal = CharkleDragIdentifiers.isInternalDrag(rawString)
            cachedDragPBHasDroppable = !cachedDragPBIsInternal && dragPasteboardHasDroppablePayload(dragPB)
            cachedDragPBItemCount = cachedDragPBIsInternal ? 0 : max(1, dragPB.pasteboardItems?.count ?? 1)
        }
        return (cc, cachedDragPBIsInternal, cachedDragPBHasDroppable, cachedDragPBItemCount)
    }

    private func pollCursorAndDragState() {
        let enabled = coordinator.notchShelfEnabled
        let isMouseButtonDown = NSEvent.pressedMouseButtons != 0
        let now = CFAbsoluteTimeGetCurrent()

        guard enabled else {
            cancelHoverExpand()
            if shelfState.isExpanded { collapse(force: true) }
            isHiddenForMissionControl = false
            resetDragMotionTracking()
            repositionSensorWindows()
            stopPollTimer()
            return
        }

        if updateMissionControlYieldState(now: now) {
            return
        }

        // Keep idle drag-pasteboard baseline synced so stale files from past drags never trigger false opens
        // when the user later clicks browser tabs, menu bar items, or window title bars near the notch.
        if !isMouseButtonDown {
            if wasMouseButtonDown || (now - lastBaselineSyncTime) >= 0.5 {
                baselineDragChangeCount = NSPasteboard(name: .drag).changeCount
                lastBaselineSyncTime = now
            }
            resetDragMotionTracking()
        }
        wasMouseButtonDown = isMouseButtonDown

        // Stop polling completely once collapsed and no mouse button is held (0Hz idle CPU).
        if !shelfState.isExpanded && !isMouseButtonDown {
            cancelHoverExpand()
            stopPollTimer()
            return
        }

        // Also drop to 0Hz idle CPU when explicitly pinned open with no active drag or Mission Control yield.
        // Event-driven mouse/drag monitors and activeSpaceDidChange wake the shelf immediately when needed.
        if shelfState.isExpanded && shelfState.isPinnedOpen && !isMouseButtonDown
            && !isHiddenForMissionControl && !isSensorDragging && !isPanelDragging {
            refreshClipboardHint()
            cancelAutoCollapse()
            stopPollTimer()
            return
        }

        // Relax fast drag cadence back to 10Hz once the button is released while the shelf stays open.
        if shelfState.isExpanded && !isMouseButtonDown {
            ensurePollTimerRunning(fastForDrag: false)
        }

        let loc = NSEvent.mouseLocation
        guard let cursorScreen = screenUnderCursor(at: loc) else { return }

        if isMouseButtonDown {
            recordDragMotionSample(location: loc, screenFrame: cursorScreen.frame, now: now)
        }

        if !shelfState.isExpanded {
            if isMouseButtonDown {
                let state = inspectSystemDragPasteboard()
                if NotchDropGeometry.shouldTriggerProactiveDragExpand(
                    currentDragChangeCount: state.changeCount,
                    baselineDragChangeCount: baselineDragChangeCount,
                    isInternalDrag: state.isInternal,
                    hasDroppablePayload: state.hasDroppable
                ) {
                    let metrics = notchMetrics(for: cursorScreen)
                    let startLocation = dragStartLocation ?? loc
                    if NotchDropGeometry.shouldTriggerUpwardDragApproach(
                        currentLocation: loc,
                        dragStartLocation: startLocation,
                        recentSamples: dragMotionSamples,
                        screenFrame: cursorScreen.frame,
                        hasPhysicalNotch: metrics.hasPhysicalNotch,
                        notchWidth: metrics.notchWidth,
                        notchHeight: metrics.notchHeight
                    ) {
                        cancelHoverExpand()
                        shelfState.dragItemCount = max(1, state.itemCount)
                        lastPredictiveDragExpandTime = now
                        expand(forDrag: true)
                    }
                }
            }
            return
        }

        refreshClipboardHint()

        // While expanded, keep the Notch Shelf anchored on its current display (never teleporting
        // onto another monitor when the user moves the pointer to a secondary screen).
        guard let panelFrame = panel?.frame else { return }
        let anchoredScreen = panel?.screen
            ?? NSScreen.screens.first(where: { $0.frame.intersects(panelFrame) })
            ?? cursorScreen
        let metrics = notchMetrics(for: anchoredScreen)
        let inDragTrigger = NotchDropGeometry.isPointInDragTriggerZone(
            loc,
            screenFrame: anchoredScreen.frame,
            hasPhysicalNotch: metrics.hasPhysicalNotch,
            notchWidth: metrics.notchWidth,
            notchHeight: metrics.notchHeight
        )
        let inHoverTrigger = NotchDropGeometry.isPointInHoverTriggerZone(
            loc,
            screenFrame: anchoredScreen.frame,
            hasPhysicalNotch: metrics.hasPhysicalNotch,
            notchWidth: metrics.notchWidth,
            notchHeight: metrics.notchHeight
        )

        let strictCardRect = NotchDropGeometry.strictScreenCardRect(
            panelFrame: panelFrame,
            bodyWidth: shelfState.expandedBodyWidth,
            cardHeight: shelfState.expandedCardHeight
        )
        let inPredictiveApproachGrace: Bool = {
            guard isMouseButtonDown, (now - lastPredictiveDragExpandTime) < 0.45 else { return false }
            let approachRect = strictCardRect.insetBy(dx: -48, dy: -48)
            guard approachRect.contains(loc) else { return false }
            let velocity = NotchDropGeometry.recentDragVelocity(from: dragMotionSamples)
            return velocity.dy >= -80
        }()
        let insideActiveArea = strictCardRect.contains(loc)
            || inPredictiveApproachGrace
            || (isMouseButtonDown ? inDragTrigger : inHoverTrigger)

        if (!insideActiveArea || !isMouseButtonDown) && (isPanelDragging || isSensorDragging) {
            if !isMouseButtonDown {
                isSensorDragging = false
                isPanelDragging = false
            } else if !insideActiveArea {
                isPanelDragging = false
            }
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

        if shelfState.statusBanner != nil || shelfState.processingMessage != nil || isSensorDragging || shelfState.isPinnedOpen || isMenuTracking {
            cancelAutoCollapse()
            return
        }

        if insideActiveArea {
            cancelAutoCollapse()
        } else if hideWorkItem == nil {
            scheduleAutoCollapse(delay: isMouseButtonDown ? 0.14 : 0.45)
        }
    }

    private func screenUnderCursor(at location: NSPoint? = nil) -> NSScreen? {
        let loc = location ?? NSEvent.mouseLocation
        return NSScreen.screens.first(where: { $0.frame.contains(loc) })
            ?? NSScreen.main
            ?? NSScreen.screens.first
    }

    private func cancelAutoCollapse() {
        hideWorkItem?.cancel()
        hideWorkItem = nil
    }

    private func scheduleAutoCollapse(delay: TimeInterval = 0.55) {
        cancelAutoCollapse()
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
            let folderID = shelfState.selectedFolderID ?? library.folderHierarchyRoots.first?.folder.id ?? library.folders.first?.id
            let name = folderID.flatMap { library.folder(byID: $0)?.name } ?? "收件箱"
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
            let hasSocialPost = directInputs.contains { input in
                if case .webURL(let url, _, _) = input { return SocialPostURLParser.parse(url) != nil }
                return false
            }
            let hasGitHubRepo = directInputs.contains { input in
                if case .webURL(let url, _, _) = input { return GitHubRepoURLParser.parse(url) != nil }
                return false
            }
            let hasGenericWebURL = directInputs.contains { input in
                if case .webURL(let url, _, _) = input {
                    return SocialPostURLParser.parse(url) == nil && GitHubRepoURLParser.parse(url) == nil
                }
                return false
            }
            notchLogger.info("NotchShelf received \(directInputs.count) payload(s) -> \(destLabel, privacy: .public)")
            if hasSocialPost {
                showProcessing("正在保存推文及媒体…")
            } else if hasGitHubRepo {
                showProcessing("正在解析 GitHub 仓库…")
            } else if hasGenericWebURL {
                showProcessing("正在解析网页缩略图…")
            }
            Task { @MainActor in
                let created = await library.ingest(
                    directInputs,
                    targetFolderID: targetFolderID,
                    targetBoardID: targetBoardID
                )
                if let boardID = targetBoardID, !created.isEmpty {
                    await moodboards.reloadActiveBoardIfNeeded(id: boardID)
                    await moodboards.refreshBoards()
                }
                guard !created.isEmpty else {
                    flashConfirmation(library.lastError ?? "未能收入内容或素材已存在")
                    return
                }
                let count = created.count
                let message: String
                if hasSocialPost {
                    message = "已保存推文及媒体至「\(destLabel)」(\(count) 项)"
                } else if hasGitHubRepo {
                    message = "已收藏 GitHub 仓库至「\(destLabel)」(\(count) 项)"
                } else if hasGenericWebURL {
                    message = "已收藏网页书签至「\(destLabel)」(\(count) 项)"
                } else {
                    message = "已收入「\(destLabel)」(\(count) 项)"
                }
                flashConfirmation(message)
            }
            return true
        }

        // 2. File promises (Photos.app, Safari dragged images, Mail attachments)
        if !promiseReceivers.isEmpty {
            let tempDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("charkle-drop-\(UUID().uuidString)", isDirectory: true)
            try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            let tracker = NotchPromiseBatchTracker(total: promiseReceivers.count)
            for receiver in promiseReceivers {
                receiver.receivePromisedFiles(atDestination: tempDir, options: [:], operationQueue: promiseQueue) { [weak self] fileURL, error in
                    guard let self else {
                        try? FileManager.default.removeItem(at: fileURL)
                        if tracker.record(succeeded: false).done {
                            try? FileManager.default.removeItem(at: tempDir)
                        }
                        return
                    }
                    if error != nil {
                        try? FileManager.default.removeItem(at: fileURL)
                        let status = tracker.record(succeeded: false)
                        if status.done {
                            try? FileManager.default.removeItem(at: tempDir)
                            Task { @MainActor [weak self] in
                                guard let self else { return }
                                if status.totalCreated > 0 {
                                    if let boardID = targetBoardID {
                                        await self.moodboards.reloadActiveBoardIfNeeded(id: boardID)
                                        await self.moodboards.refreshBoards()
                                    }
                                    self.flashConfirmation("已收入「\(destLabel)」(\(status.totalCreated) 项)")
                                } else {
                                    self.flashConfirmation("拖入文件接收失败，请重试")
                                }
                            }
                        }
                        return
                    }
                    Task { @MainActor [weak self] in
                        var ingestedCount = 0
                        defer {
                            try? FileManager.default.removeItem(at: fileURL)
                            let status = tracker.record(succeeded: ingestedCount > 0, created: ingestedCount)
                            if status.done {
                                try? FileManager.default.removeItem(at: tempDir)
                                Task { @MainActor [weak self] in
                                    guard let self else { return }
                                    if status.totalCreated > 0 {
                                        if let boardID = targetBoardID {
                                            await self.moodboards.reloadActiveBoardIfNeeded(id: boardID)
                                            await self.moodboards.refreshBoards()
                                        }
                                        self.flashConfirmation("已收入「\(destLabel)」(\(status.totalCreated) 项)")
                                    } else {
                                        self.flashConfirmation(self.library.lastError ?? "拖入文件未能收入，请重试")
                                    }
                                }
                            }
                        }
                        guard let self else { return }
                        let created = await self.library.ingest(
                            [.fileURL(fileURL)],
                            targetFolderID: targetFolderID,
                            targetBoardID: targetBoardID
                        )
                        ingestedCount = created.count
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
        if let activeSpaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activeSpaceObserver)
        }
        if let menuBeginObserver {
            NotificationCenter.default.removeObserver(menuBeginObserver)
        }
        if let menuEndObserver {
            NotificationCenter.default.removeObserver(menuEndObserver)
        }
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
        }
        if let globalMouseMonitor {
            NSEvent.removeMonitor(globalMouseMonitor)
        }
        if let localMouseMonitor {
            NSEvent.removeMonitor(localMouseMonitor)
        }
        pollTimer?.invalidate()
        bannerResetTask?.cancel()
        hideWorkItem?.cancel()
        hoverExpandWorkItem?.cancel()
        panelOrderOutWorkItem?.cancel()
        for window in sensorWindows {
            window.orderOut(nil)
        }
        panel?.orderOut(nil)
    }
}
