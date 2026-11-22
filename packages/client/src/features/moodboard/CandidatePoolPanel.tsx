import React, { useEffect, useMemo, useState } from 'react';
import {
  ArrowLeftRight,
  Plus,
  RefreshCw,
  Search,
  X,
} from 'lucide-react';
import { getBoardReferencedAssetIDs } from '@charkle/shared';
import type { AssetRecord, MoodboardDocument, ScoredAsset, UUID } from '@charkle/shared';
import { thumbnailURL } from '../../api/client';
import { Button } from '../../design-system/Button';
import { CharkleIcon } from '../../design-system/CharkleIcon';

export interface CandidatePoolPanelProps {
  open: boolean;
  document: MoodboardDocument;
  assetsByID: Record<UUID, AssetRecord>;
  allLibraryAssets: AssetRecord[];
  cacheBustVersion: number;
  swappingNodeID: UUID | null;
  candidatePool: ScoredAsset[];
  loadingCandidates: boolean;
  onClose: () => void;
  onCancelSwap: () => void;
  onRefreshCandidates: (seedAssetID: UUID) => void;
  onSwapWithAsset: (nodeID: UUID, newAssetID: UUID) => void;
  onAppendAsset: (assetID: UUID) => void;
}

export const CandidatePoolPanel: React.FC<CandidatePoolPanelProps> = ({
  open,
  document,
  assetsByID,
  allLibraryAssets,
  cacheBustVersion,
  swappingNodeID,
  candidatePool,
  loadingCandidates,
  onClose,
  onCancelSwap,
  onRefreshCandidates,
  onSwapWithAsset,
  onAppendAsset,
}) => {
  const [filterQuery, setFilterQuery] = useState('');

  const boardAssetIDs = useMemo(() => new Set(getBoardReferencedAssetIDs(document)), [document]);

  const swappingAsset = useMemo(() => {
    if (!swappingNodeID) return null;
    const node = document.nodes.find((n) => n.id === swappingNodeID);
    if (!node || node.kind.type !== 'assetRef') return null;
    return assetsByID[node.kind.assetID] ?? null;
  }, [swappingNodeID, document.nodes, assetsByID]);

  // Auto-load initial replacement candidates when opening the drawer if empty
  useEffect(() => {
    if (!open || candidatePool.length > 0 || loadingCandidates) return;
    const firstAssetID = getBoardReferencedAssetIDs(document)[0];
    if (firstAssetID) {
      onRefreshCandidates(firstAssetID);
    }
  }, [open, candidatePool.length, loadingCandidates, document, onRefreshCandidates]);

  // Combine ranked replacement candidates + document.candidateAssetIDs + library fallback (up to 40)
  const displayItems = useMemo<ScoredAsset[]>(() => {
    const seen = new Set<UUID>();
    const list: ScoredAsset[] = [];

    for (const item of candidatePool) {
      if (boardAssetIDs.has(item.asset.id) || seen.has(item.asset.id)) continue;
      seen.add(item.asset.id);
      list.push(item);
    }

    for (const id of document.candidateAssetIDs) {
      if (boardAssetIDs.has(id) || seen.has(id)) continue;
      const asset = assetsByID[id];
      if (!asset || asset.isTrashed) continue;
      seen.add(id);
      list.push({ asset, score: 0.72, matchReasons: ['策展候选池'] });
    }

    // Pad up to 36 from non-trashed library assets so the pool is always immediately usable
    if (list.length < 24) {
      for (const asset of allLibraryAssets) {
        if (list.length >= 36) break;
        if (asset.isTrashed || boardAssetIDs.has(asset.id) || seen.has(asset.id)) continue;
        seen.add(asset.id);
        list.push({ asset, score: 0.45, matchReasons: ['素材库推荐'] });
      }
    }

    const q = filterQuery.trim().toLowerCase();
    const filtered = q
      ? list.filter(
          (item) =>
            item.asset.title.toLowerCase().includes(q) ||
            item.asset.tags.some((t) => t.toLowerCase().includes(q)) ||
            item.matchReasons.some((r) => r.toLowerCase().includes(q)),
        )
      : list;

    return filtered.slice(0, 40);
  }, [candidatePool, document.candidateAssetIDs, assetsByID, allLibraryAssets, boardAssetIDs, filterQuery]);

  if (!open) return null;

  const refreshSeedID =
    swappingAsset?.id ?? getBoardReferencedAssetIDs(document)[0] ?? allLibraryAssets[0]?.id;

  return (
    <aside
      aria-label="候选替换素材池"
      className="w-[300px] shrink-0 h-full border-l border-[var(--border-hairline)] bg-[var(--bg-inspector)] flex flex-col select-none"
    >
      {/* Header */}
      <div className="px-3.5 py-3 border-b border-[var(--border-hairline)] flex items-center justify-between gap-2">
        <div className="flex items-center gap-2 min-w-0">
          <CharkleIcon name="swap" size={16} isActive={Boolean(swappingNodeID)} />
          <div className="min-w-0">
            <div className="text-[13px] font-semibold text-[var(--text-primary)] truncate">
              候选素材池
            </div>
            <div className="text-[11px] text-[var(--text-secondary)] truncate">
              {swappingNodeID ? '点击任意卡片原地替换' : `${displayItems.length} 项候选可替换或追加`}
            </div>
          </div>
        </div>
        <div className="flex items-center gap-1 shrink-0">
          {refreshSeedID && (
            <button
              type="button"
              onClick={() => onRefreshCandidates(refreshSeedID)}
              disabled={loadingCandidates}
              title="重新计算匹配候选"
              className="charkle-pressable w-7 h-7 rounded-[var(--radius-chip)] inline-flex items-center justify-center text-[var(--text-secondary)] hover:text-[var(--text-primary)] hover:bg-[var(--bg-subtle)] cursor-pointer disabled:opacity-40"
            >
              <RefreshCw size={13} className={loadingCandidates ? 'animate-spin' : ''} />
            </button>
          )}
          <button
            type="button"
            onClick={onClose}
            aria-label="关闭候选池"
            className="charkle-pressable w-7 h-7 rounded-[var(--radius-chip)] inline-flex items-center justify-center text-[var(--text-secondary)] hover:text-[var(--text-primary)] hover:bg-[var(--bg-subtle)] cursor-pointer"
          >
            <X size={14} />
          </button>
        </div>
      </div>

      {/* Active Swap Target Banner */}
      {swappingNodeID && (
        <div className="mx-3 mt-3 p-2.5 rounded-[var(--radius-settings-inner)] bg-[var(--accent-soft)] border border-[var(--accent-ring)] flex items-center gap-2.5">
          {swappingAsset && (
            <img
              src={thumbnailURL(swappingAsset.id, 'grid520', cacheBustVersion)}
              alt={swappingAsset.title}
              className="w-10 h-10 rounded-[6px] object-cover shrink-0 bg-[var(--bg-subtle)]"
            />
          )}
          <div className="min-w-0 flex-1">
            <div className="text-[11.5px] font-semibold text-[var(--accent)]">
              原地替换模式
            </div>
            <div className="text-[11px] text-[var(--text-secondary)] truncate">
              {swappingAsset?.title ?? '已选画布卡片'}
            </div>
          </div>
          <Button variant="ghost" size="xs" onClick={onCancelSwap}>
            取消
          </Button>
        </div>
      )}

      {/* Search filter */}
      <div className="px-3 pt-3 pb-2">
        <div className="relative flex items-center">
          <Search
            size={13}
            className="absolute left-2.5 text-[var(--text-tertiary)] pointer-events-none"
          />
          <input
            type="search"
            value={filterQuery}
            onChange={(e) => setFilterQuery(e.target.value)}
            placeholder="筛选候选标题或标签…"
            className="w-full h-8 pl-8 pr-2.5 rounded-[var(--radius-settings-inner)] bg-[var(--bg-inspector-field)] border border-[var(--border-hairline)] text-[12px] text-[var(--text-primary)] placeholder:text-[var(--text-tertiary)] outline-none focus:border-[var(--accent)]"
          />
        </div>
      </div>

      {/* Grid */}
      <div className="flex-1 min-h-0 overflow-y-auto charkle-scroll px-3 pb-4">
        {loadingCandidates && displayItems.length === 0 ? (
          <div className="grid grid-cols-2 gap-2 pt-1">
            {Array.from({ length: 8 }).map((_, idx) => (
              <div
                key={idx}
                className="aspect-[4/3] rounded-[var(--radius-settings-inner)] bg-[var(--bg-subtle)] animate-pulse"
              />
            ))}
          </div>
        ) : displayItems.length === 0 ? (
          <div className="py-12 text-center text-[12px] text-[var(--text-secondary)]">
            暂无可替换的候选素材
          </div>
        ) : (
          <div className="grid grid-cols-2 gap-2 pt-1">
            {displayItems.map((item) => (
              <div
                key={item.asset.id}
                draggable
                onDragStart={(e) => {
                  e.dataTransfer.setData(
                    'application/x-charkle-asset-ids',
                    JSON.stringify([item.asset.id]),
                  );
                  e.dataTransfer.effectAllowed = 'copy';
                }}
                className="group/cand relative rounded-[var(--radius-settings-inner)] overflow-hidden bg-[var(--bg-elevated)] border border-[var(--border-hairline)] hover:border-[var(--border-strong)]"
              >
                <div className="aspect-[4/3] w-full overflow-hidden bg-[var(--bg-subtle)]">
                  <img
                    src={thumbnailURL(item.asset.id, 'grid520', cacheBustVersion)}
                    alt={item.asset.title}
                    loading="lazy"
                    className="w-full h-full object-cover charkle-media-zoom"
                  />
                </div>

                {/* Hover / Focus quick button */}
                <div className="absolute inset-0 bg-black/0 group-hover/cand:bg-black/32 group-focus-within/cand:bg-black/32 transition-colors duration-150 flex items-center justify-center p-2">
                  {swappingNodeID ? (
                    <button
                      type="button"
                      onClick={() => onSwapWithAsset(swappingNodeID, item.asset.id)}
                      className="charkle-pressable opacity-0 group-hover/cand:opacity-100 group-focus-within/cand:opacity-100 transition-opacity duration-150 inline-flex items-center gap-1 px-2.5 py-1 rounded-full bg-[var(--accent)] text-white text-[11px] font-medium shadow-md cursor-pointer"
                    >
                      <ArrowLeftRight size={11} />
                      替换此图
                    </button>
                  ) : (
                    <button
                      type="button"
                      onClick={() => onAppendAsset(item.asset.id)}
                      className="charkle-pressable opacity-0 group-hover/cand:opacity-100 group-focus-within/cand:opacity-100 transition-opacity duration-150 inline-flex items-center gap-1 px-2.5 py-1 rounded-full bg-[#141517]/88 text-white text-[11px] font-medium shadow-md cursor-pointer"
                    >
                      <Plus size={11} />
                      追加到画布
                    </button>
                  )}
                </div>

                <div className="px-2 py-1.5">
                  <div className="text-[11px] font-medium text-[var(--text-primary)] truncate">
                    {item.asset.title}
                  </div>
                  <div className="text-[10px] text-[var(--text-tertiary)] truncate">
                    {item.matchReasons[0] ?? `${Math.round(item.score * 100)}% 契合`}
                  </div>
                </div>
              </div>
            ))}
          </div>
        )}
      </div>
    </aside>
  );
};
