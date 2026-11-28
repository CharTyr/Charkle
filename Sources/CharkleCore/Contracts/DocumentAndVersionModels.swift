import Foundation

// MARK: - Universal Version Stack Metadata (Wire-Synced via AssetRichMetadata)

public struct AssetVersionStackMetadata: Codable, Hashable, Sendable {
    public var groupID: UUID
    public var versionNumber: Int
    public var parentAssetID: UUID?
    public var versionLabel: String?
    public var editorName: String?
    public var changeNote: String?
    public var isPinnedPrimary: Bool

    public init(
        groupID: UUID,
        versionNumber: Int = 1,
        parentAssetID: UUID? = nil,
        versionLabel: String? = nil,
        editorName: String? = nil,
        changeNote: String? = nil,
        isPinnedPrimary: Bool = false
    ) {
        self.groupID = groupID
        self.versionNumber = max(1, versionNumber)
        self.parentAssetID = parentAssetID
        self.versionLabel = versionLabel
        self.editorName = editorName
        self.changeNote = changeNote
        self.isPinnedPrimary = isPinnedPrimary
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.groupID = try c.decode(UUID.self, forKey: .groupID)
        self.versionNumber = max(1, try c.decodeIfPresent(Int.self, forKey: .versionNumber) ?? 1)
        self.parentAssetID = try c.decodeIfPresent(UUID.self, forKey: .parentAssetID)
        self.versionLabel = try c.decodeIfPresent(String.self, forKey: .versionLabel)
        self.editorName = try c.decodeIfPresent(String.self, forKey: .editorName)
        self.changeNote = try c.decodeIfPresent(String.self, forKey: .changeNote)
        self.isPinnedPrimary = try c.decodeIfPresent(Bool.self, forKey: .isPinnedPrimary) ?? false
    }

    private static let leadingVersionPrefixRegex = try! NSRegularExpression(
        pattern: #"^(?:v|ver|version)\s*\d+(?:\.\d+)?(?![A-Za-z0-9])[\s·•:：\-—]*"#,
        options: [.caseInsensitive]
    )

    private static let pureVersionTokenRegex = try! NSRegularExpression(
        pattern: #"^(?:v|ver|version)\s*\d+(?:\.\d+)?$"#,
        options: [.caseInsensitive]
    )

    private static let ignoredBoilerplateDescriptors: Set<String> = [
        "本机", "初稿", "修订版", "挑拣合成" + "净版", "基于差异审阅合成"
    ]

    private static let descriptorTrimCharacters: CharacterSet =
        CharacterSet(charactersIn: "·•:：-—_ ").union(.whitespacesAndNewlines)

