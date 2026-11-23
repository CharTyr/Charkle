import { deltaE76, labFromHex } from '../color/lab.js';
import type { AssetRecord, SmartFolderRule } from '../models/core.js';

/**
 * Returns true if the smart folder rule specifies at least one active condition.
 * Exact port of Swift `SmartFolderRule.hasAnyCondition`.
 */
export function smartFolderRuleHasAnyCondition(rule: SmartFolderRule): boolean {
  return (
    rule.tags.length > 0 ||
    rule.descriptionQuery.trim().length > 0 ||
    rule.colorHexes.length > 0 ||
    rule.mediaKinds.length > 0 ||
    rule.minRating > 0
  );
}

/**
 * Evaluates whether a non-trashed asset satisfies this smart folder rule.
 * Exact 1:1 port of Swift `SmartFolderRule.matches(_ asset:)` (CoreModels.swift).
 */
export function matchesSmartFolderRule(rule: SmartFolderRule, asset: AssetRecord): boolean {
  if (asset.isTrashed) return false;

  const checks: boolean[] = [];

  const cleanTags = rule.tags
    .map((t) => t.trim().toLowerCase())
    .filter((t) => t.length > 0);
  if (cleanTags.length > 0) {
    const assetTags = new Set(asset.tags.map((t) => t.trim().toLowerCase()));
    const matched =
      rule.matchMode === 'all'
        ? cleanTags.every((t) => assetTags.has(t))
        : cleanTags.some((t) => assetTags.has(t));
    checks.push(matched);
  }

  const query = rule.descriptionQuery.trim().toLowerCase();
  if (query.length > 0) {
    const tokens = query.split(/\s+/).filter((t) => t.length > 0);
    const haystack = [
      asset.title,
      asset.notes,
      asset.aiDescription ?? '',
      asset.ocrText ?? '',
      asset.richMetadata?.githubRepo?.fullName ?? '',
      asset.richMetadata?.githubRepo?.description ?? '',
      asset.richMetadata?.socialPost?.authorName ?? '',
      asset.richMetadata?.socialPost?.bodyText ?? '',
    ]
      .join('\n')
      .toLowerCase();
    const matched = tokens.every((token) => haystack.includes(token));
    checks.push(matched);
  }

  const cleanColors = rule.colorHexes
    .map((c) => c.trim())
    .filter((c) => c.length > 0);
  if (cleanColors.length > 0) {
    const targetLabs = cleanColors.map((hex) => labFromHex(hex));
    const tolerance = Math.max(4.0, rule.colorTolerance);
    const matched =
      asset.dominantColors.length > 0 &&
      targetLabs.some((target) =>
        asset.dominantColors.some((dc) => deltaE76(dc, target) <= tolerance),
      );
    checks.push(matched);
  }

  if (rule.mediaKinds.length > 0) {
    checks.push(rule.mediaKinds.includes(asset.mediaKind));
  }

  if (rule.minRating > 0) {
    checks.push(asset.rating >= rule.minRating);
  }

  if (checks.length === 0) return false;
  return rule.matchMode === 'all' ? checks.every(Boolean) : checks.some(Boolean);
}

/**
 * Filter an array of assets by a `SmartFolderRule`.
 */
export function filterAssetsBySmartFolderRule(
  rule: SmartFolderRule,
  assets: readonly AssetRecord[],
): AssetRecord[] {
  return assets.filter((asset) => matchesSmartFolderRule(rule, asset));
}

export const SmartFolderRuleEvaluator = {
  hasAnyCondition: smartFolderRuleHasAnyCondition,
  matches: matchesSmartFolderRule,
  filter: filterAssetsBySmartFolderRule,
} as const;
