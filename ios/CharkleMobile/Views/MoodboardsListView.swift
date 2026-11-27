import CharkleCore
import SwiftUI

/// Moodboards Home screen synced 1:1 with macOS & Windows `/.charkle/boards/<UUID>.json`.
struct MoodboardsListView: View {
    @Bindable var store: MobileAppStore
    let onOpenBoard: (UUID) -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    @State private var isCreateSheetPresented = false
    @State private var boardToDelete: MoodboardSummary?
    @State private var boardToRename: MoodboardSummary?
    @State private var renameDraft: String = ""

    private var gridColumns: [GridItem] {
        if horizontalSizeClass == .regular {
            return [GridItem(.adaptive(minimum: 260, maximum: 340), spacing: 14)]
        }
        return [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]
    }

    var body: some View {
        ZStack {
            MobileTheme.galleryGround(for: colorScheme)
                .ignoresSafeArea()

            if store.boards.isEmpty && !store.isLoadingLibrary {
                MobileEmptyStateView(
                    kind: .emptyLibrary,
                    title: "还没有情绪板",
                    subtitle: "把零散灵感拼成视觉方案，支持自由画布、自动排版、手绘批注，并与 Mac / Windows 双向同步。",
                    primaryActionTitle: "新建情绪板",
                    primaryAction: { isCreateSheetPresented = true }
                )
            } else {
                ScrollView {
                    LazyVGrid(columns: gridColumns, spacing: 14) {
                        ForEach(store.boards) { board in
                            MoodboardSummaryCard(
                                board: board,
                                thumbnails: store.thumbnails,
                                onTap: { onOpenBoard(board.id) }
                            )
                            .contextMenu {
                                Button("打开情绪板", systemImage: "rectangle.3.group") {
                                    onOpenBoard(board.id)
                                }
                                Button("重命名", systemImage: "pencil") {
                                    boardToRename = board
                                    renameDraft = board.title
                                }
                                Button(
                                    board.pinnedOffline ? "取消离线置顶" : "置顶离线",
                                    systemImage: board.pinnedOffline ? "pin.slash" : "pin"
                                ) {
                                    Task { await store.setBoardPinnedOffline(id: board.id, pinned: !board.pinnedOffline) }
                                }
                                Divider()
                                Button("删除情绪板", systemImage: "trash", role: .destructive) {
                                    boardToDelete = board
                                }
                            }
                        }
                    }
                    .padding(14)
                }
                .refreshable {
                    if store.hasConnectedCloudBackend {
                        await store.syncNow(quiet: false)
                    } else {
                        await store.reloadAll()
                    }
                }
            }
        }
        .navigationTitle("情绪板")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    isCreateSheetPresented = true
                } label: {
                    Image(systemName: "plus")
                        .fontWeight(.semibold)
                }
            }
        }
        .sheet(isPresented: $isCreateSheetPresented) {
            NavigationStack {
                CreateMoodboardSheet(store: store) { createdID in
                    isCreateSheetPresented = false
                    onOpenBoard(createdID)
                }
            }
            .presentationDetents([.medium, .large])
        }
        .alert("重命名情绪板", isPresented: Binding(
            get: { boardToRename != nil },
            set: { if !$0 { boardToRename = nil } }
        )) {
            TextField("情绪板名称", text: $renameDraft)
            Button("取消", role: .cancel) { boardToRename = nil }
            Button("保存") {
                guard let target = boardToRename else { return }
                let trimmed = renameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                boardToRename = nil
                guard !trimmed.isEmpty else { return }
                Task {
                    if var doc = await store.fetchBoardDocument(id: target.id) {
                        doc.title = trimmed
                        _ = await store.saveBoardDocument(doc, quiet: false)
                    }
                }
            }
        }
        .confirmationDialog(
            "删除情绪板「\(boardToDelete?.title ?? "")」？",
            isPresented: Binding(
                get: { boardToDelete != nil },
                set: { if !$0 { boardToDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("删除情绪板", role: .destructive) {
                if let target = boardToDelete {
                    boardToDelete = nil
                    Task { await store.deleteBoard(id: target.id) }
                }
            }
            Button("取消", role: .cancel) { boardToDelete = nil }
        } message: {
            Text("只会删除情绪板本身，不会删除素材库中的原图。")
        }
    }
}

private struct MoodboardSummaryCard: View {
    let board: MoodboardSummary
    let thumbnails: MobileThumbnailCache
    let onTap: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 0) {
                // 3-tile editorial collage cover
                ZStack(alignment: .topTrailing) {
                    collageCover
                        .frame(height: 146)
                        .clipped()

                    if board.pinnedOffline {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(6)
                            .background(.black.opacity(0.55), in: Circle())
                            .padding(8)
                    }
                }

                // Auto-extracted board color strip
                if !board.paletteHexes.isEmpty {
                    HStack(spacing: 0) {
                        ForEach(board.paletteHexes.prefix(6), id: \.self) { hex in
                            Color(charkleHex: hex)
                        }
                    }
                    .frame(height: 5)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(board.title)
                        .font(.system(size: 14.5, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    HStack(spacing: 6) {
                        Text("\(board.itemCount) 项")
                            .font(.system(size: 11.5).monospacedDigit())
                        Text("·")
                        Text(board.mode.isAutoEditorial ? "自动排版" : "自由画布")
                            .font(.system(size: 11.5))
                        Spacer(minLength: 2)
                        Text(MobileFormatters.relativeDate(board.updatedAt))
                            .font(.system(size: 11))
                    }
                    .foregroundStyle(MobileTheme.secondaryInk(for: colorScheme))
                }
                .padding(11)
            }
            .background(
                MobileTheme.surfaceElevated(for: colorScheme),
                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(MobileTheme.hairline(for: colorScheme), lineWidth: 0.75)
            )
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(MobileTactileButtonStyle())
    }

    @ViewBuilder
    private var collageCover: some View {
        let ids = Array(board.previewAssetIDs.prefix(3))
        if ids.isEmpty {
            MobileTheme.surfaceSubtle(for: colorScheme)
                .overlay {
                    Image(systemName: "rectangle.3.group")
                        .font(.system(size: 26, weight: .light))
                        .foregroundStyle(MobileTheme.tertiaryInk(for: colorScheme))
                }
        } else if ids.count == 1 {
            BoardPreviewImageCell(assetID: ids[0], thumbnails: thumbnails)
        } else {
            HStack(spacing: 2) {
                BoardPreviewImageCell(assetID: ids[0], thumbnails: thumbnails)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                VStack(spacing: 2) {
                    BoardPreviewImageCell(assetID: ids[1], thumbnails: thumbnails)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    if ids.count >= 3 {
                        BoardPreviewImageCell(assetID: ids[2], thumbnails: thumbnails)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

private struct BoardPreviewImageCell: View {
    let assetID: UUID
    let thumbnails: MobileThumbnailCache
    @State private var image: UIImage?

    var body: some View {
        Color(.secondarySystemFill)
            .overlay {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                }
            }
            .clipped()
            .task(id: "\(assetID.uuidString)-\(thumbnails.revision)") {
                if let hit = thumbnails.cachedImage(for: assetID, tier: .grid520) {
                    image = hit
                    return
                }
                image = await thumbnails.loadImage(for: assetID, tier: .grid520)
            }
    }
}

struct CreateMoodboardSheet: View {
    enum CreationMode: String, CaseIterable {
        case blank = "空白画板"
        case smart = "智能策展"
    }

    @Bindable var store: MobileAppStore
    let onCreated: (UUID) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var creationMode: CreationMode = .blank
    @State private var titleText = ""
    @State private var promptText = ""
    @State private var useFreeform = true
    @State private var isCreating = false

    var body: some View {
        Form {
            Section {
                Picker("创建方式", selection: $creationMode) {
                    ForEach(CreationMode.allCases, id: \.self) { m in
                        Text(m.rawValue).tag(m)
                    }
                }
                .pickerStyle(.segmented)
            }

            if creationMode == .blank {
                Section("画板信息") {
                    TextField("情绪板名称（如：夏日泳池配色参考）", text: $titleText)
                    Picker("初始布局", selection: $useFreeform) {
                        Text("自由画布").tag(true)
                        Text("自动排版").tag(false)
                    }
                    .pickerStyle(.segmented)
                }
            } else {
                Section {
                    TextField("输入灵感主题或关键词（如：海边夏日、蓝白插画、胶片光影…）", text: $promptText, axis: .vertical)
                        .lineLimit(2...4)
                } header: {
                    Text("策展主题")
                } footer: {
                    Text("自动从你的素材库挑选色彩与视觉方向契合的作品并完成排版，生成后可自由微调。")
                }
            }
        }
        .navigationTitle("新建情绪板")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("取消") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button {
                    Task { await submit() }
                } label: {
                    if isCreating {
                        ProgressView()
                    } else {
                        Text("创建").fontWeight(.semibold)
                    }
                }
                .disabled(isCreating)
            }
        }
    }

    private func submit() async {
        isCreating = true
        defer { isCreating = false }
        let created: MoodboardDocument?
        if creationMode == .blank {
            created = await store.createMoodboard(
                title: titleText.isEmpty ? "新建情绪板" : titleText,
                useFreeform: useFreeform
            )
        } else {
            created = await store.proposeMoodboard(prompt: promptText)
        }
        if let created {
            onCreated(created.id)
        }
    }
}
