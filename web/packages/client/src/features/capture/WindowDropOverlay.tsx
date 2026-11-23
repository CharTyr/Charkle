import React, { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { createPortal } from 'react-dom';
import { Folder, Inbox, LayoutGrid, Upload } from 'lucide-react';
import type { UUID } from '@charkle/shared';
import { usePresence } from '../../design-system';
import { useCoordinatorStore } from '../../stores/coordinatorStore';
import { useLibraryStore } from '../../stores/libraryStore';
import { useMoodboardStore } from '../../stores/moodboardStore';
import { detectURLFromText } from './captureUtils';

type DropZoneKey = 'inbox' | 'folder' | 'board';

interface DropZoneOption {
  key: DropZoneKey;
  label: string;
  sublabel?: string;
  targetFolderID: UUID | null;
  targetBoardID: UUID | null;
}

function isExternalCaptureDrag(e: DragEvent): boolean {
  const dt = e.dataTransfer;
  if (!dt) return false;
  const types = Array.from(dt.types ?? []);
  if (
    types.includes('application/x-charkle-assets') ||
    types.includes('application/x-charkle-folder')
  ) {
    return false;
  }
  return types.includes('Files') || types.includes('text/uri-list');
}

/**
 * Calm full-window drag-and-drop overlay that ONLY appears while dragging external
 * files or URLs over the browser window. Zero persistent chrome at rest.
 */
export const WindowDropOverlay: React.FC = () => {
  const destination = useCoordinatorStore((s) => s.destination);
  const activeBoardID = useCoordinatorStore((s) => s.activeBoardID);
  const captureTarget = useCoordinatorStore((s) => s.captureTarget);
  const pushToast = useCoordinatorStore((s) => s.pushToast);

  const folders = useLibraryStore((s) => s.folders);
  const uploadFiles = useLibraryStore((s) => s.uploadFiles);
  const ingestInputs = useLibraryStore((s) => s.ingestInputs);

  const boards = useMoodboardStore((s) => s.boards);

  const [visible, setVisible] = useState(false);
  const [hoveredZone, setHoveredZone] = useState<DropZoneKey | null>(null);
  const [dropping, setDropping] = useState(false);

  const dragDepthRef = useRef(0);

  const currentFolder = useMemo(() => {
    if (destination.type === 'folder') {
      return folders.find((f) => f.id === destination.id) ?? null;
    }
    if (captureTarget.type === 'folder') {
      return folders.find((f) => f.id === captureTarget.folderID) ?? null;
    }
    return null;
  }, [destination, captureTarget, folders]);

  const activeBoard = useMemo(() => {
    return boards.find((b) => b.id === activeBoardID) ?? boards[0] ?? null;
  }, [boards, activeBoardID]);

  const zones: DropZoneOption[] = useMemo(() => {
    const list: DropZoneOption[] = [
      {
        key: 'inbox',
        label: '收件箱',
        targetFolderID: null,
        targetBoardID: null,
      },
    ];
    if (currentFolder) {
      list.push({
        key: 'folder',
        label: currentFolder.name,
        sublabel: destination.type === 'folder' ? '当前浏览文件夹' : '默认采集文件夹',
        targetFolderID: currentFolder.id,
        targetBoardID: null,
      });
    }
    if (activeBoard) {
      list.push({
        key: 'board',
        label: activeBoard.title,
        sublabel: '当前活跃情绪板',
        targetFolderID: null,
        targetBoardID: activeBoard.id,
      });
    }
    return list;
  }, [currentFolder, destination.type, activeBoard]);

  const defaultZone: DropZoneOption = useMemo(() => {
    if (destination.type === 'folder' && currentFolder) {
      return zones.find((z) => z.key === 'folder') ?? zones[0];
    }
    if (captureTarget.type === 'activeMoodboard' && activeBoard) {
      return zones.find((z) => z.key === 'board') ?? zones[0];
    }
    if (captureTarget.type === 'folder' && currentFolder) {
      return zones.find((z) => z.key === 'folder') ?? zones[0];
    }
    return zones[0];
  }, [destination.type, currentFolder, captureTarget.type, activeBoard, zones]);

  const activeZone =
    (hoveredZone ? zones.find((z) => z.key === hoveredZone) : null) ?? defaultZone;

  const resetOverlay = useCallback(() => {
    dragDepthRef.current = 0;
    setVisible(false);
    setHoveredZone(null);
  }, []);

  const performDrop = useCallback(
    async (dt: DataTransfer, zone: DropZoneOption) => {
      const opts = {
        targetFolderID: zone.targetFolderID,
        targetBoardID: zone.targetBoardID,
      };

      const files = dt.files ? Array.from(dt.files) : [];
      if (files.length > 0) {
        setDropping(true);
        try {
          const created = await uploadFiles(files, opts);
          pushToast({
            tone: 'success',
            message: `已导入 ${created.length} 项素材至「${zone.label}」`,
          });
        } catch (err) {
          pushToast({
            tone: 'error',
            message: err instanceof Error ? err.message : '导入文件失败',
          });
        } finally {
          setDropping(false);
        }
        return;
      }

      const rawUri = dt.getData('text/uri-list') || dt.getData('text/plain') || '';
      const firstLine = rawUri
        .split(/\r?\n/)
        .map((line) => line.trim())
        .find((line) => line.length > 0 && !line.startsWith('#'));

      if (firstLine) {
        const detected = detectURLFromText(firstLine);
        if (detected) {
          setDropping(true);
          try {
            const created = await ingestInputs([{ type: 'webURL', url: detected.url }], opts);
            pushToast({
              tone: 'success',
              message: `已收藏${detected.badge}（${created.length} 项）至「${zone.label}」`,
            });
          } catch (err) {
            pushToast({
              tone: 'error',
              message: err instanceof Error ? err.message : '收藏链接失败',
            });
          } finally {
            setDropping(false);
          }
        }
      }
    },
    [uploadFiles, ingestInputs, pushToast],
  );

  useEffect(() => {
    const isBlockedByContext = () => {
      const coord = useCoordinatorStore.getState();
      return (
        coord.destination.type === 'moodboard' ||
        coord.showQuickCapture ||
        coord.settingsOpen ||
        coord.onboardingOpen ||
        coord.generatorModalOpen ||
        coord.quickLookAssetID !== null
      );
    };

    const onDragEnter = (e: DragEvent) => {
      if (isBlockedByContext() || !isExternalCaptureDrag(e)) return;
      e.preventDefault();
      dragDepthRef.current += 1;
      setVisible(true);
    };

    const onDragOver = (e: DragEvent) => {
      if (isBlockedByContext() || !isExternalCaptureDrag(e)) return;
      e.preventDefault();
      if (e.dataTransfer) {
        e.dataTransfer.dropEffect = 'copy';
      }
      if (!visible) setVisible(true);
    };

    const onDragLeave = (e: DragEvent) => {
      if (dragDepthRef.current <= 0) return;
      dragDepthRef.current -= 1;
      if (dragDepthRef.current <= 0 || e.relatedTarget === null) {
        resetOverlay();
      }
    };

    const onWindowDrop = (e: DragEvent) => {
      if (!visible) return;
      // If dropped onto the overlay portal itself, React's onDrop already handled it
      resetOverlay();
    };

    window.addEventListener('dragenter', onDragEnter);
    window.addEventListener('dragover', onDragOver);
    window.addEventListener('dragleave', onDragLeave);
    window.addEventListener('drop', onWindowDrop);
    window.addEventListener('dragend', resetOverlay);
    window.addEventListener('blur', resetOverlay);

    return () => {
      window.removeEventListener('dragenter', onDragEnter);
      window.removeEventListener('dragover', onDragOver);
      window.removeEventListener('dragleave', onDragLeave);
      window.removeEventListener('drop', onWindowDrop);
      window.removeEventListener('dragend', resetOverlay);
      window.removeEventListener('blur', resetOverlay);
    };
  }, [visible, resetOverlay]);

  const presence = usePresence(visible, 175);

  if (!presence.rendered || typeof document === 'undefined') return null;

  return createPortal(
    <div
      data-state={presence.state}
      onDragOver={(e) => {
        e.preventDefault();
        e.dataTransfer.dropEffect = 'copy';
      }}
      onDrop={(e) => {
        e.preventDefault();
        e.stopPropagation();
        const dt = e.dataTransfer;
        const chosen = activeZone;
        resetOverlay();
        void performDrop(dt, chosen);
      }}
      className={[
        'charkle-modal-veil charkle-modal-veil-transition fixed inset-0 z-[145] flex items-center justify-center p-5 select-none',
        presence.state === 'closing' ? 'pointer-events-none' : '',
      ].join(' ')}
    >
      {/* Calm full-window dashed drop ring */}
      <div
        aria-hidden="true"
        className="pointer-events-none absolute inset-4 rounded-[22px] border-2 border-dashed border-[var(--accent)]/65"
      />

      {/* Centered translucent floating drop target card */}
      <div
        data-state={presence.state}
        className="charkle-glass charkle-modal-surface-transition relative z-10 w-full max-w-[500px] p-6 rounded-[var(--radius-dock-outer)] flex flex-col items-center gap-4 text-center"
      >
        <div className="h-11 w-11 rounded-[var(--radius-dock-inner)] bg-[var(--accent-soft)] text-[var(--accent)] flex items-center justify-center">
          <Upload size={20} />
        </div>

        <div className="text-[15.5px] font-semibold text-[var(--text-primary)]">
          {dropping ? '正在导入…' : `松开导入至「${activeZone.label}」`}
        </div>

        {/* Direct Target Drop Zones */}
        <div className="w-full grid grid-cols-1 sm:grid-cols-3 gap-2 pt-1">
          {zones.map((zone) => {
            const isSelected = activeZone.key === zone.key;
            const Icon =
              zone.key === 'inbox' ? Inbox : zone.key === 'folder' ? Folder : LayoutGrid;
            return (
              <div
                key={zone.key}
                onDragEnter={(e) => {
                  e.preventDefault();
                  e.stopPropagation();
                  setHoveredZone(zone.key);
                }}
                onDragOver={(e) => {
                  e.preventDefault();
                  e.stopPropagation();
                  e.dataTransfer.dropEffect = 'copy';
                  setHoveredZone(zone.key);
                }}
                onDrop={(e) => {
                  e.preventDefault();
                  e.stopPropagation();
                  const dt = e.dataTransfer;
                  resetOverlay();
                  void performDrop(dt, zone);
                }}
                className={[
                  'px-3 py-2.5 rounded-[var(--radius-dock-inner)] border text-left flex flex-col gap-1',
                  'transition-[background-color,border-color,box-shadow] duration-[var(--duration-press)] ease-[var(--ease-out)]',
                  isSelected
                    ? 'bg-[var(--accent-soft)] border-[var(--accent)] ring-2 ring-[var(--accent-ring)]'
                    : 'bg-[var(--bg-elevated)]/85 border-[var(--border-hairline)]',
                ].join(' ')}
              >
                <div className="flex items-center gap-1.5 text-[12.5px] font-medium text-[var(--text-primary)]">
                  <Icon
                    size={13.5}
                    className={
                      isSelected ? 'text-[var(--accent)] shrink-0' : 'text-[var(--text-secondary)] shrink-0'
                    }
                  />
                  <span className="truncate">{zone.label}</span>
                </div>
                {zone.sublabel && (
                  <span className="text-[11px] text-[var(--text-tertiary)] truncate">
                    {zone.sublabel}
                  </span>
                )}
              </div>
            );
          })}
        </div>
      </div>
    </div>,
    document.body,
  );
};
