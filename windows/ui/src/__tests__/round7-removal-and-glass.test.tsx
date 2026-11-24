import { act, fireEvent, render, screen, waitFor, within } from '@testing-library/react';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { App } from '../App';
import { InMemoryMockTransport, setTransport } from '../api/transport';
import { ToastHost } from '../design-system';
import { GalleryFilmstripView } from '../features/gallery/GalleryFilmstripView';
import { GalleryRingView } from '../features/gallery/GalleryRingView';
import { HorizontalJustifiedView } from '../features/gallery/HorizontalJustifiedView';
import { TopFilterCapsule } from '../features/gallery/TopFilterCapsule';
import { VerticalMasonryView } from '../features/gallery/VerticalMasonryView';
import { JumpAnywhereModal } from '../features/jump/JumpAnywhereModal';
import { MoodboardStudioView } from '../features/moodboard/MoodboardStudioView';
import {
  DEFAULT_INSPECTOR_CARD_ORDER,
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
  type MoodboardSummary,
} from '../types/domain';

async function loadTokensCss(): Promise<string> {
  const fsSpec = 'node:fs';
  const pathSpec = 'node:path';
  const fs = (await import(/* @vite-ignore */ fsSpec)) as {
    readFileSync: (filePath: string, encoding: 'utf8') => string;
  };
  const path = (await import(/* @vite-ignore */ pathSpec)) as {
    resolve: (...segments: string[]) => string;
  };
  const cwd = (globalThis as { process?: { cwd: () => string } }).process?.cwd() ?? '.';
  return fs.readFileSync(path.resolve(cwd, 'src/design-system/tokens.css'), 'utf8');
}

function realPointerClick(el: HTMLElement) {
  fireEvent.mouseDown(el, { button: 0, bubbles: true });
  fireEvent.mouseUp(el, { button: 0, bubbles: true });
  fireEvent.click(el, { button: 0, bubbles: true });
}

function makeAsset(id: string, title: string, overrides: Partial<AssetRecord> = {}): AssetRecord {
  return {
    id,
    contentHash: `hash-${id}`,
    title,
    notes: '',
    mediaKind: 'image',
    mimeType: 'image/png',
    fileName: `${id}.png`,
    fileSizeBytes: 4096,
    pixelWidth: 1200,
    pixelHeight: 900,
    rating: 0,
    tags: [],
    suggestedTags: [],
    dominantColors: [
      { hex: '#D95D48', l: 55, a: 45, b: 30, proportion: 0.6 },
      { hex: '#3D5A80', l: 38, a: -4, b: -24, proportion: 0.4 },
    ],
    waveformPeaks: [],
    folderID: null,
    isTrashed: false,
    pinnedOffline: false,
    isLocalOriginalCached: true,
    createdAt: 760000000,
    updatedAt: 760000000,
    updatedHLC: 1,
    ...overrides,
  };
}

function makeAssetNode(
  id: string,
  assetID: string,
  index: number,
  overrides: Partial<BoardNode> = {},
): BoardNode {
  return {
    id,
    kind: {
      assetRef: {
        assetID,
        crop: null,
        weight: 1,
        autoplayLoop: false,
      },
    },
    frame: { x: 80 + index * 260, y: 80, width: 220, height: 180 },
    zIndex: index + 1,
    rotationDegrees: 0,
    flipHorizontal: false,
    flipVertical: false,
    isLocked: false,
    editorialOrder: index,
    updatedAt: 760000000,
    ...overrides,
  };
}

function makeBoardDoc(id: string, nodes: BoardNode[]): MoodboardDocument {
  return {
    id,
    title: 'Round 7 Test Board',
    subtitle: 'Editorial regression',
    mode: { freeform: {} },
    nodes,
    connectors: [],
    inkStrokes: [],
    extractedPalette: [
      { hex: '#D95D48', l: 55, a: 45, b: 30, proportion: 0.6 },
      { hex: '#3D5A80', l: 38, a: -4, b: -24, proportion: 0.4 },
    ],
    candidateAssetIDs: [],
    pinnedOffline: false,
    viewportCenter: { x: 420, y: 260 },
    viewportZoom: 1,
    createdAt: 760000000,
    updatedAt: 760000000,
    updatedHLC: Date.now(),
  };
}

