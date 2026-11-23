import { create } from 'zustand';
import { getTransport } from '../api/transport';
import { applyThemeToDocument, type ThemeMode } from '../design-system/theme';
import type {
  GalleryLayoutMode,
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

const THEME_STORAGE_KEY = 'charkle.win.theme';
const LAYOUT_STORAGE_KEY = 'charkle.win.layout';
const SCALE_STORAGE_KEY = 'charkle.win.cardScale';

function readStoredTheme(): ThemeMode {
  if (typeof localStorage === 'undefined') return 'system';
  const raw = localStorage.getItem(THEME_STORAGE_KEY);
  if (raw === 'light' || raw === 'dark' || raw === 'system') return raw;
  return 'system';
}

function readStoredLayout(): GalleryLayoutMode {
  if (typeof localStorage === 'undefined') return 'verticalMasonry';
  const raw = localStorage.getItem(LAYOUT_STORAGE_KEY);
  if (raw === 'verticalMasonry' || raw === 'horizontalJustified' || raw === 'galleryFilmstrip') {
    return raw;
  }
  return 'verticalMasonry';
}

function readStoredScale(): number {
  if (typeof localStorage === 'undefined') return 236;
  const raw = Number(localStorage.getItem(SCALE_STORAGE_KEY));
  if (Number.isFinite(raw) && raw >= 160 && raw <= 360) return raw;
  return 236;
}

export interface CoordinatorState {
  themeMode: ThemeMode;
  surfaceState: WindowSurfaceState | null;
  sidebarOpen: boolean;
  inspectorOpen: boolean;
  layoutMode: GalleryLayoutMode;
  cardScale: number;
  destination: SidebarDestination;
  selectedAssetIds: string[];
  lastSelectedAssetId: string | null;
  quickLookAssetId: string | null;
  quickLookOriginRect: QuickLookOriginRect | null;
  jumpOpen: boolean;
  captureOpen: boolean;
  activeMoodboardId: string | null;
  toasts: ToastItem[];

  setThemeMode: (mode: ThemeMode) => Promise<void>;
  syncWindowChrome: () => Promise<void>;
  setSidebarOpen: (open: boolean) => void;
  toggleSidebar: () => void;
  setInspectorOpen: (open: boolean) => void;
  toggleInspector: () => void;
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
  setJumpOpen: (open: boolean) => void;
  setCaptureOpen: (open: boolean) => void;
  setActiveMoodboardId: (id: string | null) => void;
  pushToast: (toast: Omit<ToastItem, 'id'>) => string;
  dismissToast: (id: string) => void;
}

let toastSeq = 0;

export const useCoordinatorStore = create<CoordinatorState>((set, get) => ({
  themeMode: readStoredTheme(),
  surfaceState: null,
  sidebarOpen: true,
  inspectorOpen: true,
  layoutMode: readStoredLayout(),
  cardScale: readStoredScale(),
  destination: { type: 'allItems' },
  selectedAssetIds: [],
  lastSelectedAssetId: null,
  quickLookAssetId: null,
  quickLookOriginRect: null,
  jumpOpen: false,
  captureOpen: false,
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

  setInspectorOpen(open) {
    set({ inspectorOpen: open });
  },

  toggleInspector() {
    set((s) => ({ inspectorOpen: !s.inspectorOpen }));
  },

  setLayoutMode(mode) {
    set({ layoutMode: mode });
    if (typeof localStorage !== 'undefined') {
      localStorage.setItem(LAYOUT_STORAGE_KEY, mode);
    }
  },

  setCardScale(scale) {
    const clamped = Math.max(160, Math.min(360, Math.round(scale)));
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
    set({
      quickLookAssetId: id,
      quickLookOriginRect: originRect,
    });
  },

  closeQuickLook() {
    set({ quickLookAssetId: null, quickLookOriginRect: null });
  },

  setJumpOpen(open) {
    set({ jumpOpen: open });
  },

  setCaptureOpen(open) {
    set({ captureOpen: open });
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
