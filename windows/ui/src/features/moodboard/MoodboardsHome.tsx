import React, { useEffect, useMemo, useRef, useState } from 'react';
import {
  Add16Regular,
  ArrowCircleDown16Regular,
  Cube16Regular,
  Delete16Regular,
  DocumentText16Regular,
  Edit16Regular,
  Filmstrip16Regular,
  Globe16Regular,
  Image16Regular,
  MusicNote216Regular,
  Star16Filled,
  Star16Regular,
} from '@fluentui/react-icons';
import { getTransport } from '../../api/transport';
import {
  BoardLoadingSkeleton,
  Button,
  CharkleIcon,
  EmptyStateVignette,
  isLightHex,
  ModalShell,
  Popconfirm,
  useDelayedFlag,
} from '../../design-system';
import { useCoordinatorStore, useLibraryStore, useMoodboardStore } from '../../stores';
import { formatWireDate, isAutoEditorialMode, type AssetRecord, type MoodboardSummary } from '../../types/domain';
import { MoodboardGeneratorModal } from './MoodboardGeneratorModal';
import { MoodboardStudioView } from './MoodboardStudioView';

function withCacheBust(url: string, updatedAt: number | string | undefined): string {
  if (!url || url.startsWith('data:') || url.startsWith('blob:') || updatedAt === undefined) {
    return url;
  }
  const sep = url.includes('?') ? '&' : '?';
  return `${url}${sep}v=${encodeURIComponent(String(updatedAt))}`;
}

function renderMosaicFallbackIcon(kind: AssetRecord['mediaKind'] | undefined) {
  switch (kind) {
    case 'video':
    case 'animatedImage':
      return <Filmstrip16Regular className="w-4 h-4" />;
    case 'audio':
      return <MusicNote216Regular className="w-4 h-4" />;
    case 'document':
      return <DocumentText16Regular className="w-4 h-4" />;
    case 'webBookmark':
      return <Globe16Regular className="w-4 h-4" />;
    case 'model3D':
      return <Cube16Regular className="w-4 h-4" />;
    default:
      return <Image16Regular className="w-4 h-4" />;
  }
}

const BoardMosaicTile: React.FC<{
  assetId: string;
  asset?: AssetRecord;
  libraryBootstrapped: boolean;
}> = ({ assetId, asset, libraryBootstrapped }) => {
  const transport = getTransport();
  const isMissing = libraryBootstrapped && !asset;
  const isSwatch = Boolean(asset?.fileName.toLowerCase().endsWith('.swatch'));
  const thumbUrl =
    isMissing || isSwatch
      ? ''
      : withCacheBust(transport.thumbnailUrl(assetId, 'grid520'), asset?.updatedAt);
  const [imgFailed, setImgFailed] = useState(false);

  useEffect(() => {
    setImgFailed(false);
  }, [thumbUrl]);

  const primaryHex = asset?.dominantColors?.[0]?.hex?.trim() || null;
  const secondaryHex = asset?.dominantColors?.[1]?.hex?.trim() || null;
  const swatchHex = (primaryHex || '#64748B').toUpperCase();
  const swatchLight = isLightHex(swatchHex);

  const backdropStyle: React.CSSProperties = isSwatch
    ? { backgroundColor: swatchHex }
    : primaryHex && secondaryHex
      ? { backgroundImage: `linear-gradient(135deg, ${primaryHex}38 0%, ${secondaryHex}28 100%)` }
      : primaryHex
        ? { backgroundColor: `${primaryHex}2C` }
        : {};

  return (
    <div style={backdropStyle} className="w-full h-full bg-[var(--bg-subtle)]">
      {isSwatch ? (
        <div className="w-full h-full flex items-center justify-center px-1">
          <span
            style={{ color: swatchLight ? 'rgba(0,0,0,0.75)' : 'rgba(255,255,255,0.9)' }}
            className="text-[10px] font-semibold charkle-mono"
          >
            {swatchHex}
          </span>
        </div>
      ) : !isMissing && !imgFailed && thumbUrl ? (
        <img
          src={thumbUrl}
          alt=""
          loading="lazy"
          draggable={false}
          onError={() => setImgFailed(true)}
          className="w-full h-full object-cover charkle-media-zoom"
        />
      ) : (
        <div className="w-full h-full flex items-center justify-center text-[var(--text-tertiary)]/75">
          {renderMosaicFallbackIcon(asset?.mediaKind)}
        </div>
      )}
    </div>
  );
};

