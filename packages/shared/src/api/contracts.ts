import type { LabColor } from '../color/lab.js';
import type {
  ApiTokenInfo,
  ApiTokenScope,
  AuthSessionInfo,
  AuthStatus,
  AuthUser,
  CreateApiTokenResult,
} from '../models/auth.js';
import type {
  AssetBatchPatch,
  AssetRecord,
  FilterCriteria,
  FolderRecord,
  FolderSuggestion,
  ISODateString,
  QuickJumpMatch,
  ScoredAsset,
  SmartFolderRecord,
  SmartFolderRule,
  TagCount,
  UUID,
} from '../models/core.js';
import type {
  AIProviderConfig,
  CacheStats,
  CaptureInput,
  ChatGPTAccountSession,
  ChatGPTModelInfo,
  CleanBoundsResult,
  CloudAIProviderKind,
  CloudAIUsageCategory,
  CloudAIUsageSummary,
  InboxTriageRecommendation,
  SemanticSearchReport,
  SubjectPaletteResult,
  TypeSafeExperimentalConfig,
  TypeSafeModelInfo,
  VisualRegionResult,
} from '../models/media.js';
import type {
  ConnectorAnchor,
  ConnectorStyle,
  GroupTint,
  MoodboardAgentStep,
  MoodboardCurationRequest,
  MoodboardDocument,
  MoodboardExportFormat,
  MoodboardExportOptions,
  MoodboardProposal,
  MoodboardSeed,
  MoodboardSummary,
  NoteStyle,
} from '../models/moodboard.js';
import type {
  DriveAccountInfo,
  DriveSyncConfig,
  ExternalAgentConfig,
  RemoteDriveFile,
  StorageMigrationReport,
  SyncReport,
  SyncStatus,
} from '../models/sync.js';

// MARK: - Common Envelopes

export interface ApiErrorResponse {
  error: string;
  code?: string;
  details?: unknown;
}

export interface OkResponse {
  ok: true;
}

export interface HealthResponse {
  ok: boolean;
  version: string;
  timestamp: ISODateString;
}

// MARK: - Auth API (/api/auth/*)

export interface AuthSetupRequest {
  username: string;
  password: string;
  displayName?: string;
}

export interface AuthLoginRequest {
  username: string;
  password: string;
}

export interface AuthLoginResponse {
  user: AuthUser;
  status: AuthStatus;
}

export interface AuthChangePasswordRequest {
  currentPassword: string;
  newPassword: string;
}

export interface AuthSessionsResponse {
  sessions: AuthSessionInfo[];
}

export interface ApiTokensResponse {
  tokens: ApiTokenInfo[];
}

export interface CreateApiTokenRequest {
  name: string;
  scopes: ApiTokenScope[];
  expiresInDays?: number | null;
}

export type CreateApiTokenResponse = CreateApiTokenResult;

// MARK: - Library, Folders, Smart Folders & Assets API

export interface LibraryBootstrapResponse {
  folders: FolderRecord[];
  smartFolders: SmartFolderRecord[];
  tags: TagCount[];
  boards: MoodboardSummary[];
  inboxCount: number;
  totalAssetCount: number;
  untaggedCount: number;
  trashCount: number;
  syncStatus: SyncStatus;
  aiConfig: AIProviderConfig;
}

export interface AssetsQueryRequest {
  criteria?: Partial<FilterCriteria>;
  smartFolderID?: UUID | null;
  limit?: number;
  offset?: number;
}

export interface AssetsListResponse {
  assets: AssetRecord[];
  total: number;
}

export interface AssetDetailResponse {
  asset: AssetRecord;
}

export interface IngestRequest {
  inputs: CaptureInput[];
  targetFolderID?: UUID | null;
  targetBoardID?: UUID | null;
}

export interface IngestResponse {
  assets: AssetRecord[];
}

export type BatchPatchAssetsRequest = AssetBatchPatch;

export interface BatchPatchAssetsResponse {
  assets: AssetRecord[];
}

export interface PermanentDeleteAssetsRequest {
  ids: UUID[];
}

export interface ExtractSocialMediaRequest {
  /** Index into `effectiveAttachments`; omit to extract all attachments in batch. */
  attachmentIndex?: number | null;
}

export interface DeleteFolderRequest {
  /** When true, soft-trashes all non-trashed assets inside the folder subtree and deletes all subfolders. */
  trashContents?: boolean;
}

export interface CreateFolderRequest {
  name: string;
  parentID?: UUID | null;
}

export interface RenameFolderRequest {
  name: string;
}

export interface MoveFolderRequest {
  newParentID?: UUID | null;
  insertAtIndex?: number | null;
}

export interface UpdateFolderAppearanceRequest {
  colorHex?: string | null;
  customSymbol?: string | null;
}

export interface FolderResponse {
  folder: FolderRecord;
}

export interface FoldersResponse {
  folders: FolderRecord[];
}

