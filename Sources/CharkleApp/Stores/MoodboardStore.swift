import AppKit
import CharkleCanvas
import CharkleCore
import Foundation
import os

private let boardStoreLogger = Logger(subsystem: "com.charkle.app", category: "MoodboardStore")

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
    public var isGeneratingProposal: Bool = false
    public var isSaving: Bool = false
    public var lastError: String?

    private var saveDebounceTask: Task<Void, Never>?
    private let maxUndoDepth: Int = 45

    public init(engine: any CharkleEngineProtocol) {
        self.engine = engine
    }

    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }

    public func refreshBoards() async {
        do {
            boards = try await engine.fetchBoards()
        } catch {
            lastError = error.localizedDescription
        }
    }

    public func openBoard(id: UUID) async {
        do {
            if let doc = try await engine.fetchBoard(id: id) {
                activeBoard = doc
                undoStack.removeAll()
                redoStack.removeAll()
                swappingNodeID = nil
                await refreshCandidates(for: nil)
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    public func reloadActiveBoardIfNeeded(id: UUID) async {
        guard activeBoard?.id == id else { return }
        if let fresh = try? await engine.fetchBoard(id: id) {
            activeBoard = fresh
            await refreshBoards()
        }
    }

    @discardableResult
    public func createBlankBoard(title: String = "未命名情绪板") async -> MoodboardDocument? {
        let doc = MoodboardDocument(
            title: title,
            subtitle: "",
            mode: .autoEditorial(AutoLayoutConfig(columns: 4, spacing: 16, style: .balanced, showPaletteStrip: true))
        )
        do {
            let saved = try await engine.saveBoard(doc)
            activeBoard = saved
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
        do {
            let prop = try await engine.proposeMoodboard(
                seed: .manualSelection(assetIDs),
                primaryCount: min(max(assetIDs.count, 12), 24),
                candidateCount: 30
            )
            var doc = prop.draftDocument
            doc.title = title
            let saved = try await engine.saveBoard(doc)
            activeBoard = saved
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
        do {
            try await engine.deleteBoard(id: id)
            if activeBoard?.id == id {
                activeBoard = nil
                undoStack.removeAll()
                redoStack.removeAll()
                candidatePool.removeAll()
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

    // MARK: - Value-Type Undo / Redo & Debounced Save

    public func commitMutation(_ nextDoc: MoodboardDocument, recordUndo: Bool = true) {
        if recordUndo, let previous = activeBoard, previous != nextDoc {
            undoStack.append(previous)
            if undoStack.count > maxUndoDepth {
                undoStack.removeFirst(undoStack.count - maxUndoDepth)
            }
            redoStack.removeAll()
        }
        var stamped = nextDoc
        stamped.updatedAt = Date()
        activeBoard = stamped
        scheduleSave(stamped)
    }

    public func undo() {
        guard let previous = undoStack.popLast(), let current = activeBoard else { return }
        redoStack.append(current)
        activeBoard = previous
        scheduleSave(previous)
    }

    public func redo() {
        guard let next = redoStack.popLast(), let current = activeBoard else { return }
        undoStack.append(current)
        activeBoard = next
        scheduleSave(next)
    }

    private func scheduleSave(_ doc: MoodboardDocument) {
        saveDebounceTask?.cancel()
        saveDebounceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(220))
            guard !Task.isCancelled, let self else { return }
            self.isSaving = true
            defer { self.isSaving = false }
            do {
                _ = try await self.engine.saveBoard(doc)
                await self.refreshBoards()
            } catch {
                self.lastError = error.localizedDescription
                boardStoreLogger.error("saveBoard failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: - Candidate Swap Pool & Board Composition

    public func selectSwapTarget(_ nodeID: UUID?) async {
        swappingNodeID = nodeID
        await refreshCandidates(for: nodeID)
    }

    public func refreshCandidates(for nodeID: UUID?) async {
        guard let board = activeBoard else {
            candidatePool = []
            return
        }
        let boardAssetIDs = board.referencedAssetIDs
        let targetAssetID: UUID? = {
            if let nodeID, let node = board.nodes.first(where: { $0.id == nodeID }) {
                return node.referencedAssetID
            }
            return boardAssetIDs.first
        }()

        guard let anchorID = targetAssetID else {
            // Board empty: pull recent library items as candidates
            if let recent = try? await engine.fetchAssets(matching: FilterCriteria(sortBy: .newest)) {
                candidatePool = recent.prefix(24).map {
                    ScoredAsset(asset: $0, score: 0.7, matchReasons: ["素材库推荐"])
                }
            }
            return
        }

        do {
            candidatePool = try await engine.replacementCandidates(
                for: anchorID,
                excluding: Set(boardAssetIDs),
                boardContext: boardAssetIDs,
                limit: 32
            )
        } catch {
            lastError = error.localizedDescription
        }
    }

    public func swapNode(nodeID: UUID, with asset: AssetRecord) async {
        guard var board = activeBoard,
              let idx = board.nodes.firstIndex(where: { $0.id == nodeID }),
              case .assetRef(_, let crop, let weight, _) = board.nodes[idx].kind else { return }

        board.nodes[idx].kind = .assetRef(
            assetID: asset.id,
            crop: crop,
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
            let node = BoardNode(
                kind: .assetRef(
                    assetID: asset.id,
                    crop: nil,
                    weight: 1,
                    autoplayLoop: asset.mediaKind == .animatedImage || asset.mediaKind == .video
                ),
                frame: BoardRect(x: Double((n % 4) * 260) + 40, y: Double((n / 4) * 240) + 40, width: 240, height: 210),
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
        guard var board = activeBoard else { return }
        let ids = board.referencedAssetIDs
        guard !ids.isEmpty else { return }
        if let palette = try? await engine.extractBoardPalette(assetIDs: ids, count: 6), !palette.isEmpty {
            board.extractedPalette = palette
            for idx in board.nodes.indices {
                if case .paletteStrip(_, let autoSync) = board.nodes[idx].kind, autoSync {
                    board.nodes[idx].kind = .paletteStrip(colors: palette, autoSyncWithBoard: true)
                }
            }
            commitMutation(board, recordUndo: false)
        }
    }

    // MARK: - Rapid 4-Entry Moodboard Generator

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

    @discardableResult
    public func confirmProposal(title: String, subtitle: String = "") async -> MoodboardDocument? {
        guard let prop = proposal else { return nil }
        var doc = prop.draftDocument
        let cleaned = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleaned.isEmpty { doc.title = cleaned }
        doc.subtitle = subtitle
        do {
            let saved = try await engine.saveBoard(doc)
            activeBoard = saved
            candidatePool = prop.candidatePool
            proposal = nil
            undoStack.removeAll()
            redoStack.removeAll()
            await refreshBoards()
            return saved
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }
}
