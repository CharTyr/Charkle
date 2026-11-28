import CharkleCore
import SwiftUI

// MARK: - 1:1 Desktop-Matched Studio Color Filter Panel

/// Calibrated color filter control matching macOS `CharkleColorFilterPopover` 1:1:
/// - 10 low-saturation studio swatches (5 × 2 grid) with double-ring active selection
/// - Native iOS `ColorPicker` (Color Wheel / Spectrum / Sliders / System Eyedropper)
/// - Custom `#RRGGBB` HEX entry with live swatch preview and instant normalization
/// - CIELAB matching tolerance slider (`10...55`) with `精确` ↔ `宽松` & `极近 / 相近 / 宽泛` tiers
struct MobileColorFilterPanel: View {
    @Bindable var store: MobileAppStore
    var title: String? = "主色调"
    var embedded: Bool = true

    @Environment(\.colorScheme) private var colorScheme
    @State private var hexDraft: String = ""

    private var activeHex: String? {
        store.criteria.selectedColorHex
    }

    private var colorPickerBinding: Binding<Color> {
        Binding(
            get: {
                if let hex = activeHex {
                    return Color(charkleHex: hex)
                }
                return MobileTheme.accent(for: colorScheme)
            },
            set: { newColor in
                if let hex = MobileTheme.hexString(from: newColor) {
                    store.setColorFilter(hex)
                }
            }
        )
    }

    var body: some View {
        let accent = MobileTheme.accent(for: colorScheme)

        let stack = VStack(alignment: .leading, spacing: 11) {
            if title != nil || activeHex != nil {
                HStack(spacing: 6) {
                    if let title {
                        Text(title)
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(MobileTheme.secondaryInk(for: colorScheme))
                    }

                    if let activeHex {
                        HStack(spacing: 4) {
                            Circle()
                                .fill(Color(charkleHex: activeHex))
                                .frame(width: 10, height: 10)
                                .overlay(
                                    Circle().strokeBorder(Color.primary.opacity(0.22), lineWidth: 0.5)
                                )
                            Text(activeHex.uppercased())
                                .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                                .foregroundStyle(.primary.opacity(0.88))
                        }
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(MobileTheme.surfaceSubtle(for: colorScheme), in: Capsule())
                    }

                    Spacer(minLength: 4)

                    if activeHex != nil {
                        Button("清除色彩") {
                            MobileKeyboard.dismiss()
                            store.setColorFilter(nil)
                        }
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(accent)
                        .buttonStyle(.plain)
                    }
                }
            }

            // 10 calibrated low-saturation studio swatches (5 × 2 grid matching desktop)
            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 5),
                spacing: 10
            ) {
                ForEach(MobileTheme.filterSwatches, id: \.self) { hex in
                    let isSelected = activeHex?.caseInsensitiveCompare(hex) == .orderedSame
                    Button {
                        MobileKeyboard.dismiss()
                        store.toggleColorFilter(hex)
                    } label: {
                        ZStack {
                            Circle()
                                .fill(Color(charkleHex: hex))
                                .frame(width: 30, height: 30)
                                .overlay(
                                    Circle().strokeBorder(
                                        isSelected ? accent : Color.primary.opacity(0.18),
                                        lineWidth: isSelected ? 2.5 : 0.75
                                    )
                                )
                            if isSelected {
                                Circle()
                                    .strokeBorder(MobileTheme.surfaceElevated(for: colorScheme), lineWidth: 1.75)
                                    .frame(width: 25, height: 25)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 34)
                        .contentShape(Circle())
                    }
                    .buttonStyle(MobileTactileButtonStyle())
                    .accessibilityLabel("按主色调筛选 \(hex)")
                }
            }

            // Native iOS Color Wheel / Eyedropper + Custom #RRGGBB HEX entry
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "eyedropper")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(MobileTheme.secondaryInk(for: colorScheme))
                    Text("选色 / 吸管")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    ColorPicker("", selection: colorPickerBinding, supportsOpacity: false)
                        .labelsHidden()
                        .frame(width: 26, height: 26)
                }
                .padding(.horizontal, 10)
                .frame(height: 34)
                .background(
                    MobileTheme.surfaceSubtle(for: colorScheme),
                    in: RoundedRectangle(cornerRadius: MobileTheme.Radius.chip, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: MobileTheme.Radius.chip, style: .continuous)
                        .strokeBorder(MobileTheme.hairline(for: colorScheme), lineWidth: 0.75)
                )

                HStack(spacing: 6) {
                    Circle()
                        .fill(
                            (MobileTheme.normalizedHex(hexDraft) ?? activeHex)
                                .map { Color(charkleHex: $0) }
                                ?? Color.primary.opacity(0.10)
                        )
                        .frame(width: 12, height: 12)
                        .overlay(
                            Circle().strokeBorder(Color.primary.opacity(0.20), lineWidth: 0.5)
                        )

                    TextField("#RRGGBB", text: $hexDraft)
                        .font(.system(size: 12.5, weight: .medium, design: .monospaced))
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .submitLabel(.done)
                        .onSubmit { commitHexDraft() }

                    if let parsed = MobileTheme.normalizedHex(hexDraft),
                       parsed.caseInsensitiveCompare(activeHex ?? "") != .orderedSame {
                        Button("应用") {
                            commitHexDraft()
                        }
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(MobileTheme.accentButtonFill(for: colorScheme), in: Capsule())
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 9)
                .frame(height: 34)
                .background(
                    MobileTheme.inspectorFieldSurface(for: colorScheme),
                    in: RoundedRectangle(cornerRadius: MobileTheme.Radius.chip, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: MobileTheme.Radius.chip, style: .continuous)
                        .strokeBorder(MobileTheme.hairline(for: colorScheme), lineWidth: 0.75)
                )
            }

            // CIELAB matching tolerance slider (10...55 matching desktop exactly)
            if activeHex != nil {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("匹配范围")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(MobileTheme.secondaryInk(for: colorScheme))
                        Spacer(minLength: 4)
                        Text("\(MobileTheme.colorToleranceLabel(store.criteria.colorTolerance)) · ΔE \(Int(store.criteria.colorTolerance.rounded()))")
                            .font(.system(size: 12, weight: .semibold).monospacedDigit())
                            .foregroundStyle(accent)
                    }

                    HStack(spacing: 8) {
                        Text("精确")
                            .font(.system(size: 11))
                            .foregroundStyle(MobileTheme.secondaryInk(for: colorScheme))
                        Slider(
                            value: Binding(
                                get: { store.criteria.colorTolerance },
                                set: { store.updateColorTolerance($0) }
                            ),
                            in: 10...55
                        )
                        .tint(accent)
                        Text("宽松")
                            .font(.system(size: 11))
                            .foregroundStyle(MobileTheme.secondaryInk(for: colorScheme))
                    }
                }
                .padding(.top, 2)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .onAppear {
            hexDraft = activeHex?.uppercased() ?? ""
        }
        .onChange(of: store.criteria.selectedColorHex) { _, newHex in
            let normalized = newHex?.uppercased() ?? ""
            if hexDraft.uppercased() != normalized {
                hexDraft = normalized
            }
        }

        if embedded {
            stack
        } else {
            stack
                .padding(14)
                .background(
                    MobileTheme.surfaceElevated(for: colorScheme),
                    in: RoundedRectangle(cornerRadius: MobileTheme.Radius.cardOuter, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: MobileTheme.Radius.cardOuter, style: .continuous)
                        .strokeBorder(MobileTheme.hairline(for: colorScheme), lineWidth: 0.75)
                )
        }
    }

    private func commitHexDraft() {
        MobileKeyboard.dismiss()
        let trimmed = hexDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            store.setColorFilter(nil)
            return
        }
        guard let normalized = MobileTheme.normalizedHex(trimmed) else { return }
        store.setColorFilter(normalized)
    }
}

