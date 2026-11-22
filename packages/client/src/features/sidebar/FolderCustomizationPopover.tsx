import React, { useState } from 'react';
import { Ban, LayoutGrid, Smile } from 'lucide-react';
import type { FolderRecord } from '@charkle/shared';
import {
  CharkleFolderIcon,
  MACOS_FOLDER_COLORS,
  SF_SYMBOL_TO_LUCIDE,
} from '../../design-system';

const SYMBOL_GROUPS: ReadonlyArray<{ id: string; title: string; symbols: readonly string[] }> = [
  {
    id: 'design',
    title: '设计与创意',
    symbols: [
      'paintbrush.fill',
      'paintpalette.fill',
      'sparkles',
      'wand.and.stars',
      'swatchpalette.fill',
      'pencil.and.outline',
      'scissors',
      'ruler.fill',
      'square.on.circle',
      'cube.fill',
      'view.3d',
      'scribble.variable',
    ],
  },
  {
    id: 'media',
    title: '影像与媒体',
    symbols: [
      'photo.fill',
      'camera.fill',
      'film.fill',
      'play.rectangle.fill',
      'music.note',
      'waveform',
      'headphones',
      'book.fill',
      'doc.richtext.fill',
      'globe',
      'link',
      'bubble.left.and.bubble.right.fill',
    ],
  },
  {
    id: 'people',
    title: '人物与自然',
    symbols: [
      'person.fill',
      'person.2.fill',
      'face.smiling',
      'eye.fill',
      'hand.raised.fill',
      'heart.fill',
      'star.fill',
      'flame.fill',
      'sun.max.fill',
      'moon.stars.fill',
      'leaf.fill',
      'pawprint.fill',
    ],
  },
  {
    id: 'dev',
    title: '开发与工作',
    symbols: [
      'chevron.left.forwardslash.chevron.right',
      'terminal.fill',
      'cpu.fill',
      'desktopcomputer',
      'iphone',
      'gamecontroller.fill',
      'briefcase.fill',
      'archivebox.fill',
      'tray.full.fill',
      'bolt.fill',
      'flag.fill',
      'bookmark.fill',
    ],
  },
];

const EMOJI_PRESETS: readonly string[] = [
  '🎨', '✨', '🌸', '🌊', '🔥', '⚡️', '🌙', '☀️',
  '🎬', '📷', '🎧', '🎮', '🧩', '📐', '💎', '🚀',
  '💻', '📱', '🧠', '🦊', '🐱', '🌿', '🏔️', '🏙️',
  '⭐️', '❤️', '📌', '🔖', '📦', '🗂️', '🧪', '🛠️',
];

export interface FolderCustomizationPopoverProps {
  folder: FolderRecord;
  onUpdate: (colorHex: string | null, customSymbol: string | null) => void;
}

