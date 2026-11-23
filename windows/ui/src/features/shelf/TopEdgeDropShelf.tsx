import React, { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import {
  Camera,
  Check,
  Clipboard,
  ExternalLink,
  Folder,
  Inbox,
  LayoutGrid,
  Maximize2,
  Minimize2,
  Pin,
  Search,
  Share2,
  Upload,
  X,
} from 'lucide-react';
import { getTransport } from '../../api/transport';
import { CharkleBrandMark, CustomSelect, type SelectOption } from '../../design-system';
import {
  buildFolderTree,
  createDefaultFilterCriteria,
  flattenFolderTree,
  type AssetRecord,
  type ClipboardPreview,
  type FolderRecord,
  type MoodboardSummary,
  type ShelfTargetMode,
} from '../../types/domain';

export interface TopEdgeDropShelfProps {
  initialFullGallery?: boolean;
}

/**
 * Windows Top-Edge Drop Shelf (`shelf.html`):
 * Non-focus-stealing pure-black frosted capsule anchored top-center with dynamic
 * `WM_NCHITTEST` hit-rect reporting, Compact + Expanded Full-Waterfall dual states,
 * target routing (`收件箱 / 指定文件夹 / 当前活跃情绪板`), live clipboard quick-collect chip,
 * and native Win32 OLE `DoDragDrop` outbound file dragging.
 */
export const TopEdgeDropShelf: React.FC<TopEdgeDropShelfProps> = ({
  initialFullGallery = false,
}) => {
  const capsuleRef = useRef<HTMLDivElement | null>(null);
  const [fullGallery, setFullGallery] = useState(initialFullGallery);
  const [pinned, setPinned] = useState(false);
  const [targetMode, setTargetMode] = useState<ShelfTargetMode>('inbox');
  const [selectedFolderId, setSelectedFolderId] = useState<string>('');
  const [assets, setAssets] = useState<AssetRecord[]>([]);
  const [folders, setFolders] = useState<FolderRecord[]>([]);
  const [boards, setBoards] = useState<MoodboardSummary[]>([]);
  const [clipboard, setClipboard] = useState<ClipboardPreview | null>(null);
  const [selectedIds, setSelectedIds] = useState<string[]>([]);
  const [searchQuery, setSearchQuery] = useState('');
  const [dragHovering, setDragHovering] = useState(false);
  const [statusMessage, setStatusMessage] = useState<string | null>(null);

  const transport = getTransport();

  const refreshData = useCallback(async () => {
    try {
      const [fetchedAssets, fetchedFolders, fetchedBoards, clip] = await Promise.all([
        transport.fetchAssets(createDefaultFilterCriteria({ sortBy: 'newest' })),
        transport.fetchFolders(),
        transport.fetchBoards(),
        transport.getClipboardPreview(),
      ]);
      setAssets(fetchedAssets);
      setFolders(fetchedFolders);
      setBoards(fetchedBoards);
      setClipboard(clip);
      if (!selectedFolderId && fetchedFolders[0]) {
        setSelectedFolderId(fetchedFolders[0].id);
      }
    } catch {
      // Ignore transient refresh error in background shelf
    }
  }, [transport, selectedFolderId]);

  useEffect(() => {
    void refreshData();
    let unlisten: (() => void) | null = null;
    void transport
      .subscribeEvents({
        onLibraryChanged: () => void refreshData(),
        onBoardUpdated: () => void refreshData(),
        onClipboardChanged: (preview) => setClipboard(preview),
        onShelfState: (s) => {
          setPinned(s.pinned);
          if (s.expanded) void refreshData();
        },
      })
      .then((fn) => {
        unlisten = fn;
      })
      .catch(() => {});
    return () => {
      unlisten?.();
    };
  }, [transport, refreshData]);

  // Continuously sync visible capsule bounds to Win32 WM_NCHITTEST so outside pixels stay HTTRANSPARENT
  const reportHitRect = useCallback(() => {
    const el = capsuleRef.current;
    if (!el) return;
    const rect = el.getBoundingClientRect();
    const dpr = window.devicePixelRatio || 1;
    void transport.setShelfHitRect({
      x: Math.round(rect.left * dpr),
      y: Math.round(rect.top * dpr),
      width: Math.round(rect.width * dpr),
      height: Math.round(rect.height * dpr),
    });
  }, [transport]);

  useEffect(() => {
    reportHitRect();
    const el = capsuleRef.current;
    if (!el || typeof ResizeObserver === 'undefined') return;
    const obs = new ResizeObserver(reportHitRect);
    obs.observe(el);
    window.addEventListener('resize', reportHitRect);
    return () => {
      obs.disconnect();
      window.removeEventListener('resize', reportHitRect);
    };
  }, [reportHitRect, fullGallery]);

  const showBanner = (msg: string) => {
    setStatusMessage(msg);
    window.setTimeout(() => {
      setStatusMessage((prev) => (prev === msg ? null : prev));
    }, 2400);
  };

  const resolvedTargets = useMemo(() => {
    const folderId = targetMode === 'folder' && selectedFolderId ? selectedFolderId : null;
    const boardId = targetMode === 'activeMoodboard' ? (boards[0]?.id ?? null) : null;
    return { folderId, boardId };
  }, [targetMode, selectedFolderId, boards]);

  const folderOptions = useMemo<SelectOption<string>[]>(() => {
    return flattenFolderTree(buildFolderTree(folders)).map((node) => ({
      value: node.folder.id,
      label: node.folder.name,
      depth: node.depth,
    }));
  }, [folders]);

  const filteredAssets = useMemo(() => {
    const q = searchQuery.trim().toLowerCase();
    if (!q) return assets;
    return assets.filter(
      (a) =>
        a.title.toLowerCase().includes(q) ||
        a.tags.some((t) => t.toLowerCase().includes(q)),
    );
  }, [assets, searchQuery]);

  const handleDrop = async (e: React.DragEvent) => {
    e.preventDefault();
    setDragHovering(false);
    const { folderId, boardId } = resolvedTargets;

    const files = Array.from(e.dataTransfer.files);
    if (files.length > 0) {
      let count = 0;
      for (const file of files) {
        const dataUrl = await new Promise<string>((resolve) => {
          const reader = new FileReader();
          reader.onload = () => resolve(String(reader.result ?? ''));
          reader.readAsDataURL(file);
        });
        const b64 = dataUrl.includes(',') ? dataUrl.split(',')[1] : dataUrl;
        if (b64) {
          await transport.ingestImageBase64(b64, file.name, null, folderId, boardId);
          count += 1;
        }
      }
      if (count > 0) {
        showBanner(`已采集 ${count} 项文件`);
        void refreshData();
      }
      return;
    }

    const droppedText = (
      e.dataTransfer.getData('text/uri-list') || e.dataTransfer.getData('text/plain')
    ).trim();
    if (/^https?:\/\//i.test(droppedText)) {
      await transport.ingestUrl(droppedText, null, null, folderId, boardId);
      showBanner('已采集网页链接');
      void refreshData();
    } else if (droppedText) {
      await transport.ingestText('抽屉速记', droppedText, null, folderId, boardId);
      showBanner('已保存文本灵感');
      void refreshData();
    }
  };

  const handleDragOut = async (ids: string[]) => {
    if (ids.length === 0) return;
    try {
      const outcome = await transport.startOutboundDrag(ids);
      if (outcome !== 'cancelled') {
        showBanner(`已拖出 ${ids.length} 项原文件`);
      }
    } catch (err) {
      showBanner(err instanceof Error ? err.message : '原文件未本地缓存');
    }
  };

  const toggleSelect = (id: string, multi: boolean) => {
    setSelectedIds((prev) => {
      if (!multi) return prev.length === 1 && prev[0] === id ? [] : [id];
      return prev.includes(id) ? prev.filter((x) => x !== id) : [...prev, id];
    });
  };

  return (
    <div
      className="w-screen h-screen flex justify-center items-start bg-transparent select-none overflow-hidden"
      onDragOver={(e) => {
        e.preventDefault();
        setDragHovering(true);
      }}
      onDragLeave={(e) => {
        if (e.currentTarget === e.target) setDragHovering(false);
      }}
      onDrop={(e) => void handleDrop(e)}
    >
      <div
        ref={capsuleRef}
        data-testid="top-edge-drop-shelf"
        data-mode={fullGallery ? 'waterfall' : 'compact'}
        style={{
          width: fullGallery ? 'min(980px, calc(100vw - 24px))' : 'min(672px, calc(100vw - 24px))',
          maxHeight: fullGallery ? '580px' : '336px',
          transition:
            'width var(--duration-drawer) var(--ease-drawer), max-height var(--duration-drawer) var(--ease-drawer)',
        }}
        className="charkle-glass-dark rounded-b-[24px] px-4 pt-2.5 pb-3.5 flex flex-col gap-2.5 text-[#F2F3F5] border-x border-b border-white/12"
      >
        {/* Top Wing Header */}
        <div className="flex items-center justify-between gap-2">
          <div className="flex items-center gap-2 min-w-0">
            <CharkleBrandMark size={17} variant="dark" />
            <span className="text-[12.5px] font-semibold tracking-[-0.01em]">
              顶部灵感抽屉
            </span>

            {/* Target Routing Pill: Inbox / Folder / Active Moodboard */}
            <div
              role="radiogroup"
              aria-label="采集投递目标"
              className="inline-flex items-center p-0.5 rounded-full bg-white/8 border border-white/10 text-[11px]"
            >
              {(
                [
                  { id: 'inbox', label: '收件箱', icon: <Inbox size={11} /> },
                  { id: 'folder', label: '指定文件夹', icon: <Folder size={11} /> },
                  { id: 'activeMoodboard', label: '当前活跃情绪板', icon: <LayoutGrid size={11} /> },
                ] as const
              ).map((opt) => {
                const active = targetMode === opt.id;
                return (
                  <button
                    key={opt.id}
                    type="button"
                    role="radio"
                    aria-checked={active}
                    onClick={() => setTargetMode(opt.id)}
                    className={[
                      'charkle-pressable h-6 px-2 rounded-full inline-flex items-center gap-1 cursor-pointer',
                      active
                        ? 'bg-[#5B8DEF] text-white font-medium'
                        : 'text-white/70 hover:text-white',
                    ].join(' ')}
                  >
                    {opt.icon}
                    <span>{opt.label}</span>
                  </button>
                );
              })}
            </div>

            {targetMode === 'folder' && folderOptions.length > 0 && (
              <CustomSelect<string>
                value={selectedFolderId}
                options={folderOptions}
                onChange={setSelectedFolderId}
                ariaLabel="选择投递文件夹"
                size="xs"
                className="h-6 max-w-[140px] bg-white/10 border-white/15 text-white"
              />
            )}
          </div>

          {/* Right Controls */}
          <div className="flex items-center gap-1 shrink-0">
            <button
              type="button"
              title="区域截图采集 (Alt+Shift+A)"
              aria-label="区域截图采集"
              onClick={() =>
                void transport.startRegionCapture(
                  resolvedTargets.folderId,
                  resolvedTargets.boardId,
                )
              }
              className="charkle-pressable h-7 w-7 rounded-full inline-flex items-center justify-center text-white/75 hover:text-white hover:bg-white/10 cursor-pointer"
            >
              <Camera size={14} />
            </button>

            <button
              type="button"
              title={pinned ? '取消固定展开' : '固定展开抽屉'}
              aria-label={pinned ? '取消固定展开' : '固定展开抽屉'}
              onClick={() => {
                const next = !pinned;
                setPinned(next);
                void transport.setShelfPinned(next);
              }}
              className={[
                'charkle-pressable h-7 w-7 rounded-full inline-flex items-center justify-center cursor-pointer',
                pinned
                  ? 'bg-[#5B8DEF]/25 text-[#8EB4FF]'
                  : 'text-white/75 hover:text-white hover:bg-white/10',
              ].join(' ')}
            >
              <Pin size={13.5} />
            </button>

            <button
              type="button"
              title={fullGallery ? '切换为紧凑抽屉' : '展开为全瀑布流抽屉'}
              aria-label={fullGallery ? '切换为紧凑抽屉' : '展开为全瀑布流抽屉'}
              onClick={() => setFullGallery((v) => !v)}
              className="charkle-pressable h-7 px-2 rounded-full inline-flex items-center gap-1 text-[11.5px] text-white/80 hover:text-white hover:bg-white/10 cursor-pointer"
            >
              {fullGallery ? <Minimize2 size={13} /> : <Maximize2 size={13} />}
              <span>{fullGallery ? '紧凑' : '瀑布流'}</span>
            </button>

            <button
              type="button"
              title="打开 Charkle 主窗口"
              aria-label="打开主窗口"
              onClick={() => void transport.focusMainWindow()}
              className="charkle-pressable h-7 w-7 rounded-full inline-flex items-center justify-center text-white/75 hover:text-white hover:bg-white/10 cursor-pointer"
            >
              <ExternalLink size={13.5} />
            </button>

            <button
              type="button"
              title="收起抽屉"
              aria-label="收起抽屉"
              onClick={() => void transport.hideShelf()}
              className="charkle-pressable h-7 w-7 rounded-full inline-flex items-center justify-center text-white/75 hover:text-white hover:bg-white/10 cursor-pointer"
            >
              <X size={14} />
            </button>
          </div>
        </div>

        {/* Status or Live Clipboard Quick-Collect Chip */}
        {(statusMessage || clipboard) && (
          <div className="flex items-center justify-between gap-2 px-3 py-1.5 rounded-[12px] bg-white/7 border border-white/10 text-[12px]">
            {statusMessage ? (
              <span className="inline-flex items-center gap-1.5 text-emerald-400 font-medium">
                <Check size={13.5} />
                {statusMessage}
              </span>
            ) : clipboard ? (
              <>
                <span className="inline-flex items-center gap-1.5 min-w-0 truncate text-white/85">
                  <Clipboard size={13} className="text-[#5B8DEF] shrink-0" />
                  <span className="truncate">{clipboard.label}</span>
                </span>
                <button
                  type="button"
                  onClick={async () => {
                    const count = await transport.collectClipboardNow(
                      resolvedTargets.folderId,
                      resolvedTargets.boardId,
                    );
                    showBanner(count > 0 ? `已采集 ${count} 项剪贴板内容` : '剪贴板为空');
                    void refreshData();
                  }}
                  className="charkle-pressable h-6 px-2.5 rounded-full bg-[#5B8DEF] hover:bg-[#74A0F7] text-white text-[11.5px] font-medium shrink-0 cursor-pointer"
                >
                  立即采集
                </button>
              </>
            ) : null}
          </div>
        )}

        {/* Compact Mode: Drop Well + Horizontal Recent Assets Strip */}
        {!fullGallery ? (
          <div className="flex flex-col gap-2.5">
            <div
              className={[
                'h-[84px] rounded-[14px] border border-dashed flex flex-col items-center justify-center gap-1 transition-colors duration-150',
                dragHovering
                  ? 'border-[#5B8DEF] bg-[#5B8DEF]/20'
                  : 'border-white/18 bg-white/[0.04]',
              ].join(' ')}
            >
              <Upload size={18} className="text-[#8EB4FF]" />
              <div className="text-[12.5px] font-medium text-white/90">
                拖入图片、文件或网页链接直接入库
              </div>
              <div className="text-[11px] text-white/50">
                不抢占当前应用焦点 · 拖动下方卡片即可原生拖出到 Figma / Photoshop / 资源管理器
              </div>
            </div>

            <div className="flex flex-col gap-1.5">
              <div className="flex items-center justify-between text-[11px] text-white/55 px-0.5">
                <span>最近素材（点击拖出原文件）</span>
                <span className="charkle-tabular">{assets.length} 项</span>
              </div>
              <div className="flex items-center gap-2 overflow-x-auto charkle-scroll pb-1">
                {assets.slice(0, 12).map((asset) => (
                  <div
                    key={asset.id}
                    className="group relative shrink-0 h-[84px] w-[104px] rounded-[10px] overflow-hidden bg-white/8 border border-white/10"
                  >
                    <img
                      src={transport.thumbnailUrl(asset.id, 'grid520')}
                      alt={asset.title}
                      draggable={false}
                      className="w-full h-full object-cover"
                    />
                    <button
                      type="button"
                      title="原生拖出原文件到外部应用"
                      aria-label={`拖出 ${asset.title}`}
                      onMouseDown={(e) => {
                        if (e.button === 0) void handleDragOut([asset.id]);
                      }}
                      className="absolute inset-0 bg-black/55 opacity-0 group-hover:opacity-100 transition-opacity flex flex-col items-center justify-center gap-1 text-[11px] text-white cursor-grab"
                    >
                      <Share2 size={14} />
                      <span>拖出文件</span>
                    </button>
                  </div>
                ))}
              </div>
            </div>
          </div>
        ) : (
          /* Expanded Full-Waterfall Shelf Mode */
          <div className="flex-1 min-h-0 flex flex-col gap-2.5 overflow-hidden">
            <div className="flex items-center justify-between gap-2">
              <div className="flex items-center gap-1.5 flex-1 h-8 px-2.5 rounded-[10px] bg-white/8 border border-white/10">
                <Search size={13.5} className="text-white/50 shrink-0" />
                <input
                  type="text"
                  value={searchQuery}
                  onChange={(e) => setSearchQuery(e.target.value)}
                  placeholder="快速筛选素材…"
                  className="flex-1 bg-transparent text-[12.5px] text-white placeholder:text-white/40 outline-none"
                />
              </div>

              {selectedIds.length > 0 && (
                <button
                  type="button"
                  onClick={() => void handleDragOut(selectedIds)}
                  className="charkle-pressable h-8 px-3 rounded-[10px] bg-[#5B8DEF] text-white text-[12px] font-medium inline-flex items-center gap-1.5 cursor-pointer shrink-0"
                >
                  <Share2 size={13.5} />
                  <span>拖出已选 {selectedIds.length} 项原文件</span>
                </button>
              )}
            </div>

            <div className="flex-1 min-h-0 overflow-y-auto charkle-scroll pr-1">
              <div className="columns-4 gap-2.5 space-y-2.5">
                {filteredAssets.slice(0, 60).map((asset) => {
                  const selected = selectedIds.includes(asset.id);
                  return (
                    <div
                      key={asset.id}
                      role="button"
                      tabIndex={0}
                      onClick={(e) => toggleSelect(asset.id, e.ctrlKey || e.metaKey)}
                      className={[
                        'group relative break-inside-avoid rounded-[10px] overflow-hidden bg-white/8 cursor-pointer',
                        selected ? 'ring-2 ring-[#5B8DEF]' : 'ring-1 ring-white/10',
                      ].join(' ')}
                    >
                      <img
                        src={transport.thumbnailUrl(asset.id, 'grid520')}
                        alt={asset.title}
                        draggable={false}
                        className="w-full h-auto block object-cover"
                      />
                      <button
                        type="button"
                        aria-label={`原生拖出 ${asset.title}`}
                        onMouseDown={(e) => {
                          e.stopPropagation();
                          const ids = selected && selectedIds.length > 1 ? selectedIds : [asset.id];
                          void handleDragOut(ids);
                        }}
                        className="absolute top-1.5 right-1.5 h-6 px-2 rounded-full bg-black/70 text-[10.5px] text-white opacity-0 group-hover:opacity-100 inline-flex items-center gap-1 cursor-grab"
                      >
                        <Share2 size={11} />
                        拖出
                      </button>
                    </div>
                  );
                })}
              </div>
            </div>
          </div>
        )}
      </div>
    </div>
  );
};
