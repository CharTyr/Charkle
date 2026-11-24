import React, { useEffect, useMemo, useRef, useState } from 'react';
import {
  Add16Regular,
  ArrowDownload16Regular,
  ArrowSort16Regular,
  Dismiss16Regular,
  Star16Filled,
  Star16Regular,
  Subtract16Regular,
} from '@fluentui/react-icons';
import { useMotionValue, type MotionValue } from 'motion/react';
import {
  Button,
  CharkleIcon,
  CharkleSlider,
  CustomSelect,
  FILTER_PRESET_COLORS,
  SegmentedControl,
  Tooltip,
  m,
  useMotionValueEvent,
  useScroll,
  useTransform,
  type SelectOption,
} from '../../design-system';
import { useCoordinatorStore, useLibraryStore } from '../../stores';
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

const COLLAPSE_DISTANCE_PX = 48;

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

const ScrollProgressBinder: React.FC<{
  container: HTMLDivElement;
  scrollProgress: MotionValue<number>;
}> = ({ container, scrollProgress }) => {
  const containerRef = useRef<HTMLDivElement>(container);
  containerRef.current = container;
  const { scrollY } = useScroll({ container: containerRef });

  useMotionValueEvent(scrollY, 'change', (latest) => {
    const next = Math.max(0, Math.min(1, latest / COLLAPSE_DISTANCE_PX));
    scrollProgress.set(next);
  });

  useEffect(() => {
    const sync = () => {
      const next = Math.max(0, Math.min(1, container.scrollTop / COLLAPSE_DISTANCE_PX));
      scrollProgress.set(next);
    };
    sync();
    container.addEventListener('scroll', sync, { passive: true });
    return () => {
      container.removeEventListener('scroll', sync);
      scrollProgress.set(0);
    };
  }, [container, scrollProgress]);

  return null;
};

export interface TopFilterCapsuleProps {
  /** Measured gallery viewport width for exact 1-column / 1-stop +/- zoom stepping. */
  galleryViewportWidth?: number;
  /** Section heading displayed on the left side of the collapsible Fluent 2 gallery header. */
  sectionTitle?: string;
  /** Total item count displayed beside the heading in tabular numerals. */
  itemCount?: number;
  /** Live vertical scroll container driving zero-rerender scroll-linked sticky collapse (0px -> 48px). */
  scrollContainer?: HTMLDivElement | null;
}

/**
 * Windows 11 Fluent 2 Collapsible Sticky Gallery Header (`fluent2-design-system.md` §3.2 & §6.2):
 * - Expanded (`scrollTop = 0`): 24px SemiBold `.win-display-title` heading + tabular item count on left;
 *   crisp 32px-tall aligned Fluent toolbar on right (Filter, Sort, 4-mode layout SegmentedControl,
 *   Density slider with +/- steps, Quick Moodboard CTA). Search lives in Sidebar; Inspector toggle in Titlebar.
 * - Scrolled (`0px -> 48px`): zero-rerender `useScroll` + `useTransform` glides out display heading,
 *   fades in compact sticky title, and reveals `.win-acrylic-header` + 1px bottom divider.
 * - Expandable Visual Filter card (`data-testid="visual-filter-bar"`) with 4px/8px Fluent geometry.
 */
