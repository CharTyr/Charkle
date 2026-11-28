import Foundation

extension LiveCharkleEngine {
    // MARK: - 1. Version Stack Candidate Detection (<150ms)

    public func detectVersionStackCandidate(
        for fileURL: URL,
        targetFolderID: UUID?
    ) async throws -> VersionStackCandidate? {
        let parsedIncoming = await Self.inspectIncomingFileForStackOffActor(fileURL: fileURL)
        return try await matchVersionStackCandidate(
            incomingStem: parsedIncoming.stem,
            incomingKind: parsedIncoming.mediaKind,
            incomingSimHash: parsedIncoming.simhash64,
            incomingWordCount: parsedIncoming.wordCount,
            internalEditor: parsedIncoming.internalEditor,
            excludingAssetID: nil,
            preferredFolderID: targetFolderID
        )
    }

    public func detectVersionStackCandidate(
        forAssetID assetID: UUID
    ) async throws -> VersionStackCandidate? {
        guard let asset = try await database.asset(id: assetID), !asset.isTrashed else {
            return nil
        }
        let stemFromName = VersionStemNormalizer.normalize(fileNameOrTitle: asset.fileName)
        let stemFromTitle = VersionStemNormalizer.normalize(fileNameOrTitle: asset.title)
        let effectiveStem = stemFromName.canonicalStem.isEmpty ? stemFromTitle : stemFromName

        var simhash: Int64 = 0
        var wordCount = asset.richMetadata?.document?.wordCount ?? 0
        var internalEditor: String?
        if asset.mediaKind == .document {
            if let cached = try await database.cachedStructuredDocument(assetID: asset.id, expectedContentHash: asset.contentHash) {
                simhash = cached.simhash64
                wordCount = max(wordCount, cached.payload.wordCount)
                internalEditor = cached.payload.authorOrEditor
            } else if let orig = media.cachedOriginal(for: asset),
                      let parsed = try? await DocumentParserEngine.parse(fileURL: orig, assetID: asset.id, preferredTitle: asset.title) {
                simhash = parsed.simhash64
                wordCount = parsed.payload.wordCount
                internalEditor = parsed.payload.authorOrEditor
                try? await database.transaction { store in
                    try store.upsertDocumentContentCache(
                        assetID: asset.id,
                        contentHash: asset.contentHash,
                        payload: parsed.payload,
                        simhash64: parsed.simhash64
                    )
                }
            }
        }

        return try await matchVersionStackCandidate(
            incomingStem: effectiveStem,
            incomingKind: asset.mediaKind,
            incomingSimHash: simhash,
            incomingWordCount: wordCount,
            internalEditor: stemFromTitle.suggestedEditorName ?? internalEditor,
            excludingAssetID: asset.id,
            preferredFolderID: asset.folderID
        )
    }

    @concurrent
    private static func inspectIncomingFileForStackOffActor(
        fileURL: URL
    ) async -> (stem: NormalizedVersionStem, mediaKind: MediaKind, simhash64: Int64, wordCount: Int, internalEditor: String?) {
        let fileName = fileURL.lastPathComponent
        let ext = fileURL.pathExtension
        let kind = MediaKind.detect(fileExtension: ext)
        let stem = VersionStemNormalizer.normalize(fileNameOrTitle: fileName)

        guard kind == .document else {
            return (stem, kind, 0, 0, nil)
        }
        let accessed = fileURL.startAccessingSecurityScopedResource()
        defer { if accessed { fileURL.stopAccessingSecurityScopedResource() } }
        let fileSize = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard fileSize > 0, fileSize <= 32 * 1024 * 1024,
              let parsed = try? await DocumentParserEngine.parse(
                  fileURL: fileURL,
                  preferredTitle: stem.cleanDisplayTitle,
                  performOCRIfScanned: false
              ) else {
            return (stem, kind, 0, 0, nil)
        }
        return (stem, kind, parsed.simhash64, parsed.payload.wordCount, parsed.payload.authorOrEditor)
    }

