/**
 * Isomorphic GitHub-Flavored Markdown + README HTML parser & URL resolver.
 * Port of Swift `MarkdownDocumentParser` (`MarkdownDocumentParser.swift`) with
 * YAML frontmatter stripping/parsing, heading TOC extraction, GFM callouts,
 * and GitHub relative URL / `blob -> raw` rewriting.
 */

export type MarkdownAlignment = 'leading' | 'center' | 'trailing';

export type MarkdownAlertKind = 'note' | 'tip' | 'important' | 'warning' | 'caution';

export const MARKDOWN_ALERT_LABELS: Record<MarkdownAlertKind, string> = {
  note: 'Note',
  tip: 'Tip',
  important: 'Important',
  warning: 'Warning',
  caution: 'Caution',
};

export function markdownAlertLabel(kind: MarkdownAlertKind): string {
  return MARKDOWN_ALERT_LABELS[kind];
}

export type MarkdownListMarker =
  | { type: 'bullet' }
  | { type: 'ordered'; index: number }
  | { type: 'task'; checked: boolean };

export interface MarkdownImageItem {
  id: number;
  url: string;
  alt: string;
  width?: number | null;
  height?: number | null;
  linkURL?: string | null;
}

export type MarkdownBlock =
  | { type: 'heading'; id: number; level: number; text: string; slug: string; alignment: MarkdownAlignment }
  | { type: 'paragraph'; id: number; text: string; alignment: MarkdownAlignment }
  | { type: 'image'; id: number; item: MarkdownImageItem; alignment: MarkdownAlignment }
  | { type: 'imageRow'; id: number; items: MarkdownImageItem[]; alignment: MarkdownAlignment }
  | { type: 'code'; id: number; language: string; content: string }
  | { type: 'quote'; id: number; alertKind: MarkdownAlertKind | null; text: string }
  | { type: 'listItem'; id: number; marker: MarkdownListMarker; indent: number; text: string }
  | {
      type: 'table';
      id: number;
      headers: string[];
      alignments: MarkdownAlignment[];
      rows: string[][];
    }
  | { type: 'details'; id: number; summary: string; children: MarkdownBlock[] }
  | { type: 'divider'; id: number };

export interface MarkdownFrontmatterEntry {
  key: string;
  value: string;
}

export interface MarkdownFrontmatterResult {
  frontmatter: Record<string, string>;
  entries: MarkdownFrontmatterEntry[];
  rawFrontmatter: string | null;
  body: string;
}

export interface MarkdownTocItem {
  id: number;
  level: number;
  text: string;
  slug: string;
}

export interface MarkdownURLContext {
  rawAssetBaseURL?: string | null;
  webLinkBaseURL?: string | null;
  repoHomeURL?: string | null;
}

export interface ParsedMarkdownDocument {
  frontmatter: Record<string, string>;
  frontmatterEntries: MarkdownFrontmatterEntry[];
  rawFrontmatter: string | null;
  body: string;
  blocks: MarkdownBlock[];
  toc: MarkdownTocItem[];
}

export function createGitHubMarkdownURLContext(
  owner: string,
  repo: string,
  branch = 'main',
): MarkdownURLContext {
  const safeOwner = owner.trim();
  const safeRepo = repo.trim();
  const safeBranch = branch.trim() || 'main';
  return {
    rawAssetBaseURL: `https://raw.githubusercontent.com/${safeOwner}/${safeRepo}/${safeBranch}/`,
    webLinkBaseURL: `https://github.com/${safeOwner}/${safeRepo}/blob/${safeBranch}/`,
    repoHomeURL: `https://github.com/${safeOwner}/${safeRepo}`,
  };
}

/**
 * Rewrites `https://github.com/<owner>/<repo>/blob/<branch>/<path>` URLs into
 * `https://raw.githubusercontent.com/<owner>/<repo>/<branch>/<path>` so images fetch raw bytes.
 */
export function rewriteGitHubBlobToRawURL(raw: string): string {
  const trimmed = raw.trim();
  if (!trimmed) return trimmed;
  try {
    const parsed = new URL(trimmed);
    const host = parsed.hostname.toLowerCase();
    if (host === 'github.com' || host === 'www.github.com') {
      const parts = parsed.pathname.split('/').filter((segment) => segment.length > 0);
      if (parts.length >= 5 && parts[2] === 'blob') {
        const rest = parts.slice(3).join('/');
        return `https://raw.githubusercontent.com/${parts[0]}/${parts[1]}/${rest}`;
      }
      if (parts.length >= 5 && parts[2] === 'raw') {
        const rest = parts.slice(3).join('/');
        return `https://raw.githubusercontent.com/${parts[0]}/${parts[1]}/${rest}`;
      }
    }
  } catch {
    return trimmed;
  }
  return trimmed;
}

export function resolveMarkdownAssetURL(
  raw: string,
  context?: MarkdownURLContext | null,
): string {
  const trimmed = raw.trim();
  if (!trimmed) return trimmed;
  if (/^(?:https?:|data:)/i.test(trimmed)) {
    return rewriteGitHubBlobToRawURL(trimmed);
  }
  if (trimmed.startsWith('//')) {
    return `https:${trimmed}`;
  }
  const base = context?.rawAssetBaseURL;
  if (!base) return trimmed;
  const cleanRel = trimmed.startsWith('/') ? trimmed.slice(1) : trimmed;
  try {
    return new URL(cleanRel, base).toString();
  } catch {
    return trimmed;
  }
}

