import CoreGraphics
import CoreText
import Foundation
import PDFKit
import Testing
@testable import CharkleCore

@Suite("Document Core, Version Stack & Scheme B 2-Way Synthesis")
struct DocumentCoreAndVersionStackTests {

    // MARK: - 1. Layout Mode, MediaKind Extensions & Safe ZIP Codec

    @Test("GalleryLayoutMode.compactList and expanded MediaKind.document extensions")
    func compactListAndDocumentExtensions() throws {
        #expect(GalleryLayoutMode.compactList.rawValue == "compactList")
        #expect(GalleryLayoutMode.compactList.localizedLabel == "紧凑视图")
        #expect(GalleryLayoutMode.allCases.contains(.compactList))

        let encoded = try JSONEncoder().encode(GalleryLayoutMode.compactList)
        #expect(String(data: encoded, encoding: .utf8) == "\"compactList\"")
        #expect(try JSONDecoder().decode(GalleryLayoutMode.self, from: encoded) == .compactList)

        let officeExts = ["doc", "docx", "wps", "et", "dps", "xlsx", "xls", "pptx", "odt", "epub", "ofd", "pdf", "md", "txt", "csv"]
        for ext in officeExts {
            #expect(MediaKind.detect(fileExtension: ext) == .document, "Expected .document for .\(ext)")
            #expect(MediaKind.detect(fileExtension: ext.uppercased()) == .document)
        }
    }

