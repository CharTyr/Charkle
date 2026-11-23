import { randomUUID } from '../runtime/web-crypto-utils.js';
import {
  createDefaultAutoLayoutConfig,
  createDefaultMoodboardDocument,
  deltaE76,
  deltaE2000,
  freezeIntoFreeform,
  fuzzyScoreSearchText,
  getAssetAspectRatio,
  normalizeSearchText,
  toSwiftUUID,
  type AssetRecord,
  type AssetVector,
  type BoardNode,
  type FolderSuggestion,
  type LabColor,
  type MoodboardProposal,
  type MoodboardSeed,
  type ScoredAsset,
  type UUID,
} from '@charkle/shared';
import {
  cosineSimilarity,
  decodeFeaturePrintFloat32,
  type LibraryDatabase,
} from '../db/library-database.js';
import type { CloudAIProvider } from './cloud-ai-provider.js';

const CLOUD_REASON = '语义接近';

function uniqueStrings(values: readonly string[]): string[] {
  const seen = new Set<string>();
  const out: string[] = [];
  for (const v of values) {
    if (!seen.has(v)) {
      seen.add(v);
      out.push(v);
    }
  }
  return out;
}

function significantSwatches(colors: readonly LabColor[], maxCount: number): LabColor[] {
  const valid = colors.filter(
    (c) => Number.isFinite(c.l) && Number.isFinite(c.a) && Number.isFinite(c.b),
  );
  const hasProportions = valid.some((c) => c.proportion > 0.001);
  if (hasProportions) {
    const major = valid.filter((c) => c.proportion >= 0.08);
    if (major.length > 0) return major.slice(0, maxCount);
  }
  return valid.slice(0, maxCount);
}

/**
 * Proportion-weighted average minimum CIEDE2000 from candidate's top dominant swatches to target palette.
 */
export function weightedPaletteDistance(
  candidate: readonly LabColor[],
  target: readonly LabColor[],
): number | null {
  const a = significantSwatches(candidate, 3);
  const b = significantSwatches(target, 4);
  if (a.length === 0 || b.length === 0) return null;
  let weightedSum = 0;
  let totalWeight = 0;
  for (const swatch of a) {
    let nearest = Number.POSITIVE_INFINITY;
    for (const t of b) {
      const d = deltaE2000(swatch, t);
      if (Number.isFinite(d) && d < nearest) nearest = d;
    }
    if (!Number.isFinite(nearest)) continue;
    const w = swatch.proportion > 0.001 ? swatch.proportion : 1.0;
    weightedSum += nearest * w;
    totalWeight += w;
  }
  if (totalWeight <= 0) return null;
  return weightedSum / totalWeight;
}

export function significantSwatchDistance(
  candidate: readonly LabColor[],
  target: readonly LabColor[],
): number | null {
  const a = significantSwatches(candidate, 5);
  const b = target.filter(
    (c) => Number.isFinite(c.l) && Number.isFinite(c.a) && Number.isFinite(c.b),
  );
  if (a.length === 0 || b.length === 0) return null;
  let best = Number.POSITIVE_INFINITY;
  for (const lhs of a) {
    for (const rhs of b) {
      const d = deltaE2000(lhs, rhs);
      if (Number.isFinite(d) && d < best) best = d;
    }
  }
  return Number.isFinite(best) ? best : null;
}

export function featurePrintSimilarity(fpA?: string | null, fpB?: string | null): number | null {
  if (!fpA || !fpB) return null;
  const a = decodeFeaturePrintFloat32(fpA);
  const b = decodeFeaturePrintFloat32(fpB);
  if (!a || !b || a.length !== b.length || a.length === 0) return null;
  const cos = cosineSimilarity(a, b);
  return Math.max(0, Math.min(1, cos));
}

interface EvidenceContext {
  seeds: AssetRecord[];
  colors: LabColor[];
  tolerance: number;
  ranks: Map<UUID, number>;
  queryVector: number[] | null;
  embeddingIdentity: string | null;
  vectors: Map<UUID, AssetVector>;
}

