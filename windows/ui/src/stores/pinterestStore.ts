//! Zustand controller for the Pinterest Infinite Spatial Browser, persistent Shopping-Cart
//! Collection Tray, Aspect-Adaptive Floating Pin Detail Overlay, and Batch Board Importer.
//! Mirrors `Sources/CharkleCore/Services/Pinterest/PinterestExploreController.swift`.

import { create } from 'zustand';
import { getTransport, isTauriRuntime } from '../api/transport';
import {
  PinterestSpatialLayout,
  pinDisplayImageUrl,
  type PinterestSpatialCard,
  type SpatialRect,
  type SpatialSize,
} from '../features/pinterest/spatialLayout';
import {
  resolveSocialMediaUrl,
  type PinterestAccount,
  type PinterestBatchImportReport,
  type PinterestBoard,
  type PinterestBoardImportDestination,
  type PinterestBoardImportProgress,
  type PinterestBoardsImportReport,
  type PinterestFeedSource,
  type PinterestPin,
  type PinterestPinDetailResult,
  type PinterestTrayImportProgress,
} from '../types/domain';
import { useCoordinatorStore } from './coordinatorStore';
import { useLibraryStore } from './libraryStore';

export type PinterestSessionState = 'unknown' | 'checking' | 'signedOut' | 'signedIn';

const TRAY_STORAGE_KEY = 'charkle.pinterest.collectionTray.v1';
const MAX_TRAY_ITEMS = 250;

function readPersistedTray(): PinterestPin[] {
  if (typeof localStorage === 'undefined') return [];
  try {
    const raw = localStorage.getItem(TRAY_STORAGE_KEY);
    if (!raw) return [];
    const parsed = JSON.parse(raw);
    if (!Array.isArray(parsed)) return [];
    const seen = new Set<string>();
    const out: PinterestPin[] = [];
    for (const item of parsed) {
      if (item && typeof item.id === 'string' && item.id.length > 0 && !seen.has(item.id)) {
        seen.add(item.id);
        out.push(item as PinterestPin);
      }
    }
    return out.slice(0, MAX_TRAY_ITEMS);
  } catch {
    return [];
  }
}

function persistTray(pins: PinterestPin[]): void {
  if (typeof localStorage === 'undefined') return;
  try {
    localStorage.setItem(TRAY_STORAGE_KEY, JSON.stringify(pins.slice(0, MAX_TRAY_ITEMS)));
  } catch {
    // Ignore storage quota errors
  }
}

function isAuthError(err: unknown): boolean {
  if (!err || typeof err !== 'object') return false;
  const code = (err as { code?: unknown }).code;
  if (code === 'AUTH_REQUIRED') return true;
  const msg = err instanceof Error ? err.message : String((err as { message?: unknown }).message ?? err);
  return msg.includes('登录状态已失效') || msg.includes('AUTH_REQUIRED');
}

function errorMessage(err: unknown, fallback: string): string {
  if (err instanceof Error && err.message) return err.message;
  if (err && typeof err === 'object' && typeof (err as { message?: unknown }).message === 'string') {
    return (err as { message: string }).message;
  }
  return fallback;
}

const spatialLayout = new PinterestSpatialLayout(224, 16);
const prefetchedUrls = new Set<string>();
const detailCache = new Map<string, PinterestPinDetailResult>();

function warmImageUrl(rawUrl: string | undefined): void {
  if (!rawUrl || typeof Image === 'undefined') return;
  const resolved = resolveSocialMediaUrl(rawUrl, isTauriRuntime());
  if (!resolved || prefetchedUrls.has(resolved)) return;
  if (prefetchedUrls.size > 600) {
    prefetchedUrls.clear();
  }
  prefetchedUrls.add(resolved);
  const img = new Image();
  img.decoding = 'async';
  img.src = resolved;
}

