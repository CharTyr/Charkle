import fs from 'node:fs';
import fsp from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import JSZip from 'jszip';
import type { IBundleAssets } from './types.js';

const EXCLUDED_EXTENSION_DIRS = new Set(['tests', 'test', '__tests__', 'node_modules']);
const EXCLUDED_EXTENSION_FILES = new Set([
  '.DS_Store',
  'Thumbs.db',
  'package.json',
  'package-lock.json',
  'tsconfig.json',
]);
const EXCLUDED_FIGMA_FILES = new Set(['.DS_Store', 'Thumbs.db', 'ui-template.html']);

function isExcludedExtensionFileName(name: string): boolean {
  if (name.startsWith('.')) return true;
  if (EXCLUDED_EXTENSION_FILES.has(name)) return true;
  if (/^vitest\.config\./i.test(name)) return true;
  if (/\.(?:test|spec)\.[^.]+$/i.test(name)) return true;
  if (/\.map$/i.test(name)) return true;
  return false;
}

export function resolveExtensionDir(): string | null {
  const envDir = process.env.CHARKLE_EXTENSION_DIR?.trim();
  if (envDir) {
    const resolved = path.resolve(envDir);
    return fs.existsSync(path.join(resolved, 'manifest.json')) ? resolved : null;
  }

  const here = path.dirname(fileURLToPath(import.meta.url));
  const candidates = [
    path.resolve(here, '../../../extension'),
    path.resolve(process.cwd(), 'packages/extension'),
    path.resolve(process.cwd(), '../extension'),
  ];
  for (const dir of candidates) {
    if (fs.existsSync(path.join(dir, 'manifest.json'))) {
      return dir;
    }
  }
  return null;
}

async function collectExtensionFiles(
  rootDir: string,
  subDir = '',
): Promise<Array<{ absPath: string; relPath: string }>> {
  const currentDir = subDir ? path.join(rootDir, subDir) : rootDir;
  const entries = await fsp.readdir(currentDir, { withFileTypes: true });
  entries.sort((a, b) => a.name.localeCompare(b.name));

  const results: Array<{ absPath: string; relPath: string }> = [];
  for (const entry of entries) {
    if (entry.isDirectory()) {
      if (entry.name.startsWith('.') || EXCLUDED_EXTENSION_DIRS.has(entry.name)) {
        continue;
      }
      const nextSub = subDir ? `${subDir}/${entry.name}` : entry.name;
      results.push(...(await collectExtensionFiles(rootDir, nextSub)));
    } else if (entry.isFile()) {
      if (isExcludedExtensionFileName(entry.name)) continue;
      const absPath = path.join(currentDir, entry.name);
      const relPath = subDir ? `${subDir}/${entry.name}` : entry.name;
      results.push({ absPath, relPath });
    }
  }
  return results;
}

export function resolveFigmaPluginDir(): string | null {
  const envDir = process.env.CHARKLE_FIGMA_PLUGIN_DIR?.trim();
  if (envDir) {
    const resolved = path.resolve(envDir);
    return fs.existsSync(path.join(resolved, 'manifest.json')) ? resolved : null;
  }

  const here = path.dirname(fileURLToPath(import.meta.url));
  const candidates = [
    path.resolve(here, '../../../../figma-plugin'),
    path.resolve(here, '../../../figma-plugin'),
    path.resolve(process.cwd(), 'figma-plugin'),
    path.resolve(process.cwd(), '../../figma-plugin'),
  ];
  for (const dir of candidates) {
    if (fs.existsSync(path.join(dir, 'manifest.json'))) {
      return dir;
    }
  }
  return null;
}

async function collectFigmaPluginFiles(
  rootDir: string,
  subDir = '',
): Promise<Array<{ absPath: string; relPath: string }>> {
  const currentDir = subDir ? path.join(rootDir, subDir) : rootDir;
  const entries = await fsp.readdir(currentDir, { withFileTypes: true });
  entries.sort((a, b) => a.name.localeCompare(b.name));

  const results: Array<{ absPath: string; relPath: string }> = [];
  for (const entry of entries) {
    if (entry.isDirectory()) {
      if (entry.name.startsWith('.') || EXCLUDED_EXTENSION_DIRS.has(entry.name)) {
        continue;
      }
      const nextSub = subDir ? `${subDir}/${entry.name}` : entry.name;
      results.push(...(await collectFigmaPluginFiles(rootDir, nextSub)));
    } else if (entry.isFile()) {
      if (entry.name.startsWith('.') || EXCLUDED_FIGMA_FILES.has(entry.name)) continue;
      const absPath = path.join(currentDir, entry.name);
      const relPath = subDir ? `${subDir}/${entry.name}` : entry.name;
      results.push({ absPath, relPath });
    }
  }
  return results;
}

/**
 * Node.js bundle asset provider that zips `packages/extension/` and `figma-plugin/`
 * directly from disk using `JSZip`.
 */
export class NodeBundleAssets implements IBundleAssets {
  async getExtensionZip(): Promise<Uint8Array | null> {
    const extDir = resolveExtensionDir();
    if (!extDir) return null;
    const files = await collectExtensionFiles(extDir);
    if (files.length === 0) return null;

    const zip = new JSZip();
    for (const file of files) {
      const data = await fsp.readFile(file.absPath);
      zip.file(file.relPath, data);
    }
    return zip.generateAsync({
      type: 'uint8array',
      compression: 'DEFLATE',
      compressionOptions: { level: 6 },
    });
  }

  async getFigmaPluginZip(): Promise<Uint8Array | null> {
    const pluginDir = resolveFigmaPluginDir();
    if (!pluginDir) return null;
    const files = await collectFigmaPluginFiles(pluginDir);
    if (files.length === 0) return null;

    const zip = new JSZip();
    for (const file of files) {
      const data = await fsp.readFile(file.absPath);
      zip.file(file.relPath, data);
    }
    return zip.generateAsync({
      type: 'uint8array',
      compression: 'DEFLATE',
      compressionOptions: { level: 6 },
    });
  }
}
