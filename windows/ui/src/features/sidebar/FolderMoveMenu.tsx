import React, { useMemo } from 'react';
import { Menu as BaseMenu } from '@base-ui/react/menu';
import {
  Checkmark16Regular,
  ChevronRight16Regular,
  MailInbox16Regular,
} from '@fluentui/react-icons';
import {
  CharkleFolderIcon,
  MenuItem,
  MenuSeparator,
  MenuSub,
} from '../../design-system';
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
  /** Set true when rendered directly inside a Fluent `DropdownMenu` / `ContextMenu`. */
  inMenu?: boolean;
}

function nodeContainsFolderId(
  node: FolderTreeNode,
  targetId: string | null | undefined,
): boolean {
  if (!targetId) return false;
  if (node.folder.id === targetId) return true;
  return node.children.some((child) => nodeContainsFolderId(child, targetId));
}

const stopSubmenuPropagation = {
  onMouseDown: (e: React.MouseEvent) => e.stopPropagation(),
  onPointerDown: (e: React.PointerEvent) => e.stopPropagation(),
  onClick: (e: React.MouseEvent) => e.stopPropagation(),
  onDoubleClick: (e: React.MouseEvent) => e.stopPropagation(),
  onContextMenu: (e: React.MouseEvent) => e.stopPropagation(),
};

/**
 * Recursive cascading items rendered inside a `@base-ui/react/menu` context (`MenuSub` + `MenuItem`)
 * with native Floating UI safe-triangle hover intent and automatic viewport edge flipping.
 */
const NestedMenuNode: React.FC<{
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
  const hasChildren = node.children.length > 0;
  const isSelected = highlightSelection && currentFolderId === node.folder.id;
  const hasSelectedDescendant =
    highlightSelection && !isSelected && nodeContainsFolderId(node, currentFolderId);

  const folderIcon = (
    <CharkleFolderIcon
      colorHex={node.folder.colorHex}
      customSymbol={node.folder.customSymbol}
      size={15}
      isActive={isSelected}
    />
  );

  if (!hasChildren) {
    return (
      <MenuItem
        icon={folderIcon}
        onSelect={() => onSelectFolder(node.folder.id)}
        className={isSelected ? 'bg-[var(--win-subtle-active)] text-[var(--accent)] font-medium' : ''}
      >
        <span className="flex items-center justify-between gap-2 min-w-0">
          <span className="truncate">{node.folder.name}</span>
          {isSelected && <Checkmark16Regular className="w-3.5 h-3.5 text-[var(--accent)] shrink-0" />}
        </span>
      </MenuItem>
    );
  }

  return (
    <MenuSub
      icon={folderIcon}
      label={
        <span className="truncate">
          {node.folder.name}
          {isSelected || hasSelectedDescendant ? ' •' : ''}
        </span>
      }
      popupClassName="min-w-[188px] max-w-[260px]"
    >
      <MenuItem
        icon={folderIcon}
        onSelect={() => onSelectFolder(node.folder.id)}
        className={isSelected ? 'bg-[var(--win-subtle-active)] text-[var(--accent)] font-medium' : ''}
      >
        <span className="flex items-center justify-between gap-2 min-w-0">
          <span className="truncate">
            {parentSelfPrefix}「{node.folder.name}」
          </span>
          {isSelected && <Checkmark16Regular className="w-3.5 h-3.5 text-[var(--accent)] shrink-0" />}
        </span>
      </MenuItem>
      <MenuSeparator />
      {node.children.map((child) => (
        <NestedMenuNode
          key={child.folder.id}
          node={child}
          currentFolderId={currentFolderId}
          highlightSelection={highlightSelection}
          parentSelfPrefix={parentSelfPrefix}
          onSelectFolder={onSelectFolder}
        />
      ))}
    </MenuSub>
  );
};

