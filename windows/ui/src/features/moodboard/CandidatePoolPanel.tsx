import React, { useMemo, useState } from 'react';
import { ArrowLeftRight, Plus, RefreshCw, Sparkles } from 'lucide-react';
import { getTransport } from '../../api/transport';
import { Button } from '../../design-system';
import { useLibraryStore, useMoodboardStore } from '../../stores';
import { isAutoEditorialMode, type ScoredAsset } from '../../types/domain';

export const CANDIDATE_DRAG_MIME = 'application/x-charkle-candidate-asset-id';

/**
 * Collapsible right Candidate Replacement Pool (M4-R3):
 * Displays 20–40 ranked alternative assets with 1-click in-place swap (preserving layout slot),
 * drag-onto-canvas addition, and iterative natural-language refinement.
 */
export const CandidatePoolPanel: React.FC = () => {
  const activeBoard = useMoodboardStore((s) => s.activeBoard);
  const selectedNodeIds = useMoodboardStore((s) => s.selectedNodeIds);
  const candidatePool = useMoodboardStore((s) => s.candidatePool);
  const curating = useMoodboardStore((s) => s.curating);
  const swapNodeAsset = useMoodboardStore((s) => s.swapNodeAsset);
  const addAssetNodeAt = useMoodboardStore((s) => s.addAssetNodeAt);
  const curateMoodboard = useMoodboardStore((s) => s.curateMoodboard);

  const libraryAssets = useLibraryStore((s) => s.assets);
  const [refineText, setRefineText] = useState('');

  const transport = getTransport();

  const selectedAssetNodeId = useMemo(() => {
    if (!activeBoard || selectedNodeIds.length !== 1) return null;
    const node = activeBoard.nodes.find((n) => n.id === selectedNodeIds[0]);
    return node && 'assetRef' in node.kind ? node.id : null;
  }, [activeBoard, selectedNodeIds]);

  const displayedCandidates = useMemo<ScoredAsset[]>(() => {
    if (!activeBoard) return [];
    const onBoardIds = new Set(
      activeBoard.nodes
        .map((n) => ('assetRef' in n.kind ? n.kind.assetRef.assetID : null))
        .filter((x): x is string => Boolean(x)),
    );

    if (candidatePool.length > 0) {
      const fresh = candidatePool.filter((c) => !onBoardIds.has(c.asset.id));
      if (fresh.length > 0) return fresh;
    }

    const byId = new Map(libraryAssets.map((a) => [a.id, a]));
    const fromIds = activeBoard.candidateAssetIDs
      .filter((id) => !onBoardIds.has(id))
      .map((id) => byId.get(id))
      .filter((a): a is NonNullable<typeof a> => Boolean(a))
      .map((asset) => ({ asset, score: 0.8, matchReasons: ['板内候选池'] }));

    if (fromIds.length > 0) return fromIds;

    return libraryAssets
      .filter((a) => !a.isTrashed && !onBoardIds.has(a.id))
      .slice(0, 24)
      .map((asset) => ({ asset, score: 0.65, matchReasons: ['素材库补充'] }));
  }, [activeBoard, candidatePool, libraryAssets]);

  if (!activeBoard) return null;

  const handleRefine = async (e: React.FormEvent) => {
    e.preventDefault();
    const instruction = refineText.trim();
    if (!instruction) return;
    const lockedAssetIds = activeBoard.nodes
      .filter((n) => n.isLocked && 'assetRef' in n.kind)
      .map((n) => ('assetRef' in n.kind ? n.kind.assetRef.assetID : ''))
      .filter(Boolean);

    await curateMoodboard({
      prompt: activeBoard.title,
      seedAssetIDs: [],
      scopeFolderIDs: [],
      requiredTags: [],
      targetPalette: activeBoard.extractedPalette,
      colorTolerance: 28,
      preferredCount: Math.max(
        6,
        activeBoard.nodes.filter((n) => 'assetRef' in n.kind).length,
      ),
      candidateCount: 28,
      layoutStyle: isAutoEditorialMode(activeBoard.mode)
        ? activeBoard.mode.autoEditorial._0.style
        : 'magazine',
      useFreeformLayout: !isAutoEditorialMode(activeBoard.mode),
      includeCuratorNotes: false,
      excludedAssetIDs: [],
      lockedAssetIDs: lockedAssetIds,
      existingBoard: activeBoard,
      refinementInstruction: instruction,
      autoFocusDetailCrop: false,
    });
    setRefineText('');
  };

  return (
    <aside
      data-testid="candidate-pool-panel"
      aria-label="候选替换池"
      className="w-[276px] shrink-0 h-full bg-[var(--bg-inspector)] border-l border-[var(--border-hairline)] flex flex-col overflow-hidden"
    >
      <div className="px-3.5 py-3 border-b border-[var(--border-hairline)] flex flex-col gap-2">
        <div className="flex items-center justify-between">
          <div className="flex items-center gap-1.5 text-[12.5px] font-semibold text-[var(--text-primary)]">
            <Sparkles size={13.5} className="text-[var(--accent)]" />
            <span>候选替换池</span>
          </div>
          <span className="text-[11px] text-[var(--text-tertiary)] charkle-tabular">
            {displayedCandidates.length} 项
          </span>
        </div>
        <p className="text-[11px] text-[var(--text-tertiary)] leading-snug">
          {selectedAssetNodeId
            ? '已选中画布图片：点击任意候选即可原地替换并保留原构图槽位'
            : '选中画布中的图片即可一键替换，或点击 + / 拖入画布添加'}
        </p>

        <form onSubmit={(e) => void handleRefine(e)} className="flex items-center gap-1.5 pt-0.5">
          <input
            type="text"
            value={refineText}
            onChange={(e) => setRefineText(e.target.value)}
            placeholder="继续微调方向（保留锁定项）…"
            className="flex-1 min-w-0 h-7 px-2 rounded-[var(--radius-card-inner)] bg-[var(--bg-inspector-field)] border border-[var(--border-hairline)] text-[11.5px] text-[var(--text-primary)] outline-none focus:border-[var(--accent)]"
          />
          <Button type="submit" variant="secondary" size="xs" loading={curating} className="h-7 px-2">
            <RefreshCw size={12} />
          </Button>
        </form>
      </div>

      <div className="flex-1 min-h-0 overflow-y-auto charkle-scroll p-2.5 grid grid-cols-2 gap-2 content-start">
        {displayedCandidates.length === 0 ? (
          <div className="col-span-2 py-10 text-center text-[12px] text-[var(--text-tertiary)]">
            当前暂无更多候选素材
          </div>
        ) : (
          displayedCandidates.map((item) => (
            <div
              key={item.asset.id}
              draggable
              onDragStart={(e) => {
                e.dataTransfer.setData(CANDIDATE_DRAG_MIME, item.asset.id);
                e.dataTransfer.effectAllowed = 'copy';
              }}
              className="group relative rounded-[var(--radius-settings-inner)] overflow-hidden bg-[var(--bg-elevated)] border border-[var(--border-hairline)] hover:border-[var(--accent)] flex flex-col"
            >
              <div className="aspect-[4/3] bg-[var(--bg-subtle)] overflow-hidden relative">
                <img
                  src={transport.thumbnailUrl(item.asset.id, 'grid520')}
                  alt={item.asset.title}
                  loading="lazy"
                  draggable={false}
                  className="w-full h-full object-cover"
                />
                <div className="absolute inset-x-1.5 bottom-1.5 flex items-center gap-1 opacity-0 group-hover:opacity-100 transition-opacity">
                  {selectedAssetNodeId && (
                    <button
                      type="button"
                      onClick={() => swapNodeAsset(selectedAssetNodeId, item.asset.id)}
                      className="charkle-pressable flex-1 h-6 px-1.5 rounded-[6px] bg-[var(--accent)] text-white text-[10.5px] font-medium inline-flex items-center justify-center gap-1 cursor-pointer"
                    >
                      <ArrowLeftRight size={10.5} />
                      替换
                    </button>
                  )}
                  <button
                    type="button"
                    aria-label={`添加 ${item.asset.title} 到画布`}
                    onClick={() => addAssetNodeAt(item.asset.id)}
                    className="charkle-pressable h-6 px-1.5 rounded-[6px] bg-black/75 text-white text-[10.5px] inline-flex items-center justify-center gap-0.5 cursor-pointer"
                  >
                    <Plus size={11} />
                    添加
                  </button>
                </div>
              </div>
              <div className="px-2 py-1.5">
                <div className="text-[11px] font-medium text-[var(--text-primary)] truncate">
                  {item.asset.title}
                </div>
                {item.matchReasons[0] && (
                  <div className="text-[10px] text-[var(--text-tertiary)] truncate">
                    {item.matchReasons[0]}
                  </div>
                )}
              </div>
            </div>
          ))
        )}
      </div>
    </aside>
  );
};
