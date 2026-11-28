import AppKit
import CharkleCanvas
import CharkleCore
import PDFKit
import QuickLookUI
import SwiftUI

/// Quick Look Document Studio:
/// 1. Full-bleed paper-fidelity readers for `.docx`/Office (`QLPreviewView` + structured blocks/comments), `.xlsx`, `.pdf`, and `.md` / `.txt`
/// 2. Continuous Document Paper Review (`maxWidth: 780`), Synchronized 2-Column Split Paper (`maxWidth: 980`),
///    Primary-Key-aligned Excel sheet diff, and PDF Red-Cyan overlay + Split Curtain Wipe
/// 3. Interactive Paper 2-Way Merge with complex-block protection guardrails and live full-text preview.
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

    private static let paperSheetCornerRadius: CGFloat = 10
    private static let paperProseFont: Font = .system(size: 14, weight: .regular)
    private static let studioHeaderTitleFont: Font = .system(size: 14, weight: .semibold)
    private static let boilerplateVersionDescriptors: Set<String> = [
        "基于差异审阅合成",
        "本机",
        "初稿",
        "修订版"
    ]

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
    @State private var hoveredHunkID: String? = nil
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
    @State private var mergeNoteDraft: String = ""
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

    private var activeAccentSoft: Color {
        CharkleTheme.accentSoft(for: colorScheme, source: accentSource)
    }

    private var activeAccentBorder: Color {
        CharkleTheme.accentBorder(for: colorScheme, source: accentSource)
    }

    private var siblings: [AssetRecord] {
        library.versionStackSiblings(for: asset.id)
    }

    private var primaryAsset: AssetRecord {
        library.primaryVersionAsset(for: asset.id) ?? asset
    }

    private var currentVersionNumber: Int {
        if let idx = siblings.firstIndex(where: { $0.id == asset.id }) {
            return asset.richMetadata?.versionStack?.versionNumber ?? (idx + 1)
        }
        return asset.richMetadata?.versionStack?.versionNumber ?? 1
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

    private func versionMenuItemLabel(for ver: AssetRecord, fallbackIndex: Int) -> String {
        let vMeta = ver.richMetadata?.versionStack
        let vNum = vMeta?.versionNumber ?? (fallbackIndex + 1)
        var parts = ["v\(vNum)"]
        if let desc = Self.cleanVersionDescriptor(
            changeNote: vMeta?.changeNote,
            versionLabel: vMeta?.versionLabel,
            editorName: vMeta?.editorName
        ) {
            parts.append(desc)
        }
        if ver.id == primaryAsset.id {
            parts.append("主版")
        }
        return parts.joined(separator: " · ")
    }

    public static func cleanVersionDescriptor(
        changeNote: String?,
        versionLabel: String?,
        editorName: String?
    ) -> String? {
        for rawCandidate in [changeNote, versionLabel, editorName] {
            guard let raw = rawCandidate else { continue }
            var cleaned = AssetVersionStackMetadata.strippingRedundantVersionPrefix(raw)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if cleaned.hasPrefix("(") && cleaned.hasSuffix(")") && cleaned.count >= 2 {
                cleaned = String(cleaned.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if cleaned.hasPrefix("（") && cleaned.hasSuffix("）") && cleaned.count >= 2 {
                cleaned = String(cleaned.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard !cleaned.isEmpty,
                  !cleaned.contains("净版"),
                  !boilerplateVersionDescriptors.contains(cleaned) else { continue }
            return cleaned
        }
        return nil
    }

    public static func hasSkippedBlocksBefore(
        hunks: [DocumentDiffHunk],
        at index: Int,
        onlyChanged: Bool
    ) -> Bool {
        guard onlyChanged, index > 0, index < hunks.count else { return false }
        return hunks[index].hunkIndex > hunks[index - 1].hunkIndex + 1
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
        case .xlsx:
            CharkleTheme.positive(for: colorScheme)
        case .pdf:
            CharkleTheme.destructive(for: colorScheme)
        case .pptx:
            CharkleTheme.warning(for: colorScheme)
        case .docx, .legacyOffice:
            activeAccent
        default:
            CharkleTheme.secondaryInk(for: colorScheme)
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

    private var conciseDocumentSpecText: String? {
        var parts: [String] = []
        if let p = payload {
            if !p.sheets.isEmpty {
                parts.append("\(p.sheets.count) 工作表")
            } else if p.pageCount > 0 {
                parts.append("\(p.pageCount) 页")
            }
            if p.wordCount > 0 {
                parts.append("\(p.wordCount.formatted()) 字")
            }
            if !p.hasTextLayer && docFamily == .pdf {
                parts.append("扫描件")
            }
        } else if let docMeta = asset.richMetadata?.document {
            if !docMeta.sheetNames.isEmpty {
                parts.append("\(docMeta.sheetNames.count) 工作表")
            } else if docMeta.pageCount > 0 {
                parts.append("\(docMeta.pageCount) 页")
            }
            if docMeta.wordCount > 0 {
                parts.append("\(docMeta.wordCount.formatted()) 字")
            }
            if !docMeta.hasTextLayer && docFamily == .pdf {
                parts.append("扫描件")
            }
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var diffSegmentBadgeText: String? {
        let summary = comparisonReport?.summary ?? asset.richMetadata?.document?.diffSummary
        guard let summary else { return nil }
        if summary.totalHighRiskChanges > 0 {
            return "\(summary.totalHighRiskChanges)"
        }
        if summary.totalChangedBlocks > 0 {
            return "\(summary.totalChangedBlocks)"
        }
        return nil
    }

    public var body: some View {
        let windowShape = RoundedRectangle(cornerRadius: CharkleTheme.Radius.popoverOuter, style: .continuous)

        VStack(alignment: .leading, spacing: 0) {
            topDocumentHeaderBar

            CharkleHairlineDivider()

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
            .background(CharkleTheme.galleryGround(for: colorScheme))
        }
        .frame(maxWidth: 1060, maxHeight: 760)
        .clipShape(windowShape)
        .background {
            windowShape
                .fill(CharkleTheme.surfaceElevated(for: colorScheme))
                .shadow(color: .black.opacity(colorScheme == .dark ? 0.42 : 0.18), radius: 28, y: 12)
        }
        .overlay(
            windowShape.strokeBorder(
                CharkleTheme.hairline(for: colorScheme),
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

    // MARK: - Single Unified 46pt Top Header Bar (Zero 2nd Version Pill Row)

    private var topDocumentHeaderBar: some View {
        let hasMultipleVersions = siblings.count >= 2
        let positiveInk = CharkleTheme.positive(for: colorScheme)
        let isViewingPrimary = asset.id == primaryAsset.id

        return HStack(spacing: 10) {
            Text(docFamily.badgeLabel)
                .font(CharkleTheme.text(.caption, weight: .bold, design: .monospaced))
                .foregroundStyle(formatAccent)
                .padding(.horizontal, 6.5)
                .padding(.vertical, 2.5)
                .background(
                    formatAccent.opacity(0.12),
                    in: RoundedRectangle(cornerRadius: CharkleTheme.Radius.xs, style: .continuous)
                )

            Text(asset.title)
                .font(Self.studioHeaderTitleFont)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.middle)

            if let specText = conciseDocumentSpecText {
                Text(specText)
                    .font(CharkleTheme.text(.caption))
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }

            Spacer(minLength: 8)

            if hasMultipleVersions && studioMode == .reader {
                Menu {
                    ForEach(Array(siblings.enumerated()).reversed(), id: \.element.id) { idx, ver in
                        let itemTitle = versionMenuItemLabel(for: ver, fallbackIndex: idx)
                        Button {
                            var playlist = coordinator.quickLookPlaylist
                            if !playlist.contains(ver.id) {
                                playlist.append(ver.id)
                            }
                            coordinator.openQuickLook(assetID: ver.id, playlist: playlist)
                        } label: {
                            if ver.id == asset.id {
                                Label(itemTitle, systemImage: "checkmark")
                            } else {
                                Text(itemTitle)
                            }
                        }
                    }

                    if !isViewingPrimary {
                        Divider()
                        Button {
                            Task {
                                _ = await library.setPrimaryVersion(asset.id)
                                coordinator.showToast(
                                    "已将 v\(currentVersionNumber) 设为主版本",
                                    icon: "pin.fill",
                                    tone: .success
                                )
                            }
                        } label: {
                            Label("设当前版为主版本", systemImage: "pin")
                        }
                    }
                } label: {
                    HStack(spacing: 5) {
                        Text("v\(currentVersionNumber)")
                            .font(CharkleTheme.text(.caption, weight: .semibold))
                            .monospacedDigit()
                            .foregroundStyle(.primary)

                        if isViewingPrimary {
                            Circle()
                                .fill(positiveInk)
                                .frame(width: 5, height: 5)
                            Text("主版")
                                .font(CharkleTheme.text(.caption, weight: .medium))
                                .foregroundStyle(positiveInk)
                        }

                        CharkleDropdownChevron(size: 8)
                    }
                    .padding(.horizontal, 9)
                    .frame(height: 26)
                    .background(
                        CharkleTheme.surfaceSubtle(for: colorScheme),
                        in: RoundedRectangle(cornerRadius: CharkleTheme.Radius.chip, style: .continuous)
                    )
                }
                .menuStyle(.button)
                .buttonStyle(CharkleMenuTriggerButtonStyle())
                .menuIndicator(.hidden)
                .fixedSize()
            }

            if hasMultipleVersions {
                CharkleSegmentedControl(
                    selection: $studioMode,
                    items: [
                        .init(.reader, title: "阅读"),
                        .init(.diff, title: "对比", badge: diffSegmentBadgeText),
                        .init(.merge, title: "合并")
                    ],
                    size: .compact,
                    fullWidth: false,
                    useAccentForSelected: false,
                    onSelect: { mode in
                        if mode != .reader {
                            ensureComparisonLoaded()
                        }
                    }
                )
            }

            Button {
                openAssetInDefaultApplication(
                    assetID: studioMode == .reader ? asset.id : (compareTargetAssetID ?? asset.id)
                )
            } label: {
                Label("打开", systemImage: "arrow.up.forward.app")
            }
            .buttonStyle(.charkle(.standard, size: .xs))
            .fixedSize()
            .help("使用系统默认应用打开")
        }
        .padding(.horizontal, 16)
        .frame(height: 46)
        .background(CharkleTheme.surfaceElevated(for: colorScheme))
    }

    // MARK: - Mode 1: Full-Bleed Paper Fidelity Reader (Zero Instructional Bars)

    @ViewBuilder
    private var readerStageBody: some View {
        if docFamily == .pdf, let url = originalURL, !showPDFExtractedText {
            ZStack(alignment: .topTrailing) {
                QuickLookPDFView(url: url)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                if let p = payload, !p.plainText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Button {
                        showPDFExtractedText = true
                    } label: {
                        Text("提取正文")
                            .font(CharkleTheme.text(.caption, weight: .medium))
                            .foregroundStyle(.primary)
                            .padding(.horizontal, 10)
                            .frame(height: 26)
                    }
                    .buttonStyle(.plain)
                    .charkleLiquidGlass(.regular, in: Capsule(style: .continuous), interactive: true)
                    .padding(12)
                }
            }
        } else if supportsNativeOfficeLayout, let url = originalURL {
            VStack(spacing: 0) {
                officeReaderModeBar

                CharkleHairlineDivider()

                if readerPresentationMode == .nativeLayout {
                    NativeOfficeQLPreviewRepresentable(url: url)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if isLoadingPayload && payload == nil {
                    VStack(spacing: 10) {
                        ProgressView().controlSize(.regular)
                        Text("正在解析文档内容…")
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
                        Text("暂未提取到结构化段落")
                            .font(CharkleTheme.text(.body, weight: .medium))
                            .foregroundStyle(.secondary)
                        Button("返回原版版式") {
                            readerPresentationMode = .nativeLayout
                        }
                        .buttonStyle(.charkle(.standard, size: .sm))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        } else if isLoadingPayload && payload == nil {
            VStack(spacing: 10) {
                ProgressView().controlSize(.regular)
                Text("正在解析文档内容…")
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
                .buttonStyle(.charkle(.standard, size: .sm))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var officeReaderModeBar: some View {
        let structuredTitle = isSpreadsheetFamily ? "数据表格" : "正文批注"
        let structuredIcon = isSpreadsheetFamily ? "tablecells" : "text.bubble"
        let commentCount = payload?.comments.count ?? 0

        return HStack(spacing: 8) {
            Spacer(minLength: 0)

            CharkleSegmentedControl(
                selection: $readerPresentationMode,
                items: [
                    .init(.nativeLayout, title: "原版版式", systemImage: "doc.richtext"),
                    .init(
                        .structuredContent,
                        title: structuredTitle,
                        systemImage: structuredIcon,
                        badge: (!isSpreadsheetFamily && commentCount > 0) ? "\(commentCount)" : nil
                    )
                ],
                size: .compact,
                fullWidth: false
            )
        }
        .padding(.horizontal, 16)
        .frame(height: 34)
        .background(CharkleTheme.surfaceElevated(for: colorScheme))
    }

    private func spreadsheetReaderView(_ doc: StructuredDocumentPayload) -> some View {
        let clampedIdx = min(max(0, selectedSheetIndex), max(0, doc.sheets.count - 1))
        let activeSheet = doc.sheets[clampedIdx]
        let colCount = max(1, activeSheet.columnCount, activeSheet.headers.count)

        return VStack(alignment: .leading, spacing: 0) {
            if doc.sheets.count > 1 {
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
                                        .foregroundStyle(.tertiary)
                                }
                                .foregroundStyle(selected ? activeAccent : .secondary)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4.5)
                                .background(
                                    selected ? activeAccentSoft : CharkleTheme.surfaceSubtle(for: colorScheme),
                                    in: Capsule(style: .continuous)
                                )
                            }
                            .buttonStyle(CharkleTactileButtonStyle())
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 7)
                }
                .background(CharkleTheme.surfaceElevated(for: colorScheme))
                .background(HorizontalWheelScrollRedirector())

                CharkleHairlineDivider()
            }

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
                                                .background(
                                                    formatAccent.opacity(0.12),
                                                    in: RoundedRectangle(cornerRadius: CharkleTheme.Radius.xs, style: .continuous)
                                                )
                                                .help("公式：\(formula)")
                                        }
                                    }
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 6)
                                    .frame(width: 148, alignment: .leading)
                                    .overlay(alignment: .trailing) {
                                        CharkleHairlineDivider(axis: .vertical)
                                    }
                                }
                            }
                            .background(rowIdx.isMultiple(of: 2) ? CharkleTheme.surfaceElevated(for: colorScheme) : CharkleTheme.surfaceSubtle(for: colorScheme).opacity(0.45))
                            .overlay(alignment: .bottom) {
                                CharkleHairlineDivider()
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
                                        CharkleHairlineDivider(axis: .vertical)
                                    }
                            }
                        }
                        .background(CharkleTheme.surfaceSubtle(for: colorScheme))
                        .overlay(alignment: .bottom) {
                            CharkleHairlineDivider()
                        }
                    }
                }
            }
            .background(CharkleTheme.surfaceElevated(for: colorScheme))
            .charkleCleanScrollbars(hidden: false)
        }
    }

    private var markdownOrTextReaderView: some View {
        let rawText = payload?.plainText ?? asset.ocrText ?? asset.richMetadata?.textExcerpt ?? asset.notes
        let isMarkdown = docFamily == .markdown || asset.isMarkdownDocument

        return ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 14) {
                if isMarkdown {
                    HStack {
                        Spacer()
                        Button(showRawMarkdownSource ? "渲染排版" : "纯文本源码") {
                            showRawMarkdownSource.toggle()
                        }
                        .buttonStyle(.charkle(.subtle, size: .xs))
                    }
                }

                if isMarkdown && !showRawMarkdownSource {
                    QuickLookMarkdownContentView(markdown: rawText)
                } else {
                    Text(rawText.isEmpty ? "暂无文本内容" : rawText)
                        .font(showRawMarkdownSource ? CharkleTheme.text(.body, design: .monospaced) : Self.paperProseFont)
                        .foregroundStyle(.primary)
                        .lineSpacing(5)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.horizontal, 36)
            .padding(.vertical, 28)
            .frame(maxWidth: 780, alignment: .leading)
            .modifier(DocumentPaperSheetModifier(cornerRadius: Self.paperSheetCornerRadius))
            .frame(maxWidth: .infinity)
            .padding(24)
        }
        .charkleCleanScrollbars(hidden: false)
    }

    private func structuredDocumentReaderView(_ doc: StructuredDocumentPayload) -> some View {
        let redHeaderInk = CharkleTheme.destructive(for: colorScheme)

        return ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 14) {
                if showPDFExtractedText && docFamily == .pdf && originalURL != nil {
                    HStack {
                        Spacer()
                        Button("原版页面") {
                            showPDFExtractedText = false
                        }
                        .buttonStyle(.charkle(.standard, size: .xs))
                    }
                }

                if doc.isRedHeaderStyle {
                    VStack(spacing: 6) {
                        Text(doc.title)
                            .font(CharkleTheme.text(.title, weight: .bold))
                            .foregroundStyle(redHeaderInk)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity)
                        Rectangle()
                            .fill(redHeaderInk)
                            .frame(height: 2)
                    }
                    .padding(.bottom, 6)
                }

                ForEach(doc.blocks) { block in
                    documentBlockView(block)
                }

                if doc.blocks.isEmpty && !doc.plainText.isEmpty {
                    Text(doc.plainText)
                        .font(Self.paperProseFont)
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
                                .background(
                                    CharkleTheme.surfaceSubtle(for: colorScheme),
                                    in: RoundedRectangle(cornerRadius: CharkleTheme.Radius.chip, style: .continuous)
                                )
                            }
                        }
                        .padding(.top, 6)
                    } label: {
                        Text("批注（\(doc.comments.count)）")
                            .font(CharkleTheme.text(.caption, weight: .semibold))
                    }
                }
            }
            .padding(.horizontal, 36)
            .padding(.vertical, 28)
            .frame(maxWidth: 780, alignment: .leading)
            .modifier(DocumentPaperSheetModifier(cornerRadius: Self.paperSheetCornerRadius))
            .frame(maxWidth: .infinity)
            .padding(24)
        }
        .charkleCleanScrollbars(hidden: false)
    }

    @ViewBuilder
    private func documentBlockView(_ block: DocumentBlock) -> some View {
        switch block.kind {
        case .heading:
            let level = block.headingLevel ?? 2
            let headingFont: Font = level <= 1
                ? CharkleTheme.text(.title, weight: .bold)
                : (level == 2 ? CharkleTheme.text(.headline, weight: .bold) : Self.studioHeaderTitleFont)
            Text(block.text)
                .font(headingFont)
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
                                            CharkleHairlineDivider(axis: .vertical)
                                        }
                                    }
                            }
                        }
                        .background(rIdx == 0 ? CharkleTheme.surfaceSubtle(for: colorScheme) : Color.clear)
                        .overlay(alignment: .bottom) {
                            if rIdx < block.tableRows.count - 1 {
                                CharkleHairlineDivider()
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
                    let bodyFont: Font = block.kind == .codeBlock
                        ? CharkleTheme.text(.body, design: .monospaced)
                        : Self.paperProseFont
                    Text(block.kind == .listItem ? "• \(block.text)" : block.text)
                        .font(bodyFont)
                        .foregroundStyle(block.kind == .quote ? .secondary : .primary)
                        .lineSpacing(5)
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
                    .background(
                        (isIns ? pos : neg).opacity(0.12),
                        in: RoundedRectangle(cornerRadius: CharkleTheme.Radius.xs, style: .continuous)
                    )
                    .help("\(isIns ? "修订插入" : "修订删除")\(span.author.map { " (\($0))" } ?? "")")
            }
        }
    }

    // MARK: - Mode 2: Continuous Paper Sheet & Synchronized 2-Column Split Diff

    private var diffStageBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            diffControlAndRadarBar

            CharkleHairlineDivider()

            if isComparing && comparisonReport == nil {
                VStack(spacing: 10) {
                    ProgressView().controlSize(.regular)
                    Text("正在比对版本差异…")
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
                    Text("选择两个版本查看差异")
                        .font(CharkleTheme.text(.body))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var visibleRadarFilters: [RiskRadarFilter] {
        RiskRadarFilter.allCases.filter { filter in
            filter == .all || radarCount(for: filter) > 0 || activeRiskFilter == filter
        }
    }

    private func conciseRadarLabel(for filter: RiskRadarFilter) -> String {
        switch filter {
        case .all: "全部"
        case .numberOrCurrency: "数字"
        case .dateOrDeadline: "时间"
        case .tableMutation: "表格"
        case .nativeRevisionOrComment: "批注"
        }
    }

    private var diffControlAndRadarBar: some View {
        let baseAsset = compareBaseAssetID.flatMap { library.allAssetsByID[$0] }
        let targetAsset = compareTargetAssetID.flatMap { library.allAssetsByID[$0] }
        let isPDFVisualStage = docFamily == .pdf && (pdfVisualMode == .redCyanOverlay || pdfVisualMode == .splitCurtain)

        return HStack(spacing: 8) {
            versionPickerMenu(
                selected: baseAsset,
                fallbackBadge: baseVersionBadgeLabel
            ) { picked in
                compareBaseAssetID = picked.id
                triggerComparisonReload()
            }

            Image(systemName: "arrow.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)

            versionPickerMenu(
                selected: targetAsset,
                fallbackBadge: targetVersionBadgeLabel
            ) { picked in
                compareTargetAssetID = picked.id
                triggerComparisonReload()
            }

            if !isPDFVisualStage {
                Rectangle()
                    .fill(CharkleTheme.hairline(for: colorScheme))
                    .frame(width: CharkleTheme.hairlineWidth, height: 12)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(visibleRadarFilters) { filter in
                            DiffRadarChipButton(
                                title: conciseRadarLabel(for: filter),
                                count: radarCount(for: filter),
                                isActive: activeRiskFilter == filter
                            ) {
                                withAnimation(CharkleMotion.accessible(CharkleMotion.settleStrong, reduced: reduceMotion)) {
                                    activeRiskFilter = filter
                                }
                            }
                        }
                    }
                }
                .background(HorizontalWheelScrollRedirector())
            }

            Spacer(minLength: 8)

            if docFamily == .pdf {
                CharkleSegmentedControl(
                    selection: $pdfVisualMode,
                    items: [
                        .init(.textOrOCR, title: "文本"),
                        .init(.redCyanOverlay, title: "叠层"),
                        .init(.splitCurtain, title: "卷帘")
                    ],
                    size: .compact,
                    fullWidth: false,
                    onSelect: { mode in
                        if mode != .textOrOCR {
                            loadPDFVisualPages()
                        }
                    }
                )

                if pdfVisualMode == .textOrOCR {
                    DiffTogglePillButton(title: "OCR", isOn: $useOCRIfScanned) {
                        triggerComparisonReload()
                    }
                }
            } else if comparisonReport?.sheetDiffs.isEmpty ?? true {
                CharkleSegmentedControl(
                    selection: $textDiffLayout,
                    items: [
                        .init(.inlineReview, title: "审阅"),
                        .init(.sideBySide, title: "双栏")
                    ],
                    size: .compact,
                    fullWidth: false
                )
            }

            if !isPDFVisualStage {
                DiffTogglePillButton(title: "仅看改动", isOn: $onlyChangedBlocks)

                HStack(spacing: 2) {
                    Button {
                        stepFocusedHunk(delta: -1)
                    } label: {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 10.5, weight: .semibold))
                    }
                    .buttonStyle(.charkle(.subtle, size: .icon, iconDimension: 24))
                    .disabled(filteredHunks.isEmpty)
                    .help("上一处差异 (K)")

                    Button {
                        stepFocusedHunk(delta: 1)
                    } label: {
                        Image(systemName: "arrow.down")
                            .font(.system(size: 10.5, weight: .semibold))
                    }
                    .buttonStyle(.charkle(.subtle, size: .icon, iconDimension: 24))
                    .disabled(filteredHunks.isEmpty)
                    .help("下一处差异 (J)")
                }
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 38)
        .background(CharkleTheme.surfaceElevated(for: colorScheme))
    }

    private func versionPickerMenu(
        selected: AssetRecord?,
        fallbackBadge: String,
        onSelect: @escaping (AssetRecord) -> Void
    ) -> some View {
        let shortBadge: String = {
            if let selected, let idx = siblings.firstIndex(where: { $0.id == selected.id }) {
                let vNum = selected.richMetadata?.versionStack?.versionNumber ?? (idx + 1)
                return "v\(vNum)"
            }
            if let vNum = selected?.richMetadata?.versionStack?.versionNumber {
                return "v\(vNum)"
            }
            return fallbackBadge
        }()

        return Menu {
            ForEach(Array(siblings.enumerated()).reversed(), id: \.element.id) { idx, ver in
                let itemTitle = versionMenuItemLabel(for: ver, fallbackIndex: idx)
                Button {
                    onSelect(ver)
                } label: {
                    if ver.id == selected?.id {
                        Label(itemTitle, systemImage: "checkmark")
                    } else {
                        Text(itemTitle)
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(shortBadge)
                    .font(CharkleTheme.text(.caption, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                CharkleDropdownChevron(size: 8)
            }
            .padding(.horizontal, 8.5)
            .frame(height: 24)
            .background(CharkleTheme.surfaceSubtle(for: colorScheme), in: Capsule(style: .continuous))
        }
        .menuStyle(.button)
        .buttonStyle(CharkleMenuTriggerButtonStyle())
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private func radarCount(for filter: RiskRadarFilter) -> Int {
        guard let report = comparisonReport else { return 0 }
        return DocumentRadarFilterEngine.radarBadgeCount(in: report, for: filter)
    }

    // MARK: - Word / Text Continuous Paper & Synchronized 2-Column Split Stage

    @ViewBuilder
    private func wordAndTextDiffStage(_ report: DocumentComparisonReport) -> some View {
        let items = filteredHunks
        let showComments = !report.commentDiffs.isEmpty
            && (activeRiskFilter == .all || activeRiskFilter == .nativeRevisionOrComment)

        if items.isEmpty && !showComments {
            VStack(spacing: 8) {
                Text(activeRiskFilter == .all ? "两版正文一致，未检测到段落变更" : "当前筛选下无匹配变更")
                    .font(CharkleTheme.text(.body, weight: .medium))
                    .foregroundStyle(.secondary)
                if activeRiskFilter != .all {
                    Button("显示全部改动") {
                        activeRiskFilter = .all
                    }
                    .buttonStyle(.charkle(.standard, size: .xs))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if textDiffLayout == .sideBySide {
            synchronizedSplitDiffSheet(report: report, items: items, showComments: showComments)
        } else {
            continuousPaperReviewSheet(report: report, items: items, showComments: showComments)
        }
    }

    private func continuousPaperReviewSheet(
        report: DocumentComparisonReport,
        items: [DocumentDiffHunk],
        showComments: Bool
    ) -> some View {
        let ordinalByID = changedOrdinalMap(for: report.hunks)

        return ScrollViewReader { proxy in
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { idx, hunk in
                        if Self.hasSkippedBlocksBefore(hunks: items, at: idx, onlyChanged: onlyChangedBlocks) {
                            paperSkippedBlocksFoldSeparator
                        }

                        paperInlineHunkRow(hunk, changedOrdinal: ordinalByID[hunk.id])
                            .id(hunk.id)
                    }

                    if showComments {
                        paperCommentDiffFooter(report.commentDiffs)
                    }
                }
                .padding(.horizontal, 36)
                .padding(.vertical, 28)
                .frame(maxWidth: 780, alignment: .leading)
                .modifier(DocumentPaperSheetModifier(cornerRadius: Self.paperSheetCornerRadius))
                .frame(maxWidth: .infinity)
                .padding(24)
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

    private var paperSkippedBlocksFoldSeparator: some View {
        HStack(spacing: 10) {
            CharkleHairlineDivider()
            Text("⋯ 省略未改动段落")
                .font(CharkleTheme.text(.caption))
                .foregroundStyle(.tertiary)
                .fixedSize()
            CharkleHairlineDivider()
        }
        .frame(height: 28)
        .padding(.vertical, 4)
    }

    private func changedOrdinalMap(for allHunks: [DocumentDiffHunk]) -> [String: Int] {
        var map: [String: Int] = [:]
        var next = 1
        for h in allHunks where h.changeKind.isChanged {
            map[h.id] = next
            next += 1
        }
        return map
    }

    private func gutterBarColor(
        for kind: DocumentDiffChangeKind,
        posColor: Color,
        negColor: Color
    ) -> Color {
        switch kind {
        case .added:
            posColor
        case .removed:
            negColor
        case .modified, .moved:
            activeAccent
        case .unchanged:
            .clear
        }
    }

    private func conciseRiskFlagLabel(_ flag: DocumentDiffRiskFlag) -> String {
        switch flag {
        case .numberOrCurrency: "数字"
        case .dateOrDeadline: "时间"
        case .tableMutation: "表格"
        case .nativeRevisionOrComment: "批注"
        }
    }

    private func paperInlineHunkRow(_ hunk: DocumentDiffHunk, changedOrdinal: Int?) -> some View {
        let isFocused = focusedHunkID == hunk.id
        let isHovered = hoveredHunkID == hunk.id
        let posColor = CharkleTheme.positive(for: colorScheme)
        let negColor = CharkleTheme.destructive(for: colorScheme)
        let warnColor = CharkleTheme.warning(for: colorScheme)
        let isChanged = hunk.changeKind.isChanged
        let barColor = gutterBarColor(for: hunk.changeKind, posColor: posColor, negColor: negColor)
        let sortedFlags = Array(hunk.riskFlags).sorted { $0.rawValue < $1.rawValue }

        return HStack(alignment: .top, spacing: 12) {
            Capsule(style: .continuous)
                .fill(barColor)
                .frame(width: 3)
                .padding(.vertical, 2)

            VStack(alignment: .leading, spacing: 6) {
                if isChanged {
                    HStack(spacing: 6) {
                        if let changedOrdinal {
                            Text("#\(changedOrdinal)")
                                .font(CharkleTheme.text(.caption, weight: .medium, design: .monospaced))
                                .monospacedDigit()
                                .foregroundStyle(.tertiary)
                        }

                        if let sec = hunk.sectionTitle, !sec.isEmpty {
                            Text(sec)
                                .font(CharkleTheme.text(.caption, weight: .medium))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }

                        if hunk.changeKind == .moved,
                           let fromIdx = hunk.movedFromIndex,
                           let toIdx = hunk.movedToIndex {
                            Text("段落 \(fromIdx + 1) → \(toIdx + 1)")
                                .font(CharkleTheme.text(.caption))
                                .monospacedDigit()
                                .foregroundStyle(.tertiary)
                        }

                        ForEach(sortedFlags, id: \.self) { flag in
                            HStack(spacing: 3) {
                                if flag == .numberOrCurrency {
                                    Image(systemName: "number.circle.fill")
                                        .font(.system(size: 10))
                                } else if flag == .dateOrDeadline {
                                    Image(systemName: "clock.fill")
                                        .font(.system(size: 10))
                                }
                                Text(conciseRiskFlagLabel(flag))
                                    .font(CharkleTheme.text(.caption, weight: .medium))
                            }
                            .foregroundStyle(warnColor)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(
                                warnColor.opacity(0.12),
                                in: RoundedRectangle(cornerRadius: CharkleTheme.Radius.xs, style: .continuous)
                            )
                        }

                        Spacer(minLength: 4)

                        if isHovered || isFocused {
                            Button {
                                let copyStr = hunk.targetText ?? hunk.baseText ?? ""
                                let pb = NSPasteboard.general
                                pb.clearContents()
                                pb.setString(copyStr, forType: .string)
                                coordinator.showToast("已复制段落文本", icon: "doc.on.doc")
                            } label: {
                                Image(systemName: "doc.on.doc")
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 20, height: 20)
                            }
                            .buttonStyle(.plain)
                            .help("复制段落文本")
                        }
                    }
                }

                if !hunk.tableCellDiffs.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(hunk.tableCellDiffs) { cell in
                            HStack(spacing: 6) {
                                Text("\(cell.rowKey ?? "行\(cell.rowIndex + 1)") / \(cell.columnHeader ?? "列\(cell.colIndex + 1)")")
                                    .font(CharkleTheme.text(.caption, weight: .semibold))
                                    .foregroundStyle(.secondary)
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
                } else if !hunk.inlineTokens.isEmpty && isChanged {
                    inlineDiffAttributedText(hunk.inlineTokens, posColor: posColor, negColor: negColor)
                        .lineSpacing(5)
                        .textSelection(.enabled)
                } else if !isChanged || hunk.changeKind == .moved {
                    Text(hunk.targetText ?? hunk.baseText ?? "")
                        .font(Self.paperProseFont)
                        .foregroundStyle(.primary)
                        .lineSpacing(5)
                        .textSelection(.enabled)
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        if let oldText = hunk.baseText, oldText != hunk.targetText {
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: "minus.circle.fill")
                                    .font(.system(size: 12.5, weight: .semibold))
                                    .foregroundStyle(negColor)
                                    .padding(.top, 2)
                                    .help("修改前（\(baseVersionBadgeLabel)）")

                                Text(
                                    Self.makeBaseDiffAttributedString(
                                        tokens: [],
                                        fallbackText: oldText,
                                        textStyle: .body,
                                        isDark: colorScheme == .dark,
                                        negColor: negColor
                                    )
                                )
                                .font(Self.paperProseFont)
                                .lineSpacing(5)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                            }
                        }

                        if let newText = hunk.targetText {
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: "plus.circle.fill")
                                    .font(.system(size: 12.5, weight: .semibold))
                                    .foregroundStyle(posColor)
                                    .padding(.top, 2)
                                    .help("修改后（\(targetVersionBadgeLabel)）")

                                Text(
                                    Self.makeTargetDiffAttributedString(
                                        tokens: [],
                                        fallbackText: newText,
                                        textStyle: .body,
                                        isDark: colorScheme == .dark,
                                        posColor: posColor
                                    )
                                )
                                .font(Self.paperProseFont)
                                .lineSpacing(5)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .padding(.leading, -10)
        .background(
            isFocused
                ? activeAccentSoft
                : (isHovered && isChanged ? CharkleTheme.surfaceSubtle(for: colorScheme).opacity(0.45) : Color.clear),
            in: RoundedRectangle(cornerRadius: CharkleTheme.Radius.sm, style: .continuous)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            if isChanged {
                focusedHunkID = hunk.id
            }
        }
        .onHover { hovering in
            if hovering {
                hoveredHunkID = hunk.id
            } else if hoveredHunkID == hunk.id {
                hoveredHunkID = nil
            }
        }
    }

    private func synchronizedSplitDiffSheet(
        report: DocumentComparisonReport,
        items: [DocumentDiffHunk],
        showComments: Bool
    ) -> some View {
        let posColor = CharkleTheme.positive(for: colorScheme)
        let negColor = CharkleTheme.destructive(for: colorScheme)
        let sheetShape = RoundedRectangle(cornerRadius: Self.paperSheetCornerRadius, style: .continuous)

        return VStack(spacing: 0) {
            // Sticky 32pt 2-Column Split Header Row
            HStack(spacing: 0) {
                HStack(spacing: 5) {
                    Image(systemName: "minus.circle.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(negColor)
                    Text(baseVersionBadgeLabel)
                        .font(CharkleTheme.text(.caption, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 18)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                CharkleHairlineDivider(axis: .vertical)

                HStack(spacing: 5) {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(posColor)
                    Text(targetVersionBadgeLabel)
                        .font(CharkleTheme.text(.caption, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 18)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(height: 32)
            .background(CharkleTheme.surfaceSubtle(for: colorScheme).opacity(0.55))

            CharkleHairlineDivider()

            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { idx, hunk in
                            if Self.hasSkippedBlocksBefore(hunks: items, at: idx, onlyChanged: onlyChangedBlocks) {
                                paperSkippedBlocksFoldSeparator
                                    .padding(.horizontal, 18)
                                CharkleHairlineDivider()
                            }

                            splitDiffLockstepRow(hunk, posColor: posColor, negColor: negColor)
                                .id(hunk.id)

                            if idx < items.count - 1 || showComments {
                                CharkleHairlineDivider()
                            }
                        }

                        if showComments {
                            paperCommentDiffFooter(report.commentDiffs)
                                .padding(.horizontal, 18)
                                .padding(.bottom, 16)
                        }
                    }
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
        .frame(maxWidth: 980, maxHeight: .infinity)
        .background(CharkleTheme.surfaceElevated(for: colorScheme), in: sheetShape)
        .clipShape(sheetShape)
        .overlay(
            sheetShape.strokeBorder(
                CharkleTheme.hairline(for: colorScheme),
                lineWidth: CharkleTheme.hairlineWidth
            )
        )
        .shadow(color: .black.opacity(colorScheme == .dark ? 0.28 : 0.06), radius: 10, y: 3)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(20)
    }

    private func splitDiffLockstepRow(
        _ hunk: DocumentDiffHunk,
        posColor: Color,
        negColor: Color
    ) -> some View {
        let isFocused = focusedHunkID == hunk.id
        let isChanged = hunk.changeKind.isChanged
        let leftBg: Color = isFocused
            ? activeAccentSoft
            : (isChanged && hunk.baseText != nil ? negColor.opacity(0.045) : Color.clear)
        let rightBg: Color = isFocused
            ? activeAccentSoft
            : (isChanged && hunk.targetText != nil ? posColor.opacity(0.045) : Color.clear)

        return HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                if let baseText = hunk.baseText {
                    if !hunk.inlineTokens.isEmpty && isChanged {
                        Text(
                            Self.makeBaseDiffAttributedString(
                                tokens: hunk.inlineTokens,
                                fallbackText: baseText,
                                textStyle: .body,
                                isDark: colorScheme == .dark,
                                negColor: negColor
                            )
                        )
                        .font(Self.paperProseFont)
                        .lineSpacing(4.5)
                        .textSelection(.enabled)
                    } else if isChanged && hunk.targetText == nil {
                        Text(
                            Self.makeBaseDiffAttributedString(
                                tokens: [],
                                fallbackText: baseText,
                                textStyle: .body,
                                isDark: colorScheme == .dark,
                                negColor: negColor
                            )
                        )
                        .font(Self.paperProseFont)
                        .lineSpacing(4.5)
                        .textSelection(.enabled)
                    } else {
                        Text(baseText)
                            .font(Self.paperProseFont)
                            .foregroundStyle(.primary)
                            .lineSpacing(4.5)
                            .textSelection(.enabled)
                    }
                } else {
                    Text("—")
                        .font(CharkleTheme.text(.caption))
                        .foregroundStyle(.quaternary)
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(leftBg)

            VStack(alignment: .leading, spacing: 4) {
                if !hunk.tableCellDiffs.isEmpty {
                    ForEach(hunk.tableCellDiffs) { cell in
                        HStack(spacing: 6) {
                            Text("\(cell.rowKey ?? "行\(cell.rowIndex + 1)") / \(cell.columnHeader ?? "列\(cell.colIndex + 1)")")
                                .font(CharkleTheme.text(.caption, weight: .semibold))
                                .foregroundStyle(.secondary)
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
                } else if let targetText = hunk.targetText {
                    if !hunk.inlineTokens.isEmpty && isChanged {
                        Text(
                            Self.makeTargetDiffAttributedString(
                                tokens: hunk.inlineTokens,
                                fallbackText: targetText,
                                textStyle: .body,
                                isDark: colorScheme == .dark,
                                posColor: posColor
                            )
                        )
                        .font(Self.paperProseFont)
                        .lineSpacing(4.5)
                        .textSelection(.enabled)
                    } else if isChanged && hunk.baseText == nil {
                        Text(
                            Self.makeTargetDiffAttributedString(
                                tokens: [],
                                fallbackText: targetText,
                                textStyle: .body,
                                isDark: colorScheme == .dark,
                                posColor: posColor
                            )
                        )
                        .font(Self.paperProseFont)
                        .lineSpacing(4.5)
                        .textSelection(.enabled)
                    } else {
                        Text(targetText)
                            .font(Self.paperProseFont)
                            .foregroundStyle(.primary)
                            .lineSpacing(4.5)
                            .textSelection(.enabled)
                    }
                } else {
                    Text("—")
                        .font(CharkleTheme.text(.caption))
                        .foregroundStyle(.quaternary)
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(rightBg)
        }
        .overlay(alignment: .center) {
            Rectangle()
                .fill(CharkleTheme.hairline(for: colorScheme))
                .frame(width: CharkleTheme.hairlineWidth)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if isChanged {
                focusedHunkID = hunk.id
            }
        }
    }

    private func paperCommentDiffFooter(_ commentDiffs: [DocumentCommentDiff]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            CharkleHairlineDivider()
                .padding(.vertical, 6)

            Text("批注变动（\(commentDiffs.count)）")
                .font(CharkleTheme.text(.caption, weight: .semibold))
                .foregroundStyle(.secondary)

            ForEach(commentDiffs) { cDiff in
                HStack(spacing: 8) {
                    Text(cDiff.changeKind.localizedLabel)
                        .font(CharkleTheme.text(.caption, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(
                            CharkleTheme.surfaceSubtle(for: colorScheme),
                            in: RoundedRectangle(cornerRadius: CharkleTheme.Radius.xs, style: .continuous)
                        )
                    Text("\(cDiff.comment.author)：\(cDiff.comment.text)")
                        .font(CharkleTheme.text(.caption))
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                }
            }
        }
        .padding(.top, 8)
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
            .font(Self.paperProseFont)
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
        let sheetShape = RoundedRectangle(cornerRadius: Self.paperSheetCornerRadius, style: .continuous)

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
                                            .font(CharkleTheme.text(.caption, weight: .semibold))
                                            .monospacedDigit()
                                            .foregroundStyle(selected ? activeAccent : .secondary)
                                    }
                                }
                                .foregroundStyle(selected ? activeAccent : .primary)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4.5)
                                .background(
                                    selected ? activeAccentSoft : CharkleTheme.surfaceSubtle(for: colorScheme),
                                    in: Capsule(style: .continuous)
                                )
                            }
                            .buttonStyle(CharkleTactileButtonStyle())
                        }
                    }
                }
                .background(HorizontalWheelScrollRedirector())

                Spacer(minLength: 8)

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
                            Text("主键：\(activeSheetDiff.primaryKeyHeader ?? "自动")")
                                .font(CharkleTheme.text(.caption, weight: .medium))
                                .lineLimit(1)
                            CharkleDropdownChevron(size: 8)
                        }
                        .padding(.horizontal, 9)
                        .frame(height: 24)
                        .background(CharkleTheme.surfaceSubtle(for: colorScheme), in: Capsule(style: .continuous))
                    }
                    .menuStyle(.button)
                    .buttonStyle(CharkleMenuTriggerButtonStyle())
                    .menuIndicator(.hidden)
                    .fixedSize()
                }
            }
            .padding(.horizontal, 16)
            .frame(height: 36)
            .background(CharkleTheme.surfaceElevated(for: colorScheme))

            CharkleHairlineDivider()

            ScrollView(.vertical) {
                if visibleRows.isEmpty {
                    Text("该工作表在当前筛选下无行变更")
                        .font(CharkleTheme.text(.body))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 48)
                } else {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(visibleRows.enumerated()), id: \.element.id) { idx, rowDiff in
                            HStack(alignment: .top, spacing: 12) {
                                Capsule(style: .continuous)
                                    .fill(rowDiff.changeKind == .removed ? negColor : (rowDiff.changeKind == .added ? posColor : activeAccent))
                                    .frame(width: 3)
                                    .padding(.vertical, 2)

                                VStack(alignment: .leading, spacing: 5) {
                                    HStack(spacing: 6) {
                                        Text(rowDiff.primaryKeyValue.isEmpty ? "行 \(rowDiff.targetRowNumber ?? rowDiff.baseRowNumber ?? 0)" : rowDiff.primaryKeyValue)
                                            .font(CharkleTheme.text(.body, weight: .semibold))
                                            .monospacedDigit()
                                        Text(rowDiff.changeKind.localizedLabel)
                                            .font(CharkleTheme.text(.caption, weight: .semibold))
                                            .foregroundStyle(rowDiff.changeKind == .removed ? negColor : posColor)
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
                                                        .background(
                                                            formatAccent.opacity(0.12),
                                                            in: RoundedRectangle(cornerRadius: CharkleTheme.Radius.xs, style: .continuous)
                                                        )
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
                            }
                            .padding(.horizontal, 18)
                            .padding(.vertical, 12)

                            if idx < visibleRows.count - 1 {
                                CharkleHairlineDivider()
                            }
                        }
                    }
                    .frame(maxWidth: 920, alignment: .leading)
                    .background(CharkleTheme.surfaceElevated(for: colorScheme), in: sheetShape)
                    .overlay(
                        sheetShape.strokeBorder(
                            CharkleTheme.hairline(for: colorScheme),
                            lineWidth: CharkleTheme.hairlineWidth
                        )
                    )
                    .frame(maxWidth: .infinity)
                    .padding(20)
                }
            }
            .charkleCleanScrollbars(hidden: false)
        }
    }

    // MARK: - PDF Visual Red-Cyan Overlay & Split Curtain Stage (Zero Tutorial Sentences)

    private var pdfVisualComparisonStage: some View {
        let negColor = CharkleTheme.destructive(for: colorScheme)

        return VStack(spacing: 8) {
            HStack(spacing: 12) {
                HStack(spacing: 6) {
                    Button {
                        guard pdfPageIndex > 0 else { return }
                        pdfPageIndex -= 1
                        loadPDFVisualPages()
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .buttonStyle(.charkle(.standard, size: .icon, iconDimension: 24))
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
                    }
                    .buttonStyle(.charkle(.standard, size: .icon, iconDimension: 24))
                    .disabled(pdfPageIndex + 1 >= pdfPageCount)
                }

                Spacer()

                if pdfVisualMode == .redCyanOverlay {
                    HStack(spacing: 12) {
                        HStack(spacing: 5) {
                            Circle()
                                .fill(negColor)
                                .frame(width: 6, height: 6)
                            Text("\(baseVersionBadgeLabel) 旧版")
                                .font(CharkleTheme.text(.caption))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        HStack(spacing: 5) {
                            Circle()
                                .fill(activeAccent)
                                .frame(width: 6, height: 6)
                            Text("\(targetVersionBadgeLabel) 新版")
                                .font(CharkleTheme.text(.caption))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)

            ZStack {
                if isRenderingPDFVisual {
                    ProgressView("正在渲染页面叠层…")
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
                        accentColor: activeAccent,
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

    // MARK: - Mode 3: Interactive Paper Choice Flow (`合成`)

    private var mergeStageBody: some View {
        let report = comparisonReport
        let nextVerNumber = (siblings.map { $0.richMetadata?.versionStack?.versionNumber ?? 1 }.max() ?? 1) + 1

        return VStack(alignment: .leading, spacing: 0) {
            if let report, !report.canSynthesizeTwoWay {
                VStack(spacing: 14) {
                    Image(systemName: "lock.shield")
                        .font(.system(size: 32, weight: .regular))
                        .foregroundStyle(activeAccent)
                    Text("受保护文档结构（只读对比）")
                        .font(CharkleTheme.text(.headline, weight: .semibold))
                    Text(report.synthesisUnavailableReason ?? "Excel 公式工作簿与 PDF 签批件保持只读对比，避免破坏原格式；请在「对比」核查后用默认应用修改保存。")
                        .font(CharkleTheme.text(.body))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 500)

                    HStack(spacing: 10) {
                        Button("返回对比") {
                            studioMode = .diff
                        }
                        .buttonStyle(.charkle(.standard, size: .sm))

                        Button("使用默认应用打开") {
                            openAssetInDefaultApplication(assetID: report.targetAssetID)
                        }
                        .buttonStyle(.charkle(.accent, size: .sm))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(32)
            } else if let report {
                // Slim 38pt Merge Top Bar
                HStack(spacing: 10) {
                    Text("底稿")
                        .font(CharkleTheme.text(.caption))
                        .foregroundStyle(.secondary)

                    CharkleSegmentedControl(
                        selection: $preferTargetAsTemplate,
                        items: [
                            .init(true, title: "以新版为准"),
                            .init(false, title: "以旧版为准")
                        ],
                        size: .compact,
                        fullWidth: false
                    )

                    Spacer()

                    Text("\(changedHunksForMerge.count) 处差异")
                        .font(CharkleTheme.text(.caption))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 16)
                .frame(height: 38)
                .background(CharkleTheme.surfaceElevated(for: colorScheme))

                CharkleHairlineDivider()

                // Centered Continuous Paper Merge Sheet
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 0) {
                        if changedHunksForMerge.isEmpty {
                            Text("两版内容无差异，可直接生成或返回阅读")
                                .font(CharkleTheme.text(.body))
                                .foregroundStyle(.secondary)
                                .padding(.vertical, 24)
                        } else {
                            ForEach(Array(changedHunksForMerge.enumerated()), id: \.element.id) { idx, hunk in
                                paperMergeHunkSection(hunk, ordinal: idx + 1)

                                if idx < changedHunksForMerge.count - 1 {
                                    CharkleHairlineDivider()
                                        .padding(.vertical, 14)
                                }
                            }
                        }

                        CharkleDisclosureGroup(
                            isExpanded: $isMergePreviewExpanded,
                            showsTopDivider: true,
                            accentChevronWhenExpanded: true
                        ) {
                            let previewText = report.previewMergedText(
                                preferTargetAsTemplate: preferTargetAsTemplate,
                                decisions: Array(mergeDecisionsByHunkID.values)
                            )
                            Text(previewText.isEmpty ? "（合并预览为空）" : previewText)
                                .font(Self.paperProseFont)
                                .lineSpacing(5)
                                .textSelection(.enabled)
                                .padding(14)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(
                                    CharkleTheme.surfaceSubtle(for: colorScheme).opacity(0.65),
                                    in: RoundedRectangle(cornerRadius: CharkleTheme.Radius.chip, style: .continuous)
                                )
                                .padding(.top, 6)
                        } label: {
                            Text("合并预览")
                                .font(CharkleTheme.text(.caption, weight: .semibold))
                        }
                        .padding(.top, 16)
                    }
                    .padding(.horizontal, 36)
                    .padding(.vertical, 28)
                    .frame(maxWidth: 780, alignment: .leading)
                    .modifier(DocumentPaperSheetModifier(cornerRadius: Self.paperSheetCornerRadius))
                    .frame(maxWidth: .infinity)
                    .padding(24)
                }
                .charkleCleanScrollbars(hidden: false)

                CharkleHairlineDivider()

                // Clean 46pt Bottom Synthesis Footer
                HStack(spacing: 8) {
                    TextField("修改人", text: $mergeEditorDraft)
                        .textFieldStyle(.plain)
                        .font(CharkleTheme.text(.caption))
                        .padding(.horizontal, 9)
                        .frame(width: 96, height: 28)
                        .background(
                            CharkleTheme.surfaceSubtle(for: colorScheme),
                            in: RoundedRectangle(cornerRadius: CharkleTheme.Radius.chip, style: .continuous)
                        )

                    TextField("备注（可选）", text: $mergeNoteDraft)
                        .textFieldStyle(.plain)
                        .font(CharkleTheme.text(.caption))
                        .padding(.horizontal, 9)
                        .frame(maxWidth: 220, minHeight: 28, maxHeight: 28)
                        .background(
                            CharkleTheme.surfaceSubtle(for: colorScheme),
                            in: RoundedRectangle(cornerRadius: CharkleTheme.Radius.chip, style: .continuous)
                        )

                    Spacer()

                    Button {
                        performTwoWaySynthesis(report: report, nextVerNumber: nextVerNumber)
                    } label: {
                        HStack(spacing: 5) {
                            if isSynthesizing {
                                ProgressView().controlSize(.mini)
                            } else {
                                Image(systemName: "arrow.triangle.merge")
                                    .font(.system(size: 11, weight: .semibold))
                            }
                            Text("保存为新版本 v\(nextVerNumber)")
                                .monospacedDigit()
                        }
                    }
                    .buttonStyle(.charkle(.accent, size: .sm))
                    .disabled(isSynthesizing)
                }
                .padding(.horizontal, 16)
                .frame(height: 46)
                .background(CharkleTheme.surfaceElevated(for: colorScheme))
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func selectMergeChoice(for hunk: DocumentDiffHunk, choice: DocumentMergeDecision.Choice) {
        let existing = mergeDecisionsByHunkID[hunk.id]
        let seedCustom = existing?.customText ?? hunk.targetText ?? hunk.baseText ?? ""
        mergeDecisionsByHunkID[hunk.id] = DocumentMergeDecision(
            hunkID: hunk.id,
            choice: choice,
            customText: choice == .customText ? seedCustom : existing?.customText
        )
    }

    private func paperMergeHunkSection(_ hunk: DocumentDiffHunk, ordinal: Int) -> some View {
        let defaultChoice: DocumentMergeDecision.Choice = preferTargetAsTemplate ? .acceptTarget : .keepBase
        let currentDecision = mergeDecisionsByHunkID[hunk.id]
        let activeChoice = currentDecision?.choice ?? defaultChoice
        let posColor = CharkleTheme.positive(for: colorScheme)
        let negColor = CharkleTheme.destructive(for: colorScheme)
        let warnColor = CharkleTheme.warning(for: colorScheme)
        let sortedFlags = Array(hunk.riskFlags).sorted { $0.rawValue < $1.rawValue }

        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("#\(ordinal)")
                    .font(CharkleTheme.text(.caption, weight: .medium, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)

                if let sec = hunk.sectionTitle, !sec.isEmpty {
                    Text(sec)
                        .font(CharkleTheme.text(.caption, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                ForEach(sortedFlags, id: \.self) { flag in
                    Text(conciseRiskFlagLabel(flag))
                        .font(CharkleTheme.text(.caption, weight: .medium))
                        .foregroundStyle(warnColor)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(
                            warnColor.opacity(0.12),
                            in: RoundedRectangle(cornerRadius: CharkleTheme.Radius.xs, style: .continuous)
                        )
                }

                Spacer(minLength: 6)

                if hunk.isProtectedComplex {
                    HStack(spacing: 4) {
                        Image(systemName: "lock.shield")
                            .font(.system(size: 10.5, weight: .semibold))
                        Text("受保护结构")
                            .font(CharkleTheme.text(.caption, weight: .medium))
                    }
                    .foregroundStyle(warnColor)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2.5)
                    .background(warnColor.opacity(0.12), in: Capsule(style: .continuous))
                } else {
                    CharkleSegmentedControl(
                        selection: Binding(
                            get: { activeChoice },
                            set: { newChoice in
                                selectMergeChoice(for: hunk, choice: newChoice)
                            }
                        ),
                        items: [
                            .init(.keepBase, title: "保留 \(baseVersionBadgeLabel)"),
                            .init(.acceptTarget, title: "采纳 \(targetVersionBadgeLabel)"),
                            .init(.customText, title: "微调")
                        ],
                        size: .compact,
                        fullWidth: false
                    )
                }
            }

            if hunk.isProtectedComplex {
                Text(hunk.protectionReason ?? "涉及复杂跨行表格或嵌套域，已自动保留底稿原节点以确保格式完整。")
                    .font(CharkleTheme.text(.caption))
                    .foregroundStyle(.secondary)
            } else if activeChoice == .customText {
                TextField(
                    "微调合成后的段落文本…",
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
                .font(Self.paperProseFont)
                .padding(10)
                .background(
                    CharkleTheme.surfaceSubtle(for: colorScheme).opacity(0.65),
                    in: RoundedRectangle(cornerRadius: CharkleTheme.Radius.chip, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: CharkleTheme.Radius.chip, style: .continuous)
                        .strokeBorder(activeAccentBorder, lineWidth: 1)
                )
            } else {
                let isBaseChosen = activeChoice == .keepBase
                let isTargetChosen = activeChoice == .acceptTarget
                let hasBaseContent = hunk.baseText != nil || hunk.inlineTokens.contains(where: { $0.kind != .inserted })
                let hasTargetContent = hunk.targetText != nil || hunk.inlineTokens.contains(where: { $0.kind != .deleted })

                VStack(alignment: .leading, spacing: 6) {
                    if hasBaseContent || isBaseChosen {
                        mergeInteractiveVersionRow(
                            isSelected: isBaseChosen,
                            leadingSymbol: "minus.circle.fill",
                            leadingTint: negColor,
                            versionBadge: baseVersionBadgeLabel,
                            attributedText: hasBaseContent
                                ? Self.makeBaseDiffAttributedString(
                                    tokens: hunk.inlineTokens,
                                    fallbackText: hunk.baseText,
                                    textStyle: .body,
                                    isDark: colorScheme == .dark,
                                    negColor: negColor
                                )
                                : nil,
                            emptyPlaceholder: "（\(baseVersionBadgeLabel) 无此段落，选择该项将省略）"
                        ) {
                            selectMergeChoice(for: hunk, choice: .keepBase)
                        }
                    }

                    if hasTargetContent || isTargetChosen {
                        mergeInteractiveVersionRow(
                            isSelected: isTargetChosen,
                            leadingSymbol: "plus.circle.fill",
                            leadingTint: posColor,
                            versionBadge: targetVersionBadgeLabel,
                            attributedText: hasTargetContent
                                ? Self.makeTargetDiffAttributedString(
                                    tokens: hunk.inlineTokens,
                                    fallbackText: hunk.targetText,
                                    textStyle: .body,
                                    isDark: colorScheme == .dark,
                                    posColor: posColor
                                )
                                : nil,
                            emptyPlaceholder: "（\(targetVersionBadgeLabel) 已删除该段落，选择该项将移除）"
                        ) {
                            selectMergeChoice(for: hunk, choice: .acceptTarget)
                        }
                    }
                }
            }
        }
    }

    private func mergeInteractiveVersionRow(
        isSelected: Bool,
        leadingSymbol: String,
        leadingTint: Color,
        versionBadge: String,
        attributedText: AttributedString?,
        emptyPlaceholder: String,
        onSelect: @escaping () -> Void
    ) -> some View {
        let rowShape = RoundedRectangle(cornerRadius: CharkleTheme.Radius.chip, style: .continuous)

        return Button(action: onSelect) {
            HStack(alignment: .top, spacing: 8) {
                HStack(spacing: 4) {
                    Image(systemName: leadingSymbol)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(leadingTint)
                    Text(versionBadge)
                        .font(CharkleTheme.text(.caption, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                .fixedSize()
                .padding(.top, 2)

                if let attributedText {
                    Text(attributedText)
                        .font(Self.paperProseFont)
                        .lineSpacing(4.5)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text(emptyPlaceholder)
                        .font(CharkleTheme.text(.caption))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(activeAccent)
                    .opacity(isSelected ? 1.0 : 0.0)
                    .padding(.top, 2)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(isSelected ? activeAccentSoft : Color.clear, in: rowShape)
            .overlay(
                rowShape.strokeBorder(
                    isSelected ? activeAccentBorder : CharkleTheme.hairline(for: colorScheme),
                    lineWidth: isSelected ? 1.0 : CharkleTheme.hairlineWidth
                )
            )
            .opacity(isSelected ? 1.0 : 0.48)
            .contentShape(rowShape)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Data Loading, Hunk Stepping & Synthesis Actions

    private func bootstrapForAsset() async {
        isLoadingPayload = true
        let loaded = try? await library.readStructuredDocument(assetID: asset.id)
        guard !Task.isCancelled else { return }
        payload = loaded
        isLoadingPayload = false

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
            triggerComparisonReload()
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
                    "已生成 v\(nextVerNumber) 并设为主版本",
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

// MARK: - Paper Surface & Monochromatic Diff Control Helpers

private struct DocumentPaperSheetModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .background(CharkleTheme.surfaceElevated(for: colorScheme), in: shape)
            .overlay(
                shape.strokeBorder(
                    CharkleTheme.hairline(for: colorScheme),
                    lineWidth: CharkleTheme.hairlineWidth
                )
            )
            .shadow(
                color: .black.opacity(colorScheme == .dark ? 0.28 : 0.06),
                radius: 10,
                y: 3
            )
    }
}

private struct DiffRadarChipButton: View {
    @Environment(\.colorScheme) private var colorScheme

    let title: String
    let count: Int
    let isActive: Bool
    let action: () -> Void

    @State private var isHovered: Bool = false

    var body: some View {
        let pillShape = Capsule(style: .continuous)

        Button(action: action) {
            HStack(spacing: 4) {
                Text(title)
                    .font(CharkleTheme.text(.caption, weight: isActive ? .semibold : .medium))
                Text("\(count)")
                    .font(CharkleTheme.text(.caption, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(isActive ? .primary : .tertiary)
            }
            .foregroundStyle(
                isActive
                    ? Color.primary
                    : (isHovered ? Color.primary : CharkleTheme.secondaryInk(for: colorScheme))
            )
            .padding(.horizontal, 8.5)
            .frame(height: 24)
            .background(
                isActive
                    ? CharkleTheme.surfaceSubtle(for: colorScheme)
                    : (isHovered ? CharkleTheme.surfaceSubtle(for: colorScheme).opacity(0.65) : Color.clear),
                in: pillShape
            )
            .overlay {
                if isActive {
                    pillShape
                        .strokeBorder(
                            CharkleTheme.hairline(for: colorScheme),
                            lineWidth: CharkleTheme.hairlineWidth
                        )
                }
            }
            .contentShape(pillShape)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

private struct DiffTogglePillButton: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.charkleAccentSource) private var accentSource

    let title: String
    @Binding var isOn: Bool
    var onToggle: (() -> Void)? = nil

    @State private var isHovered: Bool = false

    var body: some View {
        let accent = CharkleTheme.accent(for: colorScheme, source: accentSource)
        let accentSoft = CharkleTheme.accentSoft(for: colorScheme, source: accentSource)

        Button {
            isOn.toggle()
            onToggle?()
        } label: {
            Text(title)
                .font(CharkleTheme.text(.caption, weight: isOn ? .semibold : .medium))
                .foregroundStyle(isOn ? accent : (isHovered ? Color.primary : CharkleTheme.secondaryInk(for: colorScheme)))
                .padding(.horizontal, 8.5)
                .frame(height: 24)
                .background(
                    isOn
                        ? accentSoft
                        : (isHovered ? CharkleTheme.surfaceSubtle(for: colorScheme) : Color.clear),
                    in: Capsule(style: .continuous)
                )
                .overlay(
                    Capsule(style: .continuous)
                        .strokeBorder(
                            isOn ? CharkleTheme.accentBorder(for: colorScheme, source: accentSource) : CharkleTheme.hairline(for: colorScheme),
                            lineWidth: CharkleTheme.hairlineWidth
                        )
                )
                .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
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
    let accentColor: Color
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
                Image(nsImage: targetImage)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: fittedSize.width, height: fittedSize.height)

                Image(nsImage: baseImage)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: fittedSize.width, height: fittedSize.height)
                    .mask(alignment: .leading) {
                        Rectangle()
                            .frame(width: splitX, height: fittedSize.height)
                    }

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
                        .background(accentColor.opacity(0.88), in: Capsule(style: .continuous))
                    }
                    .padding(10)
                    Spacer()
                }
                .frame(width: fittedSize.width, height: fittedSize.height)
                .allowsHitTesting(false)

                ZStack {
                    Rectangle()
                        .fill(accentColor)
                        .frame(width: 2, height: fittedSize.height)
                        .shadow(color: .black.opacity(0.28), radius: 2)

                    Circle()
                        .fill(Color.white)
                        .frame(width: 26, height: 26)
                        .shadow(color: .black.opacity(0.26), radius: 4, y: 1)
                        .overlay {
                            Image(systemName: "arrow.left.and.right")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(accentColor)
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
