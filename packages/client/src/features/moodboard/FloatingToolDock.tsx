import React from 'react';
import {
  ArrowDownToLine,
  ArrowUpToLine,
  Eraser,
  FlipHorizontal2,
  FlipVertical2,
  Hand,
  Lock,
  Maximize2,
  Minus,
  MousePointer2,
  Plus,
  Redo2,
  RotateCcw,
  RotateCw,
  Trash2,
  Undo2,
  Unlock,
} from 'lucide-react';
import { CharkleIcon } from '../../design-system/CharkleIcon';
import { GlassSurface } from '../../design-system/GlassSurface';
import type { MoodboardTool } from './geometry';

// MARK: - Bottom-Center Liquid Glass Floating Tool Dock

export interface FloatingToolDockProps {
  isAutoEditorial: boolean;
  activeTool: MoodboardTool;
  canUndo: boolean;
  canRedo: boolean;
  onSelectTool: (tool: MoodboardTool) => void;
  onAddNote: () => void;
  onAddGroupFrame: () => void;
  onAddPaletteStrip: () => void;
  onSwitchMode: (mode: 'autoEditorial' | 'freeform') => void;
  onUndo: () => void;
  onRedo: () => void;
  onOpenExport: () => void;
}

export const FloatingToolDock: React.FC<FloatingToolDockProps> = ({
  isAutoEditorial,
  activeTool,
  canUndo,
  canRedo,
  onSelectTool,
  onAddNote,
  onAddGroupFrame,
  onAddPaletteStrip,
  onSwitchMode,
  onUndo,
  onRedo,
  onOpenExport,
}) => {
  return (
    <GlassSurface
      variant="regular"
      radius="dock"
      className="inline-flex items-center gap-1 p-2 max-w-[96vw] overflow-x-auto charkle-scroll"
      role="toolbar"
      aria-label="情绪板画布工具栏"
    >
      {/* Pointer / Canvas Tools */}
      <DockIconButton
        label="选择 (V)"
        active={activeTool === 'select'}
        onClick={() => onSelectTool('select')}
      >
        <MousePointer2 size={15} />
      </DockIconButton>

      {!isAutoEditorial && (
        <DockIconButton
          label="抓手平移 (H / Space)"
          active={activeTool === 'pan'}
          onClick={() => onSelectTool('pan')}
        >
          <Hand size={15} />
        </DockIconButton>
      )}

      <span className="w-px h-5 bg-[var(--border-hairline)] mx-0.5 shrink-0" />

      {/* Insert Nodes */}
      <DockIconButton label="添加便签" onClick={onAddNote}>
        <CharkleIcon name="note" size={16} />
      </DockIconButton>
      <DockIconButton label="添加分组框" onClick={onAddGroupFrame}>
        <CharkleIcon name="group-frame" size={16} />
      </DockIconButton>
      <DockIconButton
        label="箭头连线 (C)"
        active={!isAutoEditorial && activeTool === 'connector'}
        onClick={() => {
          if (isAutoEditorial) onSwitchMode('freeform');
          onSelectTool('connector');
        }}
      >
        <CharkleIcon name="connector" size={16} isActive={!isAutoEditorial && activeTool === 'connector'} />
      </DockIconButton>
      <DockIconButton
        label="手绘标注 (P)"
        active={!isAutoEditorial && activeTool === 'pen'}
        onClick={() => {
          if (isAutoEditorial) onSwitchMode('freeform');
          onSelectTool('pen');
        }}
      >
        <CharkleIcon name="ink-pen" size={16} isActive={!isAutoEditorial && activeTool === 'pen'} />
      </DockIconButton>
      {!isAutoEditorial && (
        <DockIconButton
          label="橡皮擦 (E)"
          active={activeTool === 'eraser'}
          onClick={() => onSelectTool('eraser')}
        >
          <Eraser size={15} />
        </DockIconButton>
      )}
      <DockIconButton label="添加板内色卡条" onClick={onAddPaletteStrip}>
        <CharkleIcon name="palette" size={16} />
      </DockIconButton>

      <span className="w-px h-5 bg-[var(--border-hairline)] mx-0.5 shrink-0" />

      {/* Auto Editorial <-> Freeform Segmented Switcher (Kubai 015 Travelling Pill) */}
      <div
        className="relative inline-grid grid-cols-2 items-center p-0.5 rounded-[var(--radius-dock-inner)] bg-[var(--bg-subtle)]/90 border border-[var(--border-hairline)] shrink-0"
        role="tablist"
        aria-label="画布排版模式"
      >
        <span
          aria-hidden="true"
          className="absolute top-0.5 bottom-0.5 left-0.5 w-[calc(50%-2px)] rounded-[10px] bg-[var(--bg-elevated)] shadow-xs transition-transform duration-[260ms]"
          style={{
            transitionTimingFunction: 'var(--ease-in-out)',
            transform: isAutoEditorial ? 'translateX(0)' : 'translateX(100%)',
          }}
        />
        <button
          type="button"
          role="tab"
          aria-selected={isAutoEditorial}
          onClick={() => onSwitchMode('autoEditorial')}
          className={[
            'relative z-10 inline-flex items-center justify-center gap-1.5 px-2.5 py-1 text-[11.5px] font-medium cursor-pointer transition-colors duration-150',
            isAutoEditorial ? 'text-[var(--text-primary)]' : 'text-[var(--text-secondary)]',
          ].join(' ')}
        >
          <CharkleIcon name="auto-layout" size={13} isActive={isAutoEditorial} />
          自动排版
        </button>
        <button
          type="button"
          role="tab"
          aria-selected={!isAutoEditorial}
          onClick={() => onSwitchMode('freeform')}
          className={[
            'relative z-10 inline-flex items-center justify-center gap-1.5 px-2.5 py-1 text-[11.5px] font-medium cursor-pointer transition-colors duration-150',
            !isAutoEditorial ? 'text-[var(--text-primary)]' : 'text-[var(--text-secondary)]',
          ].join(' ')}
        >
          <CharkleIcon name="freeform" size={13} isActive={!isAutoEditorial} />
          自由画布
        </button>
      </div>

      <span className="w-px h-5 bg-[var(--border-hairline)] mx-0.5 shrink-0" />

      {/* Undo / Redo */}
      <DockIconButton label="撤销 (⌘Z)" disabled={!canUndo} onClick={onUndo}>
        <Undo2 size={15} />
      </DockIconButton>
      <DockIconButton label="重做 (⇧⌘Z)" disabled={!canRedo} onClick={onRedo}>
        <Redo2 size={15} />
      </DockIconButton>

      <span className="w-px h-5 bg-[var(--border-hairline)] mx-0.5 shrink-0" />

      {/* Export CTA */}
      <button
        type="button"
        onClick={onOpenExport}
        className="charkle-pressable inline-flex items-center gap-1.5 h-8 px-3 rounded-[var(--radius-dock-inner)] bg-[var(--accent)] hover:bg-[var(--accent-hover)] text-white text-[12px] font-medium cursor-pointer shrink-0"
      >
        <CharkleIcon name="export" size={14} tintHex="#FFFFFF" />
        导出
      </button>
    </GlassSurface>
  );
};

