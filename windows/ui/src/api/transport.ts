//! Pluggable `CharkleTransport` seam with `TauriTransport` (Windows desktop IPC +
//! zero-copy `charkle-media://` URLs) and `InMemoryMockTransport` (Vitest / browser preview).

import { invoke } from '@tauri-apps/api/core';
import { listen, type UnlistenFn } from '@tauri-apps/api/event';
import { open as openDialog, save as saveDialog } from '@tauri-apps/plugin-dialog';
import {
  backendLocationSummary,
  matchesSmartFolderRule,
  msToCocoaSeconds,
  resolveBackends,
  synchronizePrimaryFields,
  wireDateToMs,
  type AIConnectionTestResult,
  type AIProviderConfig,
  type AIProviderStateDto,
  type AppReleaseUpdate,
  type AssetBatchPatch,
  type AssetRecord,
  type BackendTestResultDto,
  type CacheStats,
  type CaptureSessionInfo,
  type ChatGPTAccountSession,
  type ClientRect,
  type ClipboardPreview,
  type CloudAIUsageCategory,
  type CloudAIUsageSummary,
  type DeepLinkPayload,
  type DeduplicationCleanupResult,
  type DeduplicationResolutionPlan,
  type DeduplicationScanReport,
  type DeduplicationScanScope,
  type DeduplicationSensitivity,
  type DesktopIntegrationStatus,
  type DragOutOutcome,
  type DriveSyncConfig,
  type DuplicateDisposalMode,
  type EditorialLayoutResult,
  type ExtensionBridgeStateDto,
  type ExternalAgentConfig,
  type ExternalAgentSelfCheckDto,
  type ExternalAgentStateDto,
  type FigmaBridgeExportReport,
  type FilterCriteria,
  type FolderRecord,
  type FolderSuggestion,
  type GDirectInstallProgress,
  type GDirectInstallResult,
  type HotkeyConfig,
  type ICloudDriveAvailability,
  type InboxTriageRecommendation,
  type MaterialPackageImportResult,
  type MediaKind,
  type MoodboardAgentStep,
  type MoodboardCurationRequest,
  type MoodboardDocument,
  type MoodboardExportOptions,
  type MoodboardProposal,
  type MoodboardSummary,
  type OcrDiagnostics,
  type PinterestAccount,
  type PinterestBatchImportReport,
  type PinterestBoard,
  type PinterestBoardImportDestination,
  type PinterestBoardImportProgress,
  type PinterestBoardsImportReport,
  type PinterestFeedPage,
  type PinterestFeedSource,
  type PinterestPin,
  type PinterestPinDetailResult,
  type PinterestTrayImportProgress,
  type QuickJumpMatch,
  type RebuildIndexResultDto,
  type ScoredAsset,
  type ShelfDockEdge,
  type ShelfSettings,
  type ShelfTargetMode,
  type SmartFolderRecord,
  type StorageMigrationReport,
  type SyncAuthStateDto,
  type SyncBackendProfile,
  type SyncBackendStatus,
  type SyncReport,
  type SyncStatus,
  type SystemDiagnosticsDto,
  type TagCount,
  type ThumbnailTier,
  type TypeSafeExperimentalConfig,
  type TypeSafeStateDto,
  type TypeSafeTestResultDto,
  type UpdateCheckResponseDto,
  type UpdateDownloadProgress,
  type UpdatePreferencesDto,
  type VerifiedUpdateInstaller,
  type WebdavTestResultDto,
  type WindowSurfaceState,
} from '../types/domain';

export type WindowResizeDirection =
  | 'North'
  | 'South'
  | 'East'
  | 'West'
  | 'NorthEast'
  | 'NorthWest'
  | 'SouthEast'
  | 'SouthWest';

export interface CharkleEventHandlers {
  onLibraryChanged?: () => void;
  onSyncStatus?: (status: SyncStatus) => void;
  onSyncProgressiveMetadata?: (payload: { hasBoards: boolean }) => void;
  onSyncProgressiveThumbnails?: (assetIds: string[]) => void;
  onAssetEnriched?: (assetId: string) => void;
  onBoardUpdated?: (boardId: string) => void;
  onClipboardChanged?: (preview: ClipboardPreview) => void;
  onClipboardCollected?: (count: number) => void;
  onExtensionImported?: (payload: {
    count: number;
    targetFolderId?: string | null;
    targetBoardId?: string | null;
  }) => void;
  onShelfState?: (state: {
    expanded: boolean;
    pinned: boolean;
    defaultTargetMode?: ShelfTargetMode;
    minimalMode?: boolean;
    dockEdge?: ShelfDockEdge;
  }) => void;
  onShelfSettings?: (settings: ShelfSettings) => void;
  onShelfDragHover?: (payload: { active: boolean; count: number }) => void;
  onShelfDropStatus?: (payload: { phase: 'processing' | 'done' | 'error'; message: string }) => void;
  onMainOpenAsset?: (payload: { assetId: string; openQuickLook: boolean }) => void;
  onDeepLinkNavigate?: (payload: DeepLinkPayload) => void;
  onMoodboardAgentStep?: (step: MoodboardAgentStep) => void;
  onSurfaceState?: (state: WindowSurfaceState) => void;
  onUpdateProgress?: (progress: UpdateDownloadProgress) => void;
  onUpdatePhase?: (phase: string) => void;
  onMainCheckUpdates?: () => void;
  onGDirectInstallProgress?: (progress: GDirectInstallProgress) => void;
  onPinterestAuthChanged?: (autoCloseLogin: boolean) => void;
  onPinterestTrayImportProgress?: (progress: PinterestTrayImportProgress) => void;
  onPinterestBoardImportProgress?: (progress: PinterestBoardImportProgress) => void;
}

export interface CharkleTransport {
  readonly kind: 'tauri' | 'mock';

  // Media zero-copy URL builders
  thumbnailUrl(assetId: string, tier?: ThumbnailTier): string;
  originalUrl(assetId: string, opts?: { cachedOnly?: boolean }): string;
  captureFrameUrl(token: string): string;

  // Assets
  fetchAssets(criteria: FilterCriteria): Promise<AssetRecord[]>;
  fetchAsset(id: string): Promise<AssetRecord | null>;
  ingestFiles(paths: string[], targetFolderId?: string | null, targetBoardId?: string | null): Promise<AssetRecord[]>;
  ingestUrl(url: string, title?: string | null, notes?: string | null, targetFolderId?: string | null, targetBoardId?: string | null): Promise<AssetRecord[]>;
  ingestText(title: string, text: string, sourceUrl?: string | null, targetFolderId?: string | null, targetBoardId?: string | null): Promise<AssetRecord[]>;
  ingestSwatch(hex: string, title?: string | null, targetFolderId?: string | null, targetBoardId?: string | null): Promise<AssetRecord[]>;
  ingestImageBase64(dataBase64: string, suggestedName: string, sourceUrl?: string | null, targetFolderId?: string | null, targetBoardId?: string | null): Promise<AssetRecord[]>;
  updateAssets(patch: AssetBatchPatch): Promise<AssetRecord[]>;
  permanentlyDeleteAssets(ids: string[]): Promise<void>;
  markAssetOpened(id: string): Promise<AssetRecord | null>;
  similarAssets(assetId: string, limit?: number): Promise<ScoredAsset[]>;
  suggestFolder(assetId: string): Promise<FolderSuggestion | null>;
  hydrateImageMetadata(id: string): Promise<AssetRecord | null>;
  refreshRichAsset(id: string): Promise<AssetRecord>;
  importMaterialPackages(
    paths: string[],
    targetFolderId?: string | null,
    targetBoardId?: string | null,
  ): Promise<MaterialPackageImportResult[]>;
  scanDuplicates(
    scope: DeduplicationScanScope,
    sensitivity: DeduplicationSensitivity,
    mediaKinds?: MediaKind[] | null,
  ): Promise<DeduplicationScanReport>;
  resolveDuplicateGroups(
    plans: DeduplicationResolutionPlan[],
    disposal: DuplicateDisposalMode,
    mergeMetadata: boolean,
  ): Promise<DeduplicationCleanupResult>;

  // Folders, Smart Folders & Tags
  fetchFolders(): Promise<FolderRecord[]>;
  createFolder(name: string, parentId?: string | null): Promise<FolderRecord>;
  renameFolder(id: string, newName: string): Promise<FolderRecord>;
  moveFolder(id: string, newParentId: string | null, insertAtIndex?: number | null): Promise<FolderRecord[]>;
  updateFolderAppearance(id: string, colorHex: string | null, customSymbol: string | null): Promise<FolderRecord>;
  deleteFolder(id: string, trashContents?: boolean): Promise<void>;
  fetchSmartFolders(): Promise<SmartFolderRecord[]>;
  saveSmartFolder(folder: SmartFolderRecord): Promise<SmartFolderRecord[]>;
  deleteSmartFolder(id: string): Promise<SmartFolderRecord[]>;
  fetchTagCounts(): Promise<TagCount[]>;
  inboxCount(): Promise<number>;

  // Query, Boards & Seeding
  quickJump(query: string, limit?: number): Promise<QuickJumpMatch[]>;
  fetchBoards(): Promise<MoodboardSummary[]>;
  fetchBoard(id: string): Promise<MoodboardDocument | null>;
  saveBoard(doc: MoodboardDocument): Promise<MoodboardDocument>;
  deleteBoard(id: string): Promise<void>;
  setBoardPinnedOffline(id: string, pinned: boolean): Promise<MoodboardDocument>;
  seedSampleLibraryIfEmpty(): Promise<boolean>;

  // Media Cache & System Actions
  cacheStats(): Promise<CacheStats>;
  setCacheBudgetBytes(bytes: number): Promise<number>;
  evictCacheNow(): Promise<CacheStats>;
  readAssetTextContent(id: string): Promise<string | null>;
  revealInExplorer(id: string): Promise<void>;
  openDirectoryInExplorer(path: string): Promise<void>;
  openExternalUrl(url: string): Promise<void>;
  pickFilesDialog(): Promise<string[]>;
  pickMaterialPackageFilesDialog(): Promise<string[]>;
  pickJsonFileDialog(title?: string): Promise<string | null>;

  // Sync
  syncConfig(): Promise<DriveSyncConfig>;
  saveSyncConfig(config: DriveSyncConfig): Promise<void>;
  syncStatus(): Promise<SyncStatus>;
  syncNow(): Promise<SyncReport>;
  getSyncAuthState(): Promise<SyncAuthStateDto>;
  saveGoogleOAuthClient(clientId: string, clientSecret: string): Promise<boolean>;
  importGoogleOAuthSecretFile(filePath: string): Promise<boolean>;
  signInGoogleDrive(): Promise<SyncStatus>;
  signOutGoogleDrive(): Promise<SyncStatus>;
  testWebdavConnection(
    config: DriveSyncConfig,
    password?: string | null,
  ): Promise<WebdavTestResultDto>;
  probeICloudDriveAvailability(): Promise<ICloudDriveAvailability>;
  saveBackendWebdavPassword(backendId: string, password: string): Promise<void>;
  hasBackendWebdavPassword(backendId: string): Promise<boolean>;
  testBackendConnection(
    profile: SyncBackendProfile,
    webdavPassword?: string | null,
  ): Promise<BackendTestResultDto>;
  syncBackend(backendId: string): Promise<SyncReport>;

  // Window Chrome & Snap Layouts
  setWindowTheme(isDark: boolean): Promise<WindowSurfaceState>;
  setMaximizeButtonRect(rect: ClientRect | null): Promise<void>;
  windowMinimize(): Promise<void>;
  windowToggleMaximize(): Promise<boolean>;
  windowClose(): Promise<void>;
  windowIsMaximized(): Promise<boolean>;
  windowStartResize(direction: WindowResizeDirection): Promise<void>;

  // M3 Native Windows Shelf, OLE Drag-Out, Region Capture, Clipboard, Hotkeys & OCR
  startOutboundDrag(assetIds: string[]): Promise<DragOutOutcome>;
  setShelfHitRect(rect: ClientRect | null): Promise<void>;
  toggleShelf(): Promise<boolean>;
  showShelf(pinned?: boolean): Promise<void>;
  hideShelf(): Promise<void>;
  setShelfPinned(pinned: boolean): Promise<boolean>;
  startRegionCapture(targetFolderId?: string | null, targetBoardId?: string | null): Promise<CaptureSessionInfo>;
  getCaptureSession(token: string): Promise<CaptureSessionInfo | null>;
  commitRegionCapture(
    token: string,
    x: number,
    y: number,
    width: number,
    height: number,
    targetFolderId?: string | null,
    targetBoardId?: string | null,
  ): Promise<AssetRecord[]>;
  cancelRegionCapture(token: string): Promise<void>;
  collectClipboardNow(targetFolderId?: string | null, targetBoardId?: string | null): Promise<number>;
  getClipboardPreview(): Promise<ClipboardPreview | null>;
  getDesktopIntegrationStatus(): Promise<DesktopIntegrationStatus>;
  setAutostartEnabled(enabled: boolean): Promise<boolean>;
  updateHotkeys(config: HotkeyConfig): Promise<HotkeyConfig>;
  getOcrDiagnostics(): Promise<OcrDiagnostics>;
  runAssetOcr(id: string): Promise<AssetRecord | null>;
  focusMainWindow(): Promise<void>;
  openMainWindow(): Promise<void>;
  openAssetInMainWindow(assetId: string, openQuickLook?: boolean): Promise<void>;
  copyAssetsToClipboard(assetIds: string[]): Promise<number>;
  getShelfSettings(): Promise<ShelfSettings>;
  saveShelfSettings(settings: ShelfSettings): Promise<ShelfSettings>;
  setMinimalMode(enabled: boolean): Promise<ShelfSettings>;
  setShelfAllowActivate(allow: boolean): Promise<void>;

  // M4 Moodboard Studio, Curator Harness & Exporters
  curateMoodboard(request: MoodboardCurationRequest): Promise<MoodboardProposal>;
  solveEditorialLayout(document: MoodboardDocument, containerWidth: number): Promise<EditorialLayoutResult>;
  exportBoardImageFile(
    document: MoodboardDocument,
    options: MoodboardExportOptions,
    destinationPath: string,
  ): Promise<number>;
  copyBoardImageToClipboard(
    document: MoodboardDocument,
    options: MoodboardExportOptions,
  ): Promise<number>;
  exportBoardFigmaBridge(
    document: MoodboardDocument,
    options: MoodboardExportOptions,
    destinationPath: string,
  ): Promise<FigmaBridgeExportReport>;
  saveFileDialog(
    defaultPath: string,
    filters: Array<{ name: string; extensions: string[] }>,
  ): Promise<string | null>;
  pickDirectoryDialog(title?: string): Promise<string | null>;

  // M5 Hybrid Cloud AI, TypeSafe Jev, External Agent, Storage Migration & Diagnostics
  getAiProviderState(): Promise<AIProviderStateDto>;
  saveAiProviderConfig(
    config: AIProviderConfig,
    opts?: { apiKey?: string | null; clearApiKey?: boolean },
  ): Promise<AIProviderStateDto>;
  testAiProviderConnection(): Promise<AIConnectionTestResult>;
  resetAiUsage(category?: CloudAIUsageCategory | null): Promise<CloudAIUsageSummary>;
  signInWithChatgpt(reconsent?: boolean, switchAccount?: boolean): Promise<AIProviderStateDto>;
  disconnectChatgptAccount(): Promise<ChatGPTAccountSession>;
  getTypesafeState(): Promise<TypeSafeStateDto>;
  saveTypesafeConfig(
    config: TypeSafeExperimentalConfig,
    opts?: { apiKey?: string | null; clearApiKey?: boolean },
  ): Promise<TypeSafeStateDto>;
  testTypesafeConnection(): Promise<TypeSafeTestResultDto>;
  runInboxSmartTriage(assetIds?: string[], maxCount?: number): Promise<InboxTriageRecommendation[]>;
  getExternalAgentState(): Promise<ExternalAgentStateDto>;
  saveExternalAgentConfig(config: ExternalAgentConfig): Promise<ExternalAgentStateDto>;
  runExternalAgentSelfCheck(): Promise<ExternalAgentSelfCheckDto>;
  rebuildLocalVisualIndex(): Promise<RebuildIndexResultDto>;
  saveWebdavPassword(password: string): Promise<void>;
  runStorageMigration(
    targetConfig: DriveSyncConfig,
    webdavPassword?: string | null,
  ): Promise<StorageMigrationReport>;
  getSystemDiagnostics(): Promise<SystemDiagnosticsDto>;
  installGDirectCli(): Promise<GDirectInstallResult>;
  exportFigmaPluginBundle(destinationDir: string): Promise<string>;

  // Browser Extension Bridge
  getExtensionBridgeState(): Promise<ExtensionBridgeStateDto>;
  setExtensionBridgeEnabled(enabled: boolean): Promise<ExtensionBridgeStateDto>;
  setExtensionAutoPair(allowLocalAutoPair: boolean): Promise<ExtensionBridgeStateDto>;
  regenerateExtensionBridgeToken(): Promise<ExtensionBridgeStateDto>;
  revealBundledBrowserExtension(): Promise<string>;

  // Native GitHub Releases In-App Updater
  getUpdatePreferences(): Promise<UpdatePreferencesDto>;
  setAutoCheckUpdates(enabled: boolean): Promise<UpdatePreferencesDto>;
  skipUpdateVersion(version: string): Promise<UpdatePreferencesDto>;
  clearSkippedUpdateVersion(): Promise<UpdatePreferencesDto>;
  checkForUpdates(manual?: boolean): Promise<UpdateCheckResponseDto>;
  downloadAndVerifyUpdate(update: AppReleaseUpdate): Promise<VerifiedUpdateInstaller>;
  cancelUpdateDownload(): Promise<void>;
  installAndRelaunchUpdate(installerPath: string): Promise<void>;
  openUpdateInstaller(installerPath: string): Promise<void>;
  revealUpdateInstaller(installerPath: string): Promise<void>;

