import crypto from 'node:crypto';
import path from 'node:path';
import JSZip from 'jszip';
import sharp from 'sharp';
import {
  clampCropRect,
  createDefaultMoodboardExportOptions,
  FULL_CROP_RECT,
  isLightHex,
  labFromHex,
  mediaKindLocalizedLabel,
  solveEditorialLayout,
  type AssetRecord,
  type BoardRect,
  type FigmaBridgeBoardManifest,
  type FigmaBridgeObject,
  type FigmaBridgeObjectGeometry,
  type FigmaBridgeReport,
  type FigmaBridgeTile,
  type GroupTint,
  type MoodboardDocument,
  type MoodboardExportOptions,
  type NoteStyle,
  type ThumbnailTier,
  type UUID,
} from '@charkle/shared';

const TILE_LIMIT = 4096;

export class FigmaBridgeExportError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'FigmaBridgeExportError';
  }
}

export interface FigmaBridgeExportResult {
  zipBuffer: Buffer;
  manifest: FigmaBridgeBoardManifest;
  report: FigmaBridgeReport;
}

export interface FigmaBridgeExportParams {
  document: MoodboardDocument;
  assetsByID: ReadonlyMap<UUID, AssetRecord> | Record<UUID, AssetRecord>;
  containerWidth?: number;
  options?: Partial<MoodboardExportOptions>;
  loadOriginalBuffer: (assetID: UUID) => Promise<{ buffer: Buffer; fileName?: string } | null>;
  loadThumbnailBuffer: (assetID: UUID, tier: ThumbnailTier) => Promise<Buffer | null>;
}

function sha256Hex(data: Buffer): string {
  return crypto.createHash('sha256').update(data).digest('hex');
}

function lookupAsset(
  assetsByID: ReadonlyMap<UUID, AssetRecord> | Record<UUID, AssetRecord>,
  id: UUID,
): AssetRecord | undefined {
  return assetsByID instanceof Map
    ? assetsByID.get(id)
    : (assetsByID as Record<UUID, AssetRecord>)[id];
}

function geometryObj(
  rect: BoardRect,
  angle: number,
  flipX: boolean,
  flipY: boolean,
): FigmaBridgeObjectGeometry {
  return {
    x: rect.x,
    y: rect.y,
    width: rect.width,
    height: rect.height,
    angle,
    flipX,
    flipY,
  };
}

function noteStyleHex(style: NoteStyle): { background: string; foreground: string; border: string } {
  switch (style) {
    case 'paper':
      return { background: '#FFFFFF', foreground: '#1D1F23', border: '#D9DBDE' };
    case 'ink':
      return { background: '#1D1F24', foreground: '#F1F2F4', border: '#3A3D45' };
    case 'warm':
      return { background: '#F7F0E4', foreground: '#392F22', border: '#C9B79C' };
    case 'sage':
      return { background: '#E8F0EA', foreground: '#203227', border: '#9AB5A3' };
    case 'slate':
      return { background: '#E9EEF3', foreground: '#1F2B36', border: '#9EB0C2' };
  }
}

function groupTintHex(tint: GroupTint): string {
  switch (tint) {
    case 'neutral':
      return '#7D838B';
    case 'sand':
      return '#B5956B';
    case 'sage':
      return '#6B8E76';
    case 'slate':
      return '#627A94';
    case 'terracotta':
      return '#BA6B55';
    case 'ocean':
      return '#4D7E97';
  }
}

function sanitizeSafeToken(input: string): string {
  return input.replace(/[^A-Za-z0-9._-]/g, '_');
}

function shortStableHash(input: string): string {
  return crypto.createHash('sha256').update(input).digest('hex').slice(0, 8);
}

interface DecodedRaster {
  rawBuffer: Buffer;
  width: number;
  height: number;
  channels: 1 | 2 | 3 | 4;
  frameCount: number;
}

