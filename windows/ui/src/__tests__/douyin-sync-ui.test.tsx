import { fireEvent, render, screen, waitFor } from '@testing-library/react';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { extractWebUrlFromPaste } from '../App';
import { InMemoryMockTransport, setTransport } from '../api/transport';
import { AssetCard } from '../features/gallery/AssetCard';
import { effectiveAspectRatio } from '../features/gallery/masonryLayout';
import { ringEffectiveAspectRatio } from '../features/gallery/ringGalleryMath';
import { InspectorView } from '../features/inspector/InspectorView';
import { SocialPostViewer } from '../features/quicklook/SocialPostViewer';
import { useCoordinatorStore, useLibraryStore } from '../stores';
import {
  extractableLinkAttachments,
  formatSocialDisplayHandle,
  isStreamableVideoUrl,
  isVerticalSocialFeedPlatform,
  isVideoSocialPlatform,
  isZeroDownloadVideoBookmark,
  resolveSocialMediaUrl,
  type AssetRecord,
} from '../types/domain';

function makeDouyinAsset(overrides: Partial<AssetRecord> = {}): AssetRecord {
  return {
    id: overrides.id ?? 'DY-ASSET-01',
    contentHash: 'hash-dy-01',
    folderID: null,
    mediaKind: 'webBookmark',
    mimeType: 'text/uri-list',
    title: '极简建筑光影短片',
    fileName: 'douyin-post.url',
    notes: '',
    tags: ['抖音'],
    suggestedTags: [],
    rating: 0,
    pixelWidth: 900,
    pixelHeight: 1440,
    durationSeconds: 42,
    fileSizeBytes: 512,
    dominantColors: [{ hex: '#161823', l: 10, a: 1, b: -5, proportion: 0.6 }],
    waveformPeaks: [],
    sourceURL: 'https://www.douyin.com/video/7412345678901234567',
    sourceDomain: 'www.douyin.com',
    pinnedOffline: false,
    isLocalOriginalCached: true,
    isTrashed: false,
    createdAt: 1000,
    updatedAt: 1000,
    updatedHLC: 1,
    ...overrides,
  };
}

