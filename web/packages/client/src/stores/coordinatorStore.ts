import { create } from 'zustand';
import {
  DEFAULT_INSPECTOR_SECTION_ORDER,
  normalizeInspectorSectionOrder,
} from '@charkle/shared';
import type {
  GalleryLayoutMode,
  InspectorInfoSection,
  SidebarDestination,
  UUID,
} from '@charkle/shared';
import { applyThemeToDocument } from '../design-system/theme';
import type { ThemeMode } from '../design-system/theme';
import { stopAllHoverPreviews } from '../components/hoverMediaCoordinator';

export type SettingsTabID =
  | 'general'
  | 'accountSecurity'
  | 'library'
  | 'sync'
  | 'captureShortcuts'
  | 'ai'
  | 'externalAgents'
  | 'extensions'
  | 'advancedAbout';

export type CaptureTarget =
  | { type: 'inbox' }
  | { type: 'folder'; folderID: UUID }
  | { type: 'activeMoodboard' };

export type QuickCaptureTab = 'upload' | 'url' | 'note' | 'color' | 'screen';

export interface QuickCapturePrefill {
  tab?: QuickCaptureTab;
  url?: string;
  title?: string;
  text?: string;
  hex?: string;
}

export interface SourceRect {
  left: number;
  top: number;
  width: number;
  height: number;
}

export type ToastTone = 'info' | 'success' | 'warning' | 'error';

export interface ToastItem {
  id: string;
  message: string;
  tone?: ToastTone;
  actionLabel?: string;
  onAction?: () => void;
  durationMs?: number;
  paused?: boolean;
  remainingMs?: number;
  exiting?: boolean;
}

export interface ReturnToMoodboardState {
  boardID: UUID;
  boardTitle?: string | null;
}

export interface PendingGalleryReveal {
  assetID: UUID;
  nonce: number;
}

const STORAGE_KEYS = {
  theme: 'charkle.themeMode',
  iconVariant: 'charkle.brandIconVariant',
  layoutMode: 'charkle.layoutMode',
  colWidth: 'charkle.targetColumnWidth',
  sidebarCollapsed: 'charkle.sidebarCollapsed',
  inspectorOpen: 'charkle.inspectorOpen',
  selectedInspectorTab: 'charkle.selectedInspectorTab',
  inspectorSectionOrder: 'charkle.inspectorSectionOrder',
  activeBoardID: 'charkle.activeBoardID',
  captureTarget: 'charkle.captureTarget',
  hasCompletedOnboarding: 'charkle.hasCompletedOnboarding',
} as const;

function readLS<T>(key: string, fallback: T): T {
  if (typeof window === 'undefined') return fallback;
  try {
    const raw = window.localStorage.getItem(key);
    if (raw === null) return fallback;
    return JSON.parse(raw) as T;
  } catch {
    return fallback;
  }
}

function writeLS(key: string, value: unknown): void {
  if (typeof window === 'undefined') return;
  try {
    window.localStorage.setItem(key, JSON.stringify(value));
  } catch {
    // Ignore storage quota errors
  }
}

interface CoordinatorState {
  destination: SidebarDestination;
  sidebarCollapsed: boolean;
  layoutMode: GalleryLayoutMode;
  targetColumnWidth: number;
  inspectorOpen: boolean;
  selectedInspectorTab: 'info' | 'similar';
  inspectorSectionOrder: InspectorInfoSection[];

  pendingGalleryReveal: PendingGalleryReveal | null;
  revealHighlightAssetID: UUID | null;
  returnToMoodboardState: ReturnToMoodboardState | null;
  expandedSidebarFolderIDs: UUID[];

  quickLookAssetID: UUID | null;
  quickLookSourceRect: SourceRect | null;
  quickLookHiddenAssetID: UUID | null;
  jumpAnywhereOpen: boolean;

  settingsOpen: boolean;
  settingsTab: SettingsTabID;

  hasCompletedOnboarding: boolean;
  onboardingOpen: boolean;
  onboardingRunID: number;

  generatorModalOpen: boolean;
  generatorInitialSeedAssetIDs: UUID[];

  showQuickCapture: boolean;
  quickCapturePrefill: QuickCapturePrefill | null;
  captureTarget: CaptureTarget;

