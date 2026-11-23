import { randomUUID } from 'node:crypto';
import {
  createDefaultMoodboardDocument,
  EDITORIAL_STYLES,
  getAssetAspectRatio,
  getBoardReferencedAssetIDs,
  GROUP_TINTS,
  isMeaningfulCropSubregion,
  labFromHex,
  normalizeSearchText,
  NOTE_STYLES,
  toSwiftUUID,
  type AssetRecord,
  type AssetVector,
  type BoardLayoutMode,
  type BoardNode,
  type EditorialStyle,
  type FolderRecord,
  type GroupTint,
  type LabColor,
  type MoodboardAgentPhase,
  type MoodboardAgentStep,
  type MoodboardAgentStepStatus,
  type MoodboardCurationRequest,
  type MoodboardDocument,
  type MoodboardProposal,
  type MoodboardSectionDraft,
  type NormalizedCropRect,
  type NoteStyle,
  type ScoredAsset,
  type TagCount,
  type TypeSafeExperimentalConfig,
  type UUID,
} from '@charkle/shared';
import type { IMediaPipeline } from '../context.js';
import { cosineSimilarity, type LibraryDatabase } from '../db/library-database.js';
import { CloudTagNormalizer, type CloudAIProvider } from './cloud-ai-provider.js';
import {
  ContactSheetRenderer,
  type ContactSheetBatch,
  type ContactSheetEntry,
} from './contact-sheet-renderer.js';
import {
  featurePrintSimilarity,
  MoodboardCurator,
  significantSwatchDistance,
  weightedPaletteDistance,
} from './moodboard-curator.js';
import { TypeSafeImagePreparer } from './typesafe-client.js';
import type { VisualCandidateInput, VisualGroundingEngine } from './visual-grounding-engine.js';

export interface AgentLibraryOverview {
  totalAssets: number;
  inboxCount: number;
  folders: Array<{
    id: UUID;
    name: string;
    path: string;
    assetCount: number;
  }>;
  topTags: TagCount[];
  mediaKindCounts: Record<string, number>;
  boardCount: number;
}

export interface AgentVisualInsight {
  assetID: UUID;
  description: string;
  tags: string[];
}

export interface AgentNoteSpec {
  title: string;
  text: string;
  style: NoteStyle;
}

export interface AgentSlotPick {
  slot: number;
  weight: number;
  reason: string;
}

export interface AgentSectionSpec {
  title: string;
  tint: GroupTint;
  rationale: string;
  picks: AgentSlotPick[];
}

export interface AgentBoardPlan {
  boardTitle: string;
  boardSubtitle: string;
  curatorNote: AgentNoteSpec | null;
  recommendedLayout: EditorialStyle;
  sections: AgentSectionSpec[];
  candidatePicks: AgentSlotPick[];
  rejectedNote: string | null;
  visualInsights: Array<{ slot: number; description: string; tags: string[] }>;
}

export interface AgentRecallResult {
  eligibleTotal: number;
  candidates: AssetRecord[];
  scoresByID: Map<UUID, ScoredAsset>;
  folderPathByID: Map<UUID, string>;
}

export interface VerifiedBoardCompilation {
  document: MoodboardDocument;
  primaryMatches: ScoredAsset[];
  candidatePool: ScoredAsset[];
  sections: MoodboardSectionDraft[];
  extractedPalette: LabColor[];
  issues: string[];
  needsRepair: boolean;
}

export interface ContactSheetPackage {
  sheets: ContactSheetBatch[];
  slotToAsset: Map<number, AssetRecord>;
  manifestText: string;
}

function uniqueStringsCaseInsensitive(values: readonly string[]): string[] {
  const seen = new Set<string>();
  const out: string[] = [];
  for (const v of values) {
    const key = v.toLowerCase();
    if (!seen.has(key)) {
      seen.add(key);
      out.push(v);
    }
  }
  return out;
}

export function buildFolderPathsMap(folders: readonly FolderRecord[]): Map<UUID, string> {
  const byID = new Map(folders.map((f) => [f.id, f]));
  const result = new Map<UUID, string>();
  for (const folder of folders) {
    const parts: string[] = [];
    let cursor: UUID | null | undefined = folder.id;
    const visited = new Set<UUID>();
    while (cursor && !visited.has(cursor)) {
      visited.add(cursor);
      const f = byID.get(cursor);
      if (!f) break;
      parts.unshift(f.name);
      cursor = f.parentID;
    }
    result.set(folder.id, parts.join('/'));
  }
  return result;
}

export function expandFolderScope(roots: readonly UUID[], folders: readonly FolderRecord[]): Set<UUID> {
  if (roots.length === 0) return new Set();
  const childrenByParent = new Map<UUID | null, FolderRecord[]>();
  for (const f of folders) {
    const key = f.parentID ?? null;
    const list = childrenByParent.get(key) ?? [];
    list.push(f);
    childrenByParent.set(key, list);
  }
  const expanded = new Set<UUID>();
  const queue = roots.map(toSwiftUUID);
  for (let idx = 0; idx < queue.length; idx++) {
    const cur = queue[idx];
    if (expanded.has(cur)) continue;
    expanded.add(cur);
    for (const child of childrenByParent.get(cur) ?? []) {
      queue.push(child.id);
    }
  }
  return expanded;
}

function matchPreferredFolders(
  names: readonly string[],
  folders: readonly FolderRecord[],
  paths: Map<UUID, string>,
): Set<UUID> {
  if (names.length === 0) return new Set();
  const normalized = names.map(normalizeSearchText).filter(Boolean);
  const matched: UUID[] = [];
  for (const folder of folders) {
    const nameNorm = normalizeSearchText(folder.name);
    const pathNorm = normalizeSearchText(paths.get(folder.id) ?? folder.name);
    if (
      normalized.some(
        (q) => nameNorm.includes(q) || q.includes(nameNorm) || pathNorm.includes(q),
      )
    ) {
      matched.push(folder.id);
    }
  }
  return expandFolderScope(matched, folders);
}

function scoreAgentCandidate(params: {
  asset: AssetRecord;
  seeds: AssetRecord[];
  preferredFolderIDs: Set<UUID>;
  keywordRanks: Map<UUID, number>;
  targetColors: LabColor[];
  colorTolerance: number;
  queryVector: number[] | null;
  embeddingIdentity: string | null;
  vectors: Map<UUID, AssetVector>;
}): ScoredAsset {
  const { asset, seeds, preferredFolderIDs, keywordRanks, targetColors, colorTolerance, queryVector, embeddingIdentity, vectors } = params;
  const signals: Array<{ value: number; weight: number; reason: string }> = [];

  if (keywordRanks.size > 0) {
    signals.push({ value: keywordRanks.get(asset.id) ?? 0, weight: 0.44, reason: '关键词匹配' });
  }
  if (preferredFolderIDs.size > 0) {
    const inFolder = Boolean(asset.folderID && preferredFolderIDs.has(asset.folderID));
    signals.push({ value: inFolder ? 1.0 : 0.0, weight: 0.34, reason: '所属文件夹吻合' });
  }

  const vec = vectors.get(asset.id);
  if (vec?.embedding && vec.embedding.length > 0) {
    const cloudSims: number[] = [];
    if (queryVector && vec.embeddingModel === embeddingIdentity) {
      cloudSims.push(Math.max(0, Math.min(1, cosineSimilarity(vec.embedding, queryVector))));
    }
    for (const seed of seeds) {
      const other = vectors.get(seed.id);
      if (other?.embedding && other.embeddingModel === vec.embeddingModel) {
        cloudSims.push(Math.max(0, Math.min(1, cosineSimilarity(vec.embedding, other.embedding))));
      }
    }
    if (cloudSims.length > 0) {
      signals.push({ value: Math.max(...cloudSims), weight: 0.42, reason: '语义接近' });
    }
  }

  if (vec?.featurePrint && seeds.length > 0) {
    const sims: number[] = [];
    for (const seed of seeds) {
      const s = featurePrintSimilarity(vec.featurePrint, vectors.get(seed.id)?.featurePrint);
      if (s !== null) sims.push(s);
    }
    if (sims.length > 0) {
      signals.push({ value: Math.max(...sims), weight: 0.36, reason: '画面风格接近' });
    }
  }

  const effectiveColors =
    targetColors.length === 0 ? seeds.flatMap((s) => s.dominantColors.slice(0, 3)) : targetColors;
  if (effectiveColors.length > 0) {
    let sim = 0;
    if (targetColors.length === 0) {
      const avgDelta = weightedPaletteDistance(asset.dominantColors, effectiveColors);
      if (avgDelta !== null) {
        if (avgDelta <= 6.0) sim = 1.0;
        else if (avgDelta < 22.0) sim = Math.pow((22.0 - avgDelta) / 16.0, 1.1);
      }
    } else {
      const dist = significantSwatchDistance(asset.dominantColors, effectiveColors);
      if (dist !== null) {
        if (dist <= colorTolerance) {
          sim = 1.0 - (dist / Math.max(1.0, colorTolerance)) * 0.35;
        } else {
          const cutoff = Math.max(colorTolerance * 1.6, colorTolerance + 14.0);
          if (dist < cutoff) {
            sim = 0.25 * ((cutoff - dist) / Math.max(1.0, cutoff - colorTolerance));
          }
        }
      }
    }
    signals.push({ value: sim, weight: targetColors.length === 0 ? 0.2 : 0.42, reason: '色彩吻合' });
  }

  if (seeds.length > 0) {
    const assetTags = new Set(
      [...asset.tags, ...asset.suggestedTags].map(normalizeSearchText).filter(Boolean),
    );
    let maxOverlap = 0;
    for (const seed of seeds) {
      const peer = new Set(
        [...seed.tags, ...seed.suggestedTags].map(normalizeSearchText).filter(Boolean),
      );
      if (peer.size === 0 || assetTags.size === 0) continue;
      let inter = 0;
      for (const t of peer) {
        if (assetTags.has(t)) inter++;
      }
      const jaccard = inter / Math.max(1, peer.size + assetTags.size - inter);
      if (jaccard > maxOverlap) maxOverlap = jaccard;
    }
    signals.push({ value: maxOverlap, weight: 0.16, reason: '标签相近' });
  }

  const weightedSum = signals.reduce((acc, s) => acc + s.value * s.weight, 0);
  const capacity = Math.max(0.35, signals.reduce((acc, s) => acc + s.weight, 0));
  const rating = Math.min(5, Math.max(0, asset.rating)) / 5.0;
  const finalScore =
    signals.length === 0
      ? 0.35 + 0.15 * rating
      : Math.min(1.0, 0.06 * rating + 0.94 * (weightedSum / capacity));
  const matchReasons = signals
    .filter((s) => s.value > 0.25)
    .sort((a, b) => b.value * b.weight - a.value * a.weight)
    .map((s) => s.reason);

  return { asset, score: finalScore, matchReasons };
}