  // Pinterest Infinite Spatial Browser, Collection Tray & Board Batch Import
  pinterestOpenLoginWindow(): Promise<void>;
  pinterestCloseLoginWindow(): Promise<void>;
  pinterestCheckSession(): Promise<PinterestAccount | null>;
  pinterestSignOut(): Promise<void>;
  pinterestFetchFeed(
    source: PinterestFeedSource,
    bookmark?: string | null,
    pageSize?: number,
  ): Promise<PinterestFeedPage>;
  pinterestFetchBoards(username: string): Promise<PinterestBoard[]>;
  pinterestFetchPinDetail(pin: PinterestPin): Promise<PinterestPinDetailResult>;
  pinterestFetchSimilarPins(
    pin: PinterestPin,
    bookmark?: string | null,
    pageSize?: number,
  ): Promise<PinterestFeedPage>;
  pinterestExistingImportedPinIds(): Promise<string[]>;
  pinterestImportPins(
    pins: PinterestPin[],
    targetFolderId: string | null,
    extraTags: string[],
    skipDuplicates?: boolean,
  ): Promise<PinterestBatchImportReport>;
  pinterestImportBoards(
    boards: PinterestBoard[],
    destination: PinterestBoardImportDestination,
    extraTags: string[],
    skipDuplicates?: boolean,
  ): Promise<PinterestBoardsImportReport>;
  pinterestCancelBoardImport(): Promise<void>;

  // Live Events
  subscribeEvents(handlers: CharkleEventHandlers): Promise<() => void>;
}

export function isTauriRuntime(): boolean {
  return typeof window !== 'undefined' && '__TAURI_INTERNALS__' in window;
}

export class TauriTransport implements CharkleTransport {
  readonly kind = 'tauri' as const;

  thumbnailUrl(assetId: string, tier: ThumbnailTier = 'grid520'): string {
    return `http://charkle-media.localhost/thumb/${encodeURIComponent(assetId)}/${tier}`;
  }

  originalUrl(assetId: string, opts?: { cachedOnly?: boolean }): string {
    const suffix = opts?.cachedOnly ? '?cachedOnly=1' : '';
    return `http://charkle-media.localhost/original/${encodeURIComponent(assetId)}${suffix}`;
  }

  captureFrameUrl(token: string): string {
    return `http://charkle-media.localhost/capture-frame/${encodeURIComponent(token)}`;
  }

  fetchAssets(criteria: FilterCriteria): Promise<AssetRecord[]> {
    return invoke('fetch_assets', { criteria });
  }

  fetchAsset(id: string): Promise<AssetRecord | null> {
    return invoke('fetch_asset', { id });
  }

  ingestFiles(paths: string[], targetFolderId?: string | null, targetBoardId?: string | null): Promise<AssetRecord[]> {
    return invoke('ingest_files', { paths, targetFolderId: targetFolderId ?? null, targetBoardId: targetBoardId ?? null });
  }

  ingestUrl(url: string, title?: string | null, notes?: string | null, targetFolderId?: string | null, targetBoardId?: string | null): Promise<AssetRecord[]> {
    return invoke('ingest_url', { url, title: title ?? null, notes: notes ?? null, targetFolderId: targetFolderId ?? null, targetBoardId: targetBoardId ?? null });
  }

  ingestText(title: string, text: string, sourceUrl?: string | null, targetFolderId?: string | null, targetBoardId?: string | null): Promise<AssetRecord[]> {
    return invoke('ingest_text', { title, text, sourceUrl: sourceUrl ?? null, targetFolderId: targetFolderId ?? null, targetBoardId: targetBoardId ?? null });
  }

  ingestSwatch(hex: string, title?: string | null, targetFolderId?: string | null, targetBoardId?: string | null): Promise<AssetRecord[]> {
    return invoke('ingest_swatch', { hex, title: title ?? null, targetFolderId: targetFolderId ?? null, targetBoardId: targetBoardId ?? null });
  }

  ingestImageBase64(dataBase64: string, suggestedName: string, sourceUrl?: string | null, targetFolderId?: string | null, targetBoardId?: string | null): Promise<AssetRecord[]> {
    return invoke('ingest_image_base64', { dataBase64, suggestedName, sourceUrl: sourceUrl ?? null, targetFolderId: targetFolderId ?? null, targetBoardId: targetBoardId ?? null });
  }

  updateAssets(patch: AssetBatchPatch): Promise<AssetRecord[]> {
    return invoke('update_assets', { patch });
  }

  permanentlyDeleteAssets(ids: string[]): Promise<void> {
    return invoke('permanently_delete_assets', { ids });
  }

  markAssetOpened(id: string): Promise<AssetRecord | null> {
    return invoke('mark_asset_opened', { id });
  }

  similarAssets(assetId: string, limit = 12): Promise<ScoredAsset[]> {
    return invoke('similar_assets', { assetId, limit });
  }

  suggestFolder(assetId: string): Promise<FolderSuggestion | null> {
    return invoke('suggest_folder', { assetId });
  }

  hydrateImageMetadata(id: string): Promise<AssetRecord | null> {
    return invoke('hydrate_image_metadata', { id });
  }

  refreshRichAsset(id: string): Promise<AssetRecord> {
    return invoke('refresh_rich_asset', { id });
  }

  importMaterialPackages(
    paths: string[],
    targetFolderId?: string | null,
    targetBoardId?: string | null,
  ): Promise<MaterialPackageImportResult[]> {
    return invoke('import_material_packages', {
      paths,
      targetFolderId: targetFolderId ?? null,
      targetBoardId: targetBoardId ?? null,
    });
  }

  scanDuplicates(
    scope: DeduplicationScanScope,
    sensitivity: DeduplicationSensitivity,
    mediaKinds?: MediaKind[] | null,
  ): Promise<DeduplicationScanReport> {
    return invoke('scan_duplicates', {
      scope,
      sensitivity,
      mediaKinds: mediaKinds && mediaKinds.length > 0 ? mediaKinds : null,
    });
  }

  resolveDuplicateGroups(
    plans: DeduplicationResolutionPlan[],
    disposal: DuplicateDisposalMode,
    mergeMetadata: boolean,
  ): Promise<DeduplicationCleanupResult> {
    return invoke('resolve_duplicate_groups', {
      plans,
      disposal,
      mergeMetadata,
    });
  }

  fetchFolders(): Promise<FolderRecord[]> {
    return invoke('fetch_folders');
  }

  createFolder(name: string, parentId?: string | null): Promise<FolderRecord> {
    return invoke('create_folder', { name, parentId: parentId ?? null });
  }

  renameFolder(id: string, newName: string): Promise<FolderRecord> {
    return invoke('rename_folder', { id, newName });
  }

  moveFolder(id: string, newParentId: string | null, insertAtIndex?: number | null): Promise<FolderRecord[]> {
    return invoke('move_folder', { id, newParentId, insertAtIndex: insertAtIndex ?? null });
  }

  updateFolderAppearance(id: string, colorHex: string | null, customSymbol: string | null): Promise<FolderRecord> {
    return invoke('update_folder_appearance', { id, colorHex, customSymbol });
  }

  deleteFolder(id: string, trashContents = false): Promise<void> {
    return invoke('delete_folder', { id, trashContents });
  }

  fetchSmartFolders(): Promise<SmartFolderRecord[]> {
    return invoke('fetch_smart_folders');
  }

  saveSmartFolder(folder: SmartFolderRecord): Promise<SmartFolderRecord[]> {
    return invoke('save_smart_folder', { folder });
  }

  deleteSmartFolder(id: string): Promise<SmartFolderRecord[]> {
    return invoke('delete_smart_folder', { id });
  }

  fetchTagCounts(): Promise<TagCount[]> {
    return invoke('fetch_tag_counts');
  }

  inboxCount(): Promise<number> {
    return invoke('inbox_count');
  }

  quickJump(query: string, limit = 24): Promise<QuickJumpMatch[]> {
    return invoke('quick_jump', { query, limit });
  }

  fetchBoards(): Promise<MoodboardSummary[]> {
    return invoke('fetch_boards');
  }

  fetchBoard(id: string): Promise<MoodboardDocument | null> {
    return invoke('fetch_board', { id });
  }

  saveBoard(document: MoodboardDocument): Promise<MoodboardDocument> {
    return invoke('save_board', { document });
  }

  deleteBoard(id: string): Promise<void> {
    return invoke('delete_board', { id });
  }

  setBoardPinnedOffline(id: string, pinned: boolean): Promise<MoodboardDocument> {
    return invoke('set_board_pinned_offline', { id, pinned });
  }

  seedSampleLibraryIfEmpty(): Promise<boolean> {
    return invoke('seed_sample_library_if_empty');
  }

  cacheStats(): Promise<CacheStats> {
    return invoke('cache_stats');
  }

  setCacheBudgetBytes(bytes: number): Promise<number> {
    return invoke('set_cache_budget_bytes', { bytes });
  }

  evictCacheNow(): Promise<CacheStats> {
    return invoke('evict_cache_now');
  }

  readAssetTextContent(id: string): Promise<string | null> {
    return invoke('read_asset_text_content', { id });
  }

  revealInExplorer(id: string): Promise<void> {
    return invoke('reveal_in_explorer', { id });
  }

  openDirectoryInExplorer(path: string): Promise<void> {
    return invoke('open_directory_in_explorer', { path });
  }

  openExternalUrl(url: string): Promise<void> {
    return invoke('open_external_url', { url });
  }

  async pickFilesDialog(): Promise<string[]> {
    const selected = await openDialog({ multiple: true, directory: false });
    if (!selected) return [];
    return Array.isArray(selected) ? selected : [selected];
  }

  async pickMaterialPackageFilesDialog(): Promise<string[]> {
    const selected = await openDialog({
      multiple: true,
      directory: false,
      title: '选择外部素材包 (.eaglepack / .zip)',
      filters: [{ name: '素材包 (.eaglepack / .zip)', extensions: ['eaglepack', 'zip'] }],
    });
    if (!selected) return [];
    return Array.isArray(selected) ? selected : [selected];
  }

  async pickJsonFileDialog(title = '选择 JSON 凭证文件'): Promise<string | null> {
    const selected = await openDialog({
      multiple: false,
      directory: false,
      title,
      filters: [{ name: 'JSON', extensions: ['json'] }],
    });
    return typeof selected === 'string' && selected.length > 0 ? selected : null;
  }

  syncConfig(): Promise<DriveSyncConfig> {
    return invoke('sync_config');
  }

  saveSyncConfig(config: DriveSyncConfig): Promise<void> {
    return invoke('save_sync_config', { config });
  }

  syncStatus(): Promise<SyncStatus> {
    return invoke('sync_status');
  }

  syncNow(): Promise<SyncReport> {
    return invoke('sync_now');
  }

  getSyncAuthState(): Promise<SyncAuthStateDto> {
    return invoke('get_sync_auth_state');
  }

  saveGoogleOAuthClient(clientId: string, clientSecret: string): Promise<boolean> {
    return invoke('save_google_oauth_client', { clientId, clientSecret });
  }

  importGoogleOAuthSecretFile(filePath: string): Promise<boolean> {
    return invoke('import_google_oauth_secret_file', { filePath });
  }

  signInGoogleDrive(): Promise<SyncStatus> {
    return invoke('sign_in_google_drive');
  }

  signOutGoogleDrive(): Promise<SyncStatus> {
    return invoke('sign_out_google_drive');
  }

  testWebdavConnection(
    config: DriveSyncConfig,
    password?: string | null,
  ): Promise<WebdavTestResultDto> {
    return invoke('test_webdav_connection', { config, password: password ?? null });
  }

  probeICloudDriveAvailability(): Promise<ICloudDriveAvailability> {
    return invoke('probe_icloud_drive_availability');
  }

  saveBackendWebdavPassword(backendId: string, password: string): Promise<void> {
    return invoke('save_backend_webdav_password', { backendId, password });
  }

  hasBackendWebdavPassword(backendId: string): Promise<boolean> {
    return invoke('has_backend_webdav_password', { backendId });
  }

  testBackendConnection(
    profile: SyncBackendProfile,
    webdavPassword?: string | null,
  ): Promise<BackendTestResultDto> {
    return invoke('test_backend_connection', {
      profile,
      webdavPassword: webdavPassword ?? null,
    });
  }

  syncBackend(backendId: string): Promise<SyncReport> {
    return invoke('sync_backend', { backendId });
  }

  setWindowTheme(isDark: boolean): Promise<WindowSurfaceState> {
    return invoke('set_window_theme', { isDark });
  }

  setMaximizeButtonRect(rect: ClientRect | null): Promise<void> {
    return invoke('set_maximize_button_rect', { rect });
  }

  windowMinimize(): Promise<void> {
    return invoke('window_minimize');
  }

  windowToggleMaximize(): Promise<boolean> {
    return invoke('window_toggle_maximize');
  }

  windowClose(): Promise<void> {
    return invoke('window_close');
  }

  windowIsMaximized(): Promise<boolean> {
    return invoke('window_is_maximized');
  }

  windowStartResize(direction: WindowResizeDirection): Promise<void> {
    return invoke('window_start_resize', { direction });
  }

  startOutboundDrag(assetIds: string[]): Promise<DragOutOutcome> {
    return invoke('start_outbound_drag', { assetIds });
  }

  setShelfHitRect(rect: ClientRect | null): Promise<void> {
    return invoke('set_shelf_hit_rect', { rect });
  }

  toggleShelf(): Promise<boolean> {
    return invoke('toggle_shelf');
  }

  showShelf(pinned = false): Promise<void> {
    return invoke('show_shelf', { pinned });
  }

  hideShelf(): Promise<void> {
    return invoke('hide_shelf');
  }

  setShelfPinned(pinned: boolean): Promise<boolean> {
    return invoke('set_shelf_pinned', { pinned });
  }

  startRegionCapture(targetFolderId?: string | null, targetBoardId?: string | null): Promise<CaptureSessionInfo> {
    return invoke('start_region_capture', {
      targetFolderId: targetFolderId ?? null,
      targetBoardId: targetBoardId ?? null,
    });
  }

  getCaptureSession(token: string): Promise<CaptureSessionInfo | null> {
    return invoke('get_capture_session', { token });
  }

  commitRegionCapture(
    token: string,
    x: number,
    y: number,
    width: number,
    height: number,
    targetFolderId?: string | null,
    targetBoardId?: string | null,
  ): Promise<AssetRecord[]> {
    return invoke('commit_region_capture', {
      token,
      x,
      y,
      width,
      height,
      targetFolderId: targetFolderId ?? null,
      targetBoardId: targetBoardId ?? null,
    });
  }

  cancelRegionCapture(token: string): Promise<void> {
    return invoke('cancel_region_capture', { token });
  }

  collectClipboardNow(targetFolderId?: string | null, targetBoardId?: string | null): Promise<number> {
    return invoke('collect_clipboard_now', {
      targetFolderId: targetFolderId ?? null,
      targetBoardId: targetBoardId ?? null,
    });
  }

  getClipboardPreview(): Promise<ClipboardPreview | null> {
    return invoke('get_clipboard_preview');
  }

  getDesktopIntegrationStatus(): Promise<DesktopIntegrationStatus> {
    return invoke('get_desktop_integration_status');
  }

  setAutostartEnabled(enabled: boolean): Promise<boolean> {
    return invoke('set_autostart_enabled', { enabled });
  }

  updateHotkeys(config: HotkeyConfig): Promise<HotkeyConfig> {
    return invoke('update_hotkeys', { config });
  }

  getOcrDiagnostics(): Promise<OcrDiagnostics> {
    return invoke('get_ocr_diagnostics');
  }

  runAssetOcr(id: string): Promise<AssetRecord | null> {
    return invoke('run_asset_ocr', { id });
  }

  focusMainWindow(): Promise<void> {
    return invoke('focus_main_window');
  }

  openMainWindow(): Promise<void> {
    return invoke('open_main_window');
  }

  openAssetInMainWindow(assetId: string, openQuickLook = true): Promise<void> {
    return invoke('open_asset_in_main_window', { assetId, openQuickLook });
  }

  copyAssetsToClipboard(assetIds: string[]): Promise<number> {
    return invoke('copy_assets_to_clipboard', { assetIds });
  }

  getShelfSettings(): Promise<ShelfSettings> {
    return invoke('get_shelf_settings');
  }

  saveShelfSettings(settings: ShelfSettings): Promise<ShelfSettings> {
    return invoke('save_shelf_settings', { settings });
  }

  setMinimalMode(enabled: boolean): Promise<ShelfSettings> {
    return invoke('set_minimal_mode', { enabled });
  }

  setShelfAllowActivate(allow: boolean): Promise<void> {
    return invoke('set_shelf_allow_activate', { allow });
  }

  curateMoodboard(request: MoodboardCurationRequest): Promise<MoodboardProposal> {
    return invoke('curate_moodboard', { request });
  }

  solveEditorialLayout(
    document: MoodboardDocument,
    containerWidth: number,
  ): Promise<EditorialLayoutResult> {
    return invoke('solve_editorial_layout', { document, containerWidth });
  }

  exportBoardImageFile(
    document: MoodboardDocument,
    options: MoodboardExportOptions,
    destinationPath: string,
  ): Promise<number> {
    return invoke('export_board_image_file', { document, options, destinationPath });
  }

  copyBoardImageToClipboard(
    document: MoodboardDocument,
    options: MoodboardExportOptions,
  ): Promise<number> {
    return invoke('copy_board_image_to_clipboard', { document, options });
  }

  exportBoardFigmaBridge(
    document: MoodboardDocument,
    options: MoodboardExportOptions,
    destinationPath: string,
  ): Promise<FigmaBridgeExportReport> {
    return invoke('export_board_figma_bridge', { document, options, destinationPath });
  }

  async saveFileDialog(
    defaultPath: string,
    filters: Array<{ name: string; extensions: string[] }>,
  ): Promise<string | null> {
    const selected = await saveDialog({ defaultPath, filters });
    return typeof selected === 'string' && selected.length > 0 ? selected : null;
  }

  async pickDirectoryDialog(title = '选择目录'): Promise<string | null> {
    const selected = await openDialog({ directory: true, multiple: false, title });
    return typeof selected === 'string' && selected.length > 0 ? selected : null;
  }

  getAiProviderState(): Promise<AIProviderStateDto> {
    return invoke('get_ai_provider_state');
  }