export function resolveMarkdownLinkURL(
  raw: string,
  context?: MarkdownURLContext | null,
): string {
  const trimmed = raw.trim();
  if (!trimmed) return trimmed;
  if (/^(?:https?:|mailto:)/i.test(trimmed)) {
    return trimmed;
  }
  if (trimmed.startsWith('//')) {
    return `https:${trimmed}`;
  }
  if (trimmed.startsWith('#')) {
    if (context?.repoHomeURL) {
      return `${context.repoHomeURL}${trimmed}`;
    }
    return trimmed;
  }
  const base = context?.webLinkBaseURL;
  if (!base) return trimmed;
  const cleanRel = trimmed.startsWith('/') ? trimmed.slice(1) : trimmed;
  try {
    return new URL(cleanRel, base).toString();
  } catch {
    return trimmed;
  }
}

/**
 * Strips leading YAML frontmatter (`---\n...\n---`) if present and extracts key/value pairs.
 */
export function extractMarkdownFrontmatter(markdown: string): MarkdownFrontmatterResult {
  const normalized = markdown.replace(/\r\n/g, '\n').replace(/\r/g, '\n');
  const match = /^---\n([\s\S]*?)\n---(?:\n|$)/.exec(normalized);
  if (!match) {
    return {
      frontmatter: {},
      entries: [],
      rawFrontmatter: null,
      body: normalized,
    };
  }

  const rawFrontmatter = match[1];
  const body = normalized.slice(match[0].length);
  const frontmatter: Record<string, string> = {};
  const entries: MarkdownFrontmatterEntry[] = [];

  let currentKey: string | null = null;
  let listBuffer: string[] = [];

  const flushList = (): void => {
    if (currentKey && listBuffer.length > 0) {
      const joined = listBuffer.join(', ');
      frontmatter[currentKey] = joined;
      entries.push({ key: currentKey, value: joined });
    }
    currentKey = null;
    listBuffer = [];
  };

  for (const line of rawFrontmatter.split('\n')) {
    const trimmed = line.trim();
    if (!trimmed || trimmed.startsWith('#')) continue;

    const listMatch = /^-\s+(.*)$/.exec(trimmed);
    if (listMatch && currentKey) {
      listBuffer.push(unquoteYamlScalar(listMatch[1]));
      continue;
    }

    flushList();
    const kvMatch = /^([A-Za-z0-9_.-]+)\s*:\s*(.*)$/.exec(trimmed);
    if (!kvMatch) continue;
    const key = kvMatch[1].trim();
    const rawVal = kvMatch[2].trim();
    if (!rawVal) {
      currentKey = key;
      listBuffer = [];
      continue;
    }
    const value = unquoteYamlScalar(rawVal);
    frontmatter[key] = value;
    entries.push({ key, value });
  }
  flushList();

  return {
    frontmatter,
    entries,
    rawFrontmatter,
    body,
  };
}

function unquoteYamlScalar(raw: string): string {
  const trimmed = raw.trim();
  if (
    (trimmed.startsWith('"') && trimmed.endsWith('"') && trimmed.length >= 2) ||
    (trimmed.startsWith("'") && trimmed.endsWith("'") && trimmed.length >= 2)
  ) {
    return trimmed.slice(1, -1);
  }
  if (trimmed.startsWith('[') && trimmed.endsWith(']')) {
    return trimmed
      .slice(1, -1)
      .split(',')
      .map((s) => unquoteYamlScalar(s))
      .filter((s) => s.length > 0)
      .join(', ');
  }
  return trimmed;
}