describe('Charkle Windows Douyin Favorites Sync UI (Wave 3)', () => {
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
      selectedAssetIds: [],
      quickLookAssetId: null,
      toasts: [],
    });
  });

  afterEach(() => {
    vi.restoreAllMocks();
  });

  it('decouples isVideoSocialPlatform from isZeroDownloadVideoBookmark and tolerates unknown future platforms', () => {
    expect(isVideoSocialPlatform('youtube')).toBe(true);
    expect(isVideoSocialPlatform('bilibili')).toBe(true);
    expect(isVideoSocialPlatform('douyin')).toBe(false);
    expect(isVideoSocialPlatform('future_social_platform')).toBe(false);

    expect(isVerticalSocialFeedPlatform('xiaohongshu')).toBe(true);
    expect(isVerticalSocialFeedPlatform('douyin')).toBe(true);
    expect(isVerticalSocialFeedPlatform('youtube')).toBe(false);
    expect(isVerticalSocialFeedPlatform('future_social_platform')).toBe(false);

    expect(isZeroDownloadVideoBookmark({ platform: 'youtube', hasVideo: true })).toBe(true);
    expect(isZeroDownloadVideoBookmark({ platform: 'bilibili', hasVideo: false })).toBe(true);
    expect(isZeroDownloadVideoBookmark({ platform: 'douyin', hasVideo: true })).toBe(true);
    expect(isZeroDownloadVideoBookmark({ platform: 'douyin', hasVideo: false })).toBe(false);
    expect(isZeroDownloadVideoBookmark({ platform: 'xiaohongshu', hasVideo: true })).toBe(false);
    expect(
      isZeroDownloadVideoBookmark({ platform: 'future_social_platform', hasVideo: true }),
    ).toBe(false);
  });

  it('sanitizes Douyin sec_uid / numeric UIDs in formatSocialDisplayHandle and tolerates unknown platforms', () => {
    expect(
      formatSocialDisplayHandle({
        platform: 'douyin',
        authorName: '光影观察室',
        authorHandle: 'MS4wLjABAAAA9x8y7z6w5v4u3t2s1r0q',
      }),
    ).toBeNull();
    expect(
      formatSocialDisplayHandle({
        platform: 'douyin',
        authorName: '光影观察室',
        authorHandle: '123456789012345',
      }),
    ).toBeNull();
    expect(
      formatSocialDisplayHandle({
        platform: 'douyin',
        authorName: '光影观察室',
        authorHandle: '@douyin',
      }),
    ).toBeNull();
    expect(
      formatSocialDisplayHandle({
        platform: 'douyin',
        authorName: '光影观察室',
        authorHandle: '光影观察室',
      }),
    ).toBeNull();
    expect(
      formatSocialDisplayHandle({
        platform: 'douyin',
        authorName: '光影观察室',
        authorHandle: 'light_studio_dy',
      }),
    ).toBe('抖音号 light_studio_dy');
    expect(
      formatSocialDisplayHandle({
        platform: 'douyin',
        authorName: '光影观察室',
        authorHandle: '抖音号 light_studio_dy',
      }),
    ).toBe('抖音号 light_studio_dy');
    expect(
      formatSocialDisplayHandle({
        platform: 'future_social_platform',
        authorName: 'Future Author',
        authorHandle: 'future_handle',
      }),
    ).toBe('@future_handle');
  });

  it('routes Douyin image CDN hosts through /proxy-social in Tauri runtime and recognizes streamable Douyin video URLs', () => {
    const cdnUrls = [
      'https://p3-pc.douyinpic.com/img/cover.jpeg',
      'https://p9-sign.byteimg.com/tos-cn-i/sample.webp',
      'https://sf3-cdn-tos.ibytedtos.com/obj/avatar.png',
      'https://p6.zjcdn.com/tos-cn-i/slide.jpg',
      'https://p1.snssdk.com/img/thumb.jpg',
      'https://p26.amemv.com/img/thumb.jpg',
      'https://p3.pstatp.com/img/thumb.jpg',
    ];
    for (const url of cdnUrls) {
      expect(resolveSocialMediaUrl(url, true)).toBe(
        `http://charkle-media.localhost/proxy-social?url=${encodeURIComponent(url)}`,
      );
      expect(resolveSocialMediaUrl(url, false)).toBe(url);
    }

    expect(isStreamableVideoUrl('https://www.douyin.com/video/7412345678901234567')).toBe(true);
    expect(
      isStreamableVideoUrl('https://www.douyin.com/user/self?modal_id=7412345678901234567'),
    ).toBe(true);
    expect(isStreamableVideoUrl('https://v26-web.douyinvod.com/stream/abc')).toBe(true);
    expect(isStreamableVideoUrl('https://www.douyin.com/note/7412345678901234567')).toBe(false);

    const bareDouyinVideo = makeDouyinAsset({
      richMetadata: {
        socialPost: {
          platform: 'douyin',
          authorName: '光影观察室',
          authorHandle: '',
          bodyText: '裸链接采集测试',
          mediaURLs: [],
          mediaThumbnailURLs: [],
          attachments: [],
          hasVideo: true,
          originalURL: 'https://www.douyin.com/video/7412345678901234567',
        },
      },
    });
    expect(extractableLinkAttachments(bareDouyinVideo)).toEqual([
      {
        id: 'video-bookmark-0',
        kind: 'video',
        url: 'https://www.douyin.com/video/7412345678901234567',
        thumbnailURL: null,
      },
    ]);
  });

  it('renders SocialPostViewer Douyin video branch with streaming player, frame-to-cover, and on-demand MP4 save', async () => {
    const streamUrl = 'https://v26-web.douyinvod.com/stream/7412345678901234567.mp4';
    const coverUrl = 'https://p3-pc.douyinpic.com/img/cover.jpeg';
    const dyVideoAsset = makeDouyinAsset({
      id: 'DY-VIDEO-01',
      title: '日落建筑逆光运镜',
      richMetadata: {
        socialPost: {
          platform: 'douyin',
          authorName: '空间造物影像',
          authorHandle: 'MS4wLjABAAAA9x8y7z6w5v4u3t2s1r0q',
          articleTitle: '日落建筑逆光运镜',
          bodyText: '低饱和胶片感运镜参考。',
          mediaURLs: [coverUrl],
          mediaThumbnailURLs: [coverUrl],
          attachments: [
            {
              id: 'dy-vid-0',
              kind: 'video',
              url: streamUrl,
              thumbnailURL: coverUrl,
            },
          ],
          hasVideo: true,
          videoURL: streamUrl,
          videoDurationSeconds: 42,
          videoID: '7412345678901234567',
          likeCount: 3200,
          originalURL: 'https://www.douyin.com/video/7412345678901234567',
        },
      },
    });
    mock.seedAssets([dyVideoAsset]);
    useLibraryStore.setState({ assets: [dyVideoAsset], allAssets: [dyVideoAsset] });

    const updateSpy = vi.spyOn(mock, 'updateAssets');
    const extractSpy = vi.spyOn(mock, 'extractLinkMediaAttachment');

    const { container } = render(<SocialPostViewer asset={dyVideoAsset} />);

    // Platform badge, action label, duration, and sec_uid suppression
    expect(screen.getByText('抖音')).toBeInTheDocument();
    expect(screen.getAllByRole('button', { name: '在抖音中打开' }).length).toBeGreaterThanOrEqual(1);
    expect(container.textContent).not.toContain('MS4wLjABAAAA9x8y7z6w5v4u3t2s1r0q');

    // Mounts QuickLookStreamingVideoView & resolves native direct stream
    expect(screen.getByTestId('video-bookmark-stage')).toBeInTheDocument();
    const videoEl = await screen.findByTestId('streaming-native-video');
    expect(videoEl.getAttribute('src')).toContain('douyinvod.com/stream/7412345678901234567.mp4');
    expect(videoEl.getAttribute('crossorigin')).toBe('anonymous');

    // Frame-to-cover action ("设当前帧为封面") via region capture fallback in jsdom
    const stage = screen.getByTestId('quicklook-streaming-video-player');
    vi.spyOn(stage, 'getBoundingClientRect').mockReturnValue({
      left: 40,
      top: 40,
      width: 640,
      height: 360,
      right: 680,
      bottom: 400,
      x: 40,
      y: 40,
      toJSON: () => ({}),
    });
    fireEvent.click(screen.getByTestId('streaming-set-cover-btn'));
    await waitFor(() => {
      expect(mock.mockCoverUpdates).toHaveLength(1);
    });
    expect(mock.mockCoverUpdates[0].assetId).toBe(dyVideoAsset.id);

    // Explicit on-demand save ("保存视频为独立素材")
    fireEvent.click(screen.getByTestId('video-bookmark-save-asset'));
    await waitFor(() => {
      expect(extractSpy).toHaveBeenCalledTimes(1);
    });
    expect(extractSpy).toHaveBeenCalledWith(dyVideoAsset.id, streamUrl, 'video', null);
    await waitFor(() => {
      expect(updateSpy).toHaveBeenCalledWith(
        expect.objectContaining({
          title: '日落建筑逆光运镜',
          addTags: ['抖音'],
          notes: expect.stringContaining('来源作品：空间造物影像 · 抖音'),
        }),
      );
    });
  });

  it('renders SocialPostViewer Douyin multi-image photo-note branch with 3:4 grid and extraction', async () => {
    const img1 = 'https://p3-pc.douyinpic.com/img/note-1.jpeg';
    const img2 = 'https://p9-sign.byteimg.com/tos-cn-i/note-2.webp';
    const dyPhotoNote = makeDouyinAsset({
      id: 'DY-NOTE-01',
      title: '北欧木作配色灵感图文',
      durationSeconds: undefined,
      sourceURL: 'https://www.douyin.com/note/7412345678909876543',
      richMetadata: {
        socialPost: {
          platform: 'douyin',
          authorName: '材料与空间',
          authorHandle: 'material_space',
          articleTitle: '北欧木作配色灵感图文',
          bodyText: '原木、石膏与柔和自然光的搭配参考。',
          mediaURLs: [img1, img2],
          mediaThumbnailURLs: [img1, img2],
          attachments: [
            { id: 'dy-img-0', kind: 'photo', url: img1, thumbnailURL: img1 },
            { id: 'dy-img-1', kind: 'photo', url: img2, thumbnailURL: img2 },
          ],
          hasVideo: false,
          likeCount: 1840,
          originalURL: 'https://www.douyin.com/note/7412345678909876543',
        },
      },
    });
    mock.seedAssets([dyPhotoNote]);
    useLibraryStore.setState({ assets: [dyPhotoNote], allAssets: [dyPhotoNote] });

    const { container } = render(<SocialPostViewer asset={dyPhotoNote} />);

    // Must NOT mount streaming video player for photo-notes
    expect(screen.queryByTestId('video-bookmark-stage')).not.toBeInTheDocument();
    expect(screen.getByText('抖音')).toBeInTheDocument();
    expect(screen.getByText('抖音号 material_space')).toBeInTheDocument();
    expect(screen.getByText('作品内含 2 个媒体')).toBeInTheDocument();
    expect(screen.getByRole('button', { name: '全部提取为独立素材' })).toBeInTheDocument();
    expect(screen.getByRole('button', { name: '在抖音中打开' })).toBeInTheDocument();

    // Renders 3:4 vertical 2-column grid matching Xiaohongshu
    const gridCells = container.querySelectorAll<HTMLElement>('.aspect-\\[3\\/4\\]');
    expect(gridCells).toHaveLength(2);
    const imgs = Array.from(gridCells).map((cell) => cell.querySelector('img'));
    expect(imgs[0]?.getAttribute('src')).toBe(img1);
    expect(imgs[1]?.getAttribute('src')).toBe(img2);
  });

  it('tolerates unknown future SocialPlatform values in SocialPostViewer without crashing', () => {
    const futurePost = makeDouyinAsset({
      id: 'FUTURE-01',
      title: 'Future Platform Post',
      richMetadata: {
        socialPost: {
          platform: 'future_canvas',
          authorName: 'Future Creator',
          authorHandle: 'future_id',
          bodyText: 'Synced from a newer client.',
          mediaURLs: [],
          mediaThumbnailURLs: [],
          attachments: [],
          hasVideo: false,
          originalURL: 'https://example.com/posts/123',
        },
      },
    });

    render(<SocialPostViewer asset={futurePost} />);
    expect(screen.getByText('future_canvas')).toBeInTheDocument();
    expect(screen.getByText('@future_id')).toBeInTheDocument();
    expect(screen.getByRole('button', { name: '查看原帖' })).toBeInTheDocument();
  });

  it('aligns AssetCard, Masonry/Ring 0.625 ratio, Inspector, paste share-copy, and mock transport for Douyin', async () => {
    const dyZeroPixel = makeDouyinAsset({
      id: 'DY-RATIO-01',
      pixelWidth: 0,
      pixelHeight: 0,
      richMetadata: {
        socialPost: {
          platform: 'douyin',
          authorName: '空间造物',
          authorHandle: 'MS4wLjABAAAA1234567890abcdef',
          articleTitle: '竖版比例测试',
          bodyText: '正文内容',
          mediaURLs: [],
          mediaThumbnailURLs: [],
          attachments: [],
          hasVideo: true,
          originalURL: 'https://www.douyin.com/video/7412345678901234567',
        },
      },
    });

    expect(effectiveAspectRatio(dyZeroPixel, 0.4, 2.5)).toBeCloseTo(0.625, 3);
    expect(ringEffectiveAspectRatio(dyZeroPixel)).toBeCloseTo(0.625, 3);

    render(
      <AssetCard
        asset={dyZeroPixel}
        selected={false}
        orderedIds={[dyZeroPixel.id]}
        width={220}
        height={352}
      />,
    );
    expect(screen.getByText('抖音')).toBeInTheDocument();

    // Inspector renders Douyin label and zero-download video save CTA even when attachments is empty
    mock.seedAssets([dyZeroPixel]);
    useLibraryStore.setState({ assets: [dyZeroPixel], allAssets: [dyZeroPixel] });
    useCoordinatorStore.setState({ selectedAssetIds: [dyZeroPixel.id] });
    render(<InspectorView />);
    expect(screen.getByText('抖音作品')).toBeInTheDocument();
    expect(screen.getByText('视频作品保存')).toBeInTheDocument();
    expect(screen.getByRole('button', { name: '保存视频为独立素材' })).toBeInTheDocument();

    // Clipboard share-copy extraction supports v.douyin.com & modal_id
    expect(
      extractWebUrlFromPaste(
        '7.48 复制打开抖音，看看【空间造物的作品】自然光建筑短片 https://v.douyin.com/iAbCdEf/ 08/19',
      ),
    ).toBe('https://v.douyin.com/iAbCdEf/');
    expect(extractWebUrlFromPaste('v.douyin.com/iXyZ123/')).toBe('https://v.douyin.com/iXyZ123/');
    expect(
      extractWebUrlFromPaste(
        'https://www.douyin.com/user/self?showTab=favorite_collection&modal_id=7412345678901234567',
      ),
    ).toBe(
      'https://www.douyin.com/user/self?showTab=favorite_collection&modal_id=7412345678901234567',
    );

    // Mock transport ingestUrl + resolveVideoPlaybackPlan support Douyin video & photo-note
    const [ingestedVid] = await mock.ingestUrl(
      'https://www.douyin.com/video/7412345678901234567',
    );
    expect(ingestedVid.richMetadata?.socialPost?.platform).toBe('douyin');
    expect(ingestedVid.richMetadata?.socialPost?.hasVideo).toBe(true);
    expect(ingestedVid.pixelWidth).toBe(900);
    expect(ingestedVid.pixelHeight).toBe(1440);
    const plan = await mock.resolveVideoPlaybackPlan(ingestedVid.id);
    expect(plan.directStreams.length).toBeGreaterThan(0);
    expect(plan.directStreams[0].httpHeaders.Referer).toBe('https://www.douyin.com/');

    const [ingestedNote] = await mock.ingestUrl(
      'https://www.douyin.com/note/7412345678909876543',
    );
    expect(ingestedNote.richMetadata?.socialPost?.platform).toBe('douyin');
    expect(ingestedNote.richMetadata?.socialPost?.hasVideo).toBe(false);
    expect(ingestedNote.richMetadata?.socialPost?.attachments).toHaveLength(2);
  });
});