    /// Strips any redundant leading `v1`, `v2 · `, `v2: `, or repeated `v2 v2 · ` prefixes from a label or note
    /// so UI badges combining `v\(versionNumber)` with a label/note never render `"v1 v1"` or `"v2 v2 · Name"`.
    public static func strippingRedundantVersionPrefix(_ raw: String) -> String {
        var current = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        for _ in 0..<4 {
            guard !current.isEmpty else { break }
            let range = NSRange(current.startIndex..., in: current)
            guard let match = leadingVersionPrefixRegex.firstMatch(in: current, range: range),
                  let swiftRange = Range(match.range(at: 0), in: current) else {
                break
            }
            current = String(current[swiftRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return current
    }

    private static func unwrapOuterParentheses(_ text: String) -> String {
        let pairs: [(Character, Character)] = [("(", ")"), ("（", "）")]
        for (open, close) in pairs {
            guard text.count >= 2, text.first == open, text.last == close else { continue }
            var depth = 0
            var balancedToEnd = true
            for (idx, ch) in text.enumerated() {
                if ch == open {
                    depth += 1
                } else if ch == close {
                    depth -= 1
                    if depth == 0 && idx < text.count - 1 {
                        balancedToEnd = false
                        break
                    }
                }
            }
            if balancedToEnd && depth == 0 {
                return String(text.dropFirst().dropLast())
            }
        }
        return text
    }

    private static func sanitizeDescriptorCandidate(_ raw: String?) -> String? {
        guard let raw else { return nil }
        var current = raw.trimmingCharacters(in: descriptorTrimCharacters)
        for _ in 0..<4 {
            guard !current.isEmpty else { return nil }
            let next = unwrapOuterParentheses(strippingRedundantVersionPrefix(current))
                .trimmingCharacters(in: descriptorTrimCharacters)
            if next == current { break }
            current = next
        }
        guard !current.isEmpty else { return nil }
        if ignoredBoilerplateDescriptors.contains(current) { return nil }
        let fullRange = NSRange(current.startIndex..., in: current)
        if pureVersionTokenRegex.firstMatch(in: current, range: fullRange) != nil {
            return nil
        }
        return current
    }

    /// Resolves a single clean, non-boilerplate descriptor for timeline rows:
    /// strips redundant `vN` prefixes and outer parentheses, filters out default synthesis/device placeholders,
    /// and deduplicates against `editorName`.
    public static func cleanDisplayDescriptor(
        changeNote: String?,
        versionLabel: String?,
        editorName: String?
    ) -> String? {
        let cleanedEditor = sanitizeDescriptorCandidate(editorName)

        if let note = sanitizeDescriptorCandidate(changeNote) {
            if let ed = cleanedEditor, note.caseInsensitiveCompare(ed) == .orderedSame {
                // Skip pure repetition of editorName
            } else {
                return note
            }
        }

        if let label = sanitizeDescriptorCandidate(versionLabel) {
            if let ed = cleanedEditor {
                if label.caseInsensitiveCompare(ed) == .orderedSame {
                    return nil
                }
                if label.lowercased().hasPrefix(ed.lowercased()) {
                    let afterEditorIdx = label.index(label.startIndex, offsetBy: ed.count)
                    if afterEditorIdx < label.endIndex,
                       let firstScalar = label[afterEditorIdx].unicodeScalars.first,
                       descriptorTrimCharacters.union(CharacterSet(charactersIn: "()（）")).contains(firstScalar) {
                        let remainder = String(label[afterEditorIdx...])
                        if let stripped = sanitizeDescriptorCandidate(remainder),
                           stripped.caseInsensitiveCompare(ed) != .orderedSame {
                            return stripped
                        }
                        return nil
                    }
                }
            }
            return label
        }

        return nil
    }

    public var displayVersionTag: String {
        "v\(max(1, versionNumber))"
    }

    public var displayBadgeText: String {
        if let label = versionLabel?.trimmingCharacters(in: .whitespacesAndNewlines), !label.isEmpty {
            let cleaned = Self.strippingRedundantVersionPrefix(label)
            return cleaned.isEmpty ? displayVersionTag : "\(displayVersionTag) · \(cleaned)"
        }
        if let editor = editorName?.trimmingCharacters(in: .whitespacesAndNewlines), !editor.isEmpty {
            let cleaned = Self.strippingRedundantVersionPrefix(editor)
            return cleaned.isEmpty ? displayVersionTag : "\(displayVersionTag) · \(cleaned)"
        }
        return displayVersionTag
    }

    /// Orders stack siblings ascending by `(versionNumber, createdAt, id)`.
    public static func sortedVersions(_ siblings: [AssetRecord]) -> [AssetRecord] {
        siblings.sorted { lhs, rhs in
            let lv = lhs.richMetadata?.versionStack?.versionNumber ?? 1
            let rv = rhs.richMetadata?.versionStack?.versionNumber ?? 1
            if lv != rv { return lv < rv }
            if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }

    /// Resolves the canonical Primary Version for display, drag-out, and clipboard copy:
    /// prefers an explicitly pinned `isPinnedPrimary` version; otherwise falls back to the highest `versionNumber`.
    public static func resolvePrimaryAsset(in siblings: [AssetRecord]) -> AssetRecord? {
        guard !siblings.isEmpty else { return nil }
        let ordered = sortedVersions(siblings)
        if let pinned = ordered.last(where: { $0.richMetadata?.versionStack?.isPinnedPrimary == true }) {
            return pinned
        }
        return ordered.last
    }

    /// Number of newer versions stacked above the currently pinned Primary Version (`+N 新版` indicator).
    public static func newerThanPrimaryCount(in siblings: [AssetRecord]) -> Int {
        guard let primary = resolvePrimaryAsset(in: siblings),
              let primaryVer = primary.richMetadata?.versionStack?.versionNumber else {
            return 0
        }
        return siblings.filter {
            ($0.richMetadata?.versionStack?.versionNumber ?? 0) > primaryVer
        }.count
    }
}

// MARK: - Document Metadata & Diff Summary (Wire-Synced via AssetRichMetadata)

public enum DocumentFormatFamily: String, Codable, CaseIterable, Hashable, Sendable {
    case docx
    case xlsx
    case pptx
    case pdf
    case markdown
    case plainText
    case legacyOffice
    case epub
    case ofd
    case other

    public var badgeLabel: String {
        switch self {
        case .docx: "DOCX"
        case .xlsx: "XLSX"
        case .pptx: "PPTX"
        case .pdf: "PDF"
        case .markdown: "MD"
        case .plainText: "TXT"
        case .legacyOffice: "DOC"
        case .epub: "EPUB"
        case .ofd: "OFD"
        case .other: "DOC"
        }
    }

    public static func detect(fileExtension ext: String) -> DocumentFormatFamily {
        switch ext.lowercased() {
        case "docx", "odt": return .docx
        case "xlsx", "ods", "csv": return .xlsx
        case "pptx", "ppt", "odp", "dps", "key": return .pptx
        case "pdf": return .pdf
        case "md", "markdown": return .markdown
        case "txt", "json", "yaml", "yml", "toml", "rtf": return .plainText
        case "doc", "wps", "xls", "et", "pages", "numbers": return .legacyOffice
        case "epub": return .epub
        case "ofd": return .ofd
        default: return .other
        }
    }
}

public struct DocumentDiffSummary: Codable, Hashable, Sendable {
    public static let bucketCount = 12

    public var comparedToAssetID: UUID
    public var addedBlocks: Int
    public var removedBlocks: Int
    public var modifiedBlocks: Int
    public var movedBlocks: Int
    public var highRiskNumberChanges: Int
    public var highRiskDateChanges: Int
    /// 12-segment document minimap buckets (`0` = unchanged, `1` = normal add/mod/move, `2` = high-risk number/date change).
    public var minimapBuckets: [Int]

    public init(
        comparedToAssetID: UUID,
        addedBlocks: Int = 0,
        removedBlocks: Int = 0,
        modifiedBlocks: Int = 0,
        movedBlocks: Int = 0,
        highRiskNumberChanges: Int = 0,
        highRiskDateChanges: Int = 0,
        minimapBuckets: [Int] = Array(repeating: 0, count: DocumentDiffSummary.bucketCount)
    ) {
        self.comparedToAssetID = comparedToAssetID
        self.addedBlocks = max(0, addedBlocks)
        self.removedBlocks = max(0, removedBlocks)
        self.modifiedBlocks = max(0, modifiedBlocks)
        self.movedBlocks = max(0, movedBlocks)
        self.highRiskNumberChanges = max(0, highRiskNumberChanges)
        self.highRiskDateChanges = max(0, highRiskDateChanges)
        self.minimapBuckets = Self.normalizeBuckets(minimapBuckets)
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.comparedToAssetID = try c.decode(UUID.self, forKey: .comparedToAssetID)
        self.addedBlocks = max(0, try c.decodeIfPresent(Int.self, forKey: .addedBlocks) ?? 0)
        self.removedBlocks = max(0, try c.decodeIfPresent(Int.self, forKey: .removedBlocks) ?? 0)
        self.modifiedBlocks = max(0, try c.decodeIfPresent(Int.self, forKey: .modifiedBlocks) ?? 0)
        self.movedBlocks = max(0, try c.decodeIfPresent(Int.self, forKey: .movedBlocks) ?? 0)
        self.highRiskNumberChanges = max(0, try c.decodeIfPresent(Int.self, forKey: .highRiskNumberChanges) ?? 0)
        self.highRiskDateChanges = max(0, try c.decodeIfPresent(Int.self, forKey: .highRiskDateChanges) ?? 0)
        let rawBuckets = try c.decodeIfPresent([Int].self, forKey: .minimapBuckets) ?? []
        self.minimapBuckets = Self.normalizeBuckets(rawBuckets)
    }

    public static func normalizeBuckets(_ raw: [Int]) -> [Int] {
        if raw.isEmpty {
            return Array(repeating: 0, count: bucketCount)
        }
        if raw.count == bucketCount {
            return raw.map { min(2, max(0, $0)) }
        }
        var out = Array(repeating: 0, count: bucketCount)
        for (idx, val) in raw.enumerated() {
            let clamped = min(2, max(0, val))
            let bucket = min(bucketCount - 1, (idx * bucketCount) / max(1, raw.count))
            out[bucket] = max(out[bucket], clamped)
        }
        return out
    }

    public var totalChangedBlocks: Int {
        addedBlocks + removedBlocks + modifiedBlocks + movedBlocks
    }

    public var totalHighRiskChanges: Int {
        highRiskNumberChanges + highRiskDateChanges
    }

    public var compactBridgeLabel: String {
        var parts = ["Δ \(totalChangedBlocks)处"]
        if highRiskNumberChanges > 0 {
            parts.append("数字\(highRiskNumberChanges)")
        }
        if highRiskDateChanges > 0 {
            parts.append("时间\(highRiskDateChanges)")
        }
        return parts.joined(separator: " · ")
    }
}

public struct DocumentRichMetadata: Codable, Hashable, Sendable {
    public var formatFamily: String
    public var wordCount: Int
    public var pageCount: Int
    public var sheetNames: [String]
    public var hasNativeRevisions: Bool
    public var hasTextLayer: Bool
    public var diffSummary: DocumentDiffSummary?

    public init(
        formatFamily: String,
        wordCount: Int = 0,
        pageCount: Int = 1,
        sheetNames: [String] = [],
        hasNativeRevisions: Bool = false,
        hasTextLayer: Bool = true,
        diffSummary: DocumentDiffSummary? = nil
    ) {
        self.formatFamily = formatFamily
        self.wordCount = max(0, wordCount)
        self.pageCount = max(0, pageCount)
        self.sheetNames = sheetNames
        self.hasNativeRevisions = hasNativeRevisions
        self.hasTextLayer = hasTextLayer
        self.diffSummary = diffSummary
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.formatFamily = try c.decodeIfPresent(String.self, forKey: .formatFamily) ?? DocumentFormatFamily.other.rawValue
        self.wordCount = max(0, try c.decodeIfPresent(Int.self, forKey: .wordCount) ?? 0)
        self.pageCount = max(0, try c.decodeIfPresent(Int.self, forKey: .pageCount) ?? 0)
        self.sheetNames = try c.decodeIfPresent([String].self, forKey: .sheetNames) ?? []
        self.hasNativeRevisions = try c.decodeIfPresent(Bool.self, forKey: .hasNativeRevisions) ?? false
        self.hasTextLayer = try c.decodeIfPresent(Bool.self, forKey: .hasTextLayer) ?? true
        self.diffSummary = try c.decodeIfPresent(DocumentDiffSummary.self, forKey: .diffSummary)
    }

    public var parsedFormatFamily: DocumentFormatFamily {
        DocumentFormatFamily(rawValue: formatFamily) ?? .other
    }
}

// MARK: - Structured Document Inspection Payload (Quick Look Reader)

public enum DocumentBlockKind: String, Codable, CaseIterable, Hashable, Sendable {
    case heading
    case paragraph
    case listItem
    case table
    case codeBlock
    case quote
    case slide
    case pageBreak
}

public struct DocumentTrackRevisionSpan: Codable, Hashable, Sendable, Identifiable {
    public enum Kind: String, Codable, Hashable, Sendable {
        case inserted
        case deleted
    }

    public let id: String
    public var kind: Kind
    public var text: String
    public var author: String?
    public var dateText: String?

    public init(
        id: String = UUID().uuidString,
        kind: Kind,
        text: String,
        author: String? = nil,
        dateText: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.text = text
        self.author = author
        self.dateText = dateText
    }
}

public struct DocumentBlock: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public var index: Int
    public var kind: DocumentBlockKind
    public var headingLevel: Int?
    public var sectionTitle: String?
    public var text: String
    public var tableRows: [[String]]
    public var pageNumber: Int?
    public var nativeRevisions: [DocumentTrackRevisionSpan]
    public var commentIDs: [String]
    public var isProtectedComplex: Bool
    public var protectionReason: String?
    public var xmlParagraphIndex: Int?

    public init(
        id: String,
        index: Int,
        kind: DocumentBlockKind = .paragraph,
        headingLevel: Int? = nil,
        sectionTitle: String? = nil,
        text: String,
        tableRows: [[String]] = [],
        pageNumber: Int? = nil,
        nativeRevisions: [DocumentTrackRevisionSpan] = [],
        commentIDs: [String] = [],
        isProtectedComplex: Bool = false,
        protectionReason: String? = nil,
        xmlParagraphIndex: Int? = nil
    ) {
        self.id = id
        self.index = index
        self.kind = kind
        self.headingLevel = headingLevel
        self.sectionTitle = sectionTitle
        self.text = text
        self.tableRows = tableRows
        self.pageNumber = pageNumber
        self.nativeRevisions = nativeRevisions
        self.commentIDs = commentIDs
        self.isProtectedComplex = isProtectedComplex
        self.protectionReason = protectionReason
        self.xmlParagraphIndex = xmlParagraphIndex
    }
}

public struct SpreadsheetRow: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public var rowNumber: Int
    public var values: [String]
    public var formulasByCol: [Int: String]

    public init(
        id: String? = nil,
        rowNumber: Int,
        values: [String],
        formulasByCol: [Int: String] = [:]
    ) {
        self.id = id ?? "row-\(rowNumber)"
        self.rowNumber = rowNumber
        self.values = values
        self.formulasByCol = formulasByCol
    }

    public func formula(at col: Int) -> String? {
        formulasByCol[col]
    }
}

public struct SpreadsheetSheet: Codable, Hashable, Sendable, Identifiable {
    public var id: String { "\(sheetIndex)-\(name)" }
    public var name: String
    public var sheetIndex: Int
    public var headers: [String]
    public var rows: [SpreadsheetRow]
    public var columnCount: Int
    public var suggestedPrimaryKeyCol: Int?

    public init(
        name: String,
        sheetIndex: Int = 0,
        headers: [String] = [],
        rows: [SpreadsheetRow] = [],
        columnCount: Int? = nil,
        suggestedPrimaryKeyCol: Int? = nil
    ) {
        self.name = name
        self.sheetIndex = sheetIndex
        self.headers = headers
        self.rows = rows
        self.columnCount = columnCount ?? max(headers.count, rows.map(\.values.count).max() ?? 0)
        self.suggestedPrimaryKeyCol = suggestedPrimaryKeyCol
    }
}

public struct DocumentComment: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public var author: String
    public var dateText: String?
    public var text: String
    public var anchorBlockIndex: Int?
    public var anchorExcerpt: String?

    public init(
        id: String,
        author: String,
        dateText: String? = nil,
        text: String,
        anchorBlockIndex: Int? = nil,
        anchorExcerpt: String? = nil
    ) {
        self.id = id
        self.author = author
        self.dateText = dateText
        self.text = text
        self.anchorBlockIndex = anchorBlockIndex
        self.anchorExcerpt = anchorExcerpt
    }
}

public struct StructuredDocumentPayload: Codable, Hashable, Sendable {
    public var assetID: UUID
    public var formatFamily: String
    public var title: String
    public var authorOrEditor: String?
    public var wordCount: Int
    public var pageCount: Int
    public var hasTextLayer: Bool
    public var hasNativeRevisions: Bool
    public var isRedHeaderStyle: Bool
    public var blocks: [DocumentBlock]
    public var sheets: [SpreadsheetSheet]
    public var comments: [DocumentComment]
    public var plainText: String

