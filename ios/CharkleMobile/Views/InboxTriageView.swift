import CharkleCore
import SwiftUI

/// Fast mobile Inbox triage: switch between focused 1-tap card filing (with automatic folder suggestion)
/// and full waterfall overview.
struct InboxTriageView: View {
    enum Mode: String, CaseIterable {
        case triage = "逐张归档"
        case grid = "瀑布流"
    }

    @Bindable var store: MobileAppStore
    let zoomNamespace: Namespace.ID
    let onOpenAsset: (AssetRecord, PreviewZoomOrigin) -> Void
    let onFindSimilar: (AssetRecord, PreviewZoomOrigin) -> Void
    let onOpenCapture: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var mode: Mode = .triage
    @State private var currentIndex: Int = 0
    @State private var previewImage: UIImage?
    @State private var suggestion: FolderSuggestion?
    @State private var isFolderPickerPresented: Bool = false

    private var inboxAssets: [AssetRecord] {
        store.inboxAssets
    }

    private var activeAsset: AssetRecord? {
        guard !inboxAssets.isEmpty else { return nil }
        let safeIdx = min(currentIndex, inboxAssets.count - 1)
        return inboxAssets[safeIdx]
    }

    var body: some View {
        ZStack {
            MobileTheme.galleryGround(for: colorScheme)
                .ignoresSafeArea()

            if inboxAssets.isEmpty && store.hasCompletedInitialLoad && !store.isLoadingLibrary {
                MobileEmptyStateView(
                    kind: .inboxZero,
                    title: "收件箱已清空",
                    subtitle: "新采集或从系统分享面板存入的素材会先出现在这里，等待一键归档。",
                    primaryActionTitle: "采集新素材",
                    primaryAction: onOpenCapture
                )
            } else {
                VStack(spacing: 0) {
                    HStack {
                        Picker("收件箱模式", selection: $mode) {
                            ForEach(Mode.allCases, id: \.self) { m in
                                Text(m.rawValue).tag(m)
                            }
                        }
                        .pickerStyle(.segmented)
                        .frame(maxWidth: 220)

                        Spacer()

                        Text("待整理 \(inboxAssets.count) 项")
                            .font(.system(size: 12.5, weight: .semibold).monospacedDigit())
                            .foregroundStyle(MobileTheme.secondaryInk(for: colorScheme))
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)

                    if mode == .grid {
                        MasonryGalleryView(
                            store: store,
                            assetsOverride: store.inboxAssets,
                            isCompact: horizontalSizeClass != .regular,
                            showPhotosFloatingHeader: false,
                            zoomNamespace: zoomNamespace,
                            zoomOrigin: .inboxGrid,
                            onOpenAsset: { onOpenAsset($0, .inboxGrid) },
                            onFindSimilar: { onFindSimilar($0, .inboxGrid) },
                            onOpenCapture: onOpenCapture,
                            onOpenSyncSettings: {},
                            onOpenFolders: nil
                        )
                    } else if let asset = activeAsset {
                        triageDeck(asset)
                    }
                }
            }
        }
        .task(id: activeAsset?.id) {
            guard let asset = activeAsset else {
                previewImage = nil
                suggestion = nil
                return
            }
            if let preview = await store.thumbnails.loadImage(for: asset.id, tier: .preview1400) {
                previewImage = preview
            } else {
                previewImage = await store.thumbnails.loadImage(for: asset.id, tier: .grid520)
            }
            suggestion = try? await store.engine.suggestFolder(for: asset.id)
        }
    }