  activeBoardID: UUID | null;

  themeMode: ThemeMode;
  brandIconVariant: 'auto' | 'light' | 'dark';

  toasts: ToastItem[];

  navigate: (destination: SidebarDestination) => void;
  openBoard: (boardID: UUID) => void;
  setActiveBoardID: (boardID: UUID | null) => void;

  setSidebarCollapsed: (collapsed: boolean) => void;
  toggleSidebar: () => void;
  setLayoutMode: (mode: GalleryLayoutMode) => void;
  setTargetColumnWidth: (width: number) => void;
  setInspectorOpen: (open: boolean) => void;
  toggleInspector: () => void;
  setSelectedInspectorTab: (tab: 'info' | 'similar') => void;
  setInspectorSectionOrder: (order: readonly InspectorInfoSection[]) => void;
  resetInspectorSectionOrder: () => void;

  requestRevealAssetInGallery: (assetID: UUID) => void;
  clearPendingGalleryReveal: (nonce: number) => void;
  setRevealHighlightAssetID: (assetID: UUID | null) => void;
  setReturnToMoodboardState: (state: ReturnToMoodboardState | null) => void;

  toggleSidebarFolderExpanded: (id: UUID) => void;
  setSidebarFolderExpanded: (id: UUID, expanded: boolean) => void;
  revealSidebarFolderAncestors: (ids: readonly UUID[]) => void;

  openQuickLook: (assetID: UUID, sourceRect?: SourceRect | null) => void;
  closeQuickLook: () => void;
  setQuickLookHiddenAssetID: (assetID: UUID | null) => void;

  setJumpAnywhereOpen: (open: boolean) => void;
  toggleJumpAnywhere: () => void;

  openSettings: (tab?: SettingsTabID) => void;
  closeSettings: () => void;
  setSettingsTab: (tab: SettingsTabID) => void;

  presentOnboardingIfFirstLaunch: () => void;
  presentOnboarding: () => void;
  completeOnboarding: () => void;

  openGeneratorModal: (seedAssetIDs?: UUID[]) => void;
  closeGeneratorModal: () => void;

  openQuickCapture: (prefill?: QuickCapturePrefill | null) => void;
  closeQuickCapture: () => void;
  setCaptureTarget: (target: CaptureTarget) => void;

  setThemeMode: (mode: ThemeMode) => void;
  setBrandIconVariant: (variant: 'auto' | 'light' | 'dark') => void;

  isOverlayPresented: () => boolean;

  pushToast: (toast: Omit<ToastItem, 'id'>) => string;
  pauseToast: (id: string) => void;
  resumeToast: (id: string) => void;
  triggerToastAction: (id: string) => void;
  dismissToast: (id: string) => void;
}

const initialTheme = readLS<ThemeMode>(STORAGE_KEYS.theme, 'system');
const initialIconVariant = readLS<'auto' | 'light' | 'dark'>(STORAGE_KEYS.iconVariant, 'auto');
const initialInspectorTabRaw = readLS<string>(STORAGE_KEYS.selectedInspectorTab, 'info');
const initialInspectorTab: 'info' | 'similar' =
  initialInspectorTabRaw === 'similar' ? 'similar' : 'info';
const initialSectionOrder = normalizeInspectorSectionOrder(
  readLS<string[]>(STORAGE_KEYS.inspectorSectionOrder, [...DEFAULT_INSPECTOR_SECTION_ORDER]),
);

if (typeof document !== 'undefined') {
  applyThemeToDocument(initialTheme, initialIconVariant);
}

const toastTimers = new Map<string, { timer: number; deadline: number }>();
const toastExitTimers = new Map<string, number>();
let revealNonceCounter = 1;

function clearToastTimer(id: string): void {
  const entry = toastTimers.get(id);
  if (entry !== undefined) {
    window.clearTimeout(entry.timer);
    toastTimers.delete(id);
  }
}

