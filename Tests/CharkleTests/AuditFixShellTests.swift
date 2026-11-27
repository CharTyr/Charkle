import CharkleCanvas
import CharkleCore
import Foundation
import Testing

@Suite("Phase 2 Shell, Navigation, Inspector, Settings & DesignSystem Audit Regression Tests")
struct AuditFixShellTests {

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

    @Test("CharkleDragIdentifiers keeps internal asset and folder payloads disjoint so drops never misclassify")
    @MainActor
    func dragIdentifiersAreDisjoint() {
        let a1 = UUID()
        let a2 = UUID()
        let f1 = UUID()
        let f2 = UUID()

        let singleAsset = CharkleDragIdentifiers.encode(assetIDs: [a1])
        let multiAsset = CharkleDragIdentifiers.encode(assetIDs: [a1, a2])
        let singleFolder = CharkleDragIdentifiers.encode(folderIDs: [f1])
        let multiFolder = CharkleDragIdentifiers.encode(folderIDs: [f1, f2])

        #expect(CharkleDragIdentifiers.decodeAssetIDs(from: singleAsset) == [a1])
        #expect(CharkleDragIdentifiers.decodeFolderIDs(from: singleAsset) == nil)

        #expect(CharkleDragIdentifiers.decodeAssetIDs(from: multiAsset) == [a1, a2])
        #expect(CharkleDragIdentifiers.decodeFolderIDs(from: multiAsset) == nil)

        #expect(CharkleDragIdentifiers.decodeFolderIDs(from: singleFolder) == [f1])
        #expect(CharkleDragIdentifiers.decodeAssetIDs(from: singleFolder) == nil)

        #expect(CharkleDragIdentifiers.decodeFolderIDs(from: multiFolder) == [f1, f2])
        #expect(CharkleDragIdentifiers.decodeAssetIDs(from: multiFolder) == nil)
    }

    @Test("MainWindowView confirms Filmstrip permanent deletes, guards overlays, masks Caps Lock, and has clean UI titles")
    func mainWindowShellContracts() throws {
        let src = try readSource("Sources/CharkleApp/Views/MainWindowView.swift")

        // Filmstrip must pass full overlay guard while keeping `isQuickLookPresented:` label intact
        #expect(src.contains("isQuickLookPresented: coordinator.isModalOverlayPresented || showInboxBatchTriageSheet"))

        // Filmstrip permanent delete must route through confirmation state instead of immediate deletion
        #expect(!src.contains("onPermanentlyDeleteAssets: { ids in\n                        Task {\n                            await library.permanentlyDeleteAssets"))

        // Inbox 1-9 shortcut must mask modifier flags against primary modifiers (Caps Lock safe)
        #expect(src.contains("let primaryMods = press.modifiers.intersection([.command, .option, .control, .shift])"))

        // No internal grounding jargon in user-facing triage sheet header
        #expect(!src.contains("Companion Noul"))

        // Window-level Escape dismissal must cover Onboarding/Settings/JumpAnywhere
        #expect(src.contains("event.keyCode == 53"))
    }

    @Test("SidebarView short-circuits internal asset drops, confirms moodboard deletion, sorts by subtree count, and isolates collapse namespaces")
    func sidebarContracts() throws {
        let src = try readSource("Sources/CharkleApp/Views/SidebarView.swift")

        // Both folder header and insertion slot drop handlers must decode internal asset IDs to prevent thumbnail duplication
        let decodeAssetMatches = src.components(separatedBy: "CharkleDragIdentifiers.decodeAssetIDs(from:").count - 1
        #expect(decodeAssetMatches >= 3)

        // Moodboard deletion requires confirmation alert
        #expect(src.contains("pendingDeleteBoard"))

        // Root folder count sort must use subtreeAssetCount rather than direct assetCount
        #expect(src.contains("library.subtreeAssetCount(for: $0.id)"))

        // Distinct matchedGeometryEffect namespaces prevent duplicate active source warnings during collapse transition
        #expect(src.contains("expandedSelectionNamespace"))
        #expect(src.contains("collapsedSelectionNamespace"))
    }

