import React, { useEffect, useRef, useState } from 'react';
import { Layers, LayoutGrid, Pin, Plus, Sparkles, Star, Trash2 } from 'lucide-react';
import { getTransport } from '../../api/transport';
import {
  Button,
  EmptyStateVignette,
  ModalShell,
  Popconfirm,
} from '../../design-system';
import { useCoordinatorStore, useMoodboardStore } from '../../stores';
import { formatWireDate, isAutoEditorialMode } from '../../types/domain';
import { MoodboardGeneratorModal } from './MoodboardGeneratorModal';
import { MoodboardStudioView } from './MoodboardStudioView';

export const MoodboardsHome: React.FC = () => {
  const destination = useCoordinatorStore((s) => s.destination);
  const setDestination = useCoordinatorStore((s) => s.setDestination);
  const activeMoodboardId = useCoordinatorStore((s) => s.activeMoodboardId);
  const setActiveMoodboardId = useCoordinatorStore((s) => s.setActiveMoodboardId);
  const pushToast = useCoordinatorStore((s) => s.pushToast);

  const boards = useMoodboardStore((s) => s.boards);
  const activeBoard = useMoodboardStore((s) => s.activeBoard);
  const fetchBoards = useMoodboardStore((s) => s.fetchBoards);
  const openBoard = useMoodboardStore((s) => s.openBoard);
  const createBoard = useMoodboardStore((s) => s.createBoard);
  const deleteBoard = useMoodboardStore((s) => s.deleteBoard);
  const setBoardPinnedOffline = useMoodboardStore((s) => s.setBoardPinnedOffline);

  const [createOpen, setCreateOpen] = useState(false);
  const [generatorOpen, setGeneratorOpen] = useState(false);
  const [titleDraft, setTitleDraft] = useState('');
  const [subtitleDraft, setSubtitleDraft] = useState('');
  const [deletingId, setDeletingId] = useState<string | null>(null);
  const deleteAnchorRef = useRef<HTMLButtonElement | null>(null);

  useEffect(() => {
    void fetchBoards();
  }, [fetchBoards]);

  useEffect(() => {
    if (destination.type === 'moodboard') {
      void openBoard(destination.id);
    }
  }, [destination, openBoard]);

  if (destination.type === 'moodboard' && activeBoard) {
    return <MoodboardStudioView />;
  }

  const transport = getTransport();

  return (
    <div
      data-testid="moodboards-home"
      className="flex-1 min-h-0 flex flex-col bg-[var(--bg-gallery)] overflow-hidden"
    >
      <div className="px-6 py-4 flex items-center justify-between gap-3 border-b border-[var(--border-hairline)]">
        <div>
          <h1 className="text-[17px] font-semibold tracking-[-0.01em] text-[var(--text-primary)]">
            情绪板工作室
          </h1>
          <p className="text-[12px] text-[var(--text-secondary)] mt-0.5">
            10 秒智能生成、自动编排与自由无限画布零跳变切换，支持离线无损导出至 Figma / FigJam
          </p>
        </div>

        <div className="flex items-center gap-2 shrink-0">
          <Button variant="secondary" size="sm" onClick={() => setCreateOpen(true)}>
            <Plus size={14} />
            空白情绪板
          </Button>
          <Button variant="primary" size="sm" onClick={() => setGeneratorOpen(true)}>
            <Sparkles size={14} />
            4+1 智能生成
          </Button>
        </div>
      </div>

      <div className="flex-1 overflow-y-auto charkle-scroll p-6">
        {boards.length === 0 ? (
          <div className="h-full flex flex-col items-center justify-center gap-3 text-center py-12">
            <EmptyStateVignette kind="emptyMoodboards" />
            <div className="text-[14px] font-semibold text-[var(--text-primary)]">
              还没有情绪板
            </div>
            <p className="text-[12.5px] text-[var(--text-secondary)] max-w-[340px]">
              用主题词、种子图或目标色板 10 秒生成首张灵感情绪板，或新建一块空白自由画布。
            </p>
            <div className="flex items-center gap-2">
              <Button variant="primary" size="sm" onClick={() => setGeneratorOpen(true)}>
                <Sparkles size={14} />
                智能生成第一块情绪板
              </Button>
              <Button variant="secondary" size="sm" onClick={() => setCreateOpen(true)}>
                <Plus size={14} />
                新建空白板
              </Button>
            </div>
          </div>
        ) : (
          <div className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 gap-4">
            {boards.map((board) => {
              const isActiveTarget = activeMoodboardId === board.id;
              const isEditorial = board.mode ? isAutoEditorialMode(board.mode) : false;

              return (
                <div
                  key={board.id}
                  onClick={() => setDestination({ type: 'moodboard', id: board.id })}
                  className="group rounded-[var(--radius-settings-outer)] bg-[var(--bg-elevated)] border border-[var(--border-hairline)] hover:border-[var(--border-strong)] overflow-hidden cursor-pointer flex flex-col transition-colors duration-150"
                >
                  <div className="relative aspect-[16/10] bg-[var(--bg-subtle)] grid grid-cols-2 gap-0.5 overflow-hidden">
                    {board.previewAssetIDs.length > 0 ? (
                      board.previewAssetIDs.slice(0, 4).map((aid) => (
                        <img
                          key={aid}
                          src={transport.thumbnailUrl(aid, 'grid520')}
                          alt=""
                          className="w-full h-full object-cover charkle-media-zoom"
                        />
                      ))
                    ) : (
                      <div className="col-span-2 flex items-center justify-center">
                        <EmptyStateVignette kind="emptyMoodboards" className="scale-75 opacity-80" />
                      </div>
                    )}

                    <span className="absolute top-2 left-2 px-2 py-0.5 rounded-full bg-black/55 text-white text-[10.5px] inline-flex items-center gap-1">
                      {isEditorial ? <LayoutGrid size={10.5} /> : <Layers size={10.5} />}
                      {isEditorial ? '自动编排' : '自由画布'}
                    </span>

                    {isActiveTarget && (
                      <span className="absolute top-2 right-2 px-2 py-0.5 rounded-full bg-[var(--accent)] text-white text-[10.5px] font-medium">
                        当前活跃
                      </span>
                    )}
                  </div>

                  <div className="p-3.5 flex flex-col gap-2">
                    <div className="flex items-start justify-between gap-2">
                      <div className="min-w-0">
                        <div className="text-[13.5px] font-semibold text-[var(--text-primary)] truncate">
                          {board.title}
                        </div>
                        {board.subtitle && (
                          <div className="text-[11.5px] text-[var(--text-secondary)] truncate mt-0.5">
                            {board.subtitle}
                          </div>
                        )}
                      </div>

                      <div className="flex items-center gap-1 shrink-0">
                        <button
                          type="button"
                          title={isActiveTarget ? '当前活跃情绪板' : '设为活跃情绪板（接收抽屉与截图投递）'}
                          aria-label={`设 ${board.title} 为活跃情绪板`}
                          onClick={(e) => {
                            e.stopPropagation();
                            setActiveMoodboardId(board.id);
                            pushToast({
                              message: `已将「${board.title}」设为当前活跃情绪板`,
                              tone: 'info',
                              durationMs: 2200,
                            });
                          }}
                          className={[
                            'charkle-pressable h-6 w-6 inline-flex items-center justify-center rounded-[var(--radius-card-inner)] cursor-pointer',
                            isActiveTarget
                              ? 'bg-[var(--accent-soft)] text-[var(--accent)]'
                              : 'text-[var(--text-tertiary)] hover:bg-[var(--bg-subtle)] hover:text-[var(--text-primary)]',
                          ].join(' ')}
                        >
                          <Star size={12.5} className={isActiveTarget ? 'fill-current' : ''} />
                        </button>
                        <button
                          type="button"
                          aria-label="切换离线常驻"
                          onClick={(e) => {
                            e.stopPropagation();
                            void setBoardPinnedOffline(board.id, !board.pinnedOffline);
                          }}
                          className={[
                            'charkle-pressable h-6 w-6 inline-flex items-center justify-center rounded-[var(--radius-card-inner)] cursor-pointer',
                            board.pinnedOffline
                              ? 'bg-[var(--accent-soft)] text-[var(--accent)]'
                              : 'text-[var(--text-tertiary)] hover:bg-[var(--bg-subtle)] hover:text-[var(--text-primary)]',
                          ].join(' ')}
                        >
                          <Pin size={12.5} />
                        </button>
                        <button
                          type="button"
                          aria-label={`删除情绪板 ${board.title}`}
                          onClick={(e) => {
                            e.stopPropagation();
                            deleteAnchorRef.current = e.currentTarget;
                            setDeletingId(board.id);
                          }}
                          className="charkle-pressable h-6 w-6 inline-flex items-center justify-center rounded-[var(--radius-card-inner)] text-[var(--text-tertiary)] hover:bg-[var(--danger-soft)] hover:text-[var(--danger)] cursor-pointer"
                        >
                          <Trash2 size={12.5} />
                        </button>
                      </div>
                    </div>

                    <div className="flex items-center justify-between text-[11px] text-[var(--text-tertiary)]">
                      <span className="charkle-tabular">{board.itemCount} 个对象</span>
                      <span>更新于 {formatWireDate(board.updatedAt)}</span>
                    </div>

                    {board.paletteHexes.length > 0 && (
                      <div className="flex items-center gap-1 pt-0.5">
                        {board.paletteHexes.slice(0, 6).map((hex) => (
                          <span
                            key={hex}
                            className="h-2.5 flex-1 rounded-full"
                            style={{ backgroundColor: hex }}
                          />
                        ))}
                      </div>
                    )}
                  </div>
                </div>
              );
            })}
          </div>
        )}
      </div>

      <ModalShell
        open={createOpen}
        onClose={() => setCreateOpen(false)}
        title="新建空白情绪板"
        width="sm"
        footer={
          <>
            <Button variant="secondary" onClick={() => setCreateOpen(false)}>
              取消
            </Button>
            <Button
              variant="primary"
              onClick={async () => {
                const created = await createBoard(titleDraft, subtitleDraft, 'autoEditorial');
                setTitleDraft('');
                setSubtitleDraft('');
                setCreateOpen(false);
                setDestination({ type: 'moodboard', id: created.id });
              }}
            >
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
              placeholder="例如：春季海报材质与配色…"
              className="h-9 px-3 rounded-[var(--radius-settings-inner)] bg-[var(--bg-inspector-field)] border border-[var(--border-hairline)] text-[13px] text-[var(--text-primary)] outline-none focus:border-[var(--accent)]"
            />
          </div>
          <div className="flex flex-col gap-1">
            <label className="text-[12px] font-medium text-[var(--text-secondary)]">副标题（可选）</label>
            <input
              type="text"
              value={subtitleDraft}
              onChange={(e) => setSubtitleDraft(e.target.value)}
              placeholder="简述情绪板主题…"
              className="h-9 px-3 rounded-[var(--radius-settings-inner)] bg-[var(--bg-inspector-field)] border border-[var(--border-hairline)] text-[13px] text-[var(--text-primary)] outline-none focus:border-[var(--accent)]"
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