    private func matchVersionStackCandidate(
        incomingStem: NormalizedVersionStem,
        incomingKind: MediaKind,
        incomingSimHash: Int64,
        incomingWordCount: Int,
        internalEditor: String?,
        excludingAssetID: UUID?,
        preferredFolderID: UUID?
    ) async throws -> VersionStackCandidate? {
        let allAssets = try await database.fetchAssets(matching: FilterCriteria(includeTrashed: false))
        let simhashesByID: [UUID: Int64] = (incomingKind == .document && incomingSimHash != 0)
            ? (try await database.documentSimHashes(excludingAssetID: excludingAssetID))
            : [:]

        var groups: [UUID: [AssetRecord]] = [:]
        for asset in allAssets where asset.id != excludingAssetID {
            if let excluded = excludingAssetID,
               let myGroup = allAssets.first(where: { $0.id == excluded })?.versionGroupID,
               asset.versionGroupID == myGroup {
                continue
            }
            guard Self.areMediaKindsStackCompatible(incomingKind, asset.mediaKind) else { continue }
            let key = asset.versionGroupID ?? asset.id
            groups[key, default: []].append(asset)
        }

        struct ScoredCandidate {
            let candidate: VersionStackCandidate
            let folderBonus: Int
            let recency: Date
        }

        var best: ScoredCandidate?
        let canUseSimHash = incomingKind == .document && incomingSimHash != 0 && incomingWordCount >= 12
        let cleanIncomingStem = incomingStem.canonicalStem

        for (_, members) in groups {
            guard let primary = AssetVersionStackMetadata.resolvePrimaryAsset(in: members) else { continue }
            let existingGroupID = members.compactMap(\.versionGroupID).first
            let maxVer = members.map { $0.versionStack?.versionNumber ?? 1 }.max() ?? 1

            var stemMatched = false
            if cleanIncomingStem.count >= 2 {
                for member in members {
                    let s1 = VersionStemNormalizer.normalize(fileNameOrTitle: member.fileName).canonicalStem
                    let s2 = VersionStemNormalizer.normalize(fileNameOrTitle: member.title).canonicalStem
                    if s1 == cleanIncomingStem || s2 == cleanIncomingStem {
                        stemMatched = true
                        break
                    }
                }
            }

            var bestSim = 0.0
            if canUseSimHash {
                for member in members {
                    if let sh = simhashesByID[member.id] {
                        bestSim = max(bestSim, DocumentSimHash.similarity(incomingSimHash, sh))
                    }
                }
            }

            let simMatched = canUseSimHash && bestSim >= 0.45
            guard stemMatched || simMatched else { continue }

            let reason: VersionStackCandidate.MatchReason
            let score: Double
            if stemMatched && simMatched {
                reason = .stemAndSimHash
                score = min(1.0, 0.92 + bestSim * 0.08)
            } else if stemMatched {
                reason = .exactStem
                score = 0.90
            } else {
                reason = .contentSimHash
                score = bestSim
            }

            let editor = incomingStem.suggestedEditorName?.nonEmptyTrimmed ?? internalEditor?.nonEmptyTrimmed
            let nextVer = maxVer + 1
            let label = editor.map { "v\(nextVer) · \($0)" } ?? "v\(nextVer)"
            let targetFolder = members.compactMap(\.folderID).first ?? preferredFolderID
            let displayBaseTitle = VersionStemNormalizer.normalize(fileNameOrTitle: primary.title).cleanDisplayTitle

            let candidate = VersionStackCandidate(
                targetGroupID: existingGroupID ?? primary.id,
                targetAssetID: primary.id,
                targetTitle: displayBaseTitle.isEmpty ? primary.title : displayBaseTitle,
                targetFolderID: targetFolder,
                nextVersionNumber: nextVer,
                suggestedEditorName: editor,
                suggestedVersionLabel: label,
                normalizedStem: cleanIncomingStem,
                similarityScore: score,
                matchReason: reason,
                existingStackExists: existingGroupID != nil
            )

            let folderBonus = (preferredFolderID != nil && targetFolder == preferredFolderID) ? 1 : 0
            let recency = members.map(\.updatedAt).max() ?? primary.updatedAt
            let scored = ScoredCandidate(candidate: candidate, folderBonus: folderBonus, recency: recency)

            if let currentBest = best {
                if scored.candidate.similarityScore > currentBest.candidate.similarityScore + 0.02 {
                    best = scored
                } else if abs(scored.candidate.similarityScore - currentBest.candidate.similarityScore) <= 0.02 {
                    if scored.folderBonus != currentBest.folderBonus {
                        if scored.folderBonus > currentBest.folderBonus { best = scored }
                    } else if scored.recency > currentBest.recency {
                        best = scored
                    }
                }
            } else {
                best = scored
            }
        }

        return best?.candidate
    }

    private static func areMediaKindsStackCompatible(_ a: MediaKind, _ b: MediaKind) -> Bool {
        if a == b { return true }
        let visualGroup: Set<MediaKind> = [.image, .animatedImage, .designFile]
        return visualGroup.contains(a) && visualGroup.contains(b)
    }

    // MARK: - 2. Version Stack Mutations & Auto Diff Summary

    public func manageVersionStack(
        _ mutation: VersionStackMutation
    ) async throws -> [AssetRecord] {
        switch mutation.action {
        case .join:
            return try await executeJoinVersionStack(mutation)
        case .create:
            return try await executeCreateVersionStack(mutation)
        case .setPrimary:
            return try await executeSetPrimaryVersion(mutation)
        case .unstack:
            return try await executeUnstackAssets(mutation)
        case .updateMeta:
            return try await executeUpdateVersionMeta(mutation)
        }
    }

