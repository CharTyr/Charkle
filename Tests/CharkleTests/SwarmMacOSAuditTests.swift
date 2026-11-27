import AppKit
import CharkleCanvas
import CharkleCore
import Foundation
import Testing

@Suite("Swarm macOS App Audit Regression Suite")
struct SwarmMacOSAuditTests {

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

    // MARK: - 1. Cross-Layer Contracts & Keyboard / Overlay Isolation

    @Test("MainWindowView wires VirtualizedMasonryView overlay suspension, Spacebar/Esc stacking, and Inbox 1-9 triage")
    func mainWindowOverlayAndKeyboardContracts() throws {
        let mainWindow = try readSource("Sources/CharkleApp/Views/MainWindowView.swift")
        let entry = try readSource("Sources/CharkleApp/CharkleAppEntry.swift")
        let coord = try readSource("Sources/CharkleApp/Stores/AppCoordinatorStore.swift")

        // Locked cross-layer contract: Masonry receives isOverlayPresented immediately after activeQuickLookID
        #expect(mainWindow.contains("isOverlayPresented: coordinator.isModalOverlayPresented || showInboxBatchTriageSheet"))
        #expect(mainWindow.contains("isActive: showRightInspector && coordinator.quickLookAssetID == nil"))

        // Spacebar Quick Look dismisses via animated token & respects Smart Deduplication + Filmstrip/Ring focus
        #expect(coord.contains("public private(set) var quickLookDismissRequestToken: UInt64 = 0"))
        #expect(coord.contains("public func requestQuickLookDismiss()"))
        #expect(coord.contains("@ObservationIgnored public var focusedStageAssetID: UUID? = nil"))
        #expect(coord.contains("public var isPinterestDetailImageExpanded: Bool = false"))
        #expect(mainWindow.contains("coordinator.requestQuickLookDismiss()"))
        #expect(mainWindow.contains("!coordinator.isSmartDeduplicationPresented"))
        #expect(mainWindow.contains("coordinator.focusedStageAssetID"))

        // Esc stack covers Smart Deduplication and Pinterest expanded image before Pin detail
        #expect(mainWindow.contains("if coordinator.isSmartDeduplicationPresented"))
        #expect(mainWindow.contains("if coordinator.isPinterestDetailImageExpanded"))

        // Inbox 1-9 quick triage handled at window monitor level via shared helper
        #expect(mainWindow.contains("triggerInboxQuickTriage(digit:"))

        // Sidebar width clamp treats Inspector as hidden on .pinterest, and drag-back re-collapses cleanly
        #expect(mainWindow.contains("let inspectorVisibleForClamp = coordinator.isInspectorVisible && coordinator.selectedDestination != .pinterest"))
        #expect(mainWindow.contains("if !coordinator.isSidebarCollapsed {\n                                coordinator.isSidebarCollapsed = true"))

        // CharkleAppEntry avoids duplicate hardcoded global shortcuts & aligns folder capture fallback
        #expect(!entry.contains(".keyboardShortcut(\"a\", modifiers: [.option, .shift])"))
        #expect(!entry.contains(".keyboardShortcut(\"v\", modifiers: [.option, .shift])"))
        #expect(!entry.contains(".keyboardShortcut(\"s\", modifiers: [.option, .shift])"))
        #expect(entry.contains("library.folderHierarchyRoots.first?.folder.id"))
    }

    // MARK: - 2. Quick Look, Filmstrip & Ring Race / Teardown Safety

