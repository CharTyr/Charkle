import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import { InMemoryMockTransport, setTransport } from '../api/transport';
import { BatchActionPill } from '../features/gallery/BatchActionPill';
import { MoodboardsHome } from '../features/moodboard/MoodboardsHome';
import { QuickLookOverlay } from '../features/quicklook/QuickLookOverlay';
import { SocialPostViewer } from '../features/quicklook/SocialPostViewer';
import { SidebarView } from '../features/sidebar/SidebarView';
import {
  isPlainWebBookmark,
  useCoordinatorStore,
  useLibraryStore,
  useMoodboardStore,
} from '../stores';
import {
  createDefaultFilterCriteria,
  extractableLinkAttachments,
  resolveSocialMediaUrl,
  type AssetRecord,
} from '../types/domain';

function makeAsset(overrides: Partial<AssetRecord> = {}): AssetRecord {
  const id = overrides.id ?? `ASSET-${Math.random().toString(16).slice(2, 10).toUpperCase()}`;
  return {
    id,
    contentHash: `hash-${id}`,
    folderID: null,
    mediaKind: 'webBookmark',
    mimeType: 'text/markdown',
    title: 'Sample Asset',
    fileName: 'sample.md',
    notes: '',
    tags: [],
    suggestedTags: [],
    rating: 0,
    pixelWidth: 1280,
    pixelHeight: 720,
    durationSeconds: null,
    fileSizeBytes: 2048,
    dominantColors: [],
    waveformPeaks: [],
    sourceURL: 'https://example.com',
    sourceDomain: 'example.com',
    ocrText: null,
    aiDescription: null,
    richMetadata: null,
    pinnedOffline: false,
    isLocalOriginalCached: true,
    isTrashed: false,
    createdAt: 790_000_000,
    updatedAt: 790_000_000,
    lastOpenedAt: null,
    updatedHLC: 1,
    ...overrides,
  };
}

