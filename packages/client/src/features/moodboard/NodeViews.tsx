import React, { useEffect, useRef, useState } from 'react';
import {
  ArrowLeftRight,
  Check,
  Crop,
  Crosshair,
  Expand,
  FlipHorizontal2,
  FlipVertical2,
  Focus,
  Image as ImageIcon,
  LayoutGrid,
  Lock,
  MoreHorizontal,
  RotateCcw,
  RotateCw,
  Scissors,
  Search,
  Sparkles,
  Star,
  Trash2,
  Unlock,
} from 'lucide-react';
import {
  GROUP_TINTS,
  NOTE_STYLES,
  clampCropRect,
  isLightHex,
} from '@charkle/shared';
import type {
  AssetRecord,
  BoardNode,
  GroupTint,
  LabColor,
  NormalizedCropRect,
  NoteStyle,
} from '@charkle/shared';
import { originalMediaURL, thumbnailURL } from '../../api/client';
import { CharkleIcon } from '../../design-system/CharkleIcon';
import { GlassSurface } from '../../design-system/GlassSurface';
import { Popover } from '../../design-system/Popover';
import { useResolvedIsDark } from '../../design-system/theme';
import {
  GROUP_TINT_PALETTE,
  NOTE_FONT_SIZES,
  NOTE_STYLE_PALETTE,
} from './palettes';

// MARK: - Top Floating Board Palette Strip

export interface BoardPaletteHeaderStripProps {
  colors: LabColor[];
  onCopyHex: (hex: string) => void;
  onSearchColor: (hex: string) => void;
}

export const BoardPaletteHeaderStrip: React.FC<BoardPaletteHeaderStripProps> = ({
  colors,
  onCopyHex,
  onSearchColor,
}) => {
  const [copiedHex, setCopiedHex] = useState<string | null>(null);

  if (colors.length === 0) return null;

  const handleCopy = (hex: string) => {
    const upper = hex.toUpperCase();
    onCopyHex(upper);
    setCopiedHex(upper);
    window.setTimeout(() => {
      setCopiedHex((cur) => (cur === upper ? null : cur));
    }, 1200);
  };

  return (
    <GlassSurface
      variant="regular"
      radius="pill"
      className="inline-flex items-center gap-1.5 px-3 py-1.5 max-w-full overflow-x-auto charkle-scroll"
    >
      <span className="text-[11px] font-medium text-[var(--text-secondary)] mr-0.5 shrink-0 select-none">
        板内色卡
      </span>
      {colors.slice(0, 7).map((swatch) => {
        const hex = swatch.hex.toUpperCase();
        const light = isLightHex(hex);
        const isCopied = copiedHex === hex;
        return (
          <div key={hex} className="inline-flex items-center group/swatch shrink-0">
            <button
              type="button"
              onClick={() => handleCopy(hex)}
              onContextMenu={(e) => {
                e.preventDefault();
                onSearchColor(hex);
              }}
              title={`点击复制 ${hex}，右键或点放大镜以此色检索素材库`}
              className="charkle-pressable inline-flex items-center gap-1.5 px-2 py-1 rounded-[var(--radius-chip)] bg-[var(--bg-elevated)]/90 border border-[var(--border-hairline)] hover:border-[var(--border-strong)] cursor-pointer"
            >
              <span
                className="w-3.5 h-3.5 rounded-[4px] shrink-0"
                style={{
                  backgroundColor: hex,
                  boxShadow: light
                    ? 'inset 0 0 0 1px rgba(0,0,0,0.14)'
                    : 'inset 0 0 0 1px rgba(255,255,255,0.2)',
                }}
              />
              <span className="text-[10.5px] font-mono font-medium text-[var(--text-primary)]/85 tabular-nums">
                {isCopied ? '已复制' : hex}
              </span>
            </button>
            <button
              type="button"
              onClick={() => onSearchColor(hex)}
              aria-label={`以 ${hex} 筛选素材库`}
              title={`以 ${hex} 筛选素材库`}
              className="charkle-pressable ml-0.5 w-5 h-5 rounded-[6px] inline-flex items-center justify-center text-[var(--text-tertiary)] hover:text-[var(--text-primary)] hover:bg-[var(--bg-subtle)] opacity-0 group-hover/swatch:opacity-100 focus-visible:opacity-100 transition-opacity duration-150 cursor-pointer"
            >
              <Search size={11} />
            </button>
          </div>
        );
      })}
    </GlassSurface>
  );
};

// MARK: - Inline Non-Destructive Crop Overlay

interface InlineCropEditorProps {
  crop: NormalizedCropRect;
  onChange: (crop: NormalizedCropRect) => void;
  onCommit: (crop: NormalizedCropRect) => void;
  onCancel: () => void;
  onReset: () => void;
}

