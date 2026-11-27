import { act, cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import { App } from '../App';
import { InMemoryMockTransport, setTransport } from '../api/transport';
import { SmartDeduplicationModal } from '../features/dedup/SmartDeduplicationModal';
import { JumpAnywhereModal } from '../features/jump/JumpAnywhereModal';
import { SocialPostViewer } from '../features/quicklook/SocialPostViewer';
import { LibrarySettingsPane } from '../features/settings/SettingsPanesFoundation';
import { SidebarView } from '../features/sidebar/SidebarView';
import { useCoordinatorStore, useLibraryStore, useMoodboardStore, useSyncAIStore } from '../stores';
import {
  resolveSocialMediaUrl,
  type AssetRecord,
  type DeduplicationScanReport,
} from '../types/domain';

function makeAsset(overrides: Partial<AssetRecord> & { id: string; title: string }): AssetRecord {
  return {
    id: overrides.id,
    title: overrides.title,
    fileName: overrides.fileName ?? `${overrides.title}.png`,
    mediaKind: overrides.mediaKind ?? 'image',
    mimeType: overrides.mimeType ?? 'image/png',
    fileSizeBytes: overrides.fileSizeBytes ?? 1_200_000,
    pixelWidth: overrides.pixelWidth ?? 1600,
    pixelHeight: overrides.pixelHeight ?? 1200,
    durationSeconds: overrides.durationSeconds ?? null,
    waveformPeaks: overrides.waveformPeaks ?? [],
    contentHash: overrides.contentHash ?? 'abc123',
    tags: overrides.tags ?? [],
    suggestedTags: [],
    rating: overrides.rating ?? 0,
    notes: overrides.notes ?? '',
    aiDescription: null,
    ocrText: null,
    sourceURL: overrides.sourceURL ?? null,
    sourceDomain: overrides.sourceDomain ?? null,
    folderID: overrides.folderID ?? null,
    dominantColors: [],
    richMetadata: overrides.richMetadata ?? null,
    driveFileID: null,
    isLocalOriginalCached: true,
    pinnedOffline: false,
    isTrashed: false,
    createdAt: 0,
    updatedAt: 0,
    lastOpenedAt: null,
    updatedHLC: 0,
  };
}

describe('Charkle v1.3.0 Parity: Pixiv/Instagram, Smart Dedup & Material Packages', () => {
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
      onboardingOpen: false,
      onboardingDone: true,
      moodboardGeneratorOpen: false,
      dedupOpen: false,
      dedupInitialScope: { type: 'allActive' },
      sidebarCollapsed: false,
      sidebarOpen: true,
      toasts: [],
    });
    useLibraryStore.setState({
      allAssets: [],
      assets: [],
      folders: [],
      smartFolders: [],
      tagCounts: [],
      inboxCount: 0,
      cutAssetIds: [],
    });
    useMoodboardStore.setState({ boards: [], activeBoard: null });
    useSyncAIStore.setState({ syncConfig: null, syncStatus: null });
  });

  afterEach(() => {
    cleanup();
  });

  it('routes Pixiv i.pximg.net through /proxy-social in Tauri and renders Pixiv & Instagram viewers', () => {
    const proxied = resolveSocialMediaUrl(
      'https://i.pximg.net/img-original/img/2026/11/20/12556677_p0.png',
      true,
    );
    expect(proxied).toBe(
      'http://charkle-media.localhost/proxy-social?url=https%3A%2F%2Fi.pximg.net%2Fimg-original%2Fimg%2F2026%2F11%2F20%2F12556677_p0.png',
    );

    const pixivAsset = makeAsset({
      id: 'PX-1',
      title: '星夜水彩',
      mediaKind: 'webBookmark',
      richMetadata: {
        socialPost: {
          platform: 'pixiv',
          authorName: '青岚',
          authorHandle: '543210',
          bodyText: '水彩插画练习',
          mediaURLs: ['https://i.pximg.net/img-original/img/12556677_p0.png'],
          mediaThumbnailURLs: ['https://i.pximg.net/img-original/img/12556677_p0.png'],
          attachments: [
            {
              id: 'p0',
              kind: 'photo',
              url: 'https://i.pximg.net/img-original/img/12556677_p0.png',
            },
          ],
          hasVideo: false,
          originalURL: 'https://www.pixiv.net/artworks/12556677',
        },
      },
    });

    const { rerender } = render(<SocialPostViewer asset={pixivAsset} />);
    expect(screen.getByText('Pixiv')).toBeInTheDocument();
    expect(screen.getByText('在 Pixiv 打开')).toBeInTheDocument();

    const igAsset = makeAsset({
      id: 'IG-1',
      title: 'Studio Shoot',
      mediaKind: 'webBookmark',
      richMetadata: {
        socialPost: {
          platform: 'instagram',
          authorName: 'Studio IG',
          authorHandle: 'studio_ig',
          bodyText: 'Editorial lookbook',
          mediaURLs: ['https://scontent.cdninstagram.com/v/photo.jpg'],
          mediaThumbnailURLs: ['https://scontent.cdninstagram.com/v/photo.jpg'],
          attachments: [
            {
              id: 'ig0',
              kind: 'photo',
              url: 'https://scontent.cdninstagram.com/v/photo.jpg',
            },
          ],
          hasVideo: false,
          originalURL: 'https://www.instagram.com/p/C9AbCdEfGhI/',
        },
      },
    });
    rerender(<SocialPostViewer asset={igAsset} />);
    expect(screen.getByText('Instagram')).toBeInTheDocument();
    expect(screen.getByText('在 Instagram 打开')).toBeInTheDocument();
  });

  it('scans duplicates, overrides keeper, previews in Quick Look without closing, and cleans up', async () => {
    const hi = makeAsset({
      id: 'ASSET-HI',
      title: 'Poster Master',
      fileName: 'poster_master.png',
      pixelWidth: 2400,
      pixelHeight: 1800,
      fileSizeBytes: 3_400_000,
    });
    const lo = makeAsset({
      id: 'ASSET-LO',
      title: 'Poster Compressed',
      fileName: 'poster_compressed.jpg',
      pixelWidth: 1200,
      pixelHeight: 900,
      fileSizeBytes: 620_000,
    });
    const docA = makeAsset({
      id: 'DOC-A',
      title: 'Spec Notes A',
      fileName: 'spec_a.md',
      mediaKind: 'document',
      fileSizeBytes: 14_000,
    });
    const docB = makeAsset({
      id: 'DOC-B',
      title: 'Spec Notes B',
      fileName: 'spec_b.md',
      mediaKind: 'document',
      fileSizeBytes: 12_000,
    });

    const report: DeduplicationScanReport = {
      scannedAssetCount: 4,
      skippedNonVisualCount: 0,
      totalDuplicateItems: 2,
      totalReclaimableBytes: 632_000,
      durationSeconds: 0.05,
      groups: [
        {
          id: 'GRP-IMG',
          primaryMediaKind: 'image',
          matchKind: 'nearIdentical',
          similarityScore: 0.98,
          recommendedKeepAssetID: hi.id,
          reclaimableBytes: lo.fileSizeBytes,
          candidates: [
            {
              asset: hi,
              qualityScore: 2200,
              resolutionPixels: 2400 * 1800,
              formatLabel: 'PNG 无损',
              isLosslessFormat: true,
              sharpnessScore: 78,
              isRecommendedKeep: true,
              isReferencedByBoard: true,
              similarityToKeeper: 1,
              qualityReasons: ['分辨率 4.0×', 'PNG 无损'],
            },
            {
              asset: lo,
              qualityScore: 1850,
              resolutionPixels: 1200 * 900,
              formatLabel: 'JPG',
              isLosslessFormat: false,
              sharpnessScore: 42,
              isRecommendedKeep: false,
              isReferencedByBoard: false,
              similarityToKeeper: 0.98,
              qualityReasons: [],
            },
          ],
        },
        {
          id: 'GRP-DOC',
          primaryMediaKind: 'document',
          matchKind: 'normalizedText',
          similarityScore: 1,
          recommendedKeepAssetID: docA.id,
          reclaimableBytes: docB.fileSizeBytes,
          candidates: [
            {
              asset: docA,
              qualityScore: 500,
              resolutionPixels: 0,
              formatLabel: 'MD',
              isLosslessFormat: true,
              sharpnessScore: 0,
              isRecommendedKeep: true,
              isReferencedByBoard: false,
              similarityToKeeper: 1,
              qualityReasons: ['完整版本'],
            },
            {
              asset: docB,
              qualityScore: 480,
              resolutionPixels: 0,
              formatLabel: 'MD',
              isLosslessFormat: true,
              sharpnessScore: 0,
              isRecommendedKeep: false,
              isReferencedByBoard: false,
              similarityToKeeper: 1,
              qualityReasons: [],
            },
          ],
        },
      ],
    };
    mock.mockDuplicateReport = report;

    useCoordinatorStore.getState().openDeduplication({ type: 'allActive' });
    render(<SmartDeduplicationModal />);

    await waitFor(() => {
      expect(screen.getByTestId('dedup-group-GRP-IMG')).toBeInTheDocument();
      expect(screen.getByTestId('dedup-group-GRP-DOC')).toBeInTheDocument();
    });

    // Opaque Fluent 2 modal surface & smoke scrim (prevents underlying gallery bleed-through)
    const backdrop = screen.getByTestId('smart-dedup-modal');
    expect(backdrop.className).toContain('win-smoke-scrim');
    expect(backdrop.className).not.toContain('--overlay-scrim');
    const surface = screen.getByTestId('smart-dedup-dialog-surface');
    expect(surface.className).toContain('bg-[var(--bg-elevated)]');
    expect(surface.className).toContain('border-[var(--win-stroke-flyout)]');
    expect(surface.className).toContain('shadow-[var(--shadow-modal)]');
    expect(surface.className).not.toContain('win-acrylic-elevated');
    expect(surface.className).not.toContain('--win-stroke-surface');

    // Default recommended keeper is ASSET-HI
    expect(screen.getByTestId('dedup-candidate-ASSET-HI')).toHaveAttribute('data-kept', 'true');
    expect(screen.getByTestId('dedup-candidate-ASSET-LO')).toHaveAttribute('data-kept', 'false');

    // Preview candidate opens Quick Look while keeping modal mounted
    fireEvent.click(screen.getByLabelText('大图预览 Poster Master'));
    expect(useCoordinatorStore.getState().quickLookAssetId).toBe('ASSET-HI');
    expect(useCoordinatorStore.getState().dedupOpen).toBe(true);
    useCoordinatorStore.getState().closeQuickLook();

    // Override keeper to ASSET-LO
    fireEvent.click(screen.getByRole('button', { name: '改为保留' }));
    expect(screen.getByTestId('dedup-candidate-ASSET-LO')).toHaveAttribute('data-kept', 'true');

    // Filter to raster only -> only 1 group visible
    fireEvent.click(screen.getByTestId('dedup-filter-raster'));
    expect(screen.getByTestId('dedup-group-GRP-IMG')).toBeInTheDocument();
    expect(screen.queryByTestId('dedup-group-GRP-DOC')).not.toBeInTheDocument();

    // Execute cleanup -> calls resolveDuplicateGroups with overridden keeper ASSET-LO
    fireEvent.click(screen.getByRole('button', { name: /清理 1 组重复项/ }));
    await waitFor(() => {
      expect(mock.mockResolvedDedupCalls).toHaveLength(1);
    });
    expect(mock.mockResolvedDedupCalls[0].disposal).toBe('moveToTrash');
    expect(mock.mockResolvedDedupCalls[0].mergeMetadata).toBe(true);
    expect(mock.mockResolvedDedupCalls[0].plans).toEqual([
      { keepAssetID: 'ASSET-LO', removeAssetIDs: ['ASSET-HI'] },
    ]);
  });

  it('exposes Smart Dedup & Material Package entrypoints across Sidebar, JumpAnywhere, Settings and Ctrl+Shift+D', async () => {
    mock.mockMaterialPackagePaths = ['C:\\Downloads\\Typography.eaglepack'];

    // 1. Sidebar buttons
    const sidebar = render(<SidebarView />);
    fireEvent.click(screen.getByTestId('sidebar-smart-dedup-btn'));
    expect(useCoordinatorStore.getState().dedupOpen).toBe(true);
    useCoordinatorStore.getState().closeDeduplication();

    fireEvent.click(screen.getByTestId('sidebar-import-package-btn'));
    await waitFor(() => {
      expect(mock.mockImportedPackagePaths).toEqual(['C:\\Downloads\\Typography.eaglepack']);
    });
    sidebar.unmount();

    // 2. JumpAnywhere command
    useCoordinatorStore.getState().setJumpOpen(true);
    const jump = render(<JumpAnywhereModal />);
    expect(screen.getByText('智能去重')).toBeInTheDocument();
    fireEvent.click(screen.getByText('智能去重'));
    expect(useCoordinatorStore.getState().dedupOpen).toBe(true);
    useCoordinatorStore.getState().closeDeduplication();
    jump.unmount();

    // 3. Settings -> Library pane buttons
    const settings = render(<LibrarySettingsPane />);
    expect(screen.getByRole('button', { name: /选择素材包 \(\.eaglepack\)/ })).toBeInTheDocument();
    expect(screen.getByRole('button', { name: /选择素材库目录 \(\.library\)/ })).toBeInTheDocument();
    fireEvent.click(screen.getByRole('button', { name: /扫描重复素材/ }));
    expect(useCoordinatorStore.getState().dedupOpen).toBe(true);
    useCoordinatorStore.getState().closeDeduplication();
    settings.unmount();

    // 4. Global Ctrl+Shift+D shortcut in App
    render(<App />);
    await act(async () => {
      window.dispatchEvent(
        new KeyboardEvent('keydown', { key: 'D', ctrlKey: true, shiftKey: true, bubbles: true }),
      );
    });
    expect(useCoordinatorStore.getState().dedupOpen).toBe(true);
  });
});
