import crypto from 'node:crypto';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import sharp from 'sharp';
import { afterEach, describe, expect, it } from 'vitest';
import {
  createDefaultDriveSyncConfig,
  createDefaultMoodboardDocument,
  SwiftWireCodec,
  toSwiftUUID,
} from '@charkle/shared';
import { EventBus } from '../src/api/events.js';
import { LibraryDatabase } from '../src/db/library-database.js';
import { MediaPipeline } from '../src/media/media-pipeline.js';
import { ConfigStore } from '../src/storage/config-store.js';
import { SecretVault } from '../src/storage/secret-vault.js';
import { DriveSyncEngine } from '../src/sync/drive-sync-engine.js';
import { InMemoryDriveTransport } from '../src/sync/in-memory-transport.js';

const tempDirs: string[] = [];

function createNodeDevice(transport: InMemoryDriveTransport) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'charkle-sync-test-'));
  tempDirs.push(dir);
  const db = new LibraryDatabase(path.join(dir, 'library.sqlite'));
  const media = new MediaPipeline(path.join(dir, 'media'));
  const configStore = new ConfigStore(dir);
  const secretVault = new SecretVault(dir, 'test-sync-secret');
  const events = new EventBus();
  const engine = new DriveSyncEngine({
    db,
    media,
    configStore,
    secretVault,
    events,
    transportOverride: transport,
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

      const boardRaw = sharedDrive.readTextByPath(`Charkle/.charkle/boards/${boardA.id}.json`);
      expect(boardRaw).not.toBeNull();
      const decodedBoard = SwiftWireCodec.parseMoodboardDocument(boardRaw!);
      expect(decodedBoard.title).toBe('Light & Clay');
      expect(decodedBoard.nodes).toHaveLength(1);

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
        targetDrive.readTextByPath(`migrated-local-lib/.charkle/boards/${board.id}.json`),
      ).not.toBeNull();
    } finally {
      device.db.close();
    }
  });
});
