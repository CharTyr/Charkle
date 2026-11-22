import React, { useEffect, useState } from 'react';
import {
  Check,
  CloudDownload,
  Pencil,
  Plus,
  Sparkles,
  Star,
  Trash2,
} from 'lucide-react';
import { isAutoEditorialMode, isLightHex } from '@charkle/shared';
import type { MoodboardSummary, UUID } from '@charkle/shared';
import { apiClient, thumbnailURL } from '../../api/client';
import { Button } from '../../design-system/Button';
import { CharkleIcon } from '../../design-system/CharkleIcon';
import { useCoordinatorStore } from '../../stores/coordinatorStore';
import { useLibraryStore } from '../../stores/libraryStore';
import { useMoodboardStore } from '../../stores/moodboardStore';
import { formatRelativeDate } from '../settings/shortcuts';

export const MoodboardsHomeView: React.FC = () => {
  const boards = useMoodboardStore((s) => s.boards);
  const loadBoards = useMoodboardStore((s) => s.loadBoards);
  const createBoard = useMoodboardStore((s) => s.createBoard);
  const deleteBoard = useMoodboardStore((s) => s.deleteBoard);
  const openBoard = useMoodboardStore((s) => s.openBoard);

  const activeBoardID = useCoordinatorStore((s) => s.activeBoardID);
  const setActiveBoardID = useCoordinatorStore((s) => s.setActiveBoardID);
  const navigateOpenBoard = useCoordinatorStore((s) => s.openBoard);
  const openGeneratorModal = useCoordinatorStore((s) => s.openGeneratorModal);
  const pushToast = useCoordinatorStore((s) => s.pushToast);

  const cacheBustVersion = useLibraryStore((s) => s.cacheBustVersion);

  const [creating, setCreating] = useState(false);
  const [renamingID, setRenamingID] = useState<UUID | null>(null);
  const [renameDraft, setRenameDraft] = useState('');
  const [confirmDeleteID, setConfirmDeleteID] = useState<UUID | null>(null);

  useEffect(() => {
    void loadBoards();
  }, [loadBoards]);

  const handleCreateBlank = async () => {
    setCreating(true);
    try {
      const board = await createBoard(`未命名情绪板 ${boards.length + 1}`, '');
      navigateOpenBoard(board.id);
    } catch (err) {
      pushToast({
        tone: 'error',
        message: err instanceof Error ? err.message : '新建情绪板失败',
      });
    } finally {
      setCreating(false);
    }
  };

  const handleOpen = async (id: UUID) => {
    navigateOpenBoard(id);
    await openBoard(id);
  };

  const handleCommitRename = async (board: MoodboardSummary) => {
    const trimmed = renameDraft.trim();
    setRenamingID(null);
    if (!trimmed || trimmed === board.title) return;
    try {
      const res = await apiClient.getBoard(board.id);
      await apiClient.saveBoard(board.id, {
        ...res.board,
        title: trimmed,
        updatedAt: new Date().toISOString(),
      });
      await loadBoards();
      pushToast({ tone: 'success', message: `已重命名为「${trimmed}」` });
    } catch (err) {
      pushToast({
        tone: 'error',
        message: err instanceof Error ? err.message : '重命名失败',
      });
    }
  };

  const handleToggleOfflinePin = async (board: MoodboardSummary, e: React.MouseEvent) => {
    e.stopPropagation();
    try {
      const res = await apiClient.getBoard(board.id);
      const nextPinned = !res.board.pinnedOffline;
      await apiClient.saveBoard(board.id, {
        ...res.board,
        pinnedOffline: nextPinned,
        updatedAt: new Date().toISOString(),
      });
      await loadBoards();
      pushToast({
        tone: 'success',
        message: nextPinned ? `已为「${board.title}」开启离线保留` : '已取消离线保留',
      });
    } catch (err) {
      pushToast({
        tone: 'error',
        message: err instanceof Error ? err.message : '更新离线状态失败',
      });
    }
  };

  const handleDelete = async (board: MoodboardSummary) => {
    setConfirmDeleteID(null);
    try {
      await deleteBoard(board.id);
      pushToast({ tone: 'info', message: `已删除情绪板「${board.title}」` });
    } catch (err) {
      pushToast({
        tone: 'error',
        message: err instanceof Error ? err.message : '删除情绪板失败',
      });
    }
  };

  return (
    <div className="h-full w-full flex flex-col bg-[var(--bg-gallery)] overflow-hidden">
      {/* Clean Studio Header */}
      <header className="px-6 py-4 border-b border-[var(--border-hairline)] flex flex-wrap items-center justify-between gap-4 shrink-0">
        <div className="flex items-center gap-3 min-w-0">
          <CharkleIcon name="moodboard" style="layered" size={30} />
          <div className="min-w-0">
            <h1 className="text-[17px] font-semibold tracking-[-0.015em] text-[var(--text-primary)]">
              情绪板工作室
            </h1>
            <p className="text-[12px] text-[var(--text-secondary)]">
              自动编辑部排版与无限自由画布无缝切换 · 共 {boards.length} 块情绪板
            </p>
          </div>
        </div>

        <div className="flex items-center gap-2 shrink-0">
          <Button variant="secondary" size="sm" loading={creating} onClick={handleCreateBlank}>
            <Plus size={14} />
            新建空白板
          </Button>
          <Button variant="primary" size="sm" onClick={() => openGeneratorModal([])}>
            <Sparkles size={14} />
            AI 生成情绪板
          </Button>
        </div>
      </header>

      {/* Gallery Grid */}
      <div className="flex-1 min-h-0 overflow-y-auto charkle-scroll px-6 py-6">
        {boards.length === 0 ? (
          <div className="h-full min-h-[380px] flex flex-col items-center justify-center text-center max-w-md mx-auto gap-4">
            <CharkleIcon name="moodboard" style="layered" size={64} />
            <div>
              <h2 className="text-[16px] font-semibold text-[var(--text-primary)]">
                开始你的第一块情绪板
              </h2>
              <p className="text-[13px] text-[var(--text-secondary)] mt-1.5 leading-relaxed">
                用自然语言、种子图或目标色卡让 AI 视觉策展，或直接新建空白画布自由拼贴、连线与批注。
              </p>
            </div>
            <div className="flex items-center gap-2.5 pt-1">
              <Button variant="secondary" size="md" loading={creating} onClick={handleCreateBlank}>
                <Plus size={15} />
                新建空白板
              </Button>
              <Button variant="primary" size="md" onClick={() => openGeneratorModal([])}>
                <Sparkles size={15} />
                AI 生成情绪板
              </Button>
            </div>
          </div>
        ) : (
          <div className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 xl:grid-cols-4 gap-5">
            {boards.map((board) => {
              const isActiveTarget = activeBoardID === board.id;
              const isAuto = isAutoEditorialMode(board.mode);
              const isRenaming = renamingID === board.id;
              const isConfirmingDelete = confirmDeleteID === board.id;

              return (
                <article
                  key={board.id}
                  onClick={() => {
                    if (!isRenaming && !isConfirmingDelete) {
                      void handleOpen(board.id);
                    }
                  }}
                  className="group relative flex flex-col rounded-[var(--radius-card-outer)] bg-[var(--bg-elevated)] border border-[var(--border-hairline)] hover:border-[var(--border-strong)] shadow-xs transition-[border-color,box-shadow] duration-150 cursor-pointer overflow-hidden"
                >
                  {/* 4-Up Visual Collage Preview */}
                  <div className="relative aspect-[16/10] w-full bg-[var(--bg-subtle)] p-1.5">
                    {board.previewAssetIDs.length === 0 ? (
                      <div className="w-full h-full rounded-[8px] flex flex-col items-center justify-center gap-1.5 text-[var(--text-tertiary)] border border-dashed border-[var(--border-strong)]">
                        <CharkleIcon name="moodboard" size={22} />
                        <span className="text-[11px]">空白情绪板</span>
                      </div>
                    ) : board.previewAssetIDs.length === 1 ? (
                      <div className="w-full h-full rounded-[8px] overflow-hidden">
                        <img
                          src={thumbnailURL(board.previewAssetIDs[0], 'grid520', cacheBustVersion)}
                          alt=""
                          className="w-full h-full object-cover charkle-media-zoom"
                        />
                      </div>
                    ) : (
                      <div className="w-full h-full grid grid-cols-2 grid-rows-2 gap-1 rounded-[8px] overflow-hidden">
                        {Array.from({ length: 4 }).map((_, idx) => {
                          const aid = board.previewAssetIDs[idx];
                          return (
                            <div
                              key={idx}
                              className="w-full h-full bg-[var(--bg-gallery)] overflow-hidden"
                            >
                              {aid ? (
                                <img
                                  src={thumbnailURL(aid, 'grid520', cacheBustVersion)}
                                  alt=""
                                  loading="lazy"
                                  className="w-full h-full object-cover charkle-media-zoom"
                                />
                              ) : null}
                            </div>
                          );
                        })}
                      </div>
                    )}

                    {/* Top-left Active Board / Mode Badge */}
                    <div className="absolute top-3 left-3 flex items-center gap-1.5">
                      <span className="px-2 py-0.5 rounded-[var(--radius-card-inner)] bg-black/58 text-white text-[10px] font-medium backdrop-blur-sm">
                        {isAuto ? '自动排版' : '自由画布'}
                      </span>
                      {isActiveTarget && (
                        <span className="inline-flex items-center gap-1 px-2 py-0.5 rounded-[var(--radius-card-inner)] bg-[var(--success)] text-white text-[10px] font-semibold">
                          <span className="w-1.5 h-1.5 rounded-full bg-white" />
                          活跃采集目标
                        </span>
                      )}
                    </div>

                    {/* Top-right hover actions */}
                    <div
                      onClick={(e) => e.stopPropagation()}
                      className={[
                        'absolute top-3 right-3 flex items-center gap-1 transition-opacity duration-150',
                        isActiveTarget || board.pinnedOffline
                          ? 'opacity-100'
                          : 'opacity-0 group-hover:opacity-100 group-focus-within:opacity-100 [@media(hover:none)]:opacity-100',
                      ].join(' ')}
                    >
                      <button
                        type="button"
                        onClick={(e) => {
                          e.stopPropagation();
                          setActiveBoardID(isActiveTarget ? null : board.id);
                          pushToast({
                            tone: 'success',
                            message: isActiveTarget
                              ? '已取消当前活跃情绪板'
                              : `已将「${board.title}」设为快速采集目标情绪板`,
                          });
                        }}
                        title={isActiveTarget ? '当前活跃情绪板' : '设为当前活跃情绪板'}
                        aria-label={isActiveTarget ? '取消活跃情绪板' : '设为当前活跃情绪板'}
                        className={[
                          'charkle-pressable w-7 h-7 rounded-[var(--radius-card-inner)] inline-flex items-center justify-center cursor-pointer',
                          isActiveTarget
                            ? 'bg-[#E5B243] text-[#18191C]'
                            : 'bg-black/58 text-white hover:bg-black/75',
                        ].join(' ')}
                      >
                        <Star size={13} fill={isActiveTarget ? 'currentColor' : 'none'} />
                      </button>

                      <button
                        type="button"
                        onClick={(e) => handleToggleOfflinePin(board, e)}
                        title={board.pinnedOffline ? '已离线保留（点击取消）' : '开启离线保留'}
                        aria-label="切换离线保留"
                        className={[
                          'charkle-pressable w-7 h-7 rounded-[var(--radius-card-inner)] inline-flex items-center justify-center cursor-pointer',
                          board.pinnedOffline
                            ? 'bg-[var(--accent)] text-white'
                            : 'bg-black/58 text-white hover:bg-black/75',
                        ].join(' ')}
                      >
                        <CloudDownload size={13} />
                      </button>
                    </div>
                  </div>

                  {/* Extracted Palette Strip */}
                  {board.paletteHexes.length > 0 && (
                    <div className="flex h-2 w-full">
                      {board.paletteHexes.slice(0, 6).map((hex) => (
                        <div
                          key={hex}
                          className="flex-1 h-full"
                          style={{
                            backgroundColor: hex,
                            boxShadow: isLightHex(hex)
                              ? 'inset 0 0 0 0.5px rgba(0,0,0,0.08)'
                              : undefined,
                          }}
                          title={hex.toUpperCase()}
                        />
                      ))}
                    </div>
                  )}

                  {/* Footer Meta */}
                  <div className="p-3.5 flex flex-col gap-2">
                    <div className="flex items-start justify-between gap-2">
                      {isRenaming ? (
                        <form
                          onSubmit={(e) => {
                            e.preventDefault();
                            void handleCommitRename(board);
                          }}
                          onClick={(e) => e.stopPropagation()}
                          className="flex items-center gap-1 flex-1 min-w-0"
                        >
                          <input
                            type="text"
                            autoFocus
                            value={renameDraft}
                            onChange={(e) => setRenameDraft(e.target.value)}
                            onBlur={() => void handleCommitRename(board)}
                            onKeyDown={(e) => {
                              if (e.key === 'Escape') setRenamingID(null);
                            }}
                            className="flex-1 min-w-0 h-7 px-2 rounded-[6px] bg-[var(--bg-subtle)] border border-[var(--accent)] text-[13px] font-semibold text-[var(--text-primary)] outline-none"
                          />
                          <button
                            type="submit"
                            aria-label="确认重命名"
                            className="w-7 h-7 rounded-[6px] inline-flex items-center justify-center bg-[var(--accent)] text-white cursor-pointer"
                          >
                            <Check size={13} />
                          </button>
                        </form>
                      ) : (
                        <div className="min-w-0 flex-1">
                          <h3 className="text-[14px] font-semibold text-[var(--text-primary)] truncate">
                            {board.title}
                          </h3>
                          {board.subtitle && (
                            <p className="text-[11.5px] text-[var(--text-secondary)] truncate mt-0.5">
                              {board.subtitle}
                            </p>
                          )}
                        </div>
                      )}

                      {!isRenaming && !isConfirmingDelete && (
                        <div
                          onClick={(e) => e.stopPropagation()}
                          className="flex items-center gap-0.5 opacity-0 group-hover:opacity-100 group-focus-within:opacity-100 [@media(hover:none)]:opacity-100 transition-opacity duration-150 shrink-0"
                        >
                          <button
                            type="button"
                            onClick={() => {
                              setRenamingID(board.id);
                              setRenameDraft(board.title);
                            }}
                            aria-label="重命名情绪板"
                            title="重命名"
                            className="charkle-pressable w-7 h-7 rounded-[6px] inline-flex items-center justify-center text-[var(--text-secondary)] hover:text-[var(--text-primary)] hover:bg-[var(--bg-subtle)] cursor-pointer"
                          >
                            <Pencil size={12} />
                          </button>
                          <button
                            type="button"
                            onClick={() => setConfirmDeleteID(board.id)}
                            aria-label="删除情绪板"
                            title="删除情绪板"
                            className="charkle-pressable w-7 h-7 rounded-[6px] inline-flex items-center justify-center text-[var(--text-secondary)] hover:text-[var(--danger)] hover:bg-[var(--danger-soft)] cursor-pointer"
                          >
                            <Trash2 size={12} />
                          </button>
                        </div>
                      )}
                    </div>

                    {isConfirmingDelete ? (
                      <div
                        onClick={(e) => e.stopPropagation()}
                        className="flex items-center justify-between gap-2 pt-1 border-t border-[var(--border-hairline)]"
                      >
                        <span className="text-[11.5px] text-[var(--danger)] font-medium">
                          确定删除此板？
                        </span>
                        <div className="flex items-center gap-1.5">
                          <Button
                            variant="ghost"
                            size="xs"
                            onClick={() => setConfirmDeleteID(null)}
                          >
                            取消
                          </Button>
                          <Button
                            variant="danger"
                            size="xs"
                            onClick={() => void handleDelete(board)}
                          >
                            确认删除
                          </Button>
                        </div>
                      </div>
                    ) : (
                      <div className="flex items-center justify-between text-[11.5px] text-[var(--text-tertiary)] pt-0.5">
                        <span className="tabular-nums">{board.itemCount} 个元素</span>
                        <span>更新于 {formatRelativeDate(board.updatedAt)}</span>
                      </div>
                    )}
                  </div>
                </article>
              );
            })}
          </div>
        )}
      </div>
    </div>
  );
};
