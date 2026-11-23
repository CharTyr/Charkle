import { fireEvent, render, screen, waitFor, within } from '@testing-library/react';
import { beforeEach, describe, expect, it } from 'vitest';
import { App } from '../App';
import { InMemoryMockTransport, setTransport } from '../api/transport';
import { VerticalMasonryView } from '../features/gallery/VerticalMasonryView';
import {
  useCoordinatorStore,
  useLibraryStore,
  useMoodboardStore,
  useSyncAIStore,
} from '../stores';
import { createDefaultFilterCriteria, type AssetRecord } from '../types/domain';

function resetStores() {
  useCoordinatorStore.setState({
    themeMode: 'light',
    surfaceState: null,
    sidebarOpen: true,
    inspectorOpen: true,
    layoutMode: 'verticalMasonry',
    cardScale: 236,
    destination: { type: 'allItems' },
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
  });
  useSyncAIStore.setState({
    syncConfig: null,
    syncStatus: null,
    cacheStats: null,
    syncing: false,
  });
}

describe('Charkle Windows M2 Gallery, Navigation, Inspector & Quick Look', () => {
  beforeEach(() => {
    localStorage.clear();
    setTransport(new InMemoryMockTransport(true));
    resetStores();
  });

  it('bootstraps seeded library, renders nested folders, switches 3 layouts, and opens Inspector EXIF & AI cards', async () => {
    render(<App />);

    // Seeded items and nested folders render
    await waitFor(() => {
      expect(screen.getByText('UI Inspiration')).toBeInTheDocument();
      expect(screen.getByText('高分精选')).toBeInTheDocument();
      expect(screen.getByText('暖调建筑海报参考')).toBeInTheDocument();
    });

    // Click asset 1 to bind Inspector -> verify Camera EXIF & AI Generation cards
    const card = document.querySelector('[data-asset-id="20000000-0000-4000-8000-000000000001"]');
    expect(card).not.toBeNull();
    fireEvent.click(card!);

    await waitFor(() => {
      expect(screen.getByText('Fujifilm X-T5')).toBeInTheDocument();
      expect(screen.getByText(/warm limestone courtyard/)).toBeInTheDocument();
    });

    // Switch through all 3 gallery layout modes via keyboard shortcuts
    fireEvent.keyDown(window, { key: '2', ctrlKey: true });
    expect(screen.getByTestId('gallery-justified-scroll')).toBeInTheDocument();

    fireEvent.keyDown(window, { key: '3', ctrlKey: true });
    expect(screen.getByTestId('gallery-filmstrip-view')).toBeInTheDocument();

    fireEvent.keyDown(window, { key: '1', ctrlKey: true });
    expect(screen.getByTestId('gallery-masonry-scroll')).toBeInTheDocument();
  });

  it('virtualizes 10,000 assets in VerticalMasonryView so only the visible window is in the DOM', () => {
    const hugeAssets: AssetRecord[] = Array.from({ length: 10_000 }, (_, i) => ({
      id: `virt-${i}`,
      contentHash: `h-${i}`,
      mediaKind: 'image',
      mimeType: 'image/png',
      title: `Item ${i}`,
      fileName: `item-${i}.png`,
      notes: '',
      tags: [],
      suggestedTags: [],
      rating: 0,
      pixelWidth: 800,
      pixelHeight: 600,
      fileSizeBytes: 512,
      dominantColors: [],
      waveformPeaks: [],
      pinnedOffline: false,
      isLocalOriginalCached: true,
      isTrashed: false,
      createdAt: 0,
      updatedAt: 0,
      updatedHLC: i,
    }));

    const { container } = render(<VerticalMasonryView assets={hugeAssets} cardScale={240} />);
    const renderedCards = container.querySelectorAll('[data-asset-id]');
    expect(renderedCards.length).toBeGreaterThan(0);
    expect(renderedCards.length).toBeLessThan(120);
  });

  it('supports Inbox 1-9 rapid triage shortcut and Ctrl+J instant Jump Anywhere', async () => {
    render(<App />);

    await waitFor(() => {
      expect(screen.getByText('收件箱')).toBeInTheDocument();
    });

    // Navigate to Inbox (contains asset 1)
    fireEvent.click(screen.getByText('收件箱'));
    await waitFor(() => {
      expect(screen.getByTestId('inbox-triage-bar')).toBeInTheDocument();
    });

    // Press key '1' to move top Inbox asset into top folder ('UI Inspiration')
    fireEvent.keyDown(window, { key: '1' });

    await waitFor(() => {
      expect(screen.getByText('收件箱已清空')).toBeInTheDocument();
      expect(screen.getByText(/已分拣 1 项到「UI Inspiration」/)).toBeInTheDocument();
    });

    // Trigger Ctrl+J 0ms Jump Anywhere
    fireEvent.keyDown(window, { key: 'j', ctrlKey: true });
    expect(screen.getByTestId('jump-anywhere-modal')).toBeInTheDocument();

    const jumpInput = screen.getByLabelText('快速跳转搜索框');
    fireEvent.change(jumpInput, { target: { value: 'Typography' } });
    await waitFor(() => {
      expect(screen.getByText('Typography')).toBeInTheDocument();
    });
    fireEvent.keyDown(jumpInput, { key: 'Enter' });

    await waitFor(() => {
      expect(screen.queryByTestId('jump-anywhere-modal')).not.toBeInTheDocument();
      expect(useCoordinatorStore.getState().destination).toEqual({
        type: 'folder',
        id: '10000000-0000-4000-8000-000000000002',
      });
    });
  });

  it('opens Space Quick Look with Long-Strip scroll mode, GitHub Repo viewer, and Markdown viewer', async () => {
    render(<App />);

    await waitFor(() => {
      expect(
        document.querySelector('[data-asset-id="20000000-0000-4000-8000-000000000004"]'),
      ).not.toBeNull();
    });

    // 1. Long-strip image (800x2800) -> enters long-strip vertical scroll viewer automatically
    const longStripCard = document.querySelector(
      '[data-asset-id="20000000-0000-4000-8000-000000000004"]',
    )!;
    fireEvent.click(longStripCard);
    fireEvent.keyDown(window, { code: 'Space', key: ' ' });

    await waitFor(() => {
      expect(screen.getByTestId('quicklook-overlay')).toBeInTheDocument();
      expect(screen.getByTestId('quicklook-long-strip-scroll')).toBeInTheDocument();
    });

    // Close Quick Look on Escape
    fireEvent.keyDown(window, { key: 'Escape' });
    await waitFor(() => {
      expect(screen.queryByTestId('quicklook-overlay')).not.toBeInTheDocument();
    });

    // 2. GitHub repo bookmark -> opens GitHubRepoViewer with rendered README
    const ghCard = document.querySelector(
      '[data-asset-id="20000000-0000-4000-8000-000000000002"]',
    )!;
    fireEvent.doubleClick(ghCard);
    await waitFor(() => {
      expect(screen.getByTestId('quicklook-github-viewer')).toBeInTheDocument();
      expect(screen.getByText(/Build native Windows desktop applications/)).toBeInTheDocument();
    });
    fireEvent.keyDown(window, { key: 'Escape' });

    // 3. Markdown document -> opens DocumentMarkdownViewer
    const mdCard = document.querySelector(
      '[data-asset-id="20000000-0000-4000-8000-000000000003"]',
    )!;
    fireEvent.doubleClick(mdCard);
    await waitFor(() => {
      const docViewer = screen.getByTestId('quicklook-document-viewer');
      expect(docViewer).toBeInTheDocument();
      expect(within(docViewer).getByText(/90–95% 中性画布/)).toBeInTheDocument();
    });
  });
});
