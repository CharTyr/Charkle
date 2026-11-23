import React from 'react';
import { RotateCcw } from 'lucide-react';
import {
  FOLDER_PRESET_COLORS,
  Popover,
  SF_SYMBOL_TO_LUCIDE,
} from '../../design-system';

const PRESET_EMOJIS = [
  '🎨', '📷', '🎬', '📐', '✨', '🧩', '🌿', '💡',
  '🎵', '📚', '💻', '🚀', '🏛️', '🧵', '🪴', '📌',
];

const SF_SYMBOL_NAMES = Object.keys(SF_SYMBOL_TO_LUCIDE);

export interface FolderCustomizationPopoverProps {
  open: boolean;
  onOpenChange: (open: boolean) => void;
  anchorEl: HTMLElement | null;
  colorHex?: string | null;
  customSymbol?: string | null;
  onApply: (colorHex: string | null, customSymbol: string | null) => void;
}

export const FolderCustomizationPopover: React.FC<FolderCustomizationPopoverProps> = ({
  open,
  onOpenChange,
  anchorEl,
  colorHex = null,
  customSymbol = null,
  onApply,
}) => {
  return (
    <Popover
      open={open}
      onOpenChange={onOpenChange}
      anchorEl={anchorEl}
      placement="right-start"
      className="w-[292px] p-3"
    >
      <div className="flex items-center justify-between mb-2">
        <span className="text-[12px] font-semibold text-[var(--text-primary)]">
          自定义图标与色彩
        </span>
        {(colorHex || customSymbol) && (
          <button
            type="button"
            onClick={() => onApply(null, null)}
            className="charkle-pressable inline-flex items-center gap-1 text-[11px] text-[var(--text-secondary)] hover:text-[var(--text-primary)] cursor-pointer"
          >
            <RotateCcw size={11} />
            重置
          </button>
        )}
      </div>

      {/* Color swatches */}
      <div className="mb-3">
        <div className="text-[11px] text-[var(--text-tertiary)] mb-1.5">文件夹色彩</div>
        <div className="flex items-center gap-1.5 flex-wrap">
          <button
            type="button"
            title="默认颜色"
            onClick={() => onApply(null, customSymbol)}
            className={[
              'charkle-pressable h-6 w-6 rounded-full border cursor-pointer flex items-center justify-center text-[10px] text-[var(--text-secondary)]',
              !colorHex
                ? 'border-[var(--accent)] ring-2 ring-[var(--accent-ring)] bg-[var(--bg-subtle)]'
                : 'border-[var(--border-strong)] bg-[var(--bg-subtle)]',
            ].join(' ')}
          >
            无
          </button>
          {FOLDER_PRESET_COLORS.map((preset) => {
            const selected = colorHex?.toUpperCase() === preset.hex.toUpperCase();
            return (
              <button
                key={preset.hex}
                type="button"
                title={preset.name}
                aria-label={preset.name}
                onClick={() => onApply(preset.hex, customSymbol)}
                className={[
                  'charkle-pressable h-6 w-6 rounded-full cursor-pointer border border-black/10',
                  selected ? 'ring-2 ring-offset-1 ring-[var(--accent)]' : '',
                ].join(' ')}
                style={{ backgroundColor: preset.hex }}
              />
            );
          })}
        </div>
      </div>

      {/* 48 SF Symbol presets */}
      <div className="mb-3">
        <div className="flex items-center justify-between mb-1.5">
          <span className="text-[11px] text-[var(--text-tertiary)]">图标徽章</span>
          {customSymbol && (
            <button
              type="button"
              onClick={() => onApply(colorHex, null)}
              className="text-[11px] text-[var(--text-secondary)] hover:text-[var(--text-primary)] cursor-pointer"
            >
              清除徽章
            </button>
          )}
        </div>
        <div className="grid grid-cols-8 gap-1 max-h-[144px] overflow-y-auto charkle-scroll pr-0.5">
          {SF_SYMBOL_NAMES.map((sym) => {
            const Icon = SF_SYMBOL_TO_LUCIDE[sym];
            const encoded = `sf:${sym}`;
            const active = customSymbol === encoded || customSymbol === sym;
            return (
              <button
                key={sym}
                type="button"
                title={sym}
                onClick={() => onApply(colorHex, encoded)}
                className={[
                  'charkle-pressable h-7 w-7 inline-flex items-center justify-center rounded-[var(--radius-card-inner)] cursor-pointer',
                  active
                    ? 'bg-[var(--accent-soft)] text-[var(--accent)]'
                    : 'text-[var(--text-secondary)] hover:bg-[var(--bg-subtle)] hover:text-[var(--text-primary)]',
                ].join(' ')}
              >
                <Icon size={14} strokeWidth={1.85} />
              </button>
            );
          })}
        </div>
      </div>

      {/* Emoji presets */}
      <div>
        <div className="text-[11px] text-[var(--text-tertiary)] mb-1.5">表情符号</div>
        <div className="grid grid-cols-8 gap-1">
          {PRESET_EMOJIS.map((emoji) => {
            const encoded = `emoji:${emoji}`;
            const active = customSymbol === encoded;
            return (
              <button
                key={emoji}
                type="button"
                onClick={() => onApply(colorHex, encoded)}
                className={[
                  'charkle-pressable h-7 w-7 inline-flex items-center justify-center rounded-[var(--radius-card-inner)] text-[14px] cursor-pointer',
                  active
                    ? 'bg-[var(--accent-soft)]'
                    : 'hover:bg-[var(--bg-subtle)]',
                ].join(' ')}
              >
                {emoji}
              </button>
            );
          })}
        </div>
      </div>
    </Popover>
  );
};
