import React, { useEffect, useRef, useState } from 'react';
import {
  ArrowDownCircle,
  ArrowUpDown,
  Grid2x2,
  Grid3x3,
  PanelRight,
  Sparkles,
  Star,
  X,
} from 'lucide-react';
import {
  CharkleIcon,
  CharkleSlider,
  CustomSelect,
  FILTER_PRESET_COLORS,
  type SelectOption,
} from '../../design-system';
import {
  useCoordinatorStore,
  useLibraryStore,
} from '../../stores';
import {
  mediaKindLabel,
  type AspectShape,
  type FilterCriteria,
  type GalleryLayoutMode,
  type MediaKind,
  type SortOrder,
} from '../../types/domain';
import { steppedColumnWidth } from './masonryLayout';

const ALL_MEDIA_KINDS: MediaKind[] = [
  'image',
  'animatedImage',
  'video',
  'audio',
  'document',
  'webBookmark',
  'designFile',
  'model3D',
];

const ASPECT_SHAPES: ReadonlyArray<{ value: AspectShape; label: string }> = [
  { value: 'landscape', label: '横图' },
  { value: 'portrait', label: '竖图' },
  { value: 'square', label: '方图' },
  { value: 'ultrawide', label: '超宽' },
];

const SORT_OPTIONS: ReadonlyArray<SelectOption<SortOrder>> = [
  { value: 'newest', label: '最新导入' },
  { value: 'oldest', label: '最早导入' },
  { value: 'nameAsc', label: '名称排序' },
  { value: 'ratingDesc', label: '评分优先' },
  { value: 'fileSizeDesc', label: '文件大小' },
  { value: 'relevance', label: '相关度优先' },
];

function toleranceLabel(val: number): string {
  if (val <= 18) return '精确';
  if (val <= 34) return '适中';
  return '宽松';
}

function countVisualFiltersOnly(criteria: FilterCriteria): number {
  let count = 0;
  if (criteria.kinds.length > 0) count += 1;
  if (criteria.selectedColorHex) count += 1;
  if (criteria.shape) count += 1;
  if (criteria.minRating > 0) count += 1;
  if (criteria.tags.length > 0) count += 1;
  if (criteria.onlyPinnedOffline) count += 1;
  return count;
}

export interface TopFilterCapsuleProps {
  /** Measured gallery viewport width for exact 1-column / 1-stop +/- zoom stepping. */
  galleryViewportWidth?: number;
}

/**
 * Floating Liquid Glass Top Control Bar matching macOS `MainWindowView.swift`:
 * - Individual `.charkle-glass rounded-full` capsules floating directly over scrolling gallery artwork
 * - Transparent search input with inline semantic toggle pill inside the search capsule
 * - Filter toggle pill, Sort picker glass pill, 3-mode duotone layout switcher pill,
 *   density slider pill (exact 1-column/1-stop +/- stepping), quick moodboard CTA pill, and Inspector circle
 * - Expandable `.charkle-glass` visual & color filter bar
 */
