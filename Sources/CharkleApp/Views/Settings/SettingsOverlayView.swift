import CharkleCore
import SwiftUI

/// Centered Settings modal overlay presented above `MainWindowView`.
/// Supports backdrop click dismissal, `Esc` dismissal, deep-link tab selection, and calm Light/Dark parity.
public struct SettingsOverlayView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public let coordinator: AppCoordinatorStore
    public let library: LibraryStore
    public let syncAndAI: SyncAndAIStore
    public let onToggleNotchPreview: () -> Void
    public let onSyncHotkeysEnabled: (Bool) -> Void
    public let onSyncDefaultNotchTarget: (NotchTargetMode) -> Void
    public let onEnterMinimalCaptureMode: () -> Void
    public let onClose: () -> Void

    public init(
        coordinator: AppCoordinatorStore,
        library: LibraryStore,
        syncAndAI: SyncAndAIStore,
        onToggleNotchPreview: @escaping () -> Void,
        onSyncHotkeysEnabled: @escaping (Bool) -> Void,
        onSyncDefaultNotchTarget: @escaping (NotchTargetMode) -> Void = { _ in },
        onEnterMinimalCaptureMode: @escaping () -> Void = {},
        onClose: @escaping () -> Void
    ) {
        self.coordinator = coordinator
        self.library = library
        self.syncAndAI = syncAndAI
        self.onToggleNotchPreview = onToggleNotchPreview
        self.onSyncHotkeysEnabled = onSyncHotkeysEnabled
        self.onSyncDefaultNotchTarget = onSyncDefaultNotchTarget
        self.onEnterMinimalCaptureMode = onEnterMinimalCaptureMode
        self.onClose = onClose
    }

    @State private var cardAppeared: Bool = false

    public var body: some View {
        ZStack {
            CharkleModalBackdrop(onTap: onClose)

            GeometryReader { geo in
                let modalWidth = min(max(680, geo.size.width - 72), 840)
                let modalHeight = min(max(500, geo.size.height - 68), 636)

                let cardShape = RoundedRectangle(cornerRadius: 16, style: .continuous)
                SettingsContentShell(
                    coordinator: coordinator,
                    library: library,
                    syncAndAI: syncAndAI,
                    onToggleNotchPreview: onToggleNotchPreview,
                    onSyncHotkeysEnabled: onSyncHotkeysEnabled,
                    onSyncDefaultNotchTarget: onSyncDefaultNotchTarget,
                    onEnterMinimalCaptureMode: onEnterMinimalCaptureMode,
                    onClose: onClose
                )
                .frame(width: modalWidth, height: modalHeight)
                .clipShape(cardShape)
                .background {
                    // Shadows strictly on the static rounded-rect backing rather than the live scrolling subtree
                    // so CoreAnimation never re-rasterizes shadows offscreen during open/close/tab animations.
                    cardShape
                        .fill(SettingsPalette.contentBackground(for: colorScheme))
                        .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.46 : 0.14), radius: 34, y: 16)
                        .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.22 : 0.05), radius: 8, y: 3)
                }
                .overlay(
                    cardShape
                        .strokeBorder(
                            colorScheme == .dark ? Color.white.opacity(0.12) : Color.black.opacity(0.08),
                            lineWidth: 0.75
                        )
                )
                .scaleEffect(cardAppeared || reduceMotion ? 1.0 : 0.97)
                .opacity(cardAppeared ? 1.0 : 0.0)
                .animation(CharkleMotion.accessible(CharkleMotion.enterMd, reduced: reduceMotion), value: cardAppeared)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .ignoresSafeArea(.all)
        .onAppear {
            cardAppeared = true
        }
        .onKeyPress(.escape) {
            onClose()
            return .handled
        }
    }
}