/**
 * Top-level branch used when `FolderMoveMenu` is hosted inside a `Popover` (outside `Menu.Root`):
 * wraps each branch with children in a `@base-ui/react/menu` `Root` + hover-triggered `Trigger`
 * so native safe-triangle hover intent, collision flipping, and `.win-acrylic` portals work everywhere.
 */
const StandaloneFolderBranch: React.FC<{
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
  const hasChildren = node.children.length > 0;
  const isSelected = highlightSelection && currentFolderId === node.folder.id;
  const hasSelectedDescendant =
    highlightSelection && !isSelected && nodeContainsFolderId(node, currentFolderId);

  const rowClass = [
    'charkle-pressable w-full min-h-[32px] flex items-center gap-2.5 px-2.5 py-1.5 text-[13px] leading-[18px]',
    'rounded-[var(--win-radius-control)] cursor-pointer text-left outline-none select-none',
    'focus-visible:outline-2 focus-visible:outline-offset-1 focus-visible:outline-[var(--accent)]',
    isSelected
      ? 'bg-[var(--win-subtle-active)] text-[var(--accent)] font-medium'
      : 'text-[var(--text-primary)] hover:bg-[var(--win-subtle-hover)] active:bg-[var(--win-subtle-active)] data-[popup-open]:bg-[var(--win-subtle-hover)]',
  ].join(' ');

  if (!hasChildren) {
    return (
      <button
        type="button"
        onClick={() => onSelectFolder(node.folder.id)}
        className={rowClass}
      >
        <CharkleFolderIcon
          colorHex={node.folder.colorHex}
          customSymbol={node.folder.customSymbol}
          size={15}
          isActive={isSelected}
        />
        <span className="truncate flex-1 min-w-0">{node.folder.name}</span>
        {isSelected && <Checkmark16Regular className="w-3.5 h-3.5 text-[var(--accent)] shrink-0" />}
      </button>
    );
  }

  return (
    <BaseMenu.Root modal={false}>
      <BaseMenu.Trigger
        openOnHover
        delay={60}
        closeDelay={90}
        render={<button type="button" className={rowClass} />}
      >
        <CharkleFolderIcon
          colorHex={node.folder.colorHex}
          customSymbol={node.folder.customSymbol}
          size={15}
          isActive={isSelected}
        />
        <span className="truncate flex-1 min-w-0">
          {node.folder.name}
          {isSelected || hasSelectedDescendant ? ' •' : ''}
        </span>
        <ChevronRight16Regular className="w-3.5 h-3.5 text-[var(--text-tertiary)] shrink-0" />
      </BaseMenu.Trigger>
      <BaseMenu.Portal>
        <BaseMenu.Positioner
          side="right"
          align="start"
          sideOffset={4}
          alignOffset={-4}
          collisionPadding={10}
          positionMethod="fixed"
          className="z-[180] outline-none"
        >
          <BaseMenu.Popup
            data-charkle-popover-open="true"
            className="win-acrylic win-flyout-popup min-w-[188px] max-w-[260px] p-1 rounded-[var(--win-radius-overlay)] outline-none select-none max-h-[calc(100vh-24px)] overflow-y-auto charkle-scroll"
            {...stopSubmenuPropagation}
          >
            <MenuItem
              icon={
                <CharkleFolderIcon
                  colorHex={node.folder.colorHex}
                  customSymbol={node.folder.customSymbol}
                  size={15}
                  isActive={isSelected}
                />
              }
              onSelect={() => onSelectFolder(node.folder.id)}
              className={
                isSelected ? 'bg-[var(--win-subtle-active)] text-[var(--accent)] font-medium' : ''
              }
            >
              <span className="flex items-center justify-between gap-2 min-w-0">
                <span className="truncate">
                  {parentSelfPrefix}「{node.folder.name}」
                </span>
                {isSelected && (
                  <Checkmark16Regular className="w-3.5 h-3.5 text-[var(--accent)] shrink-0" />
                )}
              </span>
            </MenuItem>
            <MenuSeparator />
            {node.children.map((child) => (
              <NestedMenuNode
                key={child.folder.id}
                node={child}
                currentFolderId={currentFolderId}
                highlightSelection={highlightSelection}
                parentSelfPrefix={parentSelfPrefix}
                onSelectFolder={onSelectFolder}
              />
            ))}
          </BaseMenu.Popup>
        </BaseMenu.Positioner>
      </BaseMenu.Portal>
    </BaseMenu.Root>
  );
};