function scoreWithEvidence(asset: AssetRecord, evidence: EvidenceContext): ScoredAsset {
  const signals: Array<{ value: number; weight: number; threshold: number; reason: string }> = [];

  if (evidence.ranks.size > 0) {
    signals.push({
      value: evidence.ranks.get(asset.id) ?? 0,
      weight: 0.48,
      threshold: 0.15,
      reason: '关键词匹配',
    });
  }

  const vec = evidence.vectors.get(asset.id);
  if (vec?.embedding && vec.embedding.length > 0) {
    const cloudSims: number[] = [];
    if (evidence.queryVector && vec.embeddingModel === evidence.embeddingIdentity) {
      cloudSims.push(Math.max(0, Math.min(1, cosineSimilarity(vec.embedding, evidence.queryVector))));
    }
    for (const seed of evidence.seeds) {
      const other = evidence.vectors.get(seed.id);
      if (other?.embedding && other.embeddingModel === vec.embeddingModel) {
        cloudSims.push(Math.max(0, Math.min(1, cosineSimilarity(vec.embedding, other.embedding))));
      }
    }
    if (cloudSims.length > 0) {
      signals.push({
        value: Math.max(...cloudSims),
        weight: 0.4,
        threshold: 0.45,
        reason: CLOUD_REASON,
      });
    }
  }

  if (vec?.featurePrint && evidence.seeds.length > 0) {
    const fpSims: number[] = [];
    for (const seed of evidence.seeds) {
      const sim = featurePrintSimilarity(vec.featurePrint, evidence.vectors.get(seed.id)?.featurePrint);
      if (sim !== null) fpSims.push(sim);
    }
    if (fpSims.length > 0) {
      signals.push({
        value: Math.max(...fpSims),
        weight: 0.36,
        threshold: 0.22,
        reason: '图像特征接近',
      });
    }
  }

  const targetColors =
    evidence.colors.length === 0
      ? evidence.seeds.flatMap((s) => s.dominantColors.slice(0, 3))
      : evidence.colors;

  if (targetColors.length > 0) {
    let similarity = 0;
    if (evidence.colors.length === 0) {
      const avgDelta = weightedPaletteDistance(asset.dominantColors, targetColors);
      if (avgDelta !== null) {
        if (avgDelta <= 6.0) similarity = 1.0;
        else if (avgDelta < 22.0) similarity = Math.pow((22.0 - avgDelta) / 16.0, 1.1);
        else similarity = 0;
      }
    } else {
      const d = significantSwatchDistance(asset.dominantColors, targetColors);
      if (d !== null) {
        const tol = Math.max(1.0, evidence.tolerance);
        if (d <= evidence.tolerance) {
          similarity = 1.0 - (d / tol) * 0.35;
        } else {
          const cutoff = Math.max(evidence.tolerance * 1.6, evidence.tolerance + 14.0);
          if (d < cutoff) {
            similarity = 0.3 * ((cutoff - d) / Math.max(1.0, cutoff - evidence.tolerance));
          }
        }
      }
    }
    signals.push({
      value: similarity,
      weight: evidence.colors.length === 0 ? 0.24 : 0.44,
      threshold: 0.35,
      reason: '配色相近',
    });
  }

  if (evidence.seeds.length > 0) {
    const assetTags = new Set(
      [...asset.tags, ...asset.suggestedTags].map(normalizeSearchText).filter(Boolean),
    );
    let maxOverlap = 0;
    for (const seed of evidence.seeds) {
      const peerTags = new Set(
        [...seed.tags, ...seed.suggestedTags].map(normalizeSearchText).filter(Boolean),
      );
      if (peerTags.size === 0 || assetTags.size === 0) continue;
      let inter = 0;
      for (const t of peerTags) {
        if (assetTags.has(t)) inter++;
      }
      const union = peerTags.size + assetTags.size - inter;
      const jaccard = inter / Math.max(1, union);
      if (jaccard > maxOverlap) maxOverlap = jaccard;
    }
    signals.push({
      value: maxOverlap,
      weight: 0.18,
      threshold: 0.2,
      reason: '相同标签',
    });
  }

  const sum = signals.reduce((acc, s) => acc + s.value * s.weight, 0);
  const signalCapacity = Math.max(0.35, signals.reduce((acc, s) => acc + s.weight, 0));
  const rating = Math.min(5, Math.max(0, asset.rating)) / 5;
  const qualifiedReasons = signals
    .filter((s) => s.value >= s.threshold)
    .sort((a, b) => b.value * b.weight - a.value * a.weight)
    .map((s) => s.reason);

  const baseScore = sum / signalCapacity;
  const finalScore =
    qualifiedReasons.length === 0 ? baseScore : Math.min(1, 0.06 * rating + 0.94 * baseScore);

  return {
    asset,
    score: finalScore,
    matchReasons: qualifiedReasons,
  };
}

