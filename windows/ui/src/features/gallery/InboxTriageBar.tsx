import React, { useEffect, useMemo, useRef, useState } from 'react';
import {
  CheckmarkCircle16Filled,
  Circle16Regular,
  Folder16Regular,
  Image16Regular,
  Sparkle16Regular,
  SubtractCircle16Regular,
  Wand16Regular,
} from '@fluentui/react-icons';
import { getTransport } from '../../api/transport';
import {
  Button,
  CharkleFolderIcon,
  CharkleIcon,
  CustomSelect,
  ModalShell,
  Popover,
  useDelayedFlag,
  type SelectOption,
} from '../../design-system';
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
  type InboxTriageRecommendation,
} from '../../types/domain';
import { FolderMoveMenu } from '../sidebar/FolderMoveMenu';

export interface InboxTriageBarProps {
  assets: AssetRecord[];
}

const TriageRowThumb: React.FC<{ asset?: AssetRecord; rawUrl: string }> = ({ asset, rawUrl }) => {
  const thumbSrc =
    rawUrl.startsWith('data:') || rawUrl.startsWith('blob:')
      ? rawUrl
      : asset?.updatedAt != null
        ? `${rawUrl}?v=${encodeURIComponent(String(asset.updatedAt))}`
        : rawUrl;
  const [failed, setFailed] = useState(false);

  useEffect(() => {
    setFailed(false);
  }, [thumbSrc]);

  if (asset?.fileName.toLowerCase().endsWith('.swatch')) {
    const hex = (asset.dominantColors[0]?.hex || '#2A60E0').toUpperCase();
    return (
      <div
        className="h-10 w-10 rounded-[var(--win-radius-control)] border border-[var(--win-stroke-card)] shrink-0"
        style={{ backgroundColor: hex }}
      />
    );
  }

  if (failed) {
    return (
      <div className="h-10 w-10 rounded-[var(--win-radius-control)] bg-[var(--bg-elevated)] border border-[var(--win-stroke-card)] flex items-center justify-center text-[var(--text-tertiary)] shrink-0">
        <Image16Regular className="w-4 h-4" />
      </div>
    );
  }

  return (
    <img
      src={thumbSrc}
      alt=""
      onError={() => setFailed(true)}
      className="h-10 w-10 rounded-[var(--win-radius-control)] object-cover bg-[var(--bg-elevated)] shrink-0"
    />
  );
};

/**
 * Single-row Fluent 2 Inbox Triage Strip:
 * - Pending count + AI recommended folder 1-click action + Batch Smart Triage modal
 * - Quick 1-9 folder archive chips + hierarchical "目录" dropdown
 * - 1-click "收入情绪板" menu (all boards + create new moodboard from inbox)
 */
