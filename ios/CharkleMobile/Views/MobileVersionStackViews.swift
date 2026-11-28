import CharkleCore
import SwiftUI
import UIKit

// MARK: - Pending Stack Candidate Model, Diff Launch Request & Display Sanitizer

struct MobilePendingStackPrompt: Identifiable, Equatable {
    var id: UUID { importedAsset.id }
    let importedAsset: AssetRecord
    let candidate: VersionStackCandidate
}

struct MobileDiffLaunchRequest: Identifiable, Equatable {
    let id = UUID()
    let baseAssetID: UUID
    let targetAssetID: UUID
}

/// Shared clean version label & attribution formatter across iOS Compact View, Inspector, and Document Studio.
/// Standalone without external symbol dependencies: strips redundant `vN` prefixes, unwraps parentheses,
/// suppresses system boilerplate, and prevents duplicate editor names.
enum MobileVersionDisplayFormatting {
    private static let ignoredBoilerplateTokens: Set<String> = [
        "本机",
        "初稿",
        "修订版",
        "基于差异审阅合成",
        "确认合成定稿",
    ]

    static func cleanDescriptor(
        changeNote: String?,
        versionLabel: String?,
        editorName: String?
    ) -> String? {
        let trimmedEditor = normalizedNonBoilerplate(editorName)
        if let cleanedNote = normalizedNonBoilerplate(changeNote) {
            if cleanedNote == trimmedEditor {
                return nil
            }
            return cleanedNote
        }
        if let cleanedLabel = normalizedNonBoilerplate(versionLabel) {
            if cleanedLabel == trimmedEditor {
                return nil
            }
            return cleanedLabel
        }
        return nil
    }

    static func cleanEditor(_ editorName: String?, excluding descriptor: String? = nil) -> String? {
        guard let cleaned = normalizedNonBoilerplate(editorName) else {
            return nil
        }
        if let descriptor, !descriptor.isEmpty, (descriptor == cleaned || descriptor.contains(cleaned)) {
            return nil
        }
        return cleaned
    }

