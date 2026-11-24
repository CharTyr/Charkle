import React, { useEffect, useMemo, useRef, useState } from 'react';
import {
  ChevronRight,
  FolderPlus,
  RotateCcw,
  Trash2,
  Upload,
} from 'lucide-react';
import { getTransport } from '../../api/transport';
import {
  Button,
  CharkleFolderIcon,
  EmptyStateVignette,
  GallerySkeleton,
  ModalShell,
  Popover,
  useDelayedFlag,
  type EmptyVignetteKind,
} from '../../design-system';
import {
  countActiveVisualFilters,
  useCoordinatorStore,
  useLibraryStore,
} from '../../stores';
import {
  buildFolderTree,
  type FolderRecord,
  type FolderTreeNode,
} from '../../types/domain';
import { useDndStore } from '../dnd/dndStore';
import { BatchActionPill } from './BatchActionPill';
import { GalleryFilmstripView } from './GalleryFilmstripView';
import { GalleryRingView } from './GalleryRingView';
import { HorizontalJustifiedView } from './HorizontalJustifiedView';
import { InboxTriageBar } from './InboxTriageBar';
import { TopFilterCapsule } from './TopFilterCapsule';
import { VerticalMasonryView } from './VerticalMasonryView';

function findSubtreeCount(nodes: FolderTreeNode[], targetId: string): number {
  for (const node of nodes) {
    if (node.folder.id === targetId) return node.totalAssetCount;
    const hit = findSubtreeCount(node.children, targetId);
    if (hit >= 0) return hit;
  }
  return -1;
}

/**
 * Full-height Gallery-First stage matching macOS `MainWindowView.swift`:
 * - Floating `.charkle-glass` top control stack (`TopFilterCapsule` + `InboxTriageBar` / `trashActionBar` / `folderSubfoldersBar`)
 *   overlaid directly above scrolling gallery artwork (zero opaque header bar, zero top gradient veil)
 * - Dynamic `ResizeObserver` `topInset` so Row 1 sits cleanly below pills at scrollTop = 0 and cards glide visibly under glass
 * - Native macOS folder breadcrumb + subfolder chips + create-subfolder popover
 * - Native macOS Trash recovery/empty bar & Inbox Zero celebration view
 */
