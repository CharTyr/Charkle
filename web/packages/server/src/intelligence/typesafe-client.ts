import {
  cropFromBoxEdges,
  type NormalizedCropRect,
  type TypeSafeModelInfo,
} from '@charkle/shared';
import type { IImageProcessor } from '../runtime/types.js';
import { randomUUID, toBuffer } from '../runtime/web-crypto-utils.js';
import { inspectImageHeader } from '../runtime/workers-image.js';
import { SECRET_KEYS } from '../storage/secret-vault.js';
import type { FetchLike } from './cloud-ai-provider.js';
import type { CloudAIUsageTracker } from './cloud-ai-usage-tracker.js';

export const TYPESAFE_DANGER_ZONE_IMAGES_HEADER = 'TypeSafe-Danger-Zone-Images';
export const TYPESAFE_SECRET_KEY = SECRET_KEYS.TYPESAFE_API_KEY;

export interface TypeSafeBoxCoordinates {
  top: number;
  bottom: number;
  left: number;
  right: number;
}

export function boxCoordinatesToNormalizedCrop(coords: TypeSafeBoxCoordinates): NormalizedCropRect {
  return cropFromBoxEdges(coords.top, coords.bottom, coords.left, coords.right);
}

export interface TypeSafeImageAttachment {
  referenceKey: string;
  partName: string;
  format: 'jpg' | 'png';
  data: Buffer;
}

export function createTypeSafeImageAttachment(opts: {
  referenceKey?: string;
  partName?: string;
  format?: string;
  data: Buffer;
}): TypeSafeImageAttachment {
  return {
    referenceKey: opts.referenceKey ?? `img-${randomUUID().toLowerCase()}`,
    partName: opts.partName ?? `image-${randomUUID().slice(0, 8).toLowerCase()}`,
    format: opts.format?.toLowerCase() === 'png' ? 'png' : 'jpg',
    data: opts.data,
  };
}

export type TypeSafeQuestion =
  | {
      type: 'noul';
      instructions: string;
      trueCriteria?: string;
      falseCriteria?: string;
    }
  | {
      type: 'box';
      instructions: string;
    }
  | {
      type: 'choice';
      instructions: string;
      criteria: Record<string, string>;
    }
  | {
      type: 'score';
      instructions: string;
      criteria: string[];
    };

export type TypeSafeAnswer =
  | { type: 'noul'; probability: number }
  | { type: 'box'; box: TypeSafeBoxCoordinates; confidence: number | null }
  | {
      type: 'choice';
      choice: string;
      confidence: number | null;
      probabilities: Record<string, number>;
    }
  | {
      type: 'score';
      score: number;
      confidence: number | null;
      probabilities: Record<string, number>;
      legend: Record<string, string>;
    };

export interface TypeSafeUsage {
  inputTokens: number;
  outputTokens: number;
}

export interface TypeSafeSystemOneResponse {
  model: string;
  answers: Record<string, TypeSafeAnswer>;
  usage: TypeSafeUsage | null;
}

export class TypeSafeError extends Error {
  readonly status?: number;

  constructor(message: string, status?: number) {
    super(message);
    this.name = 'TypeSafeError';
    this.status = status;
  }
}

function questionToWireObject(question: TypeSafeQuestion): Record<string, unknown> {
  switch (question.type) {
    case 'noul': {
      const obj: Record<string, unknown> = {
        type: 'noul',
        instructions: question.instructions,
      };
      if (question.trueCriteria !== undefined || question.falseCriteria !== undefined) {
        const crit: Record<string, string> = {};
        if (question.trueCriteria !== undefined) crit.true = question.trueCriteria;
        if (question.falseCriteria !== undefined) crit.false = question.falseCriteria;
        obj.criteria = crit;
      }
      return obj;
    }
    case 'box':
      return {
        type: 'box',
        instructions: question.instructions,
      };
    case 'choice':
      return {
        type: 'choice',
        instructions: question.instructions,
        criteria: question.criteria,
      };
    case 'score':
      return {
        type: 'score',
        instructions: question.instructions,
        criteria: question.criteria,
      };
  }
}

