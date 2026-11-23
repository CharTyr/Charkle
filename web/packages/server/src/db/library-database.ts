import {
  buildFtsQuery,
  classifyAspectShape,
  createDefaultFilterCriteria,
  decodeBytesBase64,
  deltaE2000,
  encodeBytesBase64,
  extractPinyin,
  fuzzyScoreSearchText,
  getAssetRecentActivityDate,
  getBoardReferencedAssetIDs,
  getPhotoExifCameraDisplayName,
  getPhotoExifExposureSummary,
  indexSearchText,
  labFromHex,
  matchesSmartFolderRule,
  mediaKindLocalizedLabel,
  normalizeSearchText,
  socialPlatformDisplayName,
  toSwiftUUID,
  type AssetBatchPatch,
  type AssetRecord,
  type AssetVector,
  type EmbeddingPrecision,
  type FilterCriteria,
  type FolderRecord,
  type FolderSuggestion,
  type MoodboardDocument,
  type MoodboardSummary,
  type QuickJumpMatch,
  type ScoredAsset,
  type SmartFolderRecord,
  type SyncClocks,
  type SyncLogLine,
  type SyncOperation,
  type SyncOperationChange,
  type TagCount,
  type UUID,
} from '@charkle/shared';
import type { ISqlDatabase, SqlParam } from '../runtime/types.js';
import { bytesToHex, randomBytes, randomUUID } from '../runtime/web-crypto-utils.js';
import {
  applySyncOperation,
  diffAssetChanges,
  diffBoardChanges,
  isAssetChangesEmpty,
  isBoardChangesEmpty,
  isClockDeleted,
  nextHLC,
  type SyncOperationStore,
} from './sync-operations.js';

const SCHEMA_VERSION = 3;
const SCHEMA_VERSION_STATE_KEY = 'schema.version';
const SMART_FOLDERS_STATE_KEY = 'smart_folders.v1';

export class LibraryDatabaseError extends Error {
  public readonly status: 400 | 404 | 409;
  public readonly code: string;

  constructor(message: string, status: 400 | 404 | 409 = 400, code = 'BAD_REQUEST') {
    super(message);
    this.name = 'LibraryDatabaseError';
    this.status = status;
    this.code = code;
  }
}

export function validateDriveName(name: string): void {
  if (
    !name ||
    name === '.' ||
    name === '..' ||
    name.includes('/') ||
    name.includes('\\') ||
    /[\u0000-\u001f\u007f]/.test(name)
  ) {
    throw new LibraryDatabaseError('无效的名称：不能包含路径分隔符或控制字符。', 400, 'INVALID_NAME');
  }
}

export function validateFolderName(raw: string, parentID: UUID | null): string {
  const name = raw.trim();
  validateDriveName(name);
  if (name.startsWith('.') || (parentID === null && name.toLowerCase() === 'inbox')) {
    throw new LibraryDatabaseError(
      '该文件夹名称为系统保留名称（不能以 "." 开头或在根目录命名为 "Inbox"）。',
      400,
      'RESERVED_FOLDER_NAME',
    );
  }
  return name;
}

// MARK: - Float16 / Float32 Embedding & Vector Helpers

const f32Scratch = new Float32Array(1);
const u32Scratch = new Uint32Array(f32Scratch.buffer);

export function float32ToFloat16Bits(val: number): number {
  f32Scratch[0] = val;
  const x = u32Scratch[0];
  const sign = (x >>> 16) & 0x8000;
  const expRaw = (x >>> 23) & 0xff;
  const mant = x & 0x7fffff;

  // Infinity & NaN (preserve NaN quiet bit instead of collapsing to +Infinity)
  if (expRaw === 0xff) {
    if (mant === 0) return sign | 0x7c00;
    return sign | 0x7e00 | (mant >>> 13);
  }

  const exp = expRaw - 127 + 15;
  if (exp <= 0) {
    if (exp < -10) return sign;
    const sig = mant | 0x800000;
    const shift = 14 - exp;
    const half = 1 << (shift - 1);
    const rem = sig & ((1 << shift) - 1);
    let frac = sig >>> shift;
    if (rem > half || (rem === half && (frac & 1) !== 0)) {
      frac += 1;
    }
    return sign | frac;
  }
  if (exp >= 31) return sign | 0x7c00;

  // IEEE-754 round-to-nearest-even with proper carry addition (`+`, NOT `|`)
  const rem = mant & 0x1fff;
  let frac = mant >>> 13;
  if (rem > 0x1000 || (rem === 0x1000 && (frac & 1) !== 0)) {
    frac += 1;
  }
  return sign | ((exp << 10) + frac);
}

export function float16BitsToFloat32(bits: number): number {
  const sign = (bits & 0x8000) !== 0 ? -1 : 1;
  const exp = (bits >> 10) & 0x1f;
  const frac = bits & 0x3ff;
  if (exp === 0) {
    return sign * Math.pow(2, -14) * (frac / 1024);
  }
  if (exp === 31) {
    return frac === 0 ? sign * Infinity : NaN;
  }
  return sign * Math.pow(2, exp - 15) * (1 + frac / 1024);
}

export function encodeEmbeddingBlob(values: readonly number[], precision: EmbeddingPrecision): Uint8Array {
  if (precision === 32) {
    const f32 = new Float32Array(values.length);
    for (let i = 0; i < values.length; i++) f32[i] = values[i];
    return new Uint8Array(f32.buffer, f32.byteOffset, f32.byteLength);
  }
  const u16 = new Uint16Array(values.length);
  for (let i = 0; i < values.length; i++) u16[i] = float32ToFloat16Bits(values[i]);
  return new Uint8Array(u16.buffer, u16.byteOffset, u16.byteLength);
}

export function decodeEmbeddingBlob(
  blob: Uint8Array | ArrayBuffer,
  precision: EmbeddingPrecision,
): number[] {
  const bytes =
    blob instanceof ArrayBuffer
      ? new Uint8Array(blob)
      : new Uint8Array(blob.buffer, blob.byteOffset, blob.byteLength);
  const copy = new Uint8Array(bytes.byteLength);
  copy.set(bytes);
  if (precision === 32) {
    const f32 = new Float32Array(copy.buffer, 0, Math.floor(copy.byteLength / 4));
    return Array.from(f32);
  }
  const u16 = new Uint16Array(copy.buffer, 0, Math.floor(copy.byteLength / 2));
  const out = new Array<number>(u16.length);
  for (let i = 0; i < u16.length; i++) out[i] = float16BitsToFloat32(u16[i]);
  return out;
}

export function encodeFeaturePrintFloat32(vec: readonly number[]): string {
  const f32 = new Float32Array(vec.length);
  for (let i = 0; i < vec.length; i++) f32[i] = vec[i];
  return encodeBytesBase64(new Uint8Array(f32.buffer, f32.byteOffset, f32.byteLength));
}

const BPLIST00_MAGIC = [0x62, 0x70, 0x6c, 0x69, 0x73, 0x74, 0x30, 0x30] as const;

export function isBinaryPlistBytes(bytes: Uint8Array): boolean {
  if (bytes.byteLength < BPLIST00_MAGIC.length) return false;
  for (let i = 0; i < BPLIST00_MAGIC.length; i++) {
    if (bytes[i] !== BPLIST00_MAGIC[i]) return false;
  }
  return true;
}

export function decodeFeaturePrintFloat32(base64: string): number[] | null {
  try {
    const bytes = decodeBytesBase64(base64);
    if (bytes.byteLength === 0 || bytes.byteLength % 4 !== 0) return null;
    // Guard macOS VNFeaturePrintObservation NSKeyedArchiver binary/XML plists from Float32 mis-decoding
    if (isBinaryPlistBytes(bytes)) return null;
    if (bytes.byteLength >= 5 && bytes[0] === 0x3c && (bytes[1] === 0x3f || bytes[1] === 0x21)) {
      return null;
    }
    const copy = new Uint8Array(bytes.byteLength);
    copy.set(bytes);
    const floats = new Float32Array(copy.buffer);
    const out = new Array<number>(floats.length);
    for (let i = 0; i < floats.length; i++) {
      const v = floats[i];
      if (!Number.isFinite(v) || Math.abs(v) > 1e6) return null;
      out[i] = v;
    }
    return out;
  } catch {
    return null;
  }
}

export function cosineSimilarity(a: readonly number[], b: readonly number[]): number {
  const len = Math.min(a.length, b.length);
  if (len === 0) return 0;
  let dot = 0;
  let magA = 0;
  let magB = 0;
  for (let i = 0; i < len; i++) {
    const va = a[i];
    const vb = b[i];
    dot += va * vb;
    magA += va * va;
    magB += vb * vb;
  }
  const denom = Math.sqrt(magA) * Math.sqrt(magB);
  if (!Number.isFinite(denom) || denom <= 1e-12) return 0;
  return dot / denom;
}

// MARK: - LibraryDatabase

