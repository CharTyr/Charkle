import { act, fireEvent, render, screen, waitFor } from '@testing-library/react';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { InMemoryMockTransport, setTransport } from '../api/transport';
import {
  isAllowedVideoEmbedUrl,
  parseSafeExternalUrl,
  sanitizeMarkdownHtml,
} from '../design-system';
import { beginPointerDrag } from '../features/dnd/PointerDragContext';
import { InspectorView } from '../features/inspector/InspectorView';
import { JumpAnywhereModal } from '../features/jump/JumpAnywhereModal';
import { PinterestBoardImportModal } from '../features/pinterest/PinterestBoardImportModal';
import {
  DEFAULT_INSPECTOR_CARD_ORDER,
  moveAssetsToFolderWithUndo,
  useAppUpdateStore,
  useCoordinatorStore,
  useLibraryStore,
  useMoodboardStore,
  usePinterestStore,
} from '../stores';
import {
  createDefaultFilterCriteria,
  type AssetRecord,
  type MoodboardDocument,
  type MoodboardProposal,
  type MoodboardSummary,
  type PinterestBoard,
} from '../types/domain';

function makeAsset(overrides: Partial<AssetRecord> = {}): AssetRecord {
  const id = overrides.id ?? 'asset-1';
  return {
    id,
    contentHash: overrides.contentHash ?? `hash-${id}`,
    folderID: overrides.folderID ?? null,
    mediaKind: overrides.mediaKind ?? 'image',
    mimeType: overrides.mimeType ?? 'image/png',
    title: overrides.title ?? '示例素材',
    fileName: overrides.fileName ?? `${id}.png`,
    notes: overrides.notes ?? '',
    tags: overrides.tags ?? [],
    suggestedTags: overrides.suggestedTags ?? [],
    rating: overrides.rating ?? 0,
    pixelWidth: overrides.pixelWidth ?? 800,
    pixelHeight: overrides.pixelHeight ?? 600,
    durationSeconds: overrides.durationSeconds ?? null,
    fileSizeBytes: overrides.fileSizeBytes ?? 12000,
    dominantColors: overrides.dominantColors ?? [],
    waveformPeaks: overrides.waveformPeaks ?? [],
    sourceURL: overrides.sourceURL ?? null,
    sourceDomain: overrides.sourceDomain ?? null,
    richMetadata: overrides.richMetadata ?? null,
    pinnedOffline: overrides.pinnedOffline ?? false,
    isLocalOriginalCached: overrides.isLocalOriginalCached ?? true,
    isTrashed: overrides.isTrashed ?? false,
    createdAt: overrides.createdAt ?? 1000,
    updatedAt: overrides.updatedAt ?? 1000,
    lastOpenedAt: overrides.lastOpenedAt ?? null,
    updatedHLC: overrides.updatedHLC ?? 1,
    ...overrides,
  };
}

function makeBoardDoc(id: string, title: string): MoodboardDocument {
  return {
    id,
    title,
    subtitle: '',
    mode: { freeform: {} },
    nodes: [],
    connectors: [],
    inkStrokes: [],
    extractedPalette: [],
    candidateAssetIDs: [],
    pinnedOffline: false,
    viewportCenter: { x: 0, y: 0 },
    viewportZoom: 1,
    createdAt: 1000,
    updatedAt: 1000,
    updatedHLC: 1,
  };
}

function makeBoardSummary(id: string, title: string): MoodboardSummary {
  return {
    id,
    title,
    subtitle: '',
    mode: { freeform: {} },
    itemCount: 0,
    previewAssetIDs: [],
    paletteHexes: [],
    pinnedOffline: false,
    updatedAt: 1000,
  };
}

