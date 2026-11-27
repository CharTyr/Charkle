import CharkleCore
import SwiftUI

enum MobilePrimaryTab: Int, CaseIterable, Hashable, Sendable {
    case library = 0
    case inbox = 1
    case moodboards = 2

    var title: String {
        switch self {
        case .library: "素材库"
        case .inbox: "收件箱"
        case .moodboards: "情绪板"
        }
    }

    var icon: String {
        switch self {
        case .library: "square.grid.2x2"
        case .inbox: "tray"
        case .moodboards: "rectangle.3.group"
        }
    }

    var activeIcon: String {
        switch self {
        case .library: "square.grid.2x2.fill"
        case .inbox: "tray.fill"
        case .moodboards: "rectangle.3.group.fill"
        }
    }
}

enum MobileSearchScopeMode: String, CaseIterable, Identifiable, Sendable {
    case all
    case color
    case currentFolder
    case pinterest

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "全部素材"
        case .color: "按主色调搜图"
        case .currentFolder: "仅当前文件夹"
        case .pinterest: "Pinterest 空间"
        }
    }

    var placeholder: String {
        switch self {
        case .all: "搜索素材或画面描述…"
        case .color: "关键词或点上方色板…"
        case .currentFolder: "在当前目录中搜图…"
        case .pinterest: "探索 Pinterest 灵感…"
        }
    }

    var symbol: String {
        switch self {
        case .all: "magnifyingglass"
        case .color: "paintpalette.fill"
        case .currentFolder: "folder.fill"
        case .pinterest: "sparkles"
        }
    }

    func accentColor(for scheme: ColorScheme) -> Color {
        switch self {
        case .all: MobileTheme.accent(for: scheme)
        case .color: MobileTheme.warning(for: scheme)
        case .currentFolder: MobileTheme.positive(for: scheme)
        case .pinterest: MobileTheme.destructive(for: scheme)
        }
    }
}

private struct CharkleMorphGlassIDModifier: ViewModifier {
    let id: String
    let namespace: Namespace.ID

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffectID(id, in: namespace)
        } else {
            content.matchedGeometryEffect(id: id, in: namespace)
        }
    }
}

private extension View {
    func charkleMorphGlassID(_ id: String, in namespace: Namespace.ID) -> some View {
        modifier(CharkleMorphGlassIDModifier(id: id, namespace: namespace))
    }
}

/// Video-inspired Liquid Glass Morphing Bottom Bar for iPhone (Scheme A):
/// - Default state: Left 3-tab Liquid Glass capsule (`素材库` / `收件箱` / `情绪板`) with real-time
///   horizontal drag-scrubbing refracting lens + swipe-up/re-tap on `素材库` to open Directory & Filters;
///   Right compact companion capsule (`⚙️` 1-tap Settings with live sync status dot + `🔍` Liquid Search).
/// - Expanded state: Tapping `🔍` morphs the 3-tab bar into a circular return button, detaches `⚙️` into
///   its own circle, and stretches `🔍` into a full thumb-reachable bottom Liquid Search input bar with a
///   trailing scope circle that melts open a 4-mode Liquid Glass picker popover.
struct LiquidGlassMorphingTabBar: View {
    @Bindable var store: MobileAppStore
    @Binding var activeTab: CompactTab
    @Binding var lastPrimaryTab: MobilePrimaryTab
    @Binding var isSearchExpanded: Bool
    @Binding var searchScopeMode: MobileSearchScopeMode

    let onOpenDirectoryAndFilters: () -> Void
    let onSelectSettings: () -> Void
    let onSelectSearchMode: (MobileSearchScopeMode) -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    @Namespace private var morphNamespace
    @FocusState private var isSearchFieldFocused: Bool

    @State private var isScopeMenuOpen: Bool = false

    // Horizontal drag-scrubbing refracting lens state
    @State private var isScrubbing: Bool = false
    @State private var scrubCenterX: CGFloat = 0
    @State private var scrubHoverTab: MobilePrimaryTab? = nil
    @State private var dragStartTab: MobilePrimaryTab? = nil
    @State private var didTriggerLibrarySwipeUp: Bool = false

    private var morphAnimation: Animation {
        reduceMotion
            ? MobileMotion.reducedFade
            : .spring(response: 0.42, dampingFraction: 0.82)
    }

