import { create } from 'zustand';
import { getTransport } from '../api/transport';
import { applyThemeToDocument, type ThemeMode } from '../design-system/theme';
import type {
  GalleryLayoutMode,
  SettingsTabId,
  SidebarDestination,
  WindowSurfaceState,
} from '../types/domain';

export interface ToastItem {
  id: string;
  message: string;
  tone?: 'info' | 'success' | 'error';
  actionLabel?: string;
  onAction?: () => void;
  durationMs?: number;
}

export interface QuickLookOriginRect {
  left: number;
  top: number;
  width: number;
  height: number;
}

export type InspectorTab = 'info' | 'similar';

export type MoodboardGeneratorEntry = 'prompt' | 'seedAssets' | 'palette' | 'selection';

export type InspectorCardId =
  | 'previewIdentity'
  | 'quickActions'
  | 'colorsAndTags'
  | 'notesAndOCR'
  | 'aiGeneration'
  | 'photoExif'
  | 'mediaSpecs'
  | 'githubRepo'
  | 'socialMediaExtract';

export const DEFAULT_INSPECTOR_CARD_ORDER: InspectorCardId[] = [
  'previewIdentity',
  'quickActions',
  'colorsAndTags',
  'notesAndOCR',
  'aiGeneration',
  'photoExif',
  'mediaSpecs',
  'githubRepo',
  'socialMediaExtract',
];

export type SettingsTab = SettingsTabId;

export interface GalleryRevealRequest {
  assetId: string;
  sourceBoardId?: string | null;
  sourceBoardTitle?: string | null;
  nonce: number;
}

const THEME_STORAGE_KEY = 'charkle.win.theme';
const LAYOUT_STORAGE_KEY = 'charkle.win.layout';
const SCALE_STORAGE_KEY = 'charkle.win.cardScale';
const ONBOARDING_DONE_KEY = 'charkle.win.onboardingDone.v2';
const SIDEBAR_COLLAPSED_KEY = 'charkle.win.sidebarCollapsed';
const INSPECTOR_ORDER_STORAGE_KEY = 'charkle.win.inspectorOrder.v3';
const LEGACY_INSPECTOR_ORDER_STORAGE_KEY = 'charkle.win.inspectorOrder.v2';

const LEGACY_CARD_ID_MAP: Record<string, InspectorCardId> = {
  core: 'previewIdentity',
  location: 'quickActions',
  palette: 'colorsAndTags',
  tags: 'colorsAndTags',
  aiGen: 'aiGeneration',
  exif: 'photoExif',
};

export function normalizeInspectorCardOrder(raw: unknown): InspectorCardId[] {
  const result: InspectorCardId[] = [];
  const seen = new Set<InspectorCardId>();
  if (Array.isArray(raw)) {
    for (const entry of raw) {
      if (typeof entry !== 'string') continue;
      const mapped = (
        DEFAULT_INSPECTOR_CARD_ORDER.includes(entry as InspectorCardId)
          ? entry
          : LEGACY_CARD_ID_MAP[entry]
      ) as InspectorCardId | undefined;
      if (mapped && !seen.has(mapped)) {
        seen.add(mapped);
        result.push(mapped);
      }
    }
  }
  for (const fallback of DEFAULT_INSPECTOR_CARD_ORDER) {
    if (!seen.has(fallback)) {
      seen.add(fallback);
      result.push(fallback);
    }
  }
  return result;
}

export function isInspectorCardOrderCustomized(order: InspectorCardId[]): boolean {
  if (order.length !== DEFAULT_INSPECTOR_CARD_ORDER.length) return true;
  return order.some((id, idx) => DEFAULT_INSPECTOR_CARD_ORDER[idx] !== id);
}

function readStoredInspectorCardOrder(): InspectorCardId[] {
  if (typeof localStorage === 'undefined') return [...DEFAULT_INSPECTOR_CARD_ORDER];
  try {
    const rawV3 = localStorage.getItem(INSPECTOR_ORDER_STORAGE_KEY);
    if (rawV3) {
      return normalizeInspectorCardOrder(JSON.parse(rawV3));
    }
    const rawV2 = localStorage.getItem(LEGACY_INSPECTOR_ORDER_STORAGE_KEY);
    if (rawV2) {
      const migrated = normalizeInspectorCardOrder(JSON.parse(rawV2));
      localStorage.setItem(INSPECTOR_ORDER_STORAGE_KEY, JSON.stringify(migrated));
      return migrated;
    }
  } catch {
    // Ignore malformed localStorage
  }
  return [...DEFAULT_INSPECTOR_CARD_ORDER];
}

