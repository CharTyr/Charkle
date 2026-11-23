import {
  clampCropRect,
  createDefaultFilterCriteria,
  FULL_CROP_RECT,
  isMeaningfulCropSubregion,
  padCropRect,
  type AssetRecord,
  type CleanBoundsResult,
  type FilterCriteria,
  type FolderRecord,
  type FolderSuggestion,
  type InboxTriageRecommendation,
  type LabColor,
  type NormalizedCropRect,
  type SemanticSearchHit,
  type SemanticSearchReport,
  type SubjectPaletteResult,
  type TypeSafeExperimentalConfig,
  type UUID,
  type VisualRegionResult,
} from '@charkle/shared';
import type { IMediaPipeline } from '../context.js';
import { cosineSimilarity, type LibraryDatabase } from '../db/library-database.js';
import type { IImageProcessor } from '../runtime/types.js';
import { randomUUID } from '../runtime/web-crypto-utils.js';
import type { CloudAIProvider, FetchLike } from './cloud-ai-provider.js';
import type { CloudAIUsageTracker } from './cloud-ai-usage-tracker.js';
import { MoodboardCurator } from './moodboard-curator.js';
import {
  boxCoordinatesToNormalizedCrop,
  createTypeSafeImageAttachment,
  TypeSafeError,
  TypeSafeImagePreparer,
  TypeSafeSystemOneClient,
  type TypeSafeImageAttachment,
  type TypeSafeQuestion,
} from './typesafe-client.js';

export interface VisualCandidateInput {
  assetID: UUID;
  title: string;
  tags: string[];
  description?: string | null;
  imageData: Buffer | null;
  imageFormat?: 'jpg' | 'png';
}

export interface VisualScoreResult {
  assetID: UUID;
  /** Normalized relevance score in `[0, 1]` derived from Jev's `0..3` calibrated Score. */
  score: number;
  confidence: number | null;
  rawScore: number;
}

export interface FolderOptionInput {
  id: UUID;
  name: string;
  sampleTags: string[];
}

// MARK: - Visual Grounding Engine (Phase 1 + Phase 2)

export interface VisualGroundingEngineOptions {
  usage?: CloudAIUsageTracker | null;
  fetchFn?: FetchLike;
  images?: IImageProcessor | null;
}

export class VisualGroundingEngine {
  private readonly usage: CloudAIUsageTracker | null;
  private readonly fetchFn: FetchLike;
  private readonly images: IImageProcessor | null;

  constructor(opts: VisualGroundingEngineOptions = {}) {
    this.usage = opts.usage ?? null;
    this.fetchFn = opts.fetchFn ?? globalThis.fetch;
    this.images = opts.images ?? null;
  }

  private createClient(config: TypeSafeExperimentalConfig, apiKey: string): TypeSafeSystemOneClient {
    return new TypeSafeSystemOneClient({
      baseURL: config.baseURL,
      apiKey,
      usage: this.usage,
      fetchFn: this.fetchFn,
    });
  }

  /**
   * Phase 1.1: Locate primary visual subject (`query` empty) or semantic element (`query` non-empty).
   * Uses companion `noul("present")` + `box("region")` when TypeSafe Jev is enabled,
   * applying `lowConfidencePadding` if `confidence < minConfidence`, and falling back to
   * local sharp edge/center saliency in subject mode when Jev is disabled or unreachable.
   */
  async locateRegion(params: {
    query?: string | null;
    imageBuffer: Buffer;
    imageFormat?: 'jpg' | 'png';
    config: TypeSafeExperimentalConfig;
    apiKey?: string | null;
    images?: IImageProcessor | null;
  }): Promise<VisualRegionResult> {
    const images = params.images ?? this.images;
    const trimmedQuery = (params.query ?? '').trim();
    const isSemanticQuery = trimmedQuery.length > 0;
    const key = params.apiKey?.trim() ?? '';

    if (params.config.enabled && key.length > 0) {
      try {
        const prepared = await TypeSafeImagePreparer.prepareJPEG(
          params.imageBuffer,
          768,
          0.86,
          images,
        );
        const wireData = prepared?.data ?? params.imageBuffer;
        const client = this.createClient(params.config, key);
        const photoRef = `img-${randomUUID().toLowerCase()}`;
        const attachment = createTypeSafeImageAttachment({
          referenceKey: photoRef,
          partName: 'photo',
          format: prepared ? 'jpg' : params.imageFormat ?? 'jpg',
          data: wireData,
        });

        const targetPhrase = isSemanticQuery
          ? trimmedQuery
          : 'the main visual subject, hero object, or focal artwork';

        const response = await client.systemOne({
          model: params.config.model,
          state: { photo: photoRef },
          questions: {
            present: {
              type: 'noul',
              instructions: `Is ${targetPhrase} clearly visible in \`photo\`?`,
              trueCriteria: 'The requested subject or visual element is visible in `photo`.',
              falseCriteria: 'The requested subject or visual element does not appear in `photo`.',
            },
            region: {
              type: 'box',
              instructions: `${targetPhrase} in \`photo\``,
            },
          },
          images: [attachment],
        });

        const presentAns = response.answers.present;
        const presence = presentAns?.type === 'noul' ? presentAns.probability : 1.0;
        const regionAns = response.answers.region;
        if (!regionAns || regionAns.type !== 'box') {
          throw new TypeSafeError('TypeSafe 未返回有效的 Box 定位结果。');
        }

        const rawBox = clampCropRect(boxCoordinatesToNormalizedCrop(regionAns.box));
        const confidence = regionAns.confidence;
        const minPresence = Math.max(0.05, Math.min(0.95, params.config.minPresenceProbability));
        const found = presence >= minPresence;
        const shouldPad =
          params.config.lowConfidencePadding > 0 &&
          (confidence === null || confidence < params.config.minConfidence);
        const finalCrop = shouldPad
          ? padCropRect(rawBox, params.config.lowConfidencePadding)
          : rawBox;

        let summary: string;
        if (!found) {
          summary = isSemanticQuery
            ? `画面中未检测到「${trimmedQuery}」（存在概率 ${Math.round(presence * 100)}%）`
            : `未检测到明确视觉主体（存在概率 ${Math.round(presence * 100)}%）`;
        } else {
          const confText = confidence !== null ? `置信度 ${Math.round(confidence * 100)}%` : '已定位';
          const padText = shouldPad ? ' · 已自动外扩防切边' : '';
          summary = isSemanticQuery
            ? `Jev Box 已定位「${trimmedQuery}」（${confText}${padText}）`
            : `Jev Box 已聚焦主体（${confText}${padText}）`;
        }

        return {
          crop: finalCrop,
          rawBox,
          presenceProbability: presence,
          confidence,
          didApplyPadding: shouldPad,
          found,
          source: 'typeSafeJev',
          model: response.model,
          summary,
        };
      } catch (err) {
        if (isSemanticQuery) {
          throw err;
        }
        // Unreachable Jev in subject mode -> fall through to local sharp saliency fallback
      }
    }

    if (isSemanticQuery) {
      throw new TypeSafeError(
        '「一句话语义定位」需要开启 TypeSafe (Jev) 实验档并填写 API 密钥（可在 设置 → 智能与搜索 中开启）。',
      );
    }

    const saliency = images?.detectPrimarySubjectBox
      ? await images.detectPrimarySubjectBox(params.imageBuffer)
      : null;
    if (!saliency) {
      return {
        crop: { ...FULL_CROP_RECT },
        rawBox: { ...FULL_CROP_RECT },
        presenceProbability: 0,
        confidence: null,
        didApplyPadding: false,
        found: false,
        source: 'appleVisionSaliency',
        model: null,
        summary: '本机主体识别未检测到独立聚焦主体',
      };
    }

    const padded = padCropRect(saliency, 0.04);
    return {
      crop: padded,
      rawBox: saliency,
      presenceProbability: 1.0,
      confidence: null,
      didApplyPadding: true,
      found: true,
      source: 'appleVisionSaliency',
      model: 'Local Sharp Saliency',
      summary: '已通过本机视觉显著性自动聚焦主体',
    };
  }

