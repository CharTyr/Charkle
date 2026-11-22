import type { LabColor } from '../color/lab.js';
import type { AssetRecord, ISODateString, UUID } from './core.js';
import type { NormalizedCropRect } from './moodboard.js';

// MARK: - Capture & Media Cache

export type CaptureInput =
  | { type: 'fileURL'; url: string }
  | { type: 'imageData'; base64Data: string; suggestedName: string; sourceURL?: string | null }
  | { type: 'webURL'; url: string; title?: string | null; notes?: string | null }
  | { type: 'textSnippet'; title: string; text: string; sourceURL?: string | null }
  | { type: 'colorSwatch'; hex: string; title?: string | null };

export type ThumbnailTier = 'grid520' | 'preview1400';

export interface CacheStats {
  thumbnailBytes: number;
  originalCacheBytes: number;
  pinnedOfflineBytes: number;
  budgetBytes: number;
  cachedOriginalCount: number;
  pinnedAssetCount: number;
}

export function createDefaultCacheStats(overrides: Partial<CacheStats> = {}): CacheStats {
  return {
    thumbnailBytes: 0,
    originalCacheBytes: 0,
    pinnedOfflineBytes: 0,
    budgetBytes: 10 * 1024 * 1024 * 1024,
    cachedOriginalCount: 0,
    pinnedAssetCount: 0,
    ...overrides,
  };
}

// MARK: - Embeddings & Vectors

export type EmbeddingPrecision = 16 | 32;

export interface AssetVector {
  /** Base64-encoded binary visual feature print (macOS Vision VNFeaturePrint or perceptual digest). */
  featurePrint?: string | null;
  embedding?: number[] | null;
  embeddingModel?: string | null;
  precision: EmbeddingPrecision;
}

// MARK: - Cloud AI Configuration & Usage Telemetry

export type CloudAIProviderKind =
  | 'disabled'
  | 'chatGPTSubscription'
  | 'gemini'
  | 'openAICompatible';

export const CLOUD_AI_PROVIDER_KINDS: readonly CloudAIProviderKind[] = [
  'disabled',
  'chatGPTSubscription',
  'gemini',
  'openAICompatible',
] as const;

export function cloudAIProviderLocalizedLabel(kind: CloudAIProviderKind): string {
  switch (kind) {
    case 'disabled':
      return '关闭（仅本机）';
    case 'chatGPTSubscription':
      return 'ChatGPT 订阅账号';
    case 'gemini':
      return 'Google Gemini';
    case 'openAICompatible':
      return '自定义兼容服务';
  }
}

export type ChatGPTConnectionStatus = 'disconnected' | 'connected' | 'reauthRequired';

export interface ChatGPTAccountSession {
  status: ChatGPTConnectionStatus;
  sharingEnabled: boolean;
  email?: string | null;
  name?: string | null;
  subject?: string | null;
  lastUpdatedAt?: ISODateString | null;
}

export function getChatGPTAccountDisplayName(session: ChatGPTAccountSession): string {
  const name = session.name?.trim();
  if (name) return name;
  const email = session.email?.trim();
  if (email) return email;
  return 'ChatGPT 账号';
}

export interface ChatGPTModelInfo {
  slug: string;
  displayName: string;
}

export type CustomAIEndpointFormat =
  | 'openAIChatCompletions'
  | 'anthropicMessages'
  | 'openAIResponses';

export const CUSTOM_AI_ENDPOINT_FORMATS: readonly CustomAIEndpointFormat[] = [
  'openAIChatCompletions',
  'anthropicMessages',
  'openAIResponses',
] as const;

export function customAIEndpointLocalizedLabel(format: CustomAIEndpointFormat): string {
  switch (format) {
    case 'openAIChatCompletions':
      return 'OpenAI 兼容 (Chat Completions)';
    case 'anthropicMessages':
      return 'Anthropic Messages';
    case 'openAIResponses':
      return 'OpenAI Responses';
  }
}

export function customAIEndpointDefaultBaseURL(format: CustomAIEndpointFormat): string {
  return format === 'anthropicMessages' ? 'https://api.anthropic.com' : 'https://api.openai.com';
}