export function slugifyMarkdownHeading(text: string): string {
  const stripped = text
    .replace(/!\[([^\]]*)\]\([^)]+\)/g, '$1')
    .replace(/\[([^\]]+)\]\([^)]+\)/g, '$1')
    .replace(/[`*_~]/g, '')
    .trim()
    .toLowerCase();
  const slug = stripped
    .replace(/[^\p{L}\p{N}\s-]/gu, '')
    .replace(/\s+/g, '-')
    .replace(/-+/g, '-')
    .replace(/^-|-$/g, '');
  return slug || 'section';
}

export function detectMarkdownCallout(
  text: string,
): { alertKind: MarkdownAlertKind; body: string } | null {
  const normalized = text.replace(/\r\n/g, '\n').replace(/\r/g, '\n');
  const lines = normalized.split('\n');
  const first = lines[0]?.trim().toUpperCase() ?? '';
  let alertKind: MarkdownAlertKind | null = null;
  if (first === '[!NOTE]') alertKind = 'note';
  else if (first === '[!TIP]') alertKind = 'tip';
  else if (first === '[!IMPORTANT]') alertKind = 'important';
  else if (first === '[!WARNING]') alertKind = 'warning';
  else if (first === '[!CAUTION]') alertKind = 'caution';
  if (!alertKind) return null;
  return {
    alertKind,
    body: lines.slice(1).join('\n').trim(),
  };
}

export function extractMarkdownToc(
  markdownOrBlocks: string | readonly MarkdownBlock[],
): MarkdownTocItem[] {
  const blocks =
    typeof markdownOrBlocks === 'string'
      ? parseMarkdownDocument(markdownOrBlocks).blocks
      : markdownOrBlocks;
  const items: MarkdownTocItem[] = [];
  const walk = (list: readonly MarkdownBlock[]): void => {
    for (const block of list) {
      if (block.type === 'heading') {
        items.push({
          id: block.id,
          level: block.level,
          text: block.text,
          slug: block.slug,
        });
      } else if (block.type === 'details') {
        walk(block.children);
      }
    }
  };
  walk(blocks);
  return items;
}

export function parseMarkdownDocument(
  markdown: string,
  urlContext: MarkdownURLContext = {},
): ParsedMarkdownDocument {
  const fm = extractMarkdownFrontmatter(markdown);
  const blocks = parseMarkdownBlocks(fm.body, urlContext);
  const toc = extractMarkdownToc(blocks);
  return {
    frontmatter: fm.frontmatter,
    frontmatterEntries: fm.entries,
    rawFrontmatter: fm.rawFrontmatter,
    body: fm.body,
    blocks,
    toc,
  };
}

export function parseMarkdownBlocks(
  markdown: string,
  urlContext: MarkdownURLContext = {},
): MarkdownBlock[] {
  const state = { nextID: 0, slugCounts: new Map<string, number>() };
  return parseInternal(markdown, urlContext, state);
}

interface ParseState {
  nextID: number;
  slugCounts: Map<string, number>;
}

function allocID(state: ParseState): number {
  const id = state.nextID;
  state.nextID += 1;
  return id;
}

function allocHeadingSlug(text: string, state: ParseState): string {
  const base = slugifyMarkdownHeading(text);
  const count = state.slugCounts.get(base) ?? 0;
  state.slugCounts.set(base, count + 1);
  return count === 0 ? base : `${base}-${count}`;
}

function parseInternal(
  markdown: string,
  urlContext: MarkdownURLContext,
  state: ParseState,
): MarkdownBlock[] {
  const normalized = markdown.replace(/\r\n/g, '\n').replace(/\r/g, '\n');
  const cleaned = stripHTMLCommentsOutsideCode(normalized);
  const lines = cleaned.split('\n');

  const result: MarkdownBlock[] = [];
  let i = 0;

  while (i < lines.length) {
    const line = lines[i];
    const trimmed = line.trim();

    if (trimmed.length === 0) {
      i += 1;
      continue;
    }

    // 1. Fenced code block (``` or ~~~)
    const fence = openingFence(trimmed);
    if (fence) {
      const lang = trimmed.slice(fence.count).trim();
      const codeLines: string[] = [];
      i += 1;
      while (i < lines.length) {
        const curTrimmed = lines[i].trim();
        if (
          curTrimmed.startsWith(fence.marker) &&
          curTrimmed.length >= fence.count &&
          isAllChar(curTrimmed, fence.char)
        ) {
          i += 1;
          break;
        }
        codeLines.push(lines[i]);
        i += 1;
      }
      result.push({
        type: 'code',
        id: allocID(state),
        language: lang,
        content: codeLines.join('\n'),
      });
      continue;
    }

    // 2. HTML <details>...</details>
    if (matchesOpeningTag(trimmed, 'details')) {
      const collected = collectHTMLBlock(lines, i, 'details');
      i = collected.nextIndex;
      const { summary, body } = splitDetailsBlock(collected.html);
      const children = parseInternal(body, urlContext, state);
      result.push({ type: 'details', id: allocID(state), summary, children });
      continue;
    }

    // 3. HTML <pre>...</pre>
    if (matchesOpeningTag(trimmed, 'pre')) {
      const collected = collectHTMLBlock(lines, i, 'pre');
      i = collected.nextIndex;
      const content = extractPreCodeText(collected.html);
      result.push({ type: 'code', id: allocID(state), language: '', content });
      continue;
    }

    // 4. HTML <hr> / <hr/>
    if (isHTMLHorizontalRule(trimmed)) {
      result.push({ type: 'divider', id: allocID(state) });
      i += 1;
      continue;
    }

    // 5. HTML Heading <h1..h6>
    const headingTag = detectHTMLHeadingTag(trimmed);
    if (headingTag) {
      const collected = collectHTMLBlock(lines, i, headingTag.tag);
      i = collected.nextIndex;
      const alignment = extractAlignment(collected.html);
      const inner = stripOuterTag(collected.html, headingTag.tag);
      const text = convertInlineHTMLToMarkdown(inner, urlContext).trim();
      if (text.length > 0) {
        result.push({
          type: 'heading',
          id: allocID(state),
          level: headingTag.level,
          text,
          slug: allocHeadingSlug(text, state),
          alignment,
        });
      }
      continue;
    }

    // 6. HTML container (<p>, <div>, <center>, <picture>, <figure>) or standalone <img>
    const containerTag = detectHTMLContainerTag(trimmed);
    if (containerTag) {
      const collected = collectHTMLBlock(lines, i, containerTag);
      i = collected.nextIndex;
      const alignment: MarkdownAlignment =
        containerTag === 'center' ? 'center' : extractAlignment(collected.html);
      const inner = stripOuterTag(collected.html, containerTag);
      appendHTMLContainerBlocks(inner, alignment, urlContext, result, state);
      continue;
    }

    if (isStandaloneHTMLImageLine(trimmed)) {
      appendHTMLContainerBlocks(trimmed, 'leading', urlContext, result, state);
      i += 1;
      continue;
    }

    // 7. Markdown Horizontal Rule (---, ***, ___)
    if (isMarkdownHorizontalRule(trimmed)) {
      result.push({ type: 'divider', id: allocID(state) });
      i += 1;
      continue;
    }

    // 8. Markdown ATX Heading (# .. ######)
    if (trimmed.startsWith('#')) {
      let hashes = 0;
      while (hashes < trimmed.length && trimmed[hashes] === '#') hashes += 1;
      if (hashes <= 6 && trimmed[hashes] === ' ') {
        let title = trimmed.slice(hashes + 1).trim();
        while (title.endsWith('#')) title = title.slice(0, -1);
        title = convertInlineHTMLToMarkdown(title, urlContext).trim();
        result.push({
          type: 'heading',
          id: allocID(state),
          level: hashes,
          text: title,
          slug: allocHeadingSlug(title, state),
          alignment: 'leading',
        });
        i += 1;
        continue;
      }
    }

    // 9. GFM Pipe Table
    if (i + 1 < lines.length && looksLikeTableRow(trimmed)) {
      const tableAlignments = parseTableDelimiterRow(lines[i + 1]);
      if (tableAlignments) {
        const rawHeaders = splitTableCells(trimmed);
        const colCount = Math.max(rawHeaders.length, tableAlignments.length);
        const headers = padCells(rawHeaders, colCount).map((cell) =>
          convertInlineHTMLToMarkdown(cell, urlContext),
        );
        const normalizedAligns: MarkdownAlignment[] = Array.from({ length: colCount }, (_, idx) =>
          idx < tableAlignments.length ? tableAlignments[idx] : 'leading',
        );
        i += 2;
        const rows: string[][] = [];
        while (i < lines.length) {
          const rowTrimmed = lines[i].trim();
          if (!rowTrimmed || !looksLikeTableRow(rowTrimmed)) break;
          const cells = padCells(splitTableCells(rowTrimmed), colCount).map((cell) =>
            convertInlineHTMLToMarkdown(cell, urlContext),
          );
          rows.push(cells);
          i += 1;
        }
        result.push({
          type: 'table',
          id: allocID(state),
          headers,
          alignments: normalizedAligns,
          rows,
        });
        continue;
      }
    }

    // 10. Blockquote + GitHub Alert Callouts (> [!NOTE], [!TIP], [!IMPORTANT], [!WARNING], [!CAUTION])
    if (trimmed.startsWith('>')) {
      const quoteLines: string[] = [];
      while (i < lines.length && lines[i].trim().startsWith('>')) {
        let stripped = lines[i].trim().slice(1);
        if (stripped.startsWith(' ')) stripped = stripped.slice(1);
        quoteLines.push(stripped);
        i += 1;
      }
      const rawQuote = quoteLines.join('\n');
      const callout = detectMarkdownCallout(rawQuote);
      const alertKind = callout?.alertKind ?? null;
      const bodyRaw = callout ? callout.body : rawQuote;
      const joined = convertInlineHTMLToMarkdown(bodyRaw, urlContext).trim();
      if (joined.length > 0 || alertKind !== null) {
        result.push({
          type: 'quote',
          id: allocID(state),
          alertKind,
          text: joined,
        });
      }
      continue;
    }

    // 11. List Item (Task / Bullet / Ordered)
    const listMatch = parseListItem(line);
    if (listMatch) {
      const text = convertInlineHTMLToMarkdown(listMatch.content, urlContext);
      result.push({
        type: 'listItem',
        id: allocID(state),
        marker: listMatch.marker,
        indent: listMatch.indent,
        text,
      });
      i += 1;
      continue;
    }

    // 12. Standalone Markdown Image(s) / Linked Badge Row
    const mdImages = parseStandaloneMarkdownImages(trimmed, urlContext, state);
    if (mdImages) {
      if (mdImages.length === 1) {
        result.push({
          type: 'image',
          id: allocID(state),
          item: mdImages[0],
          alignment: 'leading',
        });
      } else {
        result.push({
          type: 'imageRow',
          id: allocID(state),
          items: mdImages,
          alignment: 'leading',
        });
      }
      i += 1;
      continue;
    }

    // 13. Paragraph (stop before any block boundary)
    const paraLines: string[] = [trimmed];
    i += 1;
    while (i < lines.length) {
      const rawNext = lines[i];
      const peek = rawNext.trim();
      if (
        peek.length === 0 ||
        openingFence(peek) !== null ||
        peek.startsWith('#') ||
        peek.startsWith('>') ||
        isMarkdownHorizontalRule(peek) ||
        isHTMLHorizontalRule(peek) ||
        parseListItem(rawNext) !== null ||
        matchesOpeningTag(peek, 'details') ||
        matchesOpeningTag(peek, 'pre') ||
        detectHTMLHeadingTag(peek) !== null ||
        detectHTMLContainerTag(peek) !== null ||
        isStandaloneHTMLImageLine(peek) ||
        (i + 1 < lines.length &&
          looksLikeTableRow(peek) &&
          parseTableDelimiterRow(lines[i + 1]) !== null)
      ) {
        break;
      }

      // Setext H1/H2 underline
      if (
        paraLines.length === 1 &&
        (isSetextUnderline(peek, '=') || isSetextUnderline(peek, '-'))
      ) {
        const level = peek[0] === '=' ? 1 : 2;
        const headingText = convertInlineHTMLToMarkdown(paraLines[0], urlContext).trim();
        result.push({
          type: 'heading',
          id: allocID(state),
          level,
          text: headingText,
          slug: allocHeadingSlug(headingText, state),
          alignment: 'leading',
        });
        paraLines.length = 0;
        i += 1;
        break;
      }

      paraLines.push(peek);
      i += 1;
    }

    if (paraLines.length > 0) {
      const converted = convertInlineHTMLToMarkdown(paraLines.join('\n'), urlContext).trim();
      if (converted.length > 0) {
        result.push({
          type: 'paragraph',
          id: allocID(state),
          text: converted,
          alignment: 'leading',
        });
      }
    }
  }

  return result;
}

