import { describe, expect, it } from 'vitest';
import {
  detectMediaKind,
  getEffectiveSocialAttachments,
  mediaKindLocalizedLabel,
} from '../src/models/core.js';
import type { SocialPostMetadata } from '../src/models/core.js';
import {
  activeStorageLocationSummary,
  createDefaultDriveSyncConfig,
  extractGoogleDriveFolderID,
} from '../src/models/sync.js';

describe('DriveSyncConfig & Core model helpers', () => {
  it('extracts Google Drive folder IDs from URLs and raw IDs, rejecting invalid inputs', () => {
    expect(
      extractGoogleDriveFolderID('https://drive.google.com/drive/folders/1aBcDeFgHiJkLmNoPqRsTuVwXyZ'),
    ).toBe('1aBcDeFgHiJkLmNoPqRsTuVwXyZ');

    expect(
      extractGoogleDriveFolderID(
        'https://drive.google.com/drive/u/0/folders/1aBc_DeFg-HiJk?usp=sharing',
      ),
    ).toBe('1aBc_DeFg-HiJk');

    expect(
      extractGoogleDriveFolderID('https://drive.google.com/open?id=1XyZ9876_abcd-EFGH'),
    ).toBe('1XyZ9876_abcd-EFGH');

    expect(extractGoogleDriveFolderID('  1RawDriveFolderID_99  ')).toBe('1RawDriveFolderID_99');

    // Invalid inputs
    expect(extractGoogleDriveFolderID('')).toBeNull();
    expect(extractGoogleDriveFolderID('   ')).toBeNull();
    expect(extractGoogleDriveFolderID('abc')).toBeNull(); // shorter than 4 chars
    expect(extractGoogleDriveFolderID('https://example.com/drive/folders/1aBcDeFgHiJk')).toBeNull();
    expect(extractGoogleDriveFolderID('https://drive.google.com/drive/my-drive')).toBeNull();
    expect(extractGoogleDriveFolderID('Design/Charkle')).toBeNull();
    expect(extractGoogleDriveFolderID('has space id')).toBeNull();
  });

  it('formats activeStorageLocationSummary cleanly for every transport mode', () => {
    expect(
      activeStorageLocationSummary(
        createDefaultDriveSyncConfig({
          mode: 'directAPIWithGDirect',
          rootFolderName: '/Design/Charkle/',
        }),
      ),
    ).toBe('Google Drive / Design/Charkle');

    expect(
      activeStorageLocationSummary(
        createDefaultDriveSyncConfig({
          mode: 'directAPIWithGDirect',
          sharedFolderURLOrID: 'https://drive.google.com/drive/folders/1AbCdEfGhIjKlMnOpQr',
        }),
      ),
    ).toBe('Google Drive 共享目录 (1AbCdEfGhI…)');

    expect(
      activeStorageLocationSummary(
        createDefaultDriveSyncConfig({
          mode: 'webDAV',
          webDAVServerURL: 'https://dav.jianguoyun.com/dav/',
          webDAVRemotePath: '/Design/Charkle',
        }),
      ),
    ).toBe('WebDAV (dav.jianguoyun.com) / Design/Charkle');

    expect(
      activeStorageLocationSummary(
        createDefaultDriveSyncConfig({
          mode: 'gdirectMount',
          mountPath: '/Users/char/GoogleDrive',
          rootFolderName: 'Charkle',
        }),
      ),
    ).toBe('/Users/char/GoogleDrive/Charkle');

    expect(
      activeStorageLocationSummary(
        createDefaultDriveSyncConfig({
          mode: 'localOnly',
          localLibraryPath: '/data/library',
        }),
      ),
    ).toBe('/data/library');

    expect(
      activeStorageLocationSummary(
        createDefaultDriveSyncConfig({
          mode: 'localOnly',
          localLibraryPath: '/data/library',
        }),
        'cloudflare',
      ),
    ).toBe('内置云存储');
  });

  it('detects all 8 MediaKind categories and synthesizes legacy social attachments', () => {
    expect(detectMediaKind('gif')).toBe('animatedImage');
    expect(detectMediaKind('.PNG')).toBe('image');
    expect(detectMediaKind('mp4')).toBe('video');
    expect(detectMediaKind('webloc')).toBe('webBookmark');
    expect(detectMediaKind('md')).toBe('document');
    expect(detectMediaKind('fig')).toBe('designFile');
    expect(detectMediaKind('flac')).toBe('audio');
    expect(detectMediaKind('glb')).toBe('model3D');
    expect(detectMediaKind('unknown', 'image/svg+xml')).toBe('designFile');
    expect(detectMediaKind('unknown', 'model/gltf-binary')).toBe('model3D');
    expect(mediaKindLocalizedLabel('model3D')).toBe('3D 模型');

    const legacyPost: SocialPostMetadata = {
      platform: 'x',
      authorName: 'Tester',
      authorHandle: 'tester',
      bodyText: 'Hello',
      mediaURLs: ['https://pbs.twimg.com/media/abc.jpg'],
      mediaThumbnailURLs: ['https://pbs.twimg.com/ext_tw_video_thumb/1/img.jpg'],
      attachments: [],
      hasVideo: true,
      videoURL: 'https://video.twimg.com/ext_tw_video/1/vid.mp4',
      originalURL: 'https://x.com/tester/status/123',
      mediaFetchFailed: false,
    };
    const effective = getEffectiveSocialAttachments(legacyPost);
    expect(effective).toHaveLength(2);
    expect(effective[0].kind).toBe('video');
    expect(effective[1].kind).toBe('photo');
  });
});
