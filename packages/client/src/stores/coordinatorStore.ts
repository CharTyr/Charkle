import { create } from 'zustand';
import type { GalleryLayoutMode, SidebarDestination, UUID } from '@charkle/shared';
import { applyThemeToDocument } from '../design-system/theme';
import type { ThemeMode } from '../design-system/theme';

export type SettingsTabID =
  | 'accountSecurity'
  | 'cloudSync'
  | 'intelligence'
  | 'appearance'
  | 'externalAgent'
  | 'storage'
  | 'captureShortcuts';

export type QuickDropTarget =
  | { type: 'inbox' }
  | { type: 'folder'; folderID: UUID }
  | { type: 'activeMoodboard' };

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
  inspectorOpen: 'charkle.inspectorOpen',
  shelfEnabled: 'charkle.quickDropShelfEnabled',
  activeBoardID: 'charkle.activeBoardID',
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

  generatorModalOpen: boolean;
  generatorInitialSeedAssetIDs: UUID[];

  quickDropShelfEnabled: boolean;
  quickDropShelfOpen: boolean;
  quickDropShelfExpanded: boolean;
  quickDropShelfPinned: boolean;
  quickDropTarget: QuickDropTarget;

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

  openGeneratorModal: (seedAssetIDs?: UUID[]) => void;
  closeGeneratorModal: () => void;

  setQuickDropShelfEnabled: (enabled: boolean) => void;
  setQuickDropShelfOpen: (open: boolean) => void;
  setQuickDropShelfExpanded: (expanded: boolean) => void;
  setQuickDropShelfPinned: (pinned: boolean) => void;
  setQuickDropTarget: (target: QuickDropTarget) => void;

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
  sidebarCollapsed: false,
  layoutMode: readLS<GalleryLayoutMode>(STORAGE_KEYS.layoutMode, 'verticalMasonry'),
  targetColumnWidth: Math.max(130, Math.min(420, readLS<number>(STORAGE_KEYS.colWidth, 236))),
  inspectorOpen: readLS<boolean>(STORAGE_KEYS.inspectorOpen, true),

  quickLookAssetID: null,
  quickLookSourceRect: null,
  jumpAnywhereOpen: false,

  settingsOpen: false,
  settingsTab: 'accountSecurity',

  generatorModalOpen: false,
  generatorInitialSeedAssetIDs: [],

  quickDropShelfEnabled: readLS<boolean>(STORAGE_KEYS.shelfEnabled, true),
  quickDropShelfOpen: false,
  quickDropShelfExpanded: false,
  quickDropShelfPinned: false,
  quickDropTarget: { type: 'inbox' },

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

  setSidebarCollapsed: (collapsed) => set({ sidebarCollapsed: collapsed }),
  toggleSidebar: () => set((s) => ({ sidebarCollapsed: !s.sidebarCollapsed })),

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

  openQuickLook: (assetID, sourceRect = null) =>
    set({ quickLookAssetID: assetID, quickLookSourceRect: sourceRect }),

  closeQuickLook: () => set({ quickLookAssetID: null, quickLookSourceRect: null }),

  setJumpAnywhereOpen: (open) => set({ jumpAnywhereOpen: open }),
  toggleJumpAnywhere: () => set((s) => ({ jumpAnywhereOpen: !s.jumpAnywhereOpen })),

  openSettings: (tab) =>
    set((s) => ({
      settingsOpen: true,
      settingsTab: tab ?? s.settingsTab,
    })),

  closeSettings: () => set({ settingsOpen: false }),
  setSettingsTab: (tab) => set({ settingsTab: tab }),

  openGeneratorModal: (seedAssetIDs = []) =>
    set({ generatorModalOpen: true, generatorInitialSeedAssetIDs: seedAssetIDs }),

  closeGeneratorModal: () =>
    set({ generatorModalOpen: false, generatorInitialSeedAssetIDs: [] }),

  setQuickDropShelfEnabled: (enabled) => {
    writeLS(STORAGE_KEYS.shelfEnabled, enabled);
    set({ quickDropShelfEnabled: enabled, quickDropShelfOpen: enabled ? get().quickDropShelfOpen : false });
  },

  setQuickDropShelfOpen: (open) => set({ quickDropShelfOpen: open }),
  setQuickDropShelfExpanded: (expanded) => set({ quickDropShelfExpanded: expanded }),
  setQuickDropShelfPinned: (pinned) => set({ quickDropShelfPinned: pinned }),
  setQuickDropTarget: (target) => set({ quickDropTarget: target }),

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