function parseWireAnswer(raw: unknown): TypeSafeAnswer {
  if (!raw || typeof raw !== 'object') {
    throw new TypeSafeError('TypeSafe 响应中的答案结构无效。');
  }
  const obj = raw as Record<string, unknown>;
  const kind = obj.type;
  switch (kind) {
    case 'noul': {
      const prob = typeof obj.noul === 'number' ? obj.noul : typeof obj.probability === 'number' ? obj.probability : NaN;
      if (!Number.isFinite(prob)) {
        throw new TypeSafeError('TypeSafe noul 答案缺少有效概率值。');
      }
      return { type: 'noul', probability: prob };
    }
    case 'box': {
      const b = obj.box as Record<string, unknown> | undefined;
      if (
        !b ||
        typeof b.top !== 'number' ||
        typeof b.bottom !== 'number' ||
        typeof b.left !== 'number' ||
        typeof b.right !== 'number'
      ) {
        throw new TypeSafeError('TypeSafe box 答案缺少有效坐标。');
      }
      return {
        type: 'box',
        box: { top: b.top, bottom: b.bottom, left: b.left, right: b.right },
        confidence: typeof obj.confidence === 'number' && Number.isFinite(obj.confidence) ? obj.confidence : null,
      };
    }
    case 'choice': {
      if (typeof obj.choice !== 'string') {
        throw new TypeSafeError('TypeSafe choice 答案缺少有效选项。');
      }
      const probs: Record<string, number> = {};
      if (obj.probabilities && typeof obj.probabilities === 'object') {
        for (const [k, v] of Object.entries(obj.probabilities as Record<string, unknown>)) {
          if (typeof v === 'number' && Number.isFinite(v)) probs[k] = v;
        }
      }
      return {
        type: 'choice',
        choice: obj.choice,
        confidence: typeof obj.confidence === 'number' && Number.isFinite(obj.confidence) ? obj.confidence : null,
        probabilities: probs,
      };
    }
    case 'score': {
      if (typeof obj.score !== 'number' || !Number.isFinite(obj.score)) {
        throw new TypeSafeError('TypeSafe score 答案缺少有效分数。');
      }
      const probs: Record<string, number> = {};
      if (obj.probabilities && typeof obj.probabilities === 'object') {
        for (const [k, v] of Object.entries(obj.probabilities as Record<string, unknown>)) {
          if (typeof v === 'number' && Number.isFinite(v)) probs[k] = v;
        }
      }
      const legend: Record<string, string> = {};
      if (obj.legend && typeof obj.legend === 'object') {
        for (const [k, v] of Object.entries(obj.legend as Record<string, unknown>)) {
          if (typeof v === 'string') legend[k] = v;
        }
      }
      return {
        type: 'score',
        score: obj.score,
        confidence: typeof obj.confidence === 'number' && Number.isFinite(obj.confidence) ? obj.confidence : null,
        probabilities: probs,
        legend,
      };
    }
    default:
      throw new TypeSafeError(`Unsupported TypeSafe answer type: ${String(kind)}`);
  }
}

const LOCAL_HOSTS = new Set(['localhost', '127.0.0.1', '::1', '[::1]']);

/**
 * Ensures every image sent to TypeSafe strictly obeys `280 <= width, height <= 1568`
 * and upright EXIF-normalized JPEG encoding (padding extreme aspect ratios onto `#F5F5F5`).
 * Delegates raster resizing/padding to the runtime's `IImageProcessor` (zero `sharp` import here).
 */
