import CharkleCore
import CoreGraphics
import PDFKit
import QuickLook
import SwiftUI
import UIKit

// MARK: - Unified Document Studio Stage (`阅读 | 对比 | 合并`)

enum MobileDocumentStageMode: String, CaseIterable {
    case read = "阅读"
    case diff = "对比"
    case merge = "合并"
}

enum MobileRadarFilter: String, CaseIterable, Identifiable {
    case all = "全部"
    case numberOrCurrency = "数字"
    case dateOrDeadline = "时间"
    case tableMutation = "表格"
    case nativeRevisionOrComment = "批注"

    var id: String { rawValue }

    var riskFlag: DocumentDiffRiskFlag? {
        switch self {
        case .all: nil
        case .numberOrCurrency: .numberOrCurrency
        case .dateOrDeadline: .dateOrDeadline
        case .tableMutation: .tableMutation
        case .nativeRevisionOrComment: .nativeRevisionOrComment
        }
    }
}

/// Hosts native iOS/iPadOS structured & true-layout document reading (`.docx`, `.xlsx`, `.pdf`, `.md/.txt`),
/// single unified header (`阅读 | 对比 | 合成` + compact `vN ▾` menu), Continuous Paper Sheet diff & synchronized
/// iPad 2-column split sheet, Red-Cyan / Split-Curtain scanned PDF diff, and interactive paper 2-Way Merge.
struct MobileDocumentStageView: View {
    @Bindable var store: MobileAppStore
    let asset: AssetRecord
    let initialMode: MobileDocumentStageMode
    let initialComparePair: (baseID: UUID, targetID: UUID)?
    let externalDiffTrigger: MobileDiffLaunchRequest?
    let onSelectVersionAsset: (AssetRecord) -> Void
    let onShareURL: (URL) -> Void
    let onBlockPagingChanged: (Bool) -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    @State private var mode: MobileDocumentStageMode
    @State private var payload: StructuredDocumentPayload?
    @State private var isLoadingPayload: Bool = true
    @State private var payloadError: String?
    @State private var localOriginalURL: URL?

    // Reader sub-states
    @State private var officeReaderMode: OfficeReaderDisplayMode = .trueLayout
    @State private var selectedSheetIndex: Int = 0
    @State private var selectedFormulaDetail: String?
    @State private var showRawTextMode: Bool = false
    @State private var areCommentsExpanded: Bool = true
    @State private var pdfContinuousMode: Bool = true

    private enum OfficeReaderDisplayMode: String, CaseIterable {
        case trueLayout
        case structured
    }

    private enum TextDiffLayoutMode: String, CaseIterable {
        case inlinePaper = "审阅"
        case splitPaper = "双栏"
    }

    // Diff states
    @State private var baseVersionID: UUID
    @State private var targetVersionID: UUID
    @State private var diffReport: DocumentComparisonReport?
    @State private var isLoadingDiff: Bool = false
    @State private var diffError: String?
    @State private var radarFilter: MobileRadarFilter = .all
    @State private var onlyChangedBlocks: Bool = true
    @State private var textDiffLayout: TextDiffLayoutMode = .inlinePaper
    @State private var selectedDiffSheetName: String?
    @State private var selectedPrimaryKeyCol: Int?
    @State private var useOCRIfScanned: Bool = true
    @State private var focusedHunkCursor: Int = 0
    @State private var pdfDiffSubMode: PDFDiffSubMode = .textOrOCR

    // Inline Continuous Paper Merge states (`mergeNoteDraft` strictly defaults to empty `""`)
    @State private var preferTargetAsTemplate: Bool = true
    @State private var mergeChoiceByHunkID: [String: DocumentMergeDecision.Choice] = [:]
    @State private var mergeCustomTextByHunkID: [String: String] = [:]
    @State private var isMergePreviewExpanded: Bool = false
    @State private var mergeEditorDraft: String = ""
    @State private var mergeNoteDraft: String = ""
    @State private var isSynthesizingMerge: Bool = false

    private enum PDFDiffSubMode: String, CaseIterable {
        case textOrOCR = "文本"
        case redCyan = "叠层"
        case splitCurtain = "卷帘"
    }

    init(
        store: MobileAppStore,
        asset: AssetRecord,
        initialMode: MobileDocumentStageMode = .read,
        initialComparePair: (baseID: UUID, targetID: UUID)? = nil,
        externalDiffTrigger: MobileDiffLaunchRequest? = nil,
        onSelectVersionAsset: @escaping (AssetRecord) -> Void,
        onShareURL: @escaping (URL) -> Void,
        onBlockPagingChanged: @escaping (Bool) -> Void
    ) {
        self.store = store
        self.asset = asset
        self.initialMode = initialMode
        self.initialComparePair = initialComparePair
        self.externalDiffTrigger = externalDiffTrigger
        self.onSelectVersionAsset = onSelectVersionAsset
        self.onShareURL = onShareURL
        self.onBlockPagingChanged = onBlockPagingChanged
        _mode = State(initialValue: initialMode)

        let siblings = store.stackMembers(for: asset)
        if let pair = initialComparePair {
            _baseVersionID = State(initialValue: pair.baseID)
            _targetVersionID = State(initialValue: pair.targetID)
        } else if siblings.count >= 2 {
            let lastTwo = Array(siblings.suffix(2))
            _baseVersionID = State(initialValue: lastTwo[0].id)
            _targetVersionID = State(initialValue: lastTwo[1].id)
        } else {
            _baseVersionID = State(initialValue: asset.id)
            _targetVersionID = State(initialValue: asset.id)
        }
    }

    private var stackSiblings: [AssetRecord] {
        store.stackMembers(for: asset)
    }

    private var hasStack: Bool {
        stackSiblings.count > 1
    }

    private var primaryAsset: AssetRecord {
        store.primaryVersionAsset(for: asset)
    }

    private var currentVersionNumber: Int {
        if let explicit = asset.richMetadata?.versionStack?.versionNumber {
            return explicit
        }
        if let idx = stackSiblings.firstIndex(where: { $0.id == asset.id }) {
            return idx + 1
        }
        return 1
    }

    private var fileExtensionLower: String {
        (asset.fileName as NSString).pathExtension.lowercased()
    }

    private var formatFamily: DocumentFormatFamily {
        if let raw = payload?.formatFamily, let parsed = DocumentFormatFamily(rawValue: raw) {
            return parsed
        }
        if let doc = asset.richMetadata?.document {
            return doc.parsedFormatFamily
        }
        return DocumentFormatFamily.detect(fileExtension: fileExtensionLower)
    }

    private var supportsTrueLayoutOfficePreview: Bool {
        let ext = fileExtensionLower
        if [
            "docx", "doc", "wps", "pptx", "ppt", "dps",
            "rtf", "pages", "key", "numbers",
            "odt", "odp", "ods", "xlsx", "xls", "et",
        ].contains(ext) {
            return true
        }
        switch formatFamily {
        case .docx, .pptx, .legacyOffice:
            return true
        case .xlsx:
            return ext != "csv"
        default:
            return false
        }
    }

    private var availableStageModes: [MobileDocumentStageMode] {
        if asset.mediaKind != .document {
            return [.read, .diff]
        }
        return [.read, .diff, .merge]
    }

    private var isInteractiveSpreadsheetGridActive: Bool {
        mode == .read
            && formatFamily == .xlsx
            && (fileExtensionLower == "csv" || officeReaderMode == .structured || localOriginalURL == nil)
    }

    private var shouldBlockOuterPaging: Bool {
        (mode == .diff && (pdfDiffSubMode == .splitCurtain || formatFamily == .xlsx))
            || isInteractiveSpreadsheetGridActive
    }

