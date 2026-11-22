import CharkleCanvas
import CharkleCore
import SwiftUI
import UniformTypeIdentifiers

/// Refined translucent macOS Sidebar with Kubai Tip 015 single travelling selection indicator
/// (`matchedGeometryEffect`), live Inbox badge, Moodboards section, Google Drive Folders
/// (drag-drop targets + inline creator), and Tags.
public struct SidebarView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public let coordinator: AppCoordinatorStore
    public let library: LibraryStore
    public let moodboards: MoodboardStore
    public let onSelectDestination: (SidebarDestination) -> Void
    public let onDropAssetsOntoFolder: ([UUID], UUID?) -> Void
    public let onDropExternalOntoFolder: ([CaptureInput], UUID?) -> Void
    public let onDropAssetsOntoBoard: ([UUID], UUID) -> Void
    public let onDropExternalOntoBoard: ([CaptureInput], UUID) -> Void

    @Namespace private var selectionIndicatorNamespace

    @State private var isCreatingFolder: Bool = false
    @State private var newFolderName: String = ""
    @State private var renamingFolderID: UUID?
    @State private var renameDraft: String = ""
    @State private var dropTargetedFolderID: UUID?
    @State private var dropTargetedInbox: Bool = false
    @State private var dropTargetedBoardID: UUID?

    public init(
        coordinator: AppCoordinatorStore,
        library: LibraryStore,
        moodboards: MoodboardStore,
        onSelectDestination: @escaping (SidebarDestination) -> Void,
        onDropAssetsOntoFolder: @escaping ([UUID], UUID?) -> Void,
        onDropExternalOntoFolder: @escaping ([CaptureInput], UUID?) -> Void,
        onDropAssetsOntoBoard: @escaping ([UUID], UUID) -> Void,
        onDropExternalOntoBoard: @escaping ([CaptureInput], UUID) -> Void
    ) {
        self.coordinator = coordinator
        self.library = library
        self.moodboards = moodboards
        self.onSelectDestination = onSelectDestination
        self.onDropAssetsOntoFolder = onDropAssetsOntoFolder
        self.onDropExternalOntoFolder = onDropExternalOntoFolder
        self.onDropAssetsOntoBoard = onDropAssetsOntoBoard
        self.onDropExternalOntoBoard = onDropExternalOntoBoard
    }

    public var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 18) {
                // Brand compact header
                HStack(spacing: 8) {
                    CharkleIcon("moodboard", style: .layered, size: 22)
                    Text("Charkle")
                        .font(.system(size: 14, weight: .semibold))
                        .tracking(-0.2)
                    Spacer()
                    Button {
                        coordinator.isJumpAnywherePresented = true
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "magnifyingglass")
                                .font(.system(size: 10, weight: .semibold))
                            Text("⌘J")
                                .font(.system(size: 10, weight: .medium, design: .monospaced))
                        }
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .help("快速跳转 (⌘J)")
                }
                .padding(.horizontal, 12)
                .padding(.top, 12)

                // Section 1: Library
                VStack(alignment: .leading, spacing: 2) {
                    sectionHeader("素材库")
                    sidebarRow(
                        destination: .allItems,
                        iconName: "library",
                        title: "全部素材",
                        badgeCount: library.allAssetsByID.values.filter { !$0.isTrashed }.count
                    )
                    sidebarRow(
                        destination: .inbox,
                        iconName: "inbox",
                        title: "收件箱",
                        badgeCount: library.inboxCount,
                        emphasizeBadge: library.inboxCount > 0,
                        isDropHighlighted: dropTargetedInbox
                    )
                    .onDrop(of: [.plainText, .fileURL, .url, .image], isTargeted: $dropTargetedInbox) { providers in
                        handleDrop(providers: providers, folderID: nil, boardID: nil)
                    }
                    sidebarRow(
                        destination: .untagged,
                        iconName: "untagged",
                        title: "未打标签",
                        badgeCount: library.allAssetsByID.values.filter { !$0.isTrashed && $0.tags.isEmpty }.count
                    )
                    sidebarRow(
                        destination: .recent,
                        iconName: "recent",
                        title: "最近添加"
                    )
                    sidebarRow(
                        destination: .trash,
                        iconName: "trash",
                        title: "废纸篓"
                    )
                }

                // Section 2: Moodboards
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        sectionHeader("情绪板")
                        Spacer()
                        Button {
                            coordinator.presentMoodboardGenerator(entry: .prompt)
                        } label: {
                            HStack(spacing: 3) {
                                Image(systemName: "plus")
                                    .font(.system(size: 10, weight: .bold))
                                Text("快速生成")
                                    .font(.system(size: 10.5, weight: .medium))
                            }
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Color.primary.opacity(0.06), in: Capsule(style: .continuous))
                        }
                        .buttonStyle(CharkleTactileButtonStyle())
                        .help("4 入口 10 秒快速生成情绪板")
                    }
                    .padding(.trailing, 10)

                    sidebarRow(
                        destination: .moodboardsHome,
                        iconName: "moodboard",
                        title: "所有情绪板",
                        badgeCount: moodboards.boards.count
                    )

                    ForEach(moodboards.boards) { board in
                        let isActiveTarget = coordinator.activeMoodboardID == board.id
                        sidebarRow(
                            destination: .moodboard(board.id),
                            iconName: "sparkle-board",
                            title: board.title,
                            badgeCount: board.itemCount,
                            isActiveMoodboard: isActiveTarget,
                            isPinnedOffline: board.pinnedOffline,
                            isDropHighlighted: dropTargetedBoardID == board.id
                        )
                        .onDrop(
                            of: [.plainText, .fileURL, .url, .image],
                            isTargeted: Binding(
                                get: { dropTargetedBoardID == board.id },
                                set: { targeted in
                                    dropTargetedBoardID = targeted ? board.id : (dropTargetedBoardID == board.id ? nil : dropTargetedBoardID)
                                }
                            )
                        ) { providers in
                            handleDrop(providers: providers, folderID: nil, boardID: board.id)
                        }
                        .contextMenu {
                            Button(isActiveTarget ? "已是当前活跃情绪板" : "设为当前活跃情绪板（刘海直投目标）") {
                                coordinator.activeMoodboardID = board.id
                                coordinator.showToast("已锁定「\(board.title)」为刘海活跃情绪板", icon: "checkmark.circle.fill")
                            }
                            Button(board.pinnedOffline ? "取消钉选离线" : "钉选整板离线可用") {
                                Task { await moodboards.togglePinnedOffline(id: board.id) }
                            }
                            Divider()
                            Button("删除情绪板", role: .destructive) {
                                Task {
                                    await moodboards.deleteBoard(id: board.id)
                                    if coordinator.selectedDestination == .moodboard(board.id) {
                                        onSelectDestination(.moodboardsHome)
                                    }
                                    if coordinator.activeMoodboardID == board.id {
                                        coordinator.activeMoodboardID = moodboards.boards.first?.id
                                    }
                                }
                            }
                        }
                    }
                }

                // Section 3: Google Drive Folders
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        sectionHeader("文件夹")
                        Spacer()
                        Button {
                            withAnimation(CharkleMotion.accessible(CharkleMotion.enterSm, reduced: reduceMotion)) {
                                isCreatingFolder.toggle()
                                newFolderName = ""
                            }
                        } label: {
                            Image(systemName: "plus")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .frame(width: 22, height: 22)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("新建文件夹")
                    }
                    .padding(.trailing, 10)

                    if isCreatingFolder {
                        HStack(spacing: 6) {
                            TextField("文件夹名称", text: $newFolderName)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 12))
                                .onSubmit { commitNewFolder() }
                            Button("创建") { commitNewFolder() }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 4)
                        .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
                    }

                    if library.folders.isEmpty {
                        Text("暂无文件夹，点击右上角 + 创建")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 6)
                    } else {
                        ForEach(library.folders) { folder in
                            if renamingFolderID == folder.id {
                                HStack(spacing: 6) {
                                    TextField("重命名", text: $renameDraft)
                                        .textFieldStyle(.roundedBorder)
                                        .font(.system(size: 12))
                                        .onSubmit {
                                            let name = renameDraft
                                            renamingFolderID = nil
                                            Task { await library.renameFolder(id: folder.id, newName: name) }
                                        }
                                    Button("好") {
                                        let name = renameDraft
                                        renamingFolderID = nil
                                        Task { await library.renameFolder(id: folder.id, newName: name) }
                                    }
                                    .controlSize(.small)
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 3)
                            } else {
                                sidebarRow(
                                    destination: .folder(folder.id),
                                    iconName: "folder",
                                    title: folder.name,
                                    badgeCount: folder.assetCount,
                                    isDropHighlighted: dropTargetedFolderID == folder.id
                                )
                                .onDrop(
                                    of: [.plainText, .fileURL, .url, .image],
                                    isTargeted: Binding(
                                        get: { dropTargetedFolderID == folder.id },
                                        set: { targeted in
                                            dropTargetedFolderID = targeted ? folder.id : (dropTargetedFolderID == folder.id ? nil : dropTargetedFolderID)
                                        }
                                    )
                                ) { providers in
                                    handleDrop(providers: providers, folderID: folder.id, boardID: nil)
                                }
                                .contextMenu {
                                    Button("重命名…") {
                                        renameDraft = folder.name
                                        renamingFolderID = folder.id
                                    }
                                    Divider()
                                    Button("删除文件夹（素材退回收件箱）", role: .destructive) {
                                        Task {
                                            await library.deleteFolder(id: folder.id)
                                            if coordinator.selectedDestination == .folder(folder.id) {
                                                onSelectDestination(.allItems)
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }

                // Section 4: Tags
                if !library.tagCounts.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        sectionHeader("标签")
                        ForEach(library.tagCounts.prefix(18)) { tag in
                            sidebarRow(
                                destination: .tag(tag.name),
                                iconName: "tag",
                                title: "#\(tag.name)",
                                badgeCount: tag.count
                            )
                        }
                    }
                }
            }
            .padding(.bottom, 20)
        }
        .scrollIndicators(.hidden)
    }
}

