import React, { useRef, useState } from 'react';
import { Pencil, Plus, Trash2 } from 'lucide-react';
import { CharkleIcon, Popconfirm } from '../../design-system';
import {
  useCoordinatorStore,
  useLibraryStore,
  useMoodboardStore,
} from '../../stores';
import type { SidebarDestination, SmartFolderRecord } from '../../types/domain';
import { FolderTree } from './FolderTree';
import { SmartFolderEditorModal } from './SmartFolderEditorModal';

function isDestEqual(a: SidebarDestination, b: SidebarDestination): boolean {
  if (a.type !== b.type) return false;
  if ('id' in a && 'id' in b) return a.id === b.id;
  if ('name' in a && 'name' in b) return a.name === b.name;
  return true;
}

const NavRow: React.FC<{
  iconName: string;
  label: string;
  active: boolean;
  badge?: number | string | null;
  highlightBadge?: boolean;
  onClick: () => void;
}> = ({ iconName, label, active, badge, highlightBadge = false, onClick }) => (
  <button
    type="button"
    onClick={onClick}
    className={[
      'charkle-pressable w-full flex items-center gap-2.5 px-2.5 h-[31px] rounded-[var(--radius-chip)] text-[12.5px] cursor-pointer text-left',
      active
        ? 'bg-[var(--accent-soft)] text-[var(--accent)] font-medium'
        : 'text-[var(--text-primary)] hover:bg-[var(--bg-subtle)]/80',
    ].join(' ')}
  >
    <CharkleIcon name={iconName} style="duotone" size={16} isActive={active} />
    <span className="truncate flex-1 min-w-0">{label}</span>
    {badge != null && badge !== 0 && (
      <span
        className={[
          'text-[11px] px-1.5 py-0.5 rounded-full leading-none charkle-tabular',
          highlightBadge
            ? 'bg-[var(--accent)] text-white font-semibold'
            : 'text-[var(--text-tertiary)]',
        ].join(' ')}
      >
        {badge}
      </span>
    )}
  </button>
);