    private func executeJoinVersionStack(_ mutation: VersionStackMutation) async throws -> [AssetRecord] {
        guard let targetKey = mutation.targetAssetOrGroupID else {
            throw LibraryDatabaseError("缺少目标版本叠或目标素材 ID。")
        }
        let joiningIDs = Self.deduplicatedUUIDs(mutation.assetIDs).filter { $0 != targetKey }
        guard !joiningIDs.isEmpty else {
            if let single = try await database.asset(id: targetKey) { return [single] }
            return []
        }

        let allActive = try await database.fetchAssets(matching: FilterCriteria(includeTrashed: true))
        var existingMembers = allActive.filter {
            !joiningIDs.contains($0.id) && ($0.versionGroupID == targetKey || $0.id == targetKey)
        }
        // If `targetKey` was an asset ID that already belongs to a larger `groupID`, pull in all siblings of that `groupID`!
        if let discoveredGroup = existingMembers.compactMap(\.versionGroupID).first {
            existingMembers = allActive.filter {
                !joiningIDs.contains($0.id) && $0.versionGroupID == discoveredGroup
            }
        }
        guard !existingMembers.isEmpty else {
            throw DriveTransportError.fileNotFound(targetKey.uuidString)
        }

        let groupID = existingMembers.compactMap(\.versionGroupID).first ?? UUID()
        let orderedExisting = AssetVersionStackMetadata.sortedVersions(existingMembers)
        let targetFolderID = orderedExisting.compactMap(\.folderID).first
        var previousTip = orderedExisting.last!
        let maxVersion = orderedExisting.map { $0.versionStack?.versionNumber ?? 1 }.max() ?? 1

        // Precompute DocumentDiffSummary off-transaction against the previous version
        var computedDiffByJoiningID: [UUID: DocumentDiffSummary] = [:]
        var inferredEditorByJoiningID: [UUID: String] = [:]
        for joinID in joiningIDs {
            guard let joinAsset = try await database.asset(id: joinID) else { continue }
            if joinAsset.mediaKind == .document && previousTip.mediaKind == .document {
                if let report = try? await compareDocumentVersions(
                    baseAssetID: previousTip.id,
                    targetAssetID: joinAsset.id,
                    sheetName: nil,
                    primaryKeyCol: nil,
                    useOCRIfScanned: false
                ) {
                    computedDiffByJoiningID[joinID] = report.summary
                }
            }
            if mutation.editorName?.nonEmptyTrimmed == nil {
                let stemEditor = VersionStemNormalizer.normalize(fileNameOrTitle: joinAsset.fileName).suggestedEditorName
                if let stemEditor {
                    inferredEditorByJoiningID[joinID] = stemEditor
                } else if joinAsset.mediaKind == .document,
                          let payload = try? await readStructuredDocument(assetID: joinAsset.id),
                          let docEditor = payload.authorOrEditor?.nonEmptyTrimmed {
                    inferredEditorByJoiningID[joinID] = docEditor
                }
            }
            previousTip = joinAsset
        }

        let initialMaxVersion = maxVersion
        let diffSnapshot = computedDiffByJoiningID
        let editorSnapshot = inferredEditorByJoiningID

        let updatedStack = try await database.transaction { store -> [AssetRecord] in
            var savedMembers: [AssetRecord] = []
            let shouldClearExistingPins = mutation.pinAsPrimary
            var runningMaxVersion = initialMaxVersion

            // 1. Ensure existing standalone target has `v1` metadata, and preserve any existing `isPinnedPrimary`!
            for existing in orderedExisting {
                guard var latest = try store.asset(id: existing.id) else { continue }
                var rich = latest.richMetadata ?? AssetRichMetadata()
                var changed = false
                if var stack = rich.versionStack {
                    if shouldClearExistingPins && stack.isPinnedPrimary {
                        stack.isPinnedPrimary = false
                        rich.versionStack = stack
                        changed = true
                    }
                } else {
                    let stemInfo = VersionStemNormalizer.normalize(fileNameOrTitle: latest.fileName)
                    rich.versionStack = AssetVersionStackMetadata(
                        groupID: groupID,
                        versionNumber: 1,
                        parentAssetID: nil,
                        versionLabel: "v1",
                        editorName: stemInfo.suggestedEditorName,
                        changeNote: nil,
                        isPinnedPrimary: false
                    )
                    changed = true
                }
                if changed {
                    latest.richMetadata = rich
                    savedMembers.append(try store.saveAssetLocally(latest))
                } else {
                    savedMembers.append(latest)
                }
            }

            // 2. Append joining asset(s) as `vN+1`, adopting target folder if requested
            var parentID = savedMembers.last?.id
            for (idx, joinID) in joiningIDs.enumerated() {
                guard var joining = try store.asset(id: joinID) else { continue }
                runningMaxVersion += 1
                if mutation.adoptTargetFolder, let targetFolderID, joining.folderID != targetFolderID {
                    joining.folderID = targetFolderID
                }
                let editor = mutation.editorName?.nonEmptyTrimmed ?? editorSnapshot[joinID]
                let note = mutation.changeNote?.nonEmptyTrimmed
                let customLabel = mutation.versionLabel?.nonEmptyTrimmed
                let pinThis = mutation.pinAsPrimary && (idx == joiningIDs.count - 1)

                var rich = joining.richMetadata ?? AssetRichMetadata()
                rich.versionStack = AssetVersionStackMetadata(
                    groupID: groupID,
                    versionNumber: runningMaxVersion,
                    parentAssetID: parentID,
                    versionLabel: customLabel,
                    editorName: editor,
                    changeNote: note,
                    isPinnedPrimary: pinThis
                )
                if let diffSummary = diffSnapshot[joinID] {
                    var docMeta = rich.document ?? DocumentRichMetadata(
                        formatFamily: DocumentFormatFamily.detect(fileExtension: (joining.fileName as NSString).pathExtension).rawValue
                    )
                    docMeta.diffSummary = diffSummary
                    rich.document = docMeta
                }
                joining.richMetadata = rich
                let saved = try store.saveAssetLocally(joining)
                savedMembers.append(saved)
                parentID = saved.id
            }

            return AssetVersionStackMetadata.sortedVersions(savedMembers)
        }

        await refreshDocumentVersionPostersIfNeeded(updatedStack)
        return try await reloadStackAssets(ids: updatedStack.map(\.id))
    }