/**
 * Shared grounded tool layer powering BOTH `MoodboardAgentHarness` and External Agent MCP.
 */
export class CharkleAgentTools {
  readonly db: LibraryDatabase;
  readonly media: IMediaPipeline;

  constructor(db: LibraryDatabase, media: IMediaPipeline) {
    this.db = db;
    this.media = media;
  }

  async preparedTypeSafeJPEG(asset: AssetRecord, targetLongSide = 448): Promise<Buffer | null> {
    const preferHighRes = targetLongSide > 520;
    let raw: Buffer | null = null;
    if (preferHighRes) {
      raw = await this.media.readThumbnailBuffer(asset.id, 'preview1400');
    }
    if (!raw) {
      raw = await this.media.readThumbnailBuffer(asset.id, 'grid520');
    }
    if (!raw && (asset.mediaKind === 'image' || asset.mediaKind === 'animatedImage')) {
      raw = await this.media.readOriginalBuffer(asset);
    }
    if (!raw) return null;
    const prep = await TypeSafeImagePreparer.prepareJPEG(raw, targetLongSide);
    return prep?.data ?? null;
  }

  libraryOverview(): AgentLibraryOverview {
    const assets = this.db.fetchAssets({ includeTrashed: false });
    const folders = this.db.fetchFolders();
    const tags = this.db.fetchTagCounts();
    const boards = this.db.fetchBoards();
    const folderPaths = buildFolderPathsMap(folders);

    const countsByFolder = new Map<UUID, number>();
    const mediaKindCounts: Record<string, number> = {};
    let inboxCount = 0;

    for (const asset of assets) {
      if (asset.folderID) {
        countsByFolder.set(asset.folderID, (countsByFolder.get(asset.folderID) ?? 0) + 1);
      } else {
        inboxCount += 1;
      }
      mediaKindCounts[asset.mediaKind] = (mediaKindCounts[asset.mediaKind] ?? 0) + 1;
    }

    const folderInfos = folders
      .map((f) => ({
        id: f.id,
        name: f.name,
        path: folderPaths.get(f.id) ?? f.name,
        assetCount: countsByFolder.get(f.id) ?? 0,
      }))
      .sort((a, b) => a.path.localeCompare(b.path));

    return {
      totalAssets: assets.length,
      inboxCount,
      folders: folderInfos,
      topTags: tags.slice(0, 40),
      mediaKindCounts,
      boardCount: boards.length,
    };
  }

  async recallCandidates(params: {
    request: MoodboardCurationRequest;
    expandedQueries?: string[];
    preferredFolderNames?: string[];
    inferredColors?: LabColor[];
    provider?: CloudAIProvider | null;
    maxCandidates?: number;
  }): Promise<AgentRecallResult> {
    const {
      request,
      expandedQueries = [],
      preferredFolderNames = [],
      inferredColors = [],
      provider = null,
      maxCandidates = 32,
    } = params;

    const allAssets = this.db.fetchAssets({ includeTrashed: false });
    const folders = this.db.fetchFolders();
    const folderPathByID = buildFolderPathsMap(folders);
    const vectors = this.db.getAllVectors();

    const excluded = new Set(request.excludedAssetIDs.map(toSwiftUUID));
    const allowedFolderIDs = expandFolderScope(request.scopeFolderIDs, folders);
    const requiredTagSet = new Set(request.requiredTags.map(normalizeSearchText).filter(Boolean));

    const eligible = allAssets.filter((asset) => {
      if (excluded.has(asset.id)) return false;
      if (allowedFolderIDs.size > 0) {
        if (!asset.folderID || !allowedFolderIDs.has(asset.folderID)) return false;
      }
      if (requiredTagSet.size > 0) {
        const assetTags = new Set(
          [...asset.tags, ...asset.suggestedTags].map(normalizeSearchText).filter(Boolean),
        );
        for (const reqTag of requiredTagSet) {
          if (!assetTags.has(reqTag)) return false;
        }
      }
      return true;
    });

    const eligibleByID = new Map(eligible.map((a) => [a.id, a]));
    const mustIncludeIDs: UUID[] = [];
    const mustSeen = new Set<UUID>();
    const addMust = (rawId: UUID) => {
      const id = toSwiftUUID(rawId);
      if (!excluded.has(id) && eligibleByID.has(id) && !mustSeen.has(id)) {
        mustSeen.add(id);
        mustIncludeIDs.push(id);
      }
    };
    for (const id of request.lockedAssetIDs) addMust(id);
    for (const id of request.seedAssetIDs) addMust(id);
    if (request.existingBoard) {
      for (const id of getBoardReferencedAssetIDs(request.existingBoard)) addMust(id);
    }

    const queries = uniqueStringsCaseInsensitive([
      request.prompt,
      request.refinementInstruction ?? '',
      ...expandedQueries,
    ]).filter((q) => q.trim().length > 0);

    const keywordRanks = new Map<UUID, number>();
    for (const query of queries.slice(0, 12)) {
      for (const [id, rank] of this.db.searchRanks(query)) {
        keywordRanks.set(id, Math.max(keywordRanks.get(id) ?? 0, rank));
      }
      const terms = query.split(/\s+/).filter(Boolean);
      if (terms.length > 1) {
        for (const term of terms.slice(0, 8)) {
          for (const [id, rank] of this.db.searchRanks(term)) {
            keywordRanks.set(id, Math.max(keywordRanks.get(id) ?? 0, rank * 0.72));
          }
        }
      }
    }

    const preferredFolderIDs = matchPreferredFolders(preferredFolderNames, folders, folderPathByID);
    const seedAssets = request.seedAssetIDs
      .map((id) => eligibleByID.get(toSwiftUUID(id)))
      .filter((a): a is AssetRecord => Boolean(a));
    const targetColors = request.targetPalette.length > 0 ? request.targetPalette : inferredColors;

    let queryVector: number[] | null = null;
    const primaryQueryText = [request.prompt, request.refinementInstruction ?? '']
      .map((s) => s.trim())
      .filter(Boolean)
      .join(' ');

    if (provider && primaryQueryText) {
      let hasCompat = false;
      for (const v of vectors.values()) {
        if (v.embeddingModel === provider.embeddingIdentity && v.embedding) {
          hasCompat = true;
          break;
        }
      }
      if (hasCompat) {
        try {
          queryVector = await provider.embed(primaryQueryText);
        } catch {
          queryVector = null;
        }
      }
    }

    const scoresByID = new Map<UUID, ScoredAsset>();
    for (const asset of eligible) {
      const scored = scoreAgentCandidate({
        asset,
        seeds: seedAssets,
        preferredFolderIDs,
        keywordRanks,
        targetColors,
        colorTolerance: request.colorTolerance,
        queryVector,
        embeddingIdentity: provider?.embeddingIdentity ?? null,
        vectors,
      });
      scoresByID.set(asset.id, scored);
    }

    const mustAssets = mustIncludeIDs
      .map((id) => eligibleByID.get(id))
      .filter((a): a is AssetRecord => Boolean(a));
    const rest = eligible
      .filter((a) => !mustSeen.has(a.id))
      .sort((lhs, rhs) => {
        const ls = scoresByID.get(lhs.id)?.score ?? 0;
        const rs = scoresByID.get(rhs.id)?.score ?? 0;
        if (Math.abs(ls - rs) > 0.001) return rs - ls;
        if (lhs.rating !== rhs.rating) return rhs.rating - lhs.rating;
        return rhs.createdAt.localeCompare(lhs.createdAt);
      });

    const orderedCandidates =
      eligible.length <= maxCandidates
        ? [...mustAssets, ...rest]
        : [...mustAssets, ...rest.slice(0, Math.max(0, maxCandidates - mustAssets.length))];

    return {
      eligibleTotal: eligible.length,
      candidates: orderedCandidates,
      scoresByID,
      folderPathByID,
    };
  }