export const InboxTriageBar: React.FC<InboxTriageBarProps> = ({ assets }) => {
  const destination = useCoordinatorStore((s) => s.destination);
  const selectedAssetIds = useCoordinatorStore((s) => s.selectedAssetIds);
  const clearSelection = useCoordinatorStore((s) => s.clearSelection);
  const setSelection = useCoordinatorStore((s) => s.setSelection);
  const setMoodboardGeneratorOpen = useCoordinatorStore((s) => s.setMoodboardGeneratorOpen);
  const pushToast = useCoordinatorStore((s) => s.pushToast);

  const folders = useLibraryStore((s) => s.folders);
  const inboxCount = useLibraryStore((s) => s.inboxCount);
  const updateAssets = useLibraryStore((s) => s.updateAssets);

  const boards = useMoodboardStore((s) => s.boards);
  const addAssetsToBoard = useMoodboardStore((s) => s.addAssetsToBoard);

  const allFoldersBtnRef = useRef<HTMLButtonElement | null>(null);
  const moodboardBtnRef = useRef<HTMLButtonElement | null>(null);

  const [allFoldersOpen, setAllFoldersOpen] = useState(false);
  const [moodboardMenuOpen, setMoodboardMenuOpen] = useState(false);
  const [triageRunning, setTriageRunning] = useState(false);
  const [triageModalOpen, setTriageModalOpen] = useState(false);
  const [triageRecs, setTriageRecs] = useState<InboxTriageRecommendation[]>([]);
  const [selectedTriageIds, setSelectedTriageIds] = useState<Set<string>>(new Set());

  const showTriageSpinner = useDelayedFlag(triageRunning, 300, 500);

  const flatFolders = useMemo(
    () => flattenFolderTree(buildFolderTree(folders)),
    [folders],
  );
  const topNineFolders = useMemo(() => flatFolders.slice(0, 9), [flatFolders]);

  const folderDisplayPath = useMemo(() => {
    const byId = new Map(folders.map((f) => [f.id, f]));
    return (folderId: string): string => {
      const names: string[] = [];
      const visited = new Set<string>();
      let cur = byId.get(folderId);
      while (cur && !visited.has(cur.id)) {
        visited.add(cur.id);
        names.unshift(cur.name);
        cur = cur.parentID ? byId.get(cur.parentID) : undefined;
      }
      return names.join(' / ');
    };
  }, [folders]);

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
  }, [primaryAsset?.id, primaryAsset?.updatedAt, folders.length]);

  if (!primaryAsset) return null;

  const targetIds = targetAssets.map((a) => a.id);
  const transport = getTransport();

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

  const handleRunSmartTriage = async () => {
    if (triageRunning) return;
    setTriageRunning(true);
    try {
      const selectedInInbox = selectedAssetIds.filter((id) => assets.some((a) => a.id === id));
      const recs = await transport.runInboxSmartTriage(
        selectedInInbox.length > 0 ? selectedInInbox : undefined,
        24,
      );
      setTriageRecs(recs);
      setSelectedTriageIds(
        new Set(
          recs
            .filter((r) => r.recommendedFolderID && r.confidence >= 0.65)
            .map((r) => r.assetID),
        ),
      );
      setTriageModalOpen(true);
    } catch (err) {
      pushToast({
        message: err instanceof Error ? err.message : '智能分拣失败，请检查相关配置',
        tone: 'error',
      });
    } finally {
      setTriageRunning(false);
    }
  };

  const handleOverrideTriageFolder = (assetID: string, folderID: string) => {
    const nextFolder = folderID ? folders.find((f) => f.id === folderID) ?? null : null;
    setTriageRecs((prev) =>
      prev.map((rec) => {
        if (rec.assetID !== assetID) return rec;
        if (!nextFolder) {
          return {
            ...rec,
            recommendedFolderID: null,
            recommendedFolderName: null,
            confidence: 0,
            fitProbability: 0,
            reason: '已手动设为暂留收件箱',
          };
        }
        return {
          ...rec,
          recommendedFolderID: nextFolder.id,
          recommendedFolderName: nextFolder.name,
          confidence: 1,
          fitProbability: 1,
          reason: `已手动指定归档至「${folderDisplayPath(nextFolder.id)}」`,
        };
      }),
    );
    setSelectedTriageIds((prev) => {
      const next = new Set(prev);
      if (nextFolder) next.add(assetID);
      else next.delete(assetID);
      return next;
    });
  };

  const actionableRecs = triageRecs.filter((r) => Boolean(r.recommendedFolderID));
  const selectedRecs = actionableRecs.filter((r) => selectedTriageIds.has(r.assetID));

  const handleApplyTriage = async () => {
    const batch = selectedRecs;
    setTriageModalOpen(false);
    if (batch.length === 0) return;

    const grouped = new Map<string, string[]>();
    for (const rec of batch) {
      if (!rec.recommendedFolderID) continue;
      const list = grouped.get(rec.recommendedFolderID) ?? [];
      list.push(rec.assetID);
      grouped.set(rec.recommendedFolderID, list);
    }

    let movedCount = 0;
    for (const [folderId, ids] of grouped.entries()) {
      await updateAssets(
        { assetIDs: ids, folderAssignment: { folder: folderId } },
        destination,
      );
      movedCount += ids.length;
    }
    pushToast({
      message: `智能分拣完成：已归档 ${movedCount} 项素材`,
      tone: 'success',
    });
  };

  return (
    <>
      <div
        data-testid="inbox-triage-bar"
        className="pointer-events-auto charkle-reveal-top win-acrylic-bar min-h-[38px] px-3 py-1 rounded-[var(--win-radius-card)] flex items-center gap-2"
      >
        {/* Left: Inbox count */}
        <div className="flex items-center gap-1.5 shrink-0">
          <CharkleIcon name="inbox" style="duotone" size={15} isActive />
          <span className="text-[12.5px] font-semibold text-[var(--text-primary)] charkle-tabular whitespace-nowrap">
            待整理 {inboxCount || assets.length} 项
          </span>
        </div>

        <div className="h-4 w-px bg-[var(--win-stroke-divider)] shrink-0" />

        {/* AI Suggested Folder 1-Click Action */}
        {suggestion && (
          <button
            type="button"
            onClick={() => void moveToFolder(suggestion.folderID, suggestion.folderName)}
            title={suggestion.reason}
            className="charkle-pressable h-[26px] px-2 inline-flex items-center gap-1 rounded-[var(--win-radius-control)] bg-[var(--accent-soft)] text-[var(--accent)] hover:brightness-95 text-[11.5px] font-semibold cursor-pointer shrink-0 whitespace-nowrap"
          >
            <Sparkle16Regular className="w-3 h-3 shrink-0" />
            <span className="max-w-[96px] truncate">推荐：{suggestion.folderName}</span>
          </button>
        )}

        {/* Batch Inbox Smart Triage */}
        {folders.length > 0 && (
          <button
            type="button"
            disabled={triageRunning}
            onClick={() => void handleRunSmartTriage()}
            title="批量识别收件箱素材并推荐归档目录"
            className="charkle-pressable h-[26px] px-2 inline-flex items-center gap-1 rounded-[var(--win-radius-control)] bg-[var(--accent-soft)] text-[var(--accent)] hover:brightness-95 text-[11.5px] font-semibold cursor-pointer shrink-0 whitespace-nowrap disabled:opacity-50"
          >
            {showTriageSpinner ? (
              <span
                aria-hidden="true"
                className="h-3 w-3 rounded-full border-2 border-current border-t-transparent animate-spin motion-reduce:animate-none"
              />
            ) : (
              <Wand16Regular className="w-3.5 h-3.5 shrink-0" />
            )}
            <span>{triageRunning ? '分拣中…' : '智能分拣'}</span>
          </button>
        )}

        {/* Quick 1-9 Folder Archive Chips */}
        <div
          onWheel={(e) => {
            if (Math.abs(e.deltaY) > Math.abs(e.deltaX)) {
              e.currentTarget.scrollLeft += e.deltaY;
            }
          }}
          className="flex-1 min-w-0 flex items-center gap-1.5 overflow-x-auto charkle-scroll-hidden"
        >
          {topNineFolders.map((node, index) => (
            <button
              key={node.folder.id}
              type="button"
              onClick={() => void moveToFolder(node.folder.id, node.folder.name)}
              title={`${folderDisplayPath(node.folder.id)}（按数字键 ${index + 1}）`}
              className="charkle-pressable h-[26px] px-2 inline-flex items-center gap-1.5 rounded-[var(--win-radius-control)] bg-[var(--win-subtle-hover)] hover:bg-[var(--accent-soft)] hover:text-[var(--accent)] text-[11.5px] font-medium text-[var(--text-primary)] cursor-pointer shrink-0 whitespace-nowrap"
            >
              <kbd className="text-[10px] font-semibold charkle-mono w-[15px] h-[15px] inline-flex items-center justify-center rounded-[3px] bg-[var(--bg-subtle)] text-[var(--text-secondary)] shrink-0">
                {index + 1}
              </kbd>
              <CharkleFolderIcon
                colorHex={node.folder.colorHex}
                customSymbol={node.folder.customSymbol}
                size={13}
              />
              <span className="max-w-[116px] shrink-0 truncate">
                {node.depth > 0 ? `↳ ${node.folder.name}` : node.folder.name}
              </span>
            </button>
          ))}
        </div>

        {/* Always-accessible Full Folder Menu */}
        {folders.length > 0 && (
          <Button
            ref={allFoldersBtnRef}
            variant="subtle"
            size="xs"
            title="展开全部文件夹归档目录"
            onClick={() => setAllFoldersOpen((v) => !v)}
            className="shrink-0"
          >
            <Folder16Regular className="w-3.5 h-3.5 shrink-0" />
            <span>目录</span>
          </Button>
        )}

        {/* 1-Click Send to Moodboard Menu */}
        <Button
          ref={moodboardBtnRef}
          variant="standard"
          size="xs"
          title="一键收入情绪板"
          onClick={() => setMoodboardMenuOpen((v) => !v)}
          className="shrink-0"
        >
          <CharkleIcon name="sparkle-board" style="duotone" size={14} isActive />
          <span>收入情绪板</span>
        </Button>
      </div>

      {/* All Folders Hierarchical Popover */}
      <Popover
        open={allFoldersOpen}
        onOpenChange={setAllFoldersOpen}
        anchorEl={allFoldersBtnRef.current}
        placement="bottom-start"
        className="p-1"
      >
        <FolderMoveMenu
          folders={folders}
          onSelectFolder={(folderId) => {
            setAllFoldersOpen(false);
            if (!folderId) return;
            const folderName = folders.find((f) => f.id === folderId)?.name ?? '文件夹';
            void moveToFolder(folderId, folderName);
          }}
        />
      </Popover>

      {/* Send to Moodboard Popover */}
      <Popover
        open={moodboardMenuOpen}
        onOpenChange={setMoodboardMenuOpen}
        anchorEl={moodboardBtnRef.current}
        placement="bottom-end"
        className="w-[232px] p-1"
      >
        <div className="flex flex-col gap-0.5 text-[13px] leading-[18px]">
          {boards.map((board) => (
            <button
              key={board.id}
              type="button"
              onClick={() => {
                setMoodboardMenuOpen(false);
                void addAssetsToBoard(board.id, targetIds);
              }}
              className="w-full min-h-[32px] text-left px-2.5 py-1.5 rounded-[var(--win-radius-control)] text-[var(--text-primary)] hover:bg-[var(--win-subtle-hover)] truncate cursor-pointer"
            >
              {board.title}
            </button>
          ))}
          {boards.length > 0 && <div className="my-1 mx-2 h-px bg-[var(--win-stroke-divider)]" />}
          <button
            type="button"
            onClick={() => {
              setMoodboardMenuOpen(false);
              setSelection(assets.slice(0, 16).map((a) => a.id));
              setMoodboardGeneratorOpen(true);
            }}
            className="w-full min-h-[32px] flex items-center gap-2 px-2.5 py-1.5 rounded-[var(--win-radius-control)] text-[var(--accent)] hover:bg-[var(--accent-soft)] font-medium cursor-pointer"
          >
            <Sparkle16Regular className="w-4 h-4 shrink-0" />
            <span>用当前收件箱创建新情绪板…</span>
          </button>
        </div>
      </Popover>

      {/* Batch Inbox Smart Triage Preview Modal */}
      <ModalShell
        open={triageModalOpen}
        onClose={() => setTriageModalOpen(false)}
        title="收件箱智能分拣预览"
        subtitle={`共分析 ${triageRecs.length} 项待整理素材，其中 ${actionableRecs.length} 项匹配到已有目录；高置信度项已默认勾选。`}
        width="md"
        footer={
          <div className="w-full flex items-center justify-between gap-2">
            <div>
              {actionableRecs.length > 0 && (
                <Button
                  variant="standard"
                  size="sm"
                  onClick={() => {
                    if (selectedRecs.length === actionableRecs.length) {
                      setSelectedTriageIds(new Set());
                    } else {
                      setSelectedTriageIds(new Set(actionableRecs.map((r) => r.assetID)));
                    }
                  }}
                >
                  {selectedRecs.length === actionableRecs.length ? '取消全选' : '全选推荐项'}
                </Button>
              )}
            </div>
            <div className="flex items-center gap-2">
              <Button variant="standard" size="sm" onClick={() => setTriageModalOpen(false)}>
                取消
              </Button>
              <Button
                variant="accent"
                size="sm"
                disabled={selectedRecs.length === 0}
                onClick={() => void handleApplyTriage()}
              >
                归档已勾选 ({selectedRecs.length} 项)
              </Button>
            </div>
          </div>
        }
      >
        {triageRecs.length === 0 ? (
          <div className="py-10 text-center text-[13px] text-[var(--text-secondary)]">
            收件箱暂无可分拣素材。
          </div>
        ) : (
          <div className="flex flex-col gap-1.5 max-h-[360px] overflow-y-auto charkle-scroll">
            {triageRecs.map((rec) => {
              const hasTarget = Boolean(rec.recommendedFolderID);
              const checked = selectedTriageIds.has(rec.assetID);
              return (
                <div
                  key={rec.assetID}
                  className="p-2 rounded-[var(--win-radius-card)] bg-[var(--bg-subtle)]/65 flex items-center gap-2.5"
                >
                  <button
                    type="button"
                    disabled={!hasTarget}
                    aria-label={checked ? '取消勾选' : '勾选归档'}
                    onClick={() => {
                      if (!hasTarget) return;
                      setSelectedTriageIds((prev) => {
                        const next = new Set(prev);
                        if (next.has(rec.assetID)) next.delete(rec.assetID);
                        else next.add(rec.assetID);
                        return next;
                      });
                    }}
                    className="cursor-pointer disabled:opacity-45 shrink-0 text-[var(--accent)]"
                  >
                    {!hasTarget ? (
                      <SubtractCircle16Regular className="w-4 h-4 text-[var(--text-tertiary)]" />
                    ) : checked ? (
                      <CheckmarkCircle16Filled className="w-4 h-4" />
                    ) : (
                      <Circle16Regular className="w-4 h-4 text-[var(--text-tertiary)]" />
                    )}
                  </button>

                  <TriageRowThumb
                    asset={assets.find((a) => a.id === rec.assetID)}
                    rawUrl={transport.thumbnailUrl(rec.assetID, 'grid520')}
                  />

                  <div className="min-w-0 flex-1">
                    <div className="text-[13px] font-medium text-[var(--text-primary)] truncate">
                      {rec.assetTitle}
                    </div>
                    <div className="text-[11.5px] text-[var(--text-secondary)] truncate">
                      {rec.reason}
                    </div>
                  </div>

                  <div className="flex items-center gap-1.5 shrink-0">
                    <CustomSelect<string>
                      ariaLabel={`为「${rec.assetTitle}」选择目标目录`}
                      size="xs"
                      value={rec.recommendedFolderID ?? ''}
                      onChange={(val) => handleOverrideTriageFolder(rec.assetID, val)}
                      options={[
                        { value: '', label: '留在收件箱' } as SelectOption<string>,
                        ...flatFolders.map(
                          (node): SelectOption<string> => ({
                            value: node.folder.id,
                            label: node.folder.name,
                            depth: node.depth,
                          }),
                        ),
                      ]}
                      className={[
                        'max-w-[160px] text-[11.5px] font-medium',
                        rec.recommendedFolderID && rec.confidence >= 0.65
                          ? 'border-[var(--accent)]/30 bg-[var(--accent-soft)] text-[var(--accent)]'
                          : '',
                      ].join(' ')}
                    />
                    {rec.recommendedFolderID && rec.confidence > 0 && rec.confidence < 1 && (
                      <span className="text-[10.5px] text-[var(--text-tertiary)] charkle-tabular w-[30px] text-right">
                        {Math.round(rec.confidence * 100)}%
                      </span>
                    )}
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
