import {
  getAssetAspectRatio,
  isGitHubRepoAsset,
  isSocialPostAsset,
  socialPlatformDisplayName,
} from '@charkle/shared';
import type { AssetRecord } from '@charkle/shared';
import { formatDuration } from '../../design-system';

export function isColorSwatchAsset(asset: AssetRecord): boolean {
  return (
    asset.mediaKind === 'document' &&
    (asset.mimeType === 'application/x-charkle-swatch' ||
      asset.fileName.toLowerCase().endsWith('.swatch') ||
      (asset.tags.includes('色卡') &&
        asset.dominantColors.length === 1 &&
        asset.pixelWidth === asset.pixelHeight))
  );
}

/**
 * Exact card aspect ratio formula matching `PARITY_SPEC.md` §5.2.
 */
export function getCardEffectiveAspectRatio(asset: AssetRecord): number {
  if (asset.mediaKind === 'audio') return 1.55;
  if (isSocialPostAsset(asset)) {
    return asset.pixelWidth > 0 && asset.pixelHeight > 0 ? getAssetAspectRatio(asset) : 1.12;
  }
  if (isGitHubRepoAsset(asset)) return 1.32;
  if (asset.mediaKind === 'webBookmark') return 1.25;
  if (isColorSwatchAsset(asset)) return 1.0;
  if (asset.mediaKind === 'document') return 0.84;
  if (asset.mediaKind === 'model3D') {
    return asset.pixelWidth > 0 && asset.pixelHeight > 0 ? getAssetAspectRatio(asset) : 1.0;
  }
  return getAssetAspectRatio(asset);
}

/**
 * Top-right media pill badge text matching `PARITY_SPEC.md` §5.2.
 */
export function getCardMediaBadge(asset: AssetRecord): string | null {
  if (asset.mediaKind === 'image') return null;
  if (asset.mediaKind === 'animatedImage') return 'GIF';
  if (asset.mediaKind === 'video') {
    return asset.durationSeconds ? formatDuration(asset.durationSeconds) : 'VIDEO';
  }
  if (asset.mediaKind === 'audio') return 'AUDIO';
  if (isGitHubRepoAsset(asset)) return 'GITHUB';
  if (asset.richMetadata?.socialPost) {
    return socialPlatformDisplayName(asset.richMetadata.socialPost.platform).toUpperCase();
  }
  if (asset.mediaKind === 'webBookmark') return 'WEB';
  if (asset.mediaKind === 'model3D') {
    return (asset.richMetadata?.model3DFormat || '3D').toUpperCase();
  }
  if (isColorSwatchAsset(asset)) return null;
  if (asset.mediaKind === 'document' || asset.mediaKind === 'designFile') {
    const dot = asset.fileName.lastIndexOf('.');
    const ext = dot >= 0 ? asset.fileName.slice(dot + 1).toUpperCase() : 'DOC';
    return ext.slice(0, 6);
  }
  return null;
}
