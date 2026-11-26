import CoreGraphics
import Foundation
import Observation

/// Unified cross-platform (`macOS` + `iOS/iPadOS`) controller driving Charkle's native Pinterest
/// infinite 2D spatial browser, shopping-cart collection tray, and floating Pin detail + similar pins stack.
@Observable
@MainActor
public final class PinterestExploreController {
    // MARK: - Auth & Account State
    public var account: PinterestAccount?
    public var boards: [PinterestBoard] = []
    public var isCheckingSession: Bool = false
    public var isLoadingBoards: Bool = false
    public var isLoginSheetPresented: Bool = false
    public var needsReauthentication: Bool = false

    // MARK: - Board Collection Batch Import State
    public var isBoardImportSheetPresented: Bool = false
    public var isImportingBoards: Bool = false
    public var boardImportProgress: PinterestBoardImportProgress?
    public var lastBoardsImportReport: PinterestBoardsImportReport?
    @ObservationIgnored private var activeBoardImportTask: Task<PinterestBoardsImportReport, Never>?

    // MARK: - Infinite Spatial Feed State
    public var feedSource: PinterestFeedSource = .homeFeed
    public var searchText: String = ""
    public var layout: PinterestSpatialLayout
    public var layoutRevision: Int = 0
    public var isLoadingFeed: Bool = false
    public var isLoadingMore: Bool = false
    public var hasMore: Bool = true
    public var nextBookmark: String?
    public var errorMessage: String?
    /// When enabled, clicking/tapping any card in the infinite space directly toggles it into the tray.
    public var fastPickMode: Bool = false

    // MARK: - Shopping-Cart Collection Tray State
    public var trayPins: [PinterestPin] = []
    public var selectedTrayPinIDs: Set<String> = []
    public var isTrayExpanded: Bool = false
    public var importedPinIDs: Set<String> = []
    public var isImportingTray: Bool = false
    public var importProgress: (completed: Int, total: Int)?

    // MARK: - Floating Pin Detail + Similar Pins Stack
    public var detailStack: [PinterestPin] = []
    public var detailSimilarPins: [PinterestPin] = []
    public var detailSimilarBookmark: String?
    public var detailHasMoreSimilar: Bool = false
    public var isLoadingDetail: Bool = false
    public var isLoadingMoreSimilar: Bool = false

    public var activeDetailPin: PinterestPin? {
        detailStack.last
    }

    public var isSignedIn: Bool {
        account != nil
    }

    public var selectedTrayPins: [PinterestPin] {
        trayPins.filter { selectedTrayPinIDs.contains($0.id) }
    }

    public var trayCount: Int {
        trayPins.count
    }

    public var selectedTrayCount: Int {
        trayPins.reduce(0) { $0 + (selectedTrayPinIDs.contains($1.id) ? 1 : 0) }
    }

    @ObservationIgnored private var hasBootstrapped: Bool = false
    @ObservationIgnored private var feedGeneration: UInt64 = 0
    @ObservationIgnored private var detailGeneration: UInt64 = 0
    @ObservationIgnored private var detailCache: [String: PinterestPinDetailResult] = [:]
    @ObservationIgnored private var lastEdgeTriggerTime: Date = .distantPast
    @ObservationIgnored private var lastViewportCenter: CGPoint?
    @ObservationIgnored private var lastViewportTimestamp: Date = .distantPast
    @ObservationIgnored private var smoothedWorldVelocity: CGVector = .zero
    @ObservationIgnored private var lastPrefetchTime: Date = .distantPast
    @ObservationIgnored private var lastVisibleWorldRect: CGRect = .zero
    @ObservationIgnored private var lastCameraScale: CGFloat = 0.90
    @ObservationIgnored private let persistTray: Bool

    public init(
        cardWidth: CGFloat = 224,
        gap: CGFloat = 16,
        persistTray: Bool = true
    ) {
        self.layout = PinterestSpatialLayout(cardWidth: cardWidth, gap: gap)
        self.persistTray = persistTray
        if persistTray {
            let loaded = PinterestTrayStorage.load()
            self.trayPins = loaded
            self.selectedTrayPinIDs = Set(loaded.map(\.id))
        }
    }

    // MARK: - Lifecycle & Authentication

    public func bootstrap(engine: any CharkleEngineProtocol) async {
        await refreshImportedPinIDs(in: engine)
        guard !hasBootstrapped else { return }
        hasBootstrapped = true
        await verifySessionAndLoadIfNeeded()
    }

