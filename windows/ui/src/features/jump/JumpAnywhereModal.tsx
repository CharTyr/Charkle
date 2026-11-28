import React, { useEffect, useMemo, useRef, useState } from 'react';
import { createPortal } from 'react-dom';
import {
  ArrowEnter16Regular,
  Board16Filled,
  Board16Regular,
  DismissCircle16Regular,
  Folder16Filled,
  Folder16Regular,
  Image16Filled,
  Image16Regular,
  MailInbox16Filled,
  MailInbox16Regular,
  Screenshot20Filled,
  Screenshot20Regular,
  Search20Regular,
  Settings16Filled,
  Settings16Regular,
  Sparkle16Filled,
  Sparkle16Regular,
  Tag16Filled,
  Tag16Regular,
  WindowHeaderHorizontal20Filled,
  WindowHeaderHorizontal20Regular,
} from '@fluentui/react-icons';
import { getTransport } from '../../api/transport';
import {
  isPlainWebBookmark,
  useCoordinatorStore,
  useLibraryStore,
  useMoodboardStore,
} from '../../stores';
import type { AssetRecord, QuickJumpKind, QuickJumpMatch } from '../../types/domain';

type QuickCommandId =
  | 'newMoodboard'
  | 'smartDedup'
  | 'openInbox'
  | 'toggleShelf'
  | 'captureArea'
  | 'openSettings';

interface QuickCommandItem {
  id: QuickCommandId;
  title: string;
  shortcut?: string;
  keywords?: string[];
}

const QUICK_COMMANDS: QuickCommandItem[] = [
  { id: 'newMoodboard', title: '快速生成情绪板…', keywords: ['情绪板', 'moodboard', '生成'] },
  {
    id: 'smartDedup',
    title: '智能去重',
    shortcut: 'Ctrl+Shift+D',
    keywords: ['去重', '重复', 'dedup', 'duplicate', '智能去重'],
  },
  { id: 'openInbox', title: '前往收件箱清理台', keywords: ['收件箱', 'inbox'] },
  { id: 'toggleShelf', title: '展开 / 收起顶部悬浮窗', shortcut: 'Alt+Shift+S', keywords: ['悬浮窗', 'shelf'] },
  { id: 'captureArea', title: '交互式区域截图', shortcut: 'Alt+Shift+A', keywords: ['截图', 'capture'] },
  { id: 'openSettings', title: '打开设置', shortcut: 'Ctrl+,', keywords: ['设置', 'settings'] },
];

type SelectableRow =
  | { kind: 'command'; command: QuickCommandItem }
  | { kind: 'match'; match: QuickJumpMatch };

const KIND_LABEL: Record<QuickJumpKind, string> = {
  folder: '文件夹',
  moodboard: '情绪板',
  tag: '标签',
  asset: '素材',
};

const KindIcon: React.FC<{ kind: QuickJumpKind; active: boolean }> = ({ kind, active }) => {
  const cls = active ? 'w-4 h-4 text-[var(--accent)] shrink-0' : 'w-4 h-4 text-[var(--text-secondary)] shrink-0';
  switch (kind) {
    case 'folder':
      return active ? <Folder16Filled className={cls} /> : <Folder16Regular className={cls} />;
    case 'moodboard':
      return active ? <Board16Filled className={cls} /> : <Board16Regular className={cls} />;
    case 'tag':
      return active ? <Tag16Filled className={cls} /> : <Tag16Regular className={cls} />;
    case 'asset':
      return active ? <Image16Filled className={cls} /> : <Image16Regular className={cls} />;
  }
};