async function decodeUprightRaster(data: Buffer): Promise<DecodedRaster | null> {
  try {
    let frameCount = 1;
    try {
      const animMeta = await sharp(data, { animated: true, limitInputPixels: false }).metadata();
      frameCount = Math.max(1, animMeta.pages ?? 1);
    } catch {
      frameCount = 1;
    }

    const decoded = await sharp(data, { animated: false, page: 0, limitInputPixels: false })
      .rotate()
      .ensureAlpha()
      .raw()
      .toBuffer({ resolveWithObject: true });

    if (!decoded.info.width || !decoded.info.height) return null;
    return {
      rawBuffer: decoded.data,
      width: decoded.info.width,
      height: decoded.info.height,
      channels: decoded.info.channels,
      frameCount,
    };
  } catch {
    return null;
  }
}

async function writeLosslessTiles(
  raster: { rawBuffer: Buffer; width: number; height: number; channels: 1 | 2 | 3 | 4 },
  zip: JSZip,
  prefix: string,
): Promise<FigmaBridgeTile[]> {
  const tiles: FigmaBridgeTile[] = [];
  const safePrefix = sanitizeSafeToken(prefix);

  for (let y = 0; y < raster.height; y += TILE_LIMIT) {
    for (let x = 0; x < raster.width; x += TILE_LIMIT) {
      const w = Math.min(TILE_LIMIT, raster.width - x);
      const h = Math.min(TILE_LIMIT, raster.height - y);
      const tilePng = await sharp(raster.rawBuffer, {
        raw: {
          width: raster.width,
          height: raster.height,
          channels: raster.channels,
        },
        limitInputPixels: false,
      })
        .extract({ left: x, top: y, width: w, height: h })
        .png({ compressionLevel: 6 })
        .toBuffer();

      const relPath = `tiles/${safePrefix}-${x}-${y}.png`;
      zip.file(relPath, tilePng, { compression: 'STORE' });
      tiles.push({
        file: relPath,
        x,
        y,
        width: w,
        height: h,
        sha256: sha256Hex(tilePng),
      });
    }
  }
  return tiles;
}

/**
 * Exact 1:1 port of macOS `FigmaBridgeExporter.swift` producing offline lossless
 * `.charkleboard` ZIP archives 100% validated by `figma-plugin/code.js` & `figma-plugin/ui.html`.
 */