function makeBoardSummary(doc: MoodboardDocument): MoodboardSummary {
  return {
    id: doc.id,
    title: doc.title,
    subtitle: doc.subtitle,
    mode: doc.mode,
    itemCount: doc.nodes.length,
    previewAssetIDs: doc.nodes
      .map((n) => ('assetRef' in n.kind ? n.kind.assetRef.assetID : null))
      .filter((x): x is string => Boolean(x))
      .slice(0, 4),
    paletteHexes: doc.extractedPalette.map((c) => c.hex),
    pinnedOffline: doc.pinnedOffline,
    updatedAt: doc.updatedAt,
  };
}

function resetStores() {
  useCoordinatorStore.setState({
    themeMode: 'light',
    surfaceState: null,
    sidebarOpen: true,
    sidebarCollapsed: false,
    inspectorOpen: true,
    inspectorTab: 'info',
    inspectorCardOrder: [...DEFAULT_INSPECTOR_CARD_ORDER],
    visualFilterBarOpen: false,
    layoutMode: 'verticalMasonry',
    cardScale: 236,
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
    onboardingDone: true,
    onboardingStep: 0,
    resumeOnboardingOnSettingsClose: false,
    moodboardGeneratorOpen: false,
    activeMoodboardId: null,
    toasts: [],
  });
  useLibraryStore.setState({
    assets: [],
    allAssets: [],
    folders: [],
    smartFolders: [],
    tagCounts: [],
    inboxCount: 0,
    cutAssetIds: [],
    criteria: createDefaultFilterCriteria(),
    semanticSearch: false,
    loading: false,
    bootstrapped: false,
    error: null,
  });
  useMoodboardStore.setState({
    boards: [],
    activeBoard: null,
    historyPast: [],
    historyFuture: [],
    selectedNodeIds: [],
    swappingNodeId: null,
    candidatePool: [],
    agentTrace: [],
    activeBoardAgentTrace: [],
    activeBoardLastSummary: null,
    loading: false,
    curating: false,
    isRefiningActiveBoard: false,
    openBoardFailedId: null,
    lastError: null,
  });
  useSyncAIStore.setState({
    syncConfig: null,
    syncStatus: null,
    cacheStats: null,
    syncing: false,
    migrating: false,
    aiState: null,
    typesafeState: null,
  });
}

async function seedMockAssets(
  transport: InMemoryMockTransport,
  count: number,
  opts?: { trashed?: boolean },
): Promise<AssetRecord[]> {
  await transport.seedSampleLibraryIfEmpty();
  const initial = await transport.fetchAssets(createDefaultFilterCriteria({ includeTrashed: true }));
  const picked = initial.slice(0, count);
  if (picked.length < count) {
    throw new Error(`Expected at least ${count} seeded assets, got ${picked.length}`);
  }
  const extraIds = initial.slice(count).map((a) => a.id);
  if (extraIds.length > 0) {
    await transport.permanentlyDeleteAssets(extraIds);
  }
  if (opts?.trashed) {
    await transport.updateAssets({
      assetIDs: picked.map((a) => a.id),
      isTrashed: true,
    });
  }
  const fresh = await transport.fetchAssets(createDefaultFilterCriteria({ includeTrashed: true }));
  return fresh;
}

