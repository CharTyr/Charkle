import AppKit
import CharkleCanvas
import CharkleCore
import SwiftUI

/// Adaptive Right Inspector cleanly switching between:
/// 1. Moodboard Right Rail (Candidate Swap Pool, Board Palette Strip, Quick Add from Library, Pin Offline, Export)
/// 2. Multi-Select Batch Inspector (Bulk Folder, Rating, Tags, Pin Offline, Create Moodboard)
/// 3. Single Asset Inspector (Subtle ambient color tint, clickable HEX palette chips, tags + AI suggestions, OCR/notes, EXIF, Similar Assets)
public struct InspectorView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public let coordinator: AppCoordinatorStore
    public let library: LibraryStore
    public let moodboards: MoodboardStore
    public let onCopyHex: (String) -> Void
    public let onFilterByColor: (String) -> Void
    public let onOpenQuickLook: (AssetRecord) -> Void
    public let onCopyBoardImage: () -> Void
    public let onSaveBoardImage: (MoodboardExportFormat) -> Void

    @State private var newTagInput: String = ""
    @State private var batchTagInput: String = ""
    @State private var quickAddQuery: String = ""
    @State private var notesDraft: String = ""
    @State private var titleDraft: String = ""
    @State private var boardTitleDraft: String = ""
    @State private var boardSubtitleDraft: String = ""
    @State private var pendingPermanentDeleteIDs: [UUID] = []

    public init(
        coordinator: AppCoordinatorStore,
        library: LibraryStore,
        moodboards: MoodboardStore,
        onCopyHex: @escaping (String) -> Void,
        onFilterByColor: @escaping (String) -> Void,
        onOpenQuickLook: @escaping (AssetRecord) -> Void,
        onCopyBoardImage: @escaping () -> Void,
        onSaveBoardImage: @escaping (MoodboardExportFormat) -> Void
    ) {
        self.coordinator = coordinator
        self.library = library
        self.moodboards = moodboards
        self.onCopyHex = onCopyHex
        self.onFilterByColor = onFilterByColor
        self.onOpenQuickLook = onOpenQuickLook
        self.onCopyBoardImage = onCopyBoardImage
        self.onSaveBoardImage = onSaveBoardImage
    }

    public var body: some View {
        ZStack(alignment: .top) {
            CharkleTheme.inspectorBackground(for: colorScheme)
                .ignoresSafeArea()

            // Subtle low-saturation ambient tint ONLY for Single Asset Inspector
            if !coordinator.isViewingMoodboard, let asset = library.primarySelectedAsset {
                LinearGradient(
                    colors: [
                        CharkleTheme.ambientTint(from: asset.dominantColors.first?.hex, scheme: colorScheme),
                        .clear
                    ],
                    startPoint: .top,
                    endPoint: .center
                )
                .frame(height: 220)
                .allowsHitTesting(false)
            }

            if coordinator.isViewingMoodboard, let board = moodboards.activeBoard {
                moodboardRightRail(board)
            } else if library.selectedAssetIDs.count >= 2 {
                multiSelectBatchInspector
            } else if let asset = library.primarySelectedAsset {
                singleAssetInspector(asset)
            } else {
                emptyInspectorPlaceholder
            }
        }
        .frame(width: 300)
        .frame(maxHeight: .infinity)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(CharkleTheme.hairline(for: colorScheme))
                .frame(width: 1)
                .ignoresSafeArea(.container, edges: .top)
        }
        .alert(
            "彻底删除 \(pendingPermanentDeleteIDs.count) 项素材？",
            isPresented: Binding(
                get: { !pendingPermanentDeleteIDs.isEmpty },
                set: { if !$0 { pendingPermanentDeleteIDs = [] } }
            )
        ) {
            Button("取消", role: .cancel) {
                pendingPermanentDeleteIDs = []
            }
            Button("彻底删除", role: .destructive) {
                let ids = pendingPermanentDeleteIDs
                pendingPermanentDeleteIDs = []
                Task {
                    await library.permanentlyDeleteAssets(ids)
                    coordinator.showToast("已彻底删除 \(ids.count) 项素材", icon: "trash.slash")
                }
            }
        } message: {
            Text("彻底删除后将无法从废纸篓恢复。")
        }
    }

    // MARK: - 1. Single Asset Inspector

    private func singleAssetInspector(_ asset: AssetRecord) -> some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 16) {
                // Clean Uncropped Proportional Preview Card
                let naturalRatio = max(0.35, min(3.2, CGFloat(asset.aspectRatio)))
                let previewContentWidth: CGFloat = 268
                let fittedHeight = min(320, max(110, (previewContentWidth / naturalRatio).rounded()))
                let fittedWidth = min(previewContentWidth, (fittedHeight * naturalRatio).rounded())

                ZStack {
                    AssetThumbnailSurface(
                        asset: asset,
                        loader: library.thumbnailLoader,
                        tier: .preview1400,
                        cornerRadius: CharkleTheme.Radius.cardOuter,
                        contentMode: .fit
                    )
                    .frame(width: fittedWidth, height: fittedHeight)
                    .overlay(
                        RoundedRectangle(cornerRadius: CharkleTheme.Radius.cardOuter, style: .continuous)
                            .strokeBorder(CharkleTheme.hairline(for: colorScheme), lineWidth: 0.75)
                    )
                }
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
                .onTapGesture {
                    onOpenQuickLook(asset)
                }
                .help("点击打开 Quick Look 全屏预览")

                // Editable Title + Quick Actions
                VStack(alignment: .leading, spacing: 8) {
                    TextField("素材标题", text: $titleDraft)
                        .textFieldStyle(.plain)
                        .font(.system(size: 14, weight: .semibold))
                        .onSubmit { commitSingleAssetTitle(asset) }

                    HStack(spacing: 8) {
                        // 5-Star Rating (with Kubai microOvershoot)
                        HStack(spacing: 3) {
                            ForEach(1...5, id: \.self) { star in
                                Button {
                                    let target = asset.rating == star ? 0 : star
                                    Task { await library.setRating(target, for: [asset.id]) }
                                } label: {
                                    Image(systemName: star <= asset.rating ? "star.fill" : "star")
                                        .font(.system(size: 12))
                                        .foregroundStyle(star <= asset.rating ? Color(charkleHex: "#E5B243") : .secondary.opacity(0.45))
                                        .scaleEffect(star == asset.rating ? 1.08 : 1.0)
                                        .animation(CharkleMotion.accessible(CharkleMotion.microOvershoot, reduced: reduceMotion), value: asset.rating)
                                }
                                .buttonStyle(.plain)
                            }
                        }

                        Spacer()

                        if !asset.isTrashed {
                            // Keep Downloaded (iCloud-style) Toggle
                            Button {
                                let nextPinned = !asset.pinnedOffline
                                Task {
                                    await library.togglePinOffline(ids: [asset.id], pinned: nextPinned)
                                    coordinator.showToast(
                                        nextPinned ? "已设为始终保留在本地" : "已取消始终保留，将按需管理空间",
                                        icon: nextPinned ? "arrow.down.circle.fill" : "icloud"
                                    )
                                }
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: asset.pinnedOffline ? "arrow.down.circle.fill" : "arrow.down.circle")
                                        .font(.system(size: 10.5))
                                    Text(asset.pinnedOffline ? "已保留在本地" : "始终保留在本地")
                                        .font(.system(size: 11, weight: .medium))
                                }
                                .foregroundStyle(asset.pinnedOffline ? Color.accentColor : .secondary)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(
                                    asset.pinnedOffline ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.06),
                                    in: Capsule(style: .continuous)
                                )
                            }
                            .buttonStyle(.plain)
                            .help(asset.pinnedOffline ? "已始终保留在本机，离线可用；点击取消" : "始终将原文件保留在本机，不会被缓存自动清理")
                        }
                    }
                }

                // Add to Moodboard + Folder Picker (or Trash Recovery Actions when in Trash)
                if asset.isTrashed {
                    HStack(spacing: 8) {
                        Button {
                            Task {
                                await library.restoreAssets([asset.id])
                                coordinator.showToast("已放回原处", icon: "arrow.uturn.backward")
                            }
                        } label: {
                            Label("放回原处", systemImage: "arrow.uturn.backward")
                                .font(.system(size: 11.5, weight: .semibold))
                                .foregroundStyle(.white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 7)
                                .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        }
                        .buttonStyle(.plain)

                        Button(role: .destructive) {
                            pendingPermanentDeleteIDs = [asset.id]
                        } label: {
                            Label("彻底删除", systemImage: "trash.slash")
                                .font(.system(size: 11.5, weight: .medium))
                                .foregroundStyle(.red)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 7)
                                .background(Color.red.opacity(0.10), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                } else {
                    HStack(spacing: 8) {
                        Menu {
                            ForEach(moodboards.boards) { board in
                                Button(board.title) {
                                    Task {
                                        await moodboards.addAssetsToSpecificBoard(boardID: board.id, assets: [asset])
                                        coordinator.showToast("已加入情绪板「\(board.title)」", icon: "rectangle.3.group")
                                    }
                                }
                            }
                            Divider()
                            Button("以此图快速生成新情绪板…") {
                                coordinator.presentMoodboardGenerator(entry: .seedAssets)
                            }
                        } label: {
                            HStack(spacing: 5) {
                                CharkleIcon("sparkle-board", style: .duotone, size: 13)
                                Text("加入情绪板")
                                    .font(.system(size: 11.5, weight: .medium))
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                            .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        }
                        .menuStyle(.borderlessButton)

                        Menu {
                            Button("收件箱") {
                                Task { await library.moveAssets([asset.id], toFolderID: nil) }
                            }
                            Divider()
                            ForEach(library.folders) { folder in
                                Button(library.folderDisplayPath(for: folder.id)) {
                                    Task { await library.moveAssets([asset.id], toFolderID: folder.id) }
                                }
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "folder")
                                    .font(.system(size: 11))
                                Text(folderName(for: asset.folderID))
                                    .font(.system(size: 11.5, weight: .medium))
                                    .lineLimit(1)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                            .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        }
                        .menuStyle(.borderlessButton)
                    }

                    // Finder Reveal + Copy + Cut quick row
                    HStack(spacing: 6) {
                        Button {
                            Task {
                                let ok = await library.revealInFinder(assetID: asset.id)
                                if !ok {
                                    coordinator.showToast("无法定位本地文件", icon: "exclamationmark.triangle", tone: .warning)
                                }
                            }
                        } label: {
                            Label("在访达中显示", systemImage: "folder")
                                .font(.system(size: 11, weight: .medium))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 5.5)
                                .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                        }
                        .buttonStyle(.plain)

                        Button {
                            Task {
                                _ = await library.copyAssetsToPasteboard([asset.id])
                                coordinator.showToast("已拷贝到剪贴板", icon: "doc.on.doc")
                            }
                        } label: {
                            Label("拷贝", systemImage: "doc.on.doc")
                                .font(.system(size: 11, weight: .medium))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5.5)
                                .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                        }
                        .buttonStyle(.plain)

                        Button {
                            Task {
                                _ = await library.cutAssets([asset.id])
                                coordinator.showToast("已剪切，前往目标文件夹按 ⌘V 移动", icon: "scissors")
                            }
                        } label: {
                            Label("剪切", systemImage: "scissors")
                                .font(.system(size: 11, weight: .medium))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5.5)
                                .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                }

                // Dominant CIELAB Color Swatches
                if !asset.dominantColors.isEmpty {
                    inspectorSection("提取色板") {
                        CharkleFlowLayout(spacing: 6, lineSpacing: 6) {
                            ForEach(asset.dominantColors.prefix(6), id: \.hex) { swatch in
                                let hex = swatch.hex.uppercased()
                                Button {
                                    onCopyHex(hex)
                                } label: {
                                    HStack(spacing: 5) {
                                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                                            .fill(Color(charkleHex: hex))
                                            .frame(width: 14, height: 14)
                                            .overlay(
                                                RoundedRectangle(cornerRadius: 4, style: .continuous)
                                                    .strokeBorder(Color.primary.opacity(0.14), lineWidth: 0.5)
                                            )
                                        Text(hex)
                                            .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                                    }
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 4)
                                    .background(CharkleTheme.surfaceElevated(for: colorScheme), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                                            .strokeBorder(CharkleTheme.hairline(for: colorScheme), lineWidth: 0.75)
                                    )
                                }
                                .buttonStyle(.plain)
                                .contextMenu {
                                    Button("复制 \(hex)") { onCopyHex(hex) }
                                    Button("以此色筛选素材库") { onFilterByColor(hex) }
                                }
                                .help("点击复制 HEX，右键按色彩筛选")
                            }
                        }
                    }
                }

                // Tags + 1-Click AI Suggested Tags
                inspectorSection("标签") {
                    VStack(alignment: .leading, spacing: 8) {
                        if !asset.tags.isEmpty {
                            CharkleFlowLayout(spacing: 6, lineSpacing: 6) {
                                ForEach(asset.tags, id: \.self) { tag in
                                    HStack(spacing: 4) {
                                        Text("#\(tag)")
                                            .font(.system(size: 11, weight: .medium))
                                        Button {
                                            Task { await library.removeTag(tag, from: [asset.id]) }
                                        } label: {
                                            Image(systemName: "xmark")
                                                .font(.system(size: 8.5, weight: .bold))
                                                .foregroundStyle(.secondary)
                                        }
                                        .buttonStyle(.plain)
                                    }
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(Color.primary.opacity(0.07), in: Capsule(style: .continuous))
                                }
                            }
                        }

                        HStack(spacing: 6) {
                            TextField("添加标签，回车确认…", text: $newTagInput)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 11.5))
                                .onSubmit {
                                    let val = newTagInput
                                    newTagInput = ""
                                    Task { await library.addTags([val], to: [asset.id]) }
                                }
                        }

                        if !asset.suggestedTags.isEmpty {
                            VStack(alignment: .leading, spacing: 5) {
                                HStack {
                                    Text("AI 建议标签")
                                        .font(.system(size: 10.5, weight: .semibold))
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                    Button("全部采纳") {
                                        Task { await library.acceptAllSuggestedTags(for: [asset.id]) }
                                    }
                                    .font(.system(size: 10.5, weight: .medium))
                                    .buttonStyle(.plain)
                                    .foregroundStyle(Color.accentColor)
                                }
                                CharkleFlowLayout(spacing: 5, lineSpacing: 5) {
                                    ForEach(asset.suggestedTags, id: \.self) { tag in
                                        Button {
                                            Task { await library.acceptSuggestedTag(tag, for: asset.id) }
                                        } label: {
                                            HStack(spacing: 3) {
                                                Image(systemName: "plus")
                                                    .font(.system(size: 8.5, weight: .bold))
                                                Text(tag)
                                                    .font(.system(size: 11, weight: .medium))
                                            }
                                            .foregroundStyle(Color.accentColor)
                                            .padding(.horizontal, 8)
                                            .padding(.vertical, 3.5)
                                            .background(Color.accentColor.opacity(0.10), in: Capsule(style: .continuous))
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                            }
                            .padding(.top, 2)
                        }
                    }
                }

                // Notes & OCR Text
                inspectorSection("备注与识别文本") {
                    VStack(alignment: .leading, spacing: 8) {
                        TextEditor(text: $notesDraft)
                            .font(.system(size: 12))
                            .frame(minHeight: 58, maxHeight: 110)
                            .padding(6)
                            .background(CharkleTheme.surfaceElevated(for: colorScheme), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .strokeBorder(CharkleTheme.hairline(for: colorScheme), lineWidth: 0.75)
                            )
                            .onChange(of: notesDraft) { _, newValue in
                                if newValue != asset.notes {
                                    Task {
                                        await library.applyPatch(AssetBatchPatch(assetIDs: [asset.id], notes: newValue))
                                    }
                                }
                            }

                        if let ocr = asset.ocrText, !ocr.isEmpty {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("OCR 识别文字")
                                    .font(.system(size: 10.5, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                Text(ocr)
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                                    .lineLimit(4)
                            }
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        }

                        if let aiDesc = asset.aiDescription, !aiDesc.isEmpty {
                            Text(aiDesc)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .padding(8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        }
                    }
                }

                // Media & EXIF Specifications
                inspectorSection("媒体信息") {
                    VStack(spacing: 6) {
                        specRow("类型", asset.mediaKind.localizedLabel)
                        specRow("尺寸", "\(asset.pixelWidth) × \(asset.pixelHeight) (\(asset.aspectShape.localizedLabel))")
                        specRow("大小", ByteCountFormatter.string(fromByteCount: asset.fileSizeBytes, countStyle: .file))
                        if let duration = asset.durationSeconds {
                            specRow("时长", CanvasFormatters.durationString(duration))
                        }
                        specRow("原文件状态", asset.isLocalOriginalCached ? "已缓存本地" : "云端按需拉取")
                        if let urlStr = asset.sourceURL, let url = URL(string: urlStr) {
                            HStack {
                                Text("来源")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Link(asset.sourceDomain ?? url.host ?? "打开链接", destination: url)
                                    .font(.system(size: 11, weight: .medium))
                                    .lineLimit(1)
                            }
                        }
                    }
                }

                // Similar Assets Strip
                if !library.similarAssets.isEmpty {
                    inspectorSection("视觉与色彩相似") {
                        LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                            ForEach(library.similarAssets.prefix(6)) { scored in
                                AssetThumbnailSurface(
                                    asset: scored.asset,
                                    loader: library.thumbnailLoader,
                                    tier: .grid520,
                                    cornerRadius: 8
                                )
                                .frame(height: 76)
                                .onTapGesture {
                                    library.selectedAssetIDs = [scored.asset.id]
                                }
                                .help(scored.matchReasons.joined(separator: " · "))
                            }
                        }
                    }
                }
            }
            .padding(14)
        }
        .onAppear {
            titleDraft = asset.title
            notesDraft = asset.notes
            library.refreshInspectorContext(for: asset.id)
        }
        .onChange(of: asset.id) { _, newID in
            titleDraft = asset.title
            notesDraft = asset.notes
            library.refreshInspectorContext(for: newID)
        }
    }

    // MARK: - 2. Multi-Select Batch Inspector

    private var multiSelectBatchInspector: some View {
        let ids = Array(library.selectedAssetIDs)
        let selectedAssets = library.selectedAssets
        let isTrashSelection = coordinator.selectedDestination == .trash
            || (!selectedAssets.isEmpty && selectedAssets.allSatisfy(\.isTrashed))

        return ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("已选中 \(ids.count) 项素材")
                        .font(.system(size: 15, weight: .semibold))
                        .monospacedDigit()
                    Text(isTrashSelection ? "这些素材当前位于废纸篓，可恢复到原位置或彻底删除" : "批量归档、打标签或一键进入情绪板排版")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }

                if isTrashSelection {
                    inspectorSection("废纸篓操作") {
                        VStack(spacing: 8) {
                            Button {
                                Task {
                                    await library.restoreAssets(ids)
                                    coordinator.showToast("已将 \(ids.count) 项放回原处", icon: "arrow.uturn.backward")
                                }
                            } label: {
                                Label("全部放回原处", systemImage: "arrow.uturn.backward")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(.white)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 8)
                                    .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                            }
                            .buttonStyle(.plain)

                            Button(role: .destructive) {
                                pendingPermanentDeleteIDs = ids
                            } label: {
                                Label("彻底删除所选 \(ids.count) 项", systemImage: "trash.slash")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(.red)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 8)
                                    .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                } else {
                    // Primary Moodboard CTA
                    Button {
                        Task {
                            if let board = await moodboards.createBoardFromSelection(assetIDs: ids, title: "灵感合集 (\(ids.count))") {
                                coordinator.openMoodboard(board.id)
                                coordinator.showToast("已用 \(ids.count) 项素材生成情绪板", icon: "sparkles.rectangle.stack")
                            }
                        }
                    } label: {
                        HStack(spacing: 6) {
                            CharkleIcon("sparkle-board", style: .duotone, size: 15, color: .white)
                            Text("从所选生成情绪板")
                                .font(.system(size: 12.5, weight: .semibold))
                        }
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    .buttonStyle(CharkleTactileButtonStyle())

                    inspectorSection("批量移动到文件夹") {
                        VStack(spacing: 6) {
                            Menu {
                                Button("收件箱") {
                                    Task { await library.moveAssets(ids, toFolderID: nil) }
                                }
                                Divider()
                                ForEach(library.folders) { folder in
                                    Button(library.folderDisplayPath(for: folder.id)) {
                                        Task { await library.moveAssets(ids, toFolderID: folder.id) }
                                    }
                                }
                            } label: {
                                HStack {
                                    Image(systemName: "folder")
                                    Text("选择目标文件夹…")
                                    Spacer()
                                    Image(systemName: "chevron.up.chevron.down")
                                        .font(.system(size: 10))
                                }
                                .font(.system(size: 12))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 7)
                                .background(CharkleTheme.surfaceElevated(for: colorScheme), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .strokeBorder(CharkleTheme.hairline(for: colorScheme), lineWidth: 0.75)
                                )
                            }
                            .menuStyle(.borderlessButton)
                        }
                    }

                    inspectorSection("批量添加标签") {
                        HStack(spacing: 6) {
                            TextField("输入标签回车批量添加…", text: $batchTagInput)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 12))
                                .onSubmit {
                                    let val = batchTagInput
                                    batchTagInput = ""
                                    Task {
                                        await library.addTags([val], to: ids)
                                        coordinator.showToast("已为 \(ids.count) 项添加标签 #\(val)")
                                    }
                                }
                        }
                    }

                    inspectorSection("批量评分") {
                        HStack(spacing: 6) {
                            ForEach(1...5, id: \.self) { star in
                                Button {
                                    Task { await library.setRating(star, for: ids) }
                                } label: {
                                    Image(systemName: "star.fill")
                                        .font(.system(size: 14))
                                        .foregroundStyle(Color(charkleHex: "#E5B243"))
                                }
                                .buttonStyle(.plain)
                            }
                            Spacer()
                            Button("清除评分") {
                                Task { await library.setRating(0, for: ids) }
                            }
                            .font(.system(size: 11))
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                        }
                    }

                    inspectorSection("本地与操作") {
                        let allKeptLocally = !selectedAssets.isEmpty && selectedAssets.allSatisfy(\.pinnedOffline)
                        VStack(spacing: 8) {
                            Button {
                                let nextPinned = !allKeptLocally
                                Task {
                                    await library.togglePinOffline(ids: ids, pinned: nextPinned)
                                    coordinator.showToast(
                                        nextPinned ? "已将 \(ids.count) 项设为始终保留在本地" : "已取消 \(ids.count) 项的始终保留",
                                        icon: nextPinned ? "arrow.down.circle.fill" : "icloud"
                                    )
                                }
                            } label: {
                                Label(
                                    allKeptLocally ? "取消全部保留在本地" : "全部始终保留在本地",
                                    systemImage: allKeptLocally ? "icloud" : "arrow.down.circle"
                                )
                                .font(.system(size: 12, weight: .medium))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 7)
                                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                            }
                            .buttonStyle(.plain)

                            Button(role: .destructive) {
                                Task {
                                    await library.trashAssets(ids)
                                    coordinator.showToast("已将 \(ids.count) 项移至废纸篓", icon: "trash")
                                }
                            } label: {
                                Label("移至废纸篓", systemImage: "trash")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(.red)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 7)
                                    .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(14)
        }
    }

    // MARK: - 3. Moodboard Right Rail (Candidate Swap Pool + Palette + Quick Add + Export)

    private func moodboardRightRail(_ board: MoodboardDocument) -> some View {
        let isActiveNotchBoard = coordinator.activeMoodboardID == board.id
        let quickAddResults = quickAddFilteredAssets(excluding: Set(board.referencedAssetIDs))

        return ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 16) {
                // Board Title & Active/Offline Controls
                VStack(alignment: .leading, spacing: 8) {
                    TextField("情绪板名称", text: $boardTitleDraft)
                        .textFieldStyle(.plain)
                        .font(.system(size: 15, weight: .semibold))
                        .onSubmit { commitBoardHeader(board) }

                    TextField("补充创作 Brief 或氛围备注…", text: $boardSubtitleDraft)
                        .textFieldStyle(.plain)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .onSubmit { commitBoardHeader(board) }

                    HStack(spacing: 6) {
                        Button {
                            coordinator.activeMoodboardID = board.id
                            coordinator.showToast("已设为刘海活跃情绪板", icon: "checkmark.circle.fill")
                        } label: {
                            HStack(spacing: 4) {
                                Circle()
                                    .fill(isActiveNotchBoard ? Color.green : Color.secondary.opacity(0.4))
                                    .frame(width: 6, height: 6)
                                Text(isActiveNotchBoard ? "当前活跃板" : "设为活跃板")
                                    .font(.system(size: 11, weight: .medium))
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(Color.primary.opacity(0.07), in: Capsule(style: .continuous))
                        }
                        .buttonStyle(.plain)

                        Button {
                            let nextPinned = !board.pinnedOffline
                            Task {
                                await moodboards.togglePinnedOffline(id: board.id)
                                coordinator.showToast(
                                    nextPinned ? "整板素材将始终保留在本地" : "已取消整板始终保留在本地",
                                    icon: nextPinned ? "arrow.down.circle.fill" : "icloud"
                                )
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: board.pinnedOffline ? "arrow.down.circle.fill" : "arrow.down.circle")
                                    .font(.system(size: 10.5))
                                Text(board.pinnedOffline ? "已保留在本地" : "始终保留在本地")
                                    .font(.system(size: 11, weight: .medium))
                            }
                            .foregroundStyle(board.pinnedOffline ? Color.accentColor : .primary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(
                                board.pinnedOffline ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.07),
                                in: Capsule(style: .continuous)
                            )
                        }
                        .buttonStyle(.plain)
                        .help(board.pinnedOffline ? "整板素材已始终保留在本机，离线可用" : "始终将此情绪板引用的素材保留在本机")
                    }
                }

                // Active Swap Mode Banner
                if let swapNodeID = moodboards.swappingNodeID {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Color.accentColor)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("正在替换选中卡片")
                                .font(.system(size: 11.5, weight: .semibold))
                            Text("点击下方任意候选图即可原地替换")
                                .font(.system(size: 10.5))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("取消") {
                            moodboards.swappingNodeID = nil
                        }
                        .font(.system(size: 11))
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                    }
                    .padding(10)
                    .background(Color.accentColor.opacity(0.11), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(Color.accentColor.opacity(0.35), lineWidth: 1)
                    )
                    .id(swapNodeID)
                }

                // Candidate Swap Pool (20-40同方向候选池)
                inspectorSection(moodboards.swappingNodeID != nil ? "候选替换池（点击原地替换）" : "同方向候选池（点击追加上板）") {
                    if moodboards.candidatePool.isEmpty {
                        Text("暂无更多候选图，可从下方直接检索素材库添加。")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.tertiary)
                    } else {
                        LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                            ForEach(moodboards.candidatePool.prefix(24)) { candidate in
                                Button {
                                    Task {
                                        if let swapID = moodboards.swappingNodeID {
                                            await moodboards.swapNode(nodeID: swapID, with: candidate.asset)
                                            coordinator.showToast("已原地替换为「\(candidate.asset.title)」", icon: "arrow.triangle.2.circlepath")
                                        } else {
                                            await moodboards.appendAssets([candidate.asset])
                                            coordinator.showToast("已追加到情绪板", icon: "plus.circle.fill")
                                        }
                                    }
                                } label: {
                                    ZStack(alignment: .bottomLeading) {
                                        AssetThumbnailSurface(
                                            asset: candidate.asset,
                                            loader: library.thumbnailLoader,
                                            tier: .grid520,
                                            cornerRadius: 8
                                        )

                                        if let reason = candidate.matchReasons.first {
                                            Text(reason)
                                                .font(.system(size: 9.5, weight: .semibold))
                                                .foregroundStyle(.white)
                                                .padding(.horizontal, 6)
                                                .padding(.vertical, 2)
                                                .background(Color.black.opacity(0.58), in: Capsule(style: .continuous))
                                                .padding(5)
                                        }
                                    }
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 86)
                                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                                            .strokeBorder(CharkleTheme.hairline(for: colorScheme), lineWidth: 0.75)
                                    )
                                }
                                .buttonStyle(CharkleTactileButtonStyle())
                            }
                        }
                    }
                }

                // Board Harmonious Palette Strip
                inspectorSection("全板和谐色板") {
                    VStack(alignment: .leading, spacing: 8) {
                        if !board.extractedPalette.isEmpty {
                            HStack(spacing: 4) {
                                ForEach(board.extractedPalette.prefix(7), id: \.hex) { swatch in
                                    Button {
                                        onCopyHex(swatch.hex.uppercased())
                                    } label: {
                                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                                            .fill(Color(charkleHex: swatch.hex))
                                            .frame(height: 30)
                                            .overlay(
                                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                                    .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
                                            )
                                    }
                                    .buttonStyle(.plain)
                                    .help("点击复制 \(swatch.hex.uppercased())")
                                }
                            }
                        }
                        Button {
                            Task {
                                await moodboards.syncBoardPalette()
                                coordinator.showToast("已重新提取全板和谐色卡", icon: "paintpalette")
                            }
                        } label: {
                            Label("重新提取全板配色", systemImage: "paintpalette")
                                .font(.system(size: 11.5, weight: .medium))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                    }
                }

                // Quick Add from Library Search
                inspectorSection("从素材库快速拉图") {
                    VStack(alignment: .leading, spacing: 8) {
                        TextField("搜索标题、标签或域名…", text: $quickAddQuery)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 11.5))

                        if !quickAddResults.isEmpty {
                            LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)], spacing: 6) {
                                ForEach(quickAddResults.prefix(9)) { asset in
                                    Button {
                                        Task {
                                            await moodboards.appendAssets([asset])
                                            coordinator.showToast("已将「\(asset.title)」加入情绪板")
                                        }
                                    } label: {
                                        AssetThumbnailSurface(
                                            asset: asset,
                                            loader: library.thumbnailLoader,
                                            tier: .grid520,
                                            cornerRadius: 6
                                        )
                                        .frame(maxWidth: .infinity)
                                        .frame(height: 58)
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                                .strokeBorder(CharkleTheme.hairline(for: colorScheme), lineWidth: 0.5)
                                        )
                                    }
                                    .buttonStyle(CharkleTactileButtonStyle())
                                    .help("点击加入：\(asset.title)")
                                }
                            }
                        }
                    }
                }

                // Export Actions
                inspectorSection("导出与交付") {
                    VStack(spacing: 6) {
                        Button(action: onCopyBoardImage) {
                            Label("复制 2× 高清图（⌘V 到 Figma）", systemImage: "doc.on.clipboard")
                                .font(.system(size: 12, weight: .medium))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 8)
                                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                                .foregroundStyle(Color.accentColor)
                        }
                        .buttonStyle(.plain)

                        HStack(spacing: 6) {
                            Button {
                                onSaveBoardImage(.png)
                            } label: {
                                Text("保存 PNG")
                                    .font(.system(size: 11.5, weight: .medium))
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 6)
                                    .background(CharkleTheme.surfaceElevated(for: colorScheme), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                                            .strokeBorder(CharkleTheme.hairline(for: colorScheme), lineWidth: 0.75)
                                    )
                            }
                            .buttonStyle(CharkleTactileButtonStyle())

                            Button {
                                onSaveBoardImage(.jpeg)
                            } label: {
                                Text("保存 JPG")
                                    .font(.system(size: 11.5, weight: .medium))
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 6)
                                    .background(CharkleTheme.surfaceElevated(for: colorScheme), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                                            .strokeBorder(CharkleTheme.hairline(for: colorScheme), lineWidth: 0.75)
                                    )
                            }
                            .buttonStyle(CharkleTactileButtonStyle())
                        }
                    }
                }
            }
            .padding(14)
        }
        .onAppear {
            boardTitleDraft = board.title
            boardSubtitleDraft = board.subtitle
        }
        .onChange(of: board.id) { _, _ in
            boardTitleDraft = board.title
            boardSubtitleDraft = board.subtitle
        }
    }

    private var emptyInspectorPlaceholder: some View {
        VStack(spacing: 10) {
            Spacer()
            CharkleIcon("quicklook", style: .layered, size: 42, color: .secondary.opacity(0.5))
            Text("选择素材查看详情")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
            Text("单击卡片检视色板与元数据\n框选多张可一键生成情绪板")
                .font(.system(size: 11.5))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .padding(24)
    }

    // MARK: - Helpers

    private func inspectorSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            content()
        }
    }

    private func specRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.system(size: 11, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(.primary.opacity(0.88))
        }
    }

    private func folderName(for folderID: UUID?) -> String {
        guard let folderID else { return "收件箱" }
        return library.folders.first(where: { $0.id == folderID })?.name ?? "文件夹"
    }

    private func commitSingleAssetTitle(_ asset: AssetRecord) {
        let trimmed = titleDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != asset.title else { return }
        Task {
            await library.applyPatch(AssetBatchPatch(assetIDs: [asset.id], title: trimmed))
        }
    }

    private func commitBoardHeader(_ board: MoodboardDocument) {
        var next = board
        let trimmed = boardTitleDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { next.title = trimmed }
        next.subtitle = boardSubtitleDraft
        moodboards.commitMutation(next)
    }

    private func quickAddFilteredAssets(excluding excluded: Set<UUID>) -> [AssetRecord] {
        let q = quickAddQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return library.allAssetsByID.values
            .filter { asset in
                guard !asset.isTrashed, !excluded.contains(asset.id) else { return false }
                if q.isEmpty { return true }
                let hay = ([asset.title, asset.sourceDomain ?? ""] + asset.tags).joined(separator: " ").lowercased()
                return hay.contains(q)
            }
            .sorted { $0.createdAt > $1.createdAt }
    }
}
