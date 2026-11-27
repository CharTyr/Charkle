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
    public let appUpdater: AppUpdateStore?
    public let onToggleNotchPreview: () -> Void
    public let onSyncHotkeysEnabled: (Bool) -> Void
    public let onSyncDefaultNotchTarget: (NotchTargetMode) -> Void
    public let onEnterMinimalCaptureMode: () -> Void
    public let onImportMaterialPackage: (() -> Void)?
    public let onOpenSmartDeduplication: (() -> Void)?
    public let onClose: () -> Void

    public init(
        coordinator: AppCoordinatorStore,
        library: LibraryStore,
        syncAndAI: SyncAndAIStore,
        appUpdater: AppUpdateStore? = nil,
        onToggleNotchPreview: @escaping () -> Void,
        onSyncHotkeysEnabled: @escaping (Bool) -> Void,
        onSyncDefaultNotchTarget: @escaping (NotchTargetMode) -> Void = { _ in },
        onEnterMinimalCaptureMode: @escaping () -> Void = {},
        onImportMaterialPackage: (() -> Void)? = nil,
        onOpenSmartDeduplication: (() -> Void)? = nil,
        onClose: @escaping () -> Void
    ) {
        self.coordinator = coordinator
        self.library = library
        self.syncAndAI = syncAndAI
        self.appUpdater = appUpdater
        self.onToggleNotchPreview = onToggleNotchPreview
        self.onSyncHotkeysEnabled = onSyncHotkeysEnabled
        self.onSyncDefaultNotchTarget = onSyncDefaultNotchTarget
        self.onEnterMinimalCaptureMode = onEnterMinimalCaptureMode
        self.onImportMaterialPackage = onImportMaterialPackage
        self.onOpenSmartDeduplication = onOpenSmartDeduplication
        self.onClose = onClose
    }

    @State private var cardAppeared: Bool = false

    public var body: some View {
        ZStack {
            CharkleModalBackdrop(onTap: onClose)

            GeometryReader { geo in
                let maxAvailableWidth = max(360, geo.size.width - 24)
                let maxAvailableHeight = max(320, geo.size.height - 24)
                let modalWidth = min(max(560, geo.size.width - 72), min(880, maxAvailableWidth))
                let modalHeight = min(max(440, geo.size.height - 68), min(640, maxAvailableHeight))

                let cardShape = RoundedRectangle(cornerRadius: CharkleTheme.Radius.settingsOuter, style: .continuous)
                SettingsContentShell(
                    coordinator: coordinator,
                    library: library,
                    syncAndAI: syncAndAI,
                    appUpdater: appUpdater,
                    onToggleNotchPreview: onToggleNotchPreview,
                    onSyncHotkeysEnabled: onSyncHotkeysEnabled,
                    onSyncDefaultNotchTarget: onSyncDefaultNotchTarget,
                    onEnterMinimalCaptureMode: onEnterMinimalCaptureMode,
                    onImportMaterialPackage: onImportMaterialPackage,
                    onOpenSmartDeduplication: onOpenSmartDeduplication,
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
                            lineWidth: CharkleTheme.hairlineWidth
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
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    @State private var hoveredTab: CharkleSettingsTab? = nil
    @State private var fallbackLibrary: LibraryStore? = nil
    @Namespace private var navSelectionNamespace

    public let coordinator: AppCoordinatorStore
    public let library: LibraryStore?
    public let syncAndAI: SyncAndAIStore
    public let appUpdater: AppUpdateStore?
    public let onToggleNotchPreview: () -> Void
    public let onSyncHotkeysEnabled: (Bool) -> Void
    public let onSyncDefaultNotchTarget: (NotchTargetMode) -> Void
    public let onEnterMinimalCaptureMode: () -> Void
    public let onImportMaterialPackage: (() -> Void)?
    public let onOpenSmartDeduplication: (() -> Void)?
    public let onClose: (() -> Void)?

    public init(
        coordinator: AppCoordinatorStore,
        library: LibraryStore? = nil,
        syncAndAI: SyncAndAIStore,
        appUpdater: AppUpdateStore? = nil,
        onToggleNotchPreview: @escaping () -> Void,
        onSyncHotkeysEnabled: @escaping (Bool) -> Void,
        onSyncDefaultNotchTarget: @escaping (NotchTargetMode) -> Void = { _ in },
        onEnterMinimalCaptureMode: @escaping () -> Void = {},
        onImportMaterialPackage: (() -> Void)? = nil,
        onOpenSmartDeduplication: (() -> Void)? = nil,
        onClose: (() -> Void)? = nil
    ) {
        self.coordinator = coordinator
        self.library = library
        self.syncAndAI = syncAndAI
        self.appUpdater = appUpdater
        self.onToggleNotchPreview = onToggleNotchPreview
        self.onSyncHotkeysEnabled = onSyncHotkeysEnabled
        self.onSyncDefaultNotchTarget = onSyncDefaultNotchTarget
        self.onEnterMinimalCaptureMode = onEnterMinimalCaptureMode
        self.onImportMaterialPackage = onImportMaterialPackage
        self.onOpenSmartDeduplication = onOpenSmartDeduplication
        self.onClose = onClose
    }

    private var activeAccent: Color {
        CharkleTheme.accent(for: colorScheme, source: coordinator.accentSource)
    }

    public var body: some View {
        HStack(spacing: 0) {
            navigationRail
                .frame(width: 208)
                .background(SettingsPalette.railBackground(for: colorScheme))

            CharkleHairlineDivider(axis: .vertical)

            contentColumn
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(SettingsPalette.contentBackground(for: colorScheme))
        }
        .environment(\.charkleAccentSource, coordinator.accentSource)
        .tint(activeAccent)
        .task {
            // Avoid mutating 13 observable properties mid-open-animation when cached state is already populated.
            if syncAndAI.hasLoadedInitialState {
                try? await Task.sleep(for: .milliseconds(260))
                guard !Task.isCancelled else { return }
            }
            await syncAndAI.loadAll()
        }
        .onChange(of: syncAndAI.lastFeedbackEvent) { _, event in
            guard let event else { return }
            coordinator.showToast(
                event.message,
                icon: event.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill",
                tone: event.isError ? .error : .success,
                duration: event.isError ? 4.2 : nil
            )
        }
    }

    // MARK: - Left Navigation Rail

    private var navigationRail: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("设置")
                    .font(CharkleTheme.text(.headline, weight: .semibold))
                    .foregroundStyle(.primary)
                Spacer()
            }
            .padding(.horizontal, 16)
            .frame(height: 50)

            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(CharkleSettingsSection.allCases) { section in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(section.title)
                                .font(CharkleTheme.text(.caption, weight: .semibold))
                                .foregroundStyle(SettingsPalette.sectionLabel(for: colorScheme))
                                .padding(.horizontal, 10)
                                .padding(.bottom, 3)

                            ForEach(section.tabs) { tab in
                                sidebarItem(for: tab)
                            }
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 16)
                .charkleCleanScrollbars(hidden: true)
            }
            .scrollIndicators(.hidden)
        }
    }

    private func sidebarItem(for tab: CharkleSettingsTab) -> some View {
        let active = coordinator.selectedSettingsTab == tab
        let hovered = hoveredTab == tab
        let rowShape = RoundedRectangle(cornerRadius: CharkleTheme.Radius.settingsInner, style: .continuous)

        return Button {
            withAnimation(CharkleMotion.accessible(CharkleMotion.moveOnScreen, reduced: reduceMotion)) {
                coordinator.selectedSettingsTab = tab
            }
        } label: {
            HStack(spacing: 9) {
                Image(systemName: sfSymbolName(for: tab))
                    .font(.system(size: 13.5, weight: active ? .semibold : .medium))
                    .symbolVariant(active ? .fill : .none)
                    .foregroundStyle(active ? activeAccent : CharkleTheme.secondaryInk(for: colorScheme))
                    .frame(width: 18, height: 18)
                Text(tab.label)
                    .font(CharkleTheme.text(.body, weight: active ? .semibold : .regular))
                    .foregroundStyle(active ? Color.primary : Color.primary.opacity(hovered ? 0.90 : 0.78))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background {
                if active {
                    rowShape
                        .fill(
                            reduceTransparency
                                ? CharkleTheme.surfaceElevated(for: colorScheme)
                                : Color.primary.opacity(colorScheme == .dark ? 0.10 : 0.075)
                        )
                        .matchedGeometryEffect(id: "settings-rail-selection", in: navSelectionNamespace)
                } else if hovered {
                    rowShape
                        .fill(Color.primary.opacity(colorScheme == .dark ? 0.055 : 0.04))
                }
            }
            .contentShape(rowShape)
        }
        .buttonStyle(.plain)
        .onHover { isHovering in
            if isHovering {
                hoveredTab = tab
            } else if hoveredTab == tab {
                hoveredTab = nil
            }
        }
    }

    private func sfSymbolName(for tab: CharkleSettingsTab) -> String {
        switch tab {
        case .general: "gearshape"
        case .library: "photo.stack"
        case .sync: "icloud"
        case .notchShelf: "tray.and.arrow.down"
        case .captureShortcuts: "keyboard"
        case .ai: "sparkles"
        case .externalAgents: "terminal"
        case .extensions: "puzzlepiece.extension"
        case .advancedAbout: "wrench.and.screwdriver"
        }
    }

    // MARK: - Right Content Column

    private var contentColumn: some View {
        VStack(spacing: 0) {
            // Fixed pane title header + close button
            HStack(spacing: 10) {
                Text(coordinator.selectedSettingsTab.label)
                    .font(CharkleTheme.text(.headline, weight: .semibold))
                    .foregroundStyle(.primary)

                Spacer()

                if let onClose {
                    Button {
                        onClose()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 11.5, weight: .semibold))
                    }
                    .buttonStyle(.charkle(.subtle, size: .icon, iconDimension: 28))
                    .help("关闭设置 (Esc)")
                }
            }
            .padding(.horizontal, 24)
            .frame(height: 50)

            CharkleHairlineDivider()

            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 18) {
                    activePane
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 18)
                .charkleCleanScrollbars(hidden: false)
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
            LibrarySettingsPane(
                coordinator: coordinator,
                syncAndAI: syncAndAI,
                onImportMaterialPackage: onImportMaterialPackage,
                onOpenSmartDeduplication: onOpenSmartDeduplication
            )
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
            if let resolvedLibrary = library ?? fallbackLibrary {
                AdvancedAboutSettingsPane(
                    library: resolvedLibrary,
                    syncAndAI: syncAndAI,
                    appUpdater: appUpdater,
                    coordinator: coordinator
                )
            } else {
                Color.clear
                    .onAppear {
                        if fallbackLibrary == nil {
                            fallbackLibrary = LibraryStore(engine: syncAndAI.engine)
                        }
                    }
            }
        }
    }
}
