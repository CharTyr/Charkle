import {
  type CloudAIUsageBucket,
  type CloudAIUsageCategory,
  type CloudAIUsageSummary,
  createDefaultCloudAIUsageBucket,
  createDefaultCloudAIUsageSummary,
  formatTokenCount,
  localDayKey,
} from '@charkle/shared';

export interface UsageModelBreakdown {
  requests: number;
  inputTokens: number;
  outputTokens: number;
  totalTokens: number;
  estimatedCostUSD: number;
}

export interface ExtendedCloudAIUsageBucket extends CloudAIUsageBucket {
  estimatedCostUSD: number;
  byModel: Record<string, UsageModelBreakdown>;
}

export interface ExtendedCloudAIUsageSummary extends CloudAIUsageSummary {
  estimatedCostUSD: number;
  standard: ExtendedCloudAIUsageBucket;
  jev: ExtendedCloudAIUsageBucket;
}

export interface UsageStateStore {
  getState<T>(key: string): T | null | Promise<T | null>;
  setState(key: string, value: unknown): void | Promise<void>;
}

export interface RecordUsageInput {
  category?: CloudAIUsageCategory;
  providerLabel: string;
  model: string;
  inputTokens?: number;
  outputTokens?: number;
  totalTokens?: number | null;
  now?: Date;
}

/**
 * Rough USD per 1M token pricing estimates for local spend visibility.
 * Never gates calls; purely informational telemetry.
 */
const MODEL_PRICING_PER_MILLION: Array<{ match: RegExp; input: number; output: number }> = [
  { match: /^gemini-2\.5-pro/i, input: 1.25, output: 10.0 },
  { match: /^gemini-2\.5-flash/i, input: 0.15, output: 0.6 },
  { match: /^gemini-2\.0-flash/i, input: 0.1, output: 0.4 },
  { match: /^gemini-embedding/i, input: 0.15, output: 0 },
  { match: /^gpt-4\.1-mini/i, input: 0.4, output: 1.6 },
  { match: /^gpt-4\.1-nano/i, input: 0.1, output: 0.4 },
  { match: /^gpt-4\.1/i, input: 2.0, output: 8.0 },
  { match: /^gpt-4o-mini/i, input: 0.15, output: 0.6 },
  { match: /^gpt-4o/i, input: 2.5, output: 10.0 },
  { match: /^gpt-5(?:\.\d+)?-mini/i, input: 0.25, output: 2.0 },
  { match: /^gpt-5(?:\.\d+)?-nano/i, input: 0.05, output: 0.4 },
  { match: /^gpt-5/i, input: 1.25, output: 10.0 },
  { match: /^claude-sonnet/i, input: 3.0, output: 15.0 },
  { match: /^claude-haiku/i, input: 0.8, output: 4.0 },
  { match: /^claude-opus/i, input: 15.0, output: 75.0 },
  { match: /^text-embedding-3-small/i, input: 0.02, output: 0 },
  { match: /^text-embedding-3-large/i, input: 0.13, output: 0 },
  { match: /^jev/i, input: 0.5, output: 1.5 },
];

export function estimateCostUSD(model: string, inputTokens: number, outputTokens: number): number {
  const cleaned = model.trim();
  const rate = MODEL_PRICING_PER_MILLION.find((entry) => entry.match.test(cleaned)) ?? {
    input: 0.5,
    output: 1.5,
  };
  const cost = (Math.max(0, inputTokens) * rate.input + Math.max(0, outputTokens) * rate.output) / 1_000_000;
  return Math.round(cost * 1_000_000) / 1_000_000;
}

function createExtendedBucket(dayKey: string = localDayKey()): ExtendedCloudAIUsageBucket {
  return {
    ...createDefaultCloudAIUsageBucket(dayKey),
    estimatedCostUSD: 0,
    byModel: {},
  };
}