    @Test("Safe ZipArchiveWriter & ZipArchiveReader round-trip and path traversal guard")
    func safeZipRoundTripAndSecurityGuards() throws {
        var writer = ZipArchiveWriter()
        let sampleXML = Data("<?xml version=\"1.0\"?><root>春季安全专项排查汇报材料测试内容，重复段落用于验证压缩率。春季安全专项排查汇报材料测试内容。</root>".utf8)
        let rawBinary = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0xAA, 0xBB, 0xCC])
        try writer.addEntry(name: "word/document.xml", data: sampleXML, compress: true)
        try writer.addEntry(name: "word/media/seal.bin", data: rawBinary, compress: false)

        let archiveBytes = try writer.finalize()
        let reader = try ZipArchiveReader(data: archiveBytes)
        #expect(reader.entries.count == 2)
        #expect(try reader.readEntry("word/document.xml") == sampleXML)
        #expect(try reader.readEntry("word/media/seal.bin") == rawBinary)

        // Path traversal must fail closed
        #expect(throws: ZipArchiveError.self) {
            var badWriter = ZipArchiveWriter()
            try badWriter.addEntry(name: "../outside.txt", data: Data("bad".utf8))
        }
        #expect(throws: ZipArchiveError.self) {
            var badWriter = ZipArchiveWriter()
            try badWriter.addEntry(name: "/etc/passwd", data: Data("bad".utf8))
        }
    }

    // MARK: - 2. Native .docx, .xlsx, .pptx, GB18030, and PDF Parsing

    @Test("Native OOXML .docx parser extracts headings, tables, track changes, comments, editor & protected blocks")
    func docxStructuredParsing() async throws {
        let dir = try BackendFixture.directory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let docxURL = dir.appending(path: "关于春季安全专项排查的汇报.docx")
        let archive = try Self.makeSampleDOCXData(
            lastModifiedBy: "张主任",
            paragraphsXML: """
            <w:p><w:pPr><w:pStyle w:val="Heading1"/></w:pPr><w:r><w:rPr><w:color w:val="C83E37"/></w:rPr><w:t>一、总体工作情况</w:t></w:r></w:p>
            <w:p><w:r><w:t>各科室已于前期完成自查，专项整改经费核定为 </w:t></w:r><w:del w:author="李敏" w:date="2026-05-10"><w:r><w:delText>12.5万元</w:delText></w:r></w:del><w:ins w:author="张主任" w:date="2026-05-12"><w:r><w:t>15.2万元</w:t></w:r></w:ins><w:commentRangeStart w:id="1"/><w:r><w:t>。</w:t></w:r><w:commentReference w:id="1"/></w:p>
            <w:tbl>
              <w:tr><w:tc><w:p><w:r><w:t>科室</w:t></w:r></w:p></w:tc><w:tc><w:p><w:r><w:t>预算</w:t></w:r></w:p></w:tc></w:tr>
              <w:tr><w:tc><w:p><w:r><w:t>后勤处</w:t></w:r></w:p></w:tc><w:tc><w:p><w:r><w:t>8.5万元</w:t></w:r></w:p></w:tc></w:tr>
            </w:tbl>
            <w:p><w:r><w:fldChar w:fldCharType="begin"/><w:instrText>TOC \\o "1-3"</w:instrText><w:t>自动目录域</w:t><w:fldChar w:fldCharType="end"/></w:r></w:p>
            """,
            commentsXML: """
            <?xml version="1.0" encoding="UTF-8"?>
            <w:comments xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
              <w:comment w:id="1" w:author="张主任" w:date="2026-05-12T10:00:00Z">
                <w:p><w:r><w:t>按最新燃气改造标准上调预算</w:t></w:r></w:p>
              </w:comment>
            </w:comments>
            """
        )
        try archive.write(to: docxURL)

        let parsed = try await DocumentParserEngine.parse(fileURL: docxURL)
        let payload = parsed.payload
        #expect(payload.formatFamily == "docx")
        #expect(payload.authorOrEditor == "张主任")
        #expect(payload.hasNativeRevisions == true)
        #expect(payload.isRedHeaderStyle == true)
        #expect(payload.blocks.count == 4)

        // Block 0: Heading
        #expect(payload.blocks[0].kind == .heading)
        #expect(payload.blocks[0].headingLevel == 1)
        #expect(payload.blocks[0].xmlParagraphIndex == 0)
        #expect(payload.blocks[0].isProtectedComplex == false)

        // Block 1: Track-changed paragraph (clean current text omits <w:delText>, retains both revisions)
        #expect(payload.blocks[1].text.contains("15.2万元"))
        #expect(!payload.blocks[1].text.contains("12.5万元"))
        #expect(payload.blocks[1].nativeRevisions.count == 2)
        #expect(payload.blocks[1].xmlParagraphIndex == 1)

        // Block 2: Embedded table (marked protected)
        #expect(payload.blocks[2].kind == .table)
        #expect(payload.blocks[2].tableRows == [["科室", "预算"], ["后勤处", "8.5万元"]])
        #expect(payload.blocks[2].isProtectedComplex == true)

        // Block 3: Complex field paragraph (`fldChar` -> marked protected!)
        #expect(payload.blocks[3].isProtectedComplex == true)
        #expect(payload.blocks[3].xmlParagraphIndex == 2)

        // Comment anchored to Block 1
        #expect(payload.comments.count == 1)
        #expect(payload.comments[0].author == "张主任")
        #expect(payload.comments[0].text == "按最新燃气改造标准上调预算")
        #expect(payload.comments[0].anchorBlockIndex == 1)
    }

    @Test("Native OOXML .xlsx and .pptx parsers extract sheets, sharedStrings, formulas & slides")
    func xlsxAndPptxParsing() async throws {
        let dir = try BackendFixture.directory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let xlsxURL = dir.appending(path: "隐患整改台账.xlsx")
        let xlsxData = try Self.makeSampleXLSXData(
            sheetName: "2026预算汇总",
            rows: [
                (cells: ["项目编号", "整改事项", "核定金额"], formulas: [:]),
                (cells: ["#101", "消防喷淋检修", "8000"], formulas: [:]),
                (cells: ["#102", "食堂燃气阀更换", "11500"], formulas: [2: "SUM(C2,3500)"])
            ],
            lastModifiedBy: "财务室"
        )
        try xlsxData.write(to: xlsxURL)

        let xlsxParsed = try await DocumentParserEngine.parse(fileURL: xlsxURL)
        #expect(xlsxParsed.payload.formatFamily == "xlsx")
        #expect(xlsxParsed.payload.authorOrEditor == "财务室")
        #expect(xlsxParsed.payload.sheets.count == 1)
        let sheet = try #require(xlsxParsed.payload.sheets.first)
        #expect(sheet.name == "2026预算汇总")
        #expect(sheet.headers == ["项目编号", "整改事项", "核定金额"])
        #expect(sheet.rows.count == 2)
        #expect(sheet.rows[1].values == ["#102", "食堂燃气阀更换", "11500"])
        #expect(sheet.rows[1].formula(at: 2) == "=SUM(C2,3500)")
        #expect(sheet.suggestedPrimaryKeyCol == 0)

        let pptxURL = dir.appending(path: "汇报演示.pptx")
        var pptWriter = ZipArchiveWriter()
        let slideXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <p:sld xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main" xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main">
          <p:cSld><p:spTree><p:sp><p:txBody>
            <a:p><a:r><a:t>第一部分：总体整改进度</a:t></a:r></a:p>
            <a:p><a:r><a:t>已完成全部校区配电室巡检</a:t></a:r></a:p>
          </p:txBody></p:sp></p:spTree></p:cSld>
        </p:sld>
        """
        try pptWriter.addEntry(name: "ppt/slides/slide1.xml", data: Data(slideXML.utf8))
        try pptWriter.finalize().write(to: pptxURL)

        let pptParsed = try await DocumentParserEngine.parse(fileURL: pptxURL)
        #expect(pptParsed.payload.formatFamily == "pptx")
        #expect(pptParsed.payload.pageCount == 1)
        #expect(pptParsed.payload.plainText.contains("已完成全部校区配电室巡检"))
    }

    @Test("GB18030 / UTF-16 text decoding and PDF text-layer vs scanned Vision OCR")
    func gb18030AndPdfScanDetectionAndOCR() async throws {
        let dir = try BackendFixture.directory()
        defer { try? FileManager.default.removeItem(at: dir) }

        // 1. GB18030 encoded `.txt` file
        let gbString = "一、通知要求\n请各单位于5月20日前报送防汛物资储备清单及值班表。"
        let gbData = try #require(gbString.data(using: DocumentTextDecoder.gb18030Encoding))
        // Confirm it is NOT valid UTF-8
        #expect(String(data: gbData, encoding: .utf8) == nil)
        let gbURL = dir.appending(path: "防汛值班通知_GBK.txt")
        try gbData.write(to: gbURL)

        let gbParsed = try await DocumentParserEngine.parse(fileURL: gbURL)
        #expect(gbParsed.payload.plainText.contains("防汛物资储备清单"))
        #expect(gbParsed.payload.blocks.first?.kind == .heading)

        // 2. Scanned image-only PDF (`hasTextLayer == false`) + offline Vision OCR
        let scannedPDFURL = dir.appending(path: "签批扫描件.pdf")
        try Self.makeRasterScannedPDF(lines: ["专项安全检查督办单", "整改预算 28万元"], to: scannedPDFURL)

        let pdfNoOCR = try await DocumentParserEngine.parse(fileURL: scannedPDFURL, performOCRIfScanned: false)
        #expect(pdfNoOCR.payload.formatFamily == "pdf")
        #expect(pdfNoOCR.payload.hasTextLayer == false)

        let pdfWithOCR = try await DocumentParserEngine.parse(fileURL: scannedPDFURL, performOCRIfScanned: true)
        #expect(pdfWithOCR.payload.hasTextLayer == false)
        #expect(!pdfWithOCR.payload.plainText.isEmpty)
    }

    // MARK: - 3. FTS5 Full-Text & Pinyin Indexing via `document_content_cache` (Without Sync Op Bloat)

    @Test("Ingested documents populate document_content_cache, match FTS5 + Pinyin + QuickJump, and cap AssetRecord.ocrText")
    func fts5AndLocalDocumentCacheIsolation() async throws {
        let dir = try BackendFixture.directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let engine = try BackendFixture.makeEngine(dir)

        let filler = String(repeating: "常规背景段落说明内容，用于构造超过三千字的长篇正式汇报正文。", count: 120)
        let tailSecret = "尾页核心指标：东配楼实验室排风管改造立项编码 ZX20260998。"
        let docxURL = dir.appending(path: "基础设施修缮立项报告.docx")
        let docxBytes = try Self.makePlainParagraphDOCX(
            paragraphs: ["一、项目背景", filler, tailSecret],
            lastModifiedBy: "后勤基建处"
        )
        try docxBytes.write(to: docxURL)

        let imported = try #require(try await engine.ingest([.fileURL(docxURL)], targetFolderID: nil, targetBoardID: nil).first)
        #expect(imported.mediaKind == .document)
        #expect(imported.richMetadata?.document?.formatFamily == "docx")
        #expect((imported.richMetadata?.document?.wordCount ?? 0) > 3_000)

        // Wire payload hygiene: `AssetRecord.ocrText` stays <= 2,000 chars even though `tailSecret` is past char 3,600!
        #expect((imported.ocrText?.count ?? 0) <= 2_000)
        #expect(imported.ocrText?.contains("ZX20260998") == false)

        // Yet `document_content_cache` + `assets_fts` finds both the deep tail Chinese phrase, code, AND Pinyin!
        let codeHits = try await engine.fetchAssets(matching: FilterCriteria(searchQuery: "ZX20260998"))
        #expect(codeHits.map(\.id) == [imported.id])

        let chineseHits = try await engine.fetchAssets(matching: FilterCriteria(searchQuery: "实验室排风管改造"))
        #expect(chineseHits.map(\.id) == [imported.id])

        let pinyinHits = try await engine.fetchAssets(matching: FilterCriteria(searchQuery: "shiyanshipaifengguan"))
        #expect(pinyinHits.map(\.id) == [imported.id])

        let jumpHits = try await engine.quickJump(query: "ZX20260998", limit: 10)
        #expect(jumpHits.contains { $0.kind == .asset && $0.targetUUID == imported.id })
    }

    // MARK: - 4. Stem Normalizer, SimHash Matching & `isPinnedPrimary` Anti-Override

    @Test("Stem normalizer, <150ms SimHash candidate matching, folder adoption, and isPinnedPrimary anti-override")
    func versionStackDetectionAndPinnedPrimaryProtection() async throws {
        // 1. Stem normalizer edge cases
        let n1 = VersionStemNormalizer.normalize(fileNameOrTitle: "20260512_关于春季安全排查的汇报_v2_张主任改(1).docx")
        let n2 = VersionStemNormalizer.normalize(fileNameOrTitle: "关于春季安全排查的汇报（李科长核定版）_副本.docx")
        let n3 = VersionStemNormalizer.normalize(fileNameOrTitle: "关于春季安全排查的汇报_最终版.docx")
        #expect(n1.canonicalStem == n2.canonicalStem)
        #expect(n2.canonicalStem == n3.canonicalStem)
        #expect(n1.suggestedEditorName == "张主任")
        #expect(n2.suggestedEditorName == "李科长")
        #expect(n1.explicitVersionHint == 2)

        // 2. Live engine stack detection, folder routing & `isPinnedPrimary` preservation
        let dir = try BackendFixture.directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let engine = try BackendFixture.makeEngine(dir)
        let projectFolder = try await engine.createFolder(name: "安全专项", parentID: nil)

        let v1URL = dir.appending(path: "春季安全排查方案_初稿.docx")
        try Self.makePlainParagraphDOCX(
            paragraphs: [
                "一、排查范围",
                "覆盖全校教学楼、实验室、学生公寓与食堂燃气设施，全面建立隐患台账。",
                "二、经费预算",
                "第一阶段专项整改经费预算为 12.5万元，由保卫处与后勤处统筹执行。",
                "三、时间节点",
                "各单位须于 2026年5月25日前 完成全部闭环复核。"
            ],
            lastModifiedBy: "李敏"
        ).write(to: v1URL)
        let v1 = try #require(try await engine.ingest([.fileURL(v1URL)], targetFolderID: projectFolder.id, targetBoardID: nil).first)

        // Prepare v2 draft with `-张主任改` suffix and measure `<150ms` candidate detection
        let v2URL = dir.appending(path: "春季安全排查方案_v2-张主任改.docx")
        try Self.makePlainParagraphDOCX(
            paragraphs: [
                "一、排查范围",
                "覆盖全校教学楼、实验室、学生公寓与食堂燃气设施，全面建立隐患台账。",
                "二、经费预算",
                "第一阶段专项整改经费预算为 15.2万元，由保卫处与后勤处统筹执行。",
                "三、时间节点",
                "各单位须于 2026年5月18日前 完成全部闭环复核。"
            ],
            lastModifiedBy: "张主任"
        ).write(to: v2URL)

        let startClock = ContinuousClock.now
        let candidateV2 = try #require(try await engine.detectVersionStackCandidate(for: v2URL, targetFolderID: nil))
        let elapsedMs = startClock.duration(to: .now).components.attoseconds / 1_000_000_000_000_000
        #expect(elapsedMs < 150)
        #expect(candidateV2.targetAssetID == v1.id)
        #expect(candidateV2.nextVersionNumber == 2)
        #expect(candidateV2.suggestedEditorName == "张主任")
        #expect(candidateV2.targetFolderID == projectFolder.id)

        // Ingest v2 into Inbox (simulating Notch Shelf drop) and join stack -> adopts `projectFolder.id`!
        let v2Ingested = try #require(try await engine.ingest([.fileURL(v2URL)], targetFolderID: nil, targetBoardID: nil).first)
        let stackAfterV2 = try await engine.manageVersionStack(
            .join(assetID: v2Ingested.id, targetAssetOrGroupID: candidateV2.targetGroupID, editorName: candidateV2.suggestedEditorName, changeNote: "核定预算与时限")
        )
        #expect(stackAfterV2.count == 2)
        let v2Joined = try #require(stackAfterV2.last)
        #expect(v2Joined.folderID == projectFolder.id)
        #expect(v2Joined.versionStack?.versionNumber == 2)
        #expect(v2Joined.documentMetadata?.diffSummary?.highRiskNumberChanges == 1)
        #expect(v2Joined.documentMetadata?.diffSummary?.highRiskDateChanges == 1)
        #expect(v2Joined.documentMetadata?.diffSummary?.minimapBuckets.count == 12)
        #expect(v2Joined.documentMetadata?.diffSummary?.minimapBuckets.contains(2) == true)

        // Pin v2 as Primary Version (`定稿主版`)
        let pinnedStack = try await engine.manageVersionStack(.setPrimary(assetID: v2Joined.id))
        #expect(AssetVersionStackMetadata.resolvePrimaryAsset(in: pinnedStack)?.id == v2Joined.id)

        // Drop a renamed v3 file (completely different filename stem -> matched purely via 64-bit paragraph SimHash!)
        let v3RenamedURL = dir.appending(path: "发群待审阅材料0513.docx")
        try Self.makePlainParagraphDOCX(
            paragraphs: [
                "一、排查范围",
                "覆盖全校教学楼、实验室、学生公寓与食堂燃气设施，全面建立隐患台账。",
                "二、经费预算",
                "第一阶段专项整改经费预算为 16.0万元，由保卫处与后勤处统筹执行。",
                "三、时间节点",
                "各单位须于 2026年5月18日前 完成全部闭环复核。"
            ],
            lastModifiedBy: "王科"
        ).write(to: v3RenamedURL)

        let simCandidate = try #require(try await engine.detectVersionStackCandidate(for: v3RenamedURL, targetFolderID: projectFolder.id))
        #expect(simCandidate.matchReason == .contentSimHash)
        #expect(simCandidate.nextVersionNumber == 3)
        #expect(simCandidate.suggestedEditorName == "王科")

        let v3Ingested = try #require(try await engine.ingest([.fileURL(v3RenamedURL)], targetFolderID: nil, targetBoardID: nil).first)
        let stackAfterV3 = try await engine.manageVersionStack(
            .join(assetID: v3Ingested.id, targetAssetOrGroupID: simCandidate.targetGroupID, editorName: "王科", changeNote: "补充照明预算")
        )
        #expect(stackAfterV3.count == 3)

        // CRITICAL ANTI-MIS-SEND INVARIANT: v2 MUST remain the pinned Primary Version (`+1 新版`)!
        let resolvedPrimary = try #require(AssetVersionStackMetadata.resolvePrimaryAsset(in: stackAfterV3))
        #expect(resolvedPrimary.id == v2Joined.id)
        #expect(resolvedPrimary.versionStack?.isPinnedPrimary == true)
        #expect(stackAfterV3.last?.versionStack?.isPinnedPrimary == false)
        #expect(AssetVersionStackMetadata.newerThanPrimaryCount(in: stackAfterV3) == 1)
    }

    // MARK: - 5. Multi-Modal Diff Radar (Move Detection, High-Risk Numbers/Dates & Excel PK Alignment)

    @Test("Paragraph Move detection, High-Risk Number/Date Radar, and Excel Primary-Key row insertion alignment")
    func multiModalDiffAndExcelPKAlignment() async throws {
        let dir = try BackendFixture.directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let engine = try BackendFixture.makeEngine(dir)

        // Part A: Paragraph Move + High-Risk Number & Date Radar
        let docAURL = dir.appending(path: "通知_v1.md")
        let docBURL = dir.appending(path: "通知_v2.md")
        try Data("""
        # 专项督导通知

        督导组实行每周五定期通报制度，各科室须严格落实责任人签字背书。

        专项设备采购限额核定为 ¥125,000，复检合格率须达到 95%。

        材料报送截止日期为 2026年6月30日前。
        """.utf8).write(to: docAURL)

        try Data("""
        # 专项督导通知

        专项设备采购限额核定为 ¥148,000，复检合格率须达到 98.5%。

        材料报送截止日期为 2026年6月15日前。

        督导组实行每周五定期通报制度，各科室须严格落实责任人签字背书。
        """.utf8).write(to: docBURL)

        let importedDocs = try await engine.ingest([.fileURL(docAURL), .fileURL(docBURL)], targetFolderID: nil, targetBoardID: nil)
        let report = try await engine.compareDocumentVersions(
            baseAssetID: importedDocs[0].id,
            targetAssetID: importedDocs[1].id,
            sheetName: nil,
            primaryKeyCol: nil,
            useOCRIfScanned: false
        )

        #expect(report.summary.movedBlocks >= 1)
        #expect(report.summary.highRiskNumberChanges >= 2)
        #expect(report.summary.highRiskDateChanges >= 1)
        #expect(report.hunks.contains { $0.changeKind == .moved })
        #expect(report.hunks.contains { $0.riskFlags.contains(.numberOrCurrency) })
        #expect(report.hunks.contains { $0.riskFlags.contains(.dateOrDeadline) })

        // Part B: Excel Primary-Key alignment prevents shifted false positives on mid-sheet row insertion
        let xlsV1URL = dir.appending(path: "预算表_v1.xlsx")
        let xlsV2URL = dir.appending(path: "预算表_v2.xlsx")
        try Self.makeSampleXLSXData(
            sheetName: "设备明细",
            rows: [
                (cells: ["编号", "项目", "预算"], formulas: [:]),
                (cells: ["EQ-01", "红外测温仪", "5000"], formulas: [:]),
                (cells: ["EQ-02", "应急照明灯", "12000"], formulas: [:]),
                (cells: ["EQ-03", "防排烟风机", "45000"], formulas: [:]),
                (cells: ["EQ-04", "防火门闭门器", "9000"], formulas: [:])
            ]
        ).write(to: xlsV1URL)

        // Insert 2 brand-new rows right after EQ-01, and modify only EQ-03's budget (`45000` -> `52000`)!
        // EQ-02 and EQ-04 shifted down by 2 row numbers, yet MUST stay `.unchanged`!
        try Self.makeSampleXLSXData(
            sheetName: "设备明细",
            rows: [
                (cells: ["编号", "项目", "预算"], formulas: [:]),
                (cells: ["EQ-01", "红外测温仪", "5000"], formulas: [:]),
                (cells: ["EQ-01A", "新增烟感探头", "6800"], formulas: [:]),
                (cells: ["EQ-01B", "新增灭火器箱", "3200"], formulas: [:]),
                (cells: ["EQ-02", "应急照明灯", "12000"], formulas: [:]),
                (cells: ["EQ-03", "防排烟风机", "52000"], formulas: [:]),
                (cells: ["EQ-04", "防火门闭门器", "9000"], formulas: [:])
            ]
        ).write(to: xlsV2URL)

        let xlsAssets = try await engine.ingest([.fileURL(xlsV1URL), .fileURL(xlsV2URL)], targetFolderID: nil, targetBoardID: nil)
        let xlsReport = try await engine.compareDocumentVersions(
            baseAssetID: xlsAssets[0].id,
            targetAssetID: xlsAssets[1].id,
            sheetName: nil,
            primaryKeyCol: nil,
            useOCRIfScanned: false
        )
        let sheetDiff = try #require(xlsReport.sheetDiffs.first)
        #expect(sheetDiff.primaryKeyCol == 0)
        #expect(sheetDiff.addedRowCount == 2)
        #expect(sheetDiff.removedRowCount == 0)
        #expect(sheetDiff.modifiedRowCount == 1)

        let eq02Row = try #require(sheetDiff.rowDiffs.first { $0.primaryKeyValue == "EQ-02" })
        let eq04Row = try #require(sheetDiff.rowDiffs.first { $0.primaryKeyValue == "EQ-04" })
        let eq03Row = try #require(sheetDiff.rowDiffs.first { $0.primaryKeyValue == "EQ-03" })
        #expect(eq02Row.changeKind == .unchanged)
        #expect(eq04Row.changeKind == .unchanged)
        #expect(eq03Row.changeKind == .modified)
        #expect(eq03Row.cellDiffs.first?.oldValue == "45000")
        #expect(eq03Row.cellDiffs.first?.newValue == "52000")
        #expect(eq03Row.riskFlags.contains(.numberOrCurrency))
    }

    // MARK: - 6. Scheme B Safe 2-Way `.docx` Surgical Synthesis Round-Trip

    @Test("Scheme B .docx 2-Way synthesis preserves styles/media byte-for-byte, protects tables, and creates v3")
    func docxSurgicalTwoWaySynthesisRoundTrip() async throws {
        let dir = try BackendFixture.directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let engine = try BackendFixture.makeEngine(dir)

        let customStylesBytes = Data("<?xml version=\"1.0\" encoding=\"UTF-8\"?><w:styles xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\"><w:style w:styleId=\"RedHeaderCustom\"/></w:styles>".utf8)
        let embeddedMediaBytes = Data((0..<256).map { UInt8($0 & 0xFF) })

        let v1URL = dir.appending(path: "整改工作报告_v1.docx")
        let v2URL = dir.appending(path: "整改工作报告_v2.docx")

        try Self.makeSampleDOCXData(
            lastModifiedBy: "李敏",
            paragraphsXML: """
            <w:p><w:pPr><w:pStyle w:val="Heading1"/></w:pPr><w:r><w:rPr><w:b/><w:color w:val="C83E37"/></w:rPr><w:t>关于校园安全整改的报告</w:t></w:r></w:p>
            <w:p><w:pPr><w:jc w:val="both"/></w:pPr><w:r><w:rPr><w:sz w:val="28"/></w:rPr><w:t>第一处经费维持旧版 12.5万元。</w:t></w:r></w:p>
            <w:p><w:r><w:t>第二处时限旧版为 5月25日前。</w:t></w:r></w:p>
            <w:tbl><w:tr><w:tc><w:p><w:r><w:t>受保护表格</w:t></w:r></w:p></w:tc><w:tc><w:p><w:r><w:t>100</w:t></w:r></w:p></w:tc></w:tr></w:tbl>
            """,
            stylesBytes: customStylesBytes,
            mediaBytes: embeddedMediaBytes
        ).write(to: v1URL)

        try Self.makeSampleDOCXData(
            lastModifiedBy: "张主任",
            paragraphsXML: """
            <w:p><w:pPr><w:pStyle w:val="Heading1"/></w:pPr><w:r><w:rPr><w:b/><w:color w:val="C83E37"/></w:rPr><w:t>关于校园安全整改的报告</w:t></w:r></w:p>
            <w:p><w:pPr><w:jc w:val="both"/></w:pPr><w:r><w:rPr><w:sz w:val="28"/></w:rPr><w:t>第一处经费误改为 99.9万元。</w:t></w:r></w:p>
            <w:p><w:r><w:t>第二处时限新版提前至 5月18日前。</w:t></w:r></w:p>
            <w:tbl><w:tr><w:tc><w:p><w:r><w:t>受保护表格</w:t></w:r></w:p></w:tc><w:tc><w:p><w:r><w:t>200</w:t></w:r></w:p></w:tc></w:tr></w:tbl>
            """,
            stylesBytes: customStylesBytes,
            mediaBytes: embeddedMediaBytes
        ).write(to: v2URL)

        let ingested = try await engine.ingest([.fileURL(v1URL), .fileURL(v2URL)], targetFolderID: nil, targetBoardID: nil)
        let stack = try await engine.manageVersionStack(.create(assetIDs: [ingested[0].id, ingested[1].id], primaryAssetID: ingested[0].id))
        let baseV1 = stack[0]
        let targetV2 = stack[1]

        let diff = try await engine.compareDocumentVersions(
            baseAssetID: baseV1.id,
            targetAssetID: targetV2.id,
            sheetName: nil,
            primaryKeyCol: nil,
            useOCRIfScanned: false
        )
        #expect(diff.canSynthesizeTwoWay == true)

        let changedPlainHunks = diff.hunks.filter { $0.changeKind == .modified && !$0.isProtectedComplex }
        #expect(changedPlainHunks.count == 2)

        // Decision: revert hunk 1 to old (`保留旧版 12.5万元`), accept new on hunk 2 (`5月18日前`), plus test custom micro-edit!
        let decisions: [DocumentMergeDecision] = [
            DocumentMergeDecision(hunkID: changedPlainHunks[0].id, choice: .keepBase),
            DocumentMergeDecision(hunkID: changedPlainHunks[1].id, choice: .customText, customText: "第二处时限经会议审定为 5月20日前（含周末值守） & <零坏档校验>。")
        ]

        let createdV3 = try await engine.synthesizeDocumentVersion(
            baseAssetID: baseV1.id,
            targetAssetID: targetV2.id,
            preferTargetAsTemplate: true,
            decisions: decisions,
            editorName: "办公室汇总",
            changeNote: "退回第一处经费，微调第二处时限"
        )

        #expect(createdV3.versionStack?.versionNumber == 3)
        #expect(createdV3.versionStack?.groupID == baseV1.versionGroupID)
        // Synthesized vN+1 must immediately carry a populated `diffSummary` so Revision Rail shows `Δ X处` instead of `Δ 对比`!
        let synthDiffSummary = try #require(createdV3.documentMetadata?.diffSummary)
        #expect(synthDiffSummary.totalChangedBlocks >= 1)
        #expect(synthDiffSummary.compactBridgeLabel.hasPrefix("Δ "))
        #expect(!synthDiffSummary.compactBridgeLabel.contains("¥"))
        // Pinned primary v1 must remain preserved!
        let refreshedV1 = try #require(try await engine.fetchAsset(id: baseV1.id))
        #expect(refreshedV1.versionStack?.isPinnedPrimary == true)

        // Verify output `.docx` ZIP integrity, untouched `styles.xml` & `word/media/seal.bin` bytes, and `<w:pPr>`/`<w:rPr>` preservation!
        let synthURL = try await engine.originalURL(for: createdV3.id)
        let synthReader = try ZipArchiveReader(url: synthURL)
        #expect(try synthReader.readEntry("word/styles.xml") == customStylesBytes)
        #expect(try synthReader.readEntry("word/media/seal.bin") == embeddedMediaBytes)

        let docXMLBytes = try #require(try synthReader.readEntry("word/document.xml"))
        let rawOutXML = try #require(String(data: docXMLBytes, encoding: .utf8))
        #expect(rawOutXML.contains("<w:jc w:val=\"both\"/>"))
        #expect(rawOutXML.contains("<w:sz w:val=\"28\"/>"))

        let v3Structured = try await engine.readStructuredDocument(assetID: createdV3.id)
        #expect(v3Structured.blocks[1].text == "第一处经费维持旧版 12.5万元。")
        #expect(v3Structured.blocks[2].text == "第二处时限经会议审定为 5月20日前（含周末值守） & <零坏档校验>。")
        // Protected table from target template stays intact
        #expect(v3Structured.blocks[3].tableRows == [["受保护表格", "200"]])
    }

    // MARK: - 7. Cross-Platform `/.charkle/` Sync Wire Contract & Lossless Codable Round-Trip

    @Test("AssetRichMetadata.versionStack & document round-trip across /.charkle/ HLC sync with uppercase UUIDs")
    func charkleSyncWireRoundTrip() async throws {
        let dir = try BackendFixture.directory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let transport = InMemoryDriveTransport(pageSize: 10)
        let macA = try BackendFixture.makeEngine(dir.appending(path: "MacA"), transport: transport)
        let macB = try BackendFixture.makeEngine(dir.appending(path: "MacB"), transport: transport)
        try await macA.saveSyncConfig(BackendFixture.syncConfig())
        try await macB.saveSyncConfig(BackendFixture.syncConfig())

        let md1 = dir.appending(path: "年度总结_v1.md")
        let md2 = dir.appending(path: "年度总结_v2.md")
        try Data("# 总结\n\n完成课题经费 30万元。".utf8).write(to: md1)
        try Data("# 总结\n\n完成课题经费 42万元，结题日期 2026年11月30日。".utf8).write(to: md2)

        let assetsA = try await macA.ingest([.fileURL(md1), .fileURL(md2)], targetFolderID: nil, targetBoardID: nil)
        let stackedA = try await macA.manageVersionStack(
            .create(assetIDs: [assetsA[0].id, assetsA[1].id], primaryAssetID: assetsA[1].id, editorName: "张主任", changeNote: "核定结题经费")
        )
        let primaryA = stackedA[1]

        // Verify wire JSON uses canonical uppercase RFC-4122 UUIDs & exact camelCase keys
        let jsonBytes = try JSONEncoder().encode(primaryA)
        let jsonText = try #require(String(data: jsonBytes, encoding: .utf8))
        #expect(jsonText.contains("\"versionStack\""))
        #expect(jsonText.contains("\"isPinnedPrimary\":true"))
        #expect(jsonText.contains("\"minimapBuckets\""))
        #expect(jsonText.contains(primaryA.versionGroupID!.uuidString))
        #expect(primaryA.versionGroupID!.uuidString == primaryA.versionGroupID!.uuidString.uppercased())

        // Sync Mac A -> Transport -> Mac B
        _ = try await macA.syncNow()
        _ = try await macB.syncNow()

        let syncedV1 = try #require(try await macB.fetchAsset(id: stackedA[0].id))
        let syncedV2 = try #require(try await macB.fetchAsset(id: stackedA[1].id))
        #expect(syncedV1.versionGroupID == stackedA[0].versionGroupID)
        #expect(syncedV2.versionStack == primaryA.versionStack)
        #expect(syncedV2.documentMetadata == primaryA.documentMetadata)
        #expect(syncedV2.documentMetadata?.diffSummary?.minimapBuckets.count == 12)
    }

    // MARK: - 8. Pure Number Bridge Labels, Clock-Time / Year / Dotted-Date Isolation & Prefix Deduplication

    @Test("compactBridgeLabel uses 数字/时间 (no ¥), clock times & dates never leak into highRiskNumberChanges, and v1/v2 prefixes deduplicate")
    func bridgeLabelsTimeClassificationAndPrefixDeduplication() async throws {
        // 1. Pure number & time bridge labels (zero `¥` symbol)
        let summary = DocumentDiffSummary(
            comparedToAssetID: UUID(),
            addedBlocks: 10,
            removedBlocks: 4,
            modifiedBlocks: 12,
            movedBlocks: 0,
            highRiskNumberChanges: 2,
            highRiskDateChanges: 5
        )
        #expect(summary.compactBridgeLabel == "Δ 26处 · 数字2 · 时间5")
        #expect(!summary.compactBridgeLabel.contains("¥"))
        #expect(DocumentDiffRiskFlag.numberOrCurrency.localizedLabel == "数字变动")
        #expect(DocumentDiffRiskFlag.dateOrDeadline.localizedLabel == "日期时间")

        // 2. Clock times (`14:30 -> 15:00`), spoken Chinese times, years/year-ranges, and dotted dates
        // must count ONLY as `highRiskDateChanges` with `highRiskNumberChanges == 0`!
        let basePayload = StructuredDocumentPayload(
            assetID: UUID(),
            formatFamily: DocumentFormatFamily.docx.rawValue,
            title: "会议通知_v1",
            blocks: [
                DocumentBlock(id: "b0", index: 0, kind: .paragraph, text: "一、集中评审会定于 14:30 准时开始，请下午2点15分前签到。"),
                DocumentBlock(id: "b1", index: 1, kind: .paragraph, text: "二、围绕 2024—2025年度 工作台账及 5.12的通报 开展复盘，于 2025年 完成归档。")
            ],
            plainText: ""
        )
        let targetPayload = StructuredDocumentPayload(
            assetID: UUID(),
            formatFamily: DocumentFormatFamily.docx.rawValue,
            title: "会议通知_v2",
            blocks: [
                DocumentBlock(id: "t0", index: 0, kind: .paragraph, text: "一、集中评审会定于 15:00 准时开始，请下午2点45分前签到。"),
                DocumentBlock(id: "t1", index: 1, kind: .paragraph, text: "二、围绕 2025—2026年度 工作台账及 5.18的通报 开展复盘，于 2026年 完成归档。")
            ],
            plainText: ""
        )

        let timeOnlyReport = DocumentDiffEngine.compare(base: basePayload, target: targetPayload)
        #expect(timeOnlyReport.summary.highRiskDateChanges >= 4)
        #expect(timeOnlyReport.summary.highRiskNumberChanges == 0)
        #expect(timeOnlyReport.summary.compactBridgeLabel.contains("时间"))
        #expect(!timeOnlyReport.summary.compactBridgeLabel.contains("数字"))
        for hunk in timeOnlyReport.hunks where hunk.changeKind.isChanged {
            #expect(hunk.riskFlags.contains(.dateOrDeadline))
            #expect(!hunk.riskFlags.contains(.numberOrCurrency))
        }

        // Meanwhile genuine decimal/count edits (`12.5万元 -> 15.2万元`, `3处 -> 5处`) still register as `highRiskNumberChanges`!
        let numBase = StructuredDocumentPayload(
            assetID: UUID(),
            formatFamily: DocumentFormatFamily.docx.rawValue,
            title: "预算_v1",
            blocks: [DocumentBlock(id: "n0", index: 0, kind: .paragraph, text: "整改预算为 12.5万元，涉及隐患 3处。")]
        )
        let numTarget = StructuredDocumentPayload(
            assetID: UUID(),
            formatFamily: DocumentFormatFamily.docx.rawValue,
            title: "预算_v2",
            blocks: [DocumentBlock(id: "n0", index: 0, kind: .paragraph, text: "整改预算为 15.2万元，涉及隐患 5处。")]
        )
        let numReport = DocumentDiffEngine.compare(base: numBase, target: numTarget)
        #expect(numReport.summary.highRiskNumberChanges >= 1)
        #expect(numReport.summary.highRiskDateChanges == 0)
        #expect(numReport.summary.compactBridgeLabel.contains("数字"))

        // 3. Redundant version prefix stripping (`v1 v1`, `v2 v2 · Name`) & Office extension classification
        #expect(AssetVersionStackMetadata.strippingRedundantVersionPrefix("v1") == "")
        #expect(AssetVersionStackMetadata.strippingRedundantVersionPrefix("v1 · 初稿") == "初稿")
        #expect(AssetVersionStackMetadata.strippingRedundantVersionPrefix("v2 v2 · 张主任") == "张主任")
        #expect(AssetVersionStackMetadata.strippingRedundantVersionPrefix("V3: 终审定稿") == "终审定稿")

        let metaV1 = AssetVersionStackMetadata(groupID: UUID(), versionNumber: 1, versionLabel: "v1")
        let metaV2 = AssetVersionStackMetadata(groupID: UUID(), versionNumber: 2, versionLabel: "v2 v2 · 张主任")
        #expect(metaV1.displayBadgeText == "v1")
        #expect(metaV2.displayBadgeText == "v2 · 张主任")

        for officeExt in ["docx", "doc", "wps", "xlsx", "xls", "et", "pptx", "ppt", "dps", "rtf", "pages", "numbers", "key", "odt", "epub", "ofd"] {
            #expect(MediaPipeline.isRichLayoutDocumentExtension(officeExt))
        }
        for textExt in ["md", "markdown", "txt", "json", "yaml", "yml", "toml", "csv"] {
            #expect(!MediaPipeline.isRichLayoutDocumentExtension(textExt))
        }

        // 4. Idempotent legacy Office thumbnail upgrade call safety
        let dir = try BackendFixture.directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let engine = try BackendFixture.makeEngine(dir)
        let firstUpgrade = await engine.upgradeLegacyOfficeDocumentThumbnailsIfNeeded()
        let secondUpgrade = await engine.upgradeLegacyOfficeDocumentThumbnailsIfNeeded()
        #expect(firstUpgrade.isEmpty)
        #expect(secondUpgrade.isEmpty)
    }

    // MARK: - Test Fixture Builders

    private static func makePlainParagraphDOCX(
        paragraphs: [String],
        lastModifiedBy: String
    ) throws -> Data {
        let pXML = paragraphs.map { text in
            "<w:p><w:r><w:t xml:space=\"preserve\">\(DocumentTwoWaySynthesizer.escapeXMLText(text))</w:t></w:r></w:p>"
        }.joined(separator: "\n")
        return try makeSampleDOCXData(lastModifiedBy: lastModifiedBy, paragraphsXML: pXML)
    }

    private static func makeSampleDOCXData(
        lastModifiedBy: String,
        paragraphsXML: String,
        commentsXML: String? = nil,
        stylesBytes: Data? = nil,
        mediaBytes: Data? = nil
    ) throws -> Data {
        var writer = ZipArchiveWriter()
        let contentTypes = """
        <?xml version="1.0" encoding="UTF-8"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
          <Default Extension="xml" ContentType="application/xml"/>
          <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
        </Types>
        """
        let coreXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" xmlns:dc="http://purl.org/dc/elements/1.1/">
          <dc:creator>\(lastModifiedBy)</dc:creator>
          <cp:lastModifiedBy>\(lastModifiedBy)</cp:lastModifiedBy>
        </cp:coreProperties>
        """
        let docXML = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
          <w:body>
            \(paragraphsXML)
            <w:sectPr><w:pgSz w:w="11906" w:h="16838"/></w:sectPr>
          </w:body>
        </w:document>
        """
        try writer.addEntry(name: "[Content_Types].xml", data: Data(contentTypes.utf8))
        try writer.addEntry(name: "docProps/core.xml", data: Data(coreXML.utf8))
        try writer.addEntry(name: "word/document.xml", data: Data(docXML.utf8))
        if let commentsXML {
            try writer.addEntry(name: "word/comments.xml", data: Data(commentsXML.utf8))
        }
        if let stylesBytes {
            try writer.addEntry(name: "word/styles.xml", data: stylesBytes)
        }
        if let mediaBytes {
            try writer.addEntry(name: "word/media/seal.bin", data: mediaBytes, compress: false)
        }
        return try writer.finalize()
    }

    private static func makeSampleXLSXData(
        sheetName: String,
        rows: [(cells: [String], formulas: [Int: String])],
        lastModifiedBy: String = "制表人"
    ) throws -> Data {
        var writer = ZipArchiveWriter()
        var sharedStrings: [String] = []
        var sstIndex: [String: Int] = [:]

        func intern(_ s: String) -> Int {
            if let existing = sstIndex[s] { return existing }
            let idx = sharedStrings.count
            sharedStrings.append(s)
            sstIndex[s] = idx
            return idx
        }

        var rowXMLParts: [String] = []
        for (rIdx, row) in rows.enumerated() {
            let rowNum = rIdx + 1
            var cellParts: [String] = []
            for (cIdx, val) in row.cells.enumerated() {
                let colLetter = String(UnicodeScalar(UInt8(0x41 + cIdx)))
                let addr = "\(colLetter)\(rowNum)"
                let formulaXML = row.formulas[cIdx].map { "<f>\(DocumentTwoWaySynthesizer.escapeXMLText($0))</f>" } ?? ""
                if Double(val) != nil {
                    cellParts.append("<c r=\"\(addr)\">\(formulaXML)<v>\(val)</v></c>")
                } else {
                    let sIdx = intern(val)
                    cellParts.append("<c r=\"\(addr)\" t=\"s\">\(formulaXML)<v>\(sIdx)</v></c>")
                }
            }
            rowXMLParts.append("<row r=\"\(rowNum)\">\(cellParts.joined())</row>")
        }

        let sstXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <sst xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
          \(sharedStrings.map { "<si><t>\(DocumentTwoWaySynthesizer.escapeXMLText($0))</t></si>" }.joined())
        </sst>
        """
        let wbXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
          <sheets><sheet name="\(DocumentTwoWaySynthesizer.escapeXMLText(sheetName))" sheetId="1" r:id="rId1"/></sheets>
        </workbook>
        """
        let relsXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
          <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/>
        </Relationships>
        """
        let sheetXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
          <sheetData>\(rowXMLParts.joined())</sheetData>
        </worksheet>
        """
        let coreXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties">
          <cp:lastModifiedBy>\(DocumentTwoWaySynthesizer.escapeXMLText(lastModifiedBy))</cp:lastModifiedBy>
        </cp:coreProperties>
        """

        try writer.addEntry(name: "docProps/core.xml", data: Data(coreXML.utf8))
        try writer.addEntry(name: "xl/sharedStrings.xml", data: Data(sstXML.utf8))
        try writer.addEntry(name: "xl/workbook.xml", data: Data(wbXML.utf8))
        try writer.addEntry(name: "xl/_rels/workbook.xml.rels", data: Data(relsXML.utf8))
        try writer.addEntry(name: "xl/worksheets/sheet1.xml", data: Data(sheetXML.utf8))
        return try writer.finalize()
    }

    private static func makeRasterScannedPDF(lines: [String], to url: URL) throws {
        let width = 1000
        let height = 1400
        let ctx = try #require(MediaArtwork.context(width: width, height: height))
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))

        for (idx, line) in lines.enumerated() {
            MediaArtwork.draw(
                line,
                in: ctx,
                at: CGPoint(x: 80, y: Double(height - 180 - idx * 90)),
                size: 48,
                ink: 0x111111,
                width: 840,
                bold: true
            )
        }
        let cgImage = try #require(ctx.makeImage())
        let pdfData = NSMutableData()
        var mediaBox = CGRect(x: 0, y: 0, width: 595, height: 842)
        let consumer = try #require(CGDataConsumer(data: pdfData as CFMutableData))
        let pdfCtx = try #require(CGContext(consumer: consumer, mediaBox: &mediaBox, nil))
        pdfCtx.beginPDFPage(nil)
        pdfCtx.draw(cgImage, in: mediaBox)
        pdfCtx.endPDFPage()
        pdfCtx.closePDF()
        try (pdfData as Data).write(to: url)
    }
}