  async buildContactSheets(params: {
    candidates: AssetRecord[];
    folderPathByID: Map<UUID, string>;
    seedIDs?: Set<UUID>;
    lockedIDs?: Set<UUID>;
    existingBoardIDs?: Set<UUID>;
    sheetCapacity?: number;
    format?: 'png' | 'jpeg';
  }): Promise<ContactSheetPackage> {
    const {
      candidates,
      folderPathByID,
      seedIDs = new Set(),
      lockedIDs = new Set(),
      existingBoardIDs = new Set(),
      sheetCapacity = 16,
      format = 'jpeg',
    } = params;

    const sheets: ContactSheetBatch[] = [];
    const slotToAsset = new Map<number, AssetRecord>();
    const manifestLines: string[] = [];

    let slot = 1;
    let currentEntries: ContactSheetEntry[] = [];

    const flushSheet = async () => {
      if (currentEntries.length === 0) return;
      const batch = await ContactSheetRenderer.render(currentEntries, { format });
      if (batch) sheets.push(batch);
      currentEntries = [];
    };

    for (const asset of candidates) {
      const currentSlot = slot++;
      slotToAsset.set(currentSlot, asset);
      const thumbPath =
        this.media.getThumbnailPath(asset.id, 'grid520') ??
        this.media.getThumbnailPath(asset.id, 'preview1400');
      const thumbBuf = thumbPath
        ? null
        : ((await this.media.readThumbnailBuffer(asset.id, 'grid520')) ??
            (await this.media.readThumbnailBuffer(asset.id, 'preview1400')));

      currentEntries.push({
        slot: currentSlot,
        asset,
        thumbnailPath: thumbPath,
        thumbnailBuffer: thumbBuf,
      });

      const flags: string[] = [];
      if (lockedIDs.has(asset.id)) flags.push('LOCKED_MUST_KEEP');
      if (seedIDs.has(asset.id)) flags.push('USER_SEED');
      if (existingBoardIDs.has(asset.id)) flags.push('CURRENTLY_ON_BOARD');

      const folderLabel = (asset.folderID && folderPathByID.get(asset.folderID)) || 'Inbox';
      const colors = asset.dominantColors.slice(0, 3).map((c) => c.hex).join(',');
      const tags = [...asset.tags, ...asset.suggestedTags].slice(0, 6).join(',');
      const ratioStr = getAssetAspectRatio(asset).toFixed(2);
      const desc = (asset.aiDescription || asset.notes || '').replace(/\n/g, ' ').slice(0, 120);
      const ocr = (asset.ocrText || '').replace(/\n/g, ' ').slice(0, 60);

      let line = `#${String(currentSlot).padStart(2, '0')} | kind=${asset.mediaKind} | ratio=${ratioStr} | folder=${folderLabel} | title=${asset.title.slice(0, 48)}`;
      if (colors) line += ` | colors=${colors}`;
      if (tags) line += ` | tags=${tags}`;
      if (desc) line += ` | desc=${desc}`;
      if (ocr) line += ` | ocr=${ocr}`;
      if (flags.length > 0) line += ` | flags=${flags.join(',')}`;
      manifestLines.push(line);

      if (currentEntries.length >= sheetCapacity) {
        await flushSheet();
      }
    }
    await flushSheet();

    return {
      sheets,
      slotToAsset,
      manifestText: manifestLines.join('\n'),
    };
  }

  compileAndVerifyBoard(params: {
    plan: AgentBoardPlan;
    slotToAsset: Map<number, AssetRecord>;
    request: MoodboardCurationRequest;
    recall: AgentRecallResult;
  }): VerifiedBoardCompilation {
    const { plan, slotToAsset, request, recall } = params;
    const vectors = this.db.getAllVectors();
    const excluded = new Set(request.excludedAssetIDs.map(toSwiftUUID));
    const locked = new Set(request.lockedAssetIDs.map(toSwiftUUID));
    const seeds = new Set(request.seedAssetIDs.map(toSwiftUUID));
    const maxPrimary = Math.max(1, Math.min(32, request.preferredCount));

    const issues: string[] = [];
    const usedPrimaryIDs = new Set<UUID>();
    const primaryAssets: AssetRecord[] = [];
    const primaryScored: ScoredAsset[] = [];
    const verifiedSections: MoodboardSectionDraft[] = [];
    const demotedDuplicates: ScoredAsset[] = [];

    const isNearDuplicateOfSelected = (candidate: AssetRecord): boolean => {
      if (locked.has(candidate.id) || seeds.has(candidate.id)) return false;
      for (const chosen of primaryAssets) {
        if (candidate.contentHash && candidate.contentHash === chosen.contentHash) {
          return true;
        }
        const fpSim = featurePrintSimilarity(
          vectors.get(candidate.id)?.featurePrint,
          vectors.get(chosen.id)?.featurePrint,
        );
        if (fpSim !== null && fpSim > 0.96) {
          return true;
        }
      }
      return false;
    };

    for (const section of plan.sections) {
      const sectionAssetIDs: UUID[] = [];
      const sectionHeroIDs: UUID[] = [];
      for (const pick of section.picks) {
        const asset = slotToAsset.get(pick.slot);
        if (!asset) {
          issues.push(`忽略无效编号 #${pick.slot}`);
          continue;
        }
        if (excluded.has(asset.id)) {
          issues.push(`已拦截用户排除的素材 #${pick.slot}`);
          continue;
        }
        if (usedPrimaryIDs.has(asset.id)) continue;

        if (primaryAssets.length >= maxPrimary && !locked.has(asset.id) && !seeds.has(asset.id)) {
          demotedDuplicates.push({
            asset,
            score: 0.78,
            matchReasons: [pick.reason || '备选推荐'],
          });
          continue;
        }
        if (isNearDuplicateOfSelected(asset)) {
          demotedDuplicates.push({
            asset,
            score: 0.72,
            matchReasons: ['与已选图高度相似，移入备选池'],
          });
          continue;
        }

        usedPrimaryIDs.add(asset.id);
        primaryAssets.push(asset);
        sectionAssetIDs.push(asset.id);
        if (pick.weight >= 2) sectionHeroIDs.push(asset.id);
        const reason = pick.reason.trim();
        primaryScored.push({
          asset,
          score: pick.weight >= 2 ? 0.98 : 0.9,
          matchReasons: [reason || section.title],
        });
      }

      if (sectionAssetIDs.length > 0) {
        verifiedSections.push({
          id: toSwiftUUID(randomUUID()),
          title: section.title.trim() || '核心参考',
          tint: section.tint,
          rationale: section.rationale,
          assetIDs: sectionAssetIDs,
          heroAssetIDs: sectionHeroIDs,
        });
      }
    }

    // Guarantee every user-locked & seed asset is preserved
    const requiredKeep = [...request.lockedAssetIDs, ...request.seedAssetIDs].map(toSwiftUUID);
    const missingRequired: AssetRecord[] = [];
    for (const id of requiredKeep) {
      if (excluded.has(id) || usedPrimaryIDs.has(id)) continue;
      const asset = recall.candidates.find((a) => a.id === id);
      if (asset) {
        usedPrimaryIDs.add(id);
        primaryAssets.unshift(asset);
        missingRequired.push(asset);
        primaryScored.unshift({
          asset,
          score: 1.0,
          matchReasons: [locked.has(id) ? '已锁定保留' : '种子图'],
        });
      }
    }

    if (missingRequired.length > 0) {
      if (verifiedSections.length === 0) {
        verifiedSections.push({
          id: toSwiftUUID(randomUUID()),
          title: '定调核心参考',
          tint: 'neutral',
          rationale: '包含你指定的种子与锁定素材',
          assetIDs: missingRequired.map((a) => a.id),
          heroAssetIDs: missingRequired[0] ? [missingRequired[0].id] : [],
        });
      } else {
        verifiedSections[0] = {
          ...verifiedSections[0],
          assetIDs: [...missingRequired.map((a) => a.id), ...verifiedSections[0].assetIDs],
        };
      }
    }

    // Build grounded candidate swap pool
    const candidateScored: ScoredAsset[] = [];
    const candidateSeen = new Set<UUID>(usedPrimaryIDs);
    for (const pick of plan.candidatePicks) {
      const asset = slotToAsset.get(pick.slot);
      if (!asset || excluded.has(asset.id) || candidateSeen.has(asset.id)) continue;
      candidateSeen.add(asset.id);
      candidateScored.push({
        asset,
        score: 0.76,
        matchReasons: [pick.reason.trim() || '同方向备选'],
      });
    }
    for (const demoted of demotedDuplicates) {
      if (!excluded.has(demoted.asset.id) && !candidateSeen.has(demoted.asset.id)) {
        candidateSeen.add(demoted.asset.id);
        candidateScored.push(demoted);
      }
    }
    const extraCandidates = recall.candidates
      .filter((a) => !excluded.has(a.id) && !candidateSeen.has(a.id))
      .map((a) => recall.scoresByID.get(a.id))
      .filter((s): s is ScoredAsset => Boolean(s))
      .sort((a, b) => b.score - a.score);

    const remainingSlots = Math.max(0, request.candidateCount - candidateScored.length);
    for (const extra of extraCandidates.slice(0, remainingSlots)) {
      if (!candidateSeen.has(extra.asset.id)) {
        candidateSeen.add(extra.asset.id);
        candidateScored.push(extra);
      }
    }

    const paletteSource = primaryAssets.flatMap((a) => a.dominantColors);
    const extractedPalette = MoodboardCurator.harmonizePalette(
      paletteSource.length > 0 ? paletteSource : request.targetPalette,
      6,
    );

    const assetByID = new Map(primaryAssets.map((a) => [a.id, a]));
    const effectiveStyle = request.layoutStyle;
    const useFreeformLayout = request.useFreeformLayout ?? true;
    const nodes = CharkleAgentTools.buildBoardNodes({
      sections: verifiedSections,
      assetByID,
      curatorNote: request.includeCuratorNotes ? plan.curatorNote : null,
      extractedPalette,
      includeSectionHeaders:
        request.includeCuratorNotes &&
        (verifiedSections.length >= 2 ||
          (verifiedSections.length === 1 && verifiedSections[0].rationale.length > 0)),
      useFreeformLayout,
      style: effectiveStyle,
    });

    const cleanTitle = plan.boardTitle.trim();
    const fallbackTitle = request.prompt.trim();
    const finalTitle = cleanTitle
      ? cleanTitle.slice(0, 80)
      : fallbackTitle
        ? fallbackTitle.slice(0, 40)
        : (request.existingBoard?.title ?? 'AI 策展情绪板');
    const finalSubtitle = plan.boardSubtitle.trim();

    const boardMode: BoardLayoutMode = useFreeformLayout
      ? { type: 'freeform' }
      : {
          type: 'autoEditorial',
          config: {
            columns:
              primaryAssets.length <= 4
                ? Math.max(2, primaryAssets.length)
                : effectiveStyle === 'compact'
                  ? 4
                  : 3,
            spacing: effectiveStyle === 'compact' ? 10 : 16,
            style: effectiveStyle,
            showPaletteStrip: true,
          },
        };

    const viewportCenter =
      useFreeformLayout && nodes.length > 0
        ? {
            x: Math.max(...nodes.map((n) => n.frame.x + n.frame.width)) * 0.5,
            y: Math.min(Math.max(...nodes.map((n) => n.frame.y + n.frame.height)) * 0.5, 420),
          }
        : (request.existingBoard?.viewportCenter ?? { x: 0, y: 0 });

    const now = new Date().toISOString();
    const document: MoodboardDocument = request.existingBoard
      ? {
          ...request.existingBoard,
          title: finalTitle,
          subtitle: finalSubtitle || request.existingBoard.subtitle,
          mode: boardMode,
          nodes,
          extractedPalette,
          candidateAssetIDs: candidateScored.map((c) => c.asset.id),
          viewportCenter,
          viewportZoom: useFreeformLayout ? 1.0 : request.existingBoard.viewportZoom,
          updatedAt: now,
        }
      : createDefaultMoodboardDocument({
          id: toSwiftUUID(randomUUID()),
          title: finalTitle,
          subtitle: finalSubtitle,
          mode: boardMode,
          nodes,
          extractedPalette,
          candidateAssetIDs: candidateScored.map((c) => c.asset.id),
          viewportCenter,
        });

    const needsRepair =
      primaryAssets.length === 0 &&
      recall.candidates.length > 0 &&
      !(plan.rejectedNote && plan.rejectedNote.trim().length > 0);

    return {
      document,
      primaryMatches: primaryScored,
      candidatePool: candidateScored.slice(0, request.candidateCount),
      sections: verifiedSections,
      extractedPalette,
      issues,
      needsRepair,
    };
  }

