import fs from 'node:fs';
import path from 'node:path';
import { DatabaseSync, type SQLInputValue } from 'node:sqlite';
import { LibraryDatabase } from '../db/library-database.js';
import type { ISqlDatabase, SqlParam } from './types.js';

/**
 * Node.js 26 `node:sqlite` (`DatabaseSync`) implementation of `ISqlDatabase`.
 * ONLY imported by Node entrypoints (`app.ts`, `index.ts`, `mcp-stdio.ts`, Node tests).
 */
export class NodeSqlDatabase implements ISqlDatabase {
  public readonly dbPath: string;
  public readonly raw: DatabaseSync;
  private inTransaction = false;

  constructor(dbPath: string = ':memory:') {
    this.dbPath = dbPath;
    if (dbPath !== ':memory:') {
      fs.mkdirSync(path.dirname(dbPath), { recursive: true });
    }
    this.raw = new DatabaseSync(dbPath, {
      enableForeignKeyConstraints: true,
      timeout: 10_000,
    });
    if (dbPath !== ':memory:') {
      this.raw.exec('PRAGMA journal_mode = WAL;');
    }
    this.raw.exec('PRAGMA foreign_keys = ON; PRAGMA synchronous = NORMAL;');
  }

  exec(sql: string): void {
    this.raw.exec(sql);
  }

  run(sql: string, params: SqlParam[] = []): { changes: number; lastInsertRowid?: number | bigint } {
    const res = this.raw.prepare(sql).run(...(params as SQLInputValue[]));
    return {
      changes: Number(res.changes),
      lastInsertRowid: res.lastInsertRowid,
    };
  }

  get<T = Record<string, unknown>>(sql: string, params: SqlParam[] = []): T | undefined {
    return this.raw.prepare(sql).get(...(params as SQLInputValue[])) as T | undefined;
  }

  all<T = Record<string, unknown>>(sql: string, params: SqlParam[] = []): T[] {
    return this.raw.prepare(sql).all(...(params as SQLInputValue[])) as unknown as T[];
  }

  transaction<T>(fn: () => T): T {
    if (this.inTransaction) {
      return fn();
    }
    this.inTransaction = true;
    this.raw.exec('BEGIN IMMEDIATE');
    try {
      const result = fn();
      this.raw.exec('COMMIT');
      return result;
    } catch (err) {
      try {
        this.raw.exec('ROLLBACK');
      } catch {
        // Ignore rollback failure
      }
      throw err;
    } finally {
      this.inTransaction = false;
    }
  }

  close(): void {
    this.raw.close();
  }
}

/**
 * Convenience helper for Node.js & tests: opens a SQLite database file (or `:memory:`)
 * backed by `NodeSqlDatabase` and returns a migrated `LibraryDatabase`.
 */
export function openNodeLibraryDatabase(dbPath: string = ':memory:'): LibraryDatabase {
  const sql = new NodeSqlDatabase(dbPath);
  return new LibraryDatabase(sql, dbPath);
}