function persistInspectorCardOrder(order: InspectorCardId[]): void {
  if (typeof localStorage === 'undefined') return;
  try {
    localStorage.setItem(INSPECTOR_ORDER_STORAGE_KEY, JSON.stringify(order));
  } catch {
    // Ignore quota errors
  }
}

function readOnboardingDone(): boolean {
  if (typeof localStorage === 'undefined') return true;
  return localStorage.getItem(ONBOARDING_DONE_KEY) === '1';
}

function readStoredTheme(): ThemeMode {
  if (typeof localStorage === 'undefined') return 'system';
  const raw = localStorage.getItem(THEME_STORAGE_KEY);
  if (raw === 'light' || raw === 'dark' || raw === 'system') return raw;
  return 'system';
}

function readStoredLayout(): GalleryLayoutMode {
  if (typeof localStorage === 'undefined') return 'verticalMasonry';
  const raw = localStorage.getItem(LAYOUT_STORAGE_KEY);
  if (
    raw === 'verticalMasonry' ||
    raw === 'horizontalJustified' ||
    raw === 'galleryFilmstrip' ||
    raw === 'ringGallery'
  ) {
    return raw;
  }
  return 'verticalMasonry';
}

function readStoredScale(): number {
  if (typeof localStorage === 'undefined') return 236;
  const raw = Number(localStorage.getItem(SCALE_STORAGE_KEY));
  if (Number.isFinite(raw) && raw >= 130 && raw <= 420) return raw;
  return 236;
}

function readStoredSidebarCollapsed(): boolean {
  if (typeof localStorage === 'undefined') return false;
  return localStorage.getItem(SIDEBAR_COLLAPSED_KEY) === '1';
}

export interface CoordinatorState {
  themeMode: ThemeMode;
  surfaceState: WindowSurfaceState | null;
  sidebarOpen: boolean;
  sidebarCollapsed: boolean;
  inspectorOpen: boolean;
  inspectorTab: InspectorTab;
  inspectorCardOrder: InspectorCardId[];
  visualFilterBarOpen: boolean;
  layoutMode: GalleryLayoutMode;
  cardScale: number;
  destination: SidebarDestination;
  selectedAssetIds: string[];
  lastSelectedAssetId: string | null;
  quickLookAssetId: string | null;
  quickLookOriginRect: QuickLookOriginRect | null;
  pendingGalleryReveal: GalleryRevealRequest | null;
  jumpOpen: boolean;
  captureOpen: boolean;
  settingsOpen: boolean;
  settingsTab: SettingsTabId;
  onboardingOpen: boolean;
  onboardingDone: boolean;
  onboardingStep: number;
  onboardingRunId: number;
  resumeOnboardingOnSettingsClose: boolean;
  moodboardGeneratorOpen: boolean;
  moodboardGeneratorEntry: MoodboardGeneratorEntry;
  activeMoodboardId: string | null;
  toasts: ToastItem[];