const DockIconButton: React.FC<{
  label: string;
  active?: boolean;
  disabled?: boolean;
  onClick: () => void;
  children: React.ReactNode;
}> = ({ label, active = false, disabled = false, onClick, children }) => (
  <button
    type="button"
    title={label}
    aria-label={label}
    aria-pressed={active || undefined}
    disabled={disabled}
    onClick={onClick}
    className={[
      'charkle-pressable h-8 w-8 inline-flex items-center justify-center rounded-[var(--radius-dock-inner)] shrink-0 cursor-pointer',
      'focus-visible:outline-2 focus-visible:outline-offset-1 focus-visible:outline-[var(--accent)]',
      'disabled:opacity-35 disabled:cursor-not-allowed',
      active
        ? 'bg-[var(--accent-soft)] text-[var(--accent)] shadow-[inset_0_0_0_1px_var(--accent-ring)]'
        : 'text-[var(--text-secondary)] hover:text-[var(--text-primary)] hover:bg-[var(--bg-subtle)]/80',
    ].join(' ')}
  >
    {children}
  </button>
);

// MARK: - Selected Node Transform Bar (Floats Above Tool Dock)

export interface SelectedTransformBarProps {
  selectedCount: number;
  allLocked: boolean;
  hasCroppedAsset: boolean;
  onRotateCCW: () => void;
  onRotateCW: () => void;
  onFlipH: () => void;
  onFlipV: () => void;
  onBringForward: () => void;
  onSendBackward: () => void;
  onToggleLock: () => void;
  onResetCrop: () => void;
  onDelete: () => void;
}