    private func executeCreateVersionStack(_ mutation: VersionStackMutation) async throws -> [AssetRecord] {
        let uniqueIDs = Self.deduplicatedUUIDs(mutation.assetIDs)
        guard !uniqueIDs.isEmpty else { return [] }

        var fetched: [AssetRecord] = []
        for id in uniqueIDs {
            if let a = try await database.asset(id: id) { fetched.append(a) }
        }
        guard !fetched.isEmpty else { return [] }

        // Sort chronologically when creation timestamps differ meaningfully (>1s) or explicit version hints exist;
        // otherwise preserve caller's supplied order.
        let orderedInput = Self.orderAssetsForInitialStack(fetched, suppliedOrder: uniqueIDs)
        let groupID = UUID()
        let targetFolder = orderedInput.compactMap(\.folderID).first

        var diffsByID: [UUID: DocumentDiffSummary] = [:]
        if orderedInput.count >= 2 {
            for idx in 1..<orderedInput.count {
                let prev = orderedInput[idx - 1]
                let curr = orderedInput[idx]
                if prev.mediaKind == .document && curr.mediaKind == .document,
                   let report = try? await compareDocumentVersions(
                       baseAssetID: prev.id,
                       targetAssetID: curr.id,
                       sheetName: nil,
                       primaryKeyCol: nil,
                       useOCRIfScanned: false
                   ) {
                    diffsByID[curr.id] = report.summary
                }
            }
        }

        let createDiffSnapshot = diffsByID
        let updated = try await database.transaction { store -> [AssetRecord] in
            var saved: [AssetRecord] = []
            for (idx, item) in orderedInput.enumerated() {
                guard var latest = try store.asset(id: item.id) else { continue }
                if mutation.adoptTargetFolder, let targetFolder, latest.folderID == nil {
                    latest.folderID = targetFolder
                }
                let stemInfo = VersionStemNormalizer.normalize(fileNameOrTitle: latest.fileName)
                let isLast = (idx == orderedInput.count - 1)
                var rich = latest.richMetadata ?? AssetRichMetadata()
                rich.versionStack = AssetVersionStackMetadata(
                    groupID: groupID,
                    versionNumber: idx + 1,
                    parentAssetID: idx > 0 ? orderedInput[idx - 1].id : nil,
                    versionLabel: nil,
                    editorName: (isLast ? mutation.editorName?.nonEmptyTrimmed : nil) ?? stemInfo.suggestedEditorName,
                    changeNote: isLast ? mutation.changeNote?.nonEmptyTrimmed : nil,
                    isPinnedPrimary: mutation.primaryAssetID == latest.id
                )
                if let diff = createDiffSnapshot[latest.id] {
                    var docMeta = rich.document ?? DocumentRichMetadata(
                        formatFamily: DocumentFormatFamily.detect(fileExtension: (latest.fileName as NSString).pathExtension).rawValue
                    )
                    docMeta.diffSummary = diff
                    rich.document = docMeta
                }
                latest.richMetadata = rich
                saved.append(try store.saveAssetLocally(latest))
            }
            return AssetVersionStackMetadata.sortedVersions(saved)
        }

        await refreshDocumentVersionPostersIfNeeded(updated)
        return try await reloadStackAssets(ids: updated.map(\.id))
    }

    private func executeSetPrimaryVersion(_ mutation: VersionStackMutation) async throws -> [AssetRecord] {
        guard let primaryID = mutation.primaryAssetID ?? mutation.assetIDs.first,
              let target = try await database.asset(id: primaryID) else {
            return []
        }
        let groupID = target.versionGroupID ?? UUID()
        let allAssets = try await database.fetchAssets(matching: FilterCriteria(includeTrashed: true))
        let siblings = allAssets.filter { $0.versionGroupID == groupID || $0.id == primaryID }

        let updated = try await database.transaction { store -> [AssetRecord] in
            var saved: [AssetRecord] = []
            for sibling in siblings {
                guard var latest = try store.asset(id: sibling.id) else { continue }
                var rich = latest.richMetadata ?? AssetRichMetadata()
                var stack = rich.versionStack ?? AssetVersionStackMetadata(groupID: groupID, versionNumber: 1)
                let shouldPin = (latest.id == primaryID)
                if stack.isPinnedPrimary != shouldPin || rich.versionStack == nil {
                    stack.isPinnedPrimary = shouldPin
                    rich.versionStack = stack
                    latest.richMetadata = rich
                    saved.append(try store.saveAssetLocally(latest))
                } else {
                    saved.append(latest)
                }
            }
            return AssetVersionStackMetadata.sortedVersions(saved)
        }

        await refreshDocumentVersionPostersIfNeeded(updated)
        return try await reloadStackAssets(ids: updated.map(\.id))
    }