    public func refreshImportedPinIDs(in engine: any CharkleEngineProtocol) async {
        importedPinIDs = await PinterestImportService.existingImportedPinIDs(in: engine)
    }

    public func verifySessionAndLoadIfNeeded() async {
        isCheckingSession = true
        defer { isCheckingSession = false }

        let detected = await PinterestSessionBridge.shared.checkSessionAccount()
        account = detected
        if let detected {
            needsReauthentication = false
            errorMessage = nil
            Task { [weak self] in
                await self?.loadBoards(username: detected.username)
            }
            if layout.cards.isEmpty {
                await reloadFeed()
            }
        }
    }

    public func handleLoginCompleted(engine: any CharkleEngineProtocol) async -> Bool {
        isCheckingSession = true
        defer { isCheckingSession = false }

        PinterestSessionBridge.shared.resetWarmContext()
        let detected = await PinterestSessionBridge.shared.checkSessionAccount()
        account = detected
        guard let detected else {
            return false
        }
        isLoginSheetPresented = false
        needsReauthentication = false
        errorMessage = nil
        await refreshImportedPinIDs(in: engine)
        Task { [weak self] in
            await self?.loadBoards(username: detected.username)
        }
        await reloadFeed()
        return true
    }

    public func signOut() async {
        feedGeneration &+= 1
        detailGeneration &+= 1
        await PinterestSessionBridge.shared.signOut()
        account = nil
        boards = []
        layout.reset()
        layoutRevision &+= 1
        detailStack.removeAll()
        detailSimilarPins.removeAll()
        detailCache.removeAll()
        nextBookmark = nil
        hasMore = true
        errorMessage = nil
        needsReauthentication = false
    }

    public func refreshBoards() async {
        guard let username = account?.username else { return }
        await loadBoards(username: username)
    }

    private func loadBoards(username: String) async {
        isLoadingBoards = true
        defer { isLoadingBoards = false }
        if let fetched = try? await PinterestSessionBridge.shared.fetchUserBoards(username: username) {
            boards = fetched
        }
    }

    /// Batch-imports the chosen Pinterest Boards into Charkle, creating/reusing one folder per board.
    public func importBoards(
        _ selectedBoards: [PinterestBoard],
        into engine: any CharkleEngineProtocol,
        destination: PinterestBoardImportDestination = .pinterestRootFolder,
        extraTags: [String] = [],
        skipDuplicates: Bool = true
    ) async -> PinterestBoardsImportReport {
        guard !selectedBoards.isEmpty, !isImportingBoards else {
            return PinterestBoardsImportReport(
                boardsProcessed: 0,
                foldersCreated: 0,
                importedAssets: [],
                importedPinIDs: [],
                skippedDuplicatePinIDs: [],
                failedPinIDs: [],
                failedBoardNames: [],
                wasCancelled: false
            )
        }

        isImportingBoards = true
        boardImportProgress = nil
        lastBoardsImportReport = nil

        let progressHandler: @Sendable (PinterestBoardImportProgress) -> Void = { [weak self] progress in
            let target = self
            Task { @MainActor in
                target?.boardImportProgress = progress
            }
        }

        let task = Task<PinterestBoardsImportReport, Never> { @MainActor in
            await PinterestImportService.importBoards(
                selectedBoards,
                into: engine,
                destination: destination,
                extraTags: extraTags,
                skipDuplicates: skipDuplicates,
                pinProvider: { board, onPageFetched in
                    try await PinterestSessionBridge.shared.fetchAllPins(
                        in: board,
                        maxPins: 2000,
                        onPageFetched: onPageFetched
                    )
                },
                onProgress: progressHandler
            )
        }

        activeBoardImportTask = task
        let report = await task.value
        activeBoardImportTask = nil
        isImportingBoards = false
        boardImportProgress = nil
        lastBoardsImportReport = report

        importedPinIDs.formUnion(report.importedPinIDs)
        importedPinIDs.formUnion(report.skippedDuplicatePinIDs)
        return report
    }

    public func cancelBoardImport() {
        activeBoardImportTask?.cancel()
    }

    // MARK: - Infinite Spatial Feed Loading

    public func switchSource(_ source: PinterestFeedSource) async {
        feedSource = source
        if case .search(let q) = source {
            searchText = q
        } else if case .homeFeed = source {
            searchText = ""
        }
        await reloadFeed()
    }

