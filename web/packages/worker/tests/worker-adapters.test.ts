import JSZip from 'jszip';
import { describe, expect, it, vi } from 'vitest';
import {
  DurableObjectSqlDatabase,
  splitSqlStatements,
  type DurableObjectSqlStorageLike,
} from '../src/do-sql.js';
import type { CharkleWorkerEnv } from '../src/env.js';
import { BUNDLE_METADATA, createBundledAssets } from '../src/generated/bundles.js';
import { R2BlobStore } from '../src/r2-blob.js';

vi.mock('cloudflare:workers', () => {
  class DurableObject<Env = unknown> {
    protected readonly ctx: DurableObjectState;
    protected readonly env: Env;
    constructor(ctx: DurableObjectState, env: Env) {
      this.ctx = ctx;
      this.env = env;
    }
  }
  return { DurableObject };
});

// MARK: - Faithful Cloudflare DurableObjectStorage Mock

interface ExecutedCall {
  query: string;
  bindings: unknown[];
}

function createMockDoStorage(options?: {
  rowsByQuery?: (query: string, bindings: unknown[]) => {
    rows?: Array<Record<string, SqlStorageValue>>;
    rowsWritten?: number;
  };
  throwOnPragma?: boolean;
}) {
  const calls: ExecutedCall[] = [];
  let inNativeTransaction = false;
  let transactionSyncCount = 0;

  const storage: DurableObjectSqlStorageLike = {
    sql: {
      exec<T extends Record<string, SqlStorageValue>>(
        query: string,
        ...bindings: unknown[]
      ): SqlStorageCursor<T> {
        calls.push({ query, bindings });
        if (options?.throwOnPragma && /^\s*PRAGMA\b/i.test(query)) {
          throw new Error('SQLITE_AUTH: not authorized to run PRAGMA');
        }
        const res = options?.rowsByQuery?.(query, bindings) ?? {};
        const rows = (res.rows ?? []) as T[];
        const rowsWritten = res.rowsWritten ?? 0;

        let idx = 0;
        const cursor = {
          columnNames: rows.length > 0 ? Object.keys(rows[0]) : [],
          get rowsRead() {
            return rows.length;
          },
          get rowsWritten() {
            return rowsWritten;
          },
          toArray() {
            return rows;
          },
          one() {
            if (rows.length !== 1) throw new Error(`Expected 1 row, got ${rows.length}`);
            return rows[0];
          },
          next(): IteratorResult<T, undefined> {
            if (idx < rows.length) {
              return { done: false, value: rows[idx++] };
            }
            return { done: true, value: undefined };
          },
          raw<U extends SqlStorageValue[]>(): IterableIterator<U> {
            const mapped = rows.map((r) => Object.values(r) as U);
            return mapped[Symbol.iterator]();
          },
          [Symbol.iterator](): IterableIterator<T> {
            return rows[Symbol.iterator]();
          },
        };
        return cursor as SqlStorageCursor<T>;
      },
      get databaseSize() {
        return 4096;
      },
      Cursor: null as never,
      Statement: null as never,
    },
    transactionSync<T>(closure: () => T): T {
      if (inNativeTransaction) {
        throw new Error('Nested transactionSync is not allowed in workerd');
      }
      inNativeTransaction = true;
      transactionSyncCount += 1;
      try {
        return closure();
      } finally {
        inNativeTransaction = false;
      }
    },
  };

  return {
    storage,
    calls,
    getTransactionSyncCount: () => transactionSyncCount,
  };
}

// MARK: - Faithful Cloudflare R2Bucket Mock (supports Range, Pagination, Stream enforcement)

interface StoredR2Entry {
  key: string;
  bytes: Uint8Array;
  contentType?: string;
  etag: string;
  uploaded: Date;
}

interface MockR2MultipartState {
  key: string;
  uploadId: string;
  contentType?: string;
  parts: Map<number, { etag: string; bytes: Uint8Array }>;
  aborted: boolean;
  completed: boolean;
}

