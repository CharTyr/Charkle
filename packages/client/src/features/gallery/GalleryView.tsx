import React, { useMemo, useRef, useState } from 'react';
import {
  ChevronRight,
  FolderPlus,
  RotateCcw,
  Sparkles,
  Trash2,
  Upload,
} from 'lucide-react';
import type { FolderRecord, UUID } from '@charkle/shared';
import { Button, CharkleFolderIcon, CharkleIcon } from '../../design-system';
import { useCoordinatorStore } from '../../stores/coordinatorStore';
import { useLibraryStore } from '../../stores/libraryStore';
import { BatchActionPill } from './BatchActionPill';
import { GalleryFilmstripView } from './GalleryFilmstripView';
import { HorizontalJustifiedView } from './HorizontalJustifiedView';
import { InboxTriageBar } from './InboxTriageBar';
import { InboxZeroView } from './InboxZeroView';
import { TopFilterCapsule } from './TopFilterCapsule';
import { VerticalMasonryView } from './VerticalMasonryView';

export const GalleryView: React.FC = () => {
  const destination = useCoordinatorStore((s) => s.destination);
  const navigate = useCoordinatorStore((s) => s.navigate);
  const layoutMode = useCoordinatorStore((s) => s.layoutMode);
  const pushToast = useCoordinatorStore((s) => s.pushToast);

  const assets = useLibraryStore((s) => s.assets);
  const loading = useLibraryStore((s) => s.loading);
  const folders = useLibraryStore((s) => s.folders);
  const smartFolders = useLibraryStore((s) => s.smartFolders);
  const uploadFiles = useLibraryStore((s) => s.uploadFiles);
  const createFolder = useLibraryStore((s) => s.createFolder);
  const emptyTrash = useLibraryStore((s) => s.emptyTrash);
  const restoreAllTrash = useLibraryStore((s) => s.restoreAllTrash);
  const seedDemoLibrary = useLibraryStore((s) => s.seedDemoLibrary);

  const scrollContainerRef = useRef<HTMLDivElement | null>(null);
  const fileInputRef = useRef<HTMLInputElement | null>(null);

  const [dragOverCanvas, setDragOverCanvas] = useState(false);
  const [creatingSubfolder, setCreatingSubfolder] = useState(false);
  const [subfolderDraft, setSubfolderDraft] = useState('');
  const [seedingDemo, setSeedingDemo] = useState(false);
  const [confirmEmptyTrash, setConfirmEmptyTrash] = useState(false);

  const currentFolder = useMemo(() => {
    if (destination.type !== 'folder') return null;
    return folders.find((f) => f.id === destination.id) ?? null;
  }, [destination, folders]);

  const folderBreadcrumbs = useMemo(() => {
    if (!currentFolder) return [];
    const map = new Map(folders.map((f) => [f.id, f]));
    const chain: FolderRecord[] = [];
    let cur: FolderRecord | undefined = currentFolder;
    const guard = new Set<UUID>();
    while (cur && !guard.has(cur.id)) {
      guard.add(cur.id);
      chain.unshift(cur);
      cur = cur.parentID ? map.get(cur.parentID) : undefined;
    }
    return chain;
  }, [currentFolder, folders]);

  const directSubfolders = useMemo(() => {
    if (!currentFolder) return [];
    return folders.filter((f) => f.parentID === currentFolder.id);
  }, [currentFolder, folders]);

  const destinationTitle = useMemo(() => {
    switch (destination.type) {
      case 'allItems':
        return '全部素材';
      case 'inbox':
        return '收件箱';
      case 'untagged':
        return '未打标签';
      case 'recent':
        return '最近使用';
      case 'trash':
        return '回收站';
      case 'folder':
        return currentFolder?.name ?? '文件夹';
      case 'smartFolder':
        return smartFolders.find((s) => s.id === destination.id)?.name ?? '智能文件夹';
      case 'tag':
        return `#${destination.name}`;
      default:
        return '素材库';
    }
  }, [destination, currentFolder, smartFolders]);

  const targetUploadFolderID = destination.type === 'folder' ? destination.id : null;

  const handleFilesSelected = async (fileList: FileList | File[]) => {
    const files = Array.from(fileList);
    if (files.length === 0) return;
    try {
      const created = await uploadFiles(files, { targetFolderID: targetUploadFolderID });
      pushToast({
        tone: 'success',
        message: `已导入 ${created.length} 项素材`,
      });
    } catch (err) {
      pushToast({
        tone: 'error',
        message: err instanceof Error ? err.message : '导入文件失败',
      });
    }
  };

  const handleCreateSubfolder = async () => {
    const trimmed = subfolderDraft.trim();
    setCreatingSubfolder(false);
    setSubfolderDraft('');
    if (!trimmed || !currentFolder) return;
    const created = await createFolder(trimmed, currentFolder.id);
    navigate({ type: 'folder', id: created.id });
  };

  const handleDropFiles = async (e: React.DragEvent) => {
    if (!e.dataTransfer.files || e.dataTransfer.files.length === 0) return;
    e.preventDefault();
    setDragOverCanvas(false);
    await handleFilesSelected(e.dataTransfer.files);
  };

  return (
    <div
      className="relative flex-1 min-w-0 h-full flex flex-col bg-[var(--bg-gallery)] overflow-hidden"
      onDragOver={(e) => {
        if (e.dataTransfer.types.includes('Files')) {
          e.preventDefault();
          setDragOverCanvas(true);
        }
      }}
      onDragLeave={(e) => {
        if (e.currentTarget === e.target) setDragOverCanvas(false);
      }}
      onDrop={(e) => void handleDropFiles(e)}
    >
      <input
        ref={fileInputRef}
        type="file"
        multiple
        className="hidden"
        onChange={(e) => {
          if (e.target.files) void handleFilesSelected(e.target.files);
          e.target.value = '';
        }}
      />

      {/* Scrollable Gallery Canvas (Filmstrip uses full height flex instead of outer scroll) */}
      <div
        ref={scrollContainerRef}
        className={[
          'flex-1 min-h-0 flex flex-col',
          layoutMode === 'galleryFilmstrip' ? 'overflow-hidden' : 'overflow-y-auto charkle-scroll',
        ].join(' ')}
      >
        {/* Floating Liquid Glass Top Filter Bar */}
        <TopFilterCapsule
          destinationTitle={destinationTitle}
          assetCount={assets.length}
          onTriggerUpload={() => fileInputRef.current?.click()}
        />

        {/* Contextual Strip 1: Folder Breadcrumbs & Direct Subfolders */}
        {currentFolder && (
          <div className="mx-5 mb-2 flex flex-col gap-2">
            <div className="flex items-center justify-between gap-2 text-[12px]">
              <div className="flex items-center gap-1 text-[var(--text-secondary)] min-w-0 overflow-x-auto">
                <button
                  type="button"
                  onClick={() => navigate({ type: 'allItems' })}
                  className="hover:text-[var(--text-primary)] cursor-pointer shrink-0"
                >
                  全部素材
                </button>
                {folderBreadcrumbs.map((crumb) => (
                  <React.Fragment key={crumb.id}>
                    <ChevronRight size={12} className="text-[var(--text-tertiary)] shrink-0" />
                    <button
                      type="button"
                      onClick={() => navigate({ type: 'folder', id: crumb.id })}
                      className="hover:text-[var(--text-primary)] font-medium text-[var(--text-primary)] truncate cursor-pointer"
                    >
                      {crumb.name}
                    </button>
                  </React.Fragment>
                ))}
              </div>

              {creatingSubfolder ? (
                <input
                  type="text"
                  autoFocus
                  value={subfolderDraft}
                  onChange={(e) => setSubfolderDraft(e.target.value)}
                  onBlur={() => void handleCreateSubfolder()}
                  onKeyDown={(e) => {
                    if (e.key === 'Enter') void handleCreateSubfolder();
                    if (e.key === 'Escape') {
                      setCreatingSubfolder(false);
                      setSubfolderDraft('');
                    }
                  }}
                  placeholder="子文件夹名称…"
                  className="h-7 px-2 text-[12px] rounded-[var(--radius-chip)] bg-[var(--bg-elevated)] border border-[var(--accent)] text-[var(--text-primary)] focus:outline-none"
                />
              ) : (
                <Button variant="ghost" size="xs" onClick={() => setCreatingSubfolder(true)}>
                  <FolderPlus size={13} />
                  新建子文件夹
                </Button>
              )}
            </div>

            {directSubfolders.length > 0 && (
              <div className="flex flex-wrap gap-2">
                {directSubfolders.map((sub) => (
                  <button
                    key={sub.id}
                    type="button"
                    onClick={() => navigate({ type: 'folder', id: sub.id })}
                    className="charkle-pressable inline-flex items-center gap-2 px-3 py-1.5 rounded-[var(--radius-settings-inner)] bg-[var(--bg-elevated)] border border-[var(--border-hairline)] hover:border-[var(--border-strong)] text-[12.5px] text-[var(--text-primary)] cursor-pointer"
                  >
                    <CharkleFolderIcon
                      colorHex={sub.colorHex}
                      customSymbol={sub.customSymbol}
                      size={18}
                    />
                    <span>{sub.name}</span>
                    <span className="text-[11px] tabular-nums text-[var(--text-tertiary)]">
                      {sub.assetCount}
                    </span>
                  </button>
                ))}
              </div>
            )}
          </div>
        )}

        {/* Contextual Strip 2: Trash Action Bar */}
        {destination.type === 'trash' && assets.length > 0 && (
          <div className="mx-5 mb-2 px-3.5 py-2 rounded-[var(--radius-settings-outer)] bg-[var(--bg-elevated)] border border-[var(--border-hairline)] flex items-center justify-between gap-3">
            <span className="text-[12.5px] text-[var(--text-secondary)]">
              回收站中的素材可随时恢复，清空后将无法找回。
            </span>
            <div className="flex items-center gap-2">
              <Button variant="secondary" size="xs" onClick={() => void restoreAllTrash()}>
                <RotateCcw size={13} />
                全部恢复
              </Button>
              {confirmEmptyTrash ? (
                <div className="flex items-center gap-1.5">
                  <Button
                    variant="danger"
                    size="xs"
                    onClick={async () => {
                      setConfirmEmptyTrash(false);
                      await emptyTrash();
                    }}
                  >
                    确认彻底清空
                  </Button>
                  <Button variant="ghost" size="xs" onClick={() => setConfirmEmptyTrash(false)}>
                    取消
                  </Button>
                </div>
              ) : (
                <Button variant="danger" size="xs" onClick={() => setConfirmEmptyTrash(true)}>
                  <Trash2 size={13} />
                  清空回收站
                </Button>
              )}
            </div>
          </div>
        )}

        {/* Contextual Strip 3: Inbox Triage Bar */}
        {destination.type === 'inbox' && <InboxTriageBar />}

        {/* Main Content Area */}
        {loading && assets.length === 0 ? (
          <div className="flex-1 flex items-center justify-center p-12 text-[13px] text-[var(--text-secondary)] gap-2">
            <span className="h-4 w-4 rounded-full border-2 border-[var(--accent)] border-t-transparent animate-spin" />
            正在载入素材…
          </div>
        ) : assets.length === 0 ? (
          destination.type === 'inbox' ? (
            <InboxZeroView />
          ) : (
            <div className="flex-1 flex flex-col items-center justify-center p-10 text-center">
              <CharkleIcon name="library" style="layered" size={76} className="mb-3" />
              <h2 className="text-[16px] font-semibold text-[var(--text-primary)]">
                暂无符合条件的素材
              </h2>
              <p className="text-[13px] text-[var(--text-secondary)] mt-1 max-w-[360px]">
                直接拖放图片、视频、音频、3D 模型或文档到此处，或粘贴任意网页 / GitHub / X 推文链接。
              </p>
              <div className="flex items-center gap-2.5 mt-5">
                <Button variant="primary" size="sm" onClick={() => fileInputRef.current?.click()}>
                  <Upload size={14} />
                  导入本地素材
                </Button>
                {destination.type === 'allItems' && (
                  <Button
                    variant="secondary"
                    size="sm"
                    loading={seedingDemo}
                    onClick={async () => {
                      setSeedingDemo(true);
                      try {
                        await seedDemoLibrary();
                        pushToast({ tone: 'success', message: '已载入精选示例素材库' });
                      } finally {
                        setSeedingDemo(false);
                      }
                    }}
                  >
                    <Sparkles size={14} />
                    载入示例库
                  </Button>
                )}
              </div>
            </div>
          )
        ) : layoutMode === 'verticalMasonry' ? (
          <VerticalMasonryView assets={assets} scrollContainerRef={scrollContainerRef} />
        ) : layoutMode === 'horizontalJustified' ? (
          <HorizontalJustifiedView assets={assets} scrollContainerRef={scrollContainerRef} />
        ) : (
          <GalleryFilmstripView assets={assets} />
        )}
      </div>

      {/* Drag-over Drop Veil */}
      {dragOverCanvas && (
        <div className="pointer-events-none fixed inset-0 z-50 flex items-center justify-center bg-black/25 backdrop-blur-[2px]">
          <div className="charkle-glass px-7 py-5 rounded-[var(--radius-dock-outer)] border-2 border-dashed border-[var(--accent)] text-center">
            <div className="text-[15px] font-semibold text-[var(--text-primary)]">
              松开即可导入至「{destinationTitle}」
            </div>
            <div className="text-[12.5px] text-[var(--text-secondary)] mt-1">
              支持图片、GIF、视频、音频、PDF、Markdown、设计文件与 3D 模型
            </div>
          </div>
        </div>
      )}

      {/* Multi-Select Floating Liquid Glass Batch Action Pill */}
      <BatchActionPill />
    </div>
  );
};
