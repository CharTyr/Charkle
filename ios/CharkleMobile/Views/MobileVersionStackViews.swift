import CharkleCore
import SwiftUI
import UIKit

// MARK: - Pending Stack Candidate Model & Diff Launch Request

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

// MARK: - Non-Blocking Import Version Stack Prompt Banner

/// Lightweight non-blocking stacking prompt presented above bottom chrome when importing files
/// from WeChat Open-In, Files picker, Share Extension, or iPad drag-and-drop.
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
                        Text("叠入《\(prompt.candidate.targetTitle)》作为 v\(prompt.candidate.nextVersionNumber)？")
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
                            Text("· 自动归入「\(folderLabel)」")
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
                        HStack(spacing: 6) {
                            Image(systemName: "person")
                                .font(.system(size: 11.5, weight: .medium))
                                .foregroundStyle(MobileTheme.secondaryInk(for: colorScheme))
                            TextField("修改人（可选）", text: $editorDraft)
                                .font(.system(size: 12.5))
                                .submitLabel(.next)
                        }
                        .padding(.horizontal, 9)
                        .padding(.vertical, 7)
                        .frame(maxWidth: 148)
                        .background(
                            MobileTheme.inspectorFieldSurface(for: colorScheme),
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(MobileTheme.hairline(for: colorScheme), lineWidth: 0.75)
                        )

                        TextField("1 行改动备注（如：核定第三部分预算数字）", text: $changeNoteDraft)
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
                                    .strokeBorder(MobileTheme.hairline(for: colorScheme), lineWidth: 0.75)
                            )
                    }

                    Toggle(isOn: $pinAsPrimary) {
                        Text("同时将此版锁定为对外「主版本」（未勾选则保留原主版本防误发）")
                            .font(.system(size: 11.5))
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

                Button("保留独立") {
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
                        Text("叠入 v\(prompt.candidate.nextVersionNumber)")
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
            return "修改人：\(trimmedEditor)（点此补备注）"
        }
        return "填写修改人 / 备注"
    }

    private func syncInitialFields() {
        editorDraft = prompt.candidate.suggestedEditorName ?? ""
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
                editorName: editor.isEmpty ? nil : editor,
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
            Section("新版本备注（可选）") {
                TextField("修改人（如：张主任）", text: $editorDraft)
                    .font(.system(size: 14))
                TextField("改动说明（如：核定第三节经费明细）", text: $changeNoteDraft)
                    .font(.system(size: 14))
                Toggle("设为主版本（对外分享与导出的默认版本）", isOn: $pinAsPrimary)
                    .font(.system(size: 13.5))
            }

            if sourceAssets.count >= 2 {
                Section("将所选项目直接合为一叠") {
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
                                editorName: editor.isEmpty ? nil : editor,
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
                                Text("将选中的 \(sourceAssets.count) 项合并为新建版本叠")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(.primary)
                                Text("按时间顺序自动编号 v1 → v\(sourceAssets.count)，原文件独立保留")
                                    .font(.system(size: 12).monospacedDigit())
                                    .foregroundStyle(MobileTheme.secondaryInk(for: colorScheme))
                            }
                        }
                        .padding(.vertical, 3)
                    }
                    .disabled(isSubmitting)
                }
            }

            Section("叠入已有素材或版本叠") {
                if candidateTargets.isEmpty {
                    Text("没有找到可叠入的目标素材")
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
                                        editorName: editor.isEmpty ? nil : editor,
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
                                            ? "已有 \(siblings.count) 个版本 · 叠入为 v\(nextVer)"
                                            : "\(target.displayTypeLabel) · 合并后成为 v2"
                                    )
                                    .font(.system(size: 11.5).monospacedDigit())
                                    .foregroundStyle(MobileTheme.secondaryInk(for: colorScheme))
                                }

                                Spacer()

                                Text("v\(nextVer)")
                                    .font(.system(size: 11.5, weight: .semibold).monospacedDigit())
                                    .foregroundStyle(MobileTheme.accent(for: colorScheme))
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 3)
                                    .background(MobileTheme.accentSoft(for: colorScheme), in: Capsule())
                            }
                        }
                        .disabled(isSubmitting)
                    }
                }
            }
        }
        .searchable(text: $searchText, prompt: "搜索目标文档或设计稿标题…")
        .navigationTitle("合并入版本叠")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("取消", action: onDone)
            }
        }
    }
}

