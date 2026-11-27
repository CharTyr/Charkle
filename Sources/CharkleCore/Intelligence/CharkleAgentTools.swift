import Foundation
import Vision

/// Grounded overview of a Charkle library returned to both the built-in Moodboard Agent Harness
/// and external MCP/CLI agents.
public nonisolated struct AgentLibraryOverview: Codable, Sendable {
    public struct FolderInfo: Codable, Sendable {
        public let id: UUID
        public let name: String
        public let path: String
        public let assetCount: Int
    }

    public let totalAssets: Int
    public let inboxCount: Int
    public let folders: [FolderInfo]
    public let topTags: [TagCount]
    public let mediaKindCounts: [String: Int]
    public let boardCount: Int
}

public nonisolated struct AgentVisualInsight: Codable, Sendable {
    public let assetID: UUID
    public let description: String
    public let tags: [String]

    public init(assetID: UUID, description: String, tags: [String]) {
        self.assetID = assetID
        self.description = description
        self.tags = tags
    }
}

/// Structured Board Composition Plan produced by either the Multimodal Curator Agent
/// or an external Agent calling `compose_moodboard` / `patch_moodboard` via MCP/CLI.
public nonisolated struct AgentBoardPlan: Sendable {
    public struct NoteSpec: Sendable {
        public let title: String
        public let text: String
        public let style: NoteStyle
    }

    public struct SlotPick: Sendable {
        public let slot: Int
        public let weight: Int
        public let reason: String
    }

    public struct SectionSpec: Sendable {
        public let title: String
        public let tint: GroupTint
        public let rationale: String
        public let picks: [SlotPick]
    }

    public let boardTitle: String
    public let boardSubtitle: String
    public let curatorNote: NoteSpec?
    public let recommendedLayout: EditorialStyle
    public let sections: [SectionSpec]
    public let candidatePicks: [SlotPick]
    public let rejectedNote: String?
    public let visualInsights: [(slot: Int, description: String, tags: [String])]
}

public nonisolated struct AgentRecallResult: Sendable {
    public let eligibleTotal: Int
    public let candidates: [AssetRecord]
    public let scoresByID: [UUID: ScoredAsset]
    public let folderPathByID: [UUID: String]
}

public nonisolated struct VerifiedBoardCompilation: Sendable {
    public let document: MoodboardDocument
    public let primaryMatches: [ScoredAsset]
    public let candidatePool: [ScoredAsset]
    public let sections: [MoodboardSectionDraft]
    public let extractedPalette: [LabColor]
    public let issues: [String]
    public let needsRepair: Bool
}

