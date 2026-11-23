import React, { useEffect, useMemo, useState } from 'react';
import { LayoutGrid, Sparkles, Trash2 } from 'lucide-react';
import { getTransport } from '../../api/transport';
import { CharkleFolderIcon } from '../../design-system';
import {
  useCoordinatorStore,
  useLibraryStore,
  useMoodboardStore,
} from '../../stores';
import {
  buildFolderTree,
  flattenFolderTree,
  type AssetRecord,
  type FolderSuggestion,
} from '../../types/domain';

export interface InboxTriageBarProps {
  assets: AssetRecord[];
}

/**
 * Rapid Inbox triage strip (DESIGN.md M2-R6):
 * - Keys 1–9 move selected/top Inbox asset into the first 9 folders immediately with Undo toast
 * - Live smart folder suggestion chip with one-click Accept
 * - Quick send to active Moodboard & soft-trash
 */
export const InboxTriageBar: React.FC<InboxTriageBarProps> = ({ assets }) => {
  const destination = useCoordinatorStore((s) => s.destination);
  const selectedAssetIds = useCoordinatorStore((s) => s.selectedAssetIds);
  const activeMoodboardId = useCoordinatorStore((s) => s.activeMoodboardId);
  const clearSelection = useCoordinatorStore((s) => s.clearSelection);

  const folders = useLibraryStore((s) => s.folders);
  const updateAssets = useLibraryStore((s) => s.updateAssets);

  const boards = useMoodboardStore((s) => s.boards);
  const addAssetsToBoard = useMoodboardStore((s) => s.addAssetsToBoard);

  const topNineFolders = useMemo(
    () => flattenFolderTree(buildFolderTree(folders)).slice(0, 9),
    [folders],
  );

  const targetAssets = useMemo(() => {
    if (selectedAssetIds.length > 0) {
      const set = new Set(selectedAssetIds);
      const matched = assets.filter((a) => set.has(a.id));
      if (matched.length > 0) return matched;
    }
    return assets[0] ? [assets[0]] : [];
  }, [assets, selectedAssetIds]);

  const primaryAsset = targetAssets[0] ?? null;
  const [suggestion, setSuggestion] = useState<FolderSuggestion | null>(null);

  useEffect(() => {
    let cancelled = false;
    if (!primaryAsset) {
      setSuggestion(null);
      return;
    }
    void getTransport()
      .suggestFolder(primaryAsset.id)
      .then((res) => {
        if (!cancelled) setSuggestion(res);
      })
      .catch(() => {
        if (!cancelled) setSuggestion(null);
      });
    return () => {
      cancelled = true;
    };
  }, [primaryAsset]);

  if (!primaryAsset) return null;

  const targetIds = targetAssets.map((a) => a.id);

  const moveToFolder = async (folderId: string, folderName: string) => {
    clearSelection();
    await updateAssets(
      { assetIDs: targetIds, folderAssignment: { folder: folderId } },
      destination,
      {
        undoMessage: `已分拣 ${targetIds.length} 项到「${folderName}」`,
        undoPatch: { assetIDs: targetIds, folderAssignment: 'inbox' },
      },
    );
  };

  const targetBoardId = activeMoodboardId ?? boards[0]?.id ?? null;

  return (
    <div
      data-testid="inbox-triage-bar"
      className="shrink-0 mx-4 mb-2 px-3 py-2 rounded-[var(--radius-settings-outer)] bg-[var(--bg-elevated)] border border-[var(--border-hairline)] flex flex-col gap-2"
    >
      <div className="flex items-center justify-between gap-2 flex-wrap">
        <div className="flex items-center gap-2 min-w-0">
          <span className="text-[11.5px] font-semibold text-[var(--accent)] bg-[var(--accent-soft)] px-2 py-0.5 rounded-full shrink-0">
            收件箱分拣
          </span>
          <span className="text-[12.5px] font-medium text-[var(--text-primary)] truncate">
            {targetIds.length > 1
              ? `已选 ${targetIds.length} 项素材`
              : primaryAsset.title}
          </span>
          <span className="hidden md:inline text-[11.5px] text-[var(--text-tertiary)]">
            按数字键 1–9 一键归档
          </span>
        </div>

        <div className="flex items-center gap-1.5">
          {suggestion && (
            <button
              type="button"
              onClick={() => void moveToFolder(suggestion.folderID, suggestion.folderName)}
              title={suggestion.reason}
              className="charkle-pressable h-7 px-2.5 inline-flex items-center gap-1.5 rounded-[var(--radius-chip)] bg-[var(--accent-soft)] text-[var(--accent)] text-[12px] font-medium cursor-pointer"
            >
              <Sparkles size={12.5} />
              <span>建议归入：{suggestion.folderName}</span>
            </button>
          )}

          {targetBoardId && (
            <button
              type="button"
              onClick={() => void addAssetsToBoard(targetBoardId, targetIds)}
              className="charkle-pressable h-7 px-2.5 inline-flex items-center gap-1.5 rounded-[var(--radius-chip)] bg-[var(--bg-subtle)] text-[var(--text-primary)] hover:bg-[var(--border-hairline)] text-[12px] cursor-pointer"
            >
              <LayoutGrid size={12.5} />
              <span>发送至情绪板</span>
            </button>
          )}

          <button
            type="button"
            onClick={() => {
              clearSelection();
              void updateAssets({ assetIDs: targetIds, isTrashed: true }, destination, {
                undoMessage: `已将 ${targetIds.length} 项移入回收站`,
                undoPatch: { assetIDs: targetIds, isTrashed: false },
              });
            }}
            className="charkle-pressable h-7 px-2 inline-flex items-center gap-1 rounded-[var(--radius-chip)] text-[var(--danger)] hover:bg-[var(--danger-soft)] text-[12px] cursor-pointer"
          >
            <Trash2 size={12.5} />
            <span>舍弃</span>
          </button>
        </div>
      </div>

      {topNineFolders.length > 0 && (
        <div className="flex items-center gap-1.5 flex-wrap">
          {topNineFolders.map((node, index) => (
            <button
              key={node.folder.id}
              type="button"
              onClick={() => void moveToFolder(node.folder.id, node.folder.name)}
              className="charkle-pressable h-7 px-2 inline-flex items-center gap-1.5 rounded-[var(--radius-chip)] bg-[var(--bg-subtle)] hover:bg-[var(--accent-soft)] hover:text-[var(--accent)] text-[12px] text-[var(--text-primary)] cursor-pointer"
            >
              <kbd className="text-[10.5px] font-semibold px-1 py-0.5 rounded bg-[var(--bg-elevated)] border border-[var(--border-hairline)] text-[var(--text-tertiary)] charkle-tabular">
                {index + 1}
              </kbd>
              <CharkleFolderIcon
                colorHex={node.folder.colorHex}
                customSymbol={node.folder.customSymbol}
                size={13.5}
              />
              <span className="max-w-[120px] truncate">{node.folder.name}</span>
            </button>
          ))}
        </div>
      )}
    </div>
  );
};
