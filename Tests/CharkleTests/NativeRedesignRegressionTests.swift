import CharkleCanvas
import CharkleCore
import CoreGraphics
import Foundation
import Testing

@Suite("macOS Native UI Redesign Regression Tests")
struct NativeRedesignRegressionTests {

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

    @Test("Dual accent source defaults to studio cobalt, persists in UserDefaults, and flows from root environment")
    func dualAccentStrategyContracts() throws {
        let theme = try readSource("Sources/CharkleApp/DesignSystem/CharkleTheme.swift")
        #expect(theme.contains("enum CharkleAccentSource"))
        #expect(theme.contains("case studio"))
        #expect(theme.contains("case system"))
        #expect(theme.contains("工作室钴蓝"))
        #expect(theme.contains("跟随 macOS 系统"))
        #expect(theme.contains("@Entry public var charkleAccentSource: CharkleAccentSource = .studio"))
        #expect(theme.contains("studioAccentLightHex: String = \"#2A60E0\""))
        #expect(theme.contains("studioAccentDarkHex: String = \"#5B8DEF\""))
        #expect(theme.contains("hairlineWidth: CGFloat = 0.5"))

        let coordinator = try readSource("Sources/CharkleApp/Stores/AppCoordinatorStore.swift")
        #expect(coordinator.contains("static let accentSource = \"charkle.accentSource\""))
        #expect(coordinator.contains(".flatMap(CharkleAccentSource.init(rawValue:)) ?? .studio"))

        let appEntry = try readSource("Sources/CharkleApp/CharkleAppEntry.swift")
        #expect(appEntry.contains(".environment(\\.charkleAccentSource, accentSource)"))
        #expect(appEntry.contains(".tint(CharkleTheme.accent(for: colorScheme, source: accentSource))"))

        let generalPane = try readSource("Sources/CharkleApp/Views/Settings/GeneralSettingsPane.swift")
        #expect(generalPane.contains("title: \"强调色来源\""))
        #expect(generalPane.contains("coordinator.accentSource"))
    }

    @Test("Unified CharkleButtonStyle, CharkleFilterToken, and NSColorSampler eyedropper contracts hold")
    func designSystemPrimitivesContracts() throws {
        let controls = try readSource("Sources/CharkleApp/DesignSystem/CharkleControls.swift")
        #expect(controls.contains("enum CharkleButtonVariant"))
        #expect(controls.contains("case accent"))
        #expect(controls.contains("case standard"))
        #expect(controls.contains("case subtle"))
        #expect(controls.contains("case destructive"))
        #expect(controls.contains("enum CharkleButtonSize"))
        #expect(controls.contains("struct CharkleSegmentedControl"))
        #expect(controls.contains("struct CharkleInspectorSection"))
        #expect(controls.contains("struct CharkleSpecRow"))
        #expect(controls.contains("struct CharkleFilterToken"))
        #expect(controls.contains("case color(hex: String)"))
        #expect(controls.contains("case mediaKind(MediaKind)"))
        #expect(controls.contains("case minRating(Int)"))
        #expect(controls.contains("case tag(String)"))
        #expect(controls.contains("case orientation(AspectShape)"))
        #expect(controls.contains("case pinnedOffline"))
        #expect(controls.contains("struct CharkleTokenSearchField"))
        #expect(controls.contains("struct CharkleColorFilterPopover"))
        #expect(controls.contains("NSColorSampler()"))

        let motion = try readSource("Sources/CharkleApp/DesignSystem/CharkleMotion.swift")
        #expect(motion.contains("CharkleButtonStyle(mappedVariant, size: .md)"))
    }

    @Test("Top toolbar converges onto 3 Liquid Glass islands and retires the stacked 92pt visual filter strip")
    func topToolbarAndShellContracts() throws {
        let mainWindow = try readSource("Sources/CharkleApp/Views/MainWindowView.swift")
        #expect(mainWindow.contains("CharkleGlassContainer"))
        #expect(mainWindow.contains(".charkleScrollEdgeSoft(for: .top)"))
        #expect(mainWindow.contains("CharkleTokenSearchField("))
        #expect(mainWindow.contains("CharkleColorFilterPopover("))
        #expect(mainWindow.contains("CharkleSegmentedControl("))
        #expect(mainWindow.contains("FloatingSyncStatusPill("))
        #expect(!mainWindow.contains("floatingVisualFilterBar"))
        #expect(!mainWindow.contains("contextMaxWidth"))
        #expect(mainWindow.contains("ViewThatFits(in: .horizontal)"))
        #expect(mainWindow.contains("sideChromeWidth: sideChromeWidth"))
        #expect(mainWindow.contains("WindowKeyEventBridge"))
        #expect(mainWindow.contains(".intersection([.command, .option, .control, .shift])"))

        let sidebar = try readSource("Sources/CharkleApp/Views/SidebarView.swift")
        #expect(sidebar.contains(".symbolVariant("))
        #expect(sidebar.contains("CharkleFolderIcon("))
        #expect(sidebar.contains("CharkleHairlineDivider"))
    }

