import React, { useEffect, useRef, useState } from 'react';
import {
  ArrowDownCircle,
  Columns3,
  Film,
  PanelRight,
  Plus,
  Rows2,
  Search,
  SlidersHorizontal,
  Sparkles,
  Star,
  Upload,
  X,
} from 'lucide-react';
import {
  ASPECT_SHAPES,
  aspectShapeLocalizedLabel,
  hasActiveVisualFilters,
  MEDIA_KINDS,
  mediaKindLocalizedLabel,
  SORT_ORDERS,
  sortOrderLocalizedLabel,
} from '@charkle/shared';
import type { AspectShape, GalleryLayoutMode, MediaKind, SortOrder } from '@charkle/shared';
import {
  Button,
  CharkleIcon,
  FILTER_PRESET_COLORS,
  GlassSurface,
} from '../../design-system';
import { useCoordinatorStore } from '../../stores/coordinatorStore';
import { useLibraryStore } from '../../stores/libraryStore';

export interface TopFilterCapsuleProps {
  destinationTitle: string;
  assetCount: number;
  onTriggerUpload: () => void;
}

export const TopFilterCapsule: React.FC<TopFilterCapsuleProps> = ({
  destinationTitle,
  assetCount,
  onTriggerUpload,
}) => {
  const layoutMode = useCoordinatorStore((s) => s.layoutMode);
  const setLayoutMode = useCoordinatorStore((s) => s.setLayoutMode);
  const targetColumnWidth = useCoordinatorStore((s) => s.targetColumnWidth);
  const setTargetColumnWidth = useCoordinatorStore((s) => s.setTargetColumnWidth);
  const inspectorOpen = useCoordinatorStore((s) => s.inspectorOpen);
  const toggleInspector = useCoordinatorStore((s) => s.toggleInspector);
  const openGeneratorModal = useCoordinatorStore((s) => s.openGeneratorModal);

  const criteria = useLibraryStore((s) => s.criteria);
  const setCriteria = useLibraryStore((s) => s.setCriteria);
  const resetVisualFilters = useLibraryStore((s) => s.resetVisualFilters);
  const showVisualFilterBar = useLibraryStore((s) => s.showVisualFilterBar);
  const setShowVisualFilterBar = useLibraryStore((s) => s.setShowVisualFilterBar);
  const semanticSearchEnabled = useLibraryStore((s) => s.semanticSearchEnabled);
  const setSemanticSearchEnabled = useLibraryStore((s) => s.setSemanticSearchEnabled);
  const semanticReport = useLibraryStore((s) => s.semanticReport);
  const isSemanticSearching = useLibraryStore((s) => s.isSemanticSearching);
  const runSemanticSearch = useLibraryStore((s) => s.runSemanticSearch);
  const clearSemanticSearch = useLibraryStore((s) => s.clearSemanticSearch);
  const selectedAssetIDs = useLibraryStore((s) => s.selectedAssetIDs);

  const [localQuery, setLocalQuery] = useState(criteria.searchQuery);
  const debounceRef = useRef<number | null>(null);

  useEffect(() => {
    setLocalQuery(criteria.searchQuery);
  }, [criteria.searchQuery]);

  const handleQueryChange = (val: string) => {
    setLocalQuery(val);
    if (debounceRef.current !== null) window.clearTimeout(debounceRef.current);
    if (!semanticSearchEnabled) {
      debounceRef.current = window.setTimeout(() => {
        setCriteria({ searchQuery: val });
      }, 180);
    } else if (!val.trim()) {
      clearSemanticSearch();
      setCriteria({ searchQuery: '' });
    }
  };

  const handleSearchKeyDown = (e: React.KeyboardEvent<HTMLInputElement>) => {
    if (e.key === 'Enter') {
      if (debounceRef.current !== null) window.clearTimeout(debounceRef.current);
      if (semanticSearchEnabled && localQuery.trim()) {
        setCriteria({ searchQuery: localQuery }, false);
        void runSemanticSearch(localQuery);
      } else {
        setCriteria({ searchQuery: localQuery });
      }
    } else if (e.key === 'Escape') {
      setLocalQuery('');
      clearSemanticSearch();
      setCriteria({ searchQuery: '' });
    }
  };

  const toggleKind = (kind: MediaKind) => {
    const exists = criteria.kinds.includes(kind);
    setCriteria({
      kinds: exists ? criteria.kinds.filter((k) => k !== kind) : [...criteria.kinds, kind],
    });
  };

  const toggleShape = (shape: AspectShape) => {
    setCriteria({ shape: criteria.shape === shape ? null : shape });
  };

  const activeFilterCount =
    criteria.kinds.length +
    (criteria.selectedColorHex ? 1 : 0) +
    (criteria.shape ? 1 : 0) +
    (criteria.minRating > 0 ? 1 : 0) +
    criteria.tags.length +
    (criteria.onlyPinnedOffline ? 1 : 0);

  const toleranceLabel =
    criteria.colorTolerance <= 18 ? '精确' : criteria.colorTolerance <= 34 ? '适中' : '宽松';

  const layoutOptions: ReadonlyArray<{ mode: GalleryLayoutMode; label: string; icon: React.ReactNode }> = [
    { mode: 'verticalMasonry', label: '纵向瀑布流', icon: <Columns3 size={14} /> },
    { mode: 'horizontalJustified', label: '横向瀑布流', icon: <Rows2 size={14} /> },
    { mode: 'galleryFilmstrip', label: '画廊视图', icon: <Film size={14} /> },
  ];

  return (
    <div className="sticky top-0 z-30 px-4 pt-1.5 pb-2 pointer-events-none">
      <div className="pointer-events-auto flex flex-col gap-2">
        {/* Main Floating Liquid Glass Bar */}
        <GlassSurface
          variant="regular"
          radius="dock"
          className="px-2.5 py-1.5 flex flex-nowrap items-center gap-1.5"
        >
          {/* Destination Title & Count */}
          <div className="flex items-baseline gap-1.5 pl-1 pr-1 min-w-0 shrink-0">
            <h1 className="text-[13.5px] font-semibold tracking-[-0.01em] text-[var(--text-primary)] truncate max-w-[116px]">
              {destinationTitle}
            </h1>
            <span className="text-[11px] tabular-nums text-[var(--text-tertiary)]">
              {assetCount}
            </span>
          </div>

          {/* Search Capsule + Hybrid Semantic Toggle */}
          <div className="flex-1 min-w-[140px] max-w-[420px] h-8 flex items-center gap-1.5 px-2.5 rounded-[var(--radius-dock-inner)] bg-[var(--bg-elevated)]/85 border border-[var(--border-hairline)] focus-within:border-[var(--accent)] focus-within:ring-2 focus-within:ring-[var(--accent-ring)]">
            <Search size={13.5} className="text-[var(--text-tertiary)] shrink-0" />
            <input
              type="text"
              value={localQuery}
              onChange={(e) => handleQueryChange(e.target.value)}
              onKeyDown={handleSearchKeyDown}
              placeholder={
                semanticSearchEnabled
                  ? '描述画面、情绪或材质，回车语义检索…'
                  : '搜索标题、标签、拼音、OCR…'
              }
              className="flex-1 min-w-0 bg-transparent text-[12.5px] text-[var(--text-primary)] placeholder:text-[var(--text-tertiary)] focus:outline-none"
            />
            {localQuery && (
              <button
                type="button"
                aria-label="清空搜索"
                onClick={() => {
                  setLocalQuery('');
                  clearSemanticSearch();
                  setCriteria({ searchQuery: '' });
                }}
                className="text-[var(--text-tertiary)] hover:text-[var(--text-primary)] cursor-pointer"
              >
                <X size={13} />
              </button>
            )}
            <button
              type="button"
              title="混合语义检索（FTS5 + 向量 + TypeSafe Jev 视觉重排）"
              onClick={() => {
                const next = !semanticSearchEnabled;
                setSemanticSearchEnabled(next);
                if (next && localQuery.trim()) {
                  void runSemanticSearch(localQuery);
                }
              }}
              className={[
                'charkle-pressable h-5.5 px-2 inline-flex items-center gap-1 rounded-full text-[11px] font-medium cursor-pointer shrink-0',
                semanticSearchEnabled
                  ? 'bg-[var(--accent)] text-white'
                  : 'bg-[var(--bg-subtle)] text-[var(--text-secondary)] hover:text-[var(--text-primary)]',
              ].join(' ')}
            >
              <Sparkles size={10} />
              {isSemanticSearching ? '检索中' : '语义'}
            </button>
          </div>

          {/* Filter Toggle */}
          <Button
            variant="ghost"
            size="xs"
            active={showVisualFilterBar || activeFilterCount > 0}
            onClick={() => setShowVisualFilterBar(!showVisualFilterBar)}
            title="视觉筛选器 (⇧⌘S)"
            className="px-2 gap-1 shrink-0"
          >
            <SlidersHorizontal size={13} />
            筛选
            {activeFilterCount > 0 && (
              <span className="px-1.5 py-0.25 rounded-full bg-[var(--accent)] text-white text-[10px] font-semibold leading-none">
                {activeFilterCount}
              </span>
            )}
          </Button>

          {/* Sort Select */}
          <select
            aria-label="排序方式"
            value={criteria.sortBy}
            onChange={(e) => setCriteria({ sortBy: e.target.value as SortOrder })}
            className="h-7 px-1.5 text-[12px] rounded-[var(--radius-chip)] bg-[var(--bg-subtle)]/80 border border-[var(--border-hairline)] text-[var(--text-primary)] focus:outline-none focus:border-[var(--accent)] cursor-pointer shrink-0"
          >
            {SORT_ORDERS.map((order) => (
              <option key={order} value={order}>
                {sortOrderLocalizedLabel(order)}
              </option>
            ))}
          </select>

          {/* 3-Mode Layout Switcher */}
          <div className="inline-flex items-center p-0.5 rounded-[var(--radius-chip)] bg-[var(--bg-subtle)]/85 border border-[var(--border-hairline)] shrink-0">
            {layoutOptions.map((opt) => {
              const active = layoutMode === opt.mode;
              return (
                <button
                  key={opt.mode}
                  type="button"
                  title={opt.label}
                  onClick={() => setLayoutMode(opt.mode)}
                  className={[
                    'charkle-pressable h-6 w-6 inline-flex items-center justify-center rounded-[6px] cursor-pointer',
                    active
                      ? 'bg-[var(--bg-elevated)] text-[var(--text-primary)] shadow-xs'
                      : 'text-[var(--text-secondary)] hover:text-[var(--text-primary)]',
                  ].join(' ')}
                >
                  {opt.icon}
                </button>
              );
            })}
          </div>

          {/* Card Density Slider (when not in Filmstrip; wide screens only to preserve crisp 1-row 1440px fit) */}
          {layoutMode !== 'galleryFilmstrip' && (
            <div className="hidden 2xl:flex items-center gap-1 px-0.5 shrink-0" title="调整瀑布流卡片尺寸">
              <input
                type="range"
                min={130}
                max={420}
                step={8}
                value={targetColumnWidth}
                onChange={(e) => setTargetColumnWidth(Number(e.target.value))}
                className="w-16 accent-[var(--accent)] cursor-pointer"
              />
            </div>
          )}

          {/* Right Quick Actions */}
          <div className="flex items-center gap-1 ml-auto shrink-0">
            <Button
              variant="secondary"
              size="xs"
              onClick={onTriggerUpload}
              title="上传本地文件至当前位置"
              className="px-2 gap-1"
            >
              <Upload size={13} />
              <span className="hidden sm:inline">导入</span>
            </Button>

            <Button
              variant="ghost"
              size="xs"
              onClick={() => openGeneratorModal(Array.from(selectedAssetIDs))}
              title="基于素材库或当前选中项生成情绪板"
              className="px-2 gap-1"
            >
              <CharkleIcon name="sparkle-board" size={15} />
              <span className="hidden 2xl:inline">情绪板</span>
            </Button>

            <Button
              variant="ghost"
              size="icon"
              active={inspectorOpen}
              onClick={toggleInspector}
              title="切换右侧检查器 (⌘I)"
              className="h-7 w-7"
            >
              <PanelRight size={15} />
            </Button>
          </div>
        </GlassSurface>

        {/* Semantic Search Status Banner */}
        {semanticReport && (
          <GlassSurface
            variant="regular"
            radius="chip"
            className="px-3.5 py-2 flex items-center justify-between gap-3 text-[12px]"
          >
            <div className="flex items-center gap-2 min-w-0">
              <Sparkles size={13} className="text-[var(--accent)] shrink-0" />
              <span className="text-[var(--text-primary)] font-medium truncate">
                {semanticReport.summary || `语义检索「${semanticReport.query}」命中 ${semanticReport.hits.length} 项`}
              </span>
              {semanticReport.evaluatedVisualCount > 0 && (
                <span className="text-[11px] text-[var(--text-tertiary)] shrink-0">
                  已视觉重排 {semanticReport.evaluatedVisualCount} 项
                </span>
              )}
            </div>
            <button
              type="button"
              onClick={clearSemanticSearch}
              className="charkle-pressable text-[12px] font-medium text-[var(--accent)] hover:underline shrink-0 cursor-pointer"
            >
              返回普通检索
            </button>
          </GlassSurface>
        )}

        {/* Expandable Visual Filter Bar */}
        {showVisualFilterBar && (
          <GlassSurface
            variant="regular"
            radius="settings"
            className="px-3.5 py-3 flex flex-col gap-2.5 charkle-popover-enter"
          >
            {/* Row 1: Media Kinds + Aspect Shape */}
            <div className="flex flex-wrap items-center gap-x-4 gap-y-2">
              <div className="flex flex-wrap items-center gap-1">
                <span className="text-[11px] font-semibold text-[var(--text-tertiary)] mr-1">
                  类型
                </span>
                {MEDIA_KINDS.map((kind) => {
                  const active = criteria.kinds.includes(kind);
                  return (
                    <button
                      key={kind}
                      type="button"
                      onClick={() => toggleKind(kind)}
                      className={[
                        'charkle-pressable px-2 py-0.5 text-[11.5px] rounded-[var(--radius-chip)] border cursor-pointer',
                        active
                          ? 'bg-[var(--accent-soft)] border-[var(--accent-ring)] text-[var(--accent)] font-medium'
                          : 'bg-[var(--bg-subtle)]/75 border-transparent text-[var(--text-secondary)] hover:text-[var(--text-primary)]',
                      ].join(' ')}
                    >
                      {mediaKindLocalizedLabel(kind)}
                    </button>
                  );
                })}
              </div>

              <div className="flex items-center gap-1">
                <span className="text-[11px] font-semibold text-[var(--text-tertiary)] mr-1">
                  构图
                </span>
                {ASPECT_SHAPES.map((shape) => {
                  const active = criteria.shape === shape;
                  return (
                    <button
                      key={shape}
                      type="button"
                      onClick={() => toggleShape(shape)}
                      className={[
                        'charkle-pressable px-2 py-0.5 text-[11.5px] rounded-[var(--radius-chip)] border cursor-pointer',
                        active
                          ? 'bg-[var(--accent-soft)] border-[var(--accent-ring)] text-[var(--accent)] font-medium'
                          : 'bg-[var(--bg-subtle)]/75 border-transparent text-[var(--text-secondary)] hover:text-[var(--text-primary)]',
                      ].join(' ')}
                    >
                      {aspectShapeLocalizedLabel(shape)}
                    </button>
                  );
                })}
              </div>
            </div>

            {/* Row 2: CIELAB Color Swatches + ΔE Tolerance + Rating + Offline + Clear */}
            <div className="flex flex-wrap items-center gap-x-4 gap-y-2 pt-1 border-t border-[var(--border-hairline)]">
              <div className="flex items-center gap-1.5 flex-wrap">
                <span className="text-[11px] font-semibold text-[var(--text-tertiary)] mr-0.5">
                  色彩
                </span>
                {FILTER_PRESET_COLORS.map((hex) => {
                  const active =
                    criteria.selectedColorHex?.toUpperCase() === hex.toUpperCase();
                  return (
                    <button
                      key={hex}
                      type="button"
                      title={hex}
                      onClick={() =>
                        setCriteria({ selectedColorHex: active ? null : hex })
                      }
                      className={[
                        'charkle-pressable h-5 w-5 rounded-full border border-black/15 cursor-pointer',
                        active
                          ? 'ring-2 ring-[var(--accent)] ring-offset-1 ring-offset-[var(--bg-elevated)]'
                          : '',
                      ].join(' ')}
                      style={{ backgroundColor: hex }}
                    />
                  );
                })}
                <label
                  title="自定义色板筛选"
                  className="charkle-pressable relative h-5 px-1.5 inline-flex items-center gap-0.5 rounded-full bg-[var(--bg-subtle)] text-[11px] text-[var(--text-secondary)] cursor-pointer"
                >
                  <Plus size={10} />
                  选色
                  <input
                    type="color"
                    value={criteria.selectedColorHex ?? '#4E7D96'}
                    onChange={(e) => setCriteria({ selectedColorHex: e.target.value.toUpperCase() })}
                    className="opacity-0 absolute inset-0 w-full h-full cursor-pointer"
                  />
                </label>

                {criteria.selectedColorHex && (
                  <div className="flex items-center gap-1.5 ml-1">
                    <input
                      type="range"
                      min={10}
                      max={55}
                      step={1}
                      value={criteria.colorTolerance}
                      onChange={(e) => setCriteria({ colorTolerance: Number(e.target.value) })}
                      className="w-20 accent-[var(--accent)] cursor-pointer"
                    />
                    <span className="text-[11px] text-[var(--text-secondary)] tabular-nums">
                      ΔE {Math.round(criteria.colorTolerance)} ({toleranceLabel})
                    </span>
                  </div>
                )}
              </div>

              {/* Min Rating */}
              <div className="flex items-center gap-0.5">
                <span className="text-[11px] font-semibold text-[var(--text-tertiary)] mr-1">
                  评分
                </span>
                {[1, 2, 3, 4, 5].map((star) => {
                  const active = criteria.minRating >= star;
                  return (
                    <button
                      key={star}
                      type="button"
                      onClick={() =>
                        setCriteria({ minRating: criteria.minRating === star ? 0 : star })
                      }
                      className="charkle-pressable p-0.5 cursor-pointer"
                    >
                      <Star
                        size={14}
                        className={
                          active
                            ? 'fill-[#F2C14E] text-[#F2C14E]'
                            : 'text-[var(--text-tertiary)]'
                        }
                      />
                    </button>
                  );
                })}
              </div>

              {/* Pinned Offline */}
              <button
                type="button"
                onClick={() => setCriteria({ onlyPinnedOffline: !criteria.onlyPinnedOffline })}
                className={[
                  'charkle-pressable inline-flex items-center gap-1 px-2 py-0.5 rounded-[var(--radius-chip)] text-[11.5px] border cursor-pointer',
                  criteria.onlyPinnedOffline
                    ? 'bg-[var(--accent-soft)] border-[var(--accent-ring)] text-[var(--accent)] font-medium'
                    : 'bg-[var(--bg-subtle)]/75 border-transparent text-[var(--text-secondary)]',
                ].join(' ')}
              >
                <ArrowDownCircle size={12} />
                已保留在本地
              </button>

              {/* Active Tag Filters */}
              {criteria.tags.map((tag) => (
                <span
                  key={tag}
                  className="inline-flex items-center gap-1 px-2 py-0.5 rounded-[var(--radius-chip)] bg-[var(--accent-soft)] text-[var(--accent)] text-[11.5px]"
                >
                  #{tag}
                  <button
                    type="button"
                    onClick={() =>
                      setCriteria({ tags: criteria.tags.filter((t) => t !== tag) })
                    }
                    className="cursor-pointer"
                  >
                    <X size={10} />
                  </button>
                </span>
              ))}

              {hasActiveVisualFilters(criteria) && (
                <button
                  type="button"
                  onClick={resetVisualFilters}
                  className="ml-auto text-[11.5px] font-medium text-[var(--text-secondary)] hover:text-[var(--danger)] cursor-pointer"
                >
                  清空筛选
                </button>
              )}
            </div>
          </GlassSurface>
        )}
      </div>
    </div>
  );
};
