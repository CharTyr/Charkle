import { describe, expect, it } from 'vitest';
import {
  createGitHubMarkdownURLContext,
  cropMaxX,
  cropMaxY,
  cropMinX,
  cropMinY,
  customAIEndpointLocalizedLabel,
  externalAgentAccessLevelSummary,
  extractPinyin,
  MarkdownDocumentParser,
  resolveMarkdownAssetURL,
  resolveMarkdownLinkURL,
  rewriteGitHubBlobToRawURL,
  SwiftWireCodec,
  visualRegionSourceLocalizedLabel,
  type SocialPostMetadata,
} from '../src/index.js';

describe('MarkdownDocumentParser (isomorphic parity with MarkdownDocumentParser.swift)', () => {
  it('strips YAML frontmatter, extracts TOC headings with unique slugs, and parses GFM callouts/tables/tasks', () => {
    const md = [
      '---',
      'title: Charkle Design Guide',
      'author: Studio',
      '---',
      '',
      '# Overview',
      '',
      'Intro paragraph with <strong>bold</strong> and `code`.',
      '',
      '## Setup',
      '',
      '> [!TIP]',
      '> Use dark surfaces for reference comparisons.',
      '',
      '> [!WARNING]',
      '> Never overwrite unbacked local originals.',
      '',
      '- [x] Install dependencies',
      '- [ ] Export `.charkleboard`',
      '',
      '| Layer | Runtime |',
      '| :--- | ---: |',
      '| Shared | Isomorphic |',
      '| Worker | Cloudflare |',
      '',
      '```ts',
      'export const ok = true;',
      '```',
      '',
      '## Setup',
      '',
      '![Hero Banner](./docs/hero.png)',
    ].join('\n');

    const doc = MarkdownDocumentParser.parseDocument(md);
    expect(doc.frontmatter.title).toBe('Charkle Design Guide');
    expect(doc.frontmatter.author).toBe('Studio');
    expect(doc.body).not.toContain('title: Charkle Design Guide');

    expect(doc.toc.map((h) => ({ level: h.level, text: h.text, slug: h.slug }))).toEqual([
      { level: 1, text: 'Overview', slug: 'overview' },
      { level: 2, text: 'Setup', slug: 'setup' },
      { level: 2, text: 'Setup', slug: 'setup-1' },
    ]);

    const quotes = doc.blocks.filter((b) => b.type === 'quote');
    expect(quotes).toHaveLength(2);
    expect(quotes[0]).toMatchObject({ type: 'quote', alertKind: 'tip' });
    expect(quotes[1]).toMatchObject({ type: 'quote', alertKind: 'warning' });

    const tasks = doc.blocks.filter((b) => b.type === 'listItem' && b.marker.type === 'task');
    expect(tasks).toHaveLength(2);
    expect(tasks[0]).toMatchObject({
      type: 'listItem',
      marker: { type: 'task', checked: true },
      text: 'Install dependencies',
    });
    expect(tasks[1]).toMatchObject({
      type: 'listItem',
      marker: { type: 'task', checked: false },
      text: 'Export `.charkleboard`',
    });

    const table = doc.blocks.find((b) => b.type === 'table');
    expect(table).toMatchObject({
      type: 'table',
      headers: ['Layer', 'Runtime'],
      alignments: ['leading', 'trailing'],
    });

    const image = doc.blocks.find((b) => b.type === 'image');
    expect(image).toMatchObject({
      type: 'image',
      item: { alt: 'Hero Banner', url: './docs/hero.png' },
    });
  });

  it('resolves GitHub relative image/link URLs and rewrites github.com /blob/ to raw.githubusercontent.com', () => {
    const ctx = createGitHubMarkdownURLContext('acme', 'design-kit', 'main');

    expect(resolveMarkdownAssetURL('./assets/logo.png', ctx)).toBe(
      'https://raw.githubusercontent.com/acme/design-kit/main/assets/logo.png',
    );
    expect(resolveMarkdownAssetURL('/docs/grid.webp', ctx)).toBe(
      'https://raw.githubusercontent.com/acme/design-kit/main/docs/grid.webp',
    );
    expect(
      rewriteGitHubBlobToRawURL('https://github.com/acme/design-kit/blob/main/media/shot.png'),
    ).toBe('https://raw.githubusercontent.com/acme/design-kit/main/media/shot.png');
    expect(resolveMarkdownLinkURL('docs/API.md#auth', ctx)).toBe(
      'https://github.com/acme/design-kit/blob/main/docs/API.md#auth',
    );
    expect(resolveMarkdownLinkURL('#overview', ctx)).toBe(
      'https://github.com/acme/design-kit#overview',
    );
  });
});