export const MoodboardsHome: React.FC = () => {
  const destination = useCoordinatorStore((s) => s.destination);
  const setDestination = useCoordinatorStore((s) => s.setDestination);
  const activeMoodboardId = useCoordinatorStore((s) => s.activeMoodboardId);
  const setActiveMoodboardId = useCoordinatorStore((s) => s.setActiveMoodboardId);
  const pushToast = useCoordinatorStore((s) => s.pushToast);

  const allLibraryAssets = useLibraryStore((s) => s.allAssets);
  const filteredLibraryAssets = useLibraryStore((s) => s.assets);
  const libraryBootstrapped = useLibraryStore((s) => s.bootstrapped);
  const libraryAssets = allLibraryAssets.length > 0 ? allLibraryAssets : filteredLibraryAssets;

  const boards = useMoodboardStore((s) => s.boards);
  const activeBoard = useMoodboardStore((s) => s.activeBoard);
  const openBoardFailedId = useMoodboardStore((s) => s.openBoardFailedId);
  const fetchBoards = useMoodboardStore((s) => s.fetchBoards);
  const openBoard = useMoodboardStore((s) => s.openBoard);
  const createBoard = useMoodboardStore((s) => s.createBoard);
  const renameBoard = useMoodboardStore((s) => s.renameBoard);
  const deleteBoard = useMoodboardStore((s) => s.deleteBoard);
  const setBoardPinnedOffline = useMoodboardStore((s) => s.setBoardPinnedOffline);

  const [createOpen, setCreateOpen] = useState(false);
  const [creating, setCreating] = useState(false);
  const [importingPureRef, setImportingPureRef] = useState(false);
  const [generatorOpen, setGeneratorOpen] = useState(false);
  const [titleDraft, setTitleDraft] = useState('');
  const [subtitleDraft, setSubtitleDraft] = useState('');
  const [renamingBoard, setRenamingBoard] = useState<MoodboardSummary | null>(null);
  const [renameTitleDraft, setRenameTitleDraft] = useState('');
  const [renameSubtitleDraft, setRenameSubtitleDraft] = useState('');
  const [renaming, setRenaming] = useState(false);
  const [deletingId, setDeletingId] = useState<string | null>(null);
  const deleteAnchorRef = useRef<HTMLButtonElement | null>(null);

  const assetsById = useMemo(
    () => new Map<string, AssetRecord>(libraryAssets.map((a) => [a.id, a])),
    [libraryAssets],
  );

  useEffect(() => {
    void fetchBoards();
  }, [fetchBoards]);

  useEffect(() => {
    if (destination.type === 'moodboard') {
      // Avoid redundant backend reload right after createBoard / curateMoodboard already hydrated activeBoard
      if (useMoodboardStore.getState().activeBoard?.id !== destination.id) {
        void openBoard(destination.id);
      }
    }
  }, [destination, openBoard]);

  const isBoardLoading =
    destination.type === 'moodboard' &&
    (!activeBoard || activeBoard.id !== destination.id) &&
    openBoardFailedId !== destination.id;
  const showBoardSkeleton = useDelayedFlag(isBoardLoading, 300, 300);

  if (destination.type === 'moodboard') {
    if (activeBoard && activeBoard.id === destination.id) {
      return <MoodboardStudioView />;
    }
    if (openBoardFailedId === destination.id) {
      return (
        <div className="flex-1 min-w-0 min-h-0 flex flex-col items-center justify-center gap-3 bg-[var(--bg-gallery)] p-6 text-center">
          <EmptyStateVignette kind="emptyMoodboards" compact />
          <div className="text-[14px] font-semibold text-[var(--text-primary)]">
            未找到该情绪板
          </div>
          <p className="text-[12px] text-[var(--text-secondary)] max-w-[320px]">
            该情绪板可能已被删除或尚未同步完成。
          </p>
          <Button
            variant="standard"
            size="sm"
            onClick={() => setDestination({ type: 'moodboardsHome' })}
          >
            返回情绪板列表
          </Button>
        </div>
      );
    }
    return (
      <div
        data-testid="moodboard-loading-stage"
        className="flex-1 min-w-0 min-h-0 flex flex-col bg-[var(--bg-gallery)] overflow-hidden"
      >
        {showBoardSkeleton && <BoardLoadingSkeleton />}
      </div>
    );
  }

  const safeBoards = Array.isArray(boards) ? boards : [];

  const closeCreateModal = () => {
    setCreateOpen(false);
    setTitleDraft('');
    setSubtitleDraft('');
  };

  const handleCreateBlank = async () => {
    if (creating) return;
    setCreating(true);
    try {
      const created = await createBoard(titleDraft, subtitleDraft, 'freeform');
      closeCreateModal();
      setDestination({ type: 'moodboard', id: created.id });
    } catch {
      // toast handled in store
    } finally {
      setCreating(false);
    }
  };

  const openRenameModal = (board: MoodboardSummary) => {
    setRenamingBoard(board);
    setRenameTitleDraft(board.title);
    setRenameSubtitleDraft(board.subtitle ?? '');
  };

  const closeRenameModal = () => {
    setRenamingBoard(null);
    setRenameTitleDraft('');
    setRenameSubtitleDraft('');
  };

  const handleCommitRename = async () => {
    if (!renamingBoard || renaming) return;
    setRenaming(true);
    try {
      await renameBoard(renamingBoard.id, renameTitleDraft, renameSubtitleDraft);
      closeRenameModal();
    } finally {
      setRenaming(false);
    }
  };

  return (
    <div
      data-testid="moodboards-home"
      className="flex-1 min-w-0 min-h-0 flex flex-col bg-[var(--bg-gallery)] overflow-hidden"
    >
      <div className="flex-1 overflow-y-auto charkle-scroll p-6">
        <div className="flex flex-col gap-5">
          {/* Header (matching macOS MainWindowView.moodboardsHomeStage) */}
          <div className="flex items-center justify-between gap-3 flex-wrap">
            <div className="min-w-0">
              <h1 className="win-display-title text-[var(--text-primary)]">
                情绪板创作台
              </h1>
              <p className="text-[12.5px] text-[var(--text-secondary)] mt-0.5">
                单源引用素材库 · 无限自由画布与智能灵感策展
              </p>
            </div>

            <div className="flex items-center gap-2 shrink-0">
              <Button
                variant="standard"
                size="sm"
                loading={importingPureRef}
                data-testid="moodboards-import-pureref"
                onClick={() => {
                  if (importingPureRef) return;
                  setImportingPureRef(true);
                  void (async () => {
                    try {
                      const paths = await getTransport().pickPureRefFilesDialog();
                      if (paths.length === 0) return;
                      const results = await useLibraryStore
                        .getState()
                        .importPureRefScenes(paths, null, true, { type: 'moodboardsHome' });
                      await fetchBoards();
                      const first = results[0];
                      const totalImages = results.reduce(
                        (sum, r) => sum + r.importedAssets.length,
                        0,
                      );
                      pushToast({
                        message: `已导入 PureRef 场景（${totalImages} 张图），并生成自由情绪板`,
                        tone: 'success',
                        durationMs: 4200,
                      });
                      if (first?.createdBoardID) {
                        await openBoard(first.createdBoardID);
                        setDestination({ type: 'moodboard', id: first.createdBoardID });
                      }
                    } catch (err) {
                      pushToast({
                        message: `导入 PureRef (.pur) 失败：${err instanceof Error ? err.message : String(err)}`,
                        tone: 'error',
                      });
                    } finally {
                      setImportingPureRef(false);
                    }
                  })();
                }}
              >
                <ArrowCircleDown16Regular className="w-3.5 h-3.5" />
                导入 PureRef (.pur)
              </Button>
              <Button variant="standard" size="sm" onClick={() => setCreateOpen(true)}>
                <Add16Regular className="w-3.5 h-3.5" />
                新建空白板
              </Button>
              <Button
                variant="accent"
                size="sm"
                aria-label="4+1 智能生成"
                onClick={() => setGeneratorOpen(true)}
              >
                <CharkleIcon name="sparkle-board" style="duotone" size={14} />
                智能生成
              </Button>
            </div>
          </div>

          {safeBoards.length === 0 ? (
            <div className="flex flex-col items-center justify-center gap-3.5 text-center py-16">
              <EmptyStateVignette kind="emptyMoodboards" />
              <div className="text-[17px] font-semibold text-[var(--text-primary)]">
                还没有情绪板
              </div>
              <p className="text-[12.5px] text-[var(--text-secondary)] max-w-[380px]">
                通过灵感词、种子图或主色板生成首张可编辑情绪板，或新建一块空白自由画布。
              </p>
              <div className="flex items-center gap-2.5 pt-0.5">
                <Button variant="standard" size="sm" onClick={() => setCreateOpen(true)}>
                  <Add16Regular className="w-3.5 h-3.5" />
                  新建空白板
                </Button>
                <Button variant="accent" size="sm" onClick={() => setGeneratorOpen(true)}>
                  <CharkleIcon name="sparkle-board" style="duotone" size={14} />
                  智能生成情绪板
                </Button>
              </div>
            </div>
          ) : (
            <div
              className="grid gap-4"
              style={{ gridTemplateColumns: 'repeat(auto-fill, minmax(260px, 310px))' }}
            >
              {/* Quick Generate Card (matching macOS MainWindowView.moodboardsHomeStage) */}
              <button
                type="button"
                onClick={() => setGeneratorOpen(true)}
                className="charkle-pressable rounded-[var(--win-radius-card)] bg-[var(--bg-elevated)] border border-dashed border-[var(--accent)]/40 hover:border-[var(--accent)] p-[18px] min-h-[220px] flex flex-col items-center justify-center gap-2.5 text-center cursor-pointer transition-colors duration-150"
              >
                <CharkleIcon name="sparkle-board" style="layered" size={42} />
                <div className="text-[14px] font-semibold text-[var(--text-primary)]">
                  新建灵感情绪板
                </div>
                <p className="text-[11.5px] text-[var(--text-secondary)] max-w-[220px]">
                  支持灵感词 / 种子图 / 配色定调 / 框选成板
                </p>
              </button>

              {safeBoards.map((board) => {
                const isActiveTarget = activeMoodboardId === board.id;
                const isEditorial = board.mode ? isAutoEditorialMode(board.mode) : false;
                const previewIds = Array.isArray(board.previewAssetIDs)
                  ? board.previewAssetIDs.slice(0, 4)
                  : [];
                const paletteHexes = Array.isArray(board.paletteHexes) ? board.paletteHexes : [];

                return (
                  <div
                    key={board.id}
                    onClick={() => setDestination({ type: 'moodboard', id: board.id })}
                    className="group rounded-[var(--win-radius-card)] bg-[var(--bg-elevated)] border border-[var(--win-stroke-card)] hover:border-[var(--border-strong)] p-3 cursor-pointer flex flex-col gap-2.5 shadow-[0_1px_3px_rgba(0,0,0,0.04)] transition-colors duration-150"
                  >
                    {/* True 2×2 Preview Mosaic (h-[132px], resilient to deleted/swatch assets) */}
                    <div className="relative h-[132px] rounded-[var(--win-radius-control)] bg-[var(--bg-subtle)] overflow-hidden">
                      {previewIds.length === 0 ? (
                        <div className="w-full h-full flex items-center justify-center">
                          <CharkleIcon
                            name="moodboard"
                            style="layered"
                            size={32}
                            className="opacity-55"
                          />
                        </div>
                      ) : previewIds.length === 1 ? (
                        <div className="w-full h-full overflow-hidden rounded-[var(--win-radius-control)]">
                          <BoardMosaicTile
                            assetId={previewIds[0]}
                            asset={assetsById.get(previewIds[0])}
                            libraryBootstrapped={libraryBootstrapped}
                          />
                        </div>
                      ) : previewIds.length === 2 ? (
                        <div className="grid grid-cols-2 gap-[3px] h-full">
                          {previewIds.map((aid) => (
                            <div key={aid} className="min-h-0 overflow-hidden rounded-[var(--win-radius-control)]">
                              <BoardMosaicTile
                                assetId={aid}
                                asset={assetsById.get(aid)}
                                libraryBootstrapped={libraryBootstrapped}
                              />
                            </div>
                          ))}
                        </div>
                      ) : (
                        <div className="grid grid-cols-2 grid-rows-2 gap-[3px] h-full">
                          {previewIds.map((aid) => (
                            <div key={aid} className="min-h-0 overflow-hidden rounded-[var(--win-radius-control)]">
                              <BoardMosaicTile
                                assetId={aid}
                                asset={assetsById.get(aid)}
                                libraryBootstrapped={libraryBootstrapped}
                              />
                            </div>
                          ))}
                          {previewIds.length === 3 && (
                            <div className="min-h-0 rounded-[var(--win-radius-control)] bg-[var(--bg-subtle)]" />
                          )}
                        </div>
                      )}
                    </div>

                    {paletteHexes.length > 0 && (
                      <div className="flex items-center gap-[3px]">
                        {paletteHexes.slice(0, 6).map((hex) => (
                          <span
                            key={hex}
                            className="h-2 flex-1 rounded-[2px]"
                            style={{ backgroundColor: hex }}
                          />
                        ))}
                      </div>
                    )}

                    <div className="flex items-start justify-between gap-2">
                      <div className="min-w-0">
                        <div className="flex items-center gap-1.5">
                          <span className="text-[14px] font-semibold text-[var(--text-primary)] truncate">
                            {board.title}
                          </span>
                          {isActiveTarget && (
                            <span className="px-1.5 py-0.5 rounded-[var(--win-radius-control)] bg-[var(--success-soft)] text-[var(--success)] text-[10px] font-semibold shrink-0">
                              活跃板
                            </span>
                          )}
                        </div>
                        {board.subtitle && (
                          <div className="text-[11.5px] text-[var(--text-secondary)] truncate mt-0.5">
                            {board.subtitle}
                          </div>
                        )}
                      </div>

                      <div className="flex items-center gap-0.5 shrink-0">
                        <button
                          type="button"
                          title="重命名情绪板"
                          aria-label={`重命名情绪板 ${board.title}`}
                          onClick={(e) => {
                            e.stopPropagation();
                            openRenameModal(board);
                          }}
                          className="charkle-pressable h-6 w-6 inline-flex items-center justify-center rounded-[var(--win-radius-control)] text-[var(--text-tertiary)] hover:bg-[var(--win-subtle-hover)] hover:text-[var(--text-primary)] cursor-pointer"
                        >
                          <Edit16Regular className="w-3.5 h-3.5" />
                        </button>
                        <button
                          type="button"
                          title={isActiveTarget ? '当前活跃情绪板' : '设为活跃板'}
                          aria-label={`设 ${board.title} 为活跃情绪板`}
                          onClick={(e) => {
                            e.stopPropagation();
                            setActiveMoodboardId(board.id);
                            pushToast({
                              message: `已将「${board.title}」设为活跃情绪板`,
                              tone: 'info',
                              durationMs: 2200,
                            });
                          }}
                          className={[
                            'charkle-pressable h-6 w-6 inline-flex items-center justify-center rounded-[var(--win-radius-control)] cursor-pointer',
                            isActiveTarget
                              ? 'bg-[var(--accent-soft)] text-[var(--accent)]'
                              : 'text-[var(--text-tertiary)] hover:bg-[var(--win-subtle-hover)] hover:text-[var(--text-primary)]',
                          ].join(' ')}
                        >
                          {isActiveTarget ? (
                            <Star16Filled className="w-3.5 h-3.5" />
                          ) : (
                            <Star16Regular className="w-3.5 h-3.5" />
                          )}
                        </button>
                        <button
                          type="button"
                          aria-label="切换始终保留本地"
                          title={board.pinnedOffline ? '已始终保留在本地' : '始终保留在本地'}
                          onClick={(e) => {
                            e.stopPropagation();
                            void setBoardPinnedOffline(board.id, !board.pinnedOffline);
                          }}
                          className={[
                            'charkle-pressable h-6 w-6 inline-flex items-center justify-center rounded-[var(--win-radius-control)] cursor-pointer',
                            board.pinnedOffline
                              ? 'bg-[var(--accent-soft)] text-[var(--accent)]'
                              : 'text-[var(--text-tertiary)] hover:bg-[var(--win-subtle-hover)] hover:text-[var(--text-primary)]',
                          ].join(' ')}
                        >
                          <ArrowCircleDown16Regular className="w-3.5 h-3.5" />
                        </button>
                        <button
                          type="button"
                          aria-label={`删除情绪板 ${board.title}`}
                          onClick={(e) => {
                            e.stopPropagation();
                            deleteAnchorRef.current = e.currentTarget;
                            setDeletingId(board.id);
                          }}
                          className="charkle-pressable h-6 w-6 inline-flex items-center justify-center rounded-[var(--win-radius-control)] text-[var(--text-tertiary)] hover:bg-[var(--danger-soft)] hover:text-[var(--danger)] cursor-pointer"
                        >
                          <Delete16Regular className="w-3.5 h-3.5" />
                        </button>
                      </div>
                    </div>

                    <div className="flex items-center justify-between text-[11px] text-[var(--text-tertiary)]">
                      <div className="flex items-center gap-1.5 text-[11.5px] text-[var(--text-secondary)]">
                        <span className="charkle-tabular">{board.itemCount} 个节点</span>
                        <span className="text-[var(--text-tertiary)]">·</span>
                        <span>{isEditorial ? '自动编排' : '自由画布'}</span>
                      </div>
                      <span>{formatWireDate(board.updatedAt)}</span>
                    </div>
                  </div>
                );
              })}
            </div>
          )}
        </div>
      </div>

      <ModalShell
        open={createOpen}
        onClose={closeCreateModal}
        title="新建空白情绪板"
        width="sm"
        footer={
          <>
            <Button variant="standard" onClick={closeCreateModal}>
              取消
            </Button>
            <Button variant="accent" loading={creating} onClick={() => void handleCreateBlank()}>
              创建并进入画布
            </Button>
          </>
        }
      >
        <div className="flex flex-col gap-3">
          <div className="flex flex-col gap-1">
            <label className="text-[12px] font-medium text-[var(--text-secondary)]">标题</label>
            <input
              type="text"
              value={titleDraft}
              autoFocus
              onChange={(e) => setTitleDraft(e.target.value)}
              onKeyDown={(e) => {
                if (e.key === 'Enter' && !e.nativeEvent.isComposing) void handleCreateBlank();
              }}
              placeholder="例如：春季海报材质与配色…"
              className="win-input-elevation h-8 px-2.5 rounded-[var(--win-radius-control)] bg-[var(--bg-inspector-field)] text-[13px] text-[var(--text-primary)] outline-none"
            />
          </div>
          <div className="flex flex-col gap-1">
            <label className="text-[12px] font-medium text-[var(--text-secondary)]">备注（可选）</label>
            <input
              type="text"
              value={subtitleDraft}
              onChange={(e) => setSubtitleDraft(e.target.value)}
              onKeyDown={(e) => {
                if (e.key === 'Enter' && !e.nativeEvent.isComposing) void handleCreateBlank();
              }}
              placeholder="补充创作方向或氛围备注…"
              className="win-input-elevation h-8 px-2.5 rounded-[var(--win-radius-control)] bg-[var(--bg-inspector-field)] text-[13px] text-[var(--text-primary)] outline-none"
            />
          </div>
        </div>
      </ModalShell>

      <ModalShell
        open={renamingBoard !== null}
        onClose={closeRenameModal}
        title="重命名情绪板"
        width="sm"
        footer={
          <>
            <Button variant="standard" onClick={closeRenameModal}>
              取消
            </Button>
            <Button
              variant="accent"
              loading={renaming}
              disabled={!renameTitleDraft.trim()}
              onClick={() => void handleCommitRename()}
            >
              保存名称
            </Button>
          </>
        }
      >
        <div className="flex flex-col gap-3">
          <div className="flex flex-col gap-1">
            <label className="text-[12px] font-medium text-[var(--text-secondary)]">标题</label>
            <input
              type="text"
              value={renameTitleDraft}
              autoFocus
              onChange={(e) => setRenameTitleDraft(e.target.value)}
              onKeyDown={(e) => {
                if (e.key === 'Enter' && !e.nativeEvent.isComposing && renameTitleDraft.trim()) {
                  void handleCommitRename();
                }
              }}
              placeholder="输入情绪板名称…"
              className="win-input-elevation h-8 px-2.5 rounded-[var(--win-radius-control)] bg-[var(--bg-inspector-field)] text-[13px] text-[var(--text-primary)] outline-none"
            />
          </div>
          <div className="flex flex-col gap-1">
            <label className="text-[12px] font-medium text-[var(--text-secondary)]">备注（可选）</label>
            <input
              type="text"
              value={renameSubtitleDraft}
              onChange={(e) => setRenameSubtitleDraft(e.target.value)}
              onKeyDown={(e) => {
                if (e.key === 'Enter' && !e.nativeEvent.isComposing && renameTitleDraft.trim()) {
                  void handleCommitRename();
                }
              }}
              placeholder="补充创作方向或氛围备注…"
              className="win-input-elevation h-8 px-2.5 rounded-[var(--win-radius-control)] bg-[var(--bg-inspector-field)] text-[13px] text-[var(--text-primary)] outline-none"
            />
          </div>
        </div>
      </ModalShell>

      <MoodboardGeneratorModal
        open={generatorOpen}
        onClose={() => setGeneratorOpen(false)}
      />

      <Popconfirm
        open={deletingId !== null}
        onOpenChange={(open) => {
          if (!open) setDeletingId(null);
        }}
        anchorEl={deleteAnchorRef.current}
        title="删除此情绪板？"
        description="情绪板内的原始素材仍会安全保留在素材库中。"
        confirmLabel="删除"
        onConfirm={() => {
          if (deletingId) void deleteBoard(deletingId);
        }}
      />
    </div>
  );
};