    public init(
        assetID: UUID,
        formatFamily: String,
        title: String,
        authorOrEditor: String? = nil,
        wordCount: Int = 0,
        pageCount: Int = 1,
        hasTextLayer: Bool = true,
        hasNativeRevisions: Bool = false,
        isRedHeaderStyle: Bool = false,
        blocks: [DocumentBlock] = [],
        sheets: [SpreadsheetSheet] = [],
        comments: [DocumentComment] = [],
        plainText: String = ""
    ) {
        self.assetID = assetID
        self.formatFamily = formatFamily
        self.title = title
        self.authorOrEditor = authorOrEditor
        self.wordCount = wordCount
        self.pageCount = pageCount
        self.hasTextLayer = hasTextLayer
        self.hasNativeRevisions = hasNativeRevisions
        self.isRedHeaderStyle = isRedHeaderStyle
        self.blocks = blocks
        self.sheets = sheets
        self.comments = comments
        self.plainText = plainText
    }
}

// MARK: - Version Stack Detection & Mutation Contracts

public struct VersionStackCandidate: Codable, Hashable, Sendable, Identifiable {
    public enum MatchReason: String, Codable, Hashable, Sendable {
        case exactStem
        case contentSimHash
        case stemAndSimHash

        public var localizedLabel: String {
            switch self {
            case .exactStem: "文件名同源匹配"
            case .contentSimHash: "正文段落同源匹配"
            case .stemAndSimHash: "标题与正文双重匹配"
            }
        }
    }