/// Native macOS translucent sidebar surface (`NSVisualEffectView(.sidebar)`) without `NavigationSplitView`'s
/// hidden-titlebar scroll pocket hit-testing offset.
public struct CharkleSidebarMaterialBackground: NSViewRepresentable {
    public init() {}

    public func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }

    public func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = .sidebar
    }
}

extension SidebarView {

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary.opacity(0.85))
            .padding(.horizontal, 14)
            .padding(.bottom, 3)
    }

    private func sidebarRow(
        destination: SidebarDestination,
        iconName: String,
        title: String,
        badgeCount: Int? = nil,
        emphasizeBadge: Bool = false,
        isActiveMoodboard: Bool = false,
        isPinnedOffline: Bool = false,
        isDropHighlighted: Bool = false
    ) -> some View {
        let isSelected = coordinator.selectedDestination == destination
        let rowShape = RoundedRectangle(cornerRadius: 8, style: .continuous)

        return Button {
            withAnimation(CharkleMotion.accessible(CharkleMotion.settleStrong, reduced: reduceMotion)) {
                onSelectDestination(destination)
            }
        } label: {
            HStack(spacing: 8) {
                CharkleIcon(
                    iconName,
                    style: .duotone,
                    size: 15,
                    color: isSelected ? Color.accentColor : .secondary
                )

                Text(title)
                    .font(.system(size: 12.5, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? Color.primary : Color.primary.opacity(0.86))
                    .lineLimit(1)

                Spacer(minLength: 4)

                if isActiveMoodboard {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 6, height: 6)
                        .help("当前活跃情绪板（刘海直投目标）")
                }

                if isPinnedOffline {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .help("已钉选离线可用")
                }

                if let count = badgeCount, count > 0 {
                    Text("\(count)")
                        .font(.system(size: 10.5, weight: emphasizeBadge ? .semibold : .medium, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(emphasizeBadge ? .white : .secondary)
                        .padding(.horizontal, emphasizeBadge ? 6 : 4)
                        .padding(.vertical, emphasizeBadge ? 2 : 1)
                        .background {
                            if emphasizeBadge {
                                Capsule(style: .continuous).fill(Color.accentColor)
                            }
                        }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background {
                if isSelected {
                    rowShape
                        .fill(Color.primary.opacity(colorScheme == .dark ? 0.12 : 0.08))
                        .matchedGeometryEffect(id: "sidebar-selection-pill", in: selectionIndicatorNamespace)
                } else if isDropHighlighted {
                    rowShape
                        .fill(Color.accentColor.opacity(0.16))
                        .overlay(rowShape.strokeBorder(Color.accentColor, lineWidth: 1.5))
                }
            }
            .contentShape(rowShape)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
    }

    private func commitNewFolder() {
        let trimmed = newFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        newFolderName = ""
        isCreatingFolder = false
        Task {
            if let created = await library.createFolder(name: trimmed) {
                coordinator.showToast("已创建文件夹「\(created.name)」", icon: "folder.badge.plus")
            }
        }
    }

    private func handleDrop(providers: [NSItemProvider], folderID: UUID?, boardID: UUID?) -> Bool {
        guard !providers.isEmpty else { return false }
        Task {
            var internalIDs: [UUID] = []
            var externalInputs: [CaptureInput] = []

            for provider in providers {
                if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier),
                   let str = await loadText(provider) {
                    if let ids = CharkleDragIdentifiers.decodeAssetIDs(from: str) {
                        internalIDs.append(contentsOf: ids)
                        continue
                    }
                }
                if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier),
                   let url = await loadURL(provider, type: .fileURL) {
                    externalInputs.append(.fileURL(url))
                    continue
                }
                if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier),
                   let url = await loadURL(provider, type: .url) {
                    if url.isFileURL { externalInputs.append(.fileURL(url)) }
                    else if url.scheme == "http" || url.scheme == "https" {
                        externalInputs.append(.webURL(url, title: nil, notes: nil))
                    }
                    continue
                }
                if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier),
                   let data = await loadData(provider, type: .image) {
                    externalInputs.append(.imageData(data, suggestedName: "SidebarDrop-\(Int(Date().timeIntervalSince1970)).png", sourceURL: nil))
                }
            }

            if let boardID {
                if !internalIDs.isEmpty { onDropAssetsOntoBoard(internalIDs, boardID) }
                if !externalInputs.isEmpty { onDropExternalOntoBoard(externalInputs, boardID) }
            } else {
                if !internalIDs.isEmpty { onDropAssetsOntoFolder(internalIDs, folderID) }
                if !externalInputs.isEmpty { onDropExternalOntoFolder(externalInputs, folderID) }
            }
        }
        return true
    }

    private func loadText(_ provider: NSItemProvider) async -> String? {
        await withCheckedContinuation { cont in
            provider.loadItem(forTypeIdentifier: UTType.plainText.identifier, options: nil) { item, _ in
                if let s = item as? String { cont.resume(returning: s) }
                else if let d = item as? Data, let s = String(data: d, encoding: .utf8) { cont.resume(returning: s) }
                else { cont.resume(returning: nil) }
            }
        }
    }

    private func loadURL(_ provider: NSItemProvider, type: UTType) async -> URL? {
        await withCheckedContinuation { cont in
            provider.loadItem(forTypeIdentifier: type.identifier, options: nil) { item, _ in
                if let u = item as? URL { cont.resume(returning: u) }
                else if let d = item as? Data, let u = URL(dataRepresentation: d, relativeTo: nil) { cont.resume(returning: u) }
                else if let s = item as? String, let u = URL(string: s) { cont.resume(returning: u) }
                else { cont.resume(returning: nil) }
            }
        }
    }

    private func loadData(_ provider: NSItemProvider, type: UTType) async -> Data? {
        await withCheckedContinuation { cont in
            provider.loadDataRepresentation(forTypeIdentifier: type.identifier) { data, _ in
                cont.resume(returning: data)
            }
        }
    }
}
