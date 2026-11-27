import AppKit
import CharkleCanvas
import CharkleCore
import SwiftUI
import os

/// Centered native macOS Smart Deduplication workspace (100% local classical algorithms, zero AI).
/// Supports all 8 Charkle media kinds, side-by-side quality comparison, manual keeper override,
/// metadata/Moodboard reference merging, and reversible Trash or permanent deletion.
public struct SmartDeduplicationView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.charkleAccentSource) private var accentSource
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public let coordinator: AppCoordinatorStore
    public let library: LibraryStore
    public let moodboards: MoodboardStore
    public let initialFolderID: UUID?
    public let onOpenQuickLook: (AssetRecord) -> Void
    public let onClose: () -> Void

    private enum ScopeOption: Hashable {
        case allActive
        case inbox
        case folder(UUID)
    }

    private enum MediaKindFilter: String, CaseIterable, Identifiable {
        case all
        case images
        case videos
        case audio
        case designFiles
        case bookmarks
        case docsAnd3D

        var id: String { rawValue }

        var label: String {
            switch self {
            case .all: "全部媒体"
            case .images: "图片与动图"
            case .videos: "视频"
            case .audio: "音频"
            case .designFiles: "设计文件"
            case .bookmarks: "网页与社媒"
            case .docsAnd3D: "文档与 3D"
            }
        }

        var kinds: Set<MediaKind>? {
            switch self {
            case .all: nil
            case .images: [.image, .animatedImage]
            case .videos: [.video]
            case .audio: [.audio]
            case .designFiles: [.designFile]
            case .bookmarks: [.webBookmark]
            case .docsAnd3D: [.document, .model3D]
            }
        }
    }

    @State private var cardAppeared: Bool = false
    @State private var selectedScope: ScopeOption = .allActive
    @State private var selectedKindFilter: MediaKindFilter = .all
    @State private var sensitivity: DeduplicationSensitivity = .balanced
    @State private var disposalMode: DuplicateDisposalMode = .moveToTrash
    @State private var mergeMetadata: Bool = true

    @State private var isScanning: Bool = false
    @State private var scanProgress: DeduplicationScanProgress = DeduplicationScanProgress(completed: 0, total: 1, phase: "准备扫描…")
    @State private var report: DeduplicationScanReport? = nil
    @State private var selectedGroupID: UUID? = nil
    @State private var enabledGroupIDs: Set<UUID> = []
    @State private var keeperOverrides: [UUID: UUID] = [:]

    @State private var isCleaning: Bool = false
    @State private var pendingPermanentCleanupPlans: [DeduplicationResolutionPlan]? = nil
    @State private var scanTask: Task<Void, Never>? = nil
    @State private var cleanupTask: Task<Void, Never>? = nil

    public init(
        coordinator: AppCoordinatorStore,
        library: LibraryStore,
        moodboards: MoodboardStore,
        initialFolderID: UUID? = nil,
        onOpenQuickLook: @escaping (AssetRecord) -> Void,
        onClose: @escaping () -> Void
    ) {
        self.coordinator = coordinator
        self.library = library
        self.moodboards = moodboards
        self.initialFolderID = initialFolderID
        self.onOpenQuickLook = onOpenQuickLook
        self.onClose = onClose
    }

    private var activeAccent: Color {
        CharkleTheme.accent(for: colorScheme, source: accentSource)
    }

    private var groups: [DuplicateGroup] {
        report?.groups ?? []
    }

    private var activeGroup: DuplicateGroup? {
        if let id = selectedGroupID, let found = groups.first(where: { $0.id == id }) {
            return found
        }
        return groups.first
    }

    private func effectiveKeeperID(for group: DuplicateGroup) -> UUID {
        if let override = keeperOverrides[group.id],
           group.candidates.contains(where: { $0.asset.id == override }) {
            return override
        }
        return group.recommendedKeepAssetID
    }

    private func reclaimableBytes(for group: DuplicateGroup) -> Int64 {
        let keepID = effectiveKeeperID(for: group)
        return group.candidates
            .filter { $0.asset.id != keepID }
            .reduce(Int64(0)) { $0 + max(Int64(0), $1.asset.fileSizeBytes) }
    }

    private var selectedGroups: [DuplicateGroup] {
        groups.filter { enabledGroupIDs.contains($0.id) }
    }

    private var selectedRemovableCount: Int {
        selectedGroups.reduce(0) { $0 + max(0, $1.candidates.count - 1) }
    }

    private var selectedReclaimableBytes: Int64 {
        selectedGroups.reduce(Int64(0)) { $0 + reclaimableBytes(for: $1) }
    }

    public var body: some View {
        ZStack {
            CharkleModalBackdrop(onTap: onClose)

            GeometryReader { geo in
                let maxAvailableWidth = max(360, geo.size.width - 24)
                let maxAvailableHeight = max(320, geo.size.height - 24)
                let modalWidth = min(max(640, geo.size.width - 72), min(1040, maxAvailableWidth))
                let modalHeight = min(max(460, geo.size.height - 64), min(740, maxAvailableHeight))
                let cardShape = RoundedRectangle(cornerRadius: CharkleTheme.Radius.settingsOuter, style: .continuous)

                VStack(spacing: 0) {
                    headerBar
                    CharkleHairlineDivider()
                    controlBar
                    CharkleHairlineDivider()

                    if isScanning {
                        scanningBody
                    } else if let report, report.groups.isEmpty {
                        emptyCleanBody(report)
                    } else if !groups.isEmpty {
                        comparisonSplitBody
                        CharkleHairlineDivider()
                        footerActionBar
                    } else {
                        scanningBody
                    }
                }
                .frame(width: modalWidth, height: modalHeight)
                .clipShape(cardShape)
                .background {
                    cardShape
                        .fill(SettingsPalette.contentBackground(for: colorScheme))
                        .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.48 : 0.16), radius: 36, y: 16)
                        .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.24 : 0.05), radius: 8, y: 3)
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
            if let folderID = initialFolderID {
                selectedScope = .folder(folderID)
            } else if case .folder(let currentID) = coordinator.selectedDestination {
                selectedScope = .folder(currentID)
            } else if coordinator.selectedDestination == .inbox {
                selectedScope = .inbox
            } else {
                selectedScope = .allActive
            }
            cardAppeared = true
            startScan()
        }
        .onDisappear {
            scanTask?.cancel()
            scanTask = nil
            cleanupTask?.cancel()
            cleanupTask = nil
        }
        .onKeyPress(.escape) {
            guard coordinator.quickLookAssetID == nil else { return .ignored }
            onClose()
            return .handled
        }
        .alert(
            "确认彻底删除 \(pendingPermanentCleanupPlans?.reduce(0) { $0 + $1.removeAssetIDs.count } ?? 0) 项重复素材？",
            isPresented: Binding(
                get: { pendingPermanentCleanupPlans != nil },
                set: { if !$0 { pendingPermanentCleanupPlans = nil } }
            )
        ) {
            Button("取消", role: .cancel) {
                pendingPermanentCleanupPlans = nil
            }
            Button("彻底删除并保留最高质量版本", role: .destructive) {
                if let plans = pendingPermanentCleanupPlans {
                    pendingPermanentCleanupPlans = nil
                    executeCleanup(plans: plans, disposal: .permanentlyDelete)
                }
            }
        } message: {
            Text("彻底删除不可撤销；若已勾选合并选项，重复项中的标签、评分、备注与情绪板引用将在删除前无损合并到保留的高质量版本。")
        }
    }

    // MARK: - Header & Controls

    private var headerBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "square.on.square.dashed")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(activeAccent)

            Text("智能去重")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.primary)

            Text("全媒体纯本地算法 · 无需 AI")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(activeAccent)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(activeAccent.opacity(colorScheme == .dark ? 0.18 : 0.10), in: Capsule(style: .continuous))

            Spacer()

            if let report, !isScanning {
                Text(
                    String(
                        format: "已扫描 %d 项 · %.2fs",
                        report.scannedAssetCount,
                        max(0.01, report.durationSeconds)
                    )
                )
                .font(.system(size: 11.5))
                .monospacedDigit()
                .foregroundStyle(.secondary)
            }

            Button {
                onClose()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11.5, weight: .semibold))
            }
            .buttonStyle(.charkle(.subtle, size: .icon, iconDimension: 28))
            .help("关闭 (Esc)")
        }
        .padding(.horizontal, 20)
        .frame(height: 52)
    }

    private var controlBar: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                // Scope Picker
                Menu {
                    Button("全部素材") {
                        selectedScope = .allActive
                        startScan()
                    }
                    Button("仅收件箱") {
                        selectedScope = .inbox
                        startScan()
                    }
                    if !library.flattenedFolderHierarchy.isEmpty {
                        Divider()
                        ForEach(library.flattenedFolderHierarchy) { node in
                            let indent = String(repeating: "　", count: min(node.depth, 5))
                            Button("\(indent)\(node.folder.name)") {
                                selectedScope = .folder(node.folder.id)
                                startScan()
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "folder")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                        Text(scopeLabel)
                            .font(.system(size: 12, weight: .medium))
                            .lineLimit(1)
                        CharkleDropdownChevron(size: 8.5)
                    }
                }
                .menuStyle(.button)
                .buttonStyle(CharkleButtonStyle(.standard, size: .sm))
                .menuIndicator(.hidden)
                .fixedSize()

                // Sensitivity Segmented Picker
                Picker("检测精度", selection: $sensitivity) {
                    ForEach(DeduplicationSensitivity.allCases, id: \.self) { mode in
                        Text(mode.localizedLabel).tag(mode)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(maxWidth: 320)
                .onChange(of: sensitivity) { _, _ in
                    startScan()
                }

                Spacer()

                Button {
                    startScan()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 11, weight: .semibold))
                        Text("重新扫描")
                    }
                }
                .buttonStyle(SettingsSecondaryButtonStyle())
                .disabled(isScanning || isCleaning)
                .fixedSize()
            }

            // Multi-Media Filter Chips (All 8 Charkle Media Kinds)
            HStack(spacing: 6) {
                ForEach(MediaKindFilter.allCases) { filter in
                    let active = selectedKindFilter == filter
                    Button {
                        if selectedKindFilter != filter {
                            selectedKindFilter = filter
                            startScan()
                        }
                    } label: {
                        Text(filter.label)
                            .font(.system(size: 11.5, weight: active ? .semibold : .medium))
                            .foregroundStyle(
                                active
                                    ? CharkleTheme.accentButtonForeground(for: colorScheme, source: accentSource)
                                    : Color.primary.opacity(0.82)
                            )
                            .padding(.horizontal, 9)
                            .frame(height: 24)
                            .background(
                                active
                                    ? CharkleTheme.accentButtonFill(for: colorScheme, source: accentSource)
                                    : SettingsPalette.subtleFill(for: colorScheme),
                                in: Capsule(style: .continuous)
                            )
                    }
                    .buttonStyle(CharkleTactileButtonStyle())
                }
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(SettingsPalette.railBackground(for: colorScheme).opacity(0.65))
    }

    private var scopeLabel: String {
        switch selectedScope {
        case .allActive: "范围：全部素材"
        case .inbox: "范围：收件箱"
        case .folder(let id): "范围：\(library.folder(byID: id)?.name ?? "指定文件夹")"
        }
    }

    // MARK: - Scanning & Empty States

    private var scanningBody: some View {
        VStack(spacing: 14) {
            Spacer()
            ProgressView(
                value: Double(max(0, scanProgress.completed)),
                total: Double(max(1, scanProgress.total))
            )
            .progressViewStyle(.linear)
            .frame(width: 280)

            Text(scanProgress.phase)
                .font(.system(size: 13.5, weight: .medium))
                .foregroundStyle(.primary)

            Text("纯本地比对文件内容、画面相似度、音频波形与来源链接，不消耗 AI 额度且不上传任何文件")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func emptyCleanBody(_ report: DeduplicationScanReport) -> some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 40))
                .foregroundStyle(SettingsPalette.positiveInk(for: colorScheme))

            Text("素材库很整洁，未发现重复项")
                .font(.system(size: 16, weight: .semibold))

            Text("已使用「\(sensitivity.localizedLabel)」精度校验 \(report.scannedAssetCount) 项素材（耗时 \(String(format: "%.2fs", max(0.01, report.durationSeconds)))）。")
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)

            if sensitivity != .relaxed {
                Button("切换至「宽松」模式再检一次") {
                    sensitivity = .relaxed
                }
                .buttonStyle(SettingsSecondaryButtonStyle())
                .padding(.top, 4)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
    }

    // MARK: - Two-Pane Duplicate Review Workspace

    private var comparisonSplitBody: some View {
        HStack(spacing: 0) {
            // Left Groups List
            VStack(spacing: 0) {
                HStack {
                    Text("重复组（\(groups.count)）")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(enabledGroupIDs.count == groups.count ? "全部取消" : "全选") {
                        if enabledGroupIDs.count == groups.count {
                            enabledGroupIDs.removeAll()
                        } else {
                            enabledGroupIDs = Set(groups.map(\.id))
                        }
                    }
                    .buttonStyle(CharkleButtonStyle(.subtle, size: .xs))
                }
                .padding(.horizontal, 12)
                .frame(height: 36)

                CharkleHairlineDivider()

                ScrollView(.vertical) {
                    LazyVStack(spacing: 4) {
                        ForEach(groups) { group in
                            groupListRow(group)
                        }
                    }
                    .padding(8)
                    .charkleCleanScrollbars(hidden: false)
                }
            }
            .frame(width: 286)
            .background(SettingsPalette.railBackground(for: colorScheme))

            CharkleHairlineDivider(axis: .vertical)

            // Right Side-by-Side Comparison Stage
            if let group = activeGroup {
                groupComparisonStage(group)
            } else {
                Spacer()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func groupListRow(_ group: DuplicateGroup) -> some View {
        let isSelected = activeGroup?.id == group.id
        let isEnabled = enabledGroupIDs.contains(group.id)
        let keepID = effectiveKeeperID(for: group)
        let keeper = group.candidates.first(where: { $0.asset.id == keepID }) ?? group.candidates.first
        let rowShape = RoundedRectangle(cornerRadius: 9, style: .continuous)

        return HStack(spacing: 8) {
            Button {
                if isEnabled {
                    enabledGroupIDs.remove(group.id)
                } else {
                    enabledGroupIDs.insert(group.id)
                }
            } label: {
                Image(systemName: isEnabled ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(isEnabled ? activeAccent : Color.secondary.opacity(0.6))
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if let keeperAsset = keeper?.asset {
                DedupThumbnailPreview(asset: keeperAsset, loader: library.thumbnailLoader, size: CGSize(width: 42, height: 42))
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(keeper?.asset.title ?? "重复组")
                    .font(.system(size: 12, weight: isSelected ? .semibold : .medium))
                    .lineLimit(1)
                    .foregroundStyle(.primary)

                HStack(spacing: 5) {
                    Text(group.matchKind.localizedLabel)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(group.matchKind == .exactBinary ? SettingsPalette.positiveInk(for: colorScheme) : activeAccent)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background(
                            (group.matchKind == .exactBinary ? SettingsPalette.positiveInk(for: colorScheme) : activeAccent).opacity(0.12),
                            in: RoundedRectangle(cornerRadius: 4, style: .continuous)
                        )

                    Text("\(group.candidates.count) 项")
                        .font(.system(size: 10.5))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)

                    Spacer(minLength: 0)

                    let saved = reclaimableBytes(for: group)
                    if saved > 0 {
                        Text("-\(ByteCountFormatter.string(fromByteCount: saved, countStyle: .file))")
                            .font(.system(size: 10.5, weight: .medium))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(
            isSelected
                ? Color.primary.opacity(colorScheme == .dark ? 0.11 : 0.075)
                : Color.clear,
            in: rowShape
        )
        .contentShape(rowShape)
        .onTapGesture {
            selectedGroupID = group.id
        }
    }

    private func groupComparisonStage(_ group: DuplicateGroup) -> some View {
        let keepID = effectiveKeeperID(for: group)
        let removeCount = max(0, group.candidates.count - 1)
        let savedBytes = reclaimableBytes(for: group)
        let similarityPct = Int((group.similarityScore * 100.0).rounded())

        return VStack(spacing: 0) {
            // Group Detail Header
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text("\(group.primaryMediaKind.localizedLabel) · \(group.matchKind.localizedLabel)")
                            .font(.system(size: 13.5, weight: .semibold))
                        if group.matchKind == .nearIdentical || group.matchKind == .audioWaveform {
                            Text("相似度 \(similarityPct)%")
                                .font(.system(size: 11, weight: .semibold))
                                .monospacedDigit()
                                .foregroundStyle(activeAccent)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(activeAccent.opacity(0.12), in: Capsule(style: .continuous))
                        }
                    }
                    Text("默认保留综合质量最高的 1 项，其余 \(removeCount) 项可清理（预计释放 \(ByteCountFormatter.string(fromByteCount: savedBytes, countStyle: .file))）")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button {
                    let plan = DeduplicationResolutionPlan(
                        keepAssetID: keepID,
                        removeAssetIDs: group.candidates.map(\.asset.id).filter { $0 != keepID }
                    )
                    requestCleanup(plans: [plan])
                } label: {
                    Text("仅清理本组")
                }
                .buttonStyle(SettingsSecondaryButtonStyle())
                .disabled(isCleaning)
                .fixedSize()
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)

            CharkleHairlineDivider()

            // Side-by-side Candidate Cards
            ScrollView(.vertical) {
                let columns = [
                    GridItem(.adaptive(minimum: 270, maximum: 360), spacing: 14, alignment: .top)
                ]
                LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
                    ForEach(group.candidates) { candidate in
                        candidateComparisonCard(
                            candidate: candidate,
                            group: group,
                            isKept: candidate.asset.id == keepID
                        )
                    }
                }
                .padding(18)
                .charkleCleanScrollbars(hidden: false)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func candidateComparisonCard(
        candidate: DuplicateAssetCandidate,
        group: DuplicateGroup,
        isKept: Bool
    ) -> some View {
        let asset = candidate.asset
        let cardShape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        let positiveTint = SettingsPalette.positiveInk(for: colorScheme)
        let borderTint = isKept
            ? positiveTint.opacity(colorScheme == .dark ? 0.65 : 0.55)
            : Color.primary.opacity(colorScheme == .dark ? 0.11 : 0.08)

        return VStack(alignment: .leading, spacing: 10) {
            // Top Status Row
            HStack(spacing: 6) {
                if isKept {
                    Label(
                        candidate.isRecommendedKeep ? "推荐保留 · 质量最高" : "已手动指定保留",
                        systemImage: "crown.fill"
                    )
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(positiveTint)
                } else {
                    Label(
                        disposalMode == .moveToTrash ? "将移至废纸篓" : "将彻底删除",
                        systemImage: "trash"
                    )
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.secondary)
                }

                Spacer()

                Button {
                    onOpenQuickLook(asset)
                } label: {
                    Image(systemName: "eye")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("全屏预览对比")

                if !isKept {
                    Button("改为保留") {
                        keeperOverrides[group.id] = asset.id
                    }
                    .buttonStyle(CharkleButtonStyle(.subtle, size: .xs))
                }
            }

            // Large Visual Preview Stage
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(SettingsPalette.subtleFill(for: colorScheme))
                DedupThumbnailPreview(asset: asset, loader: library.thumbnailLoader, size: CGSize(width: 300, height: 170))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .frame(height: 168)
            .onTapGesture {
                onOpenQuickLook(asset)
            }

            // Title & Technical Quality Specs
            VStack(alignment: .leading, spacing: 5) {
                Text(asset.title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .lineLimit(1)

                HStack(spacing: 6) {
                    specPill(candidate.formatLabel, emphasized: candidate.isLosslessFormat)
                    if asset.pixelWidth > 0 && asset.pixelHeight > 0 && asset.mediaKind != .audio {
                        specPill("\(asset.pixelWidth) × \(asset.pixelHeight)")
                    }
                    if let dur = asset.durationSeconds, dur > 0 {
                        specPill(formatDuration(dur))
                    }
                    if asset.fileSizeBytes > 0 {
                        specPill(ByteCountFormatter.string(fromByteCount: asset.fileSizeBytes, countStyle: .file))
                    }
                }

                // Location & Metadata Line
                HStack(spacing: 8) {
                    let location = asset.folderID.map { library.folderDisplayPath(for: $0) } ?? "收件箱"
                    Label(location, systemImage: asset.folderID == nil ? "tray" : "folder")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    if !asset.tags.isEmpty {
                        Text("\(asset.tags.count) 标签")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    if asset.rating > 0 {
                        Text("\(asset.rating)★")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }

                // Quality Reasons
                if !candidate.qualityReasons.isEmpty {
                    CharkleFlowLayout(spacing: 5, lineSpacing: 5) {
                        ForEach(candidate.qualityReasons, id: \.self) { reason in
                            Text(reason)
                                .font(.system(size: 10.5, weight: .medium))
                                .foregroundStyle(isKept ? positiveTint : .secondary)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2.5)
                                .background(
                                    (isKept ? positiveTint : Color.primary).opacity(colorScheme == .dark ? 0.14 : 0.08),
                                    in: Capsule(style: .continuous)
                                )
                        }
                    }
                    .padding(.top, 2)
                }
            }
        }
        .padding(12)
        .background(
            SettingsPalette.cardBackground(for: colorScheme),
            in: cardShape
        )
        .overlay(
            cardShape.strokeBorder(borderTint, lineWidth: isKept ? 1.5 : CharkleTheme.hairlineWidth)
        )
    }

    private func specPill(_ text: String, emphasized: Bool = false) -> some View {
        Text(text)
            .font(.system(size: 10.5, weight: emphasized ? .semibold : .medium))
            .monospacedDigit()
            .foregroundStyle(emphasized ? activeAccent : Color.primary.opacity(0.84))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                emphasized
                    ? activeAccent.opacity(colorScheme == .dark ? 0.18 : 0.10)
                    : SettingsPalette.subtleFill(for: colorScheme),
                in: RoundedRectangle(cornerRadius: 5, style: .continuous)
            )
    }

    private func formatDuration(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        let m = total / 60
        let s = total % 60
        return String(format: "%d:%02d", m, s)
    }

    // MARK: - Footer Cleanup Bar

    private var footerActionBar: some View {
        HStack(spacing: 12) {
            Toggle(isOn: $mergeMetadata) {
                Label("合并标签、评分、备注并自动迁移情绪板引用", systemImage: "arrow.triangle.merge")
                    .font(.system(size: 12, weight: .medium))
            }
            .toggleStyle(.checkbox)

            Spacer()

            Picker("清理方式", selection: $disposalMode) {
                ForEach(DuplicateDisposalMode.allCases, id: \.self) { mode in
                    Text(mode.localizedLabel).tag(mode)
                }
            }
            .labelsHidden()
            .frame(width: 170)

            Button {
                let plans: [DeduplicationResolutionPlan] = selectedGroups.map { group in
                    let keepID = effectiveKeeperID(for: group)
                    return DeduplicationResolutionPlan(
                        keepAssetID: keepID,
                        removeAssetIDs: group.candidates.map(\.asset.id).filter { $0 != keepID }
                    )
                }
                requestCleanup(plans: plans)
            } label: {
                HStack(spacing: 6) {
                    if isCleaning {
                        ProgressView().controlSize(.mini)
                    }
                    Text(
                        selectedGroups.isEmpty
                            ? "请先勾选重复组"
                            : "清理已选 \(selectedRemovableCount) 项（释放 \(ByteCountFormatter.string(fromByteCount: selectedReclaimableBytes, countStyle: .file))）"
                    )
                }
            }
            .buttonStyle(SettingsPrimaryButtonStyle())
            .disabled(selectedGroups.isEmpty || isCleaning || isScanning)
            .fixedSize()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(SettingsPalette.railBackground(for: colorScheme))
    }

    // MARK: - Scan & Cleanup Actions

    private func startScan() {
        scanTask?.cancel()
        isScanning = true
        scanProgress = DeduplicationScanProgress(completed: 0, total: 1, phase: "正在扫描素材库…")

        let scope: DeduplicationScanScope = switch selectedScope {
        case .allActive: .allActive
        case .inbox: .inbox
        case .folder(let id): .folder(id, includeSubfolders: true)
        }
        let currentSensitivity = sensitivity
        let kindFilter = selectedKindFilter.kinds

        let lastProgressPublish = OSAllocatedUnfairLock<CFAbsoluteTime>(initialState: 0)
        scanTask = Task {
            let scanned = await library.scanDuplicateAssets(
                scope: scope,
                sensitivity: currentSensitivity,
                mediaKinds: kindFilter
            ) { progress in
                let now = CFAbsoluteTimeGetCurrent()
                let shouldPublish = progress.completed >= progress.total || lastProgressPublish.withLock { last in
                    if now - last >= 0.06 {
                        last = now
                        return true
                    }
                    return false
                }
                guard shouldPublish else { return }
                await MainActor.run {
                    scanProgress = progress
                }
            }
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self.report = scanned
                self.keeperOverrides = [:]
                let foundGroups = scanned?.groups ?? []
                self.enabledGroupIDs = Set(foundGroups.map(\.id))
                self.selectedGroupID = foundGroups.first?.id
                self.isScanning = false
            }
        }
    }

    private func requestCleanup(plans: [DeduplicationResolutionPlan]) {
        guard !plans.isEmpty else { return }
        if disposalMode == .permanentlyDelete {
            pendingPermanentCleanupPlans = plans
        } else {
            executeCleanup(plans: plans, disposal: .moveToTrash)
        }
    }

    private func executeCleanup(plans: [DeduplicationResolutionPlan], disposal: DuplicateDisposalMode) {
        guard !isCleaning else { return }
        isCleaning = true
        let shouldMerge = mergeMetadata
        cleanupTask?.cancel()
        cleanupTask = Task {
            let result = await library.resolveDuplicateGroups(
                plans,
                disposal: disposal,
                mergeMetadata: shouldMerge
            )
            if let result {
                if result.updatedBoardCount > 0 {
                    await moodboards.refreshBoards()
                    if let activeID = moodboards.activeBoard?.id {
                        await moodboards.reloadActiveBoardIfNeeded(id: activeID)
                    }
                }
                let sizeStr = ByteCountFormatter.string(fromByteCount: result.reclaimedBytes, countStyle: .file)
                let verb = disposal == .permanentlyDelete ? "已彻底清理" : "已移至废纸篓"
                let boardNote = result.updatedBoardCount > 0 ? " · 自动迁移 \(result.updatedBoardCount) 个情绪板引用" : ""
                coordinator.showToast(
                    "\(verb) \(result.removedAssetCount) 项重复素材（释放 \(sizeStr)）\(boardNote)",
                    icon: "checkmark.seal.fill",
                    tone: .success
                )
            } else if let err = library.lastError {
                coordinator.showToast(err, icon: "exclamationmark.triangle", tone: .warning)
            }
            guard !Task.isCancelled else {
                await MainActor.run { isCleaning = false }
                return
            }
            await MainActor.run {
                isCleaning = false
                startScan()
            }
        }
    }
}

/// Lightweight async thumbnail/icon preview cell for SmartDeduplicationView cards & group rows.
private struct DedupThumbnailPreview: View {
    let asset: AssetRecord
    let loader: ThumbnailImageLoader
    let size: CGSize

    @State private var image: NSImage? = nil
    @State private var loadedAssetID: UUID? = nil

    var body: some View {
        Group {
            if let image, loadedAssetID == asset.id {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: size.width > 80 ? .fit : .fill)
                    .frame(width: size.width, height: size.height)
                    .clipped()
            } else {
                ZStack {
                    Color.primary.opacity(0.05)
                    Image(systemName: fallbackSymbol)
                        .font(.system(size: size.width > 80 ? 28 : 16, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .frame(width: size.width, height: size.height)
            }
        }
        .task(id: asset.id) {
            let targetID = asset.id
            let tier: ThumbnailTier = .grid520
            if let cached = loader.cachedImage(for: targetID, tier: tier) {
                image = cached
                loadedAssetID = targetID
                return
            }
            image = nil
            loadedAssetID = nil
            let loaded = await loader.loadImage(for: targetID, tier: tier)
            if !Task.isCancelled {
                image = loaded
                loadedAssetID = loaded != nil ? targetID : nil
            }
        }
    }

    private var fallbackSymbol: String {
        switch asset.mediaKind {
        case .audio: "waveform"
        case .video: "film"
        case .webBookmark: "globe"
        case .document: "doc.text"
        case .designFile: "scribble.variable"
        case .model3D: "cube.transparent"
        case .animatedImage: "play.square.stack"
        case .image: "photo"
        }
    }
}