export function customAIEndpointDefaultChatModel(format: CustomAIEndpointFormat): string {
  return format === 'anthropicMessages' ? 'claude-sonnet-4-5' : 'gpt-4.1-mini';
}

export function customAIEndpointDefaultEmbeddingModel(format: CustomAIEndpointFormat): string {
  return format === 'anthropicMessages' ? '' : 'text-embedding-3-small';
}

export function customAIEndpointSupportsEmbeddings(format: CustomAIEndpointFormat): boolean {
  return format !== 'anthropicMessages';
}

export interface AIProviderConfig {
  provider: CloudAIProviderKind;
  customEndpointFormat: CustomAIEndpointFormat;
  baseURL: string;
  chatModel: string;
  embeddingModel: string;
  autoAnalyzeOnImport: boolean;
  sendThumbnailsToCloud: boolean;
}

export function createDefaultAIProviderConfig(
  overrides: Partial<AIProviderConfig> = {},
): AIProviderConfig {
  return {
    provider: 'disabled',
    customEndpointFormat: 'openAIChatCompletions',
    baseURL: 'https://generativelanguage.googleapis.com',
    chatModel: 'gemini-2.5-flash',
    embeddingModel: 'gemini-embedding-001',
    autoAnalyzeOnImport: false,
    sendThumbnailsToCloud: true,
    ...overrides,
  };
}

export type CloudAIUsageCategory = 'standard' | 'jev';

export interface CloudAIUsageBucket {
  dayKey: string;
  todayRequests: number;
  todayInputTokens: number;
  todayOutputTokens: number;
  todayTotalTokens: number;
  totalRequests: number;
  totalInputTokens: number;
  totalOutputTokens: number;
  totalTokens: number;
  lastProviderLabel?: string | null;
  lastModel?: string | null;
  lastUsedAt?: ISODateString | null;
  lastCallTokens: number;
}

export interface CloudAIUsageSummary {
  dayKey: string;
  todayRequests: number;
  todayInputTokens: number;
  todayOutputTokens: number;
  todayTotalTokens: number;
  totalRequests: number;
  totalInputTokens: number;
  totalOutputTokens: number;
  totalTokens: number;
  lastProviderLabel?: string | null;
  lastModel?: string | null;
  lastUsedAt?: ISODateString | null;
  lastCallTokens: number;
  standard: CloudAIUsageBucket;
  jev: CloudAIUsageBucket;
}

export function localDayKey(date: Date = new Date()): string {
  const y = String(date.getFullYear()).padStart(4, '0');
  const m = String(date.getMonth() + 1).padStart(2, '0');
  const d = String(date.getDate()).padStart(2, '0');
  return `${y}-${m}-${d}`;
}

export function formatTokenCount(count: number): string {
  const clamped = Math.max(0, Math.trunc(count));
  if (clamped >= 1_000_000) return `${(clamped / 1_000_000).toFixed(2)}M`;
  if (clamped >= 10_000) return `${(clamped / 1_000).toFixed(1)}K`;
  if (clamped >= 1_000) return `${(clamped / 1_000).toFixed(2)}K`;
  return String(clamped);
}

export function createDefaultCloudAIUsageBucket(dayKey: string = localDayKey()): CloudAIUsageBucket {
  return {
    dayKey,
    todayRequests: 0,
    todayInputTokens: 0,
    todayOutputTokens: 0,
    todayTotalTokens: 0,
    totalRequests: 0,
    totalInputTokens: 0,
    totalOutputTokens: 0,
    totalTokens: 0,
    lastProviderLabel: null,
    lastModel: null,
    lastUsedAt: null,
    lastCallTokens: 0,
  };
}