    @Test("Quick Look streaming capture uses owner-token bridge, animated Esc/Space dismiss, and playback suspension")
    func quickLookAndStageContracts() throws {
        let ql = try readSource("Sources/CharkleApp/Views/QuickLookOverlayView.swift")
        let rich = try readSource("Sources/CharkleApp/Views/QuickLookRichViewers.swift")
        let filmstrip = try readSource("Sources/CharkleApp/Views/GalleryFilmstripView.swift")
        let ring = try readSource("Sources/CharkleApp/Views/GalleryRingView.swift")

        // StreamingFrameCaptureBridge owner-token registration prevents dismantleNSView races
        #expect(rich.contains("func register(ownerID: UUID, handler:"))
        #expect(rich.contains("func unregister(ownerID: UUID)"))
        #expect(rich.contains("func captureCurrentFrame()"))
        #expect(rich.contains("guard self.ownerID == ownerID else { return }"))

        // QuickLookOverlayView honors dismiss token, guards cover capture asset identity, wires failure callback
        #expect(ql.contains(".onChange(of: coordinator.quickLookDismissRequestToken)"))
        #expect(ql.contains("coordinator.quickLookAssetID == targetAssetID,"))
        #expect(ql.contains("asset.id == targetAssetID,"))
        #expect(ql.contains("onCaptureCoverFailed:"))

        // Embed web player defers load while suspended & pauses media on suspend/dismantle; RemoteCachedImageView guards URL
        #expect(rich.contains("pauseAllMediaPlayback"))
        #expect(rich.contains("closeAllMediaPresentations"))
        #expect(rich.contains("@State private var loadedURL: URL?"))
        #expect(rich.contains("fallbackCoverImage: NSImage? = nil"))

        // Filmstrip prevents 1-frame stale image flash & supports streaming video bookmark parity
        #expect(filmstrip.contains("@State private var previewImageAssetID: UUID?"))
        #expect(filmstrip.contains("QuickLookStreamingVideoView("))
        #expect(filmstrip.contains("onFocusedAssetChanged"))
        #expect(!filmstrip.contains("rectangle.3.group.badge.plus"))

        // Ring view resolves live assets[idx] & supports Esc closing tuning panel while Metal view is focused
        #expect(ring.contains("return (assets[idx], idx)"))
        #expect(ring.contains("onFocusedAssetChanged"))
        #expect(ring.contains("if isTuningPanelExpanded"))
    }

    // MARK: - 3. Store Invalidation, Concurrency & Cross-Layer Sync Contracts

    @Test("MoodboardStore, LibraryStore, and AppUpdateStore enforce cross-layer safety and eliminate invalidation storms")
    func storeIntegrityAndPerformanceContracts() throws {
        let moodboard = try readSource("Sources/CharkleApp/Stores/MoodboardStore.swift")
        let library = try readSource("Sources/CharkleApp/Stores/LibraryStore.swift")
        let updater = try readSource("Sources/CharkleApp/Stores/AppUpdateStore.swift")

        // Locked contract #2: MoodboardStore commitMutation rejects stale board IDs + avoids full refreshBoards during drags
        #expect(moodboard.contains("guard let currentActive = activeBoard, currentActive.id == nextDoc.id else { return }"))
        #expect(moodboard.contains("syncSavedBoardSummaryIfNeeded(for:"))
        #expect(moodboard.contains("public func updateBoardHeader(id: UUID, title: String, subtitle: String) async"))
        #expect(moodboard.contains("isolated deinit"))

        // Locked contract #3: LibraryStore invalidates thumbnailLoader BEFORE updating asset record + batches mutations
        let coverRange = try #require(library.range(of: "public func updateAssetCoverImage"))
        let coverSlice = String(library[coverRange.lowerBound...].prefix(900))
        let invalidatePos = try #require(coverSlice.range(of: "thumbnailLoader.invalidate(assetID: updated.id)"))
        let publishPos = try #require(coverSlice.range(of: "allAssetsByID[updated.id] = updated"))
        #expect(invalidatePos.lowerBound < publishPos.lowerBound)

        #expect(library.contains("@ObservationIgnored private var hasBootstrapped: Bool = false"))
        #expect(library.contains("@ObservationIgnored private var lastInternalPasteboardChangeCount"))
        #expect(library.contains("suppressDerivedAssetRebuild = true"))
        #expect(library.contains("@concurrent"))
        #expect(library.contains("prepareSinglePasteboardImagePayload"))

        // AppUpdateStore cancels launch check, throttles download progress, and keeps skipVersion .idle
        #expect(updater.contains("private var launchCheckTask: Task<Void, Never>?"))
        #expect(updater.contains("launchCheckTask?.cancel()"))
        #expect(updater.contains("Preserve `.idle` if the user explicitly skipped this version while downloading."))
        #expect(updater.contains(".verifying(let current) where current.id == update.id:"))
    }

