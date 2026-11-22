import React, { useEffect, useMemo, useState } from 'react';
import {
  ArrowDownCircle,
  Check,
  Copy,
  Crop,
  ExternalLink,
  Eye,
  GitFork,
  Palette,
  RefreshCw,
  RotateCcw,
  Sparkles,
  Star,
  Tag,
  Trash2,
  X,
} from 'lucide-react';
import {
  createDefaultAssetBatchPatch,
  getAssetDisplayTypeLabel,
  getEffectiveSocialAttachments,
  socialPlatformDisplayName,
} from '@charkle/shared';
import type { AssetRecord, ScoredAsset, UUID } from '@charkle/shared';
import { apiClient } from '../../api/client';
import {
  Button,
  CharkleIcon,
  computeAmbientTintStyle,
  formatBytes,
  getGitHubLanguageColor,
  useResolvedIsDark,
} from '../../design-system';
import { useCoordinatorStore } from '../../stores/coordinatorStore';
import { useLibraryStore } from '../../stores/libraryStore';
import { useMoodboardStore } from '../../stores/moodboardStore';

export const InspectorView: React.FC = () => {
  const inspectorOpen = useCoordinatorStore((s) => s.inspectorOpen);
  const destination = useCoordinatorStore((s) => s.destination);
  const activeBoardID = useCoordinatorStore((s) => s.activeBoardID);
  const openQuickLook = useCoordinatorStore((s) => s.openQuickLook);
  const openGeneratorModal = useCoordinatorStore((s) => s.openGeneratorModal);
  const pushToast = useCoordinatorStore((s) => s.pushToast);

  const assets = useLibraryStore((s) => s.assets);
  const assetsByID = useLibraryStore((s) => s.assetsByID);
  const folders = useLibraryStore((s) => s.folders);
  const selectedAssetIDs = useLibraryStore((s) => s.selectedAssetIDs);
  const cacheBust = useLibraryStore((s) => s.cacheBustVersion);
  const batchPatch = useLibraryStore((s) => s.batchPatch);
  const trashAssets = useLibraryStore((s) => s.trashAssets);
  const restoreAssets = useLibraryStore((s) => s.restoreAssets);
  const permanentlyDeleteAssets = useLibraryStore((s) => s.permanentlyDeleteAssets);
  const refreshRichAsset = useLibraryStore((s) => s.refreshRichAsset);
  const extractSocialMedia = useLibraryStore((s) => s.extractSocialMedia);
  const setCriteria = useLibraryStore((s) => s.setCriteria);
  const setShowVisualFilterBar = useLibraryStore((s) => s.setShowVisualFilterBar);
  const selectAsset = useLibraryStore((s) => s.selectAsset);
  const upsertAssets = useLibraryStore((s) => s.upsertAssets);

  const boards = useMoodboardStore((s) => s.boards);
  const addAssetsToBoard = useMoodboardStore((s) => s.addAssetsToBoard);

  const isDark = useResolvedIsDark();

  const [tab, setTab] = useState<'info' | 'similar'>('info');
  const [titleDraft, setTitleDraft] = useState('');
  const [notesDraft, setNotesDraft] = useState('');
  const [tagInput, setTagInput] = useState('');
  const [batchTagInput, setBatchTagInput] = useState('');

  const [similarItems, setSimilarItems] = useState<ScoredAsset[]>([]);
  const [loadingSimilar, setLoadingSimilar] = useState(false);
  const [busyAction, setBusyAction] = useState<string | null>(null);

  const selectedAssets: AssetRecord[] = useMemo(() => {
    const result: AssetRecord[] = [];
    for (const id of selectedAssetIDs) {
      const found = assetsByID[id] ?? assets.find((a) => a.id === id);
      if (found) result.push(found);
    }
    return result;
  }, [selectedAssetIDs, assetsByID, assets]);

  const singleAsset = selectedAssets.length === 1 ? selectedAssets[0] : null;
  const activeBoard = boards.find((b) => b.id === activeBoardID) ?? boards[0] ?? null;

  useEffect(() => {
    if (!singleAsset) return;
    setTitleDraft(singleAsset.title);
    setNotesDraft(singleAsset.notes);
  }, [singleAsset?.id, singleAsset?.title, singleAsset?.notes]);

  useEffect(() => {
    if (!singleAsset || tab !== 'similar') return;
    let cancelled = false;
    setLoadingSimilar(true);
    apiClient
      .getSimilarAssets(singleAsset.id, 12)
      .then((res) => {
        if (!cancelled) {
          setSimilarItems(res.items);
          setLoadingSimilar(false);
        }
      })
      .catch(() => {
        if (!cancelled) setLoadingSimilar(false);
      });
    return () => {
      cancelled = true;
    };
  }, [singleAsset?.id, tab]);

  if (!inspectorOpen) return null;
  // Moodboard workspace has its own studio Candidate Pool panel
  if (destination.type === 'moodboard') return null;

  const commitTitle = async () => {
    if (!singleAsset) return;
    const trimmed = titleDraft.trim();
    if (!trimmed || trimmed === singleAsset.title) {
      setTitleDraft(singleAsset.title);
      return;
    }
    await batchPatch(createDefaultAssetBatchPatch([singleAsset.id], { title: trimmed }));
  };

  const commitNotes = async () => {
    if (!singleAsset) return;
    if (notesDraft === singleAsset.notes) return;
    await batchPatch(createDefaultAssetBatchPatch([singleAsset.id], { notes: notesDraft }));
  };

  const handleCopyHex = async (hex: string) => {
    try {
      await navigator.clipboard.writeText(hex);
      pushToast({ tone: 'info', message: `已复制色值 ${hex}` });
    } catch {
      pushToast({ tone: 'info', message: hex });
    }
  };

  const handleFilterByColor = (hex: string) => {
    setShowVisualFilterBar(true);
    setCriteria({ selectedColorHex: hex });
    pushToast({ tone: 'info', message: `已按色值 ${hex} 反向检索素材库` });
  };

  const handleAddTag = async (ids: UUID[], raw: string, clearFn: () => void) => {
    const cleaned = raw.trim().replace(/^#+/, '');
    if (!cleaned) return;
    clearFn();
    await batchPatch(createDefaultAssetBatchPatch(ids, { addTags: [cleaned] }));
  };

  const handleAnalyzeAI = async (ids: UUID[]) => {
    setBusyAction('ai-analyze');
    try {
      const res = await apiClient.analyzeAssets({ ids });
      upsertAssets(res.assets);
      pushToast({ tone: 'success', message: `已完成 ${res.assets.length} 项素材 AI 分析与标签建议` });
    } catch (err) {
      pushToast({ tone: 'error', message: err instanceof Error ? err.message : 'AI 分析失败' });
    } finally {
      setBusyAction(null);
    }
  };

  const handleSubjectPalette = async (asset: AssetRecord) => {
    setBusyAction('subject-palette');
    try {
      const res = await apiClient.extractSubjectPalette({ assetID: asset.id });
      upsertAssets([res.result.updatedAsset]);
      pushToast({
        tone: 'success',
        message: `已按主体区域重新提取 ${res.result.colors.length} 个主色`,
      });
    } catch (err) {
      pushToast({ tone: 'error', message: err instanceof Error ? err.message : '主体色板提取失败' });
    } finally {
      setBusyAction(null);
    }
  };

  const handleCleanBounds = async (asset: AssetRecord) => {
    setBusyAction('clean-bounds');
    try {
      const res = await apiClient.detectCleanBounds(asset.id);
      pushToast({
        tone: 'info',
        message: res.result.hasNoise
          ? `检测到杂边/水印区域：${res.result.summary}`
          : `画面边缘干净：${res.result.summary}`,
      });
    } catch (err) {
      pushToast({ tone: 'error', message: err instanceof Error ? err.message : '自动去杂边检测失败' });
    } finally {
      setBusyAction(null);
    }
  };

  const ambientStyle = singleAsset
    ? computeAmbientTintStyle(singleAsset.dominantColors[0]?.hex, isDark, 'inspector')
    : {};

  return (
    <aside className="relative w-[300px] shrink-0 h-full bg-[var(--bg-inspector)] border-l border-[var(--border-hairline)] flex flex-col overflow-hidden">
      {/* Ultra-subtle top 200px ambient tint strictly in Single Asset mode */}
      {singleAsset && (
        <div
          aria-hidden="true"
          className="pointer-events-none absolute inset-x-0 top-0 h-[200px] z-0"
          style={ambientStyle}
        />
      )}

      {/* Mode 1: Single Asset Inspector */}
      {singleAsset ? (
        <div className="relative z-10 flex-1 min-h-0 flex flex-col">
          {/* Segmented Header */}
          <div className="px-3.5 pt-3 pb-2 shrink-0 flex items-center justify-between gap-2 border-b border-[var(--border-hairline)]">
            <div className="inline-flex flex-1 p-0.5 rounded-[var(--radius-chip)] bg-[var(--bg-subtle)]/90 border border-[var(--border-hairline)]">
              {(['info', 'similar'] as const).map((t) => (
                <button
                  key={t}
                  type="button"
                  onClick={() => setTab(t)}
                  className={[
                    'charkle-pressable flex-1 py-1 text-[12px] font-medium rounded-[6px] cursor-pointer',
                    tab === t
                      ? 'bg-[var(--bg-elevated)] text-[var(--text-primary)] shadow-xs'
                      : 'text-[var(--text-secondary)] hover:text-[var(--text-primary)]',
                  ].join(' ')}
                >
                  {t === 'info' ? '信息' : '类似项目'}
                </button>
              ))}
            </div>
          </div>

          {tab === 'similar' ? (
            <div className="flex-1 overflow-y-auto charkle-scroll p-3">
              {loadingSimilar ? (
                <div className="py-12 flex items-center justify-center gap-2 text-[12.5px] text-[var(--text-secondary)]">
                  <span className="h-3.5 w-3.5 rounded-full border-2 border-[var(--accent)] border-t-transparent animate-spin" />
                  检索相似视觉素材…
                </div>
              ) : similarItems.length === 0 ? (
                <div className="py-10 text-center text-[12.5px] text-[var(--text-secondary)]">
                  暂未找到高相似度的其它素材
                </div>
              ) : (
                <div className="grid grid-cols-2 gap-2">
                  {similarItems.map((item) => (
                    <button
                      key={item.asset.id}
                      type="button"
                      title={item.matchReasons.join(' · ') || item.asset.title}
                      onClick={() => selectAsset(item.asset.id, 'replace')}
                      onDoubleClick={() => openQuickLook(item.asset.id)}
                      className="group relative aspect-square overflow-hidden rounded-[var(--radius-settings-inner)] bg-[var(--bg-subtle)] border border-[var(--border-hairline)] cursor-pointer text-left"
                    >
                      <img
                        src={apiClient.thumbnailURL(item.asset.id, 'grid520', cacheBust)}
                        alt={item.asset.title}
                        className="w-full h-full object-cover charkle-media-zoom"
                      />
                      <span className="absolute bottom-1 right-1 px-1.5 py-0.5 rounded bg-black/60 text-white text-[10px] font-mono">
                        {Math.round(item.score * 100)}%
                      </span>
                    </button>
                  ))}
                </div>
              )}
            </div>
          ) : (
            <div className="flex-1 overflow-y-auto charkle-scroll p-3.5 flex flex-col gap-3.5">
              {/* Preview Card + Identity */}
              <div className="flex flex-col gap-2.5">
                <div
                  onClick={() => openQuickLook(singleAsset.id)}
                  className="group relative aspect-[16/10] w-full overflow-hidden rounded-[var(--radius-card-outer)] bg-[var(--bg-subtle)] border border-[var(--border-hairline)] cursor-zoom-in"
                >
                  <img
                    src={apiClient.thumbnailURL(
                      singleAsset.id,
                      'grid520',
                      `${singleAsset.updatedAt}-${cacheBust}`,
                    )}
                    alt={singleAsset.title}
                    className="w-full h-full object-contain bg-black/5"
                  />
                  <span className="absolute bottom-2 right-2 px-2 py-0.5 rounded-[var(--radius-card-inner)] bg-black/60 text-white text-[11px] inline-flex items-center gap-1 opacity-0 group-hover:opacity-100 transition-opacity">
                    <Eye size={11} />
                    Space 预览
                  </span>
                </div>

                {/* Inline Title */}
                <input
                  type="text"
                  value={titleDraft}
                  onChange={(e) => setTitleDraft(e.target.value)}
                  onBlur={() => void commitTitle()}
                  onKeyDown={(e) => {
                    if (e.key === 'Enter') (e.target as HTMLInputElement).blur();
                  }}
                  className="w-full px-2 py-1 text-[13.5px] font-semibold rounded-[var(--radius-chip)] bg-transparent hover:bg-[var(--bg-inspector-field)] focus:bg-[var(--bg-elevated)] border border-transparent focus:border-[var(--accent)] text-[var(--text-primary)] focus:outline-none"
                />

                {/* Star Rating + Pin Offline */}
                <div className="flex items-center justify-between gap-2 px-1">
                  <div className="flex items-center gap-0.5">
                    {[1, 2, 3, 4, 5].map((star) => (
                      <button
                        key={star}
                        type="button"
                        onClick={() =>
                          void batchPatch(
                            createDefaultAssetBatchPatch([singleAsset.id], {
                              rating: singleAsset.rating === star ? 0 : star,
                            }),
                          )
                        }
                        className="charkle-pressable p-0.5 cursor-pointer"
                      >
                        <Star
                          size={15}
                          className={
                            singleAsset.rating >= star
                              ? 'fill-[#F2C14E] text-[#F2C14E] charkle-micro-pop'
                              : 'text-[var(--text-tertiary)]'
                          }
                        />
                      </button>
                    ))}
                  </div>

                  <button
                    type="button"
                    onClick={() =>
                      void batchPatch(
                        createDefaultAssetBatchPatch([singleAsset.id], {
                          pinnedOffline: !singleAsset.pinnedOffline,
                        }),
                      )
                    }
                    className={[
                      'charkle-pressable inline-flex items-center gap-1 px-2 py-1 rounded-[var(--radius-chip)] text-[11.5px] font-medium cursor-pointer',
                      singleAsset.pinnedOffline
                        ? 'bg-[var(--accent-soft)] text-[var(--accent)]'
                        : 'bg-[var(--bg-subtle)] text-[var(--text-secondary)] hover:text-[var(--text-primary)]',
                    ].join(' ')}
                  >
                    <ArrowDownCircle size={12} />
                    {singleAsset.pinnedOffline ? '已离线保留' : '保留离线'}
                  </button>
                </div>
              </div>

              {/* Quick Actions & Folder Assignment */}
              <div className="flex flex-col gap-2 p-2.5 rounded-[var(--radius-settings-outer)] bg-[var(--bg-elevated)]/80 border border-[var(--border-hairline)]">
                <div className="flex items-center gap-2">
                  <span className="text-[11.5px] text-[var(--text-secondary)] shrink-0">位置</span>
                  <select
                    value={singleAsset.folderID ?? ''}
                    onChange={(e) => {
                      const val = e.target.value;
                      void batchPatch(
                        createDefaultAssetBatchPatch([singleAsset.id], {
                          folderAssignment: val
                            ? { type: 'folder', folderID: val }
                            : { type: 'inbox' },
                        }),
                      );
                    }}
                    className="flex-1 min-w-0 h-7 px-2 text-[12px] rounded-[var(--radius-chip)] bg-[var(--bg-inspector-field)] border border-[var(--border-hairline)] text-[var(--text-primary)] focus:outline-none focus:border-[var(--accent)]"
                  >
                    <option value="">收件箱</option>
                    {folders.map((f) => (
                      <option key={f.id} value={f.id}>
                        {f.name}
                      </option>
                    ))}
                  </select>
                </div>

                <div className="flex items-center gap-1.5">
                  <Button
                    variant="secondary"
                    size="xs"
                    className="flex-1 justify-center"
                    onClick={async () => {
                      if (!activeBoard) {
                        openGeneratorModal([singleAsset.id]);
                        return;
                      }
                      await addAssetsToBoard(activeBoard.id, [singleAsset.id]);
                      pushToast({
                        tone: 'success',
                        message: `已加入情绪板「${activeBoard.title}」`,
                      });
                    }}
                  >
                    <CharkleIcon name="moodboard" size={14} />
                    加入情绪板
                  </Button>

                  {singleAsset.isTrashed ? (
                    <>
                      <Button
                        variant="secondary"
                        size="xs"
                        onClick={() => void restoreAssets([singleAsset.id])}
                      >
                        <RotateCcw size={12} />
                        恢复
                      </Button>
                      <Button
                        variant="danger"
                        size="xs"
                        onClick={() => void permanentlyDeleteAssets([singleAsset.id])}
                      >
                        <Trash2 size={12} />
                      </Button>
                    </>
                  ) : (
                    <Button
                      variant="ghost"
                      size="xs"
                      onClick={() => void trashAssets([singleAsset.id])}
                      title="移入回收站"
                    >
                      <Trash2 size={13} className="text-[var(--danger)]" />
                    </Button>
                  )}
                </div>
              </div>

              {/* CIELAB Palette + TypeSafe Jev Grounding Tools */}
              <div className="flex flex-col gap-2 p-2.5 rounded-[var(--radius-settings-outer)] bg-[var(--bg-elevated)]/80 border border-[var(--border-hairline)]">
                <div className="flex items-center justify-between">
                  <span className="text-[11.5px] font-semibold text-[var(--text-secondary)]">
                    CIELAB 色板
                  </span>
                  <span className="text-[10.5px] text-[var(--text-tertiary)]">
                    点击复制 · 右键搜色
                  </span>
                </div>

                {singleAsset.dominantColors.length > 0 ? (
                  <div className="flex items-center gap-1.5">
                    {singleAsset.dominantColors.slice(0, 6).map((swatch) => (
                      <button
                        key={swatch.hex}
                        type="button"
                        title={`${swatch.hex}（左键复制 / 右键按色检索）`}
                        onClick={() => void handleCopyHex(swatch.hex)}
                        onContextMenu={(e) => {
                          e.preventDefault();
                          handleFilterByColor(swatch.hex);
                        }}
                        className="charkle-pressable flex-1 h-7 rounded-[6px] border border-black/10 cursor-pointer relative group"
                        style={{ backgroundColor: swatch.hex }}
                      >
                        <span className="sr-only">{swatch.hex}</span>
                      </button>
                    ))}
                  </div>
                ) : (
                  <div className="text-[11.5px] text-[var(--text-tertiary)]">暂无主色数据</div>
                )}

                {(singleAsset.mediaKind === 'image' ||
                  singleAsset.mediaKind === 'animatedImage' ||
                  singleAsset.mediaKind === 'designFile') && (
                  <div className="flex items-center gap-1.5 pt-1">
                    <Button
                      variant="ghost"
                      size="xs"
                      loading={busyAction === 'subject-palette'}
                      onClick={() => void handleSubjectPalette(singleAsset)}
                      className="flex-1 justify-center bg-[var(--bg-subtle)]/70"
                    >
                      <Palette size={12} />
                      按主体重提
                    </Button>
                    <Button
                      variant="ghost"
                      size="xs"
                      loading={busyAction === 'clean-bounds'}
                      onClick={() => void handleCleanBounds(singleAsset)}
                      className="flex-1 justify-center bg-[var(--bg-subtle)]/70"
                    >
                      <Crop size={12} />
                      自动去杂边
                    </Button>
                  </div>
                )}
              </div>

              {/* Tags + AI Suggested Tags */}
              <div className="flex flex-col gap-2 p-2.5 rounded-[var(--radius-settings-outer)] bg-[var(--bg-elevated)]/80 border border-[var(--border-hairline)]">
                <div className="flex items-center justify-between">
                  <span className="text-[11.5px] font-semibold text-[var(--text-secondary)]">
                    标签
                  </span>
                  <button
                    type="button"
                    disabled={busyAction === 'ai-analyze'}
                    onClick={() => void handleAnalyzeAI([singleAsset.id])}
                    className="charkle-pressable inline-flex items-center gap-1 text-[11px] font-medium text-[var(--accent)] hover:underline cursor-pointer disabled:opacity-50"
                  >
                    <Sparkles size={11} />
                    {busyAction === 'ai-analyze' ? '分析中…' : 'AI 建议标签'}
                  </button>
                </div>

                <div className="flex flex-wrap gap-1">
                  {singleAsset.tags.map((tag) => (
                    <span
                      key={tag}
                      className="inline-flex items-center gap-1 px-2 py-0.5 rounded-[var(--radius-chip)] bg-[var(--bg-subtle)] text-[11.5px] text-[var(--text-primary)]"
                    >
                      #{tag}
                      <button
                        type="button"
                        onClick={() =>
                          void batchPatch(
                            createDefaultAssetBatchPatch([singleAsset.id], { removeTags: [tag] }),
                          )
                        }
                        className="text-[var(--text-tertiary)] hover:text-[var(--danger)] cursor-pointer"
                      >
                        <X size={10} />
                      </button>
                    </span>
                  ))}
                </div>

                <input
                  type="text"
                  value={tagInput}
                  onChange={(e) => setTagInput(e.target.value)}
                  onKeyDown={(e) => {
                    if (e.key === 'Enter') {
                      e.preventDefault();
                      void handleAddTag([singleAsset.id], tagInput, () => setTagInput(''));
                    }
                  }}
                  placeholder="添加标签，回车确认…"
                  className="h-7.5 px-2.5 text-[12px] rounded-[var(--radius-chip)] bg-[var(--bg-inspector-field)] border border-[var(--border-hairline)] text-[var(--text-primary)] focus:outline-none focus:border-[var(--accent)]"
                />

                {singleAsset.suggestedTags.length > 0 && (
                  <div className="pt-1.5 border-t border-[var(--border-hairline)] flex flex-col gap-1.5">
                    <div className="flex items-center justify-between text-[11px]">
                      <span className="text-[var(--text-tertiary)]">AI 推荐标签</span>
                      <button
                        type="button"
                        onClick={() =>
                          void batchPatch(
                            createDefaultAssetBatchPatch([singleAsset.id], {
                              acceptSuggestedTags: true,
                            }),
                          )
                        }
                        className="text-[var(--accent)] hover:underline cursor-pointer"
                      >
                        全部采纳
                      </button>
                    </div>
                    <div className="flex flex-wrap gap-1">
                      {singleAsset.suggestedTags.map((sug) => (
                        <span
                          key={sug}
                          className="inline-flex items-center gap-1 pl-2 pr-1 py-0.5 rounded-[var(--radius-chip)] bg-[var(--accent-soft)] text-[var(--accent)] text-[11.5px]"
                        >
                          <button
                            type="button"
                            onClick={() =>
                              void batchPatch(
                                createDefaultAssetBatchPatch([singleAsset.id], {
                                  addTags: [sug],
                                  dismissSuggestedTags: [sug],
                                }),
                              )
                            }
                            className="inline-flex items-center gap-0.5 cursor-pointer"
                            title="采纳标签"
                          >
                            <Check size={10} />
                            {sug}
                          </button>
                          <button
                            type="button"
                            onClick={() =>
                              void batchPatch(
                                createDefaultAssetBatchPatch([singleAsset.id], {
                                  dismissSuggestedTags: [sug],
                                }),
                              )
                            }
                            className="p-0.5 opacity-65 hover:opacity-100 cursor-pointer"
                            title="忽略"
                          >
                            <X size={10} />
                          </button>
                        </span>
                      ))}
                    </div>
                  </div>
                )}
              </div>

              {/* Conditional Rich GitHub Repo Card */}
              {singleAsset.richMetadata?.githubRepo && (
                <div className="flex flex-col gap-2 p-2.5 rounded-[var(--radius-settings-outer)] bg-[#14171D] text-[#E6EDF3] border border-white/10">
                  <div className="flex items-center justify-between gap-2">
                    <span className="text-[12px] font-semibold truncate">
                      {singleAsset.richMetadata.githubRepo.fullName}
                    </span>
                    <button
                      type="button"
                      title="刷新仓库元数据"
                      onClick={async () => {
                        setBusyAction('refresh-rich');
                        try {
                          await refreshRichAsset(singleAsset.id);
                          pushToast({ tone: 'success', message: '已刷新 GitHub 仓库信息' });
                        } finally {
                          setBusyAction(null);
                        }
                      }}
                      className="p-1 rounded hover:bg-white/10 cursor-pointer"
                    >
                      <RefreshCw
                        size={12}
                        className={busyAction === 'refresh-rich' ? 'animate-spin' : ''}
                      />
                    </button>
                  </div>
                  <div className="flex items-center gap-3 text-[11px] text-[#9CA3AF]">
                    <span className="inline-flex items-center gap-1">
                      <Star size={11} className="text-[#F2C14E]" />
                      {singleAsset.richMetadata.githubRepo.stars.toLocaleString()}
                    </span>
                    <span className="inline-flex items-center gap-1">
                      <GitFork size={11} />
                      {singleAsset.richMetadata.githubRepo.forks.toLocaleString()}
                    </span>
                    {singleAsset.richMetadata.githubRepo.language && (
                      <span className="inline-flex items-center gap-1">
                        <span
                          className="h-2 w-2 rounded-full"
                          style={{
                            backgroundColor: getGitHubLanguageColor(
                              singleAsset.richMetadata.githubRepo.language,
                            ),
                          }}
                        />
                        {singleAsset.richMetadata.githubRepo.language}
                      </span>
                    )}
                  </div>
                  <div className="flex items-center gap-1.5">
                    <Button
                      variant="secondary"
                      size="xs"
                      className="flex-1 justify-center bg-white/10 border-white/10 text-white hover:bg-white/16"
                      onClick={() => openQuickLook(singleAsset.id)}
                    >
                      阅读 README
                    </Button>
                    {singleAsset.sourceURL && (
                      <a
                        href={singleAsset.sourceURL}
                        target="_blank"
                        rel="noreferrer"
                        className="h-7 px-2 inline-flex items-center justify-center rounded-[var(--radius-chip)] bg-white/10 hover:bg-white/16 text-white"
                      >
                        <ExternalLink size={12} />
                      </a>
                    )}
                  </div>
                </div>
              )}

              {/* Conditional Rich Social Post Media Extraction Card */}
              {singleAsset.richMetadata?.socialPost && (() => {
                const post = singleAsset.richMetadata.socialPost;
                const attachments = getEffectiveSocialAttachments(post);
                return (
                  <div className="flex flex-col gap-2 p-2.5 rounded-[var(--radius-settings-outer)] bg-[var(--bg-elevated)]/80 border border-[var(--border-hairline)]">
                    <div className="flex items-center justify-between">
                      <span className="text-[11.5px] font-semibold text-[var(--text-primary)]">
                        {socialPlatformDisplayName(post.platform)} · @{post.authorHandle}
                      </span>
                      <button
                        type="button"
                        title="重新抓取推文与媒体"
                        onClick={async () => {
                          setBusyAction('refresh-rich');
                          try {
                            await refreshRichAsset(singleAsset.id);
                            pushToast({ tone: 'success', message: '已刷新推文内容与媒体' });
                          } finally {
                            setBusyAction(null);
                          }
                        }}
                        className="p-1 text-[var(--text-secondary)] hover:text-[var(--text-primary)] cursor-pointer"
                      >
                        <RefreshCw
                          size={12}
                          className={busyAction === 'refresh-rich' ? 'animate-spin' : ''}
                        />
                      </button>
                    </div>
                    {post.mediaFetchFailed && (
                      <div className="px-2 py-1.5 rounded-[6px] bg-[var(--warning-soft)] text-[var(--warning)] text-[11px] flex items-center justify-between">
                        <span>部分附件抓取失败</span>
                        <button
                          type="button"
                          onClick={() => void refreshRichAsset(singleAsset.id)}
                          className="font-semibold underline cursor-pointer"
                        >
                          重试获取
                        </button>
                      </div>
                    )}
                    {attachments.length > 0 && (
                      <Button
                        variant="secondary"
                        size="xs"
                        loading={busyAction === 'extract-social'}
                        onClick={async () => {
                          setBusyAction('extract-social');
                          try {
                            await extractSocialMedia(singleAsset.id, null);
                          } finally {
                            setBusyAction(null);
                          }
                        }}
                        className="w-full justify-center"
                      >
                        提取全部媒体为独立素材 ({attachments.length})
                      </Button>
                    )}
                  </div>
                );
              })()}

              {/* Notes & AI Description */}
              <div className="flex flex-col gap-1.5">
                <label className="text-[11.5px] font-semibold text-[var(--text-secondary)]">
                  备注
                </label>
                <textarea
                  rows={3}
                  value={notesDraft}
                  onChange={(e) => setNotesDraft(e.target.value)}
                  onBlur={() => void commitNotes()}
                  placeholder="记录设计思路、出处或使用笔记…"
                  className="w-full p-2.5 text-[12px] leading-relaxed rounded-[var(--radius-settings-inner)] bg-[var(--bg-inspector-field)] border border-[var(--border-hairline)] text-[var(--text-primary)] placeholder:text-[var(--text-tertiary)] focus:outline-none focus:border-[var(--accent)] resize-y"
                />
              </div>

              {singleAsset.aiDescription && (
                <div className="p-2.5 rounded-[var(--radius-settings-inner)] bg-[var(--bg-elevated)]/60 border border-[var(--border-hairline)]">
                  <div className="text-[11px] font-semibold text-[var(--text-tertiary)] mb-1">
                    AI 视觉描述
                  </div>
                  <p className="text-[12px] text-[var(--text-secondary)] leading-relaxed">
                    {singleAsset.aiDescription}
                  </p>
                </div>
              )}

              {/* Metadata Grid */}
              <div className="grid grid-cols-2 gap-x-3 gap-y-2 p-2.5 rounded-[var(--radius-settings-outer)] bg-[var(--bg-elevated)]/60 border border-[var(--border-hairline)] text-[11.5px]">
                <div>
                  <div className="text-[var(--text-tertiary)]">类型</div>
                  <div className="text-[var(--text-primary)] font-medium truncate">
                    {getAssetDisplayTypeLabel(singleAsset)}
                  </div>
                </div>
                <div>
                  <div className="text-[var(--text-tertiary)]">尺寸</div>
                  <div className="text-[var(--text-primary)] font-mono">
                    {singleAsset.pixelWidth > 0
                      ? `${singleAsset.pixelWidth}×${singleAsset.pixelHeight}`
                      : '—'}
                  </div>
                </div>
                <div>
                  <div className="text-[var(--text-tertiary)]">大小</div>
                  <div className="text-[var(--text-primary)] font-mono">
                    {formatBytes(singleAsset.fileSizeBytes)}
                  </div>
                </div>
                <div>
                  <div className="text-[var(--text-tertiary)]">添加时间</div>
                  <div className="text-[var(--text-primary)]">
                    {new Date(singleAsset.createdAt).toLocaleDateString('zh-CN')}
                  </div>
                </div>
                {singleAsset.sourceURL && (
                  <div className="col-span-2">
                    <div className="text-[var(--text-tertiary)]">来源链接</div>
                    <a
                      href={singleAsset.sourceURL}
                      target="_blank"
                      rel="noreferrer"
                      className="text-[var(--accent)] hover:underline truncate block"
                    >
                      {singleAsset.sourceDomain || singleAsset.sourceURL}
                    </a>
                  </div>
                )}
                {singleAsset.contentHash && (
                  <div className="col-span-2 flex items-center justify-between gap-2">
                    <span className="text-[var(--text-tertiary)] font-mono truncate">
                      SHA: {singleAsset.contentHash.slice(0, 12)}
                    </span>
                    <button
                      type="button"
                      onClick={() => void handleCopyHex(singleAsset.contentHash)}
                      className="text-[var(--text-tertiary)] hover:text-[var(--text-primary)] cursor-pointer"
                      title="复制完整哈希"
                    >
                      <Copy size={11} />
                    </button>
                  </div>
                )}
              </div>
            </div>
          )}
        </div>
      ) : selectedAssets.length >= 2 ? (
        /* Mode 2: Multi-Select Batch Edit */
        <div className="flex-1 overflow-y-auto charkle-scroll p-4 flex flex-col gap-4">
          <div>
            <h2 className="text-[15px] font-semibold text-[var(--text-primary)]">
              批量编辑 {selectedAssets.length} 项素材
            </h2>
            <p className="text-[12px] text-[var(--text-secondary)] mt-0.5">
              总体积 {formatBytes(selectedAssets.reduce((sum, a) => sum + a.fileSizeBytes, 0))}
            </p>
          </div>

          <div className="flex flex-col gap-2">
            <Button
              variant="primary"
              size="sm"
              className="w-full justify-center"
              onClick={() => openGeneratorModal(selectedAssets.map((a) => a.id))}
            >
              <Sparkles size={14} />
              用选中素材生成情绪板
            </Button>
            {activeBoard && (
              <Button
                variant="secondary"
                size="sm"
                className="w-full justify-center"
                onClick={async () => {
                  await addAssetsToBoard(
                    activeBoard.id,
                    selectedAssets.map((a) => a.id),
                  );
                  pushToast({
                    tone: 'success',
                    message: `已将 ${selectedAssets.length} 项加入「${activeBoard.title}」`,
                  });
                }}
              >
                加入「{activeBoard.title}」
              </Button>
            )}
          </div>

          <div className="flex flex-col gap-2 p-3 rounded-[var(--radius-settings-outer)] bg-[var(--bg-elevated)] border border-[var(--border-hairline)]">
            <label className="text-[11.5px] font-semibold text-[var(--text-secondary)]">
              批量移动到文件夹
            </label>
            <select
              defaultValue=""
              onChange={(e) => {
                const val = e.target.value;
                if (!val) return;
                const ids = selectedAssets.map((a) => a.id);
                void batchPatch(
                  createDefaultAssetBatchPatch(ids, {
                    folderAssignment:
                      val === '__inbox__' ? { type: 'inbox' } : { type: 'folder', folderID: val },
                  }),
                );
                e.target.value = '';
              }}
              className="h-8 px-2 text-[12.5px] rounded-[var(--radius-chip)] bg-[var(--bg-inspector-field)] border border-[var(--border-hairline)] text-[var(--text-primary)]"
            >
              <option value="" disabled>
                选择目标文件夹…
              </option>
              <option value="__inbox__">收件箱</option>
              {folders.map((f) => (
                <option key={f.id} value={f.id}>
                  {f.name}
                </option>
              ))}
            </select>
          </div>

          <div className="flex flex-col gap-2 p-3 rounded-[var(--radius-settings-outer)] bg-[var(--bg-elevated)] border border-[var(--border-hairline)]">
            <label className="text-[11.5px] font-semibold text-[var(--text-secondary)]">
              批量追加标签
            </label>
            <div className="flex gap-1.5">
              <input
                type="text"
                value={batchTagInput}
                onChange={(e) => setBatchTagInput(e.target.value)}
                onKeyDown={(e) => {
                  if (e.key === 'Enter') {
                    void handleAddTag(
                      selectedAssets.map((a) => a.id),
                      batchTagInput,
                      () => setBatchTagInput(''),
                    );
                  }
                }}
                placeholder="输入标签名…"
                className="flex-1 min-w-0 h-8 px-2.5 text-[12px] rounded-[var(--radius-chip)] bg-[var(--bg-inspector-field)] border border-[var(--border-hairline)] text-[var(--text-primary)]"
              />
              <Button
                variant="secondary"
                size="xs"
                onClick={() =>
                  void handleAddTag(
                    selectedAssets.map((a) => a.id),
                    batchTagInput,
                    () => setBatchTagInput(''),
                  )
                }
              >
                <Tag size={12} />
              </Button>
            </div>

            <Button
              variant="ghost"
              size="xs"
              loading={busyAction === 'ai-analyze'}
              onClick={() => void handleAnalyzeAI(selectedAssets.map((a) => a.id))}
              className="w-full justify-center bg-[var(--accent-soft)] text-[var(--accent)] mt-1"
            >
              <Sparkles size={12} />
              批量 AI 智能分析与打标
            </Button>
          </div>

          <div className="flex flex-col gap-2 p-3 rounded-[var(--radius-settings-outer)] bg-[var(--bg-elevated)] border border-[var(--border-hairline)]">
            <span className="text-[11.5px] font-semibold text-[var(--text-secondary)]">
              批量星级评分
            </span>
            <div className="flex items-center gap-1">
              {[1, 2, 3, 4, 5].map((star) => (
                <button
                  key={star}
                  type="button"
                  onClick={() =>
                    void batchPatch(
                      createDefaultAssetBatchPatch(
                        selectedAssets.map((a) => a.id),
                        { rating: star },
                      ),
                    )
                  }
                  className="charkle-pressable p-1 cursor-pointer hover:bg-[var(--bg-subtle)] rounded"
                >
                  <Star size={16} className="text-[#F2C14E]" />
                </button>
              ))}
            </div>
          </div>

          <div className="flex items-center gap-2">
            <Button
              variant="secondary"
              size="xs"
              className="flex-1 justify-center"
              onClick={() =>
                void batchPatch(
                  createDefaultAssetBatchPatch(
                    selectedAssets.map((a) => a.id),
                    { pinnedOffline: true },
                  ),
                )
              }
            >
              <ArrowDownCircle size={12} />
              离线保留
            </Button>
            <Button
              variant="danger"
              size="xs"
              className="flex-1 justify-center"
              onClick={() => void trashAssets(selectedAssets.map((a) => a.id))}
            >
              <Trash2 size={12} />
              移入回收站
            </Button>
          </div>
        </div>
      ) : (
        /* Mode 3: Empty Inspector State */
        <div className="flex-1 flex flex-col items-center justify-center p-6 text-center gap-2">
          <CharkleIcon name="quicklook" size={28} className="opacity-65" />
          <div className="text-[13px] font-medium text-[var(--text-primary)]">未选中素材</div>
          <p className="text-[12px] text-[var(--text-tertiary)] leading-relaxed">
            点击任意卡片查看色板、标签与元信息；支持 Shift 连选或拖拽框选进行批量编辑。
          </p>
        </div>
      )}
    </aside>
  );
};
