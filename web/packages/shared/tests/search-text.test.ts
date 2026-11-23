import { describe, expect, it } from 'vitest';
import {
  SearchText,
  buildFtsQuery,
  extractPinyin,
  fuzzyScoreSearchText,
  hasHan,
  tokenizeSearchText,
} from '../src/search/text.js';

describe('SearchText (CJK + Pinyin + FTS5)', () => {
  it('detects Han characters and tokenizes mixed CJK/Latin text', () => {
    expect(hasHan('插')).toBe(true);
    expect(hasHan('A')).toBe(false);
    expect(tokenizeSearchText('夏日Poster 2026!')).toEqual(['夏', '日', 'Poster', '2026']);
  });

  it('extracts pinyin full and initials and computes fuzzy scores', () => {
    const py = extractPinyin('情绪板设计');
    expect(py.full).toContain('qingxubansheji');
    expect(py.initials).toContain('qxbsj');

    expect(fuzzyScoreSearchText('海报', '海报')).toBe(1.0);
    expect(fuzzyScoreSearchText('海', '海报参考')).toBe(0.9);
    expect(fuzzyScoreSearchText('参考', '海报参考')).toBe(0.8);
    expect(fuzzyScoreSearchText('haibao', '海报参考')).toBe(0.75);
    expect(fuzzyScoreSearchText('hbck', '海报参考')).toBe(0.65);
    expect(fuzzyScoreSearchText('xyz', '海报参考')).toBeNull();
    expect(fuzzyScoreSearchText('', 'anything')).toBe(0.4);
  });

  it('builds safe FTS5 queries for Han phrases and Latin prefixes', () => {
    expect(buildFtsQuery('蓝天 poster')).toBe('"蓝 天" AND "poster"*');
    expect(SearchText.index('排版Design')).toBe('排 版 Design');
  });
});