  /**
   * Phase 1.2: Locate where a reference image snippet appears inside a target image.
   */
  async locateVisualMatch(params: {
    referenceImageBuffer: Buffer;
    referenceFormat?: 'jpg' | 'png';
    targetImageBuffer: Buffer;
    targetFormat?: 'jpg' | 'png';
    config: TypeSafeExperimentalConfig;
    apiKey?: string | null;
    images?: IImageProcessor | null;
  }): Promise<VisualRegionResult> {
    const images = params.images ?? this.images;
    const key = params.apiKey?.trim() ?? '';
    if (!params.config.enabled || !key) {
      throw new TypeSafeError('「以图定位」需要开启 TypeSafe (Jev) 实验档并配置 API 密钥。');
    }

    const [prepRef, prepTarget] = await Promise.all([
      TypeSafeImagePreparer.prepareJPEG(params.referenceImageBuffer, 512, 0.86, images),
      TypeSafeImagePreparer.prepareJPEG(params.targetImageBuffer, 768, 0.86, images),
    ]);

    const client = this.createClient(params.config, key);
    const targetRef = `target-${randomUUID().toLowerCase()}`;
    const snippetRef = `ref-${randomUUID().toLowerCase()}`;

    const response = await client.systemOne({
      model: params.config.model,
      state: { target: targetRef },
      questions: {
        present: {
          type: 'noul',
          instructions: `Does the object or visual element shown in ${snippetRef} appear in \`target\`?`,
        },
        region: {
          type: 'box',
          instructions: `the region in \`target\` that matches this reference: ${snippetRef}`,
        },
      },
      images: [
        createTypeSafeImageAttachment({
          referenceKey: targetRef,
          partName: 'target_image',
          format: prepTarget ? 'jpg' : params.targetFormat ?? 'jpg',
          data: prepTarget?.data ?? params.targetImageBuffer,
        }),
        createTypeSafeImageAttachment({
          referenceKey: snippetRef,
          partName: 'reference_image',
          format: prepRef ? 'jpg' : params.referenceFormat ?? 'jpg',
          data: prepRef?.data ?? params.referenceImageBuffer,
        }),
      ],
    });

    const presentAns = response.answers.present;
    const presence = presentAns?.type === 'noul' ? presentAns.probability : 1.0;
    const regionAns = response.answers.region;
    if (!regionAns || regionAns.type !== 'box') {
      throw new TypeSafeError('TypeSafe 未返回有效的以图定位 Box 结果。');
    }

    const rawBox = clampCropRect(boxCoordinatesToNormalizedCrop(regionAns.box));
    const confidence = regionAns.confidence;
    const shouldPad =
      (confidence ?? 0) < params.config.minConfidence && params.config.lowConfidencePadding > 0;
    const finalCrop = shouldPad ? padCropRect(rawBox, params.config.lowConfidencePadding) : rawBox;
    const found = presence >= Math.max(0.05, Math.min(0.95, params.config.minPresenceProbability));

    return {
      crop: finalCrop,
      rawBox,
      presenceProbability: presence,
      confidence,
      didApplyPadding: shouldPad,
      found,
      source: 'typeSafeJev',
      model: response.model,
      summary: found ? 'Jev Box 已在目标图中找到匹配局部' : '目标图中未找到匹配该参考图的元素',
    };
  }