export const useCoordinatorStore = create<CoordinatorState>((set, get) => ({
  destination: { type: 'allItems' },
  sidebarCollapsed: readLS<boolean>(STORAGE_KEYS.sidebarCollapsed, false),
  layoutMode: readLS<GalleryLayoutMode>(STORAGE_KEYS.layoutMode, 'verticalMasonry'),
  targetColumnWidth: Math.max(130, Math.min(420, readLS<number>(STORAGE_KEYS.colWidth, 236))),
  inspectorOpen: readLS<boolean>(STORAGE_KEYS.inspectorOpen, true),
  selectedInspectorTab: initialInspectorTab,
  inspectorSectionOrder: initialSectionOrder,

  pendingGalleryReveal: null,
  revealHighlightAssetID: null,
  returnToMoodboardState: null,
  expandedSidebarFolderIDs: [],

  quickLookAssetID: null,
  quickLookSourceRect: null,
  quickLookHiddenAssetID: null,
  jumpAnywhereOpen: false,

  settingsOpen: false,
  settingsTab: 'general',

  hasCompletedOnboarding: readLS<boolean>(STORAGE_KEYS.hasCompletedOnboarding, false),
  onboardingOpen: false,
  onboardingRunID: 0,

  generatorModalOpen: false,
  generatorInitialSeedAssetIDs: [],

  showQuickCapture: false,
  quickCapturePrefill: null,
  captureTarget: readLS<CaptureTarget>(STORAGE_KEYS.captureTarget, { type: 'inbox' }),

  activeBoardID: readLS<UUID | null>(STORAGE_KEYS.activeBoardID, null),

  themeMode: initialTheme,
  brandIconVariant: initialIconVariant,

  toasts: [],

  navigate: (destination) => set({ destination }),

  openBoard: (boardID) => {
    set({
      destination: { type: 'moodboard', id: boardID },
      returnToMoodboardState: null,
    });
  },

  setActiveBoardID: (boardID) => {
    writeLS(STORAGE_KEYS.activeBoardID, boardID);
    set({ activeBoardID: boardID });
  },

  setSidebarCollapsed: (collapsed) => {
    writeLS(STORAGE_KEYS.sidebarCollapsed, collapsed);
    set({ sidebarCollapsed: collapsed });
  },
  toggleSidebar: () => {
    const next = !get().sidebarCollapsed;
    writeLS(STORAGE_KEYS.sidebarCollapsed, next);
    set({ sidebarCollapsed: next });
  },

  setLayoutMode: (mode) => {
    writeLS(STORAGE_KEYS.layoutMode, mode);
    set({ layoutMode: mode });
  },

  setTargetColumnWidth: (width) => {
    const clamped = Math.round(Math.max(130, Math.min(420, width)));
    writeLS(STORAGE_KEYS.colWidth, clamped);
    set({ targetColumnWidth: clamped });
  },

  setInspectorOpen: (open) => {
    writeLS(STORAGE_KEYS.inspectorOpen, open);
    set({ inspectorOpen: open });
  },

  toggleInspector: () => {
    const next = !get().inspectorOpen;
    writeLS(STORAGE_KEYS.inspectorOpen, next);
    set({ inspectorOpen: next });
  },

  setSelectedInspectorTab: (tab) => {
    writeLS(STORAGE_KEYS.selectedInspectorTab, tab);
    set({ selectedInspectorTab: tab });
  },

  setInspectorSectionOrder: (order) => {
    const normalized = normalizeInspectorSectionOrder(order);
    writeLS(STORAGE_KEYS.inspectorSectionOrder, normalized);
    set({ inspectorSectionOrder: normalized });
  },

  resetInspectorSectionOrder: () => {
    const defaults = [...DEFAULT_INSPECTOR_SECTION_ORDER];
    writeLS(STORAGE_KEYS.inspectorSectionOrder, defaults);
    set({ inspectorSectionOrder: defaults });
  },

  requestRevealAssetInGallery: (assetID) => {
    const nonce = ++revealNonceCounter;
    set({
      pendingGalleryReveal: { assetID, nonce },
      revealHighlightAssetID: assetID,
    });
  },

  clearPendingGalleryReveal: (nonce) => {
    set((s) =>
      s.pendingGalleryReveal && s.pendingGalleryReveal.nonce === nonce
        ? { pendingGalleryReveal: null }
        : s,
    );
  },

  setRevealHighlightAssetID: (assetID) => set({ revealHighlightAssetID: assetID }),

  setReturnToMoodboardState: (state) => set({ returnToMoodboardState: state }),

  toggleSidebarFolderExpanded: (id) => {
    set((s) => {
      const exists = s.expandedSidebarFolderIDs.includes(id);
      return {
        expandedSidebarFolderIDs: exists
          ? s.expandedSidebarFolderIDs.filter((item) => item !== id)
          : [...s.expandedSidebarFolderIDs, id],
      };
    });
  },

  setSidebarFolderExpanded: (id, expanded) => {
    set((s) => {
      const exists = s.expandedSidebarFolderIDs.includes(id);
      if (expanded && !exists) {
        return { expandedSidebarFolderIDs: [...s.expandedSidebarFolderIDs, id] };
      }
      if (!expanded && exists) {
        return {
          expandedSidebarFolderIDs: s.expandedSidebarFolderIDs.filter((item) => item !== id),
        };
      }
      return s;
    });
  },

  revealSidebarFolderAncestors: (ids) => {
    if (ids.length === 0) return;
    set((s) => {
      const merged = new Set(s.expandedSidebarFolderIDs);
      for (const id of ids) merged.add(id);
      return { expandedSidebarFolderIDs: Array.from(merged) };
    });
  },

  openQuickLook: (assetID, sourceRect = null) => {
    stopAllHoverPreviews();
    let resolvedRect: SourceRect | null = sourceRect;
    if (typeof document !== 'undefined') {
      const active = document.activeElement as HTMLElement | null;
      if (active && active !== document.body && typeof active.blur === 'function') {
        active.blur();
      }
      if (!resolvedRect) {
        const safeId =
          typeof CSS !== 'undefined' && typeof CSS.escape === 'function'
            ? CSS.escape(assetID)
            : assetID.replace(/"/g, '\\"');
        const el =
          document.querySelector<HTMLElement>(`[data-asset-card-id="${safeId}"]`) ??
          document.querySelector<HTMLElement>(`[data-filmstrip-id="${safeId}"]`);
        if (el) {
          const r = el.getBoundingClientRect();
          if (r.width > 0 && r.height > 0 && r.bottom > 0 && r.top < window.innerHeight) {
            resolvedRect = { left: r.left, top: r.top, width: r.width, height: r.height };
          }
        }
      }
    }
    set({ quickLookAssetID: assetID, quickLookSourceRect: resolvedRect });
  },

  closeQuickLook: () => set({ quickLookAssetID: null, quickLookSourceRect: null }),
  setQuickLookHiddenAssetID: (assetID) => set({ quickLookHiddenAssetID: assetID }),

  setJumpAnywhereOpen: (open) => set({ jumpAnywhereOpen: open }),
  toggleJumpAnywhere: () => set((s) => ({ jumpAnywhereOpen: !s.jumpAnywhereOpen })),

  openSettings: (tab) =>
    set((s) => ({
      settingsOpen: true,
      jumpAnywhereOpen: false,
      settingsTab: tab ?? s.settingsTab,
    })),

  closeSettings: () => set({ settingsOpen: false }),
  setSettingsTab: (tab) => set({ settingsTab: tab }),

  presentOnboardingIfFirstLaunch: () => {
    const s = get();
    if (!s.hasCompletedOnboarding && !s.onboardingOpen) {
      stopAllHoverPreviews();
      set({
        onboardingOpen: true,
        onboardingRunID: s.onboardingRunID + 1,
      });
    }
  },

  presentOnboarding: () => {
    stopAllHoverPreviews();
    set((s) => ({
      onboardingOpen: true,
      settingsOpen: false,
      jumpAnywhereOpen: false,
      onboardingRunID: s.onboardingRunID + 1,
    }));
  },

  completeOnboarding: () => {
    writeLS(STORAGE_KEYS.hasCompletedOnboarding, true);
    set({
      hasCompletedOnboarding: true,
      onboardingOpen: false,
    });
  },

  openGeneratorModal: (seedAssetIDs = []) =>
    set({ generatorModalOpen: true, generatorInitialSeedAssetIDs: seedAssetIDs }),

  closeGeneratorModal: () =>
    set({ generatorModalOpen: false, generatorInitialSeedAssetIDs: [] }),

  openQuickCapture: (prefill = null) => {
    stopAllHoverPreviews();
    set({ showQuickCapture: true, quickCapturePrefill: prefill });
  },

  closeQuickCapture: () =>
    set({ showQuickCapture: false, quickCapturePrefill: null }),

  setCaptureTarget: (target) => {
    writeLS(STORAGE_KEYS.captureTarget, target);
    set({ captureTarget: target });
  },

  setThemeMode: (mode) => {
    writeLS(STORAGE_KEYS.theme, mode);
    applyThemeToDocument(mode, get().brandIconVariant);
    set({ themeMode: mode });
  },

  setBrandIconVariant: (variant) => {
    writeLS(STORAGE_KEYS.iconVariant, variant);
    applyThemeToDocument(get().themeMode, variant);
    set({ brandIconVariant: variant });
  },

  isOverlayPresented: () => {
    const s = get();
    return Boolean(
      s.quickLookAssetID ||
        s.jumpAnywhereOpen ||
        s.settingsOpen ||
        s.onboardingOpen ||
        s.generatorModalOpen ||
        s.showQuickCapture,
    );
  },

  pushToast: (toast) => {
    const id = `toast-${Date.now()}-${Math.random().toString(36).slice(2, 7)}`;
    const hasAction = Boolean(toast.actionLabel && toast.onAction);
    const duration = toast.durationMs ?? (hasAction ? 5200 : 3200);
    const item: ToastItem = {
      ...toast,
      id,
      durationMs: duration,
      remainingMs: duration,
      paused: false,
      exiting: false,
    };

    set((s) => {
      const kept = s.toasts.slice(-3);
      return { toasts: [...kept, item] };
    });

    if (typeof window !== 'undefined' && duration > 0) {
      const deadline = Date.now() + duration;
      const timer = window.setTimeout(() => {
        toastTimers.delete(id);
        get().dismissToast(id);
      }, duration);
      toastTimers.set(id, { timer, deadline });
    }
    return id;
  },

  pauseToast: (id) => {
    if (typeof window === 'undefined') return;
    const entry = toastTimers.get(id);
    if (!entry) return;
    const remaining = Math.max(80, entry.deadline - Date.now());
    clearToastTimer(id);
    set((s) => ({
      toasts: s.toasts.map((t) =>
        t.id === id && !t.exiting ? { ...t, paused: true, remainingMs: remaining } : t,
      ),
    }));
  },

  resumeToast: (id) => {
    if (typeof window === 'undefined') return;
    const current = get().toasts.find((t) => t.id === id);
    if (!current || current.exiting || !current.paused) return;
    const remaining = Math.max(80, current.remainingMs ?? current.durationMs ?? 3200);
    clearToastTimer(id);
    set((s) => ({
      toasts: s.toasts.map((t) => (t.id === id ? { ...t, paused: false } : t)),
    }));
    const deadline = Date.now() + remaining;
    const timer = window.setTimeout(() => {
      toastTimers.delete(id);
      get().dismissToast(id);
    }, remaining);
    toastTimers.set(id, { timer, deadline });
  },

  triggerToastAction: (id) => {
    const target = get().toasts.find((t) => t.id === id);
    if (!target) return;
    const action = target.onAction;
    get().dismissToast(id);
    action?.();
  },

  dismissToast: (id) => {
    clearToastTimer(id);
    const target = get().toasts.find((t) => t.id === id);
    if (!target || target.exiting) return;

    set((s) => ({
      toasts: s.toasts.map((t) => (t.id === id ? { ...t, exiting: true, paused: true } : t)),
    }));

    if (typeof window === 'undefined') {
      set((s) => ({ toasts: s.toasts.filter((t) => t.id !== id) }));
      return;
    }

    const existingExit = toastExitTimers.get(id);
    if (existingExit !== undefined) {
      window.clearTimeout(existingExit);
    }
    const exitTimer = window.setTimeout(() => {
      toastExitTimers.delete(id);
      set((s) => ({ toasts: s.toasts.filter((t) => t.id !== id) }));
    }, 135);
    toastExitTimers.set(id, exitTimer);
  },
}));