    private var popoverAnimation: Animation {
        reduceMotion
            ? MobileMotion.reducedFade
            : .spring(response: 0.36, dampingFraction: 0.80)
    }

    private var syncStatusDotColor: Color {
        if case .error = store.syncStatus.phase {
            return MobileTheme.destructive(for: colorScheme)
        }
        if store.isSyncing || store.syncStatus.isSyncing {
            return MobileTheme.accent(for: colorScheme)
        }
        return store.hasConnectedCloudBackend
            ? MobileTheme.positive(for: colorScheme)
            : MobileTheme.warning(for: colorScheme)
    }

    private var activePrimaryTab: MobilePrimaryTab? {
        switch activeTab {
        case .library: .library
        case .inbox: .inbox
        case .moodboards: .moodboards
        case .search, .settings: nil
        }
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            // Transparent hit-catcher when the scope picker popover is open
            if isScopeMenuOpen {
                Color.black.opacity(0.001)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture {
                        withAnimation(popoverAnimation) {
                            isScopeMenuOpen = false
                        }
                    }
                    .zIndex(1)
            }

            VStack(alignment: .trailing, spacing: 10) {
                if isScopeMenuOpen && isSearchExpanded {
                    searchScopePopoverMenu
                        .padding(.trailing, 14)
                        .transition(
                            reduceMotion
                                ? .opacity
                                : .scale(scale: 0.22, anchor: .bottomTrailing).combined(with: .opacity)
                        )
                        .zIndex(3)
                }

                CharkleGlassCluster(spacing: 8) {
                    HStack(spacing: 8) {
                        if !isSearchExpanded {
                            primaryTabCapsule
                                .charkleMorphGlassID("primaryTabs", in: morphNamespace)

                            rightCompanionCapsule
                                .charkleMorphGlassID("companionDock", in: morphNamespace)
                        } else {
                            collapsedReturnCircle
                                .charkleMorphGlassID("primaryTabs", in: morphNamespace)

                            detachedSettingsCircle
                                .charkleMorphGlassID("settingsSlot", in: morphNamespace)

                            expandedSearchCapsule
                                .charkleMorphGlassID("companionDock", in: morphNamespace)
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 8)
                .zIndex(2)
            }
        }
        .animation(morphAnimation, value: isSearchExpanded)
        .animation(popoverAnimation, value: isScopeMenuOpen)
        .onChange(of: isSearchExpanded) { _, expanded in
            if !expanded {
                isScopeMenuOpen = false
                isSearchFieldFocused = false
            }
        }
    }

    // MARK: - Default Left 3-Tab Capsule with Interactive Scrubbing Lens

    private var primaryTabCapsule: some View {
        GeometryReader { proxy in
            let inset: CGFloat = 4
            let innerWidth = max(60, proxy.size.width - inset * 2)
            let slotWidth = innerWidth / CGFloat(MobilePrimaryTab.allCases.count)
            let highlightedTab = isScrubbing ? scrubHoverTab : activePrimaryTab
            let targetIndex = highlightedTab?.rawValue
            let restingX: CGFloat = {
                guard let idx = targetIndex else { return inset }
                return inset + CGFloat(idx) * slotWidth
            }()
            let liveLensX: CGFloat = {
                if isScrubbing {
                    let clamped = max(inset, min(proxy.size.width - inset - slotWidth, scrubCenterX - slotWidth / 2))
                    return clamped
                }
                return restingX
            }()

            ZStack(alignment: .leading) {
                // Sliding & scrubbing Liquid Glass refracting lens
                if highlightedTab != nil {
                    scrubbingLensView
                        .frame(width: slotWidth, height: proxy.size.height - inset * 2)
                        .offset(x: liveLensX)
                        .animation(
                            isScrubbing
                                ? .interactiveSpring(response: 0.16, dampingFraction: 0.86)
                                : MobileMotion.accessible(MobileMotion.gestureSpring, reduced: reduceMotion),
                            value: liveLensX
                        )
                        .animation(
                            MobileMotion.accessible(.spring(response: 0.24, dampingFraction: 0.78), reduced: reduceMotion),
                            value: isScrubbing
                        )
                }

                HStack(spacing: 0) {
                    ForEach(MobilePrimaryTab.allCases, id: \.self) { tab in
                        let isHighlighted = highlightedTab == tab
                        VStack(spacing: 3) {
                            ZStack(alignment: .topTrailing) {
                                Image(systemName: isHighlighted ? tab.activeIcon : tab.icon)
                                    .font(.system(size: 18, weight: .semibold))
                                    .frame(height: 20)

                                if tab == .inbox && store.inboxCount > 0 {
                                    Text(store.inboxCount > 99 ? "99+" : "\(store.inboxCount)")
                                        .font(.system(size: 9.5, weight: .bold).monospacedDigit())
                                        .foregroundStyle(.white)
                                        .padding(.horizontal, 4.5)
                                        .frame(minWidth: 15, minHeight: 15)
                                        .background(MobileTheme.accent(for: colorScheme), in: Capsule())
                                        .offset(x: 11, y: -5)
                                }
                            }
                            Text(tab.title)
                                .font(.system(size: 10, weight: .semibold))
                                .lineLimit(1)
                        }
                        .foregroundStyle(isHighlighted ? MobileTheme.accent(for: colorScheme) : .primary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .contentShape(Rectangle())
                        .accessibilityAddTraits(isHighlighted ? [.isButton, .isSelected] : .isButton)
                        .accessibilityLabel(tab.title)
                    }
                }
                .padding(.horizontal, inset)
            }
            .contentShape(Capsule())
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .local)
                    .onChanged { value in
                        let loc = value.location
                        let startIdx = tabIndex(at: value.startLocation.x, totalWidth: proxy.size.width, inset: inset)
                        if dragStartTab == nil {
                            dragStartTab = MobilePrimaryTab(rawValue: startIdx)
                            didTriggerLibrarySwipeUp = false
                        }

                        let dx = value.translation.width
                        let dy = value.translation.height

                        // Swipe up on Library slot -> open Directory & Filters sheet
                        if dragStartTab == .library,
                           !isScrubbing,
                           !didTriggerLibrarySwipeUp,
                           dy <= -18,
                           abs(dy) > abs(dx) * 1.25 {
                            didTriggerLibrarySwipeUp = true
                            MobileHaptics.light()
                            onOpenDirectoryAndFilters()
                            return
                        }

                        if !didTriggerLibrarySwipeUp, !isScrubbing, abs(dx) > 6 {
                            isScrubbing = true
                            scrubCenterX = loc.x
                            scrubHoverTab = MobilePrimaryTab(rawValue: startIdx)
                            MobileHaptics.light()
                        }

                        if isScrubbing {
                            scrubCenterX = loc.x
                            let idx = tabIndex(at: loc.x, totalWidth: proxy.size.width, inset: inset)
                            if let hovered = MobilePrimaryTab(rawValue: idx), hovered != scrubHoverTab {
                                scrubHoverTab = hovered
                                MobileHaptics.light()
                            }
                        }
                    }
                    .onEnded { value in
                        defer {
                            isScrubbing = false
                            scrubHoverTab = nil
                            dragStartTab = nil
                            didTriggerLibrarySwipeUp = false
                        }
                        guard !didTriggerLibrarySwipeUp else { return }

                        let endIdx = tabIndex(at: value.location.x, totalWidth: proxy.size.width, inset: inset)
                        let chosen = (isScrubbing ? scrubHoverTab : nil) ?? MobilePrimaryTab(rawValue: endIdx) ?? .library

                        // Re-tapping active `素材库` tab opens Directory & Filters directly
                        if !isScrubbing && chosen == .library && activeTab == .library {
                            MobileHaptics.light()
                            onOpenDirectoryAndFilters()
                            return
                        }

                        let targetCompactTab: CompactTab = switch chosen {
                        case .library: .library
                        case .inbox: .inbox
                        case .moodboards: .moodboards
                        }
                        if activeTab != targetCompactTab {
                            MobileHaptics.light()
                            activeTab = targetCompactTab
                        }
                        lastPrimaryTab = chosen
                    }
            )
        }
        .frame(height: 60)
        .frame(maxWidth: .infinity)
        .charkleFloatingCapsule(interactive: true)
    }

