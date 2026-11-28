import CharkleCore
import CoreGraphics
import PDFKit
import SwiftUI
import UIKit

// MARK: - Unified Document & Version-Stack Stage for AssetDetailView

enum MobileDocumentStageMode: String, CaseIterable {
    case read = "阅读"
    case diff = "对比差异"
}

enum MobileRadarFilter: String, CaseIterable, Identifiable {
    case all = "全部改动"
    case numberOrCurrency = "数字与金额"
    case dateOrDeadline = "日期与时限"
    case tableMutation = "表格变动"
    case nativeRevisionOrComment = "原生修订/批注"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .all: "line.3.horizontal.decrease.circle"
        case .numberOrCurrency: "yensign.circle"
        case .dateOrDeadline: "calendar"
        case .tableMutation: "tablecells"
        case .nativeRevisionOrComment: "text.bubble"
        }
    }

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

/// Hosts native iOS/iPadOS structured document reading (`.docx`, `.xlsx`, `.pdf`, `.md/.txt`),
/// Version Stack top switcher, High-Risk Diff Radar, Red-Cyan & Split-Curtain scanned PDF diff,
/// and Scheme B zero-corruption 2-Way Merge (`按差异合成新版本`).
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

    @State private var mode: MobileDocumentStageMode
    @State private var payload: StructuredDocumentPayload?
    @State private var isLoadingPayload: Bool = true
    @State private var payloadError: String?
    @State private var localOriginalURL: URL?

    // Reader sub-states
    @State private var selectedSheetIndex: Int = 0
    @State private var selectedFormulaDetail: String?
    @State private var showRawTextMode: Bool = false
    @State private var areCommentsExpanded: Bool = true
    @State private var pdfContinuousMode: Bool = true

    // Diff states
    @State private var baseVersionID: UUID
    @State private var targetVersionID: UUID
    @State private var diffReport: DocumentComparisonReport?
    @State private var isLoadingDiff: Bool = false
    @State private var diffError: String?
    @State private var radarFilter: MobileRadarFilter = .all
    @State private var onlyChangedBlocks: Bool = true
    @State private var selectedDiffSheetName: String?
    @State private var selectedPrimaryKeyCol: Int?
    @State private var useOCRIfScanned: Bool = true
    @State private var focusedHunkCursor: Int = 0
    @State private var pdfDiffSubMode: PDFDiffSubMode = .textOrOCR
    @State private var isMergeSheetPresented: Bool = false

    private enum PDFDiffSubMode: String, CaseIterable {
        case textOrOCR = "文本/OCR"
        case redCyan = "红青叠层"
        case splitCurtain = "卷帘拉条"
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

    private var formatFamily: DocumentFormatFamily {
        if let raw = payload?.formatFamily, let parsed = DocumentFormatFamily(rawValue: raw) {
            return parsed
        }
        if let doc = asset.richMetadata?.document {
            return doc.parsedFormatFamily
        }
        return DocumentFormatFamily.detect(fileExtension: (asset.fileName as NSString).pathExtension)
    }

    var body: some View {
        VStack(spacing: 0) {
            if hasStack || mode == .diff {
                versionStackTopBar
                    .padding(.horizontal, 12)
                    .padding(.top, 4)
                    .padding(.bottom, 8)
            }

            if mode == .diff && stackSiblings.count >= 2 {
                diffWorkspace
            } else {
                readerWorkspace
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: mode) { _, nextMode in
            onBlockPagingChanged(
                (nextMode == .diff && (pdfDiffSubMode == .splitCurtain || formatFamily == .xlsx))
                    || (nextMode == .read && formatFamily == .xlsx)
            )
            if nextMode == .diff {
                Task { await reloadDiffReport() }
            }
        }
        .onChange(of: pdfDiffSubMode) { _, sub in
            onBlockPagingChanged(mode == .diff && sub == .splitCurtain)
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
            onBlockPagingChanged(
                (mode == .diff && (pdfDiffSubMode == .splitCurtain || formatFamily == .xlsx))
                    || (mode == .read && formatFamily == .xlsx)
            )
            if hasStack, initialComparePair == nil, externalDiffTrigger == nil {
                alignDefaultComparePair(around: asset)
            }
            if mode == .diff && stackSiblings.count >= 2 {
                await reloadDiffReport()
            }
        }
        .sheet(isPresented: $isMergeSheetPresented) {
            if let report = diffReport {
                NavigationStack {
                    DocumentTwoWayMergeSheet(
                        store: store,
                        report: report,
                        baseAsset: store.liveAsset(id: baseVersionID) ?? asset,
                        targetAsset: store.liveAsset(id: targetVersionID) ?? asset,
                        nextVersionNumber: (stackSiblings.compactMap { $0.richMetadata?.versionStack?.versionNumber }.max() ?? stackSiblings.count) + 1,
                        onShareCreated: { url in
                            isMergeSheetPresented = false
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                                onShareURL(url)
                            }
                        },
                        onOpenCreatedVersion: { created in
                            isMergeSheetPresented = false
                            mode = .read
                            onSelectVersionAsset(created)
                        },
                        onCancel: {
                            isMergeSheetPresented = false
                        }
                    )
                }
                .presentationDetents([.large])
            }
        }
    }

    // MARK: - Top Version Stack Bar & Reader/Diff Switcher

    private var versionStackTopBar: some View {
        let accent = MobileTheme.accent(for: colorScheme)
        let pos = MobileTheme.positive(for: colorScheme)
        let warn = MobileTheme.warning(for: colorScheme)
        let primaryVer = primaryAsset.richMetadata?.versionStack?.versionNumber ?? stackSiblings.count

        return HStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 5) {
                    ForEach(Array(stackSiblings.enumerated()), id: \.element.id) { idx, item in
                        let vNum = item.richMetadata?.versionStack?.versionNumber ?? (idx + 1)
                        let isCurrent = item.id == asset.id && mode == .read
                        let isPrimary = item.id == primaryAsset.id
                        let isUnreviewed = vNum > primaryVer

                        Button {
                            MobileHaptics.light()
                            mode = .read
                            onSelectVersionAsset(item)
                        } label: {
                            HStack(spacing: 4) {
                                Text("v\(vNum)")
                                    .font(.system(size: 12, weight: .bold).monospacedDigit())
                                if isPrimary {
                                    Text("主版")
                                        .font(.system(size: 9.5, weight: .bold))
                                        .foregroundStyle(isCurrent ? .white : pos)
                                        .padding(.horizontal, 4.5)
                                        .padding(.vertical, 1)
                                        .background(
                                            isCurrent ? Color.white.opacity(0.22) : pos.opacity(0.15),
                                            in: RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                                        )
                                } else if isUnreviewed {
                                    Circle()
                                        .fill(isCurrent ? .white : warn)
                                        .frame(width: 5.5, height: 5.5)
                                }
                            }
                            .foregroundStyle(isCurrent ? .white : .primary)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 5.5)
                            .background(
                                isCurrent
                                    ? MobileTheme.accentButtonFill(for: colorScheme)
                                    : MobileTheme.surfaceElevated(for: colorScheme),
                                in: Capsule()
                            )
                            .overlay(
                                Capsule().strokeBorder(
                                    isCurrent ? .clear : MobileTheme.hairline(for: colorScheme),
                                    lineWidth: 0.75
                                )
                            )
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            if !isPrimary {
                                Button {
                                    Task { await store.setPrimaryVersion(assetID: item.id) }
                                } label: {
                                    Label("锁定 v\(vNum) 为对外主版本", systemImage: "checkmark.seal.fill")
                                }
                            }
                            if idx > 0 {
                                Button {
                                    baseVersionID = stackSiblings[idx - 1].id
                                    targetVersionID = item.id
                                    mode = .diff
                                    Task { await reloadDiffReport() }
                                } label: {
                                    Label("对比 v\(idx) → v\(vNum) 差异", systemImage: "arrow.left.arrow.right")
                                }
                            }
                        }
                    }
                }
            }

            Spacer(minLength: 4)

            if stackSiblings.count >= 2 {
                HStack(spacing: 2) {
                    ForEach(MobileDocumentStageMode.allCases, id: \.self) { m in
                        let selected = mode == m
                        Button {
                            MobileHaptics.selection()
                            withAnimation(MobileMotion.accessible(MobileMotion.settleStrong, reduced: reduceMotion)) {
                                mode = m
                            }
                        } label: {
                            Text(m.rawValue)
                                .font(.system(size: 12, weight: selected ? .semibold : .medium))
                                .foregroundStyle(selected ? .white : .primary)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(
                                    selected ? accent : .clear,
                                    in: Capsule()
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(2.5)
                .background(MobileTheme.surfaceSubtle(for: colorScheme), in: Capsule())
            }
        }
    }

    // MARK: - Native Document Reader Workspace

    @ViewBuilder
    private var readerWorkspace: some View {
        switch formatFamily {
        case .pdf:
            pdfReaderStage
        case .xlsx:
            spreadsheetReaderStage
        case .markdown, .plainText:
            markdownOrTextReaderStage
        default:
            richBlocksReaderStage
        }
    }

    private var pdfReaderStage: some View {
        ZStack(alignment: .bottom) {
            if let localOriginalURL {
                MobileEnhancedPDFKitView(url: localOriginalURL, continuous: pdfContinuousMode)
                    .clipShape(RoundedRectangle(cornerRadius: MobileTheme.Radius.cardOuter, style: .continuous))
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
            } else if isLoadingPayload {
                ProgressView("正在加载 PDF 原件…")
                    .font(.system(size: 13))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let payload, !payload.plainText.isEmpty {
                richBlocksReaderStage
            } else {
                ProgressView("正在同步离线 PDF…")
                    .font(.system(size: 13))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            HStack(spacing: 8) {
                let pageCnt = payload?.pageCount ?? asset.richMetadata?.document?.pageCount ?? 0
                let hasText = payload?.hasTextLayer ?? asset.richMetadata?.document?.hasTextLayer ?? true
                if pageCnt > 0 {
                    Text("\(pageCnt) 页")
                        .font(.system(size: 11.5, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.primary)
                }
                Text(hasText ? "含可选文本层" : "签批扫描件 · 支持 OCR 对比")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(hasText ? MobileTheme.secondaryInk(for: colorScheme) : MobileTheme.warning(for: colorScheme))

                Divider().frame(height: 12)

                Button {
                    MobileHaptics.light()
                    pdfContinuousMode.toggle()
                } label: {
                    Text(pdfContinuousMode ? "单页翻阅" : "连续滚动")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(MobileTheme.accent(for: colorScheme))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .charkleFloatingCapsule()
            .padding(.bottom, 16)
        }
    }

    private var spreadsheetReaderStage: some View {
        VStack(spacing: 8) {
            if isLoadingPayload {
                ProgressView("正在解析电子表格…")
                    .font(.system(size: 13))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let sheets = payload?.sheets, !sheets.isEmpty {
                let safeIdx = max(0, min(selectedSheetIndex, sheets.count - 1))
                let activeSheet = sheets[safeIdx]

                // Sheet Switcher Pills
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
                                            .font(.system(size: 12.5, weight: selected ? .semibold : .medium))
                                        Text("\(sheet.rows.count)行")
                                            .font(.system(size: 10.5).monospacedDigit())
                                            .opacity(0.75)
                                    }
                                    .foregroundStyle(selected ? .white : .primary)
                                    .padding(.horizontal, 11)
                                    .padding(.vertical, 6)
                                    .background(
                                        selected
                                            ? Color(charkleHex: "#1D7A46")
                                            : MobileTheme.surfaceElevated(for: colorScheme),
                                        in: Capsule()
                                    )
                                    .overlay(
                                        Capsule().strokeBorder(
                                            selected ? .clear : MobileTheme.hairline(for: colorScheme),
                                            lineWidth: 0.75
                                        )
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
                                .foregroundStyle(Color(charkleHex: "#1D7A46"))
                            Text(selectedFormulaDetail)
                                .font(.system(size: 11.5, design: .monospaced))
                                .lineLimit(1)
                            Button {
                                UIPasteboard.general.string = selectedFormulaDetail
                                store.showToast("已复制单元格公式", tone: .info)
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

                // 2D Scrollable Spreadsheet Grid
                ScrollView([.horizontal, .vertical]) {
                    let colCount = max(1, activeSheet.columnCount)
                    VStack(alignment: .leading, spacing: 0) {
                        // Column Header Row
                        HStack(spacing: 0) {
                            Text("#")
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .foregroundStyle(MobileTheme.tertiaryInk(for: colorScheme))
                                .frame(width: 44, height: 34)
                                .background(MobileTheme.surfaceSubtle(for: colorScheme))

                            ForEach(0..<colCount, id: \.self) { col in
                                let letter = Self.excelColumnName(col)
                                let headerTitle = col < activeSheet.headers.count ? activeSheet.headers[col] : ""
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(headerTitle.isEmpty ? letter : "\(letter) · \(headerTitle)")
                                        .font(.system(size: 11.5, weight: .semibold))
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)
                                }
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
                                .frame(height: 0.75)
                        }

                        // Data Rows
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
                                                        .foregroundStyle(Color(charkleHex: "#1D7A46"))
                                                        .padding(.horizontal, 3.5)
                                                        .padding(.vertical, 1)
                                                        .background(Color(charkleHex: "#1D7A46").opacity(0.14), in: RoundedRectangle(cornerRadius: 3, style: .continuous))
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
                            .strokeBorder(MobileTheme.hairline(for: colorScheme), lineWidth: 0.75)
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
                    Text("排版阅读").tag(false)
                    Text("源码行号").tag(true)
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 200)

                Spacer()

                if let text = payload?.plainText, !text.isEmpty {
                    Button {
                        UIPasteboard.general.string = text
                        MobileHaptics.light()
                        store.showToast("已复制全文内容", tone: .success)
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
                            .strokeBorder(MobileTheme.hairline(for: colorScheme), lineWidth: 0.75)
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
                ProgressView("正在解析文档排版与表格…")
                    .font(.system(size: 13))
                    .padding(.top, 64)
            } else if let payload {
                VStack(alignment: .leading, spacing: 14) {
                    // Paper Document Sheet
                    VStack(alignment: .leading, spacing: 14) {
                        if payload.isRedHeaderStyle {
                            Rectangle()
                                .fill(Color(charkleHex: "#D93B30"))
                                .frame(height: 3)
                                .clipShape(Capsule())
                        }

                        // Document Metadata Header
                        HStack(spacing: 8) {
                            Text(formatFamily.badgeLabel)
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2.5)
                                .background(MobileTheme.accent(for: colorScheme), in: RoundedRectangle(cornerRadius: 5, style: .continuous))

                            if payload.pageCount > 0 {
                                Text("\(payload.pageCount) 页")
                                    .font(.system(size: 12, weight: .medium).monospacedDigit())
                                    .foregroundStyle(MobileTheme.secondaryInk(for: colorScheme))
                            }
                            if payload.wordCount > 0 {
                                Text("· \(payload.wordCount) 字")
                                    .font(.system(size: 12, weight: .medium).monospacedDigit())
                                    .foregroundStyle(MobileTheme.secondaryInk(for: colorScheme))
                            }
                            if let editor = payload.authorOrEditor, !editor.isEmpty {
                                Text("· \(editor)")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(MobileTheme.secondaryInk(for: colorScheme))
                            }
                            Spacer()
                            if payload.hasNativeRevisions {
                                Label("含原生修订", systemImage: "pencil.line")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(MobileTheme.warning(for: colorScheme))
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 3)
                                    .background(MobileTheme.warning(for: colorScheme).opacity(0.14), in: Capsule())
                            }
                        }

                        Divider()

                        if payload.blocks.isEmpty && payload.plainText.isEmpty {
                            VStack(spacing: 8) {
                                Image(systemName: "doc.text")
                                    .font(.system(size: 24))
                                    .foregroundStyle(MobileTheme.tertiaryInk(for: colorScheme))
                                Text(payloadError ?? "该文档暂无可直接提取的正文段落，可点击左下角分享用系统应用打开。")
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
                    .padding(horizontalSizeClass == .regular ? 24 : 16)
                    .frame(maxWidth: 780, alignment: .leading)
                    .background(
                        MobileTheme.surfaceElevated(for: colorScheme),
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(MobileTheme.hairline(for: colorScheme), lineWidth: 0.75)
                    )

                    // Native Word Comments Section
                    if !payload.comments.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Button {
                                MobileHaptics.light()
                                withAnimation(MobileMotion.accessible(MobileMotion.settleStrong, reduced: reduceMotion)) {
                                    areCommentsExpanded.toggle()
                                }
                            } label: {
                                HStack {
                                    Label("原生批注（\(payload.comments.count) 条）", systemImage: "text.bubble.fill")
                                        .font(.system(size: 13, weight: .semibold).monospacedDigit())
                                        .foregroundStyle(MobileTheme.warning(for: colorScheme))
                                    Spacer()
                                    Image(systemName: areCommentsExpanded ? "chevron.up" : "chevron.down")
                                        .font(.system(size: 11, weight: .bold))
                                        .foregroundStyle(MobileTheme.tertiaryInk(for: colorScheme))
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)

                            if areCommentsExpanded {
                                ForEach(payload.comments) { comment in
                                    VStack(alignment: .leading, spacing: 4) {
                                        HStack {
                                            Text(comment.author.isEmpty ? "审阅批注" : comment.author)
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
                                        in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    )
                                }
                            }
                        }
                        .padding(14)
                        .frame(maxWidth: 780, alignment: .leading)
                        .background(
                            MobileTheme.surfaceElevated(for: colorScheme),
                            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .strokeBorder(MobileTheme.hairline(for: colorScheme), lineWidth: 0.75)
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
                            .strokeBorder(MobileTheme.borderStrong(for: colorScheme), lineWidth: 0.75)
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
                Rectangle().fill(MobileTheme.hairline(for: colorScheme)).frame(height: 0.75)
                if let p = block.pageNumber {
                    Text("第 \(p) 页")
                        .font(.system(size: 10.5, weight: .medium).monospacedDigit())
                        .foregroundStyle(MobileTheme.tertiaryInk(for: colorScheme))
                }
                Rectangle().fill(MobileTheme.hairline(for: colorScheme)).frame(height: 0.75)
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
                                Text("\(isIns ? "+插入" : "-删除")：\(rev.text)" + (rev.author.map { " (\($0))" } ?? ""))
                                    .font(.system(size: 11, weight: .medium))
                                    .strikethrough(!isIns)
                                    .foregroundStyle(tint)
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 2.5)
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

    // MARK: - Multi-Modal Diff Workspace (High-Risk Radar + Word/Excel/Scanned PDF + 2-Way Merge)

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
        guard let report = diffReport else { return 0 }
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

    private var canLaunchTwoWayMerge: Bool {
        guard let report = diffReport else { return false }
        if report.canSynthesizeTwoWay { return true }
        let fam = DocumentFormatFamily(rawValue: report.formatFamily) ?? formatFamily
        return (fam == .docx || fam == .markdown || fam == .plainText)
            && report.hunks.contains(where: { $0.changeKind.isChanged && !$0.isProtectedComplex })
    }

    private var diffWorkspace: some View {
        VStack(spacing: 8) {
            diffVersionSelectorHeader
                .padding(.horizontal, 12)

            highRiskRadarFilterBar
                .padding(.horizontal, 12)

            if formatFamily == .pdf || diffReport?.supportsVisualPageOverlay == true || asset.mediaKind != .document {
                pdfVisualModeSelectorBar
                    .padding(.horizontal, 12)
            }

            if isLoadingDiff {
                ProgressView("正在比对两版差异与高危数值雷达…")
                    .font(.system(size: 13))
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
                wordAndTextDiffStage(report: report)
            } else if let diffError {
                Text(diffError)
                    .font(.system(size: 13))
                    .foregroundStyle(MobileTheme.destructive(for: colorScheme))
                    .padding(24)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var diffVersionSelectorHeader: some View {
        let baseVer = versionLabelForPicker(id: baseVersionID)
        let targetVer = versionLabelForPicker(id: targetVersionID)

        return HStack(spacing: 8) {
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
                HStack(spacing: 4) {
                    Text("旧版 \(baseVer)")
                        .font(.system(size: 12, weight: .semibold).monospacedDigit())
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                }
                .foregroundStyle(.primary)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(MobileTheme.surfaceElevated(for: colorScheme), in: Capsule())
                .overlay(Capsule().strokeBorder(MobileTheme.hairline(for: colorScheme), lineWidth: 0.75))
            }

            Button {
                MobileHaptics.light()
                let tmp = baseVersionID
                baseVersionID = targetVersionID
                targetVersionID = tmp
                Task { await reloadDiffReport() }
            } label: {
                Image(systemName: "arrow.left.arrow.right")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(MobileTheme.secondaryInk(for: colorScheme))
                    .frame(width: 28, height: 28)
                    .background(MobileTheme.surfaceSubtle(for: colorScheme), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("互换对比基准")

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
                HStack(spacing: 4) {
                    Text("新版 \(targetVer)")
                        .font(.system(size: 12, weight: .semibold).monospacedDigit())
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                }
                .foregroundStyle(.primary)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(MobileTheme.surfaceElevated(for: colorScheme), in: Capsule())
                .overlay(Capsule().strokeBorder(MobileTheme.hairline(for: colorScheme), lineWidth: 0.75))
            }

            Spacer(minLength: 4)

            if canLaunchTwoWayMerge {
                Button {
                    MobileHaptics.medium()
                    isMergeSheetPresented = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.triangle.merge")
                            .font(.system(size: 11.5, weight: .bold))
                        Text("按差异合成新版本")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 6.5)
                    .background(MobileTheme.accentButtonFill(for: colorScheme), in: Capsule())
                }
                .buttonStyle(MobileTactileButtonStyle())
            }
        }
    }

    private var highRiskRadarFilterBar: some View {
        let accent = MobileTheme.accent(for: colorScheme)
        let danger = MobileTheme.destructive(for: colorScheme)

        return VStack(spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(MobileRadarFilter.allCases) { filter in
                        let count = radarCount(for: filter)
                        let selected = radarFilter == filter
                        let isHighRisk = (filter == .numberOrCurrency || filter == .dateOrDeadline) && count > 0

                        Button {
                            MobileHaptics.selection()
                            withAnimation(MobileMotion.accessible(MobileMotion.settleStrong, reduced: reduceMotion)) {
                                radarFilter = filter
                                focusedHunkCursor = 0
                            }
                        } label: {
                            HStack(spacing: 4.5) {
                                Image(systemName: filter.symbol)
                                    .font(.system(size: 11, weight: .semibold))
                                Text(filter.rawValue)
                                    .font(.system(size: 12, weight: selected ? .semibold : .medium))
                                if count > 0 || filter == .all {
                                    Text("\(count)")
                                        .font(.system(size: 10.5, weight: .bold).monospacedDigit())
                                        .foregroundStyle(
                                            selected ? .white : (isHighRisk ? danger : MobileTheme.secondaryInk(for: colorScheme))
                                        )
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 1)
                                        .background(
                                            selected
                                                ? Color.white.opacity(0.22)
                                                : (isHighRisk ? danger.opacity(0.14) : MobileTheme.surfaceSubtle(for: colorScheme)),
                                            in: Capsule()
                                        )
                                }
                            }
                            .foregroundStyle(selected ? .white : (isHighRisk ? danger : .primary))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5.5)
                            .background(
                                selected
                                    ? (isHighRisk ? danger : accent)
                                    : MobileTheme.surfaceElevated(for: colorScheme),
                                in: Capsule()
                            )
                            .overlay(
                                Capsule().strokeBorder(
                                    selected ? .clear : (isHighRisk ? danger.opacity(0.35) : MobileTheme.hairline(for: colorScheme)),
                                    lineWidth: 0.75
                                )
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            HStack(spacing: 8) {
                Button {
                    MobileHaptics.light()
                    withAnimation(MobileMotion.accessible(MobileMotion.settleStrong, reduced: reduceMotion)) {
                        onlyChangedBlocks.toggle()
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: onlyChangedBlocks ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(onlyChangedBlocks ? accent : MobileTheme.tertiaryInk(for: colorScheme))
                        Text("仅看改动段落")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.primary)
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4.5)
                    .background(MobileTheme.surfaceElevated(for: colorScheme), in: Capsule())
                    .overlay(Capsule().strokeBorder(MobileTheme.hairline(for: colorScheme), lineWidth: 0.75))
                }
                .buttonStyle(.plain)

                if let sum = diffReport?.summary {
                    Text("+\(sum.addedBlocks) 新增 · -\(sum.removedBlocks) 删除 · ~\(sum.modifiedBlocks) 修改")
                        .font(.system(size: 11.5).monospacedDigit())
                        .foregroundStyle(MobileTheme.secondaryInk(for: colorScheme))
                        .lineLimit(1)
                }

                Spacer(minLength: 4)

                if diffReport?.usedOCR == true {
                    Text("Vision 离线 OCR")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(MobileTheme.warning(for: colorScheme))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(MobileTheme.warning(for: colorScheme).opacity(0.14), in: Capsule())
                }
            }
        }
    }

    private var pdfVisualModeSelectorBar: some View {
        HStack(spacing: 6) {
            ForEach(PDFDiffSubMode.allCases, id: \.self) { sub in
                let active = pdfDiffSubMode == sub
                Button {
                    MobileHaptics.selection()
                    withAnimation(MobileMotion.accessible(MobileMotion.settleStrong, reduced: reduceMotion)) {
                        pdfDiffSubMode = sub
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(
                            systemName: sub == .textOrOCR
                                ? "doc.text.magnifyingglass"
                                : (sub == .redCyan ? "circle.lefthalf.filled" : "square.split.2x1")
                        )
                        .font(.system(size: 11, weight: .semibold))
                        Text(sub.rawValue)
                            .font(.system(size: 12, weight: active ? .semibold : .medium))
                    }
                    .foregroundStyle(active ? .white : .primary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5.5)
                    .background(
                        active ? MobileTheme.accentButtonFill(for: colorScheme) : MobileTheme.surfaceElevated(for: colorScheme),
                        in: Capsule()
                    )
                    .overlay(
                        Capsule().strokeBorder(active ? .clear : MobileTheme.hairline(for: colorScheme), lineWidth: 0.75)
                    )
                }
                .buttonStyle(.plain)
            }

            Spacer()

            if pdfDiffSubMode == .textOrOCR && formatFamily == .pdf {
                Button {
                    useOCRIfScanned.toggle()
                    Task { await reloadDiffReport() }
                } label: {
                    Text(useOCRIfScanned ? "扫描 OCR: 开" : "扫描 OCR: 关")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(MobileTheme.accent(for: colorScheme))
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Word / Text Inline Diff Stage (Move Badges + High-Risk Callouts)

    private func wordAndTextDiffStage(report: DocumentComparisonReport) -> some View {
        let hunks = filteredDiffHunks
        return ScrollViewReader { scrollProxy in
            VStack(spacing: 0) {
                if hunks.count > 1 {
                    HStack {
                        Text("匹配 \(hunks.count) 处段落")
                            .font(.system(size: 11.5, weight: .medium).monospacedDigit())
                            .foregroundStyle(MobileTheme.tertiaryInk(for: colorScheme))
                        Spacer()
                        HStack(spacing: 6) {
                            Button {
                                guard !hunks.isEmpty else { return }
                                focusedHunkCursor = max(0, focusedHunkCursor - 1)
                                withAnimation(MobileMotion.settleStrong) {
                                    scrollProxy.scrollTo(hunks[focusedHunkCursor].id, anchor: .top)
                                }
                            } label: {
                                Label("上一处", systemImage: "chevron.up")
                                    .font(.system(size: 11.5, weight: .semibold))
                            }
                            .buttonStyle(.plain)

                            Button {
                                guard !hunks.isEmpty else { return }
                                focusedHunkCursor = min(hunks.count - 1, focusedHunkCursor + 1)
                                withAnimation(MobileMotion.settleStrong) {
                                    scrollProxy.scrollTo(hunks[focusedHunkCursor].id, anchor: .top)
                                }
                            } label: {
                                Label("下一处", systemImage: "chevron.down")
                                    .font(.system(size: 11.5, weight: .semibold))
                            }
                            .buttonStyle(.plain)
                        }
                        .foregroundStyle(MobileTheme.accent(for: colorScheme))
                    }
                    .padding(.horizontal, 14)
                    .padding(.bottom, 6)
                }

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        if hunks.isEmpty && (radarFilter != .nativeRevisionOrComment || report.commentDiffs.isEmpty) {
                            VStack(spacing: 8) {
                                Image(systemName: "checkmark.seal")
                                    .font(.system(size: 24))
                                    .foregroundStyle(MobileTheme.positive(for: colorScheme))
                                Text(radarFilter == .all ? "这两版正文内容完全一致" : "当前「\(radarFilter.rawValue)」筛选下无变动")
                                    .font(.system(size: 13.5, weight: .medium))
                                    .foregroundStyle(MobileTheme.secondaryInk(for: colorScheme))
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 48)
                        }

                        ForEach(hunks) { hunk in
                            diffHunkCard(hunk)
                                .id(hunk.id)
                        }

                        if !report.commentDiffs.isEmpty && (radarFilter == .all || radarFilter == .nativeRevisionOrComment) {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("原生批注变动（\(report.commentDiffs.count)）")
                                    .font(.system(size: 12.5, weight: .semibold).monospacedDigit())
                                    .foregroundStyle(MobileTheme.warning(for: colorScheme))
                                ForEach(report.commentDiffs) { cDiff in
                                    HStack(alignment: .top, spacing: 8) {
                                        Text(cDiff.changeKind.localizedLabel)
                                            .font(.system(size: 10.5, weight: .bold))
                                            .foregroundStyle(changeKindColor(cDiff.changeKind))
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(changeKindColor(cDiff.changeKind).opacity(0.14), in: Capsule())
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
                                    .background(MobileTheme.surfaceElevated(for: colorScheme), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 20)
                }
            }
        }
    }

    private func diffHunkCard(_ hunk: DocumentDiffHunk) -> some View {
        let kindColor = changeKindColor(hunk.changeKind)
        let danger = MobileTheme.destructive(for: colorScheme)
        let warn = MobileTheme.warning(for: colorScheme)

        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(hunk.changeKind.localizedLabel)
                    .font(.system(size: 10.5, weight: .bold))
                    .foregroundStyle(kindColor)
                    .padding(.horizontal, 6.5)
                    .padding(.vertical, 2)
                    .background(kindColor.opacity(0.14), in: Capsule())

                if let sec = hunk.sectionTitle, !sec.isEmpty {
                    Text(sec)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                } else if let p = hunk.pageNumber {
                    Text("第 \(p) 页")
                        .font(.system(size: 11.5, weight: .medium).monospacedDigit())
                        .foregroundStyle(MobileTheme.secondaryInk(for: colorScheme))
                }

                // Move Badge (prevents false-positive full red/green rewrite!)
                if let from = hunk.movedFromIndex {
                    let to = hunk.movedToIndex ?? hunk.targetBlockIndex ?? hunk.hunkIndex
                    HStack(spacing: 3) {
                        Image(systemName: "arrow.up.arrow.down")
                            .font(.system(size: 9.5, weight: .bold))
                        Text("自第 \(from + 1) 段移至第 \(to + 1) 段")
                            .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                    }
                    .foregroundStyle(MobileTheme.accent(for: colorScheme))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(MobileTheme.accentSoft(for: colorScheme), in: Capsule())
                }

                if hunk.isProtectedComplex {
                    HStack(spacing: 3) {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 9.5))
                        Text("受保护结构")
                            .font(.system(size: 10.5, weight: .medium))
                    }
                    .foregroundStyle(MobileTheme.secondaryInk(for: colorScheme))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(MobileTheme.surfaceSubtle(for: colorScheme), in: Capsule())
                }

                Spacer()

                if let copyText = hunk.targetText ?? hunk.baseText, !copyText.isEmpty {
                    Button {
                        UIPasteboard.general.string = copyText
                        MobileHaptics.light()
                        store.showToast("已复制该段内容", tone: .info)
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 12))
                            .foregroundStyle(MobileTheme.tertiaryInk(for: colorScheme))
                    }
                    .buttonStyle(.plain)
                }
            }

            // High-Risk Value Pairs Radar Callouts
            if !hunk.highRiskPairs.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(hunk.highRiskPairs) { pair in
                            let isNum = pair.flag == .numberOrCurrency
                            let badgeTint = isNum ? danger : warn
                            HStack(spacing: 4) {
                                Image(systemName: isNum ? "yensign.circle.fill" : "calendar")
                                    .font(.system(size: 11, weight: .semibold))
                                if let oldVal = pair.oldValue, !oldVal.isEmpty {
                                    Text(oldVal)
                                        .strikethrough()
                                        .opacity(0.80)
                                }
                                if pair.oldValue != nil && pair.newValue != nil {
                                    Text("→")
                                }
                                if let newVal = pair.newValue, !newVal.isEmpty {
                                    Text(newVal)
                                        .fontWeight(.bold)
                                }
                            }
                            .font(.system(size: 11.5).monospacedDigit())
                            .foregroundStyle(badgeTint)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3.5)
                            .background(badgeTint.opacity(0.13), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        }
                    }
                }
            }

            // Inline Token Diff Text
            if !hunk.inlineTokens.isEmpty {
                Text(buildInlineDiffAttributedString(tokens: hunk.inlineTokens))
                    .font(.system(size: 14.5))
                    .lineSpacing(4)
                    .textSelection(.enabled)
            } else {
                if let oldText = hunk.baseText, !oldText.isEmpty, hunk.changeKind != .unchanged {
                    Text(oldText)
                        .font(.system(size: 14))
                        .strikethrough()
                        .foregroundStyle(danger)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(danger.opacity(0.09), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
                if let newText = hunk.targetText, !newText.isEmpty {
                    Text(newText)
                        .font(.system(size: 14.5))
                        .foregroundStyle(hunk.changeKind == .unchanged ? .primary : MobileTheme.positive(for: colorScheme))
                        .padding(hunk.changeKind == .unchanged ? 0 : 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            hunk.changeKind == .unchanged ? .clear : MobileTheme.positive(for: colorScheme).opacity(0.09),
                            in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                        )
                }
            }

            // Embedded Word Table Cell Diffs
            if !hunk.tableCellDiffs.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(hunk.tableCellDiffs) { cell in
                        HStack(spacing: 6) {
                            Text(cell.columnHeader ?? "第 \(cell.rowIndex + 1) 行 · 第 \(cell.colIndex + 1) 列")
                                .font(.system(size: 11.5, weight: .semibold))
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
                                .foregroundStyle(MobileTheme.positive(for: colorScheme))
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(MobileTheme.inspectorFieldSurface(for: colorScheme), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: 780, alignment: .leading)
        .background(
            MobileTheme.surfaceElevated(for: colorScheme),
            in: RoundedRectangle(cornerRadius: MobileTheme.Radius.cardOuter, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: MobileTheme.Radius.cardOuter, style: .continuous)
                .strokeBorder(
                    !hunk.highRiskPairs.isEmpty ? danger.opacity(0.40) : MobileTheme.hairline(for: colorScheme),
                    lineWidth: !hunk.highRiskPairs.isEmpty ? 1.1 : 0.75
                )
        )
    }

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

    // MARK: - Excel Smart Primary-Key Aligned Diff Stage

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
                                        Text("Δ\(totalRowDelta)")
                                            .font(.system(size: 10.5, weight: .bold).monospacedDigit())
                                            .padding(.horizontal, 5)
                                            .padding(.vertical, 1)
                                            .background(Color.white.opacity(isOn ? 0.22 : 0.0), in: Capsule())
                                    }
                                    .foregroundStyle(isOn ? .white : .primary)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5.5)
                                    .background(
                                        isOn ? Color(charkleHex: "#1D7A46") : MobileTheme.surfaceElevated(for: colorScheme),
                                        in: Capsule()
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
                                    .font(.system(size: 10.5))
                                Text("主键：\(activeSheet.primaryKeyHeader ?? "自动")")
                                    .font(.system(size: 11.5, weight: .semibold))
                                    .lineLimit(1)
                            }
                            .foregroundStyle(Color(charkleHex: "#1D7A46"))
                            .padding(.horizontal, 9)
                            .padding(.vertical, 5)
                            .background(Color(charkleHex: "#1D7A46").opacity(0.14), in: Capsule())
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

                    LazyVStack(alignment: .leading, spacing: 8) {
                        if rows.isEmpty {
                            Text("该工作表在当前筛选条件下无单元格变动")
                                .font(.system(size: 13))
                                .foregroundStyle(MobileTheme.secondaryInk(for: colorScheme))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 44)
                        } else {
                            ForEach(rows) { row in
                                spreadsheetRowDiffCard(row, headers: activeSheet.headers)
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 20)
                }
            }
        }
    }

    private func spreadsheetRowDiffCard(_ row: SpreadsheetRowDiff, headers: [String]) -> some View {
        let kindTint = changeKindColor(row.changeKind)
        let danger = MobileTheme.destructive(for: colorScheme)
        let pos = MobileTheme.positive(for: colorScheme)

        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(row.changeKind.localizedLabel)
                    .font(.system(size: 10.5, weight: .bold))
                    .foregroundStyle(kindTint)
                    .padding(.horizontal, 6.5)
                    .padding(.vertical, 2)
                    .background(kindTint.opacity(0.14), in: Capsule())

                Text(row.primaryKeyValue.isEmpty ? "行记录" : row.primaryKeyValue)
                    .font(.system(size: 13, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Spacer()

                let rowLoc: String = {
                    switch (row.baseRowNumber, row.targetRowNumber) {
                    case let (b?, t?) where b != t: "旧#\(b) → 新#\(t)"
                    case let (_, t?): "行 #\(t)"
                    case let (b?, nil): "原行 #\(b)"
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
                                .font(.system(size: 11.5, weight: .semibold))
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
                                    .font(.system(size: 12.5, weight: .bold).monospacedDigit())
                                    .foregroundStyle(pos)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 1.5)
                                    .background(pos.opacity(0.13), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                            }
                        }

                        if cell.oldFormula != cell.newFormula, (cell.oldFormula != nil || cell.newFormula != nil) {
                            HStack(spacing: 4) {
                                Text("fx 公式变更：")
                                    .font(.system(size: 10.5, weight: .semibold))
                                Text("=\(cell.oldFormula ?? "无") → =\(cell.newFormula ?? "无")")
                                    .font(.system(size: 10.5, design: .monospaced))
                            }
                            .foregroundStyle(MobileTheme.warning(for: colorScheme))
                        }
                    }
                    .padding(8)
                    .background(MobileTheme.inspectorFieldSurface(for: colorScheme), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
            } else {
                let values = !row.targetValues.isEmpty ? row.targetValues : row.baseValues
                Text(values.filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.system(size: 12.5).monospacedDigit())
                    .foregroundStyle(row.changeKind == .removed ? danger : .primary)
            }
        }
        .padding(12)
        .background(
            MobileTheme.surfaceElevated(for: colorScheme),
            in: RoundedRectangle(cornerRadius: MobileTheme.Radius.cardOuter, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: MobileTheme.Radius.cardOuter, style: .continuous)
                .strokeBorder(MobileTheme.hairline(for: colorScheme), lineWidth: 0.75)
        )
    }

    // MARK: - Data Loading Helpers

    private func loadReaderData(for target: AssetRecord) async {
        isLoadingPayload = true
        payloadError = nil
        selectedSheetIndex = 0
        selectedFormulaDetail = nil

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

    private func versionLabelForPicker(id: UUID) -> String {
        guard let item = stackSiblings.first(where: { $0.id == id }) ?? store.liveAsset(id: id) else {
            return "版本"
        }
        let v = item.richMetadata?.versionStack?.versionNumber
            ?? ((stackSiblings.firstIndex(where: { $0.id == id }) ?? 0) + 1)
        let isPrimary = item.id == primaryAsset.id
        let who = item.richMetadata?.versionStack?.editorName
        var label = "v\(v)"
        if let who, !who.isEmpty { label += "·\(who)" }
        if isPrimary { label += " [主版]" }
        return label
    }

    private func changeKindColor(_ kind: DocumentDiffChangeKind) -> Color {
        switch kind {
        case .added: MobileTheme.positive(for: colorScheme)
        case .removed: MobileTheme.destructive(for: colorScheme)
        case .modified: MobileTheme.warning(for: colorScheme)
        case .moved: MobileTheme.accent(for: colorScheme)
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

// MARK: - Scanned PDF & Visual Stack Overlay Diff (Red-Cyan Blend & Touch-Draggable Split Curtain Wipe)

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
                    ProgressView("正在生成页面像素比对图层…")
                        .font(.system(size: 13))
                } else if isSplitCurtain, let baseImage, let targetImage {
                    GeometryReader { geo in
                        let w = max(1, geo.size.width)
                        let h = max(1, geo.size.height)
                        let dividerX = w * curtainFraction

                        ZStack(alignment: .leading) {
                            // Full-width New Version (Target) underneath
                            Image(uiImage: targetImage)
                                .resizable()
                                .scaledToFit()
                                .frame(width: w, height: h)

                            // Left-clipped Old Version (Base) on top
                            Image(uiImage: baseImage)
                                .resizable()
                                .scaledToFit()
                                .frame(width: w, height: h)
                                .mask(alignment: .leading) {
                                    Rectangle()
                                        .frame(width: dividerX, height: h)
                                }

                            // Curtain Divider Line & Touch Thumb
                            ZStack {
                                Rectangle()
                                    .fill(MobileTheme.accent(for: colorScheme))
                                    .frame(width: 2, height: h)
                                    .shadow(color: .black.opacity(0.28), radius: 3)

                                Circle()
                                    .fill(MobileTheme.accentButtonFill(for: colorScheme))
                                    .frame(width: 36, height: 36)
                                    .overlay {
                                        Image(systemName: "arrow.left.and.right")
                                            .font(.system(size: 13, weight: .bold))
                                            .foregroundStyle(.white)
                                    }
                                    .shadow(color: .black.opacity(0.25), radius: 6, y: 2)
                            }
                            .position(x: dividerX, y: h * 0.5)

                            // Corner Version Labels
                            VStack {
                                HStack {
                                    Text("◀ 旧版 \(baseAsset.richMetadata?.versionStack?.displayVersionTag ?? "基准")")
                                        .font(.system(size: 11, weight: .semibold).monospacedDigit())
                                        .foregroundStyle(.white)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 4)
                                        .background(.black.opacity(0.62), in: Capsule())
                                    Spacer()
                                    Text("新版 \(targetAsset.richMetadata?.versionStack?.displayVersionTag ?? "当前") ▶")
                                        .font(.system(size: 11, weight: .semibold).monospacedDigit())
                                        .foregroundStyle(.white)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 4)
                                        .background(MobileTheme.accentButtonFill(for: colorScheme).opacity(0.88), in: Capsule())
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
                    ZStack(alignment: .top) {
                        Image(uiImage: redCyanImage)
                            .resizable()
                            .scaledToFit()
                            .padding(8)

                        HStack(spacing: 10) {
                            HStack(spacing: 4) {
                                Circle().fill(Color(charkleHex: "#D93B30")).frame(width: 8, height: 8)
                                Text("红色：旧版独有笔迹/印章")
                            }
                            HStack(spacing: 4) {
                                Circle().fill(Color(charkleHex: "#0891B2")).frame(width: 8, height: 8)
                                Text("青色：新版新增批示/改动")
                            }
                        }
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .background(.black.opacity(0.68), in: Capsule())
                        .padding(.top, 10)
                    }
                } else {
                    Text("无法渲染这两版的视觉叠层预览")
                        .font(.system(size: 13))
                        .foregroundStyle(MobileTheme.secondaryInk(for: colorScheme))
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: MobileTheme.Radius.cardOuter, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: MobileTheme.Radius.cardOuter, style: .continuous)
                    .strokeBorder(MobileTheme.hairline(for: colorScheme), lineWidth: 0.75)
            )

            if pageCount > 1 {
                HStack(spacing: 14) {
                    Button {
                        MobileHaptics.light()
                        pageIndex = max(0, pageIndex - 1)
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 13, weight: .bold))
                            .frame(width: 30, height: 30)
                    }
                    .disabled(pageIndex <= 0)

                    Text("第 \(pageIndex + 1) / \(pageCount) 页")
                        .font(.system(size: 12.5, weight: .semibold).monospacedDigit())

                    Button {
                        MobileHaptics.light()
                        pageIndex = min(pageCount - 1, pageIndex + 1)
                    } label: {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 13, weight: .bold))
                            .frame(width: 30, height: 30)
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

    /// Combines Base luminance into Cyan-blocked channel (so Base ink renders Red) and Target luminance
    /// into Red-blocked channel (so Target ink renders Cyan), while shared ink converges to neutral charcoal!
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
            // Red channel comes from Target lightness (dark Base drops G & B -> appears Red; dark Target drops R -> appears Cyan)
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

// MARK: - Scheme B Safe 2-Way Document Merge Sheet (`按差异合成新版本`)

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

    @State private var preferTargetAsTemplate: Bool = true
    @State private var choiceByHunkID: [String: DocumentMergeDecision.Choice] = [:]
    @State private var customTextByHunkID: [String: String] = [:]
    @State private var showCleanPreview: Bool = false
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
            let custom = choice == .customText ? (customTextByHunkID[hunk.id] ?? hunk.targetText ?? hunk.baseText ?? "") : nil
            return DocumentMergeDecision(hunkID: hunk.id, choice: choice, customText: custom)
        }
    }

    private var revertedCount: Int {
        compiledDecisions.filter {
            $0.choice != (preferTargetAsTemplate ? .acceptTarget : .keepBase)
        }.count
    }

    var body: some View {
        let accent = MobileTheme.accent(for: colorScheme)
        let pos = MobileTheme.positive(for: colorScheme)
        let warn = MobileTheme.warning(for: colorScheme)
        let danger = MobileTheme.destructive(for: colorScheme)

        VStack(spacing: 0) {
            if let createdAsset {
                // Celebratory Ready-to-Send Card with 1-Tap WeChat Share
                VStack(spacing: 18) {
                    Spacer()

                    ZStack {
                        Circle()
                            .fill(pos.opacity(0.15))
                            .frame(width: 64, height: 64)
                        Image(systemName: "checkmark.seal.fill")
                            .font(.system(size: 30, weight: .bold))
                            .foregroundStyle(pos)
                    }

                    VStack(spacing: 6) {
                        Text("已生成净版 \(createdAsset.richMetadata?.versionStack?.displayVersionTag ?? "v\(nextVersionNumber)")")
                            .font(.system(size: 20, weight: .bold).monospacedDigit())
                        Text("原稿完整保留未覆盖，新版本已自动锁定为主版本，可直接发回微信。")
                            .font(.system(size: 13.5))
                            .foregroundStyle(MobileTheme.secondaryInk(for: colorScheme))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 24)
                    }

                    VStack(spacing: 10) {
                        Button {
                            MobileHaptics.success()
                            Task {
                                if let url = await store.shareableOriginalURL(for: createdAsset, preferExactAsset: true) {
                                    onShareCreated(url)
                                }
                            }
                        } label: {
                            Label("一键分享定稿到微信 / 文件", systemImage: "square.and.arrow.up")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(.white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 13)
                                .background(MobileTheme.accentButtonFill(for: colorScheme), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                        .buttonStyle(MobileTactileButtonStyle())

                        Button {
                            onOpenCreatedVersion(createdAsset)
                        } label: {
                            Text("在阅读器中查看新版本")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(accent)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 11)
                                .background(MobileTheme.accentSoft(for: colorScheme), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                        .buttonStyle(MobileTactileButtonStyle())
                    }
                    .padding(.horizontal, 24)
                    .frame(maxWidth: 440)

                    Spacer()
                }
                .background(MobileTheme.galleryGround(for: colorScheme))
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        // 1. Base Template Picker + Zero-Corruption Notice
                        VStack(alignment: .leading, spacing: 8) {
                            Text("选择合成底稿（默认保留底稿完整红头、字体与样式外壳）")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(MobileTheme.secondaryInk(for: colorScheme))

                            Picker("底稿基准", selection: $preferTargetAsTemplate) {
                                Text("以新版为底稿（推荐）").tag(true)
                                Text("以旧版为底稿").tag(false)
                            }
                            .pickerStyle(.segmented)

                            HStack(spacing: 6) {
                                Image(systemName: "checkmark.shield.fill")
                                    .font(.system(size: 12))
                                    .foregroundStyle(pos)
                                Text("仅对普通正文段落做节点级替换；复杂跨行表格与域代码自动只读保护，100% 零坏档。")
                                    .font(.system(size: 11.5))
                                    .foregroundStyle(MobileTheme.secondaryInk(for: colorScheme))
                            }
                        }
                        .padding(12)
                        .background(MobileTheme.surfaceElevated(for: colorScheme), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                        // 2. Hunk Picker <-> Clean Preview Switcher
                        HStack {
                            Picker("合成检视", selection: $showCleanPreview) {
                                Text("逐处取舍 (\(changedHunks.count))").tag(false)
                                Text("净版全文预览").tag(true)
                            }
                            .pickerStyle(.segmented)
                            .frame(maxWidth: 260)

                            Spacer()

                            Text("已调整 \(revertedCount) 处")
                                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                                .foregroundStyle(revertedCount > 0 ? warn : MobileTheme.tertiaryInk(for: colorScheme))
                        }

                        if showCleanPreview {
                            let mergedPreview = report.previewMergedText(
                                preferTargetAsTemplate: preferTargetAsTemplate,
                                decisions: compiledDecisions
                            )
                            VStack(alignment: .leading, spacing: 8) {
                                Text("合成后净版正文预览")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(MobileTheme.secondaryInk(for: colorScheme))
                                Text(mergedPreview.isEmpty ? "（无正文内容）" : mergedPreview)
                                    .font(.system(size: 14.5))
                                    .lineSpacing(4.5)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .padding(16)
                            .background(MobileTheme.surfaceElevated(for: colorScheme), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        } else {
                            ForEach(changedHunks) { hunk in
                                let currentChoice = choiceByHunkID[hunk.id] ?? (preferTargetAsTemplate ? .acceptTarget : .keepBase)

                                VStack(alignment: .leading, spacing: 8) {
                                    HStack {
                                        Text(hunk.sectionTitle ?? "变动 #\(hunk.hunkIndex + 1)")
                                            .font(.system(size: 12.5, weight: .semibold))
                                        if !hunk.highRiskPairs.isEmpty {
                                            Text("高危数值/日期")
                                                .font(.system(size: 10.5, weight: .bold))
                                                .foregroundStyle(danger)
                                                .padding(.horizontal, 6)
                                                .padding(.vertical, 1.5)
                                                .background(danger.opacity(0.14), in: Capsule())
                                        }
                                        Spacer()
                                        if hunk.isProtectedComplex {
                                            HStack(spacing: 4) {
                                                Image(systemName: "lock.fill")
                                                    .font(.system(size: 10))
                                                Text(hunk.protectionReason ?? "受保护复杂结构")
                                                    .font(.system(size: 11, weight: .semibold))
                                            }
                                            .foregroundStyle(warn)
                                            .padding(.horizontal, 8)
                                            .padding(.vertical, 3)
                                            .background(warn.opacity(0.14), in: Capsule())
                                        }
                                    }

                                    if let oldT = hunk.baseText, !oldT.isEmpty {
                                        HStack(alignment: .top, spacing: 6) {
                                            Text("旧版")
                                                .font(.system(size: 10.5, weight: .bold))
                                                .foregroundStyle(danger)
                                                .padding(.top, 2)
                                            Text(oldT)
                                                .font(.system(size: 13))
                                                .foregroundStyle(currentChoice == .keepBase ? .primary : MobileTheme.secondaryInk(for: colorScheme))
                                                .strikethrough(currentChoice != .keepBase)
                                        }
                                    }

                                    if let newT = hunk.targetText, !newT.isEmpty {
                                        HStack(alignment: .top, spacing: 6) {
                                            Text("新版")
                                                .font(.system(size: 10.5, weight: .bold))
                                                .foregroundStyle(pos)
                                                .padding(.top, 2)
                                            Text(newT)
                                                .font(.system(size: 13, weight: currentChoice == .acceptTarget ? .medium : .regular))
                                                .foregroundStyle(currentChoice == .acceptTarget ? .primary : MobileTheme.secondaryInk(for: colorScheme))
                                        }
                                    }

                                    if hunk.isProtectedComplex {
                                        HStack {
                                            Text("此复杂块将原样保留底稿结构，如需修改可在生成后用 Word/WPS 打开。")
                                                .font(.system(size: 11.5))
                                                .foregroundStyle(MobileTheme.tertiaryInk(for: colorScheme))
                                            Spacer()
                                            Button("分享打开") {
                                                let ref = preferTargetAsTemplate ? targetAsset : baseAsset
                                                Task {
                                                    if let url = await store.shareableOriginalURL(for: ref, preferExactAsset: true) {
                                                        onShareCreated(url)
                                                    }
                                                }
                                            }
                                            .font(.system(size: 11.5, weight: .semibold))
                                            .foregroundStyle(accent)
                                        }
                                    } else {
                                        HStack(spacing: 6) {
                                            ForEach(DocumentMergeDecision.Choice.allCases, id: \.self) { choice in
                                                let active = currentChoice == choice
                                                Button {
                                                    MobileHaptics.selection()
                                                    choiceByHunkID[hunk.id] = choice
                                                    if choice == .customText && customTextByHunkID[hunk.id] == nil {
                                                        customTextByHunkID[hunk.id] = hunk.targetText ?? hunk.baseText ?? ""
                                                    }
                                                } label: {
                                                    Text(choice.localizedLabel)
                                                        .font(.system(size: 12, weight: active ? .semibold : .medium))
                                                        .foregroundStyle(active ? .white : .primary)
                                                        .frame(maxWidth: .infinity)
                                                        .padding(.vertical, 6.5)
                                                        .background(
                                                            active ? accent : MobileTheme.surfaceSubtle(for: colorScheme),
                                                            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                                                        )
                                                }
                                                .buttonStyle(.plain)
                                            }
                                        }

                                        if currentChoice == .customText {
                                            TextField(
                                                "直接微调该段定稿措辞…",
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
                                            .overlay(
                                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                                    .strokeBorder(accent.opacity(0.45), lineWidth: 1)
                                            )
                                        }
                                    }
                                }
                                .padding(12)
                                .background(MobileTheme.surfaceElevated(for: colorScheme), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .strokeBorder(MobileTheme.hairline(for: colorScheme), lineWidth: 0.75)
                                )
                            }
                        }

                        // 3. Version Attribution Fields
                        VStack(alignment: .leading, spacing: 8) {
                            Text("新版本信息（可选）")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(MobileTheme.secondaryInk(for: colorScheme))
                            HStack(spacing: 8) {
                                TextField("定稿人（如：我）", text: $editorNameDraft)
                                    .font(.system(size: 13))
                                    .padding(9)
                                    .frame(maxWidth: 140)
                                    .background(MobileTheme.surfaceElevated(for: colorScheme), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                                TextField("版本备注（默认：挑拣合成净版）", text: $changeNoteDraft)
                                    .font(.system(size: 13))
                                    .padding(9)
                                    .background(MobileTheme.surfaceElevated(for: colorScheme), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                            }
                        }
                    }
                    .padding(16)
                }
                .charkleDismissKeyboardOnScroll()
                .background(MobileTheme.galleryGround(for: colorScheme))
                .safeAreaInset(edge: .bottom) {
                    HStack(spacing: 12) {
                        Button {
                            showCleanPreview.toggle()
                        } label: {
                            Text(showCleanPreview ? "返回挑拣" : "净版预览")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(.primary)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 12)
                                .background(MobileTheme.surfaceElevated(for: colorScheme), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .strokeBorder(MobileTheme.borderStrong(for: colorScheme), lineWidth: 0.75)
                                )
                        }
                        .buttonStyle(MobileTactileButtonStyle())

                        Button {
                            synthesizeNow()
                        } label: {
                            HStack(spacing: 6) {
                                if isSynthesizing {
                                    ProgressView().controlSize(.small).tint(.white)
                                } else {
                                    Image(systemName: "sparkles")
                                }
                                Text(isSynthesizing ? "正在生成净版…" : "生成新版本 v\(nextVersionNumber)")
                                    .font(.system(size: 14.5, weight: .semibold).monospacedDigit())
                            }
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(MobileTheme.accentButtonFill(for: colorScheme), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
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
        .navigationTitle("按差异合成新版本")
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
        let defaultNote = revertedCount > 0 ? "挑拣合成(调整\(revertedCount)处)" : "确认合成定稿"
        let decisions = compiledDecisions
        let preferTarget = preferTargetAsTemplate

        Task {
            do {
                let created = try await store.engine.synthesizeDocumentVersion(
                    baseAssetID: report.baseAssetID,
                    targetAssetID: report.targetAssetID,
                    preferTargetAsTemplate: preferTarget,
                    decisions: decisions,
                    editorName: ed.isEmpty ? nil : ed,
                    changeNote: noteRaw.isEmpty ? defaultNote : noteRaw
                )
                _ = try? await store.engine.manageVersionStack(.setPrimary(assetID: created.id))
                await store.reloadAll()
                MobileHaptics.success()
                createdAsset = store.liveAsset(id: created.id) ?? created
                store.showToast("已合成 v\(nextVersionNumber) 并自动设为主版本", tone: .success)
                if store.hasConnectedCloudBackend {
                    Task { await store.syncNow(quiet: true) }
                }
            } catch {
                MobileHaptics.error()
                store.showToast("合成新版本失败：\(error.localizedDescription)", tone: .error)
            }
            isSynthesizing = false
        }
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
                ProgressView("正在打开 PDF…")
                    .font(.system(size: 13))
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