function createExtendedSummary(dayKey: string = localDayKey()): ExtendedCloudAIUsageSummary {
  return {
    ...createDefaultCloudAIUsageSummary(dayKey),
    estimatedCostUSD: 0,
    standard: createExtendedBucket(dayKey),
    jev: createExtendedBucket(dayKey),
  };
}

function looksLikeJev(providerLabel?: string | null, model?: string | null): boolean {
  const p = (providerLabel ?? '').toLowerCase();
  const m = (model ?? '').toLowerCase();
  return p.includes('typesafe') || p.includes('jev') || m.startsWith('jev');
}

function normalizeBucket(raw: Partial<ExtendedCloudAIUsageBucket> | null | undefined, fallbackDayKey: string): ExtendedCloudAIUsageBucket {
  const base = createExtendedBucket(raw?.dayKey || fallbackDayKey);
  if (!raw) return base;
  return {
    ...base,
    dayKey: raw.dayKey || fallbackDayKey,
    todayRequests: Math.max(0, Math.trunc(raw.todayRequests ?? 0)),
    todayInputTokens: Math.max(0, Math.trunc(raw.todayInputTokens ?? 0)),
    todayOutputTokens: Math.max(0, Math.trunc(raw.todayOutputTokens ?? 0)),
    todayTotalTokens: Math.max(0, Math.trunc(raw.todayTotalTokens ?? 0)),
    totalRequests: Math.max(0, Math.trunc(raw.totalRequests ?? 0)),
    totalInputTokens: Math.max(0, Math.trunc(raw.totalInputTokens ?? 0)),
    totalOutputTokens: Math.max(0, Math.trunc(raw.totalOutputTokens ?? 0)),
    totalTokens: Math.max(0, Math.trunc(raw.totalTokens ?? 0)),
    lastProviderLabel: raw.lastProviderLabel ?? null,
    lastModel: raw.lastModel ?? null,
    lastUsedAt: raw.lastUsedAt ?? null,
    lastCallTokens: Math.max(0, Math.trunc(raw.lastCallTokens ?? 0)),
    estimatedCostUSD: typeof raw.estimatedCostUSD === 'number' && Number.isFinite(raw.estimatedCostUSD)
      ? Math.max(0, raw.estimatedCostUSD)
      : 0,
    byModel: raw.byModel && typeof raw.byModel === 'object' ? { ...raw.byModel } : {},
  };
}

function rolloverBucket(bucket: ExtendedCloudAIUsageBucket, currentKey: string): boolean {
  if (bucket.dayKey === currentKey) return false;
  bucket.dayKey = currentKey;
  bucket.todayRequests = 0;
  bucket.todayInputTokens = 0;
  bucket.todayOutputTokens = 0;
  bucket.todayTotalTokens = 0;
  return true;
}

function synchronizeAggregates(summary: ExtendedCloudAIUsageSummary): void {
  const { standard, jev } = summary;
  summary.todayRequests = standard.todayRequests + jev.todayRequests;
  summary.todayInputTokens = standard.todayInputTokens + jev.todayInputTokens;
  summary.todayOutputTokens = standard.todayOutputTokens + jev.todayOutputTokens;
  summary.todayTotalTokens = standard.todayTotalTokens + jev.todayTotalTokens;
  summary.totalRequests = standard.totalRequests + jev.totalRequests;
  summary.totalInputTokens = standard.totalInputTokens + jev.totalInputTokens;
  summary.totalOutputTokens = standard.totalOutputTokens + jev.totalOutputTokens;
  summary.totalTokens = standard.totalTokens + jev.totalTokens;
  summary.estimatedCostUSD = Math.round((standard.estimatedCostUSD + jev.estimatedCostUSD) * 1_000_000) / 1_000_000;

  const sTime = standard.lastUsedAt ? Date.parse(standard.lastUsedAt) : Number.NEGATIVE_INFINITY;
  const jTime = jev.lastUsedAt ? Date.parse(jev.lastUsedAt) : Number.NEGATIVE_INFINITY;
  if (Number.isFinite(sTime) && Number.isFinite(jTime)) {
    const latest = jTime >= sTime ? jev : standard;
    summary.lastProviderLabel = latest.lastProviderLabel ?? null;
    summary.lastModel = latest.lastModel ?? null;
    summary.lastUsedAt = latest.lastUsedAt ?? null;
    summary.lastCallTokens = latest.lastCallTokens;
  } else if (Number.isFinite(sTime)) {
    summary.lastProviderLabel = standard.lastProviderLabel ?? null;
    summary.lastModel = standard.lastModel ?? null;
    summary.lastUsedAt = standard.lastUsedAt ?? null;
    summary.lastCallTokens = standard.lastCallTokens;
  } else if (Number.isFinite(jTime)) {
    summary.lastProviderLabel = jev.lastProviderLabel ?? null;
    summary.lastModel = jev.lastModel ?? null;
    summary.lastUsedAt = jev.lastUsedAt ?? null;
    summary.lastCallTokens = jev.lastCallTokens;
  } else {
    summary.lastProviderLabel = null;
    summary.lastModel = null;
    summary.lastUsedAt = null;
    summary.lastCallTokens = 0;
  }
}

