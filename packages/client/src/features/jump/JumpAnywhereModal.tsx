import React, { useEffect, useMemo, useRef, useState } from 'react';
import {
  Compass,
  CornerDownLeft,
  Folder,
  Hash,
  Image as ImageIcon,
  Inbox,
  LayoutGrid,
  PlusCircle,
  Puzzle,
  Search,
  Settings,
  Sparkles,
} from 'lucide-react';
import { fuzzyScoreSearchText } from '@charkle/shared';
import type { QuickJumpMatch } from '@charkle/shared';
import { apiClient } from '../../api/client';
import { CharkleFolderIcon, CharkleIcon } from '../../design-system';
import { useCoordinatorStore } from '../../stores/coordinatorStore';
import { useLibraryStore } from '../../stores/libraryStore';
import { useMoodboardStore } from '../../stores/moodboardStore';

interface JumpRow {
  id: string;
  kind: 'command' | 'moodboard' | 'folder' | 'tag' | 'asset';
  title: string;
  subtitle: string;
  targetUUID?: string | null;
  tagName?: string | null;
  commandKey?:
    | 'generateBoard'
    | 'gotoInbox'
    | 'openQuickCapture'
    | 'installExtension'
    | 'rerunOnboarding'
    | 'openSettings';
  score: number;
}

const QUICK_COMMANDS: JumpRow[] = [
  {
    id: 'cmd-quick-capture',
    kind: 'command',
    commandKey: 'openQuickCapture',
    title: '打开快速采集',
    subtitle: '上传文件、链接、笔记、色卡或截屏 (⇧⌘N)',
    score: 1.01,
  },
  {
    id: 'cmd-generate-board',
    kind: 'command',
    commandKey: 'generateBoard',
    title: '快速生成情绪板…',
    subtitle: '按提示词、素材或色板生成情绪板',
    score: 1,
  },
  {
    id: 'cmd-goto-inbox',
    kind: 'command',
    commandKey: 'gotoInbox',
    title: '前往收件箱清理台',
    subtitle: '使用数字键 1–9 快速归档素材',
    score: 0.99,
  },
  {
    id: 'cmd-install-extension',
    kind: 'command',
    commandKey: 'installExtension',
    title: '安装浏览器采集扩展',
    subtitle: '下载扩展包并获取访问令牌',
    score: 0.98,
  },
  {
    id: 'cmd-rerun-onboarding',
    kind: 'command',
    commandKey: 'rerunOnboarding',
    title: '重新运行首次使用引导',
    subtitle: '快速配置素材库、浏览器扩展、AI 与外观',
    score: 0.975,
  },
  {
    id: 'cmd-open-settings',
    kind: 'command',
    commandKey: 'openSettings',
    title: '打开设置中心',
    subtitle: '账号、同步、智能与存储设置',
    score: 0.97,
  },
];