const InlineCropEditor: React.FC<InlineCropEditorProps> = ({
  crop,
  onChange,
  onCommit,
  onCancel,
  onReset,
}) => {
  const containerRef = useRef<HTMLDivElement | null>(null);
  const dragRef = useRef<{
    mode: 'move' | 'nw' | 'ne' | 'sw' | 'se';
    startX: number;
    startY: number;
    startCrop: NormalizedCropRect;
  } | null>(null);

  const startDrag = (mode: 'move' | 'nw' | 'ne' | 'sw' | 'se', e: React.PointerEvent) => {
    e.stopPropagation();
    e.preventDefault();
    (e.currentTarget as HTMLElement).setPointerCapture(e.pointerId);
    dragRef.current = {
      mode,
      startX: e.clientX,
      startY: e.clientY,
      startCrop: { ...crop },
    };
  };

  const handleMove = (e: React.PointerEvent) => {
    const state = dragRef.current;
    const rect = containerRef.current?.getBoundingClientRect();
    if (!state || !rect || rect.width < 10 || rect.height < 10) return;
    e.stopPropagation();
    const dx = (e.clientX - state.startX) / rect.width;
    const dy = (e.clientY - state.startY) / rect.height;
    const sc = state.startCrop;
    let next: NormalizedCropRect = { ...sc };

    if (state.mode === 'move') {
      next.x = Math.max(0, Math.min(1 - sc.width, sc.x + dx));
      next.y = Math.max(0, Math.min(1 - sc.height, sc.y + dy));
    } else {
      let left = sc.x;
      let top = sc.y;
      let right = sc.x + sc.width;
      let bottom = sc.y + sc.height;
      if (state.mode === 'nw' || state.mode === 'sw') {
        left = Math.max(0, Math.min(right - 0.1, sc.x + dx));
      }
      if (state.mode === 'ne' || state.mode === 'se') {
        right = Math.min(1, Math.max(left + 0.1, sc.x + sc.width + dx));
      }
      if (state.mode === 'nw' || state.mode === 'ne') {
        top = Math.max(0, Math.min(bottom - 0.1, sc.y + dy));
      }
      if (state.mode === 'sw' || state.mode === 'se') {
        bottom = Math.min(1, Math.max(top + 0.1, sc.y + sc.height + dy));
      }
      next = clampCropRect({
        x: left,
        y: top,
        width: right - left,
        height: bottom - top,
      });
    }
    onChange(next);
  };

  const endDrag = (e: React.PointerEvent) => {
    if (!dragRef.current) return;
    e.stopPropagation();
    dragRef.current = null;
  };

  return (
    <div
      ref={containerRef}
      className="absolute inset-0 z-30 select-none bg-black/50"
      onPointerDown={(e) => e.stopPropagation()}
      onPointerMove={handleMove}
      onPointerUp={endDrag}
    >
      {/* Active crop frame */}
      <div
        onPointerDown={(e) => startDrag('move', e)}
        className="absolute border-2 border-white shadow-[0_0_0_9999px_rgba(0,0,0,0.48)] cursor-move"
        style={{
          left: `${crop.x * 100}%`,
          top: `${crop.y * 100}%`,
          width: `${crop.width * 100}%`,
          height: `${crop.height * 100}%`,
        }}
      >
        {/* Rule-of-thirds gridlines */}
        <div className="pointer-events-none absolute inset-0 grid grid-cols-3 grid-rows-3">
          <div className="border-r border-b border-white/30" />
          <div className="border-r border-b border-white/30" />
          <div className="border-b border-white/30" />
          <div className="border-r border-b border-white/30" />
          <div className="border-r border-b border-white/30" />
          <div className="border-b border-white/30" />
          <div className="border-r border-white/30" />
          <div className="border-r border-white/30" />
          <div />
        </div>
        {/* 4 corner handles */}
        {(['nw', 'ne', 'sw', 'se'] as const).map((corner) => (
          <div
            key={corner}
            onPointerDown={(e) => startDrag(corner, e)}
            className="absolute w-3.5 h-3.5 bg-white border border-black/40 rounded-[3px]"
            style={{
              left: corner.includes('w') ? -7 : undefined,
              right: corner.includes('e') ? -7 : undefined,
              top: corner.includes('n') ? -7 : undefined,
              bottom: corner.includes('s') ? -7 : undefined,
              cursor: corner === 'nw' || corner === 'se' ? 'nwse-resize' : 'nesw-resize',
            }}
          />
        ))}
      </div>

      {/* Confirm / Reset / Cancel floating bar */}
      <div className="absolute bottom-2 left-1/2 -translate-x-1/2 flex items-center gap-1.5 px-2 py-1 rounded-full bg-[#111317]/92 border border-white/15 shadow-lg">
        <button
          type="button"
          onClick={() => onCommit(crop)}
          className="charkle-pressable inline-flex items-center gap-1 px-2.5 py-0.5 rounded-full bg-[var(--accent)] text-white text-[11px] font-medium cursor-pointer"
        >
          <Check size={12} /> 应用裁切
        </button>
        <button
          type="button"
          onClick={onReset}
          className="charkle-pressable px-2 py-0.5 rounded-full text-white/80 hover:text-white text-[11px] cursor-pointer"
        >
          还原
        </button>
        <button
          type="button"
          onClick={onCancel}
          className="charkle-pressable px-2 py-0.5 rounded-full text-white/65 hover:text-white text-[11px] cursor-pointer"
        >
          取消
        </button>
      </div>
    </div>
  );
};

