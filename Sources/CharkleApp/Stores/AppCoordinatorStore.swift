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

    public init(id: UUID = UUID(), message: String, iconName: String = "checkmark.circle.fill", tone: ToastTone = .neutral) {
        self.id = id
        self.message = message
        self.iconName = iconName
        self.tone = tone
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

    public var toasts: [CharkleToast] = []

    private enum Keys {
        static let notchShelfEnabled = "charkle.notchShelfEnabled"
        static let notchHoverTriggerEnabled = "charkle.notchHoverTriggerEnabled"
        static let globalHotkeysEnabled = "charkle.globalHotkeysEnabled"
        static let sidebarCollapsed = "charkle.sidebarCollapsed"
        static let galleryLayoutMode = "charkle.galleryLayoutMode"
    }

    public init() {
        let defaults = UserDefaults.standard
        self.notchShelfEnabled = defaults.object(forKey: Keys.notchShelfEnabled) as? Bool ?? true
        self.notchHoverTriggerEnabled = defaults.object(forKey: Keys.notchHoverTriggerEnabled) as? Bool ?? true
        self.globalHotkeysEnabled = defaults.object(forKey: Keys.globalHotkeysEnabled) as? Bool ?? true
        self.isSidebarCollapsed = defaults.object(forKey: Keys.sidebarCollapsed) as? Bool ?? false
        self.galleryLayoutMode = defaults.string(forKey: Keys.galleryLayoutMode)
            .flatMap(GalleryLayoutMode.init(rawValue:)) ?? .verticalMasonry
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

    public func showToast(_ message: String, icon: String = "checkmark.circle.fill", tone: ToastTone = .neutral, duration: Double = 2.4) {
        let toast = CharkleToast(message: message, iconName: icon, tone: tone)
        toasts.append(toast)
        if toasts.count > 3 {
            toasts.removeFirst(toasts.count - 3)
        }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(duration))
            guard let self else { return }
            self.toasts.removeAll { $0.id == toast.id }
        }
    }
}
