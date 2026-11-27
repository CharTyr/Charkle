import CharkleCanvas
import CharkleCore
import SwiftUI

/// Clean Gallery-First rule builder modal for creating or editing a Smart Folder
/// (matching tags, description/keywords, multiple specific colors, media kinds, and rating).
public struct SmartFolderEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    public let library: LibraryStore
    public let existing: SmartFolderRecord?
    public let onSave: (SmartFolderRecord) -> Void

    @State private var name: String
    @State private var matchMode: SmartFolderRule.MatchMode
    @State private var selectedTags: [String]
    @State private var customTagInput: String = ""
    @State private var descriptionQuery: String
    @State private var selectedColorHexes: [String]
    @State private var colorTolerance: Double
    @State private var customPickerColor: Color = Color(charkleHex: "#3B82F6")
    @State private var selectedKinds: Set<MediaKind>
    @State private var minRating: Int
    @State private var cachedLiveMatchCount: Int = 0

    private let quickPalette: [String] = [
        "#E11D48", "#F97316", "#F59E0B", "#10B981",
        "#06B6D4", "#3B82F6", "#4E7D96", "#EC4899",
        "#18181B", "#71717A", "#E4E4E7", "#FFFFFF"
    ]

    public init(
        library: LibraryStore,
        existing: SmartFolderRecord?,
        onSave: @escaping (SmartFolderRecord) -> Void
    ) {
        self.library = library
        self.existing = existing
        self.onSave = onSave
        _name = State(initialValue: existing?.name ?? "")
        _matchMode = State(initialValue: existing?.rule.matchMode ?? .all)
        _selectedTags = State(initialValue: existing?.rule.tags ?? [])
        _descriptionQuery = State(initialValue: existing?.rule.descriptionQuery ?? "")
        _selectedColorHexes = State(initialValue: existing?.rule.colorHexes ?? [])
        _colorTolerance = State(initialValue: existing?.rule.colorTolerance ?? 24.0)
        _selectedKinds = State(initialValue: Set(existing?.rule.mediaKinds ?? []))
        _minRating = State(initialValue: existing?.rule.minRating ?? 0)
    }

    private var draftRule: SmartFolderRule {
        SmartFolderRule(
            matchMode: matchMode,
            tags: selectedTags,
            descriptionQuery: descriptionQuery.trimmingCharacters(in: .whitespacesAndNewlines),
            colorHexes: selectedColorHexes,
            colorTolerance: colorTolerance,
            mediaKinds: Array(selectedKinds).sorted { $0.rawValue < $1.rawValue },
            minRating: minRating
        )
    }

    private var liveMatchCount: Int {
        library.matchingCount(for: draftRule)
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 10) {
                CharkleIcon("smart-folder", style: .duotone, size: 22, isActive: true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(existing == nil ? "新建智能文件夹" : "编辑智能文件夹")
                        .font(.system(size: 15, weight: .semibold))
                    Text("符合规则的新老素材都会自动实时归入")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("当前匹配 \(cachedLiveMatchCount) 项")
                    .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(cachedLiveMatchCount > 0 ? Color.accentColor : .secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(
                        (cachedLiveMatchCount > 0 ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.06)),
                        in: Capsule(style: .continuous)
                    )
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    // Name + Match Mode
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 5) {
                            fieldLabel("文件夹名称")
                            TextField("例如：蓝色系夏日插画 / GitHub 灵感", text: $name)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 13))
                        }
                        VStack(alignment: .leading, spacing: 5) {
                            fieldLabel("规则匹配方式")
                            Picker("", selection: $matchMode) {
                                ForEach(SmartFolderRule.MatchMode.allCases, id: \.self) { mode in
                                    Text(mode.localizedLabel).tag(mode)
                                }
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                            .frame(width: 196)
                        }
                    }

                    // Condition 1: Tags
                    ruleCard(title: "符合标签", subtitle: "选择已有标签或手动输入") {
                        VStack(alignment: .leading, spacing: 10) {
                            if !selectedTags.isEmpty {
                                SmartFolderFlowLayout(spacing: 6) {
                                    ForEach(selectedTags, id: \.self) { tag in
                                        HStack(spacing: 4) {
                                            Text("#\(tag)")
                                                .font(.system(size: 11.5, weight: .medium))
                                            Button {
                                                selectedTags.removeAll { $0 == tag }
                                            } label: {
                                                Image(systemName: "xmark")
                                                    .font(.system(size: 8.5, weight: .bold))
                                            }
                                            .buttonStyle(.plain)
                                        }
                                        .foregroundStyle(.white)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 4)
                                        .background(Color.accentColor, in: Capsule(style: .continuous))
                                    }
                                }
                            }

                            HStack(spacing: 8) {
                                TextField("输入标签后回车添加…", text: $customTagInput)
                                    .textFieldStyle(.roundedBorder)
                                    .font(.system(size: 12))
                                    .onSubmit { addCustomTag() }
                                Button("添加") { addCustomTag() }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                    .disabled(customTagInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            }

                            let quickTags = library.topTenSidebarTags.filter { tc in
                                !selectedTags.contains { $0.caseInsensitiveCompare(tc.name) == .orderedSame }
                            }
                            if !quickTags.isEmpty {
                                SmartFolderFlowLayout(spacing: 5) {
                                    ForEach(quickTags) { tc in
                                        Button {
                                            selectedTags.append(tc.name)
                                        } label: {
                                            Text("+ #\(tc.name)")
                                                .font(.system(size: 11, weight: .medium))
                                                .foregroundStyle(.secondary)
                                                .padding(.horizontal, 8)
                                                .padding(.vertical, 3)
                                                .background(Color.primary.opacity(0.06), in: Capsule(style: .continuous))
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                            }
                        }
                    }

                    // Condition 2: Description / Keywords
                    ruleCard(title: "符合描述 / 关键词", subtitle: "匹配标题、AI 描述、备注、OCR 文本、推文正文与 README") {
                        TextField("输入多个关键词用空格分隔，例如：极简 建筑 海报", text: $descriptionQuery)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12.5))
                    }

                    // Condition 3: Specific Colors
                    ruleCard(title: "特定颜色", subtitle: "匹配任意已选色值的相近主色素材（支持色彩匹配范围调节）") {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(spacing: 7) {
                                ForEach(quickPalette, id: \.self) { hex in
                                    let active = selectedColorHexes.contains { $0.caseInsensitiveCompare(hex) == .orderedSame }
                                    Button {
                                        toggleColor(hex)
                                    } label: {
                                        Circle()
                                            .fill(Color(charkleHex: hex))
                                            .frame(width: 22, height: 22)
                                            .overlay(
                                                Circle()
                                                    .strokeBorder(
                                                        active ? Color.accentColor : Color.primary.opacity(0.18),
                                                        lineWidth: active ? 2.5 : 1
                                                    )
                                            )
                                            .overlay {
                                                if active {
                                                    Image(systemName: "checkmark")
                                                        .font(.system(size: 9.5, weight: .bold))
                                                        .foregroundStyle(Color.charkleIsLightHex(hex) ? .black : .white)
                                                }
                                            }
                                    }
                                    .buttonStyle(.plain)
                                    .help(hex)
                                }

                                Spacer(minLength: 4)

                                ColorPicker("", selection: $customPickerColor, supportsOpacity: false)
                                    .labelsHidden()
                                Button("加入此色") {
                                    if let hex = customPickerColor.charkleHexString {
                                        if !selectedColorHexes.contains(where: { $0.caseInsensitiveCompare(hex) == .orderedSame }) {
                                            selectedColorHexes.append(hex)
                                        }
                                    }
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }

                            if !selectedColorHexes.isEmpty {
                                SmartFolderFlowLayout(spacing: 6) {
                                    ForEach(selectedColorHexes, id: \.self) { hex in
                                        HStack(spacing: 5) {
                                            Circle()
                                                .fill(Color(charkleHex: hex))
                                                .frame(width: 11, height: 11)
                                            Text(hex)
                                                .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                                            Button {
                                                selectedColorHexes.removeAll { $0 == hex }
                                            } label: {
                                                Image(systemName: "xmark")
                                                    .font(.system(size: 8, weight: .bold))
                                            }
                                            .buttonStyle(.plain)
                                        }
                                        .padding(.horizontal, 7)
                                        .padding(.vertical, 3)
                                        .background(Color.primary.opacity(0.06), in: Capsule(style: .continuous))
                                    }
                                }

                                HStack(spacing: 10) {
                                    Text("色彩容差")
                                        .font(.system(size: 11.5))
                                        .foregroundStyle(.secondary)
                                    Slider(value: $colorTolerance, in: 10...48, step: 2)
                                        .frame(width: 180)
                                    Text("ΔE ≤ \(Int(colorTolerance))")
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }

                    // Condition 4: Media Kinds
                    ruleCard(title: "素材类型", subtitle: "不选则不限制类型") {
                        SmartFolderFlowLayout(spacing: 7) {
                            ForEach(MediaKind.allCases, id: \.self) { kind in
                                let active = selectedKinds.contains(kind)
                                Button {
                                    if active { selectedKinds.remove(kind) } else { selectedKinds.insert(kind) }
                                } label: {
                                    Text(kind.localizedLabel)
                                        .font(.system(size: 12, weight: active ? .semibold : .regular))
                                        .foregroundStyle(active ? .white : .primary)
                                        .padding(.horizontal, 11)
                                        .padding(.vertical, 5)
                                        .background(
                                            active ? Color.accentColor : Color.primary.opacity(0.06),
                                            in: Capsule(style: .continuous)
                                        )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }

                    // Condition 5: Minimum Rating
                    HStack(spacing: 10) {
                        fieldLabel("最低星级（可选）")
                        HStack(spacing: 4) {
                            ForEach(0...5, id: \.self) { star in
                                Button {
                                    minRating = star
                                } label: {
                                    Text(star == 0 ? "不限" : "\(star)★+")
                                        .font(.system(size: 11.5, weight: minRating == star ? .semibold : .regular))
                                        .foregroundStyle(minRating == star ? .white : .secondary)
                                        .padding(.horizontal, 9)
                                        .padding(.vertical, 4)
                                        .background(
                                            minRating == star ? Color.accentColor : Color.primary.opacity(0.06),
                                            in: Capsule(style: .continuous)
                                        )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                .padding(20)
            }

            Divider()

            HStack {
                Text(draftRule.hasAnyCondition ? "规则就绪" : "请至少设置一个筛选条件")
                    .font(.system(size: 11.5))
                    .foregroundStyle(draftRule.hasAnyCondition ? Color.secondary : Color.orange)
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(existing == nil ? "创建智能文件夹" : "保存规则") {
                    let finalName = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        ? "智能文件夹"
                        : name.trimmingCharacters(in: .whitespacesAndNewlines)
                    let record = SmartFolderRecord(
                        id: existing?.id ?? UUID(),
                        name: finalName,
                        colorHex: selectedColorHexes.first,
                        rule: draftRule,
                        sortOrder: existing?.sortOrder ?? library.smartFolders.count,
                        createdAt: existing?.createdAt ?? Date(),
                        updatedAt: Date()
                    )
                    onSave(record)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!draftRule.hasAnyCondition)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .frame(width: 560, height: 610)
        .background(CharkleTheme.surfaceElevated(for: colorScheme))
        .onAppear {
            cachedLiveMatchCount = liveMatchCount
        }
        .onChange(of: draftRule) { _, newRule in
            cachedLiveMatchCount = library.matchingCount(for: newRule)
        }
    }

    private func fieldLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundStyle(.secondary)
    }

    private func ruleCard<Content: View>(
        title: String,
        subtitle: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(title)
                    .font(.system(size: 12.5, weight: .semibold))
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            content()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(colorScheme == .dark ? 0.05 : 0.035))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(CharkleTheme.hairline(for: colorScheme), lineWidth: 0.75)
        )
    }

    private func addCustomTag() {
        let cleaned = customTagInput
            .trimmingCharacters(in: CharacterSet(charactersIn: "#＃").union(.whitespacesAndNewlines))
        customTagInput = ""
        guard !cleaned.isEmpty,
              !selectedTags.contains(where: { $0.caseInsensitiveCompare(cleaned) == .orderedSame }) else { return }
        selectedTags.append(cleaned)
    }

    private func toggleColor(_ hex: String) {
        if let idx = selectedColorHexes.firstIndex(where: { $0.caseInsensitiveCompare(hex) == .orderedSame }) {
            selectedColorHexes.remove(at: idx)
        } else {
            selectedColorHexes.append(hex)
        }
    }
}

private struct SmartFolderFlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxW = max(1, proposal.width ?? 480)
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineH: CGFloat = 0
        for view in subviews {
            let raw = view.sizeThatFits(ProposedViewSize(width: maxW, height: nil))
            let size = CGSize(width: min(raw.width, maxW), height: raw.height)
            if x + size.width > maxW, x > 0 {
                x = 0
                y += lineH + spacing
                lineH = 0
            }
            lineH = max(lineH, size.height)
            x += size.width + spacing
        }
        return CGSize(width: maxW, height: y + lineH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let maxW = max(1, bounds.width)
        var x = bounds.minX
        var y = bounds.minY
        var lineH: CGFloat = 0
        for view in subviews {
            let raw = view.sizeThatFits(ProposedViewSize(width: maxW, height: nil))
            let size = CGSize(width: min(raw.width, maxW), height: raw.height)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += lineH + spacing
                lineH = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            lineH = max(lineH, size.height)
            x += size.width + spacing
        }
    }
}

private extension Color {
    var charkleHexString: String? {
        guard let nsColor = NSColor(self).usingColorSpace(.sRGB) else { return nil }
        let r = Int((nsColor.redComponent * 255).rounded())
        let g = Int((nsColor.greenComponent * 255).rounded())
        let b = Int((nsColor.blueComponent * 255).rounded())
        return String(format: "#%02X%02X%02X", max(0, min(255, r)), max(0, min(255, g)), max(0, min(255, b)))
    }
}
