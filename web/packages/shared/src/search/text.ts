import { pinyin } from 'pinyin-pro';

/**
 * CJK + Pinyin + Latin search tokenization, FTS5 query builder, and fuzzy scoring.
 * Port of Swift `SearchText` (SearchText.swift) backed by `pinyin-pro`.
 */
const LETTER_OR_NUMBER_RE = /[\p{L}\p{N}]/u;

export function hasHan(char: string): boolean {
  const code = char.codePointAt(0);
  if (code === undefined) return false;
  return (code >= 0x3400 && code <= 0x9fff) || (code >= 0x20000 && code <= 0x323af);
}

export function normalizeSearchText(text: string): string {
  return text
    .normalize('NFKD')
    .replace(/[\u0300-\u036f]/g, '')
    .toLowerCase()
    .trim();
}

export function tokenizeSearchText(text: string): string[] {
  const tokens: string[] = [];
  let word = '';
  for (const ch of text) {
    if (hasHan(ch) || !LETTER_OR_NUMBER_RE.test(ch)) {
      if (word.length > 0) {
        tokens.push(word);
        word = '';
      }
      if (hasHan(ch)) {
        tokens.push(ch);
      }
    } else {
      word += ch;
    }
  }
  if (word.length > 0) {
    tokens.push(word);
  }
  return tokens;
}

export function extractPinyin(text: string): { full: string; initials: string } {
  const fullParts: string[] = [];
  const initialParts: string[] = [];

  // Split into contiguous Han phrases
  let phrase = '';
  const phrases: string[] = [];
  for (const ch of text) {
    if (hasHan(ch)) {
      phrase += ch;
    } else if (phrase.length > 0) {
      phrases.push(phrase);
      phrase = '';
    }
  }
  if (phrase.length > 0) phrases.push(phrase);

  for (const p of phrases) {
    const syllables = pinyin(p, { toneType: 'none', type: 'array' })
      .map((s) => normalizeSearchText(s))
      .filter((s) => s.length > 0);
    if (syllables.length === 0) continue;
    fullParts.push(syllables.join(' '), syllables.join(''));
    initialParts.push(syllables.map((s) => s[0]).join(''));
  }

  return {
    full: fullParts.join(' '),
    initials: initialParts.join(' '),
  };
}

export function indexSearchText(text: string): string {
  return tokenizeSearchText(text).join(' ');
}

/**
 * Build a safe SQLite FTS5 MATCH expression supporting mixed Han phrases and Latin prefixes.
 */
export function buildFtsQuery(text: string): string {
  const clauses: string[] = [];
  const chunks: string[] = [];
  let current = '';

  for (const ch of text) {
    if (LETTER_OR_NUMBER_RE.test(ch) || hasHan(ch)) {
      current += ch;
    } else if (current.length > 0) {
      chunks.push(current);
      current = '';
    }
  }
  if (current.length > 0) chunks.push(current);

  for (const chunk of chunks) {
    let han: string[] = [];
    for (const token of tokenizeSearchText(chunk)) {
      const chars = Array.from(token);
      if (chars.length === 1 && hasHan(chars[0])) {
        han.push(token);
      } else {
        if (han.length > 0) {
          clauses.push(`"${han.join(' ')}"`);
          han = [];
        }
        const safe = token.replace(/"/g, '');
        if (safe.length > 0) {
          clauses.push(`"${safe}"*`);
        }
      }
    }
    if (han.length > 0) {
      clauses.push(`"${han.join(' ')}"`);
    }
  }

  return clauses.join(' AND ');
}

/**
 * Fuzzy score in `[0.65, 1.0]` matching exact, prefix, substring, full pinyin, or pinyin initials.
 * Returns `null` when candidate does not match query (returns `0.4` on empty query, matching Swift).
 */
export function fuzzyScoreSearchText(query: string, candidate: string): number | null {
  const needle = normalizeSearchText(query);
  if (needle.length === 0) return 0.4;

  const text = normalizeSearchText(candidate);
  if (text === needle) return 1.0;
  if (text.startsWith(needle)) return 0.9;
  if (text.includes(needle)) return 0.8;

  const phonetics = extractPinyin(candidate);
  const full = normalizeSearchText(phonetics.full);
  if (full.includes(needle)) return 0.75;
  if (phonetics.initials.includes(needle)) return 0.65;
  return null;
}

export const SearchText = {
  hasHan,
  normalize: normalizeSearchText,
  tokenize: tokenizeSearchText,
  pinyin: extractPinyin,
  index: indexSearchText,
  ftsQuery: buildFtsQuery,
  fuzzyScore: fuzzyScoreSearchText,
} as const;