// MARK: - 1. AssetRef Node View

export interface AssetNodeViewProps {
  node: BoardNode;
  asset?: AssetRecord;
  cacheBustVersion: number;
  isSelected: boolean;
  isSwapTarget: boolean;
  isAutoEditorial: boolean;
  isCropping: boolean;
  onStartInlineCrop: () => void;
  onCommitCrop: (crop: NormalizedCropRect | null) => void;
  onCancelCrop: () => void;
  onToggleHero: () => void;
  onTriggerSwap: () => void;
  onOpenQuickLook: () => void;
  onSmartFocusSubject: () => void;
  onSemanticCropPrompt: () => void;
  onVisualMatchCrop: () => void;
  onCleanContentCrop: () => void;
  onPinpointAnnotate: () => void;
  onRotateBy: (delta: number) => void;
  onFlipHorizontal: () => void;
  onFlipVertical: () => void;
  onToggleLock: () => void;
  onDelete: () => void;
}

export const AssetNodeView: React.FC<AssetNodeViewProps> = ({
  node,
  asset,
  cacheBustVersion,
  isSelected,
  isSwapTarget,
  isAutoEditorial,
  isCropping,
  onStartInlineCrop,
  onCommitCrop,
  onCancelCrop,
  onToggleHero,
  onTriggerSwap,
  onOpenQuickLook,
  onSmartFocusSubject,
  onSemanticCropPrompt,
  onVisualMatchCrop,
  onCleanContentCrop,
  onPinpointAnnotate,
  onRotateBy,
  onFlipHorizontal,
  onFlipVertical,
  onToggleLock,
  onDelete,
}) => {
  const [menuOpen, setMenuOpen] = useState(false);
  const [menuPoint, setMenuPoint] = useState<{ x: number; y: number } | null>(null);
  const menuBtnRef = useRef<HTMLButtonElement | null>(null);
  const [hovered, setHovered] = useState(false);
  const [draftCrop, setDraftCrop] = useState<NormalizedCropRect>({ x: 0.1, y: 0.1, width: 0.8, height: 0.8 });

  const kind = node.kind.type === 'assetRef' ? node.kind : null;
  const weight = kind?.weight ?? 1;
  const crop = kind?.crop ?? null;
  const hasCrop = Boolean(crop && (crop.x > 0.005 || crop.y > 0.005 || crop.width < 0.995 || crop.height < 0.995));

  useEffect(() => {
    if (isCropping) {
      setDraftCrop(crop ? { ...crop } : { x: 0.08, y: 0.08, width: 0.84, height: 0.84 });
    }
  }, [isCropping, crop]);

  const flipTransform =
    node.flipHorizontal || node.flipVertical
      ? `scale(${node.flipHorizontal ? -1 : 1}, ${node.flipVertical ? -1 : 1})`
      : undefined;

  const isVideo = asset?.mediaKind === 'video';
  const isGif = asset?.mediaKind === 'animatedImage';
  const imgSrc = asset
    ? isGif
      ? originalMediaURL(asset.id)
      : thumbnailURL(asset.id, weight >= 2 ? 'preview1400' : 'grid520', cacheBustVersion)
    : '';

  // Compute cropped image style using CSS translate/scale so non-destructive crop renders cleanly
  const croppedMediaStyle: React.CSSProperties =
    !isCropping && hasCrop && crop
      ? {
          width: `${100 / Math.max(0.05, crop.width)}%`,
          height: `${100 / Math.max(0.05, crop.height)}%`,
          maxWidth: 'none',
          maxHeight: 'none',
          transform: `translate(${-crop.x * 100}%, ${-crop.y * 100}%)`,
          transformOrigin: 'top left',
        }
      : {
          width: '100%',
          height: '100%',
        };

  return (
    <div
      className="group/asset relative w-full h-full rounded-[var(--radius-card-outer)] overflow-hidden bg-[var(--bg-subtle)] select-none"
      style={{
        boxShadow: isSwapTarget
          ? '0 0 0 2.5px var(--accent), 0 10px 24px rgba(42,96,224,0.22)'
          : isSelected
            ? '0 0 0 2.5px var(--accent), 0 8px 22px rgba(0,0,0,0.16)'
            : '0 0 0 1px var(--border-hairline), 0 3px 10px rgba(0,0,0,0.06)',
      }}
      onMouseEnter={() => setHovered(true)}
      onMouseLeave={() => setHovered(false)}
      onDoubleClick={(e) => {
        e.stopPropagation();
        if (!isCropping && asset) onOpenQuickLook();
      }}
      onContextMenu={(e) => {
        e.preventDefault();
        e.stopPropagation();
        setMenuPoint({ x: e.clientX, y: e.clientY });
        setMenuOpen(true);
      }}
    >
      {/* Artwork Surface */}
      <div className="relative w-full h-full overflow-hidden" style={{ transform: flipTransform }}>
        {asset ? (
          isVideo && hovered && kind?.autoplayLoop && !isCropping ? (
            <video
              src={originalMediaURL(asset.id)}
              poster={thumbnailURL(asset.id, 'grid520', cacheBustVersion)}
              autoPlay
              muted
              loop
              playsInline
              className="object-cover block"
              style={croppedMediaStyle}
            />
          ) : (
            <img
              src={imgSrc}
              alt={asset.title}
              draggable={false}
              className="object-cover block"
              style={croppedMediaStyle}
            />
          )
        ) : (
          <div className="w-full h-full flex flex-col items-center justify-center gap-1.5 text-[var(--text-tertiary)]">
            <ImageIcon size={20} />
            <span className="text-[11px]">素材不可用</span>
          </div>
        )}
      </div>

      {/* Inline non-destructive crop editor */}
      {isCropping && (
        <InlineCropEditor
          crop={draftCrop}
          onChange={setDraftCrop}
          onCommit={(c) => onCommitCrop(c)}
          onCancel={onCancelCrop}
          onReset={() => onCommitCrop(null)}
        />
      )}

      {/* Subtle media badges (GIF / VIDEO) when idle */}
      {!isCropping && asset && (isGif || isVideo) && (
        <span className="pointer-events-none absolute top-2 right-2 px-1.5 py-0.5 rounded-[var(--radius-card-inner)] bg-black/55 text-white text-[9.5px] font-semibold tracking-wide group-hover/asset:opacity-0 transition-opacity duration-150">
          {isGif ? 'GIF' : 'VIDEO'}
        </span>
      )}

      {/* Hover / Focus / Swap quick overlay controls */}
      {!isCropping && (
        <div
          className={[
            'absolute inset-0 pointer-events-none flex flex-col justify-between p-1.5 transition-opacity duration-150',
            isSwapTarget
              ? 'opacity-100'
              : 'opacity-0 group-hover/asset:opacity-100 group-focus-within/asset:opacity-100 [@media(hover:none)]:opacity-100',
          ].join(' ')}
        >
          {/* Top Row */}
          <div className="flex items-center justify-between gap-1 pointer-events-auto">
            <div className="flex items-center gap-1">
              {(weight >= 2 || isAutoEditorial) && (
                <button
                  type="button"
                  onPointerDown={(e) => e.stopPropagation()}
                  onClick={(e) => {
                    e.stopPropagation();
                    onToggleHero();
                  }}
                  title="切换 2× 跨列主图权重"
                  className={[
                    'charkle-pressable inline-flex items-center gap-1 px-2 py-1 rounded-[var(--radius-card-inner)] text-[10px] font-semibold text-white cursor-pointer',
                    weight >= 2 ? 'bg-[var(--accent)]' : 'bg-black/58 hover:bg-black/75',
                  ].join(' ')}
                >
                  <Star size={10} fill={weight >= 2 ? 'currentColor' : 'none'} />
                  {weight >= 2 ? '主图 2×' : '设为主图'}
                </button>
              )}
              {node.isLocked && (
                <span
                  title="已锁定位置"
                  className="inline-flex items-center justify-center w-5 h-5 rounded-full bg-black/58 text-white"
                >
                  <Lock size={10} />
                </span>
              )}
            </div>

            <div className="flex items-center gap-1">
              <button
                type="button"
                onPointerDown={(e) => e.stopPropagation()}
                onClick={(e) => {
                  e.stopPropagation();
                  onTriggerSwap();
                }}
                title="打开右侧候选池原地替换这张图"
                className={[
                  'charkle-pressable inline-flex items-center gap-1 px-2 py-1 rounded-[var(--radius-card-inner)] text-[10px] font-semibold text-white cursor-pointer',
                  isSwapTarget ? 'bg-[var(--accent)]' : 'bg-black/58 hover:bg-black/75',
                ].join(' ')}
              >
                <ArrowLeftRight size={10} />
                换一张
              </button>
              <button
                ref={menuBtnRef}
                type="button"
                onPointerDown={(e) => e.stopPropagation()}
                onClick={(e) => {
                  e.stopPropagation();
                  setMenuPoint(null);
                  setMenuOpen((o) => !o);
                }}
                aria-label="更多操作"
                title="智能取景、标注与更多操作"
                className="charkle-pressable inline-flex items-center justify-center w-6 h-6 rounded-[var(--radius-card-inner)] bg-black/58 hover:bg-black/75 text-white cursor-pointer"
              >
                <MoreHorizontal size={12} />
              </button>
            </div>
          </div>

          {/* Bottom Row */}
          <div className="flex items-center justify-between gap-1 pointer-events-auto">
            {hasCrop ? (
              <button
                type="button"
                onPointerDown={(e) => e.stopPropagation()}
                onClick={(e) => {
                  e.stopPropagation();
                  onCommitCrop(null);
                }}
                title="点击还原完整画面（非破坏性裁切）"
                className="charkle-pressable inline-flex items-center gap-1 px-2 py-1 rounded-[var(--radius-card-inner)] bg-black/62 hover:bg-black/80 text-white text-[10px] font-medium cursor-pointer"
              >
                <Focus size={10} />
                局部取景 · 还原
              </button>
            ) : (
              <span />
            )}

            <button
              type="button"
              onPointerDown={(e) => e.stopPropagation()}
              onClick={(e) => {
                e.stopPropagation();
                onOpenQuickLook();
              }}
              aria-label="快速预览"
              title="快速预览 (Space)"
              className="charkle-pressable inline-flex items-center justify-center w-6 h-6 rounded-[var(--radius-card-inner)] bg-black/58 hover:bg-black/75 text-white cursor-pointer"
            >
              <Expand size={11} />
            </button>
          </div>
        </div>
      )}

      {/* Context Action Popover */}
      <Popover
        open={menuOpen}
        onOpenChange={setMenuOpen}
        anchorEl={menuPoint ? null : menuBtnRef.current}
        anchorPoint={menuPoint}
        placement="bottom-end"
        className="w-56 p-1.5"
      >
        <div className="flex flex-col text-[12px] text-[var(--text-primary)]">
          <MenuAction
            icon={<Expand size={13} />}
            label="快速预览 (Space)"
            onClick={() => {
              setMenuOpen(false);
              onOpenQuickLook();
            }}
          />
          <MenuAction
            icon={<ArrowLeftRight size={13} />}
            label="从候选池换一张…"
            onClick={() => {
              setMenuOpen(false);
              onTriggerSwap();
            }}
          />
          <MenuAction
            icon={<Crop size={13} />}
            label="手动框选裁切…"
            onClick={() => {
              setMenuOpen(false);
              onStartInlineCrop();
            }}
          />

          <div className="my-1 border-t border-[var(--border-hairline)]" />
          <div className="px-2 py-1 text-[10px] font-semibold uppercase tracking-wider text-[var(--text-tertiary)]">
            智能取景与标注 (Jev Box)
          </div>
          <MenuAction
            icon={<Focus size={13} />}
            label="聚焦画面主体"
            onClick={() => {
              setMenuOpen(false);
              onSmartFocusSubject();
            }}
          />
          <MenuAction
            icon={<Sparkles size={13} />}
            label="一句话语义裁切…"
            onClick={() => {
              setMenuOpen(false);
              onSemanticCropPrompt();
            }}
          />
          <MenuAction
            icon={<ImageIcon size={13} />}
            label="按参考图匹配区域…"
            onClick={() => {
              setMenuOpen(false);
              onVisualMatchCrop();
            }}
          />
          <MenuAction
            icon={<Scissors size={13} />}
            label="自动去杂边裁净"
            onClick={() => {
              setMenuOpen(false);
              onCleanContentCrop();
            }}
          />
          <MenuAction
            icon={<Crosshair size={13} />}
            label="指物精准批注…"
            onClick={() => {
              setMenuOpen(false);
              onPinpointAnnotate();
            }}
          />
          {hasCrop && (
            <MenuAction
              icon={<RotateCcw size={13} />}
              label="还原完整画面"
              onClick={() => {
                setMenuOpen(false);
                onCommitCrop(null);
              }}
            />
          )}

          <div className="my-1 border-t border-[var(--border-hairline)]" />
          <MenuAction
            icon={<RotateCw size={13} />}
            label="顺时针旋转 90° (R)"
            onClick={() => {
              setMenuOpen(false);
              onRotateBy(90);
            }}
          />
          <MenuAction
            icon={<FlipHorizontal2 size={13} />}
            label={node.flipHorizontal ? '取消水平翻转' : '水平翻转 (⇧H)'}
            onClick={() => {
              setMenuOpen(false);
              onFlipHorizontal();
            }}
          />
          <MenuAction
            icon={<FlipVertical2 size={13} />}
            label={node.flipVertical ? '取消上下翻转' : '上下翻转 (⇧V)'}
            onClick={() => {
              setMenuOpen(false);
              onFlipVertical();
            }}
          />
          <MenuAction
            icon={<Star size={13} />}
            label={weight >= 2 ? '取消主图 2× 权重' : '设为主图 2× 权重'}
            onClick={() => {
              setMenuOpen(false);
              onToggleHero();
            }}
          />
          <MenuAction
            icon={node.isLocked ? <Unlock size={13} /> : <Lock size={13} />}
            label={node.isLocked ? '解锁位置' : '锁定位置'}
            onClick={() => {
              setMenuOpen(false);
              onToggleLock();
            }}
          />

          <div className="my-1 border-t border-[var(--border-hairline)]" />
          <MenuAction
            icon={<Trash2 size={13} />}
            label="从情绪板移除"
            danger
            onClick={() => {
              setMenuOpen(false);
              onDelete();
            }}
          />
        </div>
      </Popover>
    </div>
  );
};