  /**
   * Phase 1.3: Detect screenshot/browser chrome or blank margins and return clean content crop.
   */
  async detectCleanContentBounds(params: {
    imageBuffer: Buffer;
    imageFormat?: 'jpg' | 'png';
    config: TypeSafeExperimentalConfig;
    apiKey?: string | null;
    images?: IImageProcessor | null;
  }): Promise<CleanBoundsResult> {
    const images = params.images ?? this.images;
    const key = params.apiKey?.trim() ?? '';
    if (params.config.enabled && key.length > 0) {
      try {
        const prepared = await TypeSafeImagePreparer.prepareJPEG(
          params.imageBuffer,
          768,
          0.86,
          images,
        );
        const client = this.createClient(params.config, key);
        const photoRef = `capture-${randomUUID().toLowerCase()}`;
        const attachment = createTypeSafeImageAttachment({
          referenceKey: photoRef,
          partName: 'capture',
          format: prepared ? 'jpg' : params.imageFormat ?? 'jpg',
          data: prepared?.data ?? params.imageBuffer,
        });

        const response = await client.systemOne({
          model: params.config.model,
          state: { capture: photoRef },
          questions: {
            has_noise: {
              type: 'noul',
              instructions:
                'Does `capture` contain unwanted browser chrome, OS window frames, status bars, social media UI surrounding a design, letterbox bars, or excessive blank outer margins?',
              trueCriteria:
                'There are surrounding UI bars, window chrome, black/white letterbox margins, or desktop background framing the real visual content.',
              falseCriteria:
                'The image is already cleanly framed artwork or photography filling the canvas without unwanted borders or UI chrome.',
            },
            core_content: {
              type: 'box',
              instructions:
                'the core visual artwork, photograph, poster, or primary design card in `capture`, excluding browser toolbars, OS window chrome, social post framing, and empty surrounding borders',
            },
          },
          images: [attachment],
        });

        const noiseAns = response.answers.has_noise;
        const noiseProb = noiseAns?.type === 'noul' ? noiseAns.probability : 0.0;
        const boxAns = response.answers.core_content;
        const confidence = boxAns?.type === 'box' ? boxAns.confidence : null;
        const hasNoise =
          noiseProb >= Math.max(0.35, Math.min(0.9, params.config.minPresenceProbability));

        if (!hasNoise || !boxAns || boxAns.type !== 'box') {
          return {
            hasNoise: false,
            noiseProbability: noiseProb,
            recommendedCrop: null,
            confidence,
            didApplyPadding: false,
            source: 'typeSafeJev',
            model: response.model,
            summary: '画面本身已很干净，无需额外去噪裁切',
          };
        }

        const rawBox = clampCropRect(boxCoordinatesToNormalizedCrop(boxAns.box));
        const shouldPad =
          (confidence ?? 0) < params.config.minConfidence && params.config.lowConfidencePadding > 0;
        const finalCrop = shouldPad
          ? padCropRect(rawBox, Math.min(0.03, params.config.lowConfidencePadding))
          : rawBox;
        const meaningful = isMeaningfulCropSubregion(finalCrop);
        const confText = confidence !== null ? `置信度 ${Math.round(confidence * 100)}%` : '已识别';

        return {
          hasNoise: meaningful,
          noiseProbability: noiseProb,
          recommendedCrop: meaningful ? finalCrop : null,
          confidence,
          didApplyPadding: shouldPad,
          source: 'typeSafeJev',
          model: response.model,
          summary: meaningful
            ? `Jev 已识别核心内容区域并去除外围噪边（${confText}）`
            : '核心内容几乎占满整图，保持原画幅更佳',
        };
      } catch {
        // Fallback to local saliency when Jev is unreachable
      }
    }

    const saliency = images?.detectPrimarySubjectBox
      ? await images.detectPrimarySubjectBox(params.imageBuffer)
      : null;
    if (!saliency) {
      return {
        hasNoise: false,
        noiseProbability: 0,
        recommendedCrop: null,
        confidence: null,
        didApplyPadding: false,
        source: 'appleVisionSaliency',
        model: 'Local Sharp Saliency',
        summary: '未检测到明显多余边距，保持完整画面',
      };
    }

    const padded = padCropRect(saliency, 0.03);
    const meaningful = isMeaningfulCropSubregion(padded);
    return {
      hasNoise: meaningful,
      noiseProbability: meaningful ? 0.72 : 0.15,
      recommendedCrop: meaningful ? padded : null,
      confidence: null,
      didApplyPadding: true,
      source: 'appleVisionSaliency',
      model: 'Local Sharp Saliency',
      summary: meaningful ? '已通过本机视觉显著性裁去外围留白区域' : '画面已较为紧凑，无需裁切',
    };
  }

  /**
   * Phase 1.4: Locate subject first, crop pixels via `sharp`, extract CIELAB k-means palette.
   */
  async extractSubjectPaletteFromBuffer(params: {
    query?: string | null;
    imageBuffer: Buffer;
    imageFormat?: 'jpg' | 'png';
    colorCount?: number;
    config: TypeSafeExperimentalConfig;
    apiKey?: string | null;
    images?: IImageProcessor | null;
  }): Promise<{ colors: LabColor[]; region: VisualRegionResult }> {
    const images = params.images ?? this.images;
    const region = await this.locateRegion({
      query: params.query,
      imageBuffer: params.imageBuffer,
      imageFormat: params.imageFormat,
      config: params.config,
      apiKey: params.apiKey,
      images,
    });
    const effectiveCrop = region.found ? region.crop : null;
    const colors = images
      ? (
          await images.extractColorsAndFingerprint(params.imageBuffer, undefined, {
            crop: effectiveCrop,
            count: params.colorCount ?? 6,
          })
        ).colors
      : [];
    return { colors, region };
  }