const CommandIcon: React.FC<{ id: QuickCommandId; active: boolean }> = ({ id, active }) => {
  const cls = active ? 'w-4 h-4 text-[var(--accent)] shrink-0' : 'w-4 h-4 text-[var(--text-secondary)] shrink-0';
  switch (id) {
    case 'newMoodboard':
      return active ? <Sparkle16Filled className={cls} /> : <Sparkle16Regular className={cls} />;
    case 'smartDedup':
      return active ? <Sparkle16Filled className={cls} /> : <Sparkle16Regular className={cls} />;
    case 'openInbox':
      return active ? <MailInbox16Filled className={cls} /> : <MailInbox16Regular className={cls} />;
    case 'toggleShelf':
      return active ? (
        <WindowHeaderHorizontal20Filled className={cls} />
      ) : (
        <WindowHeaderHorizontal20Regular className={cls} />
      );
    case 'captureArea':
      return active ? <Screenshot20Filled className={cls} /> : <Screenshot20Regular className={cls} />;
    case 'openSettings':
      return active ? <Settings16Filled className={cls} /> : <Settings16Regular className={cls} />;
  }
};

/**
 * Strictly 0ms instant Jump Anywhere command palette (Ctrl+J / Ctrl+K).
 * Renders above Quick Look (`z-[210]`) with Fluent 2 `.win-acrylic` surface and zero entrance/exit delay.
 */