    @Test("Inspector is de-cardified onto hairline sections and Settings delegates buttons cleanly with zero bare DisclosureGroup")
    func inspectorAndSettingsContracts() throws {
        let inspector = try readSource("Sources/CharkleApp/Views/InspectorView.swift")
        #expect(inspector.contains("CharkleInspectorSection("))
        #expect(inspector.contains("CharkleSegmentedControl("))
        #expect(inspector.contains("CharkleSpecRow("))
        #expect(inspector.contains("CharkleDisclosureGroup("))
        #expect(inspector.contains(".frame(width: panelWidth)"))
        #expect(SidebarResizeGeometry.defaultInspectorWidth == 300)
        #expect(inspector.contains("resolvedImageMetadata(for:"))
        #expect(inspector.contains("moveInspectorSection("))
        #expect(!inspector.contains("inspectorCard("))
        #expect(!inspector.contains("inspectorSectionCard("))

        let settingsChrome = try readSource("Sources/CharkleApp/Views/Settings/SettingsChrome.swift")
        #expect(settingsChrome.contains("CharkleButtonStyle(.accent, size: .sm).makeBody(configuration: configuration)"))
        #expect(settingsChrome.contains("CharkleButtonStyle(.standard, size: .sm).makeBody(configuration: configuration)"))
        #expect(settingsChrome.contains("CharkleButtonStyle(.destructive, size: .sm).makeBody(configuration: configuration)"))

        let settingsOverlay = try readSource("Sources/CharkleApp/Views/Settings/SettingsOverlayView.swift")
        #expect(settingsOverlay.contains(".symbolVariant(active ? .fill : .none)"))
        #expect(settingsOverlay.contains(".environment(\\.charkleAccentSource, coordinator.accentSource)"))

        let uiFiles = [
            "Sources/CharkleApp/Views/MainWindowView.swift",
            "Sources/CharkleApp/Views/SidebarView.swift",
            "Sources/CharkleApp/Views/InspectorView.swift",
            "Sources/CharkleApp/Views/Settings/SettingsChrome.swift",
            "Sources/CharkleApp/Views/Settings/SettingsOverlayView.swift",
            "Sources/CharkleApp/Views/Settings/GeneralSettingsPane.swift",
            "Sources/CharkleApp/Views/Settings/LibrarySettingsPane.swift",
            "Sources/CharkleApp/Views/Settings/SyncSettingsPane.swift",
            "Sources/CharkleApp/Views/Settings/AISettingsPane.swift",
            "Sources/CharkleApp/Views/Settings/CaptureShortcutsSettingsPane.swift",
            "Sources/CharkleApp/Views/Settings/NotchShelfSettingsPane.swift",
            "Sources/CharkleApp/Views/Settings/ExtensionsSettingsPane.swift",
            "Sources/CharkleApp/Views/Settings/ExternalAgentsSettingsPane.swift",
            "Sources/CharkleApp/Views/Settings/AdvancedAboutSettingsPane.swift"
        ]

        let bareDisclosure = try NSRegularExpression(pattern: #"(?<!Charkle)\bDisclosureGroup\s*[\(\{]"#)
        for path in uiFiles {
            let src = try readSource(path)
            let range = NSRange(location: 0, length: (src as NSString).length)
            #expect(bareDisclosure.firstMatch(in: src, range: range) == nil, "Found bare DisclosureGroup in \(path)")
            #expect(!src.contains("CharkleSkeuoButtonStyle"), "Found retired CharkleSkeuoButtonStyle in \(path)")
        }
    }

    @Test("KeyboardShortcuts defaults, Textual rich viewers, and Quick Look connected geometry registry work safely")
    @MainActor
    func swiftPMComponentsAndConnectedQuickLook() throws {
        // Detached geometry registry safely returns nil when no gallery document view is mounted
        #expect(MasonryCardGeometryRegistry.shared.visibleCardRectInWindow(for: UUID()) == nil)

        let hotkeys = try readSource("Sources/CharkleApp/Services/GlobalHotkeyManager.swift")
        #expect(hotkeys.contains("static let captureArea = Self(\"charkle.captureArea\", default: .init(.a, modifiers: [.option, .shift]))"))
        #expect(hotkeys.contains("static let collectClipboard = Self(\"charkle.collectClipboard\", default: .init(.v, modifiers: [.option, .shift]))"))
        #expect(hotkeys.contains("static let toggleNotchShelf = Self(\"charkle.toggleNotchShelf\", default: .init(.s, modifiers: [.option, .shift]))"))
        #expect(hotkeys.contains("KeyboardShortcuts.onKeyDown(for:"))
        #expect(!hotkeys.contains("KeyboardShortcuts.isEnabled"))

        let capturePane = try readSource("Sources/CharkleApp/Views/Settings/CaptureShortcutsSettingsPane.swift")
        #expect(capturePane.contains("KeyboardShortcuts.Recorder(for:"))
        #expect(capturePane.contains("恢复默认快捷键"))

        let richViewers = try readSource("Sources/CharkleApp/Views/QuickLookRichViewers.swift")
        #expect(richViewers.contains("import Textual"))
        #expect(richViewers.contains("StructuredText(markdown:"))
        #expect(richViewers.contains("InlineText(markdown:"))
        #expect(richViewers.contains(".textual.textSelection(.enabled)"))

        let quickLook = try readSource("Sources/CharkleApp/Views/QuickLookOverlayView.swift")
        #expect(quickLook.contains("MasonryCardGeometryRegistry.shared.visibleCardRectInWindow(for:"))
        #expect(quickLook.contains("CharkleMotion.gestureSpring"))
        #expect(quickLook.contains("CharkleMotion.exitSm"))
        #expect(quickLook.contains(".ignoresSafeArea(.container, edges: .top)"))
        #expect(quickLook.contains(".padding(.leading, 88)"))
        #expect(quickLook.contains(".menuIndicator(.hidden)"))
        #expect(!quickLook.contains("rectangle.3.group.badge.plus"))
    }

    @Test("Zero-flicker canvas invariants and zero-violet color discipline remain intact across redesigned UI files")
    func zeroFlickerAndZeroVioletInvariants() throws {
        let ring = try readSource("Sources/CharkleCanvas/RingGalleryMetalView.swift")
        #expect(ring.contains("presentsWithTransaction"))

        let masonry = try readSource("Sources/CharkleCanvas/VirtualizedMasonryView.swift")
        #expect(masonry.contains("class MasonryClipView"))
        #expect(masonry.contains("paneTransitionTargetWidth"))
        #expect(masonry.contains("isLivePaneResizing"))

        let mainWindow = try readSource("Sources/CharkleApp/Views/MainWindowView.swift")
        #expect(mainWindow.contains("PaneResizeHandleView"))
        #expect(mainWindow.contains("inspectorResizeDivider"))
        #expect(mainWindow.contains("isLivePaneResizing: isDraggingSidebarDivider || isDraggingInspectorDivider"))

        let quickLookView = try readSource("Sources/CharkleApp/Views/QuickLookOverlayView.swift")
        #expect(quickLookView.contains("quickLookInspectorResizeDivider"))
        #expect(quickLookView.contains("panelWidth: effectiveInspectorWidth"))

        let colorFiles = [
            "Sources/CharkleApp/DesignSystem/CharkleTheme.swift",
            "Sources/CharkleApp/DesignSystem/CharkleControls.swift",
            "Sources/CharkleApp/Views/MainWindowView.swift",
            "Sources/CharkleApp/Views/SidebarView.swift",
            "Sources/CharkleApp/Views/InspectorView.swift",
            "Sources/CharkleApp/Views/QuickLookOverlayView.swift",
            "Sources/CharkleApp/Views/QuickLookRichViewers.swift",
            "Sources/CharkleApp/Views/Settings/SettingsChrome.swift",
            "Sources/CharkleApp/Views/Settings/SettingsOverlayView.swift",
            "Sources/CharkleApp/Views/Settings/GeneralSettingsPane.swift"
        ]
        let forbiddenColorAPI = try NSRegularExpression(pattern: #"\.(purple|indigo|violet)\b"#)
        for path in colorFiles {
            let src = try readSource(path)
            let range = NSRange(location: 0, length: (src as NSString).length)
            #expect(forbiddenColorAPI.firstMatch(in: src, range: range) == nil, "Found forbidden violet/purple/indigo color in \(path)")
        }
    }

    @Test("Draggable sidebar and inspector widths clamp safely across narrow/wide windows and preserve center workspace headroom")
    func resizableSidebarWidthClampingAndPersistence() {
        #expect(SidebarResizeGeometry.clampedWidth(120) == SidebarResizeGeometry.minWidth)
        #expect(SidebarResizeGeometry.clampedWidth(285.4) == 285)
        #expect(SidebarResizeGeometry.clampedWidth(900) == SidebarResizeGeometry.maxWidth)
        #expect(SidebarResizeGeometry.clampedWidth(.nan) == SidebarResizeGeometry.defaultWidth)

        // Narrow window with Inspector open (300pt + 1pt divider) preserves >= 360pt center workspace
        let narrowWithInspector = SidebarResizeGeometry.clampedWidth(
            380,
            windowWidth: 900,
            isInspectorVisible: true
        )
        #expect(narrowWithInspector == 238)

        // Custom wider Inspector (380pt) further tightens sidebar ceiling on moderate window widths
        let withWideInspector = SidebarResizeGeometry.clampedWidth(
            380,
            windowWidth: 1000,
            isInspectorVisible: true,
            inspectorWidth: 380
        )
        #expect(withWideInspector == 258)

        // Wide window allows full 420pt expansion
        let wide = SidebarResizeGeometry.clampedWidth(
            420,
            windowWidth: 1600,
            isInspectorVisible: true
        )
        #expect(wide == SidebarResizeGeometry.maxWidth)

        // Very tight window still honors minWidth floor
        let veryNarrow = SidebarResizeGeometry.clampedWidth(
            300,
            windowWidth: 700,
            isInspectorVisible: true
        )
        #expect(veryNarrow == SidebarResizeGeometry.minWidth)

        // Right Inspector clamping (260...480pt, default 300pt)
        #expect(SidebarResizeGeometry.clampedInspectorWidth(180) == SidebarResizeGeometry.minInspectorWidth)
        #expect(SidebarResizeGeometry.clampedInspectorWidth(342.6) == 343)
        #expect(SidebarResizeGeometry.clampedInspectorWidth(720) == SidebarResizeGeometry.maxInspectorWidth)
        #expect(SidebarResizeGeometry.clampedInspectorWidth(.nan) == SidebarResizeGeometry.defaultInspectorWidth)
        #expect(SidebarResizeGeometry.clampedInspectorWidth(480, windowWidth: 1000, sidebarOccupiedWidth: 233) == 406)
        #expect(SidebarResizeGeometry.clampedInspectorWidth(480, windowWidth: 1440, sidebarOccupiedWidth: 0) == SidebarResizeGeometry.maxInspectorWidth)
    }

    @Test("Unified search fuses semantic search seamlessly without separate toggle buttons or mode-exit banners on macOS and iOS")
    func unifiedSearchZeroToggleContracts() throws {
        let a = AssetRecord(title: "Literal A", fileName: "a.jpg")
        let b = AssetRecord(title: "Literal B", fileName: "b.jpg")
        let c = AssetRecord(title: "Semantic C", fileName: "c.jpg")
        let d = AssetRecord(title: "Semantic D", fileName: "d.jpg")

        // Local-only semantic fusion keeps literal order stable at top and appends unseen semantic hits
        let localReport = SemanticSearchReport(
            query: "赛博",
            hits: [
                SemanticSearchHit(asset: c, score: 0.85),
                SemanticSearchHit(asset: b, score: 0.80),
                SemanticSearchHit(asset: d, score: 0.72)
            ],
            usedTypeSafeJev: false,
            usedCloudEmbedding: false
        )
        #expect(localReport.mergedAssets(withLiteral: [a, b]).map(\.id) == [a.id, b.id, c.id, d.id])

        // Cloud visual / embedding reranking prioritizes semantic relevance while preserving all literal matches
        let visualReport = SemanticSearchReport(
            query: "雨夜霓虹街道",
            hits: [
                SemanticSearchHit(asset: c, score: 0.94),
                SemanticSearchHit(asset: d, score: 0.88)
            ],
            usedTypeSafeJev: true,
            usedCloudEmbedding: false
        )
        #expect(visualReport.mergedAssets(withLiteral: [a, b]).map(\.id) == [c.id, d.id, a.id, b.id])

        // Pure visual mood query (no literal FTS matches) still surfaces semantic hits
        #expect(localReport.mergedAssets(withLiteral: []).map(\.id) == [c.id, b.id, d.id])

        // Empty semantic hits preserve literal FTS matches untouched
        let emptyReport = SemanticSearchReport(query: "IMG_0421", hits: [])
        #expect(emptyReport.mergedAssets(withLiteral: [a, b]).map(\.id) == [a.id, b.id])

        // UI source contracts: zero standalone "语义" mode toggle buttons and zero "返回普通检索" banners
        let macControls = try readSource("Sources/CharkleApp/DesignSystem/CharkleControls.swift")
        let macMain = try readSource("Sources/CharkleApp/Views/MainWindowView.swift")
        let macStore = try readSource("Sources/CharkleApp/Stores/LibraryStore.swift")
        let iosFilterBar = try readSource("ios/CharkleMobile/Views/FilterBarView.swift")
        let iosMasonry = try readSource("ios/CharkleMobile/Views/MasonryGalleryView.swift")
        let iosStore = try readSource("ios/CharkleMobile/Stores/MobileAppStore.swift")

        for src in [macControls, macMain, iosFilterBar, iosMasonry] {
            #expect(!src.contains("Text(\"语义\")"))
            #expect(!src.contains("返回普通检索"))
            #expect(!src.contains("semanticSearchEnabled"))
        }
        #expect(!macStore.contains("semanticSearchEnabled"))
        #expect(!iosStore.contains("semanticSearchEnabled"))
        #expect(!iosStore.contains("toggleSemanticSearchMode"))
        #expect(!iosFilterBar.contains("MobileSemanticSearchStatusBar"))
        #expect(macControls.contains("isRefiningSearch"))
        #expect(macStore.contains("SemanticSearchReport.mergeUnifiedAssets"))
        #expect(iosStore.contains("SemanticSearchReport.mergeUnifiedAssets"))
    }

    @Test("macOS drag NSItemProvider never registers fileRepresentation for public.file-url (prevents macOS 27 SIGTRAP)")
    func macOSDragItemProviderSafetyContracts() throws {
        let notch = try readSource("Sources/CharkleApp/Notch/NotchShelfView.swift")
        let filmstrip = try readSource("Sources/CharkleApp/Views/GalleryFilmstripView.swift")
        for src in [notch, filmstrip] {
            #expect(!src.contains("registerFileRepresentation(forTypeIdentifier: UTType.fileURL"))
            #expect(src.contains("registerDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier"))
            #expect(src.contains("fileExists(atPath:"))
        }
    }

    @Test("YouTube & Bilibili URL parsing, WBI signature, chapters, and universal webpage parser contracts")
    func videoPlatformAndUniversalWebParserContracts() throws {
        // 1. YouTube URL variants
        let ytWatch = try #require(URL(string: "https://www.youtube.com/watch?v=dQw4w9WgXcQ&t=42s"))
        let ytShort = try #require(URL(string: "https://youtu.be/dQw4w9WgXcQ"))
        let ytShorts = try #require(URL(string: "https://www.youtube.com/shorts/dQw4w9WgXcQ"))
        for url in [ytWatch, ytShort, ytShorts] {
            let parsed = try #require(SocialPostURLParser.parse(url))
            #expect(parsed.platform == .youtube)
            #expect(parsed.dedupKey == "yt:dQw4w9WgXcQ")
            #expect(parsed.canonicalURL.absoluteString == "https://www.youtube.com/watch?v=dQw4w9WgXcQ")
        }

        // 2. Bilibili URL variants (BV, av, multi-page, b23.tv short link)
        let biliBV = try #require(URL(string: "https://www.bilibili.com/video/BV1xx411c7m9/?spm_id_from=333.999"))
        let parsedBV = try #require(SocialPostURLParser.parse(biliBV))
        #expect(parsedBV.platform == .bilibili)
        #expect(parsedBV.dedupKey == "bili:BV1xx411c7m9")
        #expect(parsedBV.canonicalURL.absoluteString == "https://www.bilibili.com/video/BV1xx411c7m9")

        let biliShort = try #require(URL(string: "https://b23.tv/AbCdEf1"))
        let parsedShort = try #require(SocialPostURLParser.parse(biliShort))
        #expect(parsedShort.platform == .bilibili)

        // 3. Bilibili WBI MD5 signature generation produces deterministic 32-hex w_rid + wts
        let signed = VideoPlatformResolver.signBilibiliWBI(
            params: ["bvid": "BV1xx411c7m9", "cid": "123456"],
            imgKey: "7cd084941338484aae1ad9425b84077c",
            subKey: "4932caff0ff746eab6f01bf08b70ac45",
            timestamp: 1_700_000_000
        )
        let wRid = try #require(signed.first(where: { $0.name == "w_rid" })?.value)
        let isValidWRid = wRid.count == 32 && wRid.allSatisfy(\.isHexDigit)
        #expect(isValidWRid)
        #expect(signed.first(where: { $0.name == "wts" })?.value == "1700000000")

        // 4. Timestamp chapter parsing
        let chapters = VideoPlatformResolver.extractTimestampChapters(from: """
        Intro notes
        00:00 开场与思路
        02:35 灯光与材质拆解
        10:12 最终调色对比
        """)
        #expect(chapters.count == 3)

        // 5. Universal WebBookmark HTML parser: JSON-LD VideoObject, oEmbed, lazy hero img, readable lead summary
        let sampleHTML = """
        <!doctype html>
        <html>
        <head>
          <title>Studio Lighting Breakdown</title>
          <link rel="alternate" type="application/json+oembed" href="https://vimeo.com/api/oembed.json?url=https%3A%2F%2Fvimeo.com%2F123" />
          <script type="application/ld+json">
          {
            "@type": "VideoObject",
            "name": "Cinematic Studio Lighting",
            "author": { "name": "Light Craft" },
            "duration": "PT8M42S",
            "thumbnailUrl": "https://cdn.example.com/poster.jpg",
            "contentUrl": "https://cdn.example.com/reel.mp4"
          }
          </script>
        </head>
        <body>
          <article>
            <p>This comprehensive breakdown walks through key light ratios, softbox diffusion, and color temperature contrast for editorial portraits.</p>
            <img data-original="https://cdn.example.com/hero-frame.jpg" width="1200" height="800" />
            <img src="https://cdn.example.com/favicon-16.png" width="16" height="16" />
          </article>
        </body>
        </html>
        """
        let baseURL = try #require(URL(string: "https://studio.example.com/posts/lighting"))
        let parsedHTML = WebBookmark.parseHTML(sampleHTML, baseURL: baseURL)
        #expect(parsedHTML.title == "Cinematic Studio Lighting")
        #expect(parsedHTML.authorName == "Light Craft")
        #expect(parsedHTML.isVideoPage == true)
        #expect(parsedHTML.durationSeconds == 522)
        #expect(parsedHTML.oEmbedURL?.absoluteString.contains("oembed.json") == true)
        #expect(parsedHTML.videoURLs.contains(where: { $0.absoluteString == "https://cdn.example.com/reel.mp4" }))
        #expect(parsedHTML.imageURLs.contains(where: { $0.absoluteString == "https://cdn.example.com/poster.jpg" }))
        #expect(parsedHTML.imageURLs.contains(where: { $0.absoluteString == "https://cdn.example.com/hero-frame.jpg" }))
        #expect(!parsedHTML.imageURLs.contains(where: { $0.absoluteString.contains("favicon-16") }))
        #expect(parsedHTML.description?.contains("key light ratios") == true)

        // 6. iOS unified Settings, Scheme A Liquid Glass bottom bar, collapsible Directory, and batch link extraction wiring
        let iosSettings = try readSource("ios/CharkleMobile/Views/MobileSettingsView.swift")
        let iosTabBar = try readSource("ios/CharkleMobile/Views/LiquidGlassMorphingTabBar.swift")
        let iosSidebar = try readSource("ios/CharkleMobile/Views/SidebarNavigationView.swift")
        let iosRoot = try readSource("ios/CharkleMobile/Views/RootShellView.swift")
        let macMain = try readSource("Sources/CharkleApp/Views/MainWindowView.swift")
        let iosGallery = try readSource("ios/CharkleMobile/Views/MasonryGalleryView.swift")

        #expect(iosSettings.contains("GoogleDriveSyncSettingsView"))
        #expect(!iosSettings.contains(".pur"))
        #expect(iosTabBar.contains("MobileSearchScopeMode"))
        #expect(iosTabBar.contains("glassEffectID"))
        #expect(iosSidebar.contains("expandedFolderIDs"))
        #expect(iosSidebar.contains("quickFilterHeader"))
        #expect(iosRoot.contains("LiquidGlassMorphingTabBar"))
        #expect(macMain.contains("extractMediaFromSelectedLinks"))
        #expect(iosGallery.contains("extractMediaFromSelectedLinks"))
    }

    @Test("iOS preview uses native UIScrollView zoom coordination and hierarchical folder pickers")
    func iOSPreviewZoomAndHierarchicalFolderPickerContracts() throws {
        let iosDetail = try readSource("ios/CharkleMobile/Views/AssetDetailView.swift")
        let iosGallery = try readSource("ios/CharkleMobile/Views/MasonryGalleryView.swift")
        let iosInbox = try readSource("ios/CharkleMobile/Views/InboxTriageView.swift")
        let iosCapture = try readSource("ios/CharkleMobile/Views/CaptureSheetView.swift")
        let iosPinterest = try readSource("ios/CharkleMobile/Views/PinterestExploreMobileView.swift")
        let iosFolderPicker = try readSource("ios/CharkleMobile/Views/HierarchicalFolderPicker.swift")

        // Preview zoom must use native UIScrollView + modal zoom-transition dismiss coordination
        // so pinching out after zooming in shrinks the photo instead of dismissing fullScreenCover.
        #expect(iosDetail.contains("ZoomablePhotoScrollView"))
        #expect(iosDetail.contains("ZoomDismissCoordinatorBridge"))
        #expect(iosDetail.contains("attachPinchPriorityToModalTransitionIfNeeded"))
        #expect(iosDetail.contains("interactiveDismissDisabled(isCurrentAssetZoomed)"))
        #expect(!iosDetail.contains("MagnificationGesture()"))

        // Move-to-folder sheets and menus must preserve collapsible/cascading folder hierarchy
        // instead of dumping all nested folders flat.
        #expect(iosFolderPicker.contains("struct HierarchicalFolderPickerSheet"))
        #expect(iosFolderPicker.contains("struct HierarchicalFolderMenuContent"))
        #expect(iosFolderPicker.contains("expandedFolderIDs"))
        #expect(iosFolderPicker.contains("ancestorPathIDs"))
        #expect(iosGallery.contains("HierarchicalFolderPickerSheet"))
        #expect(iosGallery.contains("HierarchicalFolderMenuContent"))
        #expect(!iosGallery.contains("ForEach(store.flattenedFolders)"))
        #expect(!iosDetail.contains("ForEach(store.flattenedFolders)"))
        #expect(!iosInbox.contains("ForEach(store.flattenedFolders)"))
        #expect(!iosCapture.contains("ForEach(store.flattenedFolders)"))
        #expect(!iosPinterest.contains("ForEach(store.flattenedFolders)"))
    }

    @Test("Video-site bookmarks resolve zero-download streaming playback plans and embed HTML cleanly on macOS & iOS")
    func videoBookmarkInlineStreamingContracts() throws {
        // 1. YouTube embed player includes valid origin + strict-origin-when-cross-origin Referer (avoids Error 153)
        let ytURL = try #require(URL(string: "https://www.youtube.com/watch?v=dQw4w9WgXcQ"))
        let ytEmbed = try #require(VideoPlatformResolver.embedPlayer(for: ytURL))
        #expect(ytEmbed.url.absoluteString.contains("youtube.com/embed/dQw4w9WgXcQ"))
        #expect(ytEmbed.url.absoluteString.contains("origin=https://charkle.app"))
        let ytRendered = VideoPlatformResolver.embedHTML(for: ytEmbed)
        #expect(ytRendered.baseURL.scheme == "https")
        #expect(ytRendered.html.contains("strict-origin-when-cross-origin"))
        #expect(ytRendered.html.contains("<iframe"))

        // 2. Bilibili embed player preserves bvid, cid, and page with bilibili.com Referer
        let biliURL = try #require(URL(string: "https://www.bilibili.com/video/BV1xx411c7mD?p=2"))
        let biliEmbed = try #require(VideoPlatformResolver.embedPlayer(for: biliURL, cidOverride: 987654))
        #expect(biliEmbed.url.absoluteString.contains("player.bilibili.com/player.html"))
        #expect(biliEmbed.url.absoluteString.contains("bvid=BV1xx411c7mD"))
        #expect(biliEmbed.url.absoluteString.contains("cid=987654"))
        #expect(biliEmbed.url.absoluteString.contains("page=2"))
        #expect(biliEmbed.referer.contains("bilibili.com"))

        // 3. Generic video platforms (Vimeo, Dailymotion) and direct stream URL classifier
        let vimeoURL = try #require(URL(string: "https://vimeo.com/123456789"))
        let vimeoEmbed = try #require(VideoPlatformResolver.embedPlayer(for: vimeoURL))
        #expect(vimeoEmbed.url.absoluteString.contains("player.vimeo.com/video/123456789"))

        let dmURL = try #require(URL(string: "https://www.dailymotion.com/video/x8abcde"))
        let dmEmbed = try #require(VideoPlatformResolver.embedPlayer(for: dmURL))
        #expect(dmEmbed.url.absoluteString.contains("geo.dailymotion.com/player.html?video=x8abcde"))

        #expect(VideoPlatformResolver.looksLikeDirectVideoStreamURL(try #require(URL(string: "https://cdn.example.com/reel.mp4"))))
        #expect(VideoPlatformResolver.looksLikeDirectVideoStreamURL(try #require(URL(string: "https://cdn.example.com/master.m3u8?token=1"))))
        #expect(!VideoPlatformResolver.looksLikeDirectVideoStreamURL(ytURL))

        // 4. Both macOS Quick Look and iOS AssetDetailView wire zero-download streaming players with AVURLAsset headers + WKWebView fallback
        let macRich = try readSource("Sources/CharkleApp/Views/QuickLookRichViewers.swift")
        let macQL = try readSource("Sources/CharkleApp/Views/QuickLookOverlayView.swift")
        let iosDetail = try readSource("ios/CharkleMobile/Views/AssetDetailView.swift")

        #expect(macRich.contains("struct QuickLookStreamingVideoView"))
        #expect(macRich.contains("AVURLAssetHTTPHeaderFieldsKey"))
        #expect(macRich.contains("EmbedStreamWebPlayerViewMac"))
        #expect(macRich.contains("resolvePlaybackPlan(for: post)"))
        #expect(macQL.contains("QuickLookStreamingVideoView"))
        #expect(macQL.contains("resolveWebPagePlaybackPlan"))

        #expect(iosDetail.contains("MobileStreamingVideoPlayerView"))
        #expect(iosDetail.contains("AVURLAssetHTTPHeaderFieldsKey"))
        #expect(iosDetail.contains("MobileEmbedStreamWebView"))
        #expect(iosDetail.contains("resolvePlaybackPlan(for: post)"))
        #expect(iosDetail.contains("resolveWebPagePlaybackPlan"))
    }

    @Test("Picking a video frame updates asset cover thumbnails, dominant colors, and dual-platform UI hooks")
    func videoFrameCoverSelectionContracts() async throws {
        // 1. LiveCharkleEngine end-to-end cover replacement updates grid520/preview1400 and dominantColors
        let tempDir = FileManager.default.temporaryDirectory
            .appending(path: "charkle-cover-frame-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let engine = try LiveCharkleEngine.make(appSupportDirectory: tempDir)
        let imported = try await engine.ingest(
            [.colorSwatch(hex: "#1A4FD6", title: "ClipCoverSeed")],
            targetFolderID: nil,
            targetBoardID: nil
        )
        let asset = try #require(imported.first)

        // Replace cover with a crisp 160x90 solid crimson frame (simulating captured video frame)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let ctx = try #require(CGContext(
            data: nil,
            width: 160,
            height: 90,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        ctx.setFillColor(red: 0.90, green: 0.18, blue: 0.18, alpha: 1.0)
        ctx.fill(CGRect(x: 0, y: 0, width: 160, height: 90))
        let crimsonFrame = try #require(ctx.makeImage())
        let crimsonJPEG = try #require(VideoFrameCapture.encodeJPEG(crimsonFrame))
        let updated = try await engine.updateAssetCoverImage(id: asset.id, imageData: crimsonJPEG)

        #expect(updated.id == asset.id)
        let topHex = updated.dominantColors.first?.hex.uppercased() ?? ""
        #expect(topHex.hasPrefix("#E") || topHex.hasPrefix("#D") || topHex.hasPrefix("#F"))
        let gridURL = await engine.thumbnailURL(for: asset.id, tier: .grid520)
        #expect(gridURL != nil)
        #expect(VideoFrameCapture.formattedTimestamp(84) == "01:24")
        #expect(VideoFrameCapture.formattedTimestamp(3725) == "1:02:05")

        // 2. Dual-platform UI capture bridges & immediate filmstrip/gallery invalidation wiring
        let macRich = try readSource("Sources/CharkleApp/Views/QuickLookRichViewers.swift")
        let macQL = try readSource("Sources/CharkleApp/Views/QuickLookOverlayView.swift")
        let macStore = try readSource("Sources/CharkleApp/Stores/LibraryStore.swift")
        let iosDetail = try readSource("ios/CharkleMobile/Views/AssetDetailView.swift")
        let iosStore = try readSource("ios/CharkleMobile/Stores/MobileAppStore.swift")

        #expect(macStore.contains("func updateAssetCoverImage"))
        #expect(macRich.contains("StreamingFrameCaptureBridge"))
        #expect(macRich.contains("takeSnapshot(configuration:"))
        #expect(macQL.contains("applyCapturedCoverFrame"))
        #expect(macQL.contains("设当前帧为封面"))

        #expect(iosStore.contains("func updateAssetCoverImage"))
        #expect(iosDetail.contains("MobileVideoFrameCaptureBridge"))
        #expect(iosDetail.contains("MobileLocalVideoStageView"))
        #expect(iosDetail.contains("takeSnapshot(configuration:"))
        #expect(iosDetail.contains("thumbnails.revision"))
    }

    @Test("iOS scroll views dismiss keyboard across sibling search overlays and gallery uses continuous Photos-style pinch zoom")
    func iosKeyboardDismissAndContinuousGalleryPinchContracts() throws {
        let iosTheme = try readSource("ios/CharkleMobile/DesignSystem/MobileTheme.swift")
        let iosTabBar = try readSource("ios/CharkleMobile/Views/LiquidGlassMorphingTabBar.swift")
        let iosFilter = try readSource("ios/CharkleMobile/Views/FilterBarView.swift")
        let iosSidebar = try readSource("ios/CharkleMobile/Views/SidebarNavigationView.swift")
        let iosFolderPicker = try readSource("ios/CharkleMobile/Views/HierarchicalFolderPicker.swift")
        let iosCapture = try readSource("ios/CharkleMobile/Views/CaptureSheetView.swift")
        let iosGallery = try readSource("ios/CharkleMobile/Views/MasonryGalleryView.swift")
        let iosPinterest = try readSource("ios/CharkleMobile/Views/PinterestExploreMobileView.swift")

        // 1. Global sibling-safe keyboard dismissal on ScrollPhase.interacting + auto-focus race guard
        #expect(iosTheme.contains("enum MobileKeyboard"))
        #expect(iosTheme.contains("UIResponder.resignFirstResponder"))
        #expect(iosTheme.contains(".scrollDismissesKeyboard(.immediately)"))
        #expect(iosTheme.contains(".onScrollPhaseChange"))
        #expect(iosTheme.contains("func charkleDismissKeyboardOnScroll()"))
        #expect(iosTabBar.contains("MobileKeyboard.dismissSequence"))
        #expect(iosFilter.contains(".charkleDismissKeyboardOnScroll()"))
        #expect(iosSidebar.contains(".charkleDismissKeyboardOnScroll()"))
        #expect(iosFolderPicker.contains(".charkleDismissKeyboardOnScroll()"))
        #expect(iosCapture.contains(".charkleDismissKeyboardOnScroll()"))
        #expect(iosGallery.contains(".charkleDismissKeyboardOnScroll()"))
        #expect(iosPinterest.contains("MobileKeyboard.dismiss()"))

        // 2. Continuous 120Hz Photos-style pinch zoom with O(1) snapshot cache & native UIScrollView bridge
        //    (never applying viewport-normalized .scaleEffect to the entire multi-thousand-point ZStack)
        #expect(iosGallery.contains("class MasonryLayoutCache"))
        #expect(iosGallery.contains("class MasonryPinchZoomController"))
        #expect(iosGallery.contains("struct GalleryScrollPinchBridge"))
        #expect(iosGallery.contains("UIPinchGestureRecognizer"))
        #expect(iosGallery.contains("CADisplayLink"))
        #expect(iosGallery.contains("geo.visibleRect.minY"))
        #expect(iosGallery.contains("log2(Double(safeScale))"))
        #expect(iosGallery.contains("shouldRequireFailureOf"))
        #expect(iosGallery.contains("struct GalleryViewportBucket"))
        #expect(!iosGallery.contains(".scaleEffect(livePinchRubberScale"))
        #expect(!iosFilter.contains(".scaleEffect(livePinchRubberScale"))

        // 3. 120Hz iOS gallery scroll & preview horizontal swipe performance contracts
        let iosThumbCache = try readSource("ios/CharkleMobile/Stores/MobileThumbnailCache.swift")
        let iosDetail = try readSource("ios/CharkleMobile/Views/AssetDetailView.swift")
        let iosRoot = try readSource("ios/CharkleMobile/Views/RootShellView.swift")

        #expect(iosThumbCache.contains("actor ThumbnailDecodeGate"))
        #expect(iosThumbCache.contains("preparingForDisplay()"))
        #expect(iosThumbCache.contains("func prefetch("))
        #expect(iosThumbCache.contains("originalCache"))
        #expect(iosDetail.contains("LazyHStack(spacing: 0)"))
        #expect(iosDetail.contains(".scrollTargetBehavior(.paging)"))
        #expect(iosDetail.contains("prefetchAdjacentPreviews"))
        #expect(iosDetail.contains("bestCachedPreviewImage"))
        #expect(iosDetail.contains("func syncPanEnabledForCurrentZoom"))
        #expect(iosRoot.contains("struct DetailPresentation"))
        #expect(iosRoot.contains("struct DetailCoverTransitionHost"))
    }
}
