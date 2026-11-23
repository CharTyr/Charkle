import React, { useEffect, useMemo, useRef, useState } from 'react';
import {
  Camera,
  ChevronDown,
  Copy,
  ExternalLink,
  FolderOpen,
  GripVertical,
  Palette,
  Pin,
  Plus,
  RefreshCw,
  Sparkles,
  Star,
  Tag,
  X,
} from 'lucide-react';
import { getTransport } from '../../api/transport';
import {
  Button,
  CustomSelect,
  InspectorSimilarSkeleton,
  computeAmbientTintStyle,
  formatBytes,
  formatDuration,
  hasMeaningfulCameraExif,
  useDelayedFlag,
  useResolvedIsDark,
  type SelectOption,
} from '../../design-system';
import { useCoordinatorStore, useLibraryStore } from '../../stores';
import {
  buildFolderTree,
  flattenFolderTree,
  formatWireDate,
  mediaKindLabel,
  type AssetRecord,
  type ScoredAsset,
} from '../../types/domain';

type InspectorCardId =
  | 'core'
  | 'tags'
  | 'location'
  | 'palette'
  | 'exif'
  | 'aiGen'
  | 'similar';

const DEFAULT_CARD_ORDER: InspectorCardId[] = [
  'core',
  'tags',
  'location',
  'palette',
  'exif',
  'aiGen',
  'similar',
];

const CARD_ORDER_STORAGE_KEY = 'charkle.win.inspectorOrder';

function loadCardOrder(): InspectorCardId[] {
  if (typeof localStorage === 'undefined') return DEFAULT_CARD_ORDER;
  try {
    const raw = JSON.parse(localStorage.getItem(CARD_ORDER_STORAGE_KEY) ?? 'null');
    if (Array.isArray(raw)) {
      const valid = raw.filter((id): id is InspectorCardId =>
        DEFAULT_CARD_ORDER.includes(id as InspectorCardId),
      );
      const missing = DEFAULT_CARD_ORDER.filter((id) => !valid.includes(id));
      return [...valid, ...missing];
    }
  } catch {
    // Ignore malformed localStorage
  }
  return DEFAULT_CARD_ORDER;
}

const InspectorCardShell: React.FC<{
  cardId: InspectorCardId;
  title: string;
  icon?: React.ReactNode;
  collapsed: boolean;
  onToggleCollapse: () => void;
  onDragStart: (id: InspectorCardId) => void;
  onDropOn: (targetId: InspectorCardId) => void;
  children: React.ReactNode;
}> = ({
  cardId,
  title,
  icon,
  collapsed,
  onToggleCollapse,
  onDragStart,
  onDropOn,
  children,
}) => {
  const [dragOver, setDragOver] = useState(false);

  return (
    <section
      draggable
      data-inspector-card={cardId}
      onDragStart={(e) => {
        e.dataTransfer.setData('text/plain', cardId);
        onDragStart(cardId);
      }}
      onDragOver={(e) => {
        e.preventDefault();
        setDragOver(true);
      }}
      onDragLeave={() => setDragOver(false)}
      onDrop={(e) => {
        e.preventDefault();
        setDragOver(false);
        onDropOn(cardId);
      }}
      className={[
        'rounded-[var(--radius-card-outer)] bg-[var(--bg-elevated)] border transition-colors duration-150',
        dragOver ? 'border-[var(--accent)] ring-1 ring-[var(--accent-ring)]' : 'border-[var(--border-hairline)]',
      ].join(' ')}
    >
      <div className="flex items-center justify-between gap-1.5 px-2.5 py-2 select-none">
        <div className="flex items-center gap-1.5 min-w-0">
          <span
            title="拖拽调整卡片顺序"
            className="text-[var(--text-tertiary)] hover:text-[var(--text-secondary)] cursor-grab active:cursor-grabbing"
          >
            <GripVertical size={13} />
          </span>
          {icon}
          <span className="text-[11.5px] font-semibold text-[var(--text-secondary)] truncate">
            {title}
          </span>
        </div>
        <button
          type="button"
          aria-label={collapsed ? `展开${title}` : `收起${title}`}
          onClick={onToggleCollapse}
          className="h-5 w-5 inline-flex items-center justify-center rounded text-[var(--text-tertiary)] hover:text-[var(--text-primary)] hover:bg-[var(--bg-subtle)] cursor-pointer"
        >
          <ChevronDown
            size={13}
            className={`transition-transform duration-150 ${collapsed ? '-rotate-90' : ''}`}
          />
        </button>
      </div>
      {!collapsed && <div className="px-3 pb-3 pt-0.5 flex flex-col gap-2.5">{children}</div>}
    </section>
  );
};