    @ViewBuilder
    private var scrubbingLensView: some View {
        if isScrubbing {
            Capsule()
                .fill(
                    reduceTransparency
                        ? MobileTheme.surfaceElevated(for: colorScheme)
                        : (colorScheme == .dark ? Color.white.opacity(0.16) : Color.white.opacity(0.86))
                )
                .overlay(
                    Capsule().strokeBorder(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(colorScheme == .dark ? 0.42 : 0.96),
                                MobileTheme.accent(for: colorScheme).opacity(0.28)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
                )
                .shadow(color: .black.opacity(colorScheme == .dark ? 0.35 : 0.14), radius: 10, y: 4)
                .scaleEffect(x: 1.06, y: 1.12)
        } else {
            Capsule()
                .fill(MobileTheme.accentSoft(for: colorScheme))
        }
    }

    private func tabIndex(at x: CGFloat, totalWidth: CGFloat, inset: CGFloat) -> Int {
        let count = MobilePrimaryTab.allCases.count
        let inner = max(1, totalWidth - inset * 2)
        let normalized = max(0, min(inner - 0.001, x - inset))
        return max(0, min(count - 1, Int((normalized / inner) * CGFloat(count))))
    }

    // MARK: - Default Right Companion Capsule (`⚙️` 1-Tap Settings + `🔍` Liquid Search)

    private var rightCompanionCapsule: some View {
        HStack(spacing: 5) {
            Button {
                MobileHaptics.light()
                onSelectSettings()
            } label: {
                ZStack(alignment: .bottomTrailing) {
                    Circle()
                        .fill(
                            activeTab == .settings
                                ? MobileTheme.accentSoft(for: colorScheme)
                                : MobileTheme.surfaceSubtle(for: colorScheme).opacity(colorScheme == .dark ? 0.55 : 0.72)
                        )
                        .frame(width: 44, height: 44)
                        .overlay {
                            Image(systemName: activeTab == .settings ? "gearshape.fill" : "gearshape")
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundStyle(activeTab == .settings ? MobileTheme.accent(for: colorScheme) : .primary)
                        }

                    Circle()
                        .fill(syncStatusDotColor)
                        .frame(width: 9.5, height: 9.5)
                        .overlay(
                            Circle().strokeBorder(MobileTheme.surfaceElevated(for: colorScheme), lineWidth: 1.6)
                        )
                        .offset(x: -1, y: -1)
                }
                .contentShape(Circle())
            }
            .buttonStyle(MobileTactileButtonStyle())
            .accessibilityLabel("设置")

            Button {
                MobileHaptics.light()
                withAnimation(morphAnimation) {
                    isSearchExpanded = true
                    activeTab = .search
                }
                if searchScopeMode != .pinterest {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) {
                        if isSearchExpanded {
                            isSearchFieldFocused = true
                        }
                    }
                }
            } label: {
                Circle()
                    .fill(MobileTheme.accentSoft(for: colorScheme))
                    .frame(width: 44, height: 44)
                    .overlay {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(MobileTheme.accent(for: colorScheme))
                    }
                    .contentShape(Circle())
            }
            .buttonStyle(MobileTactileButtonStyle())
            .accessibilityLabel("搜图")
        }
        .padding(.horizontal, 7)
        .frame(height: 60)
        .charkleFloatingCapsule(interactive: true)
    }

