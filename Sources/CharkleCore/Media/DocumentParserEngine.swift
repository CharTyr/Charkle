#if canImport(AppKit)
import AppKit
#endif
import CoreFoundation
import CoreGraphics
import Foundation
import PDFKit
import Vision

// MARK: - Multi-Encoding Text Decoder (UTF-8 / UTF-16 / GB18030)

public nonisolated enum DocumentTextDecoder {
    public static let gb18030Encoding: String.Encoding = {
        let cfEnc = CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
        let nsEnc = CFStringConvertEncodingToNSStringEncoding(cfEnc)
        return String.Encoding(rawValue: nsEnc)
    }()

    public static func decode(_ data: Data) -> String {
        guard !data.isEmpty else { return "" }

        // 1. Explicit BOM checks
        if data.count >= 3,
           data[data.startIndex] == 0xEF,
           data[data.startIndex + 1] == 0xBB,
           data[data.startIndex + 2] == 0xBF {
            let body = data.dropFirst(3)
            if let utf8 = String(data: body, encoding: .utf8) {
                return normalizeLineEndings(utf8)
            }
        }
        if data.count >= 2 {
            let b0 = data[data.startIndex]
            let b1 = data[data.startIndex + 1]
            if b0 == 0xFF && b1 == 0xFE {
                if let utf16le = String(data: data.dropFirst(2), encoding: .utf16LittleEndian) {
                    return normalizeLineEndings(utf16le)
                }
            }
            if b0 == 0xFE && b1 == 0xFF {
                if let utf16be = String(data: data.dropFirst(2), encoding: .utf16BigEndian) {
                    return normalizeLineEndings(utf16be)
                }
            }
        }

        // 2. Strict UTF-8 check (returns nil on invalid byte sequences such as GBK/GB18030)
        if !looksLikeBOMLessUTF16(data), let utf8 = String(data: data, encoding: .utf8) {
            return normalizeLineEndings(utf8)
        }

        // 3. BOM-less UTF-16 heuristic
        if looksLikeBOMLessUTF16(data) {
            let evenZeros = stride(from: 0, to: min(data.count, 512), by: 2).filter { data[data.startIndex + $0] == 0 }.count
            let oddZeros = stride(from: 1, to: min(data.count, 512), by: 2).filter { data[data.startIndex + $0] == 0 }.count
            let enc: String.Encoding = oddZeros >= evenZeros ? .utf16LittleEndian : .utf16BigEndian
            if let decoded = String(data: data, encoding: enc) {
                return normalizeLineEndings(decoded)
            }
        }

        // 4. Chinese national standard GB18030 (complete superset of GBK and GB2312)
        if let gb = String(data: data, encoding: gb18030Encoding) {
            return normalizeLineEndings(gb)
        }

        // 5. Fallback to ISO-Latin-1 or lossy UTF-8
        if let latin = String(data: data, encoding: .isoLatin1) {
            return normalizeLineEndings(latin)
        }
        return normalizeLineEndings(String(decoding: data, as: UTF8.self))
    }

    private static func looksLikeBOMLessUTF16(_ data: Data) -> Bool {
        let sampleLen = min(data.count, 256)
        guard sampleLen >= 8 && sampleLen % 2 == 0 else { return false }
        var zeroCount = 0
        for idx in 0..<sampleLen where data[data.startIndex + idx] == 0 {
            zeroCount += 1
        }
        return Double(zeroCount) / Double(sampleLen) >= 0.22
    }

    static func normalizeLineEndings(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }
}

// MARK: - Unified Document Parser Engine

