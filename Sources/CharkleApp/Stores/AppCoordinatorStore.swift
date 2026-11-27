import CharkleCanvas
import CharkleCore
import Foundation
import SwiftUI

public enum MoodboardGeneratorEntry: String, CaseIterable, Sendable {
    case prompt
    case seedAssets
    case palette
    case selection

    public var label: String {
        switch self {
        case .prompt: "灵感词"
        case .seedAssets: "种子图"
        case .palette: "配色定调"
        case .selection: "当前框选"
        }
    }
}

public enum ToastTone: Sendable {
    case neutral
    case success
    case warning
    case error
}

public struct CharkleToast: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let message: String
    public let iconName: String
    public let tone: ToastTone
    public let actionTitle: String?
    public let duration: Double
    public var isPaused: Bool

    public init(
        id: UUID = UUID(),
        message: String,
        iconName: String = "checkmark.circle.fill",
        tone: ToastTone = .neutral,
        actionTitle: String? = nil,
        duration: Double = 2.6,
        isPaused: Bool = false
    ) {
        self.id = id
        self.message = message
        self.iconName = iconName
        self.tone = tone
        self.actionTitle = actionTitle
        self.duration = duration
        self.isPaused = isPaused
    }
}

public enum InspectorDetailTab: String, CaseIterable, Sendable {
    case info = "信息"
    case similar = "类似项目"
}

/// Top-level UI coordination store: navigation destination, active moodboard target,
/// Quick Look target/playlist, modal presentations, column density, Notch Shelf preferences, and toast queue.
@Observable
public final class AppCoordinatorStore {
    public var selectedDestination: SidebarDestination = .allItems
    public var activeMoodboardID: UUID?

    public var quickLookAssetID: UUID?
    public var quickLookPlaylist: [UUID] = []
    public private(set) var quickLookDismissRequestToken: UInt64 = 0
    @ObservationIgnored public var focusedStageAssetID: UUID? = nil
    public var pendingGalleryReveal: MasonryRevealRequest?

    public var isJumpAnywherePresented: Bool = false
    public var isVisualFilterBarPresented: Bool = false
    public var isInspectorVisible: Bool = true
    public var selectedInspectorTab: InspectorDetailTab = .info
    public var isMoodboardGeneratorPresented: Bool = false
    public var generatorInitialEntry: MoodboardGeneratorEntry = .prompt
    public var isSmartFolderEditorPresented: Bool = false
    public var editingSmartFolder: SmartFolderRecord?
    public var isSmartDeduplicationPresented: Bool = false
    public var deduplicationInitialFolderID: UUID? = nil
    public var isPinterestDetailImageExpanded: Bool = false

    /// Centered Settings overlay state & deep-link tab routing.
    public var isSettingsPresented: Bool = false
    public var selectedSettingsTab: CharkleSettingsTab = .general

    /// Non-nil when the persistent SQLite engine failed to initialize on launch and fell back
    /// to an in-memory placeholder, so MainWindowView can warn the user immediately.
    public var engineStartupError: String? = nil

    /// First-launch & re-runnable onboarding guide presentation state.
    public var isOnboardingPresented: Bool = false
    public var onboardingRunID: UUID = UUID()
    public var hasCompletedOnboarding: Bool {
        didSet { UserDefaults.standard.set(hasCompletedOnboarding, forKey: Keys.hasCompletedOnboarding) }
    }

    public static let collapsedSidebarWidth: CGFloat = SidebarResizeGeometry.collapsedWidth
    public static let defaultSidebarWidth: CGFloat = SidebarResizeGeometry.defaultWidth
    public static let minSidebarWidth: CGFloat = SidebarResizeGeometry.minWidth
    public static let maxSidebarWidth: CGFloat = SidebarResizeGeometry.maxWidth
    public static let defaultInspectorWidth: CGFloat = SidebarResizeGeometry.defaultInspectorWidth
    public static let minInspectorWidth: CGFloat = SidebarResizeGeometry.minInspectorWidth
    public static let maxInspectorWidth: CGFloat = SidebarResizeGeometry.maxInspectorWidth
    public static let minCenterWorkspaceWidth: CGFloat = SidebarResizeGeometry.minCenterWorkspaceWidth