const MenuAction: React.FC<{
  icon: React.ReactNode;
  label: string;
  danger?: boolean;
  onClick: () => void;
}> = ({ icon, label, danger = false, onClick }) => (
  <button
    type="button"
    onClick={onClick}
    className={[
      'charkle-pressable flex items-center gap-2 w-full px-2.5 py-1.5 rounded-[var(--radius-popover-inner)] text-left cursor-pointer',
      danger
        ? 'text-[var(--danger)] hover:bg-[var(--danger-soft)]'
        : 'text-[var(--text-primary)] hover:bg-[var(--bg-subtle)]',
    ].join(' ')}
  >
    <span className="shrink-0 opacity-80">{icon}</span>
    <span className="truncate">{label}</span>
  </button>
);

// MARK: - 2. Editable Note Card Node View (5 Calm Themes)

export interface NoteNodeViewProps {
  node: BoardNode;
  isSelected: boolean;
  onUpdate: (title: string | null, text: string, style: NoteStyle, fontSize: number) => void;
  onDelete: () => void;
}

export const NoteNodeView: React.FC<NoteNodeViewProps> = ({
  node,
  isSelected,
  onUpdate,
  onDelete,
}) => {
  if (node.kind.type !== 'note') return null;
  const { title, text, style, fontSize } = node.kind;
  const theme = NOTE_STYLE_PALETTE[style];

  return (
    <div
      className="group/note relative w-full h-full rounded-[var(--radius-card-outer)] p-3.5 flex flex-col gap-2 overflow-hidden"
      style={{
        backgroundColor: theme.background,
        color: theme.foreground,
        boxShadow: isSelected
          ? '0 0 0 2.5px var(--accent), 0 8px 22px rgba(0,0,0,0.14)'
          : `0 0 0 1px ${theme.border}, 0 3px 10px rgba(0,0,0,0.06)`,
      }}
    >
      {/* Header row: Title + quick style/size/delete bar on hover or selection */}
      <div className="flex items-center gap-1.5 min-w-0">
        <input
          type="text"
          value={title ?? ''}
          placeholder="标题 / 氛围词"
          onPointerDown={(e) => e.stopPropagation()}
          onChange={(e) => onUpdate(e.target.value || null, text, style, fontSize)}
          className="flex-1 min-w-0 bg-transparent border-0 outline-none font-semibold placeholder:opacity-45"
          style={{
            fontSize: `${Math.max(13, fontSize)}px`,
            color: theme.foreground,
          }}
        />
        <div
          onPointerDown={(e) => e.stopPropagation()}
          className={[
            'flex items-center gap-1 shrink-0 transition-opacity duration-150',
            isSelected
              ? 'opacity-100'
              : 'opacity-0 group-hover/note:opacity-100 group-focus-within/note:opacity-100 [@media(hover:none)]:opacity-100',
          ].join(' ')}
        >
          {/* 5 Calm Style dots */}
          <div className="flex items-center gap-1 px-1 py-0.5 rounded-full bg-black/8">
            {NOTE_STYLES.map((s) => (
              <button
                key={s}
                type="button"
                title={NOTE_STYLE_PALETTE[s].label}
                aria-label={`便签主题 ${NOTE_STYLE_PALETTE[s].label}`}
                onClick={() => onUpdate(title ?? null, text, s, fontSize)}
                className="w-3.5 h-3.5 rounded-full cursor-pointer transition-transform duration-120 hover:scale-110"
                style={{
                  backgroundColor: NOTE_STYLE_PALETTE[s].background,
                  boxShadow:
                    s === style
                      ? '0 0 0 1.5px var(--accent)'
                      : 'inset 0 0 0 1px rgba(128,128,128,0.45)',
                }}
              />
            ))}
          </div>

          {/* Font size selector */}
          <select
            aria-label="便签字号"
            value={fontSize}
            onChange={(e) => onUpdate(title ?? null, text, style, Number(e.target.value))}
            className="text-[10.5px] font-medium rounded-[6px] px-1 py-0.5 bg-black/8 border-0 outline-none cursor-pointer"
            style={{ color: theme.foreground }}
          >
            {NOTE_FONT_SIZES.map((sz) => (
              <option key={sz} value={sz} className="text-black bg-white">
                {sz}px
              </option>
            ))}
          </select>

          <button
            type="button"
            onClick={onDelete}
            aria-label="删除便签"
            title="删除便签"
            className="charkle-pressable w-5 h-5 rounded-[6px] inline-flex items-center justify-center opacity-70 hover:opacity-100 hover:bg-black/10 cursor-pointer"
          >
            <Trash2 size={11} />
          </button>
        </div>
      </div>

      {/* Body textarea */}
      <textarea
        value={text}
        placeholder="写下材质笔记、构图意图或策展说明…"
        onPointerDown={(e) => e.stopPropagation()}
        onChange={(e) => onUpdate(title ?? null, e.target.value, style, fontSize)}
        className="flex-1 w-full resize-none bg-transparent border-0 outline-none leading-relaxed placeholder:opacity-40 charkle-scroll"
        style={{
          fontSize: `${fontSize}px`,
          color: theme.foreground,
        }}
      />
    </div>
  );
};

