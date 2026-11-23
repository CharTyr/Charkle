import type { ISqlDatabase, SqlParam } from '@charkle/server/worker';

/**
 * Minimal structural subset of Cloudflare `DurableObjectStorage` needed by
 * `DurableObjectSqlDatabase` (allows clean mocking in unit tests while accepting
 * `this.ctx.storage` directly in workerd).
 */
export interface DurableObjectSqlStorageLike {
  readonly sql: SqlStorage;
  transactionSync<T>(closure: () => T): T;
}

/**
 * Node.js / file-backed SQLite PRAGMAs that Cloudflare Durable Objects SQLite
 * manages automatically or rejects with `SQLITE_AUTH`.
 */
const UNSUPPORTED_DO_PRAGMAS = new Set([
  'journal_mode',
  'synchronous',
  'busy_timeout',
  'wal_checkpoint',
  'locking_mode',
  'mmap_size',
  'temp_store',
  'cache_size',
  'auto_vacuum',
  'page_size',
  'secure_delete',
]);

/**
 * Splits a multi-statement SQL script into individual executable statements while
 * respecting single/double/backtick/bracket quoting and `--` / `/* ... *\/` comments.
 */
export function splitSqlStatements(script: string): string[] {
  const statements: string[] = [];
  let current = '';
  let i = 0;
  const len = script.length;

  let inSingle = false;
  let inDouble = false;
  let inBacktick = false;
  let inBracket = false;
  let inLineComment = false;
  let inBlockComment = false;

  while (i < len) {
    const ch = script[i];
    const next = i + 1 < len ? script[i + 1] : '';

    if (inLineComment) {
      current += ch;
      if (ch === '\n') inLineComment = false;
      i++;
      continue;
    }

    if (inBlockComment) {
      current += ch;
      if (ch === '*' && next === '/') {
        current += next;
        inBlockComment = false;
        i += 2;
        continue;
      }
      i++;
      continue;
    }

    if (inSingle) {
      current += ch;
      if (ch === "'") {
        if (next === "'") {
          current += next;
          i += 2;
          continue;
        }
        inSingle = false;
      }
      i++;
      continue;
    }

    if (inDouble) {
      current += ch;
      if (ch === '"') {
        if (next === '"') {
          current += next;
          i += 2;
          continue;
        }
        inDouble = false;
      }
      i++;
      continue;
    }

    if (inBacktick) {
      current += ch;
      if (ch === '`') {
        if (next === '`') {
          current += next;
          i += 2;
          continue;
        }
        inBacktick = false;
      }
      i++;
      continue;
    }

    if (inBracket) {
      current += ch;
      if (ch === ']') inBracket = false;
      i++;
      continue;
    }

    // Enter comments
    if (ch === '-' && next === '-') {
      inLineComment = true;
      current += '--';
      i += 2;
      continue;
    }
    if (ch === '/' && next === '*') {
      inBlockComment = true;
      current += '/*';
      i += 2;
      continue;
    }

    // Enter quotes
    if (ch === "'") {
      inSingle = true;
      current += ch;
      i++;
      continue;
    }
    if (ch === '"') {
      inDouble = true;
      current += ch;
      i++;
      continue;
    }
    if (ch === '`') {
      inBacktick = true;
      current += ch;
      i++;
      continue;
    }
    if (ch === '[') {
      inBracket = true;
      current += ch;
      i++;
      continue;
    }

    // Statement terminator
    if (ch === ';') {
      const trimmed = current.trim();
      if (trimmed.length > 0) {
        statements.push(trimmed);
      }
      current = '';
      i++;
      continue;
    }

    current += ch;
    i++;
  }

  const tail = current.trim();
  if (tail.length > 0) {
    statements.push(tail);
  }
  return statements;
}

function stripLeadingComments(sql: string): string {
  let s = sql.trimStart();
  for (;;) {
    if (s.startsWith('--')) {
      const nl = s.indexOf('\n');
      if (nl === -1) return '';
      s = s.slice(nl + 1).trimStart();
      continue;
    }
    if (s.startsWith('/*')) {
      const end = s.indexOf('*/');
      if (end === -1) return '';
      s = s.slice(end + 2).trimStart();
      continue;
    }
    break;
  }
  return s;
}

