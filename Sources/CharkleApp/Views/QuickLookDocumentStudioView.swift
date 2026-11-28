import AppKit
import CharkleCanvas
import CharkleCore
import PDFKit
import QuickLookUI
import SwiftUI

/// Dedicated Quick Look Document Studio supporting:
/// 1. Native high-craft readers for `.docx`/Office (`QLPreviewView` true paper layout + structured blocks/comments), `.xlsx`, `.pdf`, and `.md` / `.txt`
/// 2. Multi-modal Version Stack Diff with High-Risk Radar (`全部改动` / `数字变动` / `日期时间` / `表格变动` / `原生修订/批注`),
///    fold-unchanged toggle, `J / K` keyboard hunk stepping, inline & side-by-side Word/text diff,
///    Primary-Key-aligned Excel sheet diff, and scanned PDF offline Vision OCR + Red-Cyan blend + Split Curtain Wipe
/// 3. Scheme B deterministic 2-Way Merge (`按差异合成新版本`) with complex-block protection guardrails and clean preview.
public struct QuickLookDocumentStudioView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.charkleAccentSource) private var accentSource
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public enum StudioMode: String, CaseIterable, Identifiable, Sendable {
        case reader
        case diff
        case merge

        public var id: String { rawValue }
    }

    public enum ReaderPresentationMode: String, CaseIterable, Identifiable, Sendable {
        case nativeLayout
        case structuredContent

        public var id: String { rawValue }
    }

    public typealias RiskRadarFilter = DocumentRiskRadarFilter

    public enum TextDiffLayout: String, CaseIterable, Identifiable, Sendable {
        case inlineReview
        case sideBySide

        public var id: String { rawValue }
    }

    public enum PDFDiffVisualMode: String, CaseIterable, Identifiable, Sendable {
        case textOrOCR
        case redCyanOverlay
        case splitCurtain

        public var id: String { rawValue }
    }

    public let asset: AssetRecord
    public let originalURL: URL?
    public let library: LibraryStore
    public let coordinator: AppCoordinatorStore

    @State private var studioMode: StudioMode = .reader
    @State private var readerPresentationMode: ReaderPresentationMode = .nativeLayout
    @State private var payload: StructuredDocumentPayload? = nil
    @State private var isLoadingPayload: Bool = false
    @State private var showRawMarkdownSource: Bool = false
    @State private var showPDFExtractedText: Bool = false
    @State private var selectedSheetIndex: Int = 0
    @State private var isCommentsExpanded: Bool = true

    // Diff & Radar state
    @State private var compareBaseAssetID: UUID? = nil
    @State private var compareTargetAssetID: UUID? = nil
    @State private var comparisonReport: DocumentComparisonReport? = nil
    @State private var isComparing: Bool = false
    @State private var activeRiskFilter: RiskRadarFilter = .all
    @State private var onlyChangedBlocks: Bool = true
    @State private var textDiffLayout: TextDiffLayout = .inlineReview
    @State private var focusedHunkID: String? = nil
    @State private var selectedDiffSheetName: String? = nil
    @State private var customPrimaryKeyCol: Int? = nil
    @State private var useOCRIfScanned: Bool = false

    // PDF Visual Overlay / Split Curtain state
    @State private var pdfVisualMode: PDFDiffVisualMode = .textOrOCR
    @State private var pdfPageIndex: Int = 0
    @State private var pdfPageCount: Int = 1
    @State private var pdfBasePageImage: NSImage? = nil
    @State private var pdfTargetPageImage: NSImage? = nil
    @State private var pdfRedCyanImage: NSImage? = nil
    @State private var isRenderingPDFVisual: Bool = false
    @State private var curtainFraction: CGFloat = 0.50

    // Scheme B 2-Way Merge state
    @State private var preferTargetAsTemplate: Bool = true
    @State private var mergeDecisionsByHunkID: [String: DocumentMergeDecision] = [:]
    @State private var isMergePreviewExpanded: Bool = false
    @State private var mergeEditorDraft: String = ""
    @State private var mergeNoteDraft: String = "挑拣合成净版"
    @State private var isSynthesizing: Bool = false
    @State private var lastConsumedDiffNonce: UUID? = nil

    public init(
        asset: AssetRecord,
        originalURL: URL?,
        library: LibraryStore,
        coordinator: AppCoordinatorStore
    ) {
        self.asset = asset
        self.originalURL = originalURL
        self.library = library
        self.coordinator = coordinator
    }

    private var activeAccent: Color {
        CharkleTheme.accent(for: colorScheme, source: accentSource)
    }

    private var siblings: [AssetRecord] {
        library.versionStackSiblings(for: asset.id)
    }

    private var primaryAsset: AssetRecord {
        library.primaryVersionAsset(for: asset.id) ?? asset
    }

    private var fileExtensionLowercased: String {
        (asset.fileName as NSString).pathExtension.lowercased()
    }

    private var docFamily: DocumentFormatFamily {
        if let familyStr = payload?.formatFamily ?? asset.richMetadata?.document?.formatFamily,
           let parsed = DocumentFormatFamily(rawValue: familyStr),
           parsed != .other {
            return parsed
        }
        return DocumentFormatFamily.detect(fileExtension: fileExtensionLowercased)
    }

    private var supportsNativeOfficeLayout: Bool {
        Self.supportsNativeOfficeLayoutPreview(formatFamily: docFamily, fileExtension: fileExtensionLowercased)
    }

    private var isSpreadsheetFamily: Bool {
        docFamily == .xlsx || !(payload?.sheets.isEmpty ?? true)
    }

    private var baseVersionBadgeLabel: String {
        versionShortBadge(for: compareBaseAssetID, fallbackNumber: 1)
    }

    private var targetVersionBadgeLabel: String {
        versionShortBadge(for: compareTargetAssetID, fallbackNumber: 2)
    }

    private func versionShortBadge(for assetID: UUID?, fallbackNumber: Int) -> String {
        if let assetID {
            if let idx = siblings.firstIndex(where: { $0.id == assetID }) {
                let ver = siblings[idx]
                let vNum = ver.richMetadata?.versionStack?.versionNumber ?? (idx + 1)
                return "v\(vNum)"
            }
            if let ver = library.allAssetsByID[assetID],
               let vMeta = ver.richMetadata?.versionStack {
                return "v\(vMeta.versionNumber)"
            }
        }
        return "v\(fallbackNumber)"
    }

    public static func supportsNativeOfficeLayoutPreview(
        formatFamily: DocumentFormatFamily,
        fileExtension: String
    ) -> Bool {
        let ext = fileExtension.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
        if ext == "pdf" || formatFamily == .pdf {
            return false
        }
        if ["md", "markdown", "txt", "json", "yaml", "yml", "toml", "csv", "log", "xml", "html", "css", "js", "ts", "py", "swift", "rs"].contains(ext) {
            return false
        }
        if ["docx", "doc", "wps", "odt", "rtf", "rtfd", "pages", "pptx", "ppt", "dps", "odp", "key", "xlsx", "xls", "et", "ods", "numbers"].contains(ext) {
            return true
        }
        switch formatFamily {
        case .docx, .xlsx, .pptx, .legacyOffice:
            return true
        case .pdf, .markdown, .plainText, .epub, .ofd, .other:
            return false
        }
    }

    public static func filterBaseInlineTokens(_ tokens: [DocumentInlineDiffToken]) -> [DocumentInlineDiffToken] {
        tokens.filter { $0.kind == .equal || $0.kind == .deleted }
    }

    public static func filterTargetInlineTokens(_ tokens: [DocumentInlineDiffToken]) -> [DocumentInlineDiffToken] {
        tokens.filter { $0.kind == .equal || $0.kind == .inserted }
    }

    public static func makeBaseDiffAttributedString(
        tokens: [DocumentInlineDiffToken],
        fallbackText: String?,
        textStyle: CharkleTextStyle = .body,
        isDark: Bool,
        negColor: Color,
        strikeFallbackWhenTokensEmpty: Bool = true
    ) -> AttributedString {
        let baseTokens = filterBaseInlineTokens(tokens)
        let calmInk: Color = isDark ? .white.opacity(0.86) : .black.opacity(0.82)
        if !baseTokens.isEmpty {
            var combined = AttributedString()
            for token in baseTokens {
                var part = AttributedString(token.text)
                part.font = CharkleTheme.text(textStyle)
                switch token.kind {
                case .equal:
                    part.foregroundColor = calmInk
                case .deleted:
                    part.foregroundColor = negColor
                    part.strikethroughStyle = .single
                    part.backgroundColor = negColor.opacity(0.13)
                    if token.isHighRiskNumber || token.isHighRiskDate {
                        part.font = CharkleTheme.text(textStyle, weight: .semibold)
                        part.inlinePresentationIntent = .stronglyEmphasized
                    }
                case .inserted:
                    break
                }
                combined.append(part)
            }
            if !combined.characters.isEmpty {
                return combined
            }
        }
        var fallback = AttributedString(fallbackText ?? "")
        fallback.font = CharkleTheme.text(textStyle)
        if strikeFallbackWhenTokensEmpty {
            fallback.foregroundColor = negColor
            fallback.strikethroughStyle = .single
            fallback.backgroundColor = negColor.opacity(0.13)
        } else {
            fallback.foregroundColor = calmInk
        }
        return fallback
    }

    public static func makeTargetDiffAttributedString(
        tokens: [DocumentInlineDiffToken],
        fallbackText: String?,
        textStyle: CharkleTextStyle = .body,
        isDark: Bool,
        posColor: Color,
        emphasizeFallbackWhenTokensEmpty: Bool = true
    ) -> AttributedString {
        let targetTokens = filterTargetInlineTokens(tokens)
        let calmInk: Color = isDark ? .white.opacity(0.88) : .black.opacity(0.84)
        if !targetTokens.isEmpty {
            var combined = AttributedString()
            for token in targetTokens {
                var part = AttributedString(token.text)
                switch token.kind {
                case .equal:
                    part.font = CharkleTheme.text(textStyle)
                    part.foregroundColor = calmInk
                case .inserted:
                    part.foregroundColor = posColor
                    part.backgroundColor = posColor.opacity(0.14)
                    part.font = CharkleTheme.text(textStyle, weight: .semibold)
                    part.inlinePresentationIntent = .stronglyEmphasized
                case .deleted:
                    break
                }
                combined.append(part)
            }
            if !combined.characters.isEmpty {
                return combined
            }
        }
        var fallback = AttributedString(fallbackText ?? "")
        if emphasizeFallbackWhenTokensEmpty {
            fallback.foregroundColor = posColor
            fallback.backgroundColor = posColor.opacity(0.14)
            fallback.font = CharkleTheme.text(textStyle, weight: .semibold)
            fallback.inlinePresentationIntent = .stronglyEmphasized
        } else {
            fallback.font = CharkleTheme.text(textStyle)
            fallback.foregroundColor = calmInk
        }
        return fallback
    }

    private var formatAccent: Color {
        switch docFamily {
        case .xlsx: Color(charkleHex: "#1D7A46")
        case .pdf: Color(charkleHex: "#C83E37")
        case .pptx: Color(charkleHex: "#C96A1B")
        case .docx, .legacyOffice: Color(charkleHex: "#2A60E0")
        default: Color(charkleHex: "#4B5563")
        }
    }

    public static func filterDiffHunks(
        _ hunks: [DocumentDiffHunk],
        radar: RiskRadarFilter,
        onlyChanged: Bool
    ) -> [DocumentDiffHunk] {
        DocumentRadarFilterEngine.filterDiffHunks(hunks, radar: radar, onlyChanged: onlyChanged)
    }

    private var filteredHunks: [DocumentDiffHunk] {
        guard let report = comparisonReport else { return [] }
        return Self.filterDiffHunks(report.hunks, radar: activeRiskFilter, onlyChanged: onlyChangedBlocks)
    }

    private var changedHunksForMerge: [DocumentDiffHunk] {
        (comparisonReport?.hunks ?? []).filter { $0.changeKind.isChanged }
    }

    public var body: some View {
        let cardShape = RoundedRectangle(cornerRadius: CharkleTheme.Radius.popoverOuter, style: .continuous)
        let cardFill = colorScheme == .dark ? Color(charkleHex: "#1A1C21") : Color.white

        VStack(alignment: .leading, spacing: 0) {
            topDocumentHeaderBar

            Rectangle()
                .fill(CharkleTheme.hairline(for: colorScheme))
                .frame(height: CharkleTheme.hairlineWidth)

            Group {
                switch studioMode {
                case .reader:
                    readerStageBody
                case .diff:
                    diffStageBody
                case .merge:
                    mergeStageBody
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: 1020, maxHeight: 740)
        .clipShape(cardShape)
        .background {
            cardShape
                .fill(cardFill)
                .shadow(color: .black.opacity(0.42), radius: 28, y: 12)
        }
        .overlay(
            cardShape.strokeBorder(
                Color.white.opacity(colorScheme == .dark ? 0.10 : 0.45),
                lineWidth: CharkleTheme.hairlineWidth
            )
        )
        .background {
            WindowKeyEventBridge { event, hostWindow in
                handleStudioKeyDown(event, in: hostWindow)
            }
            .allowsHitTesting(false)
        }
        .task(id: asset.id) {
            await bootstrapForAsset()
        }
        .onChange(of: coordinator.quickLookDiffRequest) { _, req in
            guard let req, req.nonce != lastConsumedDiffNonce else { return }
            applyLaunchDiffRequest(req)
        }
    }

    // MARK: - Top Studio Header & Version Stack Bar

    private var topDocumentHeaderBar: some View {
        let hasMultipleVersions = siblings.count >= 2
        let positiveInk = CharkleTheme.positive(for: colorScheme)

        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text(docFamily.badgeLabel)
                    .font(CharkleTheme.text(.caption, weight: .bold))
                    .foregroundStyle(formatAccent)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3.5)
                    .background(formatAccent.opacity(0.13), in: RoundedRectangle(cornerRadius: CharkleTheme.Radius.sm, style: .continuous))

                Text(asset.title)
                    .font(CharkleTheme.text(.headline, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                if let p = payload {
                    HStack(spacing: 6) {
                        if !p.sheets.isEmpty {
                            Text("\(p.sheets.count) 工作表")
                        } else if p.pageCount > 0 {
                            Text("\(p.pageCount) 页")
                        }
                        if p.wordCount > 0 {
                            Text("\(p.wordCount) 字")
                        }
                        if !p.hasTextLayer && docFamily == .pdf {
                            Text("扫描件")
                                .foregroundStyle(CharkleTheme.warning(for: colorScheme))
                        }
                    }
                    .font(CharkleTheme.text(.caption))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: true, vertical: false)
                }

                Spacer(minLength: 8)

                if hasMultipleVersions {
                    HStack(spacing: 2) {
                        modeSwitchPill(.reader, label: "清晰阅读", icon: "doc.richtext")
                        modeSwitchPill(.diff, label: "对比差异", icon: "arrow.left.arrow.right")
                        modeSwitchPill(.merge, label: "按差异合成新版", icon: "arrow.triangle.merge")
                    }
                    .padding(2.5)
                    .background(CharkleTheme.surfaceSubtle(for: colorScheme), in: RoundedRectangle(cornerRadius: CharkleTheme.Radius.chip, style: .continuous))
                }

                Button {
                    openAssetInDefaultApplication(assetID: studioMode == .reader ? asset.id : (compareTargetAssetID ?? asset.id))
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.up.forward.app")
                            .font(.system(size: 11, weight: .semibold))
                        Text("用默认应用打开")
                            .font(CharkleTheme.text(.caption, weight: .medium))
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(CharkleTheme.surfaceSubtle(for: colorScheme), in: Capsule(style: .continuous))
                }
                .buttonStyle(CharkleTactileButtonStyle())
            }

            if hasMultipleVersions {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(Array(siblings.enumerated()), id: \.element.id) { idx, ver in
                            let vMeta = ver.richMetadata?.versionStack
                            let vNum = vMeta?.versionNumber ?? (idx + 1)
                            let isPrimary = ver.id == primaryAsset.id
                            let isViewing = ver.id == asset.id
                            let editor = (vMeta?.editorName?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }

                            Button {
                                var playlist = coordinator.quickLookPlaylist
                                if !playlist.contains(ver.id) {
                                    playlist.append(ver.id)
                                }
                                coordinator.openQuickLook(assetID: ver.id, playlist: playlist)
                            } label: {
                                HStack(spacing: 4.5) {
                                    Text("v\(vNum)")
                                        .font(CharkleTheme.text(.caption, weight: .bold))
                                        .monospacedDigit()
                                    if let editor {
                                        Text(editor)
                                            .font(CharkleTheme.text(.caption))
                                            .lineLimit(1)
                                    }
                                    if isPrimary {
                                        Text("主版")
                                            .font(CharkleTheme.text(.caption, weight: .bold))
                                            .foregroundStyle(positiveInk)
                                            .padding(.horizontal, 4.5)
                                            .padding(.vertical, 1)
                                            .background(positiveInk.opacity(0.14), in: RoundedRectangle(cornerRadius: CharkleTheme.Radius.xs, style: .continuous))
                                    }
                                }
                                .foregroundStyle(isViewing ? activeAccent : .primary)
                                .padding(.horizontal, 9)
                                .padding(.vertical, 4)
                                .background(
                                    isViewing
                                        ? activeAccent.opacity(colorScheme == .dark ? 0.18 : 0.11)
                                        : CharkleTheme.surfaceSubtle(for: colorScheme),
                                    in: Capsule(style: .continuous)
                                )
                                .overlay(
                                    Capsule(style: .continuous)
                                        .strokeBorder(isViewing ? activeAccent.opacity(0.45) : Color.clear, lineWidth: CharkleTheme.hairlineWidth)
                                )
                            }
                            .buttonStyle(CharkleTactileButtonStyle())
                        }

                        if asset.id != primaryAsset.id {
                            Button {
                                Task {
                                    _ = await library.setPrimaryVersion(asset.id)
                                    let vNum = asset.richMetadata?.versionStack?.versionNumber ?? 1
                                    coordinator.showToast("已将 v\(vNum) 设为主版本", icon: "pin.fill", tone: .success)
                                }
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "pin.fill")
                                        .font(.system(size: 10))
                                    Text("设当前版为主版")
                                        .font(CharkleTheme.text(.caption, weight: .medium))
                                }
                                .foregroundStyle(activeAccent)
                                .padding(.horizontal, 9)
                                .padding(.vertical, 4)
                                .background(activeAccent.opacity(0.10), in: Capsule(style: .continuous))
                            }
                            .buttonStyle(CharkleTactileButtonStyle())
                        }
                    }
                }
                .background(HorizontalWheelScrollRedirector())
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    private func modeSwitchPill(_ mode: StudioMode, label: String, icon: String) -> some View {
        let selected = studioMode == mode
        let innerR = CharkleTheme.Radius.concentricInner(outer: CharkleTheme.Radius.chip, padding: 2.5)
        return Button {
            withAnimation(CharkleMotion.accessible(CharkleMotion.settleStrong, reduced: reduceMotion)) {
                studioMode = mode
            }
            if mode != .reader {
                ensureComparisonLoaded()
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 10.5, weight: .semibold))
                Text(label)
                    .font(CharkleTheme.text(.caption, weight: selected ? .semibold : .medium))
                if mode == .diff,
                   let riskCount = comparisonReport?.summary.totalHighRiskChanges ?? asset.richMetadata?.document?.diffSummary?.totalHighRiskChanges,
                   riskCount > 0 {
                    Text("\(riskCount)")
                        .font(CharkleTheme.text(.caption, weight: .bold))
                        .monospacedDigit()
                        .foregroundStyle(selected ? .white : CharkleTheme.destructive(for: colorScheme))
                        .padding(.horizontal, 4.5)
                        .padding(.vertical, 0.5)
                        .background(
                            selected
                                ? Color.white.opacity(0.24)
                                : CharkleTheme.destructive(for: colorScheme).opacity(0.14),
                            in: Capsule(style: .continuous)
                        )
                }
            }
            .foregroundStyle(selected ? Color.white : .primary.opacity(0.84))
            .padding(.horizontal, 10)
            .padding(.vertical, 4.5)
            .background(selected ? activeAccent : Color.clear, in: RoundedRectangle(cornerRadius: innerR, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: innerR, style: .continuous))
        }
        .buttonStyle(CharkleTactileButtonStyle())
    }

    // MARK: - Mode 1: Clean Native Reader (.docx / Office QLPreviewView + Structured Blocks / .xlsx / .pdf / .md / .txt)

    @ViewBuilder
    private var readerStageBody: some View {
        if docFamily == .pdf, let url = originalURL, !showPDFExtractedText {
            VStack(spacing: 0) {
                HStack {
                    Text(payload?.hasTextLayer == false ? "签批/扫描 PDF 高清原件" : "PDF 原生页面视图")
                        .font(CharkleTheme.text(.caption, weight: .medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                    if let p = payload, !p.plainText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Button("查看提取正文") {
                            showPDFExtractedText = true
                        }
                        .buttonStyle(CharkleButtonStyle(.subtle, size: .xs))
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 6)

                QuickLookPDFView(url: url)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else if supportsNativeOfficeLayout, let url = originalURL {
            VStack(spacing: 0) {
                officeReaderModeBar

                Rectangle()
                    .fill(CharkleTheme.hairline(for: colorScheme))
                    .frame(height: CharkleTheme.hairlineWidth)

                if readerPresentationMode == .nativeLayout {
                    NativeOfficeQLPreviewRepresentable(url: url)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if isLoadingPayload && payload == nil {
                    VStack(spacing: 10) {
                        ProgressView().controlSize(.regular)
                        Text("正在解析文档结构与批注…")
                            .font(CharkleTheme.text(.caption))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let p = payload, !p.sheets.isEmpty {
                    spreadsheetReaderView(p)
                } else if let p = payload {
                    structuredDocumentReaderView(p)
                } else {
                    VStack(spacing: 8) {
                        Text("暂未提取到结构化段落，可切换回原版版式预览")
                            .font(CharkleTheme.text(.body, weight: .medium))
                            .foregroundStyle(.secondary)
                        Button("切回原版版式") {
                            readerPresentationMode = .nativeLayout
                        }
                        .buttonStyle(CharkleButtonStyle(.standard, size: .sm))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        } else if isLoadingPayload && payload == nil {
            VStack(spacing: 10) {
                ProgressView().controlSize(.regular)
                Text("正在解析文档结构与表格…")
                    .font(CharkleTheme.text(.caption))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let p = payload, !p.sheets.isEmpty {
            spreadsheetReaderView(p)
        } else if (docFamily == .markdown || docFamily == .plainText) && !supportsNativeOfficeLayout {
            markdownOrTextReaderView
        } else if let p = payload {
            structuredDocumentReaderView(p)
        } else {
            VStack(spacing: 8) {
                Text("暂无可预览的文档内容")
                    .font(CharkleTheme.text(.body, weight: .medium))
                    .foregroundStyle(.secondary)
                Button("使用系统默认应用打开") {
                    openAssetInDefaultApplication(assetID: asset.id)
                }
                .buttonStyle(CharkleButtonStyle(.standard, size: .sm))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var officeReaderModeBar: some View {
        let structuredTitle = isSpreadsheetFamily ? "结构化表格" : "结构与批注"
        let structuredIcon = isSpreadsheetFamily ? "tablecells" : "text.bubble"
        let commentCount = payload?.comments.count ?? 0

        return HStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: readerPresentationMode == .nativeLayout ? "doc.richtext" : structuredIcon)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Text(
                    readerPresentationMode == .nativeLayout
                        ? (isSpreadsheetFamily ? "原版工作簿版式预览" : "原版纸面版式预览")
                        : (isSpreadsheetFamily ? "结构化数据与公式网格（悬停 fx 查看公式）" : "结构化正文与原生批注（可直接选取复制）")
                )
                .font(CharkleTheme.text(.caption, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }

            Spacer(minLength: 10)

            HStack(spacing: 2) {
                readerPresentationCapsule(
                    .nativeLayout,
                    title: "原版版式",
                    icon: "doc.richtext",
                    badgeCount: nil
                )
                readerPresentationCapsule(
                    .structuredContent,
                    title: structuredTitle,
                    icon: structuredIcon,
                    badgeCount: (!isSpreadsheetFamily && commentCount > 0) ? commentCount : nil
                )
            }
            .padding(2)
            .background(
                CharkleTheme.surfaceSubtle(for: colorScheme),
                in: RoundedRectangle(cornerRadius: CharkleTheme.Radius.chip, style: .continuous)
            )
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 6)
    }

    private func readerPresentationCapsule(
        _ mode: ReaderPresentationMode,
        title: String,
        icon: String,
        badgeCount: Int?
    ) -> some View {
        let selected = readerPresentationMode == mode
        let innerR = CharkleTheme.Radius.concentricInner(outer: CharkleTheme.Radius.chip, padding: 2)
        return Button {
            withAnimation(CharkleMotion.accessible(CharkleMotion.settleStrong, reduced: reduceMotion)) {
                readerPresentationMode = mode
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 10.5, weight: .semibold))
                Text(title)
                    .font(CharkleTheme.text(.caption, weight: selected ? .semibold : .medium))
                if let badgeCount, badgeCount > 0 {
                    Text("\(badgeCount)")
                        .font(CharkleTheme.text(.caption, weight: .bold))
                        .monospacedDigit()
                        .foregroundStyle(selected ? activeAccent : .secondary)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 0.5)
                        .background(
                            (selected ? activeAccent : Color.primary).opacity(0.12),
                            in: Capsule(style: .continuous)
                        )
                }
            }
            .foregroundStyle(selected ? .primary : .secondary)
            .padding(.horizontal, 8.5)
            .padding(.vertical, 3.5)
            .background(
                selected ? CharkleTheme.surfaceElevated(for: colorScheme) : Color.clear,
                in: RoundedRectangle(cornerRadius: innerR, style: .continuous)
            )
            .contentShape(RoundedRectangle(cornerRadius: innerR, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func spreadsheetReaderView(_ doc: StructuredDocumentPayload) -> some View {
        let clampedIdx = min(max(0, selectedSheetIndex), max(0, doc.sheets.count - 1))
        let activeSheet = doc.sheets[clampedIdx]
        let colCount = max(1, activeSheet.columnCount, activeSheet.headers.count)

        return VStack(alignment: .leading, spacing: 0) {
            // Sheet Switcher Tabs
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(Array(doc.sheets.enumerated()), id: \.element.id) { idx, sheet in
                        let selected = idx == clampedIdx
                        Button {
                            selectedSheetIndex = idx
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: "tablecells")
                                    .font(.system(size: 10.5, weight: .medium))
                                Text(sheet.name)
                                    .font(CharkleTheme.text(.caption, weight: selected ? .semibold : .medium))
                                Text("\(sheet.rows.count)")
                                    .font(CharkleTheme.text(.caption, weight: .medium))
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                            }
                            .foregroundStyle(selected ? formatAccent : .secondary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(
                                selected ? formatAccent.opacity(0.14) : CharkleTheme.surfaceSubtle(for: colorScheme),
                                in: Capsule(style: .continuous)
                            )
                        }
                        .buttonStyle(CharkleTactileButtonStyle())
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 8)
            }
            .background(HorizontalWheelScrollRedirector())

            Rectangle()
                .fill(CharkleTheme.hairline(for: colorScheme))
                .frame(height: CharkleTheme.hairlineWidth)

            ScrollView([.horizontal, .vertical]) {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    Section {
                        ForEach(Array(activeSheet.rows.enumerated()), id: \.element.id) { rowIdx, row in
                            HStack(spacing: 0) {
                                Text("\(row.rowNumber)")
                                    .font(CharkleTheme.text(.caption, weight: .medium))
                                    .monospacedDigit()
                                    .foregroundStyle(.tertiary)
                                    .frame(width: 44, alignment: .trailing)
                                    .padding(.trailing, 8)

                                ForEach(0..<colCount, id: \.self) { col in
                                    let val = col < row.values.count ? row.values[col] : ""
                                    let formula = row.formula(at: col)
                                    HStack(spacing: 4) {
                                        Text(val)
                                            .font(CharkleTheme.text(.caption))
                                            .monospacedDigit()
                                            .foregroundStyle(.primary)
                                            .lineLimit(2)
                                            .textSelection(.enabled)
                                        Spacer(minLength: 0)
                                        if let formula, !formula.isEmpty {
                                            Text("fx")
                                                .font(CharkleTheme.text(.caption, weight: .bold, design: .monospaced))
                                                .scaleEffect(0.82)
                                                .foregroundStyle(formatAccent)
                                                .padding(.horizontal, 3.5)
                                                .padding(.vertical, 1)
                                                .background(formatAccent.opacity(0.12), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                                                .help("公式：\(formula)")
                                        }
                                    }
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 6)
                                    .frame(width: 148, alignment: .leading)
                                    .overlay(alignment: .trailing) {
                                        Rectangle()
                                            .fill(CharkleTheme.hairline(for: colorScheme))
                                            .frame(width: CharkleTheme.hairlineWidth)
                                    }
                                }
                            }
                            .background(rowIdx.isMultiple(of: 2) ? Color.clear : Color.primary.opacity(0.024))
                            .overlay(alignment: .bottom) {
                                Rectangle()
                                    .fill(CharkleTheme.hairline(for: colorScheme))
                                    .frame(height: CharkleTheme.hairlineWidth)
                            }
                        }
                    } header: {
                        HStack(spacing: 0) {
                            Text("#")
                                .font(CharkleTheme.text(.caption, weight: .semibold))
                                .foregroundStyle(.tertiary)
                                .frame(width: 44, alignment: .trailing)
                                .padding(.trailing, 8)

                            ForEach(0..<colCount, id: \.self) { col in
                                let headerText: String = {
                                    if col < activeSheet.headers.count, !activeSheet.headers[col].isEmpty {
                                        return activeSheet.headers[col]
                                    }
                                    return Self.excelColumnLetter(col)
                                }()
                                Text(headerText)
                                    .font(CharkleTheme.text(.caption, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 7)
                                    .frame(width: 148, alignment: .leading)
                                    .overlay(alignment: .trailing) {
                                        Rectangle()
                                            .fill(CharkleTheme.hairline(for: colorScheme))
                                            .frame(width: CharkleTheme.hairlineWidth)
                                    }
                            }
                        }
                        .background(CharkleTheme.surfaceSubtle(for: colorScheme))
                        .overlay(alignment: .bottom) {
                            Rectangle()
                                .fill(CharkleTheme.hairline(for: colorScheme))
                                .frame(height: 1)
                        }
                    }
                }
            }
            .charkleCleanScrollbars(hidden: false)
        }
    }

    private var markdownOrTextReaderView: some View {
        let rawText = payload?.plainText ?? asset.ocrText ?? asset.richMetadata?.textExcerpt ?? asset.notes
        let isMarkdown = docFamily == .markdown || asset.isMarkdownDocument

        return VStack(alignment: .leading, spacing: 0) {
            if isMarkdown {
                HStack {
                    Spacer()
                    Button(showRawMarkdownSource ? "渲染排版" : "纯文本源码") {
                        showRawMarkdownSource.toggle()
                    }
                    .buttonStyle(CharkleButtonStyle(.subtle, size: .xs))
                }
                .padding(.horizontal, 18)
                .padding(.top, 8)
            }

            ScrollView(.vertical) {
                Group {
                    if isMarkdown && !showRawMarkdownSource {
                        QuickLookMarkdownContentView(markdown: rawText)
                    } else {
                        Text(rawText.isEmpty ? "暂无文本内容" : rawText)
                            .font(CharkleTheme.text(.body, design: showRawMarkdownSource ? .monospaced : .default))
                            .foregroundStyle(.primary)
                            .lineSpacing(4)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(24)
            }
            .charkleCleanScrollbars(hidden: false)
        }
    }

    private func structuredDocumentReaderView(_ doc: StructuredDocumentPayload) -> some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 14) {
                if showPDFExtractedText && docFamily == .pdf && originalURL != nil {
                    HStack {
                        Text("PDF 提取正文视图")
                            .font(CharkleTheme.text(.caption, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("返回 PDF 页面视图") {
                            showPDFExtractedText = false
                        }
                        .buttonStyle(CharkleButtonStyle(.subtle, size: .xs))
                    }
                }

                if doc.isRedHeaderStyle {
                    VStack(spacing: 6) {
                        Text(doc.title)
                            .font(CharkleTheme.text(.title, weight: .bold))
                            .foregroundStyle(Color(charkleHex: "#C83E37"))
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity)
                        Rectangle()
                            .fill(Color(charkleHex: "#D93B30"))
                            .frame(height: 2)
                    }
                    .padding(.bottom, 6)
                }

                ForEach(doc.blocks) { block in
                    documentBlockView(block)
                }

                if doc.blocks.isEmpty && !doc.plainText.isEmpty {
                    Text(doc.plainText)
                        .font(CharkleTheme.text(.body))
                        .lineSpacing(5)
                        .textSelection(.enabled)
                }

                if !doc.comments.isEmpty {
                    CharkleDisclosureGroup(isExpanded: $isCommentsExpanded, showsTopDivider: true, accentChevronWhenExpanded: true) {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(doc.comments) { comment in
                                VStack(alignment: .leading, spacing: 3) {
                                    HStack(spacing: 6) {
                                        Image(systemName: "text.bubble")
                                            .font(.system(size: 10.5, weight: .semibold))
                                            .foregroundStyle(activeAccent)
                                        Text(comment.author)
                                            .font(CharkleTheme.text(.caption, weight: .semibold))
                                        if let dt = comment.dateText, !dt.isEmpty {
                                            Text(dt)
                                                .font(CharkleTheme.text(.caption))
                                                .monospacedDigit()
                                                .foregroundStyle(.tertiary)
                                        }
                                    }
                                    if let anchor = comment.anchorExcerpt, !anchor.isEmpty {
                                        Text("「\(anchor)」")
                                            .font(CharkleTheme.text(.caption))
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                    Text(comment.text)
                                        .font(CharkleTheme.text(.body))
                                        .textSelection(.enabled)
                                }
                                .padding(10)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(CharkleTheme.surfaceSubtle(for: colorScheme), in: RoundedRectangle(cornerRadius: CharkleTheme.Radius.chip, style: .continuous))
                            }
                        }
                        .padding(.top, 6)
                    } label: {
                        Text("文档原生批注（\(doc.comments.count) 条）")
                            .font(CharkleTheme.text(.caption, weight: .semibold))
                    }
                }
            }
            .padding(26)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .charkleCleanScrollbars(hidden: false)
    }

    @ViewBuilder
    private func documentBlockView(_ block: DocumentBlock) -> some View {
        switch block.kind {
        case .heading:
            let level = block.headingLevel ?? 2
            let size: CGFloat = level <= 1 ? 19 : (level == 2 ? 16 : 14)
            Text(block.text)
                .font(.system(size: size, weight: .bold))
                .foregroundStyle(.primary)
                .padding(.top, level <= 2 ? 6 : 2)
                .textSelection(.enabled)

        case .table:
            if !block.tableRows.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(block.tableRows.enumerated()), id: \.offset) { rIdx, row in
                        HStack(spacing: 0) {
                            ForEach(Array(row.enumerated()), id: \.offset) { cIdx, cell in
                                Text(cell)
                                    .font(CharkleTheme.text(.caption, weight: rIdx == 0 ? .semibold : .regular))
                                    .monospacedDigit()
                                    .foregroundStyle(.primary)
                                    .padding(.horizontal, 9)
                                    .padding(.vertical, 6)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .overlay(alignment: .trailing) {
                                        if cIdx < row.count - 1 {
                                            Rectangle()
                                                .fill(CharkleTheme.hairline(for: colorScheme))
                                                .frame(width: CharkleTheme.hairlineWidth)
                                        }
                                    }
                            }
                        }
                        .background(rIdx == 0 ? CharkleTheme.surfaceSubtle(for: colorScheme) : Color.clear)
                        .overlay(alignment: .bottom) {
                            if rIdx < block.tableRows.count - 1 {
                                Rectangle()
                                    .fill(CharkleTheme.hairline(for: colorScheme))
                                    .frame(height: CharkleTheme.hairlineWidth)
                            }
                        }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: CharkleTheme.Radius.chip, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: CharkleTheme.Radius.chip, style: .continuous)
                        .strokeBorder(CharkleTheme.hairline(for: colorScheme), lineWidth: CharkleTheme.hairlineWidth)
                )
            }

        case .pageBreak:
            HStack(spacing: 8) {
                CharkleHairlineDivider()
                if let p = block.pageNumber {
                    Text("第 \(p) 页")
                        .font(CharkleTheme.text(.caption))
                        .monospacedDigit()
                        .foregroundStyle(.tertiary)
                        .fixedSize()
                }
                CharkleHairlineDivider()
            }
            .padding(.vertical, 4)

        default:
            VStack(alignment: .leading, spacing: 5) {
                if !block.nativeRevisions.isEmpty {
                    nativeRevisionSpansView(block.nativeRevisions)
                } else {
                    Text(block.kind == .listItem ? "• \(block.text)" : block.text)
                        .font(CharkleTheme.text(.body, design: block.kind == .codeBlock ? .monospaced : .default))
                        .foregroundStyle(block.kind == .quote ? .secondary : .primary)
                        .lineSpacing(4.5)
                        .textSelection(.enabled)
                }
            }
        }
    }

    private func nativeRevisionSpansView(_ spans: [DocumentTrackRevisionSpan]) -> some View {
        let pos = CharkleTheme.positive(for: colorScheme)
        let neg = CharkleTheme.destructive(for: colorScheme)
        return CharkleFlowLayout(spacing: 4, lineSpacing: 4) {
            ForEach(spans) { span in
                let isIns = span.kind == .inserted
                Text(span.text)
                    .font(CharkleTheme.text(.body, weight: .medium))
                    .strikethrough(!isIns, color: neg)
                    .foregroundStyle(isIns ? pos : neg)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1.5)
                    .background((isIns ? pos : neg).opacity(0.12), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                    .help("\(isIns ? "修订插入" : "修订删除")\(span.author.map { " (\($0))" } ?? "")")
            }
        }
    }

    // MARK: - Mode 2: Multi-Modal Fine-Grained Diff + High-Risk Radar + PDF Visual Overlay

    private var diffStageBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            diffControlAndRadarBar

            Rectangle()
                .fill(CharkleTheme.hairline(for: colorScheme))
                .frame(height: CharkleTheme.hairlineWidth)

            if isComparing && comparisonReport == nil {
                VStack(spacing: 10) {
                    ProgressView().controlSize(.regular)
                    Text("正在本地比对段落、数值与表格差异…")
                        .font(CharkleTheme.text(.caption))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if docFamily == .pdf && (pdfVisualMode == .redCyanOverlay || pdfVisualMode == .splitCurtain) {
                pdfVisualComparisonStage
            } else if let report = comparisonReport, !report.sheetDiffs.isEmpty {
                excelSheetDiffStage(report)
            } else if let report = comparisonReport {
                wordAndTextDiffStage(report)
            } else {
                VStack(spacing: 8) {
                    Text("选择任意两个版本即可查看精细差异")
                        .font(CharkleTheme.text(.body))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var diffControlAndRadarBar: some View {
        let baseAsset = compareBaseAssetID.flatMap { library.allAssetsByID[$0] }
        let targetAsset = compareTargetAssetID.flatMap { library.allAssetsByID[$0] }

        return VStack(alignment: .leading, spacing: 8) {
            // Row 1: Version pair selector + Format-specific view toggles + J/K stepper
            HStack(spacing: 8) {
                versionPickerMenu(titlePrefix: "基准", selected: baseAsset) { picked in
                    compareBaseAssetID = picked.id
                    triggerComparisonReload()
                }

                Image(systemName: "arrow.right")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.tertiary)

                versionPickerMenu(titlePrefix: "对比", selected: targetAsset) { picked in
                    compareTargetAssetID = picked.id
                    triggerComparisonReload()
                }

                Spacer(minLength: 8)

                if docFamily == .pdf {
                    HStack(spacing: 2) {
                        pdfModeCapsule(.textOrOCR, title: "文本 / OCR")
                        pdfModeCapsule(.redCyanOverlay, title: "红青叠层")
                        pdfModeCapsule(.splitCurtain, title: "左右卷帘")
                    }
                    .padding(2)
                    .background(CharkleTheme.surfaceSubtle(for: colorScheme), in: RoundedRectangle(cornerRadius: CharkleTheme.Radius.chip, style: .continuous))

                    if pdfVisualMode == .textOrOCR {
                        Toggle("离线 OCR", isOn: $useOCRIfScanned)
                            .toggleStyle(.switch)
                            .controlSize(.mini)
                            .font(CharkleTheme.text(.caption, weight: .medium))
                            .onChange(of: useOCRIfScanned) { _, _ in
                                triggerComparisonReload()
                            }
                    }
                } else if (comparisonReport?.sheetDiffs.isEmpty ?? true) {
                    HStack(spacing: 2) {
                        textLayoutCapsule(.inlineReview, title: "行内审阅")
                        textLayoutCapsule(.sideBySide, title: "左右分栏")
                    }
                    .padding(2)
                    .background(CharkleTheme.surfaceSubtle(for: colorScheme), in: RoundedRectangle(cornerRadius: CharkleTheme.Radius.chip, style: .continuous))
                }

                Toggle("仅看改动段落", isOn: $onlyChangedBlocks)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .font(CharkleTheme.text(.caption, weight: .medium))

                if !filteredHunks.isEmpty {
                    HStack(spacing: 3) {
                        Button {
                            stepFocusedHunk(delta: -1)
                        } label: {
                            Image(systemName: "chevron.up")
                                .font(.system(size: 10, weight: .bold))
                                .frame(width: 22, height: 22)
                        }
                        .buttonStyle(.plain)
                        .help("上一处差异 (K)")

                        Button {
                            stepFocusedHunk(delta: 1)
                        } label: {
                            Image(systemName: "chevron.down")
                                .font(.system(size: 10, weight: .bold))
                                .frame(width: 22, height: 22)
                        }
                        .buttonStyle(.plain)
                        .help("下一处差异 (J)")
                    }
                    .padding(.horizontal, 4)
                    .background(CharkleTheme.surfaceSubtle(for: colorScheme), in: Capsule(style: .continuous))
                }
            }

            // Row 2: High-Risk Radar Capsules
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(RiskRadarFilter.allCases) { filter in
                        let count = radarCount(for: filter)
                        let active = activeRiskFilter == filter
                        let isHighRisk = filter == .numberOrCurrency || filter == .dateOrDeadline
                        let dangerColor = CharkleTheme.destructive(for: colorScheme)

                        Button {
                            withAnimation(CharkleMotion.accessible(CharkleMotion.settleStrong, reduced: reduceMotion)) {
                                activeRiskFilter = filter
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Text(filter.label)
                                    .font(CharkleTheme.text(.caption, weight: active ? .semibold : .medium))
                                Text("\(count)")
                                    .font(CharkleTheme.text(.caption, weight: .bold))
                                    .monospacedDigit()
                                    .foregroundStyle(
                                        active
                                            ? Color.white
                                            : (isHighRisk && count > 0 ? dangerColor : .secondary)
                                    )
                            }
                            .foregroundStyle(active ? Color.white : .primary.opacity(0.86))
                            .padding(.horizontal, 9)
                            .padding(.vertical, 4)
                            .background(
                                active
                                    ? (isHighRisk && count > 0 ? dangerColor : activeAccent)
                                    : (isHighRisk && count > 0 ? dangerColor.opacity(0.10) : CharkleTheme.surfaceSubtle(for: colorScheme)),
                                in: Capsule(style: .continuous)
                            )
                        }
                        .buttonStyle(CharkleTactileButtonStyle())
                    }
                }
            }
            .background(HorizontalWheelScrollRedirector())
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
    }

    private func versionPickerMenu(
        titlePrefix: String,
        selected: AssetRecord?,
        onSelect: @escaping (AssetRecord) -> Void
    ) -> some View {
        let labelText: String = {
            guard let selected else { return "\(titlePrefix)：选择版本" }
            let badge = selected.richMetadata?.versionStack?.displayBadgeText ?? selected.title
            return "\(titlePrefix)：\(badge)"
        }()
        return Menu {
            ForEach(siblings) { ver in
                let badge = ver.richMetadata?.versionStack?.displayBadgeText ?? ver.title
                Button {
                    onSelect(ver)
                } label: {
                    if ver.id == selected?.id {
                        Label(badge, systemImage: "checkmark")
                    } else {
                        Text(badge)
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(labelText)
                    .font(CharkleTheme.text(.caption, weight: .semibold))
                    .monospacedDigit()
                    .lineLimit(1)
                CharkleDropdownChevron(size: 8)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 4.5)
            .background(CharkleTheme.surfaceSubtle(for: colorScheme), in: Capsule(style: .continuous))
        }
        .menuStyle(.button)
        .buttonStyle(CharkleMenuTriggerButtonStyle())
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private func textLayoutCapsule(_ mode: TextDiffLayout, title: String) -> some View {
        let selected = textDiffLayout == mode
        let innerR = CharkleTheme.Radius.concentricInner(outer: CharkleTheme.Radius.chip, padding: 2)
        return Button {
            textDiffLayout = mode
        } label: {
            Text(title)
                .font(CharkleTheme.text(.caption, weight: selected ? .semibold : .medium))
                .foregroundStyle(selected ? .primary : .secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3.5)
                .background(selected ? CharkleTheme.surfaceElevated(for: colorScheme) : Color.clear, in: RoundedRectangle(cornerRadius: innerR, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func pdfModeCapsule(_ mode: PDFDiffVisualMode, title: String) -> some View {
        let selected = pdfVisualMode == mode
        let innerR = CharkleTheme.Radius.concentricInner(outer: CharkleTheme.Radius.chip, padding: 2)
        return Button {
            pdfVisualMode = mode
            if mode != .textOrOCR {
                loadPDFVisualPages()
            }
        } label: {
            Text(title)
                .font(CharkleTheme.text(.caption, weight: selected ? .semibold : .medium))
                .foregroundStyle(selected ? .primary : .secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3.5)
                .background(selected ? CharkleTheme.surfaceElevated(for: colorScheme) : Color.clear, in: RoundedRectangle(cornerRadius: innerR, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func radarCount(for filter: RiskRadarFilter) -> Int {
        guard let report = comparisonReport else { return 0 }
        return DocumentRadarFilterEngine.radarBadgeCount(in: report, for: filter)
    }

    // MARK: - Word / Text Inline & Side-by-Side Diff Stage

    private func wordAndTextDiffStage(_ report: DocumentComparisonReport) -> some View {
        let items = filteredHunks
        return ScrollViewReader { proxy in
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 10) {
                    if items.isEmpty && report.commentDiffs.isEmpty {
                        VStack(spacing: 8) {
                            Text(activeRiskFilter == .all ? "两版正文一致，未检测到段落变更" : "当前雷达筛选项下没有匹配的变更")
                                .font(CharkleTheme.text(.body, weight: .medium))
                                .foregroundStyle(.secondary)
                            if activeRiskFilter != .all {
                                Button("切回全部改动") {
                                    activeRiskFilter = .all
                                }
                                .buttonStyle(CharkleButtonStyle(.standard, size: .xs))
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 48)
                    } else {
                        ForEach(items) { hunk in
                            diffHunkCard(hunk)
                                .id(hunk.id)
                        }
                    }

                    if !report.commentDiffs.isEmpty && (activeRiskFilter == .all || activeRiskFilter == .nativeRevisionOrComment) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("原生批注变动（\(report.commentDiffs.count)）")
                                .font(CharkleTheme.text(.caption, weight: .semibold))
                                .foregroundStyle(.secondary)
                            ForEach(report.commentDiffs) { cDiff in
                                HStack(spacing: 8) {
                                    Text(cDiff.changeKind.localizedLabel)
                                        .font(CharkleTheme.text(.caption, weight: .bold))
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 1.5)
                                        .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                                    Text("\(cDiff.comment.author)：\(cDiff.comment.text)")
                                        .font(CharkleTheme.text(.caption))
                                        .textSelection(.enabled)
                                }
                                .padding(9)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(CharkleTheme.surfaceSubtle(for: colorScheme), in: RoundedRectangle(cornerRadius: CharkleTheme.Radius.chip, style: .continuous))
                            }
                        }
                        .padding(.top, 8)
                    }
                }
                .padding(20)
            }
            .charkleCleanScrollbars(hidden: false)
            .onChange(of: focusedHunkID) { _, newID in
                guard let newID else { return }
                withAnimation(CharkleMotion.accessible(CharkleMotion.settleStrong, reduced: reduceMotion)) {
                    proxy.scrollTo(newID, anchor: .center)
                }
            }
        }
    }

    private func diffHunkCard(_ hunk: DocumentDiffHunk) -> some View {
        let isFocused = focusedHunkID == hunk.id
        let posColor = CharkleTheme.positive(for: colorScheme)
        let negColor = CharkleTheme.destructive(for: colorScheme)
        let warnColor = CharkleTheme.warning(for: colorScheme)
        let railBg = colorScheme == .dark ? Color(charkleHex: "#20232B") : Color(charkleHex: "#F7F6F3")

        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                if let sec = hunk.sectionTitle, !sec.isEmpty {
                    Text(sec)
                        .font(CharkleTheme.text(.caption, weight: .semibold))
                        .foregroundStyle(.primary)
                }

                Text(hunk.changeKind.localizedLabel)
                    .font(CharkleTheme.text(.caption, weight: .bold))
                    .foregroundStyle(hunk.changeKind == .moved ? activeAccent : (hunk.changeKind == .removed ? negColor : posColor))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1.5)
                    .background(
                        (hunk.changeKind == .moved ? activeAccent : (hunk.changeKind == .removed ? negColor : posColor)).opacity(0.13),
                        in: Capsule(style: .continuous)
                    )

                if hunk.changeKind == .moved, let fromIdx = hunk.movedFromIndex, let toIdx = hunk.movedToIndex {
                    Text("段落第 \(fromIdx + 1) 段 → 第 \(toIdx + 1) 段（内容未改）")
                        .font(CharkleTheme.text(.caption))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }

                ForEach(Array(hunk.riskFlags).sorted(by: { $0.rawValue < $1.rawValue }), id: \.self) { flag in
                    Text(flag.localizedLabel)
                        .font(CharkleTheme.text(.caption, weight: .semibold))
                        .foregroundStyle(warnColor)
                        .padding(.horizontal, 5.5)
                        .padding(.vertical, 1.5)
                        .background(warnColor.opacity(0.14), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                }

                Spacer(minLength: 6)

                Button {
                    let copyStr = hunk.targetText ?? hunk.baseText ?? ""
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    pb.setString(copyStr, forType: .string)
                    coordinator.showToast("已复制该处差异文本", icon: "doc.on.doc")
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .help("复制该处文本/数值")

                Button {
                    openAssetInDefaultApplication(assetID: compareTargetAssetID ?? asset.id)
                } label: {
                    Image(systemName: "arrow.up.forward.app")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .help("用系统默认软件打开")
            }

            if !hunk.highRiskPairs.isEmpty {
                HStack(spacing: 8) {
                    ForEach(hunk.highRiskPairs) { pair in
                        let pairIconName: String = {
                            switch pair.flag {
                            case .numberOrCurrency: "number.circle.fill"
                            case .dateOrDeadline: "clock.fill"
                            default: "exclamationmark.triangle.fill"
                            }
                        }()
                        HStack(spacing: 4) {
                            Image(systemName: pairIconName)
                                .font(.system(size: 10.5))
                                .foregroundStyle(negColor)
                            if let oldV = pair.oldValue {
                                Text(oldV)
                                    .strikethrough(true, color: negColor)
                                    .foregroundStyle(negColor)
                            }
                            Image(systemName: "arrow.right")
                                .font(.system(size: 8.5, weight: .bold))
                                .foregroundStyle(.tertiary)
                            if let newV = pair.newValue {
                                Text(newV)
                                    .fontWeight(.bold)
                                    .foregroundStyle(posColor)
                            }
                        }
                        .font(CharkleTheme.text(.caption))
                        .monospacedDigit()
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3.5)
                        .background(negColor.opacity(0.08), in: RoundedRectangle(cornerRadius: CharkleTheme.Radius.xs, style: .continuous))
                    }
                }
            }

            if !hunk.tableCellDiffs.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(hunk.tableCellDiffs) { cell in
                        HStack(spacing: 6) {
                            Text("\(cell.rowKey ?? "行\(cell.rowIndex + 1)") / \(cell.columnHeader ?? "列\(cell.colIndex + 1)")")
                                .font(CharkleTheme.text(.caption, weight: .semibold))
                            if let oldVal = cell.oldValue, !oldVal.isEmpty {
                                Text(oldVal)
                                    .strikethrough(true, color: negColor)
                                    .foregroundStyle(negColor)
                            }
                            Image(systemName: "arrow.right")
                                .font(.system(size: 9))
                                .foregroundStyle(.tertiary)
                            Text(cell.newValue ?? "（空）")
                                .fontWeight(.semibold)
                                .foregroundStyle(posColor)
                        }
                        .font(CharkleTheme.text(.caption))
                        .monospacedDigit()
                    }
                }
            } else if textDiffLayout == .sideBySide {
                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 6) {
                        diffVersionColumnHeader(
                            icon: "minus.circle.fill",
                            tint: negColor,
                            versionBadge: baseVersionBadgeLabel,
                            tooltip: "修改前基准版本（\(baseVersionBadgeLabel)）"
                        )
                        if let baseText = hunk.baseText {
                            if !hunk.inlineTokens.isEmpty && hunk.changeKind != .unchanged {
                                Text(
                                    Self.makeBaseDiffAttributedString(
                                        tokens: hunk.inlineTokens,
                                        fallbackText: baseText,
                                        textStyle: .body,
                                        isDark: colorScheme == .dark,
                                        negColor: negColor
                                    )
                                )
                                .font(CharkleTheme.text(.body))
                                .lineSpacing(3)
                                .textSelection(.enabled)
                            } else {
                                Text(baseText)
                                    .font(CharkleTheme.text(.body))
                                    .foregroundStyle(.primary)
                                    .lineSpacing(3)
                                    .textSelection(.enabled)
                            }
                        } else {
                            Text("（无此段落）")
                                .font(CharkleTheme.text(.body))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .background(negColor.opacity(hunk.changeKind == .unchanged ? 0 : 0.06), in: RoundedRectangle(cornerRadius: CharkleTheme.Radius.sm, style: .continuous))

                    VStack(alignment: .leading, spacing: 6) {
                        diffVersionColumnHeader(
                            icon: "plus.circle.fill",
                            tint: posColor,
                            versionBadge: targetVersionBadgeLabel,
                            tooltip: "修改后对比版本（\(targetVersionBadgeLabel)）"
                        )
                        if let targetText = hunk.targetText {
                            if !hunk.inlineTokens.isEmpty && hunk.changeKind != .unchanged {
                                Text(
                                    Self.makeTargetDiffAttributedString(
                                        tokens: hunk.inlineTokens,
                                        fallbackText: targetText,
                                        textStyle: .body,
                                        isDark: colorScheme == .dark,
                                        posColor: posColor
                                    )
                                )
                                .font(CharkleTheme.text(.body))
                                .lineSpacing(3)
                                .textSelection(.enabled)
                            } else {
                                Text(targetText)
                                    .font(CharkleTheme.text(.body))
                                    .foregroundStyle(.primary)
                                    .lineSpacing(3)
                                    .textSelection(.enabled)
                            }
                        } else {
                            Text("（已删除）")
                                .font(CharkleTheme.text(.body))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .background(posColor.opacity(hunk.changeKind == .unchanged ? 0 : 0.06), in: RoundedRectangle(cornerRadius: CharkleTheme.Radius.sm, style: .continuous))
                }
            } else if !hunk.inlineTokens.isEmpty {
                inlineDiffAttributedText(hunk.inlineTokens, posColor: posColor, negColor: negColor)
                    .textSelection(.enabled)
            } else if hunk.changeKind == .unchanged || hunk.changeKind == .moved {
                Text(hunk.targetText ?? hunk.baseText ?? "")
                    .font(CharkleTheme.text(.body))
                    .foregroundStyle(.primary)
                    .lineSpacing(3)
                    .textSelection(.enabled)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    if let oldText = hunk.baseText, oldText != hunk.targetText {
                        HStack(alignment: .top, spacing: 8) {
                            diffVersionGutterBadge(
                                icon: "minus.circle.fill",
                                tint: negColor,
                                versionBadge: baseVersionBadgeLabel,
                                tooltip: "修改前（\(baseVersionBadgeLabel)）"
                            )
                            Text(
                                Self.makeBaseDiffAttributedString(
                                    tokens: [],
                                    fallbackText: oldText,
                                    textStyle: .body,
                                    isDark: colorScheme == .dark,
                                    negColor: negColor
                                )
                            )
                            .font(CharkleTheme.text(.body))
                            .lineSpacing(3)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                        }
                    }
                    if let newText = hunk.targetText {
                        HStack(alignment: .top, spacing: 8) {
                            diffVersionGutterBadge(
                                icon: "plus.circle.fill",
                                tint: posColor,
                                versionBadge: targetVersionBadgeLabel,
                                tooltip: "修改后（\(targetVersionBadgeLabel)）"
                            )
                            Text(
                                Self.makeTargetDiffAttributedString(
                                    tokens: [],
                                    fallbackText: newText,
                                    textStyle: .body,
                                    isDark: colorScheme == .dark,
                                    posColor: posColor
                                )
                            )
                            .font(CharkleTheme.text(.body))
                            .lineSpacing(3)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                        }
                    }
                }
            }
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(railBg, in: RoundedRectangle(cornerRadius: CharkleTheme.Radius.cardOuter, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: CharkleTheme.Radius.cardOuter, style: .continuous)
                .strokeBorder(
                    isFocused ? activeAccent : CharkleTheme.hairline(for: colorScheme),
                    lineWidth: isFocused ? 1.5 : CharkleTheme.hairlineWidth
                )
        )
    }

    private func diffVersionColumnHeader(
        icon: String,
        tint: Color,
        versionBadge: String,
        tooltip: String
    ) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tint)
            Text(versionBadge)
                .font(CharkleTheme.text(.caption, weight: .bold))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(tint.opacity(0.12), in: Capsule(style: .continuous))
        }
        .help(tooltip)
    }

    private func diffVersionGutterBadge(
        icon: String,
        tint: Color,
        versionBadge: String,
        tooltip: String
    ) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tint)
            Text(versionBadge)
                .font(CharkleTheme.text(.caption, weight: .bold))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 5.5)
        .padding(.vertical, 2)
        .background(tint.opacity(0.11), in: Capsule(style: .continuous))
        .fixedSize()
        .padding(.top, 1)
        .help(tooltip)
    }

    private func inlineDiffAttributedText(
        _ tokens: [DocumentInlineDiffToken],
        posColor: Color,
        negColor: Color
    ) -> Text {
        var combined = AttributedString()
        for token in tokens {
            var part = AttributedString(token.text)
            switch token.kind {
            case .equal:
                part.foregroundColor = colorScheme == .dark ? .white.opacity(0.90) : .black.opacity(0.86)
            case .deleted:
                part.foregroundColor = negColor
                part.strikethroughStyle = .single
                part.backgroundColor = negColor.opacity(0.13)
            case .inserted:
                part.foregroundColor = posColor
                part.backgroundColor = posColor.opacity(0.14)
                if token.isHighRiskNumber || token.isHighRiskDate {
                    part.inlinePresentationIntent = .stronglyEmphasized
                }
            }
            combined.append(part)
        }
        return Text(combined)
            .font(CharkleTheme.text(.body))
    }

    // MARK: - Excel Smart Primary-Key Aligned Diff Stage

    private func excelSheetDiffStage(_ report: DocumentComparisonReport) -> some View {
        let activeSheetDiff: SpreadsheetSheetDiff = {
            if let name = selectedDiffSheetName,
               let match = report.sheetDiffs.first(where: { $0.sheetName == name }) {
                return match
            }
            return report.sheetDiffs[0]
        }()
        let posColor = CharkleTheme.positive(for: colorScheme)
        let negColor = CharkleTheme.destructive(for: colorScheme)
        let visibleRows = activeSheetDiff.rowDiffs.filter { row in
            if onlyChangedBlocks && !row.changeKind.isChanged { return false }
            if activeRiskFilter == .numberOrCurrency { return row.riskFlags.contains(.numberOrCurrency) }
            if activeRiskFilter == .dateOrDeadline { return row.riskFlags.contains(.dateOrDeadline) }
            return true
        }

        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(report.sheetDiffs) { sDiff in
                            let selected = sDiff.sheetName == activeSheetDiff.sheetName
                            let changedTotal = sDiff.addedRowCount + sDiff.removedRowCount + sDiff.modifiedRowCount
                            Button {
                                selectedDiffSheetName = sDiff.sheetName
                                customPrimaryKeyCol = nil
                            } label: {
                                HStack(spacing: 5) {
                                    Text(sDiff.sheetName)
                                        .font(CharkleTheme.text(.caption, weight: selected ? .semibold : .medium))
                                    if changedTotal > 0 {
                                        Text("Δ\(changedTotal)")
                                            .font(CharkleTheme.text(.caption, weight: .bold))
                                            .monospacedDigit()
                                            .foregroundStyle(sDiff.highRiskCellCount > 0 ? negColor : posColor)
                                    }
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(
                                    selected ? formatAccent.opacity(0.15) : CharkleTheme.surfaceSubtle(for: colorScheme),
                                    in: Capsule(style: .continuous)
                                )
                            }
                            .buttonStyle(CharkleTactileButtonStyle())
                        }
                    }
                }
                .background(HorizontalWheelScrollRedirector())

                Spacer(minLength: 8)

                // Smart Primary-Key Column Selector
                if !activeSheetDiff.headers.isEmpty {
                    Menu {
                        Button {
                            customPrimaryKeyCol = nil
                            triggerComparisonReload(sheetName: activeSheetDiff.sheetName, pkCol: nil)
                        } label: {
                            if customPrimaryKeyCol == nil {
                                Label("自动识别主键（\(activeSheetDiff.primaryKeyHeader ?? "首列")）", systemImage: "checkmark")
                            } else {
                                Text("自动识别主键")
                            }
                        }
                        Divider()
                        ForEach(Array(activeSheetDiff.headers.enumerated()), id: \.offset) { colIdx, header in
                            let colTitle = header.isEmpty ? "第 \(colIdx + 1) 列" : header
                            Button {
                                customPrimaryKeyCol = colIdx
                                triggerComparisonReload(sheetName: activeSheetDiff.sheetName, pkCol: colIdx)
                            } label: {
                                if customPrimaryKeyCol == colIdx {
                                    Label("按「\(colTitle)」对齐行", systemImage: "checkmark")
                                } else {
                                    Text("按「\(colTitle)」对齐行")
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "tablecells")
                                .font(.system(size: 10.5))
                            Text("主键列：\(activeSheetDiff.primaryKeyHeader ?? "自动")")
                                .font(CharkleTheme.text(.caption, weight: .medium))
                                .lineLimit(1)
                            CharkleDropdownChevron(size: 8)
                        }
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4.5)
                        .background(CharkleTheme.surfaceSubtle(for: colorScheme), in: Capsule(style: .continuous))
                    }
                    .menuStyle(.button)
                    .buttonStyle(CharkleMenuTriggerButtonStyle())
                    .menuIndicator(.hidden)
                    .fixedSize()
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 8)

            Rectangle()
                .fill(CharkleTheme.hairline(for: colorScheme))
                .frame(height: CharkleTheme.hairlineWidth)

            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 8) {
                    if visibleRows.isEmpty {
                        Text("该工作表在当前筛选条件下无行变更")
                            .font(CharkleTheme.text(.body))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 40)
                    } else {
                        ForEach(visibleRows) { rowDiff in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack(spacing: 6) {
                                    Text(rowDiff.primaryKeyValue.isEmpty ? "行 \(rowDiff.targetRowNumber ?? rowDiff.baseRowNumber ?? 0)" : rowDiff.primaryKeyValue)
                                        .font(CharkleTheme.text(.body, weight: .semibold))
                                        .monospacedDigit()
                                    Text(rowDiff.changeKind.localizedLabel)
                                        .font(CharkleTheme.text(.caption, weight: .bold))
                                        .foregroundStyle(rowDiff.changeKind == .removed ? negColor : posColor)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 1.5)
                                        .background((rowDiff.changeKind == .removed ? negColor : posColor).opacity(0.13), in: Capsule(style: .continuous))
                                    Spacer()
                                }

                                if !rowDiff.cellDiffs.isEmpty {
                                    ForEach(rowDiff.cellDiffs) { cell in
                                        HStack(spacing: 6) {
                                            Text("\(cell.columnHeader ?? "列\(cell.colIndex + 1)")：")
                                                .font(CharkleTheme.text(.caption, weight: .medium))
                                                .foregroundStyle(.secondary)
                                            if let oldV = cell.oldValue, !oldV.isEmpty {
                                                Text(oldV)
                                                    .strikethrough(true, color: negColor)
                                                    .foregroundStyle(negColor)
                                            }
                                            Image(systemName: "arrow.right")
                                                .font(.system(size: 9))
                                                .foregroundStyle(.tertiary)
                                            Text(cell.newValue ?? "（空）")
                                                .fontWeight(.semibold)
                                                .foregroundStyle(posColor)

                                            if cell.oldFormula != cell.newFormula,
                                               (cell.oldFormula != nil || cell.newFormula != nil) {
                                                Text("fx: \(cell.oldFormula ?? "常量") → \(cell.newFormula ?? "常量")")
                                                    .font(CharkleTheme.text(.caption, weight: .medium, design: .monospaced))
                                                    .foregroundStyle(formatAccent)
                                                    .padding(.horizontal, 6)
                                                    .padding(.vertical, 1.5)
                                                    .background(formatAccent.opacity(0.12), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                                            }
                                        }
                                        .font(CharkleTheme.text(.caption))
                                        .monospacedDigit()
                                    }
                                } else {
                                    let values = rowDiff.changeKind == .removed ? rowDiff.baseValues : rowDiff.targetValues
                                    Text(values.filter { !$0.isEmpty }.joined(separator: "  |  "))
                                        .font(CharkleTheme.text(.caption))
                                        .monospacedDigit()
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(CharkleTheme.surfaceSubtle(for: colorScheme), in: RoundedRectangle(cornerRadius: CharkleTheme.Radius.chip, style: .continuous))
                        }
                    }
                }
                .padding(18)
            }
            .charkleCleanScrollbars(hidden: false)
        }
    }

    // MARK: - PDF Visual Red-Cyan Overlay & Interactive Split Curtain Wipe Stage

    private var pdfVisualComparisonStage: some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                HStack(spacing: 6) {
                    Button {
                        guard pdfPageIndex > 0 else { return }
                        pdfPageIndex -= 1
                        loadPDFVisualPages()
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 11, weight: .semibold))
                            .frame(width: 24, height: 24)
                    }
                    .buttonStyle(CharkleButtonStyle(.standard, size: .icon, iconDimension: 24))
                    .disabled(pdfPageIndex <= 0)

                    Text("第 \(pdfPageIndex + 1) / \(max(1, pdfPageCount)) 页")
                        .font(CharkleTheme.text(.caption, weight: .semibold))
                        .monospacedDigit()

                    Button {
                        guard pdfPageIndex + 1 < pdfPageCount else { return }
                        pdfPageIndex += 1
                        loadPDFVisualPages()
                    } label: {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .semibold))
                            .frame(width: 24, height: 24)
                    }
                    .buttonStyle(CharkleButtonStyle(.standard, size: .icon, iconDimension: 24))
                    .disabled(pdfPageIndex + 1 >= pdfPageCount)
                }

                Spacer()

                if pdfVisualMode == .redCyanOverlay {
                    Text("灰色＝未改动区域 / 红色＝仅旧版存在 / 青蓝＝新版新增批示或盖章")
                        .font(CharkleTheme.text(.caption))
                        .foregroundStyle(.secondary)
                } else {
                    Text("左右拖动中间分割卷帘，逐像素核查签字、红章与排版位移")
                        .font(CharkleTheme.text(.caption))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 8)

            ZStack {
                if isRenderingPDFVisual {
                    ProgressView("正在光栅化页面叠层…")
                } else if pdfVisualMode == .redCyanOverlay, let composite = pdfRedCyanImage {
                    Image(nsImage: composite)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: CharkleTheme.Radius.chip, style: .continuous))
                        .shadow(color: .black.opacity(0.18), radius: 8, y: 3)
                        .padding(14)
                } else if pdfVisualMode == .splitCurtain,
                          let baseImg = pdfBasePageImage,
                          let targetImg = pdfTargetPageImage {
                    PDFSplitCurtainComparisonView(
                        baseImage: baseImg,
                        targetImage: targetImg,
                        baseBadge: baseVersionBadgeLabel,
                        targetBadge: targetVersionBadgeLabel,
                        curtainFraction: $curtainFraction
                    )
                    .padding(14)
                } else {
                    Text("未能读取对比版本的 PDF 原文件页面")
                        .font(CharkleTheme.text(.body))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Mode 3: Scheme B Deterministic 2-Way Merge (`按差异合成新版本`)

    private var mergeStageBody: some View {
        let report = comparisonReport
        let nextVerNumber = (siblings.map { $0.richMetadata?.versionStack?.versionNumber ?? 1 }.max() ?? 1) + 1

        return VStack(alignment: .leading, spacing: 0) {
            if let report, !report.canSynthesizeTwoWay {
                VStack(spacing: 14) {
                    Image(systemName: "lock.shield")
                        .font(.system(size: 32, weight: .regular))
                        .foregroundStyle(activeAccent)
                    Text("受保护文档结构（零坏档只读对比模式）")
                        .font(CharkleTheme.text(.headline, weight: .semibold))
                    Text(report.synthesisUnavailableReason ?? "为确保 100% 零坏档风险，Excel 公式工作簿与 PDF 签批件不做自动改写；请在「对比差异」核查后用系统默认应用编辑保存并拖回叠卡。")
                        .font(CharkleTheme.text(.body))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 520)

                    HStack(spacing: 10) {
                        Button("返回精细差异对比") {
                            studioMode = .diff
                        }
                        .buttonStyle(CharkleButtonStyle(.standard, size: .md))

                        Button("用默认应用打开新版修改") {
                            openAssetInDefaultApplication(assetID: report.targetAssetID)
                        }
                        .buttonStyle(CharkleButtonStyle(.accent, size: .md))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(32)
            } else if let report {
                // Top Template Selector Bar
                HStack(spacing: 10) {
                    Text("合成母版外壳：")
                        .font(CharkleTheme.text(.caption, weight: .semibold))
                        .foregroundStyle(.secondary)

                    HStack(spacing: 2) {
                        templateChoicePill(preferTarget: true, title: "以新版为底稿（仅挑异议退回旧版）")
                        templateChoicePill(preferTarget: false, title: "以旧版为底稿")
                    }
                    .padding(2)
                    .background(CharkleTheme.surfaceSubtle(for: colorScheme), in: RoundedRectangle(cornerRadius: CharkleTheme.Radius.chip, style: .continuous))

                    Spacer()

                    Text("共 \(changedHunksForMerge.count) 处可取舍变动")
                        .font(CharkleTheme.text(.caption, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 10)

                Rectangle()
                    .fill(CharkleTheme.hairline(for: colorScheme))
                    .frame(height: CharkleTheme.hairlineWidth)

                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(changedHunksForMerge) { hunk in
                            mergeDecisionCard(hunk)
                        }

                        // Live Clean Preview via CharkleDisclosureGroup
                        CharkleDisclosureGroup(isExpanded: $isMergePreviewExpanded, showsTopDivider: true, accentChevronWhenExpanded: true) {
                            let previewText = report.previewMergedText(
                                preferTargetAsTemplate: preferTargetAsTemplate,
                                decisions: Array(mergeDecisionsByHunkID.values)
                            )
                            Text(previewText.isEmpty ? "（合成后正文预览为空）" : previewText)
                                .font(CharkleTheme.text(.body))
                                .lineSpacing(4)
                                .textSelection(.enabled)
                                .padding(14)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(CharkleTheme.surfaceSubtle(for: colorScheme), in: RoundedRectangle(cornerRadius: CharkleTheme.Radius.chip, style: .continuous))
                                .padding(.top, 6)
                        } label: {
                            Text("净版全文预览（保留原母版红头、字体与样式外壳，永不覆盖原稿）")
                                .font(CharkleTheme.text(.caption, weight: .semibold))
                        }
                    }
                    .padding(18)
                }
                .charkleCleanScrollbars(hidden: false)

                Rectangle()
                    .fill(CharkleTheme.hairline(for: colorScheme))
                    .frame(height: CharkleTheme.hairlineWidth)

                // Footer Synthesis CTA Bar
                HStack(spacing: 8) {
                    TextField("合成人（可选）", text: $mergeEditorDraft)
                        .textFieldStyle(.plain)
                        .font(CharkleTheme.text(.caption))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 6)
                        .frame(width: 112)
                        .background(CharkleTheme.surfaceSubtle(for: colorScheme), in: RoundedRectangle(cornerRadius: CharkleTheme.Radius.sm, style: .continuous))

                    TextField("版本备注", text: $mergeNoteDraft)
                        .textFieldStyle(.plain)
                        .font(CharkleTheme.text(.caption))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 6)
                        .frame(maxWidth: 260)
                        .background(CharkleTheme.surfaceSubtle(for: colorScheme), in: RoundedRectangle(cornerRadius: CharkleTheme.Radius.sm, style: .continuous))

                    Spacer()

                    Button {
                        performTwoWaySynthesis(report: report, nextVerNumber: nextVerNumber)
                    } label: {
                        HStack(spacing: 6) {
                            if isSynthesizing {
                                ProgressView().controlSize(.mini)
                            } else {
                                Image(systemName: "arrow.triangle.merge")
                                    .font(.system(size: 11.5, weight: .semibold))
                            }
                            Text("生成新版本 v\(nextVerNumber)")
                                .monospacedDigit()
                        }
                    }
                    .buttonStyle(CharkleButtonStyle(.accent, size: .md))
                    .disabled(isSynthesizing)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 11)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func templateChoicePill(preferTarget: Bool, title: String) -> some View {
        let selected = preferTargetAsTemplate == preferTarget
        let innerR = CharkleTheme.Radius.concentricInner(outer: CharkleTheme.Radius.chip, padding: 2)
        return Button {
            preferTargetAsTemplate = preferTarget
        } label: {
            Text(title)
                .font(CharkleTheme.text(.caption, weight: selected ? .semibold : .medium))
                .foregroundStyle(selected ? .primary : .secondary)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(selected ? CharkleTheme.surfaceElevated(for: colorScheme) : Color.clear, in: RoundedRectangle(cornerRadius: innerR, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func mergeDecisionCard(_ hunk: DocumentDiffHunk) -> some View {
        let defaultChoice: DocumentMergeDecision.Choice = preferTargetAsTemplate ? .acceptTarget : .keepBase
        let currentDecision = mergeDecisionsByHunkID[hunk.id]
        let activeChoice = currentDecision?.choice ?? defaultChoice
        let posColor = CharkleTheme.positive(for: colorScheme)
        let negColor = CharkleTheme.destructive(for: colorScheme)
        let warnColor = CharkleTheme.warning(for: colorScheme)

        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(hunk.sectionTitle ?? "第 \(hunk.hunkIndex + 1) 处改动")
                    .font(CharkleTheme.text(.caption, weight: .semibold))

                ForEach(Array(hunk.riskFlags).sorted(by: { $0.rawValue < $1.rawValue }), id: \.self) { flag in
                    Text(flag.localizedLabel)
                        .font(CharkleTheme.text(.caption, weight: .semibold))
                        .foregroundStyle(warnColor)
                        .padding(.horizontal, 5.5)
                        .padding(.vertical, 1.5)
                        .background(warnColor.opacity(0.14), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                }

                Spacer()

                if hunk.isProtectedComplex {
                    HStack(spacing: 5) {
                        Image(systemName: "lock.shield")
                            .font(.system(size: 10.5, weight: .semibold))
                        Text("受保护结构（只读对比）")
                            .font(CharkleTheme.text(.caption, weight: .semibold))
                    }
                    .foregroundStyle(warnColor)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(warnColor.opacity(0.13), in: Capsule(style: .continuous))

                    Button("用默认应用打开") {
                        openAssetInDefaultApplication(assetID: compareTargetAssetID ?? asset.id)
                    }
                    .buttonStyle(CharkleButtonStyle(.standard, size: .xs))
                } else {
                    HStack(spacing: 4) {
                        ForEach(DocumentMergeDecision.Choice.allCases, id: \.self) { choice in
                            let isChosen = activeChoice == choice
                            Button {
                                let seedCustom = currentDecision?.customText ?? hunk.targetText ?? hunk.baseText ?? ""
                                mergeDecisionsByHunkID[hunk.id] = DocumentMergeDecision(
                                    hunkID: hunk.id,
                                    choice: choice,
                                    customText: choice == .customText ? seedCustom : currentDecision?.customText
                                )
                            } label: {
                                Text(choice.localizedLabel)
                                    .font(CharkleTheme.text(.caption, weight: isChosen ? .semibold : .medium))
                                    .foregroundStyle(isChosen ? .white : .primary)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 3.5)
                                    .background(
                                        isChosen ? activeAccent : CharkleTheme.surfaceElevated(for: colorScheme),
                                        in: RoundedRectangle(cornerRadius: CharkleTheme.Radius.sm, style: .continuous)
                                    )
                            }
                            .buttonStyle(CharkleTactileButtonStyle())
                        }
                    }
                }
            }

            if hunk.isProtectedComplex {
                Text(hunk.protectionReason ?? "涉及复杂跨行表格或嵌套域代码，已自动保留母版原节点以确保零坏档。")
                    .font(CharkleTheme.text(.caption))
                    .foregroundStyle(.secondary)
            } else if activeChoice == .customText {
                TextField(
                    "在此微调合成后的段落文本…",
                    text: Binding(
                        get: { mergeDecisionsByHunkID[hunk.id]?.customText ?? hunk.targetText ?? hunk.baseText ?? "" },
                        set: { newVal in
                            mergeDecisionsByHunkID[hunk.id] = DocumentMergeDecision(
                                hunkID: hunk.id,
                                choice: .customText,
                                customText: newVal
                            )
                        }
                    ),
                    axis: .vertical
                )
                .textFieldStyle(.plain)
                .font(CharkleTheme.text(.body))
                .padding(9)
                .background(CharkleTheme.surfaceElevated(for: colorScheme), in: RoundedRectangle(cornerRadius: CharkleTheme.Radius.sm, style: .continuous))
            } else {
                let innerRowRadius = CharkleTheme.Radius.concentricInner(outer: CharkleTheme.Radius.cardOuter, padding: 6)
                let isBaseChosen = activeChoice == .keepBase
                let isTargetChosen = activeChoice == .acceptTarget
                let hasBaseContent = hunk.baseText != nil || hunk.inlineTokens.contains(where: { $0.kind != .inserted })
                let hasTargetContent = hunk.targetText != nil || hunk.inlineTokens.contains(where: { $0.kind != .deleted })

                VStack(alignment: .leading, spacing: 6) {
                    if hasBaseContent || isBaseChosen {
                        HStack(alignment: .top, spacing: 8) {
                            ZStack {
                                Circle()
                                    .fill(negColor.opacity(colorScheme == .dark ? 0.16 : 0.10))
                                Image(systemName: "minus.circle.fill")
                                    .font(.system(size: 12.5, weight: .semibold))
                                    .foregroundStyle(negColor)
                            }
                            .frame(width: 18, height: 18)
                            .padding(.top, 1)
                            .help("修改前（旧版）")

                            if hasBaseContent {
                                Text(
                                    Self.makeBaseDiffAttributedString(
                                        tokens: hunk.inlineTokens,
                                        fallbackText: hunk.baseText,
                                        textStyle: .body,
                                        isDark: colorScheme == .dark,
                                        negColor: negColor
                                    )
                                )
                                .font(CharkleTheme.text(.body))
                                .lineSpacing(3)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                            } else {
                                Text("（修改前无此段落，保留该项将省略）")
                                    .font(CharkleTheme.text(.caption))
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .padding(.horizontal, 9)
                        .padding(.vertical, 7)
                        .background(
                            isBaseChosen ? CharkleTheme.surfaceElevated(for: colorScheme) : Color.clear,
                            in: RoundedRectangle(cornerRadius: innerRowRadius, style: .continuous)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: innerRowRadius, style: .continuous)
                                .strokeBorder(isBaseChosen ? negColor.opacity(0.42) : Color.clear, lineWidth: 1)
                        )
                        .opacity(isBaseChosen ? 1.0 : 0.72)
                    }

                    if hasTargetContent || isTargetChosen {
                        HStack(alignment: .top, spacing: 8) {
                            ZStack {
                                Circle()
                                    .fill(posColor.opacity(colorScheme == .dark ? 0.16 : 0.10))
                                Image(systemName: "plus.circle.fill")
                                    .font(.system(size: 12.5, weight: .semibold))
                                    .foregroundStyle(posColor)
                            }
                            .frame(width: 18, height: 18)
                            .padding(.top, 1)
                            .help("修改后（新版）")

                            if hasTargetContent {
                                Text(
                                    Self.makeTargetDiffAttributedString(
                                        tokens: hunk.inlineTokens,
                                        fallbackText: hunk.targetText,
                                        textStyle: .body,
                                        isDark: colorScheme == .dark,
                                        posColor: posColor
                                    )
                                )
                                .font(CharkleTheme.text(.body))
                                .lineSpacing(3)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                            } else {
                                Text("（修改后已删除该段落，采用该项将移除）")
                                    .font(CharkleTheme.text(.caption))
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .padding(.horizontal, 9)
                        .padding(.vertical, 7)
                        .background(
                            isTargetChosen ? CharkleTheme.surfaceElevated(for: colorScheme) : Color.clear,
                            in: RoundedRectangle(cornerRadius: innerRowRadius, style: .continuous)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: innerRowRadius, style: .continuous)
                                .strokeBorder(isTargetChosen ? posColor.opacity(0.45) : Color.clear, lineWidth: 1)
                        )
                        .opacity(isTargetChosen ? 1.0 : 0.72)
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(CharkleTheme.surfaceSubtle(for: colorScheme), in: RoundedRectangle(cornerRadius: CharkleTheme.Radius.cardOuter, style: .continuous))
    }

    // MARK: - Data Loading, Hunk Stepping & Synthesis Actions

    private func bootstrapForAsset() async {
        isLoadingPayload = true
        let loaded = try? await library.readStructuredDocument(assetID: asset.id)
        guard !Task.isCancelled else { return }
        payload = loaded
        isLoadingPayload = false

        // Initialize default Base/Target version pair when part of a Version Stack
        let ordered = siblings
        if ordered.count >= 2 {
            if compareBaseAssetID == nil || !ordered.contains(where: { $0.id == compareBaseAssetID }) {
                compareBaseAssetID = ordered[ordered.count - 2].id
            }
            if compareTargetAssetID == nil || !ordered.contains(where: { $0.id == compareTargetAssetID }) {
                compareTargetAssetID = ordered[ordered.count - 1].id
            }
        }

        if let req = coordinator.quickLookDiffRequest, req.nonce != lastConsumedDiffNonce {
            applyLaunchDiffRequest(req)
        } else if studioMode != .reader {
            ensureComparisonLoaded()
        }
    }

    private func applyLaunchDiffRequest(_ req: AppCoordinatorStore.QuickLookDiffLaunchRequest) {
        lastConsumedDiffNonce = req.nonce
        let ordered = siblings
        if let explicitBase = req.baseAssetID {
            compareBaseAssetID = explicitBase
        } else if ordered.count >= 2 {
            compareBaseAssetID = ordered[ordered.count - 2].id
        }
        if let explicitTarget = req.targetAssetID {
            compareTargetAssetID = explicitTarget
        } else if let last = ordered.last {
            compareTargetAssetID = last.id
        }
        studioMode = req.openMergePanel ? .merge : .diff
        triggerComparisonReload()
    }

    private func ensureComparisonLoaded() {
        guard comparisonReport == nil, !isComparing else { return }
        triggerComparisonReload()
    }

    private func triggerComparisonReload(sheetName: String? = nil, pkCol: Int? = nil) {
        let ordered = siblings
        guard ordered.count >= 2 else { return }
        let baseID = compareBaseAssetID ?? ordered[ordered.count - 2].id
        let targetID = compareTargetAssetID ?? ordered[ordered.count - 1].id
        compareBaseAssetID = baseID
        compareTargetAssetID = targetID

        isComparing = true
        let useOCR = useOCRIfScanned
        let effectiveSheet = sheetName ?? selectedDiffSheetName
        let effectivePK = pkCol ?? customPrimaryKeyCol

        Task {
            let report = try? await library.compareDocumentVersions(
                baseAssetID: baseID,
                targetAssetID: targetID,
                sheetName: effectiveSheet,
                primaryKeyCol: effectivePK,
                useOCRIfScanned: useOCR
            )
            guard !Task.isCancelled else { return }
            comparisonReport = report
            isComparing = false
            mergeDecisionsByHunkID.removeAll()
            focusedHunkID = report?.hunks.first(where: { $0.changeKind.isChanged })?.id
            if docFamily == .pdf && pdfVisualMode != .textOrOCR {
                loadPDFVisualPages()
            }
        }
    }

    private func stepFocusedHunk(delta: Int) {
        if let nextID = DocumentRadarFilterEngine.nextFocusedHunkID(
            in: filteredHunks,
            currentFocusedID: focusedHunkID,
            delta: delta
        ) {
            focusedHunkID = nextID
        }
    }

    private func loadPDFVisualPages() {
        guard let baseID = compareBaseAssetID, let targetID = compareTargetAssetID else { return }
        isRenderingPDFVisual = true
        let pageIdx = pdfPageIndex
        Task {
            async let baseURL = library.resolveOriginalURL(for: baseID)
            async let targetURL = library.resolveOriginalURL(for: targetID)
            let (bURL, tURL) = await (baseURL, targetURL)
            guard let bURL, let tURL else {
                isRenderingPDFVisual = false
                return
            }
            let rendered = await PDFVisualDiffRenderer.renderComparisonPages(
                baseURL: bURL,
                targetURL: tURL,
                pageIndex: pageIdx
            )
            guard !Task.isCancelled else { return }
            pdfPageCount = max(1, rendered.pageCount)
            pdfBasePageImage = rendered.baseImage
            pdfTargetPageImage = rendered.targetImage
            pdfRedCyanImage = rendered.redCyanComposite
            isRenderingPDFVisual = false
        }
    }

    private func performTwoWaySynthesis(report: DocumentComparisonReport, nextVerNumber: Int) {
        guard !isSynthesizing else { return }
        isSynthesizing = true
        let editor = mergeEditorDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let note = mergeNoteDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let decisions = Array(mergeDecisionsByHunkID.values)
        let preferTarget = preferTargetAsTemplate

        Task {
            defer { isSynthesizing = false }
            do {
                let created = try await library.synthesizeDocumentVersion(
                    baseAssetID: report.baseAssetID,
                    targetAssetID: report.targetAssetID,
                    preferTargetAsTemplate: preferTarget,
                    decisions: decisions,
                    editorName: editor.isEmpty ? nil : editor,
                    changeNote: note.isEmpty ? nil : note
                )
                _ = await library.setPrimaryVersion(created.id)
                var playlist = coordinator.quickLookPlaylist
                if !playlist.contains(created.id) {
                    playlist.append(created.id)
                }
                studioMode = .reader
                coordinator.openQuickLook(assetID: created.id, playlist: playlist)
                coordinator.showToast(
                    "已合成净版 v\(nextVerNumber) 并设为主版本，可直接拖回微信发送",
                    icon: "checkmark.circle.fill",
                    tone: .success
                )
            } catch {
                coordinator.showToast(error.localizedDescription, icon: "exclamationmark.triangle", tone: .warning)
            }
        }
    }

    private func openAssetInDefaultApplication(assetID: UUID) {
        Task {
            if let url = await library.resolveFinderFileURL(for: assetID) {
                NSWorkspace.shared.open(url)
            } else {
                coordinator.showToast("尚未找到本地原文件", icon: "exclamationmark.triangle", tone: .warning)
            }
        }
    }

    private static func excelColumnLetter(_ colIndex: Int) -> String {
        var n = max(0, colIndex)
        var letters = ""
        repeat {
            let rem = n % 26
            if let scalar = UnicodeScalar(65 + rem) {
                letters.insert(Character(scalar), at: letters.startIndex)
            }
            n = (n / 26) - 1
        } while n >= 0
        return letters
    }

    private func handleStudioKeyDown(_ event: NSEvent, in hostWindow: NSWindow) -> NSEvent? {
        guard hostWindow.attachedSheet == nil, NSApp.modalWindow == nil else {
            return event
        }
        let targetWindow = event.window ?? hostWindow
        if let textInput = targetWindow.firstResponder as? any NSTextInputClient, textInput.hasMarkedText() {
            return event
        }
        if let resp = targetWindow.firstResponder {
            if let tv = resp as? NSTextView, tv.isEditable {
                return event
            }
            if let tf = resp as? NSTextField, tf.isEditable {
                return event
            }
        }
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard flags.isEmpty else {
            return event
        }
        // Deterministic Space / Esc Quick Look dismissal even when QLPreviewView or PDFView holds read-only focus
        if event.keyCode == 49 || event.keyCode == 53 {
            guard coordinator.quickLookAssetID != nil else { return event }
            if !event.isARepeat {
                hostWindow.makeFirstResponder(nil)
                coordinator.requestQuickLookDismiss()
            }
            return nil
        }
        if studioMode == .diff, let chars = event.charactersIgnoringModifiers?.lowercased() {
            if chars == "j" {
                stepFocusedHunk(delta: 1)
                return nil
            }
            if chars == "k" {
                stepFocusedHunk(delta: -1)
                return nil
            }
        }
        return event
    }
}

// MARK: - Native Office / Rich-Layout QuickLook Preview (`QLPreviewView`)

struct NativeOfficeQLPreviewRepresentable: NSViewRepresentable {
    let url: URL

    final class Coordinator {
        var currentURL: URL?
        var isClosed: Bool = false
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> QLPreviewView {
        let maybePreview: QLPreviewView? = QLPreviewView(frame: .zero, style: .normal)
        let previewView = maybePreview ?? QLPreviewView()
        previewView.autostarts = true
        previewView.shouldCloseWithWindow = false
        context.coordinator.currentURL = url
        previewView.previewItem = url as NSURL
        return previewView
    }

    func updateNSView(_ nsView: QLPreviewView, context: Context) {
        guard !context.coordinator.isClosed else { return }
        if context.coordinator.currentURL != url {
            context.coordinator.currentURL = url
            nsView.previewItem = url as NSURL
        }
    }

    static func dismantleNSView(_ nsView: QLPreviewView, coordinator: Coordinator) {
        guard !coordinator.isClosed else { return }
        coordinator.isClosed = true
        coordinator.currentURL = nil
        nsView.previewItem = nil
        nsView.close()
    }
}

// MARK: - Interactive PDF Split Curtain Wipe View

private struct PDFSplitCurtainComparisonView: View {
    let baseImage: NSImage
    let targetImage: NSImage
    let baseBadge: String
    let targetBadge: String
    @Binding var curtainFraction: CGFloat

    var body: some View {
        GeometryReader { geo in
            let availSize = geo.size
            let imgRatio = max(0.25, targetImage.size.width / max(1, targetImage.size.height))
            let fittedSize: CGSize = {
                if availSize.width / max(1, availSize.height) > imgRatio {
                    let h = availSize.height
                    return CGSize(width: h * imgRatio, height: h)
                } else {
                    let w = availSize.width
                    return CGSize(width: w, height: w / imgRatio)
                }
            }()
            let splitX = fittedSize.width * max(0.02, min(0.98, curtainFraction))

            ZStack(alignment: .leading) {
                // Full Target (New) page underneath
                Image(nsImage: targetImage)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: fittedSize.width, height: fittedSize.height)

                // Clipped Base (Old) page on the left of the curtain
                Image(nsImage: baseImage)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: fittedSize.width, height: fittedSize.height)
                    .mask(alignment: .leading) {
                        Rectangle()
                            .frame(width: splitX, height: fittedSize.height)
                    }

                // Corner badges
                VStack {
                    HStack {
                        HStack(spacing: 4) {
                            Image(systemName: "minus.circle.fill")
                                .font(.system(size: 10.5, weight: .semibold))
                            Text(baseBadge)
                                .font(CharkleTheme.text(.caption, weight: .bold))
                                .monospacedDigit()
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Color.black.opacity(0.62), in: Capsule(style: .continuous))

                        Spacer()

                        HStack(spacing: 4) {
                            Image(systemName: "plus.circle.fill")
                                .font(.system(size: 10.5, weight: .semibold))
                            Text(targetBadge)
                                .font(CharkleTheme.text(.caption, weight: .bold))
                                .monospacedDigit()
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Color(charkleHex: "#2A60E0").opacity(0.86), in: Capsule(style: .continuous))
                    }
                    .padding(10)
                    Spacer()
                }
                .frame(width: fittedSize.width, height: fittedSize.height)
                .allowsHitTesting(false)

                // Draggable vertical curtain bar + knob
                ZStack {
                    Rectangle()
                        .fill(Color(charkleHex: "#2A60E0"))
                        .frame(width: 2, height: fittedSize.height)
                        .shadow(color: .black.opacity(0.28), radius: 2)

                    Circle()
                        .fill(Color.white)
                        .frame(width: 26, height: 26)
                        .shadow(color: .black.opacity(0.26), radius: 4, y: 1)
                        .overlay {
                            Image(systemName: "arrow.left.and.right")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(Color(charkleHex: "#2A60E0"))
                        }
                }
                .offset(x: splitX - 13)
                .allowsHitTesting(false)
            }
            .frame(width: fittedSize.width, height: fittedSize.height)
            .clipShape(RoundedRectangle(cornerRadius: CharkleTheme.Radius.chip, style: .continuous))
            .shadow(color: .black.opacity(0.20), radius: 8, y: 3)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { val in
                        curtainFraction = max(0.02, min(0.98, val.location.x / max(1, fittedSize.width)))
                    }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