export const GalleryView: React.FC = () => {
  const destination = useCoordinatorStore((s) => s.destination);
  const setDestination = useCoordinatorStore((s) => s.setDestination);
  const layoutMode = useCoordinatorStore((s) => s.layoutMode);
  const cardScale = useCoordinatorStore((s) => s.cardScale);
  const selectedAssetIds = useCoordinatorStore((s) => s.selectedAssetIds);
  const clearSelection = useCoordinatorStore((s) => s.clearSelection);
  const setCaptureOpen = useCoordinatorStore((s) => s.setCaptureOpen);
  const setMoodboardGeneratorOpen = useCoordinatorStore((s) => s.setMoodboardGeneratorOpen);
  const pushToast = useCoordinatorStore((s) => s.pushToast);

  const assets = useLibraryStore((s) => s.assets);
  const folders = useLibraryStore((s) => s.folders);
  const smartFolders = useLibraryStore((s) => s.smartFolders);
  const criteria = useLibraryStore((s) => s.criteria);
  const loading = useLibraryStore((s) => s.loading);
  const clearVisualFilters = useLibraryStore((s) => s.clearVisualFilters);
  const updateAssets = useLibraryStore((s) => s.updateAssets);
  const permanentlyDeleteAssets = useLibraryStore((s) => s.permanentlyDeleteAssets);
  const createFolder = useLibraryStore((s) => s.createFolder);
  const refreshAll = useLibraryStore((s) => s.refreshAll);
  const ingestImageBase64 = useLibraryStore((s) => s.ingestImageBase64);
  const ingestUrl = useLibraryStore((s) => s.ingestUrl);

  const osFileDrop = useDndStore((s) => s.osFileDrop);

  const stageRef = useRef<HTMLElement | null>(null);
  const topStackRef = useRef<HTMLDivElement | null>(null);
  const createSubfolderBtnRef = useRef<HTMLButtonElement | null>(null);

  const [galleryWidth, setGalleryWidth] = useState(960);
  const [topInset, setTopInset] = useState(68);
  const [htmlDragHovering, setHtmlDragHovering] = useState(false);
  const [emptyTrashIds, setEmptyTrashIds] = useState<string[] | null>(null);
  const [createSubfolderOpen, setCreateSubfolderOpen] = useState(false);
  const [subfolderDraft, setSubfolderDraft] = useState('');

  // Measure gallery stage width for exact 1-column / 1-stop zoom stepping in TopFilterCapsule
  useEffect(() => {
    const el = stageRef.current;
    if (!el) return;
    const measure = () => {
      const w = Math.floor(el.clientWidth);
      if (w > 120) {
        setGalleryWidth((prev) => (Math.abs(prev - w) >= 2 ? w : prev));
      }
    };
    measure();
    if (typeof ResizeObserver === 'undefined') return;
    const obs = new ResizeObserver(measure);
    obs.observe(el);
    return () => obs.disconnect();
  }, []);

  // Dynamically measure floating top control stack height so Row 1 never clips underneath pills
  useEffect(() => {
    const el = topStackRef.current;
    if (!el) return;
    const measure = () => {
      const h = el.offsetHeight;
      if (h > 0) {
        // top: 12px + measured stack height + 14px breathing clearance
        const next = Math.max(58, Math.ceil(h) + 26);
        setTopInset((prev) => (Math.abs(prev - next) >= 1 ? next : prev));
      }
    };
    measure();
    if (typeof ResizeObserver === 'undefined') return;
    const obs = new ResizeObserver(measure);
    obs.observe(el);
    return () => obs.disconnect();
  }, []);

  const showDropOverlay =
    htmlDragHovering || (osFileDrop.active && osFileDrop.target?.kind === 'gallery');
  const showSkeleton = useDelayedFlag(loading && assets.length === 0, 300, 500);
  const hasFilters = countActiveVisualFilters(criteria) > 0;

  const isInbox = destination.type === 'inbox';
  const isTrash = destination.type === 'trash';
  const activeFolderId = destination.type === 'folder' ? destination.id : null;
  const bottomInset = selectedAssetIds.length >= 2 ? 104 : 44;

  const folderTree = useMemo(() => buildFolderTree(folders), [folders]);

  const folderBreadcrumbs = useMemo<FolderRecord[]>(() => {
    if (!activeFolderId) return [];
    const byId = new Map(folders.map((f) => [f.id, f]));
    const chain: FolderRecord[] = [];
    const visited = new Set<string>();
    let cur = byId.get(activeFolderId);
    while (cur && !visited.has(cur.id)) {
      visited.add(cur.id);
      chain.unshift(cur);
      cur = cur.parentID ? byId.get(cur.parentID) : undefined;
    }
    return chain;
  }, [activeFolderId, folders]);

  const childFolders = useMemo<FolderRecord[]>(() => {
    if (!activeFolderId) return [];
    return folders
      .filter((f) => f.parentID === activeFolderId)
      .sort((a, b) => a.sortOrder - b.sortOrder || a.name.localeCompare(b.name));
  }, [activeFolderId, folders]);

  const dropTargetTitle = useMemo(() => {
    switch (destination.type) {
      case 'allItems':
        return '全部素材';
      case 'inbox':
        return '收件箱';
      case 'untagged':
        return '未打标签';
      case 'recent':
        return '最近浏览';
      case 'trash':
        return '回收站';
      case 'folder':
        return folders.find((f) => f.id === destination.id)?.name ?? '文件夹';
      case 'smartFolder':
        return smartFolders.find((sf) => sf.id === destination.id)?.name ?? '智能文件夹';
      case 'tag':
        return `#${destination.name}`;
      default:
        return '素材库';
    }
  }, [destination, folders, smartFolders]);

  const handleCollectClipboard = async () => {
    try {
      const count = await getTransport().collectClipboardNow(activeFolderId, null);
      if (count > 0) {
        await refreshAll(destination);
        pushToast({ message: `已从剪贴板采集 ${count} 项素材`, tone: 'success' });
      } else {
        pushToast({ message: '剪贴板中暂无可采集内容', tone: 'info' });
      }
    } catch {
      pushToast({ message: '无法读取剪贴板', tone: 'error' });
    }
  };

  const handleCommitSubfolder = async () => {
    const clean = subfolderDraft.trim();
    if (!clean || !activeFolderId) return;
    setSubfolderDraft('');
    setCreateSubfolderOpen(false);
    try {
      const created = await createFolder(clean, activeFolderId);
      pushToast({ message: `已创建子文件夹「${created.name}」`, tone: 'success' });
    } catch (err) {
      pushToast({
        message: err instanceof Error ? err.message : '创建子文件夹失败',
        tone: 'error',
      });
    }
  };

  // HTML5 fallback for browser preview & dragged web URLs
  const handleExternalDrop = async (e: React.DragEvent) => {
    setHtmlDragHovering(false);
    e.preventDefault();
    const targetFolderId = activeFolderId;

    try {
      const files = Array.from(e.dataTransfer.files);
      if (files.length > 0) {
        for (const file of files) {
          const dataUrl = await new Promise<string>((resolve) => {
            const reader = new FileReader();
            reader.onload = () => resolve(String(reader.result ?? ''));
            reader.onerror = () => resolve('');
            reader.readAsDataURL(file);
          });
          const base64 = dataUrl.includes(',') ? dataUrl.split(',')[1] : dataUrl;
          if (base64) {
            await ingestImageBase64(base64, file.name, null, targetFolderId, destination);
          }
        }
        return;
      }

      const droppedUrl =
        e.dataTransfer.getData('text/uri-list') || e.dataTransfer.getData('text/plain');
      if (droppedUrl && /^https?:\/\//i.test(droppedUrl.trim())) {
        await ingestUrl(droppedUrl.trim(), null, null, targetFolderId, destination);
      }
    } catch (err) {
      pushToast({
        message: err instanceof Error && err.message ? err.message : '拖入导入失败',
        tone: 'error',
      });
    }
  };

  const isInboxZero = isInbox && assets.length === 0 && !loading && !hasFilters;

  const emptyMeta = useMemo<{
    kind: EmptyVignetteKind;
    title: string;
    description: string;
  }>(() => {
    if (isTrash && !hasFilters) {
      return {
        kind: 'emptyTrash',
        title: '回收站是空的',
        description: '移至回收站的素材会暂存在这里，你可以随时放回原处或彻底删除。',
      };
    }
    if (hasFilters) {
      return {
        kind: 'noResults',
        title: '没有符合筛选条件的素材',
        description: '调整搜索关键词、放宽色彩匹配范围或清除筛选条件以查看全部素材。',
      };
    }
    if (activeFolderId) {
      return {
        kind: 'emptyFolder',
        title: '当前文件夹还没有素材',
        description:
          '直接拖入图片、GIF、视频、PDF、音频、设计文件或网页链接，或按 Alt+Shift+V 粘贴剪贴板内容。',
      };
    }
    return {
      kind: 'emptyLibrary',
      title: '这里还没有素材',
      description:
        '直接拖入图片、GIF、视频、PDF、音频、设计文件或网页链接，或按 Alt+Shift+V 粘贴剪贴板内容。',
    };
  }, [isTrash, hasFilters, activeFolderId]);

  return (
    <main
      ref={stageRef}
      data-testid="gallery-stage"
      onDragOver={(e) => {
        if (
          e.dataTransfer.types.includes('Files') ||
          e.dataTransfer.types.includes('text/uri-list')
        ) {
          e.preventDefault();
          setHtmlDragHovering(true);
        }
      }}
      onDragLeave={(e) => {
        if (e.currentTarget === e.target) setHtmlDragHovering(false);
      }}
      onDrop={(e) => void handleExternalDrop(e)}
      className="charkle-gallery-surface relative flex-1 min-w-0 min-h-0 flex flex-col bg-[var(--bg-gallery)] overflow-hidden"
    >
      {/* Full-Height Gallery Content Stage (cards scroll visibly beneath floating Liquid Glass pills) */}
      <div className="relative flex-1 min-h-0 flex flex-col overflow-hidden">
        {showSkeleton ? (
          <GallerySkeleton columns={4} topInset={topInset} />
        ) : isInboxZero ? (
          <div
            style={{ paddingTop: topInset }}
            className="charkle-pane-fade flex-1 flex flex-col items-center justify-center gap-3.5 px-6 pb-10 text-center"
          >
            <EmptyStateVignette kind="inboxZero" />
            <div className="text-[19px] font-semibold tracking-[-0.015em] text-[var(--text-primary)] charkle-heading">
              收件箱已清空
            </div>
            <p className="text-[13px] text-[var(--text-secondary)] max-w-[400px] leading-relaxed charkle-prose">
              所有灵感都已妥善归档或进入情绪板。随时拖动文件到顶部悬浮窗或按 Alt+Shift+A 截图采集。
            </p>
            <div className="flex items-center gap-2.5 pt-1">
              <Button
                variant="secondary"
                size="sm"
                onClick={() => setDestination({ type: 'allItems' })}
              >
                浏览全部素材
              </Button>
              <Button
                variant="primary"
                size="sm"
                onClick={() => setMoodboardGeneratorOpen(true)}
              >
                10 秒生成情绪板
              </Button>
            </div>
          </div>
        ) : assets.length === 0 ? (
          <div
            style={{ paddingTop: topInset }}
            className="flex-1 flex flex-col items-center justify-center gap-3.5 px-6 pb-10 text-center"
          >
            <EmptyStateVignette kind={emptyMeta.kind} />
            <div className="text-[16px] font-semibold text-[var(--text-primary)] charkle-heading">
              {emptyMeta.title}
            </div>
            <p className="text-[12.5px] text-[var(--text-secondary)] max-w-[390px] leading-relaxed charkle-prose">
              {emptyMeta.description}
            </p>
            {!(isTrash && !hasFilters) && (
              <div className="flex items-center gap-2.5 pt-0.5">
                {hasFilters ? (
                  <Button
                    variant="secondary"
                    size="sm"
                    onClick={() => void clearVisualFilters(destination)}
                  >
                    清除筛选条件
                  </Button>
                ) : (
                  <Button
                    variant="secondary"
                    size="sm"
                    onClick={() => setCaptureOpen(true)}
                  >
                    导入素材
                  </Button>
                )}
                <Button
                  variant="primary"
                  size="sm"
                  onClick={() => void handleCollectClipboard()}
                >
                  采集剪贴板 (Alt+Shift+V)
                </Button>
              </div>
            )}
          </div>
        ) : layoutMode === 'verticalMasonry' ? (
          <VerticalMasonryView
            assets={assets}
            cardScale={cardScale}
            topInset={topInset}
            bottomInset={bottomInset}
          />
        ) : layoutMode === 'horizontalJustified' ? (
          <HorizontalJustifiedView
            assets={assets}
            cardScale={cardScale}
            topInset={topInset}
            bottomInset={bottomInset}
          />
        ) : layoutMode === 'ringGallery' ? (
          <GalleryRingView assets={assets} topInset={topInset} />
        ) : (
          <GalleryFilmstripView assets={assets} topInset={topInset} />
        )}
      </div>

      {/* Floating Liquid Glass Top Control Stack overlaid directly over full-height gallery */}
      <div
        ref={topStackRef}
        className="pointer-events-none absolute top-[10px] left-4 right-4 z-30 flex flex-col gap-2"
      >
        <TopFilterCapsule galleryViewportWidth={galleryWidth} />

        {/* Floating Inbox Triage Bar */}
        {isInbox && assets.length > 0 && <InboxTriageBar assets={assets} />}

        {/* Floating Trash Action Capsules (content-hugging Liquid Glass pills, zero full-width bar) */}
        {isTrash && assets.length > 0 && (
          <div
            data-testid="trash-action-bar"
            className="pointer-events-none charkle-reveal-top flex items-center justify-between gap-2"
          >
            <div
              data-pill="true"
              data-adapt-glass="true"
              className="pointer-events-auto charkle-glass rounded-full h-[32px] px-3 inline-flex items-center gap-1.5 text-[12px] font-semibold text-[var(--text-primary)] charkle-tabular w-fit shrink-0"
            >
              <Trash2 size={13} className="text-[var(--text-secondary)] shrink-0" />
              <span>回收站 · 共 {assets.length} 项素材</span>
            </div>

            <div
              data-pill="true"
              data-adapt-glass="true"
              className="pointer-events-auto charkle-glass rounded-full h-[32px] px-1.5 inline-flex items-center gap-1 w-fit shrink-0"
            >
              <button
                type="button"
                data-pill="true"
                onClick={() => {
                  const allIds = assets.map((a) => a.id);
                  clearSelection();
                  void updateAssets({ assetIDs: allIds, isTrashed: false }, destination).then(() =>
                    pushToast({
                      message: `已将 ${allIds.length} 项全部放回原处`,
                      tone: 'success',
                    }),
                  );
                }}
                className="charkle-pressable h-[24px] px-2.5 inline-flex items-center gap-1.5 rounded-full bg-black/[0.06] dark:bg-white/[0.10] hover:bg-black/[0.11] dark:hover:bg-white/[0.16] text-[11.5px] font-medium text-[var(--text-primary)] cursor-pointer whitespace-nowrap"
              >
                <RotateCcw size={11.5} />
                <span>全部放回原处</span>
              </button>

              <button
                type="button"
                data-pill="true"
                onClick={() => setEmptyTrashIds(assets.map((a) => a.id))}
                className="charkle-pressable h-[24px] px-2.5 inline-flex items-center gap-1.5 rounded-full bg-[var(--danger-soft)] hover:bg-[var(--danger)] text-[var(--danger)] hover:text-white text-[11.5px] font-semibold cursor-pointer whitespace-nowrap"
              >
                <Trash2 size={11.5} />
                <span>清空回收站…</span>
              </button>
            </div>
          </div>
        )}

        {/* Floating Folder Breadcrumb + Subfolders + Create-Subfolder Capsules (zero edge-to-edge bar) */}
        {activeFolderId && folderBreadcrumbs.length > 0 && (
          <div
            data-testid="folder-subfolders-bar"
            className="pointer-events-none charkle-reveal-top flex items-center justify-between gap-2"
          >
            <div
              data-pill="true"
              data-adapt-glass="true"
              className="pointer-events-auto charkle-glass rounded-full h-[32px] px-3 inline-flex items-center gap-2 w-fit max-w-[calc(100%-132px)] min-w-0"
            >
              {/* Breadcrumb path */}
              <nav aria-label="文件夹路径" className="flex items-center gap-1 shrink-0 min-w-0">
                {folderBreadcrumbs.map((crumb, index) => {
                  const isCurrent = crumb.id === activeFolderId;
                  return (
                    <React.Fragment key={crumb.id}>
                      {index > 0 && (
                        <ChevronRight
                          size={11}
                          className="text-[var(--text-tertiary)] shrink-0"
                        />
                      )}
                      <button
                        type="button"
                        onClick={() => setDestination({ type: 'folder', id: crumb.id })}
                        className={[
                          'inline-flex items-center gap-1.5 text-[12px] cursor-pointer max-w-[160px]',
                          isCurrent
                            ? 'font-semibold text-[var(--text-primary)]'
                            : 'font-medium text-[var(--text-secondary)] hover:text-[var(--text-primary)]',
                        ].join(' ')}
                      >
                        {index === 0 && (
                          <CharkleFolderIcon
                            colorHex={crumb.colorHex}
                            customSymbol={crumb.customSymbol}
                            size={15}
                            isActive
                          />
                        )}
                        <span className="truncate">{crumb.name}</span>
                      </button>
                    </React.Fragment>
                  );
                })}
              </nav>

              {/* Subfolder navigation chips */}
              {childFolders.length > 0 && (
                <>
                  <div className="h-3.5 w-px bg-[var(--border-hairline)] shrink-0" />
                  <div className="min-w-0 flex items-center gap-1.5 overflow-x-auto charkle-scroll-hidden">
                    {childFolders.map((child) => {
                      const count = Math.max(child.assetCount, findSubtreeCount(folderTree, child.id));
                      return (
                        <button
                          key={child.id}
                          type="button"
                          data-pill="true"
                          onClick={() => setDestination({ type: 'folder', id: child.id })}
                          className="charkle-pressable h-[22px] px-2 inline-flex items-center gap-1.5 rounded-full bg-black/[0.06] dark:bg-white/[0.08] hover:bg-black/[0.10] dark:hover:bg-white/[0.14] text-[11.5px] font-medium text-[var(--text-primary)] cursor-pointer shrink-0 whitespace-nowrap"
                        >
                          <CharkleFolderIcon
                            colorHex={child.colorHex}
                            customSymbol={child.customSymbol}
                            size={13}
                          />
                          <span className="max-w-[120px] truncate">{child.name}</span>
                          {count > 0 && (
                            <span className="text-[10px] text-[var(--text-secondary)] charkle-tabular">
                              {count}
                            </span>
                          )}
                        </button>
                      );
                    })}
                  </div>
                </>
              )}
            </div>

            {/* Right: Create Subfolder Floating Glass Pill */}
            <button
              ref={createSubfolderBtnRef}
              type="button"
              data-pill="true"
              data-adapt-glass="true"
              onClick={() => {
                setSubfolderDraft('');
                setCreateSubfolderOpen(true);
              }}
              className="pointer-events-auto charkle-pressable charkle-glass rounded-full h-[32px] px-3 inline-flex items-center gap-1.5 text-[11.5px] font-medium text-[var(--accent)] cursor-pointer shrink-0 whitespace-nowrap"
            >
              <FolderPlus size={12.5} />
              <span>新建子文件夹</span>
            </button>
          </div>
        )}
      </div>

      {/* Create Subfolder Popover */}
      <Popover
        open={createSubfolderOpen}
        onOpenChange={setCreateSubfolderOpen}
        anchorEl={createSubfolderBtnRef.current}
        placement="bottom-end"
        className="w-[264px] p-3.5"
      >
        <form
          onSubmit={(e) => {
            e.preventDefault();
            void handleCommitSubfolder();
          }}
          className="flex flex-col gap-2.5"
        >
          <div className="text-[12.5px] font-semibold text-[var(--text-primary)]">
            新建子文件夹
          </div>
          <div className="flex items-center gap-1.5">
            <input
              type="text"
              value={subfolderDraft}
              autoFocus
              onChange={(e) => setSubfolderDraft(e.target.value)}
              placeholder="子文件夹名称"
              className="flex-1 min-w-0 h-7 px-2.5 rounded-[var(--radius-popover-inner)] bg-[var(--bg-subtle)] text-[12px] text-[var(--text-primary)] outline-none focus:ring-1 focus:ring-[var(--accent)]"
            />
            <Button
              type="submit"
              variant="primary"
              size="xs"
              disabled={!subfolderDraft.trim()}
            >
              创建
            </Button>
          </div>
        </form>
      </Popover>

      {/* Floating Multi-Selection Action Pill (>= 2 items selected) */}
      <BatchActionPill />

      {/* GPU Dashed Drop-Ring Overlay (matching macOS CanvasDropRingOverlay) */}
      {showDropOverlay && (
        <div className="charkle-reveal-top pointer-events-none absolute inset-3 z-50 rounded-[var(--radius-dock-outer)] border-2 border-dashed border-[var(--accent)] bg-[var(--accent-soft)] backdrop-blur-[4px] flex flex-col items-center justify-center gap-2">
          <div className="w-12 h-12 rounded-full bg-[var(--accent)]/15 flex items-center justify-center">
            <Upload size={24} className="text-[var(--accent)]" />
          </div>
          <div className="text-[14px] font-semibold text-[var(--accent)]">
            松开即可导入{osFileDrop.paths.length > 0 ? ` ${osFileDrop.paths.length} 项` : ''}到「
            {dropTargetTitle}」
          </div>
          <div className="text-[12px] text-[var(--text-secondary)]">
            支持图片、视频、音频、PDF、3D 模型、设计文件与整个文件夹
          </div>
        </div>
      )}

      {/* Empty Trash confirmation modal */}
      <ModalShell
        open={emptyTrashIds !== null}
        onClose={() => setEmptyTrashIds(null)}
        title={`清空回收站（共 ${emptyTrashIds?.length ?? 0} 项）？`}
        width="sm"
        footer={
          <>
            <Button variant="secondary" onClick={() => setEmptyTrashIds(null)}>
              取消
            </Button>
            <Button
              variant="danger"
              onClick={async () => {
                const allIds = emptyTrashIds ?? [];
                clearSelection();
                setEmptyTrashIds(null);
                if (allIds.length > 0) {
                  await permanentlyDeleteAssets(allIds, destination);
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
    </main>
  );
};