    public var id: UUID { targetGroupID }
    public var targetGroupID: UUID
    public var targetAssetID: UUID
    public var targetTitle: String
    public var targetFolderID: UUID?
    public var nextVersionNumber: Int
    public var suggestedEditorName: String?
    public var suggestedVersionLabel: String?
    public var normalizedStem: String
    public var similarityScore: Double
    public var matchReason: MatchReason
    public var existingStackExists: Bool

    public init(
        targetGroupID: UUID,
        targetAssetID: UUID,
        targetTitle: String,
        targetFolderID: UUID? = nil,
        nextVersionNumber: Int,
        suggestedEditorName: String? = nil,
        suggestedVersionLabel: String? = nil,
        normalizedStem: String = "",
        similarityScore: Double = 1.0,
        matchReason: MatchReason = .exactStem,
        existingStackExists: Bool = false
    ) {
        self.targetGroupID = targetGroupID
        self.targetAssetID = targetAssetID
        self.targetTitle = targetTitle
        self.targetFolderID = targetFolderID
        self.nextVersionNumber = max(2, nextVersionNumber)
        self.suggestedEditorName = suggestedEditorName
        self.suggestedVersionLabel = suggestedVersionLabel
        self.normalizedStem = normalizedStem
        self.similarityScore = similarityScore
        self.matchReason = matchReason
        self.existingStackExists = existingStackExists
    }
}

public struct VersionStackMutation: Codable, Hashable, Sendable {
    public enum Action: String, Codable, CaseIterable, Hashable, Sendable {
        case join
        case create
        case setPrimary
        case unstack
        case updateMeta
    }

