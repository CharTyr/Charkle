//! Deterministic pane resize clamping geometry matching macOS `SidebarResizeGeometry`
//! (`Sources/CharkleCanvas/CanvasSupport.swift`) 1:1.

export const COLLAPSED_SIDEBAR_WIDTH = 76;
export const DEFAULT_SIDEBAR_WIDTH = 232;
export const MIN_SIDEBAR_WIDTH = 188;
export const MAX_SIDEBAR_WIDTH = 420;
export const COLLAPSED_SIDEBAR_DRAG_EXPAND_THRESHOLD = 40;

export const DEFAULT_INSPECTOR_WIDTH = 300;
export const MIN_INSPECTOR_WIDTH = 260;
export const MAX_INSPECTOR_WIDTH = 480;

export const MIN_CENTER_WORKSPACE_WIDTH = 360;

export const SIDEBAR_WIDTH_STORAGE_KEY = 'charkle.win.sidebarWidth';
export const INSPECTOR_WIDTH_STORAGE_KEY = 'charkle.win.inspectorWidth';

export function clampSidebarWidth(
  raw: number,
  windowWidth?: number | null,
  inspectorVisible = false,
  inspectorWidth = DEFAULT_INSPECTOR_WIDTH,
): number {
  const safeRaw = Number.isFinite(raw) ? raw : DEFAULT_SIDEBAR_WIDTH;
  let effectiveMax = MAX_SIDEBAR_WIDTH;
  if (windowWidth != null && Number.isFinite(windowWidth) && windowWidth > 0) {
    const safeInspector = inspectorVisible && Number.isFinite(inspectorWidth)
      ? Math.max(0, inspectorWidth)
      : 0;
    const available = windowWidth - MIN_CENTER_WORKSPACE_WIDTH - safeInspector;
    effectiveMax = Math.max(MIN_SIDEBAR_WIDTH, Math.min(MAX_SIDEBAR_WIDTH, available));
  }
  return Math.round(Math.min(effectiveMax, Math.max(MIN_SIDEBAR_WIDTH, safeRaw)));
}

export function clampInspectorWidth(
  raw: number,
  windowWidth?: number | null,
  sidebarOccupiedWidth = 0,
): number {
  const safeRaw = Number.isFinite(raw) ? raw : DEFAULT_INSPECTOR_WIDTH;
  let effectiveMax = MAX_INSPECTOR_WIDTH;
  if (windowWidth != null && Number.isFinite(windowWidth) && windowWidth > 0) {
    const safeSidebar = Number.isFinite(sidebarOccupiedWidth)
      ? Math.max(0, sidebarOccupiedWidth)
      : 0;
    const available = windowWidth - MIN_CENTER_WORKSPACE_WIDTH - safeSidebar;
    effectiveMax = Math.max(MIN_INSPECTOR_WIDTH, Math.min(MAX_INSPECTOR_WIDTH, available));
  }
  return Math.round(Math.min(effectiveMax, Math.max(MIN_INSPECTOR_WIDTH, safeRaw)));
}

export interface PaneWidthResolutionInput {
  windowWidth: number;
  sidebarOpen: boolean;
  sidebarCollapsed: boolean;
  sidebarWidth: number;
  inspectorOpen: boolean;
  inspectorWidth: number;
  priority?: 'sidebar' | 'inspector' | null;
}

export interface PaneWidthResolution {
  sidebarEffectiveWidth: number;
  inspectorEffectiveWidth: number;
}

/**
 * Mutually clamps Left Sidebar and Right Inspector widths so the center gallery / canvas
 * workspace always retains at least `MIN_CENTER_WORKSPACE_WIDTH` (`360px`) whenever possible.
 */
export function resolveEffectivePaneWidths(input: PaneWidthResolutionInput): PaneWidthResolution {
  const {
    windowWidth,
    sidebarOpen,
    sidebarCollapsed,
    sidebarWidth,
    inspectorOpen,
    inspectorWidth,
    priority = null,
  } = input;

  if (!sidebarOpen) {
    return {
      sidebarEffectiveWidth: 0,
      inspectorEffectiveWidth: inspectorOpen
        ? clampInspectorWidth(inspectorWidth, windowWidth, 0)
        : 0,
    };
  }

  if (sidebarCollapsed) {
    return {
      sidebarEffectiveWidth: COLLAPSED_SIDEBAR_WIDTH,
      inspectorEffectiveWidth: inspectorOpen
        ? clampInspectorWidth(inspectorWidth, windowWidth, COLLAPSED_SIDEBAR_WIDTH)
        : 0,
    };
  }

  if (!inspectorOpen) {
    return {
      sidebarEffectiveWidth: clampSidebarWidth(sidebarWidth, windowWidth, false, 0),
      inspectorEffectiveWidth: 0,
    };
  }

  if (priority === 'inspector') {
    const insp = clampInspectorWidth(inspectorWidth, windowWidth, MIN_SIDEBAR_WIDTH);
    const side = clampSidebarWidth(sidebarWidth, windowWidth, true, insp);
    return {
      sidebarEffectiveWidth: side,
      inspectorEffectiveWidth: clampInspectorWidth(insp, windowWidth, side),
    };
  }

  const sideFirst = clampSidebarWidth(sidebarWidth, windowWidth, true, MIN_INSPECTOR_WIDTH);
  const insp = clampInspectorWidth(inspectorWidth, windowWidth, sideFirst);
  const side = clampSidebarWidth(sideFirst, windowWidth, true, insp);
  return {
    sidebarEffectiveWidth: side,
    inspectorEffectiveWidth: insp,
  };
}
