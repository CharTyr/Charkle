import React, { useEffect, useMemo, useRef, useState } from 'react';
import { Check, ChevronRight } from 'lucide-react';
import { buildFolderTree, flattenFolderTree, folderNodeContains } from '@charkle/shared';
import type { FolderHierarchyNode, FolderRecord, UUID } from '@charkle/shared';
import { CharkleFolderIcon, CharkleIcon } from './CharkleIcon';

export interface FolderHierarchyScopeTreeProps {
  folders: readonly FolderRecord[];
  selectedFolderIDs: ReadonlySet<UUID>;
  onChange: (next: Set<UUID>) => void;
  className?: string;
}

/**
 * Compact collapsible multi-select hierarchical folder tree (port of macOS `CharkleHierarchicalFolderScopeTree`).
 */
export const FolderHierarchyScopeTree: React.FC<FolderHierarchyScopeTreeProps> = ({
  folders,
  selectedFolderIDs,
  onChange,
  className = '',
}) => {
  const [expandedIDs, setExpandedIDs] = useState<Set<UUID>>(() => new Set());
  const seededRef = useRef(false);

  const roots = useMemo(() => buildFolderTree(folders), [folders]);

  useEffect(() => {
    if (seededRef.current || folders.length === 0) return;
    seededRef.current = true;
    const initial = new Set<UUID>();
    if (folders.length <= 12) {
      for (const node of flattenFolderTree(folders)) {
        if (node.children.length > 0) initial.add(node.id);
      }
    } else {
      for (const root of roots) {
        if (root.children.length > 0) {
          for (const selID of selectedFolderIDs) {
            if (folderNodeContains(root, selID)) {
              initial.add(root.id);
              break;
            }
          }
        }
      }
    }
    if (initial.size > 0) {
      setExpandedIDs(initial);
    }
  }, [folders, roots, selectedFolderIDs]);

  const visibleNodes = useMemo(() => {
    const list: FolderHierarchyNode[] = [];
    const walk = (nodes: readonly FolderHierarchyNode[]) => {
      for (const node of nodes) {
        list.push(node);
        if (node.children.length > 0 && expandedIDs.has(node.id)) {
          walk(node.children);
        }
      }
    };
    walk(roots);
    return list;
  }, [roots, expandedIDs]);

  const toggleExpand = (id: UUID) => {
    setExpandedIDs((prev) => {
      const next = new Set(prev);
      if (next.has(id)) next.delete(id);
      else next.add(id);
      return next;
    });
  };

  const toggleSelect = (id: UUID) => {
    const next = new Set(selectedFolderIDs);
    if (next.has(id)) next.delete(id);
    else next.add(id);
    onChange(next);
  };

  const allSelected = selectedFolderIDs.size === 0;

  return (
    <div
      className={`p-1.5 rounded-[var(--radius-settings-inner)] bg-[var(--bg-elevated)] border border-[var(--border-hairline)] flex flex-col gap-0.5 select-none ${className}`}
    >
      {/* Root "All Assets" option */}
      <button
        type="button"
        onClick={() => onChange(new Set())}
        className={[
          'charkle-pressable w-full flex items-center gap-2 px-2 py-1.5 rounded-[6px] text-[12px] text-left cursor-pointer',
          allSelected
            ? 'bg-[var(--accent-soft)] text-[var(--accent)] font-semibold'
            : 'text-[var(--text-primary)] hover:bg-[var(--bg-subtle)]/75',
        ].join(' ')}
      >
        <CharkleIcon name="library" style="duotone" size={14} isActive={allSelected} />
        <span className="flex-1 truncate">全部素材（全库检索）</span>
        {allSelected && <Check size={12} strokeWidth={2.5} className="shrink-0" />}
      </button>

      {visibleNodes.length > 0 && (
        <>
          <div className="my-1 border-t border-[var(--border-hairline)]" />
          <div className="max-h-[188px] overflow-y-auto charkle-scroll flex flex-col gap-0.5">
            {visibleNodes.map((node) => {
              const folder = node.folder;
              const hasChildren = node.children.length > 0;
              const isExpanded = expandedIDs.has(folder.id);
              const isSelected = selectedFolderIDs.has(folder.id);

              return (
                <div
                  key={folder.id}
                  style={{ paddingLeft: node.depth * 16 }}
                  className="flex items-center gap-0.5"
                >
                  {hasChildren ? (
                    <button
                      type="button"
                      aria-label={isExpanded ? '收起子文件夹' : '展开子文件夹'}
                      aria-expanded={isExpanded}
                      onClick={() => toggleExpand(folder.id)}
                      className="w-[22px] h-[26px] inline-flex items-center justify-center rounded-[5px] text-[var(--text-tertiary)] hover:text-[var(--text-primary)] hover:bg-[var(--bg-subtle)] shrink-0 cursor-pointer"
                    >
                      <ChevronRight
                        size={11}
                        className={[
                          'transition-transform duration-[var(--duration-sm)] ease-[var(--ease-out-strong)]',
                          isExpanded ? 'rotate-90' : 'rotate-0',
                        ].join(' ')}
                      />
                    </button>
                  ) : (
                    <span className="w-[22px] shrink-0" aria-hidden="true" />
                  )}

                  <button
                    type="button"
                    onClick={() => toggleSelect(folder.id)}
                    className={[
                      'charkle-pressable flex-1 min-w-0 flex items-center gap-1.5 px-2 py-1 rounded-[6px] text-[12px] text-left cursor-pointer',
                      isSelected
                        ? 'bg-[var(--accent-soft)] text-[var(--accent)] font-semibold'
                        : 'text-[var(--text-primary)] hover:bg-[var(--bg-subtle)]/75',
                    ].join(' ')}
                  >
                    <CharkleFolderIcon
                      colorHex={folder.colorHex}
                      customSymbol={folder.customSymbol}
                      size={14}
                      isActive={isSelected}
                    />
                    <span className="flex-1 truncate">{folder.name}</span>
                    {isSelected && <Check size={12} strokeWidth={2.5} className="shrink-0" />}
                  </button>
                </div>
              );
            })}
          </div>
        </>
      )}
    </div>
  );
};