  /**
   * Phase 2.1: Score candidate images against a natural-language query via batched Jev `Score` (`0..3`).
   */
  async scoreCandidatesForQuery(params: {
    query: string;
    candidates: VisualCandidateInput[];
    config: TypeSafeExperimentalConfig;
    apiKey?: string | null;
    batchSize?: number;
    maxConcurrency?: number;
  }): Promise<VisualScoreResult[]> {
    const trimmedQuery = params.query.trim();
    const key = params.apiKey?.trim() ?? '';
    if (!trimmedQuery || params.candidates.length === 0 || !params.config.enabled || !key) {
      return [];
    }

    const client = this.createClient(params.config, key);
    const effectiveBatch = Math.max(1, Math.min(6, params.batchSize ?? 4));
    const chunks: VisualCandidateInput[][] = [];
    for (let i = 0; i < params.candidates.length; i += effectiveBatch) {
      chunks.push(params.candidates.slice(i, i + effectiveBatch));
    }

    const workerLimit = Math.max(1, Math.min(params.maxConcurrency ?? 3, chunks.length));
    const results: VisualScoreResult[] = [];
    let nextIdx = 0;

    const worker = async (): Promise<void> => {
      while (nextIdx < chunks.length) {
        const chunkIdx = nextIdx++;
        const batch = chunks[chunkIdx];
        const batchResults = await this.scoreSingleBatch(
          trimmedQuery,
          batch,
          params.config.model,
          client,
        );
        results.push(...batchResults);
      }
    };

    await Promise.all(Array.from({ length: workerLimit }, () => worker()));
    results.sort((a, b) => b.score - a.score);
    return results;
  }

  private async scoreSingleBatch(
    query: string,
    batch: VisualCandidateInput[],
    model: string,
    client: TypeSafeSystemOneClient,
  ): Promise<VisualScoreResult[]> {
    const stateItems: Record<string, unknown> = {};
    const attachments: TypeSafeImageAttachment[] = [];
    const questions: Record<string, TypeSafeQuestion> = {};
    const keyToAssetID = new Map<string, UUID>();

    const scoreCriteria = [
      'Unrelated — subject, mood, color atmosphere, and design style do not match the query.',
      'Weakly related — only a tangential element or faint mood overlaps.',
      "Good match — clearly matches the query's visual subject, design language, or aesthetic mood.",
      'Strong exact match — directly depicts the requested subject, style, composition, or visual concept.',
    ];

    for (let idx = 0; idx < batch.length; idx++) {
      const item = batch[idx];
      const slotKey = `item_${idx}`;
      keyToAssetID.set(slotKey, item.assetID);

      const entry: Record<string, unknown> = {
        title: item.title.slice(0, 120),
      };
      if (item.tags.length > 0) entry.tags = item.tags.slice(0, 8);
      if (item.description?.trim()) entry.description = item.description.trim().slice(0, 240);
      if (item.imageData && item.imageData.length > 0) {
        const ref = `cand-${idx}-${randomUUID().toLowerCase()}`;
        entry.image = ref;
        attachments.push(
          createTypeSafeImageAttachment({
            referenceKey: ref,
            partName: `img_${idx}`,
            format: item.imageFormat ?? 'jpg',
            data: item.imageData,
          }),
        );
      }
      stateItems[slotKey] = entry;

      const hasImage = Boolean(item.imageData && item.imageData.length > 0);
      questions[slotKey] = {
        type: 'score',
        instructions: hasImage
          ? `Rate how well the design reference in \`items.${slotKey}.image\` (with metadata in \`items.${slotKey}\`) matches the user's visual search query: "${query}".`
          : `Rate how well the design reference metadata in \`items.${slotKey}\` matches the user's search query: "${query}".`,
        criteria: scoreCriteria,
      };
    }

    const response = await client.systemOne({
      model,
      state: { query, items: stateItems },
      questions,
      images: attachments,
    });

    const out: VisualScoreResult[] = [];
    for (const [slotKey, assetID] of keyToAssetID.entries()) {
      const ans = response.answers[slotKey];
      if (ans?.type === 'score') {
        const normalized = Math.max(0, Math.min(1, ans.score / 3.0));
        out.push({
          assetID,
          score: normalized,
          confidence: ans.confidence,
          rawScore: ans.score,
        });
      }
    }
    return out;
  }