describe('Code Review Fixes Regression Suite', () => {
  let mock: InMemoryMockTransport;

  beforeEach(() => {
    mock = new InMemoryMockTransport(true);
    setTransport(mock);
    useCoordinatorStore.setState({
      destination: { type: 'allItems' },
      selectedAssetIds: [],
      lastSelectedAssetId: null,
      quickLookAssetId: null,
      quickLookOriginRect: null,
      jumpOpen: false,
      captureOpen: false,
      settingsOpen: false,
      dedupOpen: false,
      onboardingOpen: false,
      moodboardGeneratorOpen: false,
      inspectorOpen: true,
      inspectorTab: 'info',
      inspectorCardOrder: [...DEFAULT_INSPECTOR_CARD_ORDER],
      toasts: [],
    });
    useLibraryStore.setState({
      assets: [],
      allAssets: [],
      folders: [],
      smartFolders: [],
      tagCounts: [],
      inboxCount: 0,
      criteria: createDefaultFilterCriteria(),
      loading: false,
      bootstrapped: true,
      error: null,
    });
    useMoodboardStore.setState({
      boards: [],
      activeBoard: null,
      selectedNodeIds: [],
      historyPast: [],
      historyFuture: [],
      curating: false,
      isRefiningActiveBoard: false,
      loading: false,
    });
    useAppUpdateStore.setState({
      state: { status: 'idle' },
      sheetOpen: false,
      hasScheduledLaunchCheck: false,
    });
    usePinterestStore.setState({
      boardImportModalOpen: false,
      boards: [],
      isLoadingBoards: false,
      isImportingBoards: false,
      boardImportProgress: null,
      lastBoardImportReport: null,
    });
  });

  afterEach(() => {
    vi.useRealTimers();
    vi.restoreAllMocks();
  });

  // -------------------------------------------------------------------------
  // 1. Markdown HTML sanitization & external URL / video embed allowlists
  // -------------------------------------------------------------------------

  it('sanitizes untrusted Markdown HTML against style injection, SVG XSS, and internal media/loopback probes', () => {
    const dirty = [
      '<div style="position:fixed;inset:0" data-secret="1" aria-label="spoof">Hi</div>',
      '<svg onload="alert(1)"><script>alert(2)</script></svg>',
      '<a href="javascript:alert(3)">bad link</a>',
      '<a href="https://example.com/docs">good link</a>',
      '<img src="http://charkle-media.localhost/thumb/1" alt="internal" />',
      '<img src="http://127.0.0.1:8080/probe.png" alt="loopback" />',
      '<img src="https://cdn.example.com/pic.png" alt="ok" />',
    ].join('');

    const clean = sanitizeMarkdownHtml(dirty);
    expect(clean).not.toContain('position:fixed');
    expect(clean).not.toContain('data-secret');
    expect(clean).not.toContain('aria-label');
    expect(clean).not.toContain('<svg');
    expect(clean).not.toContain('<script');
    expect(clean).not.toContain('javascript:');
    expect(clean).not.toContain('charkle-media.localhost');
    expect(clean).not.toContain('127.0.0.1');

    expect(clean).toContain('https://example.com/docs');
    expect(clean).toContain('rel="noopener noreferrer"');
    expect(clean).toContain('https://cdn.example.com/pic.png');
    expect(clean).toContain('referrerpolicy="no-referrer"');
  });

  it('strictly validates external links and video embed URLs', () => {
    expect(parseSafeExternalUrl('https://github.com/charkle')).toBe('https://github.com/charkle');
    expect(parseSafeExternalUrl('javascript:alert(1)')).toBeNull();
    expect(parseSafeExternalUrl('file:///C:/Windows/System32/cmd.exe')).toBeNull();

    expect(isAllowedVideoEmbedUrl('https://www.youtube.com/embed/dQw4w9WgXcQ')).toBe(true);
    expect(isAllowedVideoEmbedUrl('https://www.youtube-nocookie.com/embed/abc')).toBe(true);
    expect(isAllowedVideoEmbedUrl('https://player.bilibili.com/player.html?bvid=BV1xx')).toBe(true);
    expect(isAllowedVideoEmbedUrl('http://www.youtube.com/embed/dQw4w9WgXcQ')).toBe(false);
    expect(isAllowedVideoEmbedUrl('https://evil.example.com/embed/video')).toBe(false);
    expect(isAllowedVideoEmbedUrl('javascript:alert(1)')).toBe(false);
  });

  // -------------------------------------------------------------------------
  // 2. JumpAnywhereModal 1:1 visual & keyboard activeIndex parity
  // -------------------------------------------------------------------------

  it('renders matched quick commands on non-empty query and executes them on Enter with 1:1 index parity', async () => {
    useCoordinatorStore.setState({ jumpOpen: true, dedupOpen: false });
    render(<JumpAnywhereModal />);

    const input = screen.getByRole('textbox', { name: '快速跳转搜索框' });
    fireEvent.change(input, { target: { value: '智能去重' } });

    const commandBtn = await screen.findByText('智能去重');
    expect(commandBtn).toBeInTheDocument();

    fireEvent.keyDown(input, { key: 'Enter' });
    expect(useCoordinatorStore.getState().dedupOpen).toBe(true);
    expect(useCoordinatorStore.getState().jumpOpen).toBe(false);
  });

  // -------------------------------------------------------------------------
  // 3. PinterestBoardImportModal deselect-all persistence & Escape dismissal
  // -------------------------------------------------------------------------

  it('keeps deselected state after clicking 取消全选 and closes on Escape', async () => {
    const boards: PinterestBoard[] = [
      {
        id: 'b-1',
        name: 'Poster Inspiration',
        urlPath: '/user/poster/',
        pinCount: 12,
        coverImageURL: null,
        isSecret: false,
        ownerUsername: 'user',
      },
      {
        id: 'b-2',
        name: 'UI Typography',
        urlPath: '/user/type/',
        pinCount: 8,
        coverImageURL: null,
        isSecret: false,
        ownerUsername: 'user',
      },
    ];

    usePinterestStore.setState({
      boardImportModalOpen: true,
      boards,
      isLoadingBoards: false,
      isImportingBoards: false,
    });
    const closeSpy = vi.spyOn(usePinterestStore.getState(), 'closeBoardImportModal');

    render(<PinterestBoardImportModal />);

    await waitFor(() => {
      expect(screen.getByRole('button', { name: '取消全选' })).toBeInTheDocument();
    });

    fireEvent.click(screen.getByRole('button', { name: '取消全选' }));
    await waitFor(() => {
      expect(screen.getByRole('button', { name: '全选' })).toBeInTheDocument();
    });

    fireEvent.keyDown(window, { key: 'Escape' });
    expect(closeSpy).toHaveBeenCalledTimes(1);
  });

  // -------------------------------------------------------------------------
  // 4. PointerDragContext blur listener cleanup (zero leak)
  // -------------------------------------------------------------------------

  it('removes window blur listener cleanly when pointer drag finishes', () => {
    const addSpy = vi.spyOn(window, 'addEventListener');
    const removeSpy = vi.spyOn(window, 'removeEventListener');

    const fakeEvent = {
      button: 0,
      pointerId: 1,
      clientX: 10,
      clientY: 10,
      currentTarget: document.createElement('div'),
    } as unknown as React.PointerEvent;

    beginPointerDrag(fakeEvent, {
      kind: 'assets',
      assetIds: ['asset-1'],
      previewAssetId: 'asset-1',
      title: 'Test',
    });

    const addedBlur = addSpy.mock.calls.filter(([type]) => type === 'blur');
    expect(addedBlur.length).toBe(1);

    fireEvent.pointerUp(window, { pointerId: 1, clientX: 10, clientY: 10 });

    const removedBlur = removeSpy.mock.calls.filter(([type]) => type === 'blur');
    expect(removedBlur.length).toBe(1);
    expect(removedBlur[0][1]).toBe(addedBlur[0][1]);
  });

  // -------------------------------------------------------------------------
  // 5. useAppUpdateStore StrictMode launch check cleanup
  // -------------------------------------------------------------------------

  it('resets hasScheduledLaunchCheck when deferred launch check is cancelled before firing', () => {
    vi.useFakeTimers();
    const cancelFirst = useAppUpdateStore.getState().scheduleDeferredLaunchCheck(undefined, 1500);
    expect(useAppUpdateStore.getState().hasScheduledLaunchCheck).toBe(true);

    // Simulate React StrictMode unmount before timer fires
    cancelFirst();
    expect(useAppUpdateStore.getState().hasScheduledLaunchCheck).toBe(false);

    // Re-mounting can schedule cleanly again
    const cancelSecond = useAppUpdateStore.getState().scheduleDeferredLaunchCheck(undefined, 1500);
    expect(useAppUpdateStore.getState().hasScheduledLaunchCheck).toBe(true);
    cancelSecond();
  });

  // -------------------------------------------------------------------------
  // 6. useMoodboardStore refineActiveBoard stale board-switch guard
  // -------------------------------------------------------------------------

  it('discards stale refineActiveBoard result when user switches to another board mid-request', async () => {
    const boardA = makeBoardDoc('board-a', 'Board A');
    const boardB = makeBoardDoc('board-b', 'Board B');

    let resolveCurate!: (value: MoodboardProposal) => void;
    vi.spyOn(mock, 'curateMoodboard').mockImplementation(
      () =>
        new Promise<MoodboardProposal>((resolve) => {
          resolveCurate = resolve;
        }),
    );

    useMoodboardStore.setState({
      boards: [makeBoardSummary('board-a', 'Board A'), makeBoardSummary('board-b', 'Board B')],
      activeBoard: boardA,
    });

    const pending = useMoodboardStore.getState().refineActiveBoard('加一点蓝色系', new Map());

    // Switch active board while refine RPC is in flight
    useMoodboardStore.setState({ activeBoard: boardB });

    const refinedDoc = makeBoardDoc('board-a', 'Board A');
    refinedDoc.nodes = [
      {
        id: 'stale-note',
        kind: { note: { title: '来自旧请求', text: '不应污染 Board B', style: 'paper', fontSize: 13 } },
        frame: { x: 0, y: 0, width: 200, height: 120 },
        zIndex: 1,
        rotationDegrees: 0,
        flipHorizontal: false,
        flipVertical: false,
        editorialOrder: 0,
        isLocked: false,
        updatedAt: 1000,
      },
    ];

    resolveCurate({
      draftDocument: refinedDoc,
      primaryMatches: [],
      candidatePool: [],
      extractedPalette: [],
      usedCloudAi: false,
      curatedSummary: '已微调 Board A',
      agentTrace: [],
      sections: [],
      cachedVisualInsightsCount: 0,
    });

    const outcome = await pending;
    expect(outcome).toBeNull();
    expect(useMoodboardStore.getState().activeBoard?.id).toBe('board-b');
    expect(useMoodboardStore.getState().activeBoard?.nodes).toHaveLength(0);
  });

  // -------------------------------------------------------------------------
  // 7. InspectorView webPage summary visibility & external title sync
  // -------------------------------------------------------------------------

  it('renders 网页摘要与媒体提取 for webPage metadata assets and syncs external title updates', async () => {
    const webAsset = makeAsset({
      id: 'web-1',
      title: '初始标题',
      mediaKind: 'webBookmark',
      fileName: 'article.url',
      sourceURL: 'https://example.com/design-essay',
      sourceDomain: 'example.com',
      richMetadata: {
        webPage: {
          siteName: 'Design Journal',
          summary: '一篇关于版式节奏与视觉层级的长文摘要。',
          attachments: [
            {
              id: 'att-1',
              kind: 'photo',
              url: 'https://cdn.example.com/hero.jpg',
            },
          ],
        },
      },
    });

    useLibraryStore.setState({
      assets: [webAsset],
      allAssets: [webAsset],
    });
    useCoordinatorStore.setState({
      selectedAssetIds: [webAsset.id],
      lastSelectedAssetId: webAsset.id,
    });

    render(<InspectorView active />);

    expect(await screen.findByText('网页摘要与媒体提取')).toBeInTheDocument();
    expect(screen.getByText('一篇关于版式节奏与视觉层级的长文摘要。')).toBeInTheDocument();

    const titleInput = screen.getByDisplayValue('初始标题') as HTMLInputElement;
    expect(document.activeElement).not.toBe(titleInput);

    // Simulate external metadata sync updating the same asset's title while input is unfocused
    const renamed = { ...webAsset, title: '远端同步新标题', updatedAt: 2000 };
    act(() => {
      useLibraryStore.setState({
        assets: [renamed],
        allAssets: [renamed],
      });
    });

    await waitFor(() => {
      expect((screen.getByDisplayValue('远端同步新标题') as HTMLInputElement).value).toBe(
        '远端同步新标题',
      );
    });
  });

  // -------------------------------------------------------------------------
  // 8. moveAssetsToFolderWithUndo preserves distinct source folders on Undo
  // -------------------------------------------------------------------------

  it('restores assets from two different source folders back to their exact original folders on Undo', async () => {
    await useLibraryStore.getState().refreshAll({ type: 'allItems' });
    const [a1, a2] = useLibraryStore.getState().allAssets;
    expect(a1).toBeDefined();
    expect(a2).toBeDefined();

    const [f1, f2] = useLibraryStore.getState().folders;
    expect(f1).toBeDefined();

    const targetFolder = await mock.createFolder('目标目录', null);
    await mock.updateAssets({
      assetIDs: [a1.id],
      folderAssignment: { folder: f1.id },
    });
    await mock.updateAssets({
      assetIDs: [a2.id],
      folderAssignment: f2 ? { folder: f2.id } : 'inbox',
    });
    await useLibraryStore.getState().refreshAll({ type: 'allItems' });

    const origFolder1 = useLibraryStore.getState().allAssets.find((a) => a.id === a1.id)?.folderID;
    const origFolder2 = useLibraryStore.getState().allAssets.find((a) => a.id === a2.id)?.folderID;
    expect(origFolder1).not.toBe(origFolder2);

    await moveAssetsToFolderWithUndo(
      [a1.id, a2.id],
      targetFolder.id,
      targetFolder.name,
      { type: 'allItems' },
    );

    expect(useLibraryStore.getState().allAssets.find((a) => a.id === a1.id)?.folderID).toBe(
      targetFolder.id,
    );
    expect(useLibraryStore.getState().allAssets.find((a) => a.id === a2.id)?.folderID).toBe(
      targetFolder.id,
    );

    const toastWithUndo = useCoordinatorStore
      .getState()
      .toasts.find((t) => t.actionLabel === '撤销');
    expect(toastWithUndo?.onAction).toBeDefined();

    await act(async () => {
      await toastWithUndo!.onAction!();
    });

    await waitFor(() => {
      expect(useLibraryStore.getState().allAssets.find((a) => a.id === a1.id)?.folderID).toBe(
        origFolder1,
      );
      expect(useLibraryStore.getState().allAssets.find((a) => a.id === a2.id)?.folderID).toBe(
        origFolder2,
      );
    });
  });
});