// MARK: - Active Filter Tokens Row (Desktop Parity)

struct MobileActiveFilterTokensRow: View {
    @Bindable var store: MobileAppStore
    var showResultCount: Bool = true
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                if showResultCount {
                    Text("\(store.assets.count) 项")
                        .font(.system(size: 11.5, weight: .semibold).monospacedDigit())
                        .foregroundStyle(MobileTheme.secondaryInk(for: colorScheme))
                        .padding(.trailing, 2)
                }

                if let hex = store.criteria.selectedColorHex {
                    tokenChip(label: hex.uppercased(), dotHex: hex) {
                        store.setColorFilter(nil)
                    }
                }

                ForEach(MediaKind.allCases.filter { store.criteria.kinds.contains($0) }, id: \.self) { kind in
                    tokenChip(label: kind.localizedLabel, symbol: MobileTheme.mediaKindSymbol(for: kind)) {
                        store.criteria.kinds.remove(kind)
                        Task { await store.reloadAssets() }
                    }
                }

                if let shape = store.criteria.shape {
                    tokenChip(label: shape.localizedLabel) {
                        store.criteria.shape = nil
                        Task { await store.reloadAssets() }
                    }
                }

                if store.criteria.minRating > 0 {
                    tokenChip(label: "\(store.criteria.minRating)★ 以上", symbol: "star.fill") {
                        store.criteria.minRating = 0
                        Task { await store.reloadAssets() }
                    }
                }

                ForEach(store.criteria.tags.sorted(by: { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }), id: \.self) { tag in
                    tokenChip(label: "#\(tag)") {
                        store.criteria.tags.remove(tag)
                        Task { await store.reloadAssets() }
                    }
                }

                if store.criteria.onlyPinnedOffline {
                    tokenChip(label: "本地保留", symbol: "arrow.down.circle.fill") {
                        store.criteria.onlyPinnedOffline = false
                        Task { await store.reloadAssets() }
                    }
                }

