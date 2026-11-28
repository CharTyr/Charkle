import Foundation
import Testing
@testable import CharkleCore

@Suite("Inbox Version Stack Folder & Trash Atomicity Regression Tests")
struct InboxStackRegressionTests {

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

    private func makeThreeVersionInboxStack(
        in engine: LiveCharkleEngine,
        dir: URL,
        stem: String = "方案汇报"
    ) async throws -> (v1: AssetRecord, v2: AssetRecord, v3: AssetRecord, groupID: UUID) {
        let u1 = dir.appending(path: "\(stem)_v1.md")
        let u2 = dir.appending(path: "\(stem)_v2.md")
        let u3 = dir.appending(path: "\(stem)_v3.md")
        try Data("# \(stem)\n\n第一版初稿正文内容。".utf8).write(to: u1)
        try Data("# \(stem)\n\n第二版修订正文内容。".utf8).write(to: u2)
        try Data("# \(stem)\n\n第三版定稿正文内容。".utf8).write(to: u3)

        let imported = try await engine.ingest(
            [.fileURL(u1), .fileURL(u2), .fileURL(u3)],
            targetFolderID: nil,
            targetBoardID: nil
        )
        #expect(imported.count == 3)

        let stacked = try await engine.manageVersionStack(
            .create(
                assetIDs: imported.map(\.id),
                primaryAssetID: imported[2].id
            )
        )
        let sorted = AssetVersionStackMetadata.sortedVersions(stacked)
        #expect(sorted.count == 3)
        let gid = try #require(sorted[0].versionGroupID)
        return (sorted[0], sorted[1], sorted[2], gid)
    }

    // MARK: - Scenario A: Move Collapsed Stack Out of Inbox & Scope-Safe Folding

    @Test("Moving primary version of collapsed Inbox stack moves all siblings out of Inbox, zeroes inboxCount, and prevents ghost primary substitution")
    func moveCollapsedStackOutOfInbox() async throws {
        let dir = try BackendFixture.directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let engine = try BackendFixture.makeEngine(dir)

        let folderF = try await engine.createFolder(name: "已归档方案", parentID: nil)
        let stack = try await makeThreeVersionInboxStack(in: engine, dir: dir)

        // Stack-aware Inbox count treats the 3-version stack in Inbox as 1 collapsed item
        #expect(try await engine.inboxCount() == 1)
        #expect(stack.v3.versionStack?.isPinnedPrimary == true)

        let inboxCriteria = FilterCriteria(onlyInbox: true)
        let preMoveInboxRaw = try await engine.fetchAssets(matching: inboxCriteria)
        let preMoveFolded = AssetRecord.foldVersionStacks(
            preMoveInboxRaw,
            onlyTrashed: false,
            criteria: inboxCriteria,
            cachedPrimaryByGroupID: [stack.groupID: stack.v3]
        )
        #expect(preMoveFolded.map(\.id) == [stack.v3.id])

        // Mixed patch check: moving `[v3.id]` with an explicit `title` updates `v3.title` while moving all 3 siblings
        // to `folderF.id` without overwriting `v1.title` or `v2.title`!
        let updated = try await engine.updateAssets(
            AssetBatchPatch(
                assetIDs: [stack.v3.id],
                title: "方案汇报（定稿归档）",
                folderAssignment: .folder(folderF.id)
            )
        )
        #expect(updated.count == 3)

        let reloadedV1 = try #require(try await engine.fetchAsset(id: stack.v1.id))
        let reloadedV2 = try #require(try await engine.fetchAsset(id: stack.v2.id))
        let reloadedV3 = try #require(try await engine.fetchAsset(id: stack.v3.id))

        #expect(reloadedV1.folderID == folderF.id)
        #expect(reloadedV2.folderID == folderF.id)
        #expect(reloadedV3.folderID == folderF.id)
        #expect(reloadedV3.title == "方案汇报（定稿归档）")
        #expect(reloadedV1.title == stack.v1.title)
        #expect(reloadedV2.title == stack.v2.title)

        let postMoveInboxCount = try await engine.inboxCount()
        let postMoveInboxRaw = try await engine.fetchAssets(matching: inboxCriteria)
        let postMoveFoldedInbox = AssetRecord.foldVersionStacks(
            postMoveInboxRaw,
            onlyTrashed: false,
            criteria: inboxCriteria,
            cachedPrimaryByGroupID: [stack.groupID: reloadedV3]
        )
        #expect(postMoveInboxCount == 0)
        #expect(postMoveInboxRaw.isEmpty)
        #expect(postMoveFoldedInbox.isEmpty && postMoveInboxCount == 0)

        let inFolder = try await engine.fetchAssets(matching: FilterCriteria(folderID: folderF.id))
        #expect(Set(inFolder.map(\.id)) == Set([stack.v1.id, stack.v2.id, stack.v3.id]))

        // Verify scope-safe guard directly: even if a stale unfiled `v1` appeared in an `onlyInbox` slice while
        // `cachedPrimaryByGroupID` held a filed `reloadedV3` (`folderID == folderF.id`), `foldVersionStacks`
        // NEVER substitutes `reloadedV3` into Inbox; it falls back to in-list `v1`!
        var syntheticUnfiledV1 = reloadedV1
        syntheticUnfiledV1.folderID = nil
        let guardedInboxFold = AssetRecord.foldVersionStacks(
            [syntheticUnfiledV1],
            onlyTrashed: false,
            criteria: inboxCriteria,
            cachedPrimaryByGroupID: [stack.groupID: reloadedV3]
        )
        #expect(guardedInboxFold.map(\.id) == [syntheticUnfiledV1.id])
        #expect(guardedInboxFold.first?.folderID == nil)
    }

