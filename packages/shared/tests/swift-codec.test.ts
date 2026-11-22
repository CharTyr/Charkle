import { describe, expect, it } from 'vitest';
import { labFromHex } from '../src/color/lab.js';
import { createDefaultAssetRecord } from '../src/models/core.js';
import type { FolderRecord } from '../src/models/core.js';
import { createDefaultAutoLayoutConfig, createDefaultMoodboardDocument } from '../src/models/moodboard.js';
import type { SyncLogLine, SyncManifest } from '../src/models/sync.js';
import {
  COCOA_REFERENCE_EPOCH_UNIX_SECONDS,
  SwiftWireCodec,
  cocoaSecondsToIso,
  encodeBase64Utf8,
  isoToCocoaSeconds,
  parseOpsShardFileName,
} from '../src/sync/swift-codec.js';

describe('SwiftWireCodec (/.charkle/ bidirectional macOS sync)', () => {
  it('converts between ISO-8601 and Cocoa reference date seconds losslessly', () => {
    expect(COCOA_REFERENCE_EPOCH_UNIX_SECONDS).toBe(978_307_200);
    expect(isoToCocoaSeconds('2001-01-01T00:00:00.000Z')).toBe(0);
    expect(cocoaSecondsToIso(0)).toBe('2001-01-01T00:00:00.000Z');

    // Verified against Swift JSONEncoder: Date(timeIntervalSince1970: 1700000000) == 721692800
    const iso = new Date(1_700_000_000 * 1000).toISOString();
    expect(isoToCocoaSeconds(iso)).toBe(721_692_800);
    expect(cocoaSecondsToIso(721_692_800)).toBe(iso);
  });

  it('round-trips MoodboardDocument with all BoardNodeKind & BoardLayoutMode variants in Swift wire JSON', () => {
    const assetID = '550e8400-e29b-41d4-a716-446655440000';
    const doc = createDefaultMoodboardDocument({
      id: '11111111-2222-4333-8444-555555555555',
      title: 'Editorial Direction',
      subtitle: 'Autumn Campaign',
      mode: {
        type: 'autoEditorial',
        config: createDefaultAutoLayoutConfig({ style: 'magazine', columns: 3, spacing: 20 }),
      },
      nodes: [
        {
          id: 'aaaaaaaa-1111-4111-8111-111111111111',
          kind: {
            type: 'assetRef',
            assetID,
            crop: { x: 0.1, y: 0.2, width: 0.5, height: 0.6 },
            weight: 2,
            autoplayLoop: true,
          },
          frame: { x: 20, y: 30, width: 320, height: 240 },
          zIndex: 1,
          rotationDegrees: 0,
          flipHorizontal: false,
          flipVertical: true,
          isLocked: false,
          editorialOrder: 0,
          updatedAt: '2026-11-22T12:00:00.000Z',
        },
        {
          id: 'bbbbbbbb-2222-4222-8222-222222222222',
          kind: {
            type: 'note',
            title: 'Key Quote',
            text: '光线质感与胶片颗粒',
            style: 'warm',
            fontSize: 16,
          },
          frame: { x: 360, y: 30, width: 220, height: 150 },
          zIndex: 2,
          rotationDegrees: -2.5,
          flipHorizontal: false,
          flipVertical: false,
          isLocked: false,
          editorialOrder: 1,
          updatedAt: '2026-11-22T12:00:00.000Z',
        },
        {
          id: 'cccccccc-3333-4333-8333-333333333333',
          kind: { type: 'groupFrame', title: 'Material Study', tint: 'terracotta' },
          frame: { x: 10, y: 300, width: 600, height: 80 },
          zIndex: 0,
          rotationDegrees: 0,
          flipHorizontal: false,
          flipVertical: false,
          isLocked: true,
          editorialOrder: 2,
          updatedAt: '2026-11-22T12:00:00.000Z',
        },
        {
          id: 'dddddddd-4444-4444-8444-444444444444',
          kind: {
            type: 'paletteStrip',
            colors: [labFromHex('#3B82F6', 0.6), labFromHex('#E05A47', 0.4)],
            autoSyncWithBoard: true,
          },
          frame: { x: 10, y: 400, width: 600, height: 76 },
          zIndex: 3,
          rotationDegrees: 0,
          flipHorizontal: false,
          flipVertical: false,
          isLocked: false,
          editorialOrder: 3,
          updatedAt: '2026-11-22T12:00:00.000Z',
        },
      ],
      connectors: [
        {
          id: 'eeeeeeee-5555-4555-8555-555555555555',
          fromNodeID: 'bbbbbbbb-2222-4222-8222-222222222222',
          fromAnchor: 'leading',
          fromNormalizedPoint: null,
          toNodeID: 'aaaaaaaa-1111-4111-8111-111111111111',
          toAnchor: 'auto',
          toNormalizedPoint: { x: 0.42, y: 0.35 },
          label: '主光方向',
          colorHex: '#E05A47',
          style: 'curved',
          dashed: true,
          updatedAt: '2026-11-22T12:01:00.000Z',
        },
      ],
      inkStrokes: [
        {
          id: 'ffffffff-6666-4666-8666-666666666666',
          points: [
            { x: 10, y: 12, pressure: 0.6 },
            { x: 45, y: 58, pressure: 0.8 },
          ],
          colorHex: '#E05A47',
          lineWidth: 3.5,
          opacity: 0.9,
          zIndex: 1000,
          createdAt: '2026-11-22T12:02:00.000Z',
        },
      ],
      extractedPalette: [labFromHex('#3B82F6')],
      candidateAssetIDs: [assetID],
      pinnedOffline: true,
      viewportCenter: { x: 520, y: 310 },
      viewportZoom: 1.25,
      createdAt: '2026-11-22T11:00:00.000Z',
      updatedAt: '2026-11-22T12:05:00.000Z',
      updatedHLC: 1_795_349_100_000_000,
    });

    const wireString = SwiftWireCodec.stringifyMoodboardDocument(doc);
    const wireObj = JSON.parse(wireString) as Record<string, unknown>;

    // Verify exact Swift JSONEncoder wire shape
    expect(wireObj.id).toBe('11111111-2222-4333-8444-555555555555');
    expect(wireObj.mode).toEqual({
      autoEditorial: {
        _0: { columns: 3, showPaletteStrip: true, spacing: 20, style: 'magazine' },
      },
    });
    expect(typeof wireObj.createdAt).toBe('number');
    expect(wireObj.candidateAssetIDs).toEqual(['550E8400-E29B-41D4-A716-446655440000']);

    const decoded = SwiftWireCodec.parseMoodboardDocument(wireString);
    expect(decoded.mode).toEqual(doc.mode);
    expect(decoded.nodes[0].id).toBe('AAAAAAAA-1111-4111-8111-111111111111');
    expect(decoded.nodes[0].kind).toEqual({
      type: 'assetRef',
      assetID: '550E8400-E29B-41D4-A716-446655440000',
      crop: { x: 0.1, y: 0.2, width: 0.5, height: 0.6 },
      weight: 2,
      autoplayLoop: true,
    });
    expect(decoded.nodes[1].kind).toEqual(doc.nodes[1].kind);
    expect(decoded.nodes[2].kind).toEqual(doc.nodes[2].kind);
    expect(decoded.nodes[3].kind).toEqual(doc.nodes[3].kind);
    expect(decoded.connectors[0].toNormalizedPoint).toEqual({ x: 0.42, y: 0.35 });
    expect(decoded.inkStrokes[0].points).toHaveLength(2);
    expect(decoded.createdAt).toBe('2026-11-22T11:00:00.000Z');
    expect(decoded.updatedAt).toBe('2026-11-22T12:05:00.000Z');
  });

  it('decodes authentic Swift JSONEncoder fixture ops JSONL across all 7 SyncOperation.Change cases', () => {
    const device = '0123456789abcdef0123456789abcdef';
    const assetID = '550E8400-E29B-41D4-A716-446655440000';
    const boardID = '660E8400-E29B-41D4-A716-446655440001';
    const folderID = '770E8400-E29B-41D4-A716-446655440002';

    // Exact Swift JSONEncoder output fixture for SyncLogLine NDJSON
    const swiftOpsFixture = [
      JSON.stringify({
        seq: 1,
        operation: {
          stamp: { time: 1740000000000, device },
          change: {
            asset: {
              _0: {
                id: assetID,
                fields: {
                  title: encodeBase64Utf8('"海报参考"'),
                  folderID: encodeBase64Utf8('null'),
                  createdAt: encodeBase64Utf8('721692800'),
                  rating: encodeBase64Utf8('5'),
                },
                tagsAdded: ['平面设计', '海报'],
                tagsRemoved: ['草稿'],
              },
            },
          },
        },
      }),
      JSON.stringify({
        seq: 2,
        operation: {
          stamp: { time: 1740000000001, device },
          change: {
            board: {
              _0: {
                id: boardID,
                fields: {
                  title: encodeBase64Utf8('"Brand Board"'),
                  mode: encodeBase64Utf8('{"freeform":{}}'),
                },
                nodes: { updated: [], removed: ['880E8400-E29B-41D4-A716-446655440003'] },
                connectors: { updated: [], removed: [] },
                strokes: { updated: [], removed: [] },
              },
            },
          },
        },
      }),
      JSON.stringify({
        seq: 3,
        operation: {
          stamp: { time: 1740000000002, device },
          projectLocation: false,
          change: {
            folder: {
              _0: {
                id: folderID,
                name: 'Typography',
                sortOrder: 2,
                assetCount: 0,
                createdAt: 721692800,
                updatedAt: 721692800,
              },
            },
          },
        },
      }),
      JSON.stringify({
        seq: 4,
        operation: {
          stamp: { time: 1740000000003, device },
          change: { deleteAsset: { _0: assetID, driveID: 'drv-file-123' } },
        },
      }),
      JSON.stringify({
        seq: 5,
        operation: {
          stamp: { time: 1740000000004, device },
          change: { deleteBoard: { _0: boardID } },
        },
      }),
      JSON.stringify({
        seq: 6,
        operation: {
          stamp: { time: 1740000000005, device },
          change: { deleteFolder: { _0: folderID } },
        },
      }),
      JSON.stringify({
        seq: 7,
        operation: {
          stamp: { time: 1740000000006, device },
          change: {
            vector: {
              _0: assetID,
              _1: {
                featurePrint: 'AQIDBA==',
                embedding: [0.25, -0.5, 0.75],
                embeddingModel: 'gemini-embedding-001',
                precision: 16,
              },
            },
          },
        },
      }),
    ].join('\n');

    const decoded = SwiftWireCodec.decodeOpsJsonl(swiftOpsFixture);
    expect(decoded).toHaveLength(7);

    // 1. Asset change with Base64 SyncFields
    expect(decoded[0].seq).toBe(1);
    expect(decoded[0].operation.change.type).toBe('asset');
    if (decoded[0].operation.change.type === 'asset') {
      expect(decoded[0].operation.change.delta.fields).toEqual({
        title: '海报参考',
        folderID: null,
        createdAt: cocoaSecondsToIso(721_692_800),
        rating: 5,
      });
      expect(decoded[0].operation.change.delta.tagsAdded).toEqual(['平面设计', '海报']);
      expect(decoded[0].operation.change.delta.tagsRemoved).toEqual(['草稿']);
    }

    // 2. Board change with freeform mode field
    expect(decoded[1].operation.change.type).toBe('board');
    if (decoded[1].operation.change.type === 'board') {
      expect(decoded[1].operation.change.delta.fields).toEqual({
        title: 'Brand Board',
        mode: { type: 'freeform' },
      });
      expect(decoded[1].operation.change.delta.nodes.removed).toEqual([
        '880E8400-E29B-41D4-A716-446655440003',
      ]);
    }

    // 3. Folder record
    expect(decoded[2].operation.projectLocation).toBe(false);
    expect(decoded[2].operation.change.type).toBe('folder');
    if (decoded[2].operation.change.type === 'folder') {
      const folder: FolderRecord = decoded[2].operation.change.folder;
      expect(folder.name).toBe('Typography');
      expect(folder.createdAt).toBe(cocoaSecondsToIso(721_692_800));
    }

    // 4-6. Deletes
    expect(decoded[3].operation.change).toEqual({
      type: 'deleteAsset',
      id: assetID,
      driveID: 'drv-file-123',
    });
    expect(decoded[4].operation.change).toEqual({ type: 'deleteBoard', id: boardID });
    expect(decoded[5].operation.change).toEqual({
      type: 'deleteFolder',
      id: folderID,
      driveID: null,
    });

    // 7. Vector
    expect(decoded[6].operation.change).toEqual({
      type: 'vector',
      id: assetID,
      vector: {
        featurePrint: 'AQIDBA==',
        embedding: [0.25, -0.5, 0.75],
        embeddingModel: 'gemini-embedding-001',
        precision: 16,
      },
    });

    // Round-trip re-encode and re-decode must be strictly identical
    const reencoded = SwiftWireCodec.encodeOpsJsonl(decoded);
    const redecoded: SyncLogLine[] = SwiftWireCodec.decodeOpsJsonl(reencoded);
    expect(redecoded).toEqual(decoded);
  });

  it('encodes & decodes SyncManifest, ops shard filenames, and diffs SyncFields', () => {
    const manifest: SyncManifest = {
      version: 1,
      rootFolderID: 'drv-root-1',
      directories: {
        Inbox: 'drv-inbox',
        ops: 'drv-ops',
        boards: 'drv-boards',
        embeddings: 'drv-emb',
        thumbnails: 'drv-thumb',
      },
    };
    const encoded = SwiftWireCodec.encodeManifest(manifest);
    expect(SwiftWireCodec.decodeManifest(encoded)).toEqual(manifest);

    expect(parseOpsShardFileName('ops-0123456789abcdef0123456789abcdef-42.jsonl')).toEqual({
      device: '0123456789abcdef0123456789abcdef',
      endSeq: 42,
    });
    expect(parseOpsShardFileName('ops-short-42.jsonl')).toBeNull();
    expect(parseOpsShardFileName('ops-0123456789abcdef0123456789abcdef-0.jsonl')).toBeNull();

    const before = createDefaultAssetRecord({
      id: '550E8400-E29B-41D4-A716-446655440000',
      title: 'Old',
      fileName: 'old.png',
      folderID: '770E8400-E29B-41D4-A716-446655440002',
      createdAt: '2026-11-22T10:00:00.000Z',
      updatedAt: '2026-11-22T10:00:00.000Z',
    });
    const after = {
      ...before,
      title: 'New',
      folderID: null,
      isLocalOriginalCached: true, // excluded from sync fields
      updatedAt: '2026-11-22T12:00:00.000Z', // excluded from sync fields
    };
    const diff = SwiftWireCodec.diffSyncFields('asset', after, before);
    expect(diff).toEqual({
      title: 'New',
      folderID: null,
    });
  });
});
