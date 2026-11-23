import {
  ASSET_SYNC_EXCLUDED_FIELDS,
  BOARD_SYNC_EXCLUDED_FIELDS,
  canonicalSwiftJsonStringify,
  compareSyncStamp,
  createDefaultAssetRecord,
  createDefaultMoodboardDocument,
  diffSwiftSyncFields,
  normalizeSearchText,
  toSwiftUUID,
  type AssetChanges,
  type AssetRecord,
  type BoardChanges,
  type CollectionChanges,
  type DeletedAssetFingerprint,
  type FolderRecord,
  type MoodboardDocument,
  type SyncClocks,
  type SyncOperation,
  type SyncOperationChange,
  type SyncStamp,
  type UUID,
} from '@charkle/shared';
import { bytesToHex, sha256BytesSync } from '../runtime/web-crypto-utils.js';

/**
 * Deterministic UUID v5-shaped derivation matching macOS `DriveFiles.stableUUID(_:)`.
 */
export function stableUUID(key: string): UUID {
  const digest = sha256BytesSync(key);
  const b = new Uint8Array(digest.subarray(0, 16));
  b[6] = (b[6] & 0x0f) | 0x50;
  b[8] = (b[8] & 0x3f) | 0x80;
  const hex = bytesToHex(b).toUpperCase();
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20, 32)}`;
}

export function tagMap(tags: readonly string[]): Map<string, string> {
  const result = new Map<string, string>();
  for (const tag of tags) {
    const clean = tag.trim();
    const key = normalizeSearchText(clean);
    if (key.length > 0) {
      result.set(key, clean);
    }
  }
  return result;
}

export function acceptClock(clocks: SyncClocks, stamp: SyncStamp, key: string): boolean {
  const current = clocks.clocks[key];
  if (current && compareSyncStamp(current, stamp) >= 0) {
    return false;
  }
  clocks.clocks[key] = stamp;
  return true;
}

export function isClockDeleted(clocks: SyncClocks | null | undefined): boolean {
  return Boolean(clocks?.clocks?.['deleted']);
}

export function createSyncClocks(): SyncClocks {
  return { clocks: {} };
}

export function diffAssetChanges(value: AssetRecord, previous: AssetRecord | null): AssetChanges {
  const fields = diffSwiftSyncFields('asset', value, previous, ASSET_SYNC_EXCLUDED_FIELDS);
  const oldMap = tagMap(previous?.tags ?? []);
  const newMap = tagMap(value.tags);

  const tagsAdded: string[] = [];
  for (const k of Array.from(newMap.keys()).sort()) {
    const newVal = newMap.get(k)!;
    if (oldMap.get(k) !== newVal) {
      tagsAdded.push(newVal);
    }
  }

  const tagsRemoved: string[] = [];
  for (const k of Array.from(oldMap.keys()).sort()) {
    if (!newMap.has(k)) {
      tagsRemoved.push(k);
    }
  }

  return {
    id: toSwiftUUID(value.id),
    fields,
    tagsAdded,
    tagsRemoved,
  };
}

export function isAssetChangesEmpty(delta: AssetChanges): boolean {
  return (
    Object.keys(delta.fields).length === 0 &&
    delta.tagsAdded.length === 0 &&
    delta.tagsRemoved.length === 0
  );
}

export function assetChangesTouchesLocation(delta: AssetChanges): boolean {
  return 'folderID' in delta.fields || 'fileName' in delta.fields;
}

export function diffCollectionChanges<T extends { id: UUID }>(
  values: readonly T[],
  previous: readonly T[],
): CollectionChanges<T> {
  const before = new Map<UUID, T>();
  for (const item of previous) before.set(toSwiftUUID(item.id), item);
  const after = new Map<UUID, T>();
  for (const item of values) after.set(toSwiftUUID(item.id), item);

  const updated: T[] = [];
  for (const [id, item] of after.entries()) {
    const prev = before.get(id);
    if (!prev || canonicalSwiftJsonStringify(prev) !== canonicalSwiftJsonStringify(item)) {
      updated.push(item);
    }
  }
  updated.sort((a, b) => toSwiftUUID(a.id).localeCompare(toSwiftUUID(b.id)));

  const removed: UUID[] = [];
  for (const id of before.keys()) {
    if (!after.has(id)) removed.push(id);
  }
  removed.sort((a, b) => a.localeCompare(b));

  return { updated, removed };
}

export function applyCollectionChanges<T extends { id: UUID }>(
  changes: CollectionChanges<T>,
  values: readonly T[],
  component: string,
  stamp: SyncStamp,
  clocks: SyncClocks,
): T[] {
  const indexed = new Map<UUID, T>();
  for (const item of values) indexed.set(toSwiftUUID(item.id), item);

  for (const rawId of changes.removed) {
    const id = toSwiftUUID(rawId);
    if (acceptClock(clocks, stamp, component + id)) {
      indexed.delete(id);
    }
  }
  for (const item of changes.updated) {
    const id = toSwiftUUID(item.id);
    if (acceptClock(clocks, stamp, component + id)) {
      indexed.set(id, item);
    }
  }
  return Array.from(indexed.values()).sort((a, b) =>
    toSwiftUUID(a.id).localeCompare(toSwiftUUID(b.id)),
  );
}

export function diffBoardChanges(
  value: MoodboardDocument,
  previous: MoodboardDocument | null,
): BoardChanges {
  const fields = diffSwiftSyncFields('board', value, previous, BOARD_SYNC_EXCLUDED_FIELDS);
  const nodes = diffCollectionChanges(value.nodes, previous?.nodes ?? []);
  const connectors = diffCollectionChanges(value.connectors, previous?.connectors ?? []);
  const strokes = diffCollectionChanges(value.inkStrokes, previous?.inkStrokes ?? []);
  return {
    id: toSwiftUUID(value.id),
    fields,
    nodes,
    connectors,
    strokes,
  };
}

export function isBoardChangesEmpty(delta: BoardChanges): boolean {
  return (
    Object.keys(delta.fields).length === 0 &&
    delta.nodes.updated.length === 0 &&
    delta.nodes.removed.length === 0 &&
    delta.connectors.updated.length === 0 &&
    delta.connectors.removed.length === 0 &&
    delta.strokes.updated.length === 0 &&
    delta.strokes.removed.length === 0
  );
}

export function mergeSyncFields<T extends object>(
  deltaFields: Record<string, unknown>,
  original: T,
  excluding: ReadonlySet<string>,
  stamp: SyncStamp,
  clocks: SyncClocks,
): T {
  const merged = { ...(original as Record<string, unknown>) };
  for (const [field, value] of Object.entries(deltaFields)) {
    if (excluding.has(field)) continue;
    if (!acceptClock(clocks, stamp, `field:${field}`)) continue;
    merged[field] = value === undefined ? null : value;
  }
  return merged as T;
}

/**
 * Minimal DB interface used by CRDT sync operation applier (implemented by LibraryDatabase).
 */
export interface SyncOperationStore {
  getState<T>(key: string): T | null;
  setState<T>(key: string, value: T | null): void;
  getAsset(id: UUID): AssetRecord | null;
  getAssetByDriveID(driveID: string): AssetRecord | null;
  putAsset(asset: AssetRecord): void;
  removeAsset(id: UUID): void;
  getBoard(id: UUID): MoodboardDocument | null;
  fetchBoards(): MoodboardDocument[];
  putBoard(board: MoodboardDocument): void;
  removeBoard(id: UUID): void;
  getFolder(id: UUID): FolderRecord | null;
  putFolder(folder: FolderRecord): void;
  removeFolder(id: UUID): void;
  saveVector(
    id: UUID,
    vector: {
      featurePrint?: string | null;
      embedding?: number[] | null;
      embeddingModel?: string | null;
      precision: 16 | 32;
    },
  ): void;
  markProjection(name: string, id: UUID): void;
  isTombstoned(entity: string, id: UUID): boolean;
}

export function nextHLC(store: Pick<SyncOperationStore, 'getState' | 'setState'>): number {
  const previous = store.getState<number>('hlc') ?? 0;
  const now = Date.now() * 1024;
  return Math.max(now, previous + 1);
}

export function applySyncOperation(store: SyncOperationStore, op: SyncOperation): void {
  const stamp = op.stamp;
  if (!Number.isFinite(stamp.time) || stamp.time <= 0) {
    throw new Error('Invalid sync clock timestamp');
  }
  const observed = store.getState<number>('hlc') ?? 0;
  if (observed < stamp.time) {
    store.setState('hlc', stamp.time);
  }
  const isoDate = new Date(Math.floor(stamp.time / 1024)).toISOString();

  const change: SyncOperationChange = op.change;
  switch (change.type) {
    case 'asset': {
      const id = toSwiftUUID(change.delta.id);
      const clockKey = `clock.asset.${id}`;
      const clocks = store.getState<SyncClocks>(clockKey) ?? createSyncClocks();
      if (isClockDeleted(clocks)) return;

      const current =
        store.getAsset(id) ??
        createDefaultAssetRecord({
          id,
          title: '',
          fileName: '',
          isLocalOriginalCached: false,
          createdAt: isoDate,
          updatedAt: isoDate,
        });

      const excluded = new Set(ASSET_SYNC_EXCLUDED_FIELDS);
      if (current.driveFileID?.startsWith('mounted-')) {
        excluded.add('driveFileID');
      }

      const merged = mergeSyncFields(change.delta.fields, current, excluded, stamp, clocks);
      const tags = tagMap(current.tags);
      for (const removed of change.delta.tagsRemoved) {
        const key = normalizeSearchText(removed);
        if (acceptClock(clocks, stamp, `tag:${key}`)) {
          tags.delete(key);
        }
      }
      for (const added of change.delta.tagsAdded) {
        const key = normalizeSearchText(added);
        if (key.length > 0 && acceptClock(clocks, stamp, `tag:${key}`)) {
          tags.set(key, added.trim());
        }
      }
      merged.tags = Array.from(tags.values()).sort((a, b) => a.localeCompare(b));
      if (current.updatedHLC <= stamp.time) {
        merged.updatedHLC = stamp.time;
        merged.updatedAt = isoDate;
      }

      if (merged.driveFileID) {
        const duplicate = store.getAssetByDriveID(merged.driveFileID);
        if (duplicate && toSwiftUUID(duplicate.id) !== id) {
          if (toSwiftUUID(duplicate.id) === stableUUID(`asset:${merged.driveFileID}`)) {
            remapDiscoveredAsset(store, duplicate, id);
          } else {
            merged.driveFileID = current.driveFileID ?? null;
          }
        }
      }

      store.putAsset(merged);
      store.setState(clockKey, clocks);

      const deferredKey = `deferred.vector.${id}`;
      const deferred = store.getState<SyncOperation[]>(deferredKey);
      if (deferred && deferred.length > 0) {
        store.setState(deferredKey, null);
        for (const deferredOp of deferred) {
          applySyncOperation(store, deferredOp);
        }
      }
      return;
    }

    case 'board': {
      const id = toSwiftUUID(change.delta.id);
      const clockKey = `clock.board.${id}`;
      const clocks = store.getState<SyncClocks>(clockKey) ?? createSyncClocks();
      if (isClockDeleted(clocks)) return;

      const current =
        store.getBoard(id) ??
        createDefaultMoodboardDocument({
          id,
          title: '',
          createdAt: isoDate,
          updatedAt: isoDate,
        });

      let merged = mergeSyncFields(
        change.delta.fields,
        current,
        BOARD_SYNC_EXCLUDED_FIELDS,
        stamp,
        clocks,
      );
      merged.nodes = applyCollectionChanges(
        change.delta.nodes,
        current.nodes,
        'node:',
        stamp,
        clocks,
      ).sort((a, b) => {
        if (a.editorialOrder !== b.editorialOrder) return a.editorialOrder - b.editorialOrder;
        if (a.zIndex !== b.zIndex) return a.zIndex - b.zIndex;
        return toSwiftUUID(a.id).localeCompare(toSwiftUUID(b.id));
      });
      merged.connectors = applyCollectionChanges(
        change.delta.connectors,
        current.connectors,
        'connector:',
        stamp,
        clocks,
      );
      merged.inkStrokes = applyCollectionChanges(
        change.delta.strokes,
        current.inkStrokes,
        'stroke:',
        stamp,
        clocks,
      ).sort((a, b) => {
        if (a.zIndex !== b.zIndex) return a.zIndex - b.zIndex;
        if (a.createdAt !== b.createdAt) return a.createdAt.localeCompare(b.createdAt);
        return toSwiftUUID(a.id).localeCompare(toSwiftUUID(b.id));
      });

      if (current.updatedHLC <= stamp.time) {
        merged.updatedHLC = stamp.time;
        merged.updatedAt = isoDate;
      }

      merged = resolveAssetAliasesInBoard(store, merged);
      store.putBoard(merged);
      store.setState(clockKey, clocks);
      store.markProjection('boards', id);
      return;
    }

    case 'folder': {
      const folder: FolderRecord = {
        ...change.folder,
        id: toSwiftUUID(change.folder.id),
        parentID: change.folder.parentID ? toSwiftUUID(change.folder.parentID) : null,
      };
      const clockKey = `clock.folder.${folder.id}`;
      const clocks = store.getState<SyncClocks>(clockKey) ?? createSyncClocks();
      if (isClockDeleted(clocks) || !acceptClock(clocks, stamp, 'value')) return;

      const current = store.getFolder(folder.id);
      if (folder.driveFolderID?.startsWith('mounted-')) {
        folder.driveFolderID = current?.driveFolderID ?? null;
      }
      if (!folder.driveFolderID) {
        folder.driveFolderID = current?.driveFolderID ?? null;
      }
      folder.assetCount = 0;
      store.putFolder(folder);
      store.setState(clockKey, clocks);
      return;
    }

    case 'deleteAsset': {
      const id = toSwiftUUID(change.id);
      const existing = store.getAsset(id);
      const knownDriveID = existing?.driveFileID ?? change.driveID ?? null;
      if (knownDriveID) {
        store.setState(`deleted.drive.${knownDriveID}`, true);
      }
      if (existing && existing.contentHash) {
        const fp: DeletedAssetFingerprint = {
          assetID: id,
          sha256: existing.contentHash,
          md5: null,
          fileName: existing.fileName,
          deletedAt: new Date().toISOString(),
        };
        store.setState(`deleted.content.${existing.contentHash}`, fp);
      }
      tombstone(store, 'asset', id, stamp);
      store.removeAsset(id);
      store.setState(`media.cleanup.${id}`, true);
      store.setState(`deferred.vector.${id}`, null);
      store.markProjection('thumbnails', id);
      store.markProjection('embeddings', id);
      return;
    }

    case 'deleteBoard': {
      const id = toSwiftUUID(change.id);
      tombstone(store, 'board', id, stamp);
      store.removeBoard(id);
      store.markProjection('boards', id);
      return;
    }

    case 'deleteFolder': {
      const id = toSwiftUUID(change.id);
      tombstone(store, 'folder', id, stamp);
      store.removeFolder(id);
      return;
    }

    case 'vector': {
      const id = toSwiftUUID(change.id);
      const clockKey = `clock.vector.${id}`;
      const clocks = store.getState<SyncClocks>(clockKey) ?? createSyncClocks();
      if (!store.getAsset(id)) {
        if (!store.isTombstoned('asset', id)) {
          storeDeferredVector(store, id, change.vector, stamp);
        }
        return;
      }
      const featurePrint =
        change.vector.featurePrint && acceptClock(clocks, stamp, 'feature')
          ? change.vector.featurePrint
          : null;
      const embedding =
        change.vector.embedding && acceptClock(clocks, stamp, 'embedding')
          ? change.vector.embedding
          : null;
      if (featurePrint || embedding) {
        store.saveVector(id, {
          featurePrint,
          embedding,
          embeddingModel: change.vector.embeddingModel ?? null,
          precision: change.vector.precision,
        });
        store.setState(clockKey, clocks);
        store.markProjection('embeddings', id);
      }
      return;
    }
  }
}

function tombstone(store: SyncOperationStore, entity: string, id: UUID, stamp: SyncStamp): void {
  const key = `clock.${entity}.${id}`;
  const clocks = store.getState<SyncClocks>(key) ?? createSyncClocks();
  if (acceptClock(clocks, stamp, 'deleted')) {
    store.setState(key, clocks);
  }
}

function storeDeferredVector(
  store: SyncOperationStore,
  id: UUID,
  vector: Extract<SyncOperationChange, { type: 'vector' }>['vector'],
  stamp: SyncStamp,
): void {
  const key = `deferred.vector.${id}`;
  const pending = (store.getState<SyncOperation[]>(key) ?? []).filter((op) => {
    if (compareSyncStamp(op.stamp, stamp) > 0 || op.change.type !== 'vector') return true;
    const prior = op.change.vector;
    const superseded =
      (!prior.embedding || Boolean(vector.embedding)) &&
      (!prior.featurePrint || Boolean(vector.featurePrint));
    return !superseded;
  });
  pending.push({ stamp, change: { type: 'vector', id, vector } });
  store.setState(key, pending);
}

function remapDiscoveredAsset(
  store: SyncOperationStore,
  discovered: AssetRecord,
  canonicalID: UUID,
): void {
  const oldID = toSwiftUUID(discovered.id);
  store.setState(`alias.asset.${oldID}`, canonicalID);
  for (const board of store.fetchBoards()) {
    const referencesOld =
      board.nodes.some((n) => n.kind.type === 'assetRef' && toSwiftUUID(n.kind.assetID) === oldID) ||
      board.candidateAssetIDs.some((cid) => toSwiftUUID(cid) === oldID);
    if (referencesOld) {
      store.putBoard(resolveAssetAliasesInBoard(store, board));
      store.markProjection('boards', board.id);
    }
  }
  store.removeAsset(oldID);
  store.setState(`media.cleanup.${oldID}`, true);
}

function resolveAssetAliasesInBoard(
  store: SyncOperationStore,
  board: MoodboardDocument,
): MoodboardDocument {
  const nextNodes = board.nodes.map((node) => {
    if (node.kind.type !== 'assetRef') return node;
    const alias = store.getState<UUID>(`alias.asset.${toSwiftUUID(node.kind.assetID)}`);
    if (!alias) return node;
    return {
      ...node,
      kind: { ...node.kind, assetID: alias },
    };
  });
  const nextCandidates = board.candidateAssetIDs.map((cid) => {
    return store.getState<UUID>(`alias.asset.${toSwiftUUID(cid)}`) ?? cid;
  });
  return {
    ...board,
    nodes: nextNodes,
    candidateAssetIDs: nextCandidates,
  };
}