  saveAiProviderConfig(
    config: AIProviderConfig,
    opts?: { apiKey?: string | null; clearApiKey?: boolean },
  ): Promise<AIProviderStateDto> {
    return invoke('save_ai_provider_config', {
      payload: {
        config,
        apiKey: opts?.apiKey ?? null,
        clearApiKey: opts?.clearApiKey ?? false,
      },
    });
  }

  testAiProviderConnection(): Promise<AIConnectionTestResult> {
    return invoke('test_ai_provider_connection');
  }

  resetAiUsage(category?: CloudAIUsageCategory | null): Promise<CloudAIUsageSummary> {
    return invoke('reset_ai_usage', { category: category ?? null });
  }

  signInWithChatgpt(reconsent = false, switchAccount = false): Promise<AIProviderStateDto> {
    return invoke('sign_in_with_chatgpt', { reconsent, switchAccount });
  }

  disconnectChatgptAccount(): Promise<ChatGPTAccountSession> {
    return invoke('disconnect_chatgpt_account');
  }

  getTypesafeState(): Promise<TypeSafeStateDto> {
    return invoke('get_typesafe_state');
  }

  saveTypesafeConfig(
    config: TypeSafeExperimentalConfig,
    opts?: { apiKey?: string | null; clearApiKey?: boolean },
  ): Promise<TypeSafeStateDto> {
    return invoke('save_typesafe_config', {
      payload: {
        config,
        apiKey: opts?.apiKey ?? null,
        clearApiKey: opts?.clearApiKey ?? false,
      },
    });
  }

  testTypesafeConnection(): Promise<TypeSafeTestResultDto> {
    return invoke('test_typesafe_connection');
  }

  runInboxSmartTriage(
    assetIds?: string[],
    maxCount = 24,
  ): Promise<InboxTriageRecommendation[]> {
    return invoke('run_inbox_smart_triage', {
      assetIds: assetIds && assetIds.length > 0 ? assetIds : null,
      maxCount,
    });
  }

  getExternalAgentState(): Promise<ExternalAgentStateDto> {
    return invoke('get_external_agent_state');
  }

  saveExternalAgentConfig(config: ExternalAgentConfig): Promise<ExternalAgentStateDto> {
    return invoke('save_external_agent_config', { config });
  }

  runExternalAgentSelfCheck(): Promise<ExternalAgentSelfCheckDto> {
    return invoke('run_external_agent_self_check');
  }

  rebuildLocalVisualIndex(): Promise<RebuildIndexResultDto> {
    return invoke('rebuild_local_visual_index');
  }

  saveWebdavPassword(password: string): Promise<void> {
    return invoke('save_webdav_password', { password });
  }

  runStorageMigration(
    targetConfig: DriveSyncConfig,
    webdavPassword?: string | null,
  ): Promise<StorageMigrationReport> {
    return invoke('run_storage_migration', {
      targetConfig,
      webdavPassword: webdavPassword ?? null,
    });
  }

  getSystemDiagnostics(): Promise<SystemDiagnosticsDto> {
    return invoke('get_system_diagnostics');
  }

  installGDirectCli(): Promise<GDirectInstallResult> {
    return invoke('install_gdirect_cli');
  }

  exportFigmaPluginBundle(destinationDir: string): Promise<string> {
    return invoke('export_figma_plugin_bundle', { destinationDir });
  }

  getExtensionBridgeState(): Promise<ExtensionBridgeStateDto> {
    return invoke('get_extension_bridge_state');
  }

  setExtensionBridgeEnabled(enabled: boolean): Promise<ExtensionBridgeStateDto> {
    return invoke('set_extension_bridge_enabled', { enabled });
  }

  setExtensionAutoPair(allowLocalAutoPair: boolean): Promise<ExtensionBridgeStateDto> {
    return invoke('set_extension_auto_pair', { allowLocalAutoPair });
  }

  regenerateExtensionBridgeToken(): Promise<ExtensionBridgeStateDto> {
    return invoke('regenerate_extension_bridge_token');
  }

  revealBundledBrowserExtension(): Promise<string> {
    return invoke('reveal_bundled_browser_extension');
  }

  getUpdatePreferences(): Promise<UpdatePreferencesDto> {
    return invoke('get_update_preferences');
  }

  setAutoCheckUpdates(enabled: boolean): Promise<UpdatePreferencesDto> {
    return invoke('set_auto_check_updates', { enabled });
  }

  skipUpdateVersion(version: string): Promise<UpdatePreferencesDto> {
    return invoke('skip_update_version', { version });
  }

  clearSkippedUpdateVersion(): Promise<UpdatePreferencesDto> {
    return invoke('clear_skipped_update_version');
  }

  checkForUpdates(manual = true): Promise<UpdateCheckResponseDto> {
    return invoke('check_for_updates', { manual });
  }

  downloadAndVerifyUpdate(update: AppReleaseUpdate): Promise<VerifiedUpdateInstaller> {
    return invoke('download_and_verify_update', { update });
  }

  cancelUpdateDownload(): Promise<void> {
    return invoke('cancel_update_download');
  }

  installAndRelaunchUpdate(installerPath: string): Promise<void> {
    return invoke('install_and_relaunch_update', { installerPath });
  }

  openUpdateInstaller(installerPath: string): Promise<void> {
    return invoke('open_update_installer', { installerPath });
  }

  revealUpdateInstaller(installerPath: string): Promise<void> {
    return invoke('reveal_update_installer', { installerPath });
  }

  pinterestOpenLoginWindow(): Promise<void> {
    return invoke('pinterest_open_login_window');
  }

  pinterestCloseLoginWindow(): Promise<void> {
    return invoke('pinterest_close_login_window');
  }

  pinterestCheckSession(): Promise<PinterestAccount | null> {
    return invoke('pinterest_check_session');
  }

  pinterestSignOut(): Promise<void> {
    return invoke('pinterest_sign_out');
  }

  pinterestFetchFeed(
    source: PinterestFeedSource,
    bookmark?: string | null,
    pageSize?: number,
  ): Promise<PinterestFeedPage> {
    return invoke('pinterest_fetch_feed', {
      source,
      bookmark: bookmark ?? null,
      pageSize: pageSize ?? 32,
    });
  }

  pinterestFetchBoards(username: string): Promise<PinterestBoard[]> {
    return invoke('pinterest_fetch_boards', { username });
  }

  pinterestFetchPinDetail(pin: PinterestPin): Promise<PinterestPinDetailResult> {
    return invoke('pinterest_fetch_pin_detail', { pin });
  }

  pinterestFetchSimilarPins(
    pin: PinterestPin,
    bookmark?: string | null,
    pageSize?: number,
  ): Promise<PinterestFeedPage> {
    return invoke('pinterest_fetch_similar_pins', {
      pin,
      bookmark: bookmark ?? null,
      pageSize: pageSize ?? 28,
    });
  }

  pinterestExistingImportedPinIds(): Promise<string[]> {
    return invoke('pinterest_existing_imported_pin_ids');
  }

  pinterestImportPins(
    pins: PinterestPin[],
    targetFolderId: string | null,
    extraTags: string[],
    skipDuplicates = true,
  ): Promise<PinterestBatchImportReport> {
    return invoke('pinterest_import_pins', {
      pins,
      targetFolderId,
      extraTags,
      skipDuplicates,
    });
  }

  pinterestImportBoards(
    boards: PinterestBoard[],
    destination: PinterestBoardImportDestination,
    extraTags: string[],
    skipDuplicates = true,
  ): Promise<PinterestBoardsImportReport> {
    return invoke('pinterest_import_boards', {
      boards,
      destination,
      extraTags,
      skipDuplicates,
    });
  }

  pinterestCancelBoardImport(): Promise<void> {
    return invoke('pinterest_cancel_board_import');
  }

  async subscribeEvents(handlers: CharkleEventHandlers): Promise<() => void> {
    let disposed = false;
    const unsubs: UnlistenFn[] = [];
    const cleanup = () => {
      if (disposed) return;
      disposed = true;
      for (const unsub of unsubs.splice(0)) {
        try {
          unsub();
        } catch {
          // Ignore already-unregistered Tauri listener errors during teardown.
        }
      }
    };

    const registrations: Array<() => Promise<UnlistenFn>> = [];
    if (handlers.onLibraryChanged) {
      registrations.push(() =>
        listen('library:changed', () => {
          if (!disposed) handlers.onLibraryChanged?.();
        }),
      );
    }
    if (handlers.onSyncStatus) {
      registrations.push(() =>
        listen<SyncStatus>('sync:status', (e) => {
          if (!disposed) handlers.onSyncStatus?.(e.payload);
        }),
      );
    }
    if (handlers.onSyncProgressiveMetadata) {
      registrations.push(() =>
        listen<{ hasBoards: boolean }>('sync:progressive-metadata', (e) => {
          if (!disposed) handlers.onSyncProgressiveMetadata?.(e.payload);
        }),
      );
    }
    if (handlers.onSyncProgressiveThumbnails) {
      registrations.push(() =>
        listen<string[]>('sync:progressive-thumbnails', (e) => {
          if (!disposed) handlers.onSyncProgressiveThumbnails?.(e.payload);
        }),
      );
    }
    if (handlers.onAssetEnriched) {
      registrations.push(() =>
        listen<string>('asset:enriched', (e) => {
          if (!disposed) handlers.onAssetEnriched?.(e.payload);
        }),
      );
    }
    if (handlers.onBoardUpdated) {
      registrations.push(() =>
        listen<string>('board:updated', (e) => {
          if (!disposed) handlers.onBoardUpdated?.(e.payload);
        }),
      );
    }
    if (handlers.onClipboardChanged) {
      registrations.push(() =>
        listen<ClipboardPreview>('clipboard:changed', (e) => {
          if (!disposed) handlers.onClipboardChanged?.(e.payload);
        }),
      );
    }
    if (handlers.onClipboardCollected) {
      registrations.push(() =>
        listen<number>('clipboard:collected', (e) => {
          if (!disposed) handlers.onClipboardCollected?.(e.payload);
        }),
      );
    }
    if (handlers.onExtensionImported) {
      registrations.push(() =>
        listen<{
          count: number;
          targetFolderId?: string | null;
          targetBoardId?: string | null;
        }>('extension:imported', (e) => {
          if (!disposed) handlers.onExtensionImported?.(e.payload);
        }),
      );
    }
    if (handlers.onShelfState) {
      registrations.push(() =>
        listen<{
          expanded: boolean;
          pinned: boolean;
          defaultTargetMode?: ShelfTargetMode;
          minimalMode?: boolean;
          dockEdge?: ShelfDockEdge;
        }>('shelf:state', (e) => {
          if (!disposed) handlers.onShelfState?.(e.payload);
        }),
      );
    }
    if (handlers.onShelfSettings) {
      registrations.push(() =>
        listen<ShelfSettings>('shelf:settings', (e) => {
          if (!disposed) handlers.onShelfSettings?.(e.payload);
        }),
      );
    }
    if (handlers.onShelfDragHover) {
      registrations.push(() =>
        listen<{ active: boolean; count: number }>('shelf:drag-hover', (e) => {
          if (!disposed) handlers.onShelfDragHover?.(e.payload);
        }),
      );
    }
    if (handlers.onShelfDropStatus) {
      registrations.push(() =>
        listen<{ phase: 'processing' | 'done' | 'error'; message: string }>(
          'shelf:drop-status',
          (e) => {
            if (!disposed) handlers.onShelfDropStatus?.(e.payload);
          },
        ),
      );
    }
    if (handlers.onMainOpenAsset) {
      registrations.push(() =>
        listen<{ assetId: string; openQuickLook: boolean }>('main:open-asset', (e) => {
          if (!disposed) handlers.onMainOpenAsset?.(e.payload);
        }),
      );
    }
    if (handlers.onDeepLinkNavigate) {
      registrations.push(() =>
        listen<DeepLinkPayload>('deep-link:navigate', (e) => {
          if (!disposed) handlers.onDeepLinkNavigate?.(e.payload);
        }),
      );
    }
    if (handlers.onMoodboardAgentStep) {
      registrations.push(() =>
        listen<MoodboardAgentStep>('moodboard:agent-step', (e) => {
          if (!disposed) handlers.onMoodboardAgentStep?.(e.payload);
        }),
      );
    }
    if (handlers.onSurfaceState) {
      registrations.push(() =>
        listen<WindowSurfaceState>('charkle://surface-changed', (e) => {
          if (!disposed) handlers.onSurfaceState?.(e.payload);
        }),
      );
    }
    if (handlers.onUpdateProgress) {
      registrations.push(() =>
        listen<UpdateDownloadProgress>('updater:progress', (e) => {
          if (!disposed) handlers.onUpdateProgress?.(e.payload);
        }),
      );
    }
    if (handlers.onUpdatePhase) {
      registrations.push(() =>
        listen<string>('updater:phase', (e) => {
          if (!disposed) handlers.onUpdatePhase?.(e.payload);
        }),
      );
    }
    if (handlers.onMainCheckUpdates) {
      registrations.push(() =>
        listen('main:check-updates', () => {
          if (!disposed) handlers.onMainCheckUpdates?.();
        }),
      );
    }
    if (handlers.onGDirectInstallProgress) {
      registrations.push(() =>
        listen<GDirectInstallProgress>('gdirect:install-progress', (e) => {
          if (!disposed) handlers.onGDirectInstallProgress?.(e.payload);
        }),
      );
    }
    if (handlers.onPinterestAuthChanged) {
      registrations.push(() =>
        listen<boolean>('pinterest:auth-changed', (e) => {
          if (!disposed) handlers.onPinterestAuthChanged?.(Boolean(e.payload));
        }),
      );
    }
    if (handlers.onPinterestTrayImportProgress) {
      registrations.push(() =>
        listen<PinterestTrayImportProgress>('pinterest:tray-import-progress', (e) => {
          if (!disposed) handlers.onPinterestTrayImportProgress?.(e.payload);
        }),
      );
    }
    if (handlers.onPinterestBoardImportProgress) {
      registrations.push(() =>
        listen<PinterestBoardImportProgress>('pinterest:board-import-progress', (e) => {
          if (!disposed) handlers.onPinterestBoardImportProgress?.(e.payload);
        }),
      );
    }

    try {
      await Promise.all(
        registrations.map(async (register) => {
          const unsub = await register();
          if (disposed) {
            try {
              unsub();
            } catch {
              // Ignore teardown error if already cleaned up.
            }
          } else {
            unsubs.push(unsub);
          }
        }),
      );
    } catch (err) {
      cleanup();
      throw err;
    }

    return cleanup;
  }
}

function makeUuid(): string {
  if (typeof crypto !== 'undefined' && typeof crypto.randomUUID === 'function') {
    return crypto.randomUUID().toUpperCase();
  }
  return 'XXXXXXXX-XXXX-4XXX-8XXX-XXXXXXXXXXXX'.replace(/X/g, () =>
    Math.floor(Math.random() * 16)
      .toString(16)
      .toUpperCase(),
  );
}

function makeSvgDataUrl(bg: string, accent: string, title: string, w = 480, h = 360): string {
  const svg = `<svg xmlns="http://www.w3.org/2000/svg" width="${w}" height="${h}"><rect width="100%" height="100%" fill="${bg}"/><circle cx="${Math.round(w * 0.65)}" cy="${Math.round(h * 0.38)}" r="${Math.round(Math.min(w, h) * 0.25)}" fill="${accent}" opacity="0.85"/><text x="24" y="${h - 28}" fill="#ffffff" font-family="sans-serif" font-size="16" opacity="0.72">${title.replace(/[<>&]/g, '')}</text></svg>`;
  return `data:image/svg+xml;charset=utf-8,${encodeURIComponent(svg)}`;
}

/**
 * Full in-memory mock transport for Vitest suites and standalone Vite browser previews.
 */
export class InMemoryMockTransport implements CharkleTransport {
  readonly kind = 'mock' as const;
  private assets: AssetRecord[] = [];
  private folders: FolderRecord[] = [];
  private smartFolders: SmartFolderRecord[] = [];
  private boards: MoodboardDocument[] = [];
  private textContent = new Map<string, string>();
  private thumbs = new Map<string, string>();
  private maximized = false;
  private shelfVisible = false;
  private shelfPinned = false;
  private autostartEnabled = false;
  private hotkeyConfig: HotkeyConfig = {
    enabled: true,
    captureArea: 'Alt+Shift+A',
    toggleShelf: 'Alt+Shift+S',
    collectClipboard: 'Alt+Shift+V',
  };
  private clipboardPreview: ClipboardPreview | null = {
    kind: 'url',
    label: 'https://x.com/charkle_design/status/1900000001',
    url: 'https://x.com/charkle_design/status/1900000001',
    hex: null,
    fileCount: 0,
    isSocialOrGithubUrl: true,
  };
  public lastOutboundDragIds: string[] = [];
  public lastShelfHitRect: ClientRect | null = null;
  public lastCommittedCrop: { token: string; x: number; y: number; width: number; height: number } | null = null;
  public lastExportedPath: string | null = null;
  public lastClipboardExportCount = 0;
  private syncCfg: DriveSyncConfig = {
    mode: 'localOnly',
    rootFolderName: 'Charkle',
    sharedFolderURLOrID: '',
    mountPath: 'G:\\',
    useGDirectIPAcceleration: true,
    webDAVServerURL: '',
    webDAVUsername: '',
    webDAVRemotePath: '/Charkle',
    localLibraryPath: 'Pictures\\Charkle',
    autoSyncIntervalSeconds: 120,
    syncThumbnails: true,
    syncEmbeddings: true,
  };

  constructor(seed = true) {
    if (seed) {
      this.seedSync();
    }
  }

