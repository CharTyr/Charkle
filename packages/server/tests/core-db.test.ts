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
  encodeFeaturePrintFloat32,
  LibraryDatabase,
} from '../src/db/library-database.js';

const tempDirs: string[] = [];

function makeTempDB(): LibraryDatabase {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'charkle-db-test-'));
  tempDirs.push(dir);
  return new LibraryDatabase(path.join(dir, 'library.sqlite'));
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
      const modeRow = db.sqlite.prepare('PRAGMA journal_mode').get() as { journal_mode: string };
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
});
