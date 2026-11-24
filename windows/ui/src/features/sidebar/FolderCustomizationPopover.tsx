import React, { useEffect, useState } from 'react';
import { Ban, LayoutGrid, Smile } from 'lucide-react';
import {
  CharkleFolderIcon,
  FOLDER_PRESET_COLORS,
  Popover,
  SF_SYMBOL_TO_LUCIDE,
} from '../../design-system';

interface SymbolGroup {
  id: string;
  title: string;
  symbols: string[];
}

const SYMBOL_GROUPS: SymbolGroup[] = [
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

const EMOJI_PRESETS: string[] = [
  '🎨', '✨', '🌸', '🌊', '🔥', '⚡️', '🌙', '☀️',
  '🎬', '📷', '🎧', '🎮', '🧩', '📐', '💎', '🚀',
  '💻', '📱', '🧠', '🦊', '🐱', '🌿', '🏔️', '🏙️',
  '⭐️', '❤️', '📌', '🔖', '📦', '🗂️', '🧪', '🛠️',
];

export interface FolderCustomizationPopoverProps {
  open: boolean;
  onOpenChange: (open: boolean) => void;
  anchorEl: HTMLElement | null;
  folderName?: string;
  colorHex?: string | null;
  customSymbol?: string | null;
  onApply: (colorHex: string | null, customSymbol: string | null) => void;
}

/**
 * 1:1 macOS `FolderCustomizationPopover.swift`:
 * - Live 58px folder preview + folder title
 * - Reset dot + 7 preset folder colors + custom color picker
 * - 4 categorized 48-icon gallery OR 32-emoji + custom emoji picker
 * - Bottom footer: Clear | Emoji/Icon mode toggle
 */
export const FolderCustomizationPopover: React.FC<FolderCustomizationPopoverProps> = ({
  open,
  onOpenChange,
  anchorEl,
  folderName = '文件夹',
  colorHex = null,
  customSymbol = null,
  onApply,
}) => {
  const [showEmojiMode, setShowEmojiMode] = useState(
    Boolean(customSymbol?.startsWith('emoji:')),
  );
  const [customEmojiInput, setCustomEmojiInput] = useState('');

  useEffect(() => {
    if (open) {
      setShowEmojiMode(Boolean(customSymbol?.startsWith('emoji:')));
      setCustomEmojiInput('');
    }
  }, [open, customSymbol]);

  const applyCustomEmoji = () => {
    const trimmed = customEmojiInput.trim();
    if (!trimmed) return;
    const first = Array.from(trimmed)[0];
    if (!first) return;
    setCustomEmojiInput('');
    onApply(colorHex, `emoji:${first}`);
  };

  return (
    <Popover
      open={open}
      onOpenChange={onOpenChange}
      anchorEl={anchorEl}
      placement="right-start"
      className="w-[288px] p-0 overflow-hidden"
    >
      <div className="flex flex-col">
        {/* Live Large Folder Preview */}
        <div className="pt-4 pb-3 px-4 flex flex-col items-center gap-1.5">
          <CharkleFolderIcon
            colorHex={colorHex}
            customSymbol={customSymbol}
            size={56}
            isActive={false}
          />
          <span className="text-[12.5px] font-semibold text-[var(--text-primary)] truncate max-w-full">
            {folderName}
          </span>
        </div>

        {/* Color Dot Strip + Reset + Custom Color Picker */}
        <div className="px-3.5 pb-3 flex items-center justify-center gap-1.5">
          <button
            type="button"
            title="恢复默认颜色"
            aria-label="恢复默认颜色"
            onClick={() => onApply(null, customSymbol)}
            className={[
              'charkle-pressable w-[22px] h-[22px] rounded-full bg-[var(--bg-subtle)] inline-flex items-center justify-center text-[var(--text-secondary)] cursor-pointer',
              !colorHex ? 'ring-2 ring-[var(--accent)]' : 'border border-[var(--border-hairline)]',
            ].join(' ')}
          >
            <Ban size={12} />
          </button>

          {FOLDER_PRESET_COLORS.map((preset) => {
            const active = colorHex?.toUpperCase() === preset.hex.toUpperCase();
            return (
              <button
                key={preset.hex}
                type="button"
                title={preset.name}
                aria-label={preset.name}
                onClick={() => onApply(preset.hex, customSymbol)}
                className={[
                  'charkle-pressable w-[22px] h-[22px] rounded-full cursor-pointer border border-black/10',
                  active ? 'ring-2 ring-offset-1 ring-[var(--accent)]' : '',
                ].join(' ')}
                style={{ backgroundColor: preset.hex }}
              />
            );
          })}

          <label
            title="自定义任意颜色"
            className="charkle-pressable relative w-[22px] h-[22px] rounded-full overflow-hidden border border-[var(--border-strong)] cursor-pointer shrink-0"
            style={{
              background:
                'conic-gradient(from 0deg, #ff453a, #ff9f0a, #ffd60a, #30d158, #0a84ff, #bf5af2, #ff453a)',
            }}
          >
            <input
              type="color"
              aria-label="自定义任意颜色"
              value={colorHex ?? '#2A60E0'}
              onChange={(e) => onApply(e.target.value.toUpperCase(), customSymbol)}
              className="opacity-0 absolute inset-0 w-full h-full cursor-pointer"
            />
          </label>
        </div>

        <div className="h-px bg-[var(--border-hairline)]" />

        {/* Categorized Symbol Gallery or Emoji Picker */}
        <div className="h-[246px] overflow-y-auto charkle-scroll p-3.5">
          {showEmojiMode ? (
            <div className="flex flex-col gap-3">
              <form
                onSubmit={(e) => {
                  e.preventDefault();
                  applyCustomEmoji();
                }}
                className="flex items-center gap-1.5"
              >
                <input
                  type="text"
                  value={customEmojiInput}
                  onChange={(e) => setCustomEmojiInput(e.target.value)}
                  placeholder="输入任意表情符号…"
                  className="flex-1 min-w-0 h-7 px-2 rounded-[7px] bg-[var(--bg-inspector-field)] border border-[var(--border-hairline)] focus:border-[var(--accent)] text-[12.5px] text-[var(--text-primary)] outline-none"
                />
                <button
                  type="submit"
                  disabled={!customEmojiInput.trim()}
                  className="charkle-pressable h-7 px-2.5 rounded-[7px] bg-[var(--bg-subtle)] hover:bg-[var(--border-hairline)] text-[11.5px] font-medium text-[var(--text-primary)] disabled:opacity-45 cursor-pointer"
                >
                  应用
                </button>
              </form>

              <div className="grid grid-cols-8 gap-1.5">
                {EMOJI_PRESETS.map((emoji) => {
                  const token = `emoji:${emoji}`;
                  const active = customSymbol === token;
                  return (
                    <button
                      key={emoji}
                      type="button"
                      onClick={() => onApply(colorHex, active ? null : token)}
                      className={[
                        'charkle-pressable h-[30px] w-[30px] inline-flex items-center justify-center rounded-[7px] text-[17px] cursor-pointer',
                        active ? 'bg-[var(--accent-soft)]' : 'hover:bg-[var(--bg-subtle)]',
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
                  <span className="text-[11px] font-semibold text-[var(--text-secondary)]">
                    {group.title}
                  </span>
                  <div className="grid grid-cols-6 gap-1.5">
                    {group.symbols.map((sym) => {
                      const Icon = SF_SYMBOL_TO_LUCIDE[sym];
                      if (!Icon) return null;
                      const token = `sf:${sym}`;
                      const active = customSymbol === token || customSymbol === sym;
                      return (
                        <button
                          key={sym}
                          type="button"
                          onClick={() => onApply(colorHex, active ? null : token)}
                          className={[
                            'charkle-pressable h-[30px] inline-flex items-center justify-center rounded-[7px] cursor-pointer',
                            active
                              ? 'bg-[var(--accent-soft)] text-[var(--accent)]'
                              : 'bg-[var(--bg-subtle)]/55 text-[var(--text-primary)]/76 hover:bg-[var(--bg-subtle)]',
                          ].join(' ')}
                        >
                          <Icon size={14.5} strokeWidth={1.85} />
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

        {/* Footer: Clear | Symbol/Emoji Switch */}
        <div className="p-2.5 grid grid-cols-2 gap-2">
          <button
            type="button"
            onClick={() => onApply(null, null)}
            className="charkle-pressable py-1.5 rounded-[7px] bg-[var(--bg-subtle)] hover:bg-[var(--border-hairline)] text-[12px] font-medium text-[var(--text-primary)] cursor-pointer"
          >
            清除
          </button>

          <button
            type="button"
            onClick={() => setShowEmojiMode((v) => !v)}
            className={[
              'charkle-pressable py-1.5 rounded-[7px] text-[12px] font-medium inline-flex items-center justify-center gap-1.5 cursor-pointer',
              showEmojiMode
                ? 'bg-[var(--accent-soft)] text-[var(--accent)]'
                : 'bg-[var(--bg-subtle)] hover:bg-[var(--border-hairline)] text-[var(--text-primary)]',
            ].join(' ')}
          >
            {showEmojiMode ? <LayoutGrid size={12.5} /> : <Smile size={12.5} />}
            <span>{showEmojiMode ? '系统图标' : '表情符号'}</span>
          </button>
        </div>
      </div>
    </Popover>
  );
};