    private func executeUnstackAssets(_ mutation: VersionStackMutation) async throws -> [AssetRecord] {
        let removeIDs = Set(mutation.assetIDs)
        guard !removeIDs.isEmpty else { return [] }

        let allAssets = try await database.fetchAssets(matching: FilterCriteria(includeTrashed: true))
        let affectedGroupIDs = Set(allAssets.filter { removeIDs.contains($0.id) }.compactMap(\.versionGroupID))

        let updated = try await database.transaction { store -> [AssetRecord] in
            var out: [AssetRecord] = []
            for id in mutation.assetIDs {
                guard var asset = try store.asset(id: id) else { continue }
                var rich = asset.richMetadata ?? AssetRichMetadata()
                rich.versionStack = nil
                if var doc = rich.document {
                    doc.diffSummary = nil
                    rich.document = doc
                }
                asset.richMetadata = rich
                out.append(try store.saveAssetLocally(asset))
            }

            // Clean up lone 1-item residual stack if unstacking left a single unpinned v1 item
            for gid in affectedGroupIDs {
                let remaining = allAssets.filter { !removeIDs.contains($0.id) && $0.versionGroupID == gid }
                if remaining.count == 1,
                   let soleID = remaining.first?.id,
                   var sole = try store.asset(id: soleID),
                   sole.versionStack?.isPinnedPrimary != true,
                   sole.versionStack?.changeNote?.nonEmptyTrimmed == nil {
                    var rich = sole.richMetadata ?? AssetRichMetadata()
                    rich.versionStack = nil
                    if var doc = rich.document {
                        doc.diffSummary = nil
                        rich.document = doc
                    }
                    sole.richMetadata = rich
                    out.append(try store.saveAssetLocally(sole))
                }
            }
            return out
        }

        await refreshDocumentVersionPostersIfNeeded(updated)
        return try await reloadStackAssets(ids: updated.map(\.id))
    }

    private func executeUpdateVersionMeta(_ mutation: VersionStackMutation) async throws -> [AssetRecord] {
        let targetIDs = Self.deduplicatedUUIDs(mutation.assetIDs)
        guard !targetIDs.isEmpty else { return [] }

        let updated = try await database.transaction { store -> [AssetRecord] in
            var changedGroups = Set<UUID>()
            var directSaved: [AssetRecord] = []

            for id in targetIDs {
                guard var asset = try store.asset(id: id) else { continue }
                var rich = asset.richMetadata ?? AssetRichMetadata()
                var stack = rich.versionStack ?? AssetVersionStackMetadata(groupID: UUID(), versionNumber: 1)
                if let label = mutation.versionLabel {
                    stack.versionLabel = label.nonEmptyTrimmed
                }
                if let editor = mutation.editorName {
                    stack.editorName = editor.nonEmptyTrimmed
                }
                if let note = mutation.changeNote {
                    stack.changeNote = note.nonEmptyTrimmed
                }
                rich.versionStack = stack
                asset.richMetadata = rich
                let saved = try store.saveAssetLocally(asset)
                directSaved.append(saved)
                changedGroups.insert(stack.groupID)
            }

            if changedGroups.count == 1, let gid = changedGroups.first {
                let all = try store.fetchAssets(matching: FilterCriteria(includeTrashed: true))
                let siblings = all.filter { $0.versionGroupID == gid }
                if !siblings.isEmpty {
                    return AssetVersionStackMetadata.sortedVersions(siblings)
                }
            }
            return directSaved
        }

        await refreshDocumentVersionPostersIfNeeded(updated)
        return try await reloadStackAssets(ids: updated.map(\.id))
    }

    private func refreshDocumentVersionPostersIfNeeded(_ assets: [AssetRecord]) async {
        let currentSync = await syncConfig()
        for var asset in assets where asset.mediaKind == .document {
            let ext = (asset.fileName as NSString).pathExtension.lowercased()
            guard ext != "pdf" else { continue }

            // Never clobber rich-layout / Office page thumbnails with procedural `documentCard`:
            // preserve existing `QLThumbnailGenerator` page renders, or upgrade legacy `900x1240` procedural posters when original is cached.
            if MediaPipeline.isRichLayoutDocumentExtension(ext) {
                let hasRealPageThumb = media.thumbnailURL(for: asset.id, tier: .grid520) != nil
                    && !(asset.pixelWidth == 900 && asset.pixelHeight == 1_240)
                if hasRealPageThumb {
                    continue
                }
                guard let localOriginal = media.cachedOriginal(for: asset),
                      let ql = await MediaPipeline.quickLook(localOriginal, scale: 2),
                      ql.width >= 160, ql.height >= 160 else {
                    continue
                }
                do {
                    try media.writeCustomPoster(ql.poster, for: &asset)
                    let newW = asset.pixelWidth
                    let newH = asset.pixelHeight
                    let newColors = asset.dominantColors
                    let id = asset.id
                    _ = try await database.transaction { store -> AssetRecord? in
                        guard var latest = try store.asset(id: id) else { return nil }
                        latest.pixelWidth = newW
                        latest.pixelHeight = newH
                        latest.dominantColors = newColors
                        let saved = try store.saveAssetLocally(latest)
                        if currentSync.syncThumbnails {
                            try store.markProjection("thumbnails", id: id)
                        }
                        return saved
                    }
                } catch {
                    continue
                }
                continue
            }

            let cached = try? await database.cachedStructuredDocument(assetID: asset.id, expectedContentHash: asset.contentHash)
            guard let card = MediaArtwork.documentCard(
                title: asset.title,
                fileExtension: ext,
                payload: cached?.payload,
                firstPageImage: nil,
                versionStack: asset.versionStack
            ) else { continue }
            do {
                try media.writeCustomPoster(card, for: &asset)
                let newW = asset.pixelWidth
                let newH = asset.pixelHeight
                let newColors = asset.dominantColors
                let id = asset.id
                _ = try await database.transaction { store -> AssetRecord? in
                    guard var latest = try store.asset(id: id) else { return nil }
                    latest.pixelWidth = newW
                    latest.pixelHeight = newH
                    latest.dominantColors = newColors
                    let saved = try store.saveAssetLocally(latest)
                    if currentSync.syncThumbnails {
                        try store.markProjection("thumbnails", id: id)
                    }
                    return saved
                }
            } catch {
                continue
            }
        }
    }