/**
 * Cascading hierarchical folder-move menu powered by `@base-ui/react/menu` (`MenuSub`)
 * with native safe-triangle hover intent, viewport edge flipping, and `.win-acrylic` styling.
 */
export const FolderMoveMenu: React.FC<FolderMoveMenuProps> = ({
  folders,
  onSelectFolder,
  currentFolderId,
  includeInbox = true,
  highlightSelection,
  parentSelfPrefix = '放入',
  inMenu = false,
}) => {
  const tree = useMemo(() => buildFolderTree(folders), [folders]);
  const shouldHighlight = highlightSelection ?? currentFolderId !== undefined;
  const isInboxSelected = shouldHighlight && currentFolderId === null;

  if (inMenu) {
    return (
      <>
        {includeInbox && (
          <MenuItem
            icon={<MailInbox16Regular className="w-4 h-4" />}
            onSelect={() => onSelectFolder(null)}
            className={
              isInboxSelected ? 'bg-[var(--win-subtle-active)] text-[var(--accent)] font-medium' : ''
            }
          >
            <span className="flex items-center justify-between gap-2 min-w-0">
              <span className="truncate">收件箱</span>
              {isInboxSelected && (
                <Checkmark16Regular className="w-3.5 h-3.5 text-[var(--accent)] shrink-0" />
              )}
            </span>
          </MenuItem>
        )}

        {includeInbox && tree.length > 0 && <MenuSeparator />}

        {tree.length === 0 && !includeInbox ? (
          <div className="px-2.5 py-1.5 text-[12px] text-[var(--text-tertiary)]">暂无文件夹</div>
        ) : (
          tree.map((node) => (
            <NestedMenuNode
              key={node.folder.id}
              node={node}
              currentFolderId={currentFolderId}
              highlightSelection={shouldHighlight}
              parentSelfPrefix={parentSelfPrefix}
              onSelectFolder={onSelectFolder}
            />
          ))
        )}
      </>
    );
  }

  return (
    <div className="flex flex-col gap-0.5 min-w-[188px]">
      {includeInbox && (
        <button
          type="button"
          onClick={() => onSelectFolder(null)}
          className={[
            'charkle-pressable w-full min-h-[32px] flex items-center gap-2.5 px-2.5 py-1.5 text-[13px] leading-[18px]',
            'rounded-[var(--win-radius-control)] cursor-pointer text-left outline-none',
            'focus-visible:outline-2 focus-visible:outline-offset-1 focus-visible:outline-[var(--accent)]',
            isInboxSelected
              ? 'bg-[var(--win-subtle-active)] text-[var(--accent)] font-medium'
              : 'text-[var(--text-primary)] hover:bg-[var(--win-subtle-hover)] active:bg-[var(--win-subtle-active)]',
          ].join(' ')}
        >
          <MailInbox16Regular className="w-4 h-4 text-[var(--text-secondary)] shrink-0" />
          <span className="truncate flex-1 min-w-0">收件箱</span>
          {isInboxSelected && (
            <Checkmark16Regular className="w-3.5 h-3.5 text-[var(--accent)] shrink-0" />
          )}
        </button>
      )}

      {includeInbox && tree.length > 0 && (
        <div className="my-1 mx-2 h-px bg-[var(--win-stroke-divider)]" />
      )}

      {tree.length === 0 && !includeInbox ? (
        <div className="px-2.5 py-1.5 text-[12px] text-[var(--text-tertiary)]">暂无文件夹</div>
      ) : (
        tree.map((node) => (
          <StandaloneFolderBranch
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
