import React from 'react';
import { ClipboardPaste, Plus } from 'lucide-react';
import { createDefaultAssetBatchPatch } from '@charkle/shared';
import { Popover } from '../../design-system';
import { useCoordinatorStore } from '../../stores/coordinatorStore';
import { useLibraryStore } from '../../stores/libraryStore';

export interface GalleryCanvasMenuProps {
  point: { x: number; y: number } | null;
  onClose: () => void;
}

export const GalleryCanvasMenu: React.FC<GalleryCanvasMenuProps> = ({ point, onClose }) => {
  const destination = useCoordinatorStore((s) => s.destination);
  const openQuickCapture = useCoordinatorStore((s) => s.openQuickCapture);
  const pushToast = useCoordinatorStore((s) => s.pushToast);

  const cutAssetIDs = useLibraryStore((s) => s.cutAssetIDs);
  const setCutAssetIDs = useLibraryStore((s) => s.setCutAssetIDs);
  const batchPatch = useLibraryStore((s) => s.batchPatch);
  const ingestInputs = useLibraryStore((s) => s.ingestInputs);
  const uploadFiles = useLibraryStore((s) => s.uploadFiles);

  const canPasteCut =
    cutAssetIDs.size > 0 && (destination.type === 'folder' || destination.type === 'inbox');

  const handlePasteClipboard = async () => {
    onClose();
    const targetFolderID = destination.type === 'folder' ? destination.id : null;

    if (canPasteCut) {
      const cutIDs = Array.from(cutAssetIDs);
      setCutAssetIDs([]);
      await batchPatch(
        createDefaultAssetBatchPatch(cutIDs, {
          folderAssignment:
            destination.type === 'folder'
              ? { type: 'folder', folderID: destination.id }
              : { type: 'inbox' },
        }),
      );
      pushToast({ tone: 'success', message: `已移动 ${cutIDs.length} 项素材` });
      return;
    }

    try {
      if (navigator.clipboard && 'read' in navigator.clipboard) {
        const items = await navigator.clipboard.read();
        const files: File[] = [];
        for (const item of items) {
          const imgType = item.types.find((t) => t.startsWith('image/'));
          if (imgType) {
            const blob = await item.getType(imgType);
            const ext = imgType.split('/')[1]?.split(';')[0] || 'png';
            files.push(new File([blob], `clipboard-${Date.now()}.${ext}`, { type: imgType }));
          }
        }
        if (files.length > 0) {
          const uploaded = await uploadFiles(files, { targetFolderID });
          pushToast({ tone: 'success', message: `已粘贴导入 ${uploaded.length} 项图片` });
          return;
        }
      }
      if (navigator.clipboard && 'readText' in navigator.clipboard) {
        const raw = (await navigator.clipboard.readText()).trim();
        if (raw) {
          const isHex = /^#?[0-9a-fA-F]{6}$/.test(raw);
          const isUrl = /^https?:\/\/\S+$/i.test(raw);
          if (isHex) {
            const hex = raw.startsWith('#') ? raw.toUpperCase() : `#${raw.toUpperCase()}`;
            await ingestInputs([{ type: 'colorSwatch', hex, title: `色卡 ${hex}` }], { targetFolderID });
            pushToast({ tone: 'success', message: `已创建色卡 ${hex}` });
            return;
          }
          if (isUrl) {
            await ingestInputs([{ type: 'webURL', url: raw }], { targetFolderID });
            pushToast({ tone: 'success', message: '已保存网页链接' });
            return;
          }
          await ingestInputs([{ type: 'textSnippet', title: raw.slice(0, 40), text: raw }], {
            targetFolderID,
          });
          pushToast({ tone: 'success', message: '已保存文本片段' });
          return;
        }
      }
      pushToast({ tone: 'info', message: '剪贴板为空，可按 ⌘V 粘贴' });
    } catch {
      pushToast({ tone: 'info', message: '请直接使用 ⌘V 粘贴剪贴板内容' });
    }
  };

  return (
    <Popover
      open={Boolean(point)}
      onOpenChange={(open) => {
        if (!open) onClose();
      }}
      anchorPoint={point}
      glass={false}
    >
      {point && (
        <div
          role="menu"
          className="w-[196px] p-1.5 flex flex-col gap-0.5 text-[12.5px] text-[var(--text-primary)] select-none"
        >
          <button
            type="button"
            role="menuitem"
            onClick={() => void handlePasteClipboard()}
            className="w-full px-2.5 py-1.5 rounded-[var(--radius-popover-inner)] flex items-center gap-2 hover:bg-[var(--bg-subtle)] cursor-pointer text-left"
          >
            <ClipboardPaste size={13.5} className="text-[var(--text-secondary)] shrink-0" />
            <span className="flex-1">
              {canPasteCut ? `粘贴移动 (${cutAssetIDs.size} 项)` : '粘贴剪贴板'}
            </span>
            <span className="text-[11px] font-mono text-[var(--text-tertiary)]">⌘V</span>
          </button>

          <button
            type="button"
            role="menuitem"
            onClick={() => {
              onClose();
              openQuickCapture();
            }}
            className="w-full px-2.5 py-1.5 rounded-[var(--radius-popover-inner)] flex items-center gap-2 hover:bg-[var(--bg-subtle)] cursor-pointer text-left"
          >
            <Plus size={13.5} className="text-[var(--text-secondary)] shrink-0" />
            <span className="flex-1">快速采集</span>
            <span className="text-[11px] font-mono text-[var(--text-tertiary)]">⇧⌘N</span>
          </button>
        </div>
      )}
    </Popover>
  );
};