function pairRedundancy(lhs: AssetRecord, rhs: AssetRecord, vectors: Map<UUID, AssetVector>): number {
  if (lhs.contentHash && lhs.contentHash === rhs.contentHash) return 1;
  const l = vectors.get(lhs.id);
  const r = vectors.get(rhs.id);
  let result = 0;
  if (l?.embedding && r?.embedding && l.embeddingModel === r.embeddingModel) {
    result = Math.max(result, Math.max(0, cosineSimilarity(l.embedding, r.embedding)) * 0.92);
  }
  const fpSim = featurePrintSimilarity(l?.featurePrint, r?.featurePrint);
  if (fpSim !== null) {
    result = Math.max(result, fpSim);
  }
  const paletteDist = weightedPaletteDistance(
    lhs.dominantColors.slice(0, 2),
    rhs.dominantColors.slice(0, 2),
  );
  if (paletteDist !== null) {
    result = Math.max(result, 0.55 * Math.exp(-paletteDist / 17));
  }
  return result;
}

/**
 * Multi-signal Moodboard Curator & Greedy MMR diversity reranker.
 * Exact port of macOS `MoodboardCurator.swift`.
 */
export class MoodboardCurator {
  private readonly database: LibraryDatabase;

  constructor(database: LibraryDatabase) {
    this.database = database;
  }

  async proposeMoodboard(
    seed: MoodboardSeed,
    primaryCount = 12,
    candidateCount = 24,
    provider?: CloudAIProvider | null,
  ): Promise<MoodboardProposal> {
    let prompt = '';
    let seedIDs: UUID[] = [];
    let palette: LabColor[] = [];
    let tolerance = 28.0;
    let manual = false;

    switch (seed.type) {
      case 'prompt':
        prompt = seed.prompt;
        break;
      case 'seedAssets':
        seedIDs = seed.assetIDs;
        break;
      case 'palette':
        palette = seed.colors;
        tolerance = Math.max(0, seed.tolerance);
        break;
      case 'manualSelection':
        seedIDs = seed.assetIDs;
        manual = true;
        break;
      case 'combined':
        prompt = seed.prompt ?? '';
        seedIDs = seed.seedAssetIDs;
        palette = seed.palette;
        break;
    }

    const assets = this.database.fetchAssets({ includeTrashed: false });
    const indexed = new Map(assets.map((a) => [a.id, a]));
    const normalizedSeedIDs = uniqueStrings(seedIDs.map(toSwiftUUID));
    const seedSet = new Set(normalizedSeedIDs);
    const seeds = normalizedSeedIDs
      .map((id) => indexed.get(id))
      .filter((a): a is AssetRecord => Boolean(a));
    const available = assets.filter((a) => !seedSet.has(a.id));
    const vectors = this.database.getAllVectors();
    const ranks = this.keywordRanks(prompt);

    let promptVector: number[] | null = null;
    if (provider && prompt.trim().length > 0) {
      let hasCompat = false;
      for (const v of vectors.values()) {
        if (v.embeddingModel === provider.embeddingIdentity && v.embedding && v.embedding.length > 0) {
          hasCompat = true;
          break;
        }
      }
      if (hasCompat) {
        try {
          promptVector = await provider.embed(prompt);
        } catch {
          promptVector = null;
        }
      }
    }

    const evidence: EvidenceContext = {
      seeds,
      colors: palette,
      tolerance,
      ranks,
      queryVector: promptVector,
      embeddingIdentity: provider?.embeddingIdentity ?? null,
      vectors,
    };

    const explicitSeeds: ScoredAsset[] = seeds.map((a) => ({
      asset: a,
      score: 1,
      matchReasons: ['所选素材'],
    }));
    const safePrimary = Math.max(0, primaryCount);
    const safeCandidate = Math.max(0, candidateCount);
    const primarySeeds = explicitSeeds.slice(0, safePrimary);
    const needed = manual ? 0 : Math.max(0, safePrimary - primarySeeds.length);

    const scoredAvailable = available.map((a) => scoreWithEvidence(a, evidence));
    const ordered = this.mmrRerank(
      scoredAvailable,
      vectors,
      seeds,
      Math.min(needed, available.length) + Math.min(safeCandidate, available.length),
    );

    const primary = [...primarySeeds, ...ordered.slice(0, needed)];
    const candidates = [
      ...explicitSeeds.slice(primarySeeds.length),
      ...ordered.slice(needed),
    ].slice(0, safeCandidate);

    const paletteSource = primary.flatMap((m) => m.asset.dominantColors);
    const extracted = MoodboardCurator.harmonizePalette(
      paletteSource.length > 0 ? paletteSource : palette,
      6,
    );

    const cleanTitle = prompt.trim();
    const primaryAssets = primary.map((p) => p.asset);
    const baseNodes = MoodboardCurator.editorialNodes(primaryAssets);
    const rawDocument = createDefaultMoodboardDocument({
      id: toSwiftUUID(randomUUID()),
      title: cleanTitle ? cleanTitle.slice(0, 120) : '新情绪板',
      mode:
        primaryAssets.length > 0
          ? {
              type: 'autoEditorial',
              config: createDefaultAutoLayoutConfig({
                columns: Math.min(3, Math.max(2, primaryAssets.length)),
                spacing: 18,
                style: 'magazine',
                showPaletteStrip: true,
              }),
            }
          : { type: 'freeform' },
      nodes: baseNodes,
      extractedPalette: extracted,
      candidateAssetIDs: candidates.map((c) => c.asset.id),
    });
    const assetsByID: Record<string, AssetRecord> = {};
    for (const a of primaryAssets) {
      assetsByID[a.id] = a;
    }
    const document =
      primaryAssets.length > 0
        ? freezeIntoFreeform(rawDocument, 1080, assetsByID)
        : rawDocument;

    const usedCloud = [...primary, ...candidates].some((m) =>
      m.matchReasons.includes(CLOUD_REASON),
    );

    return {
      draftDocument: document,
      primaryMatches: primary,
      candidatePool: candidates,
      extractedPalette: extracted,
      usedCloudAI: usedCloud,
      curatedSummary: cleanTitle
        ? `围绕「${cleanTitle}」精选 ${primary.length} 项参考素材`
        : `已精选 ${primary.length} 项视觉参考素材`,
      agentTrace: [],
      sections: [],
      rejectedSummary: null,
      cachedVisualInsightsCount: 0,
    };
  }

