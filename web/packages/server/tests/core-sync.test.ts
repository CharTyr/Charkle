import crypto from 'node:crypto';
import fs from 'node:fs';
import fsp from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import sharp from 'sharp';
import { afterEach, describe, expect, it, vi } from 'vitest';
import {
  createDefaultDriveSyncConfig,
  createDefaultMoodboardDocument,
  SwiftWireCodec,
  toSwiftUUID,
} from '@charkle/shared';
import { EventBus } from '../src/api/events.js';
import { MediaPipeline } from '../src/media/media-pipeline.js';
import { NodeBlobStore } from '../src/runtime/node-blob.js';
import { NodeImageProcessor } from '../src/runtime/node-image.js';
import { openNodeLibraryDatabase } from '../src/runtime/node-sql.js';
import { createNodeConfigStore, createNodeSecretVault } from '../src/runtime/node-storage.js';
import { DirectAPITransport } from '../src/sync/direct-api-transport.js';
import { DriveSyncEngine } from '../src/sync/drive-sync-engine.js';
import { InMemoryDriveTransport } from '../src/sync/in-memory-transport.js';
import { LocalFolderTransport } from '../src/sync/local-folder-transport.js';
import { isBinaryPlist, parseBinaryPlist } from '../src/runtime/bplist.js';

const tempDirs: string[] = [];

function createNodeDevice(transport: InMemoryDriveTransport) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'charkle-sync-test-'));
  tempDirs.push(dir);
  const db = openNodeLibraryDatabase(path.join(dir, 'library.sqlite'));
  const media = new MediaPipeline({
    blobs: new NodeBlobStore(path.join(dir, 'media')),
    images: new NodeImageProcessor(),
    readLocalFile: async (filePath) => new Uint8Array(await fsp.readFile(filePath)),
  });
  const configStore = createNodeConfigStore(db.sql, dir);
  const secretVault = createNodeSecretVault(db.sql, dir, 'test-sync-secret');
  const events = new EventBus();
  const engine = new DriveSyncEngine({
    db,
    media,
    configStore,
    secretVault,
    events,
    transportOverride: transport,
    localTransportFactory: (cfg) =>
      cfg.mode === 'gdirectMount'
        ? new LocalFolderTransport(cfg.mountPath.trim(), 'gdirectMount')
        : new LocalFolderTransport(path.dirname(path.resolve(cfg.localLibraryPath)), 'LocalFolder'),
    runtimeMode: 'node',
  });
  return { dir, db, media, configStore, secretVault, events, engine };
}

async function samplePng(r: number, g: number, b: number): Promise<Buffer> {
  return sharp({
    create: { width: 320, height: 240, channels: 4, background: { r, g, b, alpha: 1 } },
  })
    .png()
    .toBuffer();
}