    // MARK: - 4. Notch Shelf, Pinterest, Smart Deduplication & Moodboard Generator

    @Test("Notch Shelf drops to 0Hz when pinned idle, respects open menus & modals, and reports accurate drop feedback")
    func notchShelfAuditContracts() throws {
        let notch = try readSource("Sources/CharkleApp/Notch/NotchShelfController.swift")

        #expect(notch.contains("NSMenu.didBeginTrackingNotification"))
        #expect(notch.contains("NSMenu.didEndTrackingNotification"))
        #expect(notch.contains("private var isMenuTracking: Bool = false"))
        #expect(notch.contains("shelfState.isExpanded && shelfState.isPinnedOpen && !isMouseButtonDown"))
        #expect(notch.contains("let hasHigherPriorityModal = self.coordinator.isModalOverlayPresented"))
        #expect(notch.contains("library.folderHierarchyRoots.first?.folder.id ?? library.folders.first?.id"))
        #expect(!notch.contains("max(created.count, directInputs.count)"))
    }

    @Test("Pinterest canvas, detail overlay, login sheet, Smart Deduplication, and Moodboard Generator avoid leaks and jank")
    func pinterestDedupAndGeneratorContracts() throws {
        let canvas = try readSource("Sources/CharkleApp/Views/Pinterest/PinterestInfiniteCanvasMac.swift")
        let workspace = try readSource("Sources/CharkleApp/Views/Pinterest/PinterestExploreWorkspaceView.swift")
        let login = try readSource("Sources/CharkleApp/Views/Pinterest/PinterestLoginSheetMac.swift")
        let dedup = try readSource("Sources/CharkleApp/Views/SmartDeduplicationView.swift")
        let generator = try readSource("Sources/CharkleApp/Views/MoodboardGeneratorSheet.swift")

        // Pinterest canvas: loadingURL dedupe, CoreGraphics static badge cache (zero lockFocus), balanced cursor stack
        #expect(canvas.contains("private var loadingURL: URL?"))
        #expect(canvas.contains("if desiredURL != loadedURL && desiredURL != loadingURL"))
        #expect(canvas.contains("private static var whiteSymbolCache: [String: CGImage] = [:]"))
        #expect(!canvas.contains(".lockFocus()"))
        #expect(canvas.contains("private var didPushClosedHandCursor: Bool = false"))
        #expect(canvas.contains("resetDragCursorIfNeeded()"))

        // Pinterest detail & login
        #expect(workspace.contains("coordinator.isPinterestDetailImageExpanded"))
        #expect(workspace.contains("@State private var loadedURL: URL?"))
        #expect(login.contains("@State private var verifyTask: Task<Void, Never>? = nil"))
        #expect(login.contains("coordinator.teardown()"))
        #expect(login.contains("primary.loadHTMLString(\"\", baseURL: nil)"))

        // Smart Deduplication
        #expect(dedup.contains("OSAllocatedUnfairLock<CFAbsoluteTime>"))
        #expect(dedup.contains("@State private var cleanupTask: Task<Void, Never>? = nil"))
        #expect(dedup.contains("@State private var loadedAssetID: UUID? = nil"))
        #expect(!dedup.contains("2D-DCT"))

        // Moodboard Generator
        #expect(generator.contains("@State private var curationTask: Task<Void, Never>? = nil"))
        #expect(generator.contains("private func startCuration(refinement: String?)"))
        #expect(!generator.contains("bubble.left.and.sparkles"))
        #expect(!generator.contains("Agent 会把候选素材"))
    }