    /// Clamps a requested sidebar width to safe visual bounds (`188...420pt`) while guaranteeing
    /// the center workspace always retains at least `minCenterWorkspaceWidth` when the window narrows.
    public static func clampedSidebarWidth(
        _ rawWidth: CGFloat,
        windowWidth: CGFloat? = nil,
        isInspectorVisible: Bool = false,
        inspectorWidth: CGFloat = defaultInspectorWidth
    ) -> CGFloat {
        SidebarResizeGeometry.clampedWidth(
            rawWidth,
            windowWidth: windowWidth,
            isInspectorVisible: isInspectorVisible,
            inspectorWidth: inspectorWidth
        )
    }

    /// Clamps a requested right Inspector width to safe visual bounds (`260...480pt`) while preserving
    /// center workspace / Quick Look stage headroom.
    public static func clampedInspectorWidth(
        _ rawWidth: CGFloat,
        windowWidth: CGFloat? = nil,
        sidebarOccupiedWidth: CGFloat = 0
    ) -> CGFloat {
        SidebarResizeGeometry.clampedInspectorWidth(
            rawWidth,
            windowWidth: windowWidth,
            sidebarOccupiedWidth: sidebarOccupiedWidth
        )
    }

    /// Collapsible icon-only sidebar rail (⌘\).
    public var isSidebarCollapsed: Bool {
        didSet { UserDefaults.standard.set(isSidebarCollapsed, forKey: Keys.sidebarCollapsed) }
    }

    /// Persisted user-adjusted expanded sidebar width (`188...420pt`, default `232pt`).
    public var sidebarWidth: CGFloat {
        didSet {
            let clamped = Self.clampedSidebarWidth(sidebarWidth)
            if abs(clamped - sidebarWidth) > 0.01 {
                sidebarWidth = clamped
                return
            }
            UserDefaults.standard.set(Double(clamped), forKey: Keys.sidebarWidth)
        }
    }

    /// Persisted user-adjusted right Inspector width (`260...480pt`, default `300pt`),
    /// shared 1:1 between the main workspace and Quick Look overlay.
    public var inspectorWidth: CGFloat {
        didSet {
            let clamped = Self.clampedInspectorWidth(inspectorWidth)
            if abs(clamped - inspectorWidth) > 0.01 {
                inspectorWidth = clamped
                return
            }
            UserDefaults.standard.set(Double(clamped), forKey: Keys.inspectorWidth)
        }
    }

    /// Gallery layout mode: vertical masonry vs. horizontal justified rows.
    public var galleryLayoutMode: GalleryLayoutMode {
        didSet { UserDefaults.standard.set(galleryLayoutMode.rawValue, forKey: Keys.galleryLayoutMode) }
    }

    /// Dual accent source preference: studio cobalt (default) or live macOS system accent.
    public var accentSource: CharkleAccentSource {
        didSet { UserDefaults.standard.set(accentSource.rawValue, forKey: Keys.accentSource) }
    }

    /// Target card width in masonry grid (130pt dense – 420pt editorial).
    public var targetColumnWidth: Double = 228

    /// User-configurable Notch Shelf & Global Hotkey toggles persisted in UserDefaults.
    public var notchShelfEnabled: Bool {
        didSet { UserDefaults.standard.set(notchShelfEnabled, forKey: Keys.notchShelfEnabled) }
    }

    public var notchHoverTriggerEnabled: Bool {
        didSet { UserDefaults.standard.set(notchHoverTriggerEnabled, forKey: Keys.notchHoverTriggerEnabled) }
    }

    public var notchPresentationMode: NotchShelfPresentationMode {
        didSet { UserDefaults.standard.set(notchPresentationMode.rawValue, forKey: Keys.notchPresentationMode) }
    }

    public var globalHotkeysEnabled: Bool {
        didSet { UserDefaults.standard.set(globalHotkeysEnabled, forKey: Keys.globalHotkeysEnabled) }
    }

    public var defaultNotchTargetMode: NotchTargetMode {
        didSet { UserDefaults.standard.set(defaultNotchTargetMode.rawValue, forKey: Keys.defaultNotchTargetMode) }
    }

    /// Runtime flag for Ultra-Low-Resource Minimal Capture Mode (closes main workspace, purges decoded
    /// caches, hides Dock icon, and keeps only the top Notch Shelf capture + Menu Bar icon alive).
    public var isMinimalCaptureMode: Bool = false

    /// Persisted preference: launch directly into Minimal Capture Mode on startup.
    public var launchInMinimalCaptureMode: Bool {
        didSet { UserDefaults.standard.set(launchInMinimalCaptureMode, forKey: Keys.launchInMinimalCaptureMode) }
    }