    public var action: Action
    public var assetIDs: [UUID]
    public var targetAssetOrGroupID: UUID?
    public var primaryAssetID: UUID?
    public var editorName: String?
    public var changeNote: String?
    public var versionLabel: String?
    public var pinAsPrimary: Bool
    public var adoptTargetFolder: Bool

    public init(
        action: Action,
        assetIDs: [UUID],
        targetAssetOrGroupID: UUID? = nil,
        primaryAssetID: UUID? = nil,
        editorName: String? = nil,
        changeNote: String? = nil,
        versionLabel: String? = nil,
        pinAsPrimary: Bool = false,
        adoptTargetFolder: Bool = true
    ) {
        self.action = action
        self.assetIDs = assetIDs
        self.targetAssetOrGroupID = targetAssetOrGroupID
        self.primaryAssetID = primaryAssetID
        self.editorName = editorName
        self.changeNote = changeNote
        self.versionLabel = versionLabel
        self.pinAsPrimary = pinAsPrimary
        self.adoptTargetFolder = adoptTargetFolder
    }

    public static func join(
        assetID: UUID,
        targetAssetOrGroupID: UUID,
        editorName: String? = nil,
        changeNote: String? = nil,
        versionLabel: String? = nil,
        pinAsPrimary: Bool = false,
        adoptTargetFolder: Bool = true
    ) -> VersionStackMutation {
        VersionStackMutation(
            action: .join,
            assetIDs: [assetID],
            targetAssetOrGroupID: targetAssetOrGroupID,
            editorName: editorName,
            changeNote: changeNote,
            versionLabel: versionLabel,
            pinAsPrimary: pinAsPrimary,
            adoptTargetFolder: adoptTargetFolder
        )
    }

