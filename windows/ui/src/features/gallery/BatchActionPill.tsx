import React, { useMemo, useRef, useState } from 'react';
import {
  ArrowDownload16Regular,
  ArrowExportUp16Regular,
  ArrowUndo16Regular,
  Board16Regular,
  Cloud16Regular,
  Delete16Regular,
  Dismiss16Regular,
  FolderArrowRight16Regular,
  ImageMultiple16Regular,
  Sparkle16Regular,
  Star16Regular,
  Tag16Regular,
} from '@fluentui/react-icons';
import { getTransport } from '../../api/transport';
import { Button, ModalShell, Popover, Tooltip } from '../../design-system';
import {
  useCoordinatorStore,
  useLibraryStore,
  useMoodboardStore,
} from '../../stores';
import { extractableLinkAttachments } from '../../types/domain';
import { FolderMoveMenu } from '../sidebar/FolderMoveMenu';

/**
 * Floating bottom-center Fluent 2 Acrylic multi-select batch action bar
 * (shown on demand when >= 2 items are selected).
 */
export const BatchActionPill: React.FC = () => {
  const selectedAssetIds = useCoordinatorStore((s) => s.selectedAssetIds);
  const clearSelection = useCoordinatorStore((s) => s.clearSelection);
  const destination = useCoordinatorStore((s) => s.destination);
  const setMoodboardGeneratorOpen = useCoordinatorStore((s) => s.setMoodboardGeneratorOpen);
  const pushToast = useCoordinatorStore((s) => s.pushToast);
  const isModalOverlayActive = useCoordinatorStore(
    (s) =>
      s.settingsOpen ||
      s.onboardingOpen ||
      s.quickLookAssetId !== null ||
      s.jumpOpen ||
      s.captureOpen ||
      s.moodboardGeneratorOpen,
  );

  const assets = useLibraryStore((s) => s.assets);
  const folders = useLibraryStore((s) => s.folders);
  const tagCounts = useLibraryStore((s) => s.tagCounts);
  const updateAssets = useLibraryStore((s) => s.updateAssets);
  const permanentlyDeleteAssets = useLibraryStore((s) => s.permanentlyDeleteAssets);
  const batchExtractLinkMedia = useLibraryStore((s) => s.batchExtractLinkMedia);
  const exportAssetsToPureRef = useLibraryStore((s) => s.exportAssetsToPureRef);

  const boards = useMoodboardStore((s) => s.boards);
  const addAssetsToBoard = useMoodboardStore((s) => s.addAssetsToBoard);

  const [moveOpen, setMoveOpen] = useState(false);
  const [tagOpen, setTagOpen] = useState(false);
  const [rateOpen, setRateOpen] = useState(false);
  const [boardOpen, setBoardOpen] = useState(false);
  const [tagDraft, setTagDraft] = useState('');
  const [permDeleteIds, setPermDeleteIds] = useState<string[] | null>(null);
  const [extractingBatch, setExtractingBatch] = useState(false);
  const [exportingPureRef, setExportingPureRef] = useState(false);

  const moveBtnRef = useRef<HTMLButtonElement | null>(null);
  const tagBtnRef = useRef<HTMLButtonElement | null>(null);
  const rateBtnRef = useRef<HTMLButtonElement | null>(null);
  const boardBtnRef = useRef<HTMLButtonElement | null>(null);

  const selectedAssets = useMemo(() => {
    if (selectedAssetIds.length < 2) return [];
    const set = new Set(selectedAssetIds);
    return assets.filter((a) => set.has(a.id));
  }, [assets, selectedAssetIds]);

  const extractableLinkAssets = useMemo(
    () => selectedAssets.filter((a) => extractableLinkAttachments(a).length > 0),
    [selectedAssets],
  );

  const showPill = selectedAssetIds.length >= 2 && !isModalOverlayActive;
  if (!showPill && permDeleteIds === null) return null;

  const isTrashSelection =
    destination.type === 'trash' ||
    (selectedAssets.length > 0 && selectedAssets.every((a) => a.isTrashed));
  const allKeptLocally =
    selectedAssets.length > 0 && selectedAssets.every((a) => a.pinnedOffline);

  const handleBatchExtractMedia = async () => {
    if (extractingBatch || extractableLinkAssets.length === 0) return;
    setExtractingBatch(true);
    try {
      const ids = extractableLinkAssets.map((a) => a.id);
      const report = await batchExtractLinkMedia(ids, destination);
      if (report.extractedAssets.length > 0) {
        pushToast({
          message:
            report.failedCount > 0
              ? `已从 ${report.sourceAssetCount} 条链接提取 ${report.extractedAssets.length} 项独立素材（${report.failedCount} 项失败）`
              : `已从 ${report.sourceAssetCount} 条链接提取 ${report.extractedAssets.length} 项独立素材`,
          tone: 'success',
          durationMs: 4200,
        });
      } else {
        pushToast({
          message: '未能提取所选链接中的媒体，请检查网络连接或重试',
          tone: 'info',
        });
      }
    } catch (err) {
      pushToast({
        message: `批量提取媒体失败：${err instanceof Error ? err.message : String(err)}`,
        tone: 'error',
      });
    } finally {
      setExtractingBatch(false);
    }
  };

  const handleBatchExportPureRef = async () => {
    if (exportingPureRef || selectedAssetIds.length === 0) return;
    setExportingPureRef(true);
    try {
      const dest = await getTransport().saveFileDialog('Charkle参考图集.pur', [
        { name: 'PureRef 场景 (.pur)', extensions: ['pur'] },
      ]);
      if (!dest) return;
      const report = await exportAssetsToPureRef([...selectedAssetIds], dest);
      pushToast({
        message: `已导出 PureRef 场景（${report.imageCount} 张图）`,
        tone: 'success',
        durationMs: 4200,
      });
    } catch (err) {
      pushToast({
        message: `导出 PureRef 失败：${err instanceof Error ? err.message : String(err)}`,
        tone: 'error',
      });
    } finally {
      setExportingPureRef(false);
    }
  };

  const applyBatchTag = async (tag: string) => {
    const clean = tag.trim();
    const ids = [...selectedAssetIds];
    if (!clean || ids.length === 0) return;
    await updateAssets({ assetIDs: ids, addTags: [clean] }, destination);
    setTagDraft('');
    setTagOpen(false);
    pushToast({
      message: `已为 ${ids.length} 项添加标签 #${clean}`,
      tone: 'success',
    });
  };

  return (
    <>
      {showPill && (
        <div className="pointer-events-none absolute bottom-5 left-1/2 -translate-x-1/2 z-30 max-w-[calc(100%-32px)]">
          <div className="charkle-reveal-bottom pointer-events-auto win-acrylic rounded-[var(--win-radius-overlay)] px-2.5 py-1.5 flex items-center gap-1.5 text-[12.5px]">
            <span className="pl-1 pr-1.5 font-semibold text-[var(--text-primary)] charkle-tabular whitespace-nowrap">
              已选 {selectedAssetIds.length} 项
            </span>

            <div className="h-4 w-px bg-[var(--win-stroke-divider)]" />

            {isTrashSelection ? (
              <>
                <Button
                  variant="accent"
                  size="xs"
                  onClick={() => {
                    const ids = [...selectedAssetIds];
                    clearSelection();
                    void updateAssets({ assetIDs: ids, isTrashed: false }, destination).then(() =>
                      pushToast({
                        message: `已将 ${ids.length} 项放回原处`,
                        tone: 'success',
                      }),
                    );
                  }}
                >
                  <ArrowUndo16Regular className="w-3.5 h-3.5" />
                  <span>放回原处</span>
                </Button>

                <Button
                  variant="danger"
                  size="xs"
                  onClick={() => setPermDeleteIds([...selectedAssetIds])}
                >
                  <Delete16Regular className="w-3.5 h-3.5" />
                  <span>彻底删除</span>
                </Button>
              </>
            ) : (
              <>
                <Button
                  variant="accent"
                  size="xs"
                  onClick={() => setMoodboardGeneratorOpen(true)}
                >
                  <Sparkle16Regular className="w-3.5 h-3.5" />
                  <span>生成情绪板</span>
                </Button>

                {extractableLinkAssets.length > 0 && (
                  <Button
                    variant="subtle"
                    size="xs"
                    loading={extractingBatch}
                    data-testid="batch-extract-link-media"
                    onClick={() => void handleBatchExtractMedia()}
                    className="text-[var(--accent)] font-semibold"
                  >
                    <ImageMultiple16Regular className="w-3.5 h-3.5" />
                    <span>
                      {extractingBatch
                        ? '提取中…'
                        : `提取媒体 (${extractableLinkAssets.length})`}
                    </span>
                  </Button>
                )}

                <Button
                  variant="subtle"
                  size="xs"
                  loading={exportingPureRef}
                  data-testid="batch-export-pureref"
                  onClick={() => void handleBatchExportPureRef()}
                  className="text-[var(--text-primary)]"
                >
                  <ArrowExportUp16Regular className="w-3.5 h-3.5" />
                  <span>导出 PureRef</span>
                </Button>

                {boards.length > 0 && (
                  <Button
                    ref={boardBtnRef}
                    variant="subtle"
                    size="xs"
                    onClick={() => setBoardOpen((v) => !v)}
                    className="text-[var(--text-primary)]"
                  >
                    <Board16Regular className="w-3.5 h-3.5" />
                    <span>加入板</span>
                  </Button>
                )}

                <Button
                  ref={moveBtnRef}
                  variant="subtle"
                  size="xs"
                  onClick={() => setMoveOpen((v) => !v)}
                  className="text-[var(--text-primary)]"
                >
                  <FolderArrowRight16Regular className="w-3.5 h-3.5" />
                  <span>移动</span>
                </Button>

                <Button
                  ref={tagBtnRef}
                  variant="subtle"
                  size="xs"
                  onClick={() => setTagOpen((v) => !v)}
                  className="text-[var(--text-primary)]"
                >
                  <Tag16Regular className="w-3.5 h-3.5" />
                  <span>加标签</span>
                </Button>

                <Button
                  ref={rateBtnRef}
                  variant="subtle"
                  size="xs"
                  onClick={() => setRateOpen((v) => !v)}
                  className="text-[var(--text-primary)]"
                >
                  <Star16Regular className="w-3.5 h-3.5" />
                  <span>评分</span>
                </Button>

                {/* Smart Kept-Locally Toggle */}
                <Tooltip content={allKeptLocally ? '取消全部保留在本地' : '全部始终保留在本地'}>
                  <button
                    type="button"
                    aria-label={allKeptLocally ? '取消全部保留在本地' : '全部始终保留在本地'}
                    onClick={() => {
                      const nextPinned = !allKeptLocally;
                      const count = selectedAssetIds.length;
                      void updateAssets(
                        { assetIDs: selectedAssetIds, pinnedOffline: nextPinned },
                        destination,
                      ).then(() =>
                        pushToast({
                          message: nextPinned
                            ? `已将 ${count} 项设为始终保留在本地`
                            : `已取消 ${count} 项的始终保留`,
                          tone: 'info',
                        }),
                      );
                    }}
                    className={[
                      'charkle-pressable h-[26px] w-[26px] inline-flex items-center justify-center rounded-[var(--win-radius-control)] hover:bg-[var(--win-subtle-hover)] cursor-pointer',
                      allKeptLocally ? 'text-[var(--accent)]' : 'text-[var(--text-primary)]',
                    ].join(' ')}
                  >
                    {allKeptLocally ? (
                      <ArrowDownload16Regular className="w-4 h-4" />
                    ) : (
                      <Cloud16Regular className="w-4 h-4" />
                    )}
                  </button>
                </Tooltip>

                <Tooltip content="移至回收站">
                  <button
                    type="button"
                    aria-label="移至回收站"
                    onClick={() => {
                      const ids = [...selectedAssetIds];
                      clearSelection();
                      void updateAssets({ assetIDs: ids, isTrashed: true }, destination, {
                        undoMessage: `已移至回收站 (${ids.length} 项)`,
                        undoPatch: { assetIDs: ids, isTrashed: false },
                      });
                    }}
                    className="charkle-pressable h-[26px] w-[26px] inline-flex items-center justify-center rounded-[var(--win-radius-control)] text-[var(--danger)] hover:bg-[var(--danger-soft)] cursor-pointer"
                  >
                    <Delete16Regular className="w-4 h-4" />
                  </button>
                </Tooltip>
              </>
            )}

            <Tooltip content="取消选择" shortcut="Esc">
              <button
                type="button"
                aria-label="取消选择"
                onClick={clearSelection}
                className="charkle-pressable h-[26px] w-[26px] inline-flex items-center justify-center rounded-[var(--win-radius-control)] text-[var(--text-secondary)] hover:bg-[var(--win-subtle-hover)] hover:text-[var(--text-primary)] cursor-pointer"
              >
                <Dismiss16Regular className="w-3.5 h-3.5" />
              </button>
            </Tooltip>
          </div>
        </div>
      )}

      {/* Move Popover */}
      <Popover
        open={moveOpen}
        onOpenChange={setMoveOpen}
        anchorEl={moveBtnRef.current}
        placement="top-center"
        className="p-1"
      >
        <FolderMoveMenu
          folders={folders}
          onSelectFolder={(folderId) => {
            setMoveOpen(false);
            const ids = [...selectedAssetIds];
            const destName = folderId
              ? folders.find((f) => f.id === folderId)?.name ?? '文件夹'
              : '收件箱';
            void updateAssets(
              {
                assetIDs: ids,
                folderAssignment: folderId ? { folder: folderId } : 'inbox',
              },
              destination,
              {
                undoMessage: `已移动 ${ids.length} 项至「${destName}」`,
                undoPatch: { assetIDs: ids, folderAssignment: 'inbox' },
              },
            );
          }}
        />
      </Popover>

      {/* Batch Tag Popover */}
      <Popover
        open={tagOpen}
        onOpenChange={setTagOpen}
        anchorEl={tagBtnRef.current}
        placement="top-center"
        className="w-[248px] p-3"
      >
        <form
          onSubmit={(e) => {
            e.preventDefault();
            void applyBatchTag(tagDraft);
          }}
          className="flex flex-col gap-2"
        >
          <div className="text-[12.5px] font-semibold text-[var(--text-primary)]">
            为 {selectedAssetIds.length} 项素材添加标签
          </div>
          <input
            type="text"
            value={tagDraft}
            autoFocus
            onChange={(e) => setTagDraft(e.target.value)}
            placeholder="输入标签回车…"
            className="win-input-elevation h-8 px-2.5 rounded-[var(--win-radius-control)] text-[12.5px] text-[var(--text-primary)] placeholder:text-[var(--text-tertiary)] outline-none"
          />
          {tagCounts.length > 0 && (
            <div className="flex flex-wrap gap-1">
              {tagCounts.slice(0, 8).map((t) => (
                <button
                  key={t.name}
                  type="button"
                  onClick={() => void applyBatchTag(t.name)}
                  className="charkle-pressable px-2 py-0.5 text-[11.5px] rounded-[var(--win-radius-control)] bg-[var(--win-subtle-hover)] text-[var(--text-secondary)] hover:text-[var(--text-primary)] hover:bg-[var(--win-subtle-active)] cursor-pointer"
                >
                  #{t.name}
                </button>
              ))}
            </div>
          )}
        </form>
      </Popover>

      {/* Batch Rating Popover */}
      <Popover
        open={rateOpen}
        onOpenChange={setRateOpen}
        anchorEl={rateBtnRef.current}
        placement="top-center"
        className="p-1"
      >
        <div className="flex flex-col gap-0.5 min-w-[132px]">
          {[1, 2, 3, 4, 5].map((r) => (
            <button
              key={r}
              type="button"
              onClick={() => {
                setRateOpen(false);
                void updateAssets({ assetIDs: selectedAssetIds, rating: r }, destination);
              }}
              className="charkle-pressable w-full min-h-[30px] flex items-center gap-0.5 px-2.5 py-1 rounded-[var(--win-radius-control)] text-[12.5px] text-[#E5B243] hover:bg-[var(--win-subtle-hover)] cursor-pointer"
            >
              {'★'.repeat(r)}
            </button>
          ))}
          <div className="my-1 mx-2 h-px bg-[var(--win-stroke-divider)]" />
          <button
            type="button"
            onClick={() => {
              setRateOpen(false);
              void updateAssets({ assetIDs: selectedAssetIds, rating: 0 }, destination);
            }}
            className="charkle-pressable w-full min-h-[30px] text-left px-2.5 py-1 rounded-[var(--win-radius-control)] text-[12.5px] text-[var(--text-secondary)] hover:bg-[var(--win-subtle-hover)] cursor-pointer"
          >
            清除评分
          </button>
        </div>
      </Popover>

      {/* Send to Existing Moodboard Popover */}
      <Popover
        open={boardOpen}
        onOpenChange={setBoardOpen}
        anchorEl={boardBtnRef.current}
        placement="top-center"
        className="w-[224px] p-1"
      >
        <div className="flex flex-col gap-0.5">
          {boards.map((b) => (
            <button
              key={b.id}
              type="button"
              onClick={() => {
                setBoardOpen(false);
                void addAssetsToBoard(b.id, selectedAssetIds);
              }}
              className="w-full min-h-[32px] text-left px-2.5 py-1.5 text-[13px] rounded-[var(--win-radius-control)] text-[var(--text-primary)] hover:bg-[var(--win-subtle-hover)] truncate cursor-pointer"
            >
              {b.title}
            </button>
          ))}
        </div>
      </Popover>

      {/* Bulk Permanent Delete Confirmation Modal */}
      <ModalShell
        open={permDeleteIds !== null}
        onClose={() => setPermDeleteIds(null)}
        title={`彻底删除 ${permDeleteIds?.length ?? 0} 项素材？`}
        width="sm"
        footer={
          <>
            <Button variant="standard" onClick={() => setPermDeleteIds(null)}>
              取消
            </Button>
            <Button
              variant="danger"
              onClick={async () => {
                const ids = permDeleteIds ?? [];
                setPermDeleteIds(null);
                if (ids.length > 0) {
                  clearSelection();
                  await permanentlyDeleteAssets(ids, destination);
                }
              }}
            >
              彻底删除
            </Button>
          </>
        }
      >
        <p className="text-[13px] text-[var(--text-secondary)] leading-relaxed charkle-prose">
          彻底删除后将无法从回收站恢复。
        </p>
      </ModalShell>
    </>
  );
};