public nonisolated enum DocumentParserEngine {
    public struct ParsedDocumentBundle: Sendable {
        public var payload: StructuredDocumentPayload
        public var richMetadata: DocumentRichMetadata
        public var simhash64: Int64
    }

    public static func parse(
        fileURL: URL,
        assetID: UUID = UUID(),
        preferredTitle: String? = nil,
        performOCRIfScanned: Bool = false
    ) async throws -> ParsedDocumentBundle {
        let accessed = fileURL.startAccessingSecurityScopedResource()
        defer { if accessed { fileURL.stopAccessingSecurityScopedResource() } }

        let ext = fileURL.pathExtension.lowercased()
        let fallbackTitle = preferredTitle?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? preferredTitle!
            : fileURL.deletingPathExtension().lastPathComponent

        var payload: StructuredDocumentPayload
        switch ext {
        case "docx":
            payload = try parseDOCX(url: fileURL, assetID: assetID, fallbackTitle: fallbackTitle)
        case "xlsx":
            payload = try parseXLSX(url: fileURL, assetID: assetID, fallbackTitle: fallbackTitle)
        case "pptx":
            payload = try parsePPTX(url: fileURL, assetID: assetID, fallbackTitle: fallbackTitle)
        case "odt":
            payload = try parseODT(url: fileURL, assetID: assetID, fallbackTitle: fallbackTitle)
        case "epub":
            payload = try parseEPUB(url: fileURL, assetID: assetID, fallbackTitle: fallbackTitle)
        case "pdf":
            payload = parsePDF(url: fileURL, assetID: assetID, fallbackTitle: fallbackTitle)
            if performOCRIfScanned && !payload.hasTextLayer {
                let ocrPayload = await ocrScannedPDF(url: fileURL, assetID: assetID, fallbackTitle: fallbackTitle)
                if !ocrPayload.blocks.isEmpty {
                    payload = ocrPayload
                }
            }
        case "md", "markdown":
            let data = try Data(contentsOf: fileURL, options: [.mappedIfSafe])
            payload = parseMarkdown(data: data, assetID: assetID, fallbackTitle: fallbackTitle)
        case "csv":
            let data = try Data(contentsOf: fileURL, options: [.mappedIfSafe])
            payload = parseCSV(data: data, assetID: assetID, fallbackTitle: fallbackTitle)
        case "txt", "json", "yaml", "yml", "toml":
            let data = try Data(contentsOf: fileURL, options: [.mappedIfSafe])
            payload = parsePlainText(data: data, assetID: assetID, fallbackTitle: fallbackTitle)
        case "doc", "wps", "xls", "et", "dps", "rtf", "ofd", "pages", "numbers", "key", "ppt":
            payload = await parseLegacyOrFallbackDocument(url: fileURL, ext: ext, assetID: assetID, fallbackTitle: fallbackTitle)
        default:
            let data = (try? Data(contentsOf: fileURL, options: [.mappedIfSafe])) ?? Data()
            payload = parsePlainText(data: data, assetID: assetID, fallbackTitle: fallbackTitle)
        }

        let rich = DocumentRichMetadata(
            formatFamily: payload.formatFamily,
            wordCount: payload.wordCount,
            pageCount: payload.pageCount,
            sheetNames: payload.sheets.map(\.name),
            hasNativeRevisions: payload.hasNativeRevisions,
            hasTextLayer: payload.hasTextLayer,
            diffSummary: nil
        )
        let simhash = DocumentSimHash.compute64(for: payload)
        return ParsedDocumentBundle(payload: payload, richMetadata: rich, simhash64: simhash)
    }

    /// Word count treating each CJK Han ideograph as 1 token and each contiguous ASCII/Latin word/number as 1 token.
    public static func countWords(in text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        var count = 0
        var inWord = false
        for scalar in text.unicodeScalars {
            if SearchText.hasHanScalar(scalar) {
                if inWord {
                    count += 1
                    inWord = false
                }
                count += 1
            } else if CharacterSet.alphanumerics.contains(scalar) {
                inWord = true
            } else if inWord {
                count += 1
                inWord = false
            }
        }
        if inWord { count += 1 }
        return count
    }

    // MARK: - OOXML .docx Parser

    public static func parseDOCX(url: URL, assetID: UUID, fallbackTitle: String) throws -> StructuredDocumentPayload {
        let reader = try ZipArchiveReader(url: url)
        return try parseDOCX(reader: reader, assetID: assetID, fallbackTitle: fallbackTitle)
    }

    public static func parseDOCX(
        reader: ZipArchiveReader,
        assetID: UUID,
        fallbackTitle: String
    ) throws -> StructuredDocumentPayload {
        guard let docXML = try reader.readEntry("word/document.xml") else {
            throw ZipArchiveError.invalidArchive("缺少 word/document.xml")
        }

        let coreProps = (try? reader.readEntry("docProps/core.xml")).map(OOXMLCorePropsParser.parse) ?? .init()
        let appPages = (try? reader.readEntry("docProps/app.xml")).flatMap(OOXMLAppPropsParser.parsePages)
        var comments = (try? reader.readEntry("word/comments.xml")).map(DOCXCommentsXMLParser.parse) ?? []

        let parsedBody = DOCXDocumentXMLParser.parse(docXML)

        // Link comment anchors to block indices & excerpts
        if !comments.isEmpty {
            var blockByCommentID: [String: (index: Int, excerpt: String)] = [:]
            for block in parsedBody.blocks {
                for cid in block.commentIDs where blockByCommentID[cid] == nil {
                    blockByCommentID[cid] = (block.index, String(block.text.prefix(80)))
                }
            }
            for idx in comments.indices {
                if let anchor = blockByCommentID[comments[idx].id] {
                    comments[idx].anchorBlockIndex = anchor.index
                    comments[idx].anchorExcerpt = anchor.excerpt
                }
            }
        }

        let plainParts = parsedBody.blocks.map(\.text).filter { !$0.isEmpty }
        let plainText = plainParts.joined(separator: "\n")
        let wordCount = countWords(in: plainText)
        let estimatedPages = max(1, appPages ?? parsedBody.explicitPageBreaks + max(1, (wordCount + 649) / 650))
        let hasRevisions = parsedBody.hasNativeRevisions || !comments.isEmpty
        let editor = coreProps.lastModifiedBy?.nonEmptyTrimmed ?? coreProps.creator?.nonEmptyTrimmed
        let title = fallbackTitle.nonEmptyTrimmed ?? coreProps.title?.nonEmptyTrimmed ?? "未命名文档"

        let redHeaderDetected = parsedBody.hasRedHeaderRun
            || Self.looksLikeOfficialRedHeaderTitle(title: title, firstBlocks: Array(parsedBody.blocks.prefix(3)))

        return StructuredDocumentPayload(
            assetID: assetID,
            formatFamily: DocumentFormatFamily.docx.rawValue,
            title: title,
            authorOrEditor: editor,
            wordCount: wordCount,
            pageCount: estimatedPages,
            hasTextLayer: true,
            hasNativeRevisions: hasRevisions,
            isRedHeaderStyle: redHeaderDetected,
            blocks: parsedBody.blocks,
            sheets: [],
            comments: comments,
            plainText: plainText
        )
    }

    // MARK: - OOXML .xlsx Parser

    public static func parseXLSX(url: URL, assetID: UUID, fallbackTitle: String) throws -> StructuredDocumentPayload {
        let reader = try ZipArchiveReader(url: url)
        return try parseXLSX(reader: reader, assetID: assetID, fallbackTitle: fallbackTitle)
    }

    public static func parseXLSX(
        reader: ZipArchiveReader,
        assetID: UUID,
        fallbackTitle: String
    ) throws -> StructuredDocumentPayload {
        let coreProps = (try? reader.readEntry("docProps/core.xml")).map(OOXMLCorePropsParser.parse) ?? .init()
        let sharedStrings: [String] = if let sstData = try reader.readEntry("xl/sharedStrings.xml") {
            XLSXSharedStringsParser.parse(sstData)
        } else {
            []
        }

        let relTargets: [String: String] = if let relData = try reader.readEntry("xl/_rels/workbook.xml.rels") {
            OOXMLRelationshipsParser.parse(relData)
        } else {
            [:]
        }

        var sheetDescriptors: [(name: String, entryPath: String)] = []
        if let wbData = try reader.readEntry("xl/workbook.xml") {
            let rawSheets = XLSXWorkbookParser.parse(wbData)
            for (idx, item) in rawSheets.enumerated() {
                if let rid = item.relID, let target = relTargets[rid] {
                    let cleanTarget = target.hasPrefix("/")
                        ? String(target.dropFirst())
                        : (target.hasPrefix("xl/") ? target : "xl/" + target)
                    if reader.contains(cleanTarget) {
                        sheetDescriptors.append((item.name, cleanTarget))
                        continue
                    }
                }
                let fallbackPath = "xl/worksheets/sheet\(idx + 1).xml"
                if reader.contains(fallbackPath) {
                    sheetDescriptors.append((item.name, fallbackPath))
                }
            }
        }

        if sheetDescriptors.isEmpty {
            let discovered = reader.entries
                .map(\.name)
                .filter { $0.hasPrefix("xl/worksheets/sheet") && $0.hasSuffix(".xml") }
                .sorted { Self.naturalSortLess($0, $1) }
            for (idx, path) in discovered.enumerated() {
                sheetDescriptors.append(("Sheet\(idx + 1)", path))
            }
        }

        var sheets: [SpreadsheetSheet] = []
        var blocks: [DocumentBlock] = []
        var plainLines: [String] = []

        for (sIdx, desc) in sheetDescriptors.enumerated() {
            guard let xmlData = try reader.readEntry(desc.entryPath) else { continue }
            let parsed = XLSXWorksheetParser.parse(
                xmlData,
                sheetName: desc.name,
                sheetIndex: sIdx,
                sharedStrings: sharedStrings
            )
            sheets.append(parsed)
            plainLines.append(desc.name)
            if !parsed.headers.isEmpty {
                plainLines.append(parsed.headers.joined(separator: "\t"))
            }
            for row in parsed.rows {
                let joined = row.values.joined(separator: "\t").trimmingCharacters(in: .whitespaces)
                if !joined.isEmpty {
                    plainLines.append(joined)
                }
            }
            var previewRows: [[String]] = []
            if !parsed.headers.isEmpty {
                previewRows.append(parsed.headers)
            }
            for r in parsed.rows.prefix(40) {
                previewRows.append(r.values)
            }
            blocks.append(DocumentBlock(
                id: "sheet-\(sIdx)",
                index: blocks.count,
                kind: .table,
                sectionTitle: desc.name,
                text: "\(desc.name)（\(parsed.rows.count) 行）",
                tableRows: previewRows,
                isProtectedComplex: true,
                protectionReason: "电子表格仅支持对比，请在表格软件中编辑公式与单元格"
            ))
        }

        let plainText = plainLines.joined(separator: "\n")
        let editor = coreProps.lastModifiedBy?.nonEmptyTrimmed ?? coreProps.creator?.nonEmptyTrimmed
        return StructuredDocumentPayload(
            assetID: assetID,
            formatFamily: DocumentFormatFamily.xlsx.rawValue,
            title: fallbackTitle,
            authorOrEditor: editor,
            wordCount: countWords(in: plainText),
            pageCount: max(1, sheets.count),
            hasTextLayer: true,
            hasNativeRevisions: false,
            isRedHeaderStyle: false,
            blocks: blocks,
            sheets: sheets,
            comments: [],
            plainText: plainText
        )
    }

    // MARK: - OOXML .pptx Parser

    public static func parsePPTX(url: URL, assetID: UUID, fallbackTitle: String) throws -> StructuredDocumentPayload {
        let reader = try ZipArchiveReader(url: url)
        let coreProps = (try? reader.readEntry("docProps/core.xml")).map(OOXMLCorePropsParser.parse) ?? .init()
        let slideEntries = reader.entries
            .map(\.name)
            .filter { $0.hasPrefix("ppt/slides/slide") && $0.hasSuffix(".xml") }
            .sorted { Self.naturalSortLess($0, $1) }

        var blocks: [DocumentBlock] = []
        var plainParts: [String] = []
        for (idx, path) in slideEntries.enumerated() {
            guard let xmlData = try reader.readEntry(path) else { continue }
            let paragraphs = PPTXSlideXMLParser.parse(xmlData)
            guard !paragraphs.isEmpty else { continue }
            let slideNo = idx + 1
            let slideTitle = paragraphs.first
            let joined = paragraphs.joined(separator: "\n")
            blocks.append(DocumentBlock(
                id: "slide-\(slideNo)",
                index: blocks.count,
                kind: .slide,
                sectionTitle: slideTitle,
                text: joined,
                pageNumber: slideNo,
                isProtectedComplex: true,
                protectionReason: "演示文稿幻灯片为受保护版式"
            ))
            plainParts.append(joined)
        }
        let plainText = plainParts.joined(separator: "\n\n")
        let editor = coreProps.lastModifiedBy?.nonEmptyTrimmed ?? coreProps.creator?.nonEmptyTrimmed
        return StructuredDocumentPayload(
            assetID: assetID,
            formatFamily: DocumentFormatFamily.pptx.rawValue,
            title: fallbackTitle,
            authorOrEditor: editor,
            wordCount: countWords(in: plainText),
            pageCount: max(1, slideEntries.count),
            hasTextLayer: !plainText.isEmpty,
            hasNativeRevisions: false,
            isRedHeaderStyle: false,
            blocks: blocks,
            sheets: [],
            comments: [],
            plainText: plainText
        )
    }

    // MARK: - .odt & .epub Parsers

    public static func parseODT(url: URL, assetID: UUID, fallbackTitle: String) throws -> StructuredDocumentPayload {
        let reader = try ZipArchiveReader(url: url)
        guard let contentXML = try reader.readEntry("content.xml") else {
            throw ZipArchiveError.invalidArchive("缺少 ODT content.xml")
        }
        let lines = GenericXMLParagraphExtractor.extract(contentXML, paragraphLocalNames: ["p", "h"])
        return buildParagraphPayload(
            lines: lines,
            formatFamily: DocumentFormatFamily.docx.rawValue,
            assetID: assetID,
            title: fallbackTitle,
            markProtected: true
        )
    }

    public static func parseEPUB(url: URL, assetID: UUID, fallbackTitle: String) throws -> StructuredDocumentPayload {
        let reader = try ZipArchiveReader(url: url)
        let htmlEntries = reader.entries
            .map(\.name)
            .filter {
                let lower = $0.lowercased()
                return lower.hasSuffix(".xhtml") || lower.hasSuffix(".html") || lower.hasSuffix(".htm")
            }
            .sorted()
        var allLines: [String] = []
        for entry in htmlEntries.prefix(80) {
            if let data = try? reader.readEntry(entry) {
                let lines = GenericXMLParagraphExtractor.extract(
                    data,
                    paragraphLocalNames: ["h1", "h2", "h3", "h4", "p", "li"]
                )
                allLines.append(contentsOf: lines)
            }
        }
        return buildParagraphPayload(
            lines: allLines,
            formatFamily: DocumentFormatFamily.epub.rawValue,
            assetID: assetID,
            title: fallbackTitle,
            markProtected: true
        )
    }

    // MARK: - PDFKit Full-Page Parser + Vision Scanned PDF OCR

    public static func parsePDF(url: URL, assetID: UUID, fallbackTitle: String) -> StructuredDocumentPayload {
        guard let pdf = PDFDocument(url: url) else {
            return StructuredDocumentPayload(
                assetID: assetID,
                formatFamily: DocumentFormatFamily.pdf.rawValue,
                title: fallbackTitle,
                pageCount: 1,
                hasTextLayer: false
            )
        }

        let pageCount = max(1, pdf.pageCount)
        let maxPagesToExtract = min(pdf.pageCount, 400)
        var blocks: [DocumentBlock] = []
        var plainPages: [String] = []
        var nonSpaceScalarCount = 0
        var activeSection: String?

        for pageIdx in 0..<maxPagesToExtract {
            guard let rawPageText = pdf.page(at: pageIdx)?.string else { continue }
            let normalized = DocumentTextDecoder.normalizeLineEndings(rawPageText)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty else { continue }
            nonSpaceScalarCount += normalized.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) }.count
            plainPages.append(normalized)

            let paragraphs = splitPlainParagraphs(normalized)
            for para in paragraphs {
                if let level = detectChineseOrNumberedHeadingLevel(para) {
                    activeSection = para
                    blocks.append(DocumentBlock(
                        id: "pdf-p\(pageIdx + 1)-\(blocks.count)",
                        index: blocks.count,
                        kind: .heading,
                        headingLevel: level,
                        sectionTitle: para,
                        text: para,
                        pageNumber: pageIdx + 1,
                        isProtectedComplex: true,
                        protectionReason: "PDF 页面为固定版式（只读对比）"
                    ))
                } else {
                    blocks.append(DocumentBlock(
                        id: "pdf-p\(pageIdx + 1)-\(blocks.count)",
                        index: blocks.count,
                        kind: .paragraph,
                        sectionTitle: activeSection,
                        text: para,
                        pageNumber: pageIdx + 1,
                        isProtectedComplex: true,
                        protectionReason: "PDF 页面为固定版式（只读对比）"
                    ))
                }
            }
        }

        let sampledPages = max(1, min(pdf.pageCount, 10))
        let hasTextLayer = nonSpaceScalarCount >= max(12, sampledPages * 8)
        let plainText = plainPages.joined(separator: "\n\n")
        let author = (pdf.documentAttributes?[PDFDocumentAttribute.authorAttribute] as? String)?.nonEmptyTrimmed
        let isRedHeader = looksLikeOfficialRedHeaderTitle(title: fallbackTitle, firstBlocks: Array(blocks.prefix(3)))

        return StructuredDocumentPayload(
            assetID: assetID,
            formatFamily: DocumentFormatFamily.pdf.rawValue,
            title: fallbackTitle,
            authorOrEditor: author,
            wordCount: countWords(in: plainText),
            pageCount: pageCount,
            hasTextLayer: hasTextLayer,
            hasNativeRevisions: false,
            isRedHeaderStyle: isRedHeader,
            blocks: blocks,
            sheets: [],
            comments: [],
            plainText: plainText
        )
    }

    @concurrent
    public static func ocrScannedPDF(
        url: URL,
        assetID: UUID,
        fallbackTitle: String,
        maxPages: Int = 24
    ) async -> StructuredDocumentPayload {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }

        guard let pdf = PDFDocument(url: url), pdf.pageCount > 0 else {
            return StructuredDocumentPayload(
                assetID: assetID,
                formatFamily: DocumentFormatFamily.pdf.rawValue,
                title: fallbackTitle,
                pageCount: 1,
                hasTextLayer: false
            )
        }

        let totalPages = pdf.pageCount
        let limit = min(totalPages, maxPages)
        var blocks: [DocumentBlock] = []
        var plainPages: [String] = []
        var activeSection: String?

        for pageIdx in 0..<limit {
            if Task.isCancelled { break }
            guard let page = pdf.page(at: pageIdx),
                  let cgImage = renderPDFPageImage(page, maxSide: 1_800) else {
                continue
            }
            let lines = recognizeTextLines(in: cgImage)
            guard !lines.isEmpty else { continue }
            let joinedPage = lines.joined(separator: "\n")
            plainPages.append(joinedPage)
            for line in splitPlainParagraphs(joinedPage) {
                if let level = detectChineseOrNumberedHeadingLevel(line) {
                    activeSection = line
                    blocks.append(DocumentBlock(
                        id: "ocr-p\(pageIdx + 1)-\(blocks.count)",
                        index: blocks.count,
                        kind: .heading,
                        headingLevel: level,
                        sectionTitle: line,
                        text: line,
                        pageNumber: pageIdx + 1,
                        isProtectedComplex: true,
                        protectionReason: "扫描件 OCR 识别文本（只读对比）"
                    ))
                } else {
                    blocks.append(DocumentBlock(
                        id: "ocr-p\(pageIdx + 1)-\(blocks.count)",
                        index: blocks.count,
                        kind: .paragraph,
                        sectionTitle: activeSection,
                        text: line,
                        pageNumber: pageIdx + 1,
                        isProtectedComplex: true,
                        protectionReason: "扫描件 OCR 识别文本（只读对比）"
                    ))
                }
            }
        }

        let plainText = plainPages.joined(separator: "\n\n")
        return StructuredDocumentPayload(
            assetID: assetID,
            formatFamily: DocumentFormatFamily.pdf.rawValue,
            title: fallbackTitle,
            wordCount: countWords(in: plainText),
            pageCount: totalPages,
            hasTextLayer: false,
            hasNativeRevisions: false,
            isRedHeaderStyle: looksLikeOfficialRedHeaderTitle(title: fallbackTitle, firstBlocks: Array(blocks.prefix(3))),
            blocks: blocks,
            sheets: [],
            comments: [],
            plainText: plainText
        )
    }

    public static func renderPDFPageImage(_ page: PDFPage, maxSide: CGFloat = 1_600) -> CGImage? {
        guard let pageRef = page.pageRef else { return nil }
        let bounds = page.bounds(for: .cropBox)
        let longest = max(bounds.width, bounds.height)
        guard bounds.width.isFinite, bounds.height.isFinite, bounds.width > 0, bounds.height > 0, longest > 1e-4 else {
            return nil
        }
        let scale = maxSide / longest
        let width = max(1, min(4_096, Int((bounds.width * scale).rounded())))
        let height = max(1, min(4_096, Int((bounds.height * scale).rounded())))
        guard let ctx = MediaArtwork.context(width: width, height: height) else { return nil }
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(rect)
        ctx.concatenate(pageRef.getDrawingTransform(.cropBox, rect: rect, rotate: 0, preserveAspectRatio: true))
        ctx.drawPDFPage(pageRef)
        return ctx.makeImage()
    }

    private static func recognizeTextLines(in image: CGImage) -> [String] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"]
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try? handler.perform([request])
        let observations = request.results ?? []
        let sorted = observations.sorted { lhs, rhs in
            let ly = lhs.boundingBox.midY
            let ry = rhs.boundingBox.midY
            if abs(ly - ry) > 0.018 { return ly > ry }
            return lhs.boundingBox.minX < rhs.boundingBox.minX
        }
        return sorted.compactMap { $0.topCandidates(1).first?.string.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    // MARK: - Markdown, CSV & Plain Text Parsers

    public static func parseMarkdown(data: Data, assetID: UUID, fallbackTitle: String) -> StructuredDocumentPayload {
        let raw = DocumentTextDecoder.decode(data)
        let mdBlocks = MarkdownDocumentParser.parse(raw)
        var blocks: [DocumentBlock] = []
        var activeSection: String?

        for md in mdBlocks {
            switch md {
            case .heading(_, let level, let text, _):
                activeSection = text
                let hashes = String(repeating: "#", count: max(1, min(6, level)))
                blocks.append(DocumentBlock(
                    id: "md-\(blocks.count)",
                    index: blocks.count,
                    kind: .heading,
                    headingLevel: level,
                    sectionTitle: text,
                    text: "\(hashes) \(text)"
                ))
            case .paragraph(_, let text, _):
                blocks.append(DocumentBlock(
                    id: "md-\(blocks.count)",
                    index: blocks.count,
                    kind: .paragraph,
                    sectionTitle: activeSection,
                    text: text
                ))
            case .listItem(_, let marker, let indent, let text):
                let pad = String(repeating: "  ", count: max(0, indent))
                let prefix = switch marker {
                case .bullet: "- "
                case .ordered(let n): "\(n). "
                case .task(let checked): checked ? "- [x] " : "- [ ] "
                }
                blocks.append(DocumentBlock(
                    id: "md-\(blocks.count)",
                    index: blocks.count,
                    kind: .listItem,
                    sectionTitle: activeSection,
                    text: "\(pad)\(prefix)\(text)"
                ))
            case .code(_, let lang, let content):
                blocks.append(DocumentBlock(
                    id: "md-\(blocks.count)",
                    index: blocks.count,
                    kind: .codeBlock,
                    sectionTitle: activeSection,
                    text: "```\(lang)\n\(content)\n```"
                ))
            case .quote(_, _, let text):
                let quoted = text.components(separatedBy: "\n").map { "> \($0)" }.joined(separator: "\n")
                blocks.append(DocumentBlock(
                    id: "md-\(blocks.count)",
                    index: blocks.count,
                    kind: .quote,
                    sectionTitle: activeSection,
                    text: quoted
                ))
            case .table(_, let headers, _, let rows):
                var allRows: [[String]] = []
                if !headers.isEmpty { allRows.append(headers) }
                allRows.append(contentsOf: rows)
                let mdTable = Self.serializeMarkdownTable(headers: headers, rows: rows)
                blocks.append(DocumentBlock(
                    id: "md-\(blocks.count)",
                    index: blocks.count,
                    kind: .table,
                    sectionTitle: activeSection,
                    text: mdTable,
                    tableRows: allRows
                ))
            case .details(_, let summary, let children):
                let childText = children.compactMap { child -> String? in
                    if case .paragraph(_, let t, _) = child { return t }
                    return nil
                }.joined(separator: "\n")
                let combined = childText.isEmpty ? summary : "\(summary)\n\(childText)"
                blocks.append(DocumentBlock(
                    id: "md-\(blocks.count)",
                    index: blocks.count,
                    kind: .paragraph,
                    sectionTitle: activeSection,
                    text: combined
                ))
            case .image, .imageRow, .divider:
                break
            }
        }

        let wordCount = countWords(in: raw)
        return StructuredDocumentPayload(
            assetID: assetID,
            formatFamily: DocumentFormatFamily.markdown.rawValue,
            title: fallbackTitle,
            wordCount: wordCount,
            pageCount: max(1, (wordCount + 649) / 650),
            hasTextLayer: true,
            hasNativeRevisions: false,
            isRedHeaderStyle: false,
            blocks: blocks,
            sheets: [],
            comments: [],
            plainText: raw
        )
    }

    public static func parsePlainText(data: Data, assetID: UUID, fallbackTitle: String) -> StructuredDocumentPayload {
        let decoded = DocumentTextDecoder.decode(data)
        let paragraphs = splitPlainParagraphs(decoded)
        var blocks: [DocumentBlock] = []
        var activeSection: String?
        for para in paragraphs {
            if let level = detectChineseOrNumberedHeadingLevel(para) {
                activeSection = para
                blocks.append(DocumentBlock(
                    id: "txt-\(blocks.count)",
                    index: blocks.count,
                    kind: .heading,
                    headingLevel: level,
                    sectionTitle: para,
                    text: para
                ))
            } else {
                blocks.append(DocumentBlock(
                    id: "txt-\(blocks.count)",
                    index: blocks.count,
                    kind: .paragraph,
                    sectionTitle: activeSection,
                    text: para
                ))
            }
        }
        let wordCount = countWords(in: decoded)
        return StructuredDocumentPayload(
            assetID: assetID,
            formatFamily: DocumentFormatFamily.plainText.rawValue,
            title: fallbackTitle,
            wordCount: wordCount,
            pageCount: max(1, (wordCount + 649) / 650),
            hasTextLayer: true,
            hasNativeRevisions: false,
            isRedHeaderStyle: looksLikeOfficialRedHeaderTitle(title: fallbackTitle, firstBlocks: Array(blocks.prefix(3))),
            blocks: blocks,
            sheets: [],
            comments: [],
            plainText: decoded
        )
    }

    public static func parseCSV(data: Data, assetID: UUID, fallbackTitle: String) -> StructuredDocumentPayload {
        let decoded = DocumentTextDecoder.decode(data)
        let parsedRows = parseCSVRows(decoded)
        let colCount = parsedRows.map(\.count).max() ?? 0
        let headers = parsedRows.first.map { padRow($0, to: colCount) } ?? []
        var sheetRows: [SpreadsheetRow] = []
        for (idx, rawRow) in parsedRows.dropFirst().enumerated() {
            sheetRows.append(SpreadsheetRow(
                rowNumber: idx + 2,
                values: padRow(rawRow, to: colCount)
            ))
        }
        let pkCol = SpreadsheetPrimaryKeyDetector.suggestPrimaryKeyColumn(headers: headers, rows: sheetRows)
        let sheet = SpreadsheetSheet(
            name: fallbackTitle,
            sheetIndex: 0,
            headers: headers,
            rows: sheetRows,
            columnCount: colCount,
            suggestedPrimaryKeyCol: pkCol
        )
        let previewRows = ([headers] + sheetRows.prefix(40).map(\.values)).filter { !$0.isEmpty }
        let block = DocumentBlock(
            id: "csv-0",
            index: 0,
            kind: .table,
            sectionTitle: fallbackTitle,
            text: "\(fallbackTitle)（\(sheetRows.count) 行）",
            tableRows: previewRows,
            isProtectedComplex: true,
            protectionReason: "CSV 数据表请在表格工具中编辑"
        )
        return StructuredDocumentPayload(
            assetID: assetID,
            formatFamily: DocumentFormatFamily.xlsx.rawValue,
            title: fallbackTitle,
            wordCount: countWords(in: decoded),
            pageCount: 1,
            hasTextLayer: true,
            hasNativeRevisions: false,
            isRedHeaderStyle: false,
            blocks: [block],
            sheets: [sheet],
            comments: [],
            plainText: decoded
        )
    }

    // MARK: - Legacy Office Fallback (.doc / .wps / .xls / .et / .rtf)

    private static func parseLegacyOrFallbackDocument(
        url: URL,
        ext: String,
        assetID: UUID,
        fallbackTitle: String
    ) async -> StructuredDocumentPayload {
        // Some `.wps` / `.et` / `.dps` files created by modern suites are actually OOXML ZIPs!
        if let reader = try? ZipArchiveReader(url: url) {
            if reader.contains("word/document.xml"),
               let docx = try? parseDOCX(reader: reader, assetID: assetID, fallbackTitle: fallbackTitle) {
                return docx
            }
            if reader.contains("xl/workbook.xml"),
               let xlsx = try? parseXLSX(reader: reader, assetID: assetID, fallbackTitle: fallbackTitle) {
                return xlsx
            }
        }

        var extractedText = ""
        #if os(macOS)
        if ["doc", "rtf", "odt", "wps"].contains(ext) {
            extractedText = await runMacOSTextutilExtract(url: url)
        }
        if extractedText.isEmpty, ext == "rtf",
           let data = try? Data(contentsOf: url),
           let attr = try? NSAttributedString(
               data: data,
               options: [.documentType: NSAttributedString.DocumentType.rtf],
               documentAttributes: nil
           ) {
            extractedText = attr.string
        }
        #endif

        if extractedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let rawData = try? Data(contentsOf: url, options: [.mappedIfSafe]) {
            if ext == "rtf" {
                extractedText = stripSimpleRTF(DocumentTextDecoder.decode(rawData))
            } else {
                extractedText = extractReadableRunsFromBinaryDocument(rawData)
            }
        }

        let family = DocumentFormatFamily.detect(fileExtension: ext).rawValue
        return buildParagraphPayload(
            lines: splitPlainParagraphs(extractedText),
            formatFamily: family,
            assetID: assetID,
            title: fallbackTitle,
            markProtected: true
        )
    }

    #if os(macOS)
    private static func runMacOSTextutilExtract(url: URL) async -> String {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/textutil") else { return "" }
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: "/usr/bin/textutil")
                proc.arguments = ["-convert", "txt", "-stdout", url.path]
                let outPipe = Pipe()
                proc.standardOutput = outPipe
                proc.standardError = FileHandle.nullDevice
                do {
                    try proc.run()
                    let data = outPipe.fileHandleForReading.readDataToEndOfFile()
                    proc.waitUntilExit()
                    if proc.terminationStatus == 0, let str = String(data: data, encoding: .utf8) {
                        continuation.resume(returning: DocumentTextDecoder.normalizeLineEndings(str))
                    } else {
                        continuation.resume(returning: "")
                    }
                } catch {
                    continuation.resume(returning: "")
                }
            }
        }
    }
    #endif

    // MARK: - Shared Formatting & Structure Helpers

    private static func buildParagraphPayload(
        lines: [String],
        formatFamily: String,
        assetID: UUID,
        title: String,
        markProtected: Bool
    ) -> StructuredDocumentPayload {
        var blocks: [DocumentBlock] = []
        var activeSection: String?
        for raw in lines {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if let level = detectChineseOrNumberedHeadingLevel(trimmed) {
                activeSection = trimmed
                blocks.append(DocumentBlock(
                    id: "blk-\(blocks.count)",
                    index: blocks.count,
                    kind: .heading,
                    headingLevel: level,
                    sectionTitle: trimmed,
                    text: trimmed,
                    isProtectedComplex: markProtected,
                    protectionReason: markProtected ? "旧版或只读文档格式，请使用系统默认应用编辑" : nil
                ))
            } else {
                blocks.append(DocumentBlock(
                    id: "blk-\(blocks.count)",
                    index: blocks.count,
                    kind: .paragraph,
                    sectionTitle: activeSection,
                    text: trimmed,
                    isProtectedComplex: markProtected,
                    protectionReason: markProtected ? "旧版或只读文档格式，请使用系统默认应用编辑" : nil
                ))
            }
        }
        let plainText = blocks.map(\.text).joined(separator: "\n")
        let words = countWords(in: plainText)
        return StructuredDocumentPayload(
            assetID: assetID,
            formatFamily: formatFamily,
            title: title,
            wordCount: words,
            pageCount: max(1, (words + 649) / 650),
            hasTextLayer: !plainText.isEmpty,
            hasNativeRevisions: false,
            isRedHeaderStyle: looksLikeOfficialRedHeaderTitle(title: title, firstBlocks: Array(blocks.prefix(3))),
            blocks: blocks,
            sheets: [],
            comments: [],
            plainText: plainText
        )
    }

    static func splitPlainParagraphs(_ text: String) -> [String] {
        let lines = DocumentTextDecoder.normalizeLineEndings(text).components(separatedBy: "\n")
        var out: [String] = []
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                out.append(trimmed)
            }
        }
        return out
    }

    static func detectChineseOrNumberedHeadingLevel(_ line: String) -> Int? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count <= 48, !trimmed.hasSuffix("。"), !trimmed.hasSuffix("；") else { return nil }
        if trimmed.range(of: #"^[一二三四五六七八九十百]+、"#, options: .regularExpression) != nil
            || trimmed.range(of: #"^第[一二三四五六七八九十百\d]+[章节部分篇]\b"#, options: .regularExpression) != nil {
            return 1
        }
        if trimmed.range(of: #"^[（(][一二三四五六七八九十]+[)）]"#, options: .regularExpression) != nil {
            return 2
        }
        if trimmed.range(of: #"^\d{1,2}\.\d{1,2}(?:\.\d{1,2})?\s+\S"#, options: .regularExpression) != nil {
            return 3
        }
        return nil
    }

    private static func looksLikeOfficialRedHeaderTitle(title: String, firstBlocks: [DocumentBlock]) -> Bool {
        let officialKeywords = ["关于", "通知", "通报", "请示", "汇报", "方案", "决定", "意见", "函", "纪要", "办法", "规定"]
        let headText = ([title] + firstBlocks.map(\.text)).joined(separator: " ")
        var hits = 0
        for kw in officialKeywords where headText.contains(kw) {
            hits += 1
        }
        return hits >= 2
    }

    private static func serializeMarkdownTable(headers: [String], rows: [[String]]) -> String {
        guard !headers.isEmpty else {
            return rows.map { "| " + $0.joined(separator: " | ") + " |" }.joined(separator: "\n")
        }
        var lines = [
            "| " + headers.joined(separator: " | ") + " |",
            "| " + headers.map { _ in "---" }.joined(separator: " | ") + " |"
        ]
        for row in rows {
            lines.append("| " + row.joined(separator: " | ") + " |")
        }
        return lines.joined(separator: "\n")
    }

    private static func padRow(_ row: [String], to count: Int) -> [String] {
        if row.count >= count { return row }
        return row + Array(repeating: "", count: count - row.count)
    }

    private static func parseCSVRows(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        var currentRow: [String] = []
        var currentCell = ""
        var inQuotes = false
        let chars = Array(text)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if inQuotes {
                if c == "\"" {
                    if i + 1 < chars.count && chars[i + 1] == "\"" {
                        currentCell.append("\"")
                        i += 2
                        continue
                    } else {
                        inQuotes = false
                    }
                } else {
                    currentCell.append(c)
                }
            } else {
                if c == "\"" {
                    inQuotes = true
                } else if c == "," {
                    currentRow.append(currentCell.trimmingCharacters(in: .whitespaces))
                    currentCell = ""
                } else if c == "\n" {
                    currentRow.append(currentCell.trimmingCharacters(in: .whitespaces))
                    currentCell = ""
                    if currentRow.contains(where: { !$0.isEmpty }) {
                        rows.append(currentRow)
                    }
                    currentRow = []
                } else {
                    currentCell.append(c)
                }
            }
            i += 1
        }
        if !currentCell.isEmpty || !currentRow.isEmpty {
            currentRow.append(currentCell.trimmingCharacters(in: .whitespaces))
            if currentRow.contains(where: { !$0.isEmpty }) {
                rows.append(currentRow)
            }
        }
        return rows
    }

    private static func stripSimpleRTF(_ raw: String) -> String {
        var out = raw
        out = out.replacingOccurrences(of: #"\\par\b\s*"#, with: "\n", options: .regularExpression)
        out = out.replacingOccurrences(of: #"\\[a-zA-Z]+-?\d*\s?"#, with: "", options: .regularExpression)
        out = out.replacingOccurrences(of: "[{}]", with: "", options: .regularExpression)
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func extractReadableRunsFromBinaryDocument(_ data: Data) -> String {
        // OLE2 `.doc` / `.wps` / `.xls` store Unicode text streams in UTF-16LE runs; scan contiguous printable runs.
        guard data.count >= 4 else { return "" }
        var runs: [String] = []
        var currentScalars: [UnicodeScalar] = []
        let limit = min(data.count - 1, 4 * 1024 * 1024)
        var idx = 0
        while idx + 1 < limit {
            let lo = UInt16(data[data.startIndex + idx])
            let hi = UInt16(data[data.startIndex + idx + 1])
            let code = lo | (hi << 8)
            let isCJK = (0x4E00...0x9FFF).contains(code) || (0x3000...0x303F).contains(code) || (0xFF00...0xFFEF).contains(code)
            let isPrintableASCII = (0x20...0x7E).contains(code) || code == 0x0A || code == 0x09
            if (isCJK || isPrintableASCII), let scalar = UnicodeScalar(code) {
                currentScalars.append(scalar)
            } else {
                if currentScalars.count >= 4 {
                    let candidate = String(String.UnicodeScalarView(currentScalars))
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if candidate.count >= 4 && SearchText.containsHan(candidate) {
                        runs.append(candidate)
                    }
                }
                currentScalars.removeAll(keepingCapacity: true)
            }
            idx += 2
        }
        if currentScalars.count >= 4 {
            let candidate = String(String.UnicodeScalarView(currentScalars)).trimmingCharacters(in: .whitespacesAndNewlines)
            if candidate.count >= 4 && SearchText.containsHan(candidate) {
                runs.append(candidate)
            }
        }
        return runs.joined(separator: "\n")
    }

    static func naturalSortLess(_ lhs: String, _ rhs: String) -> Bool {
        lhs.localizedStandardCompare(rhs) == .orderedAscending
    }
}

// MARK: - OOXML Sub-Parsers (Foundation.XMLParser)

nonisolated func xmlLocalName(_ rawName: String) -> String {
    if let colon = rawName.lastIndex(of: ":") {
        return String(rawName[rawName.index(after: colon)...])
    }
    return rawName
}

nonisolated func xmlAttr(_ dict: [String: String], local key: String) -> String? {
    if let exact = dict[key] { return exact }
    if let wPrefixed = dict["w:\(key)"] { return wPrefixed }
    if let rPrefixed = dict["r:\(key)"] { return rPrefixed }
    for (k, v) in dict where xmlLocalName(k) == key {
        return v
    }
    return nil
}

private nonisolated final class OOXMLCorePropsParser: NSObject, XMLParserDelegate {
    struct Props {
        var title: String?
        var creator: String?
        var lastModifiedBy: String?
    }

    private var currentTag = ""
    private var buffer = ""
    private var props = Props()

    static func parse(_ data: Data) -> Props {
        let delegate = OOXMLCorePropsParser()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = false
        parser.delegate = delegate
        _ = parser.parse()
        return delegate.props
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        currentTag = xmlLocalName(elementName)
        buffer = ""
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        buffer.append(string)
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let local = xmlLocalName(elementName)
        let trimmed = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            switch local {
            case "title": props.title = trimmed
            case "creator": props.creator = trimmed
            case "lastModifiedBy": props.lastModifiedBy = trimmed
            default: break
            }
        }
        currentTag = ""
        buffer = ""
    }
}

private nonisolated final class OOXMLAppPropsParser: NSObject, XMLParserDelegate {
    private var currentTag = ""
    private var buffer = ""
    private var pages: Int?

    static func parsePages(_ data: Data) -> Int? {
        let delegate = OOXMLAppPropsParser()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = false
        parser.delegate = delegate
        _ = parser.parse()
        return delegate.pages
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        currentTag = xmlLocalName(elementName)
        buffer = ""
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if currentTag == "Pages" { buffer.append(string) }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if xmlLocalName(elementName) == "Pages",
           let n = Int(buffer.trimmingCharacters(in: .whitespacesAndNewlines)), n > 0 {
            pages = n
        }
        currentTag = ""
        buffer = ""
    }
}

private nonisolated final class OOXMLRelationshipsParser: NSObject, XMLParserDelegate {
    private var map: [String: String] = [:]

    static func parse(_ data: Data) -> [String: String] {
        let delegate = OOXMLRelationshipsParser()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = false
        parser.delegate = delegate
        _ = parser.parse()
        return delegate.map
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        if xmlLocalName(elementName) == "Relationship",
           let id = attributeDict["Id"],
           let target = attributeDict["Target"] {
            map[id] = target
        }
    }
}

private nonisolated final class DOCXCommentsXMLParser: NSObject, XMLParserDelegate {
    private var comments: [DocumentComment] = []
    private var activeID: String?
    private var activeAuthor = ""
    private var activeDate: String?
    private var inTextTag = false
    private var paragraphTexts: [String] = []
    private var currentPara = ""

    static func parse(_ data: Data) -> [DocumentComment] {
        let delegate = DOCXCommentsXMLParser()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = false
        parser.delegate = delegate
        _ = parser.parse()
        return delegate.comments
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        let local = xmlLocalName(elementName)
        switch local {
        case "comment":
            activeID = xmlAttr(attributeDict, local: "id") ?? "\(comments.count)"
            activeAuthor = xmlAttr(attributeDict, local: "author") ?? "批注人"
            activeDate = xmlAttr(attributeDict, local: "date")
            paragraphTexts = []
            currentPara = ""
        case "p":
            currentPara = ""
        case "t", "delText":
            if activeID != nil { inTextTag = true }
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inTextTag { currentPara.append(string) }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let local = xmlLocalName(elementName)
        switch local {
        case "t", "delText":
            inTextTag = false
        case "p":
            let trimmed = currentPara.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { paragraphTexts.append(trimmed) }
            currentPara = ""
        case "comment":
            if let id = activeID {
                let text = paragraphTexts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    comments.append(DocumentComment(
                        id: id,
                        author: activeAuthor,
                        dateText: activeDate,
                        text: text
                    ))
                }
            }
            activeID = nil
        default:
            break
        }
    }
}

private nonisolated final class DOCXDocumentXMLParser: NSObject, XMLParserDelegate {
    struct Result {
        var blocks: [DocumentBlock] = []
        var hasNativeRevisions = false
        var hasRedHeaderRun = false
        var explicitPageBreaks = 0
    }

    private var result = Result()
    private var inBody = false
    private var bodyDepth = 0
    private var sdtDepth = 0

    // Top-level `<w:body>/<w:p>` tracking for surgical 2-Way merge
    private var nextTopLevelParagraphXMLIndex = 0
    private var currentTopLevelParagraphXMLIndex: Int?

    // Paragraph state (for top-level paragraphs when tableDepth == 0)
    private var inTopParagraph = false
    private var paraDepth = 0
    private var paraText = ""
    private var paraHeadingLevel: Int?
    private var paraIsList = false
    private var paraRevisions: [DocumentTrackRevisionSpan] = []
    private var paraCommentIDs: [String] = []
    private var paraProtected = false
    private var paraProtectionReasons: [String] = []

    // Active revision wrapper (`<w:ins>` / `<w:del>`)
    private var insDepth = 0
    private var insAuthor: String?
    private var insDate: String?
    private var insBuffer = ""

    private var delDepth = 0
    private var delAuthor: String?
    private var delDate: String?
    private var delBuffer = ""

    // Text run capture
    private var inWT = false
    private var inWDelText = false

    // Table state (`tableDepth >= 1`)
    private var tableDepth = 0
    private var currentTableRows: [[String]] = []
    private var currentRowCells: [String] = []
    private var currentCellParagraphs: [String] = []
    private var currentCellParaBuffer = ""
    private var tableHasComplexMerge = false
    private var tableCommentIDs: [String] = []
    private var tableRevisions: [DocumentTrackRevisionSpan] = []

    private var activeSectionTitle: String?
    private var currentPage = 1

    static func parse(_ data: Data) -> Result {
        let delegate = DOCXDocumentXMLParser()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = false
        parser.delegate = delegate
        _ = parser.parse()
        return delegate.result
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        let local = xmlLocalName(elementName)
        if local == "body" && !inBody {
            inBody = true
            bodyDepth = 0
            return
        }
        guard inBody else { return }
        bodyDepth += 1

        if local == "sdt" {
            sdtDepth += 1
        }

        // Track tables
        if local == "tbl" {
            tableDepth += 1
            if tableDepth == 1 {
                currentTableRows = []
                tableHasComplexMerge = false
                tableCommentIDs = []
                tableRevisions = []
            } else {
                tableHasComplexMerge = true
            }
            return
        }

        if tableDepth > 0 {
            handleTableElementStart(local: local, attributes: attributeDict)
            return
        }

        // Top-level body paragraph (`<w:body>/<w:p>` occurs at `bodyDepth == 1 && sdtDepth == 0`)
        if local == "p" && !inTopParagraph {
            inTopParagraph = true
            paraDepth = 1
            if bodyDepth == 1 && sdtDepth == 0 {
                currentTopLevelParagraphXMLIndex = nextTopLevelParagraphXMLIndex
                nextTopLevelParagraphXMLIndex += 1
                paraProtected = false
                paraProtectionReasons = []
            } else {
                currentTopLevelParagraphXMLIndex = nil
                paraProtected = true
                paraProtectionReasons = ["结构化内容控件（SDT）段落"]
            }
            paraText = ""
            paraHeadingLevel = nil
            paraIsList = false
            paraRevisions = []
            paraCommentIDs = []
            return
        }

        guard inTopParagraph else { return }
        paraDepth += 1

        switch local {
        case "pStyle":
            if let val = xmlAttr(attributeDict, local: "val") {
                if let lvl = Self.headingLevel(fromStyle: val) {
                    paraHeadingLevel = lvl
                }
            }
        case "outlineLvl":
            if let val = xmlAttr(attributeDict, local: "val"), let n = Int(val), (0...5).contains(n) {
                paraHeadingLevel = min(paraHeadingLevel ?? (n + 1), n + 1)
            }
        case "numPr":
            paraIsList = true
        case "color":
            if result.blocks.count < 4,
               let hex = xmlAttr(attributeDict, local: "val")?.uppercased(),
               Self.isOfficialRedColorHex(hex) {
                result.hasRedHeaderRun = true
            }
        case "ins":
            result.hasNativeRevisions = true
            insDepth += 1
            if insDepth == 1 {
                insAuthor = xmlAttr(attributeDict, local: "author")
                insDate = xmlAttr(attributeDict, local: "date")
                insBuffer = ""
            }
        case "del":
            result.hasNativeRevisions = true
            delDepth += 1
            if delDepth == 1 {
                delAuthor = xmlAttr(attributeDict, local: "author")
                delDate = xmlAttr(attributeDict, local: "date")
                delBuffer = ""
            }
        case "t":
            if delDepth == 0 {
                inWT = true
            }
        case "delText":
            inWDelText = true
        case "tab":
            if delDepth == 0 { paraText.append("\t") }
        case "br", "cr":
            if let brType = xmlAttr(attributeDict, local: "type"), brType == "page" {
                result.explicitPageBreaks += 1
                currentPage += 1
            } else if delDepth == 0 {
                paraText.append("\n")
            }
        case "lastRenderedPageBreak":
            currentPage += 1
        case "commentRangeStart", "commentReference":
            if let cid = xmlAttr(attributeDict, local: "id"), !paraCommentIDs.contains(cid) {
                paraCommentIDs.append(cid)
            }
        case "fldChar", "instrText":
            markParaProtected("包含 Word 复杂域代码（fldComplex）")
        case "relIds":
            markParaProtected("包含 SmartArt 图形结构")
        case "OLEObject", "object":
            markParaProtected("包含嵌入 OLE 对象")
        case "drawing", "pict":
            markParaProtected("包含内嵌图形或印章对象")
        case "oMath", "oMathPara":
            markParaProtected("包含公式对象")
        case "sectPr":
            markParaProtected("包含分节符与版面页眉配置")
        default:
            break
        }
    }

    private func handleTableElementStart(local: String, attributes: [String: String]) {
        guard tableDepth == 1 else { return }
        switch local {
        case "tr":
            currentRowCells = []
        case "tc":
            currentCellParagraphs = []
            currentCellParaBuffer = ""
        case "p":
            currentCellParaBuffer = ""
        case "vMerge", "gridSpan":
            tableHasComplexMerge = true
        case "ins":
            result.hasNativeRevisions = true
            insDepth += 1
            if insDepth == 1 {
                insAuthor = xmlAttr(attributes, local: "author")
                insDate = xmlAttr(attributes, local: "date")
                insBuffer = ""
            }
        case "del":
            result.hasNativeRevisions = true
            delDepth += 1
            if delDepth == 1 {
                delAuthor = xmlAttr(attributes, local: "author")
                delDate = xmlAttr(attributes, local: "date")
                delBuffer = ""
            }
        case "t":
            if delDepth == 0 { inWT = true }
        case "delText":
            inWDelText = true
        case "commentRangeStart", "commentReference":
            if let cid = xmlAttr(attributes, local: "id"), !tableCommentIDs.contains(cid) {
                tableCommentIDs.append(cid)
            }
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if tableDepth == 1 {
            if inWT {
                currentCellParaBuffer.append(string)
                if insDepth > 0 { insBuffer.append(string) }
            } else if inWDelText && delDepth > 0 {
                delBuffer.append(string)
            }
            return
        }
        guard inTopParagraph else { return }
        if inWT {
            paraText.append(string)
            if insDepth > 0 { insBuffer.append(string) }
        } else if inWDelText && delDepth > 0 {
            delBuffer.append(string)
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let local = xmlLocalName(elementName)
        if local == "body" && inBody && bodyDepth == 0 {
            inBody = false
            return
        }
        guard inBody else { return }
        defer { bodyDepth = max(0, bodyDepth - 1) }

        if local == "sdt" {
            sdtDepth = max(0, sdtDepth - 1)
        }

        if local == "tbl" && tableDepth > 0 {
            if tableDepth == 1 {
                finalizeTopLevelTable()
            }
            tableDepth -= 1
            return
        }

        if tableDepth > 0 {
            handleTableElementEnd(local: local)
            return
        }

        guard inTopParagraph else { return }
        paraDepth -= 1

        switch local {
        case "t":
            inWT = false
        case "delText":
            inWDelText = false
        case "ins":
            if insDepth == 1 {
                let text = insBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    paraRevisions.append(DocumentTrackRevisionSpan(
                        kind: .inserted,
                        text: text,
                        author: insAuthor,
                        dateText: insDate
                    ))
                }
                insBuffer = ""
            }
            insDepth = max(0, insDepth - 1)
        case "del":
            if delDepth == 1 {
                let text = delBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    paraRevisions.append(DocumentTrackRevisionSpan(
                        kind: .deleted,
                        text: text,
                        author: delAuthor,
                        dateText: delDate
                    ))
                }
                delBuffer = ""
            }
            delDepth = max(0, delDepth - 1)
        case "p" where paraDepth == 0:
            finalizeTopLevelParagraph()
            inTopParagraph = false
        default:
            break
        }
    }

    private func handleTableElementEnd(local: String) {
        guard tableDepth == 1 else { return }
        switch local {
        case "t":
            inWT = false
        case "delText":
            inWDelText = false
        case "ins":
            if insDepth == 1 {
                let text = insBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    tableRevisions.append(DocumentTrackRevisionSpan(kind: .inserted, text: text, author: insAuthor, dateText: insDate))
                }
                insBuffer = ""
            }
            insDepth = max(0, insDepth - 1)
        case "del":
            if delDepth == 1 {
                let text = delBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    tableRevisions.append(DocumentTrackRevisionSpan(kind: .deleted, text: text, author: delAuthor, dateText: delDate))
                }
                delBuffer = ""
            }
            delDepth = max(0, delDepth - 1)
        case "p":
            let clean = currentCellParaBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
            if !clean.isEmpty {
                currentCellParagraphs.append(clean)
            }
            currentCellParaBuffer = ""
        case "tc":
            currentRowCells.append(currentCellParagraphs.joined(separator: "\n"))
            currentCellParagraphs = []
        case "tr":
            if !currentRowCells.isEmpty {
                currentTableRows.append(currentRowCells)
            }
            currentRowCells = []
        default:
            break
        }
    }

    private func finalizeTopLevelParagraph() {
        let trimmed = paraText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !paraRevisions.isEmpty || !paraCommentIDs.isEmpty else {
            return
        }
        let detectedHeading = paraHeadingLevel ?? DocumentParserEngine.detectChineseOrNumberedHeadingLevel(trimmed)
        let kind: DocumentBlockKind
        if detectedHeading != nil {
            kind = .heading
            activeSectionTitle = trimmed
        } else if paraIsList {
            kind = .listItem
        } else {
            kind = .paragraph
        }

        let block = DocumentBlock(
            id: "docx-b\(result.blocks.count)",
            index: result.blocks.count,
            kind: kind,
            headingLevel: detectedHeading,
            sectionTitle: activeSectionTitle,
            text: trimmed,
            pageNumber: currentPage,
            nativeRevisions: paraRevisions,
            commentIDs: paraCommentIDs,
            isProtectedComplex: paraProtected,
            protectionReason: paraProtectionReasons.isEmpty ? nil : paraProtectionReasons.joined(separator: "；"),
            xmlParagraphIndex: currentTopLevelParagraphXMLIndex
        )
        result.blocks.append(block)
    }

    private func finalizeTopLevelTable() {
        guard !currentTableRows.isEmpty else { return }
        let maxCols = currentTableRows.map(\.count).max() ?? 0
        let normalizedRows = currentTableRows.map { row in
            row.count < maxCols ? row + Array(repeating: "", count: maxCols - row.count) : row
        }
        let flattened = normalizedRows
            .map { $0.joined(separator: " | ") }
            .joined(separator: "\n")
        let reason = tableHasComplexMerge
            ? "包含跨行/跨列合并单元格表格（受保护只读对比）"
            : "内嵌表格结构受保护（请在文档软件中调整表格行列）"
        result.blocks.append(DocumentBlock(
            id: "docx-tbl-\(result.blocks.count)",
            index: result.blocks.count,
            kind: .table,
            sectionTitle: activeSectionTitle,
            text: flattened,
            tableRows: normalizedRows,
            pageNumber: currentPage,
            nativeRevisions: tableRevisions,
            commentIDs: tableCommentIDs,
            isProtectedComplex: true,
            protectionReason: reason,
            xmlParagraphIndex: nil
        ))
    }

    private func markParaProtected(_ reason: String) {
        paraProtected = true
        if !paraProtectionReasons.contains(reason) {
            paraProtectionReasons.append(reason)
        }
    }

    private static func headingLevel(fromStyle style: String) -> Int? {
        let lower = style.lowercased().trimmingCharacters(in: .whitespaces)
        if lower == "title" || lower == "标题" { return 1 }
        if lower.hasPrefix("heading") {
            let tail = lower.dropFirst("heading".count).trimmingCharacters(in: .whitespaces)
            if let n = Int(tail), (1...6).contains(n) { return n }
        }
        if lower.hasPrefix("标题") {
            let tail = lower.dropFirst("标题".count).trimmingCharacters(in: .whitespaces)
            if let n = Int(tail), (1...6).contains(n) { return n }
        }
        if let n = Int(lower), (1...6).contains(n) {
            return n
        }
        return nil
    }

    private static func isOfficialRedColorHex(_ hex: String) -> Bool {
        guard hex.count == 6, let val = UInt32(hex, radix: 16) else { return false }
        let r = Int((val >> 16) & 0xFF)
        let g = Int((val >> 8) & 0xFF)
        let b = Int(val & 0xFF)
        return r >= 175 && g <= 65 && b <= 65
    }
}

