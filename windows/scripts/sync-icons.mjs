#!/usr/bin/env node
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const windowsDir = path.resolve(__dirname, '..');
const repoRoot = path.resolve(windowsDir, '..');

const sourceDir = path.join(repoRoot, 'Sources', 'CharkleApp', 'Resources', 'Icons');
const targetDir = path.join(windowsDir, 'ui', 'public', 'icons');

if (!fs.existsSync(sourceDir)) {
  console.error(`[sync-icons] Source directory not found: ${sourceDir}`);
  process.exit(1);
}

fs.mkdirSync(targetDir, { recursive: true });

const sourceFiles = fs
  .readdirSync(sourceDir, { withFileTypes: true })
  .filter((entry) => entry.isFile() && entry.name.toLowerCase().endsWith('.svg'))
  .map((entry) => entry.name)
  .sort();

const sourceSet = new Set(sourceFiles);
let copied = 0;
let unchanged = 0;
let removed = 0;

for (const name of sourceFiles) {
  const srcPath = path.join(sourceDir, name);
  const dstPath = path.join(targetDir, name);
  const srcBytes = fs.readFileSync(srcPath);
  if (fs.existsSync(dstPath) && Buffer.compare(srcBytes, fs.readFileSync(dstPath)) === 0) {
    unchanged += 1;
    continue;
  }
  fs.writeFileSync(dstPath, srcBytes);
  copied += 1;
}

for (const entry of fs.readdirSync(targetDir, { withFileTypes: true })) {
  if (entry.isFile() && entry.name.toLowerCase().endsWith('.svg') && !sourceSet.has(entry.name)) {
    fs.unlinkSync(path.join(targetDir, entry.name));
    removed += 1;
  }
}

console.log(
  `[sync-icons] Synced ${sourceFiles.length} SVG icons (${copied} updated, ${unchanged} unchanged, ${removed} removed) -> ${path.relative(repoRoot, targetDir)}`
);