function extractPragmaName(stmt: string): string | null {
  const clean = stripLeadingComments(stmt);
  if (!clean) return null;
  const match = /^PRAGMA\s+(?:[a-zA-Z_][a-zA-Z0-9_]*\.)?([a-zA-Z_][a-zA-Z0-9_]*)/i.exec(clean);
  return match ? match[1].toLowerCase() : null;
}

function isCommentOnly(stmt: string): boolean {
  return stripLeadingComments(stmt).length === 0;
}

function normalizeSqlParam(param: SqlParam | boolean | undefined): SqlStorageValue {
  if (param === null || param === undefined) {
    return null;
  }
  if (typeof param === 'boolean') {
    return param ? 1 : 0;
  }
  if (typeof param === 'bigint') {
    if (param >= BigInt(Number.MIN_SAFE_INTEGER) && param <= BigInt(Number.MAX_SAFE_INTEGER)) {
      return Number(param);
    }
    return param.toString();
  }
  if (param instanceof Uint8Array) {
    if (
      param.byteOffset === 0 &&
      param.byteLength === param.buffer.byteLength &&
      param.buffer instanceof ArrayBuffer
    ) {
      return param.buffer;
    }
    return param.slice().buffer;
  }
  return param;
}

function normalizeRow<T>(row: Record<string, SqlStorageValue>): T {
  const out: Record<string, unknown> = {};
  for (const [key, value] of Object.entries(row)) {
    if (value instanceof ArrayBuffer) {
      out[key] = new Uint8Array(value);
    } else {
      out[key] = value;
    }
  }
  return out as T;
}

/**
 * Synchronous `ISqlDatabase` adapter backed by Cloudflare Durable Object SQLite
 * (`ctx.storage.sql` + `ctx.storage.transactionSync`).
 */
export class DurableObjectSqlDatabase implements ISqlDatabase {
  private readonly storage: DurableObjectSqlStorageLike;
  private txDepth = 0;

  constructor(storage: DurableObjectSqlStorageLike) {
    this.storage = storage;
  }

  exec(sql: string): void {
    const statements = splitSqlStatements(sql);
    for (const stmt of statements) {
      if (isCommentOnly(stmt)) continue;
      const pragmaName = extractPragmaName(stmt);
      if (pragmaName && UNSUPPORTED_DO_PRAGMAS.has(pragmaName)) {
        continue;
      }
      try {
        this.storage.sql.exec(stmt).toArray();
      } catch (err) {
        // Ignore DO SQLite rejection on optional PRAGMA statements; rethrow all real SQL errors
        if (pragmaName !== null) {
          continue;
        }
        throw err;
      }
    }
  }

  run(sql: string, params: SqlParam[] = []): { changes: number; lastInsertRowid?: number | bigint } {
    const pragmaName = extractPragmaName(sql);
    if (pragmaName && UNSUPPORTED_DO_PRAGMAS.has(pragmaName)) {
      return { changes: 0 };
    }
    const bound = params.map(normalizeSqlParam);
    const cursor = this.storage.sql.exec(sql, ...bound);
    cursor.toArray();
    return { changes: cursor.rowsWritten };
  }

  get<T = Record<string, unknown>>(sql: string, params: SqlParam[] = []): T | undefined {
    const bound = params.map(normalizeSqlParam);
    const rows = this.storage.sql.exec(sql, ...bound).toArray();
    if (rows.length === 0) return undefined;
    return normalizeRow<T>(rows[0]);
  }

  all<T = Record<string, unknown>>(sql: string, params: SqlParam[] = []): T[] {
    const bound = params.map(normalizeSqlParam);
    const rows = this.storage.sql.exec(sql, ...bound).toArray();
    return rows.map((row) => normalizeRow<T>(row));
  }

  transaction<T>(fn: () => T): T {
    // Re-entrancy guard: workerd throws if `transactionSync` is nested directly
    if (this.txDepth > 0) {
      return fn();
    }
    this.txDepth += 1;
    try {
      return this.storage.transactionSync(fn);
    } finally {
      this.txDepth -= 1;
    }
  }
}