export const CLOUD_AI_USAGE_STATE_KEY = 'cloudAI.usageSummary.v1';

/**
 * Separated Cloud AI usage tracker (`standard` vs `jev`) persisted in `sync_state`.
 * Mirrors macOS `CloudAIUsageStore` with daily rollover, per-bucket reset,
 * per-model breakdown, and informational USD cost estimates.
 */
export class CloudAIUsageTracker {
  private readonly store: UsageStateStore | null;
  private readonly stateKey: string;
  private cached: ExtendedCloudAIUsageSummary;
  private loaded = false;
  private loadPromise: Promise<void> | null = null;

  constructor(store?: UsageStateStore | null, stateKey: string = CLOUD_AI_USAGE_STATE_KEY) {
    this.store = store ?? null;
    this.stateKey = stateKey;
    this.cached = createExtendedSummary();
  }

  private async ensureLoaded(now: Date): Promise<void> {
    if (this.loaded) return;
    if (!this.store) {
      this.loaded = true;
      return;
    }
    if (!this.loadPromise) {
      this.loadPromise = (async () => {
        const raw = await this.store!.getState<Partial<ExtendedCloudAIUsageSummary>>(this.stateKey);
        if (raw && typeof raw === 'object') {
          const dayKey = raw.dayKey || localDayKey(now);
          if (raw.standard || raw.jev) {
            const summary = createExtendedSummary(dayKey);
            summary.standard = normalizeBucket(raw.standard, dayKey);
            summary.jev = normalizeBucket(raw.jev, dayKey);
            synchronizeAggregates(summary);
            this.cached = summary;
          } else {
            // Legacy flat summary migration
            const legacy = normalizeBucket(
              raw as unknown as Partial<ExtendedCloudAIUsageBucket>,
              dayKey,
            );
            const summary = createExtendedSummary(dayKey);
            if (looksLikeJev(legacy.lastProviderLabel, legacy.lastModel)) {
              summary.jev = legacy;
            } else {
              summary.standard = legacy;
            }
            synchronizeAggregates(summary);
            this.cached = summary;
          }
        }
        this.loaded = true;
      })().finally(() => {
        this.loadPromise = null;
      });
    }
    await this.loadPromise;
  }

  private async persist(): Promise<void> {
    if (!this.store) return;
    await this.store.setState(this.stateKey, this.cached);
  }

  private cloneSummary(): ExtendedCloudAIUsageSummary {
    return {
      ...this.cached,
      standard: {
        ...this.cached.standard,
        byModel: Object.fromEntries(
          Object.entries(this.cached.standard.byModel).map(([k, v]) => [k, { ...v }]),
        ),
      },
      jev: {
        ...this.cached.jev,
        byModel: Object.fromEntries(
          Object.entries(this.cached.jev.byModel).map(([k, v]) => [k, { ...v }]),
        ),
      },
    };
  }

