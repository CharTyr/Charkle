import React, { useMemo } from 'react';
import { Check, ChevronRight } from 'lucide-react';
import { buildFolderTree, folderNodeContains } from '@charkle/shared';
import type { FolderHierarchyNode, FolderRecord, UUID } from '@charkle/shared';
import { CharkleFolderIcon, CharkleIcon } from './CharkleIcon';
import { useSafeTriangleSubmenu } from './hoverIntent';
import { usePresence } from './usePresence';

export interface FolderHierarchyMenuProps {
  folders: readonly FolderRecord[];
  includeInbox?: boolean;
  selectedFolderID?: UUID | null;
  highlightSelection?: boolean;
  parentSelfPrefix?: string;
  onSelectFolder: (folderID: UUID | null) => void;
  submenuSide?: 'right' | 'left';
  className?: string;
}

interface SubmenuPanelProps {
  open: boolean;
  submenuSide: 'right' | 'left';
  panelRef: React.MutableRefObject<HTMLDivElement | null>;
  onMouseEnter: () => void;
  children: React.ReactNode;
}

const FolderSubmenuPanel: React.FC<SubmenuPanelProps> = ({
  open,
  submenuSide,
  panelRef,
  onMouseEnter,
  children,
}) => {
  const { rendered, state } = usePresence(open, 115);
  if (!rendered) return null;

  return (
    <div
      ref={(el) => {
        if (open) panelRef.current = el;
      }}
      role="menu"
      data-state={state}
      onMouseEnter={onMouseEnter}
      style={{ transformOrigin: submenuSide === 'left' ? 'top right' : 'top left' }}
      className={[
        'charkle-popover-transition absolute top-0 z-30 min-w-[208px] max-w-[256px] p-1.5',
        'rounded-[var(--radius-popover-outer)] bg-[var(--bg-elevated)] border border-[var(--border-strong)] shadow-xl',
        state === 'closing' ? 'pointer-events-none' : '',
        // Invisible hover bridge spanning the gap between parent item and submenu
        submenuSide === 'left'
          ? 'right-full mr-1 before:content-[""] before:absolute before:inset-y-0 before:-right-2 before:w-2.5'
          : 'left-full ml-1 before:content-[""] before:absolute before:inset-y-0 before:-left-2 before:w-2.5',
      ].join(' ')}
    >
      {children}
    </div>
  );
};

interface BranchProps {
  nodes: readonly FolderHierarchyNode[];
  selectedFolderID?: UUID | null;
  highlightSelection: boolean;
  parentSelfPrefix: string;
  onSelectFolder: (folderID: UUID | null) => void;
  submenuSide: 'right' | 'left';
}

