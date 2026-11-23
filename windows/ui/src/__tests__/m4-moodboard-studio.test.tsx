import { fireEvent, render, screen, waitFor } from '@testing-library/react';
import { beforeEach, describe, expect, it } from 'vitest';
import { App } from '../App';
import { InMemoryMockTransport, setTransport } from '../api/transport';
import {
  freezeIntoFreeform,
  reflowNodesInsideGroupFrame,
  solveEditorialLayout,
} from '../features/moodboard/editorial';
import {
  useCoordinatorStore,
  useLibraryStore,
  useMoodboardStore,
  useSyncAIStore,
} from '../stores';
import {
  createDefaultFilterCriteria,
  type AssetRecord,
  type BoardNode,
  type MoodboardDocument,
} from '../types/domain';

function resetStores() {
  useCoordinatorStore.setState({
    themeMode: 'light',
    surfaceState: null,
    sidebarOpen: true,
    inspectorOpen: true,
    layoutMode: 'verticalMasonry',
    cardScale: 236,
    destination: { type: 'moodboardsHome' },
    selectedAssetIds: [],
    lastSelectedAssetId: null,
    quickLookAssetId: null,
    quickLookOriginRect: null,
    jumpOpen: false,
    captureOpen: false,
    activeMoodboardId: null,
    toasts: [],
  });
  useLibraryStore.setState({
    assets: [],
    folders: [],
    smartFolders: [],
    tagCounts: [],
    inboxCount: 0,
    criteria: createDefaultFilterCriteria(),
    semanticSearch: false,
    loading: false,
    bootstrapped: false,
    error: null,
  });
  useMoodboardStore.setState({
    boards: [],
    activeBoard: null,
    loading: false,
    curating: false,
    agentTrace: [],
    candidatePool: [],
    selectedNodeIds: [],
    historyPast: [],
    historyFuture: [],
  });
  useSyncAIStore.setState({
    syncConfig: null,
    syncStatus: null,
    cacheStats: null,
    syncing: false,
  });
}