    public func submitSearch() async {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            await switchSource(.homeFeed)
        } else {
            await switchSource(.search(trimmed))
        }
    }

    public func reloadFeed() async {
        guard isSignedIn else { return }
        feedGeneration &+= 1
        let gen = feedGeneration

        isLoadingFeed = true
        isLoadingMore = false
        errorMessage = nil
        nextBookmark = nil
        hasMore = true
        layout.reset()

        // When exploring "Similar in Infinite Space", anchor the chosen pin right at world (0, 0).
        if case .similar(let anchorPin) = feedSource {
            layout.append([anchorPin])
        }
        layoutRevision &+= 1

        defer {
            if gen == feedGeneration {
                isLoadingFeed = false
            }
        }

        do {
            let page1 = try await PinterestSessionBridge.shared.fetchFeed(
                source: feedSource,
                bookmark: nil,
                pageSize: 32
            )
            guard gen == feedGeneration else { return }
            let added1 = layout.append(page1.pins)
            nextBookmark = page1.bookmark
            hasMore = page1.hasMore && page1.bookmark != nil
            layoutRevision &+= 1
            prefetchInitialImages(from: added1)

            // Pre-fill outer concentric rings immediately so omnidirectional panning starts with a rich
            // multi-ring ocean (~85-100 cards) surrounding the user in every direction before they even flick.
            for _ in 0..<2 {
                guard layout.cards.count < 88, hasMore, let bm = nextBookmark else { break }
                if let nextPage = try? await PinterestSessionBridge.shared.fetchFeed(
                    source: feedSource,
                    bookmark: bm,
                    pageSize: 32
                ), gen == feedGeneration {
                    let addedMore = layout.append(nextPage.pins)
                    nextBookmark = nextPage.bookmark
                    hasMore = nextPage.hasMore && nextPage.bookmark != nil && !nextPage.pins.isEmpty
                    if !addedMore.isEmpty {
                        layoutRevision &+= 1
                        prefetchAroundCurrentViewport(force: true)
                    } else {
                        break
                    }
                } else {
                    break
                }
            }
        } catch let sessionError as PinterestSessionError {
            guard gen == feedGeneration else { return }
            if case .sessionExpired = sessionError {
                needsReauthentication = true
            }
            errorMessage = sessionError.localizedDescription
        } catch {
            guard gen == feedGeneration else { return }
            errorMessage = error.localizedDescription
        }
    }

    /// Tracks camera trajectory to predictively prefetch thumbnails AND proactively expand outer
    /// feed rings along the user's pan direction before they ever reach the loaded frontier.
    public func updateCameraViewport(visibleWorldRect: CGRect, scale: CGFloat) {
        let now = Date()
        let center = CGPoint(x: visibleWorldRect.midX, y: visibleWorldRect.midY)
        if let prev = lastViewportCenter {
            let dt = now.timeIntervalSince(lastViewportTimestamp)
            if dt > 0.004 && dt < 0.6 {
                let rawVx = (center.x - prev.x) / CGFloat(dt)
                let rawVy = (center.y - prev.y) / CGFloat(dt)
                smoothedWorldVelocity = CGVector(
                    dx: smoothedWorldVelocity.dx * 0.55 + rawVx * 0.45,
                    dy: smoothedWorldVelocity.dy * 0.55 + rawVy * 0.45
                )
            } else if dt >= 0.6 {
                smoothedWorldVelocity = .zero
            }
        }
        lastViewportCenter = center
        lastViewportTimestamp = now
        lastVisibleWorldRect = visibleWorldRect
        lastCameraScale = max(InfiniteSpatialCamera.minScale, min(InfiniteSpatialCamera.maxScale, scale))

        prefetchAroundCurrentViewport(force: false)
        loadMoreIfNeeded(visibleWorldRect: visibleWorldRect)
    }

    public func loadMoreIfNeeded(visibleWorldRect: CGRect) {
        guard isSignedIn,
              !isLoadingFeed,
              !isLoadingMore,
              hasMore,
              nextBookmark != nil else {
            return
        }
        let lookahead = predictiveLookaheadVector(for: visibleWorldRect)
        let projectedRect = visibleWorldRect.offsetBy(dx: lookahead.dx, dy: lookahead.dy)
        let generousThreshold = max(1050, max(visibleWorldRect.width, visibleWorldRect.height) * 0.95)
        guard layout.isApproachingEdge(visibleWorldRect: projectedRect, threshold: generousThreshold)
                || layout.isApproachingEdge(visibleWorldRect: visibleWorldRect, threshold: generousThreshold) else {
            return
        }
        let now = Date()
        guard now.timeIntervalSince(lastEdgeTriggerTime) > 0.28 else { return }
        lastEdgeTriggerTime = now

        Task { @MainActor [weak self] in
            await self?.loadNextPage()
        }
    }

    private func predictiveLookaheadVector(for visibleWorldRect: CGRect) -> CGVector {
        // Project ~1.25 seconds ahead along the smoothed pan trajectory, clamped to avoid runaway offsets.
        let maxJumpX = max(900, visibleWorldRect.width * 1.4)
        let maxJumpY = max(900, visibleWorldRect.height * 1.4)
        let dx = max(-maxJumpX, min(maxJumpX, smoothedWorldVelocity.dx * 1.25))
        let dy = max(-maxJumpY, min(maxJumpY, smoothedWorldVelocity.dy * 1.25))
        return CGVector(dx: dx, dy: dy)
    }

    private func prefetchAroundCurrentViewport(force: Bool) {
        guard !layout.cards.isEmpty else { return }
        let now = Date()
        if !force, now.timeIntervalSince(lastPrefetchTime) < 0.085 {
            return
        }
        lastPrefetchTime = now

        let rect = lastVisibleWorldRect.width > 10
            ? lastVisibleWorldRect
            : CGRect(x: -500, y: -400, width: 1000, height: 800)
        let lookahead = predictiveLookaheadVector(for: rect)
        let halo = max(720, max(rect.width, rect.height) * 0.95)
        let predictedCards = layout.predictivePrefetchCards(
            visibleWorldRect: rect,
            lookaheadOffset: lookahead,
            halo: halo,
            limit: 32
        )
        let renderedCardWidth = layout.cardWidth * lastCameraScale
        let urls = predictedCards.map { $0.pin.imageURL(forRenderedWidth: renderedCardWidth) }
        let maxPixels = renderedCardWidth > 420 ? 1200 : 720
        PinterestImageCache.shared.prefetchPrioritized(urls, maxPixelSize: maxPixels, replacePending: true)
    }

    public func loadNextPage() async {
        guard isSignedIn, !isLoadingFeed, !isLoadingMore, hasMore, let bookmark = nextBookmark else { return }
        let gen = feedGeneration
        isLoadingMore = true
        defer {
            if gen == feedGeneration {
                isLoadingMore = false
            }
        }

        do {
            let page = try await PinterestSessionBridge.shared.fetchFeed(
                source: feedSource,
                bookmark: bookmark,
                pageSize: 32
            )
            guard gen == feedGeneration else { return }
            let added = layout.append(page.pins)
            nextBookmark = page.bookmark
            hasMore = page.hasMore && page.bookmark != nil && !page.pins.isEmpty
            if !added.isEmpty {
                layoutRevision &+= 1
                prefetchAroundCurrentViewport(force: true)
            }
        } catch let sessionError as PinterestSessionError {
            guard gen == feedGeneration else { return }
            if case .sessionExpired = sessionError {
                needsReauthentication = true
                errorMessage = sessionError.localizedDescription
            }
        } catch {
            // Silently ignore transient edge-pagination errors so panning stays uninterrupted.
        }
    }

    /// Closes the floating detail window and re-centers the infinite 2D space around pins similar to `pin`.
    public func exploreSimilarInInfiniteSpace(_ pin: PinterestPin) async {
        closePinDetail()
        await switchSource(.similar(anchorPin: pin))
    }

    // MARK: - Shopping-Cart Collection Tray

    public func isInTray(_ pinID: String) -> Bool {
        trayPins.contains(where: { $0.id == pinID })
    }

    /// Toggles `pin` in/out of the shopping-cart tray. Returns `true` if newly added, `false` if removed.
    @discardableResult
    public func toggleTray(_ pin: PinterestPin) -> Bool {
        if let idx = trayPins.firstIndex(where: { $0.id == pin.id }) {
            trayPins.remove(at: idx)
            selectedTrayPinIDs.remove(pin.id)
            persistTrayIfNeeded()
            return false
        } else {
            trayPins.insert(pin, at: 0)
            selectedTrayPinIDs.insert(pin.id)
            persistTrayIfNeeded()
            return true
        }
    }

    public func addToTray(_ pin: PinterestPin) {
        guard !isInTray(pin.id) else { return }
        trayPins.insert(pin, at: 0)
        selectedTrayPinIDs.insert(pin.id)
        persistTrayIfNeeded()
    }

    public func removeFromTray(_ pinID: String) {
        trayPins.removeAll { $0.id == pinID }
        selectedTrayPinIDs.remove(pinID)
        persistTrayIfNeeded()
    }

    public func toggleTraySelection(_ pinID: String) {
        if selectedTrayPinIDs.contains(pinID) {
            selectedTrayPinIDs.remove(pinID)
        } else {
            selectedTrayPinIDs.insert(pinID)
        }
    }

    public func selectAllTray() {
        selectedTrayPinIDs = Set(trayPins.map(\.id))
    }

    public func deselectAllTray() {
        selectedTrayPinIDs.removeAll()
    }

    @discardableResult
    public func removeSelectedFromTray() -> Int {
        let toRemove = selectedTrayPinIDs
        guard !toRemove.isEmpty else { return 0 }
        let before = trayPins.count
        trayPins.removeAll { toRemove.contains($0.id) }
        selectedTrayPinIDs.removeAll()
        persistTrayIfNeeded()
        return before - trayPins.count
    }

    public func clearTray() {
        trayPins.removeAll()
        selectedTrayPinIDs.removeAll()
        persistTrayIfNeeded()
    }

    /// Batch-imports either the user's checked subset in the tray (default) or an explicit pin list.
    public func importTrayPins(
        _ explicitPins: [PinterestPin]? = nil,
        into engine: any CharkleEngineProtocol,
        targetFolderID: UUID?,
        extraTags: [String] = [],
        removeImportedFromTray: Bool = true
    ) async -> PinterestBatchImportReport {
        let targets = explicitPins ?? selectedTrayPins
        guard !targets.isEmpty else {
            return PinterestBatchImportReport(importedAssets: [], importedPinIDs: [], failedPinIDs: [], skippedDuplicatePinIDs: [])
        }
        guard !isImportingTray else {
            return PinterestBatchImportReport(importedAssets: [], importedPinIDs: [], failedPinIDs: [], skippedDuplicatePinIDs: [])
        }

        isImportingTray = true
        importProgress = (0, targets.count)
        defer {
            isImportingTray = false
            importProgress = nil
        }

        let report = await PinterestImportService.importPins(
            targets,
            into: engine,
            targetFolderID: targetFolderID,
            extraTags: extraTags,
            skipDuplicates: true,
            onProgress: { [weak self] completed, total in
                let target = self
                Task { @MainActor in
                    target?.importProgress = (completed, total)
                }
            }
        )

        importedPinIDs.formUnion(report.importedPinIDs)
        importedPinIDs.formUnion(report.skippedDuplicatePinIDs)

        if removeImportedFromTray {
            let doneIDs = report.importedPinIDs.union(report.skippedDuplicatePinIDs)
            trayPins.removeAll { doneIDs.contains($0.id) }
            selectedTrayPinIDs.subtract(doneIDs)
            persistTrayIfNeeded()
        }
        return report
    }

    /// Immediately imports a single pin (e.g. from the floating Pin detail sheet) without needing the tray.
    public func importSinglePinImmediately(
        _ pin: PinterestPin,
        into engine: any CharkleEngineProtocol,
        targetFolderID: UUID? = nil
    ) async -> PinterestBatchImportReport {
        let report = await PinterestImportService.importPins(
            [pin],
            into: engine,
            targetFolderID: targetFolderID,
            extraTags: [],
            skipDuplicates: true
        )
        importedPinIDs.formUnion(report.importedPinIDs)
        importedPinIDs.formUnion(report.skippedDuplicatePinIDs)
        if !report.importedPinIDs.isEmpty || !report.skippedDuplicatePinIDs.isEmpty {
            removeFromTray(pin.id)
        }
        return report
    }

    // MARK: - Floating Pin Detail Overlay + Similar Pins

    /// Opens the floating Pin detail window (callable from the infinite space, similar pins, OR the Tray!).
    public func openPinDetail(_ pin: PinterestPin, resetStack: Bool = false) {
        if resetStack {
            detailStack = [pin]
        } else if detailStack.last?.id == pin.id {
            // Already displaying this exact pin; keep current stack.
        } else {
            detailStack.append(pin)
        }

        if let cached = detailCache[pin.id] {
            replaceTopDetailPin(with: cached.pin)
            detailSimilarPins = cached.similarPins
            detailSimilarBookmark = cached.similarBookmark
            detailHasMoreSimilar = cached.similarBookmark != nil
            isLoadingDetail = false
            return
        }

        detailSimilarPins = []
        detailSimilarBookmark = nil
        detailHasMoreSimilar = false
        loadActivePinDetail(for: pin)
    }

    public func popPinDetail() {
        guard detailStack.count > 1 else {
            closePinDetail()
            return
        }
        detailStack.removeLast()
        guard let top = detailStack.last else { return }
        if let cached = detailCache[top.id] {
            replaceTopDetailPin(with: cached.pin)
            detailSimilarPins = cached.similarPins
            detailSimilarBookmark = cached.similarBookmark
            detailHasMoreSimilar = cached.similarBookmark != nil
            isLoadingDetail = false
        } else {
            detailSimilarPins = []
            detailSimilarBookmark = nil
            detailHasMoreSimilar = false
            loadActivePinDetail(for: top)
        }
    }

    public func closePinDetail() {
        detailGeneration &+= 1
        detailStack.removeAll()
        detailSimilarPins.removeAll()
        detailSimilarBookmark = nil
        detailHasMoreSimilar = false
        isLoadingDetail = false
        isLoadingMoreSimilar = false
    }

    public func loadMoreSimilarInDetail() async {
        guard let currentPin = activeDetailPin,
              !isLoadingDetail,
              !isLoadingMoreSimilar,
              let bookmark = detailSimilarBookmark else {
            return
        }
        let gen = detailGeneration
        isLoadingMoreSimilar = true
        defer {
            if gen == detailGeneration {
                isLoadingMoreSimilar = false
            }
        }

        if let page = try? await PinterestSessionBridge.shared.fetchSimilarPins(
            for: currentPin,
            bookmark: bookmark,
            pageSize: 24
        ), gen == detailGeneration {
            var seen = Set(detailSimilarPins.map(\.id))
            seen.insert(currentPin.id)
            let fresh = page.pins.filter { seen.insert($0.id).inserted }
            detailSimilarPins.append(contentsOf: fresh)
            detailSimilarBookmark = page.bookmark
            detailHasMoreSimilar = page.hasMore && page.bookmark != nil && !fresh.isEmpty

            if let existing = detailCache[currentPin.id] {
                detailCache[currentPin.id] = PinterestPinDetailResult(
                    pin: existing.pin,
                    similarPins: detailSimilarPins,
                    similarBookmark: detailSimilarBookmark
                )
            }
        }
    }

    private func loadActivePinDetail(for pin: PinterestPin) {
        detailGeneration &+= 1
        let gen = detailGeneration
        isLoadingDetail = true

        Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.detailGeneration == gen {
                    self.isLoadingDetail = false
                }
            }
            do {
                let result = try await PinterestSessionBridge.shared.fetchPinDetailAndSimilar(for: pin)
                guard self.detailGeneration == gen else { return }
                self.detailCache[pin.id] = result
                self.replaceTopDetailPin(with: result.pin)
                // Also upgrade the cached tray entry if present so tray displays enriched title/metadata.
                if let idx = self.trayPins.firstIndex(where: { $0.id == result.pin.id }) {
                    self.trayPins[idx] = self.trayPins[idx].merged(with: result.pin)
                    self.persistTrayIfNeeded()
                }
                self.detailSimilarPins = result.similarPins
                self.detailSimilarBookmark = result.similarBookmark
                self.detailHasMoreSimilar = result.similarBookmark != nil && !result.similarPins.isEmpty
                PinterestImageCache.shared.prefetch(result.similarPins.prefix(12).map(\.previewURL), maxPixelSize: 640)
            } catch {
                // Keep showing the pin's already-available preview & metadata cleanly.
            }
        }
    }

    private func replaceTopDetailPin(with updated: PinterestPin) {
        guard !detailStack.isEmpty, detailStack[detailStack.count - 1].id == updated.id else { return }
        detailStack[detailStack.count - 1] = updated
    }

    private func prefetchInitialImages(from cards: [PinterestSpatialCard]) {
        PinterestImageCache.shared.prefetch(cards.prefix(14).map { $0.pin.previewURL }, maxPixelSize: 640)
    }

    private func persistTrayIfNeeded() {
        guard persistTray else { return }
        PinterestTrayStorage.save(trayPins)
    }
}