// MARK: - Inspector Version Stack Section (1:1 Shared by iPad Docked Inspector & iPhone Sheet)

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

    var body: some View {
        let accent = MobileTheme.accent(for: colorScheme)
        let hasStack = siblings.count > 1 || asset.richMetadata?.versionStack != nil

        VStack(alignment: .leading, spacing: 10) {
            Button {
                MobileHaptics.light()
                withAnimation(MobileMotion.accessible(MobileMotion.settleStrong, reduced: reduceMotion)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: hasStack ? "square.stack.3d.up.fill" : "square.stack.3d.up")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(accent)
                    Text(hasStack ? "版本叠（共 \(siblings.count) 版）" : "版本叠")
                        .font(.system(size: 11.5, weight: .semibold).monospacedDigit())
                        .foregroundStyle(MobileTheme.secondaryInk(for: colorScheme))
                    Spacer()
                    if hasStack {
                        let pending = store.newerThanPrimaryCount(for: asset)
                        if pending > 0 {
                            Text("+\(pending) 待审新版")
                                .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                                .foregroundStyle(MobileTheme.warning(for: colorScheme))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(MobileTheme.warning(for: colorScheme).opacity(0.14), in: Capsule())
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
                        Text("将同一份汇报、表格或设计稿的历次修改叠在一起，锁定「主版本」防止误发未审草稿。")
                            .font(.system(size: 12))
                            .foregroundStyle(MobileTheme.secondaryInk(for: colorScheme))

                        Button {
                            MobileHaptics.light()
                            onRequestMergeSheet()
                        } label: {
                            Label("合并入已有版本叠…", systemImage: "arrow.triangle.merge")
                                .font(.system(size: 12.5, weight: .semibold))
                                .foregroundStyle(accent)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 8)
                                .background(MobileTheme.accentSoft(for: colorScheme), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        }
                        .buttonStyle(MobileTactileButtonStyle())
                    }
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(siblings.enumerated()), id: \.element.id) { index, member in
                            let verMeta = member.richMetadata?.versionStack
                            let vNum = verMeta?.versionNumber ?? (index + 1)
                            let isCurrent = member.id == asset.id
                            let isPrimary = member.id == primaryAsset.id
                            let prevMember: AssetRecord? = index > 0 ? siblings[index - 1] : nil

                            VStack(alignment: .leading, spacing: 6) {
                                HStack(spacing: 8) {
                                    Button {
                                        MobileHaptics.light()
                                        onSelectVersion(member)
                                    } label: {
                                        VStack(alignment: .leading, spacing: 2) {
                                            HStack(spacing: 5) {
                                                Text("v\(vNum)")
                                                    .font(.system(size: 12.5, weight: .bold).monospacedDigit())
                                                    .foregroundStyle(isCurrent ? accent : .primary)

                                                if let note = verMeta?.changeNote, !note.isEmpty {
                                                    Text("· \(note)")
                                                        .font(.system(size: 12, weight: .medium))
                                                        .foregroundStyle(.primary)
                                                        .lineLimit(1)
                                                } else if let label = verMeta?.versionLabel, !label.isEmpty {
                                                    Text("· \(label)")
                                                        .font(.system(size: 12, weight: .medium))
                                                        .foregroundStyle(.primary)
                                                        .lineLimit(1)
                                                }

                                                if isPrimary {
                                                    Text("主版")
                                                        .font(.system(size: 10, weight: .bold))
                                                        .foregroundStyle(MobileTheme.positive(for: colorScheme))
                                                        .padding(.horizontal, 5.5)
                                                        .padding(.vertical, 1.5)
                                                        .background(
                                                            MobileTheme.positive(for: colorScheme).opacity(0.14),
                                                            in: RoundedRectangle(cornerRadius: 4, style: .continuous)
                                                        )
                                                }
                                            }

                                            HStack(spacing: 5) {
                                                if let editor = verMeta?.editorName, !editor.isEmpty {
                                                    Text(editor)
                                                        .font(.system(size: 11, weight: .medium))
                                                        .foregroundStyle(MobileTheme.secondaryInk(for: colorScheme))
                                                }
                                                Text(MobileFormatters.relativeDate(member.updatedAt))
                                                    .font(.system(size: 11).monospacedDigit())
                                                    .foregroundStyle(MobileTheme.tertiaryInk(for: colorScheme))
                                                if let diff = member.richMetadata?.document?.diffSummary, diff.totalChangedBlocks > 0 {
                                                    Text(diff.compactBridgeLabel)
                                                        .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                                                        .foregroundStyle(
                                                            diff.totalHighRiskChanges > 0
                                                                ? MobileTheme.destructive(for: colorScheme)
                                                                : MobileTheme.warning(for: colorScheme)
                                                        )
                                                }
                                            }
                                        }
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)

                                    HStack(spacing: 4) {
                                        if let prevMember {
                                            Button {
                                                MobileHaptics.light()
                                                onOpenDiff(prevMember.id, member.id)
                                            } label: {
                                                Text("Δ 对比")
                                                    .font(.system(size: 11, weight: .semibold))
                                                    .foregroundStyle(MobileTheme.warning(for: colorScheme))
                                                    .padding(.horizontal, 7)
                                                    .padding(.vertical, 4)
                                                    .background(
                                                        MobileTheme.warning(for: colorScheme).opacity(0.14),
                                                        in: Capsule()
                                                    )
                                            }
                                            .buttonStyle(.plain)
                                        }

                                        Menu {
                                            if !isPrimary {
                                                Button {
                                                    Task { await store.setPrimaryVersion(assetID: member.id) }
                                                } label: {
                                                    Label("设为主版本（防误发锁定）", systemImage: "checkmark.seal.fill")
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
                                                editorDraft = verMeta?.editorName ?? ""
                                                noteDraft = verMeta?.changeNote ?? ""
                                                labelDraft = verMeta?.versionLabel ?? ""
                                            } label: {
                                                Label("编辑修改人与版本备注", systemImage: "pencil")
                                            }
                                            Divider()
                                            Button(role: .destructive) {
                                                Task { await store.unstackAsset(assetID: member.id) }
                                            } label: {
                                                Label("拆出为独立素材", systemImage: "square.stack.3d.up.slash")
                                            }
                                        } label: {
                                            Image(systemName: "ellipsis")
                                                .font(.system(size: 12, weight: .semibold))
                                                .foregroundStyle(MobileTheme.secondaryInk(for: colorScheme))
                                                .frame(width: 26, height: 26)
                                                .contentShape(Circle())
                                        }
                                    }
                                }

                                if editingVersionID == member.id {
                                    VStack(spacing: 6) {
                                        TextField("修改人（如：张主任）", text: $editorDraft)
                                            .font(.system(size: 12))
                                            .padding(7)
                                            .background(MobileTheme.inspectorFieldSurface(for: colorScheme), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                                        TextField("改动备注（如：核定第三部分预算）", text: $noteDraft)
                                            .font(.system(size: 12))
                                            .padding(7)
                                            .background(MobileTheme.inspectorFieldSurface(for: colorScheme), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
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
                                                        editorName: ed.isEmpty ? nil : ed,
                                                        changeNote: nt.isEmpty ? nil : nt
                                                    )
                                                }
                                            }
                                            .font(.system(size: 11.5, weight: .semibold))
                                            .foregroundStyle(accent)
                                        }
                                    }
                                    .padding(.top, 2)
                                }
                            }
                            .padding(8)
                            .background(
                                isCurrent
                                    ? MobileTheme.accentSoft(for: colorScheme)
                                    : MobileTheme.inspectorFieldSurface(for: colorScheme),
                                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .strokeBorder(
                                        isCurrent ? accent.opacity(0.42) : MobileTheme.hairline(for: colorScheme),
                                        lineWidth: 0.75
                                    )
                            )
                        }

                        HStack(spacing: 8) {
                            if siblings.count >= 2 {
                                let lastTwo = Array(siblings.suffix(2))
                                Button {
                                    MobileHaptics.light()
                                    onOpenDiff(lastTwo[0].id, lastTwo[1].id)
                                } label: {
                                    Label("对比最近两版", systemImage: "arrow.left.arrow.right")
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(.white)
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 7)
                                        .background(MobileTheme.accentButtonFill(for: colorScheme), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                                }
                                .buttonStyle(MobileTactileButtonStyle())
                            }

                            Button {
                                MobileHaptics.light()
                                onRequestMergeSheet()
                            } label: {
                                Image(systemName: "plus")
                                    .font(.system(size: 12.5, weight: .semibold))
                                    .foregroundStyle(accent)
                                    .frame(width: 32, height: 30)
                                    .background(MobileTheme.accentSoft(for: colorScheme), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                            }
                            .buttonStyle(MobileTactileButtonStyle())
                            .accessibilityLabel("叠入更多版本")
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
                .strokeBorder(MobileTheme.hairline(for: colorScheme), lineWidth: 0.75)
        )
    }
}