export interface SaveSmartFolderRequest {
  id?: UUID;
  name: string;
  colorHex?: string | null;
  rule: SmartFolderRule;
  sortOrder?: number;
}

export interface SmartFoldersResponse {
  smartFolders: SmartFolderRecord[];
}

export interface TagCountsResponse {
  tags: TagCount[];
}

export interface QuickJumpResponse {
  matches: QuickJumpMatch[];
}

export interface SimilarAssetsResponse {
  items: ScoredAsset[];
}

export interface FolderSuggestionResponse {
  suggestion: FolderSuggestion | null;
}

export interface CacheStatsResponse {
  stats: CacheStats;
}

export interface UpdateCacheBudgetRequest {
  budgetBytes: number;
}

export interface SeedDemoResponse {
  seeded: boolean;
}

// MARK: - Moodboards API (/api/boards/*)

export interface BoardsListResponse {
  boards: MoodboardSummary[];
}

export interface BoardDetailResponse {
  board: MoodboardDocument;
}

export interface CreateBoardRequest {
  title: string;
  subtitle?: string;
  seedAssetIDs?: UUID[];
}

export interface SaveBoardRequest {
  document: MoodboardDocument;
}

export interface ProposeMoodboardRequest {
  seed: MoodboardSeed;
  primaryCount?: number;
  candidateCount?: number;
}

export type CurateMoodboardRequest = MoodboardCurationRequest;

export interface MoodboardProposalResponse {
  proposal: MoodboardProposal;
}

export interface ExtractPaletteRequest {
  assetIDs: UUID[];
  count?: number;
}

export interface ExtractPaletteResponse {
  colors: LabColor[];
}

export interface ReplacementCandidatesRequest {
  assetID: UUID;
  excluding?: UUID[];
  boardContext?: UUID[];
  limit?: number;
}

export interface ReplacementCandidatesResponse {
  candidates: ScoredAsset[];
}

export interface ExportMoodboardRequest {
  format: MoodboardExportFormat;
  containerWidth?: number;
  options?: Partial<MoodboardExportOptions>;
}

// MARK: - Figma / FigJam Bridge (.charkleboard v1 Manifest)

export interface FigmaBridgeTile {
  file: string;
  x: number;
  y: number;
  width: number;
  height: number;
  sha256: string;
}

export interface FigmaBridgeObjectGeometry {
  x: number;
  y: number;
  width: number;
  height: number;
  angle: number;
  flipX: boolean;
  flipY: boolean;
}

export interface FigmaBridgeObject {
  id: string;
  kind: 'image' | 'note' | 'groupFrame' | 'paletteStrip' | 'unsupported';
  name: string;
  geometry: FigmaBridgeObjectGeometry;
  locked?: boolean;
  cornerRadius?: number;
  warnings: string[];
  image?: {
    pixelWidth: number;
    pixelHeight: number;
    tiles: FigmaBridgeTile[];
    animated: boolean;
    animation?: { file: string; sha256: string };
  };
  note?: {
    title: string | null;
    text: string;
    style: NoteStyle;
    fontSize: number;
    backgroundHex: string;
    foregroundHex: string;
    borderHex: string;
  };
  group?: {
    title: string;
    tint: GroupTint;
    accentHex: string;
  };
  palette?: {
    swatches: Array<{ hex: string; isLight: boolean }>;
  };
}

export interface FigmaBridgeReport {
  objectCount: number;
  imageCount: number;
  noteCount: number;
  groupCount: number;
  paletteCount: number;
  connectorCount: number;
  strokeCount: number;
  reviewCount: number;
  warnings: Array<{ id: string; name: string; issues: string[] }>;
}

export interface FigmaBridgeBoardManifest {
  format: 'charkle-figma-bridge';
  version: 1;
  boardId: UUID;
  name: string;
  subtitle: string;
  mode: 'autoEditorial' | 'freeform';
  darkAppearance: boolean;
  exportedAt: ISODateString;
  sourceOS: string;
  objects: FigmaBridgeObject[];
  connectors: Array<{
    id: UUID;
    fromNodeID: UUID;
    fromAnchor: ConnectorAnchor;
    toNodeID: UUID;
    toAnchor: ConnectorAnchor;
    style: ConnectorStyle;
    colorHex: string;
    dashed: boolean;
    label: string | null;
  }>;
  inkStrokes: Array<{
    id: UUID;
    points: Array<{ x: number; y: number }>;
    colorHex: string;
    lineWidth: number;
    opacity: number;
  }>;
  originals: Array<{
    id: UUID;
    name: string;
    file: string;
    sha256: string;
    bytes: number;
  }>;
  report: FigmaBridgeReport;
}

// MARK: - Cloud AI & Experimental TypeSafe Visual Grounding API

export interface ResetAIUsageRequest {
  category?: CloudAIUsageCategory | null;
}