    public static func create(
        assetIDs: [UUID],
        primaryAssetID: UUID? = nil,
        editorName: String? = nil,
        changeNote: String? = nil
    ) -> VersionStackMutation {
        VersionStackMutation(
            action: .create,
            assetIDs: assetIDs,
            primaryAssetID: primaryAssetID,
            editorName: editorName,
            changeNote: changeNote
        )
    }

    public static func setPrimary(assetID: UUID) -> VersionStackMutation {
        VersionStackMutation(action: .setPrimary, assetIDs: [assetID], primaryAssetID: assetID, pinAsPrimary: true)
    }

    public static func unstack(assetID: UUID) -> VersionStackMutation {
        VersionStackMutation(action: .unstack, assetIDs: [assetID])
    }

    public static func updateMeta(
        assetID: UUID,
        versionLabel: String? = nil,
        editorName: String? = nil,
        changeNote: String? = nil
    ) -> VersionStackMutation {
        VersionStackMutation(
            action: .updateMeta,
            assetIDs: [assetID],
            editorName: editorName,
            changeNote: changeNote,
            versionLabel: versionLabel
        )
    }
}

// MARK: - Multi-Modal Diff & Scheme B 2-Way Synthesis Contracts

public enum DocumentDiffRiskFlag: String, Codable, CaseIterable, Hashable, Sendable {
    case numberOrCurrency
    case dateOrDeadline
    case tableMutation
    case nativeRevisionOrComment

    public var localizedLabel: String {
        switch self {
        case .numberOrCurrency: "数字变动"
        case .dateOrDeadline: "日期时间"
        case .tableMutation: "表格变动"
        case .nativeRevisionOrComment: "原生修订/批注"
        }
    }
}

public enum DocumentDiffChangeKind: String, Codable, CaseIterable, Hashable, Sendable {
    case unchanged
    case added
    case removed
    case modified
    case moved

    public var isChanged: Bool {
        self != .unchanged
    }

    public var localizedLabel: String {
        switch self {
        case .unchanged: "未改动"
        case .added: "新增"
        case .removed: "删除"
        case .modified: "修改"
        case .moved: "段落移动"
        }
    }
}

public struct DocumentInlineDiffToken: Codable, Hashable, Sendable, Identifiable {
    public enum Kind: String, Codable, Hashable, Sendable {
        case equal
        case inserted
        case deleted
    }

    public let id: String
    public var kind: Kind
    public var text: String
    public var isHighRiskNumber: Bool
    public var isHighRiskDate: Bool

    public init(
        id: String,
        kind: Kind,
        text: String,
        isHighRiskNumber: Bool = false,
        isHighRiskDate: Bool = false
    ) {
        self.id = id
        self.kind = kind
        self.text = text
        self.isHighRiskNumber = isHighRiskNumber
        self.isHighRiskDate = isHighRiskDate
    }
}

public struct DocumentHighRiskValuePair: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public var flag: DocumentDiffRiskFlag
    public var oldValue: String?
    public var newValue: String?

    public init(
        id: String,
        flag: DocumentDiffRiskFlag,
        oldValue: String? = nil,
        newValue: String? = nil
    ) {
        self.id = id
        self.flag = flag
        self.oldValue = oldValue
        self.newValue = newValue
    }
}

public struct DocumentTableCellDiff: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public var rowIndex: Int
    public var colIndex: Int
    public var rowKey: String?
    public var columnHeader: String?
    public var changeKind: DocumentDiffChangeKind
    public var oldValue: String?
    public var newValue: String?
    public var oldFormula: String?
    public var newFormula: String?
    public var riskFlags: Set<DocumentDiffRiskFlag>

    public init(
        id: String? = nil,
        rowIndex: Int,
        colIndex: Int,
        rowKey: String? = nil,
        columnHeader: String? = nil,
        changeKind: DocumentDiffChangeKind,
        oldValue: String? = nil,
        newValue: String? = nil,
        oldFormula: String? = nil,
        newFormula: String? = nil,
        riskFlags: Set<DocumentDiffRiskFlag> = []
    ) {
        self.id = id ?? "cell-\(rowIndex)-\(colIndex)"
        self.rowIndex = rowIndex
        self.colIndex = colIndex
        self.rowKey = rowKey
        self.columnHeader = columnHeader
        self.changeKind = changeKind
        self.oldValue = oldValue
        self.newValue = newValue
        self.oldFormula = oldFormula
        self.newFormula = newFormula
        self.riskFlags = riskFlags
    }
}