function isAllChar(str: string, ch: string): boolean {
  for (let idx = 0; idx < str.length; idx++) {
    if (str[idx] !== ch) return false;
  }
  return str.length > 0;
}

interface FenceInfo {
  char: '`' | '~';
  count: number;
  marker: string;
}

function openingFence(trimmed: string): FenceInfo | null {
  const first = trimmed[0];
  if (first !== '`' && first !== '~') return null;
  let count = 0;
  while (count < trimmed.length && trimmed[count] === first) count += 1;
  if (count < 3) return null;
  return { char: first, count, marker: first.repeat(count) };
}

function stripHTMLCommentsOutsideCode(input: string): string {
  const lines = input.split('\n');
  const out: string[] = [];
  let activeFenceChar: '`' | '~' | null = null;
  let activeFenceCount = 0;
  let inComment = false;

  for (const line of lines) {
    const trimmed = line.trim();
    if (activeFenceChar) {
      out.push(line);
      if (trimmed.length >= activeFenceCount && isAllChar(trimmed, activeFenceChar)) {
        activeFenceChar = null;
        activeFenceCount = 0;
      }
      continue;
    }
    if (!inComment) {
      const fence = openingFence(trimmed);
      if (fence) {
        activeFenceChar = fence.char;
        activeFenceCount = fence.count;
        out.push(line);
        continue;
      }
    }

    let current = line;
    for (;;) {
      if (inComment) {
        const endIdx = current.indexOf('-->');
        if (endIdx >= 0) {
          current = current.slice(endIdx + 3);
          inComment = false;
        } else {
          current = '';
          break;
        }
      } else {
        const startIdx = current.indexOf('<!--');
        if (startIdx >= 0) {
          const prefix = current.slice(0, startIdx);
          const after = current.slice(startIdx + 4);
          const endIdx = after.indexOf('-->');
          if (endIdx >= 0) {
            current = prefix + after.slice(endIdx + 3);
          } else {
            current = prefix;
            inComment = true;
            break;
          }
        } else {
          break;
        }
      }
    }
    out.push(current);
  }
  return out.join('\n');
}