    /// Idempotent startup migration that scans active rich-layout / Office `.document` assets still carrying
    /// legacy procedural `900x1240` dimensions (or missing grid thumbnails), re-renders them via `MediaPipeline.refreshed`
    /// (`QLThumbnailGenerator` true page raster), and persists updated `pixelWidth`/`pixelHeight`/`dominantColors`.
    public func upgradeLegacyOfficeDocumentThumbnailsIfNeeded() async -> [UUID] {
        guard !isUpgradingOfficeThumbnails else { return [] }
        isUpgradingOfficeThumbnails = true
        defer { isUpgradingOfficeThumbnails = false }

        guard let docAssets = try? await database.fetchAssets(
            matching: FilterCriteria(kinds: [.document], includeTrashed: false)
        ) else {
            return []
        }

        let candidates = docAssets.filter { asset in
            guard !attemptedOfficeThumbnailUpgradeIDs.contains(asset.id) else { return false }
            let ext = (asset.fileName as NSString).pathExtension.lowercased()
            guard MediaPipeline.isRichLayoutDocumentExtension(ext) else { return false }
            let isLegacyProceduralSize = (asset.pixelWidth == 900 && asset.pixelHeight == 1_240)
            let isMissingThumb = media.thumbnailURL(for: asset.id, tier: .grid520) == nil
            return isLegacyProceduralSize || isMissingThumb
        }
        guard !candidates.isEmpty else { return [] }

        let currentSync = await syncConfig()
        var upgradedIDs: [UUID] = []

        for candidate in candidates {
            guard !Task.isCancelled else { break }
            attemptedOfficeThumbnailUpgradeIDs.insert(candidate.id)
            guard let localOriginal = media.cachedOriginal(for: candidate) else { continue }
            do {
                let reRendered = try await media.refreshed(candidate, from: localOriginal)
                guard !(reRendered.pixelWidth == 900 && reRendered.pixelHeight == 1_240) else {
                    continue
                }
                let id = candidate.id
                let newW = reRendered.pixelWidth
                let newH = reRendered.pixelHeight
                let newColors = reRendered.dominantColors
                let saved = try await database.transaction { store -> AssetRecord? in
                    guard var latest = try store.asset(id: id) else { return nil }
                    latest.pixelWidth = newW
                    latest.pixelHeight = newH
                    latest.dominantColors = newColors
                    let updated = try store.saveAssetLocally(latest)
                    if currentSync.syncThumbnails {
                        try store.markProjection("thumbnails", id: id)
                    }
                    return updated
                }
                if let saved {
                    upgradedIDs.append(saved.id)
                }
            } catch {
                continue
            }
        }
        return upgradedIDs
    }

    private func reloadStackAssets(ids: [UUID]) async throws -> [AssetRecord] {
        let fetched = try await database.assets(ids: ids)
        let byID = Dictionary(uniqueKeysWithValues: fetched.map { ($0.id, $0) })
        return ids.compactMap { byID[$0] }
    }

    private static func deduplicatedUUIDs(_ ids: [UUID]) -> [UUID] {
        var seen = Set<UUID>()
        return ids.filter { seen.insert($0).inserted }
    }

    private static func orderAssetsForInitialStack(
        _ assets: [AssetRecord],
        suppliedOrder: [UUID]
    ) -> [AssetRecord] {
        let posByID = Dictionary(uniqueKeysWithValues: suppliedOrder.enumerated().map { ($0.element, $0.offset) })
        let hints = Dictionary(uniqueKeysWithValues: assets.map {
            ($0.id, VersionStemNormalizer.normalize(fileNameOrTitle: $0.fileName).explicitVersionHint)
        })
        let hasDistinctHints = Set(hints.values.compactMap { $0 }).count >= 2
        let minDate = assets.map(\.createdAt).min() ?? .now
        let maxDate = assets.map(\.createdAt).max() ?? .now
        let hasDistinctDates = maxDate.timeIntervalSince(minDate) > 1.5

        return assets.sorted { lhs, rhs in
            if hasDistinctHints, let lh = hints[lhs.id] ?? nil, let rh = hints[rhs.id] ?? nil, lh != rh {
                return lh < rh
            }
            if hasDistinctDates && abs(lhs.createdAt.timeIntervalSince(rhs.createdAt)) > 1.5 {
                return lhs.createdAt < rhs.createdAt
            }
            return (posByID[lhs.id] ?? 0) < (posByID[rhs.id] ?? 0)
        }
    }

    // MARK: - 3. Structured Document Reader

