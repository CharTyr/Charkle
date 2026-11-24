import React, { useEffect, useMemo, useRef, useState } from 'react';
import { Check, ChevronRight, Inbox } from 'lucide-react';
import { CharkleFolderIcon } from '../../design-system';
import {
  buildFolderTree,
  type FolderRecord,
  type FolderTreeNode,
} from '../../types/domain';

export interface FolderMoveMenuProps {
  folders: FolderRecord[];
  onSelectFolder: (folderId: string | null) => void;
  currentFolderId?: string | null;
  includeInbox?: boolean;
  highlightSelection?: boolean;
  parentSelfPrefix?: string;
}

function nodeContainsFolderId(
  node: FolderTreeNode,
  targetId: string | null | undefined,
): boolean {
  if (!targetId) return false;
  if (node.folder.id === targetId) return true;
  return node.children.some((child) => nodeContainsFolderId(child, targetId));
}

const SubmenuBranch: React.FC<{
  node: FolderTreeNode;
  currentFolderId?: string | null;
  highlightSelection: boolean;
  parentSelfPrefix: string;
  onSelectFolder: (folderId: string | null) => void;
}> = ({
  node,
  currentFolderId,
  highlightSelection,
  parentSelfPrefix,
  onSelectFolder,
}) => {
  const [hovered, setHovered] = useState(false);
  const [openLeft, setOpenLeft] = useState(false);
  const rowWrapRef = useRef<HTMLDivElement | null>(null);
  const subRef = useRef<HTMLDivElement | null>(null);
  const closeTimerRef = useRef<number | null>(null);
  const [pointerVars, setPointerVars] = useState<{ x: number; y: number }>({ x: -8, y: 12 });

  const hasChildren = node.children.length > 0;
  const isSelected = highlightSelection && currentFolderId === node.folder.id;
  const hasSelectedDescendant =
    highlightSelection && !isSelected && nodeContainsFolderId(node, currentFolderId);

  const openSubmenu = () => {
    if (closeTimerRef.current !== null) {
      window.clearTimeout(closeTimerRef.current);
      closeTimerRef.current = null;
    }
    if (hasChildren && rowWrapRef.current && typeof window !== 'undefined') {
      const rect = rowWrapRef.current.getBoundingClientRect();
      setOpenLeft(rect.right + 204 > window.innerWidth);
    }
    setHovered(true);
  };

  const scheduleClose = () => {
    if (closeTimerRef.current !== null) {
      window.clearTimeout(closeTimerRef.current);
    }
    closeTimerRef.current = window.setTimeout(() => {
      closeTimerRef.current = null;
      setHovered(false);
    }, 90);
  };

  useEffect(() => {
    return () => {
      if (closeTimerRef.current !== null) {
        window.clearTimeout(closeTimerRef.current);
        closeTimerRef.current = null;
      }
    };
  }, []);

  const handleMouseMove = (e: React.MouseEvent) => {
    const el = subRef.current;
    if (!el) return;
    const rect = el.getBoundingClientRect();
    setPointerVars({
      x: Math.round(e.clientX - rect.left),
      y: Math.round(e.clientY - rect.top),
    });
  };

  return (
    <div
      ref={rowWrapRef}
      className="relative"
      onMouseEnter={openSubmenu}
      onMouseLeave={scheduleClose}
      onMouseMove={hasChildren && !openLeft ? handleMouseMove : undefined}
    >
      <button
        type="button"
        onClick={() => onSelectFolder(node.folder.id)}
        className={[
          'charkle-pressable w-full flex items-center gap-2 px-2.5 py-1.5 text-[12px] rounded-[var(--radius-popover-inner)] cursor-pointer text-left',
          isSelected
            ? 'bg-[var(--accent-soft)] text-[var(--accent)] font-medium'
            : 'text-[var(--text-primary)] hover:bg-[var(--bg-subtle)]',
        ].join(' ')}
      >
        <CharkleFolderIcon
          colorHex={node.folder.colorHex}
          customSymbol={node.folder.customSymbol}
          size={15}
          isActive={isSelected}
        />
        <span className="truncate flex-1 min-w-0">
          {node.folder.name}
          {(isSelected || hasSelectedDescendant) && hasChildren ? ' •' : ''}
        </span>
        {!hasChildren && isSelected && (
          <Check size={12.5} className="text-[var(--accent)] shrink-0" />
        )}
        {hasChildren && (
          <ChevronRight size={12.5} className="text-[var(--text-tertiary)] shrink-0" />
        )}
      </button>

      {hasChildren && hovered && (
        <div
          ref={subRef}
          data-bridge={!openLeft ? 'true' : undefined}
          onMouseEnter={openSubmenu}
          onMouseLeave={scheduleClose}
          className={[
            'charkle-submenu-portal charkle-glass charkle-popover-panel absolute top-[-4px] z-[180] min-w-[184px] max-w-[230px] p-1 rounded-[var(--radius-popover-outer)]',
            openLeft ? 'right-[calc(100%+4px)]' : 'left-[calc(100%+4px)]',
          ].join(' ')}
          style={
            {
              transformOrigin: openLeft ? 'top right' : 'top left',
              '--pointer-x': `${pointerVars.x}px`,
              '--pointer-y': `${pointerVars.y}px`,
            } as React.CSSProperties
          }
        >
          <button
            type="button"
            onClick={() => onSelectFolder(node.folder.id)}
            className={[
              'charkle-pressable w-full flex items-center gap-2 px-2.5 py-1.5 text-[12px] rounded-[var(--radius-popover-inner)] cursor-pointer text-left',
              isSelected
                ? 'bg-[var(--accent-soft)] text-[var(--accent)] font-medium'
                : 'text-[var(--text-primary)] hover:bg-[var(--bg-subtle)]',
            ].join(' ')}
          >
            <CharkleFolderIcon
              colorHex={node.folder.colorHex}
              customSymbol={node.folder.customSymbol}
              size={14}
              isActive={isSelected}
            />
            <span className="truncate flex-1 min-w-0">
              {parentSelfPrefix}「{node.folder.name}」
            </span>
            {isSelected && <Check size={12.5} className="text-[var(--accent)] shrink-0" />}
          </button>

          <div className="my-1 h-px bg-[var(--border-hairline)]" />

          <div className="flex flex-col gap-0.5">
            {node.children.map((child) => (
              <SubmenuBranch
                key={child.folder.id}
                node={child}
                currentFolderId={currentFolderId}
                highlightSelection={highlightSelection}
                parentSelfPrefix={parentSelfPrefix}
                onSelectFolder={onSelectFolder}
              />
            ))}
          </div>
        </div>
      )}
    </div>
  );
};

