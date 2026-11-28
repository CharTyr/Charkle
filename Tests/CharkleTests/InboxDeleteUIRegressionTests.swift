import AppKit
import CharkleCanvas
import CharkleCore
import Foundation
import Testing

@Suite("macOS Inbox & Gallery Delete UI Regression Tests")
struct InboxDeleteUIRegressionTests {

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

    @MainActor
    @Test("All trash, permanent-delete, and undo SF Symbols resolve cleanly on macOS")
    func trashAndUndoSFSymbolsExistOnMacOS() {
        let requiredSymbols = [
            "trash",
            "trash.slash",
            "arrow.uturn.backward",
            "folder",
            "doc.on.doc",
            "scissors"
        ]
        for symbol in requiredSymbols {
            #expect(
                NSImage(systemSymbolName: symbol, accessibilityDescription: nil) != nil,
                "Expected SF Symbol '\(symbol)' to exist on macOS"
            )
        }
    }

    @Test("Next-selection focus resolution selects next on middle/first delete, previous on tail delete, and nil on last remaining item")
    func nextSelectionFocusResolutionAfterDeletion() {
        let a = UUID()
        let b = UUID()
        let c = UUID()
        let d = UUID()
        let ordered = [a, b, c, d]

        // Middle item -> selects next item
        #expect(
            MasonryLayoutEngine.nextFocusAssetIDAfterDeleting(deletedIDs: [b], in: ordered) == c
        )

        // First item -> selects next item
        #expect(
            MasonryLayoutEngine.nextFocusAssetIDAfterDeleting(deletedIDs: [a], in: ordered) == b
        )

        // Last item -> selects previous item
        #expect(
            MasonryLayoutEngine.nextFocusAssetIDAfterDeleting(deletedIDs: [d], in: ordered) == c
        )

        // Contiguous middle batch -> selects item after batch
        #expect(
            MasonryLayoutEngine.nextFocusAssetIDAfterDeleting(deletedIDs: [b, c], in: ordered) == d
        )

        // Contiguous tail batch -> selects item before batch
        #expect(
            MasonryLayoutEngine.nextFocusAssetIDAfterDeleting(deletedIDs: [c, d], in: ordered) == b
        )

        // Single item list -> empty selection (nil)
        #expect(
            MasonryLayoutEngine.nextFocusAssetIDAfterDeleting(deletedIDs: [a], in: [a]) == nil
        )

        // All items deleted -> empty selection (nil)
        #expect(
            MasonryLayoutEngine.nextFocusAssetIDAfterDeleting(deletedIDs: Set(ordered), in: ordered) == nil
        )

        // Unrelated ID not in visible list -> nil
        #expect(
            MasonryLayoutEngine.nextFocusAssetIDAfterDeleting(deletedIDs: [UUID()], in: ordered) == nil
        )
    }

    @Test("Keyboard Delete / Forward Delete / ⌘Delete, modifier masking, and single-item trash buttons are wired across all macOS surfaces")
    func deleteUISurfaceAndModifierMaskingContracts() throws {
        let mainWindow = try readSource("Sources/CharkleApp/Views/MainWindowView.swift")
        let inspector = try readSource("Sources/CharkleApp/Views/InspectorView.swift")
        let compactGallery = try readSource("Sources/CharkleApp/Views/CompactIndexGalleryView.swift")
        let masonry = try readSource("Sources/CharkleCanvas/VirtualizedMasonryView.swift")
        let quickLook = try readSource("Sources/CharkleApp/Views/QuickLookOverlayView.swift")
        let appEntry = try readSource("Sources/CharkleApp/CharkleAppEntry.swift")

        // 1. Strict modifier masking invariant: never use `.deviceIndependentFlagsMask`
        for (name, source) in [
            ("MainWindowView.swift", mainWindow),
            ("InspectorView.swift", inspector),
            ("CompactIndexGalleryView.swift", compactGallery),
            ("VirtualizedMasonryView.swift", masonry),
            ("QuickLookOverlayView.swift", quickLook),
            ("CharkleAppEntry.swift", appEntry)
        ] {
            #expect(
                !source.contains("deviceIndependentFlagsMask"),
                "\(name) must mask against [.command, .option, .control, .shift], never deviceIndependentFlagsMask"
            )
        }

        for (name, keyHandlingSource) in [
            ("MainWindowView.swift", mainWindow),
            ("CompactIndexGalleryView.swift", compactGallery),
            ("VirtualizedMasonryView.swift", masonry),
            ("QuickLookOverlayView.swift", quickLook)
        ] {
            #expect(
                keyHandlingSource.contains(".intersection([.command, .option, .control, .shift])"),
                "\(name) must mask NSEvent.modifierFlags against [.command, .option, .control, .shift]"
            )
            #expect(
                keyHandlingSource.contains("51") && keyHandlingSource.contains("117"),
                "\(name) must handle both Delete (51) and Forward Delete (117)"
            )
        }

        // 2. MainWindowView: window-wide Delete + Inbox Triage Bar trailing Trash button + Undo helper
        #expect(mainWindow.contains("trashGalleryAssetsWithUndo("))
        #expect(mainWindow.contains("trashQuickLookAssetWithUndo("))
        #expect(mainWindow.contains("将当前选中或首项移至废纸篓 (Delete)"))

        // 3. InspectorView: single-asset Quick Actions 4th subtle segment Delete button
        #expect(inspector.contains("Label(\"删除\", systemImage: \"trash\")"))
        #expect(inspector.contains(".help(\"移至废纸篓 (Delete)\")"))
        #expect(inspector.contains("library.trashAssets([id])"))

        // 4. CompactIndexGalleryView: quiet hover Trash & Permanent Delete buttons + keyboard delete
        #expect(compactGallery.contains("let onTrashAsset: () -> Void"))
        #expect(compactGallery.contains("trashCompactAssetsWithUndo("))
        #expect(compactGallery.contains(".help(\"移至废纸篓\")"))

        // 5. VirtualizedMasonryView: performKeyEquivalent (⌘⌫) + keyDown (51/117) fallback
        #expect(masonry.contains("triggerKeyboardDeleteSelection()"))
        #expect(masonry.contains("callbacks.onTrashAssets(targets)"))
        #expect(masonry.contains("callbacks.onPermanentlyDeleteAssets(targets)"))

        // 6. QuickLookOverlayView: bottom HUD trash button + keyboard Delete
        #expect(quickLook.contains("hudIconButton(\"trash\", help: \"移至废纸篓 (Delete)\")"))
        #expect(quickLook.contains("trashCurrentQuickLookAsset()"))

        // 7. CharkleAppEntry: Edit menu 移至废纸篓 (⌘⌫) under CommandGroup(after: .pasteboard)
        #expect(appEntry.contains("CommandGroup(after: .pasteboard)"))
        #expect(appEntry.contains("Button(\"移至废纸篓\")"))
        #expect(appEntry.contains(".keyboardShortcut(.delete, modifiers: .command)"))
    }
}