    private static func normalizedNonBoilerplate(_ raw: String?) -> String? {
        guard let raw else { return nil }
        var current = AssetVersionStackMetadata.strippingRedundantVersionPrefix(raw)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !current.isEmpty else { return nil }

        if (current.hasPrefix("(") && current.hasSuffix(")"))
            || (current.hasPrefix("（") && current.hasSuffix("）")) {
            current = String(current.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
            current = AssetVersionStackMetadata.strippingRedundantVersionPrefix(current)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        guard !current.isEmpty else { return nil }
        if ignoredBoilerplateTokens.contains(current) || current.hasPrefix("挑拣合成") {
            return nil
        }
        return current
    }
}

// MARK: - Non-Blocking Import Version Stack Prompt Banner

/// Lightweight non-blocking stacking prompt presented above bottom chrome when importing files
/// from Open-In, Files picker, Share Extension, or iPad drag-and-drop.
struct MobileVersionStackPromptBanner: View {
    @Bindable var store: MobileAppStore
    let prompt: MobilePendingStackPrompt

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var editorDraft: String = ""
    @State private var changeNoteDraft: String = ""
    @State private var isExpandedForDetails: Bool = false
    @State private var pinAsPrimary: Bool = false
    @State private var isSubmitting: Bool = false

    var body: some View {
        let accent = MobileTheme.accent(for: colorScheme)
        let folderLabel = prompt.candidate.targetFolderID.flatMap { fid in
            store.folders.first(where: { $0.id == fid })?.name
        }

        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(MobileTheme.accentSoft(for: colorScheme))
                        .frame(width: 34, height: 34)
                    Image(systemName: "square.stack.3d.up.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(accent)
                }

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text("归入《\(prompt.candidate.targetTitle)》历史版本 (v\(prompt.candidate.nextVersionNumber))？")
                            .font(.system(size: 13.5, weight: .semibold).monospacedDigit())
                            .foregroundStyle(.primary)
                            .lineLimit(2)
                        if store.pendingStackPrompts.count > 1 {
                            Text("1/\(store.pendingStackPrompts.count)")
                                .font(.system(size: 10.5, weight: .bold).monospacedDigit())
                                .foregroundStyle(MobileTheme.secondaryInk(for: colorScheme))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(MobileTheme.surfaceSubtle(for: colorScheme), in: Capsule())
                        }
                    }

                    HStack(spacing: 6) {
                        Text(prompt.candidate.matchReason.localizedLabel)
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(MobileTheme.secondaryInk(for: colorScheme))
                        if let folderLabel {
                            Text("· 归入「\(folderLabel)」")
                                .font(.system(size: 11.5, weight: .medium))
                                .foregroundStyle(MobileTheme.positive(for: colorScheme))
                                .lineLimit(1)
                        }
                    }
                }

                Spacer(minLength: 4)

                Button {
                    MobileHaptics.light()
                    store.dismissStackPrompt(prompt.id)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(MobileTheme.tertiaryInk(for: colorScheme))
                        .frame(width: 26, height: 26)
                        .background(MobileTheme.surfaceSubtle(for: colorScheme), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("保留为独立素材")
            }

            if isExpandedForDetails {
                VStack(spacing: 8) {
                    HStack(spacing: 8) {
                        TextField("修改人", text: $editorDraft)
                            .font(.system(size: 12.5))
                            .submitLabel(.next)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 7)
                            .frame(maxWidth: 120)
                            .background(
                                MobileTheme.inspectorFieldSurface(for: colorScheme),
                                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .strokeBorder(MobileTheme.hairline(for: colorScheme), lineWidth: 0.5)
                            )

                        TextField("备注（可选）", text: $changeNoteDraft)
                            .font(.system(size: 12.5))
                            .submitLabel(.done)
                            .onSubmit { submitJoin() }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .background(
                                MobileTheme.inspectorFieldSurface(for: colorScheme),
                                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .strokeBorder(MobileTheme.hairline(for: colorScheme), lineWidth: 0.5)
                            )
                    }

                    Toggle(isOn: $pinAsPrimary) {
                        Text("同时设为主版本")
                            .font(.system(size: 12))
                            .foregroundStyle(MobileTheme.secondaryInk(for: colorScheme))
                    }
                    .tint(accent)
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            HStack(spacing: 8) {
                Button {
                    MobileHaptics.light()
                    withAnimation(MobileMotion.accessible(MobileMotion.settleStrong, reduced: reduceMotion)) {
                        isExpandedForDetails.toggle()
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(editorSummaryLabel)
                            .font(.system(size: 12, weight: .medium))
                            .lineLimit(1)
                        Image(systemName: isExpandedForDetails ? "chevron.up" : "pencil")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .foregroundStyle(MobileTheme.secondaryInk(for: colorScheme))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(MobileTheme.surfaceSubtle(for: colorScheme), in: Capsule())
                }
                .buttonStyle(.plain)

                Spacer(minLength: 4)

                Button("单独保留") {
                    MobileHaptics.light()
                    store.dismissStackPrompt(prompt.id)
                }
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(MobileTheme.secondaryInk(for: colorScheme))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .buttonStyle(.plain)

                Button {
                    submitJoin()
                } label: {
                    HStack(spacing: 5) {
                        if isSubmitting {
                            ProgressView().controlSize(.mini).tint(.white)
                        } else {
                            Image(systemName: "checkmark")
                                .font(.system(size: 11, weight: .bold))
                        }
                        Text("归入版本")
                            .font(.system(size: 12.5, weight: .semibold).monospacedDigit())
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 7)
                    .background(MobileTheme.accentButtonFill(for: colorScheme), in: Capsule())
                }
                .buttonStyle(MobileTactileButtonStyle())
                .disabled(isSubmitting)
            }
        }
        .padding(12)
        .frame(maxWidth: 580)
        .charkleFloatingCard(cornerRadius: 16, interactive: true)
        .onAppear {
            syncInitialFields()
        }
        .onChange(of: prompt.id) { _, _ in
            syncInitialFields()
        }
    }

    private var editorSummaryLabel: String {
        let trimmedEditor = editorDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedNote = changeNoteDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedEditor.isEmpty && !trimmedNote.isEmpty {
            return "\(trimmedEditor) · \(trimmedNote)"
        }
        if !trimmedEditor.isEmpty {
            return trimmedEditor
        }
        return "备注（可选）"
    }

    private func syncInitialFields() {
        let suggested = prompt.candidate.suggestedEditorName ?? ""
        editorDraft = suggested == "本机" ? "" : suggested
        changeNoteDraft = ""
        pinAsPrimary = false
    }

    private func submitJoin() {
        guard !isSubmitting else { return }
        isSubmitting = true
        MobileKeyboard.dismiss()
        let editor = editorDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let note = changeNoteDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let pin = pinAsPrimary
        Task {
            await store.confirmStackPrompt(
                prompt,
                editorName: (editor.isEmpty || editor == "本机") ? nil : editor,
                changeNote: note.isEmpty ? nil : note,
                pinAsPrimary: pin
            )
            isSubmitting = false
        }
    }
}

// MARK: - Manual Merge Into Version Stack Sheet

struct MergeIntoVersionStackSheet: View {
    @Bindable var store: MobileAppStore
    let sourceAssets: [AssetRecord]
    let onDone: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var searchText: String = ""
    @State private var editorDraft: String = ""
    @State private var changeNoteDraft: String = ""
    @State private var pinAsPrimary: Bool = false
    @State private var isSubmitting: Bool = false

    private var sourceIDs: Set<UUID> {
        Set(sourceAssets.map(\.id))
    }

    private var candidateTargets: [AssetRecord] {
        let pool = store.assets.filter { !sourceIDs.contains($0.id) && !$0.isTrashed }
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return Array(pool.prefix(40)) }
        return pool.filter {
            $0.title.localizedCaseInsensitiveContains(q)
                || $0.fileName.localizedCaseInsensitiveContains(q)
        }
    }

    var body: some View {
        List {
            Section("版本信息（可选）") {
                TextField("修改人", text: $editorDraft)
                    .font(.system(size: 14))
                TextField("备注（可选）", text: $changeNoteDraft)
                    .font(.system(size: 14))
                Toggle("同时设为主版本", isOn: $pinAsPrimary)
                    .font(.system(size: 13.5))
            }

            if sourceAssets.count >= 2 {
                Section("合并所选项目") {
                    Button {
                        guard !isSubmitting else { return }
                        isSubmitting = true
                        let ids = sourceAssets.map(\.id)
                        let editor = editorDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                        let note = changeNoteDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                        Task {
                            await store.createVersionStack(
                                assetIDs: ids,
                                primaryAssetID: pinAsPrimary ? ids.last : nil,
                                editorName: (editor.isEmpty || editor == "本机") ? nil : editor,
                                changeNote: note.isEmpty ? nil : note
                            )
                            isSubmitting = false
                            onDone()
                        }
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "square.stack.3d.up.fill")
                                .foregroundStyle(MobileTheme.accent(for: colorScheme))
                            VStack(alignment: .leading, spacing: 2) {
                                Text("将选中的 \(sourceAssets.count) 项合并为历史版本")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(.primary)
                                Text("自动编号 v1 → v\(sourceAssets.count)，原文件独立保留")
                                    .font(.system(size: 12).monospacedDigit())
                                    .foregroundStyle(MobileTheme.secondaryInk(for: colorScheme))
                            }
                        }
                        .padding(.vertical, 3)
                    }
                    .disabled(isSubmitting)
                }
            }

            Section("归入已有素材的历史版本") {
                if candidateTargets.isEmpty {
                    Text("没有找到可归入的目标素材")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(candidateTargets) { target in
                        let siblings = store.stackMembers(for: target)
                        let nextVer = (siblings.compactMap { $0.richMetadata?.versionStack?.versionNumber }.max() ?? 1) + 1
                        Button {
                            guard !isSubmitting else { return }
                            isSubmitting = true
                            let targetKey = target.richMetadata?.versionStack?.groupID ?? target.id
                            let editor = editorDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                            let note = changeNoteDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                            let pin = pinAsPrimary
                            Task {
                                for (idx, item) in sourceAssets.enumerated() {
                                    await store.joinVersionStack(
                                        assetID: item.id,
                                        targetAssetOrGroupID: targetKey,
                                        editorName: (editor.isEmpty || editor == "本机") ? nil : editor,
                                        changeNote: note.isEmpty ? nil : note,
                                        pinAsPrimary: pin && (idx == sourceAssets.count - 1),
                                        adoptTargetFolder: true
                                    )
                                }
                                isSubmitting = false
                                onDone()
                            }
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: siblings.count > 1 ? "square.stack.3d.up.fill" : MobileTheme.mediaKindSymbol(for: target.mediaKind))
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(MobileTheme.accent(for: colorScheme))
                                    .frame(width: 26)

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(target.title)
                                        .font(.system(size: 14, weight: .medium))
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)
                                    Text(
                                        siblings.count > 1
                                            ? "已有 \(siblings.count) 版 · 归入为 v\(nextVer)"
                                            : "\(target.displayTypeLabel) · 合并为 v2"
                                    )
                                    .font(.system(size: 11.5).monospacedDigit())
                                    .foregroundStyle(MobileTheme.secondaryInk(for: colorScheme))
                                }

                                Spacer()

                                Text("v\(nextVer)")
                                    .font(.system(size: 11.5, weight: .semibold).monospacedDigit())
                                    .foregroundStyle(.primary)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 3)
                                    .background(Color.primary.opacity(0.06), in: Capsule())
                            }
                        }
                        .disabled(isSubmitting)
                    }
                }
            }
        }
        .searchable(text: $searchText, prompt: "搜索目标文档或设计稿标题…")
        .navigationTitle("合并版本")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("取消", action: onDone)
            }
        }
    }
}