export interface AIConfigResponse {
  config: AIProviderConfig;
  hasStoredKeys: Record<CloudAIProviderKind, boolean>;
  usage: CloudAIUsageSummary;
  chatGPTSession: ChatGPTAccountSession;
}

export interface SaveAIConfigRequest {
  config: AIProviderConfig;
  apiKey?: string | null;
}

export interface TestAIConnectionRequest {
  config: AIProviderConfig;
  apiKey?: string | null;
}

export interface TestAIConnectionResponse {
  ok: true;
  summary: string;
  models?: ChatGPTModelInfo[];
}

export interface ChatGPTModelsResponse {
  models: ChatGPTModelInfo[];
}

export interface AnalyzeAssetsRequest {
  ids: UUID[];
  /** When true, runs offline color + visual fingerprint rebuild only (never calls cloud AI). */
  localOnly?: boolean;
}

export interface AnalyzeAssetsResponse {
  assets: AssetRecord[];
}

export interface SemanticSearchRequest {
  query: string;
  criteria?: Partial<FilterCriteria>;
  limit?: number;
}

export interface SemanticSearchResponse {
  report: SemanticSearchReport;
}

export interface BatchTriageInboxRequest {
  assetIDs?: UUID[];
  maxCount?: number;
}

export interface BatchTriageInboxResponse {
  recommendations: InboxTriageRecommendation[];
}

export interface TypeSafeConfigResponse {
  config: TypeSafeExperimentalConfig;
  hasStoredKey: boolean;
}

export interface SaveTypeSafeConfigRequest {
  config: TypeSafeExperimentalConfig;
  apiKey?: string | null;
}

export interface TestTypeSafeConnectionRequest {
  config: TypeSafeExperimentalConfig;
  apiKey?: string | null;
}

export interface TypeSafeModelsResponse {
  models: TypeSafeModelInfo[];
}

export interface LocateVisualRegionRequest {
  assetID: UUID;
  query?: string | null;
}

export interface LocateVisualRegionResponse {
  result: VisualRegionResult;
}

export interface LocateVisualMatchRequest {
  referenceAssetID: UUID;
  targetAssetID: UUID;
}

export interface CleanBoundsResponse {
  result: CleanBoundsResult;
}

export interface ExtractSubjectPaletteRequest {
  assetID: UUID;
  query?: string | null;
}

export interface ExtractSubjectPaletteResponse {
  result: SubjectPaletteResult;
}

// MARK: - Cloud & Local Storage Sync API (/api/sync/*)

export interface SyncConfigResponse {
  config: DriveSyncConfig;
  status: SyncStatus;
  hasGoogleOAuthConfig: boolean;
  hasWebDAVPassword: boolean;
  activeLocationSummary: string;
}

export interface SaveSyncConfigRequest {
  config: DriveSyncConfig;
  webDAVPassword?: string | null;
}

export interface SaveGoogleOAuthConfigRequest {
  clientID: string;
  clientSecret: string;
}

export interface GoogleOAuthStartResponse {
  authURL: string;
  state: string;
}

export interface TestWebDAVRequest {
  config: DriveSyncConfig;
  password?: string | null;
}

export interface TestWebDAVResponse {
  account: DriveAccountInfo;
}

export interface MigrateStorageRequest {
  targetConfig: DriveSyncConfig;
  webDAVPassword?: string | null;
}

export interface MigrateStorageResponse {
  report: StorageMigrationReport;
}

export interface SharedFoldersResponse {
  folders: RemoteDriveFile[];
}

export interface SyncNowResponse {
  report: SyncReport;
  status: SyncStatus;
}

// MARK: - External Agent Policy API

export interface ExternalAgentConfigResponse {
  config: ExternalAgentConfig;
}

export interface SaveExternalAgentConfigRequest {
  config: ExternalAgentConfig;
}

// MARK: - Server-Sent Events (SSE) Discriminated Union (/api/events)

export type CharkleSSEEvent =
  | {
      type: 'sync.status';
      status: SyncStatus;
      timestamp: ISODateString;
    }
  | {
      type: 'sync.completed';
      report: SyncReport;
      status: SyncStatus;
      timestamp: ISODateString;
    }
  | {
      type: 'library.changed';
      reason: string;
      assetIDs?: UUID[];
      folderIDs?: UUID[];
      timestamp: ISODateString;
    }
  | {
      type: 'library.enriched';
      assetIDs: UUID[];
      count: number;
      timestamp: ISODateString;
    }
  | {
      type: 'board.updated';
      boardID: UUID;
      deleted?: boolean;
      timestamp: ISODateString;
    }
  | {
      type: 'ai.curate.step';
      requestID: string;
      step: MoodboardAgentStep;
      timestamp: ISODateString;
    }
  | {
      type: 'ping';
      timestamp: ISODateString;
    };

export type CharkleSSEEventType = CharkleSSEEvent['type'];
