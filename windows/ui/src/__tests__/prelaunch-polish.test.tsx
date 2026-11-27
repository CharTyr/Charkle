import { act, fireEvent, render, screen, waitFor } from '@testing-library/react';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { InMemoryMockTransport, setTransport } from '../api/transport';
import { QuickCaptureModal } from '../features/capture/QuickCaptureModal';
import { InspectorView } from '../features/inspector/InspectorView';
import { buildConnectorSvgPath, sanitizeExportFileName } from '../features/moodboard/editorial';
import { AudioStudioViewer } from '../features/quicklook/AudioStudioViewer';
import {
  CaptureShortcutsSettingsPane,
  DropShelfSettingsPane,
} from '../features/settings/SettingsPanesCaptureSystem';
import { TopEdgeDropShelf } from '../features/shelf/TopEdgeDropShelf';
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
  type BoardConnector,
  type FolderRecord,
  type MoodboardDocument,
} from '../types/domain';

function makeAsset(id: string, title: string, overrides: Partial<AssetRecord> = {}): AssetRecord {
  return {
    id,
    contentHash: `hash-${id}`,
    title,
    notes: '',
    mediaKind: 'image',
    mimeType: 'image/png',
    fileName: `${id}.png`,
    fileSizeBytes: 8192,
    pixelWidth: 1200,
    pixelHeight: 900,
    rating: 0,
    tags: [],
    suggestedTags: [],
    dominantColors: [
      { hex: '#3D5A80', l: 38, a: -4, b: -24, proportion: 0.6 },
      { hex: '#D95D48', l: 55, a: 45, b: 30, proportion: 0.4 },
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

function makeBoard(id: string, title: string): MoodboardDocument {
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
    viewportCenter: { x: 400, y: 300 },
    viewportZoom: 1,
    createdAt: 760000000,
    updatedAt: 760000000,
    updatedHLC: 1,
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
    agentState: null,
    diagnostics: null,
    statusMessage: null,
    errorMessage: null,
  });
}

function parseArrowHeadVertices(path: string): Array<{ x: number; y: number }> {
  const nums = path.match(/-?\d+(?:\.\d+)?/g)?.map(Number) ?? [];
  const pts: Array<{ x: number; y: number }> = [];
  for (let i = 0; i + 1 < nums.length; i += 2) {
    pts.push({ x: nums[i], y: nums[i + 1] });
  }
  return pts;
}

describe('Pre-Launch Comprehensive Bug Hunt & Polish Regressions (#148-#154)', () => {
  beforeEach(() => {
    resetStores();
    setTransport(new InMemoryMockTransport());
  });

  // =========================================================================
  // 1. libraryStore — Xiaohongshu extraction attribution & circular moveFolder
  // =========================================================================
  describe('libraryStore', () => {
    it('extractSocialAttachment for xiaohongshu labels 小红书 / 笔记 (never Bluesky) and hides 24-hex userId', async () => {
      const transport = new InMemoryMockTransport();
      const extractSpy = vi.spyOn(transport, 'extractLinkMediaAttachment');
      const updateSpy = vi.spyOn(transport, 'updateAssets');
      setTransport(transport);

      const hexUserId = 'aa11bb22cc33dd44ee55ff66';
      const xhsPost = makeAsset('XHS-EXTRACT-1', '极简建筑光影笔记', {
        mediaKind: 'webBookmark',
        richMetadata: {
          socialPost: {
            platform: 'xiaohongshu',
            authorName: '空间造物',
            authorHandle: hexUserId,
            articleTitle: '极简建筑光影笔记',
            bodyText: '混凝土与自然天光的层次。',
            originalURL: 'https://www.xiaohongshu.com/explore/65a1b2c3d4e5f60718293a4b',
            mediaURLs: ['https://sns-webpic-qc.xhscdn.com/photo-1.webp'],
            mediaThumbnailURLs: ['https://sns-webpic-qc.xhscdn.com/thumb-1.webp'],
            attachments: [
              {
                id: 'xhs-att-1',
                kind: 'photo',
                url: 'https://sns-webpic-qc.xhscdn.com/photo-1.webp',
                thumbnailURL: 'https://sns-webpic-qc.xhscdn.com/thumb-1.webp',
              },
            ],
            hasVideo: false,
          },
        },
      });

      const created = await useLibraryStore.getState().extractSocialAttachment(
        xhsPost,
        xhsPost.richMetadata!.socialPost!.attachments[0],
        0,
        { type: 'allItems' },
      );

      expect(created).not.toBeNull();
      expect(extractSpy).toHaveBeenCalledTimes(1);
      expect(updateSpy).toHaveBeenCalledTimes(1);
      const patchArg = updateSpy.mock.calls[0][0];
      expect(patchArg.title).toBe('空间造物 图片 #1');
      expect(patchArg.title).not.toContain(hexUserId);
      expect(patchArg.notes).toContain('来源笔记：空间造物 · 小红书');
      expect(patchArg.notes).toContain('原笔记链接：https://www.xiaohongshu.com/explore/');
      expect(patchArg.notes).not.toContain('Bluesky');
      expect(patchArg.notes).not.toContain('推文');
      expect(patchArg.notes).not.toContain(hexUserId);

      expect(updateSpy).toHaveBeenCalledWith(
        expect.objectContaining({
          assetIDs: [created!.id],
          addTags: ['小红书'],
        }),
      );
    });

    it('moveFolder blocks self and descendant circular moves without invoking transport', async () => {
      const transport = new InMemoryMockTransport();
      const moveSpy = vi.spyOn(transport, 'moveFolder');
      setTransport(transport);

      const parent: FolderRecord = {
        id: 'F-ROOT',
        name: 'Root',
        parentID: null,
        sortOrder: 0,
        colorHex: null,
        customSymbol: null,
        assetCount: 0,
        createdAt: 760000000,
        updatedAt: 760000000,
      };
      const child: FolderRecord = {
        id: 'F-CHILD',
        name: 'Child',
        parentID: 'F-ROOT',
        sortOrder: 0,
        colorHex: null,
        customSymbol: null,
        assetCount: 0,
        createdAt: 760000000,
        updatedAt: 760000000,
      };
      const grandChild: FolderRecord = {
        id: 'F-GRANDCHILD',
        name: 'GrandChild',
        parentID: 'F-CHILD',
        sortOrder: 0,
        colorHex: null,
        customSymbol: null,
        assetCount: 0,
        createdAt: 760000000,
        updatedAt: 760000000,
      };

      useLibraryStore.setState({ folders: [parent, child, grandChild] });

      // Moving a folder into itself or any descendant must be blocked cleanly
      await useLibraryStore.getState().moveFolder('F-ROOT', 'F-ROOT');
      await useLibraryStore.getState().moveFolder('F-ROOT', 'F-CHILD');
      await useLibraryStore.getState().moveFolder('F-ROOT', 'F-GRANDCHILD');

      expect(moveSpy).not.toHaveBeenCalled();
    });
  });

  // =========================================================================
  // 2. InspectorView — Rapid A->B notes flush & multi-select shared tag removal
  // =========================================================================
  describe('InspectorView', () => {
    it('flushes Asset A edited notes to Asset A on rapid A->B switch without clobbering Asset B', async () => {
      const transport = new InMemoryMockTransport();
      await transport.seedSampleLibraryIfEmpty();
      const seeded = await transport.fetchAssets(createDefaultFilterCriteria());
      const [rawA, rawB] = seeded;
      await transport.updateAssets({ assetIDs: [rawA.id], notes: 'Initial A note' });
      await transport.updateAssets({ assetIDs: [rawB.id], notes: 'Original B note' });
      const fresh = await transport.fetchAssets(createDefaultFilterCriteria());
      const assetA = fresh.find((a) => a.id === rawA.id)!;
      const assetB = fresh.find((a) => a.id === rawB.id)!;

      const updateSpy = vi.spyOn(transport, 'updateAssets');
      setTransport(transport);

      useLibraryStore.setState({
        assets: fresh,
        allAssets: fresh,
      });
      useCoordinatorStore.setState({
        destination: { type: 'allItems' },
        selectedAssetIds: [assetA.id],
        lastSelectedAssetId: assetA.id,
        inspectorOpen: true,
        inspectorTab: 'info',
      });

      render(<InspectorView />);

      const notesBox = screen.getByRole('textbox', { name: '素材备注' }) as HTMLTextAreaElement;
      expect(notesBox.value).toBe('Initial A note');

      // Type new notes for Asset A (debounced), then immediately switch selection to Asset B
      fireEvent.change(notesBox, { target: { value: 'Edited A note before switch' } });

      act(() => {
        useCoordinatorStore.getState().setSelection([assetB.id], assetB.id);
      });

      await waitFor(() => {
        expect(updateSpy).toHaveBeenCalledWith(
          expect.objectContaining({
            assetIDs: [assetA.id],
            notes: 'Edited A note before switch',
          }),
        );
      });

      // Asset B's textarea shows Asset B's original note and no write targeted Asset B
      expect((screen.getByRole('textbox', { name: '素材备注' }) as HTMLTextAreaElement).value).toBe(
        'Original B note',
      );
      const callsTouchingB = updateSpy.mock.calls.filter(([patch]) =>
        patch.assetIDs.includes(assetB.id),
      );
      expect(callsTouchingB).toHaveLength(0);
    });

    it('multi-select displays shared tags and removes a tag across ALL selected asset IDs', async () => {
      const transport = new InMemoryMockTransport();
      const updateSpy = vi.spyOn(transport, 'updateAssets');
      setTransport(transport);

      const asset1 = makeAsset('MS-1', 'Card One', { tags: ['极简', '建筑'] });
      const asset2 = makeAsset('MS-2', 'Card Two', { tags: ['极简', '光影'] });
      const asset3 = makeAsset('MS-3', 'Card Three', { tags: ['极简'] });

      useLibraryStore.setState({
        assets: [asset1, asset2, asset3],
        allAssets: [asset1, asset2, asset3],
      });
      useCoordinatorStore.setState({
        destination: { type: 'allItems' },
        selectedAssetIds: [asset1.id, asset2.id, asset3.id],
        lastSelectedAssetId: asset3.id,
        inspectorOpen: true,
      });

      render(<InspectorView />);

      const removeSharedBtn = screen.getByRole('button', { name: '从所选移除标签 极简' });
      fireEvent.click(removeSharedBtn);

      await waitFor(() => {
        expect(updateSpy).toHaveBeenCalledWith({
          assetIDs: [asset1.id, asset2.id, asset3.id],
          removeTags: ['极简'],
        });
      });
    });
  });

  // =========================================================================
  // 3. AudioStudioViewer — NaN/Infinity duration & unmount pause/src release
  // =========================================================================
  describe('AudioStudioViewer', () => {
    it('handles NaN and Infinity durations cleanly and pauses + strips src on unmount', () => {
      const pauseSpy = vi
        .spyOn(window.HTMLMediaElement.prototype, 'pause')
        .mockImplementation(() => {});
      const loadSpy = vi
        .spyOn(window.HTMLMediaElement.prototype, 'load')
        .mockImplementation(() => {});

      const audioNaN = makeAsset('AUD-NAN', 'Ambient Loop', {
        mediaKind: 'audio',
        mimeType: 'audio/mpeg',
        fileName: 'ambient.mp3',
        durationSeconds: Number.NaN,
      });

      const { container, rerender, unmount } = render(<AudioStudioViewer asset={audioNaN} />);

      expect(screen.getByText('0:00 / 0:00')).toBeInTheDocument();
      expect(container.textContent).not.toContain('NaN');
      expect(screen.getByRole('slider', { name: '音频进度波形' })).toHaveAttribute(
        'aria-valuemax',
        '0',
      );

      // Simulate Infinity duration via prop & loadedmetadata
      const audioInf = makeAsset('AUD-INF', 'Live Stream Clip', {
        mediaKind: 'audio',
        mimeType: 'audio/mpeg',
        fileName: 'stream.mp3',
        durationSeconds: Number.POSITIVE_INFINITY,
      });
      rerender(<AudioStudioViewer asset={audioInf} />);

      const audioEl = container.querySelector('audio') as HTMLAudioElement;
      expect(audioEl).not.toBeNull();
      expect(audioEl.getAttribute('src')).toBeTruthy();
      expect(screen.getByText('0:00 / 0:00')).toBeInTheDocument();
      expect(container.textContent).not.toContain('Infinity');

      pauseSpy.mockClear();
      unmount();

      expect(pauseSpy).toHaveBeenCalled();
      expect(audioEl.getAttribute('src')).toBeNull();
      expect(loadSpy).toHaveBeenCalled();

      pauseSpy.mockRestore();
      loadSpy.mockRestore();
    });
  });

  // =========================================================================
  // 4. Moodboard — sanitizeExportFileName, vertical elbow arrowhead & openBoard race
  // =========================================================================
  describe('Moodboard Editorial & Store Guards', () => {
    it('sanitizeExportFileName strips Windows illegal chars, trailing dots/spaces, and escapes reserved names', () => {
      expect(sanitizeExportFileName('Spring <2026>: "Look/Book" \\ | ? *')).toBe(
        'Spring 2026 Look Book',
      );
      expect(sanitizeExportFileName('Editorial Draft...   ')).toBe('Editorial Draft');
      expect(sanitizeExportFileName('CON')).toBe('CON_board');
      expect(sanitizeExportFileName('nul')).toBe('nul_board');
      expect(sanitizeExportFileName('LPT1')).toBe('LPT1_board');
      expect(sanitizeExportFileName('   ...   ', '默认情绪板')).toBe('默认情绪板');
    });

    it('buildConnectorSvgPath vertical elbow connector generates downward/upward vertical arrowheads (never rightward 0°)', () => {
      const topRect = { x: 100, y: 40, width: 200, height: 120 };
      const bottomRect = { x: 100, y: 340, width: 200, height: 120 };

      const downConn: BoardConnector = {
        id: 'CONN-DOWN',
        fromNodeID: 'A',
        toNodeID: 'B',
        fromAnchor: 'bottom',
        toAnchor: 'top',
        style: 'elbow',
        colorHex: '#2A60E0',
        dashed: false,
        label: null,
        updatedAt: 760000000,
      };
      const downGeom = buildConnectorSvgPath(downConn, topRect, bottomRect);
      const downPts = parseArrowHeadVertices(downGeom.arrowHeadPath);
      expect(downPts).toHaveLength(3);
      const [dWing1, dTip, dWing2] = downPts;
      // Downward tip points +Y: both wings sit ABOVE tip (y < tip.y) and symmetric in X around tip.x
      expect(dTip.x).toBeCloseTo(downGeom.end.x, 3);
      expect(dTip.y).toBeCloseTo(downGeom.end.y, 3);
      expect(dWing1.y).toBeLessThan(dTip.y - 5);
      expect(dWing2.y).toBeLessThan(dTip.y - 5);
      expect(dWing1.y).toBeCloseTo(dWing2.y, 3);
      expect((dWing1.x + dWing2.x) * 0.5).toBeCloseTo(dTip.x, 3);

      const upConn: BoardConnector = {
        ...downConn,
        id: 'CONN-UP',
        fromAnchor: 'top',
        toAnchor: 'bottom',
      };
      const upGeom = buildConnectorSvgPath(upConn, bottomRect, topRect);
      const upPts = parseArrowHeadVertices(upGeom.arrowHeadPath);
      expect(upPts).toHaveLength(3);
      const [uWing1, uTip, uWing2] = upPts;
      // Upward tip points -Y: both wings sit BELOW tip (y > tip.y) and symmetric in X around tip.x
      expect(uWing1.y).toBeGreaterThan(uTip.y + 5);
      expect(uWing2.y).toBeGreaterThan(uTip.y + 5);
      expect(uWing1.y).toBeCloseTo(uWing2.y, 3);
      expect((uWing1.x + uWing2.x) * 0.5).toBeCloseTo(uTip.x, 3);
    });

    it('moodboardStore.openBoard ignores slower out-of-order board resolutions', async () => {
      const transport = new InMemoryMockTransport();
      const boardSlow = makeBoard('BOARD-SLOW', 'Slow Board');
      const boardFast = makeBoard('BOARD-FAST', 'Fast Board');

      let resolveSlow: ((doc: MoodboardDocument | null) => void) | undefined;
      let resolveFast: ((doc: MoodboardDocument | null) => void) | undefined;

      vi.spyOn(transport, 'fetchBoard').mockImplementation((id: string) => {
        if (id === boardSlow.id) {
          return new Promise<MoodboardDocument | null>((resolve) => {
            resolveSlow = resolve;
          });
        }
        return new Promise<MoodboardDocument | null>((resolve) => {
          resolveFast = resolve;
        });
      });
      setTransport(transport);

      const pSlow = useMoodboardStore.getState().openBoard(boardSlow.id);
      // Let pSlow reach fetchBoard(boardSlow.id) before starting pFast
      await waitFor(() => {
        expect(resolveSlow).toBeDefined();
      });

      const pFast = useMoodboardStore.getState().openBoard(boardFast.id);
      await waitFor(() => {
        expect(resolveFast).toBeDefined();
      });

      // Fast board resolves first
      resolveFast!(boardFast);
      await pFast;
      expect(useMoodboardStore.getState().activeBoard?.id).toBe(boardFast.id);

      // Slow board resolves later -> MUST be ignored so activeBoard stays boardFast
      resolveSlow!(boardSlow);
      await pSlow;
      expect(useMoodboardStore.getState().activeBoard?.id).toBe(boardFast.id);
      expect(useCoordinatorStore.getState().activeMoodboardId).toBe(boardFast.id);
    });
  });

  // =========================================================================
  // 5. QuickCaptureModal, CaptureShortcutsSettingsPane & syncAIStore
  // =========================================================================
  describe('QuickCaptureModal, Hotkey Validation & syncAIStore Resilience', () => {
    it('QuickCaptureModal extracts Xiaohongshu share-copy URL on URL tab and validates invalid HEX on Swatch tab', async () => {
      const transport = new InMemoryMockTransport();
      const ingestUrlSpy = vi.spyOn(transport, 'ingestUrl');
      setTransport(transport);

      useCoordinatorStore.setState({ captureOpen: true });
      render(<QuickCaptureModal />);

      // Switch to URL tab and paste full Xiaohongshu share-copy text
      fireEvent.click(screen.getByRole('radio', { name: '网页链接' }));
      const urlInput = screen.getByPlaceholderText(/https:\/\/\.\.\. 或直接粘贴/);
      fireEvent.change(urlInput, {
        target: {
          value:
            '98 空间观察室发布了一篇小红书笔记，快来看吧！😆 http://xhslink.com/a/abc12345 复制本条信息，打开【小红书】App查看精彩内容！',
        },
      });

      expect(screen.getByText('已识别链接：http://xhslink.com/a/abc12345')).toBeInTheDocument();
      const saveBtn = screen.getByRole('button', { name: '保存到素材库' });
      expect(saveBtn).not.toBeDisabled();
      fireEvent.click(saveBtn);

      await waitFor(() => {
        expect(ingestUrlSpy).toHaveBeenCalledWith(
          'http://xhslink.com/a/abc12345',
          null,
          null,
          null,
          null,
        );
      });

      // Reopen modal, switch to Swatch tab, enter invalid HEX -> inline error + disabled submit
      act(() => {
        useCoordinatorStore.getState().setCaptureOpen(true);
      });
      fireEvent.click(await screen.findByRole('radio', { name: '色卡' }));
      const hexInput = screen.getByPlaceholderText('#2A60E0');
      fireEvent.change(hexInput, { target: { value: '#GGGGGG' } });

      expect(
        screen.getByText('请输入 3 位或 6 位有效 HEX 色值（例如 #2A60E0）'),
      ).toBeInTheDocument();
      expect(screen.getByRole('button', { name: '保存到素材库' })).toBeDisabled();
    });

    it('CaptureShortcutsSettingsPane blocks duplicate and empty global hotkeys with inline warning and disabled save CTA', async () => {
      const transport = new InMemoryMockTransport();
      const updateHotkeysSpy = vi.spyOn(transport, 'updateHotkeys');
      setTransport(transport);

      render(<CaptureShortcutsSettingsPane />);

      const captureInput = (await screen.findByDisplayValue('Alt+Shift+A')) as HTMLInputElement;
      const shelfInput = screen.getByDisplayValue('Alt+Shift+S') as HTMLInputElement;
      const saveBtn = screen.getByRole('button', { name: '保存快捷键' });
      expect(saveBtn).not.toBeDisabled();

      // Duplicate hotkey (case/whitespace insensitive)
      fireEvent.change(shelfInput, { target: { value: ' alt + shift + a ' } });
      expect(screen.getByText('三个全局快捷键不能重复，请修改后再保存')).toBeInTheDocument();
      expect(saveBtn).toBeDisabled();

      // Empty hotkey
      fireEvent.change(captureInput, { target: { value: '   ' } });
      expect(
        screen.getByText('全局快捷键不能为空，请填写或点击「恢复默认」'),
      ).toBeInTheDocument();
      expect(saveBtn).toBeDisabled();
      expect(updateHotkeysSpy).not.toHaveBeenCalled();
    });

    it('syncAIStore.refreshSettingsData degrades gracefully via Promise.allSettled under partial IPC failures', async () => {
      const transport = new InMemoryMockTransport();
      vi.spyOn(transport, 'syncStatus').mockRejectedValueOnce(new Error('sync status offline'));
      vi.spyOn(transport, 'getSystemDiagnostics').mockRejectedValueOnce(
        new Error('diagnostics unavailable'),
      );
      setTransport(transport);

      await expect(useSyncAIStore.getState().refreshSettingsData()).resolves.toBeUndefined();

      const state = useSyncAIStore.getState();
      // Fulfilled calls still hydrate cleanly while rejected ones stay safely untouched
      expect(state.syncConfig).not.toBeNull();
      expect(state.cacheStats).not.toBeNull();
      expect(state.aiState).not.toBeNull();
      expect(state.agentState).not.toBeNull();
      expect(state.syncStatus).toBeNull();
      expect(state.diagnostics).toBeNull();
    });
  });

  // =========================================================================
  // 6. Drop Shelf Screen-Edge Docking (#162, #164, #165)
  // =========================================================================
  describe('Drop Shelf Screen-Edge Docking (Top / Left / Right)', () => {
    it('DropShelfSettingsPane renders 屏幕顶部/左侧/右侧, persists dockEdge via saveShelfSettings, and updates hover-trigger copy dynamically', async () => {
      const transport = new InMemoryMockTransport();
      const saveSpy = vi.spyOn(transport, 'saveShelfSettings');
      setTransport(transport);

      render(<DropShelfSettingsPane />);

      const topOpt = await screen.findByRole('radio', { name: '屏幕顶部' });
      const leftOpt = screen.getByRole('radio', { name: '屏幕左侧' });
      const rightOpt = screen.getByRole('radio', { name: '屏幕右侧' });
      expect(topOpt).toHaveAttribute('aria-checked', 'true');
      expect(screen.getByText('悬停顶部中央自动展开')).toBeInTheDocument();

      // Switch to Left edge
      fireEvent.click(leftOpt);
      await waitFor(() => {
        expect(saveSpy).toHaveBeenCalledWith(expect.objectContaining({ dockEdge: 'left' }));
      });
      expect(screen.getByText('悬停左侧中央自动展开')).toBeInTheDocument();
      expect(screen.getByText(/鼠标移至屏幕左侧中央时轻滑唤出浮窗/)).toBeInTheDocument();

      // Switch to Right edge
      fireEvent.click(rightOpt);
      await waitFor(() => {
        expect(saveSpy).toHaveBeenCalledWith(expect.objectContaining({ dockEdge: 'right' }));
      });
      expect(screen.getByText('悬停右侧中央自动展开')).toBeInTheDocument();
      expect(screen.getByText(/鼠标移至屏幕右侧中央时轻滑唤出浮窗/)).toBeInTheDocument();
    });

    it('TopEdgeDropShelf renders left/right docked edges with edge-flush hit-rects and expands sideways to waterfall on clicking 全部', async () => {
      const transport = new InMemoryMockTransport();
      await transport.seedSampleLibraryIfEmpty();
      const hitRectSpy = vi.spyOn(transport, 'setShelfHitRect');
      setTransport(transport);

      // Left-docked shelf: x === 0 and expands sideways to waterfall
      const leftView = render(<TopEdgeDropShelf initialExpanded initialDockEdge="left" />);
      const leftShelf = await screen.findByTestId('top-edge-drop-shelf');
      expect(leftShelf).toHaveAttribute('data-dock-edge', 'left');
      expect(leftShelf).toHaveAttribute('data-mode', 'compact');

      await waitFor(() => {
        const nonNullCalls = hitRectSpy.mock.calls.filter(([rect]) => rect !== null);
        expect(nonNullCalls.length).toBeGreaterThan(0);
        const latestRect = nonNullCalls[nonNullCalls.length - 1][0]!;
        expect(latestRect.x).toBe(0);
        expect(latestRect.width).toBeGreaterThan(200);
      });

      const expandLeftBtn = await screen.findByRole('button', { name: '展开为全瀑布流抽屉' });
      expect(expandLeftBtn.textContent).toContain('全部');
      fireEvent.click(expandLeftBtn);
      await waitFor(() => {
        expect(screen.getByTestId('top-edge-drop-shelf')).toHaveAttribute('data-mode', 'waterfall');
      });
      leftView.unmount();

      // Right-docked shelf: right-flush x > 0 and expands sideways to waterfall
      hitRectSpy.mockClear();
      const rightView = render(<TopEdgeDropShelf initialExpanded initialDockEdge="right" />);
      const rightShelf = await screen.findByTestId('top-edge-drop-shelf');
      expect(rightShelf).toHaveAttribute('data-dock-edge', 'right');
      expect(rightShelf).toHaveAttribute('data-mode', 'compact');

      await waitFor(() => {
        const nonNullCalls = hitRectSpy.mock.calls.filter(([rect]) => rect !== null);
        expect(nonNullCalls.length).toBeGreaterThan(0);
        const latestRect = nonNullCalls[nonNullCalls.length - 1][0]!;
        expect(latestRect.x).toBeGreaterThan(0);
        expect(latestRect.width).toBeGreaterThan(200);
      });

      const expandRightBtn = await screen.findByRole('button', { name: '展开为全瀑布流抽屉' });
      expect(expandRightBtn.textContent).toContain('全部');
      fireEvent.click(expandRightBtn);
      await waitFor(() => {
        expect(screen.getByTestId('top-edge-drop-shelf')).toHaveAttribute('data-mode', 'waterfall');
      });
      rightView.unmount();
    });
  });
});