  /**
   * Phase 2.2: Closed-set folder classification (`choice` + companion `noul("fits_any")`).
   * Respects `null` rejection when `fitProbability < clamp(0.35, 0.85, minPresenceProbability)`.
   */
  async classifyIntoFolders(params: {
    assetTitle: string;
    assetTags: string[];
    assetNotes: string;
    imageData: Buffer | null;
    imageFormat?: 'jpg' | 'png';
    folders: FolderOptionInput[];
    config: TypeSafeExperimentalConfig;
    apiKey?: string | null;
  }): Promise<{
    folderID: UUID | null;
    confidence: number;
    fitProbability: number;
    reason: string;
  }> {
    if (params.folders.length === 0) {
      return { folderID: null, confidence: 0, fitProbability: 0, reason: '素材库暂无目标文件夹' };
    }
    const key = params.apiKey?.trim() ?? '';
    if (!params.config.enabled || !key) {
      throw new TypeSafeError('Inbox 智能分拣需要开启 TypeSafe (Jev) 实验档并配置 API 密钥。');
    }

    const client = this.createClient(params.config, key);
    const cappedFolders = params.folders.slice(0, 32);
    const criteria: Record<string, string> = {};
    const idByKey = new Map<string, FolderOptionInput>();

    cappedFolders.forEach((folder, idx) => {
      const optionKey = `f_${idx}`;
      idByKey.set(optionKey, folder);
      const tagsHint =
        folder.sampleTags.length > 0
          ? ` (typical themes/tags: ${folder.sampleTags.slice(0, 6).join(', ')})`
          : '';
      criteria[optionKey] = `Folder "${folder.name}"${tagsHint}`;
    });

    const state: Record<string, unknown> = {
      title: params.assetTitle.slice(0, 120),
      tags: params.assetTags.slice(0, 10),
      notes: params.assetNotes.slice(0, 240),
    };
    const attachments: TypeSafeImageAttachment[] = [];
    if (params.imageData && params.imageData.length > 0) {
      const photoRef = `inbox-${randomUUID().toLowerCase()}`;
      state.photo = photoRef;
      attachments.push(
        createTypeSafeImageAttachment({
          referenceKey: photoRef,
          partName: 'inbox_photo',
          format: params.imageFormat ?? 'jpg',
          data: params.imageData,
        }),
      );
    }

    const folderNamesList = cappedFolders.map((f) => f.name).join(', ');
    const targetDesc =
      params.imageData && params.imageData.length > 0
        ? '`photo` and its metadata'
        : "this design asset's metadata";

    const response = await client.systemOne({
      model: params.config.model,
      state,
      questions: {
        fits_any: {
          type: 'noul',
          instructions: `Does ${targetDesc} clearly belong in one of these design reference folders (${folderNamesList})?`,
          trueCriteria:
            'The visual subject, medium, or design style clearly matches at least one listed folder.',
          falseCriteria:
            'None of the listed folders fit well; it should stay uncategorized in Inbox.',
        },
        folder: {
          type: 'choice',
          instructions: `Which folder best fits ${targetDesc}?`,
          criteria,
        },
      },
      images: attachments,
    });

    const fitsAns = response.answers.fits_any;
    const fitProb = fitsAns?.type === 'noul' ? fitsAns.probability : 0.5;
    const choiceAns = response.answers.folder;
    const chosen = choiceAns?.type === 'choice' ? idByKey.get(choiceAns.choice) : undefined;
    if (!choiceAns || choiceAns.type !== 'choice' || !chosen) {
      return {
        folderID: null,
        confidence: 0,
        fitProbability: fitProb,
        reason: '未能确定合适目录，建议暂留收件箱',
      };
    }

    const topProb = choiceAns.probabilities[choiceAns.choice] ?? fitProb;
    const effectiveConfidence = Math.max(0, Math.min(1, choiceAns.confidence ?? topProb));
    const minFit = Math.max(0.35, Math.min(0.85, params.config.minPresenceProbability));

    if (fitProb < minFit) {
      return {
        folderID: null,
        confidence: effectiveConfidence,
        fitProbability: fitProb,
        reason: `匹配度偏低（${Math.round(fitProb * 100)}%），建议暂留收件箱（最接近：${chosen.name}）`,
      };
    }

    return {
      folderID: chosen.id,
      confidence: effectiveConfidence,
      fitProbability: fitProb,
      reason: `Jev 视觉归类（匹配度 ${Math.round(fitProb * 100)}% · 置信度 ${Math.round(effectiveConfidence * 100)}%）`,
    };
  }
}

// MARK: - High-Level Library Visual Grounding Orchestrator

export interface VisualGroundingServiceDeps {
  db: LibraryDatabase;
  media: IMediaPipeline;
  engine: VisualGroundingEngine;
  getTypeSafeConfig: () => TypeSafeExperimentalConfig;
  getTypeSafeAPIKey: () => string | null;
  getCloudAIProvider: () => CloudAIProvider | null;
}

export class VisualGroundingService {
  private readonly deps: VisualGroundingServiceDeps;

  constructor(deps: VisualGroundingServiceDeps) {
    this.deps = deps;
  }

  async loadAssetImageBuffer(assetID: UUID, preferHighRes = true): Promise<Buffer | null> {
    const asset = this.deps.db.getAsset(assetID);
    if (!asset) return null;

    if (preferHighRes) {
      const p1400 = await this.deps.media.readThumbnailBuffer(assetID, 'preview1400');
      if (p1400 && p1400.length > 0) return p1400;
    }
    const g520 = await this.deps.media.readThumbnailBuffer(assetID, 'grid520');
    if (g520 && g520.length > 0) return g520;

    if (asset.mediaKind === 'image' || asset.mediaKind === 'animatedImage') {
      const orig = await this.deps.media.readOriginalBuffer(asset);
      if (orig && orig.length > 0) return orig;
    }
    return null;
  }

  async preparedTypeSafeJPEG(assetID: UUID, targetLongSide = 448): Promise<Buffer | null> {
    const raw = await this.loadAssetImageBuffer(assetID, targetLongSide > 520);
    if (!raw) return null;
    const prep = await TypeSafeImagePreparer.prepareJPEG(
      raw,
      targetLongSide,
      0.86,
      this.deps.media.images,
    );
    return prep?.data ?? null;
  }

  async locateVisualRegion(assetID: UUID, query?: string | null): Promise<VisualRegionResult> {
    const buf = await this.loadAssetImageBuffer(assetID, true);
    if (!buf) {
      throw new TypeSafeError('该素材暂无可供定位的图像预览。');
    }
    return this.deps.engine.locateRegion({
      query,
      imageBuffer: buf,
      config: this.deps.getTypeSafeConfig(),
      apiKey: this.deps.getTypeSafeAPIKey(),
      images: this.deps.media.images,
    });
  }

