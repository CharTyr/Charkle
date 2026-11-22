import React, { useEffect, useMemo, useState } from 'react';
import { Check, Sparkles } from 'lucide-react';
import { createDefaultAssetBatchPatch } from '@charkle/shared';
import type { UUID } from '@charkle/shared';
import { apiClient } from '../../api/client';
import {
  Button,
  CharkleFolderIcon,
  CharkleIcon,
  ModalShell,
} from '../../design-system';
import { useCoordinatorStore } from '../../stores/coordinatorStore';
import { useLibraryStore } from '../../stores/libraryStore';
import { useMoodboardStore } from '../../stores/moodboardStore';

export const InboxTriageBar: React.FC = () => {
  const assets = useLibraryStore((s) => s.assets);
  const folders = useLibraryStore((s) => s.folders);
  const selectedAssetIDs = useLibraryStore((s) => s.selectedAssetIDs);
  const inboxSuggestion = useLibraryStore((s) => s.inboxSuggestion);
  const loadInboxSuggestion = useLibraryStore((s) => s.loadInboxSuggestion);
  const batchPatch = useLibraryStore((s) => s.batchPatch);
  const triageRecommendations = useLibraryStore((s) => s.triageRecommendations);
  const isTriaging = useLibraryStore((s) => s.isTriaging);
  const triageModalOpen = useLibraryStore((s) => s.triageModalOpen);
  const runBatchInboxTriage = useLibraryStore((s) => s.runBatchInboxTriage);
  const setTriageModalOpen = useLibraryStore((s) => s.setTriageModalOpen);
  const cacheBust = useLibraryStore((s) => s.cacheBustVersion);

  const boards = useMoodboardStore((s) => s.boards);
  const addAssetsToBoard = useMoodboardStore((s) => s.addAssetsToBoard);

  const activeBoardID = useCoordinatorStore((s) => s.activeBoardID);
  const pushToast = useCoordinatorStore((s) => s.pushToast);

  const [checkedAssetIDs, setCheckedAssetIDs] = useState<Set<UUID>>(new Set());
  const [applyingTriage, setApplyingTriage] = useState(false);

  const targetAssetIDs = useMemo(() => {
    if (selectedAssetIDs.size > 0) return Array.from(selectedAssetIDs);
    return assets.length > 0 ? [assets[0].id] : [];
  }, [selectedAssetIDs, assets]);

  const focusedAssetID = targetAssetIDs[0] ?? null;

  useEffect(() => {
    if (!focusedAssetID) return;
    void loadInboxSuggestion(focusedAssetID);
  }, [focusedAssetID, loadInboxSuggestion]);

  // Auto-check rows with recommendedFolderID != null && confidence >= 0.65 (PARITY_SPEC §6)
  useEffect(() => {
    const auto = new Set<UUID>();
    for (const rec of triageRecommendations) {
      if (rec.recommendedFolderID && rec.confidence >= 0.65) {
        auto.add(rec.assetID);
      }
    }
    setCheckedAssetIDs(auto);
  }, [triageRecommendations]);

  const topNineFolders = useMemo(() => folders.slice(0, 9), [folders]);
  const activeBoard = boards.find((b) => b.id === activeBoardID) ?? boards[0] ?? null;

  if (assets.length === 0) return null;

  const moveTargetToFolder = async (folderID: UUID, folderName: string) => {
    if (targetAssetIDs.length === 0) return;
    const movedIDs = [...targetAssetIDs];
    await batchPatch(
      createDefaultAssetBatchPatch(movedIDs, {
        folderAssignment: { type: 'folder', folderID },
      }),
    );
    pushToast({
      tone: 'success',
      message: `已归档 ${movedIDs.length} 项到「${folderName}」`,
      actionLabel: '撤销',
      onAction: () => {
        void batchPatch(
          createDefaultAssetBatchPatch(movedIDs, { folderAssignment: { type: 'inbox' } }),
        );
      },
    });
  };

  const handleApplyBatchTriage = async () => {
    const chosen = triageRecommendations.filter(
      (r) => checkedAssetIDs.has(r.assetID) && r.recommendedFolderID,
    );
    if (chosen.length === 0) return;
    setApplyingTriage(true);
    try {
      const grouped = new Map<UUID, UUID[]>();
      for (const rec of chosen) {
        if (!rec.recommendedFolderID) continue;
        const list = grouped.get(rec.recommendedFolderID) ?? [];
        list.push(rec.assetID);
        grouped.set(rec.recommendedFolderID, list);
      }
      for (const [folderID, ids] of grouped) {
        await batchPatch(
          createDefaultAssetBatchPatch(ids, {
            folderAssignment: { type: 'folder', folderID },
          }),
        );
      }
      pushToast({
        tone: 'success',
        message: `智能分拣已归档 ${chosen.length} 项素材`,
      });
      setTriageModalOpen(false);
    } finally {
      setApplyingTriage(false);
    }
  };

  return (
    <>
      <div className="mx-5 mb-2 px-3.5 py-2.5 rounded-[var(--radius-settings-outer)] bg-[var(--bg-elevated)] border border-[var(--border-hairline)] flex flex-wrap items-center gap-2">
        <span className="text-[12px] font-semibold text-[var(--text-primary)] mr-1">
          待整理 {assets.length} 项
        </span>

        {/* Single-asset AI Folder Suggestion */}
        {inboxSuggestion && (
          <button
            type="button"
            onClick={() =>
              void moveTargetToFolder(inboxSuggestion.folderID, inboxSuggestion.folderName)
            }
            title={inboxSuggestion.reason}
            className="charkle-pressable inline-flex items-center gap-1.5 px-2.5 py-1 rounded-[var(--radius-chip)] bg-[var(--accent-soft)] text-[var(--accent)] text-[12px] font-medium cursor-pointer"
          >
            <Sparkles size={12} />
            建议移入「{inboxSuggestion.folderName}」
            <span className="opacity-70 text-[11px]">
              {Math.round(inboxSuggestion.confidence * 100)}%
            </span>
          </button>
        )}

        {/* Batch Smart Triage Button */}
        <Button
          variant="secondary"
          size="xs"
          loading={isTriaging}
          onClick={() => void runBatchInboxTriage(undefined, 24)}
        >
          <Sparkles size={12} className="text-[var(--accent)]" />
          批量智能分拣
        </Button>

        {/* Send to Active Board */}
        {activeBoard && (
          <Button
            variant="ghost"
            size="xs"
            onClick={async () => {
              if (targetAssetIDs.length === 0) return;
              await addAssetsToBoard(activeBoard.id, targetAssetIDs);
              pushToast({
                tone: 'success',
                message: `已将 ${targetAssetIDs.length} 项加入「${activeBoard.title}」`,
              });
            }}
          >
            <CharkleIcon name="moodboard" size={14} />
            加入「{activeBoard.title}」
          </Button>
        )}

        {/* Quick 1-9 Folder Archive Chips */}
        {topNineFolders.length > 0 && (
          <div className="w-full flex flex-wrap items-center gap-1.5 pt-1.5 mt-0.5 border-t border-[var(--border-hairline)]">
            <span className="text-[11px] text-[var(--text-tertiary)] mr-1">
              快捷键 1–{topNineFolders.length} 归档：
            </span>
            {topNineFolders.map((folder, index) => (
              <button
                key={folder.id}
                type="button"
                onClick={() => void moveTargetToFolder(folder.id, folder.name)}
                className="charkle-pressable inline-flex items-center gap-1.5 px-2 py-1 rounded-[var(--radius-chip)] bg-[var(--bg-subtle)]/80 hover:bg-[var(--bg-subtle)] text-[12px] text-[var(--text-primary)] cursor-pointer"
              >
                <kbd className="text-[10.5px] font-mono px-1 rounded bg-[var(--bg-elevated)] border border-[var(--border-hairline)] text-[var(--text-secondary)]">
                  {index + 1}
                </kbd>
                <CharkleFolderIcon
                  colorHex={folder.colorHex}
                  customSymbol={folder.customSymbol}
                  size={14}
                />
                <span className="max-w-[110px] truncate">{folder.name}</span>
              </button>
            ))}
          </div>
        )}
      </div>

      {/* Batch Smart Triage Modal */}
      <ModalShell
        open={triageModalOpen}
        onClose={() => setTriageModalOpen(false)}
        width="lg"
        title="收件箱批量智能分拣"
        subtitle="基于 TypeSafe Jev 视觉分类与本地特征推荐目标文件夹，置信度 ≥ 65% 已默认勾选"
        footer={
          <>
            <div className="mr-auto flex items-center gap-2">
              <Button
                variant="ghost"
                size="xs"
                onClick={() => {
                  const all = new Set<UUID>();
                  triageRecommendations.forEach((r) => {
                    if (r.recommendedFolderID) all.add(r.assetID);
                  });
                  setCheckedAssetIDs(all);
                }}
              >
                全选可归档项
              </Button>
              <Button variant="ghost" size="xs" onClick={() => setCheckedAssetIDs(new Set())}>
                全不选
              </Button>
            </div>
            <Button variant="ghost" onClick={() => setTriageModalOpen(false)}>
              取消
            </Button>
            <Button
              variant="primary"
              disabled={checkedAssetIDs.size === 0 || isTriaging}
              loading={applyingTriage}
              onClick={() => void handleApplyBatchTriage()}
            >
              应用已选 ({checkedAssetIDs.size})
            </Button>
          </>
        }
      >
        {isTriaging ? (
          <div className="py-12 flex flex-col items-center gap-3 text-[13px] text-[var(--text-secondary)]">
            <span className="h-6 w-6 rounded-full border-2 border-[var(--accent)] border-t-transparent animate-spin" />
            正在并行分析收件箱素材并匹配最佳文件夹…
          </div>
        ) : triageRecommendations.length === 0 ? (
          <div className="py-10 text-center text-[13px] text-[var(--text-secondary)]">
            暂无可分析的收件箱素材或尚未创建目标文件夹。
          </div>
        ) : (
          <div className="flex flex-col gap-2">
            {triageRecommendations.map((rec) => {
              const canCheck = Boolean(rec.recommendedFolderID);
              const checked = checkedAssetIDs.has(rec.assetID);
              return (
                <div
                  key={rec.assetID}
                  onClick={() => {
                    if (!canCheck) return;
                    setCheckedAssetIDs((prev) => {
                      const next = new Set(prev);
                      if (next.has(rec.assetID)) next.delete(rec.assetID);
                      else next.add(rec.assetID);
                      return next;
                    });
                  }}
                  className={[
                    'flex items-center gap-3 p-2.5 rounded-[var(--radius-settings-inner)] border transition-colors',
                    canCheck ? 'cursor-pointer' : 'opacity-65',
                    checked
                      ? 'bg-[var(--accent-soft)]/50 border-[var(--accent-ring)]'
                      : 'bg-[var(--bg-gallery)] border-[var(--border-hairline)]',
                  ].join(' ')}
                >
                  <span
                    className={[
                      'h-5 w-5 rounded-[6px] border flex items-center justify-center shrink-0',
                      checked
                        ? 'bg-[var(--accent)] border-[var(--accent)] text-white'
                        : 'border-[var(--border-strong)] bg-[var(--bg-elevated)] text-transparent',
                    ].join(' ')}
                  >
                    <Check size={12} strokeWidth={2.5} />
                  </span>

                  <img
                    src={apiClient.thumbnailURL(rec.assetID, 'grid520', cacheBust)}
                    alt={rec.assetTitle}
                    className="h-12 w-12 rounded-[6px] object-cover bg-[var(--bg-subtle)] shrink-0"
                  />

                  <div className="flex-1 min-w-0">
                    <div className="flex items-center gap-2">
                      <span className="text-[13px] font-medium text-[var(--text-primary)] truncate">
                        {rec.assetTitle}
                      </span>
                      <span
                        className={[
                          'px-2 py-0.5 rounded-full text-[11px] font-medium shrink-0',
                          rec.recommendedFolderID
                            ? 'bg-[var(--accent-soft)] text-[var(--accent)]'
                            : 'bg-[var(--bg-subtle)] text-[var(--text-secondary)]',
                        ].join(' ')}
                      >
                        {rec.recommendedFolderName || '保留在收件箱'}
                      </span>
                    </div>
                    <p className="text-[11.5px] text-[var(--text-secondary)] truncate mt-0.5">
                      {rec.reason}
                    </p>
                  </div>

                  <div className="text-right shrink-0">
                    <div className="text-[12.5px] font-semibold tabular-nums text-[var(--text-primary)]">
                      {Math.round(rec.confidence * 100)}%
                    </div>
                    <div className="text-[10.5px] text-[var(--text-tertiary)]">置信度</div>
                  </div>
                </div>
              );
            })}
          </div>
        )}
      </ModalShell>
    </>
  );
};