export const JumpAnywhereModal: React.FC = () => {
  const open = useCoordinatorStore((s) => s.jumpOpen);
  const setOpen = useCoordinatorStore((s) => s.setJumpOpen);
  const setDestination = useCoordinatorStore((s) => s.setDestination);
  const setSelection = useCoordinatorStore((s) => s.setSelection);
  const openQuickLook = useCoordinatorStore((s) => s.openQuickLook);
  const closeQuickLook = useCoordinatorStore((s) => s.closeQuickLook);
  const requestGalleryReveal = useCoordinatorStore((s) => s.requestGalleryReveal);
  const openMoodboardGenerator = useCoordinatorStore((s) => s.openMoodboardGenerator);
  const openDeduplication = useCoordinatorStore((s) => s.openDeduplication);
  const openSettings = useCoordinatorStore((s) => s.openSettings);
  const pushToast = useCoordinatorStore((s) => s.pushToast);

  const refreshAll = useLibraryStore((s) => s.refreshAll);
  const recordTouchedTags = useLibraryStore((s) => s.recordTouchedTags);
  const openBoard = useMoodboardStore((s) => s.openBoard);

  const [query, setQuery] = useState('');
  const [matches, setMatches] = useState<QuickJumpMatch[]>([]);
  const [activeIndex, setActiveIndex] = useState(0);

  const inputRef = useRef<HTMLInputElement | null>(null);
  const rowRefs = useRef<Array<HTMLButtonElement | null>>([]);

  useEffect(() => {
    if (!open) {
      setQuery('');
      setMatches([]);
      setActiveIndex(0);
      return;
    }
    const raf = window.requestAnimationFrame(() => {
      inputRef.current?.focus();
    });
    return () => window.cancelAnimationFrame(raf);
  }, [open]);

  useEffect(() => {
    if (!open) return;
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

  const trimmedQuery = query.trim();

  const selectableRows = useMemo<SelectableRow[]>(() => {
    if (!trimmedQuery) {
      return [
        ...QUICK_COMMANDS.map((command): SelectableRow => ({ kind: 'command', command })),
        ...matches.slice(0, 8).map((match): SelectableRow => ({ kind: 'match', match })),
      ];
    }
    const lower = trimmedQuery.toLowerCase();
    const matchedCommands = QUICK_COMMANDS.filter(
      (c) =>
        c.title.toLowerCase().includes(lower) ||
        c.keywords?.some((kw) => kw.toLowerCase().includes(lower)),
    );
    return [
      ...matchedCommands.map((command): SelectableRow => ({ kind: 'command', command })),
      ...matches.map((match): SelectableRow => ({ kind: 'match', match })),
    ];
  }, [trimmedQuery, matches]);

  useEffect(() => {
    rowRefs.current.length = selectableRows.length;
    if (activeIndex >= selectableRows.length) {
      setActiveIndex(0);
    }
  }, [activeIndex, selectableRows.length]);

  useEffect(() => {
    if (!open) return;
    rowRefs.current[activeIndex]?.scrollIntoView?.({ block: 'nearest' });
  }, [open, activeIndex]);

  // Capture Escape above Quick Look so Esc closes only Jump Anywhere (respecting IME popup)
  useEffect(() => {
    if (!open) return;
    const handleKey = (e: KeyboardEvent) => {
      if (e.isComposing || e.keyCode === 229) return;
      if (e.key === 'Escape') {
        e.preventDefault();
        e.stopPropagation();
        e.stopImmediatePropagation();
        setOpen(false);
      }
    };
    window.addEventListener('keydown', handleKey, true);
    return () => window.removeEventListener('keydown', handleKey, true);
  }, [open, setOpen]);

  const executeCommand = (cmd: QuickCommandId) => {
    setOpen(false);
    closeQuickLook();
    if (cmd === 'newMoodboard') {
      openMoodboardGenerator('prompt');
    } else if (cmd === 'smartDedup') {
      openDeduplication();
    } else if (cmd === 'openInbox') {
      setDestination({ type: 'inbox' });
    } else if (cmd === 'toggleShelf') {
      void getTransport()
        .toggleShelf()
        .catch(() => {
          pushToast({ message: '无法切换顶部悬浮窗', tone: 'error' });
        });
    } else if (cmd === 'captureArea') {
      void getTransport()
        .startRegionCapture()
        .catch(() => {
          pushToast({ message: '无法启动区域截图', tone: 'error' });
        });
    } else if (cmd === 'openSettings') {
      openSettings();
    }
  };

  const executeMatch = (match: QuickJumpMatch) => {
    setOpen(false);
    if (match.kind === 'folder' && match.targetUUID) {
      closeQuickLook();
      setDestination({ type: 'folder', id: match.targetUUID });
    } else if (match.kind === 'moodboard' && match.targetUUID) {
      closeQuickLook();
      setDestination({ type: 'moodboard', id: match.targetUUID });
      void openBoard(match.targetUUID);
    } else if (match.kind === 'tag' && match.tagName) {
      closeQuickLook();
      recordTouchedTags([match.tagName]);
      setDestination({ type: 'tag', name: match.tagName });
    } else if (match.kind === 'asset' && match.targetUUID) {
      const assetId = match.targetUUID;
      const lib = useLibraryStore.getState();
      setDestination({ type: 'allItems' }, { preserveSelection: true });
      setSelection([assetId], assetId);
      requestGalleryReveal({ assetId });
      void refreshAll({ type: 'allItems' });

      const cached =
        lib.allAssets.find((a) => a.id === assetId) ??
        lib.assets.find((a) => a.id === assetId) ??
        null;

      const openResolved = (resolved: AssetRecord | null) => {
        if (isPlainWebBookmark(resolved) && resolved?.sourceURL) {
          closeQuickLook();
          let domain = resolved.sourceDomain?.trim().replace(/^www\./i, '') || '';
          if (!domain) {
            try {
              domain = new URL(resolved.sourceURL).host.toLowerCase().replace(/^www\./, '');
            } catch {
              domain = '网页';
            }
          }
          void getTransport()
            .openExternalUrl(resolved.sourceURL)
            .then(() => {
              pushToast({
                message: `已在默认浏览器中打开 ${domain}`,
                tone: 'info',
              });
            })
            .catch(() => {
              pushToast({ message: '无法在默认浏览器中打开链接', tone: 'error' });
            });
          void useLibraryStore.getState().markAssetOpened(resolved.id);
        } else {
          openQuickLook(assetId, null);
        }
      };

      if (cached) {
        openResolved(cached);
      } else {
        void getTransport()
          .fetchAsset(assetId)
          .then((fetched) => openResolved(fetched))
          .catch(() => openQuickLook(assetId, null));
      }
    }
  };

  const executeRow = (row: SelectableRow | undefined) => {
    if (!row) return;
    if (row.kind === 'command') {
      executeCommand(row.command.id);
    } else {
      executeMatch(row.match);
    }
  };

  if (!open || typeof document === 'undefined') return null;

  const commandCount = !trimmedQuery ? QUICK_COMMANDS.length : 0;

  return createPortal(
    <div
      className="fixed inset-0 z-[210] flex items-start justify-center pt-[88px] px-4"
      role="dialog"
      aria-modal="true"
      aria-label="快速跳转"
      onMouseDown={(e) => e.stopPropagation()}
      onPointerDown={(e) => e.stopPropagation()}
      onClick={(e) => e.stopPropagation()}
      onDoubleClick={(e) => e.stopPropagation()}
      onContextMenu={(e) => e.stopPropagation()}
    >
      {/* 0ms instant smoke scrim */}
      <div
        className="win-smoke-scrim fixed inset-0"
        onClick={() => setOpen(false)}
      />

      <div
        data-testid="jump-anywhere-modal"
        className="relative z-10 w-full max-w-[580px] rounded-[var(--win-radius-dialog)] win-acrylic border border-[var(--win-stroke-flyout)] shadow-[var(--shadow-modal)] overflow-hidden flex flex-col"
      >
        {/* Search Header */}
        <div className="flex items-center gap-2.5 px-4 h-[52px] border-b border-[var(--win-stroke-divider)] shrink-0">
          <Search20Regular className="w-[18px] h-[18px] text-[var(--text-secondary)] shrink-0" />
          <input
            ref={inputRef}
            type="text"
            value={query}
            autoFocus
            onChange={(e) => setQuery(e.target.value)}
            onKeyDown={(e) => {
              if (e.nativeEvent.isComposing || e.keyCode === 229) return;
              if (e.key === 'ArrowDown') {
                e.preventDefault();
                setActiveIndex((idx) =>
                  selectableRows.length ? (idx + 1) % selectableRows.length : 0,
                );
              } else if (e.key === 'ArrowUp') {
                e.preventDefault();
                setActiveIndex((idx) =>
                  selectableRows.length
                    ? (idx - 1 + selectableRows.length) % selectableRows.length
                    : 0,
                );
              } else if (e.key === 'Enter') {
                e.preventDefault();
                executeRow(selectableRows[activeIndex]);
              }
            }}
            placeholder="快速跳转情绪板、文件夹、标签或素材（支持拼音）…"
            aria-label="快速跳转搜索框"
            className="flex-1 bg-transparent text-[14.5px] font-medium text-[var(--text-primary)] placeholder:text-[var(--text-tertiary)] outline-none"
          />
          {query && (
            <button
              type="button"
              onClick={() => {
                setQuery('');
                inputRef.current?.focus();
              }}
              aria-label="清空搜索"
              className="text-[var(--text-tertiary)] hover:text-[var(--text-primary)] cursor-pointer inline-flex items-center justify-center"
            >
              <DismissCircle16Regular className="w-4 h-4" />
            </button>
          )}
          <kbd className="win-control-elevation text-[10.5px] font-medium charkle-mono px-1.5 py-0.5 rounded-[var(--win-radius-control)] bg-[var(--win-control-fill)] text-[var(--text-secondary)] shrink-0">
            ESC
          </kbd>
        </div>

        {/* Results (strictly 0ms instant selection highlight) */}
        <div className="max-h-[360px] overflow-y-auto charkle-scroll py-1.5 px-1.5 flex flex-col gap-0.5">
          {!trimmedQuery ? (
            <>
              <div className="px-3 pt-1.5 pb-1 text-[11px] font-semibold text-[var(--text-tertiary)]">
                快捷操作
              </div>
              {QUICK_COMMANDS.map((cmd, idx) => {
                const active = idx === activeIndex;
                return (
                  <button
                    key={cmd.id}
                    ref={(el) => {
                      rowRefs.current[idx] = el;
                    }}
                    type="button"
                    onMouseEnter={() => setActiveIndex(idx)}
                    onClick={() => executeCommand(cmd.id)}
                    className={[
                      'relative w-full flex items-center gap-2.5 px-3 py-2 rounded-[var(--win-radius-control)] text-left cursor-pointer',
                      active
                        ? 'bg-[var(--win-subtle-active)] text-[var(--text-primary)] font-medium'
                        : 'text-[var(--text-primary)] hover:bg-[var(--win-subtle-hover)]',
                    ].join(' ')}
                  >
                    {active && (
                      <span
                        aria-hidden="true"
                        className="pointer-events-none absolute left-0 inset-y-0 my-auto w-[3px] h-4 rounded-full bg-[var(--accent)]"
                      />
                    )}
                    <CommandIcon id={cmd.id} active={active} />
                    <span className="flex-1 text-[13px] leading-[18px] truncate">{cmd.title}</span>
                    {cmd.shortcut && (
                      <kbd className="win-control-elevation text-[10.5px] font-medium charkle-mono px-1.5 py-0.5 rounded-[var(--win-radius-control)] bg-[var(--win-control-fill)] text-[var(--text-secondary)] shrink-0">
                        {cmd.shortcut}
                      </kbd>
                    )}
                    <ArrowEnter16Regular
                      className={`w-3.5 h-3.5 shrink-0 ${active ? 'text-[var(--accent)] opacity-90' : 'text-[var(--text-tertiary)] opacity-40'}`}
                    />
                  </button>
                );
              })}

              {matches.length > 0 && (
                <>
                  <div className="px-3 pt-2.5 pb-1 text-[11px] font-semibold text-[var(--text-tertiary)]">
                    快速跳转
                  </div>
                  {matches.slice(0, 8).map((match, mIdx) => {
                    const idx = commandCount + mIdx;
                    const active = idx === activeIndex;
                    return (
                      <button
                        key={match.id}
                        ref={(el) => {
                          rowRefs.current[idx] = el;
                        }}
                        type="button"
                        onMouseEnter={() => setActiveIndex(idx)}
                        onClick={() => executeMatch(match)}
                        className={[
                          'relative w-full flex items-center gap-2.5 px-3 py-2 rounded-[var(--win-radius-control)] text-left cursor-pointer',
                          active
                            ? 'bg-[var(--win-subtle-active)] text-[var(--text-primary)] font-medium'
                            : 'text-[var(--text-primary)] hover:bg-[var(--win-subtle-hover)]',
                        ].join(' ')}
                      >
                        {active && (
                          <span
                            aria-hidden="true"
                            className="pointer-events-none absolute left-0 inset-y-0 my-auto w-[3px] h-4 rounded-full bg-[var(--accent)]"
                          />
                        )}
                        <KindIcon kind={match.kind} active={active} />
                        <div className="flex-1 min-w-0">
                          <div className="text-[13px] leading-[18px] truncate">{match.title}</div>
                          {match.subtitle && (
                            <div className="text-[11.5px] text-[var(--text-secondary)] truncate">
                              {match.subtitle}
                            </div>
                          )}
                        </div>
                        <span className="text-[11px] font-medium px-2 py-0.5 rounded-[var(--win-radius-control)] bg-[var(--win-control-fill)] border border-[var(--win-stroke-control)] text-[var(--text-secondary)] shrink-0">
                          {KIND_LABEL[match.kind]}
                        </span>
                      </button>
                    );
                  })}
                </>
              )}
            </>
          ) : selectableRows.length === 0 ? (
            <div className="py-8 text-center flex flex-col items-center gap-1.5">
              <div className="text-[13px] font-medium text-[var(--text-secondary)]">
                未找到与「{query}」匹配的内容
              </div>
              <div className="text-[12px] text-[var(--text-tertiary)]">
                试试搜索文件夹名、情绪板标题、标签或拼音首字母
              </div>
            </div>
          ) : (
            selectableRows.map((row, idx) => {
              const active = idx === activeIndex;
              if (row.kind === 'command') {
                const cmd = row.command;
                return (
                  <button
                    key={`cmd:${cmd.id}`}
                    ref={(el) => {
                      rowRefs.current[idx] = el;
                    }}
                    type="button"
                    onMouseEnter={() => setActiveIndex(idx)}
                    onClick={() => executeCommand(cmd.id)}
                    className={[
                      'relative w-full flex items-center gap-2.5 px-3 py-2 rounded-[var(--win-radius-control)] text-left cursor-pointer',
                      active
                        ? 'bg-[var(--win-subtle-active)] text-[var(--text-primary)] font-medium'
                        : 'text-[var(--text-primary)] hover:bg-[var(--win-subtle-hover)]',
                    ].join(' ')}
                  >
                    {active && (
                      <span
                        aria-hidden="true"
                        className="pointer-events-none absolute left-0 inset-y-0 my-auto w-[3px] h-4 rounded-full bg-[var(--accent)]"
                      />
                    )}
                    <CommandIcon id={cmd.id} active={active} />
                    <span className="flex-1 text-[13px] leading-[18px] truncate">{cmd.title}</span>
                    {cmd.shortcut && (
                      <kbd className="win-control-elevation text-[10.5px] font-medium charkle-mono px-1.5 py-0.5 rounded-[var(--win-radius-control)] bg-[var(--win-control-fill)] text-[var(--text-secondary)] shrink-0">
                        {cmd.shortcut}
                      </kbd>
                    )}
                    <span className="text-[11px] font-medium px-2 py-0.5 rounded-[var(--win-radius-control)] bg-[var(--win-control-fill)] border border-[var(--win-stroke-control)] text-[var(--text-secondary)] shrink-0">
                      命令
                    </span>
                    {active && (
                      <ArrowEnter16Regular className="w-3.5 h-3.5 shrink-0 text-[var(--accent)] opacity-90" />
                    )}
                  </button>
                );
              }
              const match = row.match;
              return (
                <button
                  key={match.id}
                  ref={(el) => {
                    rowRefs.current[idx] = el;
                  }}
                  type="button"
                  onMouseEnter={() => setActiveIndex(idx)}
                  onClick={() => executeMatch(match)}
                  className={[
                    'relative w-full flex items-center gap-2.5 px-3 py-2 rounded-[var(--win-radius-control)] text-left cursor-pointer',
                    active
                      ? 'bg-[var(--win-subtle-active)] text-[var(--text-primary)] font-medium'
                      : 'text-[var(--text-primary)] hover:bg-[var(--win-subtle-hover)]',
                  ].join(' ')}
                >
                  {active && (
                    <span
                      aria-hidden="true"
                      className="pointer-events-none absolute left-0 inset-y-0 my-auto w-[3px] h-4 rounded-full bg-[var(--accent)]"
                    />
                  )}
                  <KindIcon kind={match.kind} active={active} />
                  <div className="flex-1 min-w-0">
                    <div className="text-[13px] leading-[18px] truncate">{match.title}</div>
                    {match.subtitle && (
                      <div className="text-[11.5px] text-[var(--text-secondary)] truncate">
                        {match.subtitle}
                      </div>
                    )}
                  </div>
                  <span className="text-[11px] font-medium px-2 py-0.5 rounded-[var(--win-radius-control)] bg-[var(--win-control-fill)] border border-[var(--win-stroke-control)] text-[var(--text-secondary)] shrink-0">
                    {KIND_LABEL[match.kind]}
                  </span>
                  {active && (
                    <ArrowEnter16Regular className="w-3.5 h-3.5 shrink-0 text-[var(--accent)] opacity-90" />
                  )}
                </button>
              );
            })
          )}
        </div>
      </div>
    </div>,
    document.body,
  );
};