describe('Shared P0/P1 helpers & localized copy parity', () => {
  it('computes clamped NormalizedCropRect edge helpers matching Swift MoodboardModels', () => {
    const rect = { x: 0.25, y: 0.4, width: 0.9, height: 0.75 };
    expect(cropMinX(rect)).toBe(0.25);
    expect(cropMinY(rect)).toBe(0.4);
    expect(cropMaxX(rect)).toBe(1.0);
    expect(cropMaxY(rect)).toBe(1.0);
  });

  it('emits word-segmented Pinyin sub-phrase tokens so mid-title pinyin/initials queries match', () => {
    const { full, initials } = extractPinyin('暗黑仪表盘设计');
    expect(full).toContain('anheiyibiaopansheji');
    expect(initials).toContain('ahybpsj');
    // Sub-phrase/suffix tokens allow prefix FTS5 queries for mid-title terms like "仪表盘"
    expect(full.split(' ').some((t) => t.startsWith('yibiaopan'))).toBe(true);
    expect(initials.split(' ').some((t) => t.startsWith('ybp'))).toBe(true);
  });

  it('encodes SocialPostMetadata omitting null keys on Swift wire and decodes back faithfully', () => {
    const post: SocialPostMetadata = {
      platform: 'x',
      postID: '123456',
      postURL: 'https://x.com/studio/status/123456',
      authorName: 'Studio',
      authorHandle: 'studio',
      authorAvatarURL: null,
      bodyText: 'Warm terracotta',
      publishedAt: null,
      attachments: [
        {
          id: 'att-1',
          kind: 'photo',
          url: 'https://pbs.twimg.com/media/a.jpg?name=orig',
          thumbnailURL: null,
        },
      ],
      mediaURLs: ['https://pbs.twimg.com/media/a.jpg?name=orig'],
      mediaThumbnailURLs: [],
      hasVideo: false,
      mediaFetchFailed: false,
      likeCount: 42,
      replyCount: null,
      repostCount: null,
      fetchedAt: '2026-11-23T00:00:00.000Z',
    };
    const wire = SwiftWireCodec.encodeSocialPostMetadata(post);
    expect('authorAvatarURL' in wire).toBe(false);
    expect('publishedAt' in wire).toBe(false);
    expect('replyCount' in wire).toBe(false);
    const firstAtt = (wire.attachments as Array<Record<string, unknown>>)[0];
    expect('thumbnailURL' in firstAtt).toBe(false);

    const decoded = SwiftWireCodec.decodeSocialPostMetadata(wire);
    expect(decoded.authorHandle).toBe('studio');
    expect(decoded.likeCount).toBe(42);
    expect(decoded.attachments[0].id).toBe('att-1');
    expect(decoded.attachments[0].kind).toBe('photo');
  });

  it('matches audited Chinese copy labels in shared models', () => {
    expect(visualRegionSourceLocalizedLabel('appleVisionSaliency')).toBe('本机视觉识别');
    expect(customAIEndpointLocalizedLabel('openAIChatCompletions')).toBe('OpenAI 兼容');
    expect(externalAgentAccessLevelSummary('readOnly')).toBe('仅可查看与搜索，无法修改');
    expect(externalAgentAccessLevelSummary('readWriteOrganize')).toBe(
      '可整理与生成情绪板，不可彻底删除',
    );
  });
});