  setThemeMode: (mode: ThemeMode) => Promise<void>;
  syncWindowChrome: () => Promise<void>;
  setSidebarOpen: (open: boolean) => void;
  toggleSidebar: () => void;
  setSidebarCollapsed: (collapsed: boolean) => void;
  toggleSidebarCollapsed: () => void;
  setInspectorOpen: (open: boolean) => void;
  toggleInspector: () => void;
  setInspectorTab: (tab: InspectorTab) => void;
  moveInspectorCard: (dragged: InspectorCardId, target: InspectorCardId) => void;
  moveInspectorCardToTop: (id: InspectorCardId) => void;
  moveInspectorCardToBottom: (id: InspectorCardId) => void;
  stepInspectorCard: (id: InspectorCardId, delta: number, visibleIds: InspectorCardId[]) => void;
  resetInspectorCardOrder: () => void;
  setVisualFilterBarOpen: (open: boolean) => void;
  toggleVisualFilterBar: () => void;
  setLayoutMode: (mode: GalleryLayoutMode) => void;
  setCardScale: (scale: number) => void;
  setDestination: (dest: SidebarDestination, opts?: { preserveSelection?: boolean }) => void;
  selectAsset: (
    id: string,
    orderedIds: string[],
    opts?: { multi?: boolean; range?: boolean },
  ) => void;
  setSelection: (ids: string[], lastId?: string | null) => void;
  clearSelection: () => void;
  openQuickLook: (id: string, originRect?: QuickLookOriginRect | null) => void;
  closeQuickLook: () => void;
  requestGalleryReveal: (req: Omit<GalleryRevealRequest, 'nonce'>) => void;
  clearPendingGalleryReveal: () => void;
  setJumpOpen: (open: boolean) => void;
  setCaptureOpen: (open: boolean) => void;
  openSettings: (tab?: SettingsTabId) => void;
  openSettingsFromOnboarding: (tab: SettingsTabId) => void;
  closeSettings: () => void;
  setSettingsTab: (tab: SettingsTabId) => void;
  openOnboarding: () => void;
  setOnboardingOpen: (open: boolean) => void;
  setOnboardingStep: (step: number) => void;
  completeOnboarding: () => void;
  setMoodboardGeneratorOpen: (open: boolean) => void;
  openMoodboardGenerator: (entry?: MoodboardGeneratorEntry) => void;
  setActiveMoodboardId: (id: string | null) => void;
  pushToast: (toast: Omit<ToastItem, 'id'>) => string;
  dismissToast: (id: string) => void;
}

let toastSeq = 0;
let revealSeq = 0;
let onboardingRunSeq = 0;