export const TypeSafeImagePreparer = {
  minSide: 280,
  maxSide: 1568,

  async prepareJPEG(
    input: Buffer | Uint8Array,
    targetLongSide = 768,
    quality = 0.86,
    images?: IImageProcessor | null,
  ): Promise<{ data: Buffer; width: number; height: number } | null> {
    try {
      const bytes = input instanceof Uint8Array ? input : new Uint8Array(input);
      if (images?.cropAndPad) {
        const res = await images.cropAndPad(bytes, {
          targetLongSide,
          minSide: this.minSide,
          maxSide: this.maxSide,
          quality,
        });
        if (res) {
          return {
            data: toBuffer(res.data),
            width: res.width,
            height: res.height,
          };
        }
      }
      const header = inspectImageHeader(bytes);
      if (!header) return null;
      return {
        data: toBuffer(bytes),
        width: header.width,
        height: header.height,
      };
    } catch {
      return null;
    }
  },
};

export interface TypeSafeClientOptions {
  baseURL?: string;
  apiKey: string;
  usage?: CloudAIUsageTracker | null;
  fetchFn?: FetchLike;
}

export class TypeSafeSystemOneClient {
  readonly baseURL: URL;
  private readonly apiKey: string;
  private readonly usage: CloudAIUsageTracker | null;
  private readonly fetchFn: FetchLike;

  constructor(opts: TypeSafeClientOptions) {
    const trimmedBase = (opts.baseURL ?? '').trim() || 'https://api.typesafe.ai';
    let url: URL;
    try {
      url = new URL(trimmedBase);
    } catch {
      throw new TypeSafeError('无效的 TypeSafe 服务地址，远程接口请使用 HTTPS。');
    }
    const host = url.hostname.toLowerCase();
    const validScheme = url.protocol === 'https:' || (url.protocol === 'http:' && LOCAL_HOSTS.has(host));
    if (!host || url.username || url.password || url.search || url.hash || !validScheme) {
      throw new TypeSafeError('无效的 TypeSafe 服务地址，远程接口请使用 HTTPS。');
    }

    const cleanedKey = opts.apiKey.trim();
    if (!cleanedKey) {
      throw new TypeSafeError('请先在「设置 → 智能与搜索」中填写 TypeSafe API 密钥。');
    }

    if (!url.pathname || url.pathname === '/') {
      url.pathname = '/v1';
    }
    this.baseURL = url;
    this.apiKey = cleanedKey;
    this.usage = opts.usage ?? null;
    this.fetchFn = opts.fetchFn ?? globalThis.fetch;
  }

  private endpoint(path: string): string {
    const baseStr = this.baseURL.toString().replace(/\/+$/, '');
    const rel = path.replace(/^\/+/, '');
    return `${baseStr}/${rel}`;
  }

  async listModels(timeoutMs = 20_000, externalSignal?: AbortSignal): Promise<TypeSafeModelInfo[]> {
    const controller = new AbortController();
    const onExternalAbort = () => controller.abort(externalSignal?.reason);
    if (externalSignal) {
      if (externalSignal.aborted) controller.abort(externalSignal.reason);
      else externalSignal.addEventListener('abort', onExternalAbort, { once: true });
    }
    const timer = setTimeout(() => controller.abort(), timeoutMs);
    try {
      const res = await this.fetchFn(this.endpoint('models'), {
        method: 'GET',
        headers: {
          Authorization: `Bearer ${this.apiKey}`,
          Accept: 'application/json',
        },
        signal: controller.signal,
      });
      await this.validateResponse(res);
      const payload = (await res.json()) as {
        models?: Array<{
          name?: string;
          alias?: string | null;
          description?: string;
          release_date?: string;
          releaseDate?: string;
        }>;
      };
      if (!Array.isArray(payload.models)) return [];
      return payload.models
        .filter((m) => typeof m?.name === 'string' && m.name.trim().length > 0)
        .map((m) => ({
          name: m.name!.trim(),
          alias: m.alias ?? null,
          description: typeof m.description === 'string' ? m.description : '',
          releaseDate:
            typeof m.releaseDate === 'string' && m.releaseDate
              ? m.releaseDate
              : typeof m.release_date === 'string'
                ? m.release_date
                : '',
        }));
    } finally {
      clearTimeout(timer);
      if (externalSignal) externalSignal.removeEventListener('abort', onExternalAbort);
    }
  }