export const TopFilterCapsule: React.FC<TopFilterCapsuleProps> = ({
  galleryViewportWidth = 960,
  sectionTitle,
  itemCount,
  scrollContainer = null,
}) => {
  const destination = useCoordinatorStore((s) => s.destination);
  const layoutMode = useCoordinatorStore((s) => s.layoutMode);
  const setLayoutMode = useCoordinatorStore((s) => s.setLayoutMode);
  const cardScale = useCoordinatorStore((s) => s.cardScale);
  const setCardScale = useCoordinatorStore((s) => s.setCardScale);
  const filterOpen = useCoordinatorStore((s) => s.visualFilterBarOpen);
  const toggleFilterOpen = useCoordinatorStore((s) => s.toggleVisualFilterBar);
  const setMoodboardGeneratorOpen = useCoordinatorStore((s) => s.setMoodboardGeneratorOpen);

  const assetsLength = useLibraryStore((s) => s.assets.length);
  const folders = useLibraryStore((s) => s.folders);
  const smartFolders = useLibraryStore((s) => s.smartFolders);
  const criteria = useLibraryStore((s) => s.criteria);
  const tagCounts = useLibraryStore((s) => s.tagCounts);
  const setCriteria = useLibraryStore((s) => s.setCriteria);
  const clearVisualFilters = useLibraryStore((s) => s.clearVisualFilters);

  const resolvedTitle = useMemo(() => {
    if (sectionTitle) return sectionTitle;
    switch (destination.type) {
      case 'allItems':
        return '全部素材';
      case 'inbox':
        return '收件箱';
      case 'untagged':
        return '未打标签';
      case 'recent':
        return '最近浏览';
      case 'trash':
        return '回收站';
      case 'folder':
        return folders.find((f) => f.id === destination.id)?.name ?? '文件夹';
      case 'smartFolder':
        return smartFolders.find((sf) => sf.id === destination.id)?.name ?? '智能文件夹';
      case 'tag':
        return `#${destination.name}`;
      default:
        return '全部素材';
    }
  }, [sectionTitle, destination, folders, smartFolders]);

  const resolvedCount = itemCount ?? assetsLength;
  const visualFilterCount = countVisualFiltersOnly(criteria);
  const usableWidth = Math.max(240, galleryViewportWidth - 32);

  // Zero-rerender scroll progress (0 at top -> 1 at >= 48px scrolled)
  const scrollProgress = useMotionValue(0);
  const acrylicOpacity = useTransform(scrollProgress, [0, 0.25, 1], [0, 0.35, 1]);
  const rowY = useTransform(scrollProgress, [0, 1], [4, 0]);
  const displayOpacity = useTransform(scrollProgress, [0, 0.62], [1, 0]);
  const displayY = useTransform(scrollProgress, [0, 0.62], [0, -12]);
  const compactOpacity = useTransform(scrollProgress, [0.38, 1], [0, 1]);
  const compactY = useTransform(scrollProgress, [0.38, 1], [10, 0]);

  useEffect(() => {
    if (!scrollContainer) {
      scrollProgress.set(0);
    }
  }, [scrollContainer, scrollProgress]);

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
      icon: 'gallery-filmstrip',
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

  // Progressive responsive widths so 251px ultra-narrow -> 800px -> 2560px wide never overflows or clips
  const supportsDensity = layoutMode !== 'galleryFilmstrip' && layoutMode !== 'ringGallery';
  const showHeading = effectiveWidth <= 0 || effectiveWidth >= 480;
  const isTightHeader = !showHeading;
  const showSortInRow = effectiveWidth <= 0 || effectiveWidth >= 340;
  const compactSort = effectiveWidth > 0 && effectiveWidth < 430;
  const showDensitySlider = supportsDensity && (effectiveWidth <= 0 || effectiveWidth >= 660);
  const showFilterLabel = effectiveWidth <= 0 || effectiveWidth >= 740;
  const showFullMoodboardLabel = effectiveWidth <= 0 || effectiveWidth >= 960;
  const showCompactMoodboardLabel = !showFullMoodboardLabel && effectiveWidth >= 780;

  const scrollBinderKey = useMemo(() => {
    const destId =
      'id' in destination ? destination.id : 'name' in destination ? destination.name : '';
    return `${layoutMode}:${destination.type}:${destId}`;
  }, [layoutMode, destination]);

  return (
    <div ref={barRef} className="pointer-events-none flex flex-col">
      {scrollContainer && (
        <ScrollProgressBinder
          key={scrollBinderKey}
          container={scrollContainer}
          scrollProgress={scrollProgress}
        />
      )}

      {/* Primary Collapsible Sticky Gallery Header (Expanded 56px -> Sticky Acrylic 48px) */}
      <header
        data-testid="gallery-sticky-header"
        className="pointer-events-auto relative h-[56px] w-full shrink-0 select-none overflow-hidden"
      >
        {/* Scroll-revealed Acrylic backdrop + 1px bottom divider (opacity 0 -> 1 over 0..48px) */}
        <m.div
          aria-hidden="true"
          data-testid="gallery-header-acrylic"
          style={{ opacity: acrylicOpacity }}
          className="win-acrylic-header pointer-events-none absolute inset-x-0 top-0 h-[48px]"
        />

        {/* Symmetrically aligned header row (px-4 aligns flush with gallery card edges) */}
        <m.div
          style={{ y: rowY }}
          className={[
            'relative z-[1] h-[48px] flex items-center min-w-0',
            isTightHeader ? 'px-2.5 justify-between gap-1.5' : 'px-4 justify-between gap-3',
          ].join(' ')}
        >
          {/* Left: Morphing Section Heading (24px Display -> 14px Compact Sticky Title) */}
          {showHeading ? (
            <div className="relative flex-1 min-w-0 h-full flex items-center overflow-hidden">
              <m.div
                style={{ opacity: displayOpacity, y: displayY }}
                className="flex items-baseline gap-2 min-w-0 max-w-full"
              >
                <h1 className="win-display-title whitespace-nowrap text-[var(--text-primary)] truncate">
                  {resolvedTitle}
                </h1>
                <span className="text-[12px] font-medium text-[var(--text-tertiary)] charkle-tabular shrink-0">
                  {resolvedCount.toLocaleString()}
                </span>
              </m.div>

              <m.div
                aria-hidden="true"
                style={{ opacity: compactOpacity, y: compactY }}
                className="pointer-events-none absolute inset-y-0 left-0 right-0 flex items-center gap-2 min-w-0"
              >
                <span className="text-[14px] font-semibold leading-[20px] whitespace-nowrap text-[var(--text-primary)] truncate">
                  {resolvedTitle}
                </span>
                <span className="text-[11.5px] font-medium text-[var(--text-tertiary)] charkle-tabular shrink-0">
                  {resolvedCount.toLocaleString()}
                </span>
              </m.div>
            </div>
          ) : (
            <h1 className="sr-only">{resolvedTitle}</h1>
          )}

          {/* Right: Crisp 32px-tall Aligned Fluent 2 Control Strip */}
          <div
            className={[
              'flex items-center shrink-0 flex-nowrap min-w-0',
              isTightHeader ? 'gap-1 w-full justify-between' : 'gap-1.5',
            ].join(' ')}
          >
            {/* 1. Visual Filter Toggle Button */}
            <Tooltip content="视觉与色彩筛选" shortcut="Ctrl+Shift+S">
              <Button
                variant="standard"
                size={showFilterLabel ? 'sm' : 'icon'}
                active={filterOpen || visualFilterCount > 0}
                aria-expanded={filterOpen}
                aria-label="筛选"
                onClick={toggleFilterOpen}
                className="relative shrink-0"
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
                    className={
                      showFilterLabel
                        ? 'inline-flex items-center justify-center min-w-[16px] h-4 px-1 rounded-full bg-[var(--accent)] text-[var(--accent-text)] text-[10px] font-semibold charkle-tabular shrink-0'
                        : 'absolute top-1 right-1 h-1.5 w-1.5 rounded-full bg-[var(--accent)]'
                    }
                  >
                    {showFilterLabel ? visualFilterCount : null}
                  </span>
                )}
              </Button>
            </Tooltip>

            {/* 2. Sort ComboBox (folds into filter panel below 340px to prevent clipping) */}
            {showSortInRow && (
              <div className="shrink-0">
                <CustomSelect<SortOrder>
                  value={criteria.sortBy}
                  options={SORT_OPTIONS}
                  onChange={(sortBy) => void setCriteria({ sortBy }, destination)}
                  ariaLabel="排序方式"
                  size="sm"
                  hideChevron={compactSort}
                  leadingIcon={
                    compactSort ? undefined : (
                      <ArrowSort16Regular className="w-3.5 h-3.5 text-[var(--text-secondary)] shrink-0" />
                    )
                  }
                  className={compactSort ? 'px-2 max-w-[82px] text-[12px]' : undefined}
                />
              </div>
            )}

            {/* 3. 4-Mode View Switcher SegmentedControl */}
            <SegmentedControl<GalleryLayoutMode>
              value={layoutMode}
              onChange={setLayoutMode}
              size="xs"
              ariaLabel="画廊布局模式"
              layoutId="win-gallery-layout-mode"
              className="h-8 shrink-0"
              options={layoutModes.map((item) => ({
                value: item.mode,
                label: '',
                title: item.title,
                icon: (
                  <>
                    <CharkleIcon
                      name={item.icon}
                      style="duotone"
                      size={16}
                      isActive={layoutMode === item.mode}
                    />
                    <span className="sr-only">{item.ariaLabel}</span>
                  </>
                ),
              }))}
            />

            {/* 4. Density Slider + -/+ Step Buttons */}
            {showDensitySlider && (
              <div
                title="支持按住 Ctrl + 滚轮缩放"
                className="win-control-elevation h-8 px-1.5 inline-flex items-center gap-1 rounded-[var(--win-radius-control)] bg-[var(--win-control-fill)] shrink-0"
              >
                <Tooltip content="缩小卡片、显示更多列" shortcut="Ctrl+滚轮">
                  <button
                    type="button"
                    aria-label="缩小卡片"
                    onClick={() =>
                      setCardScale(steppedColumnWidth(cardScale, -1, layoutMode, usableWidth, 12))
                    }
                    className="charkle-pressable h-6 w-6 rounded-[var(--win-radius-control)] inline-flex items-center justify-center text-[var(--text-secondary)] hover:text-[var(--text-primary)] hover:bg-[var(--win-subtle-hover)] active:bg-[var(--win-subtle-active)] focus-visible:outline-2 focus-visible:outline-[var(--accent)] cursor-pointer"
                  >
                    <Subtract16Regular className="w-3.5 h-3.5" />
                  </button>
                </Tooltip>
                <CharkleSlider
                  min={130}
                  max={420}
                  step={1}
                  value={cardScale}
                  onChange={(val) => setCardScale(val)}
                  ariaLabel="卡片缩放尺寸"
                  variant="standard"
                  size="sm"
                  className="w-[68px]"
                />
                <Tooltip content="放大卡片、清晰浏览细节" shortcut="Ctrl+滚轮">
                  <button
                    type="button"
                    aria-label="放大卡片"
                    onClick={() =>
                      setCardScale(steppedColumnWidth(cardScale, 1, layoutMode, usableWidth, 12))
                    }
                    className="charkle-pressable h-6 w-6 rounded-[var(--win-radius-control)] inline-flex items-center justify-center text-[var(--text-secondary)] hover:text-[var(--text-primary)] hover:bg-[var(--win-subtle-hover)] active:bg-[var(--win-subtle-active)] focus-visible:outline-2 focus-visible:outline-[var(--accent)] cursor-pointer"
                  >
                    <Add16Regular className="w-3.5 h-3.5" />
                  </button>
                </Tooltip>
              </div>
            )}

            {/* 5. Quick Moodboard Generator CTA */}
            <Tooltip content="快速生成情绪板">
              <Button
                variant="standard"
                size={showFullMoodboardLabel || showCompactMoodboardLabel ? 'sm' : 'icon'}
                aria-label="快速生成情绪板"
                onClick={() => setMoodboardGeneratorOpen(true)}
                className="shrink-0"
              >
                <CharkleIcon name="sparkle-board" style="duotone" size={16} isActive />
                {showFullMoodboardLabel && <span>快速生成情绪板</span>}
                {showCompactMoodboardLabel && <span>情绪板</span>}
              </Button>
            </Tooltip>
          </div>
        </m.div>
      </header>

      {/* Expandable Fluent 2 Visual Filter Card (matching Sticky Header Acrylic glass) */}
      {filterOpen && (
        <div className="pointer-events-none px-4 pb-2">
          <div
            data-testid="visual-filter-bar"
            className="pointer-events-auto charkle-reveal-top win-acrylic-bar rounded-[var(--win-radius-card)] px-3.5 py-2.5 flex flex-col gap-2.5"
          >
            {!showSortInRow && (
              <div className="flex items-center gap-2 flex-wrap">
                <span className="text-[11.5px] font-semibold text-[var(--text-secondary)] w-7 shrink-0">
                  排序
                </span>
                <CustomSelect<SortOrder>
                  value={criteria.sortBy}
                  options={SORT_OPTIONS}
                  onChange={(sortBy) => void setCriteria({ sortBy }, destination)}
                  ariaLabel="排序方式"
                  size="xs"
                  leadingIcon={
                    <ArrowSort16Regular className="w-3.5 h-3.5 text-[var(--text-secondary)] shrink-0" />
                  }
                />
              </div>
            )}
            {/* Row 1: MediaKind Chips + Aspect Shape + Clear */}
            <div className="flex items-center gap-2 flex-wrap">
              <span className="text-[11.5px] font-semibold text-[var(--text-secondary)] w-7 shrink-0">
                媒体
              </span>
              <div className="flex items-center gap-1 flex-wrap flex-1 min-w-0">
                {ALL_MEDIA_KINDS.map((kind) => {
                  const active = criteria.kinds.includes(kind);
                  return (
                    <button
                      key={kind}
                      type="button"
                      onClick={() => toggleKind(kind)}
                      className={[
                        'charkle-pressable h-[26px] px-2.5 text-[12px] leading-[16px] rounded-[var(--win-radius-control)] cursor-pointer',
                        'focus-visible:outline-2 focus-visible:outline-[var(--accent)]',
                        active
                          ? 'bg-[var(--accent)] text-[var(--accent-text)] font-medium'
                          : 'bg-[var(--win-subtle-hover)] text-[var(--text-primary)] hover:bg-[var(--win-subtle-active)]',
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
                        void setCriteria({ shape: active ? null : item.value }, destination)
                      }
                      className={[
                        'charkle-pressable h-[26px] px-2 text-[12px] leading-[16px] rounded-[var(--win-radius-control)] cursor-pointer',
                        'focus-visible:outline-2 focus-visible:outline-[var(--accent)]',
                        active
                          ? 'bg-[var(--accent)] text-[var(--accent-text)] font-medium'
                          : 'bg-[var(--win-subtle-hover)] text-[var(--text-secondary)] hover:text-[var(--text-primary)] hover:bg-[var(--win-subtle-active)]',
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
                  onClick={() => void clearVisualFilters(destination)}
                  className="text-[12px] font-medium text-[var(--accent)] hover:underline cursor-pointer shrink-0"
                >
                  清除筛选
                </button>
              )}
            </div>

            {/* Row 2: Color Swatches + Custom Color Picker + Tolerance + Rating + Kept Locally */}
            <div className="flex items-center gap-3 flex-wrap">
              <div className="flex items-center gap-1.5 flex-wrap">
                <span className="text-[11.5px] font-semibold text-[var(--text-secondary)] w-7 shrink-0">
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
                        'charkle-pressable h-[18px] w-[18px] rounded-full border border-black/18 dark:border-white/20 cursor-pointer',
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
                    <span className="text-[11px] text-[var(--text-secondary)]">精确</span>
                    <CharkleSlider
                      min={10}
                      max={55}
                      step={1}
                      value={criteria.colorTolerance}
                      onChange={(val) => void setCriteria({ colorTolerance: val }, destination)}
                      ariaLabel="色彩匹配范围"
                      title="调节颜色匹配范围：越靠左越接近所选颜色，越靠右包含更多相近色调"
                      variant="standard"
                      size="sm"
                      className="w-[82px]"
                    />
                    <span className="text-[11px] text-[var(--text-secondary)]">宽松</span>
                    <span className="px-1.5 py-0.5 rounded-[var(--win-radius-control)] bg-[var(--accent-soft)] text-[var(--accent)] text-[10.5px] font-medium">
                      {toleranceLabel(criteria.colorTolerance)}
                    </span>
                    <button
                      type="button"
                      aria-label="清除颜色筛选"
                      onClick={() => void setCriteria({ selectedColorHex: null }, destination)}
                      className="h-5 w-5 rounded-[var(--win-radius-control)] inline-flex items-center justify-center text-[var(--text-secondary)] hover:text-[var(--text-primary)] hover:bg-[var(--win-subtle-hover)] cursor-pointer"
                    >
                      <Dismiss16Regular className="w-3 h-3" />
                    </button>
                  </div>
                )}
              </div>

              <div className="h-4 w-px bg-[var(--win-stroke-divider)] hidden sm:block" />

              {/* Minimum Rating Stars (#E5B243 gold) */}
              <div className="flex items-center gap-0.5">
                <span className="text-[11.5px] font-semibold text-[var(--text-secondary)] mr-1">
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
                        'charkle-pressable h-6 w-6 rounded-[var(--win-radius-control)] inline-flex items-center justify-center hover:bg-[var(--win-subtle-hover)] cursor-pointer',
                        filled
                          ? 'text-[#E5B243] charkle-micro-pop'
                          : 'text-[var(--text-tertiary)]/65',
                      ].join(' ')}
                    >
                      {filled ? (
                        <Star16Filled className="w-3.5 h-3.5" />
                      ) : (
                        <Star16Regular className="w-3.5 h-3.5" />
                      )}
                    </button>
                  );
                })}
              </div>

              <div className="h-4 w-px bg-[var(--win-stroke-divider)] hidden sm:block" />

              {/* Kept Locally Filter Toggle */}
              <button
                type="button"
                aria-pressed={criteria.onlyPinnedOffline}
                onClick={() =>
                  void setCriteria({ onlyPinnedOffline: !criteria.onlyPinnedOffline }, destination)
                }
                className={[
                  'charkle-pressable h-[26px] px-2.5 rounded-[var(--win-radius-control)] inline-flex items-center gap-1.5 text-[12px] font-medium cursor-pointer',
                  criteria.onlyPinnedOffline
                    ? 'bg-[var(--accent-soft)] text-[var(--accent)]'
                    : 'bg-[var(--win-subtle-hover)] text-[var(--text-secondary)] hover:text-[var(--text-primary)] hover:bg-[var(--win-subtle-active)]',
                ].join(' ')}
              >
                <ArrowDownload16Regular className="w-3.5 h-3.5" />
                <span>已保留在本地</span>
              </button>
            </div>

            {/* Optional Top Tags Row */}
            {tagCounts.length > 0 && (
              <div className="flex items-center gap-1.5 flex-wrap">
                <span className="text-[11.5px] font-semibold text-[var(--text-secondary)] w-7 shrink-0">
                  标签
                </span>
                {tagCounts.slice(0, 12).map((t) => {
                  const active = criteria.tags.includes(t.name);
                  return (
                    <button
                      key={t.name}
                      type="button"
                      onClick={() => toggleTag(t.name)}
                      className={[
                        'charkle-pressable h-6 px-2 rounded-[var(--win-radius-control)] text-[11.5px] cursor-pointer',
                        active
                          ? 'bg-[var(--accent)] text-[var(--accent-text)] font-medium'
                          : 'bg-[var(--win-subtle-hover)] text-[var(--text-secondary)] hover:text-[var(--text-primary)] hover:bg-[var(--win-subtle-active)]',
                      ].join(' ')}
                    >
                      #{t.name}
                    </button>
                  );
                })}
              </div>
            )}
          </div>
        </div>
      )}

      {/* Compact Active Visual Filter Chips when filter card is collapsed */}
      {!filterOpen && visualFilterCount > 0 && (
        <div className="pointer-events-none px-4 pb-2 flex items-center gap-1.5 flex-wrap">
          {criteria.kinds.map((kind) => (
            <button
              key={kind}
              type="button"
              onClick={() => toggleKind(kind)}
              className="pointer-events-auto charkle-pressable win-acrylic-bar inline-flex items-center gap-1 h-[26px] px-2.5 rounded-[var(--win-radius-control)] text-[var(--accent)] text-[12px] font-medium cursor-pointer"
            >
              <span>{mediaKindLabel(kind)}</span>
              <Dismiss16Regular className="w-3 h-3" />
            </button>
          ))}

          {criteria.selectedColorHex && (
            <button
              type="button"
              onClick={() => void setCriteria({ selectedColorHex: null }, destination)}
              className="pointer-events-auto charkle-pressable win-acrylic-bar inline-flex items-center gap-1.5 h-[26px] px-2.5 rounded-[var(--win-radius-control)] text-[var(--accent)] text-[12px] font-medium cursor-pointer"
            >
              <span
                className="h-3 w-3 rounded-full border border-black/15"
                style={{ backgroundColor: criteria.selectedColorHex }}
              />
              <span className="charkle-mono text-[11px]">{criteria.selectedColorHex}</span>
              <Dismiss16Regular className="w-3 h-3" />
            </button>
          )}

          {criteria.shape && (
            <button
              type="button"
              onClick={() => void setCriteria({ shape: null }, destination)}
              className="pointer-events-auto charkle-pressable win-acrylic-bar inline-flex items-center gap-1 h-[26px] px-2.5 rounded-[var(--win-radius-control)] text-[var(--accent)] text-[12px] font-medium cursor-pointer"
            >
              <span>
                画幅：
                {ASPECT_SHAPES.find((s) => s.value === criteria.shape)?.label ?? criteria.shape}
              </span>
              <Dismiss16Regular className="w-3 h-3" />
            </button>
          )}

          {criteria.minRating > 0 && (
            <button
              type="button"
              onClick={() => void setCriteria({ minRating: 0 }, destination)}
              className="pointer-events-auto charkle-pressable win-acrylic-bar inline-flex items-center gap-1 h-[26px] px-2.5 rounded-[var(--win-radius-control)] text-[var(--accent)] text-[12px] font-medium cursor-pointer"
            >
              <span>评分 {criteria.minRating}+</span>
              <Dismiss16Regular className="w-3 h-3" />
            </button>
          )}

          {criteria.tags.map((tag) => (
            <button
              key={tag}
              type="button"
              onClick={() => toggleTag(tag)}
              className="pointer-events-auto charkle-pressable win-acrylic-bar inline-flex items-center gap-1 h-[26px] px-2.5 rounded-[var(--win-radius-control)] text-[var(--accent)] text-[12px] font-medium cursor-pointer"
            >
              <span>#{tag}</span>
              <Dismiss16Regular className="w-3 h-3" />
            </button>
          ))}

          {criteria.onlyPinnedOffline && (
            <button
              type="button"
              onClick={() => void setCriteria({ onlyPinnedOffline: false }, destination)}
              className="pointer-events-auto charkle-pressable win-acrylic-bar inline-flex items-center gap-1 h-[26px] px-2.5 rounded-[var(--win-radius-control)] text-[var(--accent)] text-[12px] font-medium cursor-pointer"
            >
              <span>已保留在本地</span>
              <Dismiss16Regular className="w-3 h-3" />
            </button>
          )}

          <button
            type="button"
            onClick={() => void clearVisualFilters(destination)}
            className="pointer-events-auto charkle-pressable h-[26px] px-2 rounded-[var(--win-radius-control)] text-[12px] font-medium text-[var(--text-secondary)] hover:text-[var(--text-primary)] hover:bg-[var(--win-subtle-hover)] cursor-pointer"
          >
            清除筛选
          </button>
        </div>
      )}
    </div>
  );
};