  private seedSync() {
    const now = msToCocoaSeconds(Date.now());
    const fUi: FolderRecord = {
      id: '10000000-0000-4000-8000-000000000001',
      name: 'UI Inspiration',
      parentID: null,
      sortOrder: 0,
      assetCount: 2,
      colorHex: '#2A60E0',
      customSymbol: 'sf:paintbrush.fill',
      createdAt: now,
      updatedAt: now,
    };
    const fTypo: FolderRecord = {
      id: '10000000-0000-4000-8000-000000000002',
      name: 'Typography',
      parentID: fUi.id,
      sortOrder: 0,
      assetCount: 1,
      colorHex: '#E04F44',
      customSymbol: null,
      createdAt: now,
      updatedAt: now,
    };
    this.folders = [fUi, fTypo];

    const a1: AssetRecord = {
      id: '20000000-0000-4000-8000-000000000001',
      contentHash: 'hash1',
      folderID: null,
      mediaKind: 'image',
      mimeType: 'image/png',
      title: '暖调建筑海报参考',
      fileName: 'warm-poster.png',
      notes: '低角度自然光阴影与瑞士排版节奏',
      tags: ['海报', '暖色调', '建筑'],
      suggestedTags: ['editorial'],
      rating: 5,
      pixelWidth: 1200,
      pixelHeight: 1600,
      fileSizeBytes: 245_000,
      dominantColors: [
        { hex: '#BA6B55', l: 55, a: 28, b: 22, proportion: 0.55 },
        { hex: '#F2ECE3', l: 93, a: 1, b: 5, proportion: 0.45 },
      ],
      waveformPeaks: [],
      richMetadata: {
        photoExif: {
          cameraMake: 'Fujifilm',
          cameraModel: 'X-T5',
          lensModel: 'XF35mmF1.4 R',
          exposureTime: '1/250s',
          fNumber: 2.0,
          iso: 160,
          focalLengthMM: 35,
        },
        aiGeneration: {
          generator: 'ComfyUI',
          prompt: 'warm limestone courtyard, morning shadow, minimalist architecture',
          negativePrompt: 'blurry, oversaturated',
          modelName: 'flux1-dev',
          sampler: 'euler',
          steps: 24,
          cfgScale: 6.5,
          seed: '424242',
          loras: ['arch_light_v2'],
          extraParameters: {},
        },
      },
      pinnedOffline: true,
      isLocalOriginalCached: true,
      isTrashed: false,
      createdAt: now - 3600,
      updatedAt: now - 3600,
      updatedHLC: 1,
    };
    const a2: AssetRecord = {
      id: '20000000-0000-4000-8000-000000000002',
      contentHash: 'hash2',
      folderID: fUi.id,
      mediaKind: 'webBookmark',
      mimeType: 'text/uri-list',
      title: 'tauri-apps/tauri',
      fileName: 'tauri-apps-tauri.url',
      notes: 'Build smaller, faster, and more secure desktop applications',
      tags: ['GitHub', 'Rust'],
      suggestedTags: [],
      rating: 4,
      pixelWidth: 1280,
      pixelHeight: 640,
      fileSizeBytes: 120,
      dominantColors: [{ hex: '#2A60E0', l: 44, a: 18, b: -58, proportion: 1.0 }],
      waveformPeaks: [],
      sourceURL: 'https://github.com/tauri-apps/tauri',
      sourceDomain: 'github.com',
      richMetadata: {
        githubRepo: {
          owner: 'tauri-apps',
          repo: 'tauri',
          fullName: 'tauri-apps/tauri',
          description: 'Build smaller, faster, and more secure desktop applications.',
          language: 'Rust',
          stars: 92000,
          forks: 2800,
          openIssues: 420,
          license: 'MIT / Apache-2.0',
          topics: ['rust', 'webview', 'desktop'],
          readmeMarkdown: '# Tauri\n\nBuild native Windows desktop applications with Rust + WebView2.',
        },
      },
      pinnedOffline: false,
      isLocalOriginalCached: true,
      isTrashed: false,
      createdAt: now - 1800,
      updatedAt: now - 1800,
      updatedHLC: 2,
    };
    const a3: AssetRecord = {
      id: '20000000-0000-4000-8000-000000000003',
      contentHash: 'hash3',
      folderID: fTypo.id,
      mediaKind: 'document',
      mimeType: 'text/markdown',
      title: '设计系统笔记',
      fileName: 'design-notes.md',
      notes: '中英文排版与中性画布原则',
      tags: ['排版'],
      suggestedTags: [],
      rating: 4,
      pixelWidth: 800,
      pixelHeight: 1000,
      fileSizeBytes: 1024,
      dominantColors: [{ hex: '#1E2024', l: 13, a: 0, b: -2, proportion: 1.0 }],
      waveformPeaks: [],
      richMetadata: {
        isMarkdown: true,
        textExcerpt: '# Charkle\n\n90–95% 中性画布，作品绝对主角。',
      },
      pinnedOffline: false,
      isLocalOriginalCached: true,
      isTrashed: false,
      createdAt: now - 900,
      updatedAt: now - 900,
      updatedHLC: 3,
    };
    const a4: AssetRecord = {
      id: '20000000-0000-4000-8000-000000000004',
      contentHash: 'hash4',
      folderID: fUi.id,
      mediaKind: 'image',
      mimeType: 'image/png',
      title: '超长信息图预览',
      fileName: 'long-strip-ui.png',
      notes: '长条形网页落地页截图',
      tags: ['landing-page'],
      suggestedTags: [],
      rating: 5,
      pixelWidth: 800,
      pixelHeight: 2800,
      fileSizeBytes: 620_000,
      dominantColors: [{ hex: '#3D5A80', l: 38, a: -2, b: -24, proportion: 1.0 }],
      waveformPeaks: [],
      pinnedOffline: false,
      isLocalOriginalCached: true,
      isTrashed: false,
      createdAt: now - 300,
      updatedAt: now - 300,
      updatedHLC: 4,
    };

    this.assets = [a1, a2, a3, a4];
    this.textContent.set(a3.id, '# Charkle 设计系统笔记\n\n- 90–95% 中性画布\n- 严禁紫罗兰渐变\n- 4pt 网格与同心圆角');
    this.thumbs.set(a1.id, makeSvgDataUrl('#BA6B55', '#F2ECE3', a1.title, 400, 533));
    this.thumbs.set(a2.id, makeSvgDataUrl('#141824', '#2A60E0', a2.title, 520, 260));
    this.thumbs.set(a3.id, makeSvgDataUrl('#1E2024', '#5B8DEF', a3.title, 400, 500));
    this.thumbs.set(a4.id, makeSvgDataUrl('#192438', '#4E7D96', a4.title, 400, 1400));

    this.smartFolders = [
      {
        id: '30000000-0000-4000-8000-000000000001',
        name: '高分精选',
        colorHex: '#2A60E0',
        rule: {
          matchMode: 'all',
          tags: [],
          descriptionQuery: '',
          colorHexes: [],
          colorTolerance: 24,
          mediaKinds: [],
          minRating: 5,
        },
        sortOrder: 0,
        createdAt: now,
        updatedAt: now,
      },
    ];

    this.boards = [
      {
        id: '40000000-0000-4000-8000-000000000001',
        title: '光、纸与泥 · Light, Paper & Clay',
        subtitle: '材质与构图参考',
        mode: { freeform: {} },
        nodes: [],
        connectors: [],
        inkStrokes: [],
        extractedPalette: a1.dominantColors,
        candidateAssetIDs: [a1.id],
        pinnedOffline: false,
        viewportCenter: { x: 480, y: 320 },
        viewportZoom: 1,
        createdAt: now,
        updatedAt: now,
        updatedHLC: 1,
      },
    ];
  }

  thumbnailUrl(assetId: string): string {
    return this.thumbs.get(assetId) ?? makeSvgDataUrl('#24272C', '#5B8DEF', 'Charkle');
  }

  originalUrl(assetId: string): string {
    return this.thumbnailUrl(assetId);
  }

  captureFrameUrl(_token: string): string {
    return makeSvgDataUrl('#141517', '#2A60E0', 'Desktop Snapshot', 1920, 1080);
  }

  async fetchAssets(criteria: FilterCriteria): Promise<AssetRecord[]> {
    let list = [...this.assets];
    if (criteria.onlyTrashed) {
      list = list.filter((a) => a.isTrashed);
    } else if (!criteria.includeTrashed) {
      list = list.filter((a) => !a.isTrashed);
    }
    if (criteria.onlyInbox) {
      list = list.filter((a) => !a.folderID);
    } else if (criteria.folderID) {
      const ids = new Set<string>([criteria.folderID]);
      if (criteria.includeSubfolders) {
        let added = true;
        while (added) {
          added = false;
          for (const f of this.folders) {
            if (f.parentID && ids.has(f.parentID) && !ids.has(f.id)) {
              ids.add(f.id);
              added = true;
            }
          }
        }
      }
      list = list.filter((a) => a.folderID && ids.has(a.folderID));
    }
    if (criteria.onlyUntagged) list = list.filter((a) => a.tags.length === 0);
    if (criteria.onlyPinnedOffline) list = list.filter((a) => a.pinnedOffline);
    if (criteria.kinds.length > 0) list = list.filter((a) => criteria.kinds.includes(a.mediaKind));
    if (criteria.minRating > 0) list = list.filter((a) => a.rating >= criteria.minRating);
    if (criteria.tags.length > 0) {
      list = list.filter((a) =>
        criteria.tags.every((t) => a.tags.some((at) => at.toLowerCase() === t.toLowerCase())),
      );
    }
    if (criteria.searchQuery.trim()) {
      const q = criteria.searchQuery.trim().toLowerCase();
      list = list.filter((a) =>
        [a.title, a.fileName, a.notes, a.tags.join(' '), a.richMetadata?.githubRepo?.readmeMarkdown ?? '']
          .join(' ')
          .toLowerCase()
          .includes(q),
      );
    }
    if (criteria.sortBy === 'oldest') {
      list.sort((a, b) => wireDateToMs(a.createdAt) - wireDateToMs(b.createdAt));
    } else if (criteria.sortBy === 'nameAsc') {
      list.sort((a, b) => a.title.localeCompare(b.title));
    } else if (criteria.sortBy === 'ratingDesc') {
      list.sort((a, b) => b.rating - a.rating);
    } else if (criteria.sortBy === 'fileSizeDesc') {
      list.sort((a, b) => b.fileSizeBytes - a.fileSizeBytes);
    } else {
      list.sort((a, b) => wireDateToMs(b.createdAt) - wireDateToMs(a.createdAt));
    }
    return list;
  }

  async fetchAsset(id: string): Promise<AssetRecord | null> {
    return this.assets.find((a) => a.id === id) ?? null;
  }

  async ingestFiles(paths: string[], targetFolderId?: string | null): Promise<AssetRecord[]> {
    const now = msToCocoaSeconds(Date.now());
    const created = paths.map((p) => {
      const name = p.split(/[\\/]/).pop() ?? 'Untitled.png';
      const id = makeUuid();
      const asset: AssetRecord = {
        id,
        contentHash: id,
        folderID: targetFolderId ?? null,
        mediaKind: 'image',
        mimeType: 'image/png',
        title: name.replace(/\.[^.]+$/, ''),
        fileName: name,
        notes: '',
        tags: [],
        suggestedTags: [],
        rating: 0,
        pixelWidth: 800,
        pixelHeight: 600,
        fileSizeBytes: 12000,
        dominantColors: [{ hex: '#2A60E0', l: 44, a: 18, b: -58, proportion: 1 }],
        waveformPeaks: [],
        pinnedOffline: false,
        isLocalOriginalCached: true,
        isTrashed: false,
        createdAt: now,
        updatedAt: now,
        updatedHLC: 10,
      };
      this.thumbs.set(id, makeSvgDataUrl('#24272C', '#2A60E0', asset.title));
      return asset;
    });
    this.assets = [...created, ...this.assets];
    return created;
  }

