import React, { useEffect, useMemo, useState } from 'react';
import {
  AlertTriangle,
  Check,
  CheckCircle2,
  Loader2,
  Lock,
  Send,
  Settings,
  Sparkles,
  Star,
  X,
} from 'lucide-react';
import {
  EDITORIAL_STYLES,
  createDefaultMoodboardCurationRequest,
  editorialStyleLocalizedLabel,
  isLightHex,
  labFromHex,
} from '@charkle/shared';
import type {
  EditorialStyle,
  MoodboardCurationRequest,
  MoodboardSeed,
  UUID,
} from '@charkle/shared';
import { thumbnailURL } from '../../api/client';
import {
  DisclosureGroup,
  EmptyStateVignette,
  FolderHierarchyScopeTree,
  SegmentedControl,
} from '../../design-system';
import { Button } from '../../design-system/Button';
import { CharkleIcon } from '../../design-system/CharkleIcon';
import { ModalShell } from '../../design-system/ModalShell';
import { useCoordinatorStore } from '../../stores/coordinatorStore';
import { useLibraryStore } from '../../stores/libraryStore';
import { useMoodboardStore } from '../../stores/moodboardStore';
import { useSyncAIStore } from '../../stores/syncAIStore';
import {
  AGENT_PHASE_META,
  CURATED_GENERATOR_SWATCHES,
  GENERATOR_PRESET_PROMPTS,
  GROUP_TINT_PALETTE,
} from './palettes';

type EntryMode = 'combined' | 'prompt' | 'seedAssets' | 'palette' | 'manualSelection';

const ENTRY_MODE_TABS: ReadonlyArray<{ id: EntryMode; label: string }> = [
  { id: 'combined', label: '多条件组合' },
  { id: 'prompt', label: '灵感词' },
  { id: 'seedAssets', label: '参考图' },
  { id: 'palette', label: '目标色板' },
  { id: 'manualSelection', label: '已选素材' },
];

const LAYOUT_STYLE_OPTIONS: ReadonlyArray<{ id: EditorialStyle; label: string }> =
  EDITORIAL_STYLES.map((style) => ({
    id: style,
    label: editorialStyleLocalizedLabel(style),
  }));

const PREFERRED_COUNT_OPTIONS: ReadonlyArray<{ id: '6' | '10' | '16'; label: string }> = [
  { id: '6', label: '6 张' },
  { id: '10', label: '10 张' },
  { id: '16', label: '16 张' },
];