    // MARK: - Scenario B: Join / Create Version Stack Across Inbox + Folder

    @Test("Joining or creating a version stack across Inbox and a folder unifies all siblings into that folder")
    func joinAndCreateVersionStackAcrossInboxAndFolder() async throws {
        let dir = try BackendFixture.directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let engine = try BackendFixture.makeEngine(dir)

        let folderF = try await engine.createFolder(name: "合同定稿", parentID: nil)

        // Subcase B1: `v1` in Inbox (`folderID == nil`), `v2` in `folderF` (`folderID == folderF.id`) -> `.join`
        let joinU1 = dir.appending(path: "采购协议_v1.md")
        let joinU2 = dir.appending(path: "采购协议_v2.md")
        try Data("# 采购协议\n\n第一版条款。".utf8).write(to: joinU1)
        try Data("# 采购协议\n\n第二版核定条款。".utf8).write(to: joinU2)

        let joinV1 = try #require(try await engine.ingest([.fileURL(joinU1)], targetFolderID: nil, targetBoardID: nil).first)
        let joinV2 = try #require(try await engine.ingest([.fileURL(joinU2)], targetFolderID: folderF.id, targetBoardID: nil).first)
        #expect(joinV1.folderID == nil)
        #expect(joinV2.folderID == folderF.id)

        let joined = try await engine.manageVersionStack(
            .join(assetID: joinV2.id, targetAssetOrGroupID: joinV1.id, adoptTargetFolder: true)
        )
        #expect(joined.count == 2)
        for member in joined {
            let fresh = try #require(try await engine.fetchAsset(id: member.id))
            #expect(fresh.folderID == folderF.id)
        }
        #expect(try await engine.inboxCount() == 0)
        #expect(try await engine.fetchAssets(matching: FilterCriteria(onlyInbox: true)).isEmpty)

        // Subcase B2: `c1` in Inbox (`folderID == nil`), `c2` in `folderF` (`folderID == folderF.id`) -> `.create`
        let createU1 = dir.appending(path: "预算说明_v1.md")
        let createU2 = dir.appending(path: "预算说明_v2.md")
        try Data("# 预算说明\n\n初稿内容。".utf8).write(to: createU1)
        try Data("# 预算说明\n\n复核内容。".utf8).write(to: createU2)

        let createV1 = try #require(try await engine.ingest([.fileURL(createU1)], targetFolderID: nil, targetBoardID: nil).first)
        let createV2 = try #require(try await engine.ingest([.fileURL(createU2)], targetFolderID: folderF.id, targetBoardID: nil).first)

        let created = try await engine.manageVersionStack(
            .create(assetIDs: [createV1.id, createV2.id])
        )
        #expect(created.count == 2)
        for member in created {
            let fresh = try #require(try await engine.fetchAsset(id: member.id))
            #expect(fresh.folderID == folderF.id)
        }
        #expect(try await engine.inboxCount() == 0)
        #expect(try await engine.fetchAssets(matching: FilterCriteria(onlyInbox: true)).isEmpty)
    }

