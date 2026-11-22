import Foundation

/// Multi-stage, verifiable **Moodboard Curator Agent Harness**:
/// 1. Library Overview & Brief Planning (large libraries > 32 assets)
/// 2. Multi-Route Grounded Candidate Recall (100% recall for libraries ≤ 32 assets)
/// 3. Progressive Visual Inspection via Numbered Contact Sheets (`#01`..`#32`)
/// 4. Deterministic Verification + 1-Turn Auto-Repair + Lazy Visual Insight Caching
/// 5. Strict-Threshold Offline Fallback (never pads unrelated images)
private actor AgentTraceRecorder {
    private var steps: [MoodboardAgentStep] = []
    private let onStep: (@Sendable (MoodboardAgentStep) async -> Void)?

    init(onStep: (@Sendable (MoodboardAgentStep) async -> Void)?) {
        self.onStep = onStep
    }

    func emit(
        _ phase: MoodboardAgentPhase,
        title: String,
        detail: String,
        status: MoodboardAgentStepStatus
    ) async {
        let step: MoodboardAgentStep
        if let existingIdx = steps.lastIndex(where: { $0.phase == phase && $0.status == .running }) {
            steps[existingIdx].title = title
            steps[existingIdx].detail = detail
            steps[existingIdx].status = status
            steps[existingIdx].timestamp = Date()
            step = steps[existingIdx]
        } else {
            let created = MoodboardAgentStep(phase: phase, title: title, detail: detail, status: status)
            steps.append(created)
            step = created
        }
        await onStep?(step)
    }

    func snapshot() -> [MoodboardAgentStep] {
        steps
    }
}