    private func triageDeck(_ asset: AssetRecord) -> some View {
        ScrollView {
            VStack(spacing: 16) {
                // Hero card
                Button {
                    onOpenAsset(asset, .inboxTriage)
                } label: {
                    ZStack(alignment: .bottomLeading) {
                        Group {
                            if let previewImage {
                                Image(uiImage: previewImage)
                                    .resizable()
                                    .scaledToFit()
                            } else {
                                Rectangle()
                                    .fill(MobileTheme.surfaceSubtle(for: colorScheme))
                                    .overlay(ProgressView())
                            }
                        }
                        .frame(maxWidth: 560)
                        .frame(minHeight: 240, maxHeight: 420)
                        .frame(maxWidth: .infinity)
                        .background(MobileTheme.surfaceElevated(for: colorScheme))

                        LinearGradient(
                            colors: [.clear, .black.opacity(0.62)],
                            startPoint: .center,
                            endPoint: .bottom
                        )
                        .frame(height: 84)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(asset.title)
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(.white)
                                .lineLimit(1)
                            Text("\(asset.displayTypeLabel) · \(asset.pixelWidth) × \(asset.pixelHeight)")
                                .font(.system(size: 11.5).monospacedDigit())
                                .foregroundStyle(.white.opacity(0.82))
                        }
                        .padding(14)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(MobileTheme.hairline(for: colorScheme), lineWidth: 0.75)
                    )
                }
                .buttonStyle(MobileTactileButtonStyle())
                .matchedTransitionSource(
                    id: PreviewZoomSourceID(origin: .inboxTriage, assetID: asset.id),
                    in: zoomNamespace
                ) { configuration in
                    configuration
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                }

                // Smart folder suggestion CTA
                if let suggestion {
                    Button {
                        fileAsset(asset, to: suggestion.folderID, folderName: suggestion.folderName)
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "sparkles")
                                .foregroundStyle(MobileTheme.accent(for: colorScheme))
                            VStack(alignment: .leading, spacing: 2) {
                                Text("推荐归档到「\(suggestion.folderName)」")
                                    .font(.system(size: 13.5, weight: .semibold))
                                    .foregroundStyle(.primary)
                                Text(suggestion.reason)
                                    .font(.system(size: 11.5))
                                    .foregroundStyle(MobileTheme.secondaryInk(for: colorScheme))
                                    .lineLimit(1)
                            }
                            Spacer()
                            Text("归档")
                                .font(.system(size: 12.5, weight: .semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(MobileTheme.accentButtonFill(for: colorScheme), in: Capsule())
                        }
                        .padding(12)
                        .background(
                            MobileTheme.accentSoft(for: colorScheme),
                            in: RoundedRectangle(cornerRadius: MobileTheme.Radius.cardOuter, style: .continuous)
                        )
                    }
                    .buttonStyle(MobileTactileButtonStyle())
                }

                // 1-tap root folders + hierarchical picker for nested subfolders
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("一键分进文件夹")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(MobileTheme.secondaryInk(for: colorScheme))
                        Spacer()
                        if !store.folderTree.isEmpty {
                            Button {
                                MobileHaptics.light()
                                isFolderPickerPresented = true
                            } label: {
                                Label("层级目录", systemImage: "list.bullet.indent")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(MobileTheme.accent(for: colorScheme))
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    if store.folderTree.isEmpty {
                        Text("还没有文件夹，先在侧边栏新建文件夹即可快速归档。")
                            .font(.system(size: 13))
                            .foregroundStyle(MobileTheme.tertiaryInk(for: colorScheme))
                    } else {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 118), spacing: 8)], spacing: 8) {
                            ForEach(store.folderTree) { node in
                                Button {
                                    fileAsset(asset, to: node.folder.id, folderName: node.folder.name)
                                } label: {
                                    HStack(spacing: 6) {
                                        Circle()
                                            .fill(node.folder.colorHex.map { Color(charkleHex: $0) } ?? MobileTheme.accent(for: colorScheme))
                                            .frame(width: 8, height: 8)
                                        Text(node.folder.name)
                                            .font(.system(size: 13, weight: .medium))
                                            .foregroundStyle(.primary)
                                            .lineLimit(1)
                                        Spacer(minLength: 0)
                                        if node.hasChildren {
                                            Text("+\(node.children.count)")
                                                .font(.system(size: 10, weight: .semibold).monospacedDigit())
                                                .foregroundStyle(MobileTheme.tertiaryInk(for: colorScheme))
                                        }
                                    }
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 10)
                                    .background(
                                        MobileTheme.surfaceElevated(for: colorScheme),
                                        in: RoundedRectangle(cornerRadius: MobileTheme.Radius.chip + 2, style: .continuous)
                                    )
                                    .overlay(
                                        RoundedRectangle(cornerRadius: MobileTheme.Radius.chip + 2, style: .continuous)
                                            .strokeBorder(MobileTheme.hairline(for: colorScheme), lineWidth: 0.75)
                                    )
                                }
                                .buttonStyle(MobileTactileButtonStyle())
                            }
                        }
                    }
                }
                .sheet(isPresented: $isFolderPickerPresented) {
                    NavigationStack {
                        HierarchicalFolderPickerSheet(
                            title: "归档到文件夹",
                            folderTree: store.folderTree,
                            currentFolderID: nil,
                            allowInbox: false,
                            onPick: { folderID, folderName in
                                isFolderPickerPresented = false
                                if let folderID {
                                    fileAsset(asset, to: folderID, folderName: folderName)
                                }
                            }
                        )
                    }
                    .presentationDetents([.medium, .large])
                }

                // Quick actions row
                HStack(spacing: 12) {
                    Button(role: .destructive) {
                        Task {
                            await store.patchAssets(
                                AssetBatchPatch(assetIDs: [asset.id], isTrashed: true),
                                successToast: "已移入回收站"
                            )
                            advanceIndex()
                        }
                    } label: {
                        Label("移至回收站", systemImage: "trash")
                            .font(.system(size: 13.5, weight: .medium))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 11)
                            .background(MobileTheme.surfaceElevated(for: colorScheme), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    .buttonStyle(MobileTactileButtonStyle())

                    Button {
                        advanceIndex()
                    } label: {
                        Label("跳过下一张", systemImage: "arrow.right")
                            .font(.system(size: 13.5, weight: .medium))
                            .foregroundStyle(.primary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 11)
                            .background(MobileTheme.surfaceElevated(for: colorScheme), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    .buttonStyle(MobileTactileButtonStyle())
                }
            }
            .padding(16)
            .frame(maxWidth: 640)
            .frame(maxWidth: .infinity)
        }
    }

    private func fileAsset(_ asset: AssetRecord, to folderID: UUID, folderName: String) {
        MobileHaptics.success()
        Task {
            await store.patchAssets(
                AssetBatchPatch(assetIDs: [asset.id], folderAssignment: .folder(folderID)),
                successToast: "已归档到「\(folderName)」"
            )
            if currentIndex >= store.inboxAssets.count {
                currentIndex = max(0, store.inboxAssets.count - 1)
            }
        }
    }

    private func advanceIndex() {
        guard !inboxAssets.isEmpty else {
            currentIndex = 0
            return
        }
        currentIndex = (currentIndex + 1) % inboxAssets.count
    }
}