  /**
   * Executes a TypeSafe System One request with typed questions (`noul`, `box`, `choice`, `score`).
   * Uses `multipart/form-data` with Part 1 = `name="request"` JSON whenever images are supplied,
   * and sends `TypeSafe-Danger-Zone-Images: true` whenever images or `box` questions are present.
   */
  async systemOne(params: {
    model: string;
    state: Record<string, unknown>;
    questions: Record<string, TypeSafeQuestion>;
    images?: TypeSafeImageAttachment[];
    timeoutMs?: number;
    signal?: AbortSignal;
  }): Promise<TypeSafeSystemOneResponse> {
    const questionEntries = Object.entries(params.questions);
    if (questionEntries.length === 0) {
      throw new TypeSafeError('TypeSafe System One 请求至少需要一个问题。');
    }

    const resolvedModel = params.model.trim() || 'jev-latest';
    const images = params.images ?? [];
    const wireQuestions: Record<string, unknown> = {};
    let hasBoxQuestion = false;
    for (const [key, q] of questionEntries) {
      wireQuestions[key] = questionToWireObject(q);
      if (q.type === 'box') hasBoxQuestion = true;
    }

    const requestPayload: Record<string, unknown> = {
      model: resolvedModel,
      state: params.state,
      questions: wireQuestions,
    };

    const needsImagesHeader = images.length > 0 || hasBoxQuestion;
    const headers: Record<string, string> = {
      Authorization: `Bearer ${this.apiKey}`,
      Accept: 'application/json',
    };
    if (needsImagesHeader) {
      headers[TYPESAFE_DANGER_ZONE_IMAGES_HEADER] = 'true';
    }

    let body: Buffer | string;
    if (images.length === 0) {
      headers['Content-Type'] = 'application/json';
      body = JSON.stringify(requestPayload);
    } else {
      const assetsMap: Record<string, { type: 'image'; part: string }> = {};
      for (const img of images) {
        assetsMap[img.referenceKey] = { type: 'image', part: img.partName };
      }
      requestPayload.assets = assetsMap;

      const jsonBytes = Buffer.from(JSON.stringify(requestPayload), 'utf8');
      const boundary = `CharkleTypeSafe-${randomUUID().replace(/-/g, '')}`;
      headers['Content-Type'] = `multipart/form-data; boundary=${boundary}`;
      body = TypeSafeSystemOneClient.buildMultipartBody(boundary, jsonBytes, images);
    }

    const controller = new AbortController();
    const externalSignal = params.signal;
    const onExternalAbort = () => controller.abort(externalSignal?.reason);
    if (externalSignal) {
      if (externalSignal.aborted) controller.abort(externalSignal.reason);
      else externalSignal.addEventListener('abort', onExternalAbort, { once: true });
    }
    const timer = setTimeout(() => controller.abort(), params.timeoutMs ?? 45_000);
    try {
      const res = await this.fetchFn(this.endpoint('systemone'), {
        method: 'POST',
        headers,
        body: typeof body === 'string' ? body : new Uint8Array(body),
        signal: controller.signal,
      });
      await this.validateResponse(res);
      const raw = (await res.json()) as {
        model?: string;
        answers?: Record<string, unknown>;
        usage?: { input_tokens?: number; output_tokens?: number };
      };

      const parsedAnswers: Record<string, TypeSafeAnswer> = {};
      for (const [key, value] of Object.entries(raw.answers ?? {})) {
        parsedAnswers[key] = parseWireAnswer(value);
      }

      const usage: TypeSafeUsage | null = raw.usage
        ? {
            inputTokens: Math.max(0, Math.trunc(raw.usage.input_tokens ?? 0)),
            outputTokens: Math.max(0, Math.trunc(raw.usage.output_tokens ?? 0)),
          }
        : null;

      const responseModel = (raw.model ?? '').trim() || resolvedModel;
      await this.usage?.record({
        category: 'jev',
        providerLabel: 'TypeSafe (Jev)',
        model: responseModel,
        inputTokens: usage?.inputTokens ?? 0,
        outputTokens: usage?.outputTokens ?? 0,
      });

      return {
        model: responseModel,
        answers: parsedAnswers,
        usage,
      };
    } finally {
      clearTimeout(timer);
      if (externalSignal) externalSignal.removeEventListener('abort', onExternalAbort);
    }
  }