describe('Round 7 — Moodboard Removal, Multi-Select Portal Isolation & Liquid Glass Legibility', () => {
  beforeEach(() => {
    resetStores();
    setTransport(new InMemoryMockTransport());
  });

  // =========================================================================
  // 1. Moodboard Removal (Portaled Context Menu, Multi-Select, Transform Pill,
  //    Locked Nodes, Immediate Save, Palette Clearing, Unfiltered allAssets)
  // =========================================================================
  describe('Moodboard Asset Removal', () => {
    it('removes a locked node via right-click REAL mouseDown+mouseUp+click, saves immediately, updates boards itemCount, and restores via Undo toast', async () => {
      const transport = new InMemoryMockTransport();
      const saveBoardSpy = vi.spyOn(transport, 'saveBoard');
      setTransport(transport);

      const assetA = makeAsset('MB-ASSET-A', 'Editorial Hero');
      const assetB = makeAsset('MB-ASSET-B', 'Secondary Card');
      const nodeLocked = makeAssetNode('NODE-LOCKED', assetA.id, 0, { isLocked: true });
      const nodeNormal = makeAssetNode('NODE-NORMAL', assetB.id, 1);
      const board = makeBoardDoc('BOARD-R7-1', [nodeLocked, nodeNormal]);
      await transport.saveBoard(board);
      saveBoardSpy.mockClear();

      useLibraryStore.setState({
        assets: [assetA, assetB],
        allAssets: [assetA, assetB],
      });
      useMoodboardStore.setState({
        activeBoard: board,
        boards: [makeBoardSummary(board)],
        selectedNodeIds: [],
      });
      useCoordinatorStore.setState({
        destination: { type: 'moodboard', id: board.id },
        activeMoodboardId: board.id,
      });

      const { container } = render(
        <>
          <MoodboardStudioView />
          <ToastHost />
        </>,
      );

      const lockedNodeEl = container.querySelector<HTMLElement>('[data-board-node-id="NODE-LOCKED"]');
      expect(lockedNodeEl).not.toBeNull();

      fireEvent.contextMenu(lockedNodeEl!, { clientX: 260, clientY: 220 });

      const menu = await screen.findByTestId('moodboard-node-context-menu');
      // Portaled outside the stage DOM tree into document.body
      expect(container.contains(menu)).toBe(false);
      expect(document.body.contains(menu)).toBe(true);

      const removeBtn = screen.getByRole('button', { name: '从情绪板移除' });

      // REAL mouseDown must NOT unmount the menu prematurely before click fires
      fireEvent.mouseDown(removeBtn, { button: 0, bubbles: true });
      expect(screen.getByTestId('moodboard-node-context-menu')).toBeInTheDocument();
      fireEvent.mouseUp(removeBtn, { button: 0, bubbles: true });
      fireEvent.click(removeBtn, { button: 0, bubbles: true });

      // Locked node removed immediately, saveBoard invoked immediately, boards summary synced
      expect(useMoodboardStore.getState().activeBoard?.nodes.map((n) => n.id)).toEqual([
        'NODE-NORMAL',
      ]);
      expect(saveBoardSpy).toHaveBeenCalledTimes(1);
      expect(saveBoardSpy.mock.calls[0][0].nodes.map((n) => n.id)).toEqual(['NODE-NORMAL']);
      expect(
        useMoodboardStore.getState().boards.find((b) => b.id === board.id)?.itemCount,
      ).toBe(1);

      // Undo toast appears and clicking "撤销" restores the locked node
      const toastMsg = await screen.findByText('已从情绪板移除 1 项');
      const toastCard = toastMsg.closest<HTMLElement>('.charkle-toast-item');
      expect(toastCard).not.toBeNull();
      const undoBtn = within(toastCard!).getByRole('button', { name: '撤销' });
      realPointerClick(undoBtn);

      expect(useMoodboardStore.getState().activeBoard?.nodes.map((n) => n.id)).toEqual([
        'NODE-LOCKED',
        'NODE-NORMAL',
      ]);
      expect(
        useMoodboardStore.getState().boards.find((b) => b.id === board.id)?.itemCount,
      ).toBe(2);
    });

    it('multi-select 2+ nodes right-click shows count and removes ALL selected nodes on REAL mouseDown+mouseUp+click', async () => {
      const transport = new InMemoryMockTransport();
      const saveBoardSpy = vi.spyOn(transport, 'saveBoard');
      setTransport(transport);

      const assets = [
        makeAsset('MB-M-1', 'Card 1'),
        makeAsset('MB-M-2', 'Card 2'),
        makeAsset('MB-M-3', 'Card 3'),
      ];
      const nodes = assets.map((a, idx) => makeAssetNode(`NODE-${idx + 1}`, a.id, idx));
      const board = makeBoardDoc('BOARD-R7-2', nodes);
      await transport.saveBoard(board);
      saveBoardSpy.mockClear();

      useLibraryStore.setState({ assets, allAssets: assets });
      useMoodboardStore.setState({
        activeBoard: board,
        boards: [makeBoardSummary(board)],
        selectedNodeIds: ['NODE-1', 'NODE-2'],
      });
      useCoordinatorStore.setState({
        destination: { type: 'moodboard', id: board.id },
        activeMoodboardId: board.id,
      });

      const { container } = render(<MoodboardStudioView />);

      const node2 = container.querySelector<HTMLElement>('[data-board-node-id="NODE-2"]');
      expect(node2).not.toBeNull();
      fireEvent.contextMenu(node2!, { clientX: 340, clientY: 200 });

      const removeBtn = await screen.findByRole('button', { name: '从情绪板移除 (2 项)' });
      fireEvent.mouseDown(removeBtn, { button: 0, bubbles: true });
      expect(screen.getByTestId('moodboard-node-context-menu')).toBeInTheDocument();
      fireEvent.mouseUp(removeBtn, { button: 0, bubbles: true });
      fireEvent.click(removeBtn, { button: 0, bubbles: true });

      expect(useMoodboardStore.getState().activeBoard?.nodes.map((n) => n.id)).toEqual(['NODE-3']);
      expect(useMoodboardStore.getState().selectedNodeIds).toEqual([]);
      expect(useMoodboardStore.getState().boards[0]?.itemCount).toBe(1);
      expect(saveBoardSpy).toHaveBeenCalledTimes(1);
    });

    it('keeps Transform Pill visible for multi-select, deletes all selected nodes, clears extractedPalette to [] when last assetRef is removed, and resolves assets from allAssets when assets is empty', async () => {
      const transport = new InMemoryMockTransport();
      setTransport(transport);

      const asset1 = makeAsset('MB-P-1', 'Unfiltered Hero One');
      const asset2 = makeAsset('MB-P-2', 'Unfiltered Hero Two');
      const nodes = [makeAssetNode('NP-1', asset1.id, 0), makeAssetNode('NP-2', asset2.id, 1)];
      const board = makeBoardDoc('BOARD-R7-3', nodes);
      await transport.saveBoard(board);

      // Simulate user switching from a filtered/empty folder view: `assets` is [], `allAssets` has full library
      useLibraryStore.setState({
        assets: [],
        allAssets: [asset1, asset2],
      });
      useMoodboardStore.setState({
        activeBoard: board,
        boards: [makeBoardSummary(board)],
        selectedNodeIds: ['NP-1', 'NP-2'],
      });
      useCoordinatorStore.setState({
        destination: { type: 'moodboard', id: board.id },
        activeMoodboardId: board.id,
      });

      render(<MoodboardStudioView />);

      // Assets resolve via allAssets even when filtered `assets` is empty
      expect(screen.getByAltText('Unfiltered Hero One')).toBeInTheDocument();
      expect(screen.getByAltText('Unfiltered Hero Two')).toBeInTheDocument();

      // Transform Pill stays visible on multi-select with Delete button
      const pill = screen.getByTestId('selected-transform-pill');
      expect(pill).toBeInTheDocument();
      expect(pill.textContent).toContain('已选 2 项');
      const deleteBtn = screen.getByRole('button', { name: '删除选中节点' });
      expect(deleteBtn.textContent).toContain('移除 (2)');

      realPointerClick(deleteBtn);

      const updatedBoard = useMoodboardStore.getState().activeBoard;
      expect(updatedBoard?.nodes).toEqual([]);
      expect(updatedBoard?.extractedPalette).toEqual([]);
      expect(useMoodboardStore.getState().boards[0]?.itemCount).toBe(0);
      expect(useMoodboardStore.getState().boards[0]?.paletteHexes).toEqual([]);
    });
  });

  // =========================================================================
  // 2. Asset Library Multi-Select Removal & React Portal Event Isolation
  // =========================================================================
  describe('Asset Library Multi-Select Removal & Portal Event Isolation', () => {
    it.each([
      {
        name: 'VerticalMasonryView',
        Component: VerticalMasonryView,
      },
      {
        name: 'HorizontalJustifiedView',
        Component: HorizontalJustifiedView,
      },
    ])(
      '$name preserves 3-item selection across portaled menu REAL mouseDown+mouseUp+click, trashes all 3 with zero ghost selection, and Undo restores all 3',
      async ({ Component }) => {
        const transport = new InMemoryMockTransport();
        const seeded = await seedMockAssets(transport, 3);
        const ids = seeded.map((a) => a.id);
        const updateSpy = vi.spyOn(transport, 'updateAssets');
        setTransport(transport);

        useCoordinatorStore.setState({
          destination: { type: 'allItems' },
          selectedAssetIds: [...ids],
          lastSelectedAssetId: ids[2],
        });
        useLibraryStore.setState({
          assets: seeded,
          allAssets: seeded,
        });

        function Harness() {
          const liveAssets = useLibraryStore((s) => s.assets);
          return (
            <>
              <Component assets={liveAssets} cardScale={236} />
              <ToastHost />
            </>
          );
        }

        const { container } = render(<Harness />);

        const cardB = container.querySelector<HTMLElement>(`[data-asset-id="${ids[1]}"]`);
        expect(cardB).not.toBeNull();
        fireEvent.contextMenu(cardB!, { clientX: 240, clientY: 180 });

        const trashBtn = await screen.findByRole('button', { name: '移至回收站 (3 项)' });

        // REAL mouseDown inside portal must NOT clear selection or start a marquee on scrollRef
        fireEvent.mouseDown(trashBtn, { button: 0, bubbles: true });
        expect(useCoordinatorStore.getState().selectedAssetIds).toEqual(ids);
        expect(container.querySelector('.bg-\\[var\\(--accent-soft\\)\\]')).toBeNull();

        fireEvent.mouseUp(trashBtn, { button: 0, bubbles: true });
        fireEvent.click(trashBtn, { button: 0, bubbles: true });

        await waitFor(() => {
          expect(updateSpy).toHaveBeenCalledWith({
            assetIDs: ids,
            isTrashed: true,
          });
        });

        await waitFor(() => {
          expect(useLibraryStore.getState().assets).toHaveLength(0);
        });
        expect(useCoordinatorStore.getState().selectedAssetIds).toEqual([]);

        // Undo restores all 3 assets
        const undoBtn = await screen.findByRole('button', { name: '撤销' });
        realPointerClick(undoBtn);

        await waitFor(() => {
          expect(useLibraryStore.getState().assets).toHaveLength(3);
        });
        expect(useLibraryStore.getState().assets.map((a) => a.id).sort()).toEqual(
          [...ids].sort(),
        );
      },
    );

    it('Trash view 3-item multi-select right-click permanent delete passes all 3 IDs through <Popover> + <ModalShell> with REAL pointer events', async () => {
      const transport = new InMemoryMockTransport();
      const trashed = await seedMockAssets(transport, 3, { trashed: true });
      const ids = trashed.map((a) => a.id);
      const deleteSpy = vi.spyOn(transport, 'permanentlyDeleteAssets');
      setTransport(transport);

      useCoordinatorStore.setState({
        destination: { type: 'trash' },
        selectedAssetIds: [...ids],
        lastSelectedAssetId: ids[2],
      });
      useLibraryStore.setState({
        assets: trashed,
        allAssets: trashed,
      });

      function TrashHarness() {
        const liveAssets = useLibraryStore((s) => s.assets);
        return <VerticalMasonryView assets={liveAssets} cardScale={236} />;
      }

      const { container } = render(<TrashHarness />);

      const cardB = container.querySelector<HTMLElement>(`[data-asset-id="${ids[1]}"]`);
      expect(cardB).not.toBeNull();
      fireEvent.contextMenu(cardB!, { clientX: 200, clientY: 160 });

      const permDeleteMenuBtn = await screen.findByRole('button', {
        name: /彻底删除.*\(3 项\)/,
      });
      realPointerClick(permDeleteMenuBtn);

      // Confirmation <ModalShell> opens with exact count
      expect(await screen.findByText('彻底删除 3 项素材？')).toBeInTheDocument();

      const confirmBtn = screen.getByRole('button', { name: '彻底删除' });
      // REAL mouseDown inside ModalShell must not clear selection or dismiss modal
      fireEvent.mouseDown(confirmBtn, { button: 0, bubbles: true });
      expect(screen.getByText('彻底删除 3 项素材？')).toBeInTheDocument();
      fireEvent.mouseUp(confirmBtn, { button: 0, bubbles: true });
      fireEvent.click(confirmBtn, { button: 0, bubbles: true });

      await waitFor(() => {
        expect(deleteSpy).toHaveBeenCalledWith(ids);
      });
      await waitFor(() => {
        expect(useLibraryStore.getState().assets).toHaveLength(0);
      });
      expect(useCoordinatorStore.getState().selectedAssetIds).toEqual([]);
    });

    it('Trash view Delete key opens irreversible confirmation modal (彻底删除 3 项素材？) and deletes all 3 on confirm', async () => {
      const transport = new InMemoryMockTransport();
      const trashed = await seedMockAssets(transport, 3, { trashed: true });
      const ids = trashed.map((a) => a.id);
      const deleteSpy = vi.spyOn(transport, 'permanentlyDeleteAssets');
      setTransport(transport);

      useCoordinatorStore.setState({
        destination: { type: 'trash' },
        onboardingDone: true,
        onboardingOpen: false,
      });

      render(<App />);

      await waitFor(() => {
        expect(useLibraryStore.getState().assets).toHaveLength(3);
      });

      act(() => {
        useCoordinatorStore.getState().setSelection(ids, ids[2]);
      });

      fireEvent.keyDown(window, { key: 'Delete' });

      const modalHeading = await screen.findByText('彻底删除 3 项素材？');
      const modalDialog = modalHeading.closest<HTMLElement>('[role="dialog"]');
      expect(modalDialog).not.toBeNull();
      const confirmBtn = within(modalDialog!).getByRole('button', { name: '彻底删除' });
      realPointerClick(confirmBtn);

      await waitFor(() => {
        expect(deleteSpy).toHaveBeenCalledWith(ids);
      });
      await waitFor(() => {
        expect(useLibraryStore.getState().assets).toHaveLength(0);
      });
      expect(useCoordinatorStore.getState().selectedAssetIds).toEqual([]);
    });

    it('GalleryFilmstripView preserves 3-item multi-selection on thumb right-click and trashes all 3', async () => {
      const transport = new InMemoryMockTransport();
      const seeded = await seedMockAssets(transport, 3);
      const ids = seeded.map((a) => a.id);
      const updateSpy = vi.spyOn(transport, 'updateAssets');
      setTransport(transport);

      useCoordinatorStore.setState({
        destination: { type: 'allItems' },
        layoutMode: 'galleryFilmstrip',
        selectedAssetIds: [...ids],
        lastSelectedAssetId: ids[1],
      });
      useLibraryStore.setState({
        assets: seeded,
        allAssets: seeded,
      });

      function FilmstripHarness() {
        const liveAssets = useLibraryStore((s) => s.assets);
        return <GalleryFilmstripView assets={liveAssets} />;
      }

      const { container } = render(<FilmstripHarness />);
      const thumbB = container.querySelector<HTMLElement>(`[data-strip-id="${ids[1]}"]`);
      expect(thumbB).not.toBeNull();

      fireEvent.contextMenu(thumbB!, { clientX: 280, clientY: 500 });
      const trashBtn = await screen.findByRole('button', { name: '移至回收站 (3 项)' });
      realPointerClick(trashBtn);

      await waitFor(() => {
        expect(updateSpy).toHaveBeenCalledWith({
          assetIDs: ids,
          isTrashed: true,
        });
      });
      await waitFor(() => {
        expect(useLibraryStore.getState().assets).toHaveLength(0);
      });
      expect(useCoordinatorStore.getState().selectedAssetIds).toEqual([]);
    });

    it('GalleryRingView preserves multi-selection on right-click for both normal Trash and Trash permanent delete', async () => {
      function RingHarness() {
        const liveAssets = useLibraryStore((s) => s.assets);
        return <GalleryRingView assets={liveAssets} />;
      }

      // Part 1: Normal view -> 3 selected -> right-click -> trash all 3
      const transport1 = new InMemoryMockTransport();
      const seeded = await seedMockAssets(transport1, 3);
      const ids = seeded.map((a) => a.id);
      const updateSpy = vi.spyOn(transport1, 'updateAssets');
      setTransport(transport1);

      useCoordinatorStore.setState({
        destination: { type: 'allItems' },
        layoutMode: 'ringGallery',
        selectedAssetIds: [...ids],
        lastSelectedAssetId: ids[1],
      });
      useLibraryStore.setState({
        assets: seeded,
        allAssets: seeded,
      });

      const view1 = render(<RingHarness />);
      let ringCard: HTMLElement | null = null;
      await waitFor(() => {
        ringCard = view1.container.querySelector<HTMLElement>(`[data-asset-id="${ids[1]}"]`);
        expect(ringCard).not.toBeNull();
      });

      fireEvent.contextMenu(ringCard!, { clientX: 320, clientY: 260 });
      const trashBtn = await screen.findByRole('button', { name: '移至回收站 (3 项)' });
      realPointerClick(trashBtn);

      await waitFor(() => {
        expect(updateSpy).toHaveBeenCalledWith({
          assetIDs: ids,
          isTrashed: true,
        });
      });
      await waitFor(() => {
        expect(useLibraryStore.getState().assets).toHaveLength(0);
      });
      expect(useCoordinatorStore.getState().selectedAssetIds).toEqual([]);
      view1.unmount();

      // Part 2: Trash view -> 3 trashed selected -> right-click -> permanent delete all 3 via ModalShell
      resetStores();
      const transport2 = new InMemoryMockTransport();
      const trashed = await seedMockAssets(transport2, 3, { trashed: true });
      const trashedIds = trashed.map((a) => a.id);
      const permDeleteSpy = vi.spyOn(transport2, 'permanentlyDeleteAssets');
      setTransport(transport2);

      useCoordinatorStore.setState({
        destination: { type: 'trash' },
        layoutMode: 'ringGallery',
        selectedAssetIds: [...trashedIds],
        lastSelectedAssetId: trashedIds[1],
      });
      useLibraryStore.setState({
        assets: trashed,
        allAssets: trashed,
      });

      const view2 = render(<RingHarness />);
      let trashRingCard: HTMLElement | null = null;
      await waitFor(() => {
        trashRingCard = view2.container.querySelector<HTMLElement>(
          `[data-asset-id="${trashedIds[1]}"]`,
        );
        expect(trashRingCard).not.toBeNull();
      });

      fireEvent.contextMenu(trashRingCard!, { clientX: 320, clientY: 260 });
      const permMenuBtn = await screen.findByRole('button', {
        name: /彻底删除.*\(3 项\)/,
      });
      realPointerClick(permMenuBtn);

      const modalHeading = await screen.findByText('彻底删除 3 项素材？');
      const modalDialog = modalHeading.closest<HTMLElement>('[role="dialog"]');
      expect(modalDialog).not.toBeNull();
      const confirmBtn = within(modalDialog!).getByRole('button', { name: '彻底删除' });
      realPointerClick(confirmBtn);

      await waitFor(() => {
        expect(permDeleteSpy).toHaveBeenCalledWith(trashedIds);
      });
      await waitFor(() => {
        expect(useLibraryStore.getState().assets).toHaveLength(0);
      });
      expect(useCoordinatorStore.getState().selectedAssetIds).toEqual([]);
    });
  });

  // =========================================================================
  // 3. Search & Dense-Text Liquid Glass Legibility
  // =========================================================================
  describe('Search & Dense-Text Liquid Glass Legibility', () => {
    it('JumpAnywhereModal uses studio-frost charkle-command-palette with data-no-lens="true" and no overridden bg-[var(--bg-elevated)]/95', async () => {
      useCoordinatorStore.setState({ jumpOpen: true });
      render(<JumpAnywhereModal />);

      const panel = await screen.findByTestId('jump-anywhere-modal');
      await waitFor(() => {
        expect(panel.getAttribute('data-no-lens')).toBe('true');
      });
      expect(panel.className).toContain('charkle-glass');
      expect(panel.className).toContain('charkle-command-palette');
      expect(panel.className).not.toContain('bg-[var(--bg-elevated)]/95');
    });

    it('ToastHost, visual-filter-bar, ring-tuning-panel carry data-no-lens="true" + studio-frost classes, and TopFilterCapsule search pill carries charkle-search-capsule', () => {
      const sampleAsset = makeAsset('GLASS-A', 'Glass Legibility Sample');
      useCoordinatorStore.setState({
        visualFilterBarOpen: true,
        toasts: [
          {
            id: 'toast-r7',
            message: '已移至回收站 (3 项)',
            tone: 'info',
            actionLabel: '撤销',
            onAction: () => {},
          },
        ],
      });
      useLibraryStore.setState({
        assets: [sampleAsset],
        allAssets: [sampleAsset],
      });

      render(
        <>
          <ToastHost />
          <TopFilterCapsule />
          <GalleryRingView assets={[sampleAsset]} />
        </>,
      );

      // ToastHost card
      const toastCard = document.querySelector<HTMLElement>('.charkle-toast-item');
      expect(toastCard).not.toBeNull();
      expect(toastCard!.getAttribute('data-no-lens')).toBe('true');
      expect(toastCard!.className).toContain('charkle-toast-glass');

      // TopFilterCapsule search capsule + visual-filter-bar
      const searchInput = screen.getByRole('textbox', { name: '搜索素材' });
      const searchCapsule = searchInput.closest<HTMLElement>('.charkle-search-capsule');
      expect(searchCapsule).not.toBeNull();
      expect(searchCapsule!.className).toContain('charkle-glass');

      const filterBar = screen.getByTestId('visual-filter-bar');
      expect(filterBar.getAttribute('data-no-lens')).toBe('true');
      expect(filterBar.className).toContain('charkle-glass-panel');
      expect(filterBar.getAttribute('data-adapt-glass')).toBeNull();

      // Ring tuning panel
      const tuningToggle = screen.getByTestId('ring-tuning-toggle');
      realPointerClick(tuningToggle);
      const tuningPanel = screen.getByTestId('ring-tuning-panel');
      expect(tuningPanel.getAttribute('data-no-lens')).toBe('true');
      expect(tuningPanel.className).toContain('charkle-glass-panel');
      expect(tuningPanel.getAttribute('data-adapt-glass')).toBeNull();
    });

    it('tokens.css defines all 5 dense-text & search studio-frost classes strictly AFTER @media (prefers-reduced-transparency: reduce)', async () => {
      const css = await loadTokensCss();
      const rtmMarker = '@media (prefers-reduced-transparency: reduce)';
      const rtmIdx = css.indexOf(rtmMarker);
      expect(rtmIdx).toBeGreaterThan(-1);

      const requiredSelectors = [
        '.charkle-command-palette.charkle-glass',
        '.charkle-popover-panel.charkle-glass',
        '.charkle-glass-panel.charkle-glass',
        '.charkle-toast-glass.charkle-glass',
        '.charkle-search-capsule.charkle-glass',
      ];

      for (const selector of requiredSelectors) {
        const blockToken = `${selector} {`;
        const idx = css.indexOf(blockToken);
        expect(idx, `${blockToken} should exist in tokens.css`).toBeGreaterThan(-1);
        expect(
          idx,
          `${blockToken} must be declared AFTER ${rtmMarker} so Windows Transparency Off never resets its legibility floor`,
        ).toBeGreaterThan(rtmIdx);
      }

      // Ensure adaptive floor clamp --m-floor-min is honored in --tint-a
      expect(css).toContain('var(--m-floor-min, 0)');
    });
  });
});