    public func readStructuredDocument(
        assetID: UUID
    ) async throws -> StructuredDocumentPayload {
        guard let asset = try await database.asset(id: assetID) else {
            throw DriveTransportError.fileNotFound(assetID.uuidString)
        }

        if let cached = try await database.cachedStructuredDocument(
            assetID: asset.id,
            expectedContentHash: asset.contentHash
        ) {
            var payload = cached.payload
            payload.title = asset.title
            if payload.authorOrEditor == nil {
                payload.authorOrEditor = asset.versionStack?.editorName
            }
            return payload
        }

        let fileURL: URL
        if let local = media.cachedOriginal(for: asset) {
            fileURL = local
        } else {
            fileURL = try await originalURL(for: asset.id)
        }

        var parsed = try await DocumentParserEngine.parse(
            fileURL: fileURL,
            assetID: asset.id,
            preferredTitle: asset.title,
            performOCRIfScanned: false
        )
        parsed.payload.assetID = asset.id
        parsed.payload.title = asset.title
        if parsed.payload.authorOrEditor == nil {
            parsed.payload.authorOrEditor = asset.versionStack?.editorName
        }

        let finalBundle = parsed
        try await database.transaction { store in
            try store.upsertDocumentContentCache(
                assetID: asset.id,
                contentHash: asset.contentHash,
                payload: finalBundle.payload,
                simhash64: finalBundle.simhash64
            )
            if var latest = try store.asset(id: asset.id), latest.richMetadata?.document == nil {
                var rich = latest.richMetadata ?? AssetRichMetadata()
                rich.document = finalBundle.richMetadata
                if !finalBundle.payload.plainText.isEmpty && rich.textExcerpt == nil {
                    rich.textExcerpt = String(finalBundle.payload.plainText.prefix(1_200))
                }
                latest.richMetadata = rich
                _ = try store.saveAssetLocally(latest)
            }
        }
        return finalBundle.payload
    }

    // MARK: - 4. Multi-Modal Document Version Diff

    public func compareDocumentVersions(
        baseAssetID: UUID,
        targetAssetID: UUID,
        sheetName: String? = nil,
        primaryKeyCol: Int? = nil,
        useOCRIfScanned: Bool = false
    ) async throws -> DocumentComparisonReport {
        async let baseTask = loadPayloadForComparison(assetID: baseAssetID, useOCRIfScanned: useOCRIfScanned)
        async let targetTask = loadPayloadForComparison(assetID: targetAssetID, useOCRIfScanned: useOCRIfScanned)
        let (baseLoaded, targetLoaded) = try await (baseTask, targetTask)

        return DocumentDiffEngine.compare(
            base: baseLoaded.payload,
            target: targetLoaded.payload,
            sheetName: sheetName,
            primaryKeyCol: primaryKeyCol,
            usedOCR: baseLoaded.didRunOCR || targetLoaded.didRunOCR
        )
    }

    private func loadPayloadForComparison(
        assetID: UUID,
        useOCRIfScanned: Bool
    ) async throws -> (payload: StructuredDocumentPayload, didRunOCR: Bool) {
        let payload = try await readStructuredDocument(assetID: assetID)
        guard useOCRIfScanned,
              !payload.hasTextLayer,
              payload.blocks.isEmpty,
              payload.formatFamily == DocumentFormatFamily.pdf.rawValue,
              let asset = try await database.asset(id: assetID) else {
            return (payload, false)
        }

        let fileURL: URL
        if let local = media.cachedOriginal(for: asset) {
            fileURL = local
        } else {
            fileURL = try await originalURL(for: assetID)
        }

        var ocrPayload = await DocumentParserEngine.ocrScannedPDF(
            url: fileURL,
            assetID: assetID,
            fallbackTitle: asset.title
        )
        ocrPayload.title = asset.title
        if !ocrPayload.plainText.isEmpty {
            let simhash = DocumentSimHash.compute64(for: ocrPayload)
            let cachedCopy = ocrPayload
            try? await database.transaction { store in
                try store.upsertDocumentContentCache(
                    assetID: assetID,
                    contentHash: asset.contentHash,
                    payload: cachedCopy,
                    simhash64: simhash
                )
            }
        }
        return (ocrPayload, !ocrPayload.blocks.isEmpty)
    }

    // MARK: - 5. Scheme B Safe 2-Way Document Synthesis (`vN+1`)