public nonisolated struct MoodboardAgentHarness: Sendable {
    private let tools: CharkleAgentTools

    public init(database: LibraryDatabase, media: MediaPipeline) {
        self.tools = CharkleAgentTools(database: database, media: media)
    }

    public init(tools: CharkleAgentTools) {
        self.tools = tools
    }

    public func curate(
        request: MoodboardCurationRequest,
        provider: (any CloudAIProvider)?,
        typeSafeConfig: TypeSafeExperimentalConfig? = nil,
        typeSafeAPIKey: String? = nil,
        grounding: VisualGroundingEngine? = nil,
        onStep: (@Sendable (MoodboardAgentStep) async -> Void)? = nil
    ) async throws -> MoodboardProposal {
        let recorder = AgentTraceRecorder(onStep: onStep)

        func emit(_ phase: MoodboardAgentPhase, title: String, detail: String, status: MoodboardAgentStepStatus) async {
            await recorder.emit(phase, title: title, detail: detail, status: status)
        }

        // MARK: Stage 1 — Overview & Optional Large-Library Brief Planner
        await emit(.planning, title: "读取素材库结构与策展目标", detail: "扫描文件夹树、标签分布与约束条件…", status: .running)
        let overview = try await tools.libraryOverview()

        var expandedQueries: [String] = []
        var preferredFolderNames: [String] = []
        var inferredColors: [LabColor] = []

        let hasBriefText = !request.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !(request.refinementInstruction ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        if let provider, hasBriefText, overview.totalAssets > 32, request.scopeFolderIDs.isEmpty {
            await emit(.planning, title: "拆解灵感方向与检索策略", detail: "正在由模型扩展中英双语视觉关键词与匹配目录…", status: .running)
            if let planned = try? await runRetrievalPlanner(request: request, overview: overview, provider: provider) {
                expandedQueries = planned.searchQueries
                preferredFolderNames = planned.preferredFolders
                inferredColors = planned.targetColorHexes.map { LabColor.fromHex($0) }
            }
        }

        await emit(
            .planning,
            title: "已分析素材库全貌（共 \(overview.totalAssets) 项素材 · \(overview.folders.count) 个文件夹）",
            detail: expandedQueries.isEmpty
                ? (overview.totalAssets <= 32 ? "素材库规模适中，将直接全览所有符合范围的素材进行视觉审片" : "已确定多路召回范围")
                : "扩展检索维度：\(expandedQueries.prefix(5).joined(separator: " / "))",
            status: .done
        )

        // MARK: Stage 2 — Multi-Route Grounded Recall
        await emit(.retrieving, title: "多路召回候选素材", detail: "按文件夹、标签、视觉相似与色彩过滤候选池…", status: .running)
        var recall = try await tools.recallCandidates(
            request: request,
            expandedQueries: expandedQueries,
            preferredFolderNames: preferredFolderNames,
            inferredColors: inferredColors,
            provider: provider,
            maxCandidates: 32
        )

        if recall.candidates.isEmpty {
            await emit(.retrieving, title: "未找到符合当前限定条件的素材", detail: "请放宽文件夹/标签限制，或先导入相关参考素材", status: .warning)
            let emptyDoc = request.existingBoard ?? MoodboardDocument(
                title: request.prompt.isEmpty ? "新情绪板" : String(request.prompt.prefix(40)),
                subtitle: "当前限定范围内暂无匹配素材"
            )
            return MoodboardProposal(
                draftDocument: emptyDoc,
                primaryMatches: [],
                candidatePool: [],
                extractedPalette: request.targetPalette,
                usedCloudAI: false,
                curatedSummary: "当前限定条件（文件夹/标签/排除项）下暂无可用素材，请放宽条件后重试。",
                agentTrace: await recorder.snapshot(),
                sections: [],
                rejectedSummary: nil,
                cachedVisualInsightsCount: 0
            )
        }

        // MARK: Stage 2.5 — Optional TypeSafe (Jev Score) Visual Rerank
        var usedTypeSafeVisualRerank = false
        let queryBrief = [request.prompt, request.refinementInstruction ?? ""]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "；")
        if let tsCfg = typeSafeConfig, tsCfg.enabled, tsCfg.enableCuratorVisualRerank,
           let tsKey = typeSafeAPIKey, !tsKey.isEmpty,
           let grounding, !queryBrief.isEmpty {
            await emit(
                .retrieving,
                title: "TypeSafe Jev 正在视觉精排候选池（\(min(recall.candidates.count, 24)) 张）",
                detail: "直接看图按 0–3 校准分数评估主题与氛围契合度，发现未打标高匹配作品…",
                status: .running
            )
            let visualInputs: [VisualCandidateInput] = recall.candidates.prefix(24).map { asset in
                VisualCandidateInput(
                    assetID: asset.id,
                    title: asset.title,
                    tags: asset.tags,
                    description: asset.aiDescription,
                    imageData: tools.preparedTypeSafeJPEG(for: asset, targetLongSide: 384)
                )
            }
            if let jevScores = try? await grounding.scoreCandidatesForQuery(
                query: queryBrief,
                candidates: visualInputs,
                config: tsCfg,
                apiKey: tsKey,
                batchSize: 4,
                maxConcurrency: 3
            ), !jevScores.isEmpty {
                usedTypeSafeVisualRerank = true
                let scoreMap = Dictionary(uniqueKeysWithValues: jevScores.map { ($0.assetID, $0) })
                var updatedScores = recall.scoresByID
                for asset in recall.candidates {
                    guard let js = scoreMap[asset.id] else { continue }
                    let prior = updatedScores[asset.id]
                    let blended = prior != nil ? max(js.score, (prior!.score * 0.35 + js.score * 0.65)) : js.score
                    var reasons = prior?.matchReasons ?? []
                    if js.score >= 0.45 {
                        reasons.insert("Jev 视觉契合 \(Int((js.score * 100).rounded()))%", at: 0)
                    }
                    updatedScores[asset.id] = ScoredAsset(asset: asset, score: blended, matchReasons: reasons)
                }
                let reordered = recall.candidates.sorted { lhs, rhs in
                    let ls = updatedScores[lhs.id]?.score ?? 0
                    let rs = updatedScores[rhs.id]?.score ?? 0
                    if abs(ls - rs) > 0.001 { return ls > rs }
                    return lhs.rating > rhs.rating
                }
                recall = AgentRecallResult(
                    eligibleTotal: recall.eligibleTotal,
                    candidates: reordered,
                    scoresByID: updatedScores,
                    folderPathByID: recall.folderPathByID
                )
            }
        }

        await emit(
            .retrieving,
            title: "已锁定 \(recall.candidates.count) 项候选素材进入审片" + (usedTypeSafeVisualRerank ? "（已由 Jev 视觉精排）" : ""),
            detail: recall.eligibleTotal > recall.candidates.count
                ? "从 \(recall.eligibleTotal) 项合规素材中粗筛出 Top \(recall.candidates.count)"
                : "覆盖全部 \(recall.eligibleTotal) 项合规素材，确保无标签素材也不会遗漏",
            status: .done
        )

        // MARK: Stage 3 — Multimodal Visual Contact Sheet Curation (Cloud AI) OR Strict Offline Fallback
        if let provider {
            do {
                let package = tools.buildContactSheets(
                    for: recall.candidates,
                    folderPathByID: recall.folderPathByID,
                    seedIDs: Set(request.seedAssetIDs),
                    lockedIDs: Set(request.lockedAssetIDs),
                    existingBoardIDs: Set(request.existingBoard?.referencedAssetIDs ?? []),
                    sheetCapacity: 16
                )

                await emit(
                    .inspectingVisuals,
                    title: "AI 正在视觉审片与编排（\(package.sheets.count) 张编号联系表 · \(recall.candidates.count) 张图）",
                    detail: "直接识别每张图的构图、光影、题材与风格，宁缺毋滥挑选并划分逻辑分区…",
                    status: .running
                )

                let curationPrompt = Self.buildVisualCurationPrompt(
                    request: request,
                    manifest: package.manifestText,
                    sheetCount: package.sheets.count,
                    totalSlots: package.slotToAsset.count
                )
                let sheetImages = package.sheets.map(\.jpegData)

                let rawOutput = try await provider.completeJSON(
                    instructions: Self.visualCuratorSystemPrompt,
                    prompt: curationPrompt,
                    imagesJPEG: sheetImages
                )

                await emit(.inspectingVisuals, title: "视觉审片完成，已生成策展方案", detail: "开始执行编号接地、防重与约束校验…", status: .done)
                await emit(.verifying, title: "校验画布结构与防重约束", detail: "核对真实素材 ID、锁定/排除规则与视觉去重…", status: .running)

                var parsedPlan: AgentBoardPlan?
                var parseErrorDescription: String?
                do {
                    parsedPlan = try Self.parseBoardPlan(from: rawOutput, fallbackLayout: request.layoutStyle)
                } catch {
                    parseErrorDescription = error.localizedDescription
                }

                var compilation: VerifiedBoardCompilation?
                if let plan = parsedPlan {
                    compilation = try await tools.compileAndVerifyBoard(
                        plan: plan,
                        slotToAsset: package.slotToAsset,
                        request: request,
                        recall: recall
                    )
                }

                // Deterministic 1-Turn Auto-Repair if JSON failed or Verifier flagged empty/invalid draft
                if parsedPlan == nil || compilation?.needsRepair == true {
                    let repairReason = parseErrorDescription
                        ?? (compilation?.issues.joined(separator: "; ") ?? "未能选出有效编号")
                    await emit(.repairing, title: "触发自动修正回合", detail: "校验发现异常（\(repairReason)），正在要求模型修正输出格式…", status: .running)

                    let repairPrompt = """
                    上一次策展输出未通过校验：\(repairReason)
                    请严格只输出一个合法 JSON 对象，所有 slot 必须是 1...\(package.slotToAsset.count) 中真实存在的整数编号。
                    原清单回顾：
                    \(package.manifestText)
                    """
                    let repairedRaw = try await provider.completeJSON(
                        instructions: Self.visualCuratorSystemPrompt,
                        prompt: repairPrompt,
                        imagesJPEG: sheetImages
                    )
                    let repairedPlan = try Self.parseBoardPlan(from: repairedRaw, fallbackLayout: request.layoutStyle)
                    parsedPlan = repairedPlan
                    compilation = try await tools.compileAndVerifyBoard(
                        plan: repairedPlan,
                        slotToAsset: package.slotToAsset,
                        request: request,
                        recall: recall
                    )
                    await emit(.repairing, title: "自动修正完成", detail: "修正后的策展方案已通过校验", status: .done)
                }

                if let plan = parsedPlan, let compiled = compilation {
                    // Cache any newly observed visual descriptions & tags back to SQLite for free
                    let insights: [AgentVisualInsight] = plan.visualInsights.compactMap { item in
                        guard let asset = package.slotToAsset[item.slot] else { return nil }
                        return AgentVisualInsight(assetID: asset.id, description: item.description, tags: item.tags)
                    }
                    let cachedCount = await tools.persistVisualInsights(insights)

                    let verifyDetail = compiled.issues.isEmpty
                        ? "入选 \(compiled.primaryMatches.count) 张 · 分区 \(compiled.sections.count) 组 · 候选池 \(compiled.candidatePool.count) 张"
                        + (cachedCount > 0 ? " · 顺手沉淀 \(cachedCount) 条画面理解" : "")
                        : "已自动修正 \(compiled.issues.count) 项约束 · 入选 \(compiled.primaryMatches.count) 张"
                    let finalDoc = await applyAutoDetailCropsIfRequested(
                        document: compiled.document,
                        assets: recall.candidates,
                        request: request,
                        typeSafeConfig: typeSafeConfig,
                        typeSafeAPIKey: typeSafeAPIKey,
                        grounding: grounding,
                        recorder: recorder
                    )

                    await emit(.verifying, title: "校验通过", detail: verifyDetail, status: .done)
                    await emit(.completed, title: "AI 情绪板策展完成", detail: plan.boardSubtitle.isEmpty ? verifyDetail : plan.boardSubtitle, status: .done)

                    let summary = plan.curatorNote?.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                        ? (plan.curatorNote?.text ?? "")
                        : (plan.boardSubtitle.isEmpty ? "已从 \(recall.candidates.count) 项候选中精选 \(compiled.primaryMatches.count) 张契合素材并完成分区排版。" : plan.boardSubtitle)

                    return MoodboardProposal(
                        draftDocument: finalDoc,
                        primaryMatches: compiled.primaryMatches,
                        candidatePool: compiled.candidatePool,
                        extractedPalette: compiled.extractedPalette,
                        usedCloudAI: true,
                        curatedSummary: summary,
                        agentTrace: await recorder.snapshot(),
                        sections: compiled.sections,
                        rejectedSummary: plan.rejectedNote,
                        cachedVisualInsightsCount: cachedCount
                    )
                }
            } catch {
                // Cloud AI failed (network / quota / auth) -> transparently report and fall back to strict offline curator
                await emit(
                    .fallbackOffline,
                    title: "云端模型暂不可用，已切换本机离线策展",
                    detail: error.localizedDescription,
                    status: .warning
                )
            }
        } else if !usedTypeSafeVisualRerank {
            await emit(
                .fallbackOffline,
                title: "当前为纯本机离线模式",
                detail: "可在「设置 → 智能与搜索」开启 ChatGPT / Gemini 或 TypeSafe (Jev) 解锁看图策展",
                status: .warning
            )
        }

        // MARK: Stage 4 — Strict-Threshold Curator (Jev Visual Rerank OR Offline Fallback)
        var fallbackProposal = try await runStrictOfflineCurator(
            request: request,
            recall: recall,
            recorder: recorder,
            usedTypeSafeJev: usedTypeSafeVisualRerank
        )
        fallbackProposal.draftDocument = await applyAutoDetailCropsIfRequested(
            document: fallbackProposal.draftDocument,
            assets: recall.candidates,
            request: request,
            typeSafeConfig: typeSafeConfig,
            typeSafeAPIKey: typeSafeAPIKey,
            grounding: grounding,
            recorder: recorder
        )
        fallbackProposal.agentTrace = await recorder.snapshot()
        return fallbackProposal
    }

    /// Stage 3.5 — Optional Jev Box Detail-Focus Auto-Crop for "细节特写模式" moodboards.
    private func applyAutoDetailCropsIfRequested(
        document: MoodboardDocument,
        assets: [AssetRecord],
        request: MoodboardCurationRequest,
        typeSafeConfig: TypeSafeExperimentalConfig?,
        typeSafeAPIKey: String?,
        grounding: VisualGroundingEngine?,
        recorder: AgentTraceRecorder
    ) async -> MoodboardDocument {
        let query = request.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard request.autoFocusDetailCrop,
              !query.isEmpty,
              let tsCfg = typeSafeConfig, tsCfg.enabled,
              let tsKey = typeSafeAPIKey, !tsKey.isEmpty,
              let grounding else {
            return document
        }

        let assetsByID = Dictionary(uniqueKeysWithValues: assets.map { ($0.id, $0) })
        let targets: [(index: Int, asset: AssetRecord)] = document.nodes.enumerated().compactMap { idx, node in
            guard case .assetRef(let assetID, let existingCrop, _, _) = node.kind,
                  existingCrop == nil,
                  let asset = assetsByID[assetID],
                  asset.mediaKind == .image || asset.mediaKind == .webBookmark || asset.mediaKind == .animatedImage else {
                return nil
            }
            return (idx, asset)
        }
        guard !targets.isEmpty else { return document }

        await recorder.emit(
            .composing,
            title: "Jev Box 细节特写聚焦（\(targets.count) 张主图）",
            detail: "正在按「\(query)」自动定位局部细节并写入非破坏性裁切框…",
            status: .running
        )

        var cropsByIndex: [Int: NormalizedCropRect] = [:]
        await withTaskGroup(of: (Int, NormalizedCropRect?).self) { group in
            for (idx, asset) in targets.prefix(12) {
                guard let jpeg = tools.preparedTypeSafeJPEG(for: asset, targetLongSide: 640) else { continue }
                group.addTask {
                    let res = try? await grounding.locateRegion(
                        query: query,
                        imageData: jpeg,
                        imageFormat: "jpg",
                        cgImage: nil,
                        config: tsCfg,
                        apiKey: tsKey
                    )
                    if let res, res.found, res.crop.isMeaningfulSubregion {
                        return (idx, res.crop)
                    }
                    return (idx, nil)
                }
            }
            for await (idx, crop) in group {
                if let crop { cropsByIndex[idx] = crop }
            }
        }

        var updated = document
        for (idx, crop) in cropsByIndex {
            if case .assetRef(let assetID, _, let weight, let autoplay) = updated.nodes[idx].kind {
                updated.nodes[idx].kind = .assetRef(assetID: assetID, crop: crop, weight: weight, autoplayLoop: autoplay)
            }
        }
        await recorder.emit(
            .composing,
            title: "细节特写聚焦完成（\(cropsByIndex.count)/\(targets.count) 张已自动局部取景）",
            detail: cropsByIndex.isEmpty ? "入选作品均为整幅契合，保持原始画幅" : "每张卡片随时可右键还原完整画面",
            status: .done
        )
        return updated
    }

    // MARK: - Large-Library Text Brief Planner

    private struct RetrievalPlan {
        let searchQueries: [String]
        let preferredFolders: [String]
        let targetColorHexes: [String]
    }

    private func runRetrievalPlanner(
        request: MoodboardCurationRequest,
        overview: AgentLibraryOverview,
        provider: any CloudAIProvider
    ) async throws -> RetrievalPlan {
        let foldersSummary = overview.folders.prefix(30).map { "\($0.path) (\($0.assetCount))" }.joined(separator: ", ")
        let tagsSummary = overview.topTags.prefix(30).map { "\($0.name)(\($0.count))" }.joined(separator: ", ")
        let prompt = """
        用户灵感需求：\(request.prompt)
        微调补充指令：\(request.refinementInstruction ?? "无")
        用户素材库文件夹：\(foldersSummary.isEmpty ? "无" : foldersSummary)
        用户高频标签：\(tagsSummary.isEmpty ? "无" : tagsSummary)

        请仅输出一个 JSON 对象，用于多路召回候选素材：
        {
          "searchQueries": ["4到8个中英双语画面关键词或风格词"],
          "preferredFolders": ["从上述素材库文件夹中挑选高度相关的文件夹名，没有则留空数组"],
          "targetColorHexes": ["如能从描述推断主色相，给1到3个#RRGGBB，否则留空数组"]
        }
        """
        let raw = try await provider.completeJSON(
            instructions: "You are a visual library retrieval planner. Output strict JSON only.",
            prompt: prompt,
            imagesJPEG: []
        )
        let jsonObject = try Self.extractJSONObject(from: raw)
        let queries = (jsonObject["searchQueries"] as? [String] ?? [])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let folders = (jsonObject["preferredFolders"] as? [String] ?? [])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let hexes = (jsonObject["targetColorHexes"] as? [String] ?? [])
            .filter { $0.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("#") }
        return RetrievalPlan(searchQueries: queries, preferredFolders: folders, targetColorHexes: hexes)
    }

    // MARK: - Strict Offline Curator

    private func runStrictOfflineCurator(
        request: MoodboardCurationRequest,
        recall: AgentRecallResult,
        recorder: AgentTraceRecorder,
        usedTypeSafeJev: Bool = false
    ) async throws -> MoodboardProposal {
        let locked = Set(request.lockedAssetIDs)
        let seeds = Set(request.seedAssetIDs)
        let hasActiveSignal = !request.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !request.targetPalette.isEmpty
            || !request.seedAssetIDs.isEmpty
            || !request.requiredTags.isEmpty

        let ranked = recall.candidates.compactMap { recall.scoresByID[$0.id] }
            .sorted { lhs, rhs in
                let lPin = locked.contains(lhs.id) || seeds.contains(lhs.id)
                let rPin = locked.contains(rhs.id) || seeds.contains(rhs.id)
                if lPin != rPin { return lPin }
                if abs(lhs.score - rhs.score) > 0.001 { return lhs.score > rhs.score }
                return lhs.asset.rating > rhs.asset.rating
            }

        // Strict relevance threshold: DO NOT dump random unrelated items when user gave a specific brief!
        let threshold: Double = hasActiveSignal ? 0.34 : 0.0
        var chosen: [ScoredAsset] = []
        var rejectedCount = 0
        for item in ranked {
            let isPinned = locked.contains(item.id) || seeds.contains(item.id)
            if isPinned || (!hasActiveSignal) || (item.score >= threshold && !item.matchReasons.isEmpty) {
                if chosen.count < max(1, request.preferredCount) || isPinned {
                    chosen.append(item)
                }
            } else {
                rejectedCount += 1
            }
        }

        // Group offline picks neatly by folder or into one crisp section
        var slotToAsset: [Int: AssetRecord] = [:]
        var slotByID: [UUID: Int] = [:]
        for (idx, asset) in recall.candidates.enumerated() {
            let s = idx + 1
            slotToAsset[s] = asset
            slotByID[asset.id] = s
        }

        let primaryPicks: [AgentBoardPlan.SlotPick] = chosen.enumerated().compactMap { idx, scored in
            guard let slot = slotByID[scored.id] else { return nil }
            return AgentBoardPlan.SlotPick(
                slot: slot,
                weight: idx == 0 ? 2 : 1,
                reason: scored.matchReasons.first ?? "本机相关匹配"
            )
        }
        let chosenIDs = Set(chosen.map(\.id))
        let candidatePicks: [AgentBoardPlan.SlotPick] = ranked
            .filter { !chosenIDs.contains($0.id) }
            .prefix(request.candidateCount)
            .compactMap { scored in
                guard let slot = slotByID[scored.id] else { return nil }
                return AgentBoardPlan.SlotPick(slot: slot, weight: 1, reason: scored.matchReasons.first ?? "备选参考")
            }

        let titleDraft = request.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = titleDraft.isEmpty
            ? (request.existingBoard?.title ?? (usedTypeSafeJev ? "Jev 视觉情绪板" : "本机策展情绪板"))
            : String(titleDraft.prefix(36))
        let rejectedText = rejectedCount > 0
            ? (usedTypeSafeJev
                ? "Jev 视觉打分已过滤掉 \(rejectedCount) 张不相关素材"
                : "已按本机匹配度过滤掉 \(rejectedCount) 张不相关素材（开启云端增强智能后支持 AI 直接看图筛选未打标素材）")
            : nil

        let offlinePlan = AgentBoardPlan(
            boardTitle: title,
            boardSubtitle: chosen.isEmpty
                ? (usedTypeSafeJev ? "Jev 视觉精排未找到高匹配素材，请尝试更换灵感词" : "本机离线文本/色彩检索未匹配到足够素材，可开启云端增强智能看图筛选，或放宽限定条件")
                : (usedTypeSafeJev ? "TypeSafe Jev 视觉精排精选 \(chosen.count) 项契合素材" : "本机离线精选 \(chosen.count) 项契合素材"),
            curatorNote: request.includeCuratorNotes && !chosen.isEmpty
                ? AgentBoardPlan.NoteSpec(
                    title: "策展说明",
                    text: titleDraft.isEmpty
                        ? "按色彩、视觉特征与所选种子整理的视觉参考集合。"
                        : (usedTypeSafeJev ? "围绕「\(titleDraft)」由 TypeSafe Jev 视觉精排生成的参考集合。" : "围绕「\(titleDraft)」整理的本机视觉参考集合。"),
                    style: .paper
                )
                : nil,
            recommendedLayout: request.layoutStyle,
            sections: primaryPicks.isEmpty
                ? []
                : [AgentBoardPlan.SectionSpec(title: usedTypeSafeJev ? "Jev 视觉精选" : "精选视觉参考", tint: .neutral, rationale: "", picks: primaryPicks)],
            candidatePicks: candidatePicks,
            rejectedNote: rejectedText,
            visualInsights: []
        )

        let compiled = try await tools.compileAndVerifyBoard(
            plan: offlinePlan,
            slotToAsset: slotToAsset,
            request: request,
            recall: recall
        )
        await recorder.emit(
            .completed,
            title: chosen.isEmpty
                ? (usedTypeSafeJev ? "Jev 未匹配到符合描述的素材" : "离线未匹配到符合描述的素材")
                : (usedTypeSafeJev ? "Jev 视觉策展初稿已生成（\(compiled.primaryMatches.count) 张）" : "离线初稿已生成（\(compiled.primaryMatches.count) 张）"),
            detail: rejectedText ?? "已完成版面编排与配色提炼",
            status: chosen.isEmpty ? .warning : .done
        )

        return MoodboardProposal(
            draftDocument: compiled.document,
            primaryMatches: compiled.primaryMatches,
            candidatePool: compiled.candidatePool,
            extractedPalette: compiled.extractedPalette,
            usedCloudAI: usedTypeSafeJev,
            curatedSummary: offlinePlan.boardSubtitle,
            agentTrace: await recorder.snapshot(),
            sections: compiled.sections,
            rejectedSummary: rejectedText,
            cachedVisualInsightsCount: 0
        )
    }

    // MARK: - Prompt & JSON Parser

    static let visualCuratorSystemPrompt = """
    You are Charkle's Senior Art Director & Visual Moodboard Curator Agent.
    You are given numbered Visual Contact Sheet image(s) where every candidate asset has a crisp top-left `#01`, `#02`, ... slot badge, plus a grounded metadata manifest.

    CORE CURATION PRINCIPLES (STRICT):
    1. **LOOK AT THE ACTUAL IMAGES** on the Contact Sheets! Do not rely solely on filenames (many user files are named `Clip-xxxx.jpg` or `X-xxxx.jpg` without tags).
    2. **QUALITY OVER QUANTITY (宁缺毋滥)**: NEVER pad the board with off-brief images just to reach the target count! If the user asks for anime summer illustrations and only 3 images truly fit while others are dark UI dashboards or typography posters, select ONLY those 3 images and explain what was excluded in `rejectedNote`.
    3. **GROUNDED INTEGER SLOTS ONLY**: Every `slot` MUST be an integer visible on the Contact Sheet (`1..N`). Never invent slots or repeat a slot across sections.
    4. **HONOR USER LOCKS & SEEDS**: Any slot flagged `LOCKED_MUST_KEEP` or `USER_SEED` MUST be included on the board.
    5. **EDITORIAL COMPOSITION**: Group selected assets into 1–3 meaningful Chinese visual sections (e.g., 「核心主视觉」「光影与色调氛围」「材质与构图细节」), mark 1–2 strongest focal images with `weight: 2` (Hero), and write a concise, tasteful Chinese art-direction note.
    6. **VISUAL INSIGHTS**: For images that lack a description (`desc=` missing in manifest), briefly fill `visualInsights` with concise single-language Chinese visual description and 2–5 short monolingual Chinese tags (no bilingual pairs, no `#`). Prefer reusing existing tags already seen in the manifest over inventing synonymous variants.

    OUTPUT ONLY ONE VALID JSON OBJECT (no markdown fences or commentary outside JSON) matching this schema:
    {
      "boardTitle": "简短优雅的中文情绪板标题",
      "boardSubtitle": "一句话策展方向总结",
      "curatorNote": {
        "title": "视觉定调说明",
        "text": "2-3句专业克制的中文设计策展说明（色调、构图、质感与氛围逻辑）",
        "style": "paper|ink|warm|sage|slate"
      },
      "recommendedLayout": "magazine|balanced|compact",
      "sections": [
        {
          "title": "分区名称",
          "tint": "neutral|sand|sage|slate|terracotta|ocean",
          "rationale": "一句简短分区意图（12字以内）",
          "slots": [
            { "slot": 1, "weight": 2, "reason": "8-18字入选理由" }
          ]
        }
      ],
      "candidatePoolSlots": [
        { "slot": 5, "reason": "简短备选理由" }
      ],
      "rejectedNote": "一句话说明主动剔除了哪些风格/题材不符的素材（如有）",
      "visualInsights": [
        { "slot": 1, "description": "简短中文画面描述", "tags": ["标签1", "标签2"] }
      ]
    }
    """

    static func buildVisualCurationPrompt(
        request: MoodboardCurationRequest,
        manifest: String,
        sheetCount: Int,
        totalSlots: Int
    ) -> String {
        var lines: [String] = []
        lines.append("【策展任务】")
        if !request.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.append("- 核心氛围与主题：\(request.prompt)")
        } else {
            lines.append("- 核心氛围与主题：未指定文字，请围绕已选种子图 / 色彩倾向 / 现有画布提炼统一的高级视觉方向")
        }
        if let refine = request.refinementInstruction?.trimmingCharacters(in: .whitespacesAndNewlines), !refine.isEmpty {
            lines.append("- 本轮用户微调指令（最高优先级执行）：\(refine)")
        }
        if let existing = request.existingBoard {
            lines.append("- 当前已有画布：「\(existing.title)」（现有 \(existing.referencedAssetIDs.count) 张图，清单中标注了 CURRENTLY_ON_BOARD；请在其基础上按本轮指令优化、增删或重组分区）")
        }
        if !request.targetPalette.isEmpty {
            let hexes = request.targetPalette.map(\.hex).joined(separator: ", ")
            lines.append("- 目标色彩倾向：\(hexes)")
        }
        lines.append("- 期望上限张数：最多 \(request.preferredCount) 张（宁缺毋滥，宁少勿滥，严禁硬塞风格冲突的素材）")
        lines.append("- 偏好排版风格：\(request.layoutStyle.rawValue)")
        lines.append("- 附带 \(sheetCount) 张编号视觉联系表，共 \(totalSlots) 个候选编号（#01 ~ #\(String(format: "%02d", totalSlots))）。请务必仔细观察联系表上的真实画面后再做选择！")
        lines.append("")
        lines.append("【候选素材清单】")
        lines.append(manifest)
        return lines.joined(separator: "\n")
    }

    static func parseBoardPlan(from raw: String, fallbackLayout: EditorialStyle) throws -> AgentBoardPlan {
        let obj = try extractJSONObject(from: raw)
        let title = (obj["boardTitle"] as? String) ?? (obj["title"] as? String) ?? ""
        let subtitle = (obj["boardSubtitle"] as? String) ?? (obj["subtitle"] as? String) ?? ""
        let layoutRaw = (obj["recommendedLayout"] as? String)?.lowercased() ?? fallbackLayout.rawValue
        let layout = EditorialStyle(rawValue: layoutRaw) ?? fallbackLayout

        var noteSpec: AgentBoardPlan.NoteSpec?
        if let noteObj = obj["curatorNote"] as? [String: Any],
           let text = noteObj["text"] as? String,
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let noteTitle = (noteObj["title"] as? String) ?? "视觉定调说明"
            let style = NoteStyle(rawValue: (noteObj["style"] as? String)?.lowercased() ?? "paper") ?? .paper
            noteSpec = AgentBoardPlan.NoteSpec(title: noteTitle, text: text, style: style)
        }

        var sections: [AgentBoardPlan.SectionSpec] = []
        if let rawSections = obj["sections"] as? [[String: Any]] {
            for sec in rawSections {
                let secTitle = (sec["title"] as? String) ?? "精选参考"
                let tint = GroupTint(rawValue: (sec["tint"] as? String)?.lowercased() ?? "neutral") ?? .neutral
                let rationale = (sec["rationale"] as? String) ?? ""
                let picks = parseSlotPicks(sec["slots"] ?? sec["picks"])
                if !picks.isEmpty {
                    sections.append(AgentBoardPlan.SectionSpec(title: secTitle, tint: tint, rationale: rationale, picks: picks))
                }
            }
        }
        // Fallback if model returned flat `slots` or `selectedSlots` array instead of `sections`
        if sections.isEmpty {
            let flat = parseSlotPicks(obj["slots"] ?? obj["selectedSlots"] ?? obj["picks"])
            if !flat.isEmpty {
                sections.append(AgentBoardPlan.SectionSpec(title: "核心视觉参考", tint: .neutral, rationale: "", picks: flat))
            }
        }

        let candidates = parseSlotPicks(obj["candidatePoolSlots"] ?? obj["candidatePicks"] ?? obj["candidates"])
        let rejectedNote = (obj["rejectedNote"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)

        var insights: [(Int, String, [String])] = []
        if let rawInsights = obj["visualInsights"] as? [[String: Any]] {
            for item in rawInsights {
                guard let slot = parseIntSlot(item["slot"]) else { continue }
                let desc = (item["description"] as? String) ?? ""
                let tags = (item["tags"] as? [String]) ?? []
                if !desc.isEmpty || !tags.isEmpty {
                    insights.append((slot, desc, tags))
                }
            }
        }

        return AgentBoardPlan(
            boardTitle: title,
            boardSubtitle: subtitle,
            curatorNote: noteSpec,
            recommendedLayout: layout,
            sections: sections,
            candidatePicks: candidates,
            rejectedNote: rejectedNote?.isEmpty == true ? nil : rejectedNote,
            visualInsights: insights
        )
    }

    private static func parseSlotPicks(_ raw: Any?) -> [AgentBoardPlan.SlotPick] {
        guard let array = raw as? [Any] else { return [] }
        return array.compactMap { entry in
            if let slot = parseIntSlot(entry) {
                return AgentBoardPlan.SlotPick(slot: slot, weight: 1, reason: "")
            }
            guard let dict = entry as? [String: Any], let slot = parseIntSlot(dict["slot"]) else { return nil }
            let weight = parseIntSlot(dict["weight"]) ?? 1
            let reason = (dict["reason"] as? String) ?? ""
            return AgentBoardPlan.SlotPick(slot: slot, weight: max(1, min(2, weight)), reason: reason)
        }
    }

    private static func parseIntSlot(_ raw: Any?) -> Int? {
        if let i = raw as? Int { return i }
        if let n = raw as? NSNumber { return n.intValue }
        if let s = raw as? String {
            let digits = s.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "#", with: "")
            return Int(digits)
        }
        return nil
    }

    static func extractJSONObject(from raw: String) throws -> [String: Any] {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.firstIndex(of: "{"), let last = trimmed.lastIndex(of: "}"), first <= last else {
            throw LibraryDatabaseError("模型未返回合法的 JSON 策展方案。")
        }
        let slice = Data(trimmed[first...last].utf8)
        guard let obj = try JSONSerialization.jsonObject(with: slice) as? [String: Any] else {
            throw LibraryDatabaseError("策展方案 JSON 根结构不是对象。")
        }
        return obj
    }
}