  async locateVisualMatch(referenceAssetID: UUID, targetAssetID: UUID): Promise<VisualRegionResult> {
    const [refBuf, targetBuf] = await Promise.all([
      this.loadAssetImageBuffer(referenceAssetID, false),
      this.loadAssetImageBuffer(targetAssetID, true),
    ]);
    if (!refBuf || !targetBuf) {
      throw new TypeSafeError('参考图或目标图缺少可读取的像素图像。');
    }
    return this.deps.engine.locateVisualMatch({
      referenceImageBuffer: refBuf,
      targetImageBuffer: targetBuf,
      config: this.deps.getTypeSafeConfig(),
      apiKey: this.deps.getTypeSafeAPIKey(),
      images: this.deps.media.images,
    });
  }

  async detectCleanContentBounds(assetID: UUID): Promise<CleanBoundsResult> {
    const buf = await this.loadAssetImageBuffer(assetID, true);
    if (!buf) {
      throw new TypeSafeError('该素材暂无可供分析边距的图像预览。');
    }
    return this.deps.engine.detectCleanContentBounds({
      imageBuffer: buf,
      config: this.deps.getTypeSafeConfig(),
      apiKey: this.deps.getTypeSafeAPIKey(),
      images: this.deps.media.images,
    });
  }

  async extractSubjectPalette(assetID: UUID, query?: string | null): Promise<SubjectPaletteResult> {
    const before = this.deps.db.getAsset(assetID);
    if (!before) {
      throw new TypeSafeError(`Asset not found: ${assetID}`);
    }
    const buf = await this.loadAssetImageBuffer(assetID, true);
    if (!buf) {
      throw new TypeSafeError('该素材暂无可供提色的像素图像。');
    }
    const { colors, region } = await this.deps.engine.extractSubjectPaletteFromBuffer({
      query,
      imageBuffer: buf,
      colorCount: 6,
      config: this.deps.getTypeSafeConfig(),
      apiKey: this.deps.getTypeSafeAPIKey(),
      images: this.deps.media.images,
    });

    const updatedAsset = this.deps.db.transaction(() => {
      const current = this.deps.db.getAsset(assetID) ?? before;
      if (colors.length > 0) {
        return this.deps.db.saveAssetLocally({ ...current, dominantColors: colors });
      }
      return current;
    });

    return {
      colors,
      subjectRegion: region,
      updatedAsset,
    };
  }

