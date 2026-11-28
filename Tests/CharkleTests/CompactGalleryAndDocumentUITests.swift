import AppKit
@testable import CharkleCanvas
@testable import CharkleCore
import CoreGraphics
import Foundation
import PDFKit
import Testing

@Suite("Compact Index Gallery, Version Stacks & Document Studio Tests", .serialized)
struct CompactGalleryAndDocumentUITests {

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // CharkleTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // repo root
    }

    private func readSource(_ relativePath: String) throws -> String {
        let url = Self.repoRoot.appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func allAppSwiftFiles() throws -> [URL] {
        let root = Self.repoRoot.appendingPathComponent("Sources/CharkleApp", isDirectory: true)
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        var files: [URL] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            files.append(url)
        }
        return files.sorted { $0.path < $1.path }
    }

    private static func writeTestPDF(
        to url: URL,
        mediaBox: CGRect = CGRect(x: 0, y: 0, width: 300, height: 300),
        filledRects: [(rect: CGRect, r: CGFloat, g: CGFloat, b: CGFloat)]
    ) throws {
        var box = mediaBox
        guard let consumer = CGDataConsumer(url: url as CFURL),
              let ctx = CGContext(consumer: consumer, mediaBox: &box, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        ctx.beginPDFPage(nil)
        ctx.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        ctx.fill(mediaBox)
        for item in filledRects {
            ctx.setFillColor(red: item.r, green: item.g, blue: item.b, alpha: 1)
            ctx.fill(item.rect)
        }
        ctx.endPDFPage()
        ctx.closePDF()
    }

    // MARK: - 1. 5th Gallery Layout Mode (`compactList`) & Tactile Index Geometry

    @Test("GalleryLayoutMode.compactList and CompactIndexLayoutMetrics enforce responsive columns, Reduce Motion, and 12-segment minimaps")
    func compactLayoutModeAndMicroFolioMetrics() {
        #expect(GalleryLayoutMode.allCases.contains(.compactList))
        #expect(GalleryLayoutMode.compactList.rawValue == "compactList")
        #expect(GalleryLayoutMode.compactList.localizedLabel == "紧凑视图")

        // 2-Column Tactile Index Grid collapses cleanly to 1 column below 680pt
        #expect(CompactIndexLayoutMetrics.effectiveColumnCount(viewportWidth: 1180, preferredColumnMode: 2) == 2)
        #expect(CompactIndexLayoutMetrics.effectiveColumnCount(viewportWidth: 680, preferredColumnMode: 2) == 2)
        #expect(CompactIndexLayoutMetrics.effectiveColumnCount(viewportWidth: 679, preferredColumnMode: 2) == 1)
        #expect(CompactIndexLayoutMetrics.effectiveColumnCount(viewportWidth: 1280, preferredColumnMode: 1) == 1)

        // 3D Micro-Folio hover fan-out vs Reduce Motion suppression
        let hoveredPoses = CompactIndexLayoutMetrics.microFolioLayerPoses(isHovered: true, reduceMotion: false)
        #expect(hoveredPoses.mid.rotationYDegrees < 0)
        #expect(hoveredPoses.front.rotationYDegrees < hoveredPoses.mid.rotationYDegrees)
        #expect(hoveredPoses.back.offsetX > 6)

        let reducedPoses = CompactIndexLayoutMetrics.microFolioLayerPoses(isHovered: true, reduceMotion: true)
        let idlePoses = CompactIndexLayoutMetrics.microFolioLayerPoses(isHovered: false, reduceMotion: false)
        #expect(reducedPoses.back == idlePoses.back)
        #expect(reducedPoses.mid == idlePoses.mid)
        #expect(reducedPoses.front == idlePoses.front)
        #expect(reducedPoses.front.rotationYDegrees == 0)

        // 12-Segment Diff Minimap normalization & bridge label formatting
        let summary = DocumentDiffSummary(
            comparedToAssetID: UUID(),
            addedBlocks: 2,
            removedBlocks: 1,
            modifiedBlocks: 3,
            movedBlocks: 0,
            highRiskNumberChanges: 1,
            highRiskDateChanges: 2,
            minimapBuckets: [0, 1, 2, 0]
        )
        let tones = CompactIndexLayoutMetrics.normalizedMinimapTones(for: summary)
        #expect(tones.count == 12)
        #expect(tones.contains(.addedOrModified))
        #expect(tones.contains(.highRisk))
        #expect(summary.compactBridgeLabel == "Δ 6处 · ¥1 · 时限2")
    }

    @Test("MasonryLayoutEngine, MasonryStaticLayerAssets, and MasonryCardGeometryRegistry support compactList and Version Stack document cards")
    @MainActor
    func masonryDocumentCardAndExternalGeometryBridge() {
        let groupID = UUID()
        let docAsset = AssetRecord(
            title: "2026框架采购协议（法务审定版）",
            fileName: "2026框架采购协议_v4.docx",
            mediaKind: .document,
            fileSizeBytes: 248_000,
            ocrText: "第一条 采购标的与交付周期约定如下",
            richMetadata: AssetRichMetadata(
                versionStack: AssetVersionStackMetadata(
                    groupID: groupID,
                    versionNumber: 4,
                    editorName: "法务部",
                    isPinnedPrimary: true
                ),
                document: DocumentRichMetadata(
                    formatFamily: DocumentFormatFamily.docx.rawValue,
                    wordCount: 4_280,
                    pageCount: 12,
                    hasNativeRevisions: true
                )
            )
        )
        let sheetAsset = AssetRecord(
            title: "Q4预算总表",
            fileName: "Q4预算总表.xlsx",
            mediaKind: .document,
            richMetadata: AssetRichMetadata(
                document: DocumentRichMetadata(
                    formatFamily: DocumentFormatFamily.xlsx.rawValue,
                    sheetNames: ["汇总", "研发明细"]
                )
            )
        )

        let layout = MasonryLayoutEngine.compute(
            assets: [docAsset, sheetAsset],
            layoutMode: .compactList,
            containerWidth: 960,
            targetColumnWidth: 240,
            spacing: 14,
            horizontalPadding: 20,
            topInset: 56,
            bottomInset: 28
        )
        #expect(layout.items.count == 2)
        #expect(layout.totalHeight > 0)

        let docCardDark = MasonryStaticLayerAssets.proceduralCardImage(
            for: docAsset,
            size: CGSize(width: 240, height: 300),
            isDark: true,
            scale: 2.0
        )
        let sheetCardLight = MasonryStaticLayerAssets.proceduralCardImage(
            for: sheetAsset,
            size: CGSize(width: 240, height: 300),
            isDark: false,
            scale: 2.0
        )
        #expect(docCardDark != nil && (docCardDark?.width ?? 0) > 0)
        #expect(sheetCardLight != nil && (sheetCardLight?.width ?? 0) > 0)

        // External rect bridge enables Quick Look zoom continuity from CompactIndexGalleryView
        let registry = MasonryCardGeometryRegistry.shared
        let expectedRect = CGRect(x: 42, y: 120, width: 380, height: 68)
        registry.externalCardRectProvider = { queriedID in
            queriedID == docAsset.id ? expectedRect : nil
        }
        defer { registry.externalCardRectProvider = nil }
        #expect(registry.visibleCardRectInWindow(for: docAsset.id) == expectedRect)
    }

    // MARK: - 2. Version Stack Primary-Pin Anti-Override & `+N 新版` Resolution

    @Test("AssetVersionStackMetadata preserves pinned Primary Version v4 when newer v5 arrives and reports +1 newer badge")
    func versionStackPrimaryPinAntiOverride() {
        let groupID = UUID()
        let baseDate = Date(timeIntervalSince1970: 1_730_000_000)

        let v3 = AssetRecord(
            title: "年度采购合同",
            fileName: "年度采购合同_v3.docx",
            mediaKind: .document,
            createdAt: baseDate,
            richMetadata: AssetRichMetadata(
                versionStack: AssetVersionStackMetadata(groupID: groupID, versionNumber: 3, editorName: "采购组")
            )
        )
        let v4Pinned = AssetRecord(
            title: "年度采购合同",
            fileName: "年度采购合同_v4_主版.docx",
            mediaKind: .document,
            createdAt: baseDate.addingTimeInterval(600),
            richMetadata: AssetRichMetadata(
                versionStack: AssetVersionStackMetadata(
                    groupID: groupID,
                    versionNumber: 4,
                    editorName: "我",
                    changeNote: "定稿主版",
                    isPinnedPrimary: true
                )
            )
        )
        let v5External = AssetRecord(
            title: "年度采购合同",
            fileName: "年度采购合同_v5_供应商反馈.docx",
            mediaKind: .document,
            createdAt: baseDate.addingTimeInterval(1_200),
            richMetadata: AssetRichMetadata(
                versionStack: AssetVersionStackMetadata(
                    groupID: groupID,
                    versionNumber: 5,
                    editorName: "供应商",
                    changeNote: "调整付款比例",
                    isPinnedPrimary: false
                )
            )
        )

        let shuffled = [v5External, v3, v4Pinned]
        let ordered = AssetVersionStackMetadata.sortedVersions(shuffled)
        #expect(ordered.map(\.id) == [v3.id, v4Pinned.id, v5External.id])

        // Critical invariant: incoming v5 MUST NOT silently override explicitly pinned v4!
        let resolvedPrimary = AssetVersionStackMetadata.resolvePrimaryAsset(in: shuffled)
        #expect(resolvedPrimary?.id == v4Pinned.id)
        #expect(AssetVersionStackMetadata.newerThanPrimaryCount(in: shuffled) == 1)

        // When no sibling is explicitly pinned, fallback resolves to highest versionNumber (v5)
        var v4Unpinned = v4Pinned
        v4Unpinned.richMetadata?.versionStack?.isPinnedPrimary = false
        let fallbackPrimary = AssetVersionStackMetadata.resolvePrimaryAsset(in: [v3, v4Unpinned, v5External])
        #expect(fallbackPrimary?.id == v5External.id)
        #expect(AssetVersionStackMetadata.newerThanPrimaryCount(in: [v3, v4Unpinned, v5External]) == 0)
    }

    // MARK: - 3. High-Risk Radar Filtering, J/K Stepping & Scheme B 2-Way Merge Preview

    @Test("DocumentRadarFilterEngine and DocumentComparisonReport.previewMergedText enforce High-Risk Radar and complex-block merge safety")
    func highRiskRadarAndTwoWayMergePreview() {
        let baseID = UUID()
        let targetID = UUID()

        let hUnchanged = DocumentDiffHunk(
            id: "h-0",
            hunkIndex: 0,
            changeKind: .unchanged,
            baseText: "第一章 总则",
            targetText: "第一章 总则"
        )
        let hMoney = DocumentDiffHunk(
            id: "h-1",
            hunkIndex: 1,
            changeKind: .modified,
            sectionTitle: "第三条 合同总价",
            baseText: "合同总金额为人民币 120 万元整。",
            targetText: "合同总金额为人民币 135 万元整。",
            highRiskPairs: [
                DocumentHighRiskValuePair(id: "p-1", flag: .numberOrCurrency, oldValue: "120 万元", newValue: "135 万元")
            ],
            riskFlags: [.numberOrCurrency]
        )
        let hDeadline = DocumentDiffHunk(
            id: "h-2",
            hunkIndex: 2,
            changeKind: .modified,
            sectionTitle: "第五条 交付周期",
            baseText: "签订后 30 个工作日内完成验收。",
            targetText: "签订后 15 个自然日内完成验收。",
            riskFlags: [.dateOrDeadline]
        )
        let hMoved = DocumentDiffHunk(
            id: "h-3",
            hunkIndex: 3,
            changeKind: .moved,
            movedFromIndex: 1,
            movedToIndex: 4,
            baseText: "保密义务在合同终止后三年内持续有效。",
            targetText: "保密义务在合同终止后三年内持续有效。"
        )
        let hProtectedTable = DocumentDiffHunk(
            id: "h-4",
            hunkIndex: 4,
            changeKind: .modified,
            blockKind: .table,
            baseText: "附件报价表（旧）",
            targetText: "附件报价表（新）",
            tableCellDiffs: [
                DocumentTableCellDiff(
                    rowIndex: 0,
                    colIndex: 2,
                    rowKey: "服务器节点",
                    columnHeader: "单价",
                    changeKind: .modified,
                    oldValue: "8,000",
                    newValue: "7,600",
                    riskFlags: [.tableMutation, .numberOrCurrency]
                )
            ],
            riskFlags: [.tableMutation],
            isProtectedComplex: true,
            protectionReason: "嵌套合并单元格受保护"
        )
        let hRevision = DocumentDiffHunk(
            id: "h-5",
            hunkIndex: 5,
            changeKind: .modified,
            baseText: "争议提交仲裁委员会解决。",
            targetText: "争议提交合同签订地人民法院诉讼解决。",
            riskFlags: [.nativeRevisionOrComment]
        )

        let report = DocumentComparisonReport(
            baseAssetID: baseID,
            targetAssetID: targetID,
            baseTitle: "v4 主版",
            targetTitle: "v5 外部反馈",
            formatFamily: DocumentFormatFamily.docx.rawValue,
            summary: DocumentDiffSummary(
                comparedToAssetID: baseID,
                modifiedBlocks: 4,
                movedBlocks: 1,
                highRiskNumberChanges: 1,
                highRiskDateChanges: 1
            ),
            hunks: [hUnchanged, hMoney, hDeadline, hMoved, hProtectedTable, hRevision],
            commentDiffs: [
                DocumentCommentDiff(
                    changeKind: .added,
                    comment: DocumentComment(id: "c-1", author: "法务王工", text: "请核实管辖法院变更")
                )
            ],
            canSynthesizeTwoWay: true
        )

        // Radar filters
        #expect(DocumentRadarFilterEngine.filterDiffHunks(report.hunks, radar: .all, onlyChanged: true).map(\.id) == ["h-1", "h-2", "h-3", "h-4", "h-5"])
        #expect(DocumentRadarFilterEngine.filterDiffHunks(report.hunks, radar: .all, onlyChanged: false).count == 6)
        #expect(DocumentRadarFilterEngine.filterDiffHunks(report.hunks, radar: .numberOrCurrency, onlyChanged: true).map(\.id) == ["h-1"])
        #expect(DocumentRadarFilterEngine.filterDiffHunks(report.hunks, radar: .dateOrDeadline, onlyChanged: true).map(\.id) == ["h-2"])
        #expect(DocumentRadarFilterEngine.filterDiffHunks(report.hunks, radar: .tableMutation, onlyChanged: true).map(\.id) == ["h-4"])
        #expect(DocumentRadarFilterEngine.radarBadgeCount(in: report, for: .nativeRevisionOrComment) == 2)

        // J / K cyclic stepping
        let changedOnly = DocumentRadarFilterEngine.filterDiffHunks(report.hunks, radar: .all, onlyChanged: true)
        #expect(DocumentRadarFilterEngine.nextFocusedHunkID(in: changedOnly, currentFocusedID: nil, delta: 1) == "h-1")
        #expect(DocumentRadarFilterEngine.nextFocusedHunkID(in: changedOnly, currentFocusedID: "h-1", delta: 1) == "h-2")
        #expect(DocumentRadarFilterEngine.nextFocusedHunkID(in: changedOnly, currentFocusedID: "h-1", delta: -1) == "h-5")

        // Scheme B 2-Way Merge preview: reject risky money change (keepBase), tweak deadline inline (customText),
        // and verify complex protected table ignores illegal customText override!
        let mergedPreview = report.previewMergedText(
            preferTargetAsTemplate: true,
            decisions: [
                DocumentMergeDecision(hunkID: "h-1", choice: .keepBase),
                DocumentMergeDecision(hunkID: "h-2", choice: .customText, customText: "签订后 20 个工作日内完成验收。"),
                DocumentMergeDecision(hunkID: "h-4", choice: .customText, customText: "非法覆盖受保护表格")
            ]
        )
        #expect(mergedPreview.contains("120 万元"))
        #expect(!mergedPreview.contains("135 万元"))
        #expect(mergedPreview.contains("签订后 20 个工作日内完成验收。"))
        #expect(mergedPreview.contains("附件报价表（新）"))
        #expect(!mergedPreview.contains("非法覆盖受保护表格"))
    }

    // MARK: - 4. PDF Visual Page Overlay Diff (Red-Cyan Difference Blend & Real PDF Rasterization)

    @Test("PDFVisualDiffRenderer rasterizes real PDF pages and distinguishes unchanged grey ink, removed Red ink, and added Cyan-Blue stamps")
    func pdfVisualRedCyanOverlayDiff() async throws {
        // Direct deterministic pixel verification on Red-Cyan difference compositor:
        // Pixel 0: white paper -> white
        // Pixel 1: dark ink in both -> neutral grey
        // Pixel 2: dark ink in Base, white in Target -> vivid Red (removed/shifted)
        // Pixel 3: white in Base, dark stamp in Target -> crisp Studio Cyan-Blue (added)
        let basePixels: [UInt8] = [
            255, 255, 255, 255,
            20,  20,  20,  255,
            15,  15,  15,  255,
            255, 255, 255, 255
        ]
        let targetPixels: [UInt8] = [
            255, 255, 255, 255,
            22,  22,  22,  255,
            255, 255, 255, 255,
            18,  18,  18,  255
        ]
        let composite = PDFVisualDiffRenderer.makeRedCyanOverlayRGBA(
            baseRGBA: basePixels,
            targetRGBA: targetPixels,
            pixelCount: 4
        )
        #expect(composite.count == 16)
        // Pixel 0: white paper stays white
        #expect(composite[0] == 255 && composite[1] == 255 && composite[2] == 255)
        // Pixel 1: unchanged ink -> equal RGB channels (calm neutral grey)
        #expect(composite[4] == composite[5] && composite[5] == composite[6] && composite[4] < 120)
        // Pixel 2: removed from Base -> Red dominant
        #expect(composite[8] == 235)
        #expect(Int(composite[8]) - Int(composite[9]) > 150)
        #expect(Int(composite[8]) - Int(composite[10]) > 150)
        // Pixel 3: added in Target -> Cyan-Blue dominant
        #expect(composite[14] == 242)
        #expect(Int(composite[14]) - Int(composite[12]) > 150)

        // End-to-end CoreGraphics PDF file generation + async off-main-thread rasterization
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("charkle_pdf_diff_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let basePDF = tmpDir.appendingPathComponent("contract_unsigned.pdf")
        let targetPDF = tmpDir.appendingPathComponent("contract_stamped.pdf")

        try Self.writeTestPDF(
            to: basePDF,
            filledRects: [
                (CGRect(x: 30, y: 220, width: 240, height: 40), 0.1, 0.1, 0.1), // shared header
                (CGRect(x: 30, y: 40, width: 80, height: 50), 0.1, 0.1, 0.1)    // removed clause box
            ]
        )
        try Self.writeTestPDF(
            to: targetPDF,
            filledRects: [
                (CGRect(x: 30, y: 220, width: 240, height: 40), 0.1, 0.1, 0.1), // shared header
                (CGRect(x: 180, y: 40, width: 80, height: 50), 0.8, 0.1, 0.1)   // added stamp box
            ]
        )

        let rendered = await PDFVisualDiffRenderer.renderComparisonPages(
            baseURL: basePDF,
            targetURL: targetPDF,
            pageIndex: 0,
            maxDimension: 240
        )
        #expect(rendered.pageCount == 1)
        #expect(rendered.pixelWidth == 240 && rendered.pixelHeight == 240)
        #expect(rendered.baseImage != nil)
        #expect(rendered.targetImage != nil)
        #expect(rendered.redCyanComposite != nil)

        var hasRedDiffPixel = false
        var hasCyanDiffPixel = false
        let rgba = rendered.compositeRGBA
        for px in 0..<(rendered.pixelWidth * rendered.pixelHeight) {
            let o = px * 4
            let r = Int(rgba[o])
            let g = Int(rgba[o + 1])
            let b = Int(rgba[o + 2])
            if r > 220 && r - g > 90 && r - b > 90 {
                hasRedDiffPixel = true
            }
            if b > 220 && b - r > 90 {
                hasCyanDiffPixel = true
            }
        }
        #expect(hasRedDiffPixel)
        #expect(hasCyanDiffPixel)
    }

    // MARK: - 5. CharkleApp Store, View & Guardrail Contracts

    @Test("CharkleApp wires CompactIndexGalleryView, per-destination layout persistence, Version Stack folding, JumpAnywhere Cmd+C, Notch/Gallery drop prompts, Inspector parity, and Document Studio")
    func macOSAppIntegrationAndGuardrailContracts() throws {
        let compactView = try readSource("Sources/CharkleApp/Views/CompactIndexGalleryView.swift")
        let docStudio = try readSource("Sources/CharkleApp/Views/QuickLookDocumentStudioView.swift")
        let qlOverlay = try readSource("Sources/CharkleApp/Views/QuickLookOverlayView.swift")
        let mainWindow = try readSource("Sources/CharkleApp/Views/MainWindowView.swift")
        let libraryStore = try readSource("Sources/CharkleApp/Stores/LibraryStore.swift")
        let coordStore = try readSource("Sources/CharkleApp/Stores/AppCoordinatorStore.swift")
        let jumpView = try readSource("Sources/CharkleApp/Views/JumpAnywhereView.swift")
        let inspector = try readSource("Sources/CharkleApp/Views/InspectorView.swift")
        let notchView = try readSource("Sources/CharkleApp/Notch/NotchShelfView.swift")
        let notchCtrl = try readSource("Sources/CharkleApp/Notch/NotchShelfController.swift")
        let onboarding = try readSource("Sources/CharkleApp/Views/OnboardingView.swift")
        let settings = try readSource("Sources/CharkleApp/Views/Settings/GeneralSettingsPane.swift")
        let appEntry = try readSource("Sources/CharkleApp/CharkleAppEntry.swift")
        let iconMap = try readSource("Sources/CharkleApp/DesignSystem/CharkleIcon.swift")

        // 1. 5th Gallery Mode (`compactList`, shortcut `5`, per-destination persistence, Onboarding & Settings)
        #expect(iconMap.contains("\"compact-list\": \"list.bullet\""))
        #expect(coordStore.contains("destinationLayoutOverrides"))
        #expect(coordStore.contains("selectGalleryLayoutModeForCurrentDestination"))
        #expect(coordStore.contains("applySavedLayoutMode(for destination:"))
        #expect(mainWindow.contains("CompactIndexGalleryView("))
        #expect(mainWindow.contains("(1...GalleryLayoutMode.allCases.count).contains(digit)"))
        #expect(onboarding.contains("case .compactList:"))
        #expect(settings.contains("setDefaultGalleryLayoutMode"))
        #expect(appEntry.contains("画廊视图排布"))

        // 2. CompactIndexGalleryView V2 visual & interaction fidelity
        #expect(compactView.contains("双列索引卡"))
        #expect(compactView.contains("单列折页条"))
        #expect(compactView.contains("CompactMicroFolioArtifact"))
        #expect(compactView.contains("rotation3DEffect"))
        #expect(compactView.contains("revisionRailSection("))
        #expect(compactView.contains("设为主版"))
        #expect(compactView.contains("cachedPrimaryDragFileURL"))
        #expect(compactView.contains("CompactCardStackDropDelegate"))

        // 3. LibraryStore Version Stack folding & Primary Version file drag/copy invariant
        #expect(libraryStore.contains("foldVersionStacks("))
        #expect(libraryStore.contains("primaryVersionAsset(for:"))
        #expect(libraryStore.contains("cachedPrimaryDragFileURL(for assetID:"))
        #expect(libraryStore.contains("preferStackPrimary: Bool = true"))
        #expect(libraryStore.contains("ingestAndDetectStackPrompt("))
        #expect(libraryStore.contains("confirmPendingVersionStackPrompt("))

        // 4. Active drop stacking prompt in both MainWindowView and NotchShelfView + Inspector CharkleDisclosureGroup
        #expect(mainWindow.contains("versionStackDropPromptBanner("))
        #expect(notchView.contains("notchVersionStackPromptBar("))
        #expect(notchCtrl.contains("ingestAndDetectStackPrompt("))
        #expect(inspector.contains("singleAssetVersionStackSection("))
        #expect(inspector.contains("CharkleInspectorSection(\"版本叠\""))
        #expect(inspector.contains("CharkleDisclosureGroup(isExpanded: $isVersionStackExpanded"))

        // 5. JumpAnywhere Cmd+C copies Primary Version original file directly to NSPasteboard.general
        #expect(jumpView.contains("copyAssetMatchToPasteboard("))
        #expect(jumpView.contains("preferStackPrimary: true"))
        #expect(jumpView.contains("切微信直接 ⌘V 发送"))

        // 6. Quick Look Document Studio: readers, High-Risk Radar, Split Curtain Wipe, Red-Cyan Overlay, and 2-Way Merge
        #expect(qlOverlay.contains("QuickLookDocumentStudioView("))
        #expect(docStudio.contains("PDFSplitCurtainComparisonView"))
        #expect(docStudio.contains("PDFVisualDiffRenderer.renderComparisonPages"))
        #expect(docStudio.contains("按差异合成新版本"))
        #expect(docStudio.contains("仅看改动段落"))
        #expect(docStudio.contains("用默认应用打开"))
    }

    @Test("All macOS SwiftUI views obey AGENTS.md & DESIGN.md invariants: verified SF Symbols, zero bare DisclosureGroup, borderless Menu sizing, modifier masking, and zero violet hues")
    func macOSDesignSystemAndEventGuardrails() throws {
        let appFiles = try allAppSwiftFiles()
        #expect(!appFiles.isEmpty)

        let bareDisclosureRegex = try NSRegularExpression(pattern: #"(?<![A-Za-z0-9_])DisclosureGroup\s*\("#)
        let forbiddenVioletTokens = ["8B5CF6", "7C3AED", "A855F7", "9333EA"].map { "#" + $0 } + ["Color.purple", "Color.indigo"]

        for fileURL in appFiles {
            let text = try String(contentsOf: fileURL, encoding: .utf8)
            let name = fileURL.lastPathComponent
            let fullNSRange = NSRange(text.startIndex..<text.endIndex, in: text)

            // Never use bare SwiftUI DisclosureGroup (always CharkleDisclosureGroup)
            #expect(
                bareDisclosureRegex.firstMatch(in: text, range: fullNSRange) == nil,
                "Bare DisclosureGroup found in \(name)"
            )

            // Never test unmodified keys with .deviceIndependentFlagsMask
            #expect(!text.contains("intersection(.deviceIndependentFlagsMask).isEmpty"), "Forbidden deviceIndependentFlagsMask check in \(name)")

            // Zero violet/purple tokens in newly created/updated files
            if ["CompactIndexGalleryView.swift", "QuickLookDocumentStudioView.swift"].contains(name) {
                for token in forbiddenVioletTokens {
                    #expect(!text.localizedCaseInsensitiveContains(token), "Forbidden violet token \(token) in \(name)")
                }
            }

            // Every .menuStyle(.borderlessButton) must be paired with .menuIndicator(.hidden) and .fixedSize()
            if text.contains(".menuStyle(.borderlessButton)") {
                let parts = text.components(separatedBy: ".menuStyle(.borderlessButton)")
                for idx in 1..<parts.count {
                    let windowAfter = String(parts[idx].prefix(220))
                    let windowBefore = String(parts[idx - 1].suffix(220))
                    let combined = windowBefore + windowAfter
                    #expect(combined.contains(".menuIndicator(.hidden)"), "Missing .menuIndicator(.hidden) near .menuStyle(.borderlessButton) in \(name)")
                    #expect(combined.contains(".fixedSize()"), "Missing .fixedSize() near .menuStyle(.borderlessButton) in \(name)")
                }
            }
        }

        // Verify every literal SF Symbol referenced in our touched files exists on macOS
        let symbolCheckPaths = [
            "Sources/CharkleApp/DesignSystem/CharkleIcon.swift",
            "Sources/CharkleApp/Views/CompactIndexGalleryView.swift",
            "Sources/CharkleApp/Views/QuickLookDocumentStudioView.swift",
            "Sources/CharkleApp/Views/InspectorView.swift",
            "Sources/CharkleApp/Views/JumpAnywhereView.swift"
        ]
        let regex = try NSRegularExpression(pattern: #"systemName:\s*"([a-z0-9.]+)""#)
        var verifiedSymbols: Set<String> = ["list.bullet"]
        for relPath in symbolCheckPaths {
            let src = try readSource(relPath)
            let nsRange = NSRange(src.startIndex..<src.endIndex, in: src)
            for match in regex.matches(in: src, range: nsRange) {
                if let r = Range(match.range(at: 1), in: src) {
                    verifiedSymbols.insert(String(src[r]))
                }
            }
        }
        for sym in verifiedSymbols.sorted() {
            #expect(
                NSImage(systemSymbolName: sym, accessibilityDescription: nil) != nil,
                "Nonexistent macOS SF Symbol: \(sym)"
            )
        }
    }

    // MARK: - 6. LiveCharkleEngine Milestone B + UI Engine End-to-End Integration

    @Test("LiveCharkleEngine Milestone B integrates with DocumentRadarFilterEngine, CompactIndexLayoutMetrics, and Scheme B 2-Way Synthesis")
    func liveEngineMilestoneBVersionStackAndTwoWaySynthesisIntegration() async throws {
        let dir = try BackendFixture.directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let engine = try BackendFixture.makeEngine(dir)

        let v1URL = dir.appendingPathComponent("年度技术服务协议_v1.md")
        let v2URL = dir.appendingPathComponent("年度技术服务协议_v2-法务改.md")
        try """
        # 年度技术服务协议

        一、项目范围与质量标准
        甲乙双方围绕核心业务系统的云原生架构升级、灾备演练及安全加固展开深度技术合作，确保全年可用性达标。

        二、合同总价与结算方式
        第一阶段服务总价为人民币 120 万元整，由甲方分三期向乙方指定账户支付。

        三、交付时限与验收节点
        乙方应于 2026年6月30日前 完成全部模块部署上线并通过联合验收。
        """.write(to: v1URL, atomically: true, encoding: .utf8)

        try """
        # 年度技术服务协议

        一、项目范围与质量标准
        甲乙双方围绕核心业务系统的云原生架构升级、灾备演练及安全加固展开深度技术合作，确保全年可用性达标。

        二、合同总价与结算方式
        第一阶段服务总价为人民币 138 万元整，由甲方分三期向乙方指定账户支付。

        三、交付时限与验收节点
        乙方应于 2026年6月15日前 完成全部模块部署上线并通过联合验收。
        """.write(to: v2URL, atomically: true, encoding: .utf8)

        let createdV1 = try await engine.ingest([.fileURL(v1URL)], targetFolderID: nil, targetBoardID: nil)
        let v1 = try #require(createdV1.first)

        // Active drop candidate detection before/after ingesting v2
        let candidate = try #require(await engine.detectVersionStackCandidate(for: v2URL, targetFolderID: nil))
        #expect(candidate.targetAssetID == v1.id)
        #expect(candidate.nextVersionNumber == 2)
        #expect(candidate.suggestedEditorName == "法务")

        let createdV2 = try await engine.ingest([.fileURL(v2URL)], targetFolderID: nil, targetBoardID: nil)
        let v2 = try #require(createdV2.first)
        let postIngestCandidate = try #require(await engine.detectVersionStackCandidate(forAssetID: v2.id))
        #expect(postIngestCandidate.targetAssetID == v1.id)

        let joined = try await engine.manageVersionStack(
            .join(
                assetID: v2.id,
                targetAssetOrGroupID: candidate.targetGroupID,
                editorName: "法务部",
                changeNote: "调整金额与交付周期",
                pinAsPrimary: false
            )
        )
        #expect(joined.count == 2)

        // Pin v1 as Primary Version, then verify resolvePrimaryAsset keeps v1 locked above v2!
        let afterPin = try await engine.manageVersionStack(.setPrimary(assetID: v1.id))
        #expect(AssetVersionStackMetadata.resolvePrimaryAsset(in: afterPin)?.id == v1.id)
        #expect(AssetVersionStackMetadata.newerThanPrimaryCount(in: afterPin) == 1)

        // Read structured document & run fine-grained diff feeding DocumentRadarFilterEngine + Minimap
        let structured = try await engine.readStructuredDocument(assetID: v2.id)
        #expect(!structured.blocks.isEmpty)

        let report = try await engine.compareDocumentVersions(
            baseAssetID: v1.id,
            targetAssetID: v2.id,
            sheetName: nil,
            primaryKeyCol: nil,
            useOCRIfScanned: false
        )
        #expect(report.summary.totalChangedBlocks >= 2)
        #expect(CompactIndexLayoutMetrics.normalizedMinimapTones(for: report.summary).count == 12)

        let moneyHunks = DocumentRadarFilterEngine.filterDiffHunks(report.hunks, radar: .numberOrCurrency, onlyChanged: true)
        let dateHunks = DocumentRadarFilterEngine.filterDiffHunks(report.hunks, radar: .dateOrDeadline, onlyChanged: true)
        #expect(!moneyHunks.isEmpty)
        #expect(!dateHunks.isEmpty)

        // Scheme B 2-Way Synthesis: keep v1's 120万 price while accepting v2's 15工作日 deadline -> v3
        var decisions: [DocumentMergeDecision] = []
        if let firstMoney = moneyHunks.first {
            decisions.append(DocumentMergeDecision(hunkID: firstMoney.id, choice: .keepBase))
        }
        let synthesizedV3 = try await engine.synthesizeDocumentVersion(
            baseAssetID: v1.id,
            targetAssetID: v2.id,
            preferTargetAsTemplate: true,
            decisions: decisions,
            editorName: "我",
            changeNote: "保留120万总价并采纳15工作日交付"
        )
        #expect(synthesizedV3.richMetadata?.versionStack?.versionNumber == 3)
        let v3Doc = try await engine.readStructuredDocument(assetID: synthesizedV3.id)
        #expect(v3Doc.plainText.contains("120"))
        #expect(v3Doc.plainText.contains("15"))
    }
}