const FolderHierarchyMenuBranch: React.FC<BranchProps> = ({
  nodes,
  selectedFolderID,
  highlightSelection,
  parentSelfPrefix,
  onSelectFolder,
  submenuSide,
}) => {
  const {
    openKey: openChildID,
    setOpenKey: setOpenChildID,
    submenuElRef,
    recordPointer,
    requestOpen: requestOpenChild,
    cancelPendingClose,
  } = useSafeTriangleSubmenu<UUID>(submenuSide, 145);

  return (
    <>
      {nodes.map((node) => {
        const folder = node.folder;
        const hasChildren = node.children.length > 0;
        const isSelected = highlightSelection && selectedFolderID === folder.id;
        const hasSelectedDescendant =
          highlightSelection && !isSelected && folderNodeContains(node, selectedFolderID);
        const childOpen = openChildID === folder.id;

        if (!hasChildren) {
          return (
            <button
              key={folder.id}
              type="button"
              role="menuitem"
              onMouseEnter={(e) => requestOpenChild(null, e)}
              onClick={() => onSelectFolder(folder.id)}
              className={[
                'charkle-pressable w-full px-2.5 py-1.5 rounded-[var(--radius-popover-inner)] flex items-center gap-2 text-left text-[12.5px] cursor-pointer',
                'hover:bg-[var(--bg-subtle)] text-[var(--text-primary)]',
                isSelected ? 'bg-[var(--accent-soft)]/60 text-[var(--accent)] font-medium' : '',
              ].join(' ')}
            >
              {isSelected ? (
                <Check size={14} className="text-[var(--accent)] shrink-0" />
              ) : (
                <CharkleFolderIcon
                  colorHex={folder.colorHex}
                  customSymbol={folder.customSymbol}
                  size={15}
                />
              )}
              <span className="truncate flex-1">{folder.name}</span>
            </button>
          );
        }

        return (
          <div
            key={folder.id}
            className="relative"
            onMouseMove={recordPointer}
            onMouseEnter={(e) => requestOpenChild(folder.id, e)}
          >
            <button
              type="button"
              role="menuitem"
              aria-haspopup="menu"
              aria-expanded={childOpen}
              onClick={(e) => {
                e.stopPropagation();
                setOpenChildID((cur) => (cur === folder.id ? null : folder.id));
              }}
              onKeyDown={(e) => {
                if (e.key === 'ArrowRight') {
                  e.preventDefault();
                  setOpenChildID(folder.id);
                } else if (e.key === 'ArrowLeft' && childOpen) {
                  e.preventDefault();
                  setOpenChildID(null);
                }
              }}
              className={[
                'charkle-pressable w-full px-2.5 py-1.5 rounded-[var(--radius-popover-inner)] flex items-center gap-2 text-left text-[12.5px] cursor-pointer',
                childOpen
                  ? 'bg-[var(--bg-subtle)] text-[var(--text-primary)]'
                  : 'hover:bg-[var(--bg-subtle)] text-[var(--text-primary)]',
                isSelected ? 'font-medium text-[var(--accent)]' : '',
              ].join(' ')}
            >
              <CharkleFolderIcon
                colorHex={folder.colorHex}
                customSymbol={folder.customSymbol}
                size={15}
              />
              <span className="truncate flex-1">
                {folder.name}
                {isSelected || hasSelectedDescendant ? ' •' : ''}
              </span>
              <ChevronRight size={13} className="text-[var(--text-tertiary)] shrink-0" />
            </button>

            <FolderSubmenuPanel
              open={childOpen}
              submenuSide={submenuSide}
              panelRef={submenuElRef}
              onMouseEnter={cancelPendingClose}
            >
              <button
                type="button"
                role="menuitem"
                onClick={() => onSelectFolder(folder.id)}
                className={[
                  'charkle-pressable w-full px-2.5 py-1.5 rounded-[var(--radius-popover-inner)] flex items-center gap-2 text-left text-[12.5px] cursor-pointer',
                  'hover:bg-[var(--bg-subtle)] text-[var(--text-primary)]',
                  isSelected ? 'bg-[var(--accent-soft)]/60 text-[var(--accent)] font-medium' : '',
                ].join(' ')}
              >
                {isSelected ? (
                  <Check size={14} className="text-[var(--accent)] shrink-0" />
                ) : (
                  <CharkleFolderIcon
                    colorHex={folder.colorHex}
                    customSymbol={folder.customSymbol}
                    size={15}
                  />
                )}
                <span className="truncate flex-1">
                  {parentSelfPrefix}「{folder.name}」
                </span>
              </button>

              <div className="my-1 border-t border-[var(--border-hairline)]" />

              <FolderHierarchyMenuBranch
                nodes={node.children}
                selectedFolderID={selectedFolderID}
                highlightSelection={highlightSelection}
                parentSelfPrefix={parentSelfPrefix}
                onSelectFolder={onSelectFolder}
                submenuSide={submenuSide}
              />
            </FolderSubmenuPanel>
          </div>
        );
      })}
    </>
  );
};

/**
 * Recursive cascading folder menu with pointer-trajectory safe-triangle buffer (`DESIGN.md` §7.4).
 * Folders with children open a child submenu featuring a self-target action (`放入「父目录」`),
 * divider, and recursive descendants in deterministic tree order.
 */
export const FolderHierarchyMenu: React.FC<FolderHierarchyMenuProps> = ({
  folders,
  includeInbox = true,
  selectedFolderID = null,
  highlightSelection = false,
  parentSelfPrefix = '放入',
  onSelectFolder,
  submenuSide = 'right',
  className = '',
}) => {
  const roots = useMemo(() => buildFolderTree(folders), [folders]);

  return (
    <div
      role="menu"
      className={`min-w-[216px] p-1.5 flex flex-col gap-0.5 text-[12.5px] select-none ${className}`}
    >
      {includeInbox && (
        <>
          <button
            type="button"
            role="menuitem"
            onClick={() => onSelectFolder(null)}
            className={[
              'charkle-pressable w-full px-2.5 py-1.5 rounded-[var(--radius-popover-inner)] flex items-center gap-2 text-left cursor-pointer',
              'hover:bg-[var(--bg-subtle)] text-[var(--text-primary)]',
              highlightSelection && selectedFolderID === null
                ? 'bg-[var(--accent-soft)]/60 text-[var(--accent)] font-medium'
                : '',
            ].join(' ')}
          >
            {highlightSelection && selectedFolderID === null ? (
              <Check size={14} className="text-[var(--accent)] shrink-0" />
            ) : (
              <CharkleIcon name="inbox" size={15} />
            )}
            <span className="truncate flex-1">收件箱</span>
          </button>
          {roots.length > 0 && <div className="my-1 border-t border-[var(--border-hairline)]" />}
        </>
      )}

      {roots.length === 0 && !includeInbox ? (
        <div className="px-2.5 py-2 text-[12px] text-[var(--text-tertiary)]">暂无文件夹</div>
      ) : (
        <FolderHierarchyMenuBranch
          nodes={roots}
          selectedFolderID={selectedFolderID}
          highlightSelection={highlightSelection}
          parentSelfPrefix={parentSelfPrefix}
          onSelectFolder={onSelectFolder}
          submenuSide={submenuSide}
        />
      )}
    </div>
  );
};
