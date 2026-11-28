import AppKit
import CharkleCanvas
import CharkleCore
import Foundation
import SwiftUI
import Testing
import UniformTypeIdentifiers

@Suite("Drag-Drop Duplication & Navigation Search Reset Regression Tests")
struct DragDropAndNavigationRegressionTests {

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

    private static let minimalPNGBytes = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 1, 2, 3, 4, 5, 6, 7, 8])
    private static let minimalJPGBytes = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0x49, 0x46])

    @Test("CharkleDragPasteboardResolver recovers internal asset IDs from pasteboard with image fileURL (prevents macOS 27 .image stripping duplication)")
    @MainActor
    func resolvesInternalAssetDragSynchronouslyAlongsideImageFileURL() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("charkle_drag_test_\(UUID().uuidString)", isDirectory: true)
        let originalsDir = tmpDir.appendingPathComponent("Originals", isDirectory: true)
        try FileManager.default.createDirectory(at: originalsDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let a1 = UUID()
        let a2 = UUID()
        let pngURL = originalsDir.appendingPathComponent("\(a1.uuidString).png")
        let jpgURL = originalsDir.appendingPathComponent("\(a2.uuidString).jpg")
        try Self.minimalPNGBytes.write(to: pngURL)
        try Self.minimalJPGBytes.write(to: jpgURL)

        // Single PNG internal drag (exact VirtualizedMasonryView pasteboard layout)
        let pbSingle = NSPasteboard.withUniqueName()
        let item0 = NSPasteboardItem()
        let encodedSingle = CharkleDragIdentifiers.encode(assetIDs: [a1])
        item0.setString(encodedSingle, forType: CharkleDragIdentifiers.internalPasteboardType)
        item0.setString(encodedSingle, forType: .string)
        item0.setString(pngURL.absoluteString, forType: .fileURL)
        pbSingle.writeObjects([item0])

        let resolvedSingle = CharkleDragPasteboardResolver.resolveSynchronously(from: pbSingle)
        #expect(resolvedSingle.assetIDs == [a1])
        #expect(resolvedSingle.folderIDs.isEmpty)
        #expect(resolvedSingle.externalFileURLs.isEmpty)
        #expect(CharkleDragPasteboardResolver.isInternalDrag(pasteboard: pbSingle))

        // Multi-asset internal drag (item 0 has IDs + PNG fileURL; item 1 has JPEG fileURL only)
        let pbMulti = NSPasteboard.withUniqueName()
        let m0 = NSPasteboardItem()
        let encodedMulti = CharkleDragIdentifiers.encode(assetIDs: [a1, a2])
        m0.setString(encodedMulti, forType: CharkleDragIdentifiers.internalPasteboardType)
        m0.setString(encodedMulti, forType: .string)
        m0.setString(pngURL.absoluteString, forType: .fileURL)
        let m1 = NSPasteboardItem()
        m1.setString(jpgURL.absoluteString, forType: .fileURL)
        pbMulti.writeObjects([m0, m1])

        let resolvedMulti = CharkleDragPasteboardResolver.resolveSynchronously(from: pbMulti)
        #expect(resolvedMulti.assetIDs == [a1, a2])
        #expect(resolvedMulti.externalFileURLs.isEmpty)
    }

    @Test("CharkleDragPasteboardResolver preserves real external Finder image fileURLs and redirects internal cache URLs without duplicating")
    @MainActor
    func externalFinderFilenamePreservedAndInternalCacheURLRedirected() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("charkle_finder_drop_\(UUID().uuidString)", isDirectory: true)
        let originalsDir = tmpDir.appendingPathComponent("Originals", isDirectory: true)
        try FileManager.default.createDirectory(at: originalsDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        // 1. Real external Finder file: must keep original filename URL (never fall back to SidebarDrop-*.png)
        let finderPNG = tmpDir.appendingPathComponent("CharacterConcept.png")
        try Self.minimalPNGBytes.write(to: finderPNG)

        let pbExternal = NSPasteboard.withUniqueName()
        let extItem = NSPasteboardItem()
        extItem.setString(finderPNG.absoluteString, forType: .fileURL)
        pbExternal.writeObjects([extItem])

        let resolvedExt = CharkleDragPasteboardResolver.resolveSynchronously(
            from: pbExternal,
            resolveCachedAssetID: { CharkleDragIdentifiers.decodeInternalCacheAssetID(from: $0) }
        )
        #expect(resolvedExt.assetIDs.isEmpty)
        #expect(resolvedExt.folderIDs.isEmpty)
        #expect(resolvedExt.externalFileURLs.map(\.lastPathComponent) == ["CharacterConcept.png"])
        #expect(!CharkleDragPasteboardResolver.isInternalDrag(pasteboard: pbExternal))

        // 2. Defense-in-depth: even if `.string` were somehow missing, a file inside `Originals/<UUID>.png`
        // resolves back to its owning asset ID instead of being re-ingested as a duplicate.
        let cachedAssetID = UUID()
        let cachedOriginal = originalsDir.appendingPathComponent("\(cachedAssetID.uuidString).png")
        try Self.minimalPNGBytes.write(to: cachedOriginal)

        let pbCachedOnly = NSPasteboard.withUniqueName()
        let cachedItem = NSPasteboardItem()
        cachedItem.setString(cachedOriginal.absoluteString, forType: .fileURL)
        pbCachedOnly.writeObjects([cachedItem])

        let resolvedCached = CharkleDragPasteboardResolver.resolveSynchronously(
            from: pbCachedOnly,
            resolveCachedAssetID: { url in
                CharkleDragIdentifiers.decodeInternalCacheAssetID(from: url) == cachedAssetID ? cachedAssetID : nil
            }
        )
        #expect(resolvedCached.assetIDs == [cachedAssetID])
        #expect(resolvedCached.externalFileURLs.isEmpty)
    }

    @Test("Live SwiftUI .onDrop(of: [.plainText, .fileURL, .url, .image]) recovers internal drag via synchronous drag pasteboard resolution")
    @MainActor
    func liveSwiftUIDropWithImageTypeRecoversInternalAssetID() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("charkle_live_drop_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let assetID = UUID()
        let pngURL = tmpDir.appendingPathComponent("\(assetID.uuidString).png")
        try Self.minimalPNGBytes.write(to: pngURL)

        let dragPB = NSPasteboard.withUniqueName()
        let pbItem = NSPasteboardItem()
        let encoded = CharkleDragIdentifiers.encode(assetIDs: [assetID])
        pbItem.setString(encoded, forType: CharkleDragIdentifiers.internalPasteboardType)
        pbItem.setString(encoded, forType: .string)
        pbItem.setString(pngURL.absoluteString, forType: .fileURL)
        dragPB.writeObjects([pbItem])

        var capturedPayload: CharkleSynchronousDragPayload?
        struct ProbeDropView: View {
            let pasteboard: NSPasteboard
            let onResolved: (CharkleSynchronousDragPayload) -> Void
            var body: some View {
                Color.clear
                    .frame(width: 120, height: 120)
                    .onDrop(of: [.plainText, .fileURL, .url, .image], isTargeted: nil) { _ in
                        onResolved(CharkleDragPasteboardResolver.resolveSynchronously(from: pasteboard))
                        return true
                    }
            }
        }

        final class MockDragInfo: NSObject, NSDraggingInfo {
            let pb: NSPasteboard
            let win: NSWindow
            init(pb: NSPasteboard, win: NSWindow) { self.pb = pb; self.win = win }
            var draggingDestinationWindow: NSWindow? { win }
            var draggingSourceOperationMask: NSDragOperation { [.move, .copy] }
            var draggingLocation: NSPoint { NSPoint(x: 60, y: 60) }
            var draggedImageLocation: NSPoint { .zero }
            var draggedImage: NSImage? { nil }
            var draggingPasteboard: NSPasteboard { pb }
            var draggingSource: Any? { nil }
            var draggingSequenceNumber: Int { 1 }
            var draggingFormation: NSDraggingFormation = .default
            var animatesToDestination: Bool = false
            var numberOfValidItemsForDrop: Int = 1
            func slideDraggedImage(to screenPoint: NSPoint) {}
            func enumerateDraggingItems(
                options enumOpts: NSDraggingItemEnumerationOptions = [],
                for view: NSView?,
                classes classArray: [AnyClass],
                searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
                using block: @escaping (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void
            ) {}
            func resetSpringLoading() {}
            var springLoadingHighlight: NSSpringLoadingHighlight { .none }
        }

        func findDragTarget(_ view: NSView) -> NSView? {
            if !view.registeredDraggedTypes.isEmpty { return view }
            for sub in view.subviews {
                if let match = findDragTarget(sub) { return match }
            }
            return nil
        }

        let hosting = NSHostingView(rootView: ProbeDropView(pasteboard: dragPB) { capturedPayload = $0 })
        hosting.frame = NSRect(x: 0, y: 0, width: 120, height: 120)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = hosting
        window.orderBack(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        let target = findDragTarget(hosting) ?? hosting
        let mock = MockDragInfo(pb: dragPB, win: window)
        _ = target.draggingEntered(mock)
        _ = target.draggingUpdated(mock)
        _ = target.prepareForDragOperation(mock)
        let performed = target.performDragOperation(mock)

        #expect(performed)
        #expect(capturedPayload?.assetIDs == [assetID])
        #expect(capturedPayload?.externalFileURLs.isEmpty == true)
    }

    @Test("CharkleLibraryCountFormatting clarifies filtered counts as visible / total while keeping unfiltered counts concise")
    func headerCountFormattingDistinguishesFilteredAndUnfilteredStates() {
        #expect(CharkleLibraryCountFormatting.headerCountLabel(visibleCount: 1, unfilteredTotal: 1, isFiltered: false) == "1")
        #expect(CharkleLibraryCountFormatting.headerCountLabel(visibleCount: 0, unfilteredTotal: 0, isFiltered: false) == "0")
        #expect(CharkleLibraryCountFormatting.headerCountLabel(visibleCount: 0, unfilteredTotal: 1, isFiltered: true) == "0 / 1")
        #expect(CharkleLibraryCountFormatting.headerCountLabel(visibleCount: 3, unfilteredTotal: 94, isFiltered: true) == "3 / 94")
        #expect(CharkleLibraryCountFormatting.headerCountLabel(visibleCount: 5, unfilteredTotal: nil, isFiltered: true) == "5")
    }

    @Test("SidebarView and MoodboardCanvasView resolve internal drag IDs synchronously before SwiftUI .onDrop strips plainText on macOS 27")
    func dropHandlersResolveSynchronouslyBeforeAsyncProviders() throws {
        let sidebar = try readSource("Sources/CharkleApp/Views/SidebarView.swift")
        let moodboard = try readSource("Sources/CharkleCanvas/MoodboardCanvasView.swift")
        let masonry = try readSource("Sources/CharkleCanvas/VirtualizedMasonryView.swift")

        #expect(sidebar.contains("CharkleDragPasteboardResolver.resolveSynchronously("))
        #expect(moodboard.contains("CharkleDragPasteboardResolver.resolveSynchronously("))
        #expect(masonry.contains("CharkleDragIdentifiers.internalPasteboardType"))
    }

    @Test("LibraryStore.applyDestination clears stale searchQuery and MainWindowView keeps searchDraft and filtered header count in sync")
    func destinationNavigationClearsStaleSearchAndClarifiesFilteredCounts() throws {
        let store = try readSource("Sources/CharkleApp/Stores/LibraryStore.swift")
        let mainWindow = try readSource("Sources/CharkleApp/Views/MainWindowView.swift")

        #expect(store.contains("nextFilter.searchQuery = \"\""))
        #expect(mainWindow.contains(".onChange(of: library.filter.searchQuery)"))
        #expect(mainWindow.contains("headerCountLabel("))
    }
}