    // MARK: - Expanded Morph State: [Return Circle] [Settings Circle] [Liquid Search Bar + Scope Button]

    private var collapsedReturnCircle: some View {
        Button {
            MobileHaptics.light()
            isSearchFieldFocused = false
            withAnimation(morphAnimation) {
                isScopeMenuOpen = false
                isSearchExpanded = false
                switch lastPrimaryTab {
                case .library: activeTab = .library
                case .inbox: activeTab = .inbox
                case .moodboards: activeTab = .moodboards
                }
            }
        } label: {
            Image(systemName: lastPrimaryTab.activeIcon)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 56, height: 56)
                .contentShape(Circle())
        }
        .buttonStyle(MobileTactileButtonStyle())
        .charkleFloatingCircle(interactive: true)
        .accessibilityLabel("返回\(lastPrimaryTab.title)")
    }

    private var detachedSettingsCircle: some View {
        Button {
            MobileHaptics.light()
            isSearchFieldFocused = false
            withAnimation(morphAnimation) {
                isScopeMenuOpen = false
                isSearchExpanded = false
            }
            onSelectSettings()
        } label: {
            ZStack(alignment: .bottomTrailing) {
                Image(systemName: "gearshape")
                    .font(.system(size: 17.5, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 56, height: 56)

                Circle()
                    .fill(syncStatusDotColor)
                    .frame(width: 9, height: 9)
                    .overlay(
                        Circle().strokeBorder(MobileTheme.surfaceElevated(for: colorScheme), lineWidth: 1.5)
                    )
                    .offset(x: -11, y: -11)
            }
            .contentShape(Circle())
        }
        .buttonStyle(MobileTactileButtonStyle())
        .charkleFloatingCircle(interactive: true)
        .accessibilityLabel("打开设置")
    }

    private var expandedSearchCapsule: some View {
        let modeColor = searchScopeMode.accentColor(for: colorScheme)
        return HStack(spacing: 8) {
            Group {
                if store.isRunningSemanticSearch {
                    ProgressView()
                        .controlSize(.mini)
                } else {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(MobileTheme.secondaryInk(for: colorScheme))
                }
            }
            .frame(width: 18, height: 18)

            TextField(
                searchScopeMode.placeholder,
                text: Binding(
                    get: { store.criteria.searchQuery },
                    set: { store.updateSearchQuery($0) }
                )
            )
            .font(.system(size: 14.5))
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .submitLabel(.search)
            .focused($isSearchFieldFocused)
            .onSubmit {
                store.submitSearch()
            }

            if !store.criteria.searchQuery.isEmpty {
                Button {
                    MobileHaptics.light()
                    store.updateSearchQuery("")
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 15.5))
                        .foregroundStyle(MobileTheme.tertiaryInk(for: colorScheme))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("清空搜索词")
            }

            Button {
                MobileHaptics.light()
                isSearchFieldFocused = false
                withAnimation(popoverAnimation) {
                    isScopeMenuOpen.toggle()
                }
            } label: {
                Circle()
                    .fill(modeColor.opacity(colorScheme == .dark ? 0.24 : 0.16))
                    .frame(width: 40, height: 40)
                    .overlay {
                        Image(systemName: searchScopeMode.symbol)
                            .font(.system(size: 15.5, weight: .semibold))
                            .foregroundStyle(modeColor)
                            .contentTransition(.symbolEffect(.replace))
                    }
                    .contentShape(Circle())
            }
            .buttonStyle(MobileTactileButtonStyle())
            .accessibilityLabel("切换搜索范围")
        }
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .frame(height: 56)
        .frame(maxWidth: .infinity)
        .charkleFloatingCapsule(interactive: true)
    }

    // MARK: - Liquid Glass Floating Scope Popover (Grows Above Trailing Circle)

    private var searchScopePopoverMenu: some View {
        VStack(spacing: 3) {
            ForEach(MobileSearchScopeMode.allCases) { mode in
                let isSelected = searchScopeMode == mode
                let modeColor = mode.accentColor(for: colorScheme)
                Button {
                    MobileHaptics.light()
                    withAnimation(popoverAnimation) {
                        isScopeMenuOpen = false
                    }
                    onSelectSearchMode(mode)
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "checkmark")
                            .font(.system(size: 12.5, weight: .bold))
                            .foregroundStyle(.primary)
                            .opacity(isSelected ? 1 : 0)
                            .frame(width: 15)

                        Text(mode.title)
                            .font(.system(size: 14.5, weight: isSelected ? .semibold : .medium))
                            .foregroundStyle(.primary)
                            .lineLimit(1)

                        Spacer(minLength: 4)

                        Circle()
                            .fill(modeColor.opacity(colorScheme == .dark ? 0.24 : 0.16))
                            .frame(width: 28, height: 28)
                            .overlay {
                                Image(systemName: mode.symbol)
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(modeColor)
                            }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(
                        isSelected
                            ? MobileTheme.surfaceSubtle(for: colorScheme).opacity(colorScheme == .dark ? 0.72 : 0.88)
                            : .clear,
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(MobileTactileButtonStyle())
            }
        }
        .padding(7)
        .frame(width: 218)
        .charkleFloatingCard(cornerRadius: 24, interactive: true)
    }
}