    /// Persisted preference: closing the main window automatically transitions to Minimal Capture Mode.
    public var enterMinimalModeOnWindowClose: Bool {
        didSet { UserDefaults.standard.set(enterMinimalModeOnWindowClose, forKey: Keys.enterMinimalModeOnWindowClose) }
    }

    /// User-customizable order of cards in the Single-Asset Inspector info tab.
    public var inspectorInfoSectionOrder: [InspectorInfoSection] {
        didSet {
            UserDefaults.standard.set(
                inspectorInfoSectionOrder.map(\.rawValue),
                forKey: Keys.inspectorInfoSectionOrder
            )
        }
    }

    public var isInspectorSectionOrderCustomized: Bool {
        inspectorInfoSectionOrder != InspectorInfoSection.defaultOrder
    }

    public var toasts: [CharkleToast] = []

    private struct ToastTimerRecord {
        var task: Task<Void, Never>?
        var remaining: Double
        var startedAt: Date?
    }

    public static let maxQueuedToasts: Int = 24

    @ObservationIgnored private var toastTimers: [UUID: ToastTimerRecord] = [:]
    @ObservationIgnored private var toastActions: [UUID: @MainActor () -> Void] = [:]
    @ObservationIgnored private var isToastStackPaused: Bool = false

    private enum Keys {
        static let notchShelfEnabled = "charkle.notchShelfEnabled"
        static let notchHoverTriggerEnabled = "charkle.notchHoverTriggerEnabled"
        static let notchPresentationMode = "charkle.notchPresentationMode"
        static let globalHotkeysEnabled = "charkle.globalHotkeysEnabled"
        static let defaultNotchTargetMode = "charkle.defaultNotchTargetMode"
        static let launchInMinimalCaptureMode = "charkle.launchInMinimalCaptureMode"
        static let enterMinimalModeOnWindowClose = "charkle.enterMinimalModeOnWindowClose"
        static let sidebarCollapsed = "charkle.sidebarCollapsed"
        static let sidebarWidth = "charkle.sidebarWidth"
        static let inspectorWidth = "charkle.inspectorWidth"
        static let galleryLayoutMode = "charkle.galleryLayoutMode"
        static let accentSource = "charkle.accentSource"
        static let hasCompletedOnboarding = "charkle.hasCompletedOnboarding"
        static let inspectorInfoSectionOrder = "charkle.inspectorInfoSectionOrder"
    }

    public init() {
        let defaults = UserDefaults.standard
        self.notchShelfEnabled = defaults.object(forKey: Keys.notchShelfEnabled) as? Bool ?? true
        self.notchHoverTriggerEnabled = defaults.object(forKey: Keys.notchHoverTriggerEnabled) as? Bool ?? true
        self.notchPresentationMode = defaults.string(forKey: Keys.notchPresentationMode)
            .flatMap(NotchShelfPresentationMode.init(rawValue:)) ?? .alwaysShowRecent
        self.globalHotkeysEnabled = defaults.object(forKey: Keys.globalHotkeysEnabled) as? Bool ?? true
        self.defaultNotchTargetMode = defaults.string(forKey: Keys.defaultNotchTargetMode)
            .flatMap(NotchTargetMode.init(rawValue:)) ?? .inbox
        let launchMinimal = defaults.object(forKey: Keys.launchInMinimalCaptureMode) as? Bool ?? false
        self.launchInMinimalCaptureMode = launchMinimal
        self.enterMinimalModeOnWindowClose = defaults.object(forKey: Keys.enterMinimalModeOnWindowClose) as? Bool ?? false
        self.isMinimalCaptureMode = launchMinimal
        self.isSidebarCollapsed = defaults.object(forKey: Keys.sidebarCollapsed) as? Bool ?? false
        let storedSidebarWidth = defaults.object(forKey: Keys.sidebarWidth) as? Double
        self.sidebarWidth = storedSidebarWidth.map { Self.clampedSidebarWidth(CGFloat($0)) } ?? Self.defaultSidebarWidth
        let storedInspectorWidth = defaults.object(forKey: Keys.inspectorWidth) as? Double
        self.inspectorWidth = storedInspectorWidth.map { Self.clampedInspectorWidth(CGFloat($0)) } ?? Self.defaultInspectorWidth
        self.galleryLayoutMode = defaults.string(forKey: Keys.galleryLayoutMode)
            .flatMap(GalleryLayoutMode.init(rawValue:)) ?? .verticalMasonry
        self.accentSource = defaults.string(forKey: Keys.accentSource)
            .flatMap(CharkleAccentSource.init(rawValue:)) ?? .studio
        self.hasCompletedOnboarding = defaults.object(forKey: Keys.hasCompletedOnboarding) as? Bool ?? false
        let storedOrder = defaults.stringArray(forKey: Keys.inspectorInfoSectionOrder) ?? []
        self.inspectorInfoSectionOrder = InspectorInfoSection.normalizedOrder(from: storedOrder)
    }

