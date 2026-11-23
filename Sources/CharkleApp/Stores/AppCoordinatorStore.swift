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

/// Top-level UI coordination store: navigation destination, active moodboard target,
/// Quick Look target/playlist, modal presentations, column density, Notch Shelf preferences, and toast queue.
@Observable
public final class AppCoordinatorStore {
    public var selectedDestination: SidebarDestination = .allItems
    public var activeMoodboardID: UUID?

    public var quickLookAssetID: UUID?
    public var quickLookPlaylist: [UUID] = []

    public var isJumpAnywherePresented: Bool = false
    public var isVisualFilterBarPresented: Bool = false
    public var isInspectorVisible: Bool = true
    public var isMoodboardGeneratorPresented: Bool = false
    public var generatorInitialEntry: MoodboardGeneratorEntry = .prompt
    public var isSmartFolderEditorPresented: Bool = false
    public var editingSmartFolder: SmartFolderRecord?

    /// Centered Settings overlay state & deep-link tab routing.
    public var isSettingsPresented: Bool = false
    public var selectedSettingsTab: CharkleSettingsTab = .general

    /// First-launch & re-runnable onboarding guide presentation state.
    public var isOnboardingPresented: Bool = false
    public var onboardingRunID: UUID = UUID()
    public var hasCompletedOnboarding: Bool {
        didSet { UserDefaults.standard.set(hasCompletedOnboarding, forKey: Keys.hasCompletedOnboarding) }
    }

    /// Collapsible icon-only sidebar rail (⌘\).
    public var isSidebarCollapsed: Bool {
        didSet { UserDefaults.standard.set(isSidebarCollapsed, forKey: Keys.sidebarCollapsed) }
    }

    /// Gallery layout mode: vertical masonry vs. horizontal justified rows.
    public var galleryLayoutMode: GalleryLayoutMode {
        didSet { UserDefaults.standard.set(galleryLayoutMode.rawValue, forKey: Keys.galleryLayoutMode) }
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

    public var globalHotkeysEnabled: Bool {
        didSet { UserDefaults.standard.set(globalHotkeysEnabled, forKey: Keys.globalHotkeysEnabled) }
    }

    public var defaultNotchTargetMode: NotchTargetMode {
        didSet { UserDefaults.standard.set(defaultNotchTargetMode.rawValue, forKey: Keys.defaultNotchTargetMode) }
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

    @ObservationIgnored private var toastTimers: [UUID: ToastTimerRecord] = [:]
    @ObservationIgnored private var toastActions: [UUID: @MainActor () -> Void] = [:]

    private enum Keys {
        static let notchShelfEnabled = "charkle.notchShelfEnabled"
        static let notchHoverTriggerEnabled = "charkle.notchHoverTriggerEnabled"
        static let globalHotkeysEnabled = "charkle.globalHotkeysEnabled"
        static let defaultNotchTargetMode = "charkle.defaultNotchTargetMode"
        static let sidebarCollapsed = "charkle.sidebarCollapsed"
        static let galleryLayoutMode = "charkle.galleryLayoutMode"
        static let hasCompletedOnboarding = "charkle.hasCompletedOnboarding"
        static let inspectorInfoSectionOrder = "charkle.inspectorInfoSectionOrder"
    }

    public init() {
        let defaults = UserDefaults.standard
        self.notchShelfEnabled = defaults.object(forKey: Keys.notchShelfEnabled) as? Bool ?? true
        self.notchHoverTriggerEnabled = defaults.object(forKey: Keys.notchHoverTriggerEnabled) as? Bool ?? true
        self.globalHotkeysEnabled = defaults.object(forKey: Keys.globalHotkeysEnabled) as? Bool ?? true
        self.defaultNotchTargetMode = defaults.string(forKey: Keys.defaultNotchTargetMode)
            .flatMap(NotchTargetMode.init(rawValue:)) ?? .inbox
        self.isSidebarCollapsed = defaults.object(forKey: Keys.sidebarCollapsed) as? Bool ?? false
        self.galleryLayoutMode = defaults.string(forKey: Keys.galleryLayoutMode)
            .flatMap(GalleryLayoutMode.init(rawValue:)) ?? .verticalMasonry
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

    public func openSettings(tab: CharkleSettingsTab? = nil) {
        if let tab {
            selectedSettingsTab = tab
        }
        isJumpAnywherePresented = false
        isSettingsPresented = true
    }

    public func closeSettings() {
        isSettingsPresented = false
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

    public func closeQuickLook() {
        quickLookAssetID = nil
    }

    public func stepQuickLook(delta: Int) {
        guard let current = quickLookAssetID,
              let idx = quickLookPlaylist.firstIndex(of: current),
              !quickLookPlaylist.isEmpty else { return }
        let nextIdx = (idx + delta + quickLookPlaylist.count) % quickLookPlaylist.count
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
            isPaused: false
        )
        toasts.append(toast)
        if let onAction {
            toastActions[toast.id] = onAction
        }
        while toasts.count > 3 {
            let evicted = toasts.removeFirst()
            cleanupToastResources(evicted.id)
        }
        scheduleToastDismiss(id: toast.id, remaining: resolvedDuration)
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

    public func triggerToastAction(_ id: UUID) {
        let action = toastActions.removeValue(forKey: id)
        dismissToast(id)
        action?()
    }

    public func dismissToast(_ id: UUID) {
        cleanupToastResources(id)
        toasts.removeAll { $0.id == id }
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
