import Foundation

// MARK: - 1. Chinese Office Filename Stem Normalizer

public nonisolated struct NormalizedVersionStem: Hashable, Sendable {
    public let canonicalStem: String
    public let cleanDisplayTitle: String
    public let suggestedEditorName: String?
    public let explicitVersionHint: Int?
}

/// Deterministic filename normalizer tailored for Chinese & bilingual office / WeChat workflows:
/// strips `(1)`, `（2）`, `副本`, `_v2`, `初稿/修改稿/终稿/最终版/定稿`, leading/trailing dates,
/// and extracts editor suffix hints such as `-张主任改`, `（李科长核定）`, or `_王敏修改版`.
public nonisolated enum VersionStemNormalizer {
    private static let bracketDupRegex = try! NSRegularExpression(
        pattern: #"[\s_-]*(?:\(\d{1,3}\)|（\d{1,3}）|\[\d{1,3}\]|【\d{1,3}】)\s*$"#
    )
    private static let copySuffixRegex = try! NSRegularExpression(
        pattern: #"(?:[\s_-]*(?:的?副本\s*\d*|copy(?:\s*\d+)?|\bduplicate\b))\s*$"#,
        options: [.caseInsensitive]
    )
    private static let copyPrefixRegex = try! NSRegularExpression(
        pattern: #"^(?:copy\s+of\s+|副本[\s_-]*)"#,
        options: [.caseInsensitive]
    )
    private static let explicitVersionRegex = try! NSRegularExpression(
        pattern: #"(?:[\s_.\-—·（(\[【]*(?:v|ver|version)\s*(\d{1,3})(?:\.\d+)?[）)\]】]?|[\s_.\-—·（(\[【]*第\s*(\d{1,3})\s*[版稿次][）)\]】]?)\s*$"#,
        options: [.caseInsensitive]
    )
    private static let editorBracketOrDashRegex = try! NSRegularExpression(
        pattern: #"(?:[\s_\-—·]+[（(\[【]?|[（(\[【])([\p{Han}A-Za-z]{2,8}?)(?:修改稿|修改版|修订版|批注版|审阅版|核定版|审核版|签批版|改稿|修改|修订|批注|核定|审定|审阅|补充|改|审)[）)\]】]?\s*$"#
    )
    private static let stageKeywordsRegex = try! NSRegularExpression(
        pattern: #"[\s_.\-—·]*(?:[（(\[【]?(?:初稿|草稿|讨论稿|征求意见稿|汇报稿|送审稿|报批稿|修改稿|修订稿|审阅稿|核定稿|签批稿|扫描件|签字版|盖章版|定稿|终稿|最终稿|终版|最终版|定版|清样|净版|clean|final|draft|revised|rev\d*)[）)\]】]?)\s*$"#,
        options: [.caseInsensitive]
    )
    private static let trailingDateRegex = try! NSRegularExpression(
        pattern: #"[\s_.\-—·]*(?:[（(\[【]?(?:20\d{2}[\-./年]?(?:0[1-9]|1[0-2])[\-./月]?(?:0[1-9]|[12]\d|3[01])日?|(?:0[1-9]|1[0-2])[\-./月](?:0[1-9]|[12]\d|3[01])日?)[）)\]】]?)\s*$"#
    )
    private static let leadingDateRegex = try! NSRegularExpression(
        pattern: #"^(?:20\d{2}[\-./]?(?:0[1-9]|1[0-2])[\-./]?(?:0[1-9]|[12]\d|3[01])|(?:0[1-9]|1[0-2])(?:0[1-9]|[12]\d|3[01]))[\s_.\-—·]+"#
    )
    private static let trailingNameAfterVersionRegex = try! NSRegularExpression(
        pattern: #"(?:[\-_—·\s]+(?:v\d+|第\d+[版稿]))[\-_—·\s]+([\p{Han}]{2,4})\s*$"#,
        options: [.caseInsensitive]
    )

    private static let nonPersonStopWords: Set<String> = [
        "最终", "终极", "最新", "正式", "内部", "公开", "打印", "盖章", "签字", "扫描", "汇总",
        "修订", "修改", "初稿", "定稿", "终稿", "副本", "红头", "全文", "正本", "附件"
    ]

    public static func normalize(fileNameOrTitle raw: String) -> NormalizedVersionStem {
        let ns = raw as NSString
        let ext = ns.pathExtension
        let validExt = !ext.isEmpty && ext.count <= 12 && ext.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
        var working = (validExt ? ns.deletingPathExtension : raw)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        var detectedEditor: String?
        var explicitVersion: Int?

        // Check `..._v3_张主任` pattern before stripping (stripping any trailing action verb like `改`)
        if let m = firstMatch(trailingNameAfterVersionRegex, in: working),
           let r = Range(m.range(at: 1), in: working) {
            let candidate = cleanExtractedEditorName(String(working[r]))
            if !candidate.isEmpty && !nonPersonStopWords.contains(candidate) {
                detectedEditor = candidate
            }
        }

        // Iterative stripping loop until stem stabilizes
        for _ in 0..<10 {
            let before = working

            // 1. Strip WeChat/Finder `(1)`, `（2）`
            working = replaceSuffix(bracketDupRegex, in: working)

            // 2. Strip `副本` / `copy`
            working = replaceSuffix(copySuffixRegex, in: working)
            working = replaceRegex(copyPrefixRegex, in: working)

            // 3. Extract editor hint `-张主任改` / `（李科长核定）`
            if let m = firstMatch(editorBracketOrDashRegex, in: working),
               let nameRange = Range(m.range(at: 1), in: working),
               let fullRange = Range(m.range(at: 0), in: working) {
                let candidate = cleanExtractedEditorName(String(working[nameRange]))
                if !candidate.isEmpty && !nonPersonStopWords.contains(candidate) {
                    if detectedEditor == nil { detectedEditor = candidate }
                    let prefix = String(working[..<fullRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !prefix.isEmpty {
                        working = prefix
                    }
                }
            }

            // 4. Extract & strip explicit version (`_v2`, `第3稿`)
            if let m = firstMatch(explicitVersionRegex, in: working),
               let fullRange = Range(m.range(at: 0), in: working) {
                let vStr = Range(m.range(at: 1), in: working).map { String(working[$0]) }
                    ?? Range(m.range(at: 2), in: working).map { String(working[$0]) }
                if let vStr, let v = Int(vStr), explicitVersion == nil {
                    explicitVersion = v
                }
                let prefix = String(working[..<fullRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !prefix.isEmpty {
                    working = prefix
                }
            }

            // 5. Strip stage keywords (`初稿`, `终版`, `最终版`, `定稿`, `签批扫描`)
            working = replaceSuffix(stageKeywordsRegex, in: working)

            // 6. Strip trailing & leading dates (`20260512`, `2026-05-12`)
            working = replaceSuffix(trailingDateRegex, in: working)
            let strippedLead = replaceRegex(leadingDateRegex, in: working)
            if !strippedLead.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                working = strippedLead
            }

            working = working.trimmingCharacters(in: CharacterSet(charactersIn: " _-—·.()（）[]【】"))
            if working == before || working.isEmpty {
                break
            }
        }

        let displayTitle = working.isEmpty
            ? (validExt ? ns.deletingPathExtension : raw).trimmingCharacters(in: .whitespacesAndNewlines)
            : working

        let canonical = canonicalizeForMatching(displayTitle)
        return NormalizedVersionStem(
            canonicalStem: canonical,
            cleanDisplayTitle: displayTitle,
            suggestedEditorName: detectedEditor,
            explicitVersionHint: explicitVersion
        )
    }

    private static func canonicalizeForMatching(_ text: String) -> String {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        var scalars: [UnicodeScalar] = []
        scalars.reserveCapacity(folded.unicodeScalars.count)
        for s in folded.unicodeScalars {
            if SearchText.hasHanScalar(s) || CharacterSet.alphanumerics.contains(s) {
                scalars.append(s)
            }
        }
        return String(String.UnicodeScalarView(scalars)).lowercased()
    }

    private static func firstMatch(_ regex: NSRegularExpression, in text: String) -> NSTextCheckingResult? {
        regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
    }

    private static func cleanExtractedEditorName(_ raw: String) -> String {
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let actionSuffixes = [
            "修改稿", "修改版", "修订版", "批注版", "审阅版", "核定版", "审核版", "签批版",
            "改稿", "修改", "修订", "批注", "核定", "审定", "审阅", "补充", "改", "审"
        ]
        for suffix in actionSuffixes where trimmed.count > suffix.count && trimmed.hasSuffix(suffix) {
            trimmed.removeLast(suffix.count)
            break
        }
        return trimmed.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func replaceSuffix(_ regex: NSRegularExpression, in text: String) -> String {
        guard let m = firstMatch(regex, in: text),
              let r = Range(m.range(at: 0), in: text) else {
            return text
        }
        let candidate = String(text[..<r.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        return candidate.isEmpty ? text : candidate
    }

    private static func replaceRegex(_ regex: NSRegularExpression, in text: String) -> String {
        guard let m = firstMatch(regex, in: text),
              let r = Range(m.range(at: 0), in: text) else {
            return text
        }
        var copy = text
        copy.removeSubrange(r)
        let trimmed = copy.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? text : trimmed
    }
}

// MARK: - 2. 64-Bit Paragraph & Shingle SimHash (<1ms)

public nonisolated enum DocumentSimHash {
    /// Computes a deterministic 64-bit SimHash over paragraph tokens & CJK 2-grams.
    public static func compute64(for payload: StructuredDocumentPayload) -> Int64 {
        if !payload.blocks.isEmpty {
            return compute64FromParagraphs(payload.blocks.map(\.text))
        }
        return compute64(text: payload.plainText)
    }

    public static func compute64(text: String) -> Int64 {
        let paras = DocumentParserEngine.splitPlainParagraphs(text)
        return compute64FromParagraphs(paras)
    }

    public static func compute64FromParagraphs(_ paragraphs: [String]) -> Int64 {
        var weights = [Int](repeating: 0, count: 64)
        var featureCount = 0

        for para in paragraphs {
            let clean = normalizeFeatureText(para)
            guard !clean.isEmpty else { continue }

            // Whole-paragraph structural feature (weight 3)
            accumulateHash(fnv1a64(clean), weight: 3, into: &weights)
            featureCount += 1

            // CJK 2-gram & ASCII word features (weight 1)
            let chars = Array(clean)
            if chars.count >= 2 {
                let step = chars.count > 400 ? 2 : 1
                var i = 0
                while i + 1 < chars.count {
                    let shingle = String([chars[i], chars[i + 1]])
                    accumulateHash(fnv1a64(shingle), weight: 1, into: &weights)
                    featureCount += 1
                    i += step
                }
            } else {
                accumulateHash(fnv1a64(clean), weight: 1, into: &weights)
                featureCount += 1
            }
        }

        guard featureCount > 0 else { return 0 }
        var fingerprint: UInt64 = 0
        for bit in 0..<64 where weights[bit] > 0 {
            fingerprint |= (UInt64(1) << UInt64(bit))
        }
        return Int64(bitPattern: fingerprint)
    }

    /// Returns angular SimHash similarity in `[0, 1]` where orthogonal/random 64-bit fingerprints (`hamming >= 32`)
    /// score `0.0` (preventing false positives on unrelated documents) and edited drafts (`hamming <= 17`) score `>= 0.46`.
    public static func similarity(_ lhs: Int64, _ rhs: Int64) -> Double {
        if lhs == 0 || rhs == 0 { return 0 }
        let xor = UInt64(bitPattern: lhs) ^ UInt64(bitPattern: rhs)
        let hamming = xor.nonzeroBitCount
        return max(0.0, 1.0 - Double(hamming) / 32.0)
    }

    private static func accumulateHash(_ hash: UInt64, weight: Int, into weights: inout [Int]) {
        for bit in 0..<64 {
            if ((hash >> UInt64(bit)) & 1) == 1 {
                weights[bit] &+= weight
            } else {
                weights[bit] &-= weight
            }
        }
    }

    static func fnv1a64(_ text: String) -> UInt64 {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x0000_0100_0000_01B3
        }
        // Finalizer avalanche mix (Murmur3-style) for uniform 64-bit distribution
        hash ^= hash >> 33
        hash &*= 0xFF51_AFD7_ED55_8CCD
        hash ^= hash >> 33
        hash &*= 0xC4CE_B9FE_1A85_EC53
        hash ^= hash >> 33
        return hash
    }

    static func normalizeFeatureText(_ raw: String) -> String {
        var scalars: [UnicodeScalar] = []
        scalars.reserveCapacity(raw.unicodeScalars.count)
        for s in raw.unicodeScalars {
            if SearchText.hasHanScalar(s) || CharacterSet.alphanumerics.contains(s) {
                scalars.append(s)
            }
        }
        return String(String.UnicodeScalarView(scalars)).lowercased()
    }
}

// MARK: - 3. Multi-Modal Diff Engine & High-Risk Number/Date Radar

public nonisolated enum DocumentDiffEngine {
    // High-Risk Date / Time / Deadline regex (checked first so dates & clock times never leak into bare number counts)
    private static let dateRiskRegex = try! NSRegularExpression(
        pattern: #"(?:(?:19|20)\d{2}\s*[年\-/.]\s*\d{1,2}\s*[月\-/.]\s*\d{1,2}\s*日?(?:前|内|底|止)?|(?:19|20)\d{2}\s*[—–\-~至]\s*(?:19|20)\d{2}\s*年度?|(?<!\d)(?:19|20)\d{2}\s*年(?:\s*\d{1,2}\s*月(?:底|前|初|中旬|下旬)?)?|(?<!\d)(?:19|20)\d{2}\s*年度|\d{1,2}\s*月\s*\d{1,2}\s*日(?:前|内|底|止)?|(?:[01]?\d|2[0-3])\s*[:：]\s*[0-5]\d(?:\s*[:：]\s*[0-5]\d)?(?:\s*[—–\-~至]\s*(?:[01]?\d|2[0-3])\s*[:：]\s*[0-5]\d(?:\s*[:：]\s*[0-5]\d)?)?|(?:上午|下午|中午|傍晚|晚|晚上|今晚|明早|凌晨)\s*(?:[01]?\d|2[0-4])\s*[点时](?:\s*[0-5]?\d\s*分(?:\s*[0-5]?\d\s*秒)?|\s*[半整])?|(?<!\d)(?:[01]?\d|2[0-4])\s*时(?:\s*[0-5]?\d\s*分(?:\s*[0-5]?\d\s*秒)?|\s*[半整])?|(?<!\d)(?:[01]?\d|2[0-4])\s*点(?:\s*[0-5]?\d\s*分(?:\s*[0-5]?\d\s*秒)?|\s*(?:半|整|钟)|(?=\s*(?:前|后|左右|开始|召开|集合|出发|签到|结束|截止|下班|上班)))|(?<![¥￥\$+\-\d.])(?:1[0-2]|0?[1-9])\.(?:3[01]|[12]\d|0?[1-9])\s*[—–\-~至]\s*(?:1[0-2]|0?[1-9])\.(?:3[01]|[12]\d|0?[1-9])(?![\d.%‰万亿元])|[“"「『【](?:1[0-2]|0?[1-9])\.(?:3[01]|[12]\d|0?[1-9])[”"」』】]|(?<![¥￥\$+\-\d.])(?:1[0-2]|0?[1-9])\.(?:3[01]|[12]\d|0?[1-9])(?=\s*(?:日|号|前|内|底|止|起|的|舆情|会议|活动|通报|事故|专项|事件|行动|复盘|节点|排期|上线|发布|截稿|截止))|Q[1-4]|第[一二三四1-4]季度|\d{1,3}\s*(?:个?工作日|自然日|天|小时|分钟|个月|周)(?:内|前|以上|以内)?)"#,
        options: [.caseInsensitive]
    )

    // High-Risk Number / Currency / Percentage / Quantity regex
    private static let numberRiskRegex = try! NSRegularExpression(
        pattern: #"(?:(?:人民币|RMB|CNY|USD|HKD|EUR|¥|￥|\$)\s*[-+]?\d[\d,]*(?:\.\d+)?\s*(?:万亿元|亿元|万元|千元|百元|元|万|亿|美元)?|[-+]?\d[\d,]*(?:\.\d+)?\s*(?:%|‰|万亿元|亿元|万元|元|万|亿|人|名|户|家|处|项|台|套|件|个|批|次|吨|公斤|平方米|㎡|公顷|亩|公里|km|米|倍|分)|[-+]?\d{1,3}(?:,\d{3})+(?:\.\d+)?|[-+]?\d+\.\d+|(?<![A-Za-z0-9.])\d{2,}(?![A-Za-z0-9.]))"#,
        options: [.caseInsensitive]
    )

    // Fine-grained inline diff tokenizer: keeps contiguous numbers/dates/times/currency, ASCII words, single CJK chars, and punctuation intact.
    private static let inlineTokenizerRegex = try! NSRegularExpression(
        pattern: #"(?:[¥￥\$]?\d[\d,./:：%‰\-年月日时分秒万亿元]*|\p{Han}|[A-Za-z]+|\s+|[^\s\p{Han}A-Za-z\d])"#
    )

    public static func compare(
        base: StructuredDocumentPayload,
        target: StructuredDocumentPayload,
        sheetName: String? = nil,
        primaryKeyCol: Int? = nil,
        usedOCR: Bool = false
    ) -> DocumentComparisonReport {
        let formatFamily = target.formatFamily

        // 1. Spreadsheet PK-aligned comparison when `.xlsx` / `.csv` sheets exist
        var sheetDiffs: [SpreadsheetSheetDiff] = []
        if !base.sheets.isEmpty || !target.sheets.isEmpty {
            sheetDiffs = compareSpreadsheets(
                baseSheets: base.sheets,
                targetSheets: target.sheets,
                filterSheetName: sheetName,
                overridePrimaryKeyCol: primaryKeyCol
            )
        }

        // 2. Paragraph / Block alignment with Move detection & adjacent-modification pairing
        let hunks: [DocumentDiffHunk]
        if !sheetDiffs.isEmpty && formatFamily == DocumentFormatFamily.xlsx.rawValue {
            hunks = synthesizeHunksFromSheetDiffs(sheetDiffs)
        } else {
            hunks = alignAndDiffBlocks(baseBlocks: base.blocks, targetBlocks: target.blocks)
        }

        // 3. Comment diff
        let commentDiffs = diffComments(baseComments: base.comments, targetComments: target.comments)

        // 4. Aggregate DocumentDiffSummary & 12-bucket minimap
        var addedBlocks = 0
        var removedBlocks = 0
        var modifiedBlocks = 0
        var movedBlocks = 0
        var highRiskNumbers = 0
        var highRiskDates = 0

        for hunk in hunks {
            switch hunk.changeKind {
            case .unchanged: break
            case .added: addedBlocks += 1
            case .removed: removedBlocks += 1
            case .modified: modifiedBlocks += 1
            case .moved: movedBlocks += 1
            }
            let numCount = hunk.highRiskPairs.filter { $0.flag == .numberOrCurrency }.count
            let dateCount = hunk.highRiskPairs.filter { $0.flag == .dateOrDeadline }.count
            if numCount > 0 {
                highRiskNumbers += numCount
            } else if hunk.riskFlags.contains(.numberOrCurrency) {
                highRiskNumbers += 1
            }
            if dateCount > 0 {
                highRiskDates += dateCount
            } else if hunk.riskFlags.contains(.dateOrDeadline) {
                highRiskDates += 1
            }
        }

        let minimap = buildMinimapBuckets(hunks: hunks)
        let summary = DocumentDiffSummary(
            comparedToAssetID: base.assetID,
            addedBlocks: addedBlocks,
            removedBlocks: removedBlocks,
            modifiedBlocks: modifiedBlocks,
            movedBlocks: movedBlocks,
            highRiskNumberChanges: highRiskNumbers,
            highRiskDateChanges: highRiskDates,
            minimapBuckets: minimap
        )

        let supportsTwoWay = (base.formatFamily == target.formatFamily) && [
            DocumentFormatFamily.docx.rawValue,
            DocumentFormatFamily.markdown.rawValue,
            DocumentFormatFamily.plainText.rawValue
        ].contains(target.formatFamily)

        let unavailableReason: String? = if supportsTwoWay {
            nil
        } else if base.formatFamily != target.formatFamily {
            "不同文件格式之间仅支持内容对比，不支持跨格式合成"
        } else {
            "当前格式（\(target.formatFamily.uppercased())）为受保护版式，请在系统默认软件中修改"
        }

        return DocumentComparisonReport(
            baseAssetID: base.assetID,
            targetAssetID: target.assetID,
            baseTitle: base.title,
            targetTitle: target.title,
            formatFamily: formatFamily,
            summary: summary,
            hunks: hunks,
            sheetDiffs: sheetDiffs,
            commentDiffs: commentDiffs,
            usedOCR: usedOCR,
            supportsVisualPageOverlay: target.formatFamily == DocumentFormatFamily.pdf.rawValue,
            canSynthesizeTwoWay: supportsTwoWay,
            synthesisUnavailableReason: unavailableReason
        )
    }

    // MARK: - Block Alignment + Move Detection + Inline Diff

    private static func alignAndDiffBlocks(
        baseBlocks: [DocumentBlock],
        targetBlocks: [DocumentBlock]
    ) -> [DocumentDiffHunk] {
        if baseBlocks.isEmpty && targetBlocks.isEmpty {
            return []
        }
        let baseKeys = baseBlocks.map { normalizeBlockKey($0) }
        let targetKeys = targetBlocks.map { normalizeBlockKey($0) }

        // Stage 1: Assign shared cluster IDs to exact matches AND high-similarity modified counterparts (`>= 0.52`)
        // so stationary edited paragraphs stay on the LCS spine while genuinely relocated paragraphs surface as `.moved`.
        var baseCluster = Array(repeating: -1, count: baseBlocks.count)
        var targetCluster = Array(repeating: -1, count: targetBlocks.count)
        var nextClusterID = 1

        // 1a. Exact normalized key matches (in sequential occurrence order)
        var exactTargetBuckets: [String: [Int]] = [:]
        for (ti, key) in targetKeys.enumerated() {
            exactTargetBuckets[key, default: []].append(ti)
        }
        var bucketCursor: [String: Int] = [:]
        for (bi, key) in baseKeys.enumerated() {
            guard let list = exactTargetBuckets[key] else { continue }
            let pos = bucketCursor[key] ?? 0
            if pos < list.count {
                let ti = list[pos]
                bucketCursor[key] = pos + 1
                let cid = nextClusterID
                nextClusterID += 1
                baseCluster[bi] = cid
                targetCluster[ti] = cid
            }
        }

        // 1b. Fuzzy paragraph identity pairing (`similarity >= 0.52`) for in-place modified blocks
        if baseBlocks.count * targetBlocks.count <= 100_000 {
            var candidates: [(bi: Int, ti: Int, sim: Double)] = []
            for bi in baseBlocks.indices where baseCluster[bi] == -1 {
                for ti in targetBlocks.indices where targetCluster[ti] == -1 {
                    guard baseBlocks[bi].kind == targetBlocks[ti].kind else { continue }
                    let sim = blockSimilarity(baseBlocks[bi], targetBlocks[ti])
                    if sim >= 0.52 {
                        candidates.append((bi, ti, sim))
                    }
                }
            }
            candidates.sort { lhs, rhs in
                if abs(lhs.sim - rhs.sim) > 1e-6 { return lhs.sim > rhs.sim }
                return abs(lhs.bi - lhs.ti) < abs(rhs.bi - rhs.ti)
            }
            for cand in candidates where baseCluster[cand.bi] == -1 && targetCluster[cand.ti] == -1 {
                let cid = nextClusterID
                nextClusterID += 1
                baseCluster[cand.bi] = cid
                targetCluster[cand.ti] = cid
            }
        }

        // Assign distinct negative IDs to truly unmatched blocks so they never accidentally match in LCS
        for bi in baseCluster.indices where baseCluster[bi] == -1 {
            baseCluster[bi] = -(bi + 1)
        }
        for ti in targetCluster.indices where targetCluster[ti] == -1 {
            targetCluster[ti] = -(baseBlocks.count + ti + 2)
        }

        // Stage 2: LCS spine over paragraph cluster IDs
        let anchors = computeLCSAnchors(lhs: baseCluster, rhs: targetCluster)

        struct RawStep {
            var baseIdx: Int?
            var targetIdx: Int?
            var kind: DocumentDiffChangeKind
            var movedFrom: Int?
            var movedTo: Int?
        }

        var steps: [RawStep] = []
        var bCursor = 0
        var tCursor = 0

        func emitGap(bRange: Range<Int>, tRange: Range<Int>) {
            let unmatchedB = Array(bRange)
            let unmatchedT = Array(tRange)

            // Pair modified blocks within the same gap by sequential similarity
            var bPos = 0
            var tPos = 0
            while bPos < unmatchedB.count && tPos < unmatchedT.count {
                let bi = unmatchedB[bPos]
                let ti = unmatchedT[tPos]
                let sim = blockSimilarity(baseBlocks[bi], targetBlocks[ti])
                if sim >= 0.25 || (unmatchedB.count == unmatchedT.count && baseBlocks[bi].kind == targetBlocks[ti].kind) {
                    steps.append(RawStep(baseIdx: bi, targetIdx: ti, kind: .modified))
                    bPos += 1
                    tPos += 1
                } else if unmatchedB.count > unmatchedT.count {
                    steps.append(RawStep(baseIdx: bi, targetIdx: nil, kind: .removed))
                    bPos += 1
                } else {
                    steps.append(RawStep(baseIdx: nil, targetIdx: ti, kind: .added))
                    tPos += 1
                }
            }
            while bPos < unmatchedB.count {
                steps.append(RawStep(baseIdx: unmatchedB[bPos], targetIdx: nil, kind: .removed))
                bPos += 1
            }
            while tPos < unmatchedT.count {
                steps.append(RawStep(baseIdx: nil, targetIdx: unmatchedT[tPos], kind: .added))
                tPos += 1
            }
        }

        for (anchorB, anchorT) in anchors {
            if bCursor < anchorB || tCursor < anchorT {
                emitGap(bRange: bCursor..<anchorB, tRange: tCursor..<anchorT)
            }
            let bBlock = baseBlocks[anchorB]
            let tBlock = targetBlocks[anchorT]
            if bBlock.text == tBlock.text && bBlock.tableRows == tBlock.tableRows {
                steps.append(RawStep(baseIdx: anchorB, targetIdx: anchorT, kind: .unchanged))
            } else {
                steps.append(RawStep(baseIdx: anchorB, targetIdx: anchorT, kind: .modified))
            }
            bCursor = anchorB + 1
            tCursor = anchorT + 1
        }
        if bCursor < baseBlocks.count || tCursor < targetBlocks.count {
            emitGap(bRange: bCursor..<baseBlocks.count, tRange: tCursor..<targetBlocks.count)
        }

        // Cross-gap Move Detection: match pure `.removed` and pure `.added` blocks across the document
        var removedStepIndices = steps.indices.filter { steps[$0].kind == .removed }
        let addedStepIndices = steps.indices.filter { steps[$0].kind == .added }
        var consumedRemovedSteps = Set<Int>()

        for addStepIdx in addedStepIndices {
            guard let tIdx = steps[addStepIdx].targetIdx else { continue }
            let tKey = targetKeys[tIdx]
            guard tKey.count >= 6 else { continue }

            var bestMatchStep: Int?
            var bestScore = 0.0
            for remStepIdx in removedStepIndices where !consumedRemovedSteps.contains(remStepIdx) {
                guard let bIdx = steps[remStepIdx].baseIdx else { continue }
                if baseKeys[bIdx] == tKey {
                    bestMatchStep = remStepIdx
                    bestScore = 1.0
                    break
                }
                let sim = blockSimilarity(baseBlocks[bIdx], targetBlocks[tIdx])
                if sim >= 0.88 && sim > bestScore {
                    bestScore = sim
                    bestMatchStep = remStepIdx
                }
            }

            if let matchedRemStep = bestMatchStep, let bIdx = steps[matchedRemStep].baseIdx {
                consumedRemovedSteps.insert(matchedRemStep)
                steps[addStepIdx] = RawStep(
                    baseIdx: bIdx,
                    targetIdx: tIdx,
                    kind: .moved,
                    movedFrom: bIdx,
                    movedTo: tIdx
                )
            }
        }
        removedStepIndices.removeAll()

        // Materialize DocumentDiffHunks (excluding consumed source `.removed` entries that were converted to `.moved`)
        var hunks: [DocumentDiffHunk] = []
        for (stepIdx, step) in steps.enumerated() where !consumedRemovedSteps.contains(stepIdx) {
            let bBlock = step.baseIdx.map { baseBlocks[$0] }
            let tBlock = step.targetIdx.map { targetBlocks[$0] }
            let primaryBlock = tBlock ?? bBlock!

            var inlineTokens: [DocumentInlineDiffToken] = []
            var tableCellDiffs: [DocumentTableCellDiff] = []
            var highRiskPairs: [DocumentHighRiskValuePair] = []
            var riskFlags: Set<DocumentDiffRiskFlag> = []

            if !primaryBlock.nativeRevisions.isEmpty || !primaryBlock.commentIDs.isEmpty
                || !(bBlock?.nativeRevisions.isEmpty ?? true) {
                riskFlags.insert(.nativeRevisionOrComment)
            }

            switch step.kind {
            case .unchanged:
                inlineTokens = [DocumentInlineDiffToken(id: "tok-\(hunks.count)-0", kind: .equal, text: primaryBlock.text)]
            case .moved:
                if let bText = bBlock?.text, let tText = tBlock?.text, bText != tText {
                    let built = buildInlineDiffAndRisks(oldText: bText, newText: tText, hunkIndex: hunks.count)
                    inlineTokens = built.tokens
                    highRiskPairs = built.pairs
                    riskFlags.formUnion(built.flags)
                } else {
                    inlineTokens = [DocumentInlineDiffToken(id: "tok-\(hunks.count)-0", kind: .equal, text: primaryBlock.text)]
                }
            case .added:
                let newText = tBlock?.text ?? ""
                let risks = scanHighRiskEntities(in: newText)
                let hasNum = !risks.numbers.isEmpty
                let hasDate = !risks.dates.isEmpty
                if hasNum { riskFlags.insert(.numberOrCurrency) }
                if hasDate { riskFlags.insert(.dateOrDeadline) }
                if primaryBlock.kind == .table { riskFlags.insert(.tableMutation) }
                for (i, n) in risks.numbers.enumerated() {
                    highRiskPairs.append(DocumentHighRiskValuePair(id: "hr-\(hunks.count)-n\(i)", flag: .numberOrCurrency, oldValue: nil, newValue: n))
                }
                for (i, d) in risks.dates.enumerated() {
                    highRiskPairs.append(DocumentHighRiskValuePair(id: "hr-\(hunks.count)-d\(i)", flag: .dateOrDeadline, oldValue: nil, newValue: d))
                }
                inlineTokens = [DocumentInlineDiffToken(
                    id: "tok-\(hunks.count)-0",
                    kind: .inserted,
                    text: newText,
                    isHighRiskNumber: hasNum,
                    isHighRiskDate: hasDate
                )]
            case .removed:
                let oldText = bBlock?.text ?? ""
                let risks = scanHighRiskEntities(in: oldText)
                let hasNum = !risks.numbers.isEmpty
                let hasDate = !risks.dates.isEmpty
                if hasNum { riskFlags.insert(.numberOrCurrency) }
                if hasDate { riskFlags.insert(.dateOrDeadline) }
                if primaryBlock.kind == .table { riskFlags.insert(.tableMutation) }
                for (i, n) in risks.numbers.enumerated() {
                    highRiskPairs.append(DocumentHighRiskValuePair(id: "hr-\(hunks.count)-n\(i)", flag: .numberOrCurrency, oldValue: n, newValue: nil))
                }
                for (i, d) in risks.dates.enumerated() {
                    highRiskPairs.append(DocumentHighRiskValuePair(id: "hr-\(hunks.count)-d\(i)", flag: .dateOrDeadline, oldValue: d, newValue: nil))
                }
                inlineTokens = [DocumentInlineDiffToken(
                    id: "tok-\(hunks.count)-0",
                    kind: .deleted,
                    text: oldText,
                    isHighRiskNumber: hasNum,
                    isHighRiskDate: hasDate
                )]
            case .modified:
                if primaryBlock.kind == .table, let bRows = bBlock?.tableRows, let tRows = tBlock?.tableRows,
                   (!bRows.isEmpty || !tRows.isEmpty) {
                    riskFlags.insert(.tableMutation)
                    let tblDiff = diffInlineTableCells(baseRows: bRows, targetRows: tRows, hunkIndex: hunks.count)
                    tableCellDiffs = tblDiff.cells
                    highRiskPairs.append(contentsOf: tblDiff.pairs)
                    riskFlags.formUnion(tblDiff.flags)
                }
                let built = buildInlineDiffAndRisks(
                    oldText: bBlock?.text ?? "",
                    newText: tBlock?.text ?? "",
                    hunkIndex: hunks.count
                )
                inlineTokens = built.tokens
                if highRiskPairs.isEmpty {
                    highRiskPairs = built.pairs
                }
                riskFlags.formUnion(built.flags)
            }

            let isProtected = (bBlock?.isProtectedComplex == true)
                || (tBlock?.isProtectedComplex == true)
                || primaryBlock.kind == .table
            let protReason = tBlock?.protectionReason ?? bBlock?.protectionReason

            hunks.append(DocumentDiffHunk(
                id: "hunk-\(hunks.count)",
                hunkIndex: hunks.count,
                changeKind: step.kind,
                blockKind: primaryBlock.kind,
                sectionTitle: tBlock?.sectionTitle ?? bBlock?.sectionTitle,
                baseBlockIndex: step.baseIdx,
                targetBlockIndex: step.targetIdx,
                movedFromIndex: step.movedFrom,
                movedToIndex: step.movedTo,
                pageNumber: tBlock?.pageNumber ?? bBlock?.pageNumber,
                baseText: bBlock?.text,
                targetText: tBlock?.text,
                baseTableRows: bBlock?.tableRows ?? [],
                targetTableRows: tBlock?.tableRows ?? [],
                inlineTokens: inlineTokens,
                tableCellDiffs: tableCellDiffs,
                highRiskPairs: highRiskPairs,
                riskFlags: riskFlags,
                isProtectedComplex: isProtected,
                protectionReason: protReason,
                baseXMLParagraphIndex: bBlock?.xmlParagraphIndex,
                targetXMLParagraphIndex: tBlock?.xmlParagraphIndex
            ))
        }

        return hunks
    }

    // MARK: - Inline Diff & High-Risk Radar Extraction

    static func buildInlineDiffAndRisks(
        oldText: String,
        newText: String,
        hunkIndex: Int
    ) -> (tokens: [DocumentInlineDiffToken], pairs: [DocumentHighRiskValuePair], flags: Set<DocumentDiffRiskFlag>) {
        let oldAtoms = tokenizeInlineAtoms(oldText)
        let newAtoms = tokenizeInlineAtoms(newText)

        let rawEdits: [(DocumentInlineDiffToken.Kind, String)]
        if oldAtoms.count * newAtoms.count <= 90_000 {
            let anchors = computeLCSAnchors(lhs: oldAtoms, rhs: newAtoms)
            var edits: [(DocumentInlineDiffToken.Kind, String)] = []
            var oi = 0
            var ni = 0
            for (ao, an) in anchors {
                while oi < ao { edits.append((.deleted, oldAtoms[oi])); oi += 1 }
                while ni < an { edits.append((.inserted, newAtoms[ni])); ni += 1 }
                edits.append((.equal, newAtoms[an]))
                oi = ao + 1
                ni = an + 1
            }
            while oi < oldAtoms.count { edits.append((.deleted, oldAtoms[oi])); oi += 1 }
            while ni < newAtoms.count { edits.append((.inserted, newAtoms[ni])); ni += 1 }
            rawEdits = coalesceInlineEdits(edits)
        } else {
            rawEdits = [(.deleted, oldText), (.inserted, newText)]
        }

        // Collect high-risk numbers & dates ONLY from changed (deleted / inserted) text spans
        // so unchanged section ordinals or dates in the same paragraph never false-alarm!
        let deletedJoined = rawEdits.filter { $0.0 == .deleted }.map(\.1).joined(separator: " ")
        let insertedJoined = rawEdits.filter { $0.0 == .inserted }.map(\.1).joined(separator: " ")

        // Also scan full old/new when unit suffixes attach right next to a changed digit (e.g. `12.5` -> `15.2` before unchanged `万元`!)
        let oldEntities = scanHighRiskEntities(in: oldText)
        let newEntities = scanHighRiskEntities(in: newText)
        let changedNumbers = diffOrderedMultiset(old: oldEntities.numbers, new: newEntities.numbers)
        let changedDates = diffOrderedMultiset(old: oldEntities.dates, new: newEntities.dates)

        var flags: Set<DocumentDiffRiskFlag> = []
        var pairs: [DocumentHighRiskValuePair] = []

        let datePairCount = max(changedDates.removed.count, changedDates.added.count)
        let numPairCount = max(changedNumbers.removed.count, changedNumbers.added.count)
        if numPairCount > 0 {
            flags.insert(.numberOrCurrency)
            for idx in 0..<numPairCount {
                pairs.append(DocumentHighRiskValuePair(
                    id: "hr-\(hunkIndex)-num-\(idx)",
                    flag: .numberOrCurrency,
                    oldValue: idx < changedNumbers.removed.count ? changedNumbers.removed[idx] : nil,
                    newValue: idx < changedNumbers.added.count ? changedNumbers.added[idx] : nil
                ))
            }
        } else if datePairCount == 0 {
            // Fallback check on isolated changed spans (e.g. single-digit count change `3处` -> `5处` or `3` -> `5`),
            // stripping any matched date/time spans from BOTH full texts and isolated edits first so date/time edits never leak into numbers!
            let oldNonDate = maskDateRiskSpans(in: oldText)
            let newNonDate = maskDateRiskSpans(in: newText)
            let fullNonDateDiff = diffOrderedMultiset(
                old: scanBareDigits(in: oldNonDate),
                new: scanBareDigits(in: newNonDate)
            )
            if !fullNonDateDiff.removed.isEmpty || !fullNonDateDiff.added.isEmpty {
                let delMasked = maskDateRiskSpans(in: deletedJoined)
                let insMasked = maskDateRiskSpans(in: insertedJoined)
                let delFallback = scanBareDigits(in: delMasked)
                let insFallback = scanBareDigits(in: insMasked)
                let bareDiff = diffOrderedMultiset(old: delFallback, new: insFallback)
                let effectiveDiff = (!bareDiff.removed.isEmpty || !bareDiff.added.isEmpty) ? bareDiff : fullNonDateDiff
                if !effectiveDiff.removed.isEmpty || !effectiveDiff.added.isEmpty {
                    flags.insert(.numberOrCurrency)
                    let cnt = max(effectiveDiff.removed.count, effectiveDiff.added.count)
                    for idx in 0..<cnt {
                        pairs.append(DocumentHighRiskValuePair(
                            id: "hr-\(hunkIndex)-barenum-\(idx)",
                            flag: .numberOrCurrency,
                            oldValue: idx < effectiveDiff.removed.count ? effectiveDiff.removed[idx] : nil,
                            newValue: idx < effectiveDiff.added.count ? effectiveDiff.added[idx] : nil
                        ))
                    }
                }
            }
        }

        if datePairCount > 0 {
            flags.insert(.dateOrDeadline)
            for idx in 0..<datePairCount {
                pairs.append(DocumentHighRiskValuePair(
                    id: "hr-\(hunkIndex)-date-\(idx)",
                    flag: .dateOrDeadline,
                    oldValue: idx < changedDates.removed.count ? changedDates.removed[idx] : nil,
                    newValue: idx < changedDates.added.count ? changedDates.added[idx] : nil
                ))
            }
        }

        let tokens = rawEdits.enumerated().map { idx, item -> DocumentInlineDiffToken in
            let isChanged = item.0 != .equal
            let spanRisks = isChanged ? scanHighRiskEntities(in: item.1) : (dates: [], numbers: [])
            let hasBareDigit = isChanged && item.1.unicodeScalars.contains(where: { CharacterSet.decimalDigits.contains($0) })
            let markDate = isChanged && (!spanRisks.dates.isEmpty || (flags.contains(.dateOrDeadline) && hasBareDigit && !flags.contains(.numberOrCurrency)))
            let markNum = isChanged && !markDate && (!spanRisks.numbers.isEmpty || (flags.contains(.numberOrCurrency) && hasBareDigit))
            return DocumentInlineDiffToken(
                id: "tok-\(hunkIndex)-\(idx)",
                kind: item.0,
                text: item.1,
                isHighRiskNumber: markNum,
                isHighRiskDate: markDate
            )
        }

        return (tokens, pairs, flags)
    }

    public static func scanHighRiskEntities(in text: String) -> (dates: [String], numbers: [String]) {
        guard !text.isEmpty else { return ([], []) }
        let fullRange = NSRange(text.startIndex..., in: text)

        var dateRanges: [NSRange] = []
        var dates: [String] = []
        for match in dateRiskRegex.matches(in: text, range: fullRange) {
            let r = match.range(at: 0)
            if let swiftRange = Range(r, in: text) {
                dateRanges.append(r)
                dates.append(String(text[swiftRange]).trimmingCharacters(in: .whitespaces))
            }
        }

        var numbers: [String] = []
        for match in numberRiskRegex.matches(in: text, range: fullRange) {
            let r = match.range(at: 0)
            let overlapsDate = dateRanges.contains { NSIntersectionRange($0, r).length > 0 }
            if overlapsDate { continue }
            if let swiftRange = Range(r, in: text) {
                numbers.append(String(text[swiftRange]).trimmingCharacters(in: .whitespaces))
            }
        }
        return (dates, numbers)
    }

    private static func maskDateRiskSpans(in text: String) -> String {
        guard !text.isEmpty else { return "" }
        let fullRange = NSRange(text.startIndex..., in: text)
        return dateRiskRegex.stringByReplacingMatches(in: text, options: [], range: fullRange, withTemplate: " ")
    }

    private static func scanBareDigits(in text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        let regex = try! NSRegularExpression(pattern: #"\d+(?:\.\d+)?"#)
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            Range($0.range(at: 0), in: text).map { String(text[$0]) }
        }
    }

    private static func diffOrderedMultiset(old: [String], new: [String]) -> (removed: [String], added: [String]) {
        let anchors = computeLCSAnchors(lhs: old, rhs: new)
        let keptOld = Set(anchors.map(\.0))
        let keptNew = Set(anchors.map(\.1))
        let removed = old.enumerated().compactMap { keptOld.contains($0.offset) ? nil : $0.element }
        let added = new.enumerated().compactMap { keptNew.contains($0.offset) ? nil : $0.element }
        return (removed, added)
    }

    private static func diffInlineTableCells(
        baseRows: [[String]],
        targetRows: [[String]],
        hunkIndex: Int
    ) -> (cells: [DocumentTableCellDiff], pairs: [DocumentHighRiskValuePair], flags: Set<DocumentDiffRiskFlag>) {
        var cellDiffs: [DocumentTableCellDiff] = []
        var pairs: [DocumentHighRiskValuePair] = []
        var flags: Set<DocumentDiffRiskFlag> = [.tableMutation]

        let headers = targetRows.first ?? baseRows.first ?? []
        let maxR = max(baseRows.count, targetRows.count)
        for r in 0..<maxR {
            let bRow = r < baseRows.count ? baseRows[r] : nil
            let tRow = r < targetRows.count ? targetRows[r] : nil
            let maxC = max(bRow?.count ?? 0, tRow?.count ?? 0)
            let rowKey = (tRow?.first ?? bRow?.first)?.nonEmptyTrimmed
            for c in 0..<maxC {
                let ov = (bRow != nil && c < bRow!.count) ? bRow![c] : nil
                let nv = (tRow != nil && c < tRow!.count) ? tRow![c] : nil
                guard ov != nv else { continue }
                let kind: DocumentDiffChangeKind = if ov == nil {
                    .added
                } else if nv == nil {
                    .removed
                } else {
                    .modified
                }
                let built = buildInlineDiffAndRisks(oldText: ov ?? "", newText: nv ?? "", hunkIndex: hunkIndex * 100 + cellDiffs.count)
                flags.formUnion(built.flags)
                pairs.append(contentsOf: built.pairs)
                cellDiffs.append(DocumentTableCellDiff(
                    id: "tbl-\(hunkIndex)-r\(r)-c\(c)",
                    rowIndex: r,
                    colIndex: c,
                    rowKey: rowKey,
                    columnHeader: c < headers.count ? headers[c] : nil,
                    changeKind: kind,
                    oldValue: ov,
                    newValue: nv,
                    riskFlags: built.flags
                ))
            }
        }
        return (cellDiffs, pairs, flags)
    }

    // MARK: - Excel Smart Primary-Key Row Alignment Diff

    public static func compareSpreadsheets(
        baseSheets: [SpreadsheetSheet],
        targetSheets: [SpreadsheetSheet],
        filterSheetName: String? = nil,
        overridePrimaryKeyCol: Int? = nil
    ) -> [SpreadsheetSheetDiff] {
        let baseByName = Dictionary(baseSheets.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        let targetByName = Dictionary(targetSheets.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })

        var orderedNames: [String] = []
        for s in baseSheets where !orderedNames.contains(s.name) { orderedNames.append(s.name) }
        for s in targetSheets where !orderedNames.contains(s.name) { orderedNames.append(s.name) }
        if let filter = filterSheetName?.nonEmptyTrimmed {
            orderedNames = orderedNames.filter { $0 == filter }
        }

        var results: [SpreadsheetSheetDiff] = []
        for name in orderedNames {
            let bSheet = baseByName[name]
            let tSheet = targetByName[name]

            guard let bSheet else {
                if let tSheet {
                    let rowDiffs = tSheet.rows.map { row in
                        let pk = tSheet.suggestedPrimaryKeyCol.flatMap { $0 < row.values.count ? row.values[$0] : nil } ?? "#\(row.rowNumber)"
                        return SpreadsheetRowDiff(
                            id: "sheet-\(name)-add-\(row.rowNumber)",
                            changeKind: .added,
                            primaryKeyValue: pk,
                            baseRowNumber: nil,
                            targetRowNumber: row.rowNumber,
                            baseValues: [],
                            targetValues: row.values
                        )
                    }
                    results.append(SpreadsheetSheetDiff(
                        sheetName: name,
                        changeKind: .added,
                        headers: tSheet.headers,
                        primaryKeyCol: tSheet.suggestedPrimaryKeyCol,
                        primaryKeyHeader: tSheet.suggestedPrimaryKeyCol.flatMap { $0 < tSheet.headers.count ? tSheet.headers[$0] : nil },
                        candidatePrimaryKeyCols: SpreadsheetPrimaryKeyDetector.candidatePrimaryKeyColumns(headers: tSheet.headers, rows: tSheet.rows),
                        addedRowCount: tSheet.rows.count,
                        rowDiffs: rowDiffs
                    ))
                }
                continue
            }

            guard let tSheet else {
                let rowDiffs = bSheet.rows.map { row in
                    let pk = bSheet.suggestedPrimaryKeyCol.flatMap { $0 < row.values.count ? row.values[$0] : nil } ?? "#\(row.rowNumber)"
                    return SpreadsheetRowDiff(
                        id: "sheet-\(name)-rem-\(row.rowNumber)",
                        changeKind: .removed,
                        primaryKeyValue: pk,
                        baseRowNumber: row.rowNumber,
                        targetRowNumber: nil,
                        baseValues: row.values,
                        targetValues: []
                    )
                }
                results.append(SpreadsheetSheetDiff(
                    sheetName: name,
                    changeKind: .removed,
                    headers: bSheet.headers,
                    primaryKeyCol: bSheet.suggestedPrimaryKeyCol,
                    primaryKeyHeader: bSheet.suggestedPrimaryKeyCol.flatMap { $0 < bSheet.headers.count ? bSheet.headers[$0] : nil },
                    candidatePrimaryKeyCols: SpreadsheetPrimaryKeyDetector.candidatePrimaryKeyColumns(headers: bSheet.headers, rows: bSheet.rows),
                    removedRowCount: bSheet.rows.count,
                    rowDiffs: rowDiffs
                ))
                continue
            }

            let headers = tSheet.headers.isEmpty ? bSheet.headers : tSheet.headers
            let candidates = SpreadsheetPrimaryKeyDetector.candidatePrimaryKeyColumns(
                headers: headers,
                rows: tSheet.rows.isEmpty ? bSheet.rows : tSheet.rows
            )
            let maxCols = max(bSheet.columnCount, tSheet.columnCount, headers.count)
            let pkCol: Int? = if let override = overridePrimaryKeyCol, override >= 0, override < maxCols {
                override
            } else {
                tSheet.suggestedPrimaryKeyCol ?? bSheet.suggestedPrimaryKeyCol ?? candidates.first
            }

            let aligned = alignSheetRowsByPrimaryKey(
                sheetName: name,
                headers: headers,
                baseRows: bSheet.rows,
                targetRows: tSheet.rows,
                pkCol: pkCol,
                maxCols: maxCols
            )
            let sheetChangeKind: DocumentDiffChangeKind =
                (aligned.added == 0 && aligned.removed == 0 && aligned.modified == 0 && bSheet.headers == tSheet.headers)
                ? .unchanged
                : .modified

            results.append(SpreadsheetSheetDiff(
                sheetName: name,
                changeKind: sheetChangeKind,
                headers: headers,
                primaryKeyCol: pkCol,
                primaryKeyHeader: pkCol.flatMap { $0 < headers.count ? headers[$0] : nil },
                candidatePrimaryKeyCols: candidates,
                addedRowCount: aligned.added,
                removedRowCount: aligned.removed,
                modifiedRowCount: aligned.modified,
                highRiskCellCount: aligned.highRiskCells,
                rowDiffs: aligned.rows
            ))
        }
        return results
    }

    private static func alignSheetRowsByPrimaryKey(
        sheetName: String,
        headers: [String],
        baseRows: [SpreadsheetRow],
        targetRows: [SpreadsheetRow],
        pkCol: Int?,
        maxCols: Int
    ) -> (rows: [SpreadsheetRowDiff], added: Int, removed: Int, modified: Int, highRiskCells: Int) {
        func makeUniqueKey(for row: SpreadsheetRow, occurrence: inout [String: Int]) -> (rawPK: String, uniqueKey: String) {
            let raw: String
            if let pkCol, pkCol < row.values.count {
                let trimmed = row.values[pkCol].trimmingCharacters(in: .whitespacesAndNewlines)
                raw = trimmed.isEmpty ? "行\(row.rowNumber)" : trimmed
            } else {
                raw = "行\(row.rowNumber)"
            }
            let norm = raw.lowercased()
            let count = (occurrence[norm] ?? 0) + 1
            occurrence[norm] = count
            let key = count == 1 ? norm : "\(norm)##\(count)"
            return (raw, key)
        }

        var baseOcc: [String: Int] = [:]
        var baseKeyed: [(rawPK: String, key: String, row: SpreadsheetRow)] = []
        var baseMap: [String: (rawPK: String, row: SpreadsheetRow)] = [:]
        for r in baseRows {
            let k = makeUniqueKey(for: r, occurrence: &baseOcc)
            baseKeyed.append((k.rawPK, k.uniqueKey, r))
            baseMap[k.uniqueKey] = (k.rawPK, r)
        }

        var targetOcc: [String: Int] = [:]
        var targetKeyed: [(rawPK: String, key: String, row: SpreadsheetRow)] = []
        var targetKeySet = Set<String>()
        for r in targetRows {
            let k = makeUniqueKey(for: r, occurrence: &targetOcc)
            targetKeyed.append((k.rawPK, k.uniqueKey, r))
            targetKeySet.insert(k.uniqueKey)
        }

        var out: [SpreadsheetRowDiff] = []
        var added = 0
        var removed = 0
        var modified = 0
        var highRiskCells = 0

        // Emit rows in target order (inserting removed base rows near their original predecessor position)
        var emittedBaseKeys = Set<String>()
        var baseIdxCursor = 0

        func emitRemovedBefore(matchingBaseKey: String?) {
            while baseIdxCursor < baseKeyed.count {
                let bEntry = baseKeyed[baseIdxCursor]
                if bEntry.key == matchingBaseKey {
                    baseIdxCursor += 1
                    break
                }
                if targetKeySet.contains(bEntry.key) {
                    // This base row still exists later in target (reordered), don't emit as removed
                    break
                }
                if emittedBaseKeys.insert(bEntry.key).inserted {
                    removed += 1
                    var flags: Set<DocumentDiffRiskFlag> = [.tableMutation]
                    let joined = bEntry.row.values.joined(separator: " ")
                    let risks = scanHighRiskEntities(in: joined)
                    if !risks.numbers.isEmpty { flags.insert(.numberOrCurrency); highRiskCells += 1 }
                    if !risks.dates.isEmpty { flags.insert(.dateOrDeadline); highRiskCells += 1 }
                    out.append(SpreadsheetRowDiff(
                        id: "\(sheetName)-rem-\(bEntry.row.rowNumber)",
                        changeKind: .removed,
                        primaryKeyValue: bEntry.rawPK,
                        baseRowNumber: bEntry.row.rowNumber,
                        targetRowNumber: nil,
                        baseValues: padCells(bEntry.row.values, to: maxCols),
                        targetValues: [],
                        riskFlags: flags
                    ))
                }
                baseIdxCursor += 1
            }
        }

        for tEntry in targetKeyed {
            if let bMatch = baseMap[tEntry.key] {
                emitRemovedBefore(matchingBaseKey: tEntry.key)
                emittedBaseKeys.insert(tEntry.key)

                let bVals = padCells(bMatch.row.values, to: maxCols)
                let tVals = padCells(tEntry.row.values, to: maxCols)
                var cellDiffs: [DocumentTableCellDiff] = []
                var rowFlags: Set<DocumentDiffRiskFlag> = []

                for col in 0..<maxCols {
                    let ov = bVals[col]
                    let nv = tVals[col]
                    let of = bMatch.row.formula(at: col)
                    let nf = tEntry.row.formula(at: col)
                    guard ov != nv || of != nf else { continue }

                    var cFlags: Set<DocumentDiffRiskFlag> = [.tableMutation]
                    let built = buildInlineDiffAndRisks(oldText: ov, newText: nv, hunkIndex: col)
                    cFlags.formUnion(built.flags)
                    if cFlags.contains(.numberOrCurrency) || cFlags.contains(.dateOrDeadline) {
                        highRiskCells += 1
                    }
                    rowFlags.formUnion(cFlags)
                    cellDiffs.append(DocumentTableCellDiff(
                        id: "\(sheetName)-r\(tEntry.row.rowNumber)-c\(col)",
                        rowIndex: tEntry.row.rowNumber,
                        colIndex: col,
                        rowKey: tEntry.rawPK,
                        columnHeader: col < headers.count ? headers[col] : nil,
                        changeKind: .modified,
                        oldValue: ov,
                        newValue: nv,
                        oldFormula: of,
                        newFormula: nf,
                        riskFlags: cFlags
                    ))
                }

                let rowKind: DocumentDiffChangeKind = cellDiffs.isEmpty ? .unchanged : .modified
                if rowKind == .modified { modified += 1 }
                out.append(SpreadsheetRowDiff(
                    id: "\(sheetName)-row-\(tEntry.key)",
                    changeKind: rowKind,
                    primaryKeyValue: tEntry.rawPK,
                    baseRowNumber: bMatch.row.rowNumber,
                    targetRowNumber: tEntry.row.rowNumber,
                    baseValues: bVals,
                    targetValues: tVals,
                    cellDiffs: cellDiffs,
                    riskFlags: rowFlags
                ))
            } else {
                added += 1
                var flags: Set<DocumentDiffRiskFlag> = [.tableMutation]
                let tVals = padCells(tEntry.row.values, to: maxCols)
                let risks = scanHighRiskEntities(in: tVals.joined(separator: " "))
                if !risks.numbers.isEmpty { flags.insert(.numberOrCurrency); highRiskCells += 1 }
                if !risks.dates.isEmpty { flags.insert(.dateOrDeadline); highRiskCells += 1 }
                out.append(SpreadsheetRowDiff(
                    id: "\(sheetName)-add-\(tEntry.row.rowNumber)",
                    changeKind: .added,
                    primaryKeyValue: tEntry.rawPK,
                    baseRowNumber: nil,
                    targetRowNumber: tEntry.row.rowNumber,
                    baseValues: [],
                    targetValues: tVals,
                    riskFlags: flags
                ))
            }
        }

        // Emit any trailing removed rows from base
        for bEntry in baseKeyed where !emittedBaseKeys.contains(bEntry.key) {
            removed += 1
            var flags: Set<DocumentDiffRiskFlag> = [.tableMutation]
            let risks = scanHighRiskEntities(in: bEntry.row.values.joined(separator: " "))
            if !risks.numbers.isEmpty { flags.insert(.numberOrCurrency); highRiskCells += 1 }
            if !risks.dates.isEmpty { flags.insert(.dateOrDeadline); highRiskCells += 1 }
            out.append(SpreadsheetRowDiff(
                id: "\(sheetName)-rem-\(bEntry.row.rowNumber)",
                changeKind: .removed,
                primaryKeyValue: bEntry.rawPK,
                baseRowNumber: bEntry.row.rowNumber,
                targetRowNumber: nil,
                baseValues: padCells(bEntry.row.values, to: maxCols),
                targetValues: [],
                riskFlags: flags
            ))
        }

        return (out, added, removed, modified, highRiskCells)
    }

    private static func synthesizeHunksFromSheetDiffs(_ sheetDiffs: [SpreadsheetSheetDiff]) -> [DocumentDiffHunk] {
        var hunks: [DocumentDiffHunk] = []
        for sheet in sheetDiffs {
            for row in sheet.rowDiffs {
                var pairs: [DocumentHighRiskValuePair] = []
                for cell in row.cellDiffs {
                    if cell.riskFlags.contains(.numberOrCurrency) {
                        pairs.append(DocumentHighRiskValuePair(
                            id: "hr-\(cell.id)-n",
                            flag: .numberOrCurrency,
                            oldValue: cell.oldValue,
                            newValue: cell.newValue
                        ))
                    } else if cell.riskFlags.contains(.dateOrDeadline) {
                        pairs.append(DocumentHighRiskValuePair(
                            id: "hr-\(cell.id)-d",
                            flag: .dateOrDeadline,
                            oldValue: cell.oldValue,
                            newValue: cell.newValue
                        ))
                    }
                }
                let baseLine = row.baseValues.isEmpty ? nil : row.baseValues.joined(separator: " | ")
                let targetLine = row.targetValues.isEmpty ? nil : row.targetValues.joined(separator: " | ")
                hunks.append(DocumentDiffHunk(
                    id: "xlsx-hunk-\(hunks.count)",
                    hunkIndex: hunks.count,
                    changeKind: row.changeKind,
                    blockKind: .table,
                    sectionTitle: "\(sheet.sheetName) · \(row.primaryKeyValue)",
                    baseBlockIndex: row.baseRowNumber,
                    targetBlockIndex: row.targetRowNumber,
                    baseText: baseLine,
                    targetText: targetLine,
                    tableCellDiffs: row.cellDiffs,
                    highRiskPairs: pairs,
                    riskFlags: row.riskFlags,
                    isProtectedComplex: true,
                    protectionReason: "电子表格单元格变更（只读对比）"
                ))
            }
        }
        return hunks
    }

    // MARK: - Comment Diff & 12-Bucket Minimap

    private static func diffComments(
        baseComments: [DocumentComment],
        targetComments: [DocumentComment]
    ) -> [DocumentCommentDiff] {
        let bByText = Dictionary(baseComments.map { ("\($0.author):\($0.text)", $0) }, uniquingKeysWith: { f, _ in f })
        let tByText = Dictionary(targetComments.map { ("\($0.author):\($0.text)", $0) }, uniquingKeysWith: { f, _ in f })
        var out: [DocumentCommentDiff] = []
        for c in targetComments {
            let key = "\(c.author):\(c.text)"
            out.append(DocumentCommentDiff(changeKind: bByText[key] == nil ? .added : .unchanged, comment: c))
        }
        for c in baseComments {
            let key = "\(c.author):\(c.text)"
            if tByText[key] == nil {
                out.append(DocumentCommentDiff(changeKind: .removed, comment: c))
            }
        }
        return out
    }

    public static func buildMinimapBuckets(hunks: [DocumentDiffHunk]) -> [Int] {
        let count = DocumentDiffSummary.bucketCount
        guard !hunks.isEmpty else { return Array(repeating: 0, count: count) }
        var buckets = Array(repeating: 0, count: count)
        for (idx, hunk) in hunks.enumerated() where hunk.changeKind.isChanged {
            let slot = min(count - 1, (idx * count) / max(1, hunks.count))
            let isHighRisk = hunk.riskFlags.contains(.numberOrCurrency) || hunk.riskFlags.contains(.dateOrDeadline)
            buckets[slot] = max(buckets[slot], isHighRisk ? 2 : 1)
        }
        return buckets
    }

    // MARK: - Internal Alignment Primitives

    private static func normalizeBlockKey(_ block: DocumentBlock) -> String {
        let collapsed = block.text.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return "\(block.kind.rawValue):\(collapsed)"
    }

    private static func blockSimilarity(_ a: DocumentBlock, _ b: DocumentBlock) -> Double {
        if a.text == b.text { return 1.0 }
        let setA = Set(tokenizeInlineAtoms(a.text).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
        let setB = Set(tokenizeInlineAtoms(b.text).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
        guard !setA.isEmpty || !setB.isEmpty else { return 0 }
        let inter = setA.intersection(setB).count
        let union = setA.union(setB).count
        return union > 0 ? Double(inter) / Double(union) : 0
    }

    private static func tokenizeInlineAtoms(_ text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        let ns = text as NSString
        return inlineTokenizerRegex.matches(in: text, range: NSRange(location: 0, length: ns.length)).map {
            ns.substring(with: $0.range(at: 0))
        }
    }

    private static func coalesceInlineEdits(
        _ edits: [(DocumentInlineDiffToken.Kind, String)]
    ) -> [(DocumentInlineDiffToken.Kind, String)] {
        var out: [(DocumentInlineDiffToken.Kind, String)] = []
        for (kind, text) in edits where !text.isEmpty {
            if let last = out.last, last.0 == kind {
                out[out.count - 1].1.append(text)
            } else {
                out.append((kind, text))
            }
        }
        return out
    }

    private static func computeLCSAnchors<T: Hashable>(lhs: [T], rhs: [T]) -> [(Int, Int)] {
        guard !lhs.isEmpty, !rhs.isEmpty else { return [] }

        // Trim identical prefix & suffix in O(N) first
        var prefix = 0
        while prefix < lhs.count && prefix < rhs.count && lhs[prefix] == rhs[prefix] {
            prefix += 1
        }
        var suffix = 0
        while (prefix + suffix) < lhs.count
            && (prefix + suffix) < rhs.count
            && lhs[lhs.count - 1 - suffix] == rhs[rhs.count - 1 - suffix] {
            suffix += 1
        }

        var anchors: [(Int, Int)] = (0..<prefix).map { ($0, $0) }
        let midL = Array(lhs[prefix..<(lhs.count - suffix)])
        let midR = Array(rhs[prefix..<(rhs.count - suffix)])

        if !midL.isEmpty && !midR.isEmpty {
            if midL.count * midR.count <= 250_000 {
                let n = midL.count
                let m = midR.count
                var dp = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
                for i in stride(from: n - 1, through: 0, by: -1) {
                    for j in stride(from: m - 1, through: 0, by: -1) {
                        if midL[i] == midR[j] {
                            dp[i][j] = dp[i + 1][j + 1] + 1
                        } else {
                            dp[i][j] = max(dp[i + 1][j], dp[i][j + 1])
                        }
                    }
                }
                var i = 0
                var j = 0
                while i < n && j < m {
                    if midL[i] == midR[j] {
                        anchors.append((prefix + i, prefix + j))
                        i += 1
                        j += 1
                    } else if dp[i + 1][j] >= dp[i][j + 1] {
                        i += 1
                    } else {
                        j += 1
                    }
                }
            } else {
                // Linear-memory greedy unique-item anchor fallback for huge sequences
                var rhsUniquePos: [T: Int?] = [:]
                for (j, val) in midR.enumerated() {
                    if rhsUniquePos.keys.contains(val) {
                        rhsUniquePos[val] = .some(nil)
                    } else {
                        rhsUniquePos[val] = .some(j)
                    }
                }
                var lastR = -1
                for (i, val) in midL.enumerated() {
                    if let maybeJ = rhsUniquePos[val], let j = maybeJ, j > lastR {
                        anchors.append((prefix + i, prefix + j))
                        lastR = j
                    }
                }
            }
        }

        for s in 0..<suffix {
            anchors.append((lhs.count - suffix + s, rhs.count - suffix + s))
        }
        return anchors
    }

    private static func padCells(_ cells: [String], to count: Int) -> [String] {
        cells.count < count ? cells + Array(repeating: "", count: count - cells.count) : cells
    }
}

// MARK: - 4. Scheme B Safe 2-Way Document Synthesizer

public enum DocumentSynthesisError: LocalizedError, Sendable {
    case unsupportedFormat(String)
    case missingTemplateXML
    case xmlValidationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedFormat(let fmt):
            return "当前格式（\(fmt)）不支持直接合成写回，请在默认应用中修改。"
        case .missingTemplateXML:
            return "底稿 .docx 缺少 word/document.xml。"
        case .xmlValidationFailed(let detail):
            return "合成后的文档未通过 XML 结构完整性校验：\(detail)"
        }
    }
}

public nonisolated enum DocumentTwoWaySynthesizer {
    /// Synthesizes a clean `vN+1` document file on disk (inside `outputURL`) from a 2-way comparison report
    /// and user per-hunk decisions without ever mutating `baseFileURL` or `targetFileURL`.
    public static func synthesize(
        baseFileURL: URL,
        targetFileURL: URL,
        report: DocumentComparisonReport,
        preferTargetAsTemplate: Bool,
        decisions: [DocumentMergeDecision],
        to outputURL: URL
    ) throws {
        let family = DocumentFormatFamily(rawValue: report.formatFamily) ?? .other
        switch family {
        case .markdown, .plainText:
            let mergedText = report.previewMergedText(
                preferTargetAsTemplate: preferTargetAsTemplate,
                decisions: decisions
            )
            try Data(mergedText.utf8).write(to: outputURL, options: .atomic)

        case .docx:
            let templateURL = preferTargetAsTemplate ? targetFileURL : baseFileURL
            let data = try synthesizeDOCXArchiveData(
                templateURL: templateURL,
                report: report,
                preferTargetAsTemplate: preferTargetAsTemplate,
                decisions: decisions
            )
            try data.write(to: outputURL, options: .atomic)

        default:
            throw DocumentSynthesisError.unsupportedFormat(report.formatFamily)
        }
    }

    /// Byte-preserving `.docx` surgical 2-Way synthesizer:
    /// - Copies all untouched ZIP entries (`styles.xml`, `header*.xml`, `footer*.xml`, `numbering.xml`, `word/media/*`, etc.) byte-for-byte.
    /// - Surgically updates only plain top-level `<w:body>/<w:p>` paragraphs while preserving `<w:pPr>` & `<w:rPr>` formatting and protecting complex blocks.
    /// - Validates output `word/document.xml` via `XMLParser` and archive round-trip via `ZipArchiveReader` before returning.
    public static func synthesizeDOCXArchiveData(
        templateURL: URL,
        report: DocumentComparisonReport,
        preferTargetAsTemplate: Bool,
        decisions: [DocumentMergeDecision]
    ) throws -> Data {
        let templateReader = try ZipArchiveReader(url: templateURL)
        guard let rawDocXMLData = try templateReader.readEntry("word/document.xml"),
              let rawDocXML = String(data: rawDocXMLData, encoding: .utf8) else {
            throw DocumentSynthesisError.missingTemplateXML
        }

        let patchedXML = try patchDOCXDocumentXML(
            rawXML: rawDocXML,
            report: report,
            preferTargetAsTemplate: preferTargetAsTemplate,
            decisions: decisions
        )
        let patchedData = Data(patchedXML.utf8)

        // Gate 1: Strict XML well-formedness check
        let validator = XMLParser(data: patchedData)
        validator.shouldProcessNamespaces = true
        guard validator.parse() else {
            let msg = validator.parserError?.localizedDescription ?? "未知 XML 语法错误"
            throw DocumentSynthesisError.xmlValidationFailed(msg)
        }

        // Gate 2: Rebuild ZIP preserving every other entry verbatim
        var writer = ZipArchiveWriter()
        for entry in templateReader.entries {
            if entry.name == "word/document.xml" {
                try writer.addEntry(
                    name: entry.name,
                    data: patchedData,
                    compress: true,
                    dosTime: entry.dosTime,
                    dosDate: entry.dosDate
                )
            } else {
                try writer.copyRawEntry(entry, from: templateReader)
            }
        }
        let synthesizedArchive = try writer.finalize()

        // Gate 3: Round-trip ZIP & DOCX parse verification
        let checkReader = try ZipArchiveReader(data: synthesizedArchive)
        _ = try DocumentParserEngine.parseDOCX(reader: checkReader, assetID: UUID(), fallbackTitle: "Verify")
        return synthesizedArchive
    }

    static func patchDOCXDocumentXML(
        rawXML: String,
        report: DocumentComparisonReport,
        preferTargetAsTemplate: Bool,
        decisions: [DocumentMergeDecision]
    ) throws -> String {
        let decisionByHunk = Dictionary(uniqueKeysWithValues: decisions.map { ($0.hunkID, $0) })
        let defaultChoice: DocumentMergeDecision.Choice = preferTargetAsTemplate ? .acceptTarget : .keepBase

        // Locate exact character spans of top-level `<w:body>/<w:p ...>...</w:p>` elements
        let topParagraphSpans = locateTopLevelBodyParagraphSpans(in: rawXML)

        // Map template paragraph XML index -> mutation action (`replace(String)` or `delete`)
        enum ParagraphEdit {
            case replaceText(String)
            case deleteParagraph
        }
        var editsByParaIdx: [Int: ParagraphEdit] = [:]
        var insertionsBeforeParaIdx: [Int: [String]] = [:]
        var trailingInsertions: [String] = []

        var lastSeenTemplateParaIdx: Int?

        for hunk in report.hunks {
            let templateParaIdx = preferTargetAsTemplate ? hunk.targetXMLParagraphIndex : hunk.baseXMLParagraphIndex
            if let tIdx = templateParaIdx {
                lastSeenTemplateParaIdx = tIdx
            }
            // Never touch protected complex blocks (tables, fields, SmartArt, OLE, drawings, SDTs, section breaks)
            guard !hunk.isProtectedComplex else { continue }

            let decision = decisionByHunk[hunk.id]
            let choice = decision?.choice ?? defaultChoice

            // Fast path: choice matches the template version -> keep template XML untouched!
            if (preferTargetAsTemplate && choice == .acceptTarget) || (!preferTargetAsTemplate && choice == .keepBase) {
                continue
            }

            let desiredText: String? = switch choice {
            case .keepBase: hunk.baseText
            case .acceptTarget: hunk.targetText
            case .customText: decision?.customText
            }

            if let paraIdx = templateParaIdx, paraIdx >= 0, paraIdx < topParagraphSpans.count {
                if let text = desiredText {
                    editsByParaIdx[paraIdx] = .replaceText(text)
                } else {
                    editsByParaIdx[paraIdx] = .deleteParagraph
                }
            } else if let text = desiredText, !text.isEmpty {
                // Hunk did not exist in the template (e.g. restoring a paragraph deleted in target while using target as template)
                let insertAnchor = lastSeenTemplateParaIdx.map { $0 + 1 } ?? 0
                if insertAnchor < topParagraphSpans.count {
                    insertionsBeforeParaIdx[insertAnchor, default: []].append(text)
                } else {
                    trailingInsertions.append(text)
                }
            }
        }

        if editsByParaIdx.isEmpty && insertionsBeforeParaIdx.isEmpty && trailingInsertions.isEmpty {
            return rawXML
        }

        // Apply edits in reverse offset order so earlier string indices stay valid
        var output = rawXML
        if !trailingInsertions.isEmpty {
            let newNodes = trailingInsertions.map { buildCleanWPNode(text: $0, styleSourceParagraphXML: topParagraphSpans.last.map { String(rawXML[$0]) }) }.joined()
            if let bodyClose = output.range(of: "</w:body>", options: .backwards) ?? output.range(of: "</body>", options: .backwards) {
                // Insert before trailing `<w:sectPr>` if `<w:body>` ends with `<w:sectPr>...</w:sectPr>`
                let beforeBodyClose = output[..<bodyClose.lowerBound]
                if let sectStart = beforeBodyClose.range(of: "<w:sectPr", options: .backwards) {
                    output.insert(contentsOf: newNodes, at: sectStart.lowerBound)
                } else {
                    output.insert(contentsOf: newNodes, at: bodyClose.lowerBound)
                }
            }
        }

        for idx in stride(from: topParagraphSpans.count - 1, through: 0, by: -1) {
            let span = topParagraphSpans[idx]
            let originalParaXML = String(rawXML[span])
            var replacementXML = originalParaXML

            if let edit = editsByParaIdx[idx] {
                switch edit {
                case .replaceText(let newText):
                    replacementXML = rewriteWPParagraphText(originalParaXML: originalParaXML, newText: newText)
                case .deleteParagraph:
                    // Safety invariant: if `<w:pPr>` carries a `<w:sectPr>`, keep an empty `<w:p><w:pPr>...</w:pPr></w:p>`
                    // so page margins / headers / footers never disappear!
                    if originalParaXML.contains("<w:sectPr") || originalParaXML.contains("<sectPr") {
                        replacementXML = rewriteWPParagraphText(originalParaXML: originalParaXML, newText: "")
                    } else {
                        replacementXML = ""
                    }
                }
            }

            if let prepended = insertionsBeforeParaIdx[idx], !prepended.isEmpty {
                let insertedXML = prepended.map { buildCleanWPNode(text: $0, styleSourceParagraphXML: originalParaXML) }.joined()
                replacementXML = insertedXML + replacementXML
            }

            if replacementXML != originalParaXML {
                output.replaceSubrange(span, with: replacementXML)
            }
        }

        return output
    }

    /// Scans `<w:body>` at exact tag depth 1 to locate top-level `<w:p>...</w:p>` elements,
    /// ignoring `<w:p>` inside `<w:tbl>` cells or `<w:sdt>` controls.
    static func locateTopLevelBodyParagraphSpans(in xml: String) -> [Range<String.Index>] {
        let tagRegex = try! NSRegularExpression(pattern: #"<\s*(/?)\s*([A-Za-z0-9_]+:)?([A-Za-z0-9_]+)\b([^>]*?)(/?)\s*>"#)
        let ns = xml as NSString
        let matches = tagRegex.matches(in: xml, range: NSRange(location: 0, length: ns.length))

        var inBody = false
        var depthInBody = 0
        var activeTopParaStart: String.Index?
        var spans: [Range<String.Index>] = []

        for m in matches {
            let isClosing = ns.substring(with: m.range(at: 1)) == "/"
            let local = ns.substring(with: m.range(at: 3))
            let isSelfClosing = ns.substring(with: m.range(at: 5)) == "/"
            guard let fullRange = Range(m.range(at: 0), in: xml) else { continue }

            if !inBody {
                if !isClosing && !isSelfClosing && local == "body" {
                    inBody = true
                    depthInBody = 0
                }
                continue
            }

            if isClosing {
                if local == "body" && depthInBody == 0 {
                    break
                }
                if local == "p" && depthInBody == 1, let start = activeTopParaStart {
                    spans.append(start..<fullRange.upperBound)
                    activeTopParaStart = nil
                }
                depthInBody = max(0, depthInBody - 1)
            } else if isSelfClosing {
                if local == "p" && depthInBody == 0 {
                    spans.append(fullRange)
                }
            } else {
                if local == "p" && depthInBody == 0 {
                    activeTopParaStart = fullRange.lowerBound
                }
                depthInBody += 1
            }
        }
        return spans
    }

    private static func rewriteWPParagraphText(originalParaXML: String, newText: String) -> String {
        let useWPrefix = originalParaXML.hasPrefix("<w:")
        let pTagOpen: String = {
            if let gt = originalParaXML.firstIndex(of: ">") {
                var open = String(originalParaXML[...gt])
                if open.hasSuffix("/>") {
                    open.removeLast(2)
                    open.append(">")
                }
                return open
            }
            return useWPrefix ? "<w:p>" : "<p>"
        }()
        let pTagClose = useWPrefix ? "</w:p>" : "</p>"

        let preservedPPr = extractFirstSubtree(in: originalParaXML, localTag: "pPr") ?? ""
        let preservedRPr = extractFirstRunRPr(in: originalParaXML) ?? ""
        let runXML = buildRunXML(text: newText, rPrXML: preservedRPr, useWPrefix: useWPrefix)
        return "\(pTagOpen)\(preservedPPr)\(runXML)\(pTagClose)"
    }

    private static func buildCleanWPNode(text: String, styleSourceParagraphXML: String?) -> String {
        let useWPrefix = styleSourceParagraphXML?.hasPrefix("<w:") ?? true
        let rPr = styleSourceParagraphXML.flatMap { extractFirstRunRPr(in: $0) } ?? ""
        let pOpen = useWPrefix ? "<w:p>" : "<p>"
        let pClose = useWPrefix ? "</w:p>" : "</p>"
        return "\(pOpen)\(buildRunXML(text: text, rPrXML: rPr, useWPrefix: useWPrefix))\(pClose)"
    }

    private static func buildRunXML(text: String, rPrXML: String, useWPrefix: Bool) -> String {
        guard !text.isEmpty else { return "" }
        let rOpen = useWPrefix ? "<w:r>" : "<r>"
        let rClose = useWPrefix ? "</w:r>" : "</r>"
        let tTag = useWPrefix ? "w:t" : "t"
        let brTag = useWPrefix ? "<w:br/>" : "<br/>"

        // Strip Markdown heading prefix `# ` when writing back into a styled `.docx` heading paragraph
        let lines = DocumentTextDecoder.normalizeLineEndings(text).components(separatedBy: "\n")
        var inner = rPrXML
        for (idx, line) in lines.enumerated() {
            if idx > 0 { inner.append(brTag) }
            let escaped = escapeXMLText(line)
            inner.append("<\(tTag) xml:space=\"preserve\">\(escaped)</\(tTag)>")
        }
        return "\(rOpen)\(inner)\(rClose)"
    }

    private static func extractFirstSubtree(in xml: String, localTag: String) -> String? {
        let pattern = #"<([A-Za-z0-9_]+:)?\#(localTag)\b[^>]*?(?:/>|>[\s\S]*?</\s*(?:[A-Za-z0-9_]+:)?\#(localTag)\s*>)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: xml, range: NSRange(xml.startIndex..., in: xml)),
              let range = Range(match.range(at: 0), in: xml) else {
            return nil
        }
        return String(xml[range])
    }

    private static func extractFirstRunRPr(in paraXML: String) -> String? {
        guard let rSubtree = extractFirstSubtree(in: paraXML, localTag: "r") else { return nil }
        return extractFirstSubtree(in: rSubtree, localTag: "rPr")
    }

    static func escapeXMLText(_ raw: String) -> String {
        var out = ""
        out.reserveCapacity(raw.count)
        for scalar in raw.unicodeScalars {
            // Omit illegal XML 1.0 control characters (< 0x20 except \t, \n, \r) so Word/XMLParser never rejects the file!
            let v = scalar.value
            if v < 0x20 && v != 0x09 && v != 0x0A && v != 0x0D {
                continue
            }
            switch scalar {
            case "&": out.append("&amp;")
            case "<": out.append("&lt;")
            case ">": out.append("&gt;")
            case "\"": out.append("&quot;")
            case "'": out.append("&apos;")
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out
    }
}