  persistVisualInsights(insights: readonly AgentVisualInsight[]): number {
    if (insights.length === 0) return 0;
    try {
      return this.db.transaction(() => {
        const existingLibraryTags = this.db.fetchTagCounts().map((t) => t.name);
        let updatedCount = 0;
        for (const insight of insights) {
          const asset = this.db.getAsset(insight.assetID);
          if (!asset) continue;
          const cleanDesc = insight.description.trim();
          const normalizedTags = CloudTagNormalizer.canonicalizeSuggestedTags(
            [...asset.suggestedTags, ...insight.tags],
            existingLibraryTags,
            asset.tags,
            CloudTagNormalizer.preferredLanguage(),
            6,
          );
          let changed = false;
          const next: AssetRecord = { ...asset };
          if ((!asset.aiDescription || !asset.aiDescription.trim()) && cleanDesc) {
            next.aiDescription = cleanDesc.slice(0, 600);
            changed = true;
          }
          if (
            insight.tags.length > 0 &&
            JSON.stringify(normalizedTags) !== JSON.stringify(asset.suggestedTags)
          ) {
            next.suggestedTags = normalizedTags;
            changed = true;
          }
          if (changed) {
            this.db.saveAssetLocally(next, false);
            updatedCount += 1;
          }
        }
        return updatedCount;
      });
    } catch {
      return 0;
    }
  }

  static buildBoardNodes(params: {
    sections: MoodboardSectionDraft[];
    assetByID: Map<UUID, AssetRecord>;
    curatorNote: AgentNoteSpec | null;
    extractedPalette: LabColor[];
    includeSectionHeaders: boolean;
    useFreeformLayout: boolean;
    style: EditorialStyle;
  }): BoardNode[] {
    const {
      sections,
      assetByID,
      curatorNote,
      extractedPalette,
      includeSectionHeaders,
      useFreeformLayout,
      style,
    } = params;

    const nodes: BoardNode[] = [];
    const now = new Date().toISOString();
    let order = 0;
    let cursorY = 32;
    const canvasWidth = 1140;
    const gap = style === 'compact' ? 12 : 18;

    const pushNode = (kind: BoardNode['kind'], frame: BoardNode['frame']) => {
      nodes.push({
        id: toSwiftUUID(randomUUID()),
        kind,
        frame,
        zIndex: order,
        rotationDegrees: 0,
        flipHorizontal: false,
        flipVertical: false,
        isLocked: false,
        editorialOrder: order,
        updatedAt: now,
      });
      order += 1;
    };

    if (curatorNote && curatorNote.text.trim()) {
      const noteHeight = 148;
      pushNode(
        {
          type: 'note',
          title: curatorNote.title || '视觉策展方向',
          text: curatorNote.text,
          style: curatorNote.style,
          fontSize: 13.5,
        },
        { x: 32, y: cursorY, width: useFreeformLayout ? 360 : 320, height: noteHeight },
      );
      if (useFreeformLayout) {
        if (extractedPalette.length > 0) {
          pushNode(
            { type: 'paletteStrip', colors: extractedPalette, autoSyncWithBoard: true },
            { x: 412, y: cursorY, width: canvasWidth - 412, height: 84 },
          );
        }
        cursorY += noteHeight + 28;
      }
    } else if (useFreeformLayout && extractedPalette.length > 0) {
      pushNode(
        { type: 'paletteStrip', colors: extractedPalette, autoSyncWithBoard: true },
        { x: 32, y: cursorY, width: canvasWidth - 32, height: 78 },
      );
      cursorY += 104;
    }

    for (let sIdx = 0; sIdx < sections.length; sIdx++) {
      const section = sections[sIdx];
      const sectionAssets = section.assetIDs
        .map((id) => assetByID.get(id))
        .filter((a): a is AssetRecord => Boolean(a));
      if (sectionAssets.length === 0) continue;
      const heroSet = new Set(section.heroAssetIDs);

      if (includeSectionHeaders) {
        const headerText = section.rationale
          ? `${section.title} · ${section.rationale}`
          : section.title;
        pushNode(
          { type: 'groupFrame', title: headerText.slice(0, 72), tint: section.tint },
          { x: 32, y: cursorY, width: canvasWidth - 32, height: 60 },
        );
        cursorY += 76;
      }

      if (useFreeformLayout) {
        let rowStart = 0;
        while (rowStart < sectionAssets.length) {
          const hasHeroInRow = heroSet.has(sectionAssets[rowStart].id);
          const rowCount = Math.min(hasHeroInRow ? 3 : 4, sectionAssets.length - rowStart);
          const row = sectionAssets.slice(rowStart, rowStart + rowCount);
          const ratios = row.map((a) => Math.min(2.0, Math.max(0.62, getAssetAspectRatio(a))));
          const weights = row.map((item, idx) => {
            const boost = heroSet.has(item.id) ? 1.38 : idx === 0 && hasHeroInRow ? 1.25 : 1.0;
            return ratios[idx] * boost;
          });
          const rowHeight = Math.min(
            380,
            Math.max(
              165,
              (canvasWidth - 32 - (rowCount - 1) * gap) /
                Math.max(0.5, weights.reduce((a, b) => a + b, 0)),
            ),
          );
          let x = 32;
          for (let i = 0; i < row.length; i++) {
            const asset = row[i];
            const w = rowHeight * weights[i];
            pushNode(
              {
                type: 'assetRef',
                assetID: asset.id,
                crop: null,
                weight: heroSet.has(asset.id) ? 2 : 1,
                autoplayLoop: asset.mediaKind === 'animatedImage' || asset.mediaKind === 'video',
              },
              { x, y: cursorY, width: w, height: rowHeight },
            );
            x += w + gap;
          }
          cursorY += rowHeight + gap;
          rowStart += rowCount;
        }
        cursorY += 20;
      } else {
        for (let idx = 0; idx < sectionAssets.length; idx++) {
          const asset = sectionAssets[idx];
          const isHero = heroSet.has(asset.id) || (sIdx === 0 && idx === 0 && heroSet.size === 0);
          const ratio = Math.min(2.0, Math.max(0.62, getAssetAspectRatio(asset)));
          const w = isHero ? 420 : 260;
          pushNode(
            {
              type: 'assetRef',
              assetID: asset.id,
              crop: null,
              weight: isHero ? 2 : 1,
              autoplayLoop: asset.mediaKind === 'animatedImage' || asset.mediaKind === 'video',
            },
            { x: 32, y: cursorY, width: w, height: w / ratio },
          );
        }
      }
    }

    if (!useFreeformLayout && extractedPalette.length > 0) {
      pushNode(
        { type: 'paletteStrip', colors: extractedPalette, autoSyncWithBoard: true },
        { x: 32, y: cursorY + 12, width: canvasWidth - 32, height: 76 },
      );
    }

    return nodes;
  }
}