  extractBoardPalette(assetIDs: readonly UUID[], count = 6): LabColor[] {
    const colors: LabColor[] = [];
    for (const id of uniqueStrings(assetIDs.map(toSwiftUUID))) {
      const asset = this.database.getAsset(id);
      if (asset) colors.push(...asset.dominantColors);
    }
    return MoodboardCurator.harmonizePalette(colors, count);
  }

  replacementCandidates(
    assetID: UUID,
    excluding: readonly UUID[] = [],
    boardContext: readonly UUID[] = [],
    limit = 24,
  ): ScoredAsset[] {
    if (limit <= 0) return [];
    const uid = toSwiftUUID(assetID);
    const anchor = this.database.getAsset(uid);
    if (!anchor) return [];

    const assets = this.database.fetchAssets({ includeTrashed: false });
    const existing = new Set<UUID>([
      uid,
      ...excluding.map(toSwiftUUID),
      ...boardContext.map(toSwiftUUID),
    ]);
    const contextSet = new Set<UUID>(boardContext.map(toSwiftUUID));
    contextSet.delete(uid);

    const neighbors = assets.filter((a) => contextSet.has(a.id));
    const vectors = this.database.getAllVectors();
    const evidence: EvidenceContext = {
      seeds: [anchor],
      colors: MoodboardCurator.harmonizePalette(
        neighbors.flatMap((n) => n.dominantColors),
        6,
      ),
      tolerance: 28,
      ranks: new Map(),
      queryVector: null,
      embeddingIdentity: null,
      vectors,
    };

    const matches = assets
      .filter((a) => !existing.has(a.id))
      .map((a) => scoreWithEvidence(a, evidence))
      .filter((m) => m.matchReasons.length > 0 && m.score >= 0.24);

    return this.mmrRerank(matches, vectors, [], limit);
  }

