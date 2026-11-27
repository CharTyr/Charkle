import AppKit
import CharkleCanvas
import CharkleCore
import Foundation
import os

private nonisolated let boardStoreLogger = Logger(subsystem: "com.charkle.app", category: "MoodboardStore")

/// Domain store for Moodboards: board list, active `MoodboardDocument`, full value-type Undo/Redo stack,
/// debounced persistence, candidate swap pool, rapid 4-entry generator, and 2× Retina export.
@Observable
public final class MoodboardStore {
    public let engine: any CharkleEngineProtocol

    public var boards: [MoodboardSummary] = []
    public var activeBoard: MoodboardDocument?
    public var candidatePool: [ScoredAsset] = []
    public var swappingNodeID: UUID?

    public var undoStack: [MoodboardDocument] = []
    public var redoStack: [MoodboardDocument] = []

    public var proposal: MoodboardProposal?
    public var agentTrace: [MoodboardAgentStep] = []
    public var isGeneratingProposal: Bool = false
    public var isRefiningActiveBoard: Bool = false
    public var activeBoardAgentTrace: [MoodboardAgentStep] = []
    public var activeBoardLastSummary: String?
    public var isSaving: Bool = false
    public var lastError: String?

    @ObservationIgnored private var saveDebounceTask: Task<Void, Never>?
    @ObservationIgnored private var pendingSaveDocument: MoodboardDocument?
    @ObservationIgnored private var viewportSaveTask: Task<Void, Never>?
    @ObservationIgnored private var latestViewportOverride: (boardID: UUID, center: BoardPoint, zoom: Double)?
    @ObservationIgnored private var openRequestGeneration: UInt64 = 0
    @ObservationIgnored private var curateRequestGeneration: UInt64 = 0
    @ObservationIgnored private var candidateRequestGeneration: UInt64 = 0
    @ObservationIgnored private var candidateRefreshTask: Task<Void, Never>?
    private let maxUndoDepth: Int = 45

    public init(engine: any CharkleEngineProtocol) {
        self.engine = engine
    }