function isMarkdownHorizontalRule(trimmed: string): boolean {
  const compact = trimmed.replace(/\s+/g, '');
  if (compact.length < 3) return false;
  const first = compact[0];
  if (first !== '-' && first !== '*' && first !== '_') return false;
  return isAllChar(compact, first);
}

function isSetextUnderline(trimmed: string, ch: '=' | '-'): boolean {
  return trimmed.length >= 3 && isAllChar(trimmed, ch);
}

function isHTMLHorizontalRule(trimmed: string): boolean {
  return /^<hr\b[^>]*\/?>$/i.test(trimmed);
}

function matchesOpeningTag(trimmed: string, tag: string): boolean {
  return new RegExp(`^<${tag}\\b[^>]*>`, 'i').test(trimmed);
}

function detectHTMLHeadingTag(trimmed: string): { tag: string; level: number } | null {
  for (let level = 1; level <= 6; level++) {
    const tag = `h${level}`;
    if (matchesOpeningTag(trimmed, tag)) {
      return { tag, level };
    }
  }
  return null;
}

function detectHTMLContainerTag(trimmed: string): string | null {
  for (const tag of ['p', 'div', 'center', 'picture', 'figure']) {
    if (matchesOpeningTag(trimmed, tag)) return tag;
  }
  return null;
}

function isStandaloneHTMLImageLine(trimmed: string): boolean {
  return /^<(?:a\b[^>]*>\s*)?<img\b[^>]*>(?:\s*<\/a>)?$/i.test(trimmed);
}

function collectHTMLBlock(
  lines: readonly string[],
  startIndex: number,
  tag: string,
): { html: string; nextIndex: number } {
  const openRe = new RegExp(`<${tag}\\b[^>]*>`, 'gi');
  const closeRe = new RegExp(`<\\/${tag}\\s*>`, 'gi');
  let depth = 0;
  const collected: string[] = [];
  let idx = startIndex;
  while (idx < lines.length) {
    const line = lines[idx];
    collected.push(line);
    const opens = (line.match(openRe) ?? []).length;
    const closes = (line.match(closeRe) ?? []).length;
    depth += opens - closes;
    idx += 1;
    if (depth <= 0) break;
  }
  return { html: collected.join('\n'), nextIndex: idx };
}

