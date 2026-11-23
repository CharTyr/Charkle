import { useEffect } from 'react';
import type { CaptureInput, UUID } from '@charkle/shared';
import type { CaptureTarget } from '../../stores/coordinatorStore';
import { useCoordinatorStore } from '../../stores/coordinatorStore';
import { useLibraryStore } from '../../stores/libraryStore';
import { useMoodboardStore } from '../../stores/moodboardStore';
import { fileToBase64, isEditableElement, textToCaptureInput } from './captureUtils';

export interface ResolvedCaptureTarget {
  targetFolderID: UUID | null;
  targetBoardID: UUID | null;
  label: string;
}

export function resolveCaptureTarget(target: CaptureTarget): ResolvedCaptureTarget {
  const { folders } = useLibraryStore.getState();
  const { boards } = useMoodboardStore.getState();
  const { activeBoardID } = useCoordinatorStore.getState();

  if (target.type === 'folder') {
    const folder = folders.find((f) => f.id === target.folderID);
    if (folder) {
      return { targetFolderID: folder.id, targetBoardID: null, label: `文件夹「${folder.name}」` };
    }
  }

  if (target.type === 'activeMoodboard') {
    const board = boards.find((b) => b.id === activeBoardID) ?? boards[0];
    if (board) {
      return { targetFolderID: null, targetBoardID: board.id, label: `情绪板「${board.title}」` };
    }
  }

  return { targetFolderID: null, targetBoardID: null, label: '收件箱' };
}

/**
 * Headless global ⌘V / Ctrl+V clipboard capture listener.
 * Ignores inputs/textareas/modals/Moodboard canvas/internal cut-paste moves.
 * Supports pasted images/files, X/Threads/Bluesky/GitHub/Web URLs, #HEX swatches, and text snippets.
 */
export function useGlobalPasteCapture(): void {
  useEffect(() => {
    const onPaste = async (e: ClipboardEvent) => {
      if (isEditableElement(e.target) || isEditableElement(document.activeElement)) return;

      const coord = useCoordinatorStore.getState();
      if (
        coord.quickLookAssetID ||
        coord.jumpAnywhereOpen ||
        coord.settingsOpen ||
        coord.onboardingOpen ||
        coord.generatorModalOpen ||
        coord.showQuickCapture
      ) {
        return;
      }

      // Moodboard canvas has its own native world-coordinate paste handler
      if (coord.destination.type === 'moodboard') return;

      // Let App.tsx's internal ⌘X -> ⌘V folder move take priority when assets are cut
      const lib = useLibraryStore.getState();
      if (
        lib.cutAssetIDs.size > 0 &&
        (coord.destination.type === 'folder' || coord.destination.type === 'inbox')
      ) {
        return;
      }

      const dt = e.clipboardData;
      if (!dt) return;

      // Determine destination: if browsing a specific folder & target is default inbox,
      // honour explicit captureTarget (inbox / specific folder / active moodboard).
      const resolved = resolveCaptureTarget(coord.captureTarget);
      const opts = {
        targetFolderID: resolved.targetFolderID,
        targetBoardID: resolved.targetBoardID,
      };

      // 1. Files / clipboard images
      const pastedFiles: File[] = [];
      if (dt.files && dt.files.length > 0) {
        for (let i = 0; i < dt.files.length; i++) {
          const f = dt.files.item(i);
          if (f) pastedFiles.push(f);
        }
      } else if (dt.items && dt.items.length > 0) {
        for (let i = 0; i < dt.items.length; i++) {
          const item = dt.items[i];
          if (item.kind === 'file') {
            const f = item.getAsFile();
            if (f) pastedFiles.push(f);
          }
        }
      }

      if (pastedFiles.length > 0) {
        e.preventDefault();
        try {
          const hasNamedNonImage = pastedFiles.some(
            (f) => !f.type.startsWith('image/') || f.size > 4 * 1024 * 1024,
          );
          if (hasNamedNonImage) {
            const created = await lib.uploadFiles(pastedFiles, opts);
            coord.pushToast({
              tone: 'success',
              message: `已粘贴并采集 ${created.length} 项素材至${resolved.label}`,
            });
          } else {
            const inputs: CaptureInput[] = [];
            for (const file of pastedFiles) {
              const base64Data = await fileToBase64(file);
              const ext = file.type.split('/')[1]?.replace('jpeg', 'jpg') || 'png';
              const stamp = new Date().toISOString().replace(/[:.]/g, '-').slice(0, 19);
              inputs.push({
                type: 'imageData',
                base64Data,
                suggestedName: file.name && file.name !== 'image.png'
                  ? file.name
                  : `charkle-paste-${stamp}.${ext}`,
              });
            }
            const created = await lib.ingestInputs(inputs, opts);
            coord.pushToast({
              tone: 'success',
              message: `已粘贴并采集 ${created.length} 张剪贴板图片至${resolved.label}`,
            });
          }
        } catch (err) {
          coord.pushToast({
            tone: 'error',
            message: err instanceof Error ? err.message : '粘贴采集失败',
          });
        }
        return;
      }

      // 2. Text / URL / #HEX color swatch
      const rawText = dt.getData('text/plain');
      const input = textToCaptureInput(rawText);
      if (!input) return;

      e.preventDefault();
      try {
        const created = await lib.ingestInputs([input], opts);
        const kindLabel =
          input.type === 'colorSwatch'
            ? `色卡 ${input.hex}`
            : input.type === 'webURL'
              ? '网页链接'
              : '文字灵感';
        coord.pushToast({
          tone: 'success',
          message: `已采集${kindLabel}（${created.length} 项）至${resolved.label}`,
        });
      } catch (err) {
        coord.pushToast({
          tone: 'error',
          message: err instanceof Error ? err.message : '粘贴采集失败',
        });
      }
    };

    window.addEventListener('paste', onPaste);
    return () => window.removeEventListener('paste', onPaste);
  }, []);
}