// MARK: - XLSX Sub-Parsers

private nonisolated final class XLSXSharedStringsParser: NSObject, XMLParserDelegate {
    private var strings: [String] = []
    private var inSI = false
    private var phoneticDepth = 0
    private var inT = false
    private var current = ""

    static func parse(_ data: Data) -> [String] {
        let delegate = XLSXSharedStringsParser()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = false
        parser.delegate = delegate
        _ = parser.parse()
        return delegate.strings
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        let local = xmlLocalName(elementName)
        switch local {
        case "si":
            inSI = true
            current = ""
        case "rPh":
            phoneticDepth += 1
        case "t":
            if inSI && phoneticDepth == 0 { inT = true }
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inT { current.append(string) }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let local = xmlLocalName(elementName)
        switch local {
        case "t":
            inT = false
        case "rPh":
            phoneticDepth = max(0, phoneticDepth - 1)
        case "si":
            strings.append(current)
            inSI = false
            current = ""
        default:
            break
        }
    }
}

private nonisolated final class XLSXWorkbookParser: NSObject, XMLParserDelegate {
    struct SheetRef {
        let name: String
        let relID: String?
    }

    private var sheets: [SheetRef] = []

    static func parse(_ data: Data) -> [SheetRef] {
        let delegate = XLSXWorkbookParser()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = false
        parser.delegate = delegate
        _ = parser.parse()
        return delegate.sheets
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        if xmlLocalName(elementName) == "sheet" {
            let name = attributeDict["name"] ?? "Sheet\(sheets.count + 1)"
            let rid = attributeDict["r:id"] ?? xmlAttr(attributeDict, local: "id")
            sheets.append(SheetRef(name: name, relID: rid))
        }
    }
}

private nonisolated final class XLSXWorksheetParser: NSObject, XMLParserDelegate {
    private let sharedStrings: [String]
    private var rawRows: [(rowNumber: Int, cellsByCol: [Int: String], formulasByCol: [Int: String])] = []
    private var maxColIndex = -1

    private var currentRowNum = 0
    private var currentCells: [Int: String] = [:]
    private var currentFormulas: [Int: String] = [:]
    private var nextSequentialCol = 0

    private var currentColIndex = 0
    private var currentCellType = ""
    private var inV = false
    private var inF = false
    private var inInlineT = false
    private var valueBuffer = ""
    private var formulaBuffer = ""

    init(sharedStrings: [String]) {
        self.sharedStrings = sharedStrings
    }

    static func parse(
        _ data: Data,
        sheetName: String,
        sheetIndex: Int,
        sharedStrings: [String]
    ) -> SpreadsheetSheet {
        let delegate = XLSXWorksheetParser(sharedStrings: sharedStrings)
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = false
        parser.delegate = delegate
        _ = parser.parse()

        let colCount = max(0, delegate.maxColIndex + 1)
        guard colCount > 0, !delegate.rawRows.isEmpty else {
            return SpreadsheetSheet(name: sheetName, sheetIndex: sheetIndex)
        }

        var materialized: [SpreadsheetRow] = []
        materialized.reserveCapacity(delegate.rawRows.count)
        for item in delegate.rawRows {
            var vals = Array(repeating: "", count: colCount)
            for (c, v) in item.cellsByCol where c >= 0 && c < colCount {
                vals[c] = v
            }
            if vals.contains(where: { !$0.isEmpty }) || !item.formulasByCol.isEmpty {
                materialized.append(SpreadsheetRow(
                    rowNumber: item.rowNumber,
                    values: vals,
                    formulasByCol: item.formulasByCol
                ))
            }
        }

        let headers: [String]
        let bodyRows: [SpreadsheetRow]
        if let first = materialized.first {
            headers = first.values
            bodyRows = Array(materialized.dropFirst())
        } else {
            headers = []
            bodyRows = []
        }

        let pkCol = SpreadsheetPrimaryKeyDetector.suggestPrimaryKeyColumn(headers: headers, rows: bodyRows)
        return SpreadsheetSheet(
            name: sheetName,
            sheetIndex: sheetIndex,
            headers: headers,
            rows: bodyRows,
            columnCount: colCount,
            suggestedPrimaryKeyCol: pkCol
        )
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        let local = xmlLocalName(elementName)
        switch local {
        case "row":
            currentRowNum = attributeDict["r"].flatMap(Int.init) ?? (currentRowNum + 1)
            currentCells = [:]
            currentFormulas = [:]
            nextSequentialCol = 0
        case "c":
            if let ref = attributeDict["r"], let parsedCol = Self.columnIndex(fromCellRef: ref) {
                currentColIndex = parsedCol
                nextSequentialCol = parsedCol + 1
            } else {
                currentColIndex = nextSequentialCol
                nextSequentialCol += 1
            }
            maxColIndex = max(maxColIndex, currentColIndex)
            currentCellType = attributeDict["t"] ?? ""
            valueBuffer = ""
            formulaBuffer = ""
        case "v":
            inV = true
        case "f":
            inF = true
        case "t":
            if currentCellType == "inlineStr" { inInlineT = true }
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inV || inInlineT {
            valueBuffer.append(string)
        } else if inF {
            formulaBuffer.append(string)
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let local = xmlLocalName(elementName)
        switch local {
        case "v":
            inV = false
        case "f":
            inF = false
        case "t":
            inInlineT = false
        case "c":
            let rawVal = valueBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
            let resolved: String
            switch currentCellType {
            case "s":
                if let idx = Int(rawVal), idx >= 0, idx < sharedStrings.count {
                    resolved = sharedStrings[idx]
                } else {
                    resolved = rawVal
                }
            case "b":
                resolved = (rawVal == "1" || rawVal.lowercased() == "true") ? "TRUE" : "FALSE"
            case "inlineStr", "str", "e":
                resolved = valueBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
            default:
                resolved = Self.cleanNumericCellValue(rawVal)
            }
            if !resolved.isEmpty {
                currentCells[currentColIndex] = resolved
            }
            let cleanFormula = formulaBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
            if !cleanFormula.isEmpty {
                currentFormulas[currentColIndex] = cleanFormula.hasPrefix("=") ? cleanFormula : "=\(cleanFormula)"
            }
        case "row":
            rawRows.append((currentRowNum, currentCells, currentFormulas))
        default:
            break
        }
    }

    static func columnIndex(fromCellRef ref: String) -> Int? {
        var col = 0
        var hasLetters = false
        for byte in ref.utf8 {
            if byte >= 0x41 && byte <= 0x5A {
                hasLetters = true
                col = col * 26 + Int(byte - 0x41) + 1
            } else if byte >= 0x61 && byte <= 0x7A {
                hasLetters = true
                col = col * 26 + Int(byte - 0x61) + 1
            } else {
                break
            }
        }
        return hasLetters ? (col - 1) : nil
    }

    private static func cleanNumericCellValue(_ raw: String) -> String {
        guard !raw.isEmpty, raw.contains("."), let dbl = Double(raw), dbl.isFinite else {
            return raw
        }
        // Clean IEEE-754 artefacts such as `15.200000000000001` -> `15.2`
        if abs(dbl - dbl.rounded()) < 1e-9 && abs(dbl) < 1e15 {
            return String(Int64(dbl.rounded()))
        }
        let formatted = String(format: "%.6f", dbl)
        var trimmed = formatted
        while trimmed.hasSuffix("0") { trimmed.removeLast() }
        if trimmed.hasSuffix(".") { trimmed.removeLast() }
        return trimmed
    }
}

private nonisolated final class PPTXSlideXMLParser: NSObject, XMLParserDelegate {
    private var paragraphs: [String] = []
    private var inAP = false
    private var inAT = false
    private var buffer = ""

    static func parse(_ data: Data) -> [String] {
        let delegate = PPTXSlideXMLParser()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = false
        parser.delegate = delegate
        _ = parser.parse()
        return delegate.paragraphs
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        let local = xmlLocalName(elementName)
        if local == "p" {
            inAP = true
            buffer = ""
        } else if local == "t" && inAP {
            inAT = true
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inAT { buffer.append(string) }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let local = xmlLocalName(elementName)
        if local == "t" {
            inAT = false
        } else if local == "p" && inAP {
            let clean = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
            if !clean.isEmpty { paragraphs.append(clean) }
            inAP = false
            buffer = ""
        }
    }
}

private nonisolated final class GenericXMLParagraphExtractor: NSObject, XMLParserDelegate {
    private let targetTags: Set<String>
    private var lines: [String] = []
    private var activeDepth = 0
    private var buffer = ""

    init(targetTags: Set<String>) {
        self.targetTags = targetTags
    }

    static func extract(_ data: Data, paragraphLocalNames: Set<String>) -> [String] {
        let delegate = GenericXMLParagraphExtractor(targetTags: paragraphLocalNames)
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = false
        parser.delegate = delegate
        _ = parser.parse()
        return delegate.lines
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        if targetTags.contains(xmlLocalName(elementName).lowercased()) {
            if activeDepth == 0 { buffer = "" }
            activeDepth += 1
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if activeDepth > 0 { buffer.append(string) }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if targetTags.contains(xmlLocalName(elementName).lowercased()), activeDepth > 0 {
            activeDepth -= 1
            if activeDepth == 0 {
                let clean = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
                if !clean.isEmpty { lines.append(clean) }
                buffer = ""
            }
        }
    }
}

// MARK: - Primary Key Column Detector for Spreadsheets

public nonisolated enum SpreadsheetPrimaryKeyDetector {
    private static let preferredHeaderKeywords = [
        "编号", "序号", "工号", "学号", "代码", "编码", "单号", "项目", "事项", "科目", "部门", "科室", "单位", "姓名", "名称",
        "id", "code", "key", "sku", "no", "name", "item"
    ]

    public static func candidatePrimaryKeyColumns(headers: [String], rows: [SpreadsheetRow]) -> [Int] {
        let colCount = max(headers.count, rows.map(\.values.count).max() ?? 0)
        guard colCount > 0, !rows.isEmpty else { return colCount > 0 ? [0] : [] }

        var scored: [(col: Int, score: Double)] = []
        for col in 0..<colCount {
            var nonEmpty = 0
            var unique = Set<String>()
            var pureDecimalCount = 0
            for row in rows {
                let val = (col < row.values.count ? row.values[col] : "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !val.isEmpty else { continue }
                nonEmpty += 1
                unique.insert(val.lowercased())
                if val.contains(".") && Double(val) != nil {
                    pureDecimalCount += 1
                }
            }
            guard nonEmpty > 0 else { continue }
            let fillRatio = Double(nonEmpty) / Double(rows.count)
            let uniqueRatio = Double(unique.count) / Double(nonEmpty)
            guard fillRatio >= 0.5 && uniqueRatio >= 0.65 else { continue }

            var score = uniqueRatio * 0.65 + fillRatio * 0.25
            if col < headers.count {
                let lowerHeader = headers[col].lowercased()
                if preferredHeaderKeywords.contains(where: { lowerHeader.contains($0) }) {
                    score += 0.20
                }
            }
            if col == 0 { score += 0.05 }
            if pureDecimalCount > nonEmpty / 2 { score -= 0.25 }
            scored.append((col, score))
        }

        if scored.isEmpty {
            return [0]
        }
        return scored.sorted { lhs, rhs in
            if abs(lhs.score - rhs.score) > 1e-6 { return lhs.score > rhs.score }
            return lhs.col < rhs.col
        }.map(\.col)
    }

    public static func suggestPrimaryKeyColumn(headers: [String], rows: [SpreadsheetRow]) -> Int? {
        candidatePrimaryKeyColumns(headers: headers, rows: rows).first
    }
}

nonisolated extension String {
    var nonEmptyTrimmed: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}