export const FolderCustomizationPopover: React.FC<FolderCustomizationPopoverProps> = ({
  folder,
  onUpdate,
}) => {
  const [selectedColor, setSelectedColor] = useState<string | null>(folder.colorHex ?? null);
  const [selectedSymbol, setSelectedSymbol] = useState<string | null>(folder.customSymbol ?? null);
  const [showEmojiMode, setShowEmojiMode] = useState<boolean>(
    Boolean(folder.customSymbol?.startsWith('emoji:')),
  );
  const [customEmojiInput, setCustomEmojiInput] = useState('');

  const commit = (color: string | null, symbol: string | null) => {
    setSelectedColor(color);
    setSelectedSymbol(symbol);
    onUpdate(color, symbol);
  };

  const applyCustomEmoji = () => {
    const trimmed = customEmojiInput.trim();
    if (!trimmed) return;
    const first = Array.from(trimmed)[0];
    if (!first) return;
    setCustomEmojiInput('');
    commit(selectedColor, `emoji:${first}`);
  };

  return (
    <div className="w-[292px] flex flex-col select-none">
      {/* Live Large Folder Preview */}
      <div className="flex flex-col items-center gap-1.5 pt-4 pb-3 px-4">
        <CharkleFolderIcon
          colorHex={selectedColor}
          customSymbol={selectedSymbol}
          size={56}
        />
        <span className="text-[12.5px] font-semibold text-[var(--text-primary)] truncate max-w-full">
          {folder.name}
        </span>
      </div>

      {/* 7 macOS Preset Colors + Reset + Custom Color Input */}
      <div className="flex items-center justify-center gap-1.5 px-3.5 pb-3">
        <button
          type="button"
          title="恢复默认颜色"
          onClick={() => commit(null, selectedSymbol)}
          className={[
            'charkle-pressable h-6 w-6 rounded-full flex items-center justify-center bg-[var(--bg-subtle)] text-[var(--text-secondary)] cursor-pointer',
            selectedColor === null ? 'ring-2 ring-[var(--accent)] ring-offset-1 ring-offset-[var(--bg-elevated)]' : '',
          ].join(' ')}
        >
          <Ban size={12} />
        </button>

        {MACOS_FOLDER_COLORS.map((preset) => {
          const active = selectedColor?.toLowerCase() === preset.hex.toLowerCase();
          return (
            <button
              key={preset.hex}
              type="button"
              title={preset.name}
              onClick={() => commit(preset.hex, selectedSymbol)}
              className={[
                'charkle-pressable h-5.5 w-5.5 rounded-full cursor-pointer border border-black/10',
                active ? 'ring-2 ring-[var(--accent)] ring-offset-1 ring-offset-[var(--bg-elevated)]' : '',
              ].join(' ')}
              style={{ backgroundColor: preset.hex }}
            />
          );
        })}

        <label
          title="自定义任意颜色"
          className="charkle-pressable relative h-5.5 w-5.5 rounded-full overflow-hidden border border-[var(--border-strong)] cursor-pointer shrink-0"
          style={{
            background:
              'conic-gradient(#FF453A, #FF9F0A, #FFD60A, #30D158, #0A84FF, #BF5AF2, #FF453A)',
          }}
        >
          <input
            type="color"
            value={selectedColor ?? '#0A84FF'}
            onChange={(e) => commit(e.target.value.toUpperCase(), selectedSymbol)}
            className="opacity-0 absolute inset-0 w-full h-full cursor-pointer"
          />
        </label>
      </div>

      <div className="h-px bg-[var(--border-hairline)]" />

      {/* Symbol Grid or Emoji Mode */}
      <div className="h-[244px] overflow-y-auto charkle-scroll p-3">
        {showEmojiMode ? (
          <div className="flex flex-col gap-3">
            <div className="flex items-center gap-1.5">
              <input
                type="text"
                value={customEmojiInput}
                onChange={(e) => setCustomEmojiInput(e.target.value)}
                onKeyDown={(e) => {
                  if (e.key === 'Enter') applyCustomEmoji();
                }}
                placeholder="输入任意表情符号…"
                className="flex-1 h-7.5 px-2.5 text-[12.5px] rounded-[var(--radius-chip)] bg-[var(--bg-elevated)] border border-[var(--border-hairline)] text-[var(--text-primary)] focus:outline-none focus:border-[var(--accent)]"
              />
              <button
                type="button"
                disabled={!customEmojiInput.trim()}
                onClick={applyCustomEmoji}
                className="charkle-pressable h-7.5 px-2.5 text-[12px] font-medium rounded-[var(--radius-chip)] bg-[var(--bg-subtle)] text-[var(--text-primary)] disabled:opacity-40 cursor-pointer"
              >
                应用
              </button>
            </div>
            <div className="grid grid-cols-8 gap-1">
              {EMOJI_PRESETS.map((emoji) => {
                const token = `emoji:${emoji}`;
                const active = selectedSymbol === token;
                return (
                  <button
                    key={emoji}
                    type="button"
                    onClick={() => commit(selectedColor, active ? null : token)}
                    className={[
                      'charkle-pressable h-8 w-8 flex items-center justify-center text-[17px] rounded-[var(--radius-chip)] cursor-pointer',
                      active ? 'bg-[var(--accent-soft)] ring-1 ring-[var(--accent)]' : 'hover:bg-[var(--bg-subtle)]',
                    ].join(' ')}
                  >
                    {emoji}
                  </button>
                );
              })}
            </div>
          </div>
        ) : (
          <div className="flex flex-col gap-3.5">
            {SYMBOL_GROUPS.map((group) => (
              <div key={group.id} className="flex flex-col gap-1.5">
                <span className="text-[11px] font-semibold text-[var(--text-tertiary)] px-0.5">
                  {group.title}
                </span>
                <div className="grid grid-cols-6 gap-1.5">
                  {group.symbols.map((sfName) => {
                    const token = `sf:${sfName}`;
                    const active = selectedSymbol === token;
                    const IconComp = SF_SYMBOL_TO_LUCIDE[sfName];
                    if (!IconComp) return null;
                    return (
                      <button
                        key={sfName}
                        type="button"
                        onClick={() => commit(selectedColor, active ? null : token)}
                        className={[
                          'charkle-pressable h-8 flex items-center justify-center rounded-[var(--radius-chip)] cursor-pointer',
                          active
                            ? 'bg-[var(--accent-soft)] text-[var(--accent)] ring-1 ring-[var(--accent)]'
                            : 'bg-[var(--bg-subtle)]/50 text-[var(--text-secondary)] hover:text-[var(--text-primary)] hover:bg-[var(--bg-subtle)]',
                        ].join(' ')}
                      >
                        <IconComp size={15} strokeWidth={1.9} />
                      </button>
                    );
                  })}
                </div>
              </div>
            ))}
          </div>
        )}
      </div>

      <div className="h-px bg-[var(--border-hairline)]" />

      {/* Footer */}
      <div className="flex items-center gap-2 p-2.5">
        <button
          type="button"
          onClick={() => commit(null, null)}
          className="charkle-pressable flex-1 h-7.5 text-[12px] font-medium rounded-[var(--radius-chip)] bg-[var(--bg-subtle)] text-[var(--text-primary)] hover:bg-[var(--border-hairline)] cursor-pointer"
        >
          清除
        </button>
        <button
          type="button"
          onClick={() => setShowEmojiMode((v) => !v)}
          className={[
            'charkle-pressable flex-1 h-7.5 inline-flex items-center justify-center gap-1.5 text-[12px] font-medium rounded-[var(--radius-chip)] cursor-pointer',
            showEmojiMode
              ? 'bg-[var(--accent-soft)] text-[var(--accent)]'
              : 'bg-[var(--bg-subtle)] text-[var(--text-primary)] hover:bg-[var(--border-hairline)]',
          ].join(' ')}
        >
          {showEmojiMode ? <LayoutGrid size={13} /> : <Smile size={13} />}
          {showEmojiMode ? '系统图标' : '表情符号'}
        </button>
      </div>
    </div>
  );
};