const INITIAL_SCHEMA_STATEMENTS: readonly string[] = [
  `CREATE TABLE IF NOT EXISTS assets (
    id TEXT PRIMARY KEY,
    drive_id TEXT UNIQUE,
    content_hash TEXT NOT NULL,
    folder_id TEXT,
    kind TEXT NOT NULL,
    shape TEXT NOT NULL,
    title TEXT NOT NULL,
    rating INTEGER NOT NULL,
    size INTEGER NOT NULL,
    created REAL NOT NULL,
    last_opened REAL,
    pinned INTEGER NOT NULL,
    trashed INTEGER NOT NULL,
    payload TEXT NOT NULL
  )`,
  `CREATE INDEX IF NOT EXISTS assets_folder ON assets(folder_id, trashed)`,
  `CREATE INDEX IF NOT EXISTS assets_recency ON assets(trashed, created DESC)`,
  `CREATE INDEX IF NOT EXISTS assets_hash ON assets(content_hash) WHERE content_hash <> ''`,
  `CREATE VIRTUAL TABLE IF NOT EXISTS assets_fts USING fts5(
    title, fileName, notes, tags, ocrText, aiDescription, sourceDomain, pinyin, initials,
    tokenize='unicode61 remove_diacritics 2', prefix='2 3 4'
  )`,
  `CREATE TABLE IF NOT EXISTS asset_tags (
    asset_id TEXT REFERENCES assets(id) ON DELETE CASCADE,
    tag TEXT NOT NULL COLLATE NOCASE,
    PRIMARY KEY(asset_id, tag)
  )`,
  `CREATE INDEX IF NOT EXISTS asset_tags_lookup ON asset_tags(tag, asset_id)`,
  `CREATE TABLE IF NOT EXISTS asset_colors (
    asset_id TEXT REFERENCES assets(id) ON DELETE CASCADE,
    hex TEXT NOT NULL,
    l REAL NOT NULL,
    a REAL NOT NULL,
    b REAL NOT NULL,
    proportion REAL NOT NULL
  )`,
  `CREATE INDEX IF NOT EXISTS asset_colors_asset ON asset_colors(asset_id)`,
  `CREATE TABLE IF NOT EXISTS asset_vectors (
    asset_id TEXT PRIMARY KEY REFERENCES assets(id) ON DELETE CASCADE,
    feature_print TEXT,
    embedding BLOB,
    precision INTEGER NOT NULL DEFAULT 16,
    embedding_model TEXT
  )`,
  `CREATE TABLE IF NOT EXISTS folders (
    id TEXT PRIMARY KEY,
    parent_id TEXT,
    drive_id TEXT,
    sort_order INTEGER NOT NULL DEFAULT 0,
    payload TEXT NOT NULL
  )`,
  `CREATE INDEX IF NOT EXISTS folders_parent ON folders(parent_id, sort_order)`,
  `CREATE TABLE IF NOT EXISTS boards (
    id TEXT PRIMARY KEY,
    pinned INTEGER NOT NULL,
    updated_at REAL NOT NULL,
    payload TEXT NOT NULL
  )`,
  `CREATE TABLE IF NOT EXISTS board_assets (
    board_id TEXT REFERENCES boards(id) ON DELETE CASCADE,
    asset_id TEXT NOT NULL,
    PRIMARY KEY(board_id, asset_id)
  )`,
  `CREATE TABLE IF NOT EXISTS sync_ops (
    seq INTEGER PRIMARY KEY AUTOINCREMENT,
    payload TEXT NOT NULL
  )`,
  `CREATE TABLE IF NOT EXISTS sync_state (
    key TEXT PRIMARY KEY,
    payload TEXT NOT NULL
  )`,
  `CREATE TABLE IF NOT EXISTS original_cache (
    asset_id TEXT PRIMARY KEY REFERENCES assets(id) ON DELETE CASCADE,
    accessed_at REAL NOT NULL
  )`,
  `CREATE TABLE IF NOT EXISTS auth_users (
    id TEXT PRIMARY KEY,
    username TEXT NOT NULL UNIQUE COLLATE NOCASE,
    display_name TEXT NOT NULL,
    role TEXT NOT NULL DEFAULT 'owner',
    password_hash TEXT NOT NULL,
    password_salt TEXT NOT NULL,
    created_at TEXT NOT NULL,
    last_login_at TEXT
  )`,
  `CREATE TABLE IF NOT EXISTS auth_sessions (
    id TEXT PRIMARY KEY,
    user_id TEXT NOT NULL REFERENCES auth_users(id) ON DELETE CASCADE,
    token_hash TEXT NOT NULL UNIQUE,
    user_agent TEXT,
    ip_address TEXT,
    created_at TEXT NOT NULL,
    last_seen_at TEXT NOT NULL,
    expires_at TEXT NOT NULL
  )`,
  `CREATE INDEX IF NOT EXISTS auth_sessions_user ON auth_sessions(user_id)`,
  `CREATE TABLE IF NOT EXISTS auth_tokens (
    id TEXT PRIMARY KEY,
    user_id TEXT NOT NULL REFERENCES auth_users(id) ON DELETE CASCADE,
    name TEXT NOT NULL,
    prefix TEXT NOT NULL,
    token_hash TEXT NOT NULL UNIQUE,
    scopes TEXT NOT NULL,
    created_at TEXT NOT NULL,
    last_used_at TEXT,
    expires_at TEXT
  )`,
  `CREATE INDEX IF NOT EXISTS auth_tokens_user ON auth_tokens(user_id)`,
];

export class LibraryDatabase implements SyncOperationStore {
  public readonly dbPath: string;
  public readonly sql: ISqlDatabase;

  constructor(sql: ISqlDatabase, dbPath: string = ':memory:') {
    this.sql = sql;
    this.dbPath = dbPath;
    this.migrate();
  }

  close(): void {
    this.sql.close?.();
  }

  private migrate(): void {
    this.sql.exec('CREATE TABLE IF NOT EXISTS sync_state (key TEXT PRIMARY KEY, payload TEXT NOT NULL);');
    const storedVersion = this.getState<number>(SCHEMA_VERSION_STATE_KEY);
    let version = typeof storedVersion === 'number' && Number.isFinite(storedVersion) ? storedVersion : 0;

    if (version === 0) {
      // Detect existing pre-refactor Node SQLite databases that already have all tables created
      const existingAssetsTable = this.sql.get<{ name: string }>(
        "SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'assets'",
      );
      if (existingAssetsTable) {
        version = SCHEMA_VERSION;
        this.setState(SCHEMA_VERSION_STATE_KEY, SCHEMA_VERSION);
        return;
      }
    }

    if (version > SCHEMA_VERSION) {
      throw new Error(`Library schema ${version} requires a newer version of Charkle Web.`);
    }
    if (version === SCHEMA_VERSION) return;

    this.transaction(() => {
      if (version === 0) {
        for (const stmt of INITIAL_SCHEMA_STATEMENTS) {
          this.sql.exec(stmt);
        }
      }
      this.setState(SCHEMA_VERSION_STATE_KEY, SCHEMA_VERSION);
    });
  }

  transaction<T>(work: () => T): T {
    return this.sql.transaction(work);
  }

  // MARK: - Assets

  upsertAssets(assets: readonly AssetRecord[]): void {
    this.transaction(() => {
      for (const asset of assets) {
        this.putAsset(asset);
      }
    });
  }