function extractAlignment(html: string): MarkdownAlignment {
  const match = /align\s*=\s*["']?(center|right|left)["']?/i.exec(html);
  if (!match) return 'leading';
  switch (match[1].toLowerCase()) {
    case 'center':
      return 'center';
    case 'right':
      return 'trailing';
    default:
      return 'leading';
  }
}

function stripOuterTag(html: string, tag: string): string {
  return html
    .trim()
    .replace(new RegExp(`^<${tag}\\b[^>]*>`, 'i'), '')
    .replace(new RegExp(`<\\/${tag}\\s*>$`, 'i'), '')
    .trim();
}

function splitDetailsBlock(html: string): { summary: string; body: string } {
  let inner = stripOuterTag(html, 'details');
  let summary = '展开详情';
  const match = /<summary\b[^>]*>([\s\S]*?)<\/summary>/i.exec(inner);
  if (match) {
    const cleaned = decodeMarkdownHTMLEntities(stripAllHTMLTags(match[1])).trim();
    if (cleaned.length > 0) summary = cleaned;
    inner = inner.slice(0, match.index) + inner.slice(match.index + match[0].length);
  }
  return { summary, body: inner.trim() };
}

function extractPreCodeText(html: string): string {
  let inner = stripOuterTag(html, 'pre');
  if (/^<code\b[^>]*>/i.test(inner)) {
    inner = stripOuterTag(inner, 'code');
  }
  return decodeMarkdownHTMLEntities(inner).replace(/^\n+|\n+$/g, '');
}

function appendHTMLContainerBlocks(
  innerHTML: string,
  alignment: MarkdownAlignment,
  urlContext: MarkdownURLContext,
  result: MarkdownBlock[],
  state: ParseState,
): void {
  let working = innerHTML
    .replace(/<source\b[^>]*\/?>/gi, '')
    .replace(/<\/?(?:picture|figure)\b[^>]*>/gi, '');

  const headingRe = /<h([1-6])\b[^>]*>([\s\S]*?)<\/h\1>/gi;
  const headingMatches = [...working.matchAll(headingRe)];
  if (headingMatches.length > 0) {
    let cursor = 0;
    for (const m of headingMatches) {
      const start = m.index ?? 0;
      const before = working.slice(cursor, start).trim();
      if (before.length > 0) {
        appendHTMLContainerBlocks(before, alignment, urlContext, result, state);
      }
      const level = Number.parseInt(m[1], 10) || 2;
      const extractedAlign = extractAlignment(m[0]);
      const headingAlign = extractedAlign === 'leading' ? alignment : extractedAlign;
      const text = convertInlineHTMLToMarkdown(m[2], urlContext).trim();
      if (text.length > 0) {
        result.push({
          type: 'heading',
          id: allocID(state),
          level,
          text,
          slug: allocHeadingSlug(text, state),
          alignment: headingAlign,
        });
      }
      cursor = start + m[0].length;
    }
    const tail = working.slice(cursor).trim();
    if (tail.length > 0) {
      appendHTMLContainerBlocks(tail, alignment, urlContext, result, state);
    }
    return;
  }

  const imgRe = /(?:<a\b[^>]*href\s*=\s*["']([^"']+)["'][^>]*>\s*(<img\b[^>]*>)\s*<\/a>)|(<img\b[^>]*>)/gi;
  const images: MarkdownImageItem[] = [];
  const remainder = working.replace(imgRe, (_full, linkHref: string | undefined, linkedImg: string | undefined, plainImg: string | undefined) => {
    const imgTag = linkedImg ?? plainImg;
    if (!imgTag) return '';
    const parsed = parseHTMLImageTag(imgTag, linkHref ?? null, urlContext, allocID(state));
    if (parsed) images.push(parsed);
    return '';
  });

  if (images.length === 1) {
    result.push({ type: 'image', id: allocID(state), item: images[0], alignment });
  } else if (images.length > 1) {
    result.push({ type: 'imageRow', id: allocID(state), items: images, alignment });
  }

  const text = convertInlineHTMLToMarkdown(remainder, urlContext).trim();
  if (text.length > 0) {
    result.push({ type: 'paragraph', id: allocID(state), text, alignment });
  }
}

function parseHTMLImageTag(
  tag: string,
  linkHref: string | null,
  urlContext: MarkdownURLContext,
  id: number,
): MarkdownImageItem | null {
  const rawSrc = extractHTMLAttribute('src', tag);
  if (!rawSrc) return null;
  const url = resolveMarkdownAssetURL(decodeMarkdownHTMLEntities(rawSrc), urlContext);
  const altRaw = extractHTMLAttribute('alt', tag);
  const alt = altRaw ? decodeMarkdownHTMLEntities(altRaw) : '';
  const widthRaw = extractHTMLAttribute('width', tag);
  const heightRaw = extractHTMLAttribute('height', tag);
  const width = widthRaw ? parseNumericDimension(widthRaw) : null;
  const height = heightRaw ? parseNumericDimension(heightRaw) : null;
  const linkURL = linkHref
    ? resolveMarkdownLinkURL(decodeMarkdownHTMLEntities(linkHref), urlContext)
    : null;
  return { id, url, alt, width, height, linkURL };
}

function parseNumericDimension(raw: string): number | null {
  const trimmed = raw.trim().toLowerCase();
  if (trimmed.endsWith('%')) return null;
  const cleaned = trimmed.replace(/px$/i, '');
  const val = Number.parseFloat(cleaned);
  if (!Number.isFinite(val) || val <= 0 || val > 2000) return null;
  return val;
}

function extractHTMLAttribute(name: string, tag: string): string | null {
  const dbl = new RegExp(`\\b${name}\\s*=\\s*"([^"]*)"`, 'i').exec(tag);
  if (dbl) return dbl[1];
  const sgl = new RegExp(`\\b${name}\\s*=\\s*'([^']*)'`, 'i').exec(tag);
  if (sgl) return sgl[1];
  const bare = new RegExp(`\\b${name}\\s*=\\s*([^\\s>/]+)`, 'i').exec(tag);
  if (bare) return bare[1];
  return null;
}

function parseStandaloneMarkdownImages(
  trimmed: string,
  urlContext: MarkdownURLContext,
  state: ParseState,
): MarkdownImageItem[] | null {
  const pattern =
    /(?:\[!\[([^\]]*)\]\(([^)\s]+)(?:\s+"[^"]*")?\)\]\(([^)\s]+)\))|(?:!\[([^\]]*)\]\(([^)\s]+)(?:\s+"[^"]*")?\))/g;
  const matches = [...trimmed.matchAll(pattern)];
  if (matches.length === 0) return null;

  const residual = trimmed.replace(pattern, '').trim();
  if (residual.length > 0) return null;

  const items: MarkdownImageItem[] = [];
  for (const m of matches) {
    if (m[2] && m[3]) {
      items.push({
        id: allocID(state),
        url: resolveMarkdownAssetURL(m[2], urlContext),
        alt: m[1] ?? '',
        linkURL: resolveMarkdownLinkURL(m[3], urlContext),
      });
    } else if (m[5]) {
      items.push({
        id: allocID(state),
        url: resolveMarkdownAssetURL(m[5], urlContext),
        alt: m[4] ?? '',
      });
    }
  }
  return items.length > 0 ? items : null;
}

