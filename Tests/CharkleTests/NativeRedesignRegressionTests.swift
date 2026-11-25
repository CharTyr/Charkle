import CharkleCanvas
import CharkleCore
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
}