    isolated deinit {
        saveDebounceTask?.cancel()
        viewportSaveTask?.cancel()
        candidateRefreshTask?.cancel()
    }

    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }

    public func refreshBoards() async {
        do {
            let fetched = try await engine.fetchBoards()
            if fetched != boards {
                boards = fetched
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Collects any unsaved document or dirty viewport override and clears pending debounce timers.
    private func consumePendingDocumentForSave() -> MoodboardDocument? {
        saveDebounceTask?.cancel()
        saveDebounceTask = nil
        viewportSaveTask?.cancel()
        viewportSaveTask = nil

        var docToSave = pendingSaveDocument
        pendingSaveDocument = nil

        if let override = latestViewportOverride {
            if var pending = docToSave, pending.id == override.boardID {
                pending.viewportCenter = override.center
                pending.viewportZoom = override.zoom
                docToSave = pending
            } else if docToSave == nil,
                      var current = activeBoard,
                      current.id == override.boardID,
                      (current.viewportCenter != override.center || abs(current.viewportZoom - override.zoom) > 0.0001) {
                current.viewportCenter = override.center
                current.viewportZoom = override.zoom
                docToSave = current
            }
        }
        return docToSave
    }

    /// Awaits persistence of any debounced board edit or viewport change so rapid board switches
    /// or reloads never drop the user's latest mutations.
    @MainActor
    public func flushPendingSave() async {
        guard let doc = consumePendingDocumentForSave() else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            _ = try await engine.saveBoard(doc)
        } catch {
            lastError = error.localizedDescription
            boardStoreLogger.error("flushPendingSave failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Cancels pending debounce timers and dispatches an immediate save flush.
    /// When `waitForCompletion` is `true` (default, used by `applicationWillTerminate`), waits up to
    /// 1.5s for SQLite persistence to finish before process teardown without re-entering MainActor.
    @MainActor
    public func triggerImmediateSaveFlush(waitForCompletion: Bool = true) {
        guard let doc = consumePendingDocumentForSave() else { return }
        let targetEngine = engine
        if waitForCompletion {
            let semaphore = DispatchSemaphore(value: 0)
            Task.detached(priority: .userInitiated) {
                defer { semaphore.signal() }
                do {
                    _ = try await targetEngine.saveBoard(doc)
                } catch {
                    boardStoreLogger.error("triggerImmediateSaveFlush failed: \(error.localizedDescription, privacy: .public)")
                }
            }
            _ = semaphore.wait(timeout: .now() + 1.5)
        } else {
            Task.detached(priority: .userInitiated) {
                do {
                    _ = try await targetEngine.saveBoard(doc)
                } catch {
                    boardStoreLogger.error("triggerImmediateSaveFlush failed: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }

    /// Releases the loaded board document, undo/redo history, and candidate pool while retaining tiny
    /// board summaries so Notch Shelf "Active Moodboard" capture remains functional in Minimal Mode.
    public func enterMinimalCaptureMode() {
        triggerImmediateSaveFlush(waitForCompletion: false)
        latestViewportOverride = nil
        openRequestGeneration &+= 1
        activeBoard = nil
        candidatePool = []
        swappingNodeID = nil
        undoStack = []
        redoStack = []
        proposal = nil
        agentTrace = []
        activeBoardAgentTrace = []
        activeBoardLastSummary = nil
    }

    public func openBoard(id: UUID) async {
        await flushPendingSave()
        latestViewportOverride = nil
        openRequestGeneration &+= 1
        let requestGen = openRequestGeneration
        do {
            if var doc = try await engine.fetchBoard(id: id) {
                guard openRequestGeneration == requestGen else { return }
                // Silently migrate legacy/MCP `.autoEditorial` boards into `.freeform` BEFORE
                // publishing `activeBoard` so opening never pushes a bogus Undo entry.
                if doc.mode.isAutoEditorial {
                    var assetsByID: [UUID: AssetRecord] = [:]
                    for refID in Set(doc.referencedAssetIDs) {
                        if let asset = try? await engine.fetchAsset(id: refID) {
                            assetsByID[refID] = asset
                        }
                    }
                    guard openRequestGeneration == requestGen else { return }
                    let frozen = EditorialLayoutSolver.freezeIntoFreeform(
                        document: doc,
                        containerWidth: 1080,
                        assetsByID: assetsByID
                    )
                    doc = (try? await engine.saveBoard(frozen)) ?? frozen
                    guard openRequestGeneration == requestGen else { return }
                }
                activeBoard = doc
                undoStack.removeAll()
                redoStack.removeAll()
                swappingNodeID = nil
                activeBoardAgentTrace = []
                activeBoardLastSummary = nil
                await refreshCandidates(for: nil)
            }
        } catch {
            guard openRequestGeneration == requestGen else { return }
            lastError = error.localizedDescription
        }
    }

    public func reloadActiveBoardIfNeeded(id: UUID) async {
        guard activeBoard?.id == id else { return }
        if pendingSaveDocument?.id == id {
            await flushPendingSave()
        }
        guard activeBoard?.id == id else { return }
        if let fresh = try? await engine.fetchBoard(id: id) {
            guard activeBoard?.id == id, pendingSaveDocument == nil else { return }
            saveDebounceTask?.cancel()
            saveDebounceTask = nil
            viewportSaveTask?.cancel()
            viewportSaveTask = nil
            latestViewportOverride = nil
            activeBoard = fresh
            await refreshBoards()
        }
    }

    @discardableResult
    public func createBlankBoard(title: String = "未命名情绪板") async -> MoodboardDocument? {
        await flushPendingSave()
        let doc = MoodboardDocument(
            title: title,
            subtitle: "",
            mode: .freeform
        )
        do {
            let saved = try await engine.saveBoard(doc)
            openRequestGeneration &+= 1
            activeBoard = saved
            latestViewportOverride = nil
            undoStack.removeAll()
            redoStack.removeAll()
            await refreshBoards()
            await refreshCandidates(for: nil)
            return saved
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    @discardableResult
    public func createBoardFromSelection(assetIDs: [UUID], title: String = "精选情绪板") async -> MoodboardDocument? {
        guard !assetIDs.isEmpty else { return await createBlankBoard(title: title) }
        await flushPendingSave()
        do {
            let prop = try await engine.proposeMoodboard(
                seed: .manualSelection(assetIDs),
                primaryCount: min(max(assetIDs.count, 12), 24),
                candidateCount: 30
            )
            var doc = prop.draftDocument
            doc.title = title
            if doc.mode.isAutoEditorial {
                let assetsMap = Dictionary(uniqueKeysWithValues: prop.primaryMatches.map { ($0.asset.id, $0.asset) })
                doc = EditorialLayoutSolver.freezeIntoFreeform(
                    document: doc,
                    containerWidth: 1080,
                    assetsByID: assetsMap
                )
            }
            let saved = try await engine.saveBoard(doc)
            openRequestGeneration &+= 1
            activeBoard = saved
            latestViewportOverride = nil
            candidatePool = prop.candidatePool
            undoStack.removeAll()
            redoStack.removeAll()
            await refreshBoards()
            return saved
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    public func deleteBoard(id: UUID) async {
        // Cancel any pending debounced save/viewport write for this board before deletion so
        // it never races with the tombstone and emits spurious fileNotFound errors.
        if pendingSaveDocument?.id == id || activeBoard?.id == id {
            saveDebounceTask?.cancel()
            saveDebounceTask = nil
            if pendingSaveDocument?.id == id {
                pendingSaveDocument = nil
            }
        }
        if latestViewportOverride?.boardID == id || activeBoard?.id == id {
            viewportSaveTask?.cancel()
            viewportSaveTask = nil
            if latestViewportOverride?.boardID == id {
                latestViewportOverride = nil
            }
        }
        do {
            try await engine.deleteBoard(id: id)
            if activeBoard?.id == id {
                openRequestGeneration &+= 1
                activeBoard = nil
                undoStack.removeAll()
                redoStack.removeAll()
                candidatePool.removeAll()
                swappingNodeID = nil
                activeBoardAgentTrace = []
                activeBoardLastSummary = nil
            }
            await refreshBoards()
        } catch {
            lastError = error.localizedDescription
        }
    }

    public func togglePinnedOffline(id: UUID) async {
        let currentPinned: Bool
        if activeBoard?.id == id {
            currentPinned = activeBoard?.pinnedOffline ?? false
        } else {
            currentPinned = boards.first(where: { $0.id == id })?.pinnedOffline ?? false
        }
        let target = !currentPinned
        do {
            try await engine.setBoardPinnedOffline(id: id, pinned: target)
            if activeBoard?.id == id {
                activeBoard?.pinnedOffline = target
            }
            await refreshBoards()
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Persists a moodboard title/subtitle edit safely whether `id` is still active or the user
    /// has already switched to another board (avoiding cross-board overwrites via `commitMutation`).
    public func updateBoardHeader(id: UUID, title: String, subtitle: String) async {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if var active = activeBoard, active.id == id {
            let nextTitle = trimmed.isEmpty ? active.title : trimmed
            guard nextTitle != active.title || subtitle != active.subtitle else { return }
            active.title = nextTitle
            active.subtitle = subtitle
            commitMutation(active)
            return
        }
        do {
            guard var doc = try await engine.fetchBoard(id: id) else { return }
            let nextTitle = trimmed.isEmpty ? doc.title : trimmed
            guard nextTitle != doc.title || subtitle != doc.subtitle else { return }
            doc.title = nextTitle
            doc.subtitle = subtitle
            doc.updatedAt = Date()
            let saved = try await engine.saveBoard(doc)
            await syncSavedBoardSummaryIfNeeded(for: saved)
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: - Value-Type Undo / Redo & Debounced Save

    public func commitMutation(_ nextDoc: MoodboardDocument, recordUndo: Bool = true) {
        // Guard against stale async flushes (e.g. debounced note/group edits firing onDisappear
        // after switching to another board) overwriting the newly active moodboard.
        guard let currentActive = activeBoard, currentActive.id == nextDoc.id else { return }
        viewportSaveTask?.cancel()
        viewportSaveTask = nil
        if recordUndo, currentActive != nextDoc {
            undoStack.append(currentActive)
            if undoStack.count > maxUndoDepth {
                undoStack.removeFirst(undoStack.count - maxUndoDepth)
            }
            redoStack.removeAll()
        }
        var stamped = nextDoc
        if let override = latestViewportOverride,
           override.boardID == nextDoc.id,
           nextDoc.viewportCenter == currentActive.viewportCenter,
           nextDoc.viewportZoom == currentActive.viewportZoom {
            stamped.viewportCenter = override.center
            stamped.viewportZoom = override.zoom
        } else {
            let safeCenter = BoardPoint(
                x: nextDoc.viewportCenter.x.isFinite ? nextDoc.viewportCenter.x : 0,
                y: nextDoc.viewportCenter.y.isFinite ? nextDoc.viewportCenter.y : 0
            )
            let safeZoom = (nextDoc.viewportZoom.isFinite && nextDoc.viewportZoom > 0) ? nextDoc.viewportZoom : 1.0
            stamped.viewportCenter = safeCenter
            stamped.viewportZoom = safeZoom
            latestViewportOverride = (nextDoc.id, safeCenter, safeZoom)
        }
        stamped.updatedAt = Date()
        activeBoard = stamped
        pendingSaveDocument = stamped
        scheduleSave(stamped)
    }

    /// Persists freeform camera pan/zoom quietly to disk without pushing onto the Undo stack
    /// or re-publishing `@Observable activeBoard` (keeps 120fps panning hitch-free).
    public func persistViewportQuietly(center: BoardPoint, zoom: Double) {
        guard let currentID = activeBoard?.id else { return }
        guard center.x.isFinite, center.y.isFinite, zoom.isFinite, zoom > 0 else { return }
        let safeZoom = max(0.2, min(3.0, zoom))
        latestViewportOverride = (currentID, center, safeZoom)
        viewportSaveTask?.cancel()
        viewportSaveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled, let self, var snapshot = self.activeBoard, snapshot.id == currentID else { return }
            // Avoid clobbering a pending document edit save; it already merges latestViewportOverride.
            guard self.pendingSaveDocument == nil else { return }
            snapshot.viewportCenter = center
            snapshot.viewportZoom = safeZoom
            do {
                _ = try await self.engine.saveBoard(snapshot)
            } catch {
                boardStoreLogger.error("persistViewportQuietly failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    public func undo() {
        guard var previous = undoStack.popLast(), let current = activeBoard, previous.id == current.id else { return }
        viewportSaveTask?.cancel()
        viewportSaveTask = nil
        redoStack.append(current)
        if let override = latestViewportOverride, override.boardID == previous.id {
            previous.viewportCenter = override.center
            previous.viewportZoom = override.zoom
        }
        previous.updatedAt = Date()
        activeBoard = previous
        pendingSaveDocument = previous
        scheduleSave(previous)
    }

    public func redo() {
        guard var next = redoStack.popLast(), let current = activeBoard, next.id == current.id else { return }
        viewportSaveTask?.cancel()
        viewportSaveTask = nil
        undoStack.append(current)
        if let override = latestViewportOverride, override.boardID == next.id {
            next.viewportCenter = override.center
            next.viewportZoom = override.zoom
        }
        next.updatedAt = Date()
        activeBoard = next
        pendingSaveDocument = next
        scheduleSave(next)
    }

    private func scheduleSave(_ doc: MoodboardDocument) {
        saveDebounceTask?.cancel()
        saveDebounceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(220))
            guard !Task.isCancelled, let self else { return }
            var toSave = self.pendingSaveDocument ?? doc
            if let override = self.latestViewportOverride, override.boardID == toSave.id {
                toSave.viewportCenter = override.center
                toSave.viewportZoom = override.zoom
            }
            self.pendingSaveDocument = nil
            self.isSaving = true
            defer { self.isSaving = false }
            do {
                _ = try await self.engine.saveBoard(toSave)
                await self.syncSavedBoardSummaryIfNeeded(for: toSave)
            } catch {
                self.lastError = error.localizedDescription
                boardStoreLogger.error("saveBoard failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Updates the matching `MoodboardSummary` in-place when visible summary fields changed,
    /// avoiding a full `refreshBoards()` SQLite query & Sidebar invalidation on every 220ms node drag.
    private func syncSavedBoardSummaryIfNeeded(for doc: MoodboardDocument) async {
        guard let idx = boards.firstIndex(where: { $0.id == doc.id }) else {
            await refreshBoards()
            return
        }
        let existing = boards[idx]
        let previewIDs = Array(doc.referencedAssetIDs.prefix(4))
        let paletteHexes = Array(doc.extractedPalette.prefix(6).map(\.hex))
        let itemCount = doc.nodes.count
        let visibleChanged = existing.title != doc.title
            || existing.subtitle != doc.subtitle
            || existing.mode != doc.mode
            || existing.itemCount != itemCount
            || existing.previewAssetIDs != previewIDs
            || existing.paletteHexes != paletteHexes
            || existing.pinnedOffline != doc.pinnedOffline
        guard visibleChanged else { return }
        var updated = existing
        updated.title = doc.title
        updated.subtitle = doc.subtitle
        updated.mode = doc.mode
        updated.itemCount = itemCount
        updated.previewAssetIDs = previewIDs
        updated.paletteHexes = paletteHexes
        updated.pinnedOffline = doc.pinnedOffline
        updated.updatedAt = doc.updatedAt
        boards[idx] = updated
    }

    // MARK: - Candidate Swap Pool & Board Composition

    public func selectSwapTarget(_ nodeID: UUID?) async {
        swappingNodeID = nodeID
        await refreshCandidates(for: nodeID)
    }

    public func refreshCandidates(for nodeID: UUID?) async {
        candidateRefreshTask?.cancel()
        candidateRequestGeneration &+= 1
        let gen = candidateRequestGeneration
        guard let board = activeBoard else {
            if !candidatePool.isEmpty {
                candidatePool = []
            }
            return
        }
        let boardID = board.id
        let boardAssetIDs = board.referencedAssetIDs
        let boardAssetSet = Set(boardAssetIDs)
        let candidateAssetIDs = board.candidateAssetIDs
        let targetAssetID: UUID? = {
            if let nodeID, let node = board.nodes.first(where: { $0.id == nodeID }) {
                return node.referencedAssetID
            }
            return boardAssetIDs.first
        }()
        let engine = self.engine

        let task = Task<Void, Never> { @MainActor [weak self] in
            guard let self else { return }
            // When browsing the board generally (not actively swapping a specific card) and the AI curator
            // saved a curated candidate pool on the document, preserve those curated candidates first
            // instead of overwriting them with loose fallback matches.
            if nodeID == nil, !candidateAssetIDs.isEmpty {
                var curated: [ScoredAsset] = []
                for cid in candidateAssetIDs where !boardAssetSet.contains(cid) {
                    if Task.isCancelled || self.candidateRequestGeneration != gen { return }
                    if let asset = try? await engine.fetchAsset(id: cid), !asset.isTrashed {
                        curated.append(ScoredAsset(asset: asset, score: 0.78, matchReasons: ["策展备选"]))
                    }
                }
                guard !Task.isCancelled,
                      self.candidateRequestGeneration == gen,
                      self.activeBoard?.id == boardID else { return }
                if !curated.isEmpty {
                    if self.candidatePool != curated {
                        self.candidatePool = curated
                    }
                    return
                }
            }

            guard let anchorID = targetAssetID else {
                // Board empty: pull recent library items as candidates
                if let recent = try? await engine.fetchAssets(matching: FilterCriteria(sortBy: .newest)) {
                    guard !Task.isCancelled,
                          self.candidateRequestGeneration == gen,
                          self.activeBoard?.id == boardID else { return }
                    let nextPool = recent.prefix(24).map {
                        ScoredAsset(asset: $0, score: 0.7, matchReasons: ["素材库推荐"])
                    }
                    if self.candidatePool != nextPool {
                        self.candidatePool = nextPool
                    }
                }
                return
            }

            do {
                let fetched = try await engine.replacementCandidates(
                    for: anchorID,
                    excluding: boardAssetSet,
                    boardContext: boardAssetIDs,
                    limit: 32
                )
                guard !Task.isCancelled,
                      self.candidateRequestGeneration == gen,
                      self.activeBoard?.id == boardID else { return }
                if self.candidatePool != fetched {
                    self.candidatePool = fetched
                }
            } catch {
                if !Task.isCancelled && self.candidateRequestGeneration == gen {
                    self.lastError = error.localizedDescription
                }
            }
        }
        candidateRefreshTask = task
        await task.value
    }

    public func swapNode(nodeID: UUID, with asset: AssetRecord) async {
        guard var board = activeBoard,
              let idx = board.nodes.firstIndex(where: { $0.id == nodeID }),
              case .assetRef(_, _, let weight, _) = board.nodes[idx].kind else { return }

        // Reset `crop` to nil so a previous image's detail crop never clips the replacement asset.
        board.nodes[idx].kind = .assetRef(
            assetID: asset.id,
            crop: nil,
            weight: weight,
            autoplayLoop: asset.mediaKind == .animatedImage || asset.mediaKind == .video
        )
        board.nodes[idx].updatedAt = Date()
        commitMutation(board)
        swappingNodeID = nil
        await syncBoardPalette()
        await refreshCandidates(for: nil)
    }

    public func appendAssets(_ assets: [AssetRecord], at worldPoint: BoardPoint? = nil) async {
        guard var board = activeBoard, !assets.isEmpty else { return }
        let existingMaxZ = board.nodes.map(\.zIndex).max() ?? 0

        for (offset, asset) in assets.enumerated() {
            let ratio = max(0.65, min(1.85, asset.aspectRatio))
            let width = 240.0
            let height = width / ratio
            let x: Double
            let y: Double
            if let pt = worldPoint {
                x = pt.x - width * 0.5 + Double(offset) * 24
                y = pt.y - height * 0.5 + Double(offset) * 24
            } else {
                let idx = board.nodes.count
                x = Double((idx % 4) * 260) + 40
                y = Double((idx / 4) * 240) + 40
            }
            let node = BoardNode(
                kind: .assetRef(
                    assetID: asset.id,
                    crop: nil,
                    weight: 1,
                    autoplayLoop: asset.mediaKind == .animatedImage || asset.mediaKind == .video
                ),
                frame: BoardRect(x: x, y: y, width: width, height: height),
                zIndex: existingMaxZ + offset + 1,
                editorialOrder: board.nodes.count
            )
            board.nodes.append(node)
        }

        commitMutation(board)
        await syncBoardPalette()
        await refreshCandidates(for: swappingNodeID)
    }

    public func addAssetsToSpecificBoard(boardID: UUID, assets: [AssetRecord]) async {
        guard !assets.isEmpty else { return }
        if activeBoard?.id == boardID {
            await appendAssets(assets, at: nil)
            return
        }
        guard var doc = try? await engine.fetchBoard(id: boardID) else { return }
        let baseZ = doc.nodes.map(\.zIndex).max() ?? 0
        for (idx, asset) in assets.enumerated() {
            let n = doc.nodes.count
            let ratio = max(0.65, min(1.85, asset.aspectRatio))
            let width = 240.0
            let height = width / ratio
            let node = BoardNode(
                kind: .assetRef(
                    assetID: asset.id,
                    crop: nil,
                    weight: 1,
                    autoplayLoop: asset.mediaKind == .animatedImage || asset.mediaKind == .video
                ),
                frame: BoardRect(x: Double((n % 4) * 260) + 40, y: Double((n / 4) * 260) + 40, width: width, height: height),
                zIndex: baseZ + idx + 1,
                editorialOrder: n
            )
            doc.nodes.append(node)
        }
        if let palette = try? await engine.extractBoardPalette(assetIDs: doc.referencedAssetIDs, count: 6), !palette.isEmpty {
            doc.extractedPalette = palette
        }
        _ = try? await engine.saveBoard(doc)
        await refreshBoards()
    }

    public func syncBoardPalette() async {
        guard let initialBoard = activeBoard else { return }
        let targetBoardID = initialBoard.id
        let ids = initialBoard.referencedAssetIDs
        guard !ids.isEmpty else { return }
        if let palette = try? await engine.extractBoardPalette(assetIDs: ids, count: 6), !palette.isEmpty {
            // Re-read live `activeBoard` after `await` so concurrent edits or board switches are never clobbered.
            guard var latestBoard = activeBoard, latestBoard.id == targetBoardID else { return }
            latestBoard.extractedPalette = palette
            for idx in latestBoard.nodes.indices {
                if case .paletteStrip(_, let autoSync) = latestBoard.nodes[idx].kind, autoSync {
                    latestBoard.nodes[idx].kind = .paletteStrip(colors: palette, autoSyncWithBoard: true)
                }
            }
            commitMutation(latestBoard, recordUndo: false)
        }
    }

    // MARK: - Moodboard Curator Agent Harness (Draft Workbench + In-Canvas Refinement)

    public func generateProposal(
        seed: MoodboardSeed,
        primaryCount: Int = 16,
        candidateCount: Int = 28
    ) async {
        isGeneratingProposal = true
        defer { isGeneratingProposal = false }
        do {
            proposal = try await engine.proposeMoodboard(
                seed: seed,
                primaryCount: primaryCount,
                candidateCount: candidateCount
            )
        } catch {
            lastError = error.localizedDescription
        }
    }

    public func curateProposal(_ request: MoodboardCurationRequest) async {
        curateRequestGeneration &+= 1
        let requestGen = curateRequestGeneration
        isGeneratingProposal = true
        lastError = nil
        agentTrace = []
        defer {
            if curateRequestGeneration == requestGen {
                isGeneratingProposal = false
            }
        }
        do {
            let result = try await engine.curateMoodboard(request) { [weak self] step in
                await MainActor.run {
                    guard let self, self.curateRequestGeneration == requestGen else { return }
                    if let idx = self.agentTrace.firstIndex(where: { $0.id == step.id }) {
                        self.agentTrace[idx] = step
                    } else if let idx = self.agentTrace.lastIndex(where: { $0.phase == step.phase && $0.status == .running }) {
                        self.agentTrace[idx] = step
                    } else {
                        self.agentTrace.append(step)
                    }
                }
            }
            guard curateRequestGeneration == requestGen else { return }
            proposal = result
            agentTrace = result.agentTrace
        } catch {
            guard curateRequestGeneration == requestGen else { return }
            if !(error is CancellationError) {
                lastError = error.localizedDescription
            }
        }
    }

    /// Runs the Moodboard Curator Agent Harness on the currently open `activeBoard` with full ⌘Z Undo support.
    @discardableResult
    public func refineActiveBoard(
        instruction: String,
        scopeFolderIDs: [UUID] = []
    ) async -> MoodboardProposal? {
        guard !isRefiningActiveBoard, let currentBoard = activeBoard else { return nil }
        let targetBoardID = currentBoard.id
        let trimmed = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        isRefiningActiveBoard = true
        lastError = nil
        activeBoardAgentTrace = []
        defer { isRefiningActiveBoard = false }

        let currentStyle: EditorialStyle
        switch currentBoard.mode {
        case .autoEditorial(let cfg):
            currentStyle = cfg.style
        case .freeform:
            currentStyle = .magazine
        }

        let lockedIDs = currentBoard.nodes.compactMap { node -> UUID? in
            node.isLocked ? node.referencedAssetID : nil
        }

        let req = MoodboardCurationRequest(
            prompt: currentBoard.subtitle.isEmpty ? currentBoard.title : "\(currentBoard.title)：\(currentBoard.subtitle)",
            seedAssetIDs: [],
            scopeFolderIDs: scopeFolderIDs,
            preferredCount: max(8, min(20, max(12, currentBoard.referencedAssetIDs.count + 4))),
            candidateCount: 28,
            layoutStyle: currentStyle,
            useFreeformLayout: true,
            includeCuratorNotes: true,
            lockedAssetIDs: lockedIDs,
            existingBoard: currentBoard,
            refinementInstruction: trimmed
        )

        do {
            let result = try await engine.curateMoodboard(req) { [weak self] step in
                await MainActor.run {
                    guard let self, self.activeBoard?.id == targetBoardID else { return }
                    if let idx = self.activeBoardAgentTrace.firstIndex(where: { $0.id == step.id }) {
                        self.activeBoardAgentTrace[idx] = step
                    } else if let idx = self.activeBoardAgentTrace.lastIndex(where: { $0.phase == step.phase && $0.status == .running }) {
                        self.activeBoardAgentTrace[idx] = step
                    } else {
                        self.activeBoardAgentTrace.append(step)
                    }
                }
            }
            // Verify user hasn't switched away from or closed this board while AI curation ran
            guard activeBoard?.id == targetBoardID else { return result }
            activeBoardAgentTrace = result.agentTrace
            activeBoardLastSummary = result.curatedSummary
            if !result.draftDocument.nodes.isEmpty {
                commitMutation(result.draftDocument, recordUndo: true)
            }
            candidatePool = result.candidatePool
            return result
        } catch {
            if !(error is CancellationError) {
                lastError = error.localizedDescription
            }
            return nil
        }
    }

    @discardableResult
    public func confirmProposal(title: String, subtitle: String = "") async -> MoodboardDocument? {
        guard let prop = proposal else { return nil }
        await flushPendingSave()
        var doc = prop.draftDocument
        let cleaned = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleaned.isEmpty { doc.title = cleaned }
        let cleanSubtitle = subtitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleanSubtitle.isEmpty { doc.subtitle = cleanSubtitle }
        if doc.mode.isAutoEditorial {
            let assetsMap = Dictionary(uniqueKeysWithValues: prop.primaryMatches.map { ($0.asset.id, $0.asset) })
            doc = EditorialLayoutSolver.freezeIntoFreeform(
                document: doc,
                containerWidth: 1080,
                assetsByID: assetsMap
            )
        }
        do {
            let saved = try await engine.saveBoard(doc)
            openRequestGeneration &+= 1
            activeBoard = saved
            latestViewportOverride = nil
            candidatePool = prop.candidatePool
            activeBoardLastSummary = prop.curatedSummary
            proposal = nil
            agentTrace = []
            undoStack.removeAll()
            redoStack.removeAll()
            await refreshBoards()
            return saved
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    // MARK: - Experimental TypeSafe (Jev Box) Grounding & Pinpoint Annotations

    public func smartFocusNode(
        nodeID: UUID,
        assetID: UUID,
        query: String?
    ) async -> Result<VisualRegionResult, Error> {
        let targetBoardID = activeBoard?.id
        do {
            let result = try await engine.locateVisualRegion(assetID: assetID, query: query)
            if result.found, let targetBoardID, var board = activeBoard, board.id == targetBoardID,
               let idx = board.nodes.firstIndex(where: { $0.id == nodeID }),
               case .assetRef(let refAssetID, _, let weight, let autoplay) = board.nodes[idx].kind {
                board.nodes[idx].kind = .assetRef(
                    assetID: refAssetID,
                    crop: result.crop,
                    weight: weight,
                    autoplayLoop: autoplay
                )
                board.nodes[idx].updatedAt = Date()
                commitMutation(board, recordUndo: true)
            }
            return .success(result)
        } catch {
            lastError = error.localizedDescription
            return .failure(error)
        }
    }

    public func visualMatchCropNode(
        nodeID: UUID,
        targetAssetID: UUID,
        referenceAssetID: UUID
    ) async -> Result<VisualRegionResult, Error> {
        let targetBoardID = activeBoard?.id
        do {
            let result = try await engine.locateVisualMatch(referenceAssetID: referenceAssetID, in: targetAssetID)
            if result.found, let targetBoardID, var board = activeBoard, board.id == targetBoardID,
               let idx = board.nodes.firstIndex(where: { $0.id == nodeID }),
               case .assetRef(let refAssetID, _, let weight, let autoplay) = board.nodes[idx].kind {
                board.nodes[idx].kind = .assetRef(
                    assetID: refAssetID,
                    crop: result.crop,
                    weight: weight,
                    autoplayLoop: autoplay
                )
                board.nodes[idx].updatedAt = Date()
                commitMutation(board, recordUndo: true)
            }
            return .success(result)
        } catch {
            lastError = error.localizedDescription
            return .failure(error)
        }
    }

    public func cleanCropNode(
        nodeID: UUID,
        assetID: UUID
    ) async -> Result<CleanBoundsResult, Error> {
        let targetBoardID = activeBoard?.id
        do {
            let result = try await engine.detectCleanContentBounds(assetID: assetID)
            if let recommended = result.recommendedCrop, let targetBoardID, var board = activeBoard, board.id == targetBoardID,
               let idx = board.nodes.firstIndex(where: { $0.id == nodeID }),
               case .assetRef(let refAssetID, _, let weight, let autoplay) = board.nodes[idx].kind {
                board.nodes[idx].kind = .assetRef(
                    assetID: refAssetID,
                    crop: recommended,
                    weight: weight,
                    autoplayLoop: autoplay
                )
                board.nodes[idx].updatedAt = Date()
                commitMutation(board, recordUndo: true)
            }
            return .success(result)
        } catch {
            lastError = error.localizedDescription
            return .failure(error)
        }
    }

    public func pinpointAnnotateNode(
        nodeID: UUID,
        assetID: UUID,
        targetQuery: String,
        noteText: String,
        assetsByID: [UUID: AssetRecord]
    ) async -> Result<VisualRegionResult, Error> {
        let targetBoardID = activeBoard?.id
        do {
            let result = try await engine.locateVisualRegion(assetID: assetID, query: targetQuery)
            guard result.found, let targetBoardID, var board = activeBoard, board.id == targetBoardID else {
                return .success(result)
            }

            if case .autoEditorial = board.mode {
                board = EditorialLayoutSolver.freezeIntoFreeform(
                    document: board,
                    containerWidth: 1080,
                    assetsByID: assetsByID
                )
            }

            guard let targetNode = board.nodes.first(where: { $0.id == nodeID }) else {
                return .success(result)
            }

            let visiblePoint: BoardPoint = {
                if case .assetRef(_, let existingCrop?, _, _) = targetNode.kind, existingCrop != .full {
                    return existingCrop.mappingImagePointToVisible(result.rawBox.centerPoint)
                }
                return result.rawBox.centerPoint
            }()

            let placeOnRight = visiblePoint.x >= 0.48
            let noteWidth = 216.0
            let noteHeight = 124.0
            let gap = 42.0
            let targetWorldY = targetNode.frame.y + targetNode.frame.height * visiblePoint.y
            let noteX = placeOnRight
                ? targetNode.frame.maxX + gap
                : targetNode.frame.minX - gap - noteWidth
            let noteY = targetWorldY - noteHeight * 0.5

            let confNote: String = {
                if let conf = result.confidence, conf.isFinite {
                    let pct = Int((max(0.0, min(1.0, conf)) * 100.0).rounded())
                    return "置信度 \(pct)%"
                }
                return result.source.localizedLabel
            }()
            let body = noteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "已由 \(result.source.localizedLabel) 精准定位（\(confNote)）"
                : noteText.trimmingCharacters(in: .whitespacesAndNewlines)

            let noteNode = BoardNode(
                kind: .note(title: targetQuery, text: body, style: .warm, fontSize: 13.5),
                frame: BoardRect(x: noteX, y: noteY, width: noteWidth, height: noteHeight),
                zIndex: (board.nodes.map(\.zIndex).max() ?? 0) + 1,
                editorialOrder: board.nodes.count
            )
            let connector = BoardConnector(
                fromNodeID: noteNode.id,
                fromAnchor: placeOnRight ? .leading : .trailing,
                toNodeID: nodeID,
                toAnchor: .auto,
                toNormalizedPoint: visiblePoint,
                label: nil,
                colorHex: "#D95D48",
                style: .curved,
                dashed: false
            )
            board.nodes.append(noteNode)
            board.connectors.append(connector)
            commitMutation(board, recordUndo: true)
            return .success(result)
        } catch {
            lastError = error.localizedDescription
            return .failure(error)
        }
    }
}