public struct DocumentDiffHunk: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public var hunkIndex: Int
    public var changeKind: DocumentDiffChangeKind
    public var blockKind: DocumentBlockKind
    public var sectionTitle: String?
    public var baseBlockIndex: Int?
    public var targetBlockIndex: Int?
    public var movedFromIndex: Int?
    public var movedToIndex: Int?
    public var pageNumber: Int?
    public var baseText: String?
    public var targetText: String?
    public var baseTableRows: [[String]]
    public var targetTableRows: [[String]]
    public var inlineTokens: [DocumentInlineDiffToken]
    public var tableCellDiffs: [DocumentTableCellDiff]
    public var highRiskPairs: [DocumentHighRiskValuePair]
    public var riskFlags: Set<DocumentDiffRiskFlag>
    public var isProtectedComplex: Bool
    public var protectionReason: String?
    public var baseXMLParagraphIndex: Int?
    public var targetXMLParagraphIndex: Int?

    public init(
        id: String,
        hunkIndex: Int,
        changeKind: DocumentDiffChangeKind,
        blockKind: DocumentBlockKind = .paragraph,
        sectionTitle: String? = nil,
        baseBlockIndex: Int? = nil,
        targetBlockIndex: Int? = nil,
        movedFromIndex: Int? = nil,
        movedToIndex: Int? = nil,
        pageNumber: Int? = nil,
        baseText: String? = nil,
        targetText: String? = nil,
        baseTableRows: [[String]] = [],
        targetTableRows: [[String]] = [],
        inlineTokens: [DocumentInlineDiffToken] = [],
        tableCellDiffs: [DocumentTableCellDiff] = [],
        highRiskPairs: [DocumentHighRiskValuePair] = [],
        riskFlags: Set<DocumentDiffRiskFlag> = [],
        isProtectedComplex: Bool = false,
        protectionReason: String? = nil,
        baseXMLParagraphIndex: Int? = nil,
        targetXMLParagraphIndex: Int? = nil
    ) {
        self.id = id
        self.hunkIndex = hunkIndex
        self.changeKind = changeKind
        self.blockKind = blockKind
        self.sectionTitle = sectionTitle
        self.baseBlockIndex = baseBlockIndex
        self.targetBlockIndex = targetBlockIndex
        self.movedFromIndex = movedFromIndex
        self.movedToIndex = movedToIndex
        self.pageNumber = pageNumber
        self.baseText = baseText
        self.targetText = targetText
        self.baseTableRows = baseTableRows
        self.targetTableRows = targetTableRows
        self.inlineTokens = inlineTokens
        self.tableCellDiffs = tableCellDiffs
        self.highRiskPairs = highRiskPairs
        self.riskFlags = riskFlags
        self.isProtectedComplex = isProtectedComplex
        self.protectionReason = protectionReason
        self.baseXMLParagraphIndex = baseXMLParagraphIndex
        self.targetXMLParagraphIndex = targetXMLParagraphIndex
    }
}

public struct SpreadsheetRowDiff: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public var changeKind: DocumentDiffChangeKind
    public var primaryKeyValue: String
    public var baseRowNumber: Int?
    public var targetRowNumber: Int?
    public var baseValues: [String]
    public var targetValues: [String]
    public var cellDiffs: [DocumentTableCellDiff]
    public var riskFlags: Set<DocumentDiffRiskFlag>

    public init(
        id: String,
        changeKind: DocumentDiffChangeKind,
        primaryKeyValue: String,
        baseRowNumber: Int? = nil,
        targetRowNumber: Int? = nil,
        baseValues: [String] = [],
        targetValues: [String] = [],
        cellDiffs: [DocumentTableCellDiff] = [],
        riskFlags: Set<DocumentDiffRiskFlag> = []
    ) {
        self.id = id
        self.changeKind = changeKind
        self.primaryKeyValue = primaryKeyValue
        self.baseRowNumber = baseRowNumber
        self.targetRowNumber = targetRowNumber
        self.baseValues = baseValues
        self.targetValues = targetValues
        self.cellDiffs = cellDiffs
        self.riskFlags = riskFlags
    }
}

public struct SpreadsheetSheetDiff: Codable, Hashable, Sendable, Identifiable {
    public var id: String { sheetName }
    public var sheetName: String
    public var changeKind: DocumentDiffChangeKind
    public var headers: [String]
    public var primaryKeyCol: Int?
    public var primaryKeyHeader: String?
    public var candidatePrimaryKeyCols: [Int]
    public var addedRowCount: Int
    public var removedRowCount: Int
    public var modifiedRowCount: Int
    public var highRiskCellCount: Int
    public var rowDiffs: [SpreadsheetRowDiff]