  /**
   * 3-Signal Hybrid Semantic Search (PARITY_SPEC 11.2):
   * Signal A: FTS5 + Pinyin text ranks
   * Signal B: Cloud Embedding cosine > 0.22 mapped `(cos - 0.22) / 0.63`
   * Signal C: TypeSafe Jev Score on up to 24 candidates (graceful fallback when disabled/unreachable)
   */
  async semanticSearch(
    query: string,
    partialCriteria: Partial<FilterCriteria> = {},
    limit = 48,
  ): Promise<SemanticSearchReport> {
    const trimmed = query.trim();
    if (!trimmed) {
      return {
        query: '',
        hits: [],
        usedTypeSafeJev: false,
        usedCloudEmbedding: false,
        evaluatedVisualCount: 0,
        summary: '请输入检索描述',
      };
    }

    const scope: FilterCriteria = createDefaultFilterCriteria({
      ...partialCriteria,
      searchQuery: '',
    });
    const scopedAssets = this.deps.db.fetchAssets(scope);
    if (scopedAssets.length === 0) {
      return {
        query: trimmed,
        hits: [],
        usedTypeSafeJev: false,
        usedCloudEmbedding: false,
        evaluatedVisualCount: 0,
        summary: '当前筛选范围内没有可检索素材',
      };
    }

    // Signal A: Local FTS5 + Pinyin ranks
    const textRanks = new Map<UUID, number>(this.deps.db.searchRanks(trimmed));
    const tokens = trimmed.split(/\s+/).filter(Boolean);
    if (tokens.length > 1) {
      for (const token of tokens.slice(0, 8)) {
        for (const [id, rank] of this.deps.db.searchRanks(token)) {
          textRanks.set(id, Math.min(1.0, (textRanks.get(id) ?? 0) + rank / tokens.length));
        }
      }
    }

    // Signal B: Cloud Embedding cosine similarity
    const embeddingScores = new Map<UUID, number>();
    let usedEmbedding = false;
    let provider: CloudAIProvider | null = null;
    try {
      provider = this.deps.getCloudAIProvider();
    } catch {
      provider = null;
    }

    if (provider) {
      const vectors = this.deps.db.getAllVectors();
      let hasCompatible = false;
      for (const v of vectors.values()) {
        if (v.embeddingModel === provider.embeddingIdentity && v.embedding && v.embedding.length > 0) {
          hasCompatible = true;
          break;
        }
      }
      if (hasCompatible) {
        try {
          const queryVec = await provider.embed(trimmed);
          usedEmbedding = true;
          for (const asset of scopedAssets) {
            const vec = vectors.get(asset.id);
            if (vec?.embeddingModel === provider.embeddingIdentity && vec.embedding) {
              const cos = cosineSimilarity(queryVec, vec.embedding);
              if (cos > 0.22) {
                embeddingScores.set(asset.id, Math.max(0, Math.min(1, (cos - 0.22) / 0.63)));
              }
            }
          }
        } catch {
          usedEmbedding = false;
        }
      }
    }

    // Signal C: Optional TypeSafe Jev Score visual rerank
    const jevScores = new Map<UUID, VisualScoreResult>();
    let usedJev = false;
    let evaluatedVisualCount = 0;
    const tsConfig = this.deps.getTypeSafeConfig();
    const tsKey = this.deps.getTypeSafeAPIKey();

    if (tsConfig.enabled && tsConfig.enableSemanticSearch && tsKey) {
      const maxVisualCandidates = 24;
      const prioritized = [...scopedAssets].sort((lhs, rhs) => {
        const ls = (textRanks.get(lhs.id) ?? 0) * 0.5 + (embeddingScores.get(lhs.id) ?? 0) * 0.5;
        const rs = (textRanks.get(rhs.id) ?? 0) * 0.5 + (embeddingScores.get(rhs.id) ?? 0) * 0.5;
        if (Math.abs(ls - rs) > 0.01) return rs - ls;
        return rhs.updatedAt.localeCompare(lhs.updatedAt);
      });

      const shortlist: AssetRecord[] = prioritized.slice(0, 16);
      const seen = new Set<UUID>(shortlist.map((a) => a.id));
      for (const asset of scopedAssets) {
        if (shortlist.length >= maxVisualCandidates) break;
        if (!seen.has(asset.id) && (asset.tags.length === 0 || !asset.aiDescription)) {
          seen.add(asset.id);
          shortlist.push(asset);
        }
      }
      for (const asset of prioritized) {
        if (shortlist.length >= maxVisualCandidates) break;
        if (!seen.has(asset.id)) {
          seen.add(asset.id);
          shortlist.push(asset);
        }
      }

      const visualInputs: VisualCandidateInput[] = await Promise.all(
        shortlist.map(async (asset) => ({
          assetID: asset.id,
          title: asset.title,
          tags: asset.tags,
          description: asset.aiDescription,
          imageData: await this.preparedTypeSafeJPEG(asset.id, 384),
          imageFormat: 'jpg' as const,
        })),
      );

      evaluatedVisualCount = visualInputs.length;
      try {
        const scored = await this.deps.engine.scoreCandidatesForQuery({
          query: trimmed,
          candidates: visualInputs,
          config: tsConfig,
          apiKey: tsKey,
          batchSize: 4,
          maxConcurrency: 3,
        });
        usedJev = scored.length > 0;
        for (const item of scored) {
          jevScores.set(item.assetID, item);
        }
      } catch {
        // Graceful fallback to FTS5 + Embedding if Jev is unreachable
        usedJev = false;
        evaluatedVisualCount = 0;
      }
    }

    // Fuse signals
    const cutoff = usedJev || usedEmbedding ? 0.32 : 0.05;
    const hits: SemanticSearchHit[] = [];

    for (const asset of scopedAssets) {
      const tScore = textRanks.get(asset.id) ?? 0;
      const eScore = embeddingScores.get(asset.id) ?? 0;
      const jResult = jevScores.get(asset.id);
      const jScore = jResult?.score ?? 0;

      let combined: number;
      const reasons: string[] = [];
      let sourceLabel = '全文匹配';

      if (jResult) {
        if (jScore >= 0.3) reasons.push(`Jev 视觉语义 ${Math.round(jScore * 100)}%`);
        if (eScore >= 0.3) reasons.push(`向量相似度 ${Math.round(eScore * 100)}%`);
        if (tScore > 0.05) reasons.push('标题/标签/OCR 命中');
        const nonVisual = Math.max(tScore, eScore);
        combined = Math.max(jScore, jScore * 0.72 + nonVisual * 0.28);
        sourceLabel = eScore >= 0.3 ? 'Jev 视觉 + 向量' : 'Jev 视觉语义';
      } else if (eScore >= 0.28) {
        reasons.push(`语义向量 ${Math.round(eScore * 100)}%`);
        if (tScore > 0.05) reasons.push('关键词命中');
        combined = Math.max(eScore, eScore * 0.75 + tScore * 0.25);
        sourceLabel = '语义向量';
      } else if (tScore > 0.05) {
        reasons.push('全文/标签/拼音匹配');
        combined = tScore * 0.85;
        sourceLabel = '本机全文';
      } else {
        continue;
      }

      if (combined < cutoff) continue;

      hits.push({
        asset,
        score: Math.min(1.0, combined),
        confidence: jResult?.confidence ?? null,
        reason: reasons.join(' · '),
        sourceLabel,
      });
    }

    hits.sort((a, b) => {
      if (Math.abs(a.score - b.score) > 0.002) return b.score - a.score;
      return b.asset.rating - a.asset.rating;
    });
    const limited = hits.slice(0, Math.max(1, limit));

    const engines: string[] = [];
    if (usedJev) engines.push(`Jev 视觉语义(${evaluatedVisualCount}图)`);
    if (usedEmbedding) engines.push('语义向量');
    if (engines.length === 0) engines.push('本机全文/拼音');

    const summary =
      limited.length === 0
        ? `语义检索「${trimmed}」未命中高度相关素材（${engines.join(' + ')}）`
        : `语义检索「${trimmed}」命中 ${limited.length} 项（${engines.join(' + ')}）`;

    return {
      query: trimmed,
      hits: limited,
      usedTypeSafeJev: usedJev,
      usedCloudEmbedding: usedEmbedding,
      evaluatedVisualCount,
      summary,
    };
  }

  private buildFolderOptions(folders: FolderRecord[]): FolderOptionInput[] {
    const allAssets = this.deps.db.fetchAssets({ includeTrashed: false });
    const tagsByFolder = new Map<UUID, Map<string, number>>();
    for (const asset of allAssets) {
      if (!asset.folderID) continue;
      let counts = tagsByFolder.get(asset.folderID);
      if (!counts) {
        counts = new Map();
        tagsByFolder.set(asset.folderID, counts);
      }
      for (const tag of asset.tags) {
        counts.set(tag, (counts.get(tag) ?? 0) + 1);
      }
    }
    return folders.map((folder) => {
      const counts = tagsByFolder.get(folder.id);
      const topTags = counts
        ? [...counts.entries()]
            .sort((a, b) => b[1] - a[1])
            .slice(0, 6)
            .map(([tag]) => tag)
        : [];
      return { id: folder.id, name: folder.name, sampleTags: topTags };
    });
  }