/// Shared, grounded tool layer powering BOTH the built-in Moodboard Curator Agent Harness
/// and external Agents (MCP Server / CLI).
///
/// Enforces deterministic ID grounding, recursive folder scoping, Vision near-duplicate guards,
/// strict exclusion/lock compliance, and safe lazy caching of newly discovered visual metadata.
public nonisolated struct CharkleAgentTools: Sendable {
    private let database: LibraryDatabase
    private let media: MediaPipeline

    public init(database: LibraryDatabase, media: MediaPipeline) {
        self.database = database
        self.media = media
    }

    /// Loads a compact upright JPEG strictly compliant with TypeSafe's `280...1568` pixel bounds.
    func preparedTypeSafeJPEG(for asset: AssetRecord, targetLongSide: Int = 448) -> Data? {
        let originalURL = media.originalPath(for: asset)
        let candidateURLs: [URL] = [
            media.thumbnailURL(for: asset.id, tier: targetLongSide > 520 ? .preview1400 : .grid520),
            media.thumbnailURL(for: asset.id, tier: .grid520),
            FileManager.default.fileExists(atPath: originalURL.path) ? originalURL : nil
        ].compactMap { $0 }

        for url in candidateURLs {
            if let cg = MediaPipeline.raster(url)?.poster,
               let data = TypeSafeImagePreparer.prepareJPEG(from: cg, targetLongSide: targetLongSide) {
                return data
            }
        }
        return nil
    }

    // MARK: - Tool 1: Library Overview

    public func libraryOverview() async throws -> AgentLibraryOverview {
        let assets = try await database.fetchAssets(matching: FilterCriteria(includeTrashed: false))
        let folders = try await database.fetchFolders()
        let tags = try await database.fetchTagCounts()
        let boards = try await database.fetchBoards()

        let folderPaths = Self.buildFolderPaths(folders)
        var countsByFolder: [UUID: Int] = [:]
        var mediaCounts: [String: Int] = [:]
        var inbox = 0
        for asset in assets {
            if let fid = asset.folderID {
                countsByFolder[fid, default: 0] += 1
            } else {
                inbox += 1
            }
            mediaCounts[asset.mediaKind.rawValue, default: 0] += 1
        }

        let folderInfos = folders.map { folder in
            AgentLibraryOverview.FolderInfo(
                id: folder.id,
                name: folder.name,
                path: folderPaths[folder.id] ?? folder.name,
                assetCount: countsByFolder[folder.id, default: 0]
            )
        }.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }

        return AgentLibraryOverview(
            totalAssets: assets.count,
            inboxCount: inbox,
            folders: folderInfos,
            topTags: Array(tags.prefix(40)),
            mediaKindCounts: mediaCounts,
            boardCount: boards.count
        )
    }

    // MARK: - Tool 2: Multi-Route Grounded Candidate Recall

    public func recallCandidates(
        request: MoodboardCurationRequest,
        expandedQueries: [String] = [],
        preferredFolderNames: [String] = [],
        inferredColors: [LabColor] = [],
        provider: (any CloudAIProvider)? = nil,
        maxCandidates: Int = 32
    ) async throws -> AgentRecallResult {
        let allAssets = try await database.fetchAssets(matching: FilterCriteria(includeTrashed: false))
        let folders = try await database.fetchFolders()
        let folderPaths = Self.buildFolderPaths(folders)
        let vectors = try await database.vectors()

        let excluded = Set(request.excludedAssetIDs)
        let allowedFolderIDs = Self.expandFolderScope(request.scopeFolderIDs, folders: folders)
        let requiredTagSet = Set(request.requiredTags.map(SearchText.normalize).filter { !$0.isEmpty })

        // Filter eligible pool by hard user constraints (folder scope, required tags, exclusions)
        let eligible = allAssets.filter { asset in
            if excluded.contains(asset.id) { return false }
            if !allowedFolderIDs.isEmpty {
                guard let fid = asset.folderID, allowedFolderIDs.contains(fid) else { return false }
            }
            if !requiredTagSet.isEmpty {
                let assetTags = Set((asset.tags + asset.suggestedTags).map(SearchText.normalize))
                guard requiredTagSet.isSubset(of: assetTags) else { return false }
            }
            return true
        }

        let eligibleByID = Dictionary(uniqueKeysWithValues: eligible.map { ($0.id, $0) })

        // Always-keep pinned / seed / existing board items (unless explicitly excluded)
        var mustIncludeIDs: [UUID] = []
        var mustSeen = Set<UUID>()
        func addMust(_ id: UUID) {
            guard !excluded.contains(id), eligibleByID[id] != nil, mustSeen.insert(id).inserted else { return }
            mustIncludeIDs.append(id)
        }
        for id in request.lockedAssetIDs { addMust(id) }
        for id in request.seedAssetIDs { addMust(id) }
        if let board = request.existingBoard {
            for id in board.referencedAssetIDs { addMust(id) }
        }

        // Compute multi-route evidence scores for ranking & offline fallback
        let queries = Self.uniqueStrings(
            [request.prompt, request.refinementInstruction ?? ""] + expandedQueries
        ).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

        var keywordRanks: [UUID: Double] = [:]
        for query in queries.prefix(12) {
            let direct = (try? await database.searchRanks(query)) ?? [:]
            for (id, rank) in direct {
                keywordRanks[id] = max(keywordRanks[id] ?? 0, rank)
            }
            let terms = query.split(whereSeparator: \.isWhitespace).map(String.init)
            if terms.count > 1 {
                for term in terms.prefix(8) {
                    let sub = (try? await database.searchRanks(term)) ?? [:]
                    for (id, rank) in sub {
                        keywordRanks[id] = max(keywordRanks[id] ?? 0, rank * 0.72)
                    }
                }
            }
        }

        let preferredFolderIDs = Self.matchPreferredFolders(preferredFolderNames, folders: folders, paths: folderPaths)
        let seedAssets = request.seedAssetIDs.compactMap { eligibleByID[$0] }
        let targetColors = request.targetPalette.isEmpty ? inferredColors : request.targetPalette

        var queryVector: [Float]?
        let primaryQueryText = [request.prompt, request.refinementInstruction ?? ""]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        if let provider, !primaryQueryText.isEmpty,
           vectors.values.contains(where: { $0.embeddingModel == provider.embeddingIdentity && $0.embedding != nil }) {
            queryVector = try? await provider.embed(primaryQueryText)
        }

        let seedFeaturePrints = seedAssets.compactMap { seed in
            vectors[seed.id]?.featurePrint.flatMap(VisionAnalyzer.unarchiveFeaturePrint)
        }

        var scoredList: [ScoredAsset] = []
        scoredList.reserveCapacity(eligible.count)
        for asset in eligible {
            let scored = Self.scoreCandidate(
                asset: asset,
                seeds: seedAssets,
                preferredFolderIDs: preferredFolderIDs,
                keywordRanks: keywordRanks,
                targetColors: targetColors,
                colorTolerance: request.colorTolerance,
                queryVector: queryVector,
                embeddingIdentity: provider?.embeddingIdentity,
                vectors: vectors,
                predecodedSeedPrints: seedFeaturePrints
            )
            scoredList.append(scored)
        }
        let scoresByID = Dictionary(uniqueKeysWithValues: scoredList.map { ($0.id, $0) })

        // Small-library 100% recall guarantee: inspect ALL eligible assets directly on 1–2 Contact Sheets!
        let orderedCandidates: [AssetRecord]
        if eligible.count <= maxCandidates {
            let mustAssets = mustIncludeIDs.compactMap { eligibleByID[$0] }
            let rest = eligible
                .filter { !mustSeen.contains($0.id) }
                .sorted { lhs, rhs in
                    let lb = Self.scoreBucket(scoresByID[lhs.id]?.score ?? 0)
                    let rb = Self.scoreBucket(scoresByID[rhs.id]?.score ?? 0)
                    if lb != rb { return lb > rb }
                    if lhs.createdAt != rhs.createdAt { return lhs.createdAt > rhs.createdAt }
                    return lhs.id.uuidString < rhs.id.uuidString
                }
            orderedCandidates = mustAssets + rest
        } else {
            // Progressive bounded recall for large libraries
            let mustAssets = mustIncludeIDs.compactMap { eligibleByID[$0] }
            let remainingBudget = max(0, maxCandidates - mustAssets.count)
            let rankedRest = eligible
                .filter { !mustSeen.contains($0.id) }
                .sorted { lhs, rhs in
                    let lb = Self.scoreBucket(scoresByID[lhs.id]?.score ?? 0)
                    let rb = Self.scoreBucket(scoresByID[rhs.id]?.score ?? 0)
                    if lb != rb { return lb > rb }
                    if lhs.rating != rhs.rating { return lhs.rating > rhs.rating }
                    if lhs.createdAt != rhs.createdAt { return lhs.createdAt > rhs.createdAt }
                    return lhs.id.uuidString < rhs.id.uuidString
                }
            orderedCandidates = mustAssets + Array(rankedRest.prefix(remainingBudget))
        }

        return AgentRecallResult(
            eligibleTotal: eligible.count,
            candidates: orderedCandidates,
            scoresByID: scoresByID,
            folderPathByID: folderPaths
        )
    }

    // MARK: - Tool 3: Render Numbered Visual Contact Sheets + Grounded Manifest

    public struct ContactSheetPackage: Sendable {
        public let sheets: [ContactSheetBatch]
        public let slotToAsset: [Int: AssetRecord]
        public let manifestText: String
    }

    public func buildContactSheets(
        for candidates: [AssetRecord],
        folderPathByID: [UUID: String],
        seedIDs: Set<UUID>,
        lockedIDs: Set<UUID>,
        existingBoardIDs: Set<UUID>,
        sheetCapacity: Int = 16
    ) -> ContactSheetPackage {
        var sheets: [ContactSheetBatch] = []
        var slotToAsset: [Int: AssetRecord] = [:]
        var manifestLines: [String] = []

        var slot = 1
        var currentEntries: [ContactSheetRenderer.Entry] = []

        func flushSheet() {
            guard !currentEntries.isEmpty else { return }
            if let batch = ContactSheetRenderer.render(entries: currentEntries) {
                sheets.append(batch)
            }
            currentEntries.removeAll(keepingCapacity: true)
        }

        for asset in candidates {
            let currentSlot = slot
            slot += 1
            slotToAsset[currentSlot] = asset
            let thumbURL = media.thumbnailURL(for: asset.id, tier: .grid520)
                ?? media.thumbnailURL(for: asset.id, tier: .preview1400)
            currentEntries.append(ContactSheetRenderer.Entry(slot: currentSlot, asset: asset, thumbnailURL: thumbURL))

            var flags: [String] = []
            if lockedIDs.contains(asset.id) { flags.append("LOCKED_MUST_KEEP") }
            if seedIDs.contains(asset.id) { flags.append("USER_SEED") }
            if existingBoardIDs.contains(asset.id) { flags.append("CURRENTLY_ON_BOARD") }

            let folderLabel = asset.folderID.flatMap { folderPathByID[$0] } ?? "Inbox"
            let colors = asset.dominantColors.prefix(3).map(\.hex).joined(separator: ",")
            let tags = (asset.tags + asset.suggestedTags).prefix(6).joined(separator: ",")
            let ratioStr = String(format: "%.2f", asset.aspectRatio)
            let desc = (asset.aiDescription ?? asset.notes).replacingOccurrences(of: "\n", with: " ").prefix(120)
            let ocr = (asset.ocrText ?? "").replacingOccurrences(of: "\n", with: " ").prefix(60)

            var line = String(format: "#%02d | kind=%@ | ratio=%@ | folder=%@ | title=%@", currentSlot, asset.mediaKind.rawValue, ratioStr, folderLabel, String(asset.title.prefix(48)))
            if !colors.isEmpty { line += " | colors=\(colors)" }
            if !tags.isEmpty { line += " | tags=\(tags)" }
            if !desc.isEmpty { line += " | desc=\(desc)" }
            if !ocr.isEmpty { line += " | ocr=\(ocr)" }
            if !flags.isEmpty { line += " | flags=\(flags.joined(separator: ","))" }
            manifestLines.append(line)

            if currentEntries.count >= sheetCapacity {
                flushSheet()
            }
        }
        flushSheet()

        return ContactSheetPackage(
            sheets: sheets,
            slotToAsset: slotToAsset,
            manifestText: manifestLines.joined(separator: "\n")
        )
    }

    // MARK: - Tool 4: Deterministic Verifier & Board Document Compiler

    public func compileAndVerifyBoard(
        plan: AgentBoardPlan,
        slotToAsset: [Int: AssetRecord],
        request: MoodboardCurationRequest,
        recall: AgentRecallResult
    ) async throws -> VerifiedBoardCompilation {
        let featurePrints = try await database.featurePrints()
        let excluded = Set(request.excludedAssetIDs)
        let locked = Set(request.lockedAssetIDs)
        let seeds = Set(request.seedAssetIDs)
        let maxPrimary = max(1, min(32, request.preferredCount))

        var issues: [String] = []
        var usedPrimaryIDs = Set<UUID>()
        var primaryAssets: [AssetRecord] = []
        var primaryScored: [ScoredAsset] = []
        var verifiedSections: [MoodboardSectionDraft] = []
        var demotedDuplicates: [ScoredAsset] = []
        var obsCache: [UUID: VNFeaturePrintObservation] = [:]
        var missingObs = Set<UUID>()

        func featurePrintObs(for id: UUID) -> VNFeaturePrintObservation? {
            if let hit = obsCache[id] { return hit }
            if missingObs.contains(id) { return nil }
            guard let data = featurePrints[id],
                  let obs = VisionAnalyzer.unarchiveFeaturePrint(data) else {
                missingObs.insert(id)
                return nil
            }
            obsCache[id] = obs
            return obs
        }

        func isNearDuplicateOfSelected(_ candidate: AssetRecord) -> Bool {
            guard !locked.contains(candidate.id) && !seeds.contains(candidate.id) else { return false }
            let candidateObs = featurePrintObs(for: candidate.id)
            for chosen in primaryAssets {
                if !candidate.contentHash.isEmpty && candidate.contentHash == chosen.contentHash {
                    return true
                }
                if let a = candidateObs,
                   let b = featurePrintObs(for: chosen.id),
                   let dist = VisionAnalyzer.visualDistance(between: a, and: b),
                   dist < 0.18 {
                    return true
                }
            }
            return false
        }

        // 1. Ground & verify every section's picks
        for section in plan.sections {
            var sectionAssetIDs: [UUID] = []
            var sectionHeroIDs: [UUID] = []
            for pick in section.picks {
                guard let asset = slotToAsset[pick.slot] else {
                    issues.append("忽略无效编号 #\(pick.slot)")
                    continue
                }
                if excluded.contains(asset.id) {
                    issues.append("已拦截用户排除的素材 #\(pick.slot)")
                    continue
                }
                guard !usedPrimaryIDs.contains(asset.id) else { continue }
                if primaryAssets.count >= maxPrimary && !locked.contains(asset.id) && !seeds.contains(asset.id) {
                    demotedDuplicates.append(
                        ScoredAsset(asset: asset, score: 0.78, matchReasons: [pick.reason.isEmpty ? "备选推荐" : pick.reason])
                    )
                    continue
                }
                if isNearDuplicateOfSelected(asset) {
                    demotedDuplicates.append(
                        ScoredAsset(asset: asset, score: 0.72, matchReasons: ["与已选图高度相似，移入备选池"])
                    )
                    continue
                }
                usedPrimaryIDs.insert(asset.id)
                primaryAssets.append(asset)
                sectionAssetIDs.append(asset.id)
                if pick.weight >= 2 { sectionHeroIDs.append(asset.id) }
                let reason = pick.reason.trimmingCharacters(in: .whitespacesAndNewlines)
                primaryScored.append(
                    ScoredAsset(
                        asset: asset,
                        score: pick.weight >= 2 ? 0.98 : 0.90,
                        matchReasons: [reason.isEmpty ? section.title : reason]
                    )
                )
            }
            if !sectionAssetIDs.isEmpty {
                verifiedSections.append(
                    MoodboardSectionDraft(
                        title: section.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "核心参考" : section.title,
                        tint: section.tint,
                        rationale: section.rationale,
                        assetIDs: sectionAssetIDs,
                        heroAssetIDs: sectionHeroIDs
                    )
                )
            }
        }

        // 2. Guarantee every user-locked & seed asset is preserved
        let requiredKeep = request.lockedAssetIDs + request.seedAssetIDs
        var missingRequired: [AssetRecord] = []
        for id in requiredKeep where !excluded.contains(id) && !usedPrimaryIDs.contains(id) {
            if let asset = recall.candidates.first(where: { $0.id == id }) {
                usedPrimaryIDs.insert(id)
                primaryAssets.insert(asset, at: 0)
                missingRequired.append(asset)
                primaryScored.insert(ScoredAsset(asset: asset, score: 1.0, matchReasons: [locked.contains(id) ? "已锁定保留" : "种子图"]), at: 0)
            }
        }
        if !missingRequired.isEmpty {
            if verifiedSections.isEmpty {
                verifiedSections.append(
                    MoodboardSectionDraft(
                        title: "定调核心参考",
                        tint: .neutral,
                        rationale: "包含你指定的种子与锁定素材",
                        assetIDs: missingRequired.map(\.id),
                        heroAssetIDs: missingRequired.first.map { [$0.id] } ?? []
                    )
                )
            } else {
                verifiedSections[0].assetIDs = missingRequired.map(\.id) + verifiedSections[0].assetIDs
            }
        }

        // 3. Build grounded candidate swap pool
        var candidateScored: [ScoredAsset] = []
        var candidateSeen = usedPrimaryIDs
        for pick in plan.candidatePicks {
            guard let asset = slotToAsset[pick.slot],
                  !excluded.contains(asset.id),
                  candidateSeen.insert(asset.id).inserted else { continue }
            let reason = pick.reason.trimmingCharacters(in: .whitespacesAndNewlines)
            candidateScored.append(
                ScoredAsset(asset: asset, score: 0.76, matchReasons: [reason.isEmpty ? "同方向备选" : reason])
            )
        }
        for demoted in demotedDuplicates where !excluded.contains(demoted.id) && candidateSeen.insert(demoted.id).inserted {
            candidateScored.append(demoted)
        }
        // Fill remaining candidate swap pool (only items with some positive relevance or visual proximity to selected)
        let extraCandidates = recall.candidates
            .filter { !excluded.contains($0.id) && !candidateSeen.contains($0.id) }
            .compactMap { recall.scoresByID[$0.id] }
            .sorted { $0.score > $1.score }
        for extra in extraCandidates.prefix(max(0, request.candidateCount - candidateScored.count)) {
            if candidateSeen.insert(extra.id).inserted {
                candidateScored.append(extra)
            }
        }

        // 4. Harmonize palette from selected primary assets
        let paletteSource = primaryAssets.flatMap(\.dominantColors)
        let extractedPalette = MoodboardCurator.palette(paletteSource.isEmpty ? request.targetPalette : paletteSource, count: 6)

        // 5. Compile rich BoardNodes (Curator Note + Palette Strip + Section Headers + Hero/Supporting Cards)
        let assetByID = Dictionary(uniqueKeysWithValues: primaryAssets.map { ($0.id, $0) })
        let effectiveStyle = request.layoutStyle
        var existingAssetNodesByAssetID: [UUID: BoardNode] = [:]
        var preservedUserNotes: [BoardNode] = []
        if let existingBoard = request.existingBoard {
            let generatedNoteTitles: Set<String> = ["视觉定调说明", "策展说明", "视觉策展方向"]
            for existingNode in existingBoard.nodes {
                if let refID = existingNode.referencedAssetID {
                    if existingAssetNodesByAssetID[refID] == nil {
                        existingAssetNodesByAssetID[refID] = existingNode
                    }
                } else if case .note(let noteTitle, _, _, _) = existingNode.kind {
                    let normalizedTitle = (noteTitle ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    if existingNode.isLocked || !generatedNoteTitles.contains(normalizedTitle) {
                        preservedUserNotes.append(existingNode)
                    }
                }
            }
        }

        var nodes = Self.buildBoardNodes(
            sections: verifiedSections,
            assetByID: assetByID,
            curatorNote: request.includeCuratorNotes ? plan.curatorNote : nil,
            extractedPalette: extractedPalette,
            includeSectionHeaders: request.includeCuratorNotes && (verifiedSections.count >= 2 || (verifiedSections.count == 1 && !verifiedSections[0].rationale.isEmpty)),
            useFreeformLayout: request.useFreeformLayout,
            style: effectiveStyle,
            existingAssetNodesByAssetID: existingAssetNodesByAssetID,
            lockedAssetIDs: locked
        )

        if !preservedUserNotes.isEmpty {
            let maxY = nodes.map(\.frame.maxY).max() ?? 32.0
            var noteX = 32.0
            var noteY = maxY + 28.0
            var nextZ = (nodes.map(\.zIndex).max() ?? 0) + 1
            var nextOrder = nodes.count
            for var userNote in preservedUserNotes {
                if request.useFreeformLayout {
                    let w = max(180.0, userNote.frame.width.isFinite ? userNote.frame.width : 240.0)
                    let h = max(110.0, userNote.frame.height.isFinite ? userNote.frame.height : 140.0)
                    if noteX + w > 1140.0 {
                        noteX = 32.0
                        noteY += h + 18.0
                    }
                    if !userNote.isLocked {
                        userNote.frame = BoardRect(x: noteX, y: noteY, width: w, height: h)
                    }
                    noteX += w + 18.0
                }
                userNote.zIndex = nextZ
                userNote.editorialOrder = nextOrder
                nextZ += 1
                nextOrder += 1
                nodes.append(userNote)
            }
        }

        let cleanTitle = plan.boardTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackTitle = request.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalTitle = !cleanTitle.isEmpty
            ? String(cleanTitle.prefix(80))
            : (!fallbackTitle.isEmpty ? String(fallbackTitle.prefix(40)) : (request.existingBoard?.title ?? "AI 策展情绪板"))
        let finalSubtitle = plan.boardSubtitle.trimmingCharacters(in: .whitespacesAndNewlines)

        let boardMode: BoardLayoutMode = request.useFreeformLayout
            ? .freeform
            : .autoEditorial(AutoLayoutConfig(
                columns: primaryAssets.count <= 4 ? max(2, primaryAssets.count) : (effectiveStyle == .compact ? 4 : 3),
                spacing: effectiveStyle == .compact ? 10 : 16,
                style: effectiveStyle,
                showPaletteStrip: true
            ))

        let document: MoodboardDocument
        if var existing = request.existingBoard {
            let survivingNodeIDs = Set(nodes.map(\.id))
            existing.title = finalTitle
            if !finalSubtitle.isEmpty { existing.subtitle = finalSubtitle }
            existing.mode = boardMode
            existing.nodes = nodes
            existing.connectors.removeAll {
                !survivingNodeIDs.contains($0.fromNodeID) || !survivingNodeIDs.contains($0.toNodeID)
            }
            existing.extractedPalette = extractedPalette
            existing.candidateAssetIDs = candidateScored.map(\.id)
            existing.updatedAt = Date()
            document = existing
        } else {
            document = MoodboardDocument(
                title: finalTitle,
                subtitle: finalSubtitle,
                mode: boardMode,
                nodes: nodes,
                extractedPalette: extractedPalette,
                candidateAssetIDs: candidateScored.map(\.id)
            )
        }

        let needsRepair = primaryAssets.isEmpty && !recall.candidates.isEmpty && (plan.rejectedNote?.isEmpty ?? true)

        return VerifiedBoardCompilation(
            document: document,
            primaryMatches: primaryScored,
            candidatePool: Array(candidateScored.prefix(request.candidateCount)),
            sections: verifiedSections,
            extractedPalette: extractedPalette,
            issues: issues,
            needsRepair: needsRepair
        )
    }

    // MARK: - Tool 5: Lazy Visual Insight Caching (Free Byproduct!)

    public func persistVisualInsights(
        _ insights: [AgentVisualInsight],
        overwriteDescription: Bool = false
    ) async -> Int {
        guard !insights.isEmpty else { return 0 }
        do {
            return try await database.transaction { store in
                let existingLibraryTags = ((try? store.fetchTagCounts()) ?? []).map(\.name)
                var updatedCount = 0
                for insight in insights {
                    guard var asset = try store.asset(id: insight.assetID) else { continue }
                    let cleanDesc = String(insight.description.trimmingCharacters(in: .whitespacesAndNewlines).prefix(600))
                    let normalizedTags = CloudTagNormalizer.canonicalizeSuggestedTags(
                        asset.suggestedTags + insight.tags,
                        existingLibraryTags: existingLibraryTags,
                        existingAssetTags: asset.tags,
                        maxCount: 6
                    )
                    var changed = false
                    if !cleanDesc.isEmpty {
                        let existingEmpty = asset.aiDescription?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true
                        if (overwriteDescription && asset.aiDescription != cleanDesc) || existingEmpty {
                            asset.aiDescription = cleanDesc
                            changed = true
                        }
                    }
                    if !insight.tags.isEmpty, normalizedTags != asset.suggestedTags {
                        asset.suggestedTags = normalizedTags
                        changed = true
                    }
                    if changed {
                        _ = try store.saveAssetLocally(asset, projectLocation: false)
                        updatedCount += 1
                    }
                }
                return updatedCount
            }
        } catch {
            return 0
        }
    }

    // MARK: - Helpers

    static func buildBoardNodes(
        sections: [MoodboardSectionDraft],
        assetByID: [UUID: AssetRecord],
        curatorNote: AgentBoardPlan.NoteSpec?,
        extractedPalette: [LabColor],
        includeSectionHeaders: Bool,
        useFreeformLayout: Bool,
        style: EditorialStyle,
        existingAssetNodesByAssetID: [UUID: BoardNode] = [:],
        lockedAssetIDs: Set<UUID> = []
    ) -> [BoardNode] {
        var nodes: [BoardNode] = []
        var order = 0
        var cursorY = 32.0
        let canvasWidth = 1140.0
        let gap = style == .compact ? 12.0 : 18.0

        // 1. Optional Curator Direction Note at top
        if let note = curatorNote, !note.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let noteHeight = 148.0
            nodes.append(
                BoardNode(
                    kind: .note(title: note.title.isEmpty ? "视觉策展方向" : note.title, text: note.text, style: note.style, fontSize: 13.5),
                    frame: BoardRect(x: 32, y: cursorY, width: useFreeformLayout ? 360 : 320, height: noteHeight),
                    zIndex: order,
                    editorialOrder: order
                )
            )
            order += 1
            if useFreeformLayout {
                if !extractedPalette.isEmpty {
                    nodes.append(
                        BoardNode(
                            kind: .paletteStrip(colors: extractedPalette, autoSyncWithBoard: true),
                            frame: BoardRect(x: 412, y: cursorY, width: canvasWidth - 412, height: 84),
                            zIndex: order,
                            editorialOrder: order
                        )
                    )
                    order += 1
                }
                cursorY += noteHeight + 28
            }
        } else if useFreeformLayout && !extractedPalette.isEmpty {
            nodes.append(
                BoardNode(
                    kind: .paletteStrip(colors: extractedPalette, autoSyncWithBoard: true),
                    frame: BoardRect(x: 32, y: cursorY, width: canvasWidth - 32, height: 78),
                    zIndex: order,
                    editorialOrder: order
                )
            )
            order += 1
            cursorY += 104
        }

        // 2. Sections + Ordered Hero/Supporting Cards
        for section in sections {
            let sectionAssets = section.assetIDs.compactMap { assetByID[$0] }
            guard !sectionAssets.isEmpty else { continue }
            let heroSet = Set(section.heroAssetIDs)

            if includeSectionHeaders {
                let headerText = section.rationale.isEmpty ? section.title : "\(section.title) · \(section.rationale)"
                nodes.append(
                    BoardNode(
                        kind: .groupFrame(title: String(headerText.prefix(72)), tint: section.tint),
                        frame: BoardRect(x: 32, y: cursorY, width: canvasWidth - 32, height: 60),
                        zIndex: order,
                        editorialOrder: order
                    )
                )
                order += 1
                cursorY += 76
            }

            if useFreeformLayout {
                // Arrange section assets into crisp non-overlapping rows with hero emphasis
                var rowStart = 0
                while rowStart < sectionAssets.count {
                    let hasHeroInRow = heroSet.contains(sectionAssets[rowStart].id)
                    let rowCount = min(hasHeroInRow ? 3 : 4, sectionAssets.count - rowStart)
                    let row = Array(sectionAssets[rowStart..<(rowStart + rowCount)])
                    let ratios = row.map { min(2.0, max(0.62, $0.aspectRatio)) }
                    let weights = row.enumerated().map { idx, item -> Double in
                        let boost = heroSet.contains(item.id) ? 1.38 : (idx == 0 && hasHeroInRow ? 1.25 : 1.0)
                        return ratios[idx] * boost
                    }
                    let rowHeight = min(380.0, max(165.0, (canvasWidth - 32 - Double(rowCount - 1) * gap) / max(0.5, weights.reduce(0, +))))
                    var x = 32.0
                    for (idx, asset) in row.enumerated() {
                        let w = rowHeight * weights[idx]
                        let weight = heroSet.contains(asset.id) ? 2 : 1
                        let prior = existingAssetNodesByAssetID[asset.id]
                        let priorCrop: NormalizedCropRect? = {
                            if case .assetRef(_, let c, _, _) = prior?.kind { return c }
                            return nil
                        }()
                        nodes.append(
                            BoardNode(
                                id: prior?.id ?? UUID(),
                                kind: .assetRef(
                                    assetID: asset.id,
                                    crop: priorCrop,
                                    weight: weight,
                                    autoplayLoop: asset.mediaKind == .animatedImage || asset.mediaKind == .video
                                ),
                                frame: BoardRect(x: x, y: cursorY, width: w, height: rowHeight),
                                zIndex: order,
                                rotationDegrees: prior?.rotationDegrees ?? 0,
                                flipHorizontal: prior?.flipHorizontal ?? false,
                                flipVertical: prior?.flipVertical ?? false,
                                isLocked: (prior?.isLocked ?? false) || lockedAssetIDs.contains(asset.id),
                                editorialOrder: order
                            )
                        )
                        order += 1
                        x += w + gap
                    }
                    cursorY += rowHeight + gap
                    rowStart += rowCount
                }
                cursorY += 20
            } else {
                // Auto Editorial mode: assign Hero weight + sequential editorialOrder for EditorialLayoutSolver
                for (idx, asset) in sectionAssets.enumerated() {
                    let isHero = heroSet.contains(asset.id) || (sections.first?.id == section.id && idx == 0 && heroSet.isEmpty)
                    let ratio = min(2.0, max(0.62, asset.aspectRatio))
                    let w = isHero ? 420.0 : 260.0
                    let prior = existingAssetNodesByAssetID[asset.id]
                    let priorCrop: NormalizedCropRect? = {
                        if case .assetRef(_, let c, _, _) = prior?.kind { return c }
                        return nil
                    }()
                    nodes.append(
                        BoardNode(
                            id: prior?.id ?? UUID(),
                            kind: .assetRef(
                                assetID: asset.id,
                                crop: priorCrop,
                                weight: isHero ? 2 : 1,
                                autoplayLoop: asset.mediaKind == .animatedImage || asset.mediaKind == .video
                            ),
                            frame: BoardRect(x: 32, y: cursorY, width: w, height: w / ratio),
                            zIndex: order,
                            rotationDegrees: prior?.rotationDegrees ?? 0,
                            flipHorizontal: prior?.flipHorizontal ?? false,
                            flipVertical: prior?.flipVertical ?? false,
                            isLocked: (prior?.isLocked ?? false) || lockedAssetIDs.contains(asset.id),
                            editorialOrder: order
                        )
                    )
                    order += 1
                }
            }
        }

        // In Auto Editorial mode, append palette strip neatly at top/bottom if requested and not already included
        if !useFreeformLayout && !extractedPalette.isEmpty {
            nodes.append(
                BoardNode(
                    kind: .paletteStrip(colors: extractedPalette, autoSyncWithBoard: true),
                    frame: BoardRect(x: 32, y: cursorY + 12, width: canvasWidth - 32, height: 76),
                    zIndex: order,
                    editorialOrder: order
                )
            )
        }

        return nodes
    }

    static func scoreBucket(_ score: Double) -> Int {
        guard score.isFinite else { return 0 }
        return Int((max(-1000.0, min(1000.0, score)) * 1000.0).rounded())
    }

    static func buildFolderPaths(_ folders: [FolderRecord]) -> [UUID: String] {
        let byID = Dictionary(uniqueKeysWithValues: folders.map { ($0.id, $0) })
        var result: [UUID: String] = [:]
        for folder in folders {
            var parts: [String] = []
            var cursor: UUID? = folder.id
            var visited = Set<UUID>()
            while let cid = cursor, visited.insert(cid).inserted, let f = byID[cid] {
                parts.append(f.name)
                cursor = f.parentID
            }
            result[folder.id] = parts.reversed().joined(separator: "/")
        }
        return result
    }

    static func expandFolderScope(_ roots: [UUID], folders: [FolderRecord]) -> Set<UUID> {
        guard !roots.isEmpty else { return [] }
        let childrenByParent = Dictionary(grouping: folders) { $0.parentID }
        var expanded = Set<UUID>()
        var queue = roots
        var idx = 0
        while idx < queue.count {
            let current = queue[idx]
            idx += 1
            guard expanded.insert(current).inserted else { continue }
            for child in childrenByParent[current, default: []] {
                queue.append(child.id)
            }
        }
        return expanded
    }

    private static func matchPreferredFolders(
        _ names: [String],
        folders: [FolderRecord],
        paths: [UUID: String]
    ) -> Set<UUID> {
        guard !names.isEmpty else { return [] }
        let normalized = names.map(SearchText.normalize).filter { !$0.isEmpty }
        var matched: [UUID] = []
        for folder in folders {
            let nameNorm = SearchText.normalize(folder.name)
            let pathNorm = SearchText.normalize(paths[folder.id] ?? folder.name)
            if normalized.contains(where: { q in
                nameNorm.contains(q) || q.contains(nameNorm) || pathNorm.contains(q)
            }) {
                matched.append(folder.id)
            }
        }
        return expandFolderScope(matched, folders: folders)
    }

    static func scoreCandidate(
        asset: AssetRecord,
        seeds: [AssetRecord],
        preferredFolderIDs: Set<UUID>,
        keywordRanks: [UUID: Double],
        targetColors: [LabColor],
        colorTolerance: Double,
        queryVector: [Float]?,
        embeddingIdentity: String?,
        vectors: [UUID: AssetVector],
        predecodedSeedPrints: [VNFeaturePrintObservation]? = nil
    ) -> ScoredAsset {
        var signals: [(Double, Double, String)] = []

        if !keywordRanks.isEmpty {
            let r = keywordRanks[asset.id] ?? 0
            signals.append((r, 0.44, "关键词匹配"))
        }
        if !preferredFolderIDs.isEmpty {
            let inFolder = asset.folderID.map { preferredFolderIDs.contains($0) } ?? false
            signals.append((inFolder ? 1.0 : 0.0, 0.34, "所属文件夹吻合"))
        }
        if let vector = vectors[asset.id], let emb = vector.embedding {
            var cloudSims: [Double] = []
            if let qv = queryVector, vector.embeddingModel == embeddingIdentity {
                cloudSims.append(cosine(emb, qv))
            }
            for seed in seeds {
                if let other = vectors[seed.id], other.embeddingModel == vector.embeddingModel, let vals = other.embedding {
                    cloudSims.append(cosine(emb, vals))
                }
            }
            if let best = cloudSims.max() {
                signals.append((best, 0.42, "语义接近"))
            }
        }
        if let printData = vectors[asset.id]?.featurePrint, !seeds.isEmpty {
            let seedObsList = predecodedSeedPrints
                ?? seeds.compactMap { vectors[$0.id]?.featurePrint.flatMap(VisionAnalyzer.unarchiveFeaturePrint) }
            if !seedObsList.isEmpty,
               let candidateObs = VisionAnalyzer.unarchiveFeaturePrint(printData) {
                let best = seedObsList
                    .compactMap { VisionAnalyzer.visualDistance(between: candidateObs, and: $0) }
                    .map { VisionAnalyzer.visualSimilarity(forDistance: $0) }
                    .max()
                if let best {
                    signals.append((best, 0.36, "画面风格接近"))
                }
            }
        }
        let effectiveColors = targetColors.isEmpty ? seeds.flatMap { $0.dominantColors.prefix(3) } : targetColors
        if !effectiveColors.isEmpty {
            let sim: Double
            if targetColors.isEmpty {
                if let avgDelta = weightedPaletteDistance(asset.dominantColors, effectiveColors) {
                    if avgDelta <= 6.0 {
                        sim = 1.0
                    } else if avgDelta < 22.0 {
                        sim = pow((22.0 - avgDelta) / 16.0, 1.1)
                    } else {
                        sim = 0.0
                    }
                } else {
                    sim = 0.0
                }
            } else {
                let dist = minColorDistance(asset.dominantColors, effectiveColors)
                sim = dist.map { d -> Double in
                    if d <= colorTolerance { return 1.0 - (d / max(1.0, colorTolerance)) * 0.35 }
                    let cutoff = max(colorTolerance * 1.6, colorTolerance + 14.0)
                    guard d < cutoff else { return 0.0 }
                    return 0.25 * ((cutoff - d) / max(1.0, cutoff - colorTolerance))
                } ?? 0
            }
            signals.append((sim, targetColors.isEmpty ? 0.20 : 0.42, "色彩吻合"))
        }
        if !seeds.isEmpty {
            let tags = Set((asset.tags + asset.suggestedTags).map(SearchText.normalize))
            let overlap = seeds.map { seed -> Double in
                let peer = Set((seed.tags + seed.suggestedTags).map(SearchText.normalize))
                return Double(peer.intersection(tags).count) / Double(max(1, peer.union(tags).count))
            }.max() ?? 0
            signals.append((overlap, 0.16, "标签相近"))
        }

        let weightedSum = signals.reduce(0.0) { $0 + $1.0 * $1.1 }
        let capacity = max(0.35, signals.reduce(0.0) { $0 + $1.1 })
        let rating = Double(min(5, max(0, asset.rating))) / 5.0
        let finalScore: Double = signals.isEmpty
            ? (0.35 + 0.15 * rating)
            : min(1.0, 0.06 * rating + 0.94 * (weightedSum / capacity))
        let reasons = signals.filter { $0.0 > 0.25 }.sorted { $0.0 * $0.1 > $1.0 * $1.1 }.map { $0.2 }
        return ScoredAsset(asset: asset, score: finalScore, matchReasons: reasons)
    }

    private static func minColorDistance(_ a: [LabColor], _ b: [LabColor]) -> Double? {
        let validA = a.filter { $0.l.isFinite && $0.a.isFinite && $0.b.isFinite }
        let hasProps = validA.contains { $0.proportion > 0.001 }
        let majorA = hasProps ? validA.filter { $0.proportion >= 0.08 } : validA
        let srcA = majorA.isEmpty ? Array(validA.prefix(5)) : Array(majorA.prefix(5))
        return srcA.flatMap { lhs in b.map { lhs.deltaE2000(to: $0) } }.filter(\.isFinite).min()
    }

    private static func weightedPaletteDistance(_ candidate: [LabColor], _ target: [LabColor]) -> Double? {
        let validC = candidate.filter { $0.l.isFinite && $0.a.isFinite && $0.b.isFinite }
        let hasPropsC = validC.contains { $0.proportion > 0.001 }
        let a = hasPropsC ? Array(validC.filter { $0.proportion >= 0.08 }.prefix(3)) : Array(validC.prefix(3))
        let srcA = a.isEmpty ? Array(validC.prefix(3)) : a
        let srcB = Array(target.filter { $0.l.isFinite && $0.a.isFinite && $0.b.isFinite }.prefix(4))
        guard !srcA.isEmpty, !srcB.isEmpty else { return nil }
        var sum = 0.0
        var totalW = 0.0
        for swatch in srcA {
            guard let nearest = srcB.map({ swatch.deltaE2000(to: $0) }).filter(\.isFinite).min() else { continue }
            let w = swatch.proportion > 0.001 ? swatch.proportion : 1.0
            sum += nearest * w
            totalW += w
        }
        guard totalW > 0 else { return nil }
        return sum / totalW
    }

    private static func cosine(_ a: [Float], _ b: [Float]) -> Double {
        guard a.count == b.count else { return 0 }
        var dot = 0.0, aa = 0.0, bb = 0.0
        for i in a.indices {
            let x = Double(a[i]), y = Double(b[i])
            dot += x * y; aa += x * x; bb += y * y
        }
        guard aa > 0, bb > 0, dot.isFinite else { return 0 }
        return min(1, max(0, dot / sqrt(aa * bb)))
    }

    private static func uniqueStrings(_ input: [String]) -> [String] {
        var seen = Set<String>()
        return input.filter { seen.insert($0.lowercased()).inserted }
    }
}