describe('Charkle Windows v1.5.0 parity (unified search, video bookmarks, universal web, batch extract, PureRef)', () => {
  let mock: InMemoryMockTransport;

  beforeEach(() => {
    mock = new InMemoryMockTransport();
    setTransport(mock);
    useCoordinatorStore.setState({
      destination: { type: 'allItems' },
      selectedAssetIds: [],
      quickLookAssetId: null,
      settingsOpen: false,
      onboardingOpen: false,
      jumpOpen: false,
      captureOpen: false,
      moodboardGeneratorOpen: false,
      sidebarCollapsed: false,
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
      semanticSearch: false,
      loading: false,
      bootstrapped: true,
      error: null,
    });
    useMoodboardStore.setState({
      boards: [],
      activeBoard: null,
      openBoardFailedId: null,
    });
  });

  afterEach(() => {
    cleanup();
  });

  it('removes split semantic toggle button and runs unified instant search in SidebarView', () => {
    render(<SidebarView />);
    expect(screen.queryByLabelText('语义搜图')).toBeNull();
    const input = screen.getByLabelText('搜索素材') as HTMLInputElement;
    expect(input.placeholder).toContain('搜索素材');
    fireEvent.change(input, { target: { value: 'warm studio lighting' } });
    fireEvent.keyDown(input, { key: 'Enter' });
    expect(useLibraryStore.getState().criteria.searchQuery).toBe('warm studio lighting');
  });

  it('renders YouTube/Bilibili video bookmark viewer with summary, chapters, no watch-URL <video>, and explicit save-video action', async () => {
    const biliAsset = makeAsset({
      id: 'BILI-VIDEO-01',
      title: '室内电影布光 3 步法',
      sourceURL: 'https://www.bilibili.com/video/BV1GJ411x7h7',
      sourceDomain: 'www.bilibili.com',
      durationSeconds: 754,
      richMetadata: {
        socialPost: {
          platform: 'bilibili',
          authorName: '光影实验室',
          authorHandle: 'UP 10086',
          bodyText: '完整布光拆解演示。',
          articleTitle: '室内电影布光 3 步法',
          mediaURLs: ['https://i0.hdslb.com/bfs/archive/cover.jpg'],
          mediaThumbnailURLs: ['https://i0.hdslb.com/bfs/archive/cover.jpg'],
          attachments: [
            {
              id: 'bili-0',
              kind: 'video',
              url: 'https://www.bilibili.com/video/BV1GJ411x7h7',
              thumbnailURL: 'https://i0.hdslb.com/bfs/archive/cover.jpg',
            },
          ],
          hasVideo: true,
          originalURL: 'https://www.bilibili.com/video/BV1GJ411x7h7',
          videoDurationSeconds: 754,
          videoSummary: '通过主光、轮廓光与环境光比例塑造立体电影感。',
          videoOutline: ['00:00 开场与器材', '02:15 主光定位', '06:40 轮廓光收边'],
          videoID: 'BV1GJ411x7h7',
          videoCID: 123456,
        },
      },
    });

    // Verify Bilibili & YouTube CDN hosts proxy cleanly through /proxy-social
    expect(
      resolveSocialMediaUrl('https://i0.hdslb.com/bfs/archive/cover.jpg', true),
    ).toContain('/proxy-social?url=');
    expect(resolveSocialMediaUrl('https://i.ytimg.com/vi/dQw4w9WgXcQ/maxresdefault.jpg', true)).toContain(
      '/proxy-social?url=',
    );

    const { container } = render(<SocialPostViewer asset={biliAsset} />);
    expect(screen.getByTestId('video-bookmark-stage')).toBeTruthy();
    expect(screen.getByTestId('video-bookmark-summary-card')).toBeTruthy();
    expect(screen.getByText('视频摘要')).toBeTruthy();
    expect(screen.getByText(/主光、轮廓光/)).toBeTruthy();
    expect(screen.getByText('02:15 主光定位')).toBeTruthy();
    expect(screen.getByText('12:34')).toBeTruthy();
    // Never pass watch URL directly to a <video> element
    expect(container.querySelector('video')).toBeNull();

    fireEvent.click(screen.getByTestId('video-bookmark-save-asset'));
    await waitFor(() => {
      expect(mock.mockExtractedAttachments.length).toBe(1);
    });
    expect(mock.mockExtractedAttachments[0].attachmentUrl).toBe(
      'https://www.bilibili.com/video/BV1GJ411x7h7',
    );
    expect(mock.mockExtractedAttachments[0].attachmentKind).toBe('video');
  });

  it('treats rich webpages with summary/attachments as Quick Look inspectable and extracts discovered media', async () => {
    const richWeb = makeAsset({
      id: 'WEB-RICH-01',
      title: 'Architectural Light Study',
      sourceURL: 'https://studio.example.com/study',
      sourceDomain: 'studio.example.com',
      richMetadata: {
        webPage: {
          siteName: 'Studio Journal',
          authorName: 'Maya Lin',
          publishedAtText: '2026-11-25',
          summary: 'Deep dive into daylight apertures and warm stone bounce.',
          attachments: [
            {
              id: 'w-img-0',
              kind: 'photo',
              url: 'https://cdn.example.com/hero.jpg',
              thumbnailURL: 'https://cdn.example.com/hero.jpg',
            },
          ],
          hasVideo: false,
        },
      },
    });

    expect(isPlainWebBookmark(richWeb)).toBe(false);
    expect(extractableLinkAttachments(richWeb)).toHaveLength(1);

    useLibraryStore.setState({ assets: [richWeb], allAssets: [richWeb] });
    useCoordinatorStore.setState({ quickLookAssetId: richWeb.id });

    render(<QuickLookOverlay />);
    expect(screen.getByTestId('quicklook-web-bookmark-card')).toBeTruthy();
    expect(screen.getByText(/Studio Journal/)).toBeTruthy();
    expect(screen.getByText(/Deep dive into daylight apertures/)).toBeTruthy();

    fireEvent.click(screen.getByTestId('web-extract-att-0'));
    await waitFor(() => {
      expect(mock.mockExtractedAttachments.length).toBe(1);
    });
    expect(mock.mockExtractedAttachments[0].attachmentUrl).toBe('https://cdn.example.com/hero.jpg');
  });

  it('shows multi-select batch link media extraction and PureRef export on BatchActionPill', async () => {
    const ytAsset = makeAsset({
      id: 'YT-01',
      title: 'Color Grading 101',
      sourceURL: 'https://www.youtube.com/watch?v=dQw4w9WgXcQ',
      richMetadata: {
        socialPost: {
          platform: 'youtube',
          authorName: 'Color Lab',
          authorHandle: 'colorlab',
          bodyText: 'LUT workflow',
          mediaURLs: [],
          mediaThumbnailURLs: [],
          attachments: [],
          hasVideo: true,
          originalURL: 'https://www.youtube.com/watch?v=dQw4w9WgXcQ',
        },
      },
    });
    const xAsset = makeAsset({
      id: 'X-01',
      title: 'Poster Grid',
      sourceURL: 'https://x.com/design/status/12345',
      richMetadata: {
        socialPost: {
          platform: 'x',
          authorName: 'Design Studio',
          authorHandle: 'design',
          bodyText: 'Grid study',
          mediaURLs: ['https://pbs.twimg.com/media/abc.jpg'],
          mediaThumbnailURLs: ['https://pbs.twimg.com/media/abc.jpg'],
          attachments: [
            {
              id: 'x-0',
              kind: 'photo',
              url: 'https://pbs.twimg.com/media/abc.jpg',
              thumbnailURL: 'https://pbs.twimg.com/media/abc.jpg',
            },
          ],
          hasVideo: false,
          originalURL: 'https://x.com/design/status/12345',
        },
      },
    });

    await mock.ingestText('seed', 'seed');
    // Inject both link assets into mock & store
    (mock as unknown as { assets: AssetRecord[] }).assets.unshift(ytAsset, xAsset);
    useLibraryStore.setState({ assets: [ytAsset, xAsset], allAssets: [ytAsset, xAsset] });
    useCoordinatorStore.setState({ selectedAssetIds: [ytAsset.id, xAsset.id] });

    render(<BatchActionPill />);
    const extractBtn = screen.getByTestId('batch-extract-link-media');
    expect(extractBtn.textContent).toContain('提取媒体 (2)');

    fireEvent.click(extractBtn);
    await waitFor(() => {
      expect(mock.mockBatchExtractedAssetIds.length).toBe(1);
    });
    expect(mock.mockBatchExtractedAssetIds[0]).toEqual([ytAsset.id, xAsset.id]);

    const pureRefBtn = screen.getByTestId('batch-export-pureref');
    fireEvent.click(pureRefBtn);
    await waitFor(() => {
      expect(mock.mockExportedPureRefPaths.length).toBe(1);
    });
    expect(mock.mockExportedPureRefPaths[0]).toContain('.pur');
  });

  it('imports PureRef (.pur) scenes from MoodboardsHome and opens the created Moodboard', async () => {
    mock.mockPureRefPaths = ['%USERPROFILE%\\Scenes\\CharacterRefs.pur'];
    useCoordinatorStore.setState({ destination: { type: 'moodboardsHome' } });

    render(<MoodboardsHome />);
    const importBtn = screen.getByTestId('moodboards-import-pureref');
    fireEvent.click(importBtn);

    await waitFor(() => {
      expect(mock.mockImportedPureRefPaths).toEqual(['%USERPROFILE%\\Scenes\\CharacterRefs.pur']);
    });
    await waitFor(() => {
      expect(useCoordinatorStore.getState().destination.type).toBe('moodboard');
    });
  });
});