export const JumpAnywhereModal: React.FC = () => {
  const open = useCoordinatorStore((s) => s.jumpAnywhereOpen);
  const setOpen = useCoordinatorStore((s) => s.setJumpAnywhereOpen);
  const navigate = useCoordinatorStore((s) => s.navigate);
  const openBoard = useCoordinatorStore((s) => s.openBoard);
  const openQuickLook = useCoordinatorStore((s) => s.openQuickLook);
  const openGeneratorModal = useCoordinatorStore((s) => s.openGeneratorModal);
  const openSettings = useCoordinatorStore((s) => s.openSettings);
  const openQuickCapture = useCoordinatorStore((s) => s.openQuickCapture);
  const presentOnboarding = useCoordinatorStore((s) => s.presentOnboarding);

  const folders = useLibraryStore((s) => s.folders);
  const tags = useLibraryStore((s) => s.tags);
  const assets = useLibraryStore((s) => s.assets);
  const selectAsset = useLibraryStore((s) => s.selectAsset);

  const boards = useMoodboardStore((s) => s.boards);

  const [query, setQuery] = useState('');
  const [selectedIndex, setSelectedIndex] = useState(0);
  const [remoteMatches, setRemoteMatches] = useState<QuickJumpMatch[]>([]);
  const inputRef = useRef<HTMLInputElement | null>(null);

  useEffect(() => {
    if (!open) return;
    setQuery('');
    setSelectedIndex(0);
    setRemoteMatches([]);
    requestAnimationFrame(() => inputRef.current?.focus());
  }, [open]);

  useEffect(() => {
    if (!open) return;
    const trimmed = query.trim();
    if (!trimmed) {
      setRemoteMatches([]);
      return;
    }
    let cancelled = false;
    const timer = window.setTimeout(() => {
      apiClient
        .quickJump(trimmed)
        .then((res) => {
          if (!cancelled) setRemoteMatches(res.matches);
        })
        .catch(() => {
          // Fallback silently to local fuzzy search
        });
    }, 100);
    return () => {
      cancelled = true;
      window.clearTimeout(timer);
    };
  }, [open, query]);

  const rows: JumpRow[] = useMemo(() => {
    const trimmed = query.trim();
    if (!trimmed) return QUICK_COMMANDS;

    const merged = new Map<string, JumpRow>();

    // Local instant fuzzy scoring across boards, folders, tags, and loaded assets
    for (const board of boards) {
      const s = fuzzyScoreSearchText(trimmed, `${board.title} ${board.subtitle}`);
      if (s !== null) {
        merged.set(`moodboard:${board.id}`, {
          id: `moodboard:${board.id}`,
          kind: 'moodboard',
          title: board.title,
          subtitle: `情绪板 · ${board.itemCount} 项`,
          targetUUID: board.id,
          score: s + 0.08,
        });
      }
    }

    for (const folder of folders) {
      const s = fuzzyScoreSearchText(trimmed, folder.name);
      if (s !== null) {
        merged.set(`folder:${folder.id}`, {
          id: `folder:${folder.id}`,
          kind: 'folder',
          title: folder.name,
          subtitle: `文件夹 · ${folder.assetCount} 项素材`,
          targetUUID: folder.id,
          score: s + 0.06,
        });
      }
    }

    for (const tag of tags) {
      const s = fuzzyScoreSearchText(trimmed, tag.name);
      if (s !== null) {
        merged.set(`tag:${tag.name}`, {
          id: `tag:${tag.name}`,
          kind: 'tag',
          title: `#${tag.name}`,
          subtitle: `标签 · ${tag.count} 项素材`,
          tagName: tag.name,
          score: s + 0.04,
        });
      }
    }

    for (const asset of assets.slice(0, 200)) {
      const s = fuzzyScoreSearchText(trimmed, `${asset.title} ${asset.tags.join(' ')}`);
      if (s !== null) {
        merged.set(`asset:${asset.id}`, {
          id: `asset:${asset.id}`,
          kind: 'asset',
          title: asset.title,
          subtitle: asset.fileName,
          targetUUID: asset.id,
          score: s,
        });
      }
    }

    // Merge server quick-jump matches (searches entire DB including FTS5 + Pinyin)
    for (const rm of remoteMatches) {
      const key =
        rm.kind === 'tag'
          ? `tag:${rm.tagName ?? rm.title}`
          : `${rm.kind}:${rm.targetUUID ?? rm.id}`;
      if (!merged.has(key)) {
        merged.set(key, {
          id: key,
          kind: rm.kind,
          title: rm.kind === 'tag' && !rm.title.startsWith('#') ? `#${rm.title}` : rm.title,
          subtitle: rm.subtitle,
          targetUUID: rm.targetUUID,
          tagName: rm.tagName,
          score: rm.score,
        });
      }
    }

    return Array.from(merged.values())
      .sort((a, b) => b.score - a.score)
      .slice(0, 14);
  }, [query, boards, folders, tags, assets, remoteMatches]);

  useEffect(() => {
    setSelectedIndex(0);
  }, [rows.length, query]);

  if (!open) return null;

  const executeRow = (row: JumpRow) => {
    setOpen(false);
    if (row.kind === 'command') {
      if (row.commandKey === 'generateBoard') openGeneratorModal();
      else if (row.commandKey === 'gotoInbox') navigate({ type: 'inbox' });
      else if (row.commandKey === 'openQuickCapture') openQuickCapture();
      else if (row.commandKey === 'installExtension') openSettings('extensions');
      else if (row.commandKey === 'rerunOnboarding') presentOnboarding();
      else if (row.commandKey === 'openSettings') openSettings('general');
      return;
    }
    if (row.kind === 'moodboard' && row.targetUUID) {
      openBoard(row.targetUUID);
    } else if (row.kind === 'folder' && row.targetUUID) {
      navigate({ type: 'folder', id: row.targetUUID });
    } else if (row.kind === 'tag') {
      const name = (row.tagName || row.title).replace(/^#+/, '');
      navigate({ type: 'tag', name });
    } else if (row.kind === 'asset' && row.targetUUID) {
      selectAsset(row.targetUUID, 'replace');
      openQuickLook(row.targetUUID);
    }
  };

  const handleKeyDown = (e: React.KeyboardEvent) => {
    if (e.key === 'Escape') {
      e.preventDefault();
      setOpen(false);
    } else if (e.key === 'ArrowDown') {
      e.preventDefault();
      setSelectedIndex((i) => (rows.length > 0 ? (i + 1) % rows.length : 0));
    } else if (e.key === 'ArrowUp') {
      e.preventDefault();
      setSelectedIndex((i) => (rows.length > 0 ? (i - 1 + rows.length) % rows.length : 0));
    } else if (e.key === 'Enter' && rows[selectedIndex]) {
      e.preventDefault();
      executeRow(rows[selectedIndex]);
    }
  };

  const renderRowIcon = (row: JumpRow) => {
    if (row.kind === 'command') {
      if (row.commandKey === 'openQuickCapture') return <PlusCircle size={16} className="text-[var(--accent)]" />;
      if (row.commandKey === 'generateBoard') return <Sparkles size={16} className="text-[var(--accent)]" />;
      if (row.commandKey === 'gotoInbox') return <Inbox size={16} className="text-[var(--text-secondary)]" />;
      if (row.commandKey === 'installExtension') return <Puzzle size={16} className="text-[var(--text-secondary)]" />;
      if (row.commandKey === 'rerunOnboarding') return <Compass size={16} className="text-[var(--text-secondary)]" />;
      return <Settings size={16} className="text-[var(--text-secondary)]" />;
    }
    if (row.kind === 'moodboard') return <CharkleIcon name="moodboard" size={17} />;
    if (row.kind === 'folder') {
      const folder = folders.find((f) => f.id === row.targetUUID);
      return folder ? (
        <CharkleFolderIcon colorHex={folder.colorHex} customSymbol={folder.customSymbol} size={17} />
      ) : (
        <Folder size={16} className="text-[var(--text-secondary)]" />
      );
    }
    if (row.kind === 'tag') return <Hash size={15} className="text-[var(--accent)]" />;
    if (row.kind === 'asset' && row.targetUUID) {
      return (
        <img
          src={apiClient.thumbnailURL(row.targetUUID, 'grid520')}
          alt=""
          className="h-7 w-7 rounded-[6px] object-cover bg-[var(--bg-subtle)] shrink-0"
        />
      );
    }
    return <ImageIcon size={16} className="text-[var(--text-secondary)]" />;
  };

  // Deliberately zero open animation on 100+/day keyboard palette per Emil Kowalski `animate` rule!
  return (
    <div
      className="fixed inset-0 z-[140] flex items-start justify-center pt-[14vh] px-4 bg-black/32"
      onMouseDown={(e) => {
        if (e.target === e.currentTarget) setOpen(false);
      }}
    >
      <div
        role="dialog"
        aria-label="随处跳转"
        onKeyDown={handleKeyDown}
        className="charkle-glass w-full max-w-[560px] rounded-[var(--radius-dock-outer)] overflow-hidden shadow-[0_24px_64px_rgba(0,0,0,0.28)]"
      >
        <div className="flex items-center gap-2.5 px-4 h-13 border-b border-[var(--border-hairline)]">
          <Search size={17} className="text-[var(--text-tertiary)] shrink-0" />
          <input
            ref={inputRef}
            type="text"
            value={query}
            onChange={(e) => setQuery(e.target.value)}
            placeholder="跳转至文件夹、情绪板、标签或搜索素材（支持中文拼音）…"
            className="flex-1 min-w-0 bg-transparent text-[14.5px] text-[var(--text-primary)] placeholder:text-[var(--text-tertiary)] focus:outline-none"
          />
          <kbd className="text-[11px] font-mono px-1.5 py-0.5 rounded bg-[var(--bg-subtle)] text-[var(--text-tertiary)]">
            ESC
          </kbd>
        </div>

        <div className="max-h-[380px] overflow-y-auto charkle-scroll p-2 flex flex-col gap-0.5">
          {rows.length === 0 ? (
            <div className="py-10 text-center text-[13px] text-[var(--text-secondary)]">
              未找到匹配「{query}」的文件夹、情绪板、标签或素材
            </div>
          ) : (
            rows.map((row, index) => {
              const active = index === selectedIndex;
              return (
                <button
                  key={row.id}
                  type="button"
                  onMouseEnter={() => setSelectedIndex(index)}
                  onClick={() => executeRow(row)}
                  className={[
                    'w-full flex items-center gap-3 px-3 py-2 rounded-[var(--radius-dock-inner)] text-left cursor-pointer',
                    active
                      ? 'bg-[var(--accent-soft)] text-[var(--text-primary)]'
                      : 'text-[var(--text-primary)] hover:bg-[var(--bg-subtle)]/65',
                  ].join(' ')}
                >
                  <span className="w-7 flex items-center justify-center shrink-0">
                    {renderRowIcon(row)}
                  </span>
                  <div className="flex-1 min-w-0">
                    <div className="text-[13.5px] font-medium truncate">{row.title}</div>
                    <div className="text-[11.5px] text-[var(--text-secondary)] truncate">
                      {row.subtitle}
                    </div>
                  </div>
                  {active && (
                    <CornerDownLeft size={14} className="text-[var(--accent)] shrink-0" />
                  )}
                </button>
              );
            })
          )}
        </div>

        <div className="px-4 py-2 border-t border-[var(--border-hairline)] flex items-center justify-between text-[11px] text-[var(--text-tertiary)] bg-[var(--bg-gallery)]/45">
          <span className="inline-flex items-center gap-1.5">
            <LayoutGrid size={12} />
            ↑↓ 选择 · Enter 打开
          </span>
          <span>⌘J 随处跳转</span>
        </div>
      </div>
    </div>
  );
};