export const SidebarView: React.FC = () => {
  const destination = useCoordinatorStore((s) => s.destination);
  const setDestination = useCoordinatorStore((s) => s.setDestination);

  const folders = useLibraryStore((s) => s.folders);
  const smartFolders = useLibraryStore((s) => s.smartFolders);
  const tagCounts = useLibraryStore((s) => s.tagCounts);
  const inboxCount = useLibraryStore((s) => s.inboxCount);
  const createFolder = useLibraryStore((s) => s.createFolder);
  const renameFolder = useLibraryStore((s) => s.renameFolder);
  const moveFolder = useLibraryStore((s) => s.moveFolder);
  const updateFolderAppearance = useLibraryStore((s) => s.updateFolderAppearance);
  const deleteFolder = useLibraryStore((s) => s.deleteFolder);
  const saveSmartFolder = useLibraryStore((s) => s.saveSmartFolder);
  const deleteSmartFolder = useLibraryStore((s) => s.deleteSmartFolder);
  const updateAssets = useLibraryStore((s) => s.updateAssets);

  const boards = useMoodboardStore((s) => s.boards);

  const [creatingRootFolder, setCreatingRootFolder] = useState(false);
  const [rootFolderName, setRootFolderName] = useState('');
  const [smartModalOpen, setSmartModalOpen] = useState(false);
  const [editingSmartFolder, setEditingSmartFolder] = useState<SmartFolderRecord | null>(null);
  const [deletingSmartId, setDeletingSmartId] = useState<string | null>(null);
  const smartDeleteAnchorRef = useRef<HTMLButtonElement | null>(null);

  const commitRootFolder = async () => {
    const trimmed = rootFolderName.trim();
    setCreatingRootFolder(false);
    setRootFolderName('');
    if (trimmed) {
      await createFolder(trimmed, null);
    }
  };

  return (
    <aside
      aria-label="主导航侧边栏"
      className="charkle-sidebar-surface w-[232px] shrink-0 h-full flex flex-col border-r border-[var(--border-hairline)] select-none"
    >
      <div className="flex-1 min-h-0 overflow-y-auto charkle-scroll px-2 py-2.5 flex flex-col gap-4">
        {/* Core library destinations */}
        <nav className="flex flex-col gap-0.5">
          <NavRow
            iconName="library"
            label="全部素材"
            active={isDestEqual(destination, { type: 'allItems' })}
            onClick={() => setDestination({ type: 'allItems' })}
          />
          <NavRow
            iconName="inbox"
            label="收件箱"
            badge={inboxCount}
            highlightBadge={inboxCount > 0}
            active={isDestEqual(destination, { type: 'inbox' })}
            onClick={() => setDestination({ type: 'inbox' })}
          />
          <NavRow
            iconName="moodboard"
            label="情绪板"
            badge={boards.length || null}
            active={destination.type === 'moodboardsHome' || destination.type === 'moodboard'}
            onClick={() => setDestination({ type: 'moodboardsHome' })}
          />
          <NavRow
            iconName="untagged"
            label="未打标签"
            active={isDestEqual(destination, { type: 'untagged' })}
            onClick={() => setDestination({ type: 'untagged' })}
          />
          <NavRow
            iconName="recent"
            label="最近浏览"
            active={isDestEqual(destination, { type: 'recent' })}
            onClick={() => setDestination({ type: 'recent' })}
          />
          <NavRow
            iconName="trash"
            label="回收站"
            active={isDestEqual(destination, { type: 'trash' })}
            onClick={() => setDestination({ type: 'trash' })}
          />
        </nav>

        {/* Nested Folders */}
        <section className="flex flex-col gap-1">
          <div className="flex items-center justify-between px-2">
            <span className="text-[11px] font-semibold tracking-[0.02em] text-[var(--text-tertiary)]">
              文件夹
            </span>
            <button
              type="button"
              aria-label="新建文件夹"
              title="新建文件夹"
              onClick={() => setCreatingRootFolder(true)}
              className="charkle-pressable h-5 w-5 inline-flex items-center justify-center rounded text-[var(--text-tertiary)] hover:text-[var(--text-primary)] hover:bg-[var(--bg-subtle)] cursor-pointer"
            >
              <Plus size={13} />
            </button>
          </div>

          {creatingRootFolder && (
            <div className="px-1.5 py-0.5">
              <input
                type="text"
                value={rootFolderName}
                autoFocus
                placeholder="输入文件夹名称…"
                onChange={(e) => setRootFolderName(e.target.value)}
                onBlur={() => void commitRootFolder()}
                onKeyDown={(e) => {
                  if (e.key === 'Enter') void commitRootFolder();
                  if (e.key === 'Escape') {
                    setCreatingRootFolder(false);
                    setRootFolderName('');
                  }
                }}
                className="w-full h-7 px-2 rounded-[var(--radius-card-inner)] bg-[var(--bg-elevated)] border border-[var(--accent)] text-[12.5px] text-[var(--text-primary)] outline-none"
              />
            </div>
          )}

          <FolderTree
            folders={folders}
            activeFolderId={destination.type === 'folder' ? destination.id : null}
            onSelectFolder={(id) => setDestination({ type: 'folder', id })}
            onCreateSubfolder={async (parentId, name) => {
              await createFolder(name, parentId);
            }}
            onRenameFolder={async (id, name) => {
              await renameFolder(id, name);
            }}
            onMoveFolder={async (id, newParentId, idx) => {
              await moveFolder(id, newParentId, idx);
            }}
            onUpdateAppearance={async (id, hex, sym) => {
              await updateFolderAppearance(id, hex, sym);
            }}
            onDeleteFolder={async (id, trashContents) => {
              await deleteFolder(id, trashContents, destination);
            }}
            onDropAssets={async (folderId, assetIds) => {
              await updateAssets(
                { assetIDs: assetIds, folderAssignment: { folder: folderId } },
                destination,
                {
                  undoMessage: `已将 ${assetIds.length} 项移入文件夹`,
                  undoPatch: { assetIDs: assetIds, folderAssignment: 'inbox' },
                },
              );
            }}
          />
        </section>

        {/* Smart Folders */}
        <section className="flex flex-col gap-1">
          <div className="flex items-center justify-between px-2">
            <span className="text-[11px] font-semibold tracking-[0.02em] text-[var(--text-tertiary)]">
              智能文件夹
            </span>
            <button
              type="button"
              aria-label="新建智能文件夹"
              title="新建智能文件夹"
              onClick={() => {
                setEditingSmartFolder(null);
                setSmartModalOpen(true);
              }}
              className="charkle-pressable h-5 w-5 inline-flex items-center justify-center rounded text-[var(--text-tertiary)] hover:text-[var(--text-primary)] hover:bg-[var(--bg-subtle)] cursor-pointer"
            >
              <Plus size={13} />
            </button>
          </div>

          <div className="flex flex-col gap-0.5">
            {smartFolders.length === 0 ? (
              <div className="px-2.5 py-1 text-[11.5px] text-[var(--text-tertiary)]">
                尚无智能规则
              </div>
            ) : (
              smartFolders.map((sf) => {
                const active = destination.type === 'smartFolder' && destination.id === sf.id;
                return (
                  <div
                    key={sf.id}
                    onClick={() => setDestination({ type: 'smartFolder', id: sf.id })}
                    className={[
                      'group flex items-center gap-2 px-2.5 h-[30px] rounded-[var(--radius-chip)] text-[12.5px] cursor-pointer',
                      active
                        ? 'bg-[var(--accent-soft)] text-[var(--accent)] font-medium'
                        : 'text-[var(--text-primary)] hover:bg-[var(--bg-subtle)]/80',
                    ].join(' ')}
                  >
                    <CharkleIcon
                      name="smart-folder"
                      style="duotone"
                      size={15}
                      isActive={active}
                      tintHex={sf.colorHex}
                    />
                    <span className="truncate flex-1 min-w-0">{sf.name}</span>
                    <div className="hidden group-hover:flex items-center gap-0.5">
                      <button
                        type="button"
                        aria-label={`编辑智能文件夹 ${sf.name}`}
                        onClick={(e) => {
                          e.stopPropagation();
                          setEditingSmartFolder(sf);
                          setSmartModalOpen(true);
                        }}
                        className="h-5 w-5 inline-flex items-center justify-center rounded text-[var(--text-secondary)] hover:bg-[var(--bg-elevated)] cursor-pointer"
                      >
                        <Pencil size={11.5} />
                      </button>
                      <button
                        type="button"
                        aria-label={`删除智能文件夹 ${sf.name}`}
                        onClick={(e) => {
                          e.stopPropagation();
                          smartDeleteAnchorRef.current = e.currentTarget;
                          setDeletingSmartId(sf.id);
                        }}
                        className="h-5 w-5 inline-flex items-center justify-center rounded text-[var(--danger)] hover:bg-[var(--danger-soft)] cursor-pointer"
                      >
                        <Trash2 size={11.5} />
                      </button>
                    </div>
                  </div>
                );
              })
            )}
          </div>
        </section>

        {/* Tags */}
        <section className="flex flex-col gap-1">
          <div className="px-2 text-[11px] font-semibold tracking-[0.02em] text-[var(--text-tertiary)]">
            标签
          </div>
          {tagCounts.length === 0 ? (
            <div className="px-2.5 py-1 text-[11.5px] text-[var(--text-tertiary)]">暂无标签</div>
          ) : (
            <div className="flex flex-col gap-0.5">
              {tagCounts.slice(0, 24).map((tag) => {
                const active = destination.type === 'tag' && destination.name === tag.name;
                return (
                  <button
                    key={tag.name}
                    type="button"
                    onClick={() => setDestination({ type: 'tag', name: tag.name })}
                    className={[
                      'charkle-pressable w-full flex items-center gap-2 px-2.5 h-[28px] rounded-[var(--radius-chip)] text-[12px] cursor-pointer text-left',
                      active
                        ? 'bg-[var(--accent-soft)] text-[var(--accent)] font-medium'
                        : 'text-[var(--text-primary)] hover:bg-[var(--bg-subtle)]/80',
                    ].join(' ')}
                  >
                    <CharkleIcon name="tag" style="duotone" size={14} isActive={active} />
                    <span className="truncate flex-1 min-w-0">#{tag.name}</span>
                    <span className="text-[11px] text-[var(--text-tertiary)] charkle-tabular">
                      {tag.count}
                    </span>
                  </button>
                );
              })}
            </div>
          )}
        </section>
      </div>

      <SmartFolderEditorModal
        open={smartModalOpen}
        onClose={() => setSmartModalOpen(false)}
        initial={editingSmartFolder}
        availableTags={tagCounts}
        onSave={(folder) => saveSmartFolder(folder, destination)}
      />

      <Popconfirm
        open={deletingSmartId !== null}
        onOpenChange={(open) => {
          if (!open) setDeletingSmartId(null);
        }}
        anchorEl={smartDeleteAnchorRef.current}
        title="删除此智能文件夹？"
        description="仅删除筛选规则，不会影响素材库中的任何文件。"
        confirmLabel="删除规则"
        onConfirm={() => {
          if (deletingSmartId) {
            void deleteSmartFolder(deletingSmartId, destination);
          }
        }}
      />
    </aside>
  );
};
