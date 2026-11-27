import { fireEvent, render, screen, waitFor } from '@testing-library/react';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { InMemoryMockTransport, setTransport } from '../api/transport';
import { QuickLookOverlay } from '../features/quicklook/QuickLookOverlay';
import { SocialPostViewer } from '../features/quicklook/SocialPostViewer';
import { useCoordinatorStore, useLibraryStore } from '../stores';
import {
  formatVideoTimestamp,
  isStreamableVideoUrl,
  type AssetRecord,
} from '../types/domain';

function makeAsset(overrides: Partial<AssetRecord> = {}): AssetRecord {
  return {
    id: overrides.id ?? 'V151-ASSET-01',
    contentHash: 'hash-v151',
    folderID: null,
    mediaKind: 'webBookmark',
    mimeType: 'text/uri-list',
    title: 'Sample Video Asset',
    fileName: 'sample.url',
    notes: '',
    tags: [],
    suggestedTags: [],
    rating: 0,
    pixelWidth: 1280,
    pixelHeight: 720,
    fileSizeBytes: 512,
    dominantColors: [{ hex: '#1A4FD6', l: 42, a: 28, b: -58, proportion: 0.7 }],
    waveformPeaks: [],
    pinnedOffline: false,
    isLocalOriginalCached: true,
    isTrashed: false,
    createdAt: 1000,
    updatedAt: 1000,
    updatedHLC: 1,
    ...overrides,
  };
}