    @Test("CharkleAppEntry flushes pending moodboard edits on quit and preserves text Undo/Redo")
    func appEntryContracts() throws {
        let src = try readSource("Sources/CharkleApp/CharkleAppEntry.swift")

        #expect(src.contains("moodboards.triggerImmediateSaveFlush()"))
        #expect(src.contains("Selector((\"undo:\"))"))
        #expect(src.contains("Selector((\"redo:\"))"))
        #expect(!src.contains(".disabled(!runtime.coordinator.isViewingMoodboard || !runtime.moodboards.canUndo)"))
    }

    @Test("AppIconManager never mutates signed .app bundle icon on disk and About fallback build aligns with Info.plist")
    func packagingAndIconContracts() throws {
        let iconMgr = try readSource("Sources/CharkleApp/DesignSystem/AppIconManager.swift")
        #expect(!iconMgr.contains("NSWorkspace.shared.setIcon("))
        #expect(iconMgr.contains("app.applicationIconImage = dockImg"))

        let infoPlist = try readSource("Resources/Info.plist")
        let plistBuildMatch = try #require(
            infoPlist.firstMatch(of: /<key>CFBundleVersion<\/key>\s*<string>([^<]+)<\/string>/)
        )
        let plistBuild = String(plistBuildMatch.1)
        let aboutPane = try readSource("Sources/CharkleApp/Views/Settings/AdvancedAboutSettingsPane.swift")
        #expect(aboutPane.contains("CFBundleVersion") && aboutPane.contains("?? \"\(plistBuild)\""))
    }

    @Test("JumpAnywhereView, MoodboardGeneratorSheet, and Settings modal sheets uphold interaction and feedback invariants")
    func overlaysAndSettingsContracts() throws {
        let jump = try readSource("Sources/CharkleApp/Views/JumpAnywhereView.swift")
        #expect(jump.contains("ScrollViewReader"))
        #expect(jump.contains("guard !trimmed.isEmpty else"))

        let generator = try readSource("Sources/CharkleApp/Views/MoodboardGeneratorSheet.swift")
        #expect(generator.contains("uniquingKeysWith:"))
        #expect(generator.contains("localhost"))
        #expect(generator.contains("coordinator.generatorInitialEntry"))

        let aiSettings = try readSource("Sources/CharkleApp/Views/Settings/AISettingsPane.swift")
        #expect(aiSettings.contains("SettingsSheetFeedbackBanner"))
        #expect(aiSettings.contains("http://localhost:11434/v1"))

        let syncSettings = try readSource("Sources/CharkleApp/Views/Settings/SyncSettingsPane.swift")
        #expect(syncSettings.contains("SettingsSheetFeedbackBanner"))
        #expect(!syncSettings.contains(".onTapGesture"))

        let librarySettings = try readSource("Sources/CharkleApp/Views/Settings/LibrarySettingsPane.swift")
        #expect(librarySettings.contains("SettingsSheetFeedbackBanner"))

        let oauthSheet = try readSource("Sources/CharkleApp/Views/Settings/GoogleOAuthSetupSheet.swift")
        #expect(oauthSheet.contains("SettingsSheetFeedbackBanner"))
    }

    @Test("Modal overlays suspend underlying workspace hover and pointer interaction across gallery, moodboard, Pinterest, and dividers")
    func modalOverlayHoverSuspensionContracts() throws {
        let mainWindow = try readSource("Sources/CharkleApp/Views/MainWindowView.swift")
        #expect(mainWindow.contains(".allowsHitTesting(!isMainWorkspaceOverlayPresented)"))
        #expect(mainWindow.contains(".environment(\\.charkleOverlayInteractionSuspended, isMainWorkspaceOverlayPresented)"))
        #expect(mainWindow.contains("isOverlayPresented: isMainWorkspaceOverlayPresented"))
        #expect(mainWindow.contains("isSuspended: isMainWorkspaceOverlayPresented"))

        let moodboard = try readSource("Sources/CharkleCanvas/MoodboardCanvasView.swift")
        #expect(moodboard.contains("hoverState.setSuspended(isAnyLocalModalPresented)"))
        #expect(moodboard.contains("isHoverSuspended: isAnyLocalModalPresented"))

        let nodeViews = try readSource("Sources/CharkleCanvas/MoodboardNodeViews.swift")
        #expect(nodeViews.contains("let isHoverSuspended: Bool"))

        let thumbnail = try readSource("Sources/CharkleCanvas/ThumbnailImageLoader.swift")
        #expect(thumbnail.contains("charkleOverlayInteractionSuspended"))

        let pinterest = try readSource("Sources/CharkleApp/Views/Pinterest/PinterestExploreWorkspaceView.swift")
        #expect(pinterest.contains("coordinator.isModalOverlayPresented"))
    }

    @Test("Toast overlay anchors bottom-right with tight width hugging, bottom-up entry, and 2.5D depth stack")
    func toastOverlayBottomRight25DContracts() throws {
        let toastOverlay = try readSource("Sources/CharkleApp/DesignSystem/CharkleToastOverlay.swift")
        let coordinator = try readSource("Sources/CharkleApp/Stores/AppCoordinatorStore.swift")

        // Must never greedily expand pill to 380pt before Liquid Glass (caused trailing blank space)
        #expect(!toastOverlay.contains(".frame(maxWidth: 380, alignment: .leading)"))
        // Must anchor bottom-right and pop up from bottom edge
        #expect(toastOverlay.contains("alignment: .bottomTrailing"))
        #expect(toastOverlay.contains(".move(edge: .bottom)"))
        #expect(toastOverlay.contains("CharkleToastDeckLayout"))
        #expect(toastOverlay.contains("rotation3DEffect"))
        // Coordinator supports deep stack + stack hover pause/resume + dismiss all
        #expect(coordinator.contains("public static let maxQueuedToasts"))
        #expect(coordinator.contains("public func pauseAllToasts()"))
        #expect(coordinator.contains("public func resumeAllToasts()"))
        #expect(coordinator.contains("public func dismissAllToasts()"))
    }

    @Test("All Settings panes and SyncAndAIStore feedback route through the Toast notification system")
    func settingsFeedbackRoutesToToastContracts() throws {
        let syncAndAI = try readSource("Sources/CharkleApp/Stores/SyncAndAIStore.swift")
        let settingsOverlay = try readSource("Sources/CharkleApp/Views/Settings/SettingsOverlayView.swift")
        let general = try readSource("Sources/CharkleApp/Views/Settings/GeneralSettingsPane.swift")
        let notch = try readSource("Sources/CharkleApp/Views/Settings/NotchShelfSettingsPane.swift")
        let capture = try readSource("Sources/CharkleApp/Views/Settings/CaptureShortcutsSettingsPane.swift")
        let extensions = try readSource("Sources/CharkleApp/Views/Settings/ExtensionsSettingsPane.swift")
        let advanced = try readSource("Sources/CharkleApp/Views/Settings/AdvancedAboutSettingsPane.swift")
        let syncPane = try readSource("Sources/CharkleApp/Views/Settings/SyncSettingsPane.swift")
        let aiPane = try readSource("Sources/CharkleApp/Views/Settings/AISettingsPane.swift")

        // SyncAndAIStore emits monotonic feedback events bridged into Toast by SettingsContentShell
        #expect(syncAndAI.contains("public private(set) var lastFeedbackEvent: SettingsFeedbackEvent?"))
        #expect(settingsOverlay.contains(".onChange(of: syncAndAI.lastFeedbackEvent)"))
        #expect(settingsOverlay.contains("coordinator.showToast("))
        #expect(!settingsOverlay.contains("private func feedbackBanner("))

        // Direct interactive controls across all Settings panes emit clear toast / feedback messages
        #expect(general.contains("coordinator.showToast("))
        #expect(notch.contains("coordinator.showToast("))
        #expect(capture.contains("已启用系统全局快捷键"))
        #expect(extensions.contains("已开启浏览器扩展本地桥接"))
        #expect(advanced.contains("已开启启动时自动检查更新"))
        #expect(syncPane.contains("已开启同步轻量化预览图"))
        #expect(aiPane.contains("已开启导入时自动 AI 分析"))
    }
}