  similarAssets(assetID: UUID, limit = 16): ScoredAsset[] {
    if (limit <= 0) return [];
    const uid = toSwiftUUID(assetID);
    const anchor = this.database.getAsset(uid);
    if (!anchor) return [];

    const assets = this.database.fetchAssets({ includeTrashed: false });
    const vectors = this.database.getAllVectors();
    const evidence: EvidenceContext = {
      seeds: [anchor],
      colors: [],
      tolerance: 28,
      ranks: new Map(),
      queryVector: null,
      embeddingIdentity: null,
      vectors,
    };

    const matches = assets
      .filter((a) => a.id !== uid)
      .map((a) => scoreWithEvidence(a, evidence))
      .filter((m) => m.matchReasons.length > 0 && m.score >= 0.26);

    return this.mmrRerank(matches, vectors, [], limit);
  }

  suggestFolder(assetID: UUID): FolderSuggestion | null {
    const uid = toSwiftUUID(assetID);
    const asset = this.database.getAsset(uid);
    if (!asset) return null;

    const folders = this.database.fetchFolders();
    const assets = this.database.fetchAssets({ includeTrashed: false });
    const vectors = this.database.getAllVectors();
    const evidence: EvidenceContext = {
      seeds: [asset],
      colors: [],
      tolerance: 28,
      ranks: new Map(),
      queryVector: null,
      embeddingIdentity: null,
      vectors,
    };

    const peers = assets
      .filter((a) => a.id !== uid && a.folderID !== null)
      .map((a) => scoreWithEvidence(a, evidence));

    const keywords = uniqueStrings([...asset.tags, ...asset.suggestedTags]);
    const suggestions: FolderSuggestion[] = [];

    for (const folder of folders) {
      if (folder.id === asset.folderID) continue;
      const nameMatch = keywords.some((kw) => fuzzyScoreSearchText(kw, folder.name) !== null);
      const topScores = peers
        .filter((p) => p.asset.folderID === folder.id && p.matchReasons.length > 0)
        .map((p) => p.score)
        .sort((a, b) => b - a)
        .slice(0, 3);
      if (!nameMatch && topScores.length === 0) continue;

      const affinity =
        topScores.length === 0 ? 0 : topScores.reduce((a, b) => a + b, 0) / topScores.length;
      const confidence = Math.min(0.99, affinity * 0.8 + (nameMatch ? 0.45 : 0));
      suggestions.push({
        folderID: folder.id,
        folderName: folder.name,
        confidence,
        reason: nameMatch ? '目录名与标签吻合' : '目录内有相近素材',
      });
    }

    suggestions.sort(
      (a, b) => b.confidence - a.confidence || b.folderName.localeCompare(a.folderName),
    );
    return suggestions[0] ?? null;
  }

  private keywordRanks(prompt: string): Map<UUID, number> {
    const ranks = new Map<UUID, number>(this.database.searchRanks(prompt));
    const terms = uniqueStrings(prompt.split(/\s+/).filter(Boolean));
    if (terms.length > 1) {
      for (const term of terms.slice(0, 12)) {
        for (const [id, rank] of this.database.searchRanks(term)) {
          ranks.set(id, Math.min(1, (ranks.get(id) ?? 0) + rank / terms.length));
        }
      }
    }
    return ranks;
  }

  /**
   * Greedy Maximal Marginal Relevance (MMR): `0.64 * relevance - 0.36 * maxRedundancy`.
   */
  private mmrRerank(
    matches: ScoredAsset[],
    vectors: Map<UUID, AssetVector>,
    seeds: AssetRecord[],
    limit: number,
  ): ScoredAsset[] {
    const pool = [...matches].sort((a, b) => {
      if (a.score !== b.score) return b.score - a.score;
      if (a.asset.rating !== b.asset.rating) return b.asset.rating - a.asset.rating;
      return b.asset.id.localeCompare(a.asset.id);
    });
    const count = Math.min(Math.max(0, limit), pool.length);
    if (count === 0) return [];

    const poolSize = Math.max(200, count * 6);
    if (pool.length > poolSize) pool.length = poolSize;

    const redundancy = pool.map((cand) => {
      let maxR = 0;
      for (const seed of seeds) {
        const r = pairRedundancy(cand.asset, seed, vectors);
        if (r > maxR) maxR = r;
      }
      return maxR;
    });
    const available = new Array<boolean>(pool.length).fill(true);
    const results: ScoredAsset[] = [];

    for (let step = 0; step < count; step++) {
      let bestIdx = -1;
      let bestRank = Number.NEGATIVE_INFINITY;
      for (let i = 0; i < pool.length; i++) {
        if (!available[i]) continue;
        const rank = 0.64 * pool[i].score - 0.36 * redundancy[i];
        if (rank > bestRank) {
          bestRank = rank;
          bestIdx = i;
        }
      }
      if (bestIdx < 0) break;
      available[bestIdx] = false;
      results.push(pool[bestIdx]);

      if (results.length < count) {
        for (let i = 0; i < pool.length; i++) {
          if (!available[i]) continue;
          const r = pairRedundancy(pool[bestIdx].asset, pool[i].asset, vectors);
          if (r > redundancy[i]) redundancy[i] = r;
        }
      }
    }
    return results;
  }

