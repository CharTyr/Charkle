import type {
  AIConfigResponse,
  AIProviderConfig,
  AnalyzeAssetsRequest,
  AnalyzeAssetsResponse,
  ApiTokensResponse,
  AssetDetailResponse,
  AssetsListResponse,
  AssetsQueryRequest,
  AuthChangePasswordRequest,
  AuthLoginRequest,
  AuthLoginResponse,
  AuthSessionsResponse,
  AuthSetupRequest,
  AuthStatus,
  BatchPatchAssetsRequest,
  BatchPatchAssetsResponse,
  BatchTriageInboxRequest,
  BatchTriageInboxResponse,
  BoardDetailResponse,
  BoardsListResponse,
  CacheStatsResponse,
  CaptureInput,
  ChatGPTAccountSession,
  ChatGPTModelsResponse,
  CleanBoundsResponse,
  ClientPreprocessedMedia,
  CreateApiTokenRequest,
  CreateApiTokenResponse,
  CreateBoardRequest,
  CreateFolderRequest,
  CurateMoodboardRequest,
  DeleteFolderRequest,
  ExportMoodboardRequest,
  ExternalAgentConfigResponse,
  ExternalAgentDiagnosticsResponse,
  ExtractPaletteRequest,
  ExtractPaletteResponse,
  ExtractSocialMediaRequest,
  ExtractSubjectPaletteRequest,
  ExtractSubjectPaletteResponse,
  FigmaBridgeReport,
  FolderResponse,
  FoldersResponse,
  FolderSuggestionResponse,
  GoogleOAuthStartResponse,
  HealthResponse,
  IngestRequest,
  IngestResponse,
  LibraryBootstrapResponse,
  LocateVisualMatchRequest,
  LocateVisualRegionRequest,
  LocateVisualRegionResponse,
  MigrateStorageRequest,
  MigrateStorageResponse,
  MultipartUploadCompleteRequest,
  MultipartUploadCompleteResponse,
  MultipartUploadInitRequest,
  MultipartUploadInitResponse,
  MultipartUploadPartResponse,
  MoodboardAgentStep,
  MoodboardDocument,
  MoodboardExportOptions,
  MoodboardProposal,
  MoodboardProposalResponse,
  MoveFolderRequest,
  OkResponse,
  ProposeMoodboardRequest,
  QuickJumpResponse,
  RenameFolderRequest,
  ReplacementCandidatesRequest,
  ReplacementCandidatesResponse,
  ResetAIUsageRequest,
  SaveAIConfigRequest,
  SaveExternalAgentConfigRequest,
  SaveGoogleOAuthConfigRequest,
  SaveSmartFolderRequest,
  SaveSyncConfigRequest,
  SaveTypeSafeConfigRequest,
  SeedDemoResponse,
  SemanticSearchRequest,
  SemanticSearchResponse,
  SharedFoldersResponse,
  SimilarAssetsResponse,
  SmartFoldersResponse,
  SyncConfigResponse,
  SyncNowResponse,
  TagCountsResponse,
  TestAIConnectionRequest,
  TestAIConnectionResponse,
  TestTypeSafeConnectionRequest,
  TestWebDAVRequest,
  TestWebDAVResponse,
  ThumbnailTier,
  TypeSafeConfigResponse,
  TypeSafeModelsResponse,
  UpdateFolderAppearanceRequest,
  UUID,
} from '@charkle/shared';
import { preprocessBase64Image, preprocessFileForUpload } from '../lib/client-media';

export const API_BASE = '/api/v1';

async function mapWithConcurrency<T, R>(
  items: readonly T[],
  concurrency: number,
  worker: (item: T, index: number) => Promise<R>,
): Promise<R[]> {
  const results = new Array<R>(items.length);
  let nextIdx = 0;
  const count = Math.max(1, Math.min(concurrency, items.length));
  await Promise.all(
    Array.from({ length: count }, async () => {
      while (true) {
        const idx = nextIdx++;
        if (idx >= items.length) break;
        results[idx] = await worker(items[idx], idx);
      }
    }),
  );
  return results;
}

export class ApiError extends Error {
  readonly status: number;
  readonly code?: string;
  readonly retryAfterSeconds?: number;
  readonly details?: unknown;