// MARK: - Moodboard Agent Harness (Multi-Phase Orchestrator)

const VISUAL_CURATOR_SYSTEM_PROMPT = `You are Charkle's Senior Art Director & Visual Moodboard Curator Agent.
You are given numbered Visual Contact Sheet image(s) where every candidate asset has a crisp top-left \`#01\`, \`#02\`, ... slot badge, plus a grounded metadata manifest.

CORE CURATION PRINCIPLES (STRICT):
1. **LOOK AT THE ACTUAL IMAGES** on the Contact Sheets! Do not rely solely on filenames.
2. **QUALITY OVER QUANTITY (宁缺毋滥)**: NEVER pad the board with off-brief images just to reach the target count! Explain exclusions in \`rejectedNote\`.
3. **GROUNDED INTEGER SLOTS ONLY**: Every \`slot\` MUST be an integer visible on the Contact Sheet (\`1..N\`). Never invent slots or repeat a slot across sections.
4. **HONOR USER LOCKS & SEEDS**: Any slot flagged \`LOCKED_MUST_KEEP\` or \`USER_SEED\` MUST be included on the board.
5. **EDITORIAL COMPOSITION**: Group selected assets into 1–3 meaningful Chinese visual sections, mark 1–2 strongest focal images with \`weight: 2\` (Hero), and write a concise Chinese art-direction note.
6. **VISUAL INSIGHTS**: For images lacking \`desc=\`, briefly fill \`visualInsights\` with concise monolingual Chinese description and 2–5 short monolingual tags (no bilingual pairs, no \`#\`).

OUTPUT ONLY ONE VALID JSON OBJECT matching this schema:
{
  "boardTitle": "简短优雅的中文情绪板标题",
  "boardSubtitle": "一句话策展方向总结",
  "curatorNote": {
    "title": "视觉定调说明",
    "text": "2-3句专业克制的中文设计策展说明",
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
}`;

class AgentTraceRecorder {
  private readonly steps: MoodboardAgentStep[] = [];
  private readonly onStep?: (step: MoodboardAgentStep) => void | Promise<void>;

  constructor(onStep?: (step: MoodboardAgentStep) => void | Promise<void>) {
    this.onStep = onStep;
  }

  async emit(
    phase: MoodboardAgentPhase,
    title: string,
    detail: string,
    status: MoodboardAgentStepStatus,
  ): Promise<void> {
    let step: MoodboardAgentStep;
    let existingIdx = -1;
    for (let i = this.steps.length - 1; i >= 0; i--) {
      if (this.steps[i].phase === phase && this.steps[i].status === 'running') {
        existingIdx = i;
        break;
      }
    }
    const timestamp = new Date().toISOString();
    if (existingIdx >= 0) {
      step = { ...this.steps[existingIdx], title, detail, status, timestamp };
      this.steps[existingIdx] = step;
    } else {
      step = {
        id: toSwiftUUID(randomUUID()),
        phase,
        title,
        detail,
        status,
        timestamp,
      };
      this.steps.push(step);
    }
    if (this.onStep) {
      await this.onStep(step);
    }
  }

  snapshot(): MoodboardAgentStep[] {
    return this.steps.map((s) => ({ ...s }));
  }
}

export interface CurateHarnessOptions {
  request: MoodboardCurationRequest;
  provider?: CloudAIProvider | null;
  typeSafeConfig?: TypeSafeExperimentalConfig | null;
  typeSafeAPIKey?: string | null;
  grounding?: VisualGroundingEngine | null;
  onStep?: (step: MoodboardAgentStep) => void | Promise<void>;
}

export class MoodboardAgentHarness {
  readonly tools: CharkleAgentTools;

  constructor(db: LibraryDatabase, media: IMediaPipeline) {
    this.tools = new CharkleAgentTools(db, media);
  }

