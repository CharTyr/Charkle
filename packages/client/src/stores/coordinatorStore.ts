import { create } from 'zustand';
import type { GalleryLayoutMode, SidebarDestination, UUID } from '@charkle/shared';
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

export interface ToastItem {
  id: string;
  message: string;
  tone?: 'info' | 'success' | 'error';
  actionLabel?: string;
  onAction?: () => void;
  durationMs?: number;
}

const STORAGE_KEYS = {
  theme: 'charkle.themeMode',
  iconVariant: 'charkle.brandIconVariant',
  layoutMode: 'charkle.layoutMode',
  colWidth: 'charkle.targetColumnWidth',
  sidebarCollapsed: 'charkle.sidebarCollapsed',
  inspectorOpen: 'charkle.inspectorOpen',
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

  quickLookAssetID: UUID | null;
  quickLookSourceRect: SourceRect | null;
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

  openQuickLook: (assetID: UUID, sourceRect?: SourceRect | null) => void;
  closeQuickLook: () => void;

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

  pushToast: (toast: Omit<ToastItem, 'id'>) => string;
  dismissToast: (id: string) => void;
}

const initialTheme = readLS<ThemeMode>(STORAGE_KEYS.theme, 'system');
const initialIconVariant = readLS<'auto' | 'light' | 'dark'>(STORAGE_KEYS.iconVariant, 'auto');

if (typeof document !== 'undefined') {
  applyThemeToDocument(initialTheme, initialIconVariant);
}

const toastTimers = new Map<string, number>();

export const useCoordinatorStore = create<CoordinatorState>((set, get) => ({
  destination: { type: 'allItems' },
  sidebarCollapsed: readLS<boolean>(STORAGE_KEYS.sidebarCollapsed, false),
  layoutMode: readLS<GalleryLayoutMode>(STORAGE_KEYS.layoutMode, 'verticalMasonry'),
  targetColumnWidth: Math.max(130, Math.min(420, readLS<number>(STORAGE_KEYS.colWidth, 236))),
  inspectorOpen: readLS<boolean>(STORAGE_KEYS.inspectorOpen, true),

  quickLookAssetID: null,
  quickLookSourceRect: null,
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
    set({ destination: { type: 'moodboard', id: boardID } });
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

  openQuickLook: (assetID, sourceRect = null) => {
    stopAllHoverPreviews();
    set({ quickLookAssetID: assetID, quickLookSourceRect: sourceRect });
  },

  closeQuickLook: () => set({ quickLookAssetID: null, quickLookSourceRect: null }),

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

  pushToast: (toast) => {
    const id = `toast-${Date.now()}-${Math.random().toString(36).slice(2, 7)}`;
    const duration = toast.durationMs ?? (toast.actionLabel ? 5200 : 3200);
    set((s) => ({
      toasts: [...s.toasts.slice(-3), { ...toast, id }],
    }));
    if (typeof window !== 'undefined' && duration > 0) {
      const timer = window.setTimeout(() => {
        toastTimers.delete(id);
        get().dismissToast(id);
      }, duration);
      toastTimers.set(id, timer);
    }
    return id;
  },

  dismissToast: (id) => {
    const timer = toastTimers.get(id);
    if (timer !== undefined) {
      window.clearTimeout(timer);
      toastTimers.delete(id);
    }
    set((s) => ({ toasts: s.toasts.filter((t) => t.id !== id) }));
  },
}));