function looksLikeTableRow(trimmed: string): boolean {
  return trimmed.includes('|');
}

function parseTableDelimiterRow(rawLine: string): MarkdownAlignment[] | null {
  const trimmed = rawLine.trim();
  if (!trimmed.includes('|') || !trimmed.includes('-')) return null;
  const cells = splitTableCells(trimmed);
  if (cells.length === 0) return null;
  const alignments: MarkdownAlignment[] = [];
  for (const cell of cells) {
    const c = cell.trim();
    if (!c) return null;
    const leftColon = c.startsWith(':');
    const rightColon = c.endsWith(':');
    const core = c.replace(/^:+|:+$/g, '');
    if (core.length < 2 || !isAllChar(core, '-')) return null;
    if (leftColon && rightColon) alignments.push('center');
    else if (rightColon) alignments.push('trailing');
    else alignments.push('leading');
  }
  return alignments;
}

function splitTableCells(rawLine: string): string[] {
  let s = rawLine.trim();
  if (s.startsWith('|')) s = s.slice(1);
  if (s.endsWith('|') && !s.endsWith('\\|')) s = s.slice(0, -1);

  const cells: string[] = [];
  let current = '';
  let escaped = false;
  for (let idx = 0; idx < s.length; idx++) {
    const ch = s[idx];
    if (escaped) {
      current += ch;
      escaped = false;
    } else if (ch === '\\') {
      escaped = true;
    } else if (ch === '|') {
      cells.push(current.trim());
      current = '';
    } else {
      current += ch;
    }
  }
  cells.push(current.trim());
  return cells;
}

function padCells(cells: readonly string[], count: number): string[] {
  if (cells.length >= count) return cells.slice(0, count);
  return [...cells, ...Array<string>(count - cells.length).fill('')];
}

interface ParsedListItem {
  marker: MarkdownListMarker;
  indent: number;
  content: string;
}

function parseListItem(rawLine: string): ParsedListItem | null {
  let leadSpaces = 0;
  let leadLen = 0;
  while (leadLen < rawLine.length && (rawLine[leadLen] === ' ' || rawLine[leadLen] === '\t')) {
    leadSpaces += rawLine[leadLen] === '\t' ? 2 : 1;
    leadLen += 1;
  }
  const indent = Math.min(4, Math.floor(leadSpaces / 2));
  const rest = rawLine.slice(leadLen);

  if (
    rest.startsWith('- [x] ') ||
    rest.startsWith('- [X] ') ||
    rest.startsWith('* [x] ') ||
    rest.startsWith('* [X] ')
  ) {
    return { marker: { type: 'task', checked: true }, indent, content: rest.slice(6) };
  }
  if (rest.startsWith('- [ ] ') || rest.startsWith('* [ ] ')) {
    return { marker: { type: 'task', checked: false }, indent, content: rest.slice(6) };
  }
  if (rest.startsWith('- ') || rest.startsWith('* ') || rest.startsWith('+ ')) {
    return { marker: { type: 'bullet' }, indent, content: rest.slice(2) };
  }
  const ordered = /^(\d{1,4})\.\s+(.*)$/.exec(rest);
  if (ordered) {
    return {
      marker: { type: 'ordered', index: Number.parseInt(ordered[1], 10) },
      indent,
      content: ordered[2],
    };
  }
  return null;
}