  constructor(
    message: string,
    status: number,
    options?: { code?: string; retryAfterSeconds?: number; details?: unknown },
  ) {
    super(message);
    this.name = 'ApiError';
    this.status = status;
    this.code = options?.code;
    this.retryAfterSeconds = options?.retryAfterSeconds;
    this.details = options?.details;
  }
}

let unauthorizedHandler: (() => void) | null = null;

export function setUnauthorizedHandler(handler: (() => void) | null): void {
  unauthorizedHandler = handler;
}

function parseRetryAfter(headerValue: string | null): number | undefined {
  if (!headerValue) return undefined;
  const num = Number(headerValue);
  if (Number.isFinite(num) && num > 0) return Math.ceil(num);
  const dateMs = Date.parse(headerValue);
  if (!Number.isNaN(dateMs)) {
    const diff = Math.ceil((dateMs - Date.now()) / 1000);
    return diff > 0 ? diff : undefined;
  }
  return undefined;
}

async function parseErrorResponse(res: Response): Promise<ApiError> {
  const retryAfterSeconds = parseRetryAfter(res.headers.get('Retry-After'));
  try {
    const data = (await res.json()) as { error?: string; message?: string; code?: string; details?: unknown };
    const message = data.error || data.message || `请求失败 (${res.status})`;
    return new ApiError(message, res.status, {
      code: data.code,
      retryAfterSeconds,
      details: data.details,
    });
  } catch {
    const text = await res.text().catch(() => '');
    return new ApiError(text || `请求失败 (${res.status})`, res.status, {
      retryAfterSeconds,
    });
  }
}

interface RequestOptions extends RequestInit {
  skipAuthRedirect?: boolean;
}

async function requestJson<T>(path: string, init: RequestOptions = {}): Promise<T> {
  const { skipAuthRedirect, headers, ...rest } = init;
  const finalHeaders = new Headers(headers);
  if (!(rest.body instanceof FormData) && rest.body !== undefined && !finalHeaders.has('Content-Type')) {
    finalHeaders.set('Content-Type', 'application/json');
  }

  const res = await fetch(`${API_BASE}${path}`, {
    credentials: 'include',
    ...rest,
    headers: finalHeaders,
  });

  if (res.status === 401 && !skipAuthRedirect) {
    unauthorizedHandler?.();
  }

  if (!res.ok) {
    throw await parseErrorResponse(res);
  }

  if (res.status === 204) {
    return undefined as T;
  }
  return (await res.json()) as T;
}

export function thumbnailURL(
  id: UUID,
  tier: ThumbnailTier = 'grid520',
  cacheBust?: string | number | null,
): string {
  const suffix = cacheBust ? `?v=${encodeURIComponent(String(cacheBust))}` : '';
  return `${API_BASE}/media/${encodeURIComponent(id)}/thumbnail/${tier}${suffix}`;
}

export interface OriginalMediaURLOptions {
  download?: boolean;
  cachedOnly?: boolean;
}

export function originalMediaURL(
  id: UUID,
  options: boolean | OriginalMediaURLOptions = false,
): string {
  const opts: OriginalMediaURLOptions =
    typeof options === 'boolean' ? { download: options } : options;
  const params = new URLSearchParams();
  if (opts.download) params.set('download', '1');
  if (opts.cachedOnly) params.set('cachedOnly', '1');
  const query = params.toString();
  return `${API_BASE}/media/${encodeURIComponent(id)}/original${query ? `?${query}` : ''}`;
}

export function extensionDownloadURL(): string {
  return `${API_BASE}/extension/download`;
}

export function figmaPluginDownloadURL(): string {
  return `${API_BASE}/figma-plugin/download`;
}

