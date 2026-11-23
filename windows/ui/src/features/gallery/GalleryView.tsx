import React, { useMemo, useState } from 'react';
import { Plus, Trash2, Upload } from 'lucide-react';
import {
  Button,
  EmptyStateVignette,
  GallerySkeleton,
  ModalShell,
  useDelayedFlag,
  type EmptyVignetteKind,
} from '../../design-system';
import {
  countActiveVisualFilters,
  useCoordinatorStore,
  useLibraryStore,
} from '../../stores';
import { BatchActionPill } from './BatchActionPill';
import { GalleryFilmstripView } from './GalleryFilmstripView';
import { HorizontalJustifiedView } from './HorizontalJustifiedView';
import { InboxTriageBar } from './InboxTriageBar';
import { TopFilterCapsule } from './TopFilterCapsule';
import { VerticalMasonryView } from './VerticalMasonryView';

export const GalleryView: React.FC = () => {
  const destination = useCoordinatorStore((s) => s.destination);
  const layoutMode = useCoordinatorStore((s) => s.layoutMode);
  const cardScale = useCoordinatorStore((s) => s.cardScale);
  const setCaptureOpen = useCoordinatorStore((s) => s.setCaptureOpen);

  const assets = useLibraryStore((s) => s.assets);
  const folders = useLibraryStore((s) => s.folders);
  const smartFolders = useLibraryStore((s) => s.smartFolders);
  const criteria = useLibraryStore((s) => s.criteria);
  const loading = useLibraryStore((s) => s.loading);
  const clearVisualFilters = useLibraryStore((s) => s.clearVisualFilters);
  const permanentlyDeleteAssets = useLibraryStore((s) => s.permanentlyDeleteAssets);
  const ingestImageBase64 = useLibraryStore((s) => s.ingestImageBase64);
  const ingestUrl = useLibraryStore((s) => s.ingestUrl);

  const [dragHovering, setDragHovering] = useState(false);
  const [emptyTrashOpen, setEmptyTrashOpen] = useState(false);

  const showSkeleton = useDelayedFlag(loading && assets.length === 0, 300, 500);
  const hasFilters = countActiveVisualFilters(criteria) > 0;

  const headerInfo = useMemo(() => {
    switch (destination.type) {
      case 'allItems':
        return { title: '全部素材', subtitle: '以画面为中心的本地视觉资料库' };
      case 'inbox':
        return { title: '收件箱', subtitle: '尚未归类的新采集灵感，支持 1–9 键快速分拣' };
      case 'untagged':
        return { title: '未打标签', subtitle: '还没有标签的素材集合' };
      case 'recent':
        return { title: '最近浏览', subtitle: '近 14 天内打开或导入的素材' };
      case 'trash':
        return { title: '回收站', subtitle: '可随时还原，或手动永久清除' };
      case 'folder': {
        const f = folders.find((item) => item.id === destination.id);
        return { title: f?.name ?? '文件夹', subtitle: '包含当前文件夹及子文件夹素材' };
      }
      case 'smartFolder': {
        const sf = smartFolders.find((item) => item.id === destination.id);
        return { title: sf?.name ?? '智能文件夹', subtitle: '按动态条件实时匹配' };
      }
      case 'tag':
        return { title: `#${destination.name}`, subtitle: '标签视图' };
      default:
        return { title: '素材库', subtitle: '' };
    }
  }, [destination, folders, smartFolders]);

  const emptyState = useMemo((): {
    kind: EmptyVignetteKind;
    title: string;
    description: string;
    actionLabel?: string;
    onAction?: () => void;
  } => {
    if (hasFilters) {
      return {
        kind: 'noResults',
        title: '没有匹配的素材',
        description: '当前搜索或筛选条件过严，试着放宽颜色容差或清空部分条件。',
        actionLabel: '重置筛选条件',
        onAction: () => void clearVisualFilters(destination),
      };
    }
    if (destination.type === 'inbox') {
      return {
        kind: 'inboxZero',
        title: '收件箱已清空',
        description: '所有新采集的灵感都已井井有条地归入文件夹。',
      };
    }
    if (destination.type === 'folder') {
      return {
        kind: 'emptyFolder',
        title: '文件夹还是空的',
        description: '将画廊中的素材拖拽到左侧文件夹，或直接导入新素材到此目录。',
        actionLabel: '导入素材',
        onAction: () => setCaptureOpen(true),
      };
    }
    return {
      kind: 'emptyLibrary',
      title: destination.type === 'trash' ? '回收站为空' : '开始构建你的视觉库',
      description:
        destination.type === 'trash'
          ? '目前没有任何被移入回收站的素材。'
          : '拖入图片、视频、PDF、3D 模型，或粘贴网页与 GitHub 链接即可采集。',
      actionLabel: destination.type === 'trash' ? undefined : '导入素材',
      onAction: destination.type === 'trash' ? undefined : () => setCaptureOpen(true),
    };
  }, [hasFilters, destination, clearVisualFilters, setCaptureOpen]);

  const handleExternalDrop = async (e: React.DragEvent) => {
    setDragHovering(false);
    if (e.dataTransfer.types.includes('application/x-charkle-asset-ids')) return;
    e.preventDefault();
    const targetFolderId = destination.type === 'folder' ? destination.id : null;

    const files = Array.from(e.dataTransfer.files);
    if (files.length > 0) {
      for (const file of files) {
        if (file.type.startsWith('image/')) {
          const dataUrl = await new Promise<string>((resolve) => {
            const reader = new FileReader();
            reader.onload = () => resolve(String(reader.result ?? ''));
            reader.readAsDataURL(file);
          });
          const base64 = dataUrl.includes(',') ? dataUrl.split(',')[1] : dataUrl;
          if (base64) {
            await ingestImageBase64(base64, file.name, null, targetFolderId, destination);
          }
        }
      }
      return;
    }

    const droppedUrl =
      e.dataTransfer.getData('text/uri-list') || e.dataTransfer.getData('text/plain');
    if (droppedUrl && /^https?:\/\//i.test(droppedUrl.trim())) {
      await ingestUrl(droppedUrl.trim(), null, null, targetFolderId, destination);
    }
  };

  return (
    <main
      onDragOver={(e) => {
        if (e.dataTransfer.types.includes('application/x-charkle-asset-ids')) return;
        if (e.dataTransfer.types.includes('Files') || e.dataTransfer.types.includes('text/uri-list')) {
          e.preventDefault();
          setDragHovering(true);
        }
      }}
      onDragLeave={(e) => {
        if (e.currentTarget === e.target) setDragHovering(false);
      }}
      onDrop={(e) => void handleExternalDrop(e)}
      className="relative flex-1 min-w-0 min-h-0 flex flex-col bg-[var(--bg-gallery)] overflow-hidden"
    >
      {/* Top Floating Filter Capsule */}
      <TopFilterCapsule />

      {/* Quiet destination bar */}
      <div className="shrink-0 px-4 pb-2 flex items-center justify-between gap-3">
        <div className="flex items-baseline gap-2.5 min-w-0">
          <h1 className="text-[16px] font-semibold tracking-[-0.01em] text-[var(--text-primary)] truncate">
            {headerInfo.title}
          </h1>
          <span className="text-[12px] text-[var(--text-tertiary)] charkle-tabular shrink-0">
            {assets.length} 项
          </span>
        </div>

        {destination.type === 'trash' && assets.length > 0 && (
          <Button variant="danger" size="xs" onClick={() => setEmptyTrashOpen(true)}>
            <Trash2 size={12.5} />
            清空回收站
          </Button>
        )}
      </div>

      {/* Inbox rapid 1-9 triage bar */}
      {destination.type === 'inbox' && assets.length > 0 && (
        <InboxTriageBar assets={assets} />
      )}

      {/* Main Content Stage */}
      {showSkeleton ? (
        <GallerySkeleton columns={4} />
      ) : assets.length === 0 ? (
        <div className="flex-1 flex flex-col items-center justify-center gap-3 px-6 text-center">
          <EmptyStateVignette kind={emptyState.kind} />
          <div className="text-[14.5px] font-semibold text-[var(--text-primary)] charkle-heading">
            {emptyState.title}
          </div>
          <p className="text-[12.5px] text-[var(--text-secondary)] max-w-[340px] leading-relaxed charkle-prose">
            {emptyState.description}
          </p>
          {emptyState.actionLabel && emptyState.onAction && (
            <Button variant="primary" size="sm" onClick={emptyState.onAction}>
              <Plus size={14} />
              {emptyState.actionLabel}
            </Button>
          )}
        </div>
      ) : layoutMode === 'verticalMasonry' ? (
        <VerticalMasonryView assets={assets} cardScale={cardScale} />
      ) : layoutMode === 'horizontalJustified' ? (
        <HorizontalJustifiedView assets={assets} cardScale={cardScale} />
      ) : (
        <GalleryFilmstripView assets={assets} />
      )}

      {/* Floating Multi-Selection Action Pill */}
      <BatchActionPill />

      {/* Drag-and-drop capture overlay */}
      {dragHovering && (
        <div className="pointer-events-none absolute inset-3 z-50 rounded-[var(--radius-dock-outer)] border-2 border-dashed border-[var(--accent)] bg-[var(--accent-soft)] backdrop-blur-xs flex flex-col items-center justify-center gap-2">
          <Upload size={28} className="text-[var(--accent)]" />
          <div className="text-[14px] font-semibold text-[var(--accent)]">
            释放即可导入到当前视图
          </div>
        </div>
      )}

      {/* Empty Trash confirmation modal */}
      <ModalShell
        open={emptyTrashOpen}
        onClose={() => setEmptyTrashOpen(false)}
        title={`清空回收站（${assets.length} 项）？`}
        width="sm"
        footer={
          <>
            <Button variant="secondary" onClick={() => setEmptyTrashOpen(false)}>
              取消
            </Button>
            <Button
              variant="danger"
              onClick={async () => {
                setEmptyTrashOpen(false);
                await permanentlyDeleteAssets(
                  assets.map((a) => a.id),
                  destination,
                );
              }}
            >
              确认永久清空
            </Button>
          </>
        }
      >
        <p className="text-[13px] text-[var(--text-secondary)] leading-relaxed charkle-prose">
          此操作将永久删除回收站中的全部 {assets.length} 项素材，操作不可撤销。
        </p>
      </ModalShell>
    </main>
  );
};