export function createDefaultCloudAIUsageSummary(
  dayKey: string = localDayKey(),
): CloudAIUsageSummary {
  return {
    dayKey,
    todayRequests: 0,
    todayInputTokens: 0,
    todayOutputTokens: 0,
    todayTotalTokens: 0,
    totalRequests: 0,
    totalInputTokens: 0,
    totalOutputTokens: 0,
    totalTokens: 0,
    lastProviderLabel: null,
    lastModel: null,
    lastUsedAt: null,
    lastCallTokens: 0,
    standard: createDefaultCloudAIUsageBucket(dayKey),
    jev: createDefaultCloudAIUsageBucket(dayKey),
  };
}

// MARK: - Analysis & Enrichment

export interface LocalAnalysisResult {
  dominantColors: LabColor[];
  ocrText?: string | null;
  /** Base64-encoded feature print bytes (if available). */
  featurePrintData?: string | null;
}

export interface CloudEnrichmentResult {
  description?: string | null;
  suggestedTags: string[];
  embedding?: number[] | null;
}

// MARK: - Experimental TypeSafe System One (Jev) Visual Grounding

export interface TypeSafeExperimentalConfig {
  enabled: boolean;
  baseURL: string;
  model: string;
  minConfidence: number;
  lowConfidencePadding: number;
  minPresenceProbability: number;
  enableMoodboardFocusCrop: boolean;
  enableAutoCleanCrop: boolean;
  enableSubjectPalette: boolean;
  enablePinpointAnnotations: boolean;
  enableSemanticSearch: boolean;
  enableInboxSmartTriage: boolean;
  enableCuratorVisualRerank: boolean;
}

export function createDefaultTypeSafeExperimentalConfig(
  overrides: Partial<TypeSafeExperimentalConfig> = {},
): TypeSafeExperimentalConfig {
  return {
    enabled: false,
    baseURL: 'https://api.typesafe.ai',
    model: 'jev-latest',
    minConfidence: 0.6,
    lowConfidencePadding: 0.05,
    minPresenceProbability: 0.45,
    enableMoodboardFocusCrop: true,
    enableAutoCleanCrop: true,
    enableSubjectPalette: true,
    enablePinpointAnnotations: true,
    enableSemanticSearch: true,
    enableInboxSmartTriage: true,
    enableCuratorVisualRerank: true,
    ...overrides,
  };
}

export interface TypeSafeModelInfo {
  name: string;
  description: string;
  releaseDate: string;
}

export type VisualRegionSource = 'typeSafeJev' | 'appleVisionSaliency';

export function visualRegionSourceLocalizedLabel(source: VisualRegionSource): string {
  switch (source) {
    case 'typeSafeJev':
      return 'TypeSafe Jev Box';
    case 'appleVisionSaliency':
      return '本机 Vision 主体识别';
  }
}

export interface VisualRegionResult {
  crop: NormalizedCropRect;
  rawBox: NormalizedCropRect;
  presenceProbability: number;
  confidence?: number | null;
  didApplyPadding: boolean;
  found: boolean;
  source: VisualRegionSource;
  model?: string | null;
  summary: string;
}

export interface CleanBoundsResult {
  hasNoise: boolean;
  noiseProbability: number;
  recommendedCrop?: NormalizedCropRect | null;
  confidence?: number | null;
  didApplyPadding: boolean;
  source: VisualRegionSource;
  model?: string | null;
  summary: string;
}

export interface SubjectPaletteResult {
  colors: LabColor[];
  subjectRegion: VisualRegionResult;
  updatedAsset: AssetRecord;
}

// MARK: - Hybrid Semantic Search & Inbox Smart Triage

export interface SemanticSearchHit {
  asset: AssetRecord;
  /** Combined calibrated relevance in `[0, 1]`. */
  score: number;
  confidence?: number | null;
  reason: string;
  sourceLabel: string;
}

export interface SemanticSearchReport {
  query: string;
  hits: SemanticSearchHit[];
  usedTypeSafeJev: boolean;
  usedCloudEmbedding: boolean;
  evaluatedVisualCount: number;
  summary: string;
}

export interface InboxTriageRecommendation {
  assetID: UUID;
  assetTitle: string;
  recommendedFolderID?: UUID | null;
  recommendedFolderName?: string | null;
  confidence: number;
  fitProbability: number;
  reason: string;
  source: VisualRegionSource;
}
