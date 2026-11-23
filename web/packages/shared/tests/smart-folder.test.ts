import { describe, expect, it } from 'vitest';
import { labFromHex } from '../src/color/lab.js';
import { createDefaultAssetRecord, createDefaultSmartFolderRule } from '../src/models/core.js';
import {
  filterAssetsBySmartFolderRule,
  matchesSmartFolderRule,
  smartFolderRuleHasAnyCondition,
} from '../src/rules/smart-folder.js';

describe('SmartFolderRule evaluator', () => {
  const blueSkyArt = createDefaultAssetRecord({
    id: '11111111-1111-4111-8111-111111111111',
    title: '夏日海滩插画',
    fileName: 'beach.png',
    mediaKind: 'image',
    notes: '清透海风与蓝天白云',
    tags: ['插画', '夏日'],
    dominantColors: [labFromHex('#3B82F6')],
    rating: 4,
  });

  const darkModel = createDefaultAssetRecord({
    id: '22222222-2222-4222-8222-222222222222',
    title: 'Cyber Helmet',
    fileName: 'helmet.usdz',
    mediaKind: 'model3D',
    tags: ['科幻'],
    dominantColors: [labFromHex('#18181B')],
    rating: 5,
  });

  const trashedBlue = createDefaultAssetRecord({
    ...blueSkyArt,
    id: '33333333-3333-4333-8333-333333333333',
    isTrashed: true,
  });

  it('matches strict ALL rules across tags, description keywords, CIELAB colors, media kinds, and minRating', () => {
    const strictRule = createDefaultSmartFolderRule({
      matchMode: 'all',
      tags: ['夏日'],
      descriptionQuery: '海滩 蓝天',
      colorHexes: ['#2563EB'],
      colorTolerance: 24,
      mediaKinds: ['image'],
      minRating: 3,
    });

    expect(smartFolderRuleHasAnyCondition(strictRule)).toBe(true);
    expect(matchesSmartFolderRule(strictRule, blueSkyArt)).toBe(true);
    expect(matchesSmartFolderRule(strictRule, darkModel)).toBe(false);
    expect(matchesSmartFolderRule(strictRule, trashedBlue)).toBe(false);
  });

  it('matches ANY rules and filters asset collections', () => {
    const anyRule = createDefaultSmartFolderRule({
      matchMode: 'any',
      tags: ['插画'],
      mediaKinds: ['model3D'],
    });

    expect(matchesSmartFolderRule(anyRule, blueSkyArt)).toBe(true);
    expect(matchesSmartFolderRule(anyRule, darkModel)).toBe(true);
    expect(filterAssetsBySmartFolderRule(anyRule, [blueSkyArt, darkModel, trashedBlue])).toEqual([
      blueSkyArt,
      darkModel,
    ]);
  });

  it('searches across rich metadata (GitHub repo & Social post) and rejects empty rules', () => {
    const emptyRule = createDefaultSmartFolderRule();
    expect(smartFolderRuleHasAnyCondition(emptyRule)).toBe(false);
    expect(matchesSmartFolderRule(emptyRule, blueSkyArt)).toBe(false);

    const repoAsset = createDefaultAssetRecord({
      id: '44444444-4444-4444-8444-444444444444',
      title: 'Swift Compiler',
      fileName: 'swift.webloc',
      mediaKind: 'webBookmark',
      richMetadata: {
        isMarkdown: false,
        githubRepo: {
          owner: 'apple',
          repo: 'swift',
          fullName: 'apple/swift',
          description: 'The Swift Programming Language',
          stars: 68000,
          forks: 10000,
          topics: ['swift'],
          defaultBranch: 'main',
          fetchedAt: '2026-11-22T00:00:00.000Z',
        },
      },
    });

    const repoRule = createDefaultSmartFolderRule({
      matchMode: 'all',
      descriptionQuery: 'apple/swift programming',
    });
    expect(matchesSmartFolderRule(repoRule, repoAsset)).toBe(true);
  });
});