    public func moveInspectorSection(_ dragged: InspectorInfoSection, toTarget target: InspectorInfoSection) {
        let updated = InspectorInfoSection.moving(dragged, toTarget: target, in: inspectorInfoSectionOrder)
        if updated != inspectorInfoSectionOrder {
            inspectorInfoSectionOrder = updated
        }
    }

    public func moveInspectorSectionToTop(_ section: InspectorInfoSection) {
        let updated = InspectorInfoSection.movingToTop(section, in: inspectorInfoSectionOrder)
        if updated != inspectorInfoSectionOrder {
            inspectorInfoSectionOrder = updated
        }
    }

    public func moveInspectorSectionToBottom(_ section: InspectorInfoSection) {
        let updated = InspectorInfoSection.movingToBottom(section, in: inspectorInfoSectionOrder)
        if updated != inspectorInfoSectionOrder {
            inspectorInfoSectionOrder = updated
        }
    }

    public func stepInspectorSection(_ section: InspectorInfoSection, delta: Int, visibleSections: [InspectorInfoSection]) {
        let updated = InspectorInfoSection.stepping(section, delta: delta, visible: visibleSections, in: inspectorInfoSectionOrder)
        if updated != inspectorInfoSectionOrder {
            inspectorInfoSectionOrder = updated
        }
    }

    public func resetInspectorSectionOrder() {
        if inspectorInfoSectionOrder != InspectorInfoSection.defaultOrder {
            inspectorInfoSectionOrder = InspectorInfoSection.defaultOrder
        }
    }

    public var isModalOverlayPresented: Bool {
        quickLookAssetID != nil
            || isSettingsPresented
            || isJumpAnywherePresented
            || isOnboardingPresented
            || isMoodboardGeneratorPresented
            || isSmartFolderEditorPresented
            || isSmartDeduplicationPresented
    }

    public func presentSmartDeduplication(folderID: UUID? = nil) {
        deduplicationInitialFolderID = folderID
        closeQuickLook()
        closeSettings()
        if isJumpAnywherePresented { isJumpAnywherePresented = false }
        if isOnboardingPresented { isOnboardingPresented = false }
        isSmartDeduplicationPresented = true
    }

    public func closeSmartDeduplication() {
        if isSmartDeduplicationPresented {
            isSmartDeduplicationPresented = false
        }
        deduplicationInitialFolderID = nil
    }

    public func openSettings(tab: CharkleSettingsTab? = nil) {
        if let tab, selectedSettingsTab != tab {
            selectedSettingsTab = tab
        }
        closeQuickLook()
        closeSmartDeduplication()
        if isJumpAnywherePresented { isJumpAnywherePresented = false }
        if isOnboardingPresented { isOnboardingPresented = false }
        if !isSettingsPresented { isSettingsPresented = true }
    }

    public func closeSettings() {
        if isSettingsPresented { isSettingsPresented = false }
    }

    public static let didRequestOnboardingPresentationNotification = Notification.Name("com.charkle.didRequestOnboardingPresentation")

    public func presentOnboardingIfFirstLaunch() {
        guard !hasCompletedOnboarding, !isOnboardingPresented else { return }
        onboardingRunID = UUID()
        isOnboardingPresented = true
    }

    public func presentOnboarding() {
        onboardingRunID = UUID()
        isOnboardingPresented = true
        NotificationCenter.default.post(name: Self.didRequestOnboardingPresentationNotification, object: nil)
    }

    public func completeOnboarding() {
        hasCompletedOnboarding = true
        isOnboardingPresented = false
    }

    public var isViewingMoodboard: Bool {
        if case .moodboard = selectedDestination { return true }
        return false
    }

    public func openMoodboard(_ id: UUID) {
        activeMoodboardID = id
        selectedDestination = .moodboard(id)
    }

    public func presentMoodboardGenerator(entry: MoodboardGeneratorEntry = .prompt) {
        generatorInitialEntry = entry
        isMoodboardGeneratorPresented = true
    }