export const TopFilterCapsule: React.FC<TopFilterCapsuleProps> = ({
  galleryViewportWidth = 960,
}) => {
  const destination = useCoordinatorStore((s) => s.destination);
  const layoutMode = useCoordinatorStore((s) => s.layoutMode);
  const setLayoutMode = useCoordinatorStore((s) => s.setLayoutMode);
  const cardScale = useCoordinatorStore((s) => s.cardScale);
  const setCardScale = useCoordinatorStore((s) => s.setCardScale);
  const filterOpen = useCoordinatorStore((s) => s.visualFilterBarOpen);
  const toggleFilterOpen = useCoordinatorStore((s) => s.toggleVisualFilterBar);
  const inspectorOpen = useCoordinatorStore((s) => s.inspectorOpen);
  const toggleInspector = useCoordinatorStore((s) => s.toggleInspector);
  const setMoodboardGeneratorOpen = useCoordinatorStore((s) => s.setMoodboardGeneratorOpen);
  const pushToast = useCoordinatorStore((s) => s.pushToast);

  const criteria = useLibraryStore((s) => s.criteria);
  const tagCounts = useLibraryStore((s) => s.tagCounts);
  const semanticSearch = useLibraryStore((s) => s.semanticSearch);
  const setSemanticSearch = useLibraryStore((s) => s.setSemanticSearch);
  const setCriteria = useLibraryStore((s) => s.setCriteria);
  const clearVisualFilters = useLibraryStore((s) => s.clearVisualFilters);

  const [searchDraft, setSearchDraft] = useState(criteria.searchQuery);

  useEffect(() => {
    setSearchDraft(criteria.searchQuery);
  }, [criteria.searchQuery]);

  useEffect(() => {
    if (searchDraft === criteria.searchQuery) return;
    if (semanticSearch && searchDraft.trim().length > 0) return;
    const timer = window.setTimeout(() => {
      void setCriteria({ searchQuery: searchDraft }, destination);
    }, 120);
    return () => window.clearTimeout(timer);
  }, [searchDraft, criteria.searchQuery, semanticSearch, destination, setCriteria]);

  const visualFilterCount = countVisualFiltersOnly(criteria);
  const usableWidth = Math.max(240, galleryViewportWidth - 32);

  const toggleKind = (kind: MediaKind) => {
    const next = criteria.kinds.includes(kind)
      ? criteria.kinds.filter((k) => k !== kind)
      : [...criteria.kinds, kind];
    void setCriteria({ kinds: next }, destination);
  };

  const toggleTag = (tag: string) => {
    const next = criteria.tags.includes(tag)
      ? criteria.tags.filter((t) => t !== tag)
      : [...criteria.tags, tag];
    void setCriteria({ tags: next }, destination);
  };

  const commitSemanticQuery = () => {
    const trimmed = searchDraft.trim();
    if (!trimmed) return;
    void setCriteria({ searchQuery: trimmed, sortBy: 'relevance' }, destination);
  };

  const handleToggleSemantic = () => {
    const trimmed = searchDraft.trim();
    if (semanticSearch && !trimmed) {
      setSemanticSearch(false);
      if (criteria.sortBy === 'relevance') {
        void setCriteria({ sortBy: 'newest' }, destination);
      }
      return;
    }
    const next = !semanticSearch;
    setSemanticSearch(next);
    if (next) {
      if (trimmed) {
        void setCriteria({ searchQuery: trimmed, sortBy: 'relevance' }, destination);
      } else {
        pushToast({
          message: '已开启语义搜图模式：输入描述后按回车检索',
          tone: 'info',
        });
      }
    } else {
      void setCriteria(
        {
          searchQuery: searchDraft,
          sortBy: criteria.sortBy === 'relevance' ? 'newest' : criteria.sortBy,
        },
        destination,
      );
    }
  };

  const barRef = useRef<HTMLDivElement | null>(null);
  const [measuredWidth, setMeasuredWidth] = useState(0);

  useEffect(() => {
    const el = barRef.current;
    if (!el || typeof ResizeObserver === 'undefined') return;
    const sync = () => {
      const w = Math.round(el.getBoundingClientRect().width);
      if (w > 0) setMeasuredWidth(w);
    };
    sync();
    const ro = new ResizeObserver(sync);
    ro.observe(el);
    return () => ro.disconnect();
  }, []);

  const effectiveWidth = measuredWidth > 0 ? measuredWidth : galleryViewportWidth;

  const layoutModes: ReadonlyArray<{
    mode: GalleryLayoutMode;
    icon: string;
    title: string;
    ariaLabel: string;
  }> = [
    {
      mode: 'verticalMasonry',
      icon: 'masonry-vertical',
      title: '纵向瀑布流 (Ctrl+1)',
      ariaLabel: '纵向瀑布流',
    },
    {
      mode: 'horizontalJustified',
      icon: 'masonry-horizontal',
      title: '横向等高瀑布流 (Ctrl+2)',
      ariaLabel: '横向等高瀑布流',
    },
    {
      mode: 'galleryFilmstrip',
      icon: 'quicklook',
      title: '画廊视图（底部胶片挑图）(Ctrl+3)',
      ariaLabel: '画廊视图',
    },
    {
      mode: 'ringGallery',
      icon: 'gallery-ring',
      title: '环形画廊（3D 弧形浏览）(Ctrl+4)',
      ariaLabel: '环形画廊',
    },
  ];

  // Progressive narrow top-bar collapse (Pitfall 3): full -> hide button labels -> compact search & hide secondary density slider
  const supportsDensity = layoutMode !== 'galleryFilmstrip' && layoutMode !== 'ringGallery';
  const showDensitySlider = supportsDensity && (effectiveWidth <= 0 || effectiveWidth >= 580);
  const showFilterLabel = effectiveWidth <= 0 || effectiveWidth >= 660;
  const showFullMoodboardLabel = effectiveWidth <= 0 || effectiveWidth >= 860;
  const showCompactMoodboardLabel = !showFullMoodboardLabel && effectiveWidth >= 700;
  const showSemanticLabel = effectiveWidth <= 0 || effectiveWidth >= 520;
  const compactSearch = effectiveWidth > 0 && effectiveWidth < 940;

  return (
    <div ref={barRef} className="pointer-events-none flex flex-col gap-2">
      {/* Row 1: Individual Floating Liquid Glass Capsules */}
      <div className="pointer-events-none flex items-center gap-2 flex-nowrap">
        {/* 1. Search Capsule (transparent input + inline semantic toggle pill) */}
        <div
          data-pill="true"
          data-adapt-glass="true"
          className="pointer-events-auto charkle-glass charkle-search-capsule rounded-full h-[34px] px-3 flex items-center gap-1.5 flex-[2_1_172px] min-w-[132px] max-w-[300px] focus-within:ring-1 focus-within:ring-[var(--accent)]"
        >
          <CharkleIcon
            name="search"
            style="duotone"
            size={16}
            isActive={semanticSearch}
            className="shrink-0"
          />
          <input
            type="text"
            value={searchDraft}
            onChange={(e) => setSearchDraft(e.target.value)}
            onKeyDown={(e) => {
              if (e.key === 'Enter' && semanticSearch) {
                e.preventDefault();
                commitSemanticQuery();
              }
            }}
            placeholder={
              semanticSearch
                ? compactSearch
                  ? '语义搜图，回车…'
                  : '自然语言语义搜图，回车检索…'
                : compactSearch
                  ? '搜索素材…'
                  : '搜索素材、标签或文字…'
            }
            aria-label="搜索素材"
            className="w-full min-w-0 pr-1 bg-transparent text-[12.5px] text-[var(--text-primary)] placeholder:text-[var(--text-tertiary)] outline-none"
          />
          {searchDraft && (
            <button
              type="button"
              aria-label="清空搜索"
              onClick={() => {
                setSearchDraft('');
                void setCriteria({ searchQuery: '' }, destination);
              }}
              className="text-[var(--text-tertiary)] hover:text-[var(--text-primary)] cursor-pointer shrink-0 inline-flex items-center justify-center"
            >
              <X size={12.5} />
            </button>
          )}
          <button
            type="button"
            aria-pressed={semanticSearch}
            aria-label="语义搜图"
            title="开启或关闭语义搜图（结合画面内容与文字语义）"
            onClick={handleToggleSemantic}
            data-pill="true"
            className={[
              'charkle-pressable h-[22px] inline-flex items-center justify-center gap-1 rounded-full text-[10.5px] font-semibold cursor-pointer shrink-0 whitespace-nowrap',
              showSemanticLabel ? 'px-2' : 'w-[22px]',
              semanticSearch
                ? 'bg-[var(--accent)] text-white'
                : 'bg-[var(--accent-soft)] text-[var(--accent)] hover:bg-[var(--accent)]/18',
            ].join(' ')}
          >
            <Sparkles size={10.5} />
            {showSemanticLabel && <span>语义</span>}
          </button>
        </div>

        {/* 2. Visual Filter Toggle Pill */}
        <button
          type="button"
          aria-expanded={filterOpen}
          aria-label="筛选"
          title="展开视觉与色彩筛选条 (Ctrl+Shift+S)"
          onClick={toggleFilterOpen}
          data-pill="true"
          data-adapt-glass="true"
          className={[
            'pointer-events-auto charkle-pressable charkle-glass rounded-full h-[34px] inline-flex items-center justify-center gap-1.5 text-[12px] font-medium text-[var(--text-primary)] cursor-pointer shrink-0 whitespace-nowrap',
            showFilterLabel ? 'px-3' : 'w-[34px]',
          ].join(' ')}
        >
          <CharkleIcon
            name="filter"
            style="duotone"
            size={16}
            isActive={filterOpen || visualFilterCount > 0}
          />
          {showFilterLabel && <span>筛选</span>}
          {visualFilterCount > 0 && (
            <span
              aria-label={`已启用 ${visualFilterCount} 项筛选`}
              className="h-[6px] w-[6px] rounded-full bg-[var(--accent)] shrink-0"
            />
          )}
        </button>

        {/* 3. Sort Picker Pill */}
        <div className="pointer-events-auto shrink-0">
          <CustomSelect<SortOrder>
            value={criteria.sortBy}
            options={SORT_OPTIONS}
            onChange={(sortBy) => void setCriteria({ sortBy }, destination)}
            ariaLabel="排序方式"
            variant="glassPill"
            adaptGlass
            hideChevron
            leadingIcon={
              <ArrowUpDown size={11.5} className="text-[var(--text-secondary)] shrink-0" />
            }
          />
        </div>

        {/* 4. 3-Mode Gallery View Switcher Pill */}
        <div
          role="radiogroup"
          aria-label="画廊布局模式"
          data-pill="true"
          data-adapt-glass="true"
          className="pointer-events-auto charkle-glass rounded-full h-[34px] px-1 inline-flex items-center gap-0.5 shrink-0 select-none"
        >
          {layoutModes.map((item) => {
            const active = layoutMode === item.mode;
            return (
              <button
                key={item.mode}
                type="button"
                role="radio"
                aria-checked={active}
                aria-label={item.ariaLabel}
                title={item.title}
                onClick={() => setLayoutMode(item.mode)}
                data-pill="true"
                className={[
                  'charkle-pressable h-[26px] w-[28px] rounded-full inline-flex items-center justify-center cursor-pointer',
                  'focus-visible:outline-2 focus-visible:outline-[var(--accent)]',
                  active
                    ? 'bg-black/[0.09] dark:bg-white/[0.16]'
                    : 'hover:bg-black/[0.04] dark:hover:bg-white/[0.07]',
                ].join(' ')}
              >
                <CharkleIcon name={item.icon} style="duotone" size={16} isActive={active} />
              </button>
            );
          })}
        </div>

        {/* 5. Column / Row Density Slider Pill */}
        {showDensitySlider && (
          <div
            data-pill="true"
            data-adapt-glass="true"
            title="支持按住 Ctrl + 滚轮缩放"
            className="pointer-events-auto charkle-glass rounded-full h-[34px] px-2 inline-flex items-center gap-1.5 shrink-0"
          >
            <button
              type="button"
              aria-label="缩小卡片"
              title="缩小卡片、显示更多列 (Ctrl+滚轮)"
              onClick={() =>
                setCardScale(steppedColumnWidth(cardScale, -1, layoutMode, usableWidth, 12))
              }
              className="charkle-pressable h-[22px] w-[22px] rounded-full inline-flex items-center justify-center text-[var(--text-secondary)] hover:text-[var(--text-primary)] hover:bg-black/[0.06] dark:hover:bg-white/[0.10] cursor-pointer"
            >
              <Grid3x3 size={11.5} />
            </button>
            <CharkleSlider
              min={130}
              max={420}
              step={1}
              value={cardScale}
              onChange={(val) => setCardScale(val)}
              ariaLabel="卡片缩放尺寸"
              variant="glass"
              size="sm"
              className="w-[74px]"
            />
            <button
              type="button"
              aria-label="放大卡片"
              title="放大卡片、清晰浏览细节 (Ctrl+滚轮)"
              onClick={() =>
                setCardScale(steppedColumnWidth(cardScale, 1, layoutMode, usableWidth, 12))
              }
              className="charkle-pressable h-[22px] w-[22px] rounded-full inline-flex items-center justify-center text-[var(--text-secondary)] hover:text-[var(--text-primary)] hover:bg-black/[0.06] dark:hover:bg-white/[0.10] cursor-pointer"
            >
              <Grid2x2 size={11.5} />
            </button>
          </div>
        )}

        <div className="flex-1 min-w-[4px]" />

        {/* 6. Rapid Moodboard Generator CTA Pill */}
        <button
          type="button"
          onClick={() => setMoodboardGeneratorOpen(true)}
          title="快速生成情绪板"
          aria-label="快速生成情绪板"
          data-pill="true"
          data-adapt-glass="true"
          className={[
            'pointer-events-auto charkle-pressable charkle-glass rounded-full h-[34px] inline-flex items-center justify-center gap-1.5 text-[12px] font-semibold text-[var(--text-primary)] cursor-pointer shrink-0 whitespace-nowrap',
            showFullMoodboardLabel || showCompactMoodboardLabel ? 'px-3' : 'w-[34px]',
          ].join(' ')}
        >
          <CharkleIcon name="sparkle-board" style="duotone" size={16} isActive />
          {showFullMoodboardLabel && <span>快速生成情绪板</span>}
          {showCompactMoodboardLabel && <span>情绪板</span>}
        </button>

        {/* 7. Inspector Toggle Circle Pill (1:1 macOS MainWindowView.swift) */}
        <button
          type="button"
          onClick={toggleInspector}
          aria-label={inspectorOpen ? '收起右侧检查器' : '展开右侧检查器'}
          title="显示 / 隐藏右侧检查器 (Ctrl+I)"
          data-pill="true"
          data-adapt-glass="true"
          className="pointer-events-auto charkle-pressable charkle-glass rounded-full h-[34px] w-[34px] inline-flex items-center justify-center cursor-pointer shrink-0"
        >
          <PanelRight
            size={14}
            className={inspectorOpen ? 'text-[var(--accent)]' : 'text-[var(--text-secondary)]'}
          />
        </button>
      </div>

      {/* Expandable Floating Liquid Glass Visual Filter Bar */}
      {filterOpen && (
        <div
          data-testid="visual-filter-bar"
          data-no-lens="true"
          className="pointer-events-auto charkle-glass charkle-glass-panel charkle-reveal-top rounded-[var(--radius-popover-outer)] px-3.5 py-2.5 flex flex-col gap-2.5"
        >
          {/* Row 1: MediaKind Chips + Aspect Shape Pills + Clear */}
          <div className="flex items-center gap-2 flex-wrap">
            <span className="text-[11px] font-semibold text-[var(--text-secondary)] w-7 shrink-0">
              媒体
            </span>
            <div className="flex items-center gap-1.5 flex-wrap flex-1 min-w-0">
              {ALL_MEDIA_KINDS.map((kind) => {
                const active = criteria.kinds.includes(kind);
                return (
                  <button
                    key={kind}
                    type="button"
                    onClick={() => toggleKind(kind)}
                    data-pill="true"
                    className={[
                      'charkle-pressable h-6 px-2.5 text-[11px] rounded-full cursor-pointer',
                      active
                        ? 'bg-[var(--accent)] text-white font-semibold'
                        : 'bg-black/[0.06] dark:bg-white/[0.08] text-[var(--text-primary)]/85 hover:bg-black/[0.10] dark:hover:bg-white/[0.14]',
                    ].join(' ')}
                  >
                    {mediaKindLabel(kind)}
                  </button>
                );
              })}
            </div>

            <div className="flex items-center gap-1 shrink-0">
              {ASPECT_SHAPES.map((item) => {
                const active = criteria.shape === item.value;
                return (
                  <button
                    key={item.value}
                    type="button"
                    onClick={() =>
                      void setCriteria(
                        { shape: active ? null : item.value },
                        destination,
                      )
                    }
                    className={[
                      'charkle-pressable h-6 px-2 text-[11px] rounded-[var(--radius-card-inner)] cursor-pointer',
                      active
                        ? 'bg-[var(--accent)] text-white font-semibold'
                        : 'bg-black/[0.05] dark:bg-white/[0.07] text-[var(--text-secondary)] hover:text-[var(--text-primary)]',
                    ].join(' ')}
                  >
                    {item.label}
                  </button>
                );
              })}
            </div>

            {visualFilterCount > 0 && (
              <button
                type="button"
                onClick={() => {
                  setSearchDraft('');
                  void clearVisualFilters(destination);
                }}
                className="text-[11px] font-semibold text-[var(--accent)] hover:underline cursor-pointer shrink-0"
              >
                清除
              </button>
            )}
          </div>

          {/* Row 2: Color Swatches + Custom Color Picker + Tolerance + Rating + Kept Locally */}
          <div className="flex items-center gap-3 flex-wrap">
            <div className="flex items-center gap-1.5 flex-wrap">
              <span className="text-[11px] font-semibold text-[var(--text-secondary)] w-7 shrink-0">
                色彩
              </span>
              {FILTER_PRESET_COLORS.map((hex) => {
                const selected = criteria.selectedColorHex?.toUpperCase() === hex.toUpperCase();
                return (
                  <button
                    key={hex}
                    type="button"
                    aria-label={`按颜色 ${hex} 筛选`}
                    title={`按主色调筛选 ${hex}`}
                    onClick={() =>
                      void setCriteria(
                        { selectedColorHex: selected ? null : hex },
                        destination,
                      )
                    }
                    className={[
                      'charkle-pressable h-[17px] w-[17px] rounded-full border border-black/18 dark:border-white/20 cursor-pointer',
                      selected ? 'ring-2 ring-offset-1 ring-[var(--accent)]' : '',
                    ].join(' ')}
                    style={{ backgroundColor: hex }}
                  />
                );
              })}

              <label
                title="自定义颜色筛选"
                className="relative h-[19px] w-[19px] rounded-full overflow-hidden border border-[var(--border-strong)] cursor-pointer ml-0.5 inline-flex items-center justify-center"
                style={{
                  background:
                    'conic-gradient(#EF4444, #F59E0B, #10B981, #3B82F6, #EC4899, #EF4444)',
                }}
              >
                <input
                  type="color"
                  aria-label="自定义筛选颜色"
                  value={criteria.selectedColorHex ?? '#3D5A80'}
                  onChange={(e) =>
                    void setCriteria(
                      { selectedColorHex: e.target.value.toUpperCase() },
                      destination,
                    )
                  }
                  className="opacity-0 absolute inset-0 cursor-pointer"
                />
              </label>

              {criteria.selectedColorHex && (
                <div className="flex items-center gap-1.5 ml-1">
                  <span className="text-[10px] text-[var(--text-secondary)]">精确</span>
                  <CharkleSlider
                    min={10}
                    max={55}
                    step={1}
                    value={criteria.colorTolerance}
                    onChange={(val) => void setCriteria({ colorTolerance: val }, destination)}
                    ariaLabel="色彩匹配范围"
                    title="调节颜色匹配范围：越靠左越接近所选颜色，越靠右包含更多相近色调"
                    variant="glass"
                    size="sm"
                    className="w-[82px]"
                  />
                  <span className="text-[10px] text-[var(--text-secondary)]">宽松</span>
                  <span className="px-1.5 py-0.5 rounded-full bg-[var(--accent-soft)] text-[var(--accent)] text-[10px] font-medium">
                    {toleranceLabel(criteria.colorTolerance)}
                  </span>
                  <button
                    type="button"
                    aria-label="清除颜色筛选"
                    onClick={() => void setCriteria({ selectedColorHex: null }, destination)}
                    className="text-[var(--text-secondary)] hover:text-[var(--text-primary)] cursor-pointer"
                  >
                    <X size={12} />
                  </button>
                </div>
              )}
            </div>

            <div className="h-4 w-px bg-[var(--border-hairline)] hidden sm:block" />

            {/* Minimum Rating Stars (#E5B243 gold matching macOS) */}
            <div className="flex items-center gap-1">
              <span className="text-[11px] font-semibold text-[var(--text-secondary)] mr-0.5">
                评分
              </span>
              {[1, 2, 3, 4, 5].map((star) => {
                const filled = star <= criteria.minRating;
                return (
                  <button
                    key={star}
                    type="button"
                    aria-label={`最低 ${star} 星`}
                    onClick={() =>
                      void setCriteria(
                        { minRating: criteria.minRating === star ? 0 : star },
                        destination,
                      )
                    }
                    className={[
                      'charkle-pressable cursor-pointer',
                      filled ? 'text-[#E5B243] charkle-micro-pop' : 'text-[var(--text-tertiary)]/55',
                    ].join(' ')}
                  >
                    <Star size={12} className={filled ? 'fill-current' : ''} />
                  </button>
                );
              })}
            </div>

            <div className="h-4 w-px bg-[var(--border-hairline)] hidden sm:block" />

            {/* Kept Locally Filter Toggle Pill */}
            <button
              type="button"
              onClick={() =>
                void setCriteria({ onlyPinnedOffline: !criteria.onlyPinnedOffline }, destination)
              }
              data-pill="true"
              className={[
                'charkle-pressable h-6 px-2.5 rounded-full inline-flex items-center gap-1 text-[11px] font-medium cursor-pointer',
                criteria.onlyPinnedOffline
                  ? 'bg-[var(--accent-soft)] text-[var(--accent)]'
                  : 'bg-black/[0.05] dark:bg-white/[0.07] text-[var(--text-secondary)] hover:text-[var(--text-primary)]',
              ].join(' ')}
            >
              <ArrowDownCircle size={11.5} />
              <span>已保留在本地</span>
            </button>
          </div>

          {/* Optional Top Tags Row */}
          {tagCounts.length > 0 && (
            <div className="flex items-center gap-1.5 flex-wrap">
              <span className="text-[11px] font-semibold text-[var(--text-secondary)] w-7 shrink-0">
                标签
              </span>
              {tagCounts.slice(0, 12).map((t) => {
                const active = criteria.tags.includes(t.name);
                return (
                  <button
                    key={t.name}
                    type="button"
                    onClick={() => toggleTag(t.name)}
                    data-pill="true"
                    className={[
                      'charkle-pressable h-5 px-2 rounded-full text-[11px] cursor-pointer',
                      active
                        ? 'bg-[var(--accent)] text-white font-medium'
                        : 'bg-black/[0.05] dark:bg-white/[0.07] text-[var(--text-secondary)] hover:text-[var(--text-primary)]',
                    ].join(' ')}
                  >
                    #{t.name}
                  </button>
                );
              })}
            </div>
          )}
        </div>
      )}

      {/* Compact Active Visual Filter Chips when filter bar is collapsed */}
      {!filterOpen && visualFilterCount > 0 && (
        <div className="pointer-events-none flex items-center gap-1.5 flex-wrap">
          {criteria.kinds.map((kind) => (
            <button
              key={kind}
              type="button"
              data-pill="true"
              data-adapt-glass="true"
              onClick={() => toggleKind(kind)}
              className="pointer-events-auto charkle-pressable charkle-glass inline-flex items-center gap-1 h-[26px] px-2.5 rounded-full text-[var(--accent)] text-[11.5px] font-medium cursor-pointer"
            >
              <span>{mediaKindLabel(kind)}</span>
              <X size={11} />
            </button>
          ))}

          {criteria.selectedColorHex && (
            <button
              type="button"
              data-pill="true"
              data-adapt-glass="true"
              onClick={() => void setCriteria({ selectedColorHex: null }, destination)}
              className="pointer-events-auto charkle-pressable charkle-glass inline-flex items-center gap-1.5 h-[26px] px-2.5 rounded-full text-[var(--accent)] text-[11.5px] font-medium cursor-pointer"
            >
              <span
                className="h-3 w-3 rounded-full border border-black/15"
                style={{ backgroundColor: criteria.selectedColorHex }}
              />
              <span className="charkle-mono text-[11px]">{criteria.selectedColorHex}</span>
              <X size={11} />
            </button>
          )}

          {criteria.shape && (
            <button
              type="button"
              data-pill="true"
              data-adapt-glass="true"
              onClick={() => void setCriteria({ shape: null }, destination)}
              className="pointer-events-auto charkle-pressable charkle-glass inline-flex items-center gap-1 h-[26px] px-2.5 rounded-full text-[var(--accent)] text-[11.5px] font-medium cursor-pointer"
            >
              <span>
                画幅：
                {ASPECT_SHAPES.find((s) => s.value === criteria.shape)?.label ?? criteria.shape}
              </span>
              <X size={11} />
            </button>
          )}

          {criteria.minRating > 0 && (
            <button
              type="button"
              data-pill="true"
              data-adapt-glass="true"
              onClick={() => void setCriteria({ minRating: 0 }, destination)}
              className="pointer-events-auto charkle-pressable charkle-glass inline-flex items-center gap-1 h-[26px] px-2.5 rounded-full text-[var(--accent)] text-[11.5px] font-medium cursor-pointer"
            >
              <span>评分 {criteria.minRating}+</span>
              <X size={11} />
            </button>
          )}

          {criteria.tags.map((tag) => (
            <button
              key={tag}
              type="button"
              data-pill="true"
              data-adapt-glass="true"
              onClick={() => toggleTag(tag)}
              className="pointer-events-auto charkle-pressable charkle-glass inline-flex items-center gap-1 h-[26px] px-2.5 rounded-full text-[var(--accent)] text-[11.5px] font-medium cursor-pointer"
            >
              <span>#{tag}</span>
              <X size={11} />
            </button>
          ))}

          {criteria.onlyPinnedOffline && (
            <button
              type="button"
              data-pill="true"
              data-adapt-glass="true"
              onClick={() => void setCriteria({ onlyPinnedOffline: false }, destination)}
              className="pointer-events-auto charkle-pressable charkle-glass inline-flex items-center gap-1 h-[26px] px-2.5 rounded-full text-[var(--accent)] text-[11.5px] font-medium cursor-pointer"
            >
              <span>已保留在本地</span>
              <X size={11} />
            </button>
          )}

          <button
            type="button"
            data-pill="true"
            data-adapt-glass="true"
            onClick={() => {
              setSearchDraft('');
              void clearVisualFilters(destination);
            }}
            className="pointer-events-auto charkle-pressable charkle-glass h-[26px] px-2.5 rounded-full text-[11.5px] font-medium text-[var(--text-secondary)] hover:text-[var(--text-primary)] cursor-pointer"
          >
            清除筛选
          </button>
        </div>
      )}
    </div>
  );
};