  /**
   * Clusters and harmonizes a collection of `LabColor` swatches (merging CIEDE2000 < 8),
   * picks top `count` by visual proportion, normalizes proportions, and sorts lightest → darkest.
   */
  static harmonizePalette(input: readonly LabColor[], count = 6): LabColor[] {
    if (count <= 0) return [];
    const sorted = [...input].sort((a, b) => {
      if (a.proportion !== b.proportion) return b.proportion - a.proportion;
      return b.hex.localeCompare(a.hex);
    });

    const groups: LabColor[] = [];
    for (const swatch of sorted) {
      if (!Number.isFinite(swatch.l) || !Number.isFinite(swatch.a) || !Number.isFinite(swatch.b)) {
        continue;
      }
      let bestIdx = -1;
      let bestD76 = Number.POSITIVE_INFINITY;
      for (let i = 0; i < groups.length; i++) {
        const d = deltaE76(groups[i], swatch);
        if (d < bestD76) {
          bestD76 = d;
          bestIdx = i;
        }
      }
      if (bestIdx >= 0 && deltaE2000(groups[bestIdx], swatch) < 8) {
        groups[bestIdx] = {
          ...groups[bestIdx],
          proportion: groups[bestIdx].proportion + swatch.proportion,
        };
      } else {
        groups.push({ ...swatch });
      }
    }

    const prominent = groups
      .sort((a, b) => (b.proportion !== a.proportion ? b.proportion - a.proportion : b.hex.localeCompare(a.hex)))
      .slice(0, count);

    const total = prominent.reduce((acc, s) => acc + s.proportion, 0);
    return prominent
      .sort((a, b) => b.l - a.l)
      .map((s) => ({
        ...s,
        proportion: total > 0 ? s.proportion / total : s.proportion,
      }));
  }

  static editorialNodes(assets: readonly AssetRecord[]): BoardNode[] {
    if (assets.length === 0) return [];
    const output: BoardNode[] = [];
    const now = new Date().toISOString();
    let y = 0;
    let lower = 0;
    while (lower < assets.length) {
      const count = Math.min(lower === 0 && assets.length <= 6 ? 3 : 4, assets.length - lower);
      const row = assets.slice(lower, lower + count);
      const ratios = row.map((a) => Math.min(2.1, Math.max(0.6, getAssetAspectRatio(a))));
      const boost = lower === 0 && count > 1 ? 1.25 : 1.0;
      const weights = ratios.map((r, idx) => (idx === 0 ? r * boost : r));
      const gap = 16;
      const height = Math.min(470, (1180 - (count - 1) * gap) / weights.reduce((a, b) => a + b, 0));
      let x = 0;
      for (let i = 0; i < row.length; i++) {
        const asset = row[i];
        const width = height * weights[i];
        const order = lower + i;
        output.push({
          id: toSwiftUUID(randomUUID()),
          kind: {
            type: 'assetRef',
            assetID: asset.id,
            crop: null,
            weight: order === 0 ? 2 : 1,
            autoplayLoop: asset.mediaKind === 'animatedImage' || asset.mediaKind === 'video',
          },
          frame: { x, y, width, height },
          zIndex: order,
          rotationDegrees: 0,
          flipHorizontal: false,
          flipVertical: false,
          isLocked: false,
          editorialOrder: order,
          updatedAt: now,
        });
        x += width + gap;
      }
      y += height + gap;
      lower += count;
    }
    return output;
  }
}