function createMockR2Bucket(pageSize = 2) {
  const entries = new Map<string, StoredR2Entry>();
  const multiparts = new Map<string, MockR2MultipartState>();
  const getRangeCalls: Array<{ key: string; range?: R2Range }> = [];
  const counts = {
    head: 0,
    get: 0,
    put: 0,
    delete: 0,
    deleteBatch: 0,
    list: 0,
    createMultipart: 0,
    uploadPart: 0,
    completeMultipart: 0,
    abortMultipart: 0,
  };
  let versionCounter = 1;
  let uploadCounter = 1;

  function makeStream(slice: Uint8Array): ReadableStream<Uint8Array> {
    return new ReadableStream<Uint8Array>({
      start(controller) {
        if (slice.byteLength > 0) {
          controller.enqueue(slice.slice());
        }
        controller.close();
      },
    });
  }

  function makeR2Object(entry: StoredR2Entry, range?: R2Range): R2Object {
    return {
      key: entry.key,
      version: `v${versionCounter}`,
      size: entry.bytes.byteLength, // Note: R2 ALWAYS sets `size` to full object size, even on range gets!
      etag: entry.etag,
      httpEtag: `"${entry.etag}"`,
      checksums: { toJSON: () => ({}) },
      uploaded: entry.uploaded,
      httpMetadata: entry.contentType ? { contentType: entry.contentType } : undefined,
      customMetadata: {},
      range,
      storageClass: 'Standard',
      writeHttpMetadata(headers: Headers) {
        if (entry.contentType) headers.set('content-type', entry.contentType);
      },
    } as R2Object;
  }

  async function toBytes(
    value: ReadableStream | ArrayBuffer | ArrayBufferView | string | null | Blob,
    allowStream = false,
  ): Promise<Uint8Array> {
    if (value instanceof ReadableStream) {
      if (!allowStream) {
        throw new TypeError('The ReadableStream provided to R2.put must have a known length');
      }
      return readStreamAll(value as ReadableStream<Uint8Array>);
    }
    if (value instanceof Uint8Array) return value.slice();
    if (ArrayBuffer.isView(value)) {
      return new Uint8Array(value.buffer, value.byteOffset, value.byteLength).slice();
    }
    if (value instanceof ArrayBuffer) return new Uint8Array(value).slice();
    if (typeof value === 'string') return new TextEncoder().encode(value);
    if (value === null) return new Uint8Array(0);
    return new Uint8Array(await value.arrayBuffer());
  }

  function etagMatchesHeader(onlyIf: R2Conditional | Headers | undefined, entry: StoredR2Entry): boolean {
    if (!onlyIf) return false;
    const raw =
      onlyIf instanceof Headers
        ? onlyIf.get('if-none-match')
        : onlyIf.etagDoesNotMatch ?? null;
    if (!raw) return false;
    const target = entry.etag;
    return raw
      .split(',')
      .map((s) => s.trim().replace(/^W\//i, '').replace(/^"|"$/g, ''))
      .some((part) => part === '*' || part === target);
  }

  function makeMultipartHandle(state: MockR2MultipartState): R2MultipartUpload {
    return {
      key: state.key,
      uploadId: state.uploadId,
      async uploadPart(
        partNumber: number,
        value: ReadableStream | ArrayBuffer | ArrayBufferView | string | Blob,
      ): Promise<R2UploadedPart> {
        if (state.aborted || state.completed) {
          throw new Error('Multipart upload is no longer active');
        }
        counts.uploadPart += 1;
        const bytes = await toBytes(value, true);
        const etag = `part-${state.uploadId}-${partNumber}-${versionCounter++}`;
        state.parts.set(partNumber, { etag, bytes });
        return { partNumber, etag };
      },
      async abort(): Promise<void> {
        counts.abortMultipart += 1;
        state.aborted = true;
        multiparts.delete(`${state.key}::${state.uploadId}`);
      },
      async complete(uploadedParts: R2UploadedPart[]): Promise<R2Object> {
        if (state.aborted || state.completed) {
          throw new Error('Multipart upload is no longer active');
        }
        counts.completeMultipart += 1;
        const ordered = [...uploadedParts].sort((a, b) => a.partNumber - b.partNumber);
        const chunks: Uint8Array[] = [];
        let total = 0;
        for (const p of ordered) {
          const saved = state.parts.get(p.partNumber);
          if (!saved || saved.etag !== p.etag) {
            throw new Error(`Invalid part ${p.partNumber}`);
          }
          chunks.push(saved.bytes);
          total += saved.bytes.byteLength;
        }
        const merged = new Uint8Array(total);
        let offset = 0;
        for (const c of chunks) {
          merged.set(c, offset);
          offset += c.byteLength;
        }
        state.completed = true;
        multiparts.delete(`${state.key}::${state.uploadId}`);
        const entry: StoredR2Entry = {
          key: state.key,
          bytes: merged,
          contentType: state.contentType,
          etag: `etag-mp-${versionCounter++}`,
          uploaded: new Date(1_700_000_000_000 + versionCounter * 1000),
        };
        entries.set(state.key, entry);
        return makeR2Object(entry);
      },
    };
  }

  const bucket = {
    async put(
      key: string,
      value: ReadableStream | ArrayBuffer | ArrayBufferView | string | null | Blob,
      options?: R2PutOptions,
    ): Promise<R2Object> {
      counts.put += 1;
      const bytes = await toBytes(value, false);
      const contentType =
        options?.httpMetadata && !(options.httpMetadata instanceof Headers)
          ? options.httpMetadata.contentType
          : undefined;
      const entry: StoredR2Entry = {
        key,
        bytes,
        contentType,
        etag: `etag-${versionCounter++}`,
        uploaded: new Date(1_700_000_000_000 + versionCounter * 1000),
      };
      entries.set(key, entry);
      return makeR2Object(entry);
    },

    async head(key: string): Promise<R2Object | null> {
      counts.head += 1;
      const entry = entries.get(key);
      return entry ? makeR2Object(entry) : null;
    },

    async get(key: string, options?: R2GetOptions): Promise<R2ObjectBody | R2Object | null> {
      counts.get += 1;
      const entry = entries.get(key);
      if (!entry) return null;

      if (etagMatchesHeader(options?.onlyIf, entry)) {
        // Real R2 returns an R2Object WITHOUT `.body` when `onlyIf` fails (304 Not Modified)
        return makeR2Object(entry);
      }

      const requestedRange =
        options?.range && !(options.range instanceof Headers) ? options.range : undefined;
      getRangeCalls.push({ key, range: requestedRange });

      let slice = entry.bytes;
      let resolvedRange: R2Range | undefined;
      if (requestedRange) {
        if ('suffix' in requestedRange && requestedRange.suffix !== undefined) {
          const len = Math.min(entry.bytes.byteLength, Math.max(0, requestedRange.suffix));
          const start = entry.bytes.byteLength - len;
          slice = entry.bytes.subarray(start);
          resolvedRange = { offset: start, length: slice.byteLength };
        } else if ('offset' in requestedRange && requestedRange.offset !== undefined) {
          const start = Math.max(0, requestedRange.offset);
          const end =
            requestedRange.length !== undefined
              ? Math.min(entry.bytes.byteLength, start + requestedRange.length)
              : entry.bytes.byteLength;
          slice = start < entry.bytes.byteLength ? entry.bytes.subarray(start, end) : new Uint8Array(0);
          resolvedRange = { offset: start, length: slice.byteLength };
        }
      }

      const base = makeR2Object(entry, resolvedRange);
      const bodyObj: R2ObjectBody = {
        ...base,
        writeHttpMetadata: base.writeHttpMetadata,
        get body() {
          return makeStream(slice);
        },
        get bodyUsed() {
          return false;
        },
        async arrayBuffer() {
          return slice.slice().buffer;
        },
        async bytes() {
          return slice.slice();
        },
        async text() {
          return new TextDecoder().decode(slice);
        },
        async json<T>() {
          return JSON.parse(new TextDecoder().decode(slice)) as T;
        },
        async blob() {
          return new Blob([slice.slice()]);
        },
      };
      return bodyObj;
    },

    async delete(keys: string | string[]): Promise<void> {
      counts.delete += 1;
      if (Array.isArray(keys)) {
        counts.deleteBatch += 1;
        for (const k of keys) entries.delete(k);
      } else {
        entries.delete(keys);
      }
    },

    async createMultipartUpload(
      key: string,
      options?: R2MultipartOptions,
    ): Promise<R2MultipartUpload> {
      counts.createMultipart += 1;
      const uploadId = `mp-${uploadCounter++}`;
      const contentType =
        options?.httpMetadata && !(options.httpMetadata instanceof Headers)
          ? options.httpMetadata.contentType
          : undefined;
      const state: MockR2MultipartState = {
        key,
        uploadId,
        contentType,
        parts: new Map(),
        aborted: false,
        completed: false,
      };
      multiparts.set(`${key}::${uploadId}`, state);
      return makeMultipartHandle(state);
    },

    resumeMultipartUpload(key: string, uploadId: string): R2MultipartUpload {
      const state = multiparts.get(`${key}::${uploadId}`);
      if (!state) {
        throw new Error(`Multipart upload not found: ${key}::${uploadId}`);
      }
      return makeMultipartHandle(state);
    },

    async list(options?: R2ListOptions): Promise<R2Objects> {
      counts.list += 1;
      const prefix = options?.prefix ?? '';
      const allMatching = Array.from(entries.values())
        .filter((e) => !prefix || e.key.startsWith(prefix))
        .sort((a, b) => a.key.localeCompare(b.key));

      const startIdx = options?.cursor ? Number.parseInt(options.cursor, 10) : 0;
      const limit = options?.limit ?? pageSize;
      const page = allMatching.slice(startIdx, startIdx + limit);
      const nextIdx = startIdx + page.length;
      const truncated = nextIdx < allMatching.length;

      if (truncated) {
        return {
          objects: page.map((e) => makeR2Object(e)),
          truncated: true,
          cursor: String(nextIdx),
          delimitedPrefixes: [],
        };
      }
      return {
        objects: page.map((e) => makeR2Object(e)),
        truncated: false,
        delimitedPrefixes: [],
      };
    },
  } as unknown as R2Bucket;

  return { bucket, entries, multiparts, getRangeCalls, counts };
}

async function readStreamAll(stream: ReadableStream<Uint8Array>): Promise<Uint8Array> {
  const reader = stream.getReader();
  const chunks: Uint8Array[] = [];
  let total = 0;
  try {
    for (;;) {
      const { done, value } = await reader.read();
      if (done) break;
      if (value) {
        chunks.push(value);
        total += value.byteLength;
      }
    }
  } finally {
    reader.releaseLock();
  }
  const out = new Uint8Array(total);
  let offset = 0;
  for (const c of chunks) {
    out.set(c, offset);
    offset += c.byteLength;
  }
  return out;
}

// MARK: - 1. DurableObjectSqlDatabase Tests

describe('DurableObjectSqlDatabase', () => {
  it('splits multi-statement SQL scripts cleanly while ignoring semicolons inside quotes and comments', () => {
    const statements = splitSqlStatements(`
      -- leading comment; not a split
      CREATE TABLE foo (id TEXT PRIMARY KEY, label TEXT DEFAULT 'a;b''c');
      /* block comment; still ignored */
      INSERT INTO foo (id, label) VALUES ('1', 'hello; world');
    `);
    expect(statements).toHaveLength(2);
    expect(statements[0]).toContain("DEFAULT 'a;b''c'");
    expect(statements[1]).toContain("'hello; world'");
  });

  it('skips Node-only PRAGMA statements and gracefully ignores rejected PRAGMAs while throwing real SQL errors', () => {
    const mock = createMockDoStorage({
      throwOnPragma: true,
      rowsByQuery(query) {
        if (query.includes('INVALID_SYNTAX')) {
          throw new Error('SQLITE_ERROR: near "INVALID_SYNTAX"');
        }
        return {};
      },
    });
    const db = new DurableObjectSqlDatabase(mock.storage);

    db.exec(`
      PRAGMA journal_mode = WAL;
      PRAGMA synchronous = NORMAL;
      PRAGMA foreign_keys = ON;
      CREATE TABLE items (id TEXT PRIMARY KEY);
    `);

    // journal_mode and synchronous must be filtered out before touching DO storage.sql
    const queries = mock.calls.map((c) => c.query);
    expect(queries.some((q) => /journal_mode/i.test(q))).toBe(false);
    expect(queries.some((q) => /synchronous/i.test(q))).toBe(false);
    // foreign_keys ran and its SQLITE_AUTH throw was safely caught because it's a PRAGMA
    expect(queries.some((q) => /foreign_keys/i.test(q))).toBe(true);
    expect(queries.some((q) => /CREATE TABLE items/i.test(q))).toBe(true);

    // Real SQL errors MUST still throw
    expect(() => db.exec('INVALID_SYNTAX;')).toThrow(/SQLITE_ERROR/);
  });

  it('binds Uint8Array subarrays and bigint params cleanly and reports cursor.rowsWritten', () => {
    const mock = createMockDoStorage({
      rowsByQuery: () => ({ rowsWritten: 3 }),
    });
    const db = new DurableObjectSqlDatabase(mock.storage);

    const backing = new Uint8Array([0, 1, 2, 3, 4, 5, 6, 7]);
    const subview = backing.subarray(2, 6); // [2, 3, 4, 5]

    const result = db.run('INSERT INTO blobs (id, data, seq) VALUES (?, ?, ?)', [
      'asset-1',
      subview,
      42n,
    ]);

    expect(result).toEqual({ changes: 3 });
    expect(mock.calls).toHaveLength(1);
    const bound = mock.calls[0].bindings;
    expect(bound[0]).toBe('asset-1');
    expect(bound[1]).toBeInstanceOf(ArrayBuffer);
    expect(Array.from(new Uint8Array(bound[1] as ArrayBuffer))).toEqual([2, 3, 4, 5]);
    expect(bound[2]).toBe(42);
  });

  it('converts ArrayBuffer BLOB columns returned by DO SQLite into Uint8Array in get() and all()', () => {
    const rawBuf1 = new Uint8Array([10, 20, 30, 40]).buffer;
    const rawBuf2 = new Uint8Array([50, 60]).buffer;

    const mock = createMockDoStorage({
      rowsByQuery(query) {
        if (query.includes('WHERE id = ?')) {
          return {
            rows: [{ id: 'v1', embedding: rawBuf1, dim: 4 }],
          };
        }
        if (query.includes('WHERE id = \'missing\'')) {
          return { rows: [] };
        }
        return {
          rows: [
            { id: 'v1', embedding: rawBuf1 },
            { id: 'v2', embedding: rawBuf2 },
          ],
        };
      },
    });
    const db = new DurableObjectSqlDatabase(mock.storage);

    const single = db.get<{ id: string; embedding: Uint8Array; dim: number }>(
      'SELECT id, embedding, dim FROM asset_vectors WHERE id = ?',
      ['v1'],
    );
    expect(single).toBeDefined();
    expect(single!.embedding).toBeInstanceOf(Uint8Array);
    expect(Array.from(single!.embedding)).toEqual([10, 20, 30, 40]);

    expect(db.get("SELECT id FROM asset_vectors WHERE id = 'missing'")).toBeUndefined();

    const rows = db.all<{ id: string; embedding: Uint8Array }>('SELECT id, embedding FROM asset_vectors');
    expect(rows).toHaveLength(2);
    expect(rows[0].embedding).toBeInstanceOf(Uint8Array);
    expect(Array.from(rows[1].embedding)).toEqual([50, 60]);
  });

  it('guards nested transaction() calls against workerd transactionSync re-entrancy and recovers on error', () => {
    const mock = createMockDoStorage();
    const db = new DurableObjectSqlDatabase(mock.storage);

    const value = db.transaction(() => {
      return db.transaction(() => {
        return db.transaction(() => 'nested-ok');
      });
    });

    expect(value).toBe('nested-ok');
    expect(mock.getTransactionSyncCount()).toBe(1);

    // Ensure txDepth resets cleanly after a thrown error
    expect(() =>
      db.transaction(() => {
        throw new Error('boom');
      }),
    ).toThrow('boom');
    expect(mock.getTransactionSyncCount()).toBe(2);

    const afterError = db.transaction(() => 'recovered');
    expect(afterError).toBe('recovered');
    expect(mock.getTransactionSyncCount()).toBe(3);
  });
});

// MARK: - 2. R2BlobStore Tests

describe('R2BlobStore', () => {
  it('puts, heads, reads bytes, and deletes Uint8Array blobs with key sanitization', async () => {
    const { bucket } = createMockR2Bucket();
    const store = new R2BlobStore(bucket);

    const payload = new Uint8Array([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);
    const putRes = await store.put('/originals/sample.png', payload, { contentType: 'image/png' });
    expect(putRes).toEqual({ size: 8 });

    const head = await store.head('originals/sample.png');
    expect(head).not.toBeNull();
    expect(head!.size).toBe(8);
    expect(head!.contentType).toBe('image/png');
    expect(head!.etag).toBeTruthy();

    const got = await store.getBytes('originals/sample.png');
    expect(got).toEqual(payload);

    await store.delete('originals/sample.png');
    expect(await store.head('originals/sample.png')).toBeNull();
    expect(await store.getBytes('originals/sample.png')).toBeNull();

    // Path traversal keys must be rejected
    await expect(store.put('../escape.png', payload)).rejects.toThrow(/Unsafe blob key/);
  });

  it('collects unknown-length ReadableStream uploads before putting to R2', async () => {
    const { bucket } = createMockR2Bucket();
    const store = new R2BlobStore(bucket);

    const stream = new ReadableStream<Uint8Array>({
      start(controller) {
        controller.enqueue(new TextEncoder().encode('hello '));
        controller.enqueue(new TextEncoder().encode('cloudflare '));
        controller.enqueue(new TextEncoder().encode('r2'));
        controller.close();
      },
    });

    const putRes = await store.put('notes/hello.txt', stream, { contentType: 'text/plain' });
    expect(putRes.size).toBe('hello cloudflare r2'.length);

    const bytes = await store.getBytes('notes/hello.txt');
    expect(new TextDecoder().decode(bytes!)).toBe('hello cloudflare r2');
  });

  it('supports native R2 Range reads (HTTP 206 Partial Content) with accurate slice size & total', async () => {
    const { bucket, getRangeCalls } = createMockR2Bucket();
    const store = new R2BlobStore(bucket);

    const content = new TextEncoder().encode('0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ');
    await store.put('media/clip.mp4', content, { contentType: 'video/mp4' });

    // Full stream read
    const full = await store.getStream('media/clip.mp4');
    expect(full).not.toBeNull();
    expect(full!.size).toBe(content.byteLength);
    expect(full!.range).toBeUndefined();
    expect(new TextDecoder().decode(await readStreamAll(full!.stream))).toBe(
      '0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ',
    );

    // Partial Range read: bytes 0..15 (length 16)
    const partial = await store.getStream('media/clip.mp4', { offset: 0, length: 16 });
    expect(partial).not.toBeNull();
    expect(getRangeCalls.at(-1)?.range).toEqual({ offset: 0, length: 16 });
    expect(partial!.size).toBe(16);
    expect(partial!.contentType).toBe('video/mp4');
    expect(partial!.range).toEqual({ start: 0, end: 15, total: 36 });
    expect(new TextDecoder().decode(await readStreamAll(partial!.stream))).toBe('0123456789ABCDEF');

    // Open-ended / clamped Range near EOF
    const tail = await store.getStream('media/clip.mp4', { offset: 30, length: 100 });
    expect(tail).not.toBeNull();
    expect(tail!.size).toBe(6);
    expect(tail!.range).toEqual({ start: 30, end: 35, total: 36 });
    expect(new TextDecoder().decode(await readStreamAll(tail!.stream))).toBe('UVWXYZ');

    // Out-of-bounds offset returns null
    expect(await store.getStream('media/clip.mp4', { offset: 100, length: 10 })).toBeNull();
  });

  it('paginates R2 list(prefix) across truncated cursors and returns sorted results', async () => {
    // Force page size = 2 so 5 matching keys require 3 paginated R2 calls
    const { bucket } = createMockR2Bucket(2);
    const store = new R2BlobStore(bucket);

    await store.put('thumbs/e.jpg', new Uint8Array([1]));
    await store.put('thumbs/b.jpg', new Uint8Array([1, 2]));
    await store.put('thumbs/a.jpg', new Uint8Array([1, 2, 3]));
    await store.put('thumbs/d.jpg', new Uint8Array([1, 2, 3, 4]));
    await store.put('thumbs/c.jpg', new Uint8Array([1, 2, 3, 4, 5]));
    await store.put('originals/z.png', new Uint8Array([9, 9]));

    const listed = await store.list('thumbs/');
    expect(listed.map((i) => i.key)).toEqual([
      'thumbs/a.jpg',
      'thumbs/b.jpg',
      'thumbs/c.jpg',
      'thumbs/d.jpg',
      'thumbs/e.jpg',
    ]);
    expect(listed.map((i) => i.size)).toEqual([3, 2, 5, 4, 1]);
  });

  it('streams directly through FixedLengthStream when total size is known (P0-20)', async () => {
    const payload = new TextEncoder().encode('streaming-video-payload-chunked-data');
    let receivedStreamType = '';
    let streamedBytes: Uint8Array = new Uint8Array(0);

    class FakeFixedLengthStream extends TransformStream<Uint8Array, Uint8Array> {
      readonly expectedLength: number;
      constructor(expectedLength: number) {
        super();
        this.expectedLength = expectedLength;
      }
    }

    const fakeBucket = {
      async put(
        key: string,
        value: ReadableStream<Uint8Array> | Uint8Array,
      ): Promise<R2Object> {
        if (value instanceof ReadableStream) {
          receivedStreamType = 'ReadableStream';
          streamedBytes = await readStreamAll(value);
        } else {
          receivedStreamType = 'Uint8Array';
          streamedBytes = value;
        }
        return {
          key,
          size: streamedBytes.byteLength,
          etag: 'etag-stream',
          httpEtag: '"etag-stream"',
          uploaded: new Date(),
        } as R2Object;
      },
    } as unknown as R2Bucket;

    const prevFixed = (globalThis as Record<string, unknown>).FixedLengthStream;
    (globalThis as Record<string, unknown>).FixedLengthStream = FakeFixedLengthStream;
    try {
      const store = new R2BlobStore(fakeBucket);
      const stream = new ReadableStream<Uint8Array>({
        start(c) {
          c.enqueue(payload.subarray(0, 10));
          c.enqueue(payload.subarray(10));
          c.close();
        },
      });
      const res = await store.put('originals/video.mp4', stream, {
        contentType: 'video/mp4',
        size: payload.byteLength,
      });
      expect(receivedStreamType).toBe('ReadableStream');
      expect(res.size).toBe(payload.byteLength);
      expect(streamedBytes).toEqual(payload);
    } finally {
      if (prevFixed === undefined) {
        delete (globalThis as Record<string, unknown>).FixedLengthStream;
      } else {
        (globalThis as Record<string, unknown>).FixedLengthStream = prevFixed;
      }
    }
  });
});

// MARK: - 3. Build-Time Bundled ZIP Assets Tests

describe('createBundledAssets', () => {
  it('returns valid browser extension ZIP excluding tests and dotfiles', async () => {
    const bundles = createBundledAssets();
    const bytes = await bundles.getExtensionZip();
    expect(bytes).not.toBeNull();
    expect(bytes!.byteLength).toBe(BUNDLE_METADATA.extension.byteLength);
    // ZIP local file header magic: PK\x03\x04
    expect(bytes![0]).toBe(0x50);
    expect(bytes![1]).toBe(0x4b);
    expect(bytes![2]).toBe(0x03);
    expect(bytes![3]).toBe(0x04);

    const zip = await JSZip.loadAsync(bytes!);
    const names = Object.keys(zip.files).filter((k) => !zip.files[k].dir);
    expect(names).toContain('manifest.json');
    expect(names).toContain('background.js');
    expect(names).toContain('popup.html');
    expect(names.some((n) => n.startsWith('tests/'))).toBe(false);
    expect(names.some((n) => n.includes('node_modules/'))).toBe(false);
    expect(names.some((n) => n.includes('.DS_Store'))).toBe(false);
    expect(names.some((n) => n.split('/').some((seg) => seg.startsWith('.')))).toBe(false);

    // Mutating returned copy must not corrupt subsequent reads
    bytes![0] = 0x00;
    const secondRead = await bundles.getExtensionZip();
    expect(secondRead![0]).toBe(0x50);
  });

  it('returns valid Figma plugin ZIP excluding ui-template.html and dotfiles', async () => {
    const bundles = createBundledAssets();
    const bytes = await bundles.getFigmaPluginZip();
    expect(bytes).not.toBeNull();
    expect(bytes!.byteLength).toBe(BUNDLE_METADATA.figmaPlugin.byteLength);
    expect(bytes![0]).toBe(0x50);
    expect(bytes![1]).toBe(0x4b);

    const zip = await JSZip.loadAsync(bytes!);
    const names = Object.keys(zip.files).filter((k) => !zip.files[k].dir);
    expect(names).toContain('manifest.json');
    expect(names).toContain('code.js');
    expect(names).toContain('ui.html');
    expect(names).not.toContain('ui-template.html');
    expect(names.some((n) => n.includes('.DS_Store'))).toBe(false);
    expect(names.some((n) => n.split('/').some((seg) => seg.startsWith('.')))).toBe(false);
  });
});

// MARK: - 4. Worker Entrypoint Routing & CharkleLibraryDO Lifecycle Tests (P2-10)

interface NodeSqliteStatementLike {
  all(...params: unknown[]): Array<Record<string, SqlStorageValue>>;
  run(...params: unknown[]): { changes: number };
}

interface NodeSqliteDatabaseLike {
  prepare(sql: string): NodeSqliteStatementLike;
  exec(sql: string): void;
  close(): void;
}

async function createSqliteBackedDoState(options?: { failFirstInit?: boolean }) {
  const mod = (await import('node:sqlite' as string)) as {
    DatabaseSync: new (path: string) => NodeSqliteDatabaseLike;
  };
  const nativeDb = new mod.DatabaseSync(':memory:');
  let currentAlarm: number | null = null;
  let initAttempts = 0;
  let shouldFailOnce = Boolean(options?.failFirstInit);

  const storage = {
    sql: {
      exec<T extends Record<string, SqlStorageValue>>(
        query: string,
        ...bindings: unknown[]
      ): SqlStorageCursor<T> {
        const trimmed = query.trim();
        const isQuery =
          /^(SELECT|PRAGMA|WITH)\b/i.test(trimmed) || /\bRETURNING\b/i.test(trimmed);
        let rows: T[] = [];
        let rowsWritten = 0;
        if (isQuery) {
          rows = nativeDb.prepare(query).all(...bindings) as T[];
        } else {
          const info = nativeDb.prepare(query).run(...bindings);
          rowsWritten = Number(info.changes ?? 0);
        }
        let idx = 0;
        return {
          columnNames: rows.length > 0 ? Object.keys(rows[0]) : [],
          get rowsRead() {
            return rows.length;
          },
          get rowsWritten() {
            return rowsWritten;
          },
          toArray: () => rows,
          one() {
            if (rows.length !== 1) throw new Error(`Expected 1 row, got ${rows.length}`);
            return rows[0];
          },
          next(): IteratorResult<T, undefined> {
            if (idx < rows.length) return { done: false, value: rows[idx++] };
            return { done: true, value: undefined };
          },
          raw<U extends SqlStorageValue[]>(): IterableIterator<U> {
            return rows.map((r) => Object.values(r) as U)[Symbol.iterator]();
          },
          [Symbol.iterator]: () => rows[Symbol.iterator](),
        } as SqlStorageCursor<T>;
      },
      get databaseSize() {
        return 8192;
      },
      Cursor: null as never,
      Statement: null as never,
    },
    transactionSync<T>(closure: () => T): T {
      nativeDb.exec('BEGIN IMMEDIATE');
      try {
        const out = closure();
        nativeDb.exec('COMMIT');
        return out;
      } catch (err) {
        nativeDb.exec('ROLLBACK');
        throw err;
      }
    },
    async getAlarm(): Promise<number | null> {
      return currentAlarm;
    },
    async setAlarm(scheduledTime: number | Date): Promise<void> {
      currentAlarm = scheduledTime instanceof Date ? scheduledTime.getTime() : scheduledTime;
    },
    async deleteAlarm(): Promise<void> {
      currentAlarm = null;
    },
  };

  const state = {
    storage,
    async blockConcurrencyWhile<T>(fn: () => Promise<T>): Promise<T> {
      initAttempts += 1;
      if (shouldFailOnce) {
        shouldFailOnce = false;
        throw new Error('transient DO cold-start failure');
      }
      return fn();
    },
  } as unknown as DurableObjectState;

  return {
    state,
    getAlarm: () => currentAlarm,
    getInitAttempts: () => initAttempts,
    close: () => nativeDb.close(),
  };
}

describe('Worker entrypoint routing & CharkleLibraryDO', () => {
  it('routes /api and /api/* requests to CHARKLE_LIBRARY Durable Object and non-API paths to ASSETS', async () => {
    const workerModule = await import('../src/index.js');
    const handler = workerModule.default;

    const doNamedCalls: string[] = [];
    const doFetchUrls: string[] = [];
    const assetFetchUrls: string[] = [];

    const mockEnv = {
      CHARKLE_LIBRARY_ID: 'studio-main',
      CHARKLE_LIBRARY: {
        idFromName(name: string) {
          doNamedCalls.push(name);
          return { toString: () => name } as DurableObjectId;
        },
        get() {
          return {
            async fetch(req: Request) {
              doFetchUrls.push(new URL(req.url).pathname);
              return new Response('from-do', { status: 200 });
            },
          } as unknown as DurableObjectStub;
        },
      },
      ASSETS: {
        async fetch(req: Request) {
          assetFetchUrls.push(new URL(req.url).pathname);
          return new Response('from-assets', { status: 200 });
        },
      },
    } as unknown as CharkleWorkerEnv;

    const apiRes = await handler.fetch(
      new Request('https://charkle.example.com/api/v1/health'),
      mockEnv,
      {} as ExecutionContext,
    );
    expect(await apiRes.text()).toBe('from-do');
    expect(doNamedCalls).toEqual(['studio-main']);
    expect(doFetchUrls).toEqual(['/api/v1/health']);

    const spaRes = await handler.fetch(
      new Request('https://charkle.example.com/library/all'),
      mockEnv,
      {} as ExecutionContext,
    );
    expect(await spaRes.text()).toBe('from-assets');
    expect(assetFetchUrls).toEqual(['/library/all']);
  });

  it('recovers from transient cold-start init failure, serves /api/v1/health, and reconciles auto-sync alarms on PUT /api/v1/sync/config & alarm()', async () => {
    const { CharkleLibraryDO } = await import('../src/library-do.js');
    const doMock = await createSqliteBackedDoState({ failFirstInit: true });
    const { bucket } = createMockR2Bucket(10);

    const env = {
      MEDIA_BUCKET: bucket,
      CHARKLE_VAULT_KEY: 'worker-test-vault-secret',
      CHARKLE_ADMIN_USERNAME: 'admin',
      CHARKLE_ADMIN_PASSWORD: 'worker-strong-password',
      ASSETS: { fetch: async () => new Response('ok') },
      CHARKLE_LIBRARY: {} as DurableObjectNamespace,
    } as unknown as CharkleWorkerEnv;

    const instance = new CharkleLibraryDO(doMock.state, env);
    try {
      // First call fails cold-start -> initPromise must clear so retry succeeds!
      await expect(
        instance.fetch(new Request('https://charkle.example.com/api/v1/health')),
      ).rejects.toThrow(/transient DO cold-start failure/);

      // Second call succeeds cleanly
      const healthRes = await instance.fetch(
        new Request('https://charkle.example.com/api/v1/health'),
      );
      expect(healthRes.status).toBe(200);
      const health = (await healthRes.json()) as {
        ok: boolean;
        runtimeMode: string;
        features: { clientExportPreferred: boolean };
      };
      expect(health.ok).toBe(true);
      expect(health.runtimeMode).toBe('cloudflare');
      expect(health.features.clientExportPreferred).toBe(true);
      expect(doMock.getInitAttempts()).toBe(2);
      expect(doMock.getAlarm()).toBeNull(); // localOnly default -> no alarm

      // Log in and enable WebDAV auto-sync -> reconcileAutoSyncAlarm MUST schedule a DO alarm!
      const loginRes = await instance.fetch(
        new Request('https://charkle.example.com/api/v1/auth/login', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ username: 'admin', password: 'worker-strong-password' }),
        }),
      );
      expect(loginRes.status).toBe(200);
      const cookie = (loginRes.headers.get('set-cookie') ?? '').split(';')[0];

      const syncPut = await instance.fetch(
        new Request('https://charkle.example.com/api/v1/sync/config', {
          method: 'PUT',
          headers: { 'Content-Type': 'application/json', Cookie: cookie },
          body: JSON.stringify({
            config: {
              mode: 'webDAV',
              webDAVServerURL: 'https://dav.example.com',
              webDAVRemotePath: '/Charkle',
              autoSyncIntervalSeconds: 60,
            },
          }),
        }),
      );
      expect(syncPut.status).toBe(200);
      const scheduledAt = doMock.getAlarm();
      expect(scheduledAt).not.toBeNull();
      expect(scheduledAt!).toBeGreaterThan(Date.now() + 10_000);

      // Firing alarm() catches unauthenticated/network error cleanly and reschedules next alarm without crashing
      await instance.alarm();
      expect(doMock.getAlarm()).not.toBeNull();

      // Switching back to localOnly clears the DO alarm
      const disablePut = await instance.fetch(
        new Request('https://charkle.example.com/api/v1/sync/config', {
          method: 'PUT',
          headers: { 'Content-Type': 'application/json', Cookie: cookie },
          body: JSON.stringify({
            config: { mode: 'localOnly', autoSyncIntervalSeconds: 0 },
          }),
        }),
      );
      expect(disablePut.status).toBe(200);
      expect(doMock.getAlarm()).toBeNull();
    } finally {
      doMock.close();
    }
  });

  it('streams unknown-length large ReadableStreams via R2 Multipart Upload with bounded RAM, aborts on error, batches deleteMany, and handles single-call conditional getConditionalStream', async () => {
    const { bucket, counts, multiparts } = createMockR2Bucket(10);
    // Use tiny 16-byte part threshold in unit test to exercise multi-part streaming without allocating 8 MiB
    const store = new R2BlobStore(bucket, { multipartPartBytes: 16 });

    // 1. Small unknown-length stream (<= 16 bytes) -> single regular bucket.put (0 multipart ops)
    const smallPayload = new TextEncoder().encode('tiny-10-by');
    const smallStream = new ReadableStream<Uint8Array>({
      start(c) {
        c.enqueue(smallPayload.subarray(0, 4));
        c.enqueue(smallPayload.subarray(4));
        c.close();
      },
    });
    await store.put('originals/small.bin', smallStream);
    expect(counts.put).toBe(1);
    expect(counts.createMultipart).toBe(0);

    // 2. Large unknown-length stream (> 16 bytes) -> R2 multipart upload in fixed 16-byte parts + tail
    const largePayload = new TextEncoder().encode('0123456789ABCDEF-GHIJKLMNOPQRSTUV-TAIL');
    const largeStream = new ReadableStream<Uint8Array>({
      start(c) {
        c.enqueue(largePayload.subarray(0, 10));
        c.enqueue(largePayload.subarray(10, 27));
        c.enqueue(largePayload.subarray(27));
        c.close();
      },
    });
    const mpRes = await store.put('originals/large.mp4', largeStream, { contentType: 'video/mp4' });
    expect(mpRes.size).toBe(largePayload.byteLength);
    expect(counts.createMultipart).toBe(1);
    expect(counts.uploadPart).toBe(3); // 16 + 16 + 6 bytes
    expect(counts.completeMultipart).toBe(1);
    expect(await store.getBytes('originals/large.mp4')).toEqual(largePayload);

    // 3. Failing mid-stream AFTER part 1 starts aborts the R2 multipart upload cleanly (zero leaked orphan parts)
    let pullStep = 0;
    const failingStream = new ReadableStream<Uint8Array>({
      pull(c) {
        pullStep += 1;
        if (pullStep === 1) {
          c.enqueue(new Uint8Array(20).fill(1));
        } else {
          c.error(new Error('upstream connection reset'));
        }
      },
    });
    await expect(store.put('originals/broken.mp4', failingStream)).rejects.toThrow(
      /upstream connection reset/,
    );
    expect(counts.createMultipart).toBe(2);
    expect(counts.abortMultipart).toBe(1);
    expect(multiparts.size).toBe(0);

    // 4. Single-call getConditionalStream handles 200, 304, 206 suffix, and 416 with ZERO head() calls
    counts.head = 0;
    counts.get = 0;
    const okRes = await store.getConditionalStream('originals/large.mp4');
    expect(okRes?.status).toBe('ok');
    expect(counts.head).toBe(0);
    expect(counts.get).toBe(1);
    const etag = okRes && okRes.status === 'ok' ? okRes.etag! : '';
    if (okRes?.status === 'ok') await okRes.stream.cancel();

    const notMod = await store.getConditionalStream('originals/large.mp4', { ifNoneMatch: etag });
    expect(notMod?.status).toBe('not_modified');
    expect(counts.head).toBe(0);
    expect(counts.get).toBe(2);

    const suffixRes = await store.getConditionalStream('originals/large.mp4', {
      range: { suffix: 4 },
    });
    expect(suffixRes?.status).toBe('ok');
    if (suffixRes?.status === 'ok') {
      expect(suffixRes.range).toEqual({
        start: largePayload.byteLength - 4,
        end: largePayload.byteLength - 1,
        total: largePayload.byteLength,
      });
      expect(new TextDecoder().decode(await readStreamAll(suffixRes.stream))).toBe('TAIL');
    }
    expect(counts.head).toBe(0);
    expect(counts.get).toBe(3);

    const oobRes = await store.getConditionalStream('originals/large.mp4', {
      range: { offset: 9999, length: 10 },
    });
    expect(oobRes?.status).toBe('range_not_satisfiable');
    if (oobRes?.status === 'range_not_satisfiable') {
      expect(oobRes.total).toBe(largePayload.byteLength);
    }
    expect(counts.head).toBe(0);
    expect(counts.get).toBe(4);

    // 5. deleteMany deletes multiple keys in ONE single R2 batch delete call
    counts.delete = 0;
    counts.deleteBatch = 0;
    await store.deleteMany(['originals/small.bin', 'originals/large.mp4', 'originals/small.bin']);
    expect(counts.delete).toBe(1);
    expect(counts.deleteBatch).toBe(1);
    expect(await store.head('originals/large.mp4')).toBeNull();
  });

  it('offloads R2 media reads and multipart part writes from CharkleLibraryDO to the stateless edge Worker with 1-call reads and ZERO Class A list() amplification', async () => {
    const workerModule = await import('../src/index.js');
    const handler = workerModule.default;
    const { CharkleLibraryDO } = await import('../src/library-do.js');
    const doMock = await createSqliteBackedDoState();
    const { bucket, counts, entries } = createMockR2Bucket(50);

    let doHttpFetchCount = 0;
    const waitUntilPromises: Promise<unknown>[] = [];
    const execCtx = {
      waitUntil(p: Promise<unknown>) {
        waitUntilPromises.push(p);
      },
      passThroughOnException() {},
    } as unknown as ExecutionContext;

    let instance!: InstanceType<typeof CharkleLibraryDO>;
    const env = {
      MEDIA_BUCKET: bucket,
      CHARKLE_LIBRARY_ID: 'edge-opt',
      CHARKLE_VAULT_KEY: 'edge-opt-vault-key',
      CHARKLE_ADMIN_USERNAME: 'admin',
      CHARKLE_ADMIN_PASSWORD: 'edge-strong-password',
      ASSETS: { fetch: async () => new Response('spa-asset') },
      CHARKLE_LIBRARY: {
        idFromName: (name: string) => ({ toString: () => name }) as DurableObjectId,
        get: () =>
          ({
            fetch(req: Request) {
              doHttpFetchCount += 1;
              return instance.fetch(req);
            },
            resolveEdgeMediaRead: (req: Parameters<typeof instance.resolveEdgeMediaRead>[0]) =>
              instance.resolveEdgeMediaRead(req),
            noteEdgeMediaHit: (report: Parameters<typeof instance.noteEdgeMediaHit>[0]) =>
              instance.noteEdgeMediaHit(report),
            invalidateEdgeBlobKey: (
              assetID: Parameters<typeof instance.invalidateEdgeBlobKey>[0],
              slot: Parameters<typeof instance.invalidateEdgeBlobKey>[1],
            ) => instance.invalidateEdgeBlobKey(assetID, slot),
            authorizeEdgeMultipartPart: (
              req: Parameters<typeof instance.authorizeEdgeMultipartPart>[0],
            ) => instance.authorizeEdgeMultipartPart(req),
            recordEdgeMultipartPart: (
              params: Parameters<typeof instance.recordEdgeMultipartPart>[0],
            ) => instance.recordEdgeMultipartPart(params),
          }) as unknown as DurableObjectStub<InstanceType<typeof CharkleLibraryDO>>,
      },
    } as unknown as CharkleWorkerEnv;

    instance = new CharkleLibraryDO(doMock.state, env);

    try {
      // Login via Worker -> DO
      const loginRes = await handler.fetch(
        new Request('https://charkle.example.com/api/v1/auth/login', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ username: 'admin', password: 'edge-strong-password' }),
        }),
        env,
        execCtx,
      );
      expect(loginRes.status).toBe(200);
      const cookie = (loginRes.headers.get('set-cookie') ?? '').split(';')[0];

      // Create read-only PAT and write-only PAT to verify exact scope enforcement at the edge
      const readPatRes = await handler.fetch(
        new Request('https://charkle.example.com/api/v1/auth/tokens', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json', Cookie: cookie },
          body: JSON.stringify({ name: 'reader', scopes: ['read'] }),
        }),
        env,
        execCtx,
      );
      const readPat = ((await readPatRes.json()) as { token: string }).token;

      const writePatRes = await handler.fetch(
        new Request('https://charkle.example.com/api/v1/auth/tokens', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json', Cookie: cookie },
          body: JSON.stringify({ name: 'writer', scopes: ['write'] }),
        }),
        env,
        execCtx,
      );
      const writePat = ((await writePatRes.json()) as { token: string }).token;

      // Reset counters before multipart upload + media serving benchmark
      counts.list = 0;
      counts.head = 0;
      counts.get = 0;

      // 1. Edge-offloaded Multipart Upload: init (DO) -> PUT parts (outer Worker directly to R2!) -> complete (DO)
      const chunk1 = new TextEncoder().encode('EDGE-VIDEO-CHUNK-ONE-0123456789-');
      const chunk2 = new TextEncoder().encode('EDGE-VIDEO-CHUNK-TWO-ABCDEFGHIJ');
      const fullVideo = new Uint8Array(chunk1.byteLength + chunk2.byteLength);
      fullVideo.set(chunk1, 0);
      fullVideo.set(chunk2, chunk1.byteLength);
      const thumbJpegBytes = new Uint8Array([0xff, 0xd8, 0xff, 0xe0, 0x00, 0x10, 0x4a, 0x46, 0x49, 0x46, 0xff, 0xd9]);
      const thumb520Base64 = Buffer.from(thumbJpegBytes).toString('base64');

      const initRes = await handler.fetch(
        new Request('https://charkle.example.com/api/v1/uploads/multipart/init', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json', Cookie: cookie },
          body: JSON.stringify({
            fileName: 'hero-reel.mp4',
            mimeType: 'video/mp4',
            fileSizeBytes: fullVideo.byteLength,
            preprocessed: {
              pixelWidth: 1920,
              pixelHeight: 1080,
              durationSeconds: 12.5,
              thumbnail520Base64: thumb520Base64,
            },
          }),
        }),
        env,
        execCtx,
      );
      expect(initRes.status).toBe(201);
      const initBody = (await initRes.json()) as { sessionID: string; assetID: string };

      const doFetchBeforeParts = doHttpFetchCount;

      // Read-only PAT must be rejected on PUT part with 403 before touching R2
      const forbiddenPart = await handler.fetch(
        new Request(
          `https://charkle.example.com/api/v1/uploads/multipart/${initBody.sessionID}/part/1`,
          {
            method: 'PUT',
            headers: {
              Authorization: `Bearer ${readPat}`,
              'Content-Type': 'application/octet-stream',
            },
            body: chunk1,
          },
        ),
        env,
        execCtx,
      );
      expect(forbiddenPart.status).toBe(403);
      expect(counts.uploadPart).toBe(0);

      // Valid part uploads execute directly in outer Worker -> R2 without hitting DO.fetch!
      const p1Res = await handler.fetch(
        new Request(
          `https://charkle.example.com/api/v1/uploads/multipart/${initBody.sessionID}/part/1`,
          {
            method: 'PUT',
            headers: {
              Authorization: `Bearer ${writePat}`,
              'Content-Type': 'application/octet-stream',
              'Content-Length': String(chunk1.byteLength),
            },
            body: chunk1,
          },
        ),
        env,
        execCtx,
      );
      expect(p1Res.status).toBe(200);

      const p2Res = await handler.fetch(
        new Request(
          `https://charkle.example.com/api/v1/uploads/multipart/${initBody.sessionID}/part/2`,
          {
            method: 'PUT',
            headers: {
              Cookie: cookie,
              'Content-Type': 'application/octet-stream',
              'Content-Length': String(chunk2.byteLength),
            },
            body: chunk2,
          },
        ),
        env,
        execCtx,
      );
      expect(p2Res.status).toBe(200);
      expect(doHttpFetchCount).toBe(doFetchBeforeParts); // ZERO DO HTTP fetch for multipart chunks!
      expect(counts.uploadPart).toBe(2);

      const completeRes = await handler.fetch(
        new Request(
          `https://charkle.example.com/api/v1/uploads/multipart/${initBody.sessionID}/complete`,
          {
            method: 'POST',
            headers: { 'Content-Type': 'application/json', Cookie: cookie },
            body: JSON.stringify({}),
          },
        ),
        env,
        execCtx,
      );
      expect(completeRes.status).toBe(201);
      const { asset } = (await completeRes.json()) as {
        asset: { id: string; fileSizeBytes: number; pixelWidth: number; pixelHeight: number };
      };
      expect(asset.id).toBe(initBody.assetID);
      expect(asset.fileSizeBytes).toBe(fullVideo.byteLength);
      expect(asset.pixelWidth).toBe(1920);

      // Drain background tasks (scheduleAutoEvict) -> MUST perform ZERO Class A R2 list() calls!
      await new Promise((r) => setTimeout(r, 20));
      expect(counts.list).toBe(0);

      // 2. Edge-offloaded Thumbnail & Original Reads: 1 R2 GET, 0 R2 HEAD, 0 DO.fetch!
      const doFetchBeforeMedia = doHttpFetchCount;
      counts.head = 0;
      counts.get = 0;

      // Unauthenticated -> 401 with ZERO R2 calls
      const unauthThumb = await handler.fetch(
        new Request(`https://charkle.example.com/api/v1/media/${asset.id}/thumbnail/grid520`),
        env,
        execCtx,
      );
      expect(unauthThumb.status).toBe(401);
      expect(counts.get).toBe(0);

      // Write-only PAT -> 403 with ZERO R2 calls
      const forbiddenThumb = await handler.fetch(
        new Request(`https://charkle.example.com/api/v1/media/${asset.id}/thumbnail/grid520`, {
          headers: { Authorization: `Bearer ${writePat}` },
        }),
        env,
        execCtx,
      );
      expect(forbiddenThumb.status).toBe(403);
      expect(counts.get).toBe(0);

      // grid520 hit -> 200 in 1 single R2 GET, 0 HEAD, 0 DO.fetch
      const thumbRes = await handler.fetch(
        new Request(`https://charkle.example.com/api/v1/media/${asset.id}/thumbnail/grid520`, {
          headers: {
            Authorization: `Bearer ${readPat}`,
            Origin: 'chrome-extension://abcdefghijklmnop',
          },
        }),
        env,
        execCtx,
      );
      expect(thumbRes.status).toBe(200);
      expect(thumbRes.headers.get('x-content-type-options')).toBe('nosniff');
      expect(thumbRes.headers.get('access-control-allow-origin')).toBe(
        'chrome-extension://abcdefghijklmnop',
      );
      const thumbEtag = thumbRes.headers.get('etag');
      expect(thumbEtag).toBeTruthy();
      expect(new Uint8Array(await thumbRes.arrayBuffer())).toEqual(thumbJpegBytes);
      expect(counts.head).toBe(0);
      expect(counts.get).toBe(1);
      expect(doHttpFetchCount).toBe(doFetchBeforeMedia);

      // Conditional 304 Not Modified -> 1 single R2 GET, 0 HEAD
      const thumb304 = await handler.fetch(
        new Request(`https://charkle.example.com/api/v1/media/${asset.id}/thumbnail/grid520`, {
          headers: { Cookie: cookie, 'If-None-Match': thumbEtag! },
        }),
        env,
        execCtx,
      );
      expect(thumb304.status).toBe(304);
      expect(counts.head).toBe(0);
      expect(counts.get).toBe(2);

      // preview1400 (absent, falls back to hydrated grid520) -> 1 single R2 GET (was 6-11 before!)
      const previewRes = await handler.fetch(
        new Request(`https://charkle.example.com/api/v1/media/${asset.id}/thumbnail/preview1400`, {
          headers: { Cookie: cookie },
        }),
        env,
        execCtx,
      );
      expect(previewRes.status).toBe(200);
      expect(new Uint8Array(await previewRes.arrayBuffer())).toEqual(thumbJpegBytes);
      expect(counts.head).toBe(0);
      expect(counts.get).toBe(3);

      // Original Range 206 + Suffix Range 206 + OOB 416 -> each 1 single R2 GET, 0 HEAD, 0 DO.fetch!
      const rangeRes = await handler.fetch(
        new Request(`https://charkle.example.com/api/v1/media/${asset.id}/original`, {
          headers: { Cookie: cookie, Range: 'bytes=0-15' },
        }),
        env,
        execCtx,
      );
      expect(rangeRes.status).toBe(206);
      expect(rangeRes.headers.get('content-range')).toBe(`bytes 0-15/${fullVideo.byteLength}`);
      expect(await rangeRes.text()).toBe('EDGE-VIDEO-CHUNK');
      expect(counts.head).toBe(0);
      expect(counts.get).toBe(4);

      const suffixOrigRes = await handler.fetch(
        new Request(`https://charkle.example.com/api/v1/media/${asset.id}/original`, {
          headers: { Cookie: cookie, Range: 'bytes=-10' },
        }),
        env,
        execCtx,
      );
      expect(suffixOrigRes.status).toBe(206);
      expect(await suffixOrigRes.text()).toBe('ABCDEFGHIJ');
      expect(counts.head).toBe(0);
      expect(counts.get).toBe(5);

      const oobOrigRes = await handler.fetch(
        new Request(`https://charkle.example.com/api/v1/media/${asset.id}/original`, {
          headers: { Cookie: cookie, Range: 'bytes=9999-10000' },
        }),
        env,
        execCtx,
      );
      expect(oobOrigRes.status).toBe(416);
      expect(oobOrigRes.headers.get('content-range')).toBe(`bytes */${fullVideo.byteLength}`);
      expect(counts.head).toBe(0);
      expect(counts.get).toBe(6);
      expect(doHttpFetchCount).toBe(doFetchBeforeMedia);

      // 3. Cache stats & permanent delete use blob_index with ZERO Class A R2 list() calls!
      const statsRes = await handler.fetch(
        new Request('https://charkle.example.com/api/v1/cache/stats', {
          headers: { Cookie: cookie },
        }),
        env,
        execCtx,
      );
      expect(statsRes.status).toBe(200);
      const statsBody = (await statsRes.json()) as {
        stats: { originalCacheBytes: number; thumbnailBytes: number; cachedOriginalCount: number };
      };
      expect(statsBody.stats.originalCacheBytes).toBeGreaterThanOrEqual(fullVideo.byteLength);
      expect(statsBody.stats.thumbnailBytes).toBeGreaterThanOrEqual(thumbJpegBytes.byteLength);
      expect(counts.list).toBe(0);

      // Externally deleting the R2 object makes ?cachedOnly=1 return 404 NOT_CACHED & self-heals blob_index
      entries.delete(`originals/${asset.id}.mp4`);
      const cachedMiss = await handler.fetch(
        new Request(`https://charkle.example.com/api/v1/media/${asset.id}/original?cachedOnly=1`, {
          headers: { Cookie: cookie },
        }),
        env,
        execCtx,
      );
      expect(cachedMiss.status).toBe(404);
      expect(((await cachedMiss.json()) as { code: string }).code).toBe('NOT_CACHED');

      await Promise.all(waitUntilPromises);

      // Permanent delete removes remaining thumbnail in batched delete with ZERO list() calls
      const delRes = await handler.fetch(
        new Request('https://charkle.example.com/api/v1/assets/permanent-delete', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json', Cookie: cookie },
          body: JSON.stringify({ ids: [asset.id] }),
        }),
        env,
        execCtx,
      );
      expect(delRes.status).toBe(200);
      expect(counts.list).toBe(0);
      expect(entries.has(`thumbnails/520/${asset.id}.jpg`)).toBe(false);
    } finally {
      doMock.close();
    }
  });
});