/// Shared two-pane Settings interior used by both the centered overlay and standalone `SettingsView`.
public struct SettingsContentShell: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public let coordinator: AppCoordinatorStore
    public let library: LibraryStore?
    public let syncAndAI: SyncAndAIStore
    public let onToggleNotchPreview: () -> Void
    public let onSyncHotkeysEnabled: (Bool) -> Void
    public let onSyncDefaultNotchTarget: (NotchTargetMode) -> Void
    public let onEnterMinimalCaptureMode: () -> Void
    public let onClose: (() -> Void)?

    public init(
        coordinator: AppCoordinatorStore,
        library: LibraryStore? = nil,
        syncAndAI: SyncAndAIStore,
        onToggleNotchPreview: @escaping () -> Void,
        onSyncHotkeysEnabled: @escaping (Bool) -> Void,
        onSyncDefaultNotchTarget: @escaping (NotchTargetMode) -> Void = { _ in },
        onEnterMinimalCaptureMode: @escaping () -> Void = {},
        onClose: (() -> Void)? = nil
    ) {
        self.coordinator = coordinator
        self.library = library
        self.syncAndAI = syncAndAI
        self.onToggleNotchPreview = onToggleNotchPreview
        self.onSyncHotkeysEnabled = onSyncHotkeysEnabled
        self.onSyncDefaultNotchTarget = onSyncDefaultNotchTarget
        self.onEnterMinimalCaptureMode = onEnterMinimalCaptureMode
        self.onClose = onClose
    }

    public var body: some View {
        HStack(spacing: 0) {
            navigationRail
                .frame(width: 204)
                .background(SettingsPalette.railBackground(for: colorScheme))

            Rectangle()
                .fill(colorScheme == .dark ? Color.white.opacity(0.055) : Color.black.opacity(0.045))
                .frame(width: 0.5)

            contentColumn
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(SettingsPalette.contentBackground(for: colorScheme))
        }
        .task {
            // Avoid mutating 13 observable properties mid-open-animation when cached state is already populated.
            if syncAndAI.hasLoadedInitialState {
                try? await Task.sleep(for: .milliseconds(260))
                guard !Task.isCancelled else { return }
            }
            await syncAndAI.loadAll()
        }
    }

    // MARK: - Left Navigation Rail

    private var navigationRail: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("设置")
                    .font(.system(size: 14.5, weight: .semibold))
                    .foregroundStyle(.primary)
                Spacer()
            }
            .padding(.horizontal, 16)
            .frame(height: 52)

            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(CharkleSettingsSection.allCases) { section in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(section.title)
                                .font(.system(size: 10.5, weight: .medium))
                                .foregroundStyle(SettingsPalette.sectionLabel(for: colorScheme))
                                .padding(.horizontal, 12)
                                .padding(.bottom, 3)

                            ForEach(section.tabs) { tab in
                                sidebarItem(for: tab)
                            }
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 16)
                .charkleCleanScrollbars(hidden: true)
            }
            .scrollIndicators(.hidden)
        }
    }

    private func sidebarItem(for tab: CharkleSettingsTab) -> some View {
        let active = coordinator.selectedSettingsTab == tab
        return Button {
            withAnimation(CharkleMotion.accessible(CharkleMotion.hoverPress, reduced: reduceMotion)) {
                coordinator.selectedSettingsTab = tab
            }
        } label: {
            HStack(spacing: 9) {
                CharkleIcon(
                    tab.iconName,
                    style: .duotone,
                    size: 15,
                    color: active ? .primary : .secondary,
                    isActive: active
                )
                Text(tab.label)
                    .font(.system(size: 12.5, weight: active ? .semibold : .regular))
                    .foregroundStyle(active ? Color.primary : Color.primary.opacity(0.76))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                active
                    ? Color.primary.opacity(colorScheme == .dark ? 0.10 : 0.075)
                    : Color.clear,
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Right Content Column

    private var contentColumn: some View {
        let hasFeedbackBanner = syncAndAI.statusMessage != nil || syncAndAI.errorMessage != nil

        return VStack(spacing: 0) {
            // Fixed pane title header + close button
            HStack(spacing: 10) {
                Text(coordinator.selectedSettingsTab.label)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.primary)

                Spacer()

                if let onClose {
                    Button {
                        onClose()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 26, height: 26)
                            .background(SettingsPalette.subtleFill(for: colorScheme), in: Circle())
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .help("关闭设置 (Esc)")
                }
            }
            .padding(.horizontal, 24)
            .frame(height: 52)

            Rectangle()
                .fill(colorScheme == .dark ? Color.white.opacity(0.055) : Color.black.opacity(0.045))
                .frame(height: 0.5)

            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 18) {
                    if let status = syncAndAI.statusMessage {
                        feedbackBanner(status, isError: false)
                            .transition(CharkleMotion.originTransition(anchor: .top, scale: 0.97, reduced: reduceMotion))
                    }
                    if let err = syncAndAI.errorMessage {
                        feedbackBanner(err, isError: true)
                            .transition(CharkleMotion.originTransition(anchor: .top, scale: 0.97, reduced: reduceMotion))
                    }

                    activePane
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 20)
                .charkleCleanScrollbars(hidden: false)
                .animation(
                    CharkleMotion.enterExit(hasFeedbackBanner, reduced: reduceMotion),
                    value: "\(syncAndAI.statusMessage ?? "")|\(syncAndAI.errorMessage ?? "")"
                )
            }
            .scrollIndicators(.automatic)
        }
    }

    @ViewBuilder
    private var activePane: some View {
        switch coordinator.selectedSettingsTab {
        case .general:
            GeneralSettingsPane(coordinator: coordinator, syncAndAI: syncAndAI)
        case .library:
            LibrarySettingsPane(coordinator: coordinator, syncAndAI: syncAndAI)
        case .sync:
            SyncSettingsPane(coordinator: coordinator, syncAndAI: syncAndAI)
        case .notchShelf:
            NotchShelfSettingsPane(
                coordinator: coordinator,
                onToggleNotchPreview: onToggleNotchPreview,
                onSyncDefaultNotchTarget: onSyncDefaultNotchTarget,
                onEnterMinimalCaptureMode: onEnterMinimalCaptureMode
            )
        case .captureShortcuts:
            CaptureShortcutsSettingsPane(
                coordinator: coordinator,
                onSyncHotkeysEnabled: onSyncHotkeysEnabled
            )
        case .ai:
            AISettingsPane(syncAndAI: syncAndAI)
        case .externalAgents:
            ExternalAgentsSettingsPane(syncAndAI: syncAndAI)
        case .extensions:
            ExtensionsSettingsPane(coordinator: coordinator, syncAndAI: syncAndAI)
        case .advancedAbout:
            if let library {
                AdvancedAboutSettingsPane(library: library, syncAndAI: syncAndAI)
            } else {
                AdvancedAboutSettingsPane(
                    library: LibraryStore(engine: syncAndAI.engine),
                    syncAndAI: syncAndAI
                )
            }
        }
    }

    private func feedbackBanner(_ text: String, isError: Bool) -> some View {
        let tint = isError
            ? SettingsPalette.destructiveInk(for: colorScheme)
            : SettingsPalette.positiveInk(for: colorScheme)
        return HStack(spacing: 8) {
            Image(systemName: isError ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                .foregroundStyle(tint)
            Text(text)
                .font(.system(size: 12, weight: .medium))
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button {
                if isError { syncAndAI.errorMessage = nil } else { syncAndAI.statusMessage = nil }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(tint.opacity(0.11), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(tint.opacity(0.22), lineWidth: 0.75)
        )
    }
}