  static buildMultipartBody(
    boundary: string,
    requestJSON: Buffer,
    images: TypeSafeImageAttachment[],
  ): Buffer {
    const chunks: Buffer[] = [];
    const pushStr = (s: string) => chunks.push(Buffer.from(s, 'utf8'));

    // Rule: first part MUST be named "request" with Content-Type: application/json
    pushStr(`--${boundary}\r\n`);
    pushStr('Content-Disposition: form-data; name="request"\r\n');
    pushStr('Content-Type: application/json\r\n\r\n');
    chunks.push(requestJSON);
    pushStr('\r\n');

    for (const image of images) {
      const mime = image.format === 'png' ? 'image/png' : 'image/jpeg';
      pushStr(`--${boundary}\r\n`);
      pushStr(
        `Content-Disposition: form-data; name="${image.partName}"; filename="${image.partName}.${image.format}"\r\n`,
      );
      pushStr(`Content-Type: ${mime}\r\n\r\n`);
      chunks.push(image.data);
      pushStr('\r\n');
    }

    pushStr(`--${boundary}--\r\n`);
    return Buffer.concat(chunks);
  }

  private async validateResponse(res: Response): Promise<void> {
    if (res.ok) return;
    const text = await res.text().catch(() => '');
    const detail = extractTypeSafeErrorDetail(text);
    if (res.status === 401 || res.status === 403) {
      throw new TypeSafeError(
        `TypeSafe API 密钥无效或无权限（HTTP ${res.status}）。${detail ? ` ${detail}` : ''}`,
        res.status,
      );
    }
    if (res.status === 429) {
      throw new TypeSafeError('TypeSafe 请求频率超限（HTTP 429），请稍后重试。', 429);
    }
    throw new TypeSafeError(
      `TypeSafe 返回错误 HTTP ${res.status}${detail ? `：${detail}` : ''}`,
      res.status,
    );
  }
}

function extractTypeSafeErrorDetail(rawText: string): string | null {
  const trimmed = rawText.trim();
  if (!trimmed) return null;
  try {
    const json = JSON.parse(trimmed) as Record<string, unknown>;
    if (typeof json.detail === 'string' && json.detail) return json.detail;
    if (Array.isArray(json.detail)) {
      const parts = json.detail
        .map((item) => {
          if (!item || typeof item !== 'object') return null;
          const rec = item as Record<string, unknown>;
          const msg = typeof rec.msg === 'string' ? rec.msg : null;
          const loc = Array.isArray(rec.loc) ? rec.loc.map(String).join('.') : null;
          return loc && msg ? `${loc}: ${msg}` : msg;
        })
        .filter((s): s is string => Boolean(s));
      if (parts.length > 0) return parts.join('; ');
    }
    if (typeof json.message === 'string' && json.message) return json.message;
    if (typeof json.error === 'string' && json.error) return json.error;
    if (json.error && typeof json.error === 'object') {
      const msg = (json.error as Record<string, unknown>).message;
      if (typeof msg === 'string' && msg) return msg;
    }
  } catch {
    return trimmed.slice(0, 240);
  }
  return null;
}