  /**
   * Single-asset folder suggestion.
   * Crucially respects Jev `null` rejection when Jev evaluates fit and declines all folders!
   */
  async suggestFolder(assetID: UUID): Promise<FolderSuggestion | null> {
    const tsConfig = this.deps.getTypeSafeConfig();
    const tsKey = this.deps.getTypeSafeAPIKey();
    const asset = this.deps.db.getAsset(assetID);
    if (!asset) return null;

    if (tsConfig.enabled && tsConfig.enableInboxSmartTriage && tsKey) {
      const folders = this.deps.db.fetchFolders().filter((f) => f.id !== asset.folderID);
      if (folders.length > 0) {
        const options = this.buildFolderOptions(folders);
        const jpeg = await this.preparedTypeSafeJPEG(assetID, 448);
        try {
          const res = await this.deps.engine.classifyIntoFolders({
            assetTitle: asset.title,
            assetTags: [...asset.tags, ...asset.suggestedTags],
            assetNotes: [asset.notes, asset.aiDescription ?? ''].filter(Boolean).join(' '),
            imageData: jpeg,
            folders: options,
            config: tsConfig,
            apiKey: tsKey,
          });
          if (res.folderID) {
            const matched = folders.find((f) => f.id === res.folderID);
            if (matched) {
              return {
                folderID: matched.id,
                folderName: matched.name,
                confidence: res.confidence,
                reason: res.reason,
              };
            }
          }
          // Jev explicitly evaluated fit and found none suitable — respect null!
          return null;
        } catch {
          // Unreachable Jev -> fall through to offline suggestion
        }
      }
    }

    return (
      new MoodboardCurator(this.deps.db).suggestFolder(assetID) ??
      this.deps.db.suggestFolder(assetID)
    );
  }

  /**
   * Batch Inbox AI Triage (up to `maxCount` assets, default 24, 4 concurrent workers).
   * Respects Jev `null` rejection and sorts recommended folders first, then confidence & fitProbability desc.
   */
  async batchTriageInbox(
    assetIDs: UUID[] = [],
    maxCount = 24,
  ): Promise<InboxTriageRecommendation[]> {
    const folders = this.deps.db.fetchFolders();
    if (folders.length === 0) {
      throw new TypeSafeError('请先在左侧栏创建至少一个目标文件夹，再使用智能分拣。');
    }

    const cap = Math.max(1, Math.min(64, maxCount));
    let targets: AssetRecord[];
    if (assetIDs.length === 0) {
      targets = this.deps.db.fetchAssets({ onlyInbox: true }, cap);
    } else {
      targets = [];
      for (const id of assetIDs.slice(0, cap)) {
        const asset = this.deps.db.getAsset(id);
        if (asset && !asset.isTrashed) targets.push(asset);
      }
    }
    if (targets.length === 0) return [];

    const tsConfig = this.deps.getTypeSafeConfig();
    const tsKey = this.deps.getTypeSafeAPIKey();
    const folderByID = new Map(folders.map((f) => [f.id, f]));

    if (tsConfig.enabled && tsConfig.enableInboxSmartTriage && tsKey) {
      const options = this.buildFolderOptions(folders);
      const prepared = await Promise.all(
        targets.map(async (asset) => ({
          asset,
          jpeg: await this.preparedTypeSafeJPEG(asset.id, 384),
        })),
      );

      const recommendations: InboxTriageRecommendation[] = [];
      let nextIdx = 0;
      const workerCount = Math.min(4, prepared.length);

      try {
        const worker = async (): Promise<void> => {
          while (nextIdx < prepared.length) {
            const item = prepared[nextIdx++];
            const res = await this.deps.engine.classifyIntoFolders({
              assetTitle: item.asset.title,
              assetTags: [...item.asset.tags, ...item.asset.suggestedTags],
              assetNotes: [item.asset.notes, item.asset.aiDescription ?? '']
                .filter(Boolean)
                .join(' '),
              imageData: item.jpeg,
              folders: options,
              config: tsConfig,
              apiKey: tsKey,
            });
            const folderName = res.folderID ? (folderByID.get(res.folderID)?.name ?? null) : null;
            recommendations.push({
              assetID: item.asset.id,
              assetTitle: item.asset.title,
              recommendedFolderID: res.folderID,
              recommendedFolderName: folderName,
              confidence: res.confidence,
              fitProbability: res.fitProbability,
              reason: res.reason,
              source: 'typeSafeJev',
            });
          }
        };

        await Promise.all(Array.from({ length: workerCount }, () => worker()));
        return recommendations.sort((a, b) => {
          const lHas = a.recommendedFolderID ? 1 : 0;
          const rHas = b.recommendedFolderID ? 1 : 0;
          if (lHas !== rHas) return rHas - lHas;
          if (Math.abs(a.confidence - b.confidence) > 0.005) return b.confidence - a.confidence;
          return b.fitProbability - a.fitProbability;
        });
      } catch {
        // Jev unreachable -> fall through to offline triage
      }
    }

    // Offline fallback
    const offlineRecs: InboxTriageRecommendation[] = targets.map((asset) => {
      const suggestion = this.deps.db.suggestFolder(asset.id);
      if (suggestion) {
        return {
          assetID: asset.id,
          assetTitle: asset.title,
          recommendedFolderID: suggestion.folderID,
          recommendedFolderName: suggestion.folderName,
          confidence: suggestion.confidence,
          fitProbability: suggestion.confidence,
          reason: suggestion.reason,
          source: 'appleVisionSaliency',
        };
      }
      return {
        assetID: asset.id,
        assetTitle: asset.title,
        recommendedFolderID: null,
        recommendedFolderName: null,
        confidence: 0,
        fitProbability: 0,
        reason: '离线未匹配到明确目录，建议暂留收件箱',
        source: 'appleVisionSaliency',
      };
    });

    return offlineRecs.sort((a, b) => b.confidence - a.confidence);
  }
}