export const MoodboardGeneratorModal: React.FC = () => {
  const open = useCoordinatorStore((s) => s.generatorModalOpen);
  const closeGeneratorModal = useCoordinatorStore((s) => s.closeGeneratorModal);
  const initialSeedIDs = useCoordinatorStore((s) => s.generatorInitialSeedAssetIDs);
  const destination = useCoordinatorStore((s) => s.destination);
  const openSettings = useCoordinatorStore((s) => s.openSettings);
  const pushToast = useCoordinatorStore((s) => s.pushToast);

  const folders = useLibraryStore((s) => s.folders);
  const tags = useLibraryStore((s) => s.tags);
  const assetsByID = useLibraryStore((s) => s.assetsByID);
  const selectedAssetIDs = useLibraryStore((s) => s.selectedAssetIDs);
  const cacheBustVersion = useLibraryStore((s) => s.cacheBustVersion);

  const proposal = useMoodboardStore((s) => s.proposal);
  const agentSteps = useMoodboardStore((s) => s.agentSteps);
  const isCurating = useMoodboardStore((s) => s.isCurating);
  const curationError = useMoodboardStore((s) => s.curationError);
  const curateMoodboard = useMoodboardStore((s) => s.curateMoodboard);
  const proposeMoodboard = useMoodboardStore((s) => s.proposeMoodboard);
  const cancelCuration = useMoodboardStore((s) => s.cancelCuration);
  const applyProposal = useMoodboardStore((s) => s.applyProposal);
  const clearProposal = useMoodboardStore((s) => s.clearProposal);

  const aiConfig = useSyncAIStore((s) => s.aiConfig);
  const hasStoredAIKeys = useSyncAIStore((s) => s.hasStoredAIKeys);
  const typeSafeConfig = useSyncAIStore((s) => s.typeSafeConfig);
  const hasStoredTypeSafeKey = useSyncAIStore((s) => s.hasStoredTypeSafeKey);
  const loadAIConfig = useSyncAIStore((s) => s.loadAIConfig);
  const loadTypeSafeConfig = useSyncAIStore((s) => s.loadTypeSafeConfig);

  const [entryMode, setEntryMode] = useState<EntryMode>('combined');
  const [promptText, setPromptText] = useState('');
  const [scopeFolderIDs, setScopeFolderIDs] = useState<Set<UUID>>(new Set());
  const [requiredTags, setRequiredTags] = useState<Set<string>>(new Set());
  const [selectedSeedIDs, setSelectedSeedIDs] = useState<Set<UUID>>(new Set());
  const [selectedPaletteHexes, setSelectedPaletteHexes] = useState<string[]>([]);
  const [customHex, setCustomHex] = useState('#3D5A80');
  const [colorTolerance, setColorTolerance] = useState(26);
  const [preferredCount, setPreferredCount] = useState<6 | 10 | 16>(10);
  const [layoutStyle, setLayoutStyle] = useState<EditorialStyle>('magazine');
  const [includeCuratorNotes, setIncludeCuratorNotes] = useState(true);
  const [autoFocusDetailCrop, setAutoFocusDetailCrop] = useState(false);

  const [lockedAssetIDs, setLockedAssetIDs] = useState<Set<UUID>>(new Set());
  const [excludedAssetIDs, setExcludedAssetIDs] = useState<Set<UUID>>(new Set());
  const [refinementInput, setRefinementInput] = useState('');
  const [boardTitle, setBoardTitle] = useState('');
  const [advancedOpen, setAdvancedOpen] = useState(false);
  const [traceExpanded, setTraceExpanded] = useState(true);
  const [applying, setApplying] = useState(false);

  useEffect(() => {
    if (!open) return;
    void loadAIConfig();
    void loadTypeSafeConfig();

    const preSeeds =
      initialSeedIDs.length > 0
        ? initialSeedIDs
        : Array.from(selectedAssetIDs);

    if (preSeeds.length > 0) {
      setSelectedSeedIDs(new Set(preSeeds.slice(0, entryMode === 'manualSelection' ? 24 : 4)));
      if (preSeeds.length >= 4 && initialSeedIDs.length > 0) {
        setEntryMode('manualSelection');
      }
    }
    if (destination.type === 'folder') {
      setScopeFolderIDs(new Set([destination.id]));
    } else {
      setScopeFolderIDs(new Set());
    }
  }, [open]);

  useEffect(() => {
    if (proposal?.draftDocument.title) {
      setBoardTitle(proposal.draftDocument.title);
    }
  }, [proposal?.draftDocument.title]);

  const isTypeSafeReady = typeSafeConfig.enabled && hasStoredTypeSafeKey;
  const hasGenerativeAI = aiConfig.provider !== 'disabled' && Boolean(hasStoredAIKeys[aiConfig.provider]);
  const isCloudAIReady = hasGenerativeAI || isTypeSafeReady;

  const providerBadge = useMemo(() => {
    if (!hasGenerativeAI && isTypeSafeReady) return '视觉定位模型';
    if (!hasGenerativeAI) return '本地生成';
    switch (aiConfig.provider) {
      case 'chatGPTSubscription':
        return 'ChatGPT';
      case 'gemini':
        return 'Gemini';
      case 'openAICompatible':
        return '云端模型';
      default:
        return '本地生成';
    }
  }, [aiConfig.provider, hasGenerativeAI, isTypeSafeReady]);

  const candidateLibraryAssets = useMemo(() => {
    return Object.values(assetsByID)
      .filter((a) => !a.isTrashed)
      .sort((a, b) => b.createdAt.localeCompare(a.createdAt))
      .slice(0, 30);
  }, [assetsByID]);

  const toggleRequiredTag = (name: string) => {
    setRequiredTags((prev) => {
      const next = new Set(prev);
      if (next.has(name)) next.delete(name);
      else next.add(name);
      return next;
    });
  };

  const toggleSeedAsset = (id: UUID) => {
    const limit = entryMode === 'manualSelection' ? 24 : 4;
    setSelectedSeedIDs((prev) => {
      const next = new Set(prev);
      if (next.has(id)) {
        next.delete(id);
      } else {
        if (next.size >= limit) {
          const first = next.values().next().value;
          if (first) next.delete(first);
        }
        next.add(id);
      }
      return next;
    });
  };

  const toggleSwatch = (hex: string) => {
    const upper = hex.toUpperCase();
    setSelectedPaletteHexes((prev) => {
      if (prev.includes(upper)) return prev.filter((c) => c !== upper);
      const next = [...prev];
      if (next.length >= 3) next.shift();
      next.push(upper);
      return next;
    });
  };

  const handleRunCuration = async (refinement: string | null) => {
    if (entryMode === 'manualSelection' && !refinement) {
      const ids = Array.from(selectedSeedIDs);
      if (ids.length === 0) {
        pushToast({ tone: 'error', message: '请先至少选择 1 张素材' });
        return;
      }
      const seed: MoodboardSeed = { type: 'manualSelection', assetIDs: ids };
      try {
        await proposeMoodboard(seed, ids.length, 24);
      } catch {
        // Error surfaced in store
      }
      return;
    }

    const usePrompt = entryMode === 'combined' || entryMode === 'prompt';
    const useSeeds = entryMode === 'combined' || entryMode === 'seedAssets' || entryMode === 'manualSelection';
    const usePalette = entryMode === 'combined' || entryMode === 'palette';

    const req: MoodboardCurationRequest = createDefaultMoodboardCurationRequest({
      prompt: usePrompt ? promptText.trim() : '',
      seedAssetIDs: useSeeds ? Array.from(selectedSeedIDs) : [],
      scopeFolderIDs: Array.from(scopeFolderIDs),
      requiredTags: Array.from(requiredTags),
      targetPalette: usePalette ? selectedPaletteHexes.map((h) => labFromHex(h)) : [],
      colorTolerance,
      preferredCount,
      candidateCount: 28,
      layoutStyle,
      useFreeformLayout: true,
      includeCuratorNotes,
      excludedAssetIDs: Array.from(excludedAssetIDs),
      lockedAssetIDs: Array.from(lockedAssetIDs),
      existingBoard: refinement ? proposal?.draftDocument ?? null : null,
      refinementInstruction: refinement,
      autoFocusDetailCrop: isTypeSafeReady && autoFocusDetailCrop,
    });

    await curateMoodboard(req);
  };

  const handleApplyProposal = async () => {
    if (!proposal) return;
    setApplying(true);
    try {
      const finalProposal =
        boardTitle.trim() && boardTitle.trim() !== proposal.draftDocument.title
          ? {
              ...proposal,
              draftDocument: {
                ...proposal.draftDocument,
                title: boardTitle.trim(),
              },
            }
          : proposal;
      await applyProposal(finalProposal);
      pushToast({ tone: 'success', message: `已创建情绪板「${finalProposal.draftDocument.title}」` });
    } catch (err) {
      pushToast({
        tone: 'error',
        message: err instanceof Error ? err.message : '应用情绪板失败',
      });
    } finally {
      setApplying(false);
    }
  };

  const handleClose = () => {
    if (isCurating) cancelCuration();
    closeGeneratorModal();
  };

  return (
    <ModalShell
      open={open}
      onClose={handleClose}
      width="studio"
      noPadding
      title={
        <span className="inline-flex items-center gap-2.5">
          <CharkleIcon name="sparkle-board" style="layered" size={24} />
          <span>AI 生成情绪板</span>
        </span>
      }
      headerRight={
        <div className="inline-flex items-center gap-2 px-2.5 py-1 rounded-full bg-[var(--bg-subtle)] border border-[var(--border-hairline)] text-[11.5px]">
          <span
            className="w-2 h-2 rounded-full"
            style={{ backgroundColor: isCloudAIReady ? 'var(--success)' : 'var(--warning)' }}
          />
          <span className="text-[var(--text-secondary)] font-medium">{providerBadge}</span>
          {!isCloudAIReady && (
            <button
              type="button"
              onClick={() => {
                handleClose();
                openSettings('ai');
              }}
              className="charkle-pressable inline-flex items-center gap-1 px-2 py-0.5 rounded-full bg-[var(--bg-elevated)] text-[var(--text-primary)] border border-[var(--border-hairline)] text-[11px] font-medium cursor-pointer"
            >
              <Settings size={10} />
              去开启
            </button>
          )}
        </div>
      }
      footer={
        <div className="w-full flex items-center justify-between gap-3">
          <div className="flex items-center gap-2 flex-1 min-w-0">
            {proposal && (
              <>
                <span className="text-[12px] text-[var(--text-secondary)] shrink-0">情绪板标题</span>
                <input
                  type="text"
                  value={boardTitle}
                  onChange={(e) => setBoardTitle(e.target.value)}
                  placeholder="输入情绪板标题"
                  className="w-64 max-w-full h-8 px-2.5 rounded-[var(--radius-settings-inner)] bg-[var(--bg-elevated)] border border-[var(--border-hairline)] text-[12.5px] font-medium text-[var(--text-primary)] outline-none focus:border-[var(--accent)]"
                />
              </>
            )}
          </div>
          <div className="flex items-center gap-2 shrink-0">
            {proposal && (
              <Button variant="ghost" size="sm" onClick={clearProposal}>
                清空初稿
              </Button>
            )}
            <Button variant="secondary" size="sm" onClick={handleClose}>
              取消
            </Button>
            <Button
              variant="primary"
              size="sm"
              disabled={!proposal || isCurating}
              loading={applying}
              onClick={handleApplyProposal}
            >
              <Check size={14} />
              创建并打开情绪板
            </Button>
          </div>
        </div>
      }
    >
      <div className="grid grid-cols-1 lg:grid-cols-[368px_1fr] h-[min(70vh,620px)] overflow-hidden">
        {/* Left Studio: 4+1 Composable Brief Controls */}
        <div className="border-r border-[var(--border-hairline)] bg-[var(--bg-gallery)] overflow-y-auto charkle-scroll p-4 flex flex-col gap-4">
          {/* Entry Mode Switcher */}
          <div>
            <div className="text-[12px] font-semibold text-[var(--text-primary)] mb-2">
              生成方式
            </div>
            <div className="flex flex-wrap gap-1.5">
              {ENTRY_MODE_TABS.map((m) => {
                const active = entryMode === m.id;
                return (
                  <button
                    key={m.id}
                    type="button"
                    onClick={() => setEntryMode(m.id)}
                    className={[
                      'charkle-pressable px-2.5 py-1 rounded-[var(--radius-chip)] text-[11.5px] font-medium border cursor-pointer',
                      active
                        ? 'bg-[var(--accent-soft)] text-[var(--accent)] border-[var(--accent-ring)]'
                        : 'bg-[var(--bg-elevated)] text-[var(--text-secondary)] border-[var(--border-hairline)] hover:text-[var(--text-primary)]',
                    ].join(' ')}
                  >
                    {m.label}
                  </button>
                );
              })}
            </div>
          </div>

          {/* 1. Prompt Input */}
          {(entryMode === 'combined' || entryMode === 'prompt') && (
            <div className="flex flex-col gap-2">
              <label className="text-[12px] font-semibold text-[var(--text-primary)]">
                灵感方向与要求
              </label>
              <textarea
                rows={3}
                value={promptText}
                onChange={(e) => setPromptText(e.target.value)}
                placeholder="描述想要的风格、材质或色调…"
                className="w-full p-2.5 rounded-[var(--radius-settings-inner)] bg-[var(--bg-elevated)] border border-[var(--border-hairline)] text-[12px] text-[var(--text-primary)] placeholder:text-[var(--text-tertiary)] outline-none focus:border-[var(--accent)] resize-none"
              />
              <div className="flex flex-wrap gap-1.5">
                {GENERATOR_PRESET_PROMPTS.map((preset) => (
                  <button
                    key={preset}
                    type="button"
                    onClick={() => setPromptText(preset)}
                    className="charkle-pressable px-2.5 py-1 rounded-full bg-[var(--bg-elevated)] border border-[var(--border-hairline)] text-[11px] text-[var(--text-secondary)] hover:text-[var(--text-primary)] cursor-pointer text-left"
                  >
                    {preset}
                  </button>
                ))}
              </div>
            </div>
          )}

          {/* 2. Seed Assets / Manual Selection Picker */}
          {(entryMode === 'combined' ||
            entryMode === 'seedAssets' ||
            entryMode === 'manualSelection') && (
            <div className="flex flex-col gap-2 pt-2 border-t border-[var(--border-hairline)]">
              <div className="flex items-center justify-between">
                <span className="text-[12px] font-semibold text-[var(--text-primary)]">
                  {entryMode === 'manualSelection' ? '框选入板素材' : '定调种子图 (1–4 张)'}
                </span>
                <div className="flex items-center gap-2 text-[11px]">
                  <span className="text-[var(--text-secondary)]">
                    已选 {selectedSeedIDs.size} 张
                  </span>
                  {selectedSeedIDs.size > 0 && (
                    <button
                      type="button"
                      onClick={() => setSelectedSeedIDs(new Set())}
                      className="text-[var(--text-tertiary)] hover:text-[var(--text-primary)] cursor-pointer"
                    >
                      清空
                    </button>
                  )}
                </div>
              </div>
              <div className="grid grid-cols-4 gap-1.5 max-h-[168px] overflow-y-auto charkle-scroll pr-0.5">
                {candidateLibraryAssets.map((asset) => {
                  const picked = selectedSeedIDs.has(asset.id);
                  return (
                    <button
                      key={asset.id}
                      type="button"
                      onClick={() => toggleSeedAsset(asset.id)}
                      title={asset.title}
                      className="charkle-pressable relative aspect-square rounded-[var(--radius-settings-inner)] overflow-hidden bg-[var(--bg-subtle)] cursor-pointer"
                      style={{
                        boxShadow: picked ? '0 0 0 2px var(--accent)' : 'inset 0 0 0 1px var(--border-hairline)',
                      }}
                    >
                      <img
                        src={thumbnailURL(asset.id, 'grid520', cacheBustVersion)}
                        alt={asset.title}
                        loading="lazy"
                        className="w-full h-full object-cover"
                      />
                      {picked && (
                        <span className="charkle-micro-pop absolute top-1 right-1 w-4 h-4 rounded-full bg-[var(--accent)] text-white inline-flex items-center justify-center shadow-xs">
                          <Check size={10} strokeWidth={3} />
                        </span>
                      )}
                    </button>
                  );
                })}
              </div>
            </div>
          )}

          {/* 3. Target Palette + Color Tolerance */}
          {(entryMode === 'combined' || entryMode === 'palette') && (
            <div className="flex flex-col gap-2 pt-2 border-t border-[var(--border-hairline)]">
              <div className="flex items-center justify-between">
                <span className="text-[12px] font-semibold text-[var(--text-primary)]">
                  目标色板 (最多 3 色)
                </span>
                <span className="text-[11px] text-[var(--text-secondary)]">
                  {selectedPaletteHexes.length > 0 ? `已选 ${selectedPaletteHexes.length} 色` : '可选'}
                </span>
              </div>
              <div className="flex flex-wrap items-center gap-1.5">
                {CURATED_GENERATOR_SWATCHES.map((hex) => {
                  const active = selectedPaletteHexes.includes(hex.toUpperCase());
                  return (
                    <button
                      key={hex}
                      type="button"
                      title={hex}
                      onClick={() => toggleSwatch(hex)}
                      className="charkle-pressable w-7 h-7 rounded-[var(--radius-chip)] cursor-pointer"
                      style={{
                        backgroundColor: hex,
                        boxShadow: active
                          ? '0 0 0 2px var(--bg-gallery), 0 0 0 4px var(--accent)'
                          : isLightHex(hex)
                            ? 'inset 0 0 0 1px rgba(0,0,0,0.16)'
                            : 'inset 0 0 0 1px rgba(255,255,255,0.14)',
                      }}
                    />
                  );
                })}
                <label
                  title="添加自定义 HEX 颜色"
                  className="inline-flex items-center gap-1 px-2 h-7 rounded-[var(--radius-chip)] bg-[var(--bg-elevated)] border border-[var(--border-hairline)] text-[11px] text-[var(--text-secondary)] cursor-pointer"
                >
                  <input
                    type="color"
                    value={customHex}
                    onChange={(e) => {
                      setCustomHex(e.target.value);
                      toggleSwatch(e.target.value);
                    }}
                    className="w-4 h-4 border-0 p-0 bg-transparent cursor-pointer"
                  />
                  自定义
                </label>
              </div>
              {selectedPaletteHexes.length > 0 && (
                <div className="flex items-center gap-2 text-[11px] text-[var(--text-secondary)] pt-1">
                  <span>色差容差</span>
                  <input
                    type="range"
                    min={12}
                    max={46}
                    step={2}
                    value={colorTolerance}
                    onChange={(e) => setColorTolerance(Number(e.target.value))}
                    className="flex-1 accent-[var(--accent)] cursor-pointer"
                  />
                  <span className="tabular-nums">{colorTolerance}</span>
                </div>
              )}
            </div>
          )}

          {/* 4. Hierarchical Folder & Tag Scope Filters */}
          {entryMode !== 'manualSelection' && (
            <div className="flex flex-col gap-2.5 pt-2 border-t border-[var(--border-hairline)]">
              <div className="flex items-center justify-between">
                <span className="text-[12px] font-semibold text-[var(--text-primary)]">
                  目录与标签限定
                </span>
                <span className="text-[11px] text-[var(--text-tertiary)] tabular-nums">
                  {scopeFolderIDs.size === 0 ? '全库检索' : `已选 ${scopeFolderIDs.size} 个目录`}
                </span>
              </div>
              {folders.length > 0 && (
                <FolderHierarchyScopeTree
                  folders={folders}
                  selectedFolderIDs={scopeFolderIDs}
                  onChange={setScopeFolderIDs}
                />
              )}

              {tags.length > 0 && (
                <div className="flex flex-wrap gap-1">
                  {tags.slice(0, 10).map((t) => {
                    const active = requiredTags.has(t.name);
                    return (
                      <button
                        key={t.name}
                        type="button"
                        onClick={() => toggleRequiredTag(t.name)}
                        className={[
                          'charkle-pressable px-2 py-0.5 rounded-full text-[10.5px] border cursor-pointer',
                          active
                            ? 'bg-[var(--accent-soft)] text-[var(--accent)] border-[var(--accent-ring)] font-medium'
                            : 'bg-[var(--bg-subtle)] text-[var(--text-secondary)] border-transparent hover:border-[var(--border-hairline)]',
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

          {/* 5. Collapsible Advanced Composition & Layout Options */}
          <div className="pt-2 border-t border-[var(--border-hairline)]">
            <DisclosureGroup
              open={advancedOpen}
              onOpenChange={setAdvancedOpen}
              headerClassName="-mx-2 px-2"
              label={
                <>
                  <span className="text-[12px] font-semibold text-[var(--text-primary)]">
                    版面与高级选项
                  </span>
                  <span className="text-[11px] text-[var(--text-tertiary)] tabular-nums">
                    {editorialStyleLocalizedLabel(layoutStyle)} · {preferredCount} 张
                  </span>
                </>
              }
            >
              <div className="flex flex-col gap-2.5 pt-1">
                <div className="flex items-center justify-between gap-2 text-[11.5px]">
                  <span className="text-[var(--text-secondary)] shrink-0">构图节奏</span>
                  <SegmentedControl
                    ariaLabel="初始构图节奏"
                    size="sm"
                    options={LAYOUT_STYLE_OPTIONS}
                    value={layoutStyle}
                    onChange={setLayoutStyle}
                  />
                </div>

                <div className="flex items-center justify-between gap-2 text-[11.5px]">
                  <span className="text-[var(--text-secondary)] shrink-0">数量上限</span>
                  <SegmentedControl
                    ariaLabel="数量上限"
                    size="sm"
                    options={PREFERRED_COUNT_OPTIONS}
                    value={String(preferredCount) as '6' | '10' | '16'}
                    onChange={(next) => setPreferredCount(Number(next) as 6 | 10 | 16)}
                  />
                </div>

                <label className="inline-flex items-center gap-2 text-[11.5px] text-[var(--text-primary)] cursor-pointer pt-0.5">
                  <input
                    type="checkbox"
                    checked={includeCuratorNotes}
                    onChange={(e) => setIncludeCuratorNotes(e.target.checked)}
                    className="accent-[var(--accent)]"
                  />
                  附带视觉策展便签与分区标题
                </label>

                <label
                  title={
                    isTypeSafeReady
                      ? '自动裁切画面焦点'
                      : '需先在「设置 → AI 智能」中开启'
                  }
                  className={[
                    'inline-flex items-center gap-2 text-[11.5px]',
                    isTypeSafeReady
                      ? 'text-[var(--text-primary)] cursor-pointer'
                      : 'text-[var(--text-tertiary)] cursor-not-allowed',
                  ].join(' ')}
                >
                  <input
                    type="checkbox"
                    checked={autoFocusDetailCrop}
                    disabled={!isTypeSafeReady}
                    onChange={(e) => setAutoFocusDetailCrop(e.target.checked)}
                    className="accent-[var(--accent)]"
                  />
                  自动裁切画面细节
                </label>
              </div>
            </DisclosureGroup>
          </div>

          {/* Primary Trigger */}
          <div className="pt-1 flex items-center gap-2">
            <Button
              variant="primary"
              size="md"
              className="flex-1 justify-center"
              loading={isCurating}
              onClick={() => {
                setExcludedAssetIDs(new Set());
                setLockedAssetIDs(new Set(selectedSeedIDs));
                void handleRunCuration(null);
              }}
            >
              <Sparkles size={14} />
              {isCurating
                ? '正在生成…'
                : isCloudAIReady
                  ? '开始生成'
                  : '生成情绪板'}
            </Button>
            {isCurating && (
              <Button variant="secondary" size="md" onClick={cancelCuration}>
                停止
              </Button>
            )}
          </div>
        </div>

        {/* Right Workbench: Live Progress Timeline + Section Draft Preview + Refinement */}
        <div className="bg-[var(--bg-elevated)] flex flex-col min-h-0 overflow-hidden">
          <div className="flex-1 min-h-0 overflow-y-auto charkle-scroll p-5 flex flex-col gap-4">
            {/* Error callout */}
            {curationError && (
              <div className="p-3 rounded-[var(--radius-settings-inner)] bg-[var(--danger-soft)] text-[var(--danger)] text-[12.5px] flex items-center gap-2">
                <AlertTriangle size={15} className="shrink-0" />
                <span>{curationError}</span>
              </div>
            )}

            {/* Live Progress Timeline */}
            {(isCurating || agentSteps.length > 0) && (
              <div className="rounded-[var(--radius-settings-outer)] bg-[var(--bg-gallery)] border border-[var(--border-hairline)] overflow-hidden p-1.5">
                <DisclosureGroup
                  open={traceExpanded}
                  onOpenChange={setTraceExpanded}
                  headerClassName="px-2 py-1.5"
                  label={
                    <span className="inline-flex items-center gap-2 text-[12px] font-semibold text-[var(--text-primary)]">
                      {isCurating ? (
                        <Loader2 size={13} className="animate-spin text-[var(--accent)]" />
                      ) : (
                        <CheckCircle2 size={13} className="text-[var(--success)]" />
                      )}
                      生成进度 ({agentSteps.length})
                    </span>
                  }
                >
                  <div className="px-2 pb-2 pt-2 flex flex-col gap-2 border-t border-[var(--border-hairline)]">
                    {agentSteps.length === 0 ? (
                      <div className="text-[12px] text-[var(--text-secondary)] py-1.5">
                        正在分析素材库…
                      </div>
                    ) : (
                      agentSteps.map((step) => {
                        const meta = AGENT_PHASE_META[step.phase];
                        return (
                          <div
                            key={step.id}
                            className="flex items-start gap-2.5 text-[12px]"
                          >
                            <span className="mt-0.5 shrink-0">
                              {step.status === 'running' ? (
                                <Loader2 size={13} className="animate-spin text-[var(--accent)]" />
                              ) : step.status === 'warning' ? (
                                <AlertTriangle size={13} className="text-[var(--warning)]" />
                              ) : (
                                <CheckCircle2 size={13} className="text-[var(--success)]" />
                              )}
                            </span>
                            <div className="min-w-0 flex-1">
                              <div className="flex items-center gap-2">
                                <span className="px-1.5 py-0.5 rounded-[var(--radius-chip)] bg-[var(--bg-elevated)] border border-[var(--border-hairline)] text-[10px] font-medium text-[var(--text-secondary)]">
                                  {meta?.shortLabel ?? step.phase}
                                </span>
                                <span className="font-medium text-[var(--text-primary)]">
                                  {step.title}
                                </span>
                              </div>
                              {step.detail && (
                                <p className="text-[11.5px] text-[var(--text-secondary)] mt-0.5 leading-snug">
                                  {step.detail}
                                </p>
                              )}
                            </div>
                          </div>
                        );
                      })
                    )}
                  </div>
                </DisclosureGroup>
              </div>
            )}

            {/* Empty workbench prompt */}
            {!proposal && !isCurating && (
              <div className="flex-1 min-h-[280px] flex flex-col items-center justify-center text-center max-w-sm mx-auto gap-3">
                <EmptyStateVignette kind="emptyMoodboard" compact />
                <div>
                  <div className="text-[14.5px] font-semibold text-[var(--text-primary)]">
                    准备生成情绪板
                  </div>
                </div>
              </div>
            )}

            {/* Curated Proposal Summary + Palette + Sections Preview */}
            {proposal && (
              <div className="flex flex-col gap-4">
                <div className="rounded-[var(--radius-settings-outer)] bg-[var(--bg-gallery)] border border-[var(--border-hairline)] p-4 flex flex-col gap-2.5">
                  <div className="flex items-start justify-between gap-3">
                    <div>
                      <div className="text-[14px] font-semibold text-[var(--text-primary)]">
                        {proposal.draftDocument.title}
                      </div>
                      <p className="text-[12px] text-[var(--text-secondary)] mt-1 leading-relaxed">
                        {proposal.curatedSummary}
                      </p>
                    </div>
                    <span className="px-2 py-0.5 rounded-full bg-[var(--bg-elevated)] border border-[var(--border-hairline)] text-[11px] font-medium text-[var(--text-secondary)] shrink-0">
                      {proposal.usedCloudAI ? '云端生成' : '本地生成'} ·{' '}
                      {proposal.primaryMatches.length} 张主选
                    </span>
                  </div>

                  {proposal.extractedPalette.length > 0 && (
                    <div className="flex items-center gap-1.5 pt-1">
                      {proposal.extractedPalette.slice(0, 7).map((c) => (
                        <span
                          key={c.hex}
                          title={c.hex.toUpperCase()}
                          className="inline-flex items-center gap-1 px-2 py-0.5 rounded-[6px] bg-[var(--bg-elevated)] border border-[var(--border-hairline)] text-[10.5px] font-mono text-[var(--text-secondary)]"
                        >
                          <span
                            className="w-2.5 h-2.5 rounded-[3px]"
                            style={{ backgroundColor: c.hex }}
                          />
                          {c.hex.toUpperCase()}
                        </span>
                      ))}
                    </div>
                  )}

                  {proposal.rejectedSummary && (
                    <div className="text-[11.5px] text-[var(--text-tertiary)] border-t border-[var(--border-hairline)] pt-2">
                      过滤说明：{proposal.rejectedSummary}
                    </div>
                  )}
                </div>

                {/* Section Drafts Grid */}
                {proposal.sections.length > 0 ? (
                  proposal.sections.map((section) => {
                    const tint = GROUP_TINT_PALETTE[section.tint];
                    const heroSet = new Set(section.heroAssetIDs);
                    return (
                      <div key={section.id} className="flex flex-col gap-2">
                        <div className="flex items-center justify-between gap-2">
                          <div className="flex items-center gap-2 min-w-0">
                            <span
                              className="w-2.5 h-2.5 rounded-full shrink-0"
                              style={{ backgroundColor: tint.accent }}
                            />
                            <span className="text-[13px] font-semibold text-[var(--text-primary)] truncate">
                              {section.title}
                            </span>
                            <span className="text-[11px] text-[var(--text-tertiary)] shrink-0">
                              {section.assetIDs.length} 张
                            </span>
                          </div>
                          {section.rationale && (
                            <span className="text-[11px] text-[var(--text-secondary)] truncate max-w-[55%]">
                              {section.rationale}
                            </span>
                          )}
                        </div>
                        <div className="grid grid-cols-3 sm:grid-cols-4 gap-2">
                          {section.assetIDs.map((aid) => {
                            const asset = assetsByID[aid] ??
                              proposal.primaryMatches.find((m) => m.asset.id === aid)?.asset;
                            const isHero = heroSet.has(aid);
                            const isLocked = lockedAssetIDs.has(aid);
                            const isExcluded = excludedAssetIDs.has(aid);
                            return (
                              <div
                                key={aid}
                                className={[
                                  'group/draft relative aspect-[4/3] rounded-[var(--radius-settings-inner)] overflow-hidden bg-[var(--bg-subtle)] border border-[var(--border-hairline)]',
                                  isExcluded ? 'opacity-35 grayscale' : '',
                                ].join(' ')}
                              >
                                <img
                                  src={thumbnailURL(aid, 'grid520', cacheBustVersion)}
                                  alt={asset?.title ?? ''}
                                  className="w-full h-full object-cover"
                                />
                                {isHero && (
                                  <span className="absolute top-1.5 left-1.5 inline-flex items-center gap-0.5 px-1.5 py-0.5 rounded-[var(--radius-chip)] bg-[var(--accent)] text-white text-[9.5px] font-semibold">
                                    <Star size={9} fill="currentColor" /> 主图
                                  </span>
                                )}
                                <div className="absolute top-1.5 right-1.5 flex items-center gap-1 opacity-0 group-hover/draft:opacity-100 group-focus-within/draft:opacity-100 transition-opacity duration-150">
                                  <button
                                    type="button"
                                    title={isLocked ? '取消锁定' : '锁定必留'}
                                    onClick={() =>
                                      setLockedAssetIDs((prev) => {
                                        const next = new Set(prev);
                                        if (next.has(aid)) next.delete(aid);
                                        else next.add(aid);
                                        return next;
                                      })
                                    }
                                    className={[
                                      'w-6 h-6 rounded-[var(--radius-chip)] inline-flex items-center justify-center text-white cursor-pointer',
                                      isLocked ? 'bg-[var(--accent)]' : 'bg-black/60 hover:bg-black/80',
                                    ].join(' ')}
                                  >
                                    <Lock size={10} />
                                  </button>
                                  <button
                                    type="button"
                                    title={isExcluded ? '撤销排除' : '下轮排除此图'}
                                    onClick={() =>
                                      setExcludedAssetIDs((prev) => {
                                        const next = new Set(prev);
                                        if (next.has(aid)) next.delete(aid);
                                        else next.add(aid);
                                        return next;
                                      })
                                    }
                                    className={[
                                      'w-6 h-6 rounded-[var(--radius-chip)] inline-flex items-center justify-center text-white cursor-pointer',
                                      isExcluded ? 'bg-[var(--danger)]' : 'bg-black/60 hover:bg-black/80',
                                    ].join(' ')}
                                  >
                                    <X size={10} />
                                  </button>
                                </div>
                              </div>
                            );
                          })}
                        </div>
                      </div>
                    );
                  })
                ) : (
                  <div className="grid grid-cols-3 sm:grid-cols-4 gap-2">
                    {proposal.primaryMatches.map((m) => (
                      <div
                        key={m.asset.id}
                        className="relative aspect-[4/3] rounded-[var(--radius-settings-inner)] overflow-hidden bg-[var(--bg-subtle)] border border-[var(--border-hairline)]"
                      >
                        <img
                          src={thumbnailURL(m.asset.id, 'grid520', cacheBustVersion)}
                          alt={m.asset.title}
                          className="w-full h-full object-cover"
                        />
                      </div>
                    ))}
                  </div>
                )}
              </div>
            )}
          </div>

          {/* Multi-turn Refinement Bar */}
          {proposal && (
            <form
              onSubmit={(e) => {
                e.preventDefault();
                const text = refinementInput.trim();
                if (!text || isCurating) return;
                setRefinementInput('');
                void handleRunCuration(text);
              }}
              className="px-4 py-3 border-t border-[var(--border-hairline)] bg-[var(--bg-gallery)] flex items-center gap-2"
            >
              <input
                type="text"
                value={refinementInput}
                onChange={(e) => setRefinementInput(e.target.value)}
                placeholder="输入微调要求…"
                className="flex-1 h-8 px-3 rounded-[var(--radius-settings-inner)] bg-[var(--bg-elevated)] border border-[var(--border-hairline)] text-[12px] text-[var(--text-primary)] placeholder:text-[var(--text-tertiary)] outline-none focus:border-[var(--accent)]"
              />
              <Button
                type="submit"
                variant="secondary"
                size="sm"
                disabled={!refinementInput.trim() || isCurating}
              >
                <Send size={13} />
                微调重排
              </Button>
            </form>
          )}
        </div>
      </div>
    </ModalShell>
  );
};