export function convertInlineHTMLToMarkdown(
  input: string,
  urlContext: MarkdownURLContext = {},
): string {
  let s = input;

  // <br> -> newline
  s = s.replace(/<br\s*\/?>/gi, '\n');

  // <a href="...">label</a> -> [label](resolvedURL)
  s = s.replace(
    /<a\b[^>]*href\s*=\s*["']([^"']+)["'][^>]*>([\s\S]*?)<\/a>/gi,
    (_full, rawHref: string, rawLabel: string) => {
      const href = resolveMarkdownLinkURL(decodeMarkdownHTMLEntities(rawHref), urlContext);
      const label = stripAllHTMLTags(rawLabel.trim()).replace(/\n+/g, ' ').trim();
      return label.length === 0 ? href : `[${label}](${href})`;
    },
  );

  s = replaceTagWrapping(s, ['strong', 'b'], '**', '**');
  s = replaceTagWrapping(s, ['em', 'i'], '*', '*');
  s = replaceTagWrapping(s, ['code', 'kbd'], '`', '`');
  s = replaceTagWrapping(s, ['del', 's'], '~~', '~~');

  // Resolve inline Markdown images `![alt](src)`
  s = s.replace(/!\[([^\]]*)\]\(([^)\s]+)\)/g, (_full, alt: string, rawSrc: string) => {
    const resolved = resolveMarkdownAssetURL(rawSrc, urlContext);
    return `![${alt}](${resolved})`;
  });

  // Resolve relative Markdown links `[label](href)` (not preceded by `!`)
  s = s.replace(/(^|[^!])\[([^\]]+)\]\(([^)\s]+)\)/g, (_full, lead: string, label: string, rawHref: string) => {
    const resolved = resolveMarkdownLinkURL(rawHref, urlContext);
    return `${lead}[${label}](${resolved})`;
  });

  s = stripRemainingNonCodeHTMLTags(s);
  s = decodeMarkdownHTMLEntities(s);

  return s
    .split('\n')
    .map((line) => line.trim())
    .join('\n');
}

function replaceTagWrapping(
  input: string,
  tags: readonly string[],
  prefix: string,
  suffix: string,
): string {
  let s = input;
  for (const tag of tags) {
    const re = new RegExp(`<${tag}\\b[^>]*>([\\s\\S]*?)<\\/${tag}>`, 'gi');
    s = s.replace(re, (_full, inner: string) => {
      const trimmed = inner.trim();
      return trimmed.length === 0 ? '' : `${prefix}${trimmed}${suffix}`;
    });
  }
  return s;
}

function stripAllHTMLTags(input: string): string {
  return input.replace(/<\/?[a-zA-Z][^>]*>/g, '');
}

function stripRemainingNonCodeHTMLTags(input: string): string {
  const parts = input.split('`');
  if (parts.length < 3) return stripAllHTMLTags(input);
  return parts.map((segment, idx) => (idx % 2 === 0 ? stripAllHTMLTags(segment) : segment)).join('`');
}

const NAMED_HTML_ENTITIES: ReadonlyArray<readonly [string, string]> = [
  ['&amp;', '&'],
  ['&lt;', '<'],
  ['&gt;', '>'],
  ['&quot;', '"'],
  ['&#39;', "'"],
  ['&apos;', "'"],
  ['&nbsp;', ' '],
  ['&middot;', '·'],
  ['&bull;', '•'],
  ['&mdash;', '—'],
  ['&ndash;', '–'],
  ['&hellip;', '…'],
  ['&copy;', '©'],
  ['&rarr;', '→'],
  ['&larr;', '←'],
];

export function decodeMarkdownHTMLEntities(input: string): string {
  if (!input.includes('&')) return input;
  let s = input;
  for (const [entity, replacement] of NAMED_HTML_ENTITIES) {
    if (s.includes(entity)) {
      s = s.split(entity).join(replacement);
    }
  }
  s = s.replace(/&#(x?[0-9a-fA-F]+);/g, (full, token: string) => {
    const codePoint =
      token.startsWith('x') || token.startsWith('X')
        ? Number.parseInt(token.slice(1), 16)
        : Number.parseInt(token, 10);
    if (!Number.isFinite(codePoint) || codePoint < 0 || codePoint > 0x10ffff) {
      return full;
    }
    try {
      return String.fromCodePoint(codePoint);
    } catch {
      return full;
    }
  });
  return s;
}

export const MarkdownDocumentParser = {
  parse: parseMarkdownBlocks,
  parseDocument: parseMarkdownDocument,
  extractFrontmatter: extractMarkdownFrontmatter,
  extractToc: extractMarkdownToc,
  detectCallout: detectMarkdownCallout,
  slugifyHeading: slugifyMarkdownHeading,
  githubURLContext: createGitHubMarkdownURLContext,
  resolveAssetURL: resolveMarkdownAssetURL,
  resolveLinkURL: resolveMarkdownLinkURL,
  rewriteGitHubBlobToRawURL,
  convertInlineHTMLToMarkdown,
  decodeHTMLEntities: decodeMarkdownHTMLEntities,
} as const;