// MARK: - Inspector Version Stack Section (Newest-First Vertical Timeline Spine)

struct InspectorVersionStackCard: View {
    @Bindable var store: MobileAppStore
    let asset: AssetRecord
    let onSelectVersion: (AssetRecord) -> Void
    let onOpenDiff: (UUID, UUID) -> Void
    let onRequestMergeSheet: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var isExpanded: Bool = true
    @State private var editingVersionID: UUID? = nil
    @State private var editorDraft: String = ""
    @State private var noteDraft: String = ""
    @State private var labelDraft: String = ""

    private var siblings: [AssetRecord] {
        store.stackMembers(for: asset)
    }

    private var primaryAsset: AssetRecord {
        store.primaryVersionAsset(for: asset)
    }

    private var primaryVersionNumber: Int {
        if let explicit = primaryAsset.richMetadata?.versionStack?.versionNumber {
            return explicit
        }
        if let idx = siblings.firstIndex(where: { $0.id == primaryAsset.id }) {
            return idx + 1
        }
        return 1
    }

    var body: some View {
        let accent = MobileTheme.accent(for: colorScheme)
        let pos = MobileTheme.positive(for: colorScheme)
        let warn = MobileTheme.warning(for: colorScheme)
        let danger = MobileTheme.destructive(for: colorScheme)
        let hasStack = siblings.count > 1 || asset.richMetadata?.versionStack != nil

        VStack(alignment: .leading, spacing: 10) {
            Button {
                MobileHaptics.light()
                withAnimation(MobileMotion.accessible(MobileMotion.settleStrong, reduced: reduceMotion)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    Text(hasStack ? "历史版本 · 共 \(siblings.count) 版 · 主版 v\(primaryVersionNumber)" : "历史版本")
                        .font(.system(size: 12.5, weight: .medium).monospacedDigit())
                        .foregroundStyle(.primary)
                    Spacer()
                    if hasStack {
                        let pending = store.newerThanPrimaryCount(for: asset)
                        if pending > 0 {
                            Text("+\(pending)")
                                .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                                .foregroundStyle(warn)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1.5)
                                .background(warn.opacity(0.14), in: Capsule())
                        }
                    }
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(MobileTheme.tertiaryInk(for: colorScheme))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                if !hasStack {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("合并同一文档或设计稿的历次修改")
                            .font(.system(size: 12))
                            .foregroundStyle(MobileTheme.secondaryInk(for: colorScheme))

                        Button {
                            MobileHaptics.light()
                            onRequestMergeSheet()
                        } label: {
                            Label("合并版本…", systemImage: "arrow.triangle.merge")
                                .font(.system(size: 12.5, weight: .medium))
                                .foregroundStyle(.primary)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 7.5)
                                .background(
                                    MobileTheme.inspectorFieldSurface(for: colorScheme),
                                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                                )
                        }
                        .buttonStyle(MobileTactileButtonStyle())
                    }
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        // Top Compact Action Row
                        HStack(spacing: 6) {
                            if siblings.count >= 2 {
                                let lastTwo = Array(siblings.suffix(2))
                                Button {
                                    MobileHaptics.light()
                                    onOpenDiff(lastTwo[0].id, lastTwo[1].id)
                                } label: {
                                    Label("对比差异", systemImage: "arrow.left.arrow.right")
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(.primary)
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 6.5)
                                        .background(
                                            MobileTheme.inspectorFieldSurface(for: colorScheme),
                                            in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                                        )
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                                .strokeBorder(MobileTheme.hairline(for: colorScheme), lineWidth: 0.5)
                                        )
                                }
                                .buttonStyle(MobileTactileButtonStyle())
                            }

                            if asset.id != primaryAsset.id {
                                Button {
                                    MobileHaptics.success()
                                    Task { await store.setPrimaryVersion(assetID: asset.id) }
                                } label: {
                                    Label("设为主版", systemImage: "pin")
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(accent)
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 6.5)
                                        .background(
                                            MobileTheme.accentSoft(for: colorScheme),
                                            in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                                        )
                                }
                                .buttonStyle(MobileTactileButtonStyle())
                            }