  async ingestUrl(url: string, title?: string | null, notes?: string | null, targetFolderId?: string | null): Promise<AssetRecord[]> {
    const now = msToCocoaSeconds(Date.now());
    const id = makeUuid();
    const isXiaohongshu = /(?:^|\/\/)(?:[^/]*\.)?(?:xiaohongshu\.com|xhslink\.com)\b/i.test(url);
    if (isXiaohongshu) {
      const noteTitle = title?.trim() || '小红书视觉灵感笔记';
      const coverUrl = makeSvgDataUrl('#F8F5F1', '#FF2442', noteTitle, 900, 1200);
      const asset: AssetRecord = {
        id,
        contentHash: id,
        folderID: targetFolderId ?? null,
        mediaKind: 'webBookmark',
        mimeType: 'text/uri-list',
        title: noteTitle,
        fileName: 'xiaohongshu-note.url',
        notes: notes ?? '',
        tags: ['小红书'],
        suggestedTags: [],
        rating: 0,
        pixelWidth: 900,
        pixelHeight: 1440,
        fileSizeBytes: 512,
        dominantColors: [{ hex: '#FF2442', l: 54, a: 74, b: 40, proportion: 0.4 }],
        waveformPeaks: [],
        sourceURL: url,
        sourceDomain: 'www.xiaohongshu.com',
        richMetadata: {
          socialPost: {
            platform: 'xiaohongshu',
            authorName: '小红书创作者',
            authorHandle: '',
            articleTitle: noteTitle,
            bodyText: notes?.trim() || '已通过链接采集的小红书视觉笔记。',
            mediaURLs: [coverUrl],
            mediaThumbnailURLs: [coverUrl],
            attachments: [{ id: `${id}-img-0`, kind: 'photo', url: coverUrl, thumbnailURL: coverUrl }],
            hasVideo: false,
            likeCount: 1280,
            originalURL: url,
          },
        },
        pinnedOffline: false,
        isLocalOriginalCached: true,
        isTrashed: false,
        createdAt: now,
        updatedAt: now,
        updatedHLC: 11,
      };
      this.thumbs.set(id, makeSvgDataUrl('#FFFFFF', '#FF2442', noteTitle, 900, 1440));
      this.assets = [asset, ...this.assets];
      return [asset];
    }
    const asset: AssetRecord = {
      id,
      contentHash: id,
      folderID: targetFolderId ?? null,
      mediaKind: 'webBookmark',
      mimeType: 'text/uri-list',
      title: title || url,
      fileName: 'bookmark.url',
      notes: notes ?? '',
      tags: [],
      suggestedTags: [],
      rating: 0,
      pixelWidth: 1200,
      pixelHeight: 630,
      fileSizeBytes: 256,
      dominantColors: [],
      waveformPeaks: [],
      sourceURL: url,
      sourceDomain: url.replace(/^https?:\/\//, '').split('/')[0] ?? '',
      pinnedOffline: false,
      isLocalOriginalCached: true,
      isTrashed: false,
      createdAt: now,
      updatedAt: now,
      updatedHLC: 11,
    };
    this.thumbs.set(id, makeSvgDataUrl('#1E2025', '#5B8DEF', asset.title));
    this.assets = [asset, ...this.assets];
    return [asset];
  }

  async ingestText(title: string, text: string, _sourceUrl?: string | null, targetFolderId?: string | null): Promise<AssetRecord[]> {
    const now = msToCocoaSeconds(Date.now());
    const id = makeUuid();
    const asset: AssetRecord = {
      id,
      contentHash: id,
      folderID: targetFolderId ?? null,
      mediaKind: 'document',
      mimeType: 'text/markdown',
      title: title || '文本笔记',
      fileName: `${title || 'note'}.md`,
      notes: '',
      tags: [],
      suggestedTags: [],
      rating: 0,
      pixelWidth: 640,
      pixelHeight: 800,
      fileSizeBytes: text.length,
      dominantColors: [],
      waveformPeaks: [],
      richMetadata: { isMarkdown: true, textExcerpt: text.slice(0, 400) },
      pinnedOffline: false,
      isLocalOriginalCached: true,
      isTrashed: false,
      createdAt: now,
      updatedAt: now,
      updatedHLC: 12,
    };
    this.textContent.set(id, text);
    this.thumbs.set(id, makeSvgDataUrl('#1E2025', '#6B8E76', asset.title));
    this.assets = [asset, ...this.assets];
    return [asset];
  }

  async ingestSwatch(hex: string, title?: string | null, targetFolderId?: string | null): Promise<AssetRecord[]> {
    const now = msToCocoaSeconds(Date.now());
    const id = makeUuid();
    const clean = hex.startsWith('#') ? hex.toUpperCase() : `#${hex.toUpperCase()}`;
    const asset: AssetRecord = {
      id,
      contentHash: id,
      folderID: targetFolderId ?? null,
      mediaKind: 'image',
      mimeType: 'image/png',
      title: title || clean,
      fileName: `${clean}.png`,
      notes: '',
      tags: [],
      suggestedTags: [],
      rating: 0,
      pixelWidth: 600,
      pixelHeight: 600,
      fileSizeBytes: 2048,
      dominantColors: [{ hex: clean, l: 50, a: 0, b: 0, proportion: 1 }],
      waveformPeaks: [],
      pinnedOffline: false,
      isLocalOriginalCached: true,
      isTrashed: false,
      createdAt: now,
      updatedAt: now,
      updatedHLC: 13,
    };
    this.thumbs.set(id, makeSvgDataUrl(clean, '#ffffff', asset.title, 400, 400));
    this.assets = [asset, ...this.assets];
    return [asset];
  }

  async ingestImageBase64(_dataBase64: string, suggestedName: string, _sourceUrl?: string | null, targetFolderId?: string | null): Promise<AssetRecord[]> {
    return this.ingestFiles([suggestedName], targetFolderId);
  }

  async updateAssets(patch: AssetBatchPatch): Promise<AssetRecord[]> {
    const changed: AssetRecord[] = [];
    this.assets = this.assets.map((a) => {
      if (!patch.assetIDs.includes(a.id)) return a;
      const next: AssetRecord = { ...a };
      if (patch.title) next.title = patch.title;
      if (patch.notes != null) next.notes = patch.notes;
      if (patch.rating != null) next.rating = patch.rating;
      if (patch.pinnedOffline != null) next.pinnedOffline = patch.pinnedOffline;
      if (patch.isTrashed != null) next.isTrashed = patch.isTrashed;
      if (patch.folderAssignment === 'inbox') next.folderID = null;
      else if (patch.folderAssignment && typeof patch.folderAssignment === 'object') {
        next.folderID = patch.folderAssignment.folder;
      }
      const tags = new Set(next.tags);
      if (patch.acceptSuggestedTags) {
        for (const s of next.suggestedTags) tags.add(s);
        next.suggestedTags = [];
      }
      for (const t of patch.addTags ?? []) tags.add(t.trim());
      for (const t of patch.removeTags ?? []) tags.delete(t.trim());
      next.tags = [...tags].filter(Boolean).sort();
      changed.push(next);
      return next;
    });
    return changed;
  }

  async permanentlyDeleteAssets(ids: string[]): Promise<void> {
    const del = new Set(ids);
    this.assets = this.assets.filter((a) => !del.has(a.id));
  }

  async markAssetOpened(id: string): Promise<AssetRecord | null> {
    const asset = this.assets.find((a) => a.id === id);
    if (asset) asset.lastOpenedAt = msToCocoaSeconds(Date.now());
    return asset ?? null;
  }

  async similarAssets(assetId: string, limit = 12): Promise<ScoredAsset[]> {
    const anchor = this.assets.find((a) => a.id === assetId);
    if (!anchor) return [];
    const anchorTags = new Set(
      [...anchor.tags, ...anchor.suggestedTags].map((t) => t.trim().toLowerCase()).filter(Boolean),
    );
    const anchorPrimary = anchor.dominantColors[0];
    const scored: ScoredAsset[] = [];
    for (const cand of this.assets) {
      if (cand.id === assetId || cand.isTrashed) continue;
      const reasons: string[] = [];
      let score = 0;
      const candTags = new Set(
        [...cand.tags, ...cand.suggestedTags].map((t) => t.trim().toLowerCase()).filter(Boolean),
      );
      const shared = [...anchorTags].filter((t) => candTags.has(t));
      if (shared.length > 0) {
        const jaccard = shared.length / Math.max(1, new Set([...anchorTags, ...candTags]).size);
        if (jaccard >= 0.18) {
          score += jaccard * 0.55;
          reasons.push(`相同标签：${shared.slice(0, 2).join('、')}`);
        }
      }
      const candPrimary = cand.dominantColors[0];
      if (anchorPrimary && candPrimary) {
        const de = Math.hypot(
          anchorPrimary.l - candPrimary.l,
          anchorPrimary.a - candPrimary.a,
          anchorPrimary.b - candPrimary.b,
        );
        if (de < 22) {
          score += ((22 - de) / 22) * 0.45;
          reasons.push('配色相近');
        }
      }
      if (reasons.length > 0 && score >= 0.24) {
        scored.push({ asset: cand, score: Math.min(1, score), matchReasons: reasons });
      }
    }
    scored.sort((a, b) => b.score - a.score);
    return scored.slice(0, limit);
  }

  async suggestFolder(assetId: string): Promise<FolderSuggestion | null> {
    const asset = this.assets.find((a) => a.id === assetId);
    if (!asset || this.folders.length === 0) return null;
    const hay = `${asset.title} ${asset.notes} ${asset.tags.join(' ')} ${asset.suggestedTags.join(' ')}`.toLowerCase();
    const words = new Set(hay.match(/[a-z0-9]{2,}/g) ?? []);
    const assetTags = new Set(
      [...asset.tags, ...asset.suggestedTags].map((t) => t.trim().toLowerCase()).filter(Boolean),
    );
    let best: FolderSuggestion | null = null;
    for (const folder of this.folders) {
      if (folder.id === asset.folderID) continue;
      let score = 0;
      let reason = '';
      const fname = folder.name.trim().toLowerCase();
      const fWords = fname.match(/[a-z0-9]{2,}/g) ?? [];
      if (fname && !/^[\x00-\x7f]+$/.test(fname) && hay.includes(fname)) {
        score = 0.84;
        reason = `标题或标签与目录「${folder.name}」主题吻合`;
      } else if (fWords.length > 0 && fWords.every((w) => words.has(w))) {
        score = 0.82;
        reason = `标题或标签与目录「${folder.name}」主题吻合`;
      }
      const peers = this.assets.filter((a) => !a.isTrashed && a.folderID === folder.id && a.id !== asset.id);
      let sharedTag: string | null = null;
      for (const peer of peers) {
        for (const tag of peer.tags) {
          if (assetTags.has(tag.trim().toLowerCase())) {
            sharedTag = tag;
            break;
          }
        }
        if (sharedTag) break;
      }
      if (sharedTag && score < 0.72) {
        score = 0.72;
        reason = `与「${folder.name}」中标签「${sharedTag}」一致`;
      }
      if (score >= 0.34 && (!best || score > best.confidence)) {
        best = {
          folderID: folder.id,
          folderName: folder.name,
          confidence: score,
          reason,
        };
      }
    }
    return best;
  }

  async hydrateImageMetadata(id: string): Promise<AssetRecord | null> {
    return this.fetchAsset(id);
  }

  async refreshRichAsset(id: string): Promise<AssetRecord> {
    const found = this.assets.find((a) => a.id === id);
    if (!found) throw new Error('Asset not found');
    return found;
  }

  async fetchFolders(): Promise<FolderRecord[]> {
    return this.folders.map((f) => ({
      ...f,
      assetCount: this.assets.filter((a) => !a.isTrashed && a.folderID === f.id).length,
    }));
  }

  async createFolder(name: string, parentId?: string | null): Promise<FolderRecord> {
    const now = msToCocoaSeconds(Date.now());
    const f: FolderRecord = {
      id: makeUuid(),
      name,
      parentID: parentId ?? null,
      sortOrder: this.folders.length,
      assetCount: 0,
      createdAt: now,
      updatedAt: now,
    };
    this.folders = [...this.folders, f];
    return f;
  }

  async renameFolder(id: string, newName: string): Promise<FolderRecord> {
    const found = this.folders.find((f) => f.id === id);
    if (!found) throw new Error('Folder not found');
    found.name = newName;
    return { ...found };
  }

  async moveFolder(id: string, newParentId: string | null): Promise<FolderRecord[]> {
    this.folders = this.folders.map((f) => (f.id === id ? { ...f, parentID: newParentId } : f));
    return this.fetchFolders();
  }

  async updateFolderAppearance(id: string, colorHex: string | null, customSymbol: string | null): Promise<FolderRecord> {
    const found = this.folders.find((f) => f.id === id);
    if (!found) throw new Error('Folder not found');
    found.colorHex = colorHex;
    found.customSymbol = customSymbol;
    return { ...found };
  }

  async deleteFolder(id: string, trashContents = false): Promise<void> {
    this.folders = this.folders.filter((f) => f.id !== id);
    this.assets = this.assets.map((a) =>
      a.folderID === id ? { ...a, folderID: null, isTrashed: trashContents ? true : a.isTrashed } : a,
    );
  }

  async fetchSmartFolders(): Promise<SmartFolderRecord[]> {
    return [...this.smartFolders];
  }

  async saveSmartFolder(folder: SmartFolderRecord): Promise<SmartFolderRecord[]> {
    const exists = this.smartFolders.some((s) => s.id === folder.id);
    this.smartFolders = exists
      ? this.smartFolders.map((s) => (s.id === folder.id ? folder : s))
      : [...this.smartFolders, folder];
    return [...this.smartFolders];
  }

  async deleteSmartFolder(id: string): Promise<SmartFolderRecord[]> {
    this.smartFolders = this.smartFolders.filter((s) => s.id !== id);
    return [...this.smartFolders];
  }

  async fetchTagCounts(): Promise<TagCount[]> {
    const counts = new Map<string, number>();
    for (const a of this.assets) {
      if (a.isTrashed) continue;
      for (const t of a.tags) counts.set(t, (counts.get(t) ?? 0) + 1);
    }
    return [...counts.entries()]
      .map(([name, count]) => ({ name, count }))
      .sort((a, b) => b.count - a.count || a.name.localeCompare(b.name));
  }

  async inboxCount(): Promise<number> {
    return this.assets.filter((a) => !a.isTrashed && !a.folderID).length;
  }

  async quickJump(query: string, limit = 24): Promise<QuickJumpMatch[]> {
    const q = query.trim().toLowerCase();
    const out: QuickJumpMatch[] = [];
    for (const f of this.folders) {
      if (!q || f.name.toLowerCase().includes(q)) {
        out.push({ id: `folder-${f.id}`, kind: 'folder', title: f.name, subtitle: '文件夹', targetUUID: f.id, score: 0.9 });
      }
    }
    for (const b of this.boards) {
      if (!q || b.title.toLowerCase().includes(q)) {
        out.push({ id: `moodboard-${b.id}`, kind: 'moodboard', title: b.title, subtitle: `情绪板 · ${b.nodes.length} 项`, targetUUID: b.id, score: 0.85 });
      }
    }
    for (const t of await this.fetchTagCounts()) {
      if (!q || t.name.toLowerCase().includes(q)) {
        out.push({ id: `tag-${t.name}`, kind: 'tag', title: t.name, subtitle: `标签 · ${t.count} 项`, tagName: t.name, score: 0.8 });
      }
    }
    for (const a of this.assets.filter((x) => !x.isTrashed)) {
      if (!q || a.title.toLowerCase().includes(q) || a.notes.toLowerCase().includes(q)) {
        out.push({ id: `asset-${a.id}`, kind: 'asset', title: a.title, subtitle: a.fileName, targetUUID: a.id, score: 0.75 });
      }
    }
    return out.slice(0, limit);
  }

  async fetchBoards(): Promise<MoodboardSummary[]> {
    return this.boards.map((b) => {
      const refIds = b.nodes
        .map((n) => ('assetRef' in n.kind ? n.kind.assetRef.assetID : null))
        .filter((x): x is string => Boolean(x));
      return {
        id: b.id,
        title: b.title,
        subtitle: b.subtitle,
        mode: b.mode,
        itemCount: b.nodes.length,
        previewAssetIDs: (refIds.length > 0 ? refIds : b.candidateAssetIDs).slice(0, 4),
        paletteHexes: b.extractedPalette.map((c) => c.hex),
        pinnedOffline: b.pinnedOffline,
        updatedAt: b.updatedAt,
      };
    });
  }

  async fetchBoard(id: string): Promise<MoodboardDocument | null> {
    return this.boards.find((b) => b.id === id) ?? null;
  }

  async saveBoard(doc: MoodboardDocument): Promise<MoodboardDocument> {
    const idx = this.boards.findIndex((b) => b.id === doc.id);
    if (idx >= 0) this.boards[idx] = doc;
    else this.boards.push(doc);
    return doc;
  }

  async deleteBoard(id: string): Promise<void> {
    this.boards = this.boards.filter((b) => b.id !== id);
  }

  async setBoardPinnedOffline(id: string, pinned: boolean): Promise<MoodboardDocument> {
    const b = this.boards.find((x) => x.id === id);
    if (!b) throw new Error('Board not found');
    b.pinnedOffline = pinned;
    return { ...b };
  }

  async seedSampleLibraryIfEmpty(): Promise<boolean> {
    return false;
  }

  async cacheStats(): Promise<CacheStats> {
    return {
      thumbnailBytes: 1_200_000,
      originalCacheBytes: 12_400_000,
      pinnedOfflineBytes: 245_000,
      budgetBytes: 10 * 1024 * 1024 * 1024,
      cachedOriginalCount: this.assets.length,
      pinnedAssetCount: this.assets.filter((a) => a.pinnedOffline).length,
    };
  }

  async setCacheBudgetBytes(bytes: number): Promise<number> {
    return bytes;
  }

  async evictCacheNow(): Promise<CacheStats> {
    return this.cacheStats();
  }

  async readAssetTextContent(id: string): Promise<string | null> {
    return this.textContent.get(id) ?? null;
  }

  private mockHasGoogleOAuthClient = false;
  private mockHasWebdavPassword = false;
  private mockGoogleAccountEmail: string | null = null;

  async revealInExplorer(): Promise<void> {}
  async openDirectoryInExplorer(): Promise<void> {}
  async openExternalUrl(): Promise<void> {}
  async pickFilesDialog(): Promise<string[]> {
    return [];
  }
  async pickJsonFileDialog(): Promise<string | null> {
    return 'mock-exports/client_secret.json';
  }

  public mockICloudAvailability: ICloudDriveAvailability = {
    isUbiquityContainerAvailable: false,
    ubiquityDocumentsPath: null,
    systemCloudDocsPath: '%USERPROFILE%\\iCloudDrive',
    defaultDisplayLocation: 'iCloud Drive / Charkle',
  };
  private mockBackendWebdavPasswords = new Map<string, string>();
  private mockBackendLastSynced = new Map<string, number>();

  async syncConfig(): Promise<DriveSyncConfig> {
    return {
      ...this.syncCfg,
      backends: this.syncCfg.backends ? this.syncCfg.backends.map((b) => ({ ...b })) : undefined,
    };
  }

  async saveSyncConfig(config: DriveSyncConfig): Promise<void> {
    this.syncCfg = synchronizePrimaryFields({ ...config });
  }

  async syncStatus(): Promise<SyncStatus> {
    const resolved = resolveBackends(this.syncCfg);
    const backendStatuses: SyncBackendStatus[] = resolved.map((profile) => {
      const lastSyncedAt = this.mockBackendLastSynced.get(profile.id) ?? null;
      return {
        backendID: profile.id,
        name: profile.name?.trim() || profile.mode,
        mode: profile.mode,
        isEnabled: profile.isEnabled,
        isPrimary: profile.isPrimary,
        locationSummary: backendLocationSummary(profile),
        phase: 'idle',
        lastSyncedAt,
        lastError: null,
        currentDetail: null,
        progressFraction: null,
        account:
          profile.mode === 'iCloudDrive'
            ? {
                email: backendLocationSummary(profile),
                displayName: 'iCloud Drive',
                source: 'iCloud Drive',
              }
            : profile.mode === 'directAPIWithGDirect' && this.mockGoogleAccountEmail
              ? {
                  email: this.mockGoogleAccountEmail,
                  displayName: 'Charkle Designer',
                  source: 'Google Drive API',
                }
              : null,
      };
    });

    const primaryAccount =
      this.syncCfg.mode === 'iCloudDrive'
        ? {
            email: backendLocationSummary(resolved[0]),
            displayName: 'iCloud Drive',
            source: 'iCloud Drive',
          }
        : this.syncCfg.mode === 'directAPIWithGDirect' && this.mockGoogleAccountEmail
          ? {
              email: this.mockGoogleAccountEmail,
              displayName: 'Charkle Designer',
              source: 'Google Drive API',
            }
          : null;

    return {
      phase: 'idle',
      pendingOpCount: 0,
      activeMode: this.syncCfg.mode,
      account: primaryAccount,
      backendStatuses,
    };
  }

  async syncNow(): Promise<SyncReport> {
    const now = msToCocoaSeconds(Date.now());
    for (const b of resolveBackends(this.syncCfg)) {
      if (b.isEnabled) {
        this.mockBackendLastSynced.set(b.id, now);
      }
    }
    return {
      uploadedOps: 0,
      downloadedOps: 0,
      discoveredRemoteAssets: 0,
      discoveredAssetIDs: [],
      updatedBoards: 0,
      reconciledRenames: 0,
      durationSeconds: 0.01,
    };
  }

  async getSyncAuthState(): Promise<SyncAuthStateDto> {
    return {
      hasGoogleOAuthClient: this.mockHasGoogleOAuthClient,
      hasWebdavPassword: this.mockHasWebdavPassword,
    };
  }

  async saveGoogleOAuthClient(clientId: string): Promise<boolean> {
    if (!clientId.trim()) throw new Error('请输入有效的 Google OAuth Client ID。');
    this.mockHasGoogleOAuthClient = true;
    return true;
  }

  async importGoogleOAuthSecretFile(filePath: string): Promise<boolean> {
    if (!filePath.trim()) throw new Error('请选择有效的 JSON 凭证文件。');
    this.mockHasGoogleOAuthClient = true;
    return true;
  }

  async signInGoogleDrive(): Promise<SyncStatus> {
    this.mockHasGoogleOAuthClient = true;
    this.mockGoogleAccountEmail = 'designer@example.com';
    return this.syncStatus();
  }

  async signOutGoogleDrive(): Promise<SyncStatus> {
    this.mockGoogleAccountEmail = null;
    return this.syncStatus();
  }

  async testWebdavConnection(
    config: DriveSyncConfig,
    password?: string | null,
  ): Promise<WebdavTestResultDto> {
    if (password && password.trim()) {
      this.mockHasWebdavPassword = true;
    }
    if (!config.webDAVServerURL.trim()) {
      return { ok: false, message: '请输入有效的 WebDAV 服务器地址。' };
    }
    return { ok: true, message: '连接成功，远程目录可正常访问。' };
  }

  async probeICloudDriveAvailability(): Promise<ICloudDriveAvailability> {
    return { ...this.mockICloudAvailability };
  }

  async saveBackendWebdavPassword(backendId: string, password: string): Promise<void> {
    const trimmed = password.trim();
    if (trimmed) {
      this.mockBackendWebdavPasswords.set(backendId, trimmed);
      this.mockHasWebdavPassword = true;
    } else {
      this.mockBackendWebdavPasswords.delete(backendId);
    }
  }

  async hasBackendWebdavPassword(backendId: string): Promise<boolean> {
    return this.mockBackendWebdavPasswords.has(backendId) || this.mockHasWebdavPassword;
  }

  async testBackendConnection(
    profile: SyncBackendProfile,
    webdavPassword?: string | null,
  ): Promise<BackendTestResultDto> {
    if (profile.mode === 'webDAV') {
      if (webdavPassword && webdavPassword.trim()) {
        this.mockBackendWebdavPasswords.set(profile.id, webdavPassword.trim());
      }
      if (!profile.webDAVServerURL.trim()) {
        return { ok: false, message: '请输入有效的 WebDAV 服务器地址。', account: null };
      }
      const account = {
        email: profile.webDAVUsername || profile.webDAVServerURL,
        displayName: profile.name || 'WebDAV',
        source: 'WebDAV',
      };
      return { ok: true, message: `连接成功：${account.displayName}（WebDAV）`, account };
    }
    if (profile.mode === 'iCloudDrive') {
      const hasPath =
        Boolean(profile.iCloudCustomFolderPath.trim()) ||
        Boolean(this.mockICloudAvailability.systemCloudDocsPath) ||
        this.mockICloudAvailability.isUbiquityContainerAvailable;
      if (!hasPath) {
        return {
          ok: false,
          message: '未检测到本机 iCloud Drive 目录，请先安装 Windows 版 iCloud 或手动选择目录。',
          account: null,
        };
      }
      const account = {
        email: backendLocationSummary(profile),
        displayName: 'iCloud Drive',
        source: 'iCloud Drive',
      };
      return { ok: true, message: `连接成功：${account.email}（iCloud Drive）`, account };
    }
    if (profile.mode === 'localOnly') {
      if (!profile.localLibraryPath.trim()) {
        return { ok: false, message: '请选择有效的本机目录路径。', account: null };
      }
      const account = {
        email: profile.localLibraryPath,
        displayName: profile.name || '本地文件夹',
        source: 'Local Folder',
      };
      return { ok: true, message: `连接成功：${profile.localLibraryPath}`, account };
    }
    const account = {
      email: this.mockGoogleAccountEmail ?? 'designer@example.com',
      displayName: 'Charkle Designer',
      source: 'Google Drive API',
    };
    return { ok: true, message: `连接成功：${account.email}（Google Drive）`, account };
  }

  async syncBackend(backendId: string): Promise<SyncReport> {
    this.mockBackendLastSynced.set(backendId, msToCocoaSeconds(Date.now()));
    return {
      uploadedOps: 1,
      downloadedOps: 0,
      discoveredRemoteAssets: 0,
      discoveredAssetIDs: [],
      updatedBoards: 0,
      reconciledRenames: 0,
      durationSeconds: 0.02,
    };
  }

  public mockSystemAccentHex: string | null = '#0078D4';
  private surfaceListeners = new Set<(state: WindowSurfaceState) => void>();

  async setWindowTheme(isDark: boolean): Promise<WindowSurfaceState> {
    return {
      buildNumber: 22631,
      backdrop: 'mica',
      isDark,
      transparencyEnabled: true,
      animationsEnabled: true,
      snapLayoutsSupported: true,
      systemAccentHex: this.mockSystemAccentHex,
    };
  }

  async setMaximizeButtonRect(): Promise<void> {}
  async windowMinimize(): Promise<void> {}
  async windowToggleMaximize(): Promise<boolean> {
    this.maximized = !this.maximized;
    return this.maximized;
  }
  async windowClose(): Promise<void> {}
  async windowIsMaximized(): Promise<boolean> {
    return this.maximized;
  }
  public lastWindowResizeDirection: WindowResizeDirection | null = null;
  async windowStartResize(direction: WindowResizeDirection): Promise<void> {
    this.lastWindowResizeDirection = direction;
  }

  async startOutboundDrag(assetIds: string[]): Promise<DragOutOutcome> {
    this.lastOutboundDragIds = [...assetIds];
    return assetIds.length > 0 ? 'copied' : 'cancelled';
  }

  async setShelfHitRect(rect: ClientRect | null): Promise<void> {
    this.lastShelfHitRect = rect;
  }

  async toggleShelf(): Promise<boolean> {
    this.shelfVisible = !this.shelfVisible;
    return this.shelfVisible;
  }

  async showShelf(pinned = false): Promise<void> {
    this.shelfVisible = true;
    if (pinned) this.shelfPinned = true;
  }

  async hideShelf(): Promise<void> {
    this.shelfVisible = false;
    this.shelfPinned = false;
  }

  async setShelfPinned(pinned: boolean): Promise<boolean> {
    this.shelfPinned = pinned;
    return this.shelfPinned;
  }

  async startRegionCapture(
    targetFolderId?: string | null,
    targetBoardId?: string | null,
  ): Promise<CaptureSessionInfo> {
    return {
      token: 'MOCK-CAPTURE-TOKEN',
      bounds: { left: 0, top: 0, width: 1920, height: 1080 },
      monitors: [
        {
          index: 0,
          left: 0,
          top: 0,
          width: 1920,
          height: 1080,
          dpiX: 96,
          dpiY: 96,
          scaleFactor: 1,
          isPrimary: true,
        },
      ],
      width: 1920,
      height: 1080,
      targetFolderId: targetFolderId ?? null,
      targetBoardId: targetBoardId ?? null,
    };
  }

  async getCaptureSession(token: string): Promise<CaptureSessionInfo | null> {
    return {
      token,
      bounds: { left: 0, top: 0, width: 1920, height: 1080 },
      monitors: [
        {
          index: 0,
          left: 0,
          top: 0,
          width: 1920,
          height: 1080,
          dpiX: 96,
          dpiY: 96,
          scaleFactor: 1,
          isPrimary: true,
        },
      ],
      width: 1920,
      height: 1080,
    };
  }

  async commitRegionCapture(
    token: string,
    x: number,
    y: number,
    width: number,
    height: number,
    targetFolderId?: string | null,
  ): Promise<AssetRecord[]> {
    this.lastCommittedCrop = { token, x, y, width, height };
    return this.ingestFiles([`screenshot-${width}x${height}.png`], targetFolderId);
  }

  async cancelRegionCapture(_token: string): Promise<void> {}

  async collectClipboardNow(targetFolderId?: string | null): Promise<number> {
    if (this.clipboardPreview?.url) {
      await this.ingestUrl(this.clipboardPreview.url, null, null, targetFolderId);
      return 1;
    }
    return 0;
  }

  async getClipboardPreview(): Promise<ClipboardPreview | null> {
    return this.clipboardPreview;
  }

  async getDesktopIntegrationStatus(): Promise<DesktopIntegrationStatus> {
    return {
      hotkeys: { ...this.hotkeyConfig },
      autostartEnabled: this.autostartEnabled,
      trayActive: true,
      deepLinkScheme: 'charkle',
      ocr: {
        availableLanguages: ['zh-Hans-CN', 'en-US'],
        selectedLanguage: 'zh-Hans-CN',
        hasChinese: true,
        hasEnglish: true,
        diagnosticMessage: null,
      },
      gdirectPath: null,
      shelfVisible: this.shelfVisible,
      shelfPinned: this.shelfPinned,
    };
  }

  async setAutostartEnabled(enabled: boolean): Promise<boolean> {
    this.autostartEnabled = enabled;
    return this.autostartEnabled;
  }

  async updateHotkeys(config: HotkeyConfig): Promise<HotkeyConfig> {
    this.hotkeyConfig = { ...config };
    return { ...this.hotkeyConfig };
  }

  async getOcrDiagnostics(): Promise<OcrDiagnostics> {
    return {
      availableLanguages: ['zh-Hans-CN', 'en-US'],
      selectedLanguage: 'zh-Hans-CN',
      hasChinese: true,
      hasEnglish: true,
      diagnosticMessage: null,
    };
  }

  async runAssetOcr(id: string): Promise<AssetRecord | null> {
    const asset = this.assets.find((a) => a.id === id);
    if (!asset) return null;
    asset.ocrText = '识别文字：Charkle 视觉灵感参考';
    return { ...asset };
  }

  async focusMainWindow(): Promise<void> {}

  async openMainWindow(): Promise<void> {
    this.mockShelfSettings = { ...this.mockShelfSettings, minimalMode: false };
  }

  async curateMoodboard(request: MoodboardCurationRequest): Promise<MoodboardProposal> {
    const now = msToCocoaSeconds(Date.now());
    const active = this.assets.filter((a) => !a.isTrashed);
    const primaryAssets = active.slice(0, Math.min(request.preferredCount || 4, Math.max(2, active.length - 1)));
    const candidateAssets = active.filter((a) => !primaryAssets.some((p) => p.id === a.id));
    const palette = primaryAssets.flatMap((a) => a.dominantColors).slice(0, 6);

    const nodes = primaryAssets.map((a, idx) => ({
      id: makeUuid(),
      kind: {
        assetRef: {
          assetID: a.id,
          crop: null,
          weight: idx === 0 ? 2 : 1,
          autoplayLoop: true,
        },
      },
      frame: { x: 40 + (idx % 3) * 320, y: 40 + Math.floor(idx / 3) * 260, width: 290, height: 220 },
      zIndex: idx,
      rotationDegrees: 0,
      flipHorizontal: false,
      flipVertical: false,
      isLocked: false,
      editorialOrder: idx,
      updatedAt: now,
    }));

    const draftDocument: MoodboardDocument = {
      id: request.existingBoard?.id ?? makeUuid(),
      title: request.prompt.trim() || '智能灵感情绪板',
      subtitle: request.prompt.trim() ? `主题策展 · ${request.prompt.trim()}` : '色彩与构图精选',
      mode: request.useFreeformLayout
        ? { freeform: {} }
        : {
            autoEditorial: {
              _0: {
                columns: 3,
                spacing: 16,
                style: request.layoutStyle,
                showPaletteStrip: true,
              },
            },
          },
      nodes,
      connectors: [],
      inkStrokes: [],
      extractedPalette: palette,
      candidateAssetIDs: candidateAssets.map((a) => a.id),
      pinnedOffline: false,
      viewportCenter: { x: 560, y: 360 },
      viewportZoom: 1,
      createdAt: now,
      updatedAt: now,
      updatedHLC: Date.now(),
    };

    const phases: MoodboardAgentStep[] = [
      { id: makeUuid(), phase: 'planning', title: '拆解主题与构图策略', detail: '解析关键词与构图目标', status: 'done', timestamp: now },
      { id: makeUuid(), phase: 'retrieving', title: '召回候选素材与色彩匹配', detail: `召回 ${primaryAssets.length} 项主选 + ${candidateAssets.length} 项候选`, status: 'done', timestamp: now },
      { id: makeUuid(), phase: 'inspectingVisuals', title: '视觉构图与色板分析', detail: '完成色彩和谐度与 MMR 多样性评估', status: 'done', timestamp: now },
      { id: makeUuid(), phase: 'composing', title: '编排情绪板版面与策展分区', detail: `生成 ${nodes.length} 个画布节点`, status: 'done', timestamp: now },
      { id: makeUuid(), phase: 'verifying', title: '校验视觉均衡与坐标完整性', detail: '全部节点坐标有效', status: 'done', timestamp: now },
      { id: makeUuid(), phase: 'repairing', title: '版面微调与间距收敛', detail: '版面节奏均衡', status: 'done', timestamp: now },
      { id: makeUuid(), phase: 'fallbackOffline', title: '本地离线策展完成', detail: '已生成可编辑情绪板', status: 'done', timestamp: now },
    ];

    return {
      draftDocument,
      primaryMatches: primaryAssets.map((asset, i) => ({ asset, score: 0.95 - i * 0.05, matchReasons: ['主题契合', '色彩和谐'] })),
      candidatePool: candidateAssets.map((asset, i) => ({ asset, score: 0.8 - i * 0.04, matchReasons: ['风格补充'] })),
      extractedPalette: palette,
      usedCloudAi: false,
      curatedSummary: `围绕「${request.prompt || '当前灵感'}」生成 ${primaryAssets.length} 项主选素材与 ${candidateAssets.length} 项候选替换池`,
      agentTrace: phases,
      sections: [],
      rejectedSummary: null,
      cachedVisualInsightsCount: primaryAssets.length,
    };
  }

  async solveEditorialLayout(
    document: MoodboardDocument,
    containerWidth: number,
  ): Promise<EditorialLayoutResult> {
    const frames: Record<string, { x: number; y: number; width: number; height: number }> = {};
    document.nodes.forEach((n, i) => {
      frames[n.id] = { x: 28 + (i % 3) * 320, y: 28 + Math.floor(i / 3) * 260, width: 300, height: 220 };
    });
    return {
      frames,
      orderedNodeIds: document.nodes.map((n) => n.id),
      contentSize: { width: containerWidth, height: 680 },
      columnWidth: 300,
      columnCount: 3,
    };
  }

  async exportBoardImageFile(
    _document: MoodboardDocument,
    _options: MoodboardExportOptions,
    destinationPath: string,
  ): Promise<number> {
    this.lastExportedPath = destinationPath;
    return 128_000;
  }

  async copyBoardImageToClipboard(): Promise<number> {
    this.lastClipboardExportCount += 1;
    return 128_000;
  }

  async exportBoardFigmaBridge(
    document: MoodboardDocument,
    _options: MoodboardExportOptions,
    destinationPath: string,
  ): Promise<FigmaBridgeExportReport> {
    this.lastExportedPath = destinationPath;
    return {
      objectCount: document.nodes.length,
      imageCount: document.nodes.filter((n) => 'assetRef' in n.kind).length,
      noteCount: document.nodes.filter((n) => 'note' in n.kind).length,
      groupCount: document.nodes.filter((n) => 'groupFrame' in n.kind).length,
      paletteCount: document.nodes.filter((n) => 'paletteStrip' in n.kind).length,
      connectorCount: document.connectors.length,
      strokeCount: document.inkStrokes.length,
      reviewCount: 0,
      bundlePath: destinationPath,
    };
  }

  async saveFileDialog(defaultPath: string): Promise<string | null> {
    return `mock-exports/${defaultPath}`;
  }

  async pickDirectoryDialog(): Promise<string | null> {
    return 'mock-exports/selected-folder';
  }

  private mockAiState: AIProviderStateDto = {
    config: {
      provider: 'disabled',
      customEndpointFormat: 'openAIChatCompletions',
      baseURL: 'https://generativelanguage.googleapis.com',
      chatModel: 'gemini-2.5-flash',
      embeddingModel: 'gemini-embedding-001',
      autoAnalyzeOnImport: false,
      sendThumbnailsToCloud: true,
    },
    hasApiKey: false,
    chatgptSession: { status: 'disconnected', sharingEnabled: false },
    usage: {
      dayKey: '2026-11-23',
      todayRequests: 3,
      todayInputTokens: 420,
      todayOutputTokens: 110,
      todayTotalTokens: 530,
      totalRequests: 12,
      totalInputTokens: 1800,
      totalOutputTokens: 480,
      totalTokens: 2280,
      lastProviderLabel: 'Google Gemini',
      lastModel: 'gemini-2.5-flash',
      lastCallTokens: 180,
      standard: {
        dayKey: '2026-11-23',
        todayRequests: 2,
        todayInputTokens: 240,
        todayOutputTokens: 80,
        todayTotalTokens: 320,
        totalRequests: 10,
        totalInputTokens: 1400,
        totalOutputTokens: 400,
        totalTokens: 1800,
        lastProviderLabel: 'Google Gemini',
        lastModel: 'gemini-2.5-flash',
        lastCallTokens: 180,
      },
      jev: {
        dayKey: '2026-11-23',
        todayRequests: 1,
        todayInputTokens: 180,
        todayOutputTokens: 30,
        todayTotalTokens: 210,
        totalRequests: 2,
        totalInputTokens: 400,
        totalOutputTokens: 80,
        totalTokens: 480,
        lastProviderLabel: 'TypeSafe (Jev)',
        lastModel: 'jev-latest',
        lastCallTokens: 210,
      },
    },
  };

  private mockTypesafeState: TypeSafeStateDto = {
    config: {
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
    },
    hasApiKey: false,
  };

  private mockAgentConfig: ExternalAgentConfig = {
    mcpEnabled: true,
    cliEnabled: true,
    accessLevel: 'readOnly',
  };

  async getAiProviderState(): Promise<AIProviderStateDto> {
    return structuredClone(this.mockAiState);
  }

  async saveAiProviderConfig(
    config: AIProviderConfig,
    opts?: { apiKey?: string | null; clearApiKey?: boolean },
  ): Promise<AIProviderStateDto> {
    this.mockAiState.config = { ...config };
    if (opts?.clearApiKey) this.mockAiState.hasApiKey = false;
    else if (opts?.apiKey && opts.apiKey.trim()) this.mockAiState.hasApiKey = true;
    return structuredClone(this.mockAiState);
  }

  async testAiProviderConnection(): Promise<AIConnectionTestResult> {
    const p = this.mockAiState.config.provider;
    return {
      ok: true,
      providerLabel: p === 'disabled' ? '纯本机离线模式' : p,
      model: this.mockAiState.config.chatModel,
      message: p === 'disabled' ? '纯本机离线模式已就绪' : '模拟连接校验成功',
      latencyMs: 42,
    };
  }

  async resetAiUsage(category?: CloudAIUsageCategory | null): Promise<CloudAIUsageSummary> {
    const empty = {
      dayKey: '2026-11-23',
      todayRequests: 0,
      todayInputTokens: 0,
      todayOutputTokens: 0,
      todayTotalTokens: 0,
      totalRequests: 0,
      totalInputTokens: 0,
      totalOutputTokens: 0,
      totalTokens: 0,
      lastCallTokens: 0,
    };
    if (!category || category === 'standard') this.mockAiState.usage.standard = { ...empty };
    if (!category || category === 'jev') this.mockAiState.usage.jev = { ...empty };
    this.mockAiState.usage.todayRequests =
      this.mockAiState.usage.standard.todayRequests + this.mockAiState.usage.jev.todayRequests;
    this.mockAiState.usage.todayTotalTokens =
      this.mockAiState.usage.standard.todayTotalTokens + this.mockAiState.usage.jev.todayTotalTokens;
    this.mockAiState.usage.totalRequests =
      this.mockAiState.usage.standard.totalRequests + this.mockAiState.usage.jev.totalRequests;
    this.mockAiState.usage.totalTokens =
      this.mockAiState.usage.standard.totalTokens + this.mockAiState.usage.jev.totalTokens;
    return structuredClone(this.mockAiState.usage);
  }

  async signInWithChatgpt(_reconsent = false, switchAccount = false): Promise<AIProviderStateDto> {
    const email = switchAccount ? 'studio@example.com' : 'designer@example.com';
    this.mockAiState.chatgptSession = {
      status: 'connected',
      sharingEnabled: true,
      email,
      name: switchAccount ? 'Studio Account' : 'Charkle Designer',
      subject: switchAccount ? 'sub-studio' : 'sub-designer',
      lastUpdatedAt: msToCocoaSeconds(Date.now()),
    };
    this.mockAiState.config = {
      ...this.mockAiState.config,
      provider: 'chatGPTSubscription',
      baseURL: 'https://api.openai.com/v1',
      chatModel: this.mockAiState.config.chatModel || 'gpt-5.4-mini',
    };
    return structuredClone(this.mockAiState);
  }

  async disconnectChatgptAccount(): Promise<ChatGPTAccountSession> {
    this.mockAiState.chatgptSession = { status: 'disconnected', sharingEnabled: false };
    return { ...this.mockAiState.chatgptSession };
  }

  async getTypesafeState(): Promise<TypeSafeStateDto> {
    return structuredClone(this.mockTypesafeState);
  }

  async saveTypesafeConfig(
    config: TypeSafeExperimentalConfig,
    opts?: { apiKey?: string | null; clearApiKey?: boolean },
  ): Promise<TypeSafeStateDto> {
    this.mockTypesafeState.config = { ...config };
    if (opts?.clearApiKey) this.mockTypesafeState.hasApiKey = false;
    else if (opts?.apiKey && opts.apiKey.trim()) this.mockTypesafeState.hasApiKey = true;
    return structuredClone(this.mockTypesafeState);
  }

  async testTypesafeConnection(): Promise<TypeSafeTestResultDto> {
    return {
      ok: this.mockTypesafeState.hasApiKey,
      message: this.mockTypesafeState.hasApiKey
        ? '已连接 TypeSafe System One，可用模型 2 个。'
        : '尚未配置 TypeSafe API 密钥（离线显著性兜底仍可用）。',
      models: this.mockTypesafeState.hasApiKey
        ? [
            { name: 'jev-latest', description: 'System One 视觉定位', release_date: '2026-09' },
            { name: 'jev-fast', description: '低延迟视觉定位', release_date: '2026-08' },
          ]
        : [],
    };
  }

  async runInboxSmartTriage(
    assetIds?: string[],
    maxCount = 24,
  ): Promise<InboxTriageRecommendation[]> {
    const targets =
      assetIds && assetIds.length > 0
        ? this.assets
            .filter((a) => !a.isTrashed && assetIds.includes(a.id))
            .slice(0, maxCount)
        : this.assets.filter((a) => !a.isTrashed && !a.folderID).slice(0, maxCount);
    const recs: InboxTriageRecommendation[] = [];
    for (const a of targets) {
      const sug = await this.suggestFolder(a.id);
      if (sug) {
        recs.push({
          assetID: a.id,
          assetTitle: a.title,
          recommendedFolderID: sug.folderID,
          recommendedFolderName: sug.folderName,
          confidence: sug.confidence,
          fitProbability: sug.confidence,
          reason: sug.reason,
          source: 'appleVisionSaliency',
        });
      } else {
        recs.push({
          assetID: a.id,
          assetTitle: a.title,
          recommendedFolderID: null,
          recommendedFolderName: null,
          confidence: 0,
          fitProbability: 0,
          reason: '离线未匹配到明确目录，建议暂留收件箱',
          source: 'appleVisionSaliency',
        });
      }
    }
    recs.sort((a, b) => Number(Boolean(b.recommendedFolderID)) - Number(Boolean(a.recommendedFolderID)) || b.confidence - a.confidence);
    return recs;
  }

  async getExternalAgentState(): Promise<ExternalAgentStateDto> {
    const cliBinaryPath = 'C:\\Program Files\\Charkle\\charkle-cli.exe';
    const libraryDir = '%LOCALAPPDATA%\\Charkle';
    return {
      config: { ...this.mockAgentConfig },
      cliBinaryPath,
      libraryDir,
      mcpConfigJson: JSON.stringify(
        {
          mcpServers: {
            charkle: {
              command: cliBinaryPath,
              args: ['--library-dir', libraryDir, 'mcp'],
            },
          },
        },
        null,
        2,
      ),
      readToolCount: 12,
      writeToolCount: 8,
      resourceCount: 6,
    };
  }

  async saveExternalAgentConfig(config: ExternalAgentConfig): Promise<ExternalAgentStateDto> {
    this.mockAgentConfig = { ...config };
    return this.getExternalAgentState();
  }

  async runExternalAgentSelfCheck(): Promise<ExternalAgentSelfCheckDto> {
    const activeAssets = this.assets.filter((a) => !a.isTrashed).length;
    return {
      ok: true,
      summary: `自检通过：素材库含 ${activeAssets} 项素材、${this.folders.length} 个目录、${this.boards.length} 个灵感板。`,
    };
  }

  async rebuildLocalVisualIndex(): Promise<RebuildIndexResultDto> {
    const eligible = this.assets.filter(
      (a) =>
        !a.isTrashed &&
        (a.mediaKind === 'image' || a.mediaKind === 'animatedImage' || a.mediaKind === 'designFile'),
    ).length;
    return { processed: eligible, total: eligible };
  }

  async saveWebdavPassword(password: string): Promise<void> {
    this.mockHasWebdavPassword = password.trim().length > 0;
  }

  async runStorageMigration(
    targetConfig: DriveSyncConfig,
    webdavPassword?: string | null,
  ): Promise<StorageMigrationReport> {
    const sourceMode = this.syncCfg.mode;
    this.syncCfg = { ...targetConfig };
    if (webdavPassword && webdavPassword.trim()) {
      this.mockHasWebdavPassword = true;
    }
    const targetLocation =
      targetConfig.mode === 'webDAV'
        ? targetConfig.webDAVServerURL.trim() || targetConfig.webDAVRemotePath || '/Charkle'
        : targetConfig.mode === 'iCloudDrive'
          ? targetConfig.iCloudCustomFolderPath?.trim() ||
            `iCloud Drive / ${targetConfig.iCloudFolderName?.trim() || 'Charkle'}`
          : targetConfig.mode === 'localOnly'
            ? targetConfig.localLibraryPath.trim() || '%LOCALAPPDATA%\\Charkle'
            : targetConfig.mode === 'gdirectMount'
              ? targetConfig.mountPath.trim() || 'G:\\'
              : targetConfig.rootFolderName.trim() || 'Charkle';
    return {
      sourceMode,
      targetMode: targetConfig.mode,
      targetLocation,
      downloadedOriginals: this.assets.length,
      migratedAssets: this.assets.length,
      migratedFolders: this.folders.length,
      migratedBoards: this.boards.length,
      durationSeconds: 0.84,
    };
  }

  async getSystemDiagnostics(): Promise<SystemDiagnosticsDto> {
    return {
      appVersion: '1.4.1',
      schemaVersion: 2,
      dataDir: '%LOCALAPPDATA%\\Charkle',
      databasePath: '%LOCALAPPDATA%\\Charkle\\Library.sqlite3',
      gdirect: {
        cliPath: this.mockGDirectCliPath,
        cliVersion: this.mockGDirectCliVersion,
        appVersion: null,
        hasVersionMismatch: false,
        rclonePath: null,
        accounts: [],
        defaultAccount: null,
        endpoints: [],
        mountPath: 'G:\\',
        isMountActive: false,
        bypassTunEnabled: true,
      },
      ocr: {
        availableLanguages: ['zh-Hans-CN', 'en-US'],
        selectedLanguage: 'zh-Hans-CN',
        hasChinese: true,
        hasEnglish: true,
        diagnosticMessage: null,
      },
    };
  }

  async exportFigmaPluginBundle(destinationDir: string): Promise<string> {
    return `${destinationDir}/Charkle-Figma-Plugin`;
  }

  private extensionBridge: ExtensionBridgeStateDto = {
    enabled: true,
    running: true,
    port: 41937,
    baseUrl: 'http://127.0.0.1:41937',
    allowLocalAutoPair: true,
    accessToken: 'charkle_mock_bridge_token_41937',
    lastError: null,
    bundledExtensionDir: 'C:\\Program Files\\Charkle\\Resources\\BrowserExtension',
    bundledExtensionManifestPath:
      'C:\\Program Files\\Charkle\\Resources\\BrowserExtension\\manifest.json',
  };

  private mockBridgeTokenCounter = 0;

  async getExtensionBridgeState(): Promise<ExtensionBridgeStateDto> {
    return { ...this.extensionBridge };
  }

  async setExtensionBridgeEnabled(enabled: boolean): Promise<ExtensionBridgeStateDto> {
    this.extensionBridge = {
      ...this.extensionBridge,
      enabled,
      running: enabled,
      lastError: null,
    };
    return { ...this.extensionBridge };
  }

  async setExtensionAutoPair(allowLocalAutoPair: boolean): Promise<ExtensionBridgeStateDto> {
    this.extensionBridge = {
      ...this.extensionBridge,
      allowLocalAutoPair,
    };
    return { ...this.extensionBridge };
  }

  async regenerateExtensionBridgeToken(): Promise<ExtensionBridgeStateDto> {
    this.mockBridgeTokenCounter += 1;
    const hex = `${Date.now().toString(16)}${this.mockBridgeTokenCounter.toString(16).padStart(4, '0')}${Math.floor(Math.random() * 0xffffffff).toString(16).padStart(8, '0')}`.slice(-24);
    this.extensionBridge = {
      ...this.extensionBridge,
      accessToken: `charkle_${hex}`,
    };
    return { ...this.extensionBridge };
  }

  async revealBundledBrowserExtension(): Promise<string> {
    return (
      this.extensionBridge.bundledExtensionManifestPath ??
      this.extensionBridge.bundledExtensionDir ??
      ''
    );
  }

  private mockShelfSettings: ShelfSettings = {
    enabled: true,
    hoverTriggerEnabled: true,
    defaultTargetMode: 'inbox',
    minimalMode: false,
    dockEdge: 'top',
  };

  async openAssetInMainWindow(): Promise<void> {}

  async copyAssetsToClipboard(assetIds: string[]): Promise<number> {
    return assetIds.length;
  }

  async getShelfSettings(): Promise<ShelfSettings> {
    return { ...this.mockShelfSettings };
  }

  async saveShelfSettings(settings: ShelfSettings): Promise<ShelfSettings> {
    this.mockShelfSettings = {
      ...settings,
      dockEdge: settings.dockEdge ?? this.mockShelfSettings.dockEdge ?? 'top',
    };
    return { ...this.mockShelfSettings };
  }

  async setMinimalMode(enabled: boolean): Promise<ShelfSettings> {
    this.mockShelfSettings = { ...this.mockShelfSettings, minimalMode: enabled };
    return { ...this.mockShelfSettings };
  }

  async setShelfAllowActivate(): Promise<void> {}

  // Native GitHub Releases Updater mock state
  private mockUpdatePrefs: UpdatePreferencesDto = {
    currentVersion: '1.4.1',
    autoCheckUpdates: true,
    lastUpdateCheckAtMs: null,
    skippedVersion: null,
    releasesPageUrl: 'https://github.com/CharTyr/Charkle/releases',
  };
  public mockAvailableUpdate: AppReleaseUpdate | null = null;
  public mockCheckError: string | null = null;
  public mockInstallError: string | null = null;
  public mockInstalledPaths: string[] = [];
  public mockOpenedInstallerPaths: string[] = [];
  public mockRevealedInstallerPaths: string[] = [];
  private updateProgressListeners = new Set<(progress: UpdateDownloadProgress) => void>();
  private updatePhaseListeners = new Set<(phase: string) => void>();

  async getUpdatePreferences(): Promise<UpdatePreferencesDto> {
    return { ...this.mockUpdatePrefs };
  }

  async setAutoCheckUpdates(enabled: boolean): Promise<UpdatePreferencesDto> {
    this.mockUpdatePrefs = { ...this.mockUpdatePrefs, autoCheckUpdates: enabled };
    return { ...this.mockUpdatePrefs };
  }

  async skipUpdateVersion(version: string): Promise<UpdatePreferencesDto> {
    this.mockUpdatePrefs = {
      ...this.mockUpdatePrefs,
      skippedVersion: version.trim() || null,
    };
    return { ...this.mockUpdatePrefs };
  }

  async clearSkippedUpdateVersion(): Promise<UpdatePreferencesDto> {
    this.mockUpdatePrefs = { ...this.mockUpdatePrefs, skippedVersion: null };
    return { ...this.mockUpdatePrefs };
  }

  async checkForUpdates(manual = true): Promise<UpdateCheckResponseDto> {
    if (this.mockCheckError) {
      throw new Error(this.mockCheckError);
    }
    const now = Date.now();
    this.mockUpdatePrefs = { ...this.mockUpdatePrefs, lastUpdateCheckAtMs: now };
    if (this.mockAvailableUpdate) {
      const skipped = this.mockUpdatePrefs.skippedVersion;
      const isSkipped =
        Boolean(skipped) &&
        (skipped === this.mockAvailableUpdate.version ||
          skipped === this.mockAvailableUpdate.tagName);
      return {
        currentVersion: this.mockUpdatePrefs.currentVersion,
        outcome: { kind: 'updateAvailable', update: this.mockAvailableUpdate },
        checkedAtMs: now,
        shouldNotify: manual || !isSkipped,
        preferences: { ...this.mockUpdatePrefs },
      };
    }
    return {
      currentVersion: this.mockUpdatePrefs.currentVersion,
      outcome: { kind: 'upToDate', latestVersion: this.mockUpdatePrefs.currentVersion },
      checkedAtMs: now,
      shouldNotify: false,
      preferences: { ...this.mockUpdatePrefs },
    };
  }

  async downloadAndVerifyUpdate(update: AppReleaseUpdate): Promise<VerifiedUpdateInstaller> {
    const total = update.assetSizeBytes || 20_000_000;
    for (const listener of this.updateProgressListeners) {
      listener({
        tagName: update.tagName,
        downloadedBytes: Math.round(total * 0.5),
        totalBytes: total,
        fraction: 0.5,
      });
      listener({
        tagName: update.tagName,
        downloadedBytes: total,
        totalBytes: total,
        fraction: 1,
      });
    }
    for (const listener of this.updatePhaseListeners) {
      listener('verifying');
    }
    return {
      tagName: update.tagName,
      version: update.version,
      installerPath: `C:\\Temp\\charkle-updater\\${update.assetName}`,
      fileName: update.assetName,
      verifiedSha256:
        update.expectedSha256 ??
        '1dc089f37e073529daeb95cb4709896132ebe045b557bb03ac8326c3ee00620b',
      sizeBytes: total,
      checksumVerifiedAgainstRelease: Boolean(update.expectedSha256),
    };
  }

  async cancelUpdateDownload(): Promise<void> {}

  async installAndRelaunchUpdate(installerPath: string): Promise<void> {
    if (this.mockInstallError) {
      throw new Error(this.mockInstallError);
    }
    this.mockInstalledPaths.push(installerPath);
  }

  async openUpdateInstaller(installerPath: string): Promise<void> {
    this.mockOpenedInstallerPaths.push(installerPath);
  }

  async revealUpdateInstaller(installerPath: string): Promise<void> {
    this.mockRevealedInstallerPaths.push(installerPath);
  }

  private mockGDirectCliPath: string | null = null;
  private mockGDirectCliVersion: string | null = null;
  private gdirectProgressListeners = new Set<(progress: GDirectInstallProgress) => void>();

  async installGDirectCli(): Promise<GDirectInstallResult> {
    for (const listener of this.gdirectProgressListeners) {
      listener({
        phase: 'downloading',
        message: '正在下载 gdirect-0.13.2-x86_64-pc-windows-gnu.zip…',
        downloadedBytes: 6_800_000,
        totalBytes: 13_600_000,
        fraction: 0.5,
      });
      listener({
        phase: 'done',
        message: '已安装 gdirect v0.13.2',
        downloadedBytes: 13_600_000,
        totalBytes: 13_600_000,
        fraction: 1,
      });
    }
    this.mockGDirectCliPath = 'C:\\Users\\demo\\AppData\\Local\\Charkle\\bin\\gdirect.exe';
    this.mockGDirectCliVersion = '0.13.2';
    return {
      tagName: 'v0.13.2',
      version: '0.13.2',
      cliPath: this.mockGDirectCliPath,
      assetName: 'gdirect-0.13.2-x86_64-pc-windows-gnu.zip',
      verifiedSha256: '006b409608bf0681045fee71430006876f4332625bd8403014f4d21756838b73',
      sizeBytes: 13_624_719,
    };
  }

  async subscribeEvents(handlers?: CharkleEventHandlers): Promise<() => void> {
    const surfaceHandler = handlers?.onSurfaceState;
    if (surfaceHandler) {
      this.surfaceListeners.add(surfaceHandler);
    }
    const progressHandler = handlers?.onUpdateProgress;
    if (progressHandler) {
      this.updateProgressListeners.add(progressHandler);
    }
    const phaseHandler = handlers?.onUpdatePhase;
    if (phaseHandler) {
      this.updatePhaseListeners.add(phaseHandler);
    }
    const gdirectHandler = handlers?.onGDirectInstallProgress;
    if (gdirectHandler) {
      this.gdirectProgressListeners.add(gdirectHandler);
    }
    return () => {
      if (surfaceHandler) {
        this.surfaceListeners.delete(surfaceHandler);
      }
      if (progressHandler) {
        this.updateProgressListeners.delete(progressHandler);
      }
      if (phaseHandler) {
        this.updatePhaseListeners.delete(phaseHandler);
      }
      if (gdirectHandler) {
        this.gdirectProgressListeners.delete(gdirectHandler);
      }
    };
  }

  /** Helper for tests simulating live Windows DWM surface/accent changes. */
  emitSurfaceState(state: WindowSurfaceState): void {
    if (state.systemAccentHex !== undefined) {
      this.mockSystemAccentHex = state.systemAccentHex;
    }
    for (const listener of this.surfaceListeners) {
      listener(state);
    }
  }

  /** Mock helpers for tests inspecting material package import & smart dedup flows. */
  public mockMaterialPackagePaths: string[] = [];
  public mockLibraryDirectoryPath: string | null = null;
  public mockDuplicateReport: DeduplicationScanReport | null = null;
  public mockResolvedDedupCalls: Array<{
    plans: DeduplicationResolutionPlan[];
    disposal: DuplicateDisposalMode;
    mergeMetadata: boolean;
  }> = [];
  public mockImportedPackagePaths: string[] = [];

  async pickMaterialPackageFilesDialog(): Promise<string[]> {
    return [...this.mockMaterialPackagePaths];
  }

  async importMaterialPackages(
    paths: string[],
    targetFolderId?: string | null,
  ): Promise<MaterialPackageImportResult[]> {
    this.mockImportedPackagePaths.push(...paths);
    const out: MaterialPackageImportResult[] = [];
    for (const p of paths) {
      const base = p.split(/[\\/]/).pop() ?? 'MaterialPack';
      const packageName = base.replace(/\.(eaglepack|library|zip)$/i, '') || 'MaterialPack';
      const folder = await this.createFolder(packageName, targetFolderId ?? null);
      const created = await this.ingestText(
        `${packageName} 示例`,
        `Imported from ${base}`,
        null,
        folder.id,
      );
      out.push({
        packageName,
        importedAssetCount: created.length,
        createdFolderCount: 1,
        rootFolderID: folder.id,
        skippedDeletedCount: 0,
        skippedMissingCount: 0,
      });
    }
    return out;
  }

  async scanDuplicates(
    scope: DeduplicationScanScope,
    _sensitivity: DeduplicationSensitivity,
    mediaKinds?: MediaKind[] | null,
  ): Promise<DeduplicationScanReport> {
    if (this.mockDuplicateReport) {
      const allowedKinds = mediaKinds && mediaKinds.length > 0 ? new Set(mediaKinds) : null;
      const groups = allowedKinds
        ? this.mockDuplicateReport.groups.filter((g) => allowedKinds.has(g.primaryMediaKind))
        : this.mockDuplicateReport.groups;
      return {
        ...this.mockDuplicateReport,
        groups,
        totalDuplicateItems: groups.reduce((s, g) => s + Math.max(0, g.candidates.length - 1), 0),
        totalReclaimableBytes: groups.reduce((s, g) => s + g.reclaimableBytes, 0),
      };
    }

    const active = this.assets.filter((a) => {
      if (a.isTrashed) return false;
      if (scope.type === 'inbox' && a.folderID != null) return false;
      if (scope.type === 'folder' && a.folderID !== scope.folderID) return false;
      if (mediaKinds && mediaKinds.length > 0 && !mediaKinds.includes(a.mediaKind)) return false;
      return true;
    });

    const byKey = new Map<string, AssetRecord[]>();
    for (const asset of active) {
      const key =
        asset.contentHash?.trim() ||
        `${asset.mediaKind}:${asset.title.trim().toLowerCase()}`;
      const list = byKey.get(key) ?? [];
      list.push(asset);
      byKey.set(key, list);
    }

    const groups: DeduplicationScanReport['groups'] = [];
    for (const members of byKey.values()) {
      if (members.length < 2) continue;
      const sorted = [...members].sort(
        (a, b) =>
          b.pixelWidth * b.pixelHeight - a.pixelWidth * a.pixelHeight ||
          b.fileSizeBytes - a.fileSizeBytes,
      );
      const keeper = sorted[0];
      const reclaimableBytes = sorted.slice(1).reduce((s, a) => s + Math.max(0, a.fileSizeBytes), 0);
      groups.push({
        id: `dup-${keeper.id}`,
        primaryMediaKind: keeper.mediaKind,
        matchKind: keeper.contentHash ? 'exactBinary' : 'nearIdentical',
        similarityScore: 1,
        recommendedKeepAssetID: keeper.id,
        reclaimableBytes,
        candidates: sorted.map((asset, idx) => ({
          asset,
          qualityScore: 1000 - idx * 50,
          resolutionPixels: Math.max(1, asset.pixelWidth * asset.pixelHeight),
          formatLabel: asset.fileName.split('.').pop()?.toUpperCase() || 'FILE',
          isLosslessFormat: /\.png$/i.test(asset.fileName),
          sharpnessScore: 42,
          isRecommendedKeep: idx === 0,
          isReferencedByBoard: false,
          similarityToKeeper: 1,
          qualityReasons: idx === 0 ? ['最高画质'] : [],
        })),
      });
    }

    return {
      scannedAssetCount: active.length,
      skippedNonVisualCount: 0,
      groups,
      totalDuplicateItems: groups.reduce((s, g) => s + Math.max(0, g.candidates.length - 1), 0),
      totalReclaimableBytes: groups.reduce((s, g) => s + g.reclaimableBytes, 0),
      durationSeconds: 0.02,
    };
  }

  async resolveDuplicateGroups(
    plans: DeduplicationResolutionPlan[],
    disposal: DuplicateDisposalMode,
    mergeMetadata: boolean,
  ): Promise<DeduplicationCleanupResult> {
    this.mockResolvedDedupCalls.push({ plans, disposal, mergeMetadata });
    let resolvedGroupCount = 0;
    let removedAssetCount = 0;
    let reclaimedBytes = 0;
    let mergedMetadataCount = 0;
    let updatedBoardCount = 0;

    for (const plan of plans) {
      const keeper = this.assets.find((a) => a.id === plan.keepAssetID && !a.isTrashed);
      if (!keeper) continue;
      const toRemove = plan.removeAssetIDs
        .filter((id) => id !== plan.keepAssetID)
        .map((id) => this.assets.find((a) => a.id === id && !a.isTrashed))
        .filter((a): a is AssetRecord => Boolean(a));
      if (toRemove.length === 0) continue;
      resolvedGroupCount += 1;

      if (mergeMetadata) {
        const tagSet = new Set(keeper.tags);
        let mutated = false;
        for (const dup of toRemove) {
          for (const t of dup.tags) {
            if (!tagSet.has(t)) {
              tagSet.add(t);
              mutated = true;
            }
          }
          if (dup.rating > keeper.rating) {
            keeper.rating = dup.rating;
            mutated = true;
          }
          if (!keeper.folderID && dup.folderID) {
            keeper.folderID = dup.folderID;
            mutated = true;
          }
          if (!keeper.sourceURL && dup.sourceURL) {
            keeper.sourceURL = dup.sourceURL;
            keeper.sourceDomain = dup.sourceDomain;
            mutated = true;
          }
          if (dup.notes.trim() && !keeper.notes.includes(dup.notes.trim())) {
            keeper.notes = keeper.notes.trim()
              ? `${keeper.notes.trim()}\n\n${dup.notes.trim()}`
              : dup.notes.trim();
            mutated = true;
          }
        }
        if (mutated) {
          keeper.tags = Array.from(tagSet).sort();
          mergedMetadataCount += 1;
        }
      }

      const removeSet = new Set(toRemove.map((a) => a.id));
      for (const board of this.boards) {
        let changed = false;
        const seenKeeper = new Set<string>();
        board.nodes = board.nodes.filter((n) => {
          if ('assetRef' in n.kind) {
            const aid = n.kind.assetRef.assetID;
            if (removeSet.has(aid)) {
              changed = true;
              if (seenKeeper.has(keeper.id)) return false;
              n.kind.assetRef.assetID = keeper.id;
              seenKeeper.add(keeper.id);
            } else if (aid === keeper.id) {
              seenKeeper.add(keeper.id);
            }
          }
          return true;
        });
        if (changed) updatedBoardCount += 1;
      }

      for (const dup of toRemove) {
        reclaimedBytes += Math.max(0, dup.fileSizeBytes);
        removedAssetCount += 1;
        if (disposal === 'moveToTrash') {
          dup.isTrashed = true;
        }
      }
      if (disposal === 'permanentlyDelete') {
        this.assets = this.assets.filter((a) => !removeSet.has(a.id));
      }
    }

    if (this.mockDuplicateReport) {
      const removedAll = new Set(plans.flatMap((p) => p.removeAssetIDs));
      this.mockDuplicateReport = {
        ...this.mockDuplicateReport,
        groups: this.mockDuplicateReport.groups.filter(
          (g) => !g.candidates.some((c) => removedAll.has(c.asset.id)),
        ),
      };
    }

    return {
      resolvedGroupCount,
      removedAssetCount,
      reclaimedBytes,
      mergedMetadataCount,
      updatedBoardCount,
    };
  }

  // MARK: - Pinterest Mock State & Methods (Vitest / Browser Preview)
  public mockPinterestAccount: PinterestAccount | null = {
    id: 'mock-pin-user-1',
    username: 'studio_charkle',
    fullName: 'Studio Charkle',
    avatarURL: null,
    email: null,
  };
  public mockPinterestBoards: PinterestBoard[] = [
    {
      id: 'mock-board-1',
      name: 'Editorial / Type',
      urlPath: '/studio_charkle/editorial-type/',
      description: 'Typography & editorial grids',
      pinCount: 24,
      coverImageURL: makeSvgDataUrl('#252B36', '#E07A5F', 'Editorial', 320, 240),
      isSecret: false,
      ownerUsername: 'studio_charkle',
    },
    {
      id: 'mock-board-2',
      name: 'Spatial Packaging',
      urlPath: '/studio_charkle/spatial-packaging/',
      description: 'Tactile packaging & ceramics',
      pinCount: 16,
      coverImageURL: makeSvgDataUrl('#2F3E3A', '#D4A373', 'Packaging', 320, 240),
      isSecret: false,
      ownerUsername: 'studio_charkle',
    },
  ];
  public mockPinterestPins: PinterestPin[] = Array.from({ length: 18 }, (_, idx) => {
    const w = 800;
    const h = idx % 3 === 0 ? 1200 : idx % 3 === 1 ? 800 : 620;
    const palette = ['#264653', '#2A9D8F', '#8D5B4C', '#3D405B', '#6B705C', '#4A4E69'];
    const bg = palette[idx % palette.length];
    const svgUrl = makeSvgDataUrl(bg, '#F4A261', `Pin ${idx + 1}`, w, h);
    return {
      id: `900000${100 + idx}`,
      title: `Pinterest 灵感样本 ${idx + 1}`,
      description: `视觉构图与色彩层次参考样本 #${idx + 1}`,
      authorName: idx % 2 === 0 ? 'Atelier Nord' : 'Studio Sol',
      authorUsername: idx % 2 === 0 ? 'atelier_nord' : 'studio_sol',
      authorAvatarURL: null,
      boardName: idx % 2 === 0 ? 'Editorial / Type' : 'Spatial Packaging',
      boardID: idx % 2 === 0 ? 'mock-board-1' : 'mock-board-2',
      domain: 'pinterest.com',
      linkURL: `https://example.com/ref/${idx + 1}`,
      pinPageURL: `https://www.pinterest.com/pin/900000${100 + idx}/`,
      originalURL: svgUrl,
      previewURL: svgUrl,
      thumbnailURL: svgUrl,
      videoURL: null,
      pixelWidth: w,
      pixelHeight: h,
      dominantColorHex: bg,
    };
  });
  public mockPinterestBoardImportCancelled = false;

  async pinterestOpenLoginWindow(): Promise<void> {
    if (!this.mockPinterestAccount) {
      this.mockPinterestAccount = {
        id: 'mock-pin-user-1',
        username: 'studio_charkle',
        fullName: 'Studio Charkle',
        avatarURL: null,
        email: null,
      };
    }
  }

  async pinterestCloseLoginWindow(): Promise<void> {}

  async pinterestCheckSession(): Promise<PinterestAccount | null> {
    return this.mockPinterestAccount;
  }

  async pinterestSignOut(): Promise<void> {
    this.mockPinterestAccount = null;
  }

  async pinterestFetchFeed(
    source: PinterestFeedSource,
    bookmark?: string | null,
    _pageSize?: number,
  ): Promise<PinterestFeedPage> {
    if (bookmark === 'page-2') {
      return {
        pins: [],
        nextBookmark: null,
        hasMore: false,
        sourceDescription: 'mock',
      };
    }
    let filtered = this.mockPinterestPins;
    if (source.kind === 'search') {
      const q = source.query.trim().toLowerCase();
      filtered = filtered.filter(
        (p) =>
          p.title.toLowerCase().includes(q) ||
          p.description.toLowerCase().includes(q) ||
          (p.boardName ?? '').toLowerCase().includes(q),
      );
      if (filtered.length === 0) filtered = this.mockPinterestPins.slice(0, 6);
    } else if (source.kind === 'board') {
      filtered = filtered.filter((p) => p.boardID === source.board.id);
    } else if (source.kind === 'similar') {
      filtered = filtered.filter((p) => p.id !== source.seedPin.id);
    }
    return {
      pins: filtered,
      nextBookmark: null,
      hasMore: false,
      sourceDescription: source.kind,
    };
  }

  async pinterestFetchBoards(_username: string): Promise<PinterestBoard[]> {
    return [...this.mockPinterestBoards];
  }

  async pinterestFetchPinDetail(pin: PinterestPin): Promise<PinterestPinDetailResult> {
    const similarPins = this.mockPinterestPins.filter((p) => p.id !== pin.id).slice(0, 8);
    return {
      pin,
      similarPins,
      nextSimilarBookmark: null,
      hasMoreSimilar: false,
    };
  }

  async pinterestFetchSimilarPins(
    pin: PinterestPin,
    _bookmark?: string | null,
    _pageSize?: number,
  ): Promise<PinterestFeedPage> {
    return {
      pins: this.mockPinterestPins.filter((p) => p.id !== pin.id).slice(0, 6),
      nextBookmark: null,
      hasMore: false,
      sourceDescription: 'similar',
    };
  }

  async pinterestExistingImportedPinIds(): Promise<string[]> {
    const ids: string[] = [];
    for (const a of this.assets) {
      if (a.isTrashed || !a.sourceURL) continue;
      const m = a.sourceURL.match(/pinterest\.[^/]+\/pin\/(\d{6,})/i);
      if (m) ids.push(m[1]);
    }
    return ids;
  }

  async pinterestImportPins(
    pins: PinterestPin[],
    targetFolderId: string | null,
    extraTags: string[],
    skipDuplicates = true,
  ): Promise<PinterestBatchImportReport> {
    const existing = new Set(skipDuplicates ? await this.pinterestExistingImportedPinIds() : []);
    const importedAssets: AssetRecord[] = [];
    const skippedDuplicatePinIDs: string[] = [];

    for (const pin of pins) {
      if (skipDuplicates && existing.has(pin.id)) {
        skippedDuplicatePinIDs.push(pin.id);
        continue;
      }
      const id = makeUuid();
      const now = msToCocoaSeconds(Date.now());
      const tags = Array.from(
        new Set(['Pinterest', ...(pin.boardName ? [pin.boardName] : []), ...extraTags]),
      );
      const record: AssetRecord = {
        id,
        contentHash: `pin-${pin.id}`,
        folderID: targetFolderId,
        mediaKind: 'image',
        mimeType: 'image/png',
        title: pin.title || `Pinterest ${pin.id}`,
        fileName: `pinterest_${pin.id}.png`,
        notes: pin.description,
        tags,
        suggestedTags: [],
        rating: 0,
        pixelWidth: pin.pixelWidth || 800,
        pixelHeight: pin.pixelHeight || 1000,
        fileSizeBytes: 120_000,
        dominantColors: [],
        waveformPeaks: [],
        sourceURL: pin.pinPageURL,
        sourceDomain: 'pinterest.com',
        pinnedOffline: true,
        isLocalOriginalCached: true,
        isTrashed: false,
        createdAt: now,
        updatedAt: now,
        updatedHLC: Date.now(),
      };
      this.assets.unshift(record);
      if (pin.previewURL) this.thumbs.set(id, pin.previewURL);
      importedAssets.push(record);
      existing.add(pin.id);
    }

    return {
      importedAssets,
      skippedDuplicatePinIDs,
      failedPinIDs: [],
      errors: [],
    };
  }

  async pinterestImportBoards(
    boards: PinterestBoard[],
    destination: PinterestBoardImportDestination,
    extraTags: string[],
    skipDuplicates = true,
  ): Promise<PinterestBoardsImportReport> {
    this.mockPinterestBoardImportCancelled = false;
    const createdOrReusedFolderIDs: string[] = [];
    let parentId: string | null = null;

    if (destination.kind === 'existingFolder') {
      parentId = destination.folderID;
    } else if (destination.kind === 'pinterestRootFolder') {
      const existingRoot = this.folders.find(
        (f) => !f.parentID && f.name.toLowerCase() === 'pinterest',
      );
      const root = existingRoot ?? (await this.createFolder('Pinterest', null));
      parentId = root.id;
      createdOrReusedFolderIDs.push(root.id);
    }

    let importedAssetCount = 0;
    let skippedDuplicateCount = 0;

    for (const board of boards) {
      if (this.mockPinterestBoardImportCancelled) {
        return {
          createdOrReusedFolderIDs,
          importedAssetCount,
          skippedDuplicateCount,
          failedPinCount: 0,
          errors: [],
          wasCancelled: true,
        };
      }
      const cleanName = board.name.replace(/\//g, '·').replace(/:/g, '-').slice(0, 64);
      const existingSub = this.folders.find(
        (f) => (f.parentID ?? null) === parentId && f.name.toLowerCase() === cleanName.toLowerCase(),
      );
      const targetFolder = existingSub ?? (await this.createFolder(cleanName, parentId));
      createdOrReusedFolderIDs.push(targetFolder.id);

      const boardPins = this.mockPinterestPins.filter((p) => p.boardID === board.id);
      const pinsToImport = boardPins.length > 0 ? boardPins : this.mockPinterestPins.slice(0, 2);
      const res = await this.pinterestImportPins(
        pinsToImport,
        targetFolder.id,
        [board.name, ...extraTags],
        skipDuplicates,
      );
      importedAssetCount += res.importedAssets.length;
      skippedDuplicateCount += res.skippedDuplicatePinIDs.length;
    }

    return {
      createdOrReusedFolderIDs,
      importedAssetCount,
      skippedDuplicateCount,
      failedPinCount: 0,
      errors: [],
      wasCancelled: false,
    };
  }

  async pinterestCancelBoardImport(): Promise<void> {
    this.mockPinterestBoardImportCancelled = true;
  }

  /** Helper for tests inspecting smart folder evaluation. */
  filterBySmartFolder(rule: SmartFolderRecord['rule']): AssetRecord[] {
    return this.assets.filter((a) => matchesSmartFolderRule(a, rule));
  }
}

let activeTransport: CharkleTransport = isTauriRuntime()
  ? new TauriTransport()
  : new InMemoryMockTransport(true);

export function getTransport(): CharkleTransport {
  return activeTransport;
}

export function setTransport(transport: CharkleTransport): void {
  activeTransport = transport;
}
