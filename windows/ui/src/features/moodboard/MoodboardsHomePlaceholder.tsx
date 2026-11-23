import React, { useEffect, useRef, useState } from 'react';
import { ArrowLeft, Pin, Plus, Trash2 } from 'lucide-react';
import { getTransport } from '../../api/transport';
import {
  Button,
  EmptyStateVignette,
  ModalShell,
  Popconfirm,
} from '../../design-system';
import { useCoordinatorStore, useMoodboardStore } from '../../stores';
import { formatWireDate } from '../../types/domain';

export const MoodboardsHomePlaceholder: React.FC = () => {
  const destination = useCoordinatorStore((s) => s.destination);
  const setDestination = useCoordinatorStore((s) => s.setDestination);

  const boards = useMoodboardStore((s) => s.boards);
  const activeBoard = useMoodboardStore((s) => s.activeBoard);
  const fetchBoards = useMoodboardStore((s) => s.fetchBoards);
  const openBoard = useMoodboardStore((s) => s.openBoard);
  const createBoard = useMoodboardStore((s) => s.createBoard);
  const deleteBoard = useMoodboardStore((s) => s.deleteBoard);
  const setBoardPinnedOffline = useMoodboardStore((s) => s.setBoardPinnedOffline);

  const [createOpen, setCreateOpen] = useState(false);
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

  const transport = getTransport();

  if (destination.type === 'moodboard' && activeBoard) {
    return (
      <div className="flex-1 min-h-0 flex flex-col bg-[var(--bg-gallery)] overflow-hidden">
        <div className="px-6 py-4 flex items-center justify-between border-b border-[var(--border-hairline)]">
          <div className="flex items-center gap-3 min-w-0">
            <Button
              variant="ghost"
              size="xs"
              onClick={() => setDestination({ type: 'moodboardsHome' })}
            >
              <ArrowLeft size={14} />
              返回情绪板列表
            </Button>
            <div className="min-w-0">
              <h1 className="text-[16px] font-semibold text-[var(--text-primary)] truncate">
                {activeBoard.title}
              </h1>
              {activeBoard.subtitle && (
                <p className="text-[12px] text-[var(--text-secondary)] truncate">
                  {activeBoard.subtitle}
                </p>
              )}
            </div>
          </div>

          <Button
            variant={activeBoard.pinnedOffline ? 'primary' : 'secondary'}
            size="xs"
            onClick={() => void setBoardPinnedOffline(activeBoard.id, !activeBoard.pinnedOffline)}
          >
            <Pin size={13} />
            {activeBoard.pinnedOffline ? '已离线常驻' : '离线常驻'}
          </Button>
        </div>

        <div className="flex-1 overflow-y-auto charkle-scroll p-6">
          <div className="max-w-[880px] mx-auto flex flex-col gap-5">
            <div className="p-4 rounded-[var(--radius-settings-outer)] bg-[var(--bg-elevated)] border border-[var(--border-hairline)] flex items-center justify-between gap-4">
              <div>
                <div className="text-[13.5px] font-semibold text-[var(--text-primary)]">
                  已收录 {activeBoard.candidateAssetIDs.length} 项候选素材 · {activeBoard.nodes.length} 个画布节点
                </div>
                <p className="mt-1 text-[12px] text-[var(--text-secondary)] charkle-prose">
                  自由拼贴画布与编排视图将在后续里程碑上线，当前可继续从画廊与收件箱向此情绪板归集灵感素材。
                </p>
              </div>
              {activeBoard.extractedPalette.length > 0 && (
                <div className="flex items-center gap-1 shrink-0">
                  {activeBoard.extractedPalette.slice(0, 6).map((c) => (
                    <span
                      key={c.hex}
                      title={c.hex}
                      className="h-5 w-5 rounded-full border border-black/10"
                      style={{ backgroundColor: c.hex }}
                    />
                  ))}
                </div>
              )}
            </div>

            {activeBoard.candidateAssetIDs.length > 0 ? (
              <div className="grid grid-cols-2 sm:grid-cols-3 md:grid-cols-4 gap-3">
                {activeBoard.candidateAssetIDs.map((assetId) => (
                  <div
                    key={assetId}
                    className="aspect-[4/3] rounded-[var(--radius-card-outer)] overflow-hidden bg-[var(--bg-elevated)] border border-[var(--border-hairline)]"
                  >
                    <img
                      src={transport.thumbnailUrl(assetId, 'grid520')}
                      alt=""
                      className="w-full h-full object-cover"
                    />
                  </div>
                ))}
              </div>
            ) : (
              <div className="py-12 flex flex-col items-center gap-3 text-center">
                <EmptyStateVignette kind="emptyMoodboards" />
                <div className="text-[14px] font-semibold text-[var(--text-primary)]">
                  情绪板尚无素材
                </div>
                <p className="text-[12.5px] text-[var(--text-secondary)] max-w-[320px]">
                  在画廊右键卡片或收件箱中点击「发送至情绪板」，即可将参考素材添加到此处。
                </p>
              </div>
            )}
          </div>
        </div>
      </div>
    );
  }

  return (
    <div className="flex-1 min-h-0 flex flex-col bg-[var(--bg-gallery)] overflow-hidden">
      <div className="px-6 py-4 flex items-center justify-between border-b border-[var(--border-hairline)]">
        <div>
          <h1 className="text-[17px] font-semibold tracking-[-0.01em] text-[var(--text-primary)]">
            情绪板
          </h1>
          <p className="text-[12px] text-[var(--text-secondary)] mt-0.5">
            围绕项目与视觉主题策展参考色板与素材集合
          </p>
        </div>
        <Button variant="primary" size="sm" onClick={() => setCreateOpen(true)}>
          <Plus size={14} />
          新建情绪板
        </Button>
      </div>

      <div className="flex-1 overflow-y-auto charkle-scroll p-6">
        {boards.length === 0 ? (
          <div className="h-full flex flex-col items-center justify-center gap-3 text-center py-12">
            <EmptyStateVignette kind="emptyMoodboards" />
            <div className="text-[14px] font-semibold text-[var(--text-primary)]">
              还没有情绪板
            </div>
            <p className="text-[12.5px] text-[var(--text-secondary)] max-w-[320px]">
              新建一块情绪板，把零散的配色、摄影与界面灵感组织成统一视觉方向。
            </p>
            <Button variant="primary" size="sm" onClick={() => setCreateOpen(true)}>
              <Plus size={14} />
              创建第一块情绪板
            </Button>
          </div>
        ) : (
          <div className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 gap-4">
            {boards.map((board) => (
              <div
                key={board.id}
                onClick={() => setDestination({ type: 'moodboard', id: board.id })}
                className="group rounded-[var(--radius-settings-outer)] bg-[var(--bg-elevated)] border border-[var(--border-hairline)] hover:border-[var(--border-strong)] overflow-hidden cursor-pointer flex flex-col transition-colors duration-150"
              >
                <div className="aspect-[16/10] bg-[var(--bg-subtle)] grid grid-cols-2 gap-0.5 overflow-hidden">
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
                    <span className="charkle-tabular">{board.itemCount} 项素材</span>
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
            ))}
          </div>
        )}
      </div>

      <ModalShell
        open={createOpen}
        onClose={() => setCreateOpen(false)}
        title="新建情绪板"
        width="sm"
        footer={
          <>
            <Button variant="secondary" onClick={() => setCreateOpen(false)}>
              取消
            </Button>
            <Button
              variant="primary"
              onClick={async () => {
                await createBoard(titleDraft, subtitleDraft);
                setTitleDraft('');
                setSubtitleDraft('');
                setCreateOpen(false);
              }}
            >
              创建
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