/**
 * Cascading hierarchical folder-move menu (1:1 macOS `CharkleHierarchicalFolderMenuContent`)
 * with automatic right-edge viewport flip and pointer bridge.
 */
export const FolderMoveMenu: React.FC<FolderMoveMenuProps> = ({
  folders,
  onSelectFolder,
  currentFolderId,
  includeInbox = true,
  highlightSelection,
  parentSelfPrefix = '放入',
}) => {
  const tree = useMemo(() => buildFolderTree(folders), [folders]);
  const shouldHighlight = highlightSelection ?? currentFolderId !== undefined;
  const isInboxSelected = shouldHighlight && currentFolderId === null;

  return (
    <div className="flex flex-col gap-0.5 min-w-[184px]">
      {includeInbox && (
        <button
          type="button"
          onClick={() => onSelectFolder(null)}
          className={[
            'charkle-pressable w-full flex items-center gap-2 px-2.5 py-1.5 text-[12px] rounded-[var(--radius-popover-inner)] cursor-pointer text-left',
            isInboxSelected
              ? 'bg-[var(--accent-soft)] text-[var(--accent)] font-medium'
              : 'text-[var(--text-primary)] hover:bg-[var(--bg-subtle)]',
          ].join(' ')}
        >
          <Inbox size={14} className="text-[var(--text-secondary)] shrink-0" />
          <span className="truncate flex-1 min-w-0">收件箱</span>
          {isInboxSelected && <Check size={12.5} className="text-[var(--accent)] shrink-0" />}
        </button>
      )}

      {includeInbox && tree.length > 0 && (
        <div className="my-1 h-px bg-[var(--border-hairline)]" />
      )}

      {tree.length === 0 && !includeInbox ? (
        <div className="px-2.5 py-1.5 text-[11.5px] text-[var(--text-tertiary)]">暂无文件夹</div>
      ) : (
        tree.map((node) => (
          <SubmenuBranch
            key={node.folder.id}
            node={node}
            currentFolderId={currentFolderId}
            highlightSelection={shouldHighlight}
            parentSelfPrefix={parentSelfPrefix}
            onSelectFolder={onSelectFolder}
          />
        ))
      )}
    </div>
  );
};