  async curate(opts: CurateHarnessOptions): Promise<MoodboardProposal> {
    const {
      request,
      provider = null,
      typeSafeConfig = null,
      typeSafeAPIKey = null,
      grounding = null,
      onStep,
    } = opts;

    const recorder = new AgentTraceRecorder(onStep);

    // Stage 1: Planning
    await recorder.emit('planning', '读取素材库结构与策展目标', '扫描文件夹树、标签分布与约束条件…', 'running');
    const overview = this.tools.libraryOverview();

    let expandedQueries: string[] = [];
    let preferredFolderNames: string[] = [];
    let inferredColors: LabColor[] = [];

    const hasBriefText =
      request.prompt.trim().length > 0 || (request.refinementInstruction ?? '').trim().length > 0;

    if (provider && hasBriefText && overview.totalAssets > 32 && request.scopeFolderIDs.length === 0) {
      await recorder.emit(
        'planning',
        '拆解灵感方向与检索策略',
        '正在由模型扩展中英双语视觉关键词与匹配目录…',
        'running',
      );
      try {
        const planned = await this.runRetrievalPlanner(request, overview, provider);
        expandedQueries = planned.searchQueries;
        preferredFolderNames = planned.preferredFolders;
        inferredColors = planned.targetColorHexes.map((h) => labFromHex(h));
      } catch {
        // Planner is best-effort
      }
    }

    await recorder.emit(
      'planning',
      `已分析素材库全貌（共 ${overview.totalAssets} 项素材 · ${overview.folders.length} 个文件夹）`,
      expandedQueries.length > 0
        ? `扩展检索维度：${expandedQueries.slice(0, 5).join(' / ')}`
        : overview.totalAssets <= 32
          ? '素材库规模适中，将直接全览所有符合范围的素材进行视觉审片'
          : '已确定多路召回范围',
      'done',
    );

    // Stage 2: Multi-Route Recall
    await recorder.emit('retrieving', '多路召回候选素材', '按文件夹、标签、视觉相似与色彩过滤候选池…', 'running');
    let recall = await this.tools.recallCandidates({
      request,
      expandedQueries,
      preferredFolderNames,
      inferredColors,
      provider,
      maxCandidates: 32,
    });

    if (recall.candidates.length === 0) {
      await recorder.emit(
        'retrieving',
        '未找到符合当前限定条件的素材',
        '请放宽文件夹/标签限制，或先导入相关参考素材',
        'warning',
      );
      const emptyDoc =
        request.existingBoard ??
        createDefaultMoodboardDocument({
          id: toSwiftUUID(randomUUID()),
          title: request.prompt.trim() ? request.prompt.trim().slice(0, 40) : '新情绪板',
          subtitle: '当前限定范围内暂无匹配素材',
        });
      return {
        draftDocument: emptyDoc,
        primaryMatches: [],
        candidatePool: [],
        extractedPalette: request.targetPalette,
        usedCloudAI: false,
        curatedSummary: '当前限定条件（文件夹/标签/排除项）下暂无可用素材，请放宽条件后重试。',
        agentTrace: recorder.snapshot(),
        sections: [],
        rejectedSummary: null,
        cachedVisualInsightsCount: 0,
      };
    }

    // Stage 2.5: Optional TypeSafe Jev Score Visual Rerank
    let usedTypeSafeVisualRerank = false;
    const queryBrief = [request.prompt, request.refinementInstruction ?? '']
      .map((s) => s.trim())
      .filter(Boolean)
      .join('；');

    if (
      typeSafeConfig?.enabled &&
      typeSafeConfig.enableCuratorVisualRerank &&
      typeSafeAPIKey?.trim() &&
      grounding &&
      queryBrief
    ) {
      const visualCount = Math.min(recall.candidates.length, 24);
      await recorder.emit(
        'retrieving',
        `TypeSafe Jev 正在视觉精排候选池（${visualCount} 张）`,
        '直接看图按 0–3 校准分数评估主题与氛围契合度，发现未打标高匹配作品…',
        'running',
      );
      const visualInputs: VisualCandidateInput[] = await Promise.all(
        recall.candidates.slice(0, 24).map(async (asset) => ({
          assetID: asset.id,
          title: asset.title,
          tags: asset.tags,
          description: asset.aiDescription,
          imageData: await this.tools.preparedTypeSafeJPEG(asset, 384),
          imageFormat: 'jpg' as const,
        })),
      );
      try {
        const jevScores = await grounding.scoreCandidatesForQuery({
          query: queryBrief,
          candidates: visualInputs,
          config: typeSafeConfig,
          apiKey: typeSafeAPIKey,
          batchSize: 4,
          maxConcurrency: 3,
        });
        if (jevScores.length > 0) {
          usedTypeSafeVisualRerank = true;
          const scoreMap = new Map(jevScores.map((s) => [s.assetID, s]));
          const updatedScores = new Map(recall.scoresByID);
          for (const asset of recall.candidates) {
            const js = scoreMap.get(asset.id);
            if (!js) continue;
            const prior = updatedScores.get(asset.id);
            const blended = prior
              ? Math.max(js.score, prior.score * 0.35 + js.score * 0.65)
              : js.score;
            const reasons = [...(prior?.matchReasons ?? [])];
            if (js.score >= 0.45) {
              reasons.unshift(`Jev 视觉契合 ${Math.round(js.score * 100)}%`);
            }
            updatedScores.set(asset.id, { asset, score: blended, matchReasons: reasons });
          }
          const reordered = [...recall.candidates].sort((lhs, rhs) => {
            const ls = updatedScores.get(lhs.id)?.score ?? 0;
            const rs = updatedScores.get(rhs.id)?.score ?? 0;
            if (Math.abs(ls - rs) > 0.001) return rs - ls;
            return rhs.rating - lhs.rating;
          });
          recall = {
            ...recall,
            candidates: reordered,
            scoresByID: updatedScores,
          };
        }
      } catch {
        // Jev rerank is best-effort
      }
    }

    await recorder.emit(
      'retrieving',
      `已锁定 ${recall.candidates.length} 项候选素材进入审片${usedTypeSafeVisualRerank ? '（已由 Jev 视觉精排）' : ''}`,
      recall.eligibleTotal > recall.candidates.length
        ? `从 ${recall.eligibleTotal} 项合规素材中粗筛出 Top ${recall.candidates.length}`
        : `覆盖全部 ${recall.eligibleTotal} 项合规素材，确保无标签素材也不会遗漏`,
      'done',
    );

    // Stage 3: Multimodal Visual Contact Sheet Curation
    if (provider) {
      try {
        const pkg = await this.tools.buildContactSheets({
          candidates: recall.candidates,
          folderPathByID: recall.folderPathByID,
          seedIDs: new Set(request.seedAssetIDs.map(toSwiftUUID)),
          lockedIDs: new Set(request.lockedAssetIDs.map(toSwiftUUID)),
          existingBoardIDs: new Set(
            request.existingBoard ? getBoardReferencedAssetIDs(request.existingBoard) : [],
          ),
          sheetCapacity: 16,
          format: 'jpeg',
        });

        await recorder.emit(
          'inspectingVisuals',
          `AI 正在视觉审片与编排（${pkg.sheets.length} 张编号联系表 · ${recall.candidates.length} 张图）`,
          '直接识别每张图的构图、光影、题材与风格，宁缺毋滥挑选并划分逻辑分区…',
          'running',
        );

        const curationPrompt = MoodboardAgentHarness.buildVisualCurationPrompt(
          request,
          pkg.manifestText,
          pkg.sheets.length,
          pkg.slotToAsset.size,
        );
        const sheetImages = pkg.sheets.map((s) => s.jpegData);

        const rawOutput = await provider.completeJSON(
          VISUAL_CURATOR_SYSTEM_PROMPT,
          curationPrompt,
          sheetImages,
        );

        await recorder.emit('inspectingVisuals', '视觉审片完成，已生成策展方案', '开始执行编号接地、防重与约束校验…', 'done');
        await recorder.emit('verifying', '校验画布结构与防重约束', '核对真实素材 ID、锁定/排除规则与视觉去重…', 'running');

        let parsedPlan: AgentBoardPlan | null = null;
        let parseError: string | null = null;
        try {
          parsedPlan = MoodboardAgentHarness.parseBoardPlan(rawOutput, request.layoutStyle);
        } catch (err) {
          parseError = err instanceof Error ? err.message : String(err);
        }

        let compilation: VerifiedBoardCompilation | null = null;
        if (parsedPlan) {
          compilation = this.tools.compileAndVerifyBoard({
            plan: parsedPlan,
            slotToAsset: pkg.slotToAsset,
            request,
            recall,
          });
        }

        // Deterministic 1-Turn Auto-Repair
        if (!parsedPlan || compilation?.needsRepair) {
          const repairReason =
            parseError ?? (compilation?.issues.join('; ') || '未能选出有效编号');
          await recorder.emit(
            'repairing',
            '触发自动修正回合',
            `校验发现异常（${repairReason}），正在要求模型修正输出格式…`,
            'running',
          );
          const repairPrompt = [
            `上一次策展输出未通过校验：${repairReason}`,
            `请严格只输出一个合法 JSON 对象，所有 slot 必须是 1...${pkg.slotToAsset.size} 中真实存在的整数编号。`,
            '原清单回顾：',
            pkg.manifestText,
          ].join('\n');

          const repairedRaw = await provider.completeJSON(
            VISUAL_CURATOR_SYSTEM_PROMPT,
            repairPrompt,
            sheetImages,
          );
          parsedPlan = MoodboardAgentHarness.parseBoardPlan(repairedRaw, request.layoutStyle);
          compilation = this.tools.compileAndVerifyBoard({
            plan: parsedPlan,
            slotToAsset: pkg.slotToAsset,
            request,
            recall,
          });
          await recorder.emit('repairing', '自动修正完成', '修正后的策展方案已通过校验', 'done');
        }

        if (parsedPlan && compilation) {
          const insights: AgentVisualInsight[] = [];
          for (const item of parsedPlan.visualInsights) {
            const asset = pkg.slotToAsset.get(item.slot);
            if (asset) {
              insights.push({
                assetID: asset.id,
                description: item.description,
                tags: item.tags,
              });
            }
          }
          const cachedCount = this.tools.persistVisualInsights(insights);

          const finalDoc = await this.applyAutoDetailCropsIfRequested({
            document: compilation.document,
            assets: recall.candidates,
            request,
            typeSafeConfig,
            typeSafeAPIKey,
            grounding,
            recorder,
          });

          const verifyDetail =
            compilation.issues.length === 0
              ? `入选 ${compilation.primaryMatches.length} 张 · 分区 ${compilation.sections.length} 组 · 候选池 ${compilation.candidatePool.length} 张${cachedCount > 0 ? ` · 顺手沉淀 ${cachedCount} 条画面理解` : ''}`
              : `已自动修正 ${compilation.issues.length} 项约束 · 入选 ${compilation.primaryMatches.length} 张`;

          await recorder.emit('verifying', '校验通过', verifyDetail, 'done');
          await recorder.emit(
            'completed',
            'AI 情绪板策展完成',
            parsedPlan.boardSubtitle || verifyDetail,
            'done',
          );

          const summary =
            parsedPlan.curatorNote?.text.trim() ||
            parsedPlan.boardSubtitle ||
            `已从 ${recall.candidates.length} 项候选中精选 ${compilation.primaryMatches.length} 张契合素材并完成分区排版。`;

          return {
            draftDocument: finalDoc,
            primaryMatches: compilation.primaryMatches,
            candidatePool: compilation.candidatePool,
            extractedPalette: compilation.extractedPalette,
            usedCloudAI: true,
            curatedSummary: summary,
            agentTrace: recorder.snapshot(),
            sections: compilation.sections,
            rejectedSummary: parsedPlan.rejectedNote,
            cachedVisualInsightsCount: cachedCount,
          };
        }
      } catch (err) {
        const msg = err instanceof Error ? err.message : String(err);
        await recorder.emit('fallbackOffline', '云端模型暂不可用，已切换本机离线策展', msg, 'warning');
      }
    } else if (!usedTypeSafeVisualRerank) {
      await recorder.emit(
        'fallbackOffline',
        '当前为纯本机离线模式',
        '可在「设置 → 智能与搜索」开启 ChatGPT / Gemini 或 TypeSafe (Jev) 解锁看图策展',
        'warning',
      );
    }

    // Stage 4: Strict-Threshold Offline / Jev Curator
    const fallbackProposal = await this.runStrictOfflineCurator(
      request,
      recall,
      recorder,
      usedTypeSafeVisualRerank,
    );
    fallbackProposal.draftDocument = await this.applyAutoDetailCropsIfRequested({
      document: fallbackProposal.draftDocument,
      assets: recall.candidates,
      request,
      typeSafeConfig,
      typeSafeAPIKey,
      grounding,
      recorder,
    });
    fallbackProposal.agentTrace = recorder.snapshot();
    return fallbackProposal;
  }