export const apiClient = {
  // MARK: - Health & Auth
  health: () => requestJson<HealthResponse>('/health', { skipAuthRedirect: true }),

  getAuthStatus: () => requestJson<AuthStatus>('/auth/status', { skipAuthRedirect: true }),

  setupAdmin: (req: AuthSetupRequest) =>
    requestJson<AuthLoginResponse>('/auth/setup', {
      method: 'POST',
      body: JSON.stringify(req),
      skipAuthRedirect: true,
    }),

  login: (req: AuthLoginRequest & { rememberMe?: boolean }) =>
    requestJson<AuthLoginResponse>('/auth/login', {
      method: 'POST',
      body: JSON.stringify(req),
      skipAuthRedirect: true,
    }),

  logout: () =>
    requestJson<OkResponse>('/auth/logout', {
      method: 'POST',
      skipAuthRedirect: true,
    }),

  changePassword: (req: AuthChangePasswordRequest) =>
    requestJson<OkResponse>('/auth/change-password', {
      method: 'POST',
      body: JSON.stringify(req),
    }),

  listSessions: () => requestJson<AuthSessionsResponse>('/auth/sessions'),

  revokeSession: (sessionId: UUID) =>
    requestJson<OkResponse>(`/auth/sessions/${encodeURIComponent(sessionId)}`, {
      method: 'DELETE',
    }),

  revokeOtherSessions: () =>
    requestJson<OkResponse>('/auth/sessions/revoke-others', {
      method: 'POST',
    }),

  listApiTokens: () => requestJson<ApiTokensResponse>('/auth/tokens'),

  createApiToken: (req: CreateApiTokenRequest) =>
    requestJson<CreateApiTokenResponse>('/auth/tokens', {
      method: 'POST',
      body: JSON.stringify(req),
    }),

  revokeApiToken: (tokenId: UUID) =>
    requestJson<OkResponse>(`/auth/tokens/${encodeURIComponent(tokenId)}`, {
      method: 'DELETE',
    }),

  // MARK: - Library & Assets
  getLibraryBootstrap: () => requestJson<LibraryBootstrapResponse>('/library/bootstrap'),

  seedDemoLibrary: () =>
    requestJson<SeedDemoResponse>('/library/seed-demo', {
      method: 'POST',
    }),

  quickJump: (query: string) =>
    requestJson<QuickJumpResponse>(`/library/quick-jump?q=${encodeURIComponent(query)}`),

  queryAssets: (req: AssetsQueryRequest = {}) =>
    requestJson<AssetsListResponse>('/assets/query', {
      method: 'POST',
      body: JSON.stringify(req),
    }),

  getRecentActivityAssets: (limit = 24) =>
    requestJson<AssetsListResponse>(`/assets/recent-activity?limit=${limit}`),

  getAsset: (id: UUID) =>
    requestJson<AssetDetailResponse>(`/assets/${encodeURIComponent(id)}`),

  ingestAssets: async (req: IngestRequest) => {
    const needsPreprocess = req.inputs.some(
      (input) => input.type === 'imageData' && input.preprocessed === undefined,
    );
    const enrichedInputs: CaptureInput[] = needsPreprocess
      ? await mapWithConcurrency(req.inputs, 3, async (input): Promise<CaptureInput> => {
          if (input.type === 'imageData' && input.preprocessed === undefined) {
            const preprocessed = await preprocessBase64Image(
              input.base64Data,
              input.suggestedName,
            ).catch(() => undefined);
            if (preprocessed) {
              return { ...input, preprocessed };
            }
          }
          return input;
        })
      : req.inputs;

    return requestJson<IngestResponse>('/assets/ingest', {
      method: 'POST',
      body: JSON.stringify({ ...req, inputs: enrichedInputs }),
    });
  },

  initMultipartUpload: (req: MultipartUploadInitRequest) =>
    requestJson<MultipartUploadInitResponse>('/uploads/multipart/init', {
      method: 'POST',
      body: JSON.stringify(req),
    }),

  uploadMultipartPart: async (
    sessionID: UUID,
    partNumber: number,
    chunk: Blob,
  ): Promise<MultipartUploadPartResponse> => {
    const res = await fetch(
      `${API_BASE}/uploads/multipart/${encodeURIComponent(sessionID)}/part/${partNumber}`,
      {
        method: 'PUT',
        credentials: 'include',
        headers: { 'Content-Type': 'application/octet-stream' },
        body: chunk,
      },
    );
    if (res.status === 401) {
      unauthorizedHandler?.();
    }
    if (!res.ok) {
      throw await parseErrorResponse(res);
    }
    return (await res.json()) as MultipartUploadPartResponse;
  },

  completeMultipartUpload: (sessionID: UUID, req: MultipartUploadCompleteRequest = {}) =>
    requestJson<MultipartUploadCompleteResponse>(
      `/uploads/multipart/${encodeURIComponent(sessionID)}/complete`,
      {
        method: 'POST',
        body: JSON.stringify(req),
      },
    ),

  abortMultipartUpload: (sessionID: UUID) =>
    requestJson<OkResponse>(`/uploads/multipart/${encodeURIComponent(sessionID)}`, {
      method: 'DELETE',
    }),

  uploadFiles: async (
    files: File[],
    opts?: { targetFolderID?: UUID | null; targetBoardID?: UUID | null },
  ): Promise<IngestResponse> => {
    const MULTIPART_SINGLE_FILE_THRESHOLD_BYTES = 16 * 1024 * 1024;
    const SMALL_BATCH_MAX_BYTES = 24 * 1024 * 1024;
    const PART_UPLOAD_CONCURRENCY = 3;

    const preprocessedList = await mapWithConcurrency<File, ClientPreprocessedMedia | null>(
      files,
      3,
      async (file) => (await preprocessFileForUpload(file).catch(() => undefined)) ?? null,
    );

    const smallIndices: number[] = [];
    const largeIndices: number[] = [];
    let smallBatchBytes = 0;

    for (let i = 0; i < files.length; i++) {
      const f = files[i];
      if (
        f.size > MULTIPART_SINGLE_FILE_THRESHOLD_BYTES ||
        smallBatchBytes + f.size > SMALL_BATCH_MAX_BYTES
      ) {
        largeIndices.push(i);
      } else {
        smallIndices.push(i);
        smallBatchBytes += f.size;
      }
    }

    const orderedAssets = new Array<IngestResponse['assets'][number] | undefined>(files.length);

    if (smallIndices.length > 0) {
      const form = new FormData();
      const smallPreprocessed: Array<ClientPreprocessedMedia | null> = [];
      for (const idx of smallIndices) {
        const file = files[idx];
        form.append('files', file, file.name);
        smallPreprocessed.push(preprocessedList[idx] ?? null);
      }
      if (smallPreprocessed.some((entry) => entry !== null)) {
        form.append('preprocessed', JSON.stringify(smallPreprocessed));
      }
      if (opts?.targetFolderID) {
        form.append('targetFolderID', opts.targetFolderID);
      }
      if (opts?.targetBoardID) {
        form.append('targetBoardID', opts.targetBoardID);
      }
      const res = await requestJson<IngestResponse>('/assets/upload', {
        method: 'POST',
        body: form,
      });
      for (let k = 0; k < smallIndices.length; k++) {
        orderedAssets[smallIndices[k]] = res.assets[k];
      }
    }

    for (const idx of largeIndices) {
      const file = files[idx];
      const preprocessed = preprocessedList[idx] ?? null;
      const init = await apiClient.initMultipartUpload({
        fileName: file.name || 'upload',
        mimeType: file.type || null,
        fileSizeBytes: file.size,
        targetFolderID: opts?.targetFolderID ?? null,
        targetBoardID: opts?.targetBoardID ?? null,
        preprocessed,
      });

      const partSize = Math.max(5 * 1024 * 1024, init.partSizeBytes);
      const totalParts = Math.max(1, Math.ceil(file.size / partSize));
      const partNumbers = Array.from({ length: totalParts }, (_, p) => p + 1);

      try {
        const uploadedParts = await mapWithConcurrency(
          partNumbers,
          PART_UPLOAD_CONCURRENCY,
          async (partNumber) => {
            const start = (partNumber - 1) * partSize;
            const end = Math.min(file.size, start + partSize);
            const slice = file.slice(start, end);

            let lastErr: unknown;
            for (let attempt = 0; attempt < 3; attempt++) {
              try {
                return await apiClient.uploadMultipartPart(init.sessionID, partNumber, slice);
              } catch (err) {
                lastErr = err;
                const retryable =
                  !(err instanceof ApiError) || err.status >= 500 || err.status === 429;
                if (!retryable || attempt === 2) throw err;
                await new Promise((r) => setTimeout(r, 300 * (attempt + 1)));
              }
            }
            throw lastErr;
          },
        );

        const completed = await apiClient.completeMultipartUpload(init.sessionID, {
          parts: uploadedParts,
        });
        orderedAssets[idx] = completed.asset;
      } catch (err) {
        await apiClient.abortMultipartUpload(init.sessionID).catch(() => undefined);
        throw err;
      }
    }

    return {
      assets: orderedAssets.filter((a): a is NonNullable<typeof a> => Boolean(a)),
    };
  },

  batchPatchAssets: (patch: BatchPatchAssetsRequest) =>
    requestJson<BatchPatchAssetsResponse>('/assets/batch', {
      method: 'PATCH',
      body: JSON.stringify(patch),
    }),

  permanentlyDeleteAssets: (ids: UUID[]) =>
    requestJson<OkResponse>('/assets/permanent-delete', {
      method: 'POST',
      body: JSON.stringify({ ids }),
    }),

  emptyTrash: () =>
    requestJson<OkResponse>('/assets/empty-trash', {
      method: 'POST',
    }),

  restoreAllTrash: () =>
    requestJson<OkResponse>('/assets/restore-all-trash', {
      method: 'POST',
    }),

  markAssetOpened: (id: UUID) =>
    requestJson<OkResponse>(`/assets/${encodeURIComponent(id)}/opened`, {
      method: 'POST',
    }),

  getSimilarAssets: (id: UUID, limit = 12) =>
    requestJson<SimilarAssetsResponse>(`/assets/${encodeURIComponent(id)}/similar?limit=${limit}`),

  suggestFolderForAsset: (id: UUID) =>
    requestJson<FolderSuggestionResponse>('/ai/suggest-folder', {
      method: 'POST',
      body: JSON.stringify({ assetID: id }),
    }),

  refreshRichAsset: (id: UUID) =>
    requestJson<AssetDetailResponse>(`/assets/${encodeURIComponent(id)}/refresh-rich`, {
      method: 'POST',
    }),

  hydrateAssetMetadata: (id: UUID) =>
    requestJson<AssetDetailResponse>(`/assets/${encodeURIComponent(id)}/hydrate-metadata`, {
      method: 'POST',
    }),

  extractSocialMedia: (id: UUID, req: ExtractSocialMediaRequest = {}) =>
    requestJson<IngestResponse>(`/assets/${encodeURIComponent(id)}/extract-social-media`, {
      method: 'POST',
      body: JSON.stringify(req),
    }),

  async getAssetTextContent(id: UUID): Promise<string> {
    const res = await fetch(originalMediaURL(id), { credentials: 'include' });
    if (res.status === 401) {
      unauthorizedHandler?.();
    }
    if (!res.ok) {
      throw await parseErrorResponse(res);
    }
    const text = await res.text();
    return text.slice(0, 262_144);
  },

  // MARK: - Folders, Smart Folders & Tags
  listFolders: () => requestJson<FoldersResponse>('/folders'),

  createFolder: (req: CreateFolderRequest) =>
    requestJson<FolderResponse>('/folders', {
      method: 'POST',
      body: JSON.stringify(req),
    }),

  renameFolder: (id: UUID, req: RenameFolderRequest) =>
    requestJson<FolderResponse>(`/folders/${encodeURIComponent(id)}`, {
      method: 'PATCH',
      body: JSON.stringify(req),
    }),

  moveFolder: (id: UUID, req: MoveFolderRequest) =>
    requestJson<FoldersResponse>(`/folders/${encodeURIComponent(id)}/move`, {
      method: 'POST',
      body: JSON.stringify(req),
    }),

  updateFolderAppearance: (id: UUID, req: UpdateFolderAppearanceRequest) =>
    requestJson<FolderResponse>(`/folders/${encodeURIComponent(id)}/appearance`, {
      method: 'PATCH',
      body: JSON.stringify(req),
    }),

  deleteFolder: (id: UUID, req: DeleteFolderRequest = {}) => {
    const qs = req.trashContents ? '?trashContents=true' : '';
    return requestJson<OkResponse>(`/folders/${encodeURIComponent(id)}${qs}`, {
      method: 'DELETE',
    });
  },

  pinFolderOffline: (id: UUID, pinned: boolean) =>
    requestJson<OkResponse>(`/folders/${encodeURIComponent(id)}/pin-offline`, {
      method: 'POST',
      body: JSON.stringify({ pinned }),
    }),

  listSmartFolders: () => requestJson<SmartFoldersResponse>('/smart-folders'),

  saveSmartFolder: (req: SaveSmartFolderRequest) =>
    requestJson<SmartFoldersResponse>('/smart-folders', {
      method: 'PUT',
      body: JSON.stringify(req),
    }),

  deleteSmartFolder: (id: UUID) =>
    requestJson<SmartFoldersResponse>(`/smart-folders/${encodeURIComponent(id)}`, {
      method: 'DELETE',
    }),

  listTags: () => requestJson<TagCountsResponse>('/tags'),

  // MARK: - Moodboards & Exports
  listBoards: () => requestJson<BoardsListResponse>('/boards'),

  createBoard: (req: CreateBoardRequest) =>
    requestJson<BoardDetailResponse>('/boards', {
      method: 'POST',
      body: JSON.stringify(req),
    }),

  getBoard: (id: UUID) => requestJson<BoardDetailResponse>(`/boards/${encodeURIComponent(id)}`),

  saveBoard: (id: UUID, document: MoodboardDocument) =>
    requestJson<BoardDetailResponse>(`/boards/${encodeURIComponent(id)}`, {
      method: 'PUT',
      body: JSON.stringify({ document }),
    }),

  deleteBoard: (id: UUID) =>
    requestJson<OkResponse>(`/boards/${encodeURIComponent(id)}`, {
      method: 'DELETE',
    }),

  proposeMoodboard: (req: ProposeMoodboardRequest) =>
    requestJson<MoodboardProposalResponse>('/boards/propose', {
      method: 'POST',
      body: JSON.stringify(req),
    }),

  async curateMoodboard(
    req: CurateMoodboardRequest,
    onStep?: (step: MoodboardAgentStep) => void,
    signal?: AbortSignal,
  ): Promise<MoodboardProposal> {
    const res = await fetch(`${API_BASE}/boards/curate`, {
      method: 'POST',
      credentials: 'include',
      headers: {
        'Content-Type': 'application/json',
        Accept: 'text/event-stream, application/json',
      },
      body: JSON.stringify(req),
      signal,
    });

    if (res.status === 401) {
      unauthorizedHandler?.();
    }
    if (!res.ok) {
      throw await parseErrorResponse(res);
    }

    const contentType = res.headers.get('Content-Type') ?? '';
    if (contentType.includes('text/event-stream') && res.body) {
      const reader = res.body.getReader();
      const decoder = new TextDecoder();
      let buffer = '';
      let finalProposal: MoodboardProposal | null = null;

      while (true) {
        const { done, value } = await reader.read();
        if (done) break;
        buffer += decoder.decode(value, { stream: true });

        const frames = buffer.split(/\r?\n\r?\n/);
        buffer = frames.pop() ?? '';

        for (const frame of frames) {
          let eventName = 'message';
          const dataLines: string[] = [];
          for (const line of frame.split(/\r?\n/)) {
            if (line.startsWith('event:')) {
              eventName = line.slice(6).trim();
            } else if (line.startsWith('data:')) {
              dataLines.push(line.slice(5).trim());
            }
          }
          if (dataLines.length === 0) continue;
          const payloadStr = dataLines.join('\n');
          try {
            const parsed = JSON.parse(payloadStr) as {
              type?: string;
              step?: MoodboardAgentStep;
              proposal?: MoodboardProposal;
              error?: string;
            };
            if (eventName === 'error' || parsed.error) {
              throw new ApiError(parsed.error || '生成情绪板失败', 500);
            }
            if (parsed.step && (eventName === 'step' || parsed.type === 'ai.curate.step')) {
              onStep?.(parsed.step);
            } else if (eventName === 'step' && 'phase' in parsed) {
              onStep?.(parsed as unknown as MoodboardAgentStep);
            }
            if (parsed.proposal) {
              finalProposal = parsed.proposal;
            }
          } catch (err) {
            if (err instanceof ApiError) throw err;
          }
        }
      }

      if (finalProposal) return finalProposal;
      throw new ApiError('未生成有效情绪板，请重试', 500);
    }

    const data = (await res.json()) as MoodboardProposalResponse;
    if (onStep && data.proposal.agentTrace) {
      for (const step of data.proposal.agentTrace) {
        onStep(step);
      }
    }
    return data.proposal;
  },

  extractBoardPalette: (req: ExtractPaletteRequest) =>
    requestJson<ExtractPaletteResponse>('/boards/palette', {
      method: 'POST',
      body: JSON.stringify(req),
    }),

  getReplacementCandidates: (req: ReplacementCandidatesRequest) =>
    requestJson<ReplacementCandidatesResponse>('/boards/replacements', {
      method: 'POST',
      body: JSON.stringify(req),
    }),

  async exportBoardImage(id: UUID, req: ExportMoodboardRequest): Promise<Blob> {
    const res = await fetch(`${API_BASE}/boards/${encodeURIComponent(id)}/export/image`, {
      method: 'POST',
      credentials: 'include',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(req),
    });
    if (res.status === 401) unauthorizedHandler?.();
    if (!res.ok) throw await parseErrorResponse(res);
    return res.blob();
  },

  async exportBoardFigma(
    id: UUID,
    options?: Partial<MoodboardExportOptions>,
  ): Promise<{ blob: Blob; filename: string; report?: FigmaBridgeReport }> {
    const res = await fetch(`${API_BASE}/boards/${encodeURIComponent(id)}/export/figma`, {
      method: 'POST',
      credentials: 'include',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ options: options ?? {} }),
    });
    if (res.status === 401) unauthorizedHandler?.();
    if (!res.ok) throw await parseErrorResponse(res);

    const disposition = res.headers.get('Content-Disposition') ?? '';
    const match = disposition.match(/filename\*?=(?:UTF-8'')?"?([^";]+)"?/i);
    const filename = match ? decodeURIComponent(match[1]) : `moodboard-${id.slice(0, 8)}.charkleboard`;

    let report: FigmaBridgeReport | undefined;
    const reportHeader = res.headers.get('X-Charkle-Bridge-Report');
    if (reportHeader) {
      try {
        report = JSON.parse(decodeURIComponent(reportHeader)) as FigmaBridgeReport;
      } catch {
        // Optional header
      }
    }

    const blob = await res.blob();
    return { blob, filename, report };
  },

  // MARK: - Cloud AI & Experimental TypeSafe (Jev)
  getAIConfig: () => requestJson<AIConfigResponse>('/ai/config'),

  saveAIConfig: (req: SaveAIConfigRequest) =>
    requestJson<AIConfigResponse>('/ai/config', {
      method: 'PUT',
      body: JSON.stringify(req),
    }),

  resetAIUsage: (req: ResetAIUsageRequest = {}) =>
    requestJson<AIConfigResponse>('/ai/usage/reset', {
      method: 'POST',
      body: JSON.stringify(req),
    }),

  listChatGPTModels: () => requestJson<ChatGPTModelsResponse>('/ai/chatgpt/models'),

  connectChatGPT: (req: { accessToken: string; email?: string | null; name?: string | null }) =>
    requestJson<{ session: ChatGPTAccountSession; config: AIProviderConfig }>('/ai/chatgpt/connect', {
      method: 'POST',
      body: JSON.stringify(req),
    }),

  disconnectChatGPT: () =>
    requestJson<{ session: ChatGPTAccountSession }>('/ai/chatgpt/disconnect', {
      method: 'POST',
    }),

  testAIConnection: (req: TestAIConnectionRequest) =>
    requestJson<TestAIConnectionResponse>('/ai/test', {
      method: 'POST',
      body: JSON.stringify(req),
    }),

  analyzeAssets: (req: AnalyzeAssetsRequest) =>
    requestJson<AnalyzeAssetsResponse>('/ai/analyze', {
      method: 'POST',
      body: JSON.stringify(req),
    }),

  semanticSearch: (req: SemanticSearchRequest) =>
    requestJson<SemanticSearchResponse>('/ai/semantic-search', {
      method: 'POST',
      body: JSON.stringify(req),
    }),

  batchTriageInbox: (req: BatchTriageInboxRequest = {}) =>
    requestJson<BatchTriageInboxResponse>('/ai/inbox-triage', {
      method: 'POST',
      body: JSON.stringify(req),
    }),

  getTypeSafeConfig: () => requestJson<TypeSafeConfigResponse>('/typesafe/config'),

  saveTypeSafeConfig: (req: SaveTypeSafeConfigRequest) =>
    requestJson<TypeSafeConfigResponse>('/typesafe/config', {
      method: 'PUT',
      body: JSON.stringify(req),
    }),

  testTypeSafeConnection: (req: TestTypeSafeConnectionRequest) =>
    requestJson<TypeSafeModelsResponse>('/typesafe/test', {
      method: 'POST',
      body: JSON.stringify(req),
    }),

  locateVisualRegion: (req: LocateVisualRegionRequest) =>
    requestJson<LocateVisualRegionResponse>('/typesafe/locate-region', {
      method: 'POST',
      body: JSON.stringify(req),
    }),

  locateVisualMatch: (req: LocateVisualMatchRequest) =>
    requestJson<LocateVisualRegionResponse>('/typesafe/locate-match', {
      method: 'POST',
      body: JSON.stringify(req),
    }),

  detectCleanBounds: (assetID: UUID) =>
    requestJson<CleanBoundsResponse>('/typesafe/clean-bounds', {
      method: 'POST',
      body: JSON.stringify({ assetID }),
    }),

  extractSubjectPalette: (req: ExtractSubjectPaletteRequest) =>
    requestJson<ExtractSubjectPaletteResponse>('/typesafe/subject-palette', {
      method: 'POST',
      body: JSON.stringify(req),
    }),

  // MARK: - Sync, Cache & External Agent MCP
  getSyncConfig: () => requestJson<SyncConfigResponse>('/sync/config'),

  saveSyncConfig: (req: SaveSyncConfigRequest) =>
    requestJson<SyncConfigResponse>('/sync/config', {
      method: 'PUT',
      body: JSON.stringify(req),
    }),

  saveGoogleOAuthConfig: (req: SaveGoogleOAuthConfigRequest) =>
    requestJson<SyncConfigResponse>('/sync/google/oauth-config', {
      method: 'PUT',
      body: JSON.stringify(req),
    }),

  startGoogleOAuth: () =>
    requestJson<GoogleOAuthStartResponse>('/sync/google/oauth/start', {
      method: 'POST',
    }),

  signOutGoogleDrive: () =>
    requestJson<SyncConfigResponse>('/sync/google/sign-out', {
      method: 'POST',
    }),

  listGoogleSharedFolders: () => requestJson<SharedFoldersResponse>('/sync/google/shared-folders'),

  testWebDAV: (req: TestWebDAVRequest) =>
    requestJson<TestWebDAVResponse>('/sync/webdav/test', {
      method: 'POST',
      body: JSON.stringify(req),
    }),

  syncNow: () =>
    requestJson<SyncNowResponse>('/sync/now', {
      method: 'POST',
    }),

  migrateStorage: (req: MigrateStorageRequest) =>
    requestJson<MigrateStorageResponse>('/sync/migrate', {
      method: 'POST',
      body: JSON.stringify(req),
    }),

  getCacheStats: () => requestJson<CacheStatsResponse>('/cache/stats'),

  updateCacheBudget: (budgetBytes: number) =>
    requestJson<CacheStatsResponse>('/cache/budget', {
      method: 'PUT',
      body: JSON.stringify({ budgetBytes }),
    }),

  evictCacheNow: () =>
    requestJson<CacheStatsResponse>('/cache/evict', {
      method: 'POST',
    }),

  getExternalAgentConfig: () => requestJson<ExternalAgentConfigResponse>('/agent/config'),

  saveExternalAgentConfig: (req: SaveExternalAgentConfigRequest) =>
    requestJson<ExternalAgentConfigResponse>('/agent/config', {
      method: 'PUT',
      body: JSON.stringify(req),
    }),

  getExternalAgentDiagnostics: () =>
    requestJson<ExternalAgentDiagnosticsResponse>('/agent/diagnostics'),

  // URL helpers
  thumbnailURL,
  originalMediaURL,
  extensionDownloadURL,
  figmaPluginDownloadURL,
};

export type CharkleApiClient = typeof apiClient;