export interface PinterestStoreState {
  sessionState: PinterestSessionState;
  account: PinterestAccount | null;
  boards: PinterestBoard[];
  isLoadingBoards: boolean;
  needsReauth: boolean;

  activeSource: PinterestFeedSource;
  searchQueryDraft: string;
  cards: readonly PinterestSpatialCard[];
  layoutRevision: number;
  contentBounds: SpatialRect;
  cameraResetNonce: number;

  nextBookmark: string | null;
  hasMoreFeed: boolean;
  isLoadingFeed: boolean;
  isLoadingMore: boolean;
  feedError: string | null;
  lastStatusBanner: string | null;

  // Persistent Shopping-Cart Collection Tray
  collectedPins: PinterestPin[];
  collectedPinIds: Record<string, true>;
  traySelectedPinIds: Record<string, true>;
  isTrayExpanded: boolean;
  isQuickCollectMode: boolean;

  // Duplicate detection & Tray Import
  importedPinIds: Record<string, true>;
  isImportingTray: boolean;
  trayImportProgress: PinterestTrayImportProgress | null;

  // Floating Pin Detail Overlay + Back-Stack + Lightbox
  detailStack: PinterestPin[];
  activeDetailPin: PinterestPin | null;
  activeSimilarPins: PinterestPin[];
  activeSimilarBookmark: string | null;
  hasMoreSimilar: boolean;
  isLoadingDetail: boolean;
  isLoadingMoreSimilar: boolean;
  lightboxOpen: boolean;

  // Batch Board Import Modal
  boardImportModalOpen: boolean;
  isImportingBoards: boolean;
  boardImportProgress: PinterestBoardImportProgress | null;
  lastBoardImportReport: PinterestBoardsImportReport | null;

  // Actions
  getSpatialLayout: () => PinterestSpatialLayout;
  bootstrap: () => Promise<void>;
  openLoginWindow: () => Promise<void>;
  handleAuthChangedEvent: (autoCloseLogin?: boolean) => Promise<void>;
  signOut: () => Promise<void>;
  refreshImportedPinIds: () => Promise<void>;
  refreshBoards: () => Promise<void>;

  setSearchQueryDraft: (q: string) => void;
  loadSource: (source: PinterestFeedSource) => Promise<void>;
  submitSearch: () => Promise<void>;
  loadMoreIfNeeded: (visibleWorldRect: SpatialRect) => Promise<void>;
  loadNextPage: () => Promise<void>;
  prefetchAhead: (
    visibleWorldRect: SpatialRect,
    lookaheadOffset: SpatialSize,
    renderedCardWidth: number,
  ) => void;
  requestCenterCamera: () => void;

  // Shopping-Cart Tray
  toggleTrayPin: (pin: PinterestPin) => void;
  addToTray: (pin: PinterestPin) => void;
  removeFromTray: (pinId: string) => void;
  setTrayPinSelected: (pinId: string, selected: boolean) => void;
  selectAllTrayPins: () => void;
  deselectAllTrayPins: () => void;
  removeSelectedFromTray: () => void;
  clearTray: () => void;
  setTrayExpanded: (expanded: boolean) => void;
  setQuickCollectMode: (fastPick: boolean) => void;
  importTrayPins: (
    targetFolderId: string | null,
    extraTags: string[],
    onlySelected?: boolean,
  ) => Promise<PinterestBatchImportReport | null>;
  importSinglePinDirectly: (
    pin: PinterestPin,
    targetFolderId?: string | null,
  ) => Promise<PinterestBatchImportReport | null>;

  // Pin Detail Overlay & Similar Pins
  openPinDetail: (pin: PinterestPin, pushHistory?: boolean) => Promise<void>;
  popPinDetail: () => Promise<void>;
  closePinDetail: () => void;
  loadMoreSimilarPins: () => Promise<void>;
  exploreSimilarInSpace: (pin: PinterestPin) => Promise<void>;
  setLightboxOpen: (open: boolean) => void;