export const FigmaBridgeExporter = {
  async exportBundle(params: FigmaBridgeExportParams): Promise<FigmaBridgeExportResult> {
    const {
      document,
      assetsByID,
      containerWidth = 1120,
      loadOriginalBuffer,
      loadThumbnailBuffer,
    } = params;
    const options = createDefaultMoodboardExportOptions(params.options ?? {});

    const resolvedFrames: Record<UUID, BoardRect> =
      document.mode.type === 'autoEditorial'
        ? solveEditorialLayout(document.nodes, document.mode.config, containerWidth, assetsByID)
            .frames
        : Object.fromEntries(document.nodes.map((n) => [n.id, n.frame]));

    const orderedNodes = [...document.nodes].sort((lhs, rhs) => {
      const lGroup = lhs.kind.type === 'groupFrame' ? 0 : 1;
      const rGroup = rhs.kind.type === 'groupFrame' ? 0 : 1;
      if (lGroup !== rGroup) return lGroup - rGroup;
      if (lhs.zIndex !== rhs.zIndex) return lhs.zIndex - rhs.zIndex;
      return lhs.editorialOrder - rhs.editorialOrder;
    });

    const zip = new JSZip();
    const objects: FigmaBridgeObject[] = [];
    const warnings: Array<{ id: string; name: string; issues: string[] }> = [];
    const originals: FigmaBridgeBoardManifest['originals'] = [];
    const archivedOriginals = new Map<UUID, { file: string; sha256: string; isGIF: boolean }>();
    const cachedTilePayloads = new Map<string, NonNullable<FigmaBridgeObject['image']>>();

    let imageCount = 0;
    let noteCount = 0;
    let groupCount = 0;
    let paletteCount = 0;

    // Optional top Board Palette Strip placed cleanly above content bounds
    if (options.includePaletteStrip && document.extractedPalette.length > 0) {
      const frameValues = Object.values(resolvedFrames).filter((r) => r.width > 0 && r.height > 0);
      const minX = frameValues.length > 0 ? Math.min(...frameValues.map((r) => r.x)) : 0;
      const minY = frameValues.length > 0 ? Math.min(...frameValues.map((r) => r.y)) : 0;
      const maxX =
        frameValues.length > 0 ? Math.max(...frameValues.map((r) => r.x + r.width)) : 800;
      const stripW = Math.max(320, Math.min(560, maxX - minX));
      const stripH = 54;
      const swatches = document.extractedPalette.slice(0, 7).map((sw) => {
        const hex = sw.hex.toUpperCase();
        return { hex, isLight: isLightHex(hex) };
      });
      objects.push({
        id: 'board-palette-header',
        kind: 'paletteStrip',
        name: '板内色卡',
        locked: false,
        geometry: geometryObj({ x: minX, y: minY - stripH - 24, width: stripW, height: stripH }, 0, false, false),
        palette: { swatches },
        warnings: [],
      });
      paletteCount += 1;
    }

    for (const node of orderedNodes) {
      const frame = resolvedFrames[node.id];
      if (!frame || frame.width <= 0 || frame.height <= 0) continue;
      const geom = geometryObj(
        frame,
        node.rotationDegrees,
        node.flipHorizontal,
        node.flipVertical,
      );

      if (node.kind.type === 'assetRef') {
        const assetID = node.kind.assetID;
        const asset = lookupAsset(assetsByID, assetID);
        const displayName = asset?.title || '素材';
        const itemWarnings: string[] = [];

        const original = await loadOriginalBuffer(assetID);
        let fallbackPreview: Buffer | null = null;
        if (!original) {
          fallbackPreview =
            (await loadThumbnailBuffer(assetID, 'preview1400')) ??
            (await loadThumbnailBuffer(assetID, 'grid520'));
        }

        const fileData = original?.buffer ?? fallbackPreview;
        if (!fileData || fileData.length === 0) {
          itemWarnings.push('素材原图与预览图均未缓存在本地，无法导入像素');
          warnings.push({ id: node.id, name: displayName, issues: itemWarnings });
          objects.push({
            id: node.id,
            kind: 'unsupported',
            name: displayName,
            locked: node.isLocked,
            geometry: geom,
            warnings: itemWarnings,
          });
          continue;
        }

        if (!original) {
          itemWarnings.push('原文件未缓存在本地，已使用高清预览图导出');
        }

        // Archive original file verbatim in `originals/`
        let archivedInfo = archivedOriginals.get(assetID);
        if (!archivedInfo) {
          const rawFileName = asset?.fileName || original?.fileName || `${assetID}.jpg`;
          const rawExt = path.extname(rawFileName).replace(/^\./, '').toLowerCase();
          const safeExt = rawExt.replace(/[^a-z0-9]/g, '') || (original ? 'bin' : 'jpg');
          const safeAssetID = sanitizeSafeToken(assetID);
          const fileName = `${safeAssetID}.${safeExt}`;
          const relPath = `originals/${fileName}`;
          zip.file(relPath, fileData, { compression: 'STORE' });
          const digest = sha256Hex(fileData);
          const isGIF = safeExt === 'gif' || asset?.mediaKind === 'animatedImage';
          originals.push({
            id: assetID,
            name: asset?.fileName || fileName,
            file: relPath,
            sha256: digest,
            bytes: fileData.length,
          });
          archivedInfo = { file: relPath, sha256: digest, isGIF };
          archivedOriginals.set(assetID, archivedInfo);
        }

        // Decode upright raster (or fallback thumbnail for video/PDF/design docs)
        let decoded = await decodeUprightRaster(fileData);
        let isAnimatedGIF = archivedInfo.isGIF && (decoded?.frameCount ?? 0) > 1;
        if (!decoded) {
          const thumbBuf =
            (await loadThumbnailBuffer(assetID, 'preview1400')) ??
            (await loadThumbnailBuffer(assetID, 'grid520'));
          if (thumbBuf && thumbBuf.length > 0) {
            decoded = await decodeUprightRaster(thumbBuf);
            const label = asset ? mediaKindLocalizedLabel(asset.mediaKind) : '附件';
            itemWarnings.push(
              `非静态图片素材（${label}）已以静态预览导出，原始文件已归档在 originals/`,
            );
            isAnimatedGIF = false;
          }
        }

        if (!decoded) {
          itemWarnings.push('无法解码该素材的画面像素，原始文件已归档在 originals/');
          warnings.push({ id: node.id, name: displayName, issues: itemWarnings });
          objects.push({
            id: node.id,
            kind: 'unsupported',
            name: displayName,
            locked: node.isLocked,
            geometry: geom,
            warnings: itemWarnings,
          });
          continue;
        }

        // Apply non-destructive crop if set
        let workingRaster = decoded;
        const crop = node.kind.crop;
        let cropKey = 'full';
        if (
          crop &&
          crop.width > 0.05 &&
          crop.height > 0.05 &&
          !(
            crop.x === FULL_CROP_RECT.x &&
            crop.y === FULL_CROP_RECT.y &&
            crop.width === FULL_CROP_RECT.width &&
            crop.height === FULL_CROP_RECT.height
          )
        ) {
          const c = clampCropRect(crop);
          const rx = Math.max(0, Math.min(decoded.width - 1, Math.floor(c.x * decoded.width)));
          const ry = Math.max(0, Math.min(decoded.height - 1, Math.floor(c.y * decoded.height)));
          const rw = Math.max(1, Math.min(decoded.width - rx, Math.round(c.width * decoded.width)));
          const rh = Math.max(1, Math.min(decoded.height - ry, Math.round(c.height * decoded.height)));
          const cropped = await sharp(decoded.rawBuffer, {
            raw: { width: decoded.width, height: decoded.height, channels: decoded.channels },
            limitInputPixels: false,
          })
            .extract({ left: rx, top: ry, width: rw, height: rh })
            .raw()
            .toBuffer({ resolveWithObject: true });

          workingRaster = {
            rawBuffer: cropped.data,
            width: cropped.info.width,
            height: cropped.info.height,
            channels: cropped.info.channels,
            frameCount: decoded.frameCount,
          };
          cropKey = `${c.x.toFixed(3)}-${c.y.toFixed(3)}-${c.width.toFixed(3)}-${c.height.toFixed(3)}`;
        }

        const tileCacheKey = `${assetID}-${cropKey}`;
        let imagePayload = cachedTilePayloads.get(tileCacheKey);
        if (!imagePayload) {
          const prefix =
            cropKey === 'full'
              ? sanitizeSafeToken(assetID)
              : `${sanitizeSafeToken(assetID)}-C${shortStableHash(cropKey)}`;
          const tiles = await writeLosslessTiles(workingRaster, zip, prefix);
          imagePayload = {
            pixelWidth: workingRaster.width,
            pixelHeight: workingRaster.height,
            tiles,
            animated: isAnimatedGIF && cropKey === 'full' && archivedInfo.file.toLowerCase().endsWith('.gif'),
          };
          if (imagePayload.animated) {
            imagePayload.animation = {
              file: archivedInfo.file,
              sha256: archivedInfo.sha256,
            };
          }
          cachedTilePayloads.set(tileCacheKey, imagePayload);
        }

        if (imagePayload.animation) {
          itemWarnings.push('动画 GIF 在 Figma Design 中以静态首帧导入，原始 GIF 已归档');
        }

        if (itemWarnings.length > 0) {
          warnings.push({ id: node.id, name: displayName, issues: itemWarnings });
        }

        objects.push({
          id: node.id,
          kind: 'image',
          name: displayName,
          cornerRadius: 12,
          locked: node.isLocked,
          geometry: geom,
          image: imagePayload,
          warnings: itemWarnings,
        });
        imageCount += 1;
      } else if (node.kind.type === 'note') {
        const hex = noteStyleHex(node.kind.style);
        const trimmedTitle = node.kind.title?.trim() ?? '';
        const noteName = trimmedTitle || node.kind.text.slice(0, 24) || '灵感便签';
        objects.push({
          id: node.id,
          kind: 'note',
          name: noteName,
          locked: node.isLocked,
          geometry: geom,
          note: {
            title: node.kind.title ?? '',
            text: node.kind.text,
            style: node.kind.style,
            fontSize: node.kind.fontSize,
            backgroundHex: hex.background,
            foregroundHex: hex.foreground,
            borderHex: hex.border,
          },
          warnings: [],
        });
        noteCount += 1;
      } else if (node.kind.type === 'groupFrame') {
        objects.push({
          id: node.id,
          kind: 'groupFrame',
          name: node.kind.title || '分组区域',
          locked: node.isLocked,
          geometry: geom,
          group: {
            title: node.kind.title,
            tint: node.kind.tint,
            accentHex: groupTintHex(node.kind.tint),
          },
          warnings: [],
        });
        groupCount += 1;
      } else if (node.kind.type === 'paletteStrip') {
        const activeColors =
          node.kind.autoSyncWithBoard && document.extractedPalette.length > 0
            ? document.extractedPalette
            : node.kind.colors;
        const sourceColors = activeColors.length > 0 ? activeColors : [labFromHex('#8B95A1')];
        const swatches = sourceColors.map((sw) => {
          const hex = sw.hex.toUpperCase();
          return { hex, isLight: isLightHex(hex) };
        });
        objects.push({
          id: node.id,
          kind: 'paletteStrip',
          name: '色卡条',
          locked: node.isLocked,
          geometry: geom,
          palette: { swatches },
          warnings: [],
        });
        paletteCount += 1;
      }
    }

    if (objects.length === 0) {
      throw new FigmaBridgeExportError('当前情绪板里没有可导出的对象。');
    }

    const connectorJSONs: FigmaBridgeBoardManifest['connectors'] = [];
    const strokeJSONs: FigmaBridgeBoardManifest['inkStrokes'] = [];

    if (options.includeAnnotations) {
      const exportedIDs = new Set(objects.map((o) => o.id));
      for (const conn of document.connectors) {
        if (!exportedIDs.has(conn.fromNodeID) || !exportedIDs.has(conn.toNodeID)) continue;
        connectorJSONs.push({
          id: conn.id,
          fromNodeID: conn.fromNodeID,
          fromAnchor: conn.fromAnchor,
          toNodeID: conn.toNodeID,
          toAnchor: conn.toAnchor,
          style: conn.style,
          colorHex: conn.colorHex,
          dashed: conn.dashed,
          label: conn.label ?? '',
        });
      }
      for (const stroke of document.inkStrokes) {
        if (stroke.points.length < 2) continue;
        strokeJSONs.push({
          id: stroke.id,
          points: stroke.points.map((pt) => ({ x: pt.x, y: pt.y })),
          colorHex: stroke.colorHex,
          lineWidth: stroke.lineWidth,
          opacity: stroke.opacity,
        });
      }
    }

    const report: FigmaBridgeReport = {
      objectCount: objects.length,
      imageCount,
      noteCount,
      groupCount,
      paletteCount,
      connectorCount: connectorJSONs.length,
      strokeCount: strokeJSONs.length,
      reviewCount: warnings.length,
      warnings,
    };

    const manifest: FigmaBridgeBoardManifest = {
      format: 'charkle-figma-bridge',
      version: 1,
      boardId: document.id,
      name: document.title,
      subtitle: document.subtitle,
      mode: document.mode.type === 'autoEditorial' ? 'autoEditorial' : 'freeform',
      darkAppearance: options.darkAppearance,
      exportedAt: new Date().toISOString(),
      sourceOS: 'Charkle Web',
      objects,
      connectors: connectorJSONs,
      inkStrokes: strokeJSONs,
      originals,
      report,
    };

    zip.file('board.json', JSON.stringify(manifest, null, 2), { compression: 'DEFLATE' });
    zip.file('migration-report.json', JSON.stringify(report, null, 2), { compression: 'DEFLATE' });

    const zipBuffer = await zip.generateAsync({
      type: 'nodebuffer',
      compression: 'DEFLATE',
      compressionOptions: { level: 6 },
    });

    return { zipBuffer, manifest, report };
  },
};