export const useCoordinatorStore = create<CoordinatorState>((set, get) => ({
  themeMode: readStoredTheme(),
  surfaceState: null,
  sidebarOpen: true,
  sidebarCollapsed: readStoredSidebarCollapsed(),
  inspectorOpen: true,
  inspectorTab: 'info',
  inspectorCardOrder: readStoredInspectorCardOrder(),
  visualFilterBarOpen: false,
  layoutMode: readStoredLayout(),
  cardScale: readStoredScale(),
  destination: { type: 'allItems' },
  selectedAssetIds: [],
  lastSelectedAssetId: null,
  quickLookAssetId: null,
  quickLookOriginRect: null,
  pendingGalleryReveal: null,
  jumpOpen: false,
  captureOpen: false,
  settingsOpen: false,
  settingsTab: 'general',
  onboardingOpen: false,
  onboardingDone: readOnboardingDone(),
  onboardingStep: 0,
  onboardingRunId: 0,
  resumeOnboardingOnSettingsClose: false,
  moodboardGeneratorOpen: false,
  moodboardGeneratorEntry: 'prompt',
  activeMoodboardId: null,
  toasts: [],

  async setThemeMode(mode) {
    set({ themeMode: mode });
    if (typeof localStorage !== 'undefined') {
      localStorage.setItem(THEME_STORAGE_KEY, mode);
    }
    const effective = applyThemeToDocument(mode);
    try {
      const surface = await getTransport().setWindowTheme(effective === 'dark');
      set({ surfaceState: surface });
      if (typeof document !== 'undefined') {
        document.documentElement.dataset.backdrop = surface.backdrop;
      }
    } catch {
      if (typeof document !== 'undefined') {
        document.documentElement.dataset.backdrop = 'solidFallback';
      }
    }
  },

  async syncWindowChrome() {
    const mode = get().themeMode;
    const effective = applyThemeToDocument(mode);
    try {
      const surface = await getTransport().setWindowTheme(effective === 'dark');
      set({ surfaceState: surface });
      if (typeof document !== 'undefined') {
        document.documentElement.dataset.backdrop = surface.backdrop;
      }
    } catch {
      if (typeof document !== 'undefined') {
        document.documentElement.dataset.backdrop = 'solidFallback';
      }
    }
  },

  setSidebarOpen(open) {
    set({ sidebarOpen: open });
  },

  toggleSidebar() {
    set((s) => ({ sidebarOpen: !s.sidebarOpen }));
  },

  setSidebarCollapsed(collapsed) {
    set({ sidebarCollapsed: collapsed });
    if (typeof localStorage !== 'undefined') {
      localStorage.setItem(SIDEBAR_COLLAPSED_KEY, collapsed ? '1' : '0');
    }
  },

  toggleSidebarCollapsed() {
    const next = !get().sidebarCollapsed;
    get().setSidebarCollapsed(next);
  },

  setInspectorOpen(open) {
    set({ inspectorOpen: open });
  },

  toggleInspector() {
    set((s) => ({ inspectorOpen: !s.inspectorOpen }));
  },

  setInspectorTab(tab) {
    set({ inspectorTab: tab });
  },

  moveInspectorCard(dragged, target) {
    if (dragged === target) return;
    const current = get().inspectorCardOrder;
    const fromIdx = current.indexOf(dragged);
    const toIdx = current.indexOf(target);
    if (fromIdx === -1 || toIdx === -1) return;
    const next = [...current];
    const [item] = next.splice(fromIdx, 1);
    next.splice(toIdx, 0, item);
    persistInspectorCardOrder(next);
    set({ inspectorCardOrder: next });
  },

  moveInspectorCardToTop(id) {
    const current = get().inspectorCardOrder;
    const idx = current.indexOf(id);
    if (idx <= 0) return;
    const next = [...current];
    const [item] = next.splice(idx, 1);
    next.unshift(item);
    persistInspectorCardOrder(next);
    set({ inspectorCardOrder: next });
  },

  moveInspectorCardToBottom(id) {
    const current = get().inspectorCardOrder;
    const idx = current.indexOf(id);
    if (idx === -1 || idx === current.length - 1) return;
    const next = [...current];
    const [item] = next.splice(idx, 1);
    next.push(item);
    persistInspectorCardOrder(next);
    set({ inspectorCardOrder: next });
  },

  stepInspectorCard(id, delta, visibleIds) {
    if (delta === 0) return;
    const visIdx = visibleIds.indexOf(id);
    if (visIdx === -1) return;
    const targetVisIdx = visIdx + (delta > 0 ? 1 : -1);
    if (targetVisIdx < 0 || targetVisIdx >= visibleIds.length) return;
    get().moveInspectorCard(id, visibleIds[targetVisIdx]);
  },

  resetInspectorCardOrder() {
    const next = [...DEFAULT_INSPECTOR_CARD_ORDER];
    persistInspectorCardOrder(next);
    set({ inspectorCardOrder: next });
  },

  setVisualFilterBarOpen(open) {
    set({ visualFilterBarOpen: open });
  },

  toggleVisualFilterBar() {
    set((s) => ({ visualFilterBarOpen: !s.visualFilterBarOpen }));
  },

  setLayoutMode(mode) {
    set({ layoutMode: mode });
    if (typeof localStorage !== 'undefined') {
      localStorage.setItem(LAYOUT_STORAGE_KEY, mode);
    }
  },

  setCardScale(scale) {
    const clamped = Math.max(130, Math.min(420, Math.round(scale)));
    set({ cardScale: clamped });
    if (typeof localStorage !== 'undefined') {
      localStorage.setItem(SCALE_STORAGE_KEY, String(clamped));
    }
  },

  setDestination(dest, opts) {
    set((s) => ({
      destination: dest,
      selectedAssetIds: opts?.preserveSelection ? s.selectedAssetIds : [],
      lastSelectedAssetId: opts?.preserveSelection ? s.lastSelectedAssetId : null,
      activeMoodboardId: dest.type === 'moodboard' ? dest.id : s.activeMoodboardId,
    }));
  },

  selectAsset(id, orderedIds, opts) {
    const { selectedAssetIds, lastSelectedAssetId } = get();
    if (opts?.range && lastSelectedAssetId) {
      const a = orderedIds.indexOf(lastSelectedAssetId);
      const b = orderedIds.indexOf(id);
      if (a !== -1 && b !== -1) {
        const [start, end] = a < b ? [a, b] : [b, a];
        const slice = orderedIds.slice(start, end + 1);
        const merged = opts.multi
          ? Array.from(new Set([...selectedAssetIds, ...slice]))
          : slice;
        set({ selectedAssetIds: merged, lastSelectedAssetId: id });
        return;
      }
    }
    if (opts?.multi) {
      const exists = selectedAssetIds.includes(id);
      const next = exists
        ? selectedAssetIds.filter((x) => x !== id)
        : [...selectedAssetIds, id];
      set({ selectedAssetIds: next, lastSelectedAssetId: id });
      return;
    }
    set({ selectedAssetIds: [id], lastSelectedAssetId: id });
  },

  setSelection(ids, lastId) {
    set({
      selectedAssetIds: Array.from(new Set(ids)),
      lastSelectedAssetId: lastId !== undefined ? lastId : (ids[ids.length - 1] ?? null),
    });
  },

  clearSelection() {
    set({ selectedAssetIds: [], lastSelectedAssetId: null });
  },

  openQuickLook(id, originRect = null) {
    // Resign stale text focus (e.g. search bar) so Spacebar dismiss always works deterministically
    if (typeof document !== 'undefined' && document.activeElement instanceof HTMLElement) {
      document.activeElement.blur();
    }
    set({
      quickLookAssetId: id,
      quickLookOriginRect: originRect,
    });
  },

  closeQuickLook() {
    set({ quickLookAssetId: null, quickLookOriginRect: null });
  },

  requestGalleryReveal(req) {
    set({
      pendingGalleryReveal: {
        ...req,
        nonce: ++revealSeq,
      },
    });
  },

  clearPendingGalleryReveal() {
    set({ pendingGalleryReveal: null });
  },

  setJumpOpen(open) {
    set({ jumpOpen: open });
  },

  setCaptureOpen(open) {
    set(
      open
        ? {
            captureOpen: true,
            jumpOpen: false,
            quickLookAssetId: null,
            quickLookOriginRect: null,
          }
        : { captureOpen: false },
    );
  },

  openSettings(tab) {
    set((s) => ({
      settingsOpen: true,
      settingsTab: tab ?? s.settingsTab,
      jumpOpen: false,
      quickLookAssetId: null,
      quickLookOriginRect: null,
      resumeOnboardingOnSettingsClose: false,
    }));
  },

  openSettingsFromOnboarding(tab) {
    set({
      onboardingOpen: false,
      settingsOpen: true,
      settingsTab: tab,
      jumpOpen: false,
      quickLookAssetId: null,
      quickLookOriginRect: null,
      resumeOnboardingOnSettingsClose: true,
    });
  },

  closeSettings() {
    if (get().resumeOnboardingOnSettingsClose) {
      set({
        settingsOpen: false,
        resumeOnboardingOnSettingsClose: false,
        onboardingOpen: true,
      });
      return;
    }
    set({ settingsOpen: false });
  },

  setSettingsTab(tab) {
    set({ settingsTab: tab });
  },

  openOnboarding() {
    set({
      settingsOpen: false,
      jumpOpen: false,
      quickLookAssetId: null,
      quickLookOriginRect: null,
      onboardingStep: 0,
      onboardingRunId: ++onboardingRunSeq,
      resumeOnboardingOnSettingsClose: false,
      onboardingOpen: true,
    });
  },

  setOnboardingOpen(open) {
    set({ onboardingOpen: open });
  },

  setOnboardingStep(step) {
    const next = Number.isFinite(step) ? Math.max(0, Math.floor(step)) : 0;
    set({ onboardingStep: next });
  },

  completeOnboarding() {
    if (typeof localStorage !== 'undefined') {
      localStorage.setItem(ONBOARDING_DONE_KEY, '1');
    }
    set({
      onboardingOpen: false,
      onboardingDone: true,
      resumeOnboardingOnSettingsClose: false,
      onboardingStep: 0,
    });
  },

  setMoodboardGeneratorOpen(open) {
    set(
      open
        ? {
            moodboardGeneratorOpen: true,
            jumpOpen: false,
            quickLookAssetId: null,
            quickLookOriginRect: null,
          }
        : { moodboardGeneratorOpen: false },
    );
  },

  openMoodboardGenerator(entry = 'prompt') {
    set({
      moodboardGeneratorEntry: entry,
      moodboardGeneratorOpen: true,
      jumpOpen: false,
      quickLookAssetId: null,
      quickLookOriginRect: null,
    });
  },

  setActiveMoodboardId(id) {
    set({ activeMoodboardId: id });
  },

  pushToast(toast) {
    const id = `toast-${++toastSeq}`;
    set((s) => ({
      toasts: [...s.toasts.slice(-3), { ...toast, id }],
    }));
    return id;
  },

  dismissToast(id) {
    set((s) => ({
      toasts: s.toasts.filter((t) => t.id !== id),
    }));
  },
}));