                            Button {
                                MobileHaptics.light()
                                onRequestMergeSheet()
                            } label: {
                                Image(systemName: "plus")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(accent)
                                    .frame(width: 30, height: 29)
                                    .background(
                                        MobileTheme.accentSoft(for: colorScheme),
                                        in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    )
                            }
                            .buttonStyle(MobileTactileButtonStyle())
                            .accessibilityLabel("合并更多历史版本")
                        }

                        // Newest-First Vertical Timeline (`vN → v1`)
                        let reversedItems = Array(siblings.enumerated().reversed())
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(reversedItems.enumerated()), id: \.element.element.id) { displayIdx, entry in
                                let ascIndex = entry.offset
                                let member = entry.element
                                let verMeta = member.richMetadata?.versionStack
                                let vNum = verMeta?.versionNumber ?? (ascIndex + 1)
                                let isCurrent = member.id == asset.id
                                let isPrimary = member.id == primaryAsset.id
                                let isUnreviewed = vNum > primaryVersionNumber
                                let prevMember: AssetRecord? = ascIndex > 0 ? siblings[ascIndex - 1] : nil
                                let descriptor = MobileVersionDisplayFormatting.cleanDescriptor(
                                    changeNote: verMeta?.changeNote,
                                    versionLabel: verMeta?.versionLabel,
                                    editorName: verMeta?.editorName
                                )
                                let cleanEditor = MobileVersionDisplayFormatting.cleanEditor(
                                    verMeta?.editorName,
                                    excluding: descriptor
                                )
                                let diffSummary = member.richMetadata?.document?.diffSummary
                                let changedBlocks = diffSummary?.totalChangedBlocks ?? 0
                                let hasHighRisk = (diffSummary?.totalHighRiskChanges ?? 0) > 0

                                VStack(alignment: .leading, spacing: 6) {
                                    HStack(alignment: .center, spacing: 8) {
                                        // Left 16pt Spine Column
                                        GeometryReader { geo in
                                            let midX = geo.size.width * 0.5
                                            let midY = geo.size.height * 0.5
                                            ZStack {
                                                if displayIdx > 0 {
                                                    Path { p in
                                                        p.move(to: CGPoint(x: midX, y: 0))
                                                        p.addLine(to: CGPoint(x: midX, y: midY))
                                                    }
                                                    .stroke(MobileTheme.hairline(for: colorScheme), lineWidth: 1)
                                                }
                                                if displayIdx < reversedItems.count - 1 {
                                                    Path { p in
                                                        p.move(to: CGPoint(x: midX, y: midY))
                                                        p.addLine(to: CGPoint(x: midX, y: geo.size.height))
                                                    }
                                                    .stroke(MobileTheme.hairline(for: colorScheme), lineWidth: 1)
                                                }

                                                if isPrimary {
                                                    Circle()
                                                        .fill(accent)
                                                        .frame(width: 7.5, height: 7.5)
                                                        .position(x: midX, y: midY)
                                                } else {
                                                    Circle()
                                                        .fill(MobileTheme.surfaceElevated(for: colorScheme))
                                                        .frame(width: 7.5, height: 7.5)
                                                        .overlay(
                                                            Circle().strokeBorder(
                                                                isUnreviewed ? warn : MobileTheme.secondaryInk(for: colorScheme).opacity(0.50),
                                                                lineWidth: 1.5
                                                            )
                                                        )
                                                        .position(x: midX, y: midY)
                                                }
                                            }
                                        }
                                        .frame(width: 16)

                                        // Version Row Body
                                        HStack(spacing: 4) {
                                            Button {
                                                MobileHaptics.light()
                                                onSelectVersion(member)
                                            } label: {
                                                VStack(alignment: .leading, spacing: 2) {
                                                    HStack(spacing: 5) {
                                                        Text("v\(vNum)")
                                                            .font(.system(size: 12.5, weight: .bold).monospacedDigit())
                                                            .foregroundStyle(isCurrent ? accent : .primary)

                                                        if let descriptor {
                                                            Text(descriptor)
                                                                .font(.system(size: 12, weight: .regular))
                                                                .foregroundStyle(MobileTheme.secondaryInk(for: colorScheme))
                                                                .lineLimit(1)
                                                        }

                                                        if isPrimary {
                                                            Text("主版")
                                                                .font(.system(size: 10, weight: .semibold))
                                                                .foregroundStyle(pos)
                                                                .padding(.horizontal, 5)
                                                                .padding(.vertical, 1)
                                                                .background(
                                                                    pos.opacity(0.14),
                                                                    in: RoundedRectangle(cornerRadius: 4, style: .continuous)
                                                                )
                                                        }
                                                    }

                                                    HStack(spacing: 4) {
                                                        Text(MobileFormatters.relativeDate(member.updatedAt))
                                                            .font(.system(size: 11).monospacedDigit())
                                                            .foregroundStyle(MobileTheme.tertiaryInk(for: colorScheme))

                                                        if let cleanEditor {
                                                            Text("· \(cleanEditor)")
                                                                .font(.system(size: 11))
                                                                .foregroundStyle(MobileTheme.secondaryInk(for: colorScheme))
                                                                .lineLimit(1)
                                                        }
                                                    }
                                                }
                                                .frame(maxWidth: .infinity, alignment: .leading)
                                                .contentShape(Rectangle())
                                            }
                                            .buttonStyle(.plain)

                                            if let prevMember, changedBlocks > 0 {
                                                Button {
                                                    MobileHaptics.light()
                                                    onOpenDiff(prevMember.id, member.id)
                                                } label: {
                                                    Text("Δ \(changedBlocks)")
                                                        .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                                                        .foregroundStyle(hasHighRisk ? danger : MobileTheme.secondaryInk(for: colorScheme))
                                                        .padding(.horizontal, 6)
                                                        .padding(.vertical, 3)
                                                        .background(
                                                            hasHighRisk ? danger.opacity(0.12) : MobileTheme.surfaceSubtle(for: colorScheme),
                                                            in: Capsule()
                                                        )
                                                }
                                                .buttonStyle(.plain)
                                            }

                                            if !isPrimary {
                                                Button {
                                                    MobileHaptics.success()
                                                    Task { await store.setPrimaryVersion(assetID: member.id) }
                                                } label: {
                                                    Image(systemName: "pin")
                                                        .font(.system(size: 11, weight: .semibold))
                                                        .foregroundStyle(MobileTheme.secondaryInk(for: colorScheme))
                                                        .frame(width: 24, height: 24)
                                                        .contentShape(Circle())
                                                }
                                                .buttonStyle(.plain)
                                                .accessibilityLabel("设为主版本")
                                            }

                                            Menu {
                                                if !isPrimary {
                                                    Button {
                                                        Task { await store.setPrimaryVersion(assetID: member.id) }
                                                    } label: {
                                                        Label("设为主版本", systemImage: "pin")
                                                    }
                                                }
                                                if let prevMember {
                                                    Button {
                                                        onOpenDiff(prevMember.id, member.id)
                                                    } label: {
                                                        Label("与上一版对比差异", systemImage: "arrow.left.arrow.right")
                                                    }
                                                }
                                                Button {
                                                    editingVersionID = member.id
                                                    let rawEditor = verMeta?.editorName ?? ""
                                                    editorDraft = rawEditor == "本机" ? "" : rawEditor
                                                    noteDraft = MobileVersionDisplayFormatting.cleanDescriptor(
                                                        changeNote: verMeta?.changeNote,
                                                        versionLabel: nil,
                                                        editorName: verMeta?.editorName
                                                    ) ?? ""
                                                    labelDraft = verMeta?.versionLabel ?? ""
                                                } label: {
                                                    Label("编辑备注", systemImage: "pencil")
                                                }
                                                Divider()
                                                Button(role: .destructive) {
                                                    Task { await store.unstackAsset(assetID: member.id) }
                                                } label: {
                                                    Label("拆分为独立素材", systemImage: "square.stack.3d.up.slash")
                                                }
                                            } label: {
                                                Image(systemName: "ellipsis")
                                                    .font(.system(size: 11.5, weight: .semibold))
                                                    .foregroundStyle(MobileTheme.tertiaryInk(for: colorScheme))
                                                    .frame(width: 24, height: 24)
                                                    .contentShape(Circle())
                                            }
                                        }
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 6)
                                        .background(
                                            isCurrent ? MobileTheme.accentSoft(for: colorScheme) : .clear,
                                            in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                                        )
                                    }

                                    if editingVersionID == member.id {
                                        VStack(spacing: 6) {
                                            HStack(spacing: 6) {
                                                TextField("修改人", text: $editorDraft)
                                                    .font(.system(size: 12))
                                                    .padding(7)
                                                    .frame(maxWidth: 96)
                                                    .background(
                                                        MobileTheme.inspectorFieldSurface(for: colorScheme),
                                                        in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                                                    )
                                                TextField("备注（可选）", text: $noteDraft)
                                                    .font(.system(size: 12))
                                                    .padding(7)
                                                    .background(
                                                        MobileTheme.inspectorFieldSurface(for: colorScheme),
                                                        in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                                                    )
                                            }
                                            HStack {
                                                Spacer()
                                                Button("取消") {
                                                    editingVersionID = nil
                                                }
                                                .font(.system(size: 11.5))
                                                .foregroundStyle(MobileTheme.secondaryInk(for: colorScheme))

                                                Button("保存") {
                                                    let id = member.id
                                                    let ed = editorDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                                                    let nt = noteDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                                                    let lb = labelDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                                                    editingVersionID = nil
                                                    Task {
                                                        await store.updateVersionStackMetadata(
                                                            assetID: id,
                                                            versionLabel: lb.isEmpty ? nil : lb,
                                                            editorName: (ed.isEmpty || ed == "本机") ? nil : ed,
                                                            changeNote: nt.isEmpty ? nil : nt
                                                        )
                                                    }
                                                }
                                                .font(.system(size: 11.5, weight: .semibold))
                                                .foregroundStyle(accent)
                                            }
                                        }
                                        .padding(.leading, 24)
                                        .padding(.bottom, 4)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            MobileTheme.surfaceElevated(for: colorScheme),
            in: RoundedRectangle(cornerRadius: MobileTheme.Radius.cardOuter, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: MobileTheme.Radius.cardOuter, style: .continuous)
                .strokeBorder(MobileTheme.hairline(for: colorScheme), lineWidth: 0.5)
        )
    }
}