  putAsset(rawAsset: AssetRecord): void {
    const asset: AssetRecord = {
      ...rawAsset,
      id: toSwiftUUID(rawAsset.id),
      folderID: rawAsset.folderID ? toSwiftUUID(rawAsset.folderID) : null,
    };
    const old = this.getAsset(asset.id);
    const parsedCreated = Date.parse(asset.createdAt);
    const createdSec = Number.isFinite(parsedCreated) ? parsedCreated / 1000 : Date.now() / 1000;
    const parsedLastOpened = asset.lastOpenedAt ? Date.parse(asset.lastOpenedAt) : Number.NaN;
    const lastOpenedSec = Number.isFinite(parsedLastOpened) ? parsedLastOpened / 1000 : null;
    const shape = classifyAspectShape(asset.pixelWidth, asset.pixelHeight);

    this.sql.run(
      `INSERT INTO assets (
          id, drive_id, content_hash, folder_id, kind, shape, title, rating, size,
          created, last_opened, pinned, trashed, payload
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
          drive_id=excluded.drive_id,
          content_hash=excluded.content_hash,
          folder_id=excluded.folder_id,
          kind=excluded.kind,
          shape=excluded.shape,
          title=excluded.title,
          rating=excluded.rating,
          size=excluded.size,
          created=excluded.created,
          last_opened=excluded.last_opened,
          pinned=excluded.pinned,
          trashed=excluded.trashed,
          payload=excluded.payload`,
      [
        asset.id,
        asset.driveFileID ?? null,
        asset.contentHash ?? '',
        asset.folderID ?? null,
        asset.mediaKind,
        shape,
        asset.title,
        Math.max(0, Math.min(5, Math.trunc(asset.rating))),
        asset.fileSizeBytes,
        createdSec,
        lastOpenedSec,
        asset.pinnedOffline ? 1 : 0,
        asset.isTrashed ? 1 : 0,
        JSON.stringify(asset),
      ],
    );

    if (!old || JSON.stringify(old.tags) !== JSON.stringify(asset.tags)) {
      this.sql.run('DELETE FROM asset_tags WHERE asset_id = ?', [asset.id]);
      for (const tag of asset.tags) {
        const clean = tag.trim();
        if (clean.length > 0) {
          this.sql.run('INSERT OR IGNORE INTO asset_tags(asset_id, tag) VALUES (?, ?)', [
            asset.id,
            clean,
          ]);
        }
      }
    }

    if (!old || JSON.stringify(old.dominantColors) !== JSON.stringify(asset.dominantColors)) {
      this.sql.run('DELETE FROM asset_colors WHERE asset_id = ?', [asset.id]);
      for (const c of asset.dominantColors) {
        if (Number.isFinite(c.l) && Number.isFinite(c.a) && Number.isFinite(c.b)) {
          this.sql.run(
            'INSERT INTO asset_colors(asset_id, hex, l, a, b, proportion) VALUES (?, ?, ?, ?, ?, ?)',
            [asset.id, c.hex, c.l, c.a, c.b, c.proportion ?? 0],
          );
        }
      }
    }

    const fields = LibraryDatabase.searchFields(asset);
    const oldFields = old ? LibraryDatabase.searchFields(old) : null;
    if (!oldFields || JSON.stringify(oldFields) !== JSON.stringify(fields)) {
      const rowidRow = this.sql.get<{ rowid: number }>('SELECT rowid FROM assets WHERE id = ?', [
        asset.id,
      ]);
      if (rowidRow) {
        if (old) {
          this.sql.run('DELETE FROM assets_fts WHERE rowid = ?', [rowidRow.rowid]);
        }
        const phonetics = fields.map((f) => extractPinyin(f));
        const indexedTokens = fields.map((f) => indexSearchText(f));
        const fullPinyin = phonetics
          .map((p) => p.full)
          .filter(Boolean)
          .join(' ');
        const initialsPinyin = phonetics
          .map((p) => p.initials)
          .filter(Boolean)
          .join(' ');

        this.sql.run(
          `INSERT INTO assets_fts(
              rowid, title, fileName, notes, tags, ocrText, aiDescription, sourceDomain, pinyin, initials
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
          [
            rowidRow.rowid,
            indexedTokens[0],
            indexedTokens[1],
            indexedTokens[2],
            indexedTokens[3],
            indexedTokens[4],
            indexedTokens[5],
            indexedTokens[6],
            fullPinyin,
            initialsPinyin,
          ],
        );
      }
    }
  }

  private static searchFields(asset: AssetRecord): [string, string, string, string, string, string, string] {
    let extraOCR = asset.ocrText ?? '';
    const repo = asset.richMetadata?.githubRepo;
    if (repo) {
      const repoText = [
        repo.fullName,
        repo.description ?? '',
        repo.language ?? '',
        repo.topics.join(' '),
        (repo.readmeMarkdown ?? '').slice(0, 4000),
      ]
        .filter((s) => s.length > 0)
        .join('\n');
      if (repoText) {
        extraOCR = extraOCR ? `${extraOCR}\n${repoText}` : repoText;
      }
    }
    const post = asset.richMetadata?.socialPost;
    if (post) {
      const postText = [
        socialPlatformDisplayName(post.platform),
        post.authorName,
        `@${post.authorHandle}`,
        post.articleTitle ?? '',
        post.bodyText,
        post.quotedText ?? '',
      ]
        .filter((s) => s.length > 0)
        .join('\n');
      if (postText) {
        extraOCR = extraOCR ? `${extraOCR}\n${postText}` : postText;
      }
    }
    const exif = asset.richMetadata?.photoExif;
    if (exif) {
      const exifText = [
        getPhotoExifCameraDisplayName(exif) ?? '',
        exif.lensModel ?? '',
        getPhotoExifExposureSummary(exif) ?? '',
        exif.software ?? '',
        exif.artist ?? '',
      ]
        .filter((s) => s.length > 0)
        .join('\n');
      if (exifText) {
        extraOCR = extraOCR ? `${extraOCR}\n${exifText}` : exifText;
      }
    }
    const ai = asset.richMetadata?.aiGeneration;
    if (ai) {
      const aiText = [
        ai.generator ?? '',
        ai.modelName ?? '',
        ai.sampler ?? '',
        ai.loras.join(' '),
        (ai.prompt ?? '').slice(0, 2000),
        (ai.negativePrompt ?? '').slice(0, 600),
      ]
        .filter((s) => s.length > 0)
        .join('\n');
      if (aiText) {
        extraOCR = extraOCR ? `${extraOCR}\n${aiText}` : aiText;
      }
    }
    return [
      asset.title,
      asset.fileName,
      asset.notes,
      asset.tags.join(' '),
      extraOCR,
      asset.aiDescription ?? '',
      asset.sourceDomain ?? '',
    ];
  }

  saveAssetLocally(value: AssetRecord, projectLocation = true): AssetRecord {
    return this.transaction(() => {
      const id = toSwiftUUID(value.id);
      if (this.isTombstoned('asset', id)) {
        throw new LibraryDatabaseError(
          `Asset ${id} has been permanently deleted.`,
          409,
          'ENTITY_TOMBSTONED',
        );
      }
      const existing = this.getAsset(id);
      const asset: AssetRecord = {
        ...value,
        id,
        folderID: value.folderID ? toSwiftUUID(value.folderID) : null,
      };
      let prior = existing ? { ...existing } : null;
      if (asset.driveFileID?.startsWith('mounted-')) {
        asset.driveFileID = prior?.driveFileID ?? null;
      }
      if (prior?.driveFileID?.startsWith('mounted-')) {
        prior = { ...prior, driveFileID: null };
        if (asset.driveFileID?.startsWith('mounted-')) {
          asset.driveFileID = null;
        }
      }
      const delta = diffAssetChanges(asset, prior);
      if (!isAssetChangesEmpty(delta)) {
        this.recordSyncChange({ type: 'asset', delta }, projectLocation);
      }
      const saved = this.getAsset(id) ?? asset;
      const finalAsset: AssetRecord = {
        ...saved,
        isLocalOriginalCached: value.isLocalOriginalCached,
        driveFileID: value.driveFileID ?? saved.driveFileID ?? null,
      };
      this.putAsset(finalAsset);
      return finalAsset;
    });
  }

  getAsset(id: UUID): AssetRecord | null {
    const row = this.sql.get<{ payload: string }>('SELECT payload FROM assets WHERE id = ?', [
      toSwiftUUID(id),
    ]);
    return row ? (JSON.parse(row.payload) as AssetRecord) : null;
  }

  getAssetByDriveID(driveID: string): AssetRecord | null {
    const row = this.sql.get<{ payload: string }>('SELECT payload FROM assets WHERE drive_id = ?', [
      driveID,
    ]);
    return row ? (JSON.parse(row.payload) as AssetRecord) : null;
  }

  getAssetsByContentHash(contentHash: string): AssetRecord[] {
    if (!contentHash) return [];
    const rows = this.sql.all<{ payload: string }>(
      'SELECT payload FROM assets WHERE content_hash = ?',
      [contentHash],
    );
    return rows.map((r) => JSON.parse(r.payload) as AssetRecord);
  }

  getAssetDriveBindings(): Array<{ driveID: string; assetID: UUID }> {
    const rows = this.sql.all<{ drive_id: string; id: string }>(
      'SELECT drive_id, id FROM assets WHERE drive_id IS NOT NULL',
    );
    return rows.map((r) => ({ driveID: r.drive_id, assetID: r.id }));
  }

  removeAsset(id: UUID): void {
    const uid = toSwiftUUID(id);
    this.sql.run('DELETE FROM assets_fts WHERE rowid IN (SELECT rowid FROM assets WHERE id = ?)', [
      uid,
    ]);
    this.sql.run('DELETE FROM assets WHERE id = ?', [uid]);
  }

  /**
   * Local-only activity stamp (does NOT emit a sync op, matching macOS PARITY_SPEC 4.1).
   */
  markAssetOpened(id: UUID, now: Date = new Date()): AssetRecord | null {
    const existing = this.getAsset(id);
    if (!existing) return null;
    const updated: AssetRecord = {
      ...existing,
      lastOpenedAt: now.toISOString(),
    };
    this.putAsset(updated);
    return updated;
  }

  recentActivityAssets(limit = 40): AssetRecord[] {
    const rows = this.sql.all<{ payload: string }>(
      `SELECT payload FROM assets
         WHERE trashed = 0
         ORDER BY MAX(created, COALESCE(last_opened, -1e18)) DESC, id ASC
         LIMIT ?`,
      [Math.max(0, limit)],
    );
    return rows.map((r) => JSON.parse(r.payload) as AssetRecord);
  }

  applyBatchPatch(patch: AssetBatchPatch): AssetRecord[] {
    return this.transaction(() => {
      if (patch.folderAssignment.type === 'folder') {
        const targetFolderID = toSwiftUUID(patch.folderAssignment.folderID);
        if (!this.getFolder(targetFolderID)) {
          throw new LibraryDatabaseError(
            `Folder ${targetFolderID} not found.`,
            404,
            'FOLDER_NOT_FOUND',
          );
        }
      }

      const updated: AssetRecord[] = [];
      const removeSet = new Set(patch.removeTags.map((t) => normalizeSearchText(t)).filter(Boolean));
      const dismissSet = new Set(
        patch.dismissSuggestedTags.map((t) => normalizeSearchText(t)).filter(Boolean),
      );
      const addTagsClean = patch.addTags.map((t) => t.trim()).filter(Boolean);

      // Deduplicate assetIDs while preserving order
      const seenIDs = new Set<UUID>();
      const uniqueAssetIDs: UUID[] = [];
      for (const rawId of patch.assetIDs) {
        const uid = toSwiftUUID(rawId);
        if (!seenIDs.has(uid)) {
          seenIDs.add(uid);
          uniqueAssetIDs.push(uid);
        }
      }

      for (const uid of uniqueAssetIDs) {
        const current = this.getAsset(uid);
        if (!current) continue;
        const next: AssetRecord = { ...current };

        if (patch.title !== undefined && patch.title !== null) {
          next.title = patch.title.trim() || next.title;
        }
        if (patch.notes !== undefined && patch.notes !== null) {
          next.notes = patch.notes;
        }
        if (patch.rating !== undefined && patch.rating !== null) {
          next.rating = Math.max(0, Math.min(5, Math.trunc(patch.rating)));
        }
        if (patch.pinnedOffline !== undefined && patch.pinnedOffline !== null) {
          next.pinnedOffline = patch.pinnedOffline;
        }
        if (patch.isTrashed !== undefined && patch.isTrashed !== null) {
          next.isTrashed = patch.isTrashed;
        }
        if (patch.folderAssignment.type === 'inbox') {
          next.folderID = null;
        } else if (patch.folderAssignment.type === 'folder') {
          next.folderID = toSwiftUUID(patch.folderAssignment.folderID);
        }

        // Tag mutations matching Swift LiveCharkleEngine order:
        // 1. Existing tags + addTags
        const tagByNorm = new Map<string, string>();
        for (const t of next.tags) {
          const n = normalizeSearchText(t);
          if (n) tagByNorm.set(n, t);
        }
        for (const t of addTagsClean) {
          const n = normalizeSearchText(t);
          if (n) tagByNorm.set(n, t);
        }

        // 2. Suggested tags: dismiss FIRST, then accept remaining if acceptSuggestedTags is true
        let suggested = [...next.suggestedTags];
        if (dismissSet.size > 0) {
          suggested = suggested.filter((st) => !dismissSet.has(normalizeSearchText(st)));
        }
        if (patch.acceptSuggestedTags) {
          for (const st of suggested) {
            const n = normalizeSearchText(st);
            if (n && !tagByNorm.has(n)) tagByNorm.set(n, st.trim());
          }
          suggested = [];
        }

        // 3. Explicit removeTags applied LAST so user removals always win
        for (const rm of removeSet) {
          tagByNorm.delete(rm);
        }

        next.tags = Array.from(tagByNorm.values()).sort((a, b) => a.localeCompare(b));
        next.suggestedTags = suggested;

        const saved = this.saveAssetLocally(next);
        updated.push(saved);
      }
      return updated;
    });
  }

  permanentDeleteAssets(ids: readonly UUID[], md5ByID?: ReadonlyMap<UUID, string>): number {
    return this.transaction(() => {
      let count = 0;
      for (const rawId of ids) {
        const id = toSwiftUUID(rawId);
        const existing = this.getAsset(id);
        if (!existing) continue;
        const md5 = md5ByID?.get(id)?.toLowerCase() ?? null;
        this.recordSyncChange({
          type: 'deleteAsset',
          id,
          driveID: existing.driveFileID ?? null,
        });
        if (md5) {
          this.setState(`deleted.md5.${md5}`, true);
          if (existing.contentHash) {
            const existingFp = this.getState<{
              assetID: UUID;
              sha256: string;
              md5?: string | null;
              fileName: string;
              deletedAt: string;
            }>(`deleted.content.${existing.contentHash}`);
            if (existingFp) {
              this.setState(`deleted.content.${existing.contentHash}`, { ...existingFp, md5 });
            }
          }
        }
        count++;
      }
      return count;
    });
  }

  // MARK: - FilterCriteria SQL Builder (Recursive CTE + CIELAB + FTS5 + Pinyin)

  private buildAssetWhere(
    filters: FilterCriteria,
  ): { cte: string; source: string; where: string; order: string; args: SqlParam[]; ftsQuery: string } {
    const clauses: string[] = [];
    const args: SqlParam[] = [];
    let cte = '';

    if (filters.onlyTrashed) {
      clauses.push('a.trashed = 1');
    } else if (!filters.includeTrashed) {
      clauses.push('a.trashed = 0');
    }

    if (filters.onlyInbox) {
      clauses.push('a.folder_id IS NULL AND a.trashed = 0');
    }

    if (filters.folderID) {
      const folderID = toSwiftUUID(filters.folderID);
      if (filters.includeSubfolders) {
        cte = `WITH RECURSIVE folder_subtree(id) AS (
          SELECT ?
          UNION
          SELECT f.id FROM folders f JOIN folder_subtree s ON f.parent_id = s.id
        ) `;
        args.push(folderID);
        clauses.push('a.folder_id IN (SELECT id FROM folder_subtree)');
      } else {
        clauses.push('a.folder_id = ?');
        args.push(folderID);
      }
    }

    if (filters.shape) {
      clauses.push('a.shape = ?');
      args.push(filters.shape);
    }

    if (filters.minRating > 0) {
      clauses.push('a.rating >= ?');
      args.push(Math.trunc(filters.minRating));
    }

    if (filters.onlyPinnedOffline) {
      clauses.push('a.pinned = 1');
    }

    if (filters.onlyRecentDays !== null && filters.onlyRecentDays !== undefined) {
      const cutoff = Date.now() / 1000 - Math.max(0, filters.onlyRecentDays) * 86_400;
      clauses.push('MAX(a.created, COALESCE(a.last_opened, 0)) >= ?');
      args.push(cutoff);
    }

    if (filters.kinds.length > 0) {
      const sorted = [...filters.kinds].sort();
      clauses.push(`a.kind IN (${sorted.map(() => '?').join(',')})`);
      args.push(...sorted);
    }

    if (filters.onlyUntagged) {
      clauses.push('NOT EXISTS (SELECT 1 FROM asset_tags WHERE asset_id = a.id)');
    }

    for (const tag of [...filters.tags].sort()) {
      clauses.push('EXISTS (SELECT 1 FROM asset_tags WHERE asset_id = a.id AND tag = ?)');
      args.push(tag);
    }

    if (filters.selectedColorHex) {
      const target = labFromHex(filters.selectedColorHex);
      const tol = Math.max(0, filters.colorTolerance);
      clauses.push(
        `EXISTS (
          SELECT 1 FROM asset_colors c
          WHERE c.asset_id = a.id
            AND ((c.l - ?) * (c.l - ?) + (c.a - ?) * (c.a - ?) + (c.b - ?) * (c.b - ?)) <= ?
        )`,
      );
      args.push(target.l, target.l, target.a, target.a, target.b, target.b, tol * tol);
    }

    const ftsQuery = buildFtsQuery(filters.searchQuery);
    if (ftsQuery.length > 0) {
      clauses.push('assets_fts MATCH ?');
      args.push(ftsQuery);
    }

    const source =
      ftsQuery.length === 0
        ? 'assets a'
        : 'assets_fts JOIN assets a ON a.rowid = assets_fts.rowid';

    let order: string;
    switch (filters.sortBy) {
      case 'newest':
        order = 'a.created DESC';
        break;
      case 'oldest':
        order = 'a.created ASC';
        break;
      case 'nameAsc':
        order = 'a.title COLLATE NOCASE ASC';
        break;
      case 'ratingDesc':
        order = 'a.rating DESC, a.created DESC';
        break;
      case 'fileSizeDesc':
        order = 'a.size DESC, a.created DESC';
        break;
      case 'relevance':
        order =
          ftsQuery.length === 0
            ? 'a.created DESC'
            : 'bm25(assets_fts, 8, 3, 1, 5, 2, 2, 1, 3, 2) ASC, a.created DESC';
        break;
    }

    const where = clauses.length > 0 ? ` WHERE ${clauses.join(' AND ')}` : '';
    return { cte, source, where, order, args, ftsQuery };
  }

  fetchAssets(
    partialCriteria?: Partial<FilterCriteria>,
    limit?: number,
    offset?: number,
  ): AssetRecord[] {
    const filters = createDefaultFilterCriteria(partialCriteria ?? {});
    const { cte, source, where, order, args } = this.buildAssetWhere(filters);
    const pageArgs = [...args];
    let pageSql = '';
    if (limit !== undefined && limit !== null) {
      pageSql += ' LIMIT ?';
      pageArgs.push(Math.max(0, Math.trunc(limit)));
      if (offset !== undefined && offset !== null && offset > 0) {
        pageSql += ' OFFSET ?';
        pageArgs.push(Math.trunc(offset));
      }
    } else if (offset !== undefined && offset !== null && offset > 0) {
      pageSql += ' LIMIT -1 OFFSET ?';
      pageArgs.push(Math.trunc(offset));
    }
    const sql = `${cte}SELECT a.payload FROM ${source}${where} ORDER BY ${order}, a.id ASC${pageSql}`;
    const rows = this.sql.all<{ payload: string }>(sql, pageArgs);
    return rows.map((r) => JSON.parse(r.payload) as AssetRecord);
  }

  countAssets(partialCriteria?: Partial<FilterCriteria>): number {
    const filters = createDefaultFilterCriteria(partialCriteria ?? {});
    const { cte, source, where, args } = this.buildAssetWhere(filters);
    const sql = `${cte}SELECT COUNT(*) AS cnt FROM ${source}${where}`;
    const row = this.sql.get<{ cnt: number }>(sql, args);
    return Number(row?.cnt ?? 0);
  }

  searchRanks(query: string): Map<UUID, number> {
    const ftsQuery = buildFtsQuery(query);
    if (!ftsQuery) return new Map();
    const filters = createDefaultFilterCriteria({ searchQuery: query, sortBy: 'relevance' });
    const { cte, source, where, order, args } = this.buildAssetWhere(filters);
    const sql = `${cte}SELECT a.id FROM ${source}${where} ORDER BY ${order}, a.id ASC`;
    const rows = this.sql.all<{ id: string }>(sql, args);
    const denomBase = Math.max(8, Math.floor(rows.length / 4));
    const ranks = new Map<UUID, number>();
    for (let i = 0; i < rows.length; i++) {
      ranks.set(rows[i].id, 1 / (1 + i / denomBase));
    }
    return ranks;
  }

  // MARK: - Folders

  getFolderSubtreeIDs(rootID: UUID): UUID[] {
    const rows = this.sql.all<{ id: string }>(
      `WITH RECURSIVE sub(id) AS (
          SELECT ?
          UNION
          SELECT f.id FROM folders f JOIN sub s ON f.parent_id = s.id
        )
        SELECT id FROM sub`,
      [toSwiftUUID(rootID)],
    );
    return rows.map((r) => r.id);
  }

  fetchFolders(): FolderRecord[] {
    const rows = this.sql.all<{ payload: string; cnt: number }>(
      `SELECT f.payload,
          (SELECT COUNT(*) FROM assets a WHERE a.folder_id = f.id AND a.trashed = 0) AS cnt
         FROM folders f`,
    );

    const folders = rows.map((r) => {
      const folder = JSON.parse(r.payload) as FolderRecord;
      folder.assetCount = Number(r.cnt ?? 0);
      return folder;
    });
    folders.sort((a, b) => {
      if (a.sortOrder !== b.sortOrder) return a.sortOrder - b.sortOrder;
      const nameCmp = a.name.localeCompare(b.name);
      if (nameCmp !== 0) return nameCmp;
      return a.id.localeCompare(b.id);
    });
    return folders;
  }

  getFolder(id: UUID): FolderRecord | null {
    const row = this.sql.get<{ payload: string; cnt: number }>(
      `SELECT f.payload,
          (SELECT COUNT(*) FROM assets a WHERE a.folder_id = f.id AND a.trashed = 0) AS cnt
         FROM folders f WHERE f.id = ?`,
      [toSwiftUUID(id)],
    );
    if (!row) return null;
    const folder = JSON.parse(row.payload) as FolderRecord;
    folder.assetCount = Number(row.cnt ?? 0);
    return folder;
  }

  upsertFolder(folder: FolderRecord): void {
    this.putFolder(folder);
  }

  putFolder(rawFolder: FolderRecord): void {
    const folder: FolderRecord = {
      ...rawFolder,
      id: toSwiftUUID(rawFolder.id),
      parentID: rawFolder.parentID ? toSwiftUUID(rawFolder.parentID) : null,
    };
    this.sql.run(
      `INSERT INTO folders (id, parent_id, drive_id, sort_order, payload)
         VALUES (?, ?, ?, ?, ?)
         ON CONFLICT(id) DO UPDATE SET
           parent_id=excluded.parent_id,
           drive_id=excluded.drive_id,
           sort_order=excluded.sort_order,
           payload=excluded.payload`,
      [
        folder.id,
        folder.parentID ?? null,
        folder.driveFolderID ?? null,
        folder.sortOrder,
        JSON.stringify(folder),
      ],
    );
  }

  removeFolder(id: UUID): void {
    this.sql.run('DELETE FROM folders WHERE id = ?', [toSwiftUUID(id)]);
  }

  private disambiguateFolderName(
    baseName: string,
    parentID: UUID | null,
    siblings: readonly FolderRecord[],
    excludingID?: UUID | null,
  ): string {
    const trimmed = baseName.trim() || '新建文件夹';
    const excl = excludingID ? toSwiftUUID(excludingID) : null;
    const used = new Set(
      siblings
        .filter((f) => (f.parentID ?? null) === parentID && f.id !== excl)
        .map((f) => f.name.toLowerCase()),
    );
    const collides = (candidate: string): boolean =>
      (parentID === null && candidate.toLowerCase() === 'inbox') ||
      used.has(candidate.toLowerCase());
    if (!collides(trimmed)) return trimmed;
    for (let idx = 2; idx < 1000; idx++) {
      const candidate = `${trimmed} ${idx}`;
      if (!collides(candidate)) return candidate;
    }
    return `${trimmed} ${Date.now()}`;
  }

  private ensureUniqueSiblingFolder(
    name: string,
    parentID: UUID | null,
    folders: readonly FolderRecord[],
    excludingID?: UUID | null,
  ): void {
    const excl = excludingID ? toSwiftUUID(excludingID) : null;
    const lower = name.toLowerCase();
    const conflict = folders.find(
      (f) =>
        (f.parentID ?? null) === parentID &&
        f.id !== excl &&
        f.name.toLowerCase() === lower,
    );
    if (conflict) {
      throw new LibraryDatabaseError(
        `同级目录下已存在名为「${name}」的文件夹。`,
        409,
        'FOLDER_EXISTS',
      );
    }
  }

  createFolder(name: string, parentID?: UUID | null): FolderRecord {
    return this.transaction(() => {
      const parent = parentID ? toSwiftUUID(parentID) : null;
      const validName = validateFolderName(name, parent);
      const allFolders = this.fetchFolders();
      if (parent && !allFolders.some((f) => f.id === parent)) {
        throw new LibraryDatabaseError(`Parent folder ${parent} not found.`, 404, 'FOLDER_NOT_FOUND');
      }
      this.ensureUniqueSiblingFolder(validName, parent, allFolders, null);
      const maxSort = allFolders.reduce((m, f) => Math.max(m, f.sortOrder), -1);
      const now = new Date().toISOString();
      const folder: FolderRecord = {
        id: toSwiftUUID(randomUUID()),
        name: validName,
        parentID: parent,
        driveFolderID: null,
        colorHex: null,
        customSymbol: null,
        sortOrder: maxSort + 1,
        assetCount: 0,
        createdAt: now,
        updatedAt: now,
      };
      this.recordSyncChange({ type: 'folder', folder });
      return this.getFolder(folder.id) ?? folder;
    });
  }

  renameFolder(id: UUID, name: string): FolderRecord {
    return this.transaction(() => {
      const existing = this.getFolder(id);
      if (!existing) {
        throw new LibraryDatabaseError(`Folder ${id} not found.`, 404, 'FOLDER_NOT_FOUND');
      }
      const validName = validateFolderName(name, existing.parentID ?? null);
      const allFolders = this.fetchFolders();
      this.ensureUniqueSiblingFolder(validName, existing.parentID ?? null, allFolders, existing.id);
      if (validName === existing.name) {
        return existing;
      }
      const updated: FolderRecord = {
        ...existing,
        name: validName,
        updatedAt: new Date().toISOString(),
      };
      this.recordSyncChange({ type: 'folder', folder: updated });
      return this.getFolder(existing.id) ?? updated;
    });
  }

  moveFolder(id: UUID, newParentID: UUID | null, insertAtIndex?: number | null): FolderRecord[] {
    return this.transaction(() => {
      const folderID = toSwiftUUID(id);
      const targetParent = newParentID ? toSwiftUUID(newParentID) : null;
      const existing = this.getFolder(folderID);
      if (!existing) {
        throw new LibraryDatabaseError(`Folder ${folderID} not found.`, 404, 'FOLDER_NOT_FOUND');
      }

      if (targetParent) {
        if (!this.getFolder(targetParent)) {
          throw new LibraryDatabaseError(
            `Target parent folder ${targetParent} not found.`,
            404,
            'FOLDER_NOT_FOUND',
          );
        }
        const subtree = new Set(this.getFolderSubtreeIDs(folderID));
        if (subtree.has(targetParent)) {
          throw new LibraryDatabaseError(
            'Cannot move a folder into itself or one of its descendants.',
            400,
            'FOLDER_CYCLE',
          );
        }
      }

      const allFolders = this.fetchFolders();
      const uniqueName = this.disambiguateFolderName(existing.name, targetParent, allFolders, folderID);
      validateFolderName(uniqueName, targetParent);
      const siblings = allFolders.filter(
        (f) => (f.parentID ?? null) === targetParent && f.id !== folderID,
      );
      const clampedIndex =
        insertAtIndex === undefined || insertAtIndex === null
          ? siblings.length
          : Math.max(0, Math.min(siblings.length, Math.trunc(insertAtIndex)));

      const now = new Date().toISOString();
      const moved: FolderRecord = {
        ...existing,
        name: uniqueName,
        parentID: targetParent,
        updatedAt: now,
      };
      siblings.splice(clampedIndex, 0, moved);

      for (let i = 0; i < siblings.length; i++) {
        const sib = siblings[i];
        if (sib.id === folderID || sib.sortOrder !== i) {
          this.recordSyncChange({
            type: 'folder',
            folder: { ...sib, sortOrder: i, updatedAt: now },
          });
        }
      }
      return this.fetchFolders();
    });
  }

  updateFolderAppearance(
    id: UUID,
    appearance: { colorHex?: string | null; customSymbol?: string | null },
  ): FolderRecord {
    return this.transaction(() => {
      const existing = this.getFolder(id);
      if (!existing) {
        throw new LibraryDatabaseError(`Folder ${id} not found.`, 404, 'FOLDER_NOT_FOUND');
      }
      const normalizeOpt = (val: string | null | undefined, fallback: string | null): string | null => {
        if (val === undefined) return fallback;
        if (val === null) return null;
        const trimmed = val.trim();
        return trimmed.length > 0 ? trimmed : null;
      };
      const updated: FolderRecord = {
        ...existing,
        colorHex: normalizeOpt(appearance.colorHex, existing.colorHex ?? null),
        customSymbol: normalizeOpt(appearance.customSymbol, existing.customSymbol ?? null),
        updatedAt: new Date().toISOString(),
      };
      this.recordSyncChange({ type: 'folder', folder: updated });
      return this.getFolder(existing.id) ?? updated;
    });
  }

  deleteFolder(id: UUID, trashContents = false): void {
    this.transaction(() => {
      const folderID = toSwiftUUID(id);
      const existing = this.getFolder(folderID);
      if (!existing) return;

      if (!trashContents) {
        // Move direct assets to Inbox; reparent direct children to deleted folder's parent
        // with sibling & root-Inbox collision disambiguation (matching Swift LiveCharkleEngine).
        const directAssets = this.fetchAssets({ folderID, includeTrashed: true });
        for (const asset of directAssets) {
          this.saveAssetLocally({ ...asset, folderID: null });
        }
        const allFolders = this.fetchFolders();
        const targetParent = existing.parentID ?? null;
        const children = allFolders.filter((f) => f.parentID === folderID);
        const targetSiblings = allFolders.filter(
          (f) => (f.parentID ?? null) === targetParent && f.id !== folderID,
        );
        const now = new Date().toISOString();
        for (const child of children) {
          const safeName = this.disambiguateFolderName(
            child.name,
            targetParent,
            targetSiblings,
            child.id,
          );
          const reparented: FolderRecord = {
            ...child,
            name: safeName,
            parentID: targetParent,
            updatedAt: now,
          };
          this.recordSyncChange({ type: 'folder', folder: reparented });
          targetSiblings.push(reparented);
        }
        this.recordSyncChange({
          type: 'deleteFolder',
          id: folderID,
          driveID: existing.driveFolderID ?? null,
        });
      } else {
        // Collect subtree post-order, trash all non-trashed assets in subtree, delete all folders in subtree
        const allFolders = this.fetchFolders();
        const byID = new Map<UUID, FolderRecord>(allFolders.map((f) => [f.id, f]));
        const childrenMap = new Map<UUID, UUID[]>();
        for (const f of allFolders) {
          if (f.parentID) {
            const list = childrenMap.get(f.parentID) ?? [];
            list.push(f.id);
            childrenMap.set(f.parentID, list);
          }
        }
        const postOrder: UUID[] = [];
        const visited = new Set<UUID>();
        const dfs = (cur: UUID): void => {
          if (visited.has(cur)) return;
          visited.add(cur);
          for (const child of childrenMap.get(cur) ?? []) dfs(child);
          postOrder.push(cur);
        };
        dfs(folderID);

        for (const subID of postOrder) {
          const assets = this.fetchAssets({ folderID: subID, includeTrashed: true });
          for (const asset of assets) {
            if (!asset.isTrashed) {
              this.saveAssetLocally({ ...asset, folderID: null, isTrashed: true });
            } else {
              this.saveAssetLocally({ ...asset, folderID: null });
            }
          }
        }
        for (const subID of postOrder) {
          const f = byID.get(subID);
          this.recordSyncChange({
            type: 'deleteFolder',
            id: subID,
            driveID: f?.driveFolderID ?? null,
          });
        }
      }
    });
  }

  getFolderPath(id: UUID): string {
    const folders = new Map(this.fetchFolders().map((f) => [f.id, f]));
    const parts: string[] = [];
    const seen = new Set<UUID>();
    let cur: UUID | null | undefined = toSwiftUUID(id);
    while (cur && !seen.has(cur)) {
      seen.add(cur);
      const folder = folders.get(cur);
      if (!folder) break;
      parts.unshift(folder.name);
      cur = folder.parentID;
    }
    return parts.join('/');
  }

  findFolderByPath(folderPath: string): FolderRecord | null {
    const cleanParts = folderPath
      .split('/')
      .map((s) => s.trim().toLowerCase())
      .filter(Boolean);
    if (cleanParts.length === 0) return null;
    const all = this.fetchFolders();
    let parentID: UUID | null = null;
    let found: FolderRecord | null = null;
    for (const seg of cleanParts) {
      found =
        all.find((f) => (f.parentID ?? null) === parentID && f.name.toLowerCase() === seg) ?? null;
      if (!found) return null;
      parentID = found.id;
    }
    return found;
  }

  // MARK: - Smart Folders (sync_state key: 'smart_folders.v1')

  fetchSmartFolders(): SmartFolderRecord[] {
    const list = this.getState<SmartFolderRecord[]>(SMART_FOLDERS_STATE_KEY) ?? [];
    return [...list].sort((a, b) => {
      if (a.sortOrder !== b.sortOrder) return a.sortOrder - b.sortOrder;
      const nameCmp = a.name.localeCompare(b.name);
      if (nameCmp !== 0) return nameCmp;
      return a.id.localeCompare(b.id);
    });
  }

  saveSmartFolder(record: SmartFolderRecord): SmartFolderRecord {
    return this.transaction(() => {
      const list = this.fetchSmartFolders();
      const id = toSwiftUUID(record.id);
      const now = new Date().toISOString();
      const trimmedColor = record.colorHex?.trim() ?? '';
      const trimmedName = record.name.trim();
      const normalized: SmartFolderRecord = {
        ...record,
        id,
        name: trimmedName || '未命名智能文件夹',
        colorHex: trimmedColor.length > 0 ? trimmedColor : null,
        updatedAt: now,
        createdAt: record.createdAt || now,
      };
      const idx = list.findIndex((s) => toSwiftUUID(s.id) === id);
      if (idx >= 0) {
        list[idx] = normalized;
      } else {
        list.push(normalized);
      }
      this.setState(SMART_FOLDERS_STATE_KEY, list);
      return normalized;
    });
  }

  deleteSmartFolder(id: UUID): void {
    this.transaction(() => {
      const uid = toSwiftUUID(id);
      const next = this.fetchSmartFolders().filter((s) => toSwiftUUID(s.id) !== uid);
      this.setState(SMART_FOLDERS_STATE_KEY, next);
    });
  }

  fetchAssetsForSmartFolder(
    smartFolderID: UUID,
    extraCriteria?: Partial<FilterCriteria>,
    limit?: number,
    offset?: number,
  ): AssetRecord[] {
    const sf = this.fetchSmartFolders().find((s) => toSwiftUUID(s.id) === toSwiftUUID(smartFolderID));
    if (!sf) return [];
    const base = this.fetchAssets({
      ...extraCriteria,
      includeTrashed: false,
      onlyTrashed: false,
    });
    const matched = base.filter((asset) => matchesSmartFolderRule(sf.rule, asset));
    const start = offset && offset > 0 ? Math.trunc(offset) : 0;
    if (limit !== undefined && limit !== null) {
      return matched.slice(start, start + Math.max(0, Math.trunc(limit)));
    }
    return matched.slice(start);
  }

  // MARK: - Tags & Counts

  fetchTagCounts(): TagCount[] {
    const rows = this.sql.all<{ name: string; cnt: number }>(
      `SELECT t.tag AS name, COUNT(*) AS cnt
         FROM asset_tags t
         JOIN assets a ON t.asset_id = a.id
         WHERE a.trashed = 0
         GROUP BY t.tag
         ORDER BY cnt DESC, t.tag COLLATE NOCASE ASC`,
    );
    return rows.map((r) => ({ name: r.name, count: Number(r.cnt) }));
  }

  inboxCount(): number {
    const row = this.sql.get<{ cnt: number }>(
      'SELECT COUNT(*) AS cnt FROM assets WHERE folder_id IS NULL AND trashed = 0',
    );
    return Number(row?.cnt ?? 0);
  }

  untaggedCount(): number {
    const row = this.sql.get<{ cnt: number }>(
      `SELECT COUNT(*) AS cnt FROM assets a
         WHERE a.trashed = 0 AND NOT EXISTS (SELECT 1 FROM asset_tags t WHERE t.asset_id = a.id)`,
    );
    return Number(row?.cnt ?? 0);
  }

  trashCount(): number {
    const row = this.sql.get<{ cnt: number }>('SELECT COUNT(*) AS cnt FROM assets WHERE trashed = 1');
    return Number(row?.cnt ?? 0);
  }

  totalAssetCount(): number {
    const row = this.sql.get<{ cnt: number }>('SELECT COUNT(*) AS cnt FROM assets WHERE trashed = 0');
    return Number(row?.cnt ?? 0);
  }

  isEmpty(): boolean {
    const row = this.sql.get<{ x: number }>(
      'SELECT 1 AS x FROM assets UNION ALL SELECT 1 FROM boards UNION ALL SELECT 1 FROM folders LIMIT 1',
    );
    return row === undefined;
  }

  // MARK: - Moodboards

  fetchBoards(): MoodboardDocument[] {
    const rows = this.sql.all<{ payload: string }>(
      'SELECT payload FROM boards ORDER BY updated_at DESC, id DESC',
    );
    return rows.map((r) => JSON.parse(r.payload) as MoodboardDocument);
  }

  fetchBoardSummaries(): MoodboardSummary[] {
    return this.fetchBoards().map((b) => {
      const refIDs = getBoardReferencedAssetIDs(b);
      return {
        id: b.id,
        title: b.title,
        subtitle: b.subtitle,
        mode: b.mode,
        itemCount: b.nodes.length,
        previewAssetIDs: refIDs.slice(0, 4),
        paletteHexes: b.extractedPalette.map((c) => c.hex),
        pinnedOffline: b.pinnedOffline,
        updatedAt: b.updatedAt,
      };
    });
  }

  getBoard(id: UUID): MoodboardDocument | null {
    const row = this.sql.get<{ payload: string }>('SELECT payload FROM boards WHERE id = ?', [
      toSwiftUUID(id),
    ]);
    return row ? (JSON.parse(row.payload) as MoodboardDocument) : null;
  }

  findBoardByTitle(title: string): MoodboardDocument | null {
    const needle = normalizeSearchText(title);
    if (!needle) return null;
    const all = this.fetchBoards();
    return (
      all.find((b) => normalizeSearchText(b.title) === needle) ??
      all.find((b) => normalizeSearchText(b.title).includes(needle)) ??
      null
    );
  }

  upsertBoard(board: MoodboardDocument): void {
    this.transaction(() => this.putBoard(board));
  }

  putBoard(rawBoard: MoodboardDocument): void {
    const board: MoodboardDocument = {
      ...rawBoard,
      id: toSwiftUUID(rawBoard.id),
    };
    const parsedUpdated = Date.parse(board.updatedAt);
    const updatedSec = Number.isFinite(parsedUpdated) ? parsedUpdated / 1000 : Date.now() / 1000;
    this.sql.run(
      `INSERT INTO boards (id, pinned, updated_at, payload)
         VALUES (?, ?, ?, ?)
         ON CONFLICT(id) DO UPDATE SET
           pinned=excluded.pinned,
           updated_at=excluded.updated_at,
           payload=excluded.payload`,
      [board.id, board.pinnedOffline ? 1 : 0, updatedSec, JSON.stringify(board)],
    );

    this.sql.run('DELETE FROM board_assets WHERE board_id = ?', [board.id]);
    const refSet = new Set(getBoardReferencedAssetIDs(board).map(toSwiftUUID));
    for (const assetID of refSet) {
      this.sql.run('INSERT INTO board_assets(board_id, asset_id) VALUES (?, ?)', [
        board.id,
        assetID,
      ]);
    }
  }

  saveBoardLocally(board: MoodboardDocument): MoodboardDocument {
    return this.transaction(() => {
      const id = toSwiftUUID(board.id);
      if (this.isTombstoned('board', id)) {
        throw new LibraryDatabaseError(`Board ${id} has been deleted.`, 409, 'ENTITY_TOMBSTONED');
      }
      const existing = this.getBoard(id);
      const delta = diffBoardChanges({ ...board, id }, existing);
      if (!isBoardChangesEmpty(delta)) {
        this.recordSyncChange({ type: 'board', delta });
      }
      return this.getBoard(id) ?? { ...board, id };
    });
  }

  deleteBoardLocally(id: UUID): void {
    this.transaction(() => {
      this.recordSyncChange({ type: 'deleteBoard', id: toSwiftUUID(id) });
    });
  }

  removeBoard(id: UUID): void {
    this.sql.run('DELETE FROM boards WHERE id = ?', [toSwiftUUID(id)]);
  }

  protectedAssetIDs(): Set<UUID> {
    const rows = this.sql.all<{ id: string }>(
      `SELECT id FROM assets WHERE pinned = 1
         UNION
         SELECT ba.asset_id AS id FROM board_assets ba
         JOIN boards b ON ba.board_id = b.id
         WHERE b.pinned = 1`,
    );
    return new Set(rows.map((r) => toSwiftUUID(r.id)));
  }

  // MARK: - Quick Jump, Similarity & Offline Folder Suggestion

  quickJump(query: string, limit = 24): QuickJumpMatch[] {
    if (limit <= 0) return [];
    const matches: QuickJumpMatch[] = [];
    const add = (
      title: string,
      kind: QuickJumpMatch['kind'],
      subtitle: string,
      targetUUID: UUID | null,
      tagName: string | null = null,
    ): void => {
      const score = fuzzyScoreSearchText(query, title);
      if (score === null) return;
      matches.push({
        id: `${kind}-${targetUUID ?? title}`,
        kind,
        title,
        subtitle,
        targetUUID,
        tagName,
        score,
      });
    };

    for (const board of this.fetchBoards()) {
      add(board.title, 'moodboard', `情绪板 · ${board.nodes.length} 项`, board.id);
    }
    for (const folder of this.fetchFolders()) {
      add(folder.name, 'folder', `文件夹 · ${folder.assetCount} 项`, folder.id);
    }
    for (const tag of this.fetchTagCounts()) {
      add(tag.name, 'tag', `标签 · ${tag.count} 项`, null, tag.name);
    }
    const assets = this.fetchAssets({ searchQuery: query, sortBy: 'relevance' }, Math.max(60, limit));
    for (const item of assets) {
      const score = fuzzyScoreSearchText(query, item.title) ?? 0.55;
      matches.push({
        id: `asset-${item.id}`,
        kind: 'asset',
        title: item.title,
        subtitle: mediaKindLocalizedLabel(item.mediaKind),
        targetUUID: item.id,
        tagName: null,
        score,
      });
    }

    matches.sort((a, b) => {
      if (a.score !== b.score) return b.score - a.score;
      const t = a.title.localeCompare(b.title);
      return t !== 0 ? t : a.id.localeCompare(b.id);
    });
    return matches.slice(0, limit);
  }

  similarAssets(assetID: UUID, limit = 12): ScoredAsset[] {
    const target = this.getAsset(assetID);
    if (!target) return [];
    const targetID = toSwiftUUID(target.id);
    const targetVec = this.getVector(targetID);
    const targetFp = targetVec?.featurePrint ? decodeFeaturePrintFloat32(targetVec.featurePrint) : null;
    const targetEmb = targetVec?.embedding ?? null;
    const targetEmbModel = targetVec?.embeddingModel ?? null;
    const targetTags = new Set(
      [...target.tags, ...target.suggestedTags].map((t) => normalizeSearchText(t)).filter(Boolean),
    );
    const allVectors = this.getAllVectors();

    const candidates = this.fetchAssets({ includeTrashed: false });
    const scored: ScoredAsset[] = [];

    for (const cand of candidates) {
      if (cand.id === targetID) continue;
      const reasons: string[] = [];
      let score = 0;

      const candVec = allVectors.get(cand.id);
      const modelsCompatible =
        (!targetEmbModel && !candVec?.embeddingModel) ||
        targetEmbModel === candVec?.embeddingModel;
      if (
        modelsCompatible &&
        targetEmb &&
        candVec?.embedding &&
        targetEmb.length === candVec.embedding.length
      ) {
        const sim = Math.max(0, cosineSimilarity(targetEmb, candVec.embedding));
        score += sim * 0.48;
        if (sim >= 0.45) reasons.push(`语义相似 ${(sim * 100).toFixed(0)}%`);
      }

      if (targetFp && candVec?.featurePrint) {
        const candFp = decodeFeaturePrintFloat32(candVec.featurePrint);
        if (candFp && candFp.length === targetFp.length) {
          const sim = Math.max(0, cosineSimilarity(targetFp, candFp));
          score += sim * 0.36;
          if (sim >= 0.6) reasons.push(`视觉特征相近 ${(sim * 100).toFixed(0)}%`);
        }
      }

      // Color harmony similarity (CIEDE2000)
      if (target.dominantColors.length > 0 && cand.dominantColors.length > 0) {
        let bestD = Infinity;
        for (const tc of target.dominantColors.slice(0, 3)) {
          for (const cc of cand.dominantColors.slice(0, 3)) {
            const d = deltaE2000(tc, cc);
            if (d < bestD) bestD = d;
          }
        }
        if (bestD < 45) {
          const colorScore = Math.max(0, 1 - bestD / 45);
          score += colorScore * 0.28;
          if (bestD <= 24) reasons.push('色板相近');
        }
      }

      // Tag overlap (including suggested tags)
      const candAllTags = new Set(
        [...cand.tags, ...cand.suggestedTags].map((t) => normalizeSearchText(t)).filter(Boolean),
      );
      if (targetTags.size > 0 && candAllTags.size > 0) {
        let overlap = 0;
        for (const t of candAllTags) {
          if (targetTags.has(t)) overlap++;
        }
        if (overlap > 0) {
          const jaccard = overlap / (targetTags.size + candAllTags.size - overlap);
          score += jaccard * 0.3;
          reasons.push(`共同标签 ×${overlap}`);
        }
      }

      if (cand.mediaKind === target.mediaKind) {
        score += 0.04;
      }

      if (score > 0.08) {
        scored.push({
          asset: cand,
          score: Math.min(1, score),
          matchReasons: reasons.length > 0 ? reasons : ['综合特征相近'],
        });
      }
    }

    scored.sort((a, b) => b.score - a.score || b.asset.createdAt.localeCompare(a.asset.createdAt));
    return scored.slice(0, Math.max(1, limit));
  }

  suggestFolder(assetID: UUID): FolderSuggestion | null {
    const target = this.getAsset(assetID);
    if (!target) return null;
    const folders = this.fetchFolders();
    if (folders.length === 0) return null;

    const targetTags = new Set(
      [...target.tags, ...target.suggestedTags].map((t) => normalizeSearchText(t)).filter(Boolean),
    );
    const haystack = normalizeSearchText(
      [target.title, target.notes, target.aiDescription ?? '', target.ocrText ?? ''].join(' '),
    );
    const similar = this.similarAssets(target.id, 12);

    let best: FolderSuggestion | null = null;
    for (const folder of folders) {
      if (target.folderID && folder.id === target.folderID) continue;
      let score = 0;
      const reasons: string[] = [];

      const folderNorm = normalizeSearchText(folder.name);
      if (folderNorm && (haystack.includes(folderNorm) || targetTags.has(folderNorm))) {
        score += 0.42;
        reasons.push(`关键词命中「${folder.name}」`);
      }

      const folderAssets = this.fetchAssets({ folderID: folder.id }, 80);
      if (folderAssets.length > 0) {
        const tagCounts = new Map<string, number>();
        for (const fa of folderAssets) {
          for (const t of fa.tags) {
            const n = normalizeSearchText(t);
            if (n) tagCounts.set(n, (tagCounts.get(n) ?? 0) + 1);
          }
        }
        let tagHits = 0;
        for (const tt of targetTags) {
          if (tagCounts.has(tt)) tagHits++;
        }
        if (tagHits > 0) {
          score += Math.min(0.45, tagHits * 0.18);
          reasons.push(`与文件夹标签重合 ×${tagHits}`);
        }
      }

      const simInFolder = similar.filter((s) => s.asset.folderID === folder.id);
      if (simInFolder.length > 0) {
        const avgSim = simInFolder.reduce((acc, s) => acc + s.score, 0) / simInFolder.length;
        score += Math.min(0.45, avgSim * 0.55);
        reasons.push(`${simInFolder.length} 项视觉相近素材位于此目录`);
      }

      const confidence = Math.min(0.96, score);
      if (confidence >= 0.25 && (!best || confidence > best.confidence)) {
        best = {
          folderID: folder.id,
          folderName: folder.name,
          confidence,
          reason: reasons.join(' · ') || '基于标签与视觉特征推荐',
        };
      }
    }
    return best;
  }

  // MARK: - Vectors

  saveVector(id: UUID, vector: AssetVector): void {
    const uid = toSwiftUUID(id);
    const current = this.getVector(uid);
    const featurePrint = vector.featurePrint ?? current?.featurePrint ?? null;
    const embedding = vector.embedding ?? current?.embedding ?? null;
    const embeddingModel =
      vector.embedding === undefined || vector.embedding === null
        ? (current?.embeddingModel ?? null)
        : (vector.embeddingModel ?? null);
    const precision: EmbeddingPrecision =
      vector.embedding === undefined || vector.embedding === null
        ? (current?.precision ?? 16)
        : vector.precision;

    const blob = embedding ? encodeEmbeddingBlob(embedding, precision) : null;
    this.sql.run(
      `INSERT OR REPLACE INTO asset_vectors (asset_id, feature_print, embedding, precision, embedding_model)
         VALUES (?, ?, ?, ?, ?)`,
      [uid, featurePrint, blob, precision, embeddingModel],
    );
  }

  getVector(id: UUID): AssetVector | null {
    const row = this.sql.get<{
      feature_print: string | null;
      embedding: Uint8Array | ArrayBuffer | null;
      precision: number;
      embedding_model: string | null;
    }>(
      'SELECT feature_print, embedding, precision, embedding_model FROM asset_vectors WHERE asset_id = ?',
      [toSwiftUUID(id)],
    );
    if (!row) return null;
    const precision: EmbeddingPrecision = row.precision === 32 ? 32 : 16;
    return {
      featurePrint: row.feature_print ?? null,
      embedding: row.embedding ? decodeEmbeddingBlob(row.embedding, precision) : null,
      embeddingModel: row.embedding_model || null,
      precision,
    };
  }

  getAllVectors(): Map<UUID, AssetVector> {
    const rows = this.sql.all<{
      asset_id: string;
      feature_print: string | null;
      embedding: Uint8Array | ArrayBuffer | null;
      precision: number;
      embedding_model: string | null;
    }>('SELECT asset_id, feature_print, embedding, precision, embedding_model FROM asset_vectors');
    const map = new Map<UUID, AssetVector>();
    for (const row of rows) {
      const precision: EmbeddingPrecision = row.precision === 32 ? 32 : 16;
      map.set(row.asset_id, {
        featurePrint: row.feature_print ?? null,
        embedding: row.embedding ? decodeEmbeddingBlob(row.embedding, precision) : null,
        embeddingModel: row.embedding_model || null,
        precision,
      });
    }
    return map;
  }

  // MARK: - Sync State, HLC, Ops Queue & CRDT Apply

  getState<T = unknown>(key: string): T | null {
    const row = this.sql.get<{ payload: string }>(
      'SELECT payload FROM sync_state WHERE key = ?',
      [key],
    );
    if (!row) return null;
    return JSON.parse(row.payload) as T;
  }

  getStatesWithPrefix<T = unknown>(prefix: string): Array<{ key: string; value: T }> {
    const rows = this.sql.all<{ key: string; payload: string }>(
      'SELECT key, payload FROM sync_state WHERE substr(key, 1, length(?)) = ?',
      [prefix, prefix],
    );
    return rows.map((r) => ({ key: r.key, value: JSON.parse(r.payload) as T }));
  }

  setState<T = unknown>(key: string, value: T | null): void {
    if (value === null || value === undefined) {
      this.sql.run('DELETE FROM sync_state WHERE key = ?', [key]);
    } else {
      this.sql.run('INSERT OR REPLACE INTO sync_state (key, payload) VALUES (?, ?)', [
        key,
        JSON.stringify(value),
      ]);
    }
  }

  deviceID(): string {
    const existing = this.getState<string>('deviceID');
    if (existing) return existing;
    const generated = bytesToHex(randomBytes(16)); // 32 lowercase hex chars matching Swift
    this.setState('deviceID', generated);
    return generated;
  }

  recordSyncChange(change: SyncOperationChange, projectLocation = true): SyncOperation {
    return this.transaction(() => {
      const stamp = {
        time: nextHLC(this),
        device: this.deviceID(),
      };
      const op: SyncOperation = {
        stamp,
        change,
        projectLocation: projectLocation ? null : false,
      };
      applySyncOperation(this, op);
      this.appendOp(op);
      return op;
    });
  }

  applySyncOperation(op: SyncOperation): void {
    this.transaction(() => {
      applySyncOperation(this, op);
    });
  }

  appendOp(op: SyncOperation): number {
    const row = this.sql.get<{ seq: number }>(
      'INSERT INTO sync_ops (payload) VALUES (?) RETURNING seq',
      [JSON.stringify(op)],
    );
    return Number(row?.seq ?? 0);
  }

  pendingOps(limit = 500): SyncLogLine[] {
    const rows = this.sql.all<{ seq: number; payload: string }>(
      'SELECT seq, payload FROM sync_ops ORDER BY seq ASC LIMIT ?',
      [Math.max(1, Math.trunc(limit))],
    );
    return rows.map((r) => ({
      seq: Number(r.seq),
      operation: JSON.parse(r.payload) as SyncOperation,
    }));
  }

  acknowledgeOps(throughSeq: number): void {
    this.sql.run('DELETE FROM sync_ops WHERE seq <= ?', [Math.trunc(throughSeq)]);
  }

  pendingOpCount(): number {
    const row = this.sql.get<{ cnt: number }>('SELECT COUNT(*) AS cnt FROM sync_ops');
    return Number(row?.cnt ?? 0);
  }

  clearMigrationSyncState(): void {
    this.sql.exec('DELETE FROM sync_ops;');
    this.sql.exec(`
      DELETE FROM sync_state
      WHERE key LIKE 'remote.%'
         OR key LIKE 'local.delete.%'
         OR key LIKE 'deleted.drive.%'
         OR key LIKE 'clock.%'
         OR key LIKE 'projection.%';
    `);
  }

  markProjection(name: string, id: UUID): void {
    const key = `projection.${name}`;
    const dirty = this.getState<Record<string, string>>(key) ?? {};
    dirty[toSwiftUUID(id)] = randomUUID().toUpperCase();
    this.setState(key, dirty);
  }

  clearProjection(name: string, id: string, ifVersion: string): void {
    const key = `projection.${name}`;
    const dirty = this.getState<Record<string, string>>(key) ?? {};
    if (dirty[id] === ifVersion) {
      delete dirty[id];
      this.setState(key, dirty);
    }
  }

  isTombstoned(entity: string, id: UUID): boolean {
    const clocks = this.getState<SyncClocks>(`clock.${entity}.${toSwiftUUID(id)}`);
    return isClockDeleted(clocks);
  }

  requeueLibraryForBackendMigration(
    syncThumbnails: boolean,
    syncEmbeddings: boolean,
  ): { assets: number; folders: number; boards: number } {
    return this.transaction(() => {
      this.clearMigrationSyncState();

      // Re-queue folders in parent-before-child topological order
      const existingFolders = this.fetchFolders();
      const byID = new Map(existingFolders.map((f) => [f.id, f]));
      const orderedFolders: FolderRecord[] = [];
      const visited = new Set<UUID>();
      const visit = (f: FolderRecord): void => {
        if (visited.has(f.id)) return;
        visited.add(f.id);
        if (f.parentID && byID.has(f.parentID)) {
          visit(byID.get(f.parentID)!);
        }
        orderedFolders.push(f);
      };
      for (const f of existingFolders) visit(f);

      for (const folder of orderedFolders) {
        const cleanFolder: FolderRecord = { ...folder, driveFolderID: null };
        this.putFolder(cleanFolder);
        this.recordSyncChange({ type: 'folder', folder: cleanFolder });
      }

      // Re-queue non-trashed assets with unbound driveFileID
      const allAssets = this.fetchAssets({ includeTrashed: false });
      const allVectors = this.getAllVectors();
      for (const asset of allAssets) {
        const cleanAsset: AssetRecord = { ...asset, driveFileID: null };
        this.putAsset(cleanAsset);
        const delta = diffAssetChanges(cleanAsset, null);
        if (!isAssetChangesEmpty(delta)) {
          this.recordSyncChange({ type: 'asset', delta });
        }
        if (syncThumbnails) {
          this.markProjection('thumbnails', cleanAsset.id);
        }
        if (syncEmbeddings) {
          const vec = allVectors.get(cleanAsset.id);
          if (vec) {
            this.recordSyncChange({ type: 'vector', id: cleanAsset.id, vector: vec });
          }
        }
      }

      // Re-queue moodboards
      const allBoards = this.fetchBoards();
      for (const board of allBoards) {
        const delta = diffBoardChanges(board, null);
        if (!isBoardChangesEmpty(delta)) {
          this.recordSyncChange({ type: 'board', delta });
        }
        this.markProjection('boards', board.id);
      }

      return {
        assets: allAssets.length,
        folders: orderedFolders.length,
        boards: allBoards.length,
      };
    });
  }

  // MARK: - Original Cache LRU Access Timestamps

  touchOriginal(id: UUID, now: Date = new Date()): void {
    this.sql.run('INSERT OR REPLACE INTO original_cache (asset_id, accessed_at) VALUES (?, ?)', [
      toSwiftUUID(id),
      now.getTime() / 1000,
    ]);
  }

  originalAccessTimes(): Map<UUID, number> {
    const rows = this.sql.all<{ asset_id: string; accessed_at: number }>(
      'SELECT asset_id, accessed_at FROM original_cache',
    );
    const map = new Map<UUID, number>();
    for (const r of rows) {
      map.set(r.asset_id, Number(r.accessed_at));
    }
    return map;
  }

  getRecentActivitySortValue(asset: AssetRecord): number {
    return Date.parse(getAssetRecentActivityDate(asset));
  }
}