    public func openQuickLook(assetID: UUID, playlist: [UUID]) {
        quickLookPlaylist = playlist
        quickLookAssetID = assetID
    }

    public func requestQuickLookDismiss() {
        guard quickLookAssetID != nil else { return }
        quickLookDismissRequestToken &+= 1
    }

    public func closeQuickLook() {
        if quickLookAssetID != nil {
            quickLookAssetID = nil
        }
        if !quickLookPlaylist.isEmpty {
            quickLookPlaylist.removeAll()
        }
    }

    public func requestRevealAssetInGallery(_ assetID: UUID) {
        pendingGalleryReveal = MasonryRevealRequest(assetID: assetID)
    }

    public func stepQuickLook(delta: Int) {
        guard let current = quickLookAssetID,
              let idx = quickLookPlaylist.firstIndex(of: current),
              !quickLookPlaylist.isEmpty else { return }
        let count = quickLookPlaylist.count
        let nextIdx = ((idx + delta) % count + count) % count
        quickLookAssetID = quickLookPlaylist[nextIdx]
    }

    @discardableResult
    public func showToast(
        _ message: String,
        icon: String = "checkmark.circle.fill",
        tone: ToastTone = .neutral,
        duration: Double? = nil,
        actionTitle: String? = nil,
        onAction: (@MainActor () -> Void)? = nil
    ) -> UUID {
        let resolvedDuration = duration ?? (actionTitle != nil ? 4.8 : 2.6)
        let toast = CharkleToast(
            message: message,
            iconName: icon,
            tone: tone,
            actionTitle: actionTitle,
            duration: resolvedDuration,
            isPaused: isToastStackPaused
        )
        toasts.append(toast)
        if let onAction {
            toastActions[toast.id] = onAction
        }
        while toasts.count > Self.maxQueuedToasts {
            let evicted = toasts.removeFirst()
            cleanupToastResources(evicted.id)
        }
        if isToastStackPaused {
            toastTimers[toast.id] = ToastTimerRecord(task: nil, remaining: resolvedDuration, startedAt: nil)
        } else {
            scheduleToastDismiss(id: toast.id, remaining: resolvedDuration)
        }
        return toast.id
    }

    public func pauseToast(_ id: UUID) {
        guard let idx = toasts.firstIndex(where: { $0.id == id }), !toasts[idx].isPaused else { return }
        toasts[idx].isPaused = true
        if var record = toastTimers[id] {
            record.task?.cancel()
            record.task = nil
            if let startedAt = record.startedAt {
                record.remaining = max(0.35, record.remaining - Date().timeIntervalSince(startedAt))
                record.startedAt = nil
            }
            toastTimers[id] = record
        }
    }

    public func resumeToast(_ id: UUID) {
        guard let idx = toasts.firstIndex(where: { $0.id == id }), toasts[idx].isPaused else { return }
        toasts[idx].isPaused = false
        let remaining = toastTimers[id]?.remaining ?? toasts[idx].duration
        scheduleToastDismiss(id: id, remaining: remaining)
    }

    public func pauseAllToasts() {
        isToastStackPaused = true
        for toast in toasts {
            pauseToast(toast.id)
        }
    }

    public func resumeAllToasts() {
        isToastStackPaused = false
        for toast in toasts {
            resumeToast(toast.id)
        }
    }

    public func dismissAllToasts() {
        isToastStackPaused = false
        for toast in toasts {
            cleanupToastResources(toast.id)
        }
        toasts.removeAll()
    }

    public func triggerToastAction(_ id: UUID) {
        let action = toastActions.removeValue(forKey: id)
        dismissToast(id)
        action?()
    }

    public func dismissToast(_ id: UUID) {
        cleanupToastResources(id)
        toasts.removeAll { $0.id == id }
        if toasts.isEmpty {
            isToastStackPaused = false
        }
    }

    private func scheduleToastDismiss(id: UUID, remaining: Double) {
        guard remaining > 0 else { return }
        toastTimers[id]?.task?.cancel()
        let task = Task { [weak self] in
            try? await Task.sleep(for: .seconds(remaining))
            guard !Task.isCancelled, let self else { return }
            self.dismissToast(id)
        }
        toastTimers[id] = ToastTimerRecord(task: task, remaining: remaining, startedAt: Date())
    }

    private func cleanupToastResources(_ id: UUID) {
        toastTimers[id]?.task?.cancel()
        toastTimers.removeValue(forKey: id)
        toastActions.removeValue(forKey: id)
    }
}