describe('Charkle Windows v1.5.1 parity (zero-download video streaming playback & frame-to-cover)', () => {
  let mock: InMemoryMockTransport;

  beforeEach(() => {
    mock = new InMemoryMockTransport(false);
    setTransport(mock);
    useLibraryStore.setState({
      assets: [],
      allAssets: [],
      folders: [],
      smartFolders: [],
      tagCounts: [],
      thumbnailRevisions: {},
      bootstrapped: true,
    });
    useCoordinatorStore.setState({
      destination: { type: 'allItems' },
      quickLookAssetId: null,
      toasts: [],
    });
  });

  afterEach(() => {
    vi.restoreAllMocks();
  });

  it('formats timestamps and recognizes streamable video URLs cleanly', () => {
    expect(formatVideoTimestamp(84)).toBe('01:24');
    expect(formatVideoTimestamp(3725)).toBe('1:02:05');
    expect(formatVideoTimestamp(-1)).toBe('00:00');
    expect(isStreamableVideoUrl('https://www.youtube.com/watch?v=dQw4w9WgXcQ')).toBe(true);
    expect(isStreamableVideoUrl('https://www.bilibili.com/video/BV1GJ411x7h7')).toBe(true);
    expect(isStreamableVideoUrl('https://vimeo.com/123456789')).toBe(true);
    expect(isStreamableVideoUrl('https://cdn.example.com/reel.mp4?token=1')).toBe(true);
    expect(isStreamableVideoUrl('https://example.com/article/design-notes')).toBe(false);
  });

  it('resolves Tier 1 native stream, toggles to Tier 2 embed player, and auto-falls back on <video> error with anti-Error-153 Referer policy', async () => {
    const ytAsset = makeAsset({
      id: 'YT-STREAM-01',
      title: 'Lighting Breakdown',
      sourceURL: 'https://www.youtube.com/watch?v=dQw4w9WgXcQ',
      sourceDomain: 'www.youtube.com',
      durationSeconds: 195,
      richMetadata: {
        socialPost: {
          platform: 'youtube',
          authorName: 'Studio Lighting',
          authorHandle: '@studiolight',
          bodyText: 'Zero-download streaming demo.',
          articleTitle: 'Lighting Breakdown',
          mediaURLs: ['https://i.ytimg.com/vi/dQw4w9WgXcQ/maxresdefault.jpg'],
          mediaThumbnailURLs: ['https://i.ytimg.com/vi/dQw4w9WgXcQ/maxresdefault.jpg'],
          attachments: [
            {
              id: 'yt-0',
              kind: 'video',
              url: 'https://www.youtube.com/watch?v=dQw4w9WgXcQ',
              thumbnailURL: 'https://i.ytimg.com/vi/dQw4w9WgXcQ/maxresdefault.jpg',
            },
          ],
          hasVideo: true,
          originalURL: 'https://www.youtube.com/watch?v=dQw4w9WgXcQ',
          videoDurationSeconds: 195,
          videoSummary: '三点布光演示。',
          videoOutline: ['00:00 开场', '01:24 主光测试'],
          videoID: 'dQw4w9WgXcQ',
        },
      },
    });
    mock.seedAssets([ytAsset]);
    mock.mockPlaybackPlans[ytAsset.id] = {
      directStreams: [
        {
          url: 'https://rr1---sn-demo.googlevideo.com/videoplayback?mime=video/mp4',
          httpHeaders: {
            Referer: 'https://www.youtube.com/',
            'User-Agent': 'Mozilla/5.0',
          },
          isHls: false,
        },
      ],
      embedPlayer: {
        url: 'https://www.youtube.com/embed/dQw4w9WgXcQ?autoplay=1&playsinline=1&rel=0&modestbranding=1&origin=https://charkle.app',
        referer: 'https://charkle.app',
        useIframeWrapper: true,
        embedHtml: '<iframe src="https://www.youtube.com/embed/dQw4w9WgXcQ"></iframe>',
      },
      watchUrl: 'https://www.youtube.com/watch?v=dQw4w9WgXcQ',
    };
    useLibraryStore.setState({ assets: [ytAsset], allAssets: [ytAsset] });

    render(<SocialPostViewer asset={ytAsset} />);

    // Resolving indicator appears immediately during 120ms debounce
    expect(screen.getByText('正在连接流式播放…')).toBeInTheDocument();

    // After debounce resolves, Tier 1 native <video> mounts with both action pills
    const video = await screen.findByTestId('streaming-native-video');
    expect(video.getAttribute('src')).toContain('googlevideo.com/videoplayback');
    expect(video.getAttribute('crossorigin')).toBe('anonymous');

    // Toggle between Tier 1 native stream and Tier 2 embed player
    const toggleBtn = screen.getByTestId('streaming-toggle-mode-btn');
    expect(toggleBtn.textContent).toContain('切换网页播放器');
    fireEvent.click(toggleBtn);

    const iframe = await screen.findByTestId('streaming-embed-iframe');
    expect(iframe.getAttribute('src')).toContain('youtube.com/embed/dQw4w9WgXcQ');
    expect(iframe.getAttribute('src')).toContain('origin=https://charkle.app');
    expect(iframe.getAttribute('referrerpolicy')).toBe('strict-origin-when-cross-origin');
    expect(screen.getByTestId('streaming-toggle-mode-btn').textContent).toContain('切换原生流式');

    // Switch back to native stream, trigger playback error -> auto-falls back to Tier 2 iframe
    fireEvent.click(screen.getByTestId('streaming-toggle-mode-btn'));
    const nativeAgain = await screen.findByTestId('streaming-native-video');
    fireEvent.error(nativeAgain);

    const autoFallbackIframe = await screen.findByTestId('streaming-embed-iframe');
    expect(autoFallbackIframe.getAttribute('src')).toContain('youtube.com/embed/dQw4w9WgXcQ');
  });

  it('captures current video frame in embed mode via WebView2 region capture, updates cover, bumps thumbnail revision, and shows toast', async () => {
    const biliAsset = makeAsset({
      id: 'BILI-COVER-01',
      title: '材质渲染工作流',
      sourceURL: 'https://www.bilibili.com/video/BV1GJ411x7h7',
      sourceDomain: 'www.bilibili.com',
      richMetadata: {
        socialPost: {
          platform: 'bilibili',
          authorName: '渲染实验室',
          authorHandle: 'UP 2048',
          bodyText: 'PBR 材质演示。',
          articleTitle: '材质渲染工作流',
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
          videoID: 'BV1GJ411x7h7',
          videoCID: 778899,
        },
      },
    });
    mock.seedAssets([biliAsset]);
    useLibraryStore.setState({ assets: [biliAsset], allAssets: [biliAsset] });

    render(<SocialPostViewer asset={biliAsset} />);

    // Mock transport resolves Bilibili embed player directly when no directStreams exist
    const iframe = await screen.findByTestId('streaming-embed-iframe');
    expect(iframe.getAttribute('src')).toContain('player.bilibili.com/player.html');
    expect(iframe.getAttribute('src')).toContain('bvid=BV1GJ411x7h7');
    expect(iframe.getAttribute('src')).toContain('cid=778899');

    // Provide a non-zero stage bounding rect for jsdom WebView2 capture fallback
    const stage = screen.getByTestId('quicklook-streaming-video-player');
    vi.spyOn(stage, 'getBoundingClientRect').mockReturnValue({
      left: 100,
      top: 80,
      width: 640,
      height: 360,
      right: 740,
      bottom: 440,
      x: 100,
      y: 80,
      toJSON: () => ({}),
    });

    fireEvent.click(screen.getByTestId('streaming-set-cover-btn'));

    await waitFor(() => {
      expect(mock.mockCoverUpdates).toHaveLength(1);
    });
    expect(mock.mockCoverUpdates[0].assetId).toBe(biliAsset.id);
    expect(useLibraryStore.getState().thumbnailRevisions[biliAsset.id]).toBe(1);
    expect(
      useCoordinatorStore
        .getState()
        .toasts.some((t) => t.message === '已将当前画面设为素材封面'),
    ).toBe(true);
  });

  it('captures current playhead frame for local .video asset in QuickLookOverlay bottom HUD and shows MM:SS toast', async () => {
    const localVideo = makeAsset({
      id: 'LOCAL-VID-01',
      mediaKind: 'video',
      mimeType: 'video/mp4',
      title: 'Turntable Clip',
      fileName: 'turntable.mp4',
      pixelWidth: 1920,
      pixelHeight: 1080,
    });
    mock.seedAssets([localVideo]);
    useLibraryStore.setState({ assets: [localVideo], allAssets: [localVideo] });
    useCoordinatorStore.setState({ quickLookAssetId: localVideo.id });

    // Stub offscreen canvas 2D drawing & JPEG encoding in jsdom
    const drawImage = vi.fn();
    vi.spyOn(HTMLCanvasElement.prototype, 'getContext').mockReturnValue({
      drawImage,
    } as never);
    vi.spyOn(HTMLCanvasElement.prototype, 'toDataURL').mockReturnValue(
      'data:image/jpeg;base64,/9j/4AAQSkZJRg==',
    );

    render(<QuickLookOverlay />);

    const videoEl = screen.getByTestId('quicklook-local-video') as HTMLVideoElement;
    Object.defineProperty(videoEl, 'videoWidth', { configurable: true, value: 1920 });
    Object.defineProperty(videoEl, 'videoHeight', { configurable: true, value: 1080 });
    Object.defineProperty(videoEl, 'currentTime', { configurable: true, value: 84 });

    const setCoverBtn = screen.getByTestId('quicklook-set-cover-frame-btn');
    fireEvent.click(setCoverBtn);

    await waitFor(() => {
      expect(mock.mockCoverUpdates).toHaveLength(1);
    });
    expect(drawImage).toHaveBeenCalled();
    expect(mock.mockCoverUpdates[0].assetId).toBe(localVideo.id);
    expect(useLibraryStore.getState().thumbnailRevisions[localVideo.id]).toBe(1);
    expect(
      useCoordinatorStore
        .getState()
        .toasts.some((t) => t.message === '已将 01:24 画面设为素材封面'),
    ).toBe(true);
  });

  it('mounts QuickLookStreamingVideoView for video-bearing rich webpage bookmarks inside QuickLookOverlay', async () => {
    const webVideoAsset = makeAsset({
      id: 'WEB-VID-01',
      title: 'Motion Reel 2026',
      sourceURL: 'https://vimeo.com/987654321',
      sourceDomain: 'vimeo.com',
      durationSeconds: 65,
      richMetadata: {
        webPage: {
          siteName: 'Vimeo',
          summary: 'High-contrast motion study.',
          hasVideo: true,
          durationSeconds: 65,
          attachments: [
            {
              id: 'v-0',
              kind: 'video',
              url: 'https://cdn.example.com/motion-reel.mp4',
              thumbnailURL: 'https://cdn.example.com/motion-poster.jpg',
            },
          ],
        },
      },
    });
    mock.seedAssets([webVideoAsset]);
    useLibraryStore.setState({ assets: [webVideoAsset], allAssets: [webVideoAsset] });
    useCoordinatorStore.setState({ quickLookAssetId: webVideoAsset.id });

    render(<QuickLookOverlay />);

    expect(screen.getByTestId('quicklook-web-bookmark-card')).toBeInTheDocument();
    expect(screen.getByTestId('quicklook-streaming-video-player')).toBeInTheDocument();
    const video = await screen.findByTestId('streaming-native-video');
    expect(video.getAttribute('src')).toBe('https://cdn.example.com/motion-reel.mp4');
  });
});