    // MARK: - 5. Inspector, Sidebar, Settings & DesignSystem Polish

    @Test("Inspector, Sidebar, Settings, and DesignSystem adhere to responsive sizing, caching, and accessibility rules")
    func inspectorSidebarSettingsAndDesignSystemContracts() throws {
        let inspector = try readSource("Sources/CharkleApp/Views/InspectorView.swift")
        let sidebar = try readSource("Sources/CharkleApp/Views/SidebarView.swift")
        let smartFolder = try readSource("Sources/CharkleApp/Views/SmartFolderEditorSheet.swift")
        let settingsOverlay = try readSource("Sources/CharkleApp/Views/Settings/SettingsOverlayView.swift")
        let settingsChrome = try readSource("Sources/CharkleApp/Views/Settings/SettingsChrome.swift")
        let syncSettings = try readSource("Sources/CharkleApp/Views/Settings/SyncSettingsPane.swift")
        let aiSettings = try readSource("Sources/CharkleApp/Views/Settings/AISettingsPane.swift")
        let librarySettings = try readSource("Sources/CharkleApp/Views/Settings/LibrarySettingsPane.swift")
        let folderMenu = try readSource("Sources/CharkleApp/Views/FolderHierarchyMenu.swift")
        let folderPopover = try readSource("Sources/CharkleApp/Views/FolderCustomizationPopover.swift")
        let vignette = try readSource("Sources/CharkleApp/DesignSystem/CharkleEmptyStateVignette.swift")
        let loadingKit = try readSource("Sources/CharkleApp/DesignSystem/CharkleLoadingKit.swift")

        // Inspector
        #expect(inspector.contains("public let isActive: Bool"))
        #expect(inspector.contains("let previewContentWidth = max(160, panelWidth - 44)"))
        #expect(inspector.contains("flushBoardHeaderIfDirty("))
        #expect(inspector.contains("localizedCaseInsensitiveContains(q)"))

        // Sidebar
        #expect(sidebar.contains("public let isDraggingDivider: Bool"))
        #expect(sidebar.contains("library.childFolders(of: parentID)"))
        #expect(!sidebar.contains("Dictionary(grouping: library.folders"))

        // SmartFolderEditorSheet: no banned violet, wrapped flow layout for color chips
        #expect(!smartFolder.contains("#6366F1"))
        #expect(!smartFolder.contains("CIELAB"))

        // Settings & helpers
        #expect(!settingsOverlay.contains("library: LibraryStore(engine: syncAndAI.engine)"))
        #expect(settingsChrome.contains("private static let cachedChatGPTBrandMarkImage"))
        #expect(settingsChrome.contains("private static let fallbackDateFormatter"))
        #expect(syncSettings.contains("if isRootFolderFieldFocused"))
        #expect(aiSettings.contains(".menuIndicator(.hidden)"))
        #expect(librarySettings.contains("let fitScale = rawSum > availableW ? (availableW / rawSum) : 1.0"))
        #expect(folderMenu.contains("let roots = FolderHierarchyMenuTreeCache.roots(for: folders)"))

        // Accent source & Reduce Motion
        #expect(folderPopover.contains("@Environment(\\.charkleAccentSource)"))
        #expect(vignette.contains("@Environment(\\.charkleAccentSource)"))
        #expect(!loadingKit.contains("withAnimation(CharkleMotion.enterSm)"))
    }

    // MARK: - 6. Live macOS Runtime Audits (SF Symbols, Shortcut Masks & Purity)