afterEach(() => {
  while (tempDirs.length > 0) {
    const dir = tempDirs.pop()!;
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

describe('DriveSyncEngine (Multi-device CRDT, Swift Wire Codec, Rename Reconciliation & Lossless Migration)', () => {
  it('syncs folders, assets, moodboards & Swift wire artifacts bidirectionally across two devices', async () => {
    const sharedDrive = new InMemoryDriveTransport({ email: 'studio@charkle.app' });
    const deviceA = createNodeDevice(sharedDrive);
    const deviceB = createNodeDevice(sharedDrive);

    const syncCfg = createDefaultDriveSyncConfig({
      mode: 'directAPIWithGDirect',
      rootFolderName: 'Charkle',
      syncThumbnails: true,
      syncEmbeddings: true,
    });

    try {
      // Device A creates folder, asset, and moodboard
      const folderA = deviceA.db.createFolder('Architecture');
      const png = await samplePng(180, 110, 80);
      const ing = await deviceA.media.ingestUploadedFile(png, 'courtyard.png', 'image/png', folderA.id);
      ing.asset.tags = ['limestone', 'sunlight'];
      ing.asset.rating = 5;
      const savedAssetA = deviceA.db.saveAssetLocally(ing.asset);
      if (ing.vector) deviceA.db.saveVector(savedAssetA.id, ing.vector);
      deviceA.db.markProjection('thumbnails', savedAssetA.id);

      const boardA = deviceA.db.saveBoardLocally(
        createDefaultMoodboardDocument({
          id: toSwiftUUID(crypto.randomUUID()),
          title: 'Light & Clay',
          nodes: [
            {
              id: toSwiftUUID(crypto.randomUUID()),
              kind: { type: 'assetRef', assetID: savedAssetA.id, weight: 2, autoplayLoop: false },
              frame: { x: 20, y: 20, width: 300, height: 225 },
              zIndex: 1,
              rotationDegrees: 0,
              flipHorizontal: false,
              flipVertical: false,
              isLocked: false,
              editorialOrder: 0,
              updatedAt: new Date().toISOString(),
            },
          ],
        }),
      );

      const reportA = await deviceA.engine.syncWithTransport(sharedDrive, syncCfg);
      expect(reportA.uploadedOps).toBeGreaterThan(0);

      // Verify exact `/.charkle/` layout & Swift wire codec compatibility
      const manifestRaw = sharedDrive.readTextByPath('Charkle/.charkle/manifest.json');
      expect(manifestRaw).not.toBeNull();
      const manifest = SwiftWireCodec.decodeManifest(manifestRaw!);
      expect(manifest.version).toBe(1);

      // P0-10: macOS wire parity writes lowercase UUID filenames for boards & thumbnails
      const boardRaw = sharedDrive.readTextByPath(
        `Charkle/.charkle/boards/${boardA.id.toLowerCase()}.json`,
      );
      expect(boardRaw).not.toBeNull();
      const decodedBoard = SwiftWireCodec.parseMoodboardDocument(boardRaw!);
      expect(decodedBoard.title).toBe('Light & Clay');
      expect(decodedBoard.nodes).toHaveLength(1);
      expect(
        sharedDrive.findByPath(`Charkle/.charkle/thumbnails/${savedAssetA.id.toLowerCase()}.jpg`),
      ).not.toBeNull();

      // Device B syncs from same Drive and receives folder, asset, thumbnail, and board!
      const reportB = await deviceB.engine.syncWithTransport(sharedDrive, syncCfg);
      expect(reportB.downloadedOps).toBeGreaterThan(0);

      const syncedAssetB = deviceB.db.getAsset(savedAssetA.id);
      expect(syncedAssetB).not.toBeNull();
      expect(syncedAssetB?.title).toBe('courtyard');
      expect(syncedAssetB?.tags).toEqual(['limestone', 'sunlight']);
      expect(syncedAssetB?.rating).toBe(5);
      expect(deviceB.media.getThumbnailPath(savedAssetA.id, 'grid520')).not.toBeNull();

      const syncedBoardB = deviceB.db.getBoard(boardA.id);
      expect(syncedBoardB?.title).toBe('Light & Clay');

      // Concurrent edit: Device B adds tag 'kyoto', Device A updates notes -> both survive merge!
      deviceB.db.saveAssetLocally({ ...syncedAssetB!, tags: [...syncedAssetB!.tags, 'kyoto'] });
      const latestA = deviceA.db.getAsset(savedAssetA.id)!;
      deviceA.db.saveAssetLocally({ ...latestA, notes: 'Afternoon shadow study' });

      await deviceB.engine.syncWithTransport(sharedDrive, syncCfg);
      await deviceA.engine.syncWithTransport(sharedDrive, syncCfg);
      await deviceB.engine.syncWithTransport(sharedDrive, syncCfg);

      const finalA = deviceA.db.getAsset(savedAssetA.id)!;
      const finalB = deviceB.db.getAsset(savedAssetA.id)!;
      expect(finalA.tags).toContain('kyoto');
      expect(finalA.notes).toBe('Afternoon shadow study');
      expect(finalB.tags).toContain('kyoto');
      expect(finalB.notes).toBe('Afternoon shadow study');
    } finally {
      deviceA.db.close();
      deviceB.db.close();
    }
  });

  it('reconciles remote file renames and discovers externally dropped files', async () => {
    const sharedDrive = new InMemoryDriveTransport({ email: 'rename@charkle.app' });
    const device = createNodeDevice(sharedDrive);
    const syncCfg = createDefaultDriveSyncConfig({
      mode: 'directAPIWithGDirect',
      rootFolderName: 'Charkle',
    });

    try {
      const png = await samplePng(45, 90, 140);
      const ing = await device.media.ingestUploadedFile(png, 'original-name.png', 'image/png');
      const saved = device.db.saveAssetLocally(ing.asset);
      await device.engine.syncWithTransport(sharedDrive, syncCfg);

      const bound = device.db.getAsset(saved.id)!;
      expect(bound.driveFileID).toBeTruthy();

      // Simulate external user renaming the file directly in Google Drive
      await sharedDrive.moveOrRenameFile({
        fileID: bound.driveFileID!,
        newName: 'renamed-in-drive.png',
      });

      // Also drop a brand-new external file directly into Charkle/Inbox
      const inboxFolder = sharedDrive.findByPath('Charkle/Inbox')!;
      const extPng = await samplePng(220, 180, 60);
      await sharedDrive.uploadFile({
        data: extPng,
        name: 'dropped-externally.png',
        mimeType: 'image/png',
        parentID: inboxFolder.id,
      });

      const report = await device.engine.syncWithTransport(sharedDrive, syncCfg);
      expect(report.reconciledRenames).toBe(1);
      expect(report.discoveredRemoteAssets).toBe(1);

      const afterRename = device.db.getAsset(saved.id)!;
      expect(afterRename.fileName).toBe('renamed-in-drive.png');
      expect(afterRename.title).toBe('renamed-in-drive');

      const discovered = device.db.getAsset(report.discoveredAssetIDs[0]);
      expect(discovered?.fileName).toBe('dropped-externally.png');
    } finally {
      device.db.close();
    }
  });

  it('executes lossless two-way storage migration downloading missing originals before switching backends', async () => {
    const sourceDrive = new InMemoryDriveTransport({ displayName: 'SourceDrive', email: 'src@charkle.app' });
    const targetDrive = new InMemoryDriveTransport({ displayName: 'TargetDrive', email: 'dst@charkle.app' });
    const device = createNodeDevice(sourceDrive);

    const sourceCfg = createDefaultDriveSyncConfig({
      mode: 'directAPIWithGDirect',
      rootFolderName: 'CharkleSource',
    });
    device.configStore.setSyncConfig(sourceCfg);

    try {
      const folder = device.db.createFolder('Ceramics');
      const png = await samplePng(196, 106, 52);
      const ing = await device.media.ingestUploadedFile(png, 'glaze.png', 'image/png', folder.id);
      const saved = device.db.saveAssetLocally(ing.asset);
      const board = device.db.saveBoardLocally(
        createDefaultMoodboardDocument({
          id: toSwiftUUID(crypto.randomUUID()),
          title: 'Migration Board',
        }),
      );

      await device.engine.syncWithTransport(sourceDrive, sourceCfg);

      // Evict local original to simulate cloud-only asset before migration!
      const origPath = device.media.getOriginalPath(saved)!;
      fs.unlinkSync(origPath);
      device.db.putAsset({ ...device.db.getAsset(saved.id)!, isLocalOriginalCached: false });

      const targetCfg = createDefaultDriveSyncConfig({
        mode: 'localOnly',
        localLibraryPath: path.join(device.dir, 'migrated-local-lib'),
      });
      const migrationReport = await device.engine.migrateStorage(targetCfg, null, targetDrive);

      expect(migrationReport.downloadedOriginals).toBe(1);
      expect(migrationReport.migratedAssets).toBe(1);
      expect(migrationReport.migratedFolders).toBe(1);
      expect(migrationReport.migratedBoards).toBe(1);
      expect(device.media.getOriginalPath(device.db.getAsset(saved.id)!)).not.toBeNull();
      expect(
        targetDrive.readTextByPath(
          `migrated-local-lib/.charkle/boards/${board.id.toLowerCase()}.json`,
        ),
      ).not.toBeNull();
    } finally {
      device.db.close();
    }
  });

  it('enforces macOS /.charkle/ wire parity: binary plist embedding shards, filtered maxSeq, pending-move guard, remote deletion, tombstone cleanup, collision suffix, and DirectAPI removeParents (P0-10..P0-15)', async () => {
    const sharedDrive = new InMemoryDriveTransport({ email: 'parity@charkle.app' });
    const deviceA = createNodeDevice(sharedDrive);
    const deviceB = createNodeDevice(sharedDrive);
    const syncCfg = createDefaultDriveSyncConfig({
      mode: 'directAPIWithGDirect',
      rootFolderName: 'Charkle',
      syncEmbeddings: true,
    });

    try {
      // 1. P0-11: Push & pull macOS binary plist embedding shards (`shard-<prefix>.bin`)
      const png1 = await samplePng(180, 90, 45);
      const ing1 = await deviceA.media.ingestUploadedFile(png1, 'dup.png', 'image/png');
      const asset1 = deviceA.db.saveAssetLocally(ing1.asset);
      deviceA.db.recordSyncChange({
        type: 'vector',
        id: asset1.id,
        vector: {
          featurePrint: Buffer.from(new Float32Array([0.25, 0.5, 0.75, 1.0]).buffer).toString('base64'),
          embedding: [0.1, 0.2, 0.3, 0.4],
          embeddingModel: 'gemini:test',
          precision: 16,
        },
      });
      await deviceA.engine.syncWithTransport(sharedDrive, syncCfg);

      const prefix = asset1.id.slice(0, 2).toLowerCase();
      const shardFile = sharedDrive.findByPath(`Charkle/.charkle/embeddings/shard-${prefix}.bin`);
      expect(shardFile).not.toBeNull();
      const shardBytes = await sharedDrive.downloadFile(shardFile!.id);
      expect(isBinaryPlist(shardBytes)).toBe(true);
      const decodedShard = parseBinaryPlist(shardBytes) as Record<string, unknown>;
      expect(decodedShard[asset1.id.toUpperCase()]).toBeDefined();

      // Device B pulls shard back into SQLite even without replay op
      await deviceB.engine.syncWithTransport(sharedDrive, syncCfg);
      const vecB = deviceB.db.getVector(asset1.id);
      expect(vecB?.embeddingModel).toBe('gemini:test');
      expect(vecB?.embedding).toHaveLength(4);

      // 2. P0-12: pushLocalOps with syncEmbeddings=false uses last INCLUDED seq (never unfiltered .vector seq)
      const noEmbedCfg = createDefaultDriveSyncConfig({
        mode: 'directAPIWithGDirect',
        rootFolderName: 'Charkle',
        syncEmbeddings: false,
      });
      deviceA.db.saveAssetLocally({ ...deviceA.db.getAsset(asset1.id)!, rating: 4 });
      deviceA.db.recordSyncChange({
        type: 'vector',
        id: asset1.id,
        vector: {
          featurePrint: null,
          embedding: [0.9, 0.8, 0.7, 0.6],
          embeddingModel: 'gemini:test-2',
          precision: 16,
        },
      });
      await deviceA.engine.syncWithTransport(sharedDrive, noEmbedCfg);
      const opsFolder = sharedDrive.findByPath('Charkle/.charkle/ops')!;
      const opFiles = await sharedDrive.listFiles(opsFolder.id);
      for (const f of opFiles) {
        if (!f.name.endsWith('.jsonl')) continue;
        const m = /^ops-.+-(\d+)\.jsonl$/.exec(f.name);
        expect(m).not.toBeNull();
        const declaredMaxSeq = Number(m![1]);
        const text = new TextDecoder().decode(await sharedDrive.downloadFile(f.id)).trim();
        const lines = text.split('\n').filter(Boolean);
        const lastOp = JSON.parse(lines[lines.length - 1]) as { seq: number };
        expect(lastOp.seq).toBe(declaredMaxSeq);
      }

      // 3. P0-13: Pending local rename MUST NOT be reverted by reconcileInventory before upload
      const bound1 = deviceA.db.getAsset(asset1.id)!;
      deviceA.db.saveAssetLocally({ ...bound1, fileName: 'local-renamed.png', title: 'local-renamed' });
      await deviceA.engine.syncWithTransport(sharedDrive, syncCfg);
      expect(deviceA.db.getAsset(asset1.id)?.fileName).toBe('local-renamed.png');
      const remoteItem1 = sharedDrive.findByPath('Charkle/Inbox/local-renamed.png');
      expect(remoteItem1).not.toBeNull();

      // 4. P0-15a: Upload filename collision gets `-<shortID>` suffix instead of overwriting
      const png2 = await samplePng(40, 140, 220);
      const ing2 = await deviceA.media.ingestUploadedFile(png2, 'local-renamed.png', 'image/png');
      const asset2 = deviceA.db.saveAssetLocally(ing2.asset);
      await deviceA.engine.syncWithTransport(sharedDrive, syncCfg);
      const bound2 = deviceA.db.getAsset(asset2.id)!;
      expect(bound2.fileName).toMatch(/^local-renamed-[a-f0-9]{8}\.png$/);

      // 5. P0-15b: Remote file deletion moves bound local asset into Trash
      await sharedDrive.deleteFile(bound2.driveFileID!);
      await deviceA.engine.syncWithTransport(sharedDrive, syncCfg);
      expect(deviceA.db.getAsset(asset2.id)?.isTrashed).toBe(true);

      // 6. P0-15c: Local permanent delete tombstone trashes remote file on next sync
      const driveId1 = deviceA.db.getAsset(asset1.id)!.driveFileID!;
      deviceA.db.permanentDeleteAssets([asset1.id]);
      await deviceA.engine.syncWithTransport(sharedDrive, syncCfg);
      expect(sharedDrive.findByPath('Charkle/Inbox/local-renamed.png')).toBeNull();
      expect(driveId1).toBeTruthy();

      // 7. P0-14: DirectAPITransport.moveOrRenameFile fetches current parents and sends paired addParents + removeParents
      const apiCalls: Array<{ url: string; method: string; body?: string }> = [];
      const mockOAuth = {
        getValidAccessToken: async () => 'fake-google-token',
      } as unknown as import('../src/sync/google-oauth.js').GoogleOAuthClient;
      const transport = new DirectAPITransport(mockOAuth);
      vi.stubGlobal(
        'fetch',
        vi.fn(async (input: string | URL, init?: RequestInit) => {
          const url = String(input);
          const method = init?.method ?? 'GET';
          apiCalls.push({
            url,
            method,
            body: typeof init?.body === 'string' ? init.body : undefined,
          });
          if (method === 'GET' && url.includes('fields=parents')) {
            return new Response(JSON.stringify({ parents: ['parent-old'] }), {
              status: 200,
              headers: { 'Content-Type': 'application/json' },
            });
          }
          return new Response(
            JSON.stringify({
              id: 'file-1',
              name: 'moved.png',
              mimeType: 'image/png',
              parents: ['parent-new'],
            }),
            { status: 200, headers: { 'Content-Type': 'application/json' } },
          );
        }),
      );
      try {
        await transport.moveOrRenameFile({
          fileID: 'file-1',
          newParentID: 'parent-new',
          newName: 'moved.png',
        });
        const patchMove = apiCalls.find((c) => c.method === 'PATCH');
        expect(patchMove?.url).toContain('addParents=parent-new');
        expect(patchMove?.url).toContain('removeParents=parent-old');

        // Same-folder rename MUST NOT send addParents/removeParents
        apiCalls.length = 0;
        await transport.moveOrRenameFile({
          fileID: 'file-1',
          newParentID: 'parent-old',
          newName: 'renamed-same-dir.png',
        });
        const patchSameDir = apiCalls.find((c) => c.method === 'PATCH');
        expect(patchSameDir?.url).not.toContain('addParents');
        expect(patchSameDir?.url).not.toContain('removeParents');
      } finally {
        vi.unstubAllGlobals();
      }
    } finally {
      deviceA.db.close();
      deviceB.db.close();
    }
  });
});