  // Board Batch Import Modal
  openBoardImportModal: () => void;
  closeBoardImportModal: () => void;
  startBoardBatchImport: (
    boards: PinterestBoard[],
    destination: PinterestBoardImportDestination,
    extraTags: string[],
    skipDuplicates: boolean,
  ) => Promise<PinterestBoardsImportReport | null>;
  cancelBoardBatchImport: () => Promise<void>;

  // Event receivers
  handleTrayImportProgressEvent: (progress: PinterestTrayImportProgress) => void;
  handleBoardImportProgressEvent: (progress: PinterestBoardImportProgress) => void;
  clearStatusBanner: () => void;
}

const initialTray = readPersistedTray();
const initialTrayIds: Record<string, true> = {};
const initialTraySelected: Record<string, true> = {};
for (const p of initialTray) {
  initialTrayIds[p.id] = true;
  initialTraySelected[p.id] = true;
}

let activeFeedEpoch = 0;

function makeIdRecord(ids: Iterable<string>): Record<string, true> {
  const out: Record<string, true> = {};
  for (const id of ids) {
    out[id] = true;
  }
  return out;
}

export const usePinterestStore = create<PinterestStoreState>((set, get) => ({
  sessionState: 'unknown',
  account: null,
  boards: [],
  isLoadingBoards: false,
  needsReauth: false,

  activeSource: { kind: 'home' },
  searchQueryDraft: '',
  cards: [],
  layoutRevision: 0,
  contentBounds: { x: 0, y: 0, width: 0, height: 0 },
  cameraResetNonce: 0,

  nextBookmark: null,
  hasMoreFeed: false,
  isLoadingFeed: false,
  isLoadingMore: false,
  feedError: null,
  lastStatusBanner: null,

  collectedPins: initialTray,
  collectedPinIds: initialTrayIds,
  traySelectedPinIds: initialTraySelected,
  isTrayExpanded: false,
  isQuickCollectMode: false,

  importedPinIds: {},
  isImportingTray: false,
  trayImportProgress: null,

  detailStack: [],
  activeDetailPin: null,
  activeSimilarPins: [],
  activeSimilarBookmark: null,
  hasMoreSimilar: false,
  isLoadingDetail: false,
  isLoadingMoreSimilar: false,
  lightboxOpen: false,

  boardImportModalOpen: false,
  isImportingBoards: false,
  boardImportProgress: null,
  lastBoardImportReport: null,

  getSpatialLayout() {
    return spatialLayout;
  },

  async bootstrap() {
    const state = get();
    void state.refreshImportedPinIds();
    if (state.sessionState === 'checking') return;
    if (state.sessionState === 'signedIn' && state.cards.length > 0) return;

    set({ sessionState: 'checking', feedError: null });
    try {
      const account = await getTransport().pinterestCheckSession();
      if (account) {
        set({
          sessionState: 'signedIn',
          account,
          needsReauth: false,
        });
        void get().refreshBoards();
        if (get().cards.length === 0) {
          await get().loadSource(get().activeSource);
        }
      } else {
        set({
          sessionState: 'signedOut',
          account: null,
          boards: [],
        });
      }
    } catch (err) {
      set({
        sessionState: 'signedOut',
        account: null,
        feedError: errorMessage(err, '检查 Pinterest 登录状态失败'),
      });
    }
  },

  async openLoginWindow() {
    try {
      await getTransport().pinterestOpenLoginWindow();
    } catch (err) {
      useCoordinatorStore.getState().pushToast({
        message: errorMessage(err, '无法打开 Pinterest 登录窗口'),
        tone: 'error',
      });
    }
  },

  async handleAuthChangedEvent(autoCloseLogin = false) {
    try {
      const account = await getTransport().pinterestCheckSession();
      if (account) {
        if (autoCloseLogin) {
          void getTransport().pinterestCloseLoginWindow().catch(() => {});
        }
        const wasSignedIn = get().sessionState === 'signedIn' && !get().needsReauth;
        set({
          sessionState: 'signedIn',
          account,
          needsReauth: false,
          feedError: null,
        });
        void get().refreshBoards();
        if (!wasSignedIn || get().cards.length === 0) {
          await get().loadSource(get().activeSource);
        }
      } else if (get().sessionState !== 'signedIn') {
        set({ sessionState: 'signedOut', account: null });
      }
    } catch {
      // Non-fatal while user is still typing credentials
    }
  },

  async signOut() {
    try {
      await getTransport().pinterestSignOut();
    } catch {
      // Ignore sign-out bridge cleanup failures
    }
    activeFeedEpoch += 1;
    spatialLayout.reset();
    detailCache.clear();
    set((s) => ({
      sessionState: 'signedOut',
      account: null,
      boards: [],
      needsReauth: false,
      activeSource: { kind: 'home' },
      cards: [],
      layoutRevision: s.layoutRevision + 1,
      contentBounds: { x: 0, y: 0, width: 0, height: 0 },
      nextBookmark: null,
      hasMoreFeed: false,
      isLoadingFeed: false,
      isLoadingMore: false,
      feedError: null,
      detailStack: [],
      activeDetailPin: null,
      activeSimilarPins: [],
      lightboxOpen: false,
      boardImportModalOpen: false,
    }));
  },

  async refreshImportedPinIds() {
    try {
      const ids = await getTransport().pinterestExistingImportedPinIds();
      set({ importedPinIds: makeIdRecord(ids) });
    } catch {
      // Non-fatal
    }
  },

  async refreshBoards() {
    const username = get().account?.username?.trim();
    if (!username) return;
    set({ isLoadingBoards: true });
    try {
      const boards = await getTransport().pinterestFetchBoards(username);
      set({ boards, isLoadingBoards: false });
    } catch (err) {
      set({ isLoadingBoards: false });
      if (isAuthError(err)) {
        set({ needsReauth: true });
      }
    }
  },

  setSearchQueryDraft(q) {
    set({ searchQueryDraft: q });
  },

  async loadSource(source) {
    const epoch = ++activeFeedEpoch;
    spatialLayout.reset();
    set((s) => ({
      activeSource: source,
      cards: [],
      layoutRevision: s.layoutRevision + 1,
      contentBounds: { x: 0, y: 0, width: 0, height: 0 },
      cameraResetNonce: s.cameraResetNonce + 1,
      nextBookmark: null,
      hasMoreFeed: false,
      isLoadingFeed: true,
      isLoadingMore: false,
      feedError: null,
      needsReauth: false,
    }));

    try {
      const page = await getTransport().pinterestFetchFeed(source, null, 36);
      if (epoch !== activeFeedEpoch) return;

      spatialLayout.append(page.pins);
      for (const pin of page.pins.slice(0, 18)) {
        warmImageUrl(pinDisplayImageUrl(pin, 224));
      }

      set((s) => ({
        cards: [...spatialLayout.cards],
        layoutRevision: s.layoutRevision + 1,
        contentBounds: { ...spatialLayout.contentBounds },
        nextBookmark: page.nextBookmark ?? null,
        hasMoreFeed: page.hasMore,
        isLoadingFeed: false,
      }));

      // Automatically pre-expand one extra ring if first page is small so the 2D canvas feels rich immediately.
      if (page.hasMore && page.nextBookmark && spatialLayout.cards.length < 48) {
        void get().loadNextPage();
      }
    } catch (err) {
      if (epoch !== activeFeedEpoch) return;
      const reauth = isAuthError(err);
      set({
        isLoadingFeed: false,
        needsReauth: reauth,
        feedError: errorMessage(err, '加载 Pinterest 灵感流失败'),
      });
    }
  },

  async submitSearch() {
    const query = get().searchQueryDraft.trim();
    if (!query) {
      await get().loadSource({ kind: 'home' });
      return;
    }
    await get().loadSource({ kind: 'search', query });
  },

  async loadMoreIfNeeded(visibleWorldRect) {
    const state = get();
    if (state.isLoadingFeed || state.isLoadingMore || !state.hasMoreFeed || !state.nextBookmark) {
      return;
    }
    if (spatialLayout.isApproachingEdge(visibleWorldRect, 520)) {
      await get().loadNextPage();
    }
  },

  async loadNextPage() {
    const state = get();
    if (state.isLoadingFeed || state.isLoadingMore || !state.hasMoreFeed || !state.nextBookmark) {
      return;
    }
    const epoch = activeFeedEpoch;
    const source = state.activeSource;
    const bookmark = state.nextBookmark;
    set({ isLoadingMore: true });

    try {
      const page = await getTransport().pinterestFetchFeed(source, bookmark, 32);
      if (epoch !== activeFeedEpoch) return;

      const inserted = spatialLayout.append(page.pins);
      for (const card of inserted.slice(0, 16)) {
        warmImageUrl(pinDisplayImageUrl(card.pin, 224));
      }

      const nextBm = page.nextBookmark && page.nextBookmark !== bookmark ? page.nextBookmark : null;
      set((s) => ({
        cards: [...spatialLayout.cards],
        layoutRevision: s.layoutRevision + 1,
        contentBounds: { ...spatialLayout.contentBounds },
        nextBookmark: nextBm,
        hasMoreFeed: Boolean(page.hasMore && nextBm && inserted.length > 0),
        isLoadingMore: false,
      }));
    } catch (err) {
      if (epoch !== activeFeedEpoch) return;
      set({
        isLoadingMore: false,
        needsReauth: isAuthError(err) ? true : get().needsReauth,
      });
    }
  },

  prefetchAhead(visibleWorldRect, lookaheadOffset, renderedCardWidth) {
    const upcoming = spatialLayout.predictivePrefetchCards(
      visibleWorldRect,
      lookaheadOffset,
      720,
      28,
    );
    for (const card of upcoming) {
      warmImageUrl(pinDisplayImageUrl(card.pin, renderedCardWidth));
    }
  },

  requestCenterCamera() {
    set((s) => ({ cameraResetNonce: s.cameraResetNonce + 1 }));
  },

  // MARK: - Persistent Shopping-Cart Collection Tray

  toggleTrayPin(pin) {
    if (get().collectedPinIds[pin.id]) {
      get().removeFromTray(pin.id);
    } else {
      get().addToTray(pin);
    }
  },

  addToTray(pin) {
    const state = get();
    if (state.collectedPinIds[pin.id]) return;
    const nextPins = [pin, ...state.collectedPins].slice(0, MAX_TRAY_ITEMS);
    persistTray(nextPins);
    set({
      collectedPins: nextPins,
      collectedPinIds: makeIdRecord(nextPins.map((p) => p.id)),
      traySelectedPinIds: {
        ...state.traySelectedPinIds,
        [pin.id]: true,
      },
    });
  },

  removeFromTray(pinId) {
    const state = get();
    if (!state.collectedPinIds[pinId]) return;
    const nextPins = state.collectedPins.filter((p) => p.id !== pinId);
    persistTray(nextPins);
    const nextSelected = { ...state.traySelectedPinIds };
    delete nextSelected[pinId];
    set({
      collectedPins: nextPins,
      collectedPinIds: makeIdRecord(nextPins.map((p) => p.id)),
      traySelectedPinIds: nextSelected,
      isTrayExpanded: nextPins.length > 0 ? state.isTrayExpanded : false,
    });
  },

  setTrayPinSelected(pinId, selected) {
    set((s) => {
      const next = { ...s.traySelectedPinIds };
      if (selected) {
        next[pinId] = true;
      } else {
        delete next[pinId];
      }
      return { traySelectedPinIds: next };
    });
  },

  selectAllTrayPins() {
    const pins = get().collectedPins;
    set({ traySelectedPinIds: makeIdRecord(pins.map((p) => p.id)) });
  },

  deselectAllTrayPins() {
    set({ traySelectedPinIds: {} });
  },

  removeSelectedFromTray() {
    const state = get();
    const nextPins = state.collectedPins.filter((p) => !state.traySelectedPinIds[p.id]);
    persistTray(nextPins);
    set({
      collectedPins: nextPins,
      collectedPinIds: makeIdRecord(nextPins.map((p) => p.id)),
      traySelectedPinIds: {},
      isTrayExpanded: nextPins.length > 0 ? state.isTrayExpanded : false,
    });
  },

  clearTray() {
    persistTray([]);
    set({
      collectedPins: [],
      collectedPinIds: {},
      traySelectedPinIds: {},
      isTrayExpanded: false,
    });
  },

  setTrayExpanded(expanded) {
    set({ isTrayExpanded: expanded });
  },

  setQuickCollectMode(fastPick) {
    set({ isQuickCollectMode: fastPick });
  },

  async importTrayPins(targetFolderId, extraTags, onlySelected = false) {
    const state = get();
    if (state.isImportingTray || state.collectedPins.length === 0) return null;
    const targetPins = onlySelected
      ? state.collectedPins.filter((p) => Boolean(state.traySelectedPinIds[p.id]))
      : state.collectedPins;
    if (targetPins.length === 0) return null;

    set({
      isImportingTray: true,
      trayImportProgress: {
        completed: 0,
        total: targetPins.length,
        currentTitle: targetPins[0]?.title || '准备入库…',
      },
    });

    try {
      const report = await getTransport().pinterestImportPins(
        targetPins,
        targetFolderId,
        extraTags,
        true,
      );
      const importedSet = new Set(Object.keys(get().importedPinIds));
      const processedIds = new Set<string>();
      for (const pin of targetPins) {
        if (!report.failedPinIDs.includes(pin.id)) {
          importedSet.add(pin.id);
          processedIds.add(pin.id);
        }
      }
      // Remove successfully imported/duplicate-skipped pins from the shopping cart; retain failed ones.
      const remainingPins = get().collectedPins.filter((p) => !processedIds.has(p.id));
      persistTray(remainingPins);
      const nextSelected: Record<string, true> = {};
      for (const p of remainingPins) {
        if (get().traySelectedPinIds[p.id]) {
          nextSelected[p.id] = true;
        }
      }

      set({
        isImportingTray: false,
        trayImportProgress: null,
        collectedPins: remainingPins,
        collectedPinIds: makeIdRecord(remainingPins.map((p) => p.id)),
        traySelectedPinIds: nextSelected,
        importedPinIds: makeIdRecord(importedSet),
        isTrayExpanded: remainingPins.length > 0 ? get().isTrayExpanded : false,
      });

      const summaryParts: string[] = [];
      if (report.importedAssets.length > 0) {
        summaryParts.push(`已入库 ${report.importedAssets.length} 项原图素材`);
      }
      if (report.skippedDuplicatePinIDs.length > 0) {
        summaryParts.push(`跳过已存在 ${report.skippedDuplicatePinIDs.length} 项`);
      }
      if (report.failedPinIDs.length > 0) {
        summaryParts.push(`失败 ${report.failedPinIDs.length} 项`);
      }
      const message = summaryParts.join(' · ') || '没有新增入库素材';
      set({ lastStatusBanner: message });
      useCoordinatorStore.getState().pushToast({
        message,
        tone: report.failedPinIDs.length > 0 ? 'info' : 'success',
      });
      void useLibraryStore.getState().refreshAll(useCoordinatorStore.getState().destination);
      return report;
    } catch (err) {
      set({ isImportingTray: false, trayImportProgress: null });
      useCoordinatorStore.getState().pushToast({
        message: errorMessage(err, '批量入库失败'),
        tone: 'error',
      });
      return null;
    }
  },

  async importSinglePinDirectly(pin, targetFolderId = null) {
    if (get().isImportingTray) return null;
    set({
      isImportingTray: true,
      trayImportProgress: {
        completed: 0,
        total: 1,
        currentTitle: pin.title || `Pinterest ${pin.id}`,
      },
    });
    try {
      const report = await getTransport().pinterestImportPins([pin], targetFolderId, [], true);
      const importedSet = new Set(Object.keys(get().importedPinIds));
      if (!report.failedPinIDs.includes(pin.id)) {
        importedSet.add(pin.id);
      }
      set({
        isImportingTray: false,
        trayImportProgress: null,
        importedPinIds: makeIdRecord(importedSet),
      });
      const message =
        report.importedAssets.length > 0
          ? '已将高清原图直接入库到 Charkle'
          : report.skippedDuplicatePinIDs.length > 0
            ? '该素材已在 Charkle 素材库中'
            : report.errors[0] || '直接入库失败';
      useCoordinatorStore.getState().pushToast({
        message,
        tone: report.failedPinIDs.length > 0 ? 'error' : 'success',
      });
      void useLibraryStore.getState().refreshAll(useCoordinatorStore.getState().destination);
      return report;
    } catch (err) {
      set({ isImportingTray: false, trayImportProgress: null });
      useCoordinatorStore.getState().pushToast({
        message: errorMessage(err, '直接入库失败'),
        tone: 'error',
      });
      return null;
    }
  },

  // MARK: - Floating Pin Detail Overlay & Similar Pins

  async openPinDetail(pin, pushHistory = true) {
    const prev = get().activeDetailPin;
    const nextStack =
      pushHistory && prev && prev.id !== pin.id ? [...get().detailStack, prev] : get().detailStack;

    const cached = detailCache.get(pin.id);
    if (cached) {
      set({
        detailStack: nextStack,
        activeDetailPin: cached.pin,
        activeSimilarPins: cached.similarPins,
        activeSimilarBookmark: cached.nextSimilarBookmark ?? null,
        hasMoreSimilar: cached.hasMoreSimilar,
        isLoadingDetail: false,
        lightboxOpen: false,
      });
      return;
    }

    set({
      detailStack: nextStack,
      activeDetailPin: pin,
      activeSimilarPins: [],
      activeSimilarBookmark: null,
      hasMoreSimilar: false,
      isLoadingDetail: true,
      lightboxOpen: false,
    });

    try {
      const result = await getTransport().pinterestFetchPinDetail(pin);
      detailCache.set(pin.id, result);
      if (get().activeDetailPin?.id !== pin.id) return;
      set({
        activeDetailPin: result.pin,
        activeSimilarPins: result.similarPins,
        activeSimilarBookmark: result.nextSimilarBookmark ?? null,
        hasMoreSimilar: result.hasMoreSimilar,
        isLoadingDetail: false,
      });
    } catch (err) {
      if (get().activeDetailPin?.id !== pin.id) return;
      set({
        isLoadingDetail: false,
        needsReauth: isAuthError(err) ? true : get().needsReauth,
      });
    }
  },

  async popPinDetail() {
    const stack = get().detailStack;
    if (stack.length === 0) {
      get().closePinDetail();
      return;
    }
    const previous = stack[stack.length - 1];
    set({ detailStack: stack.slice(0, -1) });
    await get().openPinDetail(previous, false);
  },

  closePinDetail() {
    set({
      detailStack: [],
      activeDetailPin: null,
      activeSimilarPins: [],
      activeSimilarBookmark: null,
      hasMoreSimilar: false,
      isLoadingDetail: false,
      isLoadingMoreSimilar: false,
      lightboxOpen: false,
    });
  },

  async loadMoreSimilarPins() {
    const state = get();
    const pin = state.activeDetailPin;
    if (!pin || state.isLoadingMoreSimilar || !state.hasMoreSimilar || !state.activeSimilarBookmark) {
      return;
    }
    set({ isLoadingMoreSimilar: true });
    try {
      const page = await getTransport().pinterestFetchSimilarPins(
        pin,
        state.activeSimilarBookmark,
        28,
      );
      if (get().activeDetailPin?.id !== pin.id) return;
      const seen = new Set([pin.id, ...get().activeSimilarPins.map((p) => p.id)]);
      const merged = [...get().activeSimilarPins];
      for (const item of page.pins) {
        if (!seen.has(item.id)) {
          seen.add(item.id);
          merged.push(item);
        }
      }
      const nextBm =
        page.nextBookmark && page.nextBookmark !== state.activeSimilarBookmark
          ? page.nextBookmark
          : null;
      set({
        activeSimilarPins: merged,
        activeSimilarBookmark: nextBm,
        hasMoreSimilar: Boolean(page.hasMore && nextBm),
        isLoadingMoreSimilar: false,
      });
    } catch {
      set({ isLoadingMoreSimilar: false });
    }
  },

  async exploreSimilarInSpace(pin) {
    get().closePinDetail();
    await get().loadSource({ kind: 'similar', seedPin: pin });
  },

  setLightboxOpen(open) {
    set({ lightboxOpen: open });
  },

  // MARK: - Batch Board Import Modal

  openBoardImportModal() {
    set({
      boardImportModalOpen: true,
      lastBoardImportReport: null,
    });
    if (get().boards.length === 0) {
      void get().refreshBoards();
    }
  },

  closeBoardImportModal() {
    if (get().isImportingBoards) return;
    set({ boardImportModalOpen: false });
  },

  async startBoardBatchImport(boards, destination, extraTags, skipDuplicates) {
    if (get().isImportingBoards || boards.length === 0) return null;
    set({
      isImportingBoards: true,
      lastBoardImportReport: null,
      boardImportProgress: {
        totalBoards: boards.length,
        completedBoards: 0,
        currentBoardName: boards[0]?.name || '',
        currentBoardIndex: 0,
        currentBoardPinCount: boards[0]?.pinCount ?? 0,
        currentBoardProcessedPins: 0,
        importedCount: 0,
        skippedCount: 0,
        failedCount: 0,
        phaseMessage: '准备同步 Pinterest 画板…',
      },
    });

    try {
      const report = await getTransport().pinterestImportBoards(
        boards,
        destination,
        extraTags,
        skipDuplicates,
      );
      set({
        isImportingBoards: false,
        boardImportProgress: null,
        lastBoardImportReport: report,
      });
      void get().refreshImportedPinIds();
      void useLibraryStore.getState().refreshAll(useCoordinatorStore.getState().destination);

      const summary = report.wasCancelled
        ? `已取消画板导入（已入库 ${report.importedAssetCount} 项）`
        : `画板导入完成：新增 ${report.importedAssetCount} 项，跳过重复 ${report.skippedDuplicateCount} 项${report.failedPinCount > 0 ? `，失败 ${report.failedPinCount} 项` : ''}`;
      useCoordinatorStore.getState().pushToast({
        message: summary,
        tone: report.wasCancelled ? 'info' : 'success',
      });
      return report;
    } catch (err) {
      set({ isImportingBoards: false, boardImportProgress: null });
      useCoordinatorStore.getState().pushToast({
        message: errorMessage(err, '画板批量导入失败'),
        tone: 'error',
      });
      return null;
    }
  },

  async cancelBoardBatchImport() {
    if (!get().isImportingBoards) return;
    try {
      await getTransport().pinterestCancelBoardImport();
    } catch {
      // Ignore
    }
  },

  handleTrayImportProgressEvent(progress) {
    set({ trayImportProgress: progress });
  },

  handleBoardImportProgressEvent(progress) {
    set({ boardImportProgress: progress });
  },

  clearStatusBanner() {
    set({ lastStatusBanner: null });
  },
}));