  async snapshot(now: Date = new Date()): Promise<ExtendedCloudAIUsageSummary> {
    await this.ensureLoaded(now);
    const currentKey = localDayKey(now);
    const standardRolled = rolloverBucket(this.cached.standard, currentKey);
    const jevRolled = rolloverBucket(this.cached.jev, currentKey);
    const changed = this.cached.dayKey !== currentKey || standardRolled || jevRolled;
    if (changed) {
      this.cached.dayKey = currentKey;
      synchronizeAggregates(this.cached);
      await this.persist();
    }
    return this.cloneSummary();
  }

  async record(input: RecordUsageInput): Promise<ExtendedCloudAIUsageSummary> {
    const now = input.now ?? new Date();
    await this.ensureLoaded(now);

    const category: CloudAIUsageCategory = input.category ?? 'standard';
    const currentKey = localDayKey(now);
    this.cached.dayKey = currentKey;
    rolloverBucket(this.cached.standard, currentKey);
    rolloverBucket(this.cached.jev, currentKey);

    const safeIn = Math.max(0, Math.trunc(input.inputTokens ?? 0));
    const safeOut = Math.max(0, Math.trunc(input.outputTokens ?? 0));
    const resolvedTotal = Math.max(safeIn + safeOut, Math.max(0, Math.trunc(input.totalTokens ?? 0)));
    const modelName = input.model.trim();
    const callCost = estimateCostUSD(modelName || input.providerLabel, safeIn, safeOut);

    const bucket = category === 'jev' ? this.cached.jev : this.cached.standard;
    bucket.todayRequests += 1;
    bucket.todayInputTokens += safeIn;
    bucket.todayOutputTokens += safeOut;
    bucket.todayTotalTokens += resolvedTotal;
    bucket.totalRequests += 1;
    bucket.totalInputTokens += safeIn;
    bucket.totalOutputTokens += safeOut;
    bucket.totalTokens += resolvedTotal;
    bucket.lastProviderLabel = input.providerLabel;
    if (modelName) {
      bucket.lastModel = modelName;
    }
    bucket.lastUsedAt = now.toISOString();
    bucket.lastCallTokens = resolvedTotal;
    bucket.estimatedCostUSD = Math.round((bucket.estimatedCostUSD + callCost) * 1_000_000) / 1_000_000;

    const modelKey = modelName || 'unknown';
    const existingModel = bucket.byModel[modelKey] ?? {
      requests: 0,
      inputTokens: 0,
      outputTokens: 0,
      totalTokens: 0,
      estimatedCostUSD: 0,
    };
    bucket.byModel[modelKey] = {
      requests: existingModel.requests + 1,
      inputTokens: existingModel.inputTokens + safeIn,
      outputTokens: existingModel.outputTokens + safeOut,
      totalTokens: existingModel.totalTokens + resolvedTotal,
      estimatedCostUSD: Math.round((existingModel.estimatedCostUSD + callCost) * 1_000_000) / 1_000_000,
    };

    synchronizeAggregates(this.cached);
    await this.persist();
    return this.cloneSummary();
  }

  async reset(category: CloudAIUsageCategory | null = null, now: Date = new Date()): Promise<ExtendedCloudAIUsageSummary> {
    await this.ensureLoaded(now);
    const currentKey = localDayKey(now);
    if (category === null) {
      this.cached = createExtendedSummary(currentKey);
    } else if (category === 'standard') {
      this.cached.dayKey = currentKey;
      rolloverBucket(this.cached.jev, currentKey);
      this.cached.standard = createExtendedBucket(currentKey);
      synchronizeAggregates(this.cached);
    } else {
      this.cached.dayKey = currentKey;
      rolloverBucket(this.cached.standard, currentKey);
      this.cached.jev = createExtendedBucket(currentKey);
      synchronizeAggregates(this.cached);
    }
    await this.persist();
    return this.cloneSummary();
  }

  static formatTokenCount = formatTokenCount;
}