                Button("清除全部") {
                    store.clearFilters()
                }
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(MobileTheme.accent(for: colorScheme))
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .buttonStyle(.plain)
            }
        }
    }

    private func tokenChip(
        label: String,
        symbol: String? = nil,
        dotHex: String? = nil,
        onRemove: @escaping () -> Void
    ) -> some View {
        Button(action: onRemove) {
            HStack(spacing: 4.5) {
                if let dotHex {
                    Circle()
                        .fill(Color(charkleHex: dotHex))
                        .frame(width: 10, height: 10)
                        .overlay(Circle().strokeBorder(.primary.opacity(0.2), lineWidth: 0.5))
                } else if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(MobileTheme.accent(for: colorScheme))
                }
                Text(label)
                    .font(.system(size: 11.5, weight: .medium))
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(MobileTheme.tertiaryInk(for: colorScheme))
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(MobileTheme.surfaceSubtle(for: colorScheme), in: Capsule())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Compact iPad / Embedded Gallery Search & Filter Bar

struct FilterBarView: View {
    @Bindable var store: MobileAppStore
    let isCompact: Bool
    var focusSearchTrigger: UInt64 = 0
    let onOpenFilterSheet: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @FocusState private var isSearchFieldFocused: Bool
    @State private var showColorPanel = false

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                // Unified Search capsule (instant literal + automatic hybrid semantic fusion)
                HStack(spacing: 7) {
                    Group {
                        if store.isRunningSemanticSearch {
                            ProgressView()
                                .controlSize(.mini)
                        } else {
                            Image(systemName: "magnifyingglass")
                                .font(.system(size: 13.5, weight: .medium))
                                .foregroundStyle(MobileTheme.secondaryInk(for: colorScheme))
                        }
                    }
                    .frame(width: 16, height: 16)

                    TextField(
                        "搜索素材、描述画面、标签或颜色…",
                        text: Binding(
                            get: { store.criteria.searchQuery },
                            set: { store.updateSearchQuery($0) }
                        )
                    )
                    .font(.system(size: 14))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                    .focused($isSearchFieldFocused)
                    .onSubmit {
                        store.submitSearch()
                    }
                    .onChange(of: focusSearchTrigger) { _, _ in
                        isSearchFieldFocused = true
                    }

                    if !store.criteria.searchQuery.isEmpty {
                        Button {
                            store.updateSearchQuery("")
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 14))
                                .foregroundStyle(MobileTheme.tertiaryInk(for: colorScheme))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.leading, 12)
                .padding(.trailing, 10)
                .padding(.vertical, 8)
                .background(
                    MobileTheme.surfaceElevated(for: colorScheme),
                    in: Capsule()
                )
                .overlay(
                    Capsule().strokeBorder(MobileTheme.hairline(for: colorScheme), lineWidth: 0.75)
                )

                // Color panel toggle button
                Button {
                    withAnimation(MobileMotion.settleStrong) {
                        showColorPanel.toggle()
                    }
                } label: {
                    ZStack {
                        if let hex = store.criteria.selectedColorHex {
                            Circle()
                                .fill(Color(charkleHex: hex))
                                .frame(width: 18, height: 18)
                                .overlay(Circle().strokeBorder(.white.opacity(0.85), lineWidth: 1.5))
                        } else {
                            Image(systemName: "paintpalette")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(showColorPanel ? MobileTheme.accent(for: colorScheme) : .primary)
                        }
                    }
                    .frame(width: 36, height: 36)
                    .background(
                        showColorPanel || store.criteria.selectedColorHex != nil
                            ? MobileTheme.accentSoft(for: colorScheme)
                            : MobileTheme.surfaceElevated(for: colorScheme),
                        in: Circle()
                    )
                    .overlay(Circle().strokeBorder(MobileTheme.hairline(for: colorScheme), lineWidth: 0.75))
                }
                .buttonStyle(MobileTactileButtonStyle())
                .accessibilityLabel("按主色筛选")

                // Filter sheet button
                Button(action: onOpenFilterSheet) {
                    Image(systemName: store.criteria.hasActiveVisualFilters ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(store.criteria.hasActiveVisualFilters ? MobileTheme.accent(for: colorScheme) : .primary)
                        .frame(width: 36, height: 36)
                        .background(
                            store.criteria.hasActiveVisualFilters
                                ? MobileTheme.accentSoft(for: colorScheme)
                                : MobileTheme.surfaceElevated(for: colorScheme),
                            in: Circle()
                        )
                        .overlay(Circle().strokeBorder(MobileTheme.hairline(for: colorScheme), lineWidth: 0.75))
                }
                .buttonStyle(MobileTactileButtonStyle())
                .accessibilityLabel("筛选与排序")

                // Layout switcher (Masonry <-> Compact Studio View, per-folder remembered)
                Button {
                    MobileHaptics.selection()
                    let next: GalleryLayoutMode = store.activeGalleryLayoutMode == .compactList
                        ? .verticalMasonry
                        : .compactList
                    withAnimation(MobileMotion.settleStrong) {
                        store.setGalleryLayoutMode(next, rememberForCurrentScope: true)
                    }
                } label: {
                    Image(systemName: store.activeGalleryLayoutMode == .compactList ? "list.bullet" : "square.grid.2x2")
                        .font(.system(size: 14.5, weight: .semibold))
                        .foregroundStyle(
                            store.activeGalleryLayoutMode == .compactList
                                ? MobileTheme.accent(for: colorScheme)
                                : .primary
                        )
                        .frame(width: 36, height: 36)
                        .background(
                            store.activeGalleryLayoutMode == .compactList
                                ? MobileTheme.accentSoft(for: colorScheme)
                                : MobileTheme.surfaceElevated(for: colorScheme),
                            in: Circle()
                        )
                        .overlay(Circle().strokeBorder(MobileTheme.hairline(for: colorScheme), lineWidth: 0.75))
                }
                .buttonStyle(MobileTactileButtonStyle())
                .accessibilityLabel(store.activeGalleryLayoutMode == .compactList ? "切回纵向瀑布流" : "切换紧凑视图")

                // Sort, density & multi-select menu
                Menu {
                    Picker("画廊视图", selection: Binding(
                        get: { store.activeGalleryLayoutMode },
                        set: { store.setGalleryLayoutMode($0, rememberForCurrentScope: true) }
                    )) {
                        Label("纵向瀑布流", systemImage: "square.grid.2x2")
                            .tag(GalleryLayoutMode.verticalMasonry)
                        Label("紧凑视图", systemImage: "list.bullet")
                            .tag(GalleryLayoutMode.compactList)
                    }

                    Divider()

                    Picker("排序方式", selection: Binding(
                        get: { store.criteria.sortBy },
                        set: { next in
                            store.criteria.sortBy = next
                            Task { await store.reloadAssets() }
                        }
                    )) {
                        ForEach(SortOrder.allCases, id: \.self) { order in
                            Text(order.localizedLabel).tag(order)
                        }
                    }

                    Menu("列数密度") {
                        Button("自动适配") { store.columnCountOverride = nil }
                        ForEach(isCompact ? [1, 2, 3, 4, 5] : [2, 3, 4, 5, 6, 7], id: \.self) { count in
                            Button("\(count) 列") { store.columnCountOverride = count }
                        }
                    }

                    Divider()

                    Button(store.isMultiSelectMode ? "退出多选" : "多选批处理", systemImage: "checkmark.circle") {
                        store.isMultiSelectMode.toggle()
                        if !store.isMultiSelectMode {
                            store.selectedAssetIDs.removeAll()
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.primary)
                        .frame(width: 36, height: 36)
                        .background(MobileTheme.surfaceElevated(for: colorScheme), in: Circle())
                        .overlay(Circle().strokeBorder(MobileTheme.hairline(for: colorScheme), lineWidth: 0.75))
                }
                .accessibilityLabel("画廊视图选项")
            }
            .padding(.horizontal, isCompact ? 10 : 16)
            .padding(.top, 8)

            if showColorPanel {
                MobileColorFilterPanel(store: store, title: "主色调", embedded: false)
                    .padding(.horizontal, isCompact ? 10 : 16)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            if store.hasActiveFilters {
                MobileActiveFilterTokensRow(store: store)
                    .padding(.horizontal, isCompact ? 10 : 16)
            }
        }
        .padding(.bottom, 4)
    }
}

// MARK: - Comprehensive Desktop-Parity Filter & Sort Sheet

struct FilterOptionsSheet: View {
    @Bindable var store: MobileAppStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Form {
            Section {
                MobileColorFilterPanel(store: store, title: "主色调", embedded: true)
                    .padding(.vertical, 4)
            }

            Section("媒体类型") {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 94), spacing: 8)], spacing: 8) {
                    ForEach(MediaKind.allCases, id: \.self) { kind in
                        let selected = store.criteria.kinds.contains(kind)
                        Button {
                            if selected {
                                store.criteria.kinds.remove(kind)
                            } else {
                                store.criteria.kinds.insert(kind)
                            }
                            Task { await store.reloadAssets() }
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: MobileTheme.mediaKindSymbol(for: kind))
                                    .font(.system(size: 12, weight: .medium))
                                    .symbolVariant(selected ? .fill : .none)
                                Text(kind.localizedLabel)
                                    .font(.system(size: 12.5, weight: selected ? .semibold : .regular))
                                    .lineLimit(1)
                            }
                            .foregroundStyle(selected ? .white : .primary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(
                                selected
                                    ? MobileTheme.accentButtonFill(for: colorScheme)
                                    : MobileTheme.surfaceSubtle(for: colorScheme),
                                in: RoundedRectangle(cornerRadius: MobileTheme.Radius.chip, style: .continuous)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 4)
            }

            Section("画幅比例") {
                HStack(spacing: 8) {
                    ForEach(AspectShape.allCases, id: \.self) { shape in
                        let selected = store.criteria.shape == shape
                        Button {
                            store.criteria.shape = selected ? nil : shape
                            Task { await store.reloadAssets() }
                        } label: {
                            Text(shape.localizedLabel)
                                .font(.system(size: 13, weight: selected ? .semibold : .medium))
                                .foregroundStyle(selected ? .white : .primary)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 8)
                                .background(
                                    selected
                                        ? MobileTheme.accentButtonFill(for: colorScheme)
                                        : MobileTheme.surfaceSubtle(for: colorScheme),
                                    in: RoundedRectangle(cornerRadius: MobileTheme.Radius.chip, style: .continuous)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 2)
            }

            Section("评分与离线保留") {
                HStack {
                    Text("最低评分")
                        .font(.system(size: 14))
                    Spacer()
                    HStack(spacing: 4) {
                        ForEach(1...5, id: \.self) { star in
                            let filled = star <= store.criteria.minRating
                            Button {
                                MobileHaptics.light()
                                store.criteria.minRating = (store.criteria.minRating == star) ? 0 : star
                                Task { await store.reloadAssets() }
                            } label: {
                                Image(systemName: filled ? "star.fill" : "star")
                                    .font(.system(size: 18, weight: .medium))
                                    .foregroundStyle(
                                        filled
                                            ? Color(charkleHex: "#E5B243")
                                            : MobileTheme.tertiaryInk(for: colorScheme)
                                    )
                                    .frame(width: 28, height: 28)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                Toggle("仅显示本地保留原图", isOn: Binding(
                    get: { store.criteria.onlyPinnedOffline },
                    set: { next in
                        store.criteria.onlyPinnedOffline = next
                        Task { await store.reloadAssets() }
                    }
                ))
            }

            Section {
                Picker("视图模式", selection: Binding(
                    get: { store.activeGalleryLayoutMode },
                    set: { store.setGalleryLayoutMode($0, rememberForCurrentScope: true) }
                )) {
                    Label("纵向瀑布流", systemImage: "square.grid.2x2")
                        .tag(GalleryLayoutMode.verticalMasonry)
                    Label("紧凑视图", systemImage: "list.bullet")
                        .tag(GalleryLayoutMode.compactList)
                }
                .pickerStyle(.segmented)
            } header: {
                Text("画廊视图（按当前目录自动记忆）")
            }

            Section("排序方式") {
                Picker("排序", selection: Binding(
                    get: { store.criteria.sortBy },
                    set: { next in
                        store.criteria.sortBy = next
                        Task { await store.reloadAssets() }
                    }
                )) {
                    ForEach(SortOrder.allCases, id: \.self) { order in
                        Text(order.localizedLabel).tag(order)
                    }
                }
            }
        }
        .scrollDismissesKeyboard(.immediately)
        .navigationTitle("筛选与排序")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("清除全部") { store.clearFilters() }
                    .disabled(!store.hasActiveFilters)
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("完成") { dismiss() }
            }
        }
    }
}

// MARK: - Dedicated "搜图" Tab (1:1 Desktop Search, Color Search, Semantic Search & True Waterfall Masonry)

struct VisualSearchTabView: View {
    @Bindable var store: MobileAppStore
    var isTabActive: Bool = true
    let zoomNamespace: Namespace.ID
    let onOpenAsset: (AssetRecord) -> Void
    let onFindSimilar: (AssetRecord) -> Void
    let onNavigateToScope: (MobileScope) -> Void
    let onOpenBoard: (UUID) -> Void
    var onOpenPinterestSpace: (() -> Void)? = nil
    var externalSearchBarActive: Bool = false
    var searchScopeMode: MobileSearchScopeMode = .all
    var activeFolderScopeTitle: String? = nil
    var onClearFolderScope: (() -> Void)? = nil

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var isColorPanelExpanded: Bool = true
    @State private var isVisualFilterExpanded: Bool = false
    @State private var shareAssetURL: URL?
    @State private var singleDeleteAssetID: UUID?
    @State private var singleMoveAsset: AssetRecord?

    // Two-finger pinch zoom state
    @State private var pinchBaselineScale: CGFloat = 1.0
    @State private var didDismissKeyboardForPinch: Bool = false
    @State private var activePinchLabel: String?
    @State private var pinchBadgeDismissTask: Task<Void, Never>?

    private var activeVisualFilterCount: Int {
        store.criteria.kinds.count
            + (store.criteria.shape != nil ? 1 : 0)
            + (store.criteria.minRating > 0 ? 1 : 0)
            + (store.criteria.onlyPinnedOffline ? 1 : 0)
    }

    var body: some View {
        GeometryReader { proxy in
            let colCount = MobileMasonryLayout.resolvedColumnCount(
                for: proxy.size.width,
                isCompact: true,
                override: store.columnCountOverride
            )
            let spacing = MobileMasonryLayout.adaptiveSpacing(for: colCount, isCompact: true)
            let cardCornerRadius = MobileMasonryLayout.adaptiveCornerRadius(for: colCount)
            let horizontalPadding: CGFloat = colCount >= 4 ? (colCount >= 5 ? 2 : 5) : 12
            let columns = isTabActive
                ? MobileMasonryLayout.distributeIntoColumns(store.assets, count: colCount)
                : Array(repeating: [AssetRecord](), count: colCount)

            ZStack(alignment: .top) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if let onOpenPinterestSpace {
                            HStack(spacing: 4) {
                                Text("库内搜图")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(.white)
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 34)
                                    .background(MobileTheme.accentButtonFill(for: colorScheme), in: Capsule())

                                Button {
                                    MobileKeyboard.dismiss()
                                    MobileHaptics.light()
                                    onOpenPinterestSpace()
                                } label: {
                                    HStack(spacing: 5) {
                                        Image(systemName: "sparkles")
                                            .font(.system(size: 12, weight: .semibold))
                                        Text("Pinterest 空间")
                                            .font(.system(size: 13, weight: .semibold))
                                        if store.pinterestController.trayCount > 0 {
                                            Text("\(store.pinterestController.trayCount)")
                                                .font(.system(size: 11, weight: .bold).monospacedDigit())
                                                .foregroundStyle(.white)
                                                .padding(.horizontal, 6)
                                                .padding(.vertical, 1)
                                                .background(MobileTheme.accent(for: colorScheme), in: Capsule())
                                        }
                                    }
                                    .foregroundStyle(.primary)
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 34)
                                    .contentShape(Capsule())
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(3)
                            .background(MobileTheme.surfaceSubtle(for: colorScheme), in: Capsule())
                            .padding(.horizontal, 14)
                        }

                        // 1. Unified Search Field (hidden on iPhone when bottom Liquid Search bar is expanded)
                        if !externalSearchBarActive {
                            searchFieldRow
                                .padding(.horizontal, 14)
                        } else if searchScopeMode == .currentFolder, let folderTitle = activeFolderScopeTitle {
                            HStack(spacing: 8) {
                                Label("仅在「\(folderTitle)」中搜图", systemImage: "folder.fill")
                                    .font(.system(size: 12.5, weight: .semibold))
                                    .foregroundStyle(MobileTheme.positive(for: colorScheme))
                                Spacer()
                                if let onClearFolderScope {
                                    Button("切回全库") {
                                        MobileHaptics.light()
                                        onClearFolderScope()
                                    }
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(MobileTheme.accent(for: colorScheme))
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(
                                MobileTheme.positive(for: colorScheme).opacity(colorScheme == .dark ? 0.16 : 0.10),
                                in: RoundedRectangle(cornerRadius: 11, style: .continuous)
                            )
                            .padding(.horizontal, 14)
                        }

                        // 2. Quick toggle strip: 主色调 · 筛选条件 · 排序
                        quickFilterToolbar
                            .padding(.horizontal, 14)

                        // 3. Inline Removable Active Filter Tokens
                        if store.hasActiveFilters {
                            MobileActiveFilterTokensRow(store: store, showResultCount: false)
                                .padding(.horizontal, 14)
                        }

                        // 4. Desktop 1:1 Studio Color Search Panel (5x2 Swatches + Color Wheel/Eyedropper + #HEX + CIELAB Tolerance)
                        if isColorPanelExpanded {
                            MobileColorFilterPanel(store: store, title: "按色彩搜图", embedded: false)
                                .padding(.horizontal, 14)
                                .transition(.opacity.combined(with: .move(edge: .top)))
                        }

                        // 6. Desktop 1:1 Visual Filters Panel (Media Kinds / Aspect Shape / 5-Star Rating / Local Retention)
                        if isVisualFilterExpanded {
                            inlineVisualFiltersCard
                                .padding(.horizontal, 14)
                                .transition(.opacity.combined(with: .move(edge: .top)))
                        }

                        // 7. Quick Jump Matches (Folders / Moodboards / Tags when searching)
                        if !store.quickJumpMatches.isEmpty {
                            quickJumpStrip
                                .padding(.horizontal, 14)
                        }

                        // 8. Common Tag Chips
                        if !store.tagCounts.isEmpty {
                            commonTagsStrip
                                .padding(.horizontal, 14)
                        }

                        // 9. Results Header + True Balanced Waterfall Masonry (Zero Landscape Stretching)
                        HStack(spacing: 8) {
                            Text("匹配结果（\(store.assets.count)）")
                                .font(.system(size: 13, weight: .semibold).monospacedDigit())
                                .foregroundStyle(MobileTheme.secondaryInk(for: colorScheme))
                            Spacer()
                            if store.hasActiveFilters {
                                Button("重置") {
                                    MobileKeyboard.dismiss()
                                    store.clearFilters()
                                }
                                    .font(.system(size: 12.5, weight: .semibold))
                                    .foregroundStyle(MobileTheme.accent(for: colorScheme))
                            }
                        }
                        .padding(.horizontal, 14)
                        .padding(.top, 2)

                        if store.assets.isEmpty {
                            MobileEmptyStateView(
                                kind: .noSearchResults,
                                title: "未找到匹配素材",
                                subtitle: "试试换个画面描述词、调宽色彩容差，或切换色轮选色。",
                                primaryActionTitle: store.hasActiveFilters ? "清除条件" : nil,
                                primaryAction: store.hasActiveFilters ? { store.clearFilters() } : nil
                            )
                            .frame(minHeight: 260)
                            .padding(.horizontal, 14)
                        } else {
                            HStack(alignment: .top, spacing: spacing) {
                                ForEach(0..<colCount, id: \.self) { colIndex in
                                    LazyVStack(spacing: spacing) {
                                        ForEach(columns[colIndex]) { asset in
                                            GalleryCardView(
                                                asset: asset,
                                                store: store,
                                                zoomNamespace: zoomNamespace,
                                                zoomOrigin: .visualSearch,
                                                cornerRadius: cardCornerRadius,
                                                isDenseOverview: colCount >= 4,
                                                isMultiSelect: false,
                                                isSelected: false,
                                                onTap: {
                                                    MobileKeyboard.dismiss()
                                                    onOpenAsset(asset)
                                                },
                                                onFindSimilar: {
                                                    MobileKeyboard.dismiss()
                                                    onFindSimilar(asset)
                                                },
                                                onShareOriginal: {
                                                    Task { await shareAsset(asset) }
                                                },
                                                onRequestPermanentDelete: {
                                                    singleDeleteAssetID = asset.id
                                                },
                                                onSelectMultiple: {
                                                    MobileKeyboard.dismiss()
                                                    store.isMultiSelectMode = true
                                                    store.selectedAssetIDs.insert(asset.id)
                                                    onNavigateToScope(store.scope)
                                                },
                                                onOpenFolderPicker: {
                                                    MobileKeyboard.dismiss()
                                                    singleMoveAsset = asset
                                                }
                                            )
                                        }
                                    }
                                }
                            }
                            .padding(.horizontal, horizontalPadding)
                            .animation(
                                MobileMotion.accessible(MobileMotion.gestureSpring, reduced: reduceMotion),
                                value: colCount
                            )
                        }
                    }
                    .padding(.top, 10)
                    .padding(.bottom, 40)
                }
                .charkleDismissKeyboardOnScroll()
                .background(MobileTheme.galleryGround(for: colorScheme))
                .charkleScrollEdgeSoft(for: .bottom)
                .simultaneousGesture(pinchColumnZoomGesture(currentWidth: proxy.size.width))

                if let activePinchLabel {
                    Text(activePinchLabel)
                        .font(.system(size: 12.5, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .charkleFloatingCapsule()
                        .padding(.top, 12)
                        .transition(.opacity.combined(with: .scale(scale: 0.94)))
                        .allowsHitTesting(false)
                }
            }
        }
        .onChange(of: searchScopeMode) { _, mode in
            if mode == .color && !isColorPanelExpanded {
                withAnimation(MobileMotion.accessible(MobileMotion.settleStrong, reduced: reduceMotion)) {
                    isColorPanelExpanded = true
                }
            }
        }
        .sheet(item: $singleMoveAsset) { target in
            NavigationStack {
                HierarchicalFolderPickerSheet(
                    title: "移动到文件夹",
                    folderTree: store.folderTree,
                    currentFolderID: target.folderID,
                    onPick: { folderID, folderName in
                        let id = target.id
                        singleMoveAsset = nil
                        Task {
                            await store.patchAssets(
                                AssetBatchPatch(
                                    assetIDs: [id],
                                    folderAssignment: folderID.map { .folder($0) } ?? .inbox
                                ),
                                successToast: folderID == nil ? "已移回收件箱" : "已归档到「\(folderName)」"
                            )
                        }
                    }
                )
            }
            .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: Binding(
            get: { shareAssetURL != nil },
            set: { if !$0 { shareAssetURL = nil } }
        )) {
            if let shareAssetURL {
                ActivityShareSheet(items: [shareAssetURL])
            }
        }
        .confirmationDialog(
            "永久删除此素材？",
            isPresented: Binding(
                get: { singleDeleteAssetID != nil },
                set: { if !$0 { singleDeleteAssetID = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("永久删除", role: .destructive) {
                if let id = singleDeleteAssetID {
                    singleDeleteAssetID = nil
                    Task { await store.permanentlyDelete(ids: [id]) }
                }
            }
            Button("取消", role: .cancel) { singleDeleteAssetID = nil }
        } message: {
            Text("彻底删除后将无法从回收站恢复。")
        }
    }

    // MARK: - Unified Search Field

    private var searchFieldRow: some View {
        HStack(spacing: 8) {
            Group {
                if store.isRunningSemanticSearch {
                    ProgressView()
                        .controlSize(.mini)
                } else {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 14.5, weight: .medium))
                        .foregroundStyle(MobileTheme.secondaryInk(for: colorScheme))
                }
            }
            .frame(width: 18, height: 18)

            TextField(
                "搜索素材、描述画面、拼音、标签或颜色…",
                text: Binding(
                    get: { store.criteria.searchQuery },
                    set: { store.updateSearchQuery($0) }
                )
            )
            .font(.system(size: 14.5))
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .submitLabel(.search)
            .onSubmit {
                store.submitSearch()
            }

            if !store.criteria.searchQuery.isEmpty {
                Button {
                    store.updateSearchQuery("")
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(MobileTheme.tertiaryInk(for: colorScheme))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 10)
        .background(
            MobileTheme.surfaceElevated(for: colorScheme),
            in: RoundedRectangle(cornerRadius: MobileTheme.Radius.cardOuter, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: MobileTheme.Radius.cardOuter, style: .continuous)
                .strokeBorder(MobileTheme.hairline(for: colorScheme), lineWidth: 0.75)
        )
    }

    // MARK: - Quick Filter Toolbar (主色调 · 筛选 · 排序)

    private var quickFilterToolbar: some View {
        let accent = MobileTheme.accent(for: colorScheme)
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Button {
                    MobileKeyboard.dismiss()
                    withAnimation(MobileMotion.accessible(MobileMotion.settleStrong, reduced: reduceMotion)) {
                        isColorPanelExpanded.toggle()
                    }
                } label: {
                    HStack(spacing: 5) {
                        if let hex = store.criteria.selectedColorHex {
                            Circle()
                                .fill(Color(charkleHex: hex))
                                .frame(width: 12, height: 12)
                                .overlay(Circle().strokeBorder(.primary.opacity(0.22), lineWidth: 0.5))
                            Text(hex.uppercased())
                                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        } else {
                            Image(systemName: "paintpalette")
                                .font(.system(size: 12.5, weight: .medium))
                            Text("主色调")
                                .font(.system(size: 12.5, weight: .semibold))
                        }
                        Image(systemName: isColorPanelExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 9.5, weight: .bold))
                    }
                    .foregroundStyle(
                        (isColorPanelExpanded || store.criteria.selectedColorHex != nil) ? accent : .primary
                    )
                    .padding(.horizontal, 11)
                    .frame(height: 32)
                    .background(
                        (isColorPanelExpanded || store.criteria.selectedColorHex != nil)
                            ? MobileTheme.accentSoft(for: colorScheme)
                            : MobileTheme.surfaceElevated(for: colorScheme),
                        in: Capsule()
                    )
                    .overlay(Capsule().strokeBorder(MobileTheme.hairline(for: colorScheme), lineWidth: 0.75))
                }
                .buttonStyle(MobileTactileButtonStyle())

                Button {
                    MobileKeyboard.dismiss()
                    withAnimation(MobileMotion.accessible(MobileMotion.settleStrong, reduced: reduceMotion)) {
                        isVisualFilterExpanded.toggle()
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "line.3.horizontal.decrease.circle")
                            .font(.system(size: 13, weight: .medium))
                            .symbolVariant(activeVisualFilterCount > 0 ? .fill : .none)
                        Text(activeVisualFilterCount > 0 ? "筛选 · \(activeVisualFilterCount)" : "媒体与评分")
                            .font(.system(size: 12.5, weight: .semibold).monospacedDigit())
                        Image(systemName: isVisualFilterExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 9.5, weight: .bold))
                    }
                    .foregroundStyle(
                        (isVisualFilterExpanded || activeVisualFilterCount > 0) ? accent : .primary
                    )
                    .padding(.horizontal, 11)
                    .frame(height: 32)
                    .background(
                        (isVisualFilterExpanded || activeVisualFilterCount > 0)
                            ? MobileTheme.accentSoft(for: colorScheme)
                            : MobileTheme.surfaceElevated(for: colorScheme),
                        in: Capsule()
                    )
                    .overlay(Capsule().strokeBorder(MobileTheme.hairline(for: colorScheme), lineWidth: 0.75))
                }
                .buttonStyle(MobileTactileButtonStyle())

                Menu {
                    ForEach(SortOrder.allCases, id: \.self) { order in
                        Button {
                            MobileKeyboard.dismiss()
                            store.criteria.sortBy = order
                            Task { await store.reloadAssets() }
                        } label: {
                            if store.criteria.sortBy == order {
                                Label(order.localizedLabel, systemImage: "checkmark")
                            } else {
                                Text(order.localizedLabel)
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "arrow.up.arrow.down")
                            .font(.system(size: 11.5, weight: .medium))
                        Text(store.criteria.sortBy.localizedLabel)
                            .font(.system(size: 12.5, weight: .medium))
                    }
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 11)
                    .frame(height: 32)
                    .background(MobileTheme.surfaceElevated(for: colorScheme), in: Capsule())
                    .overlay(Capsule().strokeBorder(MobileTheme.hairline(for: colorScheme), lineWidth: 0.75))
                }
            }
        }
        .charkleDismissKeyboardOnScroll()
    }

    // MARK: - Inline Desktop-Parity Visual Filters Card

    private var inlineVisualFiltersCard: some View {
        let accent = MobileTheme.accent(for: colorScheme)
        return VStack(alignment: .leading, spacing: 12) {
            // Media kinds with desktop SF Symbols
            VStack(alignment: .leading, spacing: 7) {
                Text("媒体类型")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(MobileTheme.secondaryInk(for: colorScheme))

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 84), spacing: 7)], spacing: 7) {
                    ForEach(MediaKind.allCases, id: \.self) { kind in
                        let active = store.criteria.kinds.contains(kind)
                        Button {
                            MobileHaptics.light()
                            if active {
                                store.criteria.kinds.remove(kind)
                            } else {
                                store.criteria.kinds.insert(kind)
                            }
                            Task { await store.reloadAssets() }
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: MobileTheme.mediaKindSymbol(for: kind))
                                    .font(.system(size: 11, weight: .medium))
                                    .symbolVariant(active ? .fill : .none)
                                Text(kind.localizedLabel)
                                    .font(.system(size: 12, weight: active ? .semibold : .medium))
                                    .lineLimit(1)
                            }
                            .foregroundStyle(active ? .white : .primary)
                            .frame(maxWidth: .infinity)
                            .frame(height: 30)
                            .background(
                                active
                                    ? MobileTheme.accentButtonFill(for: colorScheme)
                                    : MobileTheme.surfaceSubtle(for: colorScheme),
                                in: RoundedRectangle(cornerRadius: MobileTheme.Radius.chip, style: .continuous)
                            )
                        }
                        .buttonStyle(MobileTactileButtonStyle())
                    }
                }
            }

            Divider()

            // Aspect Orientation
            VStack(alignment: .leading, spacing: 7) {
                Text("画幅比例")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(MobileTheme.secondaryInk(for: colorScheme))

                HStack(spacing: 7) {
                    ForEach(AspectShape.allCases, id: \.self) { shape in
                        let active = store.criteria.shape == shape
                        Button {
                            MobileHaptics.light()
                            store.criteria.shape = active ? nil : shape
                            Task { await store.reloadAssets() }
                        } label: {
                            Text(shape.localizedLabel)
                                .font(.system(size: 12, weight: active ? .semibold : .medium))
                                .foregroundStyle(active ? .white : .primary)
                                .frame(maxWidth: .infinity)
                                .frame(height: 30)
                                .background(
                                    active
                                        ? MobileTheme.accentButtonFill(for: colorScheme)
                                        : MobileTheme.surfaceSubtle(for: colorScheme),
                                    in: RoundedRectangle(cornerRadius: MobileTheme.Radius.chip, style: .continuous)
                                )
                        }
                        .buttonStyle(MobileTactileButtonStyle())
                    }
                }
            }

            Divider()

            // Minimum Rating (5-star tap row) + Local Offline Retention
            HStack(spacing: 8) {
                HStack(spacing: 3) {
                    Text("最低评分")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(MobileTheme.secondaryInk(for: colorScheme))
                        .padding(.trailing, 4)

                    ForEach(1...5, id: \.self) { star in
                        let filled = star <= store.criteria.minRating
                        Button {
                            MobileHaptics.light()
                            store.criteria.minRating = (store.criteria.minRating == star) ? 0 : star
                            Task { await store.reloadAssets() }
                        } label: {
                            Image(systemName: filled ? "star.fill" : "star")
                                .font(.system(size: 15, weight: .medium))
                                .foregroundStyle(
                                    filled ? Color(charkleHex: "#E5B243") : MobileTheme.tertiaryInk(for: colorScheme)
                                )
                                .frame(width: 24, height: 28)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }

                Spacer(minLength: 4)

                Button {
                    MobileHaptics.light()
                    store.criteria.onlyPinnedOffline.toggle()
                    Task { await store.reloadAssets() }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: store.criteria.onlyPinnedOffline ? "arrow.down.circle.fill" : "arrow.down.circle")
                            .font(.system(size: 12, weight: .medium))
                        Text("本地保留")
                            .font(.system(size: 12, weight: store.criteria.onlyPinnedOffline ? .semibold : .medium))
                    }
                    .foregroundStyle(store.criteria.onlyPinnedOffline ? accent : MobileTheme.secondaryInk(for: colorScheme))
                    .padding(.horizontal, 10)
                    .frame(height: 30)
                    .background(
                        store.criteria.onlyPinnedOffline
                            ? MobileTheme.accentSoft(for: colorScheme)
                            : MobileTheme.surfaceSubtle(for: colorScheme),
                        in: RoundedRectangle(cornerRadius: MobileTheme.Radius.chip, style: .continuous)
                    )
                }
                .buttonStyle(MobileTactileButtonStyle())
            }
        }
        .padding(14)
        .background(
            MobileTheme.surfaceElevated(for: colorScheme),
            in: RoundedRectangle(cornerRadius: MobileTheme.Radius.cardOuter, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: MobileTheme.Radius.cardOuter, style: .continuous)
                .strokeBorder(MobileTheme.hairline(for: colorScheme), lineWidth: 0.75)
        )
    }

    // MARK: - Quick Jump Matches & Common Tags

    private var quickJumpStrip: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("快速直达")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(MobileTheme.secondaryInk(for: colorScheme))

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(store.quickJumpMatches) { match in
                        Button {
                            MobileKeyboard.dismiss()
                            MobileHaptics.light()
                            switch match.kind {
                            case .folder:
                                if let id = match.targetUUID {
                                    onNavigateToScope(.folder(id))
                                }
                            case .moodboard:
                                if let id = match.targetUUID {
                                    onOpenBoard(id)
                                }
                            case .tag:
                                if let tag = match.tagName {
                                    store.criteria.tags.insert(tag)
                                    Task { await store.reloadAssets() }
                                }
                            case .asset:
                                break
                            }
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: iconForQuickJump(match.kind))
                                    .font(.system(size: 11.5, weight: .semibold))
                                    .foregroundStyle(MobileTheme.accent(for: colorScheme))
                                Text(match.title)
                                    .font(.system(size: 12.5, weight: .medium))
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(MobileTheme.surfaceElevated(for: colorScheme), in: Capsule())
                            .overlay(Capsule().strokeBorder(MobileTheme.hairline(for: colorScheme), lineWidth: 0.75))
                        }
                        .buttonStyle(MobileTactileButtonStyle())
                    }
                }
            }
        }
    }

    private var commonTagsStrip: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("常用标签")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(MobileTheme.secondaryInk(for: colorScheme))
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 7) {
                    ForEach(store.tagCounts.prefix(16)) { item in
                        let active = store.criteria.tags.contains(item.name)
                        Button {
                            MobileKeyboard.dismiss()
                            MobileHaptics.light()
                            if active {
                                store.criteria.tags.remove(item.name)
                            } else {
                                store.criteria.tags.insert(item.name)
                            }
                            Task { await store.reloadAssets() }
                        } label: {
                            Text("#\(item.name) · \(item.count)")
                                .font(.system(size: 12, weight: active ? .semibold : .medium).monospacedDigit())
                                .foregroundStyle(active ? .white : .primary)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5.5)
                                .background(
                                    active
                                        ? MobileTheme.accentButtonFill(for: colorScheme)
                                        : MobileTheme.surfaceSubtle(for: colorScheme),
                                    in: Capsule()
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .charkleDismissKeyboardOnScroll()
        }
    }

    private func iconForQuickJump(_ kind: QuickJumpKind) -> String {
        switch kind {
        case .folder: "folder.fill"
        case .moodboard: "rectangle.3.group"
        case .tag: "number"
        case .asset: "photo"
        }
    }

    // MARK: - Pinch Zoom & Share Helpers

    private func pinchColumnZoomGesture(currentWidth: CGFloat) -> some Gesture {
        MagnifyGesture()
            .onChanged { value in
                if !didDismissKeyboardForPinch {
                    didDismissKeyboardForPinch = true
                    MobileKeyboard.dismiss()
                }
                let relative = value.magnification / max(0.01, pinchBaselineScale)

                let current = MobileMasonryLayout.resolvedColumnCount(
                    for: currentWidth,
                    isCompact: true,
                    override: store.columnCountOverride
                )

                if relative <= 0.86, current < 5 {
                    let next = current + 1
                    withAnimation(MobileMotion.accessible(MobileMotion.gestureSpring, reduced: reduceMotion)) {
                        store.columnCountOverride = next
                    }
                    pinchBaselineScale = value.magnification
                    MobileHaptics.selection()
                    flashPinchBadge("\(next) 列")
                } else if relative >= 1.15, current > 1 {
                    let next = current - 1
                    withAnimation(MobileMotion.accessible(MobileMotion.gestureSpring, reduced: reduceMotion)) {
                        store.columnCountOverride = next
                    }
                    pinchBaselineScale = value.magnification
                    MobileHaptics.selection()
                    flashPinchBadge("\(next) 列")
                }
            }
            .onEnded { _ in
                pinchBaselineScale = 1.0
                didDismissKeyboardForPinch = false
            }
    }

    private func flashPinchBadge(_ text: String) {
        pinchBadgeDismissTask?.cancel()
        withAnimation(MobileMotion.enterSm) {
            activePinchLabel = text
        }
        pinchBadgeDismissTask = Task {
            try? await Task.sleep(for: .milliseconds(850))
            guard !Task.isCancelled else { return }
            withAnimation(MobileMotion.exitSm) {
                activePinchLabel = nil
            }
        }
    }

    private func shareAsset(_ asset: AssetRecord) async {
        if let url = await store.shareableOriginalURL(for: asset) {
            shareAssetURL = url
        } else {
            store.showToast("暂无法获取可分享的原文件", tone: .warning)
        }
    }
}
