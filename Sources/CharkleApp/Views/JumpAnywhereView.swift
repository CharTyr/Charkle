import CharkleCanvas
import CharkleCore
import SwiftUI

/// Spotlight-style Liquid Glass command palette (`⌘J`) searching Moodboards, Folders, Tags,
/// and Assets (zh/en/pinyin) with full keyboard navigation (`↑` / `↓` / `Return` / `Esc`).
public struct JumpAnywhereView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public let coordinator: AppCoordinatorStore
    public let library: LibraryStore
    public let onSelectMatch: (QuickJumpMatch) -> Void
    public let onTriggerQuickCommand: (QuickCommand) -> Void
    public let onClose: () -> Void

    public enum QuickCommand: String, CaseIterable, Identifiable, Sendable {
        case newMoodboard
        case openInbox
        case smartDeduplicate
        case toggleNotch
        case captureArea

        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .newMoodboard: "快速生成情绪板…"
            case .openInbox: "前往收件箱清理台"
            case .smartDeduplicate: "智能去重（全媒体，保留最高质量）… (⌘⇧D)"
            case .toggleNotch: "展开 / 收起刘海浮窗 (⌥⇧S)"
            case .captureArea: "交互式区域截图 (⌥⇧A)"
            }
        }

        public var icon: String {
            switch self {
            case .newMoodboard: "sparkle-board"
            case .openInbox: "inbox"
            case .smartDeduplicate: "library"
            case .toggleNotch: "notch"
            case .captureArea: "screenshot"
            }
        }
    }

    @State private var query: String = ""
    @State private var matches: [QuickJumpMatch] = []
    @State private var searchTask: Task<Void, Never>?
    @State private var selectedIndex: Int = 0
    @State private var didExecuteSelection: Bool = false
    @FocusState private var isSearchFocused: Bool

    public init(
        coordinator: AppCoordinatorStore,
        library: LibraryStore,
        onSelectMatch: @escaping (QuickJumpMatch) -> Void,
        onTriggerQuickCommand: @escaping (QuickCommand) -> Void,
        onClose: @escaping () -> Void
    ) {
        self.coordinator = coordinator
        self.library = library
        self.onSelectMatch = onSelectMatch
        self.onTriggerQuickCommand = onTriggerQuickCommand
        self.onClose = onClose
    }

    private var showingQuickCommands: Bool {
        query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && matches.isEmpty
    }

    private var totalSelectableCount: Int {
        showingQuickCommands ? QuickCommand.allCases.count : matches.count
    }

    public var body: some View {
        ZStack(alignment: .top) {
            CharkleModalBackdrop(onTap: onClose)

            VStack(spacing: 0) {
                // Search Input Header
                HStack(spacing: 10) {
                    CharkleIcon("search", style: .duotone, size: 17, color: .secondary)
                    TextField("快速跳转情绪板、文件夹、标签或素材（支持拼音）…", text: $query)
                        .textFieldStyle(.plain)
                        .font(CharkleTheme.text(.headline, weight: .regular))
                        .focused($isSearchFocused)
                        .onSubmit { executeSelectedRow() }

                    if !query.isEmpty {
                        Button {
                            query = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 13))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }

                    Text("ESC")
                        .font(CharkleTheme.text(.caption, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: CharkleTheme.Radius.xs, style: .continuous))
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)

                Divider()

                // Results List
                ScrollViewReader { scrollProxy in
                    ScrollView(.vertical) {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            if showingQuickCommands {
                                Text("快捷操作")
                                    .font(CharkleTheme.text(.caption, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 14)
                                    .padding(.top, 8)
                                    .padding(.bottom, 4)

                                ForEach(Array(QuickCommand.allCases.enumerated()), id: \.element.id) { idx, cmd in
                                    rowShell(isSelected: selectedIndex == idx) {
                                        CharkleIcon(cmd.icon, style: .duotone, size: 15, color: selectedIndex == idx ? Color.accentColor : .secondary)
                                        Text(cmd.title)
                                            .font(CharkleTheme.text(.body, weight: .medium))
                                        Spacer()
                                        Text("↵")
                                            .font(CharkleTheme.text(.caption, design: .monospaced))
                                            .foregroundStyle(.tertiary)
                                    }
                                    .id(idx)
                                    .onTapGesture {
                                        guard !didExecuteSelection else { return }
                                        didExecuteSelection = true
                                        onTriggerQuickCommand(cmd)
                                        onClose()
                                    }
                                }
                            } else if matches.isEmpty {
                                VStack(spacing: 6) {
                                    Text("未找到与「\(query)」匹配的内容")
                                        .font(CharkleTheme.text(.body, weight: .medium))
                                        .foregroundStyle(.secondary)
                                    Text("试试搜索文件夹名、情绪板标题、标签或拼音首字母")
                                        .font(CharkleTheme.text(.caption))
                                        .foregroundStyle(.tertiary)
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 32)
                            } else {
                                ForEach(Array(matches.enumerated()), id: \.element.id) { idx, match in
                                    rowShell(isSelected: selectedIndex == idx) {
                                        CharkleIcon(iconName(for: match.kind), style: .duotone, size: 15, color: selectedIndex == idx ? Color.accentColor : .secondary)
                                        VStack(alignment: .leading, spacing: 1) {
                                            Text(match.title)
                                                .font(CharkleTheme.text(.body, weight: .medium))
                                                .lineLimit(1)
                                            Text(match.subtitle)
                                                .font(CharkleTheme.text(.caption))
                                                .foregroundStyle(.secondary)
                                                .lineLimit(1)
                                        }
                                        Spacer()
                                        Text(kindLabel(for: match.kind))
                                            .font(CharkleTheme.text(.caption, weight: .medium))
                                            .foregroundStyle(.secondary)
                                            .padding(.horizontal, 7)
                                            .padding(.vertical, 2.5)
                                            .background(Color.primary.opacity(0.06), in: Capsule(style: .continuous))
                                    }
                                    .id(idx)
                                    .onTapGesture {
                                        guard !didExecuteSelection else { return }
                                        didExecuteSelection = true
                                        onSelectMatch(match)
                                        onClose()
                                    }
                                }
                            }
                        }
                        .padding(.vertical, 6)
                        .charkleCleanScrollbars(hidden: false)
                    }
                    .frame(maxHeight: 360)
                    .onChange(of: selectedIndex) { _, newIndex in
                        withAnimation(CharkleMotion.accessible(CharkleMotion.hoverPress, reduced: reduceMotion)) {
                            scrollProxy.scrollTo(newIndex, anchor: .center)
                        }
                    }
                }
            }
            .frame(width: 580)
            .charkleLiquidGlass(.regular, in: RoundedRectangle(cornerRadius: CharkleTheme.Radius.popoverOuter, style: .continuous))
            .padding(.top, 92)
        }
        .ignoresSafeArea(.all)
        .onAppear {
            didExecuteSelection = false
            DispatchQueue.main.async {
                isSearchFocused = true
            }
            runSearch()
        }
        .onChange(of: query) { _, _ in
            selectedIndex = 0
            runSearch()
        }
        .onDisappear {
            searchTask?.cancel()
            searchTask = nil
        }
        .onKeyPress(.escape) {
            onClose()
            return .handled
        }
        .onKeyPress(.upArrow) {
            if totalSelectableCount > 0 {
                selectedIndex = (selectedIndex - 1 + totalSelectableCount) % totalSelectableCount
            }
            return .handled
        }
        .onKeyPress(.downArrow) {
            if totalSelectableCount > 0 {
                selectedIndex = (selectedIndex + 1) % totalSelectableCount
            }
            return .handled
        }
        .onKeyPress(.return) {
            executeSelectedRow()
            return .handled
        }
    }

    private func rowShell<Content: View>(isSelected: Bool, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 10) {
            content()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            isSelected ? Color.accentColor.opacity(0.14) : Color.clear,
            in: RoundedRectangle(
                cornerRadius: CharkleTheme.Radius.concentricInner(
                    outer: CharkleTheme.Radius.popoverOuter,
                    padding: 6
                ),
                style: .continuous
            )
        )
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
    }

    private func runSearch() {
        searchTask?.cancel()
        searchTask = nil
        let currentQuery = query
        let trimmed = currentQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            matches = []
            selectedIndex = 0
            return
        }
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(75))
            guard !Task.isCancelled else { return }
            let results = await library.quickJump(query: trimmed, limit: 24)
            guard !Task.isCancelled else { return }
            if currentQuery == query {
                matches = results
                if selectedIndex >= max(1, totalSelectableCount) {
                    selectedIndex = 0
                }
            }
        }
    }

    private func executeSelectedRow() {
        guard !didExecuteSelection else { return }
        if showingQuickCommands {
            let commands = QuickCommand.allCases
            guard selectedIndex < commands.count else { return }
            didExecuteSelection = true
            onTriggerQuickCommand(commands[selectedIndex])
            onClose()
        } else {
            guard selectedIndex < matches.count else { return }
            didExecuteSelection = true
            onSelectMatch(matches[selectedIndex])
            onClose()
        }
    }

    private func iconName(for kind: QuickJumpKind) -> String {
        switch kind {
        case .moodboard: "sparkle-board"
        case .folder: "folder"
        case .tag: "tag"
        case .asset: "library"
        }
    }

    private func kindLabel(for kind: QuickJumpKind) -> String {
        switch kind {
        case .moodboard: "情绪板"
        case .folder: "文件夹"
        case .tag: "标签"
        case .asset: "素材"
        }
    }
}