    // MARK: - Scenario C: Self-Healing Legacy Split Version Stack on Engine Init / Refresh

    @Test("LiveCharkleEngine automatically heals legacy split version stacks on startup / first query without losing unfiled siblings")
    func selfHealLegacySplitVersionStackOnInit() async throws {
        let dir = try BackendFixture.directory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let database = try LibraryDatabase()
        let media = try MediaPipeline(directory: dir)
        let folderF = FolderRecord(name: "历史项目归档", sortOrder: 0)
        try await database.upsertFolder(folderF)

        let groupID = UUID()
        let orphanGroupID = UUID()
        let missingFolderID = UUID()
        let baseDate = Date(timeIntervalSince1970: 1_735_000_000)

        let v1UnfiledActive = AssetRecord(
            title: "安全排查方案",
            fileName: "安全排查方案_v1.docx",
            folderID: nil,
            mediaKind: .document,
            isTrashed: false,
            createdAt: baseDate,
            richMetadata: AssetRichMetadata(
                versionStack: AssetVersionStackMetadata(groupID: groupID, versionNumber: 1)
            )
        )
        let v2FiledTrashed = AssetRecord(
            title: "安全排查方案",
            fileName: "安全排查方案_v2.docx",
            folderID: folderF.id,
            mediaKind: .document,
            isTrashed: true,
            createdAt: baseDate.addingTimeInterval(60),
            richMetadata: AssetRichMetadata(
                versionStack: AssetVersionStackMetadata(groupID: groupID, versionNumber: 2)
            )
        )
        let v3FiledTrashedPinned = AssetRecord(
            title: "安全排查方案",
            fileName: "安全排查方案_v3.docx",
            folderID: folderF.id,
            mediaKind: .document,
            isTrashed: true,
            createdAt: baseDate.addingTimeInterval(120),
            richMetadata: AssetRichMetadata(
                versionStack: AssetVersionStackMetadata(
                    groupID: groupID,
                    versionNumber: 3,
                    isPinnedPrimary: true
                )
            )
        )

        // Also verify safety guard: if a sibling points to a non-existent deleted folder ID, do NOT move unfiled item into nowhere!
        let orphanV1 = AssetRecord(
            title: "孤立目录测试",
            fileName: "孤立目录测试_v1.md",
            folderID: nil,
            mediaKind: .document,
            isTrashed: false,
            createdAt: baseDate,
            richMetadata: AssetRichMetadata(
                versionStack: AssetVersionStackMetadata(groupID: orphanGroupID, versionNumber: 1)
            )
        )
        let orphanV2 = AssetRecord(
            title: "孤立目录测试",
            fileName: "孤立目录测试_v2.md",
            folderID: missingFolderID,
            mediaKind: .document,
            isTrashed: true,
            createdAt: baseDate.addingTimeInterval(30),
            richMetadata: AssetRichMetadata(
                versionStack: AssetVersionStackMetadata(groupID: orphanGroupID, versionNumber: 2)
            )
        )

        try await database.upsertAssets([
            v1UnfiledActive,
            v2FiledTrashed,
            v3FiledTrashedPinned,
            orphanV1,
            orphanV2
        ])

        let engine = LiveCharkleEngine(database: database, media: media)

        // First query must deterministically self-heal the valid split stack (`groupID` -> `folderF.id`)
        // while leaving `orphanV1` safely in Inbox because `missingFolderID` does not exist in `folders`.
        #expect(try await engine.inboxCount() == 1)
        let remainingInbox = try await engine.fetchAssets(matching: FilterCriteria(onlyInbox: true))
        #expect(remainingInbox.map(\.id) == [orphanV1.id])

        let healedV1 = try #require(try await engine.fetchAsset(id: v1UnfiledActive.id))
        #expect(healedV1.folderID == folderF.id)
        #expect(healedV1.isTrashed == false)

        // Idempotent re-run produces zero additional writes
        let secondHeal = try await engine.healSplitVersionStacks()
        #expect(secondHeal.isEmpty)
    }

    // MARK: - Scenario D: Stack-Wide Trash & Restore + Surgical Override & Store Contracts

