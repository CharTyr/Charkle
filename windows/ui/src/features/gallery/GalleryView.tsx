import React, { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import {
  ArrowUndo16Regular,
  ArrowUpload24Regular,
  ChevronRight16Regular,
  Delete16Regular,
  FolderAdd16Regular,
} from '@fluentui/react-icons';
import { getTransport } from '../../api/transport';
import {
  Button,
  CharkleFolderIcon,
  EmptyStateVignette,
  GallerySkeleton,
  ModalShell,
  Popover,
  WIN_EASE_OUT,
  m,
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
 * Full-height Fluent 2 Gallery-First stage:
 * - Collapsible sticky gallery header (`TopFilterCapsule`) with scroll-linked Acrylic reveal (`0px -> 48px`)
 * - Dynamic `ResizeObserver` `topInset` so Row 1 sits cleanly below expanded header/strips at `scrollTop = 0`
 *   and cards glide smoothly behind the sticky Acrylic header when scrolled
 * - Lightweight Fluent `Entrance` / `Drill-in` destination transitions respecting `MotionConfig`
 * - Clean single-row Fluent contextual strips for Inbox Triage, Trash Recovery, and Folder Subfolders
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
  const hasNavigatedRef = useRef(false);

  const [galleryWidth, setGalleryWidth] = useState(960);
  const [topInset, setTopInset] = useState(64);
  const [scrollElement, setScrollElement] = useState<HTMLDivElement | null>(null);
  const [htmlDragHovering, setHtmlDragHovering] = useState(false);
  const [emptyTrashIds, setEmptyTrashIds] = useState<string[] | null>(null);
  const [createSubfolderOpen, setCreateSubfolderOpen] = useState(false);
  const [subfolderDraft, setSubfolderDraft] = useState('');

  const handleScrollElementChange = useCallback((el: HTMLDivElement | null) => {
    setScrollElement(el);
  }, []);

  const destinationTransitionKey = useMemo(() => {
    if (destination.type === 'folder' || destination.type === 'smartFolder' || destination.type === 'moodboard') {
      return `${destination.type}:${destination.id}`;
    }
    if (destination.type === 'tag') {
      return `tag:${destination.name}`;
    }
    return destination.type;
  }, [destination]);

  const prevTransitionKeyRef = useRef(destinationTransitionKey);
  if (prevTransitionKeyRef.current !== destinationTransitionKey) {
    prevTransitionKeyRef.current = destinationTransitionKey;
    hasNavigatedRef.current = true;
  }

  const isDrillInDestination =
    destination.type === 'folder' || destination.type === 'smartFolder';

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

  // Dynamically measure top header + contextual strip stack height so Row 1 clears expanded header
  useEffect(() => {
    const el = topStackRef.current;
    if (!el) return;
    const measure = () => {
      const h = el.offsetHeight;
      if (h > 0) {
        const next = Math.max(56, Math.ceil(h) + 8);
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
  const hasSecondaryStrip =
    (isInbox && assets.length > 0) ||
    (isTrash && assets.length > 0) ||
    Boolean(activeFolderId && folderBreadcrumbs.length > 0);

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

  const stageInitial = !hasNavigatedRef.current
    ? false
    : isDrillInDestination
      ? { opacity: 0, scale: 0.985 }
      : { opacity: 0, y: 12 };

  const stageAnimate = { opacity: 1, y: 0, scale: 1 };
  const stageTransition = {
    duration: isDrillInDestination ? 0.22 : 0.2,
    ease: WIN_EASE_OUT,
  };

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
      className="relative flex-1 min-w-0 min-h-0 flex flex-col bg-[var(--bg-gallery)] overflow-hidden"
    >
      {/* Full-Height Gallery Content Stage with Fluent Entrance / Drill-in transitions */}
      <m.div
        key={destinationTransitionKey}
        initial={stageInitial}
        animate={stageAnimate}
        transition={stageTransition}
        className="relative flex-1 min-h-0 flex flex-col overflow-hidden"
      >
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
                variant="standard"
                size="sm"
                onClick={() => setDestination({ type: 'allItems' })}
              >
                浏览全部素材
              </Button>
              <Button
                variant="accent"
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
                    variant="standard"
                    size="sm"
                    onClick={() => void clearVisualFilters(destination)}
                  >
                    清除筛选条件
                  </Button>
                ) : (
                  <Button
                    variant="standard"
                    size="sm"
                    onClick={() => setCaptureOpen(true)}
                  >
                    导入素材
                  </Button>
                )}
                <Button
                  variant="accent"
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
            onScrollElementChange={handleScrollElementChange}
          />
        ) : layoutMode === 'horizontalJustified' ? (
          <HorizontalJustifiedView
            assets={assets}
            cardScale={cardScale}
            topInset={topInset}
            bottomInset={bottomInset}
            onScrollElementChange={handleScrollElementChange}
          />
        ) : layoutMode === 'ringGallery' ? (
          <GalleryRingView assets={assets} topInset={topInset} />
        ) : (
          <GalleryFilmstripView assets={assets} topInset={topInset} />
        )}
      </m.div>

      {/* Collapsible Sticky Fluent 2 Gallery Header + Contextual Secondary Strips */}
      <div
        ref={topStackRef}
        className="pointer-events-none absolute top-0 left-0 right-0 z-30 flex flex-col"
      >
        <TopFilterCapsule
          galleryViewportWidth={galleryWidth}
          sectionTitle={dropTargetTitle}
          itemCount={assets.length}
          scrollContainer={scrollElement}
        />

        {hasSecondaryStrip && (
          <div className="pointer-events-none px-4 pb-2 flex flex-col gap-2">
            {/* Single-row Fluent Inbox Triage Strip */}
            {isInbox && assets.length > 0 && <InboxTriageBar assets={assets} />}

            {/* Single-row Fluent Trash Action Strip */}
            {isTrash && assets.length > 0 && (
              <div
                data-testid="trash-action-bar"
                className="pointer-events-auto charkle-reveal-top win-acrylic-bar min-h-[38px] px-3 py-1 rounded-[var(--win-radius-card)] flex items-center justify-between gap-2"
              >
                <div className="inline-flex items-center gap-2 text-[12.5px] font-medium text-[var(--text-primary)] charkle-tabular min-w-0">
                  <Delete16Regular className="w-4 h-4 text-[var(--text-secondary)] shrink-0" />
                  <span className="truncate">回收站 · 共 {assets.length} 项素材</span>
                </div>

                <div className="inline-flex items-center gap-1.5 shrink-0">
                  <Button
                    variant="standard"
                    size="xs"
                    onClick={() => {
                      const allIds = assets.map((a) => a.id);
                      clearSelection();
                      void updateAssets({ assetIDs: allIds, isTrashed: false }, destination).then(
                        () =>
                          pushToast({
                            message: `已将 ${allIds.length} 项全部放回原处`,
                            tone: 'success',
                          }),
                      );
                    }}
                  >
                    <ArrowUndo16Regular className="w-3.5 h-3.5" />
                    <span>全部放回原处</span>
                  </Button>

                  <Button
                    variant="danger"
                    size="xs"
                    onClick={() => setEmptyTrashIds(assets.map((a) => a.id))}
                  >
                    <Delete16Regular className="w-3.5 h-3.5" />
                    <span>清空回收站…</span>
                  </Button>
                </div>
              </div>
            )}

            {/* Single-row Fluent Folder Breadcrumb + Subfolders + Create-Subfolder Strip */}
            {activeFolderId && folderBreadcrumbs.length > 0 && (
              <div
                data-testid="folder-subfolders-bar"
                className="pointer-events-auto charkle-reveal-top win-acrylic-bar min-h-[38px] px-3 py-1 rounded-[var(--win-radius-card)] flex items-center justify-between gap-2"
              >
                <div className="flex items-center gap-2 min-w-0 flex-1">
                  {/* Breadcrumb path */}
                  <nav aria-label="文件夹路径" className="flex items-center gap-1 shrink-0 min-w-0">
                    {folderBreadcrumbs.map((crumb, index) => {
                      const isCurrent = crumb.id === activeFolderId;
                      return (
                        <React.Fragment key={crumb.id}>
                          {index > 0 && (
                            <ChevronRight16Regular className="w-3 h-3 text-[var(--text-tertiary)] shrink-0" />
                          )}
                          <button
                            type="button"
                            onClick={() => setDestination({ type: 'folder', id: crumb.id })}
                            className={[
                              'inline-flex items-center gap-1.5 px-1.5 py-0.5 rounded-[var(--win-radius-control)] text-[12.5px] hover:bg-[var(--win-subtle-hover)] cursor-pointer max-w-[160px]',
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
                      <div className="h-4 w-px bg-[var(--win-stroke-divider)] shrink-0" />
                      <div className="min-w-0 flex items-center gap-1.5 overflow-x-auto charkle-scroll-hidden">
                        {childFolders.map((child) => {
                          const count = Math.max(
                            child.assetCount,
                            findSubtreeCount(folderTree, child.id),
                          );
                          return (
                            <button
                              key={child.id}
                              type="button"
                              onClick={() => setDestination({ type: 'folder', id: child.id })}
                              className="charkle-pressable h-[26px] px-2 inline-flex items-center gap-1.5 rounded-[var(--win-radius-control)] bg-[var(--win-subtle-hover)] hover:bg-[var(--win-subtle-active)] text-[12px] font-medium text-[var(--text-primary)] cursor-pointer shrink-0 whitespace-nowrap"
                            >
                              <CharkleFolderIcon
                                colorHex={child.colorHex}
                                customSymbol={child.customSymbol}
                                size={13}
                              />
                              <span className="max-w-[120px] truncate">{child.name}</span>
                              {count > 0 && (
                                <span className="text-[10.5px] text-[var(--text-tertiary)] charkle-tabular">
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

                {/* Right: Create Subfolder Fluent Action */}
                <Button
                  ref={createSubfolderBtnRef}
                  variant="subtle"
                  size="xs"
                  onClick={() => {
                    setSubfolderDraft('');
                    setCreateSubfolderOpen(true);
                  }}
                  className="text-[var(--accent)] hover:text-[var(--accent)] shrink-0"
                >
                  <FolderAdd16Regular className="w-3.5 h-3.5" />
                  <span>新建子文件夹</span>
                </Button>
              </div>
            )}
          </div>
        )}
      </div>

      {/* Create Subfolder Popover */}
      <Popover
        open={createSubfolderOpen}
        onOpenChange={setCreateSubfolderOpen}
        anchorEl={createSubfolderBtnRef.current}
        placement="bottom-end"
        className="w-[268px] p-3.5"
      >
        <form
          onSubmit={(e) => {
            e.preventDefault();
            void handleCommitSubfolder();
          }}
          className="flex flex-col gap-2.5"
        >
          <div className="text-[13px] font-semibold text-[var(--text-primary)]">新建子文件夹</div>
          <div className="flex items-center gap-1.5">
            <input
              type="text"
              value={subfolderDraft}
              autoFocus
              onChange={(e) => setSubfolderDraft(e.target.value)}
              placeholder="子文件夹名称"
              className="win-input-elevation flex-1 min-w-0 h-8 px-2.5 rounded-[var(--win-radius-control)] text-[12.5px] text-[var(--text-primary)] placeholder:text-[var(--text-tertiary)] outline-none"
            />
            <Button
              type="submit"
              variant="accent"
              size="sm"
              disabled={!subfolderDraft.trim()}
            >
              创建
            </Button>
          </div>
        </form>
      </Popover>

      {/* Floating Multi-Selection Acrylic Action Bar (>= 2 items selected) */}
      <BatchActionPill />

      {/* GPU Dashed Drop-Ring Overlay */}
      {showDropOverlay && (
        <div className="charkle-reveal-top pointer-events-none absolute inset-4 z-50 rounded-[var(--win-radius-overlay)] border-2 border-dashed border-[var(--accent)] bg-[var(--accent-soft)] flex flex-col items-center justify-center gap-2">
          <div className="w-12 h-12 rounded-full bg-[var(--accent)]/15 flex items-center justify-center">
            <ArrowUpload24Regular className="w-6 h-6 text-[var(--accent)]" />
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
            <Button variant="standard" onClick={() => setEmptyTrashIds(null)}>
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
