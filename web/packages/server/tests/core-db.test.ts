import crypto from 'node:crypto';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { afterEach, describe, expect, it } from 'vitest';
import {
  createDefaultAssetRecord,
  createDefaultMoodboardDocument,
  createDefaultSmartFolderRule,
  labFromHex,
  toSwiftUUID,
} from '@charkle/shared';
import {
  decodeEmbeddingBlob,
  decodeFeaturePrintFloat32,
  encodeEmbeddingBlob,
  encodeFeaturePrintFloat32,
  float16BitsToFloat32,
  float32ToFloat16Bits,
  LibraryDatabaseError,
  type LibraryDatabase,
} from '../src/db/library-database.js';
import { openNodeLibraryDatabase } from '../src/runtime/node-sql.js';

const tempDirs: string[] = [];

function makeTempDB(): LibraryDatabase {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'charkle-db-test-'));
  tempDirs.push(dir);
  return openNodeLibraryDatabase(path.join(dir, 'library.sqlite'));
}

afterEach(() => {
  while (tempDirs.length > 0) {
    const dir = tempDirs.pop()!;
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

describe('LibraryDatabase (SQLite WAL + FTS5 + Pinyin + CIELAB + Folders)', () => {
  it('opens in WAL mode and indexes FTS5 with Chinese Pinyin full & initials + rich metadata', () => {
    const db = makeTempDB();
    try {
      const modeRow = db.sql.get<{ journal_mode: string }>('PRAGMA journal_mode')!;
      expect(modeRow.journal_mode.toLowerCase()).toBe('wal');

      const a1 = createDefaultAssetRecord({
        id: toSwiftUUID(crypto.randomUUID()),
        title: '暗黑仪表盘设计',
        fileName: 'dark-dashboard.png',
        notes: '高对比度数据可视化面板',
        tags: ['暗黑UI', 'analytics'],
        rating: 5,
        fileSizeBytes: 500_000,
        dominantColors: [labFromHex('#1E4CE8', 0.7), labFromHex('#0E1015', 0.3)],
      });
      const a2 = createDefaultAssetRecord({
        id: toSwiftUUID(crypto.randomUUID()),
        title: '陶土色杂志排版',
        fileName: 'terracotta-spread.png',
        notes: '温暖纸张质感',
        tags: ['editorial', '暖色调'],
        rating: 4,
        fileSizeBytes: 900_000,
        dominantColors: [labFromHex('#C46A34', 0.8)],
        richMetadata: {
          githubRepo: {
            owner: 'acme',
            repo: 'swiss-grid',
            fullName: 'acme/swiss-grid',
            description: 'Modular typography grid engine',
            stars: 1200,
            forks: 90,
            language: 'TypeScript',
            topics: ['typography', 'layout'],
            defaultBranch: 'main',
            readmeMarkdown: 'Swiss Grid System documentation for posters.',
            fetchedAt: new Date().toISOString(),
          },
          socialPost: null,
          isMarkdown: false,
        },
      });
      db.saveAssetLocally(a1);
      db.saveAssetLocally(a2);

      // Chinese text search
      expect(db.fetchAssets({ searchQuery: '仪表盘' }).map((a) => a.id)).toEqual([a1.id]);
      // Full pinyin search
      expect(db.fetchAssets({ searchQuery: 'anhei' }).map((a) => a.id)).toEqual([a1.id]);
      // Pinyin initials search
      expect(db.fetchAssets({ searchQuery: 'ahybp' }).map((a) => a.id)).toEqual([a1.id]);
      // Rich GitHub README & topic search
      expect(db.fetchAssets({ searchQuery: 'swiss-grid' }).map((a) => a.id)).toEqual([a2.id]);
      expect(db.fetchAssets({ searchQuery: 'posters' }).map((a) => a.id)).toEqual([a2.id]);

      // CIELAB color search
      const warmMatches = db.fetchAssets({ selectedColorHex: '#C86D38', colorTolerance: 18 });
      expect(warmMatches.map((a) => a.id)).toEqual([a2.id]);

      const blueMatches = db.fetchAssets({ selectedColorHex: '#2050EA', colorTolerance: 18 });
      expect(blueMatches.map((a) => a.id)).toEqual([a1.id]);

      // All 6 sort modes execute cleanly
      expect(db.fetchAssets({ sortBy: 'ratingDesc' })[0].id).toBe(a1.id);
      expect(db.fetchAssets({ sortBy: 'fileSizeDesc' })[0].id).toBe(a2.id);
      expect(db.fetchAssets({ sortBy: 'nameAsc' })).toHaveLength(2);
      expect(db.fetchAssets({ sortBy: 'newest' })).toHaveLength(2);
      expect(db.fetchAssets({ sortBy: 'oldest' })).toHaveLength(2);
      expect(db.fetchAssets({ searchQuery: '暗黑', sortBy: 'relevance' })[0].id).toBe(a1.id);
    } finally {
      db.close();
    }
  });

  it('supports recursive subfolder CTE queries, cycle-safe moveFolder, appearance, and deleteFolder modes', () => {
    const db = makeTempDB();
    try {
      const root = db.createFolder('Design');
      const child = db.createFolder('UI', root.id);
      const grand = db.createFolder('Mobile', child.id);

      const styled = db.updateFolderAppearance(root.id, {
        colorHex: '#0A84FF',
        customSymbol: 'sf:sparkles',
      });
      expect(styled.colorHex).toBe('#0A84FF');
      expect(styled.customSymbol).toBe('sf:sparkles');
      expect(db.getFolderPath(grand.id)).toBe('Design/UI/Mobile');
      expect(db.findFolderByPath('design/ui/mobile')?.id).toBe(grand.id);

      // Cycle prevention
      expect(() => db.moveFolder(root.id, grand.id)).toThrow();

      const aRoot = db.saveAssetLocally(
        createDefaultAssetRecord({
          id: toSwiftUUID(crypto.randomUUID()),
          title: 'Root Item',
          fileName: 'r.png',
          folderID: root.id,
        }),
      );
      const aGrand = db.saveAssetLocally(
        createDefaultAssetRecord({
          id: toSwiftUUID(crypto.randomUUID()),
          title: 'Grandchild Item',
          fileName: 'g.png',
          folderID: grand.id,
        }),
      );

      // Direct vs recursive subfolder query
      expect(db.fetchAssets({ folderID: root.id, includeSubfolders: false }).map((a) => a.id)).toEqual([aRoot.id]);
      const recursive = db.fetchAssets({ folderID: root.id, includeSubfolders: true }).map((a) => a.id);
      expect(recursive).toContain(aRoot.id);
      expect(recursive).toContain(aGrand.id);

      // deleteFolder with trashContents = false -> moves direct assets to inbox, reparents children
      db.deleteFolder(root.id, false);
      expect(db.getFolder(root.id)).toBeNull();
      expect(db.getAsset(aRoot.id)?.folderID).toBeNull();
      expect(db.getAsset(aRoot.id)?.isTrashed).toBe(false);
      expect(db.getFolder(child.id)?.parentID).toBeNull();

      // deleteFolder with trashContents = true -> trashes entire subtree & removes subfolders
      db.deleteFolder(child.id, true);
      expect(db.getFolder(child.id)).toBeNull();
      expect(db.getFolder(grand.id)).toBeNull();
      expect(db.getAsset(aGrand.id)?.isTrashed).toBe(true);
      expect(db.getAsset(aGrand.id)?.folderID).toBeNull();
    } finally {
      db.close();
    }
  });

  it('tracks recentActivity locally without emitting sync ops and persists SmartFolders in sync_state', () => {
    const db = makeTempDB();
    try {
      const older = db.saveAssetLocally(
        createDefaultAssetRecord({
          id: toSwiftUUID(crypto.randomUUID()),
          title: 'Older Opened Recently',
          fileName: 'old.png',
          rating: 5,
          tags: ['poster', 'warm'],
          dominantColors: [labFromHex('#D4A373', 1)],
          createdAt: '2026-01-01T00:00:00.000Z',
        }),
      );
      const newer = db.saveAssetLocally(
        createDefaultAssetRecord({
          id: toSwiftUUID(crypto.randomUUID()),
          title: 'Newer Never Opened',
          fileName: 'new.png',
          rating: 2,
          tags: ['cool'],
          dominantColors: [labFromHex('#2563EB', 1)],
          createdAt: '2026-06-01T00:00:00.000Z',
        }),
      );

      const opsBeforeOpen = db.pendingOpCount();
      db.markAssetOpened(older.id, new Date('2026-11-22T12:00:00.000Z'));
      expect(db.pendingOpCount()).toBe(opsBeforeOpen); // Local-only!

      const recent = db.recentActivityAssets(10);
      expect(recent[0].id).toBe(older.id);
      expect(recent[1].id).toBe(newer.id);

      // SmartFolder persisted under `smart_folders.v1`
      const sf = db.saveSmartFolder({
        id: toSwiftUUID(crypto.randomUUID()),
        name: 'Warm High Rated',
        colorHex: '#D4A373',
        rule: createDefaultSmartFolderRule({
          matchMode: 'all',
          tags: ['warm'],
          minRating: 4,
          colorHexes: ['#D4A373'],
          colorTolerance: 20,
        }),
        sortOrder: 0,
        createdAt: new Date().toISOString(),
        updatedAt: new Date().toISOString(),
      });
      const rawPersisted = db.getState<unknown[]>('smart_folders.v1');
      expect(Array.isArray(rawPersisted)).toBe(true);
      expect(rawPersisted).toHaveLength(1);

      const matched = db.fetchAssetsForSmartFolder(sf.id);
      expect(matched.map((a) => a.id)).toEqual([older.id]);

      // QuickJump + SimilarAssets + SuggestFolder
      const folder = db.createFolder('Poster Archive');
      db.saveAssetLocally({ ...older, folderID: folder.id });
      const target = db.saveAssetLocally(
        createDefaultAssetRecord({
          id: toSwiftUUID(crypto.randomUUID()),
          title: 'Warm Poster Candidate',
          fileName: 'cand.png',
          tags: ['poster', 'warm'],
          dominantColors: [labFromHex('#D6A678', 1)],
        }),
      );
      db.saveVector(older.id, {
        featurePrint: encodeFeaturePrintFloat32([1, 0, 0, 0]),
        precision: 16,
      });
      db.saveVector(target.id, {
        featurePrint: encodeFeaturePrintFloat32([0.99, 0.1, 0, 0]),
        precision: 16,
      });
      db.saveVector(newer.id, {
        featurePrint: encodeFeaturePrintFloat32([0, 0, 1, 0]),
        precision: 16,
      });

      const sim = db.similarAssets(target.id, 5);
      expect(sim[0].asset.id).toBe(older.id);

      const suggestion = db.suggestFolder(target.id);
      expect(suggestion?.folderID).toBe(folder.id);

      const board = db.saveBoardLocally(
        createDefaultMoodboardDocument({
          id: toSwiftUUID(crypto.randomUUID()),
          title: '光与影情绪板',
        }),
      );
      const jumps = db.quickJump('gyy', 10);
      expect(jumps.some((j) => j.kind === 'moodboard' && j.targetUUID === board.id)).toBe(true);
    } finally {
      db.close();
    }
  });

  it('round-trips Float16 carry edge cases & NaN accurately and guards bplist00 VNFeaturePrint blobs (P0-01)', () => {
    // Rounding carry values (mantissa 0x3ff -> carries into exponent via +, NOT bitwise |)
    const carryValues = [0.4999, 1.9999, 0.12499, -0.4999, -1.9999, 65504, 1e-6, 0, -0];
    const encoded = encodeEmbeddingBlob(carryValues, 16);
    const decoded = decodeEmbeddingBlob(encoded, 16);
    expect(decoded).toHaveLength(carryValues.length);
    for (let i = 0; i < carryValues.length; i++) {
      expect(Math.abs(decoded[i] - carryValues[i])).toBeLessThan(0.01);
    }
    // Specifically verify 0.4999 rounds to 0.5 (not 0.25!) and 1.9999 rounds to 2.0 (not 1.0!)
    expect(float16BitsToFloat32(float32ToFloat16Bits(0.4999))).toBeCloseTo(0.5, 4);
    expect(float16BitsToFloat32(float32ToFloat16Bits(1.9999))).toBeCloseTo(2.0, 4);
    expect(float16BitsToFloat32(float32ToFloat16Bits(0.12499))).toBeCloseTo(0.125, 4);
    // NaN MUST remain NaN (not silently turn into Infinity)
    expect(Number.isNaN(float16BitsToFloat32(float32ToFloat16Bits(Number.NaN)))).toBe(true);

    // Binary plist VNFeaturePrintObservation blob from macOS MUST return null instead of bogus Float32 values
    const macFeaturePrintBplist = Buffer.from('bplist00\x00\x01\x02\x03\x04\x05\x06\x07', 'latin1').toString('base64');
    expect(decodeFeaturePrintFloat32(macFeaturePrintBplist)).toBeNull();
    // Valid Float32 base64 still decodes cleanly
    const validFp = encodeFeaturePrintFloat32([0.25, -0.5, 0.75, 1.0]);
    expect(decodeFeaturePrintFloat32(validFp)).toEqual([0.25, -0.5, 0.75, 1.0]);
  });

  it('enforces strict folder validation, deleteFolder collision suffixing, applyBatchPatch ordering, smart folder clearable colorHex, epoch 0 timestamps, and embeddingModel filtering (P0-08, P1-03, P1-06, P2-01, P2-02)', () => {
    const db = makeTempDB();
    try {
      // Folder name validation rejects .charkle, .., /, and root Inbox
      for (const bad of ['.charkle', '..', 'a/b', 'Inbox', 'inbox', '   ']) {
        expect(() => db.createFolder(bad)).toThrow(LibraryDatabaseError);
      }
      const fA = db.createFolder('Archive');
      const fB = db.createFolder('Brand');
      expect(fB.sortOrder).toBe(fA.sortOrder + 1);
      // Duplicate sibling throws 409 FOLDER_EXISTS instead of silently renaming
      expect(() => db.createFolder('archive')).toThrow(LibraryDatabaseError);

      // Subfolder named 'Inbox' IS allowed, and deleting parent with trashContents=false disambiguates root collision -> 'Inbox 2'
      const subInbox = db.createFolder('Inbox', fA.id);
      const subBrand = db.createFolder('Brand', fA.id);
      db.deleteFolder(fA.id, false);
      expect(db.getFolder(subInbox.id)?.name).toBe('Inbox 2');
      expect(db.getFolder(subBrand.id)?.name).toBe('Brand 2');

      // updateFolderAppearance trims blank strings to null
      const cleared = db.updateFolderAppearance(fB.id, { colorHex: '   ', customSymbol: ' ' });
      expect(cleared.colorHex).toBeNull();
      expect(cleared.customSymbol).toBeNull();

      // SmartFolder clearable colorHex + default name
      const sf = db.saveSmartFolder({
        id: toSwiftUUID(crypto.randomUUID()),
        name: '   ',
        colorHex: null,
        rule: createDefaultSmartFolderRule({ colorHexes: ['#FF0000'] }),
        sortOrder: 0,
        createdAt: new Date().toISOString(),
        updatedAt: new Date().toISOString(),
      });
      expect(sf.name).toBe('未命名智能文件夹');
      expect(sf.colorHex).toBeNull();

      // Unix epoch 0 timestamp preserved (not replaced by Date.now())
      const epochAsset = db.saveAssetLocally(
        createDefaultAssetRecord({
          id: toSwiftUUID(crypto.randomUUID()),
          title: 'Epoch Zero',
          fileName: 'epoch.png',
          createdAt: '1970-01-01T00:00:00.000Z',
          updatedAt: '1970-01-01T00:00:00.000Z',
          suggestedTags: ['keep-me', 'drop-me'],
          tags: ['existing'],
        }),
      );
      const rawRow = db.sql.get<{ created: number }>('SELECT created FROM assets WHERE id = ?', [
        epochAsset.id,
      ]);
      expect(rawRow?.created).toBe(0);

      // applyBatchPatch: dismissSuggestedTags runs BEFORE acceptSuggestedTags, removeTags runs LAST, validates folderID, deduplicates IDs
      expect(() =>
        db.applyBatchPatch({
          assetIDs: [epochAsset.id],
          addTags: [],
          removeTags: [],
          acceptSuggestedTags: false,
          dismissSuggestedTags: [],
          folderAssignment: { type: 'folder', folderID: toSwiftUUID(crypto.randomUUID()) },
        }),
      ).toThrow(LibraryDatabaseError);

      const patched = db.applyBatchPatch({
        assetIDs: [epochAsset.id, epochAsset.id],
        addTags: ['added-then-removed', 'kept-added'],
        removeTags: ['added-then-removed'],
        acceptSuggestedTags: true,
        dismissSuggestedTags: ['drop-me'],
        folderAssignment: { type: 'folder', folderID: fB.id },
      });
      expect(patched).toHaveLength(1);
      expect(patched[0].tags).toContain('keep-me');
      expect(patched[0].tags).toContain('kept-added');
      expect(patched[0].tags).not.toContain('drop-me');
      expect(patched[0].tags).not.toContain('added-then-removed');
      expect(patched[0].suggestedTags).toEqual([]);

      // fetchAssets offset without limit
      const a2 = db.saveAssetLocally(
        createDefaultAssetRecord({
          id: toSwiftUUID(crypto.randomUUID()),
          title: 'Second Asset',
          fileName: 'two.png',
          folderID: fB.id,
        }),
      );
      expect(db.fetchAssets(undefined, undefined, 1)).toHaveLength(1);

      // similarAssets filters mismatched embeddingModel; suggestFolder excludes asset's own folder
      db.saveVector(epochAsset.id, {
        embedding: [1, 0, 0, 0],
        embeddingModel: 'model-A',
        precision: 16,
      });
      db.saveVector(a2.id, {
        embedding: [1, 0, 0, 0],
        embeddingModel: 'model-B',
        precision: 16,
      });
      const sim = db.similarAssets(epochAsset.id, 5);
      // Should NOT get a bogus 1.0 embedding similarity across mismatched models
      expect(sim[0]?.matchReasons.some((r) => r.includes('语义'))).toBeFalsy();
      // Both assets are in fB -> suggestFolder for epochAsset must NOT recommend its own folder fB
      expect(db.suggestFolder(epochAsset.id)?.folderID).not.toBe(fB.id);
    } finally {
      db.close();
    }
  });
});
