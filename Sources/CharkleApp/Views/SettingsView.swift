import CharkleCore
import SwiftUI

/// Compatibility standalone wrapper around Charkle's modular 9-pane Settings architecture.
/// The primary in-app experience presents `SettingsOverlayView` centered over `MainWindowView`,
/// while `SettingsView` remains available for standalone hosting or tests.
public struct SettingsView: View {
    public let coordinator: AppCoordinatorStore
    public let library: LibraryStore?
    public let syncAndAI: SyncAndAIStore
    public let onToggleNotchPreview: () -> Void
    public let onSyncHotkeysEnabled: (Bool) -> Void
    public let onSyncDefaultNotchTarget: (NotchTargetMode) -> Void

    public typealias SettingsTab = CharkleSettingsTab

    public init(
        coordinator: AppCoordinatorStore,
        library: LibraryStore? = nil,
        syncAndAI: SyncAndAIStore,
        onToggleNotchPreview: @escaping () -> Void,
        onSyncHotkeysEnabled: @escaping (Bool) -> Void,
        onSyncDefaultNotchTarget: @escaping (NotchTargetMode) -> Void = { _ in }
    ) {
        self.coordinator = coordinator
        self.library = library
        self.syncAndAI = syncAndAI
        self.onToggleNotchPreview = onToggleNotchPreview
        self.onSyncHotkeysEnabled = onSyncHotkeysEnabled
        self.onSyncDefaultNotchTarget = onSyncDefaultNotchTarget
    }

    public var body: some View {
        ZStack {
            SettingsContentShell(
                coordinator: coordinator,
                library: library,
                syncAndAI: syncAndAI,
                onToggleNotchPreview: onToggleNotchPreview,
                onSyncHotkeysEnabled: onSyncHotkeysEnabled,
                onSyncDefaultNotchTarget: onSyncDefaultNotchTarget,
                onClose: nil
            )
            CharkleToastOverlay(coordinator: coordinator)
                .zIndex(300)
        }
        .frame(width: 820, height: 630)
    }
}
