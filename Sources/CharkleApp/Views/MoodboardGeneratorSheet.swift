import CharkleCanvas
import CharkleCore
import SwiftUI

/// Composable AI Moodboard Curator Workbench powered by `MoodboardAgentHarness`.
/// Supports combining natural language brief + folder scope + seed images + optional color direction
/// + layout options, live Agent Harness step timeline, sectioned visual preview with per-card
/// lock/exclude controls, and multi-turn conversational refinement before opening the canvas.
public struct MoodboardGeneratorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public let coordinator: AppCoordinatorStore
    public let library: LibraryStore
    public let moodboards: MoodboardStore
    public let syncAndAI: SyncAndAIStore

    @State private var promptText: String = ""
    @State private var scopeFolderIDs: Set<UUID> = []
    @State private var selectedSeedIDs: Set<UUID> = []
    @State private var selectedPaletteHexes: [String] = []
    @State private var colorTolerance: Double = 26.0
    @State private var preferredCount: Int = 10
    @State private var layoutStyle: EditorialStyle = .magazine
    @State private var includeCuratorNotes: Bool = true
    @State private var autoFocusDetailCrop: Bool = false

    @State private var lockedAssetIDs: Set<UUID> = []
    @State private var excludedAssetIDs: Set<UUID> = []
    @State private var refinementInput: String = ""
    @State private var boardTitle: String = ""

    @State private var showSeedPicker: Bool = false
    @State private var showColorPicker: Bool = false
    @State private var showTraceExpanded: Bool = true
    @State private var hoveredAssetID: UUID?
    @State private var curationTask: Task<Void, Never>? = nil

    private static let presetPrompts: [String] = [
        "夏日清凉插画与通透蓝天阳光",
        "极简暖调陶艺、纸张肌理与自然光影",
        "瑞士网格排版与高级编辑部视觉",
        "现代暗色数据界面与克制科技感"
    ]

    private static let curatedSwatches: [String] = [
        "#253237", "#3D5A80", "#5C6B73", "#6B8E76",
        "#D4A373", "#C8B8A6", "#BA6B55", "#E5B243",
        "#1E2024", "#DCDAD4"
    ]

    public init(
        coordinator: AppCoordinatorStore,
        library: LibraryStore,
        moodboards: MoodboardStore,
        syncAndAI: SyncAndAIStore
    ) {
        self.coordinator = coordinator
        self.library = library
        self.moodboards = moodboards
        self.syncAndAI = syncAndAI
    }

    private var isTypeSafeReady: Bool {
        syncAndAI.typeSafeConfig.enabled && syncAndAI.hasStoredTypeSafeKey
    }

    private var isGenerativeProviderReady: Bool {
        let cfg = syncAndAI.aiConfig
        switch cfg.provider {
        case .disabled:
            return false
        case .chatGPTSubscription:
            return syncAndAI.chatGPTSession.status == .connected && syncAndAI.chatGPTSession.sharingEnabled
        case .gemini:
            return syncAndAI.hasStoredAIKey
        case .openAICompatible:
            let trimmedBase = cfg.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            let isLocalHost = trimmedBase.lowercased().contains("localhost") || trimmedBase.contains("127.0.0.1")
            return !trimmedBase.isEmpty && (syncAndAI.hasStoredAIKey || isLocalHost)
        }
    }

    private var isCloudAIReady: Bool {
        isGenerativeProviderReady || isTypeSafeReady
    }

    private var activeProviderBadge: String {
        let hasGenerative = isGenerativeProviderReady
        if !hasGenerative && isTypeSafeReady {
            return "TypeSafe Jev 视觉策展"
        }
        guard hasGenerative else { return "仅本机离线模式" }
        let suffix = isTypeSafeReady ? " + Jev 精排" : ""
        switch syncAndAI.aiConfig.provider {
        case .disabled: return isTypeSafeReady ? "TypeSafe Jev 视觉策展" : "仅本机离线模式"
        case .chatGPTSubscription: return "ChatGPT 订阅视觉策展\(suffix)"
        case .gemini: return "Gemini 视觉策展\(suffix)"
        case .openAICompatible:
            let base = syncAndAI.aiConfig.baseURL.lowercased()
            if base.contains("localhost") || base.contains("127.0.0.1") {
                return "本地 Ollama 视觉策展\(suffix)"
            }
            return "云端模型视觉策展\(suffix)"
        }
    }

    public var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()

            HStack(spacing: 0) {
                leftBriefStudio
                    .frame(width: 348)

                Divider()

                rightAgentWorkbench
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            Divider()
            footerBar
        }
        .frame(width: 960, height: 660)
        .background(CharkleTheme.galleryGround(for: colorScheme))
        .onAppear {
            switch coordinator.generatorInitialEntry {
            case .selection:
                if !library.selectedAssetIDs.isEmpty {
                    let picked = Array(library.selectedAssetIDs.prefix(16))
                    selectedSeedIDs = Set(picked)
                    if picked.count > 10 {
                        preferredCount = 16
                    }
                    showSeedPicker = true
                }
            case .seedAssets:
                if !library.selectedAssetIDs.isEmpty {
                    selectedSeedIDs = Set(library.selectedAssetIDs.prefix(4))
                }
                showSeedPicker = true
            case .palette:
                showColorPicker = true
                if selectedPaletteHexes.isEmpty, let primary = library.primarySelectedAsset {
                    selectedPaletteHexes = Array(primary.dominantColors.prefix(3).map { $0.hex.uppercased() })
                }
            case .prompt:
                if !library.selectedAssetIDs.isEmpty {
                    selectedSeedIDs = Set(library.selectedAssetIDs.prefix(4))
                    showSeedPicker = true
                }
            }
            if case .folder(let folderID) = coordinator.selectedDestination {
                scopeFolderIDs = [folderID]
            }
            if let existingProp = moodboards.proposal, boardTitle.isEmpty {
                boardTitle = existingProp.draftDocument.title
            }
        }
        .onDisappear {
            curationTask?.cancel()
            curationTask = nil
        }
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack(spacing: 12) {
            HStack(spacing: 9) {
                CharkleIcon("sparkle-board", style: .layered, size: 26)
                VStack(alignment: .leading, spacing: 1.5) {
                    Text("AI 情绪板策展工作台")
                        .font(CharkleTheme.text(.headline, weight: .semibold))
                    Text("组合灵感词、目录与种子图，由 Agent 视觉审片、宁缺毋滥挑选并编排分区")
                        .font(CharkleTheme.text(.caption))
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            HStack(spacing: 6) {
                Circle()
                    .fill(isCloudAIReady ? Color.green : Color.orange)
                    .frame(width: 7, height: 7)
                Text(activeProviderBadge)
                    .font(CharkleTheme.text(.caption, weight: .medium))
                    .foregroundStyle(.secondary)
                if !isCloudAIReady {
                    Button("去开启") {
                        dismiss()
                        coordinator.openSettings(tab: .ai)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                    .fixedSize()
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Color.primary.opacity(0.05), in: Capsule(style: .continuous))
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    // MARK: - Left Composable Brief Studio

    private var leftBriefStudio: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 16) {
                // 1. Prompt Brief
                VStack(alignment: .leading, spacing: 8) {
                    Text("灵感方向与要求")
                        .font(CharkleTheme.text(.body, weight: .semibold))

                    TextField("描述想要的氛围、题材、光影或排除项（如：只要清凉插画，不要暗色界面）…", text: $promptText, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .font(CharkleTheme.text(.caption))
                        .lineLimit(3...5)

                    CharkleFlowLayout(spacing: 6, lineSpacing: 6) {
                        ForEach(Self.presetPrompts, id: \.self) { sample in
                            Button {
                                promptText = sample
                            } label: {
                                Text(sample)
                                    .font(CharkleTheme.text(.caption))
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 9)
                                    .padding(.vertical, 4)
                                    .background(CharkleTheme.surfaceElevated(for: colorScheme), in: Capsule(style: .continuous))
                                    .overlay(
                                        Capsule(style: .continuous)
                                            .strokeBorder(CharkleTheme.hairline(for: colorScheme), lineWidth: CharkleTheme.hairlineWidth)
                                    )
                            }
                            .buttonStyle(CharkleTactileButtonStyle())
                        }
                    }
                }

                Divider()

                // 2. Folder Scope (Multi-Select Composable)
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("限定文件夹范围")
                            .font(CharkleTheme.text(.caption, weight: .semibold))
                        Spacer()
                        Text(scopeFolderIDs.isEmpty ? "全库检索" : "已选 \(scopeFolderIDs.count) 个目录")
                            .font(CharkleTheme.text(.caption))
                            .foregroundStyle(.secondary)
                    }

                    CharkleHierarchicalFolderScopeTree(
                        folders: library.folders,
                        selectedFolderIDs: $scopeFolderIDs
                    )
                }

                Divider()

                // 3. Optional Seed Images
                CharkleDisclosureGroup(isExpanded: $showSeedPicker) {
                    let candidates = library.cachedRecentActivityAssets.prefix(18)
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("点选定调种子图（必入主画布）")
                                .font(CharkleTheme.text(.caption))
                                .foregroundStyle(.secondary)
                            Spacer()
                            if !selectedSeedIDs.isEmpty {
                                Button("清空") { selectedSeedIDs.removeAll() }
                                    .font(CharkleTheme.text(.caption))
                                    .buttonStyle(.plain)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        LazyVGrid(
                            columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)],
                            spacing: 6
                        ) {
                            ForEach(candidates) { asset in
                                let isPicked = selectedSeedIDs.contains(asset.id)
                                Button {
                                    if isPicked {
                                        selectedSeedIDs.remove(asset.id)
                                    } else {
                                        let cap = max(4, preferredCount)
                                        if selectedSeedIDs.count >= cap, let first = selectedSeedIDs.first {
                                            selectedSeedIDs.remove(first)
                                        }
                                        selectedSeedIDs.insert(asset.id)
                                    }
                                } label: {
                                    ZStack(alignment: .topTrailing) {
                                        AssetThumbnailSurface(
                                            asset: asset,
                                            loader: library.thumbnailLoader,
                                            tier: .grid520,
                                            cornerRadius: CharkleTheme.Radius.chip
                                        )
                                        .frame(height: 64)
                                        .overlay(
                                            RoundedRectangle(cornerRadius: CharkleTheme.Radius.chip, style: .continuous)
                                                .strokeBorder(isPicked ? Color.accentColor : Color.clear, lineWidth: 2)
                                        )
                                        if isPicked {
                                            Image(systemName: "checkmark.circle.fill")
                                                .font(.system(size: 13))
                                                .foregroundStyle(Color.accentColor)
                                                .background(Circle().fill(Color.white).padding(1))
                                                .padding(4)
                                                .transition(CharkleMotion.originTransition(anchor: .topTrailing, scale: 0.92, reduced: reduceMotion))
                                        }
                                    }
                                    .animation(CharkleMotion.accessible(CharkleMotion.microOvershoot, reduced: reduceMotion), value: isPicked)
                                }
                                .buttonStyle(CharkleTactileButtonStyle())
                            }
                        }
                    }
                    .padding(.top, 6)
                } label: {
                    HStack {
                        Text("定调种子图")
                            .font(CharkleTheme.text(.caption, weight: .semibold))
                        Spacer()
                        Text(selectedSeedIDs.isEmpty ? "可选" : "已选 \(selectedSeedIDs.count) 张")
                            .font(CharkleTheme.text(.caption))
                            .foregroundStyle(selectedSeedIDs.isEmpty ? Color.secondary : Color.accentColor)
                    }
                }

                Divider()

                // 4. Optional Color Direction
                CharkleDisclosureGroup(isExpanded: $showColorPicker) {
                    VStack(alignment: .leading, spacing: 10) {
                        CharkleFlowLayout(spacing: 7, lineSpacing: 7) {
                            ForEach(Self.curatedSwatches, id: \.self) { hex in
                                let active = selectedPaletteHexes.contains(hex)
                                Button {
                                    if active {
                                        selectedPaletteHexes.removeAll { $0 == hex }
                                    } else {
                                        if selectedPaletteHexes.count >= 3 { selectedPaletteHexes.removeFirst() }
                                        selectedPaletteHexes.append(hex)
                                    }
                                } label: {
                                    RoundedRectangle(cornerRadius: CharkleTheme.Radius.sm, style: .continuous)
                                        .fill(Color(charkleHex: hex))
                                        .frame(width: 28, height: 28)
                                        .overlay(
                                            RoundedRectangle(cornerRadius: CharkleTheme.Radius.sm, style: .continuous)
                                                .strokeBorder(
                                                    active ? Color.accentColor : Color.primary.opacity(0.14),
                                                    lineWidth: active ? 2 : CharkleTheme.hairlineWidth
                                                )
                                        )
                                }
                                .buttonStyle(CharkleTactileButtonStyle())
                                .help(hex)
                            }
                        }

                        if !selectedPaletteHexes.isEmpty {
                            HStack(spacing: 8) {
                                Text("精确")
                                    .font(CharkleTheme.text(.caption))
                                    .foregroundStyle(.secondary)
                                Slider(value: $colorTolerance, in: 12...46, step: 2)
                                Text("宽松")
                                    .font(CharkleTheme.text(.caption))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(.top, 6)
                } label: {
                    HStack {
                        Text("色彩倾向")
                            .font(CharkleTheme.text(.caption, weight: .semibold))
                        Spacer()
                        if selectedPaletteHexes.isEmpty {
                            Text("可选")
                                .font(CharkleTheme.text(.caption))
                                .foregroundStyle(.secondary)
                        } else {
                            HStack(spacing: 3) {
                                ForEach(selectedPaletteHexes, id: \.self) { hex in
                                    Circle()
                                        .fill(Color(charkleHex: hex))
                                        .frame(width: 11, height: 11)
                                }
                            }
                        }
                    }
                }

                Divider()

                // 5. Composition & Layout Controls
                VStack(alignment: .leading, spacing: 10) {
                    Text("版面与构成")
                        .font(CharkleTheme.text(.caption, weight: .semibold))

                    HStack {
                        Text("初始构图节奏")
                            .font(CharkleTheme.text(.caption))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Picker("", selection: $layoutStyle) {
                            ForEach(EditorialStyle.allCases, id: \.self) { style in
                                Text(style.localizedLabel).tag(style)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(width: 204)
                    }

                    HStack {
                        Text("数量上限")
                            .font(CharkleTheme.text(.caption))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Picker("", selection: $preferredCount) {
                            Text("6 张").tag(6)
                            Text("10 张").tag(10)
                            Text("16 张").tag(16)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(width: 204)
                        .help("宁缺毋滥：实际张数不超过上限，不会强行凑数")
                    }

                    Toggle(isOn: $includeCuratorNotes) {
                        Text("附带视觉策展便签与分区标题")
                            .font(CharkleTheme.text(.caption))
                    }
                    .toggleStyle(.checkbox)

                    Toggle(isOn: $autoFocusDetailCrop) {
                        HStack(spacing: 4) {
                            Text("细节特写模式（按灵感词自动局部裁切）")
                                .font(CharkleTheme.text(.caption))
                        }
                    }
                    .toggleStyle(.checkbox)
                    .disabled(!isTypeSafeReady)
                    .help(isTypeSafeReady ? "入选主图会自动按灵感词定位局部细节并写入非破坏性裁切框" : "需在「设置 → 智能与搜索」中开启视觉定位增强")
                }

                // 6. Primary Curation Trigger
                Button {
                    excludedAssetIDs.removeAll()
                    lockedAssetIDs = selectedSeedIDs
                    startCuration(refinement: nil)
                } label: {
                    HStack(spacing: 7) {
                        if moodboards.isGeneratingProposal {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: isCloudAIReady ? "sparkles" : "wand.and.stars")
                                .font(.system(size: 12.5, weight: .semibold))
                        }
                        Text(
                            moodboards.isGeneratingProposal
                                ? "Agent 正在审片策展…"
                                : (isCloudAIReady ? "开始 AI 视觉策展" : "生成离线策展初稿")
                        )
                        .font(CharkleTheme.text(.body, weight: .semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 9)
                }
                .buttonStyle(.borderedProminent)
                .disabled(moodboards.isGeneratingProposal)
            }
            .padding(18)
            .charkleCleanScrollbars(hidden: false)
        }
    }

    // MARK: - Right Agent Harness Workbench & Live Sectioned Preview

    private var rightAgentWorkbench: some View {
        let hasProposal = moodboards.proposal != nil
        let showTimeline = !moodboards.agentTrace.isEmpty || moodboards.isGeneratingProposal

        return VStack(spacing: 0) {
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 14) {
                    // Live / Completed Agent Harness Timeline
                    if showTimeline {
                        agentTimelineCard
                            .transition(CharkleMotion.originTransition(anchor: .top, scale: 0.97, reduced: reduceMotion))
                    }

                    if let err = moodboards.lastError {
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                            Text(err)
                                .font(CharkleTheme.text(.caption))
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer()
                        }
                        .padding(10)
                        .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: CharkleTheme.Radius.popoverInner, style: .continuous))
                        .transition(CharkleMotion.originTransition(anchor: .top, scale: 0.97, reduced: reduceMotion))
                    }

                    if let prop = moodboards.proposal {
                        VStack(alignment: .leading, spacing: 14) {
                            curatedProposalView(prop)
                        }
                        .transition(CharkleMotion.revealTransition(offsetY: 8, reduced: reduceMotion))
                    } else if !moodboards.isGeneratingProposal {
                        emptyWorkbenchPlaceholder
                            .transition(.opacity)
                    }
                }
                .padding(18)
                .charkleCleanScrollbars(hidden: false)
                .animation(CharkleMotion.enterExit(showTimeline, reduced: reduceMotion), value: showTimeline)
                .animation(CharkleMotion.accessible(CharkleMotion.enterSm, reduced: reduceMotion), value: moodboards.lastError)
                .animation(CharkleMotion.accessible(CharkleMotion.enterMd, reduced: reduceMotion), value: moodboards.proposal?.draftDocument.updatedAt)
            }

            // Multi-Turn Refinement Steering Bar (visible once a draft exists)
            if hasProposal {
                VStack(spacing: 0) {
                    Divider()
                    HStack(spacing: 8) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 12))
                            .foregroundStyle(Color.accentColor)
                        TextField("继续微调初稿… 如：去掉暗色界面、换更通透的色调、按光影与角色分组", text: $refinementInput)
                            .textFieldStyle(.plain)
                            .font(CharkleTheme.text(.caption))
                            .onSubmit { triggerRefinement() }
                        Button("继续调整") {
                            triggerRefinement()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .fixedSize()
                        .disabled(moodboards.isGeneratingProposal || refinementInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(CharkleTheme.surfaceElevated(for: colorScheme))
                }
                .transition(CharkleMotion.originTransition(anchor: .bottom, scale: 0.97, reduced: reduceMotion))
            }
        }
        .animation(CharkleMotion.enterExit(hasProposal, reduced: reduceMotion), value: hasProposal)
    }

    private var agentTimelineCard: some View {
        CharkleDisclosureGroup(
            isExpanded: $showTraceExpanded,
            headerVerticalPadding: 4,
            headerHorizontalPadding: 6,
            negativeHorizontalBleed: 6
        ) {
            VStack(alignment: .leading, spacing: 7) {
                ForEach(moodboards.agentTrace) { step in
                    HStack(alignment: .top, spacing: 8) {
                        ZStack {
                            switch step.status {
                            case .running:
                                ProgressView()
                                    .controlSize(.mini)
                                    .transition(.opacity)
                            case .done:
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                                    .transition(CharkleMotion.originTransition(anchor: .center, scale: 0.92, reduced: reduceMotion))
                            case .warning:
                                Image(systemName: "exclamationmark.circle.fill")
                                    .foregroundStyle(.orange)
                                    .transition(CharkleMotion.originTransition(anchor: .center, scale: 0.92, reduced: reduceMotion))
                            }
                        }
                        .font(.system(size: 12))
                        .frame(width: 15, height: 15)
                        .padding(.top, 1)
                        .animation(CharkleMotion.accessible(CharkleMotion.microOvershoot, reduced: reduceMotion), value: step.status)

                        VStack(alignment: .leading, spacing: 1.5) {
                            Text(step.title)
                                .font(CharkleTheme.text(.caption, weight: .semibold))
                            if !step.detail.isEmpty {
                                Text(step.detail)
                                    .font(CharkleTheme.text(.caption))
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .transition(CharkleMotion.revealTransition(offsetY: 6, reduced: reduceMotion))
                }
            }
            .padding(.top, 6)
            .animation(CharkleMotion.accessible(CharkleMotion.enterSm, reduced: reduceMotion), value: moodboards.agentTrace)
        } label: {
            HStack(spacing: 6) {
                if moodboards.isGeneratingProposal {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: "cpu")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                }
                Text(moodboards.isGeneratingProposal ? "Agent 策展执行中…" : "策展执行轨迹（\(moodboards.agentTrace.count) 步）")
                    .font(CharkleTheme.text(.caption, weight: .semibold))
                Spacer()
            }
        }
        .padding(12)
        .background(CharkleTheme.surfaceElevated(for: colorScheme), in: RoundedRectangle(cornerRadius: CharkleTheme.Radius.cardOuter, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: CharkleTheme.Radius.cardOuter, style: .continuous)
                .strokeBorder(CharkleTheme.hairline(for: colorScheme), lineWidth: CharkleTheme.hairlineWidth)
        )
    }

    @ViewBuilder
    private func curatedProposalView(_ prop: MoodboardProposal) -> some View {
        let scoredByID = Dictionary(
            prop.primaryMatches.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        // Curator Art-Direction Summary + Palette + Rejections
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(prop.draftDocument.title)
                    .font(CharkleTheme.text(.headline, weight: .semibold))
                Spacer()
                Text("入选 \(prop.primaryMatches.count) 张 · 候选池 +\(prop.candidatePool.count)")
                    .font(CharkleTheme.text(.caption, weight: .medium))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            if !prop.curatedSummary.isEmpty {
                Text(prop.curatedSummary)
                    .font(CharkleTheme.text(.caption))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !prop.extractedPalette.isEmpty {
                HStack(spacing: 4) {
                    ForEach(prop.extractedPalette.prefix(6), id: \.hex) { swatch in
                        RoundedRectangle(cornerRadius: CharkleTheme.Radius.cardInnerBadge, style: .continuous)
                            .fill(Color(charkleHex: swatch.hex))
                            .frame(height: 22)
                            .overlay(
                                RoundedRectangle(cornerRadius: CharkleTheme.Radius.cardInnerBadge, style: .continuous)
                                    .strokeBorder(Color.primary.opacity(0.10), lineWidth: CharkleTheme.hairlineWidth)
                            )
                            .help(swatch.hex)
                    }
                }
            }

            if let rejected = prop.rejectedSummary, !rejected.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Text(rejected)
                        .font(CharkleTheme.text(.caption))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(14)
        .background(CharkleTheme.surfaceElevated(for: colorScheme), in: RoundedRectangle(cornerRadius: CharkleTheme.Radius.cardOuter, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: CharkleTheme.Radius.cardOuter, style: .continuous)
                .strokeBorder(CharkleTheme.hairline(for: colorScheme), lineWidth: CharkleTheme.hairlineWidth)
        )

        if prop.primaryMatches.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "sparkles.rectangle.stack")
                    .font(.system(size: 28, weight: .light))
                    .foregroundStyle(.secondary)
                Text("没有硬塞不符主题的素材")
                    .font(CharkleTheme.text(.body, weight: .semibold))
                Text("当前限定范围内暂无与描述相符的画面，可以放宽文件夹范围、修改描述，或先在设置开启云端增强智能让 AI 看图筛选。")
                    .font(CharkleTheme.text(.caption))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 36)
        } else {
            let displaySections: [MoodboardSectionDraft] = prop.sections.isEmpty
                ? [MoodboardSectionDraft(title: "精选画面", assetIDs: prop.primaryMatches.map(\.id))]
                : prop.sections

            ForEach(displaySections) { section in
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(sectionTintColor(section.tint))
                            .frame(width: 8, height: 8)
                        Text(section.title)
                            .font(CharkleTheme.text(.body, weight: .semibold))
                        if !section.rationale.isEmpty {
                            Text("· \(section.rationale)")
                                .font(CharkleTheme.text(.caption))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                        Text("\(section.assetIDs.count) 张")
                            .font(CharkleTheme.text(.caption))
                            .foregroundStyle(.tertiary)
                    }

                    let heroSet = Set(section.heroAssetIDs)
                    LazyVGrid(
                        columns: [
                            GridItem(.flexible(), spacing: 10),
                            GridItem(.flexible(), spacing: 10),
                            GridItem(.flexible(), spacing: 10)
                        ],
                        spacing: 10
                    ) {
                        ForEach(section.assetIDs, id: \.self) { assetID in
                            if let scored = scoredByID[assetID] {
                                curatedPreviewTile(scored: scored, isHero: heroSet.contains(assetID))
                            }
                        }
                    }
                }
            }
        }
    }

    private func curatedPreviewTile(scored: ScoredAsset, isHero: Bool) -> some View {
        let isLocked = lockedAssetIDs.contains(scored.id)
        let isHovered = hoveredAssetID == scored.id

        return ZStack {
            AssetThumbnailSurface(
                asset: scored.asset,
                loader: library.thumbnailLoader,
                tier: .grid520,
                cornerRadius: CharkleTheme.Radius.popoverInner
            )
            .frame(height: 118)
            .clipShape(RoundedRectangle(cornerRadius: CharkleTheme.Radius.popoverInner, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: CharkleTheme.Radius.popoverInner, style: .continuous)
                    .strokeBorder(
                        isLocked ? Color.accentColor : CharkleTheme.hairline(for: colorScheme),
                        lineWidth: isLocked ? 2 : CharkleTheme.hairlineWidth
                    )
            )

            // Top-left Hero badge
            VStack {
                HStack {
                    if isHero {
                        Text("主视觉")
                            .font(CharkleTheme.text(.caption, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.accentColor.opacity(0.92), in: Capsule(style: .continuous))
                    }
                    Spacer()

                    // Lock / Exclude controls on hover (or when locked)
                    if isHovered || isLocked {
                        HStack(spacing: 4) {
                            Button {
                                withAnimation(CharkleMotion.accessible(CharkleMotion.microOvershoot, reduced: reduceMotion)) {
                                    if isLocked { lockedAssetIDs.remove(scored.id) }
                                    else { lockedAssetIDs.insert(scored.id) }
                                }
                            } label: {
                                Image(systemName: isLocked ? "lock.fill" : "lock.open")
                                    .font(.system(size: 9.5, weight: .semibold))
                                    .foregroundStyle(.white)
                                    .frame(width: 22, height: 22)
                                    .background(isLocked ? Color.accentColor : Color.black.opacity(0.62), in: Circle())
                            }
                            .buttonStyle(CharkleTactileButtonStyle())
                            .help(isLocked ? "取消锁定" : "锁定保留（微调时不被换掉）")

                            Button {
                                lockedAssetIDs.remove(scored.id)
                                selectedSeedIDs.remove(scored.id)
                                excludedAssetIDs.insert(scored.id)
                                startCuration(refinement: "已剔除刚才排除的素材，请保持整体和谐并按需补位")
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: 9.5, weight: .bold))
                                    .foregroundStyle(.white)
                                    .frame(width: 22, height: 22)
                                    .background(Color.black.opacity(0.62), in: Circle())
                            }
                            .buttonStyle(CharkleTactileButtonStyle())
                            .help("排除此素材并重新调整")
                        }
                        .transition(.opacity)
                    }
                }
                .padding(6)

                Spacer()

                if let reason = scored.matchReasons.first, !reason.isEmpty {
                    HStack {
                        Text(reason)
                            .font(CharkleTheme.text(.caption, weight: .medium))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.black.opacity(0.60), in: Capsule(style: .continuous))
                        Spacer()
                    }
                    .padding(6)
                }
            }
        }
        .onHover { hovering in
            withAnimation(CharkleMotion.accessible(CharkleMotion.hoverPress, reduced: reduceMotion)) {
                hoveredAssetID = hovering ? scored.id : (hoveredAssetID == scored.id ? nil : hoveredAssetID)
            }
        }
    }

    private var emptyWorkbenchPlaceholder: some View {
        VStack(spacing: 12) {
            Image(systemName: "sparkles.rectangle.stack")
                .font(.system(size: 36, weight: .ultraLight))
                .foregroundStyle(.secondary)
            Text("输入灵感方向，点击左侧「\(isCloudAIReady ? "开始 AI 视觉策展" : "生成离线策展初稿")」")
                .font(CharkleTheme.text(.body, weight: .semibold))
            Text("系统会把候选素材拼成编号视觉联系表直接看图筛选，只挑选真正契合氛围的作品，自动划分逻辑分区、标注主视觉并提炼全板色卡；初稿生成后还可继续对话微调。")
                .font(CharkleTheme.text(.caption))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 96)
    }

    // MARK: - Footer

    private var footerBar: some View {
        HStack(spacing: 12) {
            TextField("情绪板名称…", text: $boardTitle)
                .textFieldStyle(.roundedBorder)
                .frame(width: 260)

            if let prop = moodboards.proposal {
                HStack(spacing: 5) {
                    Image(systemName: prop.usedCloudAI ? "sparkles" : "desktopcomputer")
                        .font(.system(size: 10.5))
                    Text(prop.usedCloudAI ? "已启用云端增强智能" : "本机离线策展")
                        .font(CharkleTheme.text(.caption, weight: .medium))
                    if prop.cachedVisualInsightsCount > 0 {
                        Text("· 沉淀 \(prop.cachedVisualInsightsCount) 条视觉理解")
                            .font(CharkleTheme.text(.caption))
                            .foregroundStyle(.tertiary)
                    }
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(Color.primary.opacity(0.05), in: Capsule(style: .continuous))
            }

            Spacer()

            Button("取消") {
                curationTask?.cancel()
                curationTask = nil
                moodboards.proposal = nil
                moodboards.agentTrace = []
                dismiss()
            }
            .keyboardShortcut(.cancelAction)

            Button("创建并打开情绪板") {
                curationTask?.cancel()
                curationTask = Task {
                    if moodboards.proposal == nil {
                        await runCuration(refinement: nil)
                    }
                    guard !Task.isCancelled else { return }
                    let finalTitle = boardTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        ? (moodboards.proposal?.draftDocument.title ?? "新情绪板")
                        : boardTitle
                    let subtitle = moodboards.proposal?.draftDocument.subtitle.isEmpty == false
                        ? (moodboards.proposal?.draftDocument.subtitle ?? promptText)
                        : promptText
                    if let created = await moodboards.confirmProposal(title: finalTitle, subtitle: subtitle) {
                        guard !Task.isCancelled else { return }
                        coordinator.openMoodboard(created.id)
                        coordinator.showToast("已创建情绪板「\(created.title)」", icon: "sparkles.rectangle.stack")
                        dismiss()
                    }
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(moodboards.isGeneratingProposal || (moodboards.proposal != nil && moodboards.proposal?.primaryMatches.isEmpty == true))
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 13)
    }

    // MARK: - Actions

    private func startCuration(refinement: String?) {
        curationTask?.cancel()
        curationTask = Task {
            await runCuration(refinement: refinement)
        }
    }

    private func triggerRefinement() {
        let instruction = refinementInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !instruction.isEmpty, !moodboards.isGeneratingProposal else { return }
        refinementInput = ""
        startCuration(refinement: instruction)
    }

    private func runCuration(refinement: String?) async {
        showTraceExpanded = true
        let req = MoodboardCurationRequest(
            prompt: promptText.trimmingCharacters(in: .whitespacesAndNewlines),
            seedAssetIDs: Array(selectedSeedIDs),
            scopeFolderIDs: Array(scopeFolderIDs),
            targetPalette: selectedPaletteHexes.map { LabColor.fromHex($0) },
            colorTolerance: colorTolerance,
            preferredCount: preferredCount,
            candidateCount: 24,
            layoutStyle: layoutStyle,
            useFreeformLayout: true,
            includeCuratorNotes: includeCuratorNotes,
            excludedAssetIDs: Array(excludedAssetIDs),
            lockedAssetIDs: Array(lockedAssetIDs),
            existingBoard: refinement != nil ? moodboards.proposal?.draftDocument : nil,
            refinementInstruction: refinement,
            autoFocusDetailCrop: autoFocusDetailCrop && isTypeSafeReady
        )
        await moodboards.curateProposal(req)
        guard !Task.isCancelled else { return }
        if let prop = moodboards.proposal {
            if boardTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || refinement == nil {
                boardTitle = prop.draftDocument.title
            }
            if prop.cachedVisualInsightsCount > 0 {
                await library.refreshAssets()
            }
        }
    }

    private func sectionTintColor(_ tint: GroupTint) -> Color {
        switch tint {
        case .neutral: .secondary
        case .sand: Color(charkleHex: "#D4A373")
        case .sage: Color(charkleHex: "#6B8E76")
        case .slate: Color(charkleHex: "#5C6B73")
        case .terracotta: Color(charkleHex: "#BA6B55")
        case .ocean: Color(charkleHex: "#3D5A80")
        }
    }
}
