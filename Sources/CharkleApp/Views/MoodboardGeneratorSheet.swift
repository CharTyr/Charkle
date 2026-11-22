import CharkleCanvas
import CharkleCore
import SwiftUI

/// 4-Entry Rapid Moodboard Generator Sheet (`灵感词` / `种子图` / `配色定调` / `当前框选`):
/// Lets designers generate a curated 12–20 item editorial moodboard draft + 20–40 candidate pool
/// + extracted 5–7 color palette in under 10 seconds.
public struct MoodboardGeneratorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public let coordinator: AppCoordinatorStore
    public let library: LibraryStore
    public let moodboards: MoodboardStore

    @Namespace private var entryTabNamespace

    @State private var activeEntry: MoodboardGeneratorEntry = .prompt
    @State private var promptText: String = ""
    @State private var selectedSeedIDs: Set<UUID> = []
    @State private var selectedPaletteHexes: [String] = ["#3D5A80", "#D4A373"]
    @State private var colorTolerance: Double = 28.0
    @State private var customColor: Color = Color(charkleHex: "#5C6B73")
    @State private var boardTitle: String = ""

    private static let presetPrompts: [String] = [
        "京都雨夜霓虹与湿润反光",
        "低饱和奶油陶瓷与柔和自然光",
        "粗野主义建筑几何与混凝土阴影",
        "瑞士网格排版与编辑部留白"
    ]

    private static let curatedSwatches: [String] = [
        "#253237", "#3D5A80", "#5C6B73", "#6B8E76",
        "#D4A373", "#C8B8A6", "#BA6B55", "#E5B243",
        "#1E2024", "#DCDAD4"
    ]

    public init(
        coordinator: AppCoordinatorStore,
        library: LibraryStore,
        moodboards: MoodboardStore
    ) {
        self.coordinator = coordinator
        self.library = library
        self.moodboards = moodboards
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Header + Unified 4-Entry Segmented Pill
            HStack {
                HStack(spacing: 8) {
                    CharkleIcon("sparkle-board", style: .layered, size: 24)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("10 秒快速生成情绪板")
                            .font(.system(size: 15, weight: .semibold))
                        Text("端侧 Vision / CIELAB 即时策展 · 自动生成主稿 + 候选替换池")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                HStack(spacing: 2) {
                    ForEach(MoodboardGeneratorEntry.allCases, id: \.self) { entry in
                        let isSelected = activeEntry == entry
                        Button {
                            withAnimation(CharkleMotion.accessible(CharkleMotion.settleStrong, reduced: reduceMotion)) {
                                activeEntry = entry
                            }
                            triggerPreviewGeneration()
                        } label: {
                            Text(entry.label)
                                .font(.system(size: 12, weight: isSelected ? .semibold : .medium))
                                .foregroundStyle(isSelected ? .primary : .secondary)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background {
                                    if isSelected {
                                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                                            .fill(CharkleTheme.surfaceElevated(for: colorScheme))
                                            .shadow(color: .black.opacity(0.08), radius: 3, y: 1)
                                            .matchedGeometryEffect(id: "gen-entry-pill", in: entryTabNamespace)
                                    }
                                }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(3)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)

            Divider()

            // Split Workspace: Left Seed Input / Right Live Draft Preview
            HStack(spacing: 0) {
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 16) {
                        switch activeEntry {
                        case .prompt:
                            promptEntryPanel
                        case .seedAssets:
                            seedAssetsEntryPanel
                        case .palette:
                            paletteEntryPanel
                        case .selection:
                            selectionEntryPanel
                        }

                        Button {
                            triggerPreviewGeneration()
                        } label: {
                            HStack(spacing: 6) {
                                if moodboards.isGeneratingProposal {
                                    ProgressView().controlSize(.small)
                                } else {
                                    Image(systemName: "wand.and.stars")
                                        .font(.system(size: 12, weight: .semibold))
                                }
                                Text(moodboards.isGeneratingProposal ? "正在策展排版…" : "刷新推荐初稿")
                                    .font(.system(size: 12.5, weight: .semibold))
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        }
                        .buttonStyle(CharkleTactileButtonStyle())
                        .disabled(moodboards.isGeneratingProposal)
                    }
                    .padding(20)
                }
                .frame(width: 340)

                Divider()

                // Right Live Preview Pane
                liveProposalPreviewPane
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            Divider()

            // Footer Action Bar
            HStack(spacing: 12) {
                TextField("输入情绪板标题…", text: $boardTitle)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 260)

                if let prop = moodboards.proposal {
                    Text(prop.usedCloudAI ? "已启用云端增强智能" : "端侧离线即时策展")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.primary.opacity(0.05), in: Capsule(style: .continuous))
                }

                Spacer()

                Button("取消") {
                    moodboards.proposal = nil
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button("创建并打开情绪板") {
                    Task {
                        let title = boardTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            ? defaultBoardTitle
                            : boardTitle
                        if moodboards.proposal == nil {
                            await runGenerationNow()
                        }
                        if let created = await moodboards.confirmProposal(title: title, subtitle: promptText) {
                            coordinator.openMoodboard(created.id)
                            coordinator.showToast("已创建情绪板「\(created.title)」", icon: "sparkles.rectangle.stack")
                            dismiss()
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .frame(width: 860, height: 590)
        .background(CharkleTheme.galleryGround(for: colorScheme))
        .onAppear {
            activeEntry = coordinator.generatorInitialEntry
            if !library.selectedAssetIDs.isEmpty {
                selectedSeedIDs = Set(library.selectedAssetIDs.prefix(3))
            }
            triggerPreviewGeneration()
        }
    }

    // MARK: - 4 Entry Panels

    private var promptEntryPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("描述你想探索的视觉氛围或主题")
                .font(.system(size: 12.5, weight: .semibold))
            TextField("例如：京都雨夜霓虹、奶油陶艺、复古印刷排版…", text: $promptText, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(3...5)
                .onSubmit { triggerPreviewGeneration() }

            Text("灵感方向示例")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)

            CharkleFlowLayout(spacing: 6, lineSpacing: 6) {
                ForEach(Self.presetPrompts, id: \.self) { sample in
                    Button {
                        promptText = sample
                        if boardTitle.isEmpty { boardTitle = sample }
                        triggerPreviewGeneration()
                    } label: {
                        Text(sample)
                            .font(.system(size: 11.5))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(CharkleTheme.surfaceElevated(for: colorScheme), in: Capsule(style: .continuous))
                            .overlay(
                                Capsule(style: .continuous)
                                    .strokeBorder(CharkleTheme.hairline(for: colorScheme), lineWidth: 0.75)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var seedAssetsEntryPanel: some View {
        let candidates = library.allAssetsByID.values.filter { !$0.isTrashed }.sorted { $0.createdAt > $1.createdAt }
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("选择 1–3 张定调种子图")
                    .font(.system(size: 12.5, weight: .semibold))
                Spacer()
                Text("已选 \(selectedSeedIDs.count)/3")
                    .font(.system(size: 11, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }

            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                ForEach(candidates.prefix(18)) { asset in
                    let isPicked = selectedSeedIDs.contains(asset.id)
                    Button {
                        if isPicked {
                            selectedSeedIDs.remove(asset.id)
                        } else {
                            if selectedSeedIDs.count >= 3, let first = selectedSeedIDs.first {
                                selectedSeedIDs.remove(first)
                            }
                            selectedSeedIDs.insert(asset.id)
                        }
                        triggerPreviewGeneration()
                    } label: {
                        AssetThumbnailSurface(
                            asset: asset,
                            loader: library.thumbnailLoader,
                            tier: .grid520,
                            cornerRadius: 8
                        )
                        .frame(height: 76)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(isPicked ? Color.accentColor : Color.clear, lineWidth: 2.5)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var paletteEntryPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("点选 1–3 个核心定调色彩（CIELAB 感知匹配）")
                .font(.system(size: 12.5, weight: .semibold))

            CharkleFlowLayout(spacing: 8, lineSpacing: 8) {
                ForEach(Self.curatedSwatches, id: \.self) { hex in
                    let active = selectedPaletteHexes.contains(hex)
                    Button {
                        if active {
                            if selectedPaletteHexes.count > 1 {
                                selectedPaletteHexes.removeAll { $0 == hex }
                            }
                        } else {
                            if selectedPaletteHexes.count >= 3 {
                                selectedPaletteHexes.removeFirst()
                            }
                            selectedPaletteHexes.append(hex)
                        }
                        triggerPreviewGeneration()
                    } label: {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color(charkleHex: hex))
                            .frame(width: 36, height: 36)
                            .overlay(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .strokeBorder(active ? Color.accentColor : Color.primary.opacity(0.14), lineWidth: active ? 2.5 : 0.75)
                            )
                    }
                    .buttonStyle(.plain)
                    .help(hex)
                }
            }

            HStack {
                Text("色彩容差 ΔE")
                    .font(.system(size: 11.5, weight: .medium))
                Spacer()
                Text("\(Int(colorTolerance))")
                    .font(.system(size: 11.5, design: .monospaced))
                    .monospacedDigit()
            }
            Slider(value: $colorTolerance, in: 10...55, step: 2)
                .onChange(of: colorTolerance) { _, _ in
                    triggerPreviewGeneration()
                }
        }
    }

    private var selectionEntryPanel: some View {
        let selected = library.selectedAssets
        return VStack(alignment: .leading, spacing: 10) {
            Text("基于当前素材库框选内容 (\(selected.count) 项)")
                .font(.system(size: 12.5, weight: .semibold))
            if selected.isEmpty {
                Text("当前未在素材库选中素材。将自动使用最近添加的素材构建情绪板，或返回画廊先框选一批作品。")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            } else {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                    ForEach(selected.prefix(12)) { asset in
                        AssetThumbnailSurface(
                            asset: asset,
                            loader: library.thumbnailLoader,
                            tier: .grid520,
                            cornerRadius: 8
                        )
                        .frame(height: 68)
                    }
                }
            }
        }
    }

    // MARK: - Live Draft Preview Pane

    private var liveProposalPreviewPane: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 14) {
                if let prop = moodboards.proposal {
                    HStack {
                        Text("主画布初稿预览（\(prop.primaryMatches.count) 张）")
                            .font(.system(size: 12.5, weight: .semibold))
                        Spacer()
                        Text("候选替换池 +\(prop.candidatePool.count) 张")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                    }

                    // Extracted Harmonious Board Palette
                    if !prop.extractedPalette.isEmpty {
                        HStack(spacing: 4) {
                            ForEach(prop.extractedPalette.prefix(7), id: \.hex) { swatch in
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(Color(charkleHex: swatch.hex))
                                    .frame(height: 24)
                            }
                        }
                    }

                    if prop.primaryMatches.isEmpty {
                        VStack(spacing: 8) {
                            Image(systemName: "photo.on.rectangle.angled")
                                .font(.system(size: 28, weight: .light))
                                .foregroundStyle(.secondary)
                            Text("暂未匹配到足够素材，请先拖入素材或放宽筛选条件")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 48)
                    } else {
                        LazyVGrid(
                            columns: [
                                GridItem(.flexible(), spacing: 10),
                                GridItem(.flexible(), spacing: 10),
                                GridItem(.flexible(), spacing: 10)
                            ],
                            spacing: 10
                        ) {
                            ForEach(prop.primaryMatches.prefix(15)) { match in
                                ZStack(alignment: .bottomLeading) {
                                    AssetThumbnailSurface(
                                        asset: match.asset,
                                        loader: library.thumbnailLoader,
                                        tier: .grid520,
                                        cornerRadius: 10
                                    )
                                    .frame(height: 112)

                                    if let reason = match.matchReasons.first {
                                        Text(reason)
                                            .font(.system(size: 9.5, weight: .semibold))
                                            .foregroundStyle(.white)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(Color.black.opacity(0.54), in: Capsule(style: .continuous))
                                            .padding(6)
                                    }
                                }
                            }
                        }
                    }
                } else {
                    VStack(spacing: 10) {
                        ProgressView()
                        Text("正在生成情绪板策展初稿…")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 260)
                }
            }
            .padding(20)
        }
    }

    // MARK: - Seed Resolution

    private var defaultBoardTitle: String {
        switch activeEntry {
        case .prompt:
            let p = promptText.trimmingCharacters(in: .whitespacesAndNewlines)
            return p.isEmpty ? "灵感情绪板" : String(p.prefix(20))
        case .seedAssets:
            return "以图生板 · 视觉延伸"
        case .palette:
            return "色彩情绪板 \(selectedPaletteHexes.first ?? "")"
        case .selection:
            return "精选情绪板"
        }
    }

    private func currentSeed() -> MoodboardSeed {
        switch activeEntry {
        case .prompt:
            return .prompt(promptText.trimmingCharacters(in: .whitespacesAndNewlines))
        case .seedAssets:
            let ids = Array(selectedSeedIDs)
            return ids.isEmpty ? .prompt("") : .seedAssets(ids)
        case .palette:
            let labs = selectedPaletteHexes.map { LabColor.fromHex($0) }
            return .palette(labs, tolerance: colorTolerance)
        case .selection:
            let ids = Array(library.selectedAssetIDs)
            return ids.isEmpty ? .prompt("") : .manualSelection(ids)
        }
    }

    private func triggerPreviewGeneration() {
        Task { await runGenerationNow() }
    }

    private func runGenerationNow() async {
        await moodboards.generateProposal(seed: currentSeed(), primaryCount: 16, candidateCount: 28)
    }
}