export const InspectorView: React.FC = () => {
  const destination = useCoordinatorStore((s) => s.destination);
  const selectedAssetIds = useCoordinatorStore((s) => s.selectedAssetIds);
  const setSelection = useCoordinatorStore((s) => s.setSelection);
  const openQuickLook = useCoordinatorStore((s) => s.openQuickLook);
  const pushToast = useCoordinatorStore((s) => s.pushToast);

  const assets = useLibraryStore((s) => s.assets);
  const folders = useLibraryStore((s) => s.folders);
  const updateAssets = useLibraryStore((s) => s.updateAssets);
  const setCriteria = useLibraryStore((s) => s.setCriteria);
  const refreshRichAsset = useLibraryStore((s) => s.refreshRichAsset);
  const hydrateImageMetadata = useLibraryStore((s) => s.hydrateImageMetadata);

  const isDark = useResolvedIsDark();

  const selectedAssets = useMemo(() => {
    const idSet = new Set(selectedAssetIds);
    return assets.filter((a) => idSet.has(a.id));
  }, [assets, selectedAssetIds]);

  const asset: AssetRecord | null = selectedAssets.length === 1 ? selectedAssets[0] : null;

  // Frame-0 zero-flicker binding: track which assetId owns local drafts
  const [boundAssetId, setBoundAssetId] = useState<string | null>(asset?.id ?? null);
  const [titleDraft, setTitleDraft] = useState(asset?.title ?? '');
  const [notesDraft, setNotesDraft] = useState(asset?.notes ?? '');
  const [newTagDraft, setNewTagDraft] = useState('');
  const [batchTagDraft, setBatchTagDraft] = useState('');
  const [refreshingRich, setRefreshingRich] = useState(false);

  if ((asset?.id ?? null) !== boundAssetId) {
    setBoundAssetId(asset?.id ?? null);
    setTitleDraft(asset?.title ?? '');
    setNotesDraft(asset?.notes ?? '');
    setNewTagDraft('');
  }

  // Reorderable cards state
  const [cardOrder, setCardOrder] = useState<InspectorCardId[]>(loadCardOrder);
  const [collapsedMap, setCollapsedMap] = useState<Partial<Record<InspectorCardId, boolean>>>({});
  const draggedCardRef = useRef<InspectorCardId | null>(null);

  const handleDropCard = (targetId: InspectorCardId) => {
    const srcId = draggedCardRef.current;
    draggedCardRef.current = null;
    if (!srcId || srcId === targetId) return;
    setCardOrder((prev) => {
      const next = prev.filter((id) => id !== srcId);
      const targetIndex = next.indexOf(targetId);
      next.splice(targetIndex, 0, srcId);
      if (typeof localStorage !== 'undefined') {
        localStorage.setItem(CARD_ORDER_STORAGE_KEY, JSON.stringify(next));
      }
      return next;
    });
  };

  // Lazy similar assets & EXIF hydration
  const [similar, setSimilar] = useState<ScoredAsset[]>([]);
  const [loadingSimilar, setLoadingSimilar] = useState(false);
  const hydratedIdsRef = useRef<Set<string>>(new Set());

  useEffect(() => {
    let cancelled = false;
    if (!asset) {
      setSimilar([]);
      setLoadingSimilar(false);
      return;
    }

    setLoadingSimilar(true);
    void getTransport()
      .similarAssets(asset.id, 6)
      .then((res) => {
        if (!cancelled) {
          setSimilar(res);
          setLoadingSimilar(false);
        }
      })
      .catch(() => {
        if (!cancelled) {
          setSimilar([]);
          setLoadingSimilar(false);
        }
      });

    if (
      asset.mediaKind === 'image' &&
      !asset.richMetadata?.photoExif &&
      !hydratedIdsRef.current.has(asset.id)
    ) {
      hydratedIdsRef.current.add(asset.id);
      void hydrateImageMetadata(asset.id);
    }

    return () => {
      cancelled = true;
    };
  }, [asset?.id, asset?.mediaKind, asset?.richMetadata?.photoExif, hydrateImageMetadata]);

  const showSimilarSkeleton = useDelayedFlag(loadingSimilar && similar.length === 0, 300, 500);

  const folderOptions = useMemo<SelectOption<string>[]>(() => {
    const flat = flattenFolderTree(buildFolderTree(folders));
    return [
      { value: '__inbox__', label: '收件箱' },
      ...flat.map((node) => ({
        value: node.folder.id,
        label: node.folder.name,
        depth: node.depth,
      })),
    ];
  }, [folders]);

  const copyText = async (text: string, label: string) => {
    try {
      await navigator.clipboard?.writeText(text);
      pushToast({ message: `已复制${label}`, tone: 'success', durationMs: 2200 });
    } catch {
      pushToast({ message: `已准备${label}：${text}`, tone: 'info', durationMs: 2500 });
    }
  };

  const ambientStyle = computeAmbientTintStyle(
    asset?.dominantColors[0]?.hex,
    isDark,
    'inspector',
  );
  const transport = getTransport();

  return (
    <aside
      aria-label="属性检查器"
      data-testid="inspector-view"
      className="w-[296px] shrink-0 h-full bg-[var(--bg-inspector)] border-l border-[var(--border-hairline)] flex flex-col overflow-hidden"
    >
      <div
        style={ambientStyle}
        className="flex-1 min-h-0 overflow-y-auto charkle-scroll p-3 flex flex-col gap-2.5"
      >
        {selectedAssets.length === 0 ? (
          <div className="flex-1 flex flex-col items-center justify-center text-center px-4 py-12 text-[var(--text-tertiary)]">
            <div className="text-[13px] font-medium text-[var(--text-secondary)]">
              未选择素材
            </div>
            <p className="mt-1 text-[12px] leading-relaxed">
              点击任意画廊卡片以查看或编辑标题、标签、色板、拍摄参数与相似灵感。
            </p>
          </div>
        ) : selectedAssets.length > 1 ? (
          <div className="rounded-[var(--radius-card-outer)] bg-[var(--bg-elevated)] border border-[var(--border-hairline)] p-3.5 flex flex-col gap-3">
            <div>
              <div className="text-[14px] font-semibold text-[var(--text-primary)] charkle-tabular">
                已选择 {selectedAssets.length} 项素材
              </div>
              <div className="text-[12px] text-[var(--text-tertiary)] mt-0.5 charkle-tabular">
                合计 {formatBytes(selectedAssets.reduce((sum, a) => sum + a.fileSizeBytes, 0))}
              </div>
            </div>

            <div className="flex flex-col gap-1.5">
              <span className="text-[11.5px] font-medium text-[var(--text-secondary)]">批量评分</span>
              <div className="flex items-center gap-1">
                {[1, 2, 3, 4, 5].map((star) => (
                  <button
                    key={star}
                    type="button"
                    onClick={() =>
                      void updateAssets(
                        { assetIDs: selectedAssets.map((a) => a.id), rating: star },
                        destination,
                      )
                    }
                    className="charkle-pressable h-7 w-7 inline-flex items-center justify-center rounded-[var(--radius-card-inner)] bg-[var(--bg-subtle)] text-[var(--text-secondary)] hover:text-amber-500 cursor-pointer"
                  >
                    <Star size={13.5} />
                  </button>
                ))}
              </div>
            </div>

            <form
              onSubmit={(e) => {
                e.preventDefault();
                const tag = batchTagDraft.trim();
                if (!tag) return;
                setBatchTagDraft('');
                void updateAssets(
                  { assetIDs: selectedAssets.map((a) => a.id), addTags: [tag] },
                  destination,
                );
              }}
              className="flex items-center gap-1.5"
            >
              <input
                type="text"
                value={batchTagDraft}
                onChange={(e) => setBatchTagDraft(e.target.value)}
                placeholder="批量添加标签…"
                className="flex-1 min-w-0 h-8 px-2.5 rounded-[var(--radius-settings-inner)] bg-[var(--bg-inspector-field)] border border-[var(--border-hairline)] text-[12px] text-[var(--text-primary)] outline-none focus:border-[var(--accent)]"
              />
              <Button type="submit" variant="secondary" size="xs">
                添加
              </Button>
            </form>
          </div>
        ) : (
          asset &&
          cardOrder.map((cardId) => {
            const collapsed = Boolean(collapsedMap[cardId]);
            const toggleCollapse = () =>
              setCollapsedMap((prev) => ({ ...prev, [cardId]: !prev[cardId] }));

            if (cardId === 'core') {
              return (
                <InspectorCardShell
                  key="core"
                  cardId="core"
                  title="基本信息"
                  collapsed={collapsed}
                  onToggleCollapse={toggleCollapse}
                  onDragStart={(id) => {
                    draggedCardRef.current = id;
                  }}
                  onDropOn={handleDropCard}
                >
                  <button
                    type="button"
                    onClick={() => openQuickLook(asset.id, null)}
                    title="点击进入快速预览"
                    className="w-full aspect-[16/10] rounded-[var(--radius-settings-inner)] overflow-hidden bg-[var(--bg-subtle)] border border-[var(--border-hairline)] cursor-pointer"
                  >
                    <img
                      src={transport.thumbnailUrl(asset.id, 'grid520')}
                      alt={asset.title}
                      className="w-full h-full object-cover"
                    />
                  </button>

                  <input
                    type="text"
                    value={titleDraft}
                    aria-label="素材标题"
                    onChange={(e) => setTitleDraft(e.target.value)}
                    onBlur={() => {
                      const next = titleDraft.trim();
                      if (next && next !== asset.title) {
                        void updateAssets({ assetIDs: [asset.id], title: next }, destination);
                      }
                    }}
                    className="h-8 px-2.5 rounded-[var(--radius-settings-inner)] bg-[var(--bg-inspector-field)] border border-[var(--border-hairline)] text-[13px] font-medium text-[var(--text-primary)] outline-none focus:border-[var(--accent)]"
                  />

                  <textarea
                    rows={3}
                    value={notesDraft}
                    aria-label="素材备注"
                    placeholder="添加参考备注…"
                    onChange={(e) => setNotesDraft(e.target.value)}
                    onBlur={() => {
                      if (notesDraft !== asset.notes) {
                        void updateAssets({ assetIDs: [asset.id], notes: notesDraft }, destination);
                      }
                    }}
                    className="p-2 rounded-[var(--radius-settings-inner)] bg-[var(--bg-inspector-field)] border border-[var(--border-hairline)] text-[12px] text-[var(--text-primary)] outline-none focus:border-[var(--accent)] resize-none leading-relaxed"
                  />

                  {/* Star Rating */}
                  <div className="flex items-center justify-between">
                    <span className="text-[11.5px] text-[var(--text-tertiary)]">评分</span>
                    <div className="flex items-center gap-0.5">
                      {[1, 2, 3, 4, 5].map((star) => {
                        const filled = asset.rating >= star;
                        return (
                          <button
                            key={star}
                            type="button"
                            aria-label={`评为 ${star} 星`}
                            onClick={() =>
                              void updateAssets(
                                {
                                  assetIDs: [asset.id],
                                  rating: asset.rating === star ? 0 : star,
                                },
                                destination,
                              )
                            }
                            className={[
                              'charkle-pressable h-6 w-6 inline-flex items-center justify-center rounded cursor-pointer',
                              filled
                                ? 'text-amber-500 charkle-micro-pop'
                                : 'text-[var(--text-tertiary)] hover:text-[var(--text-primary)]',
                            ].join(' ')}
                          >
                            <Star size={14} className={filled ? 'fill-current' : ''} />
                          </button>
                        );
                      })}
                    </div>
                  </div>

                  {/* Specs summary */}
                  <div className="grid grid-cols-2 gap-y-1 text-[11.5px] text-[var(--text-tertiary)] pt-1 border-t border-[var(--border-hairline)] charkle-tabular">
                    <span>类型：{mediaKindLabel(asset.mediaKind)}</span>
                    <span className="text-right">{formatBytes(asset.fileSizeBytes)}</span>
                    {asset.pixelWidth > 0 && asset.pixelHeight > 0 && (
                      <span>
                        {asset.pixelWidth} × {asset.pixelHeight}
                      </span>
                    )}
                    {asset.durationSeconds ? (
                      <span className="text-right">{formatDuration(asset.durationSeconds)}</span>
                    ) : (
                      <span className="text-right">{formatWireDate(asset.createdAt)}</span>
                    )}
                  </div>
                </InspectorCardShell>
              );
            }

            if (cardId === 'tags') {
              return (
                <InspectorCardShell
                  key="tags"
                  cardId="tags"
                  title="标签与建议"
                  icon={<Tag size={12.5} className="text-[var(--text-tertiary)]" />}
                  collapsed={collapsed}
                  onToggleCollapse={toggleCollapse}
                  onDragStart={(id) => {
                    draggedCardRef.current = id;
                  }}
                  onDropOn={handleDropCard}
                >
                  <div className="flex flex-wrap gap-1.5">
                    {asset.tags.map((tag) => (
                      <span
                        key={tag}
                        className="inline-flex items-center gap-1 h-6 pl-2 pr-1.5 rounded-full bg-[var(--bg-subtle)] text-[11.5px] text-[var(--text-primary)]"
                      >
                        <span>#{tag}</span>
                        <button
                          type="button"
                          aria-label={`移除标签 ${tag}`}
                          onClick={() =>
                            void updateAssets(
                              { assetIDs: [asset.id], removeTags: [tag] },
                              destination,
                            )
                          }
                          className="text-[var(--text-tertiary)] hover:text-[var(--danger)] cursor-pointer"
                        >
                          <X size={11} />
                        </button>
                      </span>
                    ))}
                  </div>

                  <form
                    onSubmit={(e) => {
                      e.preventDefault();
                      const t = newTagDraft.trim();
                      if (!t) return;
                      setNewTagDraft('');
                      void updateAssets({ assetIDs: [asset.id], addTags: [t] }, destination);
                    }}
                    className="flex items-center gap-1.5"
                  >
                    <input
                      type="text"
                      value={newTagDraft}
                      onChange={(e) => setNewTagDraft(e.target.value)}
                      placeholder="新增标签后回车…"
                      className="flex-1 min-w-0 h-7 px-2.5 rounded-[var(--radius-card-inner)] bg-[var(--bg-inspector-field)] border border-[var(--border-hairline)] text-[12px] text-[var(--text-primary)] outline-none focus:border-[var(--accent)]"
                    />
                    <Button type="submit" variant="secondary" size="xs" className="h-7 px-2">
                      <Plus size={12.5} />
                    </Button>
                  </form>

                  {asset.suggestedTags.length > 0 && (
                    <div className="pt-1 border-t border-[var(--border-hairline)] flex flex-col gap-1.5">
                      <div className="flex items-center justify-between">
                        <span className="text-[11px] text-[var(--text-tertiary)] inline-flex items-center gap-1">
                          <Sparkles size={11} className="text-[var(--accent)]" />
                          建议标签
                        </span>
                        <button
                          type="button"
                          onClick={() =>
                            void updateAssets(
                              { assetIDs: [asset.id], acceptSuggestedTags: true },
                              destination,
                            )
                          }
                          className="text-[11px] text-[var(--accent)] hover:underline cursor-pointer"
                        >
                          全部采纳
                        </button>
                      </div>
                      <div className="flex flex-wrap gap-1">
                        {asset.suggestedTags.map((st) => (
                          <button
                            key={st}
                            type="button"
                            onClick={() =>
                              void updateAssets(
                                {
                                  assetIDs: [asset.id],
                                  addTags: [st],
                                  dismissSuggestedTags: [st],
                                },
                                destination,
                              )
                            }
                            className="charkle-pressable h-6 px-2 rounded-full border border-dashed border-[var(--accent-ring)] text-[11px] text-[var(--accent)] hover:bg-[var(--accent-soft)] cursor-pointer"
                          >
                            + {st}
                          </button>
                        ))}
                      </div>
                    </div>
                  )}
                </InspectorCardShell>
              );
            }

            if (cardId === 'location') {
              const canRefreshRich = Boolean(
                asset.sourceURL &&
                  (asset.richMetadata?.githubRepo ||
                    asset.richMetadata?.socialPost ||
                    asset.mediaKind === 'webBookmark'),
              );
              return (
                <InspectorCardShell
                  key="location"
                  cardId="location"
                  title="归属与离线"
                  collapsed={collapsed}
                  onToggleCollapse={toggleCollapse}
                  onDragStart={(id) => {
                    draggedCardRef.current = id;
                  }}
                  onDropOn={handleDropCard}
                >
                  <div className="flex flex-col gap-1">
                    <span className="text-[11px] text-[var(--text-tertiary)]">所属文件夹</span>
                    <CustomSelect<string>
                      value={asset.folderID ?? '__inbox__'}
                      options={folderOptions}
                      onChange={(val) =>
                        void updateAssets(
                          {
                            assetIDs: [asset.id],
                            folderAssignment: val === '__inbox__' ? 'inbox' : { folder: val },
                          },
                          destination,
                        )
                      }
                      ariaLabel="所属文件夹"
                      size="xs"
                      className="w-full"
                    />
                  </div>

                  <label className="flex items-center justify-between text-[12px] text-[var(--text-primary)] cursor-pointer">
                    <span className="inline-flex items-center gap-1.5">
                      <Pin size={13} className="text-[var(--text-secondary)]" />
                      离线常驻原图
                    </span>
                    <input
                      type="checkbox"
                      checked={asset.pinnedOffline}
                      onChange={(e) =>
                        void updateAssets(
                          { assetIDs: [asset.id], pinnedOffline: e.target.checked },
                          destination,
                        )
                      }
                      className="accent-[var(--accent)] h-4 w-4 cursor-pointer"
                    />
                  </label>

                  <div className="flex items-center gap-1.5 flex-wrap pt-1">
                    <Button
                      variant="secondary"
                      size="xs"
                      onClick={() => void transport.revealInExplorer(asset.id)}
                    >
                      <FolderOpen size={12.5} />
                      打开位置
                    </Button>
                    {asset.sourceURL && (
                      <Button
                        variant="secondary"
                        size="xs"
                        onClick={() => void transport.openExternalUrl(asset.sourceURL!)}
                      >
                        <ExternalLink size={12.5} />
                        访问原链
                      </Button>
                    )}
                    {canRefreshRich && (
                      <Button
                        variant="secondary"
                        size="xs"
                        loading={refreshingRich}
                        onClick={async () => {
                          setRefreshingRich(true);
                          try {
                            await refreshRichAsset(asset.id);
                          } finally {
                            setRefreshingRich(false);
                          }
                        }}
                      >
                        <RefreshCw size={12} />
                        刷新摘要
                      </Button>
                    )}
                  </div>
                </InspectorCardShell>
              );
            }

            if (cardId === 'palette') {
              if (asset.dominantColors.length === 0) return null;
              return (
                <InspectorCardShell
                  key="palette"
                  cardId="palette"
                  title="主色板"
                  icon={<Palette size={12.5} className="text-[var(--text-tertiary)]" />}
                  collapsed={collapsed}
                  onToggleCollapse={toggleCollapse}
                  onDragStart={(id) => {
                    draggedCardRef.current = id;
                  }}
                  onDropOn={handleDropCard}
                >
                  <div className="flex flex-col gap-1.5">
                    {asset.dominantColors.slice(0, 6).map((color) => (
                      <div
                        key={color.hex}
                        className="flex items-center justify-between gap-2 text-[12px]"
                      >
                        <button
                          type="button"
                          onClick={() => void copyText(color.hex, `色值 ${color.hex}`)}
                          title="点击复制 HEX 色值"
                          className="charkle-pressable flex items-center gap-2 min-w-0 cursor-pointer hover:text-[var(--accent)]"
                        >
                          <span
                            className="h-5 w-5 rounded-[6px] border border-black/10 shrink-0"
                            style={{ backgroundColor: color.hex }}
                          />
                          <span className="charkle-mono text-[11.5px] text-[var(--text-primary)]">
                            {color.hex}
                          </span>
                          <span className="text-[11px] text-[var(--text-tertiary)] charkle-tabular">
                            {Math.round(color.proportion * 100)}%
                          </span>
                        </button>
                        <button
                          type="button"
                          onClick={() =>
                            void setCriteria({ selectedColorHex: color.hex }, destination)
                          }
                          className="text-[11px] text-[var(--accent)] hover:underline cursor-pointer shrink-0"
                        >
                          搜同色
                        </button>
                      </div>
                    ))}
                  </div>
                </InspectorCardShell>
              );
            }

            if (cardId === 'exif') {
              const exif = asset.richMetadata?.photoExif;
              if (!hasMeaningfulCameraExif(exif) || !exif) return null;
              return (
                <InspectorCardShell
                  key="exif"
                  cardId="exif"
                  title="拍摄参数"
                  icon={<Camera size={12.5} className="text-[var(--text-tertiary)]" />}
                  collapsed={collapsed}
                  onToggleCollapse={toggleCollapse}
                  onDragStart={(id) => {
                    draggedCardRef.current = id;
                  }}
                  onDropOn={handleDropCard}
                >
                  <dl className="grid grid-cols-[72px_1fr] gap-y-1.5 gap-x-2 text-[11.5px]">
                    {(exif.cameraMake || exif.cameraModel) && (
                      <>
                        <dt className="text-[var(--text-tertiary)]">相机</dt>
                        <dd className="text-[var(--text-primary)] charkle-wrap-safe">
                          {[exif.cameraMake, exif.cameraModel].filter(Boolean).join(' ')}
                        </dd>
                      </>
                    )}
                    {exif.lensModel && (
                      <>
                        <dt className="text-[var(--text-tertiary)]">镜头</dt>
                        <dd className="text-[var(--text-primary)] charkle-wrap-safe">
                          {exif.lensModel}
                        </dd>
                      </>
                    )}
                    {(exif.focalLengthMM || exif.fNumber || exif.exposureTime || exif.iso) && (
                      <>
                        <dt className="text-[var(--text-tertiary)]">曝光</dt>
                        <dd className="text-[var(--text-primary)] charkle-tabular">
                          {[
                            exif.focalLengthMM ? `${exif.focalLengthMM}mm` : null,
                            exif.fNumber ? `f/${exif.fNumber}` : null,
                            exif.exposureTime,
                            exif.iso ? `ISO ${exif.iso}` : null,
                          ]
                            .filter(Boolean)
                            .join(' · ')}
                        </dd>
                      </>
                    )}
                    {exif.capturedAt && (
                      <>
                        <dt className="text-[var(--text-tertiary)]">拍摄时间</dt>
                        <dd className="text-[var(--text-primary)] charkle-tabular">
                          {exif.capturedAt}
                        </dd>
                      </>
                    )}
                    {exif.software && (
                      <>
                        <dt className="text-[var(--text-tertiary)]">软件</dt>
                        <dd className="text-[var(--text-primary)] charkle-wrap-safe">
                          {exif.software}
                        </dd>
                      </>
                    )}
                  </dl>
                </InspectorCardShell>
              );
            }

            if (cardId === 'aiGen') {
              const ai = asset.richMetadata?.aiGeneration;
              if (!ai) return null;
              return (
                <InspectorCardShell
                  key="aiGen"
                  cardId="aiGen"
                  title="生成参数"
                  icon={<Sparkles size={12.5} className="text-[var(--text-tertiary)]" />}
                  collapsed={collapsed}
                  onToggleCollapse={toggleCollapse}
                  onDragStart={(id) => {
                    draggedCardRef.current = id;
                  }}
                  onDropOn={handleDropCard}
                >
                  {ai.prompt && (
                    <div className="flex flex-col gap-1">
                      <div className="flex items-center justify-between">
                        <span className="text-[11px] text-[var(--text-tertiary)]">正向提示词</span>
                        <button
                          type="button"
                          onClick={() => void copyText(ai.prompt!, '提示词')}
                          className="inline-flex items-center gap-1 text-[11px] text-[var(--accent)] hover:underline cursor-pointer"
                        >
                          <Copy size={11} />
                          复制
                        </button>
                      </div>
                      <p className="p-2 rounded-[var(--radius-card-inner)] bg-[var(--bg-inspector-field)] text-[11.5px] text-[var(--text-primary)] leading-relaxed charkle-wrap-safe">
                        {ai.prompt}
                      </p>
                    </div>
                  )}
                  {ai.negativePrompt && (
                    <div className="flex flex-col gap-1">
                      <span className="text-[11px] text-[var(--text-tertiary)]">负向提示词</span>
                      <p className="p-2 rounded-[var(--radius-card-inner)] bg-[var(--bg-inspector-field)] text-[11px] text-[var(--text-secondary)] leading-relaxed charkle-wrap-safe">
                        {ai.negativePrompt}
                      </p>
                    </div>
                  )}
                  <div className="flex flex-wrap gap-1.5 text-[11px] charkle-tabular">
                    {ai.generator && (
                      <span className="px-2 py-0.5 rounded bg-[var(--bg-subtle)] text-[var(--text-secondary)]">
                        {ai.generator}
                      </span>
                    )}
                    {ai.modelName && (
                      <span className="px-2 py-0.5 rounded bg-[var(--bg-subtle)] text-[var(--text-secondary)]">
                        {ai.modelName}
                      </span>
                    )}
                    {ai.sampler && (
                      <span className="px-2 py-0.5 rounded bg-[var(--bg-subtle)] text-[var(--text-secondary)]">
                        {ai.sampler}
                      </span>
                    )}
                    {ai.steps != null && (
                      <span className="px-2 py-0.5 rounded bg-[var(--bg-subtle)] text-[var(--text-secondary)]">
                        Steps {ai.steps}
                      </span>
                    )}
                    {ai.cfgScale != null && (
                      <span className="px-2 py-0.5 rounded bg-[var(--bg-subtle)] text-[var(--text-secondary)]">
                        CFG {ai.cfgScale}
                      </span>
                    )}
                    {ai.seed && (
                      <span className="px-2 py-0.5 rounded bg-[var(--bg-subtle)] text-[var(--text-secondary)]">
                        Seed {ai.seed}
                      </span>
                    )}
                  </div>
                </InspectorCardShell>
              );
            }

            if (cardId === 'similar') {
              return (
                <InspectorCardShell
                  key="similar"
                  cardId="similar"
                  title="相似灵感"
                  collapsed={collapsed}
                  onToggleCollapse={toggleCollapse}
                  onDragStart={(id) => {
                    draggedCardRef.current = id;
                  }}
                  onDropOn={handleDropCard}
                >
                  {showSimilarSkeleton ? (
                    <InspectorSimilarSkeleton />
                  ) : similar.length === 0 ? (
                    <div className="text-[11.5px] text-[var(--text-tertiary)]">暂无相似推荐</div>
                  ) : (
                    <div className="grid grid-cols-3 gap-1.5">
                      {similar.map((item) => (
                        <button
                          key={item.asset.id}
                          type="button"
                          title={item.asset.title}
                          onClick={() => setSelection([item.asset.id], item.asset.id)}
                          className="aspect-square rounded-[var(--radius-card-inner)] overflow-hidden bg-[var(--bg-subtle)] border border-[var(--border-hairline)] hover:border-[var(--accent)] cursor-pointer"
                        >
                          <img
                            src={transport.thumbnailUrl(item.asset.id, 'grid520')}
                            alt={item.asset.title}
                            loading="lazy"
                            className="w-full h-full object-cover"
                          />
                        </button>
                      ))}
                    </div>
                  )}
                </InspectorCardShell>
              );
            }

            return null;
          })
        )}
      </div>
    </aside>
  );
};