// MARK: - 3. Group Frame Node View (6 Calm Tints + Auto-Reflow)

export interface GroupFrameNodeViewProps {
  node: BoardNode;
  enclosedCount: number;
  isSelected: boolean;
  isAutoEditorial: boolean;
  onUpdate: (title: string, tint: GroupTint) => void;
  onAutoReflow: () => void;
  onDelete: () => void;
  onSideResizeStart?: (edge: 'w' | 'e', e: React.PointerEvent) => void;
}

export const GroupFrameNodeView: React.FC<GroupFrameNodeViewProps> = ({
  node,
  enclosedCount,
  isSelected,
  isAutoEditorial,
  onUpdate,
  onAutoReflow,
  onDelete,
  onSideResizeStart,
}) => {
  const isDark = useResolvedIsDark();
  if (node.kind.type !== 'groupFrame') return null;
  const { title, tint } = node.kind;
  const tokens = GROUP_TINT_PALETTE[tint];

  return (
    <div
      className="group/group relative w-full h-full rounded-[14px] flex flex-col select-none"
      style={{
        backgroundColor: isDark ? tokens.tintDark : tokens.tintLight,
        border: isSelected
          ? '2px solid var(--accent)'
          : `1.5px dashed ${isDark ? tokens.borderDark : tokens.borderLight}`,
      }}
    >
      {/* Header Bar (dragging this moves group + enclosed children) */}
      <div className="flex items-center justify-between gap-2 px-3 py-2 border-b border-[var(--border-hairline)]/60">
        <div className="flex items-center gap-2 min-w-0 flex-1">
          <span
            className="w-2.5 h-2.5 rounded-full shrink-0"
            style={{ backgroundColor: tokens.accent }}
          />
          <input
            type="text"
            value={title}
            placeholder="分区标题"
            onPointerDown={(e) => e.stopPropagation()}
            onChange={(e) => onUpdate(e.target.value, tint)}
            className="min-w-0 flex-1 bg-transparent border-0 outline-none text-[12.5px] font-semibold text-[var(--text-primary)] placeholder:text-[var(--text-tertiary)]"
          />
          {!isAutoEditorial && (
            <span className="text-[10.5px] font-medium px-1.5 py-0.5 rounded-full bg-[var(--bg-elevated)]/70 text-[var(--text-secondary)] shrink-0 tabular-nums">
              {enclosedCount} 项
            </span>
          )}
        </div>

        <div
          onPointerDown={(e) => e.stopPropagation()}
          className={[
            'flex items-center gap-1.5 shrink-0 transition-opacity duration-150',
            isSelected
              ? 'opacity-100'
              : 'opacity-0 group-hover/group:opacity-100 group-focus-within/group:opacity-100 [@media(hover:none)]:opacity-100',
          ].join(' ')}
        >
          {!isAutoEditorial && enclosedCount > 0 && (
            <button
              type="button"
              onClick={onAutoReflow}
              title="自适应排布框内全部素材"
              className="charkle-pressable inline-flex items-center gap-1 px-2 py-0.5 rounded-[var(--radius-chip)] bg-[var(--bg-elevated)] border border-[var(--border-hairline)] text-[10.5px] font-medium text-[var(--text-primary)] hover:border-[var(--border-strong)] cursor-pointer"
            >
              <LayoutGrid size={11} />
              自适应排布
            </button>
          )}

          {/* 6 Calm Tint dots */}
          <div className="flex items-center gap-1 px-1.5 py-0.5 rounded-full bg-[var(--bg-elevated)]/85 border border-[var(--border-hairline)]">
            {GROUP_TINTS.map((t) => (
              <button
                key={t}
                type="button"
                title={GROUP_TINT_PALETTE[t].label}
                aria-label={`分组色系 ${GROUP_TINT_PALETTE[t].label}`}
                onClick={() => onUpdate(title, t)}
                className="w-3 h-3 rounded-full cursor-pointer transition-transform duration-120 hover:scale-115"
                style={{
                  backgroundColor: GROUP_TINT_PALETTE[t].accent,
                  boxShadow: t === tint ? '0 0 0 1.5px var(--text-primary)' : undefined,
                }}
              />
            ))}
          </div>

          <button
            type="button"
            onClick={onDelete}
            aria-label="删除分组框"
            title="删除分组框（保留内部素材）"
            className="charkle-pressable w-5 h-5 rounded-[6px] inline-flex items-center justify-center text-[var(--text-secondary)] hover:text-[var(--danger)] hover:bg-[var(--danger-soft)] cursor-pointer"
          >
            <Trash2 size={11} />
          </button>
        </div>
      </div>

      {/* Live Side-Edge Auto-Reflow Capsules (Freeform mode) */}
      {!isAutoEditorial && !node.isLocked && onSideResizeStart && (
        <>
          <div
            onPointerDown={(e) => {
              e.stopPropagation();
              onSideResizeStart('w', e);
            }}
            title="拖动调整分组宽度并实时重排内部卡片"
            className="absolute left-[-5px] top-1/2 -translate-y-1/2 w-[8px] h-9 rounded-full bg-[var(--bg-elevated)] border border-[var(--border-strong)] shadow-xs opacity-0 group-hover/group:opacity-100 cursor-ew-resize transition-opacity duration-150"
            style={{ backgroundColor: isSelected ? tokens.accent : undefined }}
          />
          <div
            onPointerDown={(e) => {
              e.stopPropagation();
              onSideResizeStart('e', e);
            }}
            title="拖动调整分组宽度并实时重排内部卡片"
            className="absolute right-[-5px] top-1/2 -translate-y-1/2 w-[8px] h-9 rounded-full bg-[var(--bg-elevated)] border border-[var(--border-strong)] shadow-xs opacity-0 group-hover/group:opacity-100 cursor-ew-resize transition-opacity duration-150"
            style={{ backgroundColor: isSelected ? tokens.accent : undefined }}
          />
        </>
      )}
    </div>
  );
};

