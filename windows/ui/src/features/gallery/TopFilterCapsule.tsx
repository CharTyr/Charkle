import React, { useEffect, useRef, useState } from 'react';
import {
  Columns3,
  Film,
  Pin,
  Rows2,
  Search,
  SlidersHorizontal,
  Sparkles,
  Star,
  X,
} from 'lucide-react';
import {
  CustomSelect,
  FILTER_PRESET_COLORS,
  Popover,
  SegmentedControl,
  type SelectOption,
} from '../../design-system';
import {
  countActiveVisualFilters,
  useCoordinatorStore,
  useLibraryStore,
} from '../../stores';
import {
  mediaKindLabel,
  type AspectShape,
  type GalleryLayoutMode,
  type MediaKind,
  type SortOrder,
} from '../../types/domain';

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

const SORT_OPTIONS: ReadonlyArray<SelectOption<SortOrder>> = [
  { value: 'newest', label: '最新导入' },
  { value: 'oldest', label: '最早导入' },
  { value: 'nameAsc', label: '名称排序' },
  { value: 'ratingDesc', label: '评分优先' },
  { value: 'fileSizeDesc', label: '文件大小' },
  { value: 'relevance', label: '相关度优先' },
];

type ShapeChoice = 'any' | AspectShape;

export const TopFilterCapsule: React.FC = () => {
  const destination = useCoordinatorStore((s) => s.destination);
  const layoutMode = useCoordinatorStore((s) => s.layoutMode);
  const setLayoutMode = useCoordinatorStore((s) => s.setLayoutMode);
  const cardScale = useCoordinatorStore((s) => s.cardScale);
  const setCardScale = useCoordinatorStore((s) => s.setCardScale);

  const criteria = useLibraryStore((s) => s.criteria);
  const tagCounts = useLibraryStore((s) => s.tagCounts);
  const semanticSearch = useLibraryStore((s) => s.semanticSearch);
  const setSemanticSearch = useLibraryStore((s) => s.setSemanticSearch);
  const setCriteria = useLibraryStore((s) => s.setCriteria);
  const clearVisualFilters = useLibraryStore((s) => s.clearVisualFilters);

  const [searchDraft, setSearchDraft] = useState(criteria.searchQuery);
  const [filterOpen, setFilterOpen] = useState(false);
  const filterBtnRef = useRef<HTMLButtonElement | null>(null);

  useEffect(() => {
    setSearchDraft(criteria.searchQuery);
  }, [criteria.searchQuery]);

  useEffect(() => {
    if (searchDraft === criteria.searchQuery) return;
    const timer = window.setTimeout(() => {
      void setCriteria({ searchQuery: searchDraft }, destination);
    }, 120);
    return () => window.clearTimeout(timer);
  }, [searchDraft, criteria.searchQuery, destination, setCriteria]);

  const activeCount = countActiveVisualFilters(criteria);

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

  return (
    <div className="shrink-0 px-4 pt-3 pb-2 z-20 flex flex-col gap-2">
      <div className="charkle-glass rounded-[var(--radius-dock-outer)] px-2.5 py-1.5 flex items-center gap-2 flex-wrap">
        {/* Search Input */}
        <div className="flex items-center gap-1.5 flex-1 min-w-[180px] h-8 px-2.5 rounded-[var(--radius-dock-inner)] bg-[var(--bg-subtle)]/70 focus-within:ring-1 focus-within:ring-[var(--accent)]">
          <Search size={14} className="text-[var(--text-tertiary)] shrink-0" />
          <input
            type="text"
            value={searchDraft}
            onChange={(e) => setSearchDraft(e.target.value)}
            placeholder="搜索标题、标签、备注或正文…"
            aria-label="搜索素材"
            className="w-full bg-transparent text-[12.5px] text-[var(--text-primary)] placeholder:text-[var(--text-tertiary)] outline-none"
          />
          {searchDraft && (
            <button
              type="button"
              aria-label="清空搜索"
              onClick={() => {
                setSearchDraft('');
                void setCriteria({ searchQuery: '' }, destination);
              }}
              className="text-[var(--text-tertiary)] hover:text-[var(--text-primary)] cursor-pointer"
            >
              <X size={13} />
            </button>
          )}
        </div>

        {/* Semantic toggle */}
        <button
          type="button"
          aria-pressed={semanticSearch}
          title="结合视觉与语义关联排序"
          onClick={() => {
            const next = !semanticSearch;
            setSemanticSearch(next);
            if (next && criteria.sortBy !== 'relevance') {
              void setCriteria({ sortBy: 'relevance' }, destination);
            }
          }}
          className={[
            'charkle-pressable h-8 px-2.5 inline-flex items-center gap-1 rounded-[var(--radius-dock-inner)] text-[12px] font-medium cursor-pointer border',
            semanticSearch
              ? 'bg-[var(--accent-soft)] text-[var(--accent)] border-[var(--accent-ring)]'
              : 'bg-transparent text-[var(--text-secondary)] border-transparent hover:bg-[var(--bg-subtle)] hover:text-[var(--text-primary)]',
          ].join(' ')}
        >
          <Sparkles size={13.5} />
          <span>语义</span>
        </button>

        {/* Visual Filter Popover Trigger */}
        <button
          ref={filterBtnRef}
          type="button"
          aria-expanded={filterOpen}
          onClick={() => setFilterOpen((v) => !v)}
          className={[
            'charkle-pressable h-8 px-2.5 inline-flex items-center gap-1.5 rounded-[var(--radius-dock-inner)] text-[12px] font-medium cursor-pointer border',
            activeCount > 0
              ? 'bg-[var(--accent-soft)] text-[var(--accent)] border-[var(--accent-ring)]'
              : 'bg-transparent text-[var(--text-secondary)] border-transparent hover:bg-[var(--bg-subtle)] hover:text-[var(--text-primary)]',
          ].join(' ')}
        >
          <SlidersHorizontal size={13.5} />
          <span>筛选</span>
          {activeCount > 0 && (
            <span className="px-1.5 py-0.5 text-[10.5px] leading-none rounded-full bg-[var(--accent)] text-white charkle-tabular">
              {activeCount}
            </span>
          )}
        </button>

        {/* Sort Order CustomSelect */}
        <CustomSelect<SortOrder>
          value={criteria.sortBy}
          options={SORT_OPTIONS}
          onChange={(sortBy) => void setCriteria({ sortBy }, destination)}
          ariaLabel="排序方式"
          size="xs"
          className="h-8"
        />

        {/* Layout Mode Segmented Control */}
        <SegmentedControl<GalleryLayoutMode>
          value={layoutMode}
          onChange={setLayoutMode}
          ariaLabel="画廊布局模式"
          size="xs"
          options={[
            {
              value: 'verticalMasonry',
              label: '',
              title: '纵向瀑布流 (Ctrl+1)',
              icon: <Columns3 size={13.5} />,
            },
            {
              value: 'horizontalJustified',
              label: '',
              title: '横向等高流 (Ctrl+2)',
              icon: <Rows2 size={13.5} />,
            },
            {
              value: 'galleryFilmstrip',
              label: '',
              title: '胶片画廊 (Ctrl+3)',
              icon: <Film size={13.5} />,
            },
          ]}
        />

        {/* Card Density Slider (only for Masonry / Justified) */}
        {layoutMode !== 'galleryFilmstrip' && (
          <div className="hidden lg:flex items-center gap-1.5 pl-1 pr-1">
            <input
              type="range"
              min={170}
              max={330}
              step={8}
              value={cardScale}
              aria-label="卡片缩放尺寸"
              title="调整素材卡片尺寸"
              onChange={(e) => setCardScale(Number(e.target.value))}
              className="w-[68px] accent-[var(--accent)] cursor-pointer"
            />
          </div>
        )}
      </div>

      {/* Active visual filter chips */}
      {activeCount > 0 && (
        <div className="flex items-center gap-1.5 flex-wrap px-1">
          {criteria.kinds.map((kind) => (
            <button
              key={kind}
              type="button"
              onClick={() => toggleKind(kind)}
              className="charkle-pressable inline-flex items-center gap-1 h-6 px-2 rounded-full bg-[var(--accent-soft)] text-[var(--accent)] text-[11.5px] cursor-pointer"
            >
              <span>{mediaKindLabel(kind)}</span>
              <X size={11} />
            </button>
          ))}

          {criteria.selectedColorHex && (
            <button
              type="button"
              onClick={() => void setCriteria({ selectedColorHex: null }, destination)}
              className="charkle-pressable inline-flex items-center gap-1.5 h-6 px-2 rounded-full bg-[var(--accent-soft)] text-[var(--accent)] text-[11.5px] cursor-pointer"
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
              onClick={() => void setCriteria({ shape: null }, destination)}
              className="charkle-pressable inline-flex items-center gap-1 h-6 px-2 rounded-full bg-[var(--accent-soft)] text-[var(--accent)] text-[11.5px] cursor-pointer"
            >
              <span>
                画幅：
                {criteria.shape === 'landscape'
                  ? '横图'
                  : criteria.shape === 'portrait'
                    ? '竖图'
                    : criteria.shape === 'square'
                      ? '方图'
                      : '超宽'}
              </span>
              <X size={11} />
            </button>
          )}

          {criteria.minRating > 0 && (
            <button
              type="button"
              onClick={() => void setCriteria({ minRating: 0 }, destination)}
              className="charkle-pressable inline-flex items-center gap-1 h-6 px-2 rounded-full bg-[var(--accent-soft)] text-[var(--accent)] text-[11.5px] cursor-pointer"
            >
              <span>评分 {criteria.minRating}+</span>
              <X size={11} />
            </button>
          )}

          {criteria.tags.map((tag) => (
            <button
              key={tag}
              type="button"
              onClick={() => toggleTag(tag)}
              className="charkle-pressable inline-flex items-center gap-1 h-6 px-2 rounded-full bg-[var(--accent-soft)] text-[var(--accent)] text-[11.5px] cursor-pointer"
            >
              <span>#{tag}</span>
              <X size={11} />
            </button>
          ))}

          {criteria.onlyPinnedOffline && (
            <button
              type="button"
              onClick={() => void setCriteria({ onlyPinnedOffline: false }, destination)}
              className="charkle-pressable inline-flex items-center gap-1 h-6 px-2 rounded-full bg-[var(--accent-soft)] text-[var(--accent)] text-[11.5px] cursor-pointer"
            >
              <span>仅离线常驻</span>
              <X size={11} />
            </button>
          )}

          <button
            type="button"
            onClick={() => {
              setSearchDraft('');
              void clearVisualFilters(destination);
            }}
            className="text-[11.5px] text-[var(--text-secondary)] hover:text-[var(--text-primary)] px-1.5 cursor-pointer"
          >
            重置全部
          </button>
        </div>
      )}

      {/* Visual Filter Popover */}
      <Popover
        open={filterOpen}
        onOpenChange={setFilterOpen}
        anchorEl={filterBtnRef.current}
        placement="bottom-start"
        className="w-[348px] p-3.5"
      >
        <div className="flex flex-col gap-3.5">
          <div className="flex items-center justify-between">
            <span className="text-[12.5px] font-semibold text-[var(--text-primary)]">
              视觉与属性筛选
            </span>
            {activeCount > 0 && (
              <button
                type="button"
                onClick={() => {
                  setSearchDraft('');
                  void clearVisualFilters(destination);
                }}
                className="text-[11.5px] text-[var(--accent)] hover:underline cursor-pointer"
              >
                清除全部
              </button>
            )}
          </div>

          {/* Media Kinds */}
          <div className="flex flex-col gap-1.5">
            <span className="text-[11px] font-medium text-[var(--text-tertiary)]">媒体类型</span>
            <div className="flex flex-wrap gap-1.5">
              {ALL_MEDIA_KINDS.map((kind) => {
                const active = criteria.kinds.includes(kind);
                return (
                  <button
                    key={kind}
                    type="button"
                    onClick={() => toggleKind(kind)}
                    className={[
                      'charkle-pressable h-6 px-2 text-[11.5px] rounded-[var(--radius-card-inner)] border cursor-pointer',
                      active
                        ? 'bg-[var(--accent-soft)] border-[var(--accent-ring)] text-[var(--accent)] font-medium'
                        : 'bg-[var(--bg-subtle)] border-transparent text-[var(--text-secondary)] hover:text-[var(--text-primary)]',
                    ].join(' ')}
                  >
                    {mediaKindLabel(kind)}
                  </button>
                );
              })}
            </div>
          </div>

          {/* Color Palette + Tolerance */}
          <div className="flex flex-col gap-1.5">
            <div className="flex items-center justify-between">
              <span className="text-[11px] font-medium text-[var(--text-tertiary)]">按主色查找</span>
              {criteria.selectedColorHex && (
                <span className="text-[11px] text-[var(--text-secondary)] charkle-tabular">
                  色差容忍 {criteria.colorTolerance}
                </span>
              )}
            </div>
            <div className="flex items-center gap-1.5 flex-wrap">
              {FILTER_PRESET_COLORS.map((hex) => {
                const selected = criteria.selectedColorHex?.toUpperCase() === hex.toUpperCase();
                return (
                  <button
                    key={hex}
                    type="button"
                    aria-label={`按颜色 ${hex} 筛选`}
                    onClick={() =>
                      void setCriteria(
                        { selectedColorHex: selected ? null : hex },
                        destination,
                      )
                    }
                    className={[
                      'charkle-pressable h-6 w-6 rounded-full border border-black/15 cursor-pointer',
                      selected ? 'ring-2 ring-offset-1 ring-[var(--accent)]' : '',
                    ].join(' ')}
                    style={{ backgroundColor: hex }}
                  />
                );
              })}
            </div>
            {criteria.selectedColorHex && (
              <input
                type="range"
                min={10}
                max={50}
                value={criteria.colorTolerance}
                aria-label="色彩容差"
                onChange={(e) =>
                  void setCriteria({ colorTolerance: Number(e.target.value) }, destination)
                }
                className="w-full accent-[var(--accent)]"
              />
            )}
          </div>

          {/* Aspect Shape */}
          <div className="flex flex-col gap-1.5">
            <span className="text-[11px] font-medium text-[var(--text-tertiary)]">画面比例</span>
            <SegmentedControl<ShapeChoice>
              value={criteria.shape ?? 'any'}
              onChange={(val) =>
                void setCriteria({ shape: val === 'any' ? null : val }, destination)
              }
              options={[
                { value: 'any', label: '全部' },
                { value: 'landscape', label: '横图' },
                { value: 'portrait', label: '竖图' },
                { value: 'square', label: '方图' },
                { value: 'ultrawide', label: '超宽' },
              ]}
            />
          </div>

          {/* Min Rating */}
          <div className="flex items-center justify-between gap-2">
            <span className="text-[11px] font-medium text-[var(--text-tertiary)]">最低评分</span>
            <div className="flex items-center gap-1">
              {[0, 1, 2, 3, 4, 5].map((r) => (
                <button
                  key={r}
                  type="button"
                  onClick={() => void setCriteria({ minRating: r }, destination)}
                  className={[
                    'charkle-pressable h-6 px-2 inline-flex items-center gap-0.5 rounded-[var(--radius-card-inner)] text-[11.5px] cursor-pointer',
                    criteria.minRating === r
                      ? 'bg-[var(--accent-soft)] text-[var(--accent)] font-medium'
                      : 'bg-[var(--bg-subtle)] text-[var(--text-secondary)]',
                  ].join(' ')}
                >
                  {r === 0 ? (
                    '不限'
                  ) : (
                    <>
                      <Star size={10.5} className="fill-current" />
                      <span className="charkle-tabular">{r}</span>
                    </>
                  )}
                </button>
              ))}
            </div>
          </div>

          {/* Tags */}
          {tagCounts.length > 0 && (
            <div className="flex flex-col gap-1.5">
              <span className="text-[11px] font-medium text-[var(--text-tertiary)]">常用标签</span>
              <div className="flex flex-wrap gap-1 max-h-[76px] overflow-y-auto charkle-scroll">
                {tagCounts.slice(0, 14).map((t) => {
                  const active = criteria.tags.includes(t.name);
                  return (
                    <button
                      key={t.name}
                      type="button"
                      onClick={() => toggleTag(t.name)}
                      className={[
                        'charkle-pressable h-6 px-2 rounded-full text-[11.5px] cursor-pointer',
                        active
                          ? 'bg-[var(--accent-soft)] text-[var(--accent)] font-medium'
                          : 'bg-[var(--bg-subtle)] text-[var(--text-secondary)] hover:text-[var(--text-primary)]',
                      ].join(' ')}
                    >
                      #{t.name}
                    </button>
                  );
                })}
              </div>
            </div>
          )}

          {/* Offline pinned toggle */}
          <label className="flex items-center justify-between pt-1 border-t border-[var(--border-hairline)] cursor-pointer">
            <span className="inline-flex items-center gap-1.5 text-[12px] text-[var(--text-primary)]">
              <Pin size={13} className="text-[var(--text-secondary)]" />
              仅显示离线常驻素材
            </span>
            <input
              type="checkbox"
              checked={criteria.onlyPinnedOffline}
              onChange={(e) =>
                void setCriteria({ onlyPinnedOffline: e.target.checked }, destination)
              }
              className="accent-[var(--accent)] h-4 w-4 cursor-pointer"
            />
          </label>
        </div>
      </Popover>
    </div>
  );
};