    @Test("Trashing or restoring a collapsed version stack updates all siblings atomically while supporting propagateToVersionStack=false")
    func stackWideTrashRestoreAndSurgicalOverride() async throws {
        let dir = try BackendFixture.directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let engine = try BackendFixture.makeEngine(dir)

        // Backward-compatible JSON decoding of legacy AssetBatchPatch payloads (without `propagateToVersionStack` key)
        let legacyJSON = Data("{\"assetIDs\":[]}".utf8)
        let decodedLegacy = try JSONDecoder().decode(AssetBatchPatch.self, from: legacyJSON)
        #expect(decodedLegacy.propagateToVersionStack == true)

        let stack = try await makeThreeVersionInboxStack(in: engine, dir: dir, stem: "待清理草稿")
        #expect(try await engine.inboxCount() == 1)

        // 1. Trash ONLY `[v3.id]` -> all 3 siblings must become `isTrashed == true` in one operation
        _ = try await engine.updateAssets(
            AssetBatchPatch(assetIDs: [stack.v3.id], isTrashed: true)
        )

        for id in [stack.v1.id, stack.v2.id, stack.v3.id] {
            let trashed = try #require(try await engine.fetchAsset(id: id))
            #expect(trashed.isTrashed == true)
        }
        #expect(try await engine.inboxCount() == 0)
        #expect(try await engine.fetchAssets(matching: FilterCriteria(onlyInbox: true)).isEmpty)

        // 2. Restore ONLY `[v3.id]` -> all 3 siblings must restore to `isTrashed == false`
        _ = try await engine.updateAssets(
            AssetBatchPatch(assetIDs: [stack.v3.id], isTrashed: false)
        )

        for id in [stack.v1.id, stack.v2.id, stack.v3.id] {
            let restored = try #require(try await engine.fetchAsset(id: id))
            #expect(restored.isTrashed == false)
        }
        #expect(try await engine.inboxCount() == 1)
        #expect(try await engine.fetchAssets(matching: FilterCriteria(onlyInbox: true)).count == 3)

        // 3. Explicit `propagateToVersionStack: false` allows surgical single-version updates
        _ = try await engine.updateAssets(
            AssetBatchPatch(
                assetIDs: [stack.v1.id],
                isTrashed: true,
                propagateToVersionStack: false
            )
        )
        #expect(try #require(try await engine.fetchAsset(id: stack.v1.id)).isTrashed == true)
        #expect(try #require(try await engine.fetchAsset(id: stack.v2.id)).isTrashed == false)
        #expect(try #require(try await engine.fetchAsset(id: stack.v3.id)).isTrashed == false)
        #expect(try await engine.inboxCount() == 1)

        // 4. `updateAssetsBatch` multi-patch path also honors stack propagation atomically
        let folderArchive = try await engine.createFolder(name: "批处理归档", parentID: nil)
        let secondStack = try await makeThreeVersionInboxStack(in: engine, dir: dir, stem: "批处理纪要")
        _ = try await engine.updateAssetsBatch([
            AssetBatchPatch(assetIDs: [stack.v3.id], isTrashed: false),
            AssetBatchPatch(assetIDs: [secondStack.v3.id], folderAssignment: .folder(folderArchive.id))
        ])
        #expect(try #require(try await engine.fetchAsset(id: stack.v1.id)).isTrashed == false)
        for id in [secondStack.v1.id, secondStack.v2.id, secondStack.v3.id] {
            #expect(try #require(try await engine.fetchAsset(id: id)).folderID == folderArchive.id)
        }

        // 5. Verify macOS LibraryStore & iOS MobileAppStore wire scope-safe stack folding and sibling selection cleanup
        let macStore = try readSource("Sources/CharkleApp/Stores/LibraryStore.swift")
        let iosStore = try readSource("ios/CharkleMobile/Stores/MobileAppStore.swift")
        #expect(macStore.contains("AssetRecord.foldVersionStacks("))
        #expect(macStore.contains("expandedStackAndTargetIDs(for: ids)"))
        #expect(macStore.contains("selectedAssetIDs.subtract(allAffected)"))
        #expect(macStore.contains("cutAssetIDs.subtract(allAffected)"))
        #expect(macStore.contains("copiedAssetIDs.removeAll { allAffected.contains($0) }"))
        #expect(iosStore.contains("isCompatibleWithActiveScope(primary)"))
    }
}
