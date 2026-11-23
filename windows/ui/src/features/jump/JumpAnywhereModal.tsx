import React, { useEffect, useState } from 'react';
import { CornerDownLeft, Folder, Hash, Image as ImageIcon, LayoutGrid, Search } from 'lucide-react';
import { getTransport } from '../../api/transport';
import { ModalShell } from '../../design-system';
import { useCoordinatorStore, useLibraryStore } from '../../stores';
import type { QuickJumpKind, QuickJumpMatch } from '../../types/domain';

const KIND_LABEL: Record<QuickJumpKind, string> = {
  folder: '文件夹',
  moodboard: '情绪板',
  tag: '标签',
  asset: '素材',
};

const KindIcon: React.FC<{ kind: QuickJumpKind }> = ({ kind }) => {
  switch (kind) {
    case 'folder':
      return <Folder size={14} className="text-[var(--accent)] shrink-0" />;
    case 'moodboard':
      return <LayoutGrid size={14} className="text-[var(--accent)] shrink-0" />;
    case 'tag':
      return <Hash size={14} className="text-[var(--text-secondary)] shrink-0" />;
    case 'asset':
      return <ImageIcon size={14} className="text-[var(--text-secondary)] shrink-0" />;
  }
};

/**
 * 0ms instant Ctrl+J Jump Anywhere command palette (DESIGN.md §6.1 & M2-R6).
 */
export const JumpAnywhereModal: React.FC = () => {
  const open = useCoordinatorStore((s) => s.jumpOpen);
  const setOpen = useCoordinatorStore((s) => s.setJumpOpen);
  const setDestination = useCoordinatorStore((s) => s.setDestination);
  const setSelection = useCoordinatorStore((s) => s.setSelection);
  const refreshAll = useLibraryStore((s) => s.refreshAll);

  const [query, setQuery] = useState('');
  const [matches, setMatches] = useState<QuickJumpMatch[]>([]);
  const [activeIndex, setActiveIndex] = useState(0);

  useEffect(() => {
    if (!open) {
      setQuery('');
      setActiveIndex(0);
      return;
    }
    let cancelled = false;
    void getTransport()
      .quickJump(query, 24)
      .then((res) => {
        if (!cancelled) {
          setMatches(res);
          setActiveIndex(0);
        }
      })
      .catch(() => {
        if (!cancelled) setMatches([]);
      });
    return () => {
      cancelled = true;
    };
  }, [open, query]);

  const executeMatch = (match: QuickJumpMatch) => {
    setOpen(false);
    if (match.kind === 'folder' && match.targetUUID) {
      setDestination({ type: 'folder', id: match.targetUUID });
    } else if (match.kind === 'moodboard' && match.targetUUID) {
      setDestination({ type: 'moodboard', id: match.targetUUID });
    } else if (match.kind === 'tag' && match.tagName) {
      setDestination({ type: 'tag', name: match.tagName });
    } else if (match.kind === 'asset' && match.targetUUID) {
      setDestination({ type: 'allItems' }, { preserveSelection: true });
      setSelection([match.targetUUID], match.targetUUID);
      void refreshAll({ type: 'allItems' });
    }
  };

  return (
    <ModalShell
      open={open}
      onClose={() => setOpen(false)}
      width="md"
      instant
      hideCloseButton
      noPadding
      className="overflow-hidden"
    >
      <div data-testid="jump-anywhere-modal" className="flex flex-col">
        <div className="flex items-center gap-2.5 px-4 h-12 border-b border-[var(--border-hairline)]">
          <Search size={16} className="text-[var(--text-tertiary)] shrink-0" />
          <input
            type="text"
            value={query}
            autoFocus
            onChange={(e) => setQuery(e.target.value)}
            onKeyDown={(e) => {
              if (e.key === 'ArrowDown') {
                e.preventDefault();
                setActiveIndex((idx) => (matches.length ? (idx + 1) % matches.length : 0));
              } else if (e.key === 'ArrowUp') {
                e.preventDefault();
                setActiveIndex((idx) =>
                  matches.length ? (idx - 1 + matches.length) % matches.length : 0,
                );
              } else if (e.key === 'Enter' && matches[activeIndex]) {
                e.preventDefault();
                executeMatch(matches[activeIndex]);
              }
            }}
            placeholder="快速跳转文件夹、情绪板、标签或素材…"
            aria-label="快速跳转搜索框"
            className="flex-1 bg-transparent text-[14px] text-[var(--text-primary)] placeholder:text-[var(--text-tertiary)] outline-none"
          />
          <kbd className="text-[10.5px] px-1.5 py-0.5 rounded bg-[var(--bg-subtle)] text-[var(--text-tertiary)]">
            Esc
          </kbd>
        </div>

        <div className="max-h-[360px] overflow-y-auto charkle-scroll p-2 flex flex-col gap-0.5">
          {matches.length === 0 ? (
            <div className="py-10 text-center text-[12.5px] text-[var(--text-tertiary)]">
              无匹配项，换个关键词试试
            </div>
          ) : (
            matches.map((match, idx) => {
              const active = idx === activeIndex;
              return (
                <button
                  key={match.id}
                  type="button"
                  onMouseEnter={() => setActiveIndex(idx)}
                  onClick={() => executeMatch(match)}
                  className={[
                    'w-full flex items-center gap-2.5 px-3 py-2 rounded-[var(--radius-popover-inner)] text-left cursor-pointer',
                    active
                      ? 'bg-[var(--accent-soft)] text-[var(--accent)]'
                      : 'text-[var(--text-primary)] hover:bg-[var(--bg-subtle)]',
                  ].join(' ')}
                >
                  <KindIcon kind={match.kind} />
                  <div className="flex-1 min-w-0">
                    <div className="text-[13px] font-medium truncate">{match.title}</div>
                    {match.subtitle && (
                      <div className="text-[11px] text-[var(--text-tertiary)] truncate">
                        {match.subtitle}
                      </div>
                    )}
                  </div>
                  <span className="text-[10.5px] px-1.5 py-0.5 rounded bg-[var(--bg-subtle)] text-[var(--text-tertiary)] shrink-0">
                    {KIND_LABEL[match.kind]}
                  </span>
                  {active && <CornerDownLeft size={13} className="shrink-0 opacity-70" />}
                </button>
              );
            })
          )}
        </div>
      </div>
    </ModalShell>
  );
};
