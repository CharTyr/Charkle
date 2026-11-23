import React, { useMemo, useRef, useState } from 'react';
import { ChevronRight, Inbox } from 'lucide-react';
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
}

const SubmenuBranch: React.FC<{
  node: FolderTreeNode;
  currentFolderId?: string | null;
  onSelectFolder: (folderId: string | null) => void;
}> = ({ node, currentFolderId, onSelectFolder }) => {
  const [hovered, setHovered] = useState(false);
  const subRef = useRef<HTMLDivElement | null>(null);
  const [pointerVars, setPointerVars] = useState<{ x: number; y: number }>({ x: -8, y: 12 });

  const handleMouseMove = (e: React.MouseEvent) => {
    const el = subRef.current;
    if (!el) return;
    const rect = el.getBoundingClientRect();
    setPointerVars({
      x: Math.round(e.clientX - rect.left),
      y: Math.round(e.clientY - rect.top),
    });
  };

  const hasChildren = node.children.length > 0;
  const active = currentFolderId === node.folder.id;

  return (
    <div
      className="relative"
      onMouseEnter={() => setHovered(true)}
      onMouseLeave={() => setHovered(false)}
      onMouseMove={hasChildren ? handleMouseMove : undefined}
    >
      <button
        type="button"
        onClick={() => onSelectFolder(node.folder.id)}
        className={[
          'w-full flex items-center gap-2 px-2.5 py-1.5 text-[12.5px] rounded-[var(--radius-popover-inner)] cursor-pointer text-left',
          active
            ? 'bg-[var(--accent-soft)] text-[var(--accent)] font-medium'
            : 'text-[var(--text-primary)] hover:bg-[var(--bg-subtle)]',
        ].join(' ')}
      >
        <CharkleFolderIcon
          colorHex={node.folder.colorHex}
          customSymbol={node.folder.customSymbol}
          size={15}
          isActive={active}
        />
        <span className="truncate flex-1 min-w-0">{node.folder.name}</span>
        {hasChildren && <ChevronRight size={13} className="text-[var(--text-tertiary)] shrink-0" />}
      </button>

      {hasChildren && hovered && (
        <div
          ref={subRef}
          data-bridge="true"
          className="charkle-submenu-portal charkle-glass absolute left-[calc(100%+4px)] top-0 z-[140] min-w-[180px] p-1.5 rounded-[var(--radius-popover-outer)]"
          style={
            {
              '--pointer-x': `${pointerVars.x}px`,
              '--pointer-y': `${pointerVars.y}px`,
            } as React.CSSProperties
          }
        >
          {node.children.map((child) => (
            <SubmenuBranch
              key={child.folder.id}
              node={child}
              currentFolderId={currentFolderId}
              onSelectFolder={onSelectFolder}
            />
          ))}
        </div>
      )}
    </div>
  );
};

/**
 * Cascading hierarchical folder-move menu equipped with CSS Safe-Triangle pointer bridge
 * (DESIGN.md §7.4 & modern-web-guidance menu spec).
 */
export const FolderMoveMenu: React.FC<FolderMoveMenuProps> = ({
  folders,
  onSelectFolder,
  currentFolderId,
}) => {
  const tree = useMemo(() => buildFolderTree(folders), [folders]);

  return (
    <div className="flex flex-col gap-0.5 min-w-[188px]">
      <button
        type="button"
        onClick={() => onSelectFolder(null)}
        className={[
          'w-full flex items-center gap-2 px-2.5 py-1.5 text-[12.5px] rounded-[var(--radius-popover-inner)] cursor-pointer text-left',
          currentFolderId === null
            ? 'bg-[var(--accent-soft)] text-[var(--accent)] font-medium'
            : 'text-[var(--text-primary)] hover:bg-[var(--bg-subtle)]',
        ].join(' ')}
      >
        <Inbox size={14} className="text-[var(--text-secondary)] shrink-0" />
        <span className="truncate">移至收件箱</span>
      </button>

      {tree.length > 0 && <div className="my-1 h-px bg-[var(--border-hairline)]" />}

      {tree.map((node) => (
        <SubmenuBranch
          key={node.folder.id}
          node={node}
          currentFolderId={currentFolderId}
          onSelectFolder={onSelectFolder}
        />
      ))}
    </div>
  );
};