    public init(
        sheetName: String,
        changeKind: DocumentDiffChangeKind,
        headers: [String] = [],
        primaryKeyCol: Int? = nil,
        primaryKeyHeader: String? = nil,
        candidatePrimaryKeyCols: [Int] = [],
        addedRowCount: Int = 0,
        removedRowCount: Int = 0,
        modifiedRowCount: Int = 0,
        highRiskCellCount: Int = 0,
        rowDiffs: [SpreadsheetRowDiff] = []
    ) {
        self.sheetName = sheetName
        self.changeKind = changeKind
        self.headers = headers
        self.primaryKeyCol = primaryKeyCol
        self.primaryKeyHeader = primaryKeyHeader
        self.candidatePrimaryKeyCols = candidatePrimaryKeyCols
        self.addedRowCount = addedRowCount
        self.removedRowCount = removedRowCount
        self.modifiedRowCount = modifiedRowCount
        self.highRiskCellCount = highRiskCellCount
        self.rowDiffs = rowDiffs
    }
}

public struct DocumentCommentDiff: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public var changeKind: DocumentDiffChangeKind
    public var comment: DocumentComment

    public init(id: String? = nil, changeKind: DocumentDiffChangeKind, comment: DocumentComment) {
        self.id = id ?? "\(changeKind.rawValue)-\(comment.id)"
        self.changeKind = changeKind
        self.comment = comment
    }
}

public struct DocumentMergeDecision: Codable, Hashable, Sendable, Identifiable {
    public enum Choice: String, Codable, CaseIterable, Hashable, Sendable {
        case keepBase
        case acceptTarget
        case customText

        public var localizedLabel: String {
            switch self {
            case .keepBase: "保留旧版"
            case .acceptTarget: "采用新版"
            case .customText: "当场微调"
            }
        }
    }

    public var id: String { hunkID }
    public var hunkID: String
    public var choice: Choice
    public var customText: String?

    public init(hunkID: String, choice: Choice, customText: String? = nil) {
        self.hunkID = hunkID
        self.choice = choice
        self.customText = customText
    }
}

public struct DocumentComparisonReport: Codable, Hashable, Sendable {
    public var baseAssetID: UUID
    public var targetAssetID: UUID
    public var baseTitle: String
    public var targetTitle: String
    public var formatFamily: String
    public var summary: DocumentDiffSummary
    public var hunks: [DocumentDiffHunk]
    public var sheetDiffs: [SpreadsheetSheetDiff]
    public var commentDiffs: [DocumentCommentDiff]
    public var usedOCR: Bool
    public var supportsVisualPageOverlay: Bool
    public var canSynthesizeTwoWay: Bool
    public var synthesisUnavailableReason: String?

    public init(
        baseAssetID: UUID,
        targetAssetID: UUID,
        baseTitle: String = "",
        targetTitle: String = "",
        formatFamily: String,
        summary: DocumentDiffSummary,
        hunks: [DocumentDiffHunk] = [],
        sheetDiffs: [SpreadsheetSheetDiff] = [],
        commentDiffs: [DocumentCommentDiff] = [],
        usedOCR: Bool = false,
        supportsVisualPageOverlay: Bool = false,
        canSynthesizeTwoWay: Bool = false,
        synthesisUnavailableReason: String? = nil
    ) {
        self.baseAssetID = baseAssetID
        self.targetAssetID = targetAssetID
        self.baseTitle = baseTitle
        self.targetTitle = targetTitle
        self.formatFamily = formatFamily
        self.summary = summary
        self.hunks = hunks
        self.sheetDiffs = sheetDiffs
        self.commentDiffs = commentDiffs
        self.usedOCR = usedOCR
        self.supportsVisualPageOverlay = supportsVisualPageOverlay
        self.canSynthesizeTwoWay = canSynthesizeTwoWay
        self.synthesisUnavailableReason = synthesisUnavailableReason
    }

    /// Generates an instant clean preview string for Scheme B 2-Way merge decisions.
    public func previewMergedText(
        preferTargetAsTemplate: Bool = true,
        decisions: [DocumentMergeDecision]
    ) -> String {
        let byHunk = Dictionary(uniqueKeysWithValues: decisions.map { ($0.hunkID, $0) })
        let defaultChoice: DocumentMergeDecision.Choice = preferTargetAsTemplate ? .acceptTarget : .keepBase
        var lines: [String] = []
        for hunk in hunks {
            if hunk.isProtectedComplex {
                let fallback = preferTargetAsTemplate ? (hunk.targetText ?? hunk.baseText) : (hunk.baseText ?? hunk.targetText)
                if let fallback { lines.append(fallback) }
                continue
            }
            let decision = byHunk[hunk.id]
            let choice = decision?.choice ?? defaultChoice
            switch choice {
            case .keepBase:
                if let baseText = hunk.baseText {
                    lines.append(baseText)
                }
            case .acceptTarget:
                if let targetText = hunk.targetText {
                    lines.append(targetText)
                }
            case .customText:
                if let custom = decision?.customText {
                    lines.append(custom)
                }
            }
        }
        return lines.joined(separator: "\n\n")
    }
}