    @Test("Every static SF Symbol referenced in Sources/CharkleApp resolves on macOS")
    @MainActor
    func allMacOSAppSFSymbolsExist() throws {
        let files = try allAppSwiftFiles()
        #expect(!files.isEmpty)

        let patterns = [
            #"Image\s*\(\s*systemName\s*:\s*"([a-zA-Z0-9._]+)"\s*\)"#,
            #"systemImage\s*:\s*"([a-zA-Z0-9._]+)""#,
            #"NSImage\s*\(\s*systemSymbolName\s*:\s*"([a-zA-Z0-9._]+)""#
        ]
        let regexes = try patterns.map { try NSRegularExpression(pattern: $0) }
        var missing: [String] = []

        for file in files {
            let content = try String(contentsOf: file, encoding: .utf8)
            let nsContent = content as NSString
            let fullRange = NSRange(location: 0, length: nsContent.length)
            for regex in regexes {
                for match in regex.matches(in: content, range: fullRange) where match.numberOfRanges >= 2 {
                    let symbol = nsContent.substring(with: match.range(at: 1))
                    if NSImage(systemSymbolName: symbol, accessibilityDescription: nil) == nil {
                        missing.append("\(file.lastPathComponent):\(symbol)")
                    }
                }
            }
        }
        #expect(missing.isEmpty, "Invalid macOS SF Symbols found: \(missing.joined(separator: ", "))")
    }

    @Test("Sources/CharkleApp obeys shortcut modifier mask invariant and contains zero banned violet hexes")
    func appWidePurityAndModifierMaskInvariants() throws {
        let files = try allAppSwiftFiles()
        var violations: [String] = []

        for file in files {
            let content = try String(contentsOf: file, encoding: .utf8)
            if content.contains("modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty") {
                violations.append("deviceIndependentFlagsMask.isEmpty in \(file.lastPathComponent)")
            }
            if content.localizedCaseInsensitiveContains("#6366F1") {
                violations.append("banned violet #6366F1 in \(file.lastPathComponent)")
            }
        }
        #expect(violations.isEmpty, "App-wide invariant violations: \(violations.joined(separator: "; "))")
    }

    @Test("Notch Shelf 3-mode presentation setting and slim collection capsule contracts")
    func notchShelfPresentationModeContracts() throws {
        let state = try readSource("Sources/CharkleApp/Notch/NotchShelfState.swift")
        let controller = try readSource("Sources/CharkleApp/Notch/NotchShelfController.swift")
        let view = try readSource("Sources/CharkleApp/Notch/NotchShelfView.swift")
        let settings = try readSource("Sources/CharkleApp/Views/Settings/NotchShelfSettingsPane.swift")
        let coordinator = try readSource("Sources/CharkleApp/Stores/AppCoordinatorStore.swift")

        // 3 presentation modes & persistence
        #expect(state.contains("public enum NotchShelfPresentationMode"))
        #expect(state.contains("case alwaysShowRecent"))
        #expect(state.contains("case dropOnlyOnDrag"))
        #expect(state.contains("case alwaysDropOnlyUntilExpanded"))
        #expect(state.contains("public var dropOnlyCardHeight: CGFloat"))
        #expect(state.contains("public static func shouldShowRecentStripOnExpand("))
        #expect(coordinator.contains("public var notchPresentationMode: NotchShelfPresentationMode"))
        #expect(coordinator.contains("charkle.notchPresentationMode"))

        // Controller trigger dispatch & live toggle
        #expect(controller.contains("public func expand(trigger: NotchExpandTrigger, pinOpen: Bool = false)"))
        #expect(controller.contains("public func setRecentStripExpanded(_ expanded: Bool)"))
        #expect(controller.contains("NotchShelfState.shouldShowRecentStripOnExpand("))
        #expect(controller.contains("onToggleRecentStrip:"))

        // View slim collection capsule + 1-click expand/collapse + Settings UI
        #expect(view.contains("展开最近素材 ("))
        #expect(view.contains("onToggleRecentStrip(true)"))
        #expect(view.contains("onToggleRecentStrip(false)"))
        #expect(settings.contains("title: \"托盘展开形态\""))
        #expect(settings.contains("coordinator.notchPresentationMode"))
    }