// MARK: - 4. Palette Strip Node View

export interface PaletteStripNodeViewProps {
  node: BoardNode;
  boardPalette: LabColor[];
  isSelected: boolean;
  onToggleAutoSync: () => void;
  onCopyHex: (hex: string) => void;
  onSearchColor: (hex: string) => void;
  onDelete: () => void;
}

export const PaletteStripNodeView: React.FC<PaletteStripNodeViewProps> = ({
  node,
  boardPalette,
  isSelected,
  onToggleAutoSync,
  onCopyHex,
  onSearchColor,
  onDelete,
}) => {
  const [copiedHex, setCopiedHex] = useState<string | null>(null);
  if (node.kind.type !== 'paletteStrip') return null;
  const colors =
    node.kind.autoSyncWithBoard && boardPalette.length > 0
      ? boardPalette
      : node.kind.colors;

  const handleCopy = (hex: string) => {
    const upper = hex.toUpperCase();
    onCopyHex(upper);
    setCopiedHex(upper);
    window.setTimeout(() => {
      setCopiedHex((cur) => (cur === upper ? null : cur));
    }, 1100);
  };

  return (
    <div
      className="group/palette relative w-full h-full rounded-[var(--radius-card-outer)] bg-[var(--bg-elevated)] px-3 py-2 flex items-center gap-2 overflow-hidden select-none"
      style={{
        boxShadow: isSelected
          ? '0 0 0 2.5px var(--accent), 0 8px 20px rgba(0,0,0,0.12)'
          : '0 0 0 1px var(--border-hairline), 0 2px 8px rgba(0,0,0,0.05)',
      }}
    >
      <CharkleIcon name="palette" size={15} className="shrink-0" />
      <div className="flex-1 flex items-center gap-1.5 h-full min-w-0 overflow-hidden">
        {colors.length > 0 ? (
          colors.slice(0, 7).map((c) => {
            const hex = c.hex.toUpperCase();
            const light = isLightHex(hex);
            return (
              <button
                key={hex}
                type="button"
                onPointerDown={(e) => e.stopPropagation()}
                onClick={(e) => {
                  e.stopPropagation();
                  handleCopy(hex);
                }}
                onContextMenu={(e) => {
                  e.preventDefault();
                  e.stopPropagation();
                  onSearchColor(hex);
                }}
                title={`点击复制 ${hex}，右键按此色筛选素材库`}
                className="charkle-pressable flex-1 min-w-[44px] h-full min-h-[30px] rounded-[var(--radius-card-inner)] flex items-end justify-center pb-1 px-1 cursor-pointer"
                style={{
                  backgroundColor: hex,
                  color: light ? 'rgba(24,25,28,0.82)' : 'rgba(255,255,255,0.92)',
                  boxShadow: light ? 'inset 0 0 0 1px rgba(0,0,0,0.12)' : undefined,
                }}
              >
                <span className="text-[9.5px] font-mono font-semibold tracking-tight truncate">
                  {copiedHex === hex ? '已复制' : hex}
                </span>
              </button>
            );
          })
        ) : (
          <span className="text-[11.5px] text-[var(--text-tertiary)]">
            添加图片到情绪板后将自动同步提取色卡
          </span>
        )}
      </div>

      {/* Controls on hover / selected */}
      <div
        onPointerDown={(e) => e.stopPropagation()}
        className={[
          'flex items-center gap-1 shrink-0 transition-opacity duration-150',
          isSelected
            ? 'opacity-100'
            : 'opacity-0 group-hover/palette:opacity-100 group-focus-within/palette:opacity-100 [@media(hover:none)]:opacity-100',
        ].join(' ')}
      >
        <button
          type="button"
          onClick={onToggleAutoSync}
          title={node.kind.autoSyncWithBoard ? '已开启自动同步画板色卡' : '点击开启自动同步'}
          className={[
            'charkle-pressable px-2 py-0.5 rounded-[var(--radius-chip)] text-[10.5px] font-medium border cursor-pointer',
            node.kind.autoSyncWithBoard
              ? 'bg-[var(--accent-soft)] text-[var(--accent)] border-[var(--accent-ring)]'
              : 'bg-[var(--bg-subtle)] text-[var(--text-secondary)] border-[var(--border-hairline)]',
          ].join(' ')}
        >
          {node.kind.autoSyncWithBoard ? '自动同步' : '已固定'}
        </button>
        <button
          type="button"
          onClick={onDelete}
          aria-label="删除色卡条"
          className="charkle-pressable w-6 h-6 rounded-[6px] inline-flex items-center justify-center text-[var(--text-secondary)] hover:text-[var(--danger)] hover:bg-[var(--danger-soft)] cursor-pointer"
        >
          <Trash2 size={12} />
        </button>
      </div>
    </div>
  );
};
