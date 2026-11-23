import JSZip from 'jszip';
import { describe, expect, it } from 'vitest';
import {
  DurableObjectSqlDatabase,
  splitSqlStatements,
  type DurableObjectSqlStorageLike,
} from '../src/do-sql.js';
import { BUNDLE_METADATA, createBundledAssets } from '../src/generated/bundles.js';
import { R2BlobStore } from '../src/r2-blob.js';

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

function createMockR2Bucket(pageSize = 2) {
  const entries = new Map<string, StoredR2Entry>();
  const getRangeCalls: Array<{ key: string; range?: R2Range }> = [];
  let versionCounter = 1;

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

  const bucket = {
    async put(
      key: string,
      value: ReadableStream | ArrayBuffer | ArrayBufferView | string | null | Blob,
      options?: R2PutOptions,
    ): Promise<R2Object> {
      if (value instanceof ReadableStream) {
        throw new TypeError('The ReadableStream provided to R2.put must have a known length');
      }
      let bytes: Uint8Array;
      if (value instanceof Uint8Array) {
        bytes = value.slice();
      } else if (ArrayBuffer.isView(value)) {
        bytes = new Uint8Array(value.buffer, value.byteOffset, value.byteLength).slice();
      } else if (value instanceof ArrayBuffer) {
        bytes = new Uint8Array(value).slice();
      } else if (typeof value === 'string') {
        bytes = new TextEncoder().encode(value);
      } else if (value === null) {
        bytes = new Uint8Array(0);
      } else {
        bytes = new Uint8Array(await value.arrayBuffer());
      }

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
      const entry = entries.get(key);
      return entry ? makeR2Object(entry) : null;
    },

    async get(key: string, options?: R2GetOptions): Promise<R2ObjectBody | null> {
      const entry = entries.get(key);
      if (!entry) return null;

      const requestedRange =
        options?.range && !(options.range instanceof Headers) ? options.range : undefined;
      getRangeCalls.push({ key, range: requestedRange });

      let slice = entry.bytes;
      let resolvedRange: R2Range | undefined;
      if (requestedRange && 'offset' in requestedRange && requestedRange.offset !== undefined) {
        const start = Math.max(0, requestedRange.offset);
        const end =
          requestedRange.length !== undefined
            ? Math.min(entry.bytes.byteLength, start + requestedRange.length)
            : entry.bytes.byteLength;
        slice = start < entry.bytes.byteLength ? entry.bytes.subarray(start, end) : new Uint8Array(0);
        resolvedRange = { offset: start, length: slice.byteLength };
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
      const list = Array.isArray(keys) ? keys : [keys];
      for (const k of list) entries.delete(k);
    },

    async list(options?: R2ListOptions): Promise<R2Objects> {
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

  return { bucket, entries, getRangeCalls };
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
