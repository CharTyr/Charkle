import React, { useEffect, useState } from 'react';
import {
  Emoji16Regular,
  Grid16Regular,
  Prohibited12Regular,
} from '@fluentui/react-icons';
import {
  Button,
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
 * Fluent 2 Folder Customization Flyout:
 * - Live 56px folder preview + folder title
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
          <span className="text-[13px] font-semibold text-[var(--text-primary)] truncate max-w-full">
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
              'focus-visible:outline-2 focus-visible:outline-offset-1 focus-visible:outline-[var(--accent)]',
              !colorHex ? 'ring-2 ring-[var(--accent)]' : 'border border-[var(--win-stroke-control)]',
            ].join(' ')}
          >
            <Prohibited12Regular className="w-3 h-3" />
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
                  'focus-visible:outline-2 focus-visible:outline-offset-1 focus-visible:outline-[var(--accent)]',
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

        <div className="h-px bg-[var(--win-stroke-divider)]" />

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
                  aria-label="输入任意表情符号"
                  className="win-input-elevation flex-1 min-w-0 h-8 px-2.5 rounded-[var(--win-radius-control)] text-[12.5px] text-[var(--text-primary)] placeholder:text-[var(--text-tertiary)] outline-none"
                />
                <Button
                  type="submit"
                  variant="standard"
                  size="xs"
                  disabled={!customEmojiInput.trim()}
                  className="h-8"
                >
                  应用
                </Button>
              </form>

              <div className="grid grid-cols-8 gap-1">
                {EMOJI_PRESETS.map((emoji) => {
                  const token = `emoji:${emoji}`;
                  const active = customSymbol === token;
                  return (
                    <button
                      key={emoji}
                      type="button"
                      aria-label={`选择表情 ${emoji}`}
                      onClick={() => onApply(colorHex, active ? null : token)}
                      className={[
                        'charkle-pressable h-[30px] w-[30px] inline-flex items-center justify-center rounded-[var(--win-radius-control)] text-[16px] cursor-pointer',
                        'focus-visible:outline-2 focus-visible:outline-offset-1 focus-visible:outline-[var(--accent)]',
                        active
                          ? 'bg-[var(--accent-soft)] ring-1 ring-[var(--accent-ring)]'
                          : 'hover:bg-[var(--win-subtle-hover)] active:bg-[var(--win-subtle-active)]',
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
                          aria-label={`选择图标 ${sym}`}
                          onClick={() => onApply(colorHex, active ? null : token)}
                          className={[
                            'charkle-pressable h-[30px] inline-flex items-center justify-center rounded-[var(--win-radius-control)] cursor-pointer',
                            'focus-visible:outline-2 focus-visible:outline-offset-1 focus-visible:outline-[var(--accent)]',
                            active
                              ? 'bg-[var(--accent-soft)] text-[var(--accent)] ring-1 ring-[var(--accent-ring)]'
                              : 'bg-[var(--win-control-fill)] text-[var(--text-primary)]/80 hover:bg-[var(--win-subtle-hover)] active:bg-[var(--win-subtle-active)]',
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

        <div className="h-px bg-[var(--win-stroke-divider)]" />

        {/* Footer: Clear | Symbol/Emoji Switch */}
        <div className="p-2.5 grid grid-cols-2 gap-2">
          <Button
            variant="standard"
            size="sm"
            onClick={() => onApply(null, null)}
            className="w-full justify-center"
          >
            清除样式
          </Button>

          <Button
            variant="standard"
            size="sm"
            active={showEmojiMode}
            onClick={() => setShowEmojiMode((v) => !v)}
            className="w-full justify-center"
          >
            {showEmojiMode ? (
              <Grid16Regular className="w-3.5 h-3.5" />
            ) : (
              <Emoji16Regular className="w-3.5 h-3.5" />
            )}
            <span>{showEmojiMode ? '系统图标' : '表情符号'}</span>
          </Button>
        </div>
      </div>
    </Popover>
  );
};