describe('Charkle Windows M4 EditorialLayoutSolver Parity, Studio Canvas & Figma Bridge', () => {
  let mock: InMemoryMockTransport;

  beforeEach(() => {
    localStorage.clear();
    mock = new InMemoryMockTransport(true);
    setTransport(mock);
    resetStores();
  });

  it('matches macOS EditorialLayoutSolver across magazine/balanced/compact, zero-jump freeze, and GroupFrame smart reflow', () => {
    const assetsById = new Map<string, AssetRecord>();
    const nodes: BoardNode[] = [];

    for (let i = 0; i < 6; i += 1) {
      const aid = `30000000-0000-4000-8000-00000000000${i + 1}`;
      assetsById.set(aid, {
        id: aid,
        contentHash: `hash-${i}`,
        title: `Ref ${i + 1}`,
        fileName: `ref_${i + 1}.jpg`,
        mediaKind: 'image',
        mimeType: 'image/jpeg',
        notes: '',
        pixelWidth: i % 2 === 0 ? 1600 : 1000,
        pixelHeight: i % 2 === 0 ? 1000 : 1400,
        fileSizeBytes: 120000,
        dominantColors: [],
        waveformPeaks: [],
        tags: [],
        suggestedTags: [],
        rating: 0,
        pinnedOffline: false,
        isLocalOriginalCached: true,
        isTrashed: false,
        createdAt: 0,
        updatedAt: 0,
        updatedHLC: 1,
      });
      nodes.push({
        id: `40000000-0000-4000-8000-00000000000${i + 1}`,
        kind: {
          assetRef: {
            assetID: aid,
            crop: null,
            weight: i < 4 ? 2 : 1,
            autoplayLoop: true,
          },
        },
        frame: { x: 0, y: 0, width: 240, height: 240 },
        zIndex: i,
        rotationDegrees: 0,
        flipHorizontal: false,
        flipVertical: false,
        isLocked: false,
        editorialOrder: i,
        updatedAt: 0,
      });
    }

    // Magazine at 1120px => 3 columns, max 3 2-column Hero spans
    const mag = solveEditorialLayout(
      nodes,
      { columns: 4, spacing: 16, style: 'magazine', showPaletteStrip: true },
      1120,
      assetsById,
    );
    expect(mag.columnCount).toBe(3);
    const colWidth = (1120 - 2 * 24 - 2 * 16) / 3;
    const heroNodes = Object.values(mag.frames).filter((r) => r.width > colWidth * 1.5);
    expect(heroNodes.length).toBe(3);

    // Balanced (4 cols) & Compact (7 cols) at 1120px
    expect(
      solveEditorialLayout(
        nodes,
        { columns: 4, spacing: 16, style: 'balanced', showPaletteStrip: true },
        1120,
        assetsById,
      ).columnCount,
    ).toBe(4);
    expect(
      solveEditorialLayout(
        nodes,
        { columns: 4, spacing: 16, style: 'compact', showPaletteStrip: true },
        1120,
        assetsById,
      ).columnCount,
    ).toBe(7);

    // Zero-jump freezeIntoFreeform preserves exact solved frames
    const doc: MoodboardDocument = {
      id: '50000000-0000-4000-8000-000000000001',
      title: 'Zero Jump Test',
      subtitle: '',
      mode: {
        autoEditorial: {
          _0: { columns: 4, spacing: 16, style: 'magazine', showPaletteStrip: true },
        },
      },
      nodes,
      connectors: [],
      inkStrokes: [],
      extractedPalette: [],
      candidateAssetIDs: [],
      pinnedOffline: false,
      viewportCenter: { x: 0, y: 0 },
      viewportZoom: 1,
      createdAt: 0,
      updatedAt: 0,
      updatedHLC: 1,
    };
    const frozen = freezeIntoFreeform(doc, 1120, assetsById);
    expect('freeform' in frozen.mode).toBe(true);
    for (const n of frozen.nodes) {
      expect(n.frame).toEqual(mag.frames[n.id]);
    }

    // GroupFrame smart reflow keeps all child nodes inside the group bounds
    const groupRect = { x: 100, y: 120, width: 520, height: 420 };
    const reflowed = reflowNodesInsideGroupFrame(groupRect, nodes.slice(0, 4), assetsById);
    expect(Object.keys(reflowed)).toHaveLength(4);
    for (const r of Object.values(reflowed)) {
      expect(r.x).toBeGreaterThanOrEqual(groupRect.x);
      expect(r.y).toBeGreaterThanOrEqual(groupRect.y + 38);
      expect(r.x + r.width).toBeLessThanOrEqual(groupRect.x + groupRect.width + 0.5);
    }
  });

  it('generates a curated moodboard via 4+1 Generator Modal, displays Candidate Pool swap, Dual-Mode switch, 5 element tools, Undo/Redo, and Export Popover', async () => {
    render(<App />);

    // Wait for Moodboards Home to appear
    await waitFor(() => {
      expect(screen.getByTestId('moodboards-home')).toBeInTheDocument();
    });

    // Open 4+1 Generator Modal
    fireEvent.click(screen.getByRole('button', { name: /4\+1 智能生成/ }));
    await waitFor(() => {
      expect(screen.getByTestId('moodboard-generator-modal')).toBeInTheDocument();
    });

    // Fill prompt and trigger curation
    const promptInput = screen.getByPlaceholderText(/暖石膏建筑/);
    fireEvent.change(promptInput, { target: { value: '暖调建筑海报与极简材质' } });
    fireEvent.click(screen.getByRole('button', { name: /立即生成情绪板/ }));

    // Opens Moodboard Studio with Candidate Replacement Pool
    await waitFor(() => {
      expect(screen.getByTestId('moodboard-studio-view')).toBeInTheDocument();
      expect(screen.getByTestId('candidate-pool-panel')).toBeInTheDocument();
    });

    // Agent trace streamed during curation
    expect(useMoodboardStore.getState().agentTrace.length).toBeGreaterThanOrEqual(5);

    const initialBoard = useMoodboardStore.getState().activeBoard!;
    expect(initialBoard.nodes.length).toBeGreaterThan(0);

    // Select first assetRef node -> 1-click in-place replacement from Candidate Pool
    const firstAssetNode = initialBoard.nodes.find((n) => 'assetRef' in n.kind)!;
    const origAssetId =
      'assetRef' in firstAssetNode.kind ? firstAssetNode.kind.assetRef.assetID : '';
    const origFrame = { ...firstAssetNode.frame };

    const nodeEl = document.querySelector(`[data-board-node-id="${firstAssetNode.id}"]`)!;
    fireEvent.mouseDown(nodeEl, { button: 0 });

    const swapButtons = await screen.findAllByRole('button', { name: '替换' });
    fireEvent.click(swapButtons[0]);

    await waitFor(() => {
      const updated = useMoodboardStore
        .getState()
        .activeBoard?.nodes.find((n) => n.id === firstAssetNode.id);
      expect(updated && 'assetRef' in updated.kind ? updated.kind.assetRef.assetID : '').not.toBe(
        origAssetId,
      );
      expect(updated?.frame).toEqual(origFrame);
    });

    // Add Note, GroupFrame, and PaletteStrip elements via Bottom Tools Dock
    const countBeforeTools = useMoodboardStore.getState().activeBoard!.nodes.length;
    fireEvent.click(screen.getByRole('button', { name: '添加便签' }));
    fireEvent.click(screen.getByRole('button', { name: '添加分组框' }));
    fireEvent.click(screen.getByRole('button', { name: '添加色卡条' }));

    await waitFor(() => {
      const nodes = useMoodboardStore.getState().activeBoard!.nodes;
      expect(nodes.length).toBe(countBeforeTools + 3);
      expect(nodes.some((n) => 'note' in n.kind)).toBe(true);
      expect(nodes.some((n) => 'groupFrame' in n.kind)).toBe(true);
      expect(nodes.some((n) => 'paletteStrip' in n.kind)).toBe(true);
    });

    // Undo (Ctrl+Z) & Redo (Ctrl+Y)
    fireEvent.keyDown(window, { key: 'z', ctrlKey: true });
    expect(useMoodboardStore.getState().activeBoard!.nodes.length).toBe(countBeforeTools + 2);
    fireEvent.keyDown(window, { key: 'y', ctrlKey: true });
    expect(useMoodboardStore.getState().activeBoard!.nodes.length).toBe(countBeforeTools + 3);

    // Zero-jump switch from Auto Editorial -> Freeform Infinite Canvas
    fireEvent.click(screen.getByRole('radio', { name: '自由画布' }));
    await waitFor(() => {
      expect(screen.getByTestId('moodboard-canvas-stage')).toHaveAttribute(
        'data-board-mode',
        'freeform',
      );
    });

    // Add Connector between two nodes & draw InkStroke
    fireEvent.click(screen.getByRole('button', { name: '连线工具' }));
    const allNodes = useMoodboardStore.getState().activeBoard!.nodes;
    const nodeA = document.querySelector(`[data-board-node-id="${allNodes[0].id}"]`)!;
    const nodeB = document.querySelector(`[data-board-node-id="${allNodes[1].id}"]`)!;
    fireEvent.mouseDown(nodeA, { button: 0, clientX: 60, clientY: 60 });
    fireEvent.mouseDown(nodeB, { button: 0, clientX: 200, clientY: 120 });
    expect(useMoodboardStore.getState().activeBoard!.connectors.length).toBeGreaterThanOrEqual(1);

    fireEvent.click(screen.getByRole('button', { name: '画笔工具' }));
    const stage = screen.getByTestId('moodboard-canvas-stage');
    fireEvent.mouseDown(stage, { button: 0, clientX: 50, clientY: 50 });
    fireEvent.mouseMove(window, { clientX: 140, clientY: 110 });
    fireEvent.mouseUp(window);
    expect(useMoodboardStore.getState().activeBoard!.inkStrokes.length).toBeGreaterThanOrEqual(1);

    // Open Export Popover -> test Clipboard copy + .charkleboard Figma Bridge export
    fireEvent.click(screen.getByRole('button', { name: '导出' }));
    await waitFor(() => {
      expect(screen.getByTestId('moodboard-export-popover')).toBeInTheDocument();
    });

    fireEvent.click(screen.getByRole('button', { name: /复制高清图到剪贴板/ }));
    await waitFor(() => {
      expect(screen.getByText(/已复制高清情绪板到剪贴板/)).toBeInTheDocument();
    });

    fireEvent.click(screen.getByRole('button', { name: '导出' }));
    await waitFor(() => {
      expect(screen.getByTestId('moodboard-export-popover')).toBeInTheDocument();
    });
    fireEvent.click(screen.getByRole('button', { name: /导出 \.charkleboard/ }));
    await waitFor(() => {
      expect(screen.getByText(/已导出 \.charkleboard/)).toBeInTheDocument();
    });
  });
});