  private async applyAutoDetailCropsIfRequested(params: {
    document: MoodboardDocument;
    assets: AssetRecord[];
    request: MoodboardCurationRequest;
    typeSafeConfig: TypeSafeExperimentalConfig | null;
    typeSafeAPIKey: string | null;
    grounding: VisualGroundingEngine | null;
    recorder: AgentTraceRecorder;
  }): Promise<MoodboardDocument> {
    const { document, assets, request, typeSafeConfig, typeSafeAPIKey, grounding, recorder } = params;
    const query = request.prompt.trim();
    if (
      !request.autoFocusDetailCrop ||
      !query ||
      !typeSafeConfig?.enabled ||
      !typeSafeAPIKey?.trim() ||
      !grounding
    ) {
      return document;
    }

    const assetsByID = new Map(assets.map((a) => [a.id, a]));
    const targets: Array<{ index: number; asset: AssetRecord }> = [];
    document.nodes.forEach((node, idx) => {
      if (node.kind.type !== 'assetRef' || node.kind.crop) return;
      const asset = assetsByID.get(node.kind.assetID);
      if (
        asset &&
        (asset.mediaKind === 'image' ||
          asset.mediaKind === 'webBookmark' ||
          asset.mediaKind === 'animatedImage')
      ) {
        targets.push({ index: idx, asset });
      }
    });
    if (targets.length === 0) return document;

    await recorder.emit(
      'composing',
      `Jev Box 细节特写聚焦（${targets.length} 张主图）`,
      `正在按「${query}」自动定位局部细节并写入非破坏性裁切框…`,
      'running',
    );

    const cropsByIndex = new Map<number, NormalizedCropRect>();
    await Promise.all(
      targets.slice(0, 12).map(async ({ index, asset }) => {
        const jpeg = await this.tools.preparedTypeSafeJPEG(asset, 640);
        if (!jpeg) return;
        try {
          const res = await grounding.locateRegion({
            query,
            imageBuffer: jpeg,
            imageFormat: 'jpg',
            config: typeSafeConfig,
            apiKey: typeSafeAPIKey,
          });
          if (res.found && isMeaningfulCropSubregion(res.crop)) {
            cropsByIndex.set(index, res.crop);
          }
        } catch {
          // Best-effort detail focus
        }
      }),
    );

    const nextNodes = document.nodes.map((node, idx) => {
      const crop = cropsByIndex.get(idx);
      if (!crop || node.kind.type !== 'assetRef') return node;
      return {
        ...node,
        kind: { ...node.kind, crop },
      };
    });

    await recorder.emit(
      'composing',
      `细节特写聚焦完成（${cropsByIndex.size}/${targets.length} 张已自动局部取景）`,
      cropsByIndex.size === 0 ? '入选作品均为整幅契合，保持原始画幅' : '每张卡片随时可右键还原完整画面',
      'done',
    );

    return { ...document, nodes: nextNodes };
  }

  private async runRetrievalPlanner(
    request: MoodboardCurationRequest,
    overview: AgentLibraryOverview,
    provider: CloudAIProvider,
  ): Promise<{ searchQueries: string[]; preferredFolders: string[]; targetColorHexes: string[] }> {
    const foldersSummary = overview.folders
      .slice(0, 30)
      .map((f) => `${f.path} (${f.assetCount})`)
      .join(', ');
    const tagsSummary = overview.topTags
      .slice(0, 30)
      .map((t) => `${t.name}(${t.count})`)
      .join(', ');

    const prompt = [
      `用户灵感需求：${request.prompt}`,
      `微调补充指令：${request.refinementInstruction || '无'}`,
      `用户素材库文件夹：${foldersSummary || '无'}`,
      `用户高频标签：${tagsSummary || '无'}`,
      '',
      '请仅输出一个 JSON 对象，用于多路召回候选素材：',
      '{',
      '  "searchQueries": ["4到8个中英双语画面关键词或风格词"],',
      '  "preferredFolders": ["从上述素材库文件夹中挑选高度相关的文件夹名，没有则留空数组"],',
      '  "targetColorHexes": ["如能从描述推断主色相，给1到3个#RRGGBB，否则留空数组"]',
      '}',
    ].join('\n');

    const raw = await provider.completeJSON(
      'You are a visual library retrieval planner. Output strict JSON only.',
      prompt,
      [],
    );
    const obj = MoodboardAgentHarness.extractJSONObject(raw);
    const toStringList = (v: unknown): string[] =>
      Array.isArray(v)
        ? v.filter((x): x is string => typeof x === 'string').map((s) => s.trim()).filter(Boolean)
        : [];
    return {
      searchQueries: toStringList(obj.searchQueries),
      preferredFolders: toStringList(obj.preferredFolders),
      targetColorHexes: toStringList(obj.targetColorHexes).filter((h) => h.startsWith('#')),
    };
  }

  private async runStrictOfflineCurator(
    request: MoodboardCurationRequest,
    recall: AgentRecallResult,
    recorder: AgentTraceRecorder,
    usedTypeSafeJev: boolean,
  ): Promise<MoodboardProposal> {
    const locked = new Set(request.lockedAssetIDs.map(toSwiftUUID));
    const seeds = new Set(request.seedAssetIDs.map(toSwiftUUID));
    const hasActiveSignal =
      request.prompt.trim().length > 0 ||
      request.targetPalette.length > 0 ||
      request.seedAssetIDs.length > 0 ||
      request.requiredTags.length > 0;

    const ranked = recall.candidates
      .map((a) => recall.scoresByID.get(a.id))
      .filter((s): s is ScoredAsset => Boolean(s))
      .sort((lhs, rhs) => {
        const lPin = locked.has(lhs.asset.id) || seeds.has(lhs.asset.id) ? 1 : 0;
        const rPin = locked.has(rhs.asset.id) || seeds.has(rhs.asset.id) ? 1 : 0;
        if (lPin !== rPin) return rPin - lPin;
        if (Math.abs(lhs.score - rhs.score) > 0.001) return rhs.score - lhs.score;
        return rhs.asset.rating - lhs.asset.rating;
      });

    const threshold = hasActiveSignal ? 0.34 : 0.0;
    const chosen: ScoredAsset[] = [];
    let rejectedCount = 0;

    for (const item of ranked) {
      const isPinned = locked.has(item.asset.id) || seeds.has(item.asset.id);
      if (isPinned || !hasActiveSignal || (item.score >= threshold && item.matchReasons.length > 0)) {
        if (chosen.length < Math.max(1, request.preferredCount) || isPinned) {
          chosen.push(item);
        }
      } else {
        rejectedCount += 1;
      }
    }

    const slotToAsset = new Map<number, AssetRecord>();
    const slotByID = new Map<UUID, number>();
    recall.candidates.forEach((asset, idx) => {
      const s = idx + 1;
      slotToAsset.set(s, asset);
      slotByID.set(asset.id, s);
    });

    const primaryPicks: AgentSlotPick[] = chosen
      .map((scored, idx) => {
        const slot = slotByID.get(scored.asset.id);
        if (slot === undefined) return null;
        return {
          slot,
          weight: idx === 0 ? 2 : 1,
          reason: scored.matchReasons[0] ?? '本机相关匹配',
        };
      })
      .filter((p): p is AgentSlotPick => p !== null);

    const chosenIDs = new Set(chosen.map((c) => c.asset.id));
    const candidatePicks: AgentSlotPick[] = ranked
      .filter((r) => !chosenIDs.has(r.asset.id))
      .slice(0, request.candidateCount)
      .map((scored) => {
        const slot = slotByID.get(scored.asset.id);
        if (slot === undefined) return null;
        return { slot, weight: 1, reason: scored.matchReasons[0] ?? '备选参考' };
      })
      .filter((p): p is AgentSlotPick => p !== null);

    const titleDraft = request.prompt.trim();
    const title = titleDraft
      ? titleDraft.slice(0, 36)
      : (request.existingBoard?.title ?? (usedTypeSafeJev ? 'Jev 视觉情绪板' : '本机策展情绪板'));
    const rejectedText =
      rejectedCount > 0
        ? usedTypeSafeJev
          ? `Jev 视觉打分已过滤掉 ${rejectedCount} 张不相关素材`
          : `已按本机匹配度过滤掉 ${rejectedCount} 张不相关素材（开启云端增强智能后支持 AI 直接看图筛选未打标素材）`
        : null;

    const offlinePlan: AgentBoardPlan = {
      boardTitle: title,
      boardSubtitle:
        chosen.length === 0
          ? usedTypeSafeJev
            ? 'Jev 视觉精排未找到高匹配素材，请尝试更换灵感词'
            : '本机离线文本/色彩检索未匹配到足够素材，可开启云端增强智能看图筛选，或放宽限定条件'
          : usedTypeSafeJev
            ? `TypeSafe Jev 视觉精排精选 ${chosen.length} 项契合素材`
            : `本机离线精选 ${chosen.length} 项契合素材`,
      curatorNote:
        request.includeCuratorNotes && chosen.length > 0
          ? {
              title: '策展说明',
              text: !titleDraft
                ? '按色彩、视觉特征与所选种子整理的视觉参考集合。'
                : usedTypeSafeJev
                  ? `围绕「${titleDraft}」由 TypeSafe Jev 视觉精排生成的参考集合。`
                  : `围绕「${titleDraft}」整理的本机视觉参考集合。`,
              style: 'paper',
            }
          : null,
      recommendedLayout: request.layoutStyle,
      sections:
        primaryPicks.length === 0
          ? []
          : [
              {
                title: usedTypeSafeJev ? 'Jev 视觉精选' : '精选视觉参考',
                tint: 'neutral',
                rationale: '',
                picks: primaryPicks,
              },
            ],
      candidatePicks,
      rejectedNote: rejectedText,
      visualInsights: [],
    };

    const compiled = this.tools.compileAndVerifyBoard({
      plan: offlinePlan,
      slotToAsset,
      request,
      recall,
    });

    await recorder.emit(
      'completed',
      chosen.length === 0
        ? usedTypeSafeJev
          ? 'Jev 未匹配到符合描述的素材'
          : '离线未匹配到符合描述的素材'
        : usedTypeSafeJev
          ? `Jev 视觉策展初稿已生成（${compiled.primaryMatches.length} 张）`
          : `离线初稿已生成（${compiled.primaryMatches.length} 张）`,
      rejectedText ?? '已完成版面编排与配色提炼',
      chosen.length === 0 ? 'warning' : 'done',
    );

    return {
      draftDocument: compiled.document,
      primaryMatches: compiled.primaryMatches,
      candidatePool: compiled.candidatePool,
      extractedPalette: compiled.extractedPalette,
      usedCloudAI: usedTypeSafeJev,
      curatedSummary: offlinePlan.boardSubtitle,
      agentTrace: recorder.snapshot(),
      sections: compiled.sections,
      rejectedSummary: rejectedText,
      cachedVisualInsightsCount: 0,
    };
  }