    var body: some View {
        VStack(spacing: 0) {
            if hasStack || mode != .read {
                unifiedStudioHeaderBar
                    .padding(.horizontal, 12)
                    .padding(.top, 4)
                    .padding(.bottom, 6)
            }

            if mode == .diff && stackSiblings.count >= 2 {
                diffWorkspace
            } else if mode == .merge && stackSiblings.count >= 2 {
                mergeWorkspace
            } else {
                readerWorkspace
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: mode) { _, nextMode in
            onBlockPagingChanged(shouldBlockOuterPaging)
            if nextMode == .diff || nextMode == .merge {
                Task { await reloadDiffReport() }
            }
        }
        .onChange(of: officeReaderMode) { _, _ in
            onBlockPagingChanged(shouldBlockOuterPaging)
        }
        .onChange(of: pdfDiffSubMode) { _, _ in
            onBlockPagingChanged(shouldBlockOuterPaging)
        }
        .onChange(of: externalDiffTrigger) { _, req in
            guard let req else { return }
            baseVersionID = req.baseAssetID
            targetVersionID = req.targetAssetID
            if mode != .diff {
                mode = .diff
            } else {
                Task { await reloadDiffReport() }
            }
        }
        .task(id: asset.id) {
            await loadReaderData(for: asset)
            onBlockPagingChanged(shouldBlockOuterPaging)
            if hasStack, initialComparePair == nil, externalDiffTrigger == nil {
                alignDefaultComparePair(around: asset)
            }
            if (mode == .diff || mode == .merge) && stackSiblings.count >= 2 {
                await reloadDiffReport()
            }
        }
    }

    // MARK: - Single Unified Top Header (`阅读 | 对比 | 合成` + Compact `vN ▾` Menu)

    private var unifiedStudioHeaderBar: some View {
        let pos = MobileTheme.positive(for: colorScheme)
        let warn = MobileTheme.warning(for: colorScheme)
        let newerCount = store.newerThanPrimaryCount(for: asset)

        return HStack(spacing: 8) {
            // Left: Format Badge + Concise Spec
            HStack(spacing: 6) {
                Text(formatFamily.badgeLabel)
                    .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                    .foregroundStyle(MobileTheme.secondaryInk(for: colorScheme))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2.5)
                    .background(
                        MobileTheme.surfaceSubtle(for: colorScheme),
                        in: RoundedRectangle(cornerRadius: 5, style: .continuous)
                    )

                if !conciseHeaderSpec.isEmpty {
                    Text(conciseHeaderSpec)
                        .font(.system(size: 11.5).monospacedDigit())
                        .foregroundStyle(MobileTheme.tertiaryInk(for: colorScheme))
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 4)

            // Compact `vN ▾` Version Dropdown in Reader Mode (Replaces Second Horizontal Pill Bar)
            if hasStack && mode == .read {
                Menu {
                    ForEach(Array(stackSiblings.enumerated().reversed()), id: \.element.id) { idx, item in
                        let verMeta = item.richMetadata?.versionStack
                        let vNum = verMeta?.versionNumber ?? (idx + 1)
                        let isPrimary = item.id == primaryAsset.id
                        let desc = MobileVersionDisplayFormatting.cleanDescriptor(
                            changeNote: verMeta?.changeNote,
                            versionLabel: verMeta?.versionLabel,
                            editorName: verMeta?.editorName
                        )
                        Button {
                            MobileHaptics.light()
                            onSelectVersionAsset(item)
                        } label: {
                            Label(
                                "v\(vNum)" + (desc.map { " · \($0)" } ?? "") + (isPrimary ? "（主版）" : ""),
                                systemImage: item.id == asset.id ? "checkmark" : (isPrimary ? "pin.fill" : "doc.text")
                            )
                        }
                    }

                    if asset.id != primaryAsset.id {
                        Divider()
                        Button {
                            MobileHaptics.success()
                            Task { await store.setPrimaryVersion(assetID: asset.id) }
                        } label: {
                            Label("设当前版为主版本", systemImage: "pin")
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text("v\(currentVersionNumber)")
                            .font(.system(size: 12, weight: .semibold).monospacedDigit())
                            .foregroundStyle(.primary)

                        if asset.id == primaryAsset.id {
                            Text("主版")
                                .font(.system(size: 9.5, weight: .semibold))
                                .foregroundStyle(pos)
                                .padding(.horizontal, 4.5)
                                .padding(.vertical, 1)
                                .background(pos.opacity(0.14), in: RoundedRectangle(cornerRadius: 3.5, style: .continuous))
                        } else if newerCount > 0 {
                            Circle()
                                .fill(warn)
                                .frame(width: 5, height: 5)
                        }

                        Image(systemName: "chevron.down")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(MobileTheme.tertiaryInk(for: colorScheme))
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(
                        MobileTheme.surfaceElevated(for: colorScheme),
                        in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .strokeBorder(MobileTheme.hairline(for: colorScheme), lineWidth: 0.5)
                    )
                }
            }

            // Segmented Mode Control (`阅读 | 对比 | 合成`)
            if stackSiblings.count >= 2 {
                let diffCount = radarCount(for: .all)
                HStack(spacing: 2) {
                    ForEach(availableStageModes, id: \.self) { m in
                        let selected = mode == m
                        Button {
                            MobileHaptics.selection()
                            withAnimation(MobileMotion.accessible(MobileMotion.settleStrong, reduced: reduceMotion)) {
                                mode = m
                            }
                        } label: {
                            HStack(spacing: 3.5) {
                                Text(m.rawValue)
                                    .font(.system(size: 12, weight: selected ? .semibold : .medium))
                                if m == .diff && diffCount > 0 {
                                    Text("\(diffCount)")
                                        .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                                        .foregroundStyle(selected ? .primary : MobileTheme.tertiaryInk(for: colorScheme))
                                }
                            }
                            .foregroundStyle(selected ? .primary : MobileTheme.secondaryInk(for: colorScheme))
                            .padding(.horizontal, 9.5)
                            .padding(.vertical, 4.5)
                            .background(
                                selected ? MobileTheme.surfaceElevated(for: colorScheme) : .clear,
                                in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                            )
                            .shadow(color: .black.opacity(selected ? 0.06 : 0), radius: 2, y: 1)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(2.5)
                .background(
                    MobileTheme.surfaceSubtle(for: colorScheme),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                )
            }
        }
    }

    private var conciseHeaderSpec: String {
        var parts: [String] = []
        let pages = payload?.pageCount ?? asset.richMetadata?.document?.pageCount ?? 0
        let words = payload?.wordCount ?? asset.richMetadata?.document?.wordCount ?? 0
        let sheets = payload?.sheets.count ?? asset.richMetadata?.document?.sheetNames.count ?? 0
        if sheets > 0 {
            parts.append("\(sheets) 表")
        } else if pages > 0 {
            parts.append("\(pages) 页")
        }
        if words > 0 && sheets == 0 {
            parts.append("\(words.formatted()) 字")
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - Mode 1: Native Document Reader Workspace (Zero Instructional Banners)

    @ViewBuilder
    private var readerWorkspace: some View {
        if formatFamily == .pdf {
            pdfReaderStage
        } else if formatFamily == .xlsx && fileExtensionLower != "csv" {
            spreadsheetReaderStage
        } else if supportsTrueLayoutOfficePreview {
            officeReaderStage
        } else if formatFamily == .xlsx {
            spreadsheetReaderStage
        } else if formatFamily == .markdown || formatFamily == .plainText {
            markdownOrTextReaderStage
        } else {
            richBlocksReaderStage
        }
    }

    private func officeModeToggleSegmented(structuredLabel: String) -> some View {
        let commentCount = payload?.comments.count ?? 0

        return HStack(spacing: 2) {
            ForEach(OfficeReaderDisplayMode.allCases, id: \.self) { sub in
                let selected = officeReaderMode == sub
                let title = sub == .trueLayout ? "原版版式" : structuredLabel
                Button {
                    MobileHaptics.selection()
                    withAnimation(MobileMotion.accessible(MobileMotion.settleStrong, reduced: reduceMotion)) {
                        officeReaderMode = sub
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(title)
                            .font(.system(size: 11.5, weight: selected ? .semibold : .medium))
                        if sub == .structured && commentCount > 0 {
                            Text("\(commentCount)")
                                .font(.system(size: 10, weight: .semibold).monospacedDigit())
                                .foregroundStyle(MobileTheme.warning(for: colorScheme))
                        }
                    }
                    .foregroundStyle(selected ? .primary : MobileTheme.secondaryInk(for: colorScheme))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(
                        selected ? MobileTheme.surfaceElevated(for: colorScheme) : .clear,
                        in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                    )
                    .shadow(color: .black.opacity(selected ? 0.06 : 0), radius: 2, y: 1)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2.5)
        .background {
            if reduceTransparency {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(MobileTheme.surfaceSubtle(for: colorScheme))
            } else {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(.ultraThinMaterial)
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(MobileTheme.hairline(for: colorScheme), lineWidth: 0.5)
        )
    }

    private var officeReaderStage: some View {
        VStack(spacing: 6) {
            if localOriginalURL != nil {
                HStack {
                    Spacer()
                    officeModeToggleSegmented(structuredLabel: "正文批注")
                }
                .padding(.horizontal, 12)
            }

            if officeReaderMode == .trueLayout, let localOriginalURL {
                MobileOfficeQLPreviewView(url: localOriginalURL)
                    .clipShape(RoundedRectangle(cornerRadius: MobileTheme.Radius.cardOuter, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: MobileTheme.Radius.cardOuter, style: .continuous)
                            .strokeBorder(MobileTheme.hairline(for: colorScheme), lineWidth: 0.5)
                    )
                    .padding(.horizontal, 12)
                    .padding(.bottom, 10)
            } else if officeReaderMode == .trueLayout && isLoadingPayload {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                richBlocksReaderStage
            }
        }
    }

    private var pdfReaderStage: some View {
        ZStack(alignment: .bottomTrailing) {
            if let localOriginalURL {
                MobileEnhancedPDFKitView(url: localOriginalURL, continuous: pdfContinuousMode)
                    .clipShape(RoundedRectangle(cornerRadius: MobileTheme.Radius.cardOuter, style: .continuous))
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
            } else if isLoadingPayload {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let payload, !payload.plainText.isEmpty {
                richBlocksReaderStage
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            HStack(spacing: 8) {
                let pageCnt = payload?.pageCount ?? asset.richMetadata?.document?.pageCount ?? 0
                let hasText = payload?.hasTextLayer ?? asset.richMetadata?.document?.hasTextLayer ?? true
                if pageCnt > 0 {
                    Text("\(pageCnt) 页")
                        .font(.system(size: 11.5, weight: .medium).monospacedDigit())
                        .foregroundStyle(MobileTheme.secondaryInk(for: colorScheme))
                }
                if !hasText {
                    Text("扫描件")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(MobileTheme.warning(for: colorScheme))
                }

                Button {
                    MobileHaptics.light()
                    pdfContinuousMode.toggle()
                } label: {
                    Text(pdfContinuousMode ? "单页" : "连续")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(MobileTheme.accent(for: colorScheme))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 5.5)
            .charkleFloatingCapsule()
            .padding(.trailing, 20)
            .padding(.bottom, 16)
        }
    }

    private var spreadsheetReaderStage: some View {
        VStack(spacing: 6) {
            if localOriginalURL != nil && supportsTrueLayoutOfficePreview {
                HStack {
                    Spacer()
                    officeModeToggleSegmented(structuredLabel: "数据表格")
                }
                .padding(.horizontal, 12)
            }

            if officeReaderMode == .trueLayout, let localOriginalURL, supportsTrueLayoutOfficePreview {
                MobileOfficeQLPreviewView(url: localOriginalURL)
                    .clipShape(RoundedRectangle(cornerRadius: MobileTheme.Radius.cardOuter, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: MobileTheme.Radius.cardOuter, style: .continuous)
                            .strokeBorder(MobileTheme.hairline(for: colorScheme), lineWidth: 0.5)
                    )
                    .padding(.horizontal, 12)
                    .padding(.bottom, 10)
            } else if isLoadingPayload {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let sheets = payload?.sheets, !sheets.isEmpty {
                let safeIdx = max(0, min(selectedSheetIndex, sheets.count - 1))
                let activeSheet = sheets[safeIdx]

                HStack(spacing: 8) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(Array(sheets.enumerated()), id: \.element.id) { idx, sheet in
                                let selected = idx == safeIdx
                                Button {
                                    MobileHaptics.selection()
                                    selectedSheetIndex = idx
                                    selectedFormulaDetail = nil
                                } label: {
                                    HStack(spacing: 5) {
                                        Image(systemName: "tablecells")
                                            .font(.system(size: 11, weight: .semibold))
                                        Text(sheet.name)
                                            .font(.system(size: 12, weight: selected ? .semibold : .medium))
                                        Text("\(sheet.rows.count)")
                                            .font(.system(size: 10.5).monospacedDigit())
                                            .foregroundStyle(MobileTheme.tertiaryInk(for: colorScheme))
                                    }
                                    .foregroundStyle(selected ? .primary : MobileTheme.secondaryInk(for: colorScheme))
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5.5)
                                    .background(
                                        selected ? MobileTheme.surfaceElevated(for: colorScheme) : MobileTheme.surfaceSubtle(for: colorScheme),
                                        in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    )
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                                            .strokeBorder(MobileTheme.hairline(for: colorScheme), lineWidth: 0.5)
                                    )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }

                    if let selectedFormulaDetail {
                        HStack(spacing: 6) {
                            Text("fx")
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .foregroundStyle(MobileTheme.positive(for: colorScheme))
                            Text(selectedFormulaDetail)
                                .font(.system(size: 11.5, design: .monospaced))
                                .lineLimit(1)
                            Button {
                                UIPasteboard.general.string = selectedFormulaDetail
                                store.showToast("已复制公式", tone: .info)
                            } label: {
                                Image(systemName: "doc.on.doc")
                                    .font(.system(size: 11))
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(MobileTheme.surfaceElevated(for: colorScheme), in: Capsule())
                    }
                }
                .padding(.horizontal, 12)

                ScrollView([.horizontal, .vertical]) {
                    let colCount = max(1, activeSheet.columnCount)
                    VStack(alignment: .leading, spacing: 0) {
                        HStack(spacing: 0) {
                            Text("#")
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .foregroundStyle(MobileTheme.tertiaryInk(for: colorScheme))
                                .frame(width: 44, height: 34)
                                .background(MobileTheme.surfaceSubtle(for: colorScheme))

                            ForEach(0..<colCount, id: \.self) { col in
                                let letter = Self.excelColumnName(col)
                                let headerTitle = col < activeSheet.headers.count ? activeSheet.headers[col] : ""
                                Text(headerTitle.isEmpty ? letter : "\(letter) · \(headerTitle)")
                                    .font(.system(size: 11.5, weight: .semibold))
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                    .padding(.horizontal, 8)
                                    .frame(width: 132, height: 34, alignment: .leading)
                                    .background(MobileTheme.surfaceSubtle(for: colorScheme))
                                    .overlay(alignment: .leading) {
                                        Rectangle()
                                            .fill(MobileTheme.hairline(for: colorScheme))
                                            .frame(width: 0.5)
                                    }
                            }
                        }
                        .overlay(alignment: .bottom) {
                            Rectangle()
                                .fill(MobileTheme.borderStrong(for: colorScheme))
                                .frame(height: 0.5)
                        }

                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(activeSheet.rows) { row in
                                HStack(spacing: 0) {
                                    Text("\(row.rowNumber)")
                                        .font(.system(size: 11, weight: .medium, design: .monospaced).monospacedDigit())
                                        .foregroundStyle(MobileTheme.tertiaryInk(for: colorScheme))
                                        .frame(width: 44, height: 34)
                                        .background(MobileTheme.surfaceSubtle(for: colorScheme).opacity(0.55))

                                    ForEach(0..<colCount, id: \.self) { col in
                                        let val = col < row.values.count ? row.values[col] : ""
                                        let formula = row.formula(at: col)
                                        Button {
                                            if let formula {
                                                MobileHaptics.light()
                                                selectedFormulaDetail = "\(Self.excelColumnName(col))\(row.rowNumber): =\(formula)"
                                            }
                                        } label: {
                                            HStack(spacing: 4) {
                                                Text(val)
                                                    .font(.system(size: 12).monospacedDigit())
                                                    .foregroundStyle(.primary)
                                                    .lineLimit(1)
                                                Spacer(minLength: 0)
                                                if formula != nil {
                                                    Text("fx")
                                                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                                                        .foregroundStyle(MobileTheme.positive(for: colorScheme))
                                                        .padding(.horizontal, 3.5)
                                                        .padding(.vertical, 1)
                                                        .background(
                                                            MobileTheme.positive(for: colorScheme).opacity(0.14),
                                                            in: RoundedRectangle(cornerRadius: 3, style: .continuous)
                                                        )
                                                }
                                            }
                                            .padding(.horizontal, 8)
                                            .frame(width: 132, height: 34, alignment: .leading)
                                            .background(MobileTheme.surfaceElevated(for: colorScheme))
                                            .overlay(alignment: .leading) {
                                                Rectangle()
                                                    .fill(MobileTheme.hairline(for: colorScheme))
                                                    .frame(width: 0.5)
                                            }
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                                .overlay(alignment: .bottom) {
                                    Rectangle()
                                        .fill(MobileTheme.hairline(for: colorScheme))
                                        .frame(height: 0.5)
                                }
                            }
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: MobileTheme.Radius.cardOuter, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: MobileTheme.Radius.cardOuter, style: .continuous)
                            .strokeBorder(MobileTheme.hairline(for: colorScheme), lineWidth: 0.5)
                    )
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)
                }
            } else {
                richBlocksReaderStage
            }
        }
    }

    private var markdownOrTextReaderStage: some View {
        VStack(spacing: 8) {
            HStack {
                Picker("阅读视图", selection: $showRawTextMode) {
                    Text("排版").tag(false)
                    Text("源码").tag(true)
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 168)

                Spacer()

                if let text = payload?.plainText, !text.isEmpty {
                    Button {
                        UIPasteboard.general.string = text
                        MobileHaptics.light()
                        store.showToast("已复制全文", tone: .success)
                    } label: {
                        Label("复制全文", systemImage: "doc.on.doc")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(MobileTheme.accent(for: colorScheme))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(MobileTheme.accentSoft(for: colorScheme), in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 14)

            if showRawTextMode {
                let rawLines = (payload?.plainText ?? "").components(separatedBy: .newlines)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(rawLines.enumerated()), id: \.offset) { idx, line in
                            HStack(alignment: .top, spacing: 10) {
                                Text("\(idx + 1)")
                                    .font(.system(size: 11.5, design: .monospaced).monospacedDigit())
                                    .foregroundStyle(MobileTheme.tertiaryInk(for: colorScheme))
                                    .frame(width: 36, alignment: .trailing)
                                Text(line.isEmpty ? " " : line)
                                    .font(.system(size: 12.5, design: .monospaced))
                                    .foregroundStyle(.primary)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .padding(.vertical, 1)
                        }
                    }
                    .padding(14)
                    .background(
                        MobileTheme.surfaceElevated(for: colorScheme),
                        in: RoundedRectangle(cornerRadius: MobileTheme.Radius.cardOuter, style: .continuous)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: MobileTheme.Radius.cardOuter, style: .continuous)
                            .strokeBorder(MobileTheme.hairline(for: colorScheme), lineWidth: 0.5)
                    )
                    .padding(.horizontal, 14)
                    .padding(.bottom, 16)
                }
            } else {
                richBlocksReaderStage
            }
        }
    }

    private var richBlocksReaderStage: some View {
        ScrollView {
            if isLoadingPayload {
                ProgressView()
                    .padding(.top, 64)
            } else if let payload {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 14) {
                        if payload.isRedHeaderStyle {
                            Rectangle()
                                .fill(MobileTheme.destructive(for: colorScheme))
                                .frame(height: 2.5)
                                .clipShape(Capsule())
                        }

                        if payload.blocks.isEmpty && payload.plainText.isEmpty {
                            VStack(spacing: 8) {
                                Image(systemName: "doc.text")
                                    .font(.system(size: 22))
                                    .foregroundStyle(MobileTheme.tertiaryInk(for: colorScheme))
                                Text(payloadError ?? "暂无可直接提取的正文段落")
                                    .font(.system(size: 13))
                                    .foregroundStyle(MobileTheme.secondaryInk(for: colorScheme))
                                    .multilineTextAlignment(.center)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 32)
                        } else if payload.blocks.isEmpty {
                            Text(payload.plainText)
                                .font(.system(size: 15))
                                .lineSpacing(5)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        } else {
                            ForEach(payload.blocks) { block in
                                documentBlockView(block, allComments: payload.comments)
                            }
                        }
                    }
                    .padding(horizontalSizeClass == .regular ? 28 : 16)
                    .frame(maxWidth: 780, alignment: .leading)
                    .background(
                        MobileTheme.surfaceElevated(for: colorScheme),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(MobileTheme.hairline(for: colorScheme), lineWidth: 0.5)
                    )

                    if !payload.comments.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Button {
                                MobileHaptics.light()
                                withAnimation(MobileMotion.accessible(MobileMotion.settleStrong, reduced: reduceMotion)) {
                                    areCommentsExpanded.toggle()
                                }
                            } label: {
                                HStack {
                                    Label("批注 \(payload.comments.count)", systemImage: "text.bubble")
                                        .font(.system(size: 12.5, weight: .semibold).monospacedDigit())
                                        .foregroundStyle(MobileTheme.secondaryInk(for: colorScheme))
                                    Spacer()
                                    Image(systemName: areCommentsExpanded ? "chevron.up" : "chevron.down")
                                        .font(.system(size: 10.5, weight: .bold))
                                        .foregroundStyle(MobileTheme.tertiaryInk(for: colorScheme))
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)

                            if areCommentsExpanded {
                                ForEach(payload.comments) { comment in
                                    VStack(alignment: .leading, spacing: 4) {
                                        HStack {
                                            Text(comment.author.isEmpty ? "批注" : comment.author)
                                                .font(.system(size: 12, weight: .semibold))
                                            if let date = comment.dateText, !date.isEmpty {
                                                Text(date)
                                                    .font(.system(size: 11).monospacedDigit())
                                                    .foregroundStyle(MobileTheme.tertiaryInk(for: colorScheme))
                                            }
                                            Spacer()
                                        }
                                        if let excerpt = comment.anchorExcerpt, !excerpt.isEmpty {
                                            Text("“\(excerpt)”")
                                                .font(.system(size: 11.5))
                                                .foregroundStyle(MobileTheme.secondaryInk(for: colorScheme))
                                                .padding(.horizontal, 8)
                                                .padding(.vertical, 4)
                                                .background(MobileTheme.surfaceSubtle(for: colorScheme), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                                        }
                                        Text(comment.text)
                                            .font(.system(size: 13))
                                            .textSelection(.enabled)
                                    }
                                    .padding(10)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(
                                        MobileTheme.inspectorFieldSurface(for: colorScheme),
                                        in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    )
                                }
                            }
                        }
                        .padding(14)
                        .frame(maxWidth: 780, alignment: .leading)
                        .background(
                            MobileTheme.surfaceElevated(for: colorScheme),
                            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(MobileTheme.hairline(for: colorScheme), lineWidth: 0.5)
                        )
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 12)
                .padding(.bottom, 20)
            }
        }
    }

    @ViewBuilder
    private func documentBlockView(_ block: DocumentBlock, allComments: [DocumentComment]) -> some View {
        switch block.kind {
        case .heading:
            let level = block.headingLevel ?? 1
            let fontSize: CGFloat = level <= 1 ? 19 : (level == 2 ? 16.5 : 15)
            Text(block.text)
                .font(.system(size: fontSize, weight: .bold))
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .padding(.top, level <= 2 ? 6 : 2)

        case .table:
            if !block.tableRows.isEmpty {
                ScrollView(.horizontal, showsIndicators: true) {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(block.tableRows.enumerated()), id: \.offset) { rIdx, row in
                            HStack(spacing: 0) {
                                ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                                    Text(cell)
                                        .font(.system(size: 12.5, weight: rIdx == 0 ? .semibold : .regular).monospacedDigit())
                                        .foregroundStyle(.primary)
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 7)
                                        .frame(minWidth: 96, maxWidth: 200, alignment: .leading)
                                        .background(
                                            rIdx == 0
                                                ? MobileTheme.surfaceSubtle(for: colorScheme)
                                                : MobileTheme.surfaceElevated(for: colorScheme)
                                        )
                                        .overlay(
                                            Rectangle()
                                                .strokeBorder(MobileTheme.hairline(for: colorScheme), lineWidth: 0.5)
                                        )
                                }
                            }
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(MobileTheme.borderStrong(for: colorScheme), lineWidth: 0.5)
                    )
                }
            }

        case .codeBlock:
            Text(block.text)
                .font(.system(size: 12.5, design: .monospaced))
                .textSelection(.enabled)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    MobileTheme.surfaceSubtle(for: colorScheme),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                )

        case .quote:
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(MobileTheme.accent(for: colorScheme))
                    .frame(width: 3)
                Text(block.text)
                    .font(.system(size: 14))
                    .foregroundStyle(MobileTheme.secondaryInk(for: colorScheme))
                    .textSelection(.enabled)
            }
            .padding(.vertical, 2)

        case .pageBreak:
            HStack {
                Rectangle().fill(MobileTheme.hairline(for: colorScheme)).frame(height: 0.5)
                if let p = block.pageNumber {
                    Text("第 \(p) 页")
                        .font(.system(size: 10.5, weight: .medium).monospacedDigit())
                        .foregroundStyle(MobileTheme.tertiaryInk(for: colorScheme))
                }
                Rectangle().fill(MobileTheme.hairline(for: colorScheme)).frame(height: 0.5)
            }
            .padding(.vertical, 4)

        case .paragraph, .listItem, .slide:
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .top, spacing: 6) {
                    if block.kind == .listItem {
                        Text("•")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(MobileTheme.accent(for: colorScheme))
                    }
                    Text(block.text)
                        .font(.system(size: 15))
                        .lineSpacing(4.5)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                if !block.nativeRevisions.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(block.nativeRevisions) { rev in
                                let isIns = rev.kind == .inserted
                                let tint = isIns ? MobileTheme.positive(for: colorScheme) : MobileTheme.destructive(for: colorScheme)
                                Text("\(isIns ? "+" : "−") \(rev.text)")
                                    .font(.system(size: 11, weight: .medium))
                                    .strikethrough(!isIns)
                                    .foregroundStyle(tint)
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 2)
                                    .background(tint.opacity(0.12), in: Capsule())
                            }
                        }
                    }
                }

                if !block.commentIDs.isEmpty {
                    let matched = allComments.filter { block.commentIDs.contains($0.id) }
                    ForEach(matched) { c in
                        HStack(spacing: 5) {
                            Image(systemName: "text.bubble")
                                .font(.system(size: 10.5, weight: .semibold))
                            Text("\(c.author)：\(c.text)")
                                .font(.system(size: 11.5))
                                .lineLimit(2)
                        }
                        .foregroundStyle(MobileTheme.warning(for: colorScheme))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(MobileTheme.warning(for: colorScheme).opacity(0.12), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
                }
            }
        }
    }

    // MARK: - Mode 2: Continuous Paper Diff & Synchronized 2-Column Split Sheet

    private var filteredDiffHunks: [DocumentDiffHunk] {
        guard let report = diffReport else { return [] }
        return report.hunks.filter { hunk in
            if onlyChangedBlocks && !hunk.changeKind.isChanged && hunk.riskFlags.isEmpty {
                return false
            }
            if let requiredFlag = radarFilter.riskFlag {
                return hunk.riskFlags.contains(requiredFlag)
            }
            return true
        }
    }

    private func radarCount(for filter: MobileRadarFilter) -> Int {
        guard let report = diffReport else {
            if filter == .all {
                return asset.richMetadata?.document?.diffSummary?.totalChangedBlocks ?? 0
            }
            return 0
        }
        switch filter {
        case .all:
            if !report.sheetDiffs.isEmpty {
                return report.sheetDiffs.reduce(0) { $0 + $1.addedRowCount + $1.removedRowCount + $1.modifiedRowCount }
            }
            return report.hunks.filter { $0.changeKind.isChanged }.count
        case .numberOrCurrency:
            return max(
                report.summary.highRiskNumberChanges,
                report.hunks.filter { $0.riskFlags.contains(.numberOrCurrency) }.count
            )
        case .dateOrDeadline:
            return max(
                report.summary.highRiskDateChanges,
                report.hunks.filter { $0.riskFlags.contains(.dateOrDeadline) }.count
            )
        case .tableMutation:
            let hunkTables = report.hunks.filter { $0.riskFlags.contains(.tableMutation) || !$0.tableCellDiffs.isEmpty }.count
            let sheetCells = report.sheetDiffs.reduce(0) { $0 + $1.modifiedRowCount + $1.addedRowCount + $1.removedRowCount }
            return hunkTables + sheetCells
        case .nativeRevisionOrComment:
            return report.commentDiffs.count + report.hunks.filter { $0.riskFlags.contains(.nativeRevisionOrComment) }.count
        }
    }

    private var canSynthesizeTwoWay: Bool {
        guard let report = diffReport else { return false }
        if report.canSynthesizeTwoWay { return true }
        let fam = DocumentFormatFamily(rawValue: report.formatFamily) ?? formatFamily
        return (fam == .docx || fam == .markdown || fam == .plainText)
            && report.hunks.contains(where: { $0.changeKind.isChanged && !$0.isProtectedComplex })
    }

    private var isVisualOrPDFDiffTarget: Bool {
        formatFamily == .pdf || diffReport?.supportsVisualPageOverlay == true || asset.mediaKind != .document
    }

    private var isTextPaperDiffTarget: Bool {
        !isVisualOrPDFDiffTarget && formatFamily != .xlsx && (diffReport?.sheetDiffs.isEmpty ?? true)
    }

    private var diffWorkspace: some View {
        ScrollViewReader { scrollProxy in
            VStack(spacing: 6) {
                slimDiffControlBar(scrollProxy: scrollProxy)
                    .padding(.horizontal, 12)

                if !(isVisualOrPDFDiffTarget && pdfDiffSubMode != .textOrOCR) {
                    compactFilterChipBar
                        .padding(.horizontal, 12)
                }

                if isLoadingDiff {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if (formatFamily == .pdf || asset.mediaKind != .document) && pdfDiffSubMode != .textOrOCR {
                    PDFAndImageVisualOverlayDiffView(
                        store: store,
                        baseAsset: store.liveAsset(id: baseVersionID) ?? asset,
                        targetAsset: store.liveAsset(id: targetVersionID) ?? asset,
                        isSplitCurtain: pdfDiffSubMode == .splitCurtain
                    )
                    .padding(.horizontal, 12)
                    .padding(.bottom, 10)
                } else if let report = diffReport, !report.sheetDiffs.isEmpty || formatFamily == .xlsx {
                    excelSmartPKDiffStage(report: report)
                } else if let report = diffReport {
                    if horizontalSizeClass == .regular && textDiffLayout == .splitPaper {
                        synchronizedTwoColumnSplitSheet(report: report)
                    } else {
                        continuousPaperDiffSheet(report: report)
                    }
                } else if let diffError {
                    Text(diffError)
                        .font(.system(size: 13))
                        .foregroundStyle(MobileTheme.destructive(for: colorScheme))
                        .padding(24)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
    }

    private func slimDiffControlBar(scrollProxy: ScrollViewProxy) -> some View {
        let accent = MobileTheme.accent(for: colorScheme)
        let baseTag = shortVersionTag(id: baseVersionID)
        let targetTag = shortVersionTag(id: targetVersionID)
        let hunks = filteredDiffHunks

        return HStack(spacing: 6) {
            // Base ▾ → Target ▾
            HStack(spacing: 4) {
                Menu {
                    ForEach(stackSiblings) { member in
                        Button(versionLabelForPicker(id: member.id)) {
                            baseVersionID = member.id
                            if baseVersionID == targetVersionID,
                               let alt = stackSiblings.first(where: { $0.id != member.id }) {
                                targetVersionID = alt.id
                            }
                            Task { await reloadDiffReport() }
                        }
                    }
                } label: {
                    HStack(spacing: 3) {
                        Text(baseTag)
                            .font(.system(size: 12, weight: .semibold).monospacedDigit())
                        Image(systemName: "chevron.down")
                            .font(.system(size: 7.5, weight: .bold))
                            .foregroundStyle(MobileTheme.tertiaryInk(for: colorScheme))
                    }
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 8.5)
                    .padding(.vertical, 5)
                    .background(
                        MobileTheme.surfaceElevated(for: colorScheme),
                        in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .strokeBorder(MobileTheme.hairline(for: colorScheme), lineWidth: 0.5)
                    )
                }

                Button {
                    MobileHaptics.light()
                    let tmp = baseVersionID
                    baseVersionID = targetVersionID
                    targetVersionID = tmp
                    Task { await reloadDiffReport() }
                } label: {
                    Image(systemName: "arrow.left.arrow.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(MobileTheme.tertiaryInk(for: colorScheme))
                        .frame(width: 22, height: 24)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("互换对比版本")

                Menu {
                    ForEach(stackSiblings) { member in
                        Button(versionLabelForPicker(id: member.id)) {
                            targetVersionID = member.id
                            if targetVersionID == baseVersionID,
                               let alt = stackSiblings.first(where: { $0.id != member.id }) {
                                baseVersionID = alt.id
                            }
                            Task { await reloadDiffReport() }
                        }
                    }
                } label: {
                    HStack(spacing: 3) {
                        Text(targetTag)
                            .font(.system(size: 12, weight: .semibold).monospacedDigit())
                        Image(systemName: "chevron.down")
                            .font(.system(size: 7.5, weight: .bold))
                            .foregroundStyle(MobileTheme.tertiaryInk(for: colorScheme))
                    }
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 8.5)
                    .padding(.vertical, 5)
                    .background(
                        MobileTheme.surfaceElevated(for: colorScheme),
                        in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .strokeBorder(MobileTheme.hairline(for: colorScheme), lineWidth: 0.5)
                    )
                }
            }

            Spacer(minLength: 4)

            // Layout Switcher (`审阅 | 双栏` on iPad text/Word, or `文本 | 叠层 | 卷帘` on PDF/visual)
            if isVisualOrPDFDiffTarget {
                HStack(spacing: 2) {
                    ForEach(PDFDiffSubMode.allCases, id: \.self) { sub in
                        let active = pdfDiffSubMode == sub
                        Button {
                            MobileHaptics.selection()
                            withAnimation(MobileMotion.accessible(MobileMotion.settleStrong, reduced: reduceMotion)) {
                                pdfDiffSubMode = sub
                            }
                        } label: {
                            Text(sub.rawValue)
                                .font(.system(size: 11.5, weight: active ? .semibold : .medium))
                                .foregroundStyle(active ? .primary : MobileTheme.secondaryInk(for: colorScheme))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(
                                    active ? MobileTheme.surfaceElevated(for: colorScheme) : .clear,
                                    in: RoundedRectangle(cornerRadius: 5.5, style: .continuous)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(2)
                .background(MobileTheme.surfaceSubtle(for: colorScheme), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            } else if horizontalSizeClass == .regular && isTextPaperDiffTarget {
                HStack(spacing: 2) {
                    ForEach(TextDiffLayoutMode.allCases, id: \.self) { layout in
                        let active = textDiffLayout == layout
                        Button {
                            MobileHaptics.selection()
                            withAnimation(MobileMotion.accessible(MobileMotion.settleStrong, reduced: reduceMotion)) {
                                textDiffLayout = layout
                            }
                        } label: {
                            Text(layout.rawValue)
                                .font(.system(size: 11.5, weight: active ? .semibold : .medium))
                                .foregroundStyle(active ? .primary : MobileTheme.secondaryInk(for: colorScheme))
                                .padding(.horizontal, 8.5)
                                .padding(.vertical, 4)
                                .background(
                                    active ? MobileTheme.surfaceElevated(for: colorScheme) : .clear,
                                    in: RoundedRectangle(cornerRadius: 5.5, style: .continuous)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(2)
                .background(MobileTheme.surfaceSubtle(for: colorScheme), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            }

            // Only-Changed Toggle Chip
            if !(isVisualOrPDFDiffTarget && pdfDiffSubMode != .textOrOCR) {
                Button {
                    MobileHaptics.light()
                    withAnimation(MobileMotion.accessible(MobileMotion.settleStrong, reduced: reduceMotion)) {
                        onlyChangedBlocks.toggle()
                    }
                } label: {
                    Text("仅看改动")
                        .font(.system(size: 11.5, weight: onlyChangedBlocks ? .semibold : .medium))
                        .foregroundStyle(onlyChangedBlocks ? accent : MobileTheme.secondaryInk(for: colorScheme))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(
                            onlyChangedBlocks ? MobileTheme.accentSoft(for: colorScheme) : MobileTheme.surfaceSubtle(for: colorScheme),
                            in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                        )
                }
                .buttonStyle(.plain)

                if hunks.count > 1 {
                    HStack(spacing: 2) {
                        Button {
                            guard !hunks.isEmpty else { return }
                            focusedHunkCursor = max(0, focusedHunkCursor - 1)
                            withAnimation(MobileMotion.settleStrong) {
                                scrollProxy.scrollTo(hunks[focusedHunkCursor].id, anchor: .center)
                            }
                        } label: {
                            Image(systemName: "chevron.up")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(MobileTheme.secondaryInk(for: colorScheme))
                                .frame(width: 24, height: 24)
                                .background(MobileTheme.surfaceSubtle(for: colorScheme), in: Circle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("上一处差异")

                        Button {
                            guard !hunks.isEmpty else { return }
                            focusedHunkCursor = min(hunks.count - 1, focusedHunkCursor + 1)
                            withAnimation(MobileMotion.settleStrong) {
                                scrollProxy.scrollTo(hunks[focusedHunkCursor].id, anchor: .center)
                            }
                        } label: {
                            Image(systemName: "chevron.down")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(MobileTheme.secondaryInk(for: colorScheme))
                                .frame(width: 24, height: 24)
                                .background(MobileTheme.surfaceSubtle(for: colorScheme), in: Circle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("下一处差异")
                    }
                }
            }
        }
    }

    private var compactFilterChipBar: some View {
        let accent = MobileTheme.accent(for: colorScheme)
        let visibleFilters = MobileRadarFilter.allCases.filter { filter in
            filter == .all || radarFilter == filter || radarCount(for: filter) > 0
        }

        return HStack(spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 5) {
                    ForEach(visibleFilters) { filter in
                        let count = radarCount(for: filter)
                        let selected = radarFilter == filter

                        Button {
                            MobileHaptics.selection()
                            withAnimation(MobileMotion.accessible(MobileMotion.settleStrong, reduced: reduceMotion)) {
                                radarFilter = filter
                                focusedHunkCursor = 0
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Text(filter.rawValue)
                                    .font(.system(size: 11.5, weight: selected ? .semibold : .medium))
                                Text("\(count)")
                                    .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                                    .foregroundStyle(selected ? accent : MobileTheme.tertiaryInk(for: colorScheme))
                            }
                            .foregroundStyle(selected ? accent : MobileTheme.secondaryInk(for: colorScheme))
                            .padding(.horizontal, 9)
                            .padding(.vertical, 4)
                            .background(
                                selected ? MobileTheme.accentSoft(for: colorScheme) : MobileTheme.surfaceSubtle(for: colorScheme).opacity(0.65),
                                in: Capsule()
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            Spacer(minLength: 4)

            if pdfDiffSubMode == .textOrOCR && formatFamily == .pdf {
                Button {
                    useOCRIfScanned.toggle()
                    Task { await reloadDiffReport() }
                } label: {
                    Text(useOCRIfScanned ? "OCR 开" : "OCR 关")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(MobileTheme.accent(for: colorScheme))
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Continuous Paper Sheet (`审阅` — 3pt Left Margin Status Bar + Inline Fold Dividers)

    private func continuousPaperDiffSheet(report: DocumentComparisonReport) -> some View {
        let hunks = filteredDiffHunks
        let paperShape = RoundedRectangle(cornerRadius: 12, style: .continuous)

        return ScrollView {
            VStack(alignment: .center, spacing: 14) {
                if hunks.isEmpty && (radarFilter != .nativeRevisionOrComment || report.commentDiffs.isEmpty) {
                    VStack(spacing: 8) {
                        Image(systemName: "checkmark.seal")
                            .font(.system(size: 22))
                            .foregroundStyle(MobileTheme.positive(for: colorScheme))
                        Text(radarFilter == .all ? "两版正文一致" : "当前筛选下无差异")
                            .font(.system(size: 13.5, weight: .medium))
                            .foregroundStyle(MobileTheme.secondaryInk(for: colorScheme))
                    }
                    .frame(maxWidth: 780)
                    .padding(.vertical, 48)
                    .background(MobileTheme.surfaceElevated(for: colorScheme), in: paperShape)
                    .overlay(paperShape.strokeBorder(MobileTheme.hairline(for: colorScheme), lineWidth: 0.5))
                } else {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(hunks.enumerated()), id: \.element.id) { idx, hunk in
                            let skippedBefore: Bool = {
                                guard onlyChangedBlocks else { return false }
                                if idx == 0 {
                                    return hunk.hunkIndex > 0
                                }
                                return hunk.hunkIndex > hunks[idx - 1].hunkIndex + 1
                            }()

                            if skippedBefore {
                                paperFoldDivider
                            } else if idx > 0 {
                                Rectangle()
                                    .fill(MobileTheme.hairline(for: colorScheme).opacity(0.65))
                                    .frame(height: 0.5)
                            }

                            let isFocused = idx == focusedHunkCursor && hunks.count > 1
                            continuousPaperHunkRow(hunk: hunk, isFocused: isFocused)
                                .id(hunk.id)
                        }

                        if onlyChangedBlocks,
                           let lastShown = hunks.last,
                           let lastTotal = report.hunks.last,
                           lastShown.hunkIndex < lastTotal.hunkIndex {
                            paperFoldDivider
                        }
                    }
                    .padding(.horizontal, horizontalSizeClass == .regular ? 28 : 16)
                    .padding(.vertical, horizontalSizeClass == .regular ? 20 : 14)
                    .frame(maxWidth: 780, alignment: .leading)
                    .background(MobileTheme.surfaceElevated(for: colorScheme), in: paperShape)
                    .overlay(paperShape.strokeBorder(MobileTheme.hairline(for: colorScheme), lineWidth: 0.5))
                    .shadow(color: .black.opacity(colorScheme == .dark ? 0.22 : 0.035), radius: 8, y: 2)
                }

                if !report.commentDiffs.isEmpty && (radarFilter == .all || radarFilter == .nativeRevisionOrComment) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("批注变动 \(report.commentDiffs.count)")
                            .font(.system(size: 12, weight: .semibold).monospacedDigit())
                            .foregroundStyle(MobileTheme.secondaryInk(for: colorScheme))
                        ForEach(report.commentDiffs) { cDiff in
                            HStack(alignment: .top, spacing: 8) {
                                Text(cDiff.changeKind.localizedLabel)
                                    .font(.system(size: 10.5, weight: .semibold))
                                    .foregroundStyle(changeKindColor(cDiff.changeKind))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 1.5)
                                    .background(changeKindColor(cDiff.changeKind).opacity(0.13), in: Capsule())
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(cDiff.comment.author)
                                        .font(.system(size: 12, weight: .semibold))
                                    Text(cDiff.comment.text)
                                        .font(.system(size: 12.5))
                                        .textSelection(.enabled)
                                }
                            }
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(MobileTheme.surfaceElevated(for: colorScheme), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .strokeBorder(MobileTheme.hairline(for: colorScheme), lineWidth: 0.5)
                            )
                        }
                    }
                    .frame(maxWidth: 780, alignment: .leading)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 12)
            .padding(.top, 4)
            .padding(.bottom, 22)
        }
        .background(MobileTheme.galleryGround(for: colorScheme))
    }

    private var paperFoldDivider: some View {
        HStack(spacing: 8) {
            Rectangle()
                .fill(MobileTheme.hairline(for: colorScheme))
                .frame(height: 0.5)
            Text("⋯ 省略未改动段落")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(MobileTheme.tertiaryInk(for: colorScheme))
                .fixedSize()
            Rectangle()
                .fill(MobileTheme.hairline(for: colorScheme))
                .frame(height: 0.5)
        }
        .padding(.vertical, 9)
    }

    private func continuousPaperHunkRow(hunk: DocumentDiffHunk, isFocused: Bool) -> some View {
        let accent = MobileTheme.accent(for: colorScheme)
        let pos = MobileTheme.positive(for: colorScheme)
        let danger = MobileTheme.destructive(for: colorScheme)
        let warn = MobileTheme.warning(for: colorScheme)

        let barColor: Color = switch hunk.changeKind {
        case .added: pos
        case .removed: danger
        case .modified, .moved: accent
        case .unchanged: .clear
        }

        return HStack(alignment: .top, spacing: 12) {
            // 3pt Left Margin Status Bar
            Capsule(style: .continuous)
                .fill(barColor)
                .frame(width: 3)
                .padding(.vertical, 2)

            VStack(alignment: .leading, spacing: 6) {
                if hunk.changeKind.isChanged {
                    HStack(spacing: 6) {
                        Text("#\(hunk.hunkIndex + 1)")
                            .font(.system(size: 11, weight: .medium, design: .monospaced).monospacedDigit())
                            .foregroundStyle(MobileTheme.tertiaryInk(for: colorScheme))

                        if let sec = hunk.sectionTitle, !sec.isEmpty {
                            Text(sec)
                                .font(.system(size: 11.5, weight: .medium))
                                .foregroundStyle(MobileTheme.secondaryInk(for: colorScheme))
                                .lineLimit(1)
                        } else if let p = hunk.pageNumber {
                            Text("第 \(p) 页")
                                .font(.system(size: 11, weight: .medium).monospacedDigit())
                                .foregroundStyle(MobileTheme.tertiaryInk(for: colorScheme))
                        }

                        if let from = hunk.movedFromIndex {
                            let to = hunk.movedToIndex ?? hunk.targetBlockIndex ?? hunk.hunkIndex
                            Text("↕ 第\(from + 1)→\(to + 1)段")
                                .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                                .foregroundStyle(accent)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1.5)
                                .background(MobileTheme.accentSoft(for: colorScheme), in: Capsule())
                        }

                        ForEach(hunk.highRiskPairs.prefix(2)) { pair in
                            let isNum = pair.flag == .numberOrCurrency
                            let tint = isNum ? danger : warn
                            Text(isNum ? "数字" : "时间")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(tint)
                                .padding(.horizontal, 5.5)
                                .padding(.vertical, 1)
                                .background(tint.opacity(0.12), in: Capsule())
                        }

                        if hunk.isProtectedComplex {
                            HStack(spacing: 2.5) {
                                Image(systemName: "lock.fill")
                                    .font(.system(size: 9))
                                Text("受保护")
                                    .font(.system(size: 10, weight: .medium))
                            }
                            .foregroundStyle(MobileTheme.tertiaryInk(for: colorScheme))
                        }

                        Spacer(minLength: 4)

                        if let copyText = hunk.targetText ?? hunk.baseText, !copyText.isEmpty {
                            Button {
                                UIPasteboard.general.string = copyText
                                MobileHaptics.light()
                                store.showToast("已复制段落", tone: .info)
                            } label: {
                                Image(systemName: "doc.on.doc")
                                    .font(.system(size: 11.5))
                                    .foregroundStyle(MobileTheme.tertiaryInk(for: colorScheme))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                // Paragraph Body Directly on Paper
                if !hunk.inlineTokens.isEmpty {
                    Text(buildInlineDiffAttributedString(tokens: hunk.inlineTokens))
                        .font(.system(size: 14.5))
                        .lineSpacing(5)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else if hunk.changeKind == .unchanged {
                    if let sameText = hunk.targetText ?? hunk.baseText, !sameText.isEmpty {
                        Text(sameText)
                            .font(.system(size: 14.5))
                            .foregroundStyle(.primary)
                            .lineSpacing(5)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        if let oldText = hunk.baseText, !oldText.isEmpty {
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: "minus.circle.fill")
                                    .font(.system(size: 13.5, weight: .semibold))
                                    .foregroundStyle(danger)
                                    .padding(.top, 2)
                                    .accessibilityLabel("修改前")
                                Text(
                                    MobileDiffTokenHighlighter.selectiveSideAttributedString(
                                        hunk: hunk,
                                        side: .base,
                                        isEmphasized: true,
                                        colorScheme: colorScheme
                                    )
                                )
                                .font(.system(size: 14))
                                .lineSpacing(4.5)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }

                        if let newText = hunk.targetText, !newText.isEmpty {
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: "plus.circle.fill")
                                    .font(.system(size: 13.5, weight: .semibold))
                                    .foregroundStyle(pos)
                                    .padding(.top, 2)
                                    .accessibilityLabel("修改后")
                                Text(
                                    MobileDiffTokenHighlighter.selectiveSideAttributedString(
                                        hunk: hunk,
                                        side: .target,
                                        isEmphasized: true,
                                        colorScheme: colorScheme
                                    )
                                )
                                .font(.system(size: 14.5))
                                .lineSpacing(4.5)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                }

                if !hunk.tableCellDiffs.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(hunk.tableCellDiffs) { cell in
                            HStack(spacing: 6) {
                                Text(cell.columnHeader ?? "第 \(cell.rowIndex + 1) 行 · 第 \(cell.colIndex + 1) 列")
                                    .font(.system(size: 11.5, weight: .medium))
                                    .foregroundStyle(MobileTheme.secondaryInk(for: colorScheme))
                                Spacer()
                                if let oldV = cell.oldValue, !oldV.isEmpty {
                                    Text(oldV)
                                        .font(.system(size: 12).monospacedDigit())
                                        .strikethrough()
                                        .foregroundStyle(danger)
                                }
                                Text("→")
                                    .font(.system(size: 11))
                                    .foregroundStyle(MobileTheme.tertiaryInk(for: colorScheme))
                                Text(cell.newValue ?? "（空）")
                                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                                    .foregroundStyle(pos)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(MobileTheme.inspectorFieldSurface(for: colorScheme), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        }
                    }
                }
            }
        }
        .padding(.vertical, 11)
        .padding(.horizontal, 6)
        .background(
            isFocused ? MobileTheme.accentSoft(for: colorScheme).opacity(0.45) : .clear,
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
    }

    // MARK: - Synchronized 2-Column Split Paper on iPad (`双栏`)

    private func synchronizedTwoColumnSplitSheet(report: DocumentComparisonReport) -> some View {
        let hunks = filteredDiffHunks
        let splitShape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        let pos = MobileTheme.positive(for: colorScheme)
        let danger = MobileTheme.destructive(for: colorScheme)
        let baseTag = shortVersionTag(id: baseVersionID)
        let targetTag = shortVersionTag(id: targetVersionID)

        return ScrollView {
            VStack(spacing: 0) {
                // Column Header Row (`− vBase | + vTarget`)
                HStack(spacing: 0) {
                    HStack(spacing: 6) {
                        Image(systemName: "minus.circle.fill")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(danger)
                        Text(baseTag)
                            .font(.system(size: 12, weight: .semibold).monospacedDigit())
                            .foregroundStyle(.primary)
                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .frame(maxWidth: .infinity, minHeight: 34)

                    Rectangle()
                        .fill(MobileTheme.hairline(for: colorScheme))
                        .frame(width: 0.5, height: 34)

                    HStack(spacing: 6) {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(pos)
                        Text(targetTag)
                            .font(.system(size: 12, weight: .semibold).monospacedDigit())
                            .foregroundStyle(.primary)
                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .frame(maxWidth: .infinity, minHeight: 34)
                }
                .background(MobileTheme.surfaceSubtle(for: colorScheme).opacity(0.55))

                Rectangle()
                    .fill(MobileTheme.hairline(for: colorScheme))
                    .frame(height: 0.5)

                if hunks.isEmpty {
                    Text("当前筛选下无差异")
                        .font(.system(size: 13))
                        .foregroundStyle(MobileTheme.secondaryInk(for: colorScheme))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 44)
                } else {
                    ForEach(Array(hunks.enumerated()), id: \.element.id) { idx, hunk in
                        let skippedBefore: Bool = {
                            guard onlyChangedBlocks else { return false }
                            if idx == 0 { return hunk.hunkIndex > 0 }
                            return hunk.hunkIndex > hunks[idx - 1].hunkIndex + 1
                        }()

                        if skippedBefore {
                            paperFoldDivider
                                .padding(.horizontal, 16)
                                .overlay(alignment: .bottom) {
                                    Rectangle()
                                        .fill(MobileTheme.hairline(for: colorScheme))
                                        .frame(height: 0.5)
                                }
                        }

                        HStack(alignment: .top, spacing: 0) {
                            // Left Base Cell
                            Group {
                                if let baseT = hunk.baseText, !baseT.isEmpty {
                                    Text(
                                        MobileDiffTokenHighlighter.selectiveSideAttributedString(
                                            hunk: hunk,
                                            side: .base,
                                            isEmphasized: true,
                                            colorScheme: colorScheme
                                        )
                                    )
                                    .font(.system(size: 13.5))
                                    .lineSpacing(4.5)
                                    .textSelection(.enabled)
                                } else {
                                    Text("—")
                                        .font(.system(size: 12))
                                        .foregroundStyle(MobileTheme.tertiaryInk(for: colorScheme))
                                }
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                            .background(hunk.changeKind.isChanged ? danger.opacity(0.04) : .clear)

                            Rectangle()
                                .fill(MobileTheme.hairline(for: colorScheme))
                                .frame(width: 0.5)

                            // Right Target Cell
                            Group {
                                if let targetT = hunk.targetText, !targetT.isEmpty {
                                    Text(
                                        MobileDiffTokenHighlighter.selectiveSideAttributedString(
                                            hunk: hunk,
                                            side: .target,
                                            isEmphasized: true,
                                            colorScheme: colorScheme
                                        )
                                    )
                                    .font(.system(size: 13.5))
                                    .lineSpacing(4.5)
                                    .textSelection(.enabled)
                                } else {
                                    Text("—")
                                        .font(.system(size: 12))
                                        .foregroundStyle(MobileTheme.tertiaryInk(for: colorScheme))
                                }
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                            .background(hunk.changeKind.isChanged ? pos.opacity(0.04) : .clear)
                        }
                        .id(hunk.id)
                        .overlay(alignment: .bottom) {
                            if idx < hunks.count - 1 {
                                Rectangle()
                                    .fill(MobileTheme.hairline(for: colorScheme))
                                    .frame(height: 0.5)
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: 980)
            .background(MobileTheme.surfaceElevated(for: colorScheme), in: splitShape)
            .clipShape(splitShape)
            .overlay(splitShape.strokeBorder(MobileTheme.hairline(for: colorScheme), lineWidth: 0.5))
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 12)
            .padding(.top, 4)
            .padding(.bottom, 22)
        }
        .background(MobileTheme.galleryGround(for: colorScheme))
    }

    // MARK: - Mode 3: Interactive Continuous Paper Merge (`合成`)

    private var changedHunksForMerge: [DocumentDiffHunk] {
        diffReport?.hunks.filter { $0.changeKind.isChanged } ?? []
    }

    private var compiledInlineMergeDecisions: [DocumentMergeDecision] {
        let fallbackChoice: DocumentMergeDecision.Choice = preferTargetAsTemplate ? .acceptTarget : .keepBase
        return changedHunksForMerge.compactMap { hunk in
            guard !hunk.isProtectedComplex else { return nil }
            let choice = mergeChoiceByHunkID[hunk.id] ?? fallbackChoice
            let custom = choice == .customText
                ? (mergeCustomTextByHunkID[hunk.id] ?? hunk.targetText ?? hunk.baseText ?? "")
                : nil
            return DocumentMergeDecision(hunkID: hunk.id, choice: choice, customText: custom)
        }
    }

    private var nextMergeVersionNumber: Int {
        (stackSiblings.compactMap { $0.richMetadata?.versionStack?.versionNumber }.max() ?? stackSiblings.count) + 1
    }

    private var mergeWorkspace: some View {
        let accent = MobileTheme.accent(for: colorScheme)
        let pos = MobileTheme.positive(for: colorScheme)
        let danger = MobileTheme.destructive(for: colorScheme)
        let warn = MobileTheme.warning(for: colorScheme)
        let baseTag = shortVersionTag(id: baseVersionID)
        let targetTag = shortVersionTag(id: targetVersionID)
        let paperShape = RoundedRectangle(cornerRadius: 12, style: .continuous)

        return VStack(spacing: 0) {
            if isLoadingDiff && diffReport == nil {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let report = diffReport, !canSynthesizeTwoWay {
                VStack(spacing: 12) {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(MobileTheme.tertiaryInk(for: colorScheme))
                    Text(report.synthesisUnavailableReason ?? "当前格式仅支持只读对比")
                        .font(.system(size: 13.5, weight: .medium))
                        .foregroundStyle(MobileTheme.secondaryInk(for: colorScheme))
                        .multilineTextAlignment(.center)
                    Button {
                        Task {
                            if let url = await store.shareableOriginalURL(for: asset, preferExactAsset: true) {
                                onShareURL(url)
                            }
                        }
                    } label: {
                        Label("使用系统应用打开", systemImage: "square.and.arrow.up")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(accent)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(MobileTheme.accentSoft(for: colorScheme), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(MobileTheme.galleryGround(for: colorScheme))
            } else if let report = diffReport {
                // Slim 38pt Merge Template Bar
                HStack(spacing: 8) {
                    Text("底稿")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(MobileTheme.secondaryInk(for: colorScheme))

                    HStack(spacing: 2) {
                        Button {
                            MobileHaptics.selection()
                            preferTargetAsTemplate = true
                        } label: {
                            Text("以新版为准")
                                .font(.system(size: 11.5, weight: preferTargetAsTemplate ? .semibold : .medium))
                                .foregroundStyle(preferTargetAsTemplate ? .primary : MobileTheme.secondaryInk(for: colorScheme))
                                .padding(.horizontal, 9)
                                .padding(.vertical, 4)
                                .background(
                                    preferTargetAsTemplate ? MobileTheme.surfaceElevated(for: colorScheme) : .clear,
                                    in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                                )
                        }
                        .buttonStyle(.plain)

                        Button {
                            MobileHaptics.selection()
                            preferTargetAsTemplate = false
                        } label: {
                            Text("以旧版为准")
                                .font(.system(size: 11.5, weight: !preferTargetAsTemplate ? .semibold : .medium))
                                .foregroundStyle(!preferTargetAsTemplate ? .primary : MobileTheme.secondaryInk(for: colorScheme))
                                .padding(.horizontal, 9)
                                .padding(.vertical, 4)
                                .background(
                                    !preferTargetAsTemplate ? MobileTheme.surfaceElevated(for: colorScheme) : .clear,
                                    in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(2)
                    .background(MobileTheme.surfaceSubtle(for: colorScheme), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

                    Spacer()

                    Text("\(changedHunksForMerge.count) 处差异")
                        .font(.system(size: 11.5, weight: .medium).monospacedDigit())
                        .foregroundStyle(MobileTheme.secondaryInk(for: colorScheme))
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 6)

                // Continuous Paper Sheet Choice Flow
                ScrollView {
                    VStack(alignment: .center, spacing: 14) {
                        VStack(alignment: .leading, spacing: 0) {
                            if changedHunksForMerge.isEmpty {
                                Text("两版无差异段落")
                                    .font(.system(size: 13.5))
                                    .foregroundStyle(MobileTheme.secondaryInk(for: colorScheme))
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 36)
                            } else {
                                ForEach(Array(changedHunksForMerge.enumerated()), id: \.element.id) { idx, hunk in
                                    let skippedBefore = idx == 0
                                        ? hunk.hunkIndex > 0
                                        : hunk.hunkIndex > changedHunksForMerge[idx - 1].hunkIndex + 1

                                    if skippedBefore {
                                        paperFoldDivider
                                    } else if idx > 0 {
                                        Rectangle()
                                            .fill(MobileTheme.hairline(for: colorScheme))
                                            .frame(height: 0.5)
                                    }

                                    let activeChoice = mergeChoiceByHunkID[hunk.id]
                                        ?? (preferTargetAsTemplate ? .acceptTarget : .keepBase)

                                    VStack(alignment: .leading, spacing: 8) {
                                        HStack(spacing: 6) {
                                            Text("#\(idx + 1)")
                                                .font(.system(size: 11, weight: .medium, design: .monospaced).monospacedDigit())
                                                .foregroundStyle(MobileTheme.tertiaryInk(for: colorScheme))

                                            if let sec = hunk.sectionTitle, !sec.isEmpty {
                                                Text(sec)
                                                    .font(.system(size: 11.5, weight: .medium))
                                                    .foregroundStyle(MobileTheme.secondaryInk(for: colorScheme))
                                                    .lineLimit(1)
                                            }

                                            ForEach(hunk.highRiskPairs.prefix(1)) { pair in
                                                let isNum = pair.flag == .numberOrCurrency
                                                Text(isNum ? "数字" : "时间")
                                                    .font(.system(size: 10, weight: .semibold))
                                                    .foregroundStyle(isNum ? danger : warn)
                                                    .padding(.horizontal, 5)
                                                    .padding(.vertical, 1)
                                                    .background((isNum ? danger : warn).opacity(0.12), in: Capsule())
                                            }

                                            Spacer(minLength: 4)

                                            if hunk.isProtectedComplex {
                                                HStack(spacing: 6) {
                                                    Label("受保护结构", systemImage: "lock.fill")
                                                        .font(.system(size: 10.5, weight: .medium))
                                                        .foregroundStyle(MobileTheme.tertiaryInk(for: colorScheme))
                                                    Button("打开") {
                                                        let ref = preferTargetAsTemplate
                                                            ? (store.liveAsset(id: targetVersionID) ?? asset)
                                                            : (store.liveAsset(id: baseVersionID) ?? asset)
                                                        Task {
                                                            if let url = await store.shareableOriginalURL(for: ref, preferExactAsset: true) {
                                                                onShareURL(url)
                                                            }
                                                        }
                                                    }
                                                    .font(.system(size: 11, weight: .semibold))
                                                    .foregroundStyle(accent)
                                                    .buttonStyle(.plain)
                                                }
                                            } else {
                                                HStack(spacing: 2) {
                                                    mergeChoicePill(
                                                        title: "保留 \(baseTag)",
                                                        active: activeChoice == .keepBase
                                                    ) {
                                                        mergeChoiceByHunkID[hunk.id] = .keepBase
                                                    }
                                                    mergeChoicePill(
                                                        title: "采纳 \(targetTag)",
                                                        active: activeChoice == .acceptTarget
                                                    ) {
                                                        mergeChoiceByHunkID[hunk.id] = .acceptTarget
                                                    }
                                                    mergeChoicePill(
                                                        title: "微调",
                                                        active: activeChoice == .customText
                                                    ) {
                                                        mergeChoiceByHunkID[hunk.id] = .customText
                                                        if mergeCustomTextByHunkID[hunk.id] == nil {
                                                            mergeCustomTextByHunkID[hunk.id] = hunk.targetText ?? hunk.baseText ?? ""
                                                        }
                                                    }
                                                }
                                                .padding(2)
                                                .background(
                                                    MobileTheme.surfaceSubtle(for: colorScheme),
                                                    in: RoundedRectangle(cornerRadius: 6.5, style: .continuous)
                                                )
                                            }
                                        }

                                        // Direct Tap-to-Pick Version Rows
                                        if let oldT = hunk.baseText, !oldT.isEmpty {
                                            let isChosen = !hunk.isProtectedComplex && activeChoice == .keepBase
                                            Button {
                                                guard !hunk.isProtectedComplex else { return }
                                                MobileHaptics.selection()
                                                mergeChoiceByHunkID[hunk.id] = .keepBase
                                            } label: {
                                                HStack(alignment: .top, spacing: 8) {
                                                    Image(systemName: "minus.circle.fill")
                                                        .font(.system(size: 13.5, weight: .semibold))
                                                        .foregroundStyle(danger)
                                                        .padding(.top, 2)
                                                        .accessibilityLabel("修改前")
                                                    Text(
                                                        MobileDiffTokenHighlighter.selectiveSideAttributedString(
                                                            hunk: hunk,
                                                            side: .base,
                                                            isEmphasized: isChosen,
                                                            colorScheme: colorScheme
                                                        )
                                                    )
                                                    .font(.system(size: 13.5))
                                                    .lineSpacing(4)
                                                    .multilineTextAlignment(.leading)
                                                    .frame(maxWidth: .infinity, alignment: .leading)

                                                    if isChosen {
                                                        Image(systemName: "checkmark.circle.fill")
                                                            .font(.system(size: 14, weight: .semibold))
                                                            .foregroundStyle(accent)
                                                            .padding(.top, 2)
                                                    }
                                                }
                                                .padding(.horizontal, 10)
                                                .padding(.vertical, 8)
                                                .background(
                                                    isChosen ? MobileTheme.accentSoft(for: colorScheme) : .clear,
                                                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                                                )
                                                .overlay(
                                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                                        .strokeBorder(
                                                            isChosen ? accent.opacity(0.50) : MobileTheme.hairline(for: colorScheme),
                                                            lineWidth: isChosen ? 1.0 : 0.5
                                                        )
                                                )
                                                .opacity(hunk.isProtectedComplex ? 0.72 : (isChosen ? 1.0 : 0.48))
                                            }
                                            .buttonStyle(.plain)
                                        }

                                        if let newT = hunk.targetText, !newT.isEmpty {
                                            let isChosen = !hunk.isProtectedComplex && activeChoice == .acceptTarget
                                            Button {
                                                guard !hunk.isProtectedComplex else { return }
                                                MobileHaptics.selection()
                                                mergeChoiceByHunkID[hunk.id] = .acceptTarget
                                            } label: {
                                                HStack(alignment: .top, spacing: 8) {
                                                    Image(systemName: "plus.circle.fill")
                                                        .font(.system(size: 13.5, weight: .semibold))
                                                        .foregroundStyle(pos)
                                                        .padding(.top, 2)
                                                        .accessibilityLabel("修改后")
                                                    Text(
                                                        MobileDiffTokenHighlighter.selectiveSideAttributedString(
                                                            hunk: hunk,
                                                            side: .target,
                                                            isEmphasized: isChosen,
                                                            colorScheme: colorScheme
                                                        )
                                                    )
                                                    .font(.system(size: 13.5))
                                                    .lineSpacing(4)
                                                    .multilineTextAlignment(.leading)
                                                    .frame(maxWidth: .infinity, alignment: .leading)

                                                    if isChosen {
                                                        Image(systemName: "checkmark.circle.fill")
                                                            .font(.system(size: 14, weight: .semibold))
                                                            .foregroundStyle(accent)
                                                            .padding(.top, 2)
                                                    }
                                                }
                                                .padding(.horizontal, 10)
                                                .padding(.vertical, 8)
                                                .background(
                                                    isChosen ? MobileTheme.accentSoft(for: colorScheme) : .clear,
                                                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                                                )
                                                .overlay(
                                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                                        .strokeBorder(
                                                            isChosen ? accent.opacity(0.50) : MobileTheme.hairline(for: colorScheme),
                                                            lineWidth: isChosen ? 1.0 : 0.5
                                                        )
                                                )
                                                .opacity(hunk.isProtectedComplex ? 0.72 : (isChosen ? 1.0 : 0.48))
                                            }
                                            .buttonStyle(.plain)
                                        }

                                        if !hunk.isProtectedComplex && activeChoice == .customText {
                                            TextField(
                                                "输入微调后的段落正文…",
                                                text: Binding(
                                                    get: { mergeCustomTextByHunkID[hunk.id] ?? hunk.targetText ?? hunk.baseText ?? "" },
                                                    set: { mergeCustomTextByHunkID[hunk.id] = $0 }
                                                ),
                                                axis: .vertical
                                            )
                                            .lineLimit(2...6)
                                            .font(.system(size: 13.5))
                                            .padding(9)
                                            .background(
                                                MobileTheme.inspectorFieldSurface(for: colorScheme),
                                                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                                            )
                                            .overlay(
                                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                                    .strokeBorder(accent.opacity(0.45), lineWidth: 1)
                                            )
                                        }
                                    }
                                    .padding(.vertical, 12)
                                }
                            }

                            // Collapsible Clean Preview at Bottom of Paper Sheet
                            Rectangle()
                                .fill(MobileTheme.hairline(for: colorScheme))
                                .frame(height: 0.5)
                                .padding(.top, 4)

                            Button {
                                MobileHaptics.light()
                                withAnimation(MobileMotion.accessible(MobileMotion.settleStrong, reduced: reduceMotion)) {
                                    isMergePreviewExpanded.toggle()
                                }
                            } label: {
                                HStack {
                                    Text("合并预览")
                                        .font(.system(size: 12.5, weight: .semibold))
                                        .foregroundStyle(.primary)
                                    Spacer()
                                    Image(systemName: isMergePreviewExpanded ? "chevron.up" : "chevron.down")
                                        .font(.system(size: 10.5, weight: .bold))
                                        .foregroundStyle(MobileTheme.tertiaryInk(for: colorScheme))
                                }
                                .padding(.vertical, 11)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)

                            if isMergePreviewExpanded {
                                let mergedPreview = report.previewMergedText(
                                    preferTargetAsTemplate: preferTargetAsTemplate,
                                    decisions: compiledInlineMergeDecisions
                                )
                                Text(mergedPreview.isEmpty ? "（无正文内容）" : mergedPreview)
                                    .font(.system(size: 14))
                                    .lineSpacing(4.5)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(12)
                                    .background(
                                        MobileTheme.inspectorFieldSurface(for: colorScheme),
                                        in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    )
                                    .padding(.bottom, 8)
                            }
                        }
                        .padding(.horizontal, horizontalSizeClass == .regular ? 28 : 16)
                        .padding(.vertical, 12)
                        .frame(maxWidth: 780, alignment: .leading)
                        .background(MobileTheme.surfaceElevated(for: colorScheme), in: paperShape)
                        .overlay(paperShape.strokeBorder(MobileTheme.hairline(for: colorScheme), lineWidth: 0.5))
                        .shadow(color: .black.opacity(colorScheme == .dark ? 0.22 : 0.035), radius: 8, y: 2)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 12)
                    .padding(.top, 4)
                    .padding(.bottom, 16)
                }
                .charkleDismissKeyboardOnScroll()
                .background(MobileTheme.galleryGround(for: colorScheme))

                // Clean Bottom Merge Footer (`修改人` + `备注（可选）` + `生成 vN`)
                HStack(spacing: 8) {
                    TextField("修改人", text: $mergeEditorDraft)
                        .font(.system(size: 12.5))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 7.5)
                        .frame(maxWidth: 96)
                        .background(
                            MobileTheme.inspectorFieldSurface(for: colorScheme),
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(MobileTheme.hairline(for: colorScheme), lineWidth: 0.5)
                        )

                    TextField("备注（可选）", text: $mergeNoteDraft)
                        .font(.system(size: 12.5))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7.5)
                        .frame(maxWidth: 240)
                        .background(
                            MobileTheme.inspectorFieldSurface(for: colorScheme),
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(MobileTheme.hairline(for: colorScheme), lineWidth: 0.5)
                        )

                    Spacer(minLength: 4)

                    Button {
                        synthesizeInlineMerge(report: report)
                    } label: {
                        HStack(spacing: 5) {
                            if isSynthesizingMerge {
                                ProgressView().controlSize(.mini).tint(.white)
                            }
                            Text("保存为新版本 (v\(nextMergeVersionNumber))")
                                .font(.system(size: 13, weight: .semibold).monospacedDigit())
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(
                            MobileTheme.accentButtonFill(for: colorScheme),
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                        )
                    }
                    .buttonStyle(MobileTactileButtonStyle())
                    .disabled(isSynthesizingMerge)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(MobileTheme.surfaceElevated(for: colorScheme))
                .overlay(alignment: .top) {
                    Rectangle()
                        .fill(MobileTheme.hairline(for: colorScheme))
                        .frame(height: 0.5)
                }
            }
        }
    }

    private func mergeChoicePill(title: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button {
            MobileHaptics.selection()
            action()
        } label: {
            Text(title)
                .font(.system(size: 11, weight: active ? .semibold : .medium).monospacedDigit())
                .foregroundStyle(active ? .primary : MobileTheme.secondaryInk(for: colorScheme))
                .padding(.horizontal, 7.5)
                .padding(.vertical, 3.5)
                .background(
                    active ? MobileTheme.surfaceElevated(for: colorScheme) : .clear,
                    in: RoundedRectangle(cornerRadius: 5, style: .continuous)
                )
        }
        .buttonStyle(.plain)
    }

    private func synthesizeInlineMerge(report: DocumentComparisonReport) {
        guard !isSynthesizingMerge else { return }
        isSynthesizingMerge = true
        MobileKeyboard.dismiss()
        let ed = mergeEditorDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let noteRaw = mergeNoteDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let decisions = compiledInlineMergeDecisions
        let preferTarget = preferTargetAsTemplate
        let createdVer = nextMergeVersionNumber

        Task {
            do {
                let created = try await store.engine.synthesizeDocumentVersion(
                    baseAssetID: report.baseAssetID,
                    targetAssetID: report.targetAssetID,
                    preferTargetAsTemplate: preferTarget,
                    decisions: decisions,
                    editorName: (ed.isEmpty || ed == "本机") ? nil : ed,
                    changeNote: noteRaw.isEmpty ? nil : noteRaw
                )
                _ = try? await store.engine.manageVersionStack(.setPrimary(assetID: created.id))
                await store.reloadAll()
                MobileHaptics.success()
                mergeNoteDraft = ""
                let resolvedCreated = store.liveAsset(id: created.id) ?? created
                store.showToast("已生成 v\(createdVer)", tone: .success)
                if store.hasConnectedCloudBackend {
                    Task { await store.syncNow(quiet: true) }
                }
                mode = .read
                onSelectVersionAsset(resolvedCreated)
            } catch {
                MobileHaptics.error()
                store.showToast("生成失败：\(error.localizedDescription)", tone: .error)
            }
            isSynthesizingMerge = false
        }
    }

    // MARK: - Inline Token Highlighter & Excel Smart PK Diff Stage

    private func buildInlineDiffAttributedString(tokens: [DocumentInlineDiffToken]) -> AttributedString {
        var result = AttributedString()
        let posUIColor = UIColor(MobileTheme.positive(for: colorScheme))
        let delUIColor = UIColor(MobileTheme.destructive(for: colorScheme))

        for token in tokens {
            var seg = AttributedString(token.text)
            switch token.kind {
            case .equal:
                break
            case .inserted:
                seg.foregroundColor = posUIColor
                seg.backgroundColor = posUIColor.withAlphaComponent(0.14)
                if token.isHighRiskNumber || token.isHighRiskDate {
                    seg.inlinePresentationIntent = .stronglyEmphasized
                }
            case .deleted:
                seg.foregroundColor = delUIColor
                seg.backgroundColor = delUIColor.withAlphaComponent(0.12)
                seg.strikethroughStyle = .single
            }
            result.append(seg)
        }
        return result
    }

    private func excelSmartPKDiffStage(report: DocumentComparisonReport) -> some View {
        let sheets = report.sheetDiffs
        let activeSheet: SpreadsheetSheetDiff? = {
            if let name = selectedDiffSheetName, let found = sheets.first(where: { $0.sheetName == name }) {
                return found
            }
            return sheets.first
        }()

        return VStack(spacing: 8) {
            if !sheets.isEmpty {
                HStack(spacing: 8) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(sheets) { sheet in
                                let isOn = sheet.sheetName == activeSheet?.sheetName
                                let totalRowDelta = sheet.addedRowCount + sheet.removedRowCount + sheet.modifiedRowCount
                                Button {
                                    MobileHaptics.selection()
                                    selectedDiffSheetName = sheet.sheetName
                                    selectedPrimaryKeyCol = nil
                                } label: {
                                    HStack(spacing: 4) {
                                        Text(sheet.sheetName)
                                            .font(.system(size: 12, weight: isOn ? .semibold : .medium))
                                        if totalRowDelta > 0 {
                                            Text("Δ\(totalRowDelta)")
                                                .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                                                .foregroundStyle(MobileTheme.secondaryInk(for: colorScheme))
                                        }
                                    }
                                    .foregroundStyle(isOn ? .primary : MobileTheme.secondaryInk(for: colorScheme))
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .background(
                                        isOn ? MobileTheme.surfaceElevated(for: colorScheme) : MobileTheme.surfaceSubtle(for: colorScheme),
                                        in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    )
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                                            .strokeBorder(MobileTheme.hairline(for: colorScheme), lineWidth: 0.5)
                                    )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }

                    if let activeSheet, !activeSheet.headers.isEmpty {
                        Menu {
                            Button("自动识别主键列") {
                                selectedPrimaryKeyCol = nil
                                selectedDiffSheetName = activeSheet.sheetName
                                Task { await reloadDiffReport() }
                            }
                            Divider()
                            ForEach(Array(activeSheet.headers.enumerated()), id: \.offset) { colIdx, hdr in
                                Button("\(Self.excelColumnName(colIdx)) · \(hdr.isEmpty ? "第\(colIdx + 1)列" : hdr)") {
                                    selectedPrimaryKeyCol = colIdx
                                    selectedDiffSheetName = activeSheet.sheetName
                                    Task { await reloadDiffReport() }
                                }
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "key.fill")
                                    .font(.system(size: 10))
                                Text("主键：\(activeSheet.primaryKeyHeader ?? "自动")")
                                    .font(.system(size: 11.5, weight: .semibold))
                                    .lineLimit(1)
                            }
                            .foregroundStyle(MobileTheme.secondaryInk(for: colorScheme))
                            .padding(.horizontal, 9)
                            .padding(.vertical, 5)
                            .background(MobileTheme.surfaceSubtle(for: colorScheme), in: Capsule())
                        }
                    }
                }
                .padding(.horizontal, 12)
            }

            ScrollView {
                if let activeSheet {
                    let rows = activeSheet.rowDiffs.filter { row in
                        if onlyChangedBlocks && !row.changeKind.isChanged { return false }
                        if let flag = radarFilter.riskFlag {
                            if flag == .tableMutation { return row.changeKind.isChanged }
                            return row.riskFlags.contains(flag)
                        }
                        return true
                    }

                    let sheetShape = RoundedRectangle(cornerRadius: 12, style: .continuous)
                    VStack(alignment: .leading, spacing: 0) {
                        if rows.isEmpty {
                            Text("当前筛选下无单元格变动")
                                .font(.system(size: 13))
                                .foregroundStyle(MobileTheme.secondaryInk(for: colorScheme))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 44)
                        } else {
                            ForEach(Array(rows.enumerated()), id: \.element.id) { idx, row in
                                spreadsheetRowDiffItem(row, headers: activeSheet.headers)
                                if idx < rows.count - 1 {
                                    Rectangle()
                                        .fill(MobileTheme.hairline(for: colorScheme))
                                        .frame(height: 0.5)
                                }
                            }
                        }
                    }
                    .frame(maxWidth: 820, alignment: .leading)
                    .background(MobileTheme.surfaceElevated(for: colorScheme), in: sheetShape)
                    .overlay(sheetShape.strokeBorder(MobileTheme.hairline(for: colorScheme), lineWidth: 0.5))
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 20)
                }
            }
            .background(MobileTheme.galleryGround(for: colorScheme))
        }
    }

    private func spreadsheetRowDiffItem(_ row: SpreadsheetRowDiff, headers: [String]) -> some View {
        let kindTint = changeKindColor(row.changeKind)
        let danger = MobileTheme.destructive(for: colorScheme)
        let pos = MobileTheme.positive(for: colorScheme)

        return HStack(alignment: .top, spacing: 10) {
            Capsule(style: .continuous)
                .fill(kindTint)
                .frame(width: 3)
                .padding(.vertical, 2)

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(row.primaryKeyValue.isEmpty ? "行记录" : row.primaryKeyValue)
                        .font(.system(size: 13, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    Spacer()

                    let rowLoc: String = {
                        switch (row.baseRowNumber, row.targetRowNumber) {
                        case let (b?, t?) where b != t: "#\(b) → #\(t)"
                        case let (_, t?): "#\(t)"
                        case let (b?, nil): "#\(b)"
                        default: ""
                        }
                    }()
                    if !rowLoc.isEmpty {
                        Text(rowLoc)
                            .font(.system(size: 11, design: .monospaced).monospacedDigit())
                            .foregroundStyle(MobileTheme.tertiaryInk(for: colorScheme))
                    }
                }

                if !row.cellDiffs.isEmpty {
                    ForEach(row.cellDiffs) { cell in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                let colName = cell.columnHeader ?? (cell.colIndex < headers.count ? headers[cell.colIndex] : Self.excelColumnName(cell.colIndex))
                                Text(colName.isEmpty ? Self.excelColumnName(cell.colIndex) : colName)
                                    .font(.system(size: 11.5, weight: .medium))
                                    .foregroundStyle(MobileTheme.secondaryInk(for: colorScheme))

                                Spacer()

                                if let oldVal = cell.oldValue, !oldVal.isEmpty {
                                    Text(oldVal)
                                        .font(.system(size: 12.5).monospacedDigit())
                                        .strikethrough()
                                        .foregroundStyle(danger)
                                }
                                if cell.oldValue != nil && cell.newValue != nil {
                                    Text("→")
                                        .font(.system(size: 11))
                                        .foregroundStyle(MobileTheme.tertiaryInk(for: colorScheme))
                                }
                                if let newVal = cell.newValue, !newVal.isEmpty {
                                    Text(newVal)
                                        .font(.system(size: 12.5, weight: .semibold).monospacedDigit())
                                        .foregroundStyle(pos)
                                }
                            }

                            if cell.oldFormula != cell.newFormula, (cell.oldFormula != nil || cell.newFormula != nil) {
                                Text("fx =\(cell.oldFormula ?? "无") → =\(cell.newFormula ?? "无")")
                                    .font(.system(size: 10.5, design: .monospaced))
                                    .foregroundStyle(MobileTheme.warning(for: colorScheme))
                            }
                        }
                    }
                } else {
                    let values = !row.targetValues.isEmpty ? row.targetValues : row.baseValues
                    Text(values.filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.system(size: 12.5).monospacedDigit())
                        .foregroundStyle(row.changeKind == .removed ? danger : .primary)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    // MARK: - Data Loading Helpers

    private func loadReaderData(for target: AssetRecord) async {
        isLoadingPayload = true
        payloadError = nil
        selectedSheetIndex = 0
        selectedFormulaDetail = nil
        let targetExt = (target.fileName as NSString).pathExtension.lowercased()
        let detectedFamily = target.richMetadata?.document?.parsedFormatFamily
            ?? DocumentFormatFamily.detect(fileExtension: targetExt)
        officeReaderMode = (detectedFamily == .xlsx && targetExt != "csv") ? .structured : .trueLayout

        async let fetchedURL = try? store.engine.originalURL(for: target.id)
        async let structuredResult: Result<StructuredDocumentPayload, Error> = {
            do {
                return .success(try await store.engine.readStructuredDocument(assetID: target.id))
            } catch {
                return .failure(error)
            }
        }()

        let (resolvedURL, resolvedPayload) = await (fetchedURL, structuredResult)
        guard !Task.isCancelled else { return }
        localOriginalURL = resolvedURL
        switch resolvedPayload {
        case .success(let doc):
            payload = doc
        case .failure(let err):
            payloadError = err.localizedDescription
        }
        isLoadingPayload = false
    }

    private func alignDefaultComparePair(around current: AssetRecord) {
        guard stackSiblings.count >= 2 else { return }
        if let idx = stackSiblings.firstIndex(where: { $0.id == current.id }), idx > 0 {
            baseVersionID = stackSiblings[idx - 1].id
            targetVersionID = current.id
        } else {
            let lastTwo = Array(stackSiblings.suffix(2))
            baseVersionID = lastTwo[0].id
            targetVersionID = lastTwo[1].id
        }
    }

    private func reloadDiffReport() async {
        guard baseVersionID != targetVersionID else { return }
        isLoadingDiff = true
        diffError = nil
        do {
            let report = try await store.engine.compareDocumentVersions(
                baseAssetID: baseVersionID,
                targetAssetID: targetVersionID,
                sheetName: selectedDiffSheetName,
                primaryKeyCol: selectedPrimaryKeyCol,
                useOCRIfScanned: useOCRIfScanned
            )
            guard !Task.isCancelled else { return }
            diffReport = report
            if selectedDiffSheetName == nil {
                selectedDiffSheetName = report.sheetDiffs.first?.sheetName
            }
            if formatFamily == .pdf && !report.hunks.contains(where: { $0.changeKind.isChanged }) && report.supportsVisualPageOverlay {
                pdfDiffSubMode = .splitCurtain
            }
        } catch {
            guard !Task.isCancelled else { return }
            diffError = "版本对比失败：\(error.localizedDescription)"
        }
        isLoadingDiff = false
    }

    private func shortVersionTag(id: UUID) -> String {
        guard let item = stackSiblings.first(where: { $0.id == id }) ?? store.liveAsset(id: id) else {
            return "v1"
        }
        let v = item.richMetadata?.versionStack?.versionNumber
            ?? ((stackSiblings.firstIndex(where: { $0.id == id }) ?? 0) + 1)
        return "v\(v)"
    }

    private func versionLabelForPicker(id: UUID) -> String {
        guard let item = stackSiblings.first(where: { $0.id == id }) ?? store.liveAsset(id: id) else {
            return "版本"
        }
        let verMeta = item.richMetadata?.versionStack
        let v = verMeta?.versionNumber
            ?? ((stackSiblings.firstIndex(where: { $0.id == id }) ?? 0) + 1)
        let isPrimary = item.id == primaryAsset.id
        let desc = MobileVersionDisplayFormatting.cleanDescriptor(
            changeNote: verMeta?.changeNote,
            versionLabel: verMeta?.versionLabel,
            editorName: verMeta?.editorName
        ) ?? MobileVersionDisplayFormatting.cleanEditor(verMeta?.editorName)
        var label = "v\(v)"
        if let desc { label += " · \(desc)" }
        if isPrimary { label += "（主版）" }
        return label
    }

    private func changeKindColor(_ kind: DocumentDiffChangeKind) -> Color {
        switch kind {
        case .added: MobileTheme.positive(for: colorScheme)
        case .removed: MobileTheme.destructive(for: colorScheme)
        case .modified, .moved: MobileTheme.accent(for: colorScheme)
        case .unchanged: MobileTheme.secondaryInk(for: colorScheme)
        }
    }

    nonisolated static func excelColumnName(_ index: Int) -> String {
        var n = max(0, index)
        var name = ""
        repeat {
            let rem = n % 26
            name = String(UnicodeScalar(65 + rem)!) + name
            n = (n / 26) - 1
        } while n >= 0
        return name
    }
}

// MARK: - Scanned PDF & Visual Stack Overlay Diff (Zero Verbose Instructional Banners)

struct PDFAndImageVisualOverlayDiffView: View {
    @Bindable var store: MobileAppStore
    let baseAsset: AssetRecord
    let targetAsset: AssetRecord
    let isSplitCurtain: Bool

    @Environment(\.colorScheme) private var colorScheme

    @State private var pageIndex: Int = 0
    @State private var pageCount: Int = 1
    @State private var baseImage: UIImage?
    @State private var targetImage: UIImage?
    @State private var redCyanImage: UIImage?
    @State private var isRendering: Bool = true
    @State private var curtainFraction: CGFloat = 0.50

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: MobileTheme.Radius.cardOuter, style: .continuous)
                    .fill(MobileTheme.surfaceElevated(for: colorScheme))

                if isRendering {
                    ProgressView()
                } else if isSplitCurtain, let baseImage, let targetImage {
                    GeometryReader { geo in
                        let w = max(1, geo.size.width)
                        let h = max(1, geo.size.height)
                        let dividerX = w * curtainFraction

                        ZStack(alignment: .leading) {
                            Image(uiImage: targetImage)
                                .resizable()
                                .scaledToFit()
                                .frame(width: w, height: h)

                            Image(uiImage: baseImage)
                                .resizable()
                                .scaledToFit()
                                .frame(width: w, height: h)
                                .mask(alignment: .leading) {
                                    Rectangle()
                                        .frame(width: dividerX, height: h)
                                }

                            ZStack {
                                Rectangle()
                                    .fill(MobileTheme.accent(for: colorScheme))
                                    .frame(width: 2, height: h)
                                    .shadow(color: .black.opacity(0.24), radius: 2)

                                Circle()
                                    .fill(MobileTheme.accentButtonFill(for: colorScheme))
                                    .frame(width: 32, height: 32)
                                    .overlay {
                                        Image(systemName: "arrow.left.and.right")
                                            .font(.system(size: 12, weight: .bold))
                                            .foregroundStyle(.white)
                                    }
                                    .shadow(color: .black.opacity(0.22), radius: 5, y: 2)
                            }
                            .position(x: dividerX, y: h * 0.5)

                            // Compact Version Corner Badges (Zero Tutorial Prose)
                            VStack {
                                HStack {
                                    Text(baseAsset.richMetadata?.versionStack?.displayVersionTag ?? "v1")
                                        .font(.system(size: 11, weight: .semibold).monospacedDigit())
                                        .foregroundStyle(.white)
                                        .padding(.horizontal, 7.5)
                                        .padding(.vertical, 3.5)
                                        .background(.black.opacity(0.55), in: Capsule())
                                    Spacer()
                                    Text(targetAsset.richMetadata?.versionStack?.displayVersionTag ?? "v2")
                                        .font(.system(size: 11, weight: .semibold).monospacedDigit())
                                        .foregroundStyle(.white)
                                        .padding(.horizontal, 7.5)
                                        .padding(.vertical, 3.5)
                                        .background(MobileTheme.accentButtonFill(for: colorScheme).opacity(0.85), in: Capsule())
                                }
                                .padding(10)
                                Spacer()
                            }
                            .allowsHitTesting(false)
                        }
                        .contentShape(Rectangle())
                        .highPriorityGesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { val in
                                    curtainFraction = max(0.04, min(0.96, val.location.x / w))
                                }
                        )
                    }
                    .padding(8)
                } else if let redCyanImage {
                    ZStack(alignment: .topTrailing) {
                        Image(uiImage: redCyanImage)
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .padding(8)

                        // Minimal Legend Dots (`● 旧版  ● 新版`)
                        HStack(spacing: 10) {
                            HStack(spacing: 4) {
                                Circle().fill(Color(charkleHex: "#D93B30")).frame(width: 6.5, height: 6.5)
                                Text("旧版")
                            }
                            HStack(spacing: 4) {
                                Circle().fill(Color(charkleHex: "#0891B2")).frame(width: 6.5, height: 6.5)
                                Text("新版")
                            }
                        }
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(.black.opacity(0.60), in: Capsule())
                        .padding(12)
                    }
                } else {
                    Text("无法生成页面比对预览")
                        .font(.system(size: 13))
                        .foregroundStyle(MobileTheme.secondaryInk(for: colorScheme))
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: MobileTheme.Radius.cardOuter, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: MobileTheme.Radius.cardOuter, style: .continuous)
                    .strokeBorder(MobileTheme.hairline(for: colorScheme), lineWidth: 0.5)
            )

            if pageCount > 1 {
                HStack(spacing: 14) {
                    Button {
                        MobileHaptics.light()
                        pageIndex = max(0, pageIndex - 1)
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 12.5, weight: .bold))
                            .frame(width: 28, height: 28)
                    }
                    .disabled(pageIndex <= 0)

                    Text("\(pageIndex + 1) / \(pageCount)")
                        .font(.system(size: 12, weight: .semibold).monospacedDigit())

                    Button {
                        MobileHaptics.light()
                        pageIndex = min(pageCount - 1, pageIndex + 1)
                    } label: {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12.5, weight: .bold))
                            .frame(width: 28, height: 28)
                    }
                    .disabled(pageIndex >= pageCount - 1)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .charkleFloatingCapsule()
            }
        }
        .task(id: "\(baseAsset.id.uuidString):\(targetAsset.id.uuidString):\(pageIndex)") {
            await renderComparisonBitmaps()
        }
    }

    private func renderComparisonBitmaps() async {
        isRendering = true
        let baseURL = try? await store.engine.originalURL(for: baseAsset.id)
        let targetURL = try? await store.engine.originalURL(for: targetAsset.id)

        let baseExt = (baseAsset.fileName as NSString).pathExtension.lowercased()
        let isPDF = baseExt == "pdf" || (targetAsset.fileName as NSString).pathExtension.lowercased() == "pdf"

        if isPDF, let baseURL, let targetURL {
            let rendered = await Self.renderPDFPagePairAndRedCyanOffMain(
                baseURL: baseURL,
                targetURL: targetURL,
                pageIndex: pageIndex
            )
            guard !Task.isCancelled else { return }
            pageCount = max(1, rendered.totalPages)
            baseImage = rendered.base
            targetImage = rendered.target
            redCyanImage = rendered.redCyan
        } else {
            let bImg: UIImage?
            if let orig = await store.thumbnails.loadOriginalImage(for: baseAsset) {
                bImg = orig
            } else {
                bImg = await store.thumbnails.loadImage(for: baseAsset.id, tier: .preview1400)
            }
            let tImg: UIImage?
            if let orig = await store.thumbnails.loadOriginalImage(for: targetAsset) {
                tImg = orig
            } else {
                tImg = await store.thumbnails.loadImage(for: targetAsset.id, tier: .preview1400)
            }
            pageCount = 1
            baseImage = bImg
            targetImage = tImg
            if let bCG = bImg?.cgImage, let tCG = tImg?.cgImage {
                redCyanImage = await Self.composeRedCyanOffMain(baseCG: bCG, targetCG: tCG)
            } else {
                redCyanImage = nil
            }
        }
        isRendering = false
    }

    private nonisolated struct RenderedPDFPair: @unchecked Sendable {
        let totalPages: Int
        let base: UIImage?
        let target: UIImage?
        let redCyan: UIImage?
    }

    @concurrent
    private static func renderPDFPagePairAndRedCyanOffMain(
        baseURL: URL,
        targetURL: URL,
        pageIndex: Int
    ) async -> RenderedPDFPair {
        let baseDoc = PDFDocument(url: baseURL)
        let targetDoc = PDFDocument(url: targetURL)
        let total = max(baseDoc?.pageCount ?? 0, targetDoc?.pageCount ?? 0)
        let bPage = baseDoc?.page(at: min(pageIndex, max(0, (baseDoc?.pageCount ?? 1) - 1)))
        let tPage = targetDoc?.page(at: min(pageIndex, max(0, (targetDoc?.pageCount ?? 1) - 1)))

        let bImg = bPage.flatMap { rasterizePDFPage($0, maxDimension: 1440) }
        let tImg = tPage.flatMap { rasterizePDFPage($0, maxDimension: 1440) }
        let rcImg: UIImage?
        if let bCG = bImg?.cgImage, let tCG = tImg?.cgImage {
            rcImg = buildRedCyanComposite(baseCG: bCG, targetCG: tCG)
        } else {
            rcImg = nil
        }
        return RenderedPDFPair(totalPages: max(1, total), base: bImg, target: tImg, redCyan: rcImg)
    }

    @concurrent
    private static func composeRedCyanOffMain(baseCG: CGImage, targetCG: CGImage) async -> UIImage? {
        buildRedCyanComposite(baseCG: baseCG, targetCG: targetCG)
    }

    private nonisolated static func rasterizePDFPage(_ page: PDFPage, maxDimension: CGFloat) -> UIImage? {
        let box = page.bounds(for: .mediaBox)
        guard box.width > 1, box.height > 1 else { return nil }
        let scale = min(2.5, maxDimension / max(box.width, box.height))
        let width = max(1, Int((box.width * scale).rounded()))
        let height = max(1, Int((box.height * scale).rounded()))
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.saveGState()
        ctx.scaleBy(x: scale, y: scale)
        page.draw(with: .mediaBox, to: ctx)
        ctx.restoreGState()
        guard let cg = ctx.makeImage() else { return nil }
        return UIImage(cgImage: cg)
    }

    private nonisolated static func buildRedCyanComposite(baseCG: CGImage, targetCG: CGImage) -> UIImage? {
        let width = min(1280, max(baseCG.width, targetCG.width))
        let aspect = Double(targetCG.height) / Double(max(1, targetCG.width))
        let height = max(1, min(1800, Int((Double(width) * aspect).rounded())))
        let bytesPerRow = width * 4
        let byteCount = bytesPerRow * height
        let cs = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue

        var baseBuf = [UInt8](repeating: 255, count: byteCount)
        var targetBuf = [UInt8](repeating: 255, count: byteCount)
        var outBuf = [UInt8](repeating: 255, count: byteCount)

        let drawRect = CGRect(x: 0, y: 0, width: width, height: height)
        baseBuf.withUnsafeMutableBytes { ptr in
            if let ctx = CGContext(
                data: ptr.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: cs,
                bitmapInfo: bitmapInfo
            ) {
                ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
                ctx.fill(drawRect)
                ctx.draw(baseCG, in: drawRect)
            }
        }
        targetBuf.withUnsafeMutableBytes { ptr in
            if let ctx = CGContext(
                data: ptr.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: cs,
                bitmapInfo: bitmapInfo
            ) {
                ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
                ctx.fill(drawRect)
                ctx.draw(targetCG, in: drawRect)
            }
        }

        var i = 0
        while i < byteCount {
            let bLuma = (Int(baseBuf[i]) * 77 + Int(baseBuf[i + 1]) * 150 + Int(baseBuf[i + 2]) * 29) >> 8
            let tLuma = (Int(targetBuf[i]) * 77 + Int(targetBuf[i + 1]) * 150 + Int(targetBuf[i + 2]) * 29) >> 8
            outBuf[i] = UInt8(clamping: tLuma)
            outBuf[i + 1] = UInt8(clamping: bLuma)
            outBuf[i + 2] = UInt8(clamping: bLuma)
            outBuf[i + 3] = 255
            i += 4
        }

        return outBuf.withUnsafeMutableBytes { ptr -> UIImage? in
            guard let ctx = CGContext(
                data: ptr.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: cs,
                bitmapInfo: bitmapInfo
            ), let cg = ctx.makeImage() else {
                return nil
            }
            return UIImage(cgImage: cg)
        }
    }
}

// MARK: - Standalone Two-Way Merge Sheet (Preserved for Sheet Callers, Continuous Paper Style)

struct DocumentTwoWayMergeSheet: View {
    @Bindable var store: MobileAppStore
    let report: DocumentComparisonReport
    let baseAsset: AssetRecord
    let targetAsset: AssetRecord
    let nextVersionNumber: Int
    let onShareCreated: (URL) -> Void
    let onOpenCreatedVersion: (AssetRecord) -> Void
    let onCancel: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var preferTargetAsTemplate: Bool = true
    @State private var choiceByHunkID: [String: DocumentMergeDecision.Choice] = [:]
    @State private var customTextByHunkID: [String: String] = [:]
    @State private var isPreviewExpanded: Bool = false
    @State private var editorNameDraft: String = ""
    @State private var changeNoteDraft: String = ""
    @State private var isSynthesizing: Bool = false
    @State private var createdAsset: AssetRecord? = nil

    private var changedHunks: [DocumentDiffHunk] {
        report.hunks.filter { $0.changeKind.isChanged }
    }

    private var compiledDecisions: [DocumentMergeDecision] {
        let fallbackChoice: DocumentMergeDecision.Choice = preferTargetAsTemplate ? .acceptTarget : .keepBase
        return changedHunks.compactMap { hunk in
            guard !hunk.isProtectedComplex else { return nil }
            let choice = choiceByHunkID[hunk.id] ?? fallbackChoice
            let custom = choice == .customText
                ? (customTextByHunkID[hunk.id] ?? hunk.targetText ?? hunk.baseText ?? "")
                : nil
            return DocumentMergeDecision(hunkID: hunk.id, choice: choice, customText: custom)
        }
    }

    var body: some View {
        let accent = MobileTheme.accent(for: colorScheme)
        let pos = MobileTheme.positive(for: colorScheme)
        let danger = MobileTheme.destructive(for: colorScheme)
        let paperShape = RoundedRectangle(cornerRadius: 12, style: .continuous)

        VStack(spacing: 0) {
            if let createdAsset {
                VStack(spacing: 16) {
                    Spacer()
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 36, weight: .semibold))
                        .foregroundStyle(pos)
                    Text("已生成 \(createdAsset.richMetadata?.versionStack?.displayVersionTag ?? "v\(nextVersionNumber)")")
                        .font(.system(size: 18, weight: .bold).monospacedDigit())

                    VStack(spacing: 10) {
                        Button {
                            MobileHaptics.success()
                            Task {
                                if let url = await store.shareableOriginalURL(for: createdAsset, preferExactAsset: true) {
                                    onShareCreated(url)
                                }
                            }
                        } label: {
                            Label("分享文件", systemImage: "square.and.arrow.up")
                                .font(.system(size: 14.5, weight: .semibold))
                                .foregroundStyle(.white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                                .background(MobileTheme.accentButtonFill(for: colorScheme), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        }
                        .buttonStyle(MobileTactileButtonStyle())

                        Button {
                            onOpenCreatedVersion(createdAsset)
                        } label: {
                            Text("打开新版本")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(accent)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 11)
                                .background(MobileTheme.accentSoft(for: colorScheme), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        }
                        .buttonStyle(MobileTactileButtonStyle())
                    }
                    .padding(.horizontal, 24)
                    .frame(maxWidth: 400)
                    Spacer()
                }
                .background(MobileTheme.galleryGround(for: colorScheme))
            } else {
                HStack(spacing: 8) {
                    Text("底稿")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(MobileTheme.secondaryInk(for: colorScheme))
                    Picker("底稿", selection: $preferTargetAsTemplate) {
                        Text("以新版为准").tag(true)
                        Text("以旧版为准").tag(false)
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 210)
                    Spacer()
                    Text("\(changedHunks.count) 处差异")
                        .font(.system(size: 11.5, weight: .medium).monospacedDigit())
                        .foregroundStyle(MobileTheme.secondaryInk(for: colorScheme))
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)

                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(changedHunks.enumerated()), id: \.element.id) { idx, hunk in
                            if idx > 0 {
                                Rectangle()
                                    .fill(MobileTheme.hairline(for: colorScheme))
                                    .frame(height: 0.5)
                            }
                            let currentChoice = choiceByHunkID[hunk.id]
                                ?? (preferTargetAsTemplate ? .acceptTarget : .keepBase)

                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Text("#\(idx + 1)")
                                        .font(.system(size: 11, weight: .medium, design: .monospaced).monospacedDigit())
                                        .foregroundStyle(MobileTheme.tertiaryInk(for: colorScheme))
                                    Spacer()
                                    if !hunk.isProtectedComplex {
                                        Picker("取舍", selection: Binding(
                                            get: { currentChoice },
                                            set: { next in
                                                choiceByHunkID[hunk.id] = next
                                                if next == .customText && customTextByHunkID[hunk.id] == nil {
                                                    customTextByHunkID[hunk.id] = hunk.targetText ?? hunk.baseText ?? ""
                                                }
                                            }
                                        )) {
                                            Text("保留旧版").tag(DocumentMergeDecision.Choice.keepBase)
                                            Text("采纳新版").tag(DocumentMergeDecision.Choice.acceptTarget)
                                            Text("微调").tag(DocumentMergeDecision.Choice.customText)
                                        }
                                        .pickerStyle(.segmented)
                                        .frame(maxWidth: 210)
                                    }
                                }

                                if let oldT = hunk.baseText, !oldT.isEmpty {
                                    let isSelectedBase = !hunk.isProtectedComplex && currentChoice == .keepBase
                                    Button {
                                        guard !hunk.isProtectedComplex else { return }
                                        choiceByHunkID[hunk.id] = .keepBase
                                    } label: {
                                        HStack(alignment: .top, spacing: 8) {
                                            Image(systemName: "minus.circle.fill")
                                                .font(.system(size: 13.5, weight: .semibold))
                                                .foregroundStyle(danger)
                                                .padding(.top, 2)
                                            Text(
                                                MobileDiffTokenHighlighter.selectiveSideAttributedString(
                                                    hunk: hunk,
                                                    side: .base,
                                                    isEmphasized: isSelectedBase,
                                                    colorScheme: colorScheme
                                                )
                                            )
                                            .font(.system(size: 13.5))
                                            .lineSpacing(3.5)
                                            .multilineTextAlignment(.leading)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                        }
                                        .padding(9)
                                        .background(isSelectedBase ? MobileTheme.accentSoft(for: colorScheme) : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                                .strokeBorder(isSelectedBase ? accent.opacity(0.50) : MobileTheme.hairline(for: colorScheme), lineWidth: isSelectedBase ? 1 : 0.5)
                                        )
                                        .opacity(isSelectedBase ? 1.0 : 0.48)
                                    }
                                    .buttonStyle(.plain)
                                }

                                if let newT = hunk.targetText, !newT.isEmpty {
                                    let isSelectedTarget = !hunk.isProtectedComplex && currentChoice == .acceptTarget
                                    Button {
                                        guard !hunk.isProtectedComplex else { return }
                                        choiceByHunkID[hunk.id] = .acceptTarget
                                    } label: {
                                        HStack(alignment: .top, spacing: 8) {
                                            Image(systemName: "plus.circle.fill")
                                                .font(.system(size: 13.5, weight: .semibold))
                                                .foregroundStyle(pos)
                                                .padding(.top, 2)
                                            Text(
                                                MobileDiffTokenHighlighter.selectiveSideAttributedString(
                                                    hunk: hunk,
                                                    side: .target,
                                                    isEmphasized: isSelectedTarget,
                                                    colorScheme: colorScheme
                                                )
                                            )
                                            .font(.system(size: 13.5))
                                            .lineSpacing(3.5)
                                            .multilineTextAlignment(.leading)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                        }
                                        .padding(9)
                                        .background(isSelectedTarget ? MobileTheme.accentSoft(for: colorScheme) : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                                .strokeBorder(isSelectedTarget ? accent.opacity(0.50) : MobileTheme.hairline(for: colorScheme), lineWidth: isSelectedTarget ? 1 : 0.5)
                                        )
                                        .opacity(isSelectedTarget ? 1.0 : 0.48)
                                    }
                                    .buttonStyle(.plain)
                                }

                                if currentChoice == .customText && !hunk.isProtectedComplex {
                                    TextField(
                                        "微调正文…",
                                        text: Binding(
                                            get: { customTextByHunkID[hunk.id] ?? hunk.targetText ?? hunk.baseText ?? "" },
                                            set: { customTextByHunkID[hunk.id] = $0 }
                                        ),
                                        axis: .vertical
                                    )
                                    .lineLimit(2...6)
                                    .font(.system(size: 13.5))
                                    .padding(9)
                                    .background(MobileTheme.inspectorFieldSurface(for: colorScheme), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                                }
                            }
                            .padding(.vertical, 12)
                        }

                        Rectangle()
                            .fill(MobileTheme.hairline(for: colorScheme))
                            .frame(height: 0.5)

                        Button {
                            withAnimation(MobileMotion.accessible(MobileMotion.settleStrong, reduced: reduceMotion)) {
                                isPreviewExpanded.toggle()
                            }
                        } label: {
                            HStack {
                                Text("合并预览")
                                    .font(.system(size: 12.5, weight: .semibold))
                                Spacer()
                                Image(systemName: isPreviewExpanded ? "chevron.up" : "chevron.down")
                                    .font(.system(size: 10.5, weight: .bold))
                                    .foregroundStyle(MobileTheme.tertiaryInk(for: colorScheme))
                            }
                            .padding(.vertical, 11)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)

                        if isPreviewExpanded {
                            Text(
                                report.previewMergedText(
                                    preferTargetAsTemplate: preferTargetAsTemplate,
                                    decisions: compiledDecisions
                                )
                            )
                            .font(.system(size: 14))
                            .lineSpacing(4)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                            .background(MobileTheme.inspectorFieldSurface(for: colorScheme), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .padding(.bottom, 8)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(MobileTheme.surfaceElevated(for: colorScheme), in: paperShape)
                    .overlay(paperShape.strokeBorder(MobileTheme.hairline(for: colorScheme), lineWidth: 0.5))
                    .padding(16)
                }
                .charkleDismissKeyboardOnScroll()
                .background(MobileTheme.galleryGround(for: colorScheme))
                .safeAreaInset(edge: .bottom) {
                    HStack(spacing: 8) {
                        TextField("修改人", text: $editorNameDraft)
                            .font(.system(size: 12.5))
                            .padding(.horizontal, 9)
                            .padding(.vertical, 8)
                            .frame(maxWidth: 96)
                            .background(MobileTheme.surfaceElevated(for: colorScheme), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

                        TextField("备注（可选）", text: $changeNoteDraft)
                            .font(.system(size: 12.5))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .background(MobileTheme.surfaceElevated(for: colorScheme), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

                        Button {
                            synthesizeNow()
                        } label: {
                            Text(isSynthesizing ? "保存中…" : "保存为新版本")
                                .font(.system(size: 13.5, weight: .semibold).monospacedDigit())
                                .foregroundStyle(.white)
                                .padding(.horizontal, 15)
                                .padding(.vertical, 9)
                                .background(MobileTheme.accentButtonFill(for: colorScheme), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        }
                        .buttonStyle(MobileTactileButtonStyle())
                        .disabled(isSynthesizing)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.ultraThinMaterial)
                }
            }
        }
        .navigationTitle("合并")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(createdAsset != nil ? "关闭" : "取消", action: onCancel)
            }
        }
    }

    private func synthesizeNow() {
        guard !isSynthesizing else { return }
        isSynthesizing = true
        MobileKeyboard.dismiss()
        let ed = editorNameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let noteRaw = changeNoteDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let decisions = compiledDecisions
        let preferTarget = preferTargetAsTemplate

        Task {
            do {
                let created = try await store.engine.synthesizeDocumentVersion(
                    baseAssetID: report.baseAssetID,
                    targetAssetID: report.targetAssetID,
                    preferTargetAsTemplate: preferTarget,
                    decisions: decisions,
                    editorName: (ed.isEmpty || ed == "本机") ? nil : ed,
                    changeNote: noteRaw.isEmpty ? nil : noteRaw
                )
                _ = try? await store.engine.manageVersionStack(.setPrimary(assetID: created.id))
                await store.reloadAll()
                MobileHaptics.success()
                createdAsset = store.liveAsset(id: created.id) ?? created
                store.showToast("已生成 v\(nextVersionNumber)", tone: .success)
                if store.hasConnectedCloudBackend {
                    Task { await store.syncNow(quiet: true) }
                }
            } catch {
                MobileHaptics.error()
                store.showToast("生成失败：\(error.localizedDescription)", tone: .error)
            }
            isSynthesizing = false
        }
    }
}

// MARK: - Selective Side Token Highlighter (Base `−` / Target `+` Without Full-Paragraph Paint)

enum MobileDiffRowSide {
    case base
    case target
}

enum MobileDiffTokenHighlighter {
    static func selectiveSideAttributedString(
        hunk: DocumentDiffHunk,
        side: MobileDiffRowSide,
        isEmphasized: Bool,
        colorScheme: ColorScheme
    ) -> AttributedString {
        let calmColor = isEmphasized
            ? UIColor.label
            : UIColor(MobileTheme.secondaryInk(for: colorScheme))
        let posUIColor = UIColor(MobileTheme.positive(for: colorScheme))
        let delUIColor = UIColor(MobileTheme.destructive(for: colorScheme))

        let resolvedTokens: [DocumentInlineDiffToken]
        if !hunk.inlineTokens.isEmpty {
            resolvedTokens = hunk.inlineTokens
        } else {
            resolvedTokens = fallbackCommonBoundaryTokens(
                baseText: hunk.baseText ?? "",
                targetText: hunk.targetText ?? ""
            )
        }

        var result = AttributedString()
        var appendedAny = false

        for token in resolvedTokens {
            switch (side, token.kind) {
            case (_, .equal):
                var seg = AttributedString(token.text)
                seg.foregroundColor = calmColor
                result.append(seg)
                appendedAny = true

            case (.base, .deleted):
                var seg = AttributedString(token.text)
                seg.foregroundColor = delUIColor
                seg.backgroundColor = delUIColor.withAlphaComponent(0.13)
                seg.strikethroughStyle = .single
                seg.strikethroughColor = delUIColor
                if token.isHighRiskNumber || token.isHighRiskDate {
                    seg.inlinePresentationIntent = .stronglyEmphasized
                }
                result.append(seg)
                appendedAny = true

            case (.target, .inserted):
                var seg = AttributedString(token.text)
                seg.foregroundColor = posUIColor
                seg.backgroundColor = posUIColor.withAlphaComponent(0.14)
                seg.inlinePresentationIntent = .stronglyEmphasized
                result.append(seg)
                appendedAny = true

            case (.base, .inserted), (.target, .deleted):
                continue
            }
        }

        if !appendedAny {
            let fallback = (side == .base ? hunk.baseText : hunk.targetText) ?? ""
            var seg = AttributedString(fallback)
            seg.foregroundColor = calmColor
            return seg
        }

        return result
    }

    private static func fallbackCommonBoundaryTokens(
        baseText: String,
        targetText: String
    ) -> [DocumentInlineDiffToken] {
        if baseText == targetText {
            return baseText.isEmpty
                ? []
                : [DocumentInlineDiffToken(id: "fb-eq", kind: .equal, text: baseText)]
        }
        let bChars = Array(baseText)
        let tChars = Array(targetText)
        var prefixLen = 0
        let minLen = min(bChars.count, tChars.count)
        while prefixLen < minLen && bChars[prefixLen] == tChars[prefixLen] {
            prefixLen += 1
        }
        var suffixLen = 0
        while suffixLen < (minLen - prefixLen)
            && bChars[bChars.count - 1 - suffixLen] == tChars[tChars.count - 1 - suffixLen] {
            suffixLen += 1
        }

        var out: [DocumentInlineDiffToken] = []
        if prefixLen > 0 {
            out.append(DocumentInlineDiffToken(id: "fb-pre", kind: .equal, text: String(bChars[0..<prefixLen])))
        }
        let bMidEnd = bChars.count - suffixLen
        if prefixLen < bMidEnd {
            out.append(DocumentInlineDiffToken(id: "fb-del", kind: .deleted, text: String(bChars[prefixLen..<bMidEnd])))
        }
        let tMidEnd = tChars.count - suffixLen
        if prefixLen < tMidEnd {
            out.append(DocumentInlineDiffToken(id: "fb-ins", kind: .inserted, text: String(tChars[prefixLen..<tMidEnd])))
        }
        if suffixLen > 0 {
            out.append(DocumentInlineDiffToken(id: "fb-suf", kind: .equal, text: String(bChars[(bChars.count - suffixLen)..<bChars.count])))
        }
        return out
    }
}

// MARK: - Inline True-Layout Office QuickLook Preview (`OfficeImport` Native Paper Layout)

struct MobileOfficeQLPreviewView: UIViewControllerRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator {
        Coordinator(url: url)
    }

    func makeUIViewController(context: Context) -> OfficeQLContainerViewController {
        let controller = OfficeQLContainerViewController()
        controller.configure(with: context.coordinator)
        return controller
    }

    func updateUIViewController(_ uiViewController: OfficeQLContainerViewController, context: Context) {
        if context.coordinator.updateURL(url) {
            uiViewController.reloadPreview()
        }
    }

    static func dismantleUIViewController(
        _ uiViewController: OfficeQLContainerViewController,
        coordinator: Coordinator
    ) {
        coordinator.clearURL()
        uiViewController.teardown()
    }

    nonisolated final class Coordinator: NSObject, QLPreviewControllerDataSource {
        private let lock = NSLock()
        private var currentURL: URL?

        init(url: URL) {
            self.currentURL = url
            super.init()
        }

        func updateURL(_ nextURL: URL) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard currentURL != nextURL else { return false }
            currentURL = nextURL
            return true
        }

        func clearURL() {
            lock.lock()
            currentURL = nil
            lock.unlock()
        }

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int {
            lock.lock()
            defer { lock.unlock() }
            return currentURL == nil ? 0 : 1
        }

        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> any QLPreviewItem {
            lock.lock()
            let resolved = currentURL
            lock.unlock()
            return (resolved ?? URL(fileURLWithPath: "/")) as NSURL
        }
    }
}

final class OfficeQLContainerViewController: UIViewController {
    private var previewController: QLPreviewController?

    func configure(with dataSource: QLPreviewControllerDataSource) {
        guard previewController == nil else { return }
        let ql = QLPreviewController()
        ql.dataSource = dataSource
        addChild(ql)
        ql.view.translatesAutoresizingMaskIntoConstraints = false
        view.backgroundColor = .clear
        view.clipsToBounds = true
        view.addSubview(ql.view)
        NSLayoutConstraint.activate([
            ql.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            ql.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            ql.view.topAnchor.constraint(equalTo: view.topAnchor),
            ql.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        ql.didMove(toParent: self)
        previewController = ql
    }

    func reloadPreview() {
        previewController?.reloadData()
        previewController?.refreshCurrentPreviewItem()
    }

    func teardown() {
        guard let ql = previewController else { return }
        ql.dataSource = nil
        ql.willMove(toParent: nil)
        ql.view.removeFromSuperview()
        ql.removeFromParent()
        previewController = nil
    }
}

// MARK: - Enhanced PDFKit Wrapper

private struct MobileEnhancedPDFKitView: View {
    let url: URL
    let continuous: Bool

    @State private var document: PDFDocument?
    @State private var isLoading = true

    private nonisolated struct PDFBox: @unchecked Sendable {
        let doc: PDFDocument?
    }

    var body: some View {
        ZStack {
            if let document {
                EnhancedPDFViewRepresentable(document: document, continuous: continuous)
            } else if isLoading {
                ProgressView()
            } else {
                Text("无法解析此 PDF 文档")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
        }
        .task(id: url) {
            isLoading = true
            let loaded = await Self.loadOffMain(url: url)
            guard !Task.isCancelled else { return }
            document = loaded.doc
            isLoading = false
        }
    }

    @concurrent
    private static func loadOffMain(url: URL) async -> PDFBox {
        PDFBox(doc: PDFDocument(url: url))
    }
}

private struct EnhancedPDFViewRepresentable: UIViewRepresentable {
    let document: PDFDocument
    let continuous: Bool

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayDirection = .vertical
        view.displayMode = continuous ? .singlePageContinuous : .singlePage
        view.usePageViewController(!continuous)
        view.document = document
        return view
    }

    func updateUIView(_ uiView: PDFView, context: Context) {
        if uiView.document !== document {
            uiView.document = document
        }
        let targetMode: PDFDisplayMode = continuous ? .singlePageContinuous : .singlePage
        if uiView.displayMode != targetMode {
            uiView.displayMode = targetMode
            uiView.usePageViewController(!continuous)
            uiView.autoScales = true
        }
    }
}