    @Test("macOS P0 polish: zero borderlessButton menu chevron leaks and unified 0.5pt hairline strokes")
    @MainActor
    func macOSP0DropdownAndHairlineContracts() throws {
        let appFiles = try allAppSwiftFiles()
        let canvasRoot = Self.repoRoot.appendingPathComponent("Sources/CharkleCanvas", isDirectory: true)
        var canvasFiles: [URL] = []
        if let enumerator = FileManager.default.enumerator(
            at: canvasRoot,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) {
            for case let url as URL in enumerator where url.pathExtension == "swift" {
                canvasFiles.append(url)
            }
        }
        let uiFiles = (appFiles + canvasFiles).sorted { $0.path < $1.path }
        #expect(!uiFiles.isEmpty)

        var violations: [String] = []
        let nonHairlinePattern = try NSRegularExpression(pattern: #"lineWidth:\s*(?:[^,\n]*:\s*)?(?:0\.75|0\.6)\b"#)

        for file in uiFiles {
            let content = try String(contentsOf: file, encoding: .utf8)
            if content.contains(".menuStyle(.borderlessButton)") {
                violations.append("borderlessButton MenuStyle in \(file.lastPathComponent)")
            }
            if content.contains(".menuIndicator(.automatic)") {
                violations.append("automatic menuIndicator in \(file.lastPathComponent)")
            }
            let nsContent = content as NSString
            let range = NSRange(location: 0, length: nsContent.length)
            if nonHairlinePattern.firstMatch(in: content, range: range) != nil {
                violations.append("non-hairline 0.75/0.6 lineWidth in \(file.lastPathComponent)")
            }
        }
        #expect(violations.isEmpty, "P0 dropdown/hairline violations: \(violations.joined(separator: "; "))")

        let controls = try readSource("Sources/CharkleApp/DesignSystem/CharkleControls.swift")
        let canvasSupport = try readSource("Sources/CharkleCanvas/CanvasSupport.swift")
        let inspector = try readSource("Sources/CharkleApp/Views/InspectorView.swift")
        let pinterest = try readSource("Sources/CharkleApp/Views/Pinterest/PinterestExploreWorkspaceView.swift")
        let syncPane = try readSource("Sources/CharkleApp/Views/Settings/SyncSettingsPane.swift")

        #expect(controls.contains("struct CharkleMenuTriggerButtonStyle"))
        #expect(controls.contains("struct CharkleDropdownChevron"))
        #expect(CanvasSurface.hairlineWidth == 0.5)
        #expect(canvasSupport.contains("struct CanvasMenuTriggerButtonStyle"))
        #expect(inspector.contains("CharkleDropdownChevron("))
        #expect(pinterest.contains("CharkleDropdownChevron("))
        #expect(syncPane.contains("CharkleDropdownChevron("))
    }

    @Test("macOS P1 polish: 4-step >=12pt studio typography scale and concentric continuous corner radii")
    @MainActor
    func macOSP1TypographyAndConcentricRadiusContracts() throws {
        // 1. Canonical 4-step typography scale & concentric radius helper invariants
        #expect(CanvasTextStyle.allCases.map(\.rawValue) == [12, 13, 16, 20])
        #expect(CanvasTextStyle.allCases.allSatisfy { $0.rawValue >= 12 })
        #expect(CanvasSurface.Radius.concentricInner(outer: 20, padding: 8) == 12)
        #expect(CanvasSurface.Radius.concentricInner(outer: 16, padding: 6) == 10)
        #expect(CanvasSurface.Radius.concentricInner(outer: 12, padding: 6) == 6)
        #expect(CanvasSurface.Radius.concentricInner(outer: 6, padding: 4) == 4)

        let theme = try readSource("Sources/CharkleApp/DesignSystem/CharkleTheme.swift")
        #expect(theme.contains("enum CharkleTextStyle"))
        #expect(theme.contains("case caption = 12"))
        #expect(theme.contains("case body = 13"))
        #expect(theme.contains("case headline = 16"))
        #expect(theme.contains("case title = 20"))
        #expect(theme.contains("static func text("))

        // 2. App-wide scan: zero oddball non-grid cornerRadius literals & zero raw .font(.system(size:)) on UI text
        let appFiles = try allAppSwiftFiles()
        let canvasRoot = Self.repoRoot.appendingPathComponent("Sources/CharkleCanvas", isDirectory: true)
        var canvasFiles: [URL] = []
        if let enumerator = FileManager.default.enumerator(
            at: canvasRoot,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) {
            for case let url as URL in enumerator where url.pathExtension == "swift" {
                canvasFiles.append(url)
            }
        }
        let uiFiles = (appFiles + canvasFiles).sorted { $0.path < $1.path }

        let oddRadiusRegex = try NSRegularExpression(pattern: #"cornerRadius:\s*(?:5|7|9|11|13|15|18|22|24)\b"#)
        let rawTextFontRegex = try NSRegularExpression(
            pattern: #"(?:Text|TextField|SecureField|TextEditor|Label)\s*\([^\n]*\)\s*\n\s*\.font\(\.system\(size:\s*[0-9]+(?:\.[0-9]+)?"#
        )
        var violations: [String] = []

        for file in uiFiles {
            let content = try String(contentsOf: file, encoding: .utf8)
            let nsContent = content as NSString
            let fullRange = NSRange(location: 0, length: nsContent.length)

            if oddRadiusRegex.firstMatch(in: content, range: fullRange) != nil {
                violations.append("oddball cornerRadius in \(file.lastPathComponent)")
            }
            if rawTextFontRegex.firstMatch(in: content, range: fullRange) != nil {
                violations.append("raw .font(.system(size:)) on text in \(file.lastPathComponent)")
            }
        }
        #expect(violations.isEmpty, "P1 typography/radius violations: \(violations.joined(separator: "; "))")
    }

    @Test("macOS P2 polish: zero middle-dot UI separators, zero promo/codename copy, and restrained monospace usage")
    @MainActor
    func macOSP2CopyAndMonospaceDisciplineContracts() throws {
        let appFiles = try allAppSwiftFiles()
        let canvasRoot = Self.repoRoot.appendingPathComponent("Sources/CharkleCanvas", isDirectory: true)
        var canvasFiles: [URL] = []
        if let enumerator = FileManager.default.enumerator(
            at: canvasRoot,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) {
            for case let url as URL in enumerator where url.pathExtension == "swift" {
                canvasFiles.append(url)
            }
        }
        let uiFiles = (appFiles + canvasFiles).sorted { $0.path < $1.path }

        let bannedCopyRegex = try NSRegularExpression(
            pattern: #"(?:10\s*秒|往屏幕顶部甩|边逛网页边|长出一块|零配置|立即可用|一键|Jev\s*Box|TypeSafe\s*\(Jev\)|TypeSafe\s+Jev|秒看)"#
        )
        var violations: [String] = []

        for file in uiFiles {
            let content = try String(contentsOf: file, encoding: .utf8)
            for (idx, rawLine) in content.components(separatedBy: .newlines).enumerated() {
                let line = rawLine.trimmingCharacters(in: .whitespaces)
                if line.hasPrefix("//") { continue }
                if line.contains("·") && !line.contains("&middot;") {
                    violations.append("middle-dot UI separator in \(file.lastPathComponent):\(idx + 1)")
                }
                if line.contains("\"") {
                    let nsLine = line as NSString
                    let range = NSRange(location: 0, length: nsLine.length)
                    if bannedCopyRegex.firstMatch(in: line, range: range) != nil {
                        violations.append("promo/codename copy in \(file.lastPathComponent):\(idx + 1)")
                    }
                }
            }
        }
        #expect(violations.isEmpty, "P2 copy/separator violations: \(violations.joined(separator: "; "))")

        let richViewers = try readSource("Sources/CharkleApp/Views/QuickLookRichViewers.swift")
        #expect(!richViewers.contains(".tracking(0.8)"))
    }
}