    public func synthesizeDocumentVersion(
        baseAssetID: UUID,
        targetAssetID: UUID,
        preferTargetAsTemplate: Bool = true,
        decisions: [DocumentMergeDecision],
        editorName: String? = nil,
        changeNote: String? = nil
    ) async throws -> AssetRecord {
        guard let baseAsset = try await database.asset(id: baseAssetID) else {
            throw DriveTransportError.fileNotFound(baseAssetID.uuidString)
        }
        guard let targetAsset = try await database.asset(id: targetAssetID) else {
            throw DriveTransportError.fileNotFound(targetAssetID.uuidString)
        }

        let report = try await compareDocumentVersions(
            baseAssetID: baseAssetID,
            targetAssetID: targetAssetID,
            sheetName: nil,
            primaryKeyCol: nil,
            useOCRIfScanned: false
        )
        guard report.canSynthesizeTwoWay else {
            throw DocumentSynthesisError.unsupportedFormat(
                report.synthesisUnavailableReason ?? report.formatFamily
            )
        }

        let baseFileURL = if let local = media.cachedOriginal(for: baseAsset) {
            local
        } else {
            try await originalURL(for: baseAssetID)
        }
        let targetFileURL = if let local = media.cachedOriginal(for: targetAsset) {
            local
        } else {
            try await originalURL(for: targetAssetID)
        }

        let templateAsset = preferTargetAsTemplate ? targetAsset : baseAsset
        let ext = (templateAsset.fileName as NSString).pathExtension.lowercased()
        let stemInfo = VersionStemNormalizer.normalize(fileNameOrTitle: templateAsset.title)
        let cleanTitle = stemInfo.cleanDisplayTitle.isEmpty ? templateAsset.title : stemInfo.cleanDisplayTitle

        let existingGroupID = targetAsset.versionGroupID ?? baseAsset.versionGroupID
        let allAssets = try await database.fetchAssets(matching: FilterCriteria(includeTrashed: true))
        let currentSiblings: [AssetRecord] = if let gid = existingGroupID {
            allAssets.filter { $0.versionGroupID == gid }
        } else {
            [baseAsset, targetAsset]
        }
        let nextVer = (currentSiblings.map { $0.versionStack?.versionNumber ?? 1 }.max() ?? 1) + 1

        let stagingDir = media.staging.appending(path: "doc-synth-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: stagingDir) }

        let safeBaseName = MediaPipeline.cleanName("\(cleanTitle)_v\(nextVer)")
        let outputFileName = ext.isEmpty ? safeBaseName : "\(safeBaseName).\(ext)"
        let outputURL = stagingDir.appending(path: outputFileName)

        try await Self.runTwoWaySynthesizeOffActor(
            baseFileURL: baseFileURL,
            targetFileURL: targetFileURL,
            report: report,
            preferTargetAsTemplate: preferTargetAsTemplate,
            decisions: decisions,
            outputURL: outputURL
        )

        let owningFolderID = targetAsset.folderID ?? baseAsset.folderID
        let imported = try await ingest([.fileURL(outputURL)], targetFolderID: owningFolderID, targetBoardID: nil)
        guard let created = imported.first else {
            throw LibraryDatabaseError("合成新版本入库失败。")
        }

        // Ensure base & target form a stack first if they were standalone assets
        var stackTargetKey = existingGroupID ?? targetAsset.id
        if existingGroupID == nil {
            let formed = try await manageVersionStack(.create(assetIDs: [baseAsset.id, targetAsset.id]))
            stackTargetKey = formed.first?.versionGroupID ?? targetAsset.id
        }

        let resolvedNote = changeNote?.nonEmptyTrimmed ?? "基于差异审阅合成"
        let updatedStack = try await manageVersionStack(
            .join(
                assetID: created.id,
                targetAssetOrGroupID: stackTargetKey,
                editorName: editorName?.nonEmptyTrimmed,
                changeNote: resolvedNote,
                versionLabel: nil,
                pinAsPrimary: false,
                adoptTargetFolder: true
            )
        )
        var joinedCreated = updatedStack.first(where: { $0.id == created.id }) ?? created

        // Guarantee `diffSummary` is computed and attached against the immediately preceding stack version
        // (or against `baseAsset` when `vN+1` matches `previousTip` identically) so Revision Rail shows `Δ X处`.
        let ordered = AssetVersionStackMetadata.sortedVersions(updatedStack)
        if let myIdx = ordered.firstIndex(where: { $0.id == joinedCreated.id }), myIdx > 0 {
            let prevVer = ordered[myIdx - 1]
            let currentDiff = joinedCreated.richMetadata?.document?.diffSummary
            if currentDiff == nil || (currentDiff?.totalChangedBlocks == 0 && prevVer.id != baseAsset.id) {
                var resolvedSummary = currentDiff
                if resolvedSummary == nil,
                   let vsPrev = try? await compareDocumentVersions(
                       baseAssetID: prevVer.id,
                       targetAssetID: joinedCreated.id,
                       sheetName: nil,
                       primaryKeyCol: nil,
                       useOCRIfScanned: false
                   ) {
                    resolvedSummary = vsPrev.summary
                }
                if (resolvedSummary?.totalChangedBlocks ?? 0) == 0,
                   prevVer.id != baseAsset.id,
                   let vsBase = try? await compareDocumentVersions(
                       baseAssetID: baseAsset.id,
                       targetAssetID: joinedCreated.id,
                       sheetName: nil,
                       primaryKeyCol: nil,
                       useOCRIfScanned: false
                   ),
                   vsBase.summary.totalChangedBlocks > 0 {
                    resolvedSummary = vsBase.summary
                }
                if let summaryToAttach = resolvedSummary, summaryToAttach != currentDiff {
                    let targetID = joinedCreated.id
                    if let savedWithDiff = try? await database.transaction({ store -> AssetRecord? in
                        guard var latest = try store.asset(id: targetID) else { return nil }
                        var rich = latest.richMetadata ?? AssetRichMetadata()
                        var docMeta = rich.document ?? DocumentRichMetadata(
                            formatFamily: DocumentFormatFamily.detect(
                                fileExtension: (latest.fileName as NSString).pathExtension
                            ).rawValue
                        )
                        docMeta.diffSummary = summaryToAttach
                        rich.document = docMeta
                        latest.richMetadata = rich
                        return try store.saveAssetLocally(latest)
                    }) {
                        joinedCreated = savedWithDiff
                    }
                }
            }
        }
        return joinedCreated
    }

    @concurrent
    private static func runTwoWaySynthesizeOffActor(
        baseFileURL: URL,
        targetFileURL: URL,
        report: DocumentComparisonReport,
        preferTargetAsTemplate: Bool,
        decisions: [DocumentMergeDecision],
        outputURL: URL
    ) async throws {
        try DocumentTwoWaySynthesizer.synthesize(
            baseFileURL: baseFileURL,
            targetFileURL: targetFileURL,
            report: report,
            preferTargetAsTemplate: preferTargetAsTemplate,
            decisions: decisions,
            to: outputURL
        )
    }
}