  static buildVisualCurationPrompt(
    request: MoodboardCurationRequest,
    manifest: string,
    sheetCount: number,
    totalSlots: number,
  ): string {
    const lines: string[] = ['【策展任务】'];
    if (request.prompt.trim()) {
      lines.push(`- 核心氛围与主题：${request.prompt.trim()}`);
    } else {
      lines.push('- 核心氛围与主题：未指定文字，请围绕已选种子图 / 色彩倾向 / 现有画布提炼统一的高级视觉方向');
    }
    if (request.refinementInstruction?.trim()) {
      lines.push(`- 本轮用户微调指令（最高优先级执行）：${request.refinementInstruction.trim()}`);
    }
    if (request.existingBoard) {
      const refCount = getBoardReferencedAssetIDs(request.existingBoard).length;
      lines.push(
        `- 当前已有画布：「${request.existingBoard.title}」（现有 ${refCount} 张图，清单中标注了 CURRENTLY_ON_BOARD；请在其基础上按本轮指令优化、增删或重组分区）`,
      );
    }
    if (request.targetPalette.length > 0) {
      lines.push(`- 目标色彩倾向：${request.targetPalette.map((c) => c.hex).join(', ')}`);
    }
    lines.push(`- 期望上限张数：最多 ${request.preferredCount} 张（宁缺毋滥，严禁硬塞风格冲突的素材）`);
    lines.push(`- 偏好排版风格：${request.layoutStyle}`);
    lines.push(
      `- 附带 ${sheetCount} 张编号视觉联系表，共 ${totalSlots} 个候选编号（#01 ~ #${String(totalSlots).padStart(2, '0')}）。请务必仔细观察联系表上的真实画面后再做选择！`,
    );
    lines.push('');
    lines.push('【候选素材清单】');
    lines.push(manifest);
    return lines.join('\n');
  }

  static extractJSONObject(raw: string): Record<string, unknown> {
    const trimmed = raw.trim();
    const first = trimmed.indexOf('{');
    const last = trimmed.lastIndexOf('}');
    if (first < 0 || last < first) {
      throw new Error('模型未返回合法的 JSON 策展方案。');
    }
    const parsed = JSON.parse(trimmed.slice(first, last + 1)) as unknown;
    if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) {
      throw new Error('策展方案 JSON 根结构不是对象。');
    }
    return parsed as Record<string, unknown>;
  }

  static parseBoardPlan(raw: string, fallbackLayout: EditorialStyle): AgentBoardPlan {
    const obj = MoodboardAgentHarness.extractJSONObject(raw);
    const title =
      (typeof obj.boardTitle === 'string' && obj.boardTitle) ||
      (typeof obj.title === 'string' && obj.title) ||
      '';
    const subtitle =
      (typeof obj.boardSubtitle === 'string' && obj.boardSubtitle) ||
      (typeof obj.subtitle === 'string' && obj.subtitle) ||
      '';
    const layoutRaw = typeof obj.recommendedLayout === 'string' ? obj.recommendedLayout.toLowerCase() : '';
    const recommendedLayout = (EDITORIAL_STYLES as readonly string[]).includes(layoutRaw)
      ? (layoutRaw as EditorialStyle)
      : fallbackLayout;

    let curatorNote: AgentNoteSpec | null = null;
    if (obj.curatorNote && typeof obj.curatorNote === 'object') {
      const n = obj.curatorNote as Record<string, unknown>;
      const text = typeof n.text === 'string' ? n.text.trim() : '';
      if (text) {
        const noteTitle = typeof n.title === 'string' ? n.title : '视觉定调说明';
        const styleRaw = typeof n.style === 'string' ? n.style.toLowerCase() : 'paper';
        const style = (NOTE_STYLES as readonly string[]).includes(styleRaw)
          ? (styleRaw as NoteStyle)
          : 'paper';
        curatorNote = { title: noteTitle, text, style };
      }
    }

    const parseIntSlot = (v: unknown): number | null => {
      if (typeof v === 'number' && Number.isFinite(v)) return Math.trunc(v);
      if (typeof v === 'string') {
        const cleaned = v.trim().replace(/^#/, '');
        const n = Number.parseInt(cleaned, 10);
        return Number.isFinite(n) ? n : null;
      }
      return null;
    };

    const parseSlotPicks = (val: unknown): AgentSlotPick[] => {
      if (!Array.isArray(val)) return [];
      const out: AgentSlotPick[] = [];
      for (const entry of val) {
        const direct = parseIntSlot(entry);
        if (direct !== null) {
          out.push({ slot: direct, weight: 1, reason: '' });
          continue;
        }
        if (entry && typeof entry === 'object') {
          const rec = entry as Record<string, unknown>;
          const slot = parseIntSlot(rec.slot);
          if (slot === null) continue;
          const weight = Math.max(1, Math.min(2, parseIntSlot(rec.weight) ?? 1));
          const reason = typeof rec.reason === 'string' ? rec.reason : '';
          out.push({ slot, weight, reason });
        }
      }
      return out;
    };

    const sections: AgentSectionSpec[] = [];
    if (Array.isArray(obj.sections)) {
      for (const sec of obj.sections) {
        if (!sec || typeof sec !== 'object') continue;
        const rec = sec as Record<string, unknown>;
        const secTitle = typeof rec.title === 'string' ? rec.title : '精选参考';
        const tintRaw = typeof rec.tint === 'string' ? rec.tint.toLowerCase() : 'neutral';
        const tint = (GROUP_TINTS as readonly string[]).includes(tintRaw)
          ? (tintRaw as GroupTint)
          : 'neutral';
        const rationale = typeof rec.rationale === 'string' ? rec.rationale : '';
        const picks = parseSlotPicks(rec.slots ?? rec.picks);
        if (picks.length > 0) {
          sections.push({ title: secTitle, tint, rationale, picks });
        }
      }
    }
    if (sections.length === 0) {
      const flat = parseSlotPicks(obj.slots ?? obj.selectedSlots ?? obj.picks);
      if (flat.length > 0) {
        sections.push({ title: '核心视觉参考', tint: 'neutral', rationale: '', picks: flat });
      }
    }

    const candidatePicks = parseSlotPicks(
      obj.candidatePoolSlots ?? obj.candidatePicks ?? obj.candidates,
    );
    const rejectedNote =
      typeof obj.rejectedNote === 'string' && obj.rejectedNote.trim()
        ? obj.rejectedNote.trim()
        : null;

    const visualInsights: Array<{ slot: number; description: string; tags: string[] }> = [];
    if (Array.isArray(obj.visualInsights)) {
      for (const item of obj.visualInsights) {
        if (!item || typeof item !== 'object') continue;
        const rec = item as Record<string, unknown>;
        const slot = parseIntSlot(rec.slot);
        if (slot === null) continue;
        const desc = typeof rec.description === 'string' ? rec.description : '';
        const tags = Array.isArray(rec.tags)
          ? rec.tags.filter((t): t is string => typeof t === 'string')
          : [];
        if (desc || tags.length > 0) {
          visualInsights.push({ slot, description: desc, tags });
        }
      }
    }

    return {
      boardTitle: title,
      boardSubtitle: subtitle,
      curatorNote,
      recommendedLayout,
      sections,
      candidatePicks,
      rejectedNote,
      visualInsights,
    };
  }
}