export const SelectedTransformBar: React.FC<SelectedTransformBarProps> = ({
  selectedCount,
  allLocked,
  hasCroppedAsset,
  onRotateCCW,
  onRotateCW,
  onFlipH,
  onFlipV,
  onBringForward,
  onSendBackward,
  onToggleLock,
  onResetCrop,
  onDelete,
}) => {
  return (
    <GlassSurface
      variant="regular"
      radius="pill"
      className="inline-flex items-center gap-1 px-2.5 py-1 charkle-popover-enter"
      style={{ transformOrigin: 'bottom center' }}
    >
      <span className="text-[11px] font-medium text-[var(--text-secondary)] px-1.5 tabular-nums">
        已选 {selectedCount} 项
      </span>
      <span className="w-px h-3.5 bg-[var(--border-hairline)]" />

      <MiniToolBtn title="逆时针旋转 90° (⇧R)" onClick={onRotateCCW}>
        <RotateCcw size={13} />
      </MiniToolBtn>
      <MiniToolBtn title="顺时针旋转 90° (R)" onClick={onRotateCW}>
        <RotateCw size={13} />
      </MiniToolBtn>
      <MiniToolBtn title="水平翻转 (⇧H)" onClick={onFlipH}>
        <FlipHorizontal2 size={13} />
      </MiniToolBtn>
      <MiniToolBtn title="上下翻转 (⇧V)" onClick={onFlipV}>
        <FlipVertical2 size={13} />
      </MiniToolBtn>

      <span className="w-px h-3.5 bg-[var(--border-hairline)]" />

      <MiniToolBtn title="置于顶层" onClick={onBringForward}>
        <ArrowUpToLine size={13} />
      </MiniToolBtn>
      <MiniToolBtn title="置于底层" onClick={onSendBackward}>
        <ArrowDownToLine size={13} />
      </MiniToolBtn>
      <MiniToolBtn title={allLocked ? '解锁' : '锁定位置'} active={allLocked} onClick={onToggleLock}>
        {allLocked ? <Lock size={13} /> : <Unlock size={13} />}
      </MiniToolBtn>

      {hasCroppedAsset && (
        <>
          <span className="w-px h-3.5 bg-[var(--border-hairline)]" />
          <button
            type="button"
            onClick={onResetCrop}
            className="charkle-pressable px-2 py-0.5 rounded-full text-[11px] font-medium text-[var(--text-primary)] hover:bg-[var(--bg-subtle)] cursor-pointer"
          >
            还原裁切
          </button>
        </>
      )}

      <span className="w-px h-3.5 bg-[var(--border-hairline)]" />

      <MiniToolBtn title="移除选中项 (Delete)" danger onClick={onDelete}>
        <Trash2 size={13} />
      </MiniToolBtn>
    </GlassSurface>
  );
};

const MiniToolBtn: React.FC<{
  title: string;
  active?: boolean;
  danger?: boolean;
  onClick: () => void;
  children: React.ReactNode;
}> = ({ title, active, danger, onClick, children }) => (
  <button
    type="button"
    title={title}
    aria-label={title}
    onClick={onClick}
    className={[
      'charkle-pressable w-7 h-7 rounded-full inline-flex items-center justify-center cursor-pointer',
      danger
        ? 'text-[var(--danger)] hover:bg-[var(--danger-soft)]'
        : active
          ? 'bg-[var(--accent-soft)] text-[var(--accent)]'
          : 'text-[var(--text-secondary)] hover:text-[var(--text-primary)] hover:bg-[var(--bg-subtle)]',
    ].join(' ')}
  >
    {children}
  </button>
);

// MARK: - Bottom-Right Freeform Zoom Controls Pill

export interface FreeformZoomControlsProps {
  zoom: number;
  onZoomOut: () => void;
  onZoomIn: () => void;
  onResetZoom: () => void;
  onFitBoard: () => void;
}

export const FreeformZoomControls: React.FC<FreeformZoomControlsProps> = ({
  zoom,
  onZoomOut,
  onZoomIn,
  onResetZoom,
  onFitBoard,
}) => (
  <GlassSurface
    variant="regular"
    radius="pill"
    className="inline-flex items-center gap-0.5 px-1.5 py-1"
  >
    <MiniToolBtn title="缩小" onClick={onZoomOut}>
      <Minus size={13} />
    </MiniToolBtn>
    <button
      type="button"
      onClick={onResetZoom}
      title="点击重置为 100%"
      className="charkle-pressable px-2 h-7 rounded-full text-[11.5px] font-mono font-medium text-[var(--text-primary)] hover:bg-[var(--bg-subtle)] tabular-nums cursor-pointer"
    >
      {Math.round(zoom * 100)}%
    </button>
    <MiniToolBtn title="放大" onClick={onZoomIn}>
      <Plus size={13} />
    </MiniToolBtn>
    <span className="w-px h-3.5 bg-[var(--border-hairline)] mx-0.5" />
    <MiniToolBtn title="适配全部内容 (Fit)" onClick={onFitBoard}>
      <Maximize2 size={12} />
    </MiniToolBtn>
  </GlassSurface>
);
